# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../ast/ast"

class TenseLayerKind < T::Enum
  enums do
    Fallible = new("!")
    Future = new("~")
    Optional = new("?")
  end
end

class TenseLayer < T::Struct
  extend T::Sig

  const :kind, TenseLayerKind
  const :capabilities, TypeCapabilities
  const :error_set, T.nilable(TypeExpression), default: nil

  sig { returns(String) }
  def marker
    kind.serialize
  end

  sig { params(inner: TypeExpression).returns(TypeExpression) }
  def wrap(inner)
    layer_kind = kind
    case layer_kind
    when TenseLayerKind::Fallible
      FallibleTypeExpression.new(inner: inner, error_set: error_set, capabilities: capabilities)
    when TenseLayerKind::Future
      FutureTypeExpression.new(inner: inner, capabilities: capabilities)
    when TenseLayerKind::Optional
      OptionalTypeExpression.new(inner: inner, capabilities: capabilities)
    end
  end
end

class TenseFutureSplit < T::Struct
  const :outer, T::Array[TenseLayer]
  const :inner, T::Array[TenseLayer]
end

class TenseEnvelope < T::Struct
  extend T::Sig

  VALID_ORDERS = TypeExpression::VALID_TENSE_ORDERS

  const :layers, T::Array[TenseLayer]
  const :payload_expression, TypeExpression

  sig { params(type: Type).returns(TenseEnvelope) }
  def self.from_type(type)
    from_expression(type.shape.expression)
  end

  sig { params(expression: TypeExpression).returns(TenseEnvelope) }
  def self.from_expression(expression)
    layers = T.let([], T::Array[TenseLayer])
    current = T.let(expression, TypeExpression)
    loop do
      case current
      when FallibleTypeExpression
        layers << TenseLayer.new(
          kind: TenseLayerKind::Fallible,
          capabilities: current.capabilities,
          error_set: current.error_set,
        )
        current = current.inner
      when FutureTypeExpression
        layers << TenseLayer.new(kind: TenseLayerKind::Future, capabilities: current.capabilities)
        current = current.inner
      when OptionalTypeExpression
        layers << TenseLayer.new(kind: TenseLayerKind::Optional, capabilities: current.capabilities)
        current = current.inner
      else
        break
      end
    end
    envelope = new(layers: layers.freeze, payload_expression: current)
    raise ArgumentError, "unsupported tense order #{envelope.order.inspect}" unless envelope.valid?

    envelope
  end

  sig { returns(String) }
  def order
    layers.map(&:marker).join
  end

  sig { returns(T::Boolean) }
  def valid?
    VALID_ORDERS.include?(order)
  end

  sig { returns(T::Boolean) }
  def asynchronous?
    layers.any? { |layer| layer.kind == TenseLayerKind::Future }
  end

  sig { returns(T::Boolean) }
  def fallible?
    layers.any? { |layer| layer.kind == TenseLayerKind::Fallible }
  end

  sig { returns(T::Boolean) }
  def optional?
    layers.any? { |layer| layer.kind == TenseLayerKind::Optional }
  end

  sig { returns(Type) }
  def payload_type
    Type.from_child_expression(payload_expression)
  end

  sig { params(payload: TypeExpression).returns(TypeExpression) }
  def wrap(payload)
    layers.reverse_each.reduce(payload) { |inner, layer| layer.wrap(inner) }
  end

  sig { returns(TenseFutureSplit) }
  def split_future
    index = layers.index { |layer| layer.kind == TenseLayerKind::Future }
    return TenseFutureSplit.new(outer: [].freeze, inner: layers.freeze) if index.nil?

    TenseFutureSplit.new(
      outer: layers.take(index).freeze,
      inner: layers.drop(index + 1).freeze,
    )
  end

  sig { params(payload: TypeExpression, selected_layers: T::Array[TenseLayer]).returns(TypeExpression) }
  def self.wrap_layers(payload, selected_layers)
    selected_layers.reverse_each.reduce(payload) { |inner, layer| layer.wrap(inner) }
  end
end

class TenseSelectorPlan < T::Struct
  extend T::Sig
  include AST::TensePlanValue

  const :value_type, Type
  const :envelope, TenseEnvelope

  sig { returns(String) }
  def required_order
    envelope.order
  end

  sig { returns(Type) }
  def leaf_type
    envelope.payload_type
  end

  sig { returns(T::Boolean) }
  def asynchronous?
    envelope.asynchronous?
  end

  sig { returns(T::Boolean) }
  def fallible?
    envelope.fallible?
  end

  sig { returns(T.nilable(Symbol)) }
  def required_mode
    return :fallible_optional if envelope.fallible? && envelope.optional?
    return :fallible if envelope.fallible?
    return :optional if envelope.optional?

    nil
  end

  sig { params(cardinality: TypeExpression::Dimension).returns(Type) }
  def stream_result_type(cardinality)
    split = envelope.split_future
    item = TenseEnvelope.wrap_layers(envelope.payload_expression, split.inner)
    stream = StreamTypeExpression.new(cardinality: cardinality, item: item)
    Type.new(TenseEnvelope.wrap_layers(stream, split.outer))
  end
end

class TenseOperationPlanner
  extend T::Sig

  sig { params(type: Type).returns(TenseSelectorPlan) }
  def self.selector(type)
    TenseSelectorPlan.new(value_type: type, envelope: TenseEnvelope.from_type(type))
  end
end
