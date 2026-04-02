require_relative "./source_error"
require_relative "./scope"
require_relative "./parser"
require_relative "./std_lib"
require_relative "./function_context"
require_relative "./function_analysis"
require_relative "./pipe_analysis"
require_relative "./ownership_graph"
require_relative "./generic_analysis"
require_relative "./capabilities"
require_relative "./effects"
require_relative "./alloc"
require_relative "./method_analysis"
require_relative "./union"

# Handle Type inference, and semantic validation
class SemanticAnnotator
  include ErrorHelper
  include FunctionAnalysis
  include PipeAnalysis
  include ScopeHelper
  include TypeHelper
  include GenericAnalysis
  include EffectTracker
  include CapabilityHelper
  include CapabilityAudit
  include AllocHelper
  include MethodAnalysis
  include UnionAnalysis

  attr_reader :scope_stack

  def current_fn_ctx
    @function_context_stack.last
  end

  def initialize(importer: nil, compiler: nil, source_dir: nil, strict_test: false)
    @importer   = importer || compiler
    @source_dir = source_dir ? File.expand_path(source_dir) : Dir.pwd
    @strict_test = strict_test
    # We start with a global scope
    @scope_stack = [Scope.new]
    @function_context_stack = [] # Stack of expected return types
    @loop_depth = 0 # Track if we are inside a loop
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
    # @pinned escape safety: true when inside a @pinned BG block.
    @current_bg_pinned = false
    # Ownership graph: shadow tracker that runs in parallel with the scope-based system.
    @og = OwnershipGraph.new
    @og_scope_depth = 0
    effects_init!
    capability_audit_init!
    setup_builtins
  end

  def annotate!(node)
    visit(node)
    finalize_capability_audit!
  end

