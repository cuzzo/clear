require "rspec"
require_relative "../ruby/ast/parser"
require_relative "../ruby/annotator"

RSpec.describe "AND/OR logical keyword migration" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  it "lexes canonical keywords and keeps legacy glyphs distinguishable" do
    tokens = Lexer.new("a AND b OR c; a && b || c;").tokenize
    expect(tokens.select { |token| %w[AND OR].include?(token.value) }.map(&:type)).to eq(%i[KEYWORD KEYWORD])
    expect(tokens.select { |token| %w[&& ||].include?(token.value) }.map(&:type)).to eq(%i[LEGACY_LOGICAL LEGACY_LOGICAL])
  end

  it "parses AND tighter than OR and preserves short-circuit nodes" do
    ast = parse(<<~CLEAR)
      FN main() RETURNS Void ->
          result = TRUE OR FALSE AND FALSE;
          ASSERT result;
      END
    CLEAR
    expr = ast.statements.first.body.first.value
    expect(expr.op).to eq(:OR)
    expect(expr.right).to be_a(AST::BinaryOp)
    expect(expr.right.op).to eq(:AND)
  end

  it "rejects legacy glyphs with exact automatic edits" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
          result = TRUE && FALSE || TRUE;
      END
    CLEAR
    expect { parse(source) }.to raise_error(ParserError, /did you mean `AND`/)

    FixCollector.enable!
    begin
      parse(source)
      edits = FixCollector.drain.flat_map { |finding| finding.fixes.fetch(0).edits }
      expect(edits.map(&:replacement)).to include("AND", "OR")
      expect(edits.map { |edit| edit.span.length }).to all(eq(2))
    ensure
      FixCollector.disable!
    end
  end

  it "short-circuits both operators" do
    ast = parse(<<~CLEAR)
      FN explode() RETURNS Bool -> ASSERT FALSE; TRUE; END
      FN main() RETURNS Void ->
          a = TRUE OR explode();
          b = FALSE AND explode();
          ASSERT a AND !(b);
      END
    CLEAR
    SemanticAnnotator.new.annotate!(ast)
  end
end
