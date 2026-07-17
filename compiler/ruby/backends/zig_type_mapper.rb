# typed: strict
require "sorbet-runtime"
require_relative "zig_type"

module ZigTypeMapper
    extend T::Sig

  ZIG_OPS = T.let({
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
    :XOR => "^",
    :BIT_AND => "&",
    :BIT_OR => "|",
    :SHL => "<<",
    :SHR => ">>",

    # Special AST nodes you might map to operators
    #:OR_ELSE   => "orelse"
  }, T::Hash[Symbol, String])

  ZIG_PRIMITIVES = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "void", "[]const u8"]

  # Delegates to Type#zig_type for type-to-Zig conversion.
  # This keeps the transpiler interface stable while the logic lives in Type.
  sig { params(type: T.any(String, Symbol, Type), is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  def transpile_type(type, is_param: false, is_field: false)
    # If already a Type, use it directly — avoids losing shard_count through round-trip.
    t = type.is_a?(Type) ? type : Type.new(type)
    t.zig_type(is_param: is_param, is_field: is_field)
  end

end
