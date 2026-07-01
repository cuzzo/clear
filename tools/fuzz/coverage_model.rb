# typed: strict
# Machine-readable coverage model for tools/fuzz.

require 'sorbet-runtime'
require 'set'

module FuzzCoverageModel
  extend T::Sig

  VALID_SOURCE_KINDS = T.let(
    Set[:source, :modeled_mir, :curated_source].freeze,
    T::Set[Symbol]
  )
  VALID_MATRIX_STRATEGIES = T.let(
    Set[:exhaustive, :smoke, :curated, :bounded_pairwise].freeze,
    T::Set[Symbol]
  )
  FULL_EXPANSION_STRATEGIES = T.let(
    Set[:exhaustive].freeze,
    T::Set[Symbol]
  )

  class TemplateProfile < T::Struct
    const :source_kind, Symbol
    const :matrix_strategy, Symbol
    const :failure_proves, String
    const :known_exclusions, T::Array[String], default: []
    const :high_risk, T::Boolean, default: false
  end

  class TemplateSnapshot < T::Struct
    const :name, Symbol
    const :cell_count, Integer
    const :expected_counts, T::Hash[Symbol, Integer]
    const :coverage, T::Hash[Symbol, T::Array[Symbol]]
    const :profile, TemplateProfile
  end

  class CrossProductRequirement < T::Struct
    const :name, Symbol
    const :severity, Symbol
    const :left_surface, Symbol
    const :right_surface, Symbol
    const :required_pairs, T::Array[[Symbol, Symbol]]
  end

  sig do
    params(
      failure_proves: String,
      high_risk: T::Boolean,
      known_exclusions: T::Array[String],
      matrix_strategy: Symbol,
      source_kind: Symbol
    ).returns(TemplateProfile)
  end
  def self.profile(failure_proves:, high_risk: false, known_exclusions: [], matrix_strategy: :exhaustive, source_kind: :source)
    TemplateProfile.new(
      source_kind: source_kind,
      matrix_strategy: matrix_strategy,
      failure_proves: failure_proves,
      known_exclusions: known_exclusions,
      high_risk: high_risk
    )
  end

  TEMPLATE_PROFILES = T.let({
    access_gate: profile(
      failure_proves: 'WITH aliases cannot escape through returns, stores, captures, or consuming calls.',
      high_risk: true
    ),
    access_path_expression_matrix: profile(
      failure_proves: 'Field, index, optional, map, and nested access paths preserve cleanup and allocator facts.'
    ),
    auto_inference_matrix: profile(
      failure_proves: 'Auto inference accepts concrete solvable positions and rejects unresolved/ambiguous ones.'
    ),
    bg_capture_transfer_matrix: profile(
      failure_proves: 'BG/DO/BG STREAM captures transfer owned roots without losing cleanup or lifetime facts.',
      high_risk: true
    ),
    bg_capture_typing: profile(
      failure_proves: 'BG capture typing keeps inferred capture values available to the backend.'
    ),
    bg_copy_param_reentrant: profile(
      failure_proves: 'COPY of list parameters into reentrant BG calls keeps ownership independent.'
    ),
    binary_op_matrix: profile(
      failure_proves: 'Binary operator admission and lowering produce valid typed MIR/Zig for supported operands.'
    ),
    bind_capture_cleanup: profile(
      failure_proves: 'Bind-expression captures clean optional and list payloads on every exit path.'
    ),
    branch_cleanup: profile(
      failure_proves: 'Branch-local cleanup-bearing allocations are cleaned across both arms and early exits.',
      high_risk: true
    ),
    builtin_emit_matrix: profile(
      failure_proves: 'Builtin emission preserves cleanup-bearing arguments and stream/pipeline values.'
    ),
    call_ownership_contract_matrix: profile(
      failure_proves: 'Normal, TAKES, GIVE, receiver, BG, and pipeline calls obey ownership contracts.',
      high_risk: true
    ),
    capability_wrap_matrix: profile(
      failure_proves: 'Capability wrapper construction admits valid wrappers and rejects invalid combinations.'
    ),
    cast_lowering_matrix: profile(
      failure_proves: 'Annotation-driven casts/coercions lower without losing cleanup obligations.'
    ),
    catch_allocator_matrix: profile(
      failure_proves: 'Catch fallback paths keep owned destination allocator identity coherent.',
      high_risk: true
    ),
    catch_reassign_matrix: profile(
      failure_proves: 'Catch fallback reassignment preserves ownership facts for replaced values.'
    ),
    cleanup_classifier_shapes: profile(
      failure_proves: 'CleanupClassifier recognizes ownership-bearing struct, union, option, capability, and pipeline shapes.'
    ),
    cleanup_control_matrix: profile(
      failure_proves: 'Cleanup-bearing values are cleaned or transferred through branch, loop, match, catch, return, GIVE, and discard paths.',
      high_risk: true
    ),
    collection_iteration_storage_matrix: profile(
      failure_proves: 'Collection iteration/storage keeps loop-frame and collection-mutation ownership facts coherent.'
    ),
    collection_shape_smoke: profile(
      failure_proves: 'Every registered collection/container shape remains syntactically admitted or intentionally rejected.',
      matrix_strategy: :smoke
    ),
    collection_sink_escape_matrix: profile(
      failure_proves: 'Owned values stored into list/set/map/pool and collection literals keep cleanup facts visible.'
    ),
    cond_or_fallback: profile(
      failure_proves: 'OR fallback values inside conditions are hoisted before branch bodies read their temporaries.'
    ),
    cross_fiber_consumer: profile(
      failure_proves: 'Cross-fiber producer/consumer values remain owned and cleaned across fiber boundaries.'
    ),
    curated_gap_corpus: profile(
      failure_proves: 'Historical transpile-test regressions still compile through the fuzz compile path.',
      matrix_strategy: :curated,
      source_kind: :curated_source,
      known_exclusions: ['Not dimension-exhaustive; each corpus file is a preserved regression program.']
    ),
    diagnostic_policy_matrix: profile(
      failure_proves: 'Policy diagnostics for reentrancy, lock ordering, handlers, and ownership reject unsafe code.'
    ),
    destructuring_assignment_matrix: profile(
      failure_proves: 'Fixed-shape destructuring declarations, assignments, mutable targets, and discards lower directly.'
    ),
    error_cleanup: profile(
      failure_proves: 'Error paths clean or transfer owned values under OR PASS, RAISE, and DEFAULT.',
      high_risk: true
    ),
    escape_mechanism_matrix: profile(
      failure_proves: 'Escape-analysis entry points heap-place owned values for returns, stores, captures, and consuming calls.',
      high_risk: true
    ),
    escape_via_return: profile(
      failure_proves: 'Frame-owned cleanup-bearing values returned from functions are promoted or rejected correctly.',
      high_risk: true
    ),
    execution_boundary: profile(
      failure_proves: 'BG/DO/BG STREAM admission rejects values that cannot safely cross execution boundaries.',
      high_risk: true
    ),
    extern_boundary_matrix: profile(
      failure_proves: 'Extern boundary declarations and calls reject unsupported ownership/effect combinations.'
    ),
    fsm_edge_matrix: profile(
      failure_proves: 'FSM splitting preserves ownership across OR fallback, nested suspension, streams, and locks.'
    ),
    fsm_suspension_matrix: profile(
      failure_proves: 'FSM suspension/resume segments preserve owned suspend results, lock segments, and cleanup.',
      high_risk: true
    ),
    heap_ownership_transfer: profile(
      failure_proves: 'Heap list/string returns preserve promotion, cleanup, allocator identity, and move suppression.'
    ),
    hoist_edge_matrix: profile(
      failure_proves: 'Nested allocating expressions are hoisted before use while preserving cleanup facts.'
    ),
    indexed_assignment_matrix: profile(
      failure_proves: 'Indexed list/map assignment preserves owned element cleanup across value shapes.'
    ),
    indirect_recursive_union: profile(
      failure_proves: 'Recursive union payloads through indirect storage preserve cleanup and type facts.'
    ),
    infallible_signature: profile(
      failure_proves: 'Infallible function signatures accept valid returns and reject fallible/control-flow mismatches.'
    ),
    lifetimed_return: profile(
      failure_proves: 'BG handles tied to lifetime-bound captures cannot escape their source scope.',
      high_risk: true
    ),
    list_append_modality: profile(
      failure_proves: 'Every cleanup-bearing element shape appended to heap lists is cleaned or transferred correctly.',
      high_risk: true,
      known_exclusions: ['Unsupported list element shapes are represented as expected compile-error cells.']
    ),
    loop_carry_collection: profile(
      failure_proves: 'Loop-carried collections are promoted or rewound without dangling frame-owned storage.',
      high_risk: true
    ),
    loop_cleanup: profile(
      failure_proves: 'Loop disruptors pair owned allocations with cleanup on break, continue, return, and raise.',
      high_risk: true
    ),
    loop_local_cleanup_alloc: profile(
      failure_proves: 'Loop-local allocation forms are consistently cleaned or promoted.'
    ),
    loop_local_method_temp: profile(
      failure_proves: 'Method-call temporaries inside loops keep per-iteration frame scope facts.'
    ),
    lowering_boundary_matrix: profile(
      failure_proves: 'MIR lowering boundaries preserve call contracts, WITH variants, BG/DO/NEXT, and pipeline ownership.',
      high_risk: true
    ),
    match_matrix: profile(
      failure_proves: 'MATCH lowering over union/scalar shapes binds payloads and cleans owned arms.'
    ),
    match_payload_cleanup: profile(
      failure_proves: 'MATCH payload captures clean owned union/option payload values.'
    ),
    mir_checker_negative_matrix: profile(
      failure_proves: 'Malformed MIR ownership facts fail closed with the intended checker diagnostics.',
      high_risk: true,
      source_kind: :modeled_mir
    ),
    mir_lowering_shape_matrix: profile(
      failure_proves: 'MIR lowering shapes for declarations, returns, branches, calls, loops, and dispatch keep ownership facts.'
    ),
    mutable_collection_param: profile(
      failure_proves: 'Mutable collection params retain allocator and mutation visibility across forwarding calls.',
      high_risk: true
    ),
    nested_loop_escape: profile(
      failure_proves: 'Nested loop-local collection escapes force safe promotion for outer-container storage.',
      high_risk: true
    ),
    or_heap_destination_matrix: profile(
      failure_proves: 'Owned OR/TryCatch/optional branch results are placed into destination allocators coherently.',
      high_risk: true
    ),
    or_positional: profile(
      failure_proves: 'OR actions in every syntactic position preserve cleanup and error-path ownership.',
      high_risk: true
    ),
    owned_sink_destination_matrix: profile(
      failure_proves: 'Owned source expressions crossing return, field, list, map, TAKES, and call sinks keep destination facts.',
      high_risk: true
    ),
    ownership_surface_smoke: profile(
      failure_proves: 'The registry-wide ownership surface has at least one smoke program for every declared dimension.',
      matrix_strategy: :smoke
    ),
    pipeline_gap_matrix: profile(
      failure_proves: 'Focused pipeline operator gaps continue to compile and run through lowering/emission.'
    ),
    pipeline_source_shape_matrix: profile(
      failure_proves: 'Pipeline source and terminal shapes preserve cleanup across stream and promise boundaries.'
    ),
    pipeline_value_block_matrix: profile(
      failure_proves: 'Source-level pipeline and lambda value blocks preserve final-expression lowering and reject unsafe block shapes.'
    ),
    polymorphic_sync_admission: profile(
      failure_proves: 'Polymorphic sync admission accepts compatible caller/callee capability families only.'
    ),
    promise_handle_capture: profile(
      failure_proves: 'Affine promise handles moved into BG consumers cannot be reused outside.',
      high_risk: true
    ),
    return_value_modality: profile(
      failure_proves: 'Every cleanup-bearing return shape is promoted, cleaned, or rejected in each return context.',
      high_risk: true
    ),
    stream_into_boundary: profile(
      failure_proves: 'STREAM NEXT values crossing BG/DO/BG STREAM boundaries obey capability and sync rules.',
      high_risk: true
    ),
    struct_field_store_modality: profile(
      failure_proves: 'Every cleanup-bearing value shape stored into a heap struct field preserves ownership facts.',
      high_risk: true
    ),
    takes_move_modality: profile(
      failure_proves: 'Every cleanup-bearing callee-param shape obeys TAKES/GIVE/COPY move semantics.',
      high_risk: true
    ),
    test_framework_matrix: profile(
      failure_proves: 'TEST/WHEN/TEST THAT grammar lowers hooks, lets, stubs, pending tests, and benchmark/profile forms.'
    ),
    thunk_recursion_matrix: profile(
      failure_proves: 'REENTRANT:THUNK recursion preserves owned accumulator and argument cleanup.'
    ),
    union_lowering_cleanup_matrix: profile(
      failure_proves: 'Union helper lowering and recursive payload cleanup keep owned variants reachable.'
    ),
  }.freeze, T::Hash[Symbol, TemplateProfile])

  sig { params(templates: T::Hash[Symbol, T.untyped]).returns(T::Array[TemplateSnapshot]) }
  def self.snapshots(templates)
    templates.keys.sort.map do |name|
      template = T.unsafe(templates.fetch(name))
      counts = T.let(Hash.new(0), T::Hash[Symbol, Integer])
      T.unsafe(template).cells.each do |cell|
        expected = T.unsafe(cell)[:expected] || :pass
        counts[expected] += 1
      end

      TemplateSnapshot.new(
        name: name,
        cell_count: T.unsafe(template).cells.length,
        expected_counts: counts,
        coverage: coverage_for(name),
        profile: TEMPLATE_PROFILES.fetch(name)
      )
    end
  end

  sig { params(template: Symbol).returns(T::Hash[Symbol, T::Array[Symbol]]) }
  def self.coverage_for(template)
    raw = T.unsafe(FuzzSurfaceRegistry)::TEMPLATE_COVERAGE.fetch(template, {})
    coverage = T.let({}, T::Hash[Symbol, T::Array[Symbol]])
    raw.each do |surface, values|
      coverage[surface] = T.cast(values, T::Array[Symbol])
    end
    coverage
  end

  sig { params(templates: T::Hash[Symbol, T.untyped]).returns(T::Array[String]) }
  def self.metadata_gaps(templates)
    names = templates.keys.sort
    profile_names = TEMPLATE_PROFILES.keys.sort
    gaps = T.let([], T::Array[String])

    (names - profile_names).each do |name|
      gaps << "template #{name} is missing P3 scope metadata"
    end
    (profile_names - names).each do |name|
      gaps << "P3 scope metadata references missing template #{name}"
    end

    TEMPLATE_PROFILES.each do |name, profile|
      gaps << "#{name} has invalid source_kind #{profile.source_kind}" unless VALID_SOURCE_KINDS.include?(profile.source_kind)
      unless VALID_MATRIX_STRATEGIES.include?(profile.matrix_strategy)
        gaps << "#{name} has invalid matrix_strategy #{profile.matrix_strategy}"
      end
      if profile.failure_proves.strip.empty?
        gaps << "#{name} has no failure_proves text"
      end
      if profile.matrix_strategy == :bounded_pairwise && profile.known_exclusions.empty?
        gaps << "#{name} uses bounded_pairwise without a rationale"
      end
      if profile.high_risk && !FULL_EXPANSION_STRATEGIES.include?(profile.matrix_strategy)
        gaps << "#{name} is high-risk but matrix_strategy=#{profile.matrix_strategy}; high-risk surfaces require full expansion"
      end
    end

    gaps
  end

  sig { params(readme_path: String).returns(T::Hash[Symbol, Integer]) }
  def self.documented_counts(readme_path)
    return {} unless File.exist?(readme_path)

    lines = File.readlines(readme_path)
    start = lines.index { |line| line.strip == '## Current templates' }
    return {} unless start

    counts = T.let({}, T::Hash[Symbol, Integer])
    lines[(start + 1)..].to_a.take_while { |line| !line.start_with?('### ') }.each do |line|
      next unless line.start_with?('| `')
      parts = line.split('|').map(&:strip)
      next unless parts.length >= 4
      name = parts[1][/`([^`]+)`/, 1]
      count = parts[2][/^\d+/]
      next unless name && count

      counts[name.to_sym] = count.to_i
    end
    counts
  end

  sig do
    params(
      templates: T::Hash[Symbol, T.untyped],
      documented_counts: T::Hash[Symbol, Integer]
    ).returns(T::Array[String])
  end
  def self.readme_gaps(templates, documented_counts)
    names = templates.keys.sort
    doc_names = documented_counts.keys.sort
    gaps = T.let([], T::Array[String])

    (doc_names - names).each do |name|
      gaps << "README documents #{name}, but no template is registered"
    end
    (names - doc_names).each do |name|
      gaps << "template #{name} is registered, but README lacks a numeric active cell count"
    end

    names.each do |name|
      next unless documented_counts.key?(name)
      template = T.unsafe(templates.fetch(name))
      active = T.unsafe(template).cells.count { |cell| (T.unsafe(cell)[:expected] || :pass) != :in_dev }
      documented = documented_counts.fetch(name)
      next if documented == active

      gaps << "README active cell count for #{name} is #{documented}, expected #{active}"
    end

    gaps
  end

  sig { returns(T::Array[String]) }
  def self.required_surface_gaps
    gaps = T.let([], T::Array[String])
    registry = T.unsafe(FuzzSurfaceRegistry)

    registry::GLOBAL_REQUIRED_SURFACES.each do |surface|
      required = T.cast(registry.surface(surface), T::Array[Symbol])
      covered = T.cast(
        registry::TEMPLATE_COVERAGE.values.flat_map { |coverage| coverage.fetch(surface, []) }.uniq,
        T::Array[Symbol]
      )
      missing = required - covered
      next if missing.empty?

      gaps << "global #{surface} missing: #{missing.join(', ')}"
    end

    registry::REQUIRED_SURFACES_BY_TEMPLATE.each do |template, surfaces|
      surfaces.each do |surface|
        required = T.cast(registry.surface(surface), T::Array[Symbol])
        covered = T.cast(registry.covered(template, surface), T::Array[Symbol])
        missing = required - covered
        next if missing.empty?

        gaps << "#{template} missing #{surface}: #{missing.join(', ')}"
      end
    end

    gaps
  end

  sig { returns(T::Array[CrossProductRequirement]) }
  def self.cross_product_requirements
    registry = T.unsafe(FuzzSurfaceRegistry)
    sink_pairs = T.cast(
      registry::SINK_REQUIRES_SHAPES.flat_map do |sink, shapes|
        shapes.map { |shape| [sink, shape] }
      end,
      T::Array[[Symbol, Symbol]]
    )

    [
      CrossProductRequirement.new(
        name: :escape_sink_by_cleanup_shape,
        severity: :p0,
        left_surface: :escape_sinks,
        right_surface: :cleanup_value_shapes,
        required_pairs: sink_pairs
      ),
    ]
  end

  sig { returns(T::Array[String]) }
  def self.cross_product_gaps
    registry = T.unsafe(FuzzSurfaceRegistry)
    gaps = T.let([], T::Array[String])

    registry::SINK_REQUIRES_SHAPES.each do |sink, required_shapes|
      covering = T.cast(registry.templates_covering_sink(sink), T::Array[Symbol])
      exercised = T.cast(
        covering.flat_map { |template| registry.covered(template, :cleanup_value_shapes) }.uniq,
        T::Array[Symbol]
      )
      missing = T.cast(required_shapes, T::Array[Symbol]) - exercised
      next if missing.empty?

      gaps << "P0 cross-product escape_sinks:#{sink} x cleanup_value_shapes missing #{missing.join(', ')} (covered by: #{covering.join(', ')})"
    end

    gaps
  end

  sig { params(snapshots: T::Array[TemplateSnapshot]).returns(T::Array[String]) }
  def self.render_template_scope_lines(snapshots)
    snapshots.map do |snapshot|
      dimensions = snapshot.coverage.map { |surface, values| "#{surface}=#{values.length}" }.join(', ')
      dimensions = 'none' if dimensions.empty?
      counts = snapshot.expected_counts.sort.map { |expected, count| "#{expected}=#{count}" }.join(', ')
      profile = snapshot.profile
      "- #{snapshot.name}: cells=#{snapshot.cell_count} [#{counts}] source=#{profile.source_kind} matrix=#{profile.matrix_strategy} dimensions=#{dimensions}"
    end
  end

  sig { returns(T::Array[String]) }
  def self.render_cross_product_lines
    registry = T.unsafe(FuzzSurfaceRegistry)
    registry::SINK_REQUIRES_SHAPES.map do |sink, required_shapes|
      covering = T.cast(registry.templates_covering_sink(sink), T::Array[Symbol])
      exercised = T.cast(
        covering.flat_map { |template| registry.covered(template, :cleanup_value_shapes) }.uniq,
        T::Array[Symbol]
      )
      missing = T.cast(required_shapes, T::Array[Symbol]) - exercised
      status = missing.empty? ? 'covered' : "missing #{missing.join(', ')}"
      "- P0 escape_sinks:#{sink} x cleanup_value_shapes => #{status} (templates=#{covering.join(', ')})"
    end
  end
end
