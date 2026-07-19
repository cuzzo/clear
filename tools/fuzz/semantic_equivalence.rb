# Recursive, semantics-directed source generation for the CLEAR fuzz harness.
#
# Unlike the hand-authored fuzz matrices, this starts with a typed value goal,
# derives expressions which must evaluate to that value, and places every
# expression in every compatible consumer slot. Expected values are declared
# here; they are never obtained by asking the compiler under test.

require 'digest'
require 'json'

module SemanticEquivalence
  Attributes = Struct.new(
    :purity,
    :fallibility,
    :ownership,
    :optional,
    :effects,
    :capabilities,
    keyword_init: true
  ) do
    def initialize(
      purity: :pure,
      fallibility: :infallible,
      ownership: :copy,
      optional: false,
      effects: [],
      capabilities: []
    )
      super(
        purity: purity,
        fallibility: fallibility,
        ownership: ownership,
        optional: optional,
        effects: Array(effects).map(&:to_sym).uniq.sort.freeze,
        capabilities: Array(capabilities).map(&:to_sym).uniq.sort.freeze
      )
      freeze
    end

    def key = [purity, fallibility, ownership, optional, effects, capabilities]
  end

  Goal = Struct.new(:type, :value, keyword_init: true) do
    def key = [type, value]
  end

  ValueSpec = Struct.new(
    :id,
    :goal,
    :clear_type,
    :attributes,
    :setups,
    :literal,
    :observe,
    :capabilities,
    keyword_init: true
  ) do
    def render_literal = literal.call
    def assertion(expression) = observe.call(expression)
  end

  class ValueRegistry
    attr_reader :values

    def initialize(values)
      @values = values.freeze
      duplicate_ids = @values.group_by(&:id).select { |_id, group| group.length > 1 }.keys
      duplicate_types = @values.group_by { |value| value.goal.type }.select { |_type, group| group.length > 1 }.keys
      raise "duplicate semantic value ids: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
      raise "duplicate semantic goal types: #{duplicate_types.join(', ')}" unless duplicate_types.empty?
      @by_type = @values.to_h { |value| [value.goal.type, value] }.freeze
      @by_id = @values.to_h { |value| [value.id, value] }.freeze
    end

    def fetch(type) = @by_type.fetch(type)
    def fetch_optional(type) = @by_type[type]
    def fetch_id(id) = @by_id.fetch(id)
    def goals = @values.map(&:goal).freeze
  end

  Plan = Struct.new(:children, :setups, :render, :cost, :attributes, :shrink_to, keyword_init: true)
  Derivation = Struct.new(
    :production_id,
    :goal,
    :children,
    :source,
    :setups,
    :depth,
    :cost,
    keyword_init: true
  ) do
    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate(to_h))[0, 16]
    end

    def edges
      children.flat_map { |child| [[production_id, child.production_id]] + child.edges }.uniq
    end

    def production_ids = ([production_id] + children.flat_map(&:production_ids)).uniq

    def to_h
      {
        production: production_id,
        goal: goal.key,
        source: source,
        setups: setups.sort,
        depth: depth,
        cost: cost,
        children: children.map(&:to_h),
      }
    end
  end

  Fragment = Struct.new(:goal, :source, :setups, :productions, :attributes, :derivation, keyword_init: true) do
    def fingerprint = derivation.fingerprint
    def depth = derivation.depth
    def cost = derivation.cost
    def edges = derivation.edges
  end
  Production = Struct.new(:id, :parser_ref, :expand, :attributes, :cost, :shrink_to, keyword_init: true)
  Consumer = Struct.new(:id, :parser_action, :types, :render, keyword_init: true) do
    def accepts?(goal) = types.include?(goal.type)
  end
  Case = Struct.new(
    :id,
    :production_id,
    :consumer_id,
    :source,
    :derivation,
    :expected_type,
    :expected_value,
    keyword_init: true
  ) do
    def fingerprint = Digest::SHA256.hexdigest(id)[0, 16]

    def failure_context(seed:)
      {
        seed: seed,
        case_id: id,
        expected_type: expected_type,
        expected_value: expected_value,
        derivation: derivation.to_h,
        source: source,
      }
    end
  end

  INT_ONE = Goal.new(type: :int64, value: 1).freeze
  BOOL_TRUE = Goal.new(type: :bool, value: true).freeze
  STRING_ONE = Goal.new(type: :string, value: 'one').freeze
  STRUCT_ONE = Goal.new(type: :semantic_box, value: { 'v' => 1 }.freeze).freeze
  LIST_ONE = Goal.new(type: :int64_list, value: [1].freeze).freeze
  MAP_ONE = Goal.new(type: :int64_map, value: { 'one' => 1 }.freeze).freeze
  TUPLE_ONE = Goal.new(type: :int64_string_tuple, value: [1, 'one'].freeze).freeze

  COPY_ATTRIBUTES = Attributes.new.freeze
  MANAGED_ATTRIBUTES = Attributes.new(ownership: :owned, capabilities: %i[multiowned shared]).freeze
  VALUES = ValueRegistry.new([
    ValueSpec.new(
      id: :int64,
      goal: INT_ONE,
      clear_type: 'Int64',
      attributes: COPY_ATTRIBUTES,
      setups: [],
      literal: -> { '1_i64' },
      observe: ->(value) { "ASSERT #{value} == 1_i64, \"semantic Int64 payload\";" },
      capabilities: %i[shared_atomic]
    ),
    ValueSpec.new(
      id: :bool,
      goal: BOOL_TRUE,
      clear_type: 'Bool',
      attributes: COPY_ATTRIBUTES,
      setups: [],
      literal: -> { 'TRUE' },
      observe: ->(value) { "ASSERT #{value}, \"semantic Bool payload\";" },
      capabilities: []
    ),
    ValueSpec.new(
      id: :string,
      goal: STRING_ONE,
      clear_type: 'String',
      attributes: MANAGED_ATTRIBUTES,
      setups: [],
      literal: -> { 'COPY "one"' },
      observe: ->(value) { "ASSERT #{value} == \"one\", \"semantic String payload\";" },
      capabilities: %i[multiowned shared]
    ),
    ValueSpec.new(
      id: :struct,
      goal: STRUCT_ONE,
      clear_type: 'SemanticBox',
      attributes: MANAGED_ATTRIBUTES,
      setups: ['STRUCT SemanticBox { v: Int64 }'],
      literal: -> { 'SemanticBox{ v: 1_i64 }' },
      observe: ->(value) { "ASSERT #{value}.v == 1_i64, \"semantic struct payload\";" },
      capabilities: %i[multiowned shared locked write_locked versioned shared_locked shared_write_locked shared_versioned]
    ),
    ValueSpec.new(
      id: :list,
      goal: LIST_ONE,
      clear_type: 'Int64[]',
      attributes: MANAGED_ATTRIBUTES,
      setups: [],
      literal: -> { '[1_i64]' },
      observe: ->(value) { "ASSERT #{value}.length() == 1_i64, \"semantic list length\"; ASSERT #{value}[0_i64] == 1_i64, \"semantic list payload\";" },
      capabilities: %i[multiowned shared]
    ),
    ValueSpec.new(
      id: :map,
      goal: MAP_ONE,
      clear_type: 'HashMap<Int64>',
      attributes: MANAGED_ATTRIBUTES,
      setups: [],
      literal: -> { '{"one": 1_i64}' },
      observe: ->(value) { "ASSERT #{value}.count() == 1_i64, \"semantic map count\"; ASSERT (#{value}[\"one\"] OR_ELSE 0_i64) == 1_i64, \"semantic map payload\";" },
      capabilities: %i[multiowned shared]
    ),
    ValueSpec.new(
      id: :tuple,
      goal: TUPLE_ONE,
      clear_type: 'Tuple<Int64,String>',
      attributes: MANAGED_ATTRIBUTES,
      setups: ['FN semanticStringOne() RETURNS String -> RETURN COPY "one"; END'],
      literal: -> { 'Tuple{1_i64, semanticStringOne()}' },
      observe: ->(value) { "ASSERT #{value}._0 == 1_i64, \"semantic tuple first\"; ASSERT #{value}._1 == \"one\", \"semantic tuple second\";" },
      capabilities: %i[multiowned shared]
    )
  ]).freeze
  # Historical defects found by the generator. These are not outstanding
  # exclusions: their unadapted witnesses are enabled positive cases below.
  FIXED_LANGUAGE_GAPS = {
    contextual_nil_or_else: 'Bare NIL is contextually typed through OR_ELSE.',
    direct_struct_literal_field: 'Direct struct-literal field reads retain Zig parentheses.',
    unused_pipeline_capture: 'Constant pipeline stages emit an anonymous loop capture.',
    int_min_max_projection: 'MIN/MAX projections use their annotated numeric accumulator type.',
    nested_pipeline_expression: 'Nested pipeline placeholders and accumulators are lexically scoped and typed.',
    nested_owned_map: 'Managed lists containing maps use a compatible destination allocator.',
  }.freeze
  FIXED_EXPANSION_GAPS = {
    takes_direct_list_literal: 'A list literal passed directly to TAKES has a transfer mark without an allocation source.',
    tuple_nil_or_else_transfer: 'A tuple payload selected by bare NIL OR_ELSE is read after its temporary transfer.',
    tuple_temporary_copy_leak: 'COPY of a temporary tuple leaks its managed String field.',
    list_or_else_loop_field_coercion: 'A list selected by OR_ELSE is not materialized for a struct field destination.',
    nested_owned_sink_allocator_transport: 'A frame-owned list moved into a heap-owned nested field bypasses allocator transport.',
    nested_list_contextual_shape: 'Nested OR_ELSE/COPY loses the owning list shape required by an outer list element.',
    owned_optional_fallback_copy_lifetime: 'COPY of an owned optional fallback leaks the selected temporary value.',
    tuple_collection_constructor_context: 'An untyped List[] tuple field ignores the declared Tuple field type during lowering.',
    collection_literal_child_allocator_transport: 'A heap-owned value embedded in a frame list bypasses per-child allocator transport.',
    optional_owned_branch_allocator_convergence: 'An owned optional and its OR_ELSE fallback retain different allocators in the merged result.',
    tuple_temporary_allocator_convergence: 'A managed tuple temporary inherits a frame child but is cleaned with the heap allocator.',
  }.freeze
  KNOWN_GAPS = {}.freeze

  class Grammar
    attr_reader :productions

    def initialize
      @productions = []
    end

    def production(id, parser_ref:, attributes: Attributes.new, cost: 1, shrink_to: [], &expand)
      raise "duplicate semantic production #{id}" if @productions.any? { |item| item.id == id }
      @productions << Production.new(
        id: id,
        parser_ref: parser_ref,
        expand: expand,
        attributes: attributes,
        cost: cost,
        shrink_to: Array(shrink_to).map(&:to_sym).freeze
      )
    end
  end

  class Generator
    def initialize(grammar, max_per_goal: 1_500)
      @grammar = grammar
      @max_per_goal = max_per_goal
      @memo = {}
    end

    def derive(goal, max_depth:)
      key = [goal.key, max_depth]
      return @memo.fetch(key) if @memo.key?(key)

      fragments = @grammar.productions.flat_map do |production|
        plans = Array(production.expand.call(goal, max_depth))
        plans.flat_map { |plan| realize(production, goal, plan, max_depth) }
      end
      unique = fragments.uniq { |fragment| [fragment.source, fragment.setups.sort] }
      @memo[key] = unique.first(@max_per_goal).freeze
    end

    private

    def realize(production, goal, plan, max_depth)
      return [] if plan.children.any? && max_depth.zero?

      choices = plan.children.map { |child| derive(child, max_depth: max_depth - 1) }
      return [] if choices.any?(&:empty?)

      product(choices).filter_map do |children|
        setups = merge_setups(plan.setups, children.flat_map(&:setups))
        next unless setups

        attributes = plan.attributes || production.attributes
        child_derivations = children.map(&:derivation)
        source = plan.render.call(children.map(&:source))
        cost = (plan.cost || production.cost) + children.sum(&:cost)
        depth = child_derivations.empty? ? 0 : child_derivations.map(&:depth).max + 1
        derivation = Derivation.new(
          production_id: production.id,
          goal: goal,
          children: child_derivations.freeze,
          source: source,
          setups: setups.freeze,
          depth: depth,
          cost: cost
        ).freeze
        Fragment.new(
          goal: goal,
          source: source,
          setups: setups,
          productions: derivation.production_ids.freeze,
          attributes: attributes,
          derivation: derivation
        ).freeze
      end
    end

    def product(choices)
      choices.reduce([[]]) { |rows, options| rows.flat_map { |row| options.map { |option| row + [option] } } }
    end

    def merge_setups(local, inherited)
      (Array(local) + inherited).uniq.sort
    end
  end

  class Campaign
    attr_reader :seed, :limit, :shard_index, :shard_count

    def initialize(seed:, limit: nil, shard: nil)
      @seed = Integer(seed)
      @limit = limit && Integer(limit)
      @shard_index, @shard_count = parse_shard(shard)
    end

    def select(cases)
      sharded = cases.select { |item| shard?(item) }
      return sharded.freeze unless limit && sharded.length > limit

      required = coverage_representatives(sharded)
      if limit < required.length
        raise "semantic limit #{limit} cannot retain #{required.length} mandatory coverage representatives"
      end
      remaining = (sharded - required).sort_by { |item| seeded_key(item) }
      (required + remaining).uniq.first(limit).freeze
    end

    private

    def parse_shard(shard)
      return [0, 1] unless shard
      match = /\A(\d+)\/(\d+)\z/.match(shard.to_s) or raise "invalid semantic shard #{shard.inspect}"
      index = Integer(match[1])
      count = Integer(match[2])
      raise "invalid semantic shard #{shard.inspect}" unless count.positive? && index < count
      [index, count]
    end

    def shard?(item) = item.fingerprint.to_i(16) % shard_count == shard_index

    def coverage_representatives(cases)
      seen = {}
      cases.sort_by(&:id).select do |item|
        keys = [[:production, item.production_id], [:consumer, item.consumer_id]] +
          item.derivation.edges.map { |edge| [:edge, edge] }
        fresh = keys.any? { |key| !seen.key?(key) }
        keys.each { |key| seen[key] = true } if fresh
        fresh
      end
    end

    def seeded_key(item) = Digest::SHA256.hexdigest("#{seed}:#{item.id}")
  end

  class Shrinker
    def initialize(fragments)
      @fragments_by_goal = fragments.group_by { |fragment| fragment.goal.key }
    end

    def candidates(fragment)
      @fragments_by_goal.fetch(fragment.goal.key, []).select do |candidate|
        candidate.attributes.key == fragment.attributes.key &&
          (candidate.cost < fragment.cost || (candidate.cost == fragment.cost && candidate.depth < fragment.depth))
      end.sort_by { |candidate| [candidate.cost, candidate.depth, candidate.fingerprint] }
    end

    def minimal(fragment) = candidates(fragment).first || fragment

    def preserves_class?(original, replacement)
      original.goal.key == replacement.goal.key && original.attributes.key == replacement.attributes.key
    end
  end

  CapabilitySpec = Struct.new(:id, :suffix, :access, :value_ids, :ownership, :sync, keyword_init: true)

  CAPABILITIES = [
    CapabilitySpec.new(id: :multiowned, suffix: '@multiowned', access: :direct, value_ids: %i[string struct list map tuple], ownership: :multiowned, sync: nil),
    CapabilitySpec.new(id: :shared, suffix: '@shared', access: :direct, value_ids: %i[string struct list map tuple], ownership: :shared, sync: nil),
    CapabilitySpec.new(id: :locked, suffix: '@locked', access: :exclusive, value_ids: %i[struct], ownership: :affine, sync: :locked),
    CapabilitySpec.new(id: :write_locked, suffix: '@writeLocked', access: :exclusive, value_ids: %i[struct], ownership: :affine, sync: :write_locked),
    CapabilitySpec.new(id: :versioned, suffix: '@versioned', access: :snapshot, value_ids: %i[struct], ownership: :affine, sync: :versioned),
    CapabilitySpec.new(id: :shared_locked, suffix: '@shared:locked', access: :exclusive, value_ids: %i[struct], ownership: :shared, sync: :locked),
    CapabilitySpec.new(id: :shared_write_locked, suffix: '@shared:writeLocked', access: :exclusive, value_ids: %i[struct], ownership: :shared, sync: :write_locked),
    CapabilitySpec.new(id: :shared_versioned, suffix: '@shared:versioned', access: :snapshot, value_ids: %i[struct], ownership: :shared, sync: :versioned),
    CapabilitySpec.new(id: :shared_atomic, suffix: '@shared:atomic', access: :direct, value_ids: %i[int64], ownership: :shared, sync: :atomic),
  ].freeze

  FIXED_CAPABILITY_GAPS = %i[
    string_refcount_observer
    list_refcount_observer
    map_refcount_wrap
    tuple_refcount_observer
  ].freeze
  CAPABILITY_EXCLUSIONS = {}.freeze

  class CapabilitySuite
    attr_reader :cases, :capabilities, :values

    def initialize(values: VALUES, capabilities: CAPABILITIES)
      @values = values
      @capabilities = capabilities
      validate_registry!
      @cases = build_cases.freeze
    end

    def report
      {
        capabilities: capabilities.length,
        cases: cases.length,
        value_capability_pairs: cases.map { |item| [item.expected_value.fetch(:value), item.expected_value.fetch(:capability)] }.uniq.length,
        access_modes: capabilities.map(&:access).uniq.sort,
      }
    end

    private

    def validate_registry!
      ids = values.values.map(&:id)
      missing = capabilities.flat_map(&:value_ids).uniq - ids
      duplicates = capabilities.group_by(&:id).select { |_id, group| group.length > 1 }.keys
      raise "unknown capability value ids: #{missing.join(', ')}" unless missing.empty?
      raise "duplicate semantic capabilities: #{duplicates.join(', ')}" unless duplicates.empty?
    end

    def build_cases
      capabilities.flat_map do |capability|
        capability.value_ids.map do |value_id|
          value = values.values.find { |candidate| candidate.id == value_id } or raise "unknown value #{value_id}"
          build_case(value, capability)
        end
      end
    end

    def build_case(value, capability)
      source = render_program(value, capability)
      goal = Goal.new(type: :capability_payload, value: [value.id, capability.id].freeze).freeze
      derivation = Derivation.new(
        production_id: :capability_wrap,
        goal: goal,
        children: [],
        source: "#{value.render_literal} #{capability.suffix}",
        setups: value.setups,
        depth: 0,
        cost: 1
      ).freeze
      Case.new(
        id: "capability-#{value.id}-#{capability.id}",
        production_id: :capability_wrap,
        consumer_id: capability.access,
        source: source,
        derivation: derivation,
        expected_type: "#{value.clear_type}#{capability.suffix}",
        expected_value: { value: value.id, capability: capability.id }.freeze
      ).freeze
    end

    def render_program(value, capability)
      setup = value.setups.join("\n\n")
      declaration = "MUTABLE value = #{value.render_literal} #{capability.suffix};"
      observation = value.assertion(capability.access == :direct ? 'value' : 'observed')
      access = case capability.access
      when :direct
        observation
      when :exclusive
        "WITH EXCLUSIVE value AS observed {\n        #{observation}\n    }"
      when :snapshot
        "WITH SNAPSHOT value AS observed {\n        #{observation}\n    }"
      else
        raise "unknown capability access #{capability.access}"
      end
      <<~CLEAR
        #{setup}
        FN main() RETURNS Void ->
          #{declaration}
          #{access}
          RETURN;
        END
      CLEAR
    end
  end

  module ParserAudit
    GENERATED = {
      parse_select_op: [:pipeline_select],
      parse_where_op: [:pipeline_where],
      parse_find_op: [:pipeline_find],
      parse_any_op: [:pipeline_any],
      parse_all_op: [:pipeline_all],
      parse_count_op: [:pipeline_count],
      parse_sum_op: [:pipeline_sum],
      parse_min_op: [:pipeline_min],
      parse_max_op: [:pipeline_max],
      parse_take_while_op: [:pipeline_take_while],
    }.freeze

    # These operators need attributes other than "expression of type T with
    # value V" (bindings, ordering, cardinality, effects, or concurrency).
    MANUAL = %i[
      parse_index_op parse_reduce_op parse_order_by_op parse_limit_op
      parse_skip_op parse_unnest_op parse_distinct_op parse_each_op
      parse_tap_op parse_recover_op parse_collect_op parse_window_op
      parse_join_op parse_shard_op parse_concurrent_op parse_average_op
    ].freeze

    module_function

    def pipeline_actions(parser_path:)
      source = File.read(parser_path)
      primary = source[/PRIMARY_RULES =.*?PRIMARY_RULE_INDEX/m]
      raise "could not find PRIMARY_RULES in #{parser_path}" unless primary
      primary.scan(/action: :(parse_[a-z_]+_op)/).flatten.map(&:to_sym).uniq
    end

    def validate!(parser_path:, consumer_ids:, production_refs:)
      actual = pipeline_actions(parser_path: parser_path)
      classified = GENERATED.keys + MANUAL
      missing = actual - classified
      stale = classified - actual
      missing_consumers = GENERATED.values.flatten - consumer_ids
      parser_sources = [parser_path] + Dir[File.join(File.dirname(parser_path), 'parser', '*.rb')]
      parser_text = parser_sources.map { |path| File.read(path) }.join("\n")
      missing_refs = production_refs.reject { |ref| parser_text.include?(ref.to_s) }
      errors = []
      errors << "unclassified parser pipeline actions: #{missing.join(', ')}" unless missing.empty?
      errors << "stale parser pipeline actions: #{stale.join(', ')}" unless stale.empty?
      errors << "missing generated consumers: #{missing_consumers.join(', ')}" unless missing_consumers.empty?
      errors << "missing semantic production parser refs: #{missing_refs.join(', ')}" unless missing_refs.empty?
      raise errors.join('; ') unless errors.empty?
      { total: actual.length, generated: GENERATED.length, manual: MANUAL.length }
    end
  end

  class Suite
    attr_reader :grammar, :consumers, :fragments, :cases, :all_cases, :audit, :blocked_obligations, :seed

    def self.mvp(parser_path:, max_depth: 1, seed: 1, limit: nil, shard: nil)
      new(parser_path: parser_path, max_depth: max_depth, seed: seed, limit: limit, shard: shard)
    end

    def initialize(parser_path:, max_depth:, seed:, limit:, shard:)
      @seed = Integer(seed)
      @grammar = build_grammar
      @consumers = build_consumers
      @audit = ParserAudit.validate!(
        parser_path: parser_path,
        consumer_ids: @consumers.map(&:id),
        production_refs: @grammar.productions.map(&:parser_ref).uniq
      )
      generator = Generator.new(@grammar)
      @fragments = VALUES.goals.flat_map { |goal| generator.derive(goal, max_depth: max_depth) }
      @blocked_obligations = []
      @all_cases = build_cases.freeze
      @cases = Campaign.new(seed: @seed, limit: limit, shard: shard).select(@all_cases)
      @blocked_obligations.freeze
      validate_coverage!
    end

    def report
      used = @fragments.flat_map(&:productions).uniq
      {
        productions: @grammar.productions.length,
        productions_used: used.length,
        derivations: @fragments.length,
        consumers: @consumers.length,
        cases: @cases.length,
        all_cases: @all_cases.length,
        blocked_obligations: @blocked_obligations.length,
        known_gaps: KNOWN_GAPS.keys,
        fixed_language_gaps: FIXED_LANGUAGE_GAPS.keys,
        fixed_capability_gaps: FIXED_CAPABILITY_GAPS,
        fixed_expansion_gaps: FIXED_EXPANSION_GAPS.keys,
        parser_pipeline_actions: @audit,
        int_derivations: @fragments.count { |fragment| fragment.goal.type == :int64 },
        bool_derivations: @fragments.count { |fragment| fragment.goal.type == :bool },
        value_families: @fragments.group_by { |fragment| fragment.goal.type }.transform_values(&:length),
        derivation_edges: @fragments.flat_map(&:edges).uniq.length,
        depth_histogram: @fragments.group_by(&:depth).transform_values(&:length).sort.to_h,
        seed: @seed,
      }
    end

    private

    def build_grammar
      Grammar.new.tap do |grammar|
        grammar.production(:int_literal, parser_ref: :parse_stack_literal) do |goal, _depth|
          next [] unless goal.type == :int64 && goal.value.is_a?(Integer)
          [Plan.new(children: [], setups: [], render: ->(_children) { "#{goal.value}_i64" })]
        end

        grammar.production(:bool_literal, parser_ref: :parse_true_literal) do |goal, _depth|
          next [] unless goal.type == :bool
          literal = goal.value ? 'TRUE' : 'FALSE'
          [Plan.new(children: [], setups: [], render: ->(_children) { literal })]
        end


        grammar.production(:string_literal, parser_ref: :parse_stack_literal, attributes: MANAGED_ATTRIBUTES) do |goal, _depth|
          next [] unless goal == STRING_ONE
          [Plan.new(children: [], setups: [], render: ->(_children) { 'COPY "one"' }, attributes: MANAGED_ATTRIBUTES)]
        end

        grammar.production(:struct_value, parser_ref: :parse_dot_suffix, attributes: MANAGED_ATTRIBUTES) do |goal, _depth|
          next [] unless goal == STRUCT_ONE
          setups = [
            'STRUCT SemanticBox { v: Int64 }',
            'FN semanticBoxOne() RETURNS SemanticBox -> RETURN SemanticBox{ v: 1_i64 }; END',
          ]
          [Plan.new(children: [], setups: setups, render: ->(_children) { 'semanticBoxOne()' }, attributes: MANAGED_ATTRIBUTES)]
        end

        grammar.production(:list_literal, parser_ref: :parse_lit, attributes: MANAGED_ATTRIBUTES) do |goal, _depth|
          next [] unless goal == LIST_ONE
          [Plan.new(children: [], setups: [], render: ->(_children) { '[1_i64]' }, attributes: MANAGED_ATTRIBUTES)]
        end

        grammar.production(:map_literal, parser_ref: :parse_lit, attributes: MANAGED_ATTRIBUTES) do |goal, _depth|
          next [] unless goal == MAP_ONE
          [Plan.new(children: [], setups: [], render: ->(_children) { '{"one": 1_i64}' }, attributes: MANAGED_ATTRIBUTES)]
        end

        grammar.production(:tuple_literal, parser_ref: :parse_lit, attributes: MANAGED_ATTRIBUTES) do |goal, _depth|
          next [] unless goal == TUPLE_ONE
          setup = 'FN semanticStringOne() RETURNS String -> RETURN COPY "one"; END'
          [Plan.new(children: [], setups: [setup], render: ->(_children) { 'Tuple{1_i64, semanticStringOne()}' }, attributes: MANAGED_ATTRIBUTES)]
        end

        grammar.production(:nil_literal, parser_ref: :parse_nil_literal) do |goal, _depth|
          next [] unless goal.type.to_s.start_with?('optional_') && goal.value.nil?
          [Plan.new(children: [], setups: [], render: ->(_children) { 'NIL' })]
        end

        grammar.production(:group, parser_ref: :parse_group_expression) do |goal, _depth|
          attributes = VALUES.fetch_optional(goal.type)&.attributes || Attributes.new(optional: true)
          [Plan.new(children: [goal], setups: [], render: ->(children) { "(#{children.fetch(0)})" }, attributes: attributes)]
        end

        grammar.production(:identity_call, parser_ref: :parse_func_call_suffix) do |goal, _depth|
          value = VALUES.fetch_optional(goal.type)
          next [] unless value && !%i[list map].include?(value.id)
          stem = semantic_name(value)
          returned = value.attributes.ownership == :copy ? 'v' : 'COPY v'
          setup = "FN semanticIdentity#{stem}(v: #{value.clear_type}) RETURNS #{value.clear_type} -> RETURN #{returned}; END"
          [Plan.new(
            children: [goal],
            setups: [setup],
            render: ->(children) { "semanticIdentity#{stem}(#{children.fetch(0)})" },
            attributes: value.attributes
          )]
        end

        grammar.production(:identity_local_call, parser_ref: :parse_func_call_suffix, cost: 2) do |goal, _depth|
          value = VALUES.fetch_optional(goal.type)
          next [] unless value && !%i[list map].include?(value.id)
          stem = semantic_name(value)
          init = value.attributes.ownership == :copy ? 'v' : 'COPY v'
          setup = "FN semanticIdentityLocal#{stem}(v: #{value.clear_type}) RETURNS #{value.clear_type} -> local: #{value.clear_type} = #{init}; RETURN local; END"
          [Plan.new(
            children: [goal],
            setups: [setup],
            render: ->(children) { "semanticIdentityLocal#{stem}(#{children.fetch(0)})" },
            attributes: value.attributes
          )]
        end

        grammar.production(:identity_branch_call, parser_ref: :parse_func_call_suffix, cost: 2) do |goal, _depth|
          value = VALUES.fetch_optional(goal.type)
          next [] unless value && !%i[list map].include?(value.id)
          stem = semantic_name(value)
          returned = value.attributes.ownership == :copy ? 'v' : 'COPY v'
          setup = "FN semanticIdentityBranch#{stem}(v: #{value.clear_type}) RETURNS #{value.clear_type} -> IF TRUE THEN RETURN #{returned}; ELSE RETURN #{returned}; END END"
          [Plan.new(
            children: [goal],
            setups: [setup],
            render: ->(children) { "semanticIdentityBranch#{stem}(#{children.fetch(0)})" },
            attributes: value.attributes
          )]
        end

        grammar.production(:copy_value, parser_ref: :parse_copy_node) do |goal, _depth|
          value = VALUES.fetch_optional(goal.type)
          next [] unless value && value.attributes.ownership != :copy
          [Plan.new(
            children: [goal],
            setups: [],
            render: ->(children) { "COPY (#{children.fetch(0)})" },
            attributes: value.attributes
          )]
        end
        grammar.production(:add_zero, parser_ref: :parse_binary_op) do |goal, _depth|
          next [] unless goal.type == :int64
          zero = Goal.new(type: :int64, value: 0)
          [Plan.new(children: [zero, goal], setups: [], render: ->(children) { "(#{children.fetch(0)} + #{children.fetch(1)})" })]
        end

        grammar.production(:struct_field, parser_ref: :parse_dot_suffix) do |goal, _depth|
          next [] unless goal.type == :int64
          setups = [
            'STRUCT SemanticValueBox { v: Int64 }',
          ]
          [Plan.new(children: [goal], setups: setups, render: ->(children) { "SemanticValueBox{ v: #{children.fetch(0)} }.v" })]
        end

        grammar.production(:nil_or_else, parser_ref: :parse_binary_op) do |goal, _depth|
          value = VALUES.fetch_optional(goal.type)
          next [] unless value
          optional = Goal.new(type: :"optional_#{goal.type}", value: nil)
          [Plan.new(
            children: [optional, goal],
            setups: [],
            render: ->(children) { "(#{children.fetch(0)} OR_ELSE #{children.fetch(1)})" },
            attributes: value.attributes
          )]
        end

        grammar.production(:singleton_sum, parser_ref: :parse_sum_op) do |goal, _depth|
          next [] unless goal.type == :int64
          [Plan.new(children: [goal], setups: [], render: ->(children) { "([#{children.fetch(0)}] |> SUM _)" })]
        end

        grammar.production(:equals_one, parser_ref: :parse_binary_op) do |goal, _depth|
          next [] unless goal.type == :bool && goal.value == true
          [Plan.new(children: [INT_ONE], setups: [], render: ->(children) { "(#{children.fetch(0)} == 1_i64)" })]
        end
      end
    end

    def semantic_name(value)
      value.id.to_s.split('_').map(&:capitalize).join
    end

    def build_consumers
      consumers = []
      all_values = VALUES.goals.map(&:type)
      consumers << consumer(:local_initializer, all_values) { |fragment| local_program(fragment) }
      consumers << consumer(:return_expression, all_values) { |fragment| return_program(fragment) }
      consumers << consumer(:function_argument, all_values) { |fragment| argument_program(fragment) }
      consumers << consumer(:struct_field_value, all_values) { |fragment| struct_program(fragment) }
      consumers << consumer(:list_element, all_values) { |fragment| list_program(fragment) }

      managed_values = VALUES.values.reject { |value| value.attributes.ownership == :copy }.map { |value| value.goal.type }
      consumers << consumer(:copy_value, managed_values, :parse_copy_node) { |fragment| copy_program(fragment) }
      consumers << consumer(:takes_rvalue, managed_values) { |fragment| takes_program(fragment, give: false) }
      consumers << consumer(:give_to_takes, managed_values) { |fragment| takes_program(fragment, give: true) }

      consumers << consumer(:pipeline_select, [:int64], :parse_select_op) { |fragment| int_pipeline(fragment, "SELECT #{int_slot(fragment)} |> SUM _", 1) }
      consumers << consumer(:pipeline_sum, [:int64], :parse_sum_op) { |fragment| int_pipeline(fragment, "SUM #{int_slot(fragment)}", 1) }
      consumers << consumer(:pipeline_min, [:int64], :parse_min_op) { |fragment| int_pipeline(fragment, "MIN #{int_slot(fragment)}", 1) }
      consumers << consumer(:pipeline_max, [:int64], :parse_max_op) { |fragment| int_pipeline(fragment, "MAX #{int_slot(fragment)}", 1) }
      consumers << consumer(:pipeline_where, [:bool], :parse_where_op) { |fragment| int_pipeline(fragment, "WHERE #{bool_slot(fragment)} |> SUM _", 7) }
      consumers << consumer(:pipeline_find, [:bool], :parse_find_op) { |fragment| find_pipeline(fragment) }
      consumers << consumer(:pipeline_any, [:bool], :parse_any_op) { |fragment| bool_pipeline(fragment, "ANY #{bool_slot(fragment)}") }
      consumers << consumer(:pipeline_all, [:bool], :parse_all_op) { |fragment| bool_pipeline(fragment, "ALL #{bool_slot(fragment)}") }
      consumers << consumer(:pipeline_count, [:bool], :parse_count_op) { |fragment| int_pipeline(fragment, "COUNT #{bool_slot(fragment)}", 1) }
      consumers << consumer(:pipeline_take_while, [:bool], :parse_take_while_op) { |fragment| int_pipeline(fragment, "TAKE_WHILE #{bool_slot(fragment)} |> SUM _", 7) }
      consumers.freeze
    end

    def consumer(id, types, parser_action = nil, &render)
      Consumer.new(id: id, types: types, parser_action: parser_action, render: render)
    end

    def build_cases
      @fragments.flat_map do |fragment|
        @consumers.filter_map do |consumer|
          next unless consumer.accepts?(fragment.goal)
          id = "#{fragment.goal.type}-#{fragment.fingerprint}-#{consumer.id}"
          item = Case.new(
            id: id,
            production_id: fragment.productions.first,
            consumer_id: consumer.id,
            source: consumer.render.call(fragment),
            derivation: fragment.derivation,
            expected_type: type_name(fragment),
            expected_value: fragment.goal.value
          )
          if blocked_pair?(fragment, consumer)
            @blocked_obligations << item
            next
          end
          item
        end
      end
    end

    def blocked_pair?(_fragment, _consumer) = false

    def definitions(fragment, extra = [])
      (fragment.setups + extra).uniq.join("\n\n")
    end

    def type_name(fragment) = VALUES.fetch(fragment.goal.type).clear_type
    def int_slot(fragment) = fragment.source
    def bool_slot(fragment) = fragment.source
    def assertion(variable, fragment) = VALUES.fetch(fragment.goal.type).assertion(variable)

    def local_program(fragment)
      <<~CLEAR
        #{definitions(fragment)}
        FN main() RETURNS Void ->
          value: #{type_name(fragment)} = #{fragment.source};
          #{assertion('value', fragment)}
          RETURN;
        END
      CLEAR
    end

    def return_program(fragment)
      helper = "FN semanticReturn() RETURNS #{type_name(fragment)} -> RETURN #{fragment.source}; END"
      <<~CLEAR
        #{definitions(fragment, [helper])}
        FN main() RETURNS Void ->
          value = semanticReturn();
          #{assertion('value', fragment)}
          RETURN;
        END
      CLEAR
    end

    def argument_program(fragment)
      helper = "FN semanticConsume(value: #{type_name(fragment)}) RETURNS #{type_name(fragment)} -> RETURN value; END"
      <<~CLEAR
        #{definitions(fragment, [helper])}
        FN main() RETURNS Void ->
          value = semanticConsume(#{fragment.source});
          #{assertion('value', fragment)}
          RETURN;
        END
      CLEAR
    end

    def struct_program(fragment)
      helper = "STRUCT SemanticSinkBox { value: #{type_name(fragment)} }"
      <<~CLEAR
        #{definitions(fragment, [helper])}
        FN main() RETURNS Void ->
          box = SemanticSinkBox{ value: #{fragment.source} };
          #{assertion('box.value', fragment)}
          RETURN;
        END
      CLEAR
    end

    def list_program(fragment)
      <<~CLEAR
        #{definitions(fragment)}
        FN main() RETURNS Void ->
          values: #{type_name(fragment)}[] = [#{fragment.source}];
          #{assertion('values[0_i64]', fragment)}
          RETURN;
        END
      CLEAR
    end

    def copy_program(fragment)
      <<~CLEAR
        #{definitions(fragment)}
        FN main() RETURNS Void ->
          original: #{type_name(fragment)} = #{fragment.source};
          value: #{type_name(fragment)} = COPY original;
          #{assertion('value', fragment)}
          #{assertion('original', fragment)}
          RETURN;
        END
      CLEAR
    end

    def takes_program(fragment, give:)
      value = VALUES.fetch(fragment.goal.type)
      stem = semantic_name(value)
      helper = <<~HELPER.strip
        FN semanticTake#{stem}(TAKES input: #{value.clear_type}) RETURNS Void ->
          #{value.assertion('input')}
          RETURN;
        END
      HELPER
      if give
        body = <<~BODY
          original: #{value.clear_type} = #{fragment.source};
          semanticTake#{stem}(GIVE original);
        BODY
      else
        body = "semanticTake#{stem}(#{fragment.source});"
      end
      <<~CLEAR
        #{definitions(fragment, [helper])}
        FN main() RETURNS Void ->
          #{body}
          RETURN;
        END
      CLEAR
    end

    def int_pipeline(fragment, operation, expected)
      <<~CLEAR
        #{definitions(fragment)}
        FN main() RETURNS Void ->
          value = [7_i64] |> #{operation};
          ASSERT value == #{expected}_i64, "semantic pipeline value";
          RETURN;
        END
      CLEAR
    end

    def bool_pipeline(fragment, operation)
      <<~CLEAR
        #{definitions(fragment)}
        FN main() RETURNS Void ->
          value = [7_i64] |> #{operation};
          ASSERT value, "semantic pipeline predicate";
          RETURN;
        END
      CLEAR
    end

    def find_pipeline(fragment)
      <<~CLEAR
        #{definitions(fragment)}
        FN main() RETURNS Void ->
          value = [7_i64] |> FIND #{bool_slot(fragment)};
          ASSERT value != NIL, "semantic pipeline find";
          ASSERT value == 7_i64, "semantic pipeline find value";
          RETURN;
        END
      CLEAR
    end

    def validate_coverage!
      used = @fragments.flat_map(&:productions).uniq
      missing_productions = @grammar.productions.map(&:id) - used
      missing_consumers = @consumers.map(&:id) - @all_cases.map(&:consumer_id).uniq
      or_else = @fragments.find do |fragment|
        fragment.productions.include?(:nil_or_else) && fragment.productions.include?(:nil_literal) &&
          fragment.goal == INT_ONE
      end
      errors = []
      errors << "unexercised semantic productions: #{missing_productions.join(', ')}" unless missing_productions.empty?
      errors << "unexercised semantic consumers: #{missing_consumers.join(', ')}" unless missing_consumers.empty?
      errors << 'missing recursively-derived typed-NIL OR_ELSE 1_i64 witness' unless or_else
      raise errors.join('; ') unless errors.empty?
    end
  end
end
