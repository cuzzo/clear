# typed: strict

require "sorbet-runtime"

module TypeExpression
  extend T::Helpers
  extend T::Sig
  include Kernel
  interface!

  sig { abstract.returns(TypeCapabilities) }
  def capabilities; end
end

class NamedTypeExpression < T::Struct
  include TypeExpression

  const :name, Symbol
  const :arguments, T::Array[TypeExpression], default: []
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class FunctionTypeExpression < T::Struct
  include TypeExpression

  const :signature, Type::FunctionType
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class TupleTypeExpression < T::Struct
  include TypeExpression

  const :items, T::Array[TypeExpression]
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class OptionalTypeExpression < T::Struct
  include TypeExpression

  const :inner, TypeExpression
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class FallibleTypeExpression < T::Struct
  include TypeExpression

  const :inner, TypeExpression
  const :error_set, T.nilable(TypeExpression), default: nil
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class FutureTypeExpression < T::Struct
  include TypeExpression

  const :inner, TypeExpression
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class LinearTypeExpression < T::Struct
  extend T::Sig
  include TypeExpression

  const :kind, Symbol
  const :dimensions, T::Array[T.any(Integer, Symbol)]
  const :item, TypeExpression
  const :allocation_hint, T.nilable(Integer), default: nil
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true

  sig { returns(T::Boolean) }
  def list?
    kind == :list
  end

  sig { returns(T::Boolean) }
  def set?
    kind == :set
  end

  sig { returns(T::Boolean) }
  def pool?
    kind == :pool
  end
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
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class StreamTypeExpression < T::Struct
  include TypeExpression

  const :cardinality, T.any(Integer, Symbol)
  const :item, TypeExpression
  const :capabilities, TypeCapabilities, default: TypeCapabilities.new(ownership: :affine), override: true
end

