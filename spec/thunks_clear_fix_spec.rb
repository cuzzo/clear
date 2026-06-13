require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/ast/fixable_error" unless defined?(FixCollector)
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# Reentrance clear-fix coverage.
#
# Spec uses FixCollector directly (no integration with the CLI
# `clear fix` binary needed) to verify the finding shape for
# unconstrained FN-typed parameters. Legacy `@reentrant` migration
# no longer exists because the parser rejects the old annotation.

RSpec.describe "ReentranceBridge clear-fix findings" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotated(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  def findings(source)
    annotated(source)
    FixCollector.drain
  end

  it "offers no migration when EFFECTS REENTRANT is already used" do
    fs = findings(<<~CLEAR)
      FN walk(n: Int64) RETURNS Void
        EFFECTS REENTRANT ->
        IF n <= 0 -> RETURN;
        walk(n - 1);
      END
      FN main() RETURNS Void -> walk(3); RETURN; END
    CLEAR
    legacy_finding = fs.find { |f| f.message.include?("Legacy '@reentrant'") }
    expect(legacy_finding).to be_nil
  end

  it "offers no migration on a non-reentrant function" do
    fs = findings(<<~CLEAR)
      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    legacy_finding = fs.find { |f| f.message.include?("Legacy '@reentrant'") }
    expect(legacy_finding).to be_nil
  end

  describe "unconstrained FN-typed parameter fix (Phase 2)" do
    it "warns and offers two fixes: NON_REENTRANT (auto) and EFFECTS REENTRANT (interactive)" do
      fs = findings(<<~CLEAR)
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 ->
          RETURN f(x);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fs.find { |x| x.message.include?("unconstrained FN-typed parameter") }
      expect(f).not_to be_nil
      expect(f.level).to eq(:warning)
      expect(f.category).to eq(:lint)
      expect(f.fixes.length).to eq(2)
    end

    it "first fix adds REQUIRES NON_REENTRANT (auto, default for `clear fix --yes`)" do
      fs = findings(<<~CLEAR)
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 ->
          RETURN f(x);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fs.find { |x| x.message.include?("unconstrained FN-typed parameter") }
      first = f.fixes[0]
      expect(first.confidence).to eq(:auto)
      expect(first.description).to include("REQUIRES f: NON_REENTRANT")
      expect(first.edits.first.replacement).to eq("REQUIRES f: NON_REENTRANT ->")
    end

    it "second fix adds EFFECTS REENTRANT to the enclosing function (interactive)" do
      fs = findings(<<~CLEAR)
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 ->
          RETURN f(x);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fs.find { |x| x.message.include?("unconstrained FN-typed parameter") }
      second = f.fixes[1]
      expect(second.confidence).to eq(:interactive)
      expect(second.description).to include("'EFFECTS REENTRANT'")
      expect(second.edits.first.replacement).to eq("EFFECTS REENTRANT ->")
    end

    it "rejects legacy @reentrant on fn-type parameters before fixes are collected" do
      expect {
        findings(<<~CLEAR)
          FN applyReentrant(f: FN(Int64) -> Int64 @reentrant, x: Int64) RETURNS !Int64
            EFFECTS REENTRANT ->
            RETURN f(x);
          END
          FN main() RETURNS Void -> RETURN; END
        CLEAR
      }.to raise_error(ParserError)
    end

    it "skips parameters when the enclosing function declares EFFECTS REENTRANT" do
      fs = findings(<<~CLEAR)
        FN applyReentrant(f: FN(Int64) -> Int64, x: Int64) RETURNS !Int64
          EFFECTS REENTRANT ->
          RETURN f(x);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      legacy = fs.find { |x| x.message.include?("unconstrained FN-typed parameter") }
      expect(legacy).to be_nil
    end

    it "skips entirely when the enclosing function declares EFFECTS REENTRANT" do
      fs = findings(<<~CLEAR)
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS !Int64
          EFFECTS REENTRANT ->
          RETURN f(x);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      legacy = fs.find { |x| x.message.include?("unconstrained FN-typed parameter") }
      expect(legacy).to be_nil
    end

    it "skips when the enclosing function declares EFFECTS REENTRANT:THUNK" do
      # :THUNK requires self-recursion (Phase 4a validation), so use
      # a recursive callee to exercise the skip rule.
      fs = findings(<<~CLEAR)
        FN walk(f: FN(Int64) -> Int64, n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 0 -> RETURN 0;
          RETURN walk(f, n - 1);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      legacy = fs.find { |x| x.message.include?("unconstrained FN-typed parameter") }
      expect(legacy).to be_nil
    end

    it "skips parameters that already have a REQUIRES clause" do
      fs = findings(<<~CLEAR)
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS !Int64
          REQUIRES f: NON_REENTRANT ->
          RETURN f(x);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      legacy = fs.find { |x| x.message.include?("unconstrained FN-typed parameter") }
      expect(legacy).to be_nil
    end

    it "groups multiple unconstrained params into one finding with a chained replacement" do
      fs = findings(<<~CLEAR)
        FN both(f: FN(Int64) -> Int64, g: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 ->
          RETURN f(x) + g(x);
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fs.find { |x| x.message.include?("unconstrained FN-typed parameters") }
      expect(f).not_to be_nil
      expect(f.message).to include("(f, g)")
      first = f.fixes[0]
      expect(first.edits.first.replacement).to eq("REQUIRES f: NON_REENTRANT REQUIRES g: NON_REENTRANT ->")
      # The propagation fix is a single EFFECTS REENTRANT addition,
      # regardless of how many params are unconstrained.
      second = f.fixes[1]
      expect(second.edits.first.replacement).to eq("EFFECTS REENTRANT ->")
    end
  end
end
