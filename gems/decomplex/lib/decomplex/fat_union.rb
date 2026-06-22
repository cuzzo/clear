# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Fat-union detector: Missing-Abstractions for product-vs-sum
  # decomposition. A `case <disc> when ClassA when ClassB ...`
  # dispatch where the arms read mostly the SAME members of <disc>
  # is a union whose common core should be a struct, with a small union
  # for the genuinely-varying part.
  class FatUnion
    def self.scan(files, min_variants: 3, min_common: 2, ratio: 0.6)
      sites = files.flat_map do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        document.dispatch_sites
      end
      Report.new(sites, min_variants: min_variants,
                 min_common: min_common, ratio: ratio)
    end

    class Report
      def initialize(sites, min_variants:, min_common:, ratio:)
        @sites = sites
        @min_variants = min_variants
        @min_common = min_common
        @ratio = ratio
      end

      # [{ variant_set:, common:[], variant:[], degenerate:, support:,
      #    scatter:, rank:, kind:, members:, at:, sites:[], spans:{} }]
      def fat_unions
        @sites.group_by(&:variant_set).filter_map do |vset, group|
          v = vset.size
          next if v < @min_variants

          vcls = Hash.new { |h, k| h[k] = {} }
          outside = {}
          group.each do |s|
            s.arm_members.each { |cls, ms| ms.each { |m| vcls[m][cls] = true } }
            s.outside.each { |m| outside[m] = true }
          end
          keys = vcls.keys | outside.keys
          common = keys.select do |m|
            outside[m] || (vcls[m] && vcls[m].size >= v)
          end
          variant = keys.select do |m|
            !outside[m] && vcls[m] && vcls[m].size == 1
          end
          total = common.size + variant.size
          next if common.size < @min_common
          next if total.zero? || common.size.to_f / total < @ratio

          locs = group.map { |s| "#{s.file}:#{s.function}:#{s.line}" }
          {
            variant_set: vset, common: common.sort,
            variant: variant.sort, degenerate: variant.empty?,
            support: group.size,
            scatter: group.map { |s| [s.file, s.function] }.uniq.size,
            rank: group.size * common.size,
            kind: :case_dispatch, members: vset,
            at: locs.first, sites: locs.uniq,
            spans: group.to_h { |s| ["#{s.file}:#{s.function}:#{s.line}", s.span] }
          }
        end.sort_by { |h| [h[:degenerate] ? 0 : 1, -h[:rank]] }
      end
    end
  end
end
