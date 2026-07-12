require "rspec"
require_relative "../ruby/ast/parser"
require_relative "../ruby/annotator"

RSpec.describe "OR_ELSE fallback migration" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  it "lexes OR_ELSE as the fallback token and leaves legacy OR distinguishable" do
    tokens = Lexer.new("a OR_ELSE b; a OR b;").tokenize
    expect(tokens.select { |token| token.value == "OR_ELSE" }.map(&:type)).to eq([:OR_ELSE])
    expect(tokens.select { |token| token.value == "OR" }.map(&:type)).to eq([:KEYWORD])
  end

  it "parses OR_ELSE as the sole executable fallback operator" do
    ast = parse(<<~CLEAR)
      FN main() RETURNS Void ->
          maybe: ?Int64 = 1_i64;
          value = maybe OR_ELSE 0_i64;
          ASSERT value == 1_i64;
      END
    CLEAR

    fn = ast.statements.first
    value = fn.body.filter_map { |node| node.respond_to?(:value) ? node.value : nil }
              .find { |node| node.is_a?(AST::BinaryOp) && node.op == :OR_ELSE }
    expect(value).to be_a(AST::BinaryOp)
  end

  it "rejects legacy fallback OR with an exact automatic migration edit" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
          maybe: ?Int64 = 1_i64;
          value = maybe OR 0_i64;
      END
    CLEAR

    expect { parse(source) }
      .to raise_error(ParserError, /did you mean `OR_ELSE`/)

    FixCollector.enable!
    begin
      parse(source)
      finding = FixCollector.drain.find { |item| item.message.include?("did you mean `OR_ELSE`") }
      expect(finding).not_to be_nil
      fix = finding.fixes.fetch(0)
      expect(fix.confidence).to eq(:auto)
      expect(fix.edits.fetch(0).replacement).to eq("OR_ELSE")
      expect(fix.edits.fetch(0).span.length).to eq(2)
    ensure
      FixCollector.disable!
    end
  end

  it "types one fallback over both layers of !?T" do
    source = <<~CLEAR
      FN value(mode: Int64) RETURNS !?Int64 ->
          IF mode == 0_i64 THEN RAISE; END
          IF mode == 1_i64 THEN RETURN NIL; END
          RETURN 7_i64;
      END
      FN main() RETURNS Void ->
          n: Int64 = value(2_i64) OR_ELSE 3_i64;
          ASSERT n == 7_i64;
      END
    CLEAR

    ast = parse(source)
    SemanticAnnotator.new.annotate!(ast)
    fn = ast.statements.find { |node| node.respond_to?(:name) && node.name == "main" }
    fallback = fn.body.filter_map { |node| node.respond_to?(:value) ? node.value : nil }
                 .find { |node| node.is_a?(AST::BinaryOp) && node.op == :OR_ELSE }
    expect(fallback.full_type!.resolved).to eq(:Int64)
  end
end
