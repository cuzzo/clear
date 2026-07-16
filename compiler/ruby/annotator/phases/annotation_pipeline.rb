# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"
require_relative "capability_audit_phase"
require_relative "resolution_phase"
require_relative "type_analysis_phase"

module Annotator
  module Phases
    class AnnotationPipeline
      extend T::Sig

      sig do
        params(
          program: AST::Program,
          importer: T.nilable(ModuleImporter),
          source_dir: String,
          source_code: T.nilable(String),
          products: AnnotationProducts,
          type_session: TypeAnalysisSession
        ).returns(AnnotationProducts)
      end
      def self.run(program:, importer:, source_dir:, source_code:, products:, type_session:)
        resolution = ResolutionPhase.run(
          program: program,
          importer: importer,
          source_dir: source_dir,
          source_code: source_code
        )
        products = products.publish_resolution(resolution)
        type_session.publish_annotation_products!(products)

        typed_program = TypeAnalysisPhase.run(
          resolution: resolution,
          session: type_session
        )
        products = products.publish_typed_program(typed_program)
        type_session.publish_annotation_products!(products)

        audit_inputs = type_session.release_capability_audit_inputs!
        audit_session = CapabilityAuditSession.new(
          typed_program: typed_program,
          inputs: audit_inputs,
          source_code: source_code,
          language_mode: type_session.language_mode,
          strict_test: type_session.strict_test?
        )
        audit = CapabilityAuditPhase.run(
          typed_program: typed_program,
          session: audit_session
        )
        type_session.install_audited_inputs!(audit_inputs)
        products = products.publish_capability_audit(audit)
        type_session.publish_annotation_products!(products)
        products
      end
    end
  end
end
