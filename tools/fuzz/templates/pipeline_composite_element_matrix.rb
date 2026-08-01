# Template: pipeline terminals whose per-element expression CONSTRUCTS a
# composite value (struct / list literal) holding an OWNED field -- a
# heap-owning call result, a string interpolation, or a recursive transform.
#
# Such an element field-store-hoists an owned temp during lowering. The temp
# must stay scoped to the per-element loop body; if it escapes to the enclosing
# statement (outside the loop) the value is allocated once but moved into the
# result on every iteration, and the MIR ownership checker rejects the
# (memory-safe) program with an unprovable loop-invariant state. This matrix is
# the regression guard for the pipeline element-hoist-scoping fix and exercises
# the same shape across SELECT, UNNEST, and REDUCE.

PIPELINE_COMPOSITE_ELEMENT_CELLS = [
  { op: :select, elem: :struct_owned_call },
  { op: :select, elem: :nested_struct_owned_call },
  { op: :select, elem: :recursive_transform },
  { op: :select, elem: :struct_string_field },
  { op: :unnest, elem: :struct_owned_call },
  { op: :reduce, elem: :struct_owned_call },
  { op: :reduce, elem: :owned_string_acc },
  { op: :reduce, elem: :owned_string_acc_returned },
].freeze

FuzzGenerator.register(:pipeline_composite_element_matrix, cells: PIPELINE_COMPOSITE_ELEMENT_CELLS) do |p|
  case [p[:op], p[:elem]]
  when [:select, :struct_owned_call]
    # SELECT element is a struct literal wrapping a fresh owned (heap String)
    # call result. The field store hoists the String; it must free per element.
    <<~CHT
      STRUCT Row { label: String }

      FN describe(n: Int64) RETURNS String ->
        RETURN "row-${toString(n)}";
      END

      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64, 3_i64];
        rows = nums |> SELECT Row{ label: COPY describe(_) };
        ASSERT rows.length() == 3_i64, "select struct owned call";
        RETURN;
      END
    CHT

  when [:select, :nested_struct_owned_call]
    # The SELECT result feeds a second struct field, so the element is
    # field-store-hoisted twice over -- the shape that first exposed the bug.
    <<~CHT
      STRUCT Param { expr: Leaf }
      STRUCT Sig { params: Param[] }
      STRUCT Leaf { v: Int64 }

      FN twice(l: Leaf) RETURNS Leaf ->
        RETURN Leaf{ v: l.v * 2_i64 };
      END

      FN build(items: Leaf[]) RETURNS Sig ->
        RETURN Sig{ params: COPY items |> SELECT Param{ expr: COPY twice(_) } };
      END

      FN main() RETURNS Void ->
        leaves = [Leaf{ v: 1_i64 }, Leaf{ v: 2_i64 }];
        sig = build(leaves);
        ASSERT sig.params.length() == 2_i64, "select nested struct owned call";
        RETURN;
      END
    CHT

  when [:select, :recursive_transform]
    # Recursive REENTRANT tree transform: each SELECT element rebuilds a child
    # via a recursive call inside a composite literal. This is the exact shape
    # of TypeExpression::transform that the fix targets.
    <<~CHT
      UNION TKind { Named: Named, Leaf: Leaf }
      STRUCT Param { expr: Tree }
      STRUCT Sig { params: Param[] }
      STRUCT Named { sig: Sig }
      STRUCT Leaf { v: Int64 }
      STRUCT Tree { kind: TKind }

      FN bump(t: Tree) RETURNS Tree EFFECTS REENTRANT ->
        MUTABLE kind = COPY t.kind;
        IF kind IS_A Named AS n THEN
          RETURN Tree{ kind: TKind{ Named: COPY Named{ sig: COPY Sig{ params: COPY n.sig.params |> SELECT Param{ expr: COPY bump(_.expr) } } } } };
        ELSE_IF kind IS_A Leaf AS l THEN
          RETURN Tree{ kind: TKind{ Leaf: COPY Leaf{ v: l.v + 1_i64 } } };
        ELSE
          RETURN COPY t;
        END
      END

      FN main() RETURNS Void ->
        MUTABLE leaf = Tree{ kind: TKind{ Leaf: Leaf{ v: 1_i64 } } };
        MUTABLE ps: Param[] = List[];
        &ps.push(Param{ expr: COPY leaf });
        MUTABLE named = Tree{ kind: TKind{ Named: Named{ sig: Sig{ params: COPY ps } } } };
        MUTABLE out = bump(named);
        ASSERT out.kind IS_A Named, "select recursive transform";
        RETURN;
      END
    CHT

  when [:select, :struct_string_field]
    # A string-interpolation field owns a fresh heap String per element.
    <<~CHT
      STRUCT Tag { text: String }

      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64];
        tags = nums |> SELECT Tag{ text: "n=${toString(_)}" };
        ASSERT tags.length() == 2_i64, "select struct string field";
        RETURN;
      END
    CHT

  when [:unnest, :struct_owned_call]
    # UNNEST flattens a per-element owned collection of heap Strings, exercising
    # per-element owned-value flow through the inner append loop.
    <<~CHT
      STRUCT Box { labels: String[] }

      FN main() RETURNS Void ->
        boxes = [
          Box{ labels: ["a", "b"] },
          Box{ labels: ["c"] },
        ];
        flat = boxes |> UNNEST _.labels;
        ASSERT flat.length() == 3_i64, "unnest owned strings";
        RETURN;
      END
    CHT

  when [:reduce, :struct_owned_call]
    # REDUCE step creates a fresh owned heap String per element (a hoisted
    # cleanup-bearing temp) and folds a scalar derived from it; the String must
    # free each iteration.
    <<~CHT
      FN describe(n: Int64) RETURNS String ->
        RETURN "row-${toString(n)}";
      END

      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64, 3_i64];
        total = nums |> REDUCE(0_i64) acc + describe(_).length();
        ASSERT total == 15_i64, "reduce owned string temp";
        RETURN;
      END
    CHT

  when [:reduce, :owned_string_acc]
    # REDUCE whose accumulator is an owned heap String, folded in place: each
    # step's ConcatStr result must be heap-placed and the prior value freed.
    <<~CHT
      FN suffix(n: Int64) RETURNS String ->
        RETURN "-${toString(n)}";
      END

      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64, 3_i64];
        joined = nums |> REDUCE("x") "${acc}${suffix(_)}";
        ASSERT joined.length() == 7_i64, "reduce owned string acc";
        RETURN;
      END
    CHT

  when [:reduce, :owned_string_acc_returned]
    # The heap-carry-return path: the owned-String accumulator IS the returned
    # value, so its reassignment must free intermediates without a UAF.
    <<~CHT
      FN suffix(n: Int64) RETURNS String ->
        RETURN "-${toString(n)}";
      END

      FN fold(dims: Int64[]) RETURNS String ->
        RETURN dims |> REDUCE("x") "${acc}${suffix(_)}";
      END

      FN main() RETURNS Void ->
        nums = [1_i64, 2_i64];
        s = fold(nums);
        ASSERT s.length() == 5_i64, "reduce owned string acc returned";
        RETURN;
      END
    CHT
  end
end
