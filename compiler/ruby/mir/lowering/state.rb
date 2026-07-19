# typed: strict
require "sorbet-runtime"
require "set"

require_relative "../mir"
require_relative "../../backends/mir_emitter"
require_relative "../lower/pipeline/pipeline_host"
require_relative "../../ast/ast"
require_relative "../../ast/symbol_entry"
require_relative "../../semantic/lifecycle_plan"
require_relative "../../compiler/module_importer"
require_relative "../lowering/counters"
require_relative "../lowering/schema_registry"
require_relative "../lowering/functions"
require_relative "../lowering/capabilities"

class MIRLoweringInput < T::Struct
  extend T::Sig

  FnSigMap = T.type_alias { T::Hash[T.any(String, Symbol), FunctionSignature] }
  MovedGuardInfo = T.type_alias { T::Hash[String, T::Hash[String, TrueClass]] }

  const :struct_schemas, T::Hash[Symbol, Schemas::StructSchema], factory: -> { {} }
  const :enum_schemas, T::Hash[Symbol, MIRLoweringSchemas::EnumVariants], factory: -> { {} }
  const :union_schemas, T::Hash[Symbol, Schemas::UnionSchema], factory: -> { {} }
  const :schema_lookup, T.nilable(MIRLoweringSchemas::SchemaLookup), default: nil
  const :lifecycle_registry, Semantic::LifecycleRegistry, factory: -> { Semantic::LifecycleRegistry.empty }
  const :fn_sigs, FnSigMap, factory: -> { {} }
  const :moved_guard_info, MovedGuardInfo, factory: -> { {} }
  const :importer, T.nilable(ModuleImporter), default: nil
  const :source_dir, T.nilable(String), default: nil
  const :debug_mode, T::Boolean, default: false
  const :target, Symbol, default: :zig
  const :function_counter_seeds, T::Hash[String, MIRLoweringCounterSnapshot], factory: -> { {} }
end

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
  ShardContextMap = T.type_alias { T::Hash[Symbol, String] }
  ShardContext = T.type_alias { T.nilable(ShardContextMap) }
  FnNodeMap = T.type_alias { T::Hash[String, AST::FunctionDef] }

  prop :fn_sigs, FnSigMap, factory: -> { {} }
  prop :shard_context, ShardContext, default: nil
  prop :emitted_extern_modules, T::Set[String], factory: -> { Set.new }
  prop :pipeline_host, T.nilable(PipelineHost), default: nil
  prop :importer, T.nilable(ModuleImporter), default: nil
  prop :source_dir, T.nilable(String), default: nil
  prop :emitted_types, T::Set[String], factory: -> { Set.new }
  prop :emitted_require_modules, T::Set[String], factory: -> { Set.new }
  prop :debug_mode, T::Boolean, default: false
  prop :target, Symbol, default: :zig
  prop :used_sharded_map, T::Boolean, default: false
  prop :use_debug_allocator, T.nilable(T::Boolean), default: nil
  prop :fn_nodes, FnNodeMap, factory: -> { {} }
  prop :function_counter_snapshots, T::Hash[String, MIRLoweringCounterSnapshot], factory: -> { {} }
end

class MIRLoweringCaptureState < T::Struct
  extend T::Sig

  CaptureMap = T.type_alias { T::Hash[String, String] }
  CaptureSymbols = T.type_alias { T::Hash[String, SymbolEntry] }

  prop :current_bg_pointer_captures, T.nilable(T::Set[String]), default: nil
  prop :current_fiber_capture_symbols, CaptureSymbols, factory: -> { {} }
  prop :do_capture_map, T.nilable(CaptureMap), default: nil
  prop :current_stream_is_inf, T.nilable(T::Boolean), default: nil
  prop :current_stream_local, T.nilable(String), default: nil
  prop :current_stream_close_label, T.nilable(String), default: nil
  prop :current_fsm_inherited_alloc_names, T::Set[String], factory: -> { Set.new }
  prop :current_fsm_inherited_guarded_names, T::Set[String], factory: -> { Set.new }
  prop :current_fsm_owned_result_guards, T::Hash[String, String], factory: -> { {} }
  prop :last_fsm_result_transfer_facts, T::Array[MIR::FsmResultTransferFact], default: []
end

class MIRLoweringCapabilityState < T::Struct
  extend T::Sig

  prop :locked_unwrap_map, T.nilable(MIRLoweringCapabilities::LockedUnwrapMap), default: nil
  prop :rc_unwrap_map, T.nilable(MIRLoweringCapabilities::RcUnwrapMap), default: nil
  prop :with_alias_alloc_map, T.nilable(MIRLoweringCapabilities::AliasAllocMap), default: nil
  prop :with_alias_owner_map, T.nilable(MIRLoweringCapabilities::AliasOwnerMap), default: nil
  prop :polymorphic_alias_type_map, T.nilable(MIRLoweringCapabilities::PolymorphicAliasTypeMap), default: nil
  # IF ... EXISTS AS aliases can be borrowed values or physical *T captures.
  # Keep semantic borrowing separate from runtime representation: list/map/set
  # reads usually capture T, pools and mutable struct-list reads capture *T.
  prop :if_bind_aliases, T::Set[String], factory: -> { Set.new }
  prop :if_bind_pointer_aliases, T::Set[String], factory: -> { Set.new }
  prop :atomic_emit_raw, T::Boolean, default: false
end

class MIRLoweringOwnershipState < T::Struct
  extend T::Sig

  prop :next_lowered_node_id, Integer, default: 0
  prop :finalized_body_ids, T::Set[MIR::LoweredBodyId], factory: -> { Set.new }
  prop :finalized_node_ids, T::Set[MIR::LoweredNodeId], factory: -> { Set.new }
end

class MIRLoweringTestState < T::Struct
  extend T::Sig

  ActiveStubs = T.type_alias { T::Hash[T.untyped, T.untyped] }

  prop :active_stubs, ActiveStubs, factory: -> { {} }
  prop :stub_label_counter, Integer, default: 0
end

class MIRLoweringState < T::Struct
  extend T::Sig

  const :input, MIRLoweringInput
  const :schemas, MIRLoweringSchemas
  const :counters, MIRLoweringCounters
  const :function_state, MIRLoweringFunctions::FunctionState
  const :runtime, MIRLoweringRuntimeState
  const :program, MIRLoweringProgramState
  const :capture, MIRLoweringCaptureState
  const :capabilities, MIRLoweringCapabilityState
  const :ownership, MIRLoweringOwnershipState
  const :test, MIRLoweringTestState
end
