require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)

# Thunk Phase 4f.2 -- EFFECTS REENTRANT:NOT_LOGICAL.
#
# `:NOT_LOGICAL` declares that the function asserts (at runtime)
# the recursion is logically impossible. The compiler can't prove
# it. We compile in the existing `safety.StackGuard` prologue; it raises
# `error.UnexpectedRecursion` (System) if the function re-enters.
# Because the guard CAN raise, the function MUST declare an
# error-union return type (`!T`).

RSpec.describe "Thunk Phase 4f.2 -- :NOT_LOGICAL" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    ClearParser.new(tokens, source).parse
  end

  def annotate(source)
    ast = parse(source)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  describe "parser" do
    it "accepts EFFECTS REENTRANT:NOT_LOGICAL" do
      ast = parse(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN n + 1;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.effects_decl).to eq(:reentrant_not_logical)
    end

    it "rejects unknown variants with the updated valid-set message" do
      expect {
        parse(<<~CLEAR)
          FN f(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:BOGUS ->
            RETURN n + 1;
          END
        CLEAR
      }.to raise_error(/Unknown REENTRANT variant 'BOGUS'/)
    end

    it "saves an effects_span covering the full clause text" do
      ast = parse(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN n + 1;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.effects_span).to be_a(AST::EffectSpan)
      expect(fn.effects_span.start_token.value).to eq("EFFECTS")
      expect(fn.effects_span.end_token.value).to eq("NOT_LOGICAL")
    end
  end

  describe "annotator validation" do
    it "compiles when return type is !T" do
      expect {
        annotate(<<~CLEAR)
          FN f(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:NOT_LOGICAL ->
            RETURN n + 1;
          END
          FN main() RETURNS Void -> _ = TRY f(0_i64); RETURN; END
        CLEAR
      }.not_to raise_error
    end

    it "rejects bare T return (no error union)" do
      expect {
        annotate(<<~CLEAR)
          FN f(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:NOT_LOGICAL ->
            RETURN n + 1;
          END
          FN main() RETURNS Void -> _ = f(0_i64); RETURN; END
        CLEAR
      }.to raise_error(/error-union return type.*!Int64/m)
    end

    it "rejects implicit Void return" do
      expect {
        annotate(<<~CLEAR)
          FN f(n: Int64)
            EFFECTS REENTRANT:NOT_LOGICAL ->
            _ = n + 1;
            RETURN;
          END
          FN main() RETURNS Void -> f(0_i64); RETURN; END
        CLEAR
      }.to raise_error(/error-union return type.*!Void/m)
    end

    it "stamps reentrance_kind = :reentrant_not_logical and requires a guard" do
      ast = annotate(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:NOT_LOGICAL ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> _ = TRY f(0_i64); RETURN; END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "f" }
      expect(fn.reentrance_kind).to eq(:reentrant_not_logical)
      expect(fn.reentrance_guard_required?).to be(true)
    end
  end

  describe "fixable mutual-recursion error" do
    let(:src) {
      <<~CLEAR
        FN a(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 0 -> RETURN 1;
          RETURN n * b(n - 1);
        END
        FN b(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 0 -> RETURN 1;
          RETURN n * a(n - 1);
        END
        FN main() RETURNS Void -> _ = a(4_i64); RETURN; END
      CLEAR
    }

    after { FixCollector.disable! }

    def collect_findings(source)
      FixCollector.enable!
      tokens = Lexer.new(source).tokenize
      ast = ClearParser.new(tokens, source).parse
      SemanticAnnotator.new.annotate!(ast) rescue nil
      FixCollector.drain
    end

    it "emits a fixable finding with two interactive migrations" do
      finds = collect_findings(src).select { |f| f.category == :reentrance }
      expect(finds.length).to be >= 1
      finding = finds.first
      expect(finding.message).to match(/EFFECTS REENTRANT:NOT_LOGICAL/)
      descriptions = finding.fixes.map(&:description)
      expect(descriptions).to include(match(/Drop ':THUNK'/))
      expect(descriptions).to include(match(/:NOT_LOGICAL/))
    end

    it "the :NOT_LOGICAL fix prepends `!` to each return type" do
      finds = collect_findings(src).select { |f| f.category == :reentrance }
      finding = finds.first
      nl_fix = finding.fixes.find { |fx| fx.description.include?(":NOT_LOGICAL") }
      bang_inserts = nl_fix.edits.select { |e| e.replacement == "!" }
      expect(bang_inserts.length).to eq(2) # one per cycle member
    end
  end
end
