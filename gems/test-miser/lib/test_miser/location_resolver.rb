# frozen_string_literal: true

module TestMiser
  class LocationResolver
    DECLARATION_PREFIXES = %w[test it describe context def fn func function].freeze

    def initialize(root: Dir.pwd)
      @root = File.expand_path(root)
    end

    def call(report)
      tests = report.tests.map { |test| resolve(test) }
      MutationReport.from_records(tests, report.mutants, corpus_metadata: report.corpus_metadata)
    end

    private

    def resolve(test)
      return test if test.line
      return test unless test.file

      path = File.expand_path(test.file, @root)
      return test unless File.file?(path)

      lines = File.readlines(path, chomp: true)
      candidates = name_candidates(test)
      matches = lines.each_index.select do |index|
        line = lines[index]
        candidates.any? { |candidate| token_match?(line, candidate) }
      end
      line = preferred_match(lines, matches)
      Test.new(id: test.id, name: test.name, file: test.file, line: line)
    rescue Errno::ENOENT, Errno::EACCES
      test
    end

    def name_candidates(test)
      values = [test.name, test.id].compact.flat_map do |value|
        leaf = value.to_s.split(/[#:]/).last.to_s
        word = value.to_s.split(/[\s\/]/).last.to_s
        [
          value.to_s,
          leaf,
          word,
          leaf.sub(/\A(?:test|it)[_ ]/, ""),
          word.sub(/\A(?:test|it)[_ ]/, "")
        ]
      end
      values.map { |value| value.gsub(/\A["']|["']\z/, "") }
        .reject { |value| value.length < 3 }
        .uniq
        .sort_by { |value| -value.length }
    end

    def token_match?(line, candidate)
      line.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(candidate)}(?![A-Za-z0-9_])/)
    end

    def preferred_match(lines, matches)
      return nil if matches.empty?
      declaration = matches.find do |index|
        stripped = lines[index].strip
        DECLARATION_PREFIXES.any? { |prefix| stripped.start_with?("#{prefix} ", "#{prefix}(", "#{prefix} \"") }
      end
      (declaration || matches.first) + 1
    end
  end
end
