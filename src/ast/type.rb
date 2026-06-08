# typed: strict
require "sorbet-runtime"
require_relative "lexer"
require_relative "../backends/zig_type"

# Result struct for binary operation type resolution
BinaryOpResult = Struct.new(:type, :left_coercion, :right_coercion, :storage, :error, keyword_init: true)

class TypeCapabilitySuffix < T::Struct
  const :base, String
  const :ownership, T.nilable(Symbol)
  const :sync, T.nilable(Symbol)
end

class TypeCapabilityUnset < T::Struct
end

class TypeCapabilities < T::Struct
  extend T::Sig

  UNSET = T.let(TypeCapabilityUnset.new.freeze, TypeCapabilityUnset)
  MaybeSymbol = T.type_alias { T.any(TypeCapabilityUnset, Symbol, NilClass) }
  MaybeInteger = T.type_alias { T.any(TypeCapabilityUnset, Integer, NilClass) }
  MaybeBoolean = T.type_alias { T.any(TypeCapabilityUnset, T::Boolean) }
  MaybeObject = T.type_alias { T.any(TypeCapabilityUnset, Object, NilClass) }

  const :ownership, T.nilable(Symbol), default: nil
  const :sync, T.nilable(Symbol), default: nil
  const :layout, T.nilable(Symbol), default: nil
  const :lock_rank, T.nilable(Integer), default: nil
  const :collection, T.nilable(Symbol), default: nil
  const :shard_count, T.nilable(Integer), default: nil
  const :soa, T::Boolean, default: false
  const :elem_ownership, T.nilable(Symbol), default: nil
  const :elem_sync, T.nilable(Symbol), default: nil
  const :link_source, T.nilable(Symbol), default: nil
  const :observable, T::Boolean, default: false
  const :observable_terminal, T.nilable(Symbol), default: nil
  const :observable_token, T.nilable(Object), default: nil
  const :polymorphic_shared, T::Boolean, default: false

  sig { returns(TypeCapabilities) }
  def copy
    with
  end

  sig do
    params(
      ownership: MaybeSymbol,
      sync: MaybeSymbol,
      layout: MaybeSymbol,
      lock_rank: MaybeInteger,
      collection: MaybeSymbol,
      shard_count: MaybeInteger,
      soa: MaybeBoolean,
      elem_ownership: MaybeSymbol,
      elem_sync: MaybeSymbol,
      link_source: MaybeSymbol,
      observable: MaybeBoolean,
      observable_terminal: MaybeSymbol,
      observable_token: MaybeObject,
      polymorphic_shared: MaybeBoolean
    ).returns(TypeCapabilities)
  end
  def with(
    ownership: UNSET,
    sync: UNSET,
    layout: UNSET,
    lock_rank: UNSET,
    collection: UNSET,
    shard_count: UNSET,
    soa: UNSET,
    elem_ownership: UNSET,
    elem_sync: UNSET,
    link_source: UNSET,
    observable: UNSET,
    observable_terminal: UNSET,
    observable_token: UNSET,
    polymorphic_shared: UNSET
  )
    next_ownership = T.let(ownership.equal?(UNSET) ? self.ownership : T.cast(ownership, T.nilable(Symbol)), T.nilable(Symbol))
    next_sync = T.let(sync.equal?(UNSET) ? self.sync : T.cast(sync, T.nilable(Symbol)), T.nilable(Symbol))
    next_layout = T.let(layout.equal?(UNSET) ? self.layout : T.cast(layout, T.nilable(Symbol)), T.nilable(Symbol))
    next_lock_rank = T.let(lock_rank.equal?(UNSET) ? self.lock_rank : T.cast(lock_rank, T.nilable(Integer)), T.nilable(Integer))
    next_collection = T.let(collection.equal?(UNSET) ? self.collection : T.cast(collection, T.nilable(Symbol)), T.nilable(Symbol))
    next_shard_count = T.let(shard_count.equal?(UNSET) ? self.shard_count : T.cast(shard_count, T.nilable(Integer)), T.nilable(Integer))
    next_soa = T.let(soa.equal?(UNSET) ? self.soa : T.cast(soa, T::Boolean), T::Boolean)
    next_elem_ownership = T.let(elem_ownership.equal?(UNSET) ? self.elem_ownership : T.cast(elem_ownership, T.nilable(Symbol)), T.nilable(Symbol))
    next_elem_sync = T.let(elem_sync.equal?(UNSET) ? self.elem_sync : T.cast(elem_sync, T.nilable(Symbol)), T.nilable(Symbol))
    next_link_source = T.let(link_source.equal?(UNSET) ? self.link_source : T.cast(link_source, T.nilable(Symbol)), T.nilable(Symbol))
    next_observable = T.let(observable.equal?(UNSET) ? self.observable : T.cast(observable, T::Boolean), T::Boolean)
    next_observable_terminal = T.let(observable_terminal.equal?(UNSET) ? self.observable_terminal : T.cast(observable_terminal, T.nilable(Symbol)), T.nilable(Symbol))
    next_observable_token = T.let(observable_token.equal?(UNSET) ? self.observable_token : observable_token, T.nilable(Object))
    next_polymorphic_shared = T.let(polymorphic_shared.equal?(UNSET) ? self.polymorphic_shared : T.cast(polymorphic_shared, T::Boolean), T::Boolean)

    TypeCapabilities.new(
      ownership: next_ownership,
      sync: next_sync,
      layout: next_layout,
      lock_rank: next_lock_rank,
      collection: next_collection,
      shard_count: next_shard_count,
      soa: next_soa,
      elem_ownership: next_elem_ownership,
      elem_sync: next_elem_sync,
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
      sync: nil,
      layout: nil,
      elem_ownership: nil,
      elem_sync: nil
    )
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

class TypeShape < T::Struct
  extend T::Sig

  ArrayCapacity = T.type_alias { T.nilable(T.any(Integer, Symbol)) }

  const :raw, Object
  const :array, T::Boolean, default: false
  const :map, T::Boolean, default: false
  const :optional, T::Boolean, default: false
  const :tense, T::Boolean, default: false
  const :auto, T::Boolean, default: false
  const :error_union, T::Boolean, default: false
  const :generic_instance, T::Boolean, default: false
  const :capacity, ArrayCapacity, default: nil
  const :payload_type_raw, T.nilable(Symbol), default: nil
  const :wrapped_type_raw, T.nilable(Symbol), default: nil
  const :element_type_raw, T.nilable(Symbol), default: nil
  const :key_type_raw, T.nilable(Symbol), default: nil
  const :value_type_raw, T.nilable(Symbol), default: nil
  const :generic_base_raw, T.nilable(Symbol), default: nil
  const :generic_args_raw, T::Array[Symbol], default: []
  const :tense_type_raw, T.nilable(Symbol), default: nil

  sig { params(core_str: String, auto: T::Boolean).returns(TypeShape) }
  def self.from_core(core_str, auto: false)
    raw_symbol = core_str.to_sym

    if core_str.start_with?("~")
      tense_inner = T.must(core_str[1..])
      raise "Invalid type '#{core_str}': double tense (~~) is not allowed — ~T is already a promise" if tense_inner.start_with?("~")

      return TypeShape.new(
        raw: raw_symbol,
        auto: auto,
        tense: true,
        tense_type_raw: tense_inner.to_sym
      )
    end

    after_error_str = core_str
    error_union = T.let(false, T::Boolean)
    payload_type_raw = T.let(nil, T.nilable(Symbol))
    if core_str.start_with?("!")
      after_error_str = T.must(core_str[1..])
      raise "Invalid type '#{core_str}': double error union (!!) is not allowed" if after_error_str.start_with?("!")
      raise "Invalid type '#{core_str}': !~T (error union of tense) is not allowed — use ~!T instead" if after_error_str.start_with?("~")
      error_union = true
      payload_type_raw = after_error_str.to_sym
    end

    shape_str = after_error_str
    optional = T.let(false, T::Boolean)
    wrapped_type_raw = T.let(nil, T.nilable(Symbol))
    if after_error_str.start_with?("?")
      shape_str = T.must(after_error_str[1..])
      raise "Invalid type '#{after_error_str}': double optional (??) is not allowed" if shape_str.start_with?("?")
      raise "Invalid type '#{after_error_str}': ?~T (optional of tense) is not allowed — use ~?T instead" if shape_str.start_with?("~")
      optional = true
      wrapped_type_raw = shape_str.to_sym
    end

    array = T.let(false, T::Boolean)
    capacity = T.let(nil, ArrayCapacity)
    element_type_raw = T.let(nil, T.nilable(Symbol))
    if (match = shape_str.match(/^(.+)\[(\d+|INF|\?)?\]$/))
      array = true
      element_type_raw = T.must(match[1]).to_sym
      capacity = case match[2]
                 when nil then nil
                 when "?" then :STREAM_OPEN
                 when "INF" then :INF
                 else T.must(match[2]).to_i
                 end
    end

    map = T.let(false, T::Boolean)
    key_type_raw = T.let(nil, T.nilable(Symbol))
    value_type_raw = T.let(nil, T.nilable(Symbol))
    if (map_match = shape_str.match(/^HashMap<(.+)>$/))
      map = true
      map_inner = T.must(map_match[1])
      if map_inner.include?(",")
        parts = T.let(map_inner.split(",", 2).map(&:strip), T::Array[String])
        key_type_raw = T.must(parts[0]).to_sym
        value_type_raw = T.must(parts[1]).to_sym
      else
        key_type_raw = :String
        value_type_raw = map_inner.to_sym
      end
    end

    generic_instance = T.let(false, T::Boolean)
    generic_base_raw = T.let(nil, T.nilable(Symbol))
    generic_args_raw = T.let([], T::Array[Symbol])
    generic_match = shape_str.match(/^([A-Z]\w*)<(.+)>$/)
    if !map && !array && generic_match
      generic_instance = true
      generic_base_raw = T.must(generic_match[1]).to_sym
      generic_args_raw = T.must(generic_match[2]).split(",").map(&:strip).map(&:to_sym)
    end

    TypeShape.new(
      raw: raw_symbol,
      array: array,
      map: map,
      optional: optional,
      tense: false,
      auto: auto,
      error_union: error_union,
      generic_instance: generic_instance,
      capacity: capacity,
      payload_type_raw: payload_type_raw,
      wrapped_type_raw: wrapped_type_raw,
      element_type_raw: element_type_raw,
      key_type_raw: key_type_raw,
      value_type_raw: value_type_raw,
      generic_base_raw: generic_base_raw,
      generic_args_raw: generic_args_raw,
      tense_type_raw: nil
    )
  end

  sig { returns(TypeShape) }
  def copy
    with(generic_args_raw: generic_args_raw.dup)
  end

  sig { returns(T::Boolean) }
  def fn_type?
    raw.is_a?(FunctionSignature)
  end

  sig { returns(Symbol) }
  def resolved
    current_raw = raw
    if current_raw.is_a?(FunctionSignature)
      current_raw.return_type.to_sym
    elsif current_raw.is_a?(Array)
      item = current_raw[2]
      return item.resolved if item.is_a?(Type)
      return item if item.is_a?(Symbol)
      return item.to_sym if item.is_a?(String)
      :Any
    elsif current_raw.is_a?(Symbol)
      current_raw
    elsif current_raw.is_a?(String)
      current_raw.to_sym
    else
      :Any
    end
  end

  sig { returns(T::Boolean) }
  def numeric_map?
    map && !key_type_raw.nil? && key_type_raw != :String
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