private

  def setup_builtins
    STD_LIB.each do |name, config|
      current_scope.declare(name, nil, :Intrinsic, false, false, nil, :stack)
    end

    # Setup Globals
    current_scope.declare("argv", nil, Type::STRING_TYPE, false, false, nil, :heap)

    # Built-in Range type: fields accessible via dot access
    current_scope.declare_type(:Range, {"start" => :Float64, "end" => :Float64})

    # Built-in File resource type
    current_scope.declare_type(:File, {
      kind: :resource,
      close_zig: "{0}.close()",
      static_methods: {
        "open"   => { args: [:String], return: :File, zig: "try CheatLib.fileOpen({0})", can_fail: true },
        "create" => { args: [:String], return: :File, zig: "try CheatLib.fileCreate({0})", can_fail: true }
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

    # PASS 5: Compute needs_rt and can_fail for every function via call-graph fixed-point.
    compute_needs_rt!
    compute_can_fail!

    # PASS 5b: Functions referenced as fn-type values must match the fn-pointer calling
    # convention (*Runtime, params) !return. Mark them needs_rt=true so their signatures
    # are compatible with the fn-type Zig type emitted by type.rb#zig_type.
    mark_fn_value_references!(node)

    # PASS 6: Compute effect sets for every function via call-graph fixed-point.
    compute_effects!

    # PASS 7: Compute stack tier recommendations per function.
    compute_stack_tiers!

    # PASS 8: Auto-size fiber spawns (BG/DO blocks) from call-graph analysis.
    assign_fiber_stack_tiers!(node)

    # PASS 9: Ownership analysis — build complete ownership picture in the graph.
    # Runs after all types are resolved. Determines which variables need cleanup,
    # which alias shared backing data, and what allocator to use.
    compute_ownership!(node)

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
      next unless sig.is_a?(Hash) && sig.key?(:params)

      # For package imports: skip functions that were themselves imported from
      # another module (they have a pre-existing module_alias). Those functions
      # live in their own package's Zig module and must be accessed through it.
      # For local file imports (inline struct): re-exporting is fine.
      next if node.kind == :package && sig[:module_alias]

      vis = sig[:visibility] || :package
      importable = (vis == :pub) || (vis == :package && same_dir)
      next unless importable

      # Tag the signature with the namespace so the transpiler can qualify calls.
      imported_sig = sig.merge(module_alias: node.namespace)
      current_scope.declare(name, nil, imported_sig, false, false, nil, :static)
    end

    # Import type definitions (structs) — pub and package types from same dir.
    mod.global_scope.types.each do |type_name, type_entry|
      current_scope.declare_type(type_name, type_entry[:schema])
    end
  end

  # EXTERN FN name(params) RETURNS type FROM "module"
  # Registers a native Zig/C function in the current scope.
  # At call sites, no rt is injected and no try is emitted.
  def visit_ExternFnDecl(node)
    signature = {
      params: node.params.map { |p| {
        name: p[:name],
        type: p[:type],
        required: p[:default].nil?,
        mutable: p[:mutable] || false,
        comptime: p[:comptime] || false
      }},
      return:     { type: node.return_type || :Any, lifetime: nil },
      visibility: :pub,
      extern:     true,
      module_alias: node.from_module,
      extern_effects: node.effects || {},
      fn_type_params: node.fn_type_params || [],
      type_params: (node.fn_type_params || []).any? ? (node.fn_type_params || []) : nil,
      owner_type: node.owner_type,
      owner_type_params: node.owner_type_params || []
    }

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
      # Generate the close pattern: module-level function call with pointer to self.
      # Dotted paths: "std.json" → "std_json" (sanitized alias)
      mod_alias = node.from_module.gsub(".", "_")
      schema[:close_zig] = "#{mod_alias}.#{node.close_method}(&{0})"
    end

    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  def pre_register_function(node)
    signature = {
      params: node.params.map { |p| {
        name: p[:name],
        type: p[:type],
        required: p[:default].nil?,
        mutable: p[:mutable]
      }},
      return: {
        type: (node.return_type || :Any),
        lifetime: get_lifetime_path(node)
      },
      visibility: node.visibility,
      reentrant: node.reentrant == :reentrant
    }

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
    declared_return = node.return_type || :Any
    lifetime_path = get_lifetime_path(node)
    fn_type_params = (node.type_params || []).map(&:to_sym)
    @function_context_stack.push(FunctionContext.new(
      name: node.name, return_type: declared_return,
      lifetime: lifetime_path, type_params: fn_type_params
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
    node.params.each { |p| validate_type_annotation!(node, p[:type]) if p[:type].is_a?(Type) }
    validate_type_annotation!(node, node.return_type) if node.return_type.is_a?(Type)

    # 3. Pre-declaration (so the function can be recursive)
    signature = {
      params: node.params.map { |p| {
        name: p[:name], type: p[:type], required: p[:default].nil?, mutable: p[:mutable], takes: p[:takes]
      }},
      return: { type: declared_return, lifetime: lifetime_path },
      visibility: node.visibility,
      type_params: fn_type_params.any? ? fn_type_params : nil,
      reentrant: node.reentrant == :reentrant
    }
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
        error!(node, "Reentrancy Error: '#{node.name}' directly calls itself. " \
                     "Use @reentrant (not @nonReentrant) for directly recursive functions.")
      when nil
        error!(node, "Reentrancy Error: '#{node.name}' calls itself recursively. " \
                     "Add @reentrant to the function signature to allow this.")
      end

      # Tail call validation: if @reentrant:tailCall, verify the self-call is in tail position.
      if node.tail_call
        validate_tail_call!(node)
      end
    elsif node.tail_call
      error!(node, "@reentrant:tailCall on '#{node.name}' but the function is not recursive. " \
                   "Remove :tailCall - it only applies to self-recursive functions.")
    end

    # Note: calling through a fn-type variable (parameter or local lambda) does NOT
    # require @reentrant — the caller controls what is passed and self-recursion is
    # the caller's explicit choice.  Only the call-graph cycle post-pass (below) fires
    # errors for implicit mutual/direct recursion.

    # 5. Finalize Signature
    if (is_implicit_return || declared_return == :Any)
      node.return_type = final_return_type
      signature[:return][:type] = final_return_type
    end

    signature[:return_strategy] = get_return_strategy(signature[:return][:type])
    node.full_type = signature
    ctx = current_fn_ctx
    node.uses_frame = (ctx.frame_count > 0)
    node.uses_heap  = (ctx.heap_count > 0)
    node.uses_alloc = (ctx.alloc_count > 0)
    node.stack_vars_bytes = ctx.stack_vars_bytes
    # Seed for compute_can_fail! post-pass: direct failure sources.
    ret_type_obj = signature.is_a?(Hash) ? signature[:return]&.dig(:type) : nil
    heap_ret     = ret_type_obj.is_a?(Type) && (ret_type_obj.heap? || ret_type_obj.dynamic?)
    @fn_raises_directly[node.name] = node.uses_frame || node.uses_heap || node.uses_alloc || heap_ret ||
      (@fn_has_fnptr[node.name] == true) ||
      (node.reentrant == :non_reentrant) ||
      scan_for_raises(node.body)

    # Visit CATCH clause bodies with __error and snapshot in scope.
    if node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
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
          clause_body.each { |stmt| visit(stmt) }
        end
      end
    end

    @function_context_stack.pop
  end

  # Collect input types from pipeline s> steps that can fail.
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

  def visit_StructDef(node)
    # Validate generic type parameters (duplicate / builtin-shadow)
    validate_type_param_list!(node, node.type_params, "struct") if node.type_params&.any?

    # Register the Type Name with its field schema.
    schema = node.fields.transform_values { |f| f[:type] }

    # For generic structs, record the type parameter names so field-type
    # lookups don't reject them as unknown types.
    schema[:type_params] = node.type_params.map(&:to_sym) if node.type_params&.any?

    current_scope.declare_type(node.name.to_sym, schema)
    node.full_type = :Void
  end

  def visit_EnumDef(node)
    schema = { kind: :enum, variants: node.variants.to_set }
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
    end

    schema = { kind: :union, variants: node.variants }
    schema[:type_params] = node.type_params.map(&:to_sym) if node.type_params&.any?
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
    og_snapshot = og_fork
    og_branch_snapshots = []
    all_drops = []

    branches.each do |branch_logic|
      # Restore graph to pre-branch state before analyzing each branch
      @og.restore_from(og_snapshot) if @og && og_snapshot
      with_new_scope(current_scope) do
        og_push_scope
        all_drops << branch_logic.call
        og_branch_snapshots << (@og&.fork)
        og_pop_scope
      end
    end

    if merge_to_parent
      # Restore to base, then merge all branch results
      @og.restore_from(og_snapshot) if @og && og_snapshot
      og_branch_snapshots.each { |snap| og_merge(snap) }
    else
      # Restore the initial state (e.g. for WHILE loops)
      @og.restore_from(og_snapshot) if @og && og_snapshot
    end

    all_drops
  end

  def visit_IfStatement(node)
    visit(node.condition)

    branch_logic = [
      proc {
        node.then_branch.each { |stmt| visit(stmt) }
        finalize_scope(node, branch: :then)
        node.then_drops
      },
      proc {
        node.else_branch.each { |stmt| visit(stmt) }
        finalize_scope(node, branch: :else)
        node.else_drops
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
          og_declare(f[:name], nil, field_type, :stack)
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
                  og_declare(c[:binding], nil, Type.new(synthetic_type), :stack)
                  classify_ownership!(current_scope.locals[c[:binding]])
                else
                  payload_type = union_subst.any? ? apply_type_subst(raw_payload, union_subst) : Type.new(raw_payload)
                  current_scope.declare(c[:binding], nil, payload_type, false, false, nil, :stack)
                  og_declare(c[:binding], nil, payload_type, :stack)
                  classify_ownership!(current_scope.locals[c[:binding]])
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
                  og_declare(f[:name], nil, field_type, :stack)
                end
              end
            end
          end
        end
        c[:body].each { |s| visit(s) }
        collect_scope_drops(node: node)
      }
    end

    if node.default_case
      branch_logic << proc {
        node.default_case.each { |s| visit(s) }
        collect_scope_drops(node: node)
      }
    end

    all_drops = analyze_control_flow_branches(branch_logic)

    if node.default_case
      node.default_drops = all_drops.pop
    end
    node.case_drops = all_drops

    # Exhaustiveness check — only enforced for MATCH IFF.
    if node.exhaustive
      # MATCH IFF requires an enum or union subject.
      unless is_enum || is_union
        type_label = expr_t.resolved
        error!(node, "MATCH IFF requires an enum or union type, got '#{type_label}'.")
      end

      # MATCH IFF forbids DEFAULT (defeats exhaustiveness).
      if node.default_case
        error!(node, "MATCH IFF cannot have a DEFAULT branch — every variant must be handled explicitly.")
      end

      # MATCH IFF forbids WHEN guards (arbitrary conditions break static exhaustiveness).
      if node.cases.any? { |c| c[:kind] == :when }
        error!(node, "MATCH IFF cannot contain WHEN guards — every variant must be handled by an exact case.")
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
        error!(node, "MATCH IFF on #{type_label2} '#{type_name}' is non-exhaustive: missing variants: #{missing.sort.join(', ')}")
      end
    end

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

    # 2. Capture outer-scope variable names before visiting the body.
    outer_vars = @scope_stack.flat_map { |s| s.locals.keys }.to_set

    # 3. Analyze body in new scope with loop variable declared as immutable Int64
    if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end
    analyze_control_flow_branches([
      proc {
        current_scope.declare(node.var_name, nil, :Int64, false, false, nil, :stack)
        node.symbol = current_scope.locals[node.var_name]
        classify_ownership!(node.symbol)
        node.body.each { |stmt| visit(stmt) }
        finalize_scope(node)
        node.deferred_drops
      }
    ], merge_to_parent: false)
    if current_fn_ctx then current_fn_ctx.loop_depth -= 1 else @loop_depth -= 1 end

    # 4. Loop Mark Elision: emit saveLoopMark/restoreLoopMark when the loop body
    # allocates from the frame arena AND those allocations don't target an
    # outer-scope variable (which mark-rewind would corrupt).
    node.mark_per_iter = loop_allocates_frame?(node.body) &&
                         !loop_frame_escapes_to_outer?(node.body, outer_vars)

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
        current_scope.declare(node.var_name, nil, elem_sym, false, false, nil, :stack)
        node.symbol = current_scope.locals[node.var_name]
        classify_ownership!(node.symbol)
        node.body.each { |stmt| visit(stmt) }
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

    # 2. Capture outer-scope variable names before visiting the body.
    # Used to determine if per-iteration frame marks are safe.
    outer_vars = @scope_stack.flat_map { |s| s.locals.keys }.to_set

    # 3. Analyze Body in a New Scope AND increment loop depth
    if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end

    # We use analyze_control_flow_branches to handle state merging and drops.
    # Note: For a loop, if a variable dies in the body, it dies for the next iteration (merged to parent).
    pre_loop_og = @og&.fork

    analyze_control_flow_branches([
      proc {
        if node.do_branch.is_a?(Array)
          node.do_branch.each { |stmt| visit(stmt) }
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
          was_live = pre_loop_og&.live?(name)
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

    # 5. Loop Mark Elision: emit saveLoopMark/restoreLoopMark only when the loop
    # body actually allocates from the frame arena AND those allocations don't
    # target an outer-scope variable (which mark-rewind would corrupt).
    # TIGHT loops suppress loop marks entirely (arena growth is the caller's concern).
    node.mark_per_iter = !node.tight &&
                         loop_allocates_frame?(node.do_branch) &&
                         !loop_frame_escapes_to_outer?(node.do_branch, outer_vars)

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
    node.body.each { |s| visit(s) }
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
      og_declare(cap_name, node, :Int64, :stack)
    end
    node.full_type = :Void
  end

  def visit_DieNode(node)
     # Usually takes an integer status code
     visit(node.status) if node.status
     node.full_type = :NoReturn # Special type indicating execution stops
  end

  def visit_Raise(node)
    # RAISE "message" - signals an error
    visit(node.message_expr) if node.message_expr
    node.full_type = :NoReturn # Raises propagate up or are caught
  end

  # ==========================================
  # VARIABLES & DEPENDENCIES
  # ==========================================

  def visit_ReturnNode(node)
    # Handle optional return node for Void functions.
    expected = current_fn_ctx&.return_type
    if node.value.nil?
      # If the function expects a value but we return nothing -> ERROR
      if expected && expected != :Void && expected != :Any
        error!(node, "Function expects return type #{expected}, got Void")
      end

      node.full_type = :Void
      return # Stop here, nothing else to analyze
    end

    visit(node.value)

    # 1. Lifetime Tracking
    verify_return(node.value)

    actual = node.value.resolved_type
    expected = current_fn_ctx.return_type

    # 2. Ownership Tracking
    was_promoted = handle_return_escape(node.value, expected)
    if was_promoted
      current_fn_ctx.frame_count -= 1
      current_fn_ctx.heap_count  += 1
      record_effect(EffectTracker::HEAP)
    end

    # 3. Escape marking: set escaped_return on variables being returned
    # so the ownership generator suppresses their defer cleanup.
    # PromotionPlan (Pass C) reads these flags to decide what to promote.
    if mark_escaping_collections!(node.value)
      fn_node = @fn_nodes[current_fn_ctx&.name]
      fn_node.returns_promoted = true if fn_node
    end

    # Promote non-identifier literals to heap when the expected return type requires it.
    # handle_return_escape only handles identifier variables; literals need this explicit check.
    unless was_promoted || node.value.is_a?(AST::Identifier)
      expected_type = Type.new(expected) if expected
      if expected_type && (expected_type.heap? || expected_type.dynamic?) &&
         node.value.respond_to?(:storage=) &&
         node.value.type_info&.requires_move?
        node.value.storage = :heap
      end
    end

    if expected && expected != :Void && expected != :Any && actual != expected
      # Basic check (you might want to allow Number[3] -> Number[] coercion)
      if !is_safe_autocast?(actual, expected)
        error!(node, :RETURN_MISMATCH, expected, actual)
      end
      node.value.coerced_type = expected  # Don't coerce EXPLICIT returns
    end

    node.full_type = actual

    if current_fn_ctx
      current_fn_ctx.returns << {storage: node.value.storage, type: actual, metatype: node.value.metatype}
    end
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
      error!(node, :STATIC_UNKNOWN_METHOD, node.method_name, type_name, available)
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
    node.stdlib_allocates = true if method_def[:allocates]
    current_fn_ctx.alloc_count += 1 if current_fn_ctx && (method_def[:allocates] || method_def[:can_fail])
  end

  def visit_FuncCall(node)
    node.args.each { |arg| visit(arg) }

    # Handle "native_call" special case
    if node.name == "native_call"
      node.full_type = :Any
      return
    end

    resolve_call(node, node.args)
  end

  def visit_MethodCall(node)
    visit(node.object)
    node.args.each { |arg| visit(arg) }

    # Collection method dispatch (Pool/HashMap) via declarative registry.
    return if resolve_collection_method(node)

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
        node.full_type = method_sig[:return]&.dig(:type) || :Void
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
        return
      end
    end

    # Fall through to UFCS: obj.method(args) → method(obj, args)
    ufcs_args = [node.object] + node.args
    resolve_call(node, ufcs_args)
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
    if ret.is_a?(Symbol) && ret.to_s.start_with?("infer_") && respond_to?(ret, true)
      node.full_type = send(ret, args, node)
    else
      node.full_type = ret
    end

    # 4. Store Zig pattern for transpiler
    node.zig_pattern = matched_def[:zig]
    node.stdlib_allocates = true if matched_def[:allocates]
    current_fn_ctx.alloc_count += 1 if current_fn_ctx && (matched_def[:allocates] || matched_def[:can_fail])

    # 5. Collection type narrowing (e.g., append narrows Any[] → T[])
    narrow_collection_type!(matched_def, args)
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
    # Pre-set :stack on list literals when the declared type is a fixed array (e.g. Number[3]).
    if node.value.is_a?(AST::ListLit) && node.type.is_a?(Type) && node.type.fixed?
      node.value.storage = :stack
    end
    visit(node.value)

    verify_unrestricted!(node)
    handle_assign_move(node)
    handle_assign_borrow(node)

    validate_type_annotation!(node, node.type) if node.type
    validate_stream_type!(node)

    final_type, error = node.value.coerce!(node.type)
    error!(node, error) if error

    propagate_declared_type_to_value!(node, final_type)

    storage = finalize_decl_storage!(node, final_type)
    propagate_collection_metadata!(node, final_type)
    propagate_call_flags!(node)
    is_resource, resource_close = resolve_resource_close(node, final_type)
    node.resource_close_zig = resource_close
    node.type_info.is_resource = true if is_resource && node.type_info.respond_to?(:is_resource=)

    Capabilities.validate!(node, node.type_info) { |n, msg| error!(n, msg) }

    node_sync = node.type_info&.sync
    current_scope.declare(
      node.name, node, final_type, node.mutable, false, node.slot_size, storage,
      Set.new, [],
      sync: node_sync,
      resource: is_resource,
      close_zig: resource_close
    )
    node.symbol = current_scope.locals[node.name]
    # Propagate @link_source from the value type to the scope entry
    val_ti = node.value&.type_info
    if val_ti&.link?
      link_src = val_ti.link_source
      node.symbol.link_source = link_src if link_src
    end
    classify_ownership!(node.symbol)
    og_declare(node.name, node, node.type_info || final_type, storage)
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
      node.mode = :decl

      verify_unrestricted!(node)
      handle_assign_move(node)
      handle_assign_borrow(node)

      validate_type_annotation!(node, node.type) if node.type
      validate_stream_type!(node)

      final_type, error = node.value.coerce!(node.type)
      error!(node, error) if error

      # Post-coerce value type updates: coerce! validates compatibility but the
      # value node's full_type may need updating for the transpiler.
      propagate_declared_type_to_value!(node, final_type)

      storage = finalize_decl_storage!(node, final_type)
      propagate_collection_metadata!(node, final_type)
      propagate_call_flags!(node)
      is_resource, resource_close = resolve_resource_close(node, final_type)
      node.resource_close_zig = resource_close
      node.type_info.is_resource = true if is_resource && node.type_info.respond_to?(:is_resource=)

      Capabilities.validate!(node, node.type_info) { |n, msg| error!(n, msg) }

      node_sync = node.type_info&.sync
      current_scope.declare(
        node.name, node, final_type, false, false, node.slot_size, storage,
        Set.new, [],
        sync: node_sync,
        resource: is_resource,
        close_zig: resource_close
      )
      node.symbol = current_scope.locals[node.name]
      # Propagate @link_source from the value type to the scope entry
      val_ti = node.value&.type_info
      if val_ti&.link?
        link_src = val_ti.link_source
        node.symbol.link_source = link_src if link_src
      end
      classify_ownership!(node.symbol)
      og_declare(node.name, node, node.type_info || final_type, storage)
      accumulate_stack_bytes(storage, node)
      track_union_alias(node.name, node.value)
      record_capability_binding(node.name, node, final_type, storage)

    elsif scope.is_immutable?(node.name)
      error!(node, "Variable '#{node.name}' is immutable")

    else
      # Assignment path
      node.mode = :assign

      verify_unrestricted!(node)
      validate_assignment_type(node, scope.resolve_type(node.name), node.value.resolved_type)
      node.full_type = scope.resolve_type(node.name)

      handle_assign_escape(node)
      handle_assign_move(node)
      handle_assign_borrow(node)

      mark_var_mutated(node.name)
      og_set_live(node.name)
    end
  end

  def visit_Identifier(node)
    # Pipeline expressions (inside s>) are closures over the enclosing scope —
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
      error!(node, "Undefined variable '#{node.name}'")
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
    else
      node.full_type = raw_type
    end

    # 3. Liveness
    if @og&.moved?(node.name)
      # TODO: Better error
      error!(node, "Use of moved value '#{node.name}'")
    end

    # 4. Mark variable as read so the transpiler can skip `_ = &x` suppression.
    # The variable may live in an outer scope; use lookup_scope_for to find it.
    owner = lookup_scope_for(node.name)
    owner&.mark_read(node.name)
    node.symbol = owner&.locals&.[](node.name)
  end

  # Mark a variable's declaration node as mutated (reassigned after declaration).
  # Recursively find ALL frame-allocated collections reachable from a value node
  # and mark them for heap promotion. Returns true if any escaping data was found.
  # Handles: direct collections, struct literal fields, struct/union variables
  # containing collection fields (via schema lookup), and arbitrary nesting.
  def mark_escaping_collections!(node)
    return false unless node

    if node.is_a?(AST::Identifier)
      ti = node.type_info
      # Frame-allocated collections (@list, HashMap) must be promoted to heap on escape.
      # Strings are excluded at THIS level — bare string returns live in the caller's
      # frame arena. But strings inside struct/union literals ARE marked (handled below
      # in the StructLit branch) because the union cleanup path needs to know about them.
      if ti&.needs_escape_promotion? && !ti&.string?
        mark_symbol_escaped!(node, ti)
        return true
      end
      # Struct/union variable containing collection fields — walk type schema
      resolved = ti&.resolved
      schema = lookup_type_schema(resolved) if resolved
      if schema.is_a?(Hash) && !schema[:kind]
        found = false
        schema.each do |fname, ftype|
          next if fname.is_a?(Symbol)
          ft = ftype.is_a?(Type) ? ftype : Type.new(ftype)
          if ft.needs_escape_promotion?
            mark_symbol_escaped!(node, ft)
            found = true
          end
        end
        return found
      end
    elsif node.is_a?(AST::StructLit)
      found = false
      node.fields.each do |_fname, fval|
        found = true if mark_escaping_collections!(fval)
      end
      return found
    end
    false
  end

  # Mark a symbol's declaration as escaped — suppress defer-deinit, set heap flags.
  def mark_symbol_escaped!(node, field_type)
    decl_reg = node.symbol&.reg
    if decl_reg&.respond_to?(:type_info)
      decl_reg.type_info.escaped_return = true
    end
    # Also set on the SymbolEntry's type so the transpiler can read it
    sym_type = node.symbol&.type
    sym_type.escaped_return = true if sym_type.is_a?(Type)
  end

  # This allows the transpiler to skip `_ = &name;` for mutable variables that
  # are genuinely reassigned — LLVM can then SROA struct fields to registers.
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
    elsif type_obj.any_sync? || entry.sync
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
    decl_node = scope.locals[name]&.reg
    decl_node.var_mutated = true if decl_node&.respond_to?(:var_mutated=)
  end

  # ==========================================
  # Assignment
  # ==========================================
  def visit_Assignment(node)
    visit(node.value)

    verify_unrestricted!(node)

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

    handle_assign_escape(node)
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

    # 2. Check Mutability of the owner
    if index_node.target.is_a?(AST::Identifier)
      var_name = index_node.target.name
      if current_scope.is_immutable?(var_name)
        error!(assignment_node, "Cannot modify index of immutable list '#{var_name}'")
      end
      mark_var_mutated(var_name)
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
    end

    # 4. Type Check
    validate_assignment_type(assignment_node, field_node.resolved_type, assignment_node.value.resolved_type)

    # Assignments are statements (void), not expressions that produce a value.
    assignment_node.full_type = :Void
  end

  def validate_assignment_type(node, target_type, value_type)
    return if target_type.nil? || value_type.nil? || target_type == :Any || value_type == :Any
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

  def visit_Require(node)
    # 1. Resolve Path (Same as Compiler)
    # Note: You might need to pass source_path to Annotator initialize to resolve relative paths
    current_dir = Dir.pwd # Or passed in path
    full_path = File.expand_path(node.path, current_dir)

    unless File.exist?(full_path)
      error!(node, "Import Error: #{full_path}")
    end

    # 2. Parse
    code = File.read(full_path)
    # Assume you have access to your Lexer/Parser classes here
    sub_ast = Parser.new(Lexer.new(code).tokenize, code).parse

    # 3. Visit (In the SAME scope context, or new?)
    # Compiler creates a NEW compiler. Annotator should probably visit
    # in the current scope so types/functions become visible.
    visit(sub_ast)

    node.full_type = :Void
  end

  # TODO: Simplify with new type class
  def visit_GetIndex(node)
    visit(node.target)
    visit(node.index)

    target_type_info = node.target.type_info

    # Case 1: HashMap Access — returns ?V (optional; nil if key missing)
    if target_type_info.map?
      val_t = target_type_info.value_type
      node.full_type = Type.new(:"?#{val_t.resolved}")

      # Validate Key Type
      # Numeric maps (HashMap<Int64,V> or HashMap<Number,V>) accept numeric keys.
      # String maps require a String key.
      index_type_info = node.index.type_info
      if target_type_info.numeric_map?
        unless index_type_info&.numeric?
          error!(node, "Numeric map keys must be a number type, got #{node.index.resolved_type}")
        end
      else
        unless index_type_info&.string?
          error!(node, "Map keys must be Strings, got #{node.index.resolved_type}")
        end
      end

    # Case 2: Pool Index Access: pool[id] -> ?T  (sugar for pool.get(id))
    elsif target_type_info.pool?
      elem = target_type_info.element_type
      node.full_type = Type.new(:"?#{elem.resolved}")

    # Case 2b: Promise List Index Access: ~T[]@list[i] -> ~T (a single promise)
    # CheatLib.getAt handles ArrayListUnmanaged; annotator returns the promise type.
    elsif target_type_info.promise_list?
      elem_t = target_type_info.tense_type.element_type
      node.full_type = Type.new(:"~#{elem_t.resolved}")

    # Case 2c: String indexing — only allowed on String@raw
    elsif target_type_info.string? && !target_type_info.raw?
      error!(node, "Cannot index String by integer. Use String@raw for byte access, or .codepoints() for iteration.")

    # Case 2d: String@raw byte indexing -> returns String (single byte as 1-char slice)
    elsif target_type_info.string? && target_type_info.raw?
      node.full_type = :String

    # Case 3: Array Access "Number[]" -> :Float64, "Number[][]" -> "Number[]"
    elsif target_type_info.array? || node.target.metatype == :struct
      node.full_type = target_type_info.element_type

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
      type_obj = Type.new(type)
      if type_obj.generic_instance? && schema[:type_params] && field_type.is_a?(Type)
        subst = {}
        schema[:type_params].zip(type_obj.generic_args).each do |param, arg|
          subst[param] = arg.resolved
        end
        resolved_param = field_type.resolved
        field_type = Type.new(subst[resolved_param]) if subst.key?(resolved_param)
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
      return
    end

    # Analyze all values
    node.pairs.each { |k, v| visit(v) }

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
        error!(node, :UNION_UNKNOWN_VARIANT, node.name, variant_name)
      end
      raw_expected = schema[:variants][variant_name]
      if raw_expected.nil?
        error!(node, "Union variant '#{variant_name}' is a unit variant — use '#{node.name}.#{variant_name}' (no payload).")
      end
      if raw_expected.is_a?(Hash) && raw_expected[:kind] == :inline_struct
        error!(node, :UNION_INLINE_VARIANT_OLD_SYNTAX, node.name, variant_name, node.name, variant_name)
      end
      # Apply type param substitution (e.g. T → Number for generic unions)
      expected_type = union_subst.any? ? apply_type_subst(raw_expected, union_subst) : raw_expected
      visit(val_node)
      actual = val_node.type_info
      unless expected_type.accepts?(actual)
        error!(node, :UNION_PAYLOAD_MISMATCH, variant_name, expected_type.resolved, actual&.resolved)
      end
      node.full_type = if node.type_args&.any?
        :"#{node.name}<#{node.type_args.join(',')}>"
      else
        node.name.to_sym
      end
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
        error!(node, "Struct '#{node.name}' has no field '#{field_name}'")
      end

      # Apply type param substitution (e.g., T → Number)
      expected_type = if raw_expected.is_a?(Type) && type_subst.key?(raw_expected.resolved)
        Type.new(type_subst[raw_expected.resolved])
      else
        raw_expected
      end

      # Simple Type Check
      if val_node.full_type != expected_type
        unless is_safe_autocast?(val_node.resolved_type, expected_type)
          error!(node, "Field '#{field_name}' expected #{expected_type}, got #{val_node.resolved_type}")
        end
        val_node.coerced_type = expected_type
      end
    end

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
    if !node.items.empty? && node.items.all? { |i| Type.new(i.resolved_type).tense? }
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
        t.location = :heap if coll == :pool || coll == :set
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
      node.full_type = Type.new(:"#{base_type}[]", location: :heap)
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

    # Coerce integer types to Number (f64) for uniform Range representation
    node.start.coerced_type = :Float64 if start_type != :Float64 && Type.new(start_type).numeric?
    node.finish.coerced_type = :Float64 if finish_type != :Float64 && Type.new(finish_type).numeric?

    node.full_type = :Range
  end

  def visit_Literal(node)
    node.full_type =
      case node.type
      when :NUMBER then :Float64
      when :INT64 then :Int64
      when :STRING
        if node.storage == :stack
          :"Byte[#{node.value.length}]"
        else
          Type.new(Type::STRING_TYPE, location: :heap)
        end
      when :BYTE    then :Byte
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
      current_fn_ctx.frame_count += 1 if current_fn_ctx
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

    # Register in scope (Immutable, Stack storage)
    current_scope.declare(
      var_name,
      nil,
      lhs_type,
      false, # Immutable
      false, # Not rebindable
      nil,
      :stack
    )

    # The result of the operation is the value itself (passthrough)
    node.full_type = lhs_type
  end

  # =========================================================
  # OR / RESCUE
  # =========================================================
  def visit_OrRescue(node)
    # Logic: val OR default
    visit(node.left)
    visit(node.right)

    t_left_type = node.left.type_info
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
    node.full_type = :Void
  end

  def visit_CapabilityWrap(node)
    visit(node.value)

    base_type = node.value.resolved_type  # e.g. :Node
    ti = Type.new(base_type)

    # Primitive types (Int64, Number, Bool, Byte, Float64) cannot have capabilities.
    # Wrapping a primitive in @local/@locked/@shared creates a heap pointer to a
    # value you can't meaningfully dereference.  Wrap in a STRUCT instead.
    if ti.primitive? && (node.ownership || node.sync || node.layout)
      cap_name = node.sync || node.ownership || node.layout
      error!(node, "Capability @#{cap_name} cannot be applied to primitive type #{base_type}. " \
                   "Wrap in a STRUCT (e.g. STRUCT Wrapper { value: #{base_type} }) and apply the capability to the struct.")
    end

    ti.ownership = node.ownership if node.ownership
    ti.sync      = node.sync      if node.sync
    # @indirect forces heap location (same as @local, but different intent).
    ti.location  = :heap           if node.layout == :indirect

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

    unless ti&.multiowned? || ti&.shared? || ti&.requires_move? || is_resource
      error!(node, "MOVE can only be applied to @multiowned, @shared, promise, or resource variables, got '#{node.value.resolved_type}'")
    end

    # Inherit the capability type so the VarDecl or ReturnNode can infer storage correctly
    node.full_type = node.value.full_type
    node.storage   = node.value.storage

    # Consume the source variable — it is affinely transferred
    og_set_moved(node.value.name)
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

    # Result is optional of the strong type: ?T@shared or ?T@multiowned
    source = ti.link_source || :multiowned
    resolved_type = Type.new(:"?#{ti.resolved}")
    resolved_type.ownership = source == :shared ? :shared : :multiowned
    resolved_type.link_source = source
    node.full_type = resolved_type
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
    # 1. Validate each capability's variable exists and resolve its type
    expanded_capabilities = []
    node.capabilities.each do |cap|
      acquire_capability!(node, cap, expanded_capabilities)
    end

    # 2. Enter a child scope for the capability block
    # Inherits parent variables so the WITH body can see enclosing locals,
    # but new declarations inside are isolated to the WITH block.
    with_new_scope(current_scope) do
      expanded_capabilities.each { |cap| declare_capability_scope!(cap) }
      node.body.each { |stmt| visit(stmt) }
      finalize_scope(node)
    end

    # Release RESTRICT borrows after the WITH block exits
    expanded_capabilities.each do |cap|
      if cap[:capability] == :RESTRICT
        @og.release_borrow("__restrict_#{cap[:var_node].name}")
      end
    end

    node.full_type = :Void
  end

  def visit_DoBlock(node)
    node.branches.each do |branch|
      branch[:body].each { |expr| visit(expr) }

      analysis = validate_fiber_captures!(node, branch[:body], branch[:parallel], branch[:pinned])

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

    node.body.each { |expr| visit(expr) }

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

    node.full_type = :"~#{elem_syms.first}[?]"
  end

  def visit_YieldExpr(node)
    unless @current_stream_context
      error!(node, "YIELD can only be used inside a BG STREAM { } block.")
    end
    visit(node.expr)
    node.full_type = node.expr.full_type || :Void
    @stream_yield_types << Type.new(node.full_type)
  end

  def visit_BgBlock(node)
    # Body runs in a separate fiber. The last expression's type determines T in ~T.
    # node.stack_size: :standard | :micro | :large | :xl | nil  (nil → STANDARD default)
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
    node.full_type = :"~#{last_type}"

    # Propagate returns_promoted through BG blocks: if the last expression
    # calls a function with returns_promoted, the BG block's promise carries
    # heap-promoted data that the NEXT caller must clean up.
    last_expr = node.body.last
    if has_heap_promoted_call?(last_expr)
      node.returns_promoted = true
    end

    # @arena implies @pinned — thread-local arena memory can't be stolen.
    if node.arena_mode
      node.pinned = true
      if node.parallel
        error!(node, "@arena cannot be combined with @parallel — arena memory is thread-local and cannot be stolen.")
      end
    end

    # Single walk: validate captures, detect shared state, audit capabilities.
    analysis = validate_fiber_captures!(node, node.body, node.parallel, node.pinned)

    # Safety: pinned scope → child BG must also be pinned if it captures outer vars.
    if @current_bg_pinned && !node.pinned && captures_outer_variables?(node.body, locally_bound)
      error!(node, "BG block inside @pinned scope captures local variables but is not @pinned. " \
                   "Thread-local memory cannot escape to a stealable fiber. " \
                   "Add @pinned to this BG block, or avoid capturing variables from the pinned scope.")
    end

    # Auto-pin when shared state is captured (uses result from validate_fiber_captures!).
    if analysis && !node.pinned
      node.pinned = true
      if analysis.has_sharded
        note!(node, "BG block auto-pinned — captures @sharded map (scheduler affinity for shard locality).")
      else
        note!(node, "BG block auto-pinned — captures shared/locked resource. Use @parallel to override.")
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
    visit(node.expr)
    promise_type = Type.new(node.expr.full_type || :Void)

    unless promise_type.tense?
      error!(node, "NEXT requires a Promise (~T) or bounded stream (~T[N]), got #{node.expr.full_type}")
    end

    # ~T[] (bare dynamic tense array) is not a valid form — give a directed error.
    if promise_type.tense_type.array? && promise_type.tense_type.dynamic?
      error!(node, "~T[] is not a valid stream type. Use ~T[N] for a bounded stream of N concurrent tasks, ~T[INF] for an infinite rendezvous stream, or ~T[?] for an open/closeable stream.")
    end

    if promise_type.bounded_stream?
      # NEXT on ~T[N]: returns T (the element type).
      # Does NOT mark the stream as moved — the stream can be NEXT'd up to N times.
      node.full_type = promise_type.stream_element_type.to_sym
    elsif promise_type.shared_promise?
      # NEXT on ~T@shared: returns T, idempotent — same handle can be NEXT'd again.
      # Does NOT mark as moved; multiple consumers may hold their own handles.
      node.full_type = promise_type.tense_type.to_sym
    elsif promise_type.open_stream?
      # NEXT on ~T[?]: returns ?T — null signals stream exhaustion.
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
        og_set_moved(node.expr.name)
      end
      node.full_type = promise_type.tense_type.to_sym
    end

    # Propagate heap_promoted through NEXT: if the BG block's body called a
    # function with returns_promoted, the NEXT caller must free promoted fields.
    if node.expr.is_a?(AST::Identifier)
      sym = node.expr.symbol
      decl_node = sym&.reg  # the declaration's AST node (BindExpr/VarDecl)
      bg_value = decl_node.respond_to?(:value) ? decl_node.value : nil
      if bg_value.is_a?(AST::BgBlock) && bg_value.returns_promoted
        node.heap_promoted_call = true
      end
    end
  end

  def get_type_slot_size(type_input)
    type_obj = type_input.is_a?(Type) ? type_input : Type.new(type_input)
    type_obj.slot_size { |name| lookup_type_schema(name) }
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
    if node.value.is_a?(AST::GetField) || node.value.is_a?(AST::GetIndex)
      path = get_path_to_root(node.value)
      return if path.nil?
      if Type.new(node.value.resolved_type).requires_move?
        graph_path = path.map(&:to_s).join(".")
        @og.declare(graph_path, kind: :affine, scope_depth: @og_scope_depth) unless @og[graph_path]
        og_set_moved(graph_path)
      end
      return
    end

    return unless node.value.is_a?(AST::Identifier)
    rhs_name = node.value.name
    rhs_type = current_scope.resolve_type(rhs_name)
    rhs_info = current_scope.locals[rhs_name]
    return if rhs_info&.storage == :multiowned || rhs_info&.storage == :shared || rhs_info&.sync

    if Type.new(rhs_type).requires_move? || rhs_info&.resource
      lhs_name = node.name.is_a?(AST::Identifier) ? node.name.name : node.name.to_s
      og_move(rhs_name, lhs_name)
    end
  end

  def handle_assign_escape(node)
    return unless node.value.is_a?(AST::Identifier)
    rhs_name = node.value.name
    rhs_scope = lookup_scope_for(rhs_name)
    target_is_heap = false

    if node.name.is_a?(AST::Identifier)
      lhs_scope = lookup_scope_for(node.name.name)
      target_is_heap = true if lhs_scope && (lhs_scope.is_on_heap?(node.name.name) || is_global_scope?(lhs_scope))
    elsif node.name.is_a?(AST::GetField) || node.name.is_a?(AST::GetIndex)
      root = get_root_object(node.name)
      if root.is_a?(AST::Identifier)
        root_scope = lookup_scope_for(root.name)
        target_is_heap = true if root_scope && (is_global_scope?(root_scope) || root_scope.is_on_heap?(root.name))
      end
    end

    if target_is_heap && rhs_scope && Type.new(rhs_scope.resolve_type(rhs_name)).requires_move?
      promote_to_heap(rhs_name, rhs_scope)
    end
  end

  def handle_assign_borrow(node)
    return unless node.value.is_a?(AST::FuncCall) || node.value.is_a?(AST::MethodCall)
    call_node = node.value
    return if call_node.is_a?(AST::MethodCall) && call_node.pool_method

    func_name = call_node.name
    scope = lookup_scope_for(func_name)
    return unless scope

    func_type = scope.resolve_type(func_name)
    return unless func_type.is_a?(Hash)

    lifetime = func_type.dig(:return, :lifetime)
    return if lifetime.nil?

    param_index = func_type[:params].find_index { |p| p[:name] == lifetime }
    error!(node, "Missing lifetime") if param_index.nil?

    args = call_node.is_a?(AST::MethodCall) ? [call_node.object] + call_node.args : call_node.args
    actual_arg = args[param_index]
    error!(node, "Missing borrowed param") if actual_arg.nil?

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

  def handle_return_escape(value_node, expected_type = nil)
    return false if value_node.nil?
    if expected_type
      expected = Type.new(expected_type)
      return false unless expected.heap? || expected.dynamic?
    end

    root = get_root_object(value_node)
    return false unless root.is_a?(AST::Identifier)

    var_name = root.name
    sym = root.symbol
    return false unless sym

    owner_scope = sym.scope
    return false unless owner_scope
    return false if sym.storage == :multiowned || sym.storage == :shared || sym.sync

    type = owner_scope.resolve_type(var_name)
    return false unless Type.new(type).requires_move?

    result = promote_to_heap(var_name, owner_scope)
    root.storage = :heap if owner_scope.is_on_heap?(var_name) && root.respond_to?(:storage=)
    result
  end

  def verify_unrestricted!(node)
    path = get_path_to_root(node.name)
    return if path.nil?
    root_name = path.first.to_s
    unless @og.can_write?(root_name)
      error!(node, "Lifetime Error: Cannot assign to '#{root_name}' because it is currently borrowed.")
    end
  end

  def finalize_scope(node, branch: nil)
    drops = []
    current_scope.locals.each do |name, info|
      next unless current_scope.owned_names.include?(name)
      next unless @og.live?(name)
      classify_ownership!(info) unless info.ownership_kind

      case info.ownership_kind
      when :resource
        drops << { name: name, type: info.type, resource: true }
        og_drop(name)
      when :affine
        if Type.new(info.type).tense?
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
        loc = info.reg.respond_to?(:line) ? " (line #{info.reg.line})" : ""
        $stderr.puts "\e[33m[Warning]\e[0m Unused variable '#{name}'#{loc}"
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
        if node && Type.new(info.type).tense?
          error!(node, "Promise '#{name}' must be consumed before it goes out of scope. Use NEXT, COLLECT, or RETURN it.")
        end
        drops << { name: name, type: info.type }
        og_drop(name)
      end
    end
    drops
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

  def get_lifetime_path(func_node)
    get_path_to_root(func_node.return_lifetime)&.join(".")
  end

  # ── Strict Test Mode ─────────────────────────────────────────────
  # In --strict mode, all IO functions (BLOCKING/EXTERN effects) must be
  # stubbed in test bodies. Walks the call chain transitively.

  # Known IO builtins that don't appear in @fn_nodes (runtime-level).
  IO_BUILTINS = %w[tcpRead tcpWrite accept connect readFile writeFile
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
  def validate_tail_call!(fn_node)
    fn_name = fn_node.name
    returns = fn_node.body.select { |s| s.is_a?(AST::ReturnNode) }
    has_tail = returns.any? { |r| r.value.is_a?(AST::FuncCall) && r.value.name == fn_name }
    unless has_tail
      error!(fn_node, "@reentrant:tailCall requires at least one RETURN that directly " \
                       "calls '#{fn_name}' in tail position (e.g., RETURN #{fn_name}(...)). " \
                       "The recursive call cannot be wrapped in an expression.")
    end

    # Check that no RETURN has a non-tail self-call (e.g., RETURN fib(n) + fib(n))
    returns.each do |r|
      next if r.value.is_a?(AST::FuncCall) && r.value.name == fn_name  # direct tail call - OK
      if contains_self_call?(r.value, fn_name)
        error!(r, "@reentrant:tailCall: RETURN expression contains '#{fn_name}' in " \
                   "non-tail position. The recursive call must be the ENTIRE return expression.")
      end
    end
  end

  def contains_self_call?(node, fn_name)
    return false unless node
    return true if node.is_a?(AST::FuncCall) && node.name == fn_name
    if node.respond_to?(:each_pair)
      node.each_pair { |_, v| return true if contains_self_call?(v, fn_name) }
    end
    false
  end

  # ── Pass B: Ownership Analysis ───────────────────────────────────
  # Runs after all types are resolved. Builds a complete ownership picture
  # by walking the AST with full type information available.

  def compute_ownership!(program_node)
    # Phase 1: Recompute returns_promoted for ALL functions with complete type info.
    # This catches CATCH wrappers and other cases Pass A missed.
    recompute_returns_promoted!

    # Phase 2: Determine which functions return heap-promoted union data.
    @fn_returns_heap_union = {}
    @fn_nodes.each do |name, fn|
      ret_type = fn.return_type
      next unless ret_type
      ret_sym = ret_type.to_s.delete_prefix("!").to_sym
      schema = lookup_type_schema(ret_sym)
      if schema.is_a?(Hash) && schema[:kind] == :union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        @fn_returns_heap_union[name] = true if has_heap && fn.returns_promoted
      end
    end

    # Phase 3: Propagate heap_promoted to caller variables.
    walk_promote_callers(program_node.statements)

    # Phase 4: Walk all variable declarations and annotate ownership.
    walk_ownership(program_node.statements)
  end

  # Recompute returns_promoted with complete type information.
  # Pass A computes it incrementally during visit_ReturnNode, but misses:
  # - CATCH wrappers (synthetic outer function doesn't visit returns)
  # - GetField returns from promoted structs (valid.name where valid is promoted)
  # - Transitive promotion through call chains
  def recompute_returns_promoted!
    # Step 1: For each function, check if ANY callee in its body has returns_promoted
    # and the function returns the callee's result (directly or via field access).
    @fn_nodes.each do |name, fn|
      next if fn.returns_promoted  # already set by Pass A

      # Find return nodes in the function body
      returns = collect_return_nodes(fn.body)
      returns.each do |ret|
        next unless ret.value

        # Case 1: RETURN someCall() where someCall has returns_promoted
        if ret.value.is_a?(AST::FuncCall)
          callee = @fn_nodes[ret.value.name]
          if callee&.returns_promoted
            fn.returns_promoted = true
            break
          end
        end

        # Case 2: RETURN obj.field where obj came from a promoted call
        if ret.value.is_a?(AST::GetField)
          root = get_root_object(ret.value)
          if root.is_a?(AST::Identifier)
            root_type = root.resolved_type
            # Check if any function returns this type with promotion
            if @fn_nodes.any? { |_, cfn| cfn.returns_promoted && cfn.return_type.to_s.delete_prefix("!") == root_type.to_s }
              ret_type = ret.value.respond_to?(:full_type) ? Type.new(ret.value.full_type) : nil
              if ret_type&.string? || ret_type&.collection? || ret_type&.map?
                fn.returns_promoted = true
                break
              end
            end
          end
        end
      end
    end

    # Step 2: Propagate returns_promoted transitively through call graph.
    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        fn = @fn_nodes[fn_name]
        next unless fn
        next if fn.returns_promoted
        if callees.any? { |c| @fn_nodes[c]&.returns_promoted }
          returns = collect_return_nodes(fn.body)
          if returns.any? { |r| r.value.is_a?(AST::FuncCall) && @fn_nodes[r.value.name]&.returns_promoted }
            fn.returns_promoted = true
            changed = true
          end
        end
      end
    end

  end

  def collect_return_nodes(body)
    returns = []
    body = [body] unless body.is_a?(Array)
    body.each do |node|
      case node
      when AST::ReturnNode
        returns << node
      when AST::IfStatement
        returns += collect_return_nodes(node.then_branch)
        returns += collect_return_nodes(node.else_branch)
      when AST::WhileLoop
        b = node.do_branch.is_a?(Array) ? node.do_branch : [node.do_branch]
        returns += collect_return_nodes(b)
      else
        # Don't descend into nested FunctionDef
      end
    end
    returns
  end

  def walk_promote_callers(nodes)
    nodes = [nodes] unless nodes.is_a?(Array)
    nodes.each do |node|
      case node
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        node.each { |n| walk_promote_callers([n]) }
      when AST::FunctionDef
        @_walk_current_fn = node
        walk_promote_callers(node.body)
      when AST::VarDecl, AST::BindExpr
        # If value is a FuncCall from a returns_promoted function, set heap_promoted
        val = node.value
        if val.is_a?(AST::FuncCall) && @fn_nodes[val.name]&.returns_promoted
          node.type_info.heap_promoted = true if node.type_info
          # For reassignment (BindExpr mode=assign), also propagate to the declaration.
          # The declaration is the original VarDecl/BindExpr for this variable name.
          if node.is_a?(AST::BindExpr) && node.mode == :assign
            var_name = node.name
            decl = find_decl_in_body(@_walk_current_fn&.body, var_name) if @_walk_current_fn
            decl.type_info.heap_promoted = true if decl&.respond_to?(:type_info) && decl.type_info.is_a?(Type)
          end
        end
        walk_promote_callers([val]) if val
      when AST::Assignment
        # Reassignment: result = makeList() inside IF/MATCH branches.
        # Use the target identifier's symbol to find the declaration node.
        val = node.value
        if val.is_a?(AST::FuncCall) && @fn_nodes[val.name]&.returns_promoted
          target = node.name
          sym = target.respond_to?(:symbol) ? target.symbol : nil
          decl = sym&.reg
          decl.type_info.heap_promoted = true if decl&.respond_to?(:type_info) && decl.type_info.is_a?(Type)
        end
        walk_promote_callers([val]) if val
      when AST::IfStatement
        walk_promote_callers(node.then_branch)
        walk_promote_callers(node.else_branch)
      when AST::MatchStatement
        node.cases&.each { |c| walk_promote_callers(c[:body]) }
        walk_promote_callers(node.default_case) if node.default_case
      when AST::WhileLoop
        b = node.do_branch.is_a?(Array) ? node.do_branch : [node.do_branch]
        walk_promote_callers(b)
      when AST::ForRange, AST::ForEach
        walk_promote_callers(node.body)
      when AST::BgBlock, AST::BgStreamBlock
        walk_promote_callers(node.body)
      when AST::TestBlock
        walk_promote_callers(node.setup)
        node.whens&.each { |w| walk_promote_callers(w.setup); w.tests&.each { |t| walk_promote_callers(t.body) } }
      else
        node.each_pair { |_, v| walk_promote_callers([v]) if v.is_a?(Array) } if node.respond_to?(:each_pair)
      end
    end
  end

  # Find the declaration (VarDecl/BindExpr with mode=decl) for a variable name in a function body.
  def find_decl_in_body(body, var_name)
    return nil unless body
    body = [body] unless body.is_a?(Array)
    body.each do |node|
      case node
      when AST::VarDecl
        return node if node.name == var_name
      when AST::BindExpr
        return node if node.name == var_name && node.mode == :decl
      end
    end
    nil
  end

  def walk_ownership(nodes)
    nodes = [nodes] unless nodes.is_a?(Array)
    nodes.each do |node|
      case node
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        node.each { |n| walk_ownership([n]) }
      when AST::FunctionDef
        walk_ownership(node.body)
      when AST::VarDecl, AST::BindExpr
        annotate_var_ownership(node)
        walk_ownership([node.value]) if node.value
      when AST::IfStatement
        walk_ownership(node.then_branch)
        walk_ownership(node.else_branch)
      when AST::WhileLoop
        body = node.do_branch.is_a?(Array) ? node.do_branch : [node.do_branch]
        walk_ownership(body)
      when AST::ForRange, AST::ForEach
        walk_ownership(node.body)
      when AST::WithBlock
        walk_ownership(node.body)
      when AST::BgBlock, AST::BgStreamBlock
        walk_ownership(node.body)
      when AST::TestBlock
        walk_ownership(node.setup)
        node.whens.each { |w| walk_ownership(w.setup); w.tests.each { |t| walk_ownership(t.body) } }
      else
        # Walk child nodes generically
        if node.respond_to?(:each_pair)
          node.each_pair { |_, v| walk_ownership([v]) if v.is_a?(Array) || v.respond_to?(:each_pair) }
        end
      end
    end
  end

  # Annotate a variable declaration with ownership metadata on the graph node.
  def annotate_var_ownership(decl_node)
    name = decl_node.name.to_s
    graph_node = @og[name]
    return unless graph_node

    ti = decl_node.type_info
    return unless ti

    value = decl_node.value

    # Check if the value comes from a function that returns heap-promoted union data
    if value.is_a?(AST::FuncCall) && @fn_returns_heap_union[value.name]
      graph_node.storage = :heap
    end

    # Check alias: value extracted from another union/collection via function call
    if @og.aliases?(name)
      # Variable shares backing data with another - transpiler should skip cleanup
      graph_node.kind = :aliased
    end
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
        n.computed_stack_tier = max_tier_for_calls(calls)
        validate_fiber_stack!(n, calls, n.stack_size, n.can_smash)
        n.body.each { |s| traverse.call(s) }
      when AST::BgStreamBlock
        calls = scan_for_calls(n.body).first
        n.computed_stack_tier = max_tier_for_calls(calls)
        n.body.each { |s| traverse.call(s) }
      when AST::DoBlock
        n.branches.each do |branch|
          calls = scan_for_calls(branch[:body]).first
          branch[:computed_stack_tier] = max_tier_for_calls(calls)
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
  # Errors if:
  #   1. Fiber's call chain includes :unbounded (reentrant) without @canSmash
  #   2. User picked a size smaller than the computed tier without @canSmash
  def validate_fiber_stack!(node, call_names, user_size, can_smash)
    return if can_smash  # user acknowledged the risk

    computed = max_tier_for_calls(call_names)

    # Unbounded: call chain reaches a @reentrant function
    if computed == :unbounded
      fn_name = find_unbounded_callee(call_names)
      error!(node, "Stack safety: this fiber calls '#{fn_name}' whose stack depth is unbounded " \
                   "(reentrant). Add @canSmash to acknowledge the risk: BG { @canSmash -> ... }")
    end

    # User-specified size too small
    if user_size && TIER_ORDER.fetch(user_size, 0) < TIER_ORDER.fetch(computed, 0)
      error!(node, "Stack safety: @#{user_size} (#{EffectTracker::STACK_TIER_BUDGET[user_size]} bytes) " \
                   "is too small for this fiber. Call-graph analysis requires at least @#{computed}. " \
                   "Either use @#{computed} or add @canSmash to override: BG { @#{user_size}:canSmash -> ... }")
    end
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

  def og_declare(name, node, type_info, storage)
    kind = classify_og_kind(type_info)
    ti = type_info.is_a?(Type) ? type_info : (type_info ? Type.new(type_info) : nil)
    @og.declare(name, kind: kind, type_info: ti, storage: storage,
                scope_depth: @og_scope_depth, line: node&.respond_to?(:line) ? node.line : 0)
  end

  def og_move(from, to)  = @og.transfer(from, to)
  def og_set_moved(name) = (@og[name]&.state = :moved)
  def og_set_live(name)  = (@og[name]&.state = :live)
  def og_escape(name)    = @og.escape(name)
  def og_drop(name)      = @og.drop(name)
  def og_fork            = @og.fork
  def og_push_scope      = (@og_scope_depth += 1)
  def og_pop_scope       = (@og_scope_depth -= 1)

  # Unified escape: updates graph + scope storage + AST node.
  # Returns true if the variable was promoted from frame (for frame counter tracking).
  def promote_to_heap(name, scope = nil)
    og_escape(name)
    scope ||= lookup_scope_for(name)
    return false unless scope
    entry = scope.locals[name]
    return false unless entry
    was_frame = entry.storage == :frame || entry.storage == :stack
    return false if [:multiowned, :shared, :heap].include?(entry.storage)
    entry.storage = :heap
    if entry.reg&.respond_to?(:storage=)
      entry.reg.storage = :heap
      entry.reg.value.storage = :heap if entry.reg.respond_to?(:value) && entry.reg.value&.respond_to?(:storage=)
    end
    was_frame
  end

  def og_merge(snapshot)
    @og.merge(snapshot) if snapshot
  end

  def classify_og_kind(type_info)
    return :affine unless type_info
    t = type_info.is_a?(Type) ? type_info : Type.new(type_info)
    if t.multiowned? || t.shared?
      :rc
    elsif t.any_sync?
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

