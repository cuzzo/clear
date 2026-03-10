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
    node.is_a?(AST::DistinctOp) ||
    node.is_a?(AST::EachOp) ||
    node.is_a?(AST::FindOp) ||
    node.is_a?(AST::AnyOp) ||
    node.is_a?(AST::AllOp) ||
    node.is_a?(AST::CountOp) ||
    node.is_a?(AST::SumOp) ||
    node.is_a?(AST::AverageOp) ||
    node.is_a?(AST::MinOp) ||
    node.is_a?(AST::MaxOp) ||
    node.is_a?(AST::ConcurrentOp)
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
    when AST::EachOp
      analyze_each_op(node)
    when AST::FindOp
      analyze_find_op(node)
    when AST::AnyOp
      analyze_any_op(node)
    when AST::AllOp
      analyze_all_op(node)
    when AST::CountOp
      analyze_count_op(node)
    when AST::SumOp
      analyze_sum_op(node)
    when AST::AverageOp
      analyze_average_op(node)
    when AST::MinOp
      analyze_min_op(node)
    when AST::MaxOp
      analyze_max_op(node)
    when AST::ConcurrentOp
      analyze_concurrent_op(node)
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

  def analyze_each_op(node)
    # EACH accepts arrays (metatype :array), pools, and @list:sharded collections.
    lhs_type  = node.left.type_info
    is_pool   = lhs_type&.pool?
    is_list   = lhs_type&.list_collection?
    is_array  = node.left.metatype == :array

    unless is_pool || is_list || is_array
      error!(node.left, "Cannot EACH non-collection type #{node.left.resolved_type}. EACH requires an array, @list, @list:sharded(N), @pool, or @pool:sharded(N)")
      node.full_type = :Void
      return
    end

    item_type = if is_pool
      lhs_type.element_type.resolved
    else
      lhs_type.element_type.resolved
    end

    with_new_scope do
      # Mutable: EACH body may mutate the item via field assignment (_.field = value)
      current_scope.declare("_", nil, item_type, true, false, nil, :stack)
      node.right.body.each { |stmt| visit(stmt) }
    end

    node.full_type = :Void
    node.storage   = :frame
  end

  # =========================================================
  # Phase 3: Predicate Query Operators (FIND, ANY, ALL, COUNT)
  # =========================================================

  def analyze_find_op(node)
    # FIND: list s> FIND predicate  → ?ElemType (first match or null)
    require_array_input!(node, "FIND")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, "FIND clause must evaluate to Bool, got #{node.right.expression.resolved_type}")
    end

    node.full_type = :"?#{item_type}"
    node.storage   = :stack
  end

  def analyze_any_op(node)
    # ANY: list s> ANY predicate  → Bool (true if any element matches; short-circuits)
    require_array_input!(node, "ANY")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, "ANY clause must evaluate to Bool, got #{node.right.expression.resolved_type}")
    end

    node.full_type = :Bool
    node.storage   = :stack
  end

  def analyze_all_op(node)
    # ALL: list s> ALL predicate  → Bool (true iff every element matches; short-circuits on first failure)
    # Vacuous truth: ALL on an empty list returns true.
    require_array_input!(node, "ALL")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, "ALL clause must evaluate to Bool, got #{node.right.expression.resolved_type}")
    end

    node.full_type = :Bool
    node.storage   = :stack
  end

  def analyze_count_op(node)
    # COUNT: list s> COUNT predicate  → Int64 (number of elements matching predicate)
    require_array_input!(node, "COUNT")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, "COUNT clause must evaluate to Bool, got #{node.right.expression.resolved_type}")
    end

    node.full_type = :Int64
    node.storage   = :stack
  end

  # =========================================================
  # Phase 4: Numeric Aggregation Operators (SUM, AVERAGE, MIN, MAX)
  # =========================================================

  NUMERIC_TYPES = [:Number, :Int64].freeze

  def analyze_sum_op(node)
    # SUM: list s> SUM _.field  → Number (sum of numeric projection; 0 for empty list)
    require_array_input!(node, "SUM")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    expr_type = node.right.expression.resolved_type
    unless NUMERIC_TYPES.include?(expr_type)
      error!(node.right, "SUM requires a numeric expression, got #{expr_type}")
    end

    node.full_type = :Number
    node.storage   = :stack
  end

  def analyze_average_op(node)
    # AVERAGE: list s> AVERAGE _.field  → Number (arithmetic mean; 0 for empty list)
    require_array_input!(node, "AVERAGE")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    expr_type = node.right.expression.resolved_type
    unless NUMERIC_TYPES.include?(expr_type)
      error!(node.right, "AVERAGE requires a numeric expression, got #{expr_type}")
    end

    node.full_type = :Number
    node.storage   = :stack
  end

  def analyze_min_op(node)
    # MIN: list s> MIN _.field  → Number (minimum value; panics on empty list)
    require_array_input!(node, "MIN")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    expr_type = node.right.expression.resolved_type
    unless NUMERIC_TYPES.include?(expr_type)
      error!(node.right, "MIN requires a numeric expression, got #{expr_type}")
    end

    node.full_type = :Number
    node.storage   = :stack
  end

  def analyze_max_op(node)
    # MAX: list s> MAX _.field  → Number (maximum value; panics on empty list)
    require_array_input!(node, "MAX")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    expr_type = node.right.expression.resolved_type
    unless NUMERIC_TYPES.include?(expr_type)
      error!(node.right, "MAX requires a numeric expression, got #{expr_type}")
    end

    node.full_type = :Number
    node.storage   = :stack
  end

  VALID_CONCURRENT_OPTIONS = %w[pool_size pin].freeze

  def analyze_concurrent_op(node)
    conc    = node.right   # the ConcurrentOp node
    options = conc.options

    # Validate pool_size option if present
    if (ps = options["pool_size"])
      visit(ps)
      unless [:Number, :Int64].include?(ps.resolved_type)
        error!(ps, "CONCURRENT pool_size must be a number, got #{ps.resolved_type}")
      end
      # Validate pool_size > 0 for literal values (including negated literals like -1)
      literal_val = if ps.is_a?(AST::Literal)
        ps.value.to_f
      elsif ps.is_a?(AST::UnaryOp) && ps.op == :SUB && ps.right.is_a?(AST::Literal)
        -ps.right.value.to_f
      end
      if literal_val && literal_val <= 0
        error!(ps, "CONCURRENT pool_size must be greater than 0, got #{literal_val.to_i}")
      end
    end

    # Validate pin option is Bool if present
    if (pin_val = options["pin"])
      # true/false may appear as lowercase identifiers (VAR_ID) or BOOLEAN literals
      is_bool = (pin_val.is_a?(AST::Literal) && pin_val.type == :BOOLEAN) ||
                (pin_val.is_a?(AST::Identifier) && %w[true false].include?(pin_val.name))
      unless is_bool
        error!(pin_val, "CONCURRENT pin must be a Bool (true or false), got #{pin_val.class.name.split('::').last}")
      end
    end

    # Validate that only known option keys are used
    options.each_key do |key|
      unless VALID_CONCURRENT_OPTIONS.include?(key)
        error!(conc, "Unknown CONCURRENT option '#{key}'. Valid options: #{VALID_CONCURRENT_OPTIONS.join(', ')}")
      end
    end

    # Type analysis for concurrent ops is identical to synchronous versions.
    # Create a proxy BinaryOp(SMOOTH, left, inner_op) so we can reuse the existing analyze_* methods.
    proxy = AST::BinaryOp.new(node.token, node.left, :SMOOTH, conc.op)

    case conc.op
    when AST::SelectOp, AST::WhereOp
      analyze_select_family_op(proxy)
    when AST::EachOp
      analyze_each_op(proxy)
    else
      error!(conc, "CONCURRENT does not support #{conc.op.class.name.split('::').last}")
    end

    # Validate that OR PRUNE / OR RAISE is only used with error-returning expressions
    inner_expr = case conc.op
    when AST::SelectOp, AST::WhereOp then conc.op.expression
    else nil
    end

    if inner_expr.is_a?(AST::BinaryOp) && inner_expr.op == :OR_RESCUE
      modifier = inner_expr.right
      if modifier.is_a?(AST::OrPrune) || modifier.is_a?(AST::OrRaise)
        inner_fn_type = inner_expr.left.type_info
        unless inner_fn_type&.error_union?
          mod_name = modifier.is_a?(AST::OrPrune) ? "OR PRUNE" : "OR RAISE"
          error!(modifier, "#{mod_name} requires the expression to return an error union (!T), but got #{inner_expr.left.resolved_type}")
        end
      end
    end

    node.full_type = proxy.full_type
    node.storage   = proxy.storage
  end

  # Helper to validate array/pool input for higher-order ops.
  # Accepts:
  #   - Array types (metatype :array)
  #   - @pool and @pool:sharded(N) collection types
  #   - @list and @list:sharded(N) collection types
  def require_array_input!(node, op_name)
    lhs_type = node.left.type_info
    return if node.left.metatype == :array
    return if lhs_type&.pool?
    return if lhs_type&.list_collection?
    # SELECT uses "from" in error message for historical reasons
    if op_name == "SELECT"
      error!(node.left, "Cannot SELECT from non-list type #{node.left.resolved_type}")
    else
      error!(node.left, "Cannot #{op_name} non-list type #{node.left.resolved_type}")
    end
  end
end
