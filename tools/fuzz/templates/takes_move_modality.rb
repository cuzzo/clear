# Template: ownership-transfer move modality x EVERY callee-param value shape.
#
# Cells are ENUMERATED from the registry's :cleanup_value_shapes, not picked
# from imagination. Every shape in CALLEE_PARAM_VALUE_SHAPES from
# surface_registry.rb gets a cell per modality. Cells currently failing are
# :in_dev with a tracker bug ref; cells passing are :pass. No silent omissions.
#
# Bug history (the kind of blind spot this template now blocks):
#   #37  @list/@set/@pool/@map via bare/COPY -- mis-lowered as slice
#   #39  dynamic Int64[] -> TAKES -- allocator/.items mismatch
#   #40  nested @list[][] -- mutable .deinit on const-anytype
#   #42  COPY of @set/@pool/@map -- dupeValue missing arms
#   #43  union_owned_payload -- variant store + missing rt (under investigation)
#
# CLONE is out of scope (CLONE of a non-RC value is a distinct front-end
# concern, not the implicit-move-into-TAKES class).

# Canonical per-shape construction. Keys match :cleanup_value_shapes naming
# in the registry. The block ALWAYS ends with `xs` bound to the value to
# consume so the consume(<mod> xs) call is uniform across shapes.
#
# [prelude, param_type, decl_block, body_returns_1?]
TAKES_MOVE_SHAPE_SPECS = {
  string: [
    "",
    "String",
    "xs: String = COPY \"hi\";",
    true,
  ],
  dynamic_array: [
    "",
    "Int64[]",
    "MUTABLE xs: Int64[] = [];\n    xs.append(4_i64);",
    false,
  ],
  heap_list: [
    "",
    "Int64[]@list",
    "MUTABLE xs: Int64[]@list = [];\n    xs.append(4_i64);",
    false,
  ],
  set: [
    "",
    "Int64[]@set",
    "MUTABLE xs: Int64[]@set = [];\n    xs.insert(4_i64);",
    false,
  ],
  pool: [
    "STRUCT It { v: Int64 }\n",
    "It[8]@pool",
    "MUTABLE xs: It[8]@pool = [];\n    _ = xs.insert(It{ v: 4_i64 });",
    false,
  ],
  hash_map: [
    "",
    "HashMap<Int64>",
    "MUTABLE xs: HashMap<Int64> = {};\n    xs[\"k\"] = 4_i64;",
    :map,
  ],
  sharded_list: [
    "",
    "Int64[]@list:sharded(2)",
    "MUTABLE xs: Int64[]@list:sharded(2) = [];\n    xs.append(4_i64);",
    false,
  ],
  sharded_pool: [
    "STRUCT It { v: Int64 }\n",
    "It[8]@pool:sharded(2)",
    "MUTABLE xs: It[8]@pool:sharded(2) = [];\n    _ = xs.insert(It{ v: 4_i64 });",
    false,
  ],
  sharded_set: [
    "",
    "Int64[]@set:sharded(2)",
    "MUTABLE xs: Int64[]@set:sharded(2) = [];\n    xs.insert(4_i64);",
    false,
  ],
  sharded_hash_map: [
    "",
    "HashMap<Int64>@sharded(2)",
    "MUTABLE xs: HashMap<Int64>@sharded(2) = {};\n    xs[\"k\"] = 4_i64;",
    :map,
  ],
  soa_list: [
    "STRUCT It { v: Float64 }\n",
    "It[]@list:soa",
    "MUTABLE xs: It[]@list:soa = [];\n    xs.append(It{ v: 1.0 });",
    false,
  ],
  soa_pool: [
    "STRUCT It { v: Float64 }\n",
    "It[8]@pool:soa",
    "MUTABLE xs: It[8]@pool:soa = [];\n    _ = xs.insert(It{ v: 1.0 });",
    false,
  ],
  struct_owned_fields: [
    "STRUCT Holder { name: String }\n",
    "Holder",
    "xs: Holder = Holder{ name: COPY \"hello\" };",
    true,
  ],
  union_owned_payload: [
    "UNION V { Nil, Heap: Int64[]@list }\n",
    "V",
    "MUTABLE inner: Int64[]@list = [];\n    inner.append(7_i64);\n    xs: V = V{ Heap: inner };",
    true,
  ],
  option_owned_payload: [
    "",
    "?String",
    "xs: ?String = COPY \"opt\";",
    true,
  ],
  nested_container: [
    "",
    "Int64[][]@list",
    "MUTABLE inner: Int64[]@list = [];\n    inner.append(5_i64);\n    MUTABLE xs: Int64[][]@list = [];\n    xs.append(inner);",
    false,
  ],
}.freeze

# Empirically-classified expected outcomes per (shape, modality). Cells found
# failing on this branch are :in_dev with the bug task ID. Default = :pass.
# Every failure flipped via `ruby tools/fuzz/run.rb --matrix --templates
# takes_move_modality` + standalone classification. NO speculation; NO silent
# omissions.
TAKES_MOVE_EXPECTED_OVERRIDES = {
  # #43 -- union_owned_payload variant store emits `.items` slice; rt missing
  [:union_owned_payload, :give] => [:pass, "#43"],
  [:union_owned_payload, :bare] => [:pass, "#43"],
  [:union_owned_payload, :copy] => [:pass, "#43"],
  # #51 -- struct-with-owned-fields TAKES: callee body needs rt but signature
  # lacks `rt: *Runtime` (same class as #43's part B)
  [:struct_owned_fields, :give] => [:pass, "#51"],
  [:struct_owned_fields, :bare] => [:pass, "#51"],
  [:struct_owned_fields, :copy] => [:pass, "#51"],
  # #52 -- ShardedList / SoaList: cleanup shim reads .len (no such field)
  [:sharded_list, :give]        => [:pass, "#52"],
  [:sharded_list, :bare]        => [:pass, "#52"],
  [:sharded_list, :copy]        => [:pass, "#52"],
  [:soa_list, :give]            => [:pass, "#52"],
  [:soa_list, :bare]            => [:pass, "#52"],
  [:soa_list, :copy]            => [:pass, "#52"],
  # #53 -- sharded_hash_map COPY: dupeValue lacks ShardedStringMap arm; segfault
  [:sharded_hash_map, :copy]    => [:pass, "#53"],
}.freeze

TAKES_MOVE_CELLS = TAKES_MOVE_SHAPE_SPECS.keys.flat_map do |shape|
  %i[give bare copy].map do |modality|
    override = TAKES_MOVE_EXPECTED_OVERRIDES[[shape, modality]]
    { shape: shape, modality: modality,
      expected: override ? override[0] : :pass }
  end
end

FuzzGenerator.register(:takes_move_modality, cells: TAKES_MOVE_CELLS) do |p|
  prelude, ptype, decl, body_kind = TAKES_MOVE_SHAPE_SPECS.fetch(p[:shape])

  body = case body_kind
         when true then "RETURN 1_i64;"
         when :map then "RETURN xs.count();"
         else           "RETURN xs.length();"
         end

  arg = case p[:modality]
        when :give then "GIVE xs"
        when :copy then "COPY xs"
        when :bare then "xs"
        end

  <<~CHT
    #{prelude}FN consume(TAKES xs: #{ptype}) RETURNS Int64 -> #{body} END

    FN main() RETURNS Void ->
        #{decl}
        n: Int64 = consume(#{arg});
        ASSERT n == 1_i64, "takes #{p[:shape]} via #{p[:modality]}";
        RETURN;
    END
  CHT
end
