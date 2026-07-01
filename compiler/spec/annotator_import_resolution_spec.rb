require "spec_helper"
require "set"

require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

RSpec.describe "annotator import resolution boundaries" do
  def tok(value = "require")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def param(name, type)
    AST::Param.new(
      name: name,
      type: Type.new(type),
      default: nil,
      mutable: false,
      takes: false,
      comptime: false,
      name_token: tok(name),
      required: true,
      sync: nil,
      symbol: SymbolEntry.new(reg: nil, type: Type.new(type), mutable: false, storage: :stack)
    )
  end

  def import_scope(source_scope, kind: :local, module_source_dir: Dir.pwd)
    source_dir = Dir.pwd
    mod = ModuleImporter::CompiledModule.new(
      AST::Program.new(tok, []),
      source_scope,
      "",
      module_source_dir,
      {},
      {},
      {},
      "",
      [],
      []
    )
    importer = ModuleImporter.new(base_dir: source_dir)
    importer.define_singleton_method(:compile_file) { |_path, caller_dir:| mod }
    importer.define_singleton_method(:compile_package) { |_path, caller_dir:| mod }

    annotator = SemanticAnnotator.new(importer: importer, source_dir: source_dir)
    annotator.send(:visit_RequireNode, AST::RequireNode.new(tok, "helper.cht", "helper", kind))
    annotator.send(:current_scope)
  end

  it "imports function signatures as isolated semantic copies" do
    source_scope = Scope.new
    source_sig = FunctionSignature.new(
      params: [param("value", :Int64)],
      return_type: Type.new(:Int64),
      return_lifetime: ["value"],
      visibility: :pub,
      type_params: [:T],
      reentrant: true,
      extern: true,
      extern_effects: { alloc: :heap },
      fn_type_params: [:U],
      owner_type: "Box",
      owner_type_params: [:T],
      intrinsic: true,
      needs_rt: true,
      can_fail: true,
      alloc_fault: true,
      error_fallible: true,
      effects: Set[:HEAP],
      requires: { "value" => Set[:LOCKED] },
      heap_carry_return: true,
      heap_carry_return_vars: Set["value"],
      return_def: FunctionReturn.infer(:infer_element_type),
      emit: IntrinsicEmit.new(zig: :native_box)
    )
    source_scope.declare("helper", nil, source_sig, false, false, nil, :static)

    imported_scope = import_scope(source_scope)
    imported_sig = FunctionSignature.unwrap(imported_scope.resolve_entry!("helper").type)

    expect(imported_sig).not_to equal(source_sig)
    expect(imported_sig&.module_alias).to eq("helper")
    expect(source_sig.module_alias).to be_nil
    expect(imported_sig&.params&.first).not_to equal(source_sig.params.first)
    expect(imported_sig&.params&.first&.symbol).to be_nil
    expect(imported_sig&.params&.first&.type).not_to equal(source_sig.params.first.type)
    expect(imported_sig&.return_type).not_to equal(source_sig.return_type)
    expect(imported_sig&.return_def&.kind).to eq(FunctionReturn::Kind::Infer)

    imported_sig&.extern_effects&.[]=(:alloc, :frame)
    imported_sig&.requires&.fetch("value")&.add(:ATOMIC)
    imported_sig&.effects&.add(:BLOCKING)
    imported_sig&.heap_carry_return_vars&.add("other")

    expect(source_sig.extern_effects).to eq({ alloc: :heap })
    expect(source_sig.requires.fetch("value")).to eq(Set[:LOCKED])
    expect(source_sig.effects).to eq(Set[:HEAP])
    expect(source_sig.heap_carry_return_vars).to eq(Set["value"])
  end

  it "imports type schemas as isolated semantic copies" do
    method_sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Int64),
      visibility: :pub,
      return_def: FunctionReturn.fixed(Type.new(:Int64))
    )
    resource_method_sig = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Int64),
      visibility: :pub,
      return_def: FunctionReturn.variant(:ValueList)
    )
    inline_variant = Schemas::InlineStructVariant.new(
      fields: { "left" => Type.new(:Int64), "right" => Type.new(:String) },
      deinit_entries: [Schemas::InlineStructDeinitEntry.indirect(field: "right", zig_type: "[]u8")]
    )
    struct_schema = Schemas::StructSchema.new(
      fields: { "value" => AST::StructField.new(type: Type.new(:Int64)) },
      type_params: [:T],
      methods: { "size" => method_sig },
      visibility: :pub
    )
    resource_schema = Schemas::ResourceSchema.new(
      close_plan: Schemas::ResourceClosePlan.method("close").for_field("inner"),
      static_methods: { "open" => { can_fail: true, alloc: :heap } },
      fields: { "handle" => AST::StructField.new(type: Type.new(:Int64)) },
      type_params: [:H],
      visibility: :pub,
      methods: { "read" => resource_method_sig }
    )
    union_schema = Schemas::UnionSchema.new(
      variants: { "None" => nil, "Count" => Type.new(:Int64), "Pair" => inline_variant },
      type_params: [:T],
      visibility: :pub
    )
    enum_schema = Schemas::EnumSchema.new(variants: ["Left", "Right"], visibility: :pub)
    source_scope = Scope.new
    source_scope.declare_type(:Box, struct_schema)
    source_scope.declare_type(:Handle, resource_schema)
    source_scope.declare_type(:Choice, union_schema)
    source_scope.declare_type(:Direction, enum_schema)

    imported_scope = import_scope(source_scope)
    imported_struct = imported_scope.resolve_type_entry(:Box)&.schema
    imported_resource = imported_scope.resolve_type_entry(:Handle)&.schema
    imported_union = imported_scope.resolve_type_entry(:Choice)&.schema
    imported_enum = imported_scope.resolve_type_entry(:Direction)&.schema

    expect(imported_struct).to be_a(Schemas::StructSchema)
    imported_struct = imported_struct
    expect(imported_struct).not_to equal(struct_schema)
    expect(imported_struct.fields.fetch("value")).not_to equal(struct_schema.fields.fetch("value"))
    expect(imported_struct.fields.fetch("value").type).not_to equal(struct_schema.fields.fetch("value").type)
    expect(imported_struct.methods.fetch("size")).not_to equal(method_sig)
    expect(imported_struct.methods.fetch("size").return_def.fixed).not_to equal(method_sig.return_def.fixed)

    expect(imported_resource).to be_a(Schemas::ResourceSchema)
    imported_resource = imported_resource
    expect(imported_resource).not_to equal(resource_schema)
    expect(imported_resource.close_plan).not_to equal(resource_schema.close_plan)
    expect(imported_resource.close_plan.actions.first).not_to equal(resource_schema.close_plan.actions.first)
    expect(imported_resource.close_plan.actions.first.field_path).not_to equal(resource_schema.close_plan.actions.first.field_path)
    expect(imported_resource.static_methods).not_to equal(resource_schema.static_methods)
    expect(imported_resource.methods.fetch("read")).not_to equal(resource_method_sig)
    expect(imported_resource.methods.fetch("read").return_def.kind).to eq(FunctionReturn::Kind::ValueList)

    expect(imported_union).to be_a(Schemas::UnionSchema)
    imported_union = imported_union
    expect(imported_union).not_to equal(union_schema)
    expect(imported_union.variants.fetch("Count")).not_to equal(union_schema.variants.fetch("Count"))
    imported_inline = imported_union.variants.fetch("Pair")
    expect(imported_inline).to be_a(Schemas::InlineStructVariant)
    imported_inline = imported_inline
    expect(imported_inline).not_to equal(inline_variant)
    expect(imported_inline.fields.fetch("left")).not_to equal(inline_variant.fields.fetch("left"))
    expect(imported_inline.deinit_entries).not_to equal(inline_variant.deinit_entries)

    expect(imported_enum).to be_a(Schemas::EnumSchema)
    expect(imported_enum).not_to equal(enum_schema)
    expect(imported_enum.variants).not_to equal(enum_schema.variants)

    imported_struct.fields.fetch("value").type = Type.new(:String)
    imported_resource.static_methods.fetch("open")[:alloc] = :frame

    expect(struct_schema.fields.fetch("value").type.resolved).to eq(:Int64)
    expect(resource_schema.static_methods.fetch("open").fetch(:alloc)).to eq(:heap)
  end

  it "skips non-importable bindings and supports package imports" do
    source_scope = Scope.new
    source_scope.declare("plain_value", nil, Type.new(:Int64), false, false, nil, :static)
    source_scope.declare(
      "already_imported",
      nil,
      FunctionSignature.new(params: [], return_type: Type.new(:Int64), visibility: :pub, module_alias: "other"),
      false,
      false,
      nil,
      :static
    )
    source_scope.declare(
      "private_helper",
      nil,
      FunctionSignature.new(params: [], return_type: Type.new(:Int64), visibility: :private),
      false,
      false,
      nil,
      :static
    )
    source_scope.declare(
      "package_helper",
      nil,
      FunctionSignature.new(params: [], return_type: Type.new(:Int64), visibility: :package),
      false,
      false,
      nil,
      :static
    )
    source_scope.declare("public_helper", nil, FunctionSignature.new(params: [], return_type: Type.new(:Int64), visibility: :pub), false, false, nil, :static)
    source_scope.declare("main", nil, FunctionSignature.new(params: [], return_type: Type.new(:Void), visibility: :pub), false, false, nil, :static)
    source_scope.declare_type(:PrivateBox, Schemas::StructSchema.new(fields: {}, visibility: :private))
    source_scope.declare_type(:PackageBox, Schemas::StructSchema.new(fields: {}, visibility: :package))
    source_scope.declare_type(:PublicBox, Schemas::StructSchema.new(fields: {}, visibility: :pub))

    imported_scope = import_scope(source_scope, kind: :package, module_source_dir: File.join(Dir.pwd, "pkg"))

    expect(imported_scope.resolve_entry("plain_value")).to be_nil
    expect(imported_scope.resolve_entry("already_imported")).to be_nil
    expect(imported_scope.resolve_entry("private_helper")).to be_nil
    expect(imported_scope.resolve_entry("package_helper")).to be_nil
    expect(imported_scope.resolve_entry("public_helper")).not_to be_nil
    expect(imported_scope.resolve_entry("main")).to be_nil
    expect(imported_scope.resolve_type_entry(:PrivateBox)).to be_nil
    expect(imported_scope.resolve_type_entry(:PackageBox)).to be_nil
    expect(imported_scope.resolve_type_entry(:PublicBox)).not_to be_nil
  end

  it "copies schemas with nil optional metadata" do
    source_scope = Scope.new
    source_scope.declare_type(:PlainBox, Schemas::StructSchema.new(fields: {}, visibility: :pub))
    source_scope.declare_type(
      :PlainResource,
      Schemas::ResourceSchema.new(
        close_plan: Schemas::ResourceClosePlan.method("close"),
        fields: {},
        visibility: :pub
      )
    )
    source_scope.declare_type(
      :PlainChoice,
      Schemas::UnionSchema.new(
        variants: {
          "Inline" => Schemas::InlineStructVariant.new(fields: { "value" => Type.new(:Int64) })
        },
        visibility: :pub
      )
    )

    imported_scope = import_scope(source_scope)
    imported_struct = imported_scope.resolve_type_entry(:PlainBox)&.schema
    imported_resource = imported_scope.resolve_type_entry(:PlainResource)&.schema
    imported_union = imported_scope.resolve_type_entry(:PlainChoice)&.schema

    expect(imported_struct).to be_a(Schemas::StructSchema)
    expect(imported_resource).to be_a(Schemas::ResourceSchema)
    expect(imported_union).to be_a(Schemas::UnionSchema)
    inline = imported_union&.variants&.fetch("Inline")
    expect(inline).to be_a(Schemas::InlineStructVariant)
    expect(inline&.deinit_entries).to eq([])
  end

  it "rejects REQUIRE when no importer is configured" do
    annotator = SemanticAnnotator.new

    expect {
      annotator.send(:visit_RequireNode, AST::RequireNode.new(tok, "helper.cht", "helper", :local))
    }.to raise_error(CompilerError, /REQUIRE/)
  end
end
