#!/usr/bin/env ruby
# Scheme transpiler: CLEAR source -> S-expression output
# Usage: ruby scheme_transpiler.rb program.cht
#
# Runs the CLEAR source through lexer -> parser -> annotator,
# then walks the AST and emits S-expressions for the Scheme interpreter.

$LOAD_PATH.unshift(File.expand_path("../../src", __dir__))

require "lexer"
require "parser"
require "ast"

class SchemeTranspiler
  def initialize
    @output = []
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
      when AST::FunctionDef
        if stmt.name == "main"
          # Emit main body as top-level expressions (skip bare returns)
          stmt.body.each do |node|
            next if node.is_a?(AST::ReturnNode) && node.value.nil?
            @output << emit(node)
          end
        else
          # Emit as (define name (lambda (params) body))
          params = stmt.params.map { |p| p.name }.join(" ")
          body = stmt.body.map { |n| emit(n) }
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
    when AST::BindExpr
      # x = expr -> (define x expr)
      "(define #{node.name} #{emit(node.value)})"
    when AST::Assignment
      # x = expr (reassignment) -> (set! x expr)
      "(set! #{node.name} #{emit(node.value)})"
    when AST::ReturnNode
      node.value ? emit(node.value) : "nil"
    when AST::IfStatement
      emit_if(node)
    when AST::WhileLoop
      emit_while(node)
    when AST::Assert
      "(assert #{emit(node.condition)} #{node.message ? "\"#{node.message}\"" : "\"assertion failed\""})"
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
    # CLEAR WHILE -> named let loop
    cond = emit(node.condition)
    body = node.do_branch.map { |n| emit(n) }.join(" ")
    "(let loop () (if #{cond} (begin #{body} (loop)) nil))"
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
  interp_path = File.join(File.dirname(ARGV[0]), "interpreter.cht")
  interp_src = File.read(interp_path)

  # Find main() and strip it + everything after (tests, benchmarks)
  main_idx = interp_src.index(/^FN main\(\)/)
  if main_idx
    interp_base = interp_src[0...main_idx]
  else
    interp_base = interp_src
  end

  # Generate main() that runs the S-expressions
  main_code = "FN main() RETURNS Void ->\n"
  main_code += "    MUTABLE pool: Env[50000]@pool = [];\n"
  main_code += "    MUTABLE penv: HashMap<Value> = {};\n"
  main_code += "    rootId = setupEnv!(pool);\n"

  scheme.each_line do |line|
    line = line.strip
    next if line.empty?
    escaped = line.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
    main_code += "    runTest!(\"#{escaped}\", rootId, pool, penv);\n"
  end

  main_code += "    RETURN;\nEND\n"

  tmp_path = File.join(File.dirname(ARGV[0]), "_scheme_run.cht")
  File.write(tmp_path, interp_base + main_code)

  system("#{project_root}/clear", "run", tmp_path)
  File.delete(tmp_path) if File.exist?(tmp_path)
else
  puts scheme
end
