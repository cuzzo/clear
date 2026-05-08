# typed: true
require "sorbet-runtime"

require_relative "../annotator-helpers/function_signature"

# Result struct for binary operation type resolution
BinaryOpResult = Struct.new(:type, :left_coercion, :right_coercion, :storage, :error, keyword_init: true)

class Type
    extend T::Sig

  attr_reader :raw, :name, :generic_args, :capacity
  attr_accessor :ownership   # :affine (default), :multiowned (Rc), :shared (Arc), :split (shared replay stream)
  attr_accessor :sync        # nil (default), :locked, :write_locked, :versioned, :atomic, :always_mutable, :local, :raw, :symbol
  attr_accessor :layout      # nil (default), :indirect — heap-pinned cell with stable address (e.g., @indirect:atomic = AtomicPtr(T))
  attr_accessor :lock_rank   # nil (default) or Integer — @locked(rank: N) / @writeLocked(rank: N)
  attr_accessor :collection  # nil (default), :list (explicit heap list), :pool (generational pool)
  attr_accessor :shard_count  # nil (no sharding) or Integer >= 2 (@pool:sharded(N) / @list:sharded(N) / HashMap:sharded(N))
  attr_accessor :soa          # true when @pool:soa or @list:soa — Structure of Arrays layout
  attr_accessor :elem_ownership # Element-level ownership: T@shared[] = Array<Arc<T>>
  attr_accessor :elem_sync      # Element-level sync: T@locked[] = Array<Locked<T>>
  attr_accessor :link_source    # :shared or :multiowned — tracks which strong ref @link was created from
  attr_writer :is_resource      # set by annotator; read internally as @is_resource in #resource?
  attr_accessor :is_observable  # true on ~T@observable — backed by single-writer snapshot / atomic accumulator
  attr_accessor :observable_terminal  # :sum/:count/:max/:min/:avg/:any/:all/:find/:reduce — picks the Zig wrapper
  attr_accessor :observable_token   # A20: source token for the `@observable` capability, used by I1's fixable to offer to delete it
  attr_accessor :polymorphic_shared # true for `SHARED T`: shared-family polymorphic contract, not concrete Arc syntax

  # Unified provenance: where was this data allocated?
  #   :rodata — string literal in binary, valid forever, never freed
  #   :frame  — frame arena, reclaimed on function exit
  #   :heap   — heap allocated, must be explicitly freed
  #   :borrow — borrowed reference, caller owns data, no cleanup needed
  #   nil     — stack (primitives, small structs); no allocation needed
  attr_accessor :provenance

  # String type constants
  STRING_TYPE = :String
  HEAP_STRING_TYPE = :String

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
        return BinaryOpResult.new(type: :Bool)
      else
        auto_t = Type.new(:Auto, auto: true)
        return BinaryOpResult.new(type: auto_t)
      end
    end

    t_left = left_type&.resolved
    t_right = right_type&.resolved

    case op
    when :AND, :OR
      BinaryOpResult.new(type: :Bool)

    when *BOOL_RESULT_OPS
      BinaryOpResult.new(type: :Bool)

    when *NUMBER_RESULT_OPS
      resolve_numeric_op(t_left, t_right)

    when :ADD
      resolve_add_op(t_left, t_right, left_type, right_type)

    when :WRAP_ADD, :CHECK_ADD
      resolve_numeric_op(t_left, t_right)

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
  sig { params(source_type: Type, target_type: T.untyped).returns(T.nilable(String)) }
  def self.coerce_error(source_type, target_type)
    source = source_type.is_a?(Type) ? source_type : Type.new(source_type)
    target = target_type.is_a?(Type) ? target_type : Type.new(target_type)

    # Gradual-typing tolerance: an Auto target accepts any source —
    # the AutoUnifier resolves the target's concrete type after the
    # body walk, mutating the decl in place. Source-side Auto is
    # similarly tolerated: the source expression's resolved type
    # propagates once the unifier pins the slot it depends on.
    return nil if target.respond_to?(:auto?) && target.auto?
    return nil if source.respond_to?(:auto?) && source.auto?

    return nil if target.accepts?(source)

    if target.array_overflow?(source)
      "Cannot initialize array of size #{target.capacity} with #{source.capacity} elements"
    else
      "Type Mismatch: Cannot assign #{source.resolved} to #{target.resolved}"
    end
  end

  private

  sig { params(t_left: Symbol, t_right: Symbol).returns(BinaryOpResult) }
  def self.resolve_numeric_op(t_left, t_right)
    lt = t_left.is_a?(Type) ? t_left : Type.new(t_left)
    rt = t_right.is_a?(Type) ? t_right : Type.new(t_right)

    # Same type: result is that type
    if t_left == t_right
      return BinaryOpResult.new(type: t_left)
    end

    # Both integers: promote to the wider type (use Int64 as default)
    if lt.integer? && rt.integer?
      return BinaryOpResult.new(type: :Int64,
        left_coercion: t_left == :Int64 ? nil : :Int64,
        right_coercion: t_right == :Int64 ? nil : :Int64)
    end

    # Both floats: promote to f64
    if lt.float? && rt.float?
      return BinaryOpResult.new(type: :Float64,
        left_coercion: t_left == :Float64 ? nil : :Float64,
        right_coercion: t_right == :Float64 ? nil : :Float64)
    end

    # Mixed int/float: promote integer operand to the float type
    if lt.integer? && rt.float?
      return BinaryOpResult.new(type: t_right, left_coercion: t_right)
    end
    if lt.float? && rt.integer?
      return BinaryOpResult.new(type: t_left, right_coercion: t_left)
    end

    BinaryOpResult.new(type: :Float64)
  end

  sig { params(t_left: Symbol, t_right: Symbol, left_type: Type, right_type: Type).returns(BinaryOpResult) }
  def self.resolve_add_op(t_left, t_right, left_type, right_type)
    lt = t_left.is_a?(Type) ? t_left : Type.new(t_left)
    rt = t_right.is_a?(Type) ? t_right : Type.new(t_right)

    # A. Numeric addition (all int/float types)
    if lt.numeric? && rt.numeric?
      return resolve_numeric_op(t_left, t_right)
    end

    # B. String Concatenation
    if t_left == HEAP_STRING_TYPE || t_right == HEAP_STRING_TYPE
      left_coercion = (t_left != :String && safe_autocast?(t_left, :String)) ? :String : nil
      right_coercion = (t_right != :String && safe_autocast?(t_right, :String)) ? :String : nil
      return BinaryOpResult.new(type: HEAP_STRING_TYPE, left_coercion: left_coercion, right_coercion: right_coercion, storage: :frame)
    end

    # D. Array Concatenation
    if left_type&.array? && right_type&.array?
      return BinaryOpResult.new(type: t_left, storage: :frame)
    end

    BinaryOpResult.new(error: "Cannot add types: #{t_left} and #{t_right}")
  end

  sig { params(from_type: Symbol, to_type: Symbol).returns(T::Boolean) }
  def self.safe_autocast?(from_type, to_type)
    return false if from_type.nil?
    from_t = from_type.is_a?(Type) ? from_type : Type.new(from_type)
    to_t   = to_type.is_a?(Type)   ? to_type   : Type.new(to_type)
    return false if from_t.fn_type? || to_t.fn_type?
    # Any numeric -> any numeric (implicit promotion/narrowing handled by Zig casts)
    return true if from_t.numeric? && to_t.numeric?
    # Original types that can auto-cast to strings
    [:Float64, :Int64, :Bool, :Byte].include?(from_t.resolved)
  end

  public

  sig { params(raw_input: T.untyped, ownership: T.nilable(Symbol), sync: T.nilable(Symbol), layout: T.nilable(Symbol), location: T.nilable(Symbol), collection: T.nilable(Symbol), shard_count: T.nilable(Integer), stripe_count: T.untyped, observable: T.nilable(T::Boolean), observable_terminal: T.nilable(Symbol), auto: T::Boolean).void }
  def initialize(raw_input, ownership: nil, sync: nil, layout: nil, location: nil, collection: nil, shard_count: nil, stripe_count: nil, observable: nil, observable_terminal: nil, auto: false) # stripe_count kept for backwards compat (ignored)
    if raw_input.is_a?(Type)
      # Copy constructor: preserve all parsed state from the source type
      other = raw_input
      @raw                = other.instance_variable_get(:@raw)
      @ownership          = other.ownership
      @sync               = other.sync
      @layout             = other.layout
      @collection         = other.instance_variable_get(:@collection)
      @shard_count        = other.instance_variable_get(:@shard_count)
      @soa                = other.instance_variable_get(:@soa)
      @is_error_union     = other.instance_variable_get(:@is_error_union)
      @payload_type_raw   = other.instance_variable_get(:@payload_type_raw)
      @is_optional        = other.instance_variable_get(:@is_optional)
      @wrapped_type_raw   = other.instance_variable_get(:@wrapped_type_raw)
      @is_array              = other.instance_variable_get(:@is_array)
      @element_type_raw      = other.instance_variable_get(:@element_type_raw)
      @is_map                = other.instance_variable_get(:@is_map)
      @key_type_raw          = other.instance_variable_get(:@key_type_raw)
      @value_type_raw        = other.instance_variable_get(:@value_type_raw)
      @capacity              = other.capacity
      @resolved_cache        = other.instance_variable_get(:@resolved_cache)
      @is_generic_instance   = other.instance_variable_get(:@is_generic_instance)
      @generic_base_raw      = other.instance_variable_get(:@generic_base_raw)
      @generic_args_raw      = other.instance_variable_get(:@generic_args_raw)
      @is_tense              = other.instance_variable_get(:@is_tense)
      @tense_type_raw        = other.instance_variable_get(:@tense_type_raw)
      @elem_ownership        = other.elem_ownership
      @elem_sync             = other.elem_sync
      @link_source           = other.link_source
      @provenance            = other.provenance
      @is_observable         = other.instance_variable_get(:@is_observable)
      @observable_terminal   = other.instance_variable_get(:@observable_terminal)
      @polymorphic_shared    = other.polymorphic_shared
      @is_auto               = other.instance_variable_get(:@is_auto)
    else
      @raw = raw_input
      parse_raw_input
    end

    # Capability fields — set after parse/copy so they can override.
    @provenance = location if location && location != :stack
    @ownership = ownership if ownership
    @sync      = sync      if sync
    @layout    = layout    if layout
    # Sync types need a stable heap address.
    # :raw and :symbol are data-access modes, not locks — they don't force heap provenance.
    @provenance = :heap if @sync && @sync != :raw && @sync != :symbol && @ownership == :affine
    # `:indirect` layout is the explicit "heap-pinned cell with a stable
    # address" form (used by @indirect:atomic = AtomicPtr(T)). Force heap
    # provenance even without an active sync, mirroring the @indirect
    # CapabilityWrap branch in the annotator (annotator.rb:3517).
    @provenance = :heap if @layout == :indirect
    # Symbol strings live in static read-only memory — always rodata, never heap/frame.
    @provenance = :rodata if @sync == :symbol
    # Pool collection always lives on the heap (owns internal slot array).
    if collection
      @collection = collection
      @zig_type_cache = nil
      @provenance = :heap if collection == :pool
    end
    @shard_count = shard_count if shard_count
    @is_observable = true if observable
    @observable_terminal = observable_terminal if observable_terminal
    # Gradual-typing placeholder. When set, this Type represents an
    # unresolved Auto slot — the inference pass (see
    # docs/agents/gradual-typing.md) walks every Auto Type, collects
    # constraints from observed uses, and replaces the Type with a
    # resolved one before the body-validation pass runs.
    # Only overwrite when explicitly requested so the copy-constructor
    # path (`Type.new(other_type)`) preserves auto-ness from `other`.
    @is_auto = true if auto
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
      return @raw == other_t.raw
    end
    resolved == other.to_sym || @raw == other
  end

  sig { returns(String) }
  def to_s; resolved.to_s; end
  sig { returns(Symbol) }
  def to_sym; resolved; end

  # Backward API: Deprecate
  sig { returns(Symbol) }
  def resolved
    # Logic moved from Locatable#resolved_type
    return @resolved_cache if @resolved_cache

    ft = if @raw.is_a?(FunctionSignature); @raw.return_type
         elsif @raw.is_a?(Array); @raw[2]
         else; @raw; end

    @resolved_cache = ft.to_sym
  end

  # Backward API: Deprecate
  sig { returns(Symbol) }
  def base_type
    resolved.to_s.sub(/\[.*\]$/, "").to_sym
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
      inner = other_type.optional? ? other_type.wrapped_type : other_type
      return wrapped_type.accepts?(inner)
    end

    # 4. Error union coercion: !T accepts T or !T
    if error_union?
      inner = other_type.error_union? ? other_type.payload_type : other_type
      return payload_type.accepts?(inner)
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
  sig { params(other_type: Type).returns(T.untyped) }
  def array_overflow?(other_type)
    return false if !other_type.array? || !self.array?
    return false if self.base_type != other_type.base_type
    return false if !other_type.fixed? || !self.fixed?
    return true if other_type.capacity > self.capacity
  end

  # ----------------------------------------------
  # Type Predicates
  # ----------------------------------------------
  SIGNED_INT_TYPES   = [:Int8, :Int16, :Int32, :Int64].freeze
  UNSIGNED_INT_TYPES = [:UInt8, :Byte, :UInt16, :UInt32, :UInt64].freeze
  INT_TYPES          = (SIGNED_INT_TYPES + UNSIGNED_INT_TYPES).freeze
  FLOAT_TYPES        = [:Float32, :Float64].freeze
  NUMERIC_TYPES      = (INT_TYPES + FLOAT_TYPES).freeze

  INT_TYPE_MAX = {
    Byte: 255, UInt8: 255, UInt16: 65_535, UInt32: 4_294_967_295,
    UInt64: (2**64) - 1,
    Int8: 127, Int16: 32_767, Int32: 2_147_483_647, Int64: 9_223_372_036_854_775_807,
  }.freeze
  INT_TYPE_MIN = {
    Byte: 0, UInt8: 0, UInt16: 0, UInt32: 0, UInt64: 0,
    Int8: -128, Int16: -32_768, Int32: -2_147_483_648, Int64: -9_223_372_036_854_775_808,
  }.freeze

  sig { returns(T::Boolean) }
  def numeric?
    NUMERIC_TYPES.include?(resolved)
  end

  sig { returns(T::Boolean) }
  def integer?
    INT_TYPES.include?(resolved)
  end

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

  # Gradual-typing placeholder. True when this Type is an unresolved
  # `Auto` slot waiting for the inference pass to fill it in.
  sig { returns(T::Boolean) }
  def auto?
    !!@is_auto
  end

  # Source-position token for the `Auto` keyword. Set by the parser
  # at the explicit-Auto site so the fix emitter (M1.4) can compute
  # the span when replacing `Auto` with the resolved concrete type.
  # Nil for implicit-Auto (omitted annotation under `--gradual`),
  # which has no source token to point at.
  attr_accessor :auto_token

  sig { returns(T::Boolean) }
  def fn_type?
    @raw.is_a?(FunctionSignature)
  end

  sig { returns(T::Boolean) }
  def array?
    !!@is_array
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
    @provenance == :heap
  end

  sig { returns(T::Boolean) }
  def frame?
    @provenance == :frame
  end

  sig { returns(T::Boolean) }
  def rodata?
    @provenance == :rodata
  end

  # Aliases: provenance predicates (same as heap?/frame?/rodata? now that provenance is authoritative)
  alias heap_provenance?   heap?
  alias frame_provenance?  frame?
  alias rodata_provenance? rodata?

  sig { returns(T::Boolean) }
  def borrow_provenance?
    @provenance == :borrow
  end

  # Returns the allocator symbol for this provenance (:heap or :frame), or nil.
  sig { returns(T.nilable(Symbol)) }
  def provenance_alloc
    case @provenance
    when :heap  then :heap
    when :frame then :frame
    else nil
    end
  end

  # location is provenance (kept as alias for backward-compat callers).
  def location
    @provenance
  end

  sig { returns(T::Boolean) }
  def multiowned?
    @ownership == :multiowned
  end

  sig { returns(T::Boolean) }
  def shared?
    @ownership == :shared
  end

  sig { returns(T::Boolean) }
  def polymorphic_shared?
    !!@polymorphic_shared
  end

  sig { returns(T::Boolean) }
  def frozen?
    @ownership == :frozen
  end

  sig { returns(T::Boolean) }
  def split?
    @ownership == :split
  end

  sig { returns(T::Boolean) }
  def link?
    @ownership == :link
  end

  sig { returns(T::Boolean) }
  def locked?
    @sync == :locked
  end

  sig { returns(T::Boolean) }
  def write_locked?
    @sync == :write_locked
  end

  # MVCC: T@versioned -> Shared(T) (atomic-pointer COW + EBR).
  # Readers see consistent snapshots via `WITH SNAPSHOT x AS y`;
  # writers do optimistic update via `WITH SNAPSHOT x AS MUTABLE y`
  # with `ON MvccConflict ...` for the retries-exhausted case.
  sig { returns(T::Boolean) }
  def versioned?
    @sync == :versioned
  end

  # Atomic single-cell: T@atomic -> Atomic(T) (lock-free CPU-atomic
  # load/store/CAS/fetch_*). v0.2 surface limited to Int64, Float64,
  # Bool primitives. Composes with @shared (Arc<Atomic(T)>) in M1;
  # M2 will drop the Arc and tie the lifetime to declaring scope.
  sig { returns(T::Boolean) }
  def indirect?
    @layout == :indirect
  end

  sig { returns(T::Boolean) }
  def atomic?
    @sync == :atomic
  end

  sig { returns(T::Boolean) }
  def local?
    @sync == :local
  end

  sig { returns(T::Boolean) }
  def raw?
    @sync == :raw
  end

  sig { returns(T::Boolean) }
  def symbol?
    @sync == :symbol
  end

  # True for any sync capability (excludes :raw and :symbol which are data-access modes, not locks)
  sig { returns(T::Boolean) }
  def any_sync?
    !@sync.nil? && @sync != :raw && @sync != :symbol
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
    bare.ownership = :affine
    bare.sync      = nil
    bare.layout    = nil
    bare.instance_variable_set(:@elem_ownership, nil)
    bare.instance_variable_set(:@elem_sync, nil)
    # Provenance was set by sync/ownership wrappers (Type#initialize
    # forces :heap when @sync is set). Stripping the wrappers means the
    # bare shape's provenance must come from its OWN nature (e.g.
    # HashMap is always heap; a plain struct has no forced provenance).
    # Reset; the outer wrap layer that consumes this bare form is
    # responsible for re-pinning.
    bare.provenance = nil
    bare.instance_variable_set(:@zig_type_cache, nil)
    bare
  end

  sig { returns(T::Boolean) }
  def any_rc?
    # SharedPromise uses its own ref-counting internally — it is NOT an Rc/Arc wrapper.
    return false if shared_promise? || split_open_stream?
    multiowned? || shared?
  end

  sig { returns(T::Boolean) }
  def map?
    @is_map
  end

  # True when this is a numeric-keyed map (HashMap<Number,V> or HashMap<Int64,V>).
  # Backed by AutoHashMapUnmanaged — no key duplication, pure arena-allocated.
  sig { returns(T::Boolean) }
  def numeric_map?
    @is_map && @key_type_raw && @key_type_raw != :String
  end

  sig { returns(Type) }
  def key_type
    Type.new(@key_type_raw || :String)
  end

  # True when this is an explicit @pool (generational pool) collection.
  sig { returns(T::Boolean) }
  def pool?
    @collection == :pool
  end

  # True when this is an explicit @list (heap list) collection.
  sig { returns(T::Boolean) }
  def list_collection?
    @collection == :list
  end

  # True when this is an explicit @set (hash set) collection.
  sig { returns(T::Boolean) }
  def set_collection?
    @collection == :set
  end

  # --- Unified collection predicates ---
  # Use these instead of individual map?/pool?/list_collection?/set_collection? checks
  # to ensure new collection types get consistent treatment automatically.

  # True for any collection type (HashMap, @pool, @list, @set).
  sig { returns(T::Boolean) }
  def collection?
    map? || pool? || list_collection? || set_collection?
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
  sig { returns(T.untyped) }
  def fsm_foreach_descriptor
    if pool?
      { kind: :pool_indexed, var_zig_type: element_type&.zig_type || "anyopaque" }
    elsif map?
      # FOR k IN map iterates KEYS. keyIterator yields ?*K, so the
      # bound var dereferences (deref: true).
      { kind: :iterator, init_method: "keyIterator", advance_method: "next",
        deref: true, var_zig_type: key_type.zig_type }
    elsif set_collection?
      # FOR v IN set: keyIterator yields ?*T, so the bound var is
      # the element type (after deref).
      { kind: :iterator, init_method: "keyIterator", advance_method: "next",
        deref: true, var_zig_type: element_type&.zig_type || "anyopaque" }
    elsif list_collection?
      { kind: :indexed_slice, slice_suffix: ".items",
        var_zig_type: element_type&.zig_type || "anyopaque" }
    elsif array? && !dynamic?
      { kind: :indexed_slice, slice_suffix: "",
        var_zig_type: element_type&.zig_type || "anyopaque" }
    elsif array? && dynamic?
      { kind: :indexed_slice, slice_suffix: ".items",
        var_zig_type: element_type&.zig_type || "anyopaque" }
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
    elsif array? && !string?            then :array
    elsif string? && symbol? then :string_symbol
    elsif string? && raw?    then :string_raw
    end
    # Returns nil for non-dispatchable types (plain String, primitives, etc.)
  end

  # Collections that need shared mutable state across call boundaries.
  # Passed by pointer (&) at call sites, use anytype params, tracked in
  # @current_fn_collection_params to prevent double-& in recursive calls.
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
    pool? || sharded? || heap_provenance? || map? || tense_observable?
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

  # True when backing data is frame-allocated and must be promoted to heap
  # before escaping its scope (return, BG capture, etc.).
  # Covers: @list (frame-backed buffer), string HashMap (frame-backed keys/buckets),
  # and strings ([]const u8 slices pointing into the frame arena).
  sig { returns(T::Boolean) }
  def needs_escape_promotion?
    return false if sharded?  # sharded collections are always heap-backed
    list_collection? || (map? && !numeric_map?) || string?
  end

  RESOURCE_TYPES = Set[:File, :TCPClient, :TCPServer].freeze

  # Canonical mapping from CLEAR type symbols to Zig type strings.
  # User-defined types (structs, enums, unions) pass through as-is.
  ZIG_TYPE_MAP = {
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
  }.freeze

  # True when this type is a resource (File, TCPClient, TCPServer, etc.)
  # Checks the explicit flag (set by annotator after resolve_resource_close)
  # and falls back to checking known resource type names.
  sig { returns(T::Boolean) }
  def resource?
    @is_resource || RESOURCE_TYPES.include?(resolved)
  end

  # Resolve the Zig close/deinit statement for resource types.
  # Returns [is_resource, close_zig_template] where close_zig_template uses
  # {0} as placeholder for the variable name. Returns [false, nil] for non-resources.
  #
  # Group 1 / Group 2 separation: when a Group-2 shape (pool/set/...) is
  # wrapped with Group-1 ownership (Arc/Rc), the bare-shape `.deinit()`
  # call doesn't apply against the wrapper. Skip the resource path so the
  # cleanup classifier picks the rc/sync entry instead, which cascades
  # through the wrapper down to the inner shape's destruction.
  sig { params(schema_lookup: T.nilable(Proc)).returns(Array) }
  def resolve_resource_close(schema_lookup = nil)
    return [false, nil] if any_rc?
    return [true, "{0}.deinit(rt.heapAlloc())"] if pool?
    return [true, "{0}.deinit(rt.heapAlloc())"] if set_collection?
    return [true, "{0}.deinit()"] if open_stream? || inf_stream? || split_open_stream?

    return [false, nil] unless schema_lookup
    schema = schema_lookup.call(resolved) rescue nil

    if schema&.dig(:kind) == :resource
      return [true, schema[:close_zig]]
    end

    # Struct with resource fields: compose close statements from fields.
    if schema.is_a?(Hash) && schema[:kind].nil?
      closes = []
      schema.each do |fname, ftype|
        next if fname.is_a?(Symbol)  # skip metadata keys; field names are strings
        f_resolved = Type.new(ftype).resolved
        f_schema = schema_lookup.call(f_resolved) rescue nil
        if f_schema&.dig(:kind) == :resource
          closes << f_schema[:close_zig].gsub("{0}", "{0}.#{fname}")
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
    !@shard_count.nil?
  end

  sig { returns(T::Boolean) }
  def soa?
    !!@soa
  end

  # Fixed-size SOA array without collection wrapper (T[N]@soa).
  sig { returns(T::Boolean) }
  def fixed_soa?
    fixed? && soa? && !collection?
  end

  # A sharded collection with sync capability = lock-striped (skew-safe).
  # Replaces the old :striped(N) keyword — now expressed via composition:
  #   HashMap<V>:sharded(N) @locked → StripedStringMap
  sig { returns(T::Boolean) }
  def striped?
    sharded? && any_sync?
  end

  sig { returns(T.untyped) }
  def value_type
    return nil unless map?
    @value_type_obj ||= Type.new(@value_type_raw || :Any)
  end

  # Generic struct instance: Pair<Number>, Map<String, Number>
  sig { returns(T::Boolean) }
  def generic_instance?
    !!@is_generic_instance
  end

  # The base type name of a generic instance: :"Pair<Number>" → :Pair
  sig { returns(Symbol) }
  def generic_base
    @generic_base_raw
  end

  # The type arguments as Type objects: [Type(:Float64), Type(:String)]
  sig { returns(T.untyped) }
  def generic_args
    return nil unless @is_generic_instance
    @generic_args_obj ||= @generic_args_raw.map { |a| Type.new(a) }
  end

  # TODO: keep metatype from ast, use that
  sig { returns(T::Boolean) }
  def struct?
    !primitive? && !any? && !void? && !string? && !array? && !map? && !optional? && !error_union? && !tense? && !fn_type?
  end

  sig { returns(T::Boolean) }
  def optional?
    @is_optional
  end

  sig { returns(T.untyped) }
  def wrapped_type
    return nil unless optional?
    @wrapped_type_obj ||= Type.new(@wrapped_type_raw || :Any)
  end

  # Error union types: !T (Zig-style error returns)
  sig { returns(T::Boolean) }
  def error_union?
    @is_error_union
  end

  sig { returns(T.untyped) }
  def payload_type
    return nil unless error_union?
    @payload_type_obj ||= Type.new(@payload_type_raw || :Any)
  end

  # Tense (Promise) types: ~T — a background task that will produce T
  sig { returns(T::Boolean) }
  def tense?
    !!@is_tense
  end

  # Observable accumulator: ~T@observable.
  # The runtime backing is a single-writer snapshot (Observable<T>) or atomic
  # accumulator. Only such types may be the target of `WITH VIEW`.
  sig { returns(T::Boolean) }
  def observable?
    !!@is_observable
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
  sig { returns(Hash) }
  def self.observable_terminals
    @observable_terminals ||= {
      sum: {
        wrapper:   ->(t) { "ObservableSum(#{t.zig_type})" },
        ast_class: AST::SumOp,
        publish:   { method: "add", expr: :typed, gate: :always },
      },
      count: {
        wrapper:   ->(_) { "ObservableCount()" },
        ast_class: AST::CountOp,
        publish:   { method: "inc", expr: :none, gate: :pred },
      },
      avg: {
        # AVG view is always f64.
        wrapper:   ->(_) { "ObservableAvg(f64)" },
        ast_class: AST::AverageOp,
        publish:   { method: "add", expr: :f64, gate: :always },
      },
      max: {
        wrapper:   ->(t) { "ObservableMax(#{t.zig_type})" },
        ast_class: AST::MaxOp,
        publish:   { method: "submit", expr: :typed, gate: :always },
      },
      min: {
        wrapper:   ->(t) { "ObservableMin(#{t.zig_type})" },
        ast_class: AST::MinOp,
        publish:   { method: "submit", expr: :typed, gate: :always },
      },
      any: {
        wrapper:   ->(_) { "ObservableAny()" },
        ast_class: AST::AnyOp,
        publish:   { method: "submit", expr: :pred, gate: :always },
      },
      all: {
        wrapper:   ->(_) { "ObservableAll()" },
        ast_class: AST::AllOp,
        publish:   { method: "submit", expr: :pred, gate: :always },
      },
      find: {
        # FIND's tense_type is `?T`; AtomicFind stores the unwrapped T.
        wrapper:   ->(t) { "ObservableFind(#{t.wrapped_type.zig_type})" },
        ast_class: AST::FindOp,
        publish:   { method: "submit", expr: :item, gate: :pred },
      },
      reduce: {
        # REDUCE has its own lower_range_reduce_observable helper because
        # the user-supplied reducer body references stage-context (`_`
        # and `acc`) which the default publish recipe can't express.
        wrapper:   ->(t) { "ObservableReduce(#{t.zig_type})" },
      },
      distinct: {
        # DISTINCT's tense_type is `T[]@set` (dynamic) or `T[N]@set`
        # (bounded). Dynamic uses geometric-doubling StreamSet; bounded
        # uses fixed-capacity StreamSetBounded (no grow, no refcounted
        # snapshots, [N]T buffer never relocates). Has its own
        # lower_range_fold_observable_distinct helper.
        wrapper:   ->(t) {
          elem = t.element_type.zig_type
          if t.fixed?
            "ObservableStreamSetBounded(#{elem}, #{t.capacity})"
          else
            "ObservableStreamSet(#{elem})"
          end
        },
      },
    }.freeze
  end

  # Backwards-compat shim: pre-A3 callers indexed `OBSERVABLE_WRAPPERS[sym]`
  # to get the wrapper builder. Keep the hash exposed so external callers
  # (and the existing observable_wrapper_zig method) can continue to
  # work without rewriting. Lazy via class method for the same load-order
  # reason as observable_terminals.
  sig { returns(Hash) }
  def self.observable_wrappers
    @observable_wrappers ||= observable_terminals.transform_values { |e| e[:wrapper] }.freeze
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
    if @observable_terminal.nil?
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
    builder = self.class.observable_wrappers[@observable_terminal] or
      raise CompilerError.new(
        nil,
        "Internal: unknown observable terminal kind #{@observable_terminal.inspect}. " \
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

  sig { returns(T.untyped) }
  def tense_type
    return nil unless future?
    @tense_type_obj ||= Type.new(@tense_type_raw || :Void)
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
  sig { returns(T.untyped) }
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
  sig { returns(T.untyped) }
  def inf_stream_element_type
    return nil unless inf_stream?
    tense_type.element_type
  end

  # The element type T in ~T[N], or ?T in ~?T[N].
  sig { returns(T.untyped) }
  def stream_element_type
    return nil unless bounded_stream?
    if optional_stream_shape_type&.fixed?
      Type.new(:"?#{T.must(T.must(optional_stream_shape_type).element_type).to_sym}")
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
    @element_type_obj ||= begin
      t = Type.new(@element_type_raw || :Any)
      t.ownership = @elem_ownership if @elem_ownership
      t.sync = @elem_sync if @elem_sync
      t
    end
  end

  sig { params(lookup_arg: T.nilable(Proc), lookup_block: T.untyped).returns(Integer) }
  def slot_size(lookup_arg = nil, &lookup_block)
    resolver = lookup_arg || lookup_block

    # 1. Primitives / Pointers (Heap objects are 1 slot pointers; Rc/Arc/Locked are also pointer-sized)
    # Generic instances (e.g. Id<T>) are intrinsic scalar types — always 1 slot.
    return 1 if primitive? || heap? || dynamic? || any? || multiowned? || shared? || any_sync? || generic_instance?

    # 2. Fixed Arrays (Recursion)
    if fixed?
      return capacity * T.must(element_type).slot_size(resolver)
    end

    # 3. Structs (The tricky part)
    if struct?
      raise "Need lookup context for struct size" unless resolver
      schema = resolver.call(resolved)
      return 1 unless schema # Treat unknown/nil schemas as 1 slot (default for pointers/unknown structs)
      # Enum/Union/Resource types — treat as slot size 1.
      return 1 if schema.is_a?(Hash) && (schema[:kind] == :enum || schema[:kind] == :union || schema[:kind] == :resource)
      # Generic structs: treat as 1 slot (size depends on type args, unknown at this point)
      return 1 if schema.is_a?(Hash) && schema[:type_params]
      # Only sum field entries (string keys). Skip metadata (symbol keys like :type_params, :extern_module).
      return schema.select { |k, _| k.is_a?(String) }.values.sum { |t| Type.new(t).slot_size(resolver) }
    end

    1 # Default
  end

  # TODO: In future, need to be able to call slot-size for small structs.
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
      return false unless schema
      return schema.values.all? { |t| Type.new(t).copyable?(resolver) }
    end

    false
  end

  # Implicitly copyable: used for branch merge and loop checks.
  # Same as copyable? but excludes user structs — structs need explicit COPY.
  # Primitives, strings, slices, enums, and unions are implicitly copyable.
  sig { params(lookup_arg: T.nilable(Proc), lookup_block: T.untyped).returns(T::Boolean) }
  def implicitly_copyable?(lookup_arg = nil, &lookup_block)
    return true if primitive?
    # Pool Id<T> handles are u64 indices — always Copy.
    return true if generic_instance? && generic_base == :Id
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
      return true if schema.is_a?(Hash) && schema[:kind] == :enum
      # Unions: Copy if no heap variants
      if schema.is_a?(Hash) && schema[:kind] == :union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        return !has_heap
      end
      # Structs: Copy if all fields are Copy
      if schema.is_a?(Hash) && !schema[:kind]
        all_copy = schema.all? do |k, v|
          next true if k.is_a?(Symbol) # skip metadata (:type_params etc.)
          ft = v.is_a?(Type) ? v : (v.is_a?(Hash) ? Type.new(v[:type] || :Any) : Type.new(v || :Any))
          ft.implicitly_copyable?(resolver)
        end
        return true if all_copy
      end
    end
    false
  end

  # ── Recursive type analysis (mirrors Zig comptime functions) ──────

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
      if schema.is_a?(Schemas::UnionSchema) || (schema.is_a?(Hash) && schema[:kind] == :union)
        return schema_union_any?(schema) { |t| t.needs_promotion?(schema_lookup) }
      elsif schema.is_a?(Schemas::StructSchema) || (schema.is_a?(Hash) && !schema[:kind])
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
    return true if any_rc? || link? || list_collection? || map? || pool? ||
                   set_collection? || (string? && heap_provenance?) ||
                   (array? && !string?) || any_sync?
    if schema_lookup
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Schemas::UnionSchema) || (schema.is_a?(Hash) && schema[:kind] == :union)
        return schema_union_any?(schema) { |t| t.needs_cleanup?(schema_lookup) }
      elsif schema.is_a?(Schemas::StructSchema) || (schema.is_a?(Hash) && !schema[:kind])
        return schema_struct_any?(schema) { |t| t.needs_cleanup?(schema_lookup) }
      end
    end
    false
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
    return false if string? && !heap_provenance? && allocator == :frame

    # Heap-allocated non-Copy: always needs cleanup
    return true if allocator == :heap

    # Frame-allocated: only if type has heap internals that arena rewind won't handle
    return true if any_rc? || link?       # RC refcount is heap-managed
    return true if any_sync?              # mutex is OS resource
    return true if resource?              # file handle, socket, etc.

    # Frame collections/maps: backing buffer uses frame allocator, arena rewind handles it.
    # UNLESS elements have heap internals (e.g. list of RC pointers).
    if list_collection? || (map? && !numeric_map?) || numeric_map? || pool? || set_collection?
      return elem_has_heap_internals?(schema_lookup)
    end

    # Frame structs/unions: check fields recursively
    if schema_lookup
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Hash) && schema[:kind] == :union
        return (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      elsif schema.is_a?(Hash) && !schema[:kind]
        return schema_struct_any?(schema) { |t| t.any_rc? || t.link? || t.any_sync? || t.resource? }
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
      if schema.is_a?(Hash) && schema[:kind] == :union
        return (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      elsif schema.is_a?(Hash) && !schema[:kind]
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
    return :heap if heap_provenance? || map? || any_rc? || any_sync? ||
                     resource? || sharded? || striped? || link? ||
                     tense_observable?
    if schema_lookup
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Hash) && !schema[:kind]
        return :heap if schema_struct_any?(schema) { |t| t.link? || t.any_rc? || t.string? }
      elsif schema.is_a?(Hash) && schema[:kind] == :union
        return :heap if (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      end
    end
    :frame
  end

  # Check if a union variant type contains heap-allocated data (collections, maps, dynamic arrays).
  # Used to determine if a union needs cleanup.
  sig { params(vt: T.untyped).returns(T::Boolean) }
  def self.variant_has_heap?(vt)
    return false unless vt
    # Single-type payload with @indirect: always heap (stored as *T pointer)
    return true if vt.is_a?(Hash) && vt[:kind] == :indirect_payload
    if vt.is_a?(Hash) && vt[:kind] == :inline_struct
      # Inline struct: check for @indirect fields or string/collection fields
      return true if vt[:indirect_fields]&.any?
      fields = vt[:fields] || {}
      return fields.any? { |_, ft|
        t = ft.is_a?(Type) ? ft : (Type.new(ft) rescue nil)
        t && (t.string? || t.collection? || t.map? || (t.array? && !t.fixed?))
      }
    end
    t = vt.is_a?(Type) ? vt : Type.new(vt) rescue nil
    return false unless t
    (t.collection? || t.map? || t.string? || (t.array? && !t.fixed?)) rescue false
  end

  # Safely extract a normalized Type from any AST/MIR node or raw type value.
  # Returns nil if no type_info is available or conversion fails.
  # Replaces the repeated inline pattern:
  #   ti = node.type_info rescue nil
  #   ti = Type.new(ti) if ti && !ti.is_a?(Type)
  sig { params(node: T.untyped).returns(T.untyped) }
  def self.from_node(node)
    return nil unless node
    t = node.respond_to?(:type_info) ? (node.type_info rescue nil) : node
    return nil unless t
    t.is_a?(Type) ? t : (Type.new(t) rescue nil)
  end

  sig { params(value: Symbol).returns(Symbol) }
  def ownership=(value)
    @zig_type_cache = nil
    @ownership = value
  end

  sig { params(value: T.nilable(Symbol)).returns(T.nilable(Symbol)) }
  def sync=(value)
    @zig_type_cache = nil
    @sync = value
    # :raw and :symbol are data-access modes, not locks — they don't force heap provenance.
    @provenance = :heap if value && value != :raw && value != :symbol && @ownership == :affine
    @provenance = :rodata if value == :symbol
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

  # True if any struct field in schema satisfies the block (block receives Type).
  # Skips metadata (Symbol) keys; unwraps {:type => T} field hashes.
  def schema_struct_any?(schema)
    fields = schema.is_a?(Schemas::StructSchema) ? schema.fields : schema
    fields.any? { |k, v|
      next false if k.is_a?(Symbol)
      ft = v.is_a?(Hash) ? v[:type] : v
      t  = ft.is_a?(Type) ? ft : (Type.new(ft || :Any) rescue nil)
      next false unless t
      yield t
    }
  end

  # True if any non-Hash union variant in schema satisfies the block (block receives Type).
  # Skips nil and Hash variants (inline_struct/indirect); caller handles those via
  # Type.variant_has_heap? when needed.
  def schema_union_any?(schema)
    variants = schema.is_a?(Schemas::UnionSchema) ? schema.variants : (schema[:variants] || {})
    variants.any? { |_, vt|
      next false unless vt
      next false if vt.is_a?(Hash)
      t = vt.is_a?(Type) ? vt : (Type.new(vt) rescue nil)
      next false unless t
      (yield t) rescue false
    }
  end

  # Structural match for function/lambda types. Called by accepts? when self.fn_type?.
  sig { params(other_type: Type).returns(T::Boolean) }
  def accepts_fn_type?(other_type)
    return true if other_type.is_a?(Type) && other_type.any?
    return false unless other_type.is_a?(Type) && other_type.fn_type?
    other_raw = other_type.raw

    self_params  = @raw.params || []
    other_params = other_raw.params || []
    return false unless self_params.length == other_params.length

    self_ret  = @raw.return_type
    other_ret = other_raw.return_type
    self_ret_t  = self_ret.is_a?(Type)  ? self_ret  : Type.new(self_ret  || :Any)
    other_ret_t = other_ret.is_a?(Type) ? other_ret : Type.new(other_ret || :Any)
    return false unless self_ret_t.accepts?(other_ret_t)

    self_params.zip(other_params).each do |sp, op|
      sp_t = sp[:type].is_a?(Type) ? sp[:type] : Type.new(sp[:type] || :Any)
      op_t = op[:type].is_a?(Type) ? op[:type] : Type.new(op[:type] || :Any)
      return false unless sp_t.accepts?(op_t)
    end

    # Reentrant constraint: a @reentrant function cannot be passed to a parameter
    # that doesn't explicitly allow it (i.e., the param type lacks @reentrant).
    return false if other_raw.reentrant && !@raw.reentrant

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
    return other_type.capacity <= capacity if fixed? && other_type.fixed?
    dynamic? && other_type.dynamic?
  end

  sig { returns(T.nilable(Symbol)) }
  def parse_raw_input
    # FunctionSignature and Array raws are function signatures — no string parsing applies.
    # @resolved_cache is left nil and computed on-demand by the resolved() fallback.
    if @raw.is_a?(FunctionSignature) || @raw.is_a?(Array)
      @ownership  = :affine
      @sync       = nil
      @collection = nil
      @is_error_union      = false; @payload_type_raw = nil
      @is_optional         = false; @wrapped_type_raw  = nil
      @is_array            = false; @capacity = nil; @element_type_raw = nil
      @is_map              = false; @value_type_raw = nil
      @is_generic_instance = false; @generic_base_raw = nil; @generic_args_raw = nil
      @location            = :stack
      return
    end

    str = @raw.to_s

    # Type alias: Number → Float64 (canonical internal name for f64).
    # Both Number and Float64 are accepted; the type system uses :Float64 everywhere.
    str = str.gsub(/\bNumber\b/, 'Float64')

    suffix_ownership = nil
    suffix_sync = nil
    unless str.include?("<")
      str, suffix_ownership, suffix_sync = strip_capability_suffix(str)
    end
    @raw = str.to_sym

    # A0. Detect Tense prefix: ~T (Future/Promise — a BG task producing T)
    # Parsed first so ~!T = "promise of failable T", ~?T = "promise of optional T".
    # When tense, we bail early — tense_type handles its own inner parsing.
    if str.start_with?("~")
      inner = str[1..]
      raise "Invalid type '#{str}': double tense (~~) is not allowed — ~T is already a promise" if inner.start_with?("~")
      @is_tense       = true
      @tense_type_raw = inner.to_sym
      @is_error_union = false; @payload_type_raw = nil
      @is_optional    = false; @wrapped_type_raw  = nil
      @is_array       = false; @capacity = nil; @element_type_raw = nil
      @is_map              = false; @value_type_raw = nil
      @is_generic_instance = false; @generic_base_raw = nil; @generic_args_raw = nil
      @ownership      = :affine
      @sync           = nil
      @collection     = nil
      @location       = :stack  # Promise handle lives on the stack; result_cell is heap
      @resolved_cache = @raw.to_sym
      return
    else
      @is_tense       = false
      @tense_type_raw = nil
    end

    # A. Detect Error Union prefix: !Type (Zig-style error returns)
    if str.start_with?("!")
      raise "Invalid type '#{str}': double error union (!!) is not allowed" if str[1..].start_with?("!")
      raise "Invalid type '#{str}': !~T (error union of tense) is not allowed — use ~!T instead" if str[1..].start_with?("~")
      @is_error_union = true
      @payload_type_raw = str[1..].to_sym
      str = str[1..]
    else
      @is_error_union = false
      @payload_type_raw = nil
    end

    # B. Detect Optional prefix: ?Type
    if str.start_with?("?")
      raise "Invalid type '#{str}': double optional (??) is not allowed" if str[1..].start_with?("?")
      raise "Invalid type '#{str}': ?~T (optional of tense) is not allowed — use ~?T instead" if str[1..].start_with?("~")
      @is_optional = true
      @wrapped_type_raw = str[1..].to_sym
      str = str[1..]
    else
      @is_optional = false
      @wrapped_type_raw = nil
    end

    # C. Capability fields default — callers pass ownership:/sync:/location:/collection: as keyword args.
    @ownership  = suffix_ownership || :affine
    @sync       = suffix_sync
    @collection = nil

    # D. Detect Array Structure
    # Regex Breakdown:
    #   ^       Start of string
    #   (.+)    Capture Group 1: Base Type (e.g. "Float64")
    #   \[      Literal opening bracket
    #   (\d+)?  Capture Group 2: Optional Digits (Capacity).
    #           If this is missing, it matches "[]", meaning Dynamic.
    #   \]      Literal closing bracket
    #   $       End of string
    if match = str.match(/^(.+)\[(\d+|INF|\?)?\]$/)
      @is_array = true
      @element_type_raw = match[1].to_sym # Store "Float64"

      # Capacity: nil = dynamic, :STREAM_OPEN = open stream [?], :INF = infinite [INF], Integer = fixed [N]
      @capacity = case match[2]
                  when nil    then nil
                  when "?"    then :STREAM_OPEN
                  when "INF"  then :INF
                  else             match[2].to_i
                  end
    else
      @is_array = false
      @capacity = nil
      @element_type_raw = nil
    end

    # E. Detect HashMap Structure: HashMap<ValueType> or HashMap<KeyType, ValueType>
    # Two-arg form: HashMap<Number, V> or HashMap<Int64, V> → numeric-keyed AutoHashMap.
    # One-arg form: HashMap<V> → String-keyed StringHashMap (original behaviour).
    if match = str.match(/^HashMap<(.+)>$/)
      @is_map = true
      inner = match[1]
      if inner.include?(",")
        parts = inner.split(",", 2).map(&:strip)
        @key_type_raw   = parts[0].to_sym
        @value_type_raw = parts[1].to_sym
      else
        @key_type_raw   = :String
        @value_type_raw = inner.to_sym
      end
    else
      @is_map = false
      @key_type_raw   = nil
      @value_type_raw = nil
    end

    # E2. Detect Generic Struct Instance: Pair<Number> or Map<String,Number>
    # Only for non-HashMap types (HashMap is handled above).
    if !@is_map && !@is_array && (match = str.match(/^([A-Z]\w*)<(.+)>$/))
      @is_generic_instance = true
      @generic_base_raw    = match[1].to_sym
      @generic_args_raw    = match[2].split(',').map(&:strip).map(&:to_sym)
    else
      @is_generic_instance = false
      @generic_base_raw    = nil
      @generic_args_raw    = nil
    end

    # F. Default location: stack for all types.  Explicit frame/heap is set later by finalize_storage!
    #    (Previously defaulted to :frame for non-primitives, but :frame is now a meaningful directive,
    #    so we use :stack as the neutral default and let finalize_storage! upgrade when needed.)
    @location = :stack

    # Resolved name is the raw string as-is (! and ? are type-level modifiers, not stripped).
    @resolved_cache = @raw.to_sym
  end

  sig { params(str: String).returns(Array) }
  def strip_capability_suffix(str)
    return [str, nil, nil] unless str.include?("@")

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

    [base, ownership, sync]
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
      if tense_observable? && !promise_list?
        return "*CheatLib.obs.#{observable_wrapper_zig(tense_type)}"
      end
      if promise_list?
        elem_zig = tense_type.element_type.zig_type(is_param: is_param, is_field: is_field)
        return "std.ArrayListUnmanaged(CheatLib.Promise(#{elem_zig}))"
      end
      if bounded_stream?
        elem_zig = stream_element_type.zig_type(is_param: is_param, is_field: is_field)
        return "CheatLib.BoundedStream(#{elem_zig}, #{stream_capacity})"
      end
      if dynamic_stream?
        inner_t = tense_type.element_type
        return case inner_t&.resolved
               when :Int64 then "CheatLib.IntRange"
               when :Float64 then "CheatLib.Range"
               else
                 "CheatLib.Stream(#{inner_t.zig_type(is_param: is_param, is_field: is_field)})"
               end
      end
      if shared_promise?
        inner_zig = tense_type.zig_type(is_param: is_param, is_field: is_field)
        return "CheatLib.SharedPromise(#{inner_zig})"
      end
      if split_open_stream?
        elem_zig = open_stream_element_type.zig_type(is_param: is_param, is_field: is_field)
        return "CheatLib.SplitStream(#{elem_zig})"
      end
      if open_stream?
        elem_zig = open_stream_element_type.zig_type(is_param: is_param, is_field: is_field)
        return "CheatLib.Stream(#{elem_zig})"
      end
      if inf_stream?
        elem_zig = inf_stream_element_type.zig_type(is_param: is_param, is_field: is_field)
        return "CheatLib.InfStream(#{elem_zig})"
      end
      inner_zig = tense_type.zig_type(is_param: is_param, is_field: is_field)
      return "CheatLib.Promise(#{inner_zig})"
    end

    # 1. Handle Error Union: !T -> !zig_type
    if error_union?
      # The parser stamps storage decorators (heap/frame, ownership
      # like @multiowned/@shared, sync, layout) on the OUTER
      # error-union Type, but `payload_type` is built from the bare
      # base symbol -- so a `RETURNS !%User` payload is `User` (no
      # heap), and `RETURNS !Node @multiowned` payload is `Node` (no
      # ownership). Propagate the outer's storage hints so the
      # payload renders as `*User`, `CheatLib.Rc(Node)`,
      # `CheatLib.Arc(Node)`, etc. -- matching what the body actually
      # returns and what zig_type would produce for the bare type.
      pt = payload_type
      if pt
        # Make a copy so we don't mutate the cached payload Type.
        pt = Type.new(pt) if pt.is_a?(Type)
        if heap? && pt.respond_to?(:provenance) && pt.provenance != :heap &&
           pt.respond_to?(:provenance=)
          pt.provenance = :heap
        end
        # Generic ownership propagation: any non-default outer
        # ownership (multiowned / shared / link / ...) flows to the
        # payload so the inner zig_type renders the right wrapper
        # (Rc / Arc / WeakRc / ...).
        if respond_to?(:ownership) && ownership && ownership != :affine &&
           pt.respond_to?(:ownership) && (pt.ownership.nil? || pt.ownership == :affine) &&
           pt.respond_to?(:ownership=)
          pt.ownership = ownership
        end
        if respond_to?(:sync) && sync && pt.respond_to?(:sync) && pt.sync.nil? &&
           pt.respond_to?(:sync=)
          pt.sync = sync
        end
        if respond_to?(:layout) && layout && pt.respond_to?(:layout) && pt.layout.nil? &&
           pt.respond_to?(:layout=)
          pt.layout = layout
        end
      end
      inner_zig = pt.zig_type(is_param: is_param, is_field: is_field)
      return "!#{inner_zig}"
    end

    # 2. Handle Optional: ?T -> ?zig_type
    if optional?
      inner_zig = wrapped_type.zig_type(is_param: is_param, is_field: is_field)
      return "?#{inner_zig}"
    end

    # 2c. Function type: FN(T, ...) -> R  =>  *const fn(*Runtime, T, ...) anyerror!R
    if fn_type?
      param_types_zig = @raw.params.map do |p|
        t = p[:type]
        t.is_a?(Type) ? t.zig_type(is_param: true) : Type.new(t).zig_type(is_param: true)
      end
      ret = @raw.return_type
      ret_zig = ret.is_a?(Type) ? ret.zig_type : Type.new(ret).zig_type
      all_params = ["*Runtime"] + param_types_zig
      ret_str = ret_zig.start_with?("!") ? ret_zig : "anyerror!#{ret_zig}"
      return "*const fn(#{all_params.join(', ')}) #{ret_str}"
    end

    # 2b. Derive Zig type from ownership × sync dimensions
    # Only apply capability wrapping when there's an actual capability set.
    # Sharded maps with sync use StripedMap (sync built into the map type) —
    # skip Locked/RwLocked wrapping but still apply Arc/Rc if @shared/@multiowned.
    if (@ownership != :affine || any_sync?) && !(map? && striped? && @ownership == :affine)
      # For shared striped maps, the inner type is the striped map itself (sync built-in).
      # For other types, get the plain inner type and wrap with Locked/RwLocked.
      if map? && striped?
        # Striped map: sync is built into ShardedStringMap — get it with shard_count.
        bare = Type.new(resolved.to_s)
        bare.shard_count = @shard_count
        bare.sync = @sync
        inner_zig = bare.zig_type(is_param: is_param, is_field: is_field)
      else
        if fixed_soa?
          # T[N]@soa:shared etc. — inner type is SoaList, not bare [N]T
          base_zig = T.must(element_type).zig_type(is_param: is_param, is_field: is_field)
          inner_zig = "CheatLib.SoaList(#{base_zig})"
        else
          # Group 1 / Group 2 separation: the inner zig type is the data
          # shape with sync/ownership stripped. bare_data_type preserves
          # shape attrs (@pool, @sharded, capacity, element_type) that
          # `Type.new(resolved.to_s)` would lose.
          inner_zig = bare_data_type.zig_type(is_param: is_param, is_field: is_field)
        end
        inner_zig = "CheatLib.Locked(#{inner_zig})"   if @sync == :locked
        inner_zig = "CheatLib.RwLocked(#{inner_zig})" if @sync == :write_locked
        inner_zig = "CheatLib.RefCell(#{inner_zig})"   if @sync == :always_mutable
        inner_zig = "CheatLib.Versioned(#{inner_zig})" if @sync == :versioned
        # AtomicPtr M3.1: `@indirect:atomic` (struct case) wraps in
        # AtomicPtr(T), not bare Atomic(T). The cell is an atomic
        # pointer to a refcounted heap-allocated T -- single-CAS
        # publish at the pointer level, Arc-managed payload lifetime.
        # Distinct from primitive @atomic (single CAS-able machine
        # word, no indirection) -- see the @sync == :atomic branch
        # below.
        if @sync == :atomic && @layout == :indirect
          inner_zig = "CheatLib.AtomicPtr(#{inner_zig})"
        elsif @sync == :atomic
          inner_zig = "CheatLib.Atomic(#{inner_zig})"
        end
      end

      # Atomics M2.2: drop the Arc / Rc wrap for `@shared:atomic` /
      # `@multiowned:atomic`. The atomic cell itself is heap-allocated
      # by `atomicCreate` (returns `*Atomic(T)`) and the binding holds
      # the bare pointer; Zig auto-derefs so `c.load()` / `c.fetchAdd
      # (...)` work on either a pointer or a value receiver. M2.3's
      # BG-handle lifetime stamp + M2.6's escape audit make pointer-
      # capture safe without an outer refcount, so the Arc is now
      # redundant. `@multiowned:atomic` is still parser-rejected (Rc
      # isn't thread-safe), but the guard here is symmetric.
      #
      # M3.1: `@indirect:atomic` (with or without explicit @shared)
      # uses the same bare-pointer layout -- the AtomicPtr cell is
      # heap-allocated and the binding holds the bare pointer.
      if @sync == :atomic && (@ownership == :shared || @ownership == :multiowned || @layout == :indirect)
        return "*#{inner_zig}"
      end

      case @ownership
      when :multiowned
        return "CheatLib.Rc(#{inner_zig})"
      when :shared
        return "CheatLib.Arc(#{inner_zig})"
      when :link
        source = link_source
        return source == :shared ? "CheatLib.WeakArc(#{inner_zig})" : "CheatLib.WeakRc(#{inner_zig})"
      else
        return "*#{inner_zig}" unless map? && striped?
      end
    end

    # :frame means "allocated in the frame arena". Strings/arrays are value-typed (slice), only
    # frame-allocated structs are stored as *T pointers so large data stays off the fiber stack.
    is_pointer = heap? || (frame? && struct?)

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
      return is_pointer && zig != "void" ? "*#{zig}" : zig
    end

    # 5. Handle HashMaps
    #    HashMap<V>                        → std.StringHashMapUnmanaged(V)
    #    HashMap<K, V>                     → CheatLib.NumericMapType(K, V)
    #    HashMap<V>@sharded(N)             → CheatLib.PartitionedStringMap(V, N)     (shared-nothing)
    #    HashMap<V>@sharded(N):locked      → CheatLib.MutexShardedStringMap(V, N)    (Mutex per shard)
    #    HashMap<V>@sharded(N):writeLocked → CheatLib.ShardedStringMap(V, N)         (RwLock per shard)
    if map?
      val_zig = value_type.zig_type
      if striped?  # sharded + sync = lock-striped
        if numeric_map?
          key_zig = key_type.zig_type
          return "CheatLib.StripedNumericMap(#{key_zig}, #{val_zig}, #{shard_count})"
        end
        if @sync == :locked
          return "CheatLib.MutexShardedStringMap(#{val_zig}, #{shard_count})"
        else
          return "CheatLib.ShardedStringMap(#{val_zig}, #{shard_count})"
        end
      end
      if sharded?  # sharded without sync = shared-nothing (no locks)
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
      return "CheatLib.StringMap(#{val_zig})"
    end

    # 5b. Handle Generic Struct Instances
    #    Pair<Number> -> Pair(f64),  Map<String,Number> -> Map([]const u8, f64)
    #    Id<User>     -> u64        (compiler-intrinsic handle, type param is for CLEAR safety only)
    if generic_instance?
      return "u64" if @generic_base_raw == :Id
      args_zig = @generic_args_raw.map { |a| Type.new(a).zig_type }.join(", ")
      zig = "#{@generic_base_raw}(#{args_zig})"
      return is_pointer && zig != "void" ? "*#{zig}" : zig
    end

    # 6. Map primitives and builtins to Zig types; user types pass through.
    zig = ZIG_TYPE_MAP[resolved] || resolved.to_s

    # 7. Add pointer prefix if heap-allocated and not void
    is_pointer && zig != "void" ? "*#{zig}" : zig
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
  sig { params(node: T.untyped, effective_type: T.untyped).returns(T.untyped) }
  def check_prefixed_int_range!(node, effective_type)
    T.bind(self, SemanticAnnotator) rescue nil
    val = if node.is_a?(AST::Literal) && (node.type == :PREFIXED_INT || node.type == :INT64)
      node.value
    elsif node.is_a?(AST::UnaryOp) && node.op == :SUB &&
          node.right.is_a?(AST::Literal) && (node.right.type == :INT64 || node.right.type == :PREFIXED_INT)
      -node.right.value
    else
      return
    end
    # Unwrap an error union so `RETURN 256` against `RETURNS !Byte`
    # range-checks against the underlying `Byte`. Post-#338, fallible
    # int returns are stamped `!Int8`/`!Byte`/etc; the range checker's
    # INT_TYPE_MAX lookup happens on the bare type symbol.
    if effective_type.respond_to?(:error_union?) && effective_type.error_union? &&
       effective_type.respond_to?(:payload_type)
      effective_type = effective_type.payload_type
    end
    t = effective_type.respond_to?(:resolved) ? effective_type.resolved : effective_type&.to_sym
    max = Type::INT_TYPE_MAX[t]
    return unless max  # Not a known integer type; let type checker handle the mismatch
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
