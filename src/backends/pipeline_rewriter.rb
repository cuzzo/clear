require_relative "../ast/ast"
require_relative "../ast/std_lib"

# Pipeline Rewriter — transforms high-level pipeline operators (|>) into 
# regular AST nodes (ForEach, IfStatement, BlockExpr) AFTER annotation.
#
# Running after annotation allows us to use type information for things like
# correctly typed accumulators and preserving error-unwrapping semantics.
#
# Since we run after annotation, we manually stamp newly created nodes with
# type and storage information so the transpiler can process them correctly.
class PipelineRewriter
  FUSIBLE_STAGES = [AST::WhereOp, AST::SelectOp, AST::TapOp, AST::TakeWhileOp,
                    AST::SkipOp, AST::LimitOp].freeze
  TERMINAL_FOLDS = [AST::SumOp, AST::AverageOp, AST::CountOp, AST::ReduceOp,
                    AST::AnyOp, AST::AllOp, AST::FindOp, AST::MinOp, AST::MaxOp].freeze
  # OrderByOp, IndexOp, WindowOp, JoinOp: require Zig-specific constructs
  # (comparator structs, HashMap ops, dual-source joins). These fall through
  # to the pipeline_generator path.
  LIST_TERMINALS = [AST::UnnestOp, AST::DistinctOp].freeze

  def initialize(annotator = nil)
    @annotator = annotator
    @var_counter = 0
  end

  def rewrite!(node)
    return node unless node

    # Handle SMOOTH nodes BEFORE recursing into children.
    # This preserves pipeline chains (a |> WHERE |> SELECT |> SUM)
    # so collect_chain can discover and fuse them into a single loop.
    if node.is_a?(AST::BinaryOp) && node.op == :SMOOTH
      return rewrite_pipeline(node)
    end

    rewrite_children!(node)
    node
  end

  private

  def next_var(prefix = "__v")
    @var_counter += 1
    "#{prefix}#{@var_counter}"
  end

  def rewrite_children!(node)
    case node
    when AST::Program
      node.statements&.map! { |s| rewrite!(s) }
    when AST::FunctionDef
      node.body&.map! { |s| rewrite!(s) }
    when AST::VarDecl, AST::BindExpr
      node.value = rewrite!(node.value) if node.value
    when AST::Assignment
      node.value = rewrite!(node.value) if node.respond_to?(:value) && node.value
    when AST::ReturnNode
      node.value = rewrite!(node.value) if node.value
    when AST::IfStatement
      node.condition = rewrite!(node.condition)
      node.then_branch&.map! { |s| rewrite!(s) }
      node.else_branch&.map! { |s| rewrite!(s) }
    when AST::MatchStatement
      node.expr = rewrite!(node.expr)
      (node.cases || []).each { |c| c[:body]&.map! { |s| rewrite!(s) } }
      node.default_case&.map! { |s| rewrite!(s) } if node.default_case
    when AST::WhileLoop
      node.condition = rewrite!(node.condition)
      node.do_branch&.map! { |s| rewrite!(s) } if node.do_branch.is_a?(Array)
    when AST::ForRange
      node.start_expr = rewrite!(node.start_expr)
      node.end_expr = rewrite!(node.end_expr)
      node.body&.map! { |s| rewrite!(s) }
    when AST::ForEach
      node.collection = rewrite!(node.collection)
      node.body&.map! { |s| rewrite!(s) }
    when AST::BinaryOp
      node.left = rewrite!(node.left)
      node.right = rewrite!(node.right)
    when AST::UnaryOp
      node.right = rewrite!(node.right)
    when AST::FuncCall, AST::MethodCall
      node.args&.map! { |a| rewrite!(a) }
    when AST::StructLit
      node.fields.each { |k, v| node.fields[k] = rewrite!(v) }
    when AST::ListLit
      node.items&.map! { |i| rewrite!(i) }
    when AST::BlockExpr
      node.body&.map! { |s| rewrite!(s) }
      node.result = rewrite!(node.result)
    end
  end

  def rewrite_pipeline(node)
    source = node.left
    rhs = node.right

    # Collect the chain FIRST (before any recursive rewriting).
    chain = collect_chain(node)
    stages = chain[:stages]
    terminal = chain[:terminal]
    real_source = chain[:source]

    # Named binding chains (source AS @u |> UNNEST ...) must reach the MIR
    # lowering intact so lower_binding_chain can fuse them into nested loops
    # with correct @u -> loop_var substitution. PipelineRewriter has no concept
    # of named bindings and would emit @u as a raw identifier.
    return node if binding_source?(real_source)

    # Rewrite the source (it may contain nested pipelines in non-chain positions).
    # real_source is the non-SMOOTH root of the chain; safe to rewrite recursively.
    real_source = rewrite!(real_source)

    # Skip rewriting for pool, sharded, SOA sources, and when the source is
    # itself a pipeline (e.g. data |> SKIP 2 |> SUM _). These need special
    # iteration patterns that the transpiler's pipeline_generator handles.
    if needs_transpiler_pipeline?(real_source) || (real_source.is_a?(AST::BinaryOp) && real_source.op == :SMOOTH)
      # Only patch if the source actually changed; patching the same object
      # back into the chain creates a circular reference.
      patch_chain_source!(node, real_source) unless real_source.equal?(chain[:source])
      return node
    end

    # Phase 2+: range source with EACH or fold terminal and only fusible
    # intermediate stages uses the lazy MIR path. Bypass PipelineRewriter
    # fusion so the BinaryOp chain reaches lower_smooth -> lower_each /
    # lower_range_fold intact; those methods unwrap the chain and emit a
    # single fused while loop.
    is_range_fold_terminal = terminal.is_a?(AST::EachOp) ||
                             TERMINAL_FOLDS.any? { |t| terminal.is_a?(t) }
    # Infinite streams (~T[INF]) are included only when a LimitOp stage is present:
    # they require LIMIT to be finite.  Other stream types bypass unconditionally.
    inf_with_limit = real_source.type_info&.inf_stream? &&
                     stages.any? { |s| s.is_a?(AST::LimitOp) }
    if (real_source.is_a?(AST::RangeLit) || real_source.type_info&.dynamic_stream? ||
        real_source.type_info&.open_stream? ||
        real_source.type_info&.bounded_stream? || inf_with_limit) && is_range_fold_terminal &&
       stages.all? { |s| FUSIBLE_STAGES.any? { |t| s.is_a?(t) } }
      patch_chain_source!(node, real_source) unless real_source.equal?(chain[:source])
      return node
    end

    # DISTINCT always bypasses to pipeline_host lower_distinct: it handles
    # list and all stream sources via a Set-accumulating for/while loop.
    # The rewriter's fuse_pipeline path can't be used here because lower_var_decl
    # short-circuits on set_collection? and emits an empty set, discarding the
    # BlockExpr produced by fuse_pipeline.
    if terminal.is_a?(AST::DistinctOp) &&
       stages.all? { |s| FUSIBLE_STAGES.any? { |t| s.is_a?(t) } }
      patch_chain_source!(node, real_source) unless real_source.equal?(chain[:source])
      return node
    end

    # INDEX on a finite or LIMIT-bounded stream source bypasses: the MIR lowering
    # handles it as a lazy while loop (lower_stream_index via unwrap_range_chain).
    # inf_with_limit reuses the variable already computed above.
    is_stream_index = terminal.is_a?(AST::IndexOp) &&
                      (real_source.type_info&.dynamic_stream? || real_source.type_info&.open_stream? ||
                       real_source.type_info&.bounded_stream? || inf_with_limit) &&
                      stages.all? { |s| FUSIBLE_STAGES.any? { |t| s.is_a?(t) } }
    if is_stream_index
      patch_chain_source!(node, real_source) unless real_source.equal?(chain[:source])
      return node
    end

    # CASE 1: Fusion candidate (chained fusible stages or ending in a fold/EachOp)
    is_fold = terminal.nil? || terminal.is_a?(AST::EachOp) ||
              TERMINAL_FOLDS.any? { |t| terminal.is_a?(t) } ||
              LIST_TERMINALS.any? { |t| terminal.is_a?(t) }

    if stages.any? || (is_fold && terminal)
      if is_fold
        return fuse_pipeline(node, real_source, stages, terminal)
      else
        # Fusion chain ending in a non-fold terminal (e.g. MIN, MAX, FIND).
        # Fuse the stages into a loop that produces an intermediate list,
        # then pipe that list to the terminal via a new SMOOTH node.
        # Use the source's collection type for the intermediate list (not
        # the terminal's scalar result type).
        list_proxy = node.dup
        list_proxy.full_type = real_source.full_type
        list_proxy.storage   = real_source.storage
        fused_loop = fuse_pipeline(list_proxy, real_source, stages, nil)

        # Create a new SMOOTH node for the terminal call
        outer_smooth = AST::BinaryOp.new(node.token, fused_loop, :SMOOTH, terminal.dup)
        outer_smooth.full_type = node.full_type
        outer_smooth.storage   = node.storage

        return rewrite_pipeline(outer_smooth)
      end
    end

    # For non-chain cases, source = node.left which may itself be a SMOOTH.
    # real_source was already rewritten above; use it as the rewritten source.
    source = real_source

    # CASE 2/3: x |> f(y) -> f(x, y) or x |> f -> f(x)
    # Skip rewriting when the callee returns an error union — the transpiler's
    # transpile_Smooth handles error propagation and snapshot semantics for CATCH.
    # The SMOOTH's full_type may already be unwrapped by CATCH, so also check
    # the callee's declared return type.
    result_is_error = node.full_type && Type.new(node.full_type).error_union?
    result_is_error ||= callee_returns_error?(rhs)
    needs_try = source.respond_to?(:full_type) && source.full_type && Type.new(source.full_type).error_union?

    if rhs.is_a?(AST::FuncCall) && !result_is_error
      lhs_node = needs_try ? AST::UnaryOp.new(rhs.token, :TRY, source.dup) : source.dup
      if needs_try
        lhs_node.full_type = Type.new(source.full_type).payload_type
      end

      rhs.args.unshift(lhs_node)
      return rhs
    end

    if rhs.is_a?(AST::Identifier) && !result_is_error
      lhs_node = needs_try ? AST::UnaryOp.new(rhs.token, :TRY, source.dup) : source.dup
      if needs_try
        lhs_node.full_type = Type.new(source.full_type).payload_type
      end

      call = AST::FuncCall.new(rhs.token, rhs.name, [lhs_node])
      call.full_type = node.full_type
      call.storage   = node.storage
      config = STD_LIB[rhs.name]
      if config
        call.zig_pattern = config.is_a?(Array) ? config.first[:zig] : config[:zig]
      end
      return call
    end

    # CASE 4: x |> RECOVER(default) -> x OR default
    if rhs.is_a?(AST::RecoverOp)
      op = AST::BinaryOp.new(rhs.token, source.dup, :OR_RESCUE, rhs.default_expr.dup)
      op.full_type = node.full_type
      op.storage   = node.storage
      return op
    end

    node
  end

  def is_fusible?(node)
    FUSIBLE_STAGES.any? { |t| node.is_a?(t) }
  end

  # Returns true if the node is, or contains, a BIND_VAR-sourced pipeline.
  # These are handled by MIR lowering (lower_binding_chain) which performs
  # correct @u -> loop_var substitution. PipelineRewriter must leave them alone.
  def binding_source?(node)
    return true if node.is_a?(AST::BinaryOp) && node.op == :BIND_VAR
    return false unless node.is_a?(AST::BinaryOp) && node.op == :SMOOTH
    # Walk the source chain to find if its root is a BIND_VAR.
    inner_src = collect_chain(node)[:source]
    inner_src.is_a?(AST::BinaryOp) && inner_src.op == :BIND_VAR
  end

  def collect_chain(node)
    stages = []
    cursor = node
    terminal = nil

    # Identify the terminal operation.
    right = node.right
    if TERMINAL_FOLDS.any? { |t| right.is_a?(t) } || right.is_a?(AST::EachOp) || LIST_TERMINALS.any? { |t| right.is_a?(t) }
      terminal = right
      cursor = node.left
    elsif is_fusible?(right)
      terminal = nil # implicit list terminal
      cursor = node
    else
      # Standard function terminal
      terminal = right
      cursor = node.left
    end

    # Now walk back through fusible stages
    while cursor.is_a?(AST::BinaryOp) && cursor.op == :SMOOTH
      r = cursor.right
      if is_fusible?(r)
        stages.unshift(r)
        cursor = cursor.left
      else
        break
      end
    end

    { source: cursor, stages: stages, terminal: terminal }
  end

  def fuse_pipeline(smooth_node, source, stages, terminal)
    # Generate unique variable names for this pipeline
    res_var = next_var("__res")
    it_var = next_var("__it")
    token = smooth_node.token

    body = []
    
    # 1. Initialize result container or accumulator(s)
    init_nodes = build_init(terminal, res_var, token, smooth_node)
    body.concat(init_nodes)

    # 2. Build loop body
    current_it = AST::Identifier.new(token, it_var)
    if source.respond_to?(:full_type) && source.full_type
      src_t = Type.new(source.full_type)
      elem_t = if src_t.open_stream?
        src_t.open_stream_element_type
      elsif src_t.dynamic_stream? || src_t.bounded_stream?
        src_t.tense_type.element_type
      elsif src_t.inf_stream?
        src_t.inf_stream_element_type
      else
        src_t.element_type
      end
      current_it.full_type = elem_t if elem_t
    end

    stage_inits = []
    res_type = smooth_node.full_type
    loop_body = build_recursive_body(stages, terminal, current_it, res_var, token, stage_inits, res_type)
    body.concat(stage_inits)

    # 3. Create ForEach loop
    is_each = terminal.is_a?(AST::EachOp)
    foreach = AST::ForEach.new(token, it_var, source.dup, loop_body, nil, is_each)
    foreach.full_type = :Void
    foreach.instance_variable_set(:@var_used, true)
    body << foreach

    # 4. Post-loop guards
    if terminal.is_a?(AST::MinOp) || terminal.is_a?(AST::MaxOp)
      found_ident = AST::Identifier.new(token, "#{res_var}_found")
      found_ident.full_type = :Bool
      guard = AST::Assert.new(token, found_ident, "MIN/MAX applied to empty list")
      guard.full_type = :Void
      body << guard
    end

    # 5. Result
    if terminal.is_a?(AST::EachOp)
      # EACH is void — no result, no BlockExpr wrapper needed.
      # Return the ForEach directly (or wrap in a sequence if there are init nodes).
      return foreach if body.length == 1
      wrapper = AST::BlockExpr.new(token, body, nil)
      wrapper.full_type = :Void
      return wrapper
    end

    # For AVERAGE, guard against division by zero (empty list -> 0.0).
    # Emit: MUTABLE __resN = 0.0; if cnt > 0 { __resN = sum / cnt; }
    if terminal.is_a?(AST::AverageOp)
      avg_var = "#{res_var}_avg"
      zero = AST::Literal.new(token, :NUMBER, 0.0)
      zero.full_type = :Float64
      avg_decl = AST::VarDecl.new(token, avg_var, nil, zero.dup, true)
      avg_decl.full_type = :Float64
      avg_decl.storage   = :stack
      avg_decl.slot_size = 1
      avg_decl.instance_variable_set(:@var_used, true)
      avg_decl.var_mutated = true
      body << avg_decl

      sum_id = AST::Identifier.new(token, "#{res_var}_sum")
      cnt_id = AST::Identifier.new(token, "#{res_var}_cnt")
      sum_id.full_type = :Float64
      cnt_id.full_type = :Float64
      cond = AST::BinaryOp.new(token, cnt_id.dup, :GT, zero.dup)
      cond.full_type = :Bool
      div = AST::BinaryOp.new(token, sum_id, :DIV, cnt_id)
      div.full_type = :Float64
      avg_assign = AST::Assignment.new(token, avg_var, div)
      avg_assign.full_type = :Float64
      guard = AST::IfStatement.new(token, cond, [avg_assign], nil)
      guard.full_type = :Void
      body << guard

      result = AST::Identifier.new(token, avg_var)
      result.full_type = :Float64
    else
      result = build_final_result(terminal, res_var, token, smooth_node)
    end

    block = AST::BlockExpr.new(token, body, result)
    block.full_type = smooth_node.full_type
    block.storage   = smooth_node.storage
    block
  end

  def build_init(terminal, res_var, token, smooth_node)
    case terminal
    when AST::SumOp, AST::CountOp
      is_int = Type.new(smooth_node.full_type).integer?
      val = AST::Literal.new(token, is_int ? :INT64 : :NUMBER, is_int ? 0 : 0.0)
      val.full_type = smooth_node.full_type
      decl = AST::VarDecl.new(token, res_var, nil, val, true)
      decl.full_type = smooth_node.full_type
      decl.storage   = :stack
      decl.slot_size = 1
      decl.instance_variable_set(:@var_used, true)
      decl.var_mutated = true
      [decl]
    when AST::AverageOp
      # Two accumulators: sum and count
      sum_decl = AST::VarDecl.new(token, "#{res_var}_sum", nil, AST::Literal.new(token, :NUMBER, 0.0), true)
      sum_decl.full_type = :Float64
      sum_decl.storage   = :stack
      sum_decl.slot_size = 1
      sum_decl.instance_variable_set(:@var_used, true)
      sum_decl.var_mutated = true

      cnt_decl = AST::VarDecl.new(token, "#{res_var}_cnt", nil, AST::Literal.new(token, :NUMBER, 0.0), true)
      cnt_decl.full_type = :Float64
      cnt_decl.storage   = :stack
      cnt_decl.slot_size = 1
      cnt_decl.instance_variable_set(:@var_used, true)
      cnt_decl.var_mutated = true

      [sum_decl, cnt_decl]
    when AST::AnyOp, AST::AllOp
      init_val = terminal.is_a?(AST::AllOp)
      val = AST::Literal.new(token, :BOOLEAN, init_val)
      val.full_type = :Bool
      decl = AST::VarDecl.new(token, res_var, nil, val, true)
      decl.full_type = :Bool
      decl.storage   = :stack
      decl.slot_size = 1
      decl.instance_variable_set(:@var_used, true)
      decl.var_mutated = true
      [decl]
    when AST::ReduceOp
      decl = AST::VarDecl.new(token, res_var, nil, terminal.initial_value.dup, true)
      decl.full_type = terminal.full_type
      decl.storage   = :stack
      decl.slot_size = Type.new(decl.full_type).slot_size(schema_lookup)
      decl.instance_variable_set(:@var_used, true)
      decl.var_mutated = true
      [decl]
    when AST::FindOp
      val = AST::Literal.new(token, :NIL, nil)
      val.full_type = :NIL
      decl = AST::VarDecl.new(token, res_var, nil, val, true)
      decl.full_type = smooth_node.full_type
      decl.storage   = :stack
      decl.slot_size = Type.new(decl.full_type).slot_size(schema_lookup)
      decl.instance_variable_set(:@var_used, true)
      decl.var_mutated = true
      [decl]
    when AST::MinOp, AST::MaxOp
      # Found-flag pattern: first element always sets result, subsequent compare
      zero = AST::Literal.new(token, :NUMBER, 0.0)
      zero.full_type = :Float64
      val_decl = AST::VarDecl.new(token, res_var, nil, zero, true)
      val_decl.full_type = :Float64
      val_decl.storage   = :stack
      val_decl.slot_size = 1
      val_decl.instance_variable_set(:@var_used, true)
      val_decl.var_mutated = true

      found_init = AST::Literal.new(token, :BOOLEAN, false)
      found_init.full_type = :Bool
      found_decl = AST::VarDecl.new(token, "#{res_var}_found", nil, found_init, true)
      found_decl.full_type = :Bool
      found_decl.storage   = :stack
      found_decl.slot_size = 1
      found_decl.instance_variable_set(:@var_used, true)
      found_decl.var_mutated = true

      [val_decl, found_decl]
    when nil, AST::SelectOp, AST::WhereOp, AST::TapOp, AST::TakeWhileOp,
         AST::UnnestOp, AST::DistinctOp
      lit = AST::ListLit.new(token, [], :stack)
      lit.full_type = smooth_node.full_type
      decl = AST::VarDecl.new(token, res_var, nil, lit, true)
      decl.full_type = smooth_node.full_type
      decl.storage   = smooth_node.storage
      decl.slot_size = Type.new(decl.full_type).slot_size(schema_lookup)
      decl.instance_variable_set(:@var_used, true)
      [decl]
    else
      []
    end
  end

  def build_recursive_body(stages, terminal, current_val, res_var, token, stage_inits = [], res_type = nil)
    if stages.empty?
      return build_terminal_action(terminal, current_val, res_var, token, res_type)
    end

    stage = stages.first
    remaining = stages[1..-1]

    case stage
    when AST::WhereOp
      pred = replace_placeholder(stage.expression, current_val)
      then_branch = build_recursive_body(remaining, terminal, current_val, res_var, token, stage_inits, res_type)
      if_stmt = AST::IfStatement.new(stage.token, pred, then_branch, nil)
      if_stmt.full_type = :Void
      [if_stmt]
    when AST::SelectOp
      expr = replace_placeholder(stage.expression, current_val)
      # Bind SELECT result to a temp so it is never inlined into an expression
      # position. Zig forbids StructType{...}.field in arithmetic/boolean contexts.
      sel_var = next_var("__sel")
      sel_decl = AST::VarDecl.new(stage.token, sel_var, nil, expr, false)
      sel_decl.full_type = stage.expression.full_type
      sel_decl.storage   = :stack
      sel_decl.slot_size = 0
      sel_decl.instance_variable_set(:@var_used, true)
      sel_ident = AST::Identifier.new(stage.token, sel_var)
      sel_ident.full_type = stage.expression.full_type
      rest = build_recursive_body(remaining, terminal, sel_ident, res_var, token, stage_inits, res_type)
      [sel_decl] + rest
    when AST::TapOp
      tap_body = stage.body.map { |s| replace_placeholder(s, current_val) }
      tap_body + build_recursive_body(remaining, terminal, current_val, res_var, token, stage_inits, res_type)
    when AST::TakeWhileOp
      pred = replace_placeholder(stage.expression, current_val)
      then_branch = build_recursive_body(remaining, terminal, current_val, res_var, token, stage_inits, res_type)
      if_stmt = AST::IfStatement.new(stage.token, pred, then_branch, [AST::BreakNode.new(stage.token)])
      if_stmt.full_type = :Void
      [if_stmt]
    when AST::SkipOp
      cnt_var = next_var("__skip_cnt")
      zero = AST::Literal.new(token, :INT64, 0)
      zero.full_type = :Int64
      cnt_decl = AST::VarDecl.new(token, cnt_var, nil, zero, true)
      cnt_decl.full_type = :Int64
      cnt_decl.storage = :stack
      cnt_decl.slot_size = 1
      cnt_decl.instance_variable_set(:@var_used, true)
      cnt_decl.var_mutated = true
      stage_inits << cnt_decl

      cnt_ident = AST::Identifier.new(token, cnt_var)
      cnt_ident.full_type = :Int64
      one = AST::Literal.new(token, :INT64, 1)
      one.full_type = :Int64
      increment = AST::Assignment.new(token, cnt_ident, AST::BinaryOp.new(token, cnt_ident.dup, :ADD, one))
      increment.full_type = :Void

      skip_n = stage.count.dup
      cond = AST::BinaryOp.new(token, cnt_ident.dup, :LTE, skip_n)
      cond.full_type = :Bool
      skip_if = AST::IfStatement.new(token, cond, [AST::ContinueNode.new(token)], nil)
      skip_if.full_type = :Void

      rest = build_recursive_body(remaining, terminal, current_val, res_var, token, stage_inits, res_type)
      [increment, skip_if] + rest
    when AST::LimitOp
      cnt_var = next_var("__lim_cnt")
      zero = AST::Literal.new(token, :INT64, 0)
      zero.full_type = :Int64
      cnt_decl = AST::VarDecl.new(token, cnt_var, nil, zero, true)
      cnt_decl.full_type = :Int64
      cnt_decl.storage = :stack
      cnt_decl.slot_size = 1
      cnt_decl.instance_variable_set(:@var_used, true)
      cnt_decl.var_mutated = true
      stage_inits << cnt_decl

      cnt_ident = AST::Identifier.new(token, cnt_var)
      cnt_ident.full_type = :Int64
      one = AST::Literal.new(token, :INT64, 1)
      one.full_type = :Int64
      increment = AST::Assignment.new(token, cnt_ident, AST::BinaryOp.new(token, cnt_ident.dup, :ADD, one))
      increment.full_type = :Void

      limit_n = stage.count.dup
      cond = AST::BinaryOp.new(token, cnt_ident.dup, :GT, limit_n)
      cond.full_type = :Bool
      limit_if = AST::IfStatement.new(token, cond, [AST::BreakNode.new(token)], nil)
      limit_if.full_type = :Void

      rest = build_recursive_body(remaining, terminal, current_val, res_var, token, stage_inits, res_type)
      [increment, limit_if] + rest
    else
      build_recursive_body(remaining, terminal, current_val, res_var, token, stage_inits, res_type)
    end
  end

  def build_terminal_action(terminal, current_val, res_var, token, res_type = nil)
    res_ident = AST::Identifier.new(token, res_var)
    res_ident.full_type = res_type if res_type
    case terminal
    when AST::SumOp
      expr = replace_placeholder(terminal.expression, current_val)
      assign = AST::Assignment.new(token, res_ident, AST::BinaryOp.new(token, res_ident, :ADD, expr))
      assign.full_type = :Void
      [assign]
    when AST::CountOp
      expr = replace_placeholder(terminal.expression, current_val)
      one = AST::Literal.new(token, :INT64, 1)
      increment = AST::Assignment.new(token, res_ident, AST::BinaryOp.new(token, res_ident, :ADD, one))
      increment.full_type = :Void
      if_stmt = AST::IfStatement.new(token, expr, [increment], nil)
      if_stmt.full_type = :Void
      [if_stmt]
    when AST::AverageOp
      expr = replace_placeholder(terminal.expression, current_val)
      sum_ident = AST::Identifier.new(token, "#{res_var}_sum")
      cnt_ident = AST::Identifier.new(token, "#{res_var}_cnt")
      [AST::Assignment.new(token, sum_ident, AST::BinaryOp.new(token, sum_ident, :ADD, expr)),
       AST::Assignment.new(token, cnt_ident, AST::BinaryOp.new(token, cnt_ident, :ADD, AST::Literal.new(token, :NUMBER, 1.0)))]
    when AST::AnyOp
      expr = replace_placeholder(terminal.expression, current_val)
      set_true = AST::Assignment.new(token, res_ident, AST::Literal.new(token, :BOOLEAN, true))
      set_true.full_type = :Void
      if_stmt = AST::IfStatement.new(token, expr, [set_true, AST::BreakNode.new(token)], nil)
      if_stmt.full_type = :Void
      [if_stmt]
    when AST::AllOp
      expr = replace_placeholder(terminal.expression, current_val)
      set_false = AST::Assignment.new(token, res_ident, AST::Literal.new(token, :BOOLEAN, false))
      set_false.full_type = :Void
      if_stmt = AST::IfStatement.new(token, AST::UnaryOp.new(token, :NOT, expr), [set_false, AST::BreakNode.new(token)], nil)
      if_stmt.full_type = :Void
      [if_stmt]
    when AST::ReduceOp
      expr = replace_placeholder(terminal.expression, current_val)
      expr = replace_named_placeholder(expr, "acc", res_ident)
      assign = AST::Assignment.new(token, res_ident, expr)
      assign.full_type = :Void
      [assign]
    when AST::FindOp
      expr = replace_placeholder(terminal.expression, current_val)
      assign = AST::Assignment.new(token, res_ident, current_val.dup)
      assign.full_type = :Void
      if_stmt = AST::IfStatement.new(token, expr, [assign, AST::BreakNode.new(token)], nil)
      if_stmt.full_type = :Void
      [if_stmt]
    when AST::MinOp, AST::MaxOp
      expr = replace_placeholder(terminal.expression, current_val)
      op = terminal.is_a?(AST::MinOp) ? :LT : :GT
      found_ident = AST::Identifier.new(token, "#{res_var}_found")
      found_ident.full_type = :Bool

      # if !found || expr < res { res = expr; found = true }
      not_found = AST::UnaryOp.new(token, :NOT, found_ident.dup)
      not_found.full_type = :Bool
      cmp = AST::BinaryOp.new(token, expr, op, res_ident.dup)
      cmp.full_type = :Bool
      cond = AST::BinaryOp.new(token, not_found, :OR, cmp)
      cond.full_type = :Bool

      assign_val = AST::Assignment.new(token, res_ident, expr.dup)
      assign_val.full_type = :Void
      set_found = AST::Assignment.new(token, found_ident, AST::Literal.new(token, :BOOLEAN, true))
      set_found.full_type = :Void

      if_stmt = AST::IfStatement.new(token, cond, [assign_val, set_found], nil)
      if_stmt.full_type = :Void
      [if_stmt]
    when AST::EachOp
      terminal.body.map { |s| replace_placeholder(s, current_val) }
    when AST::UnnestOp
      # Nested loop: for each item, iterate over the inner list and append each element
      inner_expr = replace_placeholder(terminal.expression, current_val)
      inner_it_var = next_var("__it")

      inner_it = AST::Identifier.new(token, inner_it_var)

      append = AST::MethodCall.new(token, res_ident, "append", [inner_it.dup])
      append.full_type = :Void
      append.zig_pattern = STD_LIB["append"][:zig]
      append.matched_stdlib_def = STD_LIB["append"]

      # Iterate directly over the expression (avoids ArrayList/slice confusion).
      # Mark collection as a slice so the transpiler uses &expr, not .items.
      inner_foreach = AST::ForEach.new(token, inner_it_var, inner_expr, [append], nil, false)
      inner_foreach.full_type = :Void
      inner_foreach.instance_variable_set(:@var_used, true)

      [inner_foreach]
    when AST::DistinctOp
      # Set insert: result is a T[]@set; insert deduplicates in O(1).
      key_expr = replace_placeholder(terminal.expression, current_val)
      insert_call = AST::MethodCall.new(token, res_ident.dup, "insert", [key_expr])
      insert_call.full_type = :Void
      insert_call.zig_pattern = "try {0}.insert({alloc}, {1})"
      insert_call.matched_stdlib_def = STD_LIB["insert"] if STD_LIB.key?("insert")
      [insert_call]
    when nil, AST::SelectOp, AST::WhereOp, AST::TapOp, AST::TakeWhileOp
      # Produces a list
      call = AST::MethodCall.new(token, res_ident, "append", [current_val.dup])
      call.full_type = :Void
      call.zig_pattern = STD_LIB["append"][:zig]
      call.matched_stdlib_def = STD_LIB["append"]
      [call]
    else
      call = AST::MethodCall.new(token, res_ident, "append", [current_val.dup])
      call.zig_pattern = STD_LIB["append"][:zig]
      call.matched_stdlib_def = STD_LIB["append"]
      [call]
    end
  end

  def build_final_result(terminal, res_var, token, smooth_node)
    if terminal.is_a?(AST::AverageOp)
      sum_ident = AST::Identifier.new(token, "#{res_var}_sum")
      cnt_ident = AST::Identifier.new(token, "#{res_var}_cnt")
      sum_ident.full_type = :Float64
      cnt_ident.full_type = :Float64
      div = AST::BinaryOp.new(token, sum_ident, :DIV, cnt_ident)
      div.full_type = :Float64
      div
    else
      res = AST::Identifier.new(token, res_var)
      res.full_type = smooth_node.full_type
      res.storage   = smooth_node.storage
      res
    end
  end

  def schema_lookup
    @schema_lookup ||= ->(name) { @annotator&.lookup_type_schema(name) }
  end

  # Check if the RHS callee returns an error union (even if the SMOOTH
  # node's full_type was already unwrapped by a CATCH block).
  def callee_returns_error?(rhs)
    ti = rhs.respond_to?(:type_info) ? rhs.type_info : nil
    return false unless ti
    raw = ti.raw
    return false unless raw.is_a?(Hash) && raw[:return].is_a?(Hash)
    ret_type = raw[:return][:type]
    ret_type&.error_union? || false
  end

  # Returns true if the source requires the transpiler's pipeline_generator
  # (pool, sharded, or SOA collections need special iteration patterns).
  def needs_transpiler_pipeline?(source)
    ti = source.respond_to?(:type_info) ? source.type_info : nil
    return false unless ti
    ti.pool? || ti.soa? || ti.sharded?
  end

  # Walk the left-spine of SMOOTH nodes and replace the deepest source.
  # Used when the rewriter skips a pipeline but has already rewritten the source.
  def patch_chain_source!(node, new_source)
    cursor = node
    while cursor.left.is_a?(AST::BinaryOp) && cursor.left.op == :SMOOTH
      cursor = cursor.left
    end
    cursor.left = new_source
  end

  def replace_named_placeholder(node, name, replacement)
    return node unless node
    if node.is_a?(AST::Identifier) && node.name == name
      return replacement.dup
    end
    new_node = node.dup
    node.class.members.each do |member|
      val = node[member]
      if val.is_a?(Array)
        new_node[member] = val.map { |i| replace_named_placeholder(i, name, replacement) }
      elsif val.is_a?(AST::Locatable)
        new_node[member] = replace_named_placeholder(val, name, replacement)
      end
    end
    new_node
  end

  def replace_placeholder(node, replacement)
    return node unless node
    if node.is_a?(AST::Placeholder) || (node.is_a?(AST::Identifier) && node.name == "_")
      return replacement.dup
    end
    new_node = node.dup
    node.class.members.each do |member|
      val = node[member]
      if val.is_a?(Array)
        new_node[member] = val.map { |i| replace_placeholder(i, replacement) }
      elsif val.is_a?(Hash)
        new_node[member] = val.transform_values { |v| replace_placeholder(v, replacement) }
      elsif val.is_a?(AST::Locatable)
        new_node[member] = replace_placeholder(val, replacement)
      end
    end
    new_node
  end
end
