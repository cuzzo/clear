require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Phase 2.8 — `WITH VIEW` on a non-`@observable` source emits a
# fixable error proposing `WITH MATERIALIZED VIEW` (auto-correct,
# always-safe, owned O(N) snapshot).
RSpec.describe "WITH VIEW on non-@observable: fixable error" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotated(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  it "emits a :auto fix replacing `VIEW` with `MATERIALIZED VIEW`" do
    src = <<~CLEAR
      FN viewer(running: ~Float64) RETURNS ~Float64 ->
          WITH VIEW running AS s {
              ASSERT s >= 0.0, "ok";
          }
          RETURN GIVE running;
      END
    CLEAR
    annotated(src)
    findings = FixCollector.drain.select { |f| f.category == :capability && f.message.include?("@observable") }
    expect(findings).not_to be_empty
    fix = findings.first.fixes.first
    expect(fix.confidence).to eq(:auto)
    expect(fix.edits.first.replacement).to eq('MATERIALIZED VIEW')
  end

  it "does not fire when the source is `~T@observable`" do
    src = <<~CLEAR
      FN viewer(running: ~Float64@observable) RETURNS ~Float64@observable ->
          WITH VIEW running AS s {
              ASSERT s >= 0.0, "ok";
          }
          RETURN GIVE running;
      END
    CLEAR
    annotated(src)
    findings = FixCollector.drain.select { |f| f.category == :capability && f.message.include?("@observable") }
    expect(findings).to be_empty
  end
end
