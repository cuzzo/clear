# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../semantic/pass_state"
require_relative "type_analysis_phase"

module Annotator
  module Phases
    module AnnotationBoundary
      extend T::Sig

      sig { params(program: AST::Program).void }
      def mark_annotation_complete!(program)
        T.bind(self, SemanticAnnotator)

        verify_annotation_boundary!(program)
        MIRPassState.for!(program).mark!(:annotated)
      end

      sig { params(program: AST::Program).void }
      def verify_annotation_boundary!(program)
        T.bind(self, SemanticAnnotator)

        program.full_type!(context: "annotation boundary program")
        assert_no_annotation_type_violations!(program)
        assert_no_pending_deferred_validations!
        assert_annotation_function_signatures!
      end
      private :verify_annotation_boundary!

      sig { params(program: AST::Program).void }
      def assert_no_annotation_type_violations!(program)
        T.bind(self, SemanticAnnotator)

        typed_program = annotation_products.typed_program
        if typed_program && typed_program.program.equal?(program)
          return if typed_program.unresolved_node_count.zero?
        end

        AnnotationTypeInventory.scan(program).verify_resolved!
      end
      private :assert_no_annotation_type_violations!

      sig { void }
      def assert_no_pending_deferred_validations!
        T.bind(self, SemanticAnnotator)

        unless pending_deferred_validation_count.zero?
          raise "annotation boundary has pending deferred validations"
        end
      end
      private :assert_no_pending_deferred_validations!

      sig { void }
      def assert_annotation_function_signatures!
        T.bind(self, SemanticAnnotator)

        semantic_function_nodes.each do |name, fn|
          signature = FunctionSignature.unwrap(fn.full_type!(context: "annotation boundary function #{name}"))
          raise "annotation boundary missing function signature for #{name}" unless signature
        end
      end
      private :assert_annotation_function_signatures!

    end
  end
end
