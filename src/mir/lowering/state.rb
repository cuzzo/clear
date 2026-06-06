# typed: strict
require "sorbet-runtime"
require "set"

require_relative "../mir"
require_relative "../mir_emitter"
require_relative "../lower/pipeline/pipeline_host"
require_relative "../../ast/ast"
require_relative "../../ast/symbol_entry"
require_relative "../../backends/importer"
require_relative "../lowering/counters"
require_relative "../lowering/schema_registry"
require_relative "../lowering/functions"
require_relative "../lowering/capabilities"

class MIRLoweringRuntimeState < T::Struct
  extend T::Sig

  prop :rt_name, String, default: "rt"
  prop :emitter, T.nilable(MIREmitter), default: nil

  sig { returns(MIREmitter) }
  def emitter!
    current = emitter
    return current if current

    current = MIREmitter.new
    self.emitter = current
    current
  end

  sig do
    type_parameters(:U)
      .params(rt_name: String, blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_rt_name(rt_name, &blk)
    previous = self.rt_name
    self.rt_name = rt_name
    blk.call
  ensure
    self.rt_name = T.must(previous)
  end
end

class MIRLoweringProgramState < T::Struct
  extend T::Sig

  FnSigMap = T.type_alias { T::Hash[T.any(String, Symbol), FunctionSignature] }
  ShardContext = T.type_alias { T.nilable(T::Hash[Symbol, String]) }
  FnNodeMap = T.type_alias { T::Hash[String, AST::FunctionDef] }

  prop :fn_sigs, FnSigMap, default: {}
  prop :shard_context, ShardContext, default: nil
  prop :emitted_extern_modules, T::Set[String], default: Set.new
  prop :pipeline_host, T.nilable(PipelineHost), default: nil
  prop :importer, T.nilable(ModuleImporter), default: nil
  prop :source_dir, T.nilable(String), default: nil
  prop :emitted_types, T::Set[String], default: Set.new
  prop :emitted_require_modules, T::Set[String], default: Set.new
  prop :debug_mode, T::Boolean, default: false
  prop :target, Symbol, default: :zig
  prop :used_sharded_map, T::Boolean, default: false
  prop :use_debug_allocator, T.nilable(T::Boolean), default: nil
  prop :fn_nodes, FnNodeMap, default: {}
end

class MIRLoweringCaptureState < T::Struct
  extend T::Sig

  CaptureMap = T.type_alias { T::Hash[String, String] }
  CaptureSymbols = T.type_alias { T::Hash[String, SymbolEntry] }

  prop :current_bg_pointer_captures, T.nilable(T::Set[String]), default: nil
  prop :current_fiber_capture_symbols, T.nilable(CaptureSymbols), default: nil
  prop :do_capture_map, T.nilable(CaptureMap), default: nil
  prop :current_stream_is_inf, T.nilable(T::Boolean), default: nil
  prop :current_stream_local, T.nilable(String), default: nil
  prop :current_fsm_inherited_alloc_names, T::Set[String], default: Set.new
  prop :current_fsm_inherited_guarded_names, T::Set[String], default: Set.new
  prop :current_fsm_owned_result_guards, T.nilable(T::Hash[String, String]), default: nil
  prop :last_fsm_result_transfer_facts, T::Array[MIR::FsmResultTransferFact], default: []
end

class MIRLoweringCapabilityState < T::Struct
  extend T::Sig

  prop :locked_unwrap_map, T.nilable(MIRLoweringCapabilities::LockedUnwrapMap), default: nil
  prop :rc_unwrap_map, T.nilable(MIRLoweringCapabilities::RcUnwrapMap), default: nil
  prop :with_alias_alloc_map, T.nilable(MIRLoweringCapabilities::AliasAllocMap), default: nil
  prop :with_alias_owner_map, T.nilable(MIRLoweringCapabilities::AliasOwnerMap), default: nil
  prop :atomic_emit_raw, T::Boolean, default: false
end

class MIRLoweringOwnershipState < T::Struct
  extend T::Sig

  prop :finalized_body_ids, T::Set[Integer], default: Set.new
  prop :finalized_node_ids, T::Set[Integer], default: Set.new
end

class MIRLoweringState < T::Struct
  extend T::Sig

  const :schemas, MIRLoweringSchemas
  const :counters, MIRLoweringCounters
  const :function_state, MIRLoweringFunctions::FunctionState
  const :runtime, MIRLoweringRuntimeState
  const :program, MIRLoweringProgramState
  const :capture, MIRLoweringCaptureState
  const :capabilities, MIRLoweringCapabilityState
  const :ownership, MIRLoweringOwnershipState
end
