# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"

module Annotator
  module Phases
    class CapabilityAuditPhase
      extend T::Sig

      sig do
        params(
          typed_program: TypedProgramFacts,
          session: CapabilityAuditSession
        ).returns(CapabilityAuditReport)
      end
      def self.run(typed_program:, session:)
        session.audit!

        summaries = typed_program.body_summaries
        CapabilityAuditReport.new(
          typed_program: typed_program,
          checked_functions: summaries.keys,
          checked_call_sites: summaries.each_value.sum { |summary| summary.call_site_facts.length },
          checked_with_sites: summaries.each_value.sum { |summary| summary.with_blocks.length },
          violation_count: 0
        )
      end
    end
  end
end
