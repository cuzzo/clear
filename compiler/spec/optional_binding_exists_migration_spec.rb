require "rspec"
require_relative "../ruby/ast/parser"

RSpec.describe "EXISTS optional-binding migration" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  it "uses the existing IfBind refinement node for EXISTS AS" do
    ast = parse("IF maybe EXISTS AS value THEN PASS; END")
    node = ast.statements.first
    expect(node).to be_a(AST::IfBind)
    expect(node.bindings.first.name).to eq("value")
  end

  it "uses the existing WhileBindLoop node for EXISTS AS" do
    ast = parse("WHILE nextValue() EXISTS AS value -> PASS;")
    expect(ast.statements.first).to be_a(AST::WhileBindLoop)
  end

  it "supports parenthesized optional-binding chains" do
    ast = parse("IF (left EXISTS AS a) AND (right EXISTS AS b) THEN PASS; END")
    expect(ast.statements.first).to be_a(AST::IfBind)
    expect(ast.statements.first.bindings.map(&:name)).to eq(%w[a b])
  end

  it "rejects legacy AS bindings and offers an exact automatic insertion" do
    source = "IF maybe AS value THEN PASS; END"
    expect { parse(source) }.to raise_error(ParserError, /must state its test/)

    FixCollector.enable!
    begin
      parse(source)
      finding = FixCollector.drain.find { |item| item.message.include?("must state its test") }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("EXISTS ")
      expect(edit.span.length).to eq(0)
    ensure
      FixCollector.disable!
    end
  end
end
