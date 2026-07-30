# frozen_string_literal: true

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

  Generated = Struct.new(:payload, :count)

  class ProductionDispatcher
    def dispatch
      Value.new(:production)
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

    def ambiguous_calls(left, right)
      left.normalize; right.normalize
    end

    def nested_receiver(value)
      value.child.normalize
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

    def native_call(value)
      value.upcase
    end

    def generated_accessor(value)
      value.payload
    end

    def callback_flow(values)
      values.map { |value| yield(value) }
    end

    def dynamic_dispatch(receiver)
      receiver.dispatch
    end

    def container_shape(source)
      rows = source.fetch(:rows)
      rows.each { |row| row.normalize }
      rows
    end

    def predicate(value)
      value.respond_to?(:normalize) ? :supported : :unsupported
    end

    def subprocess_result
      system(RbConfig.ruby, "-e", "exit 0")
      $CHILD_STATUS.success?
    end

    def exception_flow(receiver)
      receiver.fail!
    rescue RuntimeError
      :rescued
    end

    def uncaught_exception_flow(receiver)
      receiver.fail!
    end

    def replaced_dispatch(receiver)
      receiver.dispatch
    end

    def state_flow(value)
      @state = value
      @state.normalize
    end

    def dependency_call(left, right)
      Diff::LCS.diff(left, right)
    end
  end
end
