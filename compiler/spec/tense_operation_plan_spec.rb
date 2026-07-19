# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/semantic/tense_operation_plan"
require_relative "../../tools/fuzz/select_tense_semantics"

RSpec.describe TenseOperationPlanner do
  def expression_for(order, payload = NamedTypeExpression.new(name: :Int64))
    order.reverse.each_char.reduce(payload) do |inner, marker|
      case marker
      when "!" then FallibleTypeExpression.new(inner: inner)
      when "~" then FutureTypeExpression.new(inner: inner)
      when "?" then OptionalTypeExpression.new(inner: inner)
      else raise "unknown test marker #{marker}"
      end
    end
  end

  it "extracts and reconstructs every independently specified SELECT order" do
    SelectTenseSemantics::VALID_ORDERS.each do |order|
      expression = expression_for(order)
      envelope = TenseEnvelope.from_expression(expression)

      expect(envelope.order).to eq(order)
      expect(envelope.valid?).to be(true)
      expect(TypeExpressionPrinter.semantic(envelope.wrap(envelope.payload_expression))).to(
        eq(TypeExpressionPrinter.semantic(expression)),
      )
      expect(envelope.payload_type.resolved).to eq(:Int64)
    end
  end

  it "rejects every independently specified invalid order" do
    SelectTenseSemantics::INVALID_ORDERS.each do |order|
      expect { TenseEnvelope.from_expression(expression_for(order)) }.to(
        raise_error(ArgumentError, /unsupported tense order/),
      )
    end
    expect { TenseEnvelope.from_expression(expression_for("!!")) }.to(
      raise_error(ArgumentError, /unsupported tense order/),
    )
  end

  it "classifies selector effects without flattening temporal order" do
    {
      "" => [nil, false, false],
      "?" => [:optional, false, false],
      "!" => [:fallible, false, true],
      "!?" => [:fallible_optional, false, true],
      "~" => [nil, true, false],
      "~!?" => [:fallible_optional, true, true],
      "!~" => [:fallible, true, true],
      "!~!?" => [:fallible_optional, true, true],
    }.each do |order, (mode, asynchronous, fallible)|
      plan = described_class.selector(Type.new(expression_for(order)))
      expect(plan.required_order).to eq(order)
      expect(plan.required_mode).to eq(mode)
      expect(plan.asynchronous?).to be(asynchronous)
      expect(plan.fallible?).to be(fallible)
      expect(plan.leaf_type.resolved).to eq(:Int64)
      expect(plan.value_type.semantic_type_key).to eq(Type.new(expression_for(order)).semantic_type_key)
    end
  end

  it "turns the future boundary into a stream while retaining layers on both sides" do
    {
      "" => "[~]Int64",
      "!?" => "[~]!?Int64",
      "~!?" => "[~]!?Int64",
      "!~" => "![~]Int64",
      "!~!?" => "![~]!?Int64",
    }.each do |order, expected|
      plan = described_class.selector(Type.new(expression_for(order)))
      actual = TypeExpressionPrinter.inline(plan.stream_result_type(:FINITE).shape.expression)
      expect(actual).to eq(expected)
    end
  end

  it "preserves capabilities and fallible error sets while rebuilding layers" do
    future_capabilities = TypeCapabilities.new(ownership: :shared, ownership_set: true)
    optional_capabilities = TypeCapabilities.new(sync: :locked)
    error_set = NamedTypeExpression.new(name: :Failure)
    expression = FutureTypeExpression.new(
      capabilities: future_capabilities,
      inner: FallibleTypeExpression.new(
        error_set: error_set,
        inner: OptionalTypeExpression.new(
          capabilities: optional_capabilities,
          inner: NamedTypeExpression.new(name: :Value),
        ),
      ),
    )

    rebuilt = TenseEnvelope.from_type(Type.new(expression)).wrap(NamedTypeExpression.new(name: :Other))
    expect(rebuilt).to be_a(FutureTypeExpression)
    future = rebuilt
    expect(future.capabilities).to equal(future_capabilities)
    expect(future.inner).to be_a(FallibleTypeExpression)
    fallible = future.inner
    expect(fallible.error_set).to equal(error_set)
    expect(fallible.inner).to be_a(OptionalTypeExpression)
    expect(fallible.inner.capabilities).to equal(optional_capabilities)
  end
end
