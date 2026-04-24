# Regression tests for compiler bugs documented in docs/agents/vm-bugs.md.
# When a bug flips from unfixed → fixed, update the corresponding assertion.

require "tempfile"
require "open3"

PROJECT_ROOT = File.expand_path("..", __dir__)
CLEAR_BIN = File.join(PROJECT_ROOT, "clear")

def compile(src_text)
  Tempfile.open(["vmbug", ".cht"]) do |src|
    src.write(src_text); src.close
    out_path = src.path.sub(/\.cht\z/, "")
    stdout, status = Open3.capture2e(CLEAR_BIN, "build", src.path, "-o", out_path)
    { ok: status.success?, output: stdout, out_path: out_path }
  end
end

def compile_and_run(src_text)
  Tempfile.open(["vmbug", ".cht"]) do |src|
    src.write(src_text); src.close
    out_path = src.path.sub(/\.cht\z/, "")
    _, bstatus = Open3.capture2e(CLEAR_BIN, "build", src.path, "-o", out_path)
    return { ok: false, phase: :compile } unless bstatus.success?
    stdout, rstatus = Open3.capture2e(out_path)
    { ok: rstatus.success?, phase: :run, output: stdout }
  end
end

RSpec.describe "VM Phase 2 compiler bugs (see docs/agents/vm-bugs.md)" do
  describe "Bug #1 (FIXED): BG ctx field type for slice fn-params" do
    # Fixed by commit 6de9a874. Before fix: ctx field typed as
    # ArrayListUnmanaged(i64), call-site value was []i64 → Zig rejected.
    # After fix: mir_lowering.lower_bg_block passes is_field: true to
    # zig_type, so dynamic arrays render as []T in ctx fields. This spec
    # is a regression guard against re-breakage.
    let(:src) { <<~CHT }
      FN consume(xs: Int64[]) RETURNS Int64 -> RETURN xs.length(); END

      FN runit(ops: Int64[]) RETURNS Int64 ->
          p: ~Int64 = BG { consume(ops); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          arr: Int64[] = [1_i64, 2_i64, 3_i64];
          n: Int64 = runit(arr);
          ASSERT n == 3, "slice-param captured into BG must compile+run";
      END
    CHT

    it "compiles and runs cleanly (guards 6de9a874)" do
      result = compile_and_run(src)
      expect(result[:ok]).to be(true), "regressed? #{result[:output]}"
    end
  end

  describe "Dangling-pointer family: slice-via-union variant + BG capture" do
    # Same root cause as the plain-slice case; added here because it's
    # the exact shape the VM's BG_SPAWN handler tried to use, and it
    # demonstrates the bug manifests identically through a union-variant
    # payload (no union magic needed for the UAF to happen).
    let(:src) { <<~CHT }
      UNION V { Nil, IntV: Int64 }

      FN consumeSlice(xs: V[]) RETURNS Int64 ->
          IF xs.length() > 0 THEN
              MATCH xs[0] START
                  V.IntV AS i -> RETURN i;,
                  DEFAULT -> RETURN 0_i64;
              END
          END
          RETURN 0_i64;
      END

      FN runit() RETURNS Int64 ->
          MUTABLE xsList: V[]@list = List[];
          xsList.append(V{ IntV: 42 });
          xsSlice: V[] = xsList;
          p: ~Int64 = BG { consumeSlice(xsSlice); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 42, "union-variant slice captured into BG";
      END
    CHT

    it "currently compiles + UAFs at runtime (same root as Bug #3)" do
      result = compile_and_run(src)
      expect(result[:phase]).to eq(:run)
      expect(result[:ok]).to be(false)
      expect(result[:output]).to match(/ASSERTION FAILED/i)
    end
  end

  describe "Bug #4 (OPEN): COPY at BG capture site → cryptic Zig error" do
    # COPY of a union literal containing a heap-owned field, captured
    # into an async BG, produces a Zig-level "expected *T found T"
    # diagnostic with no CLEAR-level context.
    let(:src) { <<~CHT }
      UNION V { Nil, IntV: Int64, Vec: V[] }

      FN consumeVec(v: V) RETURNS Int64 ->
          MATCH v START
              V.Vec AS items -> RETURN items.length();,
              DEFAULT -> RETURN 0_i64;
          END
          RETURN 0_i64;
      END

      FN runit() RETURNS Int64 ->
          MUTABLE xs: V[]@list = List[];
          xs.append(V{ IntV: 1 });
          vec: V = COPY V{ Vec: xs };
          p: ~Int64 = BG { consumeVec(vec); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 1, "COPY'd Value.Vec captured into BG";
      END
    CHT

    it "currently emits Zig 'expected *T, found T' (should be a CLEAR error)" do
      result = compile(src)
      expect(result[:ok]).to be(false),
        "Bug #4 fixed — update this spec."
      expect(result[:output]).to match(/expected type '\*T', found 'T'/i),
        "Error shape changed — partial fix may have landed."
    end
  end

  describe "Bug #3 (OPEN): slice borrow from @list captured into async BG" do
    # Safety hole. Compiler accepts the pattern; runtime UAFs because
    # the slice borrow is freed before the async fiber reads it.
    let(:src) { <<~CHT }
      FN work(xs: Int64[]) RETURNS Int64 ->
          RETURN xs.length();
      END

      FN runit() RETURNS Int64 ->
          MUTABLE lst: Int64[]@list = List[];
          lst.append(1_i64); lst.append(2_i64); lst.append(3_i64);
          slice: Int64[] = lst;
          p: ~Int64 = BG {
              work(slice);
          };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 3, "slice borrow captured into BG must be caught at compile time";
      END
    CHT

    it "currently compiles + UAFs at runtime (should be a compile-time error)" do
      result = compile_and_run(src)
      # EXPECTED after fix: compiler rejects at MIRChecker time with a
      #   borrow-escape diagnostic, so result[:phase] == :compile && :ok == false.
      # CURRENT: compiles, runs, runtime assertion fails because fiber reads freed mem.
      expect(result[:phase]).to eq(:run),
        "Bug #3 fixed — flip this spec: expect compile-phase rejection instead."
      expect(result[:ok]).to be(false)
      expect(result[:output]).to match(/ASSERTION FAILED/i)
    end
  end
end
