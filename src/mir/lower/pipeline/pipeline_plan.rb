# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "./pipeline_binding_chain_lowerer"
require_relative "./pipeline_range_lowerer"
require_relative "./pipeline_records"

class PipelineSourceKind < T::Enum
  enums do
    Soa = new("soa")
    RangeChain = new("range_chain")
    BindingChain = new("binding_chain")
    Materialized = new("materialized")
  end
end

class PipelineTerminalKind < T::Enum
  enums do
    ScalarFold = new("scalar_fold")
    RangeFold = new("range_fold")
    RangeReduce = new("range_reduce")
    BindingChain = new("binding_chain")
    ListMaterialization = new("list_materialization")
    Distinct = new("distinct")
    BatchWindow = new("batch_window")
    Index = new("index")
    Each = new("each")
    Concurrent = new("concurrent")
  end
end

class PipelineExecutionKind < T::Enum
  enums do
    SoaScalarFold = new("soa_scalar_fold")
    FusedRangeFold = new("fused_range_fold")
    FusedRangeReduce = new("fused_range_reduce")
    BindingChain = new("binding_chain")
    MaterializedScalar = new("materialized_scalar")
    MaterializedList = new("materialized_list")
    SetDistinct = new("set_distinct")
    BatchWindow = new("batch_window")
    SetIndex = new("set_index")
    Each = new("each")
    Concurrent = new("concurrent")
  end
end

class PipelineSourcePlan < T::Struct
  const :kind, PipelineSourceKind
  const :node, AST::Node
  const :range_chain, T.nilable(PipelineRangeChain)
  const :binding_chain, T.nilable(PipelineBindingUnnestChain)
end

class PipelineTerminalPlan < T::Struct
  const :kind, PipelineTerminalKind
  const :node, AST::Node
end

class PipelineSemanticFacts < T::Struct
  extend T::Sig

  const :bc_target, T::Boolean
  const :source_kind, PipelineSourceKind
  const :terminal_kind, PipelineTerminalKind

  sig { returns(T::Boolean) }
  def range_fused
    source_kind == PipelineSourceKind::RangeChain
  end

  sig { returns(T::Boolean) }
  def binding_fused
    source_kind == PipelineSourceKind::BindingChain
  end

  sig { returns(T::Boolean) }
  def concurrent
    terminal_kind == PipelineTerminalKind::Concurrent
  end

  sig { returns(T::Boolean) }
  def side_effecting
    terminal_kind == PipelineTerminalKind::Each
  end
end

