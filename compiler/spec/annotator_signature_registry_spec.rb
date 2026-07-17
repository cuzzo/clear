require "spec_helper"

require_relative "../ruby/annotator/phases/signature_registry" unless defined?(Annotator::Phases::SignatureRegistry)
require_relative "../ruby/ast/lexer" unless defined?(Lexer)

RSpec.describe Annotator::Phases::SignatureRegistry do
  def tok(value = "x")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def param(name, type, default: nil, mutable: false, takes: false, comptime: false)
    AST::Param.new(
      name: name,
      type: type,
      default: default,
      mutable: mutable,
      takes: takes,
      comptime: comptime
    )
  end

  it "builds ordinary function signatures from declared function facts" do
    default_value = AST::Literal.new(tok("1"), :INT64, 1, :stack)
    fn = AST::FunctionDef.new(
      tok("sum"),
      "sum",
      [
        param("value", Type.new(:Int64), default: default_value, mutable: true, takes: true),
        param("cell", Type.new(:Int64, sync: :locked))
      ],
      [],
      Type.new(:Int64),
      nil,
      [],
      [],
      nil,
      :pub,
      [],
      false
    )
    fn.requires = { "cell" => Set[:LOCKED] }
    fn.effects_decl = :reentrant

    signature = described_class.function_signature(fn, return_lifetime: "value")

    expect(signature.return_type.resolved).to eq(:Int64)
    expect(signature.return_lifetime).to eq(["value"])
    expect(signature.visibility).to eq(:pub)
    expect(signature.reentrant).to eq(true)
    expect(signature.requires).to eq({ "cell" => Set[:LOCKED] })
    expect(signature.params.map(&:name)).to eq(["value", "cell"])
    expect(signature.params.first.required).to eq(false)
    expect(signature.params.first.default).to eq(default_value)
    expect(signature.params.first.mutable).to eq(true)
    expect(signature.params.first.takes).to eq(true)
    expect(signature.params.last.sync).to eq(:locked)
  end

  it "builds extern signatures for free functions and generic methods" do
    node = AST::ExternFnDecl.new(
      tok("parse"),
      "parse",
      [param("raw", Type.new(:String), mutable: nil, comptime: true)],
      Type.new(:Bool),
      "native",
      { alloc: :heap }
    )
    node.fn_type_params = [:T]
    node.owner_type = "ClearParser"
    node.owner_type_params = [:T]

    signature = described_class.extern_function_signature(node)

    expect(signature.extern).to eq(true)
    expect(signature.module_alias).to eq("native")
    expect(signature.extern_effects).to eq({ alloc: :heap })
    expect(signature.fn_type_params).to eq([:T])
    expect(signature.type_params).to eq([:T])
    expect(signature.owner_type).to eq("ClearParser")
    expect(signature.owner_type_params).to eq([:T])
    expect(signature.params.first.mutable).to eq(false)
    expect(signature.params.first.comptime).to eq(true)
  end

  it "keeps extern type params empty when no generic params are declared" do
    node = AST::ExternFnDecl.new(tok("puts"), "puts", [], Type.new(:Void), "c", nil)

    signature = described_class.extern_function_signature(node)

    expect(signature.fn_type_params).to eq([])
    expect(signature.type_params).to eq([])
    expect(signature.extern_effects).to eq({})
    expect(signature.owner_type_params).to eq([])
  end

  it "normalizes function signature boundary metadata to typed defaults" do
    fn = AST::FunctionDef.new(
      tok("generic"),
      "generic",
      [],
      [],
      Type.new(:Void),
      nil,
      [],
      [],
      nil,
      :pub,
      [],
      false
    )
    fn.type_params = ["T"]

    signature = FunctionSignature.from_function_def(fn)
    expect(signature.type_params).to eq([:T])
    expect(signature.requires).to eq({})
    expect(signature.extern_effects).to eq({})

    with_requires = FunctionSignature.new(
      params: signature.params,
      return_type: signature.return_type,
      type_params: signature.type_params,
      requires: { "x" => Set[:LOCKED] }
    )
    expect(with_requires.requires.fetch("x")).to include(:LOCKED)
    without_requires = FunctionSignature.new(
      params: signature.params,
      return_type: signature.return_type,
      type_params: signature.type_params
    )
    expect(without_requires.requires).to eq({})

    copy_source = FunctionSignature.new(
      params: signature.params,
      return_type: signature.return_type,
      type_params: signature.type_params,
      effects: Set[:BLOCKING],
      heap_carry_return: true,
      heap_carry_return_vars: Set["value"]
    )

    copy = copy_source.dup
    expect(copy.effects).to eq(Set[:BLOCKING])
    expect(copy.heap_carry_return).to eq(true)
    expect(copy.heap_carry_return_vars).to eq(Set["value"])
  end
end
