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

  ZIG_PRIMITIVES = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "void", "[]const u8"]

  # Delegates to Type#zig_type for type-to-Zig conversion.
  # This keeps the transpiler interface stable while the logic lives in Type.
  def transpile_type(type, is_param: false, is_field: false)
    # If already a Type, use it directly — avoids losing shard_count through round-trip.
    t = type.is_a?(Type) ? type : Type.new(type)
    t.zig_type(is_param: is_param, is_field: is_field)
  end

  def transpile_cast(code, from_type, to_type)
    from = from_type.respond_to?(:resolved) ? from_type.resolved : from_type
    to = to_type.respond_to?(:resolved) ? to_type.resolved : to_type

    return code if from == to

    from_t = from_type.is_a?(Type) ? from_type : Type.new(from)
    to_t   = to_type.is_a?(Type)   ? to_type   : Type.new(to)

    # Skip numeric casts for fn_type (resolved type is the return type, not the fn itself)
    return "@as(#{transpile_type(to)}, #{code})" if from_t.fn_type? || to_t.fn_type?

    # A. Int -> Float (any integer to any float)
    if from_t.integer? && to_t.float?
      zig_to = transpile_type(to)
      return "@as(#{zig_to}, @floatFromInt(#{code}))"
    end

    # B. Float -> Int (any float to any integer)
    if from_t.float? && to_t.integer?
      zig_to = transpile_type(to)
      return "@as(#{zig_to}, @intFromFloat(#{code}))"
    end

    # C. Int -> Int (widening or narrowing via @intCast)
    if from_t.integer? && to_t.integer?
      zig_to = transpile_type(to)
      return "@as(#{zig_to}, @intCast(#{code}))"
    end

    # D. Float -> Float (f32 <-> f64 via @floatCast)
    if from_t.float? && to_t.float?
      zig_to = transpile_type(to)
      return "@as(#{zig_to}, @floatCast(#{code}))"
    end

    # E. Array coercion (e.g. Any[] -> Int64[], or Int64[1000] -> Int64[])
    #    ArrayList types are already correctly typed by makeList, no cast needed.
    #    @list with capacity (T[N]@list) is the same Zig type as T[]@list — skip cast.
    from_str = from.to_s
    to_str = to.to_s
    if from_str.end_with?("[]") && to_str.end_with?("[]")
      return code
    end
    # @list with capacity: T[N] -> Any[] is the same Zig ArrayList, no cast needed.
    if from_str =~ /\[\d+\]$/ && to_str == "Any[]"
      return code
    end

    # E2. HashMap coercion (e.g. HashMap<Any> -> HashMap<String>)
    #     Same Zig type (StringMap or NumericMap), no cast needed.
    if from_str.start_with?("HashMap<") && to_str.start_with?("HashMap<")
      return code
    end

    # F. Error union coercion: T -> !T (Zig handles this automatically)
    if to_str.start_with?("!")
      payload_type = to_str[1..]
      from_matches = from_str == payload_type || from == to.to_s[1..].to_sym
      from_matches ||= from_str.start_with?("Byte[") && payload_type == "String"
      return code if from_matches
    end

    # Fallback: Zig's generic cast
    zig_to = transpile_type(to)
    return "@as(#{zig_to}, #{code})"
  end
end
