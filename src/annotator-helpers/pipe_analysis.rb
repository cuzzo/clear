require_relative "../ast/ast"
require_relative "../ast/type"
require 'set'

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

  def finite_stream_source?(node)
    node.is_a?(AST::RangeLit) || node.type_info&.dynamic_stream? ||
      node.type_info&.bounded_stream? || node.type_info&.open_stream?
  end

  def bounded_stream_source?(node)
    node.type_info&.bounded_stream?
  end

  def finite_stream_element_type(node)
    return range_element_type(node) if node.is_a?(AST::RangeLit)
    return node.type_info.open_stream_element_type.resolved if node.type_info&.open_stream?
    node.type_info.tense_type.element_type.resolved
  end

  # Element type for an InfStream source (~T[INF]).
  def inf_stream_element_type(node)
    node.type_info.inf_stream_element_type.resolved
  end

  def has_catch_blocks?
    fn = @fn_nodes&.dig(current_fn_ctx&.name)
    fn && fn.catch_clauses.is_a?(Array) && fn.catch_clauses.any?
  end

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
    node.is_a?(AST::ConcurrentOp) ||
    node.is_a?(AST::ShardOp) ||
    node.is_a?(AST::SkipOp) ||
    node.is_a?(AST::TapOp) ||
    node.is_a?(AST::TakeWhileOp) ||
    node.is_a?(AST::WindowOp) ||
    node.is_a?(AST::JoinOp) ||
    node.is_a?(AST::RecoverOp)
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
    when AST::ShardOp
      analyze_shard_op(node)
    when AST::SkipOp
      analyze_skip_op(node)
    when AST::TapOp
      analyze_tap_op(node)
    when AST::TakeWhileOp
      analyze_take_while_op(node)
    when AST::WindowOp
      analyze_window_op(node)
    when AST::JoinOp
      analyze_join_op(node)
    when AST::RecoverOp
      analyze_recover_op(node)
    end
  end

  # SELECT, WHERE, INDEX, ORDER_BY share similar structure.
  # SELECT and WHERE also accept a RangeLit or InfStream source (fused lazy path).
  # INDEX accepts finite stream sources (~T[], ~T[N]).
  def analyze_select_family_op(node)
    is_inf    = node.left.type_info&.inf_stream? &&
                (node.right.is_a?(AST::SelectOp) || node.right.is_a?(AST::WhereOp))
    is_stream = (finite_stream_source?(node.left) || is_inf) &&
                (node.right.is_a?(AST::SelectOp) || node.right.is_a?(AST::WhereOp) ||
                 node.right.is_a?(AST::IndexOp))
    require_array_input!(node, "SELECT", allow_range: is_stream, allow_stream: is_stream)
    item_type = if is_inf
      inf_stream_element_type(node.left)
    elsif is_stream
      finite_stream_element_type(node.left)
    else
      node.left.type_info.element_type.resolved
    end

    # Create a temporary Scope for the body
    with_new_scope do
      # Declare '_' with the specific item type
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)

      # Analyze the Body (e.g., _["count"])
      with_soa_tracking(node, item_type) do
        visit(node.right.expression)
      end

      if node.right.is_a?(AST::WhereOp) && node.right.expression.resolved_type != :Bool
        error!(node.right, "WHERE clause must evaluate to Bool")
      end
    end

    # Set Result Type based on operator.
    # InfStream sources propagate ~T[INF] so downstream fusible ops and LIMIT
    # can see the source is still infinite; LIMIT will convert to T[].
    case node.right
    when AST::SelectOp
      result_base = node.right.expression.full_type
      node.full_type = is_inf ? :"~#{result_base}[INF]" : :"#{result_base}[]"
    when AST::WhereOp
      node.full_type = is_inf ? :"~#{item_type}[INF]" : :"#{item_type}[]"
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

    # WHERE/SELECT/ORDER_BY allocate intermediate ArrayListUnmanaged at the
    # transpiler level via rt.frameAlloc(). InfStream results are not materialized;
    # only count frame allocation for finite (list-producing) results.
    current_fn_ctx.frame_count += 1 if current_fn_ctx && !is_inf
  end

  def analyze_take_while_op(node)
    is_inf    = node.left.type_info&.inf_stream?
    is_stream = finite_stream_source?(node.left) || is_inf
    require_array_input!(node, "TAKE_WHILE", allow_range: is_stream, allow_stream: is_stream)
    item_type = if is_inf
      inf_stream_element_type(node.left)
    elsif is_stream
      finite_stream_element_type(node.left)
    else
      node.left.type_info.element_type.resolved
    end

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, "TAKE_WHILE predicate must evaluate to Bool, got #{node.right.expression.resolved_type}")
    end

    node.full_type = is_inf ? :"~#{item_type}[INF]" : :"#{item_type}[]"
    node.storage = :frame
    current_fn_ctx.frame_count += 1 if current_fn_ctx && !is_inf
  end

  def analyze_window_op(node)
    require_array_input!(node, "WINDOW")
    item_type = node.left.type_info.element_type.resolved

    # Validate the size argument is numeric
    visit(node.right.size)
    size_type = node.right.size.resolved_type
    unless [:Int64, :Float64].include?(size_type)
      error!(node.right.size, "WINDOW size must be a number, got #{size_type}")
    end

    # _ is a sub-slice of the same element type
    with_new_scope do
      current_scope.declare("_", nil, :"#{item_type}[]", false, false, nil, :stack)
      visit(node.right.expression)
    end

    # Result is a list of whatever the expression produces
    expr_type = node.right.expression.full_type || node.right.expression.resolved_type
    node.full_type = :"#{expr_type}[]"
    node.storage = :frame
    current_fn_ctx.frame_count += 1 if current_fn_ctx
  end

  def analyze_join_op(node)
    require_array_input!(node, "JOIN")
    left_type = node.left.type_info.element_type.resolved

    # Visit and validate the right source
    visit(node.right.right_source)
    rhs_type_info = node.right.right_source.type_info
    unless node.right.right_source.metatype == :array || rhs_type_info&.collection?
      error!(node.right.right_source, "JOIN right source must be a list, got #{node.right.right_source.resolved_type}")
    end
    right_type = rhs_type_info.element_type.resolved

    key_expr = node.right.key_expr

    if key_expr.is_a?(AST::LambdaLit)
      # Lambda form: %(a, b) -> a.id == b.userId
      params = key_expr.params
      error!(key_expr, "JOIN lambda must take exactly 2 parameters") unless params.size == 2
      left_name  = params[0].is_a?(Hash) ? params[0][:name] : params[0].name
      right_name = params[1].is_a?(Hash) ? params[1][:name] : params[1].name
      with_new_scope do
        current_scope.declare(left_name, nil, left_type, false, false, nil, :stack)
        current_scope.declare(right_name, nil, right_type, false, false, nil, :stack)
        visit(key_expr.body)
      end
      unless key_expr.body.resolved_type == :Bool
        error!(key_expr, "JOIN lambda must return Bool, got #{key_expr.body.resolved_type}")
      end
    else
      # Shared key form: _.field applied to both sides
      # Validate the key expression with _ as left type
      with_new_scope do
        current_scope.declare("_", nil, left_type, false, false, nil, :stack)
        visit(key_expr)
      end
      # Also validate with right type (both must have the field)
      with_new_scope do
        current_scope.declare("_", nil, right_type, false, false, nil, :stack)
        visit(key_expr)
      end
    end

    # Register a synthetic struct type for the join result so field access works.
    join_type_name = :"JoinResult_#{left_type}_#{right_type}"
    unless current_scope.resolve_type_definition(join_type_name)
      current_scope.declare_type(join_type_name, {
        "left"  => left_type,
        "right" => :"?#{right_type}",
      })
    end

    node.full_type = :"#{join_type_name}[]"
    node.storage = :frame
    current_fn_ctx.frame_count += 1 if current_fn_ctx
  end

  def analyze_recover_op(node)
    # RECOVER(default): replace error with default value in pipeline
    visit(node.right.default_expr)
    lhs_type = node.left.respond_to?(:full_type) ? node.left.full_type : nil
    lhs_t = lhs_type ? Type.new(lhs_type) : nil
    if lhs_t&.error_union?
      node.full_type = lhs_t.payload_type.resolved
    else
      node.full_type = lhs_type
    end
    node.storage = :stack
  end

  def analyze_reduce_op(node)
    # REDUCE: list s> REDUCE(initial) acc + _.value
    # Also accepts range/stream sources for the fused lazy path.
    is_stream = finite_stream_source?(node.left)
    require_array_input!(node, "REDUCE", allow_range: is_stream, allow_stream: is_stream)
    item_type = is_stream ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

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
    # Also accepts range and stream sources (fused lazy path).
    is_range  = node.left.is_a?(AST::RangeLit)
    lhs_ti    = node.left.type_info
    is_stream = lhs_ti&.dynamic_stream? || lhs_ti&.bounded_stream? || lhs_ti&.inf_stream?
    require_array_input!(node, "LIMIT", allow_range: is_range || is_stream, allow_stream: is_stream)

    item_type = if is_range
      range_element_type(node.left)
    elsif lhs_ti&.inf_stream?
      lhs_ti.inf_stream_element_type.resolved
    elsif is_stream
      lhs_ti.tense_type.element_type.resolved
    else
      lhs_ti.element_type.resolved
    end

    # Analyze the count expression
    visit(node.right.count)
    count_type = node.right.count.resolved_type
    unless [:Int64, :Float64].include?(count_type)
      error!(node.right.count, "LIMIT count must be a number, got #{count_type}")
    end

    # Result type is a materialized list of the element type
    node.full_type = :"#{item_type}[]"
    node.storage = :frame
  end

  def analyze_unnest_op(node)
    # UNNEST: list s> UNNEST _.arr (flatmap)
    # Optional inner binding: UNNEST _.arr AS @o  parses as UNNEST BIND_VAR(_.arr, @o)
    # because :pipe_expression uses parse_expression(1) which consumes AS at prec 2.
    require_array_input!(node, "UNNEST")
    item_type = node.left.type_info.element_type.resolved

    # Detect inner binding: UNNEST expr AS @name -> expression is BIND_VAR(expr, @name)
    inner_bind_name = nil
    expr = node.right.expression
    if expr.is_a?(AST::BinaryOp) && expr.op == :BIND_VAR
      inner_bind_name = expr.right.name  # e.g. "@o"
    end

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

    # Promote inner binding to the outer scope so subsequent pipeline stages can see it.
    # BIND_VAR was visited inside the temp scope, so @o was declared there and is now gone.
    # Re-declare it in current_scope (the scope that persists after this method returns).
    if inner_bind_name
      current_scope.declare(inner_bind_name, nil, nested_element_type.to_s, false, false, nil, :stack)
    end
  end

  def analyze_distinct_op(node)
    # DISTINCT: list s> DISTINCT _.field (or just DISTINCT _)
    # Returns a Set of unique key values (T[]@set).
    lhs_type  = node.left.type_info
    is_inf    = lhs_type&.inf_stream?
    is_stream = finite_stream_source?(node.left) || is_inf

    require_array_input!(node, "DISTINCT", allow_range: is_stream, allow_stream: is_stream)

    item_type = if is_inf
      inf_stream_element_type(node.left)
    elsif is_stream
      finite_stream_element_type(node.left)
    else
      lhs_type.element_type.resolved
    end

    # Analyze the expression with '_' in scope
    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    # Key type is what the expression evaluates to; result is a Set of those keys.
    key_type = node.right.expression.resolved_type
    node.right.full_type = key_type
    node.full_type = Type.new(:"#{key_type}[]", collection: :set)
    node.storage = :heap
    current_fn_ctx.heap_count += 1 if current_fn_ctx
  end

  def analyze_pipe_to_func_call(node)
    # Case 1: x s> f(y)  => f(x, y)
    # We intentionally modify the AST temporarily to leverage visit_FuncCall's
    # existing validation logic (arity, type checks, intrinsics).

    # Inject LHS as the first argument (UFC), call, uninject / eject / pop.
    node.right.args.unshift(node.left)
    visit(node.right)
    node.right.args.shift

    # Propagate Result Type. In functions with CATCH blocks, unwrap error
    # unions — the CATCH handles errors locally, so the pipe result is T not !T.
    result_type = node.right.full_type
    if has_catch_blocks? && result_type
      t = Type.new(result_type)
      result_type = t.payload_type.resolved if t.error_union?
    end
    node.full_type = result_type
  end

  def analyze_pipe_to_identifier(node)
    # Case 2: x s> f  => f(x)
    # We must MANUALLY validate this because we aren't creating a FuncCall node.

    visit(node.right) # Resolves 'f' to its Signature/Type

    sig = node.right.full_type
    func_name = node.right.name

    if sig.respond_to?(:params) ? sig.params : sig[:params]
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
    params = sig.respond_to?(:params) ? sig.params : sig[:params]
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

    # 3. Set Result Type. Unwrap error unions in CATCH functions.
    result_type = sig.respond_to?(:return_type) ? sig.return_type : sig[:return][:type]
    if has_catch_blocks? && result_type
      t = result_type.is_a?(Type) ? result_type : Type.new(result_type)
      result_type = t.payload_type.resolved if t.error_union?
    end
    node.full_type = result_type
  end

  def analyze_each_op(node)
    # EACH accepts arrays, collections, and finite streams.
    lhs_type  = node.left.type_info
    is_pool   = lhs_type&.pool?
    is_list   = lhs_type&.list_collection?
    is_array  = node.left.metatype == :array
    is_range  = finite_stream_source?(node.left)

    unless is_pool || is_list || is_array || is_range
      error!(node.left, "Cannot EACH non-collection type #{node.left.resolved_type}. EACH requires an array, @list, @list:sharded(N), @pool, @pool:sharded(N), or a range")
      node.full_type = :Void
      return
    end

    item_type = if is_range
      finite_stream_element_type(node.left)
    elsif is_pool || is_list
      lhs_type.element_type.resolved
    else
      lhs_type.element_type.resolved
    end

    with_new_scope(current_scope) do
      # Mutable: EACH body may mutate the item via field assignment (_.field = value)
      # Use current_scope as parent so outer variables remain visible for reassignment
      # (sum = sum + _ inside EACH should reassign the outer sum, not shadow it).
      current_scope.declare("_", nil, item_type, true, false, nil, :stack)
      with_soa_tracking(node, item_type) do
        node.right.body.each { |stmt| visit(stmt) }
      end
    end

    node.full_type = :Void
    node.storage   = :frame
  end

  def analyze_skip_op(node)
    # SKIP: list s> SKIP n -> same list type with first n elements removed (also accepts range/InfStream)
    is_inf   = node.left.type_info&.inf_stream?
    is_range = finite_stream_source?(node.left) || is_inf
    require_array_input!(node, "SKIP", allow_range: is_range, allow_stream: is_range)
    item_type = if is_inf
      inf_stream_element_type(node.left)
    elsif is_range
      finite_stream_element_type(node.left)
    else
      node.left.type_info.element_type.resolved
    end

    visit(node.right.count)
    count_type = node.right.count.resolved_type
    unless [:Int64, :Float64].include?(count_type)
      error!(node.right.count, "SKIP count must be a number, got #{count_type}")
    end

    node.full_type = is_inf ? :"~#{item_type}[INF]" : :"#{item_type}[]"
    node.storage = :frame
  end

  def analyze_tap_op(node)
    # TAP: list s> TAP { body } -> same list type (pass-through); also accepts range/stream source.
    lhs_type = node.left.type_info
    is_inf   = lhs_type&.inf_stream?
    is_range = finite_stream_source?(node.left) || is_inf
    is_pool  = lhs_type&.pool?
    is_list  = lhs_type&.list_collection?
    is_array = node.left.metatype == :array

    unless is_pool || is_list || is_array || is_range
      error!(node.left, "Cannot TAP non-collection type #{node.left.resolved_type}.")
      node.full_type = :Void
      return
    end

    item_type = if is_inf
      inf_stream_element_type(node.left)
    elsif is_range
      finite_stream_element_type(node.left)
    else
      lhs_type.element_type.resolved
    end

    with_new_scope do
      # Read-only: TAP is for observation, not mutation
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      node.right.body.each { |stmt| visit(stmt) }
    end

    # TAP returns the original collection (pass-through); range stays range
    node.full_type = node.left.full_type
    node.storage = node.left.storage
  end

  # =========================================================
  # Phase 3: Predicate Query Operators (FIND, ANY, ALL, COUNT)
  # =========================================================

  def analyze_find_op(node)
    # FIND: list s> FIND predicate  → ?ElemType (first match or null; also accepts range)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "FIND", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

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
    # ANY: list s> ANY predicate  → Bool (short-circuits; also accepts range)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "ANY", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

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
    # ALL: list s> ALL predicate  → Bool (vacuous truth on empty; also accepts range)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "ALL", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

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
    # COUNT: list s> COUNT predicate  → Int64 (also accepts range)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "COUNT", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

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

  # Use Type#numeric? for consistency with the type system.
  # Covers :Float64, :Int64, :Byte, :Float64.

  def analyze_sum_op(node)
    # SUM: list s> SUM expr  → upsized numeric type (int→Int64/UInt64, float→same float)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "SUM", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, "SUM requires a numeric expression, got #{expr_type}")
    end

    node.full_type = sum_result_clear_type(expr_type)
    node.storage   = :stack
  end

  def analyze_average_op(node)
    # AVERAGE: list s> AVERAGE expr  → Float64 (0 for empty; also accepts range)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "AVERAGE", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, "AVERAGE requires a numeric expression, got #{expr_type}")
    end

    node.full_type = :Float64
    node.storage   = :stack
  end

  def analyze_min_op(node)
    # MIN: list s> MIN expr  → exact expression type (panics on empty; also accepts range)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "MIN", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, "MIN requires a numeric expression, got #{expr_type}")
    end

    node.full_type = expr_type
    node.storage   = :stack
  end

  def analyze_max_op(node)
    # MAX: list s> MAX expr  → exact expression type (panics on empty; also accepts range)
    is_range = finite_stream_source?(node.left)
    require_array_input!(node, "MAX", allow_range: is_range, allow_stream: is_range)
    item_type = is_range ? finite_stream_element_type(node.left) : node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, "MAX requires a numeric expression, got #{expr_type}")
    end

    node.full_type = expr_type
    node.storage   = :stack
  end

  # =========================================================
  # SHARD: route pipeline items to owning schedulers by key hash
  # =========================================================

  # SHARD + CONCURRENT EACH: the EACH body sees `_` typed as the map's key type.
  def analyze_shard_each_op(node, shard_node)
    conc = node.right
    each_op = conc.op

    # `_` is the routing key — String for string-keyed maps, numeric for numeric maps.
    key_type = if shard_node
      ti = shard_node.target_map.type_info
      (ti&.numeric_map? && ti&.key_type&.resolved) || :String
    else
      :String
    end

    with_new_scope do
      current_scope.declare("_", nil, key_type, true, false, nil, :stack)
      each_op.body.each { |stmt| visit(stmt) }
    end

    # key_allocates_frame / body_allocates_frame are set by LoopFrameAnalysis in
    # Pass 2 after CleanupClassifier finalizes allocators. Defaulting to false here.
    if conc.shard_context
      conc.shard_context[:key_allocates_frame] = false
      conc.shard_context[:body_allocates_frame] = false
    end

    node.full_type = :Void
    node.storage   = :stack
  end

  # Pre-scan: check if the EACH body references any @sharded map variable
  # by scanning for identifiers that are in scope as @sharded (without :locked).
  # This runs BEFORE visiting the body, so we only check unvisited AST.
  def emit_multi_map_warning(conc, sharded_names)
    shard_counts = sharded_names.map do |name|
      sc = lookup_scope_for(name)&.locals&.[](name)&.type
      t = sc.is_a?(Type) ? sc : Type.new(sc)
      t.shard_count
    end.compact.uniq
    names_str = sharded_names.to_a.join(', ')
    if shard_counts.length == 1
      note!(conc, "CONCURRENT EACH accesses #{sharded_names.length} @sharded maps " \
            "(#{names_str}). Co-located (same shard count #{shard_counts.first}), " \
            "but auto-sharding requires a single map. Use explicit SHARD() or @sharded(N):locked.")
    else
      note!(conc, "CONCURRENT EACH accesses @sharded maps with different shard counts " \
            "(#{names_str}). Cross-shard routing is likely — consider @sharded(N):locked.")
    end
  end

  def collect_sharded_names(node, names)
    return unless node.is_a?(AST::Locatable)
    if node.is_a?(AST::Identifier)
      entry = node.symbol
      if entry
        t = entry.type
        t = Type.new(t) unless t.is_a?(Type)
        names << node.name if t.sharded? && !t.any_sync?
      end
    end
    return if node.is_a?(AST::BgBlock) || node.is_a?(AST::DoBlock)
    node.class.members.each do |member|
      val = node[member]
      if val.is_a?(Array)
        val.each { |v| collect_sharded_names(v, names) }
      elsif val.is_a?(AST::Locatable)
        collect_sharded_names(val, names)
      end
    end
  end

  def pre_scan_node_for_sharded(node)
    return false unless node.is_a?(AST::Locatable)
    if node.is_a?(AST::Identifier)
      entry = node.symbol
      return false unless entry
      t = entry.type
      t = Type.new(t) unless t.is_a?(Type)
      return t.sharded? && !t.any_sync?
    end
    return false if node.is_a?(AST::BgBlock) || node.is_a?(AST::DoBlock)
    node.class.members.any? do |member|
      val = node[member]
      if val.is_a?(Array)
        val.any? { |v| pre_scan_node_for_sharded(v) }
      elsif val.is_a?(AST::Locatable)
        pre_scan_node_for_sharded(val)
      else
        false
      end
    end
  end

  # Analyze CONCURRENT EACH with auto-detected @sharded map access.
  # Accepts range inputs (unlike analyze_each_op which requires collections).
  # Visits the body, then extracts the key expression and sets shard_context.
  def analyze_auto_shard_each_op(smooth_node, conc, proxy)
    lhs_type = smooth_node.left.type_info
    is_range = finite_stream_source?(smooth_node.left)
    is_array = smooth_node.left.metatype == :array
    is_list  = lhs_type&.list_collection?

    item_type = if is_range
      finite_stream_element_type(smooth_node.left)
    elsif is_array || is_list
      lhs_type.element_type.resolved
    else
      error!(smooth_node.left, "CONCURRENT EACH input must be a finite stream or collection, got #{smooth_node.left.resolved_type}")
      :Any
    end

    with_new_scope do
      current_scope.declare("_", nil, item_type, true, false, nil, :stack)
      conc.op.body.each { |stmt| visit(stmt) }
    end

    smooth_node.full_type = :Void
    smooth_node.storage   = :stack

    # Now extract the @sharded map access from the visited body
    auto_detect_sharded_access(smooth_node, conc)
  end

  # Auto-detect @sharded map access in CONCURRENT EACH body.
  # Walks the body AST looking for map[key_expr] patterns where map is @sharded.
  # If found, sets shard_context on the ConcurrentOp so the transpiler emits
  # routed sharding instead of the normal worker pool.
  def auto_detect_sharded_access(smooth_node, conc)
    each_op = conc.op
    return unless each_op.is_a?(AST::EachOp)

    # Collect all GetIndex nodes that target a @sharded map
    sharded_accesses = []
    walk_for_sharded_access(each_op.body, sharded_accesses)

    return if sharded_accesses.empty?

    # At this point, sharded_accesses should all target one map (multi-map handled upstream).
    map_name = sharded_accesses.first[:map_name]
    # Find the map's scope entry to get shard_count
    scope = lookup_scope_for(map_name)
    return unless scope
    entry = scope.locals[map_name]
    map_type = entry&.type
    map_type = Type.new(map_type) unless map_type.is_a?(Type)
    return unless map_type.sharded? && !map_type.any_sync?

    # Check for multiple different key expressions on the same map
    this_map_accesses = sharded_accesses.select { |a| a[:map_name] == map_name }
    key_sources = this_map_accesses.map { |a| a[:key_expr].class.name + ":" + (a[:key_expr].respond_to?(:name) ? a[:key_expr].name.to_s : a[:key_expr].to_s) }.uniq
    if key_sources.length > 1
      note!(conc, "CONCURRENT EACH uses #{key_sources.length} different key expressions on " \
            "@sharded map '#{map_name}'. Routing is based on the first key; other accesses " \
            "with different keys may trigger cross-shard remote calls.")
    end
    key_expr = this_map_accesses.first[:key_expr]

    # Build a synthetic map identifier node for the shard_context
    map_ident = AST::Identifier.new(sharded_accesses.first[:map_token], map_name)
    map_ident.full_type = map_type

    each_op = conc.op
    conc.shard_context = {
      map_var: map_ident,
      shard_count: map_type.shard_count,
      key_expr: key_expr,
      auto_detected: true,  # flag so transpiler knows body uses original _ not key
      key_allocates_frame: false,   # set by LoopFrameAnalysis in Pass 2
      body_allocates_frame: false   # set by LoopFrameAnalysis in Pass 2
    }
  end

  # Recursively walk AST nodes to find GetIndex on @sharded maps.
  def walk_for_sharded_access(nodes, results)
    nodes.each do |node|
      next unless node.is_a?(AST::Locatable)

      # Assignment: map[key] = value
      if node.is_a?(AST::Assignment) && node.name.is_a?(AST::GetIndex)
        gi = node.name
        if gi.target.is_a?(AST::Identifier)
          ti = gi.target.type_info
          if ti.is_a?(Type) && ti.sharded? && !ti.any_sync?
            results << { map_name: gi.target.name, key_expr: gi.index, map_token: gi.target.token }
          end
        end
      end

      # BindExpr: got = map[key] OR "" (the map[key] is inside value)
      if node.is_a?(AST::BindExpr) && node.value
        walk_for_sharded_getindex([node.value], results)
      end

      # Walk children (skip nested BG/DO blocks)
      next if node.is_a?(AST::BgBlock) || node.is_a?(AST::DoBlock)
      node.class.members.each do |member|
        val = node[member]
        if val.is_a?(Array) && member != :body  # don't re-walk body arrays we handle above
          walk_for_sharded_access(val, results)
        end
      end
    end
  end

  # Find GetIndex on @sharded maps in expression context (reads)
  def walk_for_sharded_getindex(nodes, results)
    nodes.each do |node|
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::GetIndex) && node.target.is_a?(AST::Identifier)
        ti = node.target.type_info
        if ti.is_a?(Type) && ti.sharded? && !ti.any_sync?
          results << { map_name: node.target.name, key_expr: node.index, map_token: node.target.token }
        end
      end
      # Recurse into sub-expressions
      node.class.members.each do |member|
        val = node[member]
        if val.is_a?(Array)
          walk_for_sharded_getindex(val, results)
        elsif val.is_a?(AST::Locatable)
          walk_for_sharded_getindex([val], results)
        end
      end
    end
  end

  def analyze_shard_op(node)
    shard_op = node.right  # ShardOp node

    # LHS must be iterable (range or array)
    lhs_type = node.left.type_info
    is_range = node.left.is_a?(AST::RangeLit)
    is_array = node.left.metatype == :array
    is_list  = lhs_type&.list_collection?

    unless is_range || is_array || is_list
      error!(node.left, "SHARD input must be a range or collection, got #{node.left.resolved_type}")
      node.full_type = :Void
      return
    end

    # Determine element type for `_` binding
    item_type = if is_range
      :Int64
    else
      lhs_type.element_type.resolved
    end

    # Type-check key expression with `_` in scope
    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(shard_op.key_expr)
    end

    key_type = shard_op.key_expr.resolved_type

    # Target must be a @sharded map — NOT :locked. Visit before key type check
    # so we can validate numeric key type against the map's declared key type.
    visit(shard_op.target_map)
    target_info = shard_op.target_map.type_info
    unless target_info&.sharded? && !target_info&.any_sync?
      error!(shard_op.target_map, "SHARD target must be a HashMap@sharded(N) without :locked. " \
             "SHARD routes items to owning schedulers — :locked maps don't have ownership.")
    end

    map_key_type = target_info&.key_type&.resolved
    if map_key_type == :String || map_key_type.nil?
      unless key_type == :String
        error!(shard_op.key_expr, "SHARD key expression must evaluate to String for a String-keyed map, got #{key_type}")
      end
    else
      # Numeric-keyed map: key expression must match the map's key type
      unless Type.new(key_type).numeric?
        error!(shard_op.key_expr, "SHARD key expression must evaluate to a numeric type for #{map_key_type}-keyed map, got #{key_type}")
      end
    end

    # SHARD is consumed by the subsequent CONCURRENT EACH — not standalone.
    # Set type to Void; the ConcurrentOp handler reads ShardOp from its LHS.
    node.full_type = :Void
    node.storage = :stack
  end

  VALID_CONCURRENT_OPTIONS = %w[workers parallel size].freeze
  VALID_CONCURRENT_SIZES   = %w[MICRO STANDARD LARGE XL].freeze

  def analyze_concurrent_op(node)
    conc    = node.right   # the ConcurrentOp node
    options = conc.options
    lhs_type = node.left.type_info

    # Validate workers option if present
    if (ps = options["workers"])
      visit(ps)
      unless [:Float64, :Int64].include?(ps.resolved_type)
        error!(ps, "CONCURRENT workers must be a number, got #{ps.resolved_type}")
      end
      # Validate workers > 0 for literal values (including negated literals like -1)
      literal_val = if ps.is_a?(AST::Literal)
        ps.value.to_f
      elsif ps.is_a?(AST::UnaryOp) && ps.op == :SUB && ps.right.is_a?(AST::Literal)
        -ps.right.value.to_f
      end
      if literal_val && literal_val <= 0
        error!(ps, "CONCURRENT workers must be greater than 0, got #{literal_val.to_i}")
      end
    end

    # Validate parallel option is Bool if present
    if (par_val = options["parallel"])
      is_bool = (par_val.is_a?(AST::Literal) && par_val.type == :BOOLEAN) ||
                (par_val.is_a?(AST::Identifier) && %w[true false TRUE FALSE].include?(par_val.name))
      unless is_bool
        error!(par_val, "CONCURRENT parallel must be a Bool (TRUE or FALSE), got #{par_val.class.name.split('::').last}")
      end
    end

    # Validate size option if present: must be one of MICRO STANDARD LARGE XL
    if (sz = options["size"])
      valid = sz.is_a?(AST::Identifier) && VALID_CONCURRENT_SIZES.include?(sz.name)
      unless valid
        got = sz.is_a?(AST::Identifier) ? sz.name : sz.class.name.split("::").last
        error!(sz, "CONCURRENT size must be one of #{VALID_CONCURRENT_SIZES.join(', ')}, got #{got}")
      end
    end

    # Validate that only known option keys are used
    options.each_key do |key|
      unless VALID_CONCURRENT_OPTIONS.include?(key)
        error!(conc, "Unknown CONCURRENT option '#{key}'. Valid options: #{VALID_CONCURRENT_OPTIONS.join(', ')}")
      end
    end

    # Detect SHARD predecessor: (range) s> SHARD(key, map) s> CONCURRENT EACH { ... }
    # node.left is BinaryOp(SMOOTH, range, ShardOp) when SHARD precedes CONCURRENT.
    shard_node = nil
    if node.left.is_a?(AST::BinaryOp) && node.left.op == :SMOOTH && node.left.right.is_a?(AST::ShardOp)
      shard_node = node.left.right
      target_info = shard_node.target_map.type_info
      conc.shard_context = {
        map_var: shard_node.target_map,
        shard_count: target_info&.shard_count,
        key_expr: shard_node.key_expr
      }
    end

    # Type analysis for concurrent ops is identical to synchronous versions.
    # Create a proxy BinaryOp(SMOOTH, left, inner_op) so we can reuse the existing analyze_* methods.
    proxy = AST::BinaryOp.new(node.token, node.left, :SMOOTH, conc.op)

    case conc.op
    when AST::SelectOp, AST::WhereOp
      if bounded_stream_source?(node.left)
        analyze_concurrent_bounded_select_family_op(node)
      elsif node.left.type_info&.inf_stream? || node.left.type_info&.dynamic_stream? ||
            node.left.type_info&.open_stream? || node.left.is_a?(AST::RangeLit)
        analyze_concurrent_stream_select_family_op(node)
      else
        analyze_select_family_op(proxy)
      end
    when AST::EachOp
      if bounded_stream_source?(node.left)
        analyze_concurrent_bounded_each_op(node)
      elsif node.left.type_info&.inf_stream? || node.left.type_info&.dynamic_stream? ||
            node.left.type_info&.open_stream? || node.left.is_a?(AST::RangeLit)
        analyze_concurrent_stream_each_op(node)
      elsif shard_node
        # Explicit SHARD + CONCURRENT EACH: items are String keys.
        analyze_shard_each_op(node, shard_node)
      else
        # Check for @sharded map access — emit warnings for multi-map, auto-shard for single map.
        sharded_names = Set.new
        conc.op.body.each { |stmt| collect_sharded_names(stmt, sharded_names) }

        if sharded_names.length > 1
          emit_multi_map_warning(conc, sharded_names)
          analyze_each_op(proxy)
        elsif sharded_names.length == 1
          analyze_auto_shard_each_op(node, conc, proxy)
        else
          analyze_each_op(proxy)
        end
      end
    when AST::SumOp
      analyze_sum_op(proxy)
    when AST::CountOp
      analyze_count_op(proxy)
    when AST::MinOp
      analyze_min_op(proxy)
    when AST::MaxOp
      analyze_max_op(proxy)
    when AST::AverageOp
      analyze_average_op(proxy)
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

    # SELECT/WHERE/EACH on stream sources set node.full_type directly in their analyze
    # methods. REDUCE ops (SUM/COUNT/etc.) and array sources still use the proxy.
    stream_op_analyzed = (conc.op.is_a?(AST::SelectOp) || conc.op.is_a?(AST::WhereOp) || conc.op.is_a?(AST::EachOp)) &&
                         (bounded_stream_source?(node.left) ||
                          node.left.type_info&.inf_stream? ||
                          node.left.type_info&.dynamic_stream? ||
                          node.left.type_info&.open_stream? ||
                          node.left.is_a?(AST::RangeLit))
    unless stream_op_analyzed
      node.full_type = proxy.full_type
      node.storage   = (node.full_type == :Void) ? :stack : :heap
    end
  end

  def analyze_concurrent_bounded_select_family_op(node)
    lhs_type = node.left.type_info
    item_type = lhs_type.stream_element_type.resolved
    is_parallel = node.right.options["parallel"].is_a?(AST::Identifier) &&
                  %w[true TRUE].include?(node.right.options["parallel"].name)

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) do
        visit(node.right.op.expression)
      end
    end

    node.right.capture_analysis =
      validate_fiber_captures!(node.right, [node.right.op.expression], is_parallel, false) ||
      analyze_fiber_captures([node.right.op.expression], is_parallel: is_parallel)

    if node.right.op.is_a?(AST::WhereOp) && node.right.op.expression.resolved_type != :Bool
      error!(node.right.op, "WHERE clause must evaluate to Bool")
    end

    node.full_type = case node.right.op
    when AST::SelectOp
      :"#{node.right.op.expression.full_type}[]"
    when AST::WhereOp
      :"#{item_type}[]"
    end
    node.storage = :heap
    current_fn_ctx.frame_count += 1 if current_fn_ctx
  end

  def analyze_concurrent_bounded_each_op(node)
    lhs_type = node.left.type_info
    item_type = lhs_type.stream_element_type.resolved
    is_parallel = node.right.options["parallel"].is_a?(AST::Identifier) &&
                  %w[true TRUE].include?(node.right.options["parallel"].name)

    with_new_scope(current_scope) do
      current_scope.declare("_", nil, item_type, true, false, nil, :stack)
      with_soa_tracking(node, item_type) do
        node.right.op.body.each { |stmt| visit(stmt) }
      end
    end

    node.right.capture_analysis =
      validate_fiber_captures!(node.right, node.right.op.body, is_parallel, false) ||
      analyze_fiber_captures(node.right.op.body, is_parallel: is_parallel)

    node.full_type = :Void
    node.storage   = :stack
  end

  # CONCURRENT SELECT/WHERE on ~T[] (dynamic stream) or ~T[INF] (InfStream).
  # Uses BoundedChannel for SPMC back pressure: feeder reads source, workers compete.
  # Produces a materialized list (not another stream) regardless of source kind.
  def analyze_concurrent_stream_select_family_op(node)
    lhs_type = node.left.type_info
    item_type = if lhs_type&.inf_stream?
      inf_stream_element_type(node.left)
    else
      finite_stream_element_type(node.left)
    end
    is_parallel = node.right.options["parallel"].is_a?(AST::Identifier) &&
                  %w[true TRUE].include?(node.right.options["parallel"].name)

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) do
        visit(node.right.op.expression)
      end
    end

    node.right.capture_analysis =
      validate_fiber_captures!(node.right, [node.right.op.expression], is_parallel, false) ||
      analyze_fiber_captures([node.right.op.expression], is_parallel: is_parallel)

    if node.right.op.is_a?(AST::WhereOp) && node.right.op.expression.resolved_type != :Bool
      error!(node.right.op, "WHERE clause must evaluate to Bool")
    end

    node.full_type = case node.right.op
    when AST::SelectOp then :"#{node.right.op.expression.full_type}[]"
    when AST::WhereOp  then :"#{item_type}[]"
    end
    node.storage = :heap
    current_fn_ctx.frame_count += 1 if current_fn_ctx
  end

  # CONCURRENT EACH on ~T[] (dynamic stream) or ~T[INF] (InfStream).
  def analyze_concurrent_stream_each_op(node)
    lhs_type = node.left.type_info
    item_type = if lhs_type&.inf_stream?
      inf_stream_element_type(node.left)
    else
      finite_stream_element_type(node.left)
    end
    is_parallel = node.right.options["parallel"].is_a?(AST::Identifier) &&
                  %w[true TRUE].include?(node.right.options["parallel"].name)

    with_new_scope(current_scope) do
      current_scope.declare("_", nil, item_type, true, false, nil, :stack)
      with_soa_tracking(node, item_type) do
        node.right.op.body.each { |stmt| visit(stmt) }
      end
    end

    node.right.capture_analysis =
      validate_fiber_captures!(node.right, node.right.op.body, is_parallel, false) ||
      analyze_fiber_captures(node.right.op.body, is_parallel: is_parallel)

    node.full_type = :Void
    node.storage   = :stack
  end

  # Helper to validate array/pool input for higher-order ops.
  # Accepts:
  #   - Array types (metatype :array)
  #   - @pool and @pool:sharded(N) collection types
  #   - @list and @list:sharded(N) collection types
  # Returns the CLEAR result type for SUM based on the expression's input type.
  # Signed integers upsize to Int64; unsigned to UInt64; floats stay their own type.
  def sum_result_clear_type(expr_sym)
    case expr_sym
    when :Int8, :Int16, :Int32, :Int64 then :Int64
    when :UInt8, :Byte, :UInt16, :UInt32, :UInt64 then :UInt64
    when :Float32 then :Float32
    else :Float64
    end
  end

  def require_array_input!(node, op_name, allow_range: false, allow_stream: false)
    lhs_type = node.left.type_info
    return if node.left.metatype == :array
    return if lhs_type&.collection?
    return if allow_range && node.left.is_a?(AST::RangeLit)
    return if allow_stream && (lhs_type&.dynamic_stream? || lhs_type&.bounded_stream? ||
                               lhs_type&.inf_stream? || lhs_type&.open_stream?)
    # SELECT uses "from" in error message for historical reasons
    if op_name == "SELECT"
      error!(node.left, "Cannot SELECT from non-list type #{node.left.resolved_type}")
    else
      error!(node.left, "Cannot #{op_name} non-list type #{node.left.resolved_type}")
    end
  end

  # Element type for a range source (used by fusible stage ops applied to ranges).
  def range_element_type(range_node)
    start_ft = range_node.start.respond_to?(:full_type) ? range_node.start.full_type : :Number
    start_ft || :Number
  end

  # =========================================================
  # SOA Opportunity Detection
  # =========================================================
  # Called after visiting a pipeline lambda body.  Checks whether
  # the lambda accessed less than half of the element struct's
  # fields — a signal that SOA layout would improve cache usage.
  #
  # Only triggers for struct elements with >= 4 fields (small
  # structs don't benefit meaningfully from SOA).

  SOA_MIN_FIELDS = 4
  SOA_THRESHOLD  = 0.5  # warn when < 50% of fields accessed

  def check_soa_opportunity!(node, item_type)
    return unless @pipeline_accessed_fields
    accessed = @pipeline_accessed_fields
    return if accessed.empty?

    schema = lookup_type_schema(item_type)
    return unless schema.is_a?(Hash)
    return if schema[:kind] # skip enums, unions, resources

    total = schema.keys.reject { |k| k.is_a?(Symbol) }.size  # only real field names (skip :type_params etc.)
    return if total < SOA_MIN_FIELDS

    ratio = accessed.size.to_f / total
    if ratio < SOA_THRESHOLD
      fields_str = accessed.to_a.sort.join(", ")
      note!(node, "Pipeline accesses #{accessed.size} of #{total} fields (#{fields_str}). " \
                  "Consider @soa for better cache performance on '#{item_type}'.")
    end
  end

  # Wraps a pipeline body visit with SOA field tracking.
  def with_soa_tracking(node, item_type)
    @pipeline_accessed_fields = Set.new
    yield
    check_soa_opportunity!(node, item_type)
  ensure
    @pipeline_accessed_fields = nil
  end
end
