require "spec_helper"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/mir/mir_lowering" unless defined?(MIRLowering)
require_relative "../src/mir/mir_checker" unless defined?(MIRChecker)
require_relative "../src/backends/mir_emitter" unless defined?(MIREmitter)

RSpec.describe "Clear value block expressions" do
  def parse_source(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  def first_main_bind(source, name)
    program = parse_source(source)
    main = program.statements.find { |stmt| stmt.respond_to?(:name) && stmt.name == "main" }
    raise "missing main" unless main

    main.body.find { |stmt| stmt.respond_to?(:name) && stmt.name.to_s == name.to_s }
  end

  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  def compile_and_check_mir(source)
    result = compile_mir_frontend(source)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: Dir.pwd,
      debug_mode: true
    ))
    program = lowering.lower_program(result.ast)
    errors = MIRChecker.new.check_program!(program)
    raise errors.join("\n") unless errors.empty?

    program
  end

  it "parses pipeline value blocks with statement prefixes and final expressions" do
    bind = first_main_bind(<<~CLEAR, "picked")
      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64];
        picked = nums |> SELECT { doubled = _ * 2_i64; doubled + 1_i64 };
        RETURN;
      END
    CLEAR

    select = bind.value.right
    block = select.expression

    expect(select).to be_a(AST::SelectOp)
    expect(block).to be_a(AST::BlockExpr)
    expect(block.body).to contain_exactly(an_instance_of(AST::BindExpr))
    expect(block.result).to be_a(AST::BinaryOp)
  end

  it "keeps hash literals distinct from value blocks" do
    bind = first_main_bind(<<~CLEAR, "table")
      FN main() RETURNS Void ->
        table = { "a": 1_i64, "b": 2_i64 };
        RETURN;
      END
    CLEAR

    expect(bind.value).to be_a(AST::HashLit)
  end

  it "parses single-expression value blocks without requiring prefix statements" do
    bind = first_main_bind(<<~CLEAR, "picked")
      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64];
        picked = nums |> SELECT { _ * 2_i64 };
        RETURN;
      END
    CLEAR

    block = bind.value.right.expression

    expect(block).to be_a(AST::BlockExpr)
    expect(block.body).to be_empty
    expect(block.result).to be_a(AST::BinaryOp)
  end

  it "parses expression and keyword statements before the final value" do
    bind = first_main_bind(<<~CLEAR, "picked")
      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64];
        picked = nums |> SELECT { _ + 1_i64; ASSERT _ > 0_i64, "positive"; _ * 2_i64 };
        RETURN;
      END
    CLEAR

    block = bind.value.right.expression

    expect(block).to be_a(AST::BlockExpr)
    expect(block.body.map(&:class)).to eq([AST::BinaryOp, AST::Assert])
    expect(block.result).to be_a(AST::BinaryOp)
  end

  it "parses typed locals inside value blocks as statements" do
    bind = first_main_bind(<<~CLEAR, "picked")
      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64];
        picked = nums |> SELECT { doubled: Int64 = _ * 2_i64; doubled + 1_i64 };
        RETURN;
      END
    CLEAR

    block = bind.value.right.expression

    expect(block).to be_a(AST::BlockExpr)
    expect(block.body.first).to be_a(AST::BindExpr)
    expect(block.body.first.type.to_s).to eq("Int64")
  end

  it "lowers pipeline value blocks and lambda value blocks through MIR" do
    compile_and_check_mir(<<~CLEAR)
      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64, 3_i64];
        picked = nums |> SELECT { doubled = _ * 2_i64; doubled + 1_i64 };
        filtered = nums |> WHERE { candidate = _ + 1_i64; candidate > 2_i64 };
        f = %(n: Int64) -> { inc = n + 1_i64; inc * 2_i64 };
        ASSERT picked[0] == 3_i64, "SELECT value block";
        ASSERT filtered.length() == 2_i64, "WHERE value block";
        ASSERT f(4_i64) == 10_i64, "lambda value block";
        RETURN;
      END
    CLEAR
  end

  it "discards expression prefix statements in emitted value blocks" do
    program = compile_and_check_mir(<<~CLEAR)
      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64, 3_i64];
        prefixed = nums |> SELECT { _ + 0_i64; _ * 2_i64 };
        ASSERT prefixed[1] == 4_i64, "expression prefix statement in value block";
        RETURN;
      END
    CLEAR

    zig = MIREmitter.new.emit(program)
    expect(zig).to match(/_ = CheatLib\.intAdd\(__it\d+, 0\);/)
  end

  it "rejects value blocks that have no final expression" do
    expect {
      parse_source(<<~CLEAR)
        FN main() RETURNS Void ->
          nums = [1_i64, 2_i64];
          picked = nums |> SELECT { doubled = _ * 2_i64; };
          RETURN;
        END
      CLEAR
    }.to raise_error(ParserError, /Unexpected token/)
  end

  it "rejects non-Bool pipeline predicates after value-block lowering" do
    expect {
      compile_and_check_mir(<<~CLEAR)
        FN main() RETURNS Void ->
          nums = [1_i64, 2_i64];
          filtered = nums |> WHERE { doubled = _ * 2_i64; doubled };
          RETURN;
        END
      CLEAR
    }.to raise_error(CompilerError, /WHERE clause must evaluate to Bool/)
  end

  it "covers nested and compound brace disambiguation after a top-level colon" do
    compound_parser = parser_for("{ x: T += y }")
    compound_tokens = compound_parser.instance_variable_get(:@tokens)
    compound_colon = compound_tokens.index { |token| token.type == :CHAR && token.value == ":" }
    expect(compound_parser.send(:top_level_assignment_before_brace_delimiter?, compound_colon + 1)).to eq(true)

    nested_parser = parser_for("{ x: (T = y), z: 1_i64 }")
    nested_tokens = nested_parser.instance_variable_get(:@tokens)
    nested_colon = nested_tokens.index { |token| token.type == :CHAR && token.value == ":" }
    expect(nested_parser.send(:top_level_assignment_before_brace_delimiter?, nested_colon + 1)).to eq(false)
  end
end
