require_relative "../src/ast"
require_relative "../src/type"

module PipeAnalysis
  # =========================================================
  # SMOOTH OPERATOR (s>)
  # =========================================================
  def visit_Smooth(node)
    @smooth_depth += 1
    # Logic: x s> f  -> f(x)

    # 1. Visit the Left (Input) FIRST
    visit(node.left)

    if higher_order_list_op?(node.right)
      analyze_higher_order_op(node)
    elsif node.right.is_a?(AST::FuncCall)
      analyze_pipe_to_func_call(node)
    elsif node.right.is_a?(AST::Identifier)
      analyze_pipe_to_identifier(node)
    else
      # Case 3: Invalid RHS (e.g. 10 s> (expression))
      error!(node, "Invalid pipe destination. Must be a Function Call or Identifier.")
      node.full_type = :Any
    end

    @smooth_depth -= 1
  end

  private

  def higher_order_list_op?(node)
    node.is_a?(AST::SelectOp) ||
    node.is_a?(AST::WhereOp) ||
    node.is_a?(AST::IndexOp) ||
    node.is_a?(AST::OrderByOp) ||
    node.is_a?(AST::ReduceOp) ||
    node.is_a?(AST::LimitOp) ||
    node.is_a?(AST::UnnestOp) ||
    node.is_a?(AST::DistinctOp)
  end

  def analyze_higher_order_op(node)
    case node.right
    when AST::SelectOp, AST::WhereOp, AST::IndexOp, AST::OrderByOp
      analyze_select_family_op(node)
    when AST::ReduceOp
      analyze_reduce_op(node)
    when AST::LimitOp
      analyze_limit_op(node)
    when AST::UnnestOp
      analyze_unnest_op(node)
    when AST::DistinctOp
      analyze_distinct_op(node)
    end
  end

  # SELECT, WHERE, INDEX, ORDER_BY share similar structure
  def analyze_select_family_op(node)
    require_array_input!(node, "SELECT")
    item_type = node.left.type_info.element_type.resolved

    # Create a temporary Scope for the body
    with_new_scope do
      # Declare '_' with the specific item type
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)

      # Analyze the Body (e.g., _["count"])
      visit(node.right.expression)

      if node.right.is_a?(AST::WhereOp) && node.right.expression.resolved_type != :Bool
        error!(node.right, "WHERE clause must evaluate to Bool")
      end
    end

    # Set Result Type based on operator
    case node.right
    when AST::SelectOp
      result_base = node.right.expression.full_type
      node.full_type = :"#{result_base}[]"
    when AST::WhereOp
      node.full_type = :"#{item_type}[]"
    when AST::IndexOp
      # INDEX returns HashMap<KeyType, ElementType[]>
      key_type = node.right.expression.resolved_type
      node.full_type = :"HashMap<#{item_type}[]>"
      node.right.full_type = key_type
    when AST::OrderByOp
      # ORDER_BY returns the same list type, sorted
      node.full_type = :"#{item_type}[]"
      node.right.full_type = node.right.expression.resolved_type
    end

    node.storage = :frame
  end

  def analyze_reduce_op(node)
    # REDUCE: list s> REDUCE(initial) acc + _.value
    require_array_input!(node, "REDUCE")
    item_type = node.left.type_info.element_type.resolved

    # Analyze the initial value to get the accumulator type
    visit(node.right.initial_value)
    acc_type = node.right.initial_value.resolved_type

    # Create scope with both 'acc' and '_'
    with_new_scope do
      # 'acc' is mutable (it accumulates)
      current_scope.declare("acc", nil, acc_type, true, false, nil, :stack)
      # '_' is the current element
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)

      # Analyze the body expression
      visit(node.right.expression)
    end

    # Result type is the accumulator type
    node.full_type = acc_type
    node.right.full_type = acc_type
    node.storage = :stack
  end

  def analyze_limit_op(node)
    # LIMIT: list s> LIMIT n
    require_array_input!(node, "LIMIT")
    item_type = node.left.type_info.element_type.resolved

    # Analyze the count expression
    visit(node.right.count)
    count_type = node.right.count.resolved_type
    unless [:Int64, :Number].include?(count_type)
      error!(node.right.count, "LIMIT count must be a number, got #{count_type}")
    end

    # Result type is the same list type
    node.full_type = :"#{item_type}[]"
    node.storage = :frame
  end

  def analyze_unnest_op(node)
    # UNNEST: list s> UNNEST _.arr (flatmap)
    require_array_input!(node, "UNNEST")
    item_type = node.left.type_info.element_type.resolved

    # Analyze the expression with '_' in scope
    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    # Check that the expression evaluates to an array type
    expr_type = Type.new(node.right.expression.full_type)
    unless expr_type.array?
      error!(node.right.expression, "UNNEST requires an array expression, got #{node.right.expression.resolved_type}. Use SELECT instead for non-array fields.")
    end

    # Result type is the element type of the nested array
    nested_element_type = expr_type.element_type.resolved
    node.full_type = :"#{nested_element_type}[]"
    node.right.full_type = node.right.expression.full_type
    node.storage = :frame
  end

  def analyze_distinct_op(node)
    # DISTINCT: list s> DISTINCT _.field (or just DISTINCT _)
    # Returns unique elements, preserving order
    require_array_input!(node, "DISTINCT")
    item_type = node.left.type_info.element_type.resolved

    # Analyze the expression with '_' in scope
    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    # Store the key type for transpilation (what we're comparing for uniqueness)
    node.right.full_type = node.right.expression.resolved_type

    # Result type is the same list type
    node.full_type = :"#{item_type}[]"
    node.storage = :frame
  end

  def analyze_pipe_to_func_call(node)
    # Case 1: x s> f(y)  => f(x, y)
    # We intentionally modify the AST temporarily to leverage visit_FuncCall's
    # existing validation logic (arity, type checks, intrinsics).

    # Inject LHS as the first argument (UFC), call, uninject / eject / pop.
    node.right.args.unshift(node.left)
    visit(node.right)
    node.right.args.shift

    # Propagate Result Type
    node.full_type = node.right.full_type
  end

  def analyze_pipe_to_identifier(node)
    # Case 2: x s> f  => f(x)
    # We must MANUALLY validate this because we aren't creating a FuncCall node.

    visit(node.right) # Resolves 'f' to its Signature/Type

    sig = node.right.full_type
    func_name = node.right.name

    if sig[:params]
      # Named Function or Lambda (both use standard signature format)
      analyze_pipe_to_named_function(node, sig, func_name)
    elsif sig == :Intrinsic || sig == :Nil
      # Builtin / Intrinsic
      # e.g. 'print' returns :Nil. 'map' returns :Intrinsic (resolved later via call).
      node.full_type = (sig == :Intrinsic) ? :Any : sig
    else
      # Not a Callable
      error!(node, "Cannot pipe into non-callable '#{func_name}' (Resolved Type: #{sig})")
    end
  end

  def analyze_pipe_to_named_function(node, sig, func_name)
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

      # Type.accepts? handles slice coercion (Number[3] -> Number[])
      unless is_safe_autocast?(actual, expected)
        error!(node.left, :ARGUMENT_TYPE_ERROR, "Pipe Input", 1, param[:name], expected, actual)
      end
    end

    # 3. Set Result Type
    node.full_type = sig[:return][:type]
  end

  # Helper to validate array input for higher-order ops
  def require_array_input!(node, op_name)
    return unless node.left.metatype != :array
    # SELECT uses "from" in error message for historical reasons
    if op_name == "SELECT"
      error!(node.left, "Cannot SELECT from non-list type #{node.left.resolved_type}")
    else
      error!(node.left, "Cannot #{op_name} non-list type #{node.left.resolved_type}")
    end
  end
end
