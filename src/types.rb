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
    Arena.current.register(self) if register
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

  # Comparisons
  def ==(other); other.is_a?(FluxByte) && @value == other.value; end
  def to_s; "0x#{@value.to_s(16).upcase.rjust(2, '0')}"; end
  def inspect; to_s; end
end

###
# HEAP TYPES - PASS BY REFERENCE - ARENA MANAGED
##

class FluxArray < FluxObject
  attr_reader :data, :max_size

  def initialize(max_size, initial_data)
    super() # Register with Arena

    @max_size = max_size
    @data = initial_data

    # TODO: Fill remaining space with nil? Or just keep it empty but bounded?
    # "Fixed array" usually means you can't change the size (no push/pop).
  end

  def <<(val)
    check_alive!
    if @max_size && @data.size >= @max_size
      raise "Runtime Error: Cannot append to Fixed Array (Max size: #{@max_size})"
    end
    @data << val
  end

  def [](idx)
    check_alive!
    @data[idx]
  end

  def []=(idx, val)
    check_alive!
    if @max_size && idx >= @max_size
      raise "Runtime Error: Index #{idx} out of bounds for Fixed Array[#{@max_size}]"
    end
    @data[idx] = val
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

  def initialize(initial_data = {})
    super()
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
  def inspect; to_s; end

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
    FluxString.new(@data + other_str)
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

  def inspect; to_s; end
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

