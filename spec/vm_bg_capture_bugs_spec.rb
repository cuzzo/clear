# Regression tests for compiler bugs documented in docs/agents/vm-bugs.md.
# Bugs in the dangling-pointer family are now handled by the closed
# CaptureStrategy decision: captures either receive a verifier-visible owned
# transfer/copy plan or fail at lowering time. These tests pin that behavior
# so regressions show up immediately.

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

RSpec.describe "VM Phase 2 compiler bugs (see docs/agents/vm-bugs.md)", :integration do
  describe "Bug #1 (FIXED): BG ctx field type for slice fn-params" do
    # Fixed by commit 6de9a874. After that fix, fn-param slices render
    # correctly as []T in the BG ctx struct. Under the CaptureStrategy
    # rules, a bare (non-Copy, non-GIVE, non-multiowned) slice capture
    # is refused — so the test has to COPY the slice to deep-copy it
    # into the fiber's scope.
    let(:src) { <<~CHT }
      FN consume(xs: Int64[]) RETURNS Int64 -> RETURN xs.length(); END

      FN runit(ops: Int64[]) RETURNS !Int64 ->
          p: ~Int64 = BG { consume(COPY ops); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          arr: Int64[] = [1_i64, 2_i64, 3_i64];
          n: Int64 = runit(arr);
          ASSERT n == 3, "slice-param + COPY captures into BG";
      END
    CHT

    it "compiles and runs cleanly with COPY" do
      result = compile_and_run(src)
      expect(result[:ok]).to be(true), "regressed? #{result[:output]}"
    end
  end

  describe "Bug #3 (FIXED): slice borrow from @list into BG" do
    # Was a silent UAF. CaptureStrategy now gives the fiber an owned copy.
    let(:src) { <<~CHT }
      FN work(xs: Int64[]) RETURNS Int64 -> RETURN xs.length(); END

      FN runit() RETURNS !Int64 ->
          MUTABLE lst: Int64[]@list = List[];
          lst.append(1_i64); lst.append(2_i64); lst.append(3_i64);
          slice: Int64[] = lst;
          p: ~Int64 = BG { work(slice); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 3, "should have been caught at compile time";
      END
    CHT

    it "compiles and runs with a verifier-visible owned capture" do
      result = compile_and_run(src)
      expect(result[:ok]).to be(true), "regressed? #{result[:output]}"
    end
  end

  describe "Bug #3 (FIXED): same root cause via union-variant slice" do
    let(:src) { <<~CHT }
      UNION V { Nil, IntV: Int64 }

      FN consumeSlice(xs: V[]) RETURNS Int64 ->
          IF xs.length() > 0 THEN
              PARTIAL MATCH xs[0] START
                  V.IntV AS i -> RETURN i;,
                  DEFAULT -> RETURN 0_i64;
              END
          END
          RETURN 0_i64;
      END

      FN runit() RETURNS !Int64 ->
          MUTABLE xsList: V[]@list = List[];
          xsList.append(V{ IntV: 42 });
          xsSlice: V[] = xsList;
          p: ~Int64 = BG { consumeSlice(xsSlice); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 42, "should have been caught at compile time";
      END
    CHT

    it "compiles and runs with a verifier-visible owned capture" do
      result = compile_and_run(src)
      expect(result[:ok]).to be(true), "regressed? #{result[:output]}"
    end
  end

  describe "Bug #4 (FIXED): COPY'd union literal + BG" do
    # The cryptic "expected *T, found T" Zig error was a downstream symptom
    # of missing ownership transfer data. The capture plan now gives the BG
    # body an owned value instead of producing bad Zig.
    let(:src) { <<~CHT }
      UNION V { Nil, IntV: Int64, Vec: V[] }

      FN consumeVec(v: V) RETURNS Int64 ->
          PARTIAL MATCH v START
              V.Vec AS items -> RETURN items.length();,
              DEFAULT -> RETURN 0_i64;
          END
          RETURN 0_i64;
      END

      FN runit() RETURNS !Int64 ->
          MUTABLE xs: V[]@list = List[];
          xs.append(V{ IntV: 1 });
          vec: V = COPY V{ Vec: xs };
          p: ~Int64 = BG { consumeVec(COPY vec); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 1, "should be caught at compile time";
      END
    CHT

    it "compiles and runs without the old Zig type error" do
      result = compile_and_run(src)
      expect(result[:ok]).to be(true), "regressed? #{result[:output]}"
    end
  end

  describe "Escape hatches work: GIVE inside BG body transfers ownership" do
    # The fiber takes ownership via the BG capture; outer scope's cleanup
    # is suppressed (lst_moved guard). Verifies the full pipeline:
    # ownership dataflow -> SuppressCleanup insertion -> capture-map
    # rewriting in lower_move -> guarded outer defer.
    let(:src) { <<~CHT }
      FN consume!(TAKES xs: Int64[]) RETURNS Int64 -> RETURN xs.length(); END

      FN runit() RETURNS !Int64 ->
          MUTABLE lst: Int64[]@list = List[];
          lst.append(1_i64); lst.append(2_i64); lst.append(3_i64);
          p: ~Int64 = BG { consume!(GIVE lst); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 3, "GIVE inside BG transfers ownership to fiber";
      END
    CHT

    it "compiles and runs cleanly (no double-free, no UAF)" do
      result = compile_and_run(src)
      expect(result[:ok]).to be(true), "regressed? #{result[:output]}"
    end
  end

  describe "Bug #7 (FIXED): COPY of an @list fn-param captured into BG" do
    let(:src) { <<~CHT }
      FN consume(xs: Int64[]@list) RETURNS Int64 -> RETURN xs.length(); END

      FN runit(TAKES ops: Int64[]@list) RETURNS !Int64 ->
          p: ~Int64 = BG { consume(COPY ops); };
          RETURN NEXT p;
      END

      FN main() RETURNS !Void ->
          MUTABLE arr: Int64[]@list = List[];
          arr.append(1_i64); arr.append(2_i64); arr.append(3_i64);
          n: Int64 = runit(GIVE arr) OR RAISE;
          ASSERT n == 3, "@list-param + COPY captures into BG";
      END
    CHT

    it "compiles and runs cleanly (ctx field is the owned dupe type)" do
      result = compile_and_run(src)
      expect(result[:ok]).to be(true), "regressed? #{result[:output]}"
    end
  end

end
