require_relative "./source_error"
require_relative "./scope"
require_relative "./parser"
require_relative "./std_lib"
require_relative "./function_analysis"
require_relative "./pipe_analysis"
require_relative "./ownership_tracker"
require_relative "./generic_analysis"

# Handle Type inference, and semantic validation
class SemanticAnnotator
  include ErrorHelper
  include FunctionAnalysis
  include PipeAnalysis
  include OwnershipTracker
  include ScopeHelper
  include TypeHelper
  include GenericAnalysis

  attr_reader :scope_stack

  def initialize(importer: nil, compiler: nil, source_dir: nil)
    @importer   = importer || compiler  # compiler: kept for one-release backward compat
    @source_dir = source_dir ? File.expand_path(source_dir) : Dir.pwd
    # We start with a global scope
    @scope_stack = [Scope.new]
    @function_context_stack = [] # Stack of expected return types
    @return_collection_stack = [] # Track actual returns found in current function/lambda
    @loop_depth = 0 # Track if we are inside a loop
    @smooth_depth = 0
    @match_pattern_context = false # True when visiting a MATCH case value (suppresses inline-struct GetField error)
    @frame_usage_count = 0
    @current_fn_type_params = [] # Type params of the function currently being validated
    setup_builtins
  end

  def annotate!(node)
    visit(node)
  end

