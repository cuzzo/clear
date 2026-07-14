# typed: strict

require "sorbet-runtime"

module TypeExpression
  extend T::Helpers
  include Kernel
  interface!
end

class NamedTypeExpression < T::Struct
  include TypeExpression

  const :name, Symbol
  const :arguments, T::Array[TypeExpression], default: []
end

class FunctionTypeExpression < T::Struct
  include TypeExpression

  const :signature, Type::FunctionType
end

class TupleTypeExpression < T::Struct
  include TypeExpression

  const :items, T::Array[TypeExpression]
end

class OptionalTypeExpression < T::Struct
  include TypeExpression

  const :inner, TypeExpression
end

class FallibleTypeExpression < T::Struct
  include TypeExpression

  const :inner, TypeExpression
  const :error_set, T.nilable(TypeExpression), default: nil
end

class FutureTypeExpression < T::Struct
  include TypeExpression

  const :inner, TypeExpression
end

class LinearTypeExpression < T::Struct
  include TypeExpression

  const :kind, Symbol
  const :dimensions, T::Array[T.any(Integer, Symbol)]
  const :item, TypeExpression
  const :allocation_hint, T.nilable(Integer), default: nil
  const :capabilities, T::Array[Symbol], default: []
end

class MapTypeExpression < T::Struct
  include TypeExpression

  const :key, TypeExpression
  const :value, TypeExpression
  # The key is always explicit semantically. This flag only preserves whether
  # legacy HashMap<V> syntax omitted its default String key while migration is
  # still expected to round-trip both accepted spellings.
  const :key_implicit, T::Boolean, default: false
  const :legacy_separator, String, default: ","
  const :capabilities, T::Array[Symbol], default: []
end

class StreamTypeExpression < T::Struct
  include TypeExpression

  const :cardinality, T.any(Integer, Symbol)
  const :item, TypeExpression
  const :capabilities, T::Array[Symbol], default: []
end

