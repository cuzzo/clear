require_relative "./source_error"
require_relative "./scope"
require_relative "./parser"
require_relative "./std_lib"

# Handle Type inference, and semantic validation
class SemanticAnnotator
  include ErrorHelper

  attr_reader :scope_stack

  STRING_TYPE = "String[]".to_sym
  HEAP_STRING_TYPE = "%String[]".to_sym

  def initialize
    # We start with a global scope
    @scope_stack = [Scope.new]
    @function_context_stack = [] # Stack of expected return types
    @return_collection_stack = [] # Track actual returns found in current function/lambda
    @loop_depth = 0 # Track if we are inside a loop
    @smooth_depth = 0
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
    current_scope.declare("argv", nil, STRING_TYPE, false, false, nil, :heap)
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
      return_type: (node.return_type || :Any)
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
    @scope_stack.push(scope || Scope.new)
    yield
    @scope_stack.pop
  end

  # TODO: Implement return_strategy for lambdas
  def visit_LambdaLit(node)
    # 1. Analyze Captures (Before entering the new scope)
    # We need to look up the types of variables being captured from the OUTER scope.
    # The Transpiler needs these types to build the 'Closure Struct'.
    verify_captures(node)

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
    # 1. Distinguish between Implicit (nil) and Explicit (:Any) return types
    is_implicit_return = node.return_type.nil?
    declared_return = node.return_type || :Any

    @function_context_stack.push(declared_return)

    # 2. Check Style (unchanged)
    has_mutable_param = node.params.any? { |p| p[:mutable] }
    if has_mutable_param && !node.name.end_with?("!")
      error!(node, "Style Error: Function '#{node.name}' has MUTABLE parameters. Its name must end in '!'")
    end

    # Must happen BEFORE new scope
    verify_captures(node)

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
      return_type: declared_return
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
        signature[:return_type] = inferred
      end
    end

    signature[:return_strategy] = get_return_strategy(node, found_returns, signature[:return_type])
    node.full_type = signature

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
    with_new_scope(current_scope.dup) do
      node.then_branch.each { |stmt| visit(stmt) }
      finalize_scope(node)
      @then_state = current_scope.var_states # Conceptual
    end

    current_scope.var_states = initial_state # restore_states(initial_state)

    with_new_scope(current_scope.dup) do
      node.else_branch.each { |stmt| visit(stmt) }
      finalize_scope(node)
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

  def finalize_scope(scope_node)
    # Look at all variables in the current scope
    current_scope.locals.each do |name, info|

      # We only care about variables that are:
      # 1. LIVE (Not moved yet)
      # 2. Linear (Have a destructor/need freeing)
      if current_scope.get_state(name) == :live && Type.new(info[:type]).requires_move?

        # AUTOMATICALLY INSERT DROP
        # In a transpiler, you might attach this metadata to the AST node
        # so the code generator knows to emit "free(x)" here.
        scope_node.deferred_drops << { name: name, type: info[:type] }

        # Mark as consumed so we don't double-free
        current_scope.set_state(name, :dropped)
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
    with_new_scope(current_scope.dup) do
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

  # ==========================================
  # VARIABLES & DEPENDENCIES
  # ==========================================

  def visit_ReturnNode(node)
    visit(node.value)
    actual = node.value.resolved_type
    expected = @function_context_stack.last

    if expected && expected != :Void && expected != :Any && actual != expected
      # Basic check (you might want to allow Number[3] -> Number[] coercion)
      unless is_safe_autocast?(actual, expected)
        error!(node, :RETURN_MISMATCH, expected, actual)
      end
      node.coerced_type = expected  # Don't coerce EXPLICIT returns
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
      verify_function_signature(node, func_type)
      node.full_type = func_type[:return_type]
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
      verify_function_signature(fake_call_node, func_type)
      node.full_type = func_type[:return_type]
    elsif func_type.is_a?(Array) && func_type[0] == :Proc
      node.full_type = func_type[2]
    else
      error!(node, "Property '#{method_name}' is not a function")
    end
  end

  def visit_IntrinsicFunc(node, args)
    definitions = STD_LIB[node.name]
    definitions = [definitions] if definitions.is_a?(Hash)

    matched_def = definitions.find do |config|
      # A. Arity Check
      next false if config[:args] != :Varargs && args.size != config[:args].size

      # B. Type Check
      match = true
      if config[:args] != :Varargs
        args.each_with_index do |arg, i|
          expected = config[:args][i]
          actual = arg.resolved_type

          # Use your existing safe casting check
          unless is_safe_autocast?(actual, expected)
            match = false
            break
          end
        end
      end
      match
    end

    # 3. Apply Result or Error
    if matched_def
      ret = matched_def[:return]

      if ret.is_a?(Symbol) && respond_to?(ret, true)
        node.full_type = send(ret, args, node)
      else
        node.full_type = ret
      end

      node.zig_pattern = matched_def[:zig]
    else
      # Build a nice error message listing expected signatures
      sigs = definitions.map { |d| "(#{d[:args].join(', ')})" }.join(" or ")
      arg_types = args.map { |a| a.resolved_type }.join(", ")
      error!(node, "No overload for '#{node.name}' matches arguments (#{arg_types}).\nCandidates: #{sigs}")
    end
  end

  def visit_VarDecl(node)
    visit(node.value)

    # 0. Affine Ownership:
    if node.value.is_a?(AST::Identifier)
      rhs_name = node.value.name
      rhs_type = current_scope.resolve_type(rhs_name)

      if Type.new(rhs_type).requires_move?
        current_scope.set_state(rhs_name, :moved)
      end
    end

    inferred_type = node.value.resolved_type
    final_type = (node.type == :Any) ? inferred_type : node.type

    # 1. Check Conflicts
    if node.type != inferred_type && node.type != :Any
      if !is_safe_autocast?(inferred_type, node.type)
        if check_array_type_mismatch!(node, inferred_type, node.type)
          ;
        else
          error!(node, "Type Mismatch: Cannot assign #{inferred_type} to #{node.type}")
        end
      end
      node.value.coerced_type = final_type
    end

    stack_size = get_type_slot_size(final_type)

    # 2. Get storage info
    # (Assuming your AST::Literal or Value nodes have a storage field)
    storage = node.value.respond_to?(:storage) ? node.value.storage : :stack

    # 3. Declare in Scope
    current_scope.declare(
      node.name,
      nil,           # reg
      final_type,
      node.mutable,
      false,         # rebindable? usually false for VAR
      stack_size,    # size (can infer from Literal if needed)
      storage
    )

    # 4. Set live
    current_scope.set_state(node.name, :live)

    if storage == :heap
      node.full_type = :"%#{final_type}"
    else
      node.full_type = final_type
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
    # 1. Analyze the Value (The Right-Hand Side)
    visit(node.value)

    # 2. Handle the Target (The Left-Hand Side)
    target = node.name

    # 1. Handle the Source (RHS)
    # If the RHS is an Identifier, and it's an Affine or Linear Type,
    # we must MOVE it.
    if node.value.is_a?(AST::Identifier)
      rhs_name = node.value.name
      rhs_type = current_scope.resolve_type(rhs_name)

      # Primitives COPY, everything else MOVES
      if Type.new(rhs_type).requires_move?
        current_scope.set_state(rhs_name, :moved)
      end
      type = current_scope.resolve_type(target.name)
    end

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
    return if target_type == :Any || value_type == :Any
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
      index_type = node.index.full_type
      is_string_key = index_type == :String ||
                      index_type.to_s == "%String[]" ||
                      index_type.to_s.start_with?("Byte[")

      unless is_string_key
         error!(node, "Map keys must be Strings, got #{index_type}")
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
    base_type = node.target.resolved_type.to_s
    if match = base_type.match(/^(\w+)\[.*\]$/)
      node.full_type = :"#{match[1]}[]"
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
          :"%#{STRING_TYPE}"
        end
      when :BYTE then :Byte
      when :BOOLEAN then :Bool
      else
        error!(node, "UNKNOWN LITERAL!")
      end
  end

  def visit_BinaryOp(node)
    case node.op
    when :SMOOTH then visit_Smooth(node)
    when :BIND_VAR then visit_BindVar(node)
    when :OR_RESCUE then visit_OrRescue(node)
    when :AND, :OR then visit_LogicalOp(node)
    when :ADD then visit_Add(node)
    else
      if AST::BOOL_RESULT_OPS.include?(node.op)
        visit(node.left)
        visit(node.right)
        node.full_type = :Bool
      elsif AST::NUMBER_RESULT_OPS.include?(node.op)
        visit(node.left)
        visit(node.right)
        node.full_type = :Number
      else
        error!(node, "UNKNOWN OPERAND!")
      end
    end
  end

  # =========================================================
  # SMOOTH OPERATOR (s>)
  # =========================================================
  def visit_Smooth(node)
    @smooth_depth += 1
    # Logic: x s> f  -> f(x)

    # 1. Visit the Left (Input) FIRST
    visit(node.left)

    if node.right.is_a?(AST::SelectOp) || node.right.is_a?(AST::WhereOp)
      if node.left.metatype != :array
        error!(node.left, "Cannot SELECT from non-list type #{node.left.resolved_type}")
      end
      item_type = node.left.resolved_type.to_s.gsub(/\[(\d+|\*)?\]$/, "").to_sym

      # B. Create a temporary Scope for the SELECT body
      with_new_scope do
        # Declare '_' with the specific item type
        current_scope.declare("_", nil, item_type, false, false, nil, :stack)

        # C. Analyze the Body (e.g., _["count"])
        visit(node.right.expression)

        if node.right.is_a?(AST::WhereOp) && node.right.expression.resolved_type != :Bool
          error!(node.right, "WHERE clause must evaluate to Bool")
        end
      end

      # D. Set Result Type (It returns a List of the Body's result)
      if node.right.is_a?(AST::SelectOp)
        result_base = node.right.expression.full_type
        node.full_type = :"%#{result_base}[]"
      elsif node.right.is_a?(AST::WhereOp)
        node.full_type = :"%#{item_type}[]"
      end

    elsif node.right.is_a?(AST::FuncCall)
      # Case 1: x s> f(y)  => f(x, y)
      # We intentionally modify the AST temporarily to leverage visit_FuncCall's
      # existing validation logic (arity, type checks, intrinsics).

      # A. Inject LHS as the first argument
      node.right.args.unshift(node.left)

      # B. Analyze the Function Call
      #    This will recursively visit node.left again, but since it's already
      #    resolved/declared, this is generally safe (idempotent).
      visit(node.right)

      # C. Restore AST
      node.right.args.shift

      # D. Propagate Result Type
      node.full_type = node.right.full_type

    elsif node.right.is_a?(AST::Identifier)
      # Case 2: x s> f  => f(x)
      # We must MANUALLY validate this because we aren't creating a FuncCall node.

      visit(node.right) # Resolves 'f' to its Signature/Type

      sig = node.right.full_type
      func_name = node.right.name

      if sig.is_a?(Hash)
        # --- Named Function ---
        # 1. Validate Arity: Must accept exactly 1 argument (the pipe input)
        params = sig[:params]
        min_args = params.count { |p| p[:required] }
        max_args = params.size

        if min_args < 1 || max_args > 1
           if min_args == max_args
             error!(node, :ARITY_MISMATCH, func_name, min_args, 1)
           else
             error!(node, :ARITY_MISMATCH_RANGE, func_name, min_args, max_args, 1)
           end
        end

        # 2. Validate Type: The Input must match Parameter 1
        if max_args >= 1
           param = params[0]
           expected = param[:type]
           actual = node.left.resolved_type

           # Use existing compatibility check
           unless is_safe_autocast?(actual, expected)
             # Check for Slice Coercion (e.g. Number[3] -> Number[])
             # This duplicates logic from verify_function_signature
             is_slice_match = expected.to_s.end_with?("[]") &&
                              actual.to_s.start_with?(expected.to_s.chomp("[]") + "[")

             unless is_slice_match
               error!(node.left, :ARGUMENT_TYPE_ERROR, "Pipe Input", 1, param[:name], expected, actual)
             end
           end
        end

        # 3. Set Result Type
        node.full_type = sig[:return_type]


      elsif sig.is_a?(Array) && sig[0] == :Proc
        # --- Lambda / Proc ---
        # Format: [:Proc, [ArgTypes], ReturnType]
        # TODO: Add validation for lambda arg types here if strictness is required
        node.full_type = sig[2]

      elsif sig == :Intrinsic || sig == :Nil
        # --- Builtin / Intrinsic ---
        # e.g. 'print' returns :Nil. 'map' returns :Intrinsic (resolved later via call).
        # Since we can't infer the return type of a generic :Intrinsic without arguments,
        # we default generics to :Any, but keep fixed builtins (like :Nil).
        node.full_type = (sig == :Intrinsic) ? :Any : sig

      else
        # --- Not a Callable ---
        error!(node, "Cannot pipe into non-callable '#{func_name}' (Resolved Type: #{sig})")
      end

    else
       # Case 3: Invalid RHS (e.g. 10 s> (expression))
       # The compiler likely crashes here, so we must raise an error.
       error!(node, "Invalid pipe destination. Must be a Function Call or Identifier.")
       node.full_type = :Any
    end

    @smooth_depth -= 1
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

    t_left = node.left.full_type
    t_right = node.right.full_type

    # Type Safety: Usually we want them to match.
    # If LHS is "Number?" (Nullable), RHS must be "Number".
    if t_left == t_right
      node.full_type = t_left
    else
      # If types mismatch, it might be :Any, or you could support Union types
      # For this stage, default to the LHS type or :Any
      node.full_type = t_left
    end
  end

  def visit_LogicalOp(node)
    visit(node.left)
    visit(node.right)

    # Boolean operators always return Bool
    node.full_type = :Bool
  end

  def visit_Add(node)
    visit(node.left)
    visit(node.right)

    t_left = node.left.resolved_type
    t_right = node.right.resolved_type

    # A. Int64 Optimization
    if t_left == :Int64 && t_right == :Int64
      node.full_type = :Int64

    # B. Float Propagation (Mixed Int/Number -> Number)
    elsif t_left == :Number || t_right == :Number
      node.full_type = :Number

      # Mark children for implicit casting if they are Ints
      if t_left == :Int64
        node.left.coerced_type = :Number
      end
      if t_right == :Int64
        node.right.coerced_type = :Number
      end

    # C. String Concatenation
    elsif t_left == HEAP_STRING_TYPE || t_right == HEAP_STRING_TYPE
      node.full_type = HEAP_STRING_TYPE

      # Cast non-string side to String
      if t_left != STRING_TYPE && is_safe_autocast(t_left, STRING_TYPE)
        node.left.coerced_type = STRING_TYPE
      end
      if t_right != STRING_TYPE && is_safe_autocast?(t_right, STRING_TYPE)
        node.right.coerced_type = STRING_TYPE
      end

    # D. Array Concatenation
    elsif t_left.to_s.end_with?("]") && t_right.to_s.end_with?("]")
      if t_left != t_right
        # We could allow Number[] + Number[3], but result is Number[]
        # For now, simplistic check:
        node.full_type = t_left
      else
        node.full_type = t_left
      end

    else
      error!(node, "Type Error: Cannot add type: #{type_left} and #{type_right}")
    end
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
      # If the function returns :String, map returns :String[]
      # We check if it's a primitive or complex type to format correctly
      if return_type.to_s.end_with?("]")
        # e.g. String[] -> String[][]
        return :"#{return_type}[]"
      else
        # e.g. Number -> Number[]
        return :"#{return_type}[]"
      end
    end

    # Fallback if we can't read the signature
    return :"Any[]"
  end

  def get_type_slot_size(type_name)
    type_obj = type_name.is_a?(Symbol) ? Type.new(type_name) : type_name
    type_obj.slot_size { |name| lookup_type_schema(name) }
  end

  def verify_function_signature(node, signature)
    params = signature[:params]
    min_args = params.count { |param| param[:required] }
    max_args = params.size
    given_args = node.args.size

    # A. Arity Check (Count)
    if given_args < min_args || given_args > max_args
      if min_args == max_args
        error!(node, :ARITY_MISMATCH, node.name, min_args, given_args)
      else
        error!(node, :ARITY_MISMATCH_RANGE, node.name, min_args, max_args, given_args)
      end
    end

    node.args.each_with_index do |arg_node, i|
      param = params[i]
      # B. Check mutability
      if param[:mutable]
        # Rule 1: Must be a Variable (Identifier), not a literal/expression
        if !arg_node.is_a?(AST::Identifier)
          error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_EXPRESSION, i+1, param[:name])
        end

        # Rule 2: The Variable being passed must be MUTABLE
        # We check the scope to see if the user declared it with 'MUTABLE'
        if current_scope.is_immutable?(arg_node.name)
          error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_MUTABLE, i+1, param[:name], arg_node.name)
        end
      end

      # C. Handle ownership (Affine / Linear):
      if param[:takes]
        # TODO: See if this is correct...
        current_scope.set_state(arg_node.name, :moved)
      end

      # D. Type Check
      expected = param[:type]
      actual = arg_node.resolved_type

      match = false

      # Case 1: Exact Match or Any
      if expected == :Any || actual == :Any || expected == actual
        match = true

      elsif is_safe_autocast?(actual, expected)
        node.coerced_type = expected
        match = true
      end

      unless match
        arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
        error!(arg_node, :ARGUMENT_TYPE_ERROR, arg_name, i+1, expected, actual)
      end
    end
  end

  def declare_and_verify_params(node)
    node.params.each do |param|
      # Validate Defaults (unchanged)
      if param[:default]
        visit(param[:default])

        def_type = param[:default].resolved_type
        param_type = param[:type]

        unless is_safe_autocast?(def_type, param_type)
          error!(node, "Type Error: Default value for '#{param[:name]}' expects #{param_type}, got #{def_type}")
        end
        # TODO: If types different, set coerced_type
      end

      current_scope.declare(
        param[:name], nil, param[:type], param[:mutable], false, nil, :stack # TODO: param[:storage]
      )
      param[:type]
    end
  end

  # Cannot be part of declare, needs to happen in outer-scope
  def verify_captures(node)
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      # cap is likely a hash: { name: "x" }
      cap_name = cap[:name]

      if !current_scope.locals.key?(cap_name)
        error!(node, "Cannot capture undefined variable '#{cap_name}'")
      end

      # Enrich the capture node with the resolved type
      cap_type = current_scope.resolve_type(cap_name)
      cap[:type] = cap_type
    end
  end

  def declare_captures(node)
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      current_scope.declare(cap[:name], nil, cap[:type], false)
    end
  end

  def verify_returns(node, found_returns, declared_return)
    if found_returns.size > 1
      uniq_return_types = found_returns.map { |r| r[:type] }.uniq.size
      if declared_return != :Any &&uniq_return_types > 1
        error!(node, "Ambiguous Return: Function returns multiple types #{found_returns}, specify :Any as type")
      end
    end
  end

  def get_return_strategy(node, found_returns, final_return_type)
    # Default for Void functions
    return :void if final_return_type == :Void || found_returns.empty?

    # 1. Detect Conflict
    # If one path returns Heap and another returns Stack, we have a problem in a strict language.
    # For now, let's enforce consistency or default to the "heavier" option.
    has_heap = found_returns.any? { |r| r[:storage] == :heap }
    has_stack = found_returns.any? { |r| r[:storage] == :stack }

    if has_heap && has_stack
      error!(node, "Function returns mixed storage (Stack vs Heap). Explicitly cast stack objects to Heap with %")
      # return { storage: :heap, metatype: infer_metatype(final_return_type), is_srvo: false }
    end

    # 2. Extract Consensus Properties
    storage = has_heap ? :heap : :stack
    metatype = found_returns.first[:metatype] # They should be consistent by now

    # 3. Determine SRVO
    # Rule: SRVO only happens for STACK storage of COMPLEX types.
    is_complex = [:struct, :array].include?(metatype)

    if (storage == :stack && is_complex)
      :srvo
    elsif storage == :heap
      :destination_pass
    else
      :primitive
    end
  end


  # ==========================================
  # TYPE CHECKING & AUTOCAST LOGIC
  # ==========================================

  # TODO: use directly -> track down everywhere we have a string, make a type
  def is_safe_autocast?(source_type, target_type)
    source = source_type.is_a?(Symbol) ? Type.new(source_type) : source_type
    target = target_type.is_a?(Symbol) ? Type.new(target_type) : target_type
    target.accepts?(source)
  end

  def check_array_type_mismatch!(node, type_inf, type_decl)
    type_inf = type_inf.to_s
    type_decl = type_decl.to_s
    return false if !type_inf.include?("[") || !type_decl.include?("[")
    return false if type_inf.split("[", 0).first != type_decl.split("[", 0).first

    match = type_decl.match(/^(\w+)\[(.*)\]$/)
    return false unless match

    size_str = match[2]

    # If size is empty (Number[]) or wildcard (Number[*]), skip size check.
    # This ensures we only validate counts for explicit fixed arrays like Number[3].
    return false if size_str.nil? || size_str.strip.empty? || !size_str.match?(/^\d+$/)

    limit = size_str.to_i

    # Safety check: Ensure node.value is actually a list literal
    # (VarDecl might be assigning a variable, not a literal)
    return false unless node.value.respond_to?(:items)

    current_size = node.value.items.size

    if current_size > limit
      error!(node, :FIXED_ARRAY_SIZE_MISMATCH, current_size, type_decl)
    end

    true
  end
end

