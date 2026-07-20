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

class TenseOperationKind < T::Enum
  enums do
    Try = new(:try)
    Unwrap = new(:unwrap)
    Next = new(:next)
    OrElseValue = new(:or_else_value)
    OrElseRaise = new(:or_else_raise)
    OrElseExit = new(:or_else_exit)
    OrElsePass = new(:or_else_pass)
    OrElseBreak = new(:or_else_break)
    OrElsePrune = new(:or_else_prune)
    IsOk = new(:is_ok)
    Exists = new(:exists)
    Navigate = new(:navigate)
    AsyncJoin = new(:async_join)
    Select = new(:select)
  end
end

class TenseBackendForm < T::Enum
  enums do
    ZigTry = new(:zig_try)
    OptionalTry = new(:optional_try)
    OptionalUnwrap = new(:optional_unwrap)
    PromiseNext = new(:promise_next)
    SharedPromiseNext = new(:shared_promise_next)
    ObservableStringNext = new(:observable_string_next)
    ZigCatch = new(:zig_catch)
    ZigOptionalFallback = new(:zig_optional_fallback)
    FallibleTest = new(:fallible_test)
    OptionalTest = new(:optional_test)
    DirectMap = new(:direct_map)
    FutureMap = new(:future_map)
    AsyncJoin = new(:async_join)
    Select = new(:select)
  end
end

class TensePropagation < T::Enum
  enums do
    None = new(:none)
    Failure = new(:failure)
    AbsenceAsFailure = new(:absence_as_failure)
  end
end

class TenseRecovery < T::Enum
  enums do
    None = new(:none)
    Fallback = new(:fallback)
    Raise = new(:raise)
    Exit = new(:exit)
    Pass = new(:pass)
    Break = new(:break)
    Prune = new(:prune)
  end
end

class TenseHandleUse < T::Enum
  enums do
    None = new(:none)
    Consume = new(:consume)
    SharedRead = new(:shared_read)
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

  sig { params(kind: TenseLayerKind).returns(T.nilable(Integer)) }
  def layer_index(kind)
    layers.index { |layer| layer.kind == kind }
  end

  sig { params(index: Integer).returns(Type) }
  def without_layer(index)
    retained = layers.each_with_index.filter_map { |layer, layer_index| layer unless layer_index == index }
    Type.new(TenseEnvelope.wrap_layers(payload_expression, retained))
  end
end

class TenseOperationPlan < T::Struct
  extend T::Sig
  include AST::TensePlanValue

  const :operation, TenseOperationKind
  const :input_type, Type
  const :result_type, Type
  const :backend_form, TenseBackendForm
  const :consumed_layers, T::Array[TenseLayer], factory: -> { [] }
  const :preserved_layers, T::Array[TenseLayer], factory: -> { [] }
  const :navigation_layers, T::Array[TenseLayer], factory: -> { [] }
  const :propagation, TensePropagation, default: TensePropagation::None
  const :recovery, TenseRecovery, default: TenseRecovery::None
  const :handle_use, TenseHandleUse, default: TenseHandleUse::None
  const :suspends, T::Boolean, default: false
  const :may_terminate_current_flow, T::Boolean, default: false
  const :refinement_type, T.nilable(Type), default: nil

  sig { returns(T::Boolean) }
  def consumes_handle?
    handle_use == TenseHandleUse::Consume
  end

  sig { returns(T::Boolean) }
  def recovery_operation?
    operation == TenseOperationKind::OrElseValue ||
      operation == TenseOperationKind::OrElseRaise ||
      operation == TenseOperationKind::OrElseExit ||
      operation == TenseOperationKind::OrElsePass ||
      operation == TenseOperationKind::OrElseBreak ||
      operation == TenseOperationKind::OrElsePrune
  end

  sig { returns(T::Boolean) }
  def owns_result?
    backend_form == TenseBackendForm::FutureMap
  end
end

