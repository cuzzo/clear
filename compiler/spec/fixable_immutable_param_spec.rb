require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# When a function body mutates a parameter the caller declared
# without `MUTABLE`, three errors can fire depending on the mutation
# shape: ASSIGN_VAR_IMMUTABLE (`p = ...`), ASSIGN_INDEX_IMMUTABLE_LIST
# (`p[i] = ...` — also fires for HashMap), and
# IMMUTABLE_FIELD_ASSIGNMENT (`p.field = ...`). All three now emit
# a FixableFinding whose :auto fix inserts `MUTABLE ` at the
# parameter's declaration column in the function signature.
RSpec.describe "Immutable param auto-fix" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "ASSIGN_INDEX_IMMUTABLE_LIST on a HashMap parameter" do
    let(:src) {
      <<~CLEAR
        FN parseValue!(json: String, penv: {String}Int64) RETURNS Void ->
          penv["__jp"] = 0;
        END
        FN main() RETURNS Void -> END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /immutable/i }
      expect(findings.size).to be >= 1
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit that inserts `MUTABLE ` at the param column" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /immutable/i }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("MUTABLE ")
      expect(edit.span.line).to eq(1)
      # `FN parseValue!(json: String, penv: HashMap<Int64>) ...`
      # The 'penv' identifier starts at column 30 (1-indexed); insert
      # before it.
      expect(edit.span.col).to eq(30)
      expect(edit.span.length).to eq(0)
    end

    it "applying the fix produces compilable CLEAR" do
      fixed = src.sub("penv: HashMap", "MUTABLE penv: HashMap")
      expect { annotate(fixed) }.not_to raise_error
    end
  end

  describe "ASSIGN_VAR_IMMUTABLE on a scalar parameter" do
    let(:src) {
      <<~CLEAR
        FN bump(p: Int64) RETURNS Int64 ->
          p = p + 1;
          RETURN p;
        END
        FN main() RETURNS Void -> END
      CLEAR
    }

    it "produces a MUTABLE-insert edit at the param column" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /immutable/i }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("MUTABLE ")
      expect(edit.span.line).to eq(1)
      # `FN bump(p: Int64)` — 'p' starts at column 9.
      expect(edit.span.col).to eq(9)
    end
  end

  describe "IMMUTABLE_FIELD_ASSIGNMENT on a struct parameter" do
    let(:src) {
      <<~CLEAR
        STRUCT Point { x: Int64, y: Int64 }
        FN shift(pt: Point) RETURNS Void ->
          pt.x = 10;
        END
        FN main() RETURNS Void -> END
      CLEAR
    }

    it "produces a MUTABLE-insert edit at the param column" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /immutable/i }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("MUTABLE ")
      expect(edit.span.line).to eq(2)
      # `FN shift(pt: Point)` — 'pt' starts at column 10.
      expect(edit.span.col).to eq(10)
    end
  end

  describe "fallback when the param has no decl token" do
    it "ASSIGN_VAR_IMMUTABLE — falls back to plain error! when no fix is locatable" do
      src = "FN bump(p: Int64) RETURNS Int64 ->\n  p = p + 1;\n  RETURN p;\nEND\nFN main() RETURNS Void -> END"
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      ann = SemanticAnnotator.new
      allow(ann).to receive(:build_declare_mutable_fix).and_return(nil)
      FixCollector.disable!
      expect { ann.annotate!(ast) }.to raise_error(CompilerError, /immutable/i)
    end
  end
end
