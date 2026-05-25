# Template: cleanup-classifier shape matrix.
#
# Drives CleanupClassifier.classify_binding through every per-shape arm
# by declaring a local binding of each cleanup-needing shape, using it,
# and letting it fall off the end of scope (forcing the classifier to
# stamp a cleanup entry + the checker to verify alloc<->cleanup pairing).
#
# Targets the uncovered classify_* branches in promotion_plan.rb:
#   classify_non_copy_union, classify_optional, classify_owned_string,
#   classify_struct_cleanup_fields, classify_rc_or_link,
#   classify_heap_provenance / classify_heap_composite.
#
# Each cell is a complete program. The shape is constructed, observed via
# an ASSERT (so dead-code elimination can't drop it), and cleaned up at
# function scope exit.

CLEANUP_CLASSIFIER_SHAPE_CELLS = %i[
  non_copy_union_string
  non_copy_union_inline_struct
  non_copy_union_list
  optional_owned_string
  optional_owned_struct
  owned_string_copy
  struct_string_field
  struct_list_field
  struct_map_field
  optional_nil_string
  multiowned_struct
  shared_struct
  locked_struct
  write_locked_struct
  versioned_struct
  always_mutable_struct
  atomic_indirect_struct
  indirect_struct
  split_stream_handle
  observable_sum_handle
].map { |shape| { shape: shape } }

