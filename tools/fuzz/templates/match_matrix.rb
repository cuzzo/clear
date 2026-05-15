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

MM_SUBJECT.each do |s|
  MM_DEFAULT.each do |d|
    MM_CELLS << { subject: s, default: d }
  end
end

def mm_default_arm(d)
  d == :with_default ? "        DEFAULT -> got = 9.0;\n" : ""
end

FuzzGenerator.register(:match_matrix, cells: MM_CELLS) do |p|
  case p[:subject]
  when :union_payload
    <<~CHT
      UNION Shape { Circle: Float64, Rect: Float64, Empty }

      FN main() RETURNS Void ->
          s = Shape{ Circle: 2.0 };
          MUTABLE got: Float64 = 0.0;
          PARTIAL MATCH s START
              Shape.Circle -> got = 1.0;,
              Shape.Rect   -> got = 2.0;,
      #{mm_default_arm(p[:default])}    END
          ASSERT got == 1.0, "union payload match";
          RETURN;
      END
    CHT
  when :union_unit
    <<~CHT
      UNION Shape { Circle: Float64, Rect: Float64, Empty }

      FN main() RETURNS Void ->
          s = Shape.Empty;
          MUTABLE got: Float64 = 0.0;
          PARTIAL MATCH s START
              Shape.Empty  -> got = 5.0;,
              Shape.Circle -> got = 1.0;,
      #{mm_default_arm(p[:default])}    END
          ASSERT got == 5.0, "union unit match";
          RETURN;
      END
    CHT
  when :enum
    <<~CHT
      ENUM Dir { North, South, East }

      FN main() RETURNS Void ->
          d: Dir = Dir.South;
          MUTABLE got: Float64 = 0.0;
          PARTIAL MATCH d START
              Dir.North -> got = 1.0;,
              Dir.South -> got = 2.0;,
      #{mm_default_arm(p[:default])}    END
          ASSERT got == 2.0, "enum match";
          RETURN;
      END
    CHT
  end
end
