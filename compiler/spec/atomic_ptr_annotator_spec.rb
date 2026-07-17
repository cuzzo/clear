require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# AtomicPtr M3.4 -- annotator capability validation for @boxed:atomic.
#
# Verifies the disallowed-combinations table from
# docs/agents/atomicptr.md §3:
#
#   @atomic (alone) on a struct            -> reject ("use @boxed:atomic")
#   @boxed:atomic on a primitive        -> reject ("use @shared:atomic")
#   @local:boxed:atomic                 -> reject (atomic + non-shared = pointless)
#   @multiowned:boxed:atomic            -> reject (Rc isn't thread-safe)
#   @boxed:atomic on a struct           -> ALLOW
#   @shared:boxed:atomic on a struct    -> ALLOW (shared is implicit anyway)
#   primitive @shared:atomic               -> ALLOW (M1 carve-out, untouched)
RSpec.describe "Annotator validation for @boxed:atomic (AtomicPtr M3.4)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "allowed combinations" do
    it "accepts @boxed:atomic on a struct binding" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Config { host: String, port: Int64 }
          FN main() RETURNS Void ->
            cfg = Config{ host: "localhost", port: 8080 } @boxed:atomic;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts @shared:boxed:atomic on a struct binding (explicit @shared is fine)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Config { host: String, port: Int64 }
          FN main() RETURNS Void ->
            cfg = Config{ host: "localhost", port: 8080 } @shared:boxed:atomic;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "accepts @atomic:boxed on a struct binding (order-independent)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Config { host: String, port: Int64 }
          FN main() RETURNS Void ->
            cfg = Config{ host: "localhost", port: 8080 } @atomic:boxed;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "primitive @shared:atomic still works (M1 carve-out untouched)" do
      expect {
        annotate(<<~CLEAR)
          FN main() RETURNS Void ->
            counter: Int64 = 0 @shared:atomic;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "rejected combinations" do
    it "rejects @atomic alone on a struct (must use @boxed:atomic)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            c = Counter{ value: 0 } @atomic;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /@atomic.*STRUCT.*@boxed:atomic/i)
    end

    it "rejects @boxed:atomic on a primitive (must use @shared:atomic)" do
      expect {
        annotate(<<~CLEAR)
          FN main() RETURNS Void ->
            c: Int64 = 0 @boxed:atomic;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /@boxed:atomic.*STRUCT.*@shared:atomic/i)
    end

    it "rejects @local:boxed:atomic at the PARSER (sync conflict: @local and @atomic are both sync caps)" do
      # @local is itself a sync capability (no cross-thread), so the
      # parser's one-cap-per-dimension rule rejects @local:atomic
      # (duplicate sync) BEFORE the annotator gets a chance. The
      # message points at the same conceptual mistake -- "you can't
      # have an atomic that isn't shared".
      expect {
        annotate(<<~CLEAR)
          STRUCT Config { host: String }
          FN main() RETURNS Void ->
            cfg = Config{ host: "x" } @local:boxed:atomic;
            RETURN;
          END
        CLEAR
      }.to raise_error(/Duplicate sync/i)
    end

    it "rejects @multiowned:boxed:atomic (Rc isn't thread-safe)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Config { host: String }
          FN main() RETURNS Void ->
            cfg = Config{ host: "x" } @multiowned:boxed:atomic;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /@multiowned.*boxed:atomic.*Rc/i)
    end
  end

  describe "REQUIRES family ATOMIC covers @boxed:atomic" do
    it "REQUIRES c: ATOMIC accepts an @boxed:atomic argument" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Config { host: String, port: Int64 }
          FN bumpPort(MUTABLE c: Config) RETURNS Void
            REQUIRES c: ATOMIC
          ->
            RETURN;
          END
          FN main() RETURNS Void ->
            MUTABLE cfg = Config{ host: "x", port: 80 } @boxed:atomic;
            bumpPort(&cfg);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "REQUIRES c: ATOMIC | LOCKED disjunction accepts an @boxed:atomic argument (single ATOMIC family)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT Config { host: String, port: Int64 }
          FN bumpPort(MUTABLE c: Config) RETURNS Void
            REQUIRES c: ATOMIC | LOCKED
          ->
            WITH c AS x MATCH
              WHEN ATOMIC -> { _ = x.port; }
              WHEN LOCKED -> { _ = x.port; }
            END
            RETURN;
          END
          FN main() RETURNS Void ->
            MUTABLE cfg = Config{ host: "x", port: 80 } @boxed:atomic;
            bumpPort(&cfg);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end
end
