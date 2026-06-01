# typed: strict
require "sorbet-runtime"

class ZigType
  extend T::Sig

  sig { returns(String) }
  attr_reader :source

  sig { params(source: String).void }
  def initialize(source)
    @source = T.let(source, String)
    @inferred_error_union = T.let(source.start_with?("!"), T::Boolean)
    @anyerror_union = T.let(source.include?("anyerror!"), T::Boolean)
    @explicit_error_set_union = T.let(source.include?("error{"), T::Boolean)
  end

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
