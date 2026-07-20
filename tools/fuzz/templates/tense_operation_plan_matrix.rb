# frozen_string_literal: true

# End-to-end source matrix for the annotation-to-MIR tense-operation handoff.
# The larger operation-specific matrices explore syntax placement and ordered
# tense permutations; this matrix keeps every centralized operation executable
# through the ordinary compiler pipeline.
cells = [
  { operation: :try_fallible },
  { operation: :try_optional },
  { operation: :unwrap },
  { operation: :or_else_fallible },
  { operation: :or_else_optional },
  { operation: :is_ok },
  { operation: :exists },
  { operation: :next },
].freeze

FuzzGenerator.register(:tense_operation_plan_matrix, cells: cells) do |params|
  expression, assertion = case params.fetch(:operation)
  when :try_fallible
    ["TRY risky()", "value == 7"]
  when :try_optional
    ["TRY maybe()", "value == 8"]
  when :unwrap
    ["UNWRAP maybe()", "value == 8"]
  when :or_else_fallible
    ["risky() OR_ELSE 9", "value == 7"]
  when :or_else_optional
    ["missing() OR_ELSE 9", "value == 9"]
  when :is_ok
    ["risky() IS_OK", "value"]
  when :exists
    ["maybe() EXISTS", "value"]
  when :next
    ["NEXT BG { 10; }", "value == 10"]
  else
    raise "unknown tense operation #{params.inspect}"
  end

  <<~CLEAR
    FN risky() RETURNS !Int64 -> RETURN 7; END
    FN maybe() RETURNS ?Int64 -> RETURN 8; END
    FN missing() RETURNS ?Int64 -> RETURN NIL; END
    FN main() RETURNS !Void ->
      value = #{expression};
      ASSERT #{assertion};
      RETURN;
    END
  CLEAR
end