class Type
    extend T::Sig

  TypeInput = T.type_alias { T.any(Type, Symbol, String) }
  ArrayCapacity = T.type_alias { T.nilable(T.any(Integer, Symbol)) }

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
  }.freeze, T::Hash[Symbol, String])

  SYNC_FAMILY_NAMES = T.let({
    locked: "locked",
    write_locked: "writeLocked",
    versioned: "versioned",
    atomic: "atomic",
    always_mutable: "alwaysMutable",
    local: "local",
  }.freeze, T::Hash[Symbol, String])

  DEFAULT_SHAPE = T.let(TypeShape.new(raw: :Any).freeze, TypeShape)
  DEFAULT_CAPABILITIES = T.let(TypeCapabilities.new.freeze, TypeCapabilities)
  AFFINE_CAPABILITIES = T.let(TypeCapabilities.new(ownership: :affine).freeze, TypeCapabilities)
  DEFAULT_PLACEMENT = T.let(TypePlacement.new.freeze, TypePlacement)

  class ObservablePublishSpec < T::Struct
    const :publish_method, String
    const :expr, Symbol
    const :gate, Symbol
  end

  class ObservableTerminalSpec < T::Struct
    const :wrapper, T.proc.params(type_info: Type).returns(String)
    const :ast_class, T.nilable(T::Class[T.anything]), default: nil
    const :publish, T.nilable(ObservablePublishSpec), default: nil
  end

  sig { params(value: Object).returns(T::Boolean) }
  def self.indirect_type?(value)
    return false unless value.is_a?(Type)

    value.indirect? == true
  end

  sig { params(type: TypeInput).returns(String) }
  def self.surface_name(type)
    t = type.is_a?(Type) ? type : Type.new(type)

    return "~#{surface_name(t.tense_type)}" if t.tense?
    return "!#{surface_name(T.must(t.payload_type))}" if t.error_union?
    return "?#{surface_name(T.must(t.wrapped_type))}" if t.optional?
    return "#{surface_name(T.must(t.element_type))}#{array_capacity_suffix(t.capacity)}" if t.array?

    if t.generic_instance?
      args = t.generic_args.map { |arg| surface_name(arg) }
      return "#{t.generic_base}<#{args.join(",")}>"
    end

    t.resolved.to_s
  end

  sig { params(element_type: TypeInput, capacity: ArrayCapacity).returns(Type) }
  def self.array_of(element_type, capacity: nil)
    Type.new("#{surface_name(element_type)}#{array_capacity_suffix(capacity)}")
  end

  sig { params(payload_type: TypeInput).returns(Type) }
  def self.error_union_of(payload_type)
    Type.new("!#{surface_name(payload_type)}")
  end

  sig { params(wrapped_type: TypeInput).returns(Type) }
  def self.optional_of(wrapped_type)
    Type.new("?#{surface_name(wrapped_type)}")
  end

  sig { params(value_type: TypeInput).returns(Type) }
  def self.tense_of(value_type)
    Type.new("~#{surface_name(value_type)}")
  end

  sig { params(base: Symbol, args: T::Array[TypeInput]).returns(Type) }
  def self.generic_instance_of(base, args)
    Type.new("#{base}<#{args.map { |arg| surface_name(arg) }.join(",")}>")
  end

  sig { params(capacity: ArrayCapacity).returns(String) }
  def self.array_capacity_suffix(capacity)
    case capacity
    when nil
      "[]"
    when :STREAM_OPEN
      "[?]"
    when :INF
      "[INF]"
    else
      "[#{capacity}]"
    end
  end

  # Operator categories
  BOOL_RESULT_OPS = [:EQ, :NEQ, :LT, :GT, :LTE, :GTE]
  NUMBER_RESULT_OPS = [:SUB, :MUL, :DIV, :POW, :MOD, :WRAP_SUB, :WRAP_MUL, :CHECK_SUB, :CHECK_MUL]

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
    auto_present = (left_type.respond_to?(:auto?) && left_type.auto?) ||
                   (right_type.respond_to?(:auto?) && right_type.auto?)
    if auto_present
      case op
      when :AND, :OR, *BOOL_RESULT_OPS
        return BinaryOpResult.new(type: Type.new(:Bool))
      else
        auto_t = Type.new(:Auto, auto: true)
        return BinaryOpResult.new(type: auto_t)
      end
    end

    t_left = left_type.resolved
    t_right = right_type.resolved

    case op
    when :AND, :OR
      BinaryOpResult.new(type: Type.new(:Bool))

    when *BOOL_RESULT_OPS
      BinaryOpResult.new(type: Type.new(:Bool))

    when *NUMBER_RESULT_OPS
      resolve_numeric_op(left_type, right_type)

    when :ADD
      resolve_add_op(t_left, t_right, left_type, right_type)

    when :WRAP_ADD, :CHECK_ADD
      resolve_numeric_op(left_type, right_type)

    else
      BinaryOpResult.new(error: "Unknown operator: #{op}")
    end
  end

  # Returns error message if source cannot be coerced to target, nil if ok.
  #
  # @param source_type [Type, Symbol, String] The type being assigned
  # @param target_type [Type, Symbol, String] The declared/expected type
  # @return [String, nil] Error message or nil if coercion is valid
  #
  sig { params(source_type: Type, target_type: TypeInput).returns(T.nilable(String)) }
  def self.coerce_error(source_type, target_type)
    source = source_type
    target = target_type.is_a?(Type) ? target_type : Type.new(target_type)

    # Gradual-typing tolerance: an Auto target accepts any source —
    # the AutoUnifier resolves the target's concrete type after the
    # body walk, mutating the decl in place. Source-side Auto is
    # similarly tolerated: the source expression's resolved type
    # propagates once the unifier pins the slot it depends on.
    return nil if target.auto?
    return nil if source.auto?

    return nil if target.accepts?(source)

    if target.array_overflow?(source)
      "Cannot initialize array of size #{target.capacity} with #{source.capacity} elements"
    else
      "Type Mismatch: Cannot assign #{source.resolved} to #{target.resolved}"
    end
  end

  private

  sig { params(left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_numeric_op(left_type, right_type)
    t_left = left_type.resolved
    t_right = right_type.resolved

    # Same type: result is that type
    if t_left == t_right
      return BinaryOpResult.new(type: left_type)
    end

    # Both integers: promote to the wider type (use Int64 as default)
    if left_type.integer? && right_type.integer?
      return BinaryOpResult.new(type: t_left == :Int64 ? left_type : right_type,
        left_coercion: t_left == :Int64 ? nil : :Int64,
        right_coercion: t_right == :Int64 ? nil : :Int64)
    end

    # Both floats: promote to f64
    if left_type.float? && right_type.float?
      return BinaryOpResult.new(type: t_left == :Float64 ? left_type : right_type,
        left_coercion: t_left == :Float64 ? nil : :Float64,
        right_coercion: t_right == :Float64 ? nil : :Float64)
    end

    # Mixed int/float: promote integer operand to the float type
    if left_type.integer? && right_type.float?
      return BinaryOpResult.new(type: right_type, left_coercion: t_right)
    end
    if left_type.float? && right_type.integer?
      return BinaryOpResult.new(type: left_type, right_coercion: t_left)
    end

    BinaryOpResult.new(type: Type.new(:Float64))
  end

  sig { params(t_left: Symbol, t_right: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_add_op(t_left, t_right, left_type, right_type)
    lt = Type.new(t_left)
    rt = Type.new(t_right)

    # A. Numeric addition (all int/float types)
    if lt.numeric? && rt.numeric?
      return resolve_numeric_op(left_type, right_type)
    end

    # B. String Concatenation
    if t_left == HEAP_STRING_TYPE || t_right == HEAP_STRING_TYPE
      left_coercion = (t_left != :String && safe_autocast?(t_left, :String)) ? :String : nil
      right_coercion = (t_right != :String && safe_autocast?(t_right, :String)) ? :String : nil
      return BinaryOpResult.new(type: Type.new(HEAP_STRING_TYPE), left_coercion: left_coercion, right_coercion: right_coercion, storage: :frame)
    end

    # D. Array Concatenation
    if left_type.array? && right_type.array?
      return BinaryOpResult.new(type: Type.new(left_type), storage: :frame)
    end

    BinaryOpResult.new(error: "Cannot add types: #{t_left} and #{t_right}")
  end

  sig { params(from_type: Symbol, to_type: Symbol).returns(T::Boolean) }
  def self.safe_autocast?(from_type, to_type)
    from_t = Type.new(from_type)
    to_t   = Type.new(to_type)
    return false if from_t.fn_type? || to_t.fn_type?
    # Any numeric -> any numeric (implicit promotion/narrowing handled by Zig casts)
    return true if from_t.numeric? && to_t.numeric?
    # Original types that can auto-cast to strings
    [:Float64, :Int64, :Bool, :Byte].include?(from_t.resolved)
  end

  public

  sig do
    params(
      raw_input: Object,
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
    @capabilities       = T.let(DEFAULT_CAPABILITIES, TypeCapabilities)
    @placement          = T.let(DEFAULT_PLACEMENT, TypePlacement)
    @is_resource        = T.let(nil, T.nilable(T::Boolean))
    @auto_token         = T.let(nil, T.nilable(Lexer::Token))
    @zig_type_cache     = T.let(nil, T.nilable(String))
    @generic_payload_type_arg = T.let(false, T::Boolean)
    if raw_input.is_a?(Type)
      other = raw_input
      @shape              = auto ? other.shape.with(auto: true) : other.shape
      @capabilities       = other.capabilities
      @placement          = other.placement
      @auto_token         = other.auto_token
      @generic_payload_type_arg = other.generic_payload_type_arg?
    else
      parse_raw_input(raw_input, auto: auto)
    end

    # Capability fields — set after parse/copy so explicit constructor
    # overrides can replace the parsed/default capability state. Most Type
    # construction uses the parsed default, so avoid the generic merge path
    # unless there is an actual override.
    apply_declared_location!(location)
    if ownership || sync || layout || collection || shard_count || observable || observable_terminal
      apply_capabilities!(
        ownership: ownership || TypeCapabilities::UNSET,
        sync: sync || TypeCapabilities::UNSET,
        layout: layout || TypeCapabilities::UNSET,
        collection: collection || TypeCapabilities::UNSET,
        shard_count: shard_count || TypeCapabilities::UNSET,
        observable: observable ? true : TypeCapabilities::UNSET,
        observable_terminal: observable_terminal || TypeCapabilities::UNSET
      )
    end
    # Sync types need a stable heap address.
    # :raw and :symbol are data-access modes, not locks — they don't force heap provenance.
    pin_heap_for_sync_wrapper! if sync_requires_heap_provenance?
    # `:indirect` layout is the explicit "heap-pinned cell with a stable
    # address" form (used by @indirect:atomic = AtomicPtr(T)). Force heap
    # provenance even without an active sync, mirroring the @indirect
    # CapabilityWrap branch in the annotator (annotator.rb:3517).
    pin_heap_for_indirect! if indirect?
    # Symbol strings live in static read-only memory — always rodata, never heap/frame.
    mark_rodata! if symbol?
    # Pool collection always lives on the heap (owns internal slot array).
    pin_heap_for_collection! if collection && pool?
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
  ESCAPE_CLASSES = T.let(%i[
    value          primitives, Id<T>, fixed value arrays — bag-of-bits
    slice_rodata   string literals — slice header into static memory
    slice_managed  frame/heap strings, lists, sets, pools, maps — slice into allocator
    by_ref         user structs, unions, enums, @indirect — captured by pointer
    refcounted     any_rc — Arc / Rc with own lifetime mechanism
    sync_wrapped   any_sync — locked / write_locked / atomic over a payload
  ].each_slice(2).map(&:first).freeze, T::Array[T.nilable(Symbol)])

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

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def ownership=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(ownership: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def ownership
    @capabilities.ownership
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def sync=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(sync: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def sync
    @capabilities.sync
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def layout=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(layout: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def layout
    @capabilities.layout
  end

  sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def lock_rank=(value)
    @capabilities = @capabilities.with(lock_rank: value)
    value
  end

  sig { returns(T.nilable(Integer)) }
  def lock_rank
    @capabilities.lock_rank
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def collection=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(collection: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def collection
    @capabilities.collection
  end

  sig { params(value: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def shard_count=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(shard_count: value)
    value
  end

  sig { returns(T.nilable(Integer)) }
  def shard_count
    @capabilities.shard_count
  end

  sig { params(value: T::Boolean).returns(T::Boolean) }
  def soa=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(soa: value)
    value
  end

  sig { returns(T::Boolean) }
  def soa
    @capabilities.soa
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def elem_ownership=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(elem_ownership: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def elem_ownership
    @capabilities.elem_ownership
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def elem_sync=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(elem_sync: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def elem_sync
    @capabilities.elem_sync
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def link_source=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(link_source: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def link_source
    @capabilities.link_source
  end

  sig { params(value: T::Boolean).returns(T::Boolean) }
  def is_observable=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(observable: value)
    value
  end

  sig { returns(T::Boolean) }
  def is_observable
    @capabilities.observable
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def observable_terminal=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(observable_terminal: value)
    value
  end

  sig { returns(T.nilable(Symbol)) }
  def observable_terminal
    @capabilities.observable_terminal
  end

  sig { params(value: T.nilable(Object)).returns(T.nilable(Object)) }
  def observable_token=(value)
    @capabilities = @capabilities.with(observable_token: value)
    value
  end

  sig { returns(T.nilable(Object)) }
  def observable_token
    @capabilities.observable_token
  end

  sig { params(value: T::Boolean).returns(T::Boolean) }
  def polymorphic_shared=(value)
    @zig_type_cache = nil
    @capabilities = @capabilities.with(polymorphic_shared: value)
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
      link_source: TypeCapabilities::MaybeSymbol,
      observable: TypeCapabilities::MaybeBoolean,
      observable_terminal: TypeCapabilities::MaybeSymbol,
      observable_token: TypeCapabilities::MaybeObject,
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
    link_source: TypeCapabilities::UNSET,
    observable: TypeCapabilities::UNSET,
    observable_terminal: TypeCapabilities::UNSET,
    observable_token: TypeCapabilities::UNSET,
    polymorphic_shared: TypeCapabilities::UNSET
  )
    @zig_type_cache = nil
    @capabilities = @capabilities.with(
      ownership: ownership,
      sync: sync,
      layout: layout,
      lock_rank: lock_rank,
      collection: collection,
      shard_count: shard_count,
      soa: soa,
      elem_ownership: elem_ownership,
      elem_sync: elem_sync,
      link_source: link_source,
      observable: observable,
      observable_terminal: observable_terminal,
      observable_token: observable_token,
      polymorphic_shared: polymorphic_shared
    )
  end

  sig { void }
  def clear_zig_type_cache!
    @zig_type_cache = nil
  end

  sig { params(provenance: TypePlacement::MaybeSymbol).returns(TypePlacement) }
  def apply_placement!(provenance: TypePlacement::UNSET)
    @zig_type_cache = nil
    @placement = @placement.with(provenance: provenance)
  end

  sig { returns(T.nilable(Symbol)) }
  def provenance
    @placement.provenance
  end

  sig { params(location: T.nilable(Symbol)).returns(TypePlacement) }
  def apply_declared_location!(location)
    return placement unless location && location != :stack

    apply_placement!(provenance: location)
  end

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

  sig { returns(TypePlacement) }
  def mark_rodata!
    apply_placement!(provenance: :rodata)
  end

  sig { returns(TypePlacement) }
  def mark_borrowed_reference!
    apply_placement!(provenance: :borrow)
  end

  sig { returns(TypePlacement) }
  def pin_heap_for_sync_wrapper!
    mark_heap_allocated!
  end

  sig { returns(TypePlacement) }
  def pin_heap_for_indirect!
    mark_heap_allocated!
  end

  sig { returns(TypePlacement) }
  def pin_heap_for_collection!
    mark_heap_allocated!
  end

  sig { returns(TypePlacement) }
  def reset_to_bare_data_placement!
    mark_stack_value!
  end

  sig { params(source: Type, preserve_existing: T::Boolean).returns(TypePlacement) }
  def copy_placement_from!(source, preserve_existing: true)
    return placement if preserve_existing && provenance

    apply_placement!(provenance: source.provenance || TypePlacement::UNSET)
  end

  sig { params(value_type: T.nilable(Type), alloc: T.nilable(Symbol)).returns(TypePlacement) }
  def apply_cleanup_placement!(value_type:, alloc:)
    return placement if provenance

    if value_type&.provenance
      copy_placement_from!(value_type, preserve_existing: false)
    elsif alloc
      apply_placement!(provenance: alloc)
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
      ownership: ownership || TypeCapabilities::UNSET,
      link_source: link_source || TypeCapabilities::UNSET
    )
  end

  sig { params(terminal: Symbol).returns(TypeCapabilities) }
  def stamp_observable_terminal!(terminal)
    apply_capabilities!(observable_terminal: terminal)
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
      collection: collection || TypeCapabilities::UNSET,
      soa: soa ? true : TypeCapabilities::UNSET,
      shard_count: shard_count || TypeCapabilities::UNSET
    )
  end

  sig { params(soa: T::Boolean, elem_ownership: T.nilable(Symbol), elem_sync: T.nilable(Symbol), observable_token: T.nilable(Object)).returns(TypeCapabilities) }
  def apply_type_annotation_extras!(soa:, elem_ownership:, elem_sync:, observable_token:)
    apply_capabilities!(
      soa: soa ? true : TypeCapabilities::UNSET,
      elem_ownership: elem_ownership || TypeCapabilities::UNSET,
      elem_sync: elem_sync || TypeCapabilities::UNSET,
      observable_token: observable_token || TypeCapabilities::UNSET
    )
  end

  sig { params(ownership: T.nilable(Symbol), sync: T.nilable(Symbol), lock_rank: T.nilable(Integer), layout: T.nilable(Symbol)).returns(TypeCapabilities) }
  def apply_declared_type_capabilities!(ownership:, sync:, lock_rank:, layout:)
    apply_capabilities!(
      ownership: ownership || TypeCapabilities::UNSET,
      sync: sync || TypeCapabilities::UNSET,
      lock_rank: lock_rank || TypeCapabilities::UNSET,
      layout: layout || TypeCapabilities::UNSET
    )
  end

  sig { returns(TypeCapabilities) }
  def strip_layout!
    apply_capabilities!(layout: nil)
  end

  sig { params(storage: Symbol, value_sync: T.nilable(Symbol), link_source: T.nilable(Symbol)).returns(TypeCapabilities) }
  def apply_storage_capability!(storage, value_sync: nil, link_source: nil)
    case storage
    when :frozen
      apply_reference_ownership!(:frozen)
    when :multiowned
      apply_reference_ownership!(:multiowned)
    when :shared
      apply_reference_ownership!(:shared)
    when :link
      apply_reference_ownership!(:link, link_source: link_source)
    when :rodata
      mark_rodata!
      capabilities
    when :frame
      mark_frame_allocated!
      capabilities
    when :heap
      mark_heap_allocated!
      if value_sync == :locked || value_sync == :write_locked
        apply_capabilities!(sync: value_sync)
      else
        capabilities
      end
    when :borrow
      mark_borrowed_reference!
      capabilities
    else
      capabilities
    end
  end

  sig { params(storage: Symbol, entry_sync: T.nilable(Symbol), entry_layout: T.nilable(Symbol), value_sync: T.nilable(Symbol), link_source: T.nilable(Symbol), atomic_ptr: T::Boolean).returns(TypeCapabilities) }
  def apply_symbol_overlay!(storage:, entry_sync:, entry_layout:, value_sync:, link_source:, atomic_ptr:)
    apply_storage_capability!(storage, value_sync: value_sync, link_source: link_source)
    apply_capabilities!(
      ownership: atomic_ptr && ownership == :affine ? :shared : TypeCapabilities::UNSET,
      sync: entry_sync && !sync ? entry_sync : TypeCapabilities::UNSET,
      layout: entry_layout && !layout ? entry_layout : TypeCapabilities::UNSET
    )
  end

  sig { params(storage: Symbol, sync: T.nilable(Symbol)).returns(TypeCapabilities) }
  def apply_bg_capture_symbol!(storage:, sync:)
    apply_capabilities!(
      ownership: (storage == :multiowned || storage == :shared) && (!ownership || ownership == :affine) ? storage : TypeCapabilities::UNSET,
      sync: sync && !self.sync ? sync : TypeCapabilities::UNSET
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_collection_shape_from!(source)
    apply_capabilities!(
      collection: !collection && source.collection ? source.collection : TypeCapabilities::UNSET,
      shard_count: !shard_count && source.shard_count ? source.shard_count : TypeCapabilities::UNSET,
      soa: source.soa? && !soa? ? true : TypeCapabilities::UNSET
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_topology_from!(source)
    apply_capabilities!(
      shard_count: !shard_count && source.shard_count ? source.shard_count : TypeCapabilities::UNSET,
      soa: source.soa? && !soa? ? true : TypeCapabilities::UNSET
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_declared_collection_modifiers_from!(source)
    apply_capabilities!(
      ownership: source.ownership != :affine ? source.ownership : TypeCapabilities::UNSET,
      sync: source.sync && !sync ? source.sync : TypeCapabilities::UNSET,
      shard_count: source.shard_count && !shard_count ? source.shard_count : TypeCapabilities::UNSET
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_element_capabilities_from!(source)
    apply_capabilities!(
      elem_ownership: source.elem_ownership || TypeCapabilities::UNSET,
      elem_sync: source.elem_sync || TypeCapabilities::UNSET
    )
  end

  sig { params(source: Type).returns(TypeCapabilities) }
  def copy_striped_map_topology_from!(source)
    apply_capabilities!(
      shard_count: source.shard_count || TypeCapabilities::UNSET,
      sync: source.shard_count && source.sync ? T.must(source.sync) : TypeCapabilities::UNSET,
      ownership: :affine
    )
  end

  sig { params(final_type: Type, value_type: T.nilable(Type)).returns(TypeCapabilities) }
  def apply_finalized_value_shape!(final_type:, value_type:)
    final_shard_count = final_type.shard_count || value_type&.shard_count
    final_soa = final_type.soa || (value_type&.respond_to?(:soa) && value_type.soa)
    observable = final_type.observable? ||
                 (!value_type.nil? && value_type.respond_to?(:observable?) && value_type.observable?)
    observable_terminal = if final_type.observable_terminal
      final_type.observable_terminal
    elsif !value_type.nil? && value_type.respond_to?(:observable_terminal) && value_type.observable_terminal
      value_type.observable_terminal
    end
    elem_ownership = final_type.elem_ownership ||
                     (value_type&.respond_to?(:elem_ownership) ? value_type.elem_ownership : nil)
    elem_sync = final_type.elem_sync ||
                (value_type&.respond_to?(:elem_sync) ? value_type.elem_sync : nil)
    link_src = value_type&.link? ? value_type.link_source : nil
    apply_capabilities!(
      shard_count: final_shard_count || TypeCapabilities::UNSET,
      sync: final_type.sync || TypeCapabilities::UNSET,
      soa: final_soa ? true : TypeCapabilities::UNSET,
      collection: value_type&.collection || TypeCapabilities::UNSET,
      observable: observable ? true : TypeCapabilities::UNSET,
      observable_terminal: observable_terminal || TypeCapabilities::UNSET,
      elem_ownership: elem_ownership || TypeCapabilities::UNSET,
      elem_sync: elem_sync || TypeCapabilities::UNSET,
      layout: final_type.layout || TypeCapabilities::UNSET,
      link_source: link_src || TypeCapabilities::UNSET
    )
  end

  sig { params(source: Type, preserve_existing: T::Boolean, include_affine_ownership: T::Boolean).returns(TypeCapabilities) }
  def merge_capabilities_from!(source, preserve_existing: true, include_affine_ownership: false)
    source_ownership = source.ownership
    existing_concrete_ownership = ownership && ownership != :affine
    next_ownership = if preserve_existing && existing_concrete_ownership
      TypeCapabilities::UNSET
    elsif source_ownership && (include_affine_ownership || source_ownership != :affine)
      source_ownership
    else
      TypeCapabilities::UNSET
    end
    source_collection = source.collection
    source_shard_count = source.shard_count
    source_layout = source.layout
    source_sync = source.sync
    source_elem_ownership = source.elem_ownership
    source_elem_sync = source.elem_sync
    source_link_source = source.link_source
    apply_capabilities!(
      ownership: next_ownership,
      sync: (!preserve_existing || !sync) && source_sync ? source_sync : TypeCapabilities::UNSET,
      layout: (!preserve_existing || !layout) && source_layout ? source_layout : TypeCapabilities::UNSET,
      collection: (!preserve_existing || !collection) && source_collection ? source_collection : TypeCapabilities::UNSET,
      shard_count: (!preserve_existing || !shard_count) && source_shard_count ? source_shard_count : TypeCapabilities::UNSET,
      soa: source.soa? && (!preserve_existing || !soa?) ? true : TypeCapabilities::UNSET,
      elem_ownership: (!preserve_existing || !elem_ownership) && source_elem_ownership ? source_elem_ownership : TypeCapabilities::UNSET,
      elem_sync: (!preserve_existing || !elem_sync) && source_elem_sync ? source_elem_sync : TypeCapabilities::UNSET,
      link_source: (!preserve_existing || !link_source) && source_link_source ? source_link_source : TypeCapabilities::UNSET,
      observable: source.observable? && (!preserve_existing || !observable?) ? true : TypeCapabilities::UNSET,
      observable_terminal: (!preserve_existing || !observable_terminal) && source.observable_terminal ? T.must(source.observable_terminal) : TypeCapabilities::UNSET,
      observable_token: (!preserve_existing || !observable_token) && source.observable_token ? source.observable_token : TypeCapabilities::UNSET,
      polymorphic_shared: source.polymorphic_shared? && (!preserve_existing || !polymorphic_shared?) ? true : TypeCapabilities::UNSET
    )
  end

  sig { returns(TypeCapabilities) }
  def strip_runtime_capabilities!
    @zig_type_cache = nil
    @capabilities = @capabilities.without_runtime_wrappers
  end

  # -----------------------------------------------
  # COMPATIBILITY LAYER (The "Don't Break Tests" part)
  # -----------------------------------------------

  # Allow code to compare this object directly to symbols/strings
  # e.g. if node.type == :Float64
  sig { params(other: T.untyped).returns(T::Boolean) }
  def ==(other)
    # fn_types must never compare equal to a plain symbol (resolved returns the return type,
    # not a unique identity). Two fn_types are equal only when their raw hashes match.
    if fn_type?
      other_t = other.is_a?(Type) ? other : nil
      return false unless other_t&.fn_type?
      return raw == other_t.raw
    end
    resolved == other.to_sym || raw == other
  end

  sig { returns(Object) }
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

  sig { returns(String) }
  def to_s; resolved.to_s; end
  sig { returns(Symbol) }
  def to_sym; resolved; end

  # Backward API: Deprecate
  sig { returns(Symbol) }
  def resolved
    shape.resolved
  end

  sig { returns(TypeId) }
  def type_id
    TypeId.new(key: semantic_type_key)
  end

  sig { returns(String) }
  def semantic_type_key
    [
      semantic_shape_key,
      "own=#{ownership || :affine}",
      "sync=#{sync || :none}",
      "layout=#{layout || :direct}",
      "loc=#{provenance || :stack}",
      "collection=#{collection || :none}",
      "shards=#{shard_count || 0}",
    ].join("|")
  end

  # Backward API: Deprecate
  sig { returns(Symbol) }
  def base_type
    resolved.to_s.sub(/\[.*\]$/, "").to_sym
  end

  sig { returns(T::Boolean) }
  def generic_type_parameter?
    raw = shape.raw
    raw.is_a?(Symbol) && raw.to_s.length == 1 && raw.to_s >= "A" && raw.to_s <= "Z"
  end

  sig { returns(T::Boolean) }
  def primitive?
    AST::PRIMITIVE_TYPES.include?(resolved)
  end

  # ----------------------------------------------
  # Coercion helpers
  # ----------------------------------------------
  sig { params(other_type: Type).returns(T::Boolean) }
  def accepts?(other_type)
    # 0. Function type: must precede == shortcut (resolved strips fn signature to return type)
    return accepts_fn_type?(other_type) if fn_type?

    # 1. Exact match / Any
    return true if self == other_type || any? || other_type.any?

    # 2. Primitive widening
    return true if numeric? && other_type.numeric?
    return true if string? && (other_type.byte? || other_type.string?)

    # 3. Optional coercion: ?T accepts T, NIL, or ?T
    if optional?
      return true if other_type.resolved == :NIL
      inner = other_type.optional? ? T.must(other_type.wrapped_type) : other_type
      return T.must(wrapped_type).accepts?(inner)
    end

    # 4. Error union coercion: !T accepts T or !T
    if error_union?
      inner = other_type.error_union? ? T.must(other_type.payload_type) : other_type
      return T.must(payload_type).accepts?(inner)
    end

    # 5. Tense (Promise/Stream) coercion
    return accepts_future?(other_type) if future?

    # 6. Array coercion
    return accepts_array?(other_type) if array?

    # 7. HashMap coercion: HashMap<Any> (empty literal) accepts any HashMap<T>
    if map? && other_type.map?
      return true if other_type.value_type.any?
      return value_type.accepts?(other_type.value_type)
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
    return false unless other_capacity.is_a?(Integer) && self_capacity.is_a?(Integer)
    return true if other_capacity > self_capacity
  end

  # ----------------------------------------------
  # Type Predicates
  # ----------------------------------------------
  SIGNED_INT_TYPES   = [:Int8, :Int16, :Int32, :Int64].freeze
  UNSIGNED_INT_TYPES = [:UInt8, :Byte, :UInt16, :UInt32, :UInt64].freeze
  INT_TYPES          = T.let((SIGNED_INT_TYPES + UNSIGNED_INT_TYPES).freeze, T::Array[Symbol])
  FLOAT_TYPES        = [:Float32, :Float64].freeze
  NUMERIC_TYPES      = T.let((INT_TYPES + FLOAT_TYPES).freeze, T::Array[Symbol])

  INT_TYPE_MAX = T.let({
    Byte: 255, UInt8: 255, UInt16: 65_535, UInt32: 4_294_967_295,
    UInt64: (2**64) - 1,
    Int8: 127, Int16: 32_767, Int32: 2_147_483_647, Int64: 9_223_372_036_854_775_807,
  }.freeze, T::Hash[Symbol, Integer])
  INT_TYPE_MIN = T.let({
    Byte: 0, UInt8: 0, UInt16: 0, UInt32: 0, UInt64: 0,
    Int8: -128, Int16: -32_768, Int32: -2_147_483_648, Int64: -9_223_372_036_854_775_808,
  }.freeze, T::Hash[Symbol, Integer])

  sig { returns(T::Boolean) }
  def numeric?
    NUMERIC_TYPES.include?(resolved)
  end

  sig { returns(T::Boolean) }
  def integer?
    INT_TYPES.include?(resolved)
  end

  sig { returns(T::Boolean) }
  def signed_integer?
    SIGNED_INT_TYPES.include?(resolved)
  end

  sig { returns(T::Boolean) }
  def unsigned_integer?
    UNSIGNED_INT_TYPES.include?(resolved)
  end

  sig { returns(T::Boolean) }
  def float?
    FLOAT_TYPES.include?(resolved)
  end

  sig { returns(T::Boolean) }
  def byte?
    resolved == :Byte
  end

  sig { returns(T::Boolean) }
  def void?
    resolved == :Void
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

  sig { returns(T::Boolean) }
  def array?
    shape.array
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
    array? && capacity.is_a?(Integer)
  end

  # True when this is the legacy [?] marker (open stream element-type annotation).
  # Only meaningful as the tense_type of an open stream: ~T[?].
  sig { returns(T::Boolean) }
  def open_stream_marker?
    array? && capacity == :STREAM_OPEN
  end

  # True when this is the [INF] marker (infinite stream element-type annotation).
  # Only meaningful as the tense_type of an infinite stream: ~T[INF].
  sig { returns(T::Boolean) }
  def inf_stream_marker?
    array? && capacity == :INF
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

  # AtomicPtr cell: @indirect:atomic. The `sync == :atomic && layout ==
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

  # True for any sync capability (excludes :raw and :symbol which are data-access modes, not locks)
  sig { returns(T::Boolean) }
  def any_sync?
    !sync.nil? && sync != :raw && sync != :symbol
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
    bare = Type.new(self)
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

  sig { returns(T::Boolean) }
  def shared_or_multiowned?
    shared? || multiowned?
  end

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
    shape.numeric_map?
  end

  sig { returns(T::Boolean) }
  def plain_numeric_map?
    numeric_map? && !sharded? && !striped?
  end

  sig { returns(Type) }
  def key_type
    Type.new(shape.key_type_raw || :String)
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
    return !!(wrapped_type&.heap_ptr?) if optional?
    string? || indirect? || tense_observable? || collection? || (array? && !fixed? && !string?)
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

  # Iteration shape for the FSM ForEach lowering. The recursive
  # splitter dispatches on the kind to build a per-iteration
  # segment graph. Returns nil for collection shapes the FSM
  # transform can't yet model (the body falls back to stackful).
  #
  # Shapes:
  #   :indexed_slice -- usize index iterates a slice. Suffix is
  #                     ".items" for ArrayList-backed collections,
  #                     "" for raw arrays.
  #   :pool_indexed  -- usize index iterates `coll.slots`, skipping
  #                     entries where `.alive == false`. The bound
  #                     element is `slot.value`.
  #   :iterator      -- a stateful iterator object lives on ctx;
  #                     `.next()` returns ?T (or ?*T for sets), and
  #                     the bound var captures the unwrapped value.
  #
  # Adding a new collection = adding one branch here. The splitter
  # never inspects the type directly.
  sig { returns(T.nilable(TypeFsmForEachDescriptor)) }
  def fsm_foreach_descriptor
    if pool?
      TypeFsmForEachDescriptor.new(kind: :pool_indexed, var_zig_type: element_type&.zig_type || "anyopaque")
    elsif map?
      # FOR k IN map iterates KEYS. keyIterator yields ?*K, so the
      # bound var dereferences (deref: true).
      TypeFsmForEachDescriptor.new(kind: :iterator, init_method: "keyIterator", advance_method: "next",
        deref: true, var_zig_type: key_type.zig_type)
    elsif set_collection?
      # FOR v IN set: keyIterator yields ?*T, so the bound var is
      # the element type (after deref).
      TypeFsmForEachDescriptor.new(kind: :iterator, init_method: "keyIterator", advance_method: "next",
        deref: true, var_zig_type: element_type&.zig_type || "anyopaque")
    elsif list_collection?
      TypeFsmForEachDescriptor.new(kind: :indexed_slice, slice_suffix: ".items",
        var_zig_type: element_type&.zig_type || "anyopaque")
    elsif array? && !dynamic?
      TypeFsmForEachDescriptor.new(kind: :indexed_slice, slice_suffix: "",
        var_zig_type: element_type&.zig_type || "anyopaque")
    elsif array? && dynamic?
      TypeFsmForEachDescriptor.new(kind: :indexed_slice, slice_suffix: ".items",
        var_zig_type: element_type&.zig_type || "anyopaque")
    else nil
    end
  end

  # Returns the canonical registry key for this type.
  # Used as the single lookup key for INDEX_OPS, COLLECTION_METHOD_CONFIGS, etc.
  # All type-to-dispatch mappings must go through here — never add new if/elsif
  # chains on type predicates in lowering or annotation code.
  sig { returns(T.nilable(Symbol)) }
  def dispatch_key
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
    pool? || sharded? || heap? || tense_observable?
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
    @is_resource || RESOURCE_TYPES.include?(resolved)
  end

  # Resolve the Zig close/deinit statement for resource types.
  # Returns [is_resource, close_zig_template] where close_zig_template uses
  # {0} for the variable name and {rt} for runtime access. Returns
  # [false, nil] for non-resources.
  #
  # Group 1 / Group 2 separation: when a Group-2 shape (pool/set/...) is
  # wrapped with Group-1 ownership (Arc/Rc), the bare-shape `.deinit()`
  # call doesn't apply against the wrapper. Skip the resource path so the
  # cleanup classifier picks the rc/sync entry instead, which cascades
  # through the wrapper down to the inner shape's destruction.
  ResourceCloseResult = T.type_alias { [T::Boolean, T.nilable(String)] }

  sig { params(schema_lookup: T.nilable(T.proc.params(name: Symbol).returns(T.nilable(Object)))).returns(ResourceCloseResult) }
  def resolve_resource_close(schema_lookup = nil)
    return [false, nil] if any_rc?
    return [true, "{0}.deinit()"] if open_stream? || inf_stream? || split_open_stream?

    return [false, nil] unless schema_lookup
    schema = T.let((schema_lookup.call(resolved) rescue nil), T.nilable(Object))

    if schema.is_a?(Schemas::ResourceSchema)
      return [true, schema.close_zig]
    end

    # Struct with resource fields: compose close statements from fields.
    if schema.is_a?(Schemas::StructSchema)
      closes = T.let([], T::Array[String])
      schema.fields.each do |fname, fdef|
        f_resolved = fdef.type.resolved
        f_schema = T.let((schema_lookup.call(f_resolved) rescue nil), T.nilable(Object))
        if f_schema.is_a?(Schemas::ResourceSchema)
          closes << f_schema.close_zig.gsub("{0}", "{0}.#{fname}")
        end
      end
      return [true, closes.join("; ")] if closes.any?
    end

    [false, nil]
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
      !(tense? && tense_type&.array?)
  end

  sig { returns(T::Boolean) }
  def observable_array_without_set?
    !!(tense? && observable? && tense_type&.array? && !set_collection?)
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
    string? && (other.nil? || other.string?)
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
    Type.new(shape.value_type_raw || :Any)
  end

  # Generic struct instance: Pair<Number>, Map<String, Number>
  sig { returns(T::Boolean) }
  def generic_instance?
    shape.generic_instance
  end

  # The base type name of a generic instance: :"Pair<Number>" → :Pair
  sig { returns(Symbol) }
  def generic_base
    shape.generic_base_raw || resolved
  end

  sig { returns(T::Boolean) }
  def id_handle?
    generic_instance? && shape.generic_base_raw == :Id
  end

  sig { returns(T.nilable(String)) }
  def ownership_surface_name
    own = ownership
    own ? OWNERSHIP_SURFACE_NAMES[own] : nil
  end

  sig { returns(T.nilable(String)) }
  def sync_surface_name
    current_sync = sync
    current_sync ? SYNC_SURFACE_NAMES[current_sync] : nil
  end

  sig { returns(T.nilable(String)) }
  def sync_family_name
    current_sync = sync
    current_sync ? SYNC_FAMILY_NAMES[current_sync] : nil
  end

  # The type arguments as Type objects: [Type(:Float64), Type(:String)]
  sig { returns(T::Array[Type]) }
  def generic_args
    shape.generic_args_raw.map { |arg| Type.new(arg) }
  end

  sig { returns(T::Boolean) }
  def struct?
    !primitive? && !any? && !void? && !string? && !array? && !map? && !optional? && !error_union? && !tense? && !fn_type?
  end

  sig { returns(T::Boolean) }
  def optional?
    shape.optional
  end

  sig { returns(T.nilable(Type)) }
  def wrapped_type
    return nil unless optional?
    Type.new(shape.wrapped_type_raw || :Any)
  end

  # Error union types: !T (Zig-style error returns)
  sig { returns(T::Boolean) }
  def error_union?
    shape.error_union
  end

  sig { returns(T.nilable(Type)) }
  def payload_type
    return nil unless error_union?
    Type.new(shape.payload_type_raw || :Any)
  end

  sig { returns(Type) }
  def success_type
    return self unless error_union?

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
    return false unless tt.is_a?(Type)

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
    return true if !inner&.array? && !inner&.map?  # scalar terminal
    set_collection?  # collection terminal (DISTINCT)
  end

  # A3: single source of truth for every pipeline-terminal observable.
  # Each entry consolidates the three pieces of information previously
  # split across OBSERVABLE_WRAPPERS (here), PUBLISH_SPEC + FOLD_OP_OBSERVABLE_TERMINAL
  # (pipeline_host.rb):
  #
  #   :wrapper   -- lambda(tense_type) -> "ObservableX(...)" Zig string.
  #                 Builders use Type API on tense_type (zig_type,
  #                 element_type, wrapped_type, fixed?, capacity); no
  #                 string surgery. Caller prepends "*CheatLib.obs.".
  #   :ast_class -- the Pipeline-AST class (AST::SumOp, etc.) so the
  #                 codegen's `lower_range_fold` can dispatch from a
  #                 fold_op instance to the terminal symbol. Omitted on
  #                 :reduce / :distinct because they have their own
  #                 dedicated lowering helpers (lower_range_reduce_observable
  #                 / lower_range_fold_observable_distinct) and never
  #                 hit the default fold-op dispatch.
  #   :publish   -- per-item publish recipe { method:, expr:, gate: }
  #                 consumed by lower_range_fold_observable_default.
  #                 Same omission for :reduce / :distinct.
  #
  # Lazy class method (rather than top-level constant) so the AST::*
  # class references resolve at first-call time, after src/ast/ast.rb
  # has finished loading. type.rb is required from inside ast.rb, so
  # AST::SumOp is not yet defined while type.rb's class body evaluates.
  sig { returns(T::Hash[Symbol, ObservableTerminalSpec]) }
  def self.observable_terminals
    @observable_terminals ||= T.let({
      sum: ObservableTerminalSpec.new(
        wrapper: ->(type_info) { "ObservableSum(#{type_info.zig_type})" },
        ast_class: AST::SumOp,
        publish: ObservablePublishSpec.new(publish_method: "add", expr: :typed, gate: :always),
      ),
      count: ObservableTerminalSpec.new(
        wrapper: ->(_type_info) { "ObservableCount()" },
        ast_class: AST::CountOp,
        publish: ObservablePublishSpec.new(publish_method: "inc", expr: :none, gate: :pred),
      ),
      avg: ObservableTerminalSpec.new(
        # AVG view is always f64.
        wrapper: ->(_type_info) { "ObservableAvg(f64)" },
        ast_class: AST::AverageOp,
        publish: ObservablePublishSpec.new(publish_method: "add", expr: :f64, gate: :always),
      ),
      max: ObservableTerminalSpec.new(
        wrapper: ->(type_info) { "ObservableMax(#{type_info.zig_type})" },
        ast_class: AST::MaxOp,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :typed, gate: :always),
      ),
      min: ObservableTerminalSpec.new(
        wrapper: ->(type_info) { "ObservableMin(#{type_info.zig_type})" },
        ast_class: AST::MinOp,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :typed, gate: :always),
      ),
      any: ObservableTerminalSpec.new(
        wrapper: ->(_type_info) { "ObservableAny()" },
        ast_class: AST::AnyOp,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :pred, gate: :always),
      ),
      all: ObservableTerminalSpec.new(
        wrapper: ->(_type_info) { "ObservableAll()" },
        ast_class: AST::AllOp,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :pred, gate: :always),
      ),
      find: ObservableTerminalSpec.new(
        # FIND's tense_type is `?T`; AtomicFind stores the unwrapped T.
        wrapper: ->(type_info) { "ObservableFind(#{type_info.wrapped_type.zig_type})" },
        ast_class: AST::FindOp,
        publish: ObservablePublishSpec.new(publish_method: "submit", expr: :item, gate: :pred),
      ),
      reduce: ObservableTerminalSpec.new(
        # REDUCE has its own lower_range_reduce_observable helper because
        # the user-supplied reducer body references stage-context (`_`
        # and `acc`) which the default publish recipe can't express.
        wrapper: ->(type_info) { "ObservableReduce(#{type_info.zig_type})" },
      ),
      distinct: ObservableTerminalSpec.new(
        # DISTINCT's tense_type is `T[]@set` (dynamic) or `T[N]@set`
        # (bounded). Dynamic uses geometric-doubling StreamSet; bounded
        # uses fixed-capacity StreamSetBounded (no grow, no refcounted
        # snapshots, [N]T buffer never relocates). Has its own
        # lower_range_fold_observable_distinct helper.
        wrapper: ->(type_info) {
          elem = type_info.element_type.zig_type
          if type_info.fixed?
            "ObservableStreamSetBounded(#{elem}, #{type_info.capacity})"
          else
            "ObservableStreamSet(#{elem})"
          end
        },
      ),
    }.freeze, T.nilable(T::Hash[Symbol, ObservableTerminalSpec]))
  end

  # Backwards-compat shim: pre-A3 callers indexed `OBSERVABLE_WRAPPERS[sym]`
  # to get the wrapper builder. Keep the hash exposed so external callers
  # (and the existing observable_wrapper_zig method) can continue to
  # work without rewriting. Lazy via class method for the same load-order
  # reason as observable_terminals.
  sig { returns(T::Hash[Symbol, T.proc.params(type_info: Type).returns(String)]) }
  def self.observable_wrappers
    T.must(@observable_wrappers = T.let(observable_terminals.transform_values(&:wrapper).freeze, T.nilable(T::Hash[Symbol, T.proc.params(type_info: Type).returns(String)])))
  end
  sig { params(tense_type: Type).returns(String) }
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
    builder = self.class.observable_wrappers[terminal] or
      raise CompilerError.new(
        nil,
        "Internal: unknown observable terminal kind #{terminal.inspect}. " \
        "Add an entry to Type.observable_terminals in src/ast/type.rb.",
        nil,
      )
    builder.call(tense_type)
  end

  # Preferred predicate name for ~T / stream-like future values.
  sig { returns(T::Boolean) }
  def future?
    tense?
  end

  sig { returns(Type) }
  def tense_type
    Type.new(shape.tense_type_raw || :Void)
  end

  # Finite dynamic stream: ~T[].
  # Used for lazy finite producers like ranges. NEXT returns ?T until exhausted.
  sig { returns(T::Boolean) }
  def dynamic_stream?
    !!(future? && tense_type.dynamic? && !tense_type.optional? && !list_collection?)
  end

  # New syntax alias: ~?T[] means an open stream of T (NEXT returns ?T).
  # Parsed as future of ?T[] by the general type parser, then reinterpreted here.
  sig { returns(T.nilable(Type)) }
  def optional_stream_shape_type
    return nil unless future? && tense_type.optional?
    wrapped = tense_type.wrapped_type
    wrapped if wrapped&.array?
  end

  sig { returns(T::Boolean) }
  def open_stream_alias?
    shape = optional_stream_shape_type
    shape&.dynamic? || false
  end

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
    elem = if open_stream?
      open_stream_element_type
    elsif dynamic_stream? || bounded_stream?
      tense_type.element_type
    elsif inf_stream?
      inf_stream_element_type
    end
    elem
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
    # ~T[N] is a bounded stream of N elements. ~String is NOT a bounded stream
    # even though String is internally []const u8 (a fixed array) - it's a Promise.
    !!(future? && (
      (tense_type.fixed? && !tense_type.string?) ||
      (optional_stream_shape_type&.fixed? && !T.must(optional_stream_shape_type).string?)
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
    return T.must(optional_stream_shape_type).element_type if open_stream_alias?
    tense_type.element_type
  end

  # Infinite stream: ~T[INF] — a lazy rendezvous generator; NEXT returns T (never nil).
  # Generator and consumer rendezvous on each value: push() blocks until next() reads it.
  # Resource semantics: call deinit() to free the heap-allocated Inner.
  sig { returns(T::Boolean) }
  def inf_stream?
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
    if optional_stream_shape_type&.fixed?
      Type.optional_of(T.must(T.must(optional_stream_shape_type).element_type))
    else
      tense_type.element_type
    end
  end

  # The capacity N in ~T[N] / ~?T[N].
  sig { returns(T.untyped) }
  def stream_capacity
    return nil unless bounded_stream?
    optional_stream_shape_type&.capacity || tense_type.capacity
  end

  sig { returns(T.nilable(Type)) }
  def element_type
    return nil unless array?
    # Uses the capture from parse_raw_input, ensuring "Number[3]" becomes "Float64"
    t = Type.new(shape.element_type_raw || :Any)
    t.apply_capabilities!(
      ownership: elem_ownership || TypeCapabilities::UNSET,
      sync: elem_sync || TypeCapabilities::UNSET
    )
    t
  end

  sig { params(lookup_arg: T.nilable(Proc), lookup_block: T.untyped).returns(Integer) }
  def slot_size(lookup_arg = nil, &lookup_block)
    resolver = lookup_arg || lookup_block

    # 1. Primitives / Pointers (Heap objects are 1 slot pointers; Rc/Arc/Locked are also pointer-sized)
    # Generic instances (e.g. Id<T>) are intrinsic scalar types — always 1 slot.
    return 1 if scalar_slot?

    # 2. Fixed Arrays (Recursion)
    if fixed?
      fixed_capacity = capacity
      return fixed_capacity * T.must(element_type).slot_size(resolver) if fixed_capacity.is_a?(Integer)
    end

    # 3. Structs (The tricky part)
    if struct?
      raise "Need lookup context for struct size" unless resolver
      schema = resolver.call(resolved)
      return 1 unless schema # Treat unknown/nil schemas as 1 slot (default for pointers/unknown structs)
      # Enum/Union/Resource types — treat as slot size 1.
      return 1 if (Schemas.enum?(schema) || Schemas.union?(schema) || Schemas.resource?(schema))
      # Generic structs: treat as 1 slot (size depends on type args, unknown at this point)
      return 1 if schema.respond_to?(:type_params) && schema.type_params
      return schema.fields.values.sum { |f| f.type.slot_size(resolver) }
    end

    1 # Default
  end

  sig { returns(T::Boolean) }
  def scalar_slot?
    primitive? || heap? || dynamic? || any? || multiowned? || shared? ||
      any_sync? || generic_instance?
  end

  sig { returns(T::Boolean) }
  def requires_move?
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

  sig { params(lookup_arg: T.nilable(Proc), lookup_block: T.untyped).returns(T::Boolean) }
  def copyable?(lookup_arg = nil, &lookup_block)
    return true if primitive?
    return true if string?  # Zig strings ([]const u8) are trivially copyable (pointer + length)
    return false if array?  # Arrays are not explicitly copyable (use slicing or @list)
    return false if multiowned? || shared? || any_sync?  # Rc/Arc/Locked must not be silently copied
    return false if heap?                   # Heap-allocated types are not copyable
    return false if frame? && struct?       # Frame-allocated struct pointers are not copyable
    return false if map?                    # Maps are not copyable

    # Structs: copyable if all fields are copyable (for explicit COPY keyword)
    if struct?
      resolver = lookup_arg || lookup_block
      return false unless resolver
      schema = resolver.is_a?(Proc) ? resolver.call(resolved) : (resolver[resolved] rescue nil)
      return false unless Schemas.struct?(schema)
      return schema.fields.values.all? { |f| f.type.copyable?(resolver) }
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
  sig { params(lookup_arg: T.nilable(Proc), lookup_block: T.untyped).returns(T::Boolean) }
  def bg_capture_is_value_copy?(lookup_arg = nil, &lookup_block)
    # Type-inherent classes that always-copy: primitives, Id<T>, rodata
    # string slices, fixed value arrays.
    return true if escape_class == :value || escape_class == :slice_rodata
    # Schema-aware refinement: at the Type level, enums and
    # unions-without-heap-variants land in :by_ref because Type can't
    # see schema; given a resolver they classify as value-copy.
    return false unless escape_class == :by_ref
    return false unless lookup_arg || lookup_block
    resolver = lookup_arg || lookup_block
    schema = resolver.is_a?(Proc) ? resolver.call(resolved) : (resolver[resolved] rescue nil)
    if schema.nil? && generic_instance?
      schema = resolver.is_a?(Proc) ? resolver.call(generic_base) : (resolver[generic_base] rescue nil)
    end
    return true if Schemas.enum?(schema)
    if Schemas.union?(schema)
      has_heap = (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      return !has_heap
    end
    # Structs (no :kind) deliberately fall through to false — captured by ref.
    false
  end

  # Implicitly copyable: used for branch merge and loop checks.
  # Same as copyable? but excludes user structs — structs need explicit COPY.
  # Primitives, strings, slices, enums, and unions are implicitly copyable.
  sig { params(lookup_arg: T.nilable(Proc), lookup_block: T.untyped).returns(T::Boolean) }
  def implicitly_copyable?(lookup_arg = nil, &lookup_block)
    return true if primitive?
    # Pool Id<T> handles are u64 indices — always Copy.
    return true if id_handle?
    # String literals (rodata) are Copy - static data, never freed.
    return true if string? && rodata?
    # Non-literal strings are NOT Copy - they reference frame/heap data.
    return true if array? && !list_collection? && !pool? && !set_collection? && !string?
    if lookup_arg || lookup_block
      resolver = lookup_arg || lookup_block
      schema = resolver.is_a?(Proc) ? resolver.call(resolved) : (resolver[resolved] rescue nil)
      # For generic instances (Option<Float64>), try the base type (Option)
      if schema.nil? && generic_instance?
        schema = resolver.is_a?(Proc) ? resolver.call(generic_base) : (resolver[generic_base] rescue nil)
      end
      return true if Schemas.enum?(schema)
      # Unions: Copy if no heap variants
      if Schemas.union?(schema)
        has_heap = (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        return !has_heap
      end
      # Structs: Copy if all fields are Copy
      if Schemas.struct?(schema)
        all_copy = schema.fields.all? do |_, v|
          ft = v.type
          ft = substitute_generic_schema_field_type(ft, schema)
          ft.implicitly_copyable?(resolver)
        end
        return true if all_copy
      end
    end
    false
  end

  # ── Recursive type analysis (mirrors Zig comptime functions) ──────

  sig { params(schema_lookup: T.nilable(Proc), seen: T.nilable(T::Set[String])).returns(T::Boolean) }
  def recursive_cleanup_shape?(schema_lookup = nil, seen = nil)
    seen ||= Set.new
    key = type_id.key
    return false if seen.include?(key)
    seen.add(key)

    return false if borrowed_reference?
    return wrapped_type&.recursive_cleanup_shape?(schema_lookup, seen) || false if optional?
    return true if string? || any_rc? || link? || collection? || indirect? || future?

    if array?
      return true unless fixed?
      et = element_type
      return false unless et
      return Type.from_node(et)&.recursive_cleanup_shape?(schema_lookup, seen) || false
    end

    return false unless schema_lookup
    schema = schema_lookup.call(resolved) rescue nil
    if Schemas.union?(schema)
      return (schema.variants || {}).any? do |_, vt|
        next false unless vt
        if Schemas.inline_struct?(vt)
          vt.fields.any? do |_, ft|
            ft.recursive_cleanup_shape?(schema_lookup, seen)
          end
        else
          vt.recursive_cleanup_shape?(schema_lookup, seen)
        end
      end
    end

    if Schemas.field_bearing?(schema)
      return schema.fields.any? do |_, field|
        next false if field.borrowed
        field_type = substitute_generic_schema_field_type(field.type, schema)
        field_type.recursive_cleanup_shape?(schema_lookup, seen)
      end
    end

    false
  end

  # Mirror of Zig's needsPromotion. Returns true if this type contains
  # frame-allocated data that must be duped to heap on escape.
  # Recurses into struct fields and union variants.
  # Mirror of Zig's needsPromotion comptime predicate.
  # Returns true if this type contains frame-arena data that must be
  # duped to heap before returning from a function.
  sig { params(schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def needs_promotion?(schema_lookup = nil)
    return true if string? || list_collection? || (map? && !numeric_map?)
    if schema_lookup
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Schemas::UnionSchema) || (Schemas.union?(schema))
        return schema_union_any?(schema) { |t| t.needs_promotion?(schema_lookup) }
      elsif Schemas.struct?(schema)
        return schema_struct_any?(schema) { |t| t.needs_promotion?(schema_lookup) }
      end
    end
    false
  end

  # Mirror of Zig's needsCleanup. Returns true if this type owns
  # heap-allocated data that must be freed at scope exit.
  # Same as needs_promotion? but excludes bare strings (freed by
  # StringMap.freeUnionPayload inside collections, not at top level).
  # Plus: RC, NumericMap, Pool, Set.
  sig { params(schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def needs_cleanup?(schema_lookup = nil)
    return false if borrowed_reference?
    if optional?
      inner = wrapped_type
      return inner ? (inner.needs_cleanup?(schema_lookup) || inner.string?) : false
    end
    if non_string_array?
      return true unless fixed?
      et = element_type
      return false unless et
      elem_t = Type.from_node(et)
      return !!(elem_t && elem_t.needs_cleanup?(schema_lookup))
    end

    return true if any_rc? || link? || resource? || collection? || future? || (string? && heap?) ||
                   any_sync? ||
                   (respond_to?(:indirect?) && indirect?)
    if schema_lookup
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Schemas::UnionSchema) || (Schemas.union?(schema))
        return schema_union_any?(schema) { |t| t.needs_cleanup?(schema_lookup) }
      elsif Schemas.struct?(schema)
        return schema_struct_any?(schema) { |t| substitute_generic_schema_field_type(t, schema).needs_cleanup?(schema_lookup) }
      end
    end
    false
  end

  sig { params(schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def ownership_bearing?(schema_lookup = nil)
    ti = success_type || self
    return false if ti.primitive? || ti.void? || ti.any?

    ti.string? ||
      ti.future? ||
      ti.stream? ||
      ti.heap_ptr? ||
      ti.needs_cleanup?(schema_lookup) ||
      ti.recursive_cleanup_shape?(schema_lookup)
  end

  # Does this type+allocator combination need explicit cleanup at scope exit?
  # For frame-allocated values, only types with heap internals (RC, resources,
  # mutexes) need cleanup -- the frame arena bulk-frees everything else.
  # For heap-allocated values, all non-Copy types need cleanup.
  #
  # This is the ownership-aware version of needs_cleanup?. It answers:
  # "if this variable is :live at scope exit, must we emit a defer?"
  sig { params(allocator: Symbol, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def needs_explicit_cleanup?(allocator, schema_lookup = nil)
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
      schema = schema_lookup.call(resolved) rescue nil
      if Schemas.union?(schema)
        return (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      elsif Schemas.struct?(schema)
        return schema_struct_any?(schema) do |t|
          ft = substitute_generic_schema_field_type(t, schema)
          ft.any_rc? || ft.link? || ft.any_sync? || ft.resource?
        end
      end
    end

    false
  end

  # Check if collection elements have heap internals (RC, resource, etc.)
  sig { params(schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def elem_has_heap_internals?(schema_lookup = nil)
    et = element_type
    return false unless et
    t = et.is_a?(Type) ? et : (Type.new(et) rescue nil)
    return false unless t
    return true if t.any_rc? || t.link? || t.any_sync? || t.resource?
    # Check struct/union element types via schema
    if schema_lookup
      schema = schema_lookup.call(t.resolved) rescue nil
      if Schemas.union?(schema)
        return (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      elsif Schemas.struct?(schema)
        return schema_struct_any?(schema) { |ft| ft.any_rc? || ft.link? || ft.any_sync? || ft.resource? }
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
  sig { params(schema_lookup: T.nilable(Proc)).returns(Symbol) }
  def cleanup_allocator(schema_lookup = nil)
    return :heap if heap_cleanup_allocator?
    if schema_lookup
      schema = schema_lookup.call(resolved) rescue nil
      if Schemas.struct?(schema)
        return :heap if schema_struct_any?(schema) { |t| t.link? || t.any_rc? || t.string? }
      elsif Schemas.union?(schema)
        return :heap if (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
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
  sig { params(vt: T.untyped).returns(T::Boolean) }
  def self.variant_has_heap?(vt)
    return false unless vt
    if Schemas.inline_struct?(vt)
      fields = vt.fields
      return fields.any? { |_, ft|
        ft.heap_ptr?
      }
    end
    vt.heap_ptr?
  end

  # Safely extract a normalized Type from any AST/MIR node or raw type value.
  # Returns nil if no type_info is available or conversion fails.
  # Replaces the repeated inline pattern:
  #   ti = node.full_type rescue nil
  #   ti = Type.new(ti) if ti && !ti.is_a?(Type)
  sig { params(node: T.untyped).returns(T.nilable(Type)) }
  def self.from_node(node)
    return nil unless node
    t = node.respond_to?(:full_type) ? node.full_type : node
    return nil unless t
    return t if t.is_a?(Type)
    begin
      Type.new(t)
    rescue StandardError
      nil
    end
  end

  sig { params(node: T.untyped, context: String).returns(Type) }
  def self.from_node!(node, context: "post-annotation MIR")
    t = from_node(node)
    raise "#{context}: missing type info for #{node.class}" unless t
    raise "#{context}: unresolved type info for #{node.class}" if t.untyped?
    t
  end

  # Returns the Zig type string representation of this type.
  # Memoized for performance; cache is invalidated when location changes.
  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  def zig_type(is_param: false, is_field: false)
    return compute_zig_type(is_param: is_param, is_field: is_field) if is_param || is_field
    @zig_type_cache ||= compute_zig_type
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

  sig { params(field_type: Type, schema: T.untyped).returns(Type) }
  def substitute_generic_schema_field_type(field_type, schema)
    return field_type unless generic_instance?
    params = schema.respond_to?(:type_params) ? schema.type_params : nil
    args = generic_args
    return field_type unless params.respond_to?(:zip) && args

    subst = T.let({}, T::Hash[Symbol, Type])
    params.zip(args).each do |param, arg|
      next unless param && arg

      subst[param.to_sym] = arg.is_a?(Type) ? arg : Type.new(arg)
    end
    subst[field_type.resolved] || field_type
  end

  # True if any struct field in schema satisfies the block (block receives Type).
  # Skips metadata (Symbol) keys; unwraps {:type => T} field hashes.
  sig { params(schema: T.nilable(Object), blk: T.proc.params(t: Type).returns(T::Boolean)).returns(T::Boolean) }
  def schema_struct_any?(schema, &blk)
    fields = schema.is_a?(Schemas::StructSchema) ? schema.fields : {}
    fields.any? { |_, v|
      t = v.type
      if v.borrowed
        t = Type.new(t)
        t.mark_borrowed_reference!
      end
      blk.call(t)
    }
  end

  # True if any non-Hash union variant in schema satisfies the block (block receives Type).
  # Skips nil and Hash variants (inline_struct/indirect); caller handles those via
  # Type.variant_has_heap? when needed.
  sig { params(schema: T.untyped, blk: T.proc.params(t: Type).returns(T::Boolean)).returns(T::Boolean) }
  def schema_union_any?(schema, &blk)
    variants = Schemas.union?(schema) ? schema.variants : {}
    variants.any? { |_, vt|
      next false unless vt
      next false if Schemas.inline_struct?(vt)
      (blk.call(vt)) rescue false
    }
  end

  # Structural match for function/lambda types. Called by accepts? when self.fn_type?.
  sig { params(other_type: Type).returns(T::Boolean) }
  def accepts_fn_type?(other_type)
    return true if other_type.any?
    return false unless other_type.fn_type?
    other_raw = other_type.raw
    return false unless other_raw.is_a?(FunctionSignature)
    self_raw = T.cast(raw, FunctionSignature)

    self_params  = self_raw.params
    other_params = other_raw.params
    return false unless self_params.length == other_params.length

    # raw / other_raw are FunctionSignature (fn_type? gate); their
    # return_type is a non-nil Type by the FunctionSignature seam.
    return false unless self_raw.return_type.accepts?(other_raw.return_type)

    self_params.zip(other_params).each do |sp, op|
      sp_t = sp.type
      op_t = T.must(op).type
      return false unless sp_t.accepts?(op_t)
    end

    # Reentrant constraint: a @reentrant function cannot be passed to a parameter
    # that doesn't explicitly allow it (i.e., the param type lacks @reentrant).
    return false if other_raw.reentrant && !self_raw.reentrant

    true
  end

  # Promise/Stream coercion. Called by accepts? when self.future?.
  sig { params(other_type: Type).returns(T::Boolean) }
  def accepts_future?(other_type)
    # ~T[]@list accepts [] or another ~T[]
    return true if promise_list? && (other_type.empty_list? || (other_type.future? && other_type.tense_type.dynamic?))
    return false unless other_type.future?

    if dynamic_stream? && other_type.dynamic_stream?
      se = tense_type.element_type; oe = other_type.tense_type.element_type
      return se.accepts?(oe) if se && oe
    end
    if open_stream? && other_type.open_stream?
      se = open_stream_element_type; oe = other_type.open_stream_element_type
      return se.accepts?(oe) if se && oe
    end
    # ~T[INF] accepts ~?T[] and vice versa: BG STREAM infers open-stream syntax,
    # declared type picks the runtime wrapper. Match on element type only.
    if (inf_stream? && other_type.open_stream?) || (open_stream? && other_type.inf_stream?)
      se = inf_stream? ? inf_stream_element_type : open_stream_element_type
      oe = other_type.inf_stream? ? other_type.inf_stream_element_type : other_type.open_stream_element_type
      return se.accepts?(oe) if se && oe
    end

    tense_type.accepts?(other_type.tense_type)
  end

  # Array coercion. Called by accepts? when self.array?.
  sig { params(other_type: Type).returns(T::Boolean) }
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
      return T.cast(other_capacity, Integer) <= T.cast(self_capacity, Integer)
    end
    dynamic? && other_type.dynamic?
  end

  sig { params(raw_input: Object, auto: T::Boolean).void }
  def parse_raw_input(raw_input, auto: false)
    if raw_input.is_a?(FunctionSignature) || raw_input.is_a?(Array)
      @shape = TypeShape.new(raw: raw_input, auto: auto)
      @capabilities = AFFINE_CAPABILITIES
      return
    end

    raw_str = raw_input.to_s
    normalized_str = if raw_input == :Number || raw_str == "Number"
      "Float64"
    elsif raw_str.include?("Number")
      raw_str.gsub(/\bNumber\b/, 'Float64')
    else
      raw_str
    end

    suffix = normalized_str.include?("<") ? TypeCapabilitySuffix.new(base: normalized_str, ownership: nil, sync: nil) : self.class.strip_capability_suffix_from(normalized_str)
    @shape = TypeShape.from_core(suffix.base, auto: auto)
    if suffix.ownership || suffix.sync
      @capabilities = AFFINE_CAPABILITIES
      apply_capabilities!(ownership: suffix.ownership || :affine, sync: suffix.sync, collection: nil)
    else
      @capabilities = AFFINE_CAPABILITIES
    end
  end

  sig { returns(String) }
  def semantic_shape_key
    return function_type_key if fn_type?

    Type.surface_name(self)
  end

  sig { returns(String) }
  def function_type_key
    sig = T.cast(raw, FunctionSignature)
    params_key = sig.params.map { |param| param.type.semantic_type_key }.join(",")

    "fn(#{params_key})->#{sig.return_type.semantic_type_key};reentrant=#{sig.reentrant}"
  end

  sig { params(str: String).returns(TypeCapabilitySuffix) }
  def self.strip_capability_suffix_from(str)
    unless str.include?("@")
      return TypeCapabilitySuffix.new(base: str, ownership: nil, sync: nil)
    end

    base, *caps = str.gsub(/\s+/, "").split("@")
    ownership = T.let(nil, T.nilable(Symbol))
    sync = T.let(nil, T.nilable(Symbol))
    caps.flat_map { |cap| cap.split(":") }.each do |cap|
      case cap
      when "shared" then ownership = :shared
      when "multiOwned", "multiowned" then ownership = :multiowned
      when "link" then ownership = :link
      when "split" then ownership = :split
      when "frozen" then ownership = :frozen
      when "locked" then sync = :locked
      when "writeLocked", "writelocked" then sync = :write_locked
      when "versioned" then sync = :versioned
      when "atomic" then sync = :atomic
      when "local" then sync = :local
      when "alwaysMutable", "alwaysmutable" then sync = :always_mutable
      end
    end

    TypeCapabilitySuffix.new(base: T.must(base), ownership: ownership, sync: sync)
  end

  sig { params(str: String).returns(TypeCapabilitySuffix) }
  def strip_capability_suffix(str)
    self.class.strip_capability_suffix_from(str)
  end

  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  def tense_zig_type(is_param:, is_field:)
    if tense_observable? && !promise_list?
      return "*CheatLib.obs.#{observable_wrapper_zig(tense_type)}"
    end
    if promise_list?
      elem_zig = T.must(tense_type.element_type).zig_type(is_param: is_param, is_field: is_field)
      return "std.ArrayListUnmanaged(CheatLib.Promise(#{elem_zig}))"
    end
    if bounded_stream?
      elem_zig = T.must(stream_element_type).zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.BoundedStream(#{elem_zig}, #{stream_capacity})"
    end
    if dynamic_stream?
      inner_t = tense_type.element_type
      return case inner_t&.resolved
             when :Int64 then "CheatLib.IntRange"
             when :Float64 then "CheatLib.Range"
             else
              "CheatLib.Stream(#{T.must(inner_t).zig_type(is_param: is_param, is_field: is_field)})"
             end
    end
    if shared_promise?
      inner_zig = tense_type.zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.SharedPromise(#{inner_zig})"
    end
    if split_open_stream?
      elem_zig = T.must(open_stream_element_type).zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.SplitStream(#{elem_zig})"
    end
    if open_stream?
      elem_zig = T.must(open_stream_element_type).zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.Stream(#{elem_zig})"
    end
    if inf_stream?
      elem_zig = T.must(inf_stream_element_type).zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.InfStream(#{elem_zig})"
    end

    inner_zig = tense_type.zig_type(is_param: is_param, is_field: is_field)
    "CheatLib.Promise(#{inner_zig})"
  end

  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(T.nilable(String)) }
  def capability_wrapped_zig_type(is_param:, is_field:)
    return nil unless (ownership != :affine || any_sync?) && !(map? && striped? && ownership == :affine)

    inner_zig = capability_inner_zig_type(is_param: is_param, is_field: is_field)

    if atomic_pointer_wrapped?
      return "*#{inner_zig}"
    end

    case ownership
    when :multiowned
      "CheatLib.Rc(#{inner_zig})"
    when :shared
      "CheatLib.Arc(#{inner_zig})"
    when :link
      source = link_source
      source == :shared ? "CheatLib.WeakArc(#{inner_zig})" : "CheatLib.WeakRc(#{inner_zig})"
    else
      return nil if map? && striped?

      "*#{inner_zig}"
    end
  end

  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  def capability_inner_zig_type(is_param:, is_field:)
    if map? && striped?
      bare = Type.new(resolved.to_s)
      bare.apply_capabilities!(shard_count: shard_count, sync: sync, ownership: :affine)
      return bare.zig_type(is_param: is_param, is_field: is_field)
    end

    inner_zig = if fixed_soa?
      base_zig = T.must(element_type).zig_type(is_param: is_param, is_field: is_field)
      "CheatLib.SoaList(#{base_zig})"
    else
      bare_data_type.zig_type(is_param: is_param, is_field: is_field)
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
  def map_zig_type
    val_zig = value_type.zig_type
    if striped?
      if numeric_map?
        key_zig = key_type.zig_type
        return "CheatLib.StripedNumericMap(#{key_zig}, #{val_zig}, #{shard_count})"
      end
      return "CheatLib.MutexShardedStringMap(#{val_zig}, #{shard_count})" if locked?

      return "CheatLib.ShardedStringMap(#{val_zig}, #{shard_count})"
    end
    if sharded?
      if numeric_map?
        key_zig = key_type.zig_type
        return "CheatLib.PartitionedNumericMap(#{key_zig}, #{val_zig}, #{shard_count})"
      end
      return "CheatLib.PartitionedStringMap(#{val_zig}, #{shard_count})"
    end
    if numeric_map?
      key_zig = key_type.zig_type
      return "CheatLib.NumericMapType(#{key_zig}, #{val_zig})"
    end

    "CheatLib.StringMap(#{val_zig})"
  end

  # Computes the Zig type string for this CHEAT type.
  # Handles: error unions, optionals, multiowned (Rc), pointers, arrays, hashmaps, primitives, structs.
  sig { params(is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  def compute_zig_type(is_param: false, is_field: false)
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

    # 1. Handle Error Union: !T -> !zig_type
    if error_union?
      inner_zig = error_union_payload_with_outer_capabilities.zig_type(is_param: is_param, is_field: is_field)
      return "!#{inner_zig}"
    end

    # 2. Handle Optional: ?T -> ?zig_type
    if optional?
      inner_zig = T.must(wrapped_type).zig_type(is_param: is_param, is_field: is_field)
      return "?#{inner_zig}"
    end

    # @indirect is a heap-pinned cell boxed by a single HeapCreate, so its
    # Zig type must be exactly one pointer level around the bare pointee for
    # every type uniformly (the String/slice path below otherwise drops it).
    if plain_indirect_value?
      pointee = Type.new(self)
      pointee.strip_layout!
      pointee.mark_stack_value!
      return "*#{pointee.zig_type(is_param: is_param, is_field: is_field)}"
    end

    # 2c. Function type: FN(T, ...) -> R  =>  *const fn(*Runtime, T, ...) anyerror!R
    if fn_type?
      fn_raw = T.cast(raw, FunctionSignature)
      param_types_zig = fn_raw.params.map do |p|
        t = p.type
        t.is_a?(Type) ? t.zig_type(is_param: true) : Type.new(t).zig_type(is_param: true)
      end
      ret_zig = fn_raw.return_type.zig_type
      all_params = ["*Runtime"] + param_types_zig
      ret_str = ZigType.new(ret_zig).anyerror_return_type
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
    if resolved == :String || string?
      return "[]const u8"
    end

    # 3b. Handle Pool / ShardedPool collection
    if pool?
      base_zig = T.must(element_type).zig_type(is_param: is_param, is_field: is_field)
      if soa?
        return "CheatLib.SoaPool(#{base_zig})"
      end
      return sharded? ? "CheatLib.ShardedPool(#{base_zig}, #{shard_count})" : "CheatLib.Pool(#{base_zig})"
    end

    # 3c. Handle @set collection
    if set_collection?
      base_zig = T.must(element_type).zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.Set(#{base_zig})"
    end

    # 3d. Handle @list / ShardedList / SoaList collection
    if list_collection?
      base_zig = T.must(element_type).zig_type(is_param: is_param, is_field: is_field)
      if soa?
        return "CheatLib.SoaList(#{base_zig})"
      end
      return sharded? ? "CheatLib.ShardedList(#{base_zig}, #{shard_count})" : "std.ArrayListUnmanaged(#{base_zig})"
    end

    # 3e. Handle fixed SOA arrays (T[N]@soa — no @pool/@list wrapper)
    if fixed_soa?
      base_zig = T.must(element_type).zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.SoaList(#{base_zig})"
    end

    # 4. Handle Arrays recursively
    #    Dynamic arrays use ArrayListUnmanaged only for local variables to support growth.
    #    Struct fields and function parameters use slices.
    if array?
      base_zig = T.must(element_type).zig_type(is_param: is_param, is_field: is_field)
      if dynamic? && !is_param && !is_field
        # Dynamic arrays (ArrayListUnmanaged) are always value-typed locals.
        # The list header is a struct value; the backing store lives on the heap internally.
        # heap? provenance means the backing store is heap-managed, NOT that the header
        # itself is a pointer. Never apply *-prefix here.
        return "std.ArrayListUnmanaged(#{base_zig})"
      elsif fixed?
        zig = "[#{capacity}]#{base_zig}"
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
    if generic_instance?
      return "u64" if id_handle?
      args_zig = shape.generic_args_raw.map { |a| Type.new(a).zig_type }.join(", ")
      return "#{shape.generic_base_raw}(#{args_zig})"
    end

    # 6. Map primitives and builtins to Zig types; user types pass through.
    ZIG_TYPE_MAP[resolved] || resolved.to_s
  end
end

# ==========================================
# TYPE CHECKING & AUTOCAST LOGIC
# ==========================================
module TypeHelper
    extend T::Sig

  # Coerce input to Type object if needed
  sig { params(input: T.untyped).returns(Type) }
  def to_type(input)
    input.is_a?(Type) ? input : Type.new(input)
  end

  sig { params(source_type: T.untyped, target_type: T.untyped).returns(T::Boolean) }
  def is_safe_autocast?(source_type, target_type)
    to_type(target_type).accepts?(to_type(source_type))
  end

  # Called after coercion context is known for integer literals and constant-foldable
  # unary negations (e.g. -200). Errors if the value does not fit in the effective
  # target type. No-op for non-integer or non-literal nodes.
  sig { params(node: T.untyped, effective_type: T.untyped).returns(NilClass) }
  def check_prefixed_int_range!(node, effective_type)
    T.bind(self, SemanticAnnotator) rescue nil
    val = if node.is_a?(AST::Literal) && (node.type == :PREFIXED_INT || node.type == :INT64)
      node.value
    elsif AST.negative_integer_literal?(node)
      -node.right.value
    else
      return
    end
    # Unwrap error unions so fallible integer returns range-check against the
    # underlying payload type.
    if effective_type.respond_to?(:error_union?) && effective_type.error_union? &&
       effective_type.respond_to?(:payload_type)
      effective_type = effective_type.payload_type
    end
    t = effective_type.respond_to?(:resolved) ? effective_type.resolved : effective_type&.to_sym
    max = Type::INT_TYPE_MAX[t]
    return if max.nil?  # Not a known integer type; let type checker handle the mismatch
    min = Type::INT_TYPE_MIN[t] || 0
    if val < min || val > max
      if respond_to?(:emit_int_overflow_error!)
        emit_int_overflow_error!(node, val, t, min, max)
      else
        error!(node, :INT_LITERAL_OVERFLOW, val: val, type: t, min: min, max: max)
      end
    end
  end

end

# Loaded after `class Type` is fully defined so the
# function_signature -> function_return -> type require cycle resolves
# with `Type` already present (function_return's `const :fixed,
# T.nilable(Type)` evaluates at class-body time). All Type refs to
# FunctionSignature are runtime-lazy (method bodies), so deferring
# this require is safe.
require_relative "../annotator/helpers/function_signature"

class Type
  sig { returns(T.nilable(FunctionSignature)) }
  def function_signature
    current_raw = raw
    current_raw if current_raw.is_a?(FunctionSignature)
  end
end
