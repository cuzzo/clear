require "msgpack"
require "forwardable"

require_relative "./arena"

###
# TYPES
##

class FluxObject
  attr_reader :is_alive

  def initialize(register: true)
    @is_alive = true
    @is_frozen = false

    if register == :static
      Arena.register_static(self)
    elsif register
      Arena.current.register(self)
    end
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

  def poison!
    @is_alive = false
    # Help Ruby GC clean up the heavy data
    @data = nil
    @owner = nil
  end
end

class FluxStackPtr < FluxObject
  attr_reader :offset, :size, :container, :struct_type

  def initialize(offset, size, container, struct_type = nil)
    # Note: We don't register this in the Arena.
    # It is a temporary value that lives in a Register.
    super(register: true)
    @offset = offset
    @size = size
    @container = container
    @struct_type = struct_type
  end

  def to_s; "StackPtr(#{@offset})"; end
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
  attr_reader :data, :max_size, :struct_type

  # TYPE SCHEMA:
  # :obj    -> Standard Array of Ruby native values
  # :nanbox -> Packed NanBox String (8 bytes per item - can store Int52, Float64, Pointers to strings, etc)
  # :int64  -> Packed Binary String (8 bytes per item)
  # :byte   -> Packed Binary String (1 byte per item)
  def initialize(max_size, initial_data, register: true, type: :obj, struct_type: nil)
    super(register: :register) # Register with Arena

    @struct_type = struct_type
    @max_size = max_size
    @data = initial_data
    @type = type

    # TODO: Fill remaining space with nil? Or just keep it empty but bounded?
    # "Fixed array" usually means you can't change the size (no push/pop).

    if @type == :obj
      @data = initial_data || []
    else
      # BINARY MODE: @data is a Byte String
      # Initialize string of NULL bytes
      bytes_per_item = (@type == :int64) ? 8 : 1
      size = max_size || 0
      @data = ("\x00" * (size * bytes_per_item)).force_encoding("BINARY")

      # If we have initial data (literals), pack them now
      if initial_data && !initial_data.empty?
        initial_data.each_with_index { |v, i| self[i] = v }
      end
    end
  end

  # Need to allow dynamic resize.
  def <<(val)
    check_alive!
    if @type != :obj # TODO: Think about this
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
      # offset = idx * 8
      # 'q<' = 64-bit signed integer, little endian
      raw = @data.byteslice(idx * 8, 8)
      raise "Index out of bounds" unless raw

      val = raw.unpack1('q<')

      # RE-BOX: Convert raw 64-bit int back to NanBox/FluxInteger
      Value.box_number(val)
    elsif @type == :byte
      # UNPACK: Extract 1 byte
      byte_val = @data.getbyte(idx)
      raise "Index out of bounds" unless byte_val
      Value.box_byte(byte_val)
    elsif @type == :nanbox
      raw_bits = @data.byteslice(idx * 8, 8).unpack1('q<')

      # 2. Check the NanBox Mask (Top 16 bits)
      # Mask: 0xFFF0000000000000
      # If these bits are set, it is a SPECIAL VALUE (Pointer, Bool, Nil).
      # If not, it is a Standard Number (Float).
      if (raw_bits & Value::QNAN_MASK) == Value::QNAN_MASK
        return raw_bits # Return as Integer (Preserve the Tag)
      else
        # It's a Float! Re-interpret the bits as a Double.
        return [raw_bits].pack('q<').unpack1('d')
      end
      return val # the value here is EITHER the double, or already boxed.
    end
  end

  # TODO: Need to keep set overflow error
  def []=(idx, val_boxed)
    check_alive!
    if @type == :obj
      @data[idx] = val_boxed
    elsif @type == :int64
      # PACK: Convert NanBox -> Raw Int64
      val = Value.unbox(val_boxed).to_i # Handle Float or FluxInteger

      # Replace 8 bytes at offset
      # pack('q<') returns an 8-byte string
      @data[idx * 8, 8] = [val].pack('q<')
    elsif @type == :byte
      val = Value.unbox(val_boxed)
      unless val.is_a?(Numeric)
        raise "Runtime Error: Cannot assign non-numeric to Byte array"
      end
      # Auto-truncate / Wrap to 0-255 (Standard C behavior)
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
    # Creates a new allocation in the current scope
    FluxArray.new(@max_size, @data.dup)
  end

  # size and each are not expressly necessary due to method missing below.
  # here for performance and rspec oddities.
  def size; check_alive!; @data.size; end
  def each(&block); check_alive!; @data.each(&block); end

  # MessagePack Support
  def to_msgpack(packer=nil)
    check_alive!
    # We need to serialize the constraint too!
    # We can pack as a custom type or just a hash for now.
    { "max" => @max_size, "data" => @data }.to_msgpack(packer)
  end

  def to_s
    max_size.nil? ? "<Dynamic[] #{@data.to_s}>" : "<Fixed[#{@max_size}] #{@data.to_s}>"
  end

  def inspect; @data.to_s; end

  # Delegate other methods to @data if needed (each, map, etc)
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
  def inspect; @data.to_s; end

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

  def to_s; check_alive!; @data.to_s; end
  def inspect; @data.inspect; end

  def to_msgpack(packer=nil)
    check_alive!
    @data.to_msgpack(packer)
  end
