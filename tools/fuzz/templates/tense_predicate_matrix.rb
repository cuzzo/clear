# Exhaustive surface matrix for postfix tense predicates and refinement chains.
cells = [
  { shape: :exists_values },
  { shape: :logical_presence },
  { shape: :is_ok_values },
  { shape: :nested_chain },
  { shape: :is_ready },
  { shape: :ambiguous_optional_bool_or, expected: :compile_error },
  { shape: :ambiguous_optional_bool_and, expected: :compile_error },
  { shape: :exists_wrong_type, expected: :compile_error },
  { shape: :is_ok_wrong_type, expected: :compile_error },
  { shape: :is_ready_bind, expected: :compile_error },
  { shape: :is_ready_stream, expected: :compile_error },
]

FuzzGenerator.register(:tense_predicate_matrix, cells: cells) do |p|
  common = <<~CLEAR
    FN nested(mode: Int64) RETURNS !?Int64 ->
      IF mode == 0_i64 THEN RAISE; END
      IF mode == 1_i64 THEN RETURN NIL; END
      RETURN 9_i64;
    END
  CLEAR

  body = case p[:shape]
  when :exists_values
    'a: ?Int64 = 1_i64; b: ?Int64 = NIL; ASSERT a EXISTS; ASSERT !(b EXISTS);'
  when :logical_presence
    'a: ?String = "x"; b: ?String = NIL; ASSERT a AND TRUE; ASSERT b OR TRUE;'
  when :is_ok_values
    'ASSERT nested(2_i64) IS_OK; ASSERT !(nested(0_i64) IS_OK);'
  when :nested_chain
    'IF nested(2_i64) IS_OK AS maybe AND maybe EXISTS AS value THEN ASSERT value == 9_i64; ELSE ASSERT FALSE; END'
  when :is_ready
    'future: ~Int64 = BG { 7_i64; }; ready = future IS_READY; ASSERT ready OR !(ready); ASSERT (NEXT future) == 7_i64;'
  when :ambiguous_optional_bool_or
    'flag: ?Bool = FALSE; ASSERT flag OR TRUE;'
  when :ambiguous_optional_bool_and
    'flag: ?Bool = TRUE; ASSERT flag AND TRUE;'
  when :exists_wrong_type
    'ASSERT 7_i64 EXISTS;'
  when :is_ok_wrong_type
    'ASSERT 7_i64 IS_OK;'
  when :is_ready_bind
    'future: ~Int64 = BG { 7_i64; }; IF future IS_READY AS value THEN ASSERT value == 7_i64; END'
  when :is_ready_stream
    'stream: ~Int64[2] = [BG { 1_i64; }, BG { 2_i64; }]; ASSERT stream IS_READY;'
  end

  { source: <<~CLEAR, error_code: (p[:expected] == :compile_error ? :TENSE_PREDICATE_REJECTED : nil) }
    #{common}
    FN main() RETURNS Void ->
      #{body}
      RETURN;
    END
  CLEAR
end
