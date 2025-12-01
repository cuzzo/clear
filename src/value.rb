require_relative "./arena"

module Value
  # ==========================================
  # CONSTANTS (The Bit Masks)
  # ==========================================

  # We use the top 16 bits for tagging (Standard NaN Boxing technique)
  # 0xFFF0... ensures these bits represent a QNAN in IEEE 754
  QNAN_MASK = 0xFFF0000000000000

  # Bit Shifts
  TAG_SHIFT = 48

  # Tag IDs (Arbitrary 4-bit or 8-bit identifiers)
  # 0 is reserved for Float (implicit)
  ID_NIL    = 1
  ID_BOOL   = 2
  ID_BYTE   = 3
  ID_OBJ    = 4

  # Public Constants for Switch Statements
  TAG_NUMBER = 0
  TAG_NIL    = 1
  TAG_BOOL   = 2
  TAG_BYTE   = 3
  TAG_OBJ    = 4

  # Payload Masks
  BYTE_PAYLOAD_MASK = 0xFF              # Lower 8 bits
  OBJ_PAYLOAD_MASK  = 0xFFFFFFFFFFFF    # Lower 48 bits (Address space)

  # ==========================================
  # ENCODERS (Box: Value -> Register)
  # ==========================================

  def self.box_number(num)
    # Architecture Rule: Numbers are stored as raw Floats
    raise "NaNBox Error: Expected Numeric" unless num.is_a?(Numeric)
    num.to_f
  end

  def self.box_byte(val)
    # 1. Handle inputs: accepts raw Integer OR legacy FluxByte class
    raw_integer = val.is_a?(FluxByte) ? val.value : val

    raise "NaNBox Error: Expected Integer for Byte boxing" unless raw_integer.is_a?(Integer)

    # 2. Enforce Wrapping (The Behavior)
    #    256 becomes 0, -1 becomes 255
    payload = raw_integer % 256

    # 3. Encode (The NaN Box)
    #    Mask | Tag | Payload
    QNAN_MASK | (ID_BYTE << TAG_SHIFT) | payload
  end

  def self.box_bool(val)
    payload = val ? 1 : 0
    QNAN_MASK | (ID_BOOL << TAG_SHIFT) | payload
  end

  def self.box_nil
    QNAN_MASK | (ID_NIL << TAG_SHIFT)
  end

  def self.box_obj(obj)
    raise "NaNBox Error: Expected FluxObject" unless obj.is_a?(FluxObject)

    # We use the object_id as the "Pointer Address"
    # We ensure it fits in 48 bits (Ruby object_ids usually do)
    address = obj.object_id & OBJ_PAYLOAD_MASK

    QNAN_MASK | (ID_OBJ << TAG_SHIFT) | address
  end

  # The generic entry point for Constants/Literals
  def self.box_constant(const)
    case const
    when Numeric then box_number(const)
    when TrueClass, FalseClass then box_bool(const)
    when NilClass then box_nil
    when FluxByte then box_byte(const)
    when FluxObject then box_obj(const)
    when String
      # Wrap legacy strings for constant pool
      val = FluxString.new(const, register: :static)
      box_obj(val)
    when Integer
      # Defaulting to Number (Float) for safety unless explicitly boxed via box_byte
      box_number(const)
    else
      raise "NaNBox Error: Unknown constant type: #{const.class}"
    end
  end

  # ==========================================
  # DECODERS (Unbox: Register -> Raw Value)
  # ==========================================

  def self.as_number(val)
    raise "NaNBox Type Error: Expected Number (Float)" unless val.is_a?(Float)
    val
  end

  def self.as_byte(val)
    check_tag(val, TAG_BYTE)
    val & BYTE_PAYLOAD_MASK
  end

  def self.as_bool(val)
    check_tag(val, TAG_BOOL)
    (val & 1) == 1
  end

  def self.as_obj(val)
    check_tag(val, TAG_OBJ)

    address = val & OBJ_PAYLOAD_MASK

    # Pointer Reversal via Arena Registry
    obj = Arena.current.find_object_by_address(address)

    raise "Memory Error: Segfault (Invalid Pointer Address)" unless obj
    obj.check_alive! if obj.respond_to?(:check_alive!)
    obj
  end

  # ==========================================
  # CHECKERS (Tag Testing)
  # ==========================================

  def self.get_tag(val)
    # 1. Floating Point Check (Standard Number)
    return TAG_NIL if val.nil? # TODO - this seems wrong.
    return TAG_NUMBER if val.is_a?(Float)

    # 2. Encoded Integer Check
    if val.is_a?(Integer)
      # Extract the Tag ID
      tag_id = (val >> TAG_SHIFT) & 0xF # Grab 4 bits

      case tag_id
      when ID_BYTE then return TAG_BYTE
      when ID_OBJ  then return TAG_OBJ
      when ID_BOOL then return TAG_BOOL
      when ID_NIL  then return TAG_NIL
      end
    end

    raise "NaNBox Error: Corrupted Register Value (Invalid Tag)"
  end

  def self.unbox(val)
    case get_tag(val)
    when TAG_NUMBER then as_number(val)
    when TAG_BYTE   then as_byte(val)
    when TAG_BOOL   then as_bool(val)
    when TAG_NIL    then nil
    when TAG_OBJ
      obj = as_obj(val)
      obj.is_a?(FluxString) ? obj.to_s : obj
    end
  end

  private

  def self.check_tag(val, expected_tag)
    actual = get_tag(val)
    if actual != expected_tag
      raise "NaNBox Type Error: Expected #{expected_tag}, got #{actual}"
    end
  end

  def self.is_nil?(val)
    get_tag(val) == TAG_NIL
  end

  def self.is_bool?(val)
    get_tag(val) == TAG_BOOL
  end

  def self.is_number?(val)
    get_tag(val) == TAG_NUMBER
  end

  def self.is_obj?(val)
    get_tag(val) == TAG_OBJ
  end

  def self.is_byte?(val)
    get_tag(val) == TAG_BYTE
  end
end

