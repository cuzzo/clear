# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill generic narrowing" do
  def infer
    NilKill::Infer.allocate.tap { |instance| instance.instance_variable_set(:@store, NilKill::Store.new) }
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

    it "detects union candidates by total nested union complexity" do
    type = "T::Array[T.any(T::Hash[Symbol, T.any(String, Symbol)], T::Hash[Symbol, Integer])]"

    expect(NilKill.broad_union_type?(type)).to be(true)
  end

    end
