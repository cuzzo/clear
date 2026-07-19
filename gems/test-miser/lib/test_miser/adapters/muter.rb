# frozen_string_literal: true

require "json"

module TestMiser
  module Adapters
    class Muter
      TEST_PATTERN = /^Test Case '([^']+)' (?:passed|failed)/.freeze
      FAILURE_PATTERN = /^Test Case '([^']+)' failed/.freeze
      OUTCOMES = {
        "failed" => "killed", "passed" => "survived", "noCoverage" => "uncovered",
        "timeout" => "timeout", "buildError" => "build_error", "runtimeError" => "runtime_error"
      }.freeze

      def initialize(report:, logs:, root: Dir.pwd)
        @report_path = report
        @logs_path = logs
        @root = File.expand_path(root)
      end

      def call
        report = JSON.parse(File.read(@report_path))
        baseline = baseline_log
        names = baseline.scan(TEST_PATTERN).flatten.uniq
        tests = names.map { |name| test(name) }
        records = mutation_records(report)
        complete = records.all? do |record|
          record[:log] && names.all? { |name| record[:log].match?(/^Test Case '#{Regexp.escape(name)}' (?:passed|failed)/) }
        end

        {
          "schema" => "mutant-facts/v1",
          "source" => "muter",
          "language" => "swift",
          "mutation_kind" => "stochastic",
          "subjects" => [],
          "tests" => tests,
          "mutants" => records.map { |record| mutant(record) },
          "test_miser" => {
            "complete" => complete,
            "attribution_complete" => complete,
            "run_to_complete" => complete
          }
        }
      rescue JSON::ParserError => error
        raise InvalidReport, "invalid Muter JSON report: #{error.message}"
      end

      private

      def baseline_log
        path = Dir.glob(File.join(@logs_path, "**", "baseline run.log")).max_by { |item| File.mtime(item) }
        raise InvalidReport, "Muter logs do not contain a baseline run" unless path

        File.read(path)
      end

      def mutation_records(report)
        report.fetch("fileReports").flat_map do |file_report|
          file_report.fetch("appliedOperators").each_with_index.map do |operator, index|
            point = operator.fetch("mutationPoint")
            position = point.fetch("position")
            filename = file_report.fetch("fileName")
            kind = point.fetch("mutationOperatorId")
            pattern = File.join(@logs_path, "**", "#{kind} @ #{filename}-#{position.fetch('line')}-#{position.fetch('column')}.log")
            log_path = Dir.glob(pattern).max_by { |item| File.mtime(item) }
            { operator: operator, point: point, position: position, filename: filename,
              index: index, log: log_path && File.read(log_path) }
          end
        end
      end

      def test(name)
        method = name.split(".").last
        path, line = Dir.glob(File.join(@root, "Tests", "**", "*.swift")).filter_map do |candidate|
          lines = File.readlines(candidate)
          index = lines.index { |source_line| source_line.match?(/\bfunc\s+#{Regexp.escape(method)}\b/) }
          [candidate, index + 1] if index
        end.first
        {
          "id" => "swift:#{name}",
          "name" => name,
          "file" => path && relative(path),
          "line" => line
        }
      end

      def mutant(record)
        point = record.fetch(:point)
        position = record.fetch(:position)
        kind = point.fetch("mutationOperatorId")
        failed = record[:log].to_s.scan(FAILURE_PATTERN).flatten.uniq.map { |name| "swift:#{name}" }
        {
          "id" => "muter:#{record.fetch(:filename)}:#{kind}:#{position.fetch('line')}:#{position.fetch('column')}:#{record.fetch(:index)}",
          "file" => source_file(record.fetch(:filename)),
          "kind" => kind,
          "line" => position.fetch("line"),
          "outcome" => OUTCOMES.fetch(record.fetch(:operator).fetch("testSuiteOutcome"), "unknown"),
          "covered_by" => failed,
          "killed_by" => failed
        }
      end

      def source_file(filename)
        path = Dir.glob(File.join(@root, "Sources", "**", filename)).first
        path ? relative(path) : filename
      end

      def relative(path)
        File.expand_path(path).delete_prefix("#{@root}/")
      end
    end
  end
end
