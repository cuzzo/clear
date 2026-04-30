require "rspec"
require_relative "../src/backends/transpiler"

# A14: pin H4's load-bearing invariant — every `~T@observable` and
# `~T[]@set:observable` binding must emit `wait(); destroy(...)` (in
# that order) at scope exit. Destroying before the producer finishes
# is a UAF on the inner accumulator; running tests to catch it would
# only surface the bug as a flaky leak/UAF in the DebugAllocator. The
# codegen-shape assertion makes any regression a deterministic spec
# failure.
RSpec.describe ":observable cleanup codegen shape" do
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
          running: ~Int64@observable = gen s> SUM _;
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
          running: ~Int64[]@set:observable = gen s> DISTINCT _;
          final = NEXT running;
          RETURN;
      END
    CLEAR
  end

  it "emits wait() before destroy() for scalar observables" do
    # Single brace-block defer ensures the two calls run together at scope
    # exit. wait() must precede destroy() — otherwise destroy frees the
    # inner mid-publish (UAF). The order assertion is what makes this a
    # codegen contract instead of a documented invariant.
    expect(scalar_zig).to match(
      /defer\s*\{\s*running\.wait\(\);\s*running\.destroy\(rt\.heapAlloc\(\)\);\s*\}/
    )
  end

  it "destroys via heapAlloc for scalar observables" do
    # A1 made entry[:alloc] reliable for tense_observable bindings. Pin
    # the destroy allocator so a regression in cleanup_allocator (A21
    # area) doesn't silently emit frameAlloc() and surface as a leak.
    expect(scalar_zig).not_to include("running.destroy(rt.frameAlloc()")
    expect(scalar_zig).to include("running.destroy(rt.heapAlloc())")
  end

  it "emits wait() before destroy() for collection observables (DISTINCT)" do
    expect(collection_zig).to match(
      /defer\s*\{\s*running\.wait\(\);\s*running\.destroy\(rt\.heapAlloc\(\)\);\s*\}/
    )
  end

  it "destroys via heapAlloc for collection observables" do
    expect(collection_zig).not_to include("running.destroy(rt.frameAlloc()")
    expect(collection_zig).to include("running.destroy(rt.heapAlloc())")
  end
end
