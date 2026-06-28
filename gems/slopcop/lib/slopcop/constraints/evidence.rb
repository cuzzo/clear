# frozen_string_literal: true

require_relative "../coverage_data"

module SlopCop
  module Constraints
    class Evidence
      def self.from_specs(specs, repo:)
        new(repo: repo).tap do |evidence|
          Array(specs).each do |spec|
            type, path = spec.to_s.split(":", 2)
            next if type.to_s.empty? || path.to_s.empty?

            evidence.add(type, path)
          end
        end
      end

      attr_reader :repo

      def initialize(repo:)
        @repo = File.expand_path(repo)
        @datasets = Hash.new { |hash, key| hash[key] = [] }
      end

      def add(type, path)
        resolved = File.expand_path(path, repo)
        dataset = SlopCop::CoverageData.load(resolved, root: repo)
        @datasets[type.to_s] << dataset unless dataset.empty?
      end

      def known_type?(type)
        @datasets.key?(type.to_s) && @datasets[type.to_s].any?
      end

      def line_hits(type, path, line)
        coverages_for(type, path).filter_map { |coverage| coverage.line_hits(line) }.sum
      end

      def line_known?(type, path, line)
        coverages_for(type, path).any? { |coverage| coverage.line_known?(line) }
      end

      def line_covered?(type, path, line)
        coverages_for(type, path).any? { |coverage| coverage.line_hits(line).to_i.positive? }
      end

      def first_instrumented_line_at_or_after(type, path, line)
        coverages_for(type, path)
          .flat_map { |coverage| known_lines(coverage) }
          .select { |known| known >= line.to_i }
          .min
      end

      def line_hit_map(type, path)
        coverages_for(type, path).each_with_object({}) do |coverage, out|
          coverage.lines.each_with_index do |hits, index|
            next if hits.nil?

            line = index + 1
            out[line] = out.fetch(line, 0) + hits.to_i
          end
        end
      end

      private

      def coverages_for(type, path)
        abs = File.expand_path(path, repo)
        rel = path.to_s.delete_prefix("./")
        @datasets[type.to_s].filter_map do |dataset|
          dataset[abs] || dataset.files.values.find do |coverage|
            source = coverage.source_path.to_s.delete_prefix("./")
            coverage.file == abs ||
              source == rel ||
              source == rel.delete_prefix("zig/") ||
              source.end_with?("/#{rel}") ||
              rel.end_with?("/#{source}")
          end
        end
      end

      def known_lines(coverage)
        coverage.lines.each_index.select { |index| !coverage.lines[index].nil? }.map { |index| index + 1 }
      end
    end
  end
end
