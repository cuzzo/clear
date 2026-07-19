# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"
require_relative "capability_audit_session"
require_relative "phase_handoffs"

module Annotator
  module Phases
    class CapabilityAuditPhase
      extend T::Sig

      sig do
        params(
          typed_program: TypedProgramFacts,
          request: CapabilityAuditRequest
        ).returns(CapabilityAuditReport)
      end
      def self.run(typed_program:, request:)
        session = CapabilityAuditSession.new(
          typed_program: typed_program,
          inputs: request.inputs,
          source_code: request.source_code,
          language_mode: request.language_mode,
          strict_test: request.strict_test
        )
        session.audit!
        unless request.inputs.deferred_with_validations.empty?
          raise "capability audit left deferred validations pending"
        end

        summaries = typed_program.body_summaries
        derived_program = DerivedProgramFacts.capture(typed_program.resolution.function_registry.nodes)
        CapabilityAuditReport.new(
          typed_program: typed_program,
          derived_program: derived_program,
          checked_functions: summaries.keys,
          checked_call_sites: summaries.each_value.sum { |summary| summary.call_site_facts.length },
          checked_with_sites: summaries.each_value.sum { |summary| summary.with_blocks.length },
          violation_count: 0
        )
      end
    end
  end
end
