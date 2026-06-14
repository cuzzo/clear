require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/ast/fixable_error" unless defined?(FixCollector)
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# Phase 1 of the USE-AFTER-MOVE fix refinement: the consumer-site fix
# picks `COPY` for plain affine bindings and `CLONE` for shared /
# refcounted ones (`@shared`, `@multiowned`, `@split`). Capability
# upgrades that the binding already carries are skipped (offering
# `@shared` on an already-`@shared` binding is a no-op).
RSpec.describe UseAfterMoveChecker do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  describe "plain affine binding — offers COPY + @multiowned + @shared" do
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

    it "offers three fixes: COPY, @multiowned, @shared" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      expect(finding).not_to be_nil
      descs = finding.fixes.map(&:description)
      expect(descs).to include(match(/Wrap the consuming reference with COPY/))
      expect(descs).to include(match(/Change 'msg' to `@multiowned`/))
      expect(descs).to include(match(/Change 'msg' to `@shared`/))
    end

    it "the COPY fix wraps with `(COPY name)`" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      copy_fix = finding.fixes.find { |fix| fix.description.include?("COPY") }
      expect(copy_fix.edits.first.replacement).to eq("(COPY msg)")
    end
  end

  describe "@shared / @multiowned cap-upgrade on a multi-statement decl line" do
    # When the moved binding's declaration shares a physical line with a
    # prior statement, the cap-upgrade fix must locate `;` that ENDS
    # this binding's declaration, not the first `;` on the line.
    let(:src) {
      <<~CLEAR
        UNION Value { Nil, Lambda { body: Value @indirect } }
        FN main() RETURNS Void ->
            z = 0; msg = Value.Nil;
            x = msg;
            y = msg;
        END
      CLEAR
    }

    it "inserts @shared at msg's terminator, not at the prior statement's `;`" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      expect(finding).not_to be_nil
      shared_fix = finding.fixes.find { |fx| fx.description.include?("@shared") }
      expect(shared_fix).not_to be_nil
      decl_line = "    z = 0; msg = Value.Nil;"
      expect(shared_fix.edits.first.span.col).to eq(decl_line.rindex(';') + 1)
    end
  end

  describe "@split stream — offers CLONE, no @multiowned/@shared upgrade" do
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
            s: ~?Int64[]@split = BG STREAM { YIELD 1; };
            t: ~?Int64[]@split = s;
            v: ?Int64 = NEXT s;
        END
      CLEAR
    }

    it "offers CLONE at the consumer site (not COPY)" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      expect(finding).not_to be_nil
      consumer_fix = finding.fixes.first
      expect(consumer_fix.description).to match(/Wrap the consuming reference with CLONE/)
      expect(consumer_fix.edits.first.replacement).to eq("(CLONE s)")
    end

    it "does NOT offer @multiowned or @shared upgrades for an already-@split binding" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /USE AFTER MOVE/ }
      descs = finding.fixes.map(&:description)
      expect(descs).not_to include(match(/`@multiowned`/))
      expect(descs).not_to include(match(/`@shared`/))
    end

    it "applying the CLONE fix produces compilable CLEAR" do
      fixed = src.sub("@split = s;", "@split = (CLONE s);")
      expect { annotate(fixed) }.not_to raise_error
    end
  end
end
