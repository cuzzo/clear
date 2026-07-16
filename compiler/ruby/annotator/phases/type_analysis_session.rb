# typed: strict
# frozen_string_literal: true
require "sorbet-runtime"

require_relative "../../ast/source_error"
require_relative "../../ast/fixable_error"
require_relative "../../ast/scope"
require_relative "../../ast/parser"
require_relative "../../ast/std_lib"
require_relative "../../ast/async_result_shape"
require_relative "../../semantic/ownership_graph"
require_relative "../../semantic/ownership_transport"
require_relative "body_analysis"
require_relative "builtin_environment"
require_relative "declaration_index"
require_relative "auto_finalization"
require_relative "deferred_validation"
require_relative "expression_domains"
require_relative "import_resolution"
require_relative "program_finalization"
require_relative "signature_registry"
require_relative "signature_registration"
require_relative "type_registration"
require_relative "whole_program_semantics"
require_relative "../function_registry"
require_relative "../domains/control_flow"
require_relative "../domains/variables"
require_relative "../domains/destructuring"
require_relative "../domains/member_access"
require_relative "../domains/execution_boundaries"
require_relative "../domains/errors"
require_relative "../domains/expressions"
require_relative "../domains/lifetimes"
require_relative "../helpers/function_context"
require_relative "../helpers/function_signature"
require_relative "../helpers/function_analysis"
require_relative "../helpers/prefixed_int_range"
require_relative "../helpers/pipe_analysis"
require_relative "../../semantic/escape_analysis"
require_relative "../../semantic/bg_capture_classifier"
require_relative "../../semantic/effect_inference"
require_relative "../../semantic/concurrency_checks"
require_relative "../helpers/generic_analysis"
require_relative "../helpers/capabilities"
require_relative "../helpers/test_annotation"
require_relative "../helpers/with_match_check"
require_relative "../helpers/fixable_helpers"
require_relative "../helpers/effects"
require_relative "../helpers/reentrance"
require_relative "../../mir/thunk_transform"
require_relative "../helpers/lock_helper"
require_relative "../../mir/alloc"
require_relative "../helpers/method_analysis"
require_relative "../helpers/union"
require_relative "../helpers/auto_inference"
require_relative "capability_evidence"
require_relative "phase_handoffs"
require_relative "../../compiler/module_importer"

