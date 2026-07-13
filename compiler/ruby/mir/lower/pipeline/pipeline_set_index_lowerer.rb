# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../cleanup_entry"
require_relative "../../mir"
require_relative "./pipeline_range_lowerer"

PipelineSetIndexTypeInput = T.type_alias { T.any(Type, Symbol, String) }

class PipelineIndexValueOwnership < T::Enum
  enums do
    Owned = new("owned")
    Borrowed = new("borrowed")
  end
end

class PipelineIndexAllocationFact < T::Struct
  const :alloc, Symbol
  const :mark, MIR::AllocMark
  const :cleanup_entry, T.nilable(CleanupEntry)
end

class PipelineIndexPreparedValue < T::Struct
  const :value, MIR::Node
  const :setup_stmts, T::Array[MIR::Emittable]
  const :owns_heap, T::Boolean
end

class PipelineSetIndexLowerer < T::Struct
  extend T::Sig
  const :bc_target, T.proc.returns(T::Boolean)
  const :visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node)
  const :visit_mir_with_placeholder, T.proc.params(node: AST::Node, placeholder: String).returns(MIR::Node)
  const :pipeline_block, T.proc.params(list_node: AST::Node, blk: T.proc.params(items: String, label: String).returns(T::Array[MIR::Emittable])).returns(MIR::BlockExpr)
  const :transpile_type, T.proc.params(type_info: PipelineSetIndexTypeInput).returns(String)
  const :pipeline_alloc, T.proc.params(smooth_node: AST::BinaryOp).returns(Symbol)
  const :next_label, T.proc.returns(String)
  const :typed_block_expr, T.proc.params(label: String, body: T::Array[MIR::Emittable], result_type: Type).returns(MIR::BlockExpr)
  const :range_chain, T.proc.params(node: AST::Node).returns(T.nilable(PipelineRangeChain))
  const :lazy_range_prefix, T.proc.params(source_node: AST::Node, stages: T::Array[AST::Node], on_skip: T.nilable(PipelineRangeSkipHook)).returns(PipelineLazyRangePrefix)
  const :range_fold_observable_distinct, T.proc.params(prefix: PipelineLazyRangePrefix, distinct_op: AST::DistinctOp, smooth_node: AST::BinaryOp, label: String, source_node: AST::Node).returns(MIR::BlockExpr)
  const :cleanup_bearing_type, T.proc.params(type_info: Type).returns(T::Boolean)
  const :pipeline_alloc_mark_fact, T.proc.params(value: MIR::Node, name: String, fallback_alloc: Symbol, ast_node: T.nilable(AST::Node), context: String, include_cleanup: T::Boolean).returns(T.nilable(PipelineIndexAllocationFact))
  const :pipeline_owned_cleanup_entry, T.proc.params(value: MIR::Node, ast_node: T.nilable(AST::Node)).returns(T.nilable(CleanupEntry))
  const :pipeline_index_insert_with_ownership, T.proc.params(insert: MIR::IndexInsert, value: MIR::Node, value_owns: T::Boolean, target_alloc: Symbol).returns(MIR::IndexInsert)
  const :index_temp_name, T.proc.returns(String)

  sig { params(list_node: AST::Node, smooth_node: AST::BinaryOp, distinct_node: AST::DistinctOp).returns(MIR::BlockExpr) }
  def lower_distinct(list_node, smooth_node, distinct_node)
    if smooth_node.observable_dest
      observable = lower_observable_distinct(list_node, smooth_node, distinct_node)
      return observable if observable
    end

    elem_zig = self.transpile_type.call(T.must(smooth_node.full_type!.element_type).resolved.to_s)
    set_zig = "CheatLib.Set(#{elem_zig})"
    alloc = :heap
    expr_mir = self.visit_mir_with_placeholder.call(distinct_node.expression, "it")

    range_chain = self.range_chain.call(list_node)
    return lower_range_distinct(range_chain, distinct_node, set_zig, alloc) if range_chain

    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        MIR::Let.new("dist_set", MIR::ContainerInit.new(set_zig, :set_empty, nil, nil), true, nil, nil),
        MIR::ForStmt.new(MIR::Ident.new(items), "it", [
          MIR::Let.new("dist_key", expr_mir, false, nil, nil),
          distinct_insert_stmt(alloc, uses_allocator: true),
        ], nil),
        MIR::BreakStmt.new(label, MIR::Ident.new("dist_set")),
      ]
    end)
  end

  sig { params(list_node: AST::Node, smooth_node: AST::BinaryOp, expr_node: AST::Node).returns(MIR::BlockExpr) }
  def lower_index(list_node, smooth_node, expr_node)
    lhs_type = list_node.full_type!
    alloc = self.pipeline_alloc.call(smooth_node)

    range_chain = self.range_chain.call(list_node)
    if range_chain
      elem_type = index_stream_element_type(list_node, lhs_type, range_chain.source)
      elem_zig = self.transpile_type.call(elem_type.to_s)
      map_type = "CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig}))"
      return lower_stream_index(range_chain, expr_node, elem_zig, elem_type, alloc, map_type, Type.from_node!(smooth_node, context: "INDEX result"))
    end

    elem_type = T.must(list_node.full_type!.element_type)
    elem_zig = self.transpile_type.call(elem_type.resolved.to_s)
    expr_mir = self.visit_mir_with_placeholder.call(expr_node, "it")
    map_type = "CheatLib.StringMap(std.ArrayListUnmanaged(#{elem_zig}))"

    self.pipeline_block.call(list_node, lambda do |items, label|
      [
        index_result_let(map_type, alloc),
        MIR::ForStmt.new(
          MIR::Ident.new(items),
          "it",
          build_index_gop_body(
            expr_mir,
            alloc,
            "it",
            expr_node: expr_node,
            item_type: elem_type,
            value_ownership: PipelineIndexValueOwnership::Borrowed,
          ),
          nil,
        ),
        MIR::BreakStmt.new(label, MIR::Ident.new("idx_result")),
      ]
    end)
  end

  private

  sig { params(list_node: AST::Node, smooth_node: AST::BinaryOp, distinct_node: AST::DistinctOp).returns(T.nilable(MIR::BlockExpr)) }
  def lower_observable_distinct(list_node, smooth_node, distinct_node)
    range_chain = self.range_chain.call(list_node)
    return nil unless range_chain

    prefix = self.lazy_range_prefix.call(range_chain.source, range_chain.stages, nil)
    self.range_fold_observable_distinct.call(
      prefix,
      distinct_node,
      smooth_node,
      self.next_label.call,
      range_chain.source,
    )
  end

  sig { params(range_chain: PipelineRangeChain, distinct_node: AST::DistinctOp, set_zig: String, alloc: Symbol).returns(MIR::BlockExpr) }
  def lower_range_distinct(range_chain, distinct_node, set_zig, alloc)
    prefix = self.lazy_range_prefix.call(range_chain.source, range_chain.stages, nil)
    item_var = prefix.item_var
    key_expr_mir = self.visit_mir_with_placeholder.call(distinct_node.expression, item_var)
    label = self.next_label.call
    source_type = range_chain.source.full_type!
    defer_deinit = source_type.bounded_stream? ? prefix.deinit_stmt : nil

    if self.bc_target.call && range_chain.source.is_a?(AST::Identifier) && source_type.runtime_stream?
      return MIR::BlockExpr.new(label, [
        *prefix.outer_setup_stmts,
        MIR::Let.new("dist_set", MIR::ContainerInit.new(set_zig, :set_empty, nil, nil), true, nil, nil),
        prefix.loop_stmt(self.visit_mir.call(range_chain.source), [
          MIR::Let.new("dist_key", key_expr_mir, false, nil, nil),
          distinct_insert_stmt(alloc, uses_allocator: false),
        ]),
        MIR::BreakStmt.new(label, MIR::Ident.new("dist_set")),
      ])
    end

    MIR::BlockExpr.new(label, [
      *prefix.setup_stmts,
      MIR::Let.new("dist_set", MIR::ContainerInit.new(set_zig, :set_empty, nil, nil), true, nil, nil),
      *([defer_deinit].compact),
      prefix.loop_stmt(nil, [
        MIR::Let.new("dist_key", key_expr_mir, false, nil, nil),
        distinct_insert_stmt(alloc, uses_allocator: true),
      ]),
      MIR::BreakStmt.new(label, MIR::Ident.new("dist_set")),
    ])
  end

  sig { params(alloc: Symbol, uses_allocator: T::Boolean).returns(MIR::ExprStmt) }
  def distinct_insert_stmt(alloc, uses_allocator:)
    args = if uses_allocator
      [MIR::AllocatorRef.new(alloc), MIR::Ident.new("dist_key")]
    else
      [MIR::Ident.new("dist_key")]
    end
    MIR::ExprStmt.new(
      MIR::MethodCall.new(
        MIR::Ident.new("dist_set"),
        "insert",
        args,
        true,
        MIR::CallableContract.no_ownership(args.length),
      ),
      nil,
    )
  end

  sig { params(list_node: AST::Node, lhs_type: Type, range_source: AST::Node).returns(Type) }
  def index_stream_element_type(list_node, lhs_type, range_source)
    lhs_type.runtime_stream_storage_element_type ||
      range_source.full_type!.runtime_stream_storage_element_type ||
      T.must(list_node.full_type!.element_type)
  end

  sig { params(range_chain: PipelineRangeChain, expr_node: AST::Node, elem_zig: String, elem_type: Type, alloc: Symbol, map_type: String, result_type: Type).returns(MIR::BlockExpr) }
  def lower_stream_index(range_chain, expr_node, elem_zig, elem_type, alloc, map_type, result_type)
    on_skip = T.let(lambda do |var|
      [MIR::ExprStmt.new(
        MIR::Call.new("CheatLib.cleanup", [
          MIR::Ident.new(elem_zig),
          MIR::AllocatorRef.new(:heap),
          MIR::AddressOf.new(MIR::Ident.new(var)),
        ], false, false, MIR::CallableContract.no_ownership(3)), nil)]
    end, PipelineRangeSkipHook)

    prefix = self.lazy_range_prefix.call(range_chain.source, range_chain.stages, on_skip)
    item_var = prefix.item_var
    expr_mir = self.visit_mir_with_placeholder.call(expr_node, item_var)
    label = self.next_label.call
    source_type = range_chain.source.full_type!
    defer_deinit = source_type.bounded_stream? ? prefix.deinit_stmt : nil

    if self.bc_target.call
      iter = bc_index_iter(range_chain.source)
      if iter
        return self.typed_block_expr.call(label, [
          *prefix.outer_setup_stmts,
          index_result_let(map_type, :heap),
          prefix.loop_stmt(iter, build_index_gop_body(
            expr_mir,
            :heap,
            item_var,
            expr_node: expr_node,
            item_type: elem_type,
            value_ownership: PipelineIndexValueOwnership::Owned,
          )),
          MIR::BreakStmt.new(label, MIR::Ident.new("idx_result")),
        ], result_type)
      end
    end

    self.typed_block_expr.call(label, [
      *prefix.setup_stmts,
      index_result_let(map_type, :heap),
      *([defer_deinit].compact),
      prefix.loop_stmt(nil, build_index_gop_body(
        expr_mir,
        :heap,
        item_var,
        expr_node: expr_node,
        item_type: elem_type,
        value_ownership: PipelineIndexValueOwnership::Owned,
      )),
      MIR::BreakStmt.new(label, MIR::Ident.new("idx_result")),
    ], result_type)
  end

  sig { params(range_source: AST::Node).returns(T.nilable(MIR::Emittable)) }
  def bc_index_iter(range_source)
    if range_source.is_a?(AST::RangeLit)
      start_mir = self.visit_mir.call(T.cast(range_source.start, AST::Node))
      end_mir = self.visit_mir.call(T.cast(range_source.finish, AST::Node))
      end_expr = range_source.inclusive ? MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir
      return MIR::IterRange.new(start_mir, end_expr, :i64)
    end

    return self.visit_mir.call(range_source) if range_source.is_a?(AST::Identifier)

    nil
  end

  sig { params(map_type: String, alloc: Symbol).returns(MIR::Let) }
  def index_result_let(map_type, alloc)
    MIR::Let.new(
      "idx_result",
      MIR::StructInit.new(nil, [MIR::StructInitField.new(name: "alloc", value: MIR::AllocatorRef.new(alloc))]),
      true,
      Type.new(map_type),
      nil,
    )
  end

  sig do
    params(
      expr_mir: MIR::Node,
      alloc: Symbol,
      item_var: String,
      expr_node: T.nilable(AST::Node),
      item_type: T.nilable(Type),
      value_ownership: PipelineIndexValueOwnership,
    ).returns(T::Array[MIR::Emittable])
  end
  def build_index_gop_body(expr_mir, alloc, item_var, expr_node:, item_type:, value_ownership:)
    elem_zig_type = "@TypeOf(#{item_var})"
    prepared = index_prepared_value(item_var, elem_zig_type, alloc, item_type, value_ownership)

    insert = MIR::IndexInsert.new(
      MIR::Ident.new("idx_result"),
      MIR::Ident.new("idx_key"),
      prepared.value,
      "u8",
      elem_zig_type,
      alloc,
    )
    owned_insert = self.pipeline_index_insert_with_ownership.call(insert, prepared.value, prepared.owns_heap, alloc)
    body = T.let([
      MIR::Let.new("idx_key", expr_mir, false, nil, nil),
      *prepared.setup_stmts,
      owned_insert,
    ], T::Array[MIR::Emittable])
    entry = self.pipeline_owned_cleanup_entry.call(expr_mir, expr_node)
    body << MIR::Cleanup.new("idx_key", entry) if entry
    body
  end

  sig { params(item_var: String, elem_zig_type: String, alloc: Symbol, item_type: T.nilable(Type), value_ownership: PipelineIndexValueOwnership).returns(PipelineIndexPreparedValue) }
  def index_prepared_value(item_var, elem_zig_type, alloc, item_type, value_ownership)
    item_owns = item_type ? self.cleanup_bearing_type.call(item_type) : true
    item_value = index_item_value(item_var, elem_zig_type, alloc, value_ownership)
    if preserve_owned_index_item?(item_owns, value_ownership)
      return PipelineIndexPreparedValue.new(
        value: item_value,
        setup_stmts: [MIR::AllocMark.new(item_var, alloc, item_type || Type.new(:Any), MIR::Placement.alloc_scope(alloc))],
        owns_heap: item_owns,
      )
    end

    copied_index_value(item_value, alloc, item_owns)
  end

  sig { params(item_owns: T::Boolean, value_ownership: PipelineIndexValueOwnership).returns(T::Boolean) }
  def preserve_owned_index_item?(item_owns, value_ownership)
    item_owns && value_ownership == PipelineIndexValueOwnership::Owned
  end

  sig { params(item_value: MIR::Node, alloc: Symbol, item_owns: T::Boolean).returns(PipelineIndexPreparedValue) }
  def copied_index_value(item_value, alloc, item_owns)
    fact = self.pipeline_alloc_mark_fact.call(
      item_value,
      self.index_temp_name.call,
      alloc,
      nil,
      "INDEX bucket item",
      true,
    )
    return PipelineIndexPreparedValue.new(value: item_value, setup_stmts: [], owns_heap: item_owns) unless fact

    value_name = fact.mark.name
    setup_stmts = T.let([
      fact.mark,
      MIR::Let.new(value_name, item_value, false, nil, nil),
    ], T::Array[MIR::Emittable])
    entry = fact.cleanup_entry
    setup_stmts << MIR::ErrCleanup.new(value_name, entry.with_moved_guard) if entry
    PipelineIndexPreparedValue.new(
      value: MIR::Ident.new(value_name),
      setup_stmts: setup_stmts,
      owns_heap: item_owns,
    )
  end

  sig { params(item_var: String, elem_zig_type: String, alloc: Symbol, value_ownership: PipelineIndexValueOwnership).returns(MIR::Node) }
  def index_item_value(item_var, elem_zig_type, alloc, value_ownership)
    if value_ownership == PipelineIndexValueOwnership::Borrowed
      MIR::DeepCopy.new(MIR::Ident.new(item_var), elem_zig_type, nil, :full_value, alloc)
    else
      MIR::Ident.new(item_var)
    end
  end
end
