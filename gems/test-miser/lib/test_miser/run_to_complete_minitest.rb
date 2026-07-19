# frozen_string_literal: true

require "timeout"
require "stringio"

module TestMiser
  module RunToCompleteMinitest
    module_function

    def call(integration, tests, timeout:)
      index = integration.__send__(:all_tests_index)
      reporter = ::Minitest::SummaryReporter.new(StringIO.new)
      killed_by = []
      reporter.start

      tests.each do |test|
        results_before = reporter.results.length
        begin
          ::Timeout.timeout(timeout) { index.fetch(test).call(reporter) }
        rescue ::Timeout::Error
          killed_by << test.id
          next
        end
        new_results = reporter.results.drop(results_before)
        killed_by << test.id if new_results.any? { |result| !result.skipped? }
      end

      reporter.report
      { "passed" => killed_by.empty?, "killedBy" => killed_by }
    end
  end
end
