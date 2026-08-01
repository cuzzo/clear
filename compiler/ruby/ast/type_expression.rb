# typed: strict

require "sorbet-runtime"
require_relative "type_capabilities"

# The variant-specific payload of a type expression. Every concrete node kind
# includes this marker. The per-node `capabilities` field is NOT duplicated into
# each variant -- it is hoisted onto the `TypeExpression` wrapper below and
# stored once, so reading it off any node is a direct field access with no
# per-variant dispatch. A node kind is always paired with its capabilities via
# the wrapper (`TypeExpression#kind` / `#capabilities`).
module TypeExpressionKind
  extend T::Helpers
  include Kernel
  sealed!
end

# A type expression: a variant payload (`kind`) plus the capabilities that apply
# to this node. Capabilities live here (once) rather than on every variant.
class TypeExpression < T::Struct
  extend T::Sig

  Dimension = T.type_alias { T.any(Integer, Symbol) }
  VALID_TENSE_ORDERS = T.let(
    ["", "!", "?", "!?", "~", "~!", "~?", "~!?", "!~", "!~!", "!~?", "!~!?"].freeze,
    T::Array[String],
  )

  const :kind, TypeExpressionKind
  const :capabilities, TypeCapabilities, factory: -> { TypeCapabilities::AFFINE }

  # Build a wrapper around a freshly-constructed variant payload, defaulting
  # capabilities to AFFINE when the caller does not care.
  sig { params(kind: TypeExpressionKind, capabilities: TypeCapabilities).returns(TypeExpression) }
  def self.of(kind, capabilities = TypeCapabilities::AFFINE)
    new(kind: kind, capabilities: capabilities)
  end

  # Replace this node's capabilities, keeping the variant payload.
  sig { params(capabilities: TypeCapabilities).returns(TypeExpression) }
  def with_capabilities(capabilities)
    TypeExpression.new(kind: kind, capabilities: capabilities)
  end
end

class NamedTypeExpression < T::Struct
  include TypeExpressionKind

  const :name, Symbol
  const :arguments, T::Array[TypeExpression], default: []
end

# A protocol-associated type selected from a generic type parameter, such as
# M::Key or M::Value.  This remains symbolic while a generic body is checked
# and is replaced from the concrete conformance witness at instantiation.
class TypeProjectionExpression < T::Struct
  include TypeExpressionKind

  const :owner, Symbol
  const :member, Symbol
  # Filled by semantic analysis after the owner's bounds are known. Keeping
  # this on the immutable syntax node makes `M::Item` unambiguous when M is
  # constrained by more than one protocol with an Item associated type.
  const :protocol, T.nilable(Symbol), default: nil
end

class FunctionParamExpression < T::Struct
  const :expression, TypeExpression
end

# Foundation-native function signature: parameters and return spelled as
# TypeExpressions. `semantic_payload` is an opaque backref (the semantic
# Type::FunctionType) owned entirely by type.rb; the foundation never
# inspects it.
class FunctionSignatureExpression < T::Struct
  const :params, T::Array[FunctionParamExpression]
  const :return_expression, TypeExpression
  const :reentrant, T::Boolean, default: false
  const :abi, Symbol, default: :clear
  const :semantic_payload, T.nilable(BasicObject), default: nil
end

class FunctionTypeExpression < T::Struct
  include TypeExpressionKind

  const :signature, FunctionSignatureExpression
end

class TupleTypeExpression < T::Struct
  include TypeExpressionKind

  const :items, T::Array[TypeExpression]
end

class OptionalTypeExpression < T::Struct
  include TypeExpressionKind

  const :inner, TypeExpression
end

class FallibleTypeExpression < T::Struct
  include TypeExpressionKind

  const :inner, TypeExpression
  const :error_set, T.nilable(TypeExpression), default: nil
end

class FutureTypeExpression < T::Struct
  include TypeExpressionKind

  const :inner, TypeExpression
