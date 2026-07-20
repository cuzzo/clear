# frozen_string_literal: true

# End-to-end source matrix for the annotation-to-MIR tense-operation handoff.
# The larger operation-specific matrices explore syntax placement and ordered
# tense permutations; this matrix keeps every centralized operation executable
# through the ordinary compiler pipeline.
require_relative '../select_tense_semantics'

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

cells = cells + SelectTenseSemantics::VALID_ORDERS.reject(&:empty?).flat_map do |order|
  [
    { operation: :navigate_field, order: order },
    { operation: :navigate_method, order: order },
  ]
end
cells.concat([
  { operation: :navigate_skipped, expected: :compile_error },
  { operation: :navigate_stream, expected: :compile_error },
  { operation: :navigate_nested_future, expected: :compile_error },
  { operation: :navigate_mutation, expected: :compile_error },
])
cells.freeze

FuzzGenerator.register(:tense_operation_plan_matrix, cells: cells) do |params|
  if %i[navigate_field navigate_method].include?(params.fetch(:operation))
    order = params.fetch(:order)
    member = params.fetch(:operation) == :navigate_field ? 'value' : 'read()'
    consume = if order.start_with?('!~')
                'NEXT (TRY mapped);'
              elsif order.start_with?('~')
                'NEXT mapped;'
              end
    next <<~CLEAR
      STRUCT PlannedValue { value: Int64 }
      IMPLEMENTATION PlannedValue {
        METHOD read(self) RETURNS Int64 -> RETURN self.value; END
      }
      FN planned(input: #{order}PlannedValue) RETURNS !Void ->
        mapped: #{order}Int64 = input#{order}.#{member};
        #{consume}
        RETURN;
      END
      FN main() RETURNS Void -> RETURN; END
    CLEAR
  end

  case params.fetch(:operation)
  when :navigate_skipped
    next <<~CLEAR
      STRUCT PlannedValue { value: Int64 }
      FN main(input: ~!PlannedValue) -> value = input~.value; END
    CLEAR
  when :navigate_stream
    next <<~CLEAR
      STRUCT PlannedValue { value: Int64 }
      FN main(input: [~]PlannedValue) -> value = input~.value; END
    CLEAR
  when :navigate_nested_future
    next <<~CLEAR
      STRUCT PlannedValue { value: Int64 }
      IMPLEMENTATION PlannedValue {
        METHOD later(self) RETURNS ~Int64 -> RETURN BG { self.value; }; END
      }
      FN main(input: ~PlannedValue) -> value:~ = input~.later(); END
    CLEAR
  when :navigate_mutation
    next <<~CLEAR
      STRUCT PlannedValue { value: Int64 }
      FN main(input: ~PlannedValue) -> input~.value = 2; END
    CLEAR
  end

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
