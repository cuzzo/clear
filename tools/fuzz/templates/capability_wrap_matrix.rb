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
# transpile-tests (all sigils occur there); nothing is :in_dev.
#
# expected :pass; a failing/leaking :pass cell is a SURFACED bug.

CWM_CELLS = %i[
  locked write_locked always_mutable versioned atomic
  multiowned shared_locked
].map { |m| { mode: m } }

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
  when :atomic
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 1_i64 } @indirect:atomic;
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
  end
end