end

class LinearTypeExpression < T::Struct
  extend T::Sig
  include TypeExpressionKind

  const :kind, Symbol
  const :dimensions, T::Array[TypeExpression::Dimension]
  const :item, TypeExpression
  const :allocation_hint, T.nilable(Integer), default: nil

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
  include TypeExpressionKind

  const :key, TypeExpression
  const :value, TypeExpression
  # The key is always explicit semantically. This flag only preserves whether
  # legacy HashMap<V> syntax omitted its default String key while migration is
  # still expected to round-trip both accepted spellings.
  const :key_implicit, T::Boolean, default: false
  const :legacy_separator, String, default: ","
end

class StreamTypeExpression < T::Struct
  include TypeExpressionKind

  const :cardinality, TypeExpression::Dimension
  const :item, TypeExpression
end

class TypeExpressionTree
  extend T::Sig

  sig { params(expression: TypeExpression).returns(TypeCapabilities) }
  def self.root_capabilities(expression)
    # ruby-to-clear represents the wrapper as its closed kind union and
    # distributes wrapper fields onto each payload. Keep the read under a
    # kind refinement so the generated frontend can select the concrete
    # payload field; Ruby still reads the single wrapper field.
    kind = expression.kind
    return expression.capabilities if kind.is_a?(NamedTypeExpression)
    return expression.capabilities if kind.is_a?(TypeProjectionExpression)
    return expression.capabilities if kind.is_a?(FunctionTypeExpression)
    return expression.capabilities if kind.is_a?(TupleTypeExpression)
    return expression.capabilities if kind.is_a?(OptionalTypeExpression)
    return expression.capabilities if kind.is_a?(FallibleTypeExpression)
    return expression.capabilities if kind.is_a?(FutureTypeExpression)
    return expression.capabilities if kind.is_a?(LinearTypeExpression)
    return expression.capabilities if kind.is_a?(MapTypeExpression)
    return expression.capabilities if kind.is_a?(StreamTypeExpression)

    # TypeExpressionKind is sealed, so this is unreachable. Keep a concrete
    # fallback because the generated CLEAR frontend has no T.absurd helper.
    TypeCapabilities::AFFINE
  end

  sig { params(expression: TypeExpression, capabilities: TypeCapabilities).returns(TypeExpression) }
  def self.with_root_capabilities(expression, capabilities)
    # Capabilities are hoisted onto the wrapper, so replacing the root's
    # capabilities is a single field swap that keeps the variant payload.
    expression.with_capabilities(capabilities)
  end

  sig { params(expression: TypeExpression).returns(T.nilable(TypeCapabilities)) }
  def self.linear_item_capabilities(expression)
    node = T.let(expression, TypeExpression)
    loop do
      kind = node.kind
      case kind
      when FallibleTypeExpression, FutureTypeExpression, OptionalTypeExpression
        node = kind.inner
      else
        break
      end
    end
    linear = node.kind
    return nil unless linear.is_a?(LinearTypeExpression)

    root_capabilities(linear.item)
  end

  sig { params(expression: TypeExpression, capabilities: TypeCapabilities).returns(TypeExpression) }
  def self.with_linear_item_capabilities(expression, capabilities)
    kind = expression.kind
    cap = expression.capabilities
    if kind.is_a?(FallibleTypeExpression)
      return TypeExpression.new(kind: FallibleTypeExpression.new(
        inner: with_linear_item_capabilities(kind.inner, capabilities),
        error_set: kind.error_set,
      ), capabilities: cap)
    end
    if kind.is_a?(FutureTypeExpression)
      return TypeExpression.new(kind: FutureTypeExpression.new(
        inner: with_linear_item_capabilities(kind.inner, capabilities),
      ), capabilities: cap)
    end
    if kind.is_a?(OptionalTypeExpression)
      return TypeExpression.new(kind: OptionalTypeExpression.new(
        inner: with_linear_item_capabilities(kind.inner, capabilities),
      ), capabilities: cap)
    end
    return expression unless kind.is_a?(LinearTypeExpression)

    TypeExpression.new(kind: LinearTypeExpression.new(
      kind: kind.kind,
      dimensions: kind.dimensions,
      item: with_root_capabilities(kind.item, capabilities),
      allocation_hint: kind.allocation_hint,
    ), capabilities: cap)
  end

  # Return the item beneath one linear collection while retaining every tense
  # wrapped around that collection. For example, `![]T` becomes `!T`. Promise
  # lists use this to give each physical Promise the same semantic payload
  # envelope that aggregate NEXT later reconstructs around the result list.
  sig { params(expression: TypeExpression).returns(T.nilable(TypeExpression)) }
  def self.linear_item_envelope(expression)
    kind = expression.kind
    cap = expression.capabilities
    case kind
    when FallibleTypeExpression
      inner = linear_item_envelope(kind.inner)
      return nil unless inner

      TypeExpression.new(kind: FallibleTypeExpression.new(inner: inner, error_set: kind.error_set), capabilities: cap)
    when FutureTypeExpression
      inner = linear_item_envelope(kind.inner)
      return nil unless inner

      TypeExpression.new(kind: FutureTypeExpression.new(inner: inner), capabilities: cap)
    when OptionalTypeExpression
      inner = linear_item_envelope(kind.inner)
      return nil unless inner

      TypeExpression.new(kind: OptionalTypeExpression.new(inner: inner), capabilities: cap)
    when LinearTypeExpression
      kind.item
    else
      nil
    end
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
    kind = expression.kind
    cap = expression.capabilities
    case kind
    when OptionalTypeExpression
      TypeExpression.new(kind: OptionalTypeExpression.new(
        inner: with_nominal_arguments(kind.inner, name, arguments),
      ), capabilities: cap)
    when FallibleTypeExpression
      TypeExpression.new(kind: FallibleTypeExpression.new(
        inner: with_nominal_arguments(kind.inner, name, arguments),
        error_set: kind.error_set,
      ), capabilities: cap)
    when FutureTypeExpression
      TypeExpression.new(kind: FutureTypeExpression.new(
        inner: with_nominal_arguments(kind.inner, name, arguments),
      ), capabilities: cap)
    when LinearTypeExpression
      TypeExpression.new(kind: LinearTypeExpression.new(
        kind: kind.kind,
        dimensions: kind.dimensions,
        item: with_nominal_arguments(kind.item, name, arguments),
        allocation_hint: kind.allocation_hint,
      ), capabilities: cap)
    when StreamTypeExpression
      TypeExpression.new(kind: StreamTypeExpression.new(
        cardinality: kind.cardinality,
        item: with_nominal_arguments(kind.item, name, arguments),
      ), capabilities: cap)
    when FunctionTypeExpression
      expression
    when TupleTypeExpression
      return expression unless name == :Tuple

      TypeExpression.new(kind: TupleTypeExpression.new(items: arguments), capabilities: cap)
    when NamedTypeExpression
      return expression unless kind.name == name

      TypeExpression.new(kind: NamedTypeExpression.new(name: name, arguments: arguments), capabilities: cap)
    when MapTypeExpression
      return expression unless name == :HashMap

      key = arguments.length == 1 ? kind.key : arguments.fetch(0)
      value = arguments.length == 1 ? arguments.fetch(0) : arguments.fetch(1)
      TypeExpression.new(kind: MapTypeExpression.new(
        key: key,
        value: value,
        key_implicit: arguments.length == 1,
        legacy_separator: kind.legacy_separator,
      ), capabilities: cap)
    else
      expression
    end
  end

  # Rebuild a complete type-expression tree without flattening it through the
  # legacy type-string representation. The callback sees every node after its
  # children have been transformed, which lets semantic passes attach facts to
  # nested projections while preserving tenses, collection topology, and
  # per-layer capabilities.
  sig do
    params(
      expression: TypeExpression,
      visitor: T.proc.params(node: TypeExpression).returns(TypeExpression),
    ).returns(TypeExpression)
  end
  def self.transform(expression, &visitor)
    kind = expression.kind
    cap = expression.capabilities
    rebuilt = T.let(case kind
    when NamedTypeExpression
      TypeExpression.new(kind: NamedTypeExpression.new(
        name: kind.name,
        arguments: kind.arguments.map { |argument| transform(argument, &visitor) },
      ), capabilities: cap)
    when TypeProjectionExpression
      expression
    when FunctionTypeExpression
      signature = kind.signature
      TypeExpression.new(kind: FunctionTypeExpression.new(
        signature: FunctionSignatureExpression.new(
          params: signature.params.map do |param|
            FunctionParamExpression.new(expression: transform(param.expression, &visitor))
          end,
          return_expression: transform(signature.return_expression, &visitor),
          reentrant: signature.reentrant,
          abi: signature.abi,
        ),
      ), capabilities: cap)
    when TupleTypeExpression
      TypeExpression.new(kind: TupleTypeExpression.new(
        items: kind.items.map { |item| transform(item, &visitor) },
      ), capabilities: cap)
    when OptionalTypeExpression
      TypeExpression.new(kind: OptionalTypeExpression.new(inner: transform(kind.inner, &visitor)), capabilities: cap)
    when FallibleTypeExpression
      error_set = kind.error_set
      transformed_error_set = if error_set
        transform(error_set, &visitor)
      end
      TypeExpression.new(kind: FallibleTypeExpression.new(
        inner: transform(kind.inner, &visitor),
        error_set: transformed_error_set,
      ), capabilities: cap)
    when FutureTypeExpression
      TypeExpression.new(kind: FutureTypeExpression.new(inner: transform(kind.inner, &visitor)), capabilities: cap)
    when LinearTypeExpression
      TypeExpression.new(kind: LinearTypeExpression.new(
        kind: kind.kind,
        dimensions: kind.dimensions,
        item: transform(kind.item, &visitor),
        allocation_hint: kind.allocation_hint,
      ), capabilities: cap)
    when MapTypeExpression
      TypeExpression.new(kind: MapTypeExpression.new(
        key: transform(kind.key, &visitor),
        value: transform(kind.value, &visitor),
        key_implicit: kind.key_implicit,
        legacy_separator: kind.legacy_separator,
      ), capabilities: cap)
    when StreamTypeExpression
      TypeExpression.new(kind: StreamTypeExpression.new(
        cardinality: kind.cardinality,
        item: transform(kind.item, &visitor),
      ), capabilities: cap)
    else
      expression
    end, TypeExpression)
    visitor.call(rebuilt)
  end

  sig { params(expression: TypeExpression).returns(Integer) }
  def self.node_count(expression)
    each_node(expression).length
  end

  sig { params(expression: TypeExpression).returns(Integer) }
  def self.capability_site_count(expression)
    own_site = expression.capabilities.explicit_layer_capability? ? 1 : 0
    child_depth = T.let(0, Integer)
    children(expression).each do |child|
      depth = capability_site_count(child)
      child_depth = depth if depth > child_depth
    end
    own_site + child_depth
  end

  sig { params(expression: TypeExpression).returns(T::Boolean) }
  def self.nested_capabilities?(expression)
    each_node(expression).drop(1).any? do |node|
      root_capabilities(node).explicit_layer_capability?
    end
  end

  sig { params(expression: TypeExpression).returns(T::Boolean) }
  def self.tense_wrapper?(expression)
    case expression.kind
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
      node_children = children(node)
      found << node
      pending.concat(node_children)
    end
    found
  end

  # Immediate syntax children are a semantic inventory boundary as well as a
  # tree-walking detail. Lifecycle planning uses this to register every
  # intermediate wrapper (`!?T` includes a distinct `?T` contract) before MIR
  # asks for copy/drop behavior.
  sig { params(expression: TypeExpression).returns(T::Array[TypeExpression]) }
  def self.direct_children(expression)
    children(expression)
  end

  sig { params(expression: TypeExpression).returns(T::Array[TypeExpression]) }
  def self.children(expression)
    kind = expression.kind
    case kind
    when NamedTypeExpression then kind.arguments
    when TypeProjectionExpression then []
    when FunctionTypeExpression
      kind.signature.params.map(&:expression) +
        [kind.signature.return_expression]
    when TupleTypeExpression then kind.items
    when OptionalTypeExpression, FutureTypeExpression then [kind.inner]
    when FallibleTypeExpression
      kind.error_set.nil? ? [kind.inner] : [kind.inner, T.must(kind.error_set)]
    when LinearTypeExpression, StreamTypeExpression then [kind.item]
    when MapTypeExpression then [kind.key, kind.value]
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

  # Semantic function-type raws (Type::FunctionType) convert at the type.rb
  # boundary (Type.function_type_expression); the foundation parses spellings.
  sig { params(raw: T.any(Symbol, String)).returns(TypeExpression) }
  def self.parse(raw)
    source = raw.to_s
    if source.start_with?("[~")
      closing = source.index("]")
      unless closing.nil?
        marker = source[2...closing].to_s
        cardinality = T.let(
          if marker.empty?
            :FINITE
          elsif marker == "INF"
            :INF
          elsif marker.match?(/\A\d+\z/)
            marker.to_i
          end,
          T.nilable(TypeExpression::Dimension)
        )
        unless cardinality.nil?
          item_source = source[(closing + 1)..].to_s
          return TypeExpression.of(StreamTypeExpression.new(cardinality: cardinality, item: parse(item_source))) unless item_source.empty?
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

    order = source[/\A[~!?]+/].to_s
    unless TypeExpression::VALID_TENSE_ORDERS.include?(order)
      raise ArgumentError, "double future type is not allowed" if order.include?("~~")
      raise ArgumentError, "double fallible type is not allowed" if order.include?("!!")
      raise ArgumentError, "double optional type is not allowed" if order.include?("??")

      raise ArgumentError, "unsupported tense order #{order.inspect}"
    end

    inner_source = source[1..].to_s
    case prefix
    when "~"
      raise ArgumentError, "double future type is not allowed" if inner_source.start_with?("~")

      TypeExpression.of(FutureTypeExpression.new(inner: parse_source(inner_source)))
    when "!"
      TypeExpression.of(FallibleTypeExpression.new(inner: parse_source(inner_source)))
    when "?"
      parse_optional_source(inner_source)
    end
  end

  sig { params(inner_source: String).returns(TypeExpression) }
  def self.parse_optional_source(inner_source)
    raise ArgumentError, "double optional type is not allowed" if inner_source.start_with?("?")
    if grouped_type?(inner_source)
      return TypeExpression.of(OptionalTypeExpression.new(inner: parse_source(inner_source[1..-2].to_s)))
    end

    optional_array_parts = split_array_suffix(inner_source)
    unless optional_array_parts.nil?
      item_source, dimension = optional_array_parts
      return TypeExpression.of(LinearTypeExpression.new(
        kind: dimension.nil? ? :list : :array,
        dimensions: [dimension || :LIST],
        item: TypeExpression.of(OptionalTypeExpression.new(inner: parse_source(item_source))),
      ))
    end

    TypeExpression.of(OptionalTypeExpression.new(inner: parse_source(inner_source)))
  end

  sig { params(source: String).returns(TypeExpression) }
  def self.parse_primary_source(source)
    array = parse_array_source(source)
    return array unless array.nil?

    parse_generic_or_named_source(source)
  end

  sig { params(source: String).returns(T.nilable(TypeExpression)) }
  def self.parse_array_source(source)
    array_parts = split_array_suffix(source)
    return nil if array_parts.nil?

    item_source, dimension = array_parts
    TypeExpression.of(LinearTypeExpression.new(
      kind: dimension.nil? ? :list : :array,
      dimensions: [dimension || :LIST],
      item: parse_source(item_source),
    ))
  end

  sig { params(source: String).returns(TypeExpression) }
  def self.parse_generic_or_named_source(source)
    if (projection = /\A([A-Z]\w*)::([A-Z]\w*)\z/.match(source))
      return TypeExpression.of(TypeProjectionExpression.new(
        owner: T.must(projection[1]).to_sym,
        member: T.must(projection[2]).to_sym,
      ))
    end

    generic = split_generic(source)
    unless generic.nil?
      arguments = generic.arguments.map { |argument| parse_source(argument) }
      if generic.base == "HashMap"
        if arguments.length == 1
          return TypeExpression.of(MapTypeExpression.new(
            key: TypeExpression.of(NamedTypeExpression.new(name: :String)),
            value: T.must(arguments.first),
            key_implicit: true,
          ))
        end
        if arguments.length == 2
          key = T.must(arguments.first)
          value = T.must(arguments.last)
          return TypeExpression.of(MapTypeExpression.new(
            key: key,
            value: value,
            legacy_separator: top_level_argument_separator(source),
          ))
        end
        raise ArgumentError, "HashMap expects one or two type arguments"
      elsif generic.base == "Tuple"
        return TypeExpression.of(TupleTypeExpression.new(items: arguments))
      end

      return TypeExpression.of(NamedTypeExpression.new(name: generic.base.to_sym, arguments: arguments))
    end

    base, capabilities = split_legacy_capability_suffix(source)
    TypeExpression.new(kind: NamedTypeExpression.new(name: base.to_sym), capabilities: capabilities)
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

  sig { params(source: String).returns(T.nilable([String, T.nilable(TypeExpression::Dimension)])) }
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
          dimension = T.let(
            case dimension_source
            when "" then nil
            when "?" then :STREAM_OPEN
            when "INF" then :INF
            when "*" then :INFERRED
            else
              return nil unless dimension_source.match?(/\A\d+\z/)

              dimension_source.to_i
            end,
            T.nilable(TypeExpression::Dimension)
          )
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

  # A collection dimension is either an Integer size or a Symbol marker. Branch
  # the union variant explicitly instead of matching the union value against
  # symbol literals: the typed self-host cannot compare `Integer | Symbol` to a
  # bare `:LIST`, so narrowing to Symbol first keeps the inner case well-typed.
  sig { params(dimension: TypeExpression::Dimension).returns(String) }
  def self.dimension_suffix(dimension)
    if dimension.is_a?(Symbol)
      case dimension
      when :LIST then "[]"
      when :STREAM_OPEN then "[?]"
      when :INF then "[INF]"
      when :INFERRED then "[*]"
      else "[#{dimension}]"
      end
    else
      "[#{dimension}]"
    end
  end

  # Inline Pivot dimension marker: same variant split as `dimension_suffix`.
  sig { params(dimension: TypeExpression::Dimension).returns(String) }
  def self.dimension_marker(dimension)
    if dimension.is_a?(Symbol)
      case dimension
      when :LIST then "List"
      when :STREAM_OPEN then "~"
      when :INF then "~INF"
      when :INFERRED then "*"
      else dimension.to_s
      end
    else
      dimension.to_s
    end
  end

  # Canonical semantic spelling used for type identity. Unlike `legacy`, this
  # deliberately normalizes stream syntax and omits representation
  # capabilities, which are keyed separately by Type.
  sig { params(expression: TypeExpression).returns(String) }
  def self.semantic(expression)
    kind = expression.kind
    case kind
    when NamedTypeExpression
      return kind.name.to_s if kind.arguments.empty?

      "#{kind.name}<#{kind.arguments.map { |argument| semantic(argument) }.join(",")}>"
    when TypeProjectionExpression
      "#{kind.owner}::#{kind.member}"
    when FunctionTypeExpression
      params = kind.signature.params.map { |param| semantic(param.expression) }.join(",")
      "FN(#{params}) -> #{semantic(kind.signature.return_expression)}"
    when TupleTypeExpression
      "Tuple<#{kind.items.map { |item| semantic(item) }.join(",")}>"
    when OptionalTypeExpression
      inner = semantic(kind.inner)
      inner_kind = kind.inner.kind
      grouped = inner_kind.is_a?(LinearTypeExpression) || inner_kind.is_a?(MapTypeExpression)
      grouped ? "?(#{inner})" : "?#{inner}"
    when FallibleTypeExpression
      "!#{semantic(kind.inner)}"
    when FutureTypeExpression
      "~#{semantic(kind.inner)}"
    when LinearTypeExpression
      kind.dimensions.reduce(semantic(kind.item)) do |surface, dimension|
        "#{surface}#{dimension_suffix(dimension)}"
      end
    when MapTypeExpression
      "HashMap<#{semantic(kind.key)},#{semantic(kind.value)}>"
    when StreamTypeExpression
      suffix = kind.cardinality == :FINITE ? "[]" : "[#{kind.cardinality}]"
      "~#{semantic(kind.item)}#{suffix}"
    else
      raise "unknown type expression #{kind.class}"
    end
  end

  sig { params(expression: TypeExpression).returns(String) }
  def self.legacy(expression)
    kind = expression.kind
    cap = expression.capabilities
    case kind
    when NamedTypeExpression
      base = if kind.arguments.empty?
        kind.name.to_s
      else
        "#{kind.name}<#{kind.arguments.map { |argument| legacy(argument) }.join(",")}>"
      end

      "#{base}#{capability_suffix(cap)}"
    when TypeProjectionExpression
      "#{kind.owner}::#{kind.member}#{capability_suffix(cap)}"
    when FunctionTypeExpression
      "FN(#{kind.signature.params.map { |param| legacy(param.expression) }.join(",")}) -> #{legacy(kind.signature.return_expression)}#{capability_suffix(cap)}"
    when TupleTypeExpression
      "Tuple<#{kind.items.map { |item| legacy(item) }.join(",")}>#{capability_suffix(cap)}"
    when OptionalTypeExpression
      inner = legacy(kind.inner)
      inner_kind = kind.inner.kind
      base = inner_kind.is_a?(LinearTypeExpression) || inner_kind.is_a?(MapTypeExpression) ? "?(#{inner})" : "?#{inner}"
      "#{base}#{capability_suffix(cap)}"
    when FallibleTypeExpression
      "!#{legacy(kind.inner)}#{capability_suffix(cap)}"
    when FutureTypeExpression
      "~#{legacy(kind.inner)}#{capability_suffix(cap)}"
    when LinearTypeExpression
      surface = kind.dimensions.reduce(legacy(kind.item)) do |item_surface, dimension|
        "#{item_surface}#{dimension_suffix(dimension)}"
      end
      "#{surface}#{capability_suffix(cap, include_collection: false)}"
    when MapTypeExpression
      key = legacy(kind.key)
      value = legacy(kind.value)
      base = kind.key_implicit ? "HashMap<#{value}>" : "HashMap<#{key}#{kind.legacy_separator}#{value}>"
      "#{base}#{capability_suffix(cap)}"
    when StreamTypeExpression
      cardinality = kind.cardinality
      marker = cardinality == :FINITE ? "" : cardinality.to_s
      "[~#{marker}]#{legacy(kind.item)}#{capability_suffix(cap)}"
    else
      raise "unknown type expression #{kind.class}"
    end
  end

  sig { params(expression: TypeExpression).returns(String) }
  def self.inline(expression)
    kind = expression.kind
    cap = expression.capabilities
    case kind
    when NamedTypeExpression
      base = if kind.arguments.empty?
        kind.name.to_s
      else
        "#{kind.name}<#{kind.arguments.map { |argument| inline(argument) }.join(", ")}>"
      end

      "#{base}#{capability_suffix(cap)}"
    when TypeProjectionExpression
      "#{kind.owner}::#{kind.member}#{capability_suffix(cap)}"
    when FunctionTypeExpression
      "FN(#{kind.signature.params.map { |param| inline(param.expression) }.join(", ")}) -> #{inline(kind.signature.return_expression)}#{capability_suffix(cap)}"
    when TupleTypeExpression
      "Tuple<#{kind.items.map { |item| inline(item) }.join(", ")}>#{capability_suffix(cap)}"
    when OptionalTypeExpression
      "?#{inline(kind.inner)}#{capability_suffix(cap)}"
    when FallibleTypeExpression
      "!#{inline(kind.inner)}#{capability_suffix(cap)}"
    when FutureTypeExpression
      "~#{inline(kind.inner)}#{capability_suffix(cap)}"
    when LinearTypeExpression
      prefix = inline_linear_prefix(kind)
      caps = capability_suffix(cap, include_collection: false)
      "#{prefix}#{caps.empty? ? "" : "#{caps} "}#{inline(kind.item)}"
    when MapTypeExpression
      caps = capability_suffix(cap)
      "{#{inline(kind.key)}}#{caps.empty? ? "" : "#{caps} "}#{inline(kind.value)}"
    when StreamTypeExpression
      cardinality = kind.cardinality
      marker = cardinality == :FINITE ? "" : cardinality.to_s
      caps = capability_suffix(cap)
      "[~#{marker}]#{caps.empty? ? "" : "#{caps} "}#{inline(kind.item)}"
    else
      raise "unknown type expression #{kind.class}"
    end
  end

  sig { params(expression: LinearTypeExpression).returns(String) }
  def self.inline_linear_prefix(expression)
    hint = expression.allocation_hint
    return hint.nil? ? "[]" : "[List(#{hint})]" if expression.list?
    return hint.nil? ? "[Set]" : "[Set(#{hint})]" if expression.set?
    if expression.pool?
      pool_size = T.let(hint, T.nilable(Integer))
      if pool_size.nil?
        candidate = expression.dimensions.find { |dimension| dimension.is_a?(Integer) }
        pool_size = candidate if candidate.is_a?(Integer)
      end
      return "[Pool(#{T.must(pool_size)})]"
    end

    dimensions = expression.dimensions.map { |dimension| dimension_marker(dimension) }
    "[#{dimensions.join(", ")}]"
  end
  private_class_method :inline_linear_prefix

  sig { params(capabilities: TypeCapabilities, include_collection: T::Boolean).returns(String) }
  def self.capability_suffix(capabilities, include_collection: true)
    parts = T.let([], T::Array[String])
    ownership = capabilities.ownership
    if ownership && ownership != :affine
      parts << T.must(TypeCapabilities.ownership_surface_name_for(ownership))
    end
    parts << "@boxed" if capabilities.layout == :indirect
    parts << "@soa" if capabilities.soa
    parts << "@sharded(#{capabilities.shard_count})" unless capabilities.shard_count.nil?
    sync = capabilities.sync
    parts << T.must(TypeCapabilities.sync_surface_name_for(sync)) unless sync.nil?
    parts << "@observable" if capabilities.observable
    if include_collection && !capabilities.collection.nil?
      parts << "@#{capabilities.collection}"
    end
    return "" if parts.empty?

    parts.first.to_s + parts.drop(1).map { |part| ":#{part.delete_prefix("@")}" }.join
  end
  private_class_method :capability_suffix
end
