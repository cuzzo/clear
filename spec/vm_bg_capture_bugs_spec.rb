# Regression tests for compiler bugs documented in docs/agents/vm-bugs.md.
# All bugs in the "dangling-pointer family" are now caught at lowering
# time via CaptureStrategy::Refuse. These tests pin the current behavior
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

  describe "Bug #3 (FIXED via CaptureStrategy::Refuse): slice borrow from @list into BG" do
    # Was a silent UAF. CaptureStrategy now Refuses at lowering time.
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

    it "refuses at compile time with a CLEAR-level diagnostic" do
      result = compile(src)
      expect(result[:ok]).to be(false), "expected compile refusal, got success"
      expect(result[:output]).to match(/cannot safely cross the fiber boundary/i)
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

    it "refuses at compile time with a CLEAR-level diagnostic" do
      result = compile(src)
      expect(result[:ok]).to be(false)
      expect(result[:output]).to match(/cannot safely cross the fiber boundary/i)
    end
  end

  describe "Bug #4 (FIXED as side effect of Refuse): COPY'd union literal + BG" do
    # The cryptic "expected *T, found T" Zig error was a downstream
    # symptom of the same missing ownership transfer. With CaptureStrategy::
    # Refuse firing, the program is rejected at CLEAR level before the
    # bad Zig ever gets generated.
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
          p: ~Int64 = BG { consumeVec(vec); };
          RETURN NEXT p;
      END

      FN main() RETURNS Void ->
          n: Int64 = runit();
          ASSERT n == 1, "should be caught at compile time";
      END
    CHT

    it "produces a CLEAR-level diagnostic, not a Zig type error" do
      result = compile(src)
      expect(result[:ok]).to be(false)
      expect(result[:output]).to match(/cannot safely cross the fiber boundary/i)
      # The old, cryptic Zig diagnostic must NOT surface anymore:
      expect(result[:output]).not_to match(/expected type '\*T', found 'T'/i)
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

  # Bug #7 -- the @list-PARAM sibling of Bug #1 (which fixed the
  # slice-param case). Root cause: FiberCtxBuilder's FreshHeapCopy /
  # COPY path (src/mir/fiber_ctx_builder.rb:~127) types the BG ctx
  # field as `@TypeOf(source_ref)` -- the ORIGINAL captured binding --
  # but the field actually stores `dupe_var` (the deep-copied owned
  # value). For a *local* @list or a *slice* param @TypeOf(source) ~=
  # @TypeOf(dupe), so it works (Bug #1). For an `@list` *parameter*
  # the source is a borrowed `*const ArrayList(T)`, so the ctx field
  # is declared `*const ArrayList` while it stores an owned dupe ->
  # generated Zig `error: expected '*T', found '*const T'`
  # (T = array_list.Aligned(...)). Architecturally-correct fix: the
  # ctx field type must describe the value it holds (the dupe), not
  # the source it was copied from.
  #
  # Isolation matrix (all verified 2026-05-18):
  #   COPY local @list   -> @list param, in BG   : OK
  #   COPY slice param   -> slice param, in BG    : OK (Bug #1 fix)
  #   COPY @list param   -> @list param, no BG    : OK
  #   COPY @list param   -> @list param, in BG    : OK (this fix)
  #
  # FIXED 2026-05-18 by three complementary, architecturally-correct
  # changes: (a) src/mir/mir_pass.rb insert_bg_escape_promote! skips
  # in-place promoteList for *parameters* (borrowed/caller-owned, the
  # COPY strategy deep-copies them); (b) FiberCtxBuilder's
  # FreshHeapCopy ctx field type + dupe are a single source of truth
  # via CheatLib.CapturedValue(@TypeOf(src)) / dupeCaptured (the
  # owned value type, not a `*const` alias of the source); (c) that
  # strip is scoped to `*const T` (a CLEAR borrow) ONLY -- a NON-const
  # `*T` owned heap box (`*Locked(T)`, Arc, Box) passes through so the
  # @locked-local body+cleanup pipeline (lockedDestroy) is unchanged.
  # Also regression-locked by tools/fuzz/templates/bg_capture_typing.rb.
  describe "Bug #7 (FIXED): COPY of an @list fn-param captured into BG" do
    let(:src) { <<~CHT }
      FN consume(xs: Int64[]@list) RETURNS Int64 -> RETURN xs.length(); END

      FN runit(ops: Int64[]@list) RETURNS !Int64 ->
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

  # Bug #8 (OPEN, separate): a bare String[]@list COPY'd into a BG
  # fiber double-frees its element strings under the leak-detecting
  # allocator (both local + param origin). Distinct from Bug #7
  # (cleanup-ownership, not ctx-field typing); only exposed once
  # Bug #7's compile error was removed. Not asserted here because
  # compile_and_run uses the C allocator (no double-free detection);
  # it reproduces under `./clear test`. Tracked in
  # docs/agents/vm-bugs.md "Bug #8" for its own standalone fix
  # (which re-enables the :string cells in
  # tools/fuzz/templates/bg_capture_typing.rb).
end
