# frozen_string_literal: true

require "English"
require "diff/lcs"
require "rbconfig"
require_relative "capabilities"
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
}

subject.exact_call(left)
subject.nil_return(left)
subject.ambiguous_calls(left, right)
subject.nested_receiver(left)
subject.assignment_flow(source)
subject.destructuring_flow(source)
subject.short_circuit_flow(source)
subject.short_circuit_guard(false, left)
subject.short_circuit_guard(true, left)
subject.native_call("value")
generated = RuntimeEvidenceConformance::Generated.new(left, 1)
subject.generated_accessor(generated)
subject.generated_constructor(left)
subject.generated_constructor(right)
subject.generated_accessor_chain(generated)
subject.generated_accessor_write(generated, right)
subject.callback_flow([left, right]) { |value| value.normalize }
subject.nested_callback_flow([left, right])
subject.dynamic_dispatch(RuntimeEvidenceConformance::ProductionDispatcher.new)
subject.container_shape(source)
subject.predicate(left)
subject.subprocess_result
system(RbConfig.ruby, "-e", "exit 0")
subject.mixed_provenance_status($CHILD_STATUS)
subject.mixed_provenance_status(RuntimeEvidenceConformance::TestStatus.new(true))
subject.exception_flow(RuntimeEvidenceConformance::Raiser.new)
subject.exception_result_flow(RuntimeEvidenceConformance::Raiser.new)
begin
  subject.uncaught_exception_flow(RuntimeEvidenceConformance::Raiser.new)
rescue RuntimeError
  # The function-return anchor must fail closed: the function entered but did
  # not produce a return value.
end
subject.replaced_dispatch(RuntimeEvidenceConformance::TestDispatcher.new)
subject.state_flow(left)
subject.dependency_call(%w[a], %w[b])
