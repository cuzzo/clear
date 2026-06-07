# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/type"
require_relative "../../mir"
require_relative "./pipeline_range_lowerer"

PipelineEachResult = T.type_alias { T.nilable(T.any(MIR::ForStmt, MIR::ScopeBlock)) }

class PipelineEachSoaBody < T::Struct
  const :body, T::Array[MIR::Emittable]
  const :fields, T::Array[String]
end

class PipelineEachSourceKind < T::Enum
  enums do
    Sharded = new("sharded")
    Soa = new("soa")
    Pool = new("pool")
    RangeChain = new("range_chain")
    List = new("list")
    Set = new("set")
    RangeLiteral = new("range_literal")
    Unsupported = new("unsupported")
  end
end

class PipelineEachPlan < T::Struct
  const :source_kind, PipelineEachSourceKind
  const :list_node, AST::Node
  const :each_op, AST::EachOp
  const :lhs_type, Type
  const :range_chain, T.nilable(PipelineRangeChain)
  const :bc_target, T::Boolean
end

class PipelineEachLowerer < T::Struct
  extend T::Sig
  const :bc_target, T.proc.returns(T::Boolean)
  const :visit_mir, T.proc.params(node: AST::Node).returns(MIR::Node)
  const :visit_body_with_placeholder, T.proc.params(body_stmts: T::Array[AST::Node], placeholder: String).returns(T::Array[MIR::Emittable])
  const :soa_body, T.proc.params(body_stmts: T::Array[AST::Node]).returns(PipelineEachSoaBody)
  const :range_chain, T.proc.params(node: AST::Node).returns(T.nilable(PipelineRangeChain))
  const :lower_each_range, T.proc.params(source_node: AST::Node, stages: T::Array[AST::Node], each_op: AST::EachOp).returns(MIR::ScopeBlock)
  const :lower_sharded_each, T.proc.params(list_node: AST::Node, each_op: AST::EachOp).returns(MIR::ScopeBlock)
  const :ast_stmts_use_placeholder, T.proc.params(body_stmts: T::Array[AST::Node]).returns(T::Boolean)
  const :next_index_name, T.proc.returns(String)

  sig { params(list_node: AST::Node, each_op: AST::EachOp).returns(PipelineEachResult) }
  def lower(list_node, each_op)
    lower_plan(each_plan(list_node, each_op))
  end

  private

  sig { params(list_node: AST::Node, each_op: AST::EachOp).returns(PipelineEachPlan) }
  def each_plan(list_node, each_op)
    lhs_type = list_node.full_type!
    bc_target = self.bc_target.call
    range_chain = self.range_chain.call(list_node)

    PipelineEachPlan.new(
      source_kind: each_source_kind(list_node, lhs_type, range_chain, bc_target),
      list_node: list_node,
      each_op: each_op,
      lhs_type: lhs_type,
      range_chain: range_chain,
      bc_target: bc_target,
    )
  end

  sig { params(plan: PipelineEachPlan).returns(PipelineEachResult) }
  def lower_plan(plan)
    lower_source_plan(plan.source_kind, plan)
  end

  sig { params(source_kind: PipelineEachSourceKind, plan: PipelineEachPlan).returns(PipelineEachResult) }
  def lower_source_plan(source_kind, plan)
    case source_kind
    when PipelineEachSourceKind::Sharded
      self.lower_sharded_each.call(plan.list_node, plan.each_op)
    when PipelineEachSourceKind::Soa
      lower_soa_each(plan.list_node, plan.lhs_type, plan.each_op)
    when PipelineEachSourceKind::Pool
      lower_pool_each(plan.list_node, plan.lhs_type, plan.each_op, bc_target: plan.bc_target)
    when PipelineEachSourceKind::RangeChain
      chain = T.must(plan.range_chain)
      self.lower_each_range.call(chain.source, chain.stages, plan.each_op)
    when PipelineEachSourceKind::List
      lower_list_each(plan.list_node, plan.each_op, bc_target: plan.bc_target)
    when PipelineEachSourceKind::Set
      lower_set_each(plan.list_node, plan.each_op)
    when PipelineEachSourceKind::RangeLiteral
      lower_range_literal_each(plan.list_node, plan.each_op)
    when PipelineEachSourceKind::Unsupported
      nil
    end
  end

  sig { params(list_node: AST::Node, lhs_type: Type, range_chain: T.nilable(PipelineRangeChain), bc_target: T::Boolean).returns(PipelineEachSourceKind) }
  def each_source_kind(list_node, lhs_type, range_chain, bc_target)
    return PipelineEachSourceKind::Sharded if lhs_type.sharded? && !bc_target
    return PipelineEachSourceKind::Soa if lhs_type.soa_linear_collection? && !bc_target
    return PipelineEachSourceKind::Pool if lhs_type.pool?
    return PipelineEachSourceKind::RangeChain if range_chain_usable?(list_node, range_chain, bc_target)
    return PipelineEachSourceKind::List if lhs_type.list_collection? || lhs_type.fixed_soa?
    return PipelineEachSourceKind::Set if lhs_type.set_collection?
    return PipelineEachSourceKind::RangeLiteral if list_node.is_a?(AST::RangeLit)

    PipelineEachSourceKind::Unsupported
  end

  sig { params(list_node: AST::Node, range_chain: T.nilable(PipelineRangeChain), bc_target: T::Boolean).returns(T::Boolean) }
  def range_chain_usable?(list_node, range_chain, bc_target)
    return false unless range_chain

    !(bc_target && list_node.is_a?(AST::RangeLit) && range_chain.stages.empty?)
  end

  sig { params(list_node: AST::Node, lhs_type: Type, each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_soa_each(list_node, lhs_type, each_op)
    source_mir = self.visit_mir.call(list_node)
    soa = self.soa_body.call(each_op.body)
    alive_guard = T.let([], T::Array[MIR::Emittable])
    if lhs_type.pool?
      alive_guard << MIR::IfStmt.new(
        MIR::UnaryOp.new("!",
          MIR::IndexGet.new(
            MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "alive"),
            MIR::Ident.new("__soa_i"))),
        [MIR::ContinueStmt.new(nil)], nil)
    end

    MIR::ScopeBlock.new([
      MIR::Let.new("__soa_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
      *soa.fields.map { |field|
        MIR::Let.new("__soa_#{field}",
          MIR::SoaFieldAccess.new(MIR::Ident.new("__soa_src"), field),
          false, nil, nil)
      },
      MIR::ForStmt.new(
        MIR::IterRange.new(
          MIR::Lit.new("0"),
          MIR::Cast.new(MIR::ListLength.new(MIR::FieldGet.new(MIR::Ident.new("__soa_src"), "data")), "usize", :intCast),
          :usize,
        ),
        "__soa_i",
        [*alive_guard, *soa.body],
        nil,
      ),
    ])
  end

  sig { params(list_node: AST::Node, lhs_type: Type, each_op: AST::EachOp, bc_target: T::Boolean).returns(T.any(MIR::ForStmt, MIR::ScopeBlock)) }
  def lower_pool_each(list_node, lhs_type, each_op, bc_target:)
    source_mir = self.visit_mir.call(list_node)
    pool_body_mir = self.visit_body_with_placeholder.call(each_op.body, "__each_item")
    if bc_target && list_node.is_a?(AST::Identifier)
      return lower_bc_indexed_each(list_node, pool_body_mir, skip_nil: true)
    end

    MIR::ScopeBlock.new([
      MIR::Let.new("__each_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
      MIR::ForStmt.new(
        MIR::FieldGet.new(MIR::Ident.new("__each_src"), "slots"),
        "*__each_slot",
        [
          MIR::IfStmt.new(
            MIR::UnaryOp.new("!", MIR::FieldGet.new(MIR::Ident.new("__each_slot"), "alive")),
            [MIR::ContinueStmt.new(nil)], nil),
          MIR::Let.new("__each_item",
            MIR::UnaryOp.new("&", MIR::FieldGet.new(MIR::Ident.new("__each_slot"), "value")),
            false, nil, nil),
          *pool_body_mir,
        ],
        nil,
      ),
    ])
  end

  sig { params(list_node: AST::Node, body_mir: T::Array[MIR::Emittable], skip_nil: T::Boolean).returns(MIR::ForStmt) }
  def lower_bc_indexed_each(list_node, body_mir, skip_nil:)
    idx_name = self.next_index_name.call
    src_ident = MIR::Ident.new(T.cast(list_node, AST::Identifier).name.to_s)
    body = T.let([
      MIR::Let.new("__each_item",
        MIR::IndexGet.new(src_ident, MIR::Ident.new(idx_name)),
        true, nil, nil),
    ], T::Array[MIR::Emittable])
    if skip_nil
      body << MIR::IfStmt.new(
        MIR::BinOp.new("==", MIR::Ident.new("__each_item"), MIR::Lit.new("nil")),
        [MIR::ContinueStmt.new(nil)], nil)
    end
    body.concat(body_mir)
    body << MIR::Set.new(
      MIR::IndexGet.new(src_ident, MIR::Ident.new(idx_name)),
      MIR::Ident.new("__each_item"))

    MIR::ForStmt.new(
      MIR::IterRange.new(MIR::Lit.new("0"), MIR::ListLength.new(src_ident), :usize),
      idx_name,
      body,
      nil,
    )
  end

  sig { params(list_node: AST::Node, each_op: AST::EachOp, bc_target: T::Boolean).returns(MIR::ScopeBlock) }
  def lower_list_each(list_node, each_op, bc_target:)
    source_mir = self.visit_mir.call(list_node)
    list_body_mir = self.visit_body_with_placeholder.call(each_op.body, "__each_item")
    if bc_target && list_node.is_a?(AST::Identifier)
      return MIR::ScopeBlock.new([lower_bc_indexed_each(list_node, list_body_mir, skip_nil: false)])
    end

    MIR::ScopeBlock.new([
      MIR::Let.new("__each_src", source_mir, false, nil, nil),
      MIR::Let.new("__each_items",
        MIR::ItemsAccess.new(MIR::Ident.new("__each_src"), true), false, nil, nil),
      MIR::ForStmt.new(MIR::Ident.new("__each_items"), "__each_item", list_body_mir, nil),
    ])
  end

  sig { params(list_node: AST::Node, each_op: AST::EachOp).returns(MIR::ScopeBlock) }
  def lower_set_each(list_node, each_op)
    source_mir = self.visit_mir.call(list_node)
    set_body_mir = self.visit_body_with_placeholder.call(each_op.body, "__each_item")
    MIR::ScopeBlock.new([
      MIR::Let.new("__each_src", MIR::UnaryOp.new("&", source_mir), false, nil, nil),
      MIR::Let.new("__each_iter",
        MIR::MethodCall.new(MIR::Ident.new("__each_src"), "keyIterator", [], false, MIR::CallableContract.no_ownership(0)),
        true, nil, nil),
      MIR::WhileStmt.new(
        MIR::MethodCall.new(MIR::Ident.new("__each_iter"), "next", [], false, MIR::CallableContract.no_ownership(0)),
        [MIR::Let.new("__each_item", MIR::FieldGet.new(MIR::Ident.new("__each_kptr"), "*"), false, nil, nil),
         *set_body_mir],
        "__each_kptr", nil),
    ])
  end

  sig { params(list_node: AST::Node, each_op: AST::EachOp).returns(MIR::ForStmt) }
  def lower_range_literal_each(list_node, each_op)
    range = T.cast(list_node, AST::RangeLit)
    start_mir = self.visit_mir.call(T.cast(range.start, AST::Node))
    end_mir = self.visit_mir.call(T.cast(range.finish, AST::Node))
    end_expr = range.inclusive ? MIR::BinOp.new("+", end_mir, MIR::Lit.new("1")) : end_mir
    range_body_mir = self.visit_body_with_placeholder.call(each_op.body, "__each_item")
    capture_name = self.ast_stmts_use_placeholder.call(each_op.body) ? "__each_item" : "_"

    MIR::ForStmt.new(
      MIR::IterRange.new(start_mir, end_expr, :i64),
      capture_name,
      range_body_mir,
      nil,
    )
  end
end
