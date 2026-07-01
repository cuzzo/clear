# Template: @indirect union payload memory safety.
# Exercises the single-source @indirect layout (Type#layout == :indirect ->
# exactly one pointer level): construct, MATCH-extract, deref-on-read, and
# cleanup of @indirect union payloads across payload kinds, including the
# recursive (self-referential) shapes from examples/mal.
#
# Cross-references:
#   - CLAUDE.md "Group 2 (data shape)" / @indirect heap-pinned cell
#   - transpile-tests/174_union_match_struct_fields.clear (inline-struct field)
#   - transpile-tests/520_mal_indirect_lambda_body_cleanup.clear (recursive)
#   - INV-INDIRECT-SINGLE-BOX (mir_checker): no double box.
#
# Cell schema: { payload:, op: }
#   payload ∈ {int_single, str_single, int_inline, str_inline,
#              rec_single, rec_inline}
#   op      ∈ {local, return}
#
# Every cell is expected to :pass leak-free. A failing or leaking cell is a
# real regression in the @indirect box/deref/cleanup path (double-box UAF,
# missing deref, or unreleased payload allocation).

INDIRECT_RU_PAYLOADS = %i[
  int_single str_single int_inline str_inline rec_single rec_inline
].freeze

INDIRECT_RU_OPS = %i[local return].freeze

INDIRECT_RU_CELLS = INDIRECT_RU_PAYLOADS.flat_map do |payload|
  INDIRECT_RU_OPS.map { |op| { payload: payload, op: op } }
end

# Variant declaration line for the payload kind under test.
def indirect_ru_variant_decl(payload)
  case payload
  when :int_single then "Box: Int64 @indirect"
  when :str_single then "Box: String @indirect"
  when :int_inline then "Box { v: Int64 @indirect }"
  when :str_inline then "Box { v: String @indirect }"
  when :rec_single then "Box: U @indirect"
  when :rec_inline then "Box { inner: U @indirect }"
  end
end

# Constructor expression for the variant under test.
def indirect_ru_ctor(payload)
  case payload
  when :int_single then "U{ Box: 7_i64 }"
  when :str_single then "U{ Box: \"hi\" }"
  when :int_inline then "U.Box{ v: 7_i64 }"
  when :str_inline then "U.Box{ v: \"hi\" }"
  when :rec_single then "U{ Box: U{ Lit: 3_i64 } }"
  when :rec_inline then "U.Box{ inner: U{ Lit: 3_i64 } }"
  end
end

# The MATCH arm body that extracts the @indirect payload and ASSERTs it.
def indirect_ru_check(payload)
  case payload
  when :int_single
    %(U.Box AS b -> ASSERT b == 7_i64, "int single";)
  when :str_single
    %(U.Box AS b -> ASSERT b == "hi", "str single";)
  when :int_inline
    %(U.Box AS b -> ASSERT b.v == 7_i64, "int inline";)
  when :str_inline
    %(U.Box AS b -> ASSERT b.v == "hi", "str inline";)
  when :rec_single
    <<~ARM.strip
      U.Box AS inner ->
              c = COPY inner;
              PARTIAL MATCH c START
                  U.Lit AS n -> ASSERT n == 3_i64, "rec single";,
                  DEFAULT -> ASSERT FALSE, "rec single shape";
              END
    ARM
  when :rec_inline
    <<~ARM.strip
      U.Box AS w ->
              c = COPY w.inner;
              PARTIAL MATCH c START
                  U.Lit AS n -> ASSERT n == 3_i64, "rec inline";,
                  DEFAULT -> ASSERT FALSE, "rec inline shape";
              END
    ARM
  end
end

FuzzGenerator.register(:indirect_recursive_union, cells: INDIRECT_RU_CELLS) do |p|
  union_decl = <<~CHT.strip
    UNION U {
        Nil,
        Lit: Int64,
        #{indirect_ru_variant_decl(p[:payload])}
    }
  CHT

  match_block = <<~CHT.strip
    PARTIAL MATCH subject START
            #{indirect_ru_check(p[:payload])},
            DEFAULT -> ASSERT FALSE, "expected Box variant";
        END
  CHT

  case p[:op]
  when :local
    <<~CHT
      #{union_decl}

      FN main() RETURNS Void ->
          subject = #{indirect_ru_ctor(p[:payload])};
          #{match_block}
          RETURN;
      END
    CHT
  when :return
    <<~CHT
      #{union_decl}

      FN make!() RETURNS !U ->
          RETURN #{indirect_ru_ctor(p[:payload])};
      END

      FN main() RETURNS Void ->
          subject = make!() OR RAISE;
          #{match_block}
          RETURN;
      END
    CHT
  end
end
