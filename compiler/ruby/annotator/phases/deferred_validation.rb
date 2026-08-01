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

      sig { params(node: AST::BinaryOp, left: AST::FuncCall, callee_name: String, value_type: Type).void }
      def record_deferred_recovery_validation!(node, left, callee_name, value_type)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        deferred_recovery_validations << DeferredRecoveryValidation.new(
          node: node,
          left: left,
          callee_name: callee_name,
          value_type: value_type,
        )
      end

      sig { params(facts: FunctionAnalysis::CallArgumentFacts).void }
      def record_deferred_give_validation!(facts)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        deferred_give_validations << DeferredGiveValidation.new(
          arg_node: facts.arg_node,
          callee_name: facts.site.node.name.to_s,
          param_index: facts.index,
          param_name: facts.param.name.to_s,
        )
      end

    end

    module DeferredCapabilityAudit
      extend T::Sig

      sig { void }
      def run_deferred_validations!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        flush_deferred_recovery_validations!
        flush_deferred_with_validations!
        flush_deferred_give_validations!
        flush_deferred_copy_retained_validations!
        finalize_capability_audit!
      end
      private :run_deferred_validations!

      # Replay GIVE-into-borrow-param checks after the keep fixpoint: GIVE at
      # a kept edge is a legal relinquishment assertion, everywhere else it
      # remains an error.
      sig { void }
      def flush_deferred_give_validations!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        deferred_give_validations.each do |d|
          param = function_node_for(d.callee_name)&.params&.fetch(d.param_index, nil)
          next if param&.symbol&.kept_identity
          error!(d.arg_node, :GIVE_TO_BORROW_PARAM, param: d.param_name)
        end
        deferred_give_validations.clear
      end
      private :flush_deferred_give_validations!

      # Retained-identity v5 (V5-3b): a COPY of a retained carrier at a
      # non-UNIQUE edge is illegal (design "Parameter contracts"), UNLESS the
      # callee param is a v4 kept-identity edge -- that temporary exception is
      # removed when the v4 kept machinery is retired (Phase 6b).
      sig { void }
      def flush_deferred_copy_retained_validations!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        deferred_copy_retained_validations.each do |d|
          param = function_node_for(d.callee_name)&.params&.fetch(d.param_index, nil)
          next if param&.symbol&.kept_identity # v4 kept-edge exception (Phase 6b removes this)
          error!(d.arg_node, :COPY_RETAINED_NEEDS_UNIQUE, name: d.name, carrier: d.carrier)
        end
        deferred_copy_retained_validations.clear
      end
      private :flush_deferred_copy_retained_validations!

      sig { void }
      def flush_deferred_recovery_validations!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        deferred_recovery_validations.each do |validation|
          callee = function_node_for(validation.callee_name)
          unless callee&.can_fail == true
            error!(validation.node, :OR_ELSE_NEEDS_RECOVERABLE_LEFT,
              got: Type.surface_name_type(validation.value_type))
          end

          validation.left.can_fail = true
          validation.left.error_union_type = Type.error_union_of(validation.value_type)
        end
        deferred_recovery_validations.clear
      end
      private :flush_deferred_recovery_validations!

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
