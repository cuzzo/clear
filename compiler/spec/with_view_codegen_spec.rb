require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Phase 2.5/2.6/2.7 — transpile WITH VIEW / WITH MATERIALIZED VIEW.
# Verifies the emitted Zig calls the runtime's uniform `.view()` /
# `.materialize(allocator)` methods. The runtime types (AtomicSum,
# StreamSet, Observable<T>) all expose these uniformly; the codegen
# is shape-agnostic.
RSpec.describe "WITH VIEW / WITH MATERIALIZED VIEW codegen" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  def fn_body(zig, name)
    zig[/fn #{name}\b.*?\n(.*?)^\}/m, 1] || ""
  end

  describe "Phase 2.5 — scalar WITH VIEW" do
    # Use a fold-piped binding so the lift-to-observable-terminal flow
    # runs (the binding's full_type carries observable_terminal). A
    # synthetic parameter typed `~T@observable` would bypass the lift
    # and trigger the strict "missing terminal kind" check (C5).
    let(:zig) do
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Int64@observable = gen |> SUM _;
            WITH VIEW running AS s {
                ASSERT s >= 0_i64, "started";
            }
            _ = NEXT running;
            RETURN;
        END
      CLEAR
    end

    it "emits `const s = running.view()`" do
      # Use full Zig output rather than fn_body — the BG STREAM block
      # emits a nested struct whose first `^}` ends the inner type,
      # not clearMain, fooling the simple fn_body regex.
      body = zig
      expect(body).to match(/const s = running\.view\(\);/)
    end

    it "anchors the alias against optimizer elision (`_ = &s`)" do
      # Use full Zig output rather than fn_body — the BG STREAM block
      # emits a nested struct whose first `^}` ends the inner type,
      # not clearMain, fooling the simple fn_body regex.
      body = zig
      expect(body).to include("_ = &s;")
    end

    it "does not emit a defer/release (scalar VIEW is a value copy)" do
      # Use full Zig output rather than fn_body — the BG STREAM block
      # emits a nested struct whose first `^}` ends the inner type,
      # not clearMain, fooling the simple fn_body regex.
      body = zig
      view_section = body[/const s = running\.view\(\);.*?\n\}/m] || ""
      expect(view_section).not_to include("defer s.release")
    end
  end

  describe "Phase 2.7 — WITH MATERIALIZED VIEW" do
    let(:zig) do
      transpile(<<~CLEAR)
        FN main() RETURNS Void ->
            gen: ~?Int64[] = BG STREAM {
                MUTABLE i: Int64 = 0_i64;
                WHILE i < 4_i64 DO YIELD i; i = i + 1_i64; END
            };
            running: ~Int64@observable = gen |> SUM _;
            WITH MATERIALIZED VIEW running AS s {
                ASSERT s >= 0_i64, "ok";
            }
            _ = NEXT running;
            RETURN;
        END
      CLEAR
    end

    it "emits `var s = try running.materialize(__clear_heap_alloc)` (owned, escapable)" do
      # Allocator is the function-scoped heap allocator (not `self.allocator`) so the
      # snapshot survives outside struct-method context too. `try`
      # propagates the allocation error from inner.materialize.
      # Use full Zig output rather than fn_body — the BG STREAM block
      # emits a nested struct whose first `^}` ends the inner type,
      # not clearMain, fooling the simple fn_body regex.
      body = zig
      expect(body).to match(/var s = try running\.materialize\(__clear_heap_alloc\);/)
    end
  end
end
