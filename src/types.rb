require "msgpack"

###
# TYPES
##

class FluxByte
  attr_reader :value
  def initialize(val)
    @value = val.to_i % 256
  end

  # Math returns NEW Bytes (Auto-Wrapping)
  def +(other); FluxByte.new(@value + other.value); end
  def -(other); FluxByte.new(@value - other.value); end
  def *(other); FluxByte.new(@value * other.value); end

  # Comparisons
  def ==(other); other.is_a?(FluxByte) && @value == other.value; end
  def to_s; "0x#{@value.to_s(16).upcase.rjust(2, '0')}"; end
  def inspect; to_s; end
end

class FluxArray
  attr_reader :data, :max_size

  def initialize(max_size, initial_data)
    @max_size = max_size
    @data = initial_data

    # Fill remaining space with nil? Or just keep it empty but bounded?
    # Let's keep it consistent with the user request:
    # "Fixed array" usually means you can't change the size (no push/pop).
  end

  def <<(val)
    raise "Runtime Error: Cannot append to Fixed Array (Max size: #{@max_size})"
  end

  def [](idx)
    @data[idx]
  end

  def []=(idx, val)
    if idx >= @max_size
      raise "Runtime Error: Index #{idx} out of bounds for Fixed Array[#{@max_size}]"
    end
    @data[idx] = val
  end

  # MessagePack Support
  def to_msgpack(packer=nil)
    # We need to serialize the constraint too!
    # We can pack as a custom type or just a hash for now.
    { "max" => @max_size, "data" => @data }.to_msgpack(packer)
  end

  def to_s; "<Fixed[#{@max_size}] #{@data.to_s}>"; end
  def inspect; to_s; end
  # Delegate other methods to @data if needed (each, map, etc)
  def method_missing(m, *args, &block); @data.send(m, *args, &block); end
end

MessagePack::DefaultFactory.register_type(
  1,
  FluxByte,
  # PACKER: Convert FluxByte -> String (Raw binary byte)
  packer: ->(obj) { obj.value.chr },
  # UNPACKER: Convert String -> FluxByte
  unpacker: ->(data) { VM::FluxByte.new(data.ord) }
)

