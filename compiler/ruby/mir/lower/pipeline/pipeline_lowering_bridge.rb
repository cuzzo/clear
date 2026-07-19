# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"
require_relative "../../../ast/symbol_entry"
require_relative "../../../ast/type"
require_relative "../../cleanup_entry"
require_relative "../../lowering/schema_registry"
require_relative "../../mir"
require_relative "../../../backends/mir_emitter"

class PipelineLowerHeadResult < T::Struct
  const :value, MIR::Node
  const :pending, T::Array[MIR::Emittable]
end

class PipelineBridgeAllocationFact < T::Struct
  const :alloc, Symbol
  const :mark, MIR::AllocMark
  const :cleanup_entry, T.nilable(CleanupEntry)
end

class PipelineLoweringBridge
  extend T::Sig

  sig { params(lowering: MIRLowering, emitter: MIREmitter).void }
  def initialize(lowering:, emitter:)
    @lowering = T.let(lowering, MIRLowering)
    @lowering.runtime_state.emitter = emitter
  end

  sig { returns(MIRLoweringProgramState::FnSigMap) }
  def fn_sigs
    @lowering.fn_sigs
  end

  sig { returns(Symbol) }
  def lowering_target
    @lowering.lowering_target
  end

  sig { returns(T::Boolean) }
  def bc_target?
    @lowering.bc_target?
  end

  sig { returns(Symbol) }
  def pipeline_result_alloc
    @lowering.pipeline_result_alloc
  end

  sig { returns(MIRLoweringSchemas::SchemaLookup) }
  def mir_schema_lookup
    @lowering.mir_schema_lookup
  end

  sig { returns(Integer) }
  def next_pipeline_observable_id
    @lowering.next_pipeline_observable_id
  end

  sig { params(size_name: T.nilable(Symbol)).returns(String) }
  def task_config_variant(size_name)
    @lowering.task_config_variant(size_name, nil)
  end

  sig { params(name: String).returns(T::Boolean) }
  def guarded_cleanup_name?(name)
    @lowering.pipeline_guarded_cleanup_name?(name)
  end

  sig { params(node: AST::Node).returns(MIR::Node) }
  def lower_node(node)
    T.cast(@lowering.lower(node), MIR::Node)
  end

  sig { params(node: AST::Node, alloc: Symbol).returns(MIR::Node) }
  def lower_node_with_decl_alloc(node, alloc)
    @lowering.pipeline_lower_node_with_decl_alloc(node, alloc)
  end

  sig { params(nodes: T::Array[AST::Node]).returns(T::Array[MIR::Emittable]) }
  def lower_body(nodes)
    @lowering.lower_body(nodes)
  end

  sig { params(node: MIR::Node).returns(T.nilable(String)) }
  def emit_mir(node)
    @lowering.runtime_state.emitter!.emit(node)
  end

  sig { params(name: Symbol, args: T::Array[MIR::Emittable]).returns(MIR::Node) }
  def emit_builtin(name, args)
    @lowering.emit_builtin(name, args)
  end

  sig { params(blk: T.proc.returns(MIR::Node)).returns(PipelineLowerHeadResult) }
  def lower_head(&blk)
    value, pending = @lowering.lower_head { blk.call }
    typed_pending = T.let(pending, T::Array[MIR::Emittable])
    PipelineLowerHeadResult.new(
      value: T.cast(value, MIR::Node),
      pending: typed_pending,
    )
  end

  sig { params(body: T::Array[MIR::Emittable]).returns(T::Array[MIR::Emittable]) }
  def append_ownership_transfers_for_mir_body(body)
    @lowering.append_ownership_transfers_for_mir_body(body)
  end

  sig do
    params(
      value: MIR::Node,
      name: String,
      fallback_alloc: Symbol,
      type_info: T.nilable(Type),
      ast_node: T.nilable(AST::Node),
      context: String,
      known_allocating: T::Boolean,
      accept_owned_call: T::Boolean,
      include_cleanup: T::Boolean,
    ).returns(T.nilable(PipelineBridgeAllocationFact))
  end
  def pipeline_alloc_mark_fact(value, name, fallback_alloc:, type_info: nil, ast_node: nil,
                               context: "pipeline allocation", known_allocating: false,
                               accept_owned_call: false, include_cleanup: false)
    fact = @lowering.pipeline_alloc_mark_fact(
      value,
      name,
      fallback_alloc: fallback_alloc,
      type_info: type_info,
      ast_node: ast_node,
      context: context,
      known_allocating: known_allocating,
      accept_owned_call: accept_owned_call,
      include_cleanup: include_cleanup,
    )
    return nil unless fact

    PipelineBridgeAllocationFact.new(
      alloc: fact.alloc,
      mark: fact.mark,
      cleanup_entry: fact.cleanup_entry,
    )
  end

  sig { params(value: MIR::Node, ast_node: T.nilable(AST::Node)).returns(T.nilable(CleanupEntry)) }
  def pipeline_owned_cleanup_entry(value, ast_node)
    @lowering.pipeline_owned_cleanup_entry(value, ast_node)
  end

  sig { params(insert: MIR::IndexInsert, value: MIR::Node, value_owns: T::Boolean, target_alloc: Symbol).returns(MIR::IndexInsert) }
  def pipeline_index_insert_with_ownership(insert, value, value_owns, target_alloc:)
    @lowering.pipeline_index_insert_with_ownership(insert, value, value_owns, target_alloc: target_alloc)
  end

  sig do
    type_parameters(:U)
      .params(rt_name: String, blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_runtime_binding_name(rt_name, &blk)
    @lowering.with_runtime_binding_name(rt_name, &blk)
  end

  sig do
    type_parameters(:U)
      .params(
        new_entries: T::Hash[String, String],
        capture_symbols: T::Hash[String, SymbolEntry],
        rt_override: String,
        blk: T.proc.returns(T.type_parameter(:U)),
      )
      .returns(T.type_parameter(:U))
  end
  def with_fiber_capture_map(new_entries, capture_symbols:, rt_override:, &blk)
    @lowering.with_fiber_capture_map(new_entries, capture_symbols: capture_symbols, rt_override: rt_override, &blk)
  end

  sig { params(kind: Symbol, dispatch: Symbol, analysis: T.nilable(CapabilityHelper::CaptureAnalysis)).returns(MIR::ExecutionBoundaryFact) }
  def execution_boundary_fact(kind, dispatch, analysis)
    @lowering.send(:execution_boundary_fact, kind, dispatch, analysis)
  end

  sig do
    type_parameters(:U)
      .params(
        context: T.nilable(T::Hash[Symbol, String]),
        blk: T.proc.returns(T.type_parameter(:U)),
      )
      .returns(T.type_parameter(:U))
  end
  def with_shard_context(context, &blk)
    previous = @lowering.shard_context
    @lowering.shard_context = context
    blk.call
  ensure
    @lowering.shard_context = previous
  end
end
