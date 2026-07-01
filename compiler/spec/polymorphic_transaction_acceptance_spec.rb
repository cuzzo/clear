require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# True-Sync-Polymorphism — ACCEPTANCE CRITERIA spec.
#
# This is the milestone's headline: a single transaction function body
# works correctly across every sync strategy CLEAR supports, AND the
# lowering is honest -- no silent upgrade to @shared, no silent
# blocking, no silent allocation, no silent retry where the user said
# "no sync."
#
# The ideal endpoint:
#
#   STRUCT Counter { value: Int64 }
#
#   FN tick!(MUTABLE c: Counter) RETURNS Int64 ->
#     MUTABLE r: Int64 = 0_i64;
#     WITH POLYMORPHIC c AS x { x.value = x.value + 1; r = x.value; }
#     RETURN r;
#   END
#
# called from EVERY binding kind: @local, @multiowned, @locked,
# @writeLocked, @versioned, @atomic primitive, @indirect:atomic,
# @shared:locked, @shared:writeLocked, @shared:versioned -- and the
# emitter generates the right Zig per case (no-op for non-sync,
# acquire/release for lock-style, snapshot/CAS for snapshot-style).
#
# Until the REQUIRES taxonomy admits @local / @multiowned uniformly,
# the "single function" form is `pending`. Today each sync family has
# its own narrow REQUIRES (LOCKED for mutex/rwlock; SNAPSHOTTED /
# VERSIONED / ATOMIC for the snapshot-style families); per-family
# lowering is verified below. The unified-fn case is the explicit
# pending acceptance criterion that closes the milestone.
RSpec.describe "Polymorphic transaction function — acceptance" do
  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  # The transaction body shared across every fixture below. The fn
  # name is sync-suffixed so the assertions can isolate the relevant
  # generated function.
  def fn_with_requires(suffix:, requires_clause:, with_form:)
    <<~CLEAR
      STRUCT Counter#{suffix} { value: Int64 }
      FN tick_#{suffix}!(MUTABLE c: Counter#{suffix}) RETURNS !Int64
        #{requires_clause}
      ->
        MUTABLE r: Int64 = 0_i64;
        #{with_form}
        RETURN r;
      END
    CLEAR
  end

  # ── 1. LOCKED family lowers to mutex acquire / release ─────────

  describe "@shared:locked binding lowers via acquire/release" do
    it "emits .acquire() + .release(); does NOT emit Versioned.update or AtomicPtr.update" do
      src = fn_with_requires(
        suffix: "Locked",
        requires_clause: "REQUIRES c: LOCKED",
        with_form: "WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; r = x.value; }",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterLocked{ value: 0 } @shared:locked;
          _ = tick_Locked!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)

      # Lock semantics present.
      expect(zig).to include(".acquire()")
      expect(zig).to include(".release()")

      # The tick_Locked function body MUST NOT contain snapshot/atomic
      # operations -- no silent upgrade.
      tick_body = zig[/fn tick_Locked.*?\nfn /m] || zig[/fn tick_Locked.*/m]
      expect(tick_body).not_to include("Versioned.update")
      expect(tick_body).not_to include("AtomicPtr.update")
      expect(tick_body).not_to include("UpdateRetriesExhausted")
    end
  end

  describe "@shared:writeLocked binding lowers via write-lock acquire" do
    it "uses the same .acquire() shape (RWLock.write/.acquire); no upgrade" do
      src = fn_with_requires(
        suffix: "WriteLocked",
        requires_clause: "REQUIRES c: LOCKED",
        with_form: "WITH POLYMORPHIC EXCLUSIVE c AS x { x.value = x.value + 1; r = x.value; }",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterWriteLocked{ value: 0 } @shared:writeLocked;
          _ = tick_WriteLocked!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      expect(zig).to include(".acquire()")
      expect(zig).to include(".release()")
      tick_body = zig[/fn tick_WriteLocked.*?\nfn /m] || zig[/fn tick_WriteLocked.*/m]
      expect(tick_body).not_to include("Versioned.update")
      expect(tick_body).not_to include("AtomicPtr.update")
    end
  end

  # ── 2. VERSIONED lowers via Versioned.update + MvccConflict bridge ──

  describe "@versioned / @shared:versioned binding lowers via Versioned.update" do
    it "emits .update(rt, .heapAlloc()) with the MvccConflict catch bridge; no .acquire()" do
      src = fn_with_requires(
        suffix: "Versioned",
        requires_clause: "REQUIRES c: VERSIONED",
        with_form: "WITH SNAPSHOT c AS MUTABLE x { x.value = x.value + 1; r = x.value; } ON MvccConflict RAISE",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterVersioned{ value: 0 } @shared:versioned;
          _ = tick_Versioned!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)

      tick_body = zig[/fn tick_Versioned.*?\nfn /m] || zig[/fn tick_Versioned.*/m]
      expect(tick_body).to include(".update(rt, rt.heapAlloc()")
      expect(tick_body).to include("error.UpdateRetriesExhausted")
      expect(tick_body).to include("ErrorName.MvccConflict")

      # No silent lock acquire / release.
      expect(tick_body).not_to match(/\.acquire\(\)/)
      expect(tick_body).not_to match(/\.release\(\)/)
    end
  end

  # ── 3. ATOMIC indirect lowers via AtomicPtr.update ────────────

  describe "@indirect:atomic binding lowers via AtomicPtr.update" do
    it "emits .update(rt, .heapAlloc()) with the AtomicConflict catch bridge (#330: bounded at 256)" do
      src = fn_with_requires(
        suffix: "Atomic",
        requires_clause: "REQUIRES c: ATOMIC",
        with_form: "WITH SNAPSHOT c AS MUTABLE x { x.value = x.value + 1; r = x.value; }",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterAtomic{ value: 0 } @indirect:atomic;
          _ = tick_Atomic!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)

      tick_body = zig[/fn tick_Atomic.*?\nfn /m] || zig[/fn tick_Atomic.*/m]
      expect(tick_body).to include(".update(rt, rt.heapAlloc()")

      # No mutex acquire/release.
      expect(tick_body).not_to match(/\.acquire\(\)/)
      expect(tick_body).not_to match(/\.release\(\)/)

      # #330: AtomicPtr.update is bounded at 256 retries. The catch
      # bridge surfaces error.AtomicConflict -> ErrorName.AtomicConflict
      # for the per-WITH ON / SYNC POLICY chain.
      expect(tick_body).to include("error.AtomicConflict")
      expect(tick_body).to include("ErrorName.AtomicConflict")

      # MvccConflict must NOT appear -- atomic-pointer commits never
      # raise it (no silent cross-family error propagation).
      expect(tick_body).not_to include("error.UpdateRetriesExhausted")
      expect(tick_body).not_to include("ErrorName.MvccConflict")
    end
  end

  # ── 4. SNAPSHOTTED polymorphic — verifies comptime dispatch ──

  describe "REQUIRES c: SNAPSHOTTED + WITH SNAPSHOT lowers polymorphically" do
    it "emits one body that comptime-dispatches to Versioned.update OR AtomicPtr.update" do
      src = fn_with_requires(
        suffix: "Snapshotted",
        requires_clause: "REQUIRES c: SNAPSHOTTED",
        with_form: "WITH SNAPSHOT c AS MUTABLE x { x.value = x.value + 1; r = x.value; } ON MvccConflict RAISE",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c1 = CounterSnapshotted{ value: 0 } @versioned;
          _ = tick_Snapshotted!(c1);
          RETURN;
        END
      CLEAR
      zig = transpile(src)

      tick_body = zig[/fn tick_Snapshotted.*?\nfn /m] || zig[/fn tick_Snapshotted.*/m]
      # The polymorphic shape uses comptime probes (`@hasField` / `@hasDecl`)
      # that resolve per actual-type at the call site.
      expect(tick_body).to include("comptime")
      expect(tick_body).to include(".update(rt, rt.heapAlloc()")
    end
  end

  # ── 5. NON-SHARED bindings: WITH should be a no-op ────────────

  describe "ACCEPTANCE: non-shared bindings (@local, @multiowned, plain T) are no-op" do
    # All three now work as no-op WITH POLYMORPHIC via the LOCAL
    # REQUIRES family added in #336. The body lowers to a direct
    # alias (no lock, no Arc unwrap, no snapshot, no atomic op).
    it "@local binding compiles and lowers WITH to direct field access (no lock, no snapshot, no Arc)" do
      src = fn_with_requires(
        suffix: "Local",
        requires_clause: "REQUIRES c: LOCAL",
        with_form: "WITH POLYMORPHIC c AS x { x.value = x.value + 1; r = x.value; }",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterLocal{ value: 0 } @local;
          _ = tick_Local!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      tick_body = zig[/fn tick_Local.*?\nfn /m] || zig[/fn tick_Local.*/m]
      # No-op assertion: tick body must NOT contain any sync ops.
      expect(tick_body).not_to match(/\.acquire\(\)/)
      expect(tick_body).not_to match(/\.update\(rt, rt\.heapAlloc/)
      expect(tick_body).not_to include("error.UpdateRetriesExhausted")
      expect(tick_body).not_to include("error.AtomicConflict")
      expect(tick_body).to include("const x = (if (comptime @typeInfo(@TypeOf(c)) == .pointer)")
      expect(tick_body).not_to include("const x = c.*;")
    end

    it "@multiowned binding compiles and lowers WITH to Rc deref (no lock, no snapshot)" do
      src = fn_with_requires(
        suffix: "Multi",
        requires_clause: "REQUIRES c: LOCAL",
        with_form: "WITH POLYMORPHIC c AS x { x.value = x.value + 1; r = x.value; }",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterMulti{ value: 0 } @multiowned;
          _ = tick_Multi!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      tick_body = zig[/fn tick_Multi.*?\nfn /m] || zig[/fn tick_Multi.*/m]
      expect(tick_body).not_to match(/\.acquire\(\)/)
      expect(tick_body).not_to match(/\.update\(rt, rt\.heapAlloc/)
      expect(tick_body).to include("comptime @hasField")
      expect(tick_body).not_to include("const x = c.*;")
    end

    it "read-only @multiowned polymorphic aliases use the structural payload unwrap" do
      src = fn_with_requires(
        suffix: "ReadMulti",
        requires_clause: "REQUIRES c: LOCAL",
        with_form: "WITH POLYMORPHIC c AS x { r = x.value; }",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterReadMulti{ value: 0 } @multiowned;
          _ = tick_ReadMulti!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      tick_body = zig[/fn tick_ReadMulti.*?\nfn /m] || zig[/fn tick_ReadMulti.*/m]
      expect(tick_body).to include("comptime @hasField")
      expect(tick_body).not_to include("const x = c.*;")
    end

    it "plain T (no capability) compiles and lowers WITH to direct field access" do
      src = fn_with_requires(
        suffix: "Plain",
        requires_clause: "REQUIRES c: LOCAL",
        with_form: "WITH POLYMORPHIC c AS x { x.value = x.value + 1; r = x.value; }",
      ) + <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE c = CounterPlain{ value: 0 };
          _ = tick_Plain!(c);
          RETURN;
        END
      CLEAR
      zig = transpile(src)
      tick_body = zig[/fn tick_Plain.*?\nfn /m] || zig[/fn tick_Plain.*/m]
      expect(tick_body).not_to match(/\.acquire\(\)/)
      expect(tick_body).not_to match(/\.update\(rt, rt\.heapAlloc/)
    end
  end

  # ── 6. THE HEADLINE: one fn body, every sync strategy ─────────

  describe "ACCEPTANCE: ONE polymorphic transaction fn for ALL sync strategies" do
    # The endpoint: a single tick! that admits every sync (LOCKED,
    # SNAPSHOTTED, ATOMIC, plus non-sync local / multiowned / plain),
    # comptime-dispatches per family, and the lowering is honest --
    # the lock-only branch never runs an atomic op, the atomic-only
    # branch never runs a lock acquire, the local branch is pure
    # field access. When this passes (no `pending`), the milestone
    # is complete.
    it "compiles a single tick! body that is called from 6+ sync strategies " \
       "(real end-to-end verification in transpile-tests/350_polymorphic_unified_tick.clear)" do
      # This spec verifies the codegen path -- the generated Zig contains the
      # comptime-dispatch helper call. The behavioral verification (build +
      # run + ASSERT each family yields the right cumulative value) lives in
      # the transpile-test, so a regression in either layer fails loudly.
      #
      # Note: plain T (no @local/@multiowned/sync) is excluded because Zig's
      # pass-by-value semantics drop mutations to the local copy. Closing
      # that case is a calling-convention change, not a sync-poly change.
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }

        FN tick!(MUTABLE c: Counter) RETURNS !Void ->
          WITH POLYMORPHIC c AS x { x.value = x.value + 1; }
          RETURN;
        END

        FN main() RETURNS !Void ->
          MUTABLE local_c     = Counter{ value: 0 } @local;
          MUTABLE multi_c     = Counter{ value: 0 } @multiowned;
          MUTABLE locked_c    = Counter{ value: 0 } @shared:locked;
          MUTABLE wlocked_c   = Counter{ value: 0 } @shared:writeLocked;
          MUTABLE versioned_c = Counter{ value: 0 } @shared:versioned;
          MUTABLE atomic_c    = Counter{ value: 0 } @indirect:atomic;

          tick!(local_c)     OR EXIT;
          tick!(multi_c)     OR EXIT;
          tick!(locked_c)    OR EXIT;
          tick!(wlocked_c)   OR EXIT;
          tick!(versioned_c) OR EXIT;
          tick!(atomic_c)    OR EXIT;

          RETURN;
        END
      CLEAR
      zig = transpile(src)
      # Codegen contract: one shared body, one helper call -- the
      # comptime dispatch lives inside CheatLib.polymorphicMutate.
      expect(zig).to include("CheatLib.polymorphicMutate(")
      # The body becomes a no-capture closure with the matching signature.
      expect(zig).to match(/fn run\(x: \*Counter\) void/)
      # No per-family duplication: only ONE tick fn in the output.
      expect(zig.scan(/^fn tick\b/m).length).to eq(1)
    end
  end

  # ── 7. NEGATIVE: silent-upgrade detection ─────────────────────

  describe "NEGATIVE: no silent upgrade between sync families" do
    it "REQUIRES c: LOCKED + caller passes @versioned → call-site error (no silent upgrade)" do
      # The annotator must reject -- it cannot pretend a versioned
      # cell is a locked cell.
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN bump!(MUTABLE c: C) RETURNS Void
          REQUIRES c: LOCKED
        ->
          WITH POLYMORPHIC EXCLUSIVE c AS x { x.v = x.v + 1; }
          RETURN;
        END
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @versioned;
          bump!(c);
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/family VERSIONED.*not.*accepted|not accepted by this function/m)
    end

    it "REQUIRES c: VERSIONED + caller passes @shared:locked → call-site error" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN bump!(MUTABLE c: C) RETURNS !Void
          REQUIRES c: VERSIONED
        ->
          WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; } ON MvccConflict RAISE
          RETURN;
        END
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @shared:locked;
          bump!(c);
          RETURN;
        END
      CLEAR
      expect { transpile(src) }.to raise_error(/family LOCKED.*not.*accepted|not accepted by this function/m)
    end
  end
end
