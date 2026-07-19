# frozen_string_literal: true

# Executable inventory for the full semantic-generator completion contract.
# This deliberately mirrors docs/agents/csmith.md so scope cannot be narrowed
# by prose after implementation begins.
module SemanticCompletion
  PHASE_TARGETS = {
    int64_distinct_cases: 1_000,
    per_enabled_value_family: 1_000,
    deterministic_depths: (0..3).freeze,
    full_migrations: 11,
    hybrid_refactors: 43,
    known_language_gaps: 6,
    total_discovered_gaps: 21,
    outstanding_gaps: 0,
  }.freeze

  LANGUAGE_GAPS = %i[
    contextual_nil_or_else
    direct_struct_literal_field
    unused_pipeline_capture
    int_min_max_projection
    nested_pipeline_expression
    nested_owned_map
  ].freeze

  FULL_MIGRATIONS = %i[
    access_path_expression_matrix
    binary_op_matrix
    builtin_emit_matrix
    cast_lowering_matrix
    collection_shape_smoke
    managed_payload_capability_matrix
    mir_lowering_shape_matrix
    pipeline_source_shape_matrix
    rc_generic_value_matrix
    return_value_modality
    tuple_collection_composition_matrix
  ].freeze

  HYBRID_REFACTORS = %i[
    bind_capture_cleanup
    branch_cleanup
    call_ownership_contract_matrix
    catch_allocator_matrix
    catch_reassign_matrix
    cleanup_classifier_shapes
    cleanup_control_matrix
    collection_iteration_storage_matrix
    collection_sink_escape_matrix
    cond_or_fallback
    destructuring_assignment_matrix
    error_cleanup
    escape_mechanism_matrix
    escape_via_return
    heap_ownership_transfer
    hoist_edge_matrix
    indexed_assignment_matrix
    indirect_recursive_union
    list_append_modality
    loop_carry_collection
    loop_cleanup
    loop_local_cleanup_alloc
    loop_local_method_temp
    lowering_boundary_matrix
    match_matrix
    match_payload_cleanup
    mutable_collection_param
    nested_loop_escape
    or_heap_destination_matrix
    or_positional
    owned_sink_destination_matrix
    ownership_surface_smoke
    pipeline_gap_matrix
    pipeline_value_block_matrix
    rc_generic_collection_matrix
    stateful_container_matrix
    struct_field_store_modality
    takes_move_modality
    union_lowering_cleanup_matrix
    bg_capture_transfer_matrix
    capability_wrap_matrix
    cross_fiber_consumer
    link_resolve_matrix
  ].freeze

  UNIQUE_HYBRID_REFACTORS = HYBRID_REFACTORS.uniq.freeze

  KEEP_EXPLICIT = %i[
    access_gate
    auto_inference_matrix
    auto_ownership_transport_matrix
    bg_capture_typing
    bg_copy_param_reentrant
    c_ffi_type_matrix
    curated_gap_corpus
    diagnostic_policy_matrix
    execution_boundary
    extern_boundary_matrix
    fsm_edge_matrix
    fsm_suspension_matrix
    generic_map_protocol_matrix
    generic_shared_map_capability_matrix
    infallible_signature
    inherent_method_matrix
    lifetimed_return
    mir_checker_negative_matrix
    node_graph_matrix
    polymorphic_sync_admission
    promise_handle_capture
    recursive_execution_boundary_matrix
    shared_node_graph_matrix
    stream_into_boundary
    tense_predicate_matrix
    test_framework_matrix
    thunk_recursion_matrix
  ].freeze

  module_function

  def validate!(registered_templates: nil)
    errors = []
    errors << "expected 11 full migrations, got #{FULL_MIGRATIONS.length}" unless FULL_MIGRATIONS.length == PHASE_TARGETS.fetch(:full_migrations)
    errors << "design names only #{UNIQUE_HYBRID_REFACTORS.length} unique hybrid templates, not 43" unless UNIQUE_HYBRID_REFACTORS.length == PHASE_TARGETS.fetch(:hybrid_refactors)
    errors << "expected 6 language gaps, got #{LANGUAGE_GAPS.length}" unless LANGUAGE_GAPS.length == PHASE_TARGETS.fetch(:known_language_gaps)

    require_relative 'semantic_gaps'
    gap_report = SemanticGaps.report
    errors << "expected 21 discovered gaps, got #{gap_report.fetch(:discovered)}" unless gap_report.fetch(:discovered) == PHASE_TARGETS.fetch(:total_discovered_gaps)
    errors << "expected no outstanding gaps, got #{gap_report.fetch(:outstanding)}" unless gap_report.fetch(:outstanding) == PHASE_TARGETS.fetch(:outstanding_gaps)
    errors << 'not every fixed gap has an active raw witness' unless SemanticGaps::ALL.all? { |gap| !gap.witness.to_s.strip.empty? }

    if registered_templates
      missing = (FULL_MIGRATIONS + UNIQUE_HYBRID_REFACTORS + KEEP_EXPLICIT).uniq - registered_templates.map(&:to_sym)
      errors << "unknown completion templates: #{missing.join(', ')}" unless missing.empty?
    end

    raise errors.join('; ') unless errors.empty?
    true
  end
end
