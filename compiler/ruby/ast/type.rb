# typed: strict
require "sorbet-runtime"
require_relative "lexer"
require_relative "struct_field"

class TypeCapabilitySuffix < T::Struct
  const :base, String
  const :ownership, T.nilable(Symbol)
  const :sync, T.nilable(Symbol)
end

class TypeCapabilityUnset < T::Struct
end

# ruby-to-clear: value
class TypeCapabilities
  extend T::Sig

  UNSET = T.let(TypeCapabilityUnset.new.freeze, TypeCapabilityUnset)
  MaybeSymbol = T.type_alias { T.any(TypeCapabilityUnset, Symbol, NilClass) }
  MaybeInteger = T.type_alias { T.any(TypeCapabilityUnset, Integer, NilClass) }
  MaybeBoolean = T.type_alias { T.any(TypeCapabilityUnset, T::Boolean) }
  MaybeToken = T.type_alias { T.any(TypeCapabilityUnset, Lexer::Token, NilClass) }

  sig { returns(T.nilable(Symbol)) }
  attr_reader :ownership, :sync, :layout, :collection, :elem_ownership, :elem_sync,
    :elem_layout, :link_source, :observable_terminal
  sig { returns(T.nilable(Integer)) }
  attr_reader :lock_rank, :shard_count
  sig { returns(T::Boolean) }
  attr_reader :ownership_set, :soa, :observable, :polymorphic_shared
  sig { returns(T.nilable(Lexer::Token)) }
  attr_reader :observable_token

  sig do
    params(
      ownership: T.nilable(Symbol),
      ownership_set: T::Boolean,
      sync: T.nilable(Symbol),
      layout: T.nilable(Symbol),
      lock_rank: T.nilable(Integer),
      collection: T.nilable(Symbol),
      shard_count: T.nilable(Integer),
      soa: T::Boolean,
      elem_ownership: T.nilable(Symbol),
      elem_sync: T.nilable(Symbol),
      elem_layout: T.nilable(Symbol),
      link_source: T.nilable(Symbol),
      observable: T::Boolean,
      observable_terminal: T.nilable(Symbol),
      observable_token: T.nilable(Lexer::Token),
      polymorphic_shared: T::Boolean
    ).void
  end
  def initialize(
    ownership: nil,
    ownership_set: false,
    sync: nil,
    layout: nil,
    lock_rank: nil,
    collection: nil,
    shard_count: nil,
    soa: false,
    elem_ownership: nil,
    elem_sync: nil,
    elem_layout: nil,
    link_source: nil,
    observable: false,
    observable_terminal: nil,
    observable_token: nil,
    polymorphic_shared: false
  )
    @ownership = ownership
    @ownership_set = ownership_set
    @sync = sync
    @layout = layout
    @lock_rank = lock_rank
    @collection = collection
    @shard_count = shard_count
    @soa = soa
    @elem_ownership = elem_ownership
    @elem_sync = elem_sync
    @elem_layout = elem_layout
    @link_source = link_source
    @observable = observable
    @observable_terminal = observable_terminal
    @observable_token = observable_token
    @polymorphic_shared = polymorphic_shared
    freeze
  end

  sig { returns(TypeCapabilities) }
  def copy
    self
  end

  sig do
    params(
      ownership: MaybeSymbol,
      ownership_set: MaybeBoolean,
      sync: MaybeSymbol,
      layout: MaybeSymbol,
      lock_rank: MaybeInteger,
      collection: MaybeSymbol,
      shard_count: MaybeInteger,
      soa: MaybeBoolean,
      elem_ownership: MaybeSymbol,
      elem_sync: MaybeSymbol,
      elem_layout: MaybeSymbol,
      link_source: MaybeSymbol,
      observable: MaybeBoolean,
      observable_terminal: MaybeSymbol,
      observable_token: MaybeToken,
      polymorphic_shared: MaybeBoolean
    ).returns(TypeCapabilities)
  end
  def with(
    ownership: UNSET,
    ownership_set: UNSET,
    sync: UNSET,
    layout: UNSET,
    lock_rank: UNSET,
    collection: UNSET,
    shard_count: UNSET,
    soa: UNSET,
    elem_ownership: UNSET,
    elem_sync: UNSET,
    elem_layout: UNSET,
    link_source: UNSET,
    observable: UNSET,
    observable_terminal: UNSET,
    observable_token: UNSET,
    polymorphic_shared: UNSET
  )
    next_ownership = T.let(ownership.equal?(UNSET) ? self.ownership : T.cast(ownership, T.nilable(Symbol)), T.nilable(Symbol))
    next_ownership_set = T.let(
      ownership_set.equal?(UNSET) ? (!ownership.equal?(UNSET) || self.ownership_set) : T.cast(ownership_set, T::Boolean),
      T::Boolean
    )
    next_sync = T.let(sync.equal?(UNSET) ? self.sync : T.cast(sync, T.nilable(Symbol)), T.nilable(Symbol))
    next_layout = T.let(layout.equal?(UNSET) ? self.layout : T.cast(layout, T.nilable(Symbol)), T.nilable(Symbol))
    next_lock_rank = T.let(lock_rank.equal?(UNSET) ? self.lock_rank : T.cast(lock_rank, T.nilable(Integer)), T.nilable(Integer))
    next_collection = T.let(collection.equal?(UNSET) ? self.collection : T.cast(collection, T.nilable(Symbol)), T.nilable(Symbol))
    next_shard_count = T.let(shard_count.equal?(UNSET) ? self.shard_count : T.cast(shard_count, T.nilable(Integer)), T.nilable(Integer))
    next_soa = T.let(soa.equal?(UNSET) ? self.soa : T.cast(soa, T::Boolean), T::Boolean)
    next_elem_ownership = T.let(elem_ownership.equal?(UNSET) ? self.elem_ownership : T.cast(elem_ownership, T.nilable(Symbol)), T.nilable(Symbol))
    next_elem_sync = T.let(elem_sync.equal?(UNSET) ? self.elem_sync : T.cast(elem_sync, T.nilable(Symbol)), T.nilable(Symbol))
    next_elem_layout = T.let(elem_layout.equal?(UNSET) ? self.elem_layout : T.cast(elem_layout, T.nilable(Symbol)), T.nilable(Symbol))
    next_link_source = T.let(link_source.equal?(UNSET) ? self.link_source : T.cast(link_source, T.nilable(Symbol)), T.nilable(Symbol))
    next_observable = T.let(observable.equal?(UNSET) ? self.observable : T.cast(observable, T::Boolean), T::Boolean)
    next_observable_terminal = T.let(observable_terminal.equal?(UNSET) ? self.observable_terminal : T.cast(observable_terminal, T.nilable(Symbol)), T.nilable(Symbol))
    next_observable_token = T.let(observable_token.equal?(UNSET) ? self.observable_token : T.cast(observable_token, T.nilable(Lexer::Token)), T.nilable(Lexer::Token))
    next_polymorphic_shared = T.let(polymorphic_shared.equal?(UNSET) ? self.polymorphic_shared : T.cast(polymorphic_shared, T::Boolean), T::Boolean)

    return self if next_ownership == self.ownership && next_ownership_set == self.ownership_set &&
      next_sync == self.sync && next_layout == self.layout && next_lock_rank == self.lock_rank &&
      next_collection == self.collection && next_shard_count == self.shard_count && next_soa == self.soa &&
      next_elem_ownership == self.elem_ownership && next_elem_sync == self.elem_sync &&
      next_elem_layout == self.elem_layout && next_link_source == self.link_source &&
      next_observable == self.observable && next_observable_terminal == self.observable_terminal &&
      next_observable_token == self.observable_token && next_polymorphic_shared == self.polymorphic_shared

    TypeCapabilities.new(
      ownership: next_ownership,
      ownership_set: next_ownership_set,
      sync: next_sync,
      layout: next_layout,
      lock_rank: next_lock_rank,
      collection: next_collection,
      shard_count: next_shard_count,
      soa: next_soa,
      elem_ownership: next_elem_ownership,
      elem_sync: next_elem_sync,
      elem_layout: next_elem_layout,
      link_source: next_link_source,
      observable: next_observable,
      observable_terminal: next_observable_terminal,
      observable_token: next_observable_token,
      polymorphic_shared: next_polymorphic_shared
    )
  end

  sig { returns(TypeCapabilities) }
  def without_runtime_wrappers
    with(
      ownership: :affine,
      ownership_set: false,
      sync: nil,
      layout: nil,
      elem_ownership: nil,
      elem_sync: nil,
      elem_layout: nil
    )
  end

  sig { returns(T::Boolean) }
  def inline_migration_safe?
    return false unless lock_rank.nil? && elem_ownership.nil? && elem_sync.nil? &&
      elem_layout.nil? && link_source.nil? && observable_terminal.nil?
    return false if polymorphic_shared

    collection.nil? || collection == :list || collection == :set || collection == :pool
  end

  sig { returns(T::Boolean) }
  def explicit_layer_capability?
    (!ownership.nil? && ownership != :affine) || !sync.nil? || !layout.nil? || !lock_rank.nil? ||
      !shard_count.nil? || soa || !elem_ownership.nil? || !elem_sync.nil? ||
      !elem_layout.nil? || !link_source.nil? || observable ||
      !observable_terminal.nil? || polymorphic_shared
  end

  sig { params(ownership: MaybeSymbol, sync: MaybeSymbol, layout: MaybeSymbol).returns(T::Boolean) }
  def element_update_requested?(ownership:, sync:, layout:)
    !ownership.equal?(UNSET) || !sync.equal?(UNSET) || !layout.equal?(UNSET) ||
      !elem_ownership.nil? || !elem_sync.nil? || !elem_layout.nil?
  end
end

class TypePlacementUnset < T::Struct
end

class TypePlacement < T::Struct
  extend T::Sig

  UNSET = T.let(TypePlacementUnset.new.freeze, TypePlacementUnset)
  MaybeSymbol = T.type_alias { T.any(TypePlacementUnset, Symbol, NilClass) }

  const :provenance, T.nilable(Symbol), default: nil

  sig { params(provenance: MaybeSymbol).returns(TypePlacement) }
  def with(provenance: TypePlacement::UNSET)
    next_provenance = T.let(provenance.equal?(UNSET) ? self.provenance : T.cast(provenance, T.nilable(Symbol)), T.nilable(Symbol))

    TypePlacement.new(
      provenance: next_provenance
    )
  end

  sig { returns(T.nilable(Symbol)) }
  def location
    provenance
  end

  sig { returns(TypePlacement) }
  def copy
    with
  end

  sig { returns(T::Boolean) }
  def heap?
    provenance == :heap
  end

  sig { returns(T::Boolean) }
  def frame?
    provenance == :frame
  end

  sig { returns(T::Boolean) }
  def rodata?
    provenance == :rodata
  end

  sig { returns(T.nilable(Symbol)) }
  def alloc
    case provenance
    when :heap then :heap
    when :frame then :frame
    end
  end
end

# ruby-to-clear: value
class Type
  ArrayCapacity = T.type_alias { T.nilable(T.any(Integer, Symbol)) }

  # ruby-to-clear: pub
  class FunctionTypeParam < T::Struct
    const :type, Type
  end

  # ruby-to-clear: pub
  class FunctionType < T::Struct
    const :params, T::Array[FunctionTypeParam]
    const :return_type, Type
    const :reentrant, T::Boolean, default: false
    const :source_signature, T.nilable(BasicObject), default: nil
    const :abi, Symbol, default: :clear
  end
end

require_relative "type_expression"

# ruby-to-clear: value
class TypeShape < T::Struct
  extend T::Sig

  Raw = T.type_alias { T.any(Type::FunctionType, Symbol, String) }
  CORE_CACHE_LIMIT = 4096
  CORE_CACHE = T.let({}, T::Hash[String, TypeShape])

  const :auto, T::Boolean
  const :expression, TypeExpression
  const :legacy_raw, Raw
  const :semantic_key_value, String

  sig do
    params(
      raw: Raw,
      auto: T::Boolean,
      expression: T.nilable(TypeExpression),
      optional: T::Boolean,
      wrapped_type_raw: T.nilable(Symbol),
      wrapped_function_type_raw: T.nilable(Type::FunctionType)
    ).returns(TypeShape)
  end
  def self.from_raw(
    raw:,
    auto: false,
    expression: nil,
    optional: false,
    wrapped_type_raw: nil,
    wrapped_function_type_raw: nil
  )
    parsed = T.let(expression || TypeExpressionParser.parse(raw), TypeExpression)
    if optional
      if wrapped_function_type_raw
        parsed = OptionalTypeExpression.new(inner: TypeExpressionParser.parse(wrapped_function_type_raw))
      elsif wrapped_type_raw
        parsed = OptionalTypeExpression.new(inner: TypeExpressionParser.parse(wrapped_type_raw))
      end
    end
    TypeShape.new(
      auto: auto,
      expression: parsed,
      legacy_raw: render_legacy_raw(parsed),
      semantic_key_value: TypeExpressionPrinter.semantic(parsed),
    )
  end

  sig { params(core_str: String, auto: T::Boolean).returns(TypeShape) }
  def self.from_core(core_str, auto: false)
    key = T.let("#{auto}:#{core_str}", String)
    cached = CORE_CACHE[key]
    return cached if cached

    shape = TypeShape.from_raw(raw: core_str.to_sym, auto: auto)
    if CORE_CACHE.length >= CORE_CACHE_LIMIT
      key_to_evict = CORE_CACHE.keys.first
      CORE_CACHE.delete(key_to_evict) if key_to_evict
    end
    CORE_CACHE[key] = shape
    shape
  end

  sig { returns(TypeShape) }
  def copy
    self
  end

  sig { params(auto_value: T::Boolean).returns(TypeShape) }
  def copy_with_auto(auto_value)
    return self if auto_value == auto

    TypeShape.from_raw(raw: raw, auto: auto_value, expression: expression)
  end

  sig { params(next_expression: TypeExpression).returns(TypeShape) }
  def with_expression(next_expression)
    TypeShape.from_raw(raw: :Any, auto: auto, expression: next_expression)
  end

  sig { returns(Raw) }
  def raw
    legacy_raw
  end

  sig { returns(String) }
  def semantic_key
    semantic_key_value
  end

  private

  sig { params(current: TypeExpression).returns(Raw) }
  def self.render_legacy_raw(current)
    return current.signature if current.is_a?(FunctionTypeExpression)

    root_caps = TypeExpressionTree.root_capabilities(current)
    shape_only = TypeExpressionTree.with_root_capabilities(
      current,
      TypeCapabilities.new(ownership: :affine, collection: root_caps.collection)
    )
    TypeExpressionPrinter.legacy(shape_only).to_sym
  end

  public

  sig { returns(Symbol) }
  def resolved
    raw_value = raw
    case raw_value
    when Type::FunctionType then :Any
    when Symbol then raw_value
    when String then raw_value.to_sym
    else T.absurd(raw_value)
    end
  end

  sig { returns(T::Boolean) }
  def fn_type?
    expression.is_a?(FunctionTypeExpression)
  end

  sig { returns(T::Boolean) }
  def array
    !linear_expression.nil?
  end

  sig { returns(T::Boolean) }
  def map
    structural_expression.is_a?(MapTypeExpression)
  end

  sig { returns(T::Boolean) }
  def optional
    current = expression
    current = current.inner if current.is_a?(FallibleTypeExpression)
    current.is_a?(OptionalTypeExpression) ||
      (current.is_a?(LinearTypeExpression) && current.item.is_a?(OptionalTypeExpression))
  end

  sig { returns(T::Boolean) }
  def error_union
    expression.is_a?(FallibleTypeExpression)
  end

  sig { returns(T::Boolean) }
  def tense
    expression.is_a?(FutureTypeExpression) || expression.is_a?(StreamTypeExpression)
  end

  sig { returns(T::Boolean) }
  def generic_instance
    structural = structural_expression
    structural.is_a?(TupleTypeExpression) ||
      (structural.is_a?(NamedTypeExpression) && !structural.arguments.empty?)
  end

  sig { returns(Type::ArrayCapacity) }
  def capacity
    linear = linear_expression
    return nil if linear.nil?

    if linear.dimensions.length > 1
      return nil unless linear.dimensions.all? { |dimension| dimension.is_a?(Integer) }

      return linear.dimensions.reduce(1) { |product, dimension| product * T.cast(dimension, Integer) }
    end

    dimension = linear.dimensions.last
    dimension == :LIST ? nil : dimension
  end

  sig { returns(T.nilable(Integer)) }
  def allocation_hint
    linear_expression&.allocation_hint
  end

  sig { returns(T.nilable(Symbol)) }
  def payload_type_raw
    current = expression
    return nil unless current.is_a?(FallibleTypeExpression)

    TypeExpressionPrinter.legacy(current.inner).to_sym
  end

  sig { returns(T.nilable(Symbol)) }
  def wrapped_type_raw
    current = expression
    return nil unless current.is_a?(OptionalTypeExpression)
    return nil if current.inner.is_a?(FunctionTypeExpression)

    TypeExpressionPrinter.legacy(current.inner).to_sym
  end

  sig { returns(T.nilable(Type::FunctionType)) }
  def wrapped_function_type_raw
    current = expression
    return nil unless current.is_a?(OptionalTypeExpression)
    inner = current.inner
    return nil unless inner.is_a?(FunctionTypeExpression)

    inner.signature
  end

  sig { returns(T.nilable(Symbol)) }
  def element_type_raw
    linear = linear_expression
    return nil if linear.nil?

    item = linear.item
    item = item.inner if item.is_a?(OptionalTypeExpression)
    TypeExpressionPrinter.legacy(item).to_sym
  end

  sig { returns(T.nilable(Symbol)) }
  def key_type_raw
    structural = structural_expression
    return nil unless structural.is_a?(MapTypeExpression)

    TypeExpressionPrinter.legacy(structural.key).to_sym
  end

  sig { returns(T.nilable(Symbol)) }
  def value_type_raw
    structural = structural_expression
    return nil unless structural.is_a?(MapTypeExpression)

    TypeExpressionPrinter.legacy(structural.value).to_sym
  end

  sig { returns(T.nilable(Symbol)) }
  def generic_base_raw
    structural = structural_expression
    return :Tuple if structural.is_a?(TupleTypeExpression)
    return structural.name if structural.is_a?(NamedTypeExpression) && !structural.arguments.empty?

    nil
  end

  sig { returns(T::Array[Symbol]) }
  def generic_args_raw
    structural = structural_expression
    items = if structural.is_a?(TupleTypeExpression)
      structural.items
    elsif structural.is_a?(NamedTypeExpression)
      structural.arguments
    else
      []
    end
    items.map { |item| TypeExpressionPrinter.legacy(item).to_sym }
  end

  sig { returns(T.nilable(Symbol)) }
  def tense_type_raw
    current = expression
    if current.is_a?(StreamTypeExpression)
      dimension = T.let(
        current.cardinality == :FINITE ? :LIST : current.cardinality,
        TypeExpression::Dimension
      )
      linear = LinearTypeExpression.new(kind: :array, dimensions: [dimension], item: current.item)
      return TypeExpressionPrinter.legacy(linear).to_sym
    end
    return nil unless current.is_a?(FutureTypeExpression)

    TypeExpressionPrinter.legacy(current.inner).to_sym
  end

  sig { returns(T::Boolean) }
  def numeric_map?
    map && key_type_raw != :String
  end

  private

  sig { returns(T.nilable(LinearTypeExpression)) }
  def linear_expression
    structural = structural_expression
    return structural if structural.is_a?(LinearTypeExpression)

    nil
  end

  sig { returns(TypeExpression) }
  def structural_expression
    structural = T.let(expression, TypeExpression)
    structural = structural.inner if structural.is_a?(FallibleTypeExpression)
    if structural.is_a?(OptionalTypeExpression) && !structural.inner.is_a?(LinearTypeExpression)
      structural = structural.inner
    end
    structural
  end
end

class TypeFsmForEachDescriptor < T::Struct
  const :kind, Symbol
  const :var_zig_type, String
  const :init_method, T.nilable(String), default: nil
  const :advance_method, T.nilable(String), default: nil
  const :deref, T::Boolean, default: false
  const :slice_suffix, String, default: ""
end

class TypeId < T::Struct
  extend T::Sig

  const :key, String

  sig { returns(String) }
  def to_s
    key
  end
end

