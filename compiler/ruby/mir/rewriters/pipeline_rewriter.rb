# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/std_lib"

# Pipeline Rewriter — transforms high-level pipeline operators (|>) into 
# regular AST nodes (ForEach, IfStatement, BlockExpr) AFTER annotation.
#
# Running after annotation allows us to use type information for things like
# correctly typed accumulators and preserving error-unwrapping semantics.
#
# Since we run after annotation, we manually stamp newly created nodes with
# type and storage information so the transpiler can process them correctly.
class PipelineRewriter
    extend T::Sig

  PipelineStageList = T.type_alias { T::Array[AST::Node] }

  class PipelineChain < T::Struct
    const :source, AST::Node
    const :stages, PipelineStageList
    const :terminal, T.nilable(AST::Node)
  end

  # OrderByOp, IndexOp, WindowOp, JoinOp: require structural MIR/runtime
  # lowering that the MIR pipeline lowerers own.

  sig { params(annotator: T.nilable(SemanticAnnotator)).void }
  def initialize(annotator = nil)
    @annotator = T.let(annotator, T.nilable(SemanticAnnotator))
    @var_counter = T.let(0, Integer)
  end

  sig { params(node: AST::Node).returns(AST::Node) }
  def rewrite!(node)
    # Handle SMOOTH nodes BEFORE recursing into children.
    # This preserves pipeline chains (a |> WHERE |> SELECT |> SUM)
    # so collect_chain can discover and fuse them into a single loop.
    if node.is_a?(AST::BinaryOp) && node.smooth?
      return rewrite_pipeline(node)
    end

    rewrite_children!(node)
  end

  private

  sig { params(prefix: String).returns(String) }
  def next_var(prefix = "__v")
    @var_counter += 1
    "#{prefix}#{@var_counter}"
  end

  sig { params(node: AST::Node).returns(AST::Node) }
  def rewrite_children!(node)
    case node
    when AST::Program
      node.statements.map! { |s| rewrite!(s) }
    when AST::FunctionDef
      node.body.map! { |s| rewrite!(s) }
    when AST::VarDecl, AST::BindExpr, AST::Assignment, AST::DestructuringAssignment, AST::ReturnNode
      node.value = rewrite!(node.value) if node.value
    when AST::IfStatement
      node.condition = rewrite!(node.condition)
      node.then_branch&.map! { |s| rewrite!(s) }
      node.else_branch&.map! { |s| rewrite!(s) }
    when AST::MatchStatement
      node.expr = rewrite!(node.expr)
      node.cases.each { |c| c.body&.map! { |s| rewrite!(s) } }
      node.default_case.map! { |s| rewrite!(s) } if node.default_case
    when AST::WhileLoop
      node.condition = rewrite!(node.condition)
      node.do_branch&.map! { |s| rewrite!(s) } if node.do_branch.is_a?(Array)
    when AST::ForRange
      node.start_expr = rewrite!(node.start_expr)
      node.end_expr = rewrite!(node.end_expr)
      node.body.map! { |s| rewrite!(s) }
    when AST::ForEach
      node.collection = rewrite!(node.collection)
      node.body.map! { |s| rewrite!(s) }
    when AST::BinaryOp
      node.left = rewrite!(node.left)
      node.right = rewrite!(node.right)
    when AST::UnaryOp
      node.right = rewrite!(node.right)
    when AST::FuncCall, AST::MethodCall
      node.args.map! { |a| rewrite!(a) }
    when AST::StructLit
      node.fields.each { |k, v| node.fields[k] = rewrite!(v) }
    when AST::ListLit
      node.items.map! { |i| rewrite!(i) }
    when AST::BlockExpr
      node.body.map! { |s| rewrite!(s) }
      node.result = rewrite!(node.result) if node.result
    end

    node
  end

  sig { params(node: AST::BinaryOp).returns(AST::Node) }
  def rewrite_pipeline(node)
    source = node.left
    rhs = node.right

    # Collect the chain FIRST (before any recursive rewriting).
    chain = collect_chain(node)
    stages = chain.stages
    terminal = chain.terminal
    real_source = chain.source

    # Named binding chains (source AS $u |> UNNEST ...) must reach the MIR
    # lowering intact so lower_binding_chain can fuse them into nested loops
    # with correct $u -> loop_var substitution. PipelineRewriter has no concept
    # of named bindings and would emit $u as a raw identifier.
    return node if binding_source?(real_source)

    # Rewrite the source (it may contain nested pipelines in non-chain positions).
    # real_source is the non-SMOOTH root of the chain; safe to rewrite recursively.
    real_source = rewrite!(real_source)

    # Skip rewriting for pool, sharded, SOA sources, and when the source is
    # itself a pipeline (e.g. data |> SKIP 2 |> SUM _). These need special
    # iteration patterns owned by the MIR pipeline lowerers.
    if needs_transpiler_pipeline?(real_source) || (real_source.is_a?(AST::BinaryOp) && real_source.smooth?)
      # Only patch if the source actually changed; patching the same object
      # back into the chain creates a circular reference.
      patch_chain_source!(node, real_source) unless real_source.equal?(chain.source)
      return node
    end

    # Phase 2+: range source with EACH or fold terminal and only fusible
    # intermediate stages uses the lazy MIR path. Bypass PipelineRewriter
    # fusion so the BinaryOp chain reaches lower_smooth -> lower_each /
    # lower_range_fold intact; those methods unwrap the chain and emit a
    # single fused while loop.
    is_range_fold_terminal = terminal.is_a?(AST::EachOp) ||
                             AST.pipeline_terminal_fold?(terminal)
    # Infinite streams (~T[INF]) are included only when a LimitOp stage is present:
    # they require LIMIT to be finite.  Other stream types bypass unconditionally.
    source_type = real_source.full_type!
    has_limit = stages.any? { |s| s.is_a?(AST::LimitOp) }
    if is_range_fold_terminal && stages.all? { |s| AST.pipeline_fusible_stage?(s) }
      if real_source.is_a?(AST::RangeLit) || source_type.bounded_pipeline_stream_source?(has_limit)
        patch_chain_source!(node, real_source) unless real_source.equal?(chain.source)
        return node
      end
    end

    # DISTINCT always bypasses to pipeline_host lower_distinct: it handles
    # list and all stream sources via a Set-accumulating for/while loop.
    # The rewriter's fuse_pipeline path can't be used here because lower_var_decl
    # short-circuits on set_collection? and emits an empty set, discarding the
    # BlockExpr produced by fuse_pipeline.
    if terminal.is_a?(AST::DistinctOp) &&
       stages.all? { |s| AST.pipeline_fusible_stage?(s) }
      patch_chain_source!(node, real_source) unless real_source.equal?(chain.source)
      return node
    end

    # INDEX on a finite or LIMIT-bounded stream source bypasses: the MIR lowering
    # handles it as a lazy while loop (lower_stream_index via unwrap_range_chain).
    is_stream_index = terminal.is_a?(AST::IndexOp) &&
                      source_type.bounded_pipeline_stream_source?(has_limit) &&
                      stages.all? { |s| AST.pipeline_fusible_stage?(s) }
    if is_stream_index
      patch_chain_source!(node, real_source) unless real_source.equal?(chain.source)
      return node
    end

    # CASE 1: Fusion candidate (chained fusible stages or ending in a fold/EachOp)
    is_fold = terminal.nil? || terminal.is_a?(AST::EachOp) ||
              AST.pipeline_terminal_fold?(terminal) ||
              AST.pipeline_list_terminal?(terminal)

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
        AST.stamp_synthetic_type!(list_proxy, real_source.full_type!, context: "synthetic AST type")
        list_proxy.storage   = real_source.storage
        fused_loop = fuse_pipeline(list_proxy, real_source, stages, nil)

        # Create a new SMOOTH node for the terminal call
        outer_smooth = AST::BinaryOp.new(node.token, fused_loop, :SMOOTH, terminal.dup)
        AST.stamp_synthetic_type!(outer_smooth, node.full_type!, context: "synthetic AST type")
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
    result_is_error = Type.new(node.full_type!).error_union?
    result_is_error ||= callee_returns_error?(rhs)
    needs_try = Type.new(source.full_type!).error_union?

    if rhs.is_a?(AST::FuncCall) && !result_is_error
      lhs_node = needs_try ? AST::UnaryOp.new(rhs.token, :TRY, source.dup) : source.dup
      if needs_try
        AST.stamp_synthetic_type!(lhs_node, T.must(Type.new(source.full_type!).payload_type), context: "synthetic AST type")
      end

      rhs.args.unshift(lhs_node)
      return rhs
    end

    if rhs.is_a?(AST::Identifier) && !result_is_error
      lhs_node = needs_try ? AST::UnaryOp.new(rhs.token, :TRY, source.dup) : source.dup
      if needs_try
        AST.stamp_synthetic_type!(lhs_node, T.must(Type.new(source.full_type!).payload_type), context: "synthetic AST type")
      end

      call = AST::FuncCall.new(rhs.token, rhs.name, [lhs_node])
      AST.stamp_synthetic_type!(call, node.full_type!, context: "synthetic AST type")
      call.storage   = node.storage
      config = IntrinsicRegistry.lookup(STD_LIB, T.unsafe(rhs).name)
      sig0 = T.let(config.is_a?(Array) ? config.first : FunctionSignature.unwrap(config), T.nilable(FunctionSignature))
      if sig0
        call.zig_pattern = sig0.intrinsic_pattern
      end
      return call
    end

    # CASE 4: x |> RECOVER(default) -> x OR_ELSE default
    if rhs.is_a?(AST::RecoverOp)
      op = AST::BinaryOp.new(rhs.token, source.dup, :OR_ELSE, rhs.default_expr.dup)
      AST.stamp_synthetic_type!(op, node.full_type!, context: "synthetic AST type")
      op.storage   = node.storage
      return op
    end

    node
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def is_fusible?(node)
    AST.pipeline_fusible_stage?(node)
  end

  # Returns true if the node is, or contains, a BIND_VAR-sourced pipeline.
  # These are handled by MIR lowering (lower_binding_chain) which performs
  # correct $u -> loop_var substitution. PipelineRewriter must leave them alone.
  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def binding_source?(node)
    return true if node.is_a?(AST::BinaryOp) && node.op == :BIND_VAR
    return false unless node.is_a?(AST::BinaryOp) && node.smooth?
    # Walk the source chain to find if its root is a BIND_VAR.
    inner_src = collect_chain(node).source
    inner_src.is_a?(AST::BinaryOp) && inner_src.op == :BIND_VAR
  end

  sig { params(node: AST::BinaryOp).returns(PipelineChain) }
  def collect_chain(node)
    stages = T.let([], PipelineStageList)
    cursor = T.let(node, AST::BinaryOp)
    terminal = T.let(nil, T.nilable(AST::Node))

    # Identify the terminal operation.
    right = node.right
    if is_fusible?(right)
      terminal = nil # implicit list terminal
      cursor = node
    else
      # Explicit pipeline terminal or standard function terminal.
      terminal = right
      cursor = node.left
    end

    # Now walk back through fusible stages
    while cursor.is_a?(AST::BinaryOp) && cursor.smooth?
      r = cursor.right
      if is_fusible?(r)
        stages.unshift(r)
        cursor = cursor.left
      else
        break
      end
    end

    PipelineChain.new(source: cursor, stages: stages, terminal: terminal)
  end

  sig { params(smooth_node: AST::BinaryOp, source: AST::Node, stages: PipelineStageList, terminal: T.nilable(AST::Node)).returns(AST::Node) }
  def fuse_pipeline(smooth_node, source, stages, terminal)
    # Generate unique variable names for this pipeline
    res_var = next_var("__res")
    it_var = next_var("__it")
    token = smooth_node.token

    body = []
    
    # 1. Initialize result container or accumulator(s)
    # Inner Literal/BinaryOp/UnaryOp self-derive their type from
    # structure (AST::*#full_type); statements derive Void. No stamping.
    init_nodes = build_init(terminal, res_var, token, smooth_node)
    body.concat(init_nodes)

    # 2. Build loop body
    current_it = AST::Identifier.new(token, it_var)
    src_t = Type.new(source.full_type!(context: "fused pipeline source"))
    elem_t = if src_t.open_stream?
      src_t.open_stream_element_type
    elsif src_t.dynamic_stream? || src_t.bounded_stream?
      src_t.tense_type.element_type
    elsif src_t.inf_stream?
      src_t.inf_stream_element_type
    else
      src_t.element_type
    end
    AST.stamp_synthetic_type!(current_it, elem_t, context: "synthetic AST type") if elem_t

    stage_inits = []
    res_type = smooth_node.full_type!
    # Loop-body nodes self-derive their type from structure
    # (Literal/BinaryOp/UnaryOp via AST::*#full_type; statements Void).
    loop_body = build_recursive_body(stages, terminal, current_it, res_var, token, stage_inits, res_type)
    body.concat(stage_inits)

    # 3. Create ForEach loop
    is_each = terminal.is_a?(AST::EachOp)
    foreach = AST::ForEach.new(token, it_var, source.dup, loop_body, nil, is_each)
    AST.stamp_synthetic_type!(foreach, Type.new(:Void), context: "synthetic AST type")
    foreach.var_used = true
    body << foreach

    # 4. Post-loop guards
    if terminal.is_a?(AST::MinOp) || terminal.is_a?(AST::MaxOp)
      found_ident = AST::Identifier.new(token, "#{res_var}_found")
      AST.stamp_synthetic_type!(found_ident, Type.new(:Bool), context: "synthetic AST type")
      guard = AST::Assert.new(token, found_ident, "MIN/MAX applied to empty list")
      AST.stamp_synthetic_type!(guard, Type.new(:Void), context: "synthetic AST type")
      body << guard
    end

    # 5. Result
    if terminal.is_a?(AST::EachOp)
      # EACH is void — no result, no BlockExpr wrapper needed.
      # Return the ForEach directly (or wrap in a sequence if there are init nodes).
      return foreach if body.length == 1
      wrapper = AST::BlockExpr.new(token, body, nil)
      AST.stamp_synthetic_type!(wrapper, Type.new(:Void), context: "synthetic AST type")
      return wrapper
    end

    # For AVERAGE, guard against division by zero (empty list -> 0.0).
    # Emit: MUTABLE __resN = 0.0; if cnt > 0 { __resN = sum / cnt; }
    if terminal.is_a?(AST::AverageOp)
      avg_var = "#{res_var}_avg"
      zero = AST::Literal.new(token, :NUMBER, 0.0)
      AST.stamp_synthetic_type!(zero, Type.new(:Float64), context: "synthetic AST type")
      avg_decl = AST::VarDecl.new(token, avg_var, nil, zero.dup, true)
      AST.stamp_synthetic_type!(avg_decl, Type.new(:Float64), context: "synthetic AST type")
      avg_decl.storage   = :stack
      avg_decl.slot_size = 1
      avg_decl.var_used = true
      avg_decl.var_mutated = true
      body << avg_decl

      sum_id = AST::Identifier.new(token, "#{res_var}_sum")
      cnt_id = AST::Identifier.new(token, "#{res_var}_cnt")
      AST.stamp_synthetic_type!(sum_id, Type.new(:Float64), context: "synthetic AST type")
      AST.stamp_synthetic_type!(cnt_id, Type.new(:Float64), context: "synthetic AST type")
      cond = AST::BinaryOp.new(token, cnt_id.dup, :GT, zero.dup)
      AST.stamp_synthetic_type!(cond, Type.new(:Bool), context: "synthetic AST type")
      div = AST::BinaryOp.new(token, sum_id, :DIV, cnt_id)
      AST.stamp_synthetic_type!(div, Type.new(:Float64), context: "synthetic AST type")
      avg_assign = AST::Assignment.new(token, avg_var, div)
      AST.stamp_synthetic_type!(avg_assign, Type.new(:Float64), context: "synthetic AST type")
      guard = AST::IfStatement.new(token, cond, [avg_assign], [])
      AST.stamp_synthetic_type!(guard, Type.new(:Void), context: "synthetic AST type")
      body << guard

      result = AST::Identifier.new(token, avg_var)
      AST.stamp_synthetic_type!(result, Type.new(:Float64), context: "synthetic AST type")
    else
      result = build_final_result(terminal, res_var, token, smooth_node)
    end

    block = AST::BlockExpr.new(token, body, result)
    AST.stamp_synthetic_type!(block, smooth_node.full_type!, context: "synthetic AST type")
    block.storage   = smooth_node.storage
    block
  end

  sig { params(terminal: T.nilable(AST::Node), res_var: String, token: Lexer::Token, smooth_node: AST::BinaryOp).returns(AST::RawBody) }
  def build_init(terminal, res_var, token, smooth_node)
    case terminal
    when AST::SumOp, AST::CountOp
      is_int = Type.new(smooth_node.full_type!).integer?
      val = AST::Literal.new(token, is_int ? :INT64 : :NUMBER, is_int ? 0 : 0.0)
      AST.stamp_synthetic_type!(val, smooth_node.full_type!, context: "synthetic AST type")
      decl = AST::VarDecl.new(token, res_var, nil, val, true)
      AST.stamp_synthetic_type!(decl, smooth_node.full_type!, context: "synthetic AST type")
      decl.storage   = :stack
      decl.slot_size = 1
      decl.var_used = true
      decl.var_mutated = true
      [decl]
    when AST::AverageOp
      # Two accumulators: sum and count
      sum_decl = AST::VarDecl.new(token, "#{res_var}_sum", nil, AST::Literal.new(token, :NUMBER, 0.0), true)
      AST.stamp_synthetic_type!(sum_decl, Type.new(:Float64), context: "synthetic AST type")
      sum_decl.storage   = :stack
      sum_decl.slot_size = 1
      sum_decl.var_used = true
      sum_decl.var_mutated = true

      cnt_decl = AST::VarDecl.new(token, "#{res_var}_cnt", nil, AST::Literal.new(token, :NUMBER, 0.0), true)
      AST.stamp_synthetic_type!(cnt_decl, Type.new(:Float64), context: "synthetic AST type")
      cnt_decl.storage   = :stack
      cnt_decl.slot_size = 1
      cnt_decl.var_used = true
      cnt_decl.var_mutated = true

      [sum_decl, cnt_decl]
    when AST::AnyOp, AST::AllOp
      init_val = terminal.is_a?(AST::AllOp)
      val = AST::Literal.new(token, :BOOLEAN, init_val)
      AST.stamp_synthetic_type!(val, Type.new(:Bool), context: "synthetic AST type")
      decl = AST::VarDecl.new(token, res_var, nil, val, true)
      AST.stamp_synthetic_type!(decl, Type.new(:Bool), context: "synthetic AST type")
      decl.storage   = :stack
      decl.slot_size = 1
      decl.var_used = true
      decl.var_mutated = true
      [decl]
    when AST::ReduceOp
      decl = AST::VarDecl.new(token, res_var, nil, terminal.initial_value.dup, true)
      AST.stamp_synthetic_type!(decl, terminal.full_type!, context: "synthetic AST type")
      decl.storage   = :stack
      decl.slot_size = Type.new(decl.full_type!).slot_size(schema_lookup)
      decl.var_used = true
      decl.var_mutated = true
      [decl]
    when AST::FindOp
      val = AST::Literal.new(token, :NIL, nil)
      AST.stamp_synthetic_type!(val, Type.new(:NIL), context: "synthetic AST type")
      decl = AST::VarDecl.new(token, res_var, nil, val, true)
      AST.stamp_synthetic_type!(decl, smooth_node.full_type!, context: "synthetic AST type")
      decl.storage   = :stack
      decl.slot_size = Type.new(decl.full_type!).slot_size(schema_lookup)
      decl.var_used = true
      decl.var_mutated = true
      [decl]
    when AST::MinOp, AST::MaxOp
      # Found-flag pattern: first element always sets result, subsequent compare
      zero = AST::Literal.new(token, :NUMBER, 0.0)
      AST.stamp_synthetic_type!(zero, Type.new(:Float64), context: "synthetic AST type")
      val_decl = AST::VarDecl.new(token, res_var, nil, zero, true)
      AST.stamp_synthetic_type!(val_decl, Type.new(:Float64), context: "synthetic AST type")
      val_decl.storage   = :stack
      val_decl.slot_size = 1
      val_decl.var_used = true
      val_decl.var_mutated = true

      found_init = AST::Literal.new(token, :BOOLEAN, false)
      AST.stamp_synthetic_type!(found_init, Type.new(:Bool), context: "synthetic AST type")
      found_decl = AST::VarDecl.new(token, "#{res_var}_found", nil, found_init, true)
      AST.stamp_synthetic_type!(found_decl, Type.new(:Bool), context: "synthetic AST type")
      found_decl.storage   = :stack
      found_decl.slot_size = 1
      found_decl.var_used = true
      found_decl.var_mutated = true

      [val_decl, found_decl]
    when nil, AST::SelectOp, AST::WhereOp, AST::TapOp, AST::TakeWhileOp,
         AST::UnnestOp, AST::DistinctOp
      lit = AST::ListLit.new(token, [], :stack)
      AST.stamp_synthetic_type!(lit, smooth_node.full_type!, context: "synthetic AST type")
      decl = AST::VarDecl.new(token, res_var, nil, lit, true)
      AST.stamp_synthetic_type!(decl, smooth_node.full_type!, context: "synthetic AST type")
      decl.storage   = smooth_node.storage
      decl.slot_size = Type.new(decl.full_type!).slot_size(schema_lookup)
      decl.var_used = true
      [decl]
    else
      []
    end
  end

  sig { params(stages: PipelineStageList, terminal: T.nilable(AST::Node), current_val: AST::Identifier, res_var: String, token: Lexer::Token, stage_inits: AST::RawBody, res_type: T.nilable(Type)).returns(AST::RawBody) }
  def build_recursive_body(stages, terminal, current_val, res_var, token, stage_inits = [], res_type = nil)
    if stages.empty?
      return build_terminal_action(terminal, current_val, res_var, token, res_type)
    end

    stage = stages.first
    remaining = stages[1..-1]

    case stage
    when AST::WhereOp
      pred = replace_placeholder(stage.expression, current_val)
      then_branch = build_recursive_body(T.must(remaining), terminal, current_val, res_var, token, stage_inits, res_type)
      if_stmt = AST::IfStatement.new(stage.token, pred, then_branch, [])
      AST.stamp_synthetic_type!(if_stmt, Type.new(:Void), context: "synthetic AST type")
      [if_stmt]
    when AST::SelectOp
      expr = replace_placeholder(stage.expression, current_val)
      # Bind SELECT result to a temp so it is never inlined into an expression
      # position. Zig forbids StructType{...}.field in arithmetic/boolean contexts.
      sel_var = next_var("__sel")
      sel_decl = AST::VarDecl.new(stage.token, sel_var, nil, expr, false)
      AST.stamp_synthetic_type!(sel_decl, stage.expression.full_type!, context: "synthetic AST type")
      sel_decl.storage   = :stack
      sel_decl.slot_size = 0
      sel_decl.var_used = true
      sel_ident = AST::Identifier.new(stage.token, sel_var)
      AST.stamp_synthetic_type!(sel_ident, stage.expression.full_type!, context: "synthetic AST type")
      rest = build_recursive_body(T.must(remaining), terminal, sel_ident, res_var, token, stage_inits, res_type)
      [sel_decl] + rest
    when AST::TapOp
      tap_body = stage.body.map { |s| replace_placeholder(s, current_val) }
      tap_body + build_recursive_body(T.must(remaining), terminal, current_val, res_var, token, stage_inits, res_type)
    when AST::TakeWhileOp
      pred = replace_placeholder(stage.expression, current_val)
      then_branch = build_recursive_body(T.must(remaining), terminal, current_val, res_var, token, stage_inits, res_type)
      if_stmt = AST::IfStatement.new(stage.token, pred, then_branch, [AST::BreakNode.new(stage.token)])
      AST.stamp_synthetic_type!(if_stmt, Type.new(:Void), context: "synthetic AST type")
      [if_stmt]
    when AST::SkipOp
      cnt_var = next_var("__skip_cnt")
      zero = AST::Literal.new(token, :INT64, 0)
      AST.stamp_synthetic_type!(zero, Type.new(:Int64), context: "synthetic AST type")
      cnt_decl = AST::VarDecl.new(token, cnt_var, nil, zero, true)
      AST.stamp_synthetic_type!(cnt_decl, Type.new(:Int64), context: "synthetic AST type")
      cnt_decl.storage = :stack
      cnt_decl.slot_size = 1
      cnt_decl.var_used = true
      cnt_decl.var_mutated = true
      stage_inits << cnt_decl

      cnt_ident = AST::Identifier.new(token, cnt_var)
      AST.stamp_synthetic_type!(cnt_ident, Type.new(:Int64), context: "synthetic AST type")
      one = AST::Literal.new(token, :INT64, 1)
      AST.stamp_synthetic_type!(one, Type.new(:Int64), context: "synthetic AST type")
      increment = AST::Assignment.new(token, cnt_ident, AST::BinaryOp.new(token, cnt_ident.dup, :ADD, one))
      AST.stamp_synthetic_type!(increment, Type.new(:Void), context: "synthetic AST type")

      skip_n = stage.count.dup
      cond = AST::BinaryOp.new(token, cnt_ident.dup, :LTE, skip_n)
      AST.stamp_synthetic_type!(cond, Type.new(:Bool), context: "synthetic AST type")
      skip_if = AST::IfStatement.new(token, cond, [AST::ContinueNode.new(token)], [])
      AST.stamp_synthetic_type!(skip_if, Type.new(:Void), context: "synthetic AST type")

      rest = build_recursive_body(T.must(remaining), terminal, current_val, res_var, token, stage_inits, res_type)
      [increment, skip_if] + rest
    when AST::LimitOp
      cnt_var = next_var("__lim_cnt")
      zero = AST::Literal.new(token, :INT64, 0)
      AST.stamp_synthetic_type!(zero, Type.new(:Int64), context: "synthetic AST type")
      cnt_decl = AST::VarDecl.new(token, cnt_var, nil, zero, true)
      AST.stamp_synthetic_type!(cnt_decl, Type.new(:Int64), context: "synthetic AST type")
      cnt_decl.storage = :stack
      cnt_decl.slot_size = 1
      cnt_decl.var_used = true
      cnt_decl.var_mutated = true
      stage_inits << cnt_decl

      cnt_ident = AST::Identifier.new(token, cnt_var)
      AST.stamp_synthetic_type!(cnt_ident, Type.new(:Int64), context: "synthetic AST type")
      one = AST::Literal.new(token, :INT64, 1)
      AST.stamp_synthetic_type!(one, Type.new(:Int64), context: "synthetic AST type")
      increment = AST::Assignment.new(token, cnt_ident, AST::BinaryOp.new(token, cnt_ident.dup, :ADD, one))
      AST.stamp_synthetic_type!(increment, Type.new(:Void), context: "synthetic AST type")

      limit_n = stage.count.dup
      cond = AST::BinaryOp.new(token, cnt_ident.dup, :GT, limit_n)
      AST.stamp_synthetic_type!(cond, Type.new(:Bool), context: "synthetic AST type")
      limit_if = AST::IfStatement.new(token, cond, [AST::BreakNode.new(token)], [])
      AST.stamp_synthetic_type!(limit_if, Type.new(:Void), context: "synthetic AST type")

      rest = build_recursive_body(T.must(remaining), terminal, current_val, res_var, token, stage_inits, res_type)
      [increment, limit_if] + rest
    else
      build_recursive_body(T.must(remaining), terminal, current_val, res_var, token, stage_inits, res_type)
    end
  end

  sig { params(terminal: T.nilable(AST::Node), current_val: AST::Identifier, res_var: String, token: Lexer::Token, res_type: T.nilable(Type)).returns(AST::RawBody) }
  def build_terminal_action(terminal, current_val, res_var, token, res_type = nil)
    res_ident = AST::Identifier.new(token, res_var)
    AST.stamp_synthetic_type!(res_ident, res_type, context: "synthetic AST type") if res_type
    actions = case terminal
    when AST::SumOp
      expr = replace_placeholder(terminal.expression, current_val)
      assign = AST::Assignment.new(token, res_ident, AST::BinaryOp.new(token, res_ident, :ADD, expr))
      AST.stamp_synthetic_type!(assign, Type.new(:Void), context: "synthetic AST type")
      [assign]
    when AST::CountOp
      expr = replace_placeholder(terminal.expression, current_val)
      one = AST::Literal.new(token, :INT64, 1)
      increment = AST::Assignment.new(token, res_ident, AST::BinaryOp.new(token, res_ident, :ADD, one))
      AST.stamp_synthetic_type!(increment, Type.new(:Void), context: "synthetic AST type")
      if_stmt = AST::IfStatement.new(token, expr, [increment], [])
      AST.stamp_synthetic_type!(if_stmt, Type.new(:Void), context: "synthetic AST type")
      [if_stmt]
    when AST::AverageOp
      expr = replace_placeholder(terminal.expression, current_val)
      sum_ident = AST::Identifier.new(token, "#{res_var}_sum")
      cnt_ident = AST::Identifier.new(token, "#{res_var}_cnt")
      # AVERAGE's sum/cnt accumulators are Float64 by the desugar's own
      # definition (same as build_init / build_final_result type them).
      AST.stamp_synthetic_type!(sum_ident, Type.new(:Float64), context: "synthetic AST type")
      AST.stamp_synthetic_type!(cnt_ident, Type.new(:Float64), context: "synthetic AST type")
      [AST::Assignment.new(token, sum_ident, AST::BinaryOp.new(token, sum_ident, :ADD, expr)),
       AST::Assignment.new(token, cnt_ident, AST::BinaryOp.new(token, cnt_ident, :ADD, AST::Literal.new(token, :NUMBER, 1.0)))]
    when AST::AnyOp
      expr = replace_placeholder(terminal.expression, current_val)
      set_true = AST::Assignment.new(token, res_ident, AST::Literal.new(token, :BOOLEAN, true))
      AST.stamp_synthetic_type!(set_true, Type.new(:Void), context: "synthetic AST type")
      if_stmt = AST::IfStatement.new(token, expr, [set_true, AST::BreakNode.new(token)], [])
      AST.stamp_synthetic_type!(if_stmt, Type.new(:Void), context: "synthetic AST type")
      [if_stmt]
    when AST::AllOp
      expr = replace_placeholder(terminal.expression, current_val)
      set_false = AST::Assignment.new(token, res_ident, AST::Literal.new(token, :BOOLEAN, false))
      AST.stamp_synthetic_type!(set_false, Type.new(:Void), context: "synthetic AST type")
      if_stmt = AST::IfStatement.new(token, AST::UnaryOp.new(token, :NOT, expr), [set_false, AST::BreakNode.new(token)], [])
      AST.stamp_synthetic_type!(if_stmt, Type.new(:Void), context: "synthetic AST type")
      [if_stmt]
    when AST::ReduceOp
      expr = replace_placeholder(terminal.expression, current_val)
      expr = replace_named_placeholder(expr, "acc", res_ident)
      assign = AST::Assignment.new(token, res_ident, expr)
      AST.stamp_synthetic_type!(assign, Type.new(:Void), context: "synthetic AST type")
      [assign]
    when AST::FindOp
      expr = replace_placeholder(terminal.expression, current_val)
      assign = AST::Assignment.new(token, res_ident, current_val.dup)
      AST.stamp_synthetic_type!(assign, Type.new(:Void), context: "synthetic AST type")
      if_stmt = AST::IfStatement.new(token, expr, [assign, AST::BreakNode.new(token)], [])
      AST.stamp_synthetic_type!(if_stmt, Type.new(:Void), context: "synthetic AST type")
      [if_stmt]
    when AST::MinOp, AST::MaxOp
      expr = replace_placeholder(terminal.expression, current_val)
      op = terminal.is_a?(AST::MinOp) ? :LT : :GT
      found_ident = AST::Identifier.new(token, "#{res_var}_found")
      AST.stamp_synthetic_type!(found_ident, Type.new(:Bool), context: "synthetic AST type")

      # if !found || expr < res { res = expr; found = true }
      not_found = AST::UnaryOp.new(token, :NOT, found_ident.dup)
      AST.stamp_synthetic_type!(not_found, Type.new(:Bool), context: "synthetic AST type")
      cmp = AST::BinaryOp.new(token, expr, op, res_ident.dup)
      AST.stamp_synthetic_type!(cmp, Type.new(:Bool), context: "synthetic AST type")
      cond = AST::BinaryOp.new(token, not_found, :OR, cmp)
      AST.stamp_synthetic_type!(cond, Type.new(:Bool), context: "synthetic AST type")

      assign_val = AST::Assignment.new(token, res_ident, expr.dup)
      AST.stamp_synthetic_type!(assign_val, Type.new(:Void), context: "synthetic AST type")
      set_found = AST::Assignment.new(token, found_ident, AST::Literal.new(token, :BOOLEAN, true))
      AST.stamp_synthetic_type!(set_found, Type.new(:Void), context: "synthetic AST type")

      if_stmt = AST::IfStatement.new(token, cond, [assign_val, set_found], [])
      AST.stamp_synthetic_type!(if_stmt, Type.new(:Void), context: "synthetic AST type")
      [if_stmt]
    when AST::EachOp
      terminal.body.map { |s| replace_placeholder(s, current_val) }
    when AST::UnnestOp
      # Nested loop: for each item, iterate over the inner list and append each element
      inner_expr = replace_placeholder(terminal.expression, current_val)
      inner_it_var = next_var("__it")

      inner_it = AST::Identifier.new(token, inner_it_var)
      # inner_it iterates inner_expr's elements — its type IS that
      # element type (not a guess; derived from the flattened array).
      et = Type.new(inner_expr.full_type!(context: "pipeline unnest inner expression")).element_type
      AST.stamp_synthetic_type!(inner_it, et, context: "synthetic AST type") if et

      append = synthetic_append_call(token, res_ident, inner_it.dup)

      # Iterate directly over the expression (avoids ArrayList/slice confusion).
      # Mark collection as a slice so the transpiler uses &expr, not .items.
      inner_foreach = AST::ForEach.new(token, inner_it_var, inner_expr, [append], nil, false)
      AST.stamp_synthetic_type!(inner_foreach, Type.new(:Void), context: "synthetic AST type")
      inner_foreach.var_used = true

      [inner_foreach]
    when AST::DistinctOp
      # Set insert: result is a T[]@set; insert deduplicates in O(1).
      key_expr = replace_placeholder(terminal.expression, current_val)
      insert_call = synthetic_set_insert_call(token, res_ident.dup, key_expr)
      [insert_call]
    else
      # Produces a list.
      value = AST::CopyNode.new(token, current_val.dup)
      AST.stamp_synthetic_type!(value, current_val.full_type!, context: "synthetic AST type")
      call = synthetic_append_call(token, res_ident, value)
      [call]
    end
    actions
  end

  sig { params(token: Lexer::Token, receiver: AST::Node, value: AST::Node).returns(AST::MethodCall) }
  def synthetic_append_call(token, receiver, value)
    defn = T.must(FunctionSignature.unwrap(IntrinsicRegistry.lookup(STD_LIB, "append")))
    call = AST::MethodCall.new(token, receiver, "append", [value])
    AST.stamp_synthetic_type!(call, Type.new(:Void), context: "synthetic AST type")
    call.zig_pattern = defn.intrinsic_pattern
    call.matched_stdlib_def = defn
    call
  end

  sig { params(token: Lexer::Token, receiver: AST::Node, value: AST::Node).returns(AST::MethodCall) }
  def synthetic_set_insert_call(token, receiver, value)
    defn = T.must(FunctionSignature.unwrap(IntrinsicRegistry.lookup(SET_METHODS, "insert")))
    call = AST::MethodCall.new(token, receiver, "insert", [value])
    AST.stamp_synthetic_type!(call, Type.new(:Void), context: "synthetic AST type")
    call.zig_pattern = defn.intrinsic_pattern
    call.matched_stdlib_def = defn
    call
  end

  sig { params(terminal: T.nilable(AST::Node), res_var: String, token: Lexer::Token, smooth_node: AST::BinaryOp).returns(AST::Identifier) }
  def build_final_result(terminal, res_var, token, smooth_node)
    res = AST::Identifier.new(token, res_var)
    AST.stamp_synthetic_type!(res, smooth_node.full_type!, context: "synthetic AST type")
    res.storage = smooth_node.storage
    res
  end

  sig { returns(Proc) }
  def schema_lookup
    @schema_lookup = T.let(@schema_lookup, T.nilable(Proc))
    @schema_lookup ||= ->(name) { @annotator&.lookup_type_schema(name) }
  end

  # Check if the RHS callee returns an error union (even if the SMOOTH
  # node's full_type was already unwrapped by a CATCH block).
  sig { params(rhs: AST::Locatable).returns(T::Boolean) }
  def callee_returns_error?(rhs)
    ti = rhs.full_type!(context: "pipeline callee")
    # Annotated function identifiers are represented by Type::FunctionType;
    # older producers exposed a bare FunctionSignature. Handle the canonical
    # representation first so fallible pipelines stay in MIR lowering, where
    # CATCH snapshot capture is inserted before the call.
    function_type = ti.function_type
    return function_type.return_type.error_union? if function_type

    signature = FunctionSignature.unwrap(ti)
    signature&.return_type&.error_union? || false
  end

  # Returns true if the source requires MIR pipeline lowering (pool, sharded,
  # or SOA collections need special iteration patterns).
  sig { params(source: AST::Locatable).returns(T::Boolean) }
  def needs_transpiler_pipeline?(source)
    ti = source.full_type!(context: "pipeline source")
    ti.pool? || ti.soa? || ti.sharded?
  end

  # Walk the left-spine of SMOOTH nodes and replace the deepest source.
  # Used when the rewriter skips a pipeline but has already rewritten the source.
  sig { params(node: AST::BinaryOp, new_source: AST::Node).returns(AST::Node) }
  def patch_chain_source!(node, new_source)
    cursor = T.let(node, AST::BinaryOp)
    while cursor.left.is_a?(AST::BinaryOp) && cursor.left.smooth?
      cursor = T.cast(cursor.left, AST::BinaryOp)
    end
    cursor.left = new_source
  end

  sig { params(node: AST::Node, name: String, replacement: AST::Identifier).returns(AST::Node) }
  def replace_named_placeholder(node, name, replacement)
    if node.is_a?(AST::Identifier) && node.name == name
      return replacement.dup
    end
    new_node = node.dup
    node.class.members.each do |member|
      val = T.unsafe(node)[member]
      if val.is_a?(Array)
        T.unsafe(new_node)[member] = val.map { |i| i.is_a?(AST::Locatable) ? replace_named_placeholder(i, name, replacement) : i }
      elsif val.is_a?(AST::Locatable)
        T.unsafe(new_node)[member] = replace_named_placeholder(val, name, replacement)
      end
    end
    new_node
  end

  sig { params(node: AST::Node, replacement: AST::Identifier).returns(AST::Node) }
  def replace_placeholder(node, replacement)
    if node.is_a?(AST::Placeholder) || (node.is_a?(AST::Identifier) && node.name == "_")
      return replacement.dup
    end
    new_node = node.dup
    node.class.members.each do |member|
      val = T.unsafe(node)[member]
      if val.is_a?(Array)
        T.unsafe(new_node)[member] = val.map { |i| i.is_a?(AST::Locatable) ? replace_placeholder(i, replacement) : i }
      elsif val.is_a?(Hash)
        T.unsafe(new_node)[member] = val.transform_values { |v| v.is_a?(AST::Locatable) ? replace_placeholder(v, replacement) : v }
      elsif val.is_a?(AST::Locatable)
        T.unsafe(new_node)[member] = replace_placeholder(val, replacement)
      end
    end
    new_node
  end
end