private

  def setup_builtins
    STD_LIB.each do |name, config|
      current_scope.declare(name, nil, :Intrinsic, false, false, nil, :stack)
    end

    # Setup Globals
    current_scope.declare("argv", nil, Type::STRING_TYPE, false, false, nil, :heap)

    # Built-in Range type: fields accessible via dot access
    current_scope.declare_type(:Range, {"start" => :Number, "end" => :Number})

    # Built-in File resource type
    current_scope.declare_type(:File, {
      kind: :resource,
      close_zig: "{0}.close()",
      static_methods: {
        "open"   => { args: [:String], return: :File, zig: "try CheatLib.fileOpen({0})" },
        "create" => { args: [:String], return: :File, zig: "try CheatLib.fileCreate({0})" }
      }
    })

    # Built-in TCPServer resource type — a non-blocking server socket (i32 fd).
    # TCPServer::listen(port) returns the server fd; auto-closes via RAII.
    current_scope.declare_type(:TCPServer, {
      kind: :resource,
      close_zig: "CheatLib.socketClose({0})",
      static_methods: {
        "listen" => { args: [:Int64], return: :TCPServer, zig: "try CheatLib.socketListen(@intCast({0}))" }
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
                       zig: "try CheatLib.socketConnect({0}, @intCast({1}))" }
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
      sig = entry[:type]
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
        mutable: p[:mutable] || false
      }},
      return:     { type: node.return_type || :Any, lifetime: nil },
      visibility: :pub,
      extern:     true,
      module_alias: node.from_module
    }
    node.full_type = :Void
    current_scope.declare(node.name, nil, signature, false, false, nil, :static)
  end

  # EXTERN STRUCT Name { fields } FROM "module"
  # Registers a native Zig/C struct type for CLEAR type-checking.
  def visit_ExternStructDecl(node)
    schema = node.fields.transform_keys(&:to_s).transform_values { |f| f[:type] }
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
      visibility: node.visibility
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
  def analyze_routine(node, body, declared_return, is_implicit)
    # 1. Routine Prologue (Before Scope)
    verify_captures!(node)
    @return_collection_stack.push([])

    # 2. Body Analysis (Inside Scope)
    with_new_scope do
      declare_and_verify_params(node)
      declare_captures(node)

      if body.is_a?(Array)
        body.each { |stmt| visit(stmt) }
      else
        visit(body)
      end

      finalize_scope(node)
    end

    # 3. Routine Epilogue (Process Returns)
    found_returns = @return_collection_stack.pop.uniq
    verify_returns(node, found_returns, is_implicit ? nil : declared_return)

    # Resolve return type (infer if implicit or :Any)
    return_type = if body.is_a?(Array)
      found_returns.any? ? found_returns.first[:type] : :Any
    else
      body.resolved_type
    end

    # Update return type if we can narrow it
    if (is_implicit || declared_return == :Any) && found_returns.any?
      inferred = found_returns.first[:type]
      if is_implicit || found_returns.size == 1
        return_type = inferred
      end
    end

    return_type
  end

  def visit_LambdaLit(node)
    # Lambdas are always implicit return unless we add syntax for it later
    return_type = analyze_routine(node, node.body, :Any, true)

    # Build standard signature (same format as user-defined functions)
    # This enables verify_function_signature! to validate lambda calls
    node.full_type = build_lambda_signature(node.params, return_type)
  end

  def visit_FunctionDef(node)
    @frame_usage_count = 0

    # 1. Setup metadata
    is_implicit_return = node.return_type.nil?
    declared_return = node.return_type || :Any
    lifetime_path = get_lifetime_path(node)
    fn_type_params = (node.type_params || []).map(&:to_sym)
    @function_context_stack.push({type: declared_return, lifetime: lifetime_path, type_params: fn_type_params})

    # 2. Validation & Lifetime
    has_mutable_param = node.params.any? { |p| p[:mutable] }
    if has_mutable_param && !node.name.end_with?("!")
      error!(node, "Style Error: Function '#{node.name}' has MUTABLE parameters. Its name must end in '!'")
    end
    verify_lifetime!(node)

    # Validate generic type params on the function definition
    validate_type_param_list!(node, node.type_params, "function") if fn_type_params.any?

    # Make type params visible during type annotation validation
    @current_fn_type_params = fn_type_params
    node.params.each { |p| validate_type_annotation!(node, p[:type]) if p[:type].is_a?(Type) }
    validate_type_annotation!(node, node.return_type) if node.return_type.is_a?(Type)
    @current_fn_type_params = []

    # 3. Pre-declaration (so the function can be recursive)
    signature = {
      params: node.params.map { |p| {
        name: p[:name], type: p[:type], required: p[:default].nil?, mutable: p[:mutable], takes: p[:takes]
      }},
      return: { type: declared_return, lifetime: lifetime_path },
      visibility: node.visibility,
      type_params: fn_type_params.any? ? fn_type_params : nil
    }
    current_scope.declare(node.name, nil, signature, false, false, nil, :static)

    # 4. Routine Analysis
    final_return_type = analyze_routine(node, node.body, declared_return, is_implicit_return)

    # 5. Finalize Signature
    if (is_implicit_return || declared_return == :Any)
      node.return_type = final_return_type
      signature[:return][:type] = final_return_type
    end

    signature[:return_strategy] = get_return_strategy(signature[:return][:type])
    node.full_type = signature
    node.uses_frame = (@frame_usage_count > 0)
    @function_context_stack.pop
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
  def validate_union_methods!(node)
    union_name = node.name

    # Phase 5: detect duplicate method stub declarations in the same UNION.
    seen_names = {}
    node.methods.each do |req|
      if seen_names.key?(req[:name])
        error!(req[:token], :UNION_METHOD_DUPLICATE, union_name, req[:name])
      end
      seen_names[req[:name]] = true
    end

    node.methods.each do |req|
      fn_name = req[:name]
      req_tok = req[:token]
      req_vis = req[:visibility] || :package

      scope = lookup_scope_for(fn_name)
      local = scope&.locals&.[](fn_name)

      if local.nil?
        if req[:body]
          # No concrete override — synthesize a top-level function from the default body.
          # Synthesized function inherits the stub's declared visibility.
          fn_params = req[:params].map { |rp|
            { name: rp[:name], type: rp[:type], default: nil, mutable: false, takes: false }
          }
          fn_node = AST::FunctionDef.new(
            req[:token], req[:name], fn_params, [], req[:return_type],
            nil, req[:body], nil, nil, req_vis, nil, nil
          )
          @synthetic_fns << fn_node
          next  # signature will be pre-registered in visit_Program after this loop
        else
          error!(req_tok, :UNION_METHOD_MISSING, union_name, fn_name, fn_name)
        end
      end

      sig = local[:type]
      unless sig.is_a?(Hash) && sig.key?(:params)
        error!(req_tok, :UNION_METHOD_MISSING, union_name, fn_name, fn_name)
      end

      # Phase 4: visibility check — concrete function must match the stub's declared visibility.
      if req_vis != :package
        actual_vis = sig[:visibility] || :package
        unless actual_vis == req_vis
          vis_label = { pub: "PUB", private: "PRIVATE", package: "package" }
          error!(req_tok, :UNION_METHOD_WRONG_VISIBILITY,
                 union_name, fn_name, vis_label[req_vis], fn_name, vis_label[actual_vis])
        end
      end

      # Arity check
      if req[:params].length != sig[:params].length
        error!(req_tok, :UNION_METHOD_WRONG_ARITY,
               union_name, fn_name, req[:params].length, fn_name, sig[:params].length)
      end

      # Parameter type checks
      req[:params].each_with_index do |rp, i|
        req_t  = to_type(rp[:type]).resolved.to_s
        sig_t  = to_type(sig[:params][i][:type]).resolved.to_s
        unless req_t == sig_t || req_t == 'Any' || sig_t == 'Any'
          error!(req_tok, :UNION_METHOD_PARAM_TYPE,
                 union_name, fn_name, i + 1, req_t, fn_name, sig_t)
        end
      end

      # Return type check
      if req[:return_type]
        req_ret = to_type(req[:return_type]).resolved.to_s
        sig_ret = to_type(sig[:return][:type]).resolved.to_s
        unless req_ret == sig_ret || req_ret == 'Any' || sig_ret == 'Any'
          error!(req_tok, :UNION_METHOD_RETURN_TYPE,
                 union_name, fn_name, req_ret, fn_name, sig_ret)
        end
      end
    end
  end

  def visit_UnionVariantLit(node)
    schema = lookup_type_schema(node.union_name.to_sym)
    if schema.nil?
      error!(node, "Unknown union type: '#{node.union_name}'")
    end
    unless schema.is_a?(Hash) && schema[:kind] == :union
      error!(node, "Type Error: '#{node.union_name}' is not a union type.")
    end
    unless schema[:variants].key?(node.variant_name)
      error!(node, :UNION_UNKNOWN_VARIANT, node.union_name, node.variant_name)
    end

    var_data = schema[:variants][node.variant_name]
    unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
      if var_data.nil?
        error!(node, "Union variant '#{node.variant_name}' is a unit variant — use '#{node.union_name}.#{node.variant_name}' (no fields).")
      else
        error!(node, "Union variant '#{node.variant_name}' takes a single typed payload — use '#{node.union_name}{ #{node.variant_name}: value }' instead.")
      end
    end

    expected_fields = var_data[:fields]

    # Check for unknown fields
    node.fields.each_key do |fname|
      unless expected_fields.key?(fname)
        error!(node, :UNION_INLINE_VARIANT_UNKNOWN_FIELD, node.union_name, node.variant_name, fname)
      end
    end

    # Check for missing required fields
    expected_fields.each_key do |fname|
      unless node.fields.key?(fname)
        error!(node, :UNION_INLINE_VARIANT_MISSING_FIELD, node.union_name, node.variant_name, fname)
      end
    end

    # Type-check each field value
    node.fields.each do |fname, val_node|
      visit(val_node)
      expected_type = expected_fields[fname]
      actual = val_node.type_info
      unless expected_type.accepts?(actual)
        error!(node, :UNION_INLINE_VARIANT_TYPE_MISMATCH,
               node.union_name, node.variant_name, fname,
               expected_type.resolved, actual&.resolved)
      end
    end

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
    initial_state = current_scope.clone_states
    branch_states = []
    all_drops = []

    branches.each do |branch_logic|
      current_scope.var_states = initial_state.dup
      with_new_scope(current_scope) do
        all_drops << branch_logic.call
        branch_states << current_scope.var_states.dup
      end
    end

    # Merge States: If a variable died in ANY branch, it must be considered dead in the parent.
    if merge_to_parent
      initial_state.each_key do |var|
        if branch_states.any? { |bs| bs[var] != :live }
          current_scope.set_state(var, :moved)
        end
      end
    else
      # Just restore the initial state if merging is disabled (e.g. for WHILE loops)
      current_scope.var_states = initial_state
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
    primitives = [:Number, :Bool, :Byte, :Int64, :Float64, :String, :NIL, :BOOLEAN, :Any, :Void]

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

      visit(f[:value])

      if schema
        field_type = schema[f[:name]]&.resolved
        val_type   = f[:value].resolved_type
        unless val_type == field_type || val_type == :Any || field_type == :Any
          error!(match_node, "MATCH struct pattern: field '#{f[:name]}' has type #{field_type}, but pattern value has type #{val_type}")
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
    # e.g. Option<Number> → { T: :Number }
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
          # Allow union base type (e.g. :Option) to match a generic instance (e.g. :"Option<Number>")
          base_match = expr_t2.generic_instance? && expr_t2.generic_base == c[:value].resolved_type
          unless c[:value].resolved_type == node.expr.resolved_type ||
                 node.expr.resolved_type == :Any ||
                 c[:value].resolved_type == :Any ||
                 base_match
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
                  # Inline struct variant: bind to the synthetic struct type (e.g., Shape_Circle).
                  # Field access (c.radius) is resolved via the synthetic struct schema registered in visit_UnionDef.
                  synthetic_type = :"#{type_name}_#{variant_name}"
                  current_scope.declare(c[:binding], nil, Type.new(synthetic_type), false, false, nil, :stack)
                  current_scope.set_state(c[:binding], :live)
                else
                  payload_type = union_subst.any? ? apply_type_subst(raw_payload, union_subst) : Type.new(raw_payload)
                  current_scope.declare(c[:binding], nil, payload_type, false, false, nil, :stack)
                  current_scope.set_state(c[:binding], :live)
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

  def visit_WhileLoop(node)
    # 1. Analyze Condition
    visit(node.condition)

    if node.condition.resolved_type != :Bool
      error!(node, "Condition must be a Boolean, got #{node.condition.resolved_type}")
    end

    # 2. Analyze Body in a New Scope AND increment loop depth
    @loop_depth += 1
    
    # We use analyze_control_flow_branches to handle state merging and drops.
    # Note: For a loop, if a variable dies in the body, it dies for the next iteration (merged to parent).
    pre_loop_state = current_scope.clone_states
    
    analyze_control_flow_branches([
      proc {
        if node.do_branch.is_a?(Array)
          node.do_branch.each { |stmt| visit(stmt) }
        else
          visit(node.do_branch)
        end
        finalize_scope(node)
        
        # Post-analysis check for loop-specific errors (use of moved value in next iteration)
        current_scope.var_states.each do |name, new_state|
          old_state = pre_loop_state[name]
          if old_state == :live && new_state == :moved
            error!(node, "Use of moved value '#{name}' in loop. The variable is moved in the first iteration and not available for the next.")
          end
        end
        node.deferred_drops
      }
    ], merge_to_parent: false)

    @loop_depth -= 1
    node.full_type = :Void
  end

  def visit_BreakNode(node)
    if @loop_depth <= 0
      error!(node, "BREAK must be used inside a loop")
    end
    node.full_type = :Void
  end

  def visit_ContinueNode(node)
    if @loop_depth <= 0
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
    expected = @function_context_stack.last&.dig(:type)
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
    expected = @function_context_stack.last[:type]

    # 2. Ownership Tracking
    was_promoted = handle_return_escape(node.value, expected)
    @frame_usage_count -= 1 if was_promoted

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

    if @return_collection_stack.any?
      @return_collection_stack.last << {storage: node.value.storage, type: actual, metatype: node.value.metatype}
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

    # Pool method dispatch: intercept before UFCS so pool.insert/get/remove
    # resolve to the pool's own methods rather than global functions.
    obj_type = node.object.type_info
    if obj_type&.pool?
      return visit_PoolMethod(node, obj_type)
    end

    ufcs_args = [node.object] + node.args
    resolve_call(node, ufcs_args)
  end

  # Type-checks a method call on a Pool<T> and tags the node for transpilation.
  def visit_PoolMethod(node, pool_type)
    elem = pool_type.element_type
    case node.name
    when "insert"
      unless node.args.length == 1
        error!(node, "Pool.insert requires exactly 1 argument, got #{node.args.length}")
        return
      end
      arg_type = node.args[0].resolved_type
      unless arg_type == :Any || is_safe_autocast?(arg_type, elem.resolved)
        error!(node, "Pool.insert: argument type #{arg_type} does not match pool element type #{elem.resolved}")
      end
      node.pool_method = :insert
      node.full_type   = Type.new(:"Id<#{elem.resolved}>")

    when "get"
      unless node.args.length == 1
        error!(node, "Pool.get requires exactly 1 argument (an Id handle), got #{node.args.length}")
        return
      end
      node.pool_method = :get
      node.full_type   = Type.new(:"?#{elem.resolved}")

    when "remove"
      unless node.args.length == 1
        error!(node, "Pool.remove requires exactly 1 argument (an Id handle), got #{node.args.length}")
        return
      end
      node.pool_method = :remove
      node.full_type   = :Void

    when "count"
      unless node.args.empty?
        error!(node, "Pool.count takes no arguments, got #{node.args.length}")
        return
      end
      node.pool_method = :count
      node.full_type   = Type.new(:Int64)

    else
      error!(node, "Unknown method '#{node.name}' on Pool<#{elem.resolved}>. Available: insert, get, remove, count")
    end
  end

  # Shared logic for resolving function/method calls.
  # Handles intrinsics, user-defined functions, and lambdas uniformly.
  #
  # @param node [AST::FuncCall, AST::MethodCall] The call node
  # @param args [Array] The arguments (includes receiver for UFCS method calls)
  def resolve_call(node, args)
    func_name = node.name

    # 1. Look up function in scope
    scope = lookup_scope_for(func_name)
    unless scope
      error!(node, "Undefined function '#{func_name}'")
      return
    end

    func_type = scope.resolve_type(func_name)

    # 2. Dispatch based on function type
    if func_type == :Intrinsic
      visit_IntrinsicFunc(node, args)

    elsif func_type.is_a?(Hash)
      # Tag cross-module calls so the transpiler can qualify them (e.g. mod.fn(rt, ...))
      node.module_alias = func_type[:module_alias] if node.respond_to?(:module_alias=) && func_type[:module_alias]
      # Tag extern calls so the transpiler skips rt injection and try
      node.extern_call = true if node.respond_to?(:extern_call=) && func_type[:extern]

      type_params = func_type[:type_params]
      if type_params&.any?
        # Generic function: infer type args from actual arguments
        subst = infer_generic_type_args!(node, func_type, args, type_params)
        # Store inferred types on node so the transpiler can emit them
        node.generic_type_args = type_params.map { |tp| subst[tp] } if node.respond_to?(:generic_type_args=)
        # Build a substituted signature and validate with concrete types
        substituted = substitute_type_params(func_type, subst)
        call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
        verify_function_signature!(call_node, substituted)
        node.full_type = substituted[:return][:type]
      else
        # Named Function or Lambda (both use standard signature format)
        # Create synthetic node with correct args for UFCS method calls
        call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
        verify_function_signature!(call_node, func_type)
        node.full_type = func_type[:return][:type]
      end

    elsif func_type.is_a?(Symbol)
      node.full_type = func_type

    else
      error!(node, "Cannot call '#{func_name}' - not a function")
    end
  end

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
  end

  def visit_VarDecl(node)
    visit(node.value)

    verify_unrestricted!(node)
    handle_assign_move(node)
    handle_assign_borrow(node)

    # 1a. Reject ~T@multiOwned — promises are multi-fiber; only @shared is valid.
    if node.type.is_a?(Type) && node.type.tense? && node.type.multiowned?
      error!(node, "~T@multiOwned is not valid. Promises span fiber boundaries, so the ref-count must be atomic. Use ~T@shared instead.")
    end

    # 1b. Reject bare ~T[] — must specify [N], [INF], or [?].
    if node.type.is_a?(Type) && node.type.tense? && node.type.tense_type.array? && node.type.tense_type.dynamic?
      error!(node, "~T[] is not a valid stream type. Use ~T[N] for a bounded stream of N concurrent tasks, ~T[INF] for an infinite rendezvous stream, or ~T[?] for an open/closeable stream.")
    end

    # 1. Resolve final type (handles coercion check internally)
    final_type, error = node.value.coerce!(node.type)
    error!(node, error) if error

    # 2. Finalize Storage
    storage = node.finalize_storage!(final_type) { |name| lookup_type_schema(name) }
    @frame_usage_count += 1 if storage == :frame

    # 2a. Propagate collection + shard_count from declared type (lost during finalize_storage!)
    if (decl_t = node.type).is_a?(Type) && decl_t.collection
      node.type_info.collection  = decl_t.collection
      node.type_info.location    = :heap if decl_t.collection == :pool
      node.type_info.shard_count = decl_t.shard_count if decl_t.shard_count
    end

    # 2b. Check if the declared type is a pool, open/infinite stream, or resource — tag node and scope entry
    ft_obj          = node.type_info
    is_pool         = ft_obj&.pool?
    is_open_stream  = ft_obj&.open_stream?
    is_inf_stream   = ft_obj&.inf_stream?
    if is_pool
      resource_close = "{0}.deinit(rt.heapAlloc())"
      is_resource    = false
    elsif is_open_stream || is_inf_stream
      resource_close = "{0}.deinit()"
      is_resource    = false
    else
      resource_schema = lookup_type_schema(final_type)
      is_resource     = resource_schema&.dig(:kind) == :resource
      resource_close  = is_resource ? resource_schema[:close_zig] : nil
    end
    node.resource_close_zig = resource_close

    # 3. Declare in Scope (include sync capability if present)
    node_sync = node.type_info&.sync
    current_scope.declare(
      node.name,
      node,          # reg
      final_type,
      node.mutable,
      false,         # rebindable? usually false for VAR
      node.slot_size,
      storage,
      Set.new,       # capabilities
      [],            # borrowed_paths
      sync: node_sync,
      resource: is_resource || is_pool || is_open_stream || is_inf_stream,
      close_zig: resource_close
    )

    # 4. Set live
    current_scope.set_state(node.name, :live)
  end

  # Keywordless `x = val` or `x: Type = val`.
  # If x is not yet in scope → immutable declaration (like old VAR x = val).
  # If x is in scope and mutable → assignment (like old SET x = val).
  # If x is in scope and immutable → error.
  def visit_BindExpr(node)
    visit(node.value)

    scope = current_scope
    if !scope.locals.key?(node.name)
      # Declaration path
      node.mode = :decl

      verify_unrestricted!(node)
      handle_assign_move(node)
      handle_assign_borrow(node)

      validate_type_annotation!(node, node.type) if node.type

      # Reject ~T@multiOwned — promises are multi-fiber by nature; only @shared is valid.
      if node.type.is_a?(Type) && node.type.tense? && node.type.multiowned?
        error!(node, "~T@multiOwned is not valid. Promises span fiber boundaries, so the ref-count must be atomic. Use ~T@shared instead.")
      end

      # Reject bare ~T[] — must specify [N], [INF], or [?].
      if node.type.is_a?(Type) && node.type.tense? && node.type.tense_type.array? && node.type.tense_type.dynamic?
        error!(node, "~T[] is not a valid stream type. Use ~T[N] for a bounded stream of N concurrent tasks, ~T[INF] for an infinite rendezvous stream, or ~T[?] for an open/closeable stream.")
      end

      # For BgStreamBlock assigned to ~T[INF]: retype to ~T[INF] before coerce! so exact
      # match works (BgStreamBlock infers ~T[?] by default; ~T[INF] is a separate runtime type).
      if node.value.is_a?(AST::BgStreamBlock) && node.type.is_a?(Type) && node.type.inf_stream?
        elem_sym = begin
          node.value.full_type.tense_type.element_type.to_sym
        rescue
          :Void
        end
        node.value.full_type = :"~#{elem_sym}[INF]"
      end

      final_type, error = node.value.coerce!(node.type)
      error!(node, error) if error

      # Propagate @shared ownership into the BgBlock so the transpiler emits
      # SharedPromise.spawn() instead of Promise.spawn().
      if node.value.is_a?(AST::BgBlock) && node.type.is_a?(Type) && node.type.shared_promise?
        node.value.full_type = Type.new(node.value.full_type, ownership: :shared)
      end

      storage = node.finalize_storage!(final_type) { |n| lookup_type_schema(n) }
      @frame_usage_count += 1 if storage == :frame

      # Propagate collection + shard_count from declared type (lost during finalize_storage!)
      if (decl_t = node.type).is_a?(Type) && decl_t.collection
        node.type_info.collection  = decl_t.collection
        node.type_info.location    = :heap if decl_t.collection == :pool
        node.type_info.shard_count = decl_t.shard_count if decl_t.shard_count
      end

      ft_obj          = node.type_info
      is_pool         = ft_obj&.pool?
      is_open_stream  = ft_obj&.open_stream?
      is_inf_stream   = ft_obj&.inf_stream?
      if is_pool
        resource_close = "{0}.deinit(rt.heapAlloc())"
        is_resource    = false
      elsif is_open_stream || is_inf_stream
        resource_close = "{0}.deinit()"
        is_resource    = false
      else
        resource_schema = lookup_type_schema(final_type)
        is_resource     = resource_schema&.dig(:kind) == :resource
        resource_close  = is_resource ? resource_schema[:close_zig] : nil
      end
      node.resource_close_zig = resource_close

      node_sync = node.type_info&.sync
      current_scope.declare(
        node.name,
        node,
        final_type,
        false,   # immutable
        false,
        node.slot_size,
        storage,
        Set.new,
        [],
        sync: node_sync,
        resource: is_resource || is_pool || is_open_stream || is_inf_stream,
        close_zig: resource_close
      )
      current_scope.set_state(node.name, :live)

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

      current_scope.set_state(node.name, :live)
    end
  end

  def visit_Identifier(node)
    if @smooth_depth > 0
      scope = lookup_scope_for(node.name)
    else
      scope = current_scope
      if !scope.locals.key?(node.name)
        error!(node, "Undefined variable '#{node.name}'")
      end
    end

    # 1. Check Validity (View Invalidation Logic)
    # If this is a view/slice that was invalidated by a resize, this raises.
    scope.check_validity!(node.name)

    # 2. Resolve Type
    node.full_type = scope.resolve_full_type(node.name)

    # 3. Liveness
    state = scope.get_state(node.name)
    type = scope.resolve_type(node.name)

    if state == :moved
      # TODO: Better error
      error!(node, "Use of moved value '#{node.name}'")
    end
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
    current_scope.set_state(target_name, :live)
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
  end

  def visit_assignment_index(index_node, assignment_node)
    # 1. Analyze the access itself (resolves types, checks bounds if possible)
    visit(index_node)

    # 2. Check Mutability of the owner
    #    If we are doing x[0] = 1, 'x' must be mutable.
    if index_node.target.is_a?(AST::Identifier)
      var_name = index_node.target.name
      if current_scope.is_immutable?(var_name)
        # matches your test expectation
        error!(assignment_node, "Cannot modify index of immutable list '#{var_name}'")
      end
    end

    # 3. Type Check
    #    The value being assigned must match the type of the index
    validate_assignment_type(assignment_node, index_node.resolved_type, assignment_node.value.resolved_type)

    assignment_node.full_type = index_node.full_type
  end

  def visit_assignment_field(field_node, assignment_node)
    # 1. Analyze field access
    visit(field_node)

    # 2. Check Mutability of the owner
    if field_node.target.is_a?(AST::Identifier)
      var_name = field_node.target.name
      if current_scope.is_immutable?(var_name)
        error!(assignment_node, "Cannot modify field of immutable struct '#{var_name}'")
      end
    end

    # 3. Type Check
    validate_assignment_type(assignment_node, field_node.resolved_type, assignment_node.value.resolved_type)

    assignment_node.full_type = field_node.full_type
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

    # Case 1: HashMap Access
    if target_type_info.map?
      node.full_type = target_type_info.value_type

      # Validate Key Type
      # Allow String (stack), %String (heap), or Byte[] (raw)
      index_type_info = node.index.type_info
      unless index_type_info&.string?
         error!(node, "Map keys must be Strings, got #{node.index.resolved_type}")
      end

    # Case 2: Array Access "Number[]" -> :Number, "Number[][]" -> "Number[]"
    elsif target_type_info.array? || node.target.metatype == :struct
      node.full_type = target_type_info.element_type

    else
      error!(node, "Unsupported Index")
    end
  end

  def visit_GetField(node)
    # Enum/Union variant access: TypeName.Variant
    # Must be checked BEFORE visiting target to avoid "variable not found" error.
    if node.target.is_a?(AST::Identifier)
      type_name = node.target.name.to_sym
      schema = lookup_type_schema(type_name)
      if schema.is_a?(Hash) && schema[:kind] == :enum
        unless schema[:variants].include?(node.field)
          error!(node, :ENUM_UNKNOWN_VARIANT, type_name, node.field)
        end
        node.target.full_type = type_name
        node.full_type = type_name
        return
      end
      if schema.is_a?(Hash) && schema[:kind] == :union
        unless schema[:variants].key?(node.field)
          error!(node, :UNION_UNKNOWN_VARIANT, type_name, node.field)
        end
        var_data = schema[:variants][node.field]
        if var_data.is_a?(Hash) && var_data[:kind] == :inline_struct && !@match_pattern_context
          error!(node, :UNION_INLINE_VARIANT_NEEDS_BRACES, type_name, node.field, type_name, node.field)
        end
        node.target.full_type = type_name
        node.full_type = type_name
        return
      end
    end

    visit(node.target)

    # Check if this path has been moved
    path = get_path_to_root(node)
    if path
      root_name = path.first.to_s
      scope = lookup_scope_for(root_name)
      if scope&.is_path_moved?(path)
        error!(node, "Use of moved value '#{path.join(".")}'")
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
    # e.g. Pair<Number>{ first: 1.0 } → { :T => :Number }
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

    unless [:Number, :Int64, :Byte].include?(start_type)
      error!(node, "Range start must be a numeric type, got #{start_type}")
    end

    unless [:Number, :Int64, :Byte].include?(finish_type)
      error!(node, "Range end must be a numeric type, got #{finish_type}")
    end

    # Coerce integer types to Number (f64) for uniform Range representation
    node.start.coerced_type = :Number if [:Int64, :Byte].include?(start_type)
    node.finish.coerced_type = :Number if [:Int64, :Byte].include?(finish_type)

    node.full_type = :Range
  end

  def visit_Literal(node)
    node.full_type =
      case node.type
      when :NUMBER then :Number
      when :INT64 then :Int64
      when :STRING
        if node.storage == :stack
          :"Byte[#{node.value.length}]"
        else
          Type.new(Type::STRING_TYPE, location: :heap)
        end
      when :BYTE then :Byte
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

    # Standard OR behavior
    # Type Safety: Usually we want them to match.
    # If LHS is "Number?" (Nullable), RHS must be "Number".
    if t_left_type.resolved == t_right_type.resolved
      node.full_type = t_left_type.resolved
    else
      # If types mismatch, it might be :Any, or you could support Union types
      # For this stage, default to the LHS type or :Any
      node.full_type = t_left_type.resolved
    end
  end

  def visit_OrRaise(node)
    # This is a marker node for OR RAISE - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    node.full_type = :Void
  end

  def visit_OrPass(node)
    # This is a marker node for OR PASS - no type annotation needed
    # The actual type handling is done in visit_OrRescue
    node.full_type = :Void
  end

  def visit_CapabilityWrap(node)
    visit(node.value)

    base_type = node.value.resolved_type  # e.g. :Node
    ti = Type.new(base_type)
    ti.ownership = node.ownership if node.ownership
    ti.sync      = node.sync      if node.sync

    # Store the Type directly — full_type= accepts Type objects
    node.full_type = ti
  end

  def visit_MoveNode(node)
    visit(node.value)

    unless node.value.is_a?(AST::Identifier)
      error!(node, "MOVE can only be applied to a variable identifier")
    end

    ti = node.value.type_info
    unless ti&.multiowned? || ti&.shared?
      error!(node, "MOVE can only be applied to @multiowned or @shared variables, got '#{node.value.resolved_type}'")
    end

    # Inherit the capability type so the VarDecl or ReturnNode can infer storage correctly
    node.full_type = node.value.full_type
    node.storage   = node.value.storage

    # Consume the source variable — it is affinely transferred
    current_scope.set_state(node.value.name, :moved)
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
      current_scope.set_state(root.name, :moved)
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
    node.full_type = type.wrapped_type.resolved
  end

  def visit_WithBlock(node)
    # 1. Validate each capability's variable exists and resolve its type
    expanded_capabilities = []

    node.capabilities.each do |cap|
      var_node = cap[:var_node]
      visit(var_node)
      cap[:resolved_type] = var_node.full_type
      
      # For node.*, var_node.name will correctly return the root variable name
      # because it's a GetField on Identifier.
      cap[:old_scope] = lookup_scope_for(var_node.name)

      # Infer capability from the variable's storage when not stated explicitly
      if cap[:capability] == :infer
        scope = lookup_scope_for(var_node.name)
        storage = scope&.locals&.dig(var_node.name, :storage)
        syn     = scope&.locals&.dig(var_node.name, :sync)
        cap[:capability] = case
                           when storage == :multiowned    then :multiowned
                           when storage == :shared        then :shared
                           when syn == :locked            then :EXCLUSIVE
                           when syn == :write_locked      then :write_locked_read
                           else
                             error!(node, "WITH #{var_node.name}: cannot infer capability; variable must be @multiowned, @shared, @locked, @writeLocked, or another capability type")
                             :unknown
                           end
      end

      validate_capability(node, cap[:capability], var_node)

      # Handle Wildcard Borrow: WITH RESTRICT node.* { ... }
      if var_node.is_a?(AST::GetField) && var_node.wildcard?
        # Retrieve the struct's schema for the target
        target_type = var_node.target.resolved_type
        schema = lookup_type_schema(target_type)
        
        unless schema
          error!(node, "Wildcard borrow '*' requires a struct type, but '#{var_node.target.name}' is #{target_type}")
        end

        schema.each do |field_name, _|
          # Create a synthetic GetField for each field in the struct
          field_node = AST::GetField.new(var_node.token, var_node.target, field_name)
          expanded_capabilities << {
            capability: cap[:capability],
            var_node: field_node,
            old_scope: cap[:old_scope]
          }
        end
      else
        expanded_capabilities << cap
      end
    end

    # 2. Enter a new scope for the capability block
    # This isolates any variables declared inside
    with_new_scope do
      expanded_capabilities.each do |cap|
        var_name = cap[:var_node].name
        syn = cap[:old_scope]&.locals&.dig(var_name, :sync)
        if syn && !cap[:var_node].is_a?(AST::GetField)
          # Locked: acquire gives mutable access to the inner T.
          # Declare the alias (if given) as the plain inner type.
          inner_type = cap[:old_scope].resolve_type(var_name)  # e.g. :Node
          alias_name = cap[:alias] || var_name
          current_scope.declare(alias_name, nil, inner_type, true, false, nil, :stack)
          current_scope.set_state(alias_name, :live)
          # Also re-declare the locked var itself so it stays accessible in scope
          current_scope.declare_with_new_capability(cap)
        else
          current_scope.declare_with_new_capability(cap)
        end
      end
      node.body.each { |stmt| visit(stmt) }
      finalize_scope(node)
    end

    node.full_type = :Void
  end

  def visit_DoBlock(node)
    # Each branch runs in a separate fiber (fork-join).
    # Visit branches independently — no ownership transfer between parallel branches.
    # branches: Array of { body: Array<ASTNode>, pinned: Boolean }
    node.branches.each do |branch|
      branch[:body].each { |expr| visit(expr) }
    end
    node.full_type = :Void
  end

  def visit_BgStreamBlock(node)
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
    # Affine variables captured from the enclosing scope are MOVED (not borrowed),
    # because the caller may return before the fiber finishes.
    last_type = :Void
    node.body.each do |expr|
      visit(expr)
      last_type = expr.respond_to?(:full_type) ? (expr.full_type || :Void) : :Void
    end
    node.full_type = :"~#{last_type}"
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
        scope = lookup_scope_for(node.expr.name)
        scope&.set_state(node.expr.name, :moved)
      end
      node.full_type = promise_type.tense_type.to_sym
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


  def validate_capability(node, capability_type, var_node)
    var_type = var_node.full_type
    if !var_node.is_a?(AST::Identifier) && !var_node.is_a?(AST::GetField)
      error!(var_node, "WITH #{capability_type} expects an identifier or field, got '#{var_node.class}'.")
    end

    case capability_type
    when :EXCLUSIVE
      scope = lookup_scope_for(var_node.name)
      syn = scope&.locals&.dig(var_node.name, :sync)
      unless syn
        storage = scope&.locals&.dig(var_node.name, :storage)
        error!(node, "EXCLUSIVE capability requires a @locked or @writeLocked variable, got #{storage || 'unknown'}")
      end

    when :write_locked_read
      scope = lookup_scope_for(var_node.name)
      syn = scope&.locals&.dig(var_node.name, :sync)
      unless syn == :write_locked
        error!(node, "WITH #{var_node.name}: read access requires a @writeLocked variable")
      end

    when :RESTRICT
      # TODO: RESTRICT only mutables for now. Probably want to allow anything, as it doesn't matter.
      scope = lookup_scope_for(var_node.name)
      if scope && scope.is_immutable?(var_node.name)
        error!(node, "EXCLUSIVE capability requires a mutable variable, but '#{var_node.name}' is immutable")
      end

    when :multiowned
      scope = lookup_scope_for(var_node.name)
      unless scope&.locals&.dig(var_node.name, :storage) == :multiowned
        error!(node, "WITH #{var_node.name}: expected a @multiowned variable")
      end

    when :shared
      scope = lookup_scope_for(var_node.name)
      unless scope&.locals&.dig(var_node.name, :storage) == :shared
        error!(node, "WITH #{var_node.name}: expected a @shared variable")
      end

    else
      error!(node, "Unknown capability type: #{capability_type}")
    end
  end

  # Validates a type annotation where generics are involved.
  # Called whenever a user-written type annotation is resolved (variable decls, params, returns).
  # Covers four cases:
  #   1. Generic type used correctly: Pair<Number>    — validate arg count + arg types
  # Generic helpers (validate_type_annotation!, infer_generic_type_args!, etc.)
  # live in src/generic_analysis.rb (included via GenericAnalysis module).

end