class TypeExpressionTree
  extend T::Sig

  sig { params(expression: TypeExpression).returns(TypeCapabilities) }
  def self.root_capabilities(expression)
    expression.capabilities
  end

  sig { params(expression: TypeExpression, capabilities: TypeCapabilities).returns(TypeExpression) }
  def self.with_root_capabilities(expression, capabilities)
    case expression
    when OptionalTypeExpression
      OptionalTypeExpression.new(inner: expression.inner, capabilities: capabilities)
    when FallibleTypeExpression
      FallibleTypeExpression.new(inner: expression.inner, error_set: expression.error_set, capabilities: capabilities)
    when FutureTypeExpression
      FutureTypeExpression.new(inner: expression.inner, capabilities: capabilities)
    when NamedTypeExpression
      NamedTypeExpression.new(name: expression.name, arguments: expression.arguments, capabilities: capabilities)
    when FunctionTypeExpression
      FunctionTypeExpression.new(signature: expression.signature, capabilities: capabilities)
    when TupleTypeExpression
      TupleTypeExpression.new(items: expression.items, capabilities: capabilities)
    when LinearTypeExpression
      LinearTypeExpression.new(kind: expression.kind, dimensions: expression.dimensions,
        item: expression.item, allocation_hint: expression.allocation_hint, capabilities: capabilities)
    when MapTypeExpression
      MapTypeExpression.new(key: expression.key, value: expression.value,
        key_implicit: expression.key_implicit, legacy_separator: expression.legacy_separator,
        capabilities: capabilities)
    when StreamTypeExpression
      StreamTypeExpression.new(cardinality: expression.cardinality, item: expression.item,
        capabilities: capabilities)
    else
      expression
    end
  end

  sig { params(expression: TypeExpression).returns(T.nilable(TypeCapabilities)) }
  def self.linear_item_capabilities(expression)
    node = T.let(expression, TypeExpression)
    loop do
      case node
      when FallibleTypeExpression, FutureTypeExpression, OptionalTypeExpression
        node = node.inner
      else
        break
      end
    end
    return nil unless node.is_a?(LinearTypeExpression)

    root_capabilities(node.item)
  end

  sig { params(expression: TypeExpression, capabilities: TypeCapabilities).returns(TypeExpression) }
  def self.with_linear_item_capabilities(expression, capabilities)
    if expression.is_a?(FallibleTypeExpression)
      return FallibleTypeExpression.new(
        inner: with_linear_item_capabilities(expression.inner, capabilities),
        error_set: expression.error_set,
        capabilities: expression.capabilities
      )
    end
    if expression.is_a?(FutureTypeExpression)
      return FutureTypeExpression.new(
        inner: with_linear_item_capabilities(expression.inner, capabilities),
        capabilities: expression.capabilities
      )
    end
    if expression.is_a?(OptionalTypeExpression)
      return OptionalTypeExpression.new(
        inner: with_linear_item_capabilities(expression.inner, capabilities),
        capabilities: expression.capabilities
      )
    end
    return expression unless expression.is_a?(LinearTypeExpression)

    LinearTypeExpression.new(
      kind: expression.kind,
      dimensions: expression.dimensions,
      item: with_root_capabilities(expression.item, capabilities),
      allocation_hint: expression.allocation_hint,
      capabilities: expression.capabilities
    )
  end

  # Replace the argument children of a nominal type without flattening any
  # child expression back through a source string. The parser uses this while
  # legacy outer syntax is still accepted (for example
  # `Tuple<[List]Int64, {String}Bool>`): the outer parser may normalize its own
  # suffixes, but recursive Inline Pivot children retain their topology and
  # per-layer capabilities exactly.
  sig do
    params(
      expression: TypeExpression,
      name: Symbol,
      arguments: T::Array[TypeExpression]
    ).returns(TypeExpression)
  end
  def self.with_nominal_arguments(expression, name, arguments)
    case expression
    when OptionalTypeExpression
      OptionalTypeExpression.new(
        inner: with_nominal_arguments(expression.inner, name, arguments),
        capabilities: expression.capabilities,
      )
    when FallibleTypeExpression
      FallibleTypeExpression.new(
        inner: with_nominal_arguments(expression.inner, name, arguments),
        error_set: expression.error_set,
        capabilities: expression.capabilities,
      )
    when FutureTypeExpression
      FutureTypeExpression.new(
        inner: with_nominal_arguments(expression.inner, name, arguments),
        capabilities: expression.capabilities,
      )
    when LinearTypeExpression
      LinearTypeExpression.new(
        kind: expression.kind,
        dimensions: expression.dimensions,
        item: with_nominal_arguments(expression.item, name, arguments),
        allocation_hint: expression.allocation_hint,
        capabilities: expression.capabilities,
      )
    when StreamTypeExpression
      StreamTypeExpression.new(
        cardinality: expression.cardinality,
        item: with_nominal_arguments(expression.item, name, arguments),
        capabilities: expression.capabilities,
      )
    when FunctionTypeExpression
      expression
    when TupleTypeExpression
      return expression unless name == :Tuple

      TupleTypeExpression.new(items: arguments, capabilities: expression.capabilities)
    when NamedTypeExpression
      return expression unless expression.name == name

      NamedTypeExpression.new(name: name, arguments: arguments, capabilities: expression.capabilities)
    when MapTypeExpression
      return expression unless name == :HashMap

      key = arguments.length == 1 ? expression.key : arguments.fetch(0)
      value = arguments.length == 1 ? arguments.fetch(0) : arguments.fetch(1)
      MapTypeExpression.new(
        key: key,
        value: value,
        key_implicit: arguments.length == 1,
        legacy_separator: expression.legacy_separator,
        capabilities: expression.capabilities,
      )
    else
      expression
    end
  end

  sig { params(expression: TypeExpression).returns(Integer) }
  def self.node_count(expression)
    each_node(expression).length
  end

  sig { params(expression: TypeExpression).returns(Integer) }
  def self.capability_site_count(expression)
    each_node(expression).count { |node| node.capabilities.explicit_layer_capability? }
  end

  sig { params(expression: TypeExpression).returns(T::Boolean) }
  def self.nested_capabilities?(expression)
    each_node(expression).drop(1).any? { |node| node.capabilities.explicit_layer_capability? }
  end

  sig { params(expression: TypeExpression).returns(T::Boolean) }
  def self.tense_wrapper?(expression)
    case expression
    when OptionalTypeExpression, FallibleTypeExpression, FutureTypeExpression then true
    else false
    end
  end

  sig { params(expression: TypeExpression).returns(T::Array[TypeExpression]) }
  def self.each_node(expression)
    found = T.let([], T::Array[TypeExpression])
    pending = T.let([expression], T::Array[TypeExpression])
    until pending.empty?
      node = T.must(pending.pop)
      found << node
      pending.concat(children(node))
    end
    found
  end

  sig { params(expression: TypeExpression).returns(T::Array[TypeExpression]) }
  def self.children(expression)
    case expression
    when NamedTypeExpression then expression.arguments
    when FunctionTypeExpression
      expression.signature.params.map { |param| param.type.shape.expression } +
        [expression.signature.return_type.shape.expression]
    when TupleTypeExpression then expression.items
    when OptionalTypeExpression, FutureTypeExpression then [expression.inner]
    when FallibleTypeExpression
      expression.error_set.nil? ? [expression.inner] : [expression.inner, T.must(expression.error_set)]
    when LinearTypeExpression, StreamTypeExpression then [expression.item]
    when MapTypeExpression then [expression.key, expression.value]
    else []
    end
  end
  private_class_method :children

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

    source = raw.to_s
    if source.start_with?("[~")
      closing = source.index("]")
      unless closing.nil?
        marker = source[2...closing].to_s
        cardinality = if marker.empty?
          :FINITE
        elsif marker == "INF"
          :INF
        elsif marker.match?(/\A\d+\z/)
          marker.to_i
        end
        unless cardinality.nil?
          item_source = source[(closing + 1)..].to_s
          return StreamTypeExpression.new(cardinality: cardinality, item: parse(item_source)) unless item_source.empty?
        end
      end
    end

    parse_source(source)
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

    base, capabilities = split_legacy_capability_suffix(source)
    NamedTypeExpression.new(name: base.to_sym, capabilities: capabilities)
  end

  sig { params(source: String).returns([String, TypeCapabilities]) }
  def self.split_legacy_capability_suffix(source)
    marker = source.index("@")
    return [source, TypeCapabilities.new(ownership: :affine)] if marker.nil? || marker.zero?

    base = source[0...marker].to_s
    ownership = T.let(:affine, T.nilable(Symbol))
    sync = T.let(nil, T.nilable(Symbol))
    layout = T.let(nil, T.nilable(Symbol))
    source[marker..].to_s.split("@").reject(&:empty?).flat_map { |part| part.split(":") }.each do |capability|
      case capability
      when "shared" then ownership = :shared
      when "multiowned", "multiOwned" then ownership = :multiowned
      when "link" then ownership = :link
      when "split" then ownership = :split
      when "locked" then sync = :locked
      when "writeLocked" then sync = :write_locked
      when "versioned" then sync = :versioned
      when "atomic" then sync = :atomic
      when "local" then sync = :local
      when "raw" then sync = :raw
      when "symbol" then sync = :symbol
      when "boxed", "indirect" then layout = :indirect
      end
    end
    [base, TypeCapabilities.new(ownership: ownership, sync: sync, layout: layout)]
  end
  private_class_method :split_legacy_capability_suffix

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
      base = if expression.arguments.empty?
        expression.name.to_s
      else
        "#{expression.name}<#{expression.arguments.map { |argument| legacy(argument) }.join(",")}>"
      end

      "#{base}#{capability_suffix(expression.capabilities)}"
    when FunctionTypeExpression
      "FN(#{expression.signature.params.map { |param| legacy(TypeExpressionParser.parse(param.type.raw)) }.join(",")}) -> #{legacy(TypeExpressionParser.parse(expression.signature.return_type.raw))}#{capability_suffix(expression.capabilities)}"
    when TupleTypeExpression
      "Tuple<#{expression.items.map { |item| legacy(item) }.join(",")}>#{capability_suffix(expression.capabilities)}"
    when OptionalTypeExpression
      inner = legacy(expression.inner)
      inner_expression = expression.inner
      base = inner_expression.is_a?(LinearTypeExpression) || inner_expression.is_a?(MapTypeExpression) ? "?(#{inner})" : "?#{inner}"
      "#{base}#{capability_suffix(expression.capabilities)}"
    when FallibleTypeExpression
      "!#{legacy(expression.inner)}#{capability_suffix(expression.capabilities)}"
    when FutureTypeExpression
      "~#{legacy(expression.inner)}#{capability_suffix(expression.capabilities)}"
    when LinearTypeExpression
      surface = expression.dimensions.reduce(legacy(expression.item)) do |item_surface, dimension|
        suffix = case dimension
        when :LIST then "[]"
        when :STREAM_OPEN then "[?]"
        when :INF then "[INF]"
        when :INFERRED then "[*]"
        else "[#{dimension}]"
        end
        "#{item_surface}#{suffix}"
      end
      "#{surface}#{capability_suffix(expression.capabilities, include_collection: false)}"
    when MapTypeExpression
      key = legacy(expression.key)
      value = legacy(expression.value)
      base = expression.key_implicit ? "HashMap<#{value}>" : "HashMap<#{key}#{expression.legacy_separator}#{value}>"
      "#{base}#{capability_suffix(expression.capabilities)}"
    when StreamTypeExpression
      cardinality = expression.cardinality
      marker = cardinality == :FINITE ? "" : cardinality.to_s
      "[~#{marker}]#{legacy(expression.item)}#{capability_suffix(expression.capabilities)}"
    else
      raise "unknown type expression #{expression.class}"
    end
  end

  sig { params(expression: TypeExpression).returns(String) }
  def self.inline(expression)
    case expression
    when NamedTypeExpression
      base = if expression.arguments.empty?
        expression.name.to_s
      else
        "#{expression.name}<#{expression.arguments.map { |argument| inline(argument) }.join(", ")}>"
      end

      "#{base}#{capability_suffix(expression.capabilities)}"
    when FunctionTypeExpression
      "FN(#{expression.signature.params.map { |param| inline(TypeExpressionParser.parse(param.type.raw)) }.join(", ")}) -> #{inline(TypeExpressionParser.parse(expression.signature.return_type.raw))}#{capability_suffix(expression.capabilities)}"
    when TupleTypeExpression
      "Tuple<#{expression.items.map { |item| inline(item) }.join(", ")}>#{capability_suffix(expression.capabilities)}"
    when OptionalTypeExpression
      "?#{inline(expression.inner)}#{capability_suffix(expression.capabilities)}"
    when FallibleTypeExpression
      "!#{inline(expression.inner)}#{capability_suffix(expression.capabilities)}"
    when FutureTypeExpression
      "~#{inline(expression.inner)}#{capability_suffix(expression.capabilities)}"
    when LinearTypeExpression
      prefix = inline_linear_prefix(expression)
      caps = capability_suffix(expression.capabilities, include_collection: false)
      "#{prefix}#{caps.empty? ? "" : "#{caps} "}#{inline(expression.item)}"
    when MapTypeExpression
      caps = capability_suffix(expression.capabilities)
      "{#{inline(expression.key)}}#{caps.empty? ? "" : "#{caps} "}#{inline(expression.value)}"
    when StreamTypeExpression
      cardinality = expression.cardinality
      marker = cardinality == :FINITE ? "" : cardinality.to_s
      caps = capability_suffix(expression.capabilities)
      "[~#{marker}]#{caps.empty? ? "" : "#{caps} "}#{inline(expression.item)}"
    else
      raise "unknown type expression #{expression.class}"
    end
  end

  sig { params(expression: LinearTypeExpression).returns(String) }
  def self.inline_linear_prefix(expression)
    hint = expression.allocation_hint
    return hint.nil? ? "[]" : "[List(#{hint})]" if expression.list?
    return hint.nil? ? "[Set]" : "[Set(#{hint})]" if expression.set?
    if expression.pool?
      pool_size = hint || expression.dimensions.find { |dimension| dimension.is_a?(Integer) }
      return "[Pool(#{T.must(pool_size)})]"
    end

    dimensions = expression.dimensions.map do |dimension|
      case dimension
      when :LIST then "List"
      when :STREAM_OPEN then "~"
      when :INF then "~INF"
      when :INFERRED then "*"
      else dimension.to_s
      end
    end
    "[#{dimensions.join(", ")}]"
  end
  private_class_method :inline_linear_prefix

  sig { params(capabilities: TypeCapabilities, include_collection: T::Boolean).returns(String) }
  def self.capability_suffix(capabilities, include_collection: true)
    parts = T.let([], T::Array[String])
    ownership = capabilities.ownership
    parts << T.must(Type.ownership_surface_name_for(ownership)) unless ownership.nil? || ownership == :affine
    parts << "@boxed" if capabilities.layout == :indirect
    parts << "@soa" if capabilities.soa
    parts << "@sharded(#{capabilities.shard_count})" unless capabilities.shard_count.nil?
    sync = capabilities.sync
    parts << T.must(Type.sync_surface_name_for(sync)) unless sync.nil?
    parts << "@observable" if capabilities.observable
    if include_collection && !capabilities.collection.nil?
      parts << "@#{capabilities.collection}"
    end
    return "" if parts.empty?

    parts.first.to_s + parts.drop(1).map { |part| ":#{part.delete_prefix("@")}" }.join
  end
  private_class_method :capability_suffix
end