FuzzGenerator.register(:cleanup_classifier_shapes,
                       cells: CLEANUP_CLASSIFIER_SHAPE_CELLS) do |p|
  case p[:shape]
  when :non_copy_union_string
    <<~CHT
      UNION Val { Nil, Str: String }

      FN main() RETURNS Void ->
          v = Val{ Str: "hello" };
          PARTIAL MATCH v START
              Val.Str AS s -> ASSERT s == "hello", "union string variant";,
              DEFAULT -> ASSERT FALSE, "should be Str";
          END
          RETURN;
      END
    CHT

  when :non_copy_union_inline_struct
    <<~CHT
      UNION Val { Nil, Pair { car: String, cdr: String } }

      FN main() RETURNS Void ->
          v = Val.Pair{ car: "a", cdr: "b" };
          PARTIAL MATCH v START
              Val.Pair AS pr -> ASSERT pr.car == "a", "union inline-struct variant";,
              DEFAULT -> ASSERT FALSE, "should be Pair";
          END
          RETURN;
      END
    CHT

  when :non_copy_union_list
    <<~CHT
      UNION Val { Nil, List: Int64[]@list }

      FN main() RETURNS Void ->
          MUTABLE xs: Int64[]@list = [];
          xs.append(1_i64);
          xs.append(2_i64);
          xs.append(3_i64);
          v = Val{ List: xs };
          PARTIAL MATCH v START
              Val.List AS lst -> ASSERT lst.length() == 3_i64, "union list variant";,
              DEFAULT -> ASSERT FALSE, "should be List";
          END
          RETURN;
      END
    CHT

  when :optional_owned_string
    <<~CHT
      FN main() RETURNS Void ->
          maybe: ?String = COPY "present";
          IF maybe AS s THEN
              ASSERT s == "present", "optional owned string";
          ELSE
              ASSERT FALSE, "expected Some";
          END
          RETURN;
      END
    CHT

  when :optional_owned_struct
    <<~CHT
      STRUCT Boxed { label: String }

      FN main() RETURNS Void ->
          inner = Boxed{ label: "tag" };
          maybe: ?Boxed = inner;
          IF maybe AS bx THEN
              ASSERT bx.label == "tag", "optional owned struct";
          ELSE
              ASSERT FALSE, "expected Some";
          END
          RETURN;
      END
    CHT

  when :owned_string_copy
    <<~CHT
      FN main() RETURNS Void ->
          src = "original";
          owned = COPY src;
          ASSERT owned == "original", "owned string via COPY";
          RETURN;
      END
    CHT

  when :struct_string_field
    <<~CHT
      STRUCT Person { name: String, age: Int64 }

      FN main() RETURNS Void ->
          p = Person{ name: "alice", age: 30_i64 };
          ASSERT p.name == "alice", "struct string field";
          ASSERT p.age == 30_i64, "struct numeric field";
          RETURN;
      END
    CHT

  when :struct_list_field
    <<~CHT
      STRUCT Bag { items: Int64[]@list }

      FN main() RETURNS Void ->
          MUTABLE b = Bag{ items: [] };
          b.items.append(1_i64);
          b.items.append(2_i64);
          ASSERT b.items.length() == 2_i64, "struct list field";
          RETURN;
      END
    CHT

  when :struct_map_field
    <<~CHT
      STRUCT Index { table: HashMap<Int64> }

      FN main() RETURNS Void ->
          MUTABLE ix = Index{ table: {} };
          ix.table["a"] = 1_i64;
          ix.table["b"] = 2_i64;
          ASSERT ix.table.count() == 2_i64, "struct map field";
          RETURN;
      END
    CHT

  when :optional_nil_string
    <<~CHT
      FN main() RETURNS Void ->
          maybe: ?String = NIL;
          IF maybe AS s THEN
              ASSERT s == "impossible", "optional nil should not bind";
          ELSE
              ASSERT TRUE, "optional nil fallback";
          END
          RETURN;
      END
    CHT

  when :multiowned_struct
    <<~CHT
      STRUCT Node { val: Int64 }

      FN main() RETURNS Void ->
          n = Node{ val: 42_i64 } @multiowned;
          ASSERT n.val == 42_i64, "multiowned struct binding";
          RETURN;
      END
    CHT

  when :shared_struct
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
          c = Counter{ value: 10_i64 } @shared;
          ASSERT c.value == 10_i64, "shared struct binding";
          RETURN;
      END
    CHT

  when :locked_struct
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 10_i64 } @locked;
          WITH EXCLUSIVE c AS r {
              ASSERT r.value == 10_i64, "locked struct cleanup";
          }
          RETURN;
      END
    CHT

  when :write_locked_struct
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 11_i64 } @writeLocked;
          WITH EXCLUSIVE c AS r {
              ASSERT r.value == 11_i64, "writeLocked struct cleanup";
          }
          RETURN;
      END
    CHT

  when :versioned_struct
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
          c = Counter{ value: 12_i64 } @versioned;
          WITH SNAPSHOT c AS r {
              ASSERT r.value == 12_i64, "versioned struct cleanup";
          }
          RETURN;
      END
    CHT

  when :always_mutable_struct
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
          c = Counter{ value: 13_i64 } @alwaysMutable;
          c.value = 14_i64;
          ASSERT c.value == 14_i64, "alwaysMutable struct cleanup";
          RETURN;
      END
    CHT

  when :atomic_indirect_struct
    <<~CHT
      STRUCT Counter { value: Int64 }

      FN main() RETURNS Void ->
          c = Counter{ value: 15_i64 } @indirect:atomic;
          WITH SNAPSHOT c AS r {
              ASSERT r.value == 15_i64, "atomic indirect struct cleanup";
          }
          RETURN;
      END
    CHT

  when :indirect_struct
    <<~CHT
      STRUCT Cfg { setting: Int64 }

      FN make() RETURNS !Cfg @indirect ->
          cfg = Cfg{ setting: 99_i64 };
          RETURN cfg;
      END

      FN main() RETURNS Void ->
          c = make();
          ASSERT c.setting == 99_i64, "indirect struct return";
          RETURN;
      END
    CHT

  when :split_stream_handle
    <<~CHT
      FN main() RETURNS Void ->
          s: ~?Int64[] @split = BG STREAM {
              YIELD 1_i64;
              YIELD 2_i64;
          };
          clone: ~?Int64[] @split = CLONE s;
          ASSERT (NEXT clone) == 1_i64, "split stream clone first";
          ASSERT (NEXT s) == 1_i64, "split stream source first";
          RETURN;
      END
    CHT

  when :observable_sum_handle
    <<~CHT
      FN main() RETURNS Void ->
          s: ~?Int64[] = BG STREAM {
              YIELD 1_i64;
              YIELD 2_i64;
              YIELD 3_i64;
          };
          running: ~Int64@observable = s |> SUM _;
          ASSERT (NEXT running) == 6_i64, "observable sum cleanup";
          RETURN;
      END
    CHT
  end
end
