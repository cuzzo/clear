# frozen_string_literal: true

require_relative "coverage_data"
require_relative "decomplex_risk"

module Boobytrap
  # Branch-coverage gap per file from normalized coverage data.
  # SimpleCov branch tuples are used directly. Coverage formats that
  # only provide line hits, such as kcov, use Tree-sitter branch arms and
  # normalized line hits to infer which arms are still dark.
  module CoverageGap
    File_ = Struct.new(:total, :uncovered, :gap, keyword_init: true)

    module_function

    # root: absolute repo root; resultset keys are absolute paths, we
    # return repo-relative keys so they join with git paths.
    def from_resultset(path, root:)
      from_coverage(CoverageData.load(path, root: root), root: root)
    end

    def from_coverage(dataset, root:)
      out = {}
      dataset.files.each do |abs, coverage|
        file_gap = if coverage.branch_coverage?
                     simplecov_branch_gap(coverage.branches)
                   else
                     tree_sitter_line_branch_gap(abs, coverage)
                   end
        next unless file_gap

        out[CoverageData.relpath(abs, root)] = file_gap
      end
      out
    end

    def simplecov_branch_gap(branches)
      total = 0
      uncov = 0
      branches.each_value do |arms|
        arms.each_value do |count|
          total += 1
          uncov += 1 if count.to_i.zero?
        end
      end
      return nil if total.zero?

      File_.new(total: total, uncovered: uncov, gap: uncov.to_f / total)
    end

    def tree_sitter_line_branch_gap(abs, coverage)
      return nil unless coverage.line_coverage? || coverage.branch_arm_coverage?
      return nil unless Boobytrap::DecomplexRisk.load_decomplex_syntax
      return nil unless Boobytrap::DecomplexRisk.tree_sitter_supported_source?(abs)

      doc = Decomplex::Syntax.parse(abs, parser: "tree_sitter")
      arms = CoverageData.branch_arm_coverage(coverage, doc.branch_arms)
      total = arms.size
      return nil if total.zero?

      uncov = arms.count { |arm| !arm.covered }
      File_.new(total: total, uncovered: uncov, gap: uncov.to_f / total)
    rescue LoadError, StandardError
      nil
    end

    def from_static(files, root:)
      return {} unless Boobytrap::DecomplexRisk.tree_sitter?
      return {} unless Boobytrap::DecomplexRisk.load_decomplex_syntax

      files.each_with_object({}) do |file, out|
        abs = ::File.expand_path(file.start_with?("/") ? file : ::File.join(root, file))
        next unless ::File.file?(abs)
        next unless Boobytrap::DecomplexRisk.supported_source?(abs)

        doc = Decomplex::Syntax.parse(abs, parser: "tree_sitter")
        total = doc.branch_arms.size
        next if total.zero?

        rel = CoverageData.relpath(abs, root)
        out[rel] = File_.new(total: total, uncovered: total, gap: 1.0)
      rescue LoadError, StandardError
        next
      end
    end
  end
end
