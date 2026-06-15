# frozen_string_literal: true

module Boobytrap
  module CoverageProviders
    module Python
      module_function

      def language
        "python"
      end

      def capability
        CoverageProviders::Capability.new(
          language: language,
          line_coverage: true,
          branch_coverage: true,
          native_branch_coverage: true,
          notes: "coverage.py JSON branch arcs are mapped to Tree-sitter branch arms."
        )
      end

      def handles_file?(path)
        return false unless ::File.extname(path).downcase == ".json"

        coverage_py_json?(JSON.parse(::File.read(path)))
      rescue JSON::ParserError, Errno::ENOENT
        false
      end

      def load(path, root:)
        data = JSON.parse(::File.read(path))
        files = {}
        data.fetch("files", {}).each do |source_path, entry|
          next unless entry.is_a?(Hash)

          abs = CoverageData.normalize_file(source_path, root: root, source_roots: [::File.dirname(path)])
          next unless ::File.file?(abs)
          next unless CoverageData.language_for(abs) == language

          lines = normalize_lines(entry)
          branch_arms = native_branch_arms(abs, entry, root: root)
          files[abs] = CoverageData::FileCoverage.new(
            file: abs,
            lines: lines,
            branches: {},
            branch_arms: branch_arms,
            source_path: CoverageData.relpath(abs, root),
            language: language,
            format: :coverage_py
          )
        end
        CoverageData::Dataset.new(path: path, files: files)
      end

      def coverage_py_json?(data)
        return false unless data.is_a?(Hash)
        return false unless data["files"].is_a?(Hash)

        meta = data["meta"]
        return true if meta.is_a?(Hash) && meta.key?("branch_coverage")

        data["files"].values.any? do |entry|
          entry.is_a?(Hash) &&
            (entry.key?("executed_lines") ||
             entry.key?("executed_branches") ||
             entry.key?("missing_branches"))
        end
      end

      def normalize_lines(entry)
        lines = []
        Array(entry["executed_lines"]).each do |line|
          number = line.to_i
          lines[number - 1] = 1 if number.positive?
        end
        Array(entry["missing_lines"]).each do |line|
          number = line.to_i
          next unless number.positive?

          lines[number - 1] = 0 if lines[number - 1].nil?
        end
        lines
      end

      def native_branch_arms(abs, entry, root:)
        executed = normalize_arcs(entry["executed_branches"])
        missing = normalize_arcs(entry["missing_branches"])
        return [] if executed.empty? && missing.empty?
        return [] unless CoverageData.load_decomplex_syntax

        catalog = CoverageData.branch_catalog_file(abs, root: root)
        catalog.fetch("arms", []).filter_map do |arm|
          hits = arm_hits(arm, executed, missing)
          next if hits.nil?

          CoverageData.normalize_native_branch_arm(arm.merge("hits" => hits))
        end
      rescue LoadError, StandardError
        []
      end

      def normalize_arcs(value)
        Array(value).filter_map do |arc|
          pair = Array(arc).map(&:to_i)
          next unless pair.size == 2
          next unless pair[0].positive? && pair[1].positive?

          pair
        end
      end

      def arm_hits(arm, executed, missing)
        decision_line = arm["decision_line"].to_i
        span = Array(arm["arm_span"]).map(&:to_i)
        matching_executed = executed.any? do |source, destination|
          source == decision_line && line_in_span?(destination, span)
        end
        return 1 if matching_executed

        matching_missing = missing.any? do |source, destination|
          source == decision_line && line_in_span?(destination, span)
        end
        matching_missing ? 0 : nil
      end

      def line_in_span?(line, span)
        return false unless span.size == 4

        first = span[0]
        last = span[2]
        line >= first && line <= last
      end
    end
  end
end

Boobytrap::CoverageProviders.register(Boobytrap::CoverageProviders::Python)
Boobytrap::CoverageProviders.register_language(Boobytrap::CoverageProviders::Python)
