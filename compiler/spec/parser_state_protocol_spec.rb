require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "ClearParser state-free grammar decisions" do
  def parser_for(source)
    ClearParser.new(Lexer.new(source).tokenize, source)
  end

  def parse_statement(source)
    parser_for(source).send(:parse_statement)
  end

  it "distinguishes MATCH destructuring from constructors by the arm boundary" do
    match = parse_statement("MATCH value START Shape.Circle{ radius } -> PASS; END")
    arm = match.cases.first

    expect(arm.value).to be_a(AST::GetField)
    expect(arm.destructure).to be_a(AST::StructPattern)
    expect(arm.destructure.fields.map(&:name)).to eq(["radius"])

    constructor = parser_for("Shape.Circle{ radius: 1_i64 }").send(:parse_expression)
    expect(constructor).to be_a(AST::UnionVariantLit)
  end

  it "peeks through nested generic arguments without moving the cursor" do
    parser = parser_for("<Pair<Int64, List<String>>>{")

    expect(parser.send(:peek_generic_angle_params?, "{")).to eq(true)
    expect(parser.instance_variable_get(:@pos)).to eq(0)
  end

  it "returns capability and reentrance REQUIRES products together" do
    source = <<~CLEAR
      FN apply(f: FN() -> Void, cell: Int64) RETURNS Void
        REQUIRES cell: LOCKED, f: NON_REENTRANT ->
        RETURN;
      END
    CLEAR
    fn = parser_for(source).parse.statements.first

    expect(fn.requires).to eq("cell" => Set[:LOCKED])
    expect(fn.requires_clauses).to eq("f" => :non_reentrant)
  end

  it "keeps typo diagnostics on the typed REQUIRES route" do
    source = "FN f(x: Int64) RETURNS Void REQUIRES x: LOCED -> RETURN; END"

    expect { parser_for(source).parse }.to raise_error(ParserError, /Unknown REQUIRES family/)
  end

  it "keeps binding applicability separate from suffix construction" do
    exists = parser_for("optional EXISTS").send(:parse_expression)
    expect(exists).to be_a(AST::UnaryOp)
    expect(exists.op).to eq(:EXISTS)

    expect { parser_for("future IS_READY AS value").send(:parse_expression) }
      .to raise_error(ParserError)
  end
end
