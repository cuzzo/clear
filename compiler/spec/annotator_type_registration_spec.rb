require "spec_helper"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/declaration_index" unless defined?(Annotator::Phases::DeclarationIndexer)
require_relative "../ruby/annotator/phases/type_registration" unless defined?(Annotator::Phases::TypeRegistration)
require_relative "../ruby/ast/lexer" unless defined?(Lexer)

RSpec.describe Annotator::Phases::TypeRegistration do
  def tok(value = "x")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def register(*nodes)
    annotator = SemanticAnnotator.new
    program = AST::Program.new(tok("program"), nodes)
    index = Annotator::Phases::DeclarationIndexer.index(program)
    annotator.register_type_declarations(index)
    [annotator, program]
  end

  it "registers struct, enum, extern struct, and extern resource schemas" do
    default = AST::Literal.new(tok("1"), :INT64, 1, :stack)
    struct = AST::StructDef.new(
      tok("Box"),
      "Box",
      { "value" => AST::StructField.new(type: Type.new(:Int64), default: default) },
      :pub,
      ["T"]
    )
    enum = AST::EnumDef.new(tok("Mode"), "Mode", ["On", "Off"], :private)
    native = AST::ExternStructDecl.new(tok("Native"), "Native", { "id" => AST::StructField.new(type: Type.new(:Int64)) }, "native")
    native.type_params = ["T"]
    native.as_type = "Native(T)"
    resource = AST::ExternStructDecl.new(tok("Handle"), "Handle", {}, "native")
    resource.close_method = "close"

    annotator, = register(struct, enum, native, resource)
    scope = annotator.send(:current_scope)

    box_schema = scope.types.fetch(:Box).schema
    expect(box_schema).to be_a(Schemas::StructSchema)
    expect(box_schema.fields.fetch("value").default.full_type!.resolved).to eq(:Int64)
    expect(box_schema.type_params).to eq([:T])
    expect(box_schema.visibility).to eq(:pub)
    expect(struct.full_type!.resolved).to eq(:Void)

    mode_schema = scope.types.fetch(:Mode).schema
    expect(mode_schema).to be_a(Schemas::EnumSchema)
    expect(mode_schema.variants).to eq(Set["On", "Off"])
    expect(mode_schema.visibility).to eq(:private)
    expect(enum.full_type!.resolved).to eq(:Void)

    native_schema = scope.types.fetch(:Native).schema
    expect(native_schema).to be_a(Schemas::StructSchema)
    expect(native_schema.type_params).to eq([:T])
    expect(native_schema.extern_module).to eq("native")
    expect(native_schema.as_type).to eq("Native(T)")
    expect(native.full_type!.resolved).to eq(:Void)

    resource_schema = scope.types.fetch(:Handle).schema
    expect(resource_schema).to be_a(Schemas::ResourceSchema)
    expect(resource_schema.close_plan.actions.map(&:name)).to eq(["close"])
    expect(resource.full_type!.resolved).to eq(:Void)
  end

  it "rejects duplicate type declarations" do
    first = AST::StructDef.new(tok("Box"), "Box", {}, :pub, [])
    second = AST::StructDef.new(tok("Box"), "Box", {}, :pub, [])

    expect {
      register(first, second)
    }.to raise_error(CompilerError, /Duplicate type declaration 'Box'/)
  end

  it "rejects inline union helper struct name collisions" do
    helper = AST::StructDef.new(tok("Value_Data"), "Value_Data", {}, :pub, [])
    inline = Schemas::InlineStructVariant.new(fields: { "owned" => Type.new(:String) })
    union = AST::UnionDef.new(tok("Value"), "Value", { Data: inline }, :package)

    expect {
      register(helper, union)
    }.to raise_error(CompilerError, /Duplicate type declaration 'Value_Data'/)
  end

  it "registers union schemas, helper structs, and typed inline deinit entries" do
    inline = Schemas::InlineStructVariant.new(fields: {
      "owned" => Type.new(:String),
      "items" => Type.new(:"Int64[]"),
      "linked" => Type.new(:Node, layout: :indirect),
      "plain" => Type.new(:Int64),
    })
    union = AST::UnionDef.new(tok("Value"), "Value", { Data: inline, Empty: nil }, :package)

    annotator, = register(union)
    scope = annotator.send(:current_scope)

    union_schema = scope.types.fetch(:Value).schema
    expect(union_schema).to be_a(Schemas::UnionSchema)
    expect(union_schema.variants.fetch(:Data)).to eq(inline)
    expect(scope.types.fetch(:Value_Data).schema).to be_a(Schemas::StructSchema)
    expect(union.full_type!.resolved).to eq(:Void)

    entries = inline.deinit_entries
    expect(entries.map(&:field)).to contain_exactly("owned", "items", "linked")
    expect(entries.map(&:kind)).to contain_exactly(:uniform, :array, :indirect)
    expect(entries).to all(be_a(Schemas::InlineStructDeinitEntry))
    expect(entries.find { |entry| entry.field == "plain" }).to be_nil
  end

  it "rejects generic unions with inline struct variants" do
    inline = Schemas::InlineStructVariant.new(fields: { "value" => Type.new(:Int64) })
    union = AST::UnionDef.new(tok("Boxed"), "Boxed", { Value: inline }, :pub)
    union.type_params = ["T"]

    expect {
      register(union)
    }.to raise_error(CompilerError, /Inline struct variants are not supported in generic unions/)
  end
end
