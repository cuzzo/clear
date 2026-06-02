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

      # Replay deferred WITH-on-param checks after caller-sync propagation has
      # had a chance to populate entry.sync.
      sig { returns(T::Array[DeferredWithValidation]) }
      def flush_deferred_with_validations!
        T.bind(self, SemanticAnnotator)

        deferred_with_validations.each do |d|
          var_node = d.var_node
          syn = var_node.symbol&.sync
          case d.capability
          when :EXCLUSIVE
            next if syn
            storage = var_node.symbol&.storage
            error!(d.node, :WITH_EXCLUSIVE_NEEDS_LOCK_GOT, got: storage || 'unknown')
          when :write_locked_read
            next if syn == :write_locked
            error!(d.node, :WITH_READ_NEEDS_WRITE_LOCK_NAME, name: cap_var_label(var_node))
          when :ATOMIC
            next if syn == :atomic
            name = cap_var_label(var_node)
            storage = var_node.symbol&.storage
            actual = syn ? "@#{syn}" : (storage ? "@#{storage}" : "plain")
            error!(d.node, :WITH_ATOMIC_NEEDS_SHARED_ATOMIC, name: name, actual: actual)
          end
        end
        deferred_with_validations.clear
      end
    end
  end
end
