# Template: source-level value blocks in pipeline/lambda expression positions.
#
# This matrix covers the parser disambiguation and lowering path for
# `{ stmt; final_expr }` blocks that produce values. It includes compile-error
# cells for the two most important fail-closed cases: no final expression and a
# non-Bool WHERE predicate after the block is lowered.

VALUE_BLOCK_CELLS = [
  { form: :select_basic },
  { form: :select_typed_local },
  { form: :where_predicate },
  { form: :order_by },
  { form: :lambda },
  { form: :missing_result, expected: :compile_error },
  { form: :where_non_bool, expected: :compile_error },
].freeze

def value_block_body(form)
  case form
  when :select_basic
    <<~CHT
      FN main() RETURNS Void ->
          nums = [1_i64, 2_i64, 3_i64];
          picked = nums |> SELECT { doubled = _ * 2_i64; doubled + 1_i64 };
          ASSERT picked[0] == 3_i64, "value block select";
          RETURN;
      END
    CHT
  when :select_typed_local
    <<~CHT
      FN main() RETURNS Void ->
          nums = [1_i64, 2_i64, 3_i64];
          picked = nums |> SELECT { doubled: Int64 = _ * 2_i64; doubled + 1_i64 };
          ASSERT picked[2] == 7_i64, "value block typed local";
          RETURN;
      END
    CHT
  when :where_predicate
    <<~CHT
      FN main() RETURNS Void ->
          nums = [1_i64, 2_i64, 3_i64];
          picked = nums |> WHERE { candidate = _ + 1_i64; candidate > 2_i64 };
          ASSERT picked.length() == 2_i64, "value block where";
          RETURN;
      END
    CHT
  when :order_by
    <<~CHT
      FN main() RETURNS Void ->
          nums = [1_i64, 2_i64, 3_i64];
          sorted = nums |> ORDER_BY { key = 0_i64 - _; key };
          ASSERT sorted[0] == 3_i64, "value block order by";
          RETURN;
      END
    CHT
  when :lambda
    <<~CHT
      FN main() RETURNS Void ->
          transform = %(n: Int64) -> { inc = n + 1_i64; inc * 2_i64 };
          ASSERT transform(4_i64) == 10_i64, "value block lambda";
          RETURN;
      END
    CHT
  when :missing_result
    <<~CHT
      FN main() RETURNS Void ->
          nums = [1_i64, 2_i64, 3_i64];
          picked = nums |> SELECT { doubled = _ * 2_i64; };
          RETURN;
      END
    CHT
  when :where_non_bool
    <<~CHT
      FN main() RETURNS Void ->
          nums = [1_i64, 2_i64, 3_i64];
          picked = nums |> WHERE { doubled = _ * 2_i64; doubled };
          RETURN;
      END
    CHT
  else
    raise "unknown value block form #{form.inspect}"
  end
end

FuzzGenerator.register(:pipeline_value_block_matrix, cells: VALUE_BLOCK_CELLS) do |p|
  value_block_body(p.fetch(:form))
end
