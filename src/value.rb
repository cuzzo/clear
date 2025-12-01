module Value
  # These simulate the 3-bit or 4-bit tags in NaN boxing
  TAG_NUMBER = 0
  TAG_BOOL   = 1
  TAG_OBJ    = 2
  TAG_NIL    = 3
  TAG_BYTE   = 4

  # ==========================================
  # ENCODERS (Box)
  # ==========================================

  def self.box_number(num)
    # Validation (Simulating Static Types)
    raise "NaNBox Error: Expected Numeric, got #{num.class}" unless num.is_a?(Numeric)
    num.to_f # In real NaN boxing, everything is a double
  end

  def self.box_bool(bool)
    bool # In real NaN boxing, this would be a specific constant (e.g. 0xFFFF...01)
  end

  def self.box_obj(flux_obj)
    # In real NaN boxing, this masks the pointer into the NaN space
    raise "NaNBox Error: Expected FluxObject" unless flux_obj.is_a?(FluxObject)
    flux_obj
  end

  def self.box_nil
    nil # Specific constant in real implementation
  end

  def self.box_byte(byte_obj)
    # The FluxByte object itself holds the value and acts as the "boxed" form
    byte_obj
  end

  # Generic Helper for LOADK
  # Converts a Compiler Constant -> VM Register Value
  def self.box_constant(const)
    case const
    when Numeric
      box_number(const)
    when TrueClass, FalseClass
      box_bool(const)
    when NilClass
      box_nil
    when FluxByte
      box_byte(const)
    when FluxObject
      box_obj(const)
    when String
      # TODO: This shouldn't ever happen in reality, but does in tests.
      # Eventually fix this.
      # Wrap it in a FluxString so the VM treats it consistently.
      # register: false -> Constants are immortal (don't die on rewind).
      val = FluxString.new(const, register: false)
      box_obj(val)
    else
      raise "NaNBox Error: Unknown constant type: #{const.class}"
    end
  end

  # ==========================================
  # DECODERS (Unbox) - Enforce Strictness
  # ==========================================

  def self.as_number(val)
    raise "NaNBox Type Error: Expected Number, got #{val.class}" unless val.is_a?(Numeric)
    val
  end

  def self.as_bool(val)
    raise "NaNBox Type Error: Expected Bool" unless val == true || val == false
    val
  end

  def self.as_obj(val)
    raise "NaNBox Type Error: Expected Object" unless val.is_a?(FluxObject)
    val
  end

  def self.as_byte(val)
    raise "NaNBox Type Error: Expected Byte" unless val.is_a?(FluxByte)
    val
  end

  # ==========================================
  # CHECKERS (Tag Testing)
  # ==========================================

  def self.is_number?(val); val.is_a?(Numeric); end
  def self.is_bool?(val); val == true || val == false; end
  def self.is_obj?(val); val.is_a?(FluxObject); end
  def self.is_nil?(val); val.nil?; end

  def self.get_tag(val)
    if val.is_a?(Numeric) then TAG_NUMBER
    elsif val.is_a?(FluxByte) then TAG_BYTE
    elsif val == true || val == false then TAG_BOOL
    elsif val.nil? then TAG_NIL
    else TAG_OBJ
    end
  end

  ## FOR TESTING ONLY
  def self.unbox(val)
    tag = get_tag(val)

    case tag
    when TAG_NUMBER
      as_number(val) # Returns Float/Integer

    when TAG_BOOL
      as_bool(val)   # Returns true/false

    when TAG_NIL
      nil

    when TAG_BYTE
      # Return the raw Integer value so 'expect(x).to eq(255)' works
      as_byte(val).value

    when TAG_OBJ
      obj = as_obj(val)

      # Quality of Life: Unwrap Strings for easy comparison
      if obj.is_a?(FluxString)
        obj.to_s
      else
        # Return the FluxArray/Hash/View object as-is
        # (They have [] accessors, so they are easy to test)
        obj
      end

    else
      raise "NaNBox Error: Cannot unbox unknown type #{val.class}"
    end
  end
end

