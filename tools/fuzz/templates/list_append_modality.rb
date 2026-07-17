# Template: list_append sink x EVERY value shape x modality.
#
# `MUTABLE container: T[]@list = []; container.append(<modality> xs);` over
# the FULL :cleanup_value_shapes registry. Many element-type x list-of
# combinations may be language-illegal (pool-of-pool, list-of-set, etc.);
# those remain active :compile_error cells rather than being silently omitted.

# Per-shape spec: [prelude, element_type, build_block_ending_in_xs].
LIST_APPEND_SHAPE_SPECS = {
  string:               ["", "String",
                         "xs: String = COPY \"hi\";"],
  dynamic_array:        ["", "Int64[]",
                         "MUTABLE xs: Int64[] = [];\n    &xs.append(4_i64);"],
  heap_list:            ["", "Int64[]@list",
                         "MUTABLE xs: Int64[]@list = [];\n    &xs.append(4_i64);"],
  set:                  ["", "Int64[]@set",
                         "MUTABLE xs: Int64[]@set = [];\n    &xs.insert(4_i64);"],
  pool:                 ["STRUCT It { v: Int64 }\n", "It[8]@pool",
                         "MUTABLE xs: It[8]@pool = [];\n    _ = &xs.insert(It{ v: 4_i64 });"],
  hash_map:             ["", "HashMap<Int64>",
                         "MUTABLE xs: HashMap<Int64> = {};\n    xs[\"k\"] = 4_i64;"],
  sharded_list:         ["", "Int64[]@list:sharded(2)",
                         "MUTABLE xs: Int64[]@list:sharded(2) = [];\n    &xs.append(4_i64);"],
  sharded_pool:         ["STRUCT It { v: Int64 }\n", "It[8]@pool:sharded(2)",
                         "MUTABLE xs: It[8]@pool:sharded(2) = [];\n    _ = &xs.insert(It{ v: 4_i64 });"],
  sharded_set:          ["", "Int64[]@set:sharded(2)",
                         "MUTABLE xs: Int64[]@set:sharded(2) = [];\n    &xs.insert(4_i64);"],
  sharded_hash_map:     ["", "HashMap<Int64>@sharded(2)",
                         "MUTABLE xs: HashMap<Int64>@sharded(2) = {};\n    xs[\"k\"] = 4_i64;"],
  soa_list:             ["STRUCT It { v: Float64 }\n", "It[]@list:soa",
                         "MUTABLE xs: It[]@list:soa = [];\n    &xs.append(It{ v: 1.0 });"],
  soa_pool:             ["STRUCT It { v: Float64 }\n", "It[8]@pool:soa",
                         "MUTABLE xs: It[8]@pool:soa = [];\n    _ = &xs.insert(It{ v: 1.0 });"],
  struct_owned_fields:  ["STRUCT Holder { name: String }\n", "Holder",
                         "xs: Holder = Holder{ name: COPY \"hello\" };"],
  union_owned_payload:  ["UNION V { Nil, Heap: Int64[]@list }\n", "V",
                         "MUTABLE inner: Int64[]@list = [];\n    &inner.append(7_i64);\n    xs: V = V{ Heap: inner };"],
  option_owned_payload: ["", "?String",
                         "xs: ?String = COPY \"opt\";"],
  nested_container:     ["", "Int64[]@list",
                         "MUTABLE xs: Int64[]@list = [];\n    &xs.append(5_i64);"],
  frame_string_concat:  ["", "String",
                         "i: Int64 = 1_i64;\n    xs: String = \"a\" $+ i.toString();"],
  frame_list:           ["", "Int64[]",
                         "i: Int64 = 1_i64;\n    xs: Int64[] = [i, i + 1_i64];"],
}.freeze

