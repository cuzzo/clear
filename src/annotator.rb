require_relative "./source_error"
require_relative "./scope"
require_relative "./parser"
require_relative "./std_lib"
require_relative "./function_analysis"
require_relative "./pipe_analysis"
require_relative "./ownership_tracker"

# Handle Type inference, and semantic validation
class SemanticAnnotator
  include ErrorHelper
  include FunctionAnalysis
  include PipeAnalysis
  include OwnershipTracker
  include ScopeHelper
  include TypeHelper

  attr_reader :scope_stack

  def initialize
    # We start with a global scope
    @scope_stack = [Scope.new]
    @function_context_stack = [] # Stack of expected return types
    @return_collection_stack = [] # Track actual returns found in current function/lambda
    @loop_depth = 0 # Track if we are inside a loop
    @smooth_depth = 0
    @frame_usage_count = 0
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
  end

  def visit(node)
    return unless node
    return if node.is_a?(Symbol)

    # Dynamic Dispatch
    method_name = "visit_#{node.class.name.split('::').last}"
    send(method_name, node)
  end

  def visit_Program(node)
    # PASS 1: Hoist Types (StructDefs)
    # Register all struct types first so they can be used in function signatures.
    node.statements.each do |stmt|
      visit(stmt) if stmt.is_a?(AST::StructDef)
    end

    # PASS 2: Hoist Function Signatures
    # Register function signatures in the global scope.
    # This allows functions to call other functions defined later in the file.
    node.statements.each do |stmt|
      pre_register_function(stmt) if stmt.is_a?(AST::FunctionDef)
    end

    # PASS 3: Analyze Logic
    # Visit all statements in order.
    # - VarDecls will be registered here (linear scoping).
    # - FunctionDefs will be visited "fully" here (analyzing their bodies).
    node.statements.each do |stmt|
      # Skip Structs (done in Pass 1) to avoid redundant work,
      # though re-visiting them is harmless.
      next if stmt.is_a?(AST::StructDef)

      visit(stmt)
    end

    # Determine Program Result Type (Type of the last statement)
    if node.statements.any?
      node.full_type = node.statements.last.full_type
    else
      node.full_type = :Void
    end
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
      }
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
    @function_context_stack.push({type: declared_return, lifetime: lifetime_path})

    # 2. Validation & Lifetime
    has_mutable_param = node.params.any? { |p| p[:mutable] }
    if has_mutable_param && !node.name.end_with?("!")
      error!(node, "Style Error: Function '#{node.name}' has MUTABLE parameters. Its name must end in '!'")
    end
    verify_lifetime!(node)

    # 3. Pre-declaration (so the function can be recursive)
    signature = {
      params: node.params.map { |p| {
        name: p[:name], type: p[:type], required: p[:default].nil?, mutable: p[:mutable], takes: p[:takes]
      }},
      return: { type: declared_return, lifetime: lifetime_path }
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
    # 1. Register the Type Name (e.g., "Config")
    # We store the field definition so we can validate field access later
    schema = node.fields.transform_values { |f| f[:type] }

    # Register as a Type, not a Variable
    current_scope.declare_type(node.name.to_sym, schema)

    node.full_type = :Void # Struct defs don't return values
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
          visit(c[:value])
          unless c[:value].resolved_type == node.expr.resolved_type ||
                 node.expr.resolved_type == :Any ||
                 c[:value].resolved_type == :Any
            error!(node, "MATCH case type #{c[:value].resolved_type} does not match expression type #{node.expr.resolved_type}")
          end
        end
        c[:body].each { |s| visit(s) }
        collect_scope_drops
      }
    end

    if node.default_case
      branch_logic << proc {
        node.default_case.each { |s| visit(s) }
        collect_scope_drops
      }
    end

    all_drops = analyze_control_flow_branches(branch_logic)

    if node.default_case
      node.default_drops = all_drops.pop
    end
    node.case_drops = all_drops

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

    ufcs_args = [node.object] + node.args
    resolve_call(node, ufcs_args)
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
      # Named Function or Lambda (both use standard signature format)
      # Create synthetic node with correct args for UFCS method calls
      call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
      verify_function_signature!(call_node, func_type)
      node.full_type = func_type[:return][:type]

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

    # 3. Resolve return type (may be dynamic via method call)
    ret = matched_def[:return]
    if ret.is_a?(Symbol) && respond_to?(ret, true)
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

    # 1. Resolve final type (handles coercion check internally)
    final_type, error = node.value.coerce!(node.type)
    error!(node, error) if error

    # 2. Finalize Storage
    storage = node.finalize_storage!(final_type) { |name| lookup_type_schema(name) }
    @frame_usage_count += 1 if storage == :frame

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
      sync: node_sync
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

      final_type, error = node.value.coerce!(node.type)
      error!(node, error) if error

      storage = node.finalize_storage!(final_type) { |n| lookup_type_schema(n) }
      @frame_usage_count += 1 if storage == :frame

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
        sync: node_sync
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
      # Allow String (stack), %String[] (heap), or Byte[] (raw)
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
    if schema && schema[node.field]
      node.full_type = schema[node.field]
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

    # 2. Iterate Fields (Validation)
    # Unlike Compiler, we don't need to merge defaults for code gen,
    # we just need to verify that provided fields match the schema.
    node.fields.each do |field_name, val_node|
      visit(val_node) # Resolve value type

      expected_type = schema[field_name]
      if expected_type.nil?
        error!(node, "Struct '#{node.name}' has no field '#{field_name}'")
      end

      # Simple Type Check
      if val_node.full_type != expected_type
        unless is_safe_autocast?(val_node.resolved_type, expected_type)
          error!(node, "Field '#{field_name}' expected #{expected_type}, got #{val_node.resolved_type}")
        end
        val_node.coerced_type = expected_type
      end
    end

    node.full_type = node.name.to_sym
  end

  def visit_ListLit(node)
    # 1. Analyze all items
    node.items.each { |item| visit(item) }

    if node.items.empty?
      if node.storage == :heap
        node.full_type = Type.new(:"Any[]", location: :heap)
      else
        node.full_type = :"Any[]"
      end
      return
    end

    # 2. Infer base type from the first element.
    #    If all items are string-like (Byte[N] or String[]), widen to String[] so mixed
    #    string lengths ("a", "bb", "ccc") don't produce a type error.
    if node.items.all? { |i| Type.new(i.resolved_type).string? }
      base_type = Type::STRING_TYPE
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
    node.branches.each do |branch|
      branch.each { |expr| visit(expr) }
    end
    node.full_type = :Void
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

end

