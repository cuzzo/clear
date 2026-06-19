# frozen_string_literal: true

module Decomplex
  module Syntax
    DispatchSite = Struct.new(:variant_set, :arm_members, :outside, :file,
                              :function, :line, :span, keyword_init: true)

    class Document
      def dispatch_sites
        @dispatch_sites ||= adapter.dispatch_sites(self)
      end
    end

    class TreeSitterAdapter
      def dispatch_sites(document)
        syntax_profile(document.language).dispatch_sites(document)
      end
    end

    class TreeSitterLanguageAdapter
      DISPATCH_CONSTANT_PATTERN = /\A[A-Z]\w*(?:(?:::|\.|_)[A-Z]\w*)*\z/
      IF_DISPATCH_PATTERN = /\A(?<subject>.+?)\s*(?:==|===)\s*(?<variant>[A-Z]\w*(?:(?:::|\.|_)[A-Z]\w*)*)\z/

      def dispatch_sites(document)
        arms = document.branch_arms
        case_dispatch_sites(document, arms) + if_dispatch_sites(document, arms)
      end

      private

      def case_dispatch_sites(document, arms)
        arms.select { |arm| arm.kind == :case }
            .group_by { |arm| [arm.file, arm.function, arm.decision_span, arm.predicate] }
            .filter_map { |_key, case_arms| record_case_dispatch_site(document, case_arms) }
      end

      def record_case_dispatch_site(document, arms)
        predicate = arms.first.predicate.to_s
        return nil if predicate.empty?

        arm_members = {}
        arms.each do |arm|
          variants = dispatch_constant_patterns(arm.member)
          next if variants.empty?

          members = dispatch_members_inside(document, predicate, arm.function, arm.span)
          variants.each { |variant| (arm_members[variant] ||= []).concat(members) }
        end
        return nil if arm_members.size < 2

        arm_members.transform_values!(&:uniq)
        DispatchSite.new(
          variant_set: arm_members.keys.sort,
          arm_members: arm_members,
          outside: dispatch_members_outside(document, predicate, arms.first.function, arms.first.decision_span),
          file: arms.first.file,
          function: arms.first.function,
          line: arms.first.decision_line,
          span: arms.first.decision_span
        )
      end

      def if_dispatch_sites(document, arms)
        arms.select { |arm| arm.kind == :if && arm.member == "then" }
            .filter_map { |arm| [arm, if_dispatch_match(arm.predicate)] }
            .reject { |_arm, match| match.nil? }
            .group_by { |arm, match| [arm.file, arm.function, match[:subject]] }
            .filter_map { |_key, matched| record_if_dispatch_site(document, matched) }
      end

      def record_if_dispatch_site(document, matched)
        predicate = matched.first[1][:subject]
        arm_members = {}
        matched.each do |arm, match|
          members = dispatch_members_inside(document, predicate, arm.function, arm.span)
          (arm_members[match[:variant]] ||= []).concat(members)
        end
        return nil if arm_members.size < 2

        arm_members.transform_values!(&:uniq)
        DispatchSite.new(
          variant_set: arm_members.keys.sort,
          arm_members: arm_members,
          outside: dispatch_members_outside_spans(document, predicate, matched.first[0].function, matched.map { |arm, _match| arm.span }),
          file: matched.first[0].file,
          function: matched.first[0].function,
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

      def dispatch_members_inside(document, predicate, function, span)
        dispatch_member_calls(document, predicate, function)
          .select { |call| dispatch_inside_span?(call.span, span) }
          .map { |call| dispatch_member_name(call) }
          .uniq
      end

      def dispatch_members_outside(document, predicate, function, decision_span)
        dispatch_member_calls(document, predicate, function)
          .reject { |call| dispatch_inside_span?(call.span, decision_span) }
          .map { |call| dispatch_member_name(call) }
          .uniq
      end

      def dispatch_members_outside_spans(document, predicate, function, spans)
        dispatch_member_calls(document, predicate, function)
          .reject { |call| spans.any? { |span| dispatch_inside_span?(call.span, span) } }
          .map { |call| dispatch_member_name(call) }
          .uniq
      end

      def dispatch_member_calls(document, predicate, function)
        document.call_sites.select do |call|
          call.function == function &&
            call.receiver.to_s == predicate &&
            !call.message.to_s.empty?
        end
      end

      def dispatch_member_name(call)
        call.message.to_s.sub(/=\z/, "")
      end

      def dispatch_constant_patterns(member)
        member.to_s.split(/\s*,\s*/).map { |pattern| pattern.sub(/\Acase\s+/, "") }
              .select { |pattern| pattern.match?(DISPATCH_CONSTANT_PATTERN) }
      end

      def dispatch_inside_span?(inner, outer)
        return false unless inner && outer

        starts_after_or_at = (inner[0] > outer[0]) || (inner[0] == outer[0] && inner[1] >= outer[1])
        ends_before_or_at = (inner[2] < outer[2]) || (inner[2] == outer[2] && inner[3] <= outer[3])
        starts_after_or_at && ends_before_or_at
      end
    end
  end
end
