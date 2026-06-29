# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill generic narrowing" do
  def infer
    NilKill::Infer.allocate.tap { |instance| instance.instance_variable_set(:@store, NilKill::Store.new) }
  end

  xit "narrows hash key and value slots only when both are known" do
    instance = infer

    candidate = instance.send(:generic_candidate_type,
      "T::Hash[T.untyped, T.untyped]",
      [],
      [%w[Symbol], %w[String]])

    expect(candidate).to eq("T::Hash[Symbol, String]")
  end

  xit "does not narrow hash slots when one side is unknown" do
    instance = infer

    candidate = instance.send(:generic_candidate_type,
      "T::Hash[T.untyped, T.untyped]",
      [],
      [%w[Symbol], []])

    expect(candidate).to be_nil
  end

  it "uses T::Boolean for true/false element pairs" do
    expect(NilKill.conservative_element_type(%w[FalseClass TrueClass])).to eq("T::Boolean")
  end

  it "refuses multi-class scalar element unions by default" do
    expect(NilKill.conservative_element_type(%w[String Symbol])).to be_nil
  end

  it "cuts off scalar T.any candidates above the union limit" do
    isolated_env("NIL_KILL_UNION_POLICY" => "any") do
      expect(NilKill.sorbet_type(%w[Float Hash Integer String])).to eq("T.untyped")
    end
  end

  it "preserves nilability when narrowing a single observed element type" do
    expect(NilKill.conservative_element_type(%w[NilClass String])).to eq("T.nilable(String)")
  end

  xit "generalizes broad nested array shape unions at the unstable element slot" do
    instance = infer
    shapes = %w[Float Hash Integer String].map { |name| { "kind" => "class", "name" => name } }

    candidate = instance.send(:generic_candidate_type,
      "T::Array[T.untyped]",
      [],
      nil,
      [{ "kind" => "array", "elements" => shapes }])

    expect(candidate).to eq("T::Array[T::Array[T.untyped]]")
  end

  it "detects union candidates by total nested union complexity" do
    type = "T::Array[T.any(T::Hash[Symbol, T.any(String, Symbol)], T::Hash[Symbol, Integer])]"

    expect(NilKill.broad_union_type?(type)).to be(true)
  end

  xit "generalizes broad hash value unions from shape evidence" do
    instance = infer
    value_shapes = %w[Float Hash Integer String].map { |name| { "kind" => "class", "name" => name } }

    candidate = instance.send(:generic_candidate_type,
      "T::Hash[T.untyped, T.untyped]",
      [],
      nil,
      nil,
      [[{ "kind" => "class", "name" => "Symbol" }], value_shapes])

    expect(candidate).to eq("T::Hash[Symbol, T.untyped]")
  end

  xit "generalizes nested unions to the nearest stable container shape" do
    instance = infer
    hash_shapes = [
      {
        "kind" => "hash",
        "keys" => [{ "kind" => "class", "name" => "Symbol" }],
        "values" => [
          { "kind" => "class", "name" => "String" },
          { "kind" => "class", "name" => "Symbol" },
        ],
      },
      {
        "kind" => "hash",
        "keys" => [{ "kind" => "class", "name" => "Symbol" }],
        "values" => [{ "kind" => "class", "name" => "Integer" }],
      },
    ]

    candidate = instance.send(:generic_candidate_type,
      "T::Array[T.untyped]",
      [],
      nil,
      hash_shapes)

    expect(candidate).to eq("T::Array[T::Hash[Symbol, T.untyped]]")
  end
end
