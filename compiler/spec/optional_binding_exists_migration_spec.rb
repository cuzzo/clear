require "rspec"
require_relative "../ruby/ast/parser"
require_relative "../ruby/annotator"

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

  it "parses postfix EXISTS as an ordinary Bool expression" do
    ast = parse(<<~CLEAR)
      FN main(value: ?Int64) RETURNS Bool ->
        present = value EXISTS;
        RETURN present AND (value EXISTS);
      END
    CLEAR
    SemanticAnnotator.new.annotate!(ast)
    first = ast.statements.first.body.first.value
    expect(first).to be_a(AST::UnaryOp)
    expect(first.op).to eq(:EXISTS)
    expect(first.resolved_type).to eq(:Bool)
  end

  it "rejects EXISTS on non-optional values" do
    ast = parse("FN main(value: Int64) RETURNS Bool -> RETURN value EXISTS; END")
    expect { SemanticAnnotator.new.annotate!(ast) }
      .to raise_error(CompilerError, /EXISTS.*requires an optional value/)
  end

  it "uses non-Bool optionals as presence operands for AND and OR" do
    ast = parse(<<~CLEAR)
      FN main(name: ?String, enabled: Bool) RETURNS Bool ->
        RETURN name OR enabled AND name;
      END
    CLEAR
    SemanticAnnotator.new.annotate!(ast)
    expect(ast.statements.first.body.first.value.resolved_type).to eq(:Bool)
  end

  it "rejects ambiguous ?Bool logic with presence and payload fixes" do
    source = "FN main(flag: ?Bool, y: Bool) RETURNS Bool -> RETURN flag OR y; END"
    ast = parse(source)
    FixCollector.enable!
    begin
      SemanticAnnotator.new(source_code: source).annotate!(ast)
      finding = FixCollector.drain.find { |item| item.message.include?("Ambiguous ?Bool") }
      expect(finding).not_to be_nil
      expect(finding.fixes.map { |fix| fix.edits.first.replacement })
        .to eq(["flag EXISTS", "(flag OR_ELSE FALSE)"])
    ensure
      FixCollector.disable!
    end
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
