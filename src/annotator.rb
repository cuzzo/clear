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
  end

  # Helper to get the top-most scope
  def current_scope
    @scope_stack.last
  end

  # Helper to look up a variable by walking down the stack
  def lookup_scope_for(name)
    # Search from Top (last) to Bottom (first)
    @scope_stack.reverse_each do |scope|
      return scope if scope.resolve_type(name) != :Any || scope.locals.key?(name)
    end
    nil
  end

  def lookup_type_schema(name)
    # Search from Top (newest) to Bottom (global)
    @scope_stack.reverse_each do |scope|
      # Assuming your Scope class has resolve_type_definition
      schema = scope.resolve_type_definition(name)
      return schema if schema
    end
    nil
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

  # ==========================================
  # SCOPE MANAGEMENT
  # ==========================================

  def with_new_scope(scope = nil)
    new_scope = scope.nil? ? Scope.new : scope.dup
    @scope_stack.push(new_scope)
    yield
    @scope_stack.pop
  end

  def is_global_scope?(scope)
    # Assuming the first scope in the stack is global
    scope == @scope_stack.first
  end

  # TODO: Implement return_strategy for lambdas
  # TODO: Implement force heap for USE
  def visit_LambdaLit(node)
    # 1. Analyze Captures (Before entering the new scope)
    # We need to look up the types of variables being captured from the OUTER scope.
    # The Transpiler needs these types to build the 'Closure Struct'.
    verify_captures!(node)

    # 2. Enter the Lambda's Scope
    with_new_scope do
      param_types = declare_and_verify_params(node)
      declare_captures(node)

      @return_collection_stack.push([])

      # 5. Analyze the Body
      # The body is usually an AST::Node (expression) or Array (statements)
      if node.body.is_a?(Array)
        node.body.each { |stmt| visit(stmt) }
        found_returns = @return_collection_stack.pop().uniq.map { |r| r[:type] }
        verify_returns(node, found_returns, :Any) # TODO: get declared_return
        return_type = found_returns.any? ? found_returns.first : :Any
      else
        visit(node.body)
        return_type = node.body.resolved_type
        @return_collection_stack.pop()
      end

      # 6. Annotate the Node
      # We construct a type signature: [:Proc, [ArgTypes], ReturnType]
      # Zig Transpiler will use this to generate: fn call(self, args...) ReturnType
      node.full_type = [:Proc, param_types, return_type] # , return_strategy]
    end
  end

  def visit_FunctionDef(node)
    @frame_usage_count = 0

    # 1. Distinguish between Implicit (nil) and Explicit (:Any) return types
    is_implicit_return = node.return_type.nil?
    declared_return = node.return_type || :Any

    lifetime_path = get_lifetime_path(node)
    @function_context_stack.push({type: declared_return, lifetime: lifetime_path})

    # 2. Check Style (unchanged)
    has_mutable_param = node.params.any? { |p| p[:mutable] }
    if has_mutable_param && !node.name.end_with?("!")
      error!(node, "Style Error: Function '#{node.name}' has MUTABLE parameters. Its name must end in '!'")
    end

    # Must happen BEFORE new scope
    verify_captures!(node)
    verify_lifetime!(node)

    # 3. Build Signature
    # ENSURE this hash is never nil
    signature = {
      params: node.params.map { |p| {
        name: p[:name],
        type: p[:type],
        required: p[:default].nil?,
        mutable: p[:mutable],
        takes: p[:takes]
      }},
      return: {
        type: declared_return,
        lifetime: lifetime_path
      }
    }

    # This overwrites the Pass 2 declaration. We must ensure signature is valid.
    current_scope.declare(node.name, nil, signature, false, false, nil, :static)

    # 4. Analyze Body & Track Returns
    @return_collection_stack.push([])

    with_new_scope do
      # Register Parameters
      declare_and_verify_params(node)
      declare_captures(node)

      # Visit Body
      node.body.each { |stmt| visit(stmt) }

      finalize_scope(node)
    end

    # 5. Process Returns (The inference logic from the previous fix)
    found_returns = @return_collection_stack.pop.uniq
    verify_returns(node, found_returns, is_implicit_return ? nil : declared_return)

    # B. Inference Update
    # If Implicit (nil) OR Explicitly :Any, try to narrow.
    if (is_implicit_return || declared_return == :Any) && found_returns.any?
      inferred = found_returns.first[:type]

      # Only narrow if we are sure (Implicit always narrows, Any only narrows if unique)
      if is_implicit_return || found_returns.size == 1
        node.return_type = inferred

        # MUTATE the existing signature hash so the Scope entry updates automatically
        signature[:return][:type] = inferred
      end
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
  def visit_IfStatement(node)
    visit(node.condition)

    # 1. Snapshot state before branching
    initial_state = current_scope.clone_states

    # Each branch gets its own scope to prevent leaking vars
    with_new_scope(current_scope) do
      node.then_branch.each { |stmt| visit(stmt) }
      finalize_scope(node, branch: :then)
      @then_state = current_scope.var_states # Conceptual
    end

    current_scope.var_states = initial_state # restore_states(initial_state)

    with_new_scope(current_scope) do
      node.else_branch.each { |stmt| visit(stmt) }
      finalize_scope(node, branch: :else)
      @else_state = current_scope.var_states
    end

    # 2. MERGE STATES (The Affine Logic)
    # Iterate over all variables in the parent scope
    initial_state.each do |var, state|
      if @then_state[var] != :live || @else_state[var] != :live
        # If it died in EITHER branch, it is dead in the main scope.
        # (Because we can't be sure it's alive, we must assume it's unsafe to use)
        current_scope.set_state(var, :moved) # or :invalid
      end
    end
  end

  def visit_WhileLoop(node)
    # 1. Analyze Condition
    visit(node.condition)

    if node.condition.resolved_type != :Bool
      error!(node, "Condition must be a Boolean, got #{node.condition.resolved_type}")
    end

    pre_loop_state = current_scope.clone_states

    # 2. Analyze Body in a New Scope AND increment loop depth
    @loop_depth += 1
    with_new_scope(current_scope) do
      if node.do_branch.is_a?(Array)
        node.do_branch.each { |stmt| visit(stmt) }
      else
        visit(node.do_branch)
      end

      finalize_scope(node)

      current_scope.var_states.each do |name, new_state|
        old_state = pre_loop_state[name]

        # If it was defined outside (exists in old_state)
        # AND it was Live before
        # AND it is Moved now (consumed without replacement)
        if old_state == :live && new_state == :moved
          error!(node, "Use of moved value '#{name}' in loop. The variable is moved in the first iteration and not available for the next.")
        end
      end
    end
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

    # 2. Ownership Tracking
    # TODO: Move to ownership tracker
    root = get_root_object(node.value)
    if root.is_a?(AST::Identifier)
      var_name = root.name
      owner_scope = lookup_scope_for(var_name)
      if owner_scope
        type = owner_scope.resolve_type(var_name)
        if Type.new(type).requires_move?
          was_promoted = owner_scope.mark_escaped(var_name)
          if was_promoted
            @frame_usage_count -= 1
          end
        end
      end
    end

    actual = node.value.resolved_type
    expected = @function_context_stack.last[:type]

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
    # 1. Resolve Arguments First
    # We need to know arg types before we can figure out the result
    node.args.each { |arg| visit(arg) }

    # 2. Look up the Function in Scope
    func_type = nil

    # Handle "native_call" or other special AST quirks if you have them
    if node.name == "native_call"
      node.full_type = :Any
      return
    end

    scope = lookup_scope_for(node.name)
    if scope
      func_type = scope.resolve_type(node.name)
    else
      error!(node, :MISSING_FUNCTION, node.name)
    end

    # 3. Determine Return Type
    if func_type == :Intrinsic
      visit_IntrinsicFunc(node, node.args)
    elsif func_type.is_a?(Hash) # Named Function (Rich Signature)
      verify_function_signature!(node, func_type)
      node.full_type = func_type[:return][:type]
    elsif func_type.is_a?(Array) && func_type[0] == :Proc # Lambda/Proc
      # Extract return type from [:Proc, args, ret]
      node.full_type = func_type[2]
    elsif func_type.is_a?(Symbol)
      node.full_type = func_type
    else
      # Fallback
      node.full_type = :Any
    end
  end

  def visit_MethodCall(node)
    # 1. Analyze the 'Receiver' (Object) and the explicit arguments
    visit(node.object)
    node.args.each { |arg| visit(arg) }

    method_name = node.name

    # 3. Look up the function in the Scope
    scope = lookup_scope_for(method_name)

    # ERROR CHECK: If scope is nil, the function doesn't exist.
    if scope.nil?
      error!(node, "Undefined function '#{method_name}'")
    end

    func_type = scope.resolve_type(method_name)

    # 4. Validate types using the synthesized argument list
    ufcs_args = [node.object] + node.args
    if func_type == :Intrinsic
      visit_IntrinsicFunc(node, ufcs_args)
    elsif func_type.is_a?(Hash) # Named Function
      fake_call_node = Struct.new(:token, :name, :args).new(node.token, method_name, ufcs_args)
      verify_function_signature!(fake_call_node, func_type)
      node.full_type = func_type[:return][:type]
    elsif func_type.is_a?(Array) && func_type[0] == :Proc
      node.full_type = func_type[2]
    else
      error!(node, "Property '#{method_name}' is not a function")
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

  # Finds the first intrinsic overload that matches the given arguments.
  # Returns nil if no overload matches.
  def find_matching_intrinsic(definitions, args)
    definitions.find do |config|
      next true if config[:args] == :Varargs  # Varargs accepts anything

      # Arity check
      next false if args.size != config[:args].size

      # Type check each argument
      args.each_with_index.all? do |arg, i|
        expected = config[:args][i].is_a?(Hash) ? config[:args][i][:type] : config[:args][i]
        actual = arg.resolved_type
        is_safe_autocast?(actual, expected)
      end
    end
  end

  # Formats intrinsic args for error messages
  def format_intrinsic_args(args)
    return "(varargs)" if args == :Varargs
    types = args.map { |a| a.is_a?(Hash) ? a[:type] : a }
    "(#{types.join(', ')})"
  end

  def visit_VarDecl(node)
    visit(node.value)

    verify_unrestricted!(node)
    handle_assign_move(node)
    handle_assign_borrow(node)

    is_explicit = !node.type.nil? && node.type != :Any
    inferred_type = node.value.resolved_type
    final_type = is_explicit ? node.type : inferred_type

    # 1. Check Conflicts
    if node.type != inferred_type && is_explicit
      if !is_safe_autocast?(inferred_type, node.type)
        throw_assign_mismatch_error!(node, inferred_type, node.type)
      end
      node.value.coerced_type = final_type
    end

    # 2. Finalize Storage
    type_size = get_type_slot_size(final_type)
    storage = finalize_storage(node, final_type, type_size)
    if storage == :heap
      node.full_type = :"%#{final_type}"
    else
      node.full_type = final_type
    end
    # Set storage after full_type (which creates type_object)
    node.storage = storage

    # 3. Declare in Scope
    current_scope.declare(
      node.name,
      node,          # reg
      final_type,
      node.mutable,
      false,         # rebindable? usually false for VAR
      type_size,     # size (can infer from Literal if needed)
      storage
    )

    # 4. Set live
    current_scope.set_state(node.name, :live)
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

    target_type = node.target.full_type.to_s

    # Case 1: HashMap Access
    if node.target.metatype == :hashmap
      # Extract "Int64" from "HashMap<Int64>"
      match = target_type.match(/HashMap<(.+)>/)
      if match
        node.full_type = match[1].to_sym
      else
        node.full_type = :Any
      end

      # Validate Key Type
      # Allow String (stack), %String[] (heap), or Byte[] (raw)
      index_type_info = node.index.type_info
      unless index_type_info&.string?
         error!(node, "Map keys must be Strings, got #{node.index.resolved_type}")
      end

    # Case 2: Array Access "Number[]" -> :Number
    elsif node.target.metatype == :array || node.target.metatype == :struct
      node.full_type = node.target.base_type

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
        node.full_type = :"%Any[]"
      else
        node.full_type = :"Any[]"
      end
      return
    end

    # 2. Infer base type from the first element
    base_type = node.items.first.resolved_type

    # 3. Validate Consistency
    #    Strict check: All items must match the inferred base type.
    node.items.each_with_index do |item, index|
      next if index == 0 # Skip first
      if item.resolved_type != base_type
        error!(node, "List literal contains mixed types: First item is #{base_type}, item #{index+1} is #{item.resolved_type}")
      end
    end

    # TODO: Multi-dimensional arrays
    if node.storage == :stack
      node.full_type = :"#{base_type}[#{node.items.size}]"
    else
      node.full_type = :"%#{base_type}[]"
    end
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
          :"%#{Type::STRING_TYPE}"
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
    capabilities = node.capabilities.map do |cap|
      var_node = cap[:var_node]
      visit(var_node)
      cap[:resolved_type] = var_node.full_type
      cap[:old_scope] = lookup_scope_for(var_node.name)
      validate_capability(node, cap[:capability], var_node)
    end

    # 2. Enter a new scope for the capability block
    # This isolates any variables declared inside
    with_new_scope do
      node.capabilities.each { |cap| current_scope.declare_with_new_capability(cap) }
      node.body.each { |stmt| visit(stmt) }
      finalize_scope(node)
    end

    node.full_type = :Void
  end

  # ==========================================
  # BUILT-IN INFERENCE LOGIC
  # ==========================================

  def infer_map_return_type(args, node)
    # map(list, function)
    if args.size != 2
      error!(node, "map requires 2 arguments, #{args.size} given.}")
    end

    list_node = args[0]
    func_node = args[1]

    # 1. Resolve the Function's Return Type
    # We expect the function node to have a resolved_type of:
    # [:Fn, [ArgTypes], ReturnType]  OR  [:Proc, [ArgTypes], ReturnType]

    sig = func_node.full_type

    # Check if it's a valid signature array
    if sig.is_a?(Array) && (sig[0] == :Fn || sig[0] == :Proc)
      return_type = sig[2] # The 3rd element is the return type

      # 2. Construct the New List Type
      # map returns an array of whatever the function returns
      # e.g. Number -> Number[], String[] -> String[][]
      return :"#{return_type}[]"
    end

    # Fallback if we can't read the signature
    return :"Any[]"
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

  def finalize_storage(node, final_type, type_size)
    # TODO: Move this logic to type.rb
    # TODO: If over 64kb => automatic heap
    # TODO: SROA & SIMD analysis -> if possible -> stack
    if (node.value.storage.nil? || node.value.storage == :stack) && node.value.type_object.requires_move?
      if type_size > 128
        node.value.storage = :frame
      else
        node.value.storage = :stack
      end
    end

    # Get storage info
    # (Assuming your AST::Literal or Value nodes have a storage field)
    storage = node.value.respond_to?(:storage) ? node.value.storage : :stack
    # Default to stack if storage is nil (e.g., primitives)
    storage ||= :stack

    # Increment frame after storage finalized
    @frame_usage_count += 1 if storage == :frame

    return storage
  end

  def validate_capability(node, capability_type, var_node)
    var_type = var_node.full_type
    if !var_node.is_a?(AST::Identifier)
      error!(var_node, "WITH #{capability_type} expects an identifier, got '#{var_node.class}'.")
    end

    case capability_type
    when :EXCLUSIVE
      error!(node, "EXCLUSIVE capability requires a mutable variable, but '#{var_node.name}' is immutable")

    when :RESTRICT
      # TODO: RESTRICT only mutables for now. Probably want to allow anything, as it doesn't matter.
      scope = lookup_scope_for(var_node.name)
      if scope && scope.is_immutable?(var_node.name)
        error!(node, "EXCLUSIVE capability requires a mutable variable, but '#{var_node.name}' is immutable")
      end

    else
      error!(node, "Unknown capability type: #{capability_type}")
    end
  end

  # ==========================================
  # TYPE CHECKING & AUTOCAST LOGIC
  # ==========================================

  # Coerce input to Type object if needed
  def to_type(input)
    input.is_a?(Type) ? input : Type.new(input)
  end

  def is_safe_autocast?(source_type, target_type)
    to_type(target_type).accepts?(to_type(source_type))
  end

  def throw_assign_mismatch_error!(node, source_type, target_type)
    source = to_type(source_type)
    target = to_type(target_type)
    if target.array_overflow?(source)
      error!(node, :FIXED_ARRAY_SIZE_MISMATCH, target.capacity, source.resolved)
    else
      error!(node, "Type Mismatch: Cannot assign #{source.resolved} to #{node.type}")
    end
  end
end

