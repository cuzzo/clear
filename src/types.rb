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

MessagePack::DefaultFactory.register_type(
  1,
  FluxByte,
  # PACKER: Convert FluxByte -> String (Raw binary byte)
  packer: ->(obj) { obj.value.chr },
  # UNPACKER: Convert String -> FluxByte
  unpacker: ->(data) { VM::FluxByte.new(data.ord) }
)