# Empirical overrides per (shape, modality). Default = :pass. Classified by
# `ruby tools/fuzz/run.rb --matrix --templates list_append_modality` +
# per-cell ./clear run.
#
# Two outcome classes:
#   :compile_error -- CLEAR does not currently support `T[]@list` where T
#                     is an owning collection (pool/set/sharded/soa/etc).
#                     The fuzz suite ASSERTS the rejection: if the language
#                     adds support later, the cell flips to unexpected_pass.
# A compiler/runtime defect is never an expected outcome; it leaves the
# required matrix red until fixed.
LIST_APPEND_EXPECTED_OVERRIDES = {
  # Language doesn't support `OwningT[]@list` for these element types
  # (transpiler rejects -- list-of-pool, list-of-set, etc. not modelled).
  [:heap_list, :bare]            => [:compile_error, "lang: no list-of-@list"],
  [:heap_list, :copy]            => [:compile_error, "lang: no list-of-@list"],
  [:heap_list, :give]            => [:compile_error, "lang: no list-of-@list"],
  [:nested_container, :bare]     => [:compile_error, "lang: no list-of-@list"],
  [:nested_container, :copy]     => [:compile_error, "lang: no list-of-@list"],
  [:nested_container, :give]     => [:compile_error, "lang: no list-of-@list"],
  [:pool, :bare]                 => [:compile_error, "lang: no list-of-@pool"],
  [:pool, :copy]                 => [:compile_error, "lang: no list-of-@pool"],
  [:pool, :give]                 => [:compile_error, "lang: no list-of-@pool"],
  [:sharded_pool, :bare]         => [:compile_error, "lang: no list-of-@pool"],
  [:sharded_pool, :copy]         => [:compile_error, "lang: no list-of-@pool"],
  [:sharded_pool, :give]         => [:compile_error, "lang: no list-of-@pool"],
  [:soa_pool, :bare]             => [:compile_error, "lang: no list-of-@pool"],
  [:soa_pool, :copy]             => [:compile_error, "lang: no list-of-@pool"],
  [:soa_pool, :give]             => [:compile_error, "lang: no list-of-@pool"],
  [:set, :bare]                  => [:compile_error, "lang: no list-of-@set"],
  [:set, :copy]                  => [:compile_error, "lang: no list-of-@set"],
  [:set, :give]                  => [:compile_error, "lang: no list-of-@set"],
  [:sharded_set, :bare]          => [:compile_error, "lang: no list-of-@set"],
  [:sharded_set, :copy]          => [:compile_error, "lang: no list-of-@set"],
  [:sharded_set, :give]          => [:compile_error, "lang: no list-of-@set"],
  [:sharded_list, :bare]         => [:compile_error, "lang: no list-of-sharded"],
  [:sharded_list, :copy]         => [:compile_error, "lang: no list-of-sharded"],
  [:sharded_list, :give]         => [:compile_error, "lang: no list-of-sharded"],
  [:soa_list, :bare]             => [:compile_error, "lang: no list-of-soa"],
  [:soa_list, :copy]             => [:compile_error, "lang: no list-of-soa"],
  [:soa_list, :give]             => [:compile_error, "lang: no list-of-soa"],
  [:sharded_hash_map, :bare]     => [:compile_error, "lang: no list-of-sharded-map"],
  [:sharded_hash_map, :copy]     => [:compile_error, "lang: no list-of-sharded-map"],
  [:sharded_hash_map, :give]     => [:compile_error, "lang: no list-of-sharded-map"],
  [:union_owned_payload, :bare]  => [:pass, "#43"],
  [:union_owned_payload, :copy]  => [:pass, "#43"],
  [:union_owned_payload, :give]  => [:pass, "#43"],
  [:hash_map, :copy]             => [:pass, "#58"],
}.freeze

LIST_APPEND_CELLS = LIST_APPEND_SHAPE_SPECS.keys.flat_map do |shape|
  %i[bare copy give].map do |modality|
    override = LIST_APPEND_EXPECTED_OVERRIDES[[shape, modality]]
    { shape: shape, modality: modality, expected: override ? override[0] : :pass }
  end
end

FuzzGenerator.register(:list_append_modality, cells: LIST_APPEND_CELLS) do |p|
  prelude, etype, build = LIST_APPEND_SHAPE_SPECS.fetch(p[:shape])

  arg = case p[:modality]
        when :give then "GIVE xs"
        when :copy then "COPY xs"
        when :bare then "xs"
        end

  <<~CHT
    #{prelude}FN main() RETURNS Void ->
        #{build}
        MUTABLE container: #{etype}[]@list = [];
        &container.append(#{arg});
        ASSERT container.length() == 1_i64, "list_append #{p[:shape]} via #{p[:modality]}";
        RETURN;
    END
  CHT
end
