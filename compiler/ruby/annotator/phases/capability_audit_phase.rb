# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"

module Annotator
  module Phases
    # Narrow migration interface for whole-program semantic checks. The phase
    # owns ordering and accepts only a completely typed program product.
    class CapabilityAuditOperations
      extend T::Sig

      ProgramAction = T.type_alias { T.proc.params(program: AST::Program).void }
      AuditAction = T.type_alias { T.proc.void }

      sig { returns(ProgramAction) }
      attr_reader :finalize_program_audit
      sig { returns(AuditAction) }
      attr_reader :analyze_whole_program, :run_deferred_validations

      sig do
        params(
          finalize_program_audit: ProgramAction,
          analyze_whole_program: AuditAction,
          run_deferred_validations: AuditAction
        ).void
      end
      def initialize(finalize_program_audit:, analyze_whole_program:, run_deferred_validations:)
        @finalize_program_audit = finalize_program_audit
        @analyze_whole_program = analyze_whole_program
        @run_deferred_validations = run_deferred_validations
        freeze
      end
    end

    class CapabilityAuditPhase
      extend T::Sig

      sig do
        params(
          typed_program: TypedProgramFacts,
          operations: CapabilityAuditOperations
        ).returns(CapabilityAuditReport)
      end
      def self.run(typed_program:, operations:)
        operations.finalize_program_audit.call(typed_program.program)
        operations.analyze_whole_program.call
        operations.run_deferred_validations.call

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
