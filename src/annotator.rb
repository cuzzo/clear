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
require_relative "mir/bg_capture_classifier"
require_relative "mir/effect_inference"
require_relative "mir/concurrency_checks"
require_relative "annotator-helpers/generic_analysis"
require_relative "annotator-helpers/capabilities"
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

# Handle Type inference, and semantic validation
class SemanticAnnotator
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

  attr_reader :scope_stack

  def current_fn_ctx
    @function_context_stack.last
  end

  # Run the given block with conditional_depth incremented on the current
  # function context (or the global fallback when outside a function).
  # Used to tag SUSPENDS effects recorded inside IF branches / MATCH arms
  # as SUSPENDS:CONDITIONAL.
  def with_conditional_context
    if current_fn_ctx
      current_fn_ctx.conditional_depth += 1
      begin
        yield
      ensure
        current_fn_ctx.conditional_depth -= 1
      end
    else
      @conditional_depth += 1
      begin
        yield
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

  def initialize(importer: nil, compiler: nil, source_dir: nil, strict_test: false, source_code: nil)
    @importer   = importer || compiler
    @source_dir = source_dir ? File.expand_path(source_dir) : Dir.pwd
    @strict_test = strict_test
    @source_code = source_code
    # We start with a global scope
    @scope_stack = [Scope.new]
    @function_context_stack = [] # Stack of expected return types
    @loop_depth = 0 # Track if we are inside a loop
    @conditional_depth = 0 # Track if we are inside an IF branch or MATCH arm
    @smooth_depth = 0
    @match_pattern_context = false # True when visiting a MATCH case value (suppresses inline-struct GetField error)
    # Reentrancy analysis
    @call_graph  = {}  # name => Set of directly-called function names (excluding self-calls)
    @fn_has_fnptr = {} # name => true if function calls a fn-type variable or lambda
    @fn_nodes    = {}  # name => FunctionDef node (for error reporting in the post-pass)
    # Performance analysis
    @fn_raises_directly = {}  # name => true if body has Raise/OrRaise, uses_frame, has_fnptr, or @nonReentrant
    # Capability audit — tracks declarations and usage to detect over-engineering.
    # SOA analysis: tracks which fields of `_` are accessed during pipeline lambda bodies.
    # nil = not inside a pipeline; Set = collecting field names.
    @pipeline_accessed_fields = nil

    # Phase 2 lock analysis storage (keyed by fn name). Hooked in
    # visit_WithBlock / user-fn-call visitors; cycle-checked as a
    # post-pass after @call_graph is complete.
    init_lock_analysis!
    # @pinned escape safety: true when inside a @pinned BG block.
    @current_bg_pinned = false
    # P1.7: WITH validations on parameter bindings are deferred to a
    # post-annotation pass so EscapeAnalysis.propagate_caller_sync! has a
    # chance to populate sync from callers' arg bindings first. Each entry:
    # { node:, var_node:, capability:, kind: :exclusive | :write_locked_read }
    @deferred_with_validations = []
    @predicate_call_sites = []
    # Tracks remaining statements in current body for forward reference analysis
    @stmts_after = nil
    # Ownership graph: shadow tracker that runs in parallel with the scope-based system.
    @og = OwnershipGraph.new
    @og_scope_depth = 0
    effects_init!
    capability_audit_init!
    setup_builtins
  end

  def annotate!(node)
    # Reset user-registered error types so state from prior runs (rspec
    # parallel, multi-program test harness) doesn't leak in. Stdlib
    # types are preserved.
    AST.reset_user_types!
    @program = node  # #327: WithMatchCheck reads node.sync_policy below.
    visit(node)
    # Auto / gradual-typing inference (gradual-typing.md M1.7).
    # After the body walk has populated `type_info` on every
    # constraint-source AST node, run Pass B (collector) + Pass C
    # (unifier) to resolve Auto slots. Resolved slots have their decl
    # types mutated to concrete; unresolved / ambiguous slots emit
    # fixable findings via M1.4 helpers. Runs BEFORE the downstream
    # analyses (effect inference, with-match check) so they see
    # finalized signatures.
    run_auto_inference!(node) if program_has_auto?(node)
    # P1.7: now that all bodies are annotated and arg.symbol is wired at
    # every call site, propagate caller sync into callee param entries.
    # Then re-check the WITH validations that we deferred during the body
    # walk; any param whose entry.sync is still nil is a genuine error.
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
    # P3.2: infer per-function effects (yield/alloc_heap/io/fail) and
    # propagate transitively through the call graph.
    EffectInference.analyze!(@fn_nodes)
    err = ->(n, msg) { error!(n, msg) }
    warn = ->(n, msg) { note!(n, msg) }
    sig_lookup = ->(name) {
      @scope_stack.first.locals[name]&.type
    }
    # P2.4 / P2.5 / P2.7 first: validates per-fn REQUIRES ↔ WITH and
    # auto-fills `fn.requires` for legacy code via the deprecation shim.
    # #327: pass the program-level SYNC POLICY handlers so the
    # polymorphic-warning surface knows what's already covered.
    policy_handlers = @program&.sync_policy
    @fn_nodes.each_value { |fn|
      WithMatchCheck.check_function!(fn, err, warn_handler: warn,
                                     policy_handlers: policy_handlers)
    }
    # Re-stamp signatures so call-site checks below see any shim-inferred
    # REQUIRES clauses.
    @fn_nodes.each do |name, fn|
      sig = @scope_stack.first.locals[name]&.type
      sig.requires = fn.requires if sig.is_a?(FunctionSignature)
    end
    # P2.6: call-site family check now runs against finalized REQUIRES.
    @fn_nodes.each_value { |fn| WithMatchCheck.check_call_sites!(fn, sig_lookup, err) }
    # P3.3-3.5: compile-time concurrency checks (hold-across-yield,
    # naked-nested-WITH, reentrant). The lock_ranks registry exempts
    # @locked(rank: N) sites from P3.4 — those are governed by the
    # pre-existing rank-DAG analysis instead.
    ConcurrencyChecks.check_all!(@fn_nodes, sig_lookup, err,
                                 lock_ranks: @lock_type_ranks || {})
    # Residual deferred WITH validations (any param whose sync is still
    # nil after propagation, e.g., a function called from no callsite).
    flush_deferred_with_validations!
    finalize_capability_audit!
  end

