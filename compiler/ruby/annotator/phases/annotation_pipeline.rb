# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"
require_relative "resolution_phase"
require_relative "type_analysis_phase"
require_relative "type_analysis_session"
require_relative "capability_audit_phase"

module Annotator
  module Phases
    # Owns phase ordering and the last successfully published immutable facts.
    # The phase executors never mutate or retain the product ledger.
    class AnnotationPipeline
      extend T::Sig

      class Config < T::Struct
        const :importer, T.nilable(ModuleImporter)
        const :source_dir, String
        const :source_code, T.nilable(String)
        const :strict_test, T::Boolean
      end

      sig { returns(AnnotationProducts) }
      attr_reader :products

      sig do
        params(
          importer: T.nilable(ModuleImporter),
          source_dir: String,
          source_code: T.nilable(String),
          strict_test: T::Boolean
        ).void
      end
      def initialize(importer:, source_dir:, source_code:, strict_test:)
        @config = T.let(Config.new(
          importer: importer,
          source_dir: source_dir,
          source_code: source_code,
          strict_test: strict_test
        ), Config)
        @products = T.let(AnnotationProducts.new, AnnotationProducts)
      end

      sig { params(program: AST::Program).returns(AnnotationProducts) }
      def run(program)
        resolution = ResolutionPhase.run(
          program: program,
          importer: @config.importer,
          source_dir: @config.source_dir,
          source_code: @config.source_code
        )
        @products = @products.publish_resolution(resolution)

        type_session = TypeAnalysisSession.new(
          importer: @config.importer,
          source_dir: @config.source_dir,
          strict_test: @config.strict_test,
          source_code: @config.source_code
        )
        handoff = TypeAnalysisPhase.run(resolution: resolution, session: type_session)
        typed_program = handoff.typed_program
        @products = @products.publish_typed_program(typed_program)

        audit = CapabilityAuditPhase.run(
          typed_program: typed_program,
          request: handoff.audit_request
        )
        @products = @products.publish_capability_audit(audit)
      end
    end
  end
end
