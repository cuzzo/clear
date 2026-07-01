require "rspec"
require "tmpdir"
require "fileutils"

# Step 6e of the alloc-as-FAULT plan (puck-clear-bugs.md #3/#12).
# Deterministic OOM fault injection (runtime.zig __oom_failing, gated
# by CLEAR_OOM_AFTER). Validates the FAULT model end-to-end:
#   - unhandled alloc fault PANICS with [System/OutOfMemory] (step 5),
#   - the SAME allocating call under `OR PASS` RECOVERS (no crash),
#   - zero behavior change when the env var is unset.
# Not a fuzz cell: fuzz cannot force allocator state. This is the
# deterministic VOPR-style fault test CLAUDE.md requires for faults.
CLEAR_BIN = File.expand_path("../../clear", __dir__) unless defined?(CLEAR_BIN)

RSpec.describe "OOM fault injection (alloc-as-FAULT model)", :integration do
  # An allocating fn (`xs.append` in a loop) -> alloc_fault -> can_fail
  # -> Zig !T. `RETURNS Int64` (plain): FAULT is surface-exempt.
  GROW = <<~CLEAR
    FN grow(n: Int64) RETURNS Int64 ->
      MUTABLE xs: Int64[]@list = [];
      MUTABLE i = 0;
      WHILE i < n DO
        xs.append(i);
        i += 1;
      END
      RETURN xs.length();
    END
  CLEAR

  def build(src)
    dir = Dir.mktmpdir("oom")
    cht = File.join(dir, "p.cht")
    bin = File.join(dir, "p")
    File.write(cht, src)
    out = `#{CLEAR_BIN} build #{cht} -o #{bin} 2>&1`
    raise "build failed: #{out}" unless $?.success? && File.exist?(bin)
    bin
  end

  def run(bin, env: "")
    out = `#{env} #{bin} 2>&1`
    [out, $?.exitstatus]
  end

  it "unset CLEAR_OOM_AFTER: no behavior change (allocates, exits clean)" do
    bin = build(GROW + <<~CLEAR)
      FN main() RETURNS Void ->
        k = grow(50_i64);
        ASSERT k == 50_i64, "grew";
        RETURN;
      END
    CLEAR
    _out, status = run(bin)
    expect(status).to eq(0)
  end

  it "unhandled alloc fault PANICS with [System/OutOfMemory] (step 5)" do
    bin = build(GROW + <<~CLEAR)
      FN main() RETURNS Void ->
        k = grow(50_i64);
        ASSERT k == 50_i64, "grew";
        RETURN;
      END
    CLEAR
    # Low index: the fault lands early (a runtime/user alloc) with no
    # OR/CATCH in scope -> must abort with the fault diagnostic.
    out, status = run(bin, env: "CLEAR_OOM_AFTER=3")
    expect(status).not_to eq(0)
    expect(out).to match(/out of memory \[System\/OutOfMemory\]/)
  end

  it "the SAME call under `OR PASS` recovers the fault (no crash)" do
    # Large alloc loop so the injected fault (past runtime startup)
    # lands inside grow(), which is guarded by `OR PASS` at the call.
    bin = build(GROW + <<~CLEAR)
      FN main() RETURNS Void ->
        k = grow(100000_i64) OR PASS;
        print("survived OOM via OR PASS\\n");
        RETURN;
      END
    CLEAR
    out, status = run(bin, env: "CLEAR_OOM_AFTER=200")
    expect(status).to eq(0)
    expect(out).to include("survived OOM via OR PASS")
    expect(out).not_to match(/System\/OutOfMemory/)
  end
end
