class Type
  attr_reader :raw, :name, :generic_args, :capacity
  attr_accessor :location, :mutability, :ownership, :lifetime_constraint

  # Enum constants for clarity
  LOCATIONS = [:stack, :frame, :heap]
  OWNERSHIP = [:unique, :borrowed, :shared, :static]

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

    # 1. Primitives / Pointers (Heap objects are 1 slot pointers)
    return 1 if primitive? || heap? || dynamic? || any?

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
    return true if heap?
    return true if array?
    !primitive?
  end

  def copyable?(lookup_arg = nil, &lookup_block)
    return true if primitive?
    return false if heap?    # Heap-allocated types are not copyable
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

    # C. Initialize location based on "%" prefix
    if str.start_with?("%")
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

    # Keep the full type including ? prefix for resolved
    @resolved_cache = original_str.gsub("%", "").to_sym
  end
end

