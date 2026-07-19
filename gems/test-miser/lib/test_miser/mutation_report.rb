# frozen_string_literal: true

require "json"
require "set"

module TestMiser
  class InvalidReport < ArgumentError; end

  Test = Struct.new(:id, :name, :file, keyword_init: true) do
    def to_h
      { id: id, name: name, file: file }.compact
    end
  end

  Mutant = Struct.new(:id, :file, :covered_by, :killed_by, keyword_init: true)

  class MutationReport
    attr_reader :tests, :mutants, :corpus_complete, :corpus_metadata

    def self.load_files(paths)
      reports = paths.map do |path|
        new(JSON.parse(File.read(path)), source: path)
      rescue JSON::ParserError => error
        raise InvalidReport, "#{path}: invalid JSON: #{error.message}"
      end
      merge(reports)
    end

    def self.merge(reports)
      tests = {}
      mutants = {}

      reports.each do |report|
        report.tests.each { |test| tests[test.id] ||= test }
        report.mutants.each do |mutant|
          existing = mutants[mutant.id]
          if existing
            existing.covered_by.merge(mutant.covered_by)
            existing.killed_by.merge(mutant.killed_by)
          else
            mutants[mutant.id] = mutant
          end
        end
      end

      metadata = merge_corpus_metadata(reports, mutants.length)
      from_records(tests.values, mutants.values, corpus_metadata: metadata)
    end

    def self.merge_corpus_metadata(reports, mutant_count)
      rows = reports.filter_map(&:corpus_metadata)
      return nil if rows.empty?

      fingerprints = rows.map { |row| row["corpusFingerprint"] }.uniq
      expected = rows.map { |row| row["expectedMutants"] }.uniq
      complete = fingerprints.length == 1 && expected.length == 1 && mutant_count == expected.first
      rows.first.merge("completedMutants" => mutant_count, "complete" => complete)
    end
    private_class_method :merge_corpus_metadata

    def self.from_records(tests, mutants, corpus_metadata: nil)
      allocate.tap do |report|
        report.instance_variable_set(:@tests, tests.sort_by(&:id).freeze)
        report.instance_variable_set(:@mutants, mutants.sort_by(&:id).freeze)
        report.instance_variable_set(:@corpus_metadata, corpus_metadata&.freeze)
        report.instance_variable_set(:@corpus_complete, corpus_metadata && corpus_metadata["complete"] == true)
      end
    end

    def initialize(payload, source: "mutation report")
      unless payload.is_a?(Hash) && payload["files"].is_a?(Hash)
        raise InvalidReport, "#{source}: expected a Mutation Testing Elements report with a files object"
      end

      @tests = parse_tests(payload).sort_by(&:id).freeze
      @mutants = parse_mutants(payload, source).sort_by(&:id).freeze
      @corpus_metadata = payload["testMiser"]&.freeze
      @corpus_complete = @corpus_metadata &&
        @corpus_metadata["complete"] == true &&
        @mutants.length == @corpus_metadata["expectedMutants"]
      add_referenced_tests
      validate_references(source)
    end

    private

    def parse_tests(payload)
      Array(payload["testFiles"]).flat_map do |file, details|
        Array(details && details["tests"]).filter_map do |test|
          id = string(test, "id")
          next unless id

          Test.new(id: id, name: string(test, "name") || id, file: file)
        end
      end
    end

    def parse_mutants(payload, source)
      payload.fetch("files").flat_map do |file, details|
        Array(details && details["mutants"]).map do |mutant|
          local_id = string(mutant, "id")
          raise InvalidReport, "#{source}: mutant in #{file} has no id" unless local_id

          covered_by = string_set(mutant["coveredBy"])
          killed_by = string_set(mutant["killedBy"])
          covered_by.merge(killed_by)
          Mutant.new(
            id: "#{file}:#{local_id}",
            file: file,
            covered_by: covered_by,
            killed_by: killed_by
          )
        end
      end
    end

    def add_referenced_tests
      known = @tests.to_h { |test| [test.id, test] }
      @mutants.each do |mutant|
        (mutant.covered_by | mutant.killed_by).each do |test_id|
          known[test_id] ||= Test.new(id: test_id, name: test_id)
        end
      end
      @tests = known.values.sort_by(&:id).freeze
    end

    def validate_references(source)
      known = @tests.map(&:id).to_set
      @mutants.each do |mutant|
        unknown = (mutant.covered_by | mutant.killed_by) - known
        next if unknown.empty?

        raise InvalidReport, "#{source}: mutant #{mutant.id} references unknown tests: #{unknown.to_a.sort.join(', ')}"
      end
    end

    def string(hash, key)
      value = hash.is_a?(Hash) ? hash[key] : nil
      value.to_s unless value.nil? || value.to_s.empty?
    end

    def string_set(values)
      Array(values).map(&:to_s).reject(&:empty?).to_set
    end
  end
end
