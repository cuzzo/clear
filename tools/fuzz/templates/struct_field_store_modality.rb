# Template: struct_field_store sink x EVERY value shape x modality.
#
# `STRUCT Box { f: T }; b = Box{ f: <modality> xs };` exercised over the FULL
# :cleanup_value_shapes registry. Cells are enumerated from the registry,
# not hand-picked. Failing cells fail the required matrix.
#
# The cross-cut SINK_REQUIRES_SHAPES[:struct_field_store] expects the full
# ASSIGN_INTO_HEAP_VALUE_SHAPES set; ownership_surface_smoke declares them
# all but does NOT emit each shape x modality combination -- this template
# does.

# Per-shape spec: [prelude, field_type, build_block]. Block ends with `xs`
# bound to the value to store into the struct field.
STRUCT_FIELD_STORE_SHAPE_SPECS = {
  string: [
    "",
    "String",
    "xs: String = COPY \"hi\";",
  ],
  dynamic_array: [
    "",
    "Int64[]",
    "MUTABLE xs: Int64[] = [];\n    xs.append(4_i64);",
  ],
  heap_list: [
    "",
    "Int64[]@list",
    "MUTABLE xs: Int64[]@list = [];\n    xs.append(4_i64);",
  ],
  set: [
    "",
    "Int64[]@set",
    "MUTABLE xs: Int64[]@set = [];\n    xs.insert(4_i64);",
  ],
  pool: [
    "STRUCT It { v: Int64 }\n",
    "It[8]@pool",
    "MUTABLE xs: It[8]@pool = [];\n    _ = xs.insert(It{ v: 4_i64 });",
  ],
  hash_map: [
    "",
    "HashMap<Int64>",
    "MUTABLE xs: HashMap<Int64> = {};\n    xs[\"k\"] = 4_i64;",
  ],
  sharded_list: [
    "",
    "Int64[]@list:sharded(2)",
    "MUTABLE xs: Int64[]@list:sharded(2) = [];\n    xs.append(4_i64);",
  ],
  sharded_pool: [
    "STRUCT It { v: Int64 }\n",
    "It[8]@pool:sharded(2)",
    "MUTABLE xs: It[8]@pool:sharded(2) = [];\n    _ = xs.insert(It{ v: 4_i64 });",
  ],
  sharded_set: [
    "",
    "Int64[]@set:sharded(2)",
    "MUTABLE xs: Int64[]@set:sharded(2) = [];\n    xs.insert(4_i64);",
  ],
  sharded_hash_map: [
    "",
    "HashMap<Int64>@sharded(2)",
    "MUTABLE xs: HashMap<Int64>@sharded(2) = {};\n    xs[\"k\"] = 4_i64;",
  ],
  soa_list: [
    "STRUCT It { v: Float64 }\n",
    "It[]@list:soa",
    "MUTABLE xs: It[]@list:soa = [];\n    xs.append(It{ v: 1.0 });",
  ],
  soa_pool: [
    "STRUCT It { v: Float64 }\n",
    "It[8]@pool:soa",
    "MUTABLE xs: It[8]@pool:soa = [];\n    _ = xs.insert(It{ v: 1.0 });",
  ],
  struct_owned_fields: [
    "STRUCT Holder { name: String }\n",
    "Holder",
    "xs: Holder = Holder{ name: COPY \"hello\" };",
  ],
  union_owned_payload: [
    "UNION V { Nil, Heap: Int64[]@list }\n",
    "V",
    "MUTABLE inner: Int64[]@list = [];\n    inner.append(7_i64);\n    xs: V = V{ Heap: inner };",
  ],
  option_owned_payload: [
    "",
    "?String",
    "xs: ?String = COPY \"opt\";",
  ],
  nested_container: [
    "",
    "Int64[][]@list",
    "MUTABLE inner: Int64[]@list = [];\n    inner.append(5_i64);\n    MUTABLE xs: Int64[][]@list = [];\n    xs.append(inner);",
  ],
  frame_string_concat: [
    "",
    "String",
    "i: Int64 = 1_i64;\n    xs: String = \"a\" $+ i.toString();",
  ],
  frame_list: [
    "",
    "Int64[]",
    "i: Int64 = 1_i64;\n    xs: Int64[] = [i, i + 1_i64];",
  ],
}.freeze

# Empirical overrides per (shape, modality). Default = :pass. Every repaired
# cell carries its historical bug task ID inline. Classified by `ruby tools/fuzz/run.rb
# --matrix --templates struct_field_store_modality` + per-cell ./clear run.
STRUCT_FIELD_STORE_EXPECTED_OVERRIDES = {
  # #55 -- COPY into struct field broken for set/pool/sharded/soa/map/nested/union/list
  [:set, :copy]              => [:pass, "#55"],
  [:sharded_set, :copy]      => [:pass, "#55"],
  [:pool, :copy]             => [:pass, "#55"],
  [:sharded_pool, :copy]     => [:pass, "#55"],
  [:soa_pool, :copy]         => [:pass, "#55"],
  [:soa_list, :copy]         => [:pass, "#55"],
  [:sharded_list, :copy]     => [:pass, "#55"],
  [:hash_map, :copy]         => [:pass, "#55"],
  [:sharded_hash_map, :copy] => [:pass, "#55"],
  [:nested_container, :copy] => [:pass, "#55"],
  [:union_owned_payload, :copy] => [:pass, "#55"],
  [:heap_list, :copy]        => [:pass, "#55"],
  [:dynamic_array, :give]    => [:pass, "#56"],
  [:dynamic_array, :bare]    => [:pass, "#56"],
  [:frame_list, :give]       => [:pass, "#56"],
  [:frame_list, :bare]       => [:pass, "#56"],
  [:nested_container, :give] => [:compile_error, "lang: Int64[][]@list parses inconsistently between field-decl (slice element) and var-decl (ArrayList element)"],
  [:nested_container, :bare] => [:compile_error, "lang: Int64[][]@list parses inconsistently between field-decl (slice element) and var-decl (ArrayList element)"],
  [:nested_container, :copy] => [:compile_error, "lang: Int64[][]@list parses inconsistently between field-decl (slice element) and var-decl (ArrayList element)"],
  [:union_owned_payload, :give] => [:pass, "#56"],
  [:union_owned_payload, :bare] => [:pass, "#56"],
  [:frame_string_concat, :bare] => [:compile_error, "frame strings must be COPY'd into a container"],
}.freeze

STRUCT_FIELD_STORE_CELLS = STRUCT_FIELD_STORE_SHAPE_SPECS.keys.flat_map do |shape|
  %i[bare copy give].map do |modality|
    override = STRUCT_FIELD_STORE_EXPECTED_OVERRIDES[[shape, modality]]
    { shape: shape, modality: modality, expected: override ? override[0] : :pass }
  end
end

FuzzGenerator.register(:struct_field_store_modality, cells: STRUCT_FIELD_STORE_CELLS) do |p|
  prelude, ftype, build = STRUCT_FIELD_STORE_SHAPE_SPECS.fetch(p[:shape])

  arg = case p[:modality]
        when :give then "GIVE xs"
        when :copy then "COPY xs"
        when :bare then "xs"
        end

  <<~CHT
    STRUCT Box { f: #{ftype} }
    #{prelude}
    FN main() RETURNS Void ->
        #{build}
        b: Box = Box{ f: #{arg} };
        ASSERT 1_i64 == 1_i64, "struct_field_store #{p[:shape]} via #{p[:modality]}";
        RETURN;
    END
  CHT
end
