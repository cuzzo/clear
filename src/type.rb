# Result struct for binary operation type resolution
BinaryOpResult = Struct.new(:type, :left_coercion, :right_coercion, :storage, :error, keyword_init: true)

class Type
  attr_reader :raw, :name, :generic_args, :capacity, :value_type_raw
  attr_accessor :mutability, :lifetime_constraint
  attr_accessor :ownership   # :affine (default), :multiowned (Rc), :shared (Arc)
  attr_accessor :sync        # nil (default), :locked, :write_locked
  attr_accessor :collection  # nil (default), :list (explicit heap list), :pool (generational pool)
  attr_accessor :shard_count  # nil (no sharding) or Integer >= 2 (@pool:sharded(N) / @list:sharded(N) / HashMap:sharded(N))
  attr_accessor :soa          # true when @pool:soa or @list:soa — Structure of Arrays layout
  attr_accessor :heap_list     # true when the list was promoted to heap (returned from frame-using fn)
  attr_accessor :heap_map      # true when the string map was promoted to heap (returned from any fn)
  attr_accessor :escaped_return # true when the list/map is returned — ownership transferred, no cleanup
  attr_reader :location  # Use location= setter for cache invalidation

  # Enum constants for clarity
  LOCATIONS = [:stack, :frame, :heap, :multiowned, :shared]
  OWNERSHIP = [:unique, :borrowed, :shared, :static]

  # String type constants
  STRING_TYPE = :String
  HEAP_STRING_TYPE = :String

  # Operator categories
  BOOL_RESULT_OPS = [:EQ, :NEQ, :LT, :GT, :LTE, :GTE]
  NUMBER_RESULT_OPS = [:SUB, :MUL, :DIV, :POW, :MOD]

  # Resolves the result type of a binary operation given two operand types.
  # Returns a BinaryOpResult with type, optional coercions, and storage.
  def self.binary_op(op, left_type, right_type)
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
  def self.coerce_error(source_type, target_type)
    source = source_type.is_a?(Type) ? source_type : Type.new(source_type)
    target = target_type.is_a?(Type) ? target_type : Type.new(target_type)

    return nil if target.accepts?(source)

    if target.array_overflow?(source)
      "Cannot initialize array of size #{target.capacity} with #{source.capacity} elements"
    else
      "Type Mismatch: Cannot assign #{source.resolved} to #{target.resolved}"
    end
  end

  private

  def self.resolve_numeric_op(t_left, t_right)
    # Integer wins: when either operand is Int64 the result is Int64.
    # NUMBER whole-number literals emit as Zig comptime_int which is i64-compatible,
    # so no explicit cast is needed.  Mixing a genuine f64 *variable* with Int64 in
    # SUB/MUL/DIV/MOD is a type error the user must resolve with an explicit conversion.
    if t_left == :Int64 || t_right == :Int64
      BinaryOpResult.new(type: :Int64)
    else
      BinaryOpResult.new(type: :Number)
    end
  end

  def self.resolve_add_op(t_left, t_right, left_type, right_type)
    # A. Int64 Optimization
    if t_left == :Int64 && t_right == :Int64
      return BinaryOpResult.new(type: :Int64)
    end

    # B. Float Propagation (Mixed Int/Number -> Number)
    if t_left == :Number || t_right == :Number
      left_coercion = (t_left == :Int64) ? :Number : nil
      right_coercion = (t_right == :Int64) ? :Number : nil
      return BinaryOpResult.new(type: :Number, left_coercion: left_coercion, right_coercion: right_coercion)
    end

    # C. String Concatenation
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

  def self.safe_autocast?(from_type, to_type)
    return false if from_type.nil?
    # Numbers and booleans can be auto-cast to strings
    [:Number, :Int64, :Bool, :Byte].include?(from_type)
  end

  public

  def initialize(raw_input, ownership: nil, sync: nil, location: nil, collection: nil, shard_count: nil, stripe_count: nil) # stripe_count kept for backwards compat (ignored)
    if raw_input.is_a?(Type)
      # Copy constructor: preserve all parsed state from the source type
      other = raw_input
      @raw                = other.instance_variable_get(:@raw)
      @mutability         = false
      @lifetime_constraint = nil
      @ownership          = other.ownership
      @sync               = other.sync
      @collection         = other.instance_variable_get(:@collection)
      @shard_count        = other.instance_variable_get(:@shard_count)
      @soa                = other.instance_variable_get(:@soa)
      @location           = other.instance_variable_get(:@location)
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
    else
      @raw = raw_input
      parse_raw_input

      # Defaults
      @mutability = false
      @lifetime_constraint = nil # nil means local scope
    end

    # Capability fields — set after parse/copy so they can override.
    # location must come before ownership/sync so their setters can still adjust it.
    @location  = location  if location
    @ownership = ownership if ownership
    @sync      = sync      if sync
    # Pool collection always lives on the heap (owns internal slot array).
    if collection
      @collection = collection
      @zig_type_cache = nil
      @location = :heap if collection == :pool
    end
    @shard_count = shard_count if shard_count
  end

  # Delegate [] to the raw value for Hash-typed raws (function signatures).
  def [](key)
    @raw[key] if @raw.is_a?(Hash)
  end

  # -----------------------------------------------
  # COMPATIBILITY LAYER (The "Don't Break Tests" part)
  # -----------------------------------------------

  # Allow code to compare this object directly to symbols/strings
  # e.g. if node.type == :Number
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

  def to_s; resolved.to_s; end
  def to_sym; resolved; end

  # Backward API: Deprecate
  def resolved
    # Logic moved from Locatable#resolved_type
    return @resolved_cache if @resolved_cache

    ft = if @raw.is_a?(Hash); @raw[:return][:type]
         elsif @raw.is_a?(Array); @raw[2]
         else; @raw; end

    @resolved_cache = ft.to_sym
  end

  # Backward API: Deprecate
  def base_type
    resolved.to_s.sub(/\[.*\]$/, "").to_sym
  end

  def container?
    s = resolved.to_s
    s.end_with?("]") || s.start_with?("HashMap")
  end

  def primitive?
    AST::PRIMITIVE_TYPES.include?(resolved)
  end

  # ----------------------------------------------
  # Coercion helpers
  # ----------------------------------------------
  def accepts?(other_type)
    # 0. Function type structural matching (must precede == shortcut because `resolved`
    #    returns only the return type for fn_types, making two different fn_type signatures
    #    appear equal if their return types match).
    if self.fn_type?
      return true if other_type.is_a?(Type) && other_type.any?
      other_raw = other_type.is_a?(Type) ? other_type.raw : nil
      is_fn_or_lambda = other_type.is_a?(Type) &&
                        (other_type.fn_type? || (other_raw.is_a?(Hash) && other_raw[:lambda]))
      return false unless is_fn_or_lambda

      self_params  = @raw[:params] || []
      other_params = (other_raw || {})[:params] || []
      return false unless self_params.length == other_params.length

      self_ret  = @raw.dig(:return, :type)
      other_ret = (other_raw || {}).dig(:return, :type)
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
      self_allows_reentrant = @raw[:reentrant] == true
      other_is_reentrant    = other_raw.is_a?(Hash) && other_raw[:reentrant] == true
      return false if other_is_reentrant && !self_allows_reentrant

      return true
    end

    # 1. Exact Match / Any
    return true if self == other_type || self.any? || other_type.any?

    # 2. Primitives (Widening)
    return true if self.numeric? && other_type.numeric? # Simplified logic
    return true if self.string? && other_type.byte?
    return true if self.string? && other_type.string?  # Byte[N] → String widening

    # 3. Optional Coercion: ?T accepts T, NIL, or ?T
    if self.optional?
      return true if other_type.resolved == :NIL  # nil is always valid
      # Accept the wrapped type (e.g., ?Int64 accepts Int64)
      return wrapped_type.accepts?(other_type) if !other_type.optional?
      # Accept same optional type
      return wrapped_type.accepts?(other_type.wrapped_type) if other_type.optional?
    end

    # 4. Error Union Coercion: !T accepts T or !T
    if self.error_union?
      # Accept the payload type (e.g., !Number accepts Number)
      return payload_type.accepts?(other_type) if !other_type.error_union?
      # Accept same error union type
      return payload_type.accepts?(other_type.payload_type) if other_type.error_union?
    end

    # 5a. Tense (Promise) Coercion: ~T only accepts ~T with a compatible inner type
    if self.tense?
      # Promise list (~T[]@list) accepts an empty list literal [] or another ~T[] type.
      return true if self.promise_list? && (other_type.empty_list? || (other_type.tense? && other_type.tense_type.dynamic?))
      return false unless other_type.tense?
      return tense_type.accepts?(other_type.tense_type)
    end

    # 5. Array Coercion (The complex part from your Annotator)
    if self.array?
      # Any[] accepts promise list types (~T[]) for append/list intrinsic matching.
      return true if self.element_type.any? && other_type.tense? && other_type.tense_type.dynamic?
      return false if !other_type.array?
      return true if other_type.empty_list?
      return false unless self.element_type.accepts?(other_type.element_type)
      return true if self.dynamic? && other_type.fixed?

      # e.g. var buffer: Number[10] = smaller_buffer (Number[4])
      if self.fixed? && other_type.fixed?
        return other_type.capacity <= self.capacity
      end

      return true if self.dynamic? && other_type.dynamic?
    end

    # 6. HashMap coercion: HashMap<Any> (empty literal) accepts as any HashMap<T>
    if self.map? && other_type.map?
      return true if other_type.value_type.any?
      return self.value_type.accepts?(other_type.value_type)
    end

    false
  end

  # Used specifically to check if assigning an array too large to a fixed array
  def array_overflow?(other_type)
    return false if !other_type.array? || !self.array?
    return false if self.base_type != other_type.base_type
    return false if !other_type.fixed? || !self.fixed?
    return true if other_type.capacity > self.capacity
  end

  # ----------------------------------------------
  # Type Predicates
  # ----------------------------------------------
  def numeric?
    [:Number, :Byte, :Float, :Int64].include?(resolved)
  end

  def boolean?
    resolved == :Bool
  end

  def byte?
    resolved == :Byte
  end

  def void?
    resolved == :Void
  end

  def fn_type?
    @raw.is_a?(Hash) && @raw[:fn_type] == true
  end

  def array?
    resolved.to_s.end_with?("]")
  end

  def string?
    resolved == :String || (array? && base_type == :Byte)
  end

  def any?
    resolved == :Any
  end

  def dynamic?
    # It is dynamic if it is an array, but has NO fixed capacity
    array? && capacity.nil?
  end

  def fixed?
    # It is fixed if it is an array AND has a specific integer capacity (not [?] or [INF])
    array? && capacity.is_a?(Integer)
  end

  # True when this is the [?] marker (open stream element-type annotation).
  # Only meaningful as the tense_type of an open stream: ~T[?].
  def open_stream_marker?
    array? && capacity == :STREAM_OPEN
  end

  # True when this is the [INF] marker (infinite stream element-type annotation).
  # Only meaningful as the tense_type of an infinite stream: ~T[INF].
  def inf_stream_marker?
    array? && capacity == :INF
  end

  def empty_list?
    # Handles the empty list literal "Any[]" or heap "%Any[]"
    # This is crucial for initializing typed arrays (e.g., `var x: Number[] = []`)
    resolved == :"Any[]"
  end

  def heap?
    @location == :heap
  end

  def frame?
    @location == :frame
  end

  def multiowned?
    @ownership == :multiowned
  end

  def shared?
    @ownership == :shared
  end

  def locked?
    @sync == :locked
  end

  def write_locked?
    @sync == :write_locked
  end

  def local?
    @sync == :local
  end

  # True for any sync capability
  def any_sync?
    !@sync.nil?
  end

  # Backwards compat alias used in a few places
  alias any_locked? any_sync?

  def has_capabilities?
    @ownership != :affine || any_sync?
  end

  def any_rc?
    # SharedPromise uses its own ref-counting internally — it is NOT an Rc/Arc wrapper.
    return false if shared_promise?
    multiowned? || shared?
  end

  def map?
    @is_map
  end

  # True when this is a numeric-keyed map (HashMap<Number,V> or HashMap<Int64,V>).
  # Backed by AutoHashMapUnmanaged — no key duplication, pure arena-allocated.
  def numeric_map?
    @is_map && @key_type_raw && @key_type_raw != :String
  end

  def key_type
    Type.new(@key_type_raw || :String)
  end

  # True when this is an explicit @pool (generational pool) collection.
  def pool?
    @collection == :pool
  end

  # True when this is an explicit @list (heap list) collection.
  def list_collection?
    @collection == :list
  end

  # True when this is a list of promises: ~T[]@list — a dynamic list of BG tasks.
  # Declared as `MUTABLE futures: ~T[]@list = []`; populated via append(futures, BG { ... }).
  def promise_list?
    tense? && list_collection?
  end

  # True when the collection has a sharding topology modifier (@pool:sharded(N) / @list:sharded(N)).
  def sharded?
    !@shard_count.nil?
  end

  def soa?
    !!@soa
  end

  # A sharded collection with sync capability = lock-striped (skew-safe).
  # Replaces the old :striped(N) keyword — now expressed via composition:
  #   HashMap<V>:sharded(N) @locked → StripedStringMap
  def striped?
    sharded? && any_sync?
  end

  def value_type
    return nil unless map?
    @value_type_obj ||= Type.new(@value_type_raw || :Any)
  end

  # Generic struct instance: Pair<Number>, Map<String, Number>
  def generic_instance?
    !!@is_generic_instance
  end

  # The base type name of a generic instance: :"Pair<Number>" → :Pair
  def generic_base
    @generic_base_raw
  end

  # The type arguments as Type objects: [Type(:Number), Type(:String)]
  def generic_args
    return nil unless @is_generic_instance
    @generic_args_obj ||= @generic_args_raw.map { |a| Type.new(a) }
  end

  # TODO: keep metatype from ast, use that
  def struct?
    !primitive? && !any? && !void? && !string? && !array? && !map? && !optional? && !error_union? && !tense? && !fn_type?
  end

  def optional?
    @is_optional
  end

  def wrapped_type
    return nil unless optional?
    @wrapped_type_obj ||= Type.new(@wrapped_type_raw || :Any)
  end

  # Error union types: !T (Zig-style error returns)
  def error_union?
    @is_error_union
  end

  def payload_type
    return nil unless error_union?
    @payload_type_obj ||= Type.new(@payload_type_raw || :Any)
  end

  # Tense (Promise) types: ~T — a background task that will produce T
  def tense?
    !!@is_tense
  end

  def tense_type
    return nil unless tense?
    @tense_type_obj ||= Type.new(@tense_type_raw || :Void)
  end

  # Bounded stream: ~T[N] — a fixed array of N promises consumed one-by-one via NEXT.
  # Distinct from a single promise (~T): NEXT can be called N times, not exactly once.
  def bounded_stream?
    tense? && tense_type.fixed?
  end

  # Shared promise: ~T@shared — a memoized promise backed by Arc-style ref counting.
  # Multiple holders can call NEXT independently; NEXT is idempotent per handle.
  # NOT linearly affine — can be retained (cloned) without consuming it.
  def shared_promise?
    tense? && shared?
  end

  # Open stream: ~T[?] — a generator-backed stream; NEXT returns ?T (nil when exhausted).
  # Resource semantics: call deinit() to free the heap-allocated buffer.
  def open_stream?
    tense? && tense_type.open_stream_marker?
  end

  # The element type T in ~T[?].
  def open_stream_element_type
    return nil unless open_stream?
    tense_type.element_type
  end

  # Infinite stream: ~T[INF] — a lazy rendezvous generator; NEXT returns T (never nil).
  # Generator and consumer rendezvous on each value: push() blocks until next() reads it.
  # Resource semantics: call deinit() to free the heap-allocated Inner.
  def inf_stream?
    tense? && tense_type.inf_stream_marker?
  end

  # The element type T in ~T[INF].
  def inf_stream_element_type
    return nil unless inf_stream?
    tense_type.element_type
  end

  # The element type T in ~T[N].
  def stream_element_type
    return nil unless bounded_stream?
    tense_type.element_type
  end

  # The capacity N in ~T[N].
  def stream_capacity
    return nil unless bounded_stream?
    tense_type.capacity
  end

  def element_type
    return nil unless array?
    # Uses the capture from parse_raw_input, ensuring "Number[3]" becomes "Number"
    @element_type_obj ||= Type.new(@element_type_raw || :Any)
  end

  def slot_size(lookup_arg = nil, &lookup_block)
    resolver = lookup_arg || lookup_block

    # 1. Primitives / Pointers (Heap objects are 1 slot pointers; Rc/Arc/Locked are also pointer-sized)
    # Generic instances (e.g. Id<T>) are intrinsic scalar types — always 1 slot.
    return 1 if primitive? || heap? || dynamic? || any? || multiowned? || shared? || any_sync? || generic_instance?

    # 2. Fixed Arrays (Recursion)
    if fixed?
      return capacity * element_type.slot_size(resolver)
    end

    # 3. Structs (The tricky part)
    if struct?
      raise "Need lookup context for struct size" unless resolver
      schema = resolver.call(resolved)
      # Enum/Union/Resource types — treat as slot size 1.
      return 1 if schema.is_a?(Hash) && (schema[:kind] == :enum || schema[:kind] == :union || schema[:kind] == :resource)
      # Generic structs: treat as 1 slot (size depends on type args, unknown at this point)
      return 1 if schema.is_a?(Hash) && schema[:type_params]
      return schema.values.sum { |t| Type.new(t).slot_size(resolver) }
    end

    1 # Default
  end

  # TODO: In future, need to be able to call slot-size for small structs.
  def requires_move?
    return false if fn_type?                # Function pointers are pointer-sized; no move semantics
    return false if bounded_stream?         # Bounded streams are consumed incrementally — not linearly affine
    return false if shared_promise?         # Shared promises are non-affine — multiple NEXT calls allowed
    return false if open_stream?            # Open streams are resources with deinit cleanup, not linear
    return false if inf_stream?             # Infinite streams are resources with deinit cleanup, not linear
    return false if list_collection? || pool?  # @list/@pool are arena/heap-managed via defer deinit — not linearly affine
    return false if map?                       # @map is cleaned up via mapDeinit/numericMapDeinit — not linearly affine
    return true if tense?                   # Single promises are linear — must be consumed exactly once
    return false if multiowned? || shared?  # Rc/Arc use retain/release, not linear move semantics
    return false if any_sync?               # Sync vars manage their own lifecycle
    return true if heap?
    return true if array?
    !primitive?
  end

  def copyable?(lookup_arg = nil, &lookup_block)
    return true if primitive?
    return false if multiowned? || shared? || any_sync?  # Rc/Arc/Locked must not be silently copied
    return false if heap?                   # Heap-allocated types are not copyable
    return false if frame? && struct?       # Frame-allocated struct pointers are not copyable
    return false if array?   # Arrays are not copyable
    return false if map?     # Maps are not copyable

    # Structs: copyable if all fields are copyable
    if struct?
      resolver = lookup_arg || lookup_block
      return false unless resolver
      schema = resolver.call(base_type.to_sym)
      return false unless schema
      return schema.values.all? { |t| Type.new(t).copyable?(resolver) }
    end

    false
  end

  # Custom setter for location that invalidates zig_type cache
  def location=(value)
    @zig_type_cache = nil
    @location = value
  end

  def ownership=(value)
    @zig_type_cache = nil
    @ownership = value
    # Keep @location in sync for backwards compat
    case value
    when :multiowned then @location = :multiowned
    when :shared     then @location = :shared
    end
  end

  def sync=(value)
    @zig_type_cache = nil
    @sync = value
    # Sync types need a stable heap address
    @location = :heap if value && @ownership == :affine
  end

  # Returns the Zig type string representation of this type.
  # Memoized for performance; cache is invalidated when location changes.
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
  def finalize_storage(size, current_storage = nil)
    # Multiowned (Rc) always stays multiowned
    return :multiowned if multiowned? || current_storage == :multiowned

    # Shared (Arc) always stays shared
    return :shared if shared? || current_storage == :shared

    # Sync (locked) types need a stable heap address
    return :heap if any_sync? || current_storage == :heap && any_sync?

    # If already heap, keep it heap
    return :heap if current_storage == :heap || heap?

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

  def parse_raw_input
    # Hash and Array raws are function signatures — no string parsing applies.
    # @resolved_cache is left nil and computed on-demand by the resolved() fallback.
    if @raw.is_a?(Hash) || @raw.is_a?(Array)
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

    # A0. Detect Tense prefix: ~T (Future/Promise — a BG task producing T)
    # Parsed first so ~!T = "promise of failable T", ~?T = "promise of optional T".
    # When tense, we bail early — tense_type handles its own inner parsing.
    if str.start_with?("~")
      @is_tense       = true
      @tense_type_raw = str[1..].to_sym
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
      @is_error_union = true
      @payload_type_raw = str[1..].to_sym  # Store the inner type
      str = str[1..]  # Strip the ! for further parsing of inner type
    else
      @is_error_union = false
      @payload_type_raw = nil
    end

    # B. Detect Optional prefix: ?Type
    if str.start_with?("?")
      @is_optional = true
      @wrapped_type_raw = str[1..].to_sym  # Store the inner type
      str = str[1..]  # Strip the ? for further parsing of inner type
    else
      @is_optional = false
      @wrapped_type_raw = nil
    end

    # C. Capability fields default — callers pass ownership:/sync:/location:/collection: as keyword args.
    @ownership  = :affine
    @sync       = nil
    @collection = nil

    # D. Detect Array Structure
    # Regex Breakdown:
    #   ^       Start of string
    #   (.+)    Capture Group 1: Base Type (e.g. "Number")
    #   \[      Literal opening bracket
    #   (\d+)?  Capture Group 2: Optional Digits (Capacity).
    #           If this is missing, it matches "[]", meaning Dynamic.
    #   \]      Literal closing bracket
    #   $       End of string
    if match = str.match(/^(.+)\[(\d+|INF|\?)?\]$/)
      @is_array = true
      @element_type_raw = match[1].to_sym # Store "Number"

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

  # Computes the Zig type string for this CHEAT type.
  # Handles: error unions, optionals, multiowned (Rc), pointers, arrays, hashmaps, primitives, structs.
  def compute_zig_type(is_param: false, is_field: false)
    # 0. Handle Tense types:
    #    ~T[N]      -> CheatLib.BoundedStream(T, N)
    #    ~T@shared  -> CheatLib.SharedPromise(T)
    #    ~T         -> CheatLib.Promise(T)
    if tense?
      if promise_list?
        elem_zig = tense_type.element_type.zig_type(is_param: is_param, is_field: is_field)
        return "std.ArrayListUnmanaged(CheatLib.Promise(#{elem_zig}))"
      end
      if bounded_stream?
        elem_zig = stream_element_type.zig_type(is_param: is_param, is_field: is_field)
        return "CheatLib.BoundedStream(#{elem_zig}, #{stream_capacity})"
      end
      if shared_promise?
        inner_zig = tense_type.zig_type(is_param: is_param, is_field: is_field)
        return "CheatLib.SharedPromise(#{inner_zig})"
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
      inner_zig = payload_type.zig_type(is_param: is_param, is_field: is_field)
      return "!#{inner_zig}"
    end

    # 2. Handle Optional: ?T -> ?zig_type
    if optional?
      inner_zig = wrapped_type.zig_type(is_param: is_param, is_field: is_field)
      return "?#{inner_zig}"
    end

    # 2c. Function type: FN(T, ...) -> R  =>  *const fn(*Runtime, T, ...) anyerror!R
    if fn_type?
      param_types_zig = @raw[:params].map do |p|
        t = p[:type]
        t.is_a?(Type) ? t.zig_type(is_param: true) : Type.new(t).zig_type(is_param: true)
      end
      ret = @raw[:return][:type]
      ret_zig = ret.is_a?(Type) ? ret.zig_type : Type.new(ret).zig_type
      all_params = ["*Runtime"] + param_types_zig
      ret_str = ret_zig.start_with?("!") ? ret_zig : "anyerror!#{ret_zig}"
      return "*const fn(#{all_params.join(', ')}) #{ret_str}"
    end

    # 2b. Derive Zig type from ownership × sync dimensions
    # Only apply capability wrapping when there's an actual capability set.
    # Exception: sharded maps with sync use StripedMap (sync built into the map type).
    if (@ownership != :affine || @sync) && !(map? && striped?)
      # Get the plain inner zig type (ownership=:affine creates a bare type with no wrapping)
      inner_zig = Type.new(resolved.to_s).zig_type(is_param: is_param, is_field: is_field)

      inner_zig = "CheatLib.Locked(#{inner_zig})"   if @sync == :locked
      inner_zig = "CheatLib.RwLocked(#{inner_zig})" if @sync == :write_locked

      case @ownership
      when :multiowned
        return "CheatLib.Rc(#{inner_zig})"
      when :shared
        return "CheatLib.Arc(#{inner_zig})"
      else
        # affine + sync: needs pointer (stable heap address)
        return "*#{inner_zig}"
      end
    end

    # :frame means "allocated in the frame arena". Strings/arrays are value-typed (slice), only
    # frame-allocated structs are stored as *T pointers so large data stays off the fiber stack.
    is_pointer = heap? || (frame? && struct?)

    # 3. Handle Special primitive mapping
    # String and Byte[N] (fixed-size string literals) both map to []const u8.
    # Byte[N] is the inferred type for string literals; their contents are always const.
    if resolved == :String || string?
      return is_pointer ? "*[]const u8" : "[]const u8"
    end

    # 3b. Handle Pool / ShardedPool collection
    if pool?
      base_zig = element_type.zig_type(is_param: is_param, is_field: is_field)
      if soa?
        return "CheatLib.SoaPool(#{base_zig})"
      end
      return sharded? ? "CheatLib.ShardedPool(#{base_zig}, #{shard_count})" : "CheatLib.Pool(#{base_zig})"
    end

    # 3c. Handle @list / ShardedList collection
    if list_collection?
      base_zig = element_type.zig_type(is_param: is_param, is_field: is_field)
      return sharded? ? "CheatLib.ShardedList(#{base_zig}, #{shard_count})" : "std.ArrayListUnmanaged(#{base_zig})"
    end

    # 4. Handle Arrays recursively
    #    Dynamic arrays use ArrayListUnmanaged only for local variables to support growth.
    #    Struct fields and function parameters use slices.
    if array?
      base_zig = element_type.zig_type(is_param: is_param, is_field: is_field)
      if dynamic? && !is_param && !is_field
        zig = "std.ArrayListUnmanaged(#{base_zig})"
      else
        zig = "[]#{base_zig}"
      end
      return is_pointer && zig != "void" ? "*#{zig}" : zig
    end

    # 5. Handle HashMaps
    #    HashMap<V>         → std.StringHashMapUnmanaged(V)        (String keys)
    #    HashMap<K, V>      → CheatLib.NumericMapType(K, V)        (numeric keys)
    #    HashMap<V>:sharded(N)          → CheatLib.ShardedStringMap(V, N)
    #    HashMap<K,V>:sharded(N)        → CheatLib.ShardedNumericMap(K, V, N)
    #    HashMap<V>:sharded(N) @locked   → CheatLib.StripedStringMap(V, N)   (skew-safe)
    #    HashMap<K,V>:sharded(N) @locked → CheatLib.StripedNumericMap(K, V, N)
    if map?
      val_zig = value_type.zig_type
      if striped?  # sharded + sync = lock-striped
        if numeric_map?
          key_zig = key_type.zig_type
          return "CheatLib.StripedNumericMap(#{key_zig}, #{val_zig}, #{shard_count})"
        end
        return "CheatLib.StripedStringMap(#{val_zig}, #{shard_count})"
      end
      if sharded?
        if numeric_map?
          key_zig = key_type.zig_type
          return "CheatLib.ShardedNumericMap(#{key_zig}, #{val_zig}, #{shard_count})"
        end
        return "CheatLib.ShardedStringMap(#{val_zig}, #{shard_count})"
      end
      if numeric_map?
        key_zig = key_type.zig_type
        return "CheatLib.NumericMapType(#{key_zig}, #{val_zig})"
      end
      return "std.StringHashMapUnmanaged(#{val_zig})"
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

    # 6. Map primitives and fallback to struct names
    zig = case resolved
    when :Number     then "f64"
    when :Int64      then "i64"
    when :String     then "[]const u8"
    when :Void       then "void"
    when :Bool       then "bool"
    when :Byte       then "u8"
    when :Any        then "f64" # Default to Number for Any in Zig
    when :Range      then "CheatLib.Range"
    when :File       then "std.fs.File"
    when :TCPServer  then "i32"
    when :TCPClient  then "i32"
    else resolved.to_s  # Struct names (e.g., "User")
    end

    # 7. Add pointer prefix if heap-allocated and not void
    is_pointer && zig != "void" ? "*#{zig}" : zig
  end
