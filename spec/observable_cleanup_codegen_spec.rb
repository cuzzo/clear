require "rspec"
require_relative "../src/backends/transpiler" unless defined?(ZigTranspiler)

# A14: pin H4's load-bearing invariant — every `~T@observable` and
# `~T[]@set:observable` binding must emit `wait(); destroy(...)` (in
# that order) at scope exit. Destroying before the producer finishes
# is a UAF on the inner accumulator; running tests to catch it would
# only surface the bug as a flaky leak/UAF in the DebugAllocator. The
# codegen-shape assertion makes any regression a deterministic spec
# failure.
RSpec.describe CleanupClassifier do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  let(:scalar_zig) do
    transpile(<<~CLEAR)
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
  end

  let(:collection_zig) do
    transpile(<<~CLEAR)
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
  end

  # Cleanup is now uniform via CheatLib.cleanup; the wait()-before-
  # destroy() ordering is enforced in the runtime arm at runtime-header.zig
  # (zig/runtime/runtime-header.zig, isObservableWrapper detection). What
  # the codegen pins is: the binding's cleanup goes through CheatLib.cleanup
  # with the heap allocator (not frameAlloc), so the runtime arm fires.
  it "routes scalar observable cleanup through CheatLib.cleanup with heapAlloc" do
    expect(scalar_zig).to include("defer CheatLib.cleanup(")
    expect(scalar_zig).to include("&running")
    expect(scalar_zig).to match(/CheatLib\.cleanup\([^,]+,\s*rt\.heapAlloc\(\),\s*&running\)/)
    expect(scalar_zig).not_to match(/CheatLib\.cleanup\([^,]+,\s*rt\.frameAlloc\(\),\s*&running\)/)
  end

  it "routes collection observable cleanup through CheatLib.cleanup with heapAlloc" do
    expect(collection_zig).to include("defer CheatLib.cleanup(")
    expect(collection_zig).to include("&running")
    expect(collection_zig).to match(/CheatLib\.cleanup\([^,]+,\s*rt\.heapAlloc\(\),\s*&running\)/)
    expect(collection_zig).not_to match(/CheatLib\.cleanup\([^,]+,\s*rt\.frameAlloc\(\),\s*&running\)/)
  end
end
