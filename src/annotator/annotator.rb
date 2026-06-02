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

  sig { returns(T.untyped) }
  def current_fn_ctx
    @function_context_stack.last
  end

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
      current_fn_ctx.conditional_depth += 1
      begin
        blk.call
      ensure
        current_fn_ctx.conditional_depth -= 1
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
    @function_context_stack = T.let([], T::Array[T.untyped]) # Stack of expected return types
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
    @capability_audit = T.let({}, T::Hash[T.untyped, T.untyped])
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

  # Replay deferred WITH-on-param checks after caller-sync propagation has
  # had a chance to populate entry.sync.
  sig { returns(T::Array[Annotator::Phases::DeferredWithValidation]) }
  def flush_deferred_with_validations!
    @deferred_with_validations.each do |d|
      var_node = d.var_node
      syn = var_node.symbol&.sync
      case d.capability
      when :EXCLUSIVE
        next if syn
        storage = var_node.symbol&.storage
        error!(d.node, :WITH_EXCLUSIVE_NEEDS_LOCK_GOT, got: storage || 'unknown')
      when :write_locked_read
        next if syn == :write_locked
        error!(d.node, :WITH_READ_NEEDS_WRITE_LOCK_NAME, name: cap_var_label(var_node))
      when :ATOMIC
        next if syn == :atomic
        name = cap_var_label(var_node)
        storage = var_node.symbol&.storage
        actual = syn ? "@#{syn}" : (storage ? "@#{storage}" : "plain")
        error!(d.node, :WITH_ATOMIC_NEEDS_SHARED_ATOMIC, name: name, actual: actual)
      end
    end
    @deferred_with_validations.clear
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
    @function_context_stack.push(FunctionContext.new(
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
    current_fn_ctx.uses_rt = true if has_fnptr && current_fn_ctx

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
    ctx = current_fn_ctx
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
      current_fn_ctx.uses_rt = true
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


    @function_context_stack.pop
  end

  # Pre-pass: walk every RAISE and OR EXIT site that provides both a
  # kind and a type, and seed the registry with (kind, type). Lets
  # CATCH Type clauses resolve regardless of source order. OR EXIT
  # counts too because it can introduce new types that only the
  # CATCH for a particular call needs to see.
  sig { params(program_node: AST::Program).returns(T.nilable(T::Array[T.untyped])) }
  def seed_error_types_from_raises!(program_node)
    seed_body = lambda do |stmts|
      AST.walk_body(stmts) do |n|
        case n
        when AST::Raise
          next unless n.kind && n.error_name
          resolve_error_registration!(n, n.kind, n.error_name, n.token)
        when AST::OrExit
          next unless n.kind && n.error_name
          resolve_error_registration!(n, n.kind, n.error_name, n.token)
        end
      end
    end
    program_node.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      seed_body.call(stmt.body)
      seed_body.call(stmt.catch_clauses&.map { |c| c.body }&.flatten || [])
    end
  end

  # Deadlock and LockCycle are deliberately absent because they must be
  # handled at the WITH site, never via a default policy.
  SYNC_POLICY_REQUIRED_ERRORS = %i[LockTimeout MvccConflict AtomicConflict].freeze
  # Errors that may NEVER appear in a SYNC POLICY block.
  SYNC_POLICY_INLINE_ONLY_ERRORS = %i[Deadlock LockCycle].freeze
  # The baked-in default applied when the user writes no SYNC POLICY.
  # Synthesized as a hash matching the parser's lock_error_clause
  # shape so the resolver can use it interchangeably.
  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def baked_in_default_sync_policy
    [
      { selectors: [{ form: :type, name: :LockTimeout, token: nil }],
        retries: 3, action: :raise, token: nil },
      { selectors: [{ form: :type, name: :MvccConflict, token: nil }],
        retries: nil, action: :raise, token: nil },
      { selectors: [{ form: :type, name: :AtomicConflict, token: nil }],
        retries: nil, action: :raise, token: nil },
    ]
  end

  # Walk the program statements; reject more than one SyncPolicyDecl,
  # require an `FN main` when one is present, validate the body, and
  # stamp `program_node.sync_policy` with the resolved handlers (the
  # user's if present, else the baked-in default).
  sig { params(program_node: AST::Program).returns(T.nilable(T::Array[T::Hash[T.untyped, T.untyped]])) }
  def validate_and_resolve_sync_policy!(program_node)
    decls = program_node.statements.select { |s| s.is_a?(AST::SyncPolicyDecl) }

    if decls.size > 1
      error!(decls[1], :SYNC_POLICY_DUPLICATE)
    end

    if decls.empty?
      program_node.sync_policy = baked_in_default_sync_policy
      return
    end

    decl = decls.first
    has_main = program_node.statements.any? { |s|
      s.is_a?(AST::FunctionDef) && s.name == "main"
    }
    unless has_main
      error!(decl, :SYNC_POLICY_NEEDS_MAIN_FILE)
    end

    validate_sync_policy_body!(decl)
    program_node.sync_policy = decl.handlers
  end

  # Per-handler-block validation: every selector must name a type the
  # SYNC POLICY is allowed to handle (LockTimeout, MvccConflict,
  # AtomicConflict); Deadlock / LockCycle are explicitly forbidden;
  # the union of named errors must cover the required set exactly.
  sig { params(decl: AST::SyncPolicyDecl).void }
  def validate_sync_policy_body!(decl)
    seen = []
    (decl.handlers || []).each do |clause|
      (clause[:selectors] || []).each do |sel|
        next unless sel[:form] == :type
        name = sel[:name]
        if SYNC_POLICY_INLINE_ONLY_ERRORS.include?(name)
          error!(sel[:token] || decl, :SYNC_POLICY_INLINE_ONLY,
            name: name, escape: (name == :Deadlock ? "DEADLOCK" : "LOCK_CYCLE"))
        end
        unless SYNC_POLICY_REQUIRED_ERRORS.include?(name)
          error!(sel[:token] || decl, :SYNC_POLICY_INVALID_ERROR,
            name: name, required: SYNC_POLICY_REQUIRED_ERRORS.join(', '))
        end
        seen << name
      end
      # Kind selectors (e.g. `ON Transient ...`) inside SYNC POLICY are
      # not supported -- the policy must name each error explicitly so
      # completeness is checkable. Sugar like `RETRY(N) THEN <action>`
      # desugars to `ON Transient ...` at parse time, which would land
      # here with form==:kind.
      (clause[:selectors] || []).each do |sel|
        next unless sel[:form] == :kind
        error!(sel[:token] || decl, :SYNC_POLICY_NEEDS_TYPE_NOT_KIND, name: sel[:name])
      end
    end

    seen_set = seen.to_set
    missing = SYNC_POLICY_REQUIRED_ERRORS.reject { |e| seen_set.include?(e) }
    unless missing.empty?
      error!(decl, :SYNC_POLICY_INCOMPLETE,
        required: SYNC_POLICY_REQUIRED_ERRORS.join(', '), missing: missing.join(', '))
    end
  end

  # Project a callee's full !T error union down to only the errors this
  # call site can surface. Forwarded polymorphic args keep the caller's
  # narrower family constraint instead of widening to the callee's full
  # REQUIRES set.
  sig { params(sig: FunctionSignature, args: T::Array[T.untyped]).returns(T::Set[Symbol]) }
  def collapse_errors_for_call(sig, args)
    require_relative 'helpers/with_match_check' unless defined?(WithMatchCheck)
    collapsed = Set.new
    sig.requires.each do |param_name, _families|
      idx = sig.params.find_index { |p| p.name.to_s == param_name }
      next unless idx
      arg = args[idx]
      next unless arg
      families = WithMatchCheck.family_of_arg_set(arg)
      next if families.nil? || families.empty?
      families.each do |fam|
        axes = WithMatchCheck::FAMILY_AXES[fam] || Set.new
        axes.each do |axis|
          (WithMatchCheck::AXIS_ERRORS[axis] || Set.new).each { |e| collapsed << e }
        end
      end
    end
    collapsed
  end

  # Synthesize the same clause shape as a per-WITH handler so emission can
  # use one path. Inline-only errors intentionally have no policy fallback.
  sig { params(error_name: Symbol).returns(T.untyped) }
  def synthesize_clause_from_policy(error_name)
    handlers = @program&.sync_policy
    return nil unless handlers
    handlers.find { |h|
      (h[:selectors] || []).any? { |s|
        s[:form] == :type && s[:name] == error_name
      }
    }
  end

  # SyncPolicyDecl is validated up front. This visitor keeps the AST walker
  # explicit and visits block-action handler bodies so their types are annotated.
  sig { params(node: AST::SyncPolicyDecl).returns(T::Array[T.untyped]) }
  def visit_SyncPolicyDecl(node)
    (node.handlers || []).each do |clause|
      case clause[:action]
      when :exit
        visit(clause.fetch(:message))
      when :block
        visit_stmts(clause.fetch(:body))
      end
    end
  end

  # Resolve a parsed CATCH clause into its runtime-dispatch form.
  # The parser produces:
  #   { items:   [{ form: :kind|:type, name:, token: }, ...],
  #     filters: [{ form: :type|:message, value:, token: }, ...],
  #     body:    [...] }
  # After this method, the clause carries four lowering-ready fields:
  #   clause[:kinds]            = [Symbol, ...] — kinds from items
  #   clause[:types]            = [String, ...] — types from items
  #   clause[:filter_types]     = [String, ...] — types from WITH
  #   clause[:filter_messages]  = [AST node, ...] — messages from WITH
  # Match semantics: (any kind matches OR any type matches) AND
  #   (filters empty OR any filter_type matches OR any filter_message
  #    matches). No cross-constraint between items and filters — a
  #   mixed `CATCH Kind, Type` simply ORs the two checks.
  sig { params(clause: AST::CatchClause).void }
  def resolve_catch_clause!(clause)
    kinds = []
    types = []
    clause.items.each do |item|
      if item.form == :kind
        kind_sym = item.name.to_sym
        unless AST.error_kind?(kind_sym)
          emit_registry_mismatch!(
            item.token, item.name, AST::ERROR_KINDS,
            "Unknown error kind '#{item.name}'. Expected one of: #{AST::ERROR_KINDS.join(', ')}",
            "closest known kind"
          )
        end
        kinds << kind_sym if AST.error_kind?(kind_sym)
      else
        type_sym = item.name.to_sym
        unless AST.error_type?(type_sym)
          emit_registry_mismatch!(
            item.token, item.name, AST::ERROR_TYPES.keys,
            "CATCH #{item.name}: error type '#{item.name}' is not registered. A type " \
            "must be registered via RAISE/OR EXIT before it can be CATCHed.",
            "closest registered type"
          )
        end
        types << item.name if AST.error_type?(type_sym)
      end
    end
    clause.kinds = kinds.uniq
    clause.types = types.uniq

    filter_types    = []
    filter_messages = []
    clause.filters.each do |f|
      case f.form
      when :type
        type_sym = T.cast(f.value, String).to_sym
        unless AST.error_type?(type_sym)
          error!(f.token, :CATCH_WITH_UNREGISTERED, name: f.value)
        end
        filter_types << T.cast(f.value, String)
      when :message
        # value is the parsed STRING expression. Visit so the string
        # literal gets its Type stamped for downstream lowering.
        visit(f.value)
        filter_messages << T.cast(f.value, AST::Locatable)
      end
    end
    clause.filter_types    = filter_types.uniq
    clause.filter_messages = filter_messages
  end

  # Collect input types from pipeline |> steps that can fail.
  sig { params(body: T::Array[T.untyped], types: T::Set[T.untyped]).returns(T::Array[T.untyped]) }
  def collect_pipe_input_types(body, types)
    body.each do |stmt|
      AST.each_locatable(stmt) do |node|
        if node.is_a?(AST::BinaryOp) && node.op == :SMOOTH
          t = node.left.full_type!(context: "pipe input type")
          types << t.resolved.to_s unless t.void? || t.error_union?
        end
      end
    end
  end

  sig { params(bodies: T::Array[T.untyped]).returns(T::Boolean) }
  def catch_bodies_reference_snapshot?(bodies)
    bodies.compact.any? do |body|
      found = T.let(false, T::Boolean)
      AST.each_locatable(body) do |node|
        found = true if node.is_a?(AST::Identifier) && node.name == "snapshot"
      end
      found
    end
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


  # ==========================================
  # CONTROL FLOW
  # ==========================================
  # Unifies logic for analyzing multiple code paths (branches).
  # Snapshots initial variable states, executes each branch in a clean scope,
  # and merges states back to the parent scope.
  #
  # @param branches [Array<Proc>] Procs that execute branch logic
  # @return [Array<Array<Hash>>] Array of drops for each branch
  sig { params(node: AST::Assert).returns(T.nilable(Symbol)) }
  def visit_Assert(node)
    visit(node.condition)
    if node.condition.resolved_type != :Bool
       error!(node, :ASSERT_NEEDS_BOOL)
    end
    # Optional: check message type if it exists
    stamp_type!(node, :Void)
  end

  # Test-grammar visitors (visit_TestBlock, visit_WhenBlock,
  # visit_TestThat, visit_AssertRaises, visit_BenchmarkStmt,
  # visit_SmashStmt, visit_ProfileStmt, visit_StubDecl) are mixed in
  # from annotator/helpers/test_annotation.rb.

  sig { params(node: AST::DieNode).returns(Symbol) }
  def visit_DieNode(node)
     # Usually takes an integer status code
     visit(node.status) if node.status
     stamp_type!(node, :NoReturn) # Special type indicating execution stops
  end

  sig { params(node: AST::Raise).returns(T.nilable(T::Boolean)) }
  def visit_Raise(node)
    visit(node.message_expr) if node.message_expr
    resolve_error_registration!(node, node.kind, node.error_name, node.token)
    current_fn_ctx.uses_rt = true if current_fn_ctx
    stamp_type!(node, :NoReturn) # Raises propagate up or are caught
    @branch_terminated = true
  end

  # Unified registration for RAISE / OR EXIT / EXIT sites that name an
  # error type. Rules:
  #   - kind given + type given  : register or verify (kind, type).
  #   - kind nil   + type given  : type MUST already be registered;
  #                                node.kind is backfilled to the
  #                                registered kind.
  #   - kind given + type nil    : no-op (no type to register).
  #   - kind nil   + type nil    : no-op (legacy message-only form).
  # On collision, emits a diagnostic anchored at the second site,
  # naming the first registration line for context.
  sig { params(node: T.untyped, kind_sym: T.nilable(Symbol), type_name_str: T.nilable(String), site_tok: Lexer::Token).returns(NilClass) }
  def resolve_error_registration!(node, kind_sym, type_name_str, site_tok)
    return if type_name_str.nil?
    type_sym = type_name_str.to_sym

    if kind_sym.nil?
      # Type-only form — require prior registration.
      unless AST.error_type?(type_sym)
        error!(site_tok || node, :ERROR_TYPE_NOT_REGISTERED, name: type_name_str)
        return
      end
      # Backfill the node with the registered kind so downstream
      # passes (mir-lowering) can emit rt.setError(.Kind, ...).
      node.kind = AST.kind_of_type(type_sym)
      return
    end

    # Kind + type: first use registers, subsequent verifies.
    _, conflict = AST.register_type!(type_sym, kind_sym, site_token: site_tok)
    return unless conflict
    first_site = conflict[:first_site]
    first_loc  = first_site ? " (first registered at line #{first_site.line})" : ""
    if conflict[:is_stdlib]
      error!(site_tok || node, :ERROR_TYPE_RESERVED_BY_STDLIB,
             name: type_name_str, kind: conflict[:existing_kind])
    else
      error!(site_tok || node, :ERROR_TYPE_KIND_CONFLICT,
             name: type_name_str, kind: conflict[:existing_kind], first_loc: first_loc)
    end
  end

  # ==========================================
  # VARIABLES & DEPENDENCIES
  # ==========================================

  sig { params(node: AST::ReturnNode).returns(T.nilable(T::Boolean)) }
  def visit_ReturnNode(node)
    # Handle optional return node for Void functions.
    expected = current_fn_ctx.return_type
    if node.value.nil?
      # If the function expects a value but we return nothing -> ERROR.
      # `!Void` (error union over Void) accepts a plain `RETURN;` because
      # the success arm is Void; the wrap is implicit at lowering time.
      expected_void_compatible = expected == :Void || expected == :Any ||
                                 (expected.respond_to?(:error_union?) && expected.error_union? &&
                                  expected.respond_to?(:payload_type) &&
                                  (expected.payload_type == :Void || expected.payload_type.nil?))
      unless expected_void_compatible
        error!(node, :RETURN_VOID_FROM_TYPED, expected: expected)
      end

      stamp_type!(node, :Void)
      @branch_terminated = true
      return # Stop here, nothing else to analyze
    end

    visit(node.value)

    # Inline BG return: `RETURN BG { ... }`, plus composite returns such
    # as `RETURN Holder{ bg: BG { ... } }`. There is no decl_node for
    # `stamp_bg_handle_lifetime!` to fire on, so run the same source walk
    # inline. If any contained BG captures a scope-bounded source, the
    # returned value cannot outlive those captures.
    inline_bg_sources = collect_bg_sources_in_expr(node.value).uniq
    if inline_bg_sources.any?
      source_names = inline_bg_sources.map { |s| lookup_source_name(s) || "(unnamed)" }.uniq.join(", ")
      error!(node, :RETURN_BORROWED_NO_COPY_OR_LIFETIME,
             type: node.value.full_type!(context: "inline BG return").to_s,
             hint: "BG handle captures '#{source_names}' (declared in this function's scope) — the handle cannot outlive its captures. Restructure so the captures are owned by the caller, or use COPY-eligible payloads.")
    end

    # RETURN inside a WITH block is forbidden ONLY when the returned value
    # carries a borrow of the WITH alias (the `AS` binding). Pure values
    # — primitives, fresh values returned by methods on the alias (e.g.
    # `p.insert(...)` returning a fresh Id<T>) — escape safely. The
    # SymbolEntry#non_escaping flag is set on every WITH alias by
    # declare_capability_scope!; it's the same flag ensure_owned_value!
    # already uses to prevent storing WITH-scoped values in containers.
    if (@with_block_depth || 0) > 0
      val = node.value
      if val.is_a?(AST::Identifier) && val.symbol&.non_escaping
        error!(node, :RETURN_FROM_WITH_SCOPED, name: val.name, hint: "WITH aliases are borrows of locked data and cannot escape their scope.")
      elsif val.is_a?(AST::GetField) && val.target.respond_to?(:symbol) && val.target.symbol&.non_escaping
        error!(node, :RETURN_FIELD_FROM_WITH_SCOPED, hint: "Field access borrows from the locked data; the borrow cannot escape the WITH scope.")
      elsif val.is_a?(AST::GetIndex) && val.target.respond_to?(:symbol) && val.target.symbol&.non_escaping
        error!(node, :RETURN_INDEX_FROM_WITH_SCOPED, hint: "Index access borrows from the locked data; the borrow cannot escape the WITH scope.")
      end
    end
    promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
    promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)

    verify_return(node.value)
    verify_tied_return!(node)

    actual = node.value.resolved_type
    actual_full = return_value_type(node.value)
    expected = current_fn_ctx.return_type

    if node.value.is_a?(AST::Identifier)
      vti = node.value.full_type!(context: "return identifier")
      if vti && !vti.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
        node.value.was_moved = true
      end
      # Returning a future consumes the promise; otherwise scope finalization
      # reports it as unconsumed before return-lifetime checks can run.
      vt = vti.is_a?(Type) ? vti : (vti ? Type.new(vti) : nil)
      if vt&.future?
        og_set_moved(node.value.name, at_token: node.value.token, action: :return)
      end
    end

    # RETURN COPY expr or RETURN Struct{ field: COPY ... }: the COPY heap-dupes,
    # so the caller receives heap-allocated data.

    # Promote non-identifier literals to heap when the expected return type requires it.
    unless node.value.is_a?(AST::Identifier)
      if expected.heap_return_storage? &&
         node.value.respond_to?(:storage=) &&
         node.value.full_type!(context: "return expression storage").requires_move?
        node.value.storage = :heap
      end
    end

    # Auto returns are resolved after the body walk, so strict equality here
    # would reject valid programs before the unifier has run.
    actual_is_auto = actual_full.auto?
    expected_is_auto = expected.auto?

    return_checkable = !actual_is_auto && !expected_is_auto && expected != :Void && expected != :Any
    if return_checkable && !return_type_compatible?(actual_full, expected)
      error!(node, :RETURN_MISMATCH, expected: type_display(expected), got: type_display(actual_full))
    elsif return_checkable && actual != expected
      # A value's coercion target is the PAYLOAD, never the error union
      # `!T`. `!` is the channel (added by the return mechanism / fn
      # signature), orthogonal to the value's type. Stamping `!T` here
      # makes lower() emit `@as(anyerror!T, value)`, whose address
      # (`&__tmp`) is `*const anyerror!T` and fails the @list
      # cleanup/return cast (puck-clear-bugs.md #10). A genuinely
      # fallible value (auto-propagate-stripped call: `!T` stashed on
      # error_union_type) keeps the channel target so return-lowering
      # still emits the propagating `try`. Caller-side cleanup of the
      # returned collection is handled by the uniform alloc-fault
      # pipeline (steps 3-4), so unlike the earlier standalone attempt
      # this no longer leaks (#13) and does not need E1 broadening
      # (no 527 double-free). (`expected` is always a Type on master --
      # the FunctionSignature seam coerces nil -> Void.)
      value_is_fallible =
        (node.value.respond_to?(:error_union_type) && node.value.error_union_type) ||
        actual_full.error_union?
      coerce_target =
        if !value_is_fallible && expected.plain_return_payload_type
          expected.plain_return_payload_type
        else
          expected
        end
      node.value.coerced_type = coerce_target  # Don't coerce EXPLICIT returns
      check_prefixed_int_range!(node.value, coerce_target)
    end

    stamp_type!(node, actual)

    current_fn_ctx.returns << {storage: node.value.storage, type: actual, metatype: node.value.metatype}

    @branch_terminated = true
  end

  sig { params(value: AST::Locatable).returns(Type) }
  def return_value_type(value)
    value.full_type!(context: "return value")
  end

  sig { params(actual_type: Type, expected_type: Type).returns(T::Boolean) }
  def return_type_compatible?(actual_type, expected_type)
    expected_t = expected_type.is_a?(Type) ? expected_type : Type.new(expected_type)
    actual_t = actual_type.is_a?(Type) ? actual_type : Type.new(actual_type)

    return true if expected_t.any? || actual_t.any?
    return expected_t.accepts?(actual_t) if expected_t.fn_type?
    return false unless same_return_capabilities?(expected_t, actual_t)

    is_safe_autocast?(actual_t, expected_t)
  end

  sig { params(expected_t: Type, actual_t: Type).returns(T::Boolean) }
  def same_return_capabilities?(expected_t, actual_t)
    name = expected_t.resolved.to_s
    if name.match?(/\A[A-Z]\z/) && !lookup_type_schema(name.to_sym) &&
       expected_t.polymorphic_shared? && actual_t.shared? &&
       expected_t.sync.nil? && expected_t.resolved == actual_t.resolved
      return true
    end
    # @indirect on a return type is a storage directive: the value is
    # heap-boxed into a `*T` cell at the RETURN site (escape analysis),
    # so the returned expression need not already carry :indirect.
    layout_ok = expected_t.layout == actual_t.layout || expected_t.indirect?
    expected_t.ownership == actual_t.ownership &&
      expected_t.sync == actual_t.sync &&
      layout_ok &&
      expected_t.elem_ownership == actual_t.elem_ownership &&
      expected_t.elem_sync == actual_t.elem_sync
  end

  sig { params(type: Type).returns(String) }
  def type_display(type)
    t = type.is_a?(Type) ? type : Type.new(type)
    parts = [t.resolved.to_s]

    ownership = t.ownership_surface_name
    sync = t.sync_surface_name
    parts << ownership if ownership
    parts << sync if sync

    parts.join(" ")
  end

  sig { params(fn_node: AST::FunctionDef).returns(T::Array[String]) }
  def infer_implicit_type_params(fn_node)
    explicit = (fn_node.type_params || []).map(&:to_s)
    return explicit unless explicit.empty?
    inferred = []
    ([fn_node.return_type] + fn_node.params.map { |p| p.type }).each do |type|
      collect_implicit_type_params(type, inferred, explicit)
    end
    (explicit + inferred).uniq
  end

  sig { params(type: T.untyped, out: T::Array[String], explicit: T::Array[T.untyped]).returns(T.untyped) }
  def collect_implicit_type_params(type, out, explicit)
    return unless type.is_a?(Type)
    name = type.resolved.to_s
    if name.match?(/\A[A-Z]\z/) && !explicit.include?(name) && !lookup_type_schema(name.to_sym)
      out << name
    end
    if type.generic_instance?
      type.generic_args.each { |arg| collect_implicit_type_params(arg, out, explicit) }
    end
    collect_implicit_type_params(type.payload_type, out, explicit) if type.respond_to?(:error_union?) && type.error_union?
    collect_implicit_type_params(type.wrapped_type, out, explicit) if type.respond_to?(:optional?) && type.optional?
    collect_implicit_type_params(type.element_type, out, explicit) if type.respond_to?(:array?) && type.array?
  end

  # Loop-local SROA: when a large struct literal (storage == :frame) is declared
  # inside a loop body, downgrade it to :stack allocation.
  #
  # Rationale: the frame arena's save/restore mark is per-function, not per-iteration.
  # A :frame allocation inside a loop bumps the arena every iteration and never
  # reclaims it until function exit — burning O(N) memory for N iterations.
  # A Zig `var BigVec` on the OS stack is reclaimed automatically each iteration;
  # LLVM then SROAs the fields to registers and dead-code-eliminates unused ones.
  #
  # Safety: CLEAR uses value semantics for structs (pass/return by copy).  A large
  # struct on the stack cannot have its address escape the loop body through normal
  # CLEAR operations, so :stack is always safe here.
  sig { params(node: AST::Cast).returns(Symbol) }
  def visit_Cast(node)
    visit(node.value) # Resolve 'json' -> :HashMap

    # node.target is "Config".
    # In a strict language, we'd check if :HashMap can cast to Config.
    # For now, just trust the user and carry the type forward.
    stamp_type!(node, node.target.to_sym)
  end

  sig { params(node: AST::CallSiteOverride).void }
  def visit_CallSiteOverride(node)
    sigil = node.kind == :thunk ? "@thunk" : "@maxDepth"
    variant_hint = node.kind == :thunk ? "'EFFECTS REENTRANT:THUNK'" : "'EFFECTS REENTRANT:MAX_DEPTH(#{node.n})'"
    error!(node, :CALL_SITE_OVERRIDE_UNIMPLEMENTED,
      sigil: sigil, n: node.n, variant_hint: variant_hint)
  end

  sig { params(node: AST::UnaryOp).returns(T.untyped) }
  def visit_UnaryOp(node)
    visit(node.right)

    case node.op
    when :NOT, "!"
      stamp_type!(node, :Bool)
    when :SUB, "-"
      stamp_type!(node, node.right.full_type!(context: "unary right")) # Keep as Number/Int64
    else
      stamp_type!(node, node.right.full_type!(context: "unary right"))
    end
  end

  # ==========================================
  # LITERALS & BINARY OPS
  # ==========================================
  sig { params(node: AST::Literal).returns(T.untyped) }
  def visit_Literal(node)
    literal_type = case node.type
      when :NUMBER then Type.new(:Float64)
      when :INT64 then Type.new(:Int64)
      when :STRING
        # SIMP-13f: stamp storage_override so Locatable#rodata_provenance? returns
        # true without needing the type.provenance fallback.
        if node.storage == :stack
          node.storage = :rodata
          Type.new(:"Byte[#{node.value.length}]", location: :rodata)
        else
          node.storage = :rodata
          Type.new(Type::STRING_TYPE, location: :rodata)
        end
      when :SYMBOL
        # Symbol literals: compile-time interned, static lifetime, O(1) equality by pointer.
        node.storage = :rodata
        Type.new(Type::STRING_TYPE, sync: :symbol, location: :rodata)
      when :BYTE         then Type.new(:Byte)
      when :PREFIXED_INT then Type.new(:Byte)  # Default; overflows checked after coercion context is known
      when :INT8    then Type.new(:Int8)
      when :INT16   then Type.new(:Int16)
      when :INT32   then Type.new(:Int32)
      when :UINT16  then Type.new(:UInt16)
      when :UINT32  then Type.new(:UInt32)
      when :UINT64  then Type.new(:UInt64)
      when :FLOAT32 then Type.new(:Float32)
      when :BOOLEAN then Type.new(:Bool)
      when :NIL then Type.new(:NIL)
      else
        error!(node, :UNKNOWN_LITERAL)
      end
    stamp_type!(node, literal_type)
  end

  sig { params(node: AST::DefaultLit).returns(Symbol) }
  def visit_DefaultLit(node)
    # Resolved type is set by declare_and_verify_params / visit_StructLit context.
    # Standalone DEFAULT is not valid; callers validate the context.
    stamp_type!(node, :Any)
  end

  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def visit_BinaryOp(node)
    # Special operators that need custom handling
    case node.op
    when :SMOOTH then return visit_Smooth(node)
    when :BIND_VAR then return visit_BindVar(node)
    when :OR_RESCUE then return visit_OrRescue(node)
    end

    # Standard binary operations - visit children first
    visit(node.left)
    visit(node.right)

    # Delegate type resolution to Type class
    left_type = node.left.full_type!(context: "binary left")
    right_type = node.right.full_type!(context: "binary right")
    result = Type.binary_op(node.op, left_type, right_type)

    if result.error
      error!(node, :TYPE_ERROR_GENERIC, message: result.error)
    end

    stamp_type!(node, result.type)
    node.left.coerced_type = result.left_coercion if result.left_coercion
    node.right.coerced_type = result.right_coercion if result.right_coercion
    node.storage = result.storage if result.storage

    # String concat (+) transpiles to std.mem.concat(rt.frameAlloc(), ...) —
    # mark as frame allocation so needs_rt and loop mark elision are correct.
    if node.op == :ADD && (left_type.string? || right_type.string?)
      node.string_concat = true
      current_fn_ctx.frame_count += 1 if current_fn_ctx
      # String concat result is frame-allocated.
      node.storage = :frame
      ti = node.full_type!(context: "binary result")
      ti.mark_frame_allocated! if ti.is_a?(Type)
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(SymbolEntry)) }
  def visit_Placeholder(node)
    # Just resolve it like an identifier
    visit_Identifier(AST::Identifier.new(node.token, "_"))
  end

  # =========================================================
  # BIND VAR (AS / @)
  # =========================================================
  sig { params(node: AST::BinaryOp).returns(Type) }
  def visit_BindVar(node)
    # Logic: expression AS @name
    # The value flows through, but we declare a new variable in the scope.

    visit(node.left)
    lhs_type = node.left.full_type!(context: "bind left")

    # node.right is the Identifier for the new variable
    var_name = node.right.name

    # When binding a collection source (users AS $u), $u refers to each *element*,
    # not the collection. Subsequent $u.field accesses need the element type.
    # collection_value? covers declared collections plus plain non-string arrays.
    lhs_ti = Type.new(lhs_type)
    binding_type = if lhs_ti.collection_value? && lhs_ti.element_type
      lhs_ti.element_type.to_s
    else
      lhs_type
    end

    # Register in scope (Immutable, Stack storage)
    current_scope.declare(
      var_name,
      nil,
      binding_type,
      false, # Immutable
      false, # Not rebindable
      nil,
      :stack
    )

    # The bound identifier ($u) IS the per-element binding — type it
    # exactly as it was declared (binding_type), not a guess.
    stamp_type!(node.right, binding_type)

    # The result of the operation is the collection itself (passthrough for pipeline)
    stamp_type!(node, lhs_type)
  end

  # =========================================================
  # OR / RESCUE
  # =========================================================
  sig { params(node: AST::BinaryOp).returns(T.nilable(Symbol)) }
  def visit_OrRescue(node)
    # Logic: val OR default
    visit(node.left)
    visit(node.right)


    # If the LHS is a fallible call, the auto-propagate strip moved the
    # `!T` from `full_type` (which is now the success T) to
    # `error_union_type`. OR-RESCUE needs the original `!T` to decide
    # whether to emit `catch fallback` (error union) or `orelse fallback`
    # (optional). Prefer the saved union if present.
    t_left_type = if node.left.respond_to?(:error_union_type) && node.left.error_union_type
                    eu = node.left.error_union_type
                    eu.is_a?(Type) ? eu : Type.new(eu)
                  else
                    node.left.full_type!(context: "OR left")
                  end
    t_right_type = node.right.full_type!(context: "OR right")

    # Handle OR EXIT "msg": set error context + propagate (same as OR RAISE for types)
    if node.right.is_a?(AST::OrExit)
      if t_left_type.error_union?
        stamp_type!(node, t_left_type.payload_type.resolved)
      else
        stamp_type!(node, t_left_type.resolved)
      end
      return
    end

    # Handle OR RAISE: bubble up error (Zig's try)
    if node.right.is_a?(AST::OrRaise)
      if t_left_type.error_union?
        # Unwrap to payload type - error will be propagated
        stamp_type!(node, t_left_type.payload_type.resolved)
      else
        # OR RAISE on non-error type just passes through
        stamp_type!(node, t_left_type.resolved)
      end
      return
    end

    # Handle OR PASS: ignore error, use undefined/default
    if node.right.is_a?(AST::OrPass)
      if t_left_type.error_union?
        # Unwrap to payload type - error will be ignored
        stamp_type!(node, t_left_type.payload_type.resolved)
      else
        stamp_type!(node, t_left_type.resolved)
      end
      return
    end

    # Handle OR BREAK: error-to-break coercion (valid only inside loops)
    if node.right.is_a?(AST::OrBreak)
      if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
        error!(node, :OR_BREAK_OUTSIDE_WHILE)
      end
      if t_left_type.error_union?
        stamp_type!(node, t_left_type.payload_type.resolved)
      else
        stamp_type!(node, t_left_type.resolved)
      end
      return
    end

    # Handle OR PRUNE: discard error, skip item (used in CONCURRENT SELECT/WHERE)
    if node.right.is_a?(AST::OrPrune)
      if t_left_type.error_union?
        # Unwrap to payload type - error causes item to be skipped
        stamp_type!(node, t_left_type.payload_type.resolved)
      else
        stamp_type!(node, t_left_type.resolved)
      end
      return
    end

    # Handle error union types: !T OR default -> T
    if t_left_type.error_union?
      payload_type = t_left_type.payload_type

      # Type check: RHS must be compatible with payload type
      unless payload_type.accepts?(t_right_type) || t_right_type.accepts?(payload_type)
        error!(node, :TYPE_MISMATCH_IN_OR, expected: payload_type.resolved, got: t_right_type.resolved)
      end

      coerce_empty_collection_fallback!(node.right, payload_type)
      # Result is the payload type (error is handled)
      stamp_type!(node, payload_type.resolved)
      return
    end

    # Handle optional types: ?T OR default -> T
    if t_left_type.optional?
      wrapped = t_left_type.wrapped_type
      unless wrapped.accepts?(t_right_type) || t_right_type.accepts?(wrapped)
        error!(node, :TYPE_MISMATCH_IN_OR, expected: wrapped.resolved, got: t_right_type.resolved)
      end
      coerce_empty_collection_fallback!(node.right, wrapped)
      stamp_type!(node, wrapped.resolved)
      return
    end

    # Standard OR behavior
    if t_left_type.resolved == t_right_type.resolved
      stamp_type!(node, t_left_type.resolved)
    else
      stamp_type!(node, t_left_type.resolved)
    end
  end

  # An empty collection fallback (`expr OR []` / `OR {}`) is visited
  # with no expected-type context, so visit_ListLit types it `Any[]`
  # and the transpiler defaults its element type (f64). Push the OR
  # success type onto the empty literal -- the same expected-type
  # propagation VarDecl does for `MUTABLE v: T[]@list = []`.
  sig { params(rhs: T.untyped, expected: T.untyped).void }
  def coerce_empty_collection_fallback!(rhs, expected)
    return unless expected.is_a?(Type)
    empty_list = rhs.is_a?(AST::ListLit) && rhs.items.empty? &&
                 !rhs.instance_variable_get(:@constructor_collection)
    empty_hash = rhs.is_a?(AST::HashLit) && rhs.pairs.empty?
    return unless empty_list || empty_hash
    stamp_type!(rhs, expected)
  end

  sig { params(node: AST::OrRaise).returns(Symbol) }
  def visit_OrRaise(node)
    stamp_type!(node, :Void)
  end

  sig { params(node: AST::OrBreak).returns(Symbol) }
  def visit_OrBreak(node)
    stamp_type!(node, :Void)
  end

  sig { params(node: AST::OrPass).returns(Symbol) }
  def visit_OrPass(node)
    # This is a marker node for OR PASS - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    stamp_type!(node, :Void)
  end

  sig { params(node: AST::OrPrune).returns(Symbol) }
  def visit_OrPrune(node)
    # This is a marker node for OR PRUNE - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    stamp_type!(node, :Void)
  end

  sig { params(node: AST::OrExit).returns(T.nilable(Symbol)) }
  def visit_OrExit(node)
    visit(node.message) if node.message
    resolve_error_registration!(node, node.kind, node.error_name, node.token)
    current_fn_ctx.uses_rt = true if current_fn_ctx
    stamp_type!(node, :Void)
  end

  sig { params(node: AST::CapabilityWrap).returns(T.nilable(Type)) }
  def visit_CapabilityWrap(node)
    visit(node.value)

    base_type = node.value.resolved_type  # e.g. :Node
    ti = Type.new(base_type)

    # Primitive types (Int64, Number, Bool, Byte, Float64) cannot have capabilities.
    # Wrapping a primitive in @local/@locked/@shared creates a heap pointer to a
    # value you can't meaningfully dereference.  Wrap in a STRUCT instead.
    #
    # Exception: @shared:atomic IS the primitive-as-cell case — the whole point
    # of an atomic primitive is the bare-cell form (Int64@shared:atomic =
    # AtomicInt64). The annotator validates that @atomic is only applied to
    # types the runtime supports (Int64, Float64, Bool, sized variants); other
    # primitives error.
    is_atomic_primitive = node.atomic? && !node.indirect?

    # `@indirect:atomic` is the struct-as-AtomicPtr form. Reject it on
    # primitives before the generic primitive-capability error so the
    # diagnostic can name the right migration path.
    if ti.primitive? && node.atomic_ptr?
      error!(node, :INDIRECT_ATOMIC_PRIMITIVE, type: base_type)
    end

    if ti.primitive? && !is_atomic_primitive && node.capability?
      cap_name = node.sync || node.ownership || node.layout
      error!(node, :CAPABILITY_ON_PRIMITIVE, cap: cap_name, type: base_type, hint: "Wrap in a STRUCT (e.g. STRUCT Wrapper { value: #{base_type} }) and apply the capability to the struct.")
    end

    # Struct atomics need AtomicPtr snapshot semantics; direct atomic ops only
    # make sense for CAS-sized primitive cells.
    if !ti.primitive? && node.atomic? && !node.indirect?
      error!(node, :STRUCT_ATOMIC_NEEDS_INDIRECT, type: base_type)
    end

    # AtomicPtr is cross-thread by design; @local is pointless and
    # @multiowned's Rc backing is not thread-safe.
    if node.atomic_ptr?
      if node.ownership == :local
        error!(node, :LOCAL_INDIRECT_ATOMIC)
      elsif node.multiowned?
        error!(node, :MULTIOWNED_INDIRECT_ATOMIC)
      end
    end

    ti.apply_declared_type_capabilities!(
      ownership: node.ownership,
      sync: node.sync,
      lock_rank: node.lock_rank,
      layout: node.layout
    )
    # AtomicPtr implies shared ownership because escaping the declaring
    # scope is the point of the construct; local and multiowned cases were
    # rejected above.
    if node.atomic_ptr? && !node.ownership
      ti.apply_reference_ownership!(:shared)
    end
    # @indirect forces heap location (same as @local, but different intent).
    ti.pin_heap_for_indirect!       if node.indirect?

    # Lock ranks induce a total order only if every declaration of a type
    # uses the same rank.
    if node.lock_rank && node.locked_sync?
      record_lock_type_rank!(ti.base_type, node.lock_rank, node)
    end

    # CapabilityWrap always allocates on the heap.
    if node.ownership || node.sync || node.layout
      current_fn_ctx.heap_count += 1 if current_fn_ctx
      record_effect(EffectTracker::HEAP)
    end

    # Store the Type directly — full_type= accepts Type objects
    stamp_type!(node, ti)
  end

  sig { params(node: AST::MoveNode).returns(T.nilable(T::Set[T.untyped])) }
  def visit_MoveNode(node)
    record_capture_site!(node, copied: false)
    without_capture_moves { visit(node.value) }

    unless node.value.is_a?(AST::Identifier)
      error!(node, :MOVE_NEEDS_IDENTIFIER)
    end

    ti = node.value.full_type!(context: "MOVE value")
    
    # Check if the identifier is a resource
    is_resource = false
    if node.value.is_a?(AST::Identifier)
      info = node.value.symbol
      is_resource = info&.resource
    end

    is_copy = ti&.implicitly_copyable? { |t| lookup_type_schema(t) } rescue false
    unless ti&.multiowned? || ti&.shared? || ti&.requires_move? || is_resource || !is_copy
      error!(node, :GIVE_ON_COPY_TYPE, type: node.value.resolved_type)
    end

    # Inherit the capability type so the VarDecl or ReturnNode can infer storage correctly
    stamp_type!(node, node.value.full_type!(context: "MOVE result"))
    node.storage   = node.value.storage

    # Consume the source variable — it is affinely transferred. Downstream
    # MIR lowering uses was_moved as the single ownership-transfer signal.
    node.value.was_moved = true if node.value.respond_to?(:was_moved=)
    node.was_moved = true if node.respond_to?(:was_moved=)
    og_set_moved(node.value.name, at_token: node.value.token, action: :give)
  end

  # Ensure a value node is owned data suitable for storage in structs, unions,
  # and TAKES parameters. Returns a replacement CopyNode if wrapping is needed,
  # or nil if the value is already owned.
  #
  # Rules:
  # - @list (list_collection): wrap in CopyNode (frame buffer -> heap copy)
  # - Rodata string: wrap in CopyNode (auto-dupe to heap)
  # - Non-heap string expression: error (require explicit COPY)
  # - Already CopyNode: no-op
  #
  # +val_node+:      the AST value node being stored
  # +expected_type+: the target field/param type (Type or Symbol)
  # +container_desc+: string for error messages (e.g. "MyUnion.Variant")
  sig { params(val_node: T.untyped, expected_type: T.untyped, container_desc: T.nilable(String), container_alloc: Symbol).returns(T.nilable(AST::CopyNode)) }
  def ensure_owned_value!(val_node, expected_type, container_desc = nil, container_alloc: :heap)
    # Non-escaping values (WITH block aliases) cannot be stored in containers
    if val_node.is_a?(AST::Identifier) && val_node.symbol&.non_escaping
      error!(val_node, :STORE_WITH_SCOPED_INTO_CONTAINER, name: val_node.name, container: container_desc || 'a container')
    end
    return nil if val_node.is_a?(AST::CopyNode)
    vti = val_node.full_type!(context: "owned value source")
    vti = Type.new(vti) if vti && !vti.is_a?(Type)
    return nil unless vti

    if vti.list_collection?
      # When the target field is also @list (ArrayList), skip CopyNode wrapping.
      # The move mechanism will transfer the ArrayList struct directly.
      # CopyNode produces a slice which is the wrong type for ArrayList fields.
      et = expected_type.is_a?(Type) ? expected_type : nil
      return nil if et&.list_collection?

      copy = AST::CopyNode.new(val_node.token, val_node)
      stamp_type!(copy, expected_type.is_a?(Type) ? expected_type : Type.new(expected_type || :Any))
      copy.storage = container_alloc
      copy.alloc = container_alloc
      elem = vti.element_type
      if elem
        es = lookup_type_schema(elem.resolved) rescue nil
        copy.deep_copy = Schemas.union?(es) &&
          (es.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      end
      return copy
    end

    if vti.string? && vti.rodata?
      copy = AST::CopyNode.new(val_node.token, val_node)
      # Auto-COPY of rodata literal into a non-rodata container -- new
      # string lives in the container's allocator so the container has
      # uniform-provenance elements (no cleanupAlloc needed).
      stamp_type!(copy, Type.new(Type::STRING_TYPE, location: container_alloc))
      copy.storage = container_alloc
      copy.alloc = container_alloc
      return copy
    end

    if vti.string? && val_node.is_a?(AST::Identifier) && container_desc
      sym = val_node.symbol
      unless sym&.heap_storage?
        error!(val_node, :STORE_STRING_NEEDS_COPY, name: val_node.name, container: container_desc)
      end
    end

    nil
  end

  sig { params(node: AST::CopyNode).returns(T.nilable(T::Boolean)) }
  def visit_CopyNode(node)
    record_capture_site!(node, copied: true)
    without_capture_moves { visit(node.value) }
    # COPY produces an owned deep-copy. The source is NOT consumed.
    # Clone the Type so mutating provenance doesn't affect the inner node.
    inner_type = node.value.full_type!(context: "COPY value")
    stamp_type!(node, inner_type.is_a?(Type) ? Type.new(inner_type) : inner_type)
    ti = node.full_type!(context: "COPY result")
    resolver = ->(name) { lookup_type_schema(name) rescue nil }

    # COPY of a primitive or Id<T> is a semantic no-op (value copy, no allocation).
    # All other explicit COPYs produce heap-owned data.
    source_sync = node.value.respond_to?(:symbol) ? node.value.symbol&.sync : nil
    is_value_copy = ti.is_a?(Type) &&
      source_sync.nil? && !ti.multiowned? && !ti.shared? &&
      (ti.primitive? || ti.id_handle?)
    if is_value_copy
      node.storage = :stack
    else
      # COPY always produces heap-owned data for non-value types.
      # Type's clone constructor inherits source provenance (e.g., :rodata from
      # a string literal); override on the cloned Type so internal Type
      # predicates (needs_cleanup?, finalize_storage) see :heap. The
      # storage_override is the authoritative signal for Locatable readers.
      ti.mark_heap_allocated! if ti.is_a?(Type)
      node.storage = :heap
      current_fn_ctx.heap_count += 1 if current_fn_ctx
    end

    # Determine if elements need deep copy (dupeUnionValue) vs shallow (memcpy).
    # For list/array types, check if element type is a non-Copy union.
    vti = Type.from_node!(node.value, context: "array/list deep-copy")
    if vti.direct_indexable_collection?
      elem = vti.element_type
      if elem
        schema = lookup_type_schema(elem.resolved) rescue nil
        if Schemas.union?(schema)
          has_heap = (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
          node.deep_copy = has_heap
        end
      end
    end
  end

  # Infer return type for list.remove(i) — returns the element type.
  # `node` is unused (the receiver is args.first); nilable because
  # FunctionReturn#resolve dispatches without a call node.
  sig { params(node: AST::LinkNode).returns(T.nilable(Type)) }
  def visit_LinkNode(node)
    visit(node.value)
    ti = node.value.full_type!(context: "LINK value")

    unless ti&.any_rc?
      error!(node, :LINK_NEEDS_SHARED_OR_MULTIOWNED, got: node.value.resolved_type)
    end

    # Result is the same base type with :link ownership
    link_type = Type.new(ti.resolved)
    # Track which strong ownership kind the link was created from
    link_type.apply_reference_ownership!(:link, link_source: ti.shared? ? :shared : :multiowned)
    stamp_type!(node, link_type)
  end

  sig { params(node: AST::ResolveNode).returns(T.nilable(Type)) }
  def visit_ResolveNode(node)
    visit(node.value)
    ti = node.value.full_type!(context: "RESOLVE value")

    unless ti&.link?
      error!(node, :RESOLVE_NEEDS_LINK, got: node.value.resolved_type)
    end

    # RESOLVE returns ?T@multiowned or ?T@shared.
    # Use RESOLVE(link)?.field OR fallback to safely access the target.
    source = ti.link_source || :multiowned
    resolved_type = Type.new(:"?#{ti.resolved}")
    resolved_type.apply_reference_ownership!(source == :shared ? :shared : :multiowned, link_source: source)
    stamp_type!(node, resolved_type)
  end

  sig { params(node: AST::FreezeNode).returns(Symbol) }
  def visit_FreezeNode(node)
    without_capture_moves { visit(node.value) }
    ti = node.value.full_type!(context: "FREEZE value")
    unless ti&.multiowned? || ti&.shared?
      error!(node, :FREEZE_NEEDS_OWNED, got: node.value.resolved_type)
    end
    base = ti.resolved.to_s.sub(/^\?/, '')
    result_type = Type.new(base.to_sym)
    result_type.apply_reference_ownership!(:frozen)
    stamp_type!(node, result_type)
    node.storage   = :frozen
  end

  sig { params(node: T.untyped).void }
  def visit_Give(node)
    visit(node.value)

    # Validate that GIVE is used on something that makes sense
    # (e.g., an identifier, field access, or index access)
    if !node.value.is_a?(AST::Identifier) &&
       !node.value.is_a?(AST::GetField) &&
       !node.value.is_a?(AST::GetIndex)
      error!(node, :GIVE_BAD_TARGET)
    end

    # Mark the original as moved
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier)
      og_set_moved(root.name)
    end

    stamp_type!(node, node.value.resolved_type)
  end

  sig { params(node: AST::Copy).void }
  def visit_Copy(node)
    visit(node.value)

    # Validate that the type is actually copyable
    type = node.value.full_type!(context: "COPY keyword value")
    unless type&.copyable? { |name| lookup_type_schema(name) }
      error!(node, :COPY_NON_COPYABLE, type: node.value.resolved_type)
    end

    stamp_type!(node, node.value.resolved_type)
  end

  sig { params(node: AST::CloneNode).returns(T.nilable(T::Boolean)) }
  def visit_CloneNode(node)
    record_capture_site!(node, copied: true)
    without_capture_moves { visit(node.value) }
    type = node.value.full_type!(context: "CLONE value")
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
      error!(node, :CLONE_WITH_SCOPED, name: root.name)
    end

    unless type&.split_open_stream? || type&.shared_promise? || type&.any_rc?
      error!(node, :CLONE_BAD_TARGET, got: node.value.resolved_type)
    end

    stamp_type!(node, node.value.full_type!(context: "CLONE result"))
    node.storage = node.value.storage
    current_fn_ctx.uses_rt = true if current_fn_ctx && type&.any_rc?
  end

  sig { params(node: AST::ShareNode).void }
  def visit_ShareNode(node)
    visit(node.value)
    source_type = node.value.full_type!(context: "SHARE value")
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
      error!(node, :SHARE_WITH_SCOPED, name: root.name)
    end

    result = Type.new(source_type, ownership: :shared)
    stamp_type!(node, result)
    node.storage = :heap

    if share_consumes_source?(node.value)
      root = get_root_object(node.value)
      if root.is_a?(AST::Identifier)
        og_set_moved(root.name, at_token: root.token, action: :share)
        root.was_moved = true
      end
    end

    current_fn_ctx.heap_count += 1 if current_fn_ctx
    record_effect(EffectTracker::HEAP)
  end

  sig { params(node: AST::OptionalUnwrap).returns(Type) }
  def visit_OptionalUnwrap(node)
    visit(node.target)

    # Validate that the target is actually an optional type
    type = node.target.full_type!(context: "optional unwrap target")
    unless type&.optional?
      error!(node, :UNWRAP_NON_OPTIONAL, got: node.target.resolved_type)
    end

    # The result type is the wrapped type (without the ?)
    # Preserve ownership/sync so Rc/Arc auto-deref works on the unwrapped value.
    unwrapped = type.wrapped_type
    result = Type.new(unwrapped.resolved)
    result.merge_capabilities_from!(type, include_affine_ownership: true)
    stamp_type!(node, result)
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def get_root_object(node)
    curr = T.let(node, T.any(AST::CopyNode, AST::Identifier, AST::StructLit))
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      curr = curr.target
    end
    curr
  end

  # Collect all identifier names referenced (directly) in an AST subtree.
  # Used by the WHILE loop moved-value check to skip variables not referenced in the body.
  sig { params(nodes: T::Array[T.untyped]).returns(T::Set[String]) }
  def collect_body_identifier_names(nodes)
    names = Set.new
    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef
        # Don't descend into nested function definitions.
      when AST::Identifier
        names.add(n.name)
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(nodes)
    names
  end

  # ── Ownership: move, escape, borrow, drop ────────────────────────
  # All ownership state lives in @og (OwnershipGraph). The scope is
  # The scope handles type resolution, variable declarations, mutability,
  # and capability tracking. All ownership state is in the OwnershipGraph.

  sig { params(node: T.untyped).void }
  def handle_assign_move(node)
    return if node.value.is_a?(AST::CopyNode)

    reject_scoped_assignment_move!(node)

    if node.value.is_a?(AST::GetField) || node.value.is_a?(AST::GetIndex)
      handle_assignment_path_move!(node)
      return
    end

    handle_assignment_identifier_move!(node)
  end

  sig { params(node: T.untyped).void }
  def reject_scoped_assignment_move!(node)
    # Non-escaping values (WITH block aliases) cannot be moved/consumed.
    # Copy types (Int64, Bool, Float64, etc.) are exempt: assignment copies the
    # value with no pointer transfer, so no lifetime hazard exists.
    return unless node.value.is_a?(AST::Identifier) && node.value.symbol&.non_escaping

    vti = node.value.full_type!(context: "assignment scoped move value")
    needs_move = begin
      vti && Type.new(vti).requires_move?
    rescue
      true
    end
    error!(node, :MOVE_WITH_SCOPED, name: node.value.name) if needs_move
  end

  sig { params(node: T.untyped).void }
  def handle_assignment_path_move!(node)
    reject_borrowed_index_assignment_move!(node)
    path = get_path_to_root(node.value)
    return if path.nil?
    value_type = Type.new(node.value.resolved_type)
    return unless value_type.requires_move?

    graph_path = path.map(&:to_s).join(".")
    declare_assignment_graph_path!(graph_path, value_type) unless @og[graph_path]
    og_set_moved(graph_path, at_token: node.value.token, action: :move)
  end

  sig { params(graph_path: String, value_type: Type).void }
  def declare_assignment_graph_path!(graph_path, value_type)
    @og.declare(graph_path, kind: :affine, type_info: value_type, scope_depth: @og_scope_depth)
  end

  sig { params(node: T.untyped).void }
  def reject_borrowed_index_assignment_move!(node)
    # Container indexing of borrowed source into an owned target (HashMap
    # assignment) is an error. Plain variable declarations get borrow marking
    # via register_container_borrow! instead.
    return unless node.is_a?(AST::Assignment) && node.value.is_a?(AST::GetIndex)

    vti = node.value.full_type!(context: "assignment index value")
    vti = Type.new(vti) if vti && !vti.is_a?(Type)
    is_copy = vti.is_a?(Type) ?
      (vti.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil } rescue true) :
      true
    return if is_copy
    return unless find_container_source(node.value)

    source_name = root_variable_name(node.value)
    if source_name && @og[source_name]&.kind == :borrowed
      error!(node, :MOVE_BORROWED_INDEX, source: source_name)
    end
  end

  sig { params(node: T.untyped).void }
  def handle_assignment_identifier_move!(node)
    return unless node.value.is_a?(AST::Identifier)
    rhs_name = node.value.name
    rhs_type = current_scope.resolve_type(rhs_name)
    rhs_info = current_scope.locals[rhs_name]
    return if rhs_info&.rc_stored? || rhs_info&.sync

    type_obj = Type.new(rhs_type)
    # A String *binding* is owned/move (CLEAR contract). implicitly_copyable?
    # returns true for a String only via the rvalue rodata exemption
    # (type.rb: string? && rodata?); escape analysis stamps the binding's
    # declaration :rodata because the initializer is a literal, but a
    # binding's move semantics are type-intrinsic, not value-location.
    # Exclude string? from the Copy gate at this ownership-decision site;
    # genuinely-Copy aggregates keep their exemption.
    is_copy = type_obj.implicitly_copyable? { |t| lookup_type_schema(t) } && !type_obj.string?
    if !is_copy && (type_obj.requires_move? || rhs_info&.resource)
      # Cannot move a borrowed value (non-TAKES parameter).
      if @og[rhs_name]&.kind == :borrowed
        error!(node, :MOVE_BORROWED_PARAM, name: rhs_name)
      end
      lhs_name = node.name.is_a?(AST::Identifier) ? node.name.name : node.name.to_s
      # Track the move site at the RHS identifier's token so
      # use-of-moved errors can suggest fixes at the consuming line.
      move_tok = node.value.respond_to?(:token) ? node.value.token : node.token
      og_move(rhs_name, lhs_name, at_token: move_tok)
      node.value.was_moved = true
    end
  end

  sig { params(node: T.untyped).void }
  def handle_assign_borrow(node)
    return unless node.value.is_a?(AST::FuncCall) || node.value.is_a?(AST::MethodCall)
    call_node = node.value
    return if AST.collection_method_call?(call_node)

    # Resolve the borrowed argument from either user-defined or stdlib functions.
    actual_arg = resolve_borrow_source(call_node)
    return unless actual_arg

    path = get_path_to_root(actual_arg)
    return if path.nil?

    root_var = path.first.to_s
    borrowed_scope = lookup_scope_for(root_var)
    error!(node, :BORROWED_VAR_NOT_FOUND) if borrowed_scope.nil?
    return if T.must(borrowed_scope).is_immutable?(root_var)

    lhs_name = node.name.is_a?(AST::Identifier) ? node.name.name : "__borrow_#{root_var}"
    err = @og.borrow(lhs_name, root_var, mutable: node.mutable)
    error!(node, :LIFETIME_ALREADY_BORROWED, name: root_var) if err
  end

  # Returns the AST node of the argument the return value borrows from, or nil.
  sig { params(call_node: T.untyped).returns(T.untyped) }
  def resolve_borrow_source(call_node)
    # Path 1: stdlib functions with lifetime: "self"
    matched_def = call_node.matched_stdlib_def
    if matched_def && matched_def.emit && !matched_def.emit.lifetime.empty?
      lifetimes = matched_def.emit.lifetime
      if lifetimes.include?("self") && call_node.is_a?(AST::MethodCall)
        return call_node.object
      end
      # Named param lifetime -- find by index in args list
      args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
      arg_types = matched_def.arg_spec
      if arg_types.is_a?(Array)
        idx = arg_types.index { |a| a.is_a?(Hash) && lifetimes.include?(a[:name].to_s) }
        return args[idx] if idx && args[idx]
      end
      return nil
    end

    # Path 2: user-defined functions with return_lifetime: [...]
    func_name = call_node.name
    scope = lookup_scope_for(func_name)
    return nil unless scope

    func_type = FunctionSignature.unwrap(scope.resolve_type(func_name))
    return nil unless func_type

    # Multi-binding lifetime returns track the first source only. Borrow
    # tracking still records under one root; if a
    # multi-source RETURNS is used, the caller-side check in
    # `handle_assign_borrow` uses this single source. Multi-source
    # borrow tracking (record borrows on ALL sources, error when ANY
    # is already borrowed) needs broader audit work. Wildcard returns nil
    # because there is no specific source to track.
    lifetime = func_type.return_lifetime
    return nil if lifetime.empty? || lifetime == [:wildcard]
    primary = lifetime.first
    return nil if primary == :wildcard
    primary_root = primary.to_s.split(".").first

    param_index = func_type.params.find_index { |p| p.name == primary_root }
    return nil unless param_index

    args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
    args[param_index]
  end

  sig { params(node: T.untyped).void }
  def verify_unrestricted!(node)
    path = get_path_to_root(node.name)
    return if path.nil?
    root_name = path.first.to_s
    unless @og.can_write?(root_name)
      error!(node, :ASSIGN_WHILE_BORROWED, name: root_name)
    end
  end

  # Returns the Type of the last value-producing expression in a branch body,
  # or nil if the branch doesn't end with a usable expression.
  # Used to determine whether an IF/MATCH node can be promoted to expression mode.
  sig { params(branch: T.nilable(T::Array[T.untyped])).returns(T.nilable(Type)) }
  def expr_result_type(branch)
    return nil if branch.nil? || branch.empty?
    last = branch.last
    # ELSE_IF chain: the last element is a nested IfStatement — use its result type
    if last.is_a?(AST::IfStatement)
      return last.then_result_type
    end
    return nil unless last.is_a?(AST::Locatable)
    ti = last.full_type!(context: "branch result")
    return nil if ti.void? || ti.resolved == :NoReturn
    # These are statement-level constructs, not value-producing expressions
    return nil if AST.statement_result_void?(last)
    ti
  end

  # Promotes an AST::IfStatement that is used in expression position
  # (value of a VarDecl, BindExpr, ReturnNode, or FuncCall arg).
  # Sets expr_mode = true and full_type = result_type if valid; errors otherwise.
  sig { params(parent_node: T.untyped, if_node: AST::IfStatement).returns(T.nilable(Type)) }
  def promote_to_expr_if!(parent_node, if_node)
    # Recursively promote ELSE_IF chains first
    if if_node.else_branch&.length == 1 && (nested = if_node.else_branch.first).is_a?(AST::IfStatement)
      promote_to_expr_if!(if_node, nested)
      else_result = nested.full_type!(context: "nested expression if result")
    else
      else_result = if_node.else_result_type
    end

    then_result = if_node.then_result_type

    unless then_result
      error!(if_node, :IF_EXPR_THEN_NEEDS_VALUE)
    end
    unless else_result
      if if_node.else_branch.nil? || if_node.else_branch.empty?
        error!(if_node, :IF_EXPR_NEEDS_ELSE)
      else
        error!(if_node, :IF_EXPR_ELSE_NEEDS_VALUE)
      end
    end

    t1 = then_result.string? ? :String : then_result.resolved
    t2 = else_result.string? ? :String : else_result.resolved
    unless t1 == t2 || t1 == :Any || t2 == :Any
      error!(if_node, :IF_EXPR_BRANCHES_INCOMPATIBLE, then_type: t1, else_type: t2)
    end

    result_type = (t1 == :Any) ? else_result : then_result
    unless result_type.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
      error!(if_node, :IF_EXPR_RESULT_NOT_COPYABLE, type: result_type.resolved)
    end

    if_node.expr_mode = true
    stamp_type!(if_node, (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type)
  end

  # Promotes an AST::MatchStatement that is used in expression position.
  sig { params(parent_node: T.untyped, match_node: AST::MatchStatement).returns(T.nilable(Type)) }
  def promote_to_expr_match!(parent_node, match_node)
    case_types = match_node.case_result_types || []
    default_type = match_node.default_result_type

    # All case bodies must produce values
    case_types.each_with_index do |t, i|
      unless t
        error!(match_node, :MATCH_EXPR_BRANCH_NEEDS_VALUE)
      end
    end

    # PARTIAL MATCH expressions must have a DEFAULT branch -- without
    # one a non-exhaustive match leaves the result undefined for missing
    # variants. Plain MATCH is exhaustive by construction (annotator
    # already verified all variants are covered) so the implicit return
    # value is always defined.
    if !default_type && !match_node.exhaustive
      error!(match_node, :PARTIAL_MATCH_EXPR_NEEDS_DEFAULT)
    end

    all_types = case_types.compact
    all_types << default_type if default_type

    if all_types.empty?
      error!(match_node, :MATCH_EXPR_NEEDS_CASE)
    end

    resolved_types = all_types.map { |t| t.string? ? :String : t.resolved }.uniq.reject { |t| t == :Any }
    if resolved_types.size > 1
      error!(match_node, :MATCH_EXPR_BRANCHES_INCOMPATIBLE, types: resolved_types.join(', '))
    end

    result_type = all_types.first
    unless result_type.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
      error!(match_node, :MATCH_EXPR_RESULT_NOT_COPYABLE, type: result_type.resolved)
    end

    match_node.expr_mode = true
    stamp_type!(match_node, (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type)
  end

  sig { params(node: T.untyped, branch: T.nilable(Symbol)).returns(T.nilable(T::Hash[String, SymbolEntry])) }
  def finalize_scope(node, branch: nil)
    drops = []
    current_scope.locals.each do |name, info|
      next unless current_scope.owned_names.include?(name)
      # TAKES params always need cleanup guards even if moved (the _moved
      # flag controls whether cleanup runs at runtime).
      is_takes = info.respond_to?(:takes) && info.takes
      next unless @og.live?(name) || (is_takes && @og[name]&.moved?)
      classify_ownership!(info) unless info.ownership_kind

      case info.ownership_kind
      when :resource
        drops << { name: name, type: info.type, resource: true }
        og_drop(name)
      when :affine
        t = Type.new(info.type)
        if t.single_future?
          error!(node, :PROMISE_NOT_CONSUMED, name: name)
        end
        drops << { name: name, type: info.type }
        og_drop(name)
      end
    end

    case branch
    when :then  then node.then_drops = drops
    when :else  then node.else_drops = drops
    else node.deferred_drops = drops
    end

    # Unused variable warnings (function-level finalize only)
    if branch.nil?
      current_scope.locals.each do |name, info|
        next unless current_scope.owned_names.include?(name)
        next if name.start_with?('_')
        next if info.read
        next if info.reg&.respond_to?(:var_used) && info.reg.var_used
        classify_ownership!(info) unless info.ownership_kind
        next if [:resource, :collection, :rc].include?(info.ownership_kind)
        next unless info.reg

        # Keep this as a plain stderr warning: `_` collides with Zig discard
        # and deleting the line could drop RHS side effects.
        loc = info.reg.respond_to?(:line) ? " (line #{info.reg.line})" : ""
        $stderr.puts "\e[33m[Warning]\e[0m Unused variable '#{name}'#{loc}"
      end

      # MUTABLE-never-reassigned warnings
      current_scope.locals.each do |name, info|
        next unless current_scope.owned_names.include?(name)
        next if name.start_with?('_')
        next unless info.mutable
        next unless info.read || (info.reg&.respond_to?(:var_used) && info.reg.var_used)
        next if info.reg&.respond_to?(:var_mutated) && info.reg.var_mutated
        # Also skip when the binding was passed as a MUTABLE arg to a
        # callee — the binding's contents get mutated through the
        # call, so the receiving function's MUTABLE-param signature
        # forces the caller to keep MUTABLE on the local. function_analysis
        # marks `info.mutated` (entry-level) for this case but
        # intentionally does NOT set `info.reg.var_mutated` (which
        # drives the Zig-level var/const choice). Without this skip,
        # `clear fmt` strips MUTABLE here and the next build fails
        # the param's mutability check at the call site.
        next if info.respond_to?(:mutated) && info.mutated

        emit_mutable_unused_finding!(info.reg, name)
      end
    end
  end

  sig { params(node: T.nilable(AST::MatchStatement)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def collect_scope_drops(node: nil)
    drops = []
    current_scope.locals.each do |name, info|
      next unless @og.live?(name)
      classify_ownership!(info) unless info.ownership_kind
      case info.ownership_kind
      when :resource
        drops << { name: name, type: info.type, resource: true }
        og_drop(name)
      when :affine
        t = Type.new(info.type)
        if node && t.single_future?
          error!(node, :PROMISE_NOT_CONSUMED, name: name)
        end
        drops << { name: name, type: info.type }
        og_drop(name)
      end
    end
    drops
  end

  # Walk a GetField/GetIndex chain and flag any GetIndex nodes as needing
  # mutable pointer access.  Called when the chain leads to mutation
  # (field assignment, mutating method call, etc.) so the transpiler can
  # emit `.items[idx]` instead of by-value `getAt(list, idx)`.
  sig { params(node: T.untyped).void }
  def mark_chain_needs_mut_ref!(node)
    curr = node
    while curr
      curr.needs_mut_ref = true if curr.is_a?(AST::GetIndex)
      curr = curr.respond_to?(:target) ? curr.target : nil
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Array[Symbol])) }
  def get_path_to_root(node)
    path = []
    curr = T.let(node, T.untyped)
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      path.unshift(curr.is_a?(AST::GetField) ? curr.field.to_sym : :*)
      curr = curr.target
    end
    return nil unless curr.is_a?(AST::Identifier)
    path.unshift(curr.name.to_sym)
    path
  end

  # A tied-lifetime value cannot be stored where it would outlive any
  # source. Nil-lifetime bindings flow through unchanged.
  sig { params(assign_node: AST::Assignment).void }
  def verify_tied_assignment!(assign_node)
    val = assign_node.value
    sym = val.respond_to?(:symbol) ? val.symbol : nil
    sources = lifetime_sources_for_value(val)
    return if sources.empty?
    return if sym && sources == [sym]   # :current_scope is its own check path

    dest_depth = dest_scope_depth_for_target(assign_node.name)
    return if dest_depth.nil?

    # CLEAR scopes are LIFO-stacked: shallower depth = scope lives
    # LONGER. The destination outlives the source iff
    # `dest_depth < source.scope_depth`, which means storing a
    # tied value would let it outlive its anchor.
    sources.each do |source|
      next if source.scope_depth.nil?
      next unless dest_depth < source.scope_depth
      source_name = lookup_source_name(source) || "(unnamed)"
      msg = "Lifetime Error: cannot store value tied to '#{source_name}' " \
            "(declared at scope depth #{source.scope_depth}) into a destination " \
            "at scope depth #{dest_depth} -- the destination outlives the source. " \
            "Move the destination into the same scope, or COPY the value."
      # Atomic sources get a migration fix; non-atomic tied sources do not
      # have an equivalent @shared:locked repair.
      fix = build_atomic_escape_migration_fix(source, source_name)
      if fix
        fixable!(assign_node, message: msg, category: :escape,
                 level: :error, fixes: [fix], raise_in_collector: true)
      else
        error!(assign_node, :ATOMIC_ESCAPE_ASSIGN, message: msg)
      end
    end
  end

  # Returning a tied-lifetime value is legal only when the function declares
  # a matching `RETURNS <source>:T`; wildcard accepts any source.
  sig { params(return_node: AST::ReturnNode).void }
  def verify_tied_return!(return_node)
    val = return_node.value
    return unless val.is_a?(AST::Identifier)
    sym = val.symbol
    return unless sym
    sources = sym.lifetime_sources
    return if sources.empty?
    # `:current_scope` lifetime (lifetime_sources == [self]) means the
    # binding is anchored to its own declaring scope. Returning it is
    # always invalid — covered by the existing non_escaping check.
    return if sources == [sym]

    fn_node = @fn_nodes[current_fn_ctx&.name]
    rl = fn_node&.return_lifetime
    return if rl == :wildcard
    declared = rl.is_a?(Array) ? rl : (rl.nil? ? [] : [rl])

    declared_names = declared.flat_map do |n|
      path = get_path_to_root(n)
      path ? [path.first.to_s] : []
    end

    source_names = sources.map do |s|
      # Find the binding name: walk @fn_nodes' params + locally-named
      # decls. Source is a SymbolEntry whose .reg may be the
      # declaring AST node, but the cleaner path: look at scope.locals
      # and find the entry by identity.
      lookup_source_name(s)
    end.compact

    matched = source_names.any? { |n| declared_names.include?(n) }
    return if matched

    sources_msg = source_names.empty? ? "(unnamed source)" :
                                        source_names.join(", ")
    declared_msg = declared_names.empty? ? "no `RETURNS <name>:T`" :
                                           "`RETURNS #{declared_names.join(', ')}:T`"
    msg = "Lifetime Error: cannot RETURN a value whose lifetime is tied " \
          "to #{sources_msg}, because the enclosing function declares " \
          "#{declared_msg} -- the caller's scope outlives the source. " \
          "Either declare the function as `RETURNS #{source_names.first}:T` " \
          "(propagates the lifetime to the caller), or COPY the value " \
          "before returning it."

    # Pick the first atomic source we can repair; otherwise use the plain
    # lifetime error path.
    atomic_fix = T.let(nil, T.untyped)
    sources.each_with_index do |source, idx|
      name = source_names[idx] || lookup_source_name(source) || "(unnamed)"
      f = build_atomic_escape_migration_fix(source, name)
      if f
        atomic_fix = f
        break
      end
    end

    if atomic_fix
      fixable!(return_node, message: msg, category: :escape,
               level: :error, fixes: [atomic_fix], raise_in_collector: true)
    else
      error!(return_node, :ATOMIC_ESCAPE_RETURN, message: msg)
    end
  end

  # Look up the binding name of a SymbolEntry by scanning scope.locals.
  # Returns the String name or nil if not found.
  sig { params(sym: SymbolEntry).returns(T.nilable(String)) }
  def lookup_source_name(sym)
    sc = sym.scope
    return nil unless sc
    sc.locals.each do |name, entry|
      return name if entry.equal?(sym)
    end
    # Param symbols may have been refreshed via Scope.live_param_syms;
    # fall back to a function-level scan.
    @fn_nodes.each_value do |fn|
      next unless fn.respond_to?(:params)
      fn.params.each do |p|
        return p.name.to_s if p.symbol.equal?(sym)
      end
    end
    nil
  end

  # Return an error string when storing val_node at dest_depth would let it
  # outlive one of its tied-lifetime sources.
  sig { params(val_node: T.untyped, dest_depth: T.untyped).returns(T.nilable(String)) }
  def lifetime_violation_for_store(val_node, dest_depth)
    sources = lifetime_sources_for_value(val_node)
    return nil if sources.empty?
    # `:current_scope` lifetime is detected via lifetime_sources
    # returning [self], which means source.scope_depth = sym's own
    # depth. The same depth comparison applies uniformly.
    # CLEAR scopes are LIFO-stacked: shallower depth = scope lives
    # LONGER. Destination outlives source iff dest_depth < source.depth.
    sources.each do |source|
      next if source.scope_depth.nil?
      next if dest_depth.nil?
      if dest_depth < source.scope_depth
        return "Lifetime Error: cannot store value with lifetime tied to " \
               "scope depth #{source.scope_depth} into a destination at " \
               "depth #{dest_depth} (the destination outlives the source)."
      end
    end
    nil
  end

  sig { params(val_node: T.untyped).returns(T::Array[SymbolEntry]) }
  def lifetime_sources_for_value(val_node)
    sources = T.let([], T::Array[SymbolEntry])
    if val_node.respond_to?(:symbol)
      sym = val_node.symbol
      sources.concat(sym.lifetime_sources) if sym
    end
    sources.concat(collect_bg_sources_in_expr(val_node))
    sources.uniq
  end

  # Convenience: the escape destination's effective scope depth.
  # For a struct-field assign `a.field = v`, depth = a's binding scope.
  # For a method receiver (`list.append(v)`), depth = list's binding scope.
  # For a free local in current scope, depth = current scope.
  sig { params(target_node: T.untyped).returns(T.untyped) }
  def dest_scope_depth_for_target(target_node)
    if target_node.is_a?(AST::Identifier)
      sym = target_node.symbol
      sym ||= lookup_scope_for(target_node.name)&.locals&.[](target_node.name)
      return sym&.scope_depth
    end
    if target_node.is_a?(AST::GetField) || target_node.is_a?(AST::GetIndex)
      return dest_scope_depth_for_target(target_node.target)
    end
    nil
  end

  # A BG handle's lifetime is bounded by the shortest-lived captured
  # atomic/locked/multiowned/local source.
  #
  # Skipped sources (no lifetime contribution):
  #   - @shared (Arc): refcounted; the inner data lives as long as
  #     any reference exists, so the BG handle isn't bounded by the
  #     declaring scope of the original Arc binding.
  #   - @local: BG is auto-pinned, so the BG and the @local binding
  #     run on the same scheduler. The capture is by-pointer; the
  #     captured pointer's validity IS bounded by the @local
  #     binding's scope, so we include it.
  #   - Captures whose binding has no SymbolEntry on capture_symbols
  #     (e.g. observable view aliases); those are already errored at
  #     visit_BgBlock via has_non_escaping_capture.
  sig { params(decl_node: T.untyped).void }
  def stamp_bg_handle_lifetime!(decl_node)
    sources = collect_bg_sources_in_expr(decl_node.value).uniq
    return if sources.empty?
    sym = decl_node.symbol
    return unless sym
    sym.lifetime = SymbolEntry.tied_lifetime(sources)
  end

  # Single-writer stamp: this binding's heap-bearing contents were already
  # materialized for heap storage at bind time.
  sig { params(decl_node: T.untyped).void }
  def stamp_init_contents_heap!(decl_node)
    sym = decl_node.symbol
    return unless sym
    init = decl_node.respond_to?(:value) ? decl_node.value : nil
    sym.mark_init_contents_heap! if init_value_contents_heap?(init)
  end

  sig { params(init: T.untyped).returns(T::Boolean) }
  def init_value_contents_heap?(init)
    return false unless init
    case init
    when AST::StructLit, AST::UnionVariantLit
      init.fields.all? do |_, fval|
        next true unless fval
        fti = Type.from_node!(fval, context: "heap init field")
        next true unless fti.string? || fti.collection?
        fval.is_a?(AST::Locatable) && fval.heap_storage?
      end
    when AST::FuncCall, AST::MethodCall
      init.is_a?(AST::Locatable) && init.heap_storage?
    when AST::Identifier
      !!init.symbol&.init_contents_heap
    when AST::CopyNode, AST::CloneNode
      true
    when AST::Cast
      init_value_contents_heap?(init.value)
    when AST::IfStatement
      then_tail = (init.then_branch || []).last
      else_tail = (init.else_branch || []).last
      tails = [then_tail, else_tail].compact
      tails.size == 2 && tails.all? { |t| init_value_contents_heap?(t) }
    when AST::MatchStatement
      cases = init.cases.map { |c| c.body.last }.compact
      default_tail = init.default_case&.last
      tails = cases + (default_tail ? [default_tail] : [])
      tails.any? && tails.all? { |t| init_value_contents_heap?(t) }
    else
      false
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

  # Walk an expression tree to find every BgBlock / BgStreamBlock and
  # union their lifetime-bound capture sources. Without this walk, a
  # BG buried inside a container literal escapes its captures' scope
  # when the surrounding binding is RETURNed / stored / passed (real
  # UAF, fuzz finding `lifetimed_return` store_in_field cell).
  #
  # Default-recurse: every AST node-with-sub-expressions is walked
  # generically via Struct.members. Opt-OUT only for the small finite
  # set of AST classes whose lifetime is determined by symbol /
  # return-type rather than by sub-expression containment (see
  # BG_SOURCE_OPAQUE_AST_NODES). New AST container types added later
  # propagate for free; missing-recursion bugs surface as compile-time
  # over-rejection rather than silent UAF.
  sig { params(expr: T.untyped).returns(T::Array[SymbolEntry]) }
  def collect_bg_sources_in_expr(expr)
    return [] if expr.nil?
    return bg_sources_for_block(expr) if expr.is_a?(AST::BgBlock) || expr.is_a?(AST::BgStreamBlock)
    return [] if BG_SOURCE_OPAQUE_AST_NODES.include?(expr.class)
    return [] unless expr.is_a?(Struct)
    expr.members.flat_map do |m|
      v = expr[m]
      collect_bg_sources_walk(v)
    end
  end

  sig { params(v: T.untyped).returns(T::Array[SymbolEntry]) }
  def collect_bg_sources_walk(v)
    case v
    when Array then v.flat_map { |x| collect_bg_sources_walk(x) }
    when Hash  then v.values.flat_map { |x| collect_bg_sources_walk(x) }
    when Struct then collect_bg_sources_in_expr(v)
    else []
    end
  end

  sig { params(expr: T.untyped).returns(T::Array[SymbolEntry]) }
  def bg_sources_for_block(expr)
    analysis = expr.respond_to?(:capture_analysis) ? expr.capture_analysis : nil
    return [] unless analysis && analysis.respond_to?(:capture_symbols)
    bg_lifetime_sources(analysis)
  end

  # Walk the capture-analysis SymbolEntries and pick the ones whose
  # storage / sync makes them lifetime-bounded sources for the BG
  # handle. See stamp_bg_handle_lifetime! for the criteria.
  #
  # A capture is a SOURCE (binds the BG handle's lifetime to the
  # capture's scope) when its underlying memory cannot independently
  # outlive the binding. The bound conditions are explicit because
  # each storage/sync combo has different reach semantics; the
  # critical previously-missing case is plain `@local` (or unannotated)
  # locals — captured by reference into the BG's fiber frame, so the
  # source binding's death = pointer-into-freed-memory.
  sig { params(analysis: CapabilityHelper::CaptureAnalysis).returns(T::Array[SymbolEntry]) }
  def bg_lifetime_sources(analysis)
    (analysis.capture_symbols || {}).each_value.reject { |info|
      info && bg_capture_independent?(info)
    }.compact
  end

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

  # Default-deny inverse of the old explicit-include-list. A capture is
  # INDEPENDENT (free to outlive its source) only via one of the
  # explicit escape hatches encoded above; everything else binds the
  # BG handle's lifetime by default. New storage/sync/layout
  # combinations land here as compile-time RETURN-rejections, not
  # silent UAFs.
  sig { params(info: T.untyped).returns(T::Boolean) }
  def bg_capture_independent?(info)
    # Arc-only (Group 1: @shared without inner sync) — refcounted, escapable.
    return true if STORAGE_OUTLIVES_DECLARING_SCOPE.include?(info.storage) && info.sync.nil?
    # @indirect:atomic — heap-pinned AtomicPtr cell with own lifetime
    # mechanism (M3.5 promotion).
    return true if info.atomic_ptr?
    # Any sync wrapper (Group 1 sync sigils — atomic, locked,
    # write_locked, local, versioned, always_mutable) captures the
    # binding by reference into the fiber frame; lifetime-bound
    # regardless of inner type. Excluded: pure data-access modes
    # listed in SYNC_DOES_NOT_BIND_CAPTURE.
    return false if info.sync && !SYNC_DOES_NOT_BIND_CAPTURE.include?(info.sync)
    # Rc storage: bound to declaring scope (refcount-shared but
    # captures borrow without bumping the count).
    return false if info.storage == :multiowned
    # No sync wrapper, no Rc: the TYPE's inherent escape class
    # decides. :value / :slice_rodata = value-copy = escapable.
    # Authoritative source: Type#escape_class.
    ti = info.respond_to?(:type) ? info.type : nil
    return false unless ti
    value_copy_capture?(ti)
  end

  # Thin wrapper that hands the annotator's schema-lookup closure to
  # `Type#bg_capture_is_value_copy?`. The Type predicate needs schema
  # access to resolve enum / union-without-heap / all-Copy struct
  # cases via lookup_type_schema; structs are always rejected (ref
  # capture into the fiber frame, even if every field is Copy).
  sig { params(t: T.untyped).returns(T::Boolean) }
  def value_copy_capture?(t)
    ti = t.is_a?(Type) ? t : Type.new(t)
    ti.bg_capture_is_value_copy? { |name| lookup_type_schema(name) rescue nil }
  end

  # Produce dotted-path lifetime roots. Wildcard and nil return [] because
  # there is no source-restricted path the return value must match.
  sig { params(func_node: AST::FunctionDef).returns(T::Array[T.untyped]) }
  def get_lifetime_paths(func_node)
    rl = func_node.return_lifetime
    return [] if rl.nil?
    return [:wildcard] if rl == :wildcard
    sources = rl.is_a?(Array) ? rl : [rl]
    sources.map { |s| get_path_to_root(s)&.join(".") }.compact
  end

  # Backward-compat shim: legacy single-binding callers got a single
  # string. Returns nil for multi-source / wildcard / no-lifetime
  # cases, matching the old contract for those shapes.
  sig { params(func_node: AST::FunctionDef).returns(T.nilable(String)) }
  def get_lifetime_path(func_node)
    paths = get_lifetime_paths(func_node)
    return nil if paths.size != 1 || paths.first == :wildcard
    paths.first
  end

  # Walk through GetField/GetIndex chains to find the root Identifier name.
  sig { params(node: T.untyped).returns(T.nilable(String)) }
  def root_variable_name(node)
    curr = node
    while curr
      return curr.name if curr.is_a?(AST::Identifier)
      curr = if curr.respond_to?(:target)
               curr.target
             elsif curr.respond_to?(:object)
               curr.object
             else
               nil
             end
    end
    nil
  end

  # ── Strict Test Mode ─────────────────────────────────────────────
  # In --strict mode, all IO functions (BLOCKING/EXTERN effects) must be
  # stubbed in test bodies. Walks the call chain transitively.

  # IO_BUILTINS and validate_strict_io! moved to
  # annotator/helpers/test_annotation.rb (TestAnnotation module).

  # ── Tail Call Validation ─────────────────────────────────────────

  # Tail-call lowering relies on recursion becoming a self-loop; any
  # wrapped or nested self-call would still consume real stack.
  sig { params(fn_node: AST::FunctionDef).returns(T.nilable(T::Array[T.untyped])) }
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

  # ── Ownership Graph Operations ─────────────────────────────────

  # Determine which allocator cleanup should use for this binding.
  # Sets provenance on the type_info; cleanup_alloc is now derived from provenance.
  sig { params(node: T.untyped).returns(T.nilable(Symbol)) }
  def set_cleanup_alloc!(node)
    ti = node.full_type!(context: "cleanup binding")
    return unless ti

    # Check if value comes from a stdlib function with explicit metadata
    val = node.value
    if val && (val.is_a?(AST::FuncCall) || val.is_a?(AST::MethodCall))
      matched_def = val.matched_stdlib_def
      if matched_def
        # Borrow returns (lifetime:) need no cleanup -- the caller owns the data
        if matched_def.emit && !matched_def.emit.lifetime.empty?
          val.storage = :borrow if val.respond_to?(:storage=)
          node.storage = :borrow if node.respond_to?(:storage=)
          return
        end
        ret_alloc = matched_def.emit&.return_alloc
        # For allocating methods without explicit return_alloc, the method's
        # alloc IS the return alloc (e.g. map.values() on sharded maps).
        ret_alloc ||= matched_def.emit&.alloc if matched_def.emit&.allocates
        if ret_alloc
          if [:heap, :frame].include?(ret_alloc)
            val.storage = ret_alloc if val.respond_to?(:storage=)
          end
          return
        end
      end
    end

    alloc = ti.cleanup_allocator(->(name) { lookup_type_schema(name) })
    # Propagate provenance: prefer value's provenance, then computed alloc.
    val_ti = val.is_a?(AST::Locatable) ? val.full_type!(context: "cleanup value provenance") : nil
    val_ti = val_ti.is_a?(Type) ? val_ti : nil
    ti.apply_cleanup_placement!(value_type: val_ti, alloc: alloc)
    alloc
  end

  sig { params(name: String, node: T.untyped, type_info: T.any(Type, Symbol, String)).returns(T.untyped) }
  def og_declare(name, node, type_info)
    entry = current_scope.locals[name] rescue nil
    kind = classify_og_kind(type_info, sync: entry&.sync)
    ti = type_info.is_a?(Type) ? type_info : Type.new(type_info)
    @og.declare(name, kind: kind, type_info: ti,
                scope_depth: @og_scope_depth, line: node&.respond_to?(:line) ? node.line : 0)
  end

  sig { params(from: String, to: String, at_token: T.nilable(Lexer::Token), action: Symbol).returns(T.nilable(T::Set[T.untyped])) }
  def og_move(from, to, at_token: nil, action: :move) = @og.transfer(from, to, at_token: at_token, action: action)
  sig { params(name: String, at_token: T.nilable(Lexer::Token), action: Symbol, consumer_param_type: T.untyped).returns(T.nilable(T::Set[T.untyped])) }
  def og_set_moved(name, at_token: nil, action: :move, consumer_param_type: nil) = @og.mark_moved(name, at_token: at_token, action: action, consumer_param_type: consumer_param_type)

  sig { params(node: T.untyped).returns(T::Boolean) }
  def share_consumes_source?(node)
    return false if node.is_a?(AST::CopyNode)

    ti = node.full_type!(context: "share consume source")
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    return false if ti.is_a?(Type) && ti.shared?

    true
  end

  # Mark an identifier as moved if its type is non-Copy.
  # Skips generic type params (can't determine copyability at annotation time).
  # Skips when the binding is already marked moved with a more-specific
  # action (e.g., `:give` set by visit_GiveNode) — overwriting it with
  # `:move` would destroy the action info that the
  # USE_OF_MOVED_VALUE diagnostic uses to phrase "GAVE/TOOK/etc.".
  #
  # `consumer_param_type` is recorded on the OG node at TAKES sites so
  # the USE_OF_MOVED_VALUE fix-dropdown can skip suggesting an
  # `@shared` / `@multiowned` upgrade when the consumer's parameter
  # is a plain affine type that won't accept a refcounted handle.
  sig { params(node: T.untyped, action: Symbol, consumer_param_type: T.untyped).returns(T.nilable(T::Boolean)) }
  def move_if_not_copyable!(node, action: :move, consumer_param_type: nil)
    return unless node.is_a?(AST::Identifier)
    vt = node.full_type!(context: "move candidate")
    vt = Type.new(vt) if vt && !vt.is_a?(Type)
    return unless vt.is_a?(Type)
    return if current_fn_ctx&.type_params&.include?(vt.resolved)
    return if vt.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
    existing = @og&.nodes&.[](node.name)
    if existing&.specific_move_action?
      # An earlier visitor (typically visit_GiveNode) already stamped
      # the move site with a more-specific action like `:give`. Don't
      # overwrite the action — but DO backfill the consumer's
      # parameter type when the call-arg loop has it and the earlier
      # visitor didn't, so the use-after-move fix-dropdown can still
      # filter `@shared` / `@multiowned` upgrades that won't help.
      if consumer_param_type && existing.move_consumer_param_type.nil?
        existing.move_consumer_param_type = consumer_param_type
      end
      node.was_moved = true
      return
    end
    og_set_moved(node.name, at_token: node.token, action: action, consumer_param_type: consumer_param_type)
    node.was_moved = true
  end

  sig { params(node: T.untyped, action: Symbol, consumer_param_type: T.untyped).returns(T.nilable(T::Boolean)) }
  def move_if_takes_ownership!(node, action: :takes, consumer_param_type: nil)
    return unless node.is_a?(AST::Identifier)
    vt = node.full_type!(context: "TAKES ownership candidate")
    vt = Type.new(vt) if vt && !vt.is_a?(Type)
    return unless vt.is_a?(Type)
    return if current_fn_ctx&.type_params&.include?(vt.resolved)
    return if vt.primitive? || vt.id_handle?

    existing = @og&.nodes&.[](node.name)
    if existing&.specific_move_action?
      existing.move_consumer_param_type = consumer_param_type if consumer_param_type && existing.move_consumer_param_type.nil?
      node.was_moved = true
      return
    end
    og_set_moved(node.name, at_token: node.token, action: action, consumer_param_type: consumer_param_type)
    node.was_moved = true
  end

  # Reject storing a borrowed value into an owned container (struct, union, TAKES param).
  # Borrows can't outlive the scope they reference. Use COPY for owned data.
  sig { params(val_node: T.untyped, container_desc: String).returns(NilClass) }
  def reject_borrowed_value!(val_node, container_desc)
    borrowed_name = nil
    if val_node.is_a?(AST::GetIndex)
      borrowed_name = "#{root_variable_name(val_node)}[index]"
    elsif val_node.is_a?(AST::Identifier) && @og&.[](val_node.name)&.kind == :borrowed
      borrowed_name = val_node.name
    end
    return unless borrowed_name
    vti = val_node.full_type!(context: "borrowed container value")
    return if vti&.primitive?
    return if vti&.generic_instance?
    # Skip generic type parameters - can't determine borrowability at annotation time.
    return if current_fn_ctx&.type_params&.include?(vti&.resolved)
    has_pointer = vti&.heap_ptr?
    return if !has_pointer && !vti&.struct?
    error!(val_node, :STORE_BORROWED_INTO_CONTAINER, name: borrowed_name, container: container_desc)
  end
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

  sig { params(type_info: T.any(Type, Symbol, String), sync: T.nilable(Symbol)).returns(Symbol) }
  def classify_og_kind(type_info, sync: nil)
    t = type_info.is_a?(Type) ? type_info : Type.new(type_info)
    if t.multiowned? || t.shared?
      :rc
    elsif sync
      :sync
    elsif t.implicitly_copyable? { |name| lookup_type_schema(name) }
      :value
    else
      :affine
    end
  end

end
