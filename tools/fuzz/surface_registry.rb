# Ownership-safety surface registry for the fuzz harness.
#
# This is the source of truth the fuzz coverage reporter uses to decide
# whether a template is exercising the full surface it claims to cover. Keep
# this registry broader than today's templates; uncovered entries are useful
# signal, not noise.

module FuzzSurfaceRegistry
  SURFACES = {
    storage_capabilities: [
      :plain,
      :local,
      :multiowned,
      :shared,
      :indirect,
    ],

    sync_capabilities: [
      :locked,
      :write_locked,
      :versioned,
      :atomic,
    ],

    cleanup_value_shapes: [
      :string,
      :frame_string_concat,
      :dynamic_array,
      :frame_list,
      :heap_list,
      :pool,
      :set,
      :hash_map,
      :sharded_list,
      :sharded_pool,
      :sharded_set,
      :sharded_hash_map,
      :soa_list,
      :soa_pool,
      :struct_owned_fields,
      :union_owned_payload,
      :option_owned_payload,
      :nested_container,
    ],

    collection_shapes: [
      :dynamic_array,
      :list,
      :pool,
      :set,
      :hash_map,
      :sharded_list,
      :sharded_pool,
      :sharded_set,
      :sharded_hash_map,
      :soa_list,
      :soa_pool,
      :nested_collection,
    ],

    escape_sources: [
      :frame_local,
      :loop_local,
      :function_param,
      :with_alias,
      :stream_next,
      :bg_capture,
      :bg_stream_capture,
      :do_capture,
      :fsm_suspend,
      :or_expression,
    ],

    escape_sinks: [
      :return_value,
      :struct_field_store,
      :list_append,
      :set_insert,
      :map_put,
      :pool_insert,
      :collection_literal,
      :function_arg,
      :takes_arg,
      :give_arg,
      :bg_handle_return,
      :bg_handle_field_store,
      :bg_capture,
      :do_capture,
      :bg_stream_capture,
    ],

    execution_boundaries: [
      :bg,
      :do,
      :bg_stream,
      :fsm_suspend,
      :stream_pipeline,
      :future_promise,
    ],

    mir_ownership_contracts: [
      :promotion_on_escape,
      :cleanup_on_all_paths,
      :loop_frame_rewind,
      :error_path_allocator_identity,
      :move_suppresses_cleanup,
      :alias_non_escape,
      :bg_lifetime_enforcement,
      :collection_mutation_visible_to_mir,
      :non_copy_requires_explicit_move_or_copy,
    ],
  }.freeze

  # Baseline coverage map for the templates that exist today. Phase 1 moves
  # this metadata next to each template; keeping it centralized first gives us
  # a useful coverage report without changing every renderer at once.
  TEMPLATE_COVERAGE = {
    escape_via_return: {
      cleanup_value_shapes: [:heap_list],
      escape_sources: [:frame_local],
      escape_sinks: [:return_value],
      mir_ownership_contracts: [:promotion_on_escape],
    },

    # Truthful owner of takes_arg/give_arg across owning collection shapes.
    # access_gate also claims takes_arg/give_arg but only for a struct
    # (Counter); the taxonomy not crossing sink x shape is why the
    # collection-shape gap was masked (#41).
    takes_move_modality: {
      collection_shapes: [:list, :set, :pool, :hash_map, :dynamic_array],
      escape_sinks: [:takes_arg, :give_arg],
      mir_ownership_contracts: [:move_suppresses_cleanup],
    },

    loop_carry_collection: {
      cleanup_value_shapes: [:heap_list, :frame_string_concat],
      escape_sources: [:loop_local],
      mir_ownership_contracts: [:loop_frame_rewind, :promotion_on_escape],
    },

    mutable_collection_param: {
      cleanup_value_shapes: [:heap_list],
      collection_shapes: [:list],
      escape_sources: [:function_param],
      escape_sinks: [:function_arg],
      mir_ownership_contracts: [:collection_mutation_visible_to_mir],
    },

    nested_loop_escape: {
      cleanup_value_shapes: [:heap_list, :frame_list],
      collection_shapes: [:dynamic_array, :list],
      escape_sources: [:loop_local],
      escape_sinks: [:list_append],
      mir_ownership_contracts: [:promotion_on_escape, :loop_frame_rewind],
    },

    collection_shape_smoke: {
      collection_shapes: [
        :dynamic_array,
        :list,
        :pool,
        :set,
        :hash_map,
        :sharded_list,
        :sharded_pool,
        :sharded_set,
        :sharded_hash_map,
        :soa_list,
        :soa_pool,
        :nested_collection,
      ],
    },

    ownership_surface_smoke: {
      cleanup_value_shapes: [
        :string,
        :frame_string_concat,
        :dynamic_array,
        :frame_list,
        :heap_list,
        :pool,
        :set,
        :hash_map,
        :sharded_list,
        :sharded_pool,
        :sharded_set,
        :sharded_hash_map,
        :soa_list,
        :soa_pool,
        :struct_owned_fields,
        :union_owned_payload,
        :option_owned_payload,
        :nested_container,
      ],
      escape_sinks: [
        :return_value,
        :struct_field_store,
        :list_append,
        :set_insert,
        :map_put,
        :pool_insert,
        :collection_literal,
        :function_arg,
      ],
      mir_ownership_contracts: [
        :promotion_on_escape,
        :cleanup_on_all_paths,
        :loop_frame_rewind,
        :error_path_allocator_identity,
        :alias_non_escape,
        :bg_lifetime_enforcement,
        :collection_mutation_visible_to_mir,
        :non_copy_requires_explicit_move_or_copy,
      ],
    },

    loop_cleanup: {
      cleanup_value_shapes: [:heap_list, :string, :frame_string_concat, :frame_list],
      escape_sources: [:loop_local],
      escape_sinks: [:list_append],
      mir_ownership_contracts: [:cleanup_on_all_paths, :loop_frame_rewind, :promotion_on_escape],
    },

    error_cleanup: {
      cleanup_value_shapes: [:heap_list, :string, :frame_string_concat, :frame_list],
      escape_sources: [:or_expression],
      mir_ownership_contracts: [:cleanup_on_all_paths, :error_path_allocator_identity],
    },

    branch_cleanup: {
      cleanup_value_shapes: [:heap_list, :string, :frame_string_concat, :frame_list],
      mir_ownership_contracts: [:cleanup_on_all_paths],
    },

    or_positional: {
      cleanup_value_shapes: [:heap_list, :string],
      escape_sources: [:or_expression],
      escape_sinks: [:return_value, :list_append, :collection_literal, :function_arg],
      mir_ownership_contracts: [:cleanup_on_all_paths, :error_path_allocator_identity],
    },

    access_gate: {
      sync_capabilities: [:locked, :write_locked, :versioned],
      escape_sources: [:with_alias],
      escape_sinks: [:return_value, :struct_field_store, :list_append, :takes_arg, :give_arg, :bg_capture, :do_capture, :bg_stream_capture],
      mir_ownership_contracts: [:alias_non_escape, :non_copy_requires_explicit_move_or_copy],
    },

    lifetimed_return: {
      storage_capabilities: [:local],
      escape_sources: [:bg_capture, :bg_stream_capture],
      escape_sinks: [:bg_handle_return, :bg_handle_field_store],
      execution_boundaries: [:bg, :bg_stream],
      mir_ownership_contracts: [:bg_lifetime_enforcement],
    },

    execution_boundary: {
      storage_capabilities: [:local, :multiowned, :shared],
      sync_capabilities: [:locked],
      execution_boundaries: [:bg, :do, :bg_stream],
    },

    promise_handle_capture: {
      escape_sources: [:bg_capture],
      escape_sinks: [:bg_capture],
      execution_boundaries: [:bg, :future_promise],
      mir_ownership_contracts: [:move_suppresses_cleanup, :non_copy_requires_explicit_move_or_copy],
    },

    stream_into_boundary: {
      storage_capabilities: [:local, :shared],
      sync_capabilities: [:locked, :write_locked, :versioned, :atomic],
      cleanup_value_shapes: [:string, :struct_owned_fields],
      escape_sources: [:stream_next],
      execution_boundaries: [:bg, :do, :bg_stream],
    },

    polymorphic_sync_admission: {
      storage_capabilities: [:plain, :local, :multiowned],
      sync_capabilities: [:locked, :write_locked, :versioned],
    },
  }.freeze

  # Dimensions that are intentionally covered by the union of focused
  # templates. These are broad surfaces; forcing every semantic template to
  # cover every member creates noisy false gaps.
  GLOBAL_REQUIRED_SURFACES = [
    :cleanup_value_shapes,
    :escape_sinks,
    :mir_ownership_contracts,
  ].freeze

  REQUIRED_SURFACES_BY_TEMPLATE = {
    collection_shape_smoke: [:collection_shapes],
  }.freeze

  def self.surface(name)
    SURFACES.fetch(name)
  end

  def self.covered(template, surface)
    TEMPLATE_COVERAGE.fetch(template, {}).fetch(surface, [])
  end
end
