# frozen_string_literal: true

require "json"
require "rexml/document"

module TestMiser
  module Adapters
    class Infection
      REPORT_PATTERN = /\.report\s*=\s*(\{.*\})\s*$/

      def initialize(report:, junit:, root: Dir.pwd)
        @report_path = report
        @junit_path = junit
        @root = File.expand_path(root)
      end

      def call
        report = extract_report
        known_tests = report.fetch("testFiles", {}).flat_map do |file, details|
          Array(details["tests"]).map { |test| [test.fetch("name"), test.fetch("id"), file] }
        end

        {
          "schema" => "mutant-facts/v1",
          "source" => "infection",
          "language" => "php",
          "mutation_kind" => "stochastic",
          "subjects" => [],
          "tests" => junit_tests(known_tests),
          "mutants" => mutants(report),
          "test_miser" => {
            "complete" => true,
            "attribution_complete" => true,
            "run_to_complete" => true
          }
        }
      rescue JSON::ParserError => error
        raise InvalidReport, "invalid Infection report: #{error.message}"
      rescue REXML::ParseException => error
        raise InvalidReport, "invalid PHPUnit JUnit report: #{error.message}"
      end

      private

      def extract_report
        line = File.foreach(@report_path).find { |candidate| candidate.include?(".report =") }
        json = line&.match(REPORT_PATTERN)&.[](1)
        raise InvalidReport, "Infection HTML report does not contain Mutation Testing Elements data" unless json

        JSON.parse(json)
      end

      def junit_tests(known_tests)
        document = REXML::Document.new(File.read(@junit_path))
        document.elements.to_a("//testcase").map do |testcase|
          method = testcase.attributes["name"].to_s
          klass = testcase.attributes["class"].to_s
          match = known_tests.find { |name, _id, _file| name == "#{klass}::#{method}" }
          {
            "id" => match ? match[1] : "phpunit:#{klass}::#{method}",
            "name" => "#{klass}::#{method}",
            "file" => relative(testcase.attributes["file"]),
            "line" => testcase.attributes["line"].to_i
          }
        end
      end

      def mutants(report)
        report.fetch("files").flat_map do |file, details|
          Array(details["mutants"]).map do |mutant|
            {
              "id" => "infection:#{mutant.fetch('id')}",
              "file" => relative(file),
              "kind" => mutant["mutatorName"],
              "line" => mutant.dig("location", "start", "line"),
              "outcome" => mutant.fetch("status").downcase,
              "covered_by" => Array(mutant["coveredBy"]),
              "killed_by" => Array(mutant["killedBy"])
            }
          end
        end
      end

      def relative(path)
        return unless path

        expanded = File.expand_path(path)
        expanded.start_with?("#{@root}/") ? expanded.delete_prefix("#{@root}/") : path
      end
    end
  end
end
