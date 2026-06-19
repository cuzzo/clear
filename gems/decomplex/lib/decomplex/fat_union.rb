# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Fat-union detector: Missing-Abstractions for product-vs-sum
  # decomposition. A `case <disc> when ClassA when ClassB ...`
  # dispatch where the arms read mostly the SAME members of <disc>
  # is a union whose common core should be a struct, with a small union
  # for the genuinely-varying part.
  class FatUnion
    CONSTANT_PATTERN = /\A[A-Z]\w*(?:(?:::|\.)[A-Z]\w*)*\z/
    IF_DISPATCH_PATTERN = /\A(?<subject>.+?)\s*(?:==|===)\s*(?<variant>[A-Z]\w*(?:(?:::|\.)[A-Z]\w*)*)\z/
    Site = Struct.new(:variant_set, :arm_members, :outside, :file,
                      :defn, :line, :span, keyword_init: true)

    def self.scan(files, min_variants: 3, min_common: 2, ratio: 0.6)
      sites = files.flat_map do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        new(document).sites
      end
      Report.new(sites, min_variants: min_variants,
                 min_common: min_common, ratio: ratio)
    end

    attr_reader :document

    def initialize(document)
      @document = document
    end

    def sites
      arms = document.branch_arms
      case_sites = arms
                   .select { |arm| arm.kind == :case }
                   .group_by { |arm| [arm.file, arm.function, arm.decision_span, arm.predicate] }
                   .filter_map { |_key, case_arms| record_case(case_arms) }
      case_sites + if_dispatch_sites(arms)
    end

    private

    def record_case(arms)
      predicate = arms.first.predicate.to_s
      return nil if predicate.empty?

      arm_members = {}
      arms.each do |arm|
        variants = constant_patterns(arm.member)
        next if variants.empty?

        members = members_inside(predicate, arm.function, arm.span)
        variants.each { |variant| (arm_members[variant] ||= []).concat(members) }
      end
      return nil if arm_members.size < 2

      arm_members.transform_values!(&:uniq)
      Site.new(
        variant_set: arm_members.keys.sort,
        arm_members: arm_members,
        outside: members_outside(predicate, arms.first.function, arms.first.decision_span),
        file: arms.first.file,
        defn: arms.first.function,
        line: arms.first.decision_line,
        span: arms.first.decision_span
      )
    end

    def if_dispatch_sites(arms)
      arms.select { |arm| arm.kind == :if && arm.member == "then" }
          .filter_map { |arm| [arm, if_dispatch_match(arm.predicate)] }
          .reject { |_arm, match| match.nil? }
          .group_by { |arm, match| [arm.file, arm.function, match[:subject]] }
          .filter_map { |_key, matched| record_if_dispatch(matched) }
    end

    def record_if_dispatch(matched)
      predicate = matched.first[1][:subject]
      arm_members = {}
      matched.each do |arm, match|
        members = members_inside(predicate, arm.function, arm.span)
        (arm_members[match[:variant]] ||= []).concat(members)
      end
      return nil if arm_members.size < 2

      arm_members.transform_values!(&:uniq)
      Site.new(
        variant_set: arm_members.keys.sort,
        arm_members: arm_members,
        outside: members_outside(predicate, matched.first[0].function, matched.first[0].decision_span),
        file: matched.first[0].file,
        defn: matched.first[0].function,
        line: matched.first[0].decision_line,
        span: matched.first[0].decision_span
      )
    end

    def if_dispatch_match(predicate)
      source = predicate.to_s.strip
      source = source[1...-1].strip if source.start_with?("(") && source.end_with?(")")
      match = source.match(IF_DISPATCH_PATTERN)
      return nil unless match

      { subject: match[:subject].strip, variant: match[:variant].strip }
    end

    def members_inside(predicate, function, span)
      member_calls(predicate, function)
        .select { |call| inside_span?(call.span, span) }
        .map { |call| member_name(call) }
        .uniq
    end

    def members_outside(predicate, function, decision_span)
      member_calls(predicate, function)
        .reject { |call| inside_span?(call.span, decision_span) }
        .map { |call| member_name(call) }
        .uniq
    end

    def member_calls(predicate, function)
      document.call_sites.select do |call|
        call.function == function &&
          call.receiver.to_s == predicate &&
          !call.message.to_s.empty?
      end
    end

    def member_name(call)
      call.message.to_s.sub(/=\z/, "")
    end

    def constant_patterns(member)
      member.to_s.split(/\s*,\s*/).map { |pattern| pattern.sub(/\Acase\s+/, "") }
            .select { |pattern| pattern.match?(CONSTANT_PATTERN) }
    end

    def inside_span?(inner, outer)
      return false unless inner && outer

      starts_after_or_at = (inner[0] > outer[0]) || (inner[0] == outer[0] && inner[1] >= outer[1])
      ends_before_or_at = (inner[2] < outer[2]) || (inner[2] == outer[2] && inner[3] <= outer[3])
      starts_after_or_at && ends_before_or_at
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

          locs = group.map { |s| "#{s.file}:#{s.defn}:#{s.line}" }
          {
            variant_set: vset, common: common.sort,
            variant: variant.sort, degenerate: variant.empty?,
            support: group.size,
            scatter: group.map { |s| [s.file, s.defn] }.uniq.size,
            rank: group.size * common.size,
            kind: :case_dispatch, members: vset,
            at: locs.first, sites: locs.uniq,
            spans: group.to_h { |s| ["#{s.file}:#{s.defn}:#{s.line}", s.span] }
          }
        end.sort_by { |h| [h[:degenerate] ? 0 : 1, -h[:rank]] }
      end
    end
  end
end
