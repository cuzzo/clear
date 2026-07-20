# frozen_string_literal: true

require "rspec"
require_relative "../ruby/mir/materialization"

RSpec.describe MIR::BindingMaterialization do
  it "does not invent ownership markers for lifecycle-trivial bindings" do
    plan = described_class.new(
      name: "value",
      expr: MIR::Lit.new("1"),
      alloc: :heap,
      type_info: Type.new(:Int64),
      mutable: false,
      ownership_tracked: false,
    )

    expect(plan.statements).to contain_exactly(an_instance_of(MIR::Let))
  end

  it "retains allocation markers when an ownership lifecycle is explicit" do
    plan = described_class.new(
      name: "value",
      expr: MIR::Lit.new("1"),
      alloc: :heap,
      type_info: Type.new(:String),
      mutable: false,
    )

    expect(plan.statements.first).to be_a(MIR::AllocMark)
  end
end
