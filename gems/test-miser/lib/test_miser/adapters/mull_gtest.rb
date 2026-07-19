# frozen_string_literal: true

require "json"
require "sqlite3"

module TestMiser
  module Adapters
    class MullGtest
      OUTCOMES = {
        1 => "killed", 2 => "survived", 3 => "timeout", 4 => "runtime_error",
        5 => "runtime_error", 8 => "uncovered"
      }.freeze
      INCOMPLETE_STATUSES = [0, 3, 4, 5, 6, 7].freeze
      FAILURE_PATTERN = /^\[\s*FAILED\s*\]\s+(\S+)\s+\(/.freeze

      def initialize(database:, gtest_json:, root: Dir.pwd, language: "cpp")
        @database_path = database
        @gtest_json_path = gtest_json
        @root = File.expand_path(root)
        @language = language
      end

      def call
        rows = database.execute("SELECT * FROM mutant")
        complete = rows.none? { |row| INCOMPLETE_STATUSES.include?(row.fetch("execution_status")) }
        payload = {
          "schema" => "mutant-facts/v1",
          "source" => "mull-gtest",
          "language" => @language,
          "mutation_kind" => "stochastic",
          "subjects" => [],
          "tests" => gtest_tests,
          "mutants" => rows.map { |row| mutant(row) },
          "test_miser" => {
            "complete" => complete,
            "attribution_complete" => complete,
            "run_to_complete" => true
          }
        }
        database.close
        @database = nil
        payload
      rescue SQLite3::Exception => error
        raise InvalidReport, "invalid Mull SQLite report: #{error.message}"
      rescue JSON::ParserError => error
        raise InvalidReport, "invalid GoogleTest JSON report: #{error.message}"
      end

      private

      def database
        @database ||= SQLite3::Database.new(@database_path, results_as_hash: true)
      end

      def gtest_tests
        payload = JSON.parse(File.read(@gtest_json_path))
        Array(payload["testsuites"]).flat_map do |suite|
          Array(suite["testsuite"]).map do |test|
            name = "#{suite.fetch('name')}.#{test.fetch('name')}"
            {
              "id" => "gtest:#{name}",
              "name" => name,
              "file" => relative(test["file"]),
              "line" => test["line"]
            }
          end
        end
      end

      def mutant(row)
        output = "#{row['stdout']}\n#{row['stderr']}"
        failed = output.scan(FAILURE_PATTERN).flatten.uniq.map { |name| "gtest:#{name}" }
        {
          "id" => "mull:#{row.fetch('mutant_id')}",
          "file" => relative(row["filename"]),
          "kind" => row["mutator"],
          "line" => row["line_number"],
          "outcome" => OUTCOMES.fetch(row["execution_status"], "unknown"),
          "covered_by" => failed,
          "killed_by" => failed
        }
      end

      def relative(path)
        return unless path

        expanded = File.expand_path(path)
        expanded.start_with?("#{@root}/") ? expanded.delete_prefix("#{@root}/") : path
      end
    end
  end
end
