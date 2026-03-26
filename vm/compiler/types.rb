require "msgpack"
require "forwardable"

require_relative "./arena"

module Formatter
  def self.to_native(val)
    # FIX: Use bitwise mask to check for NanBox tags.
    # Ruby handles 2's complement logic for negative integers automatically in bitwise ops.
    if val.is_a?(Integer) && defined?(Value) && (val & Value::QNAN_MASK) == Value::QNAN_MASK
       return Value.unbox(val)
    end

    return val if val.is_a?(Numeric) || val.is_a?(String) || val.nil?

    if val.is_a?(MemorySlice) || val.is_a?(FluxArray)
      return val.to_s
    end

    return Value.to_native(val) if defined?(Value) && Value.respond_to?(:to_native)

    val
  end
end

###
# TYPES
##

class FluxObject
  attr_reader :is_alive, :flux_id

  def initialize(register: true)
    @is_alive = true
    @is_frozen = false

    @flux_id = Arena.allocate_id

    if register == :static
      Arena.register_static(self)
    elsif register
      Arena.current.register(self)
    end
  end

  def ==(other)
    equal?(other)
  end

  def freeze!
    @is_frozen = true
  end

  def frozen?
    @is_frozen
  end

  def check_alive!
    unless @is_alive
      raise "Memory Error: Use After Free! Object accessed after its scope ended."
    end
  end

  def is_alive?
    @is_alive
  end
  def is_poisoned?
    !@is_alive
  end

  def poison!
    @is_alive = false
    # Help Ruby GC clean up the heavy data
    @data = nil
    @owner = nil
  end
end

###
# PRIMITIVE TYPES - PASS BY VALUE - NO ARENA
##

class FluxByte
  attr_reader :value
  def initialize(val)
    @value = val.to_i % 256
  end

  # Math returns NEW Byte (Auto-Wrapping)
  # IMPORTANT: Byte is a primitive.
  def +(other); FluxByte.new(@value + other.value); end
  def -(other); FluxByte.new(@value - other.value); end
  def *(other); FluxByte.new(@value * other.value); end

  # Division / Modulo
  def /(other); FluxByte.new(@value / other.value); end
  def %(other); FluxByte.new(@value % other.value); end
  def **(other); FluxByte.new(@value ** other.value); end

  # Bitwise
  def ~; FluxByte.new(~@value); end

  # Comparison (These return standard Bools)
  def <(other);  @value < other.value; end
  def >(other);  @value > other.value; end
  def <=(other); @value <= other.value; end
  def >=(other); @value >= other.value; end
  def !=(other); @value != other.value; end
  def ==(other); other.is_a?(FluxByte) && @value == other.value; end

  def to_s; "0x#{@value.to_s(16).upcase.rjust(2, '0')}"; end
  def inspect; to_s; end
end

class FluxInt64 < FluxObject
  attr_reader :value

  def initialize(val, register: true)
    super(register: register)
    @value = val.to_i
  end

  # Value semantics: Operations return NEW objects
  def +(other)
    FluxInt64.new(@value + other.value)
  end

  def to_s; "#{@value}_i64"; end
  def inspect; "#{@value}_i64"; end
end

###
# HEAP TYPES - PASS BY REFERENCE - ARENA MANAGED
##

class FluxClosure < FluxObject
  attr_reader :chunk, :captures

  def initialize(chunk, captures, register: true)
    super(register: register)
    @chunk = chunk
    @captures = captures # Array of Boxed Values
  end

  def to_s; "FN<#{@chunk.name}>"; end
  def inspect; to_s; end
end