class TypeExpressionParser
  extend T::Sig

  class GenericParts < T::Struct
    const :base, String
    const :arguments, T::Array[String]
  end

  sig { params(raw: T.any(Type::FunctionType, Symbol, String)).returns(TypeExpression) }
  def self.parse(raw)
    return FunctionTypeExpression.new(signature: raw) if raw.is_a?(Type::FunctionType)

    parse_source(raw.to_s)
  end

  sig { params(source: String).returns(TypeExpression) }
  def self.parse_source(source)
    normalized = source.strip
    raise ArgumentError, "empty type expression" if normalized.empty?

    prefixed = parse_prefixed_source(normalized)
    return prefixed unless prefixed.nil?

    parse_primary_source(normalized)
  end

  sig { params(source: String).returns(T.nilable(TypeExpression)) }
  def self.parse_prefixed_source(source)
    prefix = source[0]
    return nil unless ["~", "!", "?"].include?(prefix)

    inner_source = source[1..].to_s
    case prefix
    when "~"
      raise ArgumentError, "double future type is not allowed" if inner_source.start_with?("~")

      FutureTypeExpression.new(inner: parse_source(inner_source))
    when "!"
      raise ArgumentError, "double fallible type is not allowed" if inner_source.start_with?("!")
      raise ArgumentError, "fallible future types must be written as ~!T" if inner_source.start_with?("~")

      FallibleTypeExpression.new(inner: parse_source(inner_source))
    when "?"
      parse_optional_source(inner_source)
    end
  end

  sig { params(inner_source: String).returns(TypeExpression) }
  def self.parse_optional_source(inner_source)
    raise ArgumentError, "double optional type is not allowed" if inner_source.start_with?("?")
    if grouped_type?(inner_source)
      return OptionalTypeExpression.new(inner: parse_source(inner_source[1..-2].to_s))
    end

    optional_array_parts = split_array_suffix(inner_source)
    unless optional_array_parts.nil?
      item_source, dimension = optional_array_parts
      return LinearTypeExpression.new(
        kind: dimension.nil? ? :list : :array,
        dimensions: [dimension || :LIST],
        item: OptionalTypeExpression.new(inner: parse_source(item_source))
      )
    end

    OptionalTypeExpression.new(inner: parse_source(inner_source))
  end

  sig { params(source: String).returns(TypeExpression) }
  def self.parse_primary_source(source)
    array = parse_array_source(source)
    return array unless array.nil?

    parse_generic_or_named_source(source)
  end

  sig { params(source: String).returns(T.nilable(LinearTypeExpression)) }
  def self.parse_array_source(source)
    array_parts = split_array_suffix(source)
    return nil if array_parts.nil?

    item_source, dimension = array_parts
    LinearTypeExpression.new(
      kind: dimension.nil? ? :list : :array,
      dimensions: [dimension || :LIST],
      item: parse_source(item_source)
    )
  end

  sig { params(source: String).returns(TypeExpression) }
  def self.parse_generic_or_named_source(source)
    generic = split_generic(source)
    unless generic.nil?
      arguments = generic.arguments.map { |argument| parse_source(argument) }
      if generic.base == "HashMap"
        if arguments.length == 1
          return MapTypeExpression.new(
            key: NamedTypeExpression.new(name: :String),
            value: T.must(arguments.first),
            key_implicit: true
          )
        end
        if arguments.length == 2
          return MapTypeExpression.new(
            key: T.must(arguments[0]),
            value: T.must(arguments[1]),
            legacy_separator: top_level_argument_separator(source)
          )
        end
        raise ArgumentError, "HashMap expects one or two type arguments"
      elsif generic.base == "Tuple"
        return TupleTypeExpression.new(items: arguments)
      end

      return NamedTypeExpression.new(name: generic.base.to_sym, arguments: arguments)
    end

    NamedTypeExpression.new(name: source.to_sym)
  end

  sig { params(source: String).returns(T::Boolean) }
  def self.grouped_type?(source)
    return false unless source.start_with?("(") && source.end_with?(")")

    depth = T.let(0, Integer)
    source.each_char.with_index do |character, index|
      depth += 1 if character == "("
      depth -= 1 if character == ")"
      return false if depth.zero? && index < source.length - 1
    end
    depth.zero?
  end

  sig { params(source: String).returns(T.nilable([String, T.nilable(T.any(Integer, Symbol))])) }
  def self.split_array_suffix(source)
    return nil unless source.end_with?("]")

    depth = T.let(0, Integer)
    index = T.let(source.length - 1, Integer)
    while index >= 0
      character = source[index]
      depth += 1 if character == "]"
      if character == "["
        depth -= 1
        if depth.zero?
          item_source = source[0...index]
          return nil if item_source.nil? || item_source.empty?

          dimension_source = source[(index + 1)...-1].to_s
          dimension = case dimension_source
          when "" then nil
          when "?" then :STREAM_OPEN
          when "INF" then :INF
          when "*" then :INFERRED
          else
            return nil unless dimension_source.match?(/\A\d+\z/)

            dimension_source.to_i
          end
          return [item_source, dimension]
        end
      end
      index -= 1
    end
    nil
  end

  sig { params(source: String).returns(T.nilable(GenericParts)) }
  def self.split_generic(source)
    opening = source.index("<")
    return nil if opening.nil? || !source.end_with?(">")

    base = source[0...opening].to_s
    return nil unless base.match?(/\A[A-Z]\w*\z/)

    inner = source[(opening + 1)...-1].to_s
    GenericParts.new(base: base, arguments: split_arguments(inner))
  end

  sig { params(source: String).returns(T::Array[String]) }
  def self.split_arguments(source)
    arguments = T.let([], T::Array[String])
    start = T.let(0, Integer)
    depth = T.let(0, Integer)
    source.each_char.with_index do |character, index|
      case character
      when "<", "(", "[", "{"
        depth += 1
      when ">", ")", "]", "}"
        depth -= 1
      when ","
        next unless depth.zero?

        arguments << source[start...index].to_s.strip
        start = index + 1
      end
    end
    arguments << source[start..].to_s.strip
    arguments
  end

  sig { params(source: String).returns(String) }
  def self.top_level_argument_separator(source)
    opening = T.must(source.index("<"))
    depth = T.let(0, Integer)
    index = T.let(opening + 1, Integer)
    while index < source.length - 1
      character = source[index]
      case character
      when "<", "(", "[", "{"
        depth += 1
      when ">", ")", "]", "}"
        depth -= 1
      when ","
        if depth.zero?
          following = source[(index + 1)..].to_s
          return following.start_with?(" ") ? ", " : ","
        end
      end
      index += 1
    end
    ","
  end

  private_class_method :parse_source, :parse_prefixed_source, :parse_optional_source, :parse_primary_source,
    :parse_array_source, :parse_generic_or_named_source, :grouped_type?, :split_array_suffix, :split_generic,
    :split_arguments, :top_level_argument_separator
