# frozen_string_literal: true

require "open3"
require "ostruct"
require "set"
require "sorbet-runtime"

module RuntimeEvidenceConformance
  class Value
    attr_reader :payload

    def initialize(payload)
      @payload = payload
    end

    def child
      self
    end

    def normalize
      payload.to_s
    end
  end

  class AlternateValue
    def initialize(payload)
      @payload = payload
    end

    def normalize
      @payload.to_s.upcase
    end
  end

  Generated = Struct.new(:payload, :count)
  GeneratedStatus = Struct.new(:decision_line)
  class TypedGenerated < T::Struct
    const :payload, Object
  end

  GeneratedOverride = Struct.new(:payload) do
    def payload
      "override:#{self[:payload]}"
    end
  end

  class ProductionDispatcher
    def dispatch
      Value.new(:production)
    end
  end

  class ProductionCapture
    def capture
      system(RbConfig.ruby, "-e", "exit 0")
      ["", "", $CHILD_STATUS]
    end
  end

  class Raiser
    def fail!
      raise "expected conformance exception"
    end
  end

  class Subject
    def exact_call(value)
      value.normalize
    end

    def nil_return(value)
      value.normalize
      nil
    end

    def ambiguous_calls(left, right)
      left.normalize; right.normalize
    end

    def nested_receiver(value)
      value.child.normalize
    end

    def multiline_receiver(value)
      value
        .child
        .normalize
    end

    def nested_argument(value)
      accept(value.normalize)
    end

    def accept(value)
      value
    end

    def assignment_flow(source)
      value = source.fetch(:direct)
      value.normalize
    end

    def destructuring_flow(source)
      first, second = source.values_at(:first, :second)
      [first.normalize, second.normalize]
    end

    def short_circuit_flow(source)
      value = nil
      value ||= source.fetch(:cached)
      value.normalize
    end

    def short_circuit_guard(enabled, value)
      enabled && value.normalize
    end

    def safe_navigation(value)
      value&.normalize
    end

    def native_call(value)
      value.upcase
    end

    def instrumented_array_writes(values, value)
      values << value
      values.push(value)
      values.append(value)
      values.unshift(value)
      values[0] = value
      values.concat([value])
      values
    end

    def instrumented_hash_writes(values, value)
      values[:index] = value
      values.store(:store, value)
      values.merge!(merge: value)
      values.update(update: value)
      values
    end

    def instrumented_set_writes(values, value)
      values.add(value)
      values << value
      values.merge([value])
      values
    end

    def converted_index(value, index)
      Array(value)[index]
    end

    def sorbet_typed_passthrough(value)
      T.let(value, Object)
    end

    def typed_generated_constructor(value)
      TypedGenerated.new(payload: value)
    end

    def typed_generated_accessor(value)
      value.payload
    end

    def open_struct_index_write(value)
      record = OpenStruct.new
      record[:payload] = value
      record[:payload]
    end

    def generated_accessor(value)
      value.payload
    end

    def generated_constructor(value)
      Generated.new(value, 2)
    end

    def generated_accessor_chain(value)
      value.payload.normalize
    end

    def generated_accessor_write(value, replacement)
      value.payload = replacement
      value.payload
    end

    def repeated_generated_accessor_write(value, replacement)
      value.payload = value.payload == replacement.payload ? value.payload : replacement.payload
      value.payload
    end

    def generated_override(value)
      value.payload
    end

    def local_generated_constructor(value)
      Struct.new(:payload, :count, keyword_init: true).new(payload: value, count: 2)
    end

    def local_generated_accessors(value)
      record_type = Struct.new(
        :kind,
        :decision_line,
        :decision_span,
        keyword_init: true
      )
      record = record_type.new(
        kind: :branch,
        decision_line: 7,
        decision_span: [7, 0, 7, 4]
      )
      [record.kind, record.decision_line, record.decision_span, value]
    end

    def local_generated_writer(value)
      record_type = Struct.new(:payload, keyword_init: true)
      record = record_type.new(payload: value)
      record.payload = Value.new(:replacement)
      record.payload
    end

    def nested_generated_accessors(coverage)
      [coverage.arm.line, coverage.arm.span]
    end

    def generated_result_accessor(provider)
      provider.capture.arm.span
    end

    def callback_flow(values)
      values.map { |value| yield(value) }
    end

    def nested_callback_flow(values)
      values.map { |value| value.normalize }.select { |value| !value.empty? }
    end

    def callback_local_flow(values)
      values.each_with_object([]) do |value, output|
        output << value.normalize
      end
    end

    def dynamic_dispatch(receiver)
      receiver.dispatch
    end

    def alternative_target(receiver)
      receiver.normalize
    end

    def container_shape(source)
      rows = source.fetch(:rows)
      rows.each { |row| row.normalize }
      rows
    end

    def mapping_shape(source)
      mapping = source.fetch(:mapping)
      mapping.keys
    end

    def record_shape(source)
      record = source.fetch(:record)
      record.payload
    end

    def predicate(value)
      value.respond_to?(:normalize) ? :supported : :unsupported
    end

    def false_predicate(value)
      value.respond_to?(:missing_runtime_evidence_method) ? :unexpected : :expected
    end

    def repeated_call(value)
      3.times { value.normalize }
    end

    def subprocess_result
      system(RbConfig.ruby, "-e", "exit 0")
      $CHILD_STATUS.success?
    end

    def mixed_provenance_status(status)
      status.success?
    end

    def mixed_generated_accessor(status)
      status.decision_line
    end

    def status_after_capture(provider)
      _stdout, _stderr, status = provider.capture
      status.success?
    end

    def direct_capture_status
      _stdout, _stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-e",
        "exit 0"
      )
      status.success?
    end

    def exception_flow(receiver)
      receiver.fail!
    rescue RuntimeError
      :rescued
    end

    def exception_result_flow(receiver)
      value = receiver.fail!
      value.normalize
    rescue RuntimeError
      :rescued
    end

    def uncaught_exception_flow(receiver)
      receiver.fail!
    end

    def replaced_dispatch(receiver)
      receiver.dispatch
    end

    def anonymous_replaced_dispatch(receiver)
      receiver.dispatch
    end

    def mixed_anonymous_dispatch(receiver)
      receiver.dispatch
    end

    def state_flow(value)
      @state = value
      @state.normalize
    end

    def state_receiver_flow(value)
      @cached = value
      @cached.normalize
    end

    def chained_result_flow(source)
      source.fetch(:rows).first.normalize
    end

    def exception_value_flow
      raise "runtime evidence"
    rescue RuntimeError => error
      error.message
    end

    def dependency_call(left, right)
      Diff::LCS.diff(left, right)
    end
  end
end
