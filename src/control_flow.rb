# control_flow.rb - CFG construction, ownership dataflow, MIR node insertion
#
# Three components:
#   1. FunctionCFG: builds a control flow graph from an annotated AST function.
#      Basic blocks contain references to AST statements. Edges represent
#      branch/join/loop structure.
#
#   2. OwnershipDataflow: forward dataflow analysis on the CFG. Computes per-
#      variable ownership state (owned/moved/maybe_moved) at each basic block
#      boundary. Determines whether cleanup is needed and whether a moved guard
#      is required. Runs after annotation, uses was_moved flags on AST nodes.
#
#   3. MIRPass: runs CleanupClassifier/PromotionClassifier, inserts MIR nodes
#      (Drop, Promote, SuppressCleanup) into AST statement lists. The transpiler
#      consumes MIR::Drop for variable cleanup. Promote/SuppressCleanup are
#      inserted but not yet consumed.
#
# Runs AFTER annotation + plan computation, BEFORE transpilation.

require_relative "ast"

# ==========================================
# CFG - Control Flow Graph (analysis only)
# ==========================================

class BasicBlock
  attr_accessor :id, :stmts, :successors, :predecessors

  def initialize(id)
    @id = id
    @stmts = []
    @successors = []
    @predecessors = []
  end

  def add_successor(block)
    @successors << block unless @successors.include?(block)
    block.predecessors << self unless block.predecessors.include?(self)
  end

  def terminator
    @stmts.last
  end
end

class FunctionCFG
  attr_reader :blocks, :entry, :exit_block, :fn_name

  def initialize(fn_name)
    @fn_name = fn_name
    @blocks = []
    @block_counter = 0
    @entry = new_block
    @exit_block = new_block  # virtual exit - all returns target this
  end

  def new_block
    block = BasicBlock.new(@block_counter)
    @block_counter += 1
    @blocks << block
    block
  end

  # Build a CFG from an annotated function AST.
  # Each basic block holds references to AST statements (not copies).
  # Branch points (if/while/match/for) create new blocks with edges.
  #
  # @param fn_node [AST::FunctionDef]
  # @param can_fail_fns [Set<String>, nil] names of functions that can fail.
  #   When provided, statements containing calls to these functions get an
  #   error edge to the exit block (models Zig try/error-unwind semantics).
  def self.build(fn_node, can_fail_fns: nil)
    cfg = new(fn_node.name)
    cfg.instance_variable_set(:@can_fail_fns, can_fail_fns)
    last_block = build_body(fn_node.body || [], cfg.entry, cfg.exit_block, cfg)
    # Connect fall-through to exit (implicit return at end of function).
    last_block&.add_successor(cfg.exit_block) if last_block
    cfg
  end

  private

  def self.build_body(stmts, current_block, exit_target, cfg)
    stmts = [stmts] unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::IfStatement
        current_block.stmts << stmt
        then_block = cfg.new_block
        else_block = stmt.else_branch ? cfg.new_block : nil
        join_block = cfg.new_block

        current_block.add_successor(then_block)
        current_block.add_successor(else_block || join_block)

        then_exit = build_body(stmt.then_branch || [], then_block, exit_target, cfg)
        then_exit&.add_successor(join_block) if then_exit

        if stmt.else_branch
          else_exit = build_body(stmt.else_branch, else_block, exit_target, cfg)
          else_exit&.add_successor(join_block) if else_exit
        end

        current_block = join_block

      when AST::WhileLoop
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block

        current_block.add_successor(body_block)   # enter loop
        current_block.add_successor(after_block)   # skip loop

        body_exit = build_body(stmt.do_branch || [], body_block, exit_target, cfg)
        body_exit&.add_successor(current_block)    # loop back
        body_exit&.add_successor(after_block)      # break

        current_block = after_block

      when AST::ForRange, AST::ForEach
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block

        current_block.add_successor(body_block)
        current_block.add_successor(after_block)

        body_exit = build_body(stmt.body || [], body_block, exit_target, cfg)
        body_exit&.add_successor(current_block)    # loop back
        body_exit&.add_successor(after_block)      # done

        current_block = after_block

      when AST::MatchStatement
        current_block.stmts << stmt
        join_block = cfg.new_block

        (stmt.cases || []).each do |c|
          case_block = cfg.new_block
          current_block.add_successor(case_block)
          case_exit = build_body(c[:body] || [], case_block, exit_target, cfg)
          case_exit&.add_successor(join_block) if case_exit
        end
        if stmt.default_case
          default_block = cfg.new_block
          current_block.add_successor(default_block)
          default_exit = build_body(stmt.default_case, default_block, exit_target, cfg)
          default_exit&.add_successor(join_block) if default_exit
        end

        current_block = join_block

      when AST::ReturnNode
        current_block.stmts << stmt
        current_block.add_successor(cfg.exit_block)
        return nil  # no fall-through after return

      when AST::BreakNode
        current_block.stmts << stmt
        return nil  # break exits the loop - handled by loop structure

      else
        # Error edge: if this statement can fail (contains a try call),
        # Zig may unwind to the caller BEFORE the statement completes.
        # Place the error edge BEFORE the statement so the dataflow state
        # on the error path does not include effects of this statement
        # (e.g., a VarDecl's variable is not yet bound on try-unwind).
        if cfg.instance_variable_get(:@can_fail_fns) &&
           stmt_can_fail?(stmt, cfg.instance_variable_get(:@can_fail_fns))
          current_block.add_successor(cfg.exit_block)
          next_block = cfg.new_block
          current_block.add_successor(next_block)
          next_block.stmts << stmt
          current_block = next_block
        else
          current_block.stmts << stmt
        end
      end
    end
    current_block  # return the current block for fall-through edges
  end

  # Check if a statement (or its sub-expressions) contains a call to a
  # can_fail function. Used to determine whether an error edge is needed.
  # Checks node.can_fail (stamped by annotator on stdlib/static calls) and
  # can_fail_fns set (user-defined functions computed by compute_can_fail!).
  def self.stmt_can_fail?(node, can_fail_fns)
    return false unless node
    case node
    when AST::FuncCall
      return true if node.can_fail
      return true if can_fail_fns&.include?(node.name)
      node.args.any? { |a| stmt_can_fail?(a, can_fail_fns) }
    when AST::MethodCall
      return true if node.can_fail
      return true if can_fail_fns&.include?(node.name)
      stmt_can_fail?(node.object, can_fail_fns) ||
        node.args.any? { |a| stmt_can_fail?(a, can_fail_fns) }
    when AST::StaticCall
      return true if node.can_fail
      node.args.any? { |a| stmt_can_fail?(a, can_fail_fns) }
    when AST::VarDecl, AST::BindExpr
      stmt_can_fail?(node.value, can_fail_fns)
    when AST::Assignment
      stmt_can_fail?(node.value, can_fail_fns)
    when AST::BinaryOp
      stmt_can_fail?(node.left, can_fail_fns) || stmt_can_fail?(node.right, can_fail_fns)
    when AST::UnaryOp
      stmt_can_fail?(node.right, can_fail_fns)
    when AST::CopyNode, AST::MoveNode, AST::Cast
      stmt_can_fail?(node.value, can_fail_fns)
    when AST::GetField
      stmt_can_fail?(node.target, can_fail_fns)
    when AST::GetIndex
      stmt_can_fail?(node.target, can_fail_fns) || stmt_can_fail?(node.index, can_fail_fns)
    when AST::StructLit, AST::UnionVariantLit
      node.fields.any? { |_, v| stmt_can_fail?(v, can_fail_fns) }
    when AST::ListLit
      node.items.any? { |v| stmt_can_fail?(v, can_fail_fns) }
    when AST::ReturnNode
      stmt_can_fail?(node.value, can_fail_fns)
    else
      false
    end
  end
