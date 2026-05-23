# typed: strict
require "sorbet-runtime"

require_relative "ast/source_error"
require_relative "ast/fixable_error"
require_relative "ast/scope"
require_relative "ast/parser"
require_relative "ast/std_lib"
require_relative "annotator-helpers/function_context"
require_relative "annotator-helpers/function_signature"
require_relative "annotator-helpers/function_analysis"
require_relative "annotator-helpers/pipe_analysis"
require_relative "mir/ownership_graph"
require_relative "mir/escape_analysis"
require_relative "mir/escape_graph"
require_relative "mir/bg_capture_classifier"
require_relative "mir/effect_inference"
require_relative "mir/concurrency_checks"
require_relative "annotator-helpers/generic_analysis"
require_relative "annotator-helpers/capabilities"
require_relative "annotator-helpers/test_annotation"
require_relative "annotator-helpers/with_match_check"
require_relative "annotator-helpers/fixable_helpers"
require_relative "annotator-helpers/effects"
require_relative "annotator-helpers/reentrance"
require_relative "mir/thunk_transform"
require_relative "annotator-helpers/lock_helper"
require_relative "mir/alloc"
require_relative "annotator-helpers/method_analysis"
require_relative "annotator-helpers/union"
require_relative "annotator-helpers/auto_inference"
require_relative "backends/importer" # ModuleImporter — referenced by SemanticAnnotator#initialize's sig

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

  attr_reader :scope_stack

  sig { returns(T.untyped) }
  def current_fn_ctx
    @function_context_stack.last
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

  # `source_code` is optional — used ONLY by fixable-error helpers to
  # locate source-level spans (e.g., the `;` at the end of a
  # declaration line so `@multiowned` can be inserted before it).
  # When nil, affected helpers fall back to the plain `error!` path.
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
    @match_pattern_context = T.let(false, T::Boolean) # True when visiting a MATCH case value (suppresses inline-struct GetField error)
    # Reentrancy analysis
    @call_graph  = T.let({}, T::Hash[T.untyped, T.untyped])  # name => Set of directly-called function names (excluding self-calls)
    @fn_propagating_callees = T.let({}, T::Hash[T.untyped, T.untyped]) # name => Set of callees whose error channel can propagate (NOT OR-absorbed); authority for can_fail (#11)
    @fn_has_fnptr = T.let({}, T::Hash[T.untyped, T.untyped]) # name => true if function calls a fn-type variable or lambda
    @fn_nodes    = T.let({}, T::Hash[T.untyped, T.untyped])  # name => FunctionDef node (for error reporting in the post-pass)
    # Performance analysis
    @fn_raises_directly = T.let({}, T::Hash[T.untyped, T.untyped])  # name => true if body has Raise/OrRaise, uses_frame, has_fnptr, or @nonReentrant
    # Capability audit — tracks declarations and usage to detect over-engineering.
    # SOA analysis: tracks which fields of `_` are accessed during pipeline lambda bodies.
    # nil = not inside a pipeline; Set = collecting field names.
    @pipeline_accessed_fields = T.let(nil, T.nilable(T::Set[T.untyped]))
    @current_predicate_context = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
    @capability_audit = T.let({}, T::Hash[T.untyped, T.untyped])
    @fn_direct_effects = T.let({}, T::Hash[T.untyped, T.untyped])
    @call_site_context = T.let(nil, T.untyped)
    @call_site_arg_families = T.let(nil, T.untyped)
    @in_auto_locked_assign = T.let(nil, T.nilable(String))
    @with_block_depth = T.let(0, Integer)

    # Lock analysis is cycle-checked after @call_graph is complete.
    init_lock_analysis!
    # @pinned escape safety: true when inside a @pinned BG block.
    @current_bg_pinned = T.let(false, T::Boolean)
    # WITH validations on parameter bindings need caller-sync propagation first.
    @deferred_with_validations = T.let([], T::Array[T.untyped])
    @predicate_call_sites = T.let([], T::Array[T.untyped])
    # Tracks remaining statements in current body for forward reference analysis
    @stmts_after = T.let(nil, T.nilable(T::Array[T.untyped]))
    # Ownership graph: shadow tracker that runs in parallel with the scope-based system.
    @og = T.let(OwnershipGraph.new, T.untyped)
    @og_scope_depth = T.let(0, Integer)
    @synthetic_fns = T.let([], T::Array[T.untyped])
    @branch_terminated = T.let(false, T::Boolean)
    @snapshot_txn_violations = T.let(nil, T.nilable(T::Array[T.untyped]))
    @stream_yield_types = T.let(nil, T.nilable(T::Array[T.untyped]))
    effects_init!
    capability_audit_init!
    setup_builtins
  end

  sig { params(node: AST::Program).returns(T.nilable(T::Hash[String, T::Hash[Symbol, T.untyped]])) }
  def annotate!(node)
    # Reset user-registered error types so state from prior runs (rspec
    # parallel, multi-program test harness) doesn't leak in. Stdlib
    # types are preserved.
    AST.reset_user_types!
    @program = T.let(node, T.nilable(AST::Program))  # WithMatchCheck reads node.sync_policy below.
    visit(node)
    # Resolve Auto slots before downstream analyses so they see finalized
    # signatures and concrete declaration types.
    run_auto_inference!(node) if program_has_auto?(node)
    # Caller sync depends on annotated call-site args, so propagate it after
    # the body walk and before replaying deferred WITH validations.
    EscapeAnalysis.propagate_caller_sync!(@fn_nodes)
    # Single authority for BG capture-strategy facts. Runs AFTER
    # propagate_caller_sync! (so SymbolEntry stamps are final) and
    # BEFORE the downstream passes that need to know which captures
    # are MoveInto / FreshHeapCopy / RcClone / ByValue. Stamps the
    # results on each BgBlock.capture_analysis so EscapeAnalysis,
    # OwnershipDataflow, MIRPass, and mir_lowering can READ instead
    # of each re-deriving with their own walker (the divergence class
    # of bug fixed in 378036a0 / 1522e534).
    BgCaptureClassifier.classify_all!(@fn_nodes, schema_lookup: ->(t) { lookup_type_schema(t) rescue nil })
    EffectInference.analyze!(@fn_nodes)
    err = ->(n, msg) { error!(n, :EFFECT_INFERENCE_VIOLATION, message: msg) }
    warn = ->(n, msg) { note!(n, msg) }
    sig_lookup = ->(name) {
      @scope_stack.first.locals[name]&.type
    }
    # Pass the program policy so polymorphic warnings don't duplicate
    # handling already covered by SYNC POLICY.
    policy_handlers = @program&.sync_policy
    @fn_nodes.each_value { |fn|
      WithMatchCheck.check_function!(fn, err, warn_handler: warn,
                                     policy_handlers: policy_handlers)
    }
    # Re-stamp signatures so call-site checks below see any shim-inferred
    # REQUIRES clauses.
    @fn_nodes.each do |name, fn|
      sig = FunctionSignature.unwrap(@scope_stack.first.locals[name]&.type)
      sig.requires = fn.requires if sig
    end
    @fn_nodes.each_value { |fn| WithMatchCheck.check_call_sites!(fn, sig_lookup, err) }
    # Rank-annotated locks are checked by the rank-DAG analysis, not the
    # pattern-based naked-nested-WITH check.
    ConcurrencyChecks.check_all!(@fn_nodes, sig_lookup, err,
                                 lock_ranks: @lock_type_ranks || {})
    # Residual deferred WITH validations (any param whose sync is still
    # nil after propagation, e.g., a function called from no callsite).
    flush_deferred_with_validations!
    finalize_capability_audit!
  end

