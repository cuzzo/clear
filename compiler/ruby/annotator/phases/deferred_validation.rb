# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../semantic/capability_plan"

module Annotator
  module Phases
    class DeferredWithValidation < T::Struct
      const :node, AST::WithBlock
      const :fact, CapabilityPlan::CapabilityTransition
    end

    module DeferredValidation
      extend T::Sig

      sig { params(node: AST::WithBlock, fact: CapabilityPlan::CapabilityTransition).void }
      def record_deferred_with_validation!(node, fact)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        deferred_with_validations << DeferredWithValidation.new(
          node: node,
          fact: fact
        )
      end

    end

    module DeferredCapabilityAudit
      extend T::Sig

      sig { void }
      def run_deferred_validations!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        flush_deferred_with_validations!
        finalize_capability_audit!
      end
      private :run_deferred_validations!

      # Replay deferred WITH-on-param checks after caller-sync propagation has
      # had a chance to populate entry.sync.
      sig { returns(T::Array[DeferredWithValidation]) }
      def flush_deferred_with_validations!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        deferred_with_validations.each do |d|
          fact = d.fact
          var_node = fact.var_node
          syn = var_node.symbol&.sync
          case fact.capability
          when :EXCLUSIVE
            next if syn
            storage = var_node.symbol&.storage
            error!(d.node, :WITH_EXCLUSIVE_NEEDS_LOCK_GOT, got: storage || 'unknown')
          when :write_locked_read
            next if syn == :write_locked
            error!(d.node, :WITH_READ_NEEDS_WRITE_LOCK_NAME, name: fact.target_label)
          when :ATOMIC
            next if syn == :atomic
            storage = var_node.symbol&.storage
            actual = syn ? "@#{syn}" : (storage ? "@#{storage}" : "plain")
            error!(d.node, :WITH_ATOMIC_NEEDS_SHARED_ATOMIC, name: fact.target_label, actual: actual)
          end
        end
        deferred_with_validations.clear
      end
      private :flush_deferred_with_validations!

    end
  end
end
