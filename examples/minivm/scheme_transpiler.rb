#!/usr/bin/env ruby
# Scheme transpiler: CLEAR source -> S-expression output
# Usage: ruby scheme_transpiler.rb program.cht
#
# Runs the CLEAR source through lexer -> parser -> annotator,
# then walks the AST and emits S-expressions for the Scheme interpreter.

$LOAD_PATH.unshift(File.expand_path("../../src", __dir__))

require "set"
require "open3"
require "lexer"
require "parser"
require "ast"

class SchemeTranspiler
  def initialize
    @output = []
    @structs = {}       # name -> [field_name, ...] (ordered)
    @struct_types = {}  # name -> [[field_name, type_str], ...]
    @enums = Set.new
    @unions = {}  # name -> {variant_name -> has_payload}
    @mutable_stack = [Set.new]  # stack of per-function mutable sets
    @var_types = {}  # var_name -> struct_name (for field access resolution)
    @hash_vars = Set.new  # variable names known to be HashMaps
  end

  def transpile(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    # Skip annotator for now - parser AST is enough for basic emission
    emit_program(ast)
    @output.join("\n")
  end

  # Emit a single function definition as S-expression (for bytecode compiler)
  def emit_function_def(stmt)
    @mutable_stack.push(Set.new)
    params = stmt.params.map { |p| p.is_a?(Hash) ? p[:name] : p.name }.join(" ")
    body_expr = emit_body_with_early_returns(stmt.body)
    @mutable_stack.pop
    "(define #{stmt.name} (lambda (#{params}) #{body_expr}))"
  end

  private

  def mutables; @mutable_stack.last; end

  def struct_homogeneous_type(name)
    return nil unless @struct_types[name]
    types = @struct_types[name].map(&:last).uniq
    return "i64" if types.all? { |t| t.include?("Int64") && !t.include?("[]") }
    return "f64" if types.all? { |t| t.include?("Float64") && !t.include?("[]") }
    nil
  end

  # Restructure function bodies with early returns:
  # [IF cond THEN RETURN val END, ...rest...] -> (if cond val (begin ...rest...))
  def emit_body_with_early_returns(stmts)
    # Strip trailing bare RETURN
    stmts = stmts.reject { |s| s.is_a?(AST::ReturnNode) && s.value.nil? }
    return "nil" if stmts.empty?

    # If last statement is a RETURN, emit the body up to it
    # with early-return restructuring
    emit_stmts_with_returns(stmts)
  end

  def emit_stmts_with_returns(stmts)
    return "nil" if stmts.empty?

    first = stmts[0]
    rest = stmts[1..]

    # If this is an IF with a RETURN in the then-branch and there's more code after
    if first.is_a?(AST::IfStatement) && has_return?(first.then_branch) && !rest.empty?
      cond = emit(first.condition)
      then_val = emit_return_value(first.then_branch)
      # The else branch of the original IF + remaining statements become the else
      if first.else_branch && !first.else_branch.empty?
        # IF cond THEN RETURN a ELSE_IF ... -> nested
        else_stmts = first.else_branch + rest
        else_val = emit_stmts_with_returns(else_stmts)
      else
        else_val = emit_stmts_with_returns(rest)
      end
      return "(if #{cond} #{then_val} #{else_val})"
    end

    # If this is a RETURN, emit its value
    if first.is_a?(AST::ReturnNode)
      return first.value ? emit(first.value) : "nil"
    end

    # Normal statement + rest
    if rest.empty?
      emit(first)
    else
      first_expr = emit(first)
      rest_expr = emit_stmts_with_returns(rest)
      "(begin #{first_expr} #{rest_expr})"
    end
  end

  def has_return?(stmts)
    return false unless stmts
    stmts.any? { |s| s.is_a?(AST::ReturnNode) }
  end

  def emit_return_value(stmts)
    ret = stmts.find { |s| s.is_a?(AST::ReturnNode) }
    if ret
      # Emit non-return statements first, then the return value
      pre = stmts.take_while { |s| !s.is_a?(AST::ReturnNode) }
      val = ret.value ? emit(ret.value) : "nil"
      if pre.empty?
        val
      else
        "(begin #{pre.map { |s| emit(s) }.join(' ')} #{val})"
      end
    else
      # No explicit return - emit all and use last value
      exprs = stmts.map { |s| emit(s) }
      exprs.length == 1 ? exprs[0] : "(begin #{exprs.join(' ')})"
    end
  end

  def emit_program(program)
    program.statements.each do |stmt|
      case stmt
      when AST::StructDef
        @structs[stmt.name.to_s] = stmt.fields.keys
        # Preserve field types for typed struct emission
        @struct_types[stmt.name.to_s] = stmt.fields.map { |name, info| [name, info[:type].to_s] }
      when AST::EnumDef
        @enums.add(stmt.name.to_s)
      when AST::UnionDef
        @unions[stmt.name.to_s] = {}
        stmt.variants.each { |name, type| @unions[stmt.name.to_s][name] = !type.nil? }
      when AST::FunctionDef
        @mutable_stack.push(Set.new)
        if stmt.name == "main"
          stmt.body.each do |node|
            next if node.is_a?(AST::ReturnNode) && node.value.nil?
            # Emit source line marker for error tracking
            if node.respond_to?(:line) && node.line
              @output << "(source-line #{node.line})"
            end
            @output << emit(node)
          end
        else
          params = stmt.params.map { |p| p.is_a?(Hash) ? p[:name] : p.name }.join(" ")
          body_expr = emit_body_with_early_returns(stmt.body)
          @output << "(define #{stmt.name} (lambda (#{params}) #{body_expr}))"
        end
        @mutable_stack.pop
      else
        @output << emit(stmt)
      end
    end
  end

  def emit(node)
    case node
    when AST::Literal
      emit_literal(node)
    when AST::Identifier
      node.name.to_s
    when AST::FuncCall
      emit_func_call(node)
    when AST::MethodCall
      emit_method_call(node)
    when AST::BinaryOp
      emit_binary(node)
    when AST::UnaryOp
      emit_unary(node)
    when AST::StructLit
      emit_struct_lit(node)
    when AST::GetField
      emit_get_field(node)
    when AST::MatchStatement
      emit_match(node)
    when AST::HashLit
      emit_hash_lit(node)
    when AST::ListLit
      emit_list_lit(node)
    when AST::GetIndex
      emit_get_index(node)
    when AST::ForRange
      emit_for_range(node)
    when AST::ForEach
      emit_for_each(node)
    when AST::PassStmt
      "nil"
    when AST::BreakNode
      ";; break"
    when AST::ContinueNode
      ";; continue"
    when AST::Slice
      # target[start..end] -> (list-slice target start end)
      target = emit(node.target)
      s = emit(node.start)
      e = node.end ? emit(node.end) : "(list-length #{target})"
      "(list-slice #{target} #{s} #{e})"
    when AST::Cast
      # value AS Type -> identity (VM doesn't do type coercion)
      emit(node.value)
    when AST::RangeLit
      # 1..5 or 1..<5 -> generate list
      s = emit(node.start)
      f = emit(node.finish)
      if node.inclusive
        "(list-range #{s} (+ #{f} 1))"
      else
        "(list-range #{s} #{f})"
      end
    when AST::BindExpr
      # Track struct type for field resolution
      if node.value.is_a?(AST::StructLit)
        @var_types[node.name.to_s] = node.value.name.to_s
      end
      # Typed array: Int64[] = [...] -> (typed-list:i64 ...)
      val_expr = if node.type && node.type.to_s.include?("Int64[]") && node.value.is_a?(AST::ListLit)
        items = node.value.items.map { |i| emit(i) }.join(" ")
        items.empty? ? "(typed-list:i64)" : "(typed-list:i64 #{items})"
      elsif node.type && node.type.to_s.include?("Float64[]") && node.value.is_a?(AST::ListLit)
        items = node.value.items.map { |i| emit(i) }.join(" ")
        items.empty? ? "(typed-list:f64)" : "(typed-list:f64 #{items})"
      else
        emit(node.value)
      end
      if mutables.include?(node.name.to_s)
        "(set! #{node.name} #{val_expr})"
      else
        "(define #{node.name} #{val_expr})"
      end
    when AST::VarDecl
      mutables.add(node.name.to_s) if node.mutable
      if node.value.is_a?(AST::StructLit)
        @var_types[node.name.to_s] = node.value.name.to_s
      elsif node.value.is_a?(AST::HashLit)
        @hash_vars.add(node.name.to_s)
      end
      # Typed array declaration: Int64[] = [...] -> (typed-list:i64 ...)
      if node.type.to_s.include?("Int64[]") && node.value.is_a?(AST::ListLit)
        items = node.value.items.map { |i| emit(i) }.join(" ")
        "(define #{node.name} (typed-list:i64 #{items}))"
      elsif node.type.to_s.include?("Float64[]") && node.value.is_a?(AST::ListLit)
        items = node.value.items.map { |i| emit(i) }.join(" ")
        "(define #{node.name} (typed-list:f64 #{items}))"
      else
        "(define #{node.name} #{node.value ? emit(node.value) : 'nil'})"
      end
    when AST::Assignment
      emit_assignment(node)
    when AST::ReturnNode
      node.value ? emit(node.value) : "nil"
    when AST::IfStatement
      emit_if(node)
    when AST::WhileLoop
      emit_while(node)
    when AST::Assert
      emit_assert(node)
    when AST::Raise
      emit_raise(node)
    when AST::OptionalUnwrap
      emit(node.target)
    when AST::CapabilityWrap
      # VM ignores capabilities - emit inner value
      emit(node.value)
    when AST::UnionVariantLit
      vals = node.fields.values.map { |v| emit(v) }
      payload = vals.length == 1 ? vals.first : "(vector #{vals.join(' ')})"
      "(cons (quote #{node.variant_name}) #{payload})"
    when AST::Copy
      emit(node.value)
    when AST::CopyNode
      emit(node.value)
    when AST::MoveNode
      # GIVE transfers ownership - identity in VM (GC handles lifetime)
      emit(node.value)
    when AST::LambdaLit
      emit_lambda_lit(node)
    when AST::WhereOp, AST::SelectOp, AST::ReduceOp, AST::LimitOp,
         AST::OrderByOp, AST::DistinctOp, AST::UnnestOp, AST::IndexOp
      # Pipeline ops - handled via SMOOTH in emit_binary
      ";; pipeline op outside pipe"
    when AST::BgBlock
      # Sequential fake: BG { expr } -> eval immediately
      body = node.body.map { |n| emit(n) }
      body.length == 1 ? body[0] : "(begin #{body.join(' ')})"
    when AST::DoBlock
      # Sequential fake: DO { a, b } -> eval a then b
      branches = node.branches.map { |br|
        if br.is_a?(Array)
          stmts = br.map { |n| emit(n) }
          stmts.length == 1 ? stmts[0] : "(begin #{stmts.join(' ')})"
        else
          emit(br)
        end
      }
      "(begin #{branches.join(' ')})"
    when AST::ThenChain
      # Sequential evaluation: each step optionally binds a name
      parts = node.steps.map do |step|
        expr = emit(step[:expr])
        if step[:binding]
          "(define #{step[:binding]} #{expr})"
        else
          expr
        end
      end
      parts.length == 1 ? parts[0] : "(begin #{parts.join(' ')})"
    when AST::TestBlock
      # Run setup + each WHEN's setup + each TEST THAT body sequentially
      parts = node.setup.map { |n| emit(n) }
      node.whens.each do |w|
        parts += w.setup.map { |n| emit(n) }
        w.tests.each { |t| parts += t.body.map { |n| emit(n) } }
      end
      "(begin #{parts.join(' ')})"
    when AST::StaticCall
      # Type::method(args) -> (Type_method args...)
      fn = "#{node.type_name.name}_#{node.method_name}"
      args = node.args.map { |a| emit(a) }
      args.empty? ? "(#{fn})" : "(#{fn} #{args.join(' ')})"
    when AST::NextExpr
      # NEXT p -> identity (already resolved in sequential mode)
      emit(node.expr)
    when AST::WithBlock
      # WITH blocks - bind aliases and emit body
      bindings = []
      node.capabilities.each do |cap|
        if cap[:alias] && cap[:var_node]
          var = emit(cap[:var_node])
          bindings << "(define #{cap[:alias]} #{var})"
        end
      end
      body = node.body.map { |n| emit(n) }
      all = bindings + body
      all.length == 1 ? all[0] : "(begin #{all.join(' ')})"
    when NilClass
      "nil"
    else
      ";; unhandled: #{node.class.name}"
    end
  end

  def emit_literal(node)
    case node.type
    when :STRING, :string, :String
      "\"#{node.value}\""
    when :INT64, :i64, :Int64
      "#{node.value}:i64"
    when :INT, :FLOAT, :float, :f64, :Float64, :NUMBER
      node.value.to_s
    when :BOOL, :bool, :Bool, :TRUE, :FALSE
      node.value.to_s
    when :NIL, :nil
      "nil"
    else
      node.value.to_s
    end
  end

  def emit_struct_lit(node)
    name = node.name.to_s
    # Union construction: Shape{ Circle: 5.0 } -> (cons 'Circle 5.0)
    if @unions[name]
      variant = node.fields.keys.first
      payload = emit(node.fields.values.first)
      return "(cons (quote #{variant}) #{payload})"
    end
    # Struct construction with type-aware emission
    fields = @structs[name]
    return ";; unknown struct: #{name}" unless fields
    vals = fields.map { |f| node.fields[f] ? emit(node.fields[f]) : "nil" }

    # Typed struct emission blocked by compiler bug #2 (arena lifetime).
    # TypedI64Arr data inside Pair @indirect gets freed.
    # Fall back to untyped Vector for now.
    # TODO: emit typed-struct:i64/f64 when PromotionPlan is fixed.
    "(vector #{vals.join(' ')})"
  end

  def emit_get_field(node)
    target_name = node.target.is_a?(AST::Identifier) ? node.target.name.to_s : nil
    field = node.field.to_s

    # Enum variant: Direction.North -> (quote North)
    if target_name && @enums.include?(target_name)
      return "(quote #{field})"
    end

    # Union unit variant: Shape.Point -> (cons 'Point nil)
    if target_name && @unions[target_name]
      return "(cons (quote #{field}) nil)"
    end

    # Struct field access: p.x -> typed or generic access
    target = emit(node.target)
    target_name = node.target.is_a?(AST::Identifier) ? node.target.name.to_s : nil

    # Resolve via tracked variable type first
    struct_name = target_name ? @var_types[target_name] : nil
    if struct_name && @structs[struct_name]
      idx = @structs[struct_name].index(field)
      return "(vector-ref #{target} #{idx})" if idx
    end
    # Fallback: search all structs
    @structs.each do |_name, fields|
      idx = fields.index(field)
      return "(vector-ref #{target} #{idx})" if idx
    end
    ";; unknown field: #{field}"
  end

  def emit_assignment(node)
    if node.name.is_a?(AST::GetField)
      target = emit(node.name.target)
      field = node.name.field.to_s
      val = emit(node.value)
      @structs.each do |_name, fields|
        idx = fields.index(field)
        return "(vector-set! #{target} #{idx} #{val})" if idx
      end
      ";; unknown field assignment: #{field}"
    elsif node.name.is_a?(AST::GetIndex)
      # m["key"] = val -> (set! m (assoc-set m "key" val))
      target_name = node.name.target.is_a?(AST::Identifier) ? node.name.target.name.to_s : nil
      key = emit(node.name.index)
      val = emit(node.value)
      if target_name
        "(set! #{target_name} (assoc-set #{target_name} #{key} #{val}))"
      else
        ";; index assignment on non-identifier"
      end
    else
      "(set! #{node.name} #{emit(node.value)})"
    end
  end

  def emit_assert(node)
    cond = emit(node.condition)
    msg = (node.message.is_a?(String) && !node.message.empty?) ? node.message : "assertion failed"
    # Emit as: if not cond, raise error
    "(if (not #{cond}) (raise \"#{msg}\" \"Assert\") nil)"
  end

  def emit_match(node)
    subject = emit(node.expr)
    # Build nested if/else chain from cases
    emit_match_cases(subject, node.cases, node.default_case)
  end

  def emit_match_cases(subject, cases, default_case, idx = 0)
    if idx >= cases.length
      # Default case
      if default_case && !default_case.empty?
        body = default_case.map { |n| emit(n) }
        return body.length == 1 ? body[0] : "(begin #{body.join(' ')})"
      end
      return "nil"
    end

    c = cases[idx]
    pattern = c[:value]
    binding = c[:binding]
    body = c[:body].map { |n| emit(n) }
    body_expr = body.length == 1 ? body[0] : "(begin #{body.join(' ')})"
    rest = emit_match_cases(subject, cases, default_case, idx + 1)

    # Determine match condition based on pattern type
    if c[:kind] == :when
      # WHEN guard: condition is the pattern value
      cond = emit(pattern)
    elsif pattern.is_a?(AST::GetField)
      type_name = pattern.target.name.to_s
      variant = pattern.field.to_s

      if @enums.include?(type_name)
        cond = "(eq? #{subject} (quote #{variant}))"
      elsif @unions[type_name]
        cond = "(eq? (car #{subject}) (quote #{variant}))"
        if binding
          body_expr = "(begin (define #{binding} (cdr #{subject})) #{body_expr})"
        end
      else
        cond = "(= #{subject} #{emit(pattern)})"
      end
    elsif pattern.is_a?(AST::StructPattern)
      # Struct pattern: {x: 10, y: _, ...} -> check matching fields
      checks = []
      pattern.fields.each do |f|
        next if f[:value] == :wildcard
        # Find field index in any known struct
        field_name = f[:name]
        field_idx = nil
        @structs.each do |_sname, fields|
          idx = fields.index(field_name)
          if idx
            field_idx = idx
            break
          end
        end
        if field_idx
          checks << "(= (vector-ref #{subject} #{field_idx}) #{emit(f[:value])})"
        end
      end
      if checks.empty?
        cond = "true" # wildcard-only pattern always matches
      elsif checks.length == 1
        cond = checks[0]
      else
        # AND all checks: (if c1 (if c2 true false) false)
        cond = checks.reverse.reduce("true") { |acc, c| "(if #{c} #{acc} false)" }
      end
    elsif pattern.is_a?(AST::Literal)
      cond = "(= #{subject} #{emit(pattern)})"
    else
      cond = "(= #{subject} #{emit(pattern)})"
    end

    "(if #{cond} #{body_expr} #{rest})"
  end

  def emit_hash_lit(node)
    # HashMap -> assoc list: ((key . val) ...)
    pairs = node.pairs.map { |k, v| "(cons #{emit(k)} #{emit(v)})" }.join(" ")
    "(list #{pairs})"
  end

  def emit_list_lit(node)
    if node.items.empty?
      "(list)"
    else
      items = node.items.map { |i| emit(i) }.join(" ")
      "(list #{items})"
    end
  end

  def emit_get_index(node)
    target = emit(node.target)
    index = emit(node.index)
    target_name = node.target.is_a?(AST::Identifier) ? node.target.name.to_s : nil
    # HashMap or string-keyed access -> assoc-get
    if (target_name && @hash_vars.include?(target_name)) ||
       (node.index.is_a?(AST::Literal) && node.index.type == :STRING)
      "(assoc-get #{target} #{index})"
    else
      "(list-ref #{target} #{index})"
    end
  end

  def emit_for_range(node)
    @while_counter ||= 0
    @while_counter += 1
    fname = "__for#{@while_counter}"
    var = node.var_name
    start_expr = emit(node.start_expr)
    end_expr = emit(node.end_expr)
    body = node.body.map { |n| emit(n) }.join(" ")
    # FOR i IN (start ..< end) -> recursive lambda with counter
    "(begin (define #{fname} (lambda (#{var}) (if (< #{var} #{end_expr}) (begin #{body} (#{fname} (+ #{var} 1))) nil))) (#{fname} #{start_expr}))"
  end

  def emit_for_each(node)
    @while_counter ||= 0
    @while_counter += 1
    fname = "__each#{@while_counter}"
    idx = "__i#{@while_counter}"
    var = node.var_name
    coll = emit(node.collection)
    body = node.body.map { |n| emit(n) }.join(" ")
    # FOR item IN list -> recursive lambda iterating by index
    "(begin (define #{fname} (lambda (#{idx}) (if (< #{idx} (list-length #{coll})) (begin (define #{var} (list-ref #{coll} #{idx})) #{body} (#{fname} (+ #{idx} 1))) nil))) (#{fname} 0))"
  end

  def emit_func_call(node)
    name = node.name.to_s
    args = node.args.map { |a| emit(a) }.join(" ")

    # Map CLEAR builtins to Scheme equivalents
    case name
    when "print"
      "(display #{args})"
    when "eql?"
      "(= #{args})"
    when "readFile"
      "(sandboxed-read #{args})"
    when "writeFile"
      "(sandboxed-write #{args})"
    when "shell"
      "(sandboxed-shell #{args})"
    when "toFloat"
      "(int->float #{args})"
    when "toInt"
      "(float->int #{args})"
    when "floor"
      args
    else
      "(#{name} #{args})"
    end
  end

  def emit_method_call(node)
    target = emit(node.object)
    name = node.name.to_s
    args = node.args.map { |a| emit(a) }

    # Map CLEAR methods to Scheme
    case name
    when "toString"
      "(number->string #{target})"
    when "length"
      "(list-length #{target})"
    when "trim"
      "(trim #{target})"
    when "split"
      "(split #{target} #{args[0]})"
    when "append"
      # list.append(val) -> (set! list (list-push list val))
      # Need the raw target name for set!
      target_name = node.object.is_a?(AST::Identifier) ? node.object.name.to_s : nil
      val = args[0]
      if target_name
        "(set! #{target_name} (list-push #{target} #{val}))"
      else
        "(list-push #{target} #{val})"
      end
    else
      # UFCS: obj.method(args) -> (method obj args)
      all_args = ([target] + args).join(" ")
      "(#{name} #{all_args})"
    end
  end

  OP_MAP = {
    ADD: "+", SUB: "-", MUL: "*", DIV: "/", MOD: "modulo",
    EQ: "=", NEQ: "!=", LT: "<", GT: ">", LTE: "<=", GTE: ">=",
    AND: "and", OR: "or",
    CONCAT: "string-append",
  }

  def emit_binary(node)
    op = node.op

    # SMOOTH pipe: x s> fn -> (fn x), x s> fn(a) -> (fn x a)
    if op == :SMOOTH
      left = emit(node.left)
      return emit_pipe(left, node.right)
    end

    # OR_RESCUE: expr OR fallback
    if op == :OR_RESCUE
      left = emit(node.left)
      if node.right.is_a?(AST::OrRaise)
        # OR RAISE: just emit expr (errors propagate naturally)
        return left
      elsif node.right.is_a?(AST::OrPass)
        # OR PASS: catch error, return nil
        return "(try #{left} (catch __e nil))"
      else
        # OR value: catch error, return fallback
        fallback = emit(node.right)
        return "(try #{left} (catch __e #{fallback}))"
      end
    end

    left = emit(node.left)
    right = emit(node.right)

    scheme_op = OP_MAP[op]
    if scheme_op
      if op == :NEQ
        "(not (= #{left} #{right}))"
      elsif op == :AND
        "(if #{left} #{right} false)"
      elsif op == :OR
        "(if #{left} true #{right})"
      else
        "(#{scheme_op} #{left} #{right})"
      end
    else
      ";; unhandled op: #{op}"
    end
  end

  def emit_pipe(left, right)
    case right
    when AST::Identifier
      # x s> fn -> (fn x)
      "(#{right.name} #{left})"
    when AST::FuncCall
      # x s> fn(a, b) -> (fn x a b)
      args = right.args.map { |a| emit(a) }.join(" ")
      "(#{right.name} #{left} #{args})"
    when AST::WhereOp
      expr = emit_pipeline_expr(right.expression)
      "(list-where #{left} #{expr})"
    when AST::SelectOp
      expr = emit_pipeline_expr(right.expression)
      "(list-select #{left} #{expr})"
    when AST::ReduceOp
      # REDUCE uses 2-arg lambda (acc, item)
      expr = emit_pipeline_expr(right.expression, arity: 2)
      "(list-reduce #{left} #{emit(right.initial_value)} #{expr})"
    when AST::LimitOp
      "(list-limit #{left} #{emit(right.count)})"
    when AST::OrderByOp
      "(list-orderby #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::DistinctOp
      "(list-distinct #{left})"
    when AST::UnnestOp
      "(list-unnest #{left})"
    when AST::IndexOp
      "(list-index #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::CountOp
      if right.expression
        "(list-count #{left} #{emit_pipeline_expr(right.expression)})"
      else
        "(list-count #{left})"
      end
    when AST::SumOp
      "(list-sum #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::AverageOp
      "(list-avg #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::MinOp
      "(list-min #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::MaxOp
      "(list-max #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::FindOp
      "(list-find #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::AnyOp
      "(list-any #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::AllOp
      "(list-all #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::EachOp, AST::TapOp
      "(list-each #{left} #{emit_pipeline_expr(right.body)})"
    when AST::SkipOp
      "(list-skip #{left} #{emit(right.count)})"
    when AST::TakeWhileOp
      "(list-take-while #{left} #{emit_pipeline_expr(right.expression)})"
    when AST::BinaryOp
      # Chained pipe: x s> f s> g -> (g (f x))
      if right.op == :SMOOTH
        intermediate = emit_pipe(left, right.left)
        emit_pipe(intermediate, right.right)
      else
        "(#{emit(right)} #{left})"
      end
    else
      "(#{emit(right)} #{left})"
    end
  end

  def emit_pipeline_expr(expr, arity: 1)
    if expr.is_a?(AST::LambdaLit)
      emit_lambda_lit(expr)
    else
      # Bare expression using _ as implicit param. Wrap in lambda.
      body = emit(expr)
      if arity == 2
        "(lambda (acc _) #{body})"
      else
        "(lambda (_) #{body})"
      end
    end
  end

  def emit_lambda_lit(node)
    params = node.params.map { |p| p.is_a?(Hash) ? p[:name] : p.name }.join(" ")
    body = node.body.map { |n| emit(n) }
    body_expr = body.length == 1 ? body[0] : "(begin #{body.join(' ')})"
    "(lambda (#{params}) #{body_expr})"
  end

  def emit_raise(node)
    kind = node.kind.to_s
    msg = node.message_expr ? emit(node.message_expr) : "\"error\""
    "(raise #{msg} \"#{kind}\")"
  end

  def emit_unary(node)
    operand = emit(node.right)
    case node.op
    when :NOT, :BANG, :EXCL
      "(not #{operand})"
    when :SUB, :NEG
      "(- 0 #{operand})"
    else
      ";; unhandled unary: #{node.op}"
    end
  end

  def emit_if(node)
    cond = emit(node.condition)
    then_body = node.then_branch.map { |n| emit(n) }
    then_expr = then_body.length == 1 ? then_body[0] : "(begin #{then_body.join(' ')})"

    if node.else_branch && !node.else_branch.empty?
      else_body = node.else_branch.map { |n| emit(n) }
      else_expr = else_body.length == 1 ? else_body[0] : "(begin #{else_body.join(' ')})"
      "(if #{cond} #{then_expr} #{else_expr})"
    else
      "(if #{cond} #{then_expr} nil)"
    end
  end

  def emit_while(node)
    # CLEAR WHILE -> recursive lambda that captures outer env for set! mutations
    @while_counter ||= 0
    @while_counter += 1
    fname = "__loop#{@while_counter}"
    cond = emit(node.condition)
    body = node.do_branch.map { |n| emit(n) }.join(" ")
    "(begin (define #{fname} (lambda () (if #{cond} (begin #{body} (#{fname})) nil))) (#{fname}))"
  end
end

# --- Main (only when run directly) ---
if $PROGRAM_NAME == __FILE__ && ARGV.empty?
  $stderr.puts "Usage: ruby scheme_transpiler.rb <file.cht> [--run] [--bytecode] [--sExpression]"
  exit 1
end

if $PROGRAM_NAME == __FILE__
  run_mode = ARGV.delete("--run")
  bytecode_mode = ARGV.delete("--bytecode")
  sexpr_mode = ARGV.delete("--sExpression")
  source = File.read(ARGV[0])
  transpiler = SchemeTranspiler.new
  scheme = transpiler.transpile(source)

  if bytecode_mode
    # Emit bytecode format (ops + consts) for the exec! VM
    require_relative "bytecode_compiler"
    compiler = BytecodeCompiler.new
    result = compiler.compile_program(source)
    puts compiler.serialize

  elsif run_mode
    project_root = File.expand_path("../../", __dir__)
    interp_path = File.join(__dir__, "interpreter.cht")
    interp_src = File.read(interp_path)
    main_idx = interp_src.index(/^FN main\(\)/)
    interp_base = main_idx ? interp_src[0...main_idx] : interp_src
    completion_marker = "SCHEME: all expressions completed"

    fallback_to_sexpr = lambda do |reason|
      $stderr.puts "#{reason}, falling back to S-expression mode"
      lines = scheme.each_line.map(&:strip).reject(&:empty?)
      combined = lines.length == 1 ? lines[0] : "(begin #{lines.join(' ')})"
      escaped = combined.dump[1...-1]

      main_code = "FN main() RETURNS Void ->\n"
      main_code += "    MUTABLE pool: Env[50000]@pool = [];\n"
      main_code += "    MUTABLE penv: HashMap<Value> = {};\n"
      main_code += "    rootId = setupEnv!(pool);\n"
      main_code += "    MUTABLE schemeResult: Value = runTest!(\"#{escaped}\", rootId, pool, penv);\n"
      main_code += "    IF isError?(schemeResult) THEN print(\"SCHEME ASSERT FAILED: \" + getErrMsg(schemeResult)); END\n"
      main_code += "    IF isError?(schemeResult) == FALSE THEN print(\"#{completion_marker}\"); END\n"
      main_code += "    RETURN;\nEND\n"

      tmp_path = File.join(__dir__, "_scheme_run.cht")
      File.write(tmp_path, interp_base + main_code)
      output, = Open3.capture2e("#{project_root}/clear", "run", "--use-c-allocator", tmp_path)
      print output
    ensure
      File.delete(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path) && !ENV["SCHEME_DEBUG"]
    end

    # Compile to bytecode and run via exec!
    require_relative "bytecode_compiler"
    compiler = BytecodeCompiler.new
    begin
      result = compiler.compile_program(source)
      bc_txt = compiler.serialize
      ops_str = bc_txt.lines[0].chomp
      const_lines = bc_txt.lines[1..].map(&:chomp)

      ops_file = File.join(__dir__, "_bc_ops.txt")
      consts_file = File.join(__dir__, "_bc_consts.txt")
      File.write(ops_file, ops_str)
      File.write(consts_file, const_lines.join("\n"))

      main_code = <<~CHT
        FN main() RETURNS Void ->
            MUTABLE pool: Env[50000]@pool = [];
            MUTABLE penv: HashMap<Value> = {};
            rootId = setupEnv!(pool);
            bcOps = loadBytecodeOps!("#{ops_file}", pool);
            bcConsts = loadBytecodeConsts!("#{consts_file}", pool);
            bcResult = exec!(bcOps, bcConsts, rootId, pool);
            IF isError?(bcResult) THEN
                print("SCHEME ASSERT FAILED: " + getErrMsg(bcResult));
            ELSE
                print(prStr(bcResult, FALSE));
                print("SCHEME: all expressions completed");
            END
            RETURN;
        END
      CHT

      tmp_path = File.join(__dir__, "_scheme_run.cht")
      File.write(tmp_path, interp_base + main_code)
      output, status = Open3.capture2e("#{project_root}/clear", "run", "--use-c-allocator", tmp_path)
      if status.success? && output.include?(completion_marker)
        print output
      else
        reason = if status.success?
          "Bytecode execution did not complete cleanly"
        else
          "Bytecode execution failed"
        end
        fallback_to_sexpr.call(reason)
      end
    rescue => e
      fallback_to_sexpr.call("Bytecode compilation failed (#{e.message})")
    ensure
      File.delete(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path) && !ENV["SCHEME_DEBUG"]
      File.delete(ops_file) if defined?(ops_file) && ops_file && File.exist?(ops_file)
      File.delete(consts_file) if defined?(consts_file) && consts_file && File.exist?(consts_file)
    end

  elsif sexpr_mode
    # Emit S-expressions (the default output format)
    puts scheme

  else
    # Default: emit S-expressions
    puts scheme
  end
end
