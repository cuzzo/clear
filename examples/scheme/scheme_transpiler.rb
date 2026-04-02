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
    @structs = {}  # name -> [field_name, field_name, ...] (ordered)
    @mutables = Set.new  # names declared as MUTABLE
  end

  def transpile(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    # Skip annotator for now - parser AST is enough for basic emission
    emit_program(ast)
    @output.join("\n")
  end

  private

  def emit_program(program)
    program.statements.each do |stmt|
      case stmt
      when AST::StructDef
        # Register struct schema (field order matters for vector indexing)
        @structs[stmt.name.to_s] = stmt.fields.keys
      when AST::FunctionDef
        if stmt.name == "main"
          # Emit main body as top-level expressions (skip bare returns)
          stmt.body.each do |node|
            next if node.is_a?(AST::ReturnNode) && node.value.nil?
            @output << emit(node)
          end
        else
          # Emit as (define name (lambda (params) body))
          params = stmt.params.map { |p| p.is_a?(Hash) ? p[:name] : p.name }.join(" ")
          body = stmt.body.map { |n| emit(n) }.reject { |s| s == "nil" && stmt.body.last.is_a?(AST::ReturnNode) && stmt.body.last.value.nil? }
          body = ["nil"] if body.empty?
          if body.length == 1
            @output << "(define #{stmt.name} (lambda (#{params}) #{body[0]}))"
          else
            @output << "(define #{stmt.name} (lambda (#{params}) (begin #{body.join(' ')})))"
          end
        end
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
    when AST::BindExpr
      if @mutables.include?(node.name.to_s)
        "(set! #{node.name} #{emit(node.value)})"
      else
        "(define #{node.name} #{emit(node.value)})"
      end
    when AST::VarDecl
      @mutables.add(node.name.to_s) if node.mutable
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
    fields = @structs[name]
    return ";; unknown struct: #{name}" unless fields
    # Emit fields in schema order as a vector
    vals = fields.map { |f| node.fields[f] ? emit(node.fields[f]) : "nil" }
    "(vector #{vals.join(' ')})"
  end

  def emit_get_field(node)
    target = emit(node.target)
    field = node.field.to_s
    # Look up field index from struct schema
    # We need to know the struct type of the target - for now, search all schemas
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

  def emit_func_call(node)
    name = node.name.to_s
    args = node.args.map { |a| emit(a) }.join(" ")

    # Map CLEAR builtins to Scheme equivalents
    case name
    when "print"
      "(display #{args})"
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
      "(string-length #{target})"
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
    left = emit(node.left)
    right = emit(node.right)
    op = node.op

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

  def emit_unary(node)
    operand = emit(node.right)
    case node.op.to_s
    when "!", "NOT"
      "(not #{operand})"
    when "-"
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

# --- Main ---
if ARGV.empty?
  $stderr.puts "Usage: ruby scheme_transpiler.rb <file.cht> [--run]"
  exit 1
end

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
