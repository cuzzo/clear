# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "./pipeline_binding_chain_lowerer"
require_relative "./pipeline_range_lowerer"
require_relative "./pipeline_records"

class PipelineRoute < T::Enum
  enums do
    SoaScalarFold = new("soa_scalar_fold")
    RangeFold = new("range_fold")
    RangeReduce = new("range_reduce")
    BindingChain = new("binding_chain")
    ScalarTerminal = new("scalar_terminal")
    ListTerminal = new("list_terminal")
    Distinct = new("distinct")
    BatchWindow = new("batch_window")
    Index = new("index")
    Each = new("each")
    Concurrent = new("concurrent")
  end
end

class PipelineDispatchPlan < T::Struct
  const :route, PipelineRoute
  const :site, PipelineSite
  const :rhs, AST::Node
  const :range_chain, T.nilable(PipelineRangeChain)
  const :binding_chain, T.nilable(PipelineBindingUnnestChain)
end

class PipelinePlanServices < T::Struct
  const :lowering_target, T.proc.returns(Symbol)
  const :range_chain, T.proc.params(node: AST::Node).returns(T.nilable(PipelineRangeChain))
  const :binding_chain, T.proc.params(node: AST::BinaryOp).returns(T.nilable(PipelineBindingUnnestChain))
end

class PipelinePlanBuilder
  extend T::Sig

  sig { params(services: PipelinePlanServices).void }
  def initialize(services:)
    @services = T.let(services, PipelinePlanServices)
  end

  sig { params(node: AST::BinaryOp).returns(T.nilable(PipelineDispatchPlan)) }
  def build(node)
    lhs = T.cast(node.left, AST::Node)
    rhs = T.cast(node.right, AST::Node)
    site = PipelineSite.new(list: lhs, options: node)

    if soa_scalar_fold?(lhs, rhs)
      return dispatch(PipelineRoute::SoaScalarFold, site, rhs)
    end

    if AST.pipeline_range_fold?(rhs)
      range_chain = @services.range_chain.call(lhs)
      return dispatch(PipelineRoute::RangeFold, site, rhs, range_chain: range_chain) if range_chain
    end

    if rhs.is_a?(AST::ReduceOp)
      range_chain = @services.range_chain.call(lhs)
      return dispatch(PipelineRoute::RangeReduce, site, rhs, range_chain: range_chain) if range_chain
    end

    binding_chain = @services.binding_chain.call(node)
    return dispatch(PipelineRoute::BindingChain, site, rhs, binding_chain: binding_chain) if binding_chain

    route = terminal_route(rhs)
    route ? dispatch(route, site, rhs) : nil
  end

  private

  sig { params(lhs: AST::Node, rhs: AST::Node).returns(T::Boolean) }
  def soa_scalar_fold?(lhs, rhs)
    lhs_type = lhs.full_type!
    lhs_type.soa_linear_collection? &&
      AST.pipeline_range_fold?(rhs) &&
      @services.lowering_target.call != :bc
  end

  sig { params(route: PipelineRoute, site: PipelineSite, rhs: AST::Node, range_chain: T.nilable(PipelineRangeChain), binding_chain: T.nilable(PipelineBindingUnnestChain)).returns(PipelineDispatchPlan) }
  def dispatch(route, site, rhs, range_chain: nil, binding_chain: nil)
    PipelineDispatchPlan.new(
      route: route,
      site: site,
      rhs: rhs,
      range_chain: range_chain,
      binding_chain: binding_chain,
    )
  end

  sig { params(rhs: AST::Node).returns(T.nilable(PipelineRoute)) }
  def terminal_route(rhs)
    case rhs
    when AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp,
         AST::MaxOp, AST::AnyOp, AST::AllOp, AST::FindOp
      PipelineRoute::ScalarTerminal
    when AST::WhereOp, AST::SelectOp, AST::LimitOp, AST::TakeWhileOp,
         AST::SkipOp, AST::UnnestOp, AST::ReduceOp, AST::WindowOp,
         AST::OrderByOp, AST::JoinOp, AST::TapOp
      PipelineRoute::ListTerminal
    when AST::DistinctOp
      PipelineRoute::Distinct
    when AST::BatchWindowOp
      PipelineRoute::BatchWindow
    when AST::IndexOp
      PipelineRoute::Index
    when AST::EachOp
      PipelineRoute::Each
    when AST::ConcurrentOp
      PipelineRoute::Concurrent
    end
  end
end
