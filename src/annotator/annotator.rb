# typed: strict
require "sorbet-runtime"

require_relative "../ast/source_error"
require_relative "../ast/fixable_error"
require_relative "../ast/scope"
require_relative "../ast/parser"
require_relative "../ast/std_lib"
require_relative "../ast/async_result_shape"
require_relative "phases/annotation_boundary"
require_relative "phases/body_analysis"
require_relative "phases/builtin_environment"
require_relative "phases/declaration_index"
require_relative "phases/auto_finalization"
require_relative "phases/deferred_validation"
require_relative "phases/expression_domains"
require_relative "phases/program_finalization"
require_relative "phases/signature_registry"
require_relative "phases/signature_registration"
require_relative "phases/type_registration"
require_relative "phases/whole_program_semantics"
require_relative "domains/control_flow"
require_relative "domains/variables"
require_relative "domains/member_access"
require_relative "domains/execution_boundaries"
require_relative "domains/errors"
require_relative "domains/expressions"
require_relative "domains/lifetimes"
require_relative "helpers/function_context"
require_relative "helpers/function_signature"
require_relative "helpers/function_analysis"
require_relative "helpers/pipe_analysis"
require_relative "../semantic/ownership_graph"
require_relative "../semantic/escape_analysis"
require_relative "../semantic/pass_state"
require_relative "../semantic/bg_capture_classifier"
require_relative "../semantic/effect_inference"
require_relative "../semantic/concurrency_checks"
require_relative "helpers/generic_analysis"
require_relative "helpers/capabilities"
require_relative "helpers/test_annotation"
require_relative "helpers/with_match_check"
require_relative "helpers/fixable_helpers"
require_relative "helpers/effects"
require_relative "helpers/reentrance"
require_relative "../mir/thunk_transform"
require_relative "helpers/lock_helper"
require_relative "../mir/alloc"
require_relative "helpers/method_analysis"
require_relative "helpers/union"
require_relative "helpers/auto_inference"
require_relative "../backends/importer" # ModuleImporter — referenced by SemanticAnnotator#initialize's sig

