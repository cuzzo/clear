# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../semantic/pass_state"

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

        unless pending_deferred_validation_count.zero?
          raise "annotation boundary has pending deferred validations"
        end

        semantic_function_nodes.each do |name, fn|
          signature = FunctionSignature.unwrap(fn.full_type!(context: "annotation boundary function #{name}"))
          raise "annotation boundary missing function signature for #{name}" unless signature
        end
      end
      private :verify_annotation_boundary!
    end
  end
end
