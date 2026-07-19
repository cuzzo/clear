# frozen_string_literal: true

require "rexml/document"

module TestMiser
  module Adapters
    class Pit
      def initialize(mutations_xml:, test_reports:, root: Dir.pwd, language: "java")
        @mutations_xml = mutations_xml
        @test_reports = test_reports
        @root = File.expand_path(root)
        @language = language
      end

      def call
        document = REXML::Document.new(File.read(@mutations_xml))
        mutation_nodes = document.elements.to_a("mutations/mutation")
        referenced = mutation_nodes.flat_map do |node|
          split_tests(node.elements["killingTests"]&.text) + split_tests(node.elements["coveringTests"]&.text)
        end.uniq
        tests = surefire_tests(referenced)

        {
          "schema" => "mutant-facts/v1",
          "source" => "pitest",
          "language" => @language,
          "mutation_kind" => "stochastic",
          "subjects" => [],
          "tests" => tests,
          "mutants" => mutation_nodes.each_with_index.map { |node, index| mutant(node, index) },
          "test_miser" => {
            "complete" => true,
            "attribution_complete" => document.root.attributes["partial"] == "true",
            "run_to_complete" => document.root.attributes["partial"] == "true"
          }
        }
      rescue REXML::ParseException => error
        raise InvalidReport, "invalid PIT XML: #{error.message}"
      end

      private

      def mutant(node, index)
        klass = text(node, "mutatedClass")
        method = text(node, "mutatedMethod")
        line = text(node, "lineNumber").to_i
        kind = text(node, "mutator").split(".").last
        {
          "id" => "pit:#{klass}:#{method}:#{line}:#{kind}:#{index}",
          "file" => source_file(klass, text(node, "sourceFile")),
          "method" => method,
          "kind" => kind,
          "line" => line,
          "outcome" => text(node, nil, attribute: "status").downcase,
          "covered_by" => split_tests(node.elements["coveringTests"]&.text),
          "killed_by" => split_tests(node.elements["killingTests"]&.text)
        }
      end

      def surefire_tests(referenced)
        Dir.glob(File.join(@test_reports, "TEST-*.xml")).flat_map do |path|
          report = REXML::Document.new(File.read(path))
          report.elements.to_a("testsuite/testcase").map do |testcase|
            classname = testcase.attributes["classname"]
            name = testcase.attributes["name"].to_s.sub(/\(.*\)\z/, "")
            id = referenced.find { |candidate| pit_test?(candidate, classname, name) } ||
              "pit:#{classname}##{name}"
            {
              "id" => id,
              "name" => name,
              "file" => test_file(classname)
            }
          end
        end.uniq { |test| test["id"] }
      end

      def pit_test?(candidate, classname, name)
        candidate.include?(classname) && candidate.include?("method:#{name}(")
      end

      def split_tests(value)
        value.to_s.split("|").reject(&:empty?)
      end

      def source_file(classname, basename)
        directory = @language == "kotlin" ? "src/main/kotlin" : "src/main/java"
        File.join(directory, *classname.split(".")[0...-1], basename)
      end

      def test_file(classname)
        extension = @language == "kotlin" ? ".kt" : ".java"
        directory = @language == "kotlin" ? "src/test/kotlin" : "src/test/java"
        File.join(directory, *classname.split(".")) + extension
      end

      def text(node, child, attribute: nil)
        return node.attributes[attribute].to_s if attribute

        node.elements[child]&.text.to_s
      end
    end
  end
end