end

class TypeExpressionPrinter
  extend T::Sig

  sig { params(expression: TypeExpression).returns(String) }
  def self.legacy(expression)
    case expression
    when NamedTypeExpression
      return expression.name.to_s if expression.arguments.empty?

      "#{expression.name}<#{expression.arguments.map { |argument| legacy(argument) }.join(",")}>"
    when FunctionTypeExpression
      "FN(#{expression.signature.params.map { |param| legacy(TypeExpressionParser.parse(param.type.raw)) }.join(",")}) -> #{legacy(TypeExpressionParser.parse(expression.signature.return_type.raw))}"
    when TupleTypeExpression
      "Tuple<#{expression.items.map { |item| legacy(item) }.join(",")}>"
    when OptionalTypeExpression
      inner = legacy(expression.inner)
      inner_expression = expression.inner
      inner_expression.is_a?(LinearTypeExpression) || inner_expression.is_a?(MapTypeExpression) ? "?(#{inner})" : "?#{inner}"
    when FallibleTypeExpression
      "!#{legacy(expression.inner)}"
    when FutureTypeExpression
      "~#{legacy(expression.inner)}"
    when LinearTypeExpression
      expression.dimensions.reduce(legacy(expression.item)) do |surface, dimension|
        suffix = case dimension
        when :LIST then "[]"
        when :STREAM_OPEN then "[?]"
        when :INF then "[INF]"
        when :INFERRED then "[*]"
        else "[#{dimension}]"
        end
        "#{surface}#{suffix}"
      end
    when MapTypeExpression
      key = legacy(expression.key)
      value = legacy(expression.value)
      expression.key_implicit ? "HashMap<#{value}>" : "HashMap<#{key}#{expression.legacy_separator}#{value}>"
    when StreamTypeExpression
      cardinality = expression.cardinality
      marker = cardinality == :FINITE ? "" : cardinality.to_s
      "[~#{marker}]#{legacy(expression.item)}"
    else
      raise "unknown type expression #{expression.class}"
    end
  end

  sig { params(expression: TypeExpression).returns(String) }
  def self.inline(expression)
    case expression
    when NamedTypeExpression
      return expression.name.to_s if expression.arguments.empty?

      "#{expression.name}<#{expression.arguments.map { |argument| inline(argument) }.join(", ")}>"
    when FunctionTypeExpression
      "FN(#{expression.signature.params.map { |param| inline(TypeExpressionParser.parse(param.type.raw)) }.join(", ")}) -> #{inline(TypeExpressionParser.parse(expression.signature.return_type.raw))}"
    when TupleTypeExpression
      "Tuple<#{expression.items.map { |item| inline(item) }.join(", ")}>"
    when OptionalTypeExpression
      "?#{inline(expression.inner)}"
    when FallibleTypeExpression
      "!#{inline(expression.inner)}"
    when FutureTypeExpression
      "~#{inline(expression.inner)}"
    when LinearTypeExpression
      dimensions = expression.dimensions.map do |dimension|
        case dimension
        when :LIST then "List"
        when :STREAM_OPEN then "~"
        when :INF then "~INF"
        when :INFERRED then "*"
        else dimension.to_s
        end
      end
      prefix = dimensions == ["List"] ? "[]" : "[#{dimensions.join(", ")}]"
      "#{prefix}#{inline(expression.item)}"
    when MapTypeExpression
      "{#{inline(expression.key)}}#{inline(expression.value)}"
    when StreamTypeExpression
      cardinality = expression.cardinality
      marker = cardinality == :FINITE ? "" : cardinality.to_s
      "[~#{marker}]#{inline(expression.item)}"
    else
      raise "unknown type expression #{expression.class}"
    end
  end
end
