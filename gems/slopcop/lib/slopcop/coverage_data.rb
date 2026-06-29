# frozen_string_literal: true

require "digest"
require "json"
require "rexml/document"
require "rexml/xpath"

module SlopCop
  # Normalized coverage input for Boobytrap and SlopCop.
  #
  # Supported inputs:
  # - SimpleCov .resultset.json: line hits plus Ruby branch tuples.
  # - kcov Cobertura XML: line hits, including zero-hit executable lines.
  # - kcov codecov.json: line hits keyed by source-relative path.
  # - Nil-Kill branch coverage JSON: language-neutral Tree-sitter branch
  #   arm hit counts keyed by source spans / branch arm ids.
  #
  # kcov does not provide source branch-arm hit counts. Line-only coverage
  # remains useful for line gaps, but it is not treated as branch coverage.
  # Consumers that need branch semantics must provide SimpleCov tuples,
  # coverage.py branch arcs, or Nil-Kill's native branch coverage JSON.
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
      paths = coverage_paths(path)
      return empty_dataset(path) if paths.empty?
      return load_one(paths.first, root: root) if paths.size == 1

      root = ::File.expand_path(root)
      cache_key = [:multi, paths.map { |entry| realish_path(entry) }, root]
      cache[cache_key] ||= merge_datasets(path, paths.map { |entry| load_one(entry, root: root) })
    end

    def coverage_paths(path)
      Array(path).flat_map do |entry|
        entry.to_s.split(::File::PATH_SEPARATOR)
      end.map(&:strip).reject(&:empty?).uniq
    end

    def load_one(path, root:)
      root = ::File.expand_path(root)
      resolved = resolve_path(path)
      return empty_dataset(path) unless resolved && ::File.file?(resolved)

      cache_key = [realish_path(resolved), root]
      cache[cache_key] ||= load_uncached(resolved, root: root)
    end

    def empty_dataset(path)
      Dataset.new(path: path, files: {})
    end

    def merge_datasets(path, datasets)
      files = {}
      datasets.each do |dataset|
        dataset.files.each do |abs, coverage|
          if (existing = files[abs])
            merge_file_coverage!(existing, coverage)
          else
            files[abs] = dup_file_coverage(coverage)
          end
        end
      end
      Dataset.new(path: path, files: files)
    end

    def dup_file_coverage(coverage)
      FileCoverage.new(
        file: coverage.file,
        lines: coverage.lines.dup,
        branches: coverage.branches.to_h { |key, value| [key, value.dup] },
        format: coverage.format,
        branch_arms: coverage.branch_arms.map(&:dup),
        source_path: coverage.source_path,
        language: coverage.language
      )
    end

    def merge_file_coverage!(target, source)
      merge_lines!(target.lines, source.lines)
      merge_branches!(target.branches, source.branches)
      merge_native_branch_arms!(target.branch_arms, source.branch_arms)
      target.format = target.format == source.format ? target.format : :multi
      target.language = source.language if target.language.to_s.empty?
      target.source_path = source.source_path if target.source_path.to_s.empty?
      target
    end

    def merge_native_branch_arms!(target, source)
      index = target.each_with_object({}) do |arm, out|
        out[native_arm_signature(arm)] = arm
        out[arm.arm_id] = arm unless arm.arm_id.to_s.empty?
      end
      source.each do |arm|
        existing = index[native_arm_signature(arm)] || index[arm.arm_id]
        if existing
          existing.hits = existing.hits.to_i + arm.hits.to_i
        else
          copy = arm.dup
          target << copy
          index[native_arm_signature(copy)] = copy
          index[copy.arm_id] = copy unless copy.arm_id.to_s.empty?
        end
      end
    end

    def resolve(path)
      resolve_path(path)
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
      when :multi then "merged coverage"
      else format.to_s
      end
    end

    def branch_source(format)
      case format
      when :nil_kill_branch then :native_branch
      when :coverage_py then :coverage_py
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
      if file_coverage&.line_coverage?
        return line_branch_arm_coverage(file_coverage, branch_arms)
      end

      []
    end

    def line_branch_arm_coverage(file_coverage, branch_arms)
      branch_arms.map do |arm|
        start_line = arm.span[0]
        end_line = arm.span[2]
        hits_in_span = (start_line..end_line).map { |line| file_coverage.line_hits(line) }.compact
        
        covered = if hits_in_span.any? { |hits| hits.positive? }
                    true
                  elsif hits_in_span.empty?
                    declared_hits = file_coverage.line_hits(arm.line)
                    declared_hits.nil? || declared_hits.positive?
                  else
                    false
                  end
        
        max_hits = hits_in_span.max || 0
        ArmCoverage.new(
          arm: arm,
          covered: covered,
          hits: max_hits,
          executable_lines: (start_line..end_line).to_a,
          source: :tree_sitter_static
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

    def load_uncached(resolved, root:)
      begin
        data = JSON.parse(::File.read(resolved))
        if data.is_a?(Hash)
          if data.key?("coverage") && data["coverage"].is_a?(Hash) && data["coverage"]["files"].is_a?(Hash)
            return load_from_boobytrap_json(data["coverage"], path: resolved, root: root)
          elsif data.key?("files") && data["files"].is_a?(Hash)
            return load_from_boobytrap_json(data, path: resolved, root: root)
          end
        end
      rescue JSON::ParserError, Errno::ENOENT
      end

      require "open3"
      require "shellwords"
      bin = ::File.expand_path("../../../boobytrap/exe/boobytrap", __FILE__)
      bin = "boobytrap" unless ::File.exist?(bin)

      cmd = [bin, "--repo", root, "--coverage", resolved, "--parse-coverage-only"]
      stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        warn "boobytrap failed to parse coverage: #{stderr}"
        return empty_dataset(resolved)
      end

      begin
        cov_data = JSON.parse(stdout)
        load_from_boobytrap_json(cov_data, path: resolved, root: root)
      rescue JSON::ParserError
        warn "failed to parse boobytrap output JSON"
        empty_dataset(resolved)
      end
    end

    def load_from_boobytrap_json(data, path:, root:)
      files = {}
      (data["files"] || {}).each do |abs, cov|
        next unless cov.is_a?(Hash)

        branch_arms = Array(cov["branch_arms"]).map do |arm|
          NativeBranchArm.new(
            branch_id: arm["branch_id"].to_s,
            arm_id: arm["arm_id"].to_s,
            kind: (arm["kind"] || "branch").to_s,
            member: (arm["member"] || arm["label"] || arm["arm"]).to_s,
            decision_span: Array(arm["decision_span"]).map(&:to_i),
            arm_span: Array(arm["arm_span"]).map(&:to_i),
            hits: arm["hits"].to_i
          )
        end

        lines = Array(cov["lines"]).map { |h| h.nil? ? nil : h.to_i }

        branches = {}
        if cov["branches"].is_a?(Hash)
          cov["branches"].each do |k, v|
            if v.is_a?(Hash)
              branches[k] = {}
              v.each do |sub_k, sub_v|
                branches[k][sub_k] = sub_v.to_i
              end
            end
          end
        end

        files[abs] = FileCoverage.new(
          file: abs,
          lines: lines,
          branches: branches,
          branch_arms: branch_arms,
          source_path: cov["source_path"].to_s,
          language: cov["language"].to_s,
          format: cov["format"].to_s.to_sym
        )
      end
      Dataset.new(path: path, files: files)
    end

    def resolve_path(path)
      return nil if path.nil? || path.to_s.empty?
      expanded = ::File.expand_path(path)
      if ::File.directory?(expanded)
        candidates = [
          "coverage/.resultset.json",
          "merged/kcov-merged/cobertura.xml",
          "kcov-merged/cobertura.xml",
          "cobertura.xml",
          "cov.xml",
          "merged/kcov-merged/codecov.json",
          "kcov-merged/codecov.json",
          "codecov.json",
          "branch-coverage.json",
          "nil-kill-branch-coverage.json"
        ]
        candidates.each do |rel|
          cand = ::File.join(expanded, rel)
          return cand if ::File.file?(cand)
        end
        glob_patterns = [
          "**/kcov-merged/cobertura.xml",
          "**/cobertura.xml",
          "**/codecov.json"
        ]
        glob_patterns.each do |pat|
          match = Dir[::File.join(expanded, pat)].sort.first
          return match if match && ::File.file?(match)
        end
        return nil
      end
      return expanded if ::File.file?(expanded)
      nil
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
      DecomplexRisk.load_decomplex_syntax
    end
  end
end


