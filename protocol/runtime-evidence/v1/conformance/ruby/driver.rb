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
subject.ambiguous_calls(left, right)
subject.nested_receiver(left)
subject.assignment_flow(source)
subject.destructuring_flow(source)
subject.short_circuit_flow(source)
subject.native_call("value")
subject.generated_accessor(RuntimeEvidenceConformance::Generated.new(left, 1))
subject.callback_flow([left, right]) { |value| value.normalize }
subject.dynamic_dispatch(RuntimeEvidenceConformance::ProductionDispatcher.new)
subject.container_shape(source)
subject.predicate(left)
subject.subprocess_result
subject.exception_flow(RuntimeEvidenceConformance::Raiser.new)
begin
  subject.uncaught_exception_flow(RuntimeEvidenceConformance::Raiser.new)
rescue RuntimeError
  # The function-return anchor must fail closed: the function entered but did
  # not produce a return value.
end
subject.replaced_dispatch(RuntimeEvidenceConformance::TestDispatcher.new)
subject.state_flow(left)
subject.dependency_call(%w[a], %w[b])
