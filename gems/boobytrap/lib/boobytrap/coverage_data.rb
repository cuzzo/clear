# frozen_string_literal: true

require "digest"
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
  # - Nil-Kill branch coverage JSON: language-neutral Tree-sitter branch
  #   arm hit counts keyed by source spans / branch arm ids.
  #
  # kcov does not provide SimpleCov's Ruby branch tuple shape. Consumers
  # that need branch semantics can pass Tree-sitter branch arms to
  # branch_arm_coverage. If the input provides native arm hits, those
  # are used directly; otherwise this layer falls back to line-hit
  # inference.
  module CoverageData
    FileCoverage = Struct.new(:file, :lines, :branches, :format, :branch_arms,
                              :source_path, :language,
                              keyword_init: true) do
      def line_coverage?
        lines.any? { |hit| !hit.nil? }
      end

      def branch_coverage?
        !branches.empty?
      end

      def branch_arm_coverage?
        !branch_arms.to_a.empty?
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
    NativeBranchArm = Struct.new(:branch_id, :arm_id, :kind, :member,
                                 :decision_span, :arm_span, :hits,
                                 keyword_init: true)

    module_function

    def load(path, root:)
      resolved, provider = CoverageProviders.resolve(path, root: root)
      return empty_dataset(path) unless resolved && provider && ::File.file?(resolved)

      root = ::File.expand_path(root)
      cache_key = [realish_path(resolved), root]
      cache[cache_key] ||= provider.load(resolved, root: root)
    end

    def empty_dataset(path)
      Dataset.new(path: path, files: {})
    end

    def resolve(path)
      CoverageProviders.resolve(path, root: Dir.pwd).first
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
      when :nil_kill_branch then "Nil-Kill branch coverage"
      when :coverage_py then "coverage.py JSON"
      else format.to_s
      end
    end

    def branch_source(format)
      case format
      when :nil_kill_branch then :native_branch
      when :coverage_py then :coverage_py
      when :kcov_cobertura, :kcov_codecov then :kcov
      when :simplecov then :coverage
      else format
      end
    end

    def branch_catalog(files, root:)
      return empty_branch_catalog(root) unless load_decomplex_syntax

      root = ::File.expand_path(root)
      entries = Array(files).filter_map do |file|
        abs = ::File.expand_path(file.to_s.start_with?("/") ? file : ::File.join(root, file))
        next unless ::File.file?(abs)

        branch_catalog_file(abs, root: root)
      end
      empty_branch_catalog(root).merge("files" => entries)
    end

    def branch_catalog_file(file, root:)
      doc = Decomplex::Syntax.parse(file, parser: "tree_sitter")
      rel = relpath(file, root)
      language = doc.language.to_s
      {
        "path" => rel,
        "language" => language,
        "digest" => "sha256:#{Digest::SHA256.file(file).hexdigest}",
        "arms" => doc.branch_arms.map { |arm| branch_catalog_arm(rel, language, arm) }
      }
    end

    def branch_catalog_arm(path, language, arm)
      branch_id = branch_id(path: path, language: language, arm: arm)
      {
        "branch_id" => branch_id,
        "arm_id" => arm_id(branch_id: branch_id, arm: arm),
        "kind" => arm.kind.to_s,
        "label" => arm.member.to_s,
        "decision_line" => arm.decision_line,
        "decision_span" => arm.decision_span,
        "arm_line" => arm.line,
        "arm_span" => arm.span
      }
    end

    def empty_branch_catalog(root)
      {
        "schema_version" => 1,
        "format" => "nil-kill.branch-catalog",
        "root" => ::File.expand_path(root),
        "files" => []
      }
    end

    def branch_id(path:, language:, arm:)
      [
        language.to_s,
        path.to_s,
        span_key(arm.decision_span),
        arm.kind
      ].join("\0")
    end

    def arm_id(branch_id:, arm:)
      [
        branch_id,
        arm.member,
        span_key(arm.span)
      ].join("\0")
    end

    def branch_arm_coverage(file_coverage, branch_arms)
      if file_coverage&.branch_arm_coverage?
        return native_branch_arm_coverage(file_coverage, branch_arms)
      end
      if file_coverage&.branch_coverage?
        return tuple_branch_arm_coverage(file_coverage, branch_arms)
      end

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

    def tuple_branch_arm_coverage(file_coverage, branch_arms)
      file_coverage.branches.flat_map do |parent_key, arms|
        parent = coverage_tuple(parent_key)
        arms.flat_map do |arm_key, hits|
          tuple = coverage_tuple(arm_key)
          next [] unless tuple

          matching_branch_arms(branch_arms, parent, tuple).map do |arm|
            ArmCoverage.new(
              arm: arm,
              covered: hits.to_i.positive?,
              hits: hits.to_i,
              executable_lines: [arm.line],
              source: branch_source(file_coverage.format)
            )
          end
        end
      end
    end

    def matching_branch_arms(branch_arms, parent, tuple)
      parent_arms = branch_arms_for_parent(branch_arms, parent)
      candidates = parent_arms
      candidates = candidates.select { |arm| same_span?(arm.span, tuple[:span]) }
      if candidates.empty?
        candidates = parent_arms.select { |arm| span_contains?(arm.span, tuple[:span]) }
      end
      if candidates.empty?
        candidates = parent_arms.select do |arm|
          arm.line.to_i == tuple[:span][0] && arm.member.to_s == tuple[:kind].to_s
        end
      end
      candidates = candidates.select { |arm| branch_parent_matches_decision?(arm, parent) } if parent
      candidates
    end

    def branch_arms_for_parent(branch_arms, parent)
      return branch_arms unless parent

      branch_arms.select { |arm| branch_kind_compatible?(arm.kind, parent[:kind]) }
    end

    def branch_kind_compatible?(arm_kind, parent_kind)
      arm_kind = arm_kind.to_s
      parent_kind = parent_kind.to_s
      case arm_kind
      when "if"
        %w[if unless].include?(parent_kind)
      when "case"
        parent_kind == "case"
      when "loop"
        %w[while until for].include?(parent_kind)
      else
        arm_kind == parent_kind
      end
    end

    def branch_parent_matches_decision?(arm, parent)
      decision_span = parent[:span]
      same_span?(arm.decision_span, decision_span)
    end

    def coverage_tuple(value)
      fields = value.to_s.gsub(/[\[\]\":]/, "").split(",").map(&:strip)
      return nil if fields.size < 6

      {
        kind: fields[0].delete_prefix(":"),
        id: fields[1],
        span: fields[-4, 4].map(&:to_i)
      }
    end

    def same_span?(left, right)
      Array(left).map(&:to_i) == Array(right).map(&:to_i)
    end

    def span_contains?(outer, inner)
      outer = Array(outer).map(&:to_i)
      inner = Array(inner).map(&:to_i)
      return false unless outer.size == 4 && inner.size == 4

      starts_before = outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1])
      ends_after = outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3])
      starts_before && ends_after
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

    def native_branch_arm_coverage(file_coverage, branch_arms)
      index = native_branch_arm_index(file_coverage)
      branch_arms.filter_map do |arm|
        native = index[native_arm_signature(arm)] ||
                 index[static_arm_id(file_coverage, arm)]
        next unless native

        ArmCoverage.new(
          arm: arm,
          covered: native.hits.to_i.positive?,
          hits: native.hits.to_i,
          executable_lines: [arm.line],
          source: branch_source(file_coverage.format)
        )
      end
    end

    def native_branch_arm_index(file_coverage)
      file_coverage.branch_arms.each_with_object({}) do |native, index|
        index[native_arm_signature(native)] = native
        index[native.arm_id] = native unless native.arm_id.to_s.empty?
      end
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
      elsif nil_kill_branch_coverage?(data)
        load_nil_kill_branch_coverage(path, data, root: root)
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

    def nil_kill_branch_coverage?(data)
      data.is_a?(Hash) &&
        data["format"].to_s == "nil-kill.branch-coverage" &&
        data["files"].is_a?(Array)
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
            branch_arms: [],
            source_path: CoverageData.relpath(abs, root),
            language: language_for(abs),
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
          branch_arms: [],
          source_path: CoverageData.relpath(abs, root),
          language: language_for(abs),
          format: :kcov_cobertura
        )
      end
      Dataset.new(path: path, files: files)
    end

    def load_nil_kill_branch_coverage(path, data, root:)
      coverage_root = data["root"].to_s.empty? ? root : ::File.expand_path(data["root"])
      files = {}
      Array(data["files"]).each do |entry|
        rel = (entry["path"] || entry["file"] || entry["filename"]).to_s
        next if rel.empty?

        abs = normalize_file(rel, root: root, source_roots: [coverage_root])
        native_arms = Array(entry["arms"] || entry["branch_arms"]).filter_map do |arm|
          normalize_native_branch_arm(arm)
        end
        next if native_arms.empty?

        files[abs] = FileCoverage.new(
          file: abs,
          lines: normalize_native_lines(entry["lines"]),
          branches: {},
          branch_arms: native_arms,
          source_path: rel,
          language: (entry["language"] || language_for(abs)).to_s,
          format: :nil_kill_branch
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
          branch_arms: [],
          source_path: CoverageData.relpath(abs, root),
          language: language_for(abs),
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
      candidates.concat(CoverageProviders.path_candidates(
                          file,
                          root: root,
                          source_roots: source_roots,
                          summary: summary
                        ))
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

    def normalize_native_lines(value)
      case value
      when Array
        value.map { |hit| hit.nil? ? nil : normalized_hit_count(hit) }
      when Hash
        lines = []
        value.each do |line, hit|
          number = line.to_i
          next unless number.positive?

          lines[number - 1] = normalized_hit_count(hit)
        end
        lines
      else
        []
      end
    end

    def normalize_native_branch_arm(arm)
      return nil unless arm.is_a?(Hash)

      arm_span = normalize_span(arm["arm_span"] || arm["span"])
      decision_span = normalize_span(arm["decision_span"])
      return nil unless arm_span && decision_span

      NativeBranchArm.new(
        branch_id: arm["branch_id"].to_s,
        arm_id: arm["arm_id"].to_s,
        kind: (arm["kind"] || "branch").to_s,
        member: (arm["member"] || arm["label"] || arm["arm"]).to_s,
        decision_span: decision_span,
        arm_span: arm_span,
        hits: normalized_hit_count(arm["hits"] || arm["count"] || arm["sample_count"])
      )
    end

    def normalize_span(value)
      span = Array(value).map(&:to_i)
      return nil unless span.size == 4
      return nil unless span[0].positive? && span[2] >= span[0]

      span
    end

    def native_arm_signature(arm)
      [
        arm.kind.to_s,
        (arm.respond_to?(:member) ? arm.member : nil).to_s,
        Array(arm.decision_span).map(&:to_i),
        Array(arm.respond_to?(:arm_span) ? arm.arm_span : arm.span).map(&:to_i)
      ]
    end

    def static_arm_id(file_coverage, arm)
      rel = file_coverage.source_path.to_s
      rel = ::File.basename(file_coverage.file) if rel.empty?
      branch_id = branch_id(
        path: rel,
        language: file_coverage.language.to_s.empty? ? arm_language(arm) : file_coverage.language,
        arm: arm
      )
      arm_id(branch_id: branch_id, arm: arm)
    end

    def arm_language(arm)
      case ::File.extname(arm.file.to_s).downcase
      when ".zig" then "zig"
      when ".py" then "python"
      when ".js", ".jsx", ".mjs", ".cjs" then "javascript"
      when ".ts", ".tsx" then "typescript"
      when ".go" then "go"
      when ".rs" then "rust"
      when ".rb" then "ruby"
      else "unknown"
      end
    end

    def language_for(file)
      case ::File.extname(file.to_s).downcase
      when ".zig" then "zig"
      when ".py" then "python"
      when ".js", ".jsx", ".mjs", ".cjs" then "javascript"
      when ".ts", ".tsx" then "typescript"
      when ".go" then "go"
      when ".rs" then "rust"
      when ".rb" then "ruby"
      else "unknown"
      end
    end

    def span_key(span)
      Array(span).map(&:to_i).join(":")
    end

    def realish_path(path)
      ::File.realpath(path)
    rescue Errno::ENOENT
      ::File.expand_path(path)
    end

    def cache
      @cache ||= {}
    end

    def load_decomplex_syntax
      return true if defined?(Decomplex::Syntax)

      require "decomplex/syntax"
      true
    rescue LoadError
      sibling = ::File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
      return false unless ::File.file?("#{sibling}.rb")

      require sibling
      true
    end
  end
end

require_relative "coverage_providers"