class FluxArray < FluxObject
  attr_reader :data, :max_size, :type
  attr_accessor :struct_type # Accessible for VM monkey-patching

  # TYPE SCHEMA:
  # :obj    -> Standard Array of Ruby native values
  # :nanbox -> Packed NanBox String (8 bytes per item - can store Int52, Float64, Pointers to strings, etc)
  # :int64  -> Packed Binary String (8 bytes per item)
  # :byte   -> Packed Binary String (1 byte per item)
  def initialize(max_size, initial_data, register: true, type: :obj, struct_type: nil)
    super(register: register) # Register with Arena

    @struct_type = struct_type
    @max_size = max_size
    @data = initial_data
    @type = type

    if @type == :obj
      @data = initial_data || []
      # Ensure size matches max_size if strict
      if @max_size && @data.size < @max_size
        @data.fill(nil, @data.size...@max_size)
      end
    else
      # BINARY MODE: @data is a Byte String
      # Initialize string of NULL bytes
      bytes_per_item = (@type == :byte) ? 1 : 8
      size = max_size || 0

      # 1. Allocate Binary Blob
      @data = ("\x00" * (size * bytes_per_item)).force_encoding("BINARY")

      # 2. Fill if data provided
      if initial_data && !initial_data.empty?
        initial_data.each_with_index { |v, i| self[i] = v }
      end
    end
  end

  # Need to allow dynamic resize.
  def <<(val)
    check_alive!
    if @type != :obj
      raise "Runtime Error: Cannot push/append to a Fixed Binary Array. Use index assignment."
    end
    if @max_size && @data.size >= @max_size
      raise "Runtime Error: Cannot append to Fixed Array (Max size: #{@max_size})"
    end
    @data << val
  end

  def [](idx)
    check_alive!
    if @type == :obj
      @data[idx]
    elsif @type == :int64
      # UNPACK: Extract 64-bit int
      raw = @data.byteslice(idx * 8, 8)
      raise "Index out of bounds" unless raw
      val = raw.unpack1('q<')
      Value.box_number(val)
    elsif @type == :byte
      # UNPACK: Extract 1 byte
      byte_val = @data.getbyte(idx)
      raise "Index out of bounds" unless byte_val
      Value.box_byte(byte_val)
    elsif @type == :nanbox
      raw_bits = @data.byteslice(idx * 8, 8).unpack1('q<')

      # Check Mask
      if defined?(Value) && (raw_bits & Value::QNAN_MASK) == Value::QNAN_MASK
        return raw_bits # Return as Integer (Preserve the Tag)
      else
        # It's a Float! Re-interpret the bits as a Double.
        return [raw_bits].pack('q<').unpack1('d')
      end
      return val
    end
  end

  def []=(idx, val_boxed)
    check_alive!
    if @type == :obj
      @data[idx] = val_boxed
    elsif @type == :int64
      # PACK: Convert NanBox -> Raw Int64
      val = Value.unbox(val_boxed).to_i
      @data[idx * 8, 8] = [val].pack('q<')
    elsif @type == :byte
      val = Value.unbox(val_boxed)
      unless val.is_a?(Numeric)
        raise "Runtime Error: Cannot assign non-numeric to Byte array"
      end
      @data.setbyte(idx, val.to_i % 256)
    elsif @type == :nanbox
      if val_boxed.is_a?(Float)
        @data[idx * 8, 8] = [val_boxed].pack('d')
      elsif val_boxed.is_a?(Integer)
        @data[idx * 8, 8] = [val_boxed].pack('q<')
      else
        raise "Memory Error: Cannot store #{val_boxed.class} in NanBox Array"
      end
    end
  end

  def deep_copy
    check_alive!
    FluxArray.new(@max_size, @data.dup)
  end

  def size; check_alive!; @type == :obj ? @data.size : (@data.size / ((@type == :byte) ? 1 : 8)); end
  def each(&block); check_alive!; @data.each(&block); end

  def to_msgpack(packer=nil)
    check_alive!
    { "max" => @max_size, "data" => @data }.to_msgpack(packer)
  end

  def self.decode_binary_blob(blob, offset, count, type)
    results = []
    count.times do |i|
      if type == :byte
        byte = blob.getbyte(offset + i)
        results << byte # Return native Int
      elsif type == :int64
        val = blob.byteslice((offset + i) * 8, 8)&.unpack1('q<') || 0
        results << val
      elsif type == :nanbox
        raw_bits = blob.byteslice((offset + i) * 8, 8)&.unpack1('q<') || 0

        if defined?(Value) && (raw_bits & Value::QNAN_MASK) == Value::QNAN_MASK
          results << Formatter.to_native(raw_bits)
        else
          val = [raw_bits].pack('q<').unpack1('d')
          results << val
        end
      end
    end
    results
  end

  def slice_to_native(offset, count)
    check_alive!
    if @type == :obj
      @data[offset, count].map { |v| Formatter.to_native(v) }
    else
      byte_offset = (@type == :byte) ? offset : offset * 8
      FluxArray.decode_binary_blob(@data, byte_offset, count, @type)
    end
  end

  def to_a_native
    slice_to_native(0, size)
  end

  def read_at(index)
    self[index]
  end

  def write_at(index,value)
    self[index] = value
  end

  def to_boxed_a
    # If it's :obj, data is already boxed.
    # If it's :byte/:nanbox, we need to convert internal buffer to boxed array
    if @type == :obj
      @data
    else
      # Convert binary blob to array of boxed values
      (0...size).map { |i| self[i] }
    end
  end

  # --- FORMATTING LOGIC ---

  def to_s
    check_alive!
    native_list = to_a_native

    # Heuristic: If explicitly byte or Struct Type implies byte
    if @type == :byte || (@struct_type && @struct_type.to_s.include?("Byte"))
      # Map integers to chars and join
      native_list.map do |x|
        val = x.is_a?(Numeric) ? x.to_i : x
        val.is_a?(Integer) ? val.chr : val.to_s
      end.join
    else
      # Standard list output: [1, 2, 3]
      native_list.to_s
    end
  end

  def inspect
    check_alive!

    lbl = if @struct_type
      @struct_type.to_s
    else
      case @type
      when :byte then "Byte"
      when :nanbox then "NanBox"
      when :int64 then "Int64"
      else "Obj"
      end
    end

    if @struct_type
      "#{lbl}{#{size}}"
    else
      "#{lbl}[#{size}]"
    end
  end

  def method_missing(m, *args, &block)
    check_alive!
    if @data.respond_to?(m)
      @data.send(m, *args, &block)
    else
      super
    end
  end
