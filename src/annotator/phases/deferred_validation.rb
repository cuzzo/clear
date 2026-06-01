# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"

module Annotator
  module Phases
    class DeferredWithValidation < T::Struct
      const :node, AST::WithBlock
      const :var_node, AST::Locatable
      const :capability, Symbol
    end

    module DeferredValidation
      extend T::Sig

      sig { params(node: AST::WithBlock, var_node: AST::Locatable, capability: Symbol).void }
      def record_deferred_with_validation!(node, var_node, capability)
        T.bind(self, SemanticAnnotator)
        deferred_with_validations << DeferredWithValidation.new(
          node: node,
          var_node: var_node,
          capability: capability
        )
      end

      sig { void }
      def run_deferred_validations!
        T.bind(self, SemanticAnnotator)

        flush_deferred_with_validations!
        finalize_capability_audit!
      end
    end
  end
end
