# Template: builtin emission matrix.
#
# Valid source programs that force common MIR builtin emission paths through
# string/list/map operations, pipeline terminals, active union tags, and
# cleanup-sensitive helper calls.

BUILTIN_EMIT_CELLS = %i[
  string_length
  string_contains
  string_char_at
  string_split
  int_to_string
  list_length_method
  list_length_global
  map_count
  set_length
  active_union_match
  pipeline_count
  pipeline_sum
  pipeline_average
  pipeline_any
  pipeline_all
  pipeline_distinct
].map { |shape| { shape: shape } }

FuzzGenerator.register(:builtin_emit_matrix, cells: BUILTIN_EMIT_CELLS) do |p|
  case p[:shape]
  when :string_length
    %(FN main() RETURNS Void ->\n    s: String = COPY "abcd";\n    ASSERT s.length() == 4_i64, "string length";\n    RETURN;\nEND\n)
  when :string_contains
    %(FN main() RETURNS Void ->\n    s: String = COPY "abcd";\n    ASSERT s.contains?("bc"), "string contains";\n    RETURN;\nEND\n)
  when :string_char_at
    %(FN main() RETURNS Void ->\n    s: String = COPY "abcd";\n    c = s.charAt(1_i64) OR_ELSE RAISE;\n    ASSERT c == "b", "string charAt";\n    RETURN;\nEND\n)
  when :string_split
    %(FN main() RETURNS Void ->\n    parts = (COPY "a bb ccc").split(" ");\n    ASSERT parts.length() == 3_i64, "string split";\n    RETURN;\nEND\n)
  when :int_to_string
    %(FN main() RETURNS Void ->\n    s = 42_i64.toString();\n    ASSERT s.length() == 2_i64, "int toString";\n    RETURN;\nEND\n)
  when :list_length_method
    %(FN main() RETURNS Void ->\n    MUTABLE xs: Int64[]@list = [];\n    &xs.append(1_i64);\n    ASSERT xs.length() == 1_i64, "list length method";\n    RETURN;\nEND\n)
  when :list_length_global
    %(FN main() RETURNS Void ->\n    MUTABLE xs: Int64[]@list = [];\n    &xs.append(1_i64);\n    ASSERT length(xs) == 1_i64, "list length global";\n    RETURN;\nEND\n)
  when :map_count
    %(FN main() RETURNS Void ->\n    MUTABLE m: HashMap<Int64> = {};\n    m["a"] = 1_i64;\n    ASSERT m.count() == 1_i64, "map count";\n    RETURN;\nEND\n)
  when :set_length
    %(FN main() RETURNS Void ->\n    MUTABLE s: Int64[]@set = [];\n    &s.insert(1_i64);\n    ASSERT s.length() == 1_i64, "set length";\n    RETURN;\nEND\n)
  when :active_union_match
    <<~CHT
      UNION V { Empty, Text: String }
      FN main() RETURNS Void ->
          v: V = V{ Text: COPY "abc" };
          MUTABLE got: Int64 = 0_i64;
          PARTIAL MATCH v START
              V.Text AS x -> got = x.length();,
              DEFAULT -> got = 99_i64;
          END
          ASSERT got == 3_i64, "active union match";
          RETURN;
      END
    CHT
  when :pipeline_count
    %(FN main() RETURNS Void ->\n    xs = [1_i64, 2_i64, 3_i64];\n    n = xs |> COUNT _ > 1_i64;\n    ASSERT n == 2_i64, "pipeline count";\n    RETURN;\nEND\n)
  when :pipeline_sum
    %(FN main() RETURNS Void ->\n    xs = [1_i64, 2_i64, 3_i64];\n    n = xs |> SUM _;\n    ASSERT n == 6_i64, "pipeline sum";\n    RETURN;\nEND\n)
  when :pipeline_average
    %(FN main() RETURNS Void ->\n    s: ~Int64[] = 1_i64 ..< 5_i64;\n    avg: ~Float64@observable = s |> AVERAGE _;\n    ASSERT (NEXT avg) == 2.5, "pipeline average";\n    RETURN;\nEND\n)
  when :pipeline_any
    %(FN main() RETURNS Void ->\n    xs = [1_i64, 2_i64, 3_i64];\n    ok = xs |> ANY _ == 2_i64;\n    ASSERT ok, "pipeline any";\n    RETURN;\nEND\n)
  when :pipeline_all
    %(FN main() RETURNS Void ->\n    xs = [1_i64, 2_i64, 3_i64];\n    ok = xs |> ALL _ > 0_i64;\n    ASSERT ok, "pipeline all";\n    RETURN;\nEND\n)
  when :pipeline_distinct
    %(FN main() RETURNS Void ->\n    s: ~Int64[] = 1_i64 ..< 4_i64;\n    vals: ~Int64[]@set:observable = s |> DISTINCT _;\n    got = NEXT vals;\n    ASSERT got.length() == 3_i64, "pipeline distinct";\n    RETURN;\nEND\n)
  end
end
