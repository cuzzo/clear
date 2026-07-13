require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Thunk Phase 5a -- `clear fix` audit nudges plain `EFFECTS REENTRANT`
# functions toward bounded variants when the body shape allows it.
# Goal: shrink the @service-forced set as the corpus migrates.

RSpec.describe "Thunk Phase 5 -- plain :reentrant variant audit" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotated(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "suggests :TAIL_CALL when every self-call is in tail position" do
    src = <<~CLEAR
      FN sum(n: Int64, acc: Int64) RETURNS Int64
        EFFECTS REENTRANT ->
        IF n <= 0 -> RETURN acc;
        RETURN sum(n - 1, acc + n);
      END
      FN main() RETURNS Void ->
        p: ~Int64 = BG { @service -> sum(10_i64, 0_i64); };
        _ = NEXT p;
        RETURN;
      END
    CLEAR
    annotated(src)
    findings = FixCollector.drain.select { |f| f.category == :reentrance }
    expect(findings).not_to be_empty
    finding = findings.find { |f| f.message.include?("'sum'") }
    expect(finding).not_to be_nil
    expect(finding.fixes.first.description).to match(/EFFECTS REENTRANT:TAIL_CALL/)
  end

  it "suggests :THUNK when body matches the simple-recurrence shape" do
    src = <<~CLEAR
      FN factorial(n: Int64) RETURNS Int64
        EFFECTS REENTRANT ->
        IF n <= 1 -> RETURN 1;
        RETURN n * factorial(n - 1);
      END
      FN main() RETURNS Void ->
        p: ~Int64 = BG { @service -> factorial(5_i64); };
        _ = NEXT p;
        RETURN;
      END
    CLEAR
    annotated(src)
    finding = FixCollector.drain.find { |f| f.category == :reentrance && f.message.include?("'factorial'") }
    expect(finding).not_to be_nil
    expect(finding.fixes.first.description).to match(/EFFECTS REENTRANT:THUNK/)
  end

  it "does not suggest a variant when shape doesn't match anything bounded" do
    src = <<~CLEAR
      FN walk(n: Int64) RETURNS Int64
        EFFECTS REENTRANT ->
        IF n <= 0 -> RETURN 0;
        a: Int64 = walk(n - 1);
        b: Int64 = walk(n - 2);
        RETURN a + b;
      END
      FN main() RETURNS Void ->
        p: ~Int64 = BG { @service -> walk(5_i64); };
        _ = NEXT p;
        RETURN;
      END
    CLEAR
    annotated(src)
    finding = FixCollector.drain.find { |f| f.category == :reentrance && f.message.include?("'walk'") }
    expect(finding).to be_nil
  end

  it "the suggestion is :auto-confidence (safe to apply with `clear fix --yes`)" do
    src = <<~CLEAR
      FN sum(n: Int64, acc: Int64) RETURNS Int64
        EFFECTS REENTRANT ->
        IF n <= 0 -> RETURN acc;
        RETURN sum(n - 1, acc + n);
      END
      FN main() RETURNS Void ->
        p: ~Int64 = BG { @service -> sum(10_i64, 0_i64); };
        _ = NEXT p;
        RETURN;
      END
    CLEAR
    annotated(src)
    finding = FixCollector.drain.find { |f| f.category == :reentrance && f.message.include?("'sum'") }
    expect(finding.fixes.first.confidence).to eq(:auto)
  end
end
