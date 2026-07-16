# Template: MATCH lowering matrix.
#
# Targets src/mir/mir_lowering.rb#lower_match. Dark arms = the subject
# shape x arm kind x default-presence cross-product: union payload
# variant, union unit variant, enum, with and without DEFAULT. The
# corpus exercised only a couple of these shapes.
#
# Confirmed syntax (transpile-tests/52_union.clear): UNION with payload
# and unit variants, `Type{ Variant: v }` construction, `PARTIAL MATCH
# subj START Type.Variant -> ...; DEFAULT -> ...; END`.
#
# expected :pass; a failing/leaking :pass cell is a SURFACED bug.

MM_CELLS = []
MM_SUBJECT = %i[
  union_payload
  union_unit
  enum
  union_string_as
  union_list_as
  union_inline_struct_as
  union_is_a_variant
  union_is_a_payload_type
]
MM_DEFAULT = %i[with_default no_default]
MM_OUTCOME = %i[matched default_taken]

MM_SUBJECT.each do |s|
  MM_DEFAULT.each do |d|
    MM_OUTCOME.each do |o|
      next if o == :default_taken && d == :no_default

      MM_CELLS << { subject: s, default: d, outcome: o }
    end
  end
end

def mm_default_arm(d)
  d == :with_default ? "        DEFAULT -> got = 9.0;\n" : ""
end

FuzzGenerator.register(:match_matrix, cells: MM_CELLS) do |p|
  case p[:subject]
  when :union_payload
    subject_expr = p[:outcome] == :default_taken ? "Shape.Empty" : "Shape{ Circle: 2.0 }"
    expected = p[:outcome] == :default_taken ? "9.0" : "1.0"
    <<~CHT
      UNION Shape { Circle: Float64, Rect: Float64, Empty }

      FN main() RETURNS Void ->
          s = #{subject_expr};
          MUTABLE got: Float64 = 0.0;
          PARTIAL MATCH s START
              Shape.Circle -> got = 1.0;,
              Shape.Rect   -> got = 2.0;,
      #{mm_default_arm(p[:default])}    END
          ASSERT got == #{expected}, "union payload match";
          RETURN;
      END
    CHT
  when :union_unit
    subject_expr = p[:outcome] == :default_taken ? "Shape{ Rect: 3.0 }" : "Shape.Empty"
    expected = p[:outcome] == :default_taken ? "9.0" : "5.0"
    <<~CHT
      UNION Shape { Circle: Float64, Rect: Float64, Empty }

      FN main() RETURNS Void ->
          s = #{subject_expr};
          MUTABLE got: Float64 = 0.0;
          PARTIAL MATCH s START
              Shape.Empty  -> got = 5.0;,
              Shape.Circle -> got = 1.0;,
      #{mm_default_arm(p[:default])}    END
          ASSERT got == #{expected}, "union unit match";
          RETURN;
      END
    CHT
  when :enum
    subject_expr = p[:outcome] == :default_taken ? "Dir.East" : "Dir.South"
    expected = p[:outcome] == :default_taken ? "9.0" : "2.0"
    <<~CHT
      ENUM Dir { North, South, East }

      FN main() RETURNS Void ->
          d: Dir = #{subject_expr};
          MUTABLE got: Float64 = 0.0;
          PARTIAL MATCH d START
              Dir.North -> got = 1.0;,
              Dir.South -> got = 2.0;,
      #{mm_default_arm(p[:default])}    END
          ASSERT got == #{expected}, "enum match";
          RETURN;
      END
    CHT
  when :union_string_as
    subject_expr = p[:outcome] == :default_taken ? "Box.Empty" : 'Box{ Text: COPY "abc" }'
    expected = p[:outcome] == :default_taken ? "9_i64" : "3_i64"
    <<~CHT
      UNION Box { Empty, Text: String }

      FN main() RETURNS Void ->
          b = #{subject_expr};
          MUTABLE got: Int64 = 0_i64;
          PARTIAL MATCH b START
              Box.Text AS x -> got = x.length();,
      #{mm_default_arm(p[:default]).gsub("9.0", "9_i64")}    END
          ASSERT got == #{expected}, "union string AS match";
          RETURN;
      END
    CHT
  when :union_list_as
    subject_expr = p[:outcome] == :default_taken ? "Box.Empty" : "Box{ Items: xs }"
    pre_subject =
      if p[:outcome] == :default_taken
        ""
      else
        "MUTABLE xs: Int64[]@list = [];\n    xs.append(1_i64);\n    xs.append(2_i64);\n    "
      end
    expected = p[:outcome] == :default_taken ? "9_i64" : "2_i64"
    <<~CHT
      UNION Box { Empty, Items: Int64[]@list }

      FN main() RETURNS Void ->
          #{pre_subject}b = #{subject_expr};
          MUTABLE got: Int64 = 0_i64;
          PARTIAL MATCH b START
              Box.Items AS x -> got = x.length();,
      #{mm_default_arm(p[:default]).gsub("9.0", "9_i64")}    END
          ASSERT got == #{expected}, "union list AS match";
          RETURN;
      END
    CHT
  when :union_inline_struct_as
    subject_expr = p[:outcome] == :default_taken ? "Box.Empty" : 'Box.Item{ label: COPY "xyz", count: 4_i64 }'
    expected = p[:outcome] == :default_taken ? "9_i64" : "7_i64"
    <<~CHT
      UNION Box { Empty, Item { label: String, count: Int64 } }

      FN main() RETURNS Void ->
          b = #{subject_expr};
          MUTABLE got: Int64 = 0_i64;
          PARTIAL MATCH b START
              Box.Item AS x -> got = x.label.length() + x.count;,
      #{mm_default_arm(p[:default]).gsub("9.0", "9_i64")}    END
          ASSERT got == #{expected}, "union inline struct AS match";
          RETURN;
      END
    CHT
  when :union_is_a_variant, :union_is_a_payload_type
    subject_expr = p[:outcome] == :default_taken ? 'Value{ Text: "no" }' : "Value{ Number: 4.5 }"
    expected = p[:outcome] == :default_taken ? "9.0" : "4.5"
    target = p[:subject] == :union_is_a_variant ? "Value.Number" : "Number"
    else_branch = p[:default] == :with_default ? " ELSE got = 9.0;" : ""
    <<~CHT
      UNION Value { Empty, Number: Float64, Text: String }

      FN main() RETURNS Void ->
          value: Value = #{subject_expr};
          MUTABLE got: Float64 = 0.0;
          IF value IS_A #{target} AS number THEN got = number;#{else_branch} END
          ASSERT got == #{expected}, "runtime IS_A partial union match";
          RETURN;
      END
    CHT
  end
end