class PipelineOperationPlan < T::Struct
  const :execution, PipelineExecutionKind
  const :site, PipelineSite
  const :rhs, AST::Node
  const :source, PipelineSourcePlan
  const :terminal, PipelineTerminalPlan
  const :facts, PipelineSemanticFacts
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

  sig { params(node: AST::BinaryOp).returns(T.nilable(PipelineOperationPlan)) }
  def build(node)
    lhs = T.cast(node.left, AST::Node)
    rhs = T.cast(node.right, AST::Node)
    site = PipelineSite.new(list: lhs, options: node)
    bc_target = @services.lowering_target.call == :bc

    if soa_scalar_fold?(lhs, rhs)
      return operation(
        PipelineExecutionKind::SoaScalarFold,
        site,
        rhs,
        source_kind: PipelineSourceKind::Soa,
        terminal_kind: PipelineTerminalKind::ScalarFold,
        bc_target: bc_target,
      )
    end

    if AST.pipeline_range_fold?(rhs)
      range_chain = @services.range_chain.call(lhs)
      if range_chain
        return operation(
          PipelineExecutionKind::FusedRangeFold,
          site,
          rhs,
          source_kind: PipelineSourceKind::RangeChain,
          terminal_kind: PipelineTerminalKind::RangeFold,
          range_chain: range_chain,
          bc_target: bc_target,
        )
      end
    end

    if rhs.is_a?(AST::ReduceOp)
      range_chain = @services.range_chain.call(lhs)
      if range_chain
        return operation(
          PipelineExecutionKind::FusedRangeReduce,
          site,
          rhs,
          source_kind: PipelineSourceKind::RangeChain,
          terminal_kind: PipelineTerminalKind::RangeReduce,
          range_chain: range_chain,
          bc_target: bc_target,
        )
      end
    end

    binding_chain = @services.binding_chain.call(node)
    if binding_chain
      return operation(
        PipelineExecutionKind::BindingChain,
        site,
        rhs,
        source_kind: PipelineSourceKind::BindingChain,
        terminal_kind: PipelineTerminalKind::BindingChain,
        binding_chain: binding_chain,
        bc_target: bc_target,
      )
    end

    terminal = terminal_kind(rhs)
    terminal ? operation(execution_for(terminal), site, rhs, terminal_kind: terminal, bc_target: bc_target) : nil
  end

  private

  sig { params(lhs: AST::Node, rhs: AST::Node).returns(T::Boolean) }
  def soa_scalar_fold?(lhs, rhs)
    lhs_type = lhs.full_type!
    lhs_type.soa_linear_collection? &&
      AST.pipeline_range_fold?(rhs) &&
      @services.lowering_target.call != :bc
  end

  sig do
    params(
      execution: PipelineExecutionKind,
      site: PipelineSite,
      rhs: AST::Node,
      terminal_kind: PipelineTerminalKind,
      bc_target: T::Boolean,
      source_kind: PipelineSourceKind,
      range_chain: T.nilable(PipelineRangeChain),
      binding_chain: T.nilable(PipelineBindingUnnestChain),
    ).returns(PipelineOperationPlan)
  end
  def operation(execution, site, rhs, terminal_kind:, bc_target:, source_kind: PipelineSourceKind::Materialized, range_chain: nil, binding_chain: nil)
    source = PipelineSourcePlan.new(
      kind: source_kind,
      node: site.list,
      range_chain: range_chain,
      binding_chain: binding_chain,
    )
    terminal = PipelineTerminalPlan.new(kind: terminal_kind, node: rhs)
    facts = PipelineSemanticFacts.new(
      bc_target: bc_target,
      source_kind: source_kind,
      terminal_kind: terminal_kind,
    )

    PipelineOperationPlan.new(
      execution: execution,
      site: site,
      rhs: rhs,
      source: source,
      terminal: terminal,
      facts: facts,
    )
  end

  sig { params(rhs: AST::Node).returns(T.nilable(PipelineTerminalKind)) }
  def terminal_kind(rhs)
    case rhs
    when AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp,
         AST::MaxOp, AST::AnyOp, AST::AllOp, AST::FindOp
      PipelineTerminalKind::ScalarFold
    when AST::WhereOp, AST::SelectOp, AST::LimitOp, AST::TakeWhileOp,
         AST::SkipOp, AST::UnnestOp, AST::ReduceOp, AST::WindowOp,
         AST::OrderByOp, AST::JoinOp, AST::TapOp
      PipelineTerminalKind::ListMaterialization
    when AST::DistinctOp
      PipelineTerminalKind::Distinct
    when AST::BatchWindowOp
      PipelineTerminalKind::BatchWindow
    when AST::IndexOp
      PipelineTerminalKind::Index
    when AST::EachOp
      PipelineTerminalKind::Each
    when AST::ConcurrentOp
      PipelineTerminalKind::Concurrent
    end
  end

  sig { params(terminal: PipelineTerminalKind).returns(PipelineExecutionKind) }
  def execution_for(terminal)
    case terminal
    when PipelineTerminalKind::ScalarFold
      PipelineExecutionKind::MaterializedScalar
    when PipelineTerminalKind::ListMaterialization
      PipelineExecutionKind::MaterializedList
    when PipelineTerminalKind::Distinct
      PipelineExecutionKind::SetDistinct
    when PipelineTerminalKind::BatchWindow
      PipelineExecutionKind::BatchWindow
    when PipelineTerminalKind::Index
      PipelineExecutionKind::SetIndex
    when PipelineTerminalKind::Each
      PipelineExecutionKind::Each
    when PipelineTerminalKind::Concurrent
      PipelineExecutionKind::Concurrent
    else
      raise "unsupported pipeline terminal: #{terminal.serialize}"
    end
  end
end
