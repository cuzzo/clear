module ZigTypeMapper
  ZIG_OPS = {
    :ADD => "+",
    :SUB => "-",
    :MUL => "*",
    :DIV => "/",     # Note: Integer division in Zig
    :MOD => "%",     # Zig uses % for Modulo

    :EQ  => "==",
    :NEQ => "!=",
    :LT  => "<",
    :LTE => "<=",
    :GT  => ">",
    :GTE => ">=",

    # Zig-specific logic keywords
    :AND => "and",
    :OR  => "or",
    :NOT => "!",

    # Bitwise
    :BITWISE_NOT => "~",

    # Special AST nodes you might map to operators
    #:OR_RESCUE   => "orelse"
  }

  ZIG_PRIMITIVES = ["i64", "f64", "bool", "void", "[]const u8"]

  # Delegates to Type#zig_type for type-to-Zig conversion.
  # This keeps the transpiler interface stable while the logic lives in Type.
  def transpile_type(type, is_param: false, is_field: false)
    # If already a Type, use it directly — avoids losing shard_count through round-trip.
    t = type.is_a?(Type) ? type : Type.new(type)
    t.zig_type(is_param: is_param, is_field: is_field)
  end

  # TODO: from_type/to_type may need to be simplified
  def transpile_cast(code, from_type, to_type)
    from = from_type.respond_to?(:resolved) ? from_type.resolved : from_type
    to = to_type.respond_to?(:resolved) ? to_type.resolved : to_type

    return code if from == to

    # A. Int -> Float (e.g. i64 -> f64)
    if [:Int64, :Byte].include?(from) && to == :Number
      return "@as(f64, @floatFromInt(#{code}))"
    end

    # B. Float -> Int (e.g. f64 -> i64)
    #    But skip if both are actually integer types (annotator may over-coerce)
    if from == :Number && to == :Int64
      return "@intFromFloat(#{code})"
    end

    # C. Int Widening (e.g. u8 -> i64)
    if from == :Byte && to == :Int64
      return "@intCast(#{code})"
    end

    # D. Array coercion (e.g. Any[] -> Int64[])
    #    ArrayList types are already correctly typed by makeList, no cast needed
    from_str = from.to_s
    to_str = to.to_s
    if from_str.end_with?("[]") && to_str.end_with?("[]")
      return code
    end

    # E. Error union coercion: T -> !T (Zig handles this automatically)
    #    No explicit cast needed when returning payload from error union function
    if to_str.start_with?("!")
      payload_type = to_str[1..]
      if from_str == payload_type || from == to.to_s[1..].to_sym
        return code  # Zig auto-wraps payload in error union
      end
    end

    # Fallback: Zig's generic cast (often works for simple types)
    # e.g. @as(f64, 10.5)
    zig_to = transpile_type(to)
    return "@as(#{zig_to}, #{code})"
  end
end
