#!/usr/bin/env ruby
# Scheme transpiler: CLEAR source -> S-expression output
# Usage: ruby scheme_transpiler.rb program.cht
#
# Runs the CLEAR source through lexer -> parser -> annotator,
# then walks the AST and emits S-expressions for the Scheme interpreter.

$LOAD_PATH.unshift(File.expand_path("../../src", __dir__))

require "set"
require "lexer"
require "parser"
require "ast"

class SchemeTranspiler
  def initialize
    @output = []
    @structs = {}  # name -> [field_name, ...] (ordered)
    @enums = Set.new    # enum type names
    @unions = {}  # name -> {variant_name -> has_payload}
    @mutable_stack = [Set.new]  # stack of per-function mutable sets
  end

  def transpile(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    # Skip annotator for now - parser AST is enough for basic emission
    emit_program(ast)
    @output.join("\n")
  end

  private

  def mutables; @mutable_stack.last; end

  def emit_program(program)
    program.statements.each do |stmt|
      case stmt
      when AST::StructDef
        @structs[stmt.name.to_s] = stmt.fields.keys
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
            @output << emit(node)
          end
        else
          params = stmt.params.map { |p| p.is_a?(Hash) ? p[:name] : p.name }.join(" ")
          body = stmt.body.map { |n| emit(n) }.reject { |s| s == "nil" && stmt.body.last.is_a?(AST::ReturnNode) && stmt.body.last.value.nil? }
          body = ["nil"] if body.empty?
          if body.length == 1
            @output << "(define #{stmt.name} (lambda (#{params}) #{body[0]}))"
          else
            @output << "(define #{stmt.name} (lambda (#{params}) (begin #{body.join(' ')})))"
          end
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
    when AST::ListLit
      emit_list_lit(node)
    when AST::GetIndex
      emit_get_index(node)
    when AST::ForRange
      emit_for_range(node)
    when AST::BindExpr
      if mutables.include?(node.name.to_s)
        "(set! #{node.name} #{emit(node.value)})"
      else
        "(define #{node.name} #{emit(node.value)})"
      end
    when AST::VarDecl
      mutables.add(node.name.to_s) if node.mutable
      "(define #{node.name} #{node.value ? emit(node.value) : 'nil'})"
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
    when AST::Copy
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
    when :INT, :FLOAT, :int, :float, :i64, :f64, :Int64, :Float64
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
    # Struct construction: Point{ x: 10, y: 20 } -> (vector 10 20)
    fields = @structs[name]
    return ";; unknown struct: #{name}" unless fields
    vals = fields.map { |f| node.fields[f] ? emit(node.fields[f]) : "nil" }
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

    # Struct field access: p.x -> (vector-ref p idx)
    target = emit(node.target)
    @structs.each do |_name, fields|
      idx = fields.index(field)
      return "(vector-ref #{target} #{idx})" if idx
    end
    ";; unknown field: #{field}"
  end

  def emit_assignment(node)
    if node.name.is_a?(AST::GetField)
      # p.x = val -> (vector-set! p idx val)
      target = emit(node.name.target)
      field = node.name.field.to_s
      val = emit(node.value)
      @structs.each do |_name, fields|
        idx = fields.index(field)
        return "(vector-set! #{target} #{idx} #{val})" if idx
      end
      ";; unknown field assignment: #{field}"
    else
      "(set! #{node.name} #{emit(node.value)})"
    end
  end

  def emit_assert(node)
    cond = emit(node.condition)
    msg = node.message || "assertion failed"
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
    if pattern.is_a?(AST::GetField)
      type_name = pattern.target.name.to_s
      variant = pattern.field.to_s

      if @enums.include?(type_name)
        # Enum match: (eq? subject 'Variant)
        cond = "(eq? #{subject} (quote #{variant}))"
      elsif @unions[type_name]
        # Union match: (eq? (car subject) 'Variant)
        cond = "(eq? (car #{subject}) (quote #{variant}))"
        if binding
          # AS binding: bind payload to variable
          body_expr = "(begin (define #{binding} (cdr #{subject})) #{body_expr})"
        end
      else
        cond = "(= #{subject} #{emit(pattern)})"
      end
    elsif pattern.is_a?(AST::Literal)
      cond = "(= #{subject} #{emit(pattern)})"
    else
      cond = "(= #{subject} #{emit(pattern)})"
    end

    "(if #{cond} #{body_expr} #{rest})"
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
    "(list-ref #{target} #{index})"
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

  def emit_func_call(node)
    name = node.name.to_s
    args = node.args.map { |a| emit(a) }.join(" ")

    # Map CLEAR builtins to Scheme equivalents
    case name
    when "print"
      "(display #{args})"
    when "eql?"
      "(= #{args})"
    when "toFloat"
      args  # identity - all numbers are floats in scheme
    when "toInt"
      args  # identity
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
      # Could be string or list - emit list-length for now (works for both via dispatch)
      "(list-length #{target})"
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
    ADD: "+", SUB: "-", MUL: "*", DIV: "/", MOD: "%",
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
    when :NOT, :BANG
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
  $stderr.puts "Usage: ruby scheme_transpiler.rb <file.cht> [--run]"
  exit 1
end

if $PROGRAM_NAME == __FILE__
  run_mode = ARGV.delete("--run")
  source = File.read(ARGV[0])
  transpiler = SchemeTranspiler.new
  scheme = transpiler.transpile(source)

  if run_mode
  # Read the interpreter source, strip everything from main() onward,
  # and replace with a main() that executes the transpiled S-expressions.
  project_root = File.expand_path("../../", __dir__)
  interp_path = File.join(__dir__, "interpreter.cht")
  interp_src = File.read(interp_path)

  # Find main() and strip it + everything after (tests, benchmarks)
  main_idx = interp_src.index(/^FN main\(\)/)
  if main_idx
    interp_base = interp_src[0...main_idx]
  else
    interp_base = interp_src
  end

  # Wrap all S-expressions in a single (begin ...) to share one frame arena.
  # This avoids vector/list values being freed between separate runTest! calls.
  lines = scheme.each_line.map(&:strip).reject(&:empty?)
  if lines.length == 1
    combined = lines[0]
  else
    combined = "(begin #{lines.join(' ')})"
  end
  escaped = combined.gsub('\\', '\\\\\\\\').gsub('"', '\\"')

  main_code = "FN main() RETURNS Void ->\n"
  main_code += "    MUTABLE pool: Env[50000]@pool = [];\n"
  main_code += "    MUTABLE penv: HashMap<Value> = {};\n"
  main_code += "    rootId = setupEnv!(pool);\n"
  main_code += "    MUTABLE schemeResult: Value = runTest!(\"#{escaped}\", rootId, pool, penv);\n"
  main_code += "    IF isError?(schemeResult) THEN print(\"SCHEME ASSERT FAILED: \" + getErrMsg(schemeResult)); END\n"
  main_code += "    IF isError?(schemeResult) == FALSE THEN print(\"SCHEME: all expressions completed\"); END\n"

  main_code += "    RETURN;\nEND\n"

  tmp_path = File.join(__dir__, "_scheme_run.cht")
  File.write(tmp_path, interp_base + main_code)

  system("#{project_root}/clear", "run", tmp_path)
  File.delete(tmp_path) if File.exist?(tmp_path) && !ENV["SCHEME_DEBUG"]
  else
    puts scheme
  end
end