end

###
# VIEW TYPES - ZERO-COPY SLICES - MUST BE INVALIDATED BY COMPILER FOR SAFETY!!
##

class FluxView < FluxObject
  attr_reader :owner, :offset, :len

  def initialize(owner, offset, len)
    super()
    @owner = owner
    @offset = offset
    @len = len
  end

  def check_alive!
    super # Check if the View itself is valid (in scope)

    # CRITICAL: Check if the OWNER is still valid
    # If the owner was poisoned (popped stack), the view must fail.
    unless @owner.is_alive
      raise "Memory Error: Dangling Pointer! View accessed after Owner died."
    end
  end

  def [](idx)
    check_alive!
    if idx >= @len
      raise "Runtime Error: View index out of bounds"
    end

    # Implicit Deref: Forward to owner
    # Note: Strings and Arrays handle [] differently in Ruby
    if @owner.is_a?(FluxString)
      # String Slice
      @owner.data[@offset + idx]
    else
      # Array Access
      @owner[@offset + idx]
    end
  end

  # Convert View -> Owner (Implicit Promotion)
  def to_string_copy
    check_alive!
    if @owner.is_a?(FluxString)
      FluxString.new(@owner.data[@offset, @len])
    else
      raise "Cast Error: Cannot convert Array View to String"
    end
  end

  def to_s
    check_alive!
    if @owner.is_a?(FluxString)
      @owner.data[@offset, @len]
    else
      "View[#{@len}]"
    end
  end

  def deref
    check_alive!
    @owner
  end

  def inspect; to_s; end
end

class FluxHeapPtr < FluxObject
  attr_reader :owner

  def initialize(owner)
    super()
    @owner = owner
  end

  def check_alive!
    super # Check if the Pointer itself is valid

    # Check if the thing we point to is still valid
    if @owner.respond_to?(:is_alive) && !@owner.is_alive
      raise "Memory Error: Dangling Pointer! Accessing a dead object."
    end
  end

  # The dereference operator (*)
  def deref
    check_alive!
    @owner
  end

  # Transparent printing
  def to_s; "&(#{@owner})"; end
  def inspect; to_s; end

  # Serialize the value we point to (Deep Copy behavior on serialization)
  def to_msgpack(packer=nil)
    check_alive!
    @owner.to_msgpack(packer)
  end
end

###
# SERIALIZAITON REGISTRY
##

MessagePack::DefaultFactory.register_type(
  1,
  FluxByte,
  # PACKER: Convert FluxByte -> String (Raw binary byte)
  packer: ->(obj) { obj.value.chr },
  # UNPACKER: Convert String -> FluxByte
  unpacker: ->(data) { VM::FluxByte.new(data.ord) }
)

