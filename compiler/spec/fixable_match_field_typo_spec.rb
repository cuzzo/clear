require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# A MATCH struct-pattern that names a field the schema doesn't declare
# now offers a typo-suggestion fix. Covers two pattern shapes:
#   { fieldName: <value> }     — value match (A2)
#   { fieldName }              — destructuring bind  (A3)
RSpec.describe "MATCH-pattern field typo auto-fix" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "MATCH_FIELD_UNKNOWN — value-match form { x: 1 } typo as { xs: 1 }" do
    let(:src) {
      <<~CLEAR
        STRUCT P { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = P{x: 1, y: 2};
          PARTIAL MATCH p
              START { xs: 1 } -> _ = "hi";,
              DEFAULT -> _ = "bye";
          END
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /'xs'/ }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit replacing 'xs' with the closest field name" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /'xs'/ }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("x")
      expect(edit.span.length).to eq(2)  # 'xs'
      expect(edit.span.line).to eq(5)
    end

    it "applying the fix produces compilable CLEAR" do
      fixed = src.sub("xs: 1", "x: 1")
      expect { annotate(fixed) }.not_to raise_error
    end
  end

  describe "MATCH_FIELD_UNKNOWN — destructure form { x } typo as { xx }" do
    let(:src) {
      <<~CLEAR
        STRUCT P { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = P{x: 1, y: 2};
          PARTIAL MATCH p
              START { xx } -> _ = "hi";,
              DEFAULT -> _ = "bye";
          END
        END
      CLEAR
    }

    it "captures a fixable finding with a typo suggestion" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /'xx'/ }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("x")
      expect(edit.span.length).to eq(2)
    end
  end

  describe "MATCH_DESTRUCTURE_FIELD_UNKNOWN — union variant destructure typo" do
    let(:src) {
      <<~CLEAR
        UNION Shape { Circle { radius: Float64 }, Square }
        FN main() RETURNS Void ->
          c: Shape = Shape.Circle{radius: 5.0};
          MUTABLE r = 0.0;
          PARTIAL MATCH c
              START Shape.Circle{ radiu } -> r = radiu;,
              DEFAULT -> r = 0.0;
          END
        END
      CLEAR
    }

    it "produces a typo-suggestion edit for the missing variant field" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /'radiu'/ }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("radius")
      expect(edit.span.length).to eq(5)  # 'radiu'
    end
  end

  describe "no near-miss candidate (fallback to plain error)" do
    let(:src) {
      <<~CLEAR
        STRUCT P { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = P{x: 1, y: 2};
          PARTIAL MATCH p
              START { somethingDifferent: 1 } -> _ = "hi";,
              DEFAULT -> _ = "bye";
          END
        END
      CLEAR
    }

    it "raises plain CompilerError when no candidate is within Levenshtein threshold" do
      ann = SemanticAnnotator.new
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      FixCollector.disable!
      expect { ann.annotate!(ast) }.to raise_error(CompilerError, /does not exist on type|TYPO_SUGGESTION_REJECTED|somethingDifferent/i)
    end
  end
end
