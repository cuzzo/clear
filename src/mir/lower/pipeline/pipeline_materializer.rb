# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../cleanup_entry"
require_relative "../../lowering/schema_registry"
require_relative "../../mir"
require_relative "../../placement"

class PipelineMaterializer
  extend T::Sig

  class ItemKind < T::Enum
    enums do
      ShardedPool = new("sharded_pool")
      SoaPool = new("soa_pool")
      Pool = new("pool")
      SoaList = new("soa_list")
      ShardedList = new("sharded_list")
      Set = new("set")
      Default = new("default")
    end
  end

  class AllocationFact < T::Struct
    const :alloc, Symbol
    const :mark, MIR::AllocMark
  end

  class ItemSetup < T::Struct
    const :statements, T::Array[MIR::Emittable]
    const :items_ident, String
  end

  class BufferSetup < T::Struct
    const :var_decl, MIR::Let
    const :defer_stmt, MIR::DeferStmt
  end

  module Host
    extend T::Sig
    extend T::Helpers

    interface!

    sig { abstract.params(node: AST::Node).returns(MIR::Node) }
    def materializer_visit_mir(node); end

    sig do
      abstract
        .params(
          value: MIR::Node,
          name: String,
          fallback_alloc: Symbol,
          type_info: T.nilable(Type),
          ast_node: T.nilable(AST::Node),
          context: String,
          known_allocating: T::Boolean,
        )
        .returns(T.nilable(PipelineMaterializer::AllocationFact))
    end
    def materializer_alloc_mark_fact(value, name, fallback_alloc:, type_info: nil,
                                     ast_node: nil, context: "pipeline allocation",
                                     known_allocating: false); end

    sig { abstract.returns(Symbol) }
    def materializer_result_alloc; end

    sig { abstract.returns(T::Boolean) }
    def materializer_bc_target?; end

    sig { abstract.returns(MIRLoweringSchemas::SchemaLookup) }
    def materializer_schema_lookup; end

    sig { abstract.returns(String) }
    def materializer_next_label; end

    sig { abstract.params(label: String).void }
    def materializer_set_current_label(label); end

    sig { abstract.returns(String) }
    def materializer_next_item_temp_name; end
  end

  AllocationFactResolver = T.type_alias do
    T.proc.params(
      value: MIR::Node,
      name: String,
      fallback_alloc: Symbol,
      type_info: T.nilable(Type),
      ast_node: T.nilable(AST::Node),
      context: String,
      known_allocating: T::Boolean,
    ).returns(T.nilable(PipelineMaterializer::AllocationFact))
  end

  class RuntimeHost
    extend T::Sig

    include PipelineMaterializer::Host

    sig do
      params(
        visit_mir: T.proc.params(node: AST::Node).returns(MIR::Node),
        alloc_mark_fact: PipelineMaterializer::AllocationFactResolver,
        result_alloc: T.proc.returns(Symbol),
        bc_target: T.proc.returns(T::Boolean),
        schema_lookup: T.proc.returns(MIRLoweringSchemas::SchemaLookup),
        next_label: T.proc.returns(String),
        set_current_label: T.proc.params(label: String).void,
        next_item_temp_name: T.proc.returns(String),
      ).void
    end
    def initialize(visit_mir:, alloc_mark_fact:, result_alloc:, bc_target:,
                   schema_lookup:, next_label:, set_current_label:,
                   next_item_temp_name:)
      @visit_mir = T.let(visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node))
      @alloc_mark_fact = T.let(alloc_mark_fact, PipelineMaterializer::AllocationFactResolver)
      @result_alloc = T.let(result_alloc, T.proc.returns(Symbol))
      @bc_target = T.let(bc_target, T.proc.returns(T::Boolean))
      @schema_lookup = T.let(schema_lookup, T.proc.returns(MIRLoweringSchemas::SchemaLookup))
      @next_label = T.let(next_label, T.proc.returns(String))
      @set_current_label = T.let(set_current_label, T.proc.params(label: String).void)
      @next_item_temp_name = T.let(next_item_temp_name, T.proc.returns(String))
    end

    sig { override.params(node: AST::Node).returns(MIR::Node) }
    def materializer_visit_mir(node)
      @visit_mir.call(node)
    end

    sig do
      override
        .params(
          value: MIR::Node,
          name: String,
          fallback_alloc: Symbol,
          type_info: T.nilable(Type),
          ast_node: T.nilable(AST::Node),
          context: String,
          known_allocating: T::Boolean,
        )
        .returns(T.nilable(PipelineMaterializer::AllocationFact))
    end
    def materializer_alloc_mark_fact(value, name, fallback_alloc:, type_info: nil,
                                     ast_node: nil, context: "pipeline allocation",
                                     known_allocating: false)
      @alloc_mark_fact.call(value, name, fallback_alloc, type_info, ast_node, context, known_allocating)
    end

    sig { override.returns(Symbol) }
    def materializer_result_alloc
      @result_alloc.call
    end

    sig { override.returns(T::Boolean) }
    def materializer_bc_target?
      @bc_target.call
    end

    sig { override.returns(MIRLoweringSchemas::SchemaLookup) }
    def materializer_schema_lookup
      @schema_lookup.call
    end

    sig { override.returns(String) }
    def materializer_next_label
      @next_label.call
    end

    sig { override.params(label: String).void }
    def materializer_set_current_label(label)
      @set_current_label.call(label)
    end

    sig { override.returns(String) }
    def materializer_next_item_temp_name
      @next_item_temp_name.call
    end
  end

  sig { params(host: PipelineMaterializer::Host).void }
  def initialize(host:)
    @host = T.let(host, PipelineMaterializer::Host)
  end

  sig { returns(Symbol) }
  def result_alloc
    @host.materializer_result_alloc
  end

  sig { returns(MIRLoweringSchemas::SchemaLookup) }
  def schema_lookup
    @host.materializer_schema_lookup
  end

  sig { params(list_node: AST::Node, blk: T.proc.params(items_ident: String, label: String).returns(T::Array[MIR::Emittable])).returns(MIR::BlockExpr) }
  def pipeline_block(list_node, &blk)
    label = @host.materializer_next_label
    source_mir = @host.materializer_visit_mir(list_node)
    source_prefix = T.let([], T::Array[MIR::Emittable])
    source_cleanup = T.let(nil, T.nilable(MIR::Cleanup))
    forced_alloc = inline_source_alloc(source_mir)

    fact = @host.materializer_alloc_mark_fact(
      source_mir,
      "pipe_src_list",
      fallback_alloc: forced_alloc || :heap,
      type_info: list_node.full_type!,
      known_allocating: !forced_alloc.nil?,
    )
    if fact
      source_prefix << fact.mark
      source_cleanup = MIR::Cleanup.new(
        "pipe_src_list",
        CleanupEntry.build(:uniform,
          alloc: fact.alloc,
          has_moved_guard: false,
          zig_type: list_node.full_type!.zig_type),
      )
    end
    @host.materializer_set_current_label(label)

    item_setup = items_setup(list_node.full_type!)
    body_stmts = blk.call(item_setup.items_ident, label)

    MIR::BlockExpr.new(label, [
      *source_prefix,
      MIR::Let.new("pipe_src_list", source_mir, false, nil, nil),
      source_cleanup,
      *item_setup.statements,
      *body_stmts,
    ].compact)
  end

  sig { params(lhs_type: Type).returns(PipelineMaterializer::ItemSetup) }
  def items_setup(lhs_type)
    setup = item_setup_stmts(item_kind(lhs_type), lhs_type)

    ItemSetup.new(statements: setup, items_ident: "pipe_items")
  end

  sig { params(lhs_type: Type).returns(PipelineMaterializer::ItemKind) }
  def item_kind(lhs_type)
    bc = bc_target?
    return ItemKind::ShardedPool if lhs_type.pool? && lhs_type.sharded?
    return ItemKind::SoaPool if !bc && lhs_type.pool? && lhs_type.soa?
    return ItemKind::Pool if !bc && lhs_type.pool?
    return ItemKind::SoaList if !bc && lhs_type.soa_list_materialization?
    return ItemKind::ShardedList if !bc && lhs_type.list_collection? && lhs_type.sharded?
    return ItemKind::Set if lhs_type.set_collection?

    ItemKind::Default
  end

  sig { params(kind: PipelineMaterializer::ItemKind, lhs_type: Type).returns(T::Array[MIR::Emittable]) }
  def item_setup_stmts(kind, lhs_type)
    case kind
    when ItemKind::ShardedPool
      build_sharded_pool(lhs_type)
    when ItemKind::SoaPool
      build_soa_pool(lhs_type)
    when ItemKind::Pool
      build_pool(lhs_type)
    when ItemKind::SoaList
      build_soa_list(lhs_type)
    when ItemKind::ShardedList
      build_sharded_list(lhs_type)
    when ItemKind::Set
      build_set(lhs_type)
    when ItemKind::Default
      [MIR::Let.new("pipe_items", MIR::ItemsAccess.new(MIR::Ident.new("pipe_src_list"), true), false, nil, nil)]
    end
  end

  sig { params(value: MIR::Node, type_info: Type, alloc: Symbol).returns(MIR::Node) }
  def borrowed_pipeline_value(value, type_info, alloc)
    return value unless type_info.recursive_cleanup_shape?(schema_lookup) || type_info.heap_ptr?

    MIR::DeepCopy.new(value, type_info.zig_type, nil, :full_value, alloc)
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def cleanup_bearing_type?(type_info)
    type_info.recursive_cleanup_shape?(schema_lookup)
  end

  sig { params(name: String, source: MIR::Node, type_info: Type, zig_type: String, alloc: Symbol).returns(T::Array[MIR::Emittable]) }
  def owning_pipeline_temp_stmts(name, source, type_info, zig_type, alloc)
    mark = MIR::AllocMark.new(name, alloc, type_info, MIR::Placement.heap?(alloc) ? :heap : :function)
    entry = CleanupEntry.build(:uniform, alloc: alloc, has_moved_guard: true, zig_type: zig_type)
    [
      mark,
      MIR::Let.new(name, MIR::DeepCopy.new(source, zig_type, nil, :full_value, alloc), false, Type.new(zig_type), nil),
      MIR::ErrCleanup.new(name, entry),
    ]
  end

  sig { params(receiver: String, alloc: Symbol, value_expr: MIR::Node).returns(MIR::Emittable) }
  def append_owned_value_stmt(receiver, alloc, value_expr)
    fact = @host.materializer_alloc_mark_fact(
      value_expr,
      @host.materializer_next_item_temp_name,
      fallback_alloc: alloc,
      ast_node: nil,
      context: "pipeline owned append item",
    )
    if fact
      temp_name = fact.mark.name.to_s
      entry = CleanupEntry.build(:uniform,
        alloc: fact.alloc,
        has_moved_guard: true,
        zig_type: zig_type_for(value_expr))
      return MIR::ScopeBlock.new([
        fact.mark,
        MIR::Let.new(temp_name, value_expr, false, nil, nil),
        MIR::ErrCleanup.new(temp_name, entry),
        MIR::ExprStmt.new(
          MIR::MethodCall.new(MIR::Ident.new(receiver), "append",
            [MIR::AllocatorRef.new(alloc), MIR::Ident.new(temp_name)], true,
            MIR::CallableContract.no_ownership(2)), false),
        *MIR::OwnershipTransferPlan.new(
          name: temp_name,
          target: :owned_sink,
          target_alloc: alloc,
          move_guarded: true,
        ).marks,
      ])
    end

    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new(receiver), "append",
        [MIR::AllocatorRef.new(alloc), value_expr], true, MIR::CallableContract.no_ownership(2)), false)
  end

  sig { params(lhs: AST::Node).returns(T::Array[MIR::Emittable]) }
  def concurrent_source_setup(lhs)
    return range_concurrent_source_setup(lhs) if lhs.is_a?(AST::RangeLit)

    lhs_type = lhs.full_type!
    source_mir = @host.materializer_visit_mir(lhs)
    source_prefix = T.let([], T::Array[MIR::Emittable])
    source_cleanup = T.let(nil, T.nilable(MIR::Cleanup))
    fact = @host.materializer_alloc_mark_fact(source_mir, "pipe_src_list",
      fallback_alloc: :heap,
      type_info: lhs.full_type!)
    if fact
      source_prefix << fact.mark
      source_cleanup = MIR::Cleanup.new("pipe_src_list",
        CleanupEntry.build(:uniform, alloc: fact.alloc, has_moved_guard: false, zig_type: lhs_type.zig_type))
    end
    item_setup = items_setup(lhs_type)
    [
      *source_prefix,
      MIR::Let.new("pipe_src_list", source_mir, !source_cleanup.nil?, nil, "_ = &pipe_src_list;"),
      source_cleanup,
      *item_setup.statements,
    ].compact
  end

  private

  sig { params(source_mir: MIR::Node).returns(T.nilable(Symbol)) }
  def inline_source_alloc(source_mir)
    effect = MIR::OwnershipEffect.of(source_mir)
    return effect.alloc if effect.produces_owned && effect.alloc

    metadata = source_mir.respond_to?(:allocs) ? T.unsafe(source_mir).allocs : nil
    return nil unless metadata.is_a?(MIR::InlineAllocMetadata) && !metadata.empty?

    metadata.any_heap? ? :heap : :frame
  end

  sig { returns(T::Boolean) }
  def bc_target?
    @host.materializer_bc_target?
  end

  sig { params(value_expr: MIR::Node).returns(String) }
  def zig_type_for(value_expr)
    zig_type = case value_expr
    when MIR::DeepCopy, MIR::ContainerInit, MIR::StructInit, MIR::TypeSentinel,
         MIR::Undef, MIR::HeapCreate, MIR::DiscardOwned, MIR::UnionVariantGet
      value_expr.zig_type
    end
    normalized_zig_type(zig_type)
  end

  sig { params(zig_type: T.nilable(String)).returns(String) }
  def normalized_zig_type(zig_type)
    return "void" if zig_type.nil? || zig_type.empty?

    zig_type
  end

  sig { params(elem_zig: String).returns(PipelineMaterializer::BufferSetup) }
  def var_and_defer(elem_zig)
    var_decl = MIR::Let.new("pipe_mat",
      MIR::ContainerInit.new("std.ArrayListUnmanaged(#{elem_zig})",
        :list_empty, result_alloc, nil),
      true, nil, nil)
    defer = MIR::DeferStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "deinit",
        [MIR::AllocatorRef.new(result_alloc)], false, MIR::CallableContract.no_ownership(1)))
    BufferSetup.new(var_decl: var_decl, defer_stmt: defer)
  end

  sig { returns(MIR::Let) }
  def items_let
    MIR::Let.new("pipe_items", MIR::FieldGet.new(MIR::Ident.new("pipe_mat"), "items"), false, nil, nil)
  end

  sig { params(value_expr: MIR::Node).returns(MIR::Emittable) }
  def append(value_expr)
    append_owned_value_stmt("pipe_mat", result_alloc, value_expr)
  end

  sig { params(slice_expr: MIR::FieldGet).returns(MIR::ExprStmt) }
  def append_slice(slice_expr)
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "appendSlice",
        [MIR::AllocatorRef.new(result_alloc), slice_expr], true, MIR::CallableContract.no_ownership(2)), false)
  end

  sig { params(lhs_type: Type).returns(T::Array[MIR::Emittable]) }
  def build_sharded_pool(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    buffer = var_and_defer(elem_zig)

    inner_loop = MIR::ForStmt.new(
      MIR::FieldGet.new(
        MIR::IndexGet.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "shards"),
                          MIR::Ident.new("__psi")),
        "slots"),
      "*__pslot",
      [MIR::IfStmt.new(
        MIR::FieldGet.new(MIR::Ident.new("__pslot"), "alive"),
        [append(MIR::FieldGet.new(MIR::Ident.new("__pslot"), "value"))],
        nil)],
      nil)

    outer_loop = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Lit.new(lhs_type.shard_count.to_s), :usize),
      "__psi",
      [inner_loop],
      nil)

    [buffer.var_decl, buffer.defer_stmt, outer_loop, items_let]
  end

  sig { params(lhs_type: Type).returns(T::Array[MIR::Emittable]) }
  def build_soa_pool(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    buffer = var_and_defer(elem_zig)

    value_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data"),
      "get", [MIR::Ident.new("__psi")], false,
      MIR::CallableContract.no_ownership(1))
    alive_check = MIR::IndexGet.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "alive"),
      MIR::Ident.new("__psi"))

    loop_node = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data")), "usize", :intCast), :usize),
      "__psi",
      [MIR::IfStmt.new(alive_check, [append(value_expr)], nil)],
      nil)

    [buffer.var_decl, buffer.defer_stmt, loop_node, items_let]
  end

  sig { params(lhs_type: Type).returns(T::Array[MIR::Emittable]) }
  def build_pool(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    buffer = var_and_defer(elem_zig)

    loop_node = MIR::ForStmt.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "slots"),
      "*__pslot",
      [MIR::IfStmt.new(
        MIR::FieldGet.new(MIR::Ident.new("__pslot"), "alive"),
        [append(MIR::FieldGet.new(MIR::Ident.new("__pslot"), "value"))],
        nil)],
      nil)

    [buffer.var_decl, buffer.defer_stmt, loop_node, items_let]
  end

  sig { params(lhs_type: Type).returns(T::Array[MIR::Emittable]) }
  def build_set(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    buffer = var_and_defer(elem_zig)

    iter_let = MIR::Let.new("__skit",
      MIR::MethodCall.new(MIR::Ident.new("pipe_src_list"), "keyIterator", [], false, MIR::CallableContract.no_ownership(0)),
      true, nil, nil)
    deref = MIR::FieldGet.new(MIR::Ident.new("__skptr"), "*")
    loop_node = MIR::WhileStmt.new(
      MIR::MethodCall.new(MIR::Ident.new("__skit"), "next", [], false, MIR::CallableContract.no_ownership(0)),
      [append(deref)],
      "__skptr", nil)

    [buffer.var_decl, buffer.defer_stmt, iter_let, loop_node, items_let]
  end

  sig { params(lhs_type: Type).returns(T::Array[MIR::Emittable]) }
  def build_soa_list(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    buffer = var_and_defer(elem_zig)

    value_expr = MIR::MethodCall.new(
      MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data"),
      "get", [MIR::Ident.new("__psi")], false,
      MIR::CallableContract.no_ownership(1))

    loop_node = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "data")), "usize", :intCast), :usize),
      "__psi",
      [append(value_expr)],
      nil)

    [buffer.var_decl, buffer.defer_stmt, loop_node, items_let]
  end

  sig { params(lhs_type: Type).returns(T::Array[MIR::Emittable]) }
  def build_sharded_list(lhs_type)
    elem_zig = T.must(lhs_type.element_type).zig_type
    buffer = var_and_defer(elem_zig)

    shard_items = MIR::FieldGet.new(
      MIR::IndexGet.new(MIR::FieldGet.new(MIR::Ident.new("pipe_src_list"), "shards"),
                        MIR::Ident.new("__psi")),
      "items")

    loop_node = MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::Lit.new(lhs_type.shard_count.to_s), :usize), "__psi",
      [append_slice(shard_items)],
      nil)

    [buffer.var_decl, buffer.defer_stmt, loop_node, items_let]
  end

  sig { params(lhs: AST::RangeLit).returns(T::Array[MIR::Emittable]) }
  def range_concurrent_source_setup(lhs)
    source_mir = @host.materializer_visit_mir(lhs)
    to_list = MIR::MethodCall.new(MIR::Ident.new("pipe_src_list"), "toList",
      [MIR::AllocatorRef.new(:heap)], true, MIR::CallableContract.no_ownership(1))
    [
      MIR::Let.new("pipe_src_list", source_mir, true, nil, "_ = &pipe_src_list;"),
      MIR::Let.new("pipe_mat", to_list, true, nil, nil),
      MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("pipe_mat"), "deinit",
        [MIR::AllocatorRef.new(:heap)], false, MIR::CallableContract.no_ownership(1))),
      MIR::Let.new("pipe_items", MIR::ItemsAccess.new(MIR::Ident.new("pipe_mat"), true), false, nil, nil),
    ]
  end
end
