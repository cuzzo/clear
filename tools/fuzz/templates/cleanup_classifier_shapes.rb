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
  multiowned_struct
  shared_struct
  indirect_struct
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
  end
end
