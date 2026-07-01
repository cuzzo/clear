require "rspec"
require_relative "../ruby/tools/predicate_rewriter" unless defined?(PredicateRewriter::CompareSpan)

# `PredicateRewriter.lint!` emits FixableFindings for length-comparison
# patterns whose result is constant for any non-negative length:
#
#   coll.length() >= 0   # always true
#   coll.length() <  0   # always false
#
# These are bugs (almost always typos for `> 0` / `== 0`); the
# linter surfaces them as warnings during `clear fix`. No auto-fix
# is offered because the user has to decide which sense they meant.

RSpec.describe PredicateRewriter do
  def lint(src)
    FixCollector.enable!
    PredicateRewriter.lint!(src)
    FixCollector.drain
  ensure
    FixCollector.disable!
  end

  it "warns on `length() >= 0` (always true)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        xs: Int64[] = [];
        IF xs.length() >= 0 THEN RETURN; END
        RETURN;
      END
    CLEAR
    findings = lint(src)
    expect(findings.size).to eq(1)
    expect(findings.first.level).to eq(:warning)
    expect(findings.first.category).to eq(:lint)
    expect(findings.first.message).to include("always true")
  end

  it "warns on `length() < 0` (always false)" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        xs: Int64[] = [];
        IF xs.length() < 0 THEN RETURN; END
        RETURN;
      END
    CLEAR
    findings = lint(src)
    expect(findings.size).to eq(1)
    expect(findings.first.message).to include("always false")
  end

  it "does NOT warn on canonical comparisons" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        xs: Int64[] = [];
        IF xs.length() == 0 THEN RETURN; END
        IF xs.length() > 0 THEN RETURN; END
        IF xs.length() != 0 THEN RETURN; END
        RETURN;
      END
    CLEAR
    expect(lint(src)).to be_empty
  end

  it "is a no-op when FixCollector is disabled" do
    src = <<~CLEAR
      FN main() RETURNS Void ->
        xs: Int64[] = [];
        IF xs.length() >= 0 THEN RETURN; END
        RETURN;
      END
    CLEAR
    # FixCollector defaults to disabled; calling lint! shouldn't raise
    # or emit anything.
    expect { PredicateRewriter.lint!(src) }.not_to raise_error
    expect(FixCollector.enabled?).to be false
  end

  it "does not lex source when FixCollector is disabled" do
    allow(Lexer).to receive(:new).and_raise(StandardError, "should not lex")

    expect { PredicateRewriter.lint!("not parsed") }.not_to raise_error
    expect(FixCollector.enabled?).to be false
  end

  it "ignores malformed source while FixCollector is enabled" do
    FixCollector.enable!

    expect { PredicateRewriter.lint!("FN main( RETURNS Void ->") }.not_to raise_error
    expect(FixCollector.drain).to eq([])
  ensure
    FixCollector.disable!
  end
end
