# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module Annotator
  module Phases
    class SnapshotTxnViolation < T::Struct
      const :effect, Symbol
      const :fn, String
    end

    class HeldLockEntry < T::Struct
      const :token, T.nilable(Lexer::Token)
    end

    HeldLockMap = T.type_alias { T::Hash[String, HeldLockEntry] }

    class HeldLockTypeEntry < T::Struct
      const :type, Symbol
      const :opted_out, T::Boolean
    end

    class SnapshotTxnFrame < T::Struct
      const :violations, T::Array[SnapshotTxnViolation], factory: -> { [] }
    end

    class DeferredRecoveryValidation < T::Struct
      const :node, AST::BinaryOp
      const :left, AST::FuncCall
      const :callee_name, String
      const :value_type, Type
    end

    # Facts gathered while typing but consumed only by capability auditing.
    # This immutable schema is owned by the phase boundary, not by either
    # executor on its two sides.
    class CapabilityAuditInputs < T::Struct
      prop :held_locks, HeldLockMap, factory: -> { {} }
      prop :held_lock_types, T::Array[HeldLockTypeEntry], factory: -> { [] }
      prop :current_predicate_context, T.nilable(CapabilityHelper::PredicateContext), default: nil
      prop :deferred_with_validations,
        T::Array[DeferredWithValidation],
        factory: -> { [] }
      prop :deferred_recovery_validations,
        T::Array[DeferredRecoveryValidation],
        factory: -> { [] }
      prop :predicate_call_sites, T::Array[CapabilityHelper::PredicateCallSite], factory: -> { [] }
      prop :async_body_facts, T::Array[AsyncBodyFact], factory: -> { [] }
      prop :capability_audit, CapabilityAudit::BindingAuditStore, factory: -> { {} }
      prop :capture_stack, T::Array[CapabilityHelper::CaptureContext], factory: -> { [] }
      prop :capture_move_suppression_depth, Integer, default: 0
      prop :snapshot_txn_frames, T::Array[SnapshotTxnFrame], factory: -> { [] }
      prop :effect_state, T.nilable(EffectTracker::EffectState), default: nil
      prop :lock_analysis, LockHelper::LockAnalysisState, factory: -> { LockHelper::LockAnalysisState.new }
      prop :ownership_graph, OwnershipGraph, factory: -> { OwnershipGraph.new }
      prop :ownership_transport_frames, T::Array[OwnershipTransportFacts], factory: -> { [] }
    end
  end
end