# Phase-owned executor for body typing and fact collection.  The public
# SemanticAnnotator below is only a construction boundary; mutable traversal
# state belongs to this session and is discarded after one annotation run.
class Annotator::Phases::TypeAnalysisSession
    extend T::Sig

  include ErrorHelper
  include FixableHelper
  include FunctionAnalysis
  include PipeAnalysis
  include ScopeHelper
  include TypeHelper
  include PrefixedIntRange
  include GenericAnalysis
  include EffectTracker
  include EffectQueries
  include ReentranceBridge
  include ReentranceQueries
  include CapabilityHelper
  include CapabilityAudit
  include AllocHelper
  include MethodAnalysis
  include UnionAnalysis
  include LockHelper
  include TestAnnotation
  include Annotator::Phases::AutoFinalization
  include Annotator::Phases::BodyAnalysis
  include Annotator::Phases::DeferredValidation
  include Annotator::Phases::ExpressionDomains
  include Annotator::Phases::ProgramFinalization
  include Annotator::Domains::ControlFlow
  include Annotator::Domains::Variables
  include Annotator::Domains::Destructuring
  include Annotator::Domains::MemberAccess
  include Annotator::Domains::ExecutionBoundaries
  include Annotator::Domains::Errors
  include Annotator::Domains::Expressions
  include Annotator::Domains::Lifetimes

  SnapshotTxnViolation = Annotator::Phases::SnapshotTxnViolation
  HeldLockEntry = Annotator::Phases::HeldLockEntry
  HeldLockMap = T.type_alias { Annotator::Phases::HeldLockMap }
  HeldLockTypeEntry = Annotator::Phases::HeldLockTypeEntry

  class StreamYieldFrame < T::Struct
    const :node, AST::BgStreamBlock
    const :expected_type, T.nilable(Type), default: nil
    const :yield_types, T::Array[Type], factory: -> { [] }
    prop :closed, T::Boolean, default: false
  end

  SnapshotTxnFrame = Annotator::Phases::SnapshotTxnFrame

  DeadlockEscape = T.type_alias { T::Hash[Symbol, T.any(Symbol, Lexer::Token)] }

  class TraversalState < T::Struct
    prop :scopes, T::Array[Scope], factory: -> { [Scope.new] }
    prop :function_contexts, T::Array[FunctionContext], factory: -> { [] }
    prop :loop_depth, Integer, default: 0
    prop :conditional_depth, Integer, default: 0
    prop :smooth_depth, Integer, default: 0
    prop :body_fact_frames, T::Array[Annotator::Phases::BodyFactFrame], factory: -> { [] }
    prop :stream_yield_frames, T::Array[StreamYieldFrame], factory: -> { [] }
    prop :with_block_depth, Integer, default: 0
    prop :match_pattern_depth, Integer, default: 0
    prop :current_bg_pinned, T::Boolean, default: false
    prop :pipeline_accessed_fields, T.nilable(T::Set[String]), default: nil
    prop :auto_locked_assign_name, T.nilable(String), default: nil
    prop :struct_literal_call_argument_depth, Integer, default: 0
    prop :annotation_ancestors, T::Array[AST::Node], factory: -> { [] }
  end

  class Config < T::Struct
    const :importer, T.nilable(ModuleImporter)
    const :source_dir, String
    const :strict_test, T::Boolean
    const :source_code, T.nilable(String)
  end

  CapabilityAuditInputs = Annotator::Phases::CapabilityAuditInputs

  sig { returns(T::Hash[String, AST::FunctionDef]) }
  def semantic_function_nodes
    function_node_map
  end

  sig { returns(Annotator::FunctionRegistry) }
  def semantic_function_registry
    @function_registry
  end

  sig { returns(T::Hash[String, AST::FunctionDef]) }
  def function_node_map
    semantic_function_registry.nodes
  end

  sig { returns(TraversalState) }
  def phase_traversal_state
    @traversal_state
  end

  sig { returns(CapabilityAuditInputs) }
  def phase_audit_inputs
    @audit_inputs
  end

  private :phase_traversal_state, :phase_audit_inputs

  sig { returns(OwnershipGraph) }
  def ownership_graph
    @audit_inputs.ownership_graph
  end
  private :ownership_graph

  sig { params(name: T.nilable(String)).returns(T.nilable(AST::FunctionDef)) }
  def function_node_for(name)
    semantic_function_registry.fetch(name)
  end

  sig { params(node: AST::FunctionDef).returns(AST::FunctionDef) }
  def register_function_node!(node)
    semantic_function_registry.register!(node)
  end

  sig { override.returns(T::Array[Scope]) }
  def scope_stack
    @traversal_state.scopes
  end

  sig { returns(Scope) }
  def semantic_root_scope
    T.must(@traversal_state.scopes.first)
  end

  sig { returns(T.nilable(AST::Program)) }
  def semantic_program
    @program
  end

  sig { returns(T::Hash[Symbol, Integer]) }
  def semantic_lock_type_ranks
    @audit_inputs.lock_analysis.type_ranks
  end

  sig { returns(T::Array[HeldLockTypeEntry]) }
  def semantic_held_lock_types
    current_held_lock_types
  end

  sig { returns(Integer) }
  def pending_deferred_validation_count
    @audit_inputs.deferred_with_validations.length
  end

  sig { returns(T::Array[Annotator::Phases::DeferredWithValidation]) }
  def deferred_with_validations
    @audit_inputs.deferred_with_validations
  end

  sig { returns(T.nilable(FunctionContext)) }
  def current_fn_ctx
    @traversal_state.function_contexts.last
  end

  sig { returns(FunctionContext) }
  def current_fn_ctx!
    T.must(current_fn_ctx)
  end

  sig { returns(T::Array[Symbol]) }
  def current_function_type_params
    ctx = current_fn_ctx
    ctx ? ctx.type_params : []
  end
  private :current_function_type_params

  sig { params(type_name: T.nilable(Symbol)).returns(T::Boolean) }
  def current_function_type_param?(type_name)
    return false unless type_name

    current_function_type_params.include?(type_name)
  end
  private :current_function_type_param?

  sig { params(type: Type).returns(Type) }
  def refined_comptime_type_param_type(type)
    type_name = type.resolved
    return type unless current_function_type_param?(type_name)

    @comptime_type_param_refinements[type_name] || type
  end
  private :refined_comptime_type_param_type

  sig do
    type_parameters(:Result)
      .params(
        type_param: Symbol,
        narrowed_type: Type,
        blk: T.proc.returns(T.type_parameter(:Result)),
      )
      .returns(T.type_parameter(:Result))
  end
  def with_comptime_type_param_refinement(type_param, narrowed_type, &blk)
    previous = @comptime_type_param_refinements
    @comptime_type_param_refinements = previous.merge(type_param => Type.new(narrowed_type))
    blk.call
  ensure
    @comptime_type_param_refinements = T.unsafe(previous)
  end
  private :with_comptime_type_param_refinement

  sig { params(ctx: FunctionContext).returns(FunctionContext) }
  def push_function_context!(ctx)
    @traversal_state.function_contexts << ctx
    ctx
  end
  private :push_function_context!

  sig { returns(T.nilable(FunctionContext)) }
  def pop_function_context!
    @traversal_state.function_contexts.pop
  end
  private :pop_function_context!

  sig do
    type_parameters(:Stamp)
      .params(node: AST::Locatable, value: T.type_parameter(:Stamp))
      .returns(T.type_parameter(:Stamp))
  end
  def stamp_type!(node, value)
    case value
    when nil
      raise "annotation stamp missing type for #{node.class}"
    end
    node.full_type = T.cast(value, AST::SyntheticTypeInput)
    stamped = node.full_type!(context: "annotation stamp")
    raise "annotation stamp produced :Untyped for #{node.class}" if stamped.untyped?
    value
  end

  sig { params(effect: Symbol, fn_name: String).void }
  def record_snapshot_txn_violation!(effect, fn_name)
    frame = @audit_inputs.snapshot_txn_frames.last
    return unless frame

    frame.violations << SnapshotTxnViolation.new(effect: effect, fn: fn_name)
  end

  sig { returns(T::Boolean) }
  def inside_snapshot_transaction_body?
    !@audit_inputs.snapshot_txn_frames.empty?
  end
  private :inside_snapshot_transaction_body?

  # Run the given block with conditional_depth incremented on the current
  # function context (or the global fallback when outside a function).
  # Used to tag SUSPENDS effects recorded inside IF branches / MATCH arms
  # as SUSPENDS:CONDITIONAL.
  sig do
    type_parameters(:Result)
      .params(blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_conditional_context(&blk)
    fn_ctx = current_fn_ctx
    if fn_ctx
      fn_ctx.enter_conditional!
    else
      @traversal_state.conditional_depth += 1
    end
    blk.call
  ensure
    if fn_ctx
      fn_ctx.exit_conditional!
    else
      @traversal_state.conditional_depth -= 1
    end
  end

  sig do
    type_parameters(:Result)
      .params(blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_loop_context(&blk)
    fn_ctx = current_fn_ctx
    if fn_ctx
      fn_ctx.enter_loop!
    else
      @traversal_state.loop_depth += 1
    end
    blk.call
  ensure
    if fn_ctx
      fn_ctx.exit_loop!
    else
      @traversal_state.loop_depth -= 1
    end
  end
  private :with_loop_context

  sig do
    params(branches: T::Array[T.proc.returns(BasicObject)], merge_to_parent: T::Boolean)
      .returns(T::Array[BasicObject])
  end
  def analyze_loop_control_flow_branches(branches, merge_to_parent:)
    with_loop_context do
      analyze_control_flow_branches(branches, merge_to_parent: merge_to_parent)
    end
  end
  private :analyze_loop_control_flow_branches

  sig do
    type_parameters(:Result)
      .params(blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_smooth_context(&blk)
    @traversal_state.smooth_depth += 1
    blk.call
  ensure
    @traversal_state.smooth_depth -= 1
  end

  sig { returns(Integer) }
  def smooth_depth
    @traversal_state.smooth_depth
  end

  sig { returns(Integer) }
  def current_loop_depth
    current_fn_ctx&.loop_depth || @traversal_state.loop_depth
  end

  sig { returns(Integer) }
  def current_conditional_depth
    current_fn_ctx&.conditional_depth || @traversal_state.conditional_depth
  end

  sig { returns(T::Boolean) }
  def inside_with_block?
    @traversal_state.with_block_depth.positive?
  end

  sig { returns(T::Boolean) }
  def inside_match_pattern_context?
    @traversal_state.match_pattern_depth.positive?
  end

  sig { returns(HeldLockMap) }
  def current_held_locks
    @audit_inputs.held_locks
  end

  sig { returns(T::Array[HeldLockTypeEntry]) }
  def current_held_lock_types
    @audit_inputs.held_lock_types
  end

  sig { returns(T.nilable(CapabilityHelper::PredicateContext)) }
  def current_predicate_context
    @audit_inputs.current_predicate_context
  end

  sig do
    type_parameters(:Result)
      .params(
        ctx: CapabilityHelper::PredicateContext,
        blk: T.proc.returns(T.type_parameter(:Result)),
      )
      .returns(T.type_parameter(:Result))
  end
  def with_predicate_context(ctx, &blk)
    previous = @audit_inputs.current_predicate_context
    @audit_inputs.current_predicate_context = ctx
    blk.call
  ensure
    @audit_inputs.current_predicate_context = previous
  end

  sig { returns(T::Array[CapabilityHelper::PredicateCallSite]) }
  def predicate_call_sites
    @audit_inputs.predicate_call_sites
  end

  sig { returns(CapabilityAudit::BindingAuditStore) }
  def capability_audit
    @audit_inputs.capability_audit
  end

  sig { returns(T.nilable(StreamYieldFrame)) }
  def current_stream_yield_frame
    @traversal_state.stream_yield_frames.last
  end

  sig do
    type_parameters(:Result)
      .params(
        node: AST::BgStreamBlock,
        blk: T.proc.returns(T.type_parameter(:Result))
      )
      .returns(T::Array[Type])
  end
  def with_stream_yield_frame(node, &blk)
    frame = StreamYieldFrame.new(node: node, expected_type: node.declared_yield_type)
    @traversal_state.stream_yield_frames << frame
    begin
      blk.call
      frame.yield_types
    ensure
      popped = @traversal_state.stream_yield_frames.pop
      raise "BUG: stream yield frame mismatch" unless popped.equal?(frame)
    end
  end

  sig do
    type_parameters(:Result)
      .params(blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_match_pattern_context(&blk)
    @traversal_state.match_pattern_depth += 1
    blk.call
  ensure
    @traversal_state.match_pattern_depth -= 1
  end

  sig { params(family: Symbol).returns(T::Array[Symbol]) }
  def with_match_family_effects(family)
    case family
    when :LOCKED
      [EffectTracker::BLOCKING, EffectTracker::CONTENTION, EffectTracker::SUSPENDS]
    when :VERSIONED, :ATOMIC
      [EffectTracker::CONTENTION]
    else
      []
    end
  end

  sig do
    type_parameters(:Result)
      .params(
        node: AST::WithBlock,
        lock_capabilities: CapabilityHelper::WithCapabilityFacts,
        blk: T.proc.returns(T.type_parameter(:Result)),
      )
      .returns(T.type_parameter(:Result))
  end
  def with_held_locks(node, lock_capabilities, &blk)
    previous_locks = @audit_inputs.held_locks
    previous_types = @audit_inputs.held_lock_types
    @audit_inputs.held_locks = previous_locks.dup
    @audit_inputs.held_lock_types = previous_types.dup
    opted_out = !node.deadlock_escape.nil?

    lock_capabilities.each do |capability|
      variable_name = capability.var_name
      token = capability.var_node.token
      @audit_inputs.held_locks[variable_name] ||= HeldLockEntry.new(token: token)
      lock_type = capability.lock_identity
      @audit_inputs.held_lock_types << HeldLockTypeEntry.new(type: lock_type, opted_out: opted_out) if lock_type
    end

    blk.call
  ensure
    @audit_inputs.held_locks = T.must(previous_locks)
    @audit_inputs.held_lock_types = T.must(previous_types)
  end

  sig do
    type_parameters(:Result)
      .params(node: AST::WithBlock, blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_snapshot_transaction_body(node, &blk)
    frame = SnapshotTxnFrame.new
    @audit_inputs.snapshot_txn_frames << frame
    result = blk.call
    txn_violations = frame.violations
    unless txn_violations.empty?
      kinds = txn_violations.map { |violation| EffectTracker.display(violation.effect) }.uniq.join(", ")
      error!(node, :WITH_SNAPSHOT_BODY_NOT_PURE, kinds: kinds)
    end
    result
  ensure
    popped = @audit_inputs.snapshot_txn_frames.pop
    Kernel.raise "BUG: snapshot transaction frame mismatch" if popped && !popped.equal?(frame)
  end

  # `source_code` is optional — used ONLY by fixable-error helpers to
  # locate source-level spans (e.g., the `;` at the end of a
  # declaration line so `@multiowned` can be inserted before it).
  # When nil, affected helpers fall back to the plain `error!` path.
  sig { params(node: AST::Literal, val: Integer, target_type: Symbol, min: Integer, max: Integer).returns(NilClass) }
  def handle_prefixed_int_overflow!(node, val, target_type, min, max)
    emit_int_overflow_error!(node, val, target_type, min, max)
  end

  sig { override.returns(T.nilable(String)) }
  def source_code
    @config.source_code
  end

  sig { params(importer: T.nilable(ModuleImporter), compiler: T.nilable(ModuleImporter), source_dir: T.nilable(String), strict_test: T::Boolean, source_code: T.nilable(String)).void }
  def initialize(importer: nil, compiler: nil, source_dir: nil, strict_test: false, source_code: nil)
    @config = T.let(Config.new(
      importer: importer || compiler,
      source_dir: source_dir ? File.expand_path(source_dir) : Dir.pwd,
      strict_test: strict_test,
      source_code: source_code
    ), Config)
    @traversal_state = T.let(TraversalState.new, TraversalState)
    @audit_inputs = T.let(CapabilityAuditInputs.new, CapabilityAuditInputs)
    @function_registry = T.let(Annotator::FunctionRegistry.new, Annotator::FunctionRegistry)
    @program = T.let(nil, T.nilable(AST::Program))
    @language_mode = T.let(:default, Symbol)
    @comptime_type_param_refinements = T.let({}, T::Hash[Symbol, Type])
    # WITH validations on parameter bindings need caller-sync propagation first.
    @branch_terminated = T.let(false, T::Boolean)
    reset_compilation_state!
  end

  sig { returns(T::Boolean) }
  def strict_test?
    @config.strict_test
  end

  sig { returns(T::Boolean) }
  def struct_literal_call_argument_context?
    @traversal_state.struct_literal_call_argument_depth > 0
  end
  private :struct_literal_call_argument_context?

  sig { params(block: T.proc.void).void }
  def with_struct_literal_call_argument(&block)
    @traversal_state.struct_literal_call_argument_depth += 1
    begin
      block.call
    ensure
      @traversal_state.struct_literal_call_argument_depth -= 1
    end
  end
  private :with_struct_literal_call_argument

  sig { params(resolution: Annotator::Phases::ResolutionFacts).returns(Annotator::Phases::TypeAnalysisHandoff) }
  def execute_type_analysis!(resolution)
    reset_compilation_state!
    @program = resolution.program
    @language_mode = resolution.program.language_mode
    ownership = analyze_resolution!(resolution)
    inventory = Annotator::Phases::AnnotationTypeInventory.scan(resolution.program)
    inventory.verify_resolved!
    typed_program = Annotator::Phases::TypedProgramFacts.new(
      resolution: resolution,
      body_summaries: resolution.function_registry.body_summaries,
      typed_node_count: inventory.typed_node_count,
      unresolved_node_count: inventory.unresolved_node_count,
      ownership_graph: ownership
    )
    Annotator::Phases::TypeAnalysisHandoff.new(
      typed_program: typed_program,
      audit_request: release_capability_audit_request!
    )
  end

  sig { returns(Symbol) }
  def language_mode
    @language_mode
  end

  sig { params(resolution: Annotator::Phases::ResolutionFacts).returns(OwnershipGraph) }
  def analyze_resolution!(resolution)
    adopt_resolution_facts!(resolution)
    bridge_reentrance!(resolution.program)
    validate_and_resolve_sync_policy!(resolution.program)
    seed_error_type_registrations!(resolution.declarations)
    analyze_program_bodies!(resolution.declarations, resolution.program)
    resolve_catch_clauses_from_declarations!(resolution.declarations)
    finalize_program_type!(resolution.program)
    finalize_auto_types!(resolution.program)
    ownership_graph
  end

  sig { returns(CapabilityAuditInputs) }
  def release_capability_audit_inputs!
    inputs = @audit_inputs
    @audit_inputs = CapabilityAuditInputs.new
    inputs
  end

  sig { returns(Annotator::Phases::CapabilityAuditRequest) }
  def release_capability_audit_request!
    Annotator::Phases::CapabilityAuditRequest.new(
      inputs: release_capability_audit_inputs!,
      source_code: @config.source_code,
      language_mode: language_mode,
      strict_test: strict_test?
    )
  end

private

  sig { void }
  def reset_compilation_state!
    @traversal_state = TraversalState.new
    @audit_inputs = CapabilityAuditInputs.new
    @function_registry = Annotator::FunctionRegistry.new
    @program = nil
    @branch_terminated = false
    @comptime_type_param_refinements = {}
    effects_init!
    capability_audit_init!
  end

  sig { params(resolution: Annotator::Phases::ResolutionFacts).void }
  def adopt_resolution_facts!(resolution)
    @traversal_state.scopes = [resolution.root_scope]
    @function_registry = resolution.function_registry
  end

  sig { returns(T.nilable(ModuleImporter)) }
  def active_importer
    @config.importer
  end

  sig { returns(String) }
  def import_source_dir
    @config.source_dir
  end

  sig { params(name: String).returns(Semantic::BodyIdentity) }
  def body_identity_for_function(name)
    ordinal = T.must(semantic_function_registry.names.index(name)) + 1
    Semantic::BodyIdentity.for_ordinal(ordinal)
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def function_has_pre_clauses?(node)
    node.pre_clauses.is_a?(Array) && node.pre_clauses.any?
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def function_has_catch_clauses?(node)
    node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def function_has_default_catch?(node)
    node.default_catch.is_a?(Array) && node.default_catch.any?
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def runtime_error_clause?(node)
    function_has_pre_clauses?(node) ||
      function_has_catch_clauses?(node) ||
      function_has_default_catch?(node)
  end

  # Auto inference runs after the body walk has populated type_info on
  # every constraint source. It mutates successful Auto declarations to
  # concrete types and uses operator evidence to rank ambiguous fixes.
  sig { params(program_node: AST::Program).void }
  def run_auto_inference!(program_node)
    fn_nodes = function_node_map
    collector = AutoConstraintCollector.new(fn_nodes)
    slots = collector.collect!(program_node)
    return if slots.empty?

    # Empty `[]` / `{}` initializers need forward-flow evidence from later
    # appends and index writes before unification can pick an element type.
    ShapeEvidenceCollector.new(slots, fn_nodes).collect!

    op_evidence = OperatorEvidenceCollector.new(slots, fn_nodes).collect!

    unifier = AutoUnifier.new(slots)
    result = unifier.resolve!

    unifier.stamp_map_pairs!(result.resolved)
    apply_auto_resolution_stamps!(program_node, result.resolved)

    # Resolved slots: emit :info findings with :auto fix (replace
    # the Auto keyword span with the resolved type's source form).
    # Shape slots emit one binding-level finding; per-sub-slot fixes would
    # write a scalar type where the container type belongs.
    result.resolved.each_value { |resolution| emit_auto_resolved_finding!(resolution) }
    emit_auto_shape_resolved_findings!(result.resolved)

    result.ambiguous.each_value { |ambiguity|
      emit_auto_ambiguity_finding!(ambiguity, op_evidence: op_evidence)
    }

    result.unresolved.each_value { |slot|
      emit_auto_unresolved_finding!(slot, op_evidence: op_evidence)
    }
  end

  # Shape-tracked decls produce one binding-level message so HashMap key/value
  # inference does not surface as two unrelated sub-slot findings.
  sig { params(resolved_slots: AutoUnifier::ResultMap).returns(AutoUnifier::ResultMap) }
  def emit_auto_shape_resolved_findings!(resolved_slots)
    seen = {}
    resolved_slots.each_value do |resolution|
      slot = resolution.slot
      next unless slot.respond_to?(:shape) && slot.shape
      next if seen[slot.decl_node.object_id]
      seen[slot.decl_node.object_id] = true
      emit_auto_shape_resolved_finding!(slot.decl_node, slot)
    end
  end

  sig { params(node: T.nilable(AST::Node)).returns(T.untyped) }
  def visit(node)
    return unless node
    @traversal_state.annotation_ancestors << node
    begin
      result = case node
      when AST::StructDef, AST::ExternStructDecl, AST::EnumDef, AST::UnionDef, AST::ExternFnDecl
        local_resolution_session.register_local_declaration!(node)
        nil
      else
        dispatch_visit(node)
      end
      record_body_fact_node!(node)
      record_ownership_transport_fact!(node)
      result
    ensure
      popped = @traversal_state.annotation_ancestors.pop
      Kernel.raise "BUG: annotation ancestor stack mismatch" unless popped.equal?(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_visit(node)
    case node
    when AST::FunctionDef, AST::LambdaLit then dispatch_function_visit(node)
    when AST::BlockExpr, AST::IfStatement, AST::IsA, AST::IfBind,
         AST::MatchStatement, AST::ForRange, AST::ForEach, AST::WhileLoop,
         AST::WhileBindLoop, AST::BreakNode, AST::ContinueNode, AST::PassStmt
      dispatch_control_flow_visit(node)
    when AST::SyncPolicyDecl, AST::Assert, AST::DieNode, AST::Raise,
         AST::ReturnNode, AST::OrElseRaise, AST::OrElseBreak, AST::OrElsePass,
         AST::OrElsePrune, AST::OrElseExit
      dispatch_error_visit(node)
    when AST::WithBlock, AST::DoBlock, AST::BgStreamBlock, AST::YieldExpr,
         AST::CloseStream, AST::BgBlock, AST::ThenChain, AST::NextExpr
      dispatch_execution_boundary_visit(node)
    when AST::Cast, AST::CallSiteOverride, AST::UnaryOp, AST::Literal,
         AST::DefaultLit, AST::BinaryOp, AST::Placeholder, AST::CapabilityWrap,
         AST::OptionalUnwrap, AST::FuncCall, AST::MethodCall, AST::StaticCall
      dispatch_expression_visit(node)
    when AST::MoveNode, AST::CopyNode, AST::Copy, AST::LinkNode,
         AST::ResolveNode, AST::FreezeNode, AST::CloneNode, AST::ShareNode
      dispatch_lifetime_visit(node)
    when AST::GetIndex, AST::GetField, AST::Slice, AST::HashLit, AST::StructLit,
         AST::ListLit, AST::TupleLit, AST::DefaultArrayLit, AST::RangeLit
      dispatch_member_visit(node)
    when AST::VarDecl, AST::BindExpr, AST::Identifier, AST::Assignment
      dispatch_variable_visit(node)
    when AST::TestBlock, AST::WhenBlock, AST::TestThat, AST::AssertRaises,
         AST::BenchmarkStmt, AST::SmashStmt, AST::ProfileStmt, AST::StubDecl
      dispatch_test_visit(node)
    when AST::DestructuringAssignment then visit_DestructuringAssignment(node)
    when AST::UnionVariantLit then visit_UnionVariantLit(node)
    else
      Kernel.raise "BUG: no annotation visitor for #{node.class}"
    end
  end

  sig { params(node: T.any(AST::FunctionDef, AST::LambdaLit)).returns(T.untyped) }
  def dispatch_function_visit(node)
    case node
    when AST::FunctionDef then visit_FunctionDef(node)
    when AST::LambdaLit then visit_LambdaLit(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_control_flow_visit(node)
    case node
    when AST::BlockExpr then visit_BlockExpr(node)
    when AST::IfStatement then visit_IfStatement(node)
    when AST::IsA then visit_IsA(node)
    when AST::IfBind then visit_IfBind(node)
    when AST::MatchStatement then visit_MatchStatement(node)
    when AST::ForRange then visit_ForRange(node)
    when AST::ForEach then visit_ForEach(node)
    when AST::WhileLoop then visit_WhileLoop(node)
    when AST::WhileBindLoop then visit_WhileBindLoop(node)
    when AST::BreakNode then visit_BreakNode(node)
    when AST::ContinueNode then visit_ContinueNode(node)
    when AST::PassStmt then visit_PassStmt(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_error_visit(node)
    case node
    when AST::SyncPolicyDecl then visit_SyncPolicyDecl(node)
    when AST::Assert then visit_Assert(node)
    when AST::DieNode then visit_DieNode(node)
    when AST::Raise then visit_Raise(node)
    when AST::ReturnNode then visit_ReturnNode(node)
    when AST::OrElseRaise then visit_OrElseRaise(node)
    when AST::OrElseBreak then visit_OrElseBreak(node)
    when AST::OrElsePass then visit_OrElsePass(node)
    when AST::OrElsePrune then visit_OrElsePrune(node)
    when AST::OrElseExit then visit_OrElseExit(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_execution_boundary_visit(node)
    case node
    when AST::WithBlock then visit_WithBlock(node)
    when AST::DoBlock then visit_DoBlock(node)
    when AST::BgStreamBlock then visit_BgStreamBlock(node)
    when AST::YieldExpr then visit_YieldExpr(node)
    when AST::CloseStream then visit_CloseStream(node)
    when AST::BgBlock then visit_BgBlock(node)
    when AST::ThenChain then visit_ThenChain(node)
    when AST::NextExpr then visit_NextExpr(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_expression_visit(node)
    case node
    when AST::Cast then visit_Cast(node)
    when AST::CallSiteOverride then visit_CallSiteOverride(node)
    when AST::UnaryOp then visit_UnaryOp(node)
    when AST::Literal then visit_Literal(node)
    when AST::DefaultLit then visit_DefaultLit(node)
    when AST::BinaryOp then visit_BinaryOp(node)
    when AST::Placeholder then visit_Placeholder(node)
    when AST::CapabilityWrap then visit_CapabilityWrap(node)
    when AST::OptionalUnwrap then visit_OptionalUnwrap(node)
    when AST::FuncCall then visit_FuncCall(node)
    when AST::MethodCall then visit_MethodCall(node)
    when AST::StaticCall then visit_StaticCall(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_lifetime_visit(node)
    case node
    when AST::MoveNode then visit_MoveNode(node)
    when AST::CopyNode then visit_CopyNode(node)
    when AST::Copy then visit_Copy(node)
    when AST::LinkNode then visit_LinkNode(node)
    when AST::ResolveNode then visit_ResolveNode(node)
    when AST::FreezeNode then visit_FreezeNode(node)
    when AST::CloneNode then visit_CloneNode(node)
    when AST::ShareNode then visit_ShareNode(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_member_visit(node)
    case node
    when AST::GetIndex then visit_GetIndex(node)
    when AST::GetField then visit_GetField(node)
    when AST::Slice then visit_Slice(node)
    when AST::HashLit then visit_HashLit(node)
    when AST::StructLit then visit_StructLit(node)
    when AST::ListLit then visit_ListLit(node)
    when AST::TupleLit then visit_TupleLit(node)
    when AST::DefaultArrayLit then visit_DefaultArrayLit(node)
    when AST::RangeLit then visit_RangeLit(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_variable_visit(node)
    case node
    when AST::VarDecl then visit_VarDecl(node)
    when AST::BindExpr then visit_BindExpr(node)
    when AST::Identifier then visit_Identifier(node)
    when AST::Assignment then visit_Assignment(node)
    end
  end

  sig { params(node: AST::Node).returns(T.untyped) }
  def dispatch_test_visit(node)
    case node
    when AST::TestBlock then visit_TestBlock(node)
    when AST::WhenBlock then visit_WhenBlock(node)
    when AST::TestThat then visit_TestThat(node)
    when AST::AssertRaises then visit_AssertRaises(node)
    when AST::BenchmarkStmt then visit_BenchmarkStmt(node)
    when AST::SmashStmt then visit_SmashStmt(node)
    when AST::ProfileStmt then visit_ProfileStmt(node)
    when AST::StubDecl then visit_StubDecl(node)
    end
  end

  sig { returns(Annotator::Phases::ResolutionSession) }
  def local_resolution_session
    Annotator::Phases::ResolutionSession.new(
      importer: active_importer,
      source_dir: import_source_dir,
      source_code: @config.source_code,
      root_scope: current_scope,
      function_registry: semantic_function_registry,
      install_builtins: false
    )
  end
  private :local_resolution_session

  sig { params(node: AST::Node).void }
  def record_ownership_transport_fact!(node)
    return if language_mode == :strict
    fact_frames = @audit_inputs.ownership_transport_frames
    facts = fact_frames.last
    return unless facts
    ancestors = @traversal_state.annotation_ancestors[0...-1] || []

    if node.is_a?(AST::Identifier)
      fact_frames.each { |frame| frame.record_read(node, ancestors) }
      return
    end
    if (node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)) &&
        T.unsafe(node).ownership_transport_plan.is_a?(OwnershipTransportPlan) &&
        T.unsafe(node).ownership_transport_plan.action == :pending
      facts.record_alias(node, ancestors)
    end

    if node.is_a?(AST::Assignment)
      target = node.name
      root = if target.is_a?(AST::Identifier) || target.is_a?(AST::GetField) || target.is_a?(AST::GetIndex)
        AST.root_identifier(target)
      end
      if root.is_a?(AST::Identifier)
        fact_frames.each { |frame| frame.record_mutation(node, root, ancestors) }
      end
      value = node.value
      if value.is_a?(AST::Identifier) && T.unsafe(value).ownership_pending_transfer == true
        facts.record_transfer(node, "value", value)
      end
    elsif node.is_a?(AST::BindExpr) && node.mode != :decl
      entry = current_scope.resolve_entry(node.name.to_s)
      if entry
        fact_frames.each do |frame|
          frame.record_mutation_id(node, entry.ownership_binding_id, ancestors)
        end
      end
    end

    if node.is_a?(AST::FuncCall) || node.is_a?(AST::MethodCall)
      signature = node.matched_signature
      actuals = node.is_a?(AST::MethodCall) ? [node.object] + node.args : node.args
      if signature
        signature.params.each_with_index do |param, index|
          argument = actuals[index]
          if param.mutable && argument
            root = AST.root_identifier(argument)
            if root.is_a?(AST::Identifier)
              fact_frames.each { |frame| frame.record_mutation(node, root, ancestors) }
            end
          end
        end
      end
      actuals.each_with_index do |argument, index|
        if argument.is_a?(AST::Identifier) && T.unsafe(argument).ownership_pending_transfer == true
          facts.record_transfer(node, index, argument)
        end
      end
    elsif node.is_a?(AST::StructLit)
      node.fields.each do |field_name, value|
        if value.is_a?(AST::Identifier) && T.unsafe(value).ownership_pending_transfer == true
          facts.record_transfer(node, field_name, value)
        end
      end
    end
  end
  private :record_ownership_transport_fact!

  # Outer scope variable set.
  sig { returns(T::Set[String]) }
  def outer_scope_vars
    @traversal_state.scopes.flat_map(&:visible_names).to_set
  end

  sig { returns(T::Array[AST::FunctionDef]) }
  def synthetic_function_definitions
    semantic_function_registry.synthetic_definitions
  end

  sig { void }
  def clear_synthetic_function_definitions!
    semantic_function_registry.clear_synthetic_definitions!
  end

  sig { params(node: AST::FunctionDef).returns(AST::FunctionDef) }
  def queue_synthetic_function!(node)
    semantic_function_registry.add_synthetic_definition!(node)
  end

  # Unifies analysis for callables (Functions and Lambdas).
  # Handles scope entry, parameter/capture declaration, body analysis, 
  # cleanup generation, and return-type inference.
  #
  # @param node [AST::FunctionDef, AST::LambdaLit]
  # @param body [AST::Node, Array<AST::Node>]
  # @param declared_return [Symbol] The explicitly declared return type (or :Any)
  # @param is_implicit [Boolean] True if no return type was specified in source
  # @return [Symbol] The final resolved/inferred return type
  #
  # Visit a statement body.
  sig { params(stmts: T::Array[AST::Node]).void }
  def visit_stmts(stmts)
    stmts.each do |stmt|
      visit(stmt)
    end
  end

  # AST node types that DON'T propagate a BG handle's tied lifetime
  # to their enclosing expression. Their own lifetime semantics are
  # determined by the symbol / return-type the node resolves to, not
  # by walking into their sub-expressions:
  #
  #   - Identifier / Literal — terminal values; lifetime via symbol.
  #   - FuncCall / MethodCall — return type carries lifetime; args are
  #     argument-position, not return-position.
  #   - GetField / GetIndex — lifetime via root identifier's symbol.
  #   - BinaryOp / UnaryOp — produce primitives; never embed a BG.
  #
  # Default-deny inverse: every OTHER AST node-with-sub-expressions is
  # walked by reflection. New container shapes (TupleLit, future
  # collection literals, transparent wrappers) recurse for free
  # without code changes.
  BG_SOURCE_OPAQUE_AST_NODES = T.let(Set[
    AST::Identifier, AST::Literal,
    AST::FuncCall,   AST::MethodCall,
    AST::GetField,   AST::GetIndex,
    AST::BinaryOp,   AST::UnaryOp,
  ].freeze, T.untyped)

  # Captures are lifetime-bound by default. A storage/sync layer is escape-safe
  # only when listed here, so new combinations over-reject instead of silently
  # permitting a dangling BG capture.

  # `sync` values that DON'T wrap the underlying data in a
  # reference-bound layer. :raw / :symbol are pure data-access modes
  # (not locks), so they don't bind the capture's lifetime.
  SYNC_DOES_NOT_BIND_CAPTURE = T.let(Set[:raw, :symbol].freeze, T.untyped)

  # `storage` values whose memory has its own lifetime mechanism
  # independent of the declaring scope. `:shared` means Arc — own
  # refcount; capture clones the Arc and stays alive. `:heap` is
  # explicitly heap-allocated; lifetime decided at allocation site.
  STORAGE_OUTLIVES_DECLARING_SCOPE = T.let(Set[:shared, :heap].freeze, T.untyped)

  # ── Strict Test Mode ─────────────────────────────────────────────
  # In --strict mode, all IO functions (BLOCKING/EXTERN effects) must be
  # stubbed in test bodies. Walks the call chain transitively.

  # IO_BUILTINS and validate_strict_io! moved to
  # annotator/helpers/test_annotation.rb (TestAnnotation module).

  sig { params(from: String, to: String, at_token: T.nilable(Lexer::Token), action: Symbol).returns(T.nilable(T::Set[String])) }
  def og_move(from, to, at_token: nil, action: :move) = ownership_graph.transfer(from, to, at_token: at_token, action: action)
  sig { params(name: String, at_token: T.nilable(Lexer::Token), action: Symbol, consumer_param_type: OwnershipGraph::MoveConsumerParamType).returns(T.nilable(T::Set[String])) }
  def og_set_moved(name, at_token: nil, action: :move, consumer_param_type: nil) = ownership_graph.mark_moved(name, at_token: at_token, action: action, consumer_param_type: consumer_param_type)
  sig { params(name: String).returns(T.nilable(Symbol)) }
  def og_set_live(name)  = (ownership_graph[name]&.state = :live)
  sig { params(name: String).returns(T::Array[String]) }
  def og_drop(name)      = ownership_graph.drop(name)
  sig { returns(Integer) }
  def og_push_scope
    ownership_graph.push_scope!
  end
  sig { params(archive: T::Boolean).returns(Integer) }
  def og_pop_scope(archive: false)
    ownership_graph.pop_scope!(archive: archive)
  end

  private :current_fn_ctx
  private :current_held_lock_types
  private :semantic_function_registry
  private :capability_audit
  private :current_conditional_depth
  private :current_fn_ctx!
  private :current_held_locks
  private :current_loop_depth
  private :current_predicate_context
  private :current_stream_yield_frame
  private :deferred_with_validations
  private :function_node_for
  private :function_node_map
  private :handle_prefixed_int_overflow!
  private :inside_match_pattern_context?
  private :inside_with_block?
  private :pending_deferred_validation_count
  private :predicate_call_sites
  private :release_capability_audit_inputs!
  private :release_capability_audit_request!
  private :analyze_resolution!
  private :record_snapshot_txn_violation!
  private :register_function_node!
  private :semantic_function_nodes
  private :semantic_held_lock_types
  private :semantic_lock_type_ranks
  private :semantic_program
  private :semantic_root_scope
  private :scope_stack
  private :source_code
  private :smooth_depth
  private :stamp_type!
  private :with_conditional_context
  private :with_held_locks
  private :with_match_family_effects
  private :with_match_pattern_context
  private :with_predicate_context
  private :with_smooth_context
  private :with_snapshot_transaction_body
  private :with_stream_yield_frame
  private :language_mode
  private :strict_test?

end
