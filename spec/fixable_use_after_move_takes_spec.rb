require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Phase 2 of the USE-AFTER-MOVE fix refinement: when the move was
# `someFn(x)` with `someFn(TAKES v: T)` and the parameter `T` is
# plain affine (no `@shared` / `@multiowned`), upgrading `x`'s
# declaration to a refcounted handle won't help — `someFn` still
# demands a plain owned value and the use-after-move re-fires after
# the upgrade. The fix-dropdown skips the upgrade fixes in that case.
RSpec.describe "USE-AFTER-MOVE fix dropdown — TAKES-into-plain consumer filter" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  describe "TAKES into plain affine parameter — no upgrade fixes offered" do
    let(:src) {
      <<~CLEAR
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN consume(TAKES v: Value) RETURNS Void -> END
        FN main() RETURNS Void ->
            msg = Value.Nil;
            consume(msg);
            print(msg);
        END
      CLEAR
    }

    it "offers only the COPY fix (skips @shared/@multiowned upgrades)" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      expect(finding).not_to be_nil
      descs = finding.fixes.map(&:description)
      expect(descs).to include(match(/Wrap the consuming reference with COPY/))
      expect(descs).not_to include(match(/`@shared`/))
      expect(descs).not_to include(match(/`@multiowned`/))
    end
  end

  describe "plain assignment move (no TAKES) — upgrades still offered" do
    # Bare `y = x` is action `:move`, not `:takes`. The consumer-
    # compatibility filter only applies to `:takes`; here both
    # upgrade fixes still make sense (changing the decl to @shared
    # makes the assignment a refcount bump instead of a move).
    let(:src) {
      <<~CLEAR
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN main() RETURNS Void ->
            msg = Value.Nil;
            x = msg;
            y = msg;
        END
      CLEAR
    }

    it "still offers @shared and @multiowned upgrades" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      expect(finding).not_to be_nil
      descs = finding.fixes.map(&:description)
      expect(descs).to include(match(/`@multiowned`/))
      expect(descs).to include(match(/`@shared`/))
    end
  end

  describe "GIVE into plain TAKES — also skips upgrade fixes" do
    # `consume(GIVE msg)` with `consume(TAKES v: Value)` — the
    # explicit GIVE marks action `:give` (set by visit_GiveNode), but
    # the consumer is still a plain-T TAKES so the upgrade won't
    # help either. The function-call loop backfills the consumer's
    # param type onto the OG node even when the action was already
    # stamped, so the filter applies symmetrically to `:takes` and
    # `:give`.
    let(:src) {
      <<~CLEAR
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN consume(TAKES v: Value) RETURNS Void -> END
        FN main() RETURNS Void ->
            msg = Value.Nil;
            consume(GIVE msg);
            print(msg);
        END
      CLEAR
    }

    it "skips @shared/@multiowned upgrades for explicit GIVE into plain T" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      expect(finding).not_to be_nil
      descs = finding.fixes.map(&:description)
      expect(descs).to include(match(/Wrap the consuming reference with COPY/))
      expect(descs).not_to include(match(/`@multiowned`/))
      expect(descs).not_to include(match(/`@shared`/))
    end
  end
end
