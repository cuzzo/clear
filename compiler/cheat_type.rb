class CheatType
  STRING_TYPE = "String".to_sym
  HEAP_STRING_TYPE = "%String".to_sym

  # SHAPE: What is the data layout?
  # :int, :float, :bool, :void, :char (primitives)
  # :struct, :enum (composites)
  # :array, :list, :slice, :string, :map (collections)
  attr_accessor :shape

  # STORAGE: Where does it live?
  # :immediate (Register/Stack value - i64, f64, bool)
  # :frame     (Stack Memory / Scratchpad - T[N], User)
  # :arena     (Heap Memory / Persistent - %List, %User)
  # :global    (Read-only Data - String literals)
  attr_accessor :storage

  # IDENTITY: If shape is :struct, what is its name?
  attr_accessor :struct_name

  # GENERICS: Recursive CheatType
  # e.g. for Int64[], inner_type is CheatType(:Int64)
  attr_accessor :inner_type

  # SIZE: For Fixed Arrays (e.g. Number[3]), how many?
  attr_accessor :array_len

  # MUTABILITY: Tracked separately from the type string usually,
  # but good to have a slot for it when passing types around.
  attr_accessor :mutable

  # FUNCTION METADATA
  attr_accessor :param_types  # Array of CheatTypes (for functions/procs)
  attr_accessor :return_type  # CheatType (for functions/procs)

  # Class-level storage for struct definitions
  # Format: { User: { id: CheatType(:Int64), name: CheatType(:String) } }
  @@struct_definitions = {}
  def self.define_struct(name, schema)
    @@struct_definitions[name.to_sym] = schema
  end

  def self.lookup_struct(name)
    @@struct_definitions[name.to_sym]
  end

  def initialize(shape, storage: :immediate, struct_name: nil, inner_type: nil, array_len: nil, mutable: false, param_types: [], return_type: nil)
    @shape = shape
    @storage = storage
    @struct_name = struct_name
    @inner_type = inner_type
    @array_len = array_len
    @mutable = mutable
    @param_types = param_types
    @return_type = return_type
  end

  # =========================================================================
  # FACTORY: Parse your existing String/Symbol types
  # =========================================================================
  def self.create(input)
    return input if input.is_a?(CheatType)
    return new(:Void) if input.nil?

    # 1. HANDLE NAMED FUNCTION SIGNATURE (Hash)
    # {:params => [{name, type, ...}], :return_type => ...}
    if input.is_a?(Hash)
      return parse_function_hash(input)
    end

    # 2. HANDLE PROC/LAMBDA SIGNATURE (Array)
    # [:Proc, [ArgTypes...], ReturnType]
    if input.is_a?(Array)
      if input[0] == :Proc
        return parse_proc_array(input)
      else
        raise "PROC CREATION ERROR!"
      end
    end

    # 3. HANDLE STRING / SYMBOL
    parse_string(input.to_s)
  end

  # =========================================================================
  # PARSING LOGIC
  # =========================================================================

  def self.parse_function_hash(hash)
    # Extract Parameters
    params = (hash[:params] || []).map do |p|
      # p is {:name, :type, :mutable...}
      t = self.create(p[:type])
      t.mutable = p[:mutable] # Carry over mutability
      t
    end

    # Extract Return Type
    # Note: Logic for return types is strict about pointers
    ret = self.create(hash[:return_type] || :Void)
    enforce_return_storage!(ret)

    new(:Function,
      storage: :global,           # Functions live in code segment
      param_types: params,
      return_type: ret
    )
  end

  def self.parse_proc_array(arr)
    # [:Proc, [ArgTypes], ReturnType]
    param_types = (arr[1] || []).map { |t| self.create(t) }
    ret = self.create(arr[2] || :Void)
    enforce_return_storage!(ret)

    new(:Lambda,
      storage: :frame,           # Closures usually live on the frame/heap
      param_types: param_types,
      return_type: ret
    )
  end

  def self.parse_string(type_input)
    return type_input if type_input.is_a?(CheatType)

    str = type_input.to_s

    # 1. Determine Storage (Sigil Check)
    storage = :immediate # Default for primitives

    if str.start_with?("%")
      storage = :arena
      str = str[1..-1] # Strip '%'
    end

    # 2. Determine Shape via Regex

    str = str.gsub("String[]", "String")  # Strings are snowflakes til further revamps

    # CASE: Fixed Array "Type[N]"
    # TODO: May need to handle Type[*]
    if match = str.match(/^(.+)\[(\d+)\]$/)
      base_str = match[1]
      count = match[2].to_i
      return new(:Array,
        storage: (storage == :arena ? :arena : :frame), # Fixed arrays default to frame unless %
        array_len: count,
        inner_type: self.create(base_str)
      )

    # CASE: Dynamic List/Slice "Type[]"
    elsif match = str.match(/^(.+)\[\]$/)
      base_str = match[1]
      inner = self.create(base_str)

      # The Matrix Logic:
      # %Type[] -> Dynamic List (Arena)
      # Type[]  -> Slice (Frame/View) - or Fixed Array without size known yet
      shape = (storage == :arena) ? :List : :Slice

      return new(shape,
        storage: storage == :arena ? :arena : :frame,
        inner_type: inner
      )

    # CASE: HashMap "HashMap<Type>"
    elsif match = str.match(/^HashMap<(.+)>$/)
      return new(:HashMap,
        storage: :arena, # Maps are always complex/heap
        inner_type: self.create(match[1])
      )
    end

    # CASE: Primitives & Structs
    case str
    when "Int64", "Byte"      then new(:Int64, storage: :immediate)
    when "Number", "Float64"  then new(:Number, storage: :immediate)     # TODO: Update Number => Float64
    when "Bool"               then new(:Bool, storage: :immediate)
    when "Void"               then new(:Void, storage: :immediate)
    when "Any"                then new(:Any, storage: :immediate) # Placeholder
    when "String"
      # String is a special Slice of Chars
      new(STRING_TYPE, storage: :frame)        # Strings are views (slices) -> Legacy Snowflakes
    else
      # Fallback: It's a Struct
      # If it had a %, storage is already :arena, otherwise :frame
      storage = (storage == :arena) ? :arena : :frame
      new(:Struct, storage: storage, struct_name: str.to_sym)
    end
  end

  # =========================================================================
  # INTELLIGENT INFERENCE
  # =========================================================================

  # The "Missing Sigil" Logic for Return Types
  # If a function returns "List", it MUST be a pointer to the Arena.
  # If it returns "Point" (Flat), it can be on the Stack (SRVO).
  #
  # TODO: Need access to struct definitions
  def self.enforce_return_storage!(type)
    return if type.storage == :arena # Already explicit

    # Dynamic/Complex types MUST live in Arena to survive return
    # (unless they are slices/views, but usually we return Objects)
    if [:List, :HashMap].include?(type.shape)
      type.storage = :arena
    end

    # Note: Structs default to :frame (Stack), which enables SRVO.
    # Note: Strings default to :frame (Slice), which is fine (2 ints).
  end

  # =========================================================================
  # HELPER PREDICATES (Replacing your AST::Locatable logic)
  # =========================================================================

  def is_pointer?
    [:arena, :frame, :global].include?(@storage) && @shape != STRING_TYPE
  end

  # Everything is *technically* flat, this moreso means is it safe for SRVO
  # If it points to anything, it is *not* flat.
  def is_flat?
    case @shape
    when :Int64, :Float64, :Number, :Bool, :Enum then true    # TODO: Remove Number
    when :Struct
      fields = self.class.lookup_struct(@struct_name)
      raise "Unknown Struct: #{@struct_name}" if fields.nil?

      # TODO: This will infinite loop on cycles
      fields.values.all? { |field_type| field_type.is_flat? }
    when :Array
      @inner_type.is_flat?
    else
      false # Lists, Maps, Strings are complex
    end
  end

  def is_iterable?
    [:List, :Array, :Slice, STRING_TYPE].include?(@shape)
  end

  # =========================================================================
  # TRANSPILER HELPERS
  # =========================================================================

  def allocator_code
    case @storage
    when :arena  then "rt.heapAlloc()"
    when :frame  then "rt.frameAlloc()"
    when :global then "rt.globalAlloc()"
    else "rt.frameAlloc()"
    end
  end

  # Convert back to string for debugging/equality checks
  def to_s
    prefix = (@storage == :arena) ? "%" : ""

    suffix = case @shape
             when :Array then "[#{@array_len}]"
             when :List, :Slice then "[]"
             when :HashMap then "<#{@inner_type}>"
             else ""
             end

    name = @struct_name || primitive_name || "Unknown"
    "#{prefix}#{name}#{suffix}"
  end

  # TODO: Just use to_s
  def primitive_name
    case @shape
    when :Int64 then "Int64"
    when :Float64 then "Float64"
    when :Bool then "Bool"
    when :Void then "Void"
    when STRING_TYPE then "String"
    when :HahMap then "HashMap"
    when :Any then "Any"
    end
  end

  # For compatibility with your hash checks
  def ==(other)
    other.to_s == self.to_s
  end
end