private

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
  sig { params(resolved_slots: T::Hash[T::Array[T.untyped], AutoUnifier::Resolution]).returns(T::Hash[T::Array[T.untyped], AutoUnifier::Resolution]) }
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
  sig { returns(T::Array[T.untyped]) }
  def flush_deferred_with_validations!
    @deferred_with_validations.each do |d|
      var_node = d[:var_node]
      syn = var_node.symbol&.sync
      case d[:capability]
      when :EXCLUSIVE
        next if syn
        storage = var_node.symbol&.storage
        error!(d[:node], :WITH_EXCLUSIVE_NEEDS_LOCK_GOT, got: storage || 'unknown')
      when :write_locked_read
        next if syn == :write_locked
        error!(d[:node], :WITH_READ_NEEDS_WRITE_LOCK_NAME, name: var_node.name)
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

    # Dynamic Dispatch
    method_name = "visit_#{node.class.name.split('::').last}"
    send(method_name, node)
  end

  # Cached outer scope variable set - avoids O(n) flat_map per loop
  sig { returns(T::Set[T.untyped]) }
  def outer_scope_vars
    @scope_stack.flat_map { |s| s.locals.keys }.to_set
  end

  sig { params(node: AST::Program).returns(T.untyped) }
  def visit_Program(node)
    # Imports must be available before local types or functions are registered.
    node.statements.each do |stmt|
      visit_RequireNode(stmt) if stmt.is_a?(AST::RequireNode)
    end

    # Types are registered before function signatures can reference them.
    node.statements.each do |stmt|
      visit(stmt) if stmt.is_a?(AST::StructDef) || stmt.is_a?(AST::ExternStructDecl) ||
                     stmt.is_a?(AST::EnumDef)   || stmt.is_a?(AST::UnionDef)
    end

    # Function signatures are hoisted so functions can call later definitions.
    node.statements.each do |stmt|
      pre_register_function(stmt) if stmt.is_a?(AST::FunctionDef)
      visit_ExternFnDecl(stmt)    if stmt.is_a?(AST::ExternFnDecl)
    end

    # Union default methods are synthesized only after all function signatures
    # are known.
    @synthetic_fns = []
    node.statements.each do |stmt|
      next unless stmt.is_a?(AST::UnionDef) && stmt.methods&.any?
      validate_union_methods!(stmt)
    end
    # Pre-register synthesized defaults so user bodies can call them.
    @synthetic_fns.each { |fn| pre_register_function(fn) }

    # Bridge legacy `@reentrant` and new `EFFECTS REENTRANT` after
    # @fn_nodes is populated and before function bodies are checked.
    bridge_reentrance!(node)

    # Seed before body analysis so CATCH Type clauses can reference error
    # types registered by later-in-source RAISE sites.
    seed_error_types_from_raises!(node)

    # Stamps the resolved SYNC POLICY, user-written or default, so later
    # passes read a single source of truth.
    validate_and_resolve_sync_policy!(node)

    node.statements.each do |stmt|
      # Skip nodes already processed in earlier passes.
      next if stmt.is_a?(AST::StructDef)    || stmt.is_a?(AST::RequireNode) ||
              stmt.is_a?(AST::ExternFnDecl) || stmt.is_a?(AST::ExternStructDecl) ||
              stmt.is_a?(AST::EnumDef)      || stmt.is_a?(AST::UnionDef)

      visit(stmt)
    end

    # Analyze synthesized default function bodies and append to program so
    # the transpiler emits them as top-level Zig functions.
    @synthetic_fns.each do |fn|
      visit_FunctionDef(fn)
      node.statements << fn
    end

    # Indirect recursion needs the complete call graph.
    check_indirect_reentrancy!

    # Reject `:reentrant_not_logical` on a function the call-graph
    # proves is reachable from itself; nudge toward `:THUNK` /
    # `:MAX_DEPTH(N)` instead.
    validate_not_logical_recursion!

    # A `:MAX_DEPTH` fn in a mutual cycle demotes to ':unbounded'; warn
    # so the user can choose an explicit fix.
    validate_max_depth_mutual_cycle!

    # Mutual thunk recursion needs tagged-union frames; until then, report
    # a precise error instead of falling into incorrect codegen.
    validate_thunk_recursion!

    compute_needs_rt!
    compute_can_fail!

    # Transitive fallibility is known only after compute_can_fail!, so
    # error-union return declarations are enforced here.
    enforce_fallible_returns!

    # Function values must match the fn-pointer calling convention emitted
    # by type.rb#zig_type.
    mark_fn_value_references!(node)

    compute_effects!
    validate_predicate_purity!

    # FSM metadata is computed before lock-cycle and stack analysis so spawn
    # form and suspend points are available to later passes.
    compute_fsm_eligibility!
    enumerate_fsm_suspend_points!
    classify_bg_spawn_form!(node)

    # Lock-cycle detection needs propagated held-while-calling edges.
    check_lock_cycles!

    compute_stack_tiers!

    assign_fiber_stack_tiers!(node)

    # Copy computed metadata to FunctionSignature objects so callers don't
    # need direct access to @fn_nodes.
    @fn_nodes.each do |name, fn|
      sig = FunctionSignature.unwrap(fn.full_type)
      next unless sig
      sig.needs_rt = fn.needs_rt
      sig.can_fail = fn.can_fail
      sig.return_provenance = fn.return_provenance
      sig.effects = fn.effects
      sig.stack_tier = fn.stack_tier
    end

    # Determine Program Result Type (Type of the last statement)
    if node.statements.any?
      node.full_type = node.statements.last.full_type
    else
      node.full_type = :Void
    end
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
    node.full_type = :Void

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

  # EXTERN FN name(params) RETURNS type FROM "module"
  # Registers a native Zig/C function in the current scope.
  # At call sites, no rt is injected and no try is emitted.
  sig { params(node: AST::ExternFnDecl).returns(Symbol) }
  def visit_ExternFnDecl(node)
    signature = FunctionSignature.new(
      params: node.params.map { |p| AST::Param.new(
        name: p.name,
        type: p.type,
        required: p.default.nil?,
        mutable: p.mutable || false,
        comptime: p.comptime || false
      )},
      return_type: node.return_type || Type.new(:Any),
      visibility: :pub,
      extern: true,
      module_alias: node.from_module,
      extern_effects: node.effects || {},
      fn_type_params: node.fn_type_params || [],
      type_params: (node.fn_type_params || []).any? ? (node.fn_type_params || []) : nil,
      owner_type: node.owner_type,
      owner_type_params: node.owner_type_params || []
    )

    if node.owner_type
      # EXTERN FN TypeName<T>.method(...) — register as method on the type
      type_sym = node.owner_type.to_sym
      type_schema = current_scope.types[type_sym]&.dig(:schema)
      if Schemas.struct?(type_schema) || Schemas.resource?(type_schema)
        type_schema.methods[node.name] = signature
      end
    else
      # Free function — register in scope as before
      current_scope.declare(node.name, nil, signature, false, false, nil, :static)
    end
    node.full_type = :Void
  end

  # EXTERN STRUCT Name<T> { fields } [CLOSE "method"] FROM "module"
  # Registers a native Zig/C struct type for CLEAR type-checking.
  # CLOSE makes it a resource type — auto-defer cleanup via RAII.
  sig { params(node: AST::ExternStructDecl).returns(Symbol) }
  def visit_ExternStructDecl(node)
    fields = node.field_decls.transform_keys(&:to_s)
    type_params = node.respond_to?(:type_params) ? node.type_params : nil
    tp = type_params&.any? ? type_params.map(&:to_sym) : nil

    schema = if node.close_method && node.from_module
      Schemas::ResourceSchema.new(
        close_zig: "{0}.#{node.close_method}()",
        fields: fields, type_params: tp,
        extern_module: node.from_module, as_type: node.as_type,
      )
    else
      Schemas::StructSchema.new(
        fields: fields, type_params: tp,
        extern_module: node.from_module, as_type: node.as_type,
      )
    end

    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  sig { params(node: AST::FunctionDef).returns(SymbolEntry) }
  def pre_register_function(node)
    signature = FunctionSignature.new(
      params: node.params.map { |p| AST::Param.new(
        name: p.name,
        type: p.type,
        required: p.default.nil?,
        default: p.default,
        mutable: p.mutable,
        takes: p.takes || false,
        sync: p.type&.any_sync? ? p.type.sync : nil
      )},
      return_type: node.return_type || Type.new(:Any),
      return_lifetime: get_lifetime_path(node),
      visibility: node.visibility,
      reentrant: node.reentrant == :reentrant
    )
    signature.requires = node.requires

    current_scope.declare(
      node.name,
      nil,        # Reg (Unused in Analyzer)
      signature,  # Type Info
      false,      # Mutable?
      false,      # Rebindable?
      nil,        # Size
      :static     # Storage
    )
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
    node.full_type = build_lambda_signature(node.params, T.must(return_type))
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
    # Record in call graph for the later indirect-cycle post-pass.
    @call_graph[node.name]   = called_names - [node.name]
    # Single authority for can_fail propagation: only callees whose error
    # channel is NOT locally terminated (e.g. NOT `f() OR <fallback>`)
    # can propagate failure to this fn. The shared @call_graph keeps
    # every callee (reentrancy / needs_rt need that); this is the subset
    # that actually carries the error channel. (puck-clear-bugs.md #11)
    @fn_propagating_callees[node.name] = (unabsorbed_calls || called_names) - [node.name]
    @fn_has_fnptr[node.name] = has_fnptr

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
      # A), which @call_graph hasn't fully recorded yet at this
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
    node.full_type = signature
    ctx = current_fn_ctx
    node.uses_frame = (ctx.frame_count > 0)
    node.uses_heap  = (ctx.heap_count > 0)
    node.uses_alloc = (ctx.alloc_count > 0)
    node.uses_rt    = ctx.needs_rt
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
    @fn_raises_directly[node.name] =
      (@fn_has_fnptr[node.name] == true) ||
      (node.reentrant == :non_reentrant) ||
      (node.respond_to?(:pre_clauses) && node.pre_clauses && node.pre_clauses.any?) ||
      scan_for_raises(node.body)

    # Visit CATCH clause bodies with __error and snapshot in scope.
    if node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
      # Resolve each parsed clause to a { kind, error_names } pair the
      # lowering can emit directly. Validates every type against the
      # registry and rejects kind mismatches.
      node.catch_clauses.each { |c| resolve_catch_clause!(c) }

      # Collect snapshot types from pipeline steps for typed snapshot access
      snap_types = Set.new
      collect_pipe_input_types(node.body, snap_types)
      node.snapshot_types = snap_types

      all_catch_bodies = node.catch_clauses.map { |c| c.body }
      all_catch_bodies << node.default_catch if node.default_catch.is_a?(Array)
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
    require_relative 'annotator-helpers/with_match_check' unless defined?(WithMatchCheck)
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
        visit(clause[:message]) if clause[:message]
      when :block
        visit_stmts(clause[:body]) if clause[:body]
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
      walk_ast(stmt) do |node|
        if node.is_a?(AST::BinaryOp) && node.op == :SMOOTH
          lhs_type = node.left.respond_to?(:full_type) ? node.left.full_type : nil
          if lhs_type
            t = Type.new(lhs_type)
            types << t.resolved.to_s unless t.void? || t.error_union?
          end
        end
      end
    end
  end

  sig { params(node: T.untyped, block: T.untyped).returns(T.nilable(T::Array[Symbol])) }
  def walk_ast(node, &block)
    block.call(node)
    return unless node.respond_to?(:class) && node.class.respond_to?(:members)
    node.class.members.each do |m|
      val = node.send(m) rescue next
      case val
      when Array then val.each { |v| walk_ast(v, &block) if v.respond_to?(:class) }
      when AST::Locatable then walk_ast(val, &block)
      end
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

  sig { params(node: AST::StructDef).returns(T.nilable(Symbol)) }
  def visit_StructDef(node)
    # Validate generic type parameters (duplicate / builtin-shadow)
    validate_type_param_list!(node, node.type_params, "struct") if node.type_params&.any?

    # A field default's type IS the field's declared type (it must be
    # assignable to it) — not a guess. These default nodes (Literal /
    # DefaultLit) are schema metadata never walked by the expression
    # visitor, so type them here.
    node.field_decls.each do |_, f|
      d = f.default
      next unless d
      # In field-default position the value's type IS the field type;
      # assign unconditionally (overrides a Literal's derived kind).
      d.full_type = f.type.is_a?(Type) ? f.type : Type.new(f.type || :Any)
    end

    schema = Schemas::StructSchema.new(
      fields: node.field_decls,
      type_params: node.type_params&.any? ? node.type_params.map(&:to_sym) : nil,
      visibility: node.visibility || :package,
    )
    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  sig { params(node: AST::EnumDef).returns(Symbol) }
  def visit_EnumDef(node)
    schema = Schemas::EnumSchema.new(
      variants: node.variants.to_set,
      visibility: node.visibility || :package,
    )
    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  sig { params(node: AST::UnionDef).returns(T.nilable(Symbol)) }
  def visit_UnionDef(node)
    # Validate generic type parameters (duplicate / builtin-shadow)
    validate_type_param_list!(node, node.type_params, "union") if node.type_params&.any?

    # Inline struct variants are not supported in generic unions.
    if node.type_params&.any? && node.variants.any? { |_, v| Schemas.inline_struct?(v) }
      error!(node, :UNION_INLINE_IN_GENERIC)
    end

    # Register a synthetic struct schema for each inline struct variant so
    # that MATCH AS bindings (e.g. `Shape.Circle AS c`) can field-access the payload.
    node.variants.each do |var_name, var_data|
      next unless Schemas.inline_struct?(var_data)
      synthetic_name = :"#{node.name}_#{var_name}"
      current_scope.declare_type(synthetic_name, Schemas::StructSchema.new(
        fields: var_data.fields.transform_values { |t| AST::StructField.new(type: t) }))

      # Pre-compute deinit entries for transpiler: which fields need cleanup.
      deinit_entries = []
      var_data.fields.each do |fname, ftype|
        ft = ftype.is_a?(Type) ? ftype : Type.new(ftype || :Any)
        if ft.indirect?
          deinit_entries << { field: fname, kind: :indirect, zig_type: Type.new(ft.resolved).zig_type }
        elsif ft.array? && !ft.string?
          deinit_entries << { field: fname, kind: :array, elem_zig_type: Type.new(ft.element_type).zig_type }
        end
      end
      var_data.deinit_entries = deinit_entries if deinit_entries.any?
    end

    schema = Schemas::UnionSchema.new(
      variants: node.variants,
      type_params: node.type_params&.any? ? node.type_params.map(&:to_sym) : nil,
      visibility: node.visibility || :package,
    )
    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  # Called after Pass 2 (all function signatures registered).
  # Verifies that every method requirement declared inside the UNION body
  # is satisfied by a concrete top-level function with a matching signature.
  sig { params(node: AST::UnionVariantLit).returns(T.nilable(Symbol)) }
  def visit_UnionVariantLit(node)
    schema = lookup_type_schema(node.union_name.to_sym)
    var_data = validate_union_schema!(node, schema)
    validate_union_fields!(node, T.must(var_data).fields)
    node.full_type = node.union_name.to_sym
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
  sig { params(branches: T::Array[Proc], merge_to_parent: T::Boolean).returns(T.nilable(T::Array[T::Array[T::Hash[Symbol, T.untyped]]])) }
  def analyze_control_flow_branches(branches, merge_to_parent: true)
    og_snapshot = @og&.fork_lightweight
    og_branch_snapshots = []
    branch_terminates = []
    all_drops = []

    branches.each do |branch_logic|
      # Restore graph to pre-branch state before analyzing each branch
      @og&.restore_lightweight(og_snapshot) if og_snapshot
      prev_terminated = @branch_terminated
      @branch_terminated = false
      with_new_scope(current_scope) do
        og_push_scope
        all_drops << branch_logic.call
        og_branch_snapshots << (@og&.fork_lightweight)
        branch_terminates << @branch_terminated
        og_pop_scope
      end
      @branch_terminated = prev_terminated
    end

    if merge_to_parent
      # Restore to base, then merge only non-terminating branch results.
      # A terminating branch (RETURN/RAISE) cannot reach the merge point, so
      # its moved states must not poison the post-branch scope.
      @og&.restore_lightweight(og_snapshot) if og_snapshot
      og_branch_snapshots.each_with_index do |snap, i|
        next if branch_terminates[i]
        next unless snap
        # Lightweight merge: just apply moved states
        snap[:node_states].each do |path, saved|
          state = saved.is_a?(Hash) ? saved[:state] : saved
          node = @og.nodes[path]
          next unless node
          if node.state != state
            if state == :moved
              node.state = :moved
              if saved.is_a?(Hash)
                node.move_line = saved[:move_line]
                node.move_col = saved[:move_col]
                node.move_action = saved[:move_action]
              end
            end
          end
        end
      end
    else
      @og&.restore_lightweight(og_snapshot) if og_snapshot
    end

    all_drops
  end

  sig { params(node: AST::BlockExpr).returns(T.nilable(Scope)) }
  def visit_BlockExpr(node)
    with_new_scope(current_scope) do
      node.body.each { |stmt| visit(stmt) }
      visit(node.result)
      node.full_type = node.result.full_type
      node.storage   = node.result.storage
    end
  end

  sig { params(node: AST::IfStatement).returns(T.nilable(Symbol)) }
  def visit_IfStatement(node)
    visit(node.condition)

    branch_logic = [
      proc {
        with_conditional_context { visit_stmts(node.then_branch) }
        finalize_scope(node, branch: :then)
        node.then_drops
      },
      proc {
        with_conditional_context { visit_stmts(node.else_branch) }
        finalize_scope(node, branch: :else)
        node.else_drops
      }
    ]

    analyze_control_flow_branches(branch_logic)

    # Store branch result types so use sites can promote to expression mode.
    node.then_result_type = expr_result_type(node.then_branch)
    node.else_result_type = expr_result_type(node.else_branch)

    node.full_type = :Void
  end

  # Walk through field/index chains to the root binding. Used to determine
  # whether an IF-AS source borrows from a non_escaping binding.
  sig { params(expr: T.untyped).returns(T.nilable(AST::Identifier)) }
  def ifbind_source_root(expr)
    AST.root_identifier(expr)
  end

  sig { params(node: AST::IfBind).returns(Symbol) }
  def visit_IfBind(node)
    # Visit and validate each binding expression.
    node.bindings.each do |b|
      visit(b.expr)
      ti = b.expr.full_type
      unless ti.optional?
        error!(b.expr, :IF_AS_NEEDS_OPTIONAL, got: b.expr.resolved_type)
      end
      # Annotate each binding with the unwrapped type for use in lowering.
      unwrapped = ti.wrapped_type
      # RESOLVE returns ?T@multiowned/shared where the caller owns the strong ref.
      # Propagate ownership so field access auto-derefs through .ctrl.data and
      # the lowering knows to inject rcRelease cleanup.
      if b.expr.is_a?(AST::ResolveNode) && (ti.multiowned? || ti.shared?)
        unwrapped.ownership = ti.ownership
        unwrapped.link_source = ti.link_source
      end
      b.unwrapped_type = unwrapped
    end

    branch_logic = [
      proc {
        # Declare each binding in the then-scope with the unwrapped type.
        node.bindings.each do |b|
          unwrapped = b.unwrapped_type  # always a Type (never nil)
          sym = unwrapped.resolved
          current_scope.declare(b.name, nil, unwrapped, false, false, nil, :stack)
          entry = current_scope.locals[b.name]
          b.symbol = entry
          # Propagate non_escaping when the source is borrow-derived from a
          # non_escaping binding (a WITH alias or another transitive borrow
          # of one). IF-AS on `p[i]` / `p.field` where `p` is the alias
          # makes the new binding a borrow into locked data; it must not
          # escape the enclosing WITH scope either.
          src_root = ifbind_source_root(b.expr)
          if src_root && src_root.symbol&.non_escaping
            entry.non_escaping = true
          end
          classify_ownership!(entry)
          og_declare(b.name.to_s, nil, unwrapped)
        end
        visit_stmts(node.then_branch)
        nil
      },
      proc {
        visit_stmts(node.else_branch)
        nil
      }
    ]

    analyze_control_flow_branches(branch_logic)
    node.full_type = :Void
  end

  # Type-checks a struct destructuring pattern against the match subject type.
  # Verifies field names exist and value types match the struct schema.
  sig { params(match_node: AST::MatchStatement, pat: AST::StructPattern).returns(T.nilable(T::Array[T::Hash[T.untyped, T.untyped]])) }
  def annotate_struct_pattern!(match_node, pat)
    expr_type = match_node.expr.resolved_type
    primitives = [:Float64, :Bool, :Byte, :Int64, :Float64, :String, :NIL, :BOOLEAN, :Any, :Void]

    if primitives.include?(expr_type)
      error!(match_node, :MATCH_NEEDS_STRUCT_TYPE, got: expr_type)
    end

    schema = lookup_type_schema(expr_type)

    pat.fields.each do |f|
      next if f.wildcard?

      if schema
        unless schema.fields.key?(f.name)
          name_tok = f.name_token
          if name_tok
            valid_fields = schema.fields.keys.reject { |k| k.to_s.start_with?("_") }
            emit_typo_suggestion!(
              name_tok, f.name, valid_fields,
              "MATCH struct pattern: field '#{f.name}' does not exist on type #{expr_type}",
              "field of #{expr_type}",
              category: :type, cascade: true
            )
          else
            error!(match_node, :MATCH_FIELD_UNKNOWN, field: f.name, type: expr_type)
          end
        end
      end

      if f.bind?
        # Destructuring bind: declare a local variable with the field's type.
        if schema && schema.fields.key?(f.name)
          field_def = schema.fields[f.name]
          field_type = field_def.is_a?(AST::StructField) ? field_def.type : field_def
          field_type = field_type.is_a?(Type) ? field_type : Type.new(field_type)
          current_scope.declare(f.name, nil, field_type, false, false, nil, :stack)
          og_declare(f.name, nil, field_type)
        end
      else
        visit(f.expr)

        if schema
          field_def = schema.fields[f.name]
          ft = field_def&.type
          field_type = ft.is_a?(Type) ? ft.resolved : ft
          val_type   = f.expr.resolved_type
          is_numeric_promo = (val_type == :Int64 && (field_type == :Float64 || field_type == :Float64))
          unless val_type == field_type || val_type == :Any || field_type == :Any || is_numeric_promo
            error!(match_node, :MATCH_FIELD_TYPE_MISMATCH, field: f.name, declared: field_type, got: val_type)
          end
        end
      end
    end

    # A destructuring pattern's type IS the subject it destructures
    # (the MATCH expr) — not a guess.
    pat.full_type = match_node.expr.full_type_or { Type.new(match_node.expr.resolved_type || :Any) }
    nil # sig: returns(T.nilable(T::Array[...])) — don't leak the Type
  end

  sig { params(node: AST::PassStmt).returns(Symbol) }
  def visit_PassStmt(node)
    node.full_type = :Void
  end

  sig { params(node: AST::MatchStatement).returns(T.nilable(Symbol)) }
  def visit_MatchStatement(node)
    visit(node.expr)

    # Determine whether the subject is an enum or union for exhaustiveness / payload capture
    expr_t    = Type.new(node.expr.resolved_type || :Any)
    node.string_match = true if expr_t.string?
    type_name = expr_t.generic_instance? ? expr_t.generic_base : expr_t.resolved
    schema    = lookup_type_schema(type_name)
    is_enum   = Schemas.enum?(schema)
    is_union  = Schemas.union?(schema)

    # Build type-param substitution for generic union payload capture
    # e.g. Option<Number> → { T: :Float64 }
    union_subst = {}
    if is_union && expr_t.generic_instance? && schema.type_params&.any?
      schema.type_params.zip(expr_t.generic_args).each { |p, a| union_subst[p] = a.resolved }
    end

    # MATCH TAKES: if the source is explicitly consumed (MATCH TAKES expr START),
    # mark the source as moved BEFORE branch analysis. Without TAKES, the source
    # is implicitly borrowed and AS bindings are borrowed views into it.
    #
    # Auto-consume: when an AS binding extracts a non-Copy variant (one with heap
    # data), auto-promote to TAKES semantics. Without this, source and binding
    # share heap data leading to double-free or leak.
    # Auto-TAKES: when ALL cases have AS bindings and the DEFAULT doesn't use
    # the source, the source can be consumed. This prevents heap data sharing
    # between source and extracted binding (double-free/leak).
    auto_takes = T.let(false, T::Boolean)
    if !node.takes && is_union && node.expr.is_a?(AST::Identifier)
      # Check if any AS case extracts a non-Copy payload that would share
      # heap ownership with the source. Strings are Copy in CLEAR, so
      # extracting a string variant doesn't require consuming the source.
      has_non_copy_as = node.cases&.any? { |c|
        next false unless c.binding
        vn = case c.value
             when AST::GetField then c.value.field
             when AST::MethodCall then c.value.name
             end
        next false unless vn
        vt = (schema.variants || {})[vn]
        next false unless vt
        # Inline struct with heap fields: non-Copy (strings/collections/indirect)
        if Schemas.inline_struct?(vt)
          Type.variant_has_heap?(vt)
        else
          # Simple payload: non-Copy if @indirect or a collection/array (not string)
          t = vt.is_a?(Type) ? vt : (Type.new(vt) rescue nil)
          t && (t.indirect? || (!t.string? && (t.collection? || (t.array? && !t.fixed?))))
        end
      }
      if has_non_copy_as
        source_name = node.expr.name
        # Check no case lacks a binding (all cases extract payloads).
        all_cases_bind = node.cases&.all? { |c| c.binding }
        # Check DEFAULT doesn't reference the source value.
        # walk_body only visits statement-level nodes; we need to check
        # expression sub-trees too (e.g. RETURN input; has input inside).
        default_refs_source = T.let(false, T::Boolean)
        if node.default_case
          check_refs = T.let(nil, T.untyped)
          check_refs = lambda { |n|
            next unless n
            if n.is_a?(AST::Identifier) && n.name == source_name
              default_refs_source = true
              next
            end
            # Recurse into common expression wrappers
            check_refs.call(n.value) if n.respond_to?(:value)
            check_refs.call(n.left) if n.respond_to?(:left)
            check_refs.call(n.right) if n.respond_to?(:right)
            check_refs.call(n.condition) if n.respond_to?(:condition) && !n.is_a?(AST::IfStatement)
            n.args&.each { |a| check_refs.call(a) } if n.respond_to?(:args)
          }
          node.default_case.each { |stmt| check_refs.call(stmt) }
        end
        auto_takes = all_cases_bind && !default_refs_source
        auto_takes = false if @og[source_name]&.kind == :borrowed
        # Don't auto-consume if the source is referenced after the MATCH.
        if auto_takes && @stmts_after&.any?
          @stmts_after.each do |s|
            walk_ast(s) do |n|
              if n.is_a?(AST::Identifier) && n.name == source_name
                auto_takes = false
                break
              end
            end
            break unless auto_takes
          end
        end
      end
    end
    if (node.takes || auto_takes) && is_union && node.expr.is_a?(AST::Identifier)
      node.takes = true if auto_takes
      source_name = node.expr.name
      if @og[source_name] && @og[source_name].kind != :borrowed
        node.expr.was_moved = true
        og_set_moved(source_name, at_token: node.expr.token, action: :takes)
      end
    end

    branch_logic = node.cases.map do |c|
      proc {
        if c.kind == :when
          visit(c.value)
          unless c.value.resolved_type == :Bool
            error!(node, :WHEN_NEEDS_BOOL, got: c.value.resolved_type)
          end
        elsif c.kind == :struct_pattern
          annotate_struct_pattern!(node, c.value)
        else
          # Suppress inline-struct "needs braces" error: variant names in MATCH cases are
          # patterns (tag identifiers), not constructors — they don't need field values.
          @match_pattern_context = true
          visit(c.value)
          # Multi-pattern arm: visit + type-check each extra pattern
          # too. A `{ field }` destructure goes through the SAME
          # handler as a single :struct_pattern arm so it is typed
          # (and its binds declared), not just visited.
          c.extra_values&.each do |ev|
            if ev.is_a?(AST::StructPattern)
              annotate_struct_pattern!(node, ev)
            else
              visit(ev)
            end
          end
          @match_pattern_context = false
          expr_t2 = Type.new(node.expr.resolved_type || :Any)
          # Type-check the head pattern, then each extra. Patterns share
          # the arm's body so they must all have the same subject type.
          [c.value, *(c.extra_values || [])].each do |pat|
            case_t2 = Type.new(pat.resolved_type || :Any)
            base_match = expr_t2.generic_instance? && expr_t2.generic_base == pat.resolved_type
            string_match = expr_t2.string? && case_t2.string?
            unless pat.resolved_type == node.expr.resolved_type ||
                   node.expr.resolved_type == :Any ||
                   pat.resolved_type == :Any ||
                   base_match ||
                   string_match
              error!(node, :MATCH_CASE_TYPE_MISMATCH, case: pat.resolved_type, expr: node.expr.resolved_type)
            end
          end
          case_t2 = Type.new(c.value.resolved_type || :Any)

          # Payload capture: `Shape.Circle AS r ->` (or multi-pattern
          # arm: `R.Ok, R.Other AS r ->`). For multi-arm bindings, every
          # variant in the arm must produce a payload of the SAME shape
          # (same payload type, or same inline-struct fields), since one
          # binding `r` is shared across all patterns in the body.
          if c.binding
            if is_enum
              error!(node, :MATCH_ENUM_CAPTURE, binding: c.binding)
            elsif is_union
              variant_name = case c.value
                             when AST::GetField   then c.value.field
                             when AST::MethodCall then c.value.name
                             end
              # Verify each extra variant's payload matches the head's.
              # Apply union_subst before comparing so generic instances
              # (`Mixed<Int64>` where one variant is `T` and another is
              # `Int64`) compare equal post-substitution. Variants are
              # typically stored as Type instances; normalize through
              # `.resolved` to produce a Symbol that can be compared.
              normalize_payload = ->(p) {
                if p.is_a?(Type)
                  sub = union_subst.any? ? apply_type_subst(p, union_subst) : p
                  sub.respond_to?(:resolved) ? sub.resolved : sub
                elsif p.is_a?(Symbol) && union_subst[p]
                  union_subst[p]
                else
                  p
                end
              }
              c.extra_values&.each do |ev|
                ev_name = case ev
                          when AST::GetField   then ev.field
                          when AST::MethodCall then ev.name
                          end
                next unless ev_name && variant_name
                head_payload = normalize_payload.call(schema.variants[variant_name])
                ev_payload   = normalize_payload.call(schema.variants[ev_name])
                if head_payload != ev_payload
                  error!(node, :MATCH_MULTI_ARM_PAYLOAD_MISMATCH,
                    head: variant_name, other: ev_name, kind: 'AS', name: c.binding)
                end
              end
              if variant_name
                raw_payload = schema.variants[variant_name]
                if raw_payload.nil?
                  error!(node, :MATCH_UNIT_CAPTURE, binding: c.binding, variant: variant_name)
                elsif Schemas.inline_struct?(raw_payload)
                  synthetic_type = :"#{type_name}_#{variant_name}"
                  current_scope.declare(c.binding, nil, Type.new(synthetic_type), false, false, nil, :stack)
                  og_declare(c.binding, nil, Type.new(synthetic_type))
                  classify_ownership!(current_scope.locals[c.binding])
                elsif raw_payload.is_a?(Type) && raw_payload.indirect?
                  # @indirect payload: bind to the dereferenced inner type (not the *T pointer).
                  inner_type = raw_payload.dup
                  inner_type.layout = nil
                  inner_type = union_subst.any? ? apply_type_subst(inner_type, union_subst) : inner_type
                  current_scope.declare(c.binding, nil, inner_type, false, false, nil, :stack)
                  og_declare(c.binding, nil, inner_type)
                  classify_ownership!(current_scope.locals[c.binding])
                  c.indirect_payload_as = true  # transpiler must emit subject.Variant.* (deref *T)
                else
                  payload_type = union_subst.any? ? apply_type_subst(raw_payload, union_subst) : Type.new(raw_payload)
                  current_scope.declare(c.binding, nil, payload_type, false, false, nil, :stack)
                  og_declare(c.binding, nil, payload_type)
                  classify_ownership!(current_scope.locals[c.binding])
                end
                # MATCH AS: borrow view into the source union's payload.
                # MATCH TAKES: owned extraction - source is consumed.
                unless node.takes
                  @og[c.binding]&.kind = :borrowed
                end
              end
            end
          end

          # Union variant destructuring: `Result.Ok{ value, count } ->`
          # Declares each named field as a local binding with the correct type.
          # For multi-arm `R.A, R.B { x } ->`, every variant must carry
          # the SAME payload (same inline-struct fields and types) — the
          # destructured names are shared across all patterns' bodies.
          if c.destructure && is_union
            # The destructure pattern's type IS the subject it
            # destructures (the MATCH union expr) — same principle as
            # annotate_struct_pattern!; not a guess. Binds are declared
            # below; this only types the pattern node itself.
            c.destructure.full_type =
              node.expr.full_type_or { Type.new(node.expr.resolved_type || :Any) }
            variant_name = case c.value
                           when AST::GetField   then c.value.field
                           when AST::MethodCall then c.value.name
                           end
            normalize_payload_d = ->(p) {
              if p.is_a?(Type)
                sub = union_subst.any? ? apply_type_subst(p, union_subst) : p
                sub.respond_to?(:resolved) ? sub.resolved : sub
              elsif p.is_a?(Symbol) && union_subst[p]
                union_subst[p]
              else
                p
              end
            }
            c.extra_values&.each do |ev|
              ev_name = case ev
                        when AST::GetField   then ev.field
                        when AST::MethodCall then ev.name
                        end
              next unless ev_name && variant_name
              if normalize_payload_d.call(schema.variants[variant_name]) != normalize_payload_d.call(schema.variants[ev_name])
                error!(node, :MATCH_MULTI_ARM_PAYLOAD_MISMATCH,
                  head: variant_name, other: ev_name, kind: 'destructure', name: '{ ... }')
              end
            end
            if variant_name
              raw_payload = schema.variants[variant_name]
              # Resolve the payload's field schema (inline struct or named type)
              payload_schema = if Schemas.inline_struct?(raw_payload)
                Schemas::StructSchema.new(
                  fields: raw_payload.fields.transform_values { |t| AST::StructField.new(type: t) })
              else
                payload_type_sym = raw_payload.is_a?(Type) ? raw_payload.resolved : raw_payload
                payload_type_sym = union_subst[payload_type_sym] if union_subst[payload_type_sym]
                lookup_type_schema(payload_type_sym)
              end

              if Schemas.struct?(payload_schema)
                c.destructure.fields.each do |f|
                  next unless f.bind?
                  unless payload_schema.fields.key?(f.name)
                    name_tok = f.name_token
                    if name_tok
                      valid_fields = payload_schema.fields.keys.reject { |k| k.to_s.start_with?("_") }
                      emit_typo_suggestion!(
                        name_tok, f.name, valid_fields,
                        "MATCH destructure: field '#{f.name}' is not on variant #{variant_name}",
                        "field of variant #{variant_name}",
                        category: :type, cascade: true
                      )
                    else
                      error!(node, :MATCH_DESTRUCTURE_FIELD_UNKNOWN, field: f.name, variant: variant_name)
                    end
                  end
                  field_def = payload_schema.fields[f.name]
                  field_type = field_def.is_a?(AST::StructField) ? field_def.type : field_def
                  field_type = field_type.is_a?(Type) ? field_type : Type.new(field_type)
                  current_scope.declare(f.name, nil, field_type, false, false, nil, :stack)
                  og_declare(f.name, nil, field_type)
                end
              end
            end
          end
        end
        with_conditional_context { visit_stmts(c.body) }
        collect_scope_drops(node: node)
      }
    end

    if node.default_case
      branch_logic << proc {
        with_conditional_context { visit_stmts(node.default_case) }
        collect_scope_drops(node: node)
      }
    end

    all_drops = analyze_control_flow_branches(branch_logic)

    if node.default_case
      node.default_drops = T.must(all_drops).pop
    end
    node.case_drops = all_drops

    # Duplicate-pattern detection (enum/union only). A variant repeated
    # across arms — or twice in a single multi-pattern arm — would
    # produce invalid Zig (`.A, .A => ...` or two `.A` prongs); catch
    # at annotate-time so the error names the user-side mistake.
    if is_enum || is_union
      seen = {}
      node.cases.each do |c|
        next if c.kind == :when || c.kind == :struct_pattern
        [c.value, *(c.extra_values || [])].each do |pat|
          name = case pat
                 when AST::GetField   then pat.field
                 when AST::MethodCall then pat.name
                 end
          next unless name
          if seen[name]
            error!(node, :MATCH_DUPLICATE_PATTERN, variant: name)
          end
          seen[name] = true
        end
      end
    end

    # Exhaustiveness check — enforced for plain MATCH (the default).
    # PARTIAL MATCH bypasses these checks and allows DEFAULT, WHEN, and
    # non-enum/union subjects.
    if node.exhaustive
      # MATCH requires an enum or union subject. Non-discriminated types
      # (Int64, String, ...) can never be statically exhaustive; the user
      # must opt in to PARTIAL MATCH.
      unless is_enum || is_union
        type_label = expr_t.resolved
        emit_match_partial_fix!(node, :MATCH_NEEDS_ENUM_OR_UNION, type: type_label)
      end

      # MATCH forbids DEFAULT — the whole point of an exhaustive MATCH is
      # that every variant is explicitly named. If you want a fallback,
      # write `PARTIAL MATCH`.
      if node.default_case
        error!(node, :MATCH_FORBIDS_DEFAULT)
      end

      # MATCH forbids WHEN guards — they're runtime conditions that break
      # static exhaustiveness. Use `PARTIAL MATCH` for guard-style cases.
      if node.cases.any? { |c| c.kind == :when }
        error!(node, :MATCH_FORBIDS_WHEN)
      end

      # Every variant must appear exactly once. Multi-pattern arms
      # contribute one entry per pattern so they count toward
      # exhaustiveness like single arms would.
      covered = node.cases.flat_map do |c|
        names = []
        [c.value, *(c.extra_values || [])].each do |pat|
          name = case pat
                 when AST::GetField   then pat.field
                 when AST::MethodCall then pat.name
                 end
          names << name if name
        end
        names
      end.to_set

      all_variants = is_enum ? schema.variants : schema.variants.keys.to_set
      missing = all_variants - covered
      unless missing.empty?
        type_label2 = is_enum ? "enum" : "union"
        emit_match_partial_fix!(node, :MATCH_NON_EXHAUSTIVE,
          kind: type_label2, name: type_name, missing: missing.sort.join(', '))
      end
    end

    # Store case result types so use sites can promote to expression mode.
    node.case_result_types = node.cases.map { |c| expr_result_type(c.body) }
    node.default_result_type = expr_result_type(node.default_case)

    node.full_type = :Void
  end

  sig { params(node: AST::ForRange).returns(T.nilable(Symbol)) }
  def visit_ForRange(node)
    # 1. Type-check range bounds
    visit(node.start_expr)
    visit(node.end_expr)
    start_type = node.start_expr.resolved_type
    end_type   = node.end_expr.resolved_type
    error!(node, :FOR_RANGE_START_NEEDS_INT64, got: start_type) unless start_type == :Int64
    error!(node, :FOR_RANGE_END_NEEDS_INT64, got: end_type) unless end_type == :Int64

    # 2. Analyze body in new scope with loop variable declared as immutable Int64
    if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end
    analyze_control_flow_branches([
      proc {
        current_scope.declare(node.var_name, nil, :Int64, false, false, nil, :stack)
        node.symbol = current_scope.locals[node.var_name]
        classify_ownership!(node.symbol)
        visit_stmts(node.body)
        finalize_scope(node)
        node.deferred_drops
      }
    ], merge_to_parent: false)
    if current_fn_ctx then current_fn_ctx.loop_depth -= 1 else @loop_depth -= 1 end

    # 4. TIGHT validation (same as WhileLoop).
    if node.tight
      validate_tight_body!(node.body, node)
    end

    # mark_per_iter is set by LoopFrameAnalysis in Pass 2, after CleanupClassifier
    # has finalized every binding's allocator.
    node.mark_per_iter = false

    node.full_type = :Void
  end

  sig { params(node: AST::ForEach).returns(T.nilable(Symbol)) }
  def visit_ForEach(node)
    # 1. Visit collection to determine element type
    visit(node.collection)
    coll_type = node.collection.full_type
    ct = coll_type.is_a?(Type) ? coll_type : Type.new(coll_type)

    # Determine element type from collection
    elem_type = if ct.array? || ct.list_collection?
      ct.element_type || ct.value_type || :Any
    elsif ct.map?
      # FOR k IN map iterates over keys (strings)
      :String
    else
      error!(node, :FOR_IN_NEEDS_COLLECTION, got: coll_type)
    end

    elem_sym = elem_type.is_a?(Type) ? elem_type.resolved : elem_type

    # 2. Analyze body with loop variable
    if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end
    analyze_control_flow_branches([
      proc {
        current_scope.declare(node.var_name, nil, elem_sym, node.is_mutable == true, false, nil, :stack)
        node.symbol = current_scope.locals[node.var_name]
        classify_ownership!(node.symbol)
        visit_stmts(node.body)
        finalize_scope(node)
        node.deferred_drops
      }
    ], merge_to_parent: false)
    if current_fn_ctx then current_fn_ctx.loop_depth -= 1 else @loop_depth -= 1 end

    node.full_type = :Void
  end

  sig { params(node: AST::WhileLoop).returns(T.nilable(Symbol)) }
  def visit_WhileLoop(node)
    # 1. Analyze Condition
    visit(node.condition)

    if node.condition.resolved_type != :Bool
      error!(node, :CONDITION_NEEDS_BOOL, got: node.condition.resolved_type)
    end

    # Effect tracking: WHILE TRUE or any non-trivially-bounded loop.
    if node.condition.is_a?(AST::Identifier) && node.condition.name == "TRUE"
      record_effect(EffectTracker::LOOP_UNBOUND)
    elsif node.condition.is_a?(AST::Literal) && node.condition.value == true
      record_effect(EffectTracker::LOOP_UNBOUND)
    end

    # 2. Analyze Body in a New Scope AND increment loop depth
    if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end

    # We use analyze_control_flow_branches to handle state merging and drops.
    # Note: For a loop, if a variable dies in the body, it dies for the next iteration (merged to parent).
    pre_loop_states = @og&.fork_lightweight

    analyze_control_flow_branches([
      proc {
        if node.do_branch.is_a?(Array)
          visit_stmts(node.do_branch)
        else
          visit(node.do_branch)
        end
        finalize_scope(node)

        # Post-analysis check for loop-specific errors (use of moved value in next iteration)
        # Copyable types (primitives, strings, slices, unions) are exempt — they're copied implicitly.
        # Variables not referenced in the loop body are also exempt — they were moved before the
        # loop (e.g. MATCH struct bindings with field extraction) and aren't consumed by iteration.
        loop_body_names = collect_body_identifier_names(node.do_branch)
        current_scope.locals.each do |name, _entry|
          saved = pre_loop_states&.dig(:node_states, name)
          was_live = (saved.is_a?(Hash) ? saved[:state] : saved) == :live
          is_moved = @og&.moved?(name)
          if was_live && is_moved
            next unless loop_body_names.include?(name)
            var_type = current_scope.locals[name]&.type
            type_obj = var_type.is_a?(Type) ? var_type : Type.new(var_type.to_s)
            is_copy = type_obj.implicitly_copyable? { |t| lookup_type_schema(t) }
            unless is_copy
              emit_use_of_moved_in_loop_error!(node, name, @og&.[](name), code: :USE_OF_MOVED_IN_LOOP)
            end
          end
        end
        node.deferred_drops
      }
    ], merge_to_parent: false)

    if current_fn_ctx then current_fn_ctx.loop_depth -= 1 else @loop_depth -= 1 end

    # 4. TIGHT validation: deep-scan the entire loop body AST (including nested
    # if/while/match blocks) for direct calls to @reentrant or EXTERN FN functions.
    # Does NOT recurse into bodies of called CLEAR functions — those are separate
    # compilation units and their internal behaviour is their own concern.
    if node.tight
      validate_tight_body!(node.do_branch, node)
    end

    # mark_per_iter is set by LoopFrameAnalysis in Pass 2, after CleanupClassifier
    # has finalized every binding's allocator.
    node.mark_per_iter = false

    node.full_type = :Void
  end

  sig { params(node: AST::WhileBindLoop).returns(T.nilable(Symbol)) }
  def visit_WhileBindLoop(node)
    visit(node.condition)
    ti = node.condition.full_type
    unless ti&.optional?
      error!(node.condition, :WHILE_AS_NEEDS_OPTIONAL, got: node.condition.resolved_type)
    end

    unwrapped = ti.wrapped_type
    if node.condition.is_a?(AST::ResolveNode) && (ti.multiowned? || ti.shared?)
      unwrapped.ownership = ti.ownership
      unwrapped.link_source = ti.link_source
    end

    if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end

    pre_loop_states = @og&.fork_lightweight

    # Footgun guard: a MethodCall on an immutable receiver cannot advance the
    # loop condition and will loop forever.  RESOLVE is a ResolveNode (not a
    # MethodCall) and is safe; mutable receivers may mutate state each iteration.
    cond = node.condition
    if cond.is_a?(AST::MethodCall)
      recv = cond.object
      if recv.is_a?(AST::Identifier) && current_scope.is_immutable?(recv.name)
        error!(node, :WHILE_AS_IMMUTABLE_RECEIVER, method: cond.name, recv: recv.name, recv2: recv.name)
      end
    end

    analyze_control_flow_branches([
      proc {
        current_scope.declare(node.binding_name, nil, unwrapped, false, false, nil, :stack)
        entry = current_scope.locals[node.binding_name]
        classify_ownership!(entry)
        og_declare(node.binding_name.to_s, nil, unwrapped)

        visit_stmts(node.do_branch)
        finalize_scope(node)

        loop_body_names = collect_body_identifier_names(node.do_branch)
        current_scope.locals.each do |name, _entry|
          next if name == node.binding_name
          saved = pre_loop_states&.dig(:node_states, name)
          was_live = (saved.is_a?(Hash) ? saved[:state] : saved) == :live
          is_moved = @og&.moved?(name)
          if was_live && is_moved
            next unless loop_body_names.include?(name)
            var_type = current_scope.locals[name]&.type
            type_obj = var_type.is_a?(Type) ? var_type : Type.new(var_type.to_s)
            is_copy = type_obj.implicitly_copyable? { |t| lookup_type_schema(t) }
            unless is_copy
              emit_use_of_moved_in_loop_error!(node, name, @og&.[](name), code: :USE_OF_MOVED_IN_LOOP_SHORT)
            end
          end
        end
        node.deferred_drops
      }
    ], merge_to_parent: false)

    if current_fn_ctx then current_fn_ctx.loop_depth -= 1 else @loop_depth -= 1 end

    node.mark_per_iter = false
    node.full_type = :Void
  end

  # Deep validation for TIGHT loops.
  # Walks the full AST subtree (nested ifs, whiles, match blocks) looking for
  # any call to a @reentrant or EXTERN FN function. Stops at FunctionDef
  # boundaries — nested lambdas/closures are separate compilation units.
  sig { params(node: AST::BreakNode).returns(T.nilable(Symbol)) }
  def visit_BreakNode(node)
    if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
      error!(node, :BREAK_OUTSIDE_LOOP)
    end
    node.full_type = :Void
  end

  sig { params(node: AST::ContinueNode).returns(T.nilable(Symbol)) }
  def visit_ContinueNode(node)
    if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
      error!(node, :CONTINUE_OUTSIDE_LOOP)
    end
    node.full_type = :Void
  end

  sig { params(node: AST::Assert).returns(T.nilable(Symbol)) }
  def visit_Assert(node)
    visit(node.condition)
    if node.condition.resolved_type != :Bool
       error!(node, :ASSERT_NEEDS_BOOL)
    end
    # Optional: check message type if it exists
    node.full_type = :Void
  end

  # Test-grammar visitors (visit_TestBlock, visit_WhenBlock,
  # visit_TestThat, visit_AssertRaises, visit_BenchmarkStmt,
  # visit_SmashStmt, visit_ProfileStmt, visit_StubDecl) are mixed in
  # from annotator-helpers/test_annotation.rb.

  sig { params(node: AST::DieNode).returns(Symbol) }
  def visit_DieNode(node)
     # Usually takes an integer status code
     visit(node.status) if node.status
     node.full_type = :NoReturn # Special type indicating execution stops
  end

  sig { params(node: AST::Raise).returns(T.nilable(T::Boolean)) }
  def visit_Raise(node)
    visit(node.message_expr) if node.message_expr
    resolve_error_registration!(node, node.kind, node.error_name, node.token)
    node.full_type = :NoReturn # Raises propagate up or are caught
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

      node.full_type = :Void
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
             type: node.value.full_type_or("BG handle"),
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
      vti = node.value.full_type
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
      if (expected.heap? || expected.dynamic?) &&
         node.value.respond_to?(:storage=) &&
         node.value.full_type.requires_move?
        node.value.storage = :heap
      end
    end

    # Auto returns are resolved after the body walk, so strict equality here
    # would reject valid programs before the unifier has run.
    actual_is_auto = actual_full.respond_to?(:auto?) && actual_full.auto?
    expected_is_auto = expected.auto?

    if !actual_is_auto && !expected_is_auto && expected != :Void && expected != :Any && !return_type_compatible?(actual_full, expected)
      error!(node, :RETURN_MISMATCH, expected: type_display(expected), got: type_display(actual_full))
    elsif !actual_is_auto && !expected_is_auto && expected != :Void && expected != :Any && actual != expected
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
        (begin
           rt = node.value.respond_to?(:resolved_type) ? node.value.resolved_type : nil
           rt ? Type.new(rt).error_union? : false
         rescue StandardError
           false
         end)
      coerce_target =
        if !value_is_fallible && expected.respond_to?(:error_union?) && expected.error_union? &&
           expected.respond_to?(:payload_type) && expected.payload_type
          expected.payload_type
        else
          expected
        end
      node.value.coerced_type = coerce_target  # Don't coerce EXPLICIT returns
      check_prefixed_int_range!(node.value, coerce_target)
    end

    node.full_type = actual

    if current_fn_ctx
      current_fn_ctx.returns << {storage: node.value.storage, type: actual, metatype: node.value.metatype}
    end

    @branch_terminated = true
  end

  sig { params(value: T.untyped).returns(Type) }
  def return_value_type(value)
    ti = value.respond_to?(:full_type) ? value.full_type : nil
    return ti if ti.is_a?(Type)
    Type.new(value.resolved_type || :Any)
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

    ownership = case t.ownership
    when :multiowned then "@multiOwned"
    when :shared then "@shared"
    when :split then "@split"
    when :link then "@link"
    when :frozen then "@frozen"
    end
    parts << ownership if ownership

    sync = case t.sync
    when :locked then "@locked"
    when :write_locked then "@writeLocked"
    when :versioned then "@versioned"
    when :atomic then "@atomic"
    when :always_mutable then "@alwaysMutable"
    when :local then "@local"
    end
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

  sig { params(node: AST::StaticCall).void }
  def visit_StaticCall(node)
    node.args.each { |arg| visit(arg) }

    # `File` in `File::open(...)` is a TYPE reference, not a runtime
    # value. The codebase's established marker for a type-position
    # identifier is :Type (cf. comptime type args in function_analysis)
    # — not a guess.
    node.type_name.full_type = Type.new(:Type)

    type_name = node.type_name.name.to_sym
    schema    = lookup_type_schema(type_name)

    unless schema
      error!(node, :STATIC_UNKNOWN_TYPE, type: type_name)
    end

    unless schema.kind == :resource
      error!(node, :STATIC_NOT_RESOURCE, type: type_name)
    end

    static_methods = schema.static_methods || {}
    method_def     = IntrinsicRegistry.sig(static_methods, T.unsafe(node).method_name)

    unless method_def
      available = static_methods.keys.join(", ")
      available = "(none)" if available.empty?
      method_tok = node.type_name.token
      # Method name starts at `TypeName::` + 2 (the `::`).
      if method_tok
        anchor = anchor_at(
          method_tok.line,
          method_tok.column + node.type_name.name.to_s.length + 2
        )
        emit_typo_suggestion!(
          anchor, node.method_name, static_methods.keys,
          "Type Error: No static method '#{node.method_name}' on '#{type_name}'. Available: #{available}.",
          "static method of #{type_name}",
          category: :type, cascade: true
        )
      else
        error!(node, :STATIC_UNKNOWN_METHOD, method: node.method_name, type: type_name, available: available)
      end
      return
    end

    expected_args = method_def.arg_spec
    if node.args.length != expected_args.length
      error!(node, :STATIC_ARITY, type: type_name, method: node.method_name, expected: expected_args.length, got: node.args.length)
    end

    node.args.zip(expected_args).each_with_index do |(arg, expected), i|
      actual = arg.resolved_type
      unless expected == :Any || actual == :Any || is_safe_autocast?(actual, expected)
        error!(node, :STATIC_ARG_TYPE, index: i + 1, type: type_name, method: node.method_name, expected: expected, got: actual)
      end
    end

    node.zig_pattern = method_def.emit&.zig
    node.full_type   = method_def.return_def.resolve(nil, node.args, self)
    node.matched_stdlib_def = method_def
    node.stdlib_allocates = true if method_def.emit&.allocates
    node.mutates_receiver = true if method_def.emit&.mutates_receiver
    node.can_fail = true if method_def.can_fail
    node.error_kind = method_def.emit&.error_kind if method_def.emit&.error_kind
    node.error_type = method_def.emit&.error_type if method_def.emit&.error_type
    current_fn_ctx.alloc_count += 1 if current_fn_ctx && (method_def.emit&.allocates || method_def.can_fail)

    if method_def.emit&.mutates_receiver && node.is_a?(AST::MethodCall)
      root = chain_root_name(node.object)
      mark_var_mutated(root) if root
    end
  end

  sig { params(node: AST::FuncCall).returns(T.nilable(T::Array[T::Hash[Symbol, T.untyped]])) }
  def visit_FuncCall(node)
    # Mark struct literal args as call arguments so ensure_owned_value!
    # skips CopyNode wrapping for rodata strings. The struct is a temporary
    # argument - rodata strings are valid for the call's lifetime. The callee
    # dupes strings it needs to escape via promoteFields.
    node.args.each { |arg| arg.instance_variable_set(:@is_call_arg, true) if arg.is_a?(AST::StructLit) }
    node.args.each { |arg|
      visit(arg)
      promote_to_expr_if!(node, arg) if arg.is_a?(AST::IfStatement)
      promote_to_expr_match!(node, arg) if arg.is_a?(AST::MatchStatement)
    }

    if node.name == "native_call"
      node.full_type = :Any
      return
    end

    resolve_call(node, node.args)
    record_predicate_call_site!(node)

    # Record call-site context (loop/cond) for effects propagation.
    # A call sitting inside a loop promotes the callee's SUSPENDS effects
    # to SUSPENDS_LOOP; likewise for conditional.
    record_call_site(node.name) if node.name.is_a?(String)

    # Effect propagation needs the actual sync family passed at each call
    # site so ?-form effects can collapse to concrete effects or no effect.
    if node.args && !node.args.empty? && node.name.is_a?(String)
      require_relative 'annotator-helpers/with_match_check' unless defined?(WithMatchCheck)
      arg_family_sets = node.args.map { |a| WithMatchCheck.family_of_arg_set(a) }
      node.arg_families = arg_family_sets
      record_call_arg_families(node.name, arg_family_sets) if current_fn_ctx&.name

      # Error unions narrow at the call site based on the actual binding
      # families, not just the callee's declared family set.
      sig = FunctionSignature.unwrap(@scope_stack.first.locals[node.name]&.type) if node.name.is_a?(String)
      if sig && sig.requires && !sig.requires.empty?
        node.collapsed_errors = collapse_errors_for_call(sig, node.args)
      end

      # Plain-T auto-borrow stamping waits for finalized REQUIRES in
      # WithMatchCheck.check_call_sites!.
    end

    # Held-lock call sites become graph edges after callee lock acquires have
    # propagated through the call graph.
    if @held_lock_types && !@held_lock_types.empty? && @fn_nodes.key?(node.name)
      fn_name = current_fn_ctx&.name || "<top>"
      record_held_call!(fn_name, node.name, @held_lock_types, node.token)
    end
  end

  sig { params(node: AST::MethodCall).returns(T.nilable(T::Hash[Symbol, T::Boolean])) }
  def visit_MethodCall(node)
    visit(node.object)
    node.args.each { |arg| visit(arg) }

    # Collection method dispatch (Pool/HashMap) via declarative registry.
    if resolve_collection_method(node)
      record_predicate_call_site!(node)
      return
    end

    # EXTERN method dispatch: check if the object's type has EXTERN methods registered.
    obj_type = node.object.full_type
    if obj_type
      resolved = obj_type.is_a?(Type) ? obj_type.resolved : obj_type.to_s.to_sym
      # Check for generic instance: Parsed<MyDoc> → base type Parsed
      base = obj_type.is_a?(Type) && obj_type.generic_instance? ? obj_type.generic_base : resolved
      type_schema = lookup_type_schema(base)
      if (Schemas.struct?(type_schema) || Schemas.resource?(type_schema)) && type_schema.methods&.key?(node.name)
        method_sig = type_schema.methods[node.name]
        node.extern_call = true
        node.extern_effects = method_sig.extern_effects if method_sig.extern_effects
        node.instance_variable_set(:@extern_method, true)
        node.full_type = method_sig.return_type
        record_effect(EffectTracker::EXTERN)
        # Track allocator usage for EFFECTS :alloc methods.
        alloc_kind = method_sig.extern_effects&.dig(:alloc)
        if alloc_kind && current_fn_ctx
          if alloc_kind == :heap
            current_fn_ctx.heap_count += 1
          else
            current_fn_ctx.frame_count += 1
          end
        end
        record_predicate_call_site!(node)
        return
      end
    end

    # Intrinsic method dispatch: prefer a STD_LIB `is_method: true`
    # overload whose first arg matches the receiver's type over UFCS
    # resolution. This makes `s.length()` call String's intrinsic
    # `length` even when the user has defined a free function named
    # `length` with a different signature — UFCS would otherwise
    # silently rewrite to `length(s)`, hit the user's function, and
    # produce a confusing arg-type-mismatch error against the user's
    # parameter type.
    intrinsic_defs = STD_LIB[node.name]
    if intrinsic_defs
      intrinsic_defs = [intrinsic_defs] if intrinsic_defs.is_a?(Hash)
      method_overloads = intrinsic_defs.select { |d| d[:is_method] }
      if method_overloads.any?
        ufcs_args = [node.object] + node.args
        if find_matching_intrinsic(method_overloads, ufcs_args)
          visit_IntrinsicFunc(node, ufcs_args)
          record_predicate_call_site!(node)
          return
        end
      end
    end

    # Fall through to UFCS: obj.method(args) → method(obj, args)
    ufcs_args = [node.object] + node.args
    resolve_call(node, ufcs_args)
    record_predicate_call_site!(node)

    # Record call-site context for effects propagation (see visit_FuncCall).
    record_call_site(node.name) if node.name.is_a?(String)
  end

  # Shared logic for resolving function/method calls.
  # Handles intrinsics, user-defined functions, and lambdas uniformly.
  #
  # @param node [AST::FuncCall, AST::MethodCall] The call node
  # @param args [Array] The arguments (includes receiver for UFCS method calls)
  # Handles intrinsic function calls by finding the matching overload and
  # using verify_function_signature! for validation (same as user-defined functions).
  #
  # @param node [AST::FuncCall, AST::MethodCall] The call node
  # @param args [Array] The arguments (includes receiver for method calls - UFCS)
  sig { params(node: T.untyped, args: T::Array[T.untyped]).returns(T.nilable(Type)) }
  def visit_IntrinsicFunc(node, args)
    definitions = STD_LIB[node.name]
    definitions = [definitions] if definitions.is_a?(Hash)

    # 1. Find matching overload (needed for polymorphic intrinsics like 'length')
    matched_def = find_matching_intrinsic(definitions, args)

    unless matched_def
      sigs = definitions.map { |d| format_intrinsic_args(d[:args]) }.join(" or ")
      arg_types = args.map { |a| a.resolved_type }.join(", ")
      error!(node, :INTRINSIC_NO_OVERLOAD, name: node.name, args: arg_types, candidates: sigs)
      return
    end

    # 2. Normalize to standard signature format and verify
    signature = normalize_intrinsic_signature(matched_def)

    if signature
      # Create a synthetic node with the full args (for UFCS method calls,
      # node.args doesn't include the receiver, but args does)
      call_node = Struct.new(:token, :name, :args).new(node.token, node.name, args)
      verify_function_signature!(call_node, signature)
    end
    # Varargs functions skip verify_function_signature! (arity is flexible)

    # 2b. Registry-driven reject predicates. `reject_when:` names a
    # type-shape that the receiver must NOT have for this overload to
    # be applicable. Used for "always nonsense" calls like
    # `u32_val.negative?()` where Int64 autocast would otherwise mask
    # the bug. Generic — keyed by symbol so std_lib.rb stays
    # declarative and annotator.rb has no per-function logic.
    if matched_def.emit&.reject_when && reject_arg_type_matches?(args.first, matched_def.emit.reject_when)
      reason = matched_def.emit&.reject_error ||
               "#{node.name}() is not valid for #{args.first.resolved_type}"
      error!(node, :INTRINSIC_REJECTED, message: reason)
      return
    end

    # 3. Resolve return type (may be dynamic via method call).
    # Dynamic resolver methods are named `infer_*` to avoid collisions with
    # Ruby Kernel conversion methods (Integer, String, Array, etc.).
    node.full_type = matched_def.return_def.resolve(nil, args, self)

    # 4. Store Zig pattern and stdlib metadata for transpiler
    node.zig_pattern = matched_def.emit&.zig
    node.matched_stdlib_def = matched_def
    node.stdlib_allocates = true if matched_def.emit&.allocates
    node.mutates_receiver = true if matched_def.emit&.mutates_receiver
    node.can_fail = true if matched_def.can_fail || matched_def.emit&.allocates
    node.error_kind = matched_def.emit&.error_kind if matched_def.emit&.error_kind
    node.error_type = matched_def.emit&.error_type if matched_def.emit&.error_type
    current_fn_ctx.alloc_count += 1 if current_fn_ctx && (matched_def.emit&.allocates || matched_def.can_fail || matched_def.needs_rt)
    record_effect(EffectTracker::SUSPENDS) if matched_def.emit&.suspends

    # 5. Flag mutable access through list indexing.
    #    When a mutating intrinsic (e.g., append, remove) is called on a receiver
    #    that chains through a GetIndex, the GetIndex must emit pointer access
    #    instead of by-value getAt().
    if matched_def.emit&.mutates_receiver && node.is_a?(AST::MethodCall)
      mark_chain_needs_mut_ref!(node.object)
      root = chain_root_name(node.object)
      mark_var_mutated(root) if root
    end

    # 6. Collection type narrowing (e.g., append narrows Any[] → T[])
    narrow_collection_type!(matched_def, args)
    # Ownership for TAKES args (e.g., append value) is handled uniformly
    # by verify_function_signature! via the takes: true flag in STD_LIB.
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
  sig { params(node: AST::VarDecl).void }
  def visit_VarDecl(node)
    if node.value.is_a?(AST::ListLit) && node.type&.fixed?
      node.value.storage = :stack
    end
    visit(node.value)
    promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
    promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)
    finalize_decl_node!(node, node.mutable)
    stamp_init_contents_heap!(node)
    stamp_bg_handle_lifetime!(node)
  end

  # Shared declaration body used by visit_VarDecl and the declaration path of
  # visit_BindExpr. mutable_flag is node.mutable for VarDecl and false for BindExpr
  # (BindExpr declarations are immutable by default).
  # Pipeline-terminal observable detection. When the bind site has shape:
  #
  #   running: ~Int64@observable = stream |> SUM _;
  #
  # The pipe's apparent scalar type has to be lifted to the LHS observable
  # type so coerce! accepts the assignment and codegen chooses the
  # accumulator path instead of an inline fold.
  sig { params(node: T.untyped).returns(T.nilable(Type)) }
  def promote_pipe_to_observable_dest!(node)
    return unless node.respond_to?(:type) && node.type
    return unless node.value
    target = node.type
    return unless target.future? && target.observable?
    pipe = node.value
    return unless pipe.is_a?(AST::BinaryOp) && pipe.op == :SMOOTH
    return unless pipe.observable_terminal
    pipe.observable_dest = true
    # Preserve the terminal kind set by lift_to_observable_if_terminal!.
    # The LHS annotation (`~Int64@observable`) carries no terminal info;
    # only the fold's analyzer knows whether this is :sum/:count/:max/...
    # Copying it onto node.type also propagates the kind to the binding's
    # symbol entry (so WITH VIEW / NEXT / cleanup all see it).
    if pipe.full_type.observable_terminal
      pipe_terminal = pipe.full_type.observable_terminal
      target_t = node.type
      # The pipe is the authority on terminal kind: only the fold's
      # analyzer knows whether this is :sum / :count / :max / ... .
      # The LHS annotation (`~Int64@observable`) never carries one, so
      # an existing non-nil stamp here means a prior pass disagreed
      # with the analyzer. Reject loudly instead of silently winning
      # one of the two via `||=` (H7).
      if target_t.observable_terminal && target_t.observable_terminal != pipe_terminal
        raise CompilerError.new(
          node.token,
          "Observable terminal mismatch: LHS stamped #{target_t.observable_terminal.inspect}, " \
          "pipe analyzer produced #{pipe_terminal.inspect}",
          nil,
        )
      end
      target_t.observable_terminal = pipe_terminal
      node.type = target_t
      # node.full_type is the resolved Type read by mir_lowering's
      # transpile_type; propagate the terminal kind there too so
      # OBSERVABLE_WRAPPERS can find it. Without this, the binding's
      # emitted Zig wrapper would default-or-raise. Same mismatch
      # check as above.
      if node.full_type.observable?
        if node.full_type.observable_terminal && node.full_type.observable_terminal != pipe_terminal
          raise CompilerError.new(
            node.token,
            "Observable terminal mismatch on full_type: stamped " \
            "#{node.full_type.observable_terminal.inspect}, pipe produced #{pipe_terminal.inspect}",
            nil,
          )
        end
        node.full_type.observable_terminal = pipe_terminal
      end
    end
    pipe.full_type = node.type
  end

  sig { params(node: T.untyped, mutable_flag: T::Boolean).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def finalize_decl_node!(node, mutable_flag)
    verify_unrestricted!(node)
    handle_assign_move(node)
    handle_assign_borrow(node)

    validate_type_annotation!(node, node.type) if node.type
    validate_stream_type!(node)

    promote_pipe_to_observable_dest!(node)

    # An `~T@observable` binding has no usable shape unless it was
    # initialized by a fold-pipe over a tense stream: the
    # heap-allocated wrapper, the producer fiber, and the WaitGroup
    # bridge are all created in lower_range_fold_observable_default.
    # A bare `running: ~Int64@observable` (no initializer) or one
    # initialized from another value would dangle: no producer fiber
    # exists, NEXT/COLLECT would deadlock, and the cleanup recipe
    # would call destroy() on an uninitialized struct. Reject here
    # before downstream passes see the bad shape. The post-promote
    # check is correct because promote_pipe_to_observable_dest! sets
    # `observable_dest` only when the RHS is a SMOOTH-pipe over a
    # tense source; any other shape leaves it false.
    if node.type&.future? && node.type.observable?
      pipe = node.value
      ok = pipe.is_a?(AST::BinaryOp) && pipe.op == :SMOOTH && pipe.observable_dest
      unless ok
        msg = "`~T@observable` bindings must be initialized by a pipeline-terminal fold " \
              "over a tense stream (e.g. `running: ~Int64@observable = stream |> SUM _`). " \
              "The producer fiber, atomic accumulator, and WaitGroup wiring all live in " \
              "the fold's codegen path -- a bare declaration or a non-fold initializer has " \
              "no producer, so NEXT/COLLECT would deadlock and cleanup would touch an " \
              "uninitialized wrapper."

        # Offer a fixable that drops `@observable` from the type
        # annotation. When the parser captured a token for the
        # `@observable` capability, we can target it precisely. If the
        # capability was chained (`~Int64@locked:observable` → token's
        # value is `:observable` rather than `@observable`), we span
        # the colon-prefix; otherwise the token is `@observable`. This
        # lands as :interactive (not :auto) because the user almost
        # always wanted a fold-pipe initializer instead — dropping
        # @observable changes the type semantics. We only offer the
        # drop fix; the "add a fold-pipe initializer" alternative is
        # too context-specific to template.
        fixes = []
        obs_tok = node.type.observable_token if node.type.respond_to?(:observable_token)
        if obs_tok
          # Token value is `@observable` (first cap) or `:observable`
          # (chained after another cap). Match length to the actual
          # token text so the edit deletes exactly the right span.
          tok_text = obs_tok.value.to_s
          fixes << Fix.new(
            description: "Drop `#{tok_text}` from the binding's type annotation. The remaining type behaves as a regular binding (no producer fiber, no WITH VIEW); use this if you didn't actually want streaming-aggregate semantics.",
            confidence: :interactive,
            edits: [Edit.new(
              span: Span.new(file: nil, line: obs_tok.line, col: obs_tok.column, length: tok_text.length),
              replacement: "",
            )],
          )
        end

        return error!(node, :VARDECL_TYPE_MISMATCH_FIXABLE, message: msg) if fixes.empty?
        fixable!(node, message: msg, category: :type, level: :error,
                 fixes: fixes, raise_in_collector: false)
      end
    end

    final_type, error = node.value.coerce!(node.type)
    error!(node, :TYPE_COERCION_FAILED, message: error) if error

    # Empty collection literals annotated as Auto need a permissive
    # container type in scope so method dispatch works during the body walk;
    # the declaration annotation remains Auto for the later constraint pass.
    if node.type&.auto? &&
       node.value.respond_to?(:type_object) && node.value.type_object &&
       (
         (node.value.is_a?(AST::ListLit) && node.value.items.empty? &&
          !node.value.instance_variable_get(:@constructor_collection)) ||
         (node.value.is_a?(AST::HashLit) && node.value.pairs.empty?)
       )
      final_type = node.value.type_object
    end

    check_prefixed_int_range!(node.value, node.value.coerced_type || final_type)
    propagate_declared_type_to_value!(node, final_type)

    storage = finalize_decl_storage!(node, final_type)
    propagate_collection_metadata!(node, final_type)
    propagate_call_flags!(node)
    set_cleanup_alloc!(node)
    # The symbol is born with the annotation-derived placement only.
    # Escape analysis is the single writer that makes Symbol#storage
    # definitive (promotes to :heap when the binding escapes); the
    # annotator must not pre-fold a type's heap-capable provenance onto
    # the symbol -- that over-promotes (e.g. a union typed heap-capable
    # but never actually escaping).
    is_resource, resource_close = resolve_resource_close(node, final_type)
    node.resource_close_zig = resource_close
    node.full_type.is_resource = true if is_resource && node.full_type.respond_to?(:is_resource=)

    Capabilities.validate!(node, node.full_type) { |n, msg| error!(n, :CAPABILITY_INVALID, message: msg) }

    node_sync = node.full_type.sync
    node_layout = node.full_type.layout
    # Preserve collection metadata (e.g. :set from DISTINCT) in scope so
    # resolve_full_type returns the correct dispatch_key for method lookup.
    # Do NOT store the full node.full_type — it embeds ownership/sync from
    # finalize_storage!, which breaks resolve_type in declare_capability_scope!
    # (WITH EXCLUSIVE unwrapping reads the raw entry.type expecting just the base type).
    scope_type = if node.full_type.collection && !(final_type.is_a?(Type) && final_type.collection)
      ft = Type.new(final_type)
      ft.collection = node.full_type.collection
      ft
    else
      final_type
    end
    current_scope.declare(
      node.name, node, scope_type, mutable_flag, false, node.slot_size, storage,
      Set.new, [],
      sync: node_sync,
      layout: node_layout,
      resource: is_resource,
      close_zig: resource_close
    )
    node.symbol = current_scope.locals[node.name]
    # (The late-provenance fold now happens BEFORE declare, above, so the
    # symbol is born with the correct storage -- no post-declare write.)
    # Propagate @link_source from the value type to the scope entry.
    val_ti = node.value&.full_type
    if val_ti&.link?
      link_src = val_ti.link_source
      node.symbol.link_source = link_src if link_src
    end
    # `~T@observable` bindings are non_escaping: the heap accumulator's
    # producer fiber holds a borrow of the source iterator (`gen`),
    # which is bound to this scope's frame. Returning, GIVE-ing, or
    # capturing the binding into a longer-lived context (BG fiber,
    # struct field, collection element) leaves the producer fiber
    # with a dangling pointer when the original frame rewinds. The
    # existing Lockdown 2/3 checks (BG capture / struct+collection
    # store) fire automatically once non_escaping is set; RETURN is
    # rejected by visit_ReturnNode's non_escaping guard. Users get the
    # value out via `|> COLLECT` (joins + extracts scalar) or
    # `WITH MATERIALIZED VIEW` (deep-copy snapshot).
    if node.full_type.observable?
      node.symbol.non_escaping = true
    end
    # Bare `T@versioned` is legal but unusual: a single-owner MVCC cell
    # cannot be reached from another thread, so suggest the shared form.
    if node.full_type.versioned? && node.full_type.ownership == :affine
      cap_tok = node.value.is_a?(AST::CapabilityWrap) ? node.value.token : nil
      fixes = []
      if cap_tok && cap_tok.value.to_s == "@versioned"
        fixes << Fix.new(
          description: "Upgrade `@versioned` to `@shared:versioned` for cross-thread sharing.",
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: cap_tok.line, col: cap_tok.column, length: "@versioned".length),
            replacement: "@shared:versioned",
          )],
        )
      end
      msg = "Bare `@versioned` on '#{node.name}' is unusual: a single-owner " \
            "MVCC cell isn't reachable from another thread, so the lock-free " \
            "commit path has no concurrent benefit. Use `@shared:versioned` " \
            "for cross-thread sharing, or remove `@versioned` if the cell is " \
            "truly local."
      if fixes.any?
        fixable!(node, message: msg, category: :lint, level: :warning, fixes: fixes)
      else
        note!(node, msg)
      end
    end
    classify_ownership!(node.symbol)
    og_declare(node.name, node, node.full_type_or(final_type))
    register_container_borrow!(node)
    # Non-Copy union locals need rt for cleanup (heapAlloc for *T/@indirect fields).
    ti = node.full_type
    if ti && !ti.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
      current_fn_ctx.heap_count += 1 if current_fn_ctx
    end
    accumulate_stack_bytes(storage, node)
    track_union_alias(node.name, node.value)
    record_capability_binding(node.name, node, final_type, storage)
  end

  # Keywordless `x = val` or `x: Type = val`.
  # If x is not yet in scope → immutable declaration (like old VAR x = val).
  # If x is in scope and mutable → assignment (like old SET x = val).
  # If x is in scope and immutable → error.
  sig { params(node: AST::BindExpr).returns(T.nilable(T::Hash[Symbol, T::Array[SymbolEntry]])) }
  def visit_BindExpr(node)
    # Same pre-set as visit_VarDecl: mark fixed-array list literals as :stack before visiting.
    if node.value.is_a?(AST::ListLit) && node.type&.fixed?
      node.value.storage = :stack
    end
    visit(node.value)

    scope = current_scope
    # `_` is a discard sink: every `_ = expr;` is an independent
    # declaration, never a reassignment.
    if !scope.locals.key?(node.name) || node.name == "_"
      # Declaration path
      promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
      promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)
      node.mode = :decl
      finalize_decl_node!(node, false)
      if node.value.instance_variable_get(:@has_borrowed_fields)
        node.symbol.non_escaping   = true
        node.symbol.borrowed_alias = true
      end
      stamp_init_contents_heap!(node)
      stamp_bg_handle_lifetime!(node)

    elsif scope.is_immutable?(node.name)
      emit_immutable_assignment_error!(node, scope)

    else
      # Assignment path
      node.mode = :assign

      verify_unrestricted!(node)
      validate_assignment_type(node, scope.resolve_type(node.name), node.value.resolved_type)
      node.full_type = scope.resolve_type(node.name)

      handle_assign_move(node)
      handle_assign_borrow(node)

      mark_var_mutated(node.name)
      og_set_live(node.name)

      # Atomic compound assignments must become fetch ops; load+add+store
      # would lose atomicity.
      target_sync = scope.locals[node.name]&.sync
      if target_sync == :atomic
        op = case node.compound_op
             when nil  then :store
             when :ADD then :fetchAdd
             when :SUB then :fetchSub
             when :MUL, :DIV
               op_str = node.compound_op == :MUL ? "*=" : "/="
               error!(node, :ATOMIC_NO_MUL_DIV_COMPOUND, op: op_str, hint: "Atomic ops are limited to load / store / fetch_add / fetch_sub. " \
                      "For more complex updates, use compareAndSwap or switch to @shared:locked.")
               nil
             else
               error!(node, :ATOMIC_UNSUPPORTED_COMPOUND, op: node.compound_op)
               nil
             end
        node.auto_atomic_op = op if op
        record_effect(EffectTracker::CONTENTION)
      end
    end
  end

  sig { params(node: AST::Identifier).returns(T.nilable(SymbolEntry)) }
  def visit_Identifier(node)
    predicate_identifier_allowed!(node)

    # Pipeline expressions (inside |>) are closures over the enclosing scope —
    # lookup_scope_for searches all scopes. Normal code uses resolve_variable_scope
    # which restricts to local scope + function-as-value references.
    scope = @smooth_depth > 0 ? lookup_scope_for(node.name) : resolve_variable_scope(node.name)
    unless scope
      # Check if it's a type name used as a comptime argument (e.g., parseFromSlice(MyDoc, ...))
      type_schema = lookup_type_schema(node.name.to_sym)
      if type_schema
        node.full_type = :Type
        return
      end
      emit_typo_suggestion!(
        node.token, node.name, outer_scope_vars.to_a,
        "Undefined variable '#{node.name}'",
        "closest in-scope variable"
      )
      return
    end

    # 1. Check Validity (View Invalidation Logic)
    scope.check_validity!(node.name)

    # 2. Resolve Type
    raw_type = scope.resolve_full_type(node.name)
    if raw_type.raw.is_a?(FunctionSignature)
      # Named function used as a value — re-wrap the signature in a Type
      # tagged as a fn_ref so the transpiler emits `&fn_name`.
      node.full_type = Type.new(raw_type.raw)
      node.fn_ref = true
    elsif raw_type.is_a?(Type) && raw_type.atomic? && raw_type.layout != :indirect
      # Atomic reads type as the inner value; the symbol keeps :atomic so
      # assignment targets and MIR lowering still see the cell semantics.
      node.full_type = Type.new(raw_type.raw)
      # Atomic loads contend on the cache line but never park.
      record_effect(EffectTracker::CONTENTION)
    else
      node.full_type = raw_type
    end

    # 3. Liveness
    if @og&.moved?(node.name)
      emit_use_of_moved_error!(node, @og.nodes[node.name])
    end

    # 5. Mark variable as read so the transpiler can skip `_ = &x` suppression.
    owner = lookup_scope_for(node.name)
    owner&.mark_read(node.name)
    node.symbol = owner&.locals&.[](node.name)
  end

  # DEPRECATED (SROA hint only, no memory safety role): Sets ownership_kind on scope entries
  # to guide the LLVM backend's SROA pass (whether to emit `_ = &name;` suppression).
  # This has no effect on correctness or memory safety — it is purely a performance annotation.
  # When SROA is revisited (likely as part of a dedicated LLVM codegen pass), this method and
  # all call sites should be removed. The MIR layer owns all memory decisions; this is a
  # leftover from before that architecture was established. Do not add new cases here.
  sig { params(entry: SymbolEntry).returns(T.nilable(Symbol)) }
  def classify_ownership!(entry)
    return unless entry
    type_obj = entry.type
    return if type_obj.fn_type? # function signature, not a variable
    entry.ownership_kind = if entry.resource
      :resource
    elsif type_obj.multiowned? || type_obj.shared? ||
          entry.rc_stored?
      :rc
    elsif entry.sync
      :sync
    elsif type_obj.collection?
      :collection
    elsif entry.takes
      # TAKES parameters own the data — always affine so cleanup is emitted.
      :affine
    elsif type_obj.implicitly_copyable? { |t| lookup_type_schema(t) }
      :value
    else
      :affine
    end
  end

  # Accumulate stack-local variable bytes for the current function context.
  # Only counts :stack storage — :frame and :heap don't consume fiber stack.
  # Track alias relationships for union values extracted from collections.
  # When x = f(source) where f returns a union and source is a union/collection,
  # x's backing data may alias source's. Skip cleanup for x.
  # Track alias relationships for union values extracted from collections.
  # Only UFCS method calls (x.get(key) returning same union type) are aliasing.
  # FuncCall (parseValue!(json, pos, penv, depth)) creates new data, not aliasing.
  # Track alias relationships for union values extracted from another union/collection.
  # Aliased variables share backing data with the source - skip cleanup to avoid double-free.
  sig { params(var_name: String, value_node: T.untyped).returns(T.nilable(T::Array[OwnershipGraph::Edge])) }
  def track_union_alias(var_name, value_node)
    return unless value_node.is_a?(AST::FuncCall) || value_node.is_a?(AST::MethodCall)
    ret_type = value_node.full_type
    return unless ret_type
    ret_type_obj = ret_type.is_a?(Type) ? ret_type : Type.new(ret_type)

    # Check if the return type is a union with heap variants
    schema = lookup_type_schema(ret_type_obj.resolved)
    return unless Schemas.union?(schema)
    has_heap = (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
    return unless has_heap

    # Get the first argument (object for MethodCall, first arg for FuncCall)
    first_arg = if value_node.is_a?(AST::MethodCall)
      value_node.object
    elsif value_node.args.any?
      value_node.args.first
    end
    return unless first_arg.is_a?(AST::Identifier)
    arg_type = first_arg.resolved_type

    # Alias when: first arg is the SAME union type (extraction like jsonGet)
    # or first arg is a map (HashMap lookup returning union value)
    if arg_type == ret_type_obj.resolved || first_arg.full_type.map?
      @og.edges << OwnershipGraph::Edge.new(from: var_name, to: first_arg.name, kind: :aliases)
    end
  end

  sig { params(storage: Symbol, node: T.untyped).returns(T.nilable(Integer)) }
  def accumulate_stack_bytes(storage, node)
    return unless storage == :stack && current_fn_ctx
    bytes = (node.slot_size || 1) * 8
    current_fn_ctx.stack_vars_bytes += bytes
  end

  sig { params(name: String).returns(T.nilable(T::Boolean)) }
  def mark_var_mutated(name)
    scope = lookup_scope_for(name)
    return unless scope
    entry = scope.locals[name]
    return unless entry
    entry.mutated = true
    entry.reg.var_mutated = true if entry.reg&.respond_to?(:var_mutated=)
  end

  # Mark a binding as mutated INDIRECTLY (e.g. via a function call that
  # takes the binding by mutable reference). Sets only the SymbolEntry
  # flag — does NOT touch decl_node.var_mutated. The lint
  # ("MUTABLE never reassigned") and the var/const emit decision both
  # key off decl_node.var_mutated; promoting them here would cause Zig
  # to emit `var` for a local that has no visible Zig-level mutation,
  # tripping Zig's "var never mutated" safety check. The SymbolEntry
  # flag is what post-annotation passes (like
  # validate_with_guard_no_body_mutation!) read to detect any mutation,
  # direct or indirect.
  sig { params(name: String).returns(T.nilable(T::Boolean)) }
  def mark_var_mutated_via_call(name)
    scope = lookup_scope_for(name)
    return unless scope
    entry = scope.locals[name]
    return unless entry
    entry.mutated = true
    entry.mutable_ref_target = true if entry.respond_to?(:mutable_ref_target=)
  end

  # Walk a chained access expression (GetField/GetIndex chain rooted at an
  # Identifier) and return the root identifier name, or nil if the chain
  # doesn't bottom out at one. Used to attribute receiver mutation back to
  # the declared binding.
  sig { params(node: T.untyped).returns(T.untyped) }
  def chain_root_name(node)
    curr = T.let(node, T.untyped)
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      curr = curr.target
    end
    curr.is_a?(AST::Identifier) ? curr.name : nil
  end

  # ==========================================
  # Assignment
  # ==========================================
  sig { params(node: AST::Assignment).returns(T.nilable(Symbol)) }
  def visit_Assignment(node)
    # If the assignment target is a `@locked` / `@writeLocked` field
    # write (e.g. `c.value = c.value + 1`), the auto-lock path emits
    # a single lock acquire that covers BOTH the LHS write AND the
    # RHS reads. Set the auto-lock context before visiting the RHS
    # so visit_GetField's CAP_FIELD_NEEDS_WITH_EXCLUSIVE check skips
    # the in-RHS read of the same `@locked` binding (it's safe under
    # the auto-lock).
    saved_auto_lock = @in_auto_locked_assign
    target = node.name
    if target.is_a?(AST::GetField) && target.target.is_a?(AST::Identifier)
      # Symbol isn't stamped until visit_Identifier runs, so look up
      # the binding's sync from the scope directly.
      tname = target.target.name
      tscope = lookup_scope_for(tname)
      tsym = tscope&.locals&.[](tname)
      sync = tsym&.sync
      layout = tsym.respond_to?(:layout) ? tsym.layout : nil
      if tsym&.locked? || tsym&.write_locked? || tsym&.atomic_ptr?
        @in_auto_locked_assign = tname
      end
    end

    visit(node.value)
    @in_auto_locked_assign = saved_auto_lock

    verify_unrestricted!(node)
    # Tied-lifetime values cannot be stored into destinations that outlive
    # any of their lifetime sources.
    verify_tied_assignment!(node)

    target = node.name
    case target
    when AST::Identifier, String
      visit_assignment_variable(target, node)

    when AST::GetIndex
      visit_assignment_index(target, node)

    when AST::GetField
      visit_assignment_field(target, node)

    else
      error!(node, :INVALID_ASSIGNMENT_TARGET, got: target.class)
    end

    handle_assign_move(node)
    handle_assign_borrow(node)

    target_name = node.name.is_a?(AST::Identifier) ? node.name.name : node.name
    og_set_live(target_name)
  end

  sig { params(identifier_or_name: T.untyped, node: AST::Assignment).returns(T::Boolean) }
  def visit_assignment_variable(identifier_or_name, node)
    var_name = identifier_or_name.is_a?(AST::Identifier) ? identifier_or_name.name : identifier_or_name

    scope = current_scope
    if !scope.locals.key?(var_name)
      error!(node, :ASSIGN_UNDEFINED_VAR, name: var_name)
    end

    if scope.is_immutable?(var_name)
      fix = build_declare_mutable_fix(var_name, scope)
      if fix
        fixable!(node,
          message: T.must(DiagnosticRegistry.format(:ASSIGN_VAR_IMMUTABLE, name: var_name)),
          category: :ownership,
          level: :error,
          fixes: [fix])
      else
        error!(node, :ASSIGN_VAR_IMMUTABLE, name: var_name)
      end
    end

    validate_assignment_type(node, scope.resolve_type(var_name), node.value.resolved_type)
    node.full_type = scope.resolve_type(var_name)
    T.must(mark_var_mutated(var_name))
  end

  sig { params(index_node: AST::GetIndex, assignment_node: AST::Assignment).returns(NilClass) }
  def visit_assignment_index(index_node, assignment_node)
    visit(index_node)

    mark_chain_needs_mut_ref!(index_node)

    if index_node.target.is_a?(AST::Identifier)
      var_name = index_node.target.name
      if current_scope.is_immutable?(var_name)
        emit_immutable_index_assignment_error!(assignment_node, current_scope, var_name)
      end
      mark_var_mutated(var_name)
    else
      # Chained target (e.g. `y.items[0] = ...`). Mark the root binding
      # mutated so post-annotation passes (GUARD validation, etc.) can see
      # it. Immutability is enforced by the assignment_field visitor on
      # the way up.
      root = chain_root_name(index_node.target)
      mark_var_mutated(root) if root
    end

    # Map reads return ?V, but map writes store V.
    assign_type = index_node.full_type
    if assign_type&.optional?
      assign_type_resolved = assign_type.wrapped_type.resolved
    else
      assign_type_resolved = index_node.resolved_type
    end
    validate_assignment_type(assignment_node, assign_type_resolved, assignment_node.value.resolved_type)

    assignment_node.full_type = assign_type_resolved

    # HashMap put may allocate, so needs_rt must propagate.
    target_type = index_node.target.full_type
    if target_type&.map?
      current_fn_ctx.heap_count += 1 if current_fn_ctx
      record_effect(EffectTracker::HEAP)
    end
  end

  sig { params(field_node: AST::GetField, assignment_node: AST::Assignment).returns(T.nilable(Symbol)) }
  def visit_assignment_field(field_node, assignment_node)
    # Field writes go through the auto-lock path, not the WITH-required
    # diagnostic used for reads.
    field_node.is_assignment_lhs = true
    visit(field_node)

    # AtomicPtr publishes whole-T snapshots; only the WITH SNAPSHOT MUTABLE
    # alias can accept field assignments.
    reject_bare_atomic_ptr_mutation!(field_node, assignment_node)

    mark_chain_needs_mut_ref!(field_node)

    # @alwaysMutable (RefCell) allows field mutation through const bindings.
    if field_node.target.is_a?(AST::Identifier)
      var_name = field_node.target.name
      syn = field_node.target.symbol&.sync
      if current_scope.is_immutable?(var_name) && syn != :always_mutable
        emit_immutable_field_assignment_error!(assignment_node, current_scope, var_name, field_node.field)
      end
      mark_var_mutated(var_name)

      # 3. Auto-lock: if the target variable is @locked or @writeLocked, mark the
      # assignment for inline guard emission. The borrow cannot escape because
      # field assignments are statements (not expressions).
      syn = field_node.target.symbol&.sync
      if syn == :locked || syn == :write_locked || syn == :always_mutable
        assignment_node.auto_lock = { var: var_name, sync: syn }
      end
    else
      # Chained target (e.g. `y.items.field = ...` or `obj.f.g = ...`).
      # Attribute mutation to the chain root so post-annotation passes
      # see it without re-walking the AST.
      root = chain_root_name(field_node.target)
      mark_var_mutated(root) if root
    end

    # 4. Type Check
    validate_assignment_type(assignment_node, field_node.resolved_type, assignment_node.value.resolved_type)

    # Assignments are statements (void), not expressions that produce a value.
    assignment_node.full_type = :Void
  end

  sig { params(node: T.untyped, target_type: T.untyped, value_type: Symbol).returns(T.untyped) }
  def validate_assignment_type(node, target_type, value_type)
    return if target_type.nil? || false || target_type == :Any || value_type == :Any
    return if target_type == :NIL # Allow narrowing from initial NIL
    return if target_type == value_type

    if !is_safe_autocast?(value_type, target_type)
      emit_type_mismatch_assign_error!(node, target_type, value_type)
    else
      node.value.coerced_type = target_type
    end
  end

  # ==========================================
  # INVALIDATION LOGIC (The "Dependencies" feature)
  # ==========================================

  sig { params(node: AST::Cast).returns(Symbol) }
  def visit_Cast(node)
    visit(node.value) # Resolve 'json' -> :HashMap

    # node.target is "Config".
    # In a strict language, we'd check if :HashMap can cast to Config.
    # For now, just trust the user and carry the type forward.
    node.full_type = node.target.to_sym
  end

  sig { params(node: AST::GetIndex).returns(T.nilable(Type)) }
  def visit_GetIndex(node)
    visit(node.target)
    visit(node.index)

    target_type_info = node.target.full_type

    # Look up index operation from the registry
    op = resolve_index_op(target_type_info, :get)

    if op
      # Registry-driven: type and ownership from INDEX_OPS
      node.full_type = IntrinsicRegistry.to_return_def(op[:return_type])
                                        .resolve(target_type_info, [], self)
      node.container_borrow = true if op[:container_borrow]

      # Validate key types for maps
      if target_type_info.map?
        index_type_info = node.index.full_type
        if target_type_info.numeric_map?
          error!(node, :NUMERIC_MAP_KEY_BAD, got: node.index.resolved_type) unless index_type_info&.numeric?
        else
          error!(node, :STRING_MAP_KEY_BAD, got: node.index.resolved_type) unless index_type_info&.string?
        end
      end

    # Special cases not covered by INDEX_OPS
    elsif target_type_info.promise_list?
      # Promise list indexing yields ~T (tense type); dispatch_key returns :array
      # but resolve_index_op guards against this above.
      elem_t = target_type_info.tense_type.element_type
      node.full_type = Type.new(:"~#{elem_t.resolved}")
    elsif target_type_info.string? && !target_type_info.raw?
      error!(node, :STRING_INDEX_BY_INT)
    elsif node.target.metatype == :struct
      # Struct field access via index (rare legacy path)
      node.full_type = target_type_info.element_type
      node.container_borrow = true
    else
      error!(node, :UNSUPPORTED_INDEX)
    end
  end

  sig { params(node: AST::GetField).returns(T.untyped) }
  def visit_GetField(node)
    # Enum/Union variant access: TypeName.Variant
    # Must be checked BEFORE visiting target to avoid "variable not found" error.
    return if resolve_variant_access(node)

    visit(node.target)

    # Check if this path or any ancestor has been moved (graph handles both)
    path = get_path_to_root(node)
    if path
      # Check root, then progressively longer sub-paths
      check = T.let("", String)
      path.each do |seg|
        check = check.empty? ? seg.to_s : "#{check}.#{seg}"
        if @og.moved?(check)
          emit_use_of_moved_path_error!(node, path, @og[check])
          break
        end
      end
    end

    type = node.target.resolved_type

    # Struct Field Lookup
    if node.wildcard?
      node.full_type = :Void
      return
    end

    # Capability-wrapped bindings hide the inner T behind a lock /
    # atomic cell. Direct field access on the outer binding skips the
    # unwrap and produces a Zig-level "no field named X" since the
    # wrapper type doesn't have the field. Catch this early with a
    # CLEAR-level diagnostic that names the right WITH form.
    # Skip when this GetField is the LHS of an assignment — field
    # writes are handled by visit_assignment_field's auto-lock path
    # (`assignment_node.auto_lock`), which emits the correct
    # lock-acquire-and-release inline.
    if node.target.is_a?(AST::Identifier) && !node.is_assignment_lhs
      sym = node.target.symbol
      if sym
        sync   = sym.sync
        layout = sym.respond_to?(:layout) ? sym.layout : nil
        # Skip when this read is the RHS of an auto-locked assignment
        # against the same binding — `c.val = c.val + 1` on `@locked`
        # is fine because the LHS write's auto-lock covers the read.
        in_auto_lock = @in_auto_locked_assign == node.target.name
        # Skip when we're inside a WITH block — the WITH unwrap
        # mechanism handles capability access (either via an `AS`
        # alias whose own symbol is plain, or via the no-AS form
        # which auto-unwraps the original name).
        in_with_block = (@with_block_depth || 0) > 0
        if sym.locked? && !in_auto_lock && !in_with_block
          emit_cap_field_needs_with!(node,
            :CAP_FIELD_NEEDS_WITH_EXCLUSIVE, perm: "EXCLUSIVE",
            name: node.target.name, field: node.field, cap: "@locked")
        elsif sym.write_locked? && !in_auto_lock && !in_with_block
          emit_cap_field_needs_with!(node,
            :CAP_FIELD_NEEDS_WITH_EXCLUSIVE, perm: "EXCLUSIVE",
            name: node.target.name, field: node.field, cap: "@writeLocked")
        elsif sym.atomic_ptr? && !in_with_block && !in_auto_lock
          emit_cap_field_needs_with!(node,
            :CAP_FIELD_NEEDS_WITH_SNAPSHOT, perm: "SNAPSHOT",
            name: node.target.name, field: node.field, cap: "@indirect:atomic")
        end
      end
    end

    raw_schema = lookup_type_schema(type)
    struct_schema = Schemas.field_bearing?(raw_schema) ? raw_schema : nil
    if Schemas.enum?(raw_schema)
      error!(node, :ENUM_FIELD_ACCESS, enum: type)
    elsif raw_schema.is_a?(Schemas::UnionSchema) || (Schemas.union?(raw_schema))
      error!(node, :UNION_FIELD_ACCESS, union: type)
    elsif struct_schema && struct_schema.fields[node.field]
      field_type = struct_schema.fields[node.field].type
      # SOA tracking: record field access on pipeline variable `_`
      if @pipeline_accessed_fields && node.target.is_a?(AST::Identifier) && node.target.name == "_"
        @pipeline_accessed_fields << node.field
      end
      # For generic instances (e.g. Pair<Number>), substitute type params into field type.
      # Handles compound types like T[], ?T, !T via apply_type_subst.
      # BORROWED fields are stored as plain types in the schema (borrowed_fields tracks which).
      type_obj = Type.new(type)
      if type_obj.generic_instance? && struct_schema.type_params
        subst = {}
        struct_schema.type_params.zip(type_obj.generic_args).each do |param, arg|
          subst[param] = arg.resolved
        end
        field_type = apply_type_subst(field_type, subst) if subst.any?
      end
      if field_type.is_a?(Type) && field_type.indirect?
        # A struct-pointee @indirect field is an owned heap pointer that
        # moves like the old `%T`: bind/move the `*T`, let Zig auto-deref
        # field access, and free once. An explicit read-deref there turns
        # the move into a value copy and leaks the box. String/scalar and
        # union/enum pointees still need the read-deref (Zig won't coerce
        # `*T` -> `T` for those consumers).
        psch = (lookup_type_schema(field_type.resolved) rescue nil)
        struct_pointee = Schemas.struct?(psch)
        node.indirect_field = true if node.is_a?(AST::GetField) && !struct_pointee
        # For non-struct pointees, the read-deref produces a value of the
        # inner type (layout no longer applies). For struct pointees, the
        # binding holds the *T pointer directly -- keep layout=:indirect so
        # ti.zig_type renders "*T".
        if !struct_pointee
          field_type = field_type.dup
          field_type.layout = nil
        end
      end
      node.full_type = field_type
    elsif struct_schema && node.token
      # Struct schema resolved but the requested field doesn't exist —
      # emit a typo suggestion when one of the schema's fields is close
      # to what the user typed. The bare error code stays as the
      # fallback when no candidate is within Levenshtein threshold.
      valid_fields = struct_schema.fields.keys.reject { |k| k.is_a?(Symbol) || k.to_s.start_with?('_') }
      emit_typo_suggestion!(
        node.token, node.field, valid_fields,
        "Struct '#{type}' has no field '#{node.field}'",
        "field of #{type}",
        category: :type, cascade: true
      )
    else
      error!(node, :ILLEGAL_FIELD_LOOKUP, field: node.field, type: type)
    end
  end

  sig { params(node: AST::Slice).void }
  def visit_Slice(node)
    visit(node.target)
    visit(node.start) if node.start
    visit(node.end) if node.end

    # A slice of T[] is T[]
    # A slice of T[3] is T[] (Fixed becomes Dynamic view)
    target_type = node.target.full_type
    if target_type&.array?
      element = target_type.element_type.resolved
      node.full_type = Type.new(:"#{element}[]")
    else
      node.full_type = :Any
    end
  end

  # Call-site recursion overrides are parsed but not lowered yet; emit a
  # precise diagnostic instead of silently generating wrong code.
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
      node.full_type = :Bool
    when :SUB, "-"
      node.full_type = node.right.full_type # Keep as Number/Int64
    else
      node.full_type = node.right.full_type
    end
  end

  # ==========================================
  # LITERALS & BINARY OPS
  # ==========================================
  sig { params(node: AST::HashLit).void }
  def visit_HashLit(node)
    # 1. Analyze values to find the Value Type (V)
    #    Assumption: Maps are homogeneous for now (e.g. all Int64)
    if node.pairs.empty?
      node.full_type = :"HashMap<Any>"
      node.storage = :heap
      current_fn_ctx.heap_count += 1 if current_fn_ctx
      record_effect(EffectTracker::HEAP)
      return
    end

    # Visiting keys populates type_info used by Auto inference for HashMap
    # key shape slots.
    node.pairs.each { |k, v| visit(k); visit(v) }

    # Infer Type from first value
    first_val_type = node.pairs.values.first.resolved_type

    # Simple check: Ensure all values match
    node.pairs.each do |k, v|
      if v.resolved_type != first_val_type
        error!(node, :HASHMAP_MIXED_VALUES)
      end
    end

    node.full_type = Type.new(:"HashMap<#{first_val_type}>")
    node.storage = :heap
    current_fn_ctx.heap_count += 1 if current_fn_ctx
    record_effect(EffectTracker::HEAP)
  end

  sig { params(node: AST::StructLit).returns(T.nilable(Symbol)) }
  def visit_StructLit(node)
    schema = lookup_type_schema(node.name.to_sym)
    if schema.nil?
      tok = node.token
      if tok
        emit_typo_suggestion!(
          tok, node.name, all_known_type_names,
          "Unknown struct type '#{node.name}'",
          "closest declared type",
          category: :type, cascade: true
        )
      else
        error!(node, :UNKNOWN_STRUCT_TYPE, name: node.name)
      end
    end

    # Union literal: Result{ Ok: 42 } or Option<Number>{ Some: 42.0 }
    # Reuses struct-literal syntax — no new parser changes required.
    if Schemas.union?(schema)
      if node.fields.length != 1
        error!(node, :UNION_LITERAL_VARIANT_COUNT, name: node.name, got: node.fields.length)
      end

      # Build type param substitution for generic unions
      union_type_params = schema.type_params
      union_subst = {}
      if node.type_args&.any?
        if union_type_params.nil? || union_type_params.empty?
          error!(node, :GENERIC_NOT_GENERIC, type: node.name)
        end
        if node.type_args.length != union_type_params.length
          error!(node, :GENERIC_WRONG_ARG_COUNT, type: node.name, expected: union_type_params.length, got: node.type_args.length)
        end
        union_type_params.zip(node.type_args).each { |p, a| union_subst[p] = a.to_sym }
      elsif union_type_params&.any?
        params_hint = union_type_params.map(&:to_s).join(', ')
        error!(node, :GENERIC_MISSING_TYPE_ARGS, type: node.name, type2: node.name, hint: params_hint)
      end

      variant_name, val_node = node.fields.first
      unless schema.variants.key?(variant_name)
        anchor = variant_anchor_from_unionlit(node, variant_name)
        if anchor
          emit_variant_typo!(
            anchor, variant_name, schema.variants.keys,
            "Type Error: Union '#{node.name}' has no variant '#{variant_name}'.",
            "variant of union #{node.name}",
            cascade: true
          )
        else
          error!(node, :UNION_UNKNOWN_VARIANT, union: node.name, variant: variant_name)
        end
      end
      raw_expected = schema.variants[variant_name]
      if raw_expected.nil?
        error!(node, :UNION_VARIANT_IS_UNIT_NO_PAYLOAD, variant: variant_name, union: node.name, variant2: variant_name)
      end
      if Schemas.inline_struct?(raw_expected)
        error!(node, :UNION_INLINE_VARIANT_OLD_SYNTAX, union: node.name, variant: variant_name, union2: node.name, variant2: variant_name)
      end
      # @indirect single-type payload: unwrap inner type for type-checking;
      # mark the value node so the transpiler heap-allocates it via create(*T).
      indirect_payload = raw_expected.is_a?(Type) && raw_expected.indirect?
      raw_for_check = if indirect_payload
                        d = raw_expected.dup
                        d.layout = nil
                        d
                      else
                        raw_expected
                      end
      # Apply type param substitution (e.g. T → Number for generic unions)
      expected_type = T.let(union_subst.any? ? apply_type_subst(raw_for_check, union_subst) : raw_for_check, Type)
      visit(val_node)
      reject_borrowed_value!(val_node, "#{node.name}.#{variant_name}")
      # Ensure value is owned data (implicit COPY for @list/rodata strings).
      owned = T.let(ensure_owned_value!(val_node, expected_type, "#{node.name}.#{variant_name}"), T.nilable(AST::CopyNode))
      if owned
        node.fields[variant_name] = owned
        val_node = owned
      end
      if indirect_payload
        val_node.needs_heap_create = true
        current_fn_ctx.heap_count += 1 if current_fn_ctx  # heapAlloc().create(*T) needs rt
      end
      actual = val_node.full_type
      unless expected_type.accepts?(actual)
        error!(node, :UNION_PAYLOAD_MISMATCH, variant: variant_name, expected: expected_type.resolved, got: actual&.resolved)
      end
      move_if_not_copyable!(val_node)
      node.full_type = if node.type_args&.any?
        :"#{node.name}<#{node.type_args.join(',')}>"
      else
        node.name.to_sym
      end
      return
    end

    # Empty struct literal: MyStruct{} — use all struct field defaults.
    if node.fields.empty?
      field_names = schema.fields.keys
      unless field_names.empty?
        field_defaults = schema.field_defaults || {}
        missing = field_names.reject { |f| field_defaults.key?(f) }
        if missing.any?
          error!(node, :STRUCT_LITERAL_MISSING_FIELDS, name: node.name, fields: missing.join(', '))
        end
      end
      node.full_type = node.name.to_sym
      return
    end

    # Build type param substitution map for generic struct instantiation.
    # e.g. Pair<Number>{ first: 1.0 } → { :T => :Float64 }
    type_params = schema.type_params
    type_subst = {}
    if node.type_args&.any?
      if type_params.nil? || type_params.empty?
        error!(node, :GENERIC_NOT_GENERIC, type: node.name)
      end
      if node.type_args.length != type_params.length
        error!(node, :GENERIC_WRONG_ARG_COUNT, type: node.name, expected: type_params.length, got: node.type_args.length)
      end
      type_params.zip(node.type_args).each do |param, arg|
        type_subst[param] = arg.to_sym
      end
    elsif type_params&.any?
      params_hint = type_params.map(&:to_s).join(', ')
      error!(node, :GENERIC_MISSING_TYPE_ARGS, type: node.name, type2: node.name, hint: params_hint)
    end

    # Iterate Fields (Validation)
    node.fields.each do |field_name, val_node|
      visit(val_node) # Resolve value type

      raw_expected = T.let(schema.fields[field_name]&.type, T.nilable(T.any(Type, Symbol)))
      if raw_expected.nil?
        valid_fields = schema.fields.keys.reject { |k| k.to_s.start_with?("_") }
        name_tok = node.field_tokens&.[](field_name)
        if name_tok
          emit_typo_suggestion!(
            name_tok, field_name, valid_fields,
            "Struct '#{node.name}' has no field '#{field_name}'",
            "field of #{node.name}",
            category: :type, cascade: true
          )
        else
          error!(node, :STRUCT_FIELD_UNRESOLVABLE, struct: node.name, field: field_name)
        end
      end

      # Check if this field is declared BORROWED in the struct definition
      field_is_borrowed = schema.borrowed_fields&.include?(field_name)

      # Apply type param substitution (e.g., T → Number, T[] → String[])
      expected_type = T.let(if type_subst.any?
        apply_type_subst(raw_expected, type_subst)
      else
        raw_expected
      end, T.untyped)

      # BORROWED fields accept borrowed values — skip ownership checks.
      # Non-borrowed fields require owned data.
      unless field_is_borrowed
        reject_borrowed_value!(val_node, "#{node.name}.#{field_name}")
      end
      # Skip CopyNode wrapping for rodata strings in call argument structs.
      # The struct is a temporary - rodata strings are valid for the call's
      # lifetime. The callee dupes strings it needs to escape.
      is_call_arg = node.instance_variable_get(:@is_call_arg)
      owned = T.let(unless field_is_borrowed || is_call_arg
        ensure_owned_value!(val_node, expected_type, "#{node.name}.#{field_name}")
      end, T.untyped)
      if owned
        node.fields[field_name] = owned
        val_node = owned
      end

      # Simple Type Check
      if val_node.full_type != expected_type
        unless is_safe_autocast?(val_node.resolved_type, expected_type)
          error!(node, :FIELD_TYPE_MISMATCH, field: field_name, expected: expected_type, got: val_node.resolved_type)
        end
        val_node.coerced_type = expected_type
      end

      move_if_not_copyable!(val_node) unless field_is_borrowed
    end

    # Non-escaping propagation: structs with BORROWED fields inherit non_escaping.
    node.borrowed_field_names = schema.borrowed_fields
    node.instance_variable_set(:@has_borrowed_fields, true) if schema.borrowed_fields&.any?

    # Set full_type to the generic instance name or plain struct name
    node.full_type = if node.type_args&.any?
      :"#{node.name}<#{node.type_args.join(',')}>"
    else
      node.name.to_sym
    end
  end

  sig { params(node: AST::ListLit).returns(T.nilable(T.any(Symbol, Type))) }
  def visit_ListLit(node)
    # 1. Analyze all items
    node.items.each { |item| visit(item) }

    # Bounded stream literal: [BG{...}, BG{...}] where all items are promises.
    # Produces ~T[N] type — a fixed-size stream of N concurrent BG fibers.
    # This must be checked before the general array logic, since ~T items would
    # otherwise produce a bare ~T[] type (which is a compiler error).
    if !node.items.empty? && node.items.all? { |i| Type.new(i.resolved_type).future? }
      inner_types = node.items.map { |i| Type.new(i.resolved_type).tense_type.to_sym }.uniq
      if inner_types.size > 1
        error!(node, :BOUNDED_STREAM_MIXED_TYPES, types: inner_types.join(', '))
      end
      node.full_type = Type.new(:"~#{inner_types.first}[#{node.items.size}]")
      node.storage   = :stack
      return
    end

    if node.items.empty?
      # Untyped constructor: List[] or Pool[] — deferred element type.
      # The collection type is set; element type resolves on first append/insert.
      if (coll = node.instance_variable_get(:@constructor_collection))
        t = Type.new(:"Any[]", collection: coll)
        t.soa = true if node.instance_variable_get(:@constructor_soa)
        t.shard_count = node.instance_variable_get(:@constructor_shard_count)
        t.provenance = :heap if coll == :pool || coll == :set
        node.full_type = t
        node.storage = (coll == :pool || coll == :set) ? :heap : :stack
        record_effect(EffectTracker::HEAP)
        return
      end
      if node.storage == :heap
        node.full_type = Type.new(:"Any[]", location: :heap)
      else
        node.full_type = :"Any[]"
      end
      return
    end

    # 2. Infer base type from the first element.
    #    If all items are string-like (Byte[N] or String), widen to String so mixed
    #    string lengths ("a", "bb", "ccc") don't produce a type error.
    if node.items.all? { |i| Type.new(i.resolved_type).string? }
      base_type = :String
    else
      base_type = node.items.first.resolved_type
      # 3. Validate Consistency — all items must share the same type.
      node.items.each_with_index do |item, index|
        next if index == 0
        if item.resolved_type != base_type
          error!(node, :LIST_LITERAL_MIXED_TYPES, base: base_type, index: index+1, got: item.resolved_type)
        end
      end
    end

    if node.storage == :stack
      node.full_type = Type.new(:"#{base_type}[#{node.items.size}]")
    else
      t = Type.new(:"#{base_type}[]", location: :heap)
      t.provenance = :frame  # makeList uses frameAlloc for backing
      node.full_type = t
    end
  end

  sig { params(node: AST::RangeLit).returns(T.nilable(Type)) }
  def visit_RangeLit(node)
    visit(node.start)
    visit(node.finish)

    start_type = node.start.resolved_type
    finish_type = node.finish.resolved_type

    unless Type.new(start_type).numeric?
      error!(node, :RANGE_START_NEEDS_NUMERIC, got: start_type)
    end

    unless Type.new(finish_type).numeric?
      error!(node, :RANGE_END_NEEDS_NUMERIC, got: finish_type)
    end

    # Only coerce to Float64 when mixing int and float bounds.
    # Pure-integer ranges stay Int64 (no unnecessary float conversion).
    start_is_float = Type.new(start_type).float?
    finish_is_float = Type.new(finish_type).float?
    if start_is_float != finish_is_float
      # Mixed: coerce both to Float64
      node.start.coerced_type = :Float64 unless start_is_float
      node.finish.coerced_type = :Float64 unless finish_is_float
    elsif start_is_float
      # Both float: no coercion needed
    else
      # Both integer: keep as-is (Int64 range)
    end

    base_type = if start_is_float || finish_is_float
      :Float64
    else
      :Int64
    end
    node.full_type = Type.new(:"~#{base_type}[]")
  end

  sig { params(node: AST::Literal).returns(T.untyped) }
  def visit_Literal(node)
    node.full_type =
      case node.type
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
  end

  sig { params(node: AST::DefaultLit).returns(Symbol) }
  def visit_DefaultLit(node)
    # Resolved type is set by declare_and_verify_params / visit_StructLit context.
    # Standalone DEFAULT is not valid; callers validate the context.
    node.full_type = :Any
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
    result = Type.binary_op(node.op, node.left.full_type, node.right.full_type)

    if result.error
      error!(node, :TYPE_ERROR_GENERIC, message: result.error)
    end

    node.full_type = result.type
    node.left.coerced_type = result.left_coercion if result.left_coercion
    node.right.coerced_type = result.right_coercion if result.right_coercion
    node.storage = result.storage if result.storage

    # String concat (+) transpiles to std.mem.concat(rt.frameAlloc(), ...) —
    # mark as frame allocation so needs_rt and loop mark elision are correct.
    if node.op == :ADD && (node.left.full_type.string? || node.right.full_type.string?)
      node.string_concat = true
      current_fn_ctx.frame_count += 1 if current_fn_ctx
      # String concat result is frame-allocated.
      node.storage = :frame
      ti = node.full_type
      ti.provenance = :frame if ti.is_a?(Type)
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
    lhs_type = node.left.full_type

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
    node.right.full_type = binding_type

    # The result of the operation is the collection itself (passthrough for pipeline)
    node.full_type = lhs_type
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
                    node.left.full_type
                  end
    t_right_type = node.right.full_type

    # Handle OR EXIT "msg": set error context + propagate (same as OR RAISE for types)
    if node.right.is_a?(AST::OrExit)
      if t_left_type.error_union?
        node.full_type = t_left_type.payload_type.resolved
      else
        node.full_type = t_left_type.resolved
      end
      return
    end

    # Handle OR RAISE: bubble up error (Zig's try)
    if node.right.is_a?(AST::OrRaise)
      if t_left_type.error_union?
        # Unwrap to payload type - error will be propagated
        node.full_type = t_left_type.payload_type.resolved
      else
        # OR RAISE on non-error type just passes through
        node.full_type = t_left_type.resolved
      end
      return
    end

    # Handle OR PASS: ignore error, use undefined/default
    if node.right.is_a?(AST::OrPass)
      if t_left_type.error_union?
        # Unwrap to payload type - error will be ignored
        node.full_type = t_left_type.payload_type.resolved
      else
        node.full_type = t_left_type.resolved
      end
      return
    end

    # Handle OR BREAK: error-to-break coercion (valid only inside loops)
    if node.right.is_a?(AST::OrBreak)
      if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
        error!(node, :OR_BREAK_OUTSIDE_WHILE)
      end
      if t_left_type.error_union?
        node.full_type = t_left_type.payload_type.resolved
      else
        node.full_type = t_left_type.resolved
      end
      return
    end

    # Handle OR PRUNE: discard error, skip item (used in CONCURRENT SELECT/WHERE)
    if node.right.is_a?(AST::OrPrune)
      if t_left_type.error_union?
        # Unwrap to payload type - error causes item to be skipped
        node.full_type = t_left_type.payload_type.resolved
      else
        node.full_type = t_left_type.resolved
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
      node.full_type = payload_type.resolved
      return
    end

    # Handle optional types: ?T OR default -> T
    if t_left_type.optional?
      wrapped = t_left_type.wrapped_type
      unless wrapped.accepts?(t_right_type) || t_right_type.accepts?(wrapped)
        error!(node, :TYPE_MISMATCH_IN_OR, expected: wrapped.resolved, got: t_right_type.resolved)
      end
      coerce_empty_collection_fallback!(node.right, wrapped)
      node.full_type = wrapped.resolved
      return
    end

    # Standard OR behavior
    if t_left_type.resolved == t_right_type.resolved
      node.full_type = t_left_type.resolved
    else
      node.full_type = t_left_type.resolved
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
    rhs.full_type = expected
  end

  sig { params(node: AST::OrRaise).returns(Symbol) }
  def visit_OrRaise(node)
    node.full_type = :Void
  end

  sig { params(node: AST::OrBreak).returns(Symbol) }
  def visit_OrBreak(node)
    node.full_type = :Void
  end

  sig { params(node: AST::OrPass).returns(Symbol) }
  def visit_OrPass(node)
    # This is a marker node for OR PASS - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    node.full_type = :Void
  end

  sig { params(node: AST::OrPrune).returns(Symbol) }
  def visit_OrPrune(node)
    # This is a marker node for OR PRUNE - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    node.full_type = :Void
  end

  sig { params(node: AST::OrExit).returns(T.nilable(Symbol)) }
  def visit_OrExit(node)
    visit(node.message) if node.message
    resolve_error_registration!(node, node.kind, node.error_name, node.token)
    node.full_type = :Void
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

    if ti.primitive? && (node.ownership || node.sync || node.layout) && !is_atomic_primitive
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

    ti.ownership = node.ownership if node.ownership
    ti.sync      = node.sync      if node.sync
    ti.lock_rank = node.lock_rank if node.lock_rank
    ti.layout    = node.layout    if node.layout
    # AtomicPtr implies shared ownership because escaping the declaring
    # scope is the point of the construct; local and multiowned cases were
    # rejected above.
    if node.atomic_ptr? && !node.ownership
      ti.ownership = :shared
    end
    # @indirect forces heap location (same as @local, but different intent).
    ti.provenance = :heap           if node.indirect?

    # Lock ranks induce a total order only if every declaration of a type
    # uses the same rank.
    if node.lock_rank && node.sync && (node.locked? || node.write_locked?)
      record_lock_type_rank!(ti.base_type, node.lock_rank, node)
    end

    # CapabilityWrap always allocates on the heap.
    if node.ownership || node.sync || node.layout
      current_fn_ctx.heap_count += 1 if current_fn_ctx
      record_effect(EffectTracker::HEAP)
    end

    # Store the Type directly — full_type= accepts Type objects
    node.full_type = ti
  end

  sig { params(node: AST::MoveNode).returns(T.nilable(T::Set[T.untyped])) }
  def visit_MoveNode(node)
    visit(node.value)

    unless node.value.is_a?(AST::Identifier)
      error!(node, :MOVE_NEEDS_IDENTIFIER)
    end

    ti = node.value.full_type
    
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
    node.full_type = node.value.full_type
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
    vti = val_node.full_type
    vti = Type.new(vti) if vti && !vti.is_a?(Type)
    return nil unless vti

    if vti.list_collection?
      # When the target field is also @list (ArrayList), skip CopyNode wrapping.
      # The move mechanism will transfer the ArrayList struct directly.
      # CopyNode produces a slice which is the wrong type for ArrayList fields.
      et = expected_type.is_a?(Type) ? expected_type : nil
      return nil if et&.list_collection?

      copy = AST::CopyNode.new(val_node.token, val_node)
      copy.full_type = expected_type.is_a?(Type) ? expected_type : Type.new(expected_type || :Any)
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
      copy.full_type = Type.new(Type::STRING_TYPE, location: container_alloc)
      copy.storage = container_alloc
      copy.alloc = container_alloc
      return copy
    end

    if vti.string? && val_node.is_a?(AST::Identifier) && container_desc
      sym = val_node.symbol
      unless sym&.heap_provenance?
        error!(val_node, :STORE_STRING_NEEDS_COPY, name: val_node.name, container: container_desc)
      end
    end

    nil
  end

  sig { params(node: AST::CopyNode).returns(T.nilable(T::Boolean)) }
  def visit_CopyNode(node)
    visit(node.value)
    # COPY produces an owned deep-copy. The source is NOT consumed.
    # Clone the Type so mutating provenance doesn't affect the inner node.
    inner_type = node.value.full_type
    node.full_type = inner_type.is_a?(Type) ? Type.new(inner_type) : inner_type
    ti = node.full_type
    resolver = ->(name) { lookup_type_schema(name) rescue nil }

    # COPY of a primitive or Id<T> is a semantic no-op (value copy, no allocation).
    # All other explicit COPYs produce heap-owned data.
    source_sync = node.value.respond_to?(:symbol) ? node.value.symbol&.sync : nil
    is_value_copy = ti.is_a?(Type) &&
      source_sync.nil? && !ti.multiowned? && !ti.shared? &&
      (ti.primitive? || (ti.generic_instance? && ti.generic_base == :Id))
    if is_value_copy
      node.storage = :stack
    else
      # COPY always produces heap-owned data for non-value types.
      # Type's clone constructor inherits source provenance (e.g., :rodata from
      # a string literal); override on the cloned Type so internal Type
      # predicates (needs_cleanup?, finalize_storage) see :heap. The
      # storage_override is the authoritative signal for Locatable readers.
      ti.provenance = :heap if ti.is_a?(Type)
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
  sig { params(args: T::Array[T.untyped], node: T.untyped).returns(Symbol) }
  def infer_element_type(args, node)
    receiver = args.first
    ti = receiver&.full_type
    ti&.element_type&.resolved || :Any
  end

  # Infer return type for list.pop() — returns ?T (optional element type).
  sig { params(args: T::Array[T.untyped], node: T.untyped).returns(Symbol) }
  def infer_optional_element_type(args, node)
    receiver = args.first
    ti = receiver&.full_type
    elem = ti&.element_type&.resolved || :Any
    :"?#{elem}"
  end

  # Infer return type for stream/list `.toList()` — an owned heap list
  # of the receiver's element type (unwrapping stream/promise tenses).
  sig { params(args: T::Array[T.untyped], node: T.untyped).returns(Type) }
  def infer_to_list(args, node)
    recv_t = Type.new(args[0].resolved_type)
    elem_t = if recv_t.dynamic_stream? || recv_t.promise_list?
      recv_t.tense_type.element_type
    elsif recv_t.bounded_stream?
      recv_t.stream_element_type
    elsif recv_t.inf_stream?
      recv_t.inf_stream_element_type
    elsif recv_t.open_stream?
      recv_t.open_stream_element_type
    else
      recv_t.element_type
    end
    Type.new(:"#{elem_t.resolved}[]", collection: :list, location: :heap)
  end

  sig { params(node: AST::LinkNode).returns(T.nilable(Type)) }
  def visit_LinkNode(node)
    visit(node.value)
    ti = node.value.full_type

    unless ti&.any_rc?
      error!(node, :LINK_NEEDS_SHARED_OR_MULTIOWNED, got: node.value.resolved_type)
    end

    # Result is the same base type with :link ownership
    link_type = Type.new(ti.resolved)
    link_type.ownership = :link
    # Track which strong ownership kind the link was created from
    link_type.link_source = ti.shared? ? :shared : :multiowned
    node.full_type = link_type
  end

  sig { params(node: AST::ResolveNode).returns(T.nilable(Type)) }
  def visit_ResolveNode(node)
    visit(node.value)
    ti = node.value.full_type

    unless ti&.link?
      error!(node, :RESOLVE_NEEDS_LINK, got: node.value.resolved_type)
    end

    # RESOLVE returns ?T@multiowned or ?T@shared.
    # Use RESOLVE(link)?.field OR fallback to safely access the target.
    source = ti.link_source || :multiowned
    resolved_type = Type.new(:"?#{ti.resolved}")
    resolved_type.ownership = source == :shared ? :shared : :multiowned
    resolved_type.link_source = source
    node.full_type = resolved_type
  end

  sig { params(node: AST::FreezeNode).returns(Symbol) }
  def visit_FreezeNode(node)
    visit(node.value)
    ti = node.value.full_type
    unless ti&.multiowned? || ti&.shared?
      error!(node, :FREEZE_NEEDS_OWNED, got: node.value.resolved_type)
    end
    base = ti.resolved.to_s.sub(/^\?/, '')
    result_type = Type.new(base.to_sym)
    result_type.ownership  = :frozen
    node.full_type = result_type
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

    node.full_type = node.value.resolved_type
  end

  sig { params(node: AST::Copy).void }
  def visit_Copy(node)
    visit(node.value)

    # Validate that the type is actually copyable
    type = node.value.full_type
    unless type&.copyable? { |name| lookup_type_schema(name) }
      error!(node, :COPY_NON_COPYABLE, type: node.value.resolved_type)
    end

    node.full_type = node.value.resolved_type
  end

  sig { params(node: AST::CloneNode).returns(T.nilable(T::Boolean)) }
  def visit_CloneNode(node)
    visit(node.value)
    type = node.value.full_type
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
      error!(node, :CLONE_WITH_SCOPED, name: root.name)
    end

    unless type&.split_open_stream? || type&.shared_promise? || type&.any_rc?
      error!(node, :CLONE_BAD_TARGET, got: node.value.resolved_type)
    end

    node.full_type = node.value.full_type
    node.storage = node.value.storage
    current_fn_ctx.needs_rt = true if current_fn_ctx && type&.any_rc?
  end

  sig { params(node: AST::ShareNode).void }
  def visit_ShareNode(node)
    visit(node.value)
    source_type = node.value.full_type
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
      error!(node, :SHARE_WITH_SCOPED, name: root.name)
    end

    result = Type.new(source_type, ownership: :shared)
    node.full_type = result
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
    type = node.target.full_type
    unless type&.optional?
      error!(node, :UNWRAP_NON_OPTIONAL, got: node.target.resolved_type)
    end

    # The result type is the wrapped type (without the ?)
    # Preserve ownership/sync so Rc/Arc auto-deref works on the unwrapped value.
    unwrapped = type.wrapped_type
    result = Type.new(unwrapped.resolved)
    result.ownership = type.ownership if type.ownership
    result.sync = type.sync if type.sync
    result.link_source = type.link_source if type.link_source
    node.full_type = result
  end

  sig { params(node: AST::WithBlock).returns(T.nilable(Symbol)) }
  def visit_WithBlock(node)
    @with_block_depth = (@with_block_depth || 0) + 1

    # Reject WITH MATCH shapes that would silently miscompile.
    #
    # `WITH c AS MUTABLE va MATCH ... WHEN VERSIONED -> { va.field = X }`
    # writes through the read-snapshot Guard — the write goes into a
    # frozen pointer that's about to be replaced and never commits. The
    # LOCKED arm works (Guard.get() returns *T into the live cell), so
    # the bug only fires for the VERSIONED arm at runtime. Reject up
    # front and direct the user to `WITH SNAPSHOT cell AS MUTABLE va
    # { ... } ON MvccConflict ...` for transactional mutation.
    #
    # SNAPSHOT MATCH bypasses this rejection because each arm dispatches to
    # `Versioned.update`
    # (VERSIONED) or `AtomicPtr.update` (ATOMIC), which DO commit
    # transactionally. The legacy guard only applied to generic
    # WITH MATCH (no SNAPSHOT prefix), where the VERSIONED arm
    # would write through a read-snapshot Guard.
    #
    # Multi-cell WITH MATCH (`WITH c1 AS a1, c2 AS a2 MATCH`) is
    # parser-allowed but lower_with_match_block emits prelude for
    # `node.capabilities.first` only — secondary aliases are undefined
    # in arm bodies. Reject until codegen is extended.
    if node.arms && node.snapshot_mode.nil?
      has_versioned_arm = node.arms.any? { |arm| arm[:family] == :VERSIONED }
      mut_cap = node.capabilities.find { |c| c[:alias_mutable] }
      if has_versioned_arm && mut_cap
        error!(node, :WITH_MATCH_VERSIONED_AS_MUTABLE,
          name: (mut_cap[:var_node].respond_to?(:name) ? mut_cap[:var_node].name : 'cell'))
      end
      if node.capabilities.length > 1
        names = node.capabilities.map { |c|
          c[:var_node].respond_to?(:name) ? c[:var_node].name : "<expr>"
        }.join(", ")
        error!(node, :WITH_MATCH_MULTI_CELL, names: names)
      end
    end

    expanded_capabilities = []
    node.capabilities.each do |cap|
      acquire_capability!(node, cap, expanded_capabilities)
    end

    check_nested_lock_reacquire!(node, expanded_capabilities)

    # Run local rank checks before edge accumulation so ranked violations
    # produce direct diagnostics instead of later SCC errors.
    check_lock_rank_ordering!(node, expanded_capabilities)

    # WITH MATCH records blocking effects per arm, but lock-cycle edges stay
    # conservative at the outer level because any LOCKED-eligible call may
    # acquire a lock.
    fn_name_for_lock = current_fn_ctx&.name || "<top>"
    held_entries_now = @held_lock_types || []
    is_match_form = !node.arms.nil?
    expanded_capabilities.each do |cap|
      next unless cap[:capability] == :EXCLUSIVE || cap[:capability] == :write_locked_read
      record_with_acquire!(fn_name_for_lock, cap, held_entries_now, node.deadlock_escape)
      unless is_match_form
        # Exclusive lock acquisition may suspend the fiber on contention.
        record_effect(EffectTracker::BLOCKING)
        record_effect(EffectTracker::SUSPENDS)
      end
    end

    # Track which variable names / lock types become "held" on entering
    # this WITH. Only fallible captures qualify — BORROWED / RESTRICT
    # don't acquire a mutex. @held_lock_types is an Array of
    # { type:, opted_out: } so a WITH's deadlock_escape propagates to
    # every edge emitted from within its held scope.
    prev_held = @held_locks || {}
    @held_locks = prev_held.dup
    prev_held_types = @held_lock_types || []
    @held_lock_types = prev_held_types.dup
    cur_opt = !node.deadlock_escape.nil?
    expanded_capabilities.each do |cap|
      next unless cap[:capability] == :EXCLUSIVE || cap[:capability] == :write_locked_read
      vn = cap_var_name(cap[:var_node])
      @held_locks[vn] ||= { token: cap[:var_node].respond_to?(:token) ? cap[:var_node].token : node.token }
      t = lock_identity_of(cap)
      @held_lock_types << { type: t, opted_out: cur_opt } if t
    end

    # The child scope inherits parent variables for reads, but declarations
    # inside the WITH remain isolated. SNAPSHOT transaction bodies also need
    # effect tracking so retryable bodies cannot suspend after mutation starts.
    is_snapshot_txn_body = (node.snapshot_mode == :transaction)
    if is_snapshot_txn_body
      @inside_snapshot_txn = (@inside_snapshot_txn || 0) + 1
      prev_violations = @snapshot_txn_violations
      @snapshot_txn_violations = []
    end
    with_new_scope(current_scope) do
      expanded_capabilities.each { |cap| declare_capability_scope!(cap) }
      validate_and_visit_with_guards!(node)
      visit_stmts(node.body)
      validate_with_guard_no_body_mutation!(node)
      fallible_sources = retryable_with_fallible_sources(node.body)
      if is_snapshot_txn_body && !T.must(fallible_sources).empty?
        retryable_with_fallible_body_error!(
          node,
          "WITH SNAPSHOT ... AS MUTABLE",
          fallible_sources
        )
      end
      if retryable_with_universal_poly_candidate?(node) && !T.must(fallible_sources).empty?
        retryable_with_fallible_body_error!(
          node,
          "WITH POLYMORPHIC",
          fallible_sources
        )
      end
      if node.arms
        # Record family-specific prelude effects before each arm body so
        # the per-arm delta includes synthetic acquire/snapshot work.
        fn_ctx_name = current_fn_ctx&.name
        snapshot = fn_ctx_name && @fn_direct_effects[fn_ctx_name]&.dup
        per_arm_effects = []
        node.arms.each do |arm|
          before = fn_ctx_name && @fn_direct_effects[fn_ctx_name]&.dup
          # Family-specific prelude effects that the lowering will emit
          # for this arm. LOCKED acquires a mutex (BLOCKING + CONTENTION
          # + SUSPENDS); VERSIONED takes a snapshot via EBR pin
          # (CONTENTION); ATOMIC binds the alias to the cell ref so any
          # subsequent body access contends on the cache line (CONTENTION,
          # no BLOCKING — atomics never park).
          case arm[:family]
          when :LOCKED
            record_effect(EffectTracker::BLOCKING)
            record_effect(EffectTracker::CONTENTION)
            record_effect(EffectTracker::SUSPENDS)
          when :VERSIONED
            record_effect(EffectTracker::CONTENTION)
          when :ATOMIC
            record_effect(EffectTracker::CONTENTION)
          end
          with_new_scope(current_scope) do
            visit_stmts(arm[:body])
            finalize_scope(node)
          end
          if fn_ctx_name
            after = @fn_direct_effects[fn_ctx_name]
            arm_delta = after - before
            per_arm_effects << arm_delta
            # Roll back the fn's direct effects so the next arm sees a
            # clean baseline. We re-stamp the consensus and ?-form below.
            @fn_direct_effects[fn_ctx_name] = snapshot.dup
          end
        end
        if fn_ctx_name && !per_arm_effects.empty?
          # Concrete: effects present in EVERY arm (intersection).
          concrete = per_arm_effects.reduce(:&) || Set.new
          # Maybe: effects present in SOME arm but not all (symmetric diff
          # ∪ across arms minus intersection). Project to ?-form variants
          # for the contention/blocking axis.
          all_union = per_arm_effects.reduce(Set.new, :|)
          maybe_set = all_union - concrete
          concrete.each { |eff| @fn_direct_effects[fn_ctx_name].add(eff) }
          if maybe_set.include?(EffectTracker::CONTENTION)
            @fn_direct_effects[fn_ctx_name].add(EffectTracker::CONTENTION_MAYBE)
          end
          if maybe_set.include?(EffectTracker::BLOCKING)
            @fn_direct_effects[fn_ctx_name].add(EffectTracker::BLOCKING_MAYBE)
          end
          # Effects orthogonal to the contention axis (heap, yield, io,
          # etc.) that appear in some-but-not-all arms get added as
          # concrete — the fn will incur them on at least one path.
          (maybe_set - [EffectTracker::CONTENTION, EffectTracker::BLOCKING]).each do |eff|
            @fn_direct_effects[fn_ctx_name].add(eff)
          end
        end
      end
      finalize_scope(node)
    end
    if is_snapshot_txn_body
      txn_violations = @snapshot_txn_violations
      @inside_snapshot_txn -= 1
      @snapshot_txn_violations = prev_violations
      unless txn_violations.empty?
        kinds = txn_violations.map { |v| EffectTracker.display(v[:effect]) }.uniq.join(", ")
        error!(node, :WITH_SNAPSHOT_BODY_NOT_PURE, kinds: kinds)
      end
    end

    # Release borrows after the WITH block exits
    expanded_capabilities.each do |cap|
      vname = cap_var_name(cap[:var_node])
      if cap[:capability] == :RESTRICT
        @og.release_borrow("__restrict_#{vname}")
      elsif cap[:capability] == :BORROWED
        @og.release_borrow("__borrowed_#{vname}")
      end
    end

    # Restore held-lock state BEFORE visiting the ON/RETRY clause's action
    # body or message — on the error path the lock was never acquired, so
    # the action runs outside the held scope. Lock-cycle analysis must
    # see the action body as lock-free.
    @held_locks = prev_held
    @held_lock_types = prev_held_types

    validate_no_multi_object_atomic!(node)
    validate_lock_error_clause!(node, expanded_capabilities)
    # MVCC: SNAPSHOT-transaction bodies lower to
    # `Versioned.update[Multi](rt, alloc, ...)` (heap-allocates a new
    # version + retires the old via EBR), and a WITH MATCH with a
    # VERSIONED arm lowers to `Versioned.read(rt)` (lock-free, no
    # alloc, but rt is needed for the EBR pin). Both flavors require
    # `rt: *Runtime` threaded through the enclosing fn's signature.
    # Set `needs_rt` directly so compute_needs_rt! picks it up;
    # heap_count is reserved for actual heap allocations (T1 cleanup --
    # earlier code abused heap_count as a needs_rt sentinel).
    if current_fn_ctx
      versioned_arm = node.arms&.any? { |arm| arm[:family] == :VERSIONED }
      # MVCC: any WITH SNAPSHOT lowers to `Versioned.read(rt)` (read mode)
      # or `Versioned.update[Multi](rt, ...)` (transaction mode). Both
      # need rt threaded through the enclosing fn. Plus a WITH MATCH with
      # a VERSIONED arm uses Versioned.read(rt) inside the arm's prelude.
      if node.snapshot_mode == :read || node.snapshot_mode == :transaction || versioned_arm
        current_fn_ctx.needs_rt = true
      end
      # Universal-polymorphic mutation can route through Versioned/AtomicPtr
      # update helpers, so mark rt/fail here before compute_needs_rt! runs.
      if node.polymorphic && (node.capabilities || []).length == 1
        bound_var = node.capabilities.first[:var_node]
        bound_name = bound_var.respond_to?(:name) ? bound_var.name.to_s : nil
        bound_sym  = bound_var.symbol
        is_param   = bound_sym && bound_sym.respond_to?(:is_param) && bound_sym.is_param
        fn_node    = @fn_nodes[current_fn_ctx.name]
        has_req    = fn_node && fn_node.respond_to?(:requires) && fn_node.requires &&
                     fn_node.requires.key?(bound_name)
        if is_param && !has_req
          current_fn_ctx.needs_rt = true
          fn_node.can_fail = true if fn_node.respond_to?(:can_fail=)
        end
      end
    end
    # Queue this WITH for the post-pass handler-reachability check. Running
    # it here (during annotation) is too early — cycle information isn't
    # known until compute_lock_cycles! has propagated through @call_graph.
    record_lock_clause_site!(node, expanded_capabilities)

    @with_block_depth -= 1
    node.full_type = :Void
  end

  # Validate WithBlock#lock_error_clause. Requires at least one fallible
  # capability, each selector to resolve against the error registry, RETRY
  # to target only Transient-kind errors, and the selector set to overlap
  # the block's possible error set. Visits action message/body so types
  # are annotated. Action runs outside the WITH scope — the lock was never
  # acquired on the error path — so it is visited in the enclosing scope.
  #
  # Possible error set for WITH EXCLUSIVE / write_locked_read:
  #   {:LockTimeout, :LockCycle, :Deadlock}
  # Symbols matched by the clause are stamped onto clause[:matched_types];
  # unmatched types bubble up as their registry kind at codegen time.
  LOCK_POSSIBLE_TYPES = %i[LockTimeout LockCycle Deadlock].freeze
  # SNAPSHOT MUTABLE commit errors depend on the cell family.
  # @versioned -> MvccConflict (Versioned.update bounded retry).
  # @indirect:atomic -> AtomicConflict after bounded AtomicPtr retries.
  # The dispatch picks per cell at
  # validate_lock_error_clause! time; SNAPSHOT_POSSIBLE_TYPES is the
  # union over both for the resolve_error_selectors! reachability
  # check.
  SNAPSHOT_POSSIBLE_TYPES = %i[MvccConflict AtomicConflict].freeze

  sig { params(nodes: T::Array[T.untyped]).returns(T.nilable(T::Array[String])) }
  def retryable_with_fallible_sources(nodes)
    sources = []
    visit_fallible = T.let(nil, T.untyped)
    visit_fallible = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
        return
      when Array
        n.each { |item| visit_fallible.call(item) }
        return
      when Hash
        n.each_value { |v| visit_fallible.call(v) }
        return
      when AST::FunctionDef
        return
      when AST::Raise
        sources << "RAISE"
      when AST::OrRaise
        sources << "OR RAISE"
      when AST::FuncCall
        sources << n.name.to_s if retryable_with_call_fallible?(n)
        n.args.each { |arg| visit_fallible.call(arg) }
      when AST::MethodCall
        sources << "#{n.name}()" if retryable_with_call_fallible?(n)
        visit_fallible.call(n.object)
        n.args.each { |arg| visit_fallible.call(arg) }
      when AST::StaticCall
        sources << n.method_name.to_s if retryable_with_call_fallible?(n)
        n.args.each { |arg| visit_fallible.call(arg) }
      when AST::FreezeNode
        sources << "FREEZE"
        visit_fallible.call(n.value)
      else
        n.each_pair { |_, v| visit_fallible.call(v) } if n.respond_to?(:each_pair)
      end
    end
    visit_fallible.call(nodes)
    sources.uniq
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def retryable_with_call_fallible?(node)
    return true if node.respond_to?(:can_fail) && node.can_fail
    return true if node.respond_to?(:error_union_type) && node.error_union_type
    false
  end

  sig { params(node: AST::WithBlock).returns(T.nilable(T::Boolean)) }
  def retryable_with_universal_poly_candidate?(node)
    return true if node.universal_poly
    return false unless node.polymorphic && (node.capabilities || []).length == 1

    bound_var = node.capabilities.first[:var_node]
    bound_name = bound_var.respond_to?(:name) ? bound_var.name.to_s : nil
    bound_sym = bound_var.symbol
    is_param = bound_sym && bound_sym.respond_to?(:is_param) && bound_sym.is_param
    fn_node = @fn_nodes[current_fn_ctx&.name]
    has_req = fn_node && fn_node.respond_to?(:requires) && fn_node.requires &&
              fn_node.requires.key?(bound_name)
    is_param && !has_req
  end

  sig { params(node: AST::WithBlock, with_name: String, sources: T.nilable(T.any(T::Array[T.untyped], T::Array[T.untyped]))).void }
  def retryable_with_fallible_body_error!(node, with_name, sources)
    detail = T.must(sources).first(3).join(", ")
    detail += ", ..." if T.must(sources).length > 3
    error!(node, :WITH_RETRYABLE_FALLIBLE_BODY, with_name: with_name, detail: detail)
  end

  sig { params(node: AST::WithBlock, expanded_capabilities: T::Array[T::Hash[T.untyped, T.untyped]]).void }
  def validate_lock_error_clause!(node, expanded_capabilities)
    clause = node.lock_error_clause
    is_snapshot_txn = node.snapshot_mode == :transaction

    # SNAPSHOT MATCH MUTABLE arms own their conflict handlers, so validate
    # them before the single-arm checks below.
    if node.arms && is_snapshot_txn
      validate_snapshot_match_arms!(node)
      return
    end

    # AtomicPtr and Versioned cells have different conflict surfaces, so
    # choose the handler contract from the participating cell family.
    snap_caps = node.capabilities || []
    has_atomic_ptr = is_snapshot_txn && snap_caps.any? { |c|
      next false unless c[:capability] == :SNAPSHOT
      sym = c[:var_node]&.respond_to?(:symbol) ? c[:var_node].symbol : nil
      sym && sym.atomic? && sym.respond_to?(:layout) && sym.indirect?
    }

    # Missing per-WITH conflict handlers fall back to SYNC POLICY. Stamp the
    # synthesized clause onto the node so lowering uses the same catch path.
    if is_snapshot_txn && clause.nil?
      target_error = has_atomic_ptr ? :AtomicConflict : :MvccConflict
      synth = synthesize_clause_from_policy(target_error)
      if synth
        node.lock_error_clause = synth
        clause = synth
      else
        error!(node, :WITH_SNAPSHOT_NEEDS_HANDLER, error: target_error)
      end
    end

    # AtomicPtr commits can raise AtomicConflict, not MvccConflict.
    if has_atomic_ptr && clause
      bad_selector = (clause[:selectors] || []).find { |s|
        s[:form] == :type && s[:name] == :MvccConflict
      }
      if bad_selector
        error!(node, :WITH_ATOMIC_HANDLER_WRONG_ERROR)
      end
    end

    return unless clause

    # SNAPSHOT-read should not carry a Conflict handler -- pure reads
    # cannot fail. Accept silently for now (parser already restricts the
    # syntax shape); a future polish pass could note the dead clause.

    has_guard = (node.capabilities || []).any? { |c| c[:guard_expr] }
    has_fallible = has_guard || is_snapshot_txn || expanded_capabilities.any? { |c|
      c[:capability] == :EXCLUSIVE || c[:capability] == :write_locked_read
    }
    unless has_fallible
      error!(node, :ON_RETRY_NEEDS_FALLIBLE_CAP, hint: "(EXCLUSIVE on @locked/@writeLocked, or read on @writeLocked). " \
             "The declared capabilities never produce a lock-acquire error.")
    end

    resolve_error_selectors!(node, clause, is_snapshot_txn)

    case clause[:action]
    when :exit
      visit(clause[:message]) if clause[:message]
    when :return
      visit(clause[:value]) if clause[:value]
    when :block
      visit_stmts(clause[:body]) if clause[:body]
    end
  end

  # Reject `cfg.field = ...` when `cfg` is `@indirect:atomic`. The cell
  # publishes whole-T snapshots via atomic pointer swap, not per-field writes.
  # Only the WITH SNAPSHOT MUTABLE alias (a regular *T pointer
  # passed to AtomicPtr.update's closure) accepts field assignments.
  #
  # The alias's SymbolEntry is declared with sync=nil and
  # layout=nil (capabilities.rb's SNAPSHOT branch passes neither
  # to scope.declare), so this check fires only on the original
  # cell binding -- the alias path falls through.
  #
  # Walks the target's chain to find the root Identifier. For
  # GetField / GetIndex chains rooted at an @indirect:atomic
  # binding, fires the rejection. Other chain shapes (param
  # passing, etc.) are handled elsewhere.
  sig { params(field_node: AST::GetField, assignment_node: AST::Assignment).void }
  def reject_bare_atomic_ptr_mutation!(field_node, assignment_node)
    root = T.let(field_node, AST::GetField)
    root = root.target while root.respond_to?(:target) && !root.is_a?(AST::Identifier)
    return unless root.is_a?(AST::Identifier)
    sym = root.symbol
    return unless sym
    return unless sym.atomic?
    return unless sym.respond_to?(:layout) && sym.indirect?

    error!(assignment_node, :INDIRECT_ATOMIC_FIELD_WRITE,
      name: root.name, field: field_name_for_msg(field_node))
  end

  # Pull the leaf field name out of a GetField chain for the error
  # message ("for mutation" snippet). Returns "<field>" or "field".
  sig { params(node: AST::GetField).returns(String) }
  def field_name_for_msg(node)
    return node.field.to_s if node.respond_to?(:field) && node.field
    "<field>"
  end

  # Reject multi-binding WITH when any sync-constrained cell could be atomic:
  # CLEAR has no portable multi-pointer atomic primitive, so the operation
  # would not be atomic across cells.
  #
  # Covers all multi-binding WITH forms (plain, POLYMORPHIC, SNAPSHOT,
  # SNAPSHOT MATCH). Sync-only: BORROWED / RESTRICT / VIEW /
  # MATERIALIZED VIEW capabilities don't count toward the multi-binding
  # threshold (they don't synchronize).
  #
  # Atomic is admitted when:
  #   - a binding has concrete sync `:atomic` (primitive or indirect:atomic).
  #   - a polymorphic param's REQUIRES disjunction includes `:ATOMIC`
  #     literally, or `:SNAPSHOTTED` (which expands to {VERSIONED, ATOMIC}).
  # The fix: narrow REQUIRES to a non-ATOMIC family
  # (e.g. `LOCKED | VERSIONED`), or refactor to single-cell WITHs.
  sig { params(node: AST::WithBlock).void }
  def validate_no_multi_object_atomic!(node)
    caps = (node.capabilities || []).select { |c| sync_constrained_cap?(c) }
    return if caps.size < 2

    arm_admits_atomic = (node.arms || []).any? { |arm| arm[:family] == :ATOMIC }
    offender = caps.find { |c| cap_admits_atomic?(c) }
    return unless offender || arm_admits_atomic

    var_name = if offender
      offender[:var_node].respond_to?(:name) ? offender[:var_node].name : "<expr>"
    else
      "this WITH"
    end

    error!(node, :WITH_MULTI_OBJECT_ATOMIC, name: var_name)
  end

  # A capability is sync-constrained only when it synchronizes against a
  # runtime cell. Pure borrows and observable reads do not count.
  sig { params(cap: AST::Capability).returns(T::Boolean) }
  def sync_constrained_cap?(cap)
    case cap[:capability]
    when :BORROWED, :RESTRICT, :VIEW, :MATERIALIZED_VIEW, :multiowned, :shared
      false
    when :EXCLUSIVE, :write_locked_read, :SNAPSHOT, :ATOMIC
      true
    when :infer
      # Inferred from the var_node's actual sync (if any).
      sym = cap[:var_node]&.respond_to?(:symbol) ? cap[:var_node].symbol : nil
      return false unless sym
      !sym.sync.nil? || (sym.respond_to?(:sync_families) && sym.sync_families && !sym.sync_families.empty?)
    else
      false
    end
  end

  # Does this capability's binding potentially run as `:atomic` at runtime?
  #   - concrete sync `:atomic` (covers primitive @atomic and
  #     indirect:atomic via sym.indirect?, both flagged
  #     by sym.atomic?);
  #   - polymorphic REQUIRES disjunction admitting :ATOMIC or
  #     :SNAPSHOTTED (which expands to {VERSIONED, ATOMIC}).
  sig { params(cap: AST::Capability).returns(T::Boolean) }
  def cap_admits_atomic?(cap)
    sym = cap[:var_node]&.respond_to?(:symbol) ? cap[:var_node].symbol : nil
    return false unless sym
    return true if sym.atomic?
    fams = sym.respond_to?(:sync_families) ? sym.sync_families : nil
    return false unless fams.is_a?(Set)
    expanded = WithMatchCheck.expand_snapshotted(fams)
    expanded.include?(:ATOMIC)
  end

  # Per-arm conflict-handler validation for SNAPSHOT MATCH MUTABLE blocks.
  # The two families have different contracts:
  #   - VERSIONED arm: REQUIRES at least one `ON MvccConflict` clause
  #     (mirrors the single-arm M5 contract; Versioned.update bounds
  #     retries and surfaces UpdateRetriesExhausted -> MvccConflict).
  #   - ATOMIC arm: FORBIDS conflict handlers (today rcu retries
  #     until success; when bounded, the right handler is
  #     `ON AtomicConflict`, not `ON MvccConflict`.
  # Read-mode SNAPSHOT MATCH (no MUTABLE) skips this entirely --
  # read paths can't fail, so neither arm needs / accepts a handler.
  sig { params(node: AST::WithBlock).returns(T.nilable(T::Array[T.untyped])) }
  def validate_snapshot_match_arms!(node)
    (node.arms || []).each do |arm|
      clauses = arm[:lock_error_clauses] || []
      case arm[:family]
      when :VERSIONED
        # VERSIONED arms without an inline handler fall back to SYNC POLICY.
        if clauses.empty?
          synth = synthesize_clause_from_policy(:MvccConflict)
          if synth
            arm[:lock_error_clauses] = [synth]
          else
            error!(node, :WITH_SNAPSHOT_MATCH_VERSIONED_NEEDS_HANDLER)
          end
        end
      when :ATOMIC
        unless clauses.empty?
          error!(node, :WITH_SNAPSHOT_MATCH_ATOMIC_FORBIDS_HANDLER)
        end
      end
    end
    # Visit per-arm ON MvccConflict action bodies so types are
    # annotated. Mirrors the single-arm pass at the bottom of
    # validate_lock_error_clause!.
    (node.arms || []).each do |arm|
      (arm[:lock_error_clauses] || []).each do |clause|
        case clause[:action]
        when :exit
          visit(clause[:message]) if clause[:message]
        when :block
          visit_stmts(clause[:body]) if clause[:body]
        end
      end
    end
  end

  # Expand each selector to its matched error-type symbols against the
  # error registry + the block's possible error set. Enforces:
  #   1. Every :kind selector names one of the 6 ErrorKinds.
  #   2. Every :type selector names a known error type (AST::ERROR_TYPES).
  #   3. Retry selectors resolve to Transient types only.
  #   4. The matched set intersects the block's possible error set.
  sig { params(node: AST::WithBlock, clause: T::Hash[Symbol, T.untyped], is_snapshot_txn: T::Boolean).returns(T.nilable(T::Array[Symbol])) }
  def resolve_error_selectors!(node, clause, is_snapshot_txn = false)
    possible = Set.new
    possible.merge(SNAPSHOT_POSSIBLE_TYPES) if is_snapshot_txn
    if (node.capabilities || []).any? { |c| c[:capability] == :EXCLUSIVE || c[:capability] == :write_locked_read }
      possible.merge(LOCK_POSSIBLE_TYPES)
    end
    possible << :GuardFail if (node.capabilities || []).any? { |c| c[:guard_expr] }
    possible = possible.to_a
    matched  = []

    clause[:selectors].each do |sel|
      case sel[:form]
      when :kind
        unless AST.error_kind?(sel[:name])
          emit_registry_mismatch!(
            sel[:token], sel[:name], AST::ERROR_KINDS,
            "Unknown error kind '#{sel[:name]}'. Expected one of: #{AST::ERROR_KINDS.join(', ')}",
            "closest known kind"
          )
        end
        matched.concat(AST.types_for_kind(sel[:name])) if AST.error_kind?(sel[:name])
      when :type
        unless AST.error_type?(sel[:name])
          emit_registry_mismatch!(
            sel[:token], sel[:name], AST::ERROR_TYPES.keys,
            "Unknown error type '#{sel[:name]}'. Register it in src/ast/error_registry.rb.",
            "closest registered type"
          )
        end
        matched << sel[:name] if AST.error_type?(sel[:name])
      end
    end

    matched.uniq!

    if clause[:retries]
      non_transient = matched.reject { |t| AST.kind_of_type(t) == :Transient }
      unless non_transient.empty?
        error!(clause[:token] || node, :RETRY_ONLY_TRANSIENT, types: non_transient.join(', '))
      end
    end

    overlap = matched & possible
    if overlap.empty?
      error!(node, :SELECTORS_NO_MATCH, matched: matched.join(', '), possible: "any error the WITH acquire can produce (#{possible.join(', ')}).")
    end

    clause[:matched_types] = overlap
    clause[:bubble_types]  = possible - overlap
  end

  # Walk statements looking for assignments where a borrowed alias escapes
  # to an outer-scope variable.
  sig { params(node: AST::DoBlock).returns(T.nilable(Symbol)) }
  def visit_DoBlock(node)
    node.branches.each do |branch|
      visit_stmts(branch[:body])

      full_analysis = analyze_fiber_captures(branch[:body], is_parallel: branch[:parallel])
      branch[:capture_analysis] = full_analysis

      if branch[:parallel]
        error!(node, :LOCAL_VAR_NOT_IN_PARALLEL) if full_analysis.has_local
        error!(node, :MULTIOWNED_NOT_IN_PARALLEL) if full_analysis.has_rc
      end

      if full_analysis.has_non_escaping_capture
        error!(node, :DO_CAPTURES_WITH_SCOPED, hint: "WITH bindings are stack aliases that become invalid when the WITH block exits. " \
               "Move the DO block outside the WITH block, or use COPY to get an owned value.")
      end

      analysis = (!branch[:pinned] && !branch[:parallel] && full_analysis.has_shared) ? full_analysis : nil

      if analysis && !branch[:pinned]
        branch[:pinned] = true
        note!(node, "DO branch auto-pinned — captures shared/locked resource. Use @parallel to distribute.")
      end
    end
    node.full_type = :Void
  end

  sig { params(node: AST::BgStreamBlock).void }
  def visit_BgStreamBlock(node)
    # Effect tracking: generators are inherently unbounded (run until exhausted or cancelled).
    record_effect(EffectTracker::LOOP_UNBOUND)

    # Body runs in a separate generator fiber. YIELD expressions push values into the stream.
    # The stream element type T is inferred from YIELD expression types.
    prev_stream_ctx  = @current_stream_context
    prev_yield_types = @stream_yield_types
    @current_stream_context = T.let(node, T.nilable(AST::BgStreamBlock))
    @stream_yield_types = []

    visit_stmts(node.body)

    yield_types = @stream_yield_types
    @current_stream_context = prev_stream_ctx
    @stream_yield_types     = prev_yield_types

    if yield_types.empty?
      error!(node, :BG_STREAM_NO_YIELD)
    end

    elem_syms = yield_types.map(&:resolved).uniq
    if elem_syms.size > 1
      error!(node, :BG_STREAM_INCONSISTENT_YIELD, types: elem_syms.join(', '))
    end

    node.full_type = Type.new(:"~?#{elem_syms.first}[]")

    # Compute captures for transpiler (same as BG blocks).
    stream_analysis = analyze_fiber_captures(node.body)
    node.capture_analysis = stream_analysis

    if stream_analysis.has_non_escaping_capture
      error!(node, :BG_STREAM_CAPTURES_WITH_SCOPED, hint: "WITH bindings are stack aliases that become invalid when the WITH block exits. " \
             "Move the BG STREAM block outside the WITH block, or use COPY to get an owned value.")
    end
  end

  sig { params(node: AST::YieldExpr).void }
  def visit_YieldExpr(node)
    unless @current_stream_context
      error!(node, :YIELD_OUTSIDE_BG_STREAM)
    end
    visit(node.expr)
    node.full_type = Type.new(node.expr.full_type_or(:Void))
    T.must(@stream_yield_types) << Type.new(node.full_type)
    record_effect(EffectTracker::SUSPENDS)
  end

  sig { params(node: AST::BgBlock).returns(T.nilable(T::Boolean)) }
  def visit_BgBlock(node)
    # Body runs in a separate fiber. The last expression's type determines T in ~T.
    # node.stack_size: :standard | :micro | :large | :xl | nil  (nil → STANDARD default)
    record_effect(EffectTracker::YIELD)
    outer_scope = current_scope
    locally_bound = Set.new
    prev_bg_pinned = @current_bg_pinned
    @current_bg_pinned = node.pinned

    last_type = T.let(:Void, Symbol)
    node.body.each do |expr|
      visit(expr)
      last_type = expr.respond_to?(:full_type) ? expr.full_type_or(:Void) : :Void
      # Track names declared inside the body so we don't treat them as outer captures.
      if (expr.is_a?(AST::BindExpr) || expr.is_a?(AST::VarDecl)) && expr.name.is_a?(String)
        locally_bound << expr.name
      end
    end
    # Strip leading `!` from the body's last-expression type: a BG fiber
    # catches its body's errors internally and surfaces them via the
    # Promise's join boundary, not via the surface success type. So
    # `BG { napFor(50); }` (where napFor is `!Void`) is `~Void`, not
    # `~!Void` -- the latter would force callers to write `~!Void[]@list`
    # and break the Zig codegen, which expects `Promise(T)` where `T`
    # is the success type.
    last_type_str = last_type.to_s
    if last_type_str.start_with?('!')
      last_type = T.must(last_type_str[1..]).to_sym
    end
    node.full_type = Type.new(:"~#{last_type}")

    # @arena implies @pinned — thread-local arena memory can't be stolen.
    if node.arena_mode
      node.pinned = true
      if node.parallel
        error!(node, :BG_ARENA_AND_PARALLEL)
      end
    end

    # Single walk: compute captures, validate safety, detect shared state.
    # Store on node for transpiler to read (eliminates re-walking).
    full_analysis = analyze_fiber_captures(node.body, is_parallel: node.parallel)
    node.capture_analysis = full_analysis

    # Validate: @local in @parallel, @rc in @parallel
    if node.parallel
      error!(node, :LOCAL_VAR_NOT_IN_PARALLEL) if full_analysis.has_local
      error!(node, :MULTIOWNED_NOT_IN_PARALLEL) if full_analysis.has_rc
    end

    # WITH-scoped (BORROWED/RESTRICT) bindings cannot escape into fibers.
    # The fiber may outlive the WITH block, turning the alias into a dangling pointer.
    if full_analysis.has_non_escaping_capture
      error!(node, :BG_CAPTURES_WITH_SCOPED, hint: "WITH bindings are stack aliases that become invalid when the WITH block exits. " \
             "Move the BG block outside the WITH block, or use COPY to get an owned value.")
    end

    # Auto-pin detection
    analysis = (!node.pinned && !node.parallel && full_analysis.has_shared) ? full_analysis : nil

    # Safety: pinned scope → child BG must also be pinned if it captures outer vars.
    if @current_bg_pinned && !node.pinned && captures_outer_variables?(node.body, locally_bound)
      error!(node, :BG_PINNED_CAPTURE_MISMATCH, hint: "Thread-local memory cannot escape to a stealable fiber. " \
             "Add @pinned to this BG block, or avoid capturing variables from the pinned scope.")
    end

    # Auto-pin when shared state is captured (uses result from validate_fiber_captures!).
    if analysis && !node.pinned
      if analysis.has_local
        node.pinned = :local
        note!(node, "BG block auto-pinned — captures @local resource (same-scheduler affinity).")
      elsif analysis.has_affine_locked
        node.pinned = :shared
        note!(node, "BG block auto-pinned — captures @locked resource (round-robin scheduler affinity).")
      else
        node.pinned = :local
        if analysis.has_sharded
          note!(node, "BG block auto-pinned — captures @sharded map (scheduler affinity for shard locality).")
        else
          note!(node, "BG block auto-pinned — captures shared/locked resource. Use @parallel to override.")
        end
      end
    end

    walk_bg_capture_moves(node.body, outer_scope, locally_bound)
    @current_bg_pinned = prev_bg_pinned
  end

  sig { params(node: AST::ThenChain).void }
  def visit_ThenChain(node)
    # Sequential chaining: each step runs in order inside the same fiber.
    # Steps with AS bindings declare a local variable accessible to later steps.
    # The last step's type determines the ThenChain's type.
    #
    # Error propagation: if a step returns !T and has an AS binding, the
    # binding type is T (unwrapped). The error propagates to the BG result
    # via try/errdefer in the generated Zig code.
    last_type = T.let(:Void, Symbol)
    node.steps.each do |step|
      visit(step[:expr])
      step_type = step[:expr].respond_to?(:full_type) ? step[:expr].full_type_or(:Void) : :Void

      if step[:binding]
        # Unwrap error union for the binding: !T -> T
        bind_type = step_type
        t = Type.new(step_type)
        bind_type = t.payload_type if t.error_union?

        current_scope.declare(
          step[:binding],
          nil,
          bind_type,
          false,  # immutable
          false,  # not rebindable
          nil,
          :stack
        )
      end

      last_type = step_type
    end
    node.full_type = last_type
  end

  sig { params(node: AST::NextExpr).returns(T.nilable(Symbol)) }
  def visit_NextExpr(node)
    record_effect(EffectTracker::YIELD)
    visit(node.expr)
    promise_type = Type.new(node.expr.full_type_or(:Void))

    unless promise_type.future?
      error!(node, :NEXT_NEEDS_FUTURE, got: node.expr.full_type)
    end

    # NEXT awaits a promise/stream — always a fiber suspension point.
    record_effect(EffectTracker::SUSPENDS)

    if promise_type.promise_list?
      # NEXT on ~T[]@list: await all promises, return T[]@list.
      # The promise list is linearly consumed — each inner promise is freed by its next() call.
      if node.expr.is_a?(AST::Identifier)
        og_set_moved(node.expr.name, at_token: node.expr.token, action: :next)
      end
      elem_sym = promise_type.tense_type.element_type.to_sym
      node.full_type = Type.new(:"#{elem_sym}[]", collection: :list)
    elsif promise_type.observable? && promise_type.tense_type&.array?
      # NEXT on ~T[]@set:observable: wait for the producer fiber, then
      # take an owned `T[]` snapshot via `materializeNext(alloc)`. The
      # codegen path lives in lower_next_expr; here we just stamp the
      # binding's type so downstream `final.length()` etc. resolve.
      #
      # Mark the source binding moved so a second NEXT is rejected.
      # The cleanup path destroys the StreamSet at end-of-scope; a
      # second NEXT after that would be UAF. Even before scope exit,
      # `materializeNext` waits for `finish()` -- the producer is
      # done after the first call, so a second NEXT would just
      # re-take the same snapshot, violating the consume-or-transfer
      # semantics. Match scalar-NEXT behavior: linearly consume.
      og_set_moved(node.expr.name, at_token: node.expr.token, action: :next) if node.expr.is_a?(AST::Identifier)
      elem_sym = promise_type.tense_type.element_type.to_sym
      node.full_type = Type.new(:"#{elem_sym}[]")
      node.storage   = :heap
    elsif promise_type.dynamic_stream?
      elem_sym = promise_type.tense_type.element_type.to_sym
      node.full_type = Type.new(:"?#{elem_sym}")
    elsif promise_type.bounded_stream?
      # NEXT on ~T[N]: returns T (the element type).
      # Does NOT mark the stream as moved — the stream can be NEXT'd up to N times.
      node.full_type = promise_type.stream_element_type.to_sym
    elsif promise_type.shared_promise?
      # NEXT on ~T@shared: returns T, idempotent — same handle can be NEXT'd again.
      # Does NOT mark as moved; multiple consumers may hold their own handles.
      node.full_type = promise_type.tense_type.to_sym
    elsif promise_type.split_open_stream?
      # NEXT on ~?T[]@split: returns ?T — each handle advances independently through
      # the shared memoized sequence until exhaustion.
      elem_sym = promise_type.open_stream_element_type.to_sym
      node.full_type = Type.new(:"?#{elem_sym}")
    elsif promise_type.open_stream?
      # NEXT on ~?T[]: returns ?T — null signals stream exhaustion.
      # Does NOT mark as moved — stream is a resource cleaned up via deinit.
      elem_sym = promise_type.open_stream_element_type.to_sym
      node.full_type = Type.new(:"?#{elem_sym}")
    elsif promise_type.inf_stream?
      # NEXT on ~T[INF]: returns T (never nil — stream is infinite, rendezvous-style).
      # Does NOT mark as moved — stream is a resource cleaned up via deinit.
      node.full_type = promise_type.inf_stream_element_type.to_sym
    else
      # NEXT on ~T: returns T, marks the promise as linearly consumed.
      if node.expr.is_a?(AST::Identifier)
        og_set_moved(node.expr.name, at_token: node.expr.token, action: :next)
      end
      node.full_type = promise_type.tense_type.to_sym
    end

    nil
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def get_root_object(node)
    curr = T.let(node, T.untyped)
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

  sig { params(node: T.untyped).returns(T.nilable(T::Boolean)) }
  def handle_assign_move(node)
    return if node.value.is_a?(AST::CopyNode)

    # Non-escaping values (WITH block aliases) cannot be moved/consumed.
    # Copy types (Int64, Bool, Float64, etc.) are exempt: assignment copies the
    # value with no pointer transfer, so no lifetime hazard exists.
    if node.value.is_a?(AST::Identifier) && node.value.symbol&.non_escaping
      vti = node.value.full_type
      needs_move = begin
        vti && Type.new(vti).requires_move?
      rescue
        true
      end
      if needs_move
        error!(node, :MOVE_WITH_SCOPED, name: node.value.name)
      end
    end
    if node.value.is_a?(AST::GetField) || node.value.is_a?(AST::GetIndex)
      # Container indexing of borrowed source into an owned target (HashMap
      # assignment) is an error. Plain variable declarations get borrow marking
      # via register_container_borrow! instead.
      if node.is_a?(AST::Assignment) && node.value.is_a?(AST::GetIndex)
        vti = node.value.full_type
        vti = Type.new(vti) if vti && !vti.is_a?(Type)
        is_copy = vti.is_a?(Type) ?
          (vti.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil } rescue true) :
          true
        unless is_copy
          container = find_container_source(node.value)
          if container
            source_name = root_variable_name(node.value)
            if source_name && @og[source_name]&.kind == :borrowed
              error!(node, :MOVE_BORROWED_INDEX, source: source_name)
            end
          end
        end
      end
      path = get_path_to_root(node.value)
      return if path.nil?
      if Type.new(node.value.resolved_type).requires_move?
        graph_path = path.map(&:to_s).join(".")
        @og.declare(graph_path, kind: :affine, scope_depth: @og_scope_depth) unless @og[graph_path]
        og_set_moved(graph_path, at_token: node.value.token, action: :move)
      end
      return
    end

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
    return if call_node.is_a?(AST::MethodCall) && (call_node.pool_method || call_node.set_method || call_node.map_method)

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
    if matched_def && matched_def.emit&.lifetime
      lifetime = matched_def.emit.lifetime
      if lifetime == "self" && call_node.is_a?(AST::MethodCall)
        return call_node.object
      end
      # Named param lifetime -- find by index in args list
      args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
      arg_types = matched_def.arg_spec
      if arg_types.is_a?(Array)
        idx = arg_types.index { |a| a.is_a?(Hash) && a[:name] == lifetime }
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
    return nil if lifetime.nil?
    lifetime = [lifetime] unless lifetime.is_a?(Array)
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
    return nil unless last.respond_to?(:full_type)
    # ELSE_IF chain: the last element is a nested IfStatement — use its result type
    if last.is_a?(AST::IfStatement)
      return last.then_result_type
    end
    ti = last.full_type
    return nil unless ti
    return nil if ti.void? || ti.resolved == :NoReturn
    # These are statement-level constructs, not value-producing expressions
    return nil if last.is_a?(AST::ReturnNode)   || last.is_a?(AST::VarDecl)   ||
                  last.is_a?(AST::BindExpr)      || last.is_a?(AST::Assignment) ||
                  last.is_a?(AST::WhileLoop)     || last.is_a?(AST::ForRange)   ||
                  last.is_a?(AST::ForEach)       || last.is_a?(AST::MatchStatement) ||
                  last.is_a?(AST::Assert)        || last.is_a?(AST::Raise)      ||
                  last.is_a?(AST::WithBlock)     || last.is_a?(AST::BgBlock)    ||
                  last.is_a?(AST::DoBlock)       || last.is_a?(AST::PassStmt)   ||
                  last.is_a?(AST::DieNode)       || last.is_a?(AST::ThrowNode)
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
      else_result = nested.full_type
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
    if_node.full_type = (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type
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
    match_node.full_type = (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type
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
        if t.future? && !t.stream? && !t.shared_promise? && !t.promise_list?
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
        if node && t.future? && !t.stream? && !t.shared_promise? && !t.promise_list?
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
  sig { params(decl_node: T.untyped).returns(T.nilable(T::Hash[Symbol, T::Array[SymbolEntry]])) }
  def stamp_bg_handle_lifetime!(decl_node)
    sources = collect_bg_sources_in_expr(decl_node.value).uniq
    return if sources.empty?
    sym = decl_node.symbol
    return unless sym
    sym.lifetime = SymbolEntry.tied_lifetime(sources)
  end

  # Single-writer stamp: "this binding's heap-bearing contents are already
  # in heap_provenance" -- so return-time promote is unnecessary (and would
  # leak by re-allocating). Legacy compatibility field. ONE writer
  # (bind-time), many readers (return-time). See docs/agents/provenance-collapse.md.
  sig { params(decl_node: T.untyped).void }
  def stamp_init_contents_heap!(decl_node)
    sym = decl_node.symbol
    return unless sym
    init = decl_node.respond_to?(:value) ? decl_node.value : nil
    sym.init_contents_heap = init_value_contents_heap?(init)
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
        fval.is_a?(AST::Locatable) && fval.heap_provenance?
      end
    when AST::FuncCall, AST::MethodCall
      init.is_a?(AST::Locatable) && init.heap_provenance?
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
      cases = (init.cases || []).map { |c| c.is_a?(Hash) ? c[:body]&.last : (c.respond_to?(:body) ? c.body&.last : nil) }.compact
      default = init.default_case
      default_tail = default.is_a?(Array) ? default.last : (default.respond_to?(:body) ? default.body&.last : nil)
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
  sig { params(node: T.untyped).returns(T.untyped) }
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
  # annotator-helpers/test_annotation.rb (TestAnnotation module).

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
      (@call_graph[name] || []).each { |c| queue << c }
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
      (@call_graph[name] || []).each { |c| queue << c }
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
      (@call_graph[name] || []).each { |c| queue << c }
    end
    nil
  end

  # ── Ownership Graph Operations ─────────────────────────────────

  # Determine which allocator cleanup should use for this binding.
  # Sets provenance on the type_info; cleanup_alloc is now derived from provenance.
  sig { params(node: T.untyped).returns(T.nilable(Symbol)) }
  def set_cleanup_alloc!(node)
    ti = node.full_type
    return unless ti

    # Check if value comes from a stdlib function with explicit metadata
    val = node.value
    if val && (val.is_a?(AST::FuncCall) || val.is_a?(AST::MethodCall))
      matched_def = val.matched_stdlib_def
      if matched_def
        # Borrow returns (lifetime:) need no cleanup -- the caller owns the data
        if matched_def.emit&.lifetime
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
    val_ti = val&.full_type
    val_ti = val_ti.is_a?(Type) ? val_ti : nil
    ti.provenance ||= val_ti&.provenance || alloc
  end

  sig { params(name: String, node: T.untyped, type_info: T.untyped).returns(T.untyped) }
  def og_declare(name, node, type_info)
    entry = current_scope.locals[name] rescue nil
    kind = classify_og_kind(type_info, sync: entry&.sync)
    ti = Type.from_node(type_info) || Type.new(:Untyped)
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

    ti = node.full_type
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
    vt = node.full_type
    vt = Type.new(vt) if vt && !vt.is_a?(Type)
    return unless vt.is_a?(Type)
    return if current_fn_ctx&.type_params&.include?(vt.resolved)
    return if vt.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
    existing = @og&.nodes&.[](node.name)
    if existing && existing.moved? && existing.move_action && existing.move_action != :move
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
    vti = val_node.full_type
    return if vti&.primitive?
    return if vti&.generic_instance?
    # Skip generic type parameters - can't determine borrowability at annotation time.
    return if current_fn_ctx&.type_params&.include?(vti&.resolved)
    has_pointer = vti&.array? || vti&.string? || vti&.collection? || vti&.map?
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

  sig { params(type_info: T.untyped, sync: T.nilable(Symbol)).returns(Symbol) }
  def classify_og_kind(type_info, sync: nil)
    return :affine unless type_info
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
  rescue
    :affine
  end

end
