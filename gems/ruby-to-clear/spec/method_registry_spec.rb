# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyToClear::MethodRegistry do
  around do |example|
    original_registry = described_class::REGISTRY.dup
    example.run
  ensure
    described_class::REGISTRY.clear
    described_class::REGISTRY.merge!(original_registry)
  end

  it "prefers receiver-kind handlers over generic method handlers" do
    described_class.register("size") do |receiver, _node, _transpiler|
      "#{receiver}.len()"
    end
    described_class.register("size", receiver: "string_literal") do |context|
      "#{context.receiver_code}.byteLen()"
    end

    expect(RubyToClear.transpile('"abc".size').strip).to eq('"abc".byteLen();')
    expect(RubyToClear.transpile("items = []; items.size").strip).to eq("MUTABLE items = [];\nitems.len();")
  end

  it "prefers receiver-name handlers over receiver-kind handlers" do
    described_class.register("read", receiver: "constant") do |context|
      "#{context.receiver_code}.genericRead()"
    end
    described_class.register("read", receiver: "File") do |context|
      "ClearFS.read(#{context.transpiler.visit(context.node.arguments)})"
    end

    expect(RubyToClear.transpile('File.read("path.txt")').strip).to eq('ClearFS.read("path.txt");')
  end
end
