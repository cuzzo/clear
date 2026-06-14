require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)

RSpec.describe "ClearParser mutable fixed-array defaults" do
  def parse_main_body(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    ast.statements.find { |node| node.is_a?(AST::FunctionDef) && node.name == "main" }.body
  end

  it "keeps bare mutable fixed primitive array defaults compact" do
    body = parse_main_body(<<~CLEAR)
      FN main() RETURNS Void ->
        MUTABLE ints: Int64[2];
        MUTABLE floats: Float64[2];
        MUTABLE strings: String[2];
        MUTABLE bools: Bool[2];
        RETURN;
      END
    CLEAR

    defaults = body.select { |node| node.is_a?(AST::VarDecl) }.map { |decl|
      [decl.name, [decl.value.class, decl.value.full_type.resolved, decl.value.full_type.capacity, decl.value.storage]]
    }.to_h

    expect(defaults.fetch("ints")).to eq([AST::DefaultArrayLit, :"Int64[2]", 2, :stack])
    expect(defaults.fetch("floats")).to eq([AST::DefaultArrayLit, :"Float64[2]", 2, :stack])
    expect(defaults.fetch("strings")).to eq([AST::DefaultArrayLit, :"String[2]", 2, :stack])
    expect(defaults.fetch("bools")).to eq([AST::DefaultArrayLit, :"Bool[2]", 2, :stack])
  end

  it "reports return values as expression children" do
    value = AST::Literal.new(nil, :INT64, 1, nil)
    ret = AST::ReturnNode.new(nil, value)

    expect(AST.expression_children(ret)).to eq([value])
  end

  it "coerces fixed-array defaults through their target type" do
    lit = AST::DefaultArrayLit.new(nil, Type.array_of(:Int64, capacity: 2), :stack)

    expect(lit.coerce!(Type.array_of(:Int64, capacity: 2))).to eq([:"Int64[2]", nil])

    coerced, error = lit.coerce!(Type.array_of(:String, capacity: 2))
    expect(coerced).to be_nil
    expect(error).to include("Cannot initialize array of size 2 with 2 elements")
  end

  it "rejects bare mutable declarations without a fixed primitive array type" do
    expect {
      parse_main_body(<<~CLEAR)
        STRUCT Box { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE boxes: Box[2];
          RETURN;
        END
      CLEAR
    }.to raise_error(ParserError, /cannot default-init element type|bare declaration/i)

    expect {
      parse_main_body(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE values: Int64[];
          RETURN;
        END
      CLEAR
    }.to raise_error(ParserError, /MUTABLE_BARE_NEEDS_FIXED|fixed/i)
  end
end