private

  # M1.7 — Auto / gradual-typing inference pipeline. Runs Pass B
  # (collect constraint sources) and Pass C (unify, resolve, emit
  # diagnostics) after the body walk has populated type_info on
  # every constraint source. Mutates decl types in place — Auto
  # Types become concrete after a successful resolution.
  #
  # M2.1 layers an operator-evidence collector that scans body
  # BinaryOp expressions for hints; ambiguity / unresolved findings
  # consult this evidence to offer ranked candidate fixes.
  def run_auto_inference!(program_node)
    collector = AutoConstraintCollector.new(@fn_nodes)
    slots = collector.collect!(program_node)
    return if slots.empty?

    # M2.2: forward-flow evidence for shape-tagged slots from empty
    # `[]` / `{}` initializers. Walks each fn body for `.append(e)`
    # / `x[k] = v` patterns and records the operands as constraint
    # sources on the matching shape slot.
    ShapeEvidenceCollector.new(slots, @fn_nodes).collect!

    # M2.1: collect operator hints from BinaryOps over Auto-binding
    # operands. Used by ambiguity / unresolved finding builders.
    op_evidence = OperatorEvidenceCollector.new(slots, @fn_nodes).collect!

    unifier = AutoUnifier.new(slots)
    result = unifier.resolve!

    # M2.2: stamp paired `:map_key` + `:map_value` resolutions into a
    # joint `HashMap<K, V>` type on the binding's decl.
    unifier.stamp_map_pairs!(result.resolved)

    # Resolved slots: emit :info findings with :auto fix (replace
    # the Auto keyword span with the resolved type's source form).
    # M2.2: shape slots are skipped by emit_auto_resolved_finding!
    # (per-sub-slot fixes would write the scalar where the wrapped
    # container type belongs). The shape-aware emission below
    # produces one finding per fully-resolved shape-tracked decl.
    result.resolved.each_value { |resolution| emit_auto_resolved_finding!(resolution) }
    emit_auto_shape_resolved_findings!(result.resolved)

    # Ambiguous slots: emit :error findings with the ranked Option 1/
    # 2/3 text plus operator-derived candidates (M2.1).
    result.ambiguous.each_value { |ambiguity|
      emit_auto_ambiguity_finding!(ambiguity, op_evidence: op_evidence)
    }

    # Unresolved slots: emit :error findings. M2.1 attaches ranked
    # candidates from operator evidence when the body uses the
    # binding in BinaryOp expressions. M2.2: shape sub-slots
    # (map_key / map_value / list_element) emit per-sub-slot
    # unresolved findings so the user knows which half is missing.
    result.unresolved.each_value { |slot|
      emit_auto_unresolved_finding!(slot, op_evidence: op_evidence)
    }
  end

  # M2.2 — One :info finding per shape-tracked decl whose type was
  # successfully wrapped (list_element resolved → `T[]`; map pair
  # both resolved → `HashMap<K,V>`). Groups by decl_node so map
  # pairs produce a single binding-level message instead of two
  # confusing per-sub-slot ones.
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
      return true if node.params.any? { |p| p[:type].is_a?(Type) && p[:type].auto? }
    end
    if node.respond_to?(:each_pair)
      return node.each_pair.any? { |_, v| program_has_auto?(v) }
    end
    false
  end

  # P1.7: replay each deferred WITH-on-param check now that caller-sync
  # propagation has had a chance to populate entry.sync. If a param's sync
  # is still nil, fire the original eager error.
  def flush_deferred_with_validations!
    @deferred_with_validations.each do |d|
      var_node = d[:var_node]
      syn = var_node.symbol&.sync
      case d[:capability]
      when :EXCLUSIVE
        next if syn
        storage = var_node.symbol&.storage
        error!(d[:node],
          "EXCLUSIVE capability requires a @locked or @writeLocked variable, " \
          "got #{storage || 'unknown'}")
      when :write_locked_read
        next if syn == :write_locked
        error!(d[:node],
          "WITH #{var_node.name}: read access requires a @writeLocked variable")
      end
    end
    @deferred_with_validations.clear
  end

  def setup_builtins
    STD_LIB.each do |name, config|
      current_scope.declare(name, nil, :Intrinsic, false, false, nil, :stack)
    end

    # Setup Globals
    current_scope.declare("argv", nil, Type::STRING_TYPE, false, false, nil, :heap)

    # Built-in Range type: fields accessible via dot access
    current_scope.declare_type(:Range, {"start" => :Float64, "end" => :Float64})

    # Built-in File resource type
    # bc/bc_op marks the static methods as VM-dispatchable so the lowering
    # produces a structural MIR::InlineBc that both backends consume. The
    # close_zig template carries to the resource's MIR::Cleanup unchanged
    # (Zig defers it; BC ignores -- the VM has no fd-style close).
    current_scope.declare_type(:File, {
      kind: :resource,
      close_zig: "{0}.close()",
      static_methods: {
        "open"   => { args: [:String], return: :File, zig: "try CheatLib.fileOpen({0})",
                       bc: true, bc_op: :file_open, can_fail: true },
        "create" => { args: [:String], return: :File, zig: "try CheatLib.fileCreate({0})",
                       bc: true, bc_op: :file_create, can_fail: true }
      }
    })

    # Built-in TCPServer resource type — a non-blocking server socket (i32 fd).
    # TCPServer::listen(port) returns the server fd; auto-closes via RAII.
    current_scope.declare_type(:TCPServer, {
      kind: :resource,
      close_zig: "CheatLib.socketClose({0})",
      static_methods: {
        "listen" => { args: [:Int64], return: :TCPServer, zig: "try CheatLib.socketListen(@intCast({0}))", can_fail: true }
      }
    })

    # Built-in TCPClient resource type — a connected client socket (i32 fd).
    # Produced by accept(server) or TCPClient::connect(host, port).
    # Auto-closes via RAII.
    current_scope.declare_type(:TCPClient, {
      kind: :resource,
      close_zig: "CheatLib.socketClose({0})",
      static_methods: {
        "connect" => { args: [:String, :Int64], return: :TCPClient,
                       zig: "try CheatLib.socketConnect({0}, @intCast({1}))", can_fail: true }
      }
    })
  end

  def visit(node)
    return unless node
    return if node.is_a?(Symbol)

    # Dynamic Dispatch
    method_name = "visit_#{node.class.name.split('::').last}"
    send(method_name, node)
  end

  # Cached outer scope variable set - avoids O(n) flat_map per loop
  def outer_scope_vars
    @scope_stack.flat_map { |s| s.locals.keys }.to_set
  end

  def visit_Program(node)
    # PASS 0: Process REQUIRE statements — import symbols from required files
    # before any types or functions in this file are registered.
    node.statements.each do |stmt|
      visit_RequireNode(stmt) if stmt.is_a?(AST::RequireNode)
    end

    # PASS 1: Hoist Types (StructDefs, ExternStructDecl, EnumDef, UnionDef)
    # Register all type definitions first so they can be used in function signatures.
    node.statements.each do |stmt|
      visit(stmt) if stmt.is_a?(AST::StructDef) || stmt.is_a?(AST::ExternStructDecl) ||
                     stmt.is_a?(AST::EnumDef)   || stmt.is_a?(AST::UnionDef)
    end

    # PASS 2: Hoist Function Signatures (FunctionDef + ExternFnDecl)
    # Register function signatures in the global scope.
    # This allows functions to call other functions defined later in the file.
    node.statements.each do |stmt|
      pre_register_function(stmt) if stmt.is_a?(AST::FunctionDef)
      visit_ExternFnDecl(stmt)    if stmt.is_a?(AST::ExternFnDecl)
    end

    # PASS 2.5: Validate union method requirements.
    # All function signatures are now registered; check that required methods exist.
    # Methods with default bodies that have no concrete override are synthesized here.
    @synthetic_fns = []
    node.statements.each do |stmt|
      next unless stmt.is_a?(AST::UnionDef) && stmt.methods&.any?
      validate_union_methods!(stmt)
    end
    # Pre-register synthesized default functions so Pass 3 bodies can call them.
    @synthetic_fns.each { |fn| pre_register_function(fn) }

    # PASS 2.6: Bridge legacy `@reentrant` and new `EFFECTS REENTRANT`
    # into a canonical `fn_node.reentrance_kind` field, and validate
    # every `REQUIRES <name>: NON_REENTRANT` clause names a real
    # parameter. Runs after Pass 2 (so @fn_nodes is fully populated)
    # and BEFORE Pass 3 (so visit_FunctionDef's recursion check sees
    # the back-filled legacy attrs when only EFFECTS REENTRANT was
    # declared). See annotator-helpers/reentrance.rb.
    bridge_reentrance!(node)

    # PASS 2.9: Seed the error-type registry from every RAISE site that
    # provides both a kind and a type. This pre-pass means CATCH Type
    # clauses can reference types registered by later-in-source RAISE
    # sites (source order independence). Collision diagnostics still
    # point at the first-seen site since register_type! records the
    # token.
    seed_error_types_from_raises!(node)

    # PASS 2.95: True-Sync-Polymorphism (#325). Validate any
    # `SYNC POLICY START ... END` block (single-instance, main-file-only,
    # completeness, inline-only-error guard). Stamps node.sync_policy
    # with the resolved policy (user-written or baked-in default) so
    # later passes can read a single source of truth.
    validate_and_resolve_sync_policy!(node)

    # PASS 3: Analyze Logic
    # Visit all statements in order.
    # - VarDecls will be registered here (linear scoping).
    # - FunctionDefs will be visited "fully" here (analyzing their bodies).
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

    # PASS 4: Indirect reentrancy cycle detection.
    # Now that all function bodies have been analyzed and @call_graph is complete,
    # detect mutually-recursive function groups and require @reentrant or @nonReentrant.
    check_indirect_reentrancy!

    # PASS 4.1a (F1): NOT_LOGICAL static-recursion validation.
    # Reject `:reentrant_not_logical` on a function the call-graph
    # proves is reachable from itself; nudge toward `:THUNK` /
    # `:MAX_DEPTH(N)` instead.
    validate_not_logical_recursion!

    # PASS 4.1b (F4): MAX_DEPTH-mutual-cycle warning. A `:MAX_DEPTH`
    # fn caught in a mutual cycle silently demotes to ':unbounded'
    # tier; warn so the user can pick the actual fix.
    validate_max_depth_mutual_cycle!

    # PASS 4.1: Thunk recursion validation. Distinguishes between
    # not-recursive-at-all, directly-self-recursive, and
    # mutually-recursive `:reentrant_thunk` functions. Mutual
    # recursion needs tagged-union frames -- not yet implemented;
    # error with a precise forward-pointing message so users know
    # to refactor to direct self-recursion or use plain
    # 'EFFECTS REENTRANT' for now.
    validate_thunk_recursion!

    # PASS 5: Compute needs_rt and can_fail for every function via call-graph fixed-point.
    compute_needs_rt!
    compute_can_fail!

    # PASS 5a (post-#334): enforce Zig-style fallible-signature discipline.
    # Every fn whose call-graph fixed-point determined `can_fail = true`
    # must declare its return type as an error union (`RETURNS !T`).
    # The check runs AFTER compute_can_fail! so transitive fallibility
    # is captured -- a fn that calls a fallible callee inherits the
    # requirement.
    enforce_fallible_returns!

    # PASS 5b: Functions referenced as fn-type values must match the fn-pointer calling
    # convention (*Runtime, params) !return. Mark them needs_rt=true so their signatures
    # are compatible with the fn-type Zig type emitted by type.rb#zig_type.
    mark_fn_value_references!(node)

    # PASS 6: Compute effect sets for every function via call-graph fixed-point.
    compute_effects!
    validate_predicate_purity!

    # PASS 6a: FSM Phase A — classify each function for stackless-fsm
    # compilation, enumerate suspend points, and tag every BG block with
    # spawn_form (:fsm / :stackful). Phase A only records metadata; the
    # emitter still produces stackful spawns. Phase B consumes this data.
    compute_fsm_eligibility!
    enumerate_fsm_suspend_points!
    classify_bg_spawn_form!(node)

    # PASS 6b: Static lock-cycle / self-deadlock detection. Propagates
    # lock acquires through @call_graph, synthesizes held-while-calling
    # edges, then runs SCC over the global held->acquired graph and
    # reports any cycles.
    check_lock_cycles!

    # PASS 7: Compute stack tier recommendations per function.
    compute_stack_tiers!

    # PASS 8: Auto-size fiber spawns (BG/DO blocks) from call-graph analysis.
    assign_fiber_stack_tiers!(node)

    # PASS 9: Copy computed metadata to FunctionSignature objects in scope.
    # This allows callers to read needs_rt, can_fail, return_provenance from
    # the signature without needing @fn_nodes.
    @fn_nodes.each do |name, fn|
      sig = fn.full_type
      # Unwrap Type objects that wrap a FunctionSignature (e.g. @reentrant functions
      # whose full_type was set to a Type by fn-type resolution).
      if sig.is_a?(Type) && sig.raw.is_a?(FunctionSignature)
        sig = sig.raw
      end
      next unless sig.is_a?(FunctionSignature)
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

  def visit_RequireNode(node)
    unless @importer
      error!(node, "REQUIRE is only supported when using the Importer. " \
                   "Pass importer: and source_dir: to SemanticAnnotator.new.")
    end

    mod = if node.kind == :package
      @importer.compile_package(node.path, caller_dir: @source_dir)
    else
      @importer.compile_file(node.path, caller_dir: @source_dir)
    end
    node.full_type = :Void

    # Packages are always external — only :pub symbols are importable.
    same_dir = (node.kind != :package) && (mod.source_dir == @source_dir)

    # Import function signatures that are visible from this call site.
    mod.global_scope.locals.each do |name, entry|
      sig = entry.type
      next unless sig.is_a?(FunctionSignature) || (sig.is_a?(Hash) && sig.key?(:params))

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
      imported_sig = sig.merge(module_alias: node.namespace)
      current_scope.declare(name, nil, imported_sig, false, false, nil, :static)
    end

    # Import type definitions (structs, unions, enums) respecting visibility.
    mod.global_scope.types.each do |type_name, type_entry|
      vis = type_entry[:schema][:visibility] || :package
      next if vis == :private
      next unless (vis == :pub) || (vis == :package && same_dir)
      current_scope.declare_type(type_name, type_entry[:schema])
    end
  end

  # EXTERN FN name(params) RETURNS type FROM "module"
  # Registers a native Zig/C function in the current scope.
  # At call sites, no rt is injected and no try is emitted.
  def visit_ExternFnDecl(node)
    signature = FunctionSignature.new(
      params: node.params.map { |p| {
        name: p[:name],
        type: p[:type],
        required: p[:default].nil?,
        mutable: p[:mutable] || false,
        comptime: p[:comptime] || false
      }},
      return_type: node.return_type || :Any,
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
      if type_schema.is_a?(Hash)
        type_schema[:methods] ||= {}
        type_schema[:methods][node.name] = signature
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
  def visit_ExternStructDecl(node)
    schema = node.fields.transform_keys(&:to_s).transform_values { |f| f[:type] }
    type_params = node.respond_to?(:type_params) ? node.type_params : nil
    schema[:type_params] = type_params if type_params&.any?
    schema[:extern_module] = node.from_module

    if node.close_method && node.from_module
      schema[:kind] = :resource
      # Instance method call: parsed.deinit() — not a module-level function.
      schema[:close_zig] = "{0}.#{node.close_method}()"
    end
    schema[:as_type] = node.as_type if node.as_type

    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  def pre_register_function(node)
    signature = FunctionSignature.new(
      params: node.params.map { |p| {
        name: p[:name],
        type: p[:type],
        required: p[:default].nil?,
        default: p[:default],
        mutable: p[:mutable],
        takes: p[:takes] || false,
        sync: (p[:type].is_a?(Type) && p[:type].any_sync?) ? p[:type].sync : nil
      }},
      return_type: (node.return_type || :Any),
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

  # TODO: Implement return_strategy for lambdas
  # TODO: Implement force heap for USE
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
  def visit_LambdaLit(node)
    # Lambdas are always implicit return unless we add syntax for it later
    return_type = analyze_routine(node, node.body, :Any, true)

    # Build standard signature (same format as user-defined functions)
    # This enables verify_function_signature! to validate lambda calls
    node.full_type = build_lambda_signature(node.params, return_type)
  end

  def visit_FunctionDef(node)
    effects_begin_function(node.name)

    # 1. Setup metadata
    is_implicit_return = node.return_type.nil?
    node.type_params = infer_implicit_type_params(node) if node.respond_to?(:type_params=)
    declared_return = node.return_type || :Any
    lifetime_paths = get_lifetime_paths(node)
    fn_type_params = (node.type_params || []).map(&:to_sym)
    @function_context_stack.push(FunctionContext.new(
      name: node.name, return_type: declared_return,
      lifetime: lifetime_paths, type_params: fn_type_params
    ))

    # 2. Validation & Lifetime
    has_mutable_param = node.params.any? { |p| p[:mutable] }
    if has_mutable_param && !node.name.end_with?("!")
      error!(node, "Style Error: Function '#{node.name}' has MUTABLE parameters. Its name must end in '!'")
    end
    verify_lifetime!(node)

    # Validate generic type params on the function definition
    validate_type_param_list!(node, node.type_params, "function") if fn_type_params.any?

    # Make type params visible during type annotation validation
    node.params.each { |p| validate_type_annotation!(node, p[:type], is_param: true) if p[:type].is_a?(Type) }
    validate_type_annotation!(node, node.return_type) if node.return_type.is_a?(Type)

    # 3. Pre-declaration (so the function can be recursive)
    signature = FunctionSignature.new(
      params: node.params.map { |p| {
        name: p[:name], type: p[:type], required: p[:default].nil?,
        default: p[:default], mutable: p[:mutable], takes: p[:takes],
        sync: (p[:type].is_a?(Type) && p[:type].any_sync?) ? p[:type].sync : nil
      }},
      return_type: declared_return, return_lifetime: lifetime_paths,
      visibility: node.visibility,
      type_params: fn_type_params.any? ? fn_type_params : nil,
      reentrant: node.reentrant == :reentrant
    )
    signature.requires = node.requires
    current_scope.declare(node.name, nil, signature, false, false, nil, :static)

    # Register function node BEFORE body analysis so visit_ReturnNode can
    # set returns_promoted on it and callers in the same pass can read it.
    @fn_nodes[node.name] = node

    # 4. Routine Analysis
    final_return_type = analyze_routine(node, node.body, declared_return, is_implicit_return)

    # 4.5 Reentrancy analysis: scan body after annotation so fn_var_call flags are set.
    called_names, has_fnptr = scan_for_calls(node.body)
    directly_recursive = called_names.include?(node.name)
    # Record in call graph for the later indirect-cycle post-pass.
    @call_graph[node.name]   = called_names - [node.name]
    @fn_has_fnptr[node.name] = has_fnptr

    if directly_recursive
      record_effect(EffectTracker::REENTRANT)
      case node.reentrant
      when :non_reentrant
        # F1 (NOT_LOGICAL) gets a specific compile-time error from
        # `validate_not_logical_recursion!` in PASS 4.1a, so skip the
        # legacy phrasing here.
        # MAX_DEPTH on direct self-recursion is FINE -- the runtime
        # depth counter is exactly the mechanism that bounds it; the
        # legacy "Use @reentrant" message would mislead. The cycle-
        # member case still gets a fixable warning from
        # `validate_max_depth_mutual_cycle!`.
        # Both share `reentrant = :non_reentrant` (the bridge piggybacks
        # on the legacy codegen path), so suppress here for either.
        unless [:reentrant_not_logical, :reentrant_max_depth].include?(node.reentrance_kind)
          error!(node, "Reentrancy Error: '#{node.name}' directly calls itself. " \
                       "Use @reentrant (not @nonReentrant) for directly recursive functions.")
        end
      when nil
        error!(node, "Reentrancy Error: '#{node.name}' calls itself recursively. " \
                     "Add @reentrant to the function signature to allow this.")
      end

      # Tail call validation: if @reentrant:tailCall, verify the self-call is in tail position.
      if node.tail_call
        validate_tail_call!(node)
      end

      # Thunk Phase 4b/4c: :reentrant_thunk handling. The bridge
      # sets node.tail_call = true for tail-recursive :THUNK fns so
      # the line above handles them via the existing TailCall MIR
      # emission. Non-tail :THUNK lands here -- Phase 4c detects the
      # simple-recurrence pattern (factorial-shape); Phase 4d will
      # land the Zig codegen. Until then, the error message reports
      # whether the splitter recognized the shape so users can plan.
      if node.reentrance_kind == :reentrant_thunk && !node.tail_call
        plan = ThunkTransform::RecursiveSplitter.split(node.body, node.name, self)
        if plan
          # Phase 4d: shape recognized -- stamp the plan so MIR
          # lowering can synthesize the trampoline body.
          node.thunk_plan = plan
        else
          error!(node, "EFFECTS REENTRANT:THUNK on '#{node.name}' has non-tail recursion in " \
                        "a shape this phase does not yet recognize. Supported: simple " \
                        "recurrence (zero or more `IF base -> RETURN const;` followed by a final " \
                        "`RETURN expr <op> #{node.name}(args);`). Wider shapes (multi-recursion, " \
                        "arbitrary control flow with recursion) land in later sub-phases. For " \
                        "now, declare ':TAIL_CALL' or use plain 'EFFECTS REENTRANT'.")
        end
      end
    elsif node.tail_call
      error!(node, "@reentrant:tailCall on '#{node.name}' but the function is not recursive. " \
                   "Remove :tailCall - it only applies to self-recursive functions.")
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
    # Seed for compute_can_fail! post-pass: direct failure sources.
    ret_type_obj = signature.respond_to?(:return_type) ? signature.return_type : (signature.is_a?(Hash) ? signature[:return]&.dig(:type) : nil)
    heap_ret     = ret_type_obj.is_a?(Type) && (ret_type_obj.heap? || ret_type_obj.dynamic?)
    @fn_raises_directly[node.name] = node.uses_frame || node.uses_heap || node.uses_alloc || heap_ret ||
      (@fn_has_fnptr[node.name] == true) ||
      (node.reentrant == :non_reentrant) ||
      (node.respond_to?(:pre_clauses) && node.pre_clauses && node.pre_clauses.any?) ||
      scan_for_raises(node.body)

    # Visit CATCH clause bodies with __error and snapshot in scope.
    if node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
      # Resolve each parsed clause to a { kind, error_names } pair the
      # lowering can emit directly. Validates every type against the
      # registry (seeded by PASS 2.9) and rejects kind mismatches.
      node.catch_clauses.each { |c| resolve_catch_clause!(c) }

      # Collect snapshot types from pipeline steps for typed snapshot access
      snap_types = Set.new
      collect_pipe_input_types(node.body, snap_types)
      node.snapshot_types = snap_types

      all_catch_bodies = node.catch_clauses.map { |c| c[:body] }
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

      # CATCH wrappers heap-dupe all string returns (both success and catch paths).
      # Post-#338: a fallible String fn declares `RETURNS !String`; the outer
      # Type isn't string?-true (the error union is), so unwrap the payload
      # before classifying.
      ret_type = node.return_type.is_a?(Type) ? node.return_type : Type.new(node.return_type || :Void)
      bare_ret = if ret_type.respond_to?(:error_union?) && ret_type.error_union? &&
                    ret_type.respond_to?(:payload_type)
                   ret_type.payload_type || ret_type
                 else
                   ret_type
                 end
      if bare_ret.string?
        node.return_provenance = :heap
      end
    end

    @function_context_stack.pop
  end

  # Pre-pass: walk every RAISE and OR EXIT site that provides both a
  # kind and a type, and seed the registry with (kind, type). Lets
  # CATCH Type clauses resolve regardless of source order. OR EXIT
  # counts too because it can introduce new types that only the
  # CATCH for a particular call needs to see.
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
      seed_body.call(stmt.catch_clauses&.map { |c| c[:body] }&.flatten || [])
    end
  end

  # True-Sync-Polymorphism (#325). The set of errors a SYNC POLICY
  # block must handle. Deadlock and LockCycle are deliberately absent
  # -- those are inline-only (the user must handle them at the WITH
  # site, never via a default policy).
  SYNC_POLICY_REQUIRED_ERRORS = %i[LockTimeout MvccConflict AtomicConflict].freeze
  # Errors that may NEVER appear in a SYNC POLICY block.
  SYNC_POLICY_INLINE_ONLY_ERRORS = %i[Deadlock LockCycle].freeze
  # The baked-in default applied when the user writes no SYNC POLICY.
  # Synthesized as a hash matching the parser's lock_error_clause
  # shape so the resolver can use it interchangeably.
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
  def validate_and_resolve_sync_policy!(program_node)
    decls = program_node.statements.select { |s| s.is_a?(AST::SyncPolicyDecl) }

    if decls.size > 1
      error!(decls[1],
        "Only one SYNC POLICY block is allowed per program. " \
        "The first one was declared earlier in this file.")
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
      error!(decl,
        "SYNC POLICY may only be declared in the file containing `FN main`. " \
        "Move the policy to the program's main file, or remove it here.")
    end

    validate_sync_policy_body!(decl)
    program_node.sync_policy = decl.handlers
  end

  # Per-handler-block validation: every selector must name a type the
  # SYNC POLICY is allowed to handle (LockTimeout, MvccConflict,
  # AtomicConflict); Deadlock / LockCycle are explicitly forbidden;
  # the union of named errors must cover the required set exactly.
  def validate_sync_policy_body!(decl)
    seen = []
    (decl.handlers || []).each do |clause|
      (clause[:selectors] || []).each do |sel|
        next unless sel[:form] == :type
        name = sel[:name]
        if SYNC_POLICY_INLINE_ONLY_ERRORS.include?(name)
          error!(sel[:token] || decl,
            "`#{name}` must be handled in-line — SYNC POLICY defaults are not " \
            "allowed for this error. Remove it from the policy and add an " \
            "`ON #{name} ...` handler at the WITH site (use " \
            "`WITH POLYMORPHIC POSSIBLE_#{name == :Deadlock ? "DEADLOCK" : "LOCK_CYCLE"} ...` " \
            "if the static cycle check needs to be opted out).")
        end
        unless SYNC_POLICY_REQUIRED_ERRORS.include?(name)
          error!(sel[:token] || decl,
            "`#{name}` is not a valid SYNC POLICY error. " \
            "SYNC POLICY only handles: #{SYNC_POLICY_REQUIRED_ERRORS.join(', ')}.")
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
        error!(sel[:token] || decl,
          "SYNC POLICY handlers must name a specific error type, not a kind. " \
          "`ON #{sel[:name]} ...` (and the `RETRY(N) THEN` sugar that desugars " \
          "to `ON Transient ...`) is rejected here. Use `ON LockTimeout ...`, " \
          "`ON MvccConflict ...`, or `ON AtomicConflict ...` explicitly.")
      end
    end

    seen_set = seen.to_set
    missing = SYNC_POLICY_REQUIRED_ERRORS.reject { |e| seen_set.include?(e) }
    unless missing.empty?
      error!(decl,
        "SYNC POLICY must handle every required error " \
        "(#{SYNC_POLICY_REQUIRED_ERRORS.join(', ')}). " \
        "Missing: #{missing.join(', ')}.")
    end
  end

  # True-Sync-Polymorphism (#329): project the callee fn's full !T
  # error union down to only the errors this specific call site can
  # surface, given the actual-family set of each REQUIRES'd arg.
  # Returns a Set<Symbol> of error type names (e.g., :MvccConflict).
  #
  # Mechanism: for each parameter constrained by REQUIRES, find the
  # actual arg's family SET at the call site (via family_of_arg_set,
  # which returns the disjunction for polymorphic params and a
  # singleton for concrete bindings; SNAPSHOTTED is expanded to
  # {VERSIONED, ATOMIC}). For each family in the set, look up its
  # storage axes (FAMILY_AXES) and project each axis's error set
  # (AXIS_ERRORS). The union over all REQUIRES'd args is the
  # collapsed error set at this call site.
  #
  # Forwarding: when a polymorphic fn `a` (REQUIRES b: VERSIONED)
  # forwards `b` to a broader `c` (REQUIRES b: SNAPSHOTTED), the
  # inner call's collapsed_errors reflects `a`'s narrower constraint
  # ({:MvccConflict}, NOT the full {:MvccConflict, :AtomicConflict}).
  # Concrete bindings narrow further to a single axis.
  def collapse_errors_for_call(sig, args)
    require_relative 'annotator-helpers/with_match_check' unless defined?(WithMatchCheck)
    collapsed = Set.new
    sig.requires.each do |param_name, _families|
      idx = sig.params.find_index { |p| p[:name].to_s == param_name }
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

  # True-Sync-Polymorphism (#328): policy chain — for a WITH that
  # didn't get a per-WITH `ON <Error> ...` handler, look up the
  # matching handler in the program-level SYNC POLICY and synthesize
  # a clause shape compatible with the existing emit pipeline. The
  # baked-in default is always stamped on `Program#sync_policy`, so
  # this returns a non-nil clause for any of the three policy errors
  # (LockTimeout / MvccConflict / AtomicConflict). Returns nil only
  # for inline-only errors (Deadlock / LockCycle), which by design
  # never have a policy-level handler.
  def synthesize_clause_from_policy(error_name)
    handlers = @program&.sync_policy
    return nil unless handlers
    handlers.find { |h|
      (h[:selectors] || []).any? { |s|
        s[:form] == :type && s[:name] == error_name
      }
    }
  end

  # PASS 3 visitor: SyncPolicyDecl is validated up front in
  # validate_and_resolve_sync_policy! (PASS 2.95), so the PASS 3
  # walk is a no-op. This visitor exists so the AST walker doesn't
  # silently skip the node. The action bodies for `:block`-action
  # handlers (`ON X -> { stmts }`) ARE visited here so types in
  # those bodies get annotated.
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
  def resolve_catch_clause!(clause)
    kinds = []
    types = []
    (clause[:items] || []).each do |item|
      if item[:form] == :kind
        kind_sym = item[:name].to_sym
        unless AST.error_kind?(kind_sym)
          emit_registry_mismatch!(
            item[:token], item[:name], AST::ERROR_KINDS,
            "Unknown error kind '#{item[:name]}'. Expected one of: #{AST::ERROR_KINDS.join(', ')}",
            "closest known kind"
          )
        end
        kinds << kind_sym if AST.error_kind?(kind_sym)
      else
        type_sym = item[:name].to_sym
        unless AST.error_type?(type_sym)
          emit_registry_mismatch!(
            item[:token], item[:name], AST::ERROR_TYPES.keys,
            "CATCH #{item[:name]}: error type '#{item[:name]}' is not registered. A type " \
            "must be registered via RAISE/OR EXIT before it can be CATCHed.",
            "closest registered type"
          )
        end
        types << item[:name] if AST.error_type?(type_sym)
      end
    end
    clause[:kinds] = kinds.uniq
    clause[:types] = types.uniq

    filter_types    = []
    filter_messages = []
    (clause[:filters] || []).each do |f|
      case f[:form]
      when :type
        type_sym = f[:value].to_sym
        unless AST.error_type?(type_sym)
          error!(f[:token],
                 "CATCH ... WITH(#{f[:value]}): error type '#{f[:value]}' is not registered.")
        end
        filter_types << f[:value]
      when :message
        # value is the parsed STRING expression. Visit so the string
        # literal gets its Type stamped for downstream lowering.
        visit(f[:value])
        filter_messages << f[:value]
      end
    end
    clause[:filter_types]    = filter_types.uniq
    clause[:filter_messages] = filter_messages
  end

  # Collect input types from pipeline |> steps that can fail.
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
  def visit_stmts(stmts)
    return unless stmts.is_a?(Array)
    saved = @stmts_after
    stmts.each_with_index do |stmt, i|
      @stmts_after = stmts[(i + 1)..]
      visit(stmt)
    end
    @stmts_after = saved
  end

  def visit_StructDef(node)
    # Validate generic type parameters (duplicate / builtin-shadow)
    validate_type_param_list!(node, node.type_params, "struct") if node.type_params&.any?

    # Register the Type Name with its field schema.
    schema = node.fields.transform_values { |f| f[:type] }

    # Store field defaults so empty struct literals (Foo{}) can be validated.
    field_defaults = node.fields.each_with_object({}) { |(k, f), h| h[k] = f[:default] if f[:default] }
    schema[:field_defaults] = field_defaults unless field_defaults.empty?

    # Track which fields are BORROWED (references, not owned).
    borrowed_fields = node.fields.select { |_, f| f[:borrowed] }.keys
    schema[:borrowed_fields] = borrowed_fields.to_set if borrowed_fields.any?

    # For generic structs, record the type parameter names so field-type
    # lookups don't reject them as unknown types.
    schema[:type_params] = node.type_params.map(&:to_sym) if node.type_params&.any?

    schema[:visibility] = node.visibility || :package
    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  def visit_EnumDef(node)
    schema = { kind: :enum, variants: node.variants.to_set }
    schema[:visibility] = node.visibility || :package
    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  def visit_UnionDef(node)
    # Validate generic type parameters (duplicate / builtin-shadow)
    validate_type_param_list!(node, node.type_params, "union") if node.type_params&.any?

    # Inline struct variants are not supported in generic unions.
    if node.type_params&.any? && node.variants.any? { |_, v| v.is_a?(Hash) && v[:kind] == :inline_struct }
      error!(node, :UNION_INLINE_IN_GENERIC)
    end

    # Register a synthetic struct schema for each inline struct variant so
    # that MATCH AS bindings (e.g. `Shape.Circle AS c`) can field-access the payload.
    node.variants.each do |var_name, var_data|
      next unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
      synthetic_name = :"#{node.name}_#{var_name}"
      current_scope.declare_type(synthetic_name, var_data[:fields])

      # Pre-compute deinit entries for transpiler: which fields need cleanup.
      indirect = var_data[:indirect_fields] || Set.new
      deinit_entries = []
      var_data[:fields].each do |fname, ftype|
        ft = ftype.is_a?(Type) ? ftype : Type.new(ftype || :Any)
        if indirect.include?(fname)
          deinit_entries << { field: fname, kind: :indirect, zig_type: ft.zig_type(is_field: true) }
        elsif ft.array? && !ft.string?
          deinit_entries << { field: fname, kind: :array, elem_zig_type: Type.new(ft.element_type).zig_type }
        end
      end
      var_data[:deinit_entries] = deinit_entries if deinit_entries.any?
    end

    schema = { kind: :union, variants: node.variants }
    schema[:type_params] = node.type_params.map(&:to_sym) if node.type_params&.any?
    schema[:visibility] = node.visibility || :package
    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  # Called after Pass 2 (all function signatures registered).
  # Verifies that every method requirement declared inside the UNION body
  # is satisfied by a concrete top-level function with a matching signature.
  def visit_UnionVariantLit(node)
    schema = lookup_type_schema(node.union_name.to_sym)
    var_data = validate_union_schema!(node, schema)
    validate_union_fields!(node, var_data[:fields])
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

  def visit_BlockExpr(node)
    with_new_scope(current_scope) do
      node.body.each { |stmt| visit(stmt) }
      visit(node.result)
      node.full_type = node.result.full_type
      node.storage   = node.result.storage
    end
  end

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
  def ifbind_source_root(expr)
    case expr
    when AST::Identifier  then expr
    when AST::GetField    then ifbind_source_root(expr.target)
    when AST::GetIndex    then ifbind_source_root(expr.target)
    else                       nil
    end
  end

  def visit_IfBind(node)
    # Visit and validate each binding expression.
    node.bindings.each do |b|
      visit(b[:expr])
      ti = b[:expr].type_info
      unless ti&.optional?
        error!(b[:expr], "IF ... AS binding requires an optional type, got '#{b[:expr].resolved_type}'")
      end
      # Annotate each binding with the unwrapped type for use in lowering.
      unwrapped = ti.wrapped_type
      # RESOLVE returns ?T@multiowned/shared where the caller owns the strong ref.
      # Propagate ownership so field access auto-derefs through .ctrl.data and
      # the lowering knows to inject rcRelease cleanup.
      if b[:expr].is_a?(AST::ResolveNode) && (ti.multiowned? || ti.shared?)
        unwrapped.ownership = ti.ownership
        unwrapped.link_source = ti.link_source
      end
      b[:unwrapped_type] = unwrapped
    end

    branch_logic = [
      proc {
        # Declare each binding in the then-scope with the unwrapped type.
        node.bindings.each do |b|
          unwrapped = b[:unwrapped_type]
          sym = unwrapped.is_a?(Type) ? unwrapped.resolved : unwrapped
          current_scope.declare(b[:name], nil, unwrapped, false, false, nil, :stack)
          entry = current_scope.locals[b[:name]]
          b[:symbol] = entry
          # Propagate non_escaping when the source is borrow-derived from a
          # non_escaping binding (a WITH alias or another transitive borrow
          # of one). IF-AS on `p[i]` / `p.field` where `p` is the alias
          # makes the new binding a borrow into locked data; it must not
          # escape the enclosing WITH scope either.
          src_root = ifbind_source_root(b[:expr])
          if src_root && src_root.respond_to?(:symbol) && src_root.symbol&.non_escaping
            entry.non_escaping = true
          end
          classify_ownership!(entry)
          og_declare(b[:name].to_s, nil, unwrapped)
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
  def annotate_struct_pattern!(match_node, pat)
    expr_type = match_node.expr.resolved_type
    primitives = [:Float64, :Bool, :Byte, :Int64, :Float64, :String, :NIL, :BOOLEAN, :Any, :Void]

    if primitives.include?(expr_type)
      error!(match_node, "MATCH struct pattern requires a struct type, got #{expr_type}")
    end

    schema = lookup_type_schema(expr_type)

    pat.fields.each do |f|
      next if f[:value] == :wildcard

      if schema
        unless schema.key?(f[:name])
          error!(match_node, "MATCH struct pattern: field '#{f[:name]}' does not exist on type #{expr_type}")
        end
      end

      if f[:value] == :bind
        # Destructuring bind: declare a local variable with the field's type.
        if schema && schema.key?(f[:name])
          field_def = schema[f[:name]]
          field_type = field_def.is_a?(Hash) ? field_def[:type] : field_def
          field_type = field_type.is_a?(Type) ? field_type : Type.new(field_type)
          current_scope.declare(f[:name], nil, field_type, false, false, nil, :stack)
          og_declare(f[:name], nil, field_type)
        end
      else
        visit(f[:value])

        if schema
          field_def = schema[f[:name]]
          field_type = field_def.is_a?(Type) ? field_def.resolved : (field_def.is_a?(Hash) ? field_def[:type]&.resolved : field_def&.resolved)
          val_type   = f[:value].resolved_type
          is_numeric_promo = (val_type == :Int64 && (field_type == :Float64 || field_type == :Float64))
          unless val_type == field_type || val_type == :Any || field_type == :Any || is_numeric_promo
            error!(match_node, "MATCH struct pattern: field '#{f[:name]}' has type #{field_type}, but pattern value has type #{val_type}")
          end
        end
      end
    end
  end

  def visit_PassStmt(node)
    node.full_type = :Void
  end

  def visit_MatchStatement(node)
    visit(node.expr)

    # Determine whether the subject is an enum or union for exhaustiveness / payload capture
    expr_t    = Type.new(node.expr.resolved_type || :Any)
    node.string_match = true if expr_t.string?
    type_name = expr_t.generic_instance? ? expr_t.generic_base : expr_t.resolved
    schema    = lookup_type_schema(type_name)
    is_enum   = schema.is_a?(Hash) && schema[:kind] == :enum
    is_union  = schema.is_a?(Hash) && schema[:kind] == :union

    # Build type-param substitution for generic union payload capture
    # e.g. Option<Number> → { T: :Float64 }
    union_subst = {}
    if is_union && expr_t.generic_instance? && schema[:type_params]&.any?
      schema[:type_params].zip(expr_t.generic_args).each { |p, a| union_subst[p] = a.resolved }
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
    auto_takes = false
    if !node.takes && is_union && node.expr.is_a?(AST::Identifier)
      # Check if any AS case extracts a non-Copy payload that would share
      # heap ownership with the source. Strings are Copy in CLEAR, so
      # extracting a string variant doesn't require consuming the source.
      has_non_copy_as = node.cases&.any? { |c|
        next false unless c[:binding]
        vn = case c[:value]
             when AST::GetField then c[:value].field
             when AST::MethodCall then c[:value].name
             end
        next false unless vn
        vt = (schema[:variants] || {})[vn]
        next false unless vt
        # Inline struct with heap fields: non-Copy (strings/collections/indirect)
        if vt.is_a?(Hash) && (vt[:kind] == :inline_struct || vt[:kind] == :indirect_payload)
          Type.variant_has_heap?(vt)
        else
          # Simple payload: only non-Copy if it's a collection/array (not string)
          t = vt.is_a?(Type) ? vt : (Type.new(vt) rescue nil)
          t && !t.string? && (t.collection? || t.map? || (t.array? && !t.fixed?))
        end
      }
      if has_non_copy_as
        source_name = node.expr.name
        # Check no case lacks a binding (all cases extract payloads).
        all_cases_bind = node.cases&.all? { |c| c[:binding] }
        # Check DEFAULT doesn't reference the source value.
        # walk_body only visits statement-level nodes; we need to check
        # expression sub-trees too (e.g. RETURN input; has input inside).
        default_refs_source = false
        if node.default_case
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
        if c[:kind] == :when
          visit(c[:value])
          unless c[:value].resolved_type == :Bool
            error!(node, "WHEN condition must be Bool, got #{c[:value].resolved_type}")
          end
        elsif c[:kind] == :struct_pattern
          annotate_struct_pattern!(node, c[:value])
        else
          # Suppress inline-struct "needs braces" error: variant names in MATCH cases are
          # patterns (tag identifiers), not constructors — they don't need field values.
          @match_pattern_context = true
          visit(c[:value])
          @match_pattern_context = false
          expr_t2 = Type.new(node.expr.resolved_type || :Any)
          case_t2 = Type.new(c[:value].resolved_type || :Any)
          # Allow union base type (e.g. :Option) to match a generic instance (e.g. :"Option<Number>")
          base_match = expr_t2.generic_instance? && expr_t2.generic_base == c[:value].resolved_type
          # Allow Byte[N] string literals (e.g. "hello") to match a String-typed subject
          string_match = expr_t2.string? && case_t2.string?
          unless c[:value].resolved_type == node.expr.resolved_type ||
                 node.expr.resolved_type == :Any ||
                 c[:value].resolved_type == :Any ||
                 base_match ||
                 string_match
            error!(node, "MATCH case type #{c[:value].resolved_type} does not match expression type #{node.expr.resolved_type}")
          end

          # Payload capture: `Shape.Circle AS r ->`
          if c[:binding]
            if is_enum
              error!(node, "Cannot capture payload from enum variant: enums have no payload. Remove 'AS #{c[:binding]}'.")
            elsif is_union
              variant_name = case c[:value]
                             when AST::GetField   then c[:value].field
                             when AST::MethodCall then c[:value].name
                             end
              if variant_name
                raw_payload = schema[:variants][variant_name]
                if raw_payload.nil?
                  error!(node, "Cannot bind 'AS #{c[:binding]}': '#{variant_name}' is a unit variant with no payload.")
                elsif raw_payload.is_a?(Hash) && raw_payload[:kind] == :inline_struct
                  synthetic_type = :"#{type_name}_#{variant_name}"
                  current_scope.declare(c[:binding], nil, Type.new(synthetic_type), false, false, nil, :stack)
                  og_declare(c[:binding], nil, Type.new(synthetic_type))
                  classify_ownership!(current_scope.locals[c[:binding]])
                elsif raw_payload.is_a?(Hash) && raw_payload[:kind] == :indirect_payload
                  # @indirect payload: bind to the dereferenced inner type (not the *T pointer).
                  inner_type = raw_payload[:type].is_a?(Type) ? raw_payload[:type] : Type.new(raw_payload[:type])
                  inner_type = union_subst.any? ? apply_type_subst(inner_type, union_subst) : inner_type
                  current_scope.declare(c[:binding], nil, inner_type, false, false, nil, :stack)
                  og_declare(c[:binding], nil, inner_type)
                  classify_ownership!(current_scope.locals[c[:binding]])
                  c[:indirect_payload_as] = true  # transpiler must emit subject.Variant.* (deref *T)
                else
                  payload_type = union_subst.any? ? apply_type_subst(raw_payload, union_subst) : Type.new(raw_payload)
                  current_scope.declare(c[:binding], nil, payload_type, false, false, nil, :stack)
                  og_declare(c[:binding], nil, payload_type)
                  classify_ownership!(current_scope.locals[c[:binding]])
                end
                # MATCH AS: borrow view into the source union's payload.
                # MATCH TAKES: owned extraction - source is consumed.
                unless node.takes
                  @og[c[:binding]]&.kind = :borrowed
                end
              end
            end
          end

          # Union variant destructuring: `Result.Ok{ value, count } ->`
          # Declares each named field as a local binding with the correct type.
          if c[:destructure] && is_union
            variant_name = case c[:value]
                           when AST::GetField   then c[:value].field
                           when AST::MethodCall then c[:value].name
                           end
            if variant_name
              raw_payload = schema[:variants][variant_name]
              # Resolve the payload's field schema (inline struct or named type)
              payload_schema = if raw_payload.is_a?(Hash) && raw_payload[:kind] == :inline_struct
                raw_payload[:fields]
              else
                payload_type_sym = raw_payload.is_a?(Type) ? raw_payload.resolved : raw_payload
                payload_type_sym = union_subst[payload_type_sym] if union_subst[payload_type_sym]
                lookup_type_schema(payload_type_sym)
              end

              if payload_schema.is_a?(Hash) && !payload_schema[:kind]
                c[:destructure].fields.each do |f|
                  next unless f[:value] == :bind
                  unless payload_schema.key?(f[:name])
                    error!(node, "MATCH destructure: field '#{f[:name]}' does not exist on variant #{variant_name}")
                  end
                  field_def = payload_schema[f[:name]]
                  field_type = field_def.is_a?(Hash) ? field_def[:type] : field_def
                  field_type = field_type.is_a?(Type) ? field_type : Type.new(field_type)
                  current_scope.declare(f[:name], nil, field_type, false, false, nil, :stack)
                  og_declare(f[:name], nil, field_type)
                end
              end
            end
          end
        end
        with_conditional_context { visit_stmts(c[:body]) }
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
      node.default_drops = all_drops.pop
    end
    node.case_drops = all_drops

    # Exhaustiveness check — enforced for plain MATCH (the default).
    # PARTIAL MATCH bypasses these checks and allows DEFAULT, WHEN, and
    # non-enum/union subjects.
    if node.exhaustive
      # MATCH requires an enum or union subject. Non-discriminated types
      # (Int64, String, ...) can never be statically exhaustive; the user
      # must opt in to PARTIAL MATCH.
      unless is_enum || is_union
        type_label = expr_t.resolved
        error!(node,
          "MATCH requires an enum or union type, got '#{type_label}'. " \
          "Use `PARTIAL MATCH` to match on non-discriminated types " \
          "(WHEN guards, ranges, etc. require PARTIAL).")
      end

      # MATCH forbids DEFAULT — the whole point of an exhaustive MATCH is
      # that every variant is explicitly named. If you want a fallback,
      # write `PARTIAL MATCH`.
      if node.default_case
        error!(node,
          "MATCH cannot have a DEFAULT branch — every variant must be " \
          "handled explicitly. If you want a catch-all, change to " \
          "`PARTIAL MATCH` (which permits DEFAULT and WHEN guards).")
      end

      # MATCH forbids WHEN guards — they're runtime conditions that break
      # static exhaustiveness. Use `PARTIAL MATCH` for guard-style cases.
      if node.cases.any? { |c| c[:kind] == :when }
        error!(node,
          "MATCH cannot contain WHEN guards — every variant must be " \
          "handled by an exact case. Use `PARTIAL MATCH` if you need " \
          "WHEN guards.")
      end

      # Every variant must appear exactly once.
      covered = node.cases.flat_map do |c|
        variant_name = case c[:value]
                       when AST::GetField   then c[:value].field
                       when AST::MethodCall then c[:value].name
                       else nil
                       end
        variant_name ? [variant_name] : []
      end.to_set

      all_variants = is_enum ? schema[:variants] : schema[:variants].keys.to_set
      missing = all_variants - covered
      unless missing.empty?
        type_label2 = is_enum ? "enum" : "union"
        error!(node,
          "MATCH on #{type_label2} '#{type_name}' is non-exhaustive: " \
          "missing variants: #{missing.sort.join(', ')}. " \
          "Either add cases for the missing variants, or change to " \
          "`PARTIAL MATCH` to allow non-exhaustive matching.")
      end
    end

    # Store case result types so use sites can promote to expression mode.
    node.case_result_types = node.cases.map { |c| expr_result_type(c[:body]) }
    node.default_result_type = expr_result_type(node.default_case)

    node.full_type = :Void
  end

  def visit_ForRange(node)
    # 1. Type-check range bounds
    visit(node.start_expr)
    visit(node.end_expr)
    start_type = node.start_expr.resolved_type
    end_type   = node.end_expr.resolved_type
    error!(node, "FOR range start must be Int64, got #{start_type}") unless start_type == :Int64
    error!(node, "FOR range end must be Int64, got #{end_type}") unless end_type == :Int64

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
      error!(node, "FOR ... IN requires an array, list, or map, got #{coll_type}")
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

  def visit_WhileLoop(node)
    # 1. Analyze Condition
    visit(node.condition)

    if node.condition.resolved_type != :Bool
      error!(node, "Condition must be a Boolean, got #{node.condition.resolved_type}")
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
              error!(node, "Use of moved value '#{name}' in loop. The variable is moved in the first iteration and not available for the next.")
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

  def visit_WhileBindLoop(node)
    visit(node.condition)
    ti = node.condition.type_info
    unless ti&.optional?
      error!(node.condition, "WHILE ... AS binding requires an optional type, got '#{node.condition.resolved_type}'")
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
        error!(node, "WHILE ... AS binding: '#{cond.name}' is called on immutable '#{recv.name}' -- the condition cannot advance and may loop forever. Declare '#{recv.name}' as MUTABLE or use a regular WHILE loop.")
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
              error!(node, "Use of moved value '#{name}' in loop.")
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
  def visit_BreakNode(node)
    if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
      error!(node, "BREAK must be used inside a loop")
    end
    node.full_type = :Void
  end

  def visit_ContinueNode(node)
    if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
      error!(node, "CONTINUE must be used inside a loop")
    end
    node.full_type = :Void
  end

  def visit_Assert(node)
    visit(node.condition)
    if node.condition.resolved_type != :Bool
       error!(node, "Assert condition must be Boolean")
    end
    # Optional: check message type if it exists
    node.full_type = :Void
  end

  def visit_TestBlock(node)
    with_new_scope do
      node.setup.each { |s| visit(s) }
      node.whens.each { |w| visit_WhenBlock(w) }
    end
    node.full_type = :Void
  end

  def visit_WhenBlock(node)
    node.setup.each { |s| visit(s) }

    # Strict test mode: verify all IO functions are stubbed in this WHEN block.
    if @strict_test
      stubbed_fns = node.setup
        .select { |s| s.is_a?(AST::StubDecl) }
        .map { |s| s.function_name }
        .to_set
      node.tests.each { |t| validate_strict_io!(t, stubbed_fns) }
    end

    node.tests.each do |t|
      with_new_scope(current_scope) do
        visit_TestThat(t)
      end
    end
    node.benchmarks.each { |b| visit(b) }
    node.full_type = :Void
  end

  def visit_TestThat(node)
    visit_stmts(node.body)
    node.full_type = :Void
  end

  def visit_AssertRaises(node)
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_BenchmarkStmt(node)
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_SmashStmt(node)
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_ProfileStmt(node)
    visit(node.expression)
    node.full_type = :Void
  end

  def visit_StubDecl(node)
    # Visit the value for type checking if it's an expression.
    visit(node.value) if node.value.respond_to?(:full_type)
    # CAPTURES stubs declare a variable in the current scope.
    if node.kind == :captures
      cap_name = node.value  # the variable name string
      # Declare as Int64 counter (tracks number of calls captured)
      current_scope.declare(cap_name, node, :Int64, true, false, nil, :stack)
      og_declare(cap_name, node, :Int64)
    end
    node.full_type = :Void
  end

  def visit_DieNode(node)
     # Usually takes an integer status code
     visit(node.status) if node.status
     node.full_type = :NoReturn # Special type indicating execution stops
  end

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
  def resolve_error_registration!(node, kind_sym, type_name_str, site_tok)
    return if type_name_str.nil?
    type_sym = type_name_str.to_sym

    if kind_sym.nil?
      # Type-only form — require prior registration.
      unless AST.error_type?(type_sym)
        error!(site_tok || node,
               "Error type '#{type_name_str}' is not registered. The first RAISE / OR EXIT site " \
               "that names a new type must provide a kind: use 'RAISE Kind, #{type_name_str}, \"msg\"' " \
               "or similar.")
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
      error!(site_tok || node,
             "'#{type_name_str}' is reserved by the stdlib as kind '#{conflict[:existing_kind]}'. " \
             "Pick a different type name.")
    else
      error!(site_tok || node,
             "'#{type_name_str}' is already mapped to kind '#{conflict[:existing_kind]}'#{first_loc}. " \
             "Either use the same kind here, or pick a different type name.")
    end
  end

  # ==========================================
  # VARIABLES & DEPENDENCIES
  # ==========================================

  def visit_ReturnNode(node)
    # Handle optional return node for Void functions.
    expected = current_fn_ctx&.return_type
    if node.value.nil?
      # If the function expects a value but we return nothing -> ERROR.
      # `!Void` (error union over Void) accepts a plain `RETURN;` because
      # the success arm is Void; the wrap is implicit at lowering time.
      expected_void_compatible = expected.nil? ||
                                 expected == :Void || expected == :Any ||
                                 (expected.respond_to?(:error_union?) && expected.error_union? &&
                                  expected.respond_to?(:payload_type) &&
                                  (expected.payload_type == :Void || expected.payload_type.nil?))
      if expected && !expected_void_compatible
        error!(node, "Function expects return type #{expected}, got Void")
      end

      node.full_type = :Void
      @branch_terminated = true
      return # Stop here, nothing else to analyze
    end

    visit(node.value)

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
        error!(node, "Cannot RETURN '#{val.name}' from inside a WITH block. " \
                     "WITH aliases are borrows of locked data and cannot escape their scope.")
      elsif val.is_a?(AST::GetField) && val.target.respond_to?(:symbol) && val.target.symbol&.non_escaping
        error!(node, "Cannot RETURN a field of a WITH-scoped binding. " \
                     "Field access borrows from the locked data; the borrow cannot escape the WITH scope.")
      elsif val.is_a?(AST::GetIndex) && val.target.respond_to?(:symbol) && val.target.symbol&.non_escaping
        error!(node, "Cannot RETURN an indexed access of a WITH-scoped binding. " \
                     "Index access borrows from the locked data; the borrow cannot escape the WITH scope.")
      end
    end
    promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
    promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)

    # 1. Lifetime Tracking
    verify_return(node.value)
    verify_tied_return!(node)

    actual = node.value.resolved_type
    actual_full = return_value_type(node.value)
    expected = current_fn_ctx.return_type

    # 2. Move marking: returning a non-Copy value moves it out of the function.
    # Set was_moved so the transpiler emits _moved = true before return.
    if node.value.is_a?(AST::Identifier)
      vti = node.value.type_info
      if vti && !vti.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
        node.value.was_moved = true
      end
      # Atomics M2.6: a `RETURN <ident>` where the value is a future
      # (~T) consumes the promise -- the caller now owns it. Mark the
      # binding as moved in the OG so the existing finalize_scope
      # "promise must be consumed" check (annotator.rb:4765) sees the
      # consumption. Without this, ANY function that returns a `~T`
      # binding errors at scope-end before the return-lifetime check
      # gets a chance to run. Mirrors NEXT's `og_set_moved` (line ~4388).
      vt = vti.is_a?(Type) ? vti : (vti ? Type.new(vti) : nil)
      if vt&.future?
        og_set_moved(node.value.name, at_token: node.value.token, action: :return)
      end
    end

    # RETURN COPY expr or RETURN Struct{ field: COPY ... }: the COPY heap-dupes,
    # so the caller receives heap-allocated data.
    # But COPY of an implicitly-copyable value (e.g. Id<T>) is value-like and
    # must not force heap return provenance.
    if node.value.is_a?(AST::CopyNode)
      fn_node = @fn_nodes[current_fn_ctx&.name]
      copy_ti = node.value.type_info
      resolver = ->(name) { lookup_type_schema(name) rescue nil }
      unless copy_ti&.implicitly_copyable?(resolver)
        if fn_node
          fn_node.return_provenance = :heap
        end
      end
    elsif node.value.is_a?(AST::StructLit)
      # ensure_owned_value! only wraps @list/rodata in CopyNode, never value types.
      # No implicitly_copyable? gate needed here.
      has_copy_field = node.value.fields.any? { |_, v| v.is_a?(AST::CopyNode) }
      if has_copy_field
        fn_node = @fn_nodes[current_fn_ctx&.name]
        if fn_node
          fn_node.return_provenance = :heap
        end
      end
    end

    # Promote non-identifier literals to heap when the expected return type requires it.
    unless node.value.is_a?(AST::Identifier)
      expected_type = Type.new(expected) if expected
      if expected_type && (expected_type.heap? || expected_type.dynamic?) &&
         node.value.respond_to?(:storage=) &&
         node.value.type_info&.requires_move?
        node.value.storage = :heap
      end
    end

    # Gradual-typing tolerance: if either the expected (declared)
    # return or the actual (computed) return is an unresolved Auto,
    # skip the strict-equality check. The unifier (Pass C) resolves
    # both ends after the body walk; mismatch surfaces when the
    # resolved decl gets re-validated downstream.
    actual_is_auto = actual_full.respond_to?(:auto?) && actual_full.auto?
    expected_obj   = expected.is_a?(Type) ? expected : (expected ? Type.new(expected) : nil)
    expected_is_auto = expected_obj.respond_to?(:auto?) && expected_obj.auto?

    if !actual_is_auto && !expected_is_auto && expected && expected != :Void && expected != :Any && !return_type_compatible?(actual_full, expected)
      error!(node, :RETURN_MISMATCH, type_display(expected), type_display(actual_full))
    elsif !actual_is_auto && !expected_is_auto && expected && expected != :Void && expected != :Any && actual != expected
      node.value.coerced_type = expected  # Don't coerce EXPLICIT returns
      check_prefixed_int_range!(node.value, expected)
    end

    node.full_type = actual

    if current_fn_ctx
      current_fn_ctx.returns << {storage: node.value.storage, type: actual, metatype: node.value.metatype}
    end

    @branch_terminated = true
  end

  def return_value_type(value)
    ti = value.respond_to?(:type_info) ? value.type_info : nil
    return ti if ti.is_a?(Type)
    Type.new(value.resolved_type || :Any)
  end

  def return_type_compatible?(actual_type, expected_type)
    expected_t = expected_type.is_a?(Type) ? expected_type : Type.new(expected_type)
    actual_t = actual_type.is_a?(Type) ? actual_type : Type.new(actual_type)

    return true if expected_t.any? || actual_t.any?
    return expected_t.accepts?(actual_t) if expected_t.fn_type?
    return false unless same_return_capabilities?(expected_t, actual_t)

    is_safe_autocast?(actual_t, expected_t)
  end

  def same_return_capabilities?(expected_t, actual_t)
    name = expected_t.resolved.to_s
    if name.match?(/\A[A-Z]\z/) && !lookup_type_schema(name.to_sym) &&
       expected_t.polymorphic_shared? && actual_t.shared? &&
       expected_t.sync.nil? && expected_t.resolved == actual_t.resolved
      return true
    end
    expected_t.ownership == actual_t.ownership &&
      expected_t.sync == actual_t.sync &&
      expected_t.layout == actual_t.layout &&
      expected_t.elem_ownership == actual_t.elem_ownership &&
      expected_t.elem_sync == actual_t.elem_sync
  end

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

  def infer_implicit_type_params(fn_node)
    explicit = (fn_node.type_params || []).map(&:to_s)
    return explicit unless explicit.empty?
    inferred = []
    ([fn_node.return_type] + (fn_node.params || []).map { |p| p[:type] }).each do |type|
      collect_implicit_type_params(type, inferred, explicit)
    end
    (explicit + inferred).uniq
  end

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

  def visit_StaticCall(node)
    node.args.each { |arg| visit(arg) }

    type_name = node.type_name.name.to_sym
    schema    = lookup_type_schema(type_name)

    unless schema
      error!(node, :STATIC_UNKNOWN_TYPE, type_name)
    end

    unless schema[:kind] == :resource
      error!(node, :STATIC_NOT_RESOURCE, type_name)
    end

    static_methods = schema[:static_methods] || {}
    method_def     = static_methods[node.method_name]

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
        error!(node, :STATIC_UNKNOWN_METHOD, node.method_name, type_name, available)
      end
    end

    expected_args = method_def[:args]
    if node.args.length != expected_args.length
      error!(node, :STATIC_ARITY, type_name, node.method_name, expected_args.length, node.args.length)
    end

    node.args.zip(expected_args).each_with_index do |(arg, expected), i|
      actual = arg.resolved_type
      unless expected == :Any || actual == :Any || is_safe_autocast?(actual, expected)
        error!(node, :STATIC_ARG_TYPE, i + 1, type_name, node.method_name, expected, actual)
      end
    end

    node.zig_pattern = method_def[:zig]
    node.full_type   = method_def[:return]
    node.matched_stdlib_def = method_def
    node.stdlib_allocates = true if method_def[:allocates]
    node.mutates_receiver = true if method_def[:mutates_receiver]
    node.can_fail = true if method_def[:can_fail]
    node.error_kind = method_def[:error_kind] if method_def[:error_kind]
    node.error_type = method_def[:error_type] if method_def[:error_type]
    current_fn_ctx.alloc_count += 1 if current_fn_ctx && (method_def[:allocates] || method_def[:can_fail])

    if method_def[:mutates_receiver] && node.is_a?(AST::MethodCall)
      root = chain_root_name(node.object)
      mark_var_mutated(root) if root
    end
  end

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

    # Handle "native_call" special case
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

    # Atomics M1.6.5: stamp per-arg family on the FuncCall so the
    # transitive-effect propagation can resolve callee ?-form effects
    # (CONTENTION_MAYBE / BLOCKING_MAYBE) to concrete or null based on
    # what the caller actually passes. family_of_arg_set returns a Set of
    # families: size 1 = concrete; size > 1 = polymorphic param (REQUIRES
    # disjunction); empty Set = no sync attribute on the arg.
    if node.args && !node.args.empty? && node.name.is_a?(String)
      require_relative 'annotator-helpers/with_match_check' unless defined?(WithMatchCheck)
      arg_family_sets = node.args.map { |a| WithMatchCheck.family_of_arg_set(a) }
      node.arg_families = arg_family_sets
      record_call_arg_families(node.name, arg_family_sets) if current_fn_ctx&.name

      # True-Sync-Polymorphism (#329): collapse the callee's !T error
      # union to only the errors the actually-passed bindings can
      # surface. Per design: if `tick` has REQUIRES x: SNAPSHOTTED
      # (admits {MvccConflict, AtomicConflict}) and the caller passes
      # `@versioned`, this call site sees only {:MvccConflict}.
      sig = @scope_stack.first.locals[node.name]&.type if node.name.is_a?(String)
      if sig.is_a?(FunctionSignature) && sig.requires && !sig.requires.empty?
        node.collapsed_errors = collapse_errors_for_call(sig, node.args)
      end

      # True-Sync-Polymorphism Gate 3 plain-T auto-borrow stamping
      # lives in WithMatchCheck.check_call_sites! (runs after
      # universal-poly REQUIRES is finalized) so we don't need to
      # duplicate it here.
    end

    # Phase 2: when this call happens inside a held WITH scope and targets
    # a user-defined function, record a held->callee site so the post-pass
    # can add (held, T) edges for every T the callee transitively acquires.
    # Uses the Array-of-Hash @held_lock_types shape so opted_out flows
    # through to synthesized edges.
    if @held_lock_types && !@held_lock_types.empty? && @fn_nodes.key?(node.name)
      fn_name = current_fn_ctx&.name || "<top>"
      record_held_call!(fn_name, node.name, @held_lock_types, node.token)
    end
  end

  def visit_MethodCall(node)
    visit(node.object)
    node.args.each { |arg| visit(arg) }

    # Collection method dispatch (Pool/HashMap) via declarative registry.
    if resolve_collection_method(node)
      record_predicate_call_site!(node)
      return
    end

    # EXTERN method dispatch: check if the object's type has EXTERN methods registered.
    obj_type = node.object.type_info
    if obj_type
      resolved = obj_type.is_a?(Type) ? obj_type.resolved : obj_type.to_s.to_sym
      # Check for generic instance: Parsed<MyDoc> → base type Parsed
      base = obj_type.is_a?(Type) && obj_type.generic_instance? ? obj_type.generic_base : resolved
      type_schema = lookup_type_schema(base)
      if type_schema.is_a?(Hash) && type_schema[:methods]&.key?(node.name)
        method_sig = type_schema[:methods][node.name]
        node.extern_call = true
        node.extern_effects = method_sig[:extern_effects] if method_sig[:extern_effects]
        node.instance_variable_set(:@extern_method, true)
        node.full_type = method_sig.respond_to?(:return_type) ? (method_sig.return_type || :Void) : (method_sig[:return]&.dig(:type) || :Void)
        record_effect(EffectTracker::EXTERN)
        # Track allocator usage for EFFECTS :alloc methods.
        alloc_kind = method_sig[:extern_effects]&.dig(:alloc)
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
  def visit_IntrinsicFunc(node, args)
    definitions = STD_LIB[node.name]
    definitions = [definitions] if definitions.is_a?(Hash)

    # 1. Find matching overload (needed for polymorphic intrinsics like 'length')
    matched_def = find_matching_intrinsic(definitions, args)

    unless matched_def
      sigs = definitions.map { |d| format_intrinsic_args(d[:args]) }.join(" or ")
      arg_types = args.map { |a| a.resolved_type }.join(", ")
      error!(node, "No overload for '#{node.name}' matches arguments (#{arg_types}).\nCandidates: #{sigs}")
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

    # 3. Resolve return type (may be dynamic via method call).
    # Dynamic resolver methods are named `infer_*` to avoid collisions with
    # Ruby Kernel conversion methods (Integer, String, Array, etc.).
    ret = matched_def[:return]
    if ret.is_a?(Hash) && ret[:type]
      # Structured return: { type: :String, sync: :raw } etc. — preserves capabilities.
      node.full_type = Type.new(ret[:type], sync: ret[:sync], ownership: ret[:ownership])
    elsif ret.is_a?(Symbol) && ret.to_s.start_with?("infer_") && respond_to?(ret, true)
      node.full_type = send(ret, args, node)
    elsif ret.respond_to?(:call)
      node.full_type = ret.call(args.map(&:resolved_type), node)
    else
      node.full_type = ret
    end

    # 4. Store Zig pattern and stdlib metadata for transpiler
    node.zig_pattern = matched_def[:zig]
    node.matched_stdlib_def = matched_def
    node.stdlib_allocates = true if matched_def[:allocates]
    node.mutates_receiver = true if matched_def[:mutates_receiver]
    node.can_fail = true if matched_def[:can_fail] || matched_def[:allocates]
    node.error_kind = matched_def[:error_kind] if matched_def[:error_kind]
    node.error_type = matched_def[:error_type] if matched_def[:error_type]
    current_fn_ctx.alloc_count += 1 if current_fn_ctx && (matched_def[:allocates] || matched_def[:can_fail] || matched_def[:needs_rt])
    record_effect(EffectTracker::SUSPENDS) if matched_def[:suspends]

    # 5. Flag mutable access through list indexing.
    #    When a mutating intrinsic (e.g., append, remove) is called on a receiver
    #    that chains through a GetIndex, the GetIndex must emit pointer access
    #    instead of by-value getAt().
    if matched_def[:mutates_receiver] && node.is_a?(AST::MethodCall)
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
  def visit_VarDecl(node)
    if node.value.is_a?(AST::ListLit) && node.type.is_a?(Type) && node.type.fixed?
      node.value.storage = :stack
    end
    visit(node.value)
    promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
    promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)
    finalize_decl_node!(node, node.mutable)
    # Atomics M2.3: tie BG-handle lifetimes (see visit_BindExpr).
    stamp_bg_handle_lifetime!(node) if node.value.is_a?(AST::BgBlock) || node.value.is_a?(AST::BgStreamBlock)
  end

  # Shared declaration body used by visit_VarDecl and the declaration path of
  # visit_BindExpr. mutable_flag is node.mutable for VarDecl and false for BindExpr
  # (BindExpr declarations are immutable by default).
  # Pipeline-terminal observable detection (Commit 3 of the
  # observable wiring). When the bind site has shape:
  #
  #   running: ~Int64@observable = stream |> SUM _;
  #
  # Phase 2.2 already stamped `observable_terminal = true` on the
  # pipe BinaryOp. Here we lift the pipe's apparent type from
  # scalar (`Int64`) to the LHS type (`~Int64@observable`) so the
  # subsequent `coerce!` check passes, and stamp `observable_dest`
  # so pipeline_generator.rb (Commit 4) emits the accumulator path
  # instead of an inline fold.
  def promote_pipe_to_observable_dest!(node)
    return unless node.respond_to?(:type) && node.type
    return unless node.respond_to?(:value) && node.value
    target = node.type.is_a?(Type) ? node.type : Type.new(node.type)
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
    if pipe.full_type.is_a?(Type) && pipe.full_type.observable_terminal
      pipe_terminal = pipe.full_type.observable_terminal
      target_t = node.type.is_a?(Type) ? node.type : Type.new(node.type)
      # The pipe is the authority on terminal kind: only the fold's
      # analyzer knows whether this is :sum / :count / :max / ... .
      # The LHS annotation (`~Int64@observable`) never carries one, so
      # an existing non-nil stamp here means a prior pass disagreed
      # with the analyzer. Reject loudly instead of silently winning
      # one of the two via `||=` (H7).
      if target_t.observable_terminal && target_t.observable_terminal != pipe_terminal
        raise CompilerError.new(
          "Observable terminal mismatch: LHS stamped #{target_t.observable_terminal.inspect}, " \
          "pipe analyzer produced #{pipe_terminal.inspect}",
          node.location,
        )
      end
      target_t.observable_terminal = pipe_terminal
      node.type = target_t
      # node.full_type is the resolved Type read by mir_lowering's
      # transpile_type; propagate the terminal kind there too so
      # OBSERVABLE_WRAPPERS can find it. Without this, the binding's
      # emitted Zig wrapper would default-or-raise. Same mismatch
      # check as above.
      if node.respond_to?(:full_type) && node.full_type.is_a?(Type) && node.full_type.observable?
        if node.full_type.observable_terminal && node.full_type.observable_terminal != pipe_terminal
          raise CompilerError.new(
            "Observable terminal mismatch on full_type: stamped " \
            "#{node.full_type.observable_terminal.inspect}, pipe produced #{pipe_terminal.inspect}",
            node.location,
          )
        end
        node.full_type.observable_terminal = pipe_terminal
      end
    end
    pipe.full_type = node.type
  end

  def finalize_decl_node!(node, mutable_flag)
    verify_unrestricted!(node)
    handle_assign_move(node)
    handle_assign_borrow(node)

    validate_type_annotation!(node, node.type) if node.type
    validate_stream_type!(node)

    # Pipeline-terminal observable: when LHS is `~T@observable` and
    # RHS is a fold-pipe whose source is a tense stream (Phase 2.2's
    # `observable_terminal` stamp), promote the pipe's apparent type
    # to match the LHS so coerce! accepts the assignment. The
    # `observable_dest` flag tells pipeline_generator.rb to emit the
    # accumulator-and-fiber codegen path (Commit 4).
    promote_pipe_to_observable_dest!(node)

    # I1: an `~T@observable` binding has no usable shape unless it was
    # initialized by a fold-pipe over a tense stream -- the
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
    if node.type.is_a?(Type) && node.type.future? && node.type.observable?
      pipe = node.value
      ok = pipe.is_a?(AST::BinaryOp) && pipe.op == :SMOOTH && pipe.observable_dest
      unless ok
        msg = "`~T@observable` bindings must be initialized by a pipeline-terminal fold " \
              "over a tense stream (e.g. `running: ~Int64@observable = stream |> SUM _`). " \
              "The producer fiber, atomic accumulator, and WaitGroup wiring all live in " \
              "the fold's codegen path -- a bare declaration or a non-fold initializer has " \
              "no producer, so NEXT/COLLECT would deadlock and cleanup would touch an " \
              "uninitialized wrapper."

        # A20: offer a fixable that drops `@observable` from the type
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
        if obs_tok && obs_tok.respond_to?(:line) && obs_tok.respond_to?(:column)
          # Token value is `@observable` (first cap) or `:observable`
          # (chained after another cap). Match length to the actual
          # token text so the edit deletes exactly the right span.
          tok_text = obs_tok.respond_to?(:value) ? obs_tok.value.to_s : "@observable"
          fixes << Fix.new(
            description: "Drop `#{tok_text}` from the binding's type annotation. The remaining type behaves as a regular binding (no producer fiber, no WITH VIEW); use this if you didn't actually want streaming-aggregate semantics.",
            confidence: :interactive,
            edits: [Edit.new(
              span: Span.new(file: nil, line: obs_tok.line, col: obs_tok.column, length: tok_text.length),
              replacement: "",
            )],
          )
        end

        return error!(node, msg) if fixes.empty?
        fixable!(node, message: msg, category: :type, level: :error,
                 fixes: fixes, raise_in_collector: false)
      end
    end

    final_type, error = node.value.coerce!(node.type)
    error!(node, error) if error

    # M2.2 — empty `[]` / `{}` initializer with `: Auto`: coerce!
    # returns the Auto Type unchanged because Auto tolerates any
    # source. But binding the scope as Auto then breaks method
    # dispatch (e.g. `xs.append(...)` has no Auto overload). Force
    # the scope-bound type to the value's inferred container type
    # (`Any[]` / `HashMap<Any>`) so the body walk type-checks
    # against a permissive container; ShapeEvidenceCollector +
    # AutoUnifier later refine the decl's stamped type to the
    # forward-flow result. The decl_node.type stays Auto so the
    # constraint collector still recognizes the binding as a
    # shape-tagged Auto slot.
    if node.type.is_a?(Type) && node.type.auto? &&
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
    is_resource, resource_close = resolve_resource_close(node, final_type)
    node.resource_close_zig = resource_close
    node.type_info.is_resource = true if is_resource && node.type_info.respond_to?(:is_resource=)

    Capabilities.validate!(node, node.type_info) { |n, msg| error!(n, msg) }

    node_sync = node.type_info&.sync
    node_layout = node.type_info&.layout
    # Preserve collection metadata (e.g. :set from DISTINCT) in scope so
    # resolve_full_type returns the correct dispatch_key for method lookup.
    # Do NOT store the full node.type_info — it embeds ownership/sync from
    # finalize_storage!, which breaks resolve_type in declare_capability_scope!
    # (WITH EXCLUSIVE unwrapping reads the raw entry.type expecting just the base type).
    scope_type = if node.type_info&.collection && !(final_type.is_a?(Type) && final_type.collection)
      ft = Type.new(final_type)
      ft.collection = node.type_info.collection
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
    # Propagate @link_source from the value type to the scope entry.
    val_ti = node.value&.type_info
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
    if node.type_info&.observable?
      node.symbol.non_escaping = true
    end
    # MVCC L5-followup (D4): bare `T@versioned` (no Group-1 sigil) is
    # legal but unusual -- a single-owner MVCC cell can't be reached
    # from another thread, so the lock-free path's value is moot.
    # `T@shared:versioned` (Arc<Versioned>) is the typical shape.
    # T3: upgrade from a bare [Note] to a [Fixable] with an auto-fix
    # that splices `@shared:` in front of `@versioned`. Preserves the
    # Versioned semantics while enabling cross-thread sharing -- the
    # most likely intent if the user reached for `@versioned` at all.
    # Users who genuinely want a local cell can ignore the fix and
    # remove the sigil manually.
    if node.type_info&.versioned? && node.type_info&.ownership == :affine
      cap_tok = node.value.is_a?(AST::CapabilityWrap) ? node.value.token : nil
      fixes = []
      if cap_tok && cap_tok.respond_to?(:line) && cap_tok.respond_to?(:column) &&
         cap_tok.respond_to?(:value) && cap_tok.value.to_s == "@versioned"
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
    og_declare(node.name, node, node.type_info || final_type)
    register_container_borrow!(node)
    # Non-Copy union locals need rt for cleanup (heapAlloc for *T/@indirect fields).
    ti = node.type_info
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
  def visit_BindExpr(node)
    # Same pre-set as visit_VarDecl: mark fixed-array list literals as :stack before visiting.
    if node.value.is_a?(AST::ListLit) && node.type.is_a?(Type) && node.type.fixed?
      node.value.storage = :stack
    end
    visit(node.value)

    scope = current_scope
    if !scope.locals.key?(node.name)
      # Declaration path
      promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
      promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)
      node.mode = :decl
      finalize_decl_node!(node, false)
      # Struct with BORROWED fields: propagate non_escaping to the binding.
      if node.value.instance_variable_get(:@has_borrowed_fields)
        node.symbol.non_escaping   = true
        node.symbol.borrowed_alias = true
      end
      # Atomics M2.3: a BG handle inherits the lifetime of the atomics
      # and lifetime-bounded borrows it captures. The handle cannot
      # outlive the shortest-lived source. M2.5's escape checker reads
      # `symbol.lifetime` to validate RETURN / store / queue-push sites.
      stamp_bg_handle_lifetime!(node) if node.value.is_a?(AST::BgBlock) || node.value.is_a?(AST::BgStreamBlock)

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

      # Atomics M1.5: rewrite assignment to an @shared:atomic binding into
      # an atomic op call. Plain `c = v` becomes `c.store(v)`. Compound
      # forms (parser already desugared `c += 1` to `c = c + 1` and tagged
      # compound_op = :ADD) become `c.fetchAdd(1)` so the read-modify-write
      # is actually atomic instead of a load+add+store race.
      target_sync = scope.locals[node.name]&.sync
      if target_sync == :atomic
        op = case node.compound_op
             when nil  then :store
             when :ADD then :fetchAdd
             when :SUB then :fetchSub
             when :MUL, :DIV
               error!(node, "Atomic primitives do not support `#{node.compound_op == :MUL ? "*=" : "/="}`. " \
                            "Atomic ops are limited to load / store / fetch_add / fetch_sub. " \
                            "For more complex updates, use compareAndSwap or switch to @shared:locked.")
               nil
             else
               error!(node, "Compound op #{node.compound_op} is not supported on @shared:atomic targets.")
               nil
             end
        node.auto_atomic_op = op if op
        # Atomics M1.6.5: atomic store / fetch_op contends on the cell line.
        record_effect(EffectTracker::CONTENTION)
      end
    end
  end

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
    if raw_type.raw.is_a?(Hash) && raw_type.raw[:params] && !raw_type.fn_type?
      # Named function used as a value — build a proper fn_type Type.
      # Propagate :reentrant so the type-checker can enforce param constraints.
      sig = raw_type.raw
      node.full_type = Type.new({ params: sig[:params], return: sig[:return], fn_type: true, reentrant: sig[:reentrant] == true })
      node.fn_ref = true
    elsif raw_type.is_a?(Type) && raw_type.atomic? && raw_type.layout != :indirect
      # Atomics M1.5: a read of an `@shared:atomic` binding produces
      # the bare inner value (load semantics). Type-system-wise the
      # binding shows as the inner T at use sites — the Arc/Atomic
      # wrappers are an implementation detail. The MIR-lowering emits
      # the actual atomic load via lower_identifier's :atomic check.
      # The symbol's stored sync (:atomic) is preserved for the
      # assignment-target side, which still needs to detect it.
      # Note: passing an @shared:atomic identifier as a fn arg whose
      # param has REQUIRES c: ATOMIC currently load-then-passes the
      # value, not the cell — full call-site dispatch lands in M1.7.
      node.full_type = Type.new(raw_type.raw)
      # Atomics M1.6.5: atomic load -> :CONTENTION (cache-coherence
      # pressure on the cell line). No :BLOCKING — atomics never park.
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
  def classify_ownership!(entry)
    return unless entry
    t = entry.type
    return if t.is_a?(Hash) # function signature, not a variable
    type_obj = t.is_a?(Type) ? t : Type.new(t || :Any)
    entry.ownership_kind = if entry.resource
      :resource
    elsif type_obj.multiowned? || type_obj.shared? ||
          entry.storage == :multiowned || entry.storage == :shared
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
  def track_union_alias(var_name, value_node)
    return unless value_node.is_a?(AST::FuncCall) || value_node.is_a?(AST::MethodCall)
    ret_type = value_node.respond_to?(:full_type) ? value_node.full_type : nil
    return unless ret_type
    ret_type_obj = ret_type.is_a?(Type) ? ret_type : Type.new(ret_type)

    # Check if the return type is a union with heap variants
    schema = lookup_type_schema(ret_type_obj.resolved)
    return unless schema.is_a?(Hash) && schema[:kind] == :union
    has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
    return unless has_heap

    # Get the first argument (object for MethodCall, first arg for FuncCall)
    first_arg = if value_node.is_a?(AST::MethodCall)
      value_node.object
    elsif value_node.args&.any?
      value_node.args.first
    end
    return unless first_arg.is_a?(AST::Identifier)
    arg_type = first_arg.resolved_type

    # Alias when: first arg is the SAME union type (extraction like jsonGet)
    # or first arg is a map (HashMap lookup returning union value)
    if arg_type == ret_type_obj.resolved || first_arg.type_info&.map?
      @og.edges << OwnershipGraph::Edge.new(from: var_name, to: first_arg.name, kind: :aliases)
    end
  end

  def accumulate_stack_bytes(storage, node)
    return unless storage == :stack && current_fn_ctx
    bytes = (node.slot_size || 1) * 8
    current_fn_ctx.stack_vars_bytes += bytes
  end

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
  def mark_var_mutated_via_call(name)
    scope = lookup_scope_for(name)
    return unless scope
    entry = scope.locals[name]
    return unless entry
    entry.mutated = true
  end

  # Walk a chained access expression (GetField/GetIndex chain rooted at an
  # Identifier) and return the root identifier name, or nil if the chain
  # doesn't bottom out at one. Used to attribute receiver mutation back to
  # the declared binding.
  def chain_root_name(node)
    curr = node
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      curr = curr.target
    end
    curr.is_a?(AST::Identifier) ? curr.name : nil
  end

  # ==========================================
  # Assignment
  # ==========================================
  def visit_Assignment(node)
    visit(node.value)

    verify_unrestricted!(node)
    # Atomics M2.6: a tied-lifetime value flowing into a destination
    # whose declaring scope is OUTSIDE every source's scope is a
    # cross-scope escape. Fires on `a.field = bg` (where `a` outlives
    # the source) and `arr[i] = bg` (where `arr` outlives).
    verify_tied_assignment!(node)

    target = node.name
    case target
    when AST::Identifier, String
      # Simple Variable Assignment: x = 1
      visit_assignment_variable(target, node)

    when AST::GetIndex
      # Array/Map Index Assignment: x[0] = 1
      visit_assignment_index(target, node)

    when AST::GetField
      # Struct Field Assignment: x.field = 1
      visit_assignment_field(target, node)

    else
      error!(node, "Invalid assignment target: #{target.class}")
    end

    handle_assign_move(node)
    handle_assign_borrow(node)

    # If sucessfully assigned, set live
    target_name = node.name.is_a?(AST::Identifier) ? node.name.name : node.name
    og_set_live(target_name)
  end

  def visit_assignment_variable(identifier_or_name, node)
    var_name = identifier_or_name.is_a?(AST::Identifier) ? identifier_or_name.name : identifier_or_name

    scope = current_scope
    if !scope.locals.key?(var_name)
      error!(node, "Cannot assign to undefined variable '#{var_name}'")
    end

    if scope.is_immutable?(var_name)
      error!(node, "Variable '#{var_name}' is immutable")
    end

    validate_assignment_type(node, scope.resolve_type(var_name), node.value.resolved_type)
    node.full_type = scope.resolve_type(var_name)
    mark_var_mutated(var_name)
  end

  def visit_assignment_index(index_node, assignment_node)
    # 1. Analyze the access itself (resolves types, checks bounds if possible)
    visit(index_node)

    # 1b. Flag mutable access through list indexing in the target chain.
    mark_chain_needs_mut_ref!(index_node)

    # 2. Check Mutability of the owner
    if index_node.target.is_a?(AST::Identifier)
      var_name = index_node.target.name
      if current_scope.is_immutable?(var_name)
        error!(assignment_node, "Cannot modify index of immutable list '#{var_name}'")
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

    # 3. Type Check — for map assignments, use the unwrapped value type (V, not ?V).
    #    map[key] READ returns ?V, but map[key] = val STORES V.
    assign_type = index_node.type_info
    if assign_type&.optional?
      assign_type_resolved = assign_type.wrapped_type.resolved
    else
      assign_type_resolved = index_node.resolved_type
    end
    validate_assignment_type(assignment_node, assign_type_resolved, assignment_node.value.resolved_type)

    assignment_node.full_type = assign_type_resolved

    # HashMap put requires heap allocation (rt.heapAlloc()) — record so needs_rt propagates.
    target_type = index_node.target.type_info
    if target_type&.map?
      current_fn_ctx.heap_count += 1 if current_fn_ctx
      record_effect(EffectTracker::HEAP)
    end
  end

  def visit_assignment_field(field_node, assignment_node)
    # 1. Analyze field access
    visit(field_node)

    # AtomicPtr M3.10: bare `cfg.field = ...` on an `@indirect:atomic`
    # binding is invalid -- the AtomicPtr cell publishes whole-T
    # snapshots via atomic pointer swap, not per-field writes. Only
    # the WITH SNAPSHOT MUTABLE alias (a regular *T pointer to a
    # clone the runtime CAS-publishes at scope exit) accepts field
    # assignments. The alias's SymbolEntry is declared without
    # sync/layout so it falls through this check; the original cell
    # binding has sync==:atomic + layout==:indirect.
    #
    # Error message MUST distinguish from primitive @shared:atomic
    # (which uses direct ops `c += 1` because the cell fits in a
    # single CAS-able machine word). Per design contract
    # docs/agents/atomicptr.md §6.1.
    reject_bare_atomic_ptr_mutation!(field_node, assignment_node)

    # 1b. Flag mutable access through list indexing in the target chain.
    mark_chain_needs_mut_ref!(field_node)

    # 2. Check Mutability of the owner
    # @alwaysMutable (RefCell) allows field mutation through const bindings.
    if field_node.target.is_a?(AST::Identifier)
      var_name = field_node.target.name
      syn = field_node.target.symbol&.sync
      if current_scope.is_immutable?(var_name) && syn != :always_mutable
        error!(assignment_node, "Cannot modify field of immutable struct '#{var_name}'")
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

  def validate_assignment_type(node, target_type, value_type)
    return if target_type.nil? || value_type.nil? || target_type == :Any || value_type == :Any
    return if target_type == :NIL # Allow narrowing from initial NIL
    return if target_type == value_type

    if !is_safe_autocast?(value_type, target_type)
      error!(node, "Type Mismatch: Cannot assign #{value_type} to #{target_type}")
    else
      node.value.coerced_type = target_type
    end
  end

  # ==========================================
  # INVALIDATION LOGIC (The "Dependencies" feature)
  # ==========================================

  def visit_Cast(node)
    visit(node.value) # Resolve 'json' -> :HashMap

    # node.target is "Config".
    # In a strict language, we'd check if :HashMap can cast to Config.
    # For now, just trust the user and carry the type forward.
    node.full_type = node.target.to_sym  # TODO: Check is this is needed
  end

  def visit_GetIndex(node)
    visit(node.target)
    visit(node.index)

    target_type_info = node.target.type_info

    # Look up index operation from the registry
    op = resolve_index_op(target_type_info, :get)

    if op
      # Registry-driven: type and ownership from INDEX_OPS
      node.full_type = op[:return_type].call(target_type_info)
      node.container_borrow = true if op[:container_borrow]

      # Validate key types for maps
      if target_type_info.map?
        index_type_info = node.index.type_info
        if target_type_info.numeric_map?
          error!(node, "Numeric map keys must be a number type, got #{node.index.resolved_type}") unless index_type_info&.numeric?
        else
          error!(node, "Map keys must be Strings, got #{node.index.resolved_type}") unless index_type_info&.string?
        end
      end

    # Special cases not covered by INDEX_OPS
    elsif target_type_info.promise_list?
      # Promise list indexing yields ~T (tense type); dispatch_key returns :array
      # but resolve_index_op guards against this above.
      elem_t = target_type_info.tense_type.element_type
      node.full_type = Type.new(:"~#{elem_t.resolved}")
    elsif target_type_info.string? && !target_type_info.raw?
      error!(node, "Cannot index String by integer. Use String@raw for byte access, or .codepoints() for iteration.")
    elsif node.target.metatype == :struct
      # Struct field access via index (rare legacy path)
      node.full_type = target_type_info.element_type
      node.container_borrow = true
    else
      error!(node, "Unsupported Index")
    end
  end

  def visit_GetField(node)
    # Enum/Union variant access: TypeName.Variant
    # Must be checked BEFORE visiting target to avoid "variable not found" error.
    return if resolve_variant_access(node)

    visit(node.target)

    # Check if this path or any ancestor has been moved (graph handles both)
    path = get_path_to_root(node)
    if path
      # Check root, then progressively longer sub-paths
      check = ""
      path.each do |seg|
        check = check.empty? ? seg.to_s : "#{check}.#{seg}"
        if @og.moved?(check)
          error!(node, "Use of moved value '#{path.map(&:to_s).join(".")}'")
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

    schema = lookup_type_schema(type)
    if schema.is_a?(Hash) && schema[:kind] == :enum
      error!(node, :ENUM_FIELD_ACCESS, type)
    elsif schema.is_a?(Hash) && schema[:kind] == :union
      error!(node, :UNION_FIELD_ACCESS, type)
    elsif schema && schema[node.field]
      field_type = schema[node.field]
      # SOA tracking: record field access on pipeline variable `_`
      if @pipeline_accessed_fields && node.target.is_a?(AST::Identifier) && node.target.name == "_"
        @pipeline_accessed_fields << node.field
      end
      # For generic instances (e.g. Pair<Number>), substitute type params into field type.
      # Handles compound types like T[], ?T, !T via apply_type_subst.
      # BORROWED fields are stored as plain types in the schema (borrowed_fields tracks which).
      type_obj = Type.new(type)
      if type_obj.generic_instance? && schema[:type_params]
        subst = {}
        schema[:type_params].zip(type_obj.generic_args).each do |param, arg|
          subst[param] = arg.resolved
        end
        field_type = apply_type_subst(field_type, subst) if subst.any?
      end
      node.full_type = field_type
    else
      error!(node, :ILLEGAL_FIELD_LOOKUP, node.field, type)
    end
  end

  def visit_Slice(node)
    visit(node.target)
    visit(node.start) if node.start
    visit(node.end) if node.end

    # A slice of T[] is T[]
    # A slice of T[3] is T[] (Fixed becomes Dynamic view)
    target_type = node.target.type_info
    if target_type&.array?
      element = target_type.element_type.resolved
      node.full_type = :"#{element}[]"
    else
      node.full_type = :Any
    end
  end

  # Thunk Phase 4.1 / 4.2 (parser-only commit): the syntax is
  # reserved; runtime semantics defer to v0.3. Emit a precise
  # "not yet implemented" error so users get a clear forward-
  # pointing diagnostic instead of silently wrong codegen.
  def visit_CallSiteOverride(node)
    sigil = node.kind == :thunk ? "@thunk" : "@maxDepth"
    error!(node,
      "#{sigil}(#{node.n}) is parsed but not yet implemented. Per-call-site " \
      "monomorphization (cloning the callee + rewriting recursive calls inside " \
      "the clone so the depth counter / trampoline applies to internal recursion) " \
      "lands in v0.3 alongside the broader monomorphization pass. For now, " \
      "declare the variant on the function instead: " \
      "#{node.kind == :thunk ? "'EFFECTS REENTRANT:THUNK'" : "'EFFECTS REENTRANT:MAX_DEPTH(#{node.n})'"} " \
      "(call-site overrides will be a strictly additive feature when 4.1/4.2 land).")
  end

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

    # Analyze all keys + values. Visiting keys populates their
    # type_info, which the Auto-inference pass (`:map_key` shape
    # slots, M2.2) reads to resolve the binding's HashMap key type
    # when the user writes `m: Auto = { "k": v, ... }` or reassigns
    # a shape-tracked binding to a hash literal.
    node.pairs.each { |k, v| visit(k); visit(v) }

    # Infer Type from first value
    first_val_type = node.pairs.values.first.resolved_type

    # Simple check: Ensure all values match
    node.pairs.each do |k, v|
      if v.resolved_type != first_val_type
        error!(node, "HashMap must have all values be the same type")
      end
    end

    node.full_type = :"HashMap<#{first_val_type}>"
    node.storage = :heap
    current_fn_ctx.heap_count += 1 if current_fn_ctx
    record_effect(EffectTracker::HEAP)
  end

  def visit_StructLit(node)
    schema = lookup_type_schema(node.name.to_sym)
    if schema.nil?
      error!(node, "Unknown struct type: '#{node.name}'")
    end

    # Union literal: Result{ Ok: 42 } or Option<Number>{ Some: 42.0 }
    # Reuses struct-literal syntax — no new parser changes required.
    if schema.is_a?(Hash) && schema[:kind] == :union
      if node.fields.length != 1
        error!(node, "Union literal '#{node.name}' must specify exactly one variant, got #{node.fields.length}.")
      end

      # Build type param substitution for generic unions
      union_type_params = schema[:type_params]
      union_subst = {}
      if node.type_args&.any?
        if union_type_params.nil? || union_type_params.empty?
          error!(node, "Type Error: '#{node.name}' is not a generic type — remove the type arguments.")
        end
        if node.type_args.length != union_type_params.length
          error!(node, "Type Error: '#{node.name}' expects #{union_type_params.length} type argument(s), got #{node.type_args.length}.")
        end
        union_type_params.zip(node.type_args).each { |p, a| union_subst[p] = a.to_sym }
      elsif union_type_params&.any?
        params_hint = union_type_params.map(&:to_s).join(', ')
        error!(node, "Type Error: '#{node.name}' is a generic type — type arguments are required (e.g., #{node.name}<#{params_hint}>).")
      end

      variant_name, val_node = node.fields.first
      unless schema[:variants].key?(variant_name)
        anchor = variant_anchor_from_unionlit(node, variant_name)
        if anchor
          emit_variant_typo!(
            anchor, variant_name, schema[:variants].keys,
            "Type Error: Union '#{node.name}' has no variant '#{variant_name}'.",
            "variant of union #{node.name}",
            cascade: true
          )
        else
          error!(node, :UNION_UNKNOWN_VARIANT, node.name, variant_name)
        end
      end
      raw_expected = schema[:variants][variant_name]
      if raw_expected.nil?
        error!(node, "Union variant '#{variant_name}' is a unit variant — use '#{node.name}.#{variant_name}' (no payload).")
      end
      if raw_expected.is_a?(Hash) && raw_expected[:kind] == :inline_struct
        error!(node, :UNION_INLINE_VARIANT_OLD_SYNTAX, node.name, variant_name, node.name, variant_name)
      end
      # @indirect single-type payload: unwrap inner type for type-checking;
      # mark the value node so the transpiler heap-allocates it via create(*T).
      indirect_payload = raw_expected.is_a?(Hash) && raw_expected[:kind] == :indirect_payload
      raw_for_check = indirect_payload ? raw_expected[:type] : raw_expected
      # Apply type param substitution (e.g. T → Number for generic unions)
      expected_type = union_subst.any? ? apply_type_subst(raw_for_check, union_subst) : raw_for_check
      visit(val_node)
      if indirect_payload
        val_node.needs_heap_create = true
        current_fn_ctx.heap_count += 1 if current_fn_ctx  # heapAlloc().create(*T) needs rt
      end
      reject_borrowed_value!(val_node, "#{node.name}.#{variant_name}")
      # Ensure value is owned data (implicit COPY for @list/rodata strings).
      owned = ensure_owned_value!(val_node, expected_type, "#{node.name}.#{variant_name}")
      if owned
        node.fields[variant_name] = owned
        val_node = owned
      end
      actual = val_node.type_info
      unless expected_type.accepts?(actual)
        error!(node, :UNION_PAYLOAD_MISMATCH, variant_name, expected_type.resolved, actual&.resolved)
      end
      # Move: union literal captures non-Copy values.
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
      field_names = schema.keys.reject { |k| k.is_a?(Symbol) }
      unless field_names.empty?
        field_defaults = schema[:field_defaults] || {}
        missing = field_names.reject { |f| field_defaults.key?(f) }
        if missing.any?
          error!(node, "Cannot use '#{node.name}{}' — field(s) #{missing.join(', ')} have no default values")
        end
      end
      node.full_type = node.name.to_sym
      return
    end

    # Build type param substitution map for generic struct instantiation.
    # e.g. Pair<Number>{ first: 1.0 } → { :T => :Float64 }
    type_params = schema[:type_params]
    type_subst = {}
    if node.type_args&.any?
      if type_params.nil? || type_params.empty?
        error!(node, "Type Error: '#{node.name}' is not a generic type — remove the type arguments.")
      end
      if node.type_args.length != type_params.length
        error!(node, "Type Error: '#{node.name}' expects #{type_params.length} type argument(s), got #{node.type_args.length}.")
      end
      type_params.zip(node.type_args).each do |param, arg|
        type_subst[param] = arg.to_sym
      end
    elsif type_params&.any?
      params_hint = type_params.map(&:to_s).join(', ')
      error!(node, "Type Error: '#{node.name}' is a generic type — type arguments are required (e.g., #{node.name}<#{params_hint}>).")
    end

    # Iterate Fields (Validation)
    node.fields.each do |field_name, val_node|
      visit(val_node) # Resolve value type

      raw_expected = schema[field_name]
      if raw_expected.nil?
        valid_fields = schema.keys.reject { |k| k == :borrowed_fields || k.to_s.start_with?('_') }
        name_tok = node.field_tokens&.[](field_name)
        if name_tok
          emit_typo_suggestion!(
            name_tok, field_name, valid_fields,
            "Struct '#{node.name}' has no field '#{field_name}'",
            "field of #{node.name}",
            category: :type, cascade: true
          )
        else
          error!(node, "Struct '#{node.name}' has no field '#{field_name}'")
        end
      end

      # Check if this field is declared BORROWED in the struct definition
      field_is_borrowed = schema[:borrowed_fields]&.include?(field_name)

      # Apply type param substitution (e.g., T → Number, T[] → String[])
      expected_type = if type_subst.any?
        apply_type_subst(raw_expected, type_subst)
      else
        raw_expected
      end

      # BORROWED fields accept borrowed values — skip ownership checks.
      # Non-borrowed fields require owned data.
      unless field_is_borrowed
        reject_borrowed_value!(val_node, "#{node.name}.#{field_name}")
      end
      # Skip CopyNode wrapping for rodata strings in call argument structs.
      # The struct is a temporary - rodata strings are valid for the call's
      # lifetime. The callee dupes strings it needs to escape.
      is_call_arg = node.instance_variable_get(:@is_call_arg)
      owned = unless field_is_borrowed || is_call_arg
        ensure_owned_value!(val_node, expected_type, "#{node.name}.#{field_name}")
      end
      if owned
        node.fields[field_name] = owned
        val_node = owned
      end

      # Simple Type Check
      if val_node.full_type != expected_type
        unless is_safe_autocast?(val_node.resolved_type, expected_type)
          error!(node, "Field '#{field_name}' expected #{expected_type}, got #{val_node.resolved_type}")
        end
        val_node.coerced_type = expected_type
      end

      # Flag @list fields so the transpiler passes the ArrayList directly
      # instead of converting to a slice via .items.
      et = expected_type.is_a?(Type) ? expected_type : nil
      val_node.target_is_list_field = true if et&.list_collection?

      # Move: struct literal captures non-Copy values (skip for borrowed fields).
      move_if_not_copyable!(val_node) unless field_is_borrowed
    end

    # Non-escaping propagation: structs with BORROWED fields inherit non_escaping.
    node.instance_variable_set(:@has_borrowed_fields, true) if schema[:borrowed_fields]&.any?

    # Set full_type to the generic instance name or plain struct name
    node.full_type = if node.type_args&.any?
      :"#{node.name}<#{node.type_args.join(',')}>"
    else
      node.name.to_sym
    end
  end

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
        error!(node, "Bounded stream literal contains mixed promise types: #{inner_types.join(', ')}. All BG blocks must produce the same type.")
      end
      node.full_type = :"~#{inner_types.first}[#{node.items.size}]"
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
          error!(node, "List literal contains mixed types: First item is #{base_type}, item #{index+1} is #{item.resolved_type}")
        end
      end
    end

    if node.storage == :stack
      node.full_type = :"#{base_type}[#{node.items.size}]"
    else
      t = Type.new(:"#{base_type}[]", location: :heap)
      t.provenance = :frame  # makeList uses frameAlloc for backing
      node.full_type = t
    end
  end

  def visit_RangeLit(node)
    visit(node.start)
    visit(node.finish)

    start_type = node.start.resolved_type
    finish_type = node.finish.resolved_type

    unless Type.new(start_type).numeric?
      error!(node, "Range start must be a numeric type, got #{start_type}")
    end

    unless Type.new(finish_type).numeric?
      error!(node, "Range end must be a numeric type, got #{finish_type}")
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

  def visit_Literal(node)
    node.full_type =
      case node.type
      when :NUMBER then :Float64
      when :INT64 then :Int64
      when :STRING
        # provenance auto-inferred from location: :rodata in Type constructor
        if node.storage == :stack
          Type.new(:"Byte[#{node.value.length}]", location: :rodata)
        else
          Type.new(Type::STRING_TYPE, location: :rodata)
        end
      when :SYMBOL
        # Symbol literals: compile-time interned, static lifetime, O(1) equality by pointer.
        Type.new(Type::STRING_TYPE, sync: :symbol)
      when :BYTE         then :Byte
      when :PREFIXED_INT then :Byte  # Default; overflows checked after coercion context is known
      when :INT8    then :Int8
      when :INT16   then :Int16
      when :INT32   then :Int32
      when :UINT16  then :UInt16
      when :UINT32  then :UInt32
      when :UINT64  then :UInt64
      when :FLOAT32 then :Float32
      when :BOOLEAN then :Bool
      when :NIL then :NIL
      else
        error!(node, "UNKNOWN LITERAL!")
      end
  end

  def visit_DefaultLit(node)
    # Resolved type is set by declare_and_verify_params / visit_StructLit context.
    # Standalone DEFAULT is not valid; callers validate the context.
    node.full_type = :Any
  end

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
    result = Type.binary_op(node.op, node.left.type_info, node.right.type_info)

    if result.error
      error!(node, "Type Error: #{result.error}")
    end

    node.full_type = result.type
    node.left.coerced_type = result.left_coercion if result.left_coercion
    node.right.coerced_type = result.right_coercion if result.right_coercion
    node.storage = result.storage if result.storage

    # String concat (+) transpiles to std.mem.concat(rt.frameAlloc(), ...) —
    # mark as frame allocation so needs_rt and loop mark elision are correct.
    if node.op == :ADD && (node.left.type_info&.string? || node.right.type_info&.string?)
      node.string_concat = true
      current_fn_ctx.frame_count += 1 if current_fn_ctx
      # String concat result is frame-allocated.
      ti = node.type_info
      ti.provenance = :frame if ti.is_a?(Type)
    end
  end

  def visit_Placeholder(node)
    # Just resolve it like an identifier
    visit_Identifier(AST::Identifier.new(node.token, "_"))
  end

  # =========================================================
  # BIND VAR (AS / @)
  # =========================================================
  def visit_BindVar(node)
    # Logic: expression AS @name
    # The value flows through, but we declare a new variable in the scope.

    visit(node.left)
    lhs_type = node.left.full_type

    # node.right is the Identifier for the new variable
    var_name = node.right.name

    # When binding a collection source (users AS @u), @u refers to each *element*,
    # not the collection. Subsequent @u.field accesses need the element type.
    # Note: collection? covers pool/list/map; array? is needed for plain T[] arrays.
    lhs_ti = Type.new(lhs_type)
    binding_type = if (lhs_ti.array? || lhs_ti.collection?) && !lhs_ti.string? && lhs_ti.element_type
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

    # The result of the operation is the collection itself (passthrough for pipeline)
    node.full_type = lhs_type
  end

  # =========================================================
  # OR / RESCUE
  # =========================================================
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
                    node.left.type_info
                  end
    t_right_type = node.right.type_info

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
        error!(node, "OR BREAK can only be used inside a WHILE loop")
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
        error!(node, "Type mismatch in OR: expected #{payload_type.resolved}, got #{t_right_type.resolved}")
      end

      # Result is the payload type (error is handled)
      node.full_type = payload_type.resolved
      return
    end

    # Handle optional types: ?T OR default -> T
    if t_left_type.optional?
      wrapped = t_left_type.wrapped_type
      unless wrapped.accepts?(t_right_type) || t_right_type.accepts?(wrapped)
        error!(node, "Type mismatch in OR: expected #{wrapped.resolved}, got #{t_right_type.resolved}")
      end
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

  def visit_OrRaise(node)
    node.full_type = :Void
  end

  def visit_OrBreak(node)
    node.full_type = :Void
  end

  def visit_OrPass(node)
    # This is a marker node for OR PASS - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    node.full_type = :Void
  end

  def visit_OrPrune(node)
    # This is a marker node for OR PRUNE - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    node.full_type = :Void
  end

  def visit_OrExit(node)
    visit(node.message) if node.message
    resolve_error_registration!(node, node.kind, node.error_name, node.token)
    node.full_type = :Void
  end

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
    is_atomic_primitive = node.sync == :atomic && node.layout != :indirect

    # AtomicPtr M3.4: `@indirect:atomic` is the STRUCT-as-AtomicPtr form
    # (lowers to *CheatLib.AtomicPtr(T)). Reject on primitives -- the
    # primitive case already has `@shared:atomic` (M1) and there is no
    # win in indirect-wrapping a 1-machine-word value. Carve this check
    # out BEFORE the generic primitive-cap rejection so the user gets a
    # message that names the right migration path.
    if ti.primitive? && node.sync == :atomic && node.layout == :indirect
      error!(node,
        "@indirect:atomic is for STRUCTS. For primitive type #{base_type}, " \
        "use `@shared:atomic` (the v0.2 primitive-as-cell form). The atomic " \
        "primitive already fits in a single CAS-able machine word; @indirect " \
        "would add a pointless heap indirection.")
    end

    if ti.primitive? && (node.ownership || node.sync || node.layout) && !is_atomic_primitive
      cap_name = node.sync || node.ownership || node.layout
      error!(node, "Capability @#{cap_name} cannot be applied to primitive type #{base_type}. " \
                   "Wrap in a STRUCT (e.g. STRUCT Wrapper { value: #{base_type} }) and apply the capability to the struct.")
    end

    # AtomicPtr M3.4: `@atomic` alone on a STRUCT is invalid; the struct
    # case requires `@indirect:atomic` (atomic pointer swap publishes a
    # whole-T snapshot, not a single-word fetch_add). Distinct from
    # primitive `@shared:atomic`, which uses direct ops on a CAS-sized
    # cell. Catch BEFORE downstream emission tries to lower
    # `*CheatLib.Atomic(SomeStruct)`, which has no defined backing.
    if !ti.primitive? && node.sync == :atomic && node.layout != :indirect
      error!(node,
        "@atomic on a STRUCT requires @indirect (publishes whole-T snapshots " \
        "via atomic pointer swap). Use `#{base_type}{...} @indirect:atomic` " \
        "instead. (For primitive cells like `Int64@shared:atomic`, atomic " \
        "alone is correct -- those fit in a single CAS-able machine word.)")
    end

    # AtomicPtr M3.4: `@local:indirect:atomic` and `@multiowned:indirect:atomic`
    # combinations are disallowed -- atomic without cross-thread visibility
    # is pointless (@local), and Rc isn't thread-safe (@multiowned). The
    # implicit `@shared` (Arc) that `@indirect:atomic` provides under the
    # hood is the only valid ownership for the AtomicPtr cell.
    if node.sync == :atomic && node.layout == :indirect
      if node.ownership == :local
        error!(node,
          "@local:indirect:atomic is disallowed -- atomic without cross-thread " \
          "visibility is pointless. Drop @local; @indirect:atomic implies " \
          "cross-thread sharing.")
      elsif node.ownership == :multiowned
        error!(node,
          "@multiowned:indirect:atomic is disallowed -- Rc isn't thread-safe " \
          "(non-atomic refcount), so it can't back a cross-thread atomic-ptr " \
          "cell. Drop @multiowned; @indirect:atomic uses Arc internally for " \
          "the published-value lifetime.")
      end
    end

    ti.ownership = node.ownership if node.ownership
    ti.sync      = node.sync      if node.sync
    ti.lock_rank = node.lock_rank if node.lock_rank
    # AtomicPtr M3.1: stamp the :layout axis on Type. Until M3.1, the
    # only consumer of @indirect was the @indirect:atomic combination
    # (-> *CheatLib.AtomicPtr(T) in zig_type), so all earlier @indirect
    # uses just collapsed to provenance=:heap. Keep that fallback for
    # cases where layout isn't paired with a sync or ownership cap.
    ti.layout    = node.layout    if node.layout
    # AtomicPtr M3.5: `@indirect:atomic` implies `@shared` (the design
    # contract in docs/agents/atomicptr.md §3 -- "the user writes
    # `@indirect:atomic`. The compiler infers `:shared` because escaping
    # the declaring scope is the whole point of atomic-ptr"). Promote
    # the ownership axis here so downstream cleanup classification (the
    # :rc kind in promotion_plan picks up `*AtomicPtr(T)` for the
    # cleanup zig_type) and lifetime audit (M2.6 treats `:shared` cells
    # as Arc-escapable) match the design intent. The `:multiowned` /
    # `:local` cases are already rejected upstream (M3.4 errors), so
    # this only fires when the user wrote bare `@indirect:atomic` with
    # no explicit ownership.
    if node.sync == :atomic && node.layout == :indirect && !node.ownership
      ti.ownership = :shared
    end
    # @indirect forces heap location (same as @local, but different intent).
    ti.provenance = :heap           if node.layout == :indirect

    # Phase 3: enforce per-type rank consistency. First declaration of a
    # type with a rank sets it; subsequent declarations must match. A
    # mismatch is a programming error — the rank is meant to induce a
    # total order across acquire sites, which only works if all sites
    # agree on the rank of T.
    if node.lock_rank && node.sync && (node.sync == :locked || node.sync == :write_locked)
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

  def visit_MoveNode(node)
    visit(node.value)

    unless node.value.is_a?(AST::Identifier)
      error!(node, "MOVE can only be applied to a variable identifier")
    end

    ti = node.value.type_info
    
    # Check if the identifier is a resource
    is_resource = false
    if node.value.is_a?(AST::Identifier)
      info = node.value.symbol
      is_resource = info&.resource
    end

    is_copy = ti&.implicitly_copyable? { |t| lookup_type_schema(t) } rescue false
    unless ti&.multiowned? || ti&.shared? || ti&.requires_move? || is_resource || !is_copy
      error!(node, "GIVE cannot be applied to Copy types (#{node.value.resolved_type} is implicitly copyable)")
    end

    # Inherit the capability type so the VarDecl or ReturnNode can infer storage correctly
    node.full_type = node.value.full_type
    node.storage   = node.value.storage

    # Consume the source variable — it is affinely transferred
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
  def ensure_owned_value!(val_node, expected_type, container_desc = nil)
    # Non-escaping values (WITH block aliases) cannot be stored in containers
    if val_node.is_a?(AST::Identifier) && val_node.symbol&.non_escaping
      error!(val_node, "Cannot store WITH-scoped '#{val_node.name}' into #{container_desc || 'a container'}. WITH bindings cannot escape their block.")
    end
    return nil if val_node.is_a?(AST::CopyNode)
    vti = val_node.type_info
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
      elem = vti.element_type
      if elem
        es = lookup_type_schema(elem.resolved) rescue nil
        copy.deep_copy = es.is_a?(Hash) && es[:kind] == :union &&
          (es[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      end
      return copy
    end

    if vti.string? && vti.rodata?
      copy = AST::CopyNode.new(val_node.token, val_node)
      # provenance auto-inferred from location: :heap in Type constructor
      copy.full_type = Type.new(Type::STRING_TYPE, location: :heap)
      return copy
    end

    if vti.string? && val_node.is_a?(AST::Identifier) && container_desc
      error!(val_node, "Cannot store string variable '#{val_node.name}' into #{container_desc} without COPY. Strings are frame-arena managed; use COPY for heap ownership.")
    end

    nil
  end

  def visit_CopyNode(node)
    visit(node.value)
    # COPY produces an owned deep-copy. The source is NOT consumed.
    # Clone the Type so mutating provenance doesn't affect the inner node.
    inner_type = node.value.full_type
    node.full_type = inner_type.is_a?(Type) ? Type.new(inner_type) : inner_type
    node.storage = :stack
    ti = node.type_info
    resolver = ->(name) { lookup_type_schema(name) rescue nil }

    # COPY of a primitive or Id<T> is a semantic no-op (value copy, no allocation).
    # All other explicit COPYs produce heap-owned data.
    source_sync = node.value.respond_to?(:symbol) ? node.value.symbol&.sync : nil
    is_value_copy = ti.is_a?(Type) &&
      source_sync.nil? && !ti.multiowned? && !ti.shared? &&
      (ti.primitive? || (ti.generic_instance? && ti.generic_base == :Id))
    unless is_value_copy
      # COPY always produces heap-owned data for non-value types.
      ti.provenance = :heap if ti.is_a?(Type)
      # Mark as heap usage - COPY allocates via heapAlloc
      current_fn_ctx.heap_count += 1 if current_fn_ctx
    end

    # Determine if elements need deep copy (dupeUnionValue) vs shallow (memcpy).
    # For list/array types, check if element type is a non-Copy union.
    vti = node.value.type_info
    vti = Type.new(vti) if vti && !vti.is_a?(Type)
    if vti && (vti.list_collection? || (vti.array? && !vti.string?))
      elem = vti.element_type
      if elem
        schema = lookup_type_schema(elem.resolved) rescue nil
        if schema.is_a?(Hash) && schema[:kind] == :union
          has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
          node.deep_copy = has_heap
        end
      end
    end
  end

  # Infer return type for list.remove(i) — returns the element type.
  def infer_element_type(args, node)
    receiver = args.first
    ti = receiver&.type_info
    ti&.element_type&.resolved || :Any
  end

  # Infer return type for list.pop() — returns ?T (optional element type).
  def infer_optional_element_type(args, node)
    receiver = args.first
    ti = receiver&.type_info
    elem = ti&.element_type&.resolved || :Any
    :"?#{elem}"
  end

  def visit_LinkNode(node)
    visit(node.value)
    ti = node.value.type_info

    unless ti&.any_rc?
      error!(node, "LINK can only be applied to @shared or @multiowned variables, got '#{node.value.resolved_type}'")
    end

    # Result is the same base type with :link ownership
    link_type = Type.new(ti.resolved)
    link_type.ownership = :link
    # Track which strong ownership kind the link was created from
    link_type.link_source = ti.shared? ? :shared : :multiowned
    node.full_type = link_type
  end

  def visit_ResolveNode(node)
    visit(node.value)
    ti = node.value.type_info

    unless ti&.link?
      error!(node, "RESOLVE can only be applied to @link variables, got '#{node.value.resolved_type}'")
    end

    # RESOLVE returns ?T@multiowned or ?T@shared.
    # Use RESOLVE(link)?.field OR fallback to safely access the target.
    source = ti.link_source || :multiowned
    resolved_type = Type.new(:"?#{ti.resolved}")
    resolved_type.ownership = source == :shared ? :shared : :multiowned
    resolved_type.link_source = source
    node.full_type = resolved_type
  end

  def visit_FreezeNode(node)
    visit(node.value)
    ti = node.value.type_info
    unless ti&.multiowned? || ti&.shared?
      error!(node, "FREEZE can only be applied to @multiowned or @shared values, got '#{node.value.resolved_type}'")
    end
    base = ti.resolved.to_s.sub(/^\?/, '')
    result_type = Type.new(base.to_sym)
    result_type.ownership  = :frozen
    result_type.provenance = :heap
    node.full_type = result_type
    node.storage   = :frozen
  end

  def visit_Give(node)
    visit(node.value)

    # Validate that GIVE is used on something that makes sense
    # (e.g., an identifier, field access, or index access)
    if !node.value.is_a?(AST::Identifier) &&
       !node.value.is_a?(AST::GetField) &&
       !node.value.is_a?(AST::GetIndex)
      error!(node, "GIVE can only be used on variables, fields, or array elements")
    end

    # Mark the original as moved
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier)
      og_set_moved(root.name)
    end

    node.full_type = node.value.resolved_type
  end

  def visit_Copy(node)
    visit(node.value)

    # Validate that the type is actually copyable
    type = node.value.type_info
    unless type&.copyable? { |name| lookup_type_schema(name) }
      error!(node, "Cannot COPY non-copyable type '#{node.value.resolved_type}'")
    end

    node.full_type = node.value.resolved_type
  end

  def visit_CloneNode(node)
    visit(node.value)
    type = node.value.type_info
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
      error!(node, "Cannot CLONE WITH-scoped '#{root.name}'. WITH bindings are protected borrows; use COPY to return owned data.")
    end

    unless type&.split_open_stream? || type&.shared_promise? || type&.any_rc?
      error!(node, "CLONE is only supported on @split streams, @shared promises, and owned shared handles, got '#{node.value.resolved_type}'")
    end

    node.full_type = node.value.full_type
    node.storage = node.value.storage
    current_fn_ctx.needs_rt = true if current_fn_ctx && type&.any_rc?
  end

  def visit_ShareNode(node)
    visit(node.value)
    source_type = node.value.type_info
    source_type = Type.new(source_type) if source_type && !source_type.is_a?(Type)
    error!(node, "SHARE requires a typed value") unless source_type
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier) && root.symbol&.non_escaping
      error!(node, "Cannot SHARE WITH-scoped '#{root.name}'. WITH bindings are protected borrows; use COPY to return owned data.")
    end

    result = Type.new(source_type, ownership: :shared)
    result.provenance = :heap
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

  def visit_OptionalUnwrap(node)
    visit(node.target)

    # Validate that the target is actually an optional type
    type = node.target.type_info
    unless type&.optional?
      error!(node, "Cannot unwrap non-optional type '#{node.target.resolved_type}' with '?'")
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

  def visit_WithBlock(node)
    @with_block_depth = (@with_block_depth || 0) + 1

    # MVCC L7.4 followup (T2 + G1): reject WITH MATCH shapes that
    # would silently miscompile.
    #
    # T2: `WITH c AS MUTABLE va MATCH ... WHEN VERSIONED -> { va.field = X }`
    # writes through the read-snapshot Guard — the write goes into a
    # frozen pointer that's about to be replaced and never commits. The
    # LOCKED arm works (Guard.get() returns *T into the live cell), so
    # the bug only fires for the VERSIONED arm at runtime. Reject up
    # front and direct the user to `WITH SNAPSHOT cell AS MUTABLE va
    # { ... } ON MvccConflict ...` for transactional mutation.
    #
    # AtomicPtr M3.7/M3.8 carve-out: SNAPSHOT MATCH bypasses this
    # rejection because each arm dispatches to `Versioned.update`
    # (VERSIONED) or `AtomicPtr.update` (ATOMIC), which DO commit
    # transactionally. The legacy guard only applied to generic
    # WITH MATCH (no SNAPSHOT prefix), where the VERSIONED arm
    # would write through a read-snapshot Guard.
    #
    # G1: multi-cell WITH MATCH (`WITH c1 AS a1, c2 AS a2 MATCH`) is
    # parser-allowed but lower_with_match_block emits prelude for
    # `node.capabilities.first` only — secondary aliases are undefined
    # in arm bodies. Reject until codegen is extended.
    if node.arms && node.snapshot_mode.nil?
      has_versioned_arm = node.arms.any? { |arm| arm[:family] == :VERSIONED }
      mut_cap = node.capabilities.find { |c| c[:alias_mutable] }
      if has_versioned_arm && mut_cap
        error!(node,
          "WITH MATCH with `AS MUTABLE` and a VERSIONED arm is not " \
          "supported: writes through a Versioned read-snapshot don't " \
          "commit (silent data loss in the VERSIONED arm; only the " \
          "LOCKED arm would mutate the live cell). For transactional " \
          "mutation on a versioned cell use:\n" \
          "    WITH SNAPSHOT #{mut_cap[:var_node].respond_to?(:name) ? mut_cap[:var_node].name : 'cell'} AS MUTABLE va " \
          "{ ... } ON MvccConflict <action>\n" \
          "and keep WITH MATCH for read-side polymorphism.")
      end
      if node.capabilities.length > 1
        names = node.capabilities.map { |c|
          c[:var_node].respond_to?(:name) ? c[:var_node].name : "<expr>"
        }.join(", ")
        error!(node,
          "WITH MATCH with multiple cells (#{names}) is not yet " \
          "supported: lower_with_match_block emits the per-arm prelude " \
          "for the first capability only. Split into separate WITH " \
          "MATCH blocks (one per cell) until multi-cell dispatch lands.")
      end
    end

    # 1. Validate each capability's variable exists and resolve its type
    expanded_capabilities = []
    node.capabilities.each do |cap|
      acquire_capability!(node, cap, expanded_capabilities)
    end

    # Phase 1 static nested-lock check: reject same-variable-name nested
    # fallible acquire unless the inner WITH carries POSSIBLE_DEADLOCK.
    check_nested_lock_reacquire!(node, expanded_capabilities)

    # Phase 3: local rank-ordering check. Runs before edge accumulation
    # so a ranked violation fires with a clear "rank X violates rank Y"
    # message rather than a later SCC-based diagnostic.
    check_lock_rank_ordering!(node, expanded_capabilities)

    # Phase 2: record per-fn held->acquired edges and direct acquires
    # for the global cycle-detection pass. Edges from an opted-out WITH
    # (POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE) are marked opted_out and
    # excluded from the cycle graph.
    #
    # Atomics M1.6.5: for WITH MATCH form, BLOCKING/SUSPENDS are recorded
    # per-arm (only the LOCKED arm prelude blocks). Lock-cycle edges
    # are still emitted at the outer level — the static analysis is
    # conservative and treats any LOCKED-eligible call as potentially
    # acquiring a lock.
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

    # 2. Enter a child scope for the capability block
    # Inherits parent variables so the WITH body can see enclosing locals,
    # but new declarations inside are isolated to the WITH block.
    # Escape checking is handled by the non_escaping flag on SymbolEntry —
    # every escape site (ensure_owned_value!, handle_assign_move, RETURN)
    # checks this flag automatically.
    #
    # MVCC L5-followup (D1): mark the body as a SNAPSHOT-transaction
    # context so record_effect() captures any SUSPENDS-family effects
    # the body produces. After the body visit, raise if any landed.
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
      if is_snapshot_txn_body && !fallible_sources.empty?
        retryable_with_fallible_body_error!(
          node,
          "WITH SNAPSHOT ... AS MUTABLE",
          fallible_sources
        )
      end
      if retryable_with_universal_poly_candidate?(node) && !fallible_sources.empty?
        retryable_with_fallible_body_error!(
          node,
          "WITH POLYMORPHIC",
          fallible_sources
        )
      end
      # MVCC L7.2: WITH MATCH per-arm body annotation. Each arm's body
      # is visited in its own nested scope under the SAME alias binding
      # resolved by the polymorphic-fallback in acquire_capability!
      # (see function_analysis.rb: LOCKED | VERSIONED -> :locked).
      # Per-arm capability resolution + family-specific binding lands
      # in L7.3/L7.4 (#262, #263); for now this gets arm bodies type-
      # stamped enough that lower_with_match_block can lower them into
      # the comptime if-else dispatch (L7.2 mir_lowering side).
      if node.arms
        # Atomics M1.6.5: per-arm effect tracking. Each arm runs through
        # the body in its own scope; we record family-specific prelude
        # effects BEFORE the body so the synthetic acquire/snapshot
        # contributions of LOCKED / VERSIONED / ATOMIC are visible
        # in the per-arm delta. Then we collapse into concrete
        # (intersection across arms) + ?-form (effects in some-but-
        # not-all arms) so the call-site can later resolve the ?-form
        # back to concrete based on the actual arg family.
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
      txn_violations = @snapshot_txn_violations || []
      @inside_snapshot_txn -= 1
      @snapshot_txn_violations = prev_violations
      unless txn_violations.empty?
        kinds = txn_violations.map { |v| EffectTracker.display(v[:effect]) }.uniq.join(", ")
        error!(node,
          "WITH SNAPSHOT ... AS MUTABLE body must be pure for atomicity, " \
          "but the body has #{kinds} effect(s). Yielding the fiber breaks " \
          "the EBR pin and atomicity guarantees; IO can't be rolled back " \
          "if the transaction aborts. Move the impure work outside the " \
          "transaction (read state via WITH SNAPSHOT, do IO, then commit).")
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
      # True-Sync-Polymorphism Gate 3: a `WITH POLYMORPHIC` block whose
      # bound binding is a parameter with no narrow REQUIRES becomes
      # universally polymorphic and lowers to `polymorphicMutate(c, rt,
      # ...)`. The helper threads rt into Versioned/AtomicPtr
      # `.update(rt, alloc, ...)` paths, so the enclosing fn must carry
      # rt -- even when the surface body looks lock-free.
      # Detection at visit time: WITH POLYMORPHIC + the bound binding
      # is a param + the function's REQUIRES (so far) doesn't list this
      # param. The annotator's polymorphic-iff rule (in check_function!)
      # will later re-confirm and stamp `node.universal_poly` so the
      # lowering can route to the new MIR node; but we set rt/fail here
      # because compute_needs_rt! runs before check_function!.
      if node.polymorphic && (node.capabilities || []).length == 1
        bound_var = node.capabilities.first[:var_node]
        bound_name = bound_var.respond_to?(:name) ? bound_var.name.to_s : nil
        bound_sym  = bound_var.respond_to?(:symbol) ? bound_var.symbol : nil
        is_param   = bound_sym && bound_sym.respond_to?(:is_param) && bound_sym.is_param
        fn_node    = @fn_nodes[current_fn_ctx&.name]
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
  # MVCC L5 + True-Sync-Polymorphism (#324 / #330): the errors a
  # SNAPSHOT MUTABLE commit can surface depend on the cell family.
  # @versioned -> MvccConflict (Versioned.update bounded retry).
  # @indirect:atomic -> AtomicConflict (AtomicPtr.update bounded
  # retry, #330 = 256 CAS losses). The dispatch picks per cell at
  # validate_lock_error_clause! time; SNAPSHOT_POSSIBLE_TYPES is the
  # union over both for the resolve_error_selectors! reachability
  # check.
  SNAPSHOT_POSSIBLE_TYPES = %i[MvccConflict AtomicConflict].freeze

  def retryable_with_fallible_sources(nodes)
    sources = []
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
        sources << n.name.to_s if retryable_with_call_fallible?(n)
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

  def retryable_with_call_fallible?(node)
    return true if node.respond_to?(:can_fail) && node.can_fail
    return true if node.respond_to?(:error_union_type) && node.error_union_type
    false
  end

  def retryable_with_universal_poly_candidate?(node)
    return true if node.universal_poly
    return false unless node.polymorphic && (node.capabilities || []).length == 1

    bound_var = node.capabilities.first[:var_node]
    bound_name = bound_var.respond_to?(:name) ? bound_var.name.to_s : nil
    bound_sym = bound_var.respond_to?(:symbol) ? bound_var.symbol : nil
    is_param = bound_sym && bound_sym.respond_to?(:is_param) && bound_sym.is_param
    fn_node = @fn_nodes[current_fn_ctx&.name]
    has_req = fn_node && fn_node.respond_to?(:requires) && fn_node.requires &&
              fn_node.requires.key?(bound_name)
    is_param && !has_req
  end

  def retryable_with_fallible_body_error!(node, with_name, sources)
    detail = sources.first(3).join(", ")
    detail += ", ..." if sources.length > 3
    error!(node,
      "#{with_name} body must be non-fallible for atomicity, " \
      "but it contains fallible work (#{detail}). Retryable synchronization " \
      "bodies may run more than once and cannot safely propagate user " \
      "failures from inside the update callback. Move fallible work outside " \
      "the WITH body, store the result in a local, then commit only " \
      "non-fallible mutations inside the WITH.")
  end

  def validate_lock_error_clause!(node, expanded_capabilities)
    clause = node.lock_error_clause
    is_snapshot_txn = node.snapshot_mode == :transaction

    # AtomicPtr M3.8: SNAPSHOT MATCH MUTABLE has per-arm conflict
    # contracts. The trailing `node.lock_error_clause` is nil
    # (arms own their own ON MvccConflict clauses); validate each arm
    # against its family's rule and short-circuit before the
    # single-arm checks below.
    if node.arms && is_snapshot_txn
      validate_snapshot_match_arms!(node)
      return
    end

    # AtomicPtr M3.6 + True-Sync-Polymorphism (#324): split the
    # SNAPSHOT-transaction conflict-handler contract by family.
    # Versioned (MVCC) transactions REQUIRE the handler -- bounded
    # retry, MvccConflict on exhaustion. AtomicPtr (Rust rcu) FORBIDS
    # the handler today -- unbounded retry, no conflict path to handle
    # (#330 will bound this and surface AtomicConflict, but that's a
    # future task). The split only matters when ANY cell in this
    # WITH is @indirect:atomic; mixed cells trip the multi-cell
    # rejection in M3.9.
    snap_caps = node.capabilities || []
    has_atomic_ptr = is_snapshot_txn && snap_caps.any? { |c|
      next false unless c[:capability] == :SNAPSHOT
      sym = c[:var_node]&.respond_to?(:symbol) ? c[:var_node].symbol : nil
      sym && sym.sync == :atomic && sym.respond_to?(:layout) && sym.layout == :indirect
    }

    # MVCC L5 + True-Sync-Polymorphism (#328): SNAPSHOT-transaction
    # without a per-WITH conflict handler now falls back to the
    # program-level SYNC POLICY (the baked-in default is always
    # stamped when no user policy exists, so this can't fail in
    # practice). The synthesized clause is stamped on
    # node.lock_error_clause so the lowering takes the catch path
    # uniformly. The error type comes from the cell family:
    # @versioned -> MvccConflict; @indirect:atomic -> AtomicConflict
    # (#330 bounded the AtomicPtr.update loop at 256 and surfaced
    # error.AtomicConflict on exhaustion).
    if is_snapshot_txn && clause.nil?
      target_error = has_atomic_ptr ? :AtomicConflict : :MvccConflict
      synth = synthesize_clause_from_policy(target_error)
      if synth
        node.lock_error_clause = synth
        clause = synth
      else
        error!(node,
               "WITH SNAPSHOT ... AS MUTABLE has no `ON #{target_error}` " \
               "handler and the SYNC POLICY does not provide one. " \
               "Either add `ON #{target_error} ...` at this WITH, or extend " \
               "the program SYNC POLICY (a complete policy is mandatory).")
      end
    end

    # AtomicPtr M3.6 + True-Sync-Polymorphism (#330): an @indirect:atomic
    # SNAPSHOT MUTABLE block now CAN raise AtomicConflict (after
    # MAX_UPDATE_RETRIES = 256 CAS losses). An inline conflict handler
    # is permitted iff its selector is `AtomicConflict` (not
    # `MvccConflict`, which can't fire from atomic-pointer commit).
    if has_atomic_ptr && clause
      bad_selector = (clause[:selectors] || []).find { |s|
        s[:form] == :type && s[:name] == :MvccConflict
      }
      if bad_selector
        error!(node,
          "`ON MvccConflict` isn't valid on `@indirect:atomic`. " \
          "AtomicPtr.update raises `AtomicConflict` (after 256 CAS " \
          "losses), not `MvccConflict`. Use `ON AtomicConflict ...` " \
          "instead, or drop the handler to fall back to the SYNC POLICY.")
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
      error!(node, "ON / RETRY clause requires a WITH capability that can fail " \
                   "(EXCLUSIVE on @locked/@writeLocked, or read on @writeLocked). " \
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

  # AtomicPtr M3.11 [REMOVED #332]: this rule rejected bare
  # `WITH SNAPSHOT <param> AS MUTABLE x { ... }` on a polymorphic
  # `REQUIRES c: VERSIONED | ATOMIC` parameter, forcing the user to
  # use MATCH dispatch because the two families differed in their
  # ON Conflict requirement (VERSIONED required it, ATOMIC forbade
  # it). After #324 split Conflict into Mvcc/AtomicConflict, #328
  # added the SYNC POLICY chain (no inline handler required), and
  # #330 bounded AtomicPtr.update + bridged AtomicConflict, both
  # families now use identical SNAPSHOT MUTABLE syntax. The rule's
  # premise is gone, so it no longer fires.

  # AtomicPtr M3.10: reject `cfg.field = ...` (or `cfg.field += 1`,
  # etc) when `cfg` is `@indirect:atomic`. The AtomicPtr cell
  # publishes whole-T snapshots via atomic pointer swap, not per-
  # field writes -- there's no per-field cmpxchg on a struct field.
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
  def reject_bare_atomic_ptr_mutation!(field_node, assignment_node)
    root = field_node
    root = root.target while root.respond_to?(:target) && !root.is_a?(AST::Identifier)
    return unless root.is_a?(AST::Identifier)
    sym = root.respond_to?(:symbol) ? root.symbol : nil
    return unless sym
    return unless sym.sync == :atomic
    return unless sym.respond_to?(:layout) && sym.layout == :indirect

    error!(assignment_node,
      "`@indirect:atomic` requires `WITH SNAPSHOT #{root.name} AS MUTABLE x { x.#{field_name_for_msg(field_node)} = ...; }` for mutation. " \
      "Atomic pointer swap publishes a new whole-T snapshot, not a per-field write -- " \
      "the `WITH SNAPSHOT` block clones the snapshot, mutates the clone, and CAS-publishes it. " \
      "(This is different from primitive `@shared:atomic` Int64/Float64/Bool, which use direct " \
      "ops like `c += 1` because they fit in a single CAS-able machine word.)")
  end

  # Pull the leaf field name out of a GetField chain for the error
  # message ("for mutation" snippet). Returns "<field>" or "field".
  def field_name_for_msg(node)
    return node.field.to_s if node.respond_to?(:field) && node.field
    "<field>"
  end

  # AtomicPtr M3.9 + True-Sync-Polymorphism (#333): reject any
  # multi-binding WITH where one or more sync-constrained cells
  # could be `@atomic` / `@indirect:atomic` at runtime. Atomic ops
  # are per-cell; CLEAR has no portable multi-pointer atomic
  # primitive and software MCAS is out of scope, so multi-cell
  # atomic gives no atomicity ACROSS cells (readers can see states
  # nobody ever published, writers cannot commit-or-rollback).
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

    error!(node,
      "Multi-object WITH cannot admit ATOMIC: `#{var_name}` " \
      "is (or could be) `@atomic` / `@indirect:atomic`, which gives no " \
      "atomicity across cells. Either narrow the binding's REQUIRES to a " \
      "non-ATOMIC family (e.g. `LOCKED | VERSIONED`, or just `VERSIONED` " \
      "for cross-cell MVCC transactions), or refactor to single-cell " \
      "WITH blocks. Per design contract docs/agents/atomicptr.md §4 + " \
      "docs/agents/true-synchronization-polymorphism.md.")
  end

  # True-Sync-Polymorphism (#333): a capability is "sync-constrained"
  # when its WITH binding actually synchronizes against a cell at
  # runtime. BORROWED / RESTRICT / VIEW / MATERIALIZED VIEW are pure
  # borrows or observable reads -- they don't acquire a lock or pin a
  # snapshot. EXCLUSIVE / SNAPSHOT / ATOMIC and inferred capabilities
  # whose var_node has a sync axis at the symbol level all count.
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

  # True-Sync-Polymorphism (#333): does this capability's binding
  # potentially run as `:atomic` at runtime? Two paths:
  #   - concrete sync `:atomic` (covers primitive @atomic and
  #     indirect:atomic via sym.layout == :indirect, both flagged
  #     by sym.sync == :atomic);
  #   - polymorphic REQUIRES disjunction admitting :ATOMIC or
  #     :SNAPSHOTTED (which expands to {VERSIONED, ATOMIC}).
  def cap_admits_atomic?(cap)
    sym = cap[:var_node]&.respond_to?(:symbol) ? cap[:var_node].symbol : nil
    return false unless sym
    return true if sym.sync == :atomic
    fams = sym.respond_to?(:sync_families) ? sym.sync_families : nil
    return false unless fams.is_a?(Set)
    expanded = WithMatchCheck.expand_snapshotted(fams)
    expanded.include?(:ATOMIC)
  end

  # AtomicPtr M3.8 + True-Sync-Polymorphism (#324): per-arm conflict-
  # handler validation for SNAPSHOT MATCH MUTABLE blocks. The two
  # families have opposite contracts:
  #   - VERSIONED arm: REQUIRES at least one `ON MvccConflict` clause
  #     (mirrors the single-arm M5 contract; Versioned.update bounds
  #     retries and surfaces UpdateRetriesExhausted -> MvccConflict).
  #   - ATOMIC arm: FORBIDS conflict handlers (today rcu retries
  #     until success; once #330 bounds AtomicPtr.update at 256 the
  #     right handler will be `ON AtomicConflict`, not `ON
  #     MvccConflict` -- but for now no handler is permitted).
  # Read-mode SNAPSHOT MATCH (no MUTABLE) skips this entirely --
  # read paths can't fail, so neither arm needs / accepts a handler.
  def validate_snapshot_match_arms!(node)
    (node.arms || []).each do |arm|
      clauses = arm[:lock_error_clauses] || []
      case arm[:family]
      when :VERSIONED
        # True-Sync-Polymorphism (#328): VERSIONED arm without a
        # per-arm conflict handler falls back to the program SYNC
        # POLICY (always stamped, so this can't fail in practice).
        if clauses.empty?
          synth = synthesize_clause_from_policy(:MvccConflict)
          if synth
            arm[:lock_error_clauses] = [synth]
          else
            error!(node,
              "WITH SNAPSHOT ... AS MUTABLE MATCH: VERSIONED arm has no " \
              "`ON MvccConflict` handler and the SYNC POLICY does not " \
              "provide one. Either add `WHEN VERSIONED -> { ... } " \
              "ON MvccConflict ...`, or extend the program SYNC POLICY.")
          end
        end
      when :ATOMIC
        unless clauses.empty?
          error!(node,
            "WITH SNAPSHOT ... AS MUTABLE MATCH: ATOMIC arm forbids " \
            "conflict handlers (AtomicPtr.update retries until success -- " \
            "Rust `rcu` semantics; there's no conflict path to handle). " \
            "Drop the trailing handler clause from the ATOMIC arm.")
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
        error!(clause[:token] || node,
               "RETRY only targets Transient errors. Non-retryable types in selector: " \
               "#{non_transient.join(', ')}")
      end
    end

    overlap = matched & possible
    if overlap.empty?
      error!(node, "Selectors [#{matched.join(', ')}] do not match " \
                   "any error the WITH acquire can produce (#{possible.join(', ')}).")
    end

    clause[:matched_types] = overlap
    clause[:bubble_types]  = possible - overlap
  end

  # Walk statements looking for assignments where a borrowed alias escapes
  # to an outer-scope variable.
  def visit_DoBlock(node)
    node.branches.each do |branch|
      visit_stmts(branch[:body])

      full_analysis = analyze_fiber_captures(branch[:body], is_parallel: branch[:parallel])
      branch[:capture_analysis] = full_analysis

      if branch[:parallel]
        error!(node, "@local variable cannot be used in @parallel block — it requires single-scheduler affinity.") if full_analysis.has_local
        error!(node, "@multiowned (Rc) variable cannot be used in @parallel block — Rc uses a non-atomic reference count. Use @shared (Arc) for cross-scheduler sharing.") if full_analysis.has_rc
      end

      if full_analysis.has_non_escaping_capture
        error!(node, "DO block captures a WITH-scoped (BORROWED/RESTRICT) binding. " \
                     "WITH bindings are stack aliases that become invalid when the WITH block exits. " \
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

  def visit_BgStreamBlock(node)
    # Effect tracking: generators are inherently unbounded (run until exhausted or cancelled).
    record_effect(EffectTracker::LOOP_UNBOUND)

    # Body runs in a separate generator fiber. YIELD expressions push values into the stream.
    # The stream element type T is inferred from YIELD expression types.
    prev_stream_ctx  = @current_stream_context
    prev_yield_types = @stream_yield_types
    @current_stream_context = node
    @stream_yield_types = []

    visit_stmts(node.body)

    yield_types = @stream_yield_types
    @current_stream_context = prev_stream_ctx
    @stream_yield_types     = prev_yield_types

    if yield_types.empty?
      error!(node, "BG STREAM block has no YIELD statements. Use BG { } for a plain promise.")
    end

    elem_syms = yield_types.map(&:resolved).uniq
    if elem_syms.size > 1
      error!(node, "BG STREAM block yields inconsistent types: #{elem_syms.join(', ')}. All YIELD expressions must produce the same type.")
    end

    node.full_type = :"~?#{elem_syms.first}[]"

    # Detect YIELD of frame strings: when any YIELD expression is frame-allocated,
    # the MIR pass will heap-dupe it before push. NEXT callers own the duped copy.
    node.yields_frame_strings = true if stream_body_yields_frame_string?(node.body)

    # Compute captures for transpiler (same as BG blocks).
    stream_analysis = analyze_fiber_captures(node.body)
    node.capture_analysis = stream_analysis

    if stream_analysis.has_non_escaping_capture
      error!(node, "BG STREAM block captures a WITH-scoped (BORROWED/RESTRICT) binding. " \
                   "WITH bindings are stack aliases that become invalid when the WITH block exits. " \
                   "Move the BG STREAM block outside the WITH block, or use COPY to get an owned value.")
    end
  end

  # Returns true if any YieldExpr in the stream body yields a frame-allocated string.
  # Stops recursion at nested BgStreamBlock boundaries.
  def stream_body_yields_frame_string?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |stmt|
      case stmt
      when AST::YieldExpr
        bg_exit_frame_string?(stmt.expr)
      when AST::WhileLoop
        stream_body_yields_frame_string?(stmt.do_branch)
      when AST::ForRange, AST::ForEach
        stream_body_yields_frame_string?(stmt.body)
      when AST::IfStatement
        stream_body_yields_frame_string?(stmt.then_branch) ||
          stream_body_yields_frame_string?(stmt.else_branch)
      when AST::BgStreamBlock
        false  # nested stream boundary — don't descend
      else
        false
      end
    end
  end

  def visit_YieldExpr(node)
    unless @current_stream_context
      error!(node, "YIELD can only be used inside a BG STREAM { } block.")
    end
    visit(node.expr)
    node.full_type = node.expr.full_type || :Void
    @stream_yield_types << Type.new(node.full_type)
    record_effect(EffectTracker::SUSPENDS)
  end

  def visit_BgBlock(node)
    # Body runs in a separate fiber. The last expression's type determines T in ~T.
    # node.stack_size: :standard | :micro | :large | :xl | nil  (nil → STANDARD default)
    record_effect(EffectTracker::YIELD)
    outer_scope = current_scope
    locally_bound = Set.new
    prev_bg_pinned = @current_bg_pinned
    @current_bg_pinned = node.pinned

    last_type = :Void
    node.body.each do |expr|
      visit(expr)
      last_type = expr.respond_to?(:full_type) ? (expr.full_type || :Void) : :Void
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
      last_type = last_type_str[1..].to_sym
    end
    node.full_type = :"~#{last_type}"

    # Propagate returns_promoted through BG blocks: if the last expression
    # calls a function with returns_promoted, the BG block's promise carries
    # heap-promoted data that the NEXT caller must clean up.
    last_expr = node.body.last
    if has_heap_promoted_call?(last_expr)
      node.return_provenance = :heap
    elsif bg_exit_frame_string?(last_expr)
      # Last expression is a frame-allocated string. The MIR pass will heap-dup it
      # so the fiber's result outlives the frame rewind. The NEXT caller owns that
      # heap string and must free it.
      node.return_provenance = :heap
    end

    # @arena implies @pinned — thread-local arena memory can't be stolen.
    if node.arena_mode
      node.pinned = true
      if node.parallel
        error!(node, "@arena cannot be combined with @parallel — arena memory is thread-local and cannot be stolen.")
      end
    end

    # Single walk: compute captures, validate safety, detect shared state.
    # Store on node for transpiler to read (eliminates re-walking).
    full_analysis = analyze_fiber_captures(node.body, is_parallel: node.parallel)
    node.capture_analysis = full_analysis

    # Validate: @local in @parallel, @rc in @parallel
    if node.parallel
      error!(node, "@local variable cannot be used in @parallel block — it requires single-scheduler affinity.") if full_analysis.has_local
      error!(node, "@multiowned (Rc) variable cannot be used in @parallel block — Rc uses a non-atomic reference count. Use @shared (Arc) for cross-scheduler sharing.") if full_analysis.has_rc
    end

    # WITH-scoped (BORROWED/RESTRICT) bindings cannot escape into fibers.
    # The fiber may outlive the WITH block, turning the alias into a dangling pointer.
    if full_analysis.has_non_escaping_capture
      error!(node, "BG block captures a WITH-scoped (BORROWED/RESTRICT) binding. " \
                   "WITH bindings are stack aliases that become invalid when the WITH block exits. " \
                   "Move the BG block outside the WITH block, or use COPY to get an owned value.")
    end

    # Auto-pin detection
    analysis = (!node.pinned && !node.parallel && full_analysis.has_shared) ? full_analysis : nil

    # Safety: pinned scope → child BG must also be pinned if it captures outer vars.
    if @current_bg_pinned && !node.pinned && captures_outer_variables?(node.body, locally_bound)
      error!(node, "BG block inside @pinned scope captures local variables but is not @pinned. " \
                   "Thread-local memory cannot escape to a stealable fiber. " \
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

  def visit_ThenChain(node)
    # Sequential chaining: each step runs in order inside the same fiber.
    # Steps with AS bindings declare a local variable accessible to later steps.
    # The last step's type determines the ThenChain's type.
    #
    # Error propagation: if a step returns !T and has an AS binding, the
    # binding type is T (unwrapped). The error propagates to the BG result
    # via try/errdefer in the generated Zig code.
    last_type = :Void
    node.steps.each do |step|
      visit(step[:expr])
      step_type = step[:expr].respond_to?(:full_type) ? (step[:expr].full_type || :Void) : :Void

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

  def visit_NextExpr(node)
    record_effect(EffectTracker::YIELD)
    visit(node.expr)
    promise_type = Type.new(node.expr.full_type || :Void)

    unless promise_type.future?
      error!(node, "NEXT requires a future value (~T), got #{node.expr.full_type}")
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
      node.full_type = :"?#{elem_sym}"
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
      node.full_type = :"?#{elem_sym}"
    elsif promise_type.open_stream?
      # NEXT on ~?T[]: returns ?T — null signals stream exhaustion.
      # Does NOT mark as moved — stream is a resource cleaned up via deinit.
      elem_sym = promise_type.open_stream_element_type.to_sym
      node.full_type = :"?#{elem_sym}"
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

    # Propagate heap provenance through NEXT: if the fiber's exit/yield value was
    # frame-allocated and heap-duped, the NEXT caller owns that heap allocation
    # and must free it.
    if node.expr.is_a?(AST::Identifier)
      sym = node.expr.symbol
      decl_node = sym&.reg  # the declaration's AST node (BindExpr/VarDecl)
      bg_value = decl_node.respond_to?(:value) ? decl_node.value : nil
      needs_heap =
        (bg_value.is_a?(AST::BgBlock) && bg_value.return_provenance == :heap) ||
        (bg_value.is_a?(AST::BgStreamBlock) && bg_value.yields_frame_strings)
      if needs_heap
        ti = node.type_info
        ti.provenance = :heap if ti.is_a?(Type)
      end
    end
  end

  def get_root_object(node)
    curr = node
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      curr = curr.target
    end
    curr
  end

  # Collect all identifier names referenced (directly) in an AST subtree.
  # Used by the WHILE loop moved-value check to skip variables not referenced in the body.
  def collect_body_identifier_names(nodes)
    names = Set.new
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

  def handle_assign_move(node)
    return if node.value.is_a?(AST::CopyNode)

    # Non-escaping values (WITH block aliases) cannot be moved/consumed.
    # Copy types (Int64, Bool, Float64, etc.) are exempt: assignment copies the
    # value with no pointer transfer, so no lifetime hazard exists.
    if node.value.is_a?(AST::Identifier) && node.value.symbol&.non_escaping
      vti = node.value.type_info
      needs_move = begin
        vti && Type.new(vti).requires_move?
      rescue
        true
      end
      if needs_move
        error!(node, "Cannot move WITH-scoped '#{node.value.name}'. WITH bindings cannot escape their block.")
      end
    end
    if node.value.is_a?(AST::GetField) || node.value.is_a?(AST::GetIndex)
      # Container indexing of borrowed source into an owned target (HashMap
      # assignment) is an error. Plain variable declarations get borrow marking
      # via register_container_borrow! instead.
      if node.is_a?(AST::Assignment) && node.value.is_a?(AST::GetIndex)
        vti = node.value.type_info
        vti = Type.new(vti) if vti && !vti.is_a?(Type)
        is_copy = vti&.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil } rescue true
        unless is_copy
          container = find_container_source(node.value)
          if container
            source_name = root_variable_name(node.value)
            if source_name && @og[source_name]&.kind == :borrowed
              error!(node, "Cannot move borrowed value from '#{source_name}' (container index is a borrow). Use COPY for an explicit deep-copy.")
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
    return if rhs_info&.storage == :multiowned || rhs_info&.storage == :shared || rhs_info&.sync

    type_obj = Type.new(rhs_type)
    is_copy = type_obj.implicitly_copyable? { |t| lookup_type_schema(t) }
    if !is_copy && (type_obj.requires_move? || rhs_info&.resource)
      # Cannot move a borrowed value (non-TAKES parameter).
      if @og[rhs_name]&.kind == :borrowed
        error!(node, "Cannot move borrowed value '#{rhs_name}'. Parameters are implicit borrows unless TAKES.")
      end
      lhs_name = node.name.is_a?(AST::Identifier) ? node.name.name : node.name.to_s
      # Track the move site at the RHS identifier's token so
      # use-of-moved errors can suggest fixes at the consuming line.
      move_tok = node.value.respond_to?(:token) ? node.value.token : node.token
      og_move(rhs_name, lhs_name, at_token: move_tok)
      node.value.was_moved = true
    end
  end

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
    error!(node, "Variable not found") if borrowed_scope.nil?
    return if borrowed_scope.is_immutable?(root_var)

    lhs_name = node.name.is_a?(AST::Identifier) ? node.name.name : "__borrow_#{root_var}"
    err = @og.borrow(lhs_name, root_var, mutable: node.mutable)
    error!(node, "Lifetime Error: '#{root_var}' (or part of it) is already borrowed.") if err
  end

  # Returns the AST node of the argument the return value borrows from, or nil.
  def resolve_borrow_source(call_node)
    # Path 1: stdlib functions with lifetime: "self"
    matched_def = call_node.respond_to?(:matched_stdlib_def) ? call_node.matched_stdlib_def : nil
    if matched_def.is_a?(Hash) && matched_def[:lifetime]
      lifetime = matched_def[:lifetime]
      if lifetime == "self" && call_node.is_a?(AST::MethodCall)
        return call_node.object
      end
      # Named param lifetime -- find by index in args list
      args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
      arg_types = matched_def[:args]
      if arg_types.is_a?(Array)
        idx = arg_types.index { |a| a.is_a?(Hash) && a[:name] == lifetime }
        return args[idx] if idx && args[idx]
      end
      return nil
    end

    # Path 2: user-defined functions with return: { lifetime: [...] }
    func_name = call_node.name
    scope = lookup_scope_for(func_name)
    return nil unless scope

    func_type = scope.resolve_type(func_name)
    return nil unless func_type.is_a?(Hash)

    # Atomics M2.4 / M2.5: multi-binding lifetime returns the FIRST
    # source. The borrow tracking still records under one root; if a
    # multi-source RETURNS is used, the caller-side check in
    # `handle_assign_borrow` uses this single source. Multi-source
    # borrow tracking (record borrows on ALL sources, error when ANY
    # is already borrowed) is M2.6 audit-matrix work — we err on the
    # conservative side here (track only the first source) to avoid
    # spurious errors before the audit lands. Wildcard returns nil
    # (no specific source to track).
    lifetime = func_type.dig(:return, :lifetime)
    return nil if lifetime.nil?
    lifetime = [lifetime] unless lifetime.is_a?(Array)
    return nil if lifetime.empty? || lifetime == [:wildcard]
    primary = lifetime.first
    return nil if primary == :wildcard
    primary_root = primary.to_s.split(".").first

    param_index = func_type[:params]&.find_index { |p| p[:name] == primary_root }
    return nil unless param_index

    args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
    args[param_index]
  end

  def verify_unrestricted!(node)
    path = get_path_to_root(node.name)
    return if path.nil?
    root_name = path.first.to_s
    unless @og.can_write?(root_name)
      error!(node, "Lifetime Error: Cannot assign to '#{root_name}' because it is currently borrowed.")
    end
  end

  # Returns the Type of the last value-producing expression in a branch body,
  # or nil if the branch doesn't end with a usable expression.
  # Used to determine whether an IF/MATCH node can be promoted to expression mode.
  def expr_result_type(branch)
    return nil if branch.nil? || branch.empty?
    last = branch.last
    return nil unless last.respond_to?(:type_info)
    # ELSE_IF chain: the last element is a nested IfStatement — use its result type
    if last.is_a?(AST::IfStatement)
      return last.then_result_type
    end
    ti = last.type_info
    return nil unless ti
    return nil if ti.resolved == :Void || ti.resolved == :NoReturn
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
  def promote_to_expr_if!(parent_node, if_node)
    # Recursively promote ELSE_IF chains first
    if if_node.else_branch&.length == 1 && (nested = if_node.else_branch.first).is_a?(AST::IfStatement)
      promote_to_expr_if!(if_node, nested)
      else_result = nested.type_info
    else
      else_result = if_node.else_result_type
    end

    then_result = if_node.then_result_type

    unless then_result
      error!(if_node, "IF expression: THEN branch must end with a value expression")
    end
    unless else_result
      if if_node.else_branch.nil? || if_node.else_branch.empty?
        error!(if_node, "IF used as expression requires an ELSE branch")
      else
        error!(if_node, "IF expression: ELSE branch must end with a value expression")
      end
    end

    t1 = then_result.string? ? :String : then_result.resolved
    t2 = else_result.string? ? :String : else_result.resolved
    unless t1 == t2 || t1 == :Any || t2 == :Any
      error!(if_node, "IF expression branches have incompatible types: THEN returns #{t1}, ELSE returns #{t2}")
    end

    result_type = (t1 == :Any) ? else_result : then_result
    unless result_type.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
      error!(if_node, "IF expression result type '#{result_type.resolved}' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-IF with RETURN for heap-allocated values.")
    end

    if_node.expr_mode = true
    if_node.full_type = (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type
  end

  # Promotes an AST::MatchStatement that is used in expression position.
  def promote_to_expr_match!(parent_node, match_node)
    case_types = match_node.case_result_types || []
    default_type = match_node.default_result_type

    # All case bodies must produce values
    case_types.each_with_index do |t, i|
      unless t
        error!(match_node, "MATCH expression: every branch must end with a value expression")
      end
    end

    # PARTIAL MATCH expressions must have a DEFAULT branch -- without
    # one a non-exhaustive match leaves the result undefined for missing
    # variants. Plain MATCH is exhaustive by construction (annotator
    # already verified all variants are covered) so the implicit return
    # value is always defined.
    if !default_type && !match_node.exhaustive
      error!(match_node,
        "PARTIAL MATCH used in expression position requires a DEFAULT " \
        "branch. Either add a DEFAULT case, or change to `MATCH` " \
        "(which forces every variant to have an exact case).")
    end

    all_types = case_types.compact
    all_types << default_type if default_type

    if all_types.empty?
      error!(match_node, "MATCH expression must have at least one case")
    end

    resolved_types = all_types.map { |t| t.string? ? :String : t.resolved }.uniq.reject { |t| t == :Any }
    if resolved_types.size > 1
      error!(match_node, "MATCH expression branches have incompatible types: #{resolved_types.join(', ')}")
    end

    result_type = all_types.first
    unless result_type.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
      error!(match_node, "MATCH expression result type '#{result_type.resolved}' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-MATCH for heap-allocated values.")
    end

    match_node.expr_mode = true
    match_node.full_type = (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type
  end

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
          error!(node, "Promise '#{name}' must be consumed before it goes out of scope. Use NEXT, COLLECT, or RETURN it.")
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

        # TODO: not yet auto-fixable — `_` collides with the Zig discard
        # keyword and deletion loses any RHS side effects. Kept as a plain
        # stderr warning until we add an :interactive "delete line" fix.
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

        emit_mutable_unused_finding!(info.reg, name)
      end
    end
  end

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
          error!(node, "Promise '#{name}' must be consumed before it goes out of scope. Use NEXT, COLLECT, or RETURN it.")
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
  def mark_chain_needs_mut_ref!(node)
    curr = node
    while curr
      curr.needs_mut_ref = true if curr.is_a?(AST::GetIndex)
      curr = curr.respond_to?(:target) ? curr.target : nil
    end
  end

  def get_path_to_root(node)
    path = []
    curr = node
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      path.unshift(curr.is_a?(AST::GetField) ? curr.field.to_sym : :*)
      curr = curr.target
    end
    return nil unless curr.is_a?(AST::Identifier)
    path.unshift(curr.name.to_sym)
    path
  end

  # Atomics M2.6: an `a.field = bg` / `arr[i] = bg` / plain `x = bg`
  # is a cross-scope escape when the assigned binding's tied lifetime
  # has a source declared in a DEEPER scope than the destination.
  # Reads `value.symbol.lifetime_sources` and compares each source's
  # scope_depth to the destination's scope_depth. Source's depth must
  # be <= dest's depth (i.e., the source is at the same scope or an
  # ancestor of the destination -- so the destination's scope ends
  # first). Fires only for tied-lifetime values; nil-lifetime
  # bindings flow through unchanged.
  def verify_tied_assignment!(assign_node)
    val = assign_node.value
    return unless val.is_a?(AST::Identifier)
    sym = val.respond_to?(:symbol) ? val.symbol : nil
    return unless sym
    sources = sym.lifetime_sources
    return if sources.empty?
    return if sources == [sym]   # :current_scope is its own check path

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
      # Atomics M2.8: when the source binding is `@shared:atomic`,
      # produce a fixable finding so `clear fix` can suggest the
      # `@shared:atomic` -> `@shared:locked` migration. Falls back
      # to plain error! for non-atomic tied-lifetime sources (the
      # @shared:locked migration doesn't apply to those).
      fix = build_atomic_escape_migration_fix(source, source_name)
      if fix
        fixable!(assign_node, message: msg, category: :escape,
                 level: :error, fixes: [fix], raise_in_collector: true)
      else
        error!(assign_node, msg)
      end
    end
  end

  # Atomics M2.6: a `RETURN <val>` of a tied-lifetime binding is
  # legal only when the enclosing function declares
  # `RETURNS <source>:T` for at least one of the val's sources. The
  # function's `return_lifetime` array is matched by NAME against
  # the source's binding name; wildcard `RETURNS *:T` accepts.
  def verify_tied_return!(return_node)
    val = return_node.value
    return unless val.is_a?(AST::Identifier)
    sym = val.respond_to?(:symbol) ? val.symbol : nil
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

    # Atomics M2.8: if at least one source is `@shared:atomic`,
    # produce a fixable finding suggesting the migration to
    # `@shared:locked`. Picks the first atomic source whose
    # decl-line text we can locate; the rest fall through to the
    # plain error path.
    atomic_fix = nil
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
      error!(return_node, msg)
    end
  end

  # Look up the binding name of a SymbolEntry by scanning scope.locals.
  # Returns the String name or nil if not found.
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
        return p[:name].to_s if p[:symbol].equal?(sym)
      end
    end
    nil
  end

  # Atomics M2.6: lifetime escape check. The val_node has a tied
  # lifetime (sources non-empty). The destination's `dest_depth` is
  # the scope depth where the value will live. The check: every
  # source's `scope_depth` must be >= dest_depth (source is anchored
  # in dest's scope or deeper). Returns nil when the escape is safe;
  # an error message string when it isn't.
  #
  # Conservative shortcut: when val_node has no symbol or no tied
  # lifetime, returns nil immediately. The check fires only for
  # actually-tied bindings (atomic-captured BG handles today,
  # multi-source returns and similar in M2.9+).
  def lifetime_violation_for_store(val_node, dest_depth)
    return nil unless val_node.respond_to?(:symbol)
    sym = val_node.symbol
    return nil unless sym
    sources = sym.lifetime_sources
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

  # Convenience: the escape destination's effective scope depth.
  # For a struct-field assign `a.field = v`, depth = a's binding scope.
  # For a method receiver (`list.append(v)`), depth = list's binding scope.
  # For a free local in current scope, depth = current scope.
  def dest_scope_depth_for_target(target_node)
    if target_node.is_a?(AST::Identifier)
      sym = target_node.respond_to?(:symbol) ? target_node.symbol : nil
      sym ||= lookup_scope_for(target_node.name)&.locals&.[](target_node.name)
      return sym&.scope_depth
    end
    if target_node.is_a?(AST::GetField) || target_node.is_a?(AST::GetIndex)
      return dest_scope_depth_for_target(target_node.target)
    end
    nil
  end

  # Atomics M2.3: stamp the lifetime of a BG / BG STREAM handle
  # binding from its captures. The handle's lifetime is the
  # intersection of every captured @shared:atomic / @locked /
  # @writeLocked / @multiowned binding's lifetime. The escape checker
  # (M2.5 / M2.6) reads `symbol.lifetime_sources` at every potential
  # escape site (RETURN, struct-field assign, list/queue append, BG
  # capture) and rejects when the destination scope outlives any
  # source.
  #
  # Skipped sources (no lifetime contribution):
  #   - @shared (Arc): refcounted; the inner data lives as long as
  #     any reference exists, so the BG handle isn't bounded by the
  #     declaring scope of the original Arc binding.
  #   - @local: BG is auto-pinned, so the BG and the @local binding
  #     run on the same scheduler. The capture is by-pointer; the
  #     captured pointer's validity IS bounded by the @local
  #     binding's scope, so we DO include it. (M2.6 audit may revisit
  #     when @local + non-pinned spawn becomes a thing.)
  #   - Captures whose binding has no SymbolEntry on capture_symbols
  #     (e.g. observable view aliases); those are already errored at
  #     visit_BgBlock via has_non_escaping_capture.
  def stamp_bg_handle_lifetime!(decl_node)
    bg = decl_node.value
    return unless bg.respond_to?(:capture_analysis)
    analysis = bg.capture_analysis
    return unless analysis && analysis.respond_to?(:capture_symbols)
    sources = bg_lifetime_sources(analysis)
    return if sources.empty?
    sym = decl_node.symbol
    return unless sym
    sym.lifetime = SymbolEntry.tied_lifetime(sources)
  end

  # Walk the capture-analysis SymbolEntries and pick the ones whose
  # storage / sync makes them lifetime-bounded sources for the BG
  # handle. See stamp_bg_handle_lifetime! for the criteria.
  def bg_lifetime_sources(analysis)
    sources = []
    (analysis.capture_symbols || {}).each_value do |info|
      next unless info
      bound = false
      bound = true if info.sync == :atomic
      bound = true if info.sync == :locked || info.sync == :write_locked
      bound = true if info.storage == :multiowned
      bound = true if info.sync == :local
      # @shared (Arc) without atomic/locked/versioned: refcounted, no
      # lifetime constraint on the outer binding.
      bound = false if info.storage == :shared && !info.sync
      # AtomicPtr M3.12: @indirect:atomic is Arc-managed under the
      # hood (the AtomicPtr cell owns an Arc(T) payload; M3.5 auto-
      # promotes ownership to :shared). Loaded snapshots have refcount
      # lifetime; the cell itself can flow into struct fields, BG
      # handles, RETURN values without trip-wiring the M2.6 escape
      # audit. Exempt parallel to the @shared-without-sync rule
      # above. Primitive @shared:atomic stays bounded -- bare
      # *Atomic(T) is scope-bounded by M2.6 design.
      bound = false if info.sync == :atomic && info.respond_to?(:layout) && info.layout == :indirect
      sources << info if bound
    end
    sources
  end

  # Atomics M2.4 / M2.5: produce the list of dotted-path lifetime
  # roots (`["r.foo.bar"]` for `RETURNS r.foo.bar:T`,
  # `["a", "b"]` for `RETURNS (a b):T`). Wildcard / nil returns []
  # because there is no source-restricted path the return value must
  # match — wildcard accepts anything (with a warning at the
  # declaration), nil means the function isn't declared as returning
  # a borrow.
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
  def get_lifetime_path(func_node)
    paths = get_lifetime_paths(func_node)
    return nil if paths.size != 1 || paths.first == :wildcard
    paths.first
  end

  # Walk through GetField/GetIndex chains to find the root Identifier name.
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

  # Known IO builtins that don't appear in @fn_nodes (runtime-level).
  IO_BUILTINS = %w[tcpRead tcpWrite accept connect readFile writeFile readLine readLinePrompt
                   listDir listAll fileSize socketRead socketWrite socketClose].to_set.freeze

  def validate_strict_io!(test_that, stubbed_fns)
    calls = scan_for_calls(test_that.body).first
    visited = Set.new
    queue = calls.to_a.dup

    until queue.empty?
      name = queue.shift
      next if visited.include?(name)
      visited << name
      next if stubbed_fns.include?(name)

      # Check if it's a known IO builtin
      if IO_BUILTINS.include?(name)
        error!(test_that, "Strict test mode: '#{name}' is an IO function that must be " \
                          "stubbed. Add STUB #{name} RETURNS <value>; to the WHEN block.")
        next
      end

      # Check if it's a user function with BLOCKING/EXTERN effects
      fn = @fn_nodes[name]
      if fn&.effects
        has_io = fn.effects.include?(:BLOCKING) || fn.effects.include?(:EXTERN)
        if has_io
          error!(test_that, "Strict test mode: '#{name}' has IO effects (#{fn.effects.to_a.join(', ')}). " \
                            "Either stub '#{name}' or stub the IO functions it calls.")
        end
      end

      # Continue down the call chain
      (@call_graph[name] || []).each { |c| queue << c }
    end
  end

  # ── Tail Call Validation ─────────────────────────────────────────

  # Verify that @reentrant:tailCall functions have the self-recursive call
  # in tail position: the RETURN expression must be a direct call to self
  # with no wrapping operations (no +, -, etc.).
  # Thunk Phase 3: every recursive self-call inside a function declared
  # `EFFECTS REENTRANT:TAIL_CALL` (or legacy `@reentrant:tailCall`) MUST
  # be the direct value of a RETURN node. Any other position -- statement,
  # nested expression inside a RETURN, body of a WHILE/FOR loop, etc. --
  # is a hard error: the codegen lowering relies on the call being a
  # self-loop, and a non-tail call would consume real stack on every
  # invocation.
  #
  # Approach: walk the body recursively, collecting every self-call
  # AST::FuncCall, then collecting every RETURN whose value IS a self-
  # call (those are the "blessed" tail calls). Error on each self-call
  # that isn't blessed. Recurses through IF / WHILE / FOR / WITH bodies.
  def validate_tail_call!(fn_node)
    fn_name = fn_node.name
    all_self_calls = collect_self_calls(fn_node.body, fn_name)

    blessed = collect_returns(fn_node.body).filter_map { |r|
      r.value if r.value.is_a?(AST::FuncCall) && r.value.name == fn_name
    }
    blessed_ids = blessed.map(&:object_id).to_set

    if blessed.empty?
      error!(fn_node, "EFFECTS REENTRANT:TAIL_CALL on '#{fn_name}' requires at least one " \
                       "RETURN that directly calls '#{fn_name}' in tail position " \
                       "(e.g., RETURN #{fn_name}(...)). The recursive call cannot be " \
                       "wrapped in an expression.")
    end

    all_self_calls.each do |call|
      next if blessed_ids.include?(call.object_id)
      error!(call, "EFFECTS REENTRANT:TAIL_CALL: '#{fn_name}' is called in non-tail position. " \
                    "All recursive self-calls must be the ENTIRE return expression (e.g., " \
                    "RETURN #{fn_name}(...)). Non-tail recursion would consume the fiber " \
                    "stack on every invocation. If recursion is genuinely non-tail, declare " \
                    "':THUNK' instead -- it handles arbitrary recursion via a heap state-struct.")
    end
  end

  # Recursively walk an AST subtree collecting every AST::FuncCall whose
  # name matches `fn_name`. Args are also visited (so nested self-calls
  # inside outer-call arguments are found and flagged).
  def collect_self_calls(node, fn_name, out = [])
    return out if node.nil?
    case node
    when Array
      node.each { |n| collect_self_calls(n, fn_name, out) }
    when AST::FuncCall
      out << node if node.name == fn_name
      (node.args || []).each { |a| collect_self_calls(a, fn_name, out) }
    else
      node.each_pair { |_, v| collect_self_calls(v, fn_name, out) } if node.respond_to?(:each_pair)
    end
    out
  end

  # Recursively walk an AST subtree collecting every AST::ReturnNode.
  def collect_returns(node, out = [])
    return out if node.nil?
    case node
    when Array
      node.each { |n| collect_returns(n, out) }
    when AST::ReturnNode
      out << node
      collect_returns(node.value, out) if node.respond_to?(:value)
    else
      node.each_pair { |_, v| collect_returns(v, out) } if node.respond_to?(:each_pair)
    end
    out
  end

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

  def assign_fiber_stack_tiers!(program_node)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::BgBlock
        calls = scan_for_calls(n.body).first
        raw = max_tier_for_calls(calls)
        n.computed_stack_tier = (raw == :unbounded) ? :service : raw
        validate_fiber_stack!(n, calls, n.stack_size, n.can_smash)
        n.body.each { |s| traverse.call(s) }
      when AST::BgStreamBlock
        calls = scan_for_calls(n.body).first
        raw = max_tier_for_calls(calls)
        n.computed_stack_tier = (raw == :unbounded) ? :service : raw
        validate_fiber_stack!(n, calls, n.stack_size, false)
        n.body.each { |s| traverse.call(s) }
      when AST::DoBlock
        n.branches.each do |branch|
          calls = scan_for_calls(branch[:body]).first
          raw = max_tier_for_calls(calls)
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

  # Validate stack sizing for a fiber spawn.
  # Phase 4g: plain `EFFECTS REENTRANT` callees REQUIRE explicit
  # `@service` on the spawn site. The compiler no longer auto-
  # infers OS-thread stacks -- the user pays the cost knowingly,
  # or chooses a bounded variant (`:THUNK` / `:TAIL_CALL` /
  # `:NOT_LOGICAL` / `:MAX_DEPTH(N)`) on the callee.
  def validate_fiber_stack!(node, call_names, user_size, can_smash)
    if can_smash
      error!(node,
        "`@canSmash` on BG/DO blocks is recognized but not yet supported by the " \
        "compiler. The runtime has stack-hysteresis (page-guarded soft overflow " \
        "detection) to protect fiber stacks, but the compiler does not yet wire " \
        "that feature on. Use `@service` instead (spawns on a dedicated OS thread " \
        "with a 2 MB pre-allocated stack); `@canSmash` is expected to be supported " \
        "in v0.3.")
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
        error!(node, "Stack safety: this fiber transitively calls '#{mutual_md_callee}' " \
                     "which is `:MAX_DEPTH(N)` AND mutually recursive. Mutual depth-bounds " \
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
      error!(node, "Stack safety: @#{user_size} (#{EffectTracker::STACK_TIER_BUDGET[user_size]} bytes) " \
                   "is too small for this fiber. Call-graph analysis requires at least @#{computed}. " \
                   "Use @#{computed} (or @service for OS-thread). " \
                   "(`@canSmash` is reserved for v0.3 -- runtime stack-hysteresis is implemented " \
                   "but not yet wired through the compiler.)")
    end
  end

  # Walk the call graph from the BG body and return the name of the
  # first callee whose `reentrance_kind == :reentrant` (plain). Other
  # variants (:thunk, :tail_call, :not_logical, :max_depth) are
  # bounded and don't trigger the @service-required rule.
  def find_plain_reentrant_callee(call_names)
    visited = Set.new
    queue = call_names.to_a.dup
    until queue.empty?
      name = queue.shift
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
  def find_mutual_max_depth_callee(call_names)
    visited = Set.new
    queue = call_names.to_a.dup
    until queue.empty?
      name = queue.shift
      next if visited.include?(name)
      visited << name
      fn = @fn_nodes[name]
      return name if fn && fn.reentrance_kind == :reentrant_max_depth && mutually_recursive_in_call_graph?(name)
      (@call_graph[name] || []).each { |c| queue << c }
    end
    nil
  end

  # Phase 4g: emit the @service-required diagnostic as a fixable
  # finding. Two interactive fixes:
  #   1. Insert `@service ->` right after `{` (no-prefix case)
  #   2. Replace the existing tier sigil with `@service`
  # When neither span is locatable (e.g. DO branches), fall back
  # to a plain error! with the message text.
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

    return error!(node, msg) if fixes.empty?

    fixable!(node, message: msg, category: :reentrance, level: :error,
             fixes: fixes, raise_in_collector: false)
  end

  # Find the first :unbounded callee in the call chain (for error messages).
  def find_unbounded_callee(call_names)
    visited = Set.new
    queue = call_names.to_a.dup
    until queue.empty?
      name = queue.shift
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
  def set_cleanup_alloc!(node)
    ti = node.type_info
    return unless ti

    # Check if value comes from a stdlib function with explicit metadata
    val = node.respond_to?(:value) ? node.value : nil
    if val && (val.is_a?(AST::FuncCall) || val.is_a?(AST::MethodCall))
      matched_def = val.respond_to?(:matched_stdlib_def) ? val.matched_stdlib_def : nil
      if matched_def.is_a?(Hash)
        # Borrow returns (lifetime:) need no cleanup -- the caller owns the data
        if matched_def[:lifetime]
          ti.provenance = :borrow
          return
        end
        ret_alloc = matched_def[:return_alloc]
        # For allocating methods without explicit return_alloc, the method's
        # alloc IS the return alloc (e.g. map.values() on sharded maps).
        ret_alloc ||= matched_def[:alloc] if matched_def[:allocates]
        if ret_alloc
          ti.provenance ||= ret_alloc if [:heap, :frame].include?(ret_alloc)
          return
        end
      end
    end

    alloc = ti.cleanup_allocator(->(name) { lookup_type_schema(name) })
    # Propagate provenance: prefer value's provenance, then computed alloc.
    val_ti = val&.type_info
    val_ti = val_ti.is_a?(Type) ? val_ti : nil
    ti.provenance ||= val_ti&.provenance || alloc
  end

  def og_declare(name, node, type_info)
    entry = current_scope.locals[name] rescue nil
    kind = classify_og_kind(type_info, sync: entry&.sync)
    ti = type_info.is_a?(Type) ? type_info : (type_info ? Type.new(type_info) : nil)
    @og.declare(name, kind: kind, type_info: ti,
                scope_depth: @og_scope_depth, line: node&.respond_to?(:line) ? node.line : 0)
  end

  def og_move(from, to, at_token: nil, action: :move) = @og.transfer(from, to, at_token: at_token, action: action)
  def og_set_moved(name, at_token: nil, action: :move) = @og.mark_moved(name, at_token: at_token, action: action)

  def share_consumes_source?(node)
    return false if node.is_a?(AST::CopyNode)

    ti = node.type_info
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    return false if ti&.shared?

    true
  end

  # Mark an identifier as moved if its type is non-Copy.
  # Skips generic type params (can't determine copyability at annotation time).
  def move_if_not_copyable!(node)
    return unless node.is_a?(AST::Identifier)
    vt = node.type_info
    vt = Type.new(vt) if vt && !vt.is_a?(Type)
    return if vt.nil?
    return if current_fn_ctx&.type_params&.include?(vt.resolved)
    return if vt.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
    og_set_moved(node.name, at_token: node.token, action: :move)
    node.was_moved = true
  end

  # Reject storing a borrowed value into an owned container (struct, union, TAKES param).
  # Borrows can't outlive the scope they reference. Use COPY for owned data.
  def reject_borrowed_value!(val_node, container_desc)
    borrowed_name = nil
    if val_node.is_a?(AST::GetIndex)
      borrowed_name = "#{root_variable_name(val_node)}[index]"
    elsif val_node.is_a?(AST::Identifier) && @og&.[](val_node.name)&.kind == :borrowed
      borrowed_name = val_node.name
    end
    return unless borrowed_name
    vti = val_node.type_info
    return if vti&.primitive?
    return if vti&.generic_instance?
    # Skip generic type parameters - can't determine borrowability at annotation time.
    return if current_fn_ctx&.type_params&.include?(vti&.resolved)
    has_pointer = vti&.array? || vti&.string? || vti&.collection? || vti&.map?
    return if !has_pointer && !vti&.struct?
    error!(val_node, "Cannot store borrowed value '#{borrowed_name}' into #{container_desc}. Use COPY for an explicit deep-copy.")
  end
  def og_set_live(name)  = (@og[name]&.state = :live)
  def og_drop(name)      = @og.drop(name)
  def og_push_scope      = (@og_scope_depth += 1)
  def og_pop_scope       = (@og_scope_depth -= 1)

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
