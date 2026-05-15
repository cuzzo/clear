# Template: indexed-assignment lowering matrix.
#
# Targets src/mir/mir_lowering.rb#lower_indexed_assignment (the largest
# fuzz_axis dark cluster: `kind = ti.dispatch_key` ->
# INDEX_OPS.dig(kind,:set) crossed with value_transforms
# {:dupe_string_literal, :dupe_borrowed_union, :container_promote} and
# shard_direct). The corpus only ever wrote `lst[i] = int` into a plain
# list; this enumerates container_shape x key_kind x value_ownership x
# map_wrap so every dispatch/transform arm lowers.
#
# Value type DERIVES from the container (int containers take an Int64
# value; String-valued maps take string / COPY-string values -- the
# :dupe_string_literal transform arm). Mixing them would be an invalid
# program, not a surfaced bug.
#
# expected :pass with a self-checking ASSERT. A :pass cell that fails,
# leaks, or mir-errors is a SURFACED lowering bug (do not fix here).

IAM_CELLS = []

# container => :seq (int-indexed) | :map_int | :map_str
IAM_CONTAINERS = {
  array:           :seq,
  list:            :seq,
  map_int:         :map_int,
  map_int_sharded: :map_int,
  map_str:         :map_str,
  map_str_sharded: :map_str
}

IAM_CONTAINERS.each do |container, family|
  if family == :seq
    IAM_CELLS << { container: container, key: :index, value: :primitive }
  else
    keys   = %i[literal variable concat]
    values = family == :map_int ? %i[primitive] : %i[str_literal copy_str]
    keys.each do |k|
      values.each { |v| IAM_CELLS << { container: container, key: k, value: v } }
    end
  end
end

def iam_decl(c)
  {
    array:           "MUTABLE box: Int64[] = [0_i64, 0_i64, 0_i64];",
    list:            "MUTABLE box: Int64[]@list = [];",
    map_int:         "MUTABLE box: HashMap<Int64> = {};",
    map_int_sharded: "MUTABLE box: HashMap<Int64>@sharded(2) = {};",
    map_str:         "MUTABLE box: HashMap<String> = {};",
    map_str_sharded: "MUTABLE box: HashMap<String>@sharded(2) = {};"
  }[c]
end

def iam_prep(c)
  c == :list ? "    box.append(0_i64);" : ""
end

def iam_key_expr(c, k)
  return "0_i64" if %i[array list].include?(c)

  case k
  when :literal  then "\"kk\""
  when :variable then "kvar"
  when :concat   then "(\"k\" + \"k\")"
  end
end

def iam_key_setup(c, k)
  (k == :variable && !%i[array list].include?(c)) ? "    kvar: String = \"kk\";" : ""
end

def iam_value_expr(v)
  case v
  when :primitive   then "9_i64"
  when :str_literal then "\"vv\""
  when :copy_str    then "COPY sval"
  end
end

def iam_value_setup(v)
  v == :copy_str ? "    sval: String = \"vv\";" : ""
end

def iam_expected_read(c, key_e, v)
  if %i[array list].include?(c)
    "ASSERT box[#{key_e}] == 9_i64, \"seq indexed set\";"
  elsif v == :primitive
    "ASSERT (box[#{key_e}] OR 0_i64) == 9_i64, \"map int set\";"
  else
    "ASSERT (box[#{key_e}] OR \"\") == \"vv\", \"map str set\";"
  end
end

FuzzGenerator.register(:indexed_assignment_matrix, cells: IAM_CELLS) do |p|
  key_e = iam_key_expr(p[:container], p[:key])
  val_e = iam_value_expr(p[:value])
  parts = ["FN main() RETURNS Void ->", "    #{iam_decl(p[:container])}"]
  prep = iam_prep(p[:container]); parts << prep unless prep.empty?
  ks = iam_key_setup(p[:container], p[:key]); parts << ks unless ks.empty?
  vs = iam_value_setup(p[:value]);            parts << vs unless vs.empty?
  parts << "    box[#{key_e}] = #{val_e};"
  parts << "    #{iam_expected_read(p[:container], key_e, p[:value])}"
  parts << "    RETURN;"
  parts << "END"
  parts.join("\n") + "\n"
end
