# frozen_string_literal: true

require "json"
require_relative "classifier"
sibling_sarif = File.expand_path("../../../decomplex/lib/decomplex/sarif", __dir__)
if File.file?("#{sibling_sarif}.rb")
  require sibling_sarif
else
  require_relative "sarif"
end

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
      to_sarif(**kwargs)
    end

    def to_sarif(**kwargs)
      JSON.pretty_generate(to_sarif_hash(**kwargs))
    end

    def to_sarif_hash(**kwargs)
      overlay = build(**kwargs)
      arms = overlay.fetch("dark_arms")
      SlopCop::Sarif.document(
        tool_name: "SlopCop",
        information_uri: "https://github.com/codeforreno/litedb",
        rules: sarif_rules(arms),
        results: arms.map { |arm| sarif_result(arm) },
        properties: {
          "format" => "slopcop.dark-arms.sarif.v1",
          "slopcop.dark_arms" => overlay
        }
      )
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

    def sarif_rules(arms)
      arms.map { |arm| arm.fetch("arm_category", "unknown") }.uniq.sort.map do |category|
        SlopCop::Sarif.rule(
          id: "slopcop.dark-arm.#{SlopCop::Sarif.slug(category)}",
          name: "Dark Arm: #{category}",
          short_description: "Classified uncovered branch arm",
          default_level: category == "genuine" ? "warning" : "note",
          properties: { "category" => category }
        )
      end
    end

    def sarif_result(arm)
      span = arm["arm_span"]
      SlopCop::Sarif.result(
        rule_id: "slopcop.dark-arm.#{SlopCop::Sarif.slug(arm.fetch("arm_category", "unknown"))}",
        level: arm["arm_category"] == "genuine" ? "warning" : "note",
        message: arm["category"],
        path: arm["file"] || arm["path"],
        line: arm["line"],
        start_column: zero_based_column_to_sarif(span&.[](1)),
        end_line: span&.[](2),
        end_column: zero_based_column_to_sarif(span&.[](3)),
        properties: arm.merge(
          "dark_arm" => true,
          "source_format" => "slopcop.dark-arms.v1"
        )
      )
    end

    def zero_based_column_to_sarif(value)
      value.nil? ? nil : value.to_i + 1
    end

    def repo_relative(path, repo)
      root = File.expand_path(repo).tr("\\", "/").chomp("/")
      expanded = File.expand_path(path.to_s.start_with?("/") ? path : File.join(repo, path)).tr("\\", "/")
      prefix = "#{root}/"
      expanded.start_with?(prefix) ? expanded[prefix.length..] : path.to_s
    end
  end
end
