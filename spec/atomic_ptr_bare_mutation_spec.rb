require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)

# AtomicPtr M3.10 -- reject bare mutation on @indirect:atomic.
#
# An assignment whose target's root binding is @indirect:atomic and is
# NOT inside a WITH SNAPSHOT ... AS MUTABLE block is invalid: the
# AtomicPtr cell publishes whole-T snapshots via atomic pointer swap,
# not per-field writes. The error message MUST explicitly distinguish
# from primitive @shared:atomic (which uses direct ops like c += 1
# because the cell fits in a single CAS-able machine word):
#
#   "@indirect:atomic requires `WITH SNAPSHOT cfg AS MUTABLE x { x.port = 9090; }`
#    for mutation. Atomic pointer swap publishes a new whole-T snapshot,
#    not a per-field write -- the WITH SNAPSHOT block clones the snapshot,
#    mutates the clone, and CAS-publishes it. (This is different from
#    primitive @shared:atomic Int64/Float64/Bool, which use direct ops
#    like c += 1 because they fit in a single CAS-able machine word.)"
RSpec.describe "Bare mutation on @indirect:atomic (M3.10)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "rejected: bare field assignment OUTSIDE WITH SNAPSHOT" do
    it "rejects `cfg.port = 9090` on an @indirect:atomic Cfg" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN main!() RETURNS Void ->
            MUTABLE cfg = Cfg{ port: 8080 } @indirect:atomic;
            cfg.port = 9090;
            RETURN;
          END
        CLEAR
      }.to raise_error(/@indirect:atomic.\W+requires.*WITH SNAPSHOT.*MUTABLE.*atomic pointer swap.*different from primitive .@shared:atomic/im)
    end

    it "rejects compound assignment `cfg.port += 1` on an @indirect:atomic Cfg" do
      # Even compound assignments (which desugar to read+write under
      # M1/M2 atomic primitives) aren't valid on the AtomicPtr cell --
      # there's no per-field cmpxchg on a struct field.
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN main!() RETURNS Void ->
            MUTABLE cfg = Cfg{ port: 8080 } @indirect:atomic;
            cfg.port += 1;
            RETURN;
          END
        CLEAR
      }.to raise_error(/@indirect:atomic.\W+requires.*WITH SNAPSHOT.*different from primitive .@shared:atomic/im)
    end
  end

  describe "allowed: assignment INSIDE WITH SNAPSHOT MUTABLE" do
    it "accepts `x.port = 9090` inside WITH SNAPSHOT cfg AS MUTABLE x" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN main!() RETURNS !Void ->
            MUTABLE cfg = Cfg{ port: 8080 } @indirect:atomic;
            WITH SNAPSHOT cfg AS MUTABLE x {
              x.port = 9090;
            }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts compound `x.port += 1` inside WITH SNAPSHOT cfg AS MUTABLE x" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Cfg { port: Int64 }
          FN main!() RETURNS !Void ->
            MUTABLE cfg = Cfg{ port: 8080 } @indirect:atomic;
            WITH SNAPSHOT cfg AS MUTABLE x {
              x.port = x.port + 1;
            }
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "regression: primitive @shared:atomic still allows direct ops" do
    it "accepts `c += 1` on Int64@shared:atomic (M1 primitive surface)" do
      expect {
        annotate(<<~CLEAR)
          FN main!() RETURNS !Void ->
            MUTABLE c: Int64 = 0 @shared:atomic;
            c += 1;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts `c = 5` on Int64@shared:atomic (atomic store)" do
      expect {
        annotate(<<~CLEAR)
          FN main!() RETURNS !Void ->
            MUTABLE c: Int64 = 0 @shared:atomic;
            c = 5;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  # ============================================================
  # Annotated examples for compound-op codes on `@shared:atomic`
  # primitives. The atomic primitive lowering only accepts the ops
  # that map to a single hardware fetch_* instruction.
  # ============================================================

  # @example_for: ATOMIC_NO_MUL_DIV_COMPOUND
  # @fix: Multiply / divide have no single-instruction atomic form on
  # @fix: any mainstream architecture. Use a compareAndSwap loop, or
  # @fix: switch the binding from `@shared:atomic` to `@shared:locked`
  # @fix: and do the math inside a `WITH EXCLUSIVE c AS x { ... }`
  # @fix: block — the lock makes the read-modify-write atomic.
  describe ":ATOMIC_NO_MUL_DIV_COMPOUND — `*=` / `/=` on @shared:atomic" do
    it "raises on `c *= 2` against an @shared:atomic primitive" do
      expect {
        annotate(<<~CLEAR)
          FN main!() RETURNS !Void ->
            MUTABLE c: Int64 = 1 @shared:atomic;
            c *= 2;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /Atomic primitives do not support/)
    end

    it "compiles when the same op runs against an @shared:locked binding inside WITH EXCLUSIVE" do
      annotate(<<~CLEAR)
        STRUCT Counter { v: Int64 }
        FN main!() RETURNS !Void ->
          c = Counter{ v: 1 } @shared:locked;
          WITH EXCLUSIVE c AS x { x.v = x.v * 2; }
          RETURN;
        END
      CLEAR
    end
  end

end
