require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# A20: an I1-violating binding (bare `~T@observable` or non-fold-pipe
# initializer) emits a fixable error that offers to drop `@observable`
# from the type annotation. The fix is :interactive — dropping
# @observable changes type semantics, so user must opt in. The
# alternative ("add a fold-pipe initializer") is too context-specific
# to template, so only the drop fix is offered.
RSpec.describe "A20: I1 fixable error (drop @observable)" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotated(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast) rescue nil
    ast
  end

  def i1_findings
    FixCollector.drain.select { |f| f.message.include?("pipeline-terminal fold") }
  end

  it "emits a fixable :interactive `drop @observable` for a bare-init declaration" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          running: ~Int64@observable = 0_i64;
          RETURN;
      END
    CLEAR
    annotated(src)
    findings = i1_findings
    expect(findings.size).to eq(1)
    fix = findings.first.fixes.first
    expect(fix.confidence).to eq(:interactive)
    # The fix deletes the `@observable` token text. The exact replacement
    # is the empty string; the description mentions "Drop".
    expect(fix.description).to match(/Drop `@observable`/)
    expect(fix.edits.first.replacement).to eq("")
  end

  it "does not emit any I1 fix for the canonical fold-pipe form" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
          gen: ~?Int64[] = BG STREAM {
              MUTABLE i: Int64 = 0_i64;
              WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
          };
          running: ~Int64@observable = gen s> SUM _;
          _ = NEXT running;
          RETURN;
      END
    CLEAR
    annotated(src)
    expect(i1_findings).to be_empty
  end
end
