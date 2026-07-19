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
  { form: :select_fallible_unmarked, expected: :compile_error },
  { form: :select_optional_unmarked, expected: :compile_error },
  { form: :select_both_unmarked, expected: :compile_error },
  { form: :select_fallible_marked },
  { form: :select_optional_marked },
  { form: :select_both_marked },
  { form: :select_effect_recovered },
  { form: :select_async_explicit },
  { form: :where_fallible, expected: :compile_error },
  { form: :where_optional, expected: :compile_error },
  { form: :where_async, expected: :compile_error },
  { form: :where_recovered },
  { form: :concurrent_select_fallible_marked },
  { form: :concurrent_select_optional_marked },
  { form: :concurrent_select_both_marked },
  { form: :concurrent_select_async_explicit },
  { form: :concurrent_where_fallible, expected: :compile_error },
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
  when :select_fallible_unmarked, :select_optional_unmarked, :select_both_unmarked,
       :select_fallible_marked, :select_optional_marked, :select_both_marked,
       :select_effect_recovered, :select_async_explicit, :where_fallible,
       :where_optional, :where_async, :where_recovered,
       :concurrent_select_fallible_marked, :concurrent_select_optional_marked,
       :concurrent_select_both_marked, :concurrent_select_async_explicit,
       :concurrent_where_fallible
    effect_pipeline_body(form)
  else
    raise "unknown value block form #{form.inspect}"
  end
end

def effect_pipeline_body(form)
  expression = case form
  when :select_fallible_unmarked then "picked = nums |> SELECT fallible(_);"
  when :select_optional_unmarked then "picked = nums |> SELECT optional(_);"
  when :select_both_unmarked then "picked = nums |> SELECT both(_);"
  when :select_fallible_marked then "picked = nums |> SELECT! fallible(_); picked |> EACH { ASSERT TRY _ > 0; };"
  when :select_optional_marked then "picked = nums |> SELECT? optional(_); picked |> EACH { ASSERT UNWRAP _ > 0; };"
  when :select_both_marked then "picked = nums |> SELECT!? both(_); picked |> EACH { ASSERT TRY UNWRAP _ > 0; };"
  when :select_effect_recovered then "picked = nums |> SELECT fallible(_) OR_ELSE 0; ASSERT picked.length() == 3;"
  when :select_async_explicit then "picked:~ = nums |> SELECT later(_); resolved: []Int64 = NEXT picked; ASSERT resolved.length() == 3;"
  when :where_fallible then "picked = nums |> WHERE falliblePredicate(_);"
  when :where_optional then "picked = nums |> WHERE optionalPredicate(_);"
  when :where_async then "picked = nums |> WHERE asyncPredicate(_);"
  when :where_recovered then "picked = nums |> WHERE falliblePredicate(_) OR_ELSE FALSE; ASSERT picked.length() == 3;"
  when :concurrent_select_fallible_marked then "picked = nums |> CONCURRENT(workers: 2) SELECT! fallible(_); picked |> EACH { ASSERT TRY _ > 0; };"
  when :concurrent_select_optional_marked then "picked = nums |> CONCURRENT(workers: 2) SELECT? optional(_); picked |> EACH { ASSERT UNWRAP _ > 0; };"
  when :concurrent_select_both_marked then "picked = nums |> CONCURRENT(workers: 2) SELECT!? both(_); picked |> EACH { ASSERT TRY UNWRAP _ > 0; };"
  when :concurrent_select_async_explicit then "picked:~ = nums |> CONCURRENT(workers: 2) SELECT later(_); resolved: []Int64 = NEXT picked; ASSERT resolved.length() == 3;"
  when :concurrent_where_fallible then "picked = nums |> CONCURRENT(workers: 2) WHERE falliblePredicate(_);"
  else raise "unknown effect pipeline form #{form.inspect}"
  end

  <<~CHT
    FN fallible(value: Int64) RETURNS !Int64 -> RETURN value; END
    FN optional(value: Int64) RETURNS ?Int64 -> RETURN value; END
    FN both(value: Int64) RETURNS !?Int64 -> RETURN value; END
    FN falliblePredicate(value: Int64) RETURNS !Bool -> RETURN value > 0; END
    FN optionalPredicate(value: Int64) RETURNS ?Bool -> RETURN value > 0; END
    FN asyncPredicate(value: Int64) RETURNS ~Bool -> RETURN BG { value > 0; }; END
    FN later(value: Int64) RETURNS ~Int64 -> RETURN BG { value; }; END
    FN main() RETURNS !Void ->
        nums: []Int64 = [1, 2, 3];
        #{expression}
        RETURN;
    END
  CHT
end

FuzzGenerator.register(:pipeline_value_block_matrix, cells: VALUE_BLOCK_CELLS) do |p|
  value_block_body(p.fetch(:form))
end
