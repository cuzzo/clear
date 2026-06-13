require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Tier 2 fixable findings. Five additional error sites that previously
# raised a plain CompilerError now emit a FixableFinding.
RSpec.describe "Tier 2 fixable findings" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "CAPTURE_IMMUTABLE_AS_MUTABLE" do
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          x = 5;
          FN g() USE(MUTABLE x) RETURNS Int64 -> RETURN x; END
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /capture immutable/i }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that inserts MUTABLE at the captured binding's declaration" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /capture immutable/i }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("MUTABLE ")
      expect(edit.span.line).to eq(2)  # the `  x = 5;` line
      expect(edit.span.length).to eq(0)
    end
  end

  describe "AMBIGUOUS_RETURN" do
    let(:src) {
      <<~CLEAR
        FN classify(n: Int64) ->
          IF n > 0 THEN RETURN n; ELSE RETURN "negative"; END
        END
        FN main() RETURNS Void ->
          _ = classify(1);
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /Ambiguous Return|multiple types/ }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that inserts `RETURNS :Any ` before the arrow" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /Ambiguous Return|multiple types/ }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("RETURNS :Any ")
      expect(edit.span.length).to eq(0)
    end
  end

  describe "MATCH_NEEDS_ENUM_OR_UNION" do
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          x: Int64 = 5;
          MATCH x START
            5 -> _ = 0;
          END
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /MATCH requires/ }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that inserts `PARTIAL ` before the MATCH keyword" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /MATCH requires/ }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("PARTIAL ")
      expect(edit.span.length).to eq(0)
    end
  end

  describe "MATCH_NON_EXHAUSTIVE" do
    let(:src) {
      <<~CLEAR
        ENUM Color { Red, Green, Blue }
        FN main() RETURNS Void ->
          c: Color = Color.Red;
          MATCH c START
            Color.Red -> _ = 0;
          END
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /non-exhaustive/ }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces the same `PARTIAL ` insertion as MATCH_NEEDS_ENUM_OR_UNION" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /non-exhaustive/ }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("PARTIAL ")
    end
  end

  describe "RETURN_BORROWED_NO_COPY_OR_LIFETIME" do
    let(:src) {
      <<~CLEAR
        UNION Val { Nil, Name: String }
        STRUCT Foo { v: Val }
        FN getVal(f: Foo) RETURNS Val ->
          v = f.v;
          RETURN v;
        END
        FN main() RETURNS Void ->
          fb = Foo{ v: Val.Nil };
          _ = getVal(fb);
        END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /not implicitly copyable|return borrowed/i }
      expect(findings.size).to be >= 1
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that inserts `COPY ` before the returned value" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /not implicitly copyable|return borrowed/i }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("COPY ")
      expect(edit.span.length).to eq(0)
    end
  end

  describe "fallback paths" do
    it "AMBIGUOUS_RETURN — falls back to plain error! when arrow_token is missing" do
      tokens = Lexer.new("FN classify(n: Int64) ->\n  IF n > 0 THEN RETURN n; ELSE RETURN \"x\"; END\nEND\nFN main() RETURNS Void -> END").tokenize
      src = "FN classify(n: Int64) ->\n  IF n > 0 THEN RETURN n; ELSE RETURN \"x\"; END\nEND\nFN main() RETURNS Void -> END"
      ast = ClearParser.new(tokens, src).parse
      # Strip arrow_token from the synthesized fn so the helper falls
      # through to plain error!.
      classify = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "classify" }
      classify.arrow_token = nil
      ann = SemanticAnnotator.new
      FixCollector.disable!  # raise instead of collect
      expect { ann.annotate!(ast) }.to raise_error(CompilerError, /Ambiguous Return|multiple types/)
    end
  end
end