# Handle Type inference, and semantic validation
class SemanticAnnotator
    extend T::Sig

  include ErrorHelper
  include FixableHelper
  include FunctionAnalysis
  include PipeAnalysis
  include ScopeHelper
  include TypeHelper
  include GenericAnalysis
  include EffectTracker
  include ReentranceBridge
  include CapabilityHelper
  include CapabilityAudit
  include AllocHelper
  include MethodAnalysis
  include UnionAnalysis
  include LockHelper
  include TestAnnotation
  include Annotator::Phases::AnnotationBoundary
  include Annotator::Phases::AutoFinalization
  include Annotator::Phases::BodyAnalysis
  include Annotator::Phases::BuiltinEnvironment
  include Annotator::Phases::DeferredValidation
  include Annotator::Phases::ExpressionDomains
  include Annotator::Phases::ProgramFinalization
  include Annotator::Phases::TypeRegistration
  include Annotator::Phases::SignatureRegistration
  include Annotator::Phases::WholeProgramSemantics
  include Annotator::Domains::ControlFlow
  include Annotator::Domains::Variables
  include Annotator::Domains::MemberAccess
  include Annotator::Domains::ExecutionBoundaries
  include Annotator::Domains::Errors
  include Annotator::Domains::Expressions
  include Annotator::Domains::Lifetimes

  class SnapshotTxnViolation < T::Struct
    const :effect, Symbol
    const :fn, String
  end

  sig { returns(T.untyped) }
  attr_reader :scope_stack

  sig { returns(T::Hash[String, AST::FunctionDef]) }
  def semantic_function_nodes
    @fn_nodes
  end

  sig { returns(Scope) }
  def semantic_root_scope
    T.cast(@scope_stack.first, Scope)
  end

  sig { returns(T.nilable(AST::Program)) }
  def semantic_program
    @program
  end

  sig { returns(T::Hash[Symbol, Integer]) }
  def semantic_lock_type_ranks
    @lock_type_ranks || {}
  end

  sig { returns(T::Array[HeldLockTypeEntry]) }
  def semantic_held_lock_types
    @held_lock_types || []
  end

  sig { returns(Integer) }
  def pending_deferred_validation_count
    @deferred_with_validations.length
  end

  sig { returns(T::Array[Annotator::Phases::DeferredWithValidation]) }
  def deferred_with_validations
    @deferred_with_validations
  end

  sig { returns(T.nilable(FunctionContext)) }
  def current_fn_ctx
    @function_context_stack.last
  end

  sig { returns(FunctionContext) }
  def current_fn_ctx!
    T.must(current_fn_ctx)
  end

  sig { params(ctx: FunctionContext).returns(FunctionContext) }
  def push_function_context!(ctx)
    @function_context_stack << ctx
    ctx
  end
  private :push_function_context!

  sig { returns(T.nilable(FunctionContext)) }
  def pop_function_context!
    @function_context_stack.pop
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
    node.full_type = value
    stamped = node.full_type!(context: "annotation stamp")
    raise "annotation stamp produced :Untyped for #{node.class}" if stamped.untyped?
    value
  end

  sig { params(effect: Symbol, fn_name: String).void }
  def record_snapshot_txn_violation!(effect, fn_name)
    T.must(@snapshot_txn_violations) << SnapshotTxnViolation.new(effect: effect, fn: fn_name)
  end

  # Run the given block with conditional_depth incremented on the current
  # function context (or the global fallback when outside a function).
  # Used to tag SUSPENDS effects recorded inside IF branches / MATCH arms
  # as SUSPENDS:CONDITIONAL.
  sig { params(blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def with_conditional_context(&blk)
    if current_fn_ctx
      current_fn_ctx&.enter_conditional!
      begin
        blk.call
      ensure
        current_fn_ctx&.exit_conditional!
      end
    else
      @conditional_depth += 1
      begin
        blk.call
      ensure
        @conditional_depth -= 1
      end
    end
  end

  sig do
    type_parameters(:Result)
      .params(blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_match_pattern_context(&blk)
    previous = @match_pattern_context
    @match_pattern_context = T.let(true, T.nilable(T::Boolean))
    blk.call
  ensure
    @match_pattern_context = T.let(previous == true, T.nilable(T::Boolean))
  end

  class HeldLockEntry < T::Struct
    const :token, T.nilable(Lexer::Token)
  end

  HeldLockMap = T.type_alias { T::Hash[String, HeldLockEntry] }

  class HeldLockTypeEntry < T::Struct
    const :type, Symbol
    const :opted_out, T::Boolean
  end

  DeadlockEscape = T.type_alias { T::Hash[Symbol, T.any(Symbol, Lexer::Token)] }

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
        expanded_capabilities: T::Array[AST::Capability],
        blk: T.proc.returns(T.type_parameter(:Result)),
      )
      .returns(T.type_parameter(:Result))
  end
  def with_held_locks(node, expanded_capabilities, &blk)
    previous_locks = T.let(@held_locks || {}, HeldLockMap)
    previous_types = T.let(@held_lock_types || [], T::Array[HeldLockTypeEntry])
    current_locks = T.let(previous_locks.dup, HeldLockMap)
    current_types = T.let(previous_types.dup, T::Array[HeldLockTypeEntry])
    @held_locks = T.let(current_locks, T.nilable(HeldLockMap))
    @held_lock_types = T.let(current_types, T.nilable(T::Array[HeldLockTypeEntry]))
    opted_out = !node.deadlock_escape.nil?

    expanded_capabilities.each do |capability|
      next unless capability[:capability] == :EXCLUSIVE || capability[:capability] == :write_locked_read

      variable_name = cap_var_name(capability[:var_node])
      token = capability[:var_node].respond_to?(:token) ? capability[:var_node].token : node.token
      current_locks[variable_name] ||= HeldLockEntry.new(token: token)
      lock_type = lock_identity_of(capability)
      current_types << HeldLockTypeEntry.new(type: lock_type, opted_out: opted_out) if lock_type
    end

    blk.call
  ensure
    @held_locks = T.let(previous_locks, T.nilable(HeldLockMap))
    @held_lock_types = T.let(previous_types, T.nilable(T::Array[HeldLockTypeEntry]))
  end

  sig do
    type_parameters(:Result)
      .params(node: AST::WithBlock, blk: T.proc.returns(T.type_parameter(:Result)))
      .returns(T.type_parameter(:Result))
  end
  def with_snapshot_transaction_body(node, &blk)
    previous_depth = T.let(@inside_snapshot_txn || 0, Integer)
    previous_violations = @snapshot_txn_violations
    @inside_snapshot_txn = T.let(previous_depth + 1, T.nilable(Integer))
    @snapshot_txn_violations = T.let([], T.nilable(T::Array[SnapshotTxnViolation]))
    result = blk.call
    txn_violations = T.must(@snapshot_txn_violations)
    unless txn_violations.empty?
      kinds = txn_violations.map { |violation| EffectTracker.display(violation.effect) }.uniq.join(", ")
      error!(node, :WITH_SNAPSHOT_BODY_NOT_PURE, kinds: kinds)
    end
    result
  ensure
    @inside_snapshot_txn = T.let(previous_depth, T.nilable(Integer))
    @snapshot_txn_violations = T.let(previous_violations || [], T.nilable(T::Array[SnapshotTxnViolation]))
  end

  # `source_code` is optional — used ONLY by fixable-error helpers to
  # locate source-level spans (e.g., the `;` at the end of a
  # declaration line so `@multiowned` can be inserted before it).
  # When nil, affected helpers fall back to the plain `error!` path.
  sig { returns(T.nilable(String)) }
  attr_accessor :source_code

  sig { params(importer: T.nilable(ModuleImporter), compiler: T.nilable(ModuleImporter), source_dir: T.nilable(String), strict_test: T::Boolean, source_code: T.nilable(String)).void }
  def initialize(importer: nil, compiler: nil, source_dir: nil, strict_test: false, source_code: nil)
    @importer   = T.let(importer || compiler, T.nilable(ModuleImporter))
    @source_dir = T.let(source_dir ? File.expand_path(source_dir) : Dir.pwd, String)
    @strict_test = strict_test
    @source_code = source_code
    # We start with a global scope
    @scope_stack = T.let([Scope.new], T::Array[T.untyped])
    @function_context_stack = T.let([], T::Array[FunctionContext])
    @loop_depth = T.let(0, Integer) # Track if we are inside a loop
    @conditional_depth = T.let(0, Integer) # Track if we are inside an IF branch or MATCH arm
    @smooth_depth = T.let(0, Integer)
    @match_pattern_context = T.let(false, T.nilable(T::Boolean)) # True when visiting a MATCH case value (suppresses inline-struct GetField error)
    @held_locks = T.let({}, T.nilable(HeldLockMap))
    @held_lock_types = T.let([], T.nilable(T::Array[HeldLockTypeEntry]))
    # Reentrancy and fallibility analysis facts recorded by the body-summary
    # phase. This is the single source for call graph, propagating callees,
    # fn-pointer calls, and direct failure seeds.
    @body_summaries = T.let({}, T::Hash[String, Annotator::Phases::FunctionBodySummary])
    @fn_nodes    = T.let({}, T::Hash[String, AST::FunctionDef])  # name => FunctionDef node (for error reporting in the post-pass)
    # Capability audit — tracks declarations and usage to detect over-engineering.
    # SOA analysis: tracks which fields of `_` are accessed during pipeline lambda bodies.
    # nil = not inside a pipeline; Set = collecting field names.
    @pipeline_accessed_fields = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_predicate_context = T.let(nil, T.nilable(CapabilityHelper::PredicateContext))
    @capability_audit = T.let({}, T.nilable(CapabilityAudit::BindingAuditStore))
    @fn_direct_effects = T.let({}, T::Hash[T.untyped, T.untyped])
    @call_site_context = T.let(nil, T.untyped)
    @call_site_arg_families = T.let(nil, T.untyped)
    @in_auto_locked_assign = T.let(nil, T.nilable(String))
    @with_block_depth = T.let(0, Integer)

    # Lock analysis is cycle-checked after function_call_graph is complete.
    init_lock_analysis!
    # @pinned escape safety: true when inside a @pinned BG block.
    @current_bg_pinned = T.let(false, T::Boolean)
    # WITH validations on parameter bindings need caller-sync propagation first.
    @deferred_with_validations = T.let([], T::Array[Annotator::Phases::DeferredWithValidation])
    @predicate_call_sites = T.let([], T.nilable(T::Array[CapabilityHelper::PredicateCallSite]))
    # Tracks remaining statements in current body for forward reference analysis
    @stmts_after = T.let(nil, T.nilable(T::Array[T.untyped]))
    # Ownership graph: shadow tracker that runs in parallel with the scope-based system.
    @og = T.let(OwnershipGraph.new, T.untyped)
    @og_scope_depth = T.let(0, Integer)
    @synthetic_fns = T.let([], T::Array[AST::FunctionDef])
    @branch_terminated = T.let(false, T::Boolean)
    @snapshot_txn_violations = T.let([], T.nilable(T::Array[SnapshotTxnViolation]))
    @inside_snapshot_txn = T.let(0, T.nilable(Integer))
    @stream_yield_types = T.let([], T::Array[Type])
    effects_init!
    capability_audit_init!
    initialize_builtin_environment!
  end

  sig { params(node: AST::Program).returns(T.nilable(T::Hash[String, T::Hash[Symbol, T.untyped]])) }
  def annotate!(node)
    # Reset user-registered error types so state from prior runs (rspec
    # parallel, multi-program test harness) doesn't leak in. Stdlib
    # types are preserved.
    AST.reset_user_types!
    @program = T.let(node, T.nilable(AST::Program))  # WithMatchCheck reads node.sync_policy below.
    visit(node)
    finalize_auto_types!(node)
    run_whole_program_semantics!
    run_deferred_validations!
    mark_annotation_complete!(node)
    nil
  end

private

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def runtime_error_clause?(node)
    (node.respond_to?(:pre_clauses) && node.pre_clauses && node.pre_clauses.any?) ||
      (node.catch_clauses.is_a?(Array) && node.catch_clauses.any?) ||
      (node.default_catch.is_a?(Array) && node.default_catch.any?)
  end

  # Auto inference runs after the body walk has populated type_info on
  # every constraint source. It mutates successful Auto declarations to
  # concrete types and uses operator evidence to rank ambiguous fixes.
  sig { params(program_node: AST::Program).void }
  def run_auto_inference!(program_node)
    collector = AutoConstraintCollector.new(@fn_nodes)
    slots = collector.collect!(program_node)
    return if slots.empty?

    # Empty `[]` / `{}` initializers need forward-flow evidence from later
    # appends and index writes before unification can pick an element type.
    ShapeEvidenceCollector.new(slots, @fn_nodes).collect!

    op_evidence = OperatorEvidenceCollector.new(slots, @fn_nodes).collect!

    unifier = AutoUnifier.new(slots)
    result = unifier.resolve!

    unifier.stamp_map_pairs!(result.resolved)

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

  # Quick walk to detect whether the program has any Auto Types.
  # Skips the inference pipeline entirely when there are none —
  # avoids the cost on regular (non-gradual) programs.
  sig { params(node: T.untyped).returns(T::Boolean) }
  def program_has_auto?(node)
    return false if node.nil?
    case node
    when Type
      return node.auto?
    when Symbol, String, Numeric, TrueClass, FalseClass
      return false
    when Array
      return node.any? { |c| program_has_auto?(c) }
    when Hash
      return node.each_value.any? { |v| program_has_auto?(v) }
    end
    return true if node.respond_to?(:type) && node.type.is_a?(Type) && node.type.auto?
    return true if node.respond_to?(:return_type) && node.return_type.is_a?(Type) && node.return_type.auto?
    if node.respond_to?(:params) && node.params.is_a?(Array)
      return true if node.params.any? { |p| p.type&.auto? }
    end
    if node.respond_to?(:each_pair)
      return node.each_pair.any? { |_, v| program_has_auto?(v) }
    end
    false
  end

  sig { returns(T::Hash[Symbol, T::Hash[Symbol, T.untyped]]) }
  def setup_builtins
    STD_LIB.each do |name, config|
      current_scope.declare(name, nil, :Intrinsic, false, false, nil, :stack)
    end

    # Setup Globals
    current_scope.declare("argv", nil, Type::STRING_TYPE, false, false, nil, :heap)

    # Built-in Range type: fields accessible via dot access
    current_scope.declare_type(:Range, Schemas::StructSchema.new(fields: {
      "start" => AST::StructField.new(type: :Float64),
      "end"   => AST::StructField.new(type: :Float64),
    }))

    # Built-in File resource type
    # bc/bc_op marks the static methods as VM-dispatchable so the lowering
    # produces a structural MIR::InlineBc that both backends consume. The
    # close_zig template carries to the resource's MIR::Cleanup unchanged
    # (Zig defers it; BC ignores -- the VM has no fd-style close).
    current_scope.declare_type(:File, Schemas::ResourceSchema.new(
      close_zig: "{0}.close()",
      static_methods: {
        "open"   => { args: [:String], return: :File, zig: "try CheatLib.fileOpen({0})",
                       bc: true, bc_op: :file_open, can_fail: true },
        "create" => { args: [:String], return: :File, zig: "try CheatLib.fileCreate({0})",
                       bc: true, bc_op: :file_create, can_fail: true }
      }
    ))

    # Built-in TCPServer resource type — a non-blocking server socket (i32 fd).
    # TCPServer::listen(port) returns the server fd; auto-closes via RAII.
    current_scope.declare_type(:TCPServer, Schemas::ResourceSchema.new(
      close_zig: "CheatLib.socketClose({0})",
      static_methods: {
        "listen" => { args: [:Int64], return: :TCPServer, zig: "try CheatLib.socketListen(@intCast({0}))", can_fail: true }
      }
    ))

    # Built-in TCPClient resource type — a connected client socket (i32 fd).
    # Produced by accept(server) or TCPClient::connect(host, port).
    # Auto-closes via RAII.
    current_scope.declare_type(:TCPClient, Schemas::ResourceSchema.new(
      close_zig: "CheatLib.socketClose({0})",
      static_methods: {
        "connect" => { args: [:String, :Int64], return: :TCPClient,
                       zig: "try CheatLib.socketConnect({0}, @intCast({1}))", can_fail: true }
      }
    ))
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def visit(node)
    return unless node
    return if node.is_a?(Symbol)

    case node
    when AST::StructDef, AST::ExternStructDecl, AST::EnumDef, AST::UnionDef
      return register_type_declaration(node)
    when AST::ExternFnDecl
      register_extern_function_signature(node)
      return
    end

    # Dynamic Dispatch
    method_name = "visit_#{node.class.name.split('::').last}"
    send(method_name, node)
  end

  # Cached outer scope variable set - avoids O(n) flat_map per loop
  sig { returns(T::Set[String]) }
  def outer_scope_vars
    @scope_stack.flat_map { |s| s.locals.keys }.to_set
  end

  sig { params(node: AST::Program).returns(T.untyped) }
  def visit_Program(node)
    declarations = Annotator::Phases::DeclarationIndexer.index(node)

    # Imports must be available before local types or functions are registered.
    declarations.imports.each { |stmt| visit_RequireNode(stmt) }

    # Types are registered before function signatures can reference them.
    register_type_declarations(declarations)

    # Function, extern, method, and synthesized union default signatures are
    # hoisted so bodies can call later definitions.
    register_program_signatures(declarations)

    # Bridge legacy `@reentrant` and new `EFFECTS REENTRANT` after
    # @fn_nodes is populated and before function bodies are checked.
    bridge_reentrance!(node)

    # Seed before body analysis so CATCH Type clauses can reference error
    # types registered by later-in-source RAISE sites.
    seed_error_types_from_raises!(node)

    # Stamps the resolved SYNC POLICY, user-written or default, so later
    # passes read a single source of truth.
    validate_and_resolve_sync_policy!(node)

    analyze_program_bodies!(declarations, node)
    finalize_program_semantics!(node)
  end

  sig { returns(T::Array[AST::FunctionDef]) }
  def synthetic_function_definitions
    @synthetic_fns
  end

  sig { params(node: AST::RequireNode).returns(T.nilable(T::Hash[Symbol, T::Hash[Symbol, T.untyped]])) }
  def visit_RequireNode(node)
    unless @importer
      error!(node, :REQUIRE_NEEDS_IMPORTER, hint: "Pass importer: and source_dir: to SemanticAnnotator.new.")
    end

    importer = T.must(@importer)
    mod = if node.kind == :package
      importer.compile_package(node.path, caller_dir: @source_dir)
    else
      importer.compile_file(node.path, caller_dir: @source_dir)
    end
    mod = T.must(mod)
    stamp_type!(node, :Void)

    # Packages are always external — only :pub symbols are importable.
    same_dir = (node.kind != :package) && (mod.source_dir == @source_dir)

    # Import function signatures that are visible from this call site.
    mod.global_scope.locals.each do |name, entry|
      sig = entry.fn_signature
      next unless sig

      # For package imports: skip functions that were themselves imported from
      # another module (they have a pre-existing module_alias). Those functions
      # live in their own package's Zig module and must be accessed through it.
      next if node.kind == :package && sig.module_alias

      # For local imports: skip re-exporting functions that were imported from
      # a deeper module. They live in their original namespace's struct wrapper
      # and the requiring file already has them with the correct module_alias.
      next if node.kind != :package && sig.module_alias

      vis = sig.visibility || :package
      importable = (vis == :pub) || (vis == :package && same_dir)
      next unless importable

      # Tag the signature with the namespace so the transpiler can qualify calls.
      imported_sig = sig.dup
      imported_sig.module_alias = node.namespace
      current_scope.declare(name, nil, imported_sig, false, false, nil, :static)
    end

    # Import type definitions (structs, unions, enums) respecting visibility.
    mod.global_scope.types.each do |type_name, type_entry|
      vis = type_entry[:schema].visibility || :package
      next if vis == :private
      next unless (vis == :pub) || (vis == :package && same_dir)
      current_scope.declare_type(type_name, type_entry[:schema])
    end
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
  sig { params(node: AST::LambdaLit).returns(T.nilable(FunctionSignature)) }
  def visit_LambdaLit(node)
    # Lambdas are always implicit return unless we add syntax for it later
    return_type = analyze_routine(node, node.body, :Any, true)

    # Build standard signature (same format as user-defined functions)
    # This enables verify_function_signature! to validate lambda calls
    stamp_type!(node, build_lambda_signature(node.params, T.must(return_type)))
  end

  sig { params(node: AST::FunctionDef).returns(T.nilable(FunctionContext)) }
  def visit_FunctionDef(node)
    effects_begin_function(node.name)

    # 1. Setup metadata
    is_implicit_return = node.return_type.nil?
    node.type_params = infer_implicit_type_params(node) if node.respond_to?(:type_params=)
    declared_return = node.return_type || :Any
    lifetime_paths = get_lifetime_paths(node)
    fn_type_params = (node.type_params || []).map(&:to_sym)
    push_function_context!(FunctionContext.new(
      name: node.name, return_type: node.return_type || Type.new(:Any),
      lifetime: lifetime_paths, type_params: fn_type_params
    ))

    # 2. Validation & Lifetime
    has_mutable_param = node.params.any? { |p| p.mutable }
    if has_mutable_param && !node.name.end_with?("!")
      emit_style_mutable_param_needs_bang!(node)
    end
    verify_lifetime!(node)

    # Validate generic type params on the function definition
    validate_type_param_list!(node, node.type_params, "function") if fn_type_params.any?

    # Make type params visible during type annotation validation
    node.params.each { |p| validate_type_annotation!(node, p.type, is_param: true) if p.type }
    validate_type_annotation!(node, node.return_type) if node.return_type

    # 3. Pre-declaration (so the function can be recursive)
    signature = FunctionSignature.new(
      params: node.params.map { |p| AST::Param.new(
        name: p.name, type: p.type, required: p.default.nil?,
        default: p.default, mutable: p.mutable, takes: p.takes,
        sync: p.type&.any_sync? ? p.type.sync : nil
      )},
      return_type: node.return_type || Type.new(:Any), return_lifetime: lifetime_paths,
      visibility: node.visibility,
      type_params: fn_type_params.any? ? fn_type_params : nil,
      reentrant: node.reentrant == :reentrant
    )
    signature.requires = node.requires
    current_scope.declare(node.name, nil, signature, false, false, nil, :static)

    # Register function node before body analysis so recursive references can resolve it.
    @fn_nodes[node.name] = node

    # 4. Routine Analysis
    final_return_type = analyze_routine(node, node.body, declared_return, is_implicit_return)

    # 4.5 Reentrancy analysis: scan body after annotation so fn_var_call flags are set.
    called_names, has_fnptr, unabsorbed_calls = scan_for_calls(node.body)
    directly_recursive = called_names.include?(node.name)
    current_fn_ctx&.mark_runtime_used! if has_fnptr && current_fn_ctx

    if directly_recursive
      record_effect(EffectTracker::REENTRANT)
      case node.reentrant
      when :non_reentrant
        # NOT_LOGICAL gets a specific compile-time error from
        # `validate_not_logical_recursion!`, so skip the legacy phrasing here.
        # MAX_DEPTH on direct self-recursion is FINE -- the runtime
        # depth counter is exactly the mechanism that bounds it; the
        # legacy "Use @reentrant" message would mislead. The cycle-
        # member case still gets a fixable warning from
        # `validate_max_depth_mutual_cycle!`.
        # Both share `reentrant = :non_reentrant` (the bridge piggybacks
        # on the legacy codegen path), so suppress here for either.
        unless [:reentrant_not_logical, :reentrant_max_depth].include?(node.reentrance_kind)
          emit_reentrant_error!(node, :REENTRANCE_DIRECT_RECURSIVE,
            hint: "Replace `@nonReentrant` with `EFFECTS REENTRANT` (directly recursive functions need a recursion budget).")
        end
      when nil
        emit_reentrant_error!(node, :REENTRANCE_INDIRECT_RECURSIVE,
          hint: "Add `EFFECTS REENTRANT` to the function signature to allow this.")
      end

      if node.tail_call
        validate_tail_call!(node)
      end

      # Tail-recursive :THUNK uses the existing tail-call lowering; non-tail
      # thunks need a splitter plan before MIR lowering can synthesize the
      # trampoline body.
      if node.reentrance_kind == :reentrant_thunk && !node.tail_call
        plan = ThunkTransform::RecursiveSplitter.split(node.body, node.name, self)
        if plan
          node.thunk_plan = plan
        else
          error!(node, :REENTRANCE_THUNK_NON_TAIL, name: node.name, hint: "a shape this phase does not yet recognize. Supported: simple " \
                 "recurrence (zero or more `IF base -> RETURN const;` followed by a final " \
                 "`RETURN expr <op> #{node.name}(args);`). Wider shapes (multi-recursion, " \
                 "arbitrary control flow with recursion) land in later sub-phases. For " \
                 "now, declare ':TAIL_CALL' or use plain 'EFFECTS REENTRANT'.")
        end
      end
    elsif node.tail_call
      error!(node, :REENTRANCE_TAIL_CALL_NOT_RECURSIVE, name: node.name, hint: "Remove :tailCall - it only applies to self-recursive functions.")
    elsif node.reentrance_kind == :reentrant_thunk
      # The "directly recursive" branch above is false here. The
      # function might still be MUTUALLY recursive (A calls B calls
      # A), which function_call_graph hasn't fully recorded yet at this
      # point in Pass 3. Defer the THUNK-recursion validation to
      # Pass 4.1 (validate_thunk_recursion!) which runs after
      # check_indirect_reentrancy populates the cycle data.
    end

    # Note: calling through a fn-type variable (parameter or local lambda) does NOT
    # require @reentrant — the caller controls what is passed and self-recursion is
    # the caller's explicit choice.  Only the call-graph cycle post-pass (below) fires
    # errors for implicit mutual/direct recursion.

    # 5. Finalize Signature
    if (is_implicit_return || declared_return == :Any)
      node.return_type = final_return_type
      signature.return_type = final_return_type
    end

    signature.return_strategy = get_return_strategy(signature.return_type)
    stamp_type!(node, signature)
    ctx = current_fn_ctx!
    node.uses_frame = (ctx.frame_count > 0)
    node.uses_heap  = (ctx.heap_count > 0)
    node.uses_alloc = (ctx.alloc_count > 0)
    node.uses_rt    = ctx.uses_rt
    node.stack_vars_bytes = ctx.stack_vars_bytes
    # Seed for compute_can_fail! post-pass: GENUINE failure sources only.
    # A function is fallible iff a failure can propagate to its caller:
    #   - scan_for_raises  : RAISE / OrRaise / RAISE-bubbling WithBlock
    #   - PRE clauses       : a failed PRE emits `return error.CheatError`
    #   - @nonReentrant     : StackGuard/enterDepth emit `try ...` (raise)
    #   - fn-pointer call   : conservatively fallible (target may raise)
    # These STAY. What must NOT be here is "allocates / needs the
    # runtime" (uses_frame, uses_heap, uses_alloc, heap_ret): CLEAR's
    # arena model bump-allocates and panics on OOM -- it does not return
    # an error union -- so `charAt`/`split`/concat/list-build/heap-return
    # are NOT failure. Conflating allocation with failure forced every
    # string-touching `RETURNS T` to `RETURNS !T` with a lying "raises
    # directly via RAISE" diagnostic (puck-clear-bugs.md #3).
    raises_directly =
      has_fnptr ||
      (node.reentrant == :non_reentrant) ||
      (node.respond_to?(:pre_clauses) && node.pre_clauses && node.pre_clauses.any?) ||
      scan_for_raises(node.body) == true
    record_function_body_summary!(Annotator::Phases::FunctionBodySummary.new(
      name: node.name,
      callees: called_names - [node.name],
      propagating_callees: (unabsorbed_calls || called_names) - [node.name],
      has_fnptr_call: has_fnptr,
      raises_directly: raises_directly
    ))
    if current_fn_ctx && runtime_error_clause?(node)
      current_fn_ctx&.mark_runtime_used!
    end

    # Visit CATCH clause bodies with __error and snapshot in scope.
    if node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
      # Resolve each parsed clause to a { kind, error_names } pair the
      # lowering can emit directly. Validates every type against the
      # registry and rejects kind mismatches.
      node.catch_clauses.each { |c| resolve_catch_clause!(c) }

      snap_types = Set.new
      all_catch_bodies = node.catch_clauses.map { |c| c.body }
      all_catch_bodies << node.default_catch if node.default_catch.is_a?(Array)
      # Snapshot capture is only meaningful when a CATCH body reads
      # `snapshot`. Otherwise every successful pipeline call in a catchable
      # function allocates dead snapshot state that no handler can observe.
      collect_pipe_input_types(node.body, snap_types) if catch_bodies_reference_snapshot?(all_catch_bodies)
      node.snapshot_types = snap_types

      all_catch_bodies.compact.each do |clause_body|
        with_new_scope do
          # Declare __error as a struct-like type accessible in CATCH
          current_scope.declare("__error", nil, :ErrorContext, false, false, nil, :stack)
          # Declare snapshot if unambiguous
          if snap_types.size == 1
            current_scope.declare("snapshot", nil, snap_types.first.to_sym, false, false, nil, :stack)
          end
          visit_stmts(clause_body)
        end
      end

    end


    pop_function_context!
  end

  # Visit a statement body while tracking remaining siblings in @stmts_after.
  # This lets visit_MatchStatement check whether the match subject is used
  # after the match (to avoid incorrect auto-TAKES consumption).
  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def visit_stmts(stmts)
    return unless stmts.is_a?(Array)
    saved = @stmts_after
    stmts.each_with_index do |stmt, i|
      @stmts_after = T.let(stmts[(i + 1)..], T.nilable(T::Array[T.untyped]))
      visit(stmt)
    end
    @stmts_after = saved
  end

  # Called after Pass 2 (all function signatures registered).
  # Verifies that every method requirement declared inside the UNION body
  # is satisfied by a concrete top-level function with a matching signature.
  sig { params(node: AST::UnionVariantLit).returns(T.nilable(Symbol)) }
  def visit_UnionVariantLit(node)
    schema = lookup_type_schema(node.union_name.to_sym)
    var_data = validate_union_schema!(node, schema)
    validate_union_fields!(node, T.must(var_data).typed_fields)
    stamp_type!(node, node.union_name.to_sym)
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

  # ── Tail Call Validation ─────────────────────────────────────────

  # Tail-call lowering relies on recursion becoming a self-loop; any
  # wrapped or nested self-call would still consume real stack.
  sig { params(fn_node: AST::FunctionDef).returns(T.nilable(T::Array[AST::FuncCall])) }
  def validate_tail_call!(fn_node)
    fn_name = fn_node.name
    all_self_calls = collect_self_calls(fn_node.body, fn_name)

    blessed = collect_returns(fn_node.body).filter_map { |r|
      r.value if r.value.is_a?(AST::FuncCall) && r.value.name == fn_name
    }
    blessed_ids = blessed.map(&:object_id).to_set

    if blessed.empty?
      error!(fn_node, :TAIL_CALL_NEEDS_RECURSIVE, fn: fn_name, hint: "RETURN that directly calls '#{fn_name}' in tail position " \
             "(e.g., RETURN #{fn_name}(...)). The recursive call cannot be " \
             "wrapped in an expression.")
    end

    all_self_calls.each do |call|
      next if blessed_ids.include?(call.object_id)
      error!(call, :TAIL_CALL_NOT_TAIL_POSITION, fn: fn_name, hint: "All recursive self-calls must be the ENTIRE return expression (e.g., " \
             "RETURN #{fn_name}(...)). Non-tail recursion would consume the fiber " \
             "stack on every invocation. If recursion is genuinely non-tail, declare " \
             "':THUNK' instead -- it handles arbitrary recursion via a heap state-struct.")
    end
  end

  # Recursively walk an AST subtree collecting every AST::FuncCall whose
  # name matches `fn_name`. Args are also visited (so nested self-calls
  # inside outer-call arguments are found and flagged).
  sig { params(node: T.untyped, fn_name: String, out: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def collect_self_calls(node, fn_name, out = [])
    return out if node.nil?
    case node
    when Array
      node.each { |n| collect_self_calls(n, fn_name, out) }
    when AST::FuncCall
      out << node if node.name == fn_name
      node.args.each { |a| collect_self_calls(a, fn_name, out) }
    else
      node.each_pair { |_, v| collect_self_calls(v, fn_name, out) } if node.respond_to?(:each_pair)
    end
    out
  end

  # Recursively walk an AST subtree collecting every AST::ReturnNode.
  sig { params(node: T.untyped, out: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def collect_returns(node, out = [])
    return out if node.nil?
    case node
    when Array
      node.each { |n| collect_returns(n, out) }
    when AST::ReturnNode
      out << node
      collect_returns(node.value, out) if node.value
    else
      node.each_pair { |_, v| collect_returns(v, out) } if node.respond_to?(:each_pair)
    end
    out
  end

  sig { params(node: T.untyped, fn_name: T.untyped).returns(T::Boolean) }
  def contains_self_call?(node, fn_name)
    return false unless node
    return true if node.is_a?(AST::FuncCall) && node.name == fn_name
    if node.respond_to?(:each_pair)
      node.each_pair { |_, v| return true if contains_self_call?(v, fn_name) }
    end
    false
  end

  # ── Fiber Stack Auto-Sizing ──────────────────────────────────────
  # Walk the AST to find BG/DO blocks and assign computed stack tiers
  # based on the functions they call (transitively via call graph).

  sig { params(program_node: AST::Program).returns(T.nilable(T::Array[T.untyped])) }
  def assign_fiber_stack_tiers!(program_node)
    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::BgBlock
        calls = T.let(scan_for_calls(n.body).first, T::Set[T.untyped])
        raw = T.let(max_tier_for_calls(calls), Symbol)
        n.computed_stack_tier = (raw == :unbounded) ? :service : raw
        validate_fiber_stack!(n, calls, n.stack_size, n.can_smash)
        n.body.each { |s| traverse.call(s) }
      when AST::BgStreamBlock
        calls = scan_for_calls(n.body).first
        raw = T.let(max_tier_for_calls(calls), Symbol)
        n.computed_stack_tier = (raw == :unbounded) ? :service : raw
        validate_fiber_stack!(n, calls, n.stack_size, false)
        n.body.each { |s| traverse.call(s) }
      when AST::DoBlock
        n.branches.each do |branch|
          calls = scan_for_calls(branch[:body]).first
          raw = T.let(max_tier_for_calls(calls), Symbol)
          branch[:computed_stack_tier] = (raw == :unbounded) ? :service : raw
          validate_fiber_stack!(n, calls, branch[:stack_size], branch[:can_smash])
          branch[:body].each { |s| traverse.call(s) }
        end
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(program_node.statements)
  end

  # Plain `EFFECTS REENTRANT` callees require explicit `@service` on the
  # spawn site so OS-thread cost is an explicit user choice.
  sig { params(node: T.untyped, call_names: T::Set[String], user_size: T.nilable(Symbol), can_smash: T::Boolean).void }
  def validate_fiber_stack!(node, call_names, user_size, can_smash)
    if can_smash
      emit_can_smash_unsupported_error!(node)
      return
    end

    plain_reentrant_callee = find_plain_reentrant_callee(call_names)
    if plain_reentrant_callee && user_size != :service
      emit_service_required_error!(node, plain_reentrant_callee, user_size)
      return
    end

    raw = max_tier_for_calls(call_names)
    # Bounded variants no longer hit :unbounded; only mutual-MAX_DEPTH
    # falls back to :unbounded here (via compute_stack_tiers!), which
    # also requires @service via the plain_reentrant_callee path? No --
    # mutual MAX_DEPTH callees aren't `:reentrant` plain. They land in
    # the :unbounded case below; without @service we error too.
    computed = (raw == :unbounded) ? :service : raw

    if raw == :unbounded && user_size != :service
      mutual_md_callee = find_mutual_max_depth_callee(call_names)
      if mutual_md_callee
        error!(node, :STACK_SAFETY_MUTUAL_RECURSION, callee: mutual_md_callee, hint: "which is `:MAX_DEPTH(N)` AND mutually recursive. Mutual depth-bounds " \
               "compose as a product across counters and can't be statically bounded; " \
               "the spawn site must be `@service` (OS thread). Either declare `@service` " \
               "explicitly or break the cycle (see `:THUNK` for unbounded-depth fibers).")
        return
      end
    end

    if user_size == :stack
      loc = node.respond_to?(:line) ? " (line #{node.line})" : ""
      $stderr.puts "\e[33m[Warning]\e[0m Stack sizing: @stack resolved to @#{computed}; " \
                   "replace @stack with @#{computed}. In STRICT mode, @stack will be rejected.#{loc}"
      return
    end

    # User-specified size too small
    if user_size && TIER_ORDER.fetch(user_size, 0) < TIER_ORDER.fetch(computed, 0)
      error!(node, :STACK_SAFETY_USER_SIZE_TOO_SMALL, size: user_size, budget: EffectTracker::STACK_TIER_BUDGET[user_size], hint: "is too small for this fiber. Call-graph analysis requires at least @#{computed}. " \
             "Use @#{computed} (or @service for OS-thread). " \
             "(`@canSmash` is reserved for v0.3 -- runtime stack-hysteresis is implemented " \
             "but not yet wired through the compiler.)")
    end
  end

  # Walk the call graph from the BG body and return the name of the
  # first callee whose `reentrance_kind == :reentrant` (plain). Other
  # variants (:thunk, :tail_call, :not_logical, :max_depth) are
  # bounded and don't trigger the @service-required rule.
  sig { params(call_names: T::Set[String]).returns(T.nilable(String)) }
  def find_plain_reentrant_callee(call_names)
    visited = Set.new
    queue = T.let(call_names.to_a.dup, T::Array[String])
    until queue.empty?
      name = T.must(queue.shift)
      next if visited.include?(name)
      visited << name
      fn = @fn_nodes[name]
      return name if fn && fn.reentrance_kind == :reentrant
      (function_call_graph[name] || []).each { |c| queue << c }
    end
    nil
  end

  # Walk the call graph and return the first callee that has
  # `:reentrant_max_depth` AND is in a non-trivial SCC (mutually
  # recursive). Such fns force the spawn site to :service via
  # compute_stack_tiers!'s :unbounded fallback.
  sig { params(call_names: T::Set[T.untyped]).returns(T.untyped) }
  def find_mutual_max_depth_callee(call_names)
    visited = Set.new
    queue = T.let(call_names.to_a.dup, T::Array[String])
    until queue.empty?
      name = T.must(queue.shift)
      next if visited.include?(name)
      visited << name
      fn = @fn_nodes[name]
      return name if fn && fn.reentrance_kind == :reentrant_max_depth && mutually_recursive_in_call_graph?(name)
      (function_call_graph[name] || []).each { |c| queue << c }
    end
    nil
  end

  # Emit @service-required as a fixable when the spawn-site span is known;
  # DO branches fall back to a plain error because their span is ambiguous.
  sig { params(node: T.untyped, reentrant_fn: String, user_size: T.nilable(Symbol)).void }
  def emit_service_required_error!(node, reentrant_fn, user_size)
    msg = "Stack safety: this fiber transitively calls '#{reentrant_fn}' which is " \
          "`EFFECTS REENTRANT` (plain) -- the call chain is unbounded and MUST run on " \
          "an OS thread. Declare `@service` explicitly on the spawn site (the compiler " \
          "no longer auto-infers this). Alternatively, change '#{reentrant_fn}' to a " \
          "bounded reentrance variant: `:THUNK` (heap CPS, depth=1 fiber stack), " \
          "`:TAIL_CALL` (TCO loop, depth=1), `:NOT_LOGICAL` (asserts non-recursion), " \
          "or `:MAX_DEPTH(N)` (bounded counter)."

    fixes = []
    if node.respond_to?(:prefix_token) && node.prefix_token
      tok = node.prefix_token
      fixes << Fix.new(
        description: "Replace `@#{user_size}` with `@service` (this fiber transitively calls a plain :reentrant fn).",
        confidence: :interactive,
        edits: [Edit.new(
          span: Span.new(file: nil, line: tok.line, col: tok.column, length: tok.value.to_s.length),
          replacement: "@service",
        )],
      )
    elsif node.respond_to?(:open_brace_token) && node.open_brace_token
      tok = node.open_brace_token
      fixes << Fix.new(
        description: "Insert `@service ->` after `{` (this fiber transitively calls a plain :reentrant fn).",
        confidence: :interactive,
        edits: [Edit.new(
          span: Span.new(file: nil, line: tok.line, col: tok.column + 1, length: 0),
          replacement: " @service ->",
        )],
      )
    end

    return error!(node, :STACK_NEEDS_SERVICE_FIXABLE, message: msg) if fixes.empty?

    fixable!(node, message: msg, category: :reentrance, level: :error,
             fixes: fixes, raise_in_collector: false)
  end

  # Find the first :unbounded callee in the call chain (for error messages).
  sig { params(call_names: T::Set[String]).returns(T.nilable(String)) }
  def find_unbounded_callee(call_names)
    visited = T.let(Set.new, T::Set[String])
    queue = T.let(call_names.to_a.dup, T::Array[String])
    until queue.empty?
      name = T.must(queue.shift)
      next if visited.include?(name)
      visited << name
      return name if @fn_nodes[name]&.stack_tier == :unbounded
      (function_call_graph[name] || []).each { |c| queue << c }
    end
    nil
  end

  sig { params(from: String, to: String, at_token: T.nilable(Lexer::Token), action: Symbol).returns(T.nilable(T::Set[T.untyped])) }
  def og_move(from, to, at_token: nil, action: :move) = @og.transfer(from, to, at_token: at_token, action: action)
  sig { params(name: String, at_token: T.nilable(Lexer::Token), action: Symbol, consumer_param_type: T.untyped).returns(T.nilable(T::Set[T.untyped])) }
  def og_set_moved(name, at_token: nil, action: :move, consumer_param_type: nil) = @og.mark_moved(name, at_token: at_token, action: action, consumer_param_type: consumer_param_type)
  sig { params(name: T.untyped).returns(T.nilable(Symbol)) }
  def og_set_live(name)  = (@og[name]&.state = :live)
  sig { params(name: String).returns(T::Array[String]) }
  def og_drop(name)      = @og.drop(name)
  sig { returns(Integer) }
  def og_push_scope
    @og.clear_completed_snapshot! if @og_scope_depth.zero?
    @og_scope_depth += 1
  end
  sig { params(archive: T::Boolean).returns(Integer) }
  def og_pop_scope(archive: false)
    @og.prune_scope!(@og_scope_depth, archive: archive)
    @og_scope_depth -= 1
  end

end
