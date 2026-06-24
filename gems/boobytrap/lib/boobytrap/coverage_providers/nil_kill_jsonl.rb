# frozen_string_literal: true

module Boobytrap
  module CoverageProviders
    module NilKillJsonl
      module_function

      def handles_file?(path)
        return false unless ::File.basename(path).start_with?("coverage-") && ::File.extname(path).downcase == ".jsonl"

        # Peek at first line to see if it looks like Nil-kill coverage JSONL
        first_line = ::File.open(path, &:gets)
        return false unless first_line
        obs = JSON.parse(first_line)
        obs.is_a?(Hash) && obs.key?("path") && obs.key?("lines")
      rescue JSON::ParserError, Errno::ENOENT, StandardError
        false
      end

      def load(path, root:)
        files = {}
        ::File.foreach(path) do |line|
          next if line.strip.empty?
          obs = JSON.parse(line)
          source_path = obs["path"]
          next if source_path.to_s.empty?

          abs = ::File.expand_path(source_path, root)
          lines = []
          Array(obs["lines"]).each do |line_num|
            number = line_num.to_i
            lines[number - 1] = 1 if number.positive?
          end

          files[abs] = CoverageData::FileCoverage.new(
            file: abs,
            lines: lines,
            branches: {},
            branch_arms: [],
            source_path: CoverageData.relpath(abs, root),
            language: CoverageData.language_for(abs),
            format: :nil_kill_jsonl
          )
        end
        CoverageData::Dataset.new(path: path, files: files)
      end
    end
  end
end

Boobytrap::CoverageProviders.register(Boobytrap::CoverageProviders::NilKillJsonl)