end

# ==========================================
# TYPE CHECKING & AUTOCAST LOGIC
# ==========================================
module TypeHelper
  # Coerce input to Type object if needed
  def to_type(input)
    input.is_a?(Type) ? input : Type.new(input)
  end

  def is_safe_autocast?(source_type, target_type)
    to_type(target_type).accepts?(to_type(source_type))
  end

  def throw_assign_mismatch_error!(node, source_type, target_type)
    source = to_type(source_type)
    target = to_type(target_type)
    if target.array_overflow?(source)
      error!(node, :FIXED_ARRAY_SIZE_MISMATCH, target.capacity, source.resolved)
    else
      error!(node, "Type Mismatch: Cannot assign #{source.resolved} to #{node.type}")
    end
  end

  # TODO: If over 64kb => automatic heap
  # TODO: SROA & SIMD analysis -> if possible -> stack
  def finalize_storage(node, final_type, type_size)
    if (node.value.storage.nil? || node.value.storage == :stack) && node.value.type_object.requires_move?
      if type_size > 128
        node.value.storage = :frame
      else
        node.value.storage = :stack
      end
    end

    # Get storage info
    # (Assuming your AST::Literal or Value nodes have a storage field)
    storage = node.value.respond_to?(:storage) ? node.value.storage : :stack
    # Default to stack if storage is nil (e.g., primitives)
    storage ||= :stack

    # Increment frame after storage finalized
    @frame_usage_count += 1 if storage == :frame

    return storage
  end
end

