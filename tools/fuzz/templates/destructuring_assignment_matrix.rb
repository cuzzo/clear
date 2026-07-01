# Template: destructuring assignment matrix.
#
# Covers fixed-shape destructuring declaration, explicit target types, mutable
# target lowering, reassignment, mixed assignment/declaration, and discard
# targets. Every cell is a positive source program with ASSERT oracles; failure
# means parser/annotator/MIR lowering diverged on a supported destructuring shape.

DAM_CELLS = [
  { mode: :decl },
  { mode: :typed_decl },
  { mode: :mutable_decl },
  { mode: :reassign },
  { mode: :mixed_existing_new },
  { mode: :discard },
]

FuzzGenerator.register(:destructuring_assignment_matrix, cells: DAM_CELLS) do |p|
  case p[:mode]
  when :decl
    <<~CLEAR
      FN main() RETURNS Void ->
          a, b = [1_i64, 2_i64];
          ASSERT a == 1_i64, "destructure inferred a";
          ASSERT b == 2_i64, "destructure inferred b";
          RETURN;
      END
    CLEAR
  when :typed_decl
    <<~CLEAR
      FN main() RETURNS Void ->
          a: Int64, b: Int64 = [3_i64, 4_i64];
          ASSERT a == 3_i64, "destructure typed a";
          ASSERT b == 4_i64, "destructure typed b";
          RETURN;
      END
    CLEAR
  when :mutable_decl
    <<~CLEAR
      FN main() RETURNS Void ->
          MUTABLE a: Int64, b: Int64 = [5_i64, 6_i64];
          a = a + 1_i64;
          ASSERT a == 6_i64, "destructure mutable a";
          ASSERT b == 6_i64, "destructure mutable b";
          RETURN;
      END
    CLEAR
  when :reassign
    <<~CLEAR
      FN main() RETURNS Void ->
          MUTABLE a: Int64 = 0_i64;
          MUTABLE b: Int64 = 0_i64;
          a, b = [7_i64, 8_i64];
          ASSERT a == 7_i64, "destructure assign a";
          ASSERT b == 8_i64, "destructure assign b";
          RETURN;
      END
    CLEAR
  when :mixed_existing_new
    <<~CLEAR
      FN main() RETURNS Void ->
          MUTABLE a: Int64 = 0_i64;
          a, MUTABLE b: Int64 = [9_i64, 10_i64];
          b = b + 1_i64;
          ASSERT a == 9_i64, "destructure mixed assign";
          ASSERT b == 11_i64, "destructure mixed declaration";
          RETURN;
      END
    CLEAR
  when :discard
    <<~CLEAR
      FN main() RETURNS Void ->
          a: Int64, _ = [11_i64, 12_i64];
          ASSERT a == 11_i64, "destructure discard";
          RETURN;
      END
    CLEAR
  end
end