end

class FluxHash < FluxObject
  attr_reader :data

  def initialize(initial_data = {}, register: true)
    super(register: register)
    @data = initial_data
  end

  def [](key)
    check_alive!
    @data[key]
  end

  def []=(key, val)
    check_alive!
    @data[key] = val
  end

  def key?(k); check_alive!; @data.key?(k); end
  def keys; check_alive!; @data.keys; end

  def to_s; check_alive!; @data.to_s; end
  def inspect; check_alive!; "Hash{#{data.size}}"; end

  def to_msgpack(packer=nil)
    check_alive!
    @data.to_msgpack(packer)
  end
end

class FluxString < FluxObject
  attr_reader :data

  def initialize(val, register: false)
    super(register: register)
    @data = val.to_s
  end

  def +(other)
    check_alive!
    other_str = other.is_a?(FluxString) ? other.data : other.to_s
    FluxString.new(@data + other_str, register: true)
  end

  def read_at(index)
    @data[index]
  end

  def write_at(index, value)
    raise "Can only write char" if !value.is_a?(String)
    raise "Can only write char" if !value.len == 1
    @data[index] = value
  end

  def to_s; check_alive!; @data.to_s; end
  def inspect; @data.inspect; end

  def to_msgpack(packer=nil)
    check_alive!
    @data.to_msgpack(packer)
  end
end

# ... View Types and Serialization Registry remain the same ...
class MemorySlice < FluxObject
  attr_reader :container, :offset, :size, :kind

  def initialize(container, offset, size, kind = nil)
    # We do NOT register slices in the Arena usually,
    # unless they are stored in a Register (which they are).
    super(register: true)

    # If we take a slice of a slice, point to the original container.
    if container.is_a?(MemorySlice)
      @container = container.container
      @offset = container.offset + offset
      @kind = kind || container.kind # Inherit if nested
    else
      @container = container
      @offset = offset
      @kind = kind
    end

    @size = size
  end

  def deref
    @container
  end

  # --- THE UNIFIED INTERFACE ---

  def read_at(index)
    if @container.is_a?(FluxObject) && !@container.is_alive
      raise "Memory Error: Dangling Pointer! MemorySlice accessed after container died."
    end
    if index < 0 || index >= @size
      raise "Runtime Error: View index out of bounds"
    end
    @container.read_at(@offset + index)
  end

  def write_at(index, value)
    if index < 0 || index >= @size
      raise "Runtime Error: View index out of bounds"
    end
    @container.write_at(@offset + index, value)
  end

  # For Iteration (map, etc)
  def to_boxed_a
    (0...@size).map { |i| read_at(i) }
  end

  # For Debugging
  def to_native_a
    to_boxed_a.map { |x| Formatter.to_native(x) }
  end

  def to_s
    if is_string_like?
      # OPTIMIZATION: If the container is actually a String wrapper,
      # use Ruby's native slicing (Fast)
      if @container.is_a?(FluxString)
        return @container.data[@offset, @size]
      end

      # FALLBACK: Stack Strings / Byte Arrays
      # Unbox the integers, convert to Char, and join.
      return to_boxed_a.map { |v| Value.unbox(v).to_i.chr }.join
    end

    # Default: Print as a list [10, 20, 30]
    to_native_a.to_s
  end

  def inspect
    content = to_s
    content = "\"#{content}\"" if is_string_like?
    "Slice<#{@size}>#{content}"
  end

  private

  def is_string_like?
    # 1. Is the container explicitly a String? (Heap String View)
    return true if @container.is_a?(FluxString)

    # 2. Was this slice created with a Type Hint? (Stack String / ALLOCA)
    #    e.g. kind="String" or kind="Byte[10]"
    return true if @kind.to_s.include?("Byte") || @kind.to_s == "String"

    # 3. Is the container a Byte Array? (Heap Byte Array View)
    return true if @container.is_a?(FluxArray) && @container.type == :byte

    false
  end
end

# Unused
class FluxHeapPtr < FluxObject
  attr_reader :owner
  def initialize(owner); super(); @owner = owner; end
  def check_alive!
    super
    if @owner.respond_to?(:is_alive) && !@owner.is_alive
      raise "Memory Error: Dangling Pointer! Accessing a dead object."
    end
  end
  def deref; check_alive!; @owner; end
  def to_s; "&(#{@owner})"; end
  def inspect; to_s; end
  def to_msgpack(packer=nil); check_alive!; @owner.to_msgpack(packer); end
end

MessagePack::DefaultFactory.register_type(
  1,
  FluxByte,
  packer: ->(obj) { obj.value.chr },
  unpacker: ->(data) { VM::FluxByte.new(data.ord) }
)
MessagePack::DefaultFactory.register_type(
  2, # Use a unique ID (FluxByte is 1)
  FluxInt64,
  packer: ->(obj) { [obj.value].pack('q>') }, # Serialize to 8-byte string
  unpacker: ->(data) { FluxInt64.new(data.unpack1('q>')) } # Deserialize back to Object
)

