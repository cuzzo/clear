require "rspec"
require_relative "../src/tools/method_rewriter"

# Unit tests for MethodRewriter — the source-level preprocessor that
# rewrites prefix calls of METHOD-flagged functions to UFCS form.
# These tests exercise the rewriter directly on small CLEAR source
# fragments. Integration with `clear fmt` is covered separately in
# spec/clear_fmt_method_spec.rb.

RSpec.describe MethodRewriter do
  def rw(src)
    MethodRewriter.rewrite(src)
  end

  describe "no-op cases" do
    it "leaves source unchanged when no METHODs are declared" do
      src = <<~CLEAR
        FN length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void -> n = length([]); RETURN; END
      CLEAR
      expect(rw(src)).to eq(src)
    end

    it "leaves FN call sites untouched even when METHODs exist" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN add(a: Int64, b: Int64) RETURNS Int64 -> RETURN a + b; END
        FN main() RETURNS Void -> n = add(1, 2); RETURN; END
      CLEAR
      expect(rw(src)).to include("n = add(1, 2);")
    end

    it "leaves already-UFCS calls untouched" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = xs.length();
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("n = xs.length();")
      expect(rw(src)).not_to match(/length\(xs\)/)
    end

    it "leaves pipeline calls untouched (xs |> length stays)" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = xs |> length;
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs |> length")
    end
  end

  describe "single-arg METHOD rewrite" do
    it "rewrites length(xs) to xs.length()" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = length(xs);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = xs.length();")
      expect(out).not_to match(/n = length\(xs\)/)
    end

    it "rewrites with a literal receiver" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          n = length([1, 2, 3]);
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("n = [1, 2, 3].length();")
    end

    it "rewrites with a multi-character method name" do
      src = <<~CLEAR
        METHOD totalCount(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1];
          n = totalCount(xs);
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("n = xs.totalCount();")
    end
  end

  describe "multi-arg METHOD rewrite" do
    it "rewrites push(xs, 5) to xs.push(5)" do
      src = <<~CLEAR
        METHOD push(MUTABLE xs: Int64[], x: Int64) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [];
          push(xs, 5);
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.push(5);")
    end

    it "rewrites three-arg METHOD call" do
      src = <<~CLEAR
        METHOD insertAt(MUTABLE xs: Int64[], idx: Int64, x: Int64) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [];
          insertAt(xs, 0, 42);
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.insertAt(0, 42);")
    end
  end

  describe "nested METHOD calls" do
    it "rewrites inside-out into a method chain" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        METHOD reversed(xs: Int64[]) RETURNS Int64[] -> RETURN xs; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = length(reversed(xs));
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = xs.reversed().length();")
    end

    it "leaves the inner call as a free FN when only outer is METHOD" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN buildList() RETURNS Int64[] -> RETURN [1, 2, 3]; END
        FN main() RETURNS Void ->
          n = length(buildList());
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = buildList().length();")
    end

    it "leaves the outer call alone when only inner is METHOD" do
      src = <<~CLEAR
        METHOD reversed(xs: Int64[]) RETURNS Int64[] -> RETURN xs; END
        FN consume(xs: Int64[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = consume(reversed(xs));
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n = consume(xs.reversed());")
    end
  end

  describe "string and comment safety" do
    it "ignores parens inside string literals" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1];
          msg = "length(xs) is the call form";
          n = length(xs);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include('"length(xs) is the call form"')
      expect(out).to include("n = xs.length();")
    end

    it "ignores commas inside string literal args" do
      src = <<~CLEAR
        METHOD log(msg: String, level: Int64) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          log("hello, world", 1);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include('"hello, world".log(1);')
    end

    it "ignores parens inside line comments" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1];
          # ignored: length(xs) inside comment
          n = length(xs);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("# ignored: length(xs) inside comment")
      expect(out).to include("n = xs.length();")
    end
  end

  describe "idempotence" do
    it "is a no-op on already-rewritten source" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = length(xs);
          RETURN;
        END
      CLEAR
      once = rw(src)
      twice = rw(once)
      expect(twice).to eq(once)
    end

    it "is idempotent on nested rewrites" do
      src = <<~CLEAR
        METHOD length(xs: Any[]) RETURNS Int64 -> RETURN 0; END
        METHOD reversed(xs: Int64[]) RETURNS Int64[] -> RETURN xs; END
        FN main() RETURNS Void ->
          xs: Int64[] = [1, 2, 3];
          n = length(reversed(xs));
          RETURN;
        END
      CLEAR
      once = rw(src)
      twice = rw(once)
      expect(twice).to eq(once)
    end
  end

  describe "argument-list spacing in the rewrite" do
    it "preserves the user's inter-argument spacing verbatim" do
      # The rewriter is whitespace-preserving: it doesn't introduce
      # canonical `, ` separators. The downstream formatter handles
      # spacing normalization. This test pins the no-touching behaviour.
      src = <<~CLEAR
        METHOD push(MUTABLE xs: Int64[], x: Int64, y: Int64) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [];
          push(xs,5,7);
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.push(5,7);")
    end

    it "preserves nicely-spaced args verbatim too" do
      src = <<~CLEAR
        METHOD push(MUTABLE xs: Int64[], x: Int64, y: Int64) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[] = [];
          push(xs, 5, 7);
          RETURN;
        END
      CLEAR
      expect(rw(src)).to include("xs.push(5, 7);")
    end
  end

  describe "paren-wrapping the receiver to preserve precedence" do
    # Found by FmtVerifier on benchmarks/sequential/11_pipeline_overhead.
    # `toFloat(state MOD 1000)` was being rewritten to
    # `state MOD 1000.toFloat()`, which Zig parses as
    # `state MOD (1000.toFloat())` — integer mod silently became float
    # mod. The first arg must be paren-wrapped when its top-level AST
    # shape would bind looser than `.method()`.

    it "wraps a binary-op first arg" do
      # toFloat is `is_method: true` in stdlib; rewriter picks it up
      # without a METHOD declaration in the source.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          state: Int64 = 42;
          val = toFloat(state MOD 1000);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("(state MOD 1000).toFloat()")
      expect(out).not_to include("state MOD 1000.toFloat()")
    end

    it "wraps a unary-op first arg" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 5;
          val = toFloat(-n);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("(-n).toFloat()")
    end

    it "does not wrap an identifier first arg" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          n: Int64 = 5;
          val = toFloat(n);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("n.toFloat()")
      expect(out).not_to include("(n).toFloat()")
    end

    it "does not wrap a method-chain first arg" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [1_i64, 2_i64];
          n = toFloat(xs.length());
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("xs.length().toFloat()")
      expect(out).not_to include("(xs.length()).toFloat()")
    end

    it "does not wrap a literal first arg" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          val = toFloat(42_i64);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("42_i64.toFloat()").or include("42.toFloat()")
    end

    it "does not double-wrap an already-parenthesized first arg" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          state: Int64 = 5;
          val = toFloat((state + 1));
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("(state + 1).toFloat()")
      expect(out).not_to include("((state + 1)).toFloat()")
    end
  end

  describe "skip stdlib functions whose lowering is FSM-based" do
    # Found by FmtVerifier on benchmarks/concurrent/02_concurrent_search.
    # `readFile` is `is_method: true` so the rewriter would turn
    # `readFile(filepath)` into `filepath.readFile()`. But its
    # lowering reads positional args via FsmOps templates
    # (`fsm_setup` in std_lib.rb) and crashes with
    # "FsmOps arg index 0 out of range (0 args)" once the first
    # arg has moved into the receiver slot. Detection is structural:
    # `suspends: true` AND any `fsm_*` template key.

    it "leaves readFile in prefix form (FSM-lowered)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          path = "data/foo.txt";
          content = readFile(path);
          print(content);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("readFile(path)")
      expect(out).not_to include("path.readFile()")
    end

    it "still rewrites non-FSM is_method stdlib like length" do
      # Sanity: only FSM-lowered entries are skipped, normal
      # is_method ones still get UFCS-rewritten.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          xs: Int64[] = [1_i64, 2_i64];
          n = length(xs);
          RETURN;
        END
      CLEAR
      out = rw(src)
      expect(out).to include("xs.length()")
    end
  end
end
