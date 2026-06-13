# frozen_string_literal: true

require "json"
require "rexml/document"
require "rexml/xpath"

module Boobytrap
  # Normalized coverage input for Boobytrap and SlopCop.
  #
  # Supported inputs:
  # - SimpleCov .resultset.json: line hits plus Ruby branch tuples.
  # - kcov Cobertura XML: line hits, including zero-hit executable lines.
  # - kcov codecov.json: line hits keyed by source-relative path.
  #
  # kcov does not provide SimpleCov's Ruby branch tuple shape. Consumers
  # that need branch semantics can pass Tree-sitter branch arms to
  # branch_arm_coverage; this layer owns the line-hit interpretation.
  module CoverageData
    FileCoverage = Struct.new(:file, :lines, :branches, :format, keyword_init: true) do
      def line_coverage?
        lines.any? { |hit| !hit.nil? }
      end

      def branch_coverage?
        !branches.empty?
      end

      def line_known?(line)
        line.to_i.positive? && !lines[line.to_i - 1].nil?
      end

      def line_hits(line)
        return nil unless line.to_i.positive?

        lines[line.to_i - 1]
      end
    end

    Dataset = Struct.new(:path, :files, keyword_init: true) do
      def empty?
        files.empty?
      end

      def [](file)
        files[::File.expand_path(file)]
      end

      def formats
        files.values.map(&:format).uniq
      end

      def label
        labels = formats.map { |format| CoverageData.format_label(format) }.uniq
        labels.empty? ? "coverage" : labels.join(" + ")
      end

      def covered_files(root:)
        files.keys.filter_map do |abs|
          next unless ::File.file?(abs)

          CoverageData.relpath(abs, root)
        end
      end
    end

    ArmCoverage = Struct.new(:arm, :covered, :hits, :executable_lines, :source,
                             keyword_init: true)

    module_function

    def load(path, root:)
      resolved = resolve(path)
      return Dataset.new(path: path, files: {}) unless resolved && ::File.file?(resolved)

      root = ::File.expand_path(root)
      cache_key = [realish_path(resolved), root]
      cache[cache_key] ||= load_uncached(resolved, root: root)
    end

    def resolve(path)
      return nil if path.nil? || path.to_s.empty?

      expanded = ::File.expand_path(path)
      return expanded unless ::File.directory?(expanded)

      candidates = [
        "merged/kcov-merged/cobertura.xml",
        "kcov-merged/cobertura.xml",
        "cobertura.xml",
        "cov.xml",
        "merged/kcov-merged/codecov.json",
        "kcov-merged/codecov.json",
        "codecov.json"
      ]
      candidates.map { |rel| ::File.join(expanded, rel) }.find { |candidate| ::File.file?(candidate) } ||
        Dir[::File.join(expanded, "**", "kcov-merged", "cobertura.xml")].sort.first ||
        Dir[::File.join(expanded, "**", "cobertura.xml")].sort.first ||
        Dir[::File.join(expanded, "**", "codecov.json")].sort.first
    end

    def relpath(abs, root)
      rootp = ::File.expand_path(root).chomp("/") + "/"
      path = ::File.expand_path(abs)
      path.start_with?(rootp) ? path[rootp.length..] : path
    end

    def format_label(format)
      case format
      when :simplecov then "SimpleCov"
      when :kcov_cobertura then "kcov Cobertura"
      when :kcov_codecov then "kcov codecov"
      else format.to_s
      end
    end

    def branch_source(format)
      case format
      when :kcov_cobertura, :kcov_codecov then :kcov
      when :simplecov then :coverage
      else format
      end
    end

    def branch_arm_coverage(file_coverage, branch_arms)
      return [] unless file_coverage&.line_coverage?

      branch_arms.filter_map do |arm|
        executable = executable_lines_in_span(file_coverage, arm.span)
        executable = [arm.line] if executable.empty? && file_coverage.line_known?(arm.line)
        next if executable.empty?

        hits = executable.sum { |line| file_coverage.line_hits(line).to_i }
        ArmCoverage.new(
          arm: arm,
          covered: hits.positive?,
          hits: hits,
          executable_lines: executable,
          source: branch_source(file_coverage.format)
        )
      end
    end

    def dark_branch_misses_by_line(file_coverage, branch_arms)
      branch_arm_coverage(file_coverage, branch_arms).each_with_object(Hash.new(0)) do |arm_cov, out|
        next if arm_cov.covered

        out[arm_cov.arm.line] += 1
      end
    end

    def executable_lines_in_span(file_coverage, span)
      first = span[0].to_i
      last = span[2].to_i
      return [] unless first.positive? && last >= first

      (first..last).select { |line| file_coverage.line_known?(line) }
    end

    def load_uncached(path, root:)
      case ::File.extname(path).downcase
      when ".xml"
        load_cobertura(path, root: root)
      when ".json"
        load_json(path, root: root)
      else
        Dataset.new(path: path, files: {})
      end
    rescue JSON::ParserError, REXML::ParseException, Errno::ENOENT
      Dataset.new(path: path, files: {})
    end

    def load_json(path, root:)
      data = JSON.parse(::File.read(path))
      if simplecov_resultset?(data)
        load_simplecov(path, data, root: root)
      elsif kcov_codecov?(data)
        load_kcov_codecov(path, data, root: root)
      else
        Dataset.new(path: path, files: {})
      end
    end

    def simplecov_resultset?(data)
      data.is_a?(Hash) &&
        data.values.any? { |entry| entry.is_a?(Hash) && entry["coverage"].is_a?(Hash) }
    end

    def kcov_codecov?(data)
      data.is_a?(Hash) &&
        data["coverage"].is_a?(Hash) &&
        data["coverage"].values.all? { |lines| lines.is_a?(Hash) }
    end

    def load_simplecov(path, data, root:)
      files = {}
      data.each_value do |entry|
        (entry["coverage"] || {}).each do |file, cov|
          next unless cov.is_a?(Hash)

          abs = normalize_file(file, root: root, source_roots: [])
          dst = (files[abs] ||= FileCoverage.new(
            file: abs,
            lines: [],
            branches: {},
            format: :simplecov
          ))
          merge_lines!(dst.lines, cov["lines"] || [])
          merge_branches!(dst.branches, cov["branches"] || {})
        end
      end
      Dataset.new(path: path, files: files)
    end

    def load_cobertura(path, root:)
      doc = REXML::Document.new(::File.read(path))
      source_roots = REXML::XPath.match(doc, "//source").filter_map do |node|
        text = node.text.to_s.strip
        text.empty? ? nil : ::File.expand_path(text)
      end
      files = {}
      REXML::XPath.each(doc, "//class") do |klass|
        filename = klass.attributes["filename"].to_s
        next if filename.empty?

        abs = normalize_file(filename, root: root, source_roots: source_roots)
        lines = []
        REXML::XPath.each(klass, "lines/line") do |line|
          number = line.attributes["number"].to_i
          next unless number.positive?

          lines[number - 1] = line.attributes["hits"].to_i
        end
        next unless lines.any? { |hit| !hit.nil? }

        files[abs] = FileCoverage.new(
          file: abs,
          lines: lines,
          branches: {},
          format: :kcov_cobertura
        )
      end
      Dataset.new(path: path, files: files)
    end

    def load_kcov_codecov(path, data, root:)
      summary = summary_path_map(path, root: root)
      files = {}
      data.fetch("coverage", {}).each do |file, line_hits|
        abs = normalize_file(file, root: root, source_roots: [], summary: summary)
        lines = []
        line_hits.each do |line, hits|
          number = line.to_i
          next unless number.positive?

          lines[number - 1] = normalized_hit_count(hits)
        end
        next unless lines.any? { |hit| !hit.nil? }

        files[abs] = FileCoverage.new(
          file: abs,
          lines: lines,
          branches: {},
          format: :kcov_codecov
        )
      end
      Dataset.new(path: path, files: files)
    end

    def summary_path_map(path, root:)
      summary = ::File.join(::File.dirname(path), "coverage.json")
      return {} unless ::File.file?(summary)

      data = JSON.parse(::File.read(summary))
      files = data.fetch("files", []).filter_map do |entry|
        file = entry["file"].to_s
        file.empty? ? nil : ::File.expand_path(file)
      end
      files.each_with_object({}) do |abs, out|
        next unless ::File.file?(abs)

        rel = relpath(abs, root)
        parts = rel.split("/")
        parts.each_index do |idx|
          suffix = parts[idx..].join("/")
          out[suffix] ||= abs
        end
      end
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def normalize_file(file, root:, source_roots:, summary: {})
      return summary[file] if summary[file]

      expanded = ::File.expand_path(file)
      return expanded if file.start_with?("/") && ::File.file?(expanded)

      candidates = []
      source_roots.each { |source_root| candidates << ::File.expand_path(file, source_root) }
      candidates << ::File.expand_path(file, root)
      candidates << ::File.expand_path(::File.join("zig", file), root)
      found = candidates.find { |candidate| ::File.file?(candidate) }
      return found if found

      source_roots.empty? ? ::File.expand_path(file, root) : ::File.expand_path(file, source_roots.first)
    end

    def merge_lines!(dst, src)
      src.each_with_index do |hit, index|
        next if hit.nil?

        dst[index] = 0 if dst[index].nil?
        dst[index] += hit.to_i
      end
    end

    def merge_branches!(dst, src)
      src.each do |parent, arms|
        target = (dst[parent] ||= Hash.new(0))
        arms.each { |arm, hits| target[arm] += hits.to_i }
      end
    end

    def normalized_hit_count(value)
      if value.is_a?(Array)
        value.first.to_i
      else
        value.to_i
      end
    end

    def realish_path(path)
      ::File.realpath(path)
    rescue Errno::ENOENT
      ::File.expand_path(path)
    end

    def cache
      @cache ||= {}
    end
  end
end
