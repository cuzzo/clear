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

    escape_mechanism_matrix: {
      cleanup_value_shapes: [:string, :heap_list, :struct_owned_fields],
      collection_shapes: [:list, :pool, :set, :hash_map],
      escape_sources: [:frame_local, :loop_local, :function_param, :bg_capture, :bg_stream_capture, :or_expression, :stream_next],
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
        :bg_capture,
        :bg_stream_capture,
      ],
      execution_boundaries: [:bg, :bg_stream],
      mir_ownership_contracts: [:promotion_on_escape, :cleanup_on_all_paths, :collection_mutation_visible_to_mir],
    },

    # 89-cell ret_form x bind_form x decl matrix for :heap_list / :string
    # (the deep RET×BIND axis from origin/register-machine #13). The
    # complementary breadth-across-all-shapes axis is return_value_modality.
    heap_ownership_transfer: {
      cleanup_value_shapes: [:heap_list, :string],
      escape_sinks: [:return_value],
      mir_ownership_contracts: [:promotion_on_escape, :cleanup_on_all_paths,
                                 :error_path_allocator_identity, :move_suppresses_cleanup],
    },

    # Truthful owner of :return_value across EVERY value shape -- the breadth
    # axis complementing heap_ownership_transfer's depth on list/string. Cells
    # enumerated from the registry, not hand-picked.
    return_value_modality: {
      cleanup_value_shapes: [
        :string, :dynamic_array, :heap_list, :pool, :set, :hash_map,
        :sharded_list, :sharded_pool, :sharded_set, :sharded_hash_map,
        :soa_list, :soa_pool,
        :struct_owned_fields, :union_owned_payload, :option_owned_payload, :nested_container,
      ],
      escape_sinks: [:return_value],
      mir_ownership_contracts: [:promotion_on_escape],
    },

    # Truthful owner of :struct_field_store across EVERY value shape. Cells
    # enumerated from the registry (ASSIGN_INTO_HEAP_VALUE_SHAPES -- adds the
    # caller-side frame_* shapes that ownership_surface_smoke claims but
    # doesn't actually emit per shape x modality).
    struct_field_store_modality: {
      cleanup_value_shapes: [
        :string, :frame_string_concat, :dynamic_array, :frame_list, :heap_list,
        :pool, :set, :hash_map,
        :sharded_list, :sharded_pool, :sharded_set, :sharded_hash_map,
        :soa_list, :soa_pool,
        :struct_owned_fields, :union_owned_payload, :option_owned_payload, :nested_container,
      ],
      escape_sinks: [:struct_field_store],
      mir_ownership_contracts: [:move_suppresses_cleanup, :cleanup_on_all_paths],
    },

    # Truthful owner of :list_append across EVERY element value shape (the
    # ASSIGN_INTO_HEAP_VALUE_SHAPES superset). Many element-type x list-of
    # combinations may be language-illegal -- such cells are :in_dev with a
    # "language-not-supported" tag rather than silently omitted.
    list_append_modality: {
      cleanup_value_shapes: [
        :string, :frame_string_concat, :dynamic_array, :frame_list, :heap_list,
        :pool, :set, :hash_map,
        :sharded_list, :sharded_pool, :sharded_set, :sharded_hash_map,
        :soa_list, :soa_pool,
        :struct_owned_fields, :union_owned_payload, :option_owned_payload, :nested_container,
      ],
      escape_sinks: [:list_append],
      mir_ownership_contracts: [:move_suppresses_cleanup, :cleanup_on_all_paths],
    },

    # Truthful owner of takes_arg/give_arg across EVERY callee-param value
    # shape. Cells enumerated from the registry, not hand-picked (#41 cross-
    # cut is what gates this template now).
    takes_move_modality: {
      cleanup_value_shapes: [
        :string, :dynamic_array, :heap_list, :pool, :set, :hash_map,
        :sharded_list, :sharded_pool, :sharded_set, :sharded_hash_map,
        :soa_list, :soa_pool,
        :struct_owned_fields, :union_owned_payload, :option_owned_payload, :nested_container,
      ],
      collection_shapes: [
        :dynamic_array, :list, :pool, :set, :hash_map,
        :sharded_list, :sharded_pool, :sharded_set, :sharded_hash_map,
        :soa_list, :soa_pool, :nested_collection,
      ],
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
      cleanup_value_shapes: [:struct_owned_fields],
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

  # Cross-cut sinks where value-shape matters. A sink isn't truly covered
  # unless the templates claiming it collectively touch each of the listed
  # shapes. Required shapes are the FULL :cleanup_value_shapes catalog --
  # not a hand-picked subset (which was what hid #37/#39/#40/#42/#43).
  # `:frame_*` shapes are caller-side temporaries, not callee param TYPES,
  # so they are excluded from sinks that name a *type* (takes_arg/give_arg/
  # return_value); they ARE valid for assign-into-heap sinks like
  # struct_field_store / list_append. coverage.rb unions cleanup_value_shapes
  # declarations across templates whose escape_sinks include the sink and
  # reports any missing.
  CALLEE_PARAM_VALUE_SHAPES = %i[
    string dynamic_array heap_list pool set hash_map
    sharded_list sharded_pool sharded_set sharded_hash_map
    soa_list soa_pool
    struct_owned_fields union_owned_payload option_owned_payload nested_container
  ].freeze

  ASSIGN_INTO_HEAP_VALUE_SHAPES = (CALLEE_PARAM_VALUE_SHAPES + %i[frame_string_concat frame_list]).freeze

  SINK_REQUIRES_SHAPES = {
    takes_arg:          CALLEE_PARAM_VALUE_SHAPES,
    give_arg:           CALLEE_PARAM_VALUE_SHAPES,
    return_value:       CALLEE_PARAM_VALUE_SHAPES,
    struct_field_store: ASSIGN_INTO_HEAP_VALUE_SHAPES,
    list_append:        ASSIGN_INTO_HEAP_VALUE_SHAPES,
  }.freeze

  def self.surface(name)
    SURFACES.fetch(name)
  end

  def self.covered(template, surface)
    TEMPLATE_COVERAGE.fetch(template, {}).fetch(surface, [])
  end

  # Templates whose escape_sinks coverage includes the given sink.
  def self.templates_covering_sink(sink)
    TEMPLATE_COVERAGE.select { |_, cov| Array(cov[:escape_sinks]).include?(sink) }.keys
  end
end
