# Template: MATCH lowering matrix.
#
# Targets src/mir/mir_lowering.rb#lower_match. Dark arms = the subject
# shape x arm kind x default-presence cross-product: union payload
# variant, union unit variant, enum, with and without DEFAULT. The
# corpus exercised only a couple of these shapes.
#
# Confirmed syntax (transpile-tests/52_union.cht): UNION with payload
# and unit variants, `Type{ Variant: v }` construction, `PARTIAL MATCH
# subj START Type.Variant -> ...; DEFAULT -> ...; END`.
#
# expected :pass; a failing/leaking :pass cell is a SURFACED bug.

MM_CELLS = []
MM_SUBJECT = %i[union_payload union_unit enum]
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
  end
end
