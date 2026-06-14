require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# AtomicPtr M3.12 -- lifetime semantics for @indirect:atomic vs
# primitive @shared:atomic.
#
# @indirect:atomic is Arc-managed under the hood (M3.5 auto-promotes
# ownership to :shared). Loaded snapshots have refcount lifetime;
# the cell itself can flow into struct fields, BG handles, RETURN
# values without trip-wiring the M2.6 escape audit. Mirrors the
# existing @shared-without-sync exemption.
#
# Primitive @shared:atomic stays scope-bounded -- bare *Atomic(T)
# cell, no Arc, M2.6 audit rejects escapes (regression check).
RSpec.describe "AtomicPtr lifetime (M3.12)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "POSITIVE: @indirect:atomic can escape (Arc-managed)" do
    it "BG handle that captures @indirect:atomic can be returned without RETURNS x:T" do
      # Without M3.12, the BG handle's lifetime would be tied to the
      # @indirect:atomic cell, and RETURN bg without `RETURNS cfg:T`
      # would be rejected by M2.6. With M3.12, @indirect:atomic is
      # exempted from bg_lifetime_sources, so the BG handle has
      # nil/empty lifetime and RETURN bg is allowed.
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { v: Int64 }
          FN make_handle() RETURNS ~Void ->
            cfg = Cfg{ v: 0 } @indirect:atomic;
            bg = BG {
              WITH SNAPSHOT cfg AS c {
                _ = c.v;
              }
            };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "REGRESSION: primitive @shared:atomic is still scope-bounded" do
    it "NEG: primitive @shared:atomic capture without `RETURNS counter:T` still errors" do
      expect {
        annotate(<<~CLEAR)
          FN make_handle() RETURNS ~Void ->
            MUTABLE counter: Int64 = 0 @shared:atomic;
            bg = BG { v = counter; print(v.toString()); };
            RETURN bg;
          END
        CLEAR
      }.to raise_error(/Lifetime Error.*RETURN.*lifetime is tied/i)
    end

    it "POS: primitive @shared:atomic capture WITH `RETURNS counter:T` still accepts (regression)" do
      expect {
        annotate(<<~CLEAR)
          FN spawn_bumper(counter: Int64) RETURNS counter:~Void
            REQUIRES counter: ATOMIC
          ->
            bg = BG { v = counter; print(v.toString()); };
            RETURN bg;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
