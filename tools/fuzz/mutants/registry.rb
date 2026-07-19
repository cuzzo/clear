# typed: strict
# Targeted safety mutants for the fuzz harness.
#
# These are not broad source-level mutations. Each entry deliberately disables
# one ownership-safety rule and names the fuzz templates that should notice.

require 'sorbet-runtime'

module FuzzMutants
  extend T::Sig

  KillSpec = T.type_alias { T::Hash[Symbol, T.any(Symbol, Integer)] }

  class Mutant < T::Struct
    const :name, Symbol
    const :description, String
    const :invariant, Symbol
    const :patch, String
    const :templates, T::Array[Symbol]
    const :kill, KillSpec
  end

  ROOT = T.let(File.expand_path('../../..', __dir__), String)
  PATCH_DIR = T.let(File.expand_path('patches', __dir__), String)

  REGISTRY = T.let([
    Mutant.new(
      name: :protocol_conformance_signature,
      description: 'Accept incompatible protocol member signatures. A concrete implementation must match the declared return and parameter contracts.',
      invariant: :protocol_conformance_signature,
      patch: File.join(PATCH_DIR, 'protocol_conformance_signature.patch'),
      templates: [:generic_map_protocol_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :generic_shared_map_access_scope,
      description: 'Allow direct access to SHARED Map generic parameters. Index and method operations must require a WITH POLYMORPHIC view.',
      invariant: :generic_shared_map_access_scope,
      patch: File.join(PATCH_DIR, 'generic_shared_map_access_scope.patch'),
      templates: [:generic_shared_map_capability_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :allow_inferred_alias_call_mutation,
      description: 'Disable inferred-alias rejection after resolved mutable calls. User and stdlib MUTABLE contracts must still reject mutation while an inferred alias is live.',
      invariant: :inferred_alias_mutation,
      patch: File.join(PATCH_DIR, 'allow_inferred_alias_call_mutation.patch'),
      templates: [:auto_ownership_transport_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :allow_with_alias_return,
      description: 'Disable RETURN rejection for WITH-scoped aliases.',
      invariant: :alias_non_escape,
      patch: File.join(PATCH_DIR, 'allow_with_alias_return.patch'),
      templates: [:access_gate],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :escape_struct_field_walker,
      description: 'Disable both current receiver-escape paths for mutation ' \
                   'sinks. A loop-local collection wrapped in a struct/union ' \
                   'payload and appended to an outer collection must still ' \
                   'force the receiver heap-owned.',
      invariant: :inv_5_frame_escape,
      patch: File.join(PATCH_DIR, 'escape_struct_field_walker.patch'),
      templates: [:nested_loop_escape],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :lower_if_cond_pending_leak,
      description: 'Stop lower_if draining the condition\'s @pending_stmts ' \
                   'before lowering the then-body. Hoisted temps from a ' \
                   '`maybe() OR_ELSE ""` cond then leak into the then-body, ' \
                   'declared after the cond that references them. The ' \
                   'cond_or_fallback :if cells fail to compile (Zig: ' \
                   'use of undeclared identifier __tmp_N).',
      invariant: :bug1_hoist_ordering,
      patch: File.join(PATCH_DIR, 'lower_if_cond_pending_leak.patch'),
      templates: [:cond_or_fallback],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :cleanup_required_finalizer,
      description: 'Disable MIRChecker cleanup-required finalizer validation. ' \
                   'A frame AllocMark whose Type owns cleanup-bearing data can ' \
                   'then pass without Cleanup/ErrCleanup/TransferMark.',
      invariant: :cleanup_required_finalizer,
      patch: File.join(PATCH_DIR, 'cleanup_required_finalizer.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :loop_frame_scope_stamp,
      description: 'Force loop-local frame allocations to lower as function-' \
                   'scoped. MIRChecker should reject the missing per-' \
                   'iteration scope under loop-local method-call temps.',
      invariant: :bug2_frame_no_rewind,
      patch: File.join(PATCH_DIR, 'local_frame_decls_stdlib_provenance.patch'),
      templates: [:loop_local_method_temp, :loop_rewind_matrix],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :loop_destination_copy_rewind,
      description: 'Hide destination-sensitive COPY reassignment allocations ' \
                   'from loop frame analysis. Every loop and sequential ' \
                   'control-flow shape must still expose the missing rewind.',
      invariant: :destination_copy_frame_rewind,
      patch: File.join(PATCH_DIR, 'loop_destination_copy_rewind_noop.patch'),
      templates: [:loop_rewind_matrix],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :mir_checker_linear_use_after_transfer,
      description: 'Disable MIRChecker linear read-after-transfer detection. ' \
                   'Malformed MIR that reads a binding after TransferMark must ' \
                   'be rejected by the negative MIR matrix.',
      invariant: :ownership_use_after_transfer,
      patch: File.join(PATCH_DIR, 'mir_checker_skip_linear_use_after_transfer.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :mir_checker_inline_alloc_mismatch,
      description: 'Disable MIRChecker inline allocator mismatch detection. ' \
                   'Allocator-bearing structural operations must match the ' \
                   'target binding placement.',
      invariant: :inline_alloc_mismatch,
      patch: File.join(PATCH_DIR, 'mir_checker_skip_inline_alloc_mismatch.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :mir_checker_aggregate_child_alloc,
      description: 'Disable aggregate child allocator mismatch detection. ' \
                   'Owned children cannot be stored into aggregates with an ' \
                   'incoherent allocator story.',
      invariant: :aggregate_child_alloc_mismatch,
      patch: File.join(PATCH_DIR, 'mir_checker_skip_aggregate_child_alloc_mismatch.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :mir_checker_cleanup_source_owns,
      description: 'Treat borrowed/non-owning MIR lets as cleanup owners. ' \
                   'The negative matrix must reject cleanup emitted for ' \
                   'borrowed field/index values.',
      invariant: :cleanup_source_owns_value,
      patch: File.join(PATCH_DIR, 'mir_checker_skip_cleanup_source_owns.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :mir_checker_call_contracts,
      description: 'Disable MIRChecker callable-contract validation. Calls ' \
                   'without typed ownership/effect contracts must not pass.',
      invariant: :mir_call_contracts,
      patch: File.join(PATCH_DIR, 'mir_checker_skip_call_contracts.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :hold_lock_across_yield_policy,
      description: 'Disable the front-end hold-lock-across-yield policy. ' \
                   'The diagnostic policy matrix must reject suspending work ' \
                   'inside WITH lock bodies.',
      invariant: :hold_lock_across_yield,
      patch: File.join(PATCH_DIR, 'concurrency_skip_hold_yield.patch'),
      templates: [:diagnostic_policy_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :fn_type_reentrant_constraint,
      description: 'Accept incompatible function-value reentrancy contracts. ' \
                   'Plain reentrant callbacks must not satisfy ' \
                   'REQUIRES cb: NON_REENTRANT parameters.',
      invariant: :fn_type_reentrant_constraint,
      patch: File.join(PATCH_DIR, 'fn_type_reentrant_constraint_accept.patch'),
      templates: [:diagnostic_policy_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :tight_loop_admission_policy,
      description: 'Disable TIGHT-loop body validation. TIGHT loops must ' \
                   'reject plain reentrant calls that may need scheduler ' \
                   'yield checks.',
      invariant: :tight_loop_admission,
      patch: File.join(PATCH_DIR, 'tight_loop_validation_skip.patch'),
      templates: [:diagnostic_policy_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :move_mark_emission,
      description: 'Disable MIREmitter MoveMark output. GIVE/TAKES transfer ' \
                   'paths must still set the moved guard that prevents source ' \
                   'cleanup after transfer.',
      invariant: :move_mark_emission,
      patch: File.join(PATCH_DIR, 'mir_emitter_move_mark_noop.patch'),
      templates: [:call_ownership_contract_matrix, :takes_move_modality, :cleanup_control_matrix],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :capture_promise_handle_by_value,
      description: 'Stop classifying affine promise handles as moved into BG ' \
                   'captures. Reusing the handle after capture must be rejected.',
      invariant: :promise_handle_capture_consumes,
      patch: File.join(PATCH_DIR, 'capture_promise_handle_by_value.patch'),
      templates: [:promise_handle_capture],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :bg_lifetime_all_captures_independent,
      description: 'Erase BG-handle lifetime sources. Handles tied to local, ' \
                   'locked, atomic, or multiowned captures must not be returned ' \
                   'or stored past their source scope.',
      invariant: :bg_handle_lifetime_escape,
      patch: File.join(PATCH_DIR, 'bg_lifetime_all_captures_independent.patch'),
      templates: [:lifetimed_return],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :or_rescue_catch_allocator_identity,
      description: 'Skip destination allocator placement for OR_ELSE/catch fallback ' \
                   'values. Success and fallback branches must preserve one ' \
                   'allocator identity for the resulting binding.',
      invariant: :error_path_allocator_identity,
      patch: File.join(PATCH_DIR, 'or_rescue_skip_catch_placement.patch'),
      templates: [:catch_allocator_matrix],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :escape_identifier_heap_placement,
      description: 'Disable the central identifier heap-placement walker for ' \
                   'escape sinks. Returning, storing, yielding, or capturing ' \
                   'owned frame values must still be caught.',
      invariant: :declaration_provenance_escape_stamping,
      patch: File.join(PATCH_DIR, 'escape_identifier_heap_noop.patch'),
      templates: [:escape_mechanism_matrix],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :ownership_surface_finalization,
      description: 'Disable MIRChecker enforcement that ownership side-channel ' \
                   'metadata is finalized into Owned* facts before checking.',
      invariant: :ownership_surface_finalization,
      patch: File.join(PATCH_DIR, 'mir_checker_skip_ownership_surface_finalized.patch'),
      templates: [:mir_checker_negative_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :union_match_drops_payload_capture,
      description: 'Render union match arms without payload captures. The union ' \
                   'cleanup/match matrix must fail if payload values are not bound.',
      invariant: :union_payload_match_binding,
      patch: File.join(PATCH_DIR, 'union_match_drops_payload_capture.patch'),
      templates: [:union_lowering_cleanup_matrix],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :fsm_suspend_returns_done,
      description: 'Return Done instead of yielding from FSM suspend tails. ' \
                   'FSM suspension cells must fail if suspend/resume state is lost.',
      invariant: :fsm_suspend_resume,
      patch: File.join(PATCH_DIR, 'fsm_suspend_returns_done.patch'),
      templates: [:fsm_suspension_matrix],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :bg_capture_transfer_move_guard,
      description: 'Disable MIREmitter MoveMark output for BG/DO capture ' \
                   'transfer shapes. Captures that move owned roots across an ' \
                   'execution boundary must not leave the source cleanup live.',
      invariant: :bg_capture_transfer_move_guard,
      patch: File.join(PATCH_DIR, 'mir_emitter_move_mark_noop.patch'),
      templates: [:bg_capture_transfer_matrix],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :branch_cleanup_emits_finalizers,
      description: 'Disable cleanup emission for branch-local owned values. ' \
                   'Branch exits must still run finalizers on every live path.',
      invariant: :branch_cleanup_finalizers,
      patch: File.join(PATCH_DIR, 'mir_emitter_cleanup_noop.patch'),
      templates: [
        :branch_cleanup,
        :bind_capture_cleanup,
        :link_resolve_matrix,
        :managed_payload_capability_matrix,
        :node_graph_matrix,
        :rc_generic_collection_matrix,
        :rc_generic_value_matrix,
        :stateful_container_matrix,
      ],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :error_cleanup_emits_finalizers,
      description: 'Disable cleanup emission for error-path owned values. OR_ELSE, ' \
                   'RAISE, and DEFAULT paths must still clean or transfer owned roots.',
      invariant: :error_cleanup_finalizers,
      patch: File.join(PATCH_DIR, 'mir_emitter_cleanup_noop.patch'),
      templates: [:error_cleanup],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :escape_via_return_heap_placement,
      description: 'Disable the identifier heap-placement walker for returned ' \
                   'owned values. Returning frame-owned cleanup-bearing values ' \
                   'must still promote or reject before backend emission.',
      invariant: :return_escape_heap_placement,
      patch: File.join(PATCH_DIR, 'escape_identifier_heap_noop.patch'),
      templates: [:escape_via_return],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :execution_boundary_parallel_policy,
      description: 'Allow unsafe captures through parallel execution-boundary ' \
                   'validation. Boundary admission must reject non-transferable ' \
                   'values instead of silently compiling them.',
      invariant: :parallel_boundary_admission,
      patch: File.join(PATCH_DIR, 'execution_boundary_parallel_accept.patch'),
      templates: [:execution_boundary, :recursive_execution_boundary_matrix, :shared_node_graph_matrix],
      kill: { bucket: :unexpected_pass, min_delta: 1 }
    ),
    Mutant.new(
      name: :list_append_move_guard,
      description: 'Disable MoveMark output for list append transfer paths. ' \
                   'Appending cleanup-bearing values to heap lists must move ' \
                   'the source or preserve safe cleanup ownership.',
      invariant: :list_append_move_guard,
      patch: File.join(PATCH_DIR, 'mir_emitter_move_mark_noop.patch'),
      templates: [:list_append_modality],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :loop_carry_frame_scope,
      description: 'Force loop-local frame allocations to lower as function-' \
                   'scoped for loop-carried collections. Loop rewinds must not ' \
                   'leave dangling per-iteration storage behind.',
      invariant: :loop_carry_frame_scope,
      patch: File.join(PATCH_DIR, 'local_frame_decls_stdlib_provenance.patch'),
      templates: [:loop_carry_collection],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :loop_cleanup_emits_finalizers,
      description: 'Disable cleanup emission for loop disruptor paths. BREAK, ' \
                   'CONTINUE, RETURN, and RAISE must still finalize owned loop locals.',
      invariant: :loop_cleanup_finalizers,
      patch: File.join(PATCH_DIR, 'mir_emitter_cleanup_noop.patch'),
      templates: [:loop_cleanup],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :lowering_boundary_move_guard,
      description: 'Disable MoveMark output for lowering-boundary transfer ' \
                   'shapes. Lowered WITH, BG/DO/NEXT, pipeline, and call ' \
                   'boundaries must preserve transfer guards.',
      invariant: :lowering_boundary_move_guard,
      patch: File.join(PATCH_DIR, 'mir_emitter_move_mark_noop.patch'),
      templates: [:lowering_boundary_matrix],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :mutable_collection_param_pointer_passing,
      description: 'Stop lowering mutable collection arguments as pointer ' \
                   'arguments. Forwarded mutations must remain visible through ' \
                   'the declared param contract.',
      invariant: :mutable_collection_param_pointer,
      patch: File.join(PATCH_DIR, 'function_arg_pointer_noop.patch'),
      templates: [:mutable_collection_param],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :or_heap_destination_branch_placement,
      description: 'Disable destination placement for owned OR_ELSE branch values. ' \
                   'Success and fallback branches must agree on destination ' \
                   'allocator facts for heap-owned results.',
      invariant: :or_branch_destination_placement,
      patch: File.join(PATCH_DIR, 'owned_branch_destination_noop.patch'),
      templates: [:or_heap_destination_matrix],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :or_positional_branch_placement,
      description: 'Disable destination placement for owned OR_ELSE values in ' \
                   'different syntactic positions. Positional OR_ELSE lowering must ' \
                   'keep cleanup and allocator facts coherent.',
      invariant: :or_positional_destination_placement,
      patch: File.join(PATCH_DIR, 'owned_branch_destination_noop.patch'),
      templates: [:or_positional],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :owned_sink_destination_heap_placement,
      description: 'Disable identifier heap-placement for owned values crossing ' \
                   'return, field, list, map, TAKES, and call sinks. Sink ' \
                   'destinations must still receive coherent ownership facts.',
      invariant: :owned_sink_heap_placement,
      patch: File.join(PATCH_DIR, 'escape_identifier_heap_noop.patch'),
      templates: [:owned_sink_destination_matrix],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
    Mutant.new(
      name: :return_value_branch_placement,
      description: 'Disable destination placement for owned branch values that ' \
                   'feed returns. Return contexts must still promote, clean, or ' \
                   'reject cleanup-bearing branch results.',
      invariant: :return_branch_destination_placement,
      patch: File.join(PATCH_DIR, 'owned_branch_destination_noop.patch'),
      templates: [:return_value_modality],
      kill: { bucket: :fail, min_delta: 1 }
    ),
    Mutant.new(
      name: :stream_boundary_move_guard,
      description: 'Disable MoveMark output for stream values crossing ' \
                   'execution boundaries. STREAM NEXT transfer paths must not ' \
                   'double-clean or leak moved values.',
      invariant: :stream_boundary_move_guard,
      patch: File.join(PATCH_DIR, 'mir_emitter_move_mark_noop.patch'),
      templates: [:stream_into_boundary],
      kill: { bucket: :leak, min_delta: 1 }
    ),
    Mutant.new(
      name: :struct_field_store_heap_placement,
      description: 'Disable identifier heap-placement for cleanup-bearing values ' \
                   'stored into heap struct fields. Field stores must preserve ' \
                   'owned child allocation and cleanup facts.',
      invariant: :struct_field_store_heap_placement,
      patch: File.join(PATCH_DIR, 'escape_identifier_heap_noop.patch'),
      templates: [:struct_field_store_modality],
      kill: { bucket: :mir_error, min_delta: 1 }
    ),
  ].freeze, T::Array[Mutant])

  sig { params(name: T.any(String, Symbol)).returns(T.nilable(Mutant)) }
  def self.find(name)
    REGISTRY.find { |m| m.name == name.to_sym }
  end
end
