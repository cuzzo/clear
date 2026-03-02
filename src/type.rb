# Result struct for binary operation type resolution
BinaryOpResult = Struct.new(:type, :left_coercion, :right_coercion, :storage, :error, keyword_init: true)

class Type
  attr_reader :raw, :name, :generic_args, :capacity
  attr_accessor :mutability, :ownership, :lifetime_constraint
  attr_reader :location  # Use location= setter for cache invalidation

  # Enum constants for clarity
  LOCATIONS = [:stack, :frame, :heap, :multiowned, :shared, :locked, :shared_locked, :locked_shared]
  OWNERSHIP = [:unique, :borrowed, :shared, :static]

  # String type constants
  STRING_TYPE = :"String[]"
  HEAP_STRING_TYPE = :"%String[]"

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
    if t_left == :Int64 && t_right == :Int64
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
      left_coercion = (t_left != STRING_TYPE && safe_autocast?(t_left, STRING_TYPE)) ? STRING_TYPE : nil
      right_coercion = (t_right != STRING_TYPE && safe_autocast?(t_right, STRING_TYPE)) ? STRING_TYPE : nil
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

  def initialize(raw_input)
    @raw = raw_input
    parse_raw_input

    # Defaults
    @mutability = false
    @ownership = :unique # Default to owned/linear unless specified
    @lifetime_constraint = nil # nil means local scope
  end

  # -----------------------------------------------
  # COMPATIBILITY LAYER (The "Don't Break Tests" part)
  # -----------------------------------------------

  # Allow code to compare this object directly to symbols/strings
  # e.g. if node.type == :Number
  def ==(other)
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

    # Strip heap marker for the name
    result = (ft.to_s.start_with?("%") ? ft[1..] : ft).to_sym
    @resolved_cache = result
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
    # 1. Exact Match / Any
    return true if self == other_type || self.any? || other_type.any?

    # 2. Primitives (Widening)
    return true if self.numeric? && other_type.numeric? # Simplified logic
    return true if self.string? && other_type.byte?

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

    # 5. Array Coercion (The complex part from your Annotator)
    if self.array?
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

  def array?
    resolved.to_s.end_with?("]")
  end

  def string?
    resolved == :String || resolved == :"String[]" || (array? && (base_type == :Byte || base_type == :String))
  end

  def any?
    resolved == :Any
  end

  def dynamic?
    # It is dynamic if it is an array, but has NO fixed capacity
    array? && capacity.nil?
  end

  def fixed?
    # It is fixed if it is an array AND has a specific capacity
    array? && !capacity.nil?
  end

  def empty_list?
    # Handles the empty list literal "Any[]" or heap "%Any[]"
    # This is crucial for initializing typed arrays (e.g., `var x: Number[] = []`)
    resolved == :"Any[]"
  end

  def heap?
    @location == :heap
  end

  def multiowned?
    @location == :multiowned
  end

  def shared?
    @location == :shared
  end

  def locked?
    @location == :locked
  end

  def shared_locked?
    @location == :shared_locked
  end

  def locked_shared?
    @location == :locked_shared
  end

  # True for any locked-based capability
  def any_locked?
    @location == :locked || @location == :shared_locked || @location == :locked_shared
  end

  def map?
    resolved.to_s.start_with?("HashMap")
  end

  # TODO: keep metatype from ast, use that
  def struct?
    !primitive? && !any? && !void? && !string? && !array? && !map? && !optional? && !error_union?
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

  def element_type
    return nil unless array?
    # Uses the capture from parse_raw_input, ensuring "Number[3]" becomes "Number"
    @element_type_obj ||= Type.new(@element_type_raw || :Any)
  end

  def slot_size(lookup_arg = nil, &lookup_block)
    resolver = lookup_arg || lookup_block

    # 1. Primitives / Pointers (Heap objects are 1 slot pointers; Rc/Arc/Locked are also pointer-sized)
    return 1 if primitive? || heap? || dynamic? || any? || multiowned? || shared? || any_locked?

    # 2. Fixed Arrays (Recursion)
    if fixed?
      return capacity * element_type.slot_size(resolver)
    end

    # 3. Structs (The tricky part)
    if struct?
      raise "Need lookup context for struct size" unless resolver
      schema = resolver.call(resolved)
      return schema.values.sum { |t| Type.new(t).slot_size(resolver) }
    end

    1 # Default
  end

  # TODO: In future, need to be able to call slot-size for small structs.
  def requires_move?
    return false if multiowned? || shared?  # Rc/Arc use retain/release, not linear move semantics
    return false if any_locked?             # Locked vars manage their own lifecycle
    return true if heap?
    return true if array?
    !primitive?
  end

  def copyable?(lookup_arg = nil, &lookup_block)
    return true if primitive?
    return false if multiowned? || shared? || any_locked?  # Rc/Arc/Locked must not be silently copied
    return false if heap?                   # Heap-allocated types are not copyable
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

  # Returns the Zig type string representation of this type.
  # Memoized for performance; cache is invalidated when location changes.
  def zig_type
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

    # Locked capabilities stay in their storage class
    return :locked        if locked?        || current_storage == :locked
    return :shared_locked if shared_locked? || current_storage == :shared_locked
    return :locked_shared if locked_shared? || current_storage == :locked_shared

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
    str = @raw.to_s
    original_str = str  # Keep original for resolved_cache

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

    # C. Initialize location based on capability prefix
    #    ^~ = shared_locked (Arc(Locked(T))), ~^ = locked_shared (Locked(Arc(T))),
    #    @ = multiowned/Rc, ^ = shared/Arc, ~ = locked/Locked, % = unique heap
    if str.start_with?("^~")
      @location = :shared_locked
      str = str[2..]
    elsif str.start_with?("~^")
      @location = :locked_shared
      str = str[2..]
    elsif str.start_with?("@")
      @location = :multiowned
      str = str[1..]
    elsif str.start_with?("^")
      @location = :shared
      str = str[1..]
    elsif str.start_with?("~")
      @location = :locked
      str = str[1..]
    elsif str.start_with?("%")
      @location = :heap
      str = str[1..] # Strip the % so we can parse the inner type cleanly
    elsif primitive?
      @location = :stack
    else
      @location = :frame
    end

    # D. Detect Array Structure
    # Regex Breakdown:
    #   ^       Start of string
    #   (.+)    Capture Group 1: Base Type (e.g. "Number")
    #   \[      Literal opening bracket
    #   (\d+)?  Capture Group 2: Optional Digits (Capacity).
    #           If this is missing, it matches "[]", meaning Dynamic.
    #   \]      Literal closing bracket
    #   $       End of string
    if match = str.match(/^(.+)\[(\d+)?\]$/)
      @is_array = true
      @element_type_raw = match[1].to_sym # Store "Number"

      # If Capture Group 2 exists, it's the capacity.
      # If nil, it's dynamic.
      @capacity = match[2]&.to_i
    else
      @is_array = false
      @capacity = nil
      @element_type_raw = nil
    end

    # Keep the full type including ! and ? prefixes for resolved,
    # but strip capability markers (% = unique heap, @ = multiowned, ^ = shared, ~ = locked) since they are not type-level.
    @resolved_cache = original_str.gsub("%", "").gsub("@", "").gsub("^", "").gsub("~", "").to_sym
  end

  # Computes the Zig type string for this CHEAT type.
  # Handles: error unions, optionals, multiowned (Rc), pointers, arrays, hashmaps, primitives, structs.
  def compute_zig_type
    # 1. Handle Error Union: !T -> !zig_type
    if error_union?
      inner_zig = payload_type.zig_type
      return "!#{inner_zig}"
    end

    # 2. Handle Optional: ?T -> ?zig_type
    if optional?
      inner_zig = wrapped_type.zig_type
      return "?#{inner_zig}"
    end

    # 2b. Handle Multiowned: @T -> CheatLib.Rc(T)
    if multiowned?
      inner_zig = Type.new(resolved.to_s).zig_type
      return "CheatLib.Rc(#{inner_zig})"
    end

    # 2c. Handle Shared: ^T -> CheatLib.Arc(T)
    if shared?
      inner_zig = Type.new(resolved.to_s).zig_type
      return "CheatLib.Arc(#{inner_zig})"
    end

    # 2d. Handle Locked: ~T -> *CheatLib.Locked(T)
    if locked?
      inner_zig = Type.new(resolved.to_s).zig_type
      return "*CheatLib.Locked(#{inner_zig})"
    end

    # 2e. Handle SharedLocked: ^~T -> CheatLib.Arc(CheatLib.Locked(T))
    if shared_locked?
      inner_zig = Type.new(resolved.to_s).zig_type
      return "CheatLib.Arc(CheatLib.Locked(#{inner_zig}))"
    end

    # 2f. Handle LockedShared: ~^T -> *CheatLib.Locked(CheatLib.Arc(T))
    if locked_shared?
      inner_zig = Type.new(resolved.to_s).zig_type
      return "*CheatLib.Locked(CheatLib.Arc(#{inner_zig}))"
    end

    is_pointer = heap?

    # 3. Special case: String[] is the atomic "Text" type
    #    This prevents "String[][]" from becoming a 3D array.
    if resolved == :"String[]"
      return is_pointer ? "*[]const u8" : "[]const u8"
    end

    # 4. Handle Arrays recursively
    #    e.g. "Number[]" -> "[]i64", "String[][]" -> "[][]const u8"
    if array?
      base_zig = element_type.zig_type
      zig = "[]#{base_zig}"
      return is_pointer && zig != "void" ? "*#{zig}" : zig
    end

    # 5. Handle HashMaps
    #    HashMap<Int64> -> std.StringHashMapUnmanaged(i64)
    str = resolved.to_s
    if str.start_with?("HashMap")
      if match = str.match(/HashMap<(.+)>/)
        inner_zig = Type.new(match[1]).zig_type
        return "std.StringHashMapUnmanaged(#{inner_zig})"
      end
    end

    # 6. Map primitives and fallback to struct names
    zig = case resolved
    when :Number     then "f64"
    when :Int64      then "i64"
    when :String     then "[]const u8"
    when :"String[]" then "[]const u8"
    when :Void       then "void"
    when :Bool       then "bool"
    when :Byte       then "u8"
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

