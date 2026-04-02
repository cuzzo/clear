require_relative "../src/ast"
require_relative "../src/type"
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
    node.is_a?(AST::TakeWhileOp)
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
      with_soa_tracking(node, item_type) do
        visit(node.right.expression)
      end

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

    # WHERE/SELECT/ORDER_BY allocate intermediate ArrayListUnmanaged at the
    # transpiler level via rt.frameAlloc(). Signal this so compute_needs_rt!
    # propagates the Runtime dependency correctly.
    current_fn_ctx.frame_count += 1 if current_fn_ctx
  end

  def analyze_take_while_op(node)
    require_array_input!(node, "TAKE_WHILE")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      visit(node.right.expression)
    end

    unless node.right.expression.resolved_type == :Bool
      error!(node.right, "TAKE_WHILE predicate must evaluate to Bool, got #{node.right.expression.resolved_type}")
    end

    node.full_type = :"#{item_type}[]"
    node.storage = :frame
    current_fn_ctx.frame_count += 1 if current_fn_ctx
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
      with_soa_tracking(node, item_type) do
        node.right.body.each { |stmt| visit(stmt) }
      end
    end

    node.full_type = :Void
    node.storage   = :frame
  end

  def analyze_skip_op(node)
    # SKIP: list s> SKIP n -> same list type with first n elements removed
    require_array_input!(node, "SKIP")
    item_type = node.left.type_info.element_type.resolved

    visit(node.right.count)
    count_type = node.right.count.resolved_type
    unless [:Int64, :Number].include?(count_type)
      error!(node.right.count, "SKIP count must be a number, got #{count_type}")
    end

    node.full_type = :"#{item_type}[]"
    node.storage = :frame
  end

  def analyze_tap_op(node)
    # TAP: list s> TAP { body } -> same list type (pass-through)
    lhs_type = node.left.type_info
    is_pool  = lhs_type&.pool?
    is_list  = lhs_type&.list_collection?
    is_array = node.left.metatype == :array

    unless is_pool || is_list || is_array
      error!(node.left, "Cannot TAP non-collection type #{node.left.resolved_type}.")
      node.full_type = :Void
      return
    end

    item_type = lhs_type.element_type.resolved

    with_new_scope do
      # Read-only: TAP is for observation, not mutation
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      node.right.body.each { |stmt| visit(stmt) }
    end

    # TAP returns the original collection (pass-through)
    node.full_type = node.left.full_type
    node.storage = node.left.storage
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

  # Use Type#numeric? for consistency with the type system.
  # Covers :Number, :Int64, :Byte, :Float64.

  def analyze_sum_op(node)
    # SUM: list s> SUM _.field  → Number (sum of numeric projection; 0 for empty list)
    require_array_input!(node, "SUM")
    item_type = node.left.type_info.element_type.resolved

    with_new_scope do
      current_scope.declare("_", nil, item_type, false, false, nil, :stack)
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
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
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
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
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
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
      with_soa_tracking(node, item_type) { visit(node.right.expression) }
    end

    expr_type = node.right.expression.resolved_type
    unless Type.new(expr_type).numeric?
      error!(node.right, "MAX requires a numeric expression, got #{expr_type}")
    end

    node.full_type = :Number
    node.storage   = :stack
  end

  # =========================================================
  # SHARD: route pipeline items to owning schedulers by key hash
  # =========================================================

  # SHARD + CONCURRENT EACH: the EACH body sees `_` as a String key.
  def analyze_shard_each_op(node, shard_node)
    conc = node.right
    each_op = conc.op

    with_new_scope do
      # `_` is a String key (the output of SHARD's key expression)
      current_scope.declare("_", nil, :String, true, false, nil, :stack)
      each_op.body.each { |stmt| visit(stmt) }
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
    is_range = smooth_node.left.is_a?(AST::RangeLit)
    is_array = smooth_node.left.metatype == :array
    is_list  = lhs_type&.list_collection?

    item_type = if is_range
      :Int64
    elsif is_array || is_list
      lhs_type.element_type.resolved
    else
      error!(smooth_node.left, "CONCURRENT EACH input must be a range or collection, got #{smooth_node.left.resolved_type}")
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

    conc.shard_context = {
      map_var: map_ident,
      shard_count: map_type.shard_count,
      key_expr: key_expr,
      auto_detected: true  # flag so transpiler knows body uses original _ not key
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
    unless key_type == :String
      error!(shard_op.key_expr, "SHARD key expression must evaluate to String, got #{key_type}")
    end

    # Target must be a @sharded (PartitionedStringMap) — NOT :locked
    visit(shard_op.target_map)
    target_info = shard_op.target_map.type_info
    unless target_info&.sharded? && !target_info&.any_sync?
      error!(shard_op.target_map, "SHARD target must be a HashMap@sharded(N) without :locked. " \
             "SHARD routes items to owning schedulers — :locked maps don't have ownership.")
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

    # Validate workers option if present
    if (ps = options["workers"])
      visit(ps)
      unless [:Number, :Int64].include?(ps.resolved_type)
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
      analyze_select_family_op(proxy)
    when AST::EachOp
      if shard_node
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

    node.full_type = proxy.full_type
    node.storage   = (node.full_type == :Void) ? :stack : :heap
  end

  # Helper to validate array/pool input for higher-order ops.
  # Accepts:
  #   - Array types (metatype :array)
  #   - @pool and @pool:sharded(N) collection types
  #   - @list and @list:sharded(N) collection types
  def require_array_input!(node, op_name)
    lhs_type = node.left.type_info
    return if node.left.metatype == :array
    return if lhs_type&.collection?
    # SELECT uses "from" in error message for historical reasons
    if op_name == "SELECT"
      error!(node.left, "Cannot SELECT from non-list type #{node.left.resolved_type}")
    else
      error!(node.left, "Cannot #{op_name} non-list type #{node.left.resolved_type}")
    end
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
