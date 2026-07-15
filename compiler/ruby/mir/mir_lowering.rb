# typed: strict
# src/mir_lowering.rb - Lowers annotated AST (post-MIRPass) into MIR tree
#
# Pipeline: Parse -> Annotate -> MIRPass -> Lower -> Emit
#
# The lowering reads the annotated AST with marker nodes (Drop, AllocMark,
# SuppressCleanup, etc.) already inserted by MIRPass, and produces a
# complete MIR tree that the MIREmitter can emit to Zig.
#
# This pass subsumes the transpiler's visit_node dispatch. All type
# introspection and allocator resolution happens HERE, not in the emitter.

require "sorbet-runtime"
require "set"

require_relative "mir"
require_relative "cleanup_entry"
require_relative "../semantic/pass_state"
require_relative "placement"
require_relative "materialization"
require_relative "../semantic/capture_strategy"
require_relative "fiber_ctx_builder"
require_relative "../ast/ast"
require_relative "../ast/type"
require_relative "../compiler/entrypoint"
require_relative "../ast/async_result_shape"
require_relative "../ast/error_registry"
require_relative "../compiler/module_importer"
require_relative "../backends/zig_type_mapper"
require_relative "lower/pipeline/pipeline_host"
require_relative "lowering/counters"
require_relative "lowering/schema_registry"
require_relative "fsm_lowering"
require_relative "fsm_transform"
require_relative "thunk_transform"
require_relative "test_lowering"
require_relative "hoist"
require_relative "lowering/functions"
require_relative "lowering/capabilities"
require_relative "lowering/state"
require_relative "lowering/ownership_scanner"
require_relative "lowering/concurrency"
require_relative "lowering/expressions"
require_relative "lowering/literals"
require_relative "lowering/variables"
require_relative "lowering/control_flow"

