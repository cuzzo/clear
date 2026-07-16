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

        audit = CapabilityAuditPhase.run(
          typed_program: typed_program,
          request: type_session.release_capability_audit_request!
        )
        products = products.publish_capability_audit(audit)
        type_session.publish_annotation_products!(products)
        products
      end
    end
  end
end