# ruby-to-clear: pub
# ruby-to-clear: value
class Type
  extend T::Sig

  class AsyncJoinResult < T::Struct
    extend T::Sig

    const :type, T.nilable(Type), default: nil
    const :reason, T.nilable(Symbol), default: nil

    sig { returns(T::Boolean) }
    def success?
      !type.nil?
    end
  end

  class AsyncJoinEnvelope < T::Struct
    const :payload, Type
    const :optional, T::Boolean, default: false
    const :fallible, T::Boolean, default: false
    const :future, T::Boolean, default: false
  end

  # ruby-to-clear: pub
  TypeInput = T.type_alias { T.any(FunctionType, Type, Symbol, String) }
  ConstructionInput = T.type_alias { T.any(TypeInput, TypeExpression) }
  RawParseInput = T.type_alias { T.any(FunctionType, Symbol, String) }
  TypeNodeInput = T.type_alias { T.untyped }
  sig { returns(TypeShape) }
  attr_reader :shape
  sig { returns(TypeCapabilities) }
  attr_reader :capabilities
  sig { returns(TypePlacement) }
  attr_reader :placement
  sig { params(is_resource: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
  attr_writer :is_resource      # set by annotator; read internally as @is_resource in #resource?

  # Unified provenance: where was this data allocated?
  #   :rodata — string literal in binary, valid forever, never freed
  #   :frame  — frame arena, reclaimed on function exit
  #   :heap   — heap allocated, must be explicitly freed
  #   :borrow — borrowed reference, caller owns data, no cleanup needed
  #   nil     — stack (primitives, small structs); no allocation needed
  # String type constants
  STRING_TYPE = :String
  HEAP_STRING_TYPE = :String

  OWNERSHIP_SURFACE_NAMES = T.let({
    multiowned: "@multiowned",
    shared: "@shared",
    shared_node: "@shared:node",
    split: "@split",
    link: "@link",
    frozen: "@frozen",
  }.freeze, T::Hash[Symbol, String])

  SYNC_SURFACE_NAMES = T.let({
    locked: "@locked",
    write_locked: "@writeLocked",
    versioned: "@versioned",
    atomic: "@atomic",
    always_mutable: "@alwaysMutable",
    local: "@local",
    raw: "@raw",
    symbol: "@symbol",
    c: "@c",
    size: "@size",
  }.freeze, T::Hash[Symbol, String])

  SYNC_FAMILY_NAMES = T.let({
    locked: "locked",
    write_locked: "writeLocked",
    versioned: "versioned",
    atomic: "atomic",
    always_mutable: "alwaysMutable",
    local: "local",
  }.freeze, T::Hash[Symbol, String])

  DEFAULT_SHAPE = T.let(TypeShape.from_raw(raw: :Any).freeze, TypeShape)
  DEFAULT_CAPABILITIES = T.let(TypeCapabilities.new.freeze, TypeCapabilities)
  AFFINE_CAPABILITIES = T.let(TypeCapabilities.new(ownership: :affine).freeze, TypeCapabilities)
  DEFAULT_PLACEMENT = T.let(TypePlacement.new.freeze, TypePlacement)

  class ObservablePublishSpec < T::Struct
    const :publish_method, String
    const :expr, Symbol
    const :gate, Symbol
  end

  class ObservableTerminalSpec < T::Struct
    const :ast_class, T.nilable(Symbol), default: nil
    const :publish, T.nilable(ObservablePublishSpec), default: nil
  end

  ObservableTerminalRegistry = T.type_alias { T::Hash[Symbol, ObservableTerminalSpec] }
  sig { params(value: Type).returns(T::Boolean) }
  def self.indirect_type?(value)
    return false unless value.is_a?(Type)

    value.indirect? == true
  end

  sig { params(type: TypeInput).returns(Type) }
  def self.from_input(type)
    if type.is_a?(Type)
      return copy_type(type)
    elsif type.is_a?(FunctionType)
      return Type.new(type)
    elsif type.is_a?(Symbol)
      return Type.new(type)
    elsif type.is_a?(String)
      return Type.new(type)
    end

    Type.new(:Any)
  end

  sig { params(expression: TypeExpression).returns(Type) }
  def self.from_child_expression(expression)
    Type.new(expression)
  end

  sig { params(types: T::Array[Type]).returns(AsyncJoinResult) }
  def self.join_async_results(types)
    live_types = types.reject { |type| type.resolved == :Never }
    return AsyncJoinResult.new(reason: :empty) if live_types.empty?

    saw_nil = live_types.any? { |type| type.resolved == :NIL }
    envelopes = live_types.reject { |type| type.resolved == :NIL }.map do |type|
      async_join_envelope(type)
    end
    return AsyncJoinResult.new(type: Type.new(:NIL)) if envelopes.empty?

    future_states = envelopes.map { |envelope| envelope.future }.uniq
    return AsyncJoinResult.new(reason: :future_mismatch) if future_states.length > 1
    future = future_states.first == true
    return AsyncJoinResult.new(reason: :future_mismatch) if saw_nil && future

    payload_keys = envelopes.map { |envelope| envelope.payload.semantic_type_key }.uniq
    return AsyncJoinResult.new(reason: :payload_mismatch) if payload_keys.length > 1

    first_envelope = T.must(envelopes.first)
    payload = copy_type(first_envelope.payload)
    expression = payload.shape.expression
    optional = saw_nil || envelopes.any? { |envelope| envelope.optional }
    fallible = envelopes.any? { |envelope| envelope.fallible }
    expression = OptionalTypeExpression.new(inner: expression) if optional
    expression = FallibleTypeExpression.new(inner: expression) if fallible
    expression = FutureTypeExpression.new(inner: expression) if future
    joined = Type.new(expression)
    joined.merge_capabilities_from!(payload, include_affine_ownership: true)
    AsyncJoinResult.new(type: joined)
  end

  sig { params(type: Type).returns(AsyncJoinEnvelope) }
  def self.async_join_envelope(type)
    outer = type.shape.expression
    future = outer.is_a?(FutureTypeExpression)
    after_future = outer.is_a?(FutureTypeExpression) ? outer.inner : outer
    fallible = after_future.is_a?(FallibleTypeExpression)
    after_fallible = after_future.is_a?(FallibleTypeExpression) ? after_future.inner : after_future
    optional = after_fallible.is_a?(OptionalTypeExpression)
    payload_expression = after_fallible.is_a?(OptionalTypeExpression) ? after_fallible.inner : after_fallible
    payload = Type.from_child_expression(payload_expression)
    payload.merge_capabilities_from!(type, include_affine_ownership: true)
    AsyncJoinEnvelope.new(payload: payload, optional: optional, fallible: fallible, future: future)
  end
  private_class_method :async_join_envelope

  # ruby-to-clear: skip
  sig { params(value: BasicObject).returns(T::Boolean) }
  def self.function_signature_like?(value)
    T.unsafe(value).respond_to?(:params) && T.unsafe(value).respond_to?(:return_type) && T.unsafe(value).respond_to?(:reentrant)
  end

  sig { params(vt: Schemas::UnionSchema::VariantValue).returns(Type) }
  def self.from_variant_input(vt)
    return Type.new(:Any) unless vt
    return Type.new(:Any) if vt.is_a?(Schemas::InlineStructVariant)

    Type.from_input(vt)
  end

  sig { params(value: T.nilable(Symbol)).returns(TypeCapabilities::MaybeSymbol) }
  def self.capability_symbol(value)
    value
  end

  sig { params(value: T.nilable(Symbol)).returns(TypeCapabilities::MaybeSymbol) }
  def self.capability_symbol_or_unset(value)
    return TypeCapabilities::UNSET if value.nil?

    value
  end

  sig { params(value: T.nilable(Integer)).returns(TypeCapabilities::MaybeInteger) }
  def self.capability_integer(value)
    value
  end

  sig { params(value: T.nilable(Integer)).returns(TypeCapabilities::MaybeInteger) }
  def self.capability_integer_or_unset(value)
    return TypeCapabilities::UNSET if value.nil?

    value
  end

  sig { params(value: T.nilable(Lexer::Token)).returns(TypeCapabilities::MaybeToken) }
  def self.capability_token(value)
    value
  end

  sig { params(value: T.nilable(Lexer::Token)).returns(TypeCapabilities::MaybeToken) }
  def self.capability_token_or_unset(value)
    return TypeCapabilities::UNSET if value.nil?

    value
  end

  sig { params(value: T.nilable(Symbol)).returns(TypePlacement::MaybeSymbol) }
  def self.placement_symbol(value)
    value
  end

  sig { params(value: T.nilable(Symbol)).returns(TypePlacement::MaybeSymbol) }
  def self.placement_symbol_or_unset(value)
    return TypePlacement::UNSET if value.nil?

    value
  end

  sig do
    params(
      candidate: TypeCapabilities::MaybeSymbol,
      legacy: T.nilable(Symbol)
    ).returns(TypeCapabilities::MaybeSymbol)
  end
  def self.prefer_legacy_element_capability(candidate, legacy)
    return legacy if candidate.equal?(TypeCapabilities::UNSET) && !legacy.nil?

    candidate
  end

  sig do
    params(
      item_updated: T::Boolean,
      candidate: TypeCapabilities::MaybeSymbol
    ).returns(TypeCapabilities::MaybeSymbol)
  end
  def self.root_element_capability(item_updated, candidate)
    return nil if item_updated

    candidate
  end

  sig { params(value: T.nilable(T::Boolean)).returns(TypeCapabilities::MaybeBoolean) }
  def self.capability_observable_or_unset(value)
    return true if value == true

    TypeCapabilities::UNSET
  end

  sig { params(value: T::Boolean).returns(TypeCapabilities::MaybeBoolean) }
  def self.capability_boolean_or_unset(value)
    return true if value

    TypeCapabilities::UNSET
  end

  sig { params(fn: FunctionType).returns(Symbol) }
  # ruby-to-clear: effects reentrant
  def self.function_return_symbol(fn)
    fn.return_type.to_sym
  end

  sig { params(value: Integer).returns(String) }
  def self.integer_string(value)
    value.to_s
  end

  sig { params(value: T.nilable(Symbol)).returns(Symbol) }
  def self.symbol_or_any(value)
    symbol_or_default(value, :Any)
  end

  sig { params(value: T.nilable(Symbol), default_value: Symbol).returns(Symbol) }
  def self.symbol_or_default(value, default_value)
    return default_value if value.nil?

    value
  end

  sig { params(value: T.nilable(Symbol), default_value: Symbol).returns(TypeInput) }
  def self.type_input_symbol_or_default(value, default_value)
    symbol_or_default(value, default_value)
  end

  sig { params(value: T.nilable(Symbol)).returns(TypeInput) }
  def self.type_input_symbol_or_any(value)
    type_input_symbol_or_default(value, :Any)
  end

  sig { params(value: String).returns(TypeInput) }
  def self.type_input_string(value)
    value
  end

  sig { params(capacity: ArrayCapacity).returns(T::Boolean) }
  def self.integer_array_capacity?(capacity)
    return false if capacity.nil?

    capacity.is_a?(Integer)
  end

  sig { params(capacity: ArrayCapacity).returns(Integer) }
  def self.array_capacity_integer(capacity)
    T.cast(capacity, Integer)
  end

  sig { params(capacity: ArrayCapacity).returns(T.nilable(Symbol)) }
  def self.array_capacity_symbol(capacity)
    return nil if capacity.nil?

    cap = capacity
    return cap if cap.is_a?(Symbol)

    nil
  end

  sig { params(expression: TypeExpression).returns(T::Boolean) }
  def self.preallocation_expression?(expression)
    return false unless expression.is_a?(LinearTypeExpression)

    (expression.list? || expression.set?) && !expression.allocation_hint.nil?
  end

  sig { params(value: Symbol).returns(T::Boolean) }
  def self.signed_integer_symbol?(value)
    value == :Int8 || value == :Int16 || value == :Int32 || value == :Int64 ||
      value == :TargetInt || value == :TargetLong || value == :TargetLongLong
  end

  sig { params(value: Symbol).returns(T::Boolean) }
  def self.unsigned_integer_symbol?(value)
    value == :UInt8 || value == :Byte || value == :UInt16 || value == :UInt32 || value == :UInt64 ||
      value == :TargetUInt || value == :TargetULong || value == :TargetULongLong
  end

  sig { params(value: Symbol).returns(T::Boolean) }
  def self.integer_symbol?(value)
    signed_integer_symbol?(value) || unsigned_integer_symbol?(value)
  end

  sig { params(value: Symbol).returns(T::Boolean) }
  def self.float_symbol?(value)
    value == :Float32 || value == :Float64
  end

  sig { params(value: Symbol).returns(T::Boolean) }
  def self.numeric_symbol?(value)
    integer_symbol?(value) || float_symbol?(value)
  end

  sig { params(value: Symbol).returns(T::Boolean) }
  def self.primitive_symbol?(value)
    value == :Number || value == :Bool || numeric_symbol?(value)
  end

  sig { params(value: Symbol).returns(T::Boolean) }
  def self.resource_type_symbol?(value)
    value == :File || value == :TCPClient || value == :TCPServer
  end

  sig { params(value: Symbol).returns(T.nilable(String)) }
  def self.ownership_surface_name_for(value)
    return "@multiowned" if value == :multiowned
    return "@shared" if value == :shared
    return "@node" if value == :node
    return "@shared:node" if value == :shared_node
    return "@split" if value == :split
    return "@link" if value == :link
    return "@frozen" if value == :frozen

    nil
  end

  sig { params(value: Symbol).returns(T.nilable(String)) }
  def self.sync_surface_name_for(value)
    return "@locked" if value == :locked
    return "@writeLocked" if value == :write_locked
    return "@versioned" if value == :versioned
    return "@atomic" if value == :atomic
    return "@alwaysMutable" if value == :always_mutable
    return "@local" if value == :local
    return "@raw" if value == :raw
    return "@symbol" if value == :symbol
    return "@c" if value == :c
    return "@size" if value == :size

    nil
  end

  sig { params(value: Symbol).returns(T.nilable(String)) }
  def self.sync_family_name_for(value)
    return "locked" if value == :locked
    return "writeLocked" if value == :write_locked
    return "versioned" if value == :versioned
    return "atomic" if value == :atomic
    return "alwaysMutable" if value == :always_mutable
    return "local" if value == :local

    nil
  end

  sig { params(value: Symbol).returns(String) }
  def self.zig_type_name_for(value)
    return "f64" if value == :Float64
    return "i64" if value == :Int64
    return "[]const u8" if value == :String
    return "void" if value == :Void
    return "bool" if value == :Bool
    return "u8" if value == :Byte
    return "i8" if value == :Int8
    return "i16" if value == :Int16
    return "i32" if value == :Int32
    return "u8" if value == :UInt8
    return "u16" if value == :UInt16
    return "u32" if value == :UInt32
    return "u64" if value == :UInt64
    return "f32" if value == :Float32
    return "c_int" if value == :TargetInt
    return "c_uint" if value == :TargetUInt
    return "c_long" if value == :TargetLong
    return "c_ulong" if value == :TargetULong
    return "c_longlong" if value == :TargetLongLong
    return "c_ulonglong" if value == :TargetULongLong
    return "f64" if value == :Any
    return "CheatLib.Range" if value == :Range
    return "CheatLib.File" if value == :File
    return "i32" if value == :TCPServer
    return "i32" if value == :TCPClient

    value.to_s
  end

  # ruby-to-clear: skip
  sig { returns(T.untyped) }
  def self.deinit_resource_close_plan
    Schemas::ResourceClosePlan.new(actions: [
      Schemas::ResourceCloseAction.new(
        call_kind: Schemas::ResourceCloseCallKind::Method,
        name: "deinit",
        runtime_heap_alloc_args: 0
      )
    ])
  end

  sig { params(type: Type).returns(Type) }
  def self.copy_type(type)
    copy = Type.new(:Any)
    copy.replace_shape!(type.shape.copy)
    copy.replace_capabilities!(type.capabilities.copy)
    copy.replace_placement!(type.placement.copy)
    copy
  end

  # ruby-to-clear: effects reentrant
  sig { params(type: TypeInput).returns(String) }
  def self.surface_name(type)
    surface_name_type(from_input(type))
  end

  sig { params(type: Type).returns(T.nilable(String)) }
  def self.inline_migration_name(type)
    caps = type.capabilities
    return nil unless caps.inline_migration_safe?

    expression = type.shape.expression
    return nil if expression.is_a?(FunctionTypeExpression)
    # Legacy async collection spellings overload the same surface form for
    # streams, lists of promises, and promises resolving to lists. Migrating
    # only the annotation can change NEXT's result protocol, so those require
    # a whole-program migration and are deliberately not auto-fixed here.
    return nil if TypeExpressionTree.each_node(expression).any? do |node|
      node.is_a?(FutureTypeExpression)
    end
    # A bare legacy T[] is a slice/view, while Inline Pivot []T is an owned
    # dynamic list. Only an explicit legacy @list is semantics-preserving.
    return nil if TypeExpressionTree.each_node(expression).any? do |node|
      unsafe_inline_linear_migration?(node, type)
    end
    if TypeExpressionTree.tense_wrapper?(expression) &&
        expression.capabilities.explicit_layer_capability?
      return nil
    end
    projected = project_inline_collection(expression, type)
    return nil if projected.nil?

    TypeExpressionPrinter.inline(projected)
  end

  sig { params(node: TypeExpression, type: Type).returns(T::Boolean) }
  def self.unsafe_inline_linear_migration?(node, type)
    return false unless node.is_a?(LinearTypeExpression)
    return true if node.dimensions.include?(:INFERRED)

    bare_legacy_slice?(node, type)
  end

  sig { params(node: LinearTypeExpression, type: Type).returns(T::Boolean) }
  def self.bare_legacy_slice?(node, type)
    type.collection.nil? && node.list? && node.capabilities.collection.nil?
  end

  sig { params(expression: TypeExpression, type: Type).returns(T.nilable(TypeExpression)) }
  def self.project_inline_collection(expression, type)
    collection = type.collection
    return expression if collection.nil?
    if expression.is_a?(OptionalTypeExpression)
      inner = project_inline_collection(expression.inner, type)
      return inner.nil? ? nil : OptionalTypeExpression.new(inner: inner)
    end
    if expression.is_a?(FallibleTypeExpression)
      inner = project_inline_collection(expression.inner, type)
      return inner.nil? ? nil : FallibleTypeExpression.new(inner: inner, error_set: expression.error_set)
    end
    return nil unless expression.is_a?(LinearTypeExpression)

    hint = expression.allocation_hint
    if hint.nil? && type.pool?
      pool_dimension = expression.dimensions.find { |dimension| dimension.is_a?(Integer) }
      hint = pool_dimension if pool_dimension.is_a?(Integer)
    end
    # Inline Pivot pools require an explicit capacity (`[Pool(N)]T`). A
    # legacy dynamic `T[]@pool` has no semantics-preserving spelling yet.
    return nil if type.pool? && hint.nil?

    LinearTypeExpression.new(
      kind: collection,
      dimensions: expression.dimensions,
      item: expression.item,
      allocation_hint: hint,
      capabilities: expression.capabilities
    )
  end
  private_class_method :project_inline_collection

  # ruby-to-clear: effects reentrant
  sig { params(t: Type).returns(String) }
  def self.surface_name_type(t)
    return "~#{surface_name_type(t.tense_type)}" if t.tense?
    return "!#{surface_name_type(T.must(t.payload_type))}" if t.error_union?
    if t.optional?
      wrapped = T.must(t.wrapped_type)
      inner = surface_name_type(wrapped)
      return "?(#{inner})" if wrapped.array? || wrapped.map?
      return "?#{inner}"
    end
    return "#{surface_name_type(T.must(t.element_type))}#{array_capacity_suffix(t.capacity)}" if t.array?
    return function_type_surface_name(t) if t.fn_type?

    if t.generic_instance?
      names = T.let(t.generic_args.map { |arg| surface_name_type(arg) }, T::Array[String])
      return "#{t.generic_base}<#{names.join(",")}>"
    end

    t.resolved.to_s
  end

  sig { params(type: TypeInput).returns(String) }
  def self.coercion_surface_name(type)
    t = from_input(type)
    coercion_surface_name_type(t)
  end

  sig { params(t: Type).returns(String) }
  def self.coercion_surface_name_type(t)
    "#{surface_name_type(t)}#{t.sync_surface_name}"
  end

  sig { params(element_type: TypeInput, capacity: ArrayCapacity).returns(Type) }
  def self.array_of(element_type, capacity: nil)
    element = from_input(element_type)
    item_expression = TypeExpressionTree.with_root_capabilities(
      element.shape.expression,
      element.capabilities
    )
    dimension = T.let(capacity.nil? ? :LIST : capacity, TypeExpression::Dimension)
    dimensions = T.let([dimension], T::Array[TypeExpression::Dimension])
    kind = T.let(capacity.nil? ? :list : :array, Symbol)
    collection_capabilities = if capacity.nil?
      TypeCapabilities.new(ownership: :affine, collection: :list)
    else
      TypeCapabilities.new(ownership: :affine)
    end
    Type.new(
      LinearTypeExpression.new(
        kind: kind,
        dimensions: dimensions,
        item: item_expression,
        capabilities: collection_capabilities,
      )
    )
  end

  # A dynamically-sized collection of asynchronous handles. Keep the future
  # outside the linear collection in the semantic tree so `name:~` and NEXT
  # can distinguish a promise list from an ordinary `[]~T` list of values.
  sig { params(element_type: TypeInput).returns(Type) }
  def self.promise_list_of(element_type)
    list = array_of(element_type)
    Type.new(
      FutureTypeExpression.new(
        inner: list.shape.expression,
        capabilities: TypeCapabilities.new(ownership: :affine, collection: :list),
      )
    )
  end

  sig { params(element_type: TypeInput, capacity: T.nilable(Integer)).returns(Type) }
  def self.set_of(element_type, capacity: nil)
    element = from_input(element_type)
    item_expression = TypeExpressionTree.with_root_capabilities(
      element.shape.expression,
      element.capabilities
    )
    Type.new(
      LinearTypeExpression.new(
        kind: :set,
        dimensions: [:SET],
        item: item_expression,
        allocation_hint: capacity,
        capabilities: TypeCapabilities.new(collection: :set),
      )
    )
  end

  sig { params(payload_type: TypeInput).returns(Type) }
  def self.error_union_of(payload_type)
    Type.new("!#{surface_name(payload_type)}")
  end

  sig { params(wrapped_type: TypeInput).returns(Type) }
  # ruby-to-clear: effects reentrant
  def self.optional_of(wrapped_type)
    wrapped = Type.new(wrapped_type)
    return wrapped if wrapped.optional?

    t = Type.new(OptionalTypeExpression.new(inner: wrapped.shape.expression))
    t.merge_capabilities_from!(wrapped, include_affine_ownership: true)
    t.copy_placement_from!(wrapped, preserve_existing: false)
    t
  end

  sig { params(value_type: TypeInput).returns(Type) }
  def self.tense_of(value_type)
    Type.new("~#{surface_name(value_type)}")
  end

  sig { params(base: Symbol, args: T::Array[TypeInput]).returns(Type) }
  def self.generic_instance_of(base, args)
    names = T.let(args.map { |arg| surface_name(arg) }, T::Array[String])
    Type.new("#{base}<#{names.join(",")}>")
  end

  sig { params(item_type: TypeInput).returns(Type) }
  def self.stream_step_of(item_type)
    generic_instance_of(:StreamStep, [item_type])
  end

  sig { params(param_types: T::Array[Type], return_type: Type, reentrant: T::Boolean, source_signature: T.nilable(BasicObject), abi: Symbol).returns(Type) }
  def self.function_type_from_parts(param_types, return_type, reentrant, source_signature, abi = :clear)
    params = T.let([], T::Array[FunctionTypeParam])
    i = T.let(0, Integer)
    while i < param_types.length
      params << FunctionTypeParam.new(type: copy_type(T.must(param_types[i])))
      i += 1
    end

    Type.new(FunctionType.new(
      params: params,
      return_type: copy_type(return_type),
      reentrant: reentrant,
      source_signature: source_signature,
      abi: abi,
    ))
  end

  sig { params(capacity: ArrayCapacity).returns(String) }
  def self.array_capacity_suffix(capacity)
    return "[]" if capacity.nil?

    cap = array_capacity_symbol(capacity)
    unless cap.nil?
      symbol_capacity = cap
      return "[?]" if symbol_capacity == :STREAM_OPEN
      return "[INF]" if symbol_capacity == :INF
    end

    return "[#{integer_string(array_capacity_integer(capacity))}]" if integer_array_capacity?(capacity)

    "[]"
  end

  sig { params(capacity: ArrayCapacity).returns(String) }
  def self.array_capacity_label(capacity)
    return "unknown" if capacity.nil?

    return integer_string(array_capacity_integer(capacity)) if integer_array_capacity?(capacity)

    cap = array_capacity_symbol(capacity)
    unless cap.nil?
      symbol_capacity = cap
      return "STREAM_OPEN" if symbol_capacity == :STREAM_OPEN
      return "INF" if symbol_capacity == :INF
    end

    "unknown"
  end

  sig { params(type: Type).returns(String) }
  # ruby-to-clear: effects reentrant
  def self.function_type_surface_name(type)
    fn_raw = T.must(type.function_type)
    params = fn_raw.params.map { |param| surface_name_type(param.type) }

    callconv = fn_raw.abi == :c ? " CALLCONV C" : ""
    "FN(#{params.join(', ')}) -> #{surface_name_type(fn_raw.return_type)}#{callconv}"
  end

  # Operator categories
  EQUALITY_OPS = [:EQ, :NEQ].freeze
  ORDERING_OPS = [:LT, :GT, :LTE, :GTE].freeze
  LOGICAL_OPS = [:AND, :OR].freeze
  BITWISE_OPS = [:XOR, :BIT_AND, :BIT_OR].freeze
  SHIFT_OPS = [:SHL, :SHR].freeze
  BOOL_RESULT_OPS = T.let((EQUALITY_OPS + ORDERING_OPS).freeze, T::Array[Symbol])
  NUMBER_RESULT_OPS = [:SUB, :MUL, :DIV, :POW, :MOD, :WRAP_SUB, :WRAP_MUL, :CHECK_SUB, :CHECK_MUL]

  sig { params(op: Symbol).returns(T::Boolean) }
  def self.logical_op?(op)
    op == :AND || op == :OR
  end

  sig { params(op: Symbol).returns(T::Boolean) }
  def self.equality_op?(op)
    op == :EQ || op == :NEQ
  end

  sig { params(op: Symbol).returns(T::Boolean) }
  def self.ordering_op?(op)
    op == :LT || op == :GT || op == :LTE || op == :GTE
  end

  sig { params(op: Symbol).returns(T::Boolean) }
  def self.bool_result_op?(op)
    equality_op?(op) || ordering_op?(op)
  end

  sig { params(op: Symbol).returns(T::Boolean) }
  def self.number_result_op?(op)
    op == :SUB ||
      op == :MUL ||
      op == :DIV ||
      op == :POW ||
      op == :MOD ||
      op == :WRAP_SUB ||
      op == :WRAP_MUL ||
      op == :CHECK_SUB ||
      op == :CHECK_MUL
  end

  sig { params(op: Symbol).returns(T::Boolean) }
  def self.bitwise_op?(op)
    BITWISE_OPS.include?(op)
  end

  sig { params(op: Symbol).returns(T::Boolean) }
  def self.shift_op?(op)
    SHIFT_OPS.include?(op)
  end

  # Resolves the result type of a binary operation given two operand types.
  # Returns a BinaryOpResult with type, optional coercions, and storage.
  sig { params(op: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.binary_op(op, left_type, right_type)
    # Gradual-typing tolerance: if either operand is an unresolved
    # Auto, the body-validation pass would crash with
    # "Cannot add types: Auto and Auto" before the unifier ever runs.
    # The result type depends on the OPERATOR class:
    #   * boolean-result ops (==, !=, <, >, ..., AND, OR) always
    #     produce Bool regardless of operand types — keep that.
    #   * arithmetic / numeric ops produce Auto (depends on operands)
    #     — the AutoUnifier resolves it after observing concrete
    #     types at the constraint sources.
    auto_present = left_type.auto? || right_type.auto?
    if auto_present
      return BinaryOpResult.new(type: Type.new(:String), storage: :frame) if op == :CONCAT

      if logical_op?(op) || bool_result_op?(op)
        return BinaryOpResult.new(type: Type.new(:Bool))
      end

      return BinaryOpResult.new(type: Type.new(:Auto, auto: true))
    end

    t_left = left_type.resolved
    t_right = right_type.resolved

    return resolve_logical_op(op, left_type, right_type) if logical_op?(op)
    return resolve_equality_op(op, left_type, right_type) if equality_op?(op)
    return resolve_ordering_op(op, left_type, right_type) if ordering_op?(op)
    return resolve_integer_op(op, left_type, right_type, preserve_left: shift_op?(op)) if bitwise_op?(op) || shift_op?(op)
    return resolve_numeric_op(left_type, right_type) if number_result_op?(op) || op == :WRAP_ADD || op == :CHECK_ADD
    return resolve_concat_op(t_left, t_right, left_type, right_type) if op == :CONCAT
    return resolve_add_op(t_left, t_right, left_type, right_type) if op == :ADD

    BinaryOpResult.new(error: "Unknown operator: #{op}")
  end

  # Returns error message if source cannot be coerced to target, nil if ok.
  #
  # @param source_type [Type, Symbol, String] The type being assigned
  # @param target_type [Type, Symbol, String] The declared/expected type
  # @return [String, nil] Error message or nil if coercion is valid
  #
  sig { params(source_type: Type, target_type: TypeInput).returns(T.nilable(String)) }
  def self.coerce_error(source_type, target_type)
    target = from_input(target_type)

    # Gradual-typing tolerance: an Auto target accepts any source —
    # the AutoUnifier resolves the target's concrete type after the
    # body walk, mutating the decl in place. Source-side Auto is
    # similarly tolerated: the source expression's resolved type
    # propagates once the unifier pins the slot it depends on.
    return nil if target.auto?
    return nil if source_type.auto?

    return nil if target.accepts?(source_type)

    if target.array_overflow?(source_type)
      "Cannot initialize array of size #{array_capacity_label(target.capacity)} with #{array_capacity_label(source_type.capacity)} elements"
    else
      "Type Mismatch: Cannot assign #{coercion_surface_name_type(source_type)} to #{coercion_surface_name_type(target)}"
    end
  end

  private

  sig { params(op: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_logical_op(op, left_type, right_type)
    return BinaryOpResult.new(type: Type.new(:Bool)) if left_type.resolved == :Bool && right_type.resolved == :Bool
    BinaryOpResult.new(error: "Operator #{op} requires Bool operands, got #{left_type.resolved} and #{right_type.resolved}")
  end

  sig { params(op: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_equality_op(op, left_type, right_type)
    return BinaryOpResult.new(type: Type.new(:Bool)) if equality_compatible?(left_type, right_type)
    BinaryOpResult.new(error: "Operator #{op} cannot compare #{left_type.resolved} with #{right_type.resolved}")
  end

  sig { params(op: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_ordering_op(op, left_type, right_type)
    return BinaryOpResult.new(type: Type.new(:Bool)) if ordered_compatible?(left_type, right_type)
    BinaryOpResult.new(error: "Operator #{op} requires ordered operands, got #{left_type.resolved} and #{right_type.resolved}")
  end

  sig { params(op: Symbol, left_type: Type, right_type: Type, preserve_left: T::Boolean).returns(BinaryOpResult) }
  def self.resolve_integer_op(op, left_type, right_type, preserve_left:)
    if left_type.any? || right_type.any?
      return BinaryOpResult.new(type: Type.new(:Any))
    end

    unless left_type.integer? && right_type.integer?
      return BinaryOpResult.new(
        error: "Operator #{op} requires integer operands, got #{left_type.resolved} and #{right_type.resolved}"
      )
    end

    return BinaryOpResult.new(type: copy_type(left_type)) if preserve_left

    resolve_numeric_op(left_type, right_type)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.equality_compatible?(left_type, right_type)
    return true if left_type.any? || right_type.any? ||
      optional_any_comparable?(left_type, right_type)

    left_type.resolved == right_type.resolved ||
      optional_nil_comparable?(left_type, right_type) ||
      optional_payload_comparable?(left_type, right_type) ||
      scalar_comparable?(left_type, right_type)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.optional_any_comparable?(left_type, right_type)
    (left_type.optional? && T.must(left_type.wrapped_type).any?) ||
      (right_type.optional? && T.must(right_type.wrapped_type).any?)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.ordered_compatible?(left_type, right_type)
    scalar_comparable?(left_type, right_type) ||
      optional_payload_ordered_comparable?(left_type, right_type)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.scalar_comparable?(left_type, right_type)
    (left_type.numeric? && right_type.numeric?) ||
      (left_type.string? && right_type.string?) ||
      same_generic_parameter?(left_type, right_type)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.optional_nil_comparable?(left_type, right_type)
    (left_type.optional? && right_type.resolved == :NIL) ||
      (right_type.optional? && left_type.resolved == :NIL)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.optional_payload_comparable?(left_type, right_type)
    return false unless left_type.optional? != right_type.optional?

    return payload_comparable?(T.must(left_type.wrapped_type), right_type) if left_type.optional?

    payload_comparable?(T.must(right_type.wrapped_type), left_type)
  end

  sig { params(inner_type: Type, payload_type: Type).returns(T::Boolean) }
  def self.payload_comparable?(inner_type, payload_type)
    inner_type.resolved == payload_type.resolved || scalar_comparable?(inner_type, payload_type)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.optional_payload_ordered_comparable?(left_type, right_type)
    return false unless left_type.optional? != right_type.optional?

    if left_type.optional?
      return scalar_comparable?(T.must(left_type.wrapped_type), right_type)
    end

    scalar_comparable?(T.must(right_type.wrapped_type), left_type)
  end

  sig { params(left_type: Type, right_type: Type).returns(T::Boolean) }
  def self.same_generic_parameter?(left_type, right_type)
    left_type.generic_type_parameter? &&
      right_type.generic_type_parameter? &&
      left_type.resolved == right_type.resolved
  end

  sig { params(left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_numeric_op(left_type, right_type)
    t_left = left_type.resolved
    t_right = right_type.resolved

    if left_type.any? || right_type.any?
      return BinaryOpResult.new(type: Type.new(:Any))
    end

    if same_generic_parameter?(left_type, right_type)
      return BinaryOpResult.new(type: copy_type(left_type))
    end

    unless left_type.numeric? && right_type.numeric?
      return BinaryOpResult.new(error: "Numeric operator requires numeric operands, got #{t_left} and #{t_right}")
    end

    # Same type: result is that type
    if t_left == t_right
      return BinaryOpResult.new(type: copy_type(left_type))
    end

    # Both integers: promote to the wider type (use Int64 as default)
    if left_type.integer? && right_type.integer?
      if t_left == :Int64
        return BinaryOpResult.new(type: copy_type(left_type),
          left_coercion: nil,
          right_coercion: t_right == :Int64 ? nil : :Int64)
      end

      return BinaryOpResult.new(type: copy_type(right_type),
        left_coercion: :Int64,
        right_coercion: t_right == :Int64 ? nil : :Int64)
    end

    # Both floats: promote to f64
    if left_type.float? && right_type.float?
      if t_left == :Float64
        return BinaryOpResult.new(type: copy_type(left_type),
          left_coercion: nil,
          right_coercion: t_right == :Float64 ? nil : :Float64)
      end

      return BinaryOpResult.new(type: copy_type(right_type),
        left_coercion: :Float64,
        right_coercion: t_right == :Float64 ? nil : :Float64)
    end

    # Mixed int/float: promote integer operand to the float type
    if left_type.integer? && right_type.float?
      return BinaryOpResult.new(type: copy_type(right_type), left_coercion: t_right)
    end
    if left_type.float? && right_type.integer?
      return BinaryOpResult.new(type: copy_type(left_type), right_coercion: t_left)
    end

    BinaryOpResult.new(type: Type.new(:Float64))
  end

  sig { params(t_left: Symbol, t_right: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_add_op(t_left, t_right, left_type, right_type)
    lt = Type.new(t_left.to_s.to_sym)
    rt = Type.new(t_right.to_s.to_sym)

    if same_generic_parameter?(left_type, right_type)
      return BinaryOpResult.new(type: copy_type(left_type))
    end

    # A. Numeric addition (all int/float types)
    if lt.numeric? && rt.numeric?
      return resolve_numeric_op(left_type, right_type)
    end

    # B. Array Concatenation
    if left_type.array? && right_type.array?
      return BinaryOpResult.new(type: copy_type(left_type), storage: :frame)
    end

    BinaryOpResult.new(error: "Cannot add types: #{t_left} and #{t_right}")
  end

  sig { params(t_left: Symbol, t_right: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_concat_op(t_left, t_right, left_type, right_type)
    unless left_type.string? || right_type.string?
      return BinaryOpResult.new(error: "Operator $+ requires at least one String operand, got #{t_left} and #{t_right}")
    end

    left_coercion = (!left_type.string? && safe_autocast?(t_left, :String)) ? :String : nil
    right_coercion = (!right_type.string? && safe_autocast?(t_right, :String)) ? :String : nil
    BinaryOpResult.new(type: Type.new(:String), left_coercion: left_coercion,
      right_coercion: right_coercion, storage: :frame)
  end

  sig { params(from_type: Symbol, to_type: Symbol).returns(T::Boolean) }
  def self.safe_autocast?(from_type, to_type)
    from_t = Type.new(from_type.to_s.to_sym)
    to_t   = Type.new(to_type.to_s.to_sym)
    return false if from_t.fn_type? || to_t.fn_type?
    # Any numeric -> any numeric (implicit promotion/narrowing handled by Zig casts)
    return true if from_t.numeric? && to_t.numeric?
    # Original types that can auto-cast to strings
    [:Float64, :Int64, :Bool, :Byte].include?(from_t.resolved)
  end

  public

  sig do
    params(
      raw_input: ConstructionInput,
      ownership: T.nilable(Symbol),
      sync: T.nilable(Symbol),
      layout: T.nilable(Symbol),
      location: T.nilable(Symbol),
      collection: T.nilable(Symbol),
      shard_count: T.nilable(Integer),
      stripe_count: T.nilable(Integer),
      observable: T.nilable(T::Boolean),
      observable_terminal: T.nilable(Symbol),
      auto: T::Boolean
    ).void
  end
  def initialize(raw_input, ownership: nil, sync: nil, layout: nil, location: nil, collection: nil, shard_count: nil, stripe_count: nil, observable: nil, observable_terminal: nil, auto: false) # stripe_count kept for backwards compat (ignored)
    @shape              = T.let(DEFAULT_SHAPE, TypeShape)
    @capabilities       = T.let(TypeCapabilities.new, TypeCapabilities)
    @placement          = T.let(TypePlacement.new, TypePlacement)
    @is_resource        = T.let(nil, T.nilable(T::Boolean))
    @auto_token         = T.let(nil, T.nilable(Lexer::Token))
    @generic_payload_type_arg = T.let(false, T::Boolean)
    if raw_input.is_a?(Type)
      @shape              = raw_input.shape.copy
      @shape              = @shape.copy_with_auto(true) if auto
      @capabilities       = raw_input.capabilities.copy
      @placement          = raw_input.placement.copy
      @auto_token         = raw_input.auto_token
      @generic_payload_type_arg = raw_input.generic_payload_type_arg?
    elsif raw_input.is_a?(TypeExpression)
      parse_expression_input!(raw_input, auto: auto)
    elsif raw_input.is_a?(FunctionType)
      parse_function_type_input!(raw_input, auto: auto)
    elsif raw_input.is_a?(Symbol)
      parse_raw_string!(raw_input.to_s, auto: auto)
    elsif raw_input.is_a?(String)
      parse_raw_string!(raw_input, auto: auto)
    end

    # Capability fields — set after parse/copy so explicit constructor
    # overrides can replace the parsed/default capability state. Most Type
    # construction uses the parsed default, so avoid the generic merge path
    # unless there is an actual override.
    apply_declared_location!(location)
    if !ownership.nil? || !sync.nil? || !layout.nil? || !collection.nil? || !shard_count.nil? || observable == true || !observable_terminal.nil?
      apply_capabilities!(
        ownership: Type.capability_symbol_or_unset(ownership),
        sync: Type.capability_symbol_or_unset(sync),
        layout: Type.capability_symbol_or_unset(layout),
        collection: Type.capability_symbol_or_unset(collection),
        shard_count: Type.capability_integer_or_unset(shard_count),
        observable: Type.capability_observable_or_unset(observable),
        observable_terminal: Type.capability_symbol_or_unset(observable_terminal)
      )
    end
    # Sync types need a stable heap address.
    # :raw and :symbol are data-access modes, not locks — they don't force heap provenance.
    pin_heap_for_sync_wrapper! if sync_requires_heap_provenance?
    # `:indirect` layout is the explicit "heap-pinned cell with a stable
    # address" form (used by @boxed:atomic = AtomicPtr(T)). Force heap
    # provenance even without an active sync, mirroring the @boxed
    # CapabilityWrap branch in the annotator (annotator.rb:3517).
    pin_heap_for_indirect! if indirect?
    # Symbol strings live in static read-only memory — always rodata, never heap/frame.
    mark_rodata! if symbol?
    # Pool collection always lives on the heap (owns internal slot array).
    pin_heap_for_collection! if pool?
    # Gradual-typing placeholder. When set, this Type represents an
    # unresolved Auto slot — the inference pass (see
    # docs/agents/gradual-typing.md) walks every Auto Type, collects
    # constraints from observed uses, and replaces the Type with a
    # resolved one before the body-validation pass runs.
    # Only overwrite when explicitly requested so the copy-constructor
    # path (`Type.new(other_type)`) preserves auto-ness from `other`.
  end

  # Stable enum of how a value's storage flows through escape paths.
  # Each case answers ALL of:
  #   - "is BG capture an independent instance?"  (`bg_capture_is_value_copy?`)
  #   - "does escape require heap-dupe?"          (`needs_escape_promotion?`)
  #   - "can implicit Copy in branch merge?"      (`implicitly_copyable?` — modulo schema)
  #
  # IMPORTANT: computed lazily, NOT cached at construction. Type's
  # capability fields (@collection, @sync, @ownership, @provenance) are
  # often set AFTER the constructor returns — by the annotator, by
  # post-construction setters, by `dup`+mutate idioms in the
  # capability-helper code. Caching at construction time stales the
  # answer for any Type whose capabilities are filled in later (e.g.
  # `String[]@list` parses as raw `:String[]` with `@collection=nil`
  # and only acquires `@collection=:list` after parse_raw_input).
  private

  sig { returns(Symbol) }
  def escape_class
    return :value          if primitive?
    return :value          if id_handle?
    return :refcounted     if any_rc?
    return :sync_wrapped   if any_sync?
    return (rodata? ? :slice_rodata : :slice_managed) if string?
    return :slice_managed  if collection?
    return :value          if non_string_array?
    :by_ref
  end

  public

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def ownership=(value)
    apply_capabilities!(ownership: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def ownership
    @capabilities.ownership
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def sync=(value)
    apply_capabilities!(sync: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def sync
    @capabilities.sync
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def layout=(value)
    apply_capabilities!(layout: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def layout
    @capabilities.layout
  end

  sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def lock_rank=(value)
    apply_capabilities!(lock_rank: Type.capability_integer(value))
    value
  end

  sig { returns(T.nilable(Integer)) }
  def lock_rank
    @capabilities.lock_rank
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def collection=(value)
    apply_capabilities!(collection: Type.capability_symbol(value))
    pin_heap_for_collection! if pool?
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def collection
    @capabilities.collection
  end

  sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def shard_count=(value)
    apply_capabilities!(shard_count: Type.capability_integer(value))
    value
  end

  sig { returns(T.nilable(Integer)) }
  def shard_count
    @capabilities.shard_count
  end

  sig { params(value: T::Boolean).returns(T::Boolean) }
  def soa=(value)
    apply_capabilities!(soa: value)
    value
  end

  sig { returns(T::Boolean) }
  def soa
    @capabilities.soa
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def elem_ownership=(value)
    apply_capabilities!(elem_ownership: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def elem_ownership
    capabilities = TypeExpressionTree.linear_item_capabilities(@shape.expression)
    return @capabilities.elem_ownership if capabilities.nil?

    value = capabilities.ownership
    return nil if value == :affine && !capabilities.ownership_set

    value
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def elem_sync=(value)
    apply_capabilities!(elem_sync: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def elem_sync
    capabilities = TypeExpressionTree.linear_item_capabilities(@shape.expression)
    return @capabilities.elem_sync if capabilities.nil?

    capabilities.sync
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def elem_layout=(value)
    apply_capabilities!(elem_layout: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def elem_layout
    capabilities = TypeExpressionTree.linear_item_capabilities(@shape.expression)
    return @capabilities.elem_layout if capabilities.nil?

    capabilities.layout
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def link_source=(value)
    apply_capabilities!(link_source: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def link_source
    @capabilities.link_source
  end

  sig { params(value: T::Boolean).returns(T::Boolean) }
  def is_observable=(value)
    apply_capabilities!(observable: value)
    value
  end

  private

  sig { returns(T::Boolean) }
  def is_observable
    @capabilities.observable
  end

  public

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def observable_terminal=(value)
    apply_capabilities!(observable_terminal: Type.capability_symbol(value))
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def observable_terminal
    @capabilities.observable_terminal
  end

  sig { params(value: T.nilable(Lexer::Token)).returns(T.nilable(Lexer::Token)) }
  def observable_token=(value)
    apply_capabilities!(observable_token: Type.capability_token(value))
    value
  end

  sig { returns(T.nilable(Lexer::Token)) }
  def observable_token
    @capabilities.observable_token
  end

  sig { params(value: T::Boolean).returns(T::Boolean) }
  def polymorphic_shared=(value)
    apply_capabilities!(polymorphic_shared: value)
    value
  end

  sig { returns(T::Boolean) }
  def polymorphic_shared
    @capabilities.polymorphic_shared
  end

  sig do
    params(
      ownership: TypeCapabilities::MaybeSymbol,
      sync: TypeCapabilities::MaybeSymbol,
      layout: TypeCapabilities::MaybeSymbol,
      lock_rank: TypeCapabilities::MaybeInteger,
      collection: TypeCapabilities::MaybeSymbol,
      shard_count: TypeCapabilities::MaybeInteger,
      soa: TypeCapabilities::MaybeBoolean,
      elem_ownership: TypeCapabilities::MaybeSymbol,
      elem_sync: TypeCapabilities::MaybeSymbol,
      elem_layout: TypeCapabilities::MaybeSymbol,
      link_source: TypeCapabilities::MaybeSymbol,
      observable: TypeCapabilities::MaybeBoolean,
      observable_terminal: TypeCapabilities::MaybeSymbol,
      observable_token: TypeCapabilities::MaybeToken,
      polymorphic_shared: TypeCapabilities::MaybeBoolean
    ).returns(TypeCapabilities)
  end
  def apply_capabilities!(
    ownership: TypeCapabilities::UNSET,
    sync: TypeCapabilities::UNSET,
    layout: TypeCapabilities::UNSET,
    lock_rank: TypeCapabilities::UNSET,
    collection: TypeCapabilities::UNSET,
    shard_count: TypeCapabilities::UNSET,
    soa: TypeCapabilities::UNSET,
    elem_ownership: TypeCapabilities::UNSET,
    elem_sync: TypeCapabilities::UNSET,
    elem_layout: TypeCapabilities::UNSET,
    link_source: TypeCapabilities::UNSET,
    observable: TypeCapabilities::UNSET,
    observable_terminal: TypeCapabilities::UNSET,
    observable_token: TypeCapabilities::UNSET,
    polymorphic_shared: TypeCapabilities::UNSET
  )
    item_capabilities = TypeExpressionTree.linear_item_capabilities(@shape.expression)
    update_item = T.let(false, T::Boolean)
    legacy_elem_ownership = @capabilities.elem_ownership
    legacy_elem_sync = @capabilities.elem_sync
    legacy_elem_layout = @capabilities.elem_layout
    if item_capabilities
      update_item = @capabilities.element_update_requested?(
        ownership: elem_ownership,
        sync: elem_sync,
        layout: elem_layout
      )
      if update_item
        next_item_capabilities = item_capabilities.with(
          ownership: Type.prefer_legacy_element_capability(elem_ownership, legacy_elem_ownership),
          sync: Type.prefer_legacy_element_capability(elem_sync, legacy_elem_sync),
          layout: Type.prefer_legacy_element_capability(elem_layout, legacy_elem_layout)
        )
        @shape = @shape.with_expression(
          TypeExpressionTree.with_linear_item_capabilities(@shape.expression, next_item_capabilities)
        )
      end
    end

    @capabilities = @capabilities.with(
      ownership: ownership,
      sync: sync,
      layout: layout,
      lock_rank: lock_rank,
      collection: collection,
      shard_count: shard_count,
      soa: soa,
      elem_ownership: Type.root_element_capability(update_item, elem_ownership),
      elem_sync: Type.root_element_capability(update_item, elem_sync),
      elem_layout: Type.root_element_capability(update_item, elem_layout),
      link_source: link_source,
      observable: observable,
      observable_terminal: observable_terminal,
      observable_token: observable_token,
      polymorphic_shared: polymorphic_shared
    )
    @shape = @shape.with_expression(
      TypeExpressionTree.with_root_capabilities(@shape.expression, @capabilities)
    )
    @capabilities
  end

  sig { void }
  def clear_zig_type_cache!
    nil
  end

  sig { params(provenance: TypePlacement::MaybeSymbol).returns(TypePlacement) }
  def apply_placement!(provenance: TypePlacement::UNSET)
    @placement = @placement.with(provenance: provenance)
  end

  sig { returns(T.nilable(Symbol)) }
  def provenance
    @placement.provenance
  end

  private

  sig { params(location: T.nilable(Symbol)).returns(TypePlacement) }
  def apply_declared_location!(location)
    return placement if location.nil? || location == :stack

    apply_placement!(provenance: Type.placement_symbol(location))
  end

  public

  sig { returns(TypePlacement) }
  def mark_stack_value!
    apply_placement!(provenance: nil)
  end

  sig { returns(TypePlacement) }
  def mark_heap_allocated!
    apply_placement!(provenance: :heap)
  end

  sig { returns(TypePlacement) }
  def mark_frame_allocated!
    apply_placement!(provenance: :frame)
  end

  private

  sig { returns(TypePlacement) }
  def mark_rodata!
    apply_placement!(provenance: :rodata)
  end

  public

  sig { returns(TypePlacement) }
  def mark_borrowed_reference!
    apply_placement!(provenance: :borrow)
  end

  private

  sig { returns(TypePlacement) }
  def pin_heap_for_sync_wrapper!
    mark_heap_allocated!
  end

  public

  sig { returns(TypePlacement) }
  def pin_heap_for_indirect!
    mark_heap_allocated!
  end

  private

  sig { returns(TypePlacement) }
  def pin_heap_for_collection!
    mark_heap_allocated!
  end

  public

  sig { returns(TypePlacement) }
  def reset_to_bare_data_placement!
    mark_stack_value!
  end

  sig { params(source: Type, preserve_existing: T::Boolean).returns(TypePlacement) }
  def copy_placement_from!(source, preserve_existing: true)
    return placement if preserve_existing && !provenance.nil?

    apply_placement!(provenance: Type.placement_symbol_or_unset(source.provenance))
  end

  sig { params(value_type: T.nilable(Type), alloc: T.nilable(Symbol)).returns(TypePlacement) }
  def apply_cleanup_placement!(value_type:, alloc:)
    return placement if !provenance.nil?

    if value_type
      if !value_type.provenance.nil?
        copy_placement_from!(value_type, preserve_existing: false)
      elsif !alloc.nil?
        apply_placement!(provenance: Type.placement_symbol(alloc))
      else
        placement
      end
    elsif !alloc.nil?
      apply_placement!(provenance: Type.placement_symbol(alloc))
    else
      placement
    end
  end

  sig { void }
  def mark_generic_payload_type_arg!
    @generic_payload_type_arg = true
  end

  sig { returns(T::Boolean) }
  def generic_payload_type_arg?
    @generic_payload_type_arg
  end

  sig { params(ownership: T.nilable(Symbol), link_source: T.nilable(Symbol)).returns(TypeCapabilities) }
  def apply_reference_ownership!(ownership, link_source: nil)
    apply_capabilities!(
      ownership: Type.capability_symbol_or_unset(ownership),
      link_source: Type.capability_symbol_or_unset(link_source)
    )
  end

  sig { params(terminal: Symbol).returns(TypeCapabilities) }
  def stamp_observable_terminal!(terminal)
    apply_capabilities!(observable_terminal: Type.capability_symbol(terminal))
  end

  sig { params(value: T::Boolean).returns(TypeCapabilities) }
  def mark_polymorphic_shared!(value = true)
    apply_capabilities!(polymorphic_shared: value)
  end

  sig { returns(TypeCapabilities) }
  def mark_soa_layout!
    apply_capabilities!(soa: true)
  end

  sig { params(collection: T.nilable(Symbol), soa: T::Boolean, shard_count: T.nilable(Integer)).returns(TypeCapabilities) }
  def apply_constructor_collection!(collection:, soa:, shard_count:)
    apply_capabilities!(
      collection: Type.capability_symbol_or_unset(collection),
      soa: Type.capability_boolean_or_unset(soa),
      shard_count: Type.capability_integer_or_unset(shard_count)
    )
  end

  sig { params(soa: T::Boolean, elem_ownership: T.nilable(Symbol), elem_sync: T.nilable(Symbol), elem_layout: T.nilable(Symbol), observable_token: T.nilable(Lexer::Token)).returns(TypeCapabilities) }
  def apply_type_annotation_extras!(soa:, elem_ownership:, elem_sync:, elem_layout:, observable_token:)
    apply_capabilities!(
      soa: Type.capability_boolean_or_unset(soa),
      elem_ownership: Type.capability_symbol_or_unset(elem_ownership),
      elem_sync: Type.capability_symbol_or_unset(elem_sync),
      elem_layout: Type.capability_symbol_or_unset(elem_layout),
      observable_token: Type.capability_token_or_unset(observable_token)
    )
  end

  sig { params(ownership: T.nilable(Symbol), sync: T.nilable(Symbol), lock_rank: T.nilable(Integer), layout: T.nilable(Symbol)).returns(TypeCapabilities) }
  def apply_declared_type_capabilities!(ownership:, sync:, lock_rank:, layout:)
    apply_capabilities!(
      ownership: Type.capability_symbol_or_unset(ownership),
      sync: Type.capability_symbol_or_unset(sync),
      lock_rank: Type.capability_integer_or_unset(lock_rank),
      layout: Type.capability_symbol_or_unset(layout)
    )
  end

  sig { returns(TypeCapabilities) }
  def strip_layout!
    apply_capabilities!(layout: nil)
  end

  sig { params(storage: Symbol, value_sync: T.nilable(Symbol), link_source: T.nilable(Symbol)).returns(TypeCapabilities) }
  def apply_storage_capability!(storage, value_sync: nil, link_source: nil)
    if storage == :frozen
      return apply_reference_ownership!(:frozen)
    end
    if storage == :multiowned
      return apply_reference_ownership!(:multiowned)
    end
    if storage == :shared
      return apply_reference_ownership!(:shared)
    end
    if storage == :link
      return apply_reference_ownership!(:link, link_source: link_source)
    end
    if storage == :rodata
      mark_rodata!
      return capabilities.copy
    end
    if storage == :frame
      mark_frame_allocated!
      return capabilities.copy
    end
    if storage == :heap
      mark_heap_allocated!
      if value_sync == :locked || value_sync == :write_locked
        return apply_capabilities!(sync: Type.capability_symbol(value_sync))
      end
      return capabilities.copy
    end
    if storage == :borrow
      mark_borrowed_reference!
      return capabilities.copy
    end
    capabilities.copy
  end

  sig { params(storage: Symbol, entry_sync: T.nilable(Symbol), entry_layout: T.nilable(Symbol), value_sync: T.nilable(Symbol), link_source: T.nilable(Symbol), atomic_ptr: T::Boolean).returns(TypeCapabilities) }
  def apply_symbol_overlay!(storage:, entry_sync:, entry_layout:, value_sync:, link_source:, atomic_ptr:)
    apply_storage_capability!(storage, value_sync: value_sync, link_source: link_source)
    apply_capabilities!(
      ownership: Type.capability_symbol_or_unset(atomic_ptr && ownership == :affine ? :shared : nil),
      sync: Type.capability_symbol_or_unset(!entry_sync.nil? && sync.nil? ? entry_sync : nil),
      layout: Type.capability_symbol_or_unset(!entry_layout.nil? && layout.nil? ? entry_layout : nil)
    )
  end

  sig { params(storage: Symbol, sync: T.nilable(Symbol)).returns(TypeCapabilities) }
  def apply_bg_capture_symbol!(storage:, sync:)
    current_sync = @capabilities.sync
    apply_capabilities!(
      ownership: Type.capability_symbol_or_unset((storage == :multiowned || storage == :shared) && (ownership.nil? || ownership == :affine) ? storage : nil),
      sync: Type.capability_symbol_or_unset(!sync.nil? && current_sync.nil? ? sync : nil)
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_collection_shape_from!(source)
    source_collection = source.collection
    source_shard_count = source.shard_count
    # Symbol-only reconstruction cannot represent Inline Pivot markers such
    # as [Set] (its legacy projection is Int64[SET]). Recover the recursive
    # node from the authoritative source before merging binding capabilities.
    @shape = source.shape.copy if element_type.nil? && !source.element_type.nil?
    apply_capabilities!(
      collection: Type.capability_symbol_or_unset(collection.nil? && !source_collection.nil? ? source_collection : nil),
      shard_count: Type.capability_integer_or_unset(shard_count.nil? && !source_shard_count.nil? ? source_shard_count : nil),
      soa: Type.capability_boolean_or_unset(source.soa? && !soa?)
    )
  end

  sig { params(shape: TypeShape).returns(TypeShape) }
  def replace_shape!(shape)
    @shape = shape.copy
    @shape
  end

  sig { params(capabilities: TypeCapabilities).returns(TypeCapabilities) }
  def replace_capabilities!(capabilities)
    @capabilities = capabilities.copy
    @shape = @shape.with_expression(
      TypeExpressionTree.with_root_capabilities(@shape.expression, @capabilities)
    )
    @capabilities
  end

  sig { params(placement: TypePlacement).returns(TypePlacement) }
  def replace_placement!(placement)
    @placement = placement.copy
    @placement
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_topology_from!(source)
    source_shard_count = source.shard_count
    apply_capabilities!(
      shard_count: Type.capability_integer_or_unset(shard_count.nil? && !source_shard_count.nil? ? source_shard_count : nil),
      soa: Type.capability_boolean_or_unset(source.soa? && !soa?)
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_declared_collection_modifiers_from!(source)
    source_ownership = source.ownership
    source_sync = source.sync
    source_shard_count = source.shard_count
    apply_capabilities!(
      ownership: Type.capability_symbol_or_unset(!source_ownership.nil? && source_ownership != :affine ? source_ownership : nil),
      sync: Type.capability_symbol_or_unset(!source_sync.nil? && sync.nil? ? source_sync : nil),
      shard_count: Type.capability_integer_or_unset(!source_shard_count.nil? && shard_count.nil? ? source_shard_count : nil)
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_element_capabilities_from!(source)
    apply_capabilities!(
      elem_ownership: Type.capability_symbol_or_unset(source.elem_ownership),
      elem_sync: Type.capability_symbol_or_unset(source.elem_sync),
      elem_layout: Type.capability_symbol_or_unset(source.elem_layout)
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_striped_map_topology_from!(source)
    source_shard_count = source.shard_count
    source_sync = source.sync
    apply_capabilities!(
      shard_count: Type.capability_integer_or_unset(source_shard_count),
      sync: Type.capability_symbol_or_unset(!source_shard_count.nil? && !source_sync.nil? ? source_sync : nil),
      ownership: Type.capability_symbol(:affine)
    )
  end

  sig { params(final_type: Type, value_type: T.nilable(Type)).returns(TypeCapabilities) }
  def apply_finalized_value_shape!(final_type:, value_type:)
    value_shard_count = T.let(nil, T.nilable(Integer))
    value_soa = T.let(false, T::Boolean)
    value_observable = T.let(false, T::Boolean)
    value_observable_terminal = T.let(nil, T.nilable(Symbol))
    value_elem_ownership = T.let(nil, T.nilable(Symbol))
    value_elem_sync = T.let(nil, T.nilable(Symbol))
    value_elem_layout = T.let(nil, T.nilable(Symbol))
    value_collection = T.let(nil, T.nilable(Symbol))
    link_src = T.let(nil, T.nilable(Symbol))
    if value_type
      value_shard_count = value_type.shard_count
      value_soa = value_type.soa
      value_observable = value_type.observable?
      value_observable_terminal = value_type.observable_terminal
      value_elem_ownership = value_type.elem_ownership
      value_elem_sync = value_type.elem_sync
      value_elem_layout = value_type.elem_layout
      value_collection = value_type.collection unless final_type.rank?
      link_src = value_type.link_source if value_type.link?
    end

    declared_shard_count = final_type.shard_count
    final_shard_count = if !declared_shard_count.nil?
      declared_shard_count
    else
      value_shard_count
    end
    final_soa = final_type.soa || value_soa
    observable = final_type.observable? || value_observable
    final_observable_terminal = final_type.observable_terminal
    observable_terminal = if !final_observable_terminal.nil?
      final_observable_terminal
    elsif !value_observable_terminal.nil?
      value_observable_terminal
    end
    declared_elem_ownership = final_type.elem_ownership
    declared_elem_sync = final_type.elem_sync
    declared_elem_layout = final_type.elem_layout
    elem_ownership = if !declared_elem_ownership.nil?
      declared_elem_ownership
    else
      value_elem_ownership
    end
    elem_sync = if !declared_elem_sync.nil?
      declared_elem_sync
    else
      value_elem_sync
    end
    elem_layout = if !declared_elem_layout.nil?
      declared_elem_layout
    else
      value_elem_layout
    end
    # A list literal is merely the storage initializer for a rectangular
    # rank. It must not overwrite the rank's semantic topology with :list.
    apply_capabilities!(
      shard_count: Type.capability_integer_or_unset(final_shard_count),
      sync: Type.capability_symbol_or_unset(final_type.sync),
      soa: Type.capability_boolean_or_unset(final_soa),
      collection: Type.capability_symbol_or_unset(value_collection),
      observable: Type.capability_boolean_or_unset(observable),
      observable_terminal: Type.capability_symbol_or_unset(observable_terminal),
      elem_ownership: Type.capability_symbol_or_unset(elem_ownership),
      elem_sync: Type.capability_symbol_or_unset(elem_sync),
      elem_layout: Type.capability_symbol_or_unset(elem_layout),
      layout: Type.capability_symbol_or_unset(final_type.layout),
      link_source: Type.capability_symbol_or_unset(link_src)
    )
  end

  sig { params(source: Type, preserve_existing: T::Boolean, include_affine_ownership: T::Boolean).returns(TypeCapabilities) }
  def merge_capabilities_from!(source, preserve_existing: true, include_affine_ownership: false)
    source_ownership = source.ownership
    source_collection = source.collection
    source_shard_count = source.shard_count
    source_layout = source.layout
    source_sync = source.sync
    source_elem_ownership = source.elem_ownership
    source_elem_sync = source.elem_sync
    source_elem_layout = source.elem_layout
    source_link_source = source.link_source
    source_observable_terminal = source.observable_terminal
    source_observable_token = source.observable_token
    should_copy_ownership = !source_ownership.nil? &&
                            !(preserve_existing && !ownership.nil? && ownership != :affine) &&
                            (include_affine_ownership || source_ownership != :affine)
    apply_capabilities!(
      ownership: Type.capability_symbol_or_unset(should_copy_ownership ? source_ownership : nil),
      sync: Type.capability_symbol_or_unset((!preserve_existing || sync.nil?) && !source_sync.nil? ? source_sync : nil),
      layout: Type.capability_symbol_or_unset((!preserve_existing || layout.nil?) && !source_layout.nil? ? source_layout : nil),
      collection: Type.capability_symbol_or_unset((!preserve_existing || collection.nil?) && !source_collection.nil? ? source_collection : nil),
      shard_count: Type.capability_integer_or_unset((!preserve_existing || shard_count.nil?) && !source_shard_count.nil? ? source_shard_count : nil),
      soa: Type.capability_boolean_or_unset(source.soa? && (!preserve_existing || !soa?)),
      elem_ownership: Type.capability_symbol_or_unset((!preserve_existing || elem_ownership.nil?) && !source_elem_ownership.nil? ? source_elem_ownership : nil),
      elem_sync: Type.capability_symbol_or_unset((!preserve_existing || elem_sync.nil?) && !source_elem_sync.nil? ? source_elem_sync : nil),
      elem_layout: Type.capability_symbol_or_unset((!preserve_existing || elem_layout.nil?) && !source_elem_layout.nil? ? source_elem_layout : nil),
      link_source: Type.capability_symbol_or_unset((!preserve_existing || link_source.nil?) && !source_link_source.nil? ? source_link_source : nil),
      observable: Type.capability_boolean_or_unset(source.observable? && (!preserve_existing || !observable?)),
      observable_terminal: Type.capability_symbol_or_unset((!preserve_existing || observable_terminal.nil?) && !source_observable_terminal.nil? ? source_observable_terminal : nil),
      polymorphic_shared: Type.capability_boolean_or_unset(source.polymorphic_shared? && (!preserve_existing || !polymorphic_shared?))
    )
    if (!preserve_existing || observable_token.nil?) && !source_observable_token.nil?
      return apply_capabilities!(observable_token: Type.capability_token_or_unset(source_observable_token))
    end
    capabilities.copy
  end

  sig { returns(TypeCapabilities) }
  def strip_runtime_capabilities!
    @capabilities = @capabilities.without_runtime_wrappers
    @shape = @shape.with_expression(
      TypeExpressionTree.with_root_capabilities(@shape.expression, @capabilities)
    )
    @capabilities
  end

  # -----------------------------------------------
  # COMPATIBILITY LAYER (The "Don't Break Tests" part)
  # -----------------------------------------------

  # Allow code to compare this object directly to symbols/strings
  # e.g. if node.type == :Float64
  sig { params(other: TypeInput).returns(T::Boolean) }
  def ==(other)
    # fn_types must never compare equal to a plain symbol (resolved returns the return type,
    # not a unique identity). Two fn_types are equal only when their raw hashes match.
    if fn_type?
      return false unless other.is_a?(Type)
      return false unless other.fn_type?
      return semantic_type_key == other.semantic_type_key
    end
    other_type = Type.from_input(other)
    resolved == other_type.to_sym || semantic_type_key == other_type.semantic_type_key
  end

  sig { returns(TypeShape::Raw) }
  def raw
    shape.raw
  end

  sig { returns(NilClass) }
  def name
    nil
  end

  sig { returns(ArrayCapacity) }
  def capacity
    shape.capacity
  end

  # Minimum allocation requested by an Inline Pivot collection layer, such as
  # `[List(32)]T` or `[Set(32)]T`. Unlike `capacity`, this is not part of the
  # collection's value shape and must not affect assignability or ABI identity.
  sig { returns(T.nilable(Integer)) }
  def allocation_hint
    shape.allocation_hint
  end

  sig { returns(T::Boolean) }
  def preallocation_hint?
    TypeExpressionTree.each_node(shape.expression).any? { |node| Type.preallocation_expression?(node) }
  end

  sig { returns(String) }
  def to_s; resolved.to_s; end

  sig { returns(Symbol) }
  # ruby-to-clear: effects reentrant
  def to_sym
    resolved
  end

  # Backward API: Deprecate
  sig { returns(Symbol) }
  # ruby-to-clear: effects reentrant
  def resolved
    fn = function_type
    return Type.function_return_symbol(fn) unless fn.nil?

    shape.resolved
  end

  private

  sig { returns(TypeId) }
  def type_id
    TypeId.new(key: semantic_type_key)
  end

  public

  sig { returns(String) }
  # ruby-to-clear: effects reentrant
  def semantic_type_key
    ownership_key = ownership.nil? ? "affine" : T.must(ownership).to_s
    sync_key = sync.nil? ? "none" : T.must(sync).to_s
    layout_key = layout.nil? ? "direct" : T.must(layout).to_s
    provenance_key = provenance.nil? ? "stack" : T.must(provenance).to_s
    collection_key = collection.nil? ? "none" : T.must(collection).to_s
    shards_key = shard_count.nil? ? "0" : Type.integer_string(T.must(shard_count))
    elem_layout_key = elem_layout.nil? ? "direct" : T.must(elem_layout).to_s
    [
      semantic_shape_key,
      "own=#{ownership_key}",
      "sync=#{sync_key}",
      "layout=#{layout_key}",
      "loc=#{provenance_key}",
      "collection=#{collection_key}",
      "shards=#{shards_key}",
      "elem_layout=#{elem_layout_key}",
    ].join("|")
  end

  # Copy/drop identity is independent of where one binding happens to live.
  # Borrowed and rodata values remain distinct because they do not own their
  # backing representation; stack/frame/heap are all the same owning type.
  sig { returns(String) }
  def lifecycle_type_key
    location = case provenance
    when :borrow then "borrow"
    when :rodata then "rodata"
    else "owned"
    end
    semantic_type_key.sub(/\|loc=[^|]+/, "|loc=#{location}")
  end

  # Backward API: Deprecate
  sig { returns(Symbol) }
  def base_type
    element_raw = shape.element_type_raw
    return Type.symbol_or_any(element_raw) if array?

    resolved
  end

  sig { returns(T::Boolean) }
  def generic_type_parameter?
    raw_text = resolved.to_s
    raw_text.length == 1 && raw_text >= "A" && raw_text <= "Z"
  end

  sig { returns(T::Boolean) }
  def primitive?
    Type.primitive_symbol?(resolved)
  end

  # ----------------------------------------------
  # Coercion helpers
  # ----------------------------------------------
  sig { params(other_type: Type).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def accepts?(other_type)
    # 0. Function type: must precede == shortcut (resolved strips fn signature to return type)
    return accepts_fn_type?(other_type) if fn_type?

    # 1. Any
    return true if any? || other_type.any?

    # Once a destination declares T@node, assigning a plain T value inserts
    # it into the compiler-inferred NodeStore. Existing handles pass through.
    if node_reference?
      payload = node_payload_type
      other_payload = other_type.node_payload_type
      return true if payload && other_payload && payload.resolved == other_payload.resolved
      return true if payload && payload.resolved == other_type.resolved
    end

    # 2. String@symbol is a canonicalized string capability. A plain String
    # cannot satisfy it without a future runtime intern(rt, s) operation.
    return other_type.string? && other_type.symbol? if string? && symbol?

    # String@c is a NUL-terminated foreign view. String literals live in
    # rodata with a sentinel and cross without allocation; an arbitrary
    # runtime String needs the explicit checked conversion added by the FFI
    # boundary pass and must not be accepted as a slice header.
    if c_string?
      return false unless other_type.string?
      return true if other_type.c_string?
      return other_type.rodata?
    end

    # 3. Exact match
    return true if self == other_type

    # 4. Optional coercion: ?T accepts T, NIL, or ?T.
    # This must run before string capability checks so ?String@symbol can
    # unwrap and compare its payload type instead of being treated as String.
    if optional?
      return true if other_type.resolved == :NIL
      if other_type.optional?
        return T.must(wrapped_type).accepts?(T.must(other_type.wrapped_type))
      end

      return T.must(wrapped_type).accepts?(other_type)
    end

    # 5. Error union coercion: !T accepts T or !T
    if error_union?
      if other_type.error_union?
        return T.must(payload_type).accepts?(T.must(other_type.payload_type))
      end

      return T.must(payload_type).accepts?(other_type)
    end

    # 6. Primitive widening
    return true if numeric? && other_type.numeric?
    return true if string? && (other_type.byte? || other_type.string?)

    # 7. Tense (Promise/Stream) coercion
    return accepts_future?(other_type) if future?

    # 8. Array coercion
    return accepts_array?(other_type) if array?

    # 8. HashMap coercion: HashMap<Any> (empty literal) accepts any HashMap<T>
    if map? && other_type.map?
      return true if other_type.value_type.any?
      return value_type.accepts?(other_type.value_type)
    end

    # 9. Nominal generic products are covariant only through conversions
    # already admitted by each corresponding type argument. This is what lets
    # a contextually typed Tuple<String, Int64> accept Tuple<Byte[3], Int64>
    # while still rejecting a different generic constructor or capability.
    if generic_instance? && other_type.generic_instance? &&
        generic_base == other_type.generic_base &&
        ownership == other_type.ownership && sync == other_type.sync && layout == other_type.layout
      expected_args = generic_args
      actual_args = other_type.generic_args
      return expected_args.length == actual_args.length &&
        expected_args.each_with_index.all? { |expected, index| expected.accepts?(actual_args.fetch(index)) }
    end

    false
  end

  # Used specifically to check if assigning an array too large to a fixed array
  sig { params(other_type: Type).returns(T.nilable(T::Boolean)) }
  def array_overflow?(other_type)
    return false if !other_type.array? || !self.array?
    return false if self.base_type != other_type.base_type
    return false if !other_type.fixed? || !self.fixed?
    other_capacity = other_type.capacity
    self_capacity = capacity
    return false unless Type.integer_array_capacity?(other_capacity) && Type.integer_array_capacity?(self_capacity)
    return true if Type.array_capacity_integer(other_capacity) > Type.array_capacity_integer(self_capacity)
  end

  # ----------------------------------------------
  # Type Predicates
  # ----------------------------------------------
  SIGNED_INT_TYPES   = [:Int8, :Int16, :Int32, :Int64, :TargetInt, :TargetLong, :TargetLongLong].freeze
  UNSIGNED_INT_TYPES = [:UInt8, :Byte, :UInt16, :UInt32, :UInt64, :TargetUInt, :TargetULong, :TargetULongLong].freeze
  INT_TYPES          = T.let((SIGNED_INT_TYPES + UNSIGNED_INT_TYPES).freeze, T::Array[Symbol])
  FLOAT_TYPES        = [:Float32, :Float64].freeze
  NUMERIC_TYPES      = T.let((INT_TYPES + FLOAT_TYPES).freeze, T::Array[Symbol])
  PRIMITIVE_TYPES    = T.let(([:Number, :Bool] + NUMERIC_TYPES).freeze, T::Array[Symbol])

  INT_TYPE_MAX = T.let({
    Byte: 255, UInt8: 255, UInt16: 65_535, UInt32: 4_294_967_295,
    UInt64: (2**64) - 1,
    Int8: 127, Int16: 32_767, Int32: 2_147_483_647, Int64: 9_223_372_036_854_775_807,
  }.freeze, T::Hash[Symbol, Integer])
  INT_TYPE_MIN = T.let({
    Byte: 0, UInt8: 0, UInt16: 0, UInt32: 0, UInt64: 0,
    Int8: -128, Int16: -32_768, Int32: -2_147_483_648, Int64: -9_223_372_036_854_775_808,
  }.freeze, T::Hash[Symbol, Integer])

  sig { params(type_sym: Symbol).returns(T.nilable(Integer)) }
  def self.integer_type_max(type_sym)
    case type_sym
    when :Byte, :UInt8
      255
    when :UInt16
      65_535
    when :UInt32
      4_294_967_295
    when :UInt64
      9_223_372_036_854_775_807
    when :Int8
      127
    when :Int16
      32_767
    when :Int32
      2_147_483_647
    when :Int64
      9_223_372_036_854_775_807
    end
  end

  sig { params(type_sym: Symbol).returns(T.nilable(Integer)) }
  def self.integer_type_min(type_sym)
    case type_sym
    when :Byte, :UInt8, :UInt16, :UInt32, :UInt64
      0
    when :Int8
      -128
    when :Int16
      -32_768
    when :Int32
      -2_147_483_648
    when :Int64
      -9_223_372_036_854_775_808
    end
  end

  sig { returns(T::Boolean) }
  def numeric?
    Type.numeric_symbol?(resolved)
  end

  sig { returns(T::Boolean) }
  def integer?
    Type.integer_symbol?(resolved)
  end

  sig { returns(T::Boolean) }
  def signed_integer?
    Type.signed_integer_symbol?(resolved)
  end

  sig { returns(T::Boolean) }
  def unsigned_integer?
    Type.unsigned_integer_symbol?(resolved)
  end

  sig { returns(T::Boolean) }
  def float?
    Type.float_symbol?(resolved)
  end

  sig { returns(T::Boolean) }
  def byte?
    resolved == :Byte
  end

  sig { returns(T::Boolean) }
  def void?
    resolved == :Void
  end

  sig { returns(T::Boolean) }
  def catch_snapshot_payload?
    !void? && !error_union?
  end

  # The :Untyped sentinel: a generic evaluatable node whose full_type
  # was never stamped by the annotator. full_type defaults to this
  # instead of nil so the contract is non-nilable; PreMirTypeCheck
  # raises on any :Untyped reaching the AST->MIR boundary (latent bug).
  sig { returns(T::Boolean) }
  def untyped?
    resolved == :Untyped
  end

  # Gradual-typing placeholder. True when this Type is an unresolved
  # `Auto` slot waiting for the inference pass to fill it in.
  sig { returns(T::Boolean) }
  def auto?
    shape.auto
  end

  # Source-position token for the `Auto` keyword, used by fix emission when
  # replacing `Auto` with the resolved concrete type.
  # Nil for implicit-Auto (omitted annotation under `--gradual`),
  # which has no source token to point at.
  sig { returns(T.nilable(Lexer::Token)) }
  attr_reader :auto_token

  sig { params(auto_token: T.nilable(Lexer::Token)).returns(T.nilable(Lexer::Token)) }
  attr_writer :auto_token

  sig { returns(T::Boolean) }
  def fn_type?
    shape.fn_type?
  end

  sig { returns(T.nilable(FunctionType)) }
  def function_type
    raw_value = raw
    raw_value if raw_value.is_a?(FunctionType)
  end

  sig { returns(T::Boolean) }
  def array?
    shape.array
  end

  sig { returns(T::Boolean) }
  def rank?
    expression = shape.expression
    expression = expression.inner if expression.is_a?(FallibleTypeExpression)
    expression = expression.inner if expression.is_a?(OptionalTypeExpression) && expression.inner.is_a?(LinearTypeExpression)
    expression.is_a?(LinearTypeExpression) && expression.dimensions.length > 1
  end

  sig { returns(T::Array[TypeExpression::Dimension]) }
  def rank_dimensions
    return [] unless rank?

    expression = shape.expression
    expression = expression.inner if expression.is_a?(FallibleTypeExpression)
    expression = expression.inner if expression.is_a?(OptionalTypeExpression)
    T.cast(expression, LinearTypeExpression).dimensions
  end

  sig { returns(Integer) }
  def rank
    rank_dimensions.length
  end

  sig { returns(T::Boolean) }
  def dynamic_rank?
    rank? && rank_dimensions.any? { |dimension| dimension == :LIST }
  end

  sig { returns(T::Boolean) }
  def fixed_rank?
    rank? && !dynamic_rank?
  end

  # Compile-time positional validation shared by heterogeneous Tuples and
  # fixed homogeneous arrays. Surface syntax remains distinct: Tuple uses
  # `._N`; arrays use `[N]`.
  sig { returns(T.nilable(Integer)) }
  def fixed_position_count
    return generic_args.length if tuple?
    return T.cast(capacity, T.nilable(Integer)) if fixed? && !dynamic?

    nil
  end

  sig { params(index: Integer).returns(T.nilable(Type)) }
  def fixed_position_type(index)
    if tuple?
      args = generic_args
      return nil if index.negative? || index >= args.length

      return args[index]
    end

    count = fixed_position_count
    return nil if count.nil? || index.negative? || index >= count

    element_type
  end

  sig { returns(T::Boolean) }
  def string?
    resolved == :String || (array? && base_type == :Byte)
  end

  sig { returns(T::Boolean) }
  def any?
    resolved == :Any
  end

  sig { returns(T::Boolean) }
  def dynamic?
    # It is dynamic if it is an array, but has NO fixed capacity
    array? && capacity.nil?
  end

  sig { returns(T::Boolean) }
  def fixed?
    # It is fixed if it is an array AND has a specific integer capacity (not [?] or [INF])
    array? && Type.integer_array_capacity?(capacity)
  end

  # True when this is the legacy [?] marker (open stream element-type annotation).
  # Only meaningful as the tense_type of an open stream: ~T[?].
  sig { returns(T::Boolean) }
  def open_stream_marker?
    return false unless array?

    cap = Type.array_capacity_symbol(capacity)
    return false if cap.nil?

    cap == :STREAM_OPEN
  end

  # True when this is the [INF] marker (infinite stream element-type annotation).
  # Only meaningful as the tense_type of an infinite stream: ~T[INF].
  sig { returns(T::Boolean) }
  def inf_stream_marker?
    return false unless array?

    cap = Type.array_capacity_symbol(capacity)
    return false if cap.nil?

    cap == :INF
  end

  sig { returns(T::Boolean) }
  def empty_list?
    # Handles the empty list literal "Any[]" or heap "%Any[]"
    # This is crucial for initializing typed arrays (e.g., `var x: Number[] = []`)
    resolved == :"Any[]"
  end

  sig { returns(T::Boolean) }
  def heap?
    placement.heap?
  end

  sig { returns(T::Boolean) }
  def frame?
    placement.frame?
  end

  sig { returns(T::Boolean) }
  def rodata?
    placement.rodata?
  end

  sig { returns(T::Boolean) }
  def borrowed_reference?
    provenance == :borrow
  end

  # Returns the allocator symbol for this provenance (:heap or :frame), or nil.
  sig { returns(T.nilable(Symbol)) }
  def provenance_alloc
    placement.alloc
  end

  # location is provenance (kept as alias for backward-compat callers).
  sig { returns(T.nilable(Symbol)) }
  def location
    placement.location
  end

  sig { returns(T::Boolean) }
  def multiowned?
    ownership == :multiowned
  end

  sig { returns(T::Boolean) }
  def shared?
    ownership == :shared
  end

  sig { returns(T::Boolean) }
  def shared_node?
    ownership == :shared_node
  end

  sig { returns(T::Boolean) }
  def node?
    ownership == :node || shared_node?
  end

  sig { returns(T::Boolean) }
  def node_reference?
    return true if node?
    optional? && !!wrapped_type&.node?
  end

  sig { returns(T.nilable(Type)) }
  def node_payload_type
    return T.must(wrapped_type).node_payload_type if optional? && wrapped_type&.node?
    return self if node?

    nil
  end

  sig { returns(T::Boolean) }
  def polymorphic_shared?
    polymorphic_shared
  end

  sig { returns(T::Boolean) }
  def frozen?
    ownership == :frozen
  end

  sig { returns(T::Boolean) }
  def split?
    ownership == :split
  end

  sig { returns(T::Boolean) }
  def link?
    ownership == :link
  end

  sig { returns(T::Boolean) }
  def locked?
    sync == :locked
  end

  sig { returns(T::Boolean) }
  def write_locked?
    sync == :write_locked
  end

  # MVCC: T@versioned -> Shared(T) (atomic-pointer COW + EBR).
  # Readers see consistent snapshots via `WITH SNAPSHOT x AS y`;
  # writers do optimistic update via `WITH SNAPSHOT x AS MUTABLE y`
  # with `ON MvccConflict ...` for the retries-exhausted case.
  sig { returns(T::Boolean) }
  def versioned?
    sync == :versioned
  end

  # Atomic single-cell: T@atomic -> Atomic(T) (lock-free CPU-atomic
  # load/store/CAS/fetch_*). v0.2 surface limited to Int64, Float64,
  # Bool primitives. Composes with @shared (Arc<Atomic(T)>) in M1;
  # M2 will drop the Arc and tie the lifetime to declaring scope.
  sig { returns(T::Boolean) }
  def indirect?
    layout == :indirect
  end

  sig { returns(T::Boolean) }
  def atomic?
    sync == :atomic
  end

  # AtomicPtr cell: @boxed:atomic. The `sync == :atomic && layout ==
  # :indirect` pair was reinvented inline ~8x (decomplex Missing-Abstraction).
  sig { returns(T::Boolean) }
  def atomic_ptr?
    atomic? && indirect?
  end

  sig { returns(T::Boolean) }
  def local?
    sync == :local
  end

  sig { returns(T::Boolean) }
  def raw?
    sync == :raw
  end

  sig { returns(T::Boolean) }
  def symbol?
    sync == :symbol
  end

  sig { returns(T::Boolean) }
  def c_string?
    string? && sync == :c
  end

  sig { returns(T::Boolean) }
  def c_array_view?
    array? && !string? && sync == :c
  end

  sig { returns(T::Boolean) }
  def target_size?
    sync == :size
  end

  # True for synchronization capabilities. Raw/symbol/C-string/target-size
  # are representation or data-access modes, not locks.
  sig { returns(T::Boolean) }
  def any_sync?
    !sync.nil? && !%i[raw symbol c size].include?(sync)
  end

  # Group 1 vs Group 2 separation: return a copy of this type with the
  # synchronization/ownership wrappers stripped, preserving only the data
  # shape (collection kind, element type, capacity, shard count, soa flag,
  # etc.).
  #
  # Used by mir_lowering when constructing collection inits — `ContainerInit`
  # needs the BARE shape (`Pool([50000]Env)`), and the Locked/Arc layers are
  # composed AROUND it via a separate wrapping pass. Without this split, the
  # lowering bakes the sync/ownership wrappers into the `initCapacity`
  # receiver type and emits `Arc(Locked(Pool)).initCapacity(...)`, which
  # fails because `initCapacity` lives on the inner `Pool`.
  sig { returns(Type) }
  def bare_data_type
    bare = Type.copy_type(self)
    bare.strip_runtime_capabilities!
    # Provenance was set by sync/ownership wrappers (Type#initialize
    # forces :heap when @sync is set). Stripping the wrappers means the
    # bare shape's provenance must come from its OWN nature (e.g.
    # HashMap is always heap; a plain struct has no forced provenance).
    # Reset; the outer wrap layer that consumes this bare form is
    # responsible for re-pinning.
    bare.reset_to_bare_data_placement!
    bare.clear_zig_type_cache!
    bare
  end

  sig { returns(T::Boolean) }
  def any_rc?
    # SharedPromise uses its own ref-counting internally — it is NOT an Rc/Arc wrapper.
    return false if shared_promise? || split_open_stream?
    multiowned? || shared?
  end

  private

  sig { returns(T::Boolean) }
  def shared_or_multiowned?
    shared? || multiowned?
  end

  public

  sig { returns(T::Boolean) }
  def rc_map?
    map? && shared_or_multiowned?
  end

  sig { returns(T::Boolean) }
  def sync_requires_heap_provenance?
    any_sync? && ownership == :affine
  end

  sig { returns(T::Boolean) }
  def atomic_pointer_wrapped?
    atomic? && (shared_or_multiowned? || indirect?)
  end

  sig { returns(T::Boolean) }
  def map?
    shape.map
  end

  # True when this is a numeric-keyed map (HashMap<Number,V> or HashMap<Int64,V>).
  # Backed by AutoHashMapUnmanaged — no key duplication, pure arena-allocated.
  sig { returns(T::Boolean) }
  def numeric_map?
    map? && key_type.numeric?
  end

  sig { returns(T::Boolean) }
  def plain_numeric_map?
    numeric_map? && !sharded? && !striped?
  end

  sig { returns(Type) }
  def key_type
    expression = shape.expression
    expression = expression.inner if expression.is_a?(FallibleTypeExpression)
    expression = expression.inner if expression.is_a?(OptionalTypeExpression)
    return Type.from_child_expression(expression.key) if expression.is_a?(MapTypeExpression)

    Type.new(:String)
  end

  # True when this is an explicit @pool (generational pool) collection.
  sig { returns(T::Boolean) }
  def pool?
    collection == :pool
  end

  # True when this is an explicit @list (heap list) collection.
  sig { returns(T::Boolean) }
  def list_collection?
    collection == :list
  end

  # True when this is an explicit @set (hash set) collection.
  sig { returns(T::Boolean) }
  def set_collection?
    collection == :set
  end

  # --- Unified collection predicates ---
  # Use these instead of individual map?/pool?/list_collection?/set_collection? checks
  # to ensure new collection types get consistent treatment automatically.

  # True for any collection type (HashMap, @pool, @list, @set).
  sig { returns(T::Boolean) }
  def collection?
    map? || pool? || list_collection? || set_collection?
  end

  # True for collection-shaped values that may need collection copy/cleanup
  # handling at ownership boundaries. `collection?` is declaration-level
  # collections (HashMap/@pool/@list/@set); plain non-string arrays/slices are
  # value-shaped but need the same boundary treatment.
  sig { returns(T::Boolean) }
  def collection_value?
    collection? || non_string_array?
  end

  # True when values of this type carry pointer-backed data that must not
  # outlive its allocator region.
  sig { returns(T::Boolean) }
  def heap_ptr?
    return T.must(wrapped_type).heap_ptr? if optional?

    string? || indirect? || tense_observable? || collection? || (array? && !fixed?)
  end

  sig { returns(T::Boolean) }
  def associative_collection?
    map?
  end

  sig { returns(T::Boolean) }
  def linear_collection?
    pool? || list_collection? || set_collection? || non_string_array?
  end

  sig { returns(T.nilable(Symbol)) }
  def ownership_storage
    return ownership if shared? || multiowned?
    nil
  end

  sig { returns(T::Boolean) }
  def direct_indexable_collection?
    list_collection? || (array? && !string? && !collection?)
  end

  sig { returns(T::Boolean) }
  def non_string_array?
    array? && !string?
  end

  sig { returns(T::Boolean) }
  def indexed_container_borrow?
    map? || pool? || direct_indexable_collection?
  end

  sig { returns(String) }
  def element_zig_type_or_anyopaque
    elem = element_type
    return "anyopaque" if elem.nil?

    elem.zig_type
  end

  sig { returns(String) }
  def key_zig_type
    current_key_type = key_type
    current_key_type.zig_type
  end

  # Iteration shape for the FSM ForEach lowering. The recursive
  # splitter dispatches on the kind to build a per-iteration
  # segment graph. Returns nil for collection shapes the FSM
  # transform can't yet model (the body falls back to stackful).
  #
  # Shapes:
  #   :indexed_slice -- usize index iterates a slice. Suffix is
  #                     ".items" for ArrayList-backed collections,
  #                     "" for raw arrays.
  #   :pool_indexed  -- usize index iterates Pool capacity, checking
  #                     the packed state sidecar and binding the
  #                     corresponding direct payload value.
  #   :iterator      -- a stateful iterator object lives on ctx;
  #                     `.next()` returns ?T (or ?*T for sets), and
  #                     the bound var captures the unwrapped value.
  #
  # Adding a new collection = adding one branch here. The splitter
  # never inspects the type directly.
  sig { returns(T.nilable(TypeFsmForEachDescriptor)) }
  def fsm_foreach_descriptor
    if pool?
      TypeFsmForEachDescriptor.new(kind: :pool_indexed, var_zig_type: element_zig_type_or_anyopaque)
    elsif map?
      # FOR k IN map iterates KEYS. keyIterator yields ?*K, so the
      # bound var dereferences (deref: true).
      TypeFsmForEachDescriptor.new(kind: :iterator, init_method: "keyIterator", advance_method: "next",
        deref: true, var_zig_type: key_zig_type)
    elsif set_collection?
      # FOR v IN set: keyIterator yields ?*T, so the bound var is
      # the element type (after deref).
      TypeFsmForEachDescriptor.new(kind: :iterator, init_method: "keyIterator", advance_method: "next",
        deref: true, var_zig_type: element_zig_type_or_anyopaque)
    elsif list_collection? || (array? && dynamic?)
      TypeFsmForEachDescriptor.new(kind: :indexed_slice, slice_suffix: ".items",
        var_zig_type: element_zig_type_or_anyopaque)
    elsif array? && !dynamic?
      TypeFsmForEachDescriptor.new(kind: :indexed_slice, slice_suffix: "",
        var_zig_type: element_zig_type_or_anyopaque)
    else nil
    end
  end

  # Returns the canonical registry key for this type.
  # Used as the single lookup key for INDEX_OPS, COLLECTION_METHOD_CONFIGS, etc.
  # All type-to-dispatch mappings must go through here — never add new if/elsif
  # chains on type predicates in lowering or annotation code.
  sig { returns(T.nilable(Symbol)) }
  def dispatch_key
    return nil if c_array_view?
    if numeric_map?         then :numeric_map
    elsif map?              then :string_map
    elsif pool?             then :pool
    elsif set_collection?   then :set_collection
    elsif list_collection?              then :list
    elsif non_string_array?             then :array
    elsif string? && symbol? then :string_symbol
    elsif string? && raw?    then :string_raw
    end
    # Returns nil for non-dispatchable types (plain String, primitives, etc.)
  end

  # Collections that need shared mutable state across call boundaries.
  # Passed by pointer (&) at call sites, use anytype params, tracked in
  # the MIR function context to prevent double-& in recursive calls.
  sig { returns(T::Boolean) }
  def needs_pointer_passing?
    map? || pool?
  end

  # True when backing storage operations require the heap allocator.
  # Used by the transpiler to resolve :receiver_storage allocator symbols.
  #
  # A1: tense_observable? is included so mir_lowering's downgrade branch
  # (lower_var_decl, around line 4594) preserves classify_observable's
  # `entry[:alloc] = :heap` instead of overwriting it with the result of
  # cleanup_allocator (which falls through to :frame for observable
  # shapes). Without this guard, the :observable cleanup template's
  # `name.destroy(<alloc>)` would emit a frame allocator for a wrapper
  # that was created on the heap -- a cross-allocator destroy that
  # surfaces as a leak under DebugAllocator and silent UB elsewhere.
  sig { returns(T::Boolean) }
  def needs_heap_backing?
    sharded? || heap? || tense_observable?
  end

  sig { returns(T::Boolean) }
  def heap_return_storage?
    heap? || dynamic?
  end

  # True when this map type stores an allocator in its Zig struct initializer.
  # StringMaps/StripedMaps need .alloc = heapAlloc(); NumericMaps and
  # PartitionedMaps (shared-nothing sharded) don't have an alloc field.
  sig { returns(T::Boolean) }
  def map_init_needs_alloc?
    return false unless map?
    return false if numeric_map?
    return false if sharded? && !striped?
    true
  end

  # Capturing a plain StringHashMap into a BG/fiber context requires an
  # explicit deinit pattern. Numeric maps, shared/locked/sharded map
  # families, and resource-backed values have their own cleanup path.
  sig { returns(T::Boolean) }
  def captured_plain_string_map_needs_deinit?
    map? && !numeric_map? && !sharded? && !striped? && !any_rc? && !any_sync?
  end

  # True when backing data is frame-allocated and must be promoted to heap
  # before escaping its scope (return, BG capture, etc.).
  # Covers: @list (frame-backed buffer), string HashMap (frame-backed keys/buckets),
  # and strings ([]const u8 slices pointing into the frame arena).
  #
  # Authoritative source: `escape_class`. A `:slice_managed` type's
  # backing buffer dies with the declaring frame, so escape-via-RETURN /
  # struct-field / etc. requires heap-promotion. `:by_ref` types whose
  # FIELDS are `:slice_managed` need promotion too — that requires a
  # schema lookup; see `cleanup_allocator` callers / Phase 3 follow-up.
  sig { returns(T::Boolean) }
  def needs_escape_promotion?
    return false if sharded?  # sharded collections are always heap-backed
    escape_class == :slice_managed
  end

  RESOURCE_TYPES = T.let(Set[:File, :TCPClient, :TCPServer].freeze, T::Set[Symbol])

  # Canonical mapping from CLEAR type symbols to Zig type strings.
  # User-defined types (structs, enums, unions) pass through as-is.
  ZIG_TYPE_MAP = T.let({
    Float64:   "f64",
    Int64:     "i64",
    String:    "[]const u8",
    Void:      "void",
    Bool:      "bool",
    Byte:      "u8",
    Int8:      "i8",
    Int16:     "i16",
    Int32:     "i32",
    UInt8:     "u8",
    UInt16:    "u16",
    UInt32:    "u32",
    UInt64:    "u64",
    Float32:   "f32",
    TargetInt: "c_int",
    TargetUInt: "c_uint",
    TargetLong: "c_long",
    TargetULong: "c_ulong",
    TargetLongLong: "c_longlong",
    TargetULongLong: "c_ulonglong",
    Any:       "f64",
    Range:     "CheatLib.Range",
    File:      "CheatLib.File",
    TCPServer: "i32",
    TCPClient: "i32",
  }.freeze, T::Hash[Symbol, String])

  # True when this type is a resource (File, TCPClient, TCPServer, etc.)
  # Checks the explicit flag (set by annotator after resolve_resource_close)
  # and falls back to checking known resource type names.
  sig { returns(T::Boolean) }
  def resource?
    return false if node? # the store, not each compact handle, owns the payload
    return true if @is_resource == true

    Type.resource_type_symbol?(resolved)
  end

  SchemaLookupResult = T.type_alias do
    T.nilable(T.any(Schemas::EnumSchema, Schemas::StructSchema, Schemas::UnionSchema, Schemas::ResourceSchema))
  end
  SchemaLookup = T.type_alias { T.proc.params(name: Symbol).returns(SchemaLookupResult) }
  SchemaResolver = T.type_alias { SchemaLookup }

  # COPY may deep-copy ordinary heap data, but it cannot duplicate a linear
  # resource handle. This predicate is deliberately transitive: wrapping a
  # CLOSE resource in an optional, collection, union, or ordinary struct does
  # not make the handle copyable.
  sig { params(schema_lookup: T.nilable(SchemaLookup), seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  def contains_linear_resource?(schema_lookup = nil, seen = nil)
    return true if resource?

    seen_types = seen || Set.new
    key = type_id.key
    return false if seen_types.include?(key)

    next_seen = seen_types.dup.add(key)

    if optional?
      inner = wrapped_type
      return inner ? inner.contains_linear_resource?(schema_lookup, next_seen) : false
    end

    if error_union?
      return success_type.contains_linear_resource?(schema_lookup, next_seen)
    end

    if tuple?
      return generic_args.any? { |arg| arg.contains_linear_resource?(schema_lookup, next_seen) }
    end

    if map?
      return key_type.contains_linear_resource?(schema_lookup, next_seen) ||
        value_type.contains_linear_resource?(schema_lookup, next_seen)
    end

    if array? || collection?
      element = element_type
      return element ? element.contains_linear_resource?(schema_lookup, next_seen) : false
    end

    return false unless schema_lookup

    schema = schema_lookup.call(resolved)
    return true if schema.is_a?(Schemas::ResourceSchema)

    if schema.is_a?(Schemas::StructSchema)
      return schema.fields.values.any? do |field|
        next false if field.borrowed

        substitute_generic_schema_field_type(field.type, schema)
          .contains_linear_resource?(schema_lookup, next_seen)
      end
    end

    if schema.is_a?(Schemas::UnionSchema)
      return schema.variants.values.any? do |variant|
        if variant.is_a?(Schemas::InlineStructVariant)
          variant.fields.values.any? do |field|
            Type.from_input(field).contains_linear_resource?(schema_lookup, next_seen)
          end
        else
          Type.from_variant_input(variant).contains_linear_resource?(schema_lookup, next_seen)
        end
      end
    end

    false
  end

  # Resolve the close/deinit plan for resource types.
  # Returns a named result so the generated Clear has a concrete type.
  #
  # Group 1 / Group 2 separation: when a Group-2 shape (pool/set/...) is
  # wrapped with Group-1 ownership (Arc/Rc), the bare-shape `.deinit()`
  # call doesn't apply against the wrapper. Skip the resource path so the
  # cleanup classifier picks the rc/sync entry instead, which cascades
  # through the wrapper down to the inner shape's destruction.
  class ResourceCloseResult < T::Struct
    const :is_resource, T::Boolean
    const :close_plan, T.untyped
  end

  sig { params(lookup_arg: T.nilable(SchemaResolver), lookup_block: T.nilable(SchemaLookup)).returns(T.nilable(SchemaResolver)) }
  def self.schema_resolver(lookup_arg, lookup_block)
    return lookup_arg unless lookup_arg.nil?
    return nil if lookup_block.nil?

    lookup_block
  end

  # ruby-to-clear: skip
  sig { params(schema_lookup: T.nilable(SchemaLookup)).returns(ResourceCloseResult) }
  def resolve_resource_close(schema_lookup = nil)
    return ResourceCloseResult.new(is_resource: false, close_plan: nil) if node?
    return ResourceCloseResult.new(is_resource: false, close_plan: nil) if any_rc?
    if open_stream? || inf_stream? || split_open_stream?
      return ResourceCloseResult.new(is_resource: true, close_plan: Type.deinit_resource_close_plan)
    end

    return ResourceCloseResult.new(is_resource: false, close_plan: nil) unless schema_lookup
    schema = T.let(schema_lookup.call(resolved), SchemaLookupResult)

    if schema.is_a?(Schemas::ResourceSchema)
      return ResourceCloseResult.new(is_resource: true, close_plan: schema.close_plan)
    end

    ResourceCloseResult.new(is_resource: false, close_plan: nil)
  end

  # True when this is a list of promises: ~T[]@list — a dynamic list of BG tasks.
  # Declared as `MUTABLE futures: ~T[]@list = []`; populated via append(futures, BG { ... }).
  sig { returns(T::Boolean) }
  def promise_list?
    future? && list_collection?
  end

  # True when the collection has a sharding topology modifier (@pool:sharded(N) / @list:sharded(N)).
  sig { returns(T::Boolean) }
  def sharded?
    !shard_count.nil?
  end

  sig { returns(T::Boolean) }
  def soa?
    soa
  end

  # Fixed-size SOA array without collection wrapper (T[N]@soa).
  sig { returns(T::Boolean) }
  def fixed_soa?
    fixed? && soa? && !collection?
  end

  sig { returns(T::Boolean) }
  def soa_linear_collection?
    soa? && (pool? || list_collection? || fixed_soa?)
  end

  sig { returns(T::Boolean) }
  def list_requires_array_shape?
    list_collection? && !array? && !promise_list? &&
      !(tense? && tense_type.array?)
  end

  sig { returns(T::Boolean) }
  def observable_array_without_set?
    !!(tense? && observable? && tense_type.array? && !set_collection?)
  end

  sig { returns(T::Boolean) }
  def soa_requires_fixed_array?
    soa? && !collection? && (!array? || !fixed?)
  end

  sig { returns(T::Boolean) }
  def soa_list_materialization?
    (list_collection? || fixed_soa?) && soa?
  end

  sig { returns(T::Boolean) }
  def dynamic_field_array?
    array? && (dynamic? || list_collection?)
  end

  sig { returns(T::Boolean) }
  def borrowed_array_argument?
    non_string_array? && !pool?
  end

  sig { params(other: T.nilable(Type)).returns(T::Boolean) }
  def string_comparable_with?(other)
    return false unless string?
    return true if other.nil?

    other.string?
  end

  sig { returns(T::Boolean) }
  def plain_indirect_value?
    !!(indirect? && !any_sync? && (ownership.nil? || ownership == :affine) &&
      !fn_type? && !error_union? && !optional?)
  end

  # A sharded collection with sync capability = lock-striped (skew-safe).
  # Replaces the old :striped(N) keyword — now expressed via composition:
  #   HashMap<V>:sharded(N) @locked → StripedStringMap
  sig { returns(T::Boolean) }
  def striped?
    sharded? && any_sync?
  end

  sig { returns(Type) }
  def value_type
    expression = shape.expression
    expression = expression.inner if expression.is_a?(FallibleTypeExpression)
    expression = expression.inner if expression.is_a?(OptionalTypeExpression)
    return Type.from_child_expression(expression.value) if expression.is_a?(MapTypeExpression)

    Type.new(:Any)
  end

  # Generic struct instance: Pair<Number>, Map<String, Number>
  sig { returns(T::Boolean) }
  def generic_instance?
    shape.generic_instance
  end

  sig { returns(T::Boolean) }
  def projection?
    shape.expression.is_a?(TypeProjectionExpression)
  end

  # Generic projections and aggregates cannot settle their cleanup shape
  # until Zig specializes the enclosing function. Treat them as potentially
  # owning so COPY/field replacement emits comptime cleanup rather than a
  # shallow value move that is only sound for primitive instantiations.
  sig { returns(T::Boolean) }
  def specialization_may_need_cleanup?
    return true if projection? || generic_instance?
    return payload_type&.specialization_may_need_cleanup? == true if error_union?

    optional? && wrapped_type&.specialization_may_need_cleanup? == true
  end

  sig { returns(T.nilable(Symbol)) }
  def projection_owner
    expression = shape.expression
    expression.is_a?(TypeProjectionExpression) ? expression.owner : nil
  end

  sig { returns(T.nilable(Symbol)) }
  def projection_member
    expression = shape.expression
    expression.is_a?(TypeProjectionExpression) ? expression.member : nil
  end

  sig { returns(T.nilable(Symbol)) }
  def projection_protocol
    expression = shape.expression
    expression.is_a?(TypeProjectionExpression) ? expression.protocol : nil
  end

  # The base type name of a generic instance: :"Pair<Number>" → :Pair
  sig { returns(Symbol) }
  def generic_base
    Type.symbol_or_default(shape.generic_base_raw, resolved)
  end

  sig { returns(T::Boolean) }
  def tuple?
    generic_instance? && generic_base == :Tuple
  end

  sig { returns(T::Boolean) }
  def id_handle?
    generic_instance? && shape.generic_base_raw == :Id
  end

  sig { returns(T.nilable(String)) }
  def ownership_surface_name
    own = ownership
    return nil if own.nil?

    Type.ownership_surface_name_for(own)
  end

  sig { returns(T.nilable(String)) }
  def sync_surface_name
    current_sync = sync
    return nil if current_sync.nil?

    Type.sync_surface_name_for(current_sync)
  end

  sig { returns(T.nilable(String)) }
  def sync_family_name
    current_sync = sync
    return nil if current_sync.nil?

    Type.sync_family_name_for(current_sync)
  end

  # The type arguments as Type objects: [Type(:Float64), Type(:String)]
  sig { returns(T::Array[Type]) }
  def generic_args
    expression = shape.expression
    expression = expression.inner if expression.is_a?(FallibleTypeExpression)
    expression = expression.inner if expression.is_a?(OptionalTypeExpression)
    items = if expression.is_a?(TupleTypeExpression)
      expression.items
    elsif expression.is_a?(NamedTypeExpression)
      expression.arguments
    else
      []
    end
    items.map { |item| Type.from_child_expression(item) }
  end

  sig { returns(T::Boolean) }
  def struct?
    !primitive? && !any? && !void? && !string? && !array? && !map? && !tuple? && !optional? && !error_union? && !tense? && !fn_type?
  end

  sig { returns(T::Boolean) }
  def optional?
    (shape.optional && !array?) == true
  end

  # CLEAR's prefix binds through an array suffix: ?T[] is an array whose
  # elements are optional T, not an optional array of T. TypeShape retains
  # the lexical prefix so tense aliases such as ~?T[] can still be
  # distinguished from ~T[] without reparsing the source spelling.
  sig { returns(T::Boolean) }
  def optional_element_array?
    (shape.optional && array?) == true
  end

  sig { returns(T.nilable(Type)) }
  def wrapped_type
    return nil unless optional?

    expression = shape.expression
    expression = expression.inner if expression.is_a?(FallibleTypeExpression)
    return nil unless expression.is_a?(OptionalTypeExpression)

    inner = Type.from_child_expression(expression.inner)
    inner.merge_capabilities_from!(self)
    inner.copy_placement_from!(self)
    inner
  end

  # Error union types: !T (Zig-style error returns)
  sig { returns(T::Boolean) }
  def error_union?
    shape.error_union
  end

  sig { returns(T.nilable(Type)) }
  def payload_type
    return nil unless error_union?
    expression = shape.expression
    return nil unless expression.is_a?(FallibleTypeExpression)

    Type.from_child_expression(expression.inner)
  end

  sig { returns(Type) }
  def success_type
    return Type.copy_type(self) unless error_union?

    error_union_payload_with_outer_capabilities
  end

  sig { returns(Type) }
  def error_union_payload_with_outer_capabilities
    payload = Type.new(T.must(payload_type))
    payload.merge_capabilities_from!(self)
    payload.copy_placement_from!(self)
    payload
  end

  sig { returns(Type) }
  def value_payload_type
    t = success_type
    t.optional? ? T.must(t.wrapped_type) : t
  end

  sig { returns(Type) }
  def non_optional_type
    optional? ? T.must(wrapped_type) : self
  end

  # Tense (Promise) types: ~T — a background task that will produce T
  sig { returns(T::Boolean) }
  def tense?
    shape.tense
  end

  # Observable accumulator: ~T@observable.
  # The runtime backing is a single-writer snapshot (Observable<T>) or atomic
  # accumulator. Only such types may be the target of `WITH VIEW`.
  sig { returns(T::Boolean) }
  def observable?
    is_observable
  end

  # NEXT on an observable array future materializes an owned array snapshot.
  # Keep that source-shape decision with Type so annotation and MIR lowering
  # cannot drift on the `observable? && tense_type.array?` protocol.
  sig { returns(T::Boolean) }
  def observable_array_future?
    tt = tense_type
    return false unless observable?

    tt.array? == true
  end

  # True when this is a pipeline-terminal observable binding shape:
  #   - `~T@observable`              (scalar terminals: SUM/COUNT/MAX/...)
  #   - `~T[]@set:observable`        (DISTINCT)
  # Captures the carve-out used by both Type#zig_type's observable
  # branch and CleanupClassifier's classify_observable so the
  # invariant lives in one place.
  sig { returns(T::Boolean) }
  def tense_observable?
    return false unless tense? && observable?
    inner = tense_type
    return true if !inner.array? && !inner.map?  # scalar terminal
    set_collection?  # collection terminal (DISTINCT)
  end

  # A3: single source of truth for every pipeline-terminal observable.
  # Each entry consolidates the three pieces of information previously
  # split across OBSERVABLE_WRAPPERS (here), PUBLISH_SPEC + FOLD_OP_OBSERVABLE_TERMINAL
  # (pipeline_host.rb):
  #
  #   :ast_class -- observable terminal tag so the pipeline lowerer can
  #                 map its fold-op class to the terminal symbol. Omitted on
  #                 :reduce / :distinct because they have their own
  #                 dedicated lowering helpers (lower_range_reduce_observable
  #                 / lower_range_fold_observable_distinct) and never
  #                 hit the default fold-op dispatch.
  #   :publish   -- per-item publish recipe { method:, expr:, gate: }
  #                 consumed by lower_range_fold_observable_default.
  #                 Same omission for :reduce / :distinct.
  #
  sig { returns(ObservableTerminalRegistry) }
  def self.observable_terminals
    {
      sum: ObservableTerminalSpec.new(
        ast_class: :sum,
        publish: ObservablePublishSpec.new(publish_method: "add", expr: :typed, gate: :always),
      ),
      count: ObservableTerminalSpec.new(
        ast_class: :count,
        publish: ObservablePublishSpec.new(publish_method: "inc", expr: :none, gate: :pred),
      ),
      avg: ObservableTerminalSpec.new(
        # AVG view is always f64.
        ast_class: :avg,
        publish: ObservablePublishSpec.new(publish_method: "add", expr: :f64, gate: :always),
      ),
      max: ObservableTerminalSpec.new(
        ast_class: :max,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :typed, gate: :always),
      ),
      min: ObservableTerminalSpec.new(
        ast_class: :min,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :typed, gate: :always),
      ),
      any: ObservableTerminalSpec.new(
        ast_class: :any,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :pred, gate: :always),
      ),
      all: ObservableTerminalSpec.new(
        ast_class: :all,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :pred, gate: :always),
      ),
      find: ObservableTerminalSpec.new(
        ast_class: :find,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :item, gate: :pred),
      ),
      reduce: ObservableTerminalSpec.new(
        # REDUCE has its own lower_range_reduce_observable helper because
        # the user-supplied reducer body references stage-context (`_`
        # and `acc`) which the default publish recipe can't express.
      ),
      distinct: ObservableTerminalSpec.new(
        # DISTINCT's tense_type is `T[]@set` (dynamic) or `T[N]@set`
        # (bounded). Dynamic uses geometric-doubling StreamSet; bounded
        # uses fixed-capacity StreamSetBounded (no grow, no refcounted
        # snapshots, [N]T buffer never relocates). Has its own
        # lower_range_fold_observable_distinct helper.
      ),
    }
  end

  sig { params(terminal: Symbol, type_info: Type).returns(T.nilable(String)) }
  # ruby-to-clear: effects reentrant
  def self.observable_wrapper_for_terminal(terminal, type_info)
    return "ObservableSum(#{type_info.zig_type})" if terminal == :sum
    return "ObservableCount()" if terminal == :count
    return "ObservableAvg(f64)" if terminal == :avg
    return "ObservableMax(#{type_info.zig_type})" if terminal == :max
    return "ObservableMin(#{type_info.zig_type})" if terminal == :min
    return "ObservableAny()" if terminal == :any
    return "ObservableAll()" if terminal == :all

    if terminal == :find
      wrapped = type_info.wrapped_type
      return nil if wrapped.nil?

      return "ObservableFind(#{wrapped.zig_type})"
    end

    return "ObservableReduce(#{type_info.zig_type})" if terminal == :reduce

    if terminal == :distinct
      elem = type_info.element_type
      return nil if elem.nil?

      if type_info.fixed?
        return "ObservableStreamSetBounded(#{elem.zig_type}, #{Type.array_capacity_label(type_info.capacity)})"
      end
      return "ObservableStreamSet(#{elem.zig_type})"
    end

    nil
  end

  private

  sig { params(tense_type: Type).returns(String) }
  # ruby-to-clear: effects reentrant
  def observable_wrapper_zig(tense_type)
    # A2: a missing terminal stamp here means an upstream pass produced
    # an `~T@observable` Type without going through pipe_analysis's
    # mark_observable_terminal! (which sets observable_terminal as it
    # lifts the LHS type). The C5 audit fixed every known caller so
    # this should be unreachable in practice, but if it does fire we
    # need a clear compiler-level message rather than the previous
    # internal "BYPASS at <ruby caller>" debug raise.
    if observable_terminal.nil?
      raise CompilerError.new(
        nil,
        "Internal: Type#observable_wrapper_zig called on `#{self.to_s}` " \
        "without an observable_terminal stamp. The terminal kind " \
        "(:sum / :count / :max / :min / :avg / :any / :all / :find / :reduce / :distinct) " \
        "is set by pipe_analysis's mark_observable_terminal! at fold-pipe analysis " \
        "time; reaching here means an `@observable` Type was constructed by a path " \
        "that bypasses that analyzer.",
        nil,
      )
    end
    terminal = T.must(observable_terminal)
    wrapper = Type.observable_wrapper_for_terminal(terminal, tense_type)
    if wrapper.nil?
      raise CompilerError.new(
        nil,
        "Internal: unknown observable terminal kind #{terminal.to_s}. " \
        "Add an entry to Type.observable_terminals in src/ast/type.rb.",
        nil,
      )
    end
    wrapper
  end

  public

  # Preferred predicate name for ~T / stream-like future values.
  sig { returns(T::Boolean) }
  def future?
    tense?
  end

  sig { returns(Type) }
  def tense_type
    expression = shape.expression
    return Type.from_child_expression(expression.inner) if expression.is_a?(FutureTypeExpression)
    if expression.is_a?(StreamTypeExpression)
      dimension = expression.cardinality == :FINITE ? :LIST : expression.cardinality
      return Type.from_child_expression(
        LinearTypeExpression.new(kind: :array, dimensions: [dimension], item: expression.item)
      )
    end

    Type.new(:Void)
  end

  sig { returns(T::Boolean) }
  def canonical_stream?
    shape.expression.is_a?(StreamTypeExpression)
  end

  # True when this value is a canonical stream, possibly behind the one legal
  # outer SELECT wrapper (`![~]T`). Optional-before-stream is intentionally
  # rejected by the parser, so no optional recursion belongs here.
  sig { returns(T::Boolean) }
  def canonical_stream_result?
    return true if canonical_stream?
    return false unless error_union?

    payload = payload_type
    payload&.canonical_stream? == true
  end

  # Preserve all wrappers on the item (`?T`, `!T`, `!?T`) instead of
  # deriving through tense_type/element_type, which intentionally normalizes
  # some collection shapes for older stream aliases.
  sig { returns(T.nilable(Type)) }
  def canonical_stream_item_type
    stream = error_union? ? payload_type : self
    return nil unless stream&.canonical_stream?

    expression = stream.shape.expression
    return nil unless expression.is_a?(StreamTypeExpression)

    Type.from_child_expression(expression.item)
  end

  sig { returns(T::Boolean) }
  def stream_step?
    generic_instance? && generic_base == :StreamStep && generic_args.length == 1
  end

  sig { returns(T.nilable(Type)) }
  def stream_step_item_type
    return nil unless stream_step?

    generic_args.first
  end

  # Finite dynamic stream: ~T[].
  # Used for lazy finite producers like ranges. NEXT returns ?T until exhausted.
  sig { returns(T::Boolean) }
  def dynamic_stream?
    expression = shape.expression
    return true if expression.is_a?(StreamTypeExpression) && expression.cardinality == :FINITE

    !!(future? && tense_type.dynamic? && !tense_type.optional? &&
      !tense_type.optional_element_array? && !list_collection?)
  end

  # New syntax alias: ~?T[] means an open stream of T (NEXT returns ?T).
  # Parsed as future of ?T[] by the general type parser, then reinterpreted here.
  sig { returns(T.nilable(Type)) }
  def optional_stream_shape_type
    return nil unless future?

    stream_shape = tense_type
    if stream_shape.optional_element_array?
      element = stream_shape.element_type
      return nil if element.nil?

      return nil unless element.optional?

      return Type.array_of(T.must(element.wrapped_type), capacity: stream_shape.capacity)
    end

    return nil unless stream_shape.optional?
    wrapped = T.let(stream_shape.wrapped_type, T.nilable(Type))
    return wrapped if wrapped&.array?

    nil
  end

  private

  sig { returns(T::Boolean) }
  def open_stream_alias?
    shape = T.let(optional_stream_shape_type, T.nilable(Type))
    return false if shape.nil?

    shape.dynamic?
  end

  public

  sig { returns(T::Boolean) }
  def stream?
    dynamic_stream? || bounded_stream? || open_stream? || inf_stream? || split_open_stream?
  end

  sig { returns(T::Boolean) }
  def runtime_stream?
    dynamic_stream? || bounded_stream? || open_stream? || inf_stream?
  end

  sig { returns(T.nilable(Type)) }
  def runtime_stream_storage_element_type
    return open_stream_element_type if open_stream?
    return tense_type.element_type if dynamic_stream? || bounded_stream?
    return inf_stream_element_type if inf_stream?

    nil
  end

  sig { params(has_limit: T::Boolean).returns(T::Boolean) }
  def bounded_pipeline_stream_source?(has_limit)
    dynamic_stream? || bounded_stream? || open_stream? || (inf_stream? && has_limit)
  end

  sig { returns(T::Boolean) }
  def single_future?
    future? && !stream? && !shared_promise? && !promise_list?
  end

  sig { returns(T::Boolean) }
  def split_open_stream?
    split? && open_stream?
  end

  # Bounded stream: ~T[N] or ~?T[N] — a fixed stream of N elements consumed via NEXT.
  # Distinct from a single promise (~T): NEXT can be called N times, not exactly once.
  sig { returns(T::Boolean) }
  def bounded_stream?
    expression = shape.expression
    return true if expression.is_a?(StreamTypeExpression) && expression.cardinality.is_a?(Integer)

    # ~T[N] is a bounded stream of N elements. ~String is NOT a bounded stream
    # even though String is internally []const u8 (a fixed array) - it's a Promise.
    optional_shape = T.let(optional_stream_shape_type, T.nilable(Type))
    optional_bounded = T.let(false, T::Boolean)
    unless optional_shape.nil?
      optional_bounded = optional_shape.fixed? && !optional_shape.string?
    end

    !!(future? && (
      (tense_type.fixed? && !tense_type.string?) ||
      optional_bounded
    ))
  end

  # Shared promise: ~T@shared — a memoized promise backed by Arc-style ref counting.
  # Multiple holders can call NEXT independently; NEXT is idempotent per handle.
  # NOT linearly affine — can be retained (cloned) without consuming it.
  sig { returns(T::Boolean) }
  def shared_promise?
    future? && shared?
  end

  # Open stream: ~?T[] (preferred) or legacy ~T[?].
  # Generator-backed stream; NEXT returns ?T (nil when exhausted).
  # Resource semantics: call deinit() to free the heap-allocated buffer.
  sig { returns(T::Boolean) }
  def open_stream?
    future? && (tense_type.open_stream_marker? || open_stream_alias?)
  end

  # The element type T in ~?T[] / ~T[?].
  sig { returns(T.nilable(Type)) }
  def open_stream_element_type
    return nil unless open_stream?
    if open_stream_alias?
      shape = T.let(optional_stream_shape_type, T.nilable(Type))
      return nil if shape.nil?

      return shape.element_type
    end
    tense_type.element_type
  end

  # Infinite stream: ~T[INF] — a lazy rendezvous generator; NEXT returns T (never nil).
  # Generator and consumer rendezvous on each value: push() blocks until next() reads it.
  # Resource semantics: call deinit() to free the heap-allocated Inner.
  sig { returns(T::Boolean) }
  def inf_stream?
    expression = shape.expression
    return true if expression.is_a?(StreamTypeExpression) && expression.cardinality == :INF

    future? && tense_type.inf_stream_marker?
  end

  # The element type T in ~T[INF].
  sig { returns(T.nilable(Type)) }
  def inf_stream_element_type
    return nil unless inf_stream?
    tense_type.element_type
  end

  # The element type T in ~T[N], or ?T in ~?T[N].
  sig { returns(T.nilable(Type)) }
  def stream_element_type
    return nil unless bounded_stream?
    optional_shape = T.let(optional_stream_shape_type, T.nilable(Type))
    unless optional_shape.nil?
      if optional_shape.fixed?
        element = optional_shape.element_type
        return nil if element.nil?

        return Type.optional_of(Type.type_input_string(Type.surface_name_type(element)))
      end
    end

    tense_type.element_type
  end

  # The capacity N in ~T[N] / ~?T[N].
  sig { returns(T.nilable(ArrayCapacity)) }
  def stream_capacity
    return nil unless bounded_stream?
    optional_shape = T.let(optional_stream_shape_type, T.nilable(Type))
    return optional_shape.capacity unless optional_shape.nil?

    tense_type.capacity
  end

  sig { returns(T.nilable(Type)) }
  # ruby-to-clear: effects reentrant
  def element_type
    return nil unless array?
    expression = shape.expression
    expression = expression.inner if expression.is_a?(FallibleTypeExpression)
    expression = expression.inner if expression.is_a?(OptionalTypeExpression) && expression.inner.is_a?(LinearTypeExpression)
    return nil unless expression.is_a?(LinearTypeExpression)

    Type.from_child_expression(expression.item)
  end

  sig { params(lookup_arg: T.nilable(SchemaResolver), lookup_block: T.nilable(SchemaLookup)).returns(Integer) }
  def slot_size(lookup_arg = nil, &lookup_block)
    optional_resolver = Type.schema_resolver(lookup_arg, lookup_block)

    # Generic instances (e.g. Id<T>) are intrinsic scalar types — always 1 slot.
    return 1 if scalar_slot?

    return 1 unless optional_resolver
    resolver = T.let(optional_resolver, SchemaResolver)

    fixed_slots = fixed_array_slot_size(resolver)
    if fixed_slots
      return fixed_slots
    end

    return 1 unless struct?

    schema = resolver.call(resolved)
    if schema
      if schema.is_a?(Schemas::StructSchema)
        return 1 unless schema.type_params.empty?

        total = T.let(0, Integer)
        fields = schema.fields.values
        i = T.let(0, Integer)
        while i < fields.length
          field = T.must(fields[i])
          total += field.type.slot_size(resolver)
          i += 1
        end
        return total
      end
    end

    1 # Default
  end

  sig { params(resolver: SchemaResolver).returns(T.nilable(Integer)) }
  # ruby-to-clear: effects reentrant
  def fixed_array_slot_size(resolver)
    return nil unless fixed?

    fixed_capacity = capacity
    return nil unless Type.integer_array_capacity?(fixed_capacity)

    elem = element_type
    return nil unless elem

    Type.array_capacity_integer(fixed_capacity) * elem.slot_size(resolver)
  end

  sig { returns(T::Boolean) }
  def scalar_slot?
    primitive? || heap? || dynamic? || any? || multiowned? || shared? ||
      any_sync? || generic_instance?
  end

  sig { returns(T::Boolean) }
  def requires_move?
    return false if node?                   # compact handles copy; their domain owns payloads
    return false if fn_type?                # Function pointers are pointer-sized; no move semantics
    return false if bounded_stream?         # Bounded streams are consumed incrementally — not linearly affine
    return false if shared_promise?         # Shared promises are non-affine — multiple NEXT calls allowed
    return false if open_stream?            # Open streams are resources with deinit cleanup, not linear
    return false if inf_stream?             # Infinite streams are resources with deinit cleanup, not linear
    return false if split_open_stream?      # Split streams are shared replay handles with deinit cleanup
    return false if list_collection? || pool? || set_collection?  # @list/@pool/@set are arena/heap-managed via defer deinit — not linearly affine
    return false if map?                       # @map is cleaned up via mapDeinit/numericMapDeinit — not linearly affine
    return true if tense?                   # Single promises are linear — must be consumed exactly once
    return false if multiowned? || shared?  # Rc/Arc use retain/release, not linear move semantics
    return false if any_sync?               # Sync vars manage their own lifecycle
    return true if heap?
    return true if array?
    !primitive?
  end

  sig { params(lookup_arg: T.nilable(SchemaResolver), lookup_block: T.nilable(SchemaLookup)).returns(T::Boolean) }
  def copyable?(lookup_arg = nil, &lookup_block)
    return true if primitive?
    return true if string?  # Zig strings ([]const u8) are trivially copyable (pointer + length)
    return false if array?  # Arrays are not explicitly copyable (use slicing or @list)
    return false if multiowned? || shared? || any_sync?  # Rc/Arc/Locked must not be silently copied
    return false if heap?                   # Heap-allocated types are not copyable
    return false if frame? && struct?       # Frame-allocated struct pointers are not copyable
    return false if map?                    # Maps are not copyable
    if tuple?
      if lookup_block
        return generic_args.all? { |arg| arg.copyable?(&lookup_block) }
      end
      return generic_args.all? { |arg| arg.copyable?(lookup_arg) }
    end

    # Structs: copyable if all fields are copyable (for explicit COPY keyword)
    return false unless struct?

    resolver = Type.schema_resolver(lookup_arg, lookup_block)
    return false unless resolver
    resolver_fn = resolver
    schema = resolver_fn.call(resolved)
    return false unless schema
    if schema.is_a?(Schemas::StructSchema)
      fields = schema.fields.values
      i = T.let(0, Integer)
      while i < fields.length
        return false unless Type.from_input(fields.fetch(i).type).copyable?(resolver_fn)
        i += 1
      end

      return true
    end

    false
  end

  # BG/DO/CONCURRENT capture by-value: capturing a value of this type
  # into a fiber frame produces an INDEPENDENT instance — the outer
  # binding's death does not invalidate the capture.
  #
  # Like `implicitly_copyable?` but excludes user structs: even an
  # all-Copy struct is captured BY REFERENCE into the fiber frame
  # (the BG holds a pointer back to the outer struct's storage), so
  # outer-binding death = pointer-into-freed-memory. Used by the
  # annotator's BG-handle lifetime stamper to decide whether a capture
  # contributes to the handle's tied-lifetime source list.
  sig { params(lookup_arg: T.nilable(SchemaResolver), lookup_block: T.nilable(SchemaLookup)).returns(T::Boolean) }
  def bg_capture_is_value_copy?(lookup_arg = nil, &lookup_block)
    # Type-inherent classes that always-copy: primitives, Id<T>, rodata
    # string slices, fixed value arrays.
    return true if escape_class == :value || escape_class == :slice_rodata
    # Schema-aware refinement: at the Type level, enums and
    # unions-without-heap-variants land in :by_ref because Type can't
    # see schema; given a resolver they classify as value-copy.
    return false unless escape_class == :by_ref
    resolver = Type.schema_resolver(lookup_arg, lookup_block)
    return false unless resolver
    resolver_fn = resolver

    schema = resolver_fn.call(resolved)
    if schema.nil? && generic_instance?
      schema = resolver_fn.call(generic_base)
    end
    return false unless schema
    return true if schema.is_a?(Schemas::EnumSchema)
    if schema.is_a?(Schemas::UnionSchema)
      has_heap = schema.variants.values.any? { |vt| Type.variant_has_heap?(vt) }
      return !has_heap
    end
    # Structs (no :kind) deliberately fall through to false — captured by ref.
    false
  end

  # Implicitly copyable: used for branch merge and loop checks.
  # Same as copyable? but excludes user structs — structs need explicit COPY.
  # Primitives, strings, slices, enums, and unions are implicitly copyable.
  sig { params(lookup_arg: T.nilable(SchemaResolver), lookup_block: T.nilable(SchemaLookup)).returns(T::Boolean) }
  def implicitly_copyable?(lookup_arg = nil, &lookup_block)
    # @node values are compact generational handles. The NodeStore owns the
    # payload; copying a handle never copies or transfers the payload.
    return true if node?
    return true if primitive?
    # Pointer-backed ownership is not implicitly Copy, and—critically—an
    # indirect edge terminates schema recursion. Re-entering the pointee's
    # schema here makes recursive structs overflow the compiler stack.
    return false if indirect? || any_rc? || link?
    if optional?
      return lookup_block ? T.must(wrapped_type).implicitly_copyable?(&lookup_block) : T.must(wrapped_type).implicitly_copyable?(lookup_arg)
    end
    # Pool Id<T> handles are u64 indices — always Copy.
    return true if id_handle?
    if tuple?
      if lookup_block
        return generic_args.all? { |arg| arg.implicitly_copyable?(&lookup_block) }
      end
      return generic_args.all? { |arg| arg.implicitly_copyable?(lookup_arg) }
    end
    # String literals (rodata) are Copy - static data, never freed.
    return true if string? && rodata?
    # Non-literal strings are NOT Copy - they reference frame/heap data.
    return true if array? && !list_collection? && !pool? && !set_collection? && !string?
    resolver = Type.schema_resolver(lookup_arg, lookup_block)
    return false unless resolver

    resolver_fn = resolver
    schema = resolver_fn.call(resolved)
    # For generic instances (Option<Float64>), try the base type (Option)
    if schema.nil? && generic_instance?
      schema = resolver_fn.call(generic_base)
    end
    return false unless schema

    return true if schema.is_a?(Schemas::EnumSchema)
    # Unions: Copy if no heap variants
    if schema.is_a?(Schemas::UnionSchema)
      has_heap = schema.variants.values.any? { |vt| Type.variant_has_heap?(vt) }
      return !has_heap
    end
    # Structs: Copy if all fields are Copy
    if schema.is_a?(Schemas::StructSchema)
      all_copy = schema.fields.values.all? do |field|
        ft = field.type
        ft = substitute_generic_schema_field_type(ft, schema)
        ft.implicitly_copyable?(resolver_fn)
      end
      return true if all_copy
    end

    false
  end

  # ── Recursive type analysis (mirrors Zig comptime functions) ──────

  sig { params(schema_lookup: T.nilable(SchemaLookup), seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  def recursive_cleanup_shape?(schema_lookup = nil, seen = nil)
    return false if node_reference?
    seen_set = T.let(seen || Set.new, T::Set[String])
    key = type_id.key
    return false if seen_set.include?(key)
    seen_set << key

    return false if borrowed_reference?
    # Symbols are interned, process-lifetime string data. They have String's
    # representation, but never own the backing bytes and therefore must not
    # make an enclosing collection recursively cleanup-bearing.
    return false if symbol?
    return true if resource?
    if optional?
      optional_inner = T.let(wrapped_type, T.nilable(Type))
      return false unless optional_inner
      return optional_inner.recursive_cleanup_shape?(schema_lookup, seen_set)
    end
    if error_union?
      payload = payload_type
      return false unless payload
      return payload.recursive_cleanup_shape?(schema_lookup, seen_set)
    end
    return true if string? || any_rc? || any_sync? || frozen? || link? || collection? || indirect? || future?

    if tuple?
      return generic_args.any? { |arg| arg.recursive_cleanup_shape?(schema_lookup, seen_set) }
    end

    if array?
      return true unless fixed?
      et = element_type
      return false unless et
      return et.recursive_cleanup_shape?(schema_lookup, seen_set)
    end

    return false unless schema_lookup
    lookup = schema_lookup
    schema = lookup.call(resolved)
    return false unless schema
    return true if schema.is_a?(Schemas::ResourceSchema)
    if schema.is_a?(Schemas::UnionSchema)
      values = T.let(schema.variants.values, T::Array[Schemas::UnionSchema::VariantValue])
      i = T.let(0, Integer)
      while i < values.length
        vt = values.fetch(i)
        unless vt
          i += 1
          next
        end
        if Schemas.inline_struct?(vt)
          field_values = T.unsafe(vt).fields.values
          field_index = T.let(0, Integer)
          while field_index < field_values.length
            return true if Type.from_input(field_values.fetch(field_index)).recursive_cleanup_shape?(lookup, seen_set)
            field_index += 1
          end
        else
          return true if Type.from_variant_input(vt).recursive_cleanup_shape?(lookup, seen_set)
        end
        i += 1
      end
      return false
    end

    if schema.is_a?(Schemas::StructSchema)
      fields = schema.fields.values
      i = T.let(0, Integer)
      while i < fields.length
        field = fields.fetch(i)
        if field.borrowed
          i += 1
          next
        end
        return true if substitute_generic_schema_field_type(field.type, schema).recursive_cleanup_shape?(lookup, seen_set)
        i += 1
      end
      return false
    end

    if schema.is_a?(Schemas::ResourceSchema)
      fields = schema.fields.values
      i = T.let(0, Integer)
      while i < fields.length
        field = fields.fetch(i)
        if field.borrowed
          i += 1
          next
        end
        return true if substitute_generic_schema_field_type(field.type, schema).recursive_cleanup_shape?(lookup, seen_set)
        i += 1
      end
      return false
    end

    false
  end

  # Mirror of Zig's needsPromotion. Returns true if this type contains
  # frame-allocated data that must be duped to heap on escape.
  # Recurses into struct fields and union variants.
  # Mirror of Zig's needsPromotion comptime predicate.
  # Returns true if this type contains frame-arena data that must be
  # duped to heap before returning from a function.
  sig { params(schema_lookup: T.nilable(SchemaLookup), seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def needs_promotion?(schema_lookup = nil, seen = nil)
    return false if node_reference?
    return true if string? || list_collection? || (map? && !numeric_map?)
    seen_set = T.let(seen || Set.new, T::Set[String])
    key = "promotion:#{type_id.key}"
    return false if seen_set.include?(key)
    seen_set << key

    if schema_lookup
      lookup = schema_lookup
      schema = lookup.call(resolved)
      if schema
        if schema.is_a?(Schemas::UnionSchema)
          return schema_union_needs_promotion?(schema, lookup, seen_set)
        elsif schema.is_a?(Schemas::StructSchema)
          return schema_struct_needs_promotion?(schema, lookup, seen_set)
        end
      end
    end
    false
  end

  # Mirror of Zig's needsCleanup. Returns true if this type owns
  # heap-allocated data that must be freed at scope exit.
  # Same as needs_promotion? but excludes bare strings (freed by
  # StringMap.freeUnionPayload inside collections, not at top level).
  # Plus: RC, NumericMap, Pool, Set.
  sig { params(schema_lookup: T.nilable(SchemaLookup), seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def needs_cleanup?(schema_lookup = nil, seen = nil)
    # NodeStore is registered with Runtime and releases every live payload at
    # Runtime.deinit. Individual handles are non-owning Copy values.
    return false if node?
    return false if borrowed_reference?
    if optional?
      inner = wrapped_type
      return false unless inner

      return inner.needs_cleanup?(schema_lookup, seen) || inner.string?
    end
    if error_union?
      payload = payload_type
      return false unless payload

      return payload.needs_cleanup?(schema_lookup, seen) || payload.string?
    end
    return non_string_array_needs_cleanup?(schema_lookup, seen) if non_string_array?

    return true if any_rc? || link? || resource? || collection? || future? || (string? && heap?) ||
                   any_sync? ||
                   indirect?
    seen_set = T.let(seen || Set.new, T::Set[String])
    key = "cleanup:#{type_id.key}"
    return false if seen_set.include?(key)
    seen_set << key

    if tuple?
      return generic_args.any? { |arg| arg.needs_cleanup?(schema_lookup, seen_set) }
    end

    if schema_lookup
      lookup = schema_lookup
      schema = lookup.call(resolved)
      if schema
        if schema.is_a?(Schemas::UnionSchema)
          return schema_union_needs_cleanup?(schema, lookup, seen_set)
        elsif schema.is_a?(Schemas::StructSchema)
          return schema_struct_needs_cleanup?(schema, lookup, seen_set)
        end
      end
    end
    false
  end

  sig { params(schema_lookup: T.nilable(SchemaLookup), seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def non_string_array_needs_cleanup?(schema_lookup, seen = nil)
    return true unless fixed?

    et = element_type
    return false unless et

    et.needs_cleanup?(schema_lookup, seen)
  end

  sig { params(schema_lookup: T.nilable(SchemaLookup)).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def ownership_bearing?(schema_lookup = nil)
    maybe_success_type = success_type
    return maybe_success_type.ownership_bearing_type?(schema_lookup) if maybe_success_type

    ownership_bearing_type?(schema_lookup)
  end

  # Returns the first capability that prevents a value of this type from
  # crossing an explicitly parallel execution boundary. This is recursive on
  # purpose: an ordinary aggregate is not thread-safe merely because the Rc,
  # scheduler-local node, or affine synchronization cell is one field down.
  # Both annotation and MIR lowering consume this single classification.
  sig { params(schema_lookup: T.nilable(SchemaLookup), seen: T.nilable(T::Set[String])).returns(T.nilable(Symbol)) }
  def parallel_boundary_forbidden_reason(schema_lookup = nil, seen = nil)
    return :local_scheduler_affinity if local?
    return :non_atomic_rc if multiowned?
    return nil if shared? || shared_node?
    return :scheduler_local_node if node?
    return :affine_locked if locked?
    return :affine_write_locked if write_locked?
    return :affine_versioned if versioned?

    child_types = T.let([], T::Array[Type])
    optional_child = wrapped_type
    child_types << optional_child if optional_child
    array_child = element_type
    child_types << array_child if array_child
    if map?
      child_types << key_type
      child_types << value_type
    end
    generic_args.each { |arg| child_types << arg }
    child_types.each do |child|
      reason = child.parallel_boundary_forbidden_reason(schema_lookup, seen)
      return reason if reason
    end

    return nil unless schema_lookup
    seen_types = T.let(seen || Set.new, T::Set[String])
    schema_key = resolved.to_s
    return nil if T.unsafe(seen_types).include?(schema_key)

    schema = schema_lookup.call(resolved)
    return nil unless schema

    next_seen = seen_types.dup
    T.unsafe(next_seen) << schema_key
    if schema.is_a?(Schemas::StructSchema)
      schema.fields.each_value do |field|
        reason = Type.from_input(field.type).parallel_boundary_forbidden_reason(schema_lookup, next_seen)
        return reason if reason
      end
    elsif schema.is_a?(Schemas::ResourceSchema)
      schema.fields.each_value do |field|
        reason = Type.from_input(field.type).parallel_boundary_forbidden_reason(schema_lookup, next_seen)
        return reason if reason
      end
    elsif schema.is_a?(Schemas::UnionSchema)
      schema.variants.each_value do |variant|
        next if variant.nil?
        if variant.is_a?(Schemas::InlineStructVariant)
          variant.fields.each_value do |field_type|
            reason = Type.from_input(field_type).parallel_boundary_forbidden_reason(schema_lookup, next_seen)
            return reason if reason
          end
        else
          reason = Type.from_input(variant).parallel_boundary_forbidden_reason(schema_lookup, next_seen)
          return reason if reason
        end
      end
    end

    nil
  end

  sig { params(schema_lookup: T.nilable(SchemaLookup)).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def ownership_bearing_type?(schema_lookup = nil)
    return false if primitive? || void? || any?
    return false if symbol? || raw? || c_string? || c_array_view?

    string? ||
      future? ||
      stream? ||
      heap_ptr? ||
      needs_cleanup?(schema_lookup) ||
      recursive_cleanup_shape?(schema_lookup)
  end

  # Does this type+allocator combination need explicit cleanup at scope exit?
  # For frame-allocated values, only types with heap internals (RC, resources,
  # mutexes) need cleanup -- the frame arena bulk-frees everything else.
  # For heap-allocated values, all non-Copy types need cleanup.
  #
  # This is the ownership-aware version of needs_cleanup?. It answers:
  # "if this variable is :live at scope exit, must we emit a defer?"
  sig { params(allocator: Symbol, schema_lookup: T.nilable(SchemaLookup)).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def needs_explicit_cleanup?(allocator, schema_lookup = nil)
    return false if node_reference?
    return false if primitive? || void? || any?
    return false if implicitly_copyable?(schema_lookup)
    # Copy types never need cleanup regardless of allocator
    return false if string? && !heap? && allocator == :frame

    # Heap-allocated non-Copy: always needs cleanup
    return true if allocator == :heap

    # Frame-allocated: only if type has heap internals that arena rewind won't handle
    return true if any_rc? || link?       # RC refcount is heap-managed
    return true if any_sync?              # mutex is OS resource
    return true if resource?              # file handle, socket, etc.
    # Frame collections/maps: backing buffer uses frame allocator, arena rewind handles it.
    # UNLESS elements have heap internals (e.g. list of RC pointers).
    if collection?
      return elem_has_heap_internals?(schema_lookup)
    end

    # Frame structs/unions: check fields recursively
    if schema_lookup
      lookup = schema_lookup
      schema = lookup.call(resolved)
      if schema
        if schema.is_a?(Schemas::UnionSchema)
          return schema.variants.values.any? { |vt| Type.variant_has_heap?(vt) }
        elsif schema.is_a?(Schemas::StructSchema)
          return schema_struct_has_heap_internals?(schema)
        end
      end
    end

    false
  end

  # Check if collection elements have heap internals (RC, resource, etc.)
  sig { params(schema_lookup: T.nilable(SchemaLookup)).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def elem_has_heap_internals?(schema_lookup = nil)
    et = element_type
    return false unless et
    return true if et.any_rc? || et.link? || et.any_sync? || et.resource?
    # Check struct/union element types via schema
    if schema_lookup
      lookup = schema_lookup
      schema = lookup.call(et.resolved)
      if schema
        if schema.is_a?(Schemas::UnionSchema)
          return schema.variants.values.any? { |vt| Type.variant_has_heap?(vt) }
        elsif schema.is_a?(Schemas::StructSchema)
          return schema_struct_any?(schema) { |ft| ft.any_rc? || ft.link? || ft.any_sync? || ft.resource? }
        end
      end
    end
    false
  end

  # Determine the allocator needed for cleanup of this type.
  # Returns :heap or :frame. Centralizes the type-specific logic that
  # was previously inline in annotator.rb's set_cleanup_alloc!.
  #
  # A21: tense_observable? is in this list because the wrapper struct
  # is unconditionally heap-allocated by lower_range_fold_observable
  # (`*ObservableTerminal(Inner)` produced by `WrapperT.new(rt.heapAlloc())
  # catch unreachable`). Without this branch, observable bindings fell
  # through to :frame and mir_lowering's lower_var_decl downgrade guard
  # had to use needs_heap_backing? as a parallel signal to preserve the
  # :heap entry. With it here, the entry-derived allocator path is
  # self-consistent and the needs_heap_backing? guard becomes a defense-
  # in-depth backstop rather than the load-bearing path.
  sig { params(schema_lookup: T.nilable(SchemaLookup)).returns(Symbol) }
  # ruby-to-clear: effects reentrant
  def cleanup_allocator(schema_lookup = nil)
    return :heap if heap_cleanup_allocator?
    if schema_lookup
      lookup = schema_lookup
      schema = lookup.call(resolved)
      if schema
        if schema.is_a?(Schemas::StructSchema)
          return :heap if schema_struct_any?(schema) { |t| t.link? || t.any_rc? || t.string? }
        elsif schema.is_a?(Schemas::UnionSchema)
          return :heap if schema.variants.values.any? { |vt| Type.variant_has_heap?(vt) }
        end
      end
    end
    :frame
  end

  sig { returns(T::Boolean) }
  def heap_cleanup_allocator?
    heap? || map? || any_rc? || any_sync? || resource? || sharded? ||
      striped? || link? || tense_observable?
  end

  sig { returns(T.nilable(Type)) }
  def plain_return_payload_type
    return nil unless error_union?

    error_union_payload_with_outer_capabilities
  end

  # Check if a union variant type contains heap-allocated data (collections, maps, dynamic arrays).
  # Used to determine if a union needs cleanup.
  sig { params(vt: Schemas::UnionSchema::VariantValue).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def self.variant_has_heap?(vt)
    return false unless vt
    if vt.is_a?(Schemas::InlineStructVariant)
      fields = vt.fields
      keys = fields.keys
      i = T.let(0, Integer)
      while i < keys.length
        field_type = Type.from_input(fields.fetch(keys.fetch(i)))
        return true if field_type.heap_ptr? && !field_type.symbol?
        i += 1
      end
      return false
    end
    variant_type = Type.from_variant_input(vt)
    return variant_type.heap_ptr? && !variant_type.symbol?

    false
  end

  # Safely extract a normalized Type from any AST/MIR node or raw type value.
  # Returns nil if no type_info is available or conversion fails.
  # Replaces the repeated inline pattern:
  #   ti = node.full_type rescue nil
  #   ti = Type.new(ti) if ti && !ti.is_a?(Type)
  # ruby-to-clear: skip
  # ruby-to-clear: skip
  sig { params(node: TypeNodeInput).returns(T.nilable(Type)) }
  def self.from_node(node)
    return nil unless node
    t = node.respond_to?(:full_type) ? T.unsafe(node).full_type : node
    return nil unless t
    return t if t.is_a?(Type)
    return nil unless t.is_a?(Symbol) || t.is_a?(String) || t.is_a?(FunctionType) || Type.function_signature_like?(t)

    Type.new(t)
  end

  # ruby-to-clear: skip
  sig { params(node: TypeNodeInput, context: String).returns(Type) }
  def self.from_node!(node, context: "post-annotation MIR")
    t = from_node(node)
    raise "#{context}: missing type info for #{node.class}" unless t
    raise "#{context}: unresolved type info for #{node.class}" if t.untyped?
    t
  end

  # Returns the Zig type string representation of this type.
  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  # ruby-to-clear: effects reentrant
  def zig_type(is_param: false, is_field: false)
    require_relative "../backends/type_zig_renderer" unless defined?(TypeZigRenderer)
    TypeZigRenderer.render(self, is_param: is_param, is_field: is_field)
  end

  # Zig permits inferred error sets (`!T`) only in function return positions.
  # Recursive type positions—Tuple fields, collection elements, map values,
  # and promise payloads—must name a concrete error set.
  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  # ruby-to-clear: effects reentrant
  def nested_zig_type(is_param: false, is_field: false)
    require_relative "../backends/type_zig_renderer" unless defined?(TypeZigRenderer)
    TypeZigRenderer.render(self, is_param: is_param, is_field: is_field, nested: true)
  end

  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  # ruby-to-clear: effects reentrant
  def render_zig_type(is_param: false, is_field: false)
    compute_zig_type(is_param: is_param, is_field: is_field)
  end

  # Determines the appropriate storage location based on type characteristics and size.
  # Returns :stack for small primitives, :frame for medium-sized data, :heap for large/dynamic.
  #
  # @param size [Integer] The slot size of the type (from slot_size method)
  # @param current_storage [Symbol, nil] The current storage if already set
  # @return [Symbol] One of :stack, :frame, or :heap
  #
  sig { params(size: Integer, current_storage: T.nilable(Symbol)).returns(Symbol) }
  def finalize_storage(size, current_storage = nil)
    # Frozen (compact buffer) always stays frozen
    return :frozen if frozen? || current_storage == :frozen

    # Multiowned (Rc) always stays multiowned
    return :multiowned if multiowned? || current_storage == :multiowned

    # Shared (Arc) always stays shared
    return :shared if shared? || current_storage == :shared

    # Link (WeakRc/WeakArc) always stays link
    return :link if link? || current_storage == :link

    # Sync (locked) types need a stable heap address
    return :heap if any_sync? || current_storage == :heap && any_sync?

    # Rodata (string literals) always stay rodata — never heap/frame allocated
    return :rodata if current_storage == :rodata || rodata?

    # If already heap, keep it heap
    return :heap if current_storage == :heap || heap?

    # Frame-arena containers: explicit @list (non-sharded, non-sync)
    return :frame if list_collection?

    # Primitives stay on stack
    return :stack if primitive? && !requires_move?

    # Types that require moves need frame or heap based on size
    if requires_move?
      if current_storage.nil? || current_storage == :stack
        return size > 128 ? :frame : :stack
      end
    end

    # Default to current or stack
    current_storage || :stack
  end

  private

  sig { params(field_type: TypeInput, schema: T.any(Schemas::StructSchema, Schemas::ResourceSchema)).returns(Type) }
  # ruby-to-clear: effects reentrant
  def substitute_generic_schema_field_type(field_type, schema)
    normalized_field_type = Type.from_input(field_type)
    return normalized_field_type unless generic_instance?
    params = T.let([], T::Array[Symbol])
    if schema.is_a?(Schemas::StructSchema)
      params = schema.type_params
    elsif schema.is_a?(Schemas::ResourceSchema)
      params = schema.type_params
    end
    args = generic_args
    return normalized_field_type if params.empty? || args.empty?

    subst = T.let({}, T::Hash[Symbol, Type])
    limit = params.length < args.length ? params.length : args.length
    i = T.let(0, Integer)
    while i < limit
      param = params.fetch(i)
      arg = args.fetch(i)
      subst[param.to_sym] = Type.new(arg)
      i += 1
    end
    subst[normalized_field_type.resolved] || normalized_field_type
  end

  sig { params(schema: Schemas::UnionSchema, schema_lookup: SchemaLookup, seen: T::Set[String]).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def schema_union_needs_promotion?(schema, schema_lookup, seen)
    values = schema.variants.values
    i = T.let(0, Integer)
    while i < values.length
      vt = values.fetch(i)
      unless vt
        i += 1
        next
      end
      if vt.is_a?(Schemas::InlineStructVariant)
        return true if inline_variant_needs_promotion?(vt, schema_lookup, seen)
      else
        return true if Type.from_variant_input(vt).needs_promotion?(schema_lookup, seen)
      end
      i += 1
    end
    false
  end

  sig { params(variant: Schemas::InlineStructVariant, schema_lookup: SchemaLookup, seen: T::Set[String]).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def inline_variant_needs_promotion?(variant, schema_lookup, seen)
    values = variant.fields.values
    i = T.let(0, Integer)
    while i < values.length
      field_type = Type.from_input(values.fetch(i))
      return true if field_type.needs_promotion?(schema_lookup, seen)

      i += 1
    end
    false
  end

  sig { params(schema: Schemas::StructSchema, schema_lookup: SchemaLookup, seen: T::Set[String]).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def schema_struct_needs_promotion?(schema, schema_lookup, seen)
    values = schema.fields.values
    i = T.let(0, Integer)
    while i < values.length
      field = values.fetch(i)
      t = field.type
      if field.borrowed
        t = Type.new(t)
        t.mark_borrowed_reference!
      end
      return true if substitute_generic_schema_field_type(t, schema).needs_promotion?(schema_lookup, seen)
      i += 1
    end
    false
  end

  sig { params(schema: Schemas::UnionSchema, schema_lookup: SchemaLookup, seen: T::Set[String]).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def schema_union_needs_cleanup?(schema, schema_lookup, seen)
    values = schema.variants.values
    i = T.let(0, Integer)
    while i < values.length
      vt = values.fetch(i)
      unless vt
        i += 1
        next
      end
      if vt.is_a?(Schemas::InlineStructVariant)
        return true if inline_variant_needs_cleanup?(vt, schema_lookup, seen)
      else
        return true if Type.from_variant_input(vt).needs_cleanup?(schema_lookup, seen)
      end
      i += 1
    end
    false
  end

  sig { params(variant: Schemas::InlineStructVariant, schema_lookup: SchemaLookup, seen: T::Set[String]).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def inline_variant_needs_cleanup?(variant, schema_lookup, seen)
    values = variant.fields.values
    i = T.let(0, Integer)
    while i < values.length
      field_type = Type.from_input(values.fetch(i))
      return true if field_type.needs_cleanup?(schema_lookup, seen)

      i += 1
    end
    false
  end

  sig { params(schema: Schemas::StructSchema, schema_lookup: SchemaLookup, seen: T::Set[String]).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def schema_struct_needs_cleanup?(schema, schema_lookup, seen)
    fields = schema.fields
    values = fields.values
    i = T.let(0, Integer)
    while i < values.length
      field = values.fetch(i)
      t = field.type
      if field.borrowed
        t = Type.new(t)
        t.mark_borrowed_reference!
      end
      return true if substitute_generic_schema_field_type(t, schema).needs_cleanup?(schema_lookup, seen)
      i += 1
    end
    false
  end

  sig { params(schema: Schemas::StructSchema).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def schema_struct_has_heap_internals?(schema)
    fields = schema.fields
    values = fields.values
    i = T.let(0, Integer)
    while i < values.length
      field = values.fetch(i)
      t = field.type
      if field.borrowed
        t = Type.new(t)
        t.mark_borrowed_reference!
      end
      ft = substitute_generic_schema_field_type(t, schema)
      return true if ft.any_rc? || ft.link? || ft.any_sync? || ft.resource?
      i += 1
    end
    false
  end

  # True if any struct field in schema satisfies the block (block receives Type).
  # Skips metadata (Symbol) keys; unwraps {:type => T} field hashes.
  sig { params(schema: Schemas::StructSchema, blk: T.proc.params(t: Type).returns(T::Boolean)).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def schema_struct_any?(schema, &blk)
    values = schema.fields.values
    i = T.let(0, Integer)
    while i < values.length
      v = values.fetch(i)
      t = Type.from_input(v.type)
      if v.borrowed
        t = Type.copy_type(t)
        t.mark_borrowed_reference!
      end
      return true if blk.call(t)
      i += 1
    end
    false
  end

  # True if any non-Hash union variant in schema satisfies the block (block receives Type).
  # Skips nil and Hash variants (inline_struct/indirect); caller handles those via
  # Type.variant_has_heap? when needed.
  sig { params(schema: Schemas::UnionSchema, blk: T.proc.params(t: Type).returns(T::Boolean)).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def schema_union_any?(schema, &blk)
    values = schema.variants.values
    i = T.let(0, Integer)
    while i < values.length
      vt = values.fetch(i)
      unless vt
        i += 1
        next
      end

      if vt.is_a?(Schemas::InlineStructVariant)
        i += 1
        next
      else
        return true if blk.call(Type.from_variant_input(vt))
      end
      i += 1
    end
    false
  end

  # Structural match for function/lambda types. Called by accepts? when self.fn_type?.
  sig { params(other_type: Type).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def accepts_fn_type?(other_type)
    return true if other_type.any?
    return false unless other_type.fn_type?
    self_raw = T.must(function_type)
    other_raw = T.must(other_type.function_type)

    return false unless self_raw.abi == other_raw.abi || (self_raw.abi == :c && other_raw.abi == :clear)

    self_params  = self_raw.params
    other_params = other_raw.params
    return false unless self_params.length == other_params.length

    # raw / other_raw are FunctionType (fn_type? gate); their return_type is non-nil.
    return false unless self_raw.return_type.accepts?(other_raw.return_type)

    i = T.let(0, Integer)
    while i < self_params.length
      sp = self_params.fetch(i)
      op = other_params.fetch(i)
      sp_t = sp.type
      op_t = op.type
      return false unless op_t.accepts?(sp_t)
      i += 1
    end

    # Reentrant constraint: a plain EFFECTS REENTRANT function cannot be passed
    # to a function type that rejects plain reentrant callbacks.
    return false if other_raw.reentrant && !self_raw.reentrant

    true
  end

  # Promise/Stream coercion. Called by accepts? when self.future?.
  sig { params(other_type: Type).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def accepts_future?(other_type)
    # ~T[]@list accepts [] or another ~T[]
    return true if promise_list? && (other_type.empty_list? || (other_type.future? && other_type.tense_type.dynamic?))
    return false unless other_type.future?

    # A BG STREAM is inferred in the canonical finite form `[~]T` before
    # its declaration chooses a legacy open or infinite runtime wrapper.
    # This is a producer-shape coercion only; bounded declarations remain
    # exact because their cardinality is a value-level contract.
    if other_type.canonical_stream? && other_type.dynamic_stream?
      other_element = other_type.tense_type.element_type
      if open_stream?
        self_element = open_stream_element_type
        return self_element.accepts?(other_element) if self_element && other_element
      elsif inf_stream?
        self_element = inf_stream_element_type
        return self_element.accepts?(other_element) if self_element && other_element
      end
    end

    if dynamic_stream? && other_type.dynamic_stream?
      se = T.let(tense_type.element_type, T.nilable(Type))
      oe = T.let(other_type.tense_type.element_type, T.nilable(Type))
      unless se.nil? || oe.nil?
        return se.accepts?(oe)
      end
    end
    if open_stream? && other_type.open_stream?
      se = T.let(open_stream_element_type, T.nilable(Type))
      oe = T.let(other_type.open_stream_element_type, T.nilable(Type))
      unless se.nil? || oe.nil?
        return se.accepts?(oe)
      end
    end
    # ~T[INF] accepts ~?T[] and vice versa: BG STREAM infers open-stream syntax,
    # declared type picks the runtime wrapper. Match on element type only.
    if (inf_stream? && other_type.open_stream?) || (open_stream? && other_type.inf_stream?)
      se = T.let(nil, T.nilable(Type))
      oe = T.let(nil, T.nilable(Type))
      if inf_stream?
        se = inf_stream_element_type
      else
        se = open_stream_element_type
      end
      if other_type.inf_stream?
        oe = other_type.inf_stream_element_type
      else
        oe = other_type.open_stream_element_type
      end
      unless se.nil? || oe.nil?
        return se.accepts?(oe)
      end
    end

    tense_type.accepts?(other_type.tense_type)
  end

  # Array coercion. Called by accepts? when self.array?.
  sig { params(other_type: Type).returns(T::Boolean) }
  # ruby-to-clear: effects reentrant
  def accepts_array?(other_type)
    # Any[] accepts stream types for append/list intrinsic matching
    if T.must(element_type).any? && other_type.future?
      return true if other_type.dynamic_stream? || other_type.promise_list? ||
                     other_type.bounded_stream? || other_type.open_stream? ||
                     other_type.inf_stream?
    end
    return false unless other_type.array?
    return true  if other_type.empty_list?
    return false unless T.must(element_type).accepts?(T.must(other_type.element_type))
    return true  if dynamic? && other_type.fixed?
    if fixed? && other_type.fixed?
      other_capacity = other_type.capacity
      self_capacity = capacity
      return Type.array_capacity_integer(other_capacity) <= Type.array_capacity_integer(self_capacity)
    end
    dynamic? && other_type.dynamic?
  end

  sig { params(raw_input: RawParseInput, auto: T::Boolean).void }
  def parse_raw_input!(raw_input, auto: false)
    if raw_input.is_a?(FunctionType)
      parse_function_type_input!(raw_input, auto: auto)
      return
    end

    if raw_input.is_a?(Symbol)
      parse_raw_string!(raw_input.to_s, auto: auto)
    elsif raw_input.is_a?(String)
      parse_raw_string!(raw_input, auto: auto)
    end
  end

  sig { params(raw_input: FunctionType, auto: T::Boolean).void }
  def parse_function_type_input!(raw_input, auto: false)
    @shape = TypeShape.from_raw(raw: raw_input, auto: auto)
    @capabilities = TypeCapabilities.new(ownership: :affine)
  end

  sig { params(expression: TypeExpression, auto: T::Boolean).void }
  def parse_expression_input!(expression, auto: false)
    @shape = TypeShape.from_raw(raw: :Any, auto: auto, expression: expression)
    @capabilities = TypeExpressionTree.root_capabilities(expression)
  end

  sig { params(raw_str: String, auto: T::Boolean).void }
  def parse_raw_string!(raw_str, auto: false)
    normalized_str = T.let(raw_str, String)
    if raw_str == "Number"
      normalized_str = "Float64"
    elsif raw_str.include?("Number")
      normalized_str = raw_str.gsub(/\bNumber\b/, 'Float64')
    end

    suffix = T.let(TypeCapabilitySuffix.new(base: normalized_str, ownership: nil, sync: nil), TypeCapabilitySuffix)
    capability_marker = normalized_str.rindex("@")
    unless normalized_str.include?("<") || capability_marker.nil? || capability_marker.zero?
      suffix = Type.strip_capability_suffix_from(normalized_str)
    end
    @shape = TypeShape.from_core(suffix.base, auto: auto)
    if suffix.ownership || suffix.sync
      @capabilities = TypeCapabilities.new(ownership: :affine)
      suffix_ownership = T.let(suffix.ownership, T.nilable(Symbol))
      suffix_ownership = :affine if suffix_ownership.nil?
      apply_capabilities!(
        ownership: Type.capability_symbol_or_unset(suffix_ownership),
        sync: Type.capability_symbol_or_unset(suffix.sync),
        collection: nil
      )
    else
      @capabilities = TypeCapabilities.new(ownership: :affine)
    end
  end

  sig { returns(String) }
  # ruby-to-clear: effects reentrant
  def semantic_shape_key
    return function_type_key if fn_type?

    shape.semantic_key
  end

  sig { returns(String) }
  # ruby-to-clear: effects reentrant
  def function_type_key
    sig = T.must(function_type)
    param_keys = sig.params.map { |param| param.type.semantic_type_key }
    params_key = param_keys.join(",")

    "fn(#{params_key})->#{sig.return_type.semantic_type_key};reentrant=#{sig.reentrant};abi=#{sig.abi}"
  end

  sig { params(str: String).returns(TypeCapabilitySuffix) }
  def self.strip_capability_suffix_from(str)
    unless str.include?("@")
      return TypeCapabilitySuffix.new(base: str, ownership: nil, sync: nil)
    end

    parts = str.gsub(/\s+/, "").split("@")
    base = parts.fetch(0, "")
    caps = parts.drop(1)
    ownership = T.let(nil, T.nilable(Symbol))
    sync = T.let(nil, T.nilable(Symbol))
    caps.flat_map { |cap| cap.split(":") }.each do |cap|
      case cap
      when "shared"
        ownership = ownership == :node ? :shared_node : :shared
      when "node"
        ownership = ownership == :shared ? :shared_node : :node
      when "multiOwned", "multiowned" then ownership = :multiowned
      when "link" then ownership = :link
      when "split" then ownership = :split
      when "frozen" then ownership = :frozen
      when "locked" then sync = :locked
      when "writeLocked", "writelocked" then sync = :write_locked
      when "versioned" then sync = :versioned
      when "atomic" then sync = :atomic
      when "local" then sync = :local
      when "raw" then sync = :raw
      when "symbol" then sync = :symbol
      when "alwaysMutable", "alwaysmutable" then sync = :always_mutable
      end
    end

    TypeCapabilitySuffix.new(base: base, ownership: ownership, sync: sync)
  end

  sig { params(str: String).returns(TypeCapabilitySuffix) }
  def strip_capability_suffix(str)
    Type.strip_capability_suffix_from(str)
  end

  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  # ruby-to-clear: effects reentrant
  def tense_zig_type(is_param:, is_field:)
    if tense_observable? && !promise_list?
      return "*CheatLib.obs.#{observable_wrapper_zig(tense_type)}"
    end
    if promise_list?
      elem_zig = T.must(tense_type.element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "std.ArrayListUnmanaged(CheatLib.Promise(#{elem_zig}))"
    end
    if canonical_stream?
      expression = T.cast(shape.expression, StreamTypeExpression)
      elem_zig = Type.from_child_expression(expression.item)
        .nested_zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.Stream(#{elem_zig})" if expression.cardinality == :FINITE
      return "CheatLib.InfStream(#{elem_zig})" if expression.cardinality == :INF

      return "CheatLib.BoundedStream(#{elem_zig}, #{expression.cardinality})"
    end
    if bounded_stream?
      elem_zig = T.must(stream_element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.BoundedStream(#{elem_zig}, #{stream_capacity})"
    end
    if dynamic_stream?
      inner_t = T.let(T.must(tense_type.element_type), Type)
      return case inner_t.resolved
             when :Int64 then "CheatLib.IntRange"
             when :Float64 then "CheatLib.Range"
             else
              "CheatLib.Stream(#{inner_t.nested_zig_type(is_param: is_param, is_field: is_field)})"
             end
    end
    if shared_promise?
      return "CheatLib.SharedPromise(#{tense_type.nested_zig_type(is_param: is_param, is_field: is_field)})"
    end
    if split_open_stream?
      elem_zig = T.must(open_stream_element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.SplitStream(#{elem_zig})"
    end
    if open_stream?
      elem_zig = T.must(open_stream_element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.Stream(#{elem_zig})"
    end
    if inf_stream?
      elem_zig = T.must(inf_stream_element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.InfStream(#{elem_zig})"
    end

    "CheatLib.Promise(#{tense_type.nested_zig_type(is_param: is_param, is_field: is_field)})"
  end

  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(T.nilable(String)) }
  # ruby-to-clear: effects reentrant
  def capability_wrapped_zig_type(is_param:, is_field:)
    return nil unless (ownership != :affine || any_sync?) && !(map? && striped? && ownership == :affine)

    inner_zig = capability_inner_zig_type(is_param: is_param, is_field: is_field)

    if atomic_pointer_wrapped?
      return "*#{inner_zig}"
    end

    return "CheatLib.Rc(#{inner_zig})" if ownership == :multiowned
    return "CheatLib.Arc(#{inner_zig})" if ownership == :shared
    return link_zig_type(inner_zig) if ownership == :link

    default_capability_zig_type(inner_zig)
  end

  sig { params(inner_zig: String).returns(String) }
  # ruby-to-clear: effects reentrant
  def link_zig_type(inner_zig)
    link_source == :shared ? "CheatLib.WeakArc(#{inner_zig})" : "CheatLib.WeakRc(#{inner_zig})"
  end

  sig { params(inner_zig: String).returns(T.nilable(String)) }
  # ruby-to-clear: effects reentrant
  def default_capability_zig_type(inner_zig)
    return nil if map? && striped?

    "*#{inner_zig}"
  end

  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  # ruby-to-clear: effects reentrant
  def capability_inner_zig_type(is_param:, is_field:)
    if map? && striped?
      bare = Type.new(resolved)
      bare.apply_capabilities!(
        shard_count: Type.capability_integer_or_unset(shard_count),
        sync: Type.capability_symbol_or_unset(sync),
        ownership: :affine
      )
      return bare.zig_type(is_param: is_param, is_field: is_field)
    end

    inner_zig = if fixed_soa?
      base_zig = T.must(element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      "CheatLib.SoaList(#{base_zig})"
    else
      # A managed dynamic-array field stores an Rc/Arc around the owning
      # ArrayList header, not a borrowed slice.  Field spelling normally uses
      # `[]T`, but applying that rule inside a capability wrapper produces
      # `Rc([]T)` while the initializer correctly creates `Rc(ArrayList(T))`.
      # Function parameters cannot carry capability annotations, so this only
      # changes the managed aggregate payload representation.
      payload_is_field = is_field && !(direct_indexable_collection? && dynamic?)
      bare_data_type.zig_type(is_param: is_param, is_field: payload_is_field)
    end

    inner_zig = "CheatLib.Locked(#{inner_zig})" if locked?
    inner_zig = "CheatLib.RwLocked(#{inner_zig})" if write_locked?
    inner_zig = "CheatLib.RefCell(#{inner_zig})" if sync == :always_mutable
    inner_zig = "CheatLib.Versioned(#{inner_zig})" if versioned?
    if atomic_ptr?
      "CheatLib.AtomicPtr(#{inner_zig})"
    elsif atomic?
      "CheatLib.Atomic(#{inner_zig})"
    else
      inner_zig
    end
  end

  sig { returns(String) }
  # ruby-to-clear: effects reentrant
  def map_zig_type
    val_zig = value_type.nested_zig_type
    if key_type.projection?
      return "CheatLib.MapType(#{key_type.zig_type}, #{val_zig})"
    end
    if striped?
      current_shard_count = T.must(shard_count)
      if numeric_map?
        striped_key_zig = key_type.zig_type
        return "CheatLib.StripedNumericMap(#{striped_key_zig}, #{val_zig}, #{current_shard_count})"
      end
      return "CheatLib.MutexShardedStringMap(#{val_zig}, #{current_shard_count})" if locked?

      return "CheatLib.ShardedStringMap(#{val_zig}, #{current_shard_count})"
    end
    if sharded?
      current_shard_count = T.must(shard_count)
      if numeric_map?
        partitioned_key_zig = key_type.zig_type
        return "CheatLib.PartitionedNumericMap(#{partitioned_key_zig}, #{val_zig}, #{current_shard_count})"
      end
      return "CheatLib.PartitionedStringMap(#{val_zig}, #{current_shard_count})"
    end
    if numeric_map?
      numeric_key_zig = key_type.zig_type
      return "CheatLib.NumericMapType(#{numeric_key_zig}, #{val_zig})"
    end

    "CheatLib.StringMap(#{val_zig})"
  end

  # Computes the Zig type string for this CHEAT type.
  # Handles: error unions, optionals, multiowned (Rc), pointers, arrays, hashmaps, primitives, structs.
  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  # ruby-to-clear: effects reentrant
  def compute_zig_type(is_param: false, is_field: false)
    if projection?
      protocol = projection_protocol
      facts = protocol.nil? || protocol == :Map ? "CheatLib.MapFacts" : "__clearProtocolFacts_#{protocol}"
      return "#{facts}(#{T.must(projection_owner)}).#{T.must(projection_member)}"
    end

    # 0. Handle Tense types:
    #    ~T[N]              -> CheatLib.BoundedStream(T, N)
    #    ~T@shared          -> CheatLib.SharedPromise(T)
    #    ~T@observable      -> *CheatLib.obs.Observable<Terminal>(T)
    #    ~T[]@set:observable -> *CheatLib.obs.ObservableStreamSet(T)
    #    ~T                 -> CheatLib.Promise(T)
    if tense?
      # `~T@observable`: pipeline-terminal observable. Maps to a
      # heap-pointed `Observable<Terminal>(T)` (the per-terminal alias
      # picks the right Inner accumulator: SUM→AtomicSum, COUNT→AtomicCount,
      # DISTINCT→StreamSet, ...). The pointer form is needed because
      # the accumulator outlives the producer fiber and is read across
      # fibers via WITH VIEW. Order matters: this branch must come
      # before the generic shape predicates so a `~Int64@observable`
      # binding doesn't fall through to BoundedStream / Promise.
      #
      return tense_zig_type(is_param: is_param, is_field: is_field)
    end

    # A node reference is always a four-byte nullable generational handle.
    # Optionality is encoded by NodeRef's zero sentinel instead of Zig's
    # optional tag, keeping ?T@node fields compact too.
    # 1. Handle Error Union: !T -> !zig_type. Recursive positions call
    # nested_zig_type, which supplies a concrete `anyerror` set for Zig.
    if error_union?
      inner_zig = error_union_payload_with_outer_capabilities.zig_type(is_param: is_param, is_field: is_field)
      return "!#{inner_zig}"
    end

    # 2. Handle Optional: ?T -> ?zig_type
    if optional?
      inner = T.must(wrapped_type)
      return inner.zig_type(is_param: is_param, is_field: is_field) if inner.node?
      inner_zig = T.must(wrapped_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "?#{inner_zig}"
    end


    if node?
      return "CheatLib.NodeRef(#{Type.zig_type_name_for(resolved)})"
    end

    # @boxed is a heap-pinned cell boxed by a single HeapCreate, so its
    # Zig type must be exactly one pointer level around the bare pointee for
    # every type uniformly (the String/slice path below otherwise drops it).
    if plain_indirect_value?
      pointee = Type.copy_type(self)
      pointee.strip_layout!
      pointee.mark_stack_value!
      return "*#{pointee.zig_type(is_param: is_param, is_field: is_field)}"
    end

    # 2c. Function type: FN(T, ...) -> R  =>  *const fn(*Runtime, T, ...) anyerror!R
    if fn_type?
      fn_raw = T.must(function_type)
      param_types_zig = T.let([], T::Array[String])
      i = T.let(0, Integer)
      while i < fn_raw.params.length
        p = fn_raw.params.fetch(i)
        t = p.type
        if t.is_a?(Type)
          param_types_zig << t.zig_type(is_param: true)
        else
          param_types_zig << Type.new(t).zig_type(is_param: true)
        end
        i += 1
      end
      ret_zig = fn_raw.return_type.zig_type
      if fn_raw.abi == :c
        return "*const fn(#{param_types_zig.join(', ')}) callconv(.c) #{ret_zig}"
      end
      all_params = ["*Runtime"] + param_types_zig
      ret_str = ZigType.new(ret_zig).concrete_fallible_return_type
      return "*const fn(#{all_params.join(', ')}) #{ret_str}"
    end

    # 2b. Derive Zig type from ownership × sync dimensions
    # Only apply capability wrapping when there's an actual capability set.
    # Sharded maps with sync use StripedMap (sync built into the map type) —
    # skip Locked/RwLocked wrapping but still apply Arc/Rc if @shared/@multiowned.
    wrapped_zig = capability_wrapped_zig_type(is_param: is_param, is_field: is_field)
    return wrapped_zig if wrapped_zig

    # 3. Handle Special primitive mapping
    # String and Byte[N] (fixed-size string literals) both map to []const u8.
    # Byte[N] is the inferred type for string literals; their contents are always const.
    # Strings are already fat pointers (slice = ptr + len); heap vs frame provenance
    # only affects where the backing bytes live, not the Zig type.
    if c_string?
      return "[*:0]const u8"
    end
    if c_array_view?
      return "[*]const #{T.must(element_type).nested_zig_type(is_param: true)}"
    end
    if target_size?
      return signed_integer? ? "isize" : "usize"
    end
    if resolved == :String || string?
      return "[]const u8"
    end

    # 3b. Handle rectangular ranks before collection compatibility flags.
    # A rank may be initialized by List[], but that value-level construction
    # detail must never change its flat Grid/array representation.
    if rank?
      base_zig = T.must(element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      if dynamic_rank?
        return "CheatLib.Grid(#{base_zig}, #{rank})"
      end

      return "[#{T.must(capacity)}]#{base_zig}"
    end

    # 3c. Handle Pool / ShardedPool collection
    if pool?
      base_zig = T.must(element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      if soa?
        return "CheatLib.SoaPool(#{base_zig})"
      end
      if sharded?
        current_shard_count = T.must(shard_count)
        return "CheatLib.ShardedPool(#{base_zig}, #{current_shard_count})"
      end
      return "CheatLib.Pool(#{base_zig})"
    end

    # 3d. Handle @set collection
    if set_collection?
      base_zig = T.must(element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.Set(#{base_zig})"
    end

    # 3e. Handle @list / ShardedList / SoaList collection
    if list_collection?
      base_zig = T.must(element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      if soa?
        return "CheatLib.SoaList(#{base_zig})"
      end
      if sharded?
        current_shard_count = T.must(shard_count)
        return "CheatLib.ShardedList(#{base_zig}, #{current_shard_count})"
      end
      return "std.ArrayListUnmanaged(#{base_zig})"
    end

    # 3f. Handle fixed SOA arrays (T[N]@soa — no @pool/@list wrapper)
    if fixed_soa?
      base_zig = T.must(element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.SoaList(#{base_zig})"
    end

    # 4. Handle one-dimensional arrays recursively
    #    Dynamic arrays use ArrayListUnmanaged only for local variables to support growth.
    #    Struct fields and function parameters use slices.
    if array?
      base_zig = T.must(element_type).nested_zig_type(is_param: is_param, is_field: is_field)
      array_capacity_value = capacity
      if dynamic? && !is_param && !is_field
        # Dynamic arrays (ArrayListUnmanaged) are always value-typed locals.
        # The list header is a struct value; the backing store lives on the heap internally.
        # heap? provenance means the backing store is heap-managed, NOT that the header
        # itself is a pointer. Never apply *-prefix here.
        return "std.ArrayListUnmanaged(#{base_zig})"
      elsif Type.integer_array_capacity?(array_capacity_value)
        current_capacity = Type.array_capacity_integer(array_capacity_value)
        zig = "[#{Type.integer_string(current_capacity)}]#{base_zig}"
      else
        zig = "[]#{base_zig}"
      end
      return zig
    end

    # 5. Handle HashMaps
    #    HashMap<V>                        → std.StringHashMapUnmanaged(V)
    #    HashMap<K, V>                     → CheatLib.NumericMapType(K, V)
    #    HashMap<V>@sharded(N)             → CheatLib.PartitionedStringMap(V, N)     (shared-nothing)
    #    HashMap<V>@sharded(N):locked      → CheatLib.MutexShardedStringMap(V, N)    (Mutex per shard)
    #    HashMap<V>@sharded(N):writeLocked → CheatLib.ShardedStringMap(V, N)         (RwLock per shard)
    if map?
      return map_zig_type
    end

    # 5b. Handle Generic Struct Instances
    #    Pair<Number> -> Pair(f64),  Map<String,Number> -> Map([]const u8, f64)
    #    Id<User>     -> u64        (compiler-intrinsic handle, type param is for CLEAR safety only)
    generic_zig = generic_instance_zig_type
    return generic_zig if generic_zig

    # 6. Map primitives and builtins to Zig types; user types pass through.
    Type.zig_type_name_for(resolved)
  end

  sig { returns(T.nilable(String)) }
  # ruby-to-clear: effects reentrant
  def generic_instance_zig_type
    return nil unless generic_instance?
    return "u64" if id_handle?

    args_zig_parts = T.let([], T::Array[String])
    args = generic_args
    i = T.let(0, Integer)
    while i < args.length
      arg_type = args.fetch(i)
      args_zig_parts << arg_type.nested_zig_type
      i += 1
    end
    args_zig = args_zig_parts.join(", ")
    return "struct { #{args_zig} }" if tuple?
    return "CheatLib.StreamStep(#{args_zig})" if generic_base == :StreamStep

    base_name = Type.symbol_or_default(shape.generic_base_raw, resolved)
    "#{base_name}(#{args_zig})"
  end

  private :apply_placement!,
    :atomic_pointer_wrapped?,
    :elem_has_heap_internals?,
    :fixed_array_slot_size,
    :generic_instance_zig_type,
    :heap_cleanup_allocator?,
    :non_string_array_needs_cleanup?,
    :plain_indirect_value?,
    :scalar_slot?,
    :sync_requires_heap_provenance?
end

# Result record for binary-operation type resolution. Keep this typed: the
# self-hosted Type unit must preserve the distinction between an optional
# semantic Type, optional coercion/storage symbols, and an optional diagnostic.
class BinaryOpResult < T::Struct
  const :type, T.nilable(Type), default: nil
  const :left_coercion, T.nilable(Symbol), default: nil
  const :right_coercion, T.nilable(Symbol), default: nil
  const :storage, T.nilable(Symbol), default: nil
  const :error, T.nilable(String), default: nil
end

# ==========================================
# TYPE CHECKING & AUTOCAST LOGIC
# ==========================================
module TypeHelper
    extend T::Sig

  # Coerce input to Type object if needed
  sig { params(input: T.nilable(T.any(Symbol, Type))).returns(Type) }
  def to_type(input)
    return Type.new(:Any) if input.nil?
    value = input

    return Type.copy_type(value) if value.is_a?(Type)
    return Type.new(value) if value.is_a?(Symbol)

    Type.new(:Any)
  end

  sig { params(source_type: T.nilable(T.any(Symbol, Type)), target_type: Type::TypeInput).returns(T::Boolean) }
  def is_safe_autocast?(source_type, target_type)
    target = Type.from_input(target_type)
    return target.accepts?(Type.new(:Any)) if source_type.nil?
    return target.accepts?(Type.copy_type(source_type)) if source_type.is_a?(Type)
    return target.accepts?(Type.new(source_type)) if source_type.is_a?(Symbol)

    target.accepts?(Type.new(:Any))
  end

end

class Type
  sig { returns(T.nilable(BasicObject)) }
  # ruby-to-clear: skip
  def function_signature
    ft = function_type
    return nil unless ft

    ft.source_signature
  end

  # ruby-to-clear: skip
  sig { params(signature: BasicObject).returns(Type) }
  def self.from_function_signature(signature)
    raw = T.unsafe(signature)
    param_types = T.let([], T::Array[Type])
    raw.params.each do |param|
      param_type = param.type
      param_types << (param_type.is_a?(Type) ? param_type : Type.new(param_type))
    end
    return_type = raw.return_type
    function_type_from_parts(
      param_types,
      return_type.is_a?(Type) ? return_type : Type.new(return_type),
      raw.reentrant,
      signature
    )
  end
end
