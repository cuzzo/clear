# Template: capability-wrap composition matrix — ENUMERATED.
#
# Targets src/mir/mir_lowering.rb#compose_capability_wrap. The
# discriminant set is read from the dispatch itself:
#   sync_fn  = case ft.sync  {locked, write_locked, always_mutable,
#                             versioned, atomic}
#   own_fn   = case ft.ownership {shared->arc, multiowned->rc}
#   + the 4-way sync_fn&&own_fn / sync_only / own_only / else.
# One cell per sync mode + one per ownership wrap = exhaustive over
# the dispatch labels. Every surface form is CONFIRMED from
# transpile-tests (all sigils occur there); every cell is active.
#
# expected :pass; a failing/leaking :pass cell is a SURFACED bug.

CWM_CELLS = %i[
  locked write_locked always_mutable versioned atomic_ptr
  multiowned shared shared_locked shared_write_locked shared_versioned shared_atomic
].map { |m| { mode: m } }

%i[
  locked_direct_field write_locked_direct_field atomic_ptr_direct_field
  snapshot_plain borrowed_shared borrowed_write_locked
  materialized_plain view_plain
  observable_direct_index observable_direct_binary observable_direct_field observable_direct_method
].each do |m|
  CWM_CELLS << { mode: m, expected: :compile_error }
end

%i[
  restrict_plain materialized_distinct observable_view
].each do |m|
  CWM_CELLS << { mode: m }
end

FuzzGenerator.register(:capability_wrap_matrix, cells: CWM_CELLS) do |p|
  case p[:mode]
  when :locked
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @locked;
          WITH EXCLUSIVE c AS r {
              ASSERT r.value == 1_i64, "locked wrap read";
          }
          RETURN;
      END
    CHT
  when :write_locked
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @writeLocked;
          WITH EXCLUSIVE c AS r {
              ASSERT r.value == 1_i64, "writeLocked wrap read";
          }
          RETURN;
      END
    CHT
  when :always_mutable
    # Interior mutability: immutable binding, mutable data, direct.
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @alwaysMutable;
          c.value = 2_i64;
          ASSERT c.value == 2_i64, "alwaysMutable interior mutate";
          RETURN;
      END
    CHT
  when :versioned
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @versioned;
          WITH SNAPSHOT c AS r {
              ASSERT r.value == 1_i64, "versioned snapshot read";
          }
          RETURN;
      END
    CHT
  when :atomic_ptr
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @boxed:atomic;
        WITH SNAPSHOT c AS MUTABLE x {
            x.value = 2_i64;
            ASSERT x.value == 2_i64, "atomic-ptr exclusive mutate";
        }
          RETURN;
      END
    CHT
  when :multiowned
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          p = Counter{ value: 1_i64 } @multiowned;
          ASSERT p.value == 1_i64, "multiowned (rc) read";
          RETURN;
      END
    CHT
  when :shared
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          t = Counter{ value: 1_i64 } @shared;
          ASSERT t.value == 1_i64, "shared (arc) read";
          RETURN;
      END
    CHT
  when :shared_locked
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE t = Counter{ value: 1_i64 } @shared:locked;
          WITH EXCLUSIVE t AS r {
              ASSERT r.value == 1_i64, "shared:locked (arc+lock) read";
          }
          RETURN;
      END
    CHT
  when :shared_write_locked
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE t = Counter{ value: 1_i64 } @shared:writeLocked;
          WITH EXCLUSIVE t AS r {
              ASSERT r.value == 1_i64, "shared:writeLocked (arc+rwlock) read";
          }
          RETURN;
      END
    CHT
  when :shared_versioned
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE t = Counter{ value: 1_i64 } @shared:versioned;
          WITH SNAPSHOT t AS r {
              ASSERT r.value == 1_i64, "shared:versioned (arc+mvcc) read";
          }
          RETURN;
      END
    CHT
  when :shared_atomic
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE t: Int64 = 1_i64 @shared:atomic;
          ASSERT t == 1_i64, "shared:atomic primitive read";
          RETURN;
      END
    CHT
  when :locked_direct_field
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @locked;
          _ = c.value;
          RETURN;
      END
    CHT
  when :write_locked_direct_field
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @writeLocked;
          _ = c.value;
          RETURN;
      END
    CHT
  when :atomic_ptr_direct_field
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @boxed:atomic;
          _ = c.value;
          RETURN;
      END
    CHT
  when :restrict_plain
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 };
          WITH RESTRICT c AS MUTABLE r { r.value = 2_i64; }
          RETURN;
      END
    CHT
  when :snapshot_plain
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 };
          WITH SNAPSHOT c AS r { _ = r.value; }
          RETURN;
      END
    CHT
  when :borrowed_shared
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @shared;
          WITH BORROWED c AS r { _ = r.value; }
          RETURN;
      END
    CHT
  when :borrowed_write_locked
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          c = Counter{ value: 1_i64 } @writeLocked;
          WITH BORROWED c AS r { _ = r.value; }
          RETURN;
      END
    CHT
  when :materialized_plain
    <<~CHT
      FN main() RETURNS Void ->
          n: Int64 = 1_i64;
          WITH MATERIALIZED VIEW n AS snap { _ = snap; }
          RETURN;
      END
    CHT
  when :view_plain
    <<~CHT
      FN main() RETURNS Void ->
          n: Int64 = 1_i64;
          WITH VIEW n AS snap { _ = snap; }
          RETURN;
      END
    CHT
  when :materialized_distinct
    <<~CHT
      FN main() RETURNS Void ->
          s: ~?Int64[] = BG STREAM { YIELD 1_i64; YIELD 1_i64; YIELD 2_i64; };
          vals: ~Int64[]@set:observable = s |> DISTINCT _;
          WITH MATERIALIZED VIEW vals AS snap { _ = snap.length(); }
          RETURN;
      END
    CHT
  when :observable_view
    <<~CHT
      FN main() RETURNS Void ->
          stream: ~?Int64[] = BG STREAM { YIELD 1_i64; YIELD 2_i64; };
          running: ~Int64@observable = stream |> SUM _;
          WITH VIEW running AS snapshot {
              ASSERT snapshot >= 0_i64, "observable view lower bound";
              ASSERT snapshot <= 3_i64, "observable view upper bound";
          }
          ASSERT (NEXT running) == 3_i64, "observable final value";
          RETURN;
      END
    CHT
  when :observable_direct_index
    <<~CHT
      FN invalid(values: ~Int64[]@set:observable) RETURNS ?Int64 ->
          RETURN values[0_i64];
      END

      FN main() RETURNS Void -> RETURN; END
    CHT
  when :observable_direct_binary
    <<~CHT
      FN invalid(value: ~Int64@observable) RETURNS Bool ->
          RETURN value > 0_i64;
      END

      FN main() RETURNS Void -> RETURN; END
    CHT
  when :observable_direct_field
    <<~CHT
      STRUCT Reading { value: Int64 }

      FN invalid(reading: ~Reading@observable) RETURNS Int64 ->
          RETURN reading.value;
      END

      FN main() RETURNS Void -> RETURN; END
    CHT
  when :observable_direct_method
    <<~CHT
      FN invalid(values: ~Int64[]@set:observable) RETURNS Int64 ->
          RETURN values.length();
      END

      FN main() RETURNS Void -> RETURN; END
    CHT
  end
end
