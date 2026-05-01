# src/mir_pass.rb - MIR transformation pass
#
# Runs after annotation. Classifies cleanup bindings, stamps fn.cleanup_bindings,
# inserts MIR promotion/suppress nodes, and propagates heap provenance.
#
# Dependencies are defined in control_flow.rb (required first) and promotion_plan.rb.

require_relative "promotion_plan"
require_relative "escape_analysis"

class MIRPass
  # cleanup_bindings: { fn_name => { var_name => entry_hash } }
  # Exposed for specs that test classification directly.
  attr_reader :cleanup_bindings

  def initialize(fn_nodes:, schema_lookup:)
    @fn_nodes = fn_nodes
    @schema_lookup = schema_lookup
    @cleanup_bindings = {}
  end

  # Computes plans, classifies bindings, inserts MIR nodes, and stamps AST.
  # Phase 0 hoists heap-promoted temporaries (HPTs) into VarDecl nodes so that
  # existing classify_binding + cleanup_bindings infrastructure handles their cleanup.
  # PromotionClassifier must run before cleanup classification because its Phase 0
  # (scan_for_hpt_downgrade) clears heap provenance on return sub-expressions
  # that the classifier depends on.
  def transform!(ast)
    # E1: compute which functions return heap-owned values (fixed-point over call graph).
    heap_fns = EscapeAnalysis.compute_heap_return_fns!(@fn_nodes)

    # E3a: propagate heap return_provenance to caller binding type_info.
    # Must run before PromotionClassifier so HPT downgrade sees stable provenance.
    EscapeAnalysis.tag_transitive_provenance!(@fn_nodes, heap_fns)

    # E3c: propagate caller arg sync into callee param SymbolEntry#sync.
    # Runs after annotation has stamped local bindings; before classification
    # passes that read sync (CleanupClassifier, mir_lowering).
    EscapeAnalysis.propagate_caller_sync!(@fn_nodes)

    # Phase 1: classify promotions for all functions.
    # Must run before E2 so promotion_plans are available for :always_returned detection.
    promotion_plans = {}
    @fn_nodes.each do |name, fn|
      promotion_plans[name] = PromotionClassifier.classify(fn, schema_lookup: @schema_lookup)
    end

    # E2: per-declaration escape scan.
    # Applies all 6 escape conditions; replaces the upgrade_* methods below.
    # Sets fn.heap_carry_return for E3b (tag_carry_call_sites!).
    @bg_heap_upgraded = EscapeAnalysis.analyze!(
      @fn_nodes, heap_fns: heap_fns, promotion_plans: promotion_plans
    )

    # E3b: stamp heap provenance on call-site expressions for carry-return functions.
    # Runs after E2 because E2 sets fn.heap_carry_return on loop-carry functions.
    EscapeAnalysis.tag_carry_call_sites!(@fn_nodes)

    # Phase 2: set mark_per_iter on all loops so CleanupClassifier sees stable
    # provenance before classification.
    LoopFrameAnalysis.analyze!(@fn_nodes)

    # Phase 2.5: classify cleanup bindings (uses finalized provenance from Phase 2).
    @fn_nodes.each do |name, fn|
      @cleanup_bindings[name] = CleanupClassifier.classify(fn, fn_nodes: @fn_nodes, schema_lookup: @schema_lookup)
    end

    # Phase 3: insert MIR nodes + stamp AST.
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      transform_function!(stmt, promotion_plans[stmt.name])
    end

  end

  private

  def transform_function!(fn, promo)
    bindings = @cleanup_bindings[fn.name]
    has_bindings = bindings && !bindings.empty?
    promo = nil if promo&.empty?

    fn.has_promotion = true if promo

    has_bg_escapes = body_has_bg_escape_promotes?(fn.body)
    has_catch = fn.catch_clauses.is_a?(Array) && fn.catch_clauses.any?

    # BG scope-exit annotation runs unconditionally: the function may have no
    # bindings/promotions but still contain BG blocks returning frame values.
    annotate_bg_exits_in_body!(fn.body)

    return unless has_bindings || promo || has_bg_escapes || has_catch

    # Borrow checking: verify no moves of borrowed variables inside WITH blocks.
    bc_errors = BorrowChecker.check(fn, schema_lookup: @schema_lookup)
    unless bc_errors.empty?
      raise "[Borrow Error] #{bc_errors.first}"
    end

    # Pre-mark bindings captured by BG blocks so has_moved_guard is correct
    # BEFORE cleanup_decisions! runs and Drops snapshot cleanup_entry.
    pre_mark_bg_resource_captures!(fn, bindings) if has_bindings

    # Ownership dataflow refines cleanup decisions: determines WHETHER cleanup
    # is needed and WHETHER a moved guard is required, based on per-path analysis.
    # Also runs UseAfterMoveChecker (Rule 1: no use after move).
    @last_dataflow = nil
    if has_bindings
      can_fail_fns = Set.new
      @fn_nodes.each { |name, f| can_fail_fns << name if f.can_fail }
      @last_dataflow = OwnershipDataflow.analyze(fn, can_fail_fns: can_fail_fns, schema_lookup: @schema_lookup)
      @last_dataflow.cleanup_decisions!(fn, bindings)
    end

    # Patch heap carry return vars: refine_moved_guards! (called inside cleanup_decisions!)
    # sets has_moved_guard=false for string vars because strings are Copy types and
    # are never GIVE'd in OwnershipDataflow.  But carry return vars ARE transferred to the
    # caller implicitly via RETURN.  Override the flag so MIR::Drop emits a guarded defer
    # and collect_return_escapes emits SuppressCleanup before the return.
    if fn.respond_to?(:heap_carry_return_vars) && fn.heap_carry_return_vars&.any? && bindings
      fn.heap_carry_return_vars.each do |var_name|
        entry = bindings[var_name.to_s]
        next unless entry && entry[:needs_cleanup]
        entry[:has_moved_guard] = true
      end
    end

    # Stamp cleanup_bindings on the FunctionDef so MIRLowering can read
    # allocator + cleanup info without relying on OLD MIR::Alloc/Drop siblings.
    fn.cleanup_bindings = bindings

    # Stamp field pre-cleanup info directly on Assignment nodes.
    CleanupClassifier.stamp_field_pre_cleanups!(fn.body, bindings, schema_lookup: @schema_lookup) if has_bindings

    @fn_has_catch = has_catch
    @current_transform_fn = fn
    fn.body = transform_body(fn.body, bindings, promo)
    @current_transform_fn = nil

    # Transform catch clause bodies so string returns are annotated for heap-dupe.
    if has_catch
      fn.catch_clauses.each do |clause|
        clause[:body] = transform_body(clause[:body], nil, nil) if clause[:body]
      end
      if fn.default_catch.is_a?(Array)
        fn.default_catch = transform_body(fn.default_catch, nil, nil)
      end
    end
    @fn_has_catch = false

    # Build moved_guard_info map: { var_name => bool } for all bindings.
    stamp_moved_guard_info!(fn, bindings) if has_bindings

  end

  # Pre-mark bindings that are captured by BG blocks as needing moved guards.
  # This runs BEFORE refine_moved_guards! so that when Drops are later created
  # (which snapshot cleanup_entry = entry.dup), the has_moved_guard flag is
  # already correct. Without this, insert_bg_resource_suppress! would mutate
  # bindings AFTER Drops were created, causing a split between the Drop's
  # snapshot and the binding's current state.
  def pre_mark_bg_resource_captures!(fn, bindings)
    walk_for_bg_captures(fn.body, bindings)
  end

  def walk_for_bg_captures(stmts, bindings)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      each_bg_in_stmt(stmt) do |bg|
        resource_captures = bg.capture_analysis&.resource_captures
        next unless resource_captures&.any?
        resource_captures.each do |name|
          entry = bindings&.dig(name)
          next unless entry && entry[:needs_cleanup]
          entry[:has_moved_guard] = true
        end
      end
      # Recurse into nested control flow.
      case stmt
      when AST::IfStatement
        walk_for_bg_captures(stmt.then_branch, bindings)
        walk_for_bg_captures(stmt.else_branch, bindings)
      when AST::WhileLoop
        walk_for_bg_captures(stmt.do_branch, bindings)
      when AST::ForRange, AST::ForEach
        walk_for_bg_captures(stmt.body, bindings)
      when AST::MatchStatement
        stmt.cases&.each { |c| walk_for_bg_captures(c[:body], bindings) }
        walk_for_bg_captures(stmt.default_case, bindings)
      when AST::WithBlock
        walk_for_bg_captures(stmt.body, bindings)
      when AST::DoBlock
        stmt.branches&.each { |b| walk_for_bg_captures(b[:body], bindings) }
      when AST::BgBlock, AST::BgStreamBlock
        walk_for_bg_captures(stmt.body, bindings)
      end
    end
  end

  # Recursively transform a statement list, inserting MIR nodes.
  # Returns a new array (does not mutate the input).
  def transform_body(stmts, bindings, promo)
    return stmts unless stmts.is_a?(Array)
    result = []
    stmts.each do |stmt|
      # Recurse into nested control flow first.
      recurse_branches!(stmt, bindings, promo)

      # Insert Return (escape markers) + Promote before ReturnNode.
      if stmt.is_a?(AST::ReturnNode)
        insert_return!(result, stmt, bindings, fn_node: @current_transform_fn)
        insert_promotion!(result, stmt, promo)
        # Catch string dupe: heap-dupe string returns so both success and
        # error paths have consistent allocation for caller cleanup.
        insert_catch_string_dupe!(result, stmt) if @fn_has_catch
      end

      # Stamp cleanup info on reassignment / match-as nodes.
      stamp_reassign_cleanup!(stmt, bindings)
      stamp_match_as_cleanup!(stmt, bindings)
      stamp_while_bind_cleanup!(stmt, bindings)
      stamp_if_bind_cleanup!(stmt, bindings)

      # Insert MIR::Promote before container stores that need frame-to-heap promotion.
      insert_container_promote!(result, stmt)

      # BG escape promotions: frame-allocated captures must be promoted to heap.
      insert_bg_escape_promote!(result, stmt)

      # BG scope-exit promotion: annotate BgBlocks with what their exit value needs.
      # Must run after recurse_branches! so the BgBlock body is already transformed.
      each_bg_in_stmt(stmt) do |bg|
        if bg.is_a?(AST::BgBlock)
          annotate_bg_exit_promote!(bg)
        elsif bg.is_a?(AST::BgStreamBlock)
          annotate_yield_string_dupes!(bg)
        end
      end

      # OrRescue fallback dupe: when success path is heap-promoted and fallback
      # is a struct literal, string fields need heap-duping for consistent cleanup.
      insert_or_fallback_dupe!(result, stmt)

      # Emit the original statement.
      result << stmt

      # Insert MIR verification nodes for reassignment and field pre-cleanup.
      if stmt.is_a?(AST::BindExpr) && stmt.reassign_cleanup
        result << MIR::ReassignCleanup.new(stmt.token, stmt.name.to_s, stmt.reassign_cleanup[:alloc])
      end
      if stmt.is_a?(AST::Assignment) && stmt.field_pre_cleanup
        target = stmt.name
        target_name = target.is_a?(AST::GetField) && target.target.respond_to?(:name) ? target.target.name.to_s : nil
        result << MIR::FieldCleanup.new(stmt.token, target_name, target.field, stmt.field_pre_cleanup[:alloc]) if target_name
      end

      # Insert SuppressCleanup after statements that consume bindings.
      insert_suppress_cleanup!(result, stmt, bindings)

      # BG blocks that capture resources transfer ownership — suppress outer cleanup.
      insert_bg_resource_suppress!(result, stmt, bindings)

      # BG blocks where the body uses `GIVE x` on a captured outer name also
      # transfer ownership to the fiber — same rule as a GIVE elsewhere.
      insert_bg_give_suppress!(result, stmt, bindings)
    end
    result
  end

  # Recurse into control flow branches to transform nested bodies.
  def recurse_branches!(stmt, bindings, promo)
    case stmt
    when AST::IfStatement
      stmt.then_branch = transform_body(stmt.then_branch, bindings, promo) if stmt.then_branch
      stmt.else_branch = transform_body(stmt.else_branch, bindings, promo) if stmt.else_branch
    when AST::WhileLoop
      stmt.do_branch = transform_body(stmt.do_branch, bindings, promo) if stmt.do_branch
    when AST::WhileBindLoop
      stmt.do_branch = transform_body(stmt.do_branch, bindings, promo) if stmt.do_branch
    when AST::IfBind
      stmt.then_branch = transform_body(stmt.then_branch, bindings, promo) if stmt.then_branch
      stmt.else_branch = transform_body(stmt.else_branch, bindings, promo) if stmt.else_branch && !stmt.else_branch.empty?
    when AST::ForRange, AST::ForEach
      stmt.body = transform_body(stmt.body, bindings, promo) if stmt.body
    when AST::MatchStatement
      stmt.cases&.each { |c| c[:body] = transform_body(c[:body], bindings, promo) if c[:body] }
      if stmt.default_case
        stmt.default_case = transform_body(stmt.default_case, bindings, promo)
      end
    when AST::WithBlock
      stmt.body = transform_body(stmt.body, bindings, promo) if stmt.body
    when AST::DoBlock
      stmt.branches&.each do |b|
        b[:body] = transform_body(b[:body], bindings, promo) if b[:body]
      end
    when AST::BgBlock, AST::BgStreamBlock
      stmt.body = transform_body(stmt.body, bg_inner_bindings(stmt, bindings), promo) if stmt.body
    end
    # Process BgBlock bodies found in expression positions (MethodCall/FuncCall
    # args, VarDecl/BindExpr values). AST.walk_body misses these since it doesn't
    # recurse into call arguments. Only BgBlock (outer consumer fiber) -- not
    # BgStreamBlock (generator fiber has special YIELD handling).
    case stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      val = stmt.respond_to?(:value) ? stmt.value : nil
      if val.is_a?(AST::BgBlock) && val.body
        val.body = transform_body(val.body, bg_inner_bindings(val, bindings), promo)
      end
    when AST::MethodCall, AST::FuncCall
      stmt.args&.each do |a|
        if a.is_a?(AST::BgBlock) && a.body
          a.body = transform_body(a.body, bg_inner_bindings(a, bindings), promo)
        end
      end
    end
  end

  # Bindings as seen from INSIDE a BG body: captured names belong to the
  # outer scope and their moved-guard vars (e.g. `lst_moved`) are not
  # visible here, so we must not emit SuppressCleanup for them inside the
  # fiber. The outer-scope pass (insert_bg_give_suppress!) handles moves
  # of captures; inside the body only BG-local bindings are consumable.
  def bg_inner_bindings(bg_node, bindings)
    return bindings unless bindings
    captures = bg_node.capture_analysis&.captures
    return bindings unless captures&.any?
    bindings.reject { |name, _| captures.key?(name) }
  end

  # Insert MIR::SuppressCleanup after statements that consume ownership of
  # tracked bindings. Replaces the transpiler's emit_move_suppression and
  # emit_consumed_moves methods.
  def insert_suppress_cleanup!(result, stmt, bindings)
    return unless bindings
    return if stmt.is_a?(AST::ReturnNode) # handled by insert_return!

    names = collect_consumed_names(stmt, bindings)
    names.each do |name|
      result << MIR::SuppressCleanup.new(stmt.token, name)
    end
  end

  # Find all BG/stream blocks reachable from a statement. Walks into expression
  # positions: direct values (VarDecl, BindExpr, Assignment), MethodCall args,
  # FuncCall args. Yields each BgBlock/BgStreamBlock found.
  def each_bg_in_stmt(stmt, &block)
    case stmt
    when AST::BgBlock, AST::BgStreamBlock
      yield stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      _walk_expr_for_bg(stmt.value, &block)
    when AST::FuncCall
      stmt.args&.each { |a| _walk_expr_for_bg(a, &block) }
    when AST::MethodCall
      stmt.args&.each { |a| _walk_expr_for_bg(a, &block) }
    end
  end

  def _walk_expr_for_bg(expr, &block)
    return unless expr
    case expr
    when AST::BgBlock, AST::BgStreamBlock
      yield expr
    when AST::FuncCall
      expr.args&.each { |a| _walk_expr_for_bg(a, &block) }
    when AST::MethodCall
      _walk_expr_for_bg(expr.object, &block)
      expr.args&.each { |a| _walk_expr_for_bg(a, &block) }
    end
  end

  # Insert MIR::SuppressCleanup for outer bindings consumed by `GIVE x`
  # inside a BG body. Mirrors insert_bg_resource_suppress! — the fiber
  # takes ownership, so the outer scope's defer must be guarded.
  def insert_bg_give_suppress!(result, stmt, bindings)
    each_bg_in_stmt(stmt) do |bg|
      next unless bg.body
      captures = (bg.capture_analysis&.captures || {}).keys.map(&:to_s).to_set
      next if captures.empty?
      gives = collect_bg_body_give_names(bg.body, captures)
      gives.each do |name|
        entry = bindings&.dig(name)
        next if entry && !entry[:needs_cleanup]
        result << MIR::SuppressCleanup.new(stmt.token, name)
      end
    end
  end

  # Walk a BG body looking for `GIVE capture` — MoveNode wrapping an
  # Identifier whose name is in the capture set.
  def collect_bg_body_give_names(body, capture_names)
    out = []
    AST.walk_body(body) do |node|
      _walk_expr_for_give(node, capture_names, out)
    end
    out.uniq
  end

  def _walk_expr_for_give(node, capture_names, out)
    return unless node
    case node
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      # GIVE x to a TAKES param of an adapted type (e.g. @list arg to a
      # slice param) -- function_analysis.rb wraps the user's MoveNode
      # in a CopyNode for the type adaptation but stamps was_moved=true
      # on the wrapper. The user's GIVE intent lives on that flag.
      if node.is_a?(AST::CopyNode) && node.respond_to?(:was_moved) && node.was_moved &&
         node.value.is_a?(AST::Identifier) && capture_names.include?(node.value.name.to_s)
        out << node.value.name.to_s
      end
      # Otherwise: COPY / CLONE do not consume the source.
    when AST::MoveNode
      if node.value.is_a?(AST::Identifier) && capture_names.include?(node.value.name.to_s)
        out << node.value.name.to_s
      else
        _walk_expr_for_give(node.value, capture_names, out)
      end
    when AST::BinaryOp
      _walk_expr_for_give(node.left, capture_names, out)
      _walk_expr_for_give(node.right, capture_names, out)
    when AST::UnaryOp
      _walk_expr_for_give(node.right, capture_names, out)
    when AST::FuncCall
      node.args&.each { |a| _walk_expr_for_give(a, capture_names, out) }
    when AST::MethodCall
      _walk_expr_for_give(node.object, capture_names, out)
      node.args&.each { |a| _walk_expr_for_give(a, capture_names, out) }
    when AST::GetField
      _walk_expr_for_give(node.target, capture_names, out)
    when AST::GetIndex
      _walk_expr_for_give(node.target, capture_names, out)
      _walk_expr_for_give(node.index, capture_names, out)
    when AST::StructLit
      node.fields&.each_value { |v| _walk_expr_for_give(v, capture_names, out) }
    when AST::ListLit
      node.items&.each { |i| _walk_expr_for_give(i, capture_names, out) }
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      _walk_expr_for_give(node.value, capture_names, out)
    when AST::ReturnNode
      _walk_expr_for_give(node.value, capture_names, out)
    when AST::CapabilityWrap
      _walk_expr_for_give(node.value, capture_names, out)
    end
  end

  # Insert MIR::SuppressCleanup for resources captured by BG blocks.
  # When a BG fiber captures a resource (TCP fd, etc.), ownership transfers
  # to the fiber — the outer scope's defer must not close it.
  #
  # Resource variables always emit a guarded_defer (moved guard pattern)
  # regardless of scope depth. We must insert SuppressCleanup whenever a
  # BG block captures a resource — even for inner-scope variables that
  # don't appear in the function-level bindings hash.
  def insert_bg_resource_suppress!(result, stmt, bindings)
    each_bg_in_stmt(stmt) do |bg|
      resource_captures = bg.capture_analysis&.resource_captures
      next unless resource_captures&.any?
      resource_captures.each do |name|
        entry = bindings&.dig(name)
        # When dataflow says always-moved (needs_cleanup=false), no Drop was
        # inserted - the fiber is the sole owner. No suppress needed.
        next if entry && !entry[:needs_cleanup]
        # has_moved_guard was already set by pre_mark_bg_resource_captures!
        result << MIR::SuppressCleanup.new(stmt.token, name)
      end
    end
  end

  # Quick check: does the function body contain any BG/stream blocks with
  # captures needing escape promotion? Used to ensure transform_body runs
  # even for functions with no cleanup bindings.
  def body_has_bg_escape_promotes?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |stmt|
      found = false
      each_bg_in_stmt(stmt) do |bg|
        captured = bg.capture_analysis&.captures
        next unless captured&.any?
        found = true if captured.any? do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          t && t.needs_escape_promotion? && !t.needs_pointer_passing? && !@bg_heap_upgraded&.include?(name)
        end
      end
      found
    end
  end

  # Annotate a BgBlock with the scope-exit promotion its last expression needs.
  # Mirrors the logic insert_promotion!/insert_catch_string_dupe! apply to
  # function ReturnNodes, but for the BG fiber's implicit return value.
  # Currently handles strings; struct field promotion is left for future work.
  # Walk a statement list looking for BgBlocks (in expression position) and
  # annotate each with the scope-exit promotion its last expression needs.
  # Must run unconditionally — the outer function may have no bindings/promotions
  # but still contain BG blocks that return frame-allocated values.
  def annotate_bg_exits_in_body!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      each_bg_in_stmt(stmt) { |bg| annotate_bg_exit_promote!(bg) if bg.is_a?(AST::BgBlock) }
      # Recurse into control-flow branches.
      case stmt
      when AST::IfStatement
        annotate_bg_exits_in_body!(stmt.then_branch)
        annotate_bg_exits_in_body!(stmt.else_branch)
      when AST::WhileLoop
        annotate_bg_exits_in_body!(stmt.do_branch)
      when AST::ForRange, AST::ForEach
        annotate_bg_exits_in_body!(stmt.body)
      when AST::MatchStatement
        stmt.cases&.each { |c| annotate_bg_exits_in_body!(c[:body]) }
        annotate_bg_exits_in_body!(stmt.default_case)
      when AST::WithBlock
        annotate_bg_exits_in_body!(stmt.body)
      when AST::DoBlock
        stmt.branches&.each { |b| annotate_bg_exits_in_body!(b[:body]) }
      end
    end
  end

  def annotate_bg_exit_promote!(bg_node)
    body = bg_node.body
    return unless body.is_a?(Array)

    # Walk backward past MIR marker nodes to find the last real expression.
    last_expr = nil
    body.reverse_each do |stmt|
      next if stmt.is_a?(MIR::Alloc) || stmt.is_a?(MIR::Drop) ||
              stmt.is_a?(MIR::SuppressCleanup) || stmt.is_a?(MIR::Return) ||
              stmt.is_a?(MIR::Promote) || stmt.is_a?(MIR::AllocMark) ||
              stmt.is_a?(MIR::Cleanup) || stmt.is_a?(MIR::MoveMark)
      last_expr = stmt.is_a?(AST::ThenChain) ? stmt.steps.last&.dig(:expr) : stmt
      break
    end

    return unless last_expr
    return if last_expr.is_a?(AST::Assignment)

    ft = last_expr.respond_to?(:full_type) ? last_expr.full_type : nil
    return unless ft
    t = ft.is_a?(Type) ? ft : Type.new(ft)
    return if t.void?

    bg_node.exit_promote = { strategy: :string_dupe } if bg_exit_needs_string_dupe?(last_expr, t)
  end

  # Returns true when a BG block's last expression is a frame-allocated string
  # that will be invalidated when the fiber's frame is rewound on exit.
  # - rodata strings (literals) live in the binary — safe without dupe.
  # - heap strings are already owned by the caller — no dupe needed.
  # - frame strings (from allocating stdlib calls or frame-provenance types) must be duped.
  def bg_exit_needs_string_dupe?(expr, t)
    return false unless t.string?
    return false if t.heap? || t.rodata?
    return true  if t.frame?
    # No explicit provenance: check the stdlib def for frame allocation.
    if expr.respond_to?(:matched_stdlib_def)
      msd = expr.matched_stdlib_def
      return true if msd.is_a?(Hash) && msd[:return_alloc] == :frame
    end
    false
  end

  # Annotate YieldExpr nodes inside a BgStreamBlock that yield frame-allocated strings.
  # Sets yield_node.yield_dupe = true; the lowerer then wraps the push arg in a heap dupe.
  def annotate_yield_string_dupes!(stream_node)
    walk_stream_yields(stream_node.body)
  end

  def walk_stream_yields(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      if stmt.is_a?(AST::YieldExpr)
        ft = stmt.expr.respond_to?(:full_type) ? stmt.expr.full_type : nil
        t = ft.is_a?(Type) ? ft : (ft ? Type.new(ft) : nil)
        stmt.yield_dupe = true if t && bg_exit_needs_string_dupe?(stmt.expr, t)
      else
        case stmt
        when AST::WhileLoop    then walk_stream_yields(stmt.do_branch)
        when AST::ForRange, AST::ForEach then walk_stream_yields(stmt.body)
        when AST::IfStatement
          walk_stream_yields(stmt.then_branch)
          walk_stream_yields(stmt.else_branch)
        when AST::BgStreamBlock  # stop at nested stream boundaries
        end
      end
    end
  end

  # Insert MIR::Promote for frame-allocated variables captured by BG/stream fibers.
  # Lists get :list strategy (in-place promoteList). Strings get :bg_string
  # strategy (transpiler emits dupe inside the BG block where the allocator is available).
  def insert_bg_escape_promote!(result, stmt)
    each_bg_in_stmt(stmt) do |bg|
      captured = bg.capture_analysis&.captures
      next unless captured&.any?
      captured.each do |name, type_obj|
        t = type_obj ? Type.new(type_obj) : nil
        next unless t && t.needs_escape_promotion?
        next if t.needs_pointer_passing?
        next if @bg_heap_upgraded&.include?(name)  # Already heap from Phase 1.5b
        if t.list_collection?
          result << MIR::Promote.new(bg.token, name, t.zig_type, :list, nil)
        else
          # :bg_string: annotate directly on BgBlock (no MIR::Promote needed)
          bg.capture_string_dupes ||= Set.new
          bg.capture_string_dupes.add(name)
        end
      end
    end
  end

  # Annotate the ReturnNode when a catch function returns a string type.
  # Both success and error paths must return heap-backed strings for
  # consistent caller cleanup. Annotation on the node replaces the old
  # MIR::Promote(:catch_string_dupe) pending-flag mechanism.
  def insert_catch_string_dupe!(result, ret_node)
    return unless ret_node.value
    ft = ret_node.value.respond_to?(:full_type) ? ret_node.value.full_type : nil
    return unless ft
    t = Type.new(ft)
    return unless t.string?
    ret_node.catch_string_dupe_ret = true
  end

  # Annotate an OrRescue node where the success path is heap-promoted and the
  # fallback is a struct literal. Sets or_fallback_dupe on the BinaryOp so the
  # transpiler heap-dupes string fields in the fallback to match cleanup semantics.
  def insert_or_fallback_dupe!(result, stmt)
    or_node = find_or_rescue_in_value(stmt)
    return unless or_node
    return unless or_node.right.is_a?(AST::StructLit)
    return unless or_rescue_needs_fallback_dupe?(or_node)
    # Annotate directly on BinaryOp node (no MIR::Promote needed)
    or_node.or_fallback_dupe = true
  end

  # Walk into a statement's value expression to find an OrRescue node.
  def find_or_rescue_in_value(stmt)
    expr = case stmt
           when AST::VarDecl, AST::BindExpr then stmt.value
           when AST::Assignment then stmt.value
           when AST::ReturnNode then stmt.value
           else nil
           end
    find_or_rescue_expr(expr)
  end

  def find_or_rescue_expr(expr)
    return nil unless expr
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR_RESCUE
      return expr
    end
    if expr.is_a?(AST::BinaryOp) && expr.op == :OR
      return find_or_rescue_expr(expr.left)
    end
    nil
  end

  # Check if an OrRescue's success path is heap-promoted (same logic as
  # the transpiler's has_heap_promoted_call? but at MIR insertion time).
  def or_rescue_needs_fallback_dupe?(or_node)
    return false unless or_node.is_a?(AST::BinaryOp) && or_node.op == :OR_RESCUE
    left = or_node.left
    ti = left.type_info rescue nil
    ti = ti.is_a?(Type) ? ti : nil
    return true if ti&.heap_provenance?
    if left.is_a?(AST::BinaryOp) && (left.op == :OR || left.op == :OR_RESCUE)
      return or_rescue_needs_fallback_dupe_left?(left)
    end
    false
  end

  def or_rescue_needs_fallback_dupe_left?(expr)
    return false unless expr
    ti = expr.type_info rescue nil
    ti = ti.is_a?(Type) ? ti : nil
    return true if ti&.heap_provenance?
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_RESCUE)
      return or_rescue_needs_fallback_dupe_left?(expr.left)
    end
    false
  end

  # Collect names of bindings consumed by a statement.
  # Three consumption paths:
  #   1. Direct RHS: identifier used as value in assignment/declaration
  #   2. Standalone GIVE: `GIVE x;` as a statement
  #   3. Nested: identifier passed as TAKES/GIVE arg or used as struct field
  def collect_consumed_names(stmt, bindings)
    names = Set.new

    # 1. Direct RHS consumption
    rhs = case stmt
          when AST::VarDecl    then stmt.value
          when AST::BindExpr   then stmt.value
          when AST::Assignment
            # Map indexed assignments (map[k] = val) apply dupeUnionValue before
            # calling put, so the map stores a deep copy. The original value is NOT
            # consumed -- its cleanup defer must fire normally.
            lhs = stmt.name
            if lhs.is_a?(AST::GetIndex)
              target_ti = (lhs.target.type_info rescue nil)
              target_ti = target_ti.is_a?(Type) ? target_ti : (target_ti ? Type.new(target_ti) : nil)
              target_ti&.map? ? nil : stmt.value
            else
              stmt.value
            end
          else nil
          end

    if rhs
      is_move = rhs.is_a?(AST::MoveNode)
      ident = is_move ? rhs.value : rhs
      add_if_consumed(ident, names, bindings, is_move) if ident.is_a?(AST::Identifier)
    end

    # 2. Standalone GIVE: `GIVE x;` as a bare statement
    if stmt.is_a?(AST::MoveNode) && stmt.value.is_a?(AST::Identifier)
      add_if_consumed(stmt.value, names, bindings, true)
    end

    # 2. Nested consumption (StructLit fields, FuncCall/MethodCall TAKES args)
    value_expr = case stmt
                 when AST::VarDecl, AST::BindExpr then stmt.value
                 when AST::Assignment then stmt.value
                 else stmt
                 end
    value_expr = value_expr.value if value_expr.is_a?(AST::MoveNode)
    walk_consumed(value_expr, names, bindings)

    names
  end

  # Recursively walk an expression to find consumed identifiers in
  # StructLit fields and FuncCall/MethodCall TAKES/GIVE args.
  def walk_consumed(node, names, bindings)
    return unless node
    case node
    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      walk_consumed(node.value, names, bindings)
    when AST::StructLit
      node.fields.each_value do |v|
        if v.is_a?(AST::Identifier)
          add_if_consumed(v, names, bindings, false)
        else
          walk_consumed(v, names, bindings)
        end
      end
    when AST::FuncCall, AST::MethodCall
      node.args.each do |a|
        if a.is_a?(AST::MoveNode) && a.value.is_a?(AST::Identifier)
          add_if_consumed(a.value, names, bindings, true)
        elsif a.respond_to?(:was_moved) && a.was_moved && a.is_a?(AST::Identifier)
          add_if_consumed(a, names, bindings, true)
        elsif a.is_a?(AST::StructLit) || a.is_a?(AST::CapabilityWrap)
          walk_consumed(a, names, bindings)
        end
      end
    end
  end

  # Add identifier to consumed set if it has a moved guard and passes
  # Copy-type filters. RC types only consume on explicit GIVE (MoveNode).
  def add_if_consumed(ident, names, bindings, is_move)
    name = ident.name.to_s
    entry = bindings[name]
    return unless entry && entry[:has_moved_guard] && entry[:needs_cleanup]

    ti = ident.type_info
    return if ti&.string?

    # RC types: only consume on explicit GIVE
    if ti && (ti.any_rc? rescue false)
      names << name if is_move
      return
    end

    names << name
  end

  # Stamp reassign_cleanup on BindExpr :assign nodes that overwrite non-Copy variables.
  def stamp_reassign_cleanup!(stmt, bindings)
    return unless bindings
    return unless stmt.is_a?(AST::BindExpr) && stmt.mode == :assign

    entry = bindings[stmt.name.to_s]
    return unless entry && entry[:needs_cleanup] && entry[:kind] != :resource

    ti = stmt.type_info
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    zig_type = ti ? (Type.new(ti.resolved).zig_type rescue ti.resolved.to_s) : "UNKNOWN"
    stmt.reassign_cleanup = { kind: entry[:kind], alloc: entry[:alloc], zig_type: zig_type }
  end

  # Insert MIR nodes for MATCH-AS cleanup into case bodies.
  # Previously stamp-only; now inserts MIR::Alloc + MIR::Drop + MIR::SuppressCleanup
  # so the checker verifies match_as cleanup like any other binding.
  def stamp_match_as_cleanup!(stmt, bindings)
    return unless bindings
    return unless stmt.is_a?(AST::MatchStatement)
    return unless stmt.expr.is_a?(AST::Identifier) && stmt.expr.was_moved

    src_entry = bindings[stmt.expr.name.to_s]
    has_as_cleanup = false

    stmt.cases&.each do |c|
      next unless c[:binding]
      as_entry = bindings[c[:binding].to_s]
      next unless as_entry && as_entry[:needs_cleanup]

      has_as_cleanup = true

      # Insert MIR nodes at the start of case body for checker coverage.
      # Order: source suppression, then AS binding Alloc + Drop.
      mir_prefix = []
      if src_entry && src_entry[:needs_cleanup]
        mir_prefix << MIR::SuppressCleanup.new(stmt.token, stmt.expr.name.to_s)
      end
      mir_prefix << MIR::Alloc.new(stmt.token, c[:binding].to_s, as_entry[:kind], as_entry[:alloc])
      drop = MIR::Drop.new(
        stmt.token, c[:binding].to_s, as_entry[:kind], as_entry[:alloc],
        true, nil, nil, nil
      )
      drop.cleanup_entry = as_entry
      mir_prefix << drop
      c[:body] = mir_prefix + (c[:body] || [])
    end

    # Ensure source has moved guard so _moved variable exists for suppression.
    # Only set if the source still needs cleanup (dataflow may have eliminated it).
    src_entry[:has_moved_guard] = true if has_as_cleanup && src_entry && src_entry[:needs_cleanup]
  end

  def stamp_while_bind_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::WhileBindLoop)
    entry = bindings[stmt.binding_name.to_s]
    return unless entry && entry[:needs_cleanup]
    alloc_node = MIR::Alloc.new(stmt.token, stmt.binding_name.to_s, entry[:kind], entry[:alloc])
    drop = MIR::Drop.new(stmt.token, stmt.binding_name.to_s, entry[:kind], entry[:alloc],
                         true, nil, nil, nil)
    drop.cleanup_entry = entry
    stmt.do_branch = [alloc_node, drop] + (stmt.do_branch || [])
  end

  def stamp_if_bind_cleanup!(stmt, bindings)
    return unless stmt.is_a?(AST::IfBind)
    mir_prefix = []
    stmt.bindings.each do |b|
      entry = bindings[b[:name].to_s]
      next unless entry && entry[:needs_cleanup]
      mir_prefix << MIR::Alloc.new(stmt.token, b[:name].to_s, entry[:kind], entry[:alloc])
      drop = MIR::Drop.new(stmt.token, b[:name].to_s, entry[:kind], entry[:alloc],
                           true, nil, nil, nil)
      drop.cleanup_entry = entry
      mir_prefix << drop
    end
    stmt.then_branch = mir_prefix + (stmt.then_branch || []) unless mir_prefix.empty?
  end

  # Insert MIR::Promote before indexed Assignment nodes where the container's
  # INDEX_OPS :set has takes_value and the value type needs frame-to-heap
  # promotion. Driven by the INDEX_OPS registry in std_lib.rb.
  def insert_container_promote!(result, stmt)
    return unless stmt.is_a?(AST::Assignment)
    return unless stmt.name.is_a?(AST::GetIndex)
    target_node = stmt.name.target

    # Look up the INDEX_OPS :set entry for this container type.
    target_ti = target_node.type_info rescue nil
    target_ti = Type.new(target_ti) if target_ti && !target_ti.is_a?(Type)
    set_op = resolve_container_set_op(target_ti)
    return unless set_op && set_op[:takes_value]

    # Check if the value type needs frame-to-heap promotion.
    # Strings are handled by the :dupe_string_literal transform in the lowerer;
    # :container_promote only fires for !string? values.
    val_ti = stmt.value.type_info rescue nil
    return unless val_ti
    val_ti = Type.new(val_ti) if val_ti && !val_ti.is_a?(Type)
    return unless val_ti.needs_promotion?(@schema_lookup) && !val_ti.string?

    # Annotate directly on Assignment node (no MIR::Promote needed).
    # Use bare type (strip *) — promote(T, rt, &v) expects T = base, not pointer.
    zig_t = val_ti.zig_type
    zig_t = zig_t[1..] if zig_t.start_with?("*")
    stmt.container_promote_zig_type = zig_t
  end

  # Resolve the INDEX_OPS :set entry for a container type.
  def resolve_container_set_op(type_info)
    return nil unless type_info
    kind = container_kind(type_info)
    return nil unless kind
    INDEX_OPS.dig(kind, :set)
  end

  # Map a type to its INDEX_OPS container kind symbol.
  def container_kind(type_info)
    type_info&.dispatch_key
  end


  # Build moved_guard_info: { var_name => bool } for all bindings.
  def stamp_moved_guard_info!(fn, bindings)
    info = {}
    bindings.each do |name, entry|
      info[name] = true if entry[:has_moved_guard] && entry[:needs_cleanup]
    end
    fn.moved_guard_info = info unless info.empty?
  end

  # Insert MIR::Promote before a return statement and annotate the
  # ReturnNode for struct-level promotion wrapping.
  #
  # Defer suppression for escaped variables is handled by MIR::Return
  # (inserted by insert_return!) and consumed by the transpiler's
  # collect_escaping_identifiers in the ReturnNode handler.
  def insert_promotion!(result, ret_node, promo)
    return unless promo && !promo.empty?

    filtered = PromotionClassifier.filter_for_return(promo, ret_node.value)

    # Per-variable promotions.
    (filtered[:var_promotes] || []).each do |vp|
      strategy = classify_promote_strategy(vp[:zig_type])
      result << MIR::Promote.new(ret_node.token, vp[:var], vp[:zig_type], strategy, nil)
    end

    # Struct-level field promotion: annotate the ReturnNode directly so
    # lower_return can apply promotion without global pending-flag state.
    if filtered[:struct_promote] && PromotionClassifier.needs_promote?(filtered, ret_node)
      ret_node.promote_ret_wrap = :var
      ret_node.ret_field_promote_data = {
        zig_type: filtered[:struct_promote],
        fields:   filtered[:unhandled_promote_fields]
      }
    elsif filtered[:var_promotes]&.any?
      ret_node.promote_ret_wrap = :const
    end
  end

  # Insert MIR::Return before a ReturnNode to mark which local variables'
  # ownership escapes to the caller. The checker uses this to know that
  # escaped vars don't need local cleanup.
  def insert_return!(result, ret_node, bindings, fn_node: nil)
    return unless bindings
    escaped = collect_return_escapes(ret_node, bindings, fn_node: fn_node)
    return if escaped.empty?
    result << MIR::Return.new(ret_node.token, escaped)
    # Insert SuppressCleanup for each escaped var so the transpiler doesn't
    # need to re-compute escape analysis.
    escaped.each do |name|
      result << MIR::SuppressCleanup.new(ret_node.token, name)
    end
  end

  # Walk a return expression and collect variable names whose ownership
  # transfers to the caller. Mirrors transpiler's collect_escaping_identifiers
  # but filters to bindings with has_moved_guard (those needing suppression).
  def collect_return_escapes(ret_node, bindings, fn_node: nil)
    return [] unless ret_node.value
    ids = collect_escaping_ids(ret_node.value)
    ids.map { |id| id.name.to_s }
       .select { |n| bindings[n]&.dig(:has_moved_guard) && bindings[n]&.dig(:needs_cleanup) }
       .uniq
  end

  def collect_escaping_ids(node)
    return [] unless node
    case node
    when AST::Identifier then [node]
    when AST::MoveNode   then collect_escaping_ids(node.value)
    when AST::StructLit  then node.fields.values.flat_map { |v| collect_escaping_ids(v) }
    when AST::FuncCall, AST::MethodCall
      node.args.select { |a| a.respond_to?(:was_moved) && a.was_moved }
               .flat_map { |a| collect_escaping_ids(a) }
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode then []
    else []
    end
  end

  def classify_promote_strategy(zig_type)
    return :generic unless zig_type
    if zig_type.include?("ArrayListUnmanaged")
      :list
    elsif zig_type.include?("StringMap")
      :string_map
    else
      :generic
    end
  end

end