class MIRLowering
    extend T::Sig
    include ThunkTransform::LoweringProtocol

  OwnershipFact = T.type_alias do
    T.any(
      MIR::OwnedCreate,
      MIR::OwnedDestroy,
      MIR::OwnedTransfer,
      MIR::OwnedBorrow,
      MIR::OwnedStore,
      MIR::OwnedReturn,
    )
  end
  TransferMark = T.type_alias { T.any(MIR::TransferMark, MIR::MoveMark) }
  FnSigMap = T.type_alias { T::Hash[T.any(String, Symbol), FunctionSignature] }
  LoweredMir = T.type_alias { T.any(MIR::Node, T::Array[MIR::Node]) }
  LowerableMarker = T.type_alias do
    T.any(
      MIR::Drop,
      MIR::AllocMark,
      MIR::SuppressCleanup,
      MIR::Return,
      MIR::ReassignCleanup,
      MIR::FieldCleanup,
    )
  end
  LowerableStmt = T.type_alias { T.any(AST::Node, LowerableMarker) }
  BackgroundDispatch = T.type_alias { T.any(Symbol, T::Boolean) }
  UnionVariantPayload = T.type_alias { T.nilable(T.any(Type::TypeInput, Schemas::InlineStructVariant)) }

  class AllocatingResultFact < T::Struct
    extend T::Sig

    const :name, String
    const :ownership_effect, MIR::OwnershipEffect
    const :type_info, Type
    const :scope, Symbol

    sig { returns(Symbol) }
    def alloc
      ownership_effect.alloc || :heap
    end

    sig { returns(MIR::AllocMark) }
    def alloc_mark
      MIR::AllocMark.new(name, alloc, type_info, scope)
    end
  end

  class DestinationPlacementPlan < T::Struct
    extend T::Sig

    const :action, Symbol
    const :type_info, T.nilable(Type)
    const :dest_alloc, T.nilable(Symbol)
    const :source_alloc, T.nilable(Symbol), default: nil

    sig { returns(T::Boolean) }
    def keep?
      action == :keep
    end

    sig { returns(T::Boolean) }
    def heap?
      dest_alloc == :heap
    end

    sig { params(lowering: MIRLowering, mir: MIR::Node, ast_node: AST::Node).returns(MIR::Node) }
    def place(lowering, mir, ast_node)
      return mir if keep?

      case action
      when :heap_indirect
        lowering.place_indirect_value_for_heap_destination(mir, T.must(type_info))
      when :cast_wrapped_or
        cast = T.cast(mir, MIR::Cast)
        placed = lowering.place_value_for_destination(cast.expr, ast_node, dest_alloc, type_info)
        MIR::Cast.new(placed, cast.target_type, cast.method)
      when :owned_orelse
        lowering.place_owned_orelse_for_destination(T.cast(mir, MIR::Orelse), T.must(type_info), T.must(dest_alloc))
      when :owned_try_catch
        lowering.place_owned_try_catch_for_destination(T.cast(mir, MIR::TryCatch), T.must(type_info), T.must(dest_alloc))
      when :owned_alloc_mismatch
        lowering.place_owned_alloc_mismatch_for_destination(mir, T.must(type_info), T.must(dest_alloc), T.must(source_alloc))
      when :owned_copy
        lowering.place_owned_branch_value_for_destination(mir, T.must(type_info), T.must(dest_alloc))
      when :string_or
        lowering.place_string_or_for_heap_destination(mir, T.cast(ast_node, AST::BinaryOp))
      when :string
        lowering.place_string_value_for_destination(mir, ast_node, T.must(dest_alloc))
      else
        raise "unknown destination placement action #{action.inspect}"
      end
    end
  end

  class DestinationSourceFact < T::Struct
    extend T::Sig

    const :borrowed, T::Boolean
    const :owner_transfer, T::Boolean
    const :heap_owned_result, T::Boolean

    sig { params(type_info: Type).returns(T::Boolean) }
    def needs_owned_copy?(type_info)
      type_info.ownership_bearing? && borrowed && !owner_transfer && !heap_owned_result
    end
  end

  class PipelineAllocMarkFact < T::Struct
    extend T::Sig

    const :alloc, Symbol
    const :mark, MIR::AllocMark
    const :cleanup_entry, T.nilable(CleanupEntry), default: nil
  end

  class OwnedSinkPlan < T::Struct
    extend T::Sig

    const :action, Symbol
    const :target_alloc, Symbol
    const :zig_type, T.nilable(String)
    const :copy_mode, T.nilable(Symbol)
    const :rc_func, T.nilable(String), default: nil
    const :source_slice_view, T::Boolean, default: false

    sig { returns(T::Boolean) }
    def keep?
      action == :keep
    end
  end

  class OwnedSinkSourceFact < T::Struct
    extend T::Sig

    const :source_alloc, T.nilable(Symbol)
    const :moved_without_copy, T::Boolean
    const :owned_parameter, T::Boolean
    const :needs_heap_create, T::Boolean
    const :same_alloc_verifiable, T::Boolean
    const :same_alloc_transfer_source, T::Boolean
    const :transfer_without_local_cleanup, T::Boolean
    const :already_owned_value, T::Boolean
    const :existing_owned_source, T::Boolean
    const :borrowed_union_sink, T::Boolean

	    sig { params(sink_alloc: Symbol, ti: Type).returns(T::Boolean) }
	    def satisfies_sink?(sink_alloc, ti)
      same_alloc = source_alloc == sink_alloc
      same_alloc_satisfies = same_alloc &&
                             ((moved_without_copy && (!ti.string? || !ti.rodata?)) ||
                              same_alloc_verifiable ||
                              same_alloc_transfer_source)
      same_alloc_satisfies || owned_parameter || needs_heap_create ||
	        transfer_without_local_cleanup || already_owned_value
	    end

	    sig { returns(T::Boolean) }
	    def satisfies_rc_sink?
	      moved_without_copy || owned_parameter || needs_heap_create || already_owned_value
	    end
	  end

  class LoweredStmtPacket < T::Struct
    const :mir, LoweredMir
    const :pending, T::Array[MIR::Node]
    const :stmt_transfer_marks, T::Array[MIR::Stmt]
    const :source_line, T.nilable(Integer)
    const :source_column, T.nilable(Integer)
  end

  class LoweredItemTarget < T::Struct
    const :items, T::Array[MIR::Node]
    const :line, T.nilable(Integer)
  end

  class LoweredModuleItems < T::Struct
    extend T::Sig

    const :items, T::Array[MIR::Emittable]
    const :type_items, T::Array[MIR::Emittable]

    sig { params(key: Symbol).returns(T::Array[MIR::Emittable]) }
    def [](key)
      case key
      when :items then items
      when :type_items then type_items
      else []
      end
    end
  end

  class UnionVariantLoweringFact < T::Struct
    extend T::Sig

    const :owner_name, String
    const :name, String
    const :data, UnionVariantPayload
    const :inline_struct, T::Boolean
    const :zig_type, String

    sig { returns(String) }
    def helper_name
      "#{owner_name}_#{name}"
    end
  end

  class OwnershipFinalizationContext < T::Struct
    const :inherited_alloc_names, T::Set[String]
    const :parent, T.nilable(OwnershipFinalizationContext), default: nil
    const :out, T::Array[MIR::Node]
    const :guarded_cleanup_names, T::Set[String]
    const :alloc_marks, T::Hash[String, MIR::AllocMark]
    const :body_alloc_mark_names, T::Set[String]
    const :transfer_mark_names, T::Set[String]
    const :body_transfer_mark_names, T::Set[String]
    const :move_mark_names, T::Set[String]
    const :cleanup_by_name, T::Hash[String, T.any(MIR::Cleanup, MIR::ErrCleanup)]
  end

  class LoweredBodyConstruction < T::Struct
    const :packets, T::Array[LoweredStmtPacket]
    const :finalization_context, OwnershipFinalizationContext
  end

  class OwnershipFactTarget < T::Struct
    const :name, String
    const :expr, MIR::Node
    const :type_info, T.nilable(Type)
    const :include_owned_result, T::Boolean
    const :include_transfer_contract, T::Boolean
  end

  class OwnershipTransferTarget < T::Struct
    const :name, String
    const :target, Symbol
    const :target_alloc, T.nilable(Symbol)
  end

  class OwnershipSurfaceScan < T::Struct
    extend T::Sig

    const :facts, T::Array[OwnershipFact]
    const :transfer_targets, T::Array[OwnershipTransferTarget]
  end

  include ZigTypeMapper
  include FsmLowering
  include TestLowering
  include MIRHoistLowering
  include MIRLoweringFunctions
  include MIRLoweringCapabilities
  include MIRLoweringConcurrency
  include MIRLoweringExpressions
  include MIRLoweringLiterals
  include MIRLoweringVariables
  include MIRLoweringControlFlow

  sig { returns(MIRLoweringProgramState::FnSigMap) }
  def fn_sigs
    program_state.fn_sigs
  end

  sig { returns(MIRLoweringProgramState::ShardContext) }
  def shard_context
    program_state.shard_context
  end

  sig { params(context: MIRLoweringProgramState::ShardContext).returns(MIRLoweringProgramState::ShardContext) }
  def shard_context=(context)
    program_state.shard_context = context
  end

  sig { params(type_info: T.nilable(Type::TypeInput)).returns(T::Boolean) }
  def ast_void_type?(type_info)
    return true if type_info.nil? || type_info == :Void
    ti = Type.from_node(type_info)
    ti ? ti.void? : false
  end

  sig { returns(T.nilable(MIRLoweringFunctions::FunctionLoweringContext)) }
  def current_function_context
    function_state.current_function_context
  end

  sig { returns(T::Boolean) }
  def current_function_has_rt?
    current_function_context&.has_rt == true
  end

  sig { returns(T::Boolean) }
  def current_function_has_catch?
    current_function_context&.has_catch == true
  end

  sig { returns(T::Boolean) }
  def current_function_heap_carry_return?
    current_function_context&.heap_carry_return == true
  end

  sig { returns(T::Boolean) }
  def current_function_tail_call?
    current_function_context&.tail_call == true
  end

  sig { params(name: String).returns(T::Boolean) }
  def current_function_param_name?(name)
    current_function_context&.param_names&.include?(name) == true
  end

  sig { params(name: String).returns(T::Boolean) }
  def current_function_takes_param_name?(name)
    current_function_context&.takes_param_names&.include?(name) == true
  end

  sig { params(name: String).returns(T::Boolean) }
  def current_function_collection_param?(name)
    current_function_context&.collection_params&.include?(name) == true
  end

  sig { params(name: String).returns(T::Boolean) }
  def current_function_mutable_scalar_param?(name)
    current_function_context&.mutable_scalar_params&.include?(name) == true
  end

  sig { params(name: String).returns(T::Boolean) }
  def current_function_heap_carry_return_var?(name)
    current_function_context&.heap_carry_return_vars&.include?(name) == true
  end

  sig { returns(T.nilable(String)) }
  def current_function_return_payload_zig
    current_function_context&.return_payload_zig
  end

  sig { returns(T.nilable(Type)) }
  def current_function_return_type
    current_function_context&.return_type
  end

  sig { returns(MIRLoweringFunctions::NameSet) }
  def current_function_snapshot_types
    current_function_context&.snapshot_types || Set.new
  end

  sig { returns(T.nilable(String)) }
  def current_function_zig_name
    current_function_context&.zig_name
  end

  sig { params(name: T.any(String, Symbol), bang_alias: T::Boolean).returns(T.nilable(FunctionSignature)) }
  def fn_sig_for(name, bang_alias: false)
    sigs = fn_sigs
    sig = sigs.dig(name) || sigs.dig(name.to_sym) || sigs.dig(name.to_s)
    sig ||= sigs.dig("#{name}!") if bang_alias
    FunctionSignature.unwrap(sig)
  end

  sig { params(input: MIRLoweringInput).void }
  def initialize(input: MIRLoweringInput.new)
    @state = T.let(
      MIRLoweringState.new(
        input: input,
        schemas: MIRLoweringSchemas.new(
          struct_schemas: input.struct_schemas,
          enum_schemas: input.enum_schemas,
          union_schemas: input.union_schemas,
        ),
        counters: MIRLoweringCounters.new,
        function_state: MIRLoweringFunctions::FunctionState.new,
        runtime: MIRLoweringRuntimeState.new,
        program: MIRLoweringProgramState.new(
          fn_sigs: input.fn_sigs.dup,
          importer: input.importer,
          source_dir: input.source_dir,
          debug_mode: input.debug_mode,
          target: input.target,
        ),
        capture: MIRLoweringCaptureState.new,
        capabilities: MIRLoweringCapabilityState.new,
        ownership: MIRLoweringOwnershipState.new,
        test: MIRLoweringTestState.new,
      ),
      MIRLoweringState,
    )
  end

  sig { returns(MIRLoweringState) }
  def lowering_state
    @state
  end

  sig { returns(MIRLoweringInput) }
  def lowering_input
    lowering_state.input
  end

  sig { returns(MIRLoweringProgramState) }
  def program_state
    lowering_state.program
  end

  sig { returns(MIRLoweringRuntimeState) }
  def runtime_state
    lowering_state.runtime
  end

  sig { returns(MIRLoweringCaptureState) }
  def capture_state
    lowering_state.capture
  end

  sig { returns(MIRLoweringCapabilityState) }
  def capability_state
    lowering_state.capabilities
  end

  sig { returns(MIRLoweringOwnershipState) }
  def ownership_state
    lowering_state.ownership
  end

  sig { returns(MIRLoweringTestState) }
  def test_state
    lowering_state.test
  end

  sig { returns(MIRLoweringSchemas::SchemaLookup) }
  def mir_schema_lookup
    lowering_schemas.lookup_proc
  end

  sig { params(lookup_proc: MIRLoweringSchemas::SchemaLookup).void }
  def replace_mir_schema_lookup!(lookup_proc)
    lowering_schemas.replace_lookup_proc!(lookup_proc)
  end

  sig { returns(MIRLoweringSchemas) }
  def lowering_schemas
    lowering_state.schemas
  end

  sig { returns(T::Hash[Symbol, Schemas::StructSchema]) }
  def struct_schemas
    lowering_schemas.struct_schemas
  end

  sig { returns(T::Hash[Symbol, MIRLoweringSchemas::EnumVariants]) }
  def enum_schemas
    lowering_schemas.enum_schemas
  end

  sig { returns(T::Hash[Symbol, Schemas::UnionSchema]) }
  def union_schemas
    lowering_schemas.union_schemas
  end

  sig { returns(MIRLoweringCounters) }
  def lowering_counters
    lowering_state.counters
  end

  sig { returns(MIRLoweringFunctions::FunctionState) }
  def function_state
    lowering_state.function_state
  end

  sig { returns(Symbol) }
  def lowering_target
    program_state.target
  end

  sig { returns(T::Boolean) }
  def bc_target?
    lowering_target == :bc
  end

  sig { returns(String) }
  def runtime_binding_name
    runtime_state.rt_name
  end

  sig { returns(Integer) }
  def next_pipeline_observable_id
    lowering_counters.next_background_block_id.value
  end

  sig { returns(Symbol) }
  def pipeline_result_alloc
    function_state.current_decl_or_frame_alloc
  end

  sig { params(name: String).returns(T::Boolean) }
  def pipeline_guarded_cleanup_name?(name)
    function_state.guarded_cleanup_names[name] == true
  end

  sig { params(name: String).returns(T::Boolean) }
  def lowered_guarded_cleanup_name?(name)
    function_state.lowered_guarded_cleanup_names.include?(name)
  end

  sig do
    type_parameters(:U)
      .params(rt_name: String, blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_runtime_binding_name(rt_name, &blk)
    runtime_state.with_rt_name(rt_name, &blk)
  end

  sig { returns(MIRLoweringGeneratedId) }
  def next_stream_literal_id
    lowering_counters.next_stream_literal_id
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node, dest_alloc: T.nilable(Symbol), dest_type: T.nilable(Type::TypeInput)).returns(MIR::Node) }
  def place_value_for_destination(mir, ast_node, dest_alloc, dest_type = nil)
    plan = destination_placement_plan(mir, ast_node, dest_alloc, dest_type)
    plan.place(self, mir, ast_node)
  end

  sig { params(value: MIR::Node, destination: Type, source_node: AST::Node).returns(MIR::MethodCall) }
  def node_create_mir(value, destination, source_node)
    payload = T.must(destination.node_payload_type)
    zig_type = transpile_type(payload.resolved.to_s)
    shared = destination.shared_node?
    function_state.node_store_types << zig_type unless shared
    store = node_store_type_mir(zig_type, shared: shared)
    call = MIR::MethodCall.new(
      store,
      "createBound",
      [MIR::Ident.new(node_store_binding_name(zig_type, shared: shared)), value],
      true,
      MIR::CallableContract.no_ownership(2),
    )
    call.result_type = Type.new(destination)
    T.cast(with_ownership_consumption_for_value(
      call,
      value,
      source_node,
      shared ? "SharedNodeStore.createBound" : "NodeStore.createBound",
      target_alloc: :heap,
    ), MIR::MethodCall)
  end

  # NodeStore is a comptime Zig type factory. Keep the application structural
  # in MIR so identifiers remain identifiers rather than encoded expressions.
  sig { params(zig_type: String, shared: T::Boolean).returns(MIR::Call) }
  def node_store_type_mir(zig_type, shared: false)
    MIR::Call.new(
      shared ? "CheatLib.SharedNodeStore" : "CheatLib.NodeStore",
      [MIR::Ident.new(zig_type)],
      false,
      false,
      MIR::CallableContract.no_ownership(1),
    )
  end

  sig { params(nodes: T::Array[MIR::Node], include_bodies: T::Boolean).returns(T::Array[String]) }
  def shared_node_store_types_in_mir(nodes, include_bodies: true)
    found = T.let(Set.new, T::Set[String])
    pending = T.let(nodes.dup, T::Array[MIR::Node])
    until pending.empty?
      node = T.must(pending.pop)
      if node.is_a?(MIR::MethodCall) && node.receiver.is_a?(MIR::Call) &&
          T.cast(node.receiver, MIR::Call).callee == "CheatLib.SharedNodeStore"
        arg = T.cast(node.receiver, MIR::Call).args.first
        found << arg.name if arg.is_a?(MIR::Ident)
      end
      if node.is_a?(MIR::Emittable)
        node.child_exprs.each { |child| pending << child if child.is_a?(MIR::Emittable) }
        # ScopeBlock/BlockExpr bodies are the current statement's inline
        # evaluation, not nested control-flow statements. Traverse those so a
        # field assignment's cleanup+set pair shares one guard. Do not descend
        # into While/If/etc.; their bodies are guarded when lowered.
        if include_bodies || node.is_a?(MIR::ScopeBlock) || node.is_a?(MIR::BlockExpr)
          node.body_slots.each { |slot| slot.body.each { |child| pending << child } }
        end
      end
    end
    found.to_a.sort
  end

  sig { params(stmt: LowerableStmt, nodes: T::Array[MIR::Node]).returns(T::Array[MIR::Node]) }
  def guard_shared_node_statement(stmt, nodes)
    # Nested bodies are lowered and guarded statement-by-statement. Looking
    # through them here would hold an outer guard across an entire loop/branch
    # and then emit a second same-named guard inside the body.
    types = shared_node_store_types_in_mir(nodes, include_bodies: false)
    return nodes if types.empty?

    write = stmt.is_a?(AST::Assignment) || stmt.is_a?(AST::MethodCall) ||
      nodes.any? { |node| shared_node_write_mir?(node) }
    lock_method = write ? "lockWrite" : "lockRead"
    unlock_method = write ? "unlockWrite" : "unlockRead"
    prefix = T.let([], T::Array[MIR::Node])
    types.each do |zig_type|
      store = node_store_type_mir(zig_type, shared: true)
      binding = node_store_binding_name(zig_type, shared: true)
      prefix << MIR::Let.new(
        binding,
        MIR::MethodCall.new(
          store,
          lock_method,
          [MIR::Ident.new(runtime_binding_name)],
          true,
          MIR::CallableContract.no_ownership(1),
        ),
        false,
        nil,
        nil,
      )
      prefix << MIR::DeferStmt.new(MIR::MethodCall.new(
        store,
        unlock_method,
        [MIR::Ident.new(binding)],
        false,
        MIR::CallableContract.no_ownership(1),
      ))
    end

    access_nodes = nodes.select do |node|
      !shared_node_store_types_in_mir([node], include_bodies: false).empty?
    end
    if access_nodes.length == 1 && access_nodes.first.is_a?(MIR::Let)
      binding = T.cast(access_nodes.first, MIR::Let)
      label = "__shared_node_access_#{lowering_counters.next_tmp_id}"
      original_init = binding.init
      body = T.let(prefix, T::Array[MIR::Node])
      if mir_allocates?(original_init)
        value_name = "__shared_node_value_#{lowering_counters.next_tmp_id}"
        value_type = if original_init.respond_to?(:result_type) && T.unsafe(original_init).result_type
          Type.new(T.unsafe(original_init).result_type)
        else
          binding.annotation || Type.new(:Any)
        end
        value_alloc = mir_owned_alloc(original_init) || :heap
        materialized = MIR::BindingMaterialization.new(
          name: value_name,
          expr: original_init,
          alloc: value_alloc,
          type_info: value_type,
          mutable: false,
        )
        body.concat(materialized.statements)
        body.concat(ownership_transfer_marks(value_name, :block_result, target_alloc: value_alloc))
        body << MIR::BreakStmt.new(label, MIR::Ident.new(value_name))
      else
        body << MIR::BreakStmt.new(label, original_init)
      end
      block = MIR::BlockExpr.new(label, body)
      block.result_type = T.unsafe(original_init).result_type if original_init.respond_to?(:result_type)
      binding.init = block
      return nodes
    end

    [MIR::ScopeBlock.new(prefix + nodes)]
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def shared_node_write_mir?(node)
    if node.is_a?(MIR::MethodCall) && node.receiver.is_a?(MIR::Call) &&
        T.cast(node.receiver, MIR::Call).callee == "CheatLib.SharedNodeStore"
      return true if ["createBound", "removeBound"].include?(node.method)
    end
    return false unless node.is_a?(MIR::Emittable)

    node.child_exprs.any? { |child| child.is_a?(MIR::Emittable) && shared_node_write_mir?(child) } ||
      node.body_slots.any? { |slot| slot.body.any? { |child| shared_node_write_mir?(child) } }
  end

  # Optional @node values use NodeRef's zero handle as NIL so they remain a
  # compact four-byte value. Every other optional uses Zig's native null.
  sig { params(type: Type).returns(MIR::Node) }
  def optional_nil_mir(type)
    if type.node_reference?
      MIR::StructInit.new(type.zig_type, [])
    else
      # Zig peer-type resolution does not infer a typed optional from a bare
      # `else null` when the success arm yields slices and other pointer-like
      # values. Preserve the annotated CLEAR optional type explicitly.
      optional_type = type.optional? ? type : Type.optional_of(type)
      MIR::Cast.new(MIR::Lit.new("null"), optional_type.zig_type, :as)
    end
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node, dest_alloc: T.nilable(Symbol), dest_type: T.nilable(Type::TypeInput)).returns(DestinationPlacementPlan) }
  def destination_placement_plan(mir, ast_node, dest_alloc, dest_type)
    return destination_keep_plan(dest_alloc) unless dest_alloc

    ti = destination_type(ast_node, dest_type)
    return DestinationPlacementPlan.new(action: :heap_indirect, type_info: ti, dest_alloc: dest_alloc) if MIR::Placement.heap?(dest_alloc) && heap_indirect_destination?(mir, ast_node, ti)
    return DestinationPlacementPlan.new(action: :cast_wrapped_or, type_info: ti, dest_alloc: dest_alloc) if cast_wrapped_or?(mir, ast_node)
    return destination_keep_plan(dest_alloc) if borrowed_string_destination?(ast_node, ti, dest_alloc)
    return DestinationPlacementPlan.new(action: :owned_orelse, type_info: ti, dest_alloc: dest_alloc) if owned_or_destination?(mir, ast_node, ti, MIR::Orelse)
    return DestinationPlacementPlan.new(action: :owned_try_catch, type_info: ti, dest_alloc: dest_alloc) if owned_or_destination?(mir, ast_node, ti, MIR::TryCatch)
    source_alloc = mir_owned_alloc(mir)
    return destination_keep_plan(dest_alloc) if heap_owned_async_boundary_destination?(mir, ast_node, dest_alloc, ti)
    if source_alloc && source_alloc != dest_alloc && ownership_bearing_type?(ti)
      return DestinationPlacementPlan.new(action: :owned_alloc_mismatch, type_info: ti, dest_alloc: dest_alloc, source_alloc: source_alloc)
    end
    source = destination_source_fact(mir, ast_node)
    needs_recursive_copy = ownership_bearing_type?(ti) && source.borrowed && !source.owner_transfer && !source.heap_owned_result
    return DestinationPlacementPlan.new(action: :owned_copy, type_info: ti, dest_alloc: dest_alloc) if source.needs_owned_copy?(ti) || needs_recursive_copy
    return DestinationPlacementPlan.new(action: :string_or, type_info: ti, dest_alloc: dest_alloc) if ti.string? && or_binary?(ast_node)
    return destination_keep_plan(dest_alloc) if ti.symbol?
    return DestinationPlacementPlan.new(action: :string, type_info: ti, dest_alloc: dest_alloc) if ti.string?

    destination_keep_plan(dest_alloc)
  end

  sig { params(dest_alloc: T.nilable(Symbol)).returns(DestinationPlacementPlan) }
  def destination_keep_plan(dest_alloc)
    DestinationPlacementPlan.new(action: :keep, type_info: nil, dest_alloc: dest_alloc)
  end

  sig { params(ast_node: AST::Node, dest_type: T.nilable(Type::TypeInput)).returns(Type) }
  def destination_type(ast_node, dest_type)
    ti = dest_type || Type.from_node!(ast_node, context: "destination placement type")
    ti.is_a?(Type) ? ti : Type.new(ti)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def or_binary?(node)
    node.is_a?(AST::BinaryOp) && (node.op == :OR_ELSE || node.op == :OR)
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node).returns(DestinationSourceFact) }
  def destination_source_fact(mir, ast_node)
    node = destination_source_node(ast_node)
    DestinationSourceFact.new(
      borrowed: borrowed_destination_node?(node),
      owner_transfer: owner_transfer_node?(node),
      heap_owned_result: heap_owned_result?(mir, node),
    )
  end

  sig { params(node: AST::Node).returns(AST::Node) }
  def destination_source_node(node)
    node.is_a?(AST::BinaryOp) && or_binary?(node) ? node.left : node
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def borrowed_destination_node?(node)
    node.is_a?(AST::GetField) || node.is_a?(AST::GetIndex)
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def owner_transfer_node?(node)
    return false if AST.container_borrow?(node)
    return true if AST.moved?(node)
    return true if node.is_a?(AST::GetField) && node.indirect_field == true
    return Type.indirect_type?(node.full_type!(context: "owner transfer source")) if node.is_a?(AST::GetField)

    false
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node).returns(T::Boolean) }
  def cast_wrapped_or?(mir, ast_node)
    !!(mir.is_a?(MIR::Cast) && or_binary?(ast_node))
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node, ti: Type).returns(T::Boolean) }
  def heap_indirect_destination?(mir, ast_node, ti)
    return false unless ti.indirect? && !ti.any_sync? && ti.ownership == :affine
    return false if mir.is_a?(MIR::HeapCreate)

    source_t = Type.from_node!(ast_node, context: "heap indirect destination source")
    !Type.indirect_type?(source_t)
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node, ti: Type, mir_class: T.untyped).returns(T::Boolean) }
  def owned_or_destination?(mir, ast_node, ti, mir_class)
    or_binary?(ast_node) && ownership_bearing_type?(ti) && mir.is_a?(mir_class)
  end

  sig { params(ast_node: AST::Node, ti: Type, dest_alloc: T.nilable(Symbol)).returns(T::Boolean) }
  def borrowed_string_destination?(ast_node, ti, dest_alloc)
    ti.string? && !MIR::Placement.heap?(dest_alloc) && AST.container_borrow?(ast_node)
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node, dest_alloc: Symbol, type_info: Type).returns(T::Boolean) }
  def heap_owned_async_boundary_destination?(mir, ast_node, dest_alloc, type_info)
    return false unless MIR::Placement.frame?(dest_alloc)
    return false unless ast_node.is_a?(AST::BgBlock)

    source_type = Type.from_node!(ast_node, context: "async boundary destination")
    return false unless type_info.single_future? || source_type.single_future?

    effect = MIR::OwnershipEffect.of(mir)
    (effect.produces_owned && MIR::Placement.heap?(effect.alloc)) == true
  end

  sig { params(mir: MIR::Node, ti: Type).returns(MIR::Node) }
  def place_indirect_value_for_heap_destination(mir, ti)
    with_ownership_consumption(
      MIR::HeapCreate.new(transpile_type(ti.resolved.to_s), mir, :heap, "blk"),
      mir_ident_names(mir),
      "MIR::HeapCreate",
      target_alloc: :heap,
    )
  end

  sig { params(mir: MIR::Orelse, ti: Type, dest_alloc: Symbol).returns(MIR::IfOptional) }
  def place_owned_orelse_for_destination(mir, ti, dest_alloc)
    tmp_id = lowering_counters.next_tmp_id
    capture = "__or_val_#{tmp_id}"
    left = place_owned_branch_value_for_destination(MIR::Ident.new(capture), ti, dest_alloc)
    right = place_owned_branch_value_for_destination(mir.fallback, ti, dest_alloc)
    out = MIR::IfOptional.new(mir.expr, capture, left, right)
    out.result_type = Type.new(ti)
    out
  end

  sig { params(mir: MIR::TryCatch, ti: Type, dest_alloc: Symbol).returns(MIR::Node) }
  def place_owned_try_catch_for_destination(mir, ti, dest_alloc)
    right = place_owned_branch_value_for_destination(mir.catch_body, ti, dest_alloc)
    right = owned_branch_result_value(right, ti, dest_alloc) if mir_allocates?(right)
    source_alloc = mir_owned_alloc(mir.expr) || mir_owned_alloc(mir)
    if source_alloc && source_alloc != dest_alloc
      tmp_id = lowering_counters.next_tmp_id
      label = "__try_place_#{tmp_id}"
      success = "__try_val_#{tmp_id}"
      catch_break = MIR::BreakExpr.new(label, right)
      success_try = MIR::TryCatch.new(mir.expr, catch_break, mir.capture)
      success_try.result_type = Type.new(ti)
      success_cleanup = CleanupEntry.build(:uniform, alloc: source_alloc, has_moved_guard: false)
      build_drop_entry!(success_cleanup, ti, nil)
      materialized = MIR::BindingMaterialization.new(
        name: success,
        expr: success_try,
        alloc: source_alloc,
        type_info: ti,
        mutable: false,
        cleanup_entry: success_cleanup
      )
      body = materialized.statements
      body << MIR::BreakStmt.new(label, place_owned_branch_value_for_destination(MIR::Ident.new(success), ti, dest_alloc))
      out_block = MIR::BlockExpr.new(label, body)
      out_block.result_type = Type.new(ti)
      return out_block
    end

    out = MIR::TryCatch.new(mir.expr, right, mir.capture)
    out.result_type = Type.new(ti)
    out
  end

  sig { params(mir: MIR::Node, ti: Type, dest_alloc: Symbol).returns(MIR::BlockExpr) }
  def owned_branch_result_value(mir, ti, dest_alloc)
    tmp_id = lowering_counters.next_tmp_id
    label = "__owned_branch_#{tmp_id}"
    name = "__owned_branch_val_#{tmp_id}"
    materialized = MIR::BindingMaterialization.new(
      name: name,
      expr: mir,
      alloc: dest_alloc,
      type_info: ti,
      mutable: false
    )
    body = T.let(materialized.statements, T::Array[MIR::Stmt])
    body.concat(ownership_transfer_marks(name, :block_result, target_alloc: dest_alloc))
    body << MIR::BreakStmt.new(label, MIR::Ident.new(name))
    out = MIR::BlockExpr.new(label, body)
    out.result_type = Type.new(ti)
    out
  end

  sig { params(mir: MIR::Node, ti: Type, dest_alloc: Symbol, source_alloc: Symbol).returns(MIR::BlockExpr) }
  def place_owned_alloc_mismatch_for_destination(mir, ti, dest_alloc, source_alloc)
    tmp_id = lowering_counters.next_tmp_id
    label = "__owned_place_#{tmp_id}"
    name = "__owned_val_#{tmp_id}"
    cleanup = CleanupEntry.build(:uniform, alloc: source_alloc, has_moved_guard: false)
    build_drop_entry!(cleanup, ti, nil)
    materialized = MIR::BindingMaterialization.new(
      name: name,
      expr: mir,
      alloc: source_alloc,
      type_info: ti,
      mutable: false,
      cleanup_entry: cleanup
    )
    body = materialized.statements
    body << MIR::BreakStmt.new(label, place_owned_branch_value_for_destination(MIR::Ident.new(name), ti, dest_alloc))
    out = MIR::BlockExpr.new(label, body)
    out.result_type = Type.new(ti)
    out
  end

  sig { params(mir: MIR::Node, ast_node: AST::BinaryOp).returns(MIR::Node) }
  def place_string_or_for_heap_destination(mir, ast_node)
    left_t = Type.from_node!(ast_node.left, context: "string OR destination left")
    return place_string_value_for_heap_destination(mir, ast_node) if left_t.optional?

    case mir
    when MIR::TryCatch
      return place_string_value_for_heap_destination(mir, ast_node) unless heap_owned_result?(mir.expr, ast_node.left)

      left = place_or_branch_value_for_destination(mir.expr, ast_node.left)
      right = place_or_branch_value_for_destination(mir.catch_body, ast_node.right)
      out = MIR::TryCatch.new(left, right, mir.capture)
      out.result_type = Type.from_node!(ast_node, context: "string OR destination result")
      out
    when MIR::Orelse
      left = place_or_branch_value_for_destination(mir.expr, ast_node.left)
      right = place_or_branch_value_for_destination(mir.fallback, ast_node.right)
      out = MIR::Orelse.new(left, right)
      out.result_type = Type.from_node!(ast_node, context: "string OR destination result")
      out
    else
      place_string_value_for_heap_destination(mir, ast_node)
    end
  end

  sig { params(mir: MIR::Node, dst_ti: Type, dest_alloc: Symbol).returns(MIR::Node) }
  def place_owned_branch_value_for_destination(mir, dst_ti, dest_alloc)
    owned_alloc = mir_owned_alloc(mir)
    return mir if owned_alloc == dest_alloc
    return place_owned_alloc_mismatch_for_destination(mir, dst_ti, dest_alloc, owned_alloc) if owned_alloc
    return MIR::DupeSlice.new(mir, dest_alloc) if dst_ti.string?
    if dst_ti.any_rc?
      return MIR::RcRetain.new(mir, rc_payload_zig_type(dst_ti), dst_ti.shared? ? "arcRetain" : "rcRetain")
    end

    MIR::DeepCopy.new(mir, dst_ti.zig_type, nil, :full_value, dest_alloc)
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node).returns(MIR::Node) }
  def place_or_branch_value_for_destination(mir, ast_node)
    placed = place_string_value_for_heap_destination(mir, ast_node)
    return placed unless mir_allocates?(placed)

    scoped_owning_branch_value(placed, ast_node)
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node).returns(MIR::Node) }
  def place_string_value_for_heap_destination(mir, ast_node)
    return mir if heap_owned_result?(mir, ast_node)

    mir = MIR::TryExpr.new(mir) if Type.from_node!(ast_node, context: "heap destination placement").error_union?
    MIR::DupeSlice.new(mir, :heap)
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node, dest_alloc: Symbol).returns(MIR::Node) }
  def place_string_value_for_destination(mir, ast_node, dest_alloc)
    effect = MIR::OwnershipEffect.of(mir)
    if effect.produces_owned
      source_alloc = effect.alloc
      return mir if source_alloc == dest_alloc
      return place_owned_alloc_mismatch_for_destination(mir, Type.from_node!(ast_node, context: "string destination placement"), dest_alloc, source_alloc) if source_alloc
    end

    return place_string_value_for_heap_destination(mir, ast_node) if MIR::Placement.heap?(dest_alloc)

    mir = MIR::TryExpr.new(mir) if Type.from_node!(ast_node, context: "string destination placement").error_union?
    MIR::DupeSlice.new(mir, dest_alloc)
  end

  sig { params(type_info: T.nilable(Type)).returns(T.nilable(Symbol)) }
  def escaping_value_alloc(type_info)
    ti = type_info&.success_type
    return :heap if ti && ownership_bearing_type?(ti)
    nil
  end

  sig { params(value: MIR::Node).returns(MIR::Call) }
  def active_tag_call(value)
    MIR::Call.new("std.meta.activeTag", [value], false, false, MIR::CallableContract.no_ownership(1))
  end

  sig { params(expr: MIR::Node, ast_node: AST::Node, context: String).returns(Type) }
  def alloc_mark_type_info(expr, ast_node, context)
    ti = Type.from_node!(ast_node, context: context)
    return ti unless expr.is_a?(MIR::DeepCopy) && expr.zig_type.to_s.start_with?("*")
    return ti if ti.heap_ptr?

    Type.new(ti, layout: :indirect)
  end

  sig { params(node: AST::ReturnNode).returns(T.nilable(Symbol)) }
  def return_destination_alloc(node)
    return nil unless node.value

    value_type = Type.from_node!(node.value, context: "return destination allocation")
    declared_type = return_value_destination_type(node)
    if current_function_heap_carry_return?
      return :heap if declared_type && ownership_bearing_type?(declared_type.success_type || declared_type)
      return escaping_value_alloc(value_type)
    end

    borrowed_owned = ownership_bearing_type?(value_type.success_type || value_type) ||
      (declared_type && ownership_bearing_type?(declared_type.success_type || declared_type))
    return :heap if borrowed_destination_node?(node.value) && borrowed_owned

    nil
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node).returns(MIR::BlockExpr) }
  def scoped_owning_branch_value(mir, ast_node)
    block_id = lowering_counters.next_block_expr_id
    tmp_id = lowering_counters.next_tmp_id
    label = "__own_branch_#{block_id}"
    name = "__tmp_#{tmp_id}"
    type_info = alloc_mark_type_info(mir, ast_node, "branch ownership placement")
    entry = hoist_cleanup_entry(mir, ast_node)
    if entry
      entry.mark_moved_guard!
    end
    materialized = MIR::BindingMaterialization.new(
      name: name,
      expr: mir,
      alloc: :heap,
      type_info: type_info,
      mutable: false,
      cleanup_entry: entry,
      cleanup_mode: entry ? :err : :normal,
      scope: :heap
    )
    body = T.let(materialized.statements, T::Array[MIR::Stmt])
    if entry
      body.concat(ownership_transfer_marks(name, :block_result, move_guarded: true))
    end
    body << MIR::BreakStmt.new(label, MIR::Ident.new(name))
    out = MIR::BlockExpr.new(label, body)
    out.result_type = type_info
    out
  end

  sig { params(mir: MIR::Node, ast_node: AST::Node).returns(T::Boolean) }
  def heap_owned_result?(mir, ast_node)
    effect = MIR::OwnershipEffect.of(mir)
    return true if effect.produces_owned && MIR::Placement.heap?(effect.alloc)

    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    if node.is_a?(AST::Identifier) && AST.moved?(ast_node)
      return placement_for_node(node) == :heap
    end
    !!(node.is_a?(AST::Identifier) && node.symbol&.heap_storage? == true)
  end

  # Lower an AST node (or old MIR node) into a new MIR node.
  sig { params(node: LowerableStmt).returns(T.untyped) }
  def lower(node)
    mir = case node

    # --- Top-level ---
    when AST::Program           then lower_program(node)

    # --- Marker nodes from MIRPass ---
    when MIR::Drop              then lower_drop(node)
    when MIR::AllocMark
      function_state.lowered_alloc_names.add(node.name.to_s)
      node
    when MIR::SuppressCleanup
      safe = zig_safe_name(node.name)
      if pipeline_guarded_cleanup_name?(safe)
        ownership_transfer_marks(safe, :owned_sink, target_alloc: :heap, move_guarded: true)
      else
        []
      end
    when MIR::Return
      rename_map = function_state.rename_map
      escaped = node.escaped_vars.map do |name|
        escaped_safe_name = zig_safe_name(name)
        rename_map[escaped_safe_name] || escaped_safe_name
      end
      MIR::ReturnMark.new(escaped)
    when MIR::ReassignCleanup   then MIR::ReassignMark.new(node.name, node.alloc)
    when MIR::FieldCleanup      then MIR::FieldCleanupMark.new(node.target_name, node.field, node.alloc)

    # --- Type definitions ---
    when AST::EnumDef           then lower_enum_def(node)
    when AST::UnionDef          then lower_union_def(node)
    when AST::StructDef         then lower_struct_def(node)
    when AST::ExternFnDecl      then lower_extern_fn(node)
    when AST::ExternStructDecl  then lower_extern_struct(node)

    # --- Declarations & assignments ---
    when AST::VarDecl           then lower_var_decl(node)
    when AST::BindExpr          then lower_bind_expr(node)
    when AST::Assignment        then lower_assignment(node)
    when AST::DestructuringAssignment then lower_destructuring_assignment(node)

    # --- Control flow ---
    when AST::IfStatement       then lower_if(node)
    when AST::IsA               then lower_is_a(node)
    when AST::IfBind            then lower_if_bind(node)
    when AST::WhileLoop         then lower_while(node)
    when AST::WhileBindLoop     then lower_while_bind(node)
    when AST::ForEach           then lower_for_each(node)
    when AST::ForRange          then lower_for_range(node)
    when AST::MatchStatement    then lower_match(node)
    when AST::ReturnNode        then lower_return(node)
    when AST::BreakNode, AST::OrElseBreak then MIR::BreakStmt.new(nil, nil)
    when AST::ContinueNode      then MIR::ContinueStmt.new(nil)
    when AST::PassStmt          then MIR::Noop.new("pass")

    # --- Functions & calls ---
    when AST::FunctionDef       then lower_function_def(node)
    when AST::FuncCall          then lower_func_call(node)
    when AST::MethodCall        then lower_method_call(node)
    when AST::LambdaLit         then lower_lambda(node)

    # --- Collections ---
    when AST::ListLit           then lower_list_lit(node)
    when AST::TupleLit          then lower_tuple_lit(node)
    when AST::DefaultArrayLit   then lower_default_array_lit(node)
    when AST::HashLit           then lower_hash_lit(node)

    # --- Expressions ---
    when AST::Literal           then lower_literal(node)
    when AST::DefaultLit        then MIR::DefaultValue.new(kind: :aggregate_empty)
    when AST::Identifier        then lower_identifier(node)
    when AST::BinaryOp          then lower_binary_op(node)
    when AST::UnaryOp           then lower_unary_op(node)
    when AST::GetField          then lower_get_field(node)
    when AST::GetIndex          then lower_get_index(node)
    when AST::StructLit         then lower_struct_lit(node)
    when AST::UnionVariantLit   then lower_union_variant_lit(node)
    when AST::StringConcat      then lower_string_concat(node)
    when AST::BlockExpr         then lower_block_expr(node)
    when AST::RangeLit          then lower_range_lit(node)
    when AST::OptionalUnwrap    then MIR::OptionalUnwrap.new(lower(node.target))
    when AST::Assert            then lower_assert(node)
    when AST::Raise             then lower_raise(node)
    when AST::Cast              then lower_cast(node)
    when AST::ThrowNode         then MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError"))
    when AST::DieNode           then MIR::ExprStmt.new(MIR::Call.new("std.process.exit", [MIR::Lit.new((node.status || 1).to_s)], false), false)

    # --- Memory / capability expressions ---
    when AST::CopyNode          then lower_copy(node)
    when AST::CloneNode         then lower_clone(node)
    when AST::MoveNode          then lower_move(node)
    when AST::ShareNode         then lower_share(node)
    when AST::CapabilityWrap    then lower_cap_wrap(node)
    when AST::LinkNode          then lower_link(node)
    when AST::ResolveNode       then lower_resolve(node)
    when AST::FreezeNode        then lower_freeze(node)
    when AST::Copy              then lower(node.value) # Zig copies structs by value

    # --- Slice ---
    when AST::Slice             then lower_slice(node)

    # --- Concurrent / capability blocks ---
    when AST::BgBlock          then lower_bg_block(node)
    when AST::BgStreamBlock    then lower_bg_stream_block(node)
    when AST::WithBlock        then lower_with_block(node)
    when AST::DoBlock          then lower_do_block(node)
    when AST::TestBlock        then lower_test_block(node)
    when AST::RequireNode      then lower_require(node)
    when AST::YieldExpr        then lower_yield(node)
    when AST::NextExpr         then lower_next_expr(node)
    when AST::StaticCall       then lower_static_call(node)
    when AST::OrElseRaise          then MIR::FieldGet.new(MIR::Ident.new("error"), "OrElseRaise")
    when AST::OrElsePass, AST::OrElsePrune then MIR::DefaultValue.new(kind: :undefined)
    when AST::OrElseExit           then lower_or_else_exit(node)
    when AST::ThenChain        then raise "Internal: ThenChain should be flattened by BgBlock lowering"
    when AST::AssertRaises     then lower_assert_raises(node)
    when AST::StubDecl         then lower_stub_decl(node)
    when AST::BenchmarkStmt    then lower_benchmark(node)
    when AST::SmashStmt        then lower_smash(node)
    when AST::ProfileStmt      then lower_profile(node)

    else
      raise "MIRLowering: unhandled node type #{node.class} at #{node.token ? "line #{node.token.line}" : 'unknown'}"
    end
    return mir unless node.is_a?(AST::Locatable)

    apply_lowered_coercion(mir, node)
  end

  sig { params(mir: T.nilable(LoweredMir), node: AST::Locatable).returns(T.nilable(LoweredMir)) }
  def apply_lowered_coercion(mir, node)
    return mir unless mir && node.respond_to?(:coerced_type) && node.coerced_type
    coerced_type = Type.new(T.unsafe(node.coerced_type_info || node.coerced_type))
    return mir unless node.typed?
    actual_type = node.full_type!
    return mir if coerced_type.semantic_type_key == actual_type.semantic_type_key
    return mir if stack_fixed_array_coercion?(node)
    return mir unless mir.is_a?(MIR::Emittable)

    # Optionality is encoded inside NodeRef's zero sentinel; T@node and
    # ?T@node therefore have the same Zig representation and need no cast.
    return mir if coerced_type.node_reference? && actual_type.node_reference?

    if coerced_type.node_reference? && !actual_type.node_reference?
      if actual_type.resolved == :NIL
        return MIR::StructInit.new(coerced_type.zig_type, [])
      end
      return node_create_mir(T.unsafe(mir), coerced_type, T.unsafe(node))
    end

    union_wrapped = lower_union_payload_coercion(mir, node, actual_type, coerced_type)
    return union_wrapped if union_wrapped

    mir_cast(mir, actual_type, coerced_type) || mir
  end

  sig { params(mir: MIR::Emittable, node: AST::Locatable, actual_type: Type, coerced_type: Type).returns(T.nilable(MIR::Emittable)) }
  def lower_union_payload_coercion(mir, node, actual_type, coerced_type)
    target_type = coerced_type.value_payload_type
    schema = union_schemas[target_type.resolved]
    schema ||= begin
      looked_up = mir_schema_lookup.call(target_type.resolved)
      looked_up.is_a?(Schemas::UnionSchema) ? looked_up : nil
    end
    return nil unless schema

    compared_actual = actual_type.optional? ? T.must(actual_type.wrapped_type) : actual_type
    variant_name, payload_type = unique_mir_union_payload_variant(schema, compared_actual)
    return nil unless variant_name && payload_type

    if actual_type.optional? && coerced_type.optional?
      capture = "_union_payload_#{lowering_counters.next_tmp_id}"
      wrapped = MIR::StructInit.new(transpile_type(target_type), [
        { name: variant_name, value: MIR::Ident.new(capture) }
      ])
      result = MIR::IfOptional.new(mir, capture, wrapped, MIR::Lit.new("null"))
      result.result_type = coerced_type
      return result
    end

    union_payload_coercion_value(mir, node, target_type, variant_name, payload_type)
  end

  sig { params(schema: Schemas::UnionSchema, actual_type: Type).returns([T.nilable(String), T.nilable(Type)]) }
  def unique_mir_union_payload_variant(schema, actual_type)
    matches = schema.variants.filter_map do |variant_name, payload|
      next unless payload.is_a?(Type)
      next unless mir_union_payload_matches?(payload, actual_type)

      [variant_name.to_s, payload]
    end
    matches.one? ? T.cast(matches.first, [String, Type]) : [nil, nil]
  end

  sig { params(payload_type: Type, actual_type: Type).returns(T::Boolean) }
  def mir_union_payload_matches?(payload_type, actual_type)
    payload_surface = Type.coercion_surface_name(payload_type)
    actual_surface = Type.coercion_surface_name(actual_type)
    return true if payload_surface == actual_surface
    return false if payload_type.string? || actual_type.string?

    payload_type.accepts?(actual_type)
  end

  sig { params(mir: MIR::Emittable, node: AST::Locatable, union_type: Type, variant_name: String, payload_type: Type).returns(MIR::Emittable) }
  def union_payload_coercion_value(mir, node, union_type, variant_name, payload_type)
    ast_node = T.unsafe(node)
    target_alloc = function_state.current_decl_alloc || alloc_for_node(ast_node)
    payload = materialize_owned_sink_value(mir, ast_node, target_alloc, payload_type)
    payload = hoist_alloc(payload, ast_node, err_cleanup: true) if mir_allocates?(payload)

    T.cast(with_ownership_consumption(
      MIR::StructInit.new(transpile_type(union_type), [
        { name: variant_name, value: payload }
      ]),
      mir_ident_names(payload),
      "MIR::StructInit",
      target_alloc: target_alloc,
    ), MIR::StructInit)
  end

  sig { params(node: AST::Locatable).returns(T::Boolean) }
  def stack_fixed_array_coercion?(node)
    return false unless node.is_a?(AST::ListLit) && node.storage == :stack
    coerced_type = node.respond_to?(:coerced_type_info) ? node.coerced_type_info : node.full_type!
    coerced_type&.fixed? == true
  end

  # Lower a body (array of statements) into an array of MIR nodes.
  # Flushes function_state.pending_stmts before each statement so hoisted Lets (from
  # hoist_alloc calls inside lower()) precede the statement that uses them.
  sig { params(stmts: T::Array[LowerableStmt]).returns(T::Array[MIR::Emittable]) }
  def lower_body(stmts)
    finalize_lowered_body_construction!(construct_lowered_body(stmts))
  end

  sig { params(stmts: T::Array[LowerableStmt]).returns(LoweredBodyConstruction) }
  def construct_lowered_body(stmts)
    state = initial_ownership_finalization_context
    packets = T.let([], T::Array[LoweredStmtPacket])
    stmts.each do |stmt|
      packet = lowered_stmt_packet(state, stmt)
      packets << packet if packet
    end
    LoweredBodyConstruction.new(packets: packets, finalization_context: state)
  end

  sig { returns(OwnershipFinalizationContext) }
  def initial_ownership_finalization_context
    state = OwnershipFinalizationContext.new(
      inherited_alloc_names: function_state.lowered_alloc_names.dup,
      parent: nil,
      out: [],
      guarded_cleanup_names: function_state.lowered_guarded_cleanup_names.dup,
      alloc_marks: {},
      body_alloc_mark_names: Set.new,
      transfer_mark_names: Set.new,
      body_transfer_mark_names: Set.new,
      move_mark_names: Set.new,
      cleanup_by_name: {},
    )
    state
  end

  sig { params(construction: LoweredBodyConstruction).returns(T::Array[MIR::Node]) }
  def finalize_lowered_body_construction!(construction)
    state = construction.finalization_context
    seed_cleanup_owner_index!(
      state,
      construction.packets.flat_map { |packet| packet.pending.compact + Array(packet.mir).compact },
    )
    construction.packets.each do |packet|
      append_pending_packet_nodes!(state, packet)
      append_lowered_statement_packet!(state, packet)
    end
    mark_ownership_finalized_body!(state.out)
    state.out
  end

  sig { params(body: T::Array[MIR::Node]).returns(T::Array[MIR::Node]) }
  def mark_ownership_finalized_body!(body)
    ownership_state.finalized_body_ids << lowered_body_id(body)
    body
  end

  sig { params(body: T::Array[MIR::Node]).returns(T::Boolean) }
  def ownership_finalized_body?(body)
    ownership_state.finalized_body_ids.include?(lowered_body_id(body))
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def ownership_finalized_node?(node)
    return false unless node.is_a?(MIR::Emittable)

    node_id = node.lowered_node_id
    !!(node_id && ownership_state.finalized_node_ids.include?(node_id))
  end

  sig { params(node: MIR::Node).void }
  def mark_ownership_finalized_node!(node)
    ownership_state.finalized_node_ids << ensure_lowered_node_id(node) if node.is_a?(MIR::Emittable)
    nil
  end

  sig { params(node: MIR::Emittable).returns(MIR::LoweredNodeId) }
  def ensure_lowered_node_id(node)
    existing = node.lowered_node_id
    return existing if existing

    next_id = ownership_state.next_lowered_node_id
    ownership_state.next_lowered_node_id = next_id + 1
    assigned = MIR::LoweredNodeId.new(value: next_id)
    node.lowered_node_id = assigned
    assigned
  end

  sig { params(body: T::Array[MIR::Node]).returns(MIR::LoweredBodyId) }
  def lowered_body_id(body)
    node_ids = T.let([], T::Array[MIR::LoweredNodeId])
    body.each do |node|
      node_ids << ensure_lowered_node_id(node) if node.is_a?(MIR::Emittable)
    end
    MIR::LoweredBodyId.new(node_ids: node_ids)
  end

  sig { params(nodes: T::Array[MIR::Node]).void }
  def mark_ownership_finalized_nodes!(nodes)
    nodes.each { |node| mark_ownership_finalized_node!(node) }
    nil
  end

  sig { params(state: OwnershipFinalizationContext, packet: LoweredStmtPacket).void }
  def append_pending_packet_nodes!(state, packet)
    packet.pending.compact.each do |node|
      append_ownership_finalized_node!(state, node, [node], nil, nil)
    end
    nil
  end

  sig { params(state: OwnershipFinalizationContext, body: T::Array[MIR::Node]).void }
  def seed_cleanup_owner_index!(state, body)
    body.each do |node|
      case node
      when Array
        seed_cleanup_owner_index!(state, node)
      when Hash
        nested_body = node[:body]
        seed_cleanup_owner_index!(state, nested_body) if nested_body.is_a?(Array)
      when MIR::Cleanup, MIR::ErrCleanup
        name = node.name.to_s
        state.cleanup_by_name[name] ||= node
        state.guarded_cleanup_names << name if cleanup_entry_moved_guard?(node.cleanup_entry)
      when MIR::Emittable
        node.child_exprs.each do |child|
          seed_cleanup_owner_index!(state, [child]) if child.is_a?(MIR::Emittable)
        end
        node.body_slots.each do |slot|
          seed_cleanup_owner_index!(state, slot.body)
        end
      end
    end
    nil
  end

  sig { params(entry: CleanupEntry).returns(T::Boolean) }
  def cleanup_entry_moved_guard?(entry)
    entry.has_moved_guard?
  end

  sig { params(state: OwnershipFinalizationContext, packet: LoweredStmtPacket).void }
  def append_lowered_statement_packet!(state, packet)
    packet_mir = packet.mir
    packet_nodes = packet_mir.is_a?(Array) ? packet_mir.compact : [packet_mir]
    mir_nodes = normalize_allocating_mir_body(packet_nodes)
    merge_body_mark_names!(state, mir_nodes)
    line = packet.source_line
    col = packet.source_column
    state.out << MIR::Comment.new("CLR:#{line}") if line
    append_transfer_marks_to_body!(state, packet.stmt_transfer_marks, line, col)
    mir_nodes.each { |node| append_ownership_finalized_node!(state, node, mir_nodes, line, col) }
    marks = mir_nodes.flat_map { |node| ownership_transfers_for_node(node, state) }
    append_transfer_marks_to_body!(state, dedupe_transfer_marks(marks), line, col)
    nil
  end

  sig { params(state: OwnershipFinalizationContext, node: MIR::Node).void }
  def append_already_finalized_node!(state, node)
    state.out << node
    record_ownership_finalization_node!(state, node) if node.is_a?(MIR::Emittable)
    nil
  end

  sig do
    params(
      state: OwnershipFinalizationContext,
      node: MIR::Node,
      body: T::Array[MIR::Node],
      line: T.nilable(Integer),
      col: T.nilable(Integer),
    ).void
  end
  def append_ownership_finalized_node!(state, node, body, line, col)
    if ownership_finalized_node?(node)
      append_already_finalized_node!(state, node)
      return
    end

    finalize_nested_mir_bodies!(node, state)
    stamp_source_line!(node, line, col)
    append_transfer_marks_to_body!(state, pre_terminator_transfer_marks(node, state.out, body), line, col)
    state.out << node
    append_move_guard_for_transfer_mark!(node, state)
    surface = scan_ownership_surface!(
      state,
      node,
      collect_facts: true,
      collect_transfers: true,
    )
    state.out.concat(surface.facts)
    mark_ownership_finalized_node!(node)
    mark_ownership_finalized_nodes!(surface.facts)
    append_transfer_marks_to_body!(
      state,
      ownership_transfers_for_targets(surface.transfer_targets, state),
      line,
      col,
    )
    nil
  end

  sig { params(state: OwnershipFinalizationContext, marks: T::Array[MIR::Stmt], line: T.nilable(Integer), col: T.nilable(Integer)).void }
  def append_transfer_marks_to_body!(state, marks, line, col)
    marks.each do |mark|
      next if mark.is_a?(MIR::MoveMark) && state.move_mark_names.include?(mark.name.to_s)
      next if mark.is_a?(MIR::TransferMark) && state.transfer_mark_names.include?(mark.name.to_s)
      if ownership_finalized_node?(mark)
        append_already_finalized_node!(state, mark)
        next
      end

      stamp_source_line!(mark, line, col)
      state.out << mark
      facts = mark.is_a?(MIR::Emittable) ? ownership_facts_for_structural_node(mark) : []
      state.out.concat(facts)
      mark_ownership_finalized_node!(mark)
      mark_ownership_finalized_nodes!(facts)
      record_ownership_finalization_node!(state, mark)
      next unless mark.is_a?(MIR::TransferMark)

      before_guard = state.out.length
      append_move_guard_for_transfer_mark!(mark, state)
      T.must(state.out[before_guard..]).each { |node| stamp_source_line!(node, line, col) } if state.out.length > before_guard
    end
    nil
  end

  sig { params(nodes: T::Array[MIR::Node], name: String).returns(T::Boolean) }
  def emitted_guarded_cleanup_for_name?(nodes, name)
    nodes.any? do |node|
      next false unless node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)
      node.name.to_s == name && node.cleanup_entry.has_moved_guard?
    end
  end

  sig { params(marks: T::Array[MIR::Stmt]).returns(T::Array[MIR::Stmt]) }
  def dedupe_transfer_marks(marks)
    marks.uniq do |mark|
      [
        mark.class,
        mark.respond_to?(:name) ? T.unsafe(mark).name : nil,
        mark.respond_to?(:target) ? T.unsafe(mark).target : nil,
      ]
    end
  end

  sig { params(state: OwnershipFinalizationContext, stmt: LowerableStmt).returns(T.nilable(LoweredStmtPacket)) }
  def lowered_stmt_packet(state, stmt)
    mir = lower(stmt)
    return nil unless mir

    mir, hoisted_discard = materialize_statement_discard(stmt, mir)
    pending = flush_pending
    mir = MIR::ExprStmt.new(mir, true) if discard_expr_stmt?(stmt, mir) && !hoisted_discard
    token = stmt.is_a?(AST::Locatable) ? stmt.token : nil
    transfer_only = stmt.is_a?(AST::MoveNode)
    stmt_transfer_marks =
      if transfer_only
        ownership_marks_for_transferred_temp(T.cast(mir, MIR::Node))
      else
        dedupe_transfer_marks(ownership_transfers_for_stmt(stmt, state.guarded_cleanup_names))
      end
    statement_nodes = mir.is_a?(Array) ? mir.compact : [mir]
    guarded_nodes = if transfer_only
      []
    else
      guard_shared_node_statement(stmt, pending.compact + statement_nodes)
    end
    LoweredStmtPacket.new(
      mir: transfer_only ? [] : T.unsafe(guarded_nodes),
      pending: transfer_only ? pending : [],
      stmt_transfer_marks: stmt_transfer_marks,
      source_line: transfer_only ? nil : token&.line,
      source_column: transfer_only ? nil : token&.column,
    )
  end

  sig { params(stmt: LowerableStmt, mir: MIR::NodeRoot).returns([MIR::NodeRoot, T::Boolean]) }
  def materialize_statement_discard(stmt, mir)
    return [mir, false] unless stmt.is_a?(AST::Locatable)
    return [mir, false] unless discard_expr_stmt?(stmt, mir)

    discard_type = Type.from_node!(stmt, context: "discard allocation mark")
    mir = place_discarded_owned_branch_value(T.cast(mir, MIR::Node), discard_type)
    normalized_prefix = normalize_allocating_result_expr!(mir)
    function_state.pending_stmts.concat(normalized_prefix) unless normalized_prefix.empty?
    return [mir, false] unless mir_allocates?(mir) && !mutating_receiver_allocator_op?(mir)

    entry = hoist_cleanup_entry(mir, stmt)
    return [mir, false] unless entry

    discard_name = "__discard_#{lowering_counters.next_tmp_id}"
    alloc = entry.alloc || mir_owned_alloc(mir) || :heap
    materialized = MIR::BindingMaterialization.new(
      name: discard_name,
      expr: mir,
      alloc: alloc,
      type_info: discard_type,
      mutable: true,
      annotation: Type.new(discard_owned_zig_type(stmt, entry)),
      suppression: "_ = &#{discard_name};",
      cleanup_entry: entry
    )
    stamp_allocating_result_target!(mir, discard_name, alloc: alloc)
    [MIR::ScopeBlock.new(materialized.statements), true]
  end

  sig { params(mir: MIR::Node, type_info: Type).returns(MIR::Node) }
  def place_discarded_owned_branch_value(mir, type_info)
    return mir unless mir_allocates?(mir)

    result_type = type_info.success_type || type_info
    return mir unless ownership_bearing_type?(result_type)

    dest_alloc = mir_owned_alloc(mir) || :heap
    case mir
    when MIR::TryCatch
      place_owned_try_catch_for_destination(mir, result_type, dest_alloc)
    when MIR::Orelse
      place_owned_orelse_for_destination(mir, result_type, dest_alloc)
    else
      mir
    end
  end

  sig { params(stmt: LowerableStmt, mir: T.untyped).returns(T::Boolean) }
  def discard_expr_stmt?(stmt, mir)
    return false unless stmt.is_a?(AST::Locatable)
    return false unless mir.is_a?(MIR::Emittable) && mir.expr?

    ast_stmt = stmt
    return false unless AST.call?(ast_stmt) || ast_stmt.is_a?(AST::BinaryOp)

    resolved = stmt.resolved_type
    !!(resolved && resolved != :Void)
  end

  sig { params(state: OwnershipFinalizationContext, root: MIR::NodeRoot).void }
  def record_ownership_finalization_node!(state, root)
    MIR.each_surface_node(root) do |node|
      record_ownership_finalization_surface_node!(state, node)
    end
    function_state.lowered_guarded_cleanup_names = state.guarded_cleanup_names
    nil
  end

  sig { params(state: OwnershipFinalizationContext, node: MIR::Node).void }
  def record_ownership_finalization_surface_node!(state, node)
    case node
    when MIR::AllocMark
      state.alloc_marks[node.name.to_s] = node
      state.body_alloc_mark_names << node.name.to_s
    when MIR::TransferMark
      state.transfer_mark_names << node.name.to_s
      state.body_transfer_mark_names << node.name.to_s
    when MIR::MoveMark
      state.move_mark_names << node.name.to_s
    when MIR::Cleanup, MIR::ErrCleanup
      name = node.name.to_s
      state.cleanup_by_name[name] = node
      state.guarded_cleanup_names << name if cleanup_entry_moved_guard?(node.cleanup_entry)
    end
    nil
  end

  sig do
    params(
      state: OwnershipFinalizationContext,
      root: MIR::NodeRoot,
      collect_facts: T::Boolean,
      collect_transfers: T::Boolean,
    ).returns(OwnershipSurfaceScan)
  end
  def scan_ownership_surface!(state, root, collect_facts:, collect_transfers:)
    facts = T.let([], T::Array[OwnershipFact])
    transfer_targets = T.let([], T::Array[OwnershipTransferTarget])
    MIR.each_surface_node(root) do |node|
      record_ownership_finalization_surface_node!(state, node)
      append_ownership_facts_for_mir_node!(facts, node) if collect_facts
      append_ownership_transfer_targets_for_surface_node!(transfer_targets, node, state) if collect_transfers
    end
    function_state.lowered_guarded_cleanup_names = state.guarded_cleanup_names
    OwnershipSurfaceScan.new(
      facts: collect_facts ? dedupe_ownership_facts(facts) : facts,
      transfer_targets: collect_transfers ? transfer_targets.uniq : transfer_targets,
    )
  end

  sig { params(state: OwnershipFinalizationContext, body: MIR::NodeRoot).void }
  def merge_body_mark_names!(state, body)
    state.body_alloc_mark_names.merge(body_alloc_mark_names_in_body(body))
    state.body_transfer_mark_names.merge(body_transfer_mark_names_in_body(body))
    nil
  end

  sig { params(body: MIR::NodeRoot).returns(T::Set[String]) }
  def body_alloc_mark_names_in_body(body)
    names = T.let(Set.new, T::Set[String])
    MIR.each_surface_node(body) do |node|
      names << node.name.to_s if node.is_a?(MIR::AllocMark)
    end
    names
  end

  sig { params(body: MIR::NodeRoot).returns(T::Set[String]) }
  def body_transfer_mark_names_in_body(body)
    names = T.let(Set.new, T::Set[String])
    MIR.each_surface_node(body) do |node|
      names << node.name.to_s if node.is_a?(MIR::TransferMark)
    end
    names
  end

  sig do
    params(
      body: T::Array[MIR::Node],
      inherited_alloc_names: T::Set[String],
      inherited_guarded_names: T::Set[String]
    ).returns(T::Array[MIR::Node])
  end
  def append_ownership_transfers_for_mir_body(body, inherited_alloc_names = Set.new, inherited_guarded_names = Set.new)
    normalized = normalize_allocating_mir_body(body)
    state = OwnershipFinalizationContext.new(
      inherited_alloc_names: inherited_alloc_names,
      parent: nil,
      out: [],
      guarded_cleanup_names: inherited_guarded_names.dup,
      alloc_marks: {},
      body_alloc_mark_names: body_alloc_mark_names_in_body(normalized),
      transfer_mark_names: Set.new,
      body_transfer_mark_names: body_transfer_mark_names_in_body(normalized),
      move_mark_names: Set.new,
      cleanup_by_name: {},
    )
    seed_cleanup_owner_index!(state, normalized)
    normalized.each do |node|
      finalize_ownership_for_mir_node!(node, normalized, state)
    end
    mark_ownership_finalized_body!(state.out)
  end

  sig do
    params(
      body: T::Array[MIR::Node],
      inherited_alloc_names: T::Set[String],
      inherited_guarded_names: T::Set[String],
      parent: OwnershipFinalizationContext,
    ).returns(T::Array[MIR::Node])
  end
  def append_nested_ownership_transfers_for_mir_body(body, inherited_alloc_names, inherited_guarded_names, parent)
    return body if ownership_finalized_body?(body)

    normalized = normalize_allocating_mir_body(body)
    state = OwnershipFinalizationContext.new(
      inherited_alloc_names: inherited_alloc_names,
      parent: parent,
      out: [],
      guarded_cleanup_names: inherited_guarded_names.dup,
      alloc_marks: {},
      body_alloc_mark_names: body_alloc_mark_names_in_body(normalized),
      transfer_mark_names: Set.new,
      body_transfer_mark_names: body_transfer_mark_names_in_body(normalized),
      move_mark_names: Set.new,
      cleanup_by_name: {},
    )
    seed_cleanup_owner_index!(state, normalized)
    normalized.each do |node|
      finalize_ownership_for_mir_node!(node, normalized, state)
    end
    mark_ownership_finalized_body!(state.out)
  end

  sig { params(node: MIR::Node, body: T::Array[MIR::Node], state: OwnershipFinalizationContext).void }
  def finalize_ownership_for_mir_node!(node, body, state)
    if ownership_finalized_node?(node)
      append_already_finalized_node!(state, node)
      return
    end

    finalize_nested_mir_bodies!(node, state, state.inherited_alloc_names, state.guarded_cleanup_names)
    append_implicit_alloc_fact!(node, state)
    append_block_result_transfer!(node, body, state)
    append_transfer_marks!(pre_terminator_transfer_marks(node, state.out, body), state)
    append_transfer_marks!(ownership_transfers_for_node(node, state), state) if node.is_a?(MIR::BreakStmt)
    state.out << node
    append_move_guard_for_transfer_mark!(node, state)
    surface = T.let(nil, T.nilable(OwnershipSurfaceScan))
    facts = if node.is_a?(MIR::BreakStmt)
      ownership_facts_for_mir_surface(node)
    else
      surface = scan_ownership_surface!(
        state,
        node,
        collect_facts: true,
        collect_transfers: true,
      )
      surface.facts
    end
    state.out.concat(facts)
    mark_ownership_finalized_node!(node)
    mark_ownership_finalized_nodes!(facts)
    record_ownership_finalization_node!(state, node) unless surface
    unless node.is_a?(MIR::BreakStmt)
      append_transfer_marks!(
        ownership_transfers_for_targets(T.must(surface).transfer_targets, state),
        state,
      )
    end
    nil
  end

  sig { params(node: MIR::Node, state: OwnershipFinalizationContext).void }
  def append_move_guard_for_transfer_mark!(node, state)
    return unless node.is_a?(MIR::TransferMark)
    return unless node.target == :owned_sink || node.target == :return
    name = node.name.to_s
    guarded = state.guarded_cleanup_names.include?(name)
    unless guarded
      owner_cleanup = owner_cleanup_for_transfer(state, name)
      if owner_cleanup
        owner_cleanup.cleanup_entry.mark_moved_guard!
        state.guarded_cleanup_names << name
        state.parent&.guarded_cleanup_names&.add(name)
        guarded = true
      elsif (entry = function_state.bindings[name]) && entry.needs_cleanup?
        entry.mark_moved_guard!
        state.guarded_cleanup_names << name
        state.parent&.guarded_cleanup_names&.add(name)
        guarded = true
      end
    end
    return unless guarded
    return if state.move_mark_names.include?(node.name.to_s)

    move = T.must(MIR::OwnershipTransferPlan.new(
      name: node.name.to_s,
      target: node.target,
      target_alloc: node.target_alloc,
      move_guarded: true,
    ).marks.last)

    state.out << move
    state.out.concat(ownership_facts_for_structural_node(T.must(state.out.last)))
    record_ownership_finalization_node!(state, move)
    nil
  end

  sig { params(state: OwnershipFinalizationContext, name: String).returns(T.nilable(T.any(MIR::Cleanup, MIR::ErrCleanup))) }
  def owner_cleanup_for_transfer(state, name)
    current = T.let(state, T.nilable(OwnershipFinalizationContext))
    while current
      found = current.cleanup_by_name[name]
      return found if found

      current = current.parent
    end
    nil
  end

  sig { params(node: MIR::Node, state: OwnershipFinalizationContext).void }
  def append_implicit_alloc_fact!(node, state)
    alloc_mark = implicit_alloc_mark_for_mir_node(node, state)
    return unless alloc_mark

    state.out << alloc_mark
    fact = owned_create_fact_for_alloc_mark(alloc_mark, ownership_fact_source(alloc_mark))
    state.out << fact
    mark_ownership_finalized_node!(alloc_mark)
    mark_ownership_finalized_node!(fact)
    record_ownership_finalization_node!(state, alloc_mark)
    nil
  end

  sig { params(node: MIR::Node, body: T::Array[MIR::Node], state: OwnershipFinalizationContext).void }
  def append_block_result_transfer!(node, body, state)
    return unless node.is_a?(MIR::BreakStmt)
    value = node.value
    return unless value.is_a?(MIR::Ident)

    name = value.name.to_s
    return if state.body_transfer_mark_names.include?(name)
    return unless state.alloc_marks.key?(name) || state.body_alloc_mark_names.include?(name)

    ownership_transfer_marks(name, :block_result).each do |mark|
      state.out << mark
      record_ownership_finalization_node!(state, mark)
    end
    nil
  end

  sig { params(nodes: T::Array[MIR::Node], name: String).returns(T::Boolean) }
  def alloc_mark_present?(nodes, name)
    nodes.any? { |node| node.is_a?(MIR::AllocMark) && node.name.to_s == name.to_s }
  end

  sig { params(marks: T::Array[MIR::Stmt], state: OwnershipFinalizationContext).void }
  def append_transfer_marks!(marks, state)
    marks.each do |mark|
      next if mark.is_a?(MIR::MoveMark) && state.move_mark_names.include?(mark.name.to_s)
      next if mark.is_a?(MIR::TransferMark) && state.transfer_mark_names.include?(mark.name.to_s)
      if ownership_finalized_node?(mark)
        append_already_finalized_node!(state, mark)
        next
      end

      state.out << mark
      facts = ownership_facts_for_structural_node(mark)
      state.out.concat(facts)
      mark_ownership_finalized_node!(mark)
      mark_ownership_finalized_nodes!(facts)
      record_ownership_finalization_node!(state, mark)
      append_move_guard_for_transfer_mark!(mark, state)
    end
    nil
  end

  sig { params(node: MIR::Node).returns(T::Array[OwnershipFact]) }
  def ownership_facts_for_mir_surface(node)
    facts = T.let([], T::Array[OwnershipFact])
    MIR.each_surface_node(node) do |surface_node|
      append_ownership_facts_for_mir_node!(facts, surface_node)
    end
    dedupe_ownership_facts(facts)
  end

  sig { params(facts: T::Array[OwnershipFact]).returns(T::Array[OwnershipFact]) }
  def dedupe_ownership_facts(facts)
    seen = T.let(Set.new, T::Set[String])
    facts.select do |fact|
      key = ownership_fact_dedupe_key(fact)
      next true unless key
      next false if seen.include?(key)

      seen << key
      true
    end
  end

  sig { params(fact: OwnershipFact).returns(T.nilable(String)) }
  def ownership_fact_dedupe_key(fact)
    case fact
    when MIR::OwnedCreate
      "OwnedCreate:#{fact.name}:#{fact.alloc}:#{fact.source}"
    when MIR::OwnedDestroy
      "OwnedDestroy:#{fact.name}:#{fact.alloc}:#{fact.source}"
    when MIR::OwnedTransfer
      "OwnedTransfer:#{fact.name}:#{fact.target}:#{fact.source}"
    when MIR::OwnedBorrow
      "OwnedBorrow:#{fact.name}:#{fact.source}"
    when MIR::OwnedStore
      "OwnedStore:#{fact.name}:#{fact.target}:#{fact.alloc}:#{fact.source}"
    when MIR::OwnedReturn
      "OwnedReturn:#{fact.name}:#{fact.source}"
    else
      nil
    end
  end

  sig { params(facts: T::Array[OwnershipFact], node: MIR::Node).void }
  def append_ownership_facts_for_mir_node!(facts, node)
    append_ownership_facts_for_structural_node!(facts, node)
    append_ownership_store_facts_for_consumption!(facts, node)
    append_ownership_transfer_facts_for_consumption!(facts, node)
    ownership_fact_targets_for_node(node).each do |target|
      append_ownership_facts_for_owned_result!(facts, target.name, target.expr, T.must(target.type_info)) if target.include_owned_result
      append_ownership_transfer_facts_for_contract!(facts, target.expr) if target.include_transfer_contract
      facts << MIR::OwnedReturn.new(target.name, ownership_fact_source(target.expr)) if target.expr.is_a?(MIR::BgBlock)
    end
    nil
  end

  sig { params(node: MIR::Node).returns(T::Array[OwnershipFactTarget]) }
  def ownership_fact_targets_for_node(node)
    case node
    when MIR::Let
      ownership_fact_target_for_expr(node.name.to_s, node.init, node.annotation)
    when MIR::ExprStmt
      ownership_fact_target_for_expr(ownership_fact_source(node.expr), node.expr, nil)
    when MIR::Set
      [ownership_transfer_only_target(node.value)]
    when MIR::IfBindStmt
      if_bind_ownership_fact_targets(node)
    when MIR::ReturnStmt, MIR::BreakStmt
      value = node.value
      value ? ownership_fact_target_for_expr(ownership_fact_source(value), value, nil) : []
    when MIR::ReassignWithCleanup
      ownership_fact_target_for_expr(node.name.to_s, node.value, nil)
    when MIR::BgBlock
      [OwnershipFactTarget.new(name: ownership_fact_source(node), expr: node, type_info: nil, include_owned_result: false, include_transfer_contract: false)]
    else
      ownership_fact_target_for_expr(ownership_fact_source(node), node, nil)
    end
  end

  sig { params(name: String, expr: MIR::Node, type_info: T.nilable(Type)).returns(T::Array[OwnershipFactTarget]) }
  def ownership_fact_target_for_expr(name, expr, type_info)
    source_expr = ownership_contract_source_node(expr)
    include_owned_result = ownership_owned_result_fact_relevant?(expr) && !source_expr.is_a?(MIR::BgBlock)
    include_transfer_contract = ownership_transfer_contract_relevant?(expr)
    return [] unless include_owned_result || include_transfer_contract
    owned_result_type = if include_owned_result
      type_info || mir_alloc_mark_type_info(source_expr, nil, context: "owned MIR result fact")
    end

    [OwnershipFactTarget.new(
      name: name,
      expr: expr,
      type_info: owned_result_type,
      include_owned_result: include_owned_result,
      include_transfer_contract: include_transfer_contract,
    )]
  end

  sig { params(expr: MIR::Node).returns(T::Boolean) }
  def ownership_owned_result_fact_relevant?(expr)
    source_expr = ownership_contract_source_node(expr)
    return true if source_expr.is_a?(MIR::BgBlock)

    effect = MIR::OwnershipEffect.of(source_expr)
    return true if effect.produces_owned

    if source_expr.respond_to?(:mutating_receiver_allocator_op?) &&
       T.unsafe(source_expr).mutating_receiver_allocator_op?
      return false
    end

    sig = source_expr.respond_to?(:stdlib_def) ? FunctionSignature.unwrap(T.unsafe(source_expr).stdlib_def) : nil
    sig&.emits_allocating? == true
  end

  sig { params(expr: MIR::Node).returns(T::Boolean) }
  def ownership_transfer_contract_relevant?(expr)
    source_expr = ownership_contract_source_node(expr)
    return false unless source_expr.is_a?(MIR::Emittable)

    contract = source_expr.explicit_ownership_contract
    contract.is_a?(MIR::OwnershipContract) && !contract.owned_operand_names.empty?
  end

  sig { params(expr: MIR::Node).returns(OwnershipFactTarget) }
  def ownership_transfer_only_target(expr)
    OwnershipFactTarget.new(name: ownership_fact_source(expr), expr: expr, type_info: nil, include_owned_result: false, include_transfer_contract: true)
  end

  sig { params(node: MIR::IfBindStmt).returns(T::Array[OwnershipFactTarget]) }
  def if_bind_ownership_fact_targets(node)
    targets = (node.bindings || []).flat_map do |binding|
      next nil unless binding.is_a?(Hash)

      capture = binding[:capture]
      expr = binding[:expr]
      next nil unless capture && expr

      ownership_fact_target_for_expr(capture.to_s, T.cast(expr, MIR::Node), nil)
    end
    targets.compact
  end

  sig { params(facts: T::Array[OwnershipFact], node: MIR::Node).void }
  def append_ownership_store_facts_for_consumption!(facts, node)
    fact = node.ownership_consumption
    return unless fact

    source = ownership_fact_source(node)
    fact.names.each { |name| facts << MIR::OwnedStore.new(name.to_s, fact.source, fact.target_alloc, source) }
    nil
  end

  sig { params(facts: T::Array[OwnershipFact], node: MIR::Node).void }
  def append_ownership_transfer_facts_for_consumption!(facts, node)
    fact = node.ownership_consumption
    return unless fact

    source = ownership_fact_source(node)
    fact.names.each { |name| facts << MIR::OwnedTransfer.new(name.to_s, fact.target, source) }
    nil
  end

  sig { params(node: MIR::Node).returns(T::Array[OwnershipFact]) }
  def ownership_facts_for_structural_node(node)
    facts = T.let([], T::Array[OwnershipFact])
    append_ownership_facts_for_structural_node!(facts, node)
    facts
  end

  sig { params(facts: T::Array[OwnershipFact], node: MIR::Node).void }
  def append_ownership_facts_for_structural_node!(facts, node)
    case node
    when MIR::AllocMark
      facts << owned_create_fact_for_alloc_mark(node, ownership_fact_source(node))
    when MIR::Cleanup, MIR::ErrCleanup
      facts << MIR::OwnedDestroy.new(node.name.to_s, node.cleanup_entry.alloc, ownership_fact_source(node))
    when MIR::TransferMark
      facts << MIR::OwnedTransfer.new(node.name.to_s, node.target, ownership_fact_source(node))
    end
    nil
  end

  sig { params(mark: MIR::AllocMark, source: String).returns(MIR::OwnedCreate) }
  def owned_create_fact_for_alloc_mark(mark, source)
    MIR::OwnedCreate.new(mark.name.to_s, mark.alloc, mark.type_info, source)
  end

  sig { params(facts: T::Array[OwnershipFact], target_name: String, expr: MIR::Node, type_info: Type).void }
  def append_ownership_facts_for_owned_result!(facts, target_name, expr, type_info)
    source_expr = ownership_contract_source_node(expr)
    if source_expr.is_a?(MIR::BgBlock)
      facts << MIR::OwnedReturn.new(target_name, ownership_fact_source(source_expr))
      return
    end

    effect = MIR::OwnershipEffect.of(source_expr)
    unless effect.produces_owned
      sig = source_expr.respond_to?(:stdlib_def) ? FunctionSignature.unwrap(T.unsafe(source_expr).stdlib_def) : nil
      return unless sig&.emits_allocating?

      facts << MIR::OwnedCreate.new(target_name, mir_owned_alloc(source_expr) || :heap, type_info, ownership_fact_source(source_expr))
      return
    end

    facts << MIR::OwnedCreate.new(target_name, effect.alloc || mir_owned_alloc(source_expr) || :heap, type_info, ownership_fact_source(source_expr))
    nil
  end

  sig { params(facts: T::Array[OwnershipFact], expr: MIR::Node).void }
  def append_ownership_transfer_facts_for_contract!(facts, expr)
    names = ownership_contract_consumes_unwrapped(expr)
    return if names.empty?

    source = ownership_fact_source(expr)
    names.each { |name| facts << MIR::OwnedTransfer.new(name.to_s, :owned_sink, source) }
    nil
  end

  sig { params(node: MIR::Node).returns(T::Array[String]) }
  def ownership_contract_consumes_unwrapped(node)
    unwrapped = ownership_contract_source_node(node)
    return [] unless unwrapped.is_a?(MIR::Emittable)

    ownership_contract_consumes(unwrapped)
  end

  sig { params(node: MIR::Node).returns(String) }
  def ownership_fact_source(node)
    source_node = ownership_contract_source_node(node)
    return source_node.class.name.to_s if source_node.is_a?(MIR::ReassignWithCleanup) || source_node.is_a?(MIR::ShardedMapPut)
    return T.unsafe(source_node).target_var.to_s if source_node.respond_to?(:target_var) && T.unsafe(source_node).target_var
    return source_node.callee.to_s if source_node.is_a?(MIR::Call) || source_node.is_a?(MIR::TailCall)
    return source_node.method.to_s if source_node.is_a?(MIR::MethodCall)
    return "MIR::BgBlock" if source_node.is_a?(MIR::BgBlock)
    return "MIR::StreamSpawn" if source_node.is_a?(MIR::StreamSpawn)
    return T.unsafe(source_node).reason.to_s if source_node.respond_to?(:reason) && T.unsafe(source_node).reason
    return T.unsafe(source_node).name.to_s if source_node.respond_to?(:name)

    source_node.class.name || source_node.class.to_s
  end

  sig { params(node: MIR::Node).returns(MIR::Node) }
  def ownership_contract_source_node(node)
    current = T.let(node, MIR::Node)
    while MIR.expr_wrapper?(current)
      current = T.cast(T.unsafe(current).expr, MIR::Node)
    end
    current
  end

  sig { params(nodes: T::Array[MIR::Node], name: String).returns(T::Boolean) }
  def transfer_mark_present?(nodes, name)
    nodes.any? { |node| node.is_a?(MIR::TransferMark) && node.name.to_s == name.to_s }
  end

  sig { params(node: MIR::Node, emitted: T::Array[MIR::Node], remaining: T::Array[MIR::Node]).returns(T::Array[MIR::Stmt]) }
  def pre_terminator_transfer_marks(node, emitted, remaining)
    []
  end

  sig do
    params(
      node: MIR::Node,
      parent_state: OwnershipFinalizationContext,
      inherited_alloc_names: T::Set[String],
      inherited_guarded_names: T::Set[String],
    ).void
  end
  def finalize_nested_mir_bodies!(node, parent_state, inherited_alloc_names = Set.new, inherited_guarded_names = Set.new)
    node.child_exprs.each do |child|
      finalize_nested_mir_expr_bodies!(child, inherited_alloc_names, inherited_guarded_names, parent_state)
    end
    node.body_slots.each do |slot|
      slot.replace(append_nested_ownership_transfers_for_mir_body(
        slot.body,
        inherited_alloc_names,
        inherited_guarded_names,
        parent_state,
      ))
    end
    nil
  end

  sig do
    params(
      expr: T.nilable(MIR::Node),
      inherited_alloc_names: T::Set[String],
      inherited_guarded_names: T::Set[String],
      parent_state: OwnershipFinalizationContext,
    ).void
  end
  def finalize_nested_mir_expr_bodies!(expr, inherited_alloc_names, inherited_guarded_names, parent_state)
    return unless expr
    return unless expr.expr?
    expr.body_slots.each do |slot|
      slot.replace(append_nested_ownership_transfers_for_mir_body(
        slot.body,
        inherited_alloc_names,
        inherited_guarded_names,
        parent_state,
      ))
    end
    each_mir_expr_child(expr) do |child|
      finalize_nested_mir_expr_bodies!(child, inherited_alloc_names, inherited_guarded_names, parent_state)
    end
    nil
  end

  sig { params(node: MIR::Node, state: OwnershipFinalizationContext).returns(T.nilable(MIR::AllocMark)) }
  def implicit_alloc_mark_for_mir_node(node, state)
    fact = implicit_allocating_result_fact(node, state)
    fact&.alloc_mark
  end

  sig { params(node: MIR::Node, state: OwnershipFinalizationContext).returns(T.nilable(AllocatingResultFact)) }
  def implicit_allocating_result_fact(node, state)
    return nil unless node.is_a?(MIR::Let)
    init = node.init
    return nil unless mir_allocates?(init)
    return nil if mutating_receiver_allocator_op?(init)

    name = node.name.to_s
    existing_mark = state.alloc_marks[name]
    if existing_mark
      stamp_allocating_result_target!(init, name, alloc: existing_mark.alloc)
      return nil
    end

    effect = MIR::OwnershipEffect.of(init)
    alloc = effect.alloc || mir_owned_alloc(init) || :heap
    stamp_allocating_result_target!(init, name, alloc: alloc)
    type_info = node.annotation || mir_alloc_mark_type_info(init, nil, context: "implicit MIR allocation fact")
    AllocatingResultFact.new(
      name: name,
      ownership_effect: effect.produces_owned ? effect.with_target(name) : MIR::OwnershipEffect.owned(alloc: alloc, target_var: name),
      type_info: type_info,
      scope: MIR::Placement.alloc_scope(alloc),
    )
  end

  sig { params(stmt: LowerableStmt, guarded_cleanup_names: T::Set[String]).returns(T::Array[MIR::Stmt]) }
  def ownership_transfers_for_stmt(stmt, guarded_cleanup_names)
    return [] unless stmt.is_a?(AST::Locatable)
    return [] if stmt.is_a?(AST::ReturnNode)
    return [] if AST.ownership_transfer_stmt?(stmt)
    marks = T.let([], T::Array[MIR::Stmt])
    collect_bg_capture_transfer_roots(stmt).uniq.each do |name|
      safe = zig_safe_name(name)
      rename_map = function_state.rename_map
      safe = rename_map[safe] if rename_map.key?(safe)
      entry = function_state.bindings[name] || CleanupEntry::NONE
      next unless entry.present?
      marks.concat(ownership_transfer_plan(safe.to_s, :owned_sink, guarded_cleanup_names,
        target_alloc: entry.alloc).marks)
    end
    marks
  end

  sig do
    params(
      node: MIR::Node,
      state: OwnershipFinalizationContext,
    ).returns(T::Array[MIR::Stmt])
  end
  def ownership_transfers_for_node(node, state)
    return [] if node.is_a?(MIR::ReturnStmt)

    ownership_transfers_for_targets(ownership_transfer_operands_for_node(node, state), state)
  end

  sig { params(operand_targets: T::Array[OwnershipTransferTarget], state: OwnershipFinalizationContext).returns(T::Array[MIR::Stmt]) }
  def ownership_transfers_for_targets(operand_targets, state)
    marks = T.let([], T::Array[MIR::Stmt])
    generated_mark_names = T.let(Set.new, T::Set[String])
    operand_targets.each do |operand_target|
      name = operand_target.name
      next if name.empty?
      next if state.body_transfer_mark_names.include?(name) || generated_mark_names.include?(name)

      marks.concat(ownership_transfer_plan(name, operand_target.target, state.guarded_cleanup_names,
        target_alloc: operand_target.target_alloc).marks)
      generated_mark_names << name
    end
    marks
  end

  sig { params(node: MIR::Node, state: OwnershipFinalizationContext).returns(T::Array[OwnershipTransferTarget]) }
  def ownership_transfer_operands_for_node(node, state)
    operands = T.let([], T::Array[OwnershipTransferTarget])
    MIR.each_surface_node(node) do |surface_node|
      append_ownership_transfer_targets_for_surface_node!(operands, surface_node, state)
    end
    operands.uniq { |operand| [operand.name, operand.target, operand.target_alloc] }
  end

  sig { params(operands: T::Array[OwnershipTransferTarget], surface_node: MIR::Node, state: OwnershipFinalizationContext).void }
  def append_ownership_transfer_targets_for_surface_node!(operands, surface_node, state)
    fact = ownership_consumption_for_node(surface_node)
    if fact.is_a?(MIR::OwnershipConsumptionFact)
      fact.operands.each do |operand|
        next if operand.borrowed || operand.name.nil?
        operands << OwnershipTransferTarget.new(
          name: T.must(operand.name),
          target: fact.target,
          target_alloc: operand.target_alloc || fact.target_alloc,
        )
      end
    elsif surface_node.is_a?(MIR::CapWrap)
      mir_ident_names(surface_node.inner).each do |name|
        next unless state.body_alloc_mark_names.include?(name.to_s) || owned_binding_visible?(name.to_s)
        operands << OwnershipTransferTarget.new(
          name: name.to_s,
          target: :owned_sink,
          target_alloc: surface_node.alloc,
        )
      end
    end

    contract = ownership_contract_for_node(surface_node)
    if contract
      contract.operands.each do |operand|
        next if operand.borrowed || operand.name.nil?
        operands << OwnershipTransferTarget.new(
          name: T.must(operand.name),
          target: :owned_sink,
          target_alloc: operand.target_alloc,
        )
      end
    end
    nil
  end

	  sig { params(node: MIR::Node).returns(T.nilable(MIR::OwnershipConsumptionFact)) }
	  def ownership_consumption_for_node(node)
	    fact = node.respond_to?(:ownership_consumption) ? node.ownership_consumption : nil
	    return fact if fact.is_a?(MIR::OwnershipConsumptionFact)
    return node.init.ownership_consumption if node.is_a?(MIR::Let) &&
      node.init.respond_to?(:ownership_consumption) &&
      node.init.ownership_consumption.is_a?(MIR::OwnershipConsumptionFact)
    return node.expr.ownership_consumption if node.is_a?(MIR::ExprStmt) &&
      node.expr.respond_to?(:ownership_consumption) &&
      node.expr.ownership_consumption.is_a?(MIR::OwnershipConsumptionFact)

    nil
  end

  sig { params(node: T.nilable(MIR::Node)).returns(T.nilable(MIR::OwnershipContract)) }
  def ownership_contract_for_node(node)
    node.is_a?(MIR::Emittable) ? node.explicit_ownership_contract : nil
  end

  sig do
    params(
      name: String,
      target: Symbol,
      guarded_cleanup_names: T::Set[String],
      target_alloc: T.nilable(Symbol),
    ).returns(MIR::OwnershipTransferPlan)
  end
  def ownership_transfer_plan(name, target, guarded_cleanup_names, target_alloc: nil)
    MIR::OwnershipTransferPlan.new(
      name: name,
      target: target,
      target_alloc: target_alloc,
      move_guarded: guarded_cleanup_names.include?(name),
    )
  end

  sig { params(name: String, target: Symbol, target_alloc: T.nilable(Symbol), move_guarded: T::Boolean).returns(T::Array[MIR::Stmt]) }
  def ownership_transfer_marks(name, target, target_alloc: nil, move_guarded: false)
    MIR::OwnershipTransferPlan.new(
      name: name,
      target: target,
      target_alloc: target_alloc,
      move_guarded: move_guarded,
    ).marks
  end

  sig { params(node: MIR::Node).returns(T::Array[String]) }
  def ownership_contract_consumes(node)
    contract = node.explicit_ownership_contract
    return [] unless contract
    contract.owned_operand_names.map(&:to_s)
  end

  sig do
    params(
      node: MIR::Node,
      names: T::Array[String],
      source: String,
      target: Symbol,
      target_alloc: T.nilable(Symbol),
      require_visible: T::Boolean,
    ).returns(MIR::Node)
  end
  def with_ownership_consumption(node, names, source, target = :owned_sink, target_alloc: nil, require_visible: true)
    operands = ownership_consumed_name_operands(names, source, target_alloc, require_visible: require_visible)
    return node if operands.empty? && !ownership_consumer_requires_fact?(node)

    node.ownership_consumption = MIR::OwnershipConsumptionFact.new(
      operands: operands,
      target: target,
      target_alloc: target_alloc,
      source: source,
      covers_consuming_params: true,
    )
    node
  end

  sig { params(node: MIR::Node).returns(T::Boolean) }
  def ownership_consumer_requires_fact?(node)
    return true if node.is_a?(MIR::ReassignWithCleanup)
    return false unless node.respond_to?(:stdlib_def)

    sig = T.unsafe(node).stdlib_def
    return false unless sig
    params = sig.respond_to?(:params) ? sig.params : nil
    return true if params.respond_to?(:any?) && params.any? { |param| param.respond_to?(:takes) && param.takes }

    sig.respond_to?(:takes_ownership?) && sig.takes_ownership?
  end

  sig { params(names: T::Array[String], source: String, target_alloc: T.nilable(Symbol), require_visible: T::Boolean).returns(T::Array[MIR::OwnershipOperandFact]) }
  def ownership_consumed_name_operands(names, source, target_alloc, require_visible: true)
    names.map(&:to_s).reject(&:empty?).uniq.filter_map do |name|
      entry = function_state.bindings[name] || CleanupEntry::NONE
      has_alloc_mark = function_state.lowered_alloc_names.include?(name)
      next nil if require_visible && !(has_alloc_mark || (entry && entry.present?))

      MIR::OwnershipOperandFact.owned_binding(name, Type.new(:Any), source, target_alloc)
    end
  end

  sig do
    params(
      node: MIR::Node,
      value_mir: MIR::Node,
      ast_value: AST::Node,
      source: String,
      target: Symbol,
      target_alloc: T.nilable(Symbol),
    ).returns(MIR::Node)
  end
  def with_ownership_consumption_for_value(node, value_mir, ast_value, source, target = :owned_sink, target_alloc: nil)
    operands = ownership_operands_for_value(value_mir, ast_value, source, target_alloc)
    return node if operands.empty? && !ownership_consumer_requires_fact?(node)

    node.ownership_consumption = MIR::OwnershipConsumptionFact.new(
      operands: operands,
      target: target,
      target_alloc: target_alloc,
      source: source,
      covers_consuming_params: true,
    )
    node
  end

	  sig { params(value_mir: MIR::Node, ast_value: AST::Node, source: String, target_alloc: T.nilable(Symbol)).returns(T::Array[MIR::OwnershipOperandFact]) }
	  def ownership_operands_for_value(value_mir, ast_value, source, target_alloc = nil)
	    ti = ownership_operand_type(ast_value, "ownership operand")
	    ownership_operands_for_sink_value(value_mir, ast_value, ti, source, target_alloc, require_visible_owned: false)
	  end

	  sig { params(value_mir: MIR::Node, ast_value: AST::Node, source: String, target_alloc: T.nilable(Symbol)).returns(T::Array[MIR::OwnershipOperandFact]) }
	  def ownership_operands_for_lowered_takes_arg(value_mir, ast_value, source, target_alloc)
	    ti = ownership_operand_type(ast_value, "ownership sink argument")
	    ownership_operands_for_sink_value(value_mir, ast_value, ti, source, target_alloc, require_visible_owned: true)
	  end

	  sig { params(ast_value: AST::Node, context: String).returns(Type) }
	  def ownership_operand_type(ast_value, context)
    coerced = ast_value.respond_to?(:coerced_type_info) ? ast_value.coerced_type_info : nil
    Type.new(coerced || ast_value.full_type!(context: context))
  end

	  sig do
	    params(
	      value_mir: MIR::Node,
	      ast_value: AST::Node,
	      ti: Type,
	      source: String,
	      target_alloc: T.nilable(Symbol),
      require_visible_owned: T::Boolean,
    ).returns(T::Array[MIR::OwnershipOperandFact])
  end
  def ownership_operands_for_sink_value(value_mir, ast_value, ti, source, target_alloc, require_visible_owned:)
    # NodeRef is a copyable generation handle. The store owns and moves the
    # payload; assigning or capturing the handle never transfers that payload.
    return [MIR::OwnershipOperandFact.non_owning(ti, source)] if ti.node_reference?

    explicit_fact = value_mir.respond_to?(:ownership_consumption) ? value_mir.ownership_consumption : nil
    if explicit_fact.is_a?(MIR::OwnershipConsumptionFact)
      return retarget_ownership_operands(explicit_fact.operands, target_alloc)
    end

    if value_mir.is_a?(MIR::Ident) && owned_binding_visible?(value_mir.name.to_s)
      return [MIR::OwnershipOperandFact.owned_binding(value_mir.name.to_s, ti, source, target_alloc)]
    end
    visible_name = mir_ident_names(value_mir).find { |name| owned_binding_visible?(name.to_s) }
    if visible_name
      return [MIR::OwnershipOperandFact.owned_binding(visible_name.to_s, ti, source, target_alloc)]
    end

    return [MIR::OwnershipOperandFact.non_owning(ti, source)] unless ownership_tracked_transfer_type?(ti)
    return [MIR::OwnershipOperandFact.non_owning(ti, source)] if rodata_ownership_ast?(ast_value)
    return [MIR::OwnershipOperandFact.non_owning(ti, source)] if non_consuming_owned_value_expr?(value_mir)

    if borrowed_ownership_ast?(ast_value)
      return [MIR::OwnershipOperandFact.borrowed_access(ownership_root_name(ast_value), ti, source, target_alloc)]
    end

    root = ownership_root_name(ast_value)
    if root
      mapped = transfer_binding_name(root)
      if owned_binding_visible?(mapped) || (!require_visible_owned && (function_state.bindings[root] || CleanupEntry::NONE).present?)
        return [MIR::OwnershipOperandFact.owned_binding(mapped, ti, source, target_alloc)]
      end
      if visible_owned_operand_value?(ast_value, value_mir, mapped)
        return [MIR::OwnershipOperandFact.owned_binding(mapped, ti, source, target_alloc)]
      end
    end

    return [] unless require_visible_owned

    [MIR::OwnershipOperandFact.borrowed_access(ownership_root_name(ast_value), ti, "#{source} missing owned binding", target_alloc)]
  end

  sig { params(ast_value: AST::Node, value_mir: MIR::Node, mapped: String).returns(T::Boolean) }
  def visible_owned_operand_value?(ast_value, value_mir, mapped)
    ast_value = ast_value.value if ast_value.is_a?(AST::MoveNode)
    !!(ast_value.is_a?(AST::Identifier) && value_mir.is_a?(MIR::Ident) &&
      value_mir.name.to_s == mapped && !borrowed_ownership_ast?(ast_value))
  end

  sig { params(operands: T::Array[MIR::OwnershipOperandFact], target_alloc: T.nilable(Symbol)).returns(T::Array[MIR::OwnershipOperandFact]) }
  def retarget_ownership_operands(operands, target_alloc)
    operands.map do |operand|
      alloc = target_alloc || operand.target_alloc
      if operand.borrowed
        MIR::OwnershipOperandFact.borrowed_access(operand.name, operand.type_info, operand.source, alloc)
      elsif operand.name
        MIR::OwnershipOperandFact.owned_binding(T.must(operand.name), operand.type_info, operand.source, alloc)
      else
        MIR::OwnershipOperandFact.non_owning(operand.type_info, operand.source)
      end
    end
  end

	  sig { params(value_mir: MIR::Node).returns(T::Boolean) }
	  def non_consuming_owned_value_expr?(value_mir)
    value_mir.is_a?(MIR::StructInit) ||
      value_mir.is_a?(MIR::ArrayInit) ||
      value_mir.is_a?(MIR::DeepCopy) ||
      value_mir.is_a?(MIR::RcRetain) ||
      value_mir.is_a?(MIR::RcDowngrade) ||
      value_mir.is_a?(MIR::WeakUpgrade)
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def rodata_ownership_ast?(node)
    ast_node = node.is_a?(AST::MoveNode) ? node.value : node
    return true if ast_node.is_a?(AST::Literal) && ast_node.type == :STRING
    !!(ast_node.respond_to?(:rodata_provenance?) && ast_node.rodata_provenance?)
  end

  sig { params(name: String).returns(T::Boolean) }
  def owned_binding_visible?(name)
    return true if (function_state.bindings[name] || CleanupEntry::NONE).present?
    return true if function_state.pending_stmts.any? { |stmt| stmt.is_a?(MIR::AllocMark) && stmt.name.to_s == name.to_s }
    return true if capture_state.current_fsm_inherited_alloc_names.include?(name)

    function_state.lowered_alloc_names.include?(name)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def borrowed_ownership_ast?(node)
    return false unless node
    return false if owner_transfer_node?(node)

    AST.borrowed_ownership_view?(node)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T.nilable(String)) }
  def ownership_root_name(node)
    current = T.let(node, T.nilable(AST::Node))
    current = current.value if current.is_a?(AST::MoveNode) || current.is_a?(AST::CopyNode) || current.is_a?(AST::CloneNode)
    current = current.target while current.is_a?(AST::GetField) || current.is_a?(AST::GetIndex)
    return current.name.to_s if current.is_a?(AST::Identifier)
    nil
  end

  sig { returns(MIRLoweringOwnershipScanner) }
  def ownership_scanner
    MIRLoweringOwnershipScanner.new(
      schema_lookup: mir_schema_lookup,
      bindings: function_state.bindings,
      capture_map: capture_state.do_capture_map || {},
      rename_map: function_state.rename_map,
      safe_name: ->(name) { zig_safe_name(name) },
    )
  end

  sig { params(stmt: T.nilable(AST::Node)).returns(T::Array[String]) }
  def collect_bg_capture_transfer_roots(stmt)
    return [] unless stmt.is_a?(AST::Locatable)

    ownership_scanner.collect_bg_capture_transfer_roots(stmt)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Array[String]) }
  def collect_explicit_move_roots(node)
    return [] unless node.is_a?(AST::Locatable)

    ownership_scanner.collect_explicit_move_roots(node)
  end

  sig { params(stmt: T.nilable(AST::Node)).returns(T::Boolean) }
  def bg_stream_boundary_stmt?(stmt)
    found = T.let(false, T::Boolean)
    AST.each_bg_block_in_stmt(stmt) { |bg| found = true if bg.is_a?(AST::BgStreamBlock) }
    found
  end

  sig { params(stmt: T.nilable(AST::Node)).returns(T::Array[String]) }
  def collect_stdlib_consumed_roots(stmt)
    names = T.let([], T::Array[String])
    walk_ast_calls(stmt) do |call|
      stdlib_call_ownership_facts(call).consumed_names.each { |name| names << name }
    end
    names.uniq
  end

  sig { params(node: T.nilable(AST::Node), blk: T.proc.params(arg0: AST::Node).void).void }
  def walk_ast_calls(node, &blk)
    return unless node.is_a?(AST::Locatable)
    yield node if AST.call?(node)
    AST.each_child_node(node) { |child| walk_ast_calls(child, &blk) }
  end

  sig { params(stmt: T.nilable(AST::Node)).returns(T::Array[String]) }
  def collect_moved_arg_roots(stmt)
    return [] unless stmt.is_a?(AST::Locatable)

    ownership_scanner.collect_moved_arg_roots(stmt)
  end

  sig { params(ti: Type).returns(T::Boolean) }
  def ownership_tracked_transfer_type?(ti)
    return false if ti.primitive? || ti.void? || ti.any? || ti.id_handle?

    ti.ownership_bearing?(T.unsafe(mir_schema_lookup))
  end

  sig { params(node: AST::Node, blk: T.proc.params(arg0: AST::Node).void).void }
  def walk_ast_for_moved_args(node, &blk)
    return unless node.is_a?(AST::Locatable)

    ownership_scanner.walk_ast_for_moved_args(node, &blk)
  end

  sig { params(arg: AST::Node).returns(T.nilable(String)) }
  def moved_arg_root(arg)
    return nil unless arg.is_a?(AST::Locatable)

    ownership_scanner.moved_arg_root(arg)
  end

  sig { params(name: String).returns(String) }
  def transfer_binding_name(name)
    ownership_scanner.transfer_binding_name(name)
  end

  sig { params(call: AST::Node).returns(MIRLoweringFunctions::CallOwnershipFacts) }
  def stdlib_call_ownership_facts(call)
    stdlib_call_facts(T.cast(call, T.any(AST::FuncCall, AST::MethodCall))).ownership
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def ownership_bearing_type?(type_info)
    type_info.ownership_bearing?(T.unsafe(mir_schema_lookup))
  end

  sig { params(arg: T.nilable(AST::Node)).returns(T.nilable(String)) }
  def consumed_binding_root(arg)
    return nil if arg.is_a?(AST::CopyNode) || arg.is_a?(AST::CloneNode)
    node = arg.is_a?(AST::MoveNode) ? arg.value : arg
    return node.name.to_s if node.is_a?(AST::Identifier)
    root = AST.root_identifier(node) rescue nil
    root&.name&.to_s
  end

  sig { params(node: AST::Node, entry: CleanupEntry).returns(String) }
  def discard_owned_zig_type(node, entry)
    return entry[:zig_type] if entry[:zig_type]
    ti = Type.from_node!(node, context: "discard owned type")
    ti = ti.success_type || ti
    return "[]const u8" if ti.string?
    ti.zig_type || Type.new(ti.resolved).zig_type
  end

  # Stamps `MIR::Stmt#source_line` (and `source_column`) from the
  # originating AST node's token. Used by the register VM emitter for
  # per-statement crash-message attribution and per-instruction
  # debugger position lookup. Lifting this from the per-stmt comment
  # injection in lower_body keeps it as the single source of truth so
  # cleanup defers, hoist temps, and other synthesized statements all
  # inherit their parent statement's position. No-op when `line` is
  # nil (synthesized fragments may have no AST origin).
  sig { params(node: MIR::Node, line: T.nilable(Integer), column: T.nilable(Integer)).void }
  def stamp_source_line!(node, line, column = nil)
    return unless line
    return unless node.respond_to?(:source_line=)
    T.unsafe(node).source_line ||= line
    T.unsafe(node).source_column ||= column if node.respond_to?(:source_column=) && column
  end

  # Like lower_body, but the last user-visible statement becomes break :label expr
  # instead of a regular statement. Used for IF/MATCH expression branches.
  sig { params(stmts: T::Array[LowerableStmt], label: String).returns(T::Array[MIR::Emittable]) }
  def lower_body_with_break(stmts, label)
    return [] if stmts.empty?

    # Find the last non-old-MIR-verification node (the result expression)
    last_user_idx = stmts.rindex { |s|
      !s.is_a?(MIR::Drop) && !s.is_a?(MIR::AllocMark) &&
      !s.is_a?(MIR::Return) && !s.is_a?(MIR::SuppressCleanup) &&
      !s.is_a?(MIR::ReassignCleanup) && !s.is_a?(MIR::FieldCleanup)
    }
    return lower_body(stmts) unless last_user_idx

    prefix_lowered = lower_body(stmts[0...last_user_idx] || [])
    result_mir = lower(T.must(stmts[last_user_idx]))
    pending = flush_pending
    suffix_lowered = lower_body(stmts.drop(last_user_idx + 1))

    tail = pending + suffix_lowered + [MIR::BreakStmt.new(label, T.cast(result_mir, MIR::Node))]
    prefix_lowered + normalize_allocating_mir_body(tail)
  end

  # Lower a full program into MIR::Program with standard imports + footer.
  sig { params(node: AST::Program, use_c_allocator: T::Boolean, needs_safety: T::Boolean, use_debug_allocator: T::Boolean).returns(T.nilable(MIR::Program)) }
  def lower_program(node, use_c_allocator: false, needs_safety: false, use_debug_allocator: false)
    MIRPassState.require!(node, :mir_pass_complete, consumer: "MIRLowering")
    program_state.use_debug_allocator = use_debug_allocator
    program_state.fn_nodes = node.statements.each_with_object({}) do |stmt, acc|
      acc[stmt.name.to_s] = stmt if stmt.is_a?(AST::FunctionDef)
    end
    items = []

    # Auto-detect safety runtime needs from guarded reentrance variants.
    needs_safety ||= node.statements.any? { |s| s.is_a?(AST::FunctionDef) && s.reentrance_guard_required? }

    # Standard imports
    items << MIR::Import.new("std", "std", nil)
    items << MIR::Import.new("CheatHeader", "runtime/runtime-header.zig", nil)
    items << MIR::TypeAlias.new("CheatLib", "CheatHeader.CheatLib")
    items << MIR::TypeAlias.new("Runtime", "CheatHeader.Runtime")
    items << MIR::TypeAlias.new("EbrContext", "CheatHeader.EbrContext")
    items << MIR::Import.new("safety", "runtime/../lib/safety.zig", nil) if needs_safety

    if use_c_allocator || program_state.used_sharded_map
      items << MIR::PubConst.new("USE_C_ALLOCATOR", "true")
    end
    if program_state.use_debug_allocator
      items << MIR::PubConst.new("USE_DEBUG_ALLOCATOR", "true")
    end

    # Lower each statement, adding source line comments
    node.statements.each do |stmt|
      append_lowered_items!(LoweredItemTarget.new(items: items, line: stmt.token&.line), lower(stmt))
    end

    state = MIRPassState.for!(node).copy
    state.mark!(:mir_lowered)
    MIR::Program.new(items, state)
  end

  sig { params(target: LoweredItemTarget, lowered: T.nilable(LoweredMir)).void }
  def append_lowered_items!(target, lowered)
    return unless lowered

    nodes = lowered.is_a?(::Array) ? lowered : [lowered]
    nodes.each_with_index do |node, index|
      target.items << MIR::Comment.new("CLR:#{target.line}") if index.zero? && target.line
      target.items << node
    end
    nil
  end

  # Lower a module AST into MIR items for inlining via REQUIRE.
  # Emits only public declarations (types + functions + re-exports).
  # No standard imports or runtime footer -- the importing file provides those.
  #
  # Returns { items: [MIR nodes], type_items: [MIR type nodes] }
  sig { params(node: AST::Program).returns(LoweredModuleItems) }
  def lower_module(node)
    MIRPassState.require!(node, :mir_pass_complete, consumer: "MIRLowering.lower_module")
    type_items = T.let([], T::Array[MIR::Emittable])
    fn_items = T.let([], T::Array[MIR::Emittable])

    node.statements.each do |stmt|
      case stmt
      when AST::FunctionDef
        next if stmt.visibility == :private
        append_lowered_items!(LoweredItemTarget.new(items: fn_items, line: stmt.token.line), lower(stmt))
      when AST::StructDef, AST::EnumDef, AST::UnionDef
        next if stmt.visibility == :private
        append_lowered_items!(LoweredItemTarget.new(items: type_items, line: stmt.token.line), lower(stmt))
      when AST::RequireNode
        append_lowered_items!(LoweredItemTarget.new(items: fn_items, line: nil), lower(stmt))
      when AST::ExternFnDecl, AST::ExternStructDecl
        append_lowered_items!(LoweredItemTarget.new(items: fn_items, line: stmt.token.line), lower(stmt))
      end
    end

    LoweredModuleItems.new(items: fn_items, type_items: type_items)
  end

  private

  # ================================================================
  # Name and type helpers
  # ================================================================

  sig { params(name: String).returns(String) }
  def zig_safe_name(name)
    cleaned = (name.end_with?('!') || name.end_with?('?')) ? name[0..-2] : name
    cleaned = Compiler::Entrypoint::ZIG_NAME if cleaned == Compiler::Entrypoint::NAME
    cleaned = T.must(cleaned)
    ZigType.primitive_numeric_identifier?(cleaned) ? "@\"#{cleaned}\"" : cleaned
  end

  # Stable Zig identifier for a hidden per-type @node store. Avoid text/regex
  # rewriting in MIR: this is a character-wise identifier encoding, not a
  # rewrite of generated Zig expressions.
  sig { params(zig_type: String, shared: T::Boolean).returns(String) }
  def node_store_binding_name(zig_type, shared: false)
    encoded = zig_type.each_char.map do |char|
      alpha = (char >= "A" && char <= "Z") || (char >= "a" && char <= "z")
      digit = char >= "0" && char <= "9"
      alpha || digit || char == "_" ? char : "_"
    end.join
    shared ? "__shared_node_guard_#{encoded}" : "__node_store_#{encoded}"
  end

  sig { params(node: AST::Node).returns(Symbol) }
  def alloc_for_node(node)
    placement_for_node(node)
  end

  sig do
    type_parameters(:U)
      .params(alloc: T.nilable(Symbol), blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_decl_alloc(alloc, &blk)
    prev = function_state.current_decl_alloc
    function_state.current_decl_alloc = alloc
    blk.call
  ensure
    function_state.current_decl_alloc = prev
  end

  sig do
    type_parameters(:U)
      .params(type_info: T.nilable(Type), blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_expected_type(type_info, &blk)
    prev = function_state.current_expected_type
    function_state.current_expected_type = type_info
    blk.call
  ensure
    function_state.current_expected_type = prev
  end

  sig do
    type_parameters(:U)
      .params(type_info: T.nilable(Type), blk: T.proc.returns(T.type_parameter(:U)))
      .returns(T.type_parameter(:U))
  end
  def with_sink_type(type_info, &blk)
    prev = function_state.current_sink_type
    function_state.current_sink_type = type_info
    blk.call
  ensure
    function_state.current_sink_type = prev
  end

	  sig { params(callee_param: T.nilable(AST::Param)).returns(Symbol) }
	  def allocator_for_takes_param!(callee_param)
	    Kernel.raise "TAKES argument allocator requested without a callee parameter" unless callee_param
	    :heap
	  end

	  sig { params(arg: AST::Node, callee_param: T.nilable(AST::Param)).returns(T::Boolean) }
	  def call_arg_consumes_ownership?(arg, callee_param)
	    !!(callee_param && callee_param.respond_to?(:takes) && callee_param.takes)
	  end

  sig { params(node: T.nilable(AST::Node)).returns(T.nilable(Symbol)) }
  def symbol_storage_for_node(node)
    return nil unless node
    sym = node.respond_to?(:symbol) ? node.symbol : nil
    return nil unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    auth = (decl && decl.respond_to?(:symbol) && decl.symbol) || sym
    storage = auth.storage
    auth.heap_storage? ? :heap : :frame
  end

  sig { params(node: AST::Node).returns(Symbol) }
  def placement_for_node(node)
    node = node.value if node.is_a?(AST::MoveNode)
    root = root_receiver_node(node) || node
    if root.is_a?(AST::Identifier)
      alias_alloc = capability_state.with_alias_alloc_map&.[](root.name.to_s)
      return alias_alloc if alias_alloc
      return :heap if current_function_collection_param?(root.name)
      entry = function_state.bindings[root.name.to_s]
      return entry.alloc if entry&.alloc
    end
    if root.is_a?(AST::Identifier)
      sym = root.symbol
      lifetime_sources = sym&.lifetime_sources || []
      if !lifetime_sources.empty?
        return :heap if lifetime_sources.any?(&:heap_storage?)
        return :frame
      end
    end
    symbol_storage_for_node(root) || function_state.current_decl_alloc || :frame
  end


  sig { params(kind: Symbol, _rt_name: T.nilable(T.any(String, Symbol, MIR::Emittable))).returns(Symbol) }
  def alloc_expr(kind, _rt_name = nil)
    MIR::Placement.alloc(kind, :frame)
  end

  sig { params(sym: Symbol).returns(Symbol) }
  def alloc_from_sym(sym)
    MIR::Placement.alloc(sym, :heap)
  end

  # Resolve a registry alloc symbol (:heap, :frame, :receiver_storage, :node_storage)
  # to a concrete :heap/:frame symbol for structural allocator metadata.
  sig { params(alloc_sym: Symbol, target_node: T.nilable(AST::Node), node: T.nilable(AST::Node)).returns(Symbol) }
  def resolve_alloc_sym(alloc_sym, target_node = nil, node = nil)
    case alloc_sym
    when :frame then :frame
    when :receiver_storage
      receiver = target_node
      receiver ||= node.object if node.is_a?(AST::MethodCall)
      receiver ||= node.args.first if node.is_a?(AST::FuncCall) && node.mutates_receiver
      root = root_receiver_node(receiver)
      selected = T.cast(root || receiver || node, AST::Node)
      selected_type = Type.from_node!(selected, context: "allocator receiver")
      return :heap if selected_type.node_reference?

      placement_for_node(selected)
    when :node_storage
      function_state.current_decl_alloc || placement_for_node(T.cast(target_node || node, AST::Node))
    else :heap
    end
  end

  # Shared root resolution for checker attribution and receiver allocator lookup.
  sig { params(node: T.nilable(AST::Node)).returns(T.nilable(AST::Identifier)) }
  def root_receiver_node(node)
    return nil unless node.is_a?(AST::Locatable)

    root = AST.root_identifier(node)
    return root if root
    case node
    when AST::GetField, AST::GetIndex, AST::OptionalUnwrap, AST::Slice
      root_receiver_node(node.target)
    else
      nil
    end
  end

  # Extract root variable name from a potentially nested AST node (e.g., pool[id]?.vars).
  sig { params(node: AST::Node).returns(T.nilable(String)) }
  def extract_root_var_name(node)
    root = root_receiver_node(node)
    return nil unless root.is_a?(AST::Identifier)
    owner = capability_state.with_alias_owner_map&.[](root.name.to_s)
    return owner if owner

    decl = root.symbol&.reg
    (decl && function_state.decl_zig_names[decl.object_id]) || root.name.to_s
  end

  # Produce a MIR::Cast node for type coercion, or nil if no cast needed.
  # Mirrors transpile_cast logic but returns MIR nodes instead of strings.
  sig { params(mir_node: MIR::Node, from_type: Type, to_type: Type::TypeInput).returns(T.nilable(MIR::Cast)) }
  def mir_cast(mir_node, from_type, to_type)
    from_t = from_type
    to_t   = to_type.is_a?(Type)   ? to_type   : Type.new(to_type)
    return nil if from_t.semantic_type_key == to_t.semantic_type_key
    # @indirect is constructed by destination placement (HeapCreate); it is
    # not a Zig coercion. Emitting `@as(*T, value)` here wraps the payload in a
    # pointer cast before HeapCreate, so the generated initializer tries to
    # assign `*T` into a `T` cell. Keep numeric/shape coercions intact, but let
    # the dedicated placement step perform this same-payload layout change.
    if to_t.indirect? && !from_t.indirect? && from_t.resolved == to_t.resolved
      return nil
    end
    # Placement and constraint metadata can differ while the emitted value
    # representation is identical. Do not manufacture an @as cast in that
    # case; capability-changing coercions still differ in zig_type and fall
    # through to the real cast paths below.
    return nil if from_t.zig_type == to_t.zig_type

    # Keep the complete destination shape. Reducing this to `resolved` drops
    # optionality and ownership, turning `?T@multiowned` into `?T` in Zig.
    zig_to = transpile_type(to_t)

    # fn_type: generic @as cast
    return MIR::Cast.new(mir_node, zig_to, :as) if from_t.fn_type? || to_t.fn_type?

    # Int -> Float
    if from_t.integer? && to_t.float?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :floatFromInt), zig_to, :as)
    end

    # Float -> Int
    if from_t.float? && to_t.integer?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :intFromFloat), zig_to, :as)
    end

    # Int -> Int
    if from_t.integer? && to_t.integer?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :intCast), zig_to, :as)
    end

    # Float -> Float
    if from_t.float? && to_t.float?
      return MIR::Cast.new(MIR::Cast.new(mir_node, nil, :floatCast), zig_to, :as)
    end

    # Array coercions, HashMap coercions, error union coercions -- no cast needed
    return nil if from_t.dynamic? && to_t.dynamic?
    return nil if from_t.fixed? && to_t.empty_list?
    # Fixed-size array (`T[N]`) -> typed slice (`T[]`): no cast needed.
    # The downstream argument-position `MIR::ItemsAccess` handles the
    # slice coercion via `<expr>[0..]`. Without this skip, the
    # `mir_cast` fallback below wraps the identifier with
    # `@as(std.ArrayListUnmanaged(T), <fixed>)`, which Zig rejects
    # because a `[N]T` does not coerce to an ArrayList.
    if from_t.fixed? && to_t.dynamic?
      from_elem = from_t.element_type
      to_elem = to_t.element_type
      return nil if from_elem && to_elem && Type.surface_name(from_elem) == Type.surface_name(to_elem)
    end
    return nil if from_t.map? && to_t.map?
    if to_t.error_union?
      payload_type = T.must(to_t.payload_type)
      from_matches = Type.surface_name(from_t) == Type.surface_name(payload_type)
      from_matches ||= from_t.string? && payload_type.string?
      return nil if from_matches
    end

    # Fallback: @as cast
    MIR::Cast.new(mir_node, zig_to, :as)
  end

  # ================================================================
  # Cleanup entry helpers (moved from MIRPass/control_flow.rb)
  # ================================================================

  # No-op: cleanup emit now uses @TypeOf(name) at the call site, so the
  # entry needs no precomputed zig_type / elem_zig_type. Kept as a hook
  # in case future per-kind metadata needs to be stamped at lowering time.
  sig { params(entry: CleanupEntry, ti: Type, source_node: T.nilable(AST::VarDecl)).returns(T.nilable(T::Boolean)) }
  def build_drop_entry!(entry, ti, source_node)
    nil
  end

  # ================================================================
  # Old MIR translation (MATCH AS bindings still use Drop/Alloc)
  # ================================================================

  sig { params(node: MIR::Drop).returns(MIR::Cleanup) }
  def lower_drop(node)
    safe = zig_safe_name(node.name)
    entry = node.cleanup_entry
    has_guard = entry.respond_to?(:has_moved_guard?) ? entry.has_moved_guard? : !!(entry.respond_to?(:[]) && entry[:has_moved_guard])
    function_state.guarded_cleanup_names[safe] = true if has_guard
    MIR::Cleanup.new(safe, node.cleanup_entry)
  end

  # ================================================================
  # Type definitions
  # ================================================================

  sig { params(node: AST::EnumDef).returns(MIR::EnumDef) }
  def lower_enum_def(node)
    lowering_schemas.register_enum(node.name, node.variants)
    MIR::EnumDef.new(node.name, node.variants.map(&:to_s), nil)
  end

  sig { params(node: AST::Node).returns(MIR::Emittable) }
  def lower_field_default(node)
    case node
    when AST::DefaultLit then MIR::DefaultValue.new(kind: :aggregate_empty)
    else T.cast(lower(node), MIR::Emittable)
    end
  end

  sig { params(field: AST::StructField).returns(T.nilable(MIR::Emittable)) }
  def lower_struct_field_default(field)
    if field.type.optional? && field.type.node_reference? &&
       field.default.is_a?(AST::Literal) && field.default.value.nil?
      return MIR::StructInit.new(field.type.zig_type(is_field: true), [])
    end
    return lower_field_default(T.must(field.default)) if field.default

    type = field.type
    if type.optional? && type.node_reference?
      return MIR::StructInit.new(type.zig_type(is_field: true), [])
    end
    if type.list_collection?
      return MIR::ContainerInit.new(type.zig_type(is_field: true), :array_list_empty, nil, nil)
    end

    nil
  end

  sig { params(node: AST::StructDef).returns(MIR::Node) }
  def lower_struct_def(node)
    lowering_schemas.register_struct(node.name, Schemas::StructSchema.new(fields: node.field_decls))

    if node.type_params.any?
      # Generic struct: fn Name(comptime T: type) type { return struct { ... }; }
      comptime_params = node.type_params.map { |p| "comptime #{p}: type" }
      fields_mir = node.field_decls.map { |name, fd|
        zig_t = transpile_type(fd.type, is_field: true)
        default_mir = lower_struct_field_default(fd)
        MIR::FieldDef.new(name.to_s, zig_t, default_mir)
      }
      inner_struct = MIR::StructDef.new(nil, fields_mir, nil, nil)
      body = [MIR::ReturnStmt.new(inner_struct)]
      MIR::FnDef.new(node.name, [], "type", body, nil, false, comptime_params)
    else
      fields = node.field_decls.map { |name, fd|
        zig_t = transpile_type(fd.type, is_field: true)
        default_mir = lower_struct_field_default(fd)
        MIR::FieldDef.new(name.to_s, zig_t, default_mir)
      }
      MIR::StructDef.new(node.name, fields, nil, nil)
    end
  end

  sig { params(node: AST::UnionDef).returns(LoweredMir) }
  def lower_union_def(node)
    lowering_schemas.register_union(node.name, Schemas::UnionSchema.new(variants: node.variants))
    variant_facts = union_variant_lowering_facts(node)

    # Emit helper structs for inline struct variants
    helper_structs = variant_facts.filter_map do |fact|
      next unless fact.inline_struct
      data = T.cast(fact.data, Schemas::InlineStructVariant)

      fields = data.fields.map { |fname, ftype|
        zig_t = transpile_type(T.unsafe(ftype), is_field: true)
        MIR::FieldDef.new(fname.to_s, zig_t, nil)
      }

      alloc_ref = MIR::Ident.new("alloc")
      self_ref  = MIR::Ident.new("self")
      deinit_entries = data.deinit_entries
      deinit_stmts = deinit_entries.flat_map { |de|
        self_field = MIR::FieldGet.new(self_ref, de.field)
        case de.kind
        when :indirect
          [
            MIR::ExprStmt.new(
              emit_builtin(:cleanup, [MIR::Ident.new(T.must(de.zig_type)), alloc_ref, self_field]),
              false
            ),
            MIR::ExprStmt.new(MIR::DestroyPtr.new(self_field, alloc_ref), false),
          ]
        when :uniform
          [
            MIR::ExprStmt.new(
              emit_builtin(:cleanup, [
                MIR::Ident.new(T.must(de.zig_type)),
                alloc_ref,
                MIR::AddressOf.new(self_field),
              ]),
              false
            ),
          ]
        when :array
          elem_zig = MIR::Ident.new(T.must(de.elem_zig_type))
          loop_body = [
            MIR::ExprStmt.new(
              emit_builtin(:cleanup, [elem_zig, alloc_ref, MIR::Ident.new("__e")]),
              false
            ),
          ]
          for_loop = MIR::ForStmt.new(self_field, "*__e", loop_body, nil, false, false)
          cleanup_guard = MIR::IfStmt.new(
            MIR::Comptime.new(emit_builtin(:needsCleanup, [elem_zig])),
            [for_loop],
            nil
          )
          len_guard = MIR::IfStmt.new(
            MIR::BinOp.new(">", MIR::ListLength.new(self_field), MIR::Lit.new("0")),
            [MIR::ExprStmt.new(MIR::FreeSlice.new(self_field, alloc_ref), false)],
            nil
          )
          [cleanup_guard, len_guard]
        else []
        end
      }

      methods = if deinit_stmts.any?
        deinit_fn = MIR::FnDef.new(
          "deinit",
          [MIR::Param.new("self", "*@This()", false), MIR::Param.new("alloc", "std.mem.Allocator", false)],
          "void",
          deinit_stmts,
          :pub
        )

        result_ref = MIR::Ident.new("result")
        dupe_stmts = T.let([
          MIR::Let.new("result", MIR::Ident.new("self"), true, nil, nil, nil)
        ], T::Array[MIR::Stmt])

        deinit_entries.each do |de|
          tmp_name = "__dupe_#{de.field}"
          field_source = "self.#{de.field}"
          dupe_stmts << MIR::Let.new(
            tmp_name,
            MIR::Lit.new("try CheatLib.dupeValue(@TypeOf(#{field_source}), #{field_source}, alloc)"),
            false,
            nil,
            nil,
            nil
          )
          dupe_stmts << MIR::ExprStmt.new(
            MIR::Lit.new("errdefer CheatLib.cleanup(@TypeOf(#{tmp_name}), alloc, &#{tmp_name})"),
            false
          )
          dupe_stmts << MIR::Set.new(
            MIR::FieldGet.new(result_ref, de.field),
            MIR::Ident.new(tmp_name),
            false
          )
        end

        dupe_stmts << MIR::ReturnStmt.new(result_ref)

        dupe_fn = MIR::FnDef.new(
          "dupe",
          [MIR::Param.new("self", "@This()", false), MIR::Param.new("alloc", "std.mem.Allocator", false)],
          "!@This()",
          dupe_stmts,
          :pub
        )
        [deinit_fn, dupe_fn]
      end

      MIR::StructDef.new(fact.helper_name, fields, methods, nil)
    end

    # Build variant list
    variants = variant_facts.map { |fact| MIR::UnionTypeVariant.new(name: fact.name, zig_type: fact.zig_type) }

    if node.type_params.any?
      # Generic union: fn Name(comptime T: type) type { return union(enum) { ... }; }
      comptime_params = node.type_params.map { |p| "comptime #{p}: type" }
      inner_union = MIR::UnionTypeDef.new(nil, variants, nil)
      body = [MIR::ReturnStmt.new(inner_union)]
      generic_fn = MIR::FnDef.new(node.name, [], "type", body, nil, false, comptime_params)
      if helper_structs.any?
        helper_structs + [generic_fn]
      else
        generic_fn
      end
    else
      union_node = MIR::UnionTypeDef.new(node.name, variants, nil)
      if helper_structs.any?
        helper_structs + [union_node]
      else
        union_node
      end
    end
  end

  sig { params(node: AST::UnionDef).returns(T::Array[UnionVariantLoweringFact]) }
  def union_variant_lowering_facts(node)
    node.variants.map do |var_name, var_data|
      inline_struct = Schemas.inline_struct?(var_data)
      name = var_name.to_s
      zig_type =
        if var_data.nil?
          "void"
        elsif inline_struct
          "#{node.name}_#{name}"
        else
          transpile_type(var_data, is_field: true)
        end
      UnionVariantLoweringFact.new(
        owner_name: node.name.to_s,
        name: name,
        data: var_data,
        inline_struct: inline_struct,
        zig_type: zig_type,
      )
    end
  end

  # Module roots that resolve as Zig MODULES (not relative .zig files):
  # - std, builtin: Zig stdlib
  # - cheat_runtime: CLEAR runtime, wired via build.zig as a module
  EXTERN_MODULE_ROOTS = T.let(%w[std builtin cheat_runtime].to_set.freeze, T::Set[String])

  sig { params(node: AST::Cast).returns(MIR::Cast) }
  def lower_cast(node)
    inner = lower(node.value)
    target_type = transpile_type(node.target)

    # Int -> enum: emit `@enumFromInt(value)` instead of `@as(EnumT, value)`.
    # Modern Zig rejects `@as(EnumT, intExpr)` (type coercion is enum-from-
    # int, which is its own builtin). Detected by checking whether the
    # target's underlying type matches a registered enum schema.
    #
    # Strip the optional `?` and error-union `!` prefixes from the resolved
    # name before lookup so `CAST(x AS ?MyEnum)` and `CAST(x AS !MyEnum)`
    # also route through the builtin -- otherwise the schema lookup misses
    # and we emit `@as(?MyEnum, intExpr)` which Zig also rejects.
    target_base = Type.new(node.target).value_payload_type.resolved
    if enum_schemas.key?(target_base)
      return MIR::Cast.new(inner, target_type, :enumFromInt)
    end

    MIR::Cast.new(inner, target_type, :as)
  end

  # ================================================================
  # Concurrent / capability blocks
  # ================================================================

  # WITH-capture helpers. Group 1 (sync/ownership) on a binding can apply
  # to either the whole binding (Identifier capture) or to a specific
  # field of it (GetField capture, e.g. `WITH EXCLUSIVE env.vars AS v`).
  # These helpers paper over the difference for the lowering loop.

  # User-visible name of the bound entity — used for naming guard vars.
  sig { params(node: AST::StaticCall).returns(T.any(MIR::InlineBc, MIR::RegistryCall)) }
  def lower_static_call(node)
    # Structural MIR::InlineBc when the matched stdlib_def opts in via
    # bc:true. Both backends consume the same node: Zig emits via
    # emit_inline_bc_as_zig (substituting {0}, {1}, ... from stdlib_def[:zig]),
    # BC dispatches by op symbol in compile_inline_bc.
    stdlib_def = FunctionSignature.unwrap(node.matched_stdlib_def)
    raise "lower_static_call: missing stdlib signature for #{node.class.name}" unless stdlib_def

    if stdlib_def.intrinsic_bc?
      mir_args = node.args.map { |a| hoist_alloc(lower(a), a) }
      return MIR::InlineBc.new(stdlib_def.intrinsic_bc_op_or(node.method_name.to_s.to_sym), mir_args, stdlib_def)
    end

    # Hoist any heap-allocating args to named Lets via hoist_alloc so the
    # checker can verify their cleanup. Non-allocating args (and frame allocs)
    # stay as MIR children of the registry call expression.
    mir_args = node.args.map { |a| hoist_alloc(lower(a), a) }
    MIR::RegistryCall.new(
      entry: stdlib_def,
      args: mir_args.map { |arg| MIR::RegistryCallArg.new(expr: arg) },
      reason: "static_call",
    )
  end

  sig { params(node: AST::OrElseExit).returns(MIR::ScopeBlock) }
  def lower_or_else_exit(node)
    facts = or_else_exit_facts(node, node.token.line)

    # Register VM: structural sibling of the Zig backend sequence below.
    # The bc emitter cannot parse Zig (CLAUDE.md), so carry the
    # reassignment as one InlineBc with structured fields. The Zig
    # backend path (target != :bc) is byte-for-byte unchanged.
    if bc_target?
      msg_mir = node.message ? lower(node.message) : nil
      return MIR::ScopeBlock.new([
        MIR::ExprStmt.new(or_else_exit_bc_reassign(facts, msg_mir), false),
        MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError"))
      ])
    end

    msg_mir = node.message ? lower(node.message) : nil
    or_else_exit_scope(facts, msg_mir, MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError"))
  end

  # Test-framework MIR lowering (lower_test_block, lower_assert_raises,
  # lower_stub_decl, lower_benchmark, lower_smash, lower_profile,
  # stub_intercept_for, stub_local_idents, TEST_PREAMBLE) is mixed in
  # from src/mir/test_lowering.rb (TestLowering module).

  sig { params(node: AST::RequireNode).returns(LoweredMir) }
  def lower_require(node)
    # Stdlib packages auto-resolve to <repo>/stdlib/<name>/src/lib.clear
    # and are inlined into single-binary builds (no separate .zig is
    # produced for them). User-registered packages (--pkg name=...)
    # keep the @import emission so an outer build.zig can orchestrate
    # per-package compilation.
    importer = program_state.importer
    pkg_inline = node.kind == :package && importer && importer.stdlib_package?(node.path)

    if node.kind == :package && !pkg_inline
      MIR::Import.new(node.namespace || node.path, "#{node.namespace || node.path}.zig", nil)
    else
      # Local require / stdlib package: compile the module and inline its
      # structural MIR. Local uses compile_file (path); stdlib uses
      # compile_package (name → resolved path).
      raise "MIRLowering: REQUIRE \"#{node.path}\" but no importer available" unless importer

      mod = if pkg_inline
        importer.compile_package(node.path, caller_dir: T.must(program_state.source_dir))
      else
        importer.compile_file(node.path, caller_dir: T.must(program_state.source_dir))
      end

      # Merge schemas so downstream code can resolve imported types
      merge_module_schemas!(T.must(mod))

      # Propagate fn_sigs from imported functions. When `full_type` is
      # not a FunctionSignature (some annotator paths leave it as a
      # `Type`), reconstruct from the FunctionDef's own param list so
      # call-site routing decisions that consult `callee_sig.params[idx]`
      # (MUTABLE @list detection, takes/borrow, etc.) work for cross-file
      # callees too. Without this, the lowering silently sees an empty
      # param list and emits the wrong arg shape (e.g. `.items` instead
      # of `&xs` for a MUTABLE @list parameter).
      if T.must(mod).ast
        T.must(mod).ast.statements.each do |stmt|
          next unless stmt.is_a?(AST::FunctionDef)
          next if stmt.name == Compiler::Entrypoint::NAME
          fn_sigs[stmt.name] = FunctionSignature.from_function_def(stmt)
        end
      end

      # Emit visible type definitions at file scope, then imported functions in
      # a structural namespace wrapper. The namespace body is imported MIR from
      # ModuleImporter, not a pre-rendered Zig blob, so checker/emitter traversal
      # still sees function bodies and nested imports.
      same_dir = T.must(mod).source_dir == program_state.source_dir
      dependency_items = imported_module_dependency_items(T.must(mod))
      namespace_items = imported_module_items(T.must(mod))

      # VM target also needs the imported function bodies as MIR FnDefs so the
      # bytecode emitter can lay out helpers and resolve namespaced calls
      # (e.g. `require_helper.addPub`). Lower each public function from the
      # module AST and tag its name with the importer namespace; the call-site
      # lookup in bc_emitter treats `<ns>.<fn>` as a synonym for the bare name.
      if bc_target?
        helper_fns = imported_bc_helper_fns(T.must(mod), namespace_items)
        return helper_fns if helper_fns.any?
      end

      module_key = T.must(mod).object_id
      return [] unless program_state.emitted_require_modules.add?(module_key.to_s)

      [
        *dependency_items,
        *visible_type_items(T.must(mod), same_dir: same_dir),
        MIR::ModuleNamespace.new(node.namespace, namespace_items),
      ]
    end
  end

  sig { params(mod: ModuleImporter::CompiledModule).void }
  def merge_module_schemas!(mod)
    struct_schemas = mod.struct_schemas
    enum_schemas = mod.enum_schemas
    union_schemas = mod.union_schemas

    lowering_schemas.merge!(
      struct_schemas: struct_schemas,
      enum_schemas: enum_schemas,
      union_schemas: union_schemas,
    )
  end

  sig { params(mod: ModuleImporter::CompiledModule, same_dir: T::Boolean).returns(T::Array[MIR::Emittable]) }
  def visible_type_items(mod, same_dir: false)
    items = mod.type_items
    return [] unless items

    visible_names = visible_imported_type_names(mod, same_dir: same_dir)
    return [] if visible_names.empty?

    items.filter_map do |item|
      next nil unless item.is_a?(MIR::Emittable)
      next nil unless item.is_a?(MIR::NamedEmittable)

      item if visible_names.include?(item.name.to_s)
    end
  end

  sig { params(mod: ModuleImporter::CompiledModule, same_dir: T::Boolean).returns(T::Set[String]) }
  def visible_imported_type_names(mod, same_dir: false)
    visible_names = Set.new
    return visible_names unless mod.ast

    mod.ast.statements.each do |stmt|
      case stmt
      when AST::StructDef, AST::EnumDef, AST::UnionDef
        vis = stmt.visibility || :package
        next if vis == :private
        next unless (vis == :pub) || same_dir
        name = stmt.name.to_s
        next if program_state.emitted_types.include?(name)
        visible_names.add(name)
        program_state.emitted_types.add(name)
        if stmt.is_a?(AST::UnionDef)
          stmt.variants.each do |var_name, var_data|
            next unless Schemas.inline_struct?(var_data)
            syn = "#{stmt.name}_#{var_name}"
            visible_names.add(syn)
            program_state.emitted_types.add(syn)
          end
        end
      end
    end

    visible_names
  end

  sig { params(mod: ModuleImporter::CompiledModule).returns(T::Array[MIR::Emittable]) }
  def imported_module_items(mod)
    if mod.ast
      hidden_type_items = mod.ast.statements.filter_map do |stmt|
        next nil unless hidden_imported_type_statement?(stmt, mod)
        lower(stmt)
      end

      fn_items = mod.ast.statements.filter_map do |stmt|
        next nil if stmt.is_a?(AST::FunctionDef) && stmt.name == Compiler::Entrypoint::NAME
        next lower_function_def(stmt) if stmt.is_a?(AST::FunctionDef)
        next lower(stmt) if stmt.is_a?(AST::ExternFnDecl) || stmt.is_a?(AST::ExternStructDecl)

        nil
      end.flatten.select { |item| item.is_a?(MIR::Emittable) }

      return [hidden_type_items, fn_items].flatten.select { |item| item.is_a?(MIR::Emittable) }
    end

    items = mod.mir_items
    return items.select { |item| importable_module_item?(item) } if items.is_a?(Array)
    []
  end

  sig { params(stmt: AST::Node, mod: ModuleImporter::CompiledModule).returns(T::Boolean) }
  def hidden_imported_type_statement?(stmt, mod)
    return false unless stmt.is_a?(AST::StructDef) || stmt.is_a?(AST::EnumDef) || stmt.is_a?(AST::UnionDef)

    same_dir = mod.source_dir == program_state.source_dir
    vis = stmt.visibility || :package
    return false if vis == :pub
    return false if vis == :package && same_dir

    true
  end
  private :hidden_imported_type_statement?

  sig { params(item: MIR::Node).returns(T::Boolean) }
  def importable_module_item?(item)
    return false if item.is_a?(MIR::FnDef) && item.name.to_s == Compiler::Entrypoint::NAME

    true
  end
  private :importable_module_item?

  sig { params(mod: ModuleImporter::CompiledModule).returns(T::Array[MIR::Emittable]) }
  def imported_module_dependency_items(mod)
    return [] unless mod.ast

    prev_source_dir = program_state.source_dir
    program_state.source_dir = mod.source_dir
    mod.ast.statements.filter_map do |stmt|
      next nil unless stmt.is_a?(AST::RequireNode)
      lower_require(stmt)
    end.flatten.select { |item| item.is_a?(MIR::Emittable) }
  ensure
    program_state.source_dir = prev_source_dir
  end

  sig { params(mod: ModuleImporter::CompiledModule, items: T::Array[MIR::Emittable]).returns(T::Array[MIR::FnDef]) }
  def imported_bc_helper_fns(mod, items)
    items.filter_map do |item|
      next nil unless item.is_a?(MIR::FnDef)
      item
    end
  end

  # ================================================================
  # Helpers for concurrent blocks
  # ================================================================

  STACK_SIZE_ZIG_VARIANT = T.let({
    nil       => "Standard",
    :micro    => "Micro", :standard => "Standard", :large => "Large", :xl => "Xl",
    "micro"   => "Micro", "standard" => "Standard", "large" => "Large", "xl" => "Xl",
    :service  => "Huge",
  }.freeze, T::Hash[T.untyped, T.untyped])

  TIER_RANK = T.let({ "Micro" => 0, "Standard" => 1, "Large" => 2, "Xl" => 3, "Huge" => 4 }.freeze, T::Hash[T.untyped, T.untyped])

  sig { params(stack_size: T.nilable(Symbol), computed_tier: T.nilable(Symbol)).returns(String) }
  def task_config_variant(stack_size, computed_tier)
    default = program_state.debug_mode ? "Large" : "Standard"
    if stack_size
      if stack_size == :stack
        STACK_SIZE_ZIG_VARIANT.fetch(computed_tier || :standard, default)
      else
        STACK_SIZE_ZIG_VARIANT.fetch(stack_size, default)
      end
    elsif computed_tier
      computed = STACK_SIZE_ZIG_VARIANT.fetch(computed_tier, default)
      TIER_RANK.fetch(computed, 0) >= TIER_RANK.fetch(default, 0) ? computed : default
    else
      default
    end
  end

  sig { params(dispatch: BackgroundDispatch).returns(Integer) }
  def profile_dispatch_id(dispatch)
    case dispatch
    when :parallel then 2
    when :shared then 3
    else 1
    end
  end

  sig { params(site_id: Integer, line: Integer, col: Integer, dispatch: BackgroundDispatch, form: Symbol).returns(String) }
  def bg_profile_site_comment(site_id, line, col, dispatch, form)
    "// CLEAR_PROFILE_TASK_SITE id=#{site_id} kind=BG line=#{line} column=#{col} dispatch=#{dispatch} form=#{form}"
  end

  # ================================================================
  # Expressions
  # ================================================================

  sig { params(subject: MIR::Ident, pat: AST::StructPattern).returns([T::Array[MIR::Node], T::Array[MIR::Let]]) }
  def lower_struct_pattern(subject, pat)
    conditions = T.let([], T::Array[MIR::Node])
    bindings = T.let([], T::Array[MIR::Let])

    pat.fields.each do |f|
      next if f.wildcard?
      if f.bind?
        field_access = MIR::FieldGet.new(subject, f.name.to_s)
        bindings << MIR::Let.new(f.name.to_s, field_access, false, nil, "_ = &#{f.name};")
      else
        val = T.cast(lower(T.must(f.expr)), MIR::Node)
        field_access = MIR::FieldGet.new(subject, f.name.to_s)
        conditions << MIR::BinOp.new("==", field_access, val)
      end
    end

    [conditions, bindings]
  end

  sig { params(node: AST::FuncCall).returns(MIR::Call) }
  def lower_macro_print(node)
    formats = node.args.map { |arg| zig_format_for_type(arg.full_type!) }.join(" ")
    args_mir = node.args.map { |a| hoist_alloc(lower(a), a) }
    format_lit = MIR::Lit.new("\"#{formats}\\n\"")
    tuple = MIR::TupleLiteral.new(args_mir)
    MIR::Call.new("std.debug.print", [format_lit, tuple], false, false, MIR::CallableContract.no_ownership(2))
  end

  sig { params(flux_type: Type).returns(String) }
  def zig_format_for_type(flux_type)
    return "{s}" if flux_type.string? ||
      (flux_type.array? && flux_type.element_type&.byte?)
    return "{d}" if flux_type.resolved == :Number || flux_type.resolved == :Int64 || flux_type.byte?
    return "{}" if flux_type.resolved == :Bool || flux_type.resolved == :Boolean || flux_type.void?

    "{any}"
  end

  sig { params(name: String).returns(T::Boolean) }
  def callee_can_fail?(name)
    return true if name.to_s.empty?
    sig = fn_sig_for(name)
    sig ? sig.can_fail != false : true
  end

  sig { params(nodes: AST::RawBody).returns(T::Set[String]) }
  def collect_identifier_names(nodes)
    names = Set.new
    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array then n.each { |item| traverse.call(item) }
      when Hash then n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef then nil # Don't descend into nested defs
      when AST::Identifier then names.add(n.name)
      else n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(nodes)
    names
  end

  # Emit a builtin operation from BUILTIN_OPS registry with structured MIR
  # children and stdlib_def attached so the MIR checker can verify ownership.
  sig { params(name: Symbol, args: T::Array[MIR::Emittable]).returns(T.any(MIR::InlineBc, MIR::RegistryCall)) }
  def emit_builtin(name, args)
    entry = FunctionSignature.unwrap(IntrinsicRegistry.lookup(BUILTIN_OPS, name))
    raise "emit_builtin: unknown builtin :#{name}" unless entry
    if bc_target? && entry.intrinsic_bc?
      return MIR::InlineBc.new(entry.intrinsic_bc_op_or(name), args, entry)
    end
    MIR::RegistryCall.new(
      entry: entry,
      args: args.map { |arg| MIR::RegistryCallArg.new(expr: arg) },
      reason: "builtin_#{name}",
    )
  end

  sig { params(ast_node: AST::Node, type_info: Type).returns(T::Boolean) }
  def direct_slice_backed_expr?(ast_node, type_info)
    return true if type_info.fixed?
    return true if ast_node.is_a?(AST::GetField)
    ast_node.is_a?(AST::Identifier) ? current_function_param_name?(ast_node.name) : false
  end

  sig { params(target: MIR::Node, index: MIR::Node, ast_node: AST::Node, type_info: Type).returns(T.nilable(MIR::IndexGet)) }
  def direct_index_get(target, index, ast_node, type_info)
    ti = Type.new(type_info)
    # @list types defer to their registry accessor (bounds-safe getAtOpt for
    # reads). The runtime helper dispatches ArrayList vs slice via comptime
    # @hasField, so we don't
    # re-derive container shape from "is this a param?" here. Keep direct
    # IndexGet only for true slice-backed exprs (string@raw, fixed slices).
    return nil if ti.list_collection?
    return nil unless direct_slice_backed_expr?(ast_node, ti)
    cast_idx = MIR::Cast.new(index, "usize", :intCast)
    MIR::IndexGet.new(target, cast_idx)
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).returns(T.nilable(MIR::Cast)) }
  def lower_direct_length(node)
    recv_ast = node.is_a?(AST::MethodCall) ? node.object : node.args.first
    return nil unless recv_ast

    recv_ti = Type.from_node!(recv_ast, context: "direct length")

    ti = Type.new(recv_ti)
    # Containers (list/array/slice) all defer to CheatLib.len, which dispatches
    # ArrayList vs slice via comptime @hasField. Returning nil here falls back
    # to the regular stdlib-registry path that emits CheatLib.len({0}). The
    # runtime is the single source of truth for container shape — the lowering
    # MUST NOT re-derive shape from "is this a param?" or similar shortcuts
    # (TAKES @list params receive ArrayList; borrow @list params receive a
    # slice via .items; the runtime helper handles both).
    return nil if ti.direct_indexable_collection?

    recv = lower(recv_ast)
    recv = hoist_alloc(recv, recv_ast) if mir_allocates?(recv)
    return nil unless ti.string?

    MIR::Cast.new(MIR::ListLength.new(recv), "i64", :intCast)
  end

  sig { params(node: MIR::Node).returns(T.nilable(String)) }
  def emit_expr(node)
    emitter = runtime_state.emitter!
    emitter.rt_name = runtime_binding_name
    emitter.emit(node)
  end

  # Strip try-wrapping from a MIR node so it can be used inside catch/orelse.
  # Returns a new node without try, or the original node if not try-wrapped.
  sig { params(left: MIR::Node, catch_body: MIR::Node, capture: T.nilable(String), fallback: T.nilable(T.any(AST::Node, MIR::Node))).returns(MIR::TryCatch) }
  def try_catch_with_provenance(left, catch_body, capture, fallback: nil)
    stripped = strip_try(left)
    out = MIR::TryCatch.new(stripped, catch_body, capture)
    if stripped.respond_to?(:result_type) && T.unsafe(stripped).result_type
      out.result_type = Type.new(T.unsafe(stripped).result_type)
    elsif fallback && fallback.respond_to?(:full_type!)
      out.result_type = Type.new(T.unsafe(fallback).full_type!(context: "try-catch fallback result"))
    end
    out
  end

  sig { params(mir_node: MIR::Node).returns(MIR::Node) }
  def strip_try(mir_node)
    mir_node.respond_to?(:without_try) ? mir_node.without_try : mir_node
  end

  # Emit a list of MIR statements as Zig body text, adding semicolons
  # to expression nodes used as statements. Mirrors MIREmitter#emit_body.
  sig { params(mir_nodes: T::Array[MIR::Node], indent: String).returns(String) }
  def emit_stmts_zig(mir_nodes, indent: "")
    mir_nodes.filter_map { |s|
      code = emit_expr(s)
      next nil unless code
      stripped = code.strip
      if zig_statement_semicolon_required?(s, stripped)
        "#{indent}#{code};"
      else
        "#{indent}#{code}"
      end
    }.join("\n")
  end

  sig { params(stmt: MIR::Node, stripped: String).returns(T::Boolean) }
  def zig_statement_semicolon_required?(stmt, stripped)
    stmt.expr? && !stripped.end_with?(";") &&
      !stripped.end_with?("}") && !stripped.end_with?("{")
  end

  public

  public :task_config_variant, :emit_expr, :emit_builtin,
    :lower_head, :append_ownership_transfers_for_mir_body

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
    ).returns(T.nilable(PipelineAllocMarkFact))
  end
  def pipeline_alloc_mark_fact(value, name, fallback_alloc:, type_info: nil, ast_node: nil,
                               context: "pipeline allocation", known_allocating: false,
                               accept_owned_call: false, include_cleanup: false)
    owns_call_result = accept_owned_call && value.is_a?(MIR::Call) && value.owned_return?
    effect = MIR::OwnershipEffect.of(value)
    return nil unless known_allocating || mir_allocates?(value) || owns_call_result || effect.produces_owned

    alloc = effect.alloc || mir_owned_alloc(value) || fallback_alloc
    stamp_allocating_result_target!(value, name, alloc: alloc)
    mark_type = type_info || mir_alloc_mark_type_info(value, ast_node, context: context)
    mark = MIR::AllocMark.new(name, alloc, mark_type, MIR::Placement.alloc_scope(alloc))
    PipelineAllocMarkFact.new(
      alloc: alloc,
      mark: mark,
      cleanup_entry: include_cleanup ? hoist_cleanup_entry(value, ast_node) : nil,
    )
  end

  sig { params(value: MIR::Node, ast_node: T.nilable(AST::Node)).returns(T.nilable(CleanupEntry)) }
  def pipeline_owned_cleanup_entry(value, ast_node)
    return nil unless mir_owned_alloc(value)

    hoist_cleanup_entry(value, ast_node)
  end

  sig do
    params(
      insert: MIR::IndexInsert,
      value: MIR::Node,
      value_owns: T::Boolean,
      target_alloc: Symbol,
    ).returns(MIR::IndexInsert)
  end
  def pipeline_index_insert_with_ownership(insert, value, value_owns, target_alloc:)
    return insert unless value_owns || mir_allocates?(value)

    T.cast(with_ownership_consumption(
      insert,
      mir_ident_names(value),
      "MIR::IndexInsert",
      target_alloc: target_alloc,
      require_visible: false,
    ), MIR::IndexInsert)
  end

  # Temporarily installs a fiber capture map and rt alias, runs the block, then restores.
  # Used by DoBlock, BgBlock, and PipelineHost (for concurrent pipeline operators).
  #
  # `capture_symbols` carries the LIVE
  # SymbolEntry for each captured name so body-lowering passes that need
  # current sync/storage (especially WITH EXCLUSIVE's Arc-vs-bare dispatch)
  # read post-`propagate_caller_sync!` state, not the AST-snapshot state
  # that var_node.symbol may carry. Without this,
  # a `WITH EXCLUSIVE c` inside a CONCURRENT/BG/DO callback that captures
  # c (received via REQUIRES LOCKED) emits the polymorphic `c.*` deref
  # path instead of the direct `c.ctrl.data.*` Arc-unwrap, and the Zig
  # compile fails with "cannot dereference non-pointer type Arc(...)".
  # See transpile-tests/257_concurrent_capture_locked_param.clear.
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
  def with_fiber_capture_map(new_entries, capture_symbols: {}, rt_override: "__rt", &blk)
    prev_map = capture_state.do_capture_map || {}
    prev_syms = capture_state.current_fiber_capture_symbols
    prev_rt = runtime_binding_name
    capture_state.do_capture_map = prev_map.merge(new_entries)
    capture_state.current_fiber_capture_symbols = prev_syms.merge(capture_symbols)
    runtime_state.rt_name = rt_override
    result = blk.call
    capture_state.do_capture_map = prev_map
    capture_state.current_fiber_capture_symbols = prev_syms
    runtime_state.rt_name = prev_rt
    result
  end

  private

  # Should we inject `rt.checkYield()` at the entry of this fn?
  # Returns true for non-TIGHT recursive fns (plain :reentrant,
  # :TAIL_CALL, :MAX_DEPTH(N) when N > BUDGET). Skipped for :THUNK
  # (the trampoline body emits its own yield) and :NOT_LOGICAL
  # (depth=1 by assertion -- yield is meaningless).
  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def needs_recursion_yield?(node)
    AST.recursion_yield_needed?(node)
  end

  # Strip pointer prefix from zig type - dupeUnionValue needs bare type (Value not *Value).
  sig { params(ti: Type).returns(String) }
  def bare_zig_type(ti)
    t = transpile_type(ti)
    t.start_with?("*") ? T.must(t[1..]) : t
  end

  sig { params(value: MIR::Node, ast_node: T.nilable(AST::Node), sink_alloc: Symbol, sink_type: T.nilable(Type::TypeInput)).returns(MIR::Node) }
  def materialize_owned_sink_value(value, ast_node, sink_alloc, sink_type = nil)
    return value unless ast_node
    source_type = ast_node.is_a?(AST::CopyNode) ? copy_source_type_info(ast_node.value) : Type.from_node!(ast_node, context: "owned sink layout transport")
    destination_type = sink_type ? (sink_type.is_a?(Type) ? sink_type : Type.new(sink_type)) : source_type

    # Layout transport is destination-driven and remains structural in MIR.
    # A consumed direct value can be moved into a unique box without copying
    # its payload. Conversely, consuming a unique box into a direct sink moves
    # the payload out and destroys only the now-empty allocation shell.
    layout_transport = ast_node.respond_to?(:layout_transport) ? T.unsafe(ast_node).layout_transport : nil
    if layout_transport == :box && destination_type.indirect? && !source_type.indirect? &&
        destination_type.resolved == source_type.resolved && !value.is_a?(MIR::HeapCreate)
      return T.unsafe(with_ownership_consumption(
        MIR::HeapCreate.new(transpile_type(source_type.resolved.to_s), value, sink_alloc, "box_move"),
        mir_ident_names(value),
        "MIR::HeapCreate(layout move)",
        target_alloc: sink_alloc,
      ))
    end
    if layout_transport == :unbox && source_type.indirect? && !destination_type.indirect? &&
        destination_type.resolved == source_type.resolved
      unboxed = MIR::Call.new(
        "CheatLib.unboxMove",
        [MIR::Ident.new(transpile_type(destination_type.resolved.to_s)), MIR::AllocatorRef.new(sink_alloc), value],
        false,
        false,
        MIR::CallableContract.no_ownership(3),
      )
      return T.unsafe(with_ownership_consumption_for_value(
        unboxed,
        value,
        ast_node,
        "CheatLib.unboxMove",
        target_alloc: sink_alloc,
      ))
    end
    plan = owned_sink_plan(value, ast_node, sink_alloc, sink_type)
    return value if plan.keep?

    case plan.action
    when :dupe_slice
      MIR::DupeSlice.new(value, plan.target_alloc)
    when :deep_copy
      value = MIR::ItemsAccess.new(value, true) if plan.source_slice_view
      MIR::DeepCopy.new(value, T.must(plan.zig_type), nil, T.must(plan.copy_mode), plan.target_alloc)
    when :rc_retain
      MIR::RcRetain.new(value, T.must(plan.zig_type), T.must(plan.rc_func))
    when :dupe_union
      emit_builtin(:dupeUnionValue, [MIR::Ident.new(T.must(plan.zig_type)), value, MIR::AllocatorRef.new(plan.target_alloc)])
    else
      value
    end
  end

  sig { params(value: MIR::Node, ast_node: AST::Node, sink_alloc: Symbol, sink_type: T.nilable(Type::TypeInput)).returns(OwnedSinkPlan) }
  def owned_sink_plan(value, ast_node, sink_alloc, sink_type = nil)
    ti = ast_node.is_a?(AST::CopyNode) ? copy_source_type_info(ast_node.value) : Type.from_node!(ast_node, context: "owned sink materialization")
    dst_ti = sink_type ? (sink_type.is_a?(Type) ? sink_type : Type.new(sink_type)) : ti
    keep = OwnedSinkPlan.new(action: :keep, target_alloc: sink_alloc, zig_type: nil, copy_mode: nil)
    source = owned_sink_source_fact(value, ast_node, sink_alloc, ti)

    if ti.string?
      return keep if ti.symbol?
      return keep if source.satisfies_sink?(sink_alloc, ti)
      return OwnedSinkPlan.new(action: :dupe_slice, target_alloc: sink_alloc, zig_type: nil, copy_mode: nil)
    end

    if ti.any_rc?
      return keep if source.satisfies_rc_sink?

      return OwnedSinkPlan.new(
        action: :rc_retain,
        target_alloc: sink_alloc,
        zig_type: rc_payload_zig_type(ti),
        copy_mode: nil,
        rc_func: ti.shared? ? "arcRetain" : "rcRetain",
      )
    end

    if ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(T.unsafe(mir_schema_lookup))
      return keep if source.satisfies_sink?(sink_alloc, ti)
      return keep unless source.existing_owned_source
      source_slice_view = T.let(!sink_type.nil? && ti.direct_indexable_collection? && !dst_ti.collection?, T::Boolean)
      return OwnedSinkPlan.new(
        action: :deep_copy,
        target_alloc: sink_alloc,
        zig_type: dst_ti.zig_type(is_field: true),
        copy_mode: :full_value,
        source_slice_view: source_slice_view,
      )
    end

    return keep unless source.borrowed_union_sink

    OwnedSinkPlan.new(action: :dupe_union, target_alloc: sink_alloc, zig_type: bare_zig_type(ti), copy_mode: nil)
  end

  sig { params(value: MIR::Node, ast_node: AST::Node, _sink_alloc: Symbol, ti: Type).returns(OwnedSinkSourceFact) }
  def owned_sink_source_fact(value, ast_node, _sink_alloc, ti)
    source_node = owned_sink_source_node(ast_node)
    entry = owned_sink_source_entry(source_node)
    value_alloc = mir_owned_alloc(value) || placement_for_node(ast_node)

    OwnedSinkSourceFact.new(
      source_alloc: value_alloc,
      moved_without_copy: explicit_owned_sink_transfer?(ast_node, source_node),
      owned_parameter: owned_parameter_source_node?(source_node),
      needs_heap_create: !!(ast_node.respond_to?(:needs_heap_create) && ast_node.needs_heap_create),
      same_alloc_verifiable: entry.needs_cleanup?,
      same_alloc_transfer_source: entry.present?,
      transfer_without_local_cleanup: entry.present? && !entry.needs_cleanup?,
      already_owned_value: owned_sink_value?(value, ast_node),
      existing_owned_source: existing_owned_source_node?(source_node),
      borrowed_union_sink: borrowed_union_sink_source?(ast_node, source_node, ti),
    )
  end

  sig { params(ast_node: AST::Node).returns(AST::Node) }
  def owned_sink_source_node(ast_node)
    node = ast_node
    node = node.value if node.is_a?(AST::MoveNode)
    node
  end

  sig { params(ast_node: AST::Node, source_node: AST::Node).returns(T::Boolean) }
  def explicit_owned_sink_transfer?(ast_node, source_node)
    return false if ast_node.is_a?(AST::CopyNode) || ast_node.is_a?(AST::CloneNode)
    return true if ast_node.is_a?(AST::MoveNode)
    return false if borrowed_destination_node?(source_node)

    owner_transfer_node?(source_node)
  end

  sig { params(source_node: AST::Node).returns(CleanupEntry) }
  def owned_sink_source_entry(source_node)
    return CleanupEntry::NONE unless source_node.is_a?(AST::Identifier)

    function_state.bindings[source_node.name.to_s] || CleanupEntry::NONE
  end

  sig { params(source_node: AST::Node).returns(T::Boolean) }
  def owned_parameter_source_node?(source_node)
    return false unless source_node.is_a?(AST::Identifier)
    symbol = source_node.symbol
    !!(symbol&.is_param && symbol.takes)
  end

  sig { params(value: MIR::Node, ast_node: AST::Node).returns(T::Boolean) }
  def owned_sink_value?(value, ast_node)
    return owned_sink_value?(value.expr, ast_node) if value.is_a?(MIR::Cast)
    return owned_sink_value?(value.expr, ast_node) if value.is_a?(MIR::TryExpr)
    return true if ast_node.is_a?(AST::MoveNode) || ast_node.is_a?(AST::CopyNode) || ast_node.is_a?(AST::CloneNode)
    return true if mir_allocates?(value)
    return true if value.is_a?(MIR::Call) && value.owned_return?
    false
  end

  sig { params(source_node: AST::Node).returns(T::Boolean) }
  def existing_owned_source_node?(source_node)
    source_node.is_a?(AST::Identifier) || source_node.is_a?(AST::GetField) ||
      source_node.is_a?(AST::GetIndex) || source_node.is_a?(AST::OptionalUnwrap)
  end

  sig { params(ast_node: AST::Node, source_node: AST::Node, ti: Type).returns(T::Boolean) }
  def borrowed_union_sink_source?(ast_node, source_node, ti)
    return false if ast_node.is_a?(AST::MoveNode) || ast_node.is_a?(AST::CopyNode) || ast_node.is_a?(AST::CloneNode)
    return false unless source_node.is_a?(AST::Identifier) || source_node.is_a?(AST::GetIndex)
    root = AST.root_identifier(ast_node) rescue nil
    borrowed = (root&.symbol&.borrow_provenance?) || AST.container_borrow?(ast_node)
    return false unless borrowed
    return false unless union_schemas.key?(ti.resolved)
    return false if ti.respond_to?(:implicitly_copyable?) && ti.implicitly_copyable?(T.unsafe(mir_schema_lookup))
    true
  end

  # Check if a value node is an Rc/Arc identifier that needs retain (not moved, not unwrapped)
  sig { params(value_node: AST::Node).returns(T::Boolean) }
  def rc_retain_needed?(value_node)
    return false unless value_node.is_a?(AST::Identifier)
    ti = Type.from_node!(value_node, context: "rc retain")
    return false unless ti.any_rc?
    return false if ti.atomic_ptr?
    rc_map = capability_state.rc_unwrap_map || {}
    return false if rc_map.key?(value_node.name)
    true
  end

  sig { params(value_node: AST::Identifier).returns(MIR::RcRetain) }
  def make_rc_retain(value_node)
    ti = Type.from_node!(value_node, context: "rc retain emit")
    func = ti.shared? ? "arcRetain" : "rcRetain"
    zig_base = rc_payload_zig_type(ti)
    MIR::RcRetain.new(lower(value_node), zig_base, func)
  end

  # Lazy-create PipelineHost for complex pipeline operator dispatch.
  sig { returns(PipelineHost) }
  def pipeline_host
    cached = program_state.pipeline_host
    return cached if cached

    program_state.pipeline_host = PipelineHost.new(
      lowering: self,
      emitter: runtime_state.emitter!
    )
    T.must(program_state.pipeline_host)
  end

  private :append_implicit_alloc_fact!,
    :append_block_result_transfer!,
    :append_lowered_statement_packet!,
    :append_move_guard_for_transfer_mark!,
    :append_ownership_facts_for_owned_result!,
    :append_ownership_transfer_facts_for_contract!,
    :append_transfer_marks!,
    :apply_lowered_coercion,
    :finalize_lowered_body_construction!,
    :mark_ownership_finalized_node!,
    :merge_body_mark_names!,
    :owned_or_destination?,
    :ownership_finalized_body?,
    :record_ownership_finalization_node!
  private :append_already_finalized_node!
  private :append_lowered_items!
  private :append_nested_ownership_transfers_for_mir_body
  private :append_ownership_facts_for_mir_node!
  private :append_ownership_facts_for_structural_node!
  private :append_ownership_finalized_node!
  private :append_ownership_store_facts_for_consumption!
  private :append_ownership_transfer_facts_for_consumption!
  private :append_ownership_transfer_targets_for_surface_node!
  private :append_pending_packet_nodes!
  private :append_transfer_marks_to_body!
  private :borrowed_destination_node?
  private :borrowed_string_destination?
  private :borrowed_ownership_ast?
  private :cast_wrapped_or?
  private :cleanup_entry_moved_guard?
  private :construct_lowered_body
  private :current_function_collection_param?
  private :current_function_heap_carry_return?
  private :current_function_param_name?
  private :destination_keep_plan
  private :destination_placement_plan
  private :destination_source_fact
  private :destination_source_node
  private :destination_type
  private :discard_expr_stmt?
  private :discard_owned_zig_type
  private :emit_expr
  private :ensure_lowered_node_id
  private :escaping_value_alloc
  private :finalize_nested_mir_bodies!
  private :finalize_nested_mir_expr_bodies!
  private :finalize_ownership_for_mir_node!
  private :fn_sig_for
  private :heap_indirect_destination?
  private :heap_owned_result?
  private :if_bind_ownership_fact_targets
  private :implicit_alloc_mark_for_mir_node
  private :implicit_allocating_result_fact
  private :initial_ownership_finalization_context
  private :lowered_stmt_packet
  private :lowering_schemas
  private :lowering_state
  private :mark_ownership_finalized_body!
  private :mark_ownership_finalized_nodes!
  private :materialize_statement_discard
  private :non_consuming_owned_value_expr?
  private :or_binary?
  private :owned_branch_result_value
  private :owner_cleanup_for_transfer
  private :owner_transfer_node?
  private :ownership_consumed_name_operands
  private :ownership_consumer_requires_fact?
  private :ownership_consumption_for_node
  private :ownership_contract_consumes
  private :ownership_contract_consumes_unwrapped
  private :ownership_contract_source_node
  private :ownership_fact_dedupe_key
  private :ownership_fact_source
  private :ownership_fact_target_for_expr
  private :ownership_fact_targets_for_node
  private :ownership_facts_for_mir_surface
  private :ownership_finalized_node?
  private :ownership_operand_type
  private :ownership_operands_for_sink_value
  private :ownership_operands_for_value
  private :ownership_owned_result_fact_relevant?
  private :ownership_root_name
  private :rodata_ownership_ast?
  private :ownership_scanner
  private :ownership_state
  private :ownership_transfer_contract_relevant?
  private :ownership_transfer_only_target
  private :ownership_transfer_operands_for_node
  private :ownership_transfers_for_stmt
  private :place_discarded_owned_branch_value
  private :place_or_branch_value_for_destination
  private :program_state
  private :record_ownership_finalization_surface_node!
  private :retarget_ownership_operands
  private :scan_ownership_surface!
  private :scoped_owning_branch_value
  private :seed_cleanup_owner_index!
  private :stack_fixed_array_coercion?
  private :stamp_source_line!
  private :stdlib_call_ownership_facts
  private :visible_owned_operand_value?
  private :walk_ast_calls

end
