require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Field-access on a known struct with an unknown field used to raise a
# bare ILLEGAL_FIELD_LOOKUP. With a known schema we have the candidate
# set, so emit a typo-suggestion FixableFinding instead.
RSpec.describe "Struct field typo auto-fix" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "ILLEGAL_FIELD_LOOKUP with a near-miss field name" do
    let(:src) {
      <<~CLEAR
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = Point{x: 1, y: 2};
          _ = p.zz;
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /no field 'zz'/ }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that replaces 'zz' with the closest field name" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /no field 'zz'/ }
      edit = finding.fixes.first.edits.first
      # 'zz' is equidistant from 'x' and 'y' but Levenshtein ranking
      # prefers earlier candidate when ties — Point lists x first.
      expect(%w[x y]).to include(edit.replacement)
      expect(edit.span.length).to eq(2)  # length of 'zz'
      expect(edit.span.line).to eq(4)
    end

    it "applying the fix produces compilable CLEAR" do
      finding = nil
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /no field 'zz'/ }
      replacement = finding.fixes.first.edits.first.replacement
      fixed = src.sub("p.zz", "p.#{replacement}")
      expect { annotate(fixed) }.not_to raise_error
    end
  end

  describe "no near-miss candidate (fallback to plain error)" do
    let(:src) {
      <<~CLEAR
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = Point{x: 1, y: 2};
          _ = p.totallyDifferent;
        END
      CLEAR
    }

    it "raises plain CompilerError when no candidate is within Levenshtein threshold" do
      ann = SemanticAnnotator.new
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      FixCollector.disable!
      expect { ann.annotate!(ast) }.to raise_error(CompilerError, /no field|TYPO_SUGGESTION_REJECTED/)
    end
  end
end
