# typed: strict
require "sorbet-runtime"
require "set"

# ruby-to-clear: pub
# ruby-to-clear: value
class ZigType
  extend T::Sig

  RESERVED_IDENTIFIERS = T.let(Set.new(%w[
    addrspace align allowzero and anyframe anytype asm async await break callconv
    catch comptime const continue defer else enum errdefer error export extern false
    fn for if inline linksection noalias noinline nosuspend null opaque or orelse
    packed pub resume return struct suspend switch test threadlocal true try type
    undefined union unreachable usingnamespace var volatile while
  ]).freeze, T::Set[String])

  sig { params(name: String).returns(T::Boolean) }
  def self.reserved_identifier?(name)
    RESERVED_IDENTIFIERS.include?(name) || primitive_numeric_identifier?(name)
  end

  sig { returns(String) }
  attr_reader :source

  sig { params(source: String).void }
  def initialize(source)
    @source = T.let(source, String)
    @inferred_error_union = T.let(source.start_with?("!"), T::Boolean)
    @anyerror_union = T.let(source.include?("anyerror!"), T::Boolean)
    @explicit_error_set_union = T.let(source.include?("error{"), T::Boolean)
  end

  sig { params(name: String).returns(T::Boolean) }
  def self.primitive_numeric_identifier?(name)
    return false if name.length < 2
    return false unless name.start_with?("u") || name.start_with?("i") || name.start_with?("f")

    digits_only?(T.must(name[1..]))
  end

  sig { params(name: String).returns(T::Boolean) }
  def self.float_identifier?(name)
    return false if name.length < 2
    return false unless name.start_with?("f")

    digits_only?(T.must(name[1..]))
  end

  sig { params(name: String).returns(T::Boolean) }
  def self.integer_identifier?(name)
    return false if name.length < 2
    return false unless name.start_with?("u") || name.start_with?("i")

    digits_only?(T.must(name[1..]))
  end

  sig { params(value: String).returns(T::Boolean) }
  def self.digits_only?(value)
    value.match?(/\A[0-9]+\z/)
  end
  private_class_method :digits_only?

  sig { returns(T::Boolean) }
  def error_union?
    @inferred_error_union || @anyerror_union || @explicit_error_set_union
  end

  sig { returns(T::Boolean) }
  def inferred_error_union?
    @inferred_error_union
  end

  sig { returns(String) }
  def fallible_return_type
    return source if error_union?

    "!#{source}"
  end

  sig { returns(String) }
  def concrete_fallible_return_type
    return source if @anyerror_union || @explicit_error_set_union
    return "anyerror#{source}" if inferred_error_union?

    "anyerror!#{source}"
  end

  sig { params(reentrant: T::Boolean).returns(String) }
  def fallible_return_type_for(reentrant:)
    reentrant ? concrete_fallible_return_type : fallible_return_type
  end

  sig { returns(String) }
  def anyerror_return_type
    return source if error_union?

    "anyerror!#{source}"
  end

  sig { returns(String) }
  def cast_target_type
    return "anyerror#{source}" if inferred_error_union?

    source
  end

  sig { returns(String) }
  def cleanup_storage_type
    return T.must(source[1..]) if inferred_error_union?

    source
  end
end
