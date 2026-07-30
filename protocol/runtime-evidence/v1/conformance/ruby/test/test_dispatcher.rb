# frozen_string_literal: true

module RuntimeEvidenceConformance
  # This implementation deliberately lives in a non-production path. The
  # collector must preserve it as raw evidence while FactMine must not publish
  # it as a production target.
  class TestDispatcher
    def dispatch
      Value.new(:test)
    end
  end

  TestStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  TestGeneratedStatus = Struct.new(:decision_line)

  class TestCapture
    def capture
      ["", "", TestStatus.new(true)]
    end
  end

  TestArm = Struct.new(:line, :span)
  TestArmCoverage = Struct.new(:arm)

  class TestGeneratedCapture
    def initialize(value)
      @value = value
    end

    def capture
      @value
    end
  end

  # Models a test framework replacing a dependency call with a value whose
  # anonymous generated class is created inside non-production code. This is
  # materially different from a named, preloaded test double: its native
  # accessor provenance exists only at runtime.
  module Capture3Replacement
    module_function

    def anonymous_status(ok)
      Struct.new(:ok) do
        def success?
          ok
        end
      end.new(ok)
    end

    def with_result(result)
      original = Open3.method(:capture3)
      Open3.define_singleton_method(:capture3) { |*_args| result }
      yield
    ensure
      Open3.define_singleton_method(:capture3, original)
    end
  end
end