end

# ==========================================
# Ownership Dataflow Analysis
# ==========================================
# Forward dataflow on the CFG. Computes per-variable ownership state at each
# basic block boundary using a worklist algorithm to fixpoint.
#
# Lattice (per variable):
#   :uninit       - variable not yet declared on this path
#   :owned        - variable holds an owned value (needs cleanup)
#   :moved        - ownership transferred away (no cleanup)
#   :maybe_moved  - moved on some paths, owned on others (needs moved guard)
#
# Join: owned + moved = maybe_moved; X + uninit = X; X + X = X
#
# Output: exit_states[var] tells whether the variable needs cleanup and
# whether a _moved guard is required at the point where the function returns.

class OwnershipDataflow
  UNINIT      = :uninit
  OWNED       = :owned
  MOVED       = :moved
  MAYBE_MOVED = :maybe_moved

  attr_reader :block_in, :block_out

  def initialize(cfg, fn_node)
    @cfg = cfg
    @fn_node = fn_node
    @block_in  = {}  # block.id => { var_name => state }
    @block_out = {}  # block.id => { var_name => state }
  end

  # Run the forward dataflow to fixpoint. Returns self for chaining.
  def analyze!
    # Initialize all blocks to empty state.
    @cfg.blocks.each do |b|
      @block_in[b.id]  = {}
      @block_out[b.id] = {}
    end

    # Seed entry block with TAKES param ownership.
    @block_in[@cfg.entry.id] = init_entry_state

    # Seed worklist with all blocks so every block is processed at least
    # once (an empty entry block produces {} which equals the initial {},
    # and would otherwise fail to schedule successors).
    worklist = @cfg.blocks.dup
    in_worklist = {}
    worklist.each { |b| in_worklist[b.id] = true }

    until worklist.empty?
      block = worklist.shift
      in_worklist.delete(block.id)

      # Entry state: join predecessor exits (entry block uses init state).
      new_in = if block == @cfg.entry
        @block_in[@cfg.entry.id]
      else
        join_predecessors(block)
      end
      @block_in[block.id] = new_in

      # Transfer: apply each statement in the block.
      new_out = apply_transfer(block, dup_state(new_in))

      # If exit state changed, schedule successors.
      unless new_out == @block_out[block.id]
        @block_out[block.id] = new_out
        block.successors.each do |succ|
          unless in_worklist[succ.id]
            worklist << succ
            in_worklist[succ.id] = true
          end
        end
      end
    end

    self
  end

  # Ownership state at function exit (join of all paths reaching exit_block).
  def exit_states
    @block_in[@cfg.exit_block.id] || {}
  end

  # Per-variable summary: { name => { needs_cleanup: bool, has_moved_guard: bool } }
  def cleanup_summary
    summary = {}
    exit_states.each do |name, state|
      case state
      when OWNED
        summary[name] = { needs_cleanup: true, has_moved_guard: false }
      when MAYBE_MOVED
        summary[name] = { needs_cleanup: true, has_moved_guard: true }
      when MOVED
        summary[name] = { needs_cleanup: false, has_moved_guard: false }
      end
    end
    summary
  end

  # Build CFG + run dataflow for a function node. Returns the analysis.
  # @param can_fail_fns [Set<String>, nil] names of functions that can fail
  def self.analyze(fn_node, can_fail_fns: nil)
    cfg = FunctionCFG.build(fn_node, can_fail_fns: can_fail_fns)
    new(cfg, fn_node).analyze!
  end

  private

  # TAKES params start as :owned (callee must clean them up).
  def init_entry_state
    state = {}
    (@fn_node.deferred_drops || []).each do |dd|
      name = dd.is_a?(Hash) ? dd[:name].to_s : dd.to_s
      param_def = @fn_node.params&.find { |p| p[:name] == name }
      state[name] = OWNED if param_def&.dig(:takes)
    end
    state
  end

  # Merge predecessor exit states. Variables present on any path are joined.
  def join_predecessors(block)
    preds = block.predecessors
    return {} if preds.empty?

    result = dup_state(@block_out[preds.first.id])
    preds[1..].each do |pred|
      pred_out = @block_out[pred.id]
      all_vars = (result.keys | pred_out.keys)
      merged = {}
      all_vars.each do |var|
        a = result[var] || UNINIT
        b = pred_out[var] || UNINIT
        merged[var] = join_state(a, b)
      end
      result = merged
    end
    result
  end

  def join_state(a, b)
    return b if a == UNINIT
    return a if b == UNINIT
    return a if a == b
    MAYBE_MOVED
  end

  # Process all statements in a block, updating the state map.
  def apply_transfer(block, state)
    block.stmts.each do |stmt|
      transfer_stmt(stmt, state)
    end
    state
  end

  # Transfer function for a single statement.
  def transfer_stmt(stmt, state)
    case stmt
    when AST::VarDecl
      # RHS of declaration: non-Copy identifier = ownership transfer.
      collect_binding_moves(stmt.value, state).each { |n| state[n] = MOVED }
      state[stmt.name.to_s] = OWNED

    when AST::BindExpr
      collect_binding_moves(stmt.value, state).each { |n| state[n] = MOVED }
      state[stmt.name.to_s] = OWNED if stmt.mode == :decl

    when AST::Assignment
      collect_binding_moves(stmt.value, state).each { |n| state[n] = MOVED }

    when AST::ReturnNode
      collect_binding_moves(stmt.value, state).each { |n| state[n] = MOVED }

    when AST::MoveNode
      # Standalone GIVE statement: GIVE f;
      inner = stmt.value
      if inner.is_a?(AST::Identifier)
        name = inner.name.to_s
        state[name] = MOVED if state[name]
      end

    when AST::FuncCall, AST::MethodCall
      # Function args: only was_moved (TAKES/GIVE) triggers a move.
      collect_explicit_moves(stmt, state).each { |n| state[n] = MOVED }

    when AST::IfStatement, AST::WhileLoop, AST::ForRange, AST::ForEach, AST::MatchStatement
      # Control flow headers: only process condition/expr for explicit moves.
      cond = case stmt
             when AST::IfStatement then stmt.condition
             when AST::WhileLoop then stmt.condition
             when AST::MatchStatement then stmt.expr
             when AST::ForRange then nil
             when AST::ForEach then stmt.collection
             end
      collect_explicit_moves(cond, state).each { |n| state[n] = MOVED } if cond

      # ForEach/ForRange: loop variable is owned in the body block.
      if stmt.is_a?(AST::ForRange) || stmt.is_a?(AST::ForEach)
        state[stmt.var_name.to_s] = OWNED
      end
    end
  end

  # Collect identifiers moved by a binding RHS (VarDecl, BindExpr, Assignment, Return).
  # Both explicit (was_moved) and implicit (non-Copy identifier = ownership transfer).
  #
  # Ownership-transferring positions (non-Copy = move):
  #   - Direct RHS identifier: b = a
  #   - Struct literal field value: S{ field: a }
  #   - Union constructor payload: U.Variant(a)
  #   - List literal items: [a, b]
  #   - MoveNode: MOVE a
  # All other positions: only was_moved (set by annotator for TAKES/GIVE).
  def collect_binding_moves(node, state)
    return [] unless node
    consumed = Set.new
    collect_ownership_transfers(node, state, consumed)
    consumed.to_a
  end

  # Recursively find ownership-transferring identifiers.
  def collect_ownership_transfers(node, state, consumed)
    return unless node

    case node
    when AST::Identifier
      name = node.name.to_s
      return unless state[name]
      return if copy_type?(node) # Copy types are never consumed
      consumed << name

    when AST::StructLit
      node.fields&.each_value { |v| collect_ownership_transfers(v, state, consumed) }

    when AST::MethodCall
      # Union constructors: U.Variant(payload) - payload transfers ownership.
      # Regular method calls in binding RHS: only was_moved args.
      if node.object.is_a?(AST::Identifier)
        node.args&.each { |a| collect_ownership_transfers(a, state, consumed) }
      else
        collect_explicit_in(node, state, consumed)
      end

    when AST::FuncCall
      collect_explicit_in(node, state, consumed)

    when AST::ListLit
      node.items&.each { |i| collect_ownership_transfers(i, state, consumed) }

    when AST::MoveNode
      inner = node.value
      if inner.is_a?(AST::Identifier)
        name = inner.name.to_s
        consumed << name if state[name]
      end

    when AST::CopyNode
      # COPY does NOT move the source.

    else
      collect_explicit_in(node, state, consumed)
    end
  end

  # Collect only was_moved identifiers from an expression subtree.
  def collect_explicit_in(node, state, consumed)
    walk_expr(node) do |n|
      next unless n.is_a?(AST::Identifier) && n.was_moved
      name = n.name.to_s
      next unless state[name]
      next if copy_type?(n)
      consumed << name
    end
  end

  # Collect only explicitly moved identifiers (was_moved set by annotator).
  # Used for function calls where non-TAKES args are borrowed, not moved.
  def collect_explicit_moves(node, state)
    return [] unless node
    consumed = []
    walk_expr(node) do |n|
      next unless n.is_a?(AST::Identifier) && n.was_moved
      name = n.name.to_s
      next unless state[name]
      next if copy_type?(n)
      consumed << name
    end
    consumed
  end

  # Returns true if this identifier's type is Copy (no move on assignment).
  # Primitives, strings, enums, :Any, and RC types are Copy-like.
  # RC assignment is clone (rcRetain), not move. Only GIVE/MOVE transfers
  # ownership (handled by was_moved from the annotator).
  def copy_type?(ident)
    ti = ident.type_info rescue nil
    return true unless ti  # unknown type, assume Copy (safe)
    ti = Type.new(ti) if !ti.is_a?(Type)
    ti.primitive? || ti.string? || ti.any? || ti.void? || (ti.any_rc? rescue false)
  end

  # Returns true if this identifier's type is non-Copy (move semantics).
  def non_copy_type?(ident)
    !copy_type?(ident)
  end

  def walk_expr(node, &block)
    return unless node
    yield node
    case node
    when AST::BinaryOp
      walk_expr(node.left, &block)
      walk_expr(node.right, &block)
    when AST::UnaryOp
      walk_expr(node.right, &block)
    when AST::FuncCall
      node.args&.each { |a| walk_expr(a, &block) }
    when AST::MethodCall
      walk_expr(node.object, &block)
      node.args&.each { |a| walk_expr(a, &block) }
    when AST::GetField
      walk_expr(node.target, &block)
    when AST::GetIndex
      walk_expr(node.target, &block)
      walk_expr(node.index, &block)
    when AST::StructLit
      node.fields&.each_value { |v| walk_expr(v, &block) }
    when AST::ListLit
      node.items&.each { |i| walk_expr(i, &block) }
    when AST::HashLit
      node.pairs&.each { |_k, v| walk_expr(v.is_a?(Array) ? v[1] : v, &block) }
    when AST::CopyNode
      walk_expr(node.value, &block)
    when AST::MoveNode
      walk_expr(node.value, &block)
    when AST::ReturnNode
      walk_expr(node.value, &block)
    when AST::Assignment
      walk_expr(node.value, &block)
    when AST::VarDecl, AST::BindExpr
      walk_expr(node.value, &block)
    end
  end

  def dup_state(state)
    state.dup
  end
