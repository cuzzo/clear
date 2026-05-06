require "rspec"
require_relative "../src/backends/transpiler"

# I1 + I2: tighten declaration-site validation around `~T@observable`.
#
# I1 -- the wrapper, producer fiber, and WaitGroup bridge are all built
# inside `lower_range_fold_observable_default`, so an observable
# binding has no usable shape unless its initializer is a fold-pipe
# over a tense stream. Bare declarations or non-fold initializers
# would dangle (no producer; NEXT/COLLECT deadlock; cleanup destroys
# uninitialized memory).
#
# I2 -- `~T@observable` is itself a single-producer lock-free
# accumulator, so layering @locked / @writeLocked / @shared /
# @multiowned on top is either redundant double-locking or sharing
# of a scope-owned heap pointer (UAF risk).
RSpec.describe "I1/I2: @observable lockdown" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "I1: bind site requires a fold-pipe initializer" do
    it "rejects an observable bound to a literal" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            running: ~Int64@observable = 0_i64;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }
        .to raise_error(CompilerError, /pipeline-terminal fold/)
    end

    it "rejects an observable bound to another binding" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            other: Int64 = 0_i64;
            running: ~Int64@observable = other;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }
        .to raise_error(CompilerError, /pipeline-terminal fold/)
    end

    it "accepts the canonical fold-pipe form" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Int64@observable = gen |> SUM _;
            _ = NEXT running;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }.not_to raise_error
    end
  end

  describe "I2: sync / ownership wrappers are forbidden on observables" do
    it "rejects ~Int64@observable:locked" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Int64@observable:locked = gen |> SUM _;
            _ = NEXT running;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }
        .to raise_error(CompilerError, /@observable cannot be combined with sync/)
    end

    it "rejects ~Int64@observable:shared" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Int64@observable:shared = gen |> SUM _;
            _ = NEXT running;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }
        .to raise_error(CompilerError, /@observable cannot be combined with .*ownership/)
    end

    it "still accepts the DISTINCT collection shape ~T[]@set:observable" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Int64[]@set:observable = gen |> DISTINCT _;
            final = NEXT running;
            RETURN;
        END
      CLEAR
      expect { annotate(src) }.not_to raise_error
    end
  end
end
