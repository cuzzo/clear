#!/bin/bash
# Quick test runner with per-test timeout
cd /home/yahn/cheat/examples/minivm
TESTS=(
  01_stack_alloc 02_heap_leak_cheat 03_string_mutation 05_move_frees 06_heap_return
  07_loop_scope 08_where 09_array 10_concat 11_smooth_pipe 12_while_loop
  14_hashmap 15_select 16_file_io 17_shell 13_if_else 20_subfield_move
  21_subfield_return 22_heap_subfield_move 23_optional 24_error_returns
  26_reduce 27_order_by 28_limit 30_distinct 31_multiowned 32_multiowned_return
  33_multiowned_param 34_multiowned_struct_field 35_shared 36_shared_return
  37_shared_param 38_move_ownership 39_move_return 44_do_block 45_match
  46_match_when 46_range 47_match_destructure 49_visibility 50_require
  51_enum 52_union 53_generic_struct 53_writefile 54_generic_fn 54_writefile_bg
  55_generic_union 55_string_ops 56_else_if_chain 56_match_enum_exhaustive
  57_line_parser 57_match_union_capture 58_bg 58_string_return_leak
  59_bg_concurrent 59_string_temp_takes
)
pass=0; fail=0; err=0
for t in "${TESTS[@]}"; do
  out=$(timeout 12 ruby scheme_transpiler.rb ../../transpile-tests/${t}.cht --run 2>&1)
  if echo "$out" | grep -q "SCHEME: all expressions completed"; then
    echo "  PASS  $t"
    ((pass++))
  elif echo "$out" | grep -q "SCHEME ASSERT FAILED"; then
    echo "  FAIL  $t"
    ((fail++))
  else
    first=$(echo "$out" | head -1 | cut -c1-70)
    echo "  ERR   $t: $first"
    ((err++))
  fi
done
echo "----"
echo "$pass pass, $fail fail, $err err"
