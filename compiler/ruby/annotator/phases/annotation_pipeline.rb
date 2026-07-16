# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"
require_relative "capability_audit_phase"
require_relative "resolution_phase"
require_relative "type_analysis_phase"

module Annotator
  module Phases
    # The single host-facing operation surface. SemanticAnnotator supplies the
    # proven algorithms while AnnotationPipeline alone knows phase classes,
    # order, and product publication.
    class AnnotationPipelineOperations < T::Struct
      ImportResolver = T.type_alias { ResolutionOperations::ImportResolver }
      DeclarationAction = T.type_alias { ResolutionOperations::DeclarationAction }
      ProgramAction = T.type_alias { ResolutionOperations::ProgramAction }
      AnalyzeBodies = T.type_alias { TypeAnalysisOperations::AnalyzeBodies }
      AuditAction = T.type_alias { CapabilityAuditOperations::AuditAction }
      ProductPublisher = T.type_alias { T.proc.params(products: AnnotationProducts).void }

      const :resolve_import, ImportResolver
      const :register_types, DeclarationAction
      const :register_signatures, DeclarationAction
      const :resolve_reentrance, ProgramAction
      const :resolve_sync_policy, ProgramAction
      const :seed_error_types, DeclarationAction
      const :analyze_bodies, AnalyzeBodies
      const :resolve_catches, DeclarationAction
      const :finalize_program_type, ProgramAction
      const :finalize_auto_types, ProgramAction
      const :finalize_program_audit, ProgramAction
      const :analyze_whole_program, AuditAction
      const :run_deferred_validations, AuditAction
      const :publish_products, ProductPublisher
    end

    class AnnotationPipeline
      extend T::Sig

      sig do
        params(
          program: AST::Program,
          root_scope: Scope,
          function_registry: Annotator::FunctionRegistry,
          products: AnnotationProducts,
          operations: AnnotationPipelineOperations
        ).returns(AnnotationProducts)
      end
      def self.run(program:, root_scope:, function_registry:, products:, operations:)
        resolution = ResolutionPhase.run(
          program: program,
          root_scope: root_scope,
          function_registry: function_registry,
          operations: resolution_operations(operations)
        )
        products = products.publish_resolution(resolution)
        operations.publish_products.call(products)

        typed_program = TypeAnalysisPhase.run(
          resolution: resolution,
          operations: type_analysis_operations(operations)
        )
        products = products.publish_typed_program(typed_program)
        operations.publish_products.call(products)

        audit = CapabilityAuditPhase.run(
          typed_program: typed_program,
          operations: capability_audit_operations(operations)
        )
        products = products.publish_capability_audit(audit)
        operations.publish_products.call(products)
        products
      end

      sig { params(operations: AnnotationPipelineOperations).returns(ResolutionOperations) }
      def self.resolution_operations(operations)
        ResolutionOperations.new(
          resolve_import: operations.resolve_import,
          register_types: operations.register_types,
          register_signatures: operations.register_signatures,
          resolve_reentrance: operations.resolve_reentrance,
          resolve_sync_policy: operations.resolve_sync_policy,
          seed_error_types: operations.seed_error_types
        )
      end
      private_class_method :resolution_operations

      sig { params(operations: AnnotationPipelineOperations).returns(TypeAnalysisOperations) }
      def self.type_analysis_operations(operations)
        TypeAnalysisOperations.new(
          analyze_bodies: operations.analyze_bodies,
          resolve_catches: operations.resolve_catches,
          finalize_program: operations.finalize_program_type,
          finalize_auto_types: operations.finalize_auto_types
        )
      end
      private_class_method :type_analysis_operations

      sig { params(operations: AnnotationPipelineOperations).returns(CapabilityAuditOperations) }
      def self.capability_audit_operations(operations)
        CapabilityAuditOperations.new(
          finalize_program_audit: operations.finalize_program_audit,
          analyze_whole_program: operations.analyze_whole_program,
          run_deferred_validations: operations.run_deferred_validations
        )
      end
      private_class_method :capability_audit_operations
    end
  end
end
