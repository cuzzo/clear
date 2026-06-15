# frozen_string_literal: true

require "json"
require_relative "classifier"

module SlopCop
  # UI-oriented dark-arm export. This deliberately skips churn and
  # decomplex ranking; Lineage only needs the line-level classified arms.
  module DarkArmOverlay
    module_function

    def build(files:, repo:, resultset:, ffi_boundary: [], diagnostic_mids: [])
      repo = File.realpath(repo)
      arms = Array(files).flat_map do |file|
        rel = repo_relative(file, repo)
        abs = File.expand_path(rel, repo)
        next [] unless File.file?(abs)

        Classifier.classify_file(
          resultset,
          abs,
          root: repo,
          ffi_boundary: ffi_boundary,
          diagnostic_mids: diagnostic_mids
        ).map { |arm| overlay_arm(arm, repo) }
      end.compact.sort_by do |arm|
        [arm["file"], arm["line"].to_i, arm["method"].to_s, arm["arm_category"].to_s]
      end

      {
        "format" => "slopcop.dark-arms.v1",
        "repo" => repo,
        "coverage" => resultset,
        "dark_arms" => arms
      }
    end

    def to_json(**kwargs)
      JSON.pretty_generate(build(**kwargs))
    end

    def overlay_arm(arm, repo)
      rel = repo_relative(arm.file, repo)
      category = arm.category.to_s
      {
        "file" => rel,
        "path" => rel,
        "line" => arm.line,
        "arm_span" => span_array(arm.span),
        "decision_span" => span_array(arm.decision_span),
        "method" => arm.defn,
        "category" => "dark arm: #{category}",
        "arm_category" => category,
        "source" => arm.source.to_s
      }
    end

    def span_array(span)
      values = Array(span).map(&:to_i)
      values.size == 4 ? values : nil
    end

    def repo_relative(path, repo)
      root = File.expand_path(repo).tr("\\", "/").chomp("/")
      expanded = File.expand_path(path.to_s.start_with?("/") ? path : File.join(repo, path)).tr("\\", "/")
      prefix = "#{root}/"
      expanded.start_with?(prefix) ? expanded[prefix.length..] : path.to_s
    end
  end
end
