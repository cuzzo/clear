# frozen_string_literal: true

require "json"

module Boobytrap
  # Branch-coverage gap per file from SimpleCov's .resultset.json
  # (enable_coverage :branch). Same merge rule as
  # tools/branch_gap_report.rb: a decision arm is "taken" if ANY
  # resultset entry took it (specs + transpile-tests + corpus). gap =
  # uncovered_arms / total_arms. Branch granularity, not line: the
  # defect class here is missing/half-applied DECISIONS.
  module CoverageGap
    File_ = Struct.new(:total, :uncovered, :gap, keyword_init: true)

    module_function

    # root: absolute repo root; resultset keys are absolute paths, we
    # return repo-relative keys so they join with git paths.
    def from_resultset(path, root:)
      data = JSON.parse(::File.read(path))
      merged = {}
      data.each_value do |entry|
        (entry["coverage"] || {}).each do |abs, cov|
          next unless cov.is_a?(Hash) && cov["branches"]

          dst = (merged[abs] ||= {})
          cov["branches"].each do |parent, arms|
            d = (dst[parent] ||= Hash.new(0))
            arms.each { |arm, n| d[arm] = d[arm] + (n || 0) }
          end
        end
      end
      rootp = root.chomp("/") + "/"
      out = {}
      merged.each do |abs, branches|
        total = 0
        uncov = 0
        branches.each_value do |arms|
          arms.each_value do |count|
            total += 1
            uncov += 1 if count.to_i.zero?
          end
        end
        next if total.zero?

        rel = abs.start_with?(rootp) ? abs[rootp.length..] : abs
        out[rel] = File_.new(total: total, uncovered: uncov,
                             gap: uncov.to_f / total)
      end
      out
    end

    def from_static(files, root:)
      return {} unless Boobytrap::DecomplexRisk.tree_sitter?
      return {} unless Boobytrap::DecomplexRisk.load_decomplex_syntax

      rootp = root.chomp("/") + "/"
      files.each_with_object({}) do |file, out|
        abs = ::File.expand_path(file.start_with?("/") ? file : ::File.join(root, file))
        next unless ::File.file?(abs)
        next unless Boobytrap::DecomplexRisk.supported_source?(abs)

        doc = Decomplex::Syntax.parse(abs, parser: "tree_sitter")
        total = doc.branch_arms.size
        next if total.zero?

        rel = abs.start_with?(rootp) ? abs[rootp.length..] : abs
        out[rel] = File_.new(total: total, uncovered: total, gap: 1.0)
      rescue LoadError, StandardError
        next
      end
    end
  end
end
