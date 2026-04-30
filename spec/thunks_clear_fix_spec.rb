require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Thunk Phase 1.4 — `clear fix` migration that rewrites the legacy
# `@reentrant` / `@reentrant:tailCall` annotation to the new
# `EFFECTS REENTRANT[:TAIL_CALL]` clause.
#
# Spec uses FixCollector directly (no integration with the CLI
# `clear fix` binary needed) to verify the finding shape, edit
# spans, and replacement text.

RSpec.describe "ReentranceBridge clear-fix migration" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotated(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
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

  it "emits an :auto fix for `@reentrant` -> `EFFECTS REENTRANT`" do
    fs = findings(<<~CLEAR)
      FN walk(n: Int64) RETURNS Void @reentrant ->
        IF n <= 0 -> RETURN;
        walk(n - 1);
      END
      FN main() RETURNS Void -> walk(3); RETURN; END
    CLEAR
    f = fs.find { |x| x.message.include?("Legacy '@reentrant'") }
    expect(f).not_to be_nil
    expect(f.level).to eq(:info)
    expect(f.category).to eq(:lint)
    expect(f.message).to match(/migrate to 'EFFECTS REENTRANT'/)
    fix = f.fixes.first
    expect(fix.confidence).to eq(:auto)
    expect(fix.edits.length).to eq(1)
    edit = fix.edits.first
    expect(edit.replacement).to eq("EFFECTS REENTRANT")
    expect(edit.span.length).to eq("@reentrant".length)
  end

  it "emits an :auto fix for `@reentrant:tailCall` -> `EFFECTS REENTRANT:TAIL_CALL`" do
    fs = findings(<<~CLEAR)
      FN sum(n: Int64, acc: Int64) RETURNS Int64 @reentrant:tailCall ->
        IF n <= 0 -> RETURN acc;
        RETURN sum(n - 1, acc + n);
      END
      FN main() RETURNS Void -> _ = sum(10, 0); RETURN; END
    CLEAR
    f = fs.find { |x| x.message.include?("Legacy '@reentrant:tailCall'") }
    expect(f).not_to be_nil
    fix = f.fixes.first
    edit = fix.edits.first
    expect(edit.replacement).to eq("EFFECTS REENTRANT:TAIL_CALL")
    expect(edit.span.length).to eq("@reentrant:tailCall".length)
  end

  it "spans the @reentrant token at its source location" do
    fs = findings(<<~CLEAR)
      FN walk(n: Int64) RETURNS Void @reentrant ->
        IF n <= 0 -> RETURN;
        walk(n - 1);
      END
      FN main() RETURNS Void -> walk(3); RETURN; END
    CLEAR
    f = fs.find { |x| x.message.include?("Legacy '@reentrant'") }
    edit = f.fixes.first.edits.first
    expect(edit.span.line).to eq(1)
    # Column is 1-based; @reentrant starts after `FN walk(n: Int64) RETURNS Void `.
    expect(edit.span.col).to be > 1
  end

  describe "unconstrained FN-typed parameter fix (Phase 2)" do
    it "warns and offers two fixes: NON_REENTRANT (auto) and EFFECTS REENTRANT (interactive)" do
      fs = findings(<<~CLEAR)
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS Int64 ->
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
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS Int64 ->
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
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS Int64 ->
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

    it "skips parameters with @reentrant on the type (caller opted in)" do
      fs = findings(<<~CLEAR)
        FN applyReentrant(f: FN(Int64) -> Int64 @reentrant, x: Int64) RETURNS Int64
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
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS Int64
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
        FN apply(f: FN(Int64) -> Int64, x: Int64) RETURNS Int64
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
        FN both(f: FN(Int64) -> Int64, g: FN(Int64) -> Int64, x: Int64) RETURNS Int64 ->
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
