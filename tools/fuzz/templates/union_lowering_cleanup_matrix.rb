# Template: union lowering cleanup matrix.
#
# Exercises union helper struct generation and recursive payload cleanup for
# owned payload shapes. This is source-level coverage for lower_union_def and
# cleanup emission, not malformed-MIR negative testing.

UNION_LOWERING_CLEANUP_CELLS = []

%i[string list map inline_struct nested_inline slice_like].each do |payload|
  %i[construct match_borrow match_takes return_value field_store list_append].each do |mode|
    UNION_LOWERING_CLEANUP_CELLS << { payload: payload, mode: mode }
  end
end

def ulc_union_def(payload)
  case payload
  when :string
    "UNION U { Empty, Text: String }"
  when :list
    "UNION U { Empty, Items: Int64[]@list }"
  when :map
    "UNION U { Empty, Table: HashMap<Int64> }"
  when :inline_struct
    "UNION U { Empty, Item { label: String, count: Int64 } }"
  when :nested_inline
    "UNION U { Empty, Item { label: String, items: Int64[]@list } }"
  when :slice_like
    "UNION U { Empty, Items: Int64[] }"
  end
end

def ulc_build_setup(payload)
  case payload
  when :string
    ["", 'U{ Text: COPY "abc" }', "U.Text", "x.length()"]
  when :list
    ["MUTABLE xs: Int64[]@list = [];\n    &xs.append(1_i64);\n    &xs.append(2_i64);", "U{ Items: xs }", "U.Items", "x.length()"]
  when :map
    ['MUTABLE xs: HashMap<Int64> = {};' + "\n    xs[\"a\"] = 1_i64;\n    xs[\"b\"] = 2_i64;", "U{ Table: xs }", "U.Table", "x.count()"]
  when :inline_struct
    ["", 'U.Item{ label: COPY "abc", count: 2_i64 }', "U.Item", "x.label.length()"]
  when :nested_inline
    ["MUTABLE xs: Int64[]@list = [];\n    &xs.append(1_i64);\n    &xs.append(2_i64);", 'U.Item{ label: COPY "abc", items: xs }', "U.Item", "x.items.length()"]
  when :slice_like
    ["MUTABLE xs: Int64[] = [];\n    &xs.append(1_i64);\n    &xs.append(2_i64);", "U{ Items: xs }", "U.Items", "x.length()"]
  end
end

FuzzGenerator.register(:union_lowering_cleanup_matrix, cells: UNION_LOWERING_CLEANUP_CELLS) do |p|
  union_def = ulc_union_def(p[:payload])
  setup, expr, variant, observe = ulc_build_setup(p[:payload])
  setup_line = setup.empty? ? "" : "#{setup}\n    "

  case p[:mode]
  when :construct
    <<~CHT
      #{union_def}
      FN main() RETURNS Void ->
          #{setup_line}u: U = #{expr};
          _ = u;
          RETURN;
      END
    CHT
  when :match_borrow
    <<~CHT
      #{union_def}
      FN main() RETURNS Void ->
          #{setup_line}u: U = #{expr};
          PARTIAL MATCH u START
              #{variant} AS x -> ASSERT #{observe} >= 2_i64, "union borrow payload";,
              DEFAULT -> ASSERT FALSE, "expected payload";
          END
          RETURN;
      END
    CHT
  when :match_takes
    <<~CHT
      #{union_def}
      FN consume(TAKES u: U) RETURNS Void ->
          PARTIAL MATCH TAKES u START
              #{variant} AS x -> ASSERT #{observe} >= 2_i64, "union takes payload";,
              DEFAULT -> ASSERT FALSE, "expected payload";
          END
          RETURN;
      END
      FN main() RETURNS Void ->
          #{setup_line}u: U = #{expr};
          consume(GIVE u);
          RETURN;
      END
    CHT
  when :return_value
    <<~CHT
      #{union_def}
      FN build() RETURNS U ->
          #{setup_line}RETURN #{expr};
      END
      FN main() RETURNS Void ->
          _ = build();
          RETURN;
      END
    CHT
  when :field_store
    <<~CHT
      #{union_def}
      STRUCT Holder { value: U }
      FN main() RETURNS Void ->
          #{setup_line}h: Holder = Holder{ value: #{expr} };
          _ = h;
          RETURN;
      END
    CHT
  when :list_append
    <<~CHT
      #{union_def}
      FN main() RETURNS Void ->
          #{setup_line}MUTABLE out: U[]@list = [];
          &out.append(#{expr});
          ASSERT out.length() == 1_i64, "union list append";
          RETURN;
      END
    CHT
  end
end
