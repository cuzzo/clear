# Template: return_value sink x EVERY value shape -- the BREADTH axis.
#
# heap_ownership_transfer covers list/string deeply (89 cells across ret_form
# x bind_form x decl). This template covers the orthogonal axis: every
# :cleanup_value_shapes member must successfully cross a `FN producer() ->
# RETURN value; END` boundary. Cells are enumerated from
# surface_registry.SINK_REQUIRES_SHAPES[:return_value] -- not hand-picked.
#
# One cell per shape. Failing cells :in_dev with a tracker bug ref. The
# expansion will surface every previously-hidden shape × return-value blind
# spot the same way takes_move_modality's expansion did (filed #51/#52/#53).

# Canonical per-shape spec for return. Each block ALWAYS ends with `xs` bound
# to the value to return. `ptype` is the function's return type.
#
# [prelude, return_type, build_block, assert_n]
RETURN_VALUE_SHAPE_SPECS = {
  string: [
    "",
    "String",
    "xs: String = COPY \"hi\";",
    2, # length of "hi"
  ],
  dynamic_array: [
    "",
    "Int64[]",
    "MUTABLE xs: Int64[] = [];\n    xs.append(4_i64);",
    1,
  ],
  heap_list: [
    "",
    "Int64[]@list",
    "MUTABLE xs: Int64[]@list = [];\n    xs.append(4_i64);",
    1,
  ],
  set: [
    "",
    "Int64[]@set",
    "MUTABLE xs: Int64[]@set = [];\n    xs.insert(4_i64);",
    1,
  ],
  pool: [
    "STRUCT It { v: Int64 }\n",
    "It[8]@pool",
    "MUTABLE xs: It[8]@pool = [];\n    _ = xs.insert(It{ v: 4_i64 });",
    1,
  ],
  hash_map: [
    "",
    "HashMap<Int64>",
    "MUTABLE xs: HashMap<Int64> = {};\n    xs[\"k\"] = 4_i64;",
    1,
  ],
  sharded_list: [
    "",
    "Int64[]@list:sharded(2)",
    "MUTABLE xs: Int64[]@list:sharded(2) = [];\n    xs.append(4_i64);",
    1,
  ],
  sharded_pool: [
    "STRUCT It { v: Int64 }\n",
    "It[8]@pool:sharded(2)",
    "MUTABLE xs: It[8]@pool:sharded(2) = [];\n    _ = xs.insert(It{ v: 4_i64 });",
    1,
  ],
  sharded_set: [
    "",
    "Int64[]@set:sharded(2)",
    "MUTABLE xs: Int64[]@set:sharded(2) = [];\n    xs.insert(4_i64);",
    1,
  ],
  sharded_hash_map: [
    "",
    "HashMap<Int64>@sharded(2)",
    "MUTABLE xs: HashMap<Int64>@sharded(2) = {};\n    xs[\"k\"] = 4_i64;",
    1,
  ],
  soa_list: [
    "STRUCT It { v: Float64 }\n",
    "It[]@list:soa",
    "MUTABLE xs: It[]@list:soa = [];\n    xs.append(It{ v: 1.0 });",
    1,
  ],
  soa_pool: [
    "STRUCT It { v: Float64 }\n",
    "It[8]@pool:soa",
    "MUTABLE xs: It[8]@pool:soa = [];\n    _ = xs.insert(It{ v: 1.0 });",
    1,
  ],
  struct_owned_fields: [
    "STRUCT Holder { name: String }\n",
    "Holder",
    "xs: Holder = Holder{ name: COPY \"hello\" };",
    1,
  ],
  union_owned_payload: [
    "UNION V { Nil, Heap: Int64[]@list }\n",
    "V",
    "MUTABLE inner: Int64[]@list = [];\n    inner.append(7_i64);\n    xs: V = V{ Heap: inner };",
    1,
  ],
  option_owned_payload: [
    "",
    "?String",
    "xs: ?String = COPY \"opt\";",
    1,
  ],
  nested_container: [
    "",
    "Int64[][]@list",
    "MUTABLE inner: Int64[]@list = [];\n    inner.append(5_i64);\n    MUTABLE xs: Int64[][]@list = [];\n    xs.append(inner);",
    1,
  ],
}.freeze

# Empirical overrides for cells that fail today. Default = :pass. Every
# :in_dev cell carries its bug task ID inline. Classified by
# `ruby tools/fuzz/run.rb --matrix --templates return_value_modality` +
# per-cell ./clear run.
RETURN_VALUE_EXPECTED_OVERRIDES = {
  # #43 -- union variant return: variant store emits `.items` slice + rt
  union_owned_payload: [:pass, "#43"],
  # #52 -- cleanup shim reads .len on ShardedList/SoaList (no such field)
  sharded_list: [:pass, "#52"],
  soa_list: [:pass, "#52"],
  # #54 -- returning owning @set/@pool/sharded/soa loses contents at runtime
  # (ASSERT length() == 1 fails -- contents silently lost on return)
  set: [:pass, "#54"],
  sharded_set: [:pass, "#54"],
  pool: [:pass, "#54"],
  sharded_pool: [:pass, "#54"],
  soa_pool: [:pass, "#54"],
}.freeze

RETURN_VALUE_CELLS = RETURN_VALUE_SHAPE_SPECS.keys.map do |shape|
  override = RETURN_VALUE_EXPECTED_OVERRIDES[shape]
  { shape: shape, expected: override ? override[0] : :pass }
end

FuzzGenerator.register(:return_value_modality, cells: RETURN_VALUE_CELLS) do |p|
  prelude, rtype, build, expected_n = RETURN_VALUE_SHAPE_SPECS.fetch(p[:shape])

  # The caller asserts on a per-shape size method so the cell exercises the
  # returned value's storage (not just construction).
  size_call =
    case p[:shape]
    when :hash_map, :sharded_hash_map then "x.count()"
    when :struct_owned_fields then "x.name.length()"
    when :union_owned_payload then "1_i64" # union has no size; smoke-only
    when :option_owned_payload then "1_i64" # smoke-only
    when :string then "x.length()"
    else "x.length()"
    end

  expected_n_for_shape =
    case p[:shape]
    when :string then 2  # "hi".length() == 2
    when :struct_owned_fields then 5  # "hello".length()
    else expected_n
    end

  <<~CHT
    #{prelude}FN producer() RETURNS #{rtype} ->
        #{build}
        RETURN xs;
    END

    FN main() RETURNS Void ->
        x: #{rtype} = producer();
        n: Int64 = #{size_call};
        ASSERT n == #{expected_n_for_shape}_i64, "return #{p[:shape]}";
        RETURN;
    END
  CHT
end
