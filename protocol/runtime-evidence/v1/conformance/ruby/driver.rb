# frozen_string_literal: true

require "English"
require "diff/lcs"
require "rbconfig"
require_relative "capabilities"
require_relative "dependency/generated_record"
require_relative "test/test_dispatcher"

subject = RuntimeEvidenceConformance::Subject.new
left = RuntimeEvidenceConformance::Value.new(:left)
right = RuntimeEvidenceConformance::Value.new(:right)
source = {
  direct: left,
  first: left,
  second: right,
  cached: right,
  rows: [left, right],
  mapping: { left: left, right: right },
  record: RuntimeEvidenceConformance::Generated.new(left, 1),
}

subject.exact_call(left)
subject.nil_return(left)
subject.ambiguous_calls(left, right)
subject.nested_receiver(left)
subject.multiline_receiver(left)
subject.nested_argument(left)
subject.assignment_flow(source)
subject.destructuring_flow(source)
subject.short_circuit_flow(source)
subject.short_circuit_guard(false, left)
subject.short_circuit_guard(true, left)
subject.safe_navigation(nil)
subject.safe_navigation(left)
subject.native_call("value")
subject.instrumented_array_writes([], left)
subject.instrumented_hash_writes({}, left)
subject.instrumented_set_writes(Set.new, left)
subject.append_string(+"prefix")
subject.local_module_function(left)
subject.nested_local_module_function(" value ")
subject.binary_search([1, 3, 5, 7], 4)
subject.binary_search_index([1, 3, 5, 7], 4)
subject.converted_index([left], 0)
subject.sorbet_typed_passthrough(left)
typed_generated = subject.typed_generated_constructor(left)
subject.typed_generated_accessor(typed_generated)
subject.open_struct_index_write(left)
generated = RuntimeEvidenceConformance::Generated.new(left, 1)
subject.generated_accessor(generated)
dependency_generated = RuntimeEvidenceConformance::DependencyGenerated.new(left, 1)
subject.excluded_generated_accessor(dependency_generated)
subject.generated_constructor(left)
subject.generated_constructor(right)
subject.generated_accessor_chain(generated)
subject.generated_accessor_write(generated, right)
subject.repeated_generated_accessor_write(generated, right)
subject.generated_override(RuntimeEvidenceConformance::GeneratedOverride.new(left))
subject.local_generated_constructor(left)
subject.local_generated_accessors(left)
subject.local_generated_writer(left)
test_arm = RuntimeEvidenceConformance::TestArm.new(7, [7, 0, 7, 4])
test_coverage = RuntimeEvidenceConformance::TestArmCoverage.new(test_arm)
subject.nested_generated_accessors(test_coverage)
test_capture = RuntimeEvidenceConformance::TestGeneratedCapture.new(test_coverage)
subject.generated_result_accessor(test_capture)
subject.callback_flow([left, right]) { |value| value.normalize }
subject.nested_callback_flow([left, right])
subject.callback_local_flow([left, right])
subject.dynamic_dispatch(RuntimeEvidenceConformance::ProductionDispatcher.new)
subject.alternative_target(left)
subject.alternative_target(RuntimeEvidenceConformance::AlternateValue.new(:alternate))
subject.container_shape(source)
subject.mapping_shape(source)
subject.record_shape(source)
subject.predicate(left)
subject.false_predicate(left)
subject.repeated_call(left)
subject.subprocess_result
system(RbConfig.ruby, "-e", "exit 0")
subject.mixed_provenance_status($CHILD_STATUS)
subject.mixed_provenance_status(RuntimeEvidenceConformance::TestStatus.new(true))
subject.mixed_generated_accessor(RuntimeEvidenceConformance::GeneratedStatus.new(7))
subject.mixed_generated_accessor(RuntimeEvidenceConformance::TestGeneratedStatus.new(8))
subject.status_after_capture(RuntimeEvidenceConformance::ProductionCapture.new)
subject.status_after_capture(RuntimeEvidenceConformance::TestCapture.new)
subject.direct_capture_status
anonymous_status =
  RuntimeEvidenceConformance::Capture3Replacement.anonymous_status(true)
RuntimeEvidenceConformance::Capture3Replacement.with_result(
  ["", "", anonymous_status]
) do
  subject.direct_capture_status
end
subject.exception_flow(RuntimeEvidenceConformance::Raiser.new)
subject.exception_result_flow(RuntimeEvidenceConformance::Raiser.new)
begin
  subject.uncaught_exception_flow(RuntimeEvidenceConformance::Raiser.new)
rescue RuntimeError
  # The function-return anchor must fail closed: the function entered but did
  # not produce a return value.
end
subject.replaced_dispatch(RuntimeEvidenceConformance::TestDispatcher.new)
subject.anonymous_replaced_dispatch(RuntimeEvidenceConformance.anonymous_dispatcher)
subject.mixed_anonymous_dispatch(RuntimeEvidenceConformance::ProductionDispatcher.new)
subject.mixed_anonymous_dispatch(RuntimeEvidenceConformance.anonymous_dispatcher)
subject.state_flow(left)
subject.state_receiver_flow(left)
subject.chained_result_flow(source)
subject.exception_value_flow
subject.dependency_call(%w[a], %w[b])
