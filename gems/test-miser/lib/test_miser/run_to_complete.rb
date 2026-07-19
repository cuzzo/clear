# frozen_string_literal: true

require "timeout"
require_relative "run_to_complete_minitest"

module TestMiser
  module RunToComplete
    module_function

    def call(integration, tests, timeout:)
      if defined?(::Mutant::Integration::Minitest) && integration.is_a?(::Mutant::Integration::Minitest)
        return RunToCompleteMinitest.call(integration, tests, timeout: timeout)
      end

      killed_by = tests.filter_map do |test|
        result = Timeout.timeout(timeout) { integration.call([test]) }
        test.id unless result.passed
      rescue Timeout::Error
        test.id
      end
      { "passed" => killed_by.empty?, "killedBy" => killed_by }
    end
  end
end