class TenseJoinPlan < T::Struct
  extend T::Sig
  include AST::TensePlanValue

  const :result_type, T.nilable(Type), default: nil
  const :reason, T.nilable(Symbol), default: nil

  sig { returns(T::Boolean) }
  def success?
    !result_type.nil?
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

  NAVIGATION_MARKERS = T.let(
    TypeExpression::VALID_TENSE_ORDERS.reject(&:empty?).freeze,
    T::Array[String],
  )

  sig { params(type: Type).returns(TenseSelectorPlan) }
  def self.selector(type)
    TenseSelectorPlan.new(value_type: type, envelope: TenseEnvelope.from_type(type))
  end

  sig { params(type: Type).returns(TenseOperationPlan) }
  def self.try_value(type)
    envelope = TenseEnvelope.from_type(type)
    first = envelope.layers.first
    if first&.kind == TenseLayerKind::Fallible
      result = envelope.without_layer(0)
      preserve_value_metadata!(result, type)
      return operation_plan(
        TenseOperationKind::Try, type, result, TenseBackendForm::ZigTry,
        consumed: [T.must(first)], preserved: envelope.layers.drop(1),
        propagation: TensePropagation::Failure,
        may_terminate: true,
      )
    end
    if first&.kind == TenseLayerKind::Optional
      result = envelope.without_layer(0)
      preserve_value_metadata!(result, type)
      return operation_plan(
        TenseOperationKind::Try, type, result, TenseBackendForm::OptionalTry,
        consumed: [T.must(first)], preserved: envelope.layers.drop(1),
        propagation: TensePropagation::AbsenceAsFailure,
        may_terminate: true,
      )
    end

    raise ArgumentError, "TRY requires an outer fallible or optional layer, got #{envelope.order.inspect}"
  end

  sig { params(type: Type).returns(TenseOperationPlan) }
  def self.unwrap(type)
    envelope = TenseEnvelope.from_type(type)
    optional_index = envelope.layer_index(TenseLayerKind::Optional)
    if optional_index.nil? || envelope.layers.take(optional_index).any? { |layer| layer.kind == TenseLayerKind::Future }
      raise ArgumentError, "UNWRAP requires an immediately available optional layer, got #{envelope.order.inspect}"
    end
    index = optional_index
    consumed = T.must(envelope.layers[index])
    result = envelope.without_layer(index)
    result.merge_capabilities_from!(type, include_affine_ownership: true)
    result.copy_placement_from!(type)
    operation_plan(
      TenseOperationKind::Unwrap, type, result, TenseBackendForm::OptionalUnwrap,
      consumed: [consumed], preserved: envelope.layers.each_with_index.filter_map { |layer, i| layer unless i == index },
    )
  end

  sig { params(type: Type, shared: T::Boolean).returns(TenseOperationPlan) }
  def self.next_value(type, shared: false)
    envelope = TenseEnvelope.from_type(type)
    first = envelope.layers.first
    unless first&.kind == TenseLayerKind::Future
      raise ArgumentError, "NEXT requires an outer future layer, got #{envelope.order.inspect}"
    end
    result = envelope.without_layer(0)
    result.copy_placement_from!(type)
    backend = if type.observable? && envelope.payload_type.string?
      TenseBackendForm::ObservableStringNext
    elsif shared
      TenseBackendForm::SharedPromiseNext
    else
      TenseBackendForm::PromiseNext
    end
    operation_plan(
      TenseOperationKind::Next, type, result,
      backend,
      consumed: [T.must(first)], preserved: envelope.layers.drop(1),
      handle_use: shared ? TenseHandleUse::SharedRead : TenseHandleUse::Consume,
      suspends: true,
    )
  end

  sig { params(type: Type).returns(TenseOperationPlan) }
  def self.is_ok(type)
    envelope = TenseEnvelope.from_type(type)
    first = envelope.layers.first
    unless first&.kind == TenseLayerKind::Fallible
      raise ArgumentError, "IS_OK requires an outer fallible layer, got #{envelope.order.inspect}"
    end
    operation_plan(
      TenseOperationKind::IsOk, type, Type.new(:Bool), TenseBackendForm::FallibleTest,
      preserved: envelope.layers,
      refinement: envelope.without_layer(0),
    )
  end

  sig { params(type: Type).returns(TenseOperationPlan) }
  def self.exists(type)
    envelope = TenseEnvelope.from_type(type)
    optional_index = envelope.layer_index(TenseLayerKind::Optional)
    if optional_index.nil? || envelope.layers.take(optional_index).any? { |layer| layer.kind == TenseLayerKind::Future }
      raise ArgumentError, "EXISTS requires an immediately available optional layer, got #{envelope.order.inspect}"
    end
    operation_plan(
      TenseOperationKind::Exists, type, Type.new(:Bool), TenseBackendForm::OptionalTest,
      preserved: envelope.layers,
      refinement: envelope.without_layer(optional_index),
    )
  end

  sig { params(type: Type).returns(Type) }
  def self.navigation_payload(type)
    envelope = TenseEnvelope.from_type(type)
    payload = envelope.payload_type
    unless envelope.asynchronous?
      payload.merge_capabilities_from!(type, include_affine_ownership: true)
      payload.copy_placement_from!(type)
    end
    payload
  end

  sig do
    params(
      receiver_type: Type,
      mapped_type: Type,
      markers: String,
      shared: T::Boolean,
    ).returns(TenseOperationPlan)
  end
  def self.navigate(receiver_type, mapped_type, markers:, shared: false)
    receiver = TenseEnvelope.from_type(receiver_type)
    unless NAVIGATION_MARKERS.include?(markers) && receiver.order == markers
      raise ArgumentError,
        "navigation marker #{markers.inspect} must match receiver tense order #{receiver.order.inspect}"
    end
    if receiver_type.canonical_stream_result? || receiver_type.stream?
      raise ArgumentError, "navigation maps one future value; streams require SELECT"
    end

    mapped = TenseEnvelope.from_type(mapped_type)
    if receiver.asynchronous? && mapped.asynchronous?
      raise ArgumentError, "future navigation cannot implicitly create a nested future"
    end

    combined = normalize_navigation_layers(receiver.layers + mapped.layers)
    result = Type.new(TenseEnvelope.wrap_layers(mapped.payload_expression, combined))
    preserve_value_metadata!(result, mapped_type)
    operation_plan(
      TenseOperationKind::Navigate,
      receiver_type,
      result,
      receiver.asynchronous? ? TenseBackendForm::FutureMap : TenseBackendForm::DirectMap,
      preserved: combined,
      navigation: receiver.layers,
      handle_use: if receiver.asynchronous?
        shared ? TenseHandleUse::SharedRead : TenseHandleUse::Consume
      else
        TenseHandleUse::None
      end,
    )
  end

  sig do
    params(
      type: Type,
      fallback_type: Type,
      operation: TenseOperationKind,
      recovery: TenseRecovery,
    ).returns(TenseOperationPlan)
  end
  def self.or_else(type, fallback_type, operation: TenseOperationKind::OrElseValue, recovery: TenseRecovery::Fallback)
    envelope = TenseEnvelope.from_type(type)
    recoverable = envelope.layers.take_while { |layer| layer.kind != TenseLayerKind::Future }
    available = recoverable.select { |layer| layer.kind == TenseLayerKind::Fallible || layer.kind == TenseLayerKind::Optional }
    raise ArgumentError, "OR_ELSE requires a recoverable outer layer, got #{envelope.order.inspect}" if available.empty?

    handled = if recovery == TenseRecovery::Fallback
      available
    else
      available.select { |layer| layer.kind == TenseLayerKind::Fallible }
    end

    remaining = envelope.layers.drop(handled.length)
    result = Type.new(TenseEnvelope.wrap_layers(envelope.payload_expression, remaining))
    if recovery == TenseRecovery::Fallback && fallback_type.resolved != :NoReturn &&
       !result.accepts?(fallback_type) && !fallback_type.accepts?(result)
      raise ArgumentError, "OR_ELSE fallback #{fallback_type.resolved} does not match #{result.resolved}"
    end
    backend = available.any? { |layer| layer.kind == TenseLayerKind::Fallible } ?
      TenseBackendForm::ZigCatch : TenseBackendForm::ZigOptionalFallback
    operation_plan(
      operation, type, result, backend,
      consumed: handled, preserved: remaining,
      recovery: recovery,
      may_terminate: fallback_type.resolved == :NoReturn,
    )
  end

  sig { params(types: T::Array[Type]).returns(TenseJoinPlan) }
  def self.join_async_results(types)
    live_types = types.reject { |type| type.resolved == :Never }
    return TenseJoinPlan.new(reason: :empty) if live_types.empty?

    saw_nil = live_types.any? { |type| type.resolved == :NIL }
    envelopes = live_types.reject { |type| type.resolved == :NIL }.map { |type| TenseEnvelope.from_type(type) }
    return TenseJoinPlan.new(result_type: Type.new(:NIL)) if envelopes.empty?

    future_states = envelopes.map(&:asynchronous?).uniq
    return TenseJoinPlan.new(reason: :future_mismatch) if future_states.length > 1
    future = future_states.first == true
    return TenseJoinPlan.new(reason: :future_mismatch) if saw_nil && future

    payload_keys = envelopes.map { |envelope| envelope.payload_type.semantic_type_key }.uniq
    return TenseJoinPlan.new(reason: :payload_mismatch) if payload_keys.length > 1

    first = T.must(envelopes.first)
    payload = Type.copy_type(first.payload_type)
    layers = T.let([], T::Array[TenseLayer])
    if future
      future_layer = T.must(first.layers.find { |layer| layer.kind == TenseLayerKind::Future })
      layers << future_layer
    end
    if envelopes.any?(&:fallible?)
      fallible_layer = T.must(envelopes.flat_map(&:layers).find { |layer| layer.kind == TenseLayerKind::Fallible })
      layers << fallible_layer
    end
    if saw_nil || envelopes.any?(&:optional?)
      optional_layer = envelopes.flat_map(&:layers).find { |layer| layer.kind == TenseLayerKind::Optional }
      layers << (optional_layer || TenseLayer.new(kind: TenseLayerKind::Optional, capabilities: TypeCapabilities.new))
    end
    joined = Type.new(TenseEnvelope.wrap_layers(payload.shape.expression, layers))
    joined.merge_capabilities_from!(payload, include_affine_ownership: true)
    TenseJoinPlan.new(result_type: joined)
  end

  sig do
    params(
      operation: TenseOperationKind,
      input: Type,
      result: Type,
      backend: TenseBackendForm,
      consumed: T::Array[TenseLayer],
      preserved: T::Array[TenseLayer],
      navigation: T::Array[TenseLayer],
      propagation: TensePropagation,
      recovery: TenseRecovery,
      handle_use: TenseHandleUse,
      suspends: T::Boolean,
      may_terminate: T::Boolean,
      refinement: T.nilable(Type),
    ).returns(TenseOperationPlan)
  end
  def self.operation_plan(
    operation,
    input,
    result,
    backend,
    consumed: [],
    preserved: [],
    navigation: [],
    propagation: TensePropagation::None,
    recovery: TenseRecovery::None,
    handle_use: TenseHandleUse::None,
    suspends: false,
    may_terminate: false,
    refinement: nil
  )
    TenseOperationPlan.new(
      operation: operation,
      input_type: input,
      result_type: result,
      backend_form: backend,
      consumed_layers: consumed.freeze,
      preserved_layers: preserved.freeze,
      navigation_layers: navigation.freeze,
      propagation: propagation,
      recovery: recovery,
      handle_use: handle_use,
      suspends: suspends,
      may_terminate_current_flow: may_terminate,
      refinement_type: refinement,
    )
  end
  private_class_method :operation_plan

  sig { params(layers: T::Array[TenseLayer]).returns(T::Array[TenseLayer]) }
  def self.normalize_navigation_layers(layers)
    future_count = layers.count { |layer| layer.kind == TenseLayerKind::Future }
    raise ArgumentError, "navigation cannot contain more than one future boundary" if future_count > 1

    result = T.let([], T::Array[TenseLayer])
    segment = T.let([], T::Array[TenseLayer])
    layers.each do |layer|
      if layer.kind == TenseLayerKind::Future
        result.concat(normalize_immediate_navigation_segment(segment))
        result << layer
        segment = []
      else
        segment << layer
      end
    end
    result.concat(normalize_immediate_navigation_segment(segment))
    result.freeze
  end
  private_class_method :normalize_navigation_layers

  sig { params(layers: T::Array[TenseLayer]).returns(T::Array[TenseLayer]) }
  def self.normalize_immediate_navigation_segment(layers)
    fallible = layers.find { |layer| layer.kind == TenseLayerKind::Fallible }
    optional = layers.find { |layer| layer.kind == TenseLayerKind::Optional }
    [fallible, optional].compact
  end
  private_class_method :normalize_immediate_navigation_segment

  sig { params(result: Type, source: Type).void }
  def self.preserve_value_metadata!(result, source)
    result.merge_capabilities_from!(source, include_affine_ownership: true)
    result.copy_placement_from!(source)
  end
  private_class_method :preserve_value_metadata!
end
