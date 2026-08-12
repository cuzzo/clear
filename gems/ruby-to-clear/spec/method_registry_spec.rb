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
    expect(RubyToClear.transpile("items = get_items; items.size").strip).to eq("MUTABLE items = get_items();\nitems.len();")
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

  describe ".parenthesize_bare_expression_if" do
    it "wraps a bare expression-IF in parens" do
      code = "IF x > 5 THEN\n  1\nELSE\n  2\nEND"
      expect(described_class.send(:parenthesize_bare_expression_if, code)).to eq("(#{code})")
    end

    it "wraps a bare COMPTIME IF in parens" do
      code = "COMPTIME IF T IS_A Int64 THEN\n  1\nELSE\n  2\nEND"
      expect(described_class.send(:parenthesize_bare_expression_if, code)).to eq("(#{code})")
    end

    it "leaves non-IF code unchanged" do
      expect(described_class.send(:parenthesize_bare_expression_if, "x + 1")).to eq("x + 1")
      expect(described_class.send(:parenthesize_bare_expression_if, "foo(bar)")).to eq("foo(bar)")
      expect(described_class.send(:parenthesize_bare_expression_if, "{ MUTABLE x = 1; x }")).to eq("{ MUTABLE x = 1; x }")
    end

    it "leaves an already-parenthesized IF unchanged in shape (double-wraps, harmlessly)" do
      code = "(IF x > 5 THEN\n  1\nELSE\n  2\nEND)"
      # Does not start with "IF "/"COMPTIME IF " (starts with "("), so the
      # guard correctly declines - no double-parenthesization in practice,
      # since callers only ever pass the raw if_expression_code output.
      expect(described_class.send(:parenthesize_bare_expression_if, code)).to eq(code)
    end
  end
end