end

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
  # existing classify_binding + MIR::Drop infrastructure handles their cleanup.
  # PromotionClassifier must run before cleanup classification because its Phase 0
  # (scan_for_hpt_downgrade) clears heap provenance on return sub-expressions
  # that the classifier depends on.
  def transform!(ast)
    # Phase 0: hoist HPT sub-expression FuncCalls into VarDecl nodes.
    @fn_nodes.each do |_name, fn|
      hoist_heap_temps!(fn) if fn.body
    end

    promotion_plans = {}

    # Phase 1: classify promotions for all functions (triggers HPT downgrade).
    @fn_nodes.each do |name, fn|
      promotion_plans[name] = PromotionClassifier.classify(fn, schema_lookup: @schema_lookup)
    end

    # Phase 2: classify cleanup bindings (uses cleared provenance from Phase 1).
    @fn_nodes.each do |name, fn|
      @cleanup_bindings[name] = CleanupClassifier.classify(fn, fn_nodes: @fn_nodes, schema_lookup: @schema_lookup)
    end

    # Phase 3: insert MIR nodes + stamp AST.
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      transform_function!(stmt, promotion_plans[stmt.name])
    end

    # Phase 4: static leak verification on post-MIR bodies.
    can_fail_fns = Set.new
    @fn_nodes.each { |name, f| can_fail_fns << name if f.can_fail }

    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      bindings = @cleanup_bindings[stmt.name]
      next unless bindings && !bindings.empty?

      checker = StaticLeakChecker.new(stmt, bindings: bindings, can_fail_fns: can_fail_fns)
      errors = checker.check!
      unless errors.empty?
        raise "Your code is correct. This is a compiler error. Sorry for the inconvenience.\n\n#{errors.join("\n")}"
      end
    end
  end

  private

  def transform_function!(fn, promo)
    bindings = @cleanup_bindings[fn.name]
    has_bindings = bindings && !bindings.empty?
    promo = nil if promo&.empty?

    fn.has_promotion = true if promo

    return unless has_bindings || promo

    # Use dataflow analysis to tighten has_moved_guard decisions.
    # The classifier conservatively sets has_moved_guard=true for all non-trivial
    # types. Dataflow precisely tracks which variables are actually consumed on
    # some paths, so we can remove unnecessary guards.
    refine_moved_guards!(fn, bindings) if has_bindings

    # Stamp field pre-cleanup info directly on Assignment nodes.
    CleanupClassifier.stamp_field_pre_cleanups!(fn.body, bindings, schema_lookup: @schema_lookup) if has_bindings

    fn.body = transform_body(fn.body, bindings, promo)

    # Insert MIR::Drop nodes for TAKES parameters at function body start.
    insert_takes_drops!(fn, bindings) if has_bindings

    # Build moved_guard_info map: { var_name => bool } for all bindings.
    stamp_moved_guard_info!(fn, bindings) if has_bindings
  end

  # Tighten cleanup decisions using ownership dataflow analysis.
  #
  # Two refinements:
  #   1. Remove unnecessary moved guards: variable is never moved on any path
  #      → unconditional cleanup, no guard needed.
  #   2. Eliminate cleanup entirely: variable is moved on ALL paths (including
  #      error unwind) → no defer needed at all.
  #
  # Error edges in the CFG ensure that (2) is safe: if a can_fail call exists
  # between declaration and GIVE, the dataflow sees MAYBE_MOVED (not MOVED)
  # and keeps the cleanup.
  def refine_moved_guards!(fn, bindings)
    # Compute which functions can fail for error-edge modeling.
    can_fail_fns = Set.new
    @fn_nodes.each { |name, f| can_fail_fns << name if f.can_fail }

    df = OwnershipDataflow.analyze(fn, can_fail_fns: can_fail_fns)
    summary = df.cleanup_summary

    bindings.each do |var, entry|
      next unless entry[:needs_cleanup]
      df_entry = summary[var]
      next unless df_entry # variable not tracked by dataflow - keep plan

      if !df_entry[:needs_cleanup]
        # Moved on ALL paths (including error edges) → normally no cleanup needed.
        if entry[:kind] == :takes_union
          # Exception: MATCH TAKES on unions may extract Copy-type payloads
          # (strings) where extraction copies the slice header but doesn't
          # consume the underlying buffer. The source defer must stay with a
          # guard so branches that extract non-Copy variants can suppress it.
          entry[:has_moved_guard] = true
        else
          entry[:needs_cleanup] = false
          entry[:has_moved_guard] = false
        end
      elsif !df_entry[:has_moved_guard] && entry[:has_moved_guard]
        # Never moved on any path → unconditional cleanup, no guard needed.
        entry[:has_moved_guard] = false
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
        insert_return!(result, stmt, bindings)
        insert_promotion!(result, stmt, promo)
      end

      # Stamp cleanup info on reassignment / match-as / map-put nodes.
      stamp_reassign_cleanup!(stmt, bindings)
      stamp_match_as_cleanup!(stmt, bindings)
      stamp_map_value_promote!(stmt)
      stamp_map_put_alloc!(stmt)

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

      # Insert Drop after VarDecl / BindExpr (decl mode).
      insert_drop!(result, stmt, bindings)

      # Insert SuppressCleanup after statements that consume bindings.
      insert_suppress_cleanup!(result, stmt, bindings)
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
      stmt.body = transform_body(stmt.body, bindings, promo) if stmt.body
    end
  end

  # Insert a MIR::Drop after a variable declaration that needs cleanup.
  # Also stamps the declaration with cleanup_alloc and has_cleanup.
  def insert_drop!(result, stmt, bindings)
    return unless bindings
    name = case stmt
           when AST::VarDecl then stmt.name.to_s
           when AST::BindExpr then stmt.mode == :decl ? stmt.name.to_s : nil
           else nil
           end
    return unless name

    entry = bindings[name]
    return unless entry && entry[:needs_cleanup]

    # Stamp declaration with cleanup info for transpiler.
    if stmt.is_a?(AST::VarDecl) || (stmt.is_a?(AST::BindExpr) && stmt.mode == :decl)
      stmt.cleanup_alloc = entry[:alloc]
      stmt.has_cleanup = true
    end

    # Pre-compute Zig type strings into the entry so the transpiler is
    # purely mechanical (no type resolution at emit time).
    drop_entry = entry.dup
    compute_drop_type_strings!(drop_entry, stmt.type_info, stmt)

    # MIR::Alloc: explicit allocation marker for static leak checker.
    result << MIR::Alloc.new(stmt.token, name, entry[:kind], entry[:alloc])

    drop = MIR::Drop.new(
      stmt.token, name, entry[:kind], entry[:alloc],
      entry[:has_moved_guard], nil, entry[:resource_close_zig],
      nil
    )
    drop.cleanup_entry = drop_entry
    result << drop
  end

  # Insert MIR::Alloc + MIR::Drop nodes for TAKES parameters at the start
  # of the function body.
  def insert_takes_drops!(fn, bindings)
    mir_nodes = []
    (fn.deferred_drops || []).each do |dd|
      param_def = fn.params&.find { |p| p[:name] == dd[:name] }
      next unless param_def&.dig(:takes)

      entry = bindings[dd[:name].to_s]
      next unless entry && entry[:needs_cleanup]

      ti = dd[:type].is_a?(Type) ? dd[:type] : Type.new(dd[:type] || :Any)

      drop_entry = entry.dup
      compute_drop_type_strings!(drop_entry, ti, nil)

      mir_nodes << MIR::Alloc.new(fn.token, dd[:name].to_s, entry[:kind], entry[:alloc])

      drop = MIR::Drop.new(
        fn.token, dd[:name].to_s, entry[:kind], entry[:alloc],
        entry[:has_moved_guard], nil, entry[:resource_close_zig], nil
      )
      drop.cleanup_entry = drop_entry
      mir_nodes << drop
    end
    fn.body = mir_nodes + fn.body if mir_nodes.any?
  end

  # Pre-compute zig_type, elem_zig_type, is_fixed into the cleanup entry.
  # This moves all type resolution out of the transpiler -- build_drop_entry
  # is eliminated and the transpiler just reads cleanup_entry directly.
  def compute_drop_type_strings!(entry, ti, source_node)
    ti = Type.new(ti) if ti && !ti.is_a?(Type)

    zig_type = case entry[:kind]
    when :heap_slice
      is_bare = source_node.respond_to?(:value) && source_node.value.is_a?(AST::CopyNode) && !ti&.list_collection?
      if is_bare
        elem = ti&.element_type ? Type.new(ti.element_type).zig_type : "UNKNOWN"
        "[]#{elem}"
      else
        ti&.zig_type
      end
    when :list, :list_with_elem_cleanup, :string_map, :numeric_map, :set
      ti&.zig_type
    when :heap_union, :heap_struct, :locked, :write_locked,
         :struct_with_cleanup_fields, :struct_rc, :non_copy_union, :takes_union
      Type.new((ti&.resolved || :Any).to_s).zig_type
    when :rc
      ti&.zig_type
    end

    elem_zig = case entry[:kind]
    when :list_with_elem_cleanup, :takes_slice
      et = ti&.element_type
      if et
        t = et.is_a?(Type) ? et : Type.new(et)
        Type.new(t.resolved.to_s).zig_type
      end
    when :array_with_struct_strings
      ti&.element_type ? Type.new(ti.element_type).zig_type : nil
    end

    entry[:zig_type] = zig_type || entry[:zig_type] || "UNKNOWN"
    entry[:elem_zig_type] = elem_zig || entry[:elem_zig_type]
    entry[:is_fixed] = ti&.fixed? if entry[:kind] == :array_with_struct_strings
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

  # Collect names of bindings consumed by a statement.
  # Two consumption paths:
  #   1. Direct RHS: identifier used as value in assignment/declaration
  #   2. Nested: identifier passed as TAKES/GIVE arg or used as struct field
  def collect_consumed_names(stmt, bindings)
    names = Set.new

    # 1. Direct RHS consumption
    rhs = case stmt
          when AST::VarDecl    then stmt.value
          when AST::BindExpr   then stmt.value
          when AST::Assignment then stmt.value
          else nil
          end

    if rhs
      is_move = rhs.is_a?(AST::MoveNode)
      ident = is_move ? rhs.value : rhs
      add_if_consumed(ident, names, bindings, is_move) if ident.is_a?(AST::Identifier)
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
    return if ti&.escaped_return && (ti.collection? || ti.string?)

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

  # Stamp map_value_promote on Assignment nodes where a struct value with
  # list fields is stored into a HashMap. The list backing must be promoted
  # from frame to heap before the put.
  def stamp_map_value_promote!(stmt)
    return unless stmt.is_a?(AST::Assignment)
    return unless stmt.name.is_a?(AST::GetIndex)
    target_node = stmt.name.target
    return unless target_node.respond_to?(:metatype) && target_node.metatype == :hashmap

    val_ti = stmt.value.type_info rescue nil
    return unless val_ti
    val_ti = Type.new(val_ti) if val_ti && !val_ti.is_a?(Type)
    val_type_sym = val_ti.respond_to?(:resolved) ? val_ti.resolved : nil
    return unless val_type_sym

    schema = @schema_lookup.call(val_type_sym) rescue nil
    return unless schema.is_a?(Hash) && !schema[:kind]

    promote_fields = schema.filter_map do |k, v|
      next if k.is_a?(Symbol)
      ft = v.is_a?(Hash) ? Type.new(v[:type] || :Any) : Type.new(v || :Any)
      next unless ft.list_collection?
      { field: k.to_s, elem_zig: Type.new(ft.element_type).zig_type }
    end
    return if promote_fields.empty?

    stmt.map_value_promote = {
      zig_type: val_ti.zig_type,
      promote_fields: promote_fields
    }
  end

  # Stamp map_put_alloc on Assignment nodes that store into a HashMap.
  # Pre-computes allocator decisions so the transpiler is mechanical.
  #   key_alloc: :heap (StringMap owns key memory) or :frame (numeric maps)
  #   val_alloc: :heap (sharded/striped) or :frame (frame-local maps)
  def stamp_map_put_alloc!(stmt)
    return unless stmt.is_a?(AST::Assignment)
    return unless stmt.name.is_a?(AST::GetIndex)
    target_node = stmt.name.target
    return unless target_node.respond_to?(:metatype) && target_node.metatype == :hashmap

    map_ft = target_node.full_type
    map_ft = Type.new(map_ft) if map_ft && !map_ft.is_a?(Type)
    return unless map_ft

    if map_ft.numeric_map?
      alloc = (map_ft.escaped_return || map_ft.heap_provenance? || map_ft.sharded? || map_ft.striped?) ? :heap : :frame
      stmt.map_put_alloc = { key_alloc: alloc, val_alloc: alloc }
    else
      val_alloc = (map_ft.sharded? || map_ft.striped?) ? :heap : :frame
      stmt.map_put_alloc = { key_alloc: :heap, val_alloc: val_alloc }
    end
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

    # Struct-level promotion: annotate ReturnNode so transpiler wraps with __ret.
    if filtered[:struct_promote] && PromotionClassifier.needs_promote?(filtered, ret_node)
      ret_node.promote_ret_wrap = :var
      ret_node.promote_fields_info = {
        zig_type: filtered[:struct_promote],
        fields: filtered[:unhandled_promote_fields]
      }
    elsif filtered[:var_promotes]&.any?
      ret_node.promote_ret_wrap = :const
    end
  end

  # Insert MIR::Return before a ReturnNode to mark which local variables'
  # ownership escapes to the caller. The checker uses this to know that
  # escaped vars don't need local cleanup.
  def insert_return!(result, ret_node, bindings)
    return unless bindings
    escaped = collect_return_escapes(ret_node, bindings)
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
  def collect_return_escapes(ret_node, bindings)
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
    when AST::CopyNode then []
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

  # ── Phase 0: HPT hoisting ──────────────────────────────────────────
  #
  # Walks the function body looking for sub-expression FuncCall/MethodCall
  # nodes with heap_provenance that aren't bind values, moved, or direct
  # returns. Hoists each into a VarDecl before the containing statement
  # and replaces the original call with an Identifier referencing the temp.
  #
  # After hoisting, classify_binding + MIR::Drop handle cleanup automatically.
  # For return statements where the return value borrows from an HPT, the
  # ReturnNode is annotated with hpt_return_handling.

  def hoist_heap_temps!(fn)
    @hpt_counter = 0
    fn.body = hoist_in_body(fn.body)
  end

  # Process a statement list, returning a new array with hoisted VarDecls
  # inserted before the statements that used to contain the HPT calls.
  def hoist_in_body(stmts)
    return stmts unless stmts.is_a?(Array)
    result = []
    stmts.each do |stmt|
      # Recurse into nested control flow first.
      hoist_in_branches!(stmt)

      hoisted = []  # VarDecls to insert before this statement
      case stmt
      when AST::VarDecl, AST::BindExpr
        next result << stmt if stmt.is_a?(AST::BindExpr) && stmt.mode == :assign
        val = stmt.value
        if val.is_a?(AST::BinaryOp) && val.op == :OR_RESCUE
          # Left side is the bind value; right side may have HPTs.
          stmt.value.right = hoist_hpt_in_expr(val.right, stmt, hoisted, is_bind_value: false)
        else
          # The top-level value is the bind value. Scan sub-expressions only.
          stmt.value = hoist_hpt_in_expr(val, stmt, hoisted, is_bind_value: true)
        end
      when AST::ReturnNode
        if stmt.value
          stmt.value = hoist_hpt_in_expr(stmt.value, stmt, hoisted, is_bind_value: false)
        end
      when AST::Assignment
        stmt.value = hoist_hpt_in_expr(stmt.value, stmt, hoisted, is_bind_value: true)
      when AST::FuncCall, AST::MethodCall
        # Standalone expression statement (e.g., print(makeVal!()))
        replaced = hoist_hpt_in_expr(stmt, stmt, hoisted, is_bind_value: false)
        stmt = replaced if replaced != stmt  # top-level call itself was hoisted (unlikely but possible)
      end

      result.concat(hoisted)
      result << stmt
    end
    result
  end

  # Recurse into control flow branches for HPT hoisting.
  def hoist_in_branches!(stmt)
    case stmt
    when AST::IfStatement
      stmt.then_branch = hoist_in_body(stmt.then_branch) if stmt.then_branch
      stmt.else_branch = hoist_in_body(stmt.else_branch) if stmt.else_branch
    when AST::WhileLoop
      stmt.do_branch = hoist_in_body(stmt.do_branch) if stmt.do_branch
    when AST::ForRange, AST::ForEach
      stmt.body = hoist_in_body(stmt.body) if stmt.body
    when AST::MatchStatement
      stmt.cases&.each { |c| c[:body] = hoist_in_body(c[:body]) if c[:body] }
      stmt.default_case = hoist_in_body(stmt.default_case) if stmt.default_case
    when AST::WithBlock
      stmt.body = hoist_in_body(stmt.body) if stmt.body
    when AST::DoBlock
      stmt.branches&.each { |b| b[:body] = hoist_in_body(b[:body]) if b[:body] }
    when AST::BgBlock, AST::BgStreamBlock
      stmt.body = hoist_in_body(stmt.body) if stmt.body
    end
  end

  # Walk an expression tree, replacing HPT FuncCalls with Identifier
  # references to hoisted VarDecls. Returns the (possibly replaced) node.
  def hoist_hpt_in_expr(node, stmt_node, hoisted, is_bind_value:, inside_move: false)
    return node unless node

    case node
    when AST::FuncCall, AST::MethodCall
      ti = node.type_info rescue nil
      ti = ti.is_a?(Type) ? ti : nil
      if ti&.heap_provenance? && !is_bind_value && !node.was_moved && !inside_move
        # Direct return: ownership transfers to caller, no HPT needed.
        is_direct_return = stmt_node.is_a?(AST::ReturnNode) && stmt_node.value.equal?(node)
        unless is_direct_return
          # Recurse into args first (nested HPTs get hoisted first).
          hoist_call_children!(node, stmt_node, hoisted)

          # Create the hoisted VarDecl + replacement Identifier.
          ident = create_hpt_vardecl(node, stmt_node, hoisted)
          return ident
        end
      end
      # Not an HPT - recurse into children.
      hoist_call_children!(node, stmt_node, hoisted)
      node

    when AST::MoveNode
      node.value = hoist_hpt_in_expr(node.value, stmt_node, hoisted,
                                     is_bind_value: is_bind_value, inside_move: true)
      node
    when AST::BinaryOp
      node.left = hoist_hpt_in_expr(node.left, stmt_node, hoisted,
                                    is_bind_value: false)
      node.right = hoist_hpt_in_expr(node.right, stmt_node, hoisted,
                                     is_bind_value: false)
      node
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each do |k, v|
        node.fields[k] = hoist_hpt_in_expr(v, stmt_node, hoisted,
                                           is_bind_value: is_bind_value)
      end
      node
    when AST::ListLit
      node.items.map! { |v|
        hoist_hpt_in_expr(v, stmt_node, hoisted, is_bind_value: is_bind_value)
      }
      node
    when AST::GetField
      node.target = hoist_hpt_in_expr(node.target, stmt_node, hoisted,
                                      is_bind_value: false)
      node
    when AST::GetIndex
      node.target = hoist_hpt_in_expr(node.target, stmt_node, hoisted,
                                      is_bind_value: false)
      node.index = hoist_hpt_in_expr(node.index, stmt_node, hoisted,
                                     is_bind_value: false)
      node
    when AST::UnaryOp
      node.right = hoist_hpt_in_expr(node.right, stmt_node, hoisted,
                                     is_bind_value: false)
      node
    when AST::Cast
      node.value = hoist_hpt_in_expr(node.value, stmt_node, hoisted,
                                     is_bind_value: false)
      node
    when AST::CopyNode
      node.value = hoist_hpt_in_expr(node.value, stmt_node, hoisted,
                                     is_bind_value: false)
      node
    else
      node
    end
  end

  # Recurse into FuncCall/MethodCall children (args + object).
  def hoist_call_children!(node, stmt_node, hoisted)
    node.args.map! { |arg|
      hoist_hpt_in_expr(arg, stmt_node, hoisted, is_bind_value: false)
    }
    if node.is_a?(AST::MethodCall)
      node.object = hoist_hpt_in_expr(node.object, stmt_node, hoisted,
                                      is_bind_value: false)
    end
  end

  # Create a VarDecl for an HPT FuncCall, add it to hoisted list,
  # and return an Identifier node that references the temp variable.
  # Also detects return_handling and annotates the ReturnNode if needed.
  def create_hpt_vardecl(call_node, stmt_node, hoisted)
    @hpt_counter += 1
    tmp_name = "__hpt_#{@hpt_counter}"

    ti = call_node.type_info
    classify_ti = (ti.error_union? && ti.payload_type) ? ti.payload_type : ti

    # Detect return_handling: return value may borrow from this HPT's heap data.
    if stmt_node.is_a?(AST::ReturnNode)
      ret_ti = stmt_node.value&.type_info rescue nil
      ret_ti = ret_ti.is_a?(Type) ? ret_ti : nil
      if ret_ti&.string?
        stmt_node.hpt_return_handling = :dupe_string
      elsif ret_ti
        resolved = ret_ti.resolved
        ret_schema = @schema_lookup.call(resolved) rescue nil
        needs_promo = if ret_schema.is_a?(Hash) && ret_schema[:kind] == :union
          (ret_schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        elsif ret_schema.is_a?(Hash) && !ret_schema[:kind]
          ret_schema.any? do |k, v|
            next false if k.is_a?(Symbol)
            ft = v.is_a?(Type) ? v : Type.new(v.is_a?(Hash) ? (v[:type] || :Any) : (v || :Any))
            ft.needs_escape_promotion?
          end
        else
          false
        end
        if needs_promo
          stmt_node.hpt_return_handling = :promote_return
          stmt_node.hpt_return_type = Type.new(resolved).zig_type
        end
      end
    end

    # Build VarDecl node.
    vardecl = AST::VarDecl.new(call_node.token, tmp_name, nil, call_node, false)
    # Transfer type info so classify_binding sees it.
    vardecl.full_type = ti
    vardecl.storage = call_node.respond_to?(:storage) ? call_node.storage : nil
    # Mark as HPT-hoisted so the transpiler can emit the correct type annotation.
    vardecl.hpt_hoisted = true
    hoisted << vardecl

    # Build replacement Identifier.
    ident = AST::Identifier.new(call_node.token, tmp_name)
    ident.full_type = ti
    ident.storage = call_node.respond_to?(:storage) ? call_node.storage : nil
    ident
  end
end
