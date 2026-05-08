require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Capability sigil / modifier / WITH-keyword typos. All three sites
# now route through emit_typo_suggestion! with the appropriate
# candidate set (CAP_SIGIL_ATTRS keys, CAPABILITY_TOKENS, AST::CAPABILITIES).
RSpec.describe "Capability typo auto-fixes" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def parse(source)
    tokens = Lexer.new(source).tokenize
    Parser.new(tokens, source).parse
  end

  describe "UNKNOWN_CAPABILITY_SIGIL — `@shared:lokced` typo" do
    let(:src) {
      <<~CLEAR
        STRUCT Counter { v: Int64 }
        FN main() RETURNS Void ->
          c = Counter{v: 0}@shared:lokced;
          _ = c;
        END
      CLEAR
    }

    it "captures a fixable finding suggesting :locked" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /lokced/ }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      # Chain form: the user typed `lokced` (without `@`) after the
      # `:`. Replacement keeps the same shape.
      expect(edit.replacement).to eq("locked")
    end
  end

  describe "UNKNOWN_CAPABILITY_SIGIL — `@multiowned:lokced` second-position typo" do
    # The first-position sigil (`@multiowned`, `@shared`, etc.) is
    # tokenized as a single VAR_ID and dispatched by suffix rule —
    # bare-sigil typos die in expression parsing, not here. The
    # CHAINED form `@<known>:<typo>` is the path that reaches the
    # capability-sigil error site.
    let(:src) {
      <<~CLEAR
        STRUCT Counter { v: Int64 }
        FN main() RETURNS Void ->
          c = Counter{v: 0}@multiowned:lokced;
          _ = c;
        END
      CLEAR
    }

    it "captures a fixable finding suggesting `locked`" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /lokced/ }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("locked")
    end
  end

  describe "UNKNOWN_WITH_CAPABILITY — `RESTRIKT` typo" do
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE x = 5;
          WITH RESTRIKT x { _ = x; }
        END
      CLEAR
    }

    it "captures a fixable finding suggesting RESTRICT" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /RESTRIKT/i }
      expect(finding).not_to be_nil
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("RESTRICT")
    end
  end
end
