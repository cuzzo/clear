require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# T13 + T14: late-tranche test coverage from task #202.
#
# T13 -- H10 added a numeric-only whitelist for REDUCE-on-observable
# accumulators. AtomicReduce is built on AtomicFor(T) which only
# specializes for int/float; non-numeric scalars (Bool, String, etc.)
# would surface as a Zig @compileError. Verify the annotator catches
# them at CLEAR-level before they reach codegen.
#
# T14 -- nested observable pipes (two `~T@observable` bindings in the
# same fn, each with its own producer) must both pass annotation +
# codegen. The cross-product of FIDs in lower_range_fold_observable
# (ctx struct names, fiber rt names) is what regressed in the early
# generalization; this spec pins down that case.
RSpec.describe "T13/T14: observable terminal validation + nesting" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def transpile(source)
    ZigTranspiler.new.transpile(source)
  end

  describe "T13: REDUCE on observable requires a numeric scalar accumulator" do
    it "rejects ~Bool@observable = stream |> REDUCE(false, _ OR acc)" do
      # Bool accumulator routes to AtomicFor(bool) which @compileErrors
      # in Zig; H10's whitelist catches it earlier as a CLEAR coerce
      # failure (the lift to ~Bool@observable doesn't fire, so the
      # RHS stays Bool and disagrees with the LHS).
      src = <<~CLEAR
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Bool@observable = gen |> REDUCE(false) (_ > 1_i64) OR acc;
            _ = NEXT running;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }.to raise_error(CompilerError)
    end

    it "accepts ~Int64@observable = stream |> REDUCE(0, acc + _)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Int64@observable = gen |> REDUCE(0_i64) acc + _;
            _ = NEXT running;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }.not_to raise_error
    end
  end

  describe "T14: nested observable pipes in one fn" do
    it "annotates two ~T@observable bindings sharing scope" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            g1: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running_sum: ~Int64@observable = g1 |> SUM _;
            g2: ~?Int64[] = BG STREAM {
                MUTABLE j: Int64 = 0_i64;
                WHILE j < 4_i64 DO YIELD j; j = j + 1_i64; END
            };
            running_max: ~Int64@observable = g2 |> MAX _;
            final_sum = NEXT running_sum;
            final_max = NEXT running_max;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }.not_to raise_error
    end

    it "transpiles two nested observable pipes to distinct ctx struct ids" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            g1: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running_sum: ~Int64@observable = g1 |> SUM _;
            g2: ~?Int64[] = BG STREAM {
                MUTABLE j: Int64 = 0_i64;
                WHILE j < 4_i64 DO YIELD j; j = j + 1_i64; END
            };
            running_max: ~Int64@observable = g2 |> MAX _;
            final_sum = NEXT running_sum;
            final_max = NEXT running_max;
            RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Two distinct consumer-fiber ctx struct names so the spawn
      # lowering doesn't collide on identifiers.
      ids = zig.scan(/__ObsConsumerCtx(\d+)/).flatten.uniq.sort
      expect(ids.size).to be >= 2
    end
  end
end
