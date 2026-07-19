# frozen_string_literal: true

require "set"

module TestMiser
  TestResult = Struct.new(:test, :covered_mutants, :killed_mutants, keyword_init: true) do
    def to_h
      test.to_h.merge(
        covered_mutant_count: covered_mutants.length,
        killed_mutant_count: killed_mutants.length,
        killed_mutants: killed_mutants.to_a.sort
      )
    end
  end

  RedundantGroup = Struct.new(:tests, :killed_mutants, keyword_init: true) do
    def to_h
      {
        tests: tests.map(&:to_h),
        test_count: tests.length,
        mutant_count: killed_mutants.length,
        killed_mutants: killed_mutants.to_a.sort
      }
    end
  end

  Analysis = Struct.new(
    :test_results, :zero_kill_tests, :redundant_groups, :mutant_count, :corpus_complete,
    keyword_init: true
  ) do
    def to_h
      {
        schema: "test-miser/v1",
        summary: {
          tests: test_results.length,
          mutants: mutant_count,
          corpus_complete: corpus_complete,
          tests_that_kill_no_mutants: zero_kill_tests.length,
          possibly_redundant_groups: redundant_groups.length,
          tests_in_possibly_redundant_groups: redundant_groups.sum { |group| group.tests.length }
        },
        tests_that_kill_no_mutants: zero_kill_tests.map(&:to_h),
        possibly_redundant_groups: redundant_groups.map(&:to_h)
      }
    end
  end

  class Analyzer
    def initialize(report)
      @report = report
    end

    def analyze
      results = @report.tests.map { |test| result_for(test) }
      if @report.corpus_complete == false
        zero_kill = []
        groups = []
      else
        zero_kill = results.select { |result| result.killed_mutants.empty? }
          .sort_by { |result| [-result.covered_mutants.length, result.test.id] }
        groups = redundant_groups(results)
      end

      Analysis.new(
        test_results: results.freeze,
        zero_kill_tests: zero_kill.freeze,
        redundant_groups: groups.freeze,
        mutant_count: @report.mutants.length,
        corpus_complete: @report.corpus_complete
      )
    end

    private

    def result_for(test)
      covered = Set.new
      killed = Set.new
      @report.mutants.each do |mutant|
        covered.add(mutant.id) if mutant.covered_by.include?(test.id)
        killed.add(mutant.id) if mutant.killed_by.include?(test.id)
      end
      TestResult.new(test: test, covered_mutants: covered.freeze, killed_mutants: killed.freeze)
    end

    def redundant_groups(results)
      results.reject { |result| result.killed_mutants.empty? }
        .group_by { |result| result.killed_mutants.to_a.sort }
        .values
        .select { |group| group.length > 1 }
        .map do |group|
          RedundantGroup.new(
            tests: group.map(&:test).sort_by(&:id).freeze,
            killed_mutants: group.first.killed_mutants
          )
        end
        .sort_by { |group| [-group.tests.length, -group.killed_mutants.length, group.tests.first.id] }
    end
  end
end
