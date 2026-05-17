# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::TracePlan do
  def plan_entry(method)
    tp = described_class.allocate
    tp.instance_variable_set(:@methods, {})
    tp.send(:add_method, method)
    tp.instance_variable_get(:@methods).values.first
  end

  # The dangerous regression this whole investigation chased: if
  # TracePlan ever prunes a method that HAS a typeable (untyped
  # positional) slot, that method silently gets no runtime record and
  # inflates NoEvidence with a method that actually ran. Guard it.
  it "samples a method whose positional param is T.untyped (must not be pruned)" do
    e = plan_entry(
      "class" => "C", "method" => "run", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      "sig" => "sig { params(x: T.untyped).returns(String) }",
      "params" => [{ "name" => "x", "type" => "T.untyped" }]
    )
    expect(e["sample"]).to be(true)
  end

  it "samples a method whose return is T.untyped even if params are typed" do
    e = plan_entry(
      "class" => "C", "method" => "calc", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      "sig" => "sig { params(x: Integer).returns(T.untyped) }",
      "params" => [{ "name" => "x", "type" => "Integer" }]
    )
    expect(e["sample"]).to be(true)
  end

  it "prunes a method that is fully typed (nothing to learn) -- expected, not a bug" do
    e = plan_entry(
      "class" => "C", "method" => "typed", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      "sig" => "sig { params(x: Integer).returns(String) }",
      "params" => [{ "name" => "x", "type" => "Integer" }]
    )
    expect(e["sample"]).to be(false)
  end

  it "prunes a method whose ONLY untyped slot is a block param (block is ~always Proc; acceptable). The report must label such a slot arg_untraced, not never_run." do
    e = plan_entry(
      "class" => "C", "method" => "suffix", "kind" => "instance", "line" => 1,
      "path" => "src/c.rb",
      # SourceIndex omits the block param from `params`, so only the
      # typed positionals are seen -> sample=false (pruned, no record).
      "sig" => "sig { params(type: Symbol, value: String, block: T.untyped).returns(Prism::Token) }",
      "params" => [{ "name" => "type", "type" => "Symbol" }, { "name" => "value", "type" => "String" }]
    )
    expect(e["sample"]).to be(false)
  end
end
