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

      when AST::WithBlock
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block
        current_block.add_successor(body_block)
        current_block.add_successor(after_block)  # WITH can fail to acquire
        body_exit = build_body(stmt.body || [], body_block, exit_target, cfg)
        body_exit&.add_successor(after_block) if body_exit
        current_block = after_block

      when AST::DoBlock
        current_block.stmts << stmt
        join_block = cfg.new_block
        (stmt.branches || []).each do |b|
          branch_block = cfg.new_block
          current_block.add_successor(branch_block)
          branch_exit = build_body(b[:body] || [], branch_block, exit_target, cfg)
          branch_exit&.add_successor(join_block) if branch_exit
        end
        current_block.add_successor(join_block)  # fallthrough if no branches
        current_block = join_block

      when AST::BgBlock, AST::BgStreamBlock
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block
        current_block.add_successor(body_block)
        current_block.add_successor(after_block)
        build_body(stmt.body || [], body_block, exit_target, cfg)
        # BG body runs in separate fiber -- no fall-through back to parent
        current_block = after_block

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

  # Enriched ownership entry: carries allocator and cleanup info alongside state.
  # Equality is based on :state only (for fixpoint convergence -- allocator and
  # needs_cleanup are immutable properties set at declaration, never change).
  OwnerEntry = Struct.new(:state, :allocator, :needs_cleanup, keyword_init: true) do
    def ==(other)
      case other
      when OwnerEntry then state == other.state
      when Symbol     then state == other  # backward compat with raw symbols
      else false
      end
    end
    alias_method :eql?, :==

    def hash
      state.hash
    end
  end

  attr_reader :block_in, :block_out, :point_states

  def initialize(cfg, fn_node, schema_lookup: nil)
    @cfg = cfg
    @fn_node = fn_node
    @schema_lookup = schema_lookup
    @block_in  = {}  # block.id => { var_name => OwnerEntry }
    @block_out = {}  # block.id => { var_name => OwnerEntry }
    @point_states = {} # [block.id, stmt_index] => { var_name => OwnerEntry }
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
  # Backward-compatible: reads .state from OwnerEntry.
  def cleanup_summary
    summary = {}
    exit_states.each do |name, entry|
      st = entry.is_a?(OwnerEntry) ? entry.state : entry
      case st
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

  # Refine CleanupClassifier bindings using ownership state at scope exit.
  #
  # Determines WHETHER cleanup is needed and WHETHER a moved guard is required
  # for each binding, based on ownership dataflow analysis.
  #
  # Also runs UseAfterMoveChecker (Rule 1).
  #
  # Three refinements:
  #   1. Remove unnecessary moved guards: variable is never moved on any path
  #      -> unconditional cleanup, no guard.
  #   2. Eliminate cleanup entirely: variable is moved on ALL paths (including
  #      error unwind) -> no defer needed.
  #   3. Exception: MATCH TAKES unions that are moved on all paths still need
  #      a guard because non-AS branches don't extract ownership.
  def cleanup_decisions!(fn_node, bindings)
    summary = cleanup_summary

    # Rule 1: Use-after-move check.
    checker = UseAfterMoveChecker.new(fn_node, self)
    checker.check!
    unless checker.errors.empty?
      raise "[Ownership Error] #{checker.errors.first}"
    end

    bindings.each do |var, entry|
      next unless entry[:needs_cleanup]
      df_entry = summary[var]
      next unless df_entry # variable not tracked by dataflow - keep plan

      if !df_entry[:needs_cleanup]
        # Moved on ALL paths -> normally no cleanup needed.
        # Exception: MATCH TAKES unions need the defer with a moved guard.
        if entry[:kind] == :takes_union || match_takes_var?(fn_node, var)
          entry[:has_moved_guard] = true
        else
          entry[:needs_cleanup] = false
          entry[:has_moved_guard] = false
        end
      elsif !df_entry[:has_moved_guard] && entry[:has_moved_guard]
        # Never moved on any path -> unconditional cleanup, no guard.
        entry[:has_moved_guard] = false
      end
    end
  end

  private

  # Returns true if the given variable is the subject of a MATCH TAKES statement.
  def match_takes_var?(fn_node, var_name)
    found = false
    AST.walk_body(fn_node.body) do |stmt|
      if stmt.is_a?(AST::MatchStatement) && stmt.takes &&
         stmt.expr.is_a?(AST::Identifier) && stmt.expr.name.to_s == var_name
        found = true
      end
    end
    found
  end

  # Build CFG + run dataflow for a function node. Returns the analysis.
  # @param can_fail_fns [Set<String>, nil] names of functions that can fail
  # @param schema_lookup [Proc, nil] type schema resolver for needs_explicit_cleanup
  def self.analyze(fn_node, can_fail_fns: nil, schema_lookup: nil)
    cfg = FunctionCFG.build(fn_node, can_fail_fns: can_fail_fns)
    new(cfg, fn_node, schema_lookup: schema_lookup).analyze!
  end

  private

  # TAKES params start as :owned (callee must clean them up).
  # TAKES params are always heap-allocated (caller passes heap ownership).
  def init_entry_state
    state = {}
    (@fn_node.deferred_drops || []).each do |dd|
      name = dd.is_a?(Hash) ? dd[:name].to_s : dd.to_s
      param_def = @fn_node.params&.find { |p| p[:name] == name }
      if param_def&.dig(:takes)
        ti = dd.is_a?(Hash) ? dd[:type] : nil
        ti = ti.is_a?(Type) ? ti : (Type.new(ti || :Any) rescue nil)
        needs = ti ? ti.needs_explicit_cleanup?(:heap, @schema_lookup) : true
        state[name] = OwnerEntry.new(state: OWNED, allocator: :heap, needs_cleanup: needs)
      end
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
        a = result[var]
        b = pred_out[var]
        merged[var] = join_entry(a, b)
      end
      result = merged
    end
    result
  end

  # Join two OwnerEntry values (or nil for absent variables).
  def join_entry(a, b)
    return b if a.nil?
    return a if b.nil?

    a_st = a.is_a?(OwnerEntry) ? a.state : a
    b_st = b.is_a?(OwnerEntry) ? b.state : b

    joined_state = join_state(a_st, b_st)

    # Preserve allocator/needs_cleanup from whichever side has them.
    # These are immutable per-variable properties, so both sides agree
    # (or one side is nil/UNINIT and has no entry).
    if a.is_a?(OwnerEntry)
      OwnerEntry.new(state: joined_state, allocator: a.allocator, needs_cleanup: a.needs_cleanup)
    elsif b.is_a?(OwnerEntry)
      OwnerEntry.new(state: joined_state, allocator: b.allocator, needs_cleanup: b.needs_cleanup)
    else
      joined_state
    end
  end

  def join_state(a, b)
    return b if a == UNINIT
    return a if b == UNINIT
    return a if a == b
    MAYBE_MOVED
  end

  # Process all statements in a block, updating the state map.
  # Stores per-statement snapshots in @point_states.
  def apply_transfer(block, state)
    block.stmts.each_with_index do |stmt, idx|
      transfer_stmt(stmt, state)
      @point_states[[block.id, idx]] = dup_state(state)
    end
    state
  end

  # Transition a variable to :moved, preserving OwnerEntry metadata.
  def mark_moved!(state, name)
    existing = state[name]
    if existing.is_a?(OwnerEntry)
      state[name] = OwnerEntry.new(state: MOVED, allocator: existing.allocator, needs_cleanup: existing.needs_cleanup)
    else
      state[name] = MOVED
    end
  end

  # Create an OwnerEntry for a new declaration from its type info.
  def make_owner_entry(node)
    ti = node.type_info rescue nil
    ti = Type.new(ti) if ti && !ti.is_a?(Type)

    allocator = if ti
      prov = ti.provenance_alloc rescue nil
      prov || (ti.heap_provenance? ? :heap : :frame)
    else
      :frame
    end

    needs = if ti
      ti.needs_explicit_cleanup?(allocator, @schema_lookup) rescue false
    else
      false
    end

    OwnerEntry.new(state: OWNED, allocator: allocator, needs_cleanup: needs)
  end

  # Transfer function for a single statement.
  def transfer_stmt(stmt, state)
    case stmt
    when AST::VarDecl
      # RHS of declaration: non-Copy identifier = ownership transfer.
      collect_binding_moves(stmt.value, state).each { |n| mark_moved!(state, n) }
      state[stmt.name.to_s] = make_owner_entry(stmt)

    when AST::BindExpr
      collect_binding_moves(stmt.value, state).each { |n| mark_moved!(state, n) }
      state[stmt.name.to_s] = make_owner_entry(stmt) if stmt.mode == :decl

    when AST::Assignment
      collect_binding_moves(stmt.value, state).each { |n| mark_moved!(state, n) }

    when AST::ReturnNode
      collect_binding_moves(stmt.value, state).each { |n| mark_moved!(state, n) }

    when AST::MoveNode
      # Standalone GIVE statement: GIVE f;
      inner = stmt.value
      if inner.is_a?(AST::Identifier)
        name = inner.name.to_s
        mark_moved!(state, name) if state[name]
      end

    when AST::FuncCall, AST::MethodCall
      # Function args: only was_moved (TAKES/GIVE) triggers a move.
      collect_explicit_moves(stmt, state).each { |n| mark_moved!(state, n) }
      # BG blocks in args transfer ownership of captured resources.
      collect_bg_captures_in_args(stmt, state).each { |n| mark_moved!(state, n) }

    when AST::IfStatement, AST::WhileLoop, AST::ForRange, AST::ForEach, AST::MatchStatement
      # Control flow headers: only process condition/expr for explicit moves.
      cond = case stmt
             when AST::IfStatement then stmt.condition
             when AST::WhileLoop then stmt.condition
             when AST::MatchStatement then stmt.expr
             when AST::ForRange then nil
             when AST::ForEach then stmt.collection
             end
      collect_explicit_moves(cond, state).each { |n| mark_moved!(state, n) } if cond

      # ForEach/ForRange: loop variable is owned in the body block.
      if stmt.is_a?(AST::ForRange) || stmt.is_a?(AST::ForEach)
        state[stmt.var_name.to_s] = make_owner_entry(stmt)
      end

    when AST::WithBlock
      # WITH block capabilities borrow the source variable -- no ownership transfer.
      # The source variable remains OWNED (it's borrowed, not moved).

    when AST::DoBlock
      # DO block header -- no moves in the header itself.

    when AST::BgBlock, AST::BgStreamBlock
      # BG block: resource captures transfer ownership to the fiber.
      # String captures are promoted (borrowed), not moved.
      stmt.capture_analysis&.resource_captures&.each do |name|
        mark_moved!(state, name) if state[name]
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
      # Distinguish by token type: TYPE_ID = union constructor, VAR_ID = method call.
      if node.object.is_a?(AST::Identifier) && node.object.token&.type == :TYPE_ID
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

    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      collect_ownership_transfers(node.value, state, consumed)

    when AST::BgBlock, AST::BgStreamBlock
      # Resources captured by BG fibers transfer ownership.
      node.capture_analysis&.resource_captures&.each do |name|
        consumed << name if state[name]
      end

    else
      collect_explicit_in(node, state, consumed)
    end
  end

  # Collect only was_moved identifiers from an expression subtree.
  # Skips CopyNode children: COPY wraps a was_moved identifier but the
  # source is NOT consumed (the copy is what transfers ownership).
  def collect_explicit_in(node, state, consumed)
    walk_expr_skip_copy(node) do |n|
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
    walk_expr_skip_copy(node) do |n|
      next unless n.is_a?(AST::Identifier) && n.was_moved
      name = n.name.to_s
      next unless state[name]
      next if copy_type?(n)
      consumed << name
    end
    consumed
  end

  # Collect resource captures from BG blocks nested in function/method call args.
  # Without this, the dataflow doesn't see ownership transfers via BG capture
  # when the BG block appears inside a MethodCall like tasks.append(BG { ... }).
  def collect_bg_captures_in_args(stmt, state)
    consumed = []
    args = stmt.args || []
    args.each do |arg|
      _walk_bg_captures_in_expr(arg, state, consumed)
    end
    consumed
  end

  def _walk_bg_captures_in_expr(expr, state, consumed)
    return unless expr
    case expr
    when AST::BgBlock, AST::BgStreamBlock
      expr.capture_analysis&.resource_captures&.each do |name|
        consumed << name if state[name]
      end
    when AST::FuncCall
      expr.args&.each { |a| _walk_bg_captures_in_expr(a, state, consumed) }
    when AST::MethodCall
      _walk_bg_captures_in_expr(expr.object, state, consumed)
      expr.args&.each { |a| _walk_bg_captures_in_expr(a, state, consumed) }
    end
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
    when AST::CapabilityWrap
      walk_expr(node.value, &block)
    when AST::ReturnNode
      walk_expr(node.value, &block)
    when AST::Assignment
      walk_expr(node.value, &block)
    when AST::VarDecl, AST::BindExpr
      walk_expr(node.value, &block)
    end
  end

  # Like walk_expr but does NOT recurse into CopyNode. CopyNode wraps
  # was_moved identifiers for implicit copies -- the source is NOT consumed.
  def walk_expr_skip_copy(node, &block)
    return unless node
    yield node
    case node
    when AST::CopyNode
      # Do not recurse: COPY means the source is retained.
    when AST::BinaryOp
      walk_expr_skip_copy(node.left, &block)
      walk_expr_skip_copy(node.right, &block)
    when AST::UnaryOp
      walk_expr_skip_copy(node.right, &block)
    when AST::FuncCall
      node.args&.each { |a| walk_expr_skip_copy(a, &block) }
    when AST::MethodCall
      walk_expr_skip_copy(node.object, &block)
      node.args&.each { |a| walk_expr_skip_copy(a, &block) }
    when AST::GetField
      walk_expr_skip_copy(node.target, &block)
    when AST::GetIndex
      walk_expr_skip_copy(node.target, &block)
      walk_expr_skip_copy(node.index, &block)
    when AST::StructLit
      node.fields&.each_value { |v| walk_expr_skip_copy(v, &block) }
    when AST::ListLit
      node.items&.each { |i| walk_expr_skip_copy(i, &block) }
    when AST::HashLit
      node.pairs&.each { |_k, v| walk_expr_skip_copy(v.is_a?(Array) ? v[1] : v, &block) }
    when AST::MoveNode
      walk_expr_skip_copy(node.value, &block)
    when AST::CapabilityWrap
      walk_expr_skip_copy(node.value, &block)
    when AST::ReturnNode
      walk_expr_skip_copy(node.value, &block)
    when AST::Assignment
      walk_expr_skip_copy(node.value, &block)
    when AST::VarDecl, AST::BindExpr
      walk_expr_skip_copy(node.value, &block)
    end
  end

  def dup_state(state)
    state.dup
  end
end

# ==========================================
# Use-After-Move Checker (Rule 1)
# ==========================================
#
# Walks every statement in the function. For each Identifier that is READ
# (not declared, not the target of a move), verifies the ownership state
# is :live. Reports USE_AFTER_MOVE if :moved, USE_OF_MAYBE_MOVED if
# :maybe_moved.
#
# This is the critical check Rust has that CLEAR previously lacked.
# Every use-after-free is a use-after-move.

class UseAfterMoveChecker
  attr_reader :errors

  def initialize(fn_node, dataflow)
    @fn_node = fn_node
    @dataflow = dataflow
    @errors = []
  end

  # Run the check. Returns self for chaining.
  def check!
    # Walk the CFG blocks, check reads against per-statement state.
    @dataflow.instance_variable_get(:@cfg).blocks.each do |block|
      block.stmts.each_with_index do |stmt, idx|
        # State BEFORE this statement executes = state after previous statement
        # (or block entry for first statement).
        state_before = if idx == 0
          @dataflow.block_in[block.id] || {}
        else
          @dataflow.point_states[[block.id, idx - 1]] || {}
        end

        check_stmt_reads(stmt, state_before)
      end
    end
    self
  end

  # Convenience: build dataflow + run check in one call.
  def self.check(fn_node, can_fail_fns: nil, schema_lookup: nil)
    df = OwnershipDataflow.analyze(fn_node, can_fail_fns: can_fail_fns, schema_lookup: schema_lookup)
    checker = new(fn_node, df)
    checker.check!
    checker.errors
  end

  private

  # Check all read positions in a statement for use-after-move.
  def check_stmt_reads(stmt, state)
    case stmt
    when AST::VarDecl
      # RHS is read, LHS is declared (not a read).
      check_reads_in_expr(stmt.value, state)

    when AST::BindExpr
      # RHS is read. LHS: if :assign mode, the name is NOT being read (it's
      # being assigned to). If :decl mode, the name is new.
      check_reads_in_expr(stmt.value, state)

    when AST::Assignment
      # RHS is read. LHS: if it's a simple identifier reassignment, the name
      # is NOT being read. If it's field/index access (x.field = val), the
      # TARGET (x) IS being read (we need x to be live to access its field).
      if stmt.name.is_a?(AST::GetField) || stmt.name.is_a?(AST::GetIndex)
        check_reads_in_expr(stmt.name, state)
      end
      check_reads_in_expr(stmt.value, state)

    when AST::ReturnNode
      check_reads_in_expr(stmt.value, state)

    when AST::MoveNode
      # GIVE x: x is being consumed, not read. The move itself is valid.
      # But if the inner is a complex expression, sub-expressions are reads.
      # For simple GIVE ident, skip. For GIVE expr.field, check expr.
      inner = stmt.value
      unless inner.is_a?(AST::Identifier)
        check_reads_in_expr(inner, state)
      end

    when AST::FuncCall
      check_call_reads(stmt, state)

    when AST::MethodCall
      # Receiver is a read (unless it's a union constructor, which is handled
      # by the annotator as a special form).
      check_reads_in_expr(stmt.object, state)
      check_call_reads(stmt, state)

    when AST::IfStatement
      check_reads_in_expr(stmt.condition, state)

    when AST::WhileLoop
      check_reads_in_expr(stmt.condition, state)

    when AST::MatchStatement
      check_reads_in_expr(stmt.expr, state)

    when AST::ForEach
      check_reads_in_expr(stmt.collection, state)

    when AST::BgBlock, AST::BgStreamBlock
      # Captures that are reads (non-resource captures are borrows).
      # Resource captures are moves -- not reads.
      # String captures are borrows -- they ARE reads.
      captures = stmt.capture_analysis&.captures
      resource_captures = Set.new(stmt.capture_analysis&.resource_captures || [])
      (captures || {}).each_key do |name|
        next if resource_captures.include?(name)
        check_identifier_read(name.to_s, state, stmt.token)
      end
    end
  end

  # Check reads in function/method call arguments.
  # was_moved args are moves (not reads) -- skip them.
  def check_call_reads(call_node, state)
    (call_node.args || []).each do |arg|
      if arg.is_a?(AST::Identifier) && arg.was_moved
        # This is a TAKES/GIVE arg -- the move itself is valid, not a read.
        next
      elsif arg.is_a?(AST::MoveNode)
        # GIVE wrapper: inner is being moved, not read.
        next
      elsif arg.is_a?(AST::CopyNode)
        # COPY: the source IS read (must be live to copy from).
        check_reads_in_expr(arg.value, state)
      else
        check_reads_in_expr(arg, state)
      end
    end
  end

  # Recursively walk an expression, checking all Identifier reads.
  def check_reads_in_expr(node, state)
    return unless node

    case node
    when AST::Identifier
      check_identifier_read(node.name.to_s, state, node.token)

    when AST::CopyNode
      # COPY x: x IS read (must be live to copy from).
      check_reads_in_expr(node.value, state)

    when AST::MoveNode
      # GIVE inside an expression: the target is moved, not read.
      # But sub-expressions of complex moves are reads.
      unless node.value.is_a?(AST::Identifier)
        check_reads_in_expr(node.value, state)
      end

    when AST::BinaryOp
      check_reads_in_expr(node.left, state)
      check_reads_in_expr(node.right, state)

    when AST::UnaryOp
      check_reads_in_expr(node.right, state)

    when AST::FuncCall
      check_call_reads(node, state)

    when AST::MethodCall
      check_reads_in_expr(node.object, state)
      check_call_reads(node, state)

    when AST::GetField
      check_reads_in_expr(node.target, state)

    when AST::GetIndex
      check_reads_in_expr(node.target, state)
      check_reads_in_expr(node.index, state)

    when AST::StructLit
      node.fields&.each_value { |v| check_reads_in_expr(v, state) }

    when AST::ListLit
      node.items&.each { |i| check_reads_in_expr(i, state) }

    when AST::HashLit
      node.pairs&.each { |_k, v|
        val = v.is_a?(Array) ? v[1] : v
        check_reads_in_expr(val, state)
      }

    when AST::Literal
      # Leaf node: no identifiers to check.

    when AST::StringConcat
      # String interpolation parts may contain identifiers.
      node.parts&.each { |p| check_reads_in_expr(p, state) }
    end
  end

  # Check a single identifier read against the ownership state.
  def check_identifier_read(name, state, token)
    entry = state[name]
    return unless entry  # not tracked (not in scope, or primitive)

    st = entry.is_a?(OwnershipDataflow::OwnerEntry) ? entry.state : entry

    case st
    when OwnershipDataflow::MOVED
      loc = token ? " (line #{token[:line]})" : ""
      @errors << "[USE_AFTER_MOVE] #{@fn_node.name}::#{name} -- used after being moved#{loc}"
    # NOTE: :maybe_moved reads are NOT errors -- the variable might still be live.
    # Rust allows reads of maybe_moved values (it inserts runtime checks only for drops).
    # We may tighten this later, but for now, only :moved is an error.
    end
  end
end

# ==========================================
# LoopFrameAnalysis (Pass 2, Phase 2.5)
# ==========================================
#
# Sets mark_per_iter on every loop AST node and updates SHARD shard_context
# frame-alloc flags.  Runs after CleanupClassifier has finalised every
# binding's allocator, before MIR node insertion (Phase 3).
#
# Invariant: mark_per_iter = true  iff  the loop body contains at least one
# local, non-escaping, frame-allocated VarDecl.
#
#   "local"      -- declared inside THIS loop (not a nested loop or outer scope)
#   "frame"      -- node.storage == :frame  (set by annotator / upgrade phases)
#   "non-escaping" -- not passed as a value argument to a mutates_receiver
#                    call on an outer-scope container (where the stored pointer
#                    must survive the per-iteration rewind)
#
# If mark_per_iter becomes true and the direct body also contains
# mutates_receiver calls on OUTER containers, those containers are promoted to
# heap so the per-iteration rewind cannot corrupt their backing store.
#
# Scope of rewind:
#   - FOR / WHILE / FOREACH loops -- regular AST loops
#   - IF / MATCH / WITH  -- NOT a rewind boundary; always recurse into branches
#   - Nested loops       -- analysed first (inner→outer); their outer-mutation
#                          promotions are applied before the enclosing loop runs
#   - Functions/lambdas  -- their own frame; the callee rewinds on return
#
module LoopFrameAnalysis

  # Entry point.  Call once per pass, after CleanupClassifier.
  def self.analyze!(fn_nodes)
    fn_nodes.each_value do |fn|
      next unless fn.body
      walk_stmts!(fn.body)
      update_shard_contexts!(fn.body, fn_nodes)
    end
  end

  # ── recursive AST walk ────────────────────────────────────────────────────

  def self.walk_stmts!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_stmt!(s) }
  end

  def self.walk_stmt!(stmt)
    case stmt
    when AST::WhileLoop
      walk_stmts!(stmt.do_branch)          # inner loops first
      process_loop!(stmt, stmt.do_branch)
    when AST::ForRange
      walk_stmts!(stmt.body)
      process_loop!(stmt, stmt.body)
    when AST::ForEach
      walk_stmts!(stmt.body)
      process_loop!(stmt, stmt.body)
    when AST::IfStatement
      walk_stmts!(stmt.then_branch)
      walk_stmts!(stmt.else_branch)
    when AST::MatchStatement
      stmt.cases&.each { |c| walk_stmts!(c[:body]) }
      walk_stmts!(stmt.default_case)
    when AST::WithBlock
      walk_stmts!(stmt.body)
    when AST::DoBlock
      stmt.branches&.each { |b| walk_stmts!(b[:body]) }
    end
  end

  # ── loop analysis ─────────────────────────────────────────────────────────

  def self.process_loop!(loop_node, body)
    return if loop_node.tight  # tight loops suppress all frame marks

    local_names = collect_local_names(body)

    # Find frame-allocated local VarDecls that don't escape into outer containers.
    non_escaping = local_frame_decls(body, local_names).reject do |decl|
      escapes_to_outer?(decl.name.to_s, body, local_names)
    end

    loop_node.mark_per_iter = non_escaping.any?

    if loop_node.mark_per_iter
      frame_local_names = non_escaping.map { |d| d.name.to_s }.to_set

      # When the loop rewinds, backing-store extensions of OUTER frame containers
      # in the DIRECT body are corrupted.  Promote them to heap.
      direct_outer_mutations(body, local_names).each do |receiver_node|
        promote_to_heap!(receiver_node)
      end

      # Outer string variables reassigned with frame-allocated expressions
      # (e.g. resp = resp + result) need preserve-and-rewind rather than
      # heap promotion; the old value is discarded each iteration so promoting
      # to heap would leak every intermediate string.
      loop_node.loop_preserve_vars = outer_string_reassigns(body, local_names, frame_local_names)
    else
      loop_node.loop_preserve_vars = nil
    end

    # Always: promote string-typed RHS expressions to heap when assigned to outer
    # struct/map fields (outer_var.field = expr or outer_var[key] = expr).
    # This prevents allocator mismatches: the cleanup-before-reassign MIR node
    # uses the field's declared allocator (heap), so the new value must also be heap.
    promote_outer_field_assigns!(body, local_names)
  end

  # ── helpers: local name / frame-decl collection ──────────────────────────

  # Collect names declared directly in body (stop at nested loop / fn boundaries).
  def self.collect_local_names(body)
    names = Set.new
    scan_direct(body) do |s|
      case s
      when AST::VarDecl
        names << s.name.to_s if s.name.is_a?(String)
      when AST::BindExpr
        names << s.name.to_s if s.name.is_a?(String) && s.mode == :decl
      end
    end
    names
  end

  # Frame-allocated VarDecl/BindExpr declared directly in body.
  # Use type_info.frame_provenance? (provenance-based) rather than storage == :frame
  # (location-based) because lists/strings annotated with @list have provenance=:frame
  # but location=nil (their storage field stays :stack after finalize_storage!).
  # Only includes types that actually make frame-arena allocations (collections,
  # strings) -- primitives like Int64 are excluded even when frame_provenance? is set.
  def self.local_frame_decls(body, _local_names)
    decls = []
    scan_direct(body) do |s|
      case s
      when AST::VarDecl
        ti = s.type_info
        next unless ti.is_a?(Type)
        is_frame = ti.frame_provenance? &&
                   (ti.list_collection? || ti.map? || ti.string?)
        decls << s if is_frame && s.name.is_a?(String)
      when AST::BindExpr
        ti = s.type_info rescue nil
        next unless ti.is_a?(Type)
        is_frame = ti.frame_provenance? &&
                   (ti.list_collection? || ti.map? || ti.string?)
        decls << s if s.mode == :decl && is_frame && s.name.is_a?(String)
      end
    end
    decls
  end

  # Does var_name appear as a value arg to a mutates_receiver call on an outer
  # container anywhere in the loop body (including nested loops)?
  def self.escapes_to_outer?(var_name, body, local_names)
    found = false
    AST.walk_body(body) do |node|
      next unless node.respond_to?(:mutates_receiver) && node.mutates_receiver
      case node
      when AST::MethodCall
        receiver = node.object
        next unless receiver.is_a?(AST::Identifier) && !local_names.include?(receiver.name)
        found = true if node.args&.any? { |a| a.is_a?(AST::Identifier) && a.name == var_name }
      when AST::FuncCall
        receiver = node.args&.first
        next unless receiver.is_a?(AST::Identifier) && !local_names.include?(receiver.name)
        found = true if node.args&.drop(1)&.any? { |a| a.is_a?(AST::Identifier) && a.name == var_name }
      end
    end
    found
  end

  # mutates_receiver calls in DIRECT body where receiver is an outer container.
  # Returns the receiver Identifier nodes for promotion.
  def self.direct_outer_mutations(body, local_names)
    receivers = []
    scan_direct(body) do |s|
      next unless s.respond_to?(:mutates_receiver) && s.mutates_receiver
      receiver = case s
                 when AST::MethodCall then s.object
                 when AST::FuncCall   then s.args&.first
                 end
      if receiver.is_a?(AST::Identifier) && !local_names.include?(receiver.name)
        receivers << receiver
      end
    end
    receivers
  end

  # Outer-scope string variables that are reassigned with frame-allocating
  # expressions (e.g. resp = resp + result where result is a frame local).
  # These need loopPreserveAndRewind rather than heap promotion.
  # Returns a Set of variable name strings, or nil if none.
  def self.outer_string_reassigns(body, local_names, frame_local_names)
    preserve = Set.new
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::BindExpr) && node.mode == :assign
      next unless node.name.is_a?(String) && !local_names.include?(node.name)
      ti = node.type_info rescue nil
      next unless ti.is_a?(Type) && ti.string?
      # Check if the RHS references any local frame variable.
      next unless rhs_references_any?(node.value, frame_local_names)
      preserve << node.name
    end
    preserve.any? ? preserve : nil
  end

  # Does expr (or any sub-expression) contain a frame-allocating expression?
  # "Frame-allocating" means: references a local frame variable (by name) OR
  # calls a function (stdlib or user-defined) that returns a String (frame via
  # preserveAndRewind protocol), OR calls a stdlib function with stdlib_allocates=true.
  # Used to detect outer-string-reassignment patterns like
  # `resp = resp + i.toString()` or `last = makePrefix(i)` where the RHS creates
  # a frame string that would be freed by the loop's per-iteration rewind.
  def self.rhs_references_any?(expr, names)
    return false unless expr
    # COPY expr produces a heap-allocated value -- never needs loopPreserveAndRewind
    return false if expr.is_a?(AST::CopyNode)
    # Any call (stdlib or user-defined) that returns a String is frame-allocated
    # via the preserveAndRewind protocol. This covers both stdlib_allocates=true
    # calls (toString, intToString, etc.) and user-defined string-returning functions.
    if expr.is_a?(AST::MethodCall) || expr.is_a?(AST::FuncCall)
      ti = expr.type_info rescue nil
      return true if ti.is_a?(Type) && ti.string?
    end
    case expr
    when AST::Identifier
      return names.include?(expr.name)
    when AST::BinaryOp
      return rhs_references_any?(expr.left, names) || rhs_references_any?(expr.right, names)
    when AST::UnaryOp
      return rhs_references_any?(expr.operand, names)
    when AST::FuncCall
      return expr.args&.any? { |a| rhs_references_any?(a, names) } || false
    when AST::MethodCall
      return rhs_references_any?(expr.object, names) ||
             (expr.args&.any? { |a| rhs_references_any?(a, names) } || false)
    when AST::GetField
      return rhs_references_any?(expr.target, names)
    when AST::GetIndex
      return rhs_references_any?(expr.target, names) || rhs_references_any?(expr.index, names)
    when AST::StringConcat
      # StringConcat ALWAYS allocates in the frame arena (std.mem.concat uses
      # frameAlloc). Even if all parts are outer vars / literals, the result is
      # frame-allocated and will be freed by the per-iteration rewind.
      return true
    end
    false
  end

  # Promote frame-allocating string expressions assigned to outer struct/map fields.
  # Pattern: outer_var.field = expr  or  outer_var[key] = expr
  # where outer_var is not a loop-local AND expr is frame-allocating (string concat,
  # toString, etc.). The MIR cleanup-before-reassign uses the field's declared
  # allocator (heap), so the new value must also be heap to avoid a mismatch.
  def self.promote_outer_field_assigns!(body, local_names)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::Assignment)
      target = node.name
      next unless target.is_a?(AST::GetField) || target.is_a?(AST::GetIndex)
      receiver = case target
                 when AST::GetField  then target.target
                 when AST::GetIndex  then target.target
                 end
      next unless receiver.is_a?(AST::Identifier) && !local_names.include?(receiver.name)
      val = node.value
      next unless val
      val_ti = val.type_info rescue nil
      next unless val_ti.is_a?(Type) && val_ti.string?
      # Promote the value expression so the concat/dupe uses heapAlloc.
      promote_value_to_heap!(val)
    end
  end

  # Set storage=:heap on an expression node so it uses heapAlloc.
  # Handles FuncCall/MethodCall (mark heap_dupe_result) and direct string literals.
  def self.promote_value_to_heap!(node)
    return unless node
    ti = node.type_info rescue nil
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    return unless ti&.string?
    return if ti.heap_provenance?  # already heap
    if node.respond_to?(:storage=)
      node.storage = :heap
      ti.provenance = :heap
    end
  end

  # Promote a container Identifier's declaration to heap.
  def self.promote_to_heap!(ident_node)
    decl_node = ident_node.symbol&.reg
    return unless decl_node
    decl_ti = decl_node.type_info rescue nil
    return unless decl_ti.is_a?(Type)
    return unless decl_ti.list_collection? || decl_ti.map? || decl_ti.array? || decl_ti.string?
    decl_ti.provenance = :heap
    decl_node.storage = :heap if decl_node.respond_to?(:storage=)
    if decl_node.respond_to?(:value) && decl_node.value.respond_to?(:storage=)
      decl_node.value.storage = :heap
    end
  end

  # Walk DIRECT body: yield each stmt, recurse into if/match/with but STOP at
  # nested loops and function definitions.
  def self.scan_direct(body, &block)
    return unless body.is_a?(Array)
    body.each do |s|
      yield s
      case s
      when AST::WhileLoop, AST::ForRange, AST::ForEach, AST::FunctionDef
        next  # boundary -- do not enter nested loop / fn body
      when AST::IfStatement
        scan_direct(s.then_branch, &block)
        scan_direct(s.else_branch, &block)
      when AST::MatchStatement
        s.cases&.each { |c| scan_direct(c[:body], &block) }
        scan_direct(s.default_case, &block)
      when AST::WithBlock
        scan_direct(s.body, &block)
      when AST::DoBlock
        s.branches&.each { |b| scan_direct(b[:body], &block) }
      end
    end
  end

  # ── SHARD context frame-alloc flags ──────────────────────────────────────

  # Walk for pipeline nodes that carry a shard_context and update
  # key_allocates_frame / body_allocates_frame.
  def self.update_shard_contexts!(body, fn_nodes)
    AST.walk_body(body) do |node|
      next unless node.respond_to?(:shard_context) && node.shard_context
      ctx = node.shard_context

      # key_allocates_frame: does the routing key expression allocate from frame?
      key_expr = ctx[:key_expr]
      ctx[:key_allocates_frame] = key_allocates_frame?(key_expr, fn_nodes) if key_expr

      # body_allocates_frame: does the EACH body contain local frame allocs?
      each_body = node.respond_to?(:op) && node.op.respond_to?(:body) ? node.op.body : nil
      if each_body
        local_names = collect_local_names(each_body)
        ctx[:body_allocates_frame] = local_frame_decls(each_body, local_names).any?
      end
    end
  end

  # Returns true when expr is a call to a frame-allocating function
  # (uses_frame=true and NOT heap-promoted on return).
  def self.key_allocates_frame?(expr, fn_nodes)
    case expr
    when AST::FuncCall
      fn = fn_nodes[expr.name]
      fn&.uses_frame && fn.return_provenance != :heap
    when AST::MethodCall
      false  # method calls on types are not frame-allocating routing keys
    else
      false
    end
  end

end

# ==========================================
# Flow-Based Verification (Phase 4)
# ==========================================
#
# Verifies the post-MIRPass AST against ownership state.
# Defense-in-depth alongside the post-lowering MIRChecker.
#
# Checks:
#   LEAK          -- binding with needs_cleanup=true but no MIR::Drop in AST
#   ORPHAN_DROP   -- MIR::Drop for a binding that doesn't need cleanup
#   ORPHAN_GUARD  -- MIR::SuppressCleanup for a variable never moved in dataflow
#   FRAME_OVERFLOW -- loop allocates from frame without per-iteration rewind
#   HPT_LEAK      -- heap-returning call result discarded (unbound expression)
class FlowChecker
  attr_reader :errors

  def initialize(fn_name)
    @fn_name = fn_name
    @errors = []
  end

  # Verify a function's AST after MIRPass has inserted all MIR nodes.
  #
  # bindings:  { var_name => entry } from CleanupClassifier (refined by cleanup_decisions!)
  # dataflow:  OwnershipDataflow instance (optional, for ORPHAN_GUARD)
  def check!(fn_body, bindings, dataflow: nil)
    return if bindings.nil? || bindings.empty?

    # Collect all MIR::Drop and MIR::SuppressCleanup names from the AST.
    drop_names = Set.new
    suppress_names = Set.new
    alloc_names = Set.new
    collect_mir_markers(fn_body, drop_names, suppress_names, alloc_names)

    # Check 1: LEAK -- every binding with needs_cleanup must have a Drop.
    bindings.each do |var, entry|
      next unless entry[:needs_cleanup]
      unless drop_names.include?(var)
        @errors << "[LEAK] #{@fn_name}::#{var} -- needs cleanup but no MIR::Drop found"
      end
    end

    # Check 2: ORPHAN_DROP -- every Drop must correspond to a needs_cleanup binding.
    drop_names.each do |name|
      entry = bindings[name]
      unless entry && entry[:needs_cleanup]
        # TAKES params and MATCH AS bindings may have drops not in the main bindings.
        # These are handled separately. Only flag truly orphaned drops.
        unless alloc_names.include?(name)
          @errors << "[ORPHAN_DROP] #{@fn_name}::#{name} -- MIR::Drop without needs_cleanup binding"
        end
      end
    end

    # Check 3: ORPHAN_GUARD -- SuppressCleanup for a variable that the dataflow
    # says was never moved (always :owned at exit). If the variable is always
    # owned, the suppress is dead code and may indicate a bug.
    if dataflow
      summary = dataflow.cleanup_summary
      suppress_names.each do |name|
        df_entry = summary[name]
        # If dataflow shows the variable is owned (never moved), the suppress is suspicious.
        # But only flag it if the variable also has no moved guard (i.e., cleanup_decisions!
        # determined no move happens). A suppress with a moved guard is correct.
        entry = bindings[name]
        if df_entry && !df_entry[:has_moved_guard] && entry && !entry[:has_moved_guard]
          @errors << "[ORPHAN_GUARD] #{@fn_name}::#{name} -- SuppressCleanup but variable is never moved"
        end
      end
    end

    # Check 4: FRAME_OVERFLOW -- loops with frame allocations need rewind.
    check_frame_overflow!(fn_body)
  end

  private

  def collect_mir_markers(stmts, drops, suppresses, allocs)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when MIR::Drop
        drops << stmt.name.to_s
      when MIR::SuppressCleanup
        suppresses << stmt.name.to_s
      when MIR::Alloc
        allocs << stmt.name.to_s
      end

      # Recurse into nested control flow.
      case stmt
      when AST::IfStatement
        collect_mir_markers(stmt.then_branch, drops, suppresses, allocs)
        collect_mir_markers(stmt.else_branch, drops, suppresses, allocs)
        collect_mir_markers(stmt.then_drops, drops, suppresses, allocs)
        collect_mir_markers(stmt.else_drops, drops, suppresses, allocs)
      when AST::WhileLoop
        collect_mir_markers(stmt.do_branch, drops, suppresses, allocs)
      when AST::ForRange, AST::ForEach
        collect_mir_markers(stmt.body, drops, suppresses, allocs)
      when AST::MatchStatement
        stmt.cases&.each { |c| collect_mir_markers(c[:body], drops, suppresses, allocs) }
        collect_mir_markers(stmt.default_case, drops, suppresses, allocs)
        collect_mir_markers(stmt.case_drops, drops, suppresses, allocs) if stmt.case_drops.is_a?(Array)
        collect_mir_markers(stmt.default_drops, drops, suppresses, allocs) if stmt.default_drops.is_a?(Array)
      when AST::WithBlock
        collect_mir_markers(stmt.body, drops, suppresses, allocs)
      when AST::DoBlock
        stmt.branches&.each { |b| collect_mir_markers(b[:body], drops, suppresses, allocs) }
      when AST::BgBlock, AST::BgStreamBlock
        collect_mir_markers(stmt.body, drops, suppresses, allocs)
      end
    end
  end

  # FRAME_OVERFLOW: loops that allocate from the frame arena without
  # per-iteration rewind.
  def check_frame_overflow!(stmts)
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::WhileLoop
        unless stmt.tight || stmt.mark_per_iter
          if has_frame_alloc?(stmt.do_branch)
            @errors << "[FRAME_OVERFLOW] #{@fn_name} -- loop body allocates from frame arena without per-iteration rewind"
          end
        end
        check_frame_overflow!(stmt.do_branch)
      when AST::ForRange
        unless stmt.mark_per_iter
          if has_frame_alloc?(stmt.body)
            @errors << "[FRAME_OVERFLOW] #{@fn_name} -- loop body allocates from frame arena without per-iteration rewind"
          end
        end
        check_frame_overflow!(stmt.body)
      when AST::ForEach
        unless stmt.mark_per_iter
          if has_frame_alloc?(stmt.body)
            @errors << "[FRAME_OVERFLOW] #{@fn_name} -- loop body allocates from frame arena without per-iteration rewind"
          end
        end
        check_frame_overflow!(stmt.body)
      when AST::IfStatement
        check_frame_overflow!(stmt.then_branch)
        check_frame_overflow!(stmt.else_branch)
      when AST::MatchStatement
        stmt.cases&.each { |c| check_frame_overflow!(c[:body]) }
        check_frame_overflow!(stmt.default_case)
      when AST::WithBlock
        check_frame_overflow!(stmt.body)
      when AST::DoBlock
        stmt.branches&.each { |b| check_frame_overflow!(b[:body]) }
      end
    end
  end

  def has_frame_alloc?(stmts)
    return false unless stmts.is_a?(Array)
    stmts.any? do |s|
      (s.is_a?(MIR::Alloc) && s.alloc == :frame) ||
        (s.is_a?(AST::VarDecl) && s.has_cleanup && s.storage != :heap && s.storage != :stack)
    end
  end
end

# ==========================================
# Borrow Checking (Phase 6)
# ==========================================
#
# Verifies that borrowed variables (via WITH RESTRICT / WITH BORROWED) are not
# moved while the borrow is active, and that overlapping borrows don't violate
# aliasing rules.
#
# AST walk (not CFG) -- WITH blocks are lexically scoped, so a stack-based
# approach suffices. No NLL or inter-procedural lifetime analysis needed.
#
# Checks:
#   MOVE_WHILE_BORROWED  -- GIVE/move/return of a variable with an active borrow
#   ALIAS_VIOLATION      -- mutable borrow (RESTRICT) while already borrowed,
#                           or any borrow while mutably borrowed
#
# Only RESTRICT and BORROWED create compile-time borrows. EXCLUSIVE, multiowned,
# shared, and write_locked_read use runtime protection (locks / Rc / Arc).
class BorrowChecker
  attr_reader :errors

  def self.check(fn_node, schema_lookup:)
    checker = new(fn_node, schema_lookup: schema_lookup)
    checker.check!
    checker.errors
  end

  def initialize(fn_node, schema_lookup:)
    @fn_name = fn_node.name
    @fn_node = fn_node
    @schema_lookup = schema_lookup
    @errors = []
    @active_borrows = {} # { source_name => [{ kind: :mutable/:immutable }] }
  end

  def check!
    check_stmts(@fn_node.body || [])
  end

  private

  # Extract the root variable name from a capability's var_node.
  def cap_source_name(var_node)
    case var_node
    when AST::Identifier then var_node.name.to_s
    when AST::GetField then cap_source_name(var_node.target)
    when AST::GetIndex then cap_source_name(var_node.target)
    else nil
    end
  end

  def line_info(token)
    token&.line ? " (line #{token.line})" : ""
  end

  def check_stmts(stmts)
    return unless stmts.is_a?(Array)
    stmts.each { |stmt| check_stmt(stmt) }
  end

  def check_stmt(stmt)
    case stmt
    when AST::WithBlock
      handle_with_block(stmt)

    when AST::VarDecl, AST::BindExpr
      check_binding_moves(stmt.value, stmt.token)

    when AST::Assignment
      check_binding_moves(stmt.value, stmt.token)

    when AST::ReturnNode
      check_binding_moves(stmt.value, stmt.token)

    when AST::MoveNode
      # Standalone GIVE statement
      inner = stmt.value
      if inner.is_a?(AST::Identifier)
        check_borrowed_move(inner.name.to_s, stmt.token)
      end

    when AST::FuncCall, AST::MethodCall
      check_explicit_moves(stmt, stmt.token)

    when AST::IfStatement
      check_stmts(stmt.then_branch)
      check_stmts(stmt.else_branch)

    when AST::WhileLoop
      check_stmts(stmt.do_branch)

    when AST::ForRange, AST::ForEach
      check_stmts(stmt.body)

    when AST::MatchStatement
      stmt.cases&.each { |c| check_stmts(c[:body]) }
      check_stmts(stmt.default_case)

    when AST::DoBlock
      stmt.branches&.each { |b| check_stmts(b[:body]) }

    when AST::BgBlock, AST::BgStreamBlock
      # BG resource captures are ownership transfers
      stmt.capture_analysis&.resource_captures&.each do |name|
        check_borrowed_move(name, stmt.token)
      end
      check_stmts(stmt.body)
    end
  end

  def handle_with_block(stmt)
    added = []

    (stmt.capabilities || []).each do |cap|
      source = cap_source_name(cap[:var_node])
      next unless source

      # Only RESTRICT and BORROWED create compile-time borrows.
      capability = cap[:capability]
      next unless capability == :RESTRICT || capability == :BORROWED

      kind = (capability == :RESTRICT) ? :mutable : :immutable
      token = (cap[:var_node].respond_to?(:token) ? cap[:var_node].token : nil) || stmt.token

      # ALIAS_VIOLATION: conflicting borrows
      existing = @active_borrows[source]
      if existing&.any?
        if kind == :mutable
          @errors << "[ALIAS_VIOLATION] #{@fn_name}::#{source} -- " \
                     "mutable borrow (RESTRICT) while already borrowed#{line_info(token)}"
        elsif existing.any? { |b| b[:kind] == :mutable }
          @errors << "[ALIAS_VIOLATION] #{@fn_name}::#{source} -- " \
                     "immutable borrow while mutably borrowed (RESTRICT)#{line_info(token)}"
        end
        # Multiple immutable borrows are fine (shared reads).
      end

      @active_borrows[source] ||= []
      @active_borrows[source] << { kind: kind }
      added << source
    end

    # Check body with borrows active
    check_stmts(stmt.body)

    # Release borrows (LIFO)
    added.reverse_each do |source|
      @active_borrows[source]&.pop
      @active_borrows.delete(source) if @active_borrows[source]&.empty?
    end
  end

  # Check if any identifier being moved in a binding RHS is currently borrowed.
  # Mirrors OwnershipDataflow#collect_binding_moves.
  def check_binding_moves(expr, token)
    return unless expr
    moved = collect_moved_names(expr)
    moved.each { |name| check_borrowed_move(name, token) }
  end

  # Check explicit moves (was_moved) in function/method call arguments.
  def check_explicit_moves(stmt, token)
    walk_for_was_moved(stmt) do |ident|
      next if copy_type?(ident)
      check_borrowed_move(ident.name.to_s, ident.token || token)
    end
  end

  def check_borrowed_move(name, token)
    borrows = @active_borrows[name]
    return unless borrows&.any?
    borrow_kind = borrows.last[:kind]
    @errors << "[MOVE_WHILE_BORROWED] #{@fn_name}::#{name} -- " \
               "cannot move while #{borrow_kind} borrow is active#{line_info(token)}"
  end

  # Collect variable names being moved by an expression (binding RHS context).
  # Non-Copy identifiers in ownership-transferring positions are moves.
  def collect_moved_names(node)
    names = Set.new
    _collect_moves(node, names)
    names
  end

  def _collect_moves(node, names)
    return unless node
    case node
    when AST::Identifier
      return if copy_type?(node)
      names << node.name.to_s
    when AST::StructLit
      node.fields&.each_value { |v| _collect_moves(v, names) }
    when AST::MethodCall
      # Union constructors (TYPE_ID): payload transfers ownership.
      # Regular method calls: only was_moved args.
      if node.object.is_a?(AST::Identifier) && node.object.token&.type == :TYPE_ID
        node.args&.each { |a| _collect_moves(a, names) }
      else
        _collect_was_moved(node, names)
      end
    when AST::FuncCall
      _collect_was_moved(node, names)
    when AST::ListLit
      node.items&.each { |i| _collect_moves(i, names) }
    when AST::MoveNode
      inner = node.value
      names << inner.name.to_s if inner.is_a?(AST::Identifier)
    when AST::CopyNode
      # COPY does NOT move the source.
    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      _collect_moves(node.value, names)
    when AST::BgBlock, AST::BgStreamBlock
      node.capture_analysis&.resource_captures&.each { |n| names << n }
    else
      _collect_was_moved(node, names)
    end
  end

  def _collect_was_moved(node, names)
    walk_for_was_moved(node) do |ident|
      next if copy_type?(ident)
      names << ident.name.to_s
    end
  end

  # Walk expression tree for was_moved identifiers, skipping CopyNode.
  def walk_for_was_moved(node, &block)
    return unless node
    case node
    when AST::CopyNode then return
    when AST::Identifier then yield node if node.was_moved
    when AST::BinaryOp
      walk_for_was_moved(node.left, &block)
      walk_for_was_moved(node.right, &block)
    when AST::UnaryOp
      walk_for_was_moved(node.right, &block)
    when AST::FuncCall
      node.args&.each { |a| walk_for_was_moved(a, &block) }
    when AST::MethodCall
      walk_for_was_moved(node.object, &block)
      node.args&.each { |a| walk_for_was_moved(a, &block) }
    when AST::GetField
      walk_for_was_moved(node.target, &block)
    when AST::GetIndex
      walk_for_was_moved(node.target, &block)
      walk_for_was_moved(node.index, &block)
    when AST::StructLit
      node.fields&.each_value { |v| walk_for_was_moved(v, &block) }
    when AST::ListLit
      node.items&.each { |i| walk_for_was_moved(i, &block) }
    when AST::MoveNode
      walk_for_was_moved(node.value, &block)
    when AST::CapabilityWrap
      walk_for_was_moved(node.value, &block)
    end
  end

  def copy_type?(ident)
    ti = ident.type_info rescue nil
    return true unless ti
    ti = Type.new(ti) if !ti.is_a?(Type)
    ti.primitive? || ti.string? || ti.any? || ti.void? || (ti.any_rc? rescue false)
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

    # Phase 1.5: upgrade always-escaped collections to heap at declaration.
    # If a collection variable is returned on ALL return paths, allocate it on the
    # heap from the start instead of frame-then-promote. This eliminates the
    # MIR::Promote + runtime promoteList for these variables.
    promotion_plans.each do |name, plan|
      next unless plan[:var_promotes]&.any?
      fn = @fn_nodes[name]
      upgrade_always_escaped_to_heap!(fn, plan) if fn&.body
    end

    # Phase 1.5b: upgrade BG-captured variables to heap at declaration.
    # BG blocks capture outer variables into a separate fiber. Frame-allocated
    # data would be invalidated by frame rewind, so captured collections and
    # strings are promoted at runtime. Upgrading to heap at declaration
    # eliminates the runtime promote.
    @fn_nodes.each do |name, fn|
      upgrade_bg_captures_to_heap!(fn) if fn&.body
    end

    # Phase 2: classify cleanup bindings (uses cleared provenance from Phase 1).
    @fn_nodes.each do |name, fn|
      @cleanup_bindings[name] = CleanupClassifier.classify(fn, fn_nodes: @fn_nodes, schema_lookup: @schema_lookup)
    end

    # Phase 2.5: set mark_per_iter on all loops (requires finalised allocators from Phase 2).
    LoopFrameAnalysis.analyze!(@fn_nodes)

    # Phase 3: insert MIR nodes + stamp AST.
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      transform_function!(stmt, promotion_plans[stmt.name])
    end

  end

  private

  # Upgrade always-escaped collection variables to heap at declaration.
  # A variable is always-escaped if it's in var_promotes AND referenced in
  # every return node. For those, heap allocation at declaration is correct
  # and cheaper than frame-then-promote.
  # Performance optimization: allocate on heap from the start instead of frame+promote.
  # NOT a correctness requirement. OwnershipDataflow marks returned values as :moved
  # regardless of allocator. Without this, programs work but do runtime promotions.
  def upgrade_always_escaped_to_heap!(fn, plan)
    return_nodes = []
    AST.walk_body(fn.body) { |n| return_nodes << n if n.is_a?(AST::ReturnNode) }
    return if return_nodes.empty?

    always_escaped = plan[:var_promotes].select do |vp|
      return_nodes.all? { |ret| ret.value && return_references_var?(ret.value, vp[:var]) }
    end
    return if always_escaped.empty?

    always_names = Set.new
    always_escaped.each do |vp|
      ident = find_return_identifier(return_nodes, vp[:var])
      next unless ident

      # Upgrade declaration node
      decl = ident.symbol&.reg
      if decl&.respond_to?(:storage=)
        decl.storage = :heap
      end
      decl_ti = decl&.type_info rescue nil
      if decl_ti.is_a?(Type)
        decl_ti.provenance = :heap
        # Clear escaped_return so CleanupClassifier's escape hatch (line 420)
        # doesn't suppress cleanup. The variable is heap from the start now --
        # it doesn't need runtime promotion, so "escaped" is no longer true.
        decl_ti.escaped_return = false
      end

      # Upgrade scope entry
      if ident.symbol
        ident.symbol.storage = :heap
        sym_type = ident.symbol.type
        if sym_type.is_a?(Type)
          sym_type.provenance = :heap
          sym_type.escaped_return = false
        end
      end

      always_names << vp[:var]
    end

    # Remove always-escaped vars from promotion plan (no MIR::Promote needed)
    plan[:var_promotes] = plan[:var_promotes].reject { |vp| always_names.include?(vp[:var]) }
  end

  # Check if a return value expression references a variable by name.
  def return_references_var?(node, var_name)
    case node
    when AST::Identifier then node.name == var_name
    when AST::StructLit, AST::UnionVariantLit
      node.fields.any? { |_, fval| return_references_var?(fval, var_name) }
    else false
    end
  end

  # Find an Identifier node for a variable name across all return nodes.
  def find_return_identifier(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value
      ident = extract_identifier(ret.value, var_name)
      return ident if ident
    end
    nil
  end

  # Extract an Identifier node matching var_name from a return value expression.
  def extract_identifier(node, var_name)
    case node
    when AST::Identifier
      node.name == var_name ? node : nil
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_value { |fval| r = extract_identifier(fval, var_name); return r if r }
      nil
    else nil
    end
  end

  # Performance optimization: allocate BG-captured collections on heap from the start.
  # NOT a correctness requirement. OwnershipDataflow marks resource captures as :moved
  # regardless of allocator. Without this, programs work but do runtime promotions.
  #
  # Only collections (list/map) benefit: their allocator controls backing storage.
  # Strings still need MIR::Promote(:bg_string) because the data comes from
  # external sources and must be physically duped to heap at capture time.
  def upgrade_bg_captures_to_heap!(fn)
    # Collect captured collection variable names needing escape promotion.
    bg_capture_names = Set.new
    AST.walk_body(fn.body) do |stmt|
      each_bg_in_stmt(stmt) do |bg|
        captured = bg.capture_analysis&.captures
        next unless captured&.any?
        captured.each do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          next unless t && !t.needs_pointer_passing?
          next unless t.list_collection? || (t.map? && !t.numeric_map?)
          bg_capture_names << name
        end
      end
    end
    return if bg_capture_names.empty?

    # Track upgraded names so insert_bg_escape_promote! skips them.
    @bg_heap_upgraded ||= Set.new
    @bg_heap_upgraded.merge(bg_capture_names)

    # Find declarations and upgrade to heap.
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
      var_name = node.name.is_a?(String) ? node.name : node.name.to_s
      next unless bg_capture_names.include?(var_name)

      node.storage = :heap if node.respond_to?(:storage=)
      ti = node.type_info rescue nil
      if ti.is_a?(Type)
        ti.provenance = :heap
      end
    end
  end

  def transform_function!(fn, promo)
    bindings = @cleanup_bindings[fn.name]
    has_bindings = bindings && !bindings.empty?
    promo = nil if promo&.empty?

    fn.has_promotion = true if promo

    has_bg_escapes = body_has_bg_escape_promotes?(fn.body)
    has_catch = fn.catch_clauses.is_a?(Array) && fn.catch_clauses.any?
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

    # Stamp field pre-cleanup info directly on Assignment nodes.
    CleanupClassifier.stamp_field_pre_cleanups!(fn.body, bindings, schema_lookup: @schema_lookup) if has_bindings

    @fn_has_catch = has_catch
    fn.body = transform_body(fn.body, bindings, promo)

    # Transform catch clause bodies so MIR::Promote(:catch_string_dupe) is
    # inserted before string returns in error recovery paths.
    if has_catch
      fn.catch_clauses.each do |clause|
        clause[:body] = transform_body(clause[:body], nil, nil) if clause[:body]
      end
      if fn.default_catch.is_a?(Array)
        fn.default_catch = transform_body(fn.default_catch, nil, nil)
      end
    end
    @fn_has_catch = false

    # Insert MIR::Drop nodes for TAKES parameters at function body start.
    insert_takes_drops!(fn, bindings) if has_bindings

    # Build moved_guard_info map: { var_name => bool } for all bindings.
    stamp_moved_guard_info!(fn, bindings) if has_bindings

    # Flow-based verification: check MIRPass output against ownership state.
    if has_bindings
      fc = FlowChecker.new(fn.name)
      fc.check!(fn.body, bindings, dataflow: @last_dataflow)
      unless fc.errors.empty?
        raise "[Flow Verification] #{fc.errors.first}"
      end
    end
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
        insert_return!(result, stmt, bindings)
        insert_promotion!(result, stmt, promo)
        # HPT return promotion: insert MIR::Promote for checker verification.
        result << stmt.hpt_return_promote if stmt.hpt_return_promote
        # Catch string dupe: heap-dupe string returns so both success and
        # error paths have consistent allocation for caller cleanup.
        insert_catch_string_dupe!(result, stmt) if @fn_has_catch
      end

      # Stamp cleanup info on reassignment / match-as nodes.
      stamp_reassign_cleanup!(stmt, bindings)
      stamp_match_as_cleanup!(stmt, bindings)

      # Insert MIR::Promote before container stores that need frame-to-heap promotion.
      insert_container_promote!(result, stmt)

      # BG escape promotions: frame-allocated captures must be promoted to heap.
      insert_bg_escape_promote!(result, stmt)

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

      # Insert Drop after VarDecl / BindExpr (decl mode).
      insert_drop!(result, stmt, bindings)

      # Insert SuppressCleanup after statements that consume bindings.
      insert_suppress_cleanup!(result, stmt, bindings)

      # BG blocks that capture resources transfer ownership — suppress outer cleanup.
      insert_bg_resource_suppress!(result, stmt, bindings)
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
    # MATCH AS bindings are handled by stamp_match_as_cleanup!, not here.
    # Skip to avoid name collisions (e.g., MATCH AS si vs MUTABLE si in different branches).
    return if entry[:match_as]

    # LoopFrameAnalysis (Phase 2.5) may have heap-promoted a container that
    # CleanupClassifier (Phase 2) initially classified as :frame.  The AST
    # node's type_info reflects the updated provenance; sync the entry so the
    # transpiler emits heapAlloc for the cleanup.
    if entry[:alloc] == :frame
      ti = stmt.type_info rescue nil
      if ti.is_a?(Type) && ti.heap_provenance?
        entry = entry.merge(alloc: :heap)
        bindings[name] = entry
      end
    end

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
    # Use the stdlib's resolved alloc symbol (what {alloc} will emit in Zig) when
    # available -- this is independent of entry[:alloc] (which comes from cleanup
    # classifier / provenance) and lets ALLOC_CLEANUP_MISMATCH catch cases where
    # alloc: and return_alloc: in the registry specify different allocators.
    mir_alloc = resolve_stmt_stdlib_alloc(stmt) || entry[:alloc]
    result << MIR::Alloc.new(stmt.token, name, entry[:kind], mir_alloc)

    drop = MIR::Drop.new(
      stmt.token, name, entry[:kind], entry[:alloc],
      entry[:has_moved_guard], nil, entry[:resource_close_zig],
      nil
    )
    drop.cleanup_entry = drop_entry
    result << drop
  end

  # Resolve the stdlib alloc: symbol for an AllocMark, using the FuncCall node's
  # own storage -- the same resolution the Zig emitter applies for {alloc}.
  # Returns nil when no stdlib alloc is available (non-stdlib, or lazy symbol we
  # can't resolve here), falling back to the cleanup entry alloc.
  def resolve_stmt_stdlib_alloc(stmt)
    val = stmt.respond_to?(:value) ? stmt.value : nil
    return nil unless val
    mdef = val.respond_to?(:matched_stdlib_def) ? val.matched_stdlib_def : nil
    return nil unless mdef.is_a?(Hash)
    case mdef[:alloc]
    when :heap, :frame then mdef[:alloc]
    when :node_storage
      # Mirror resolve_alloc_sym(:node_storage) in mir_lowering.rb:
      # uses FuncCall's storage field, NOT provenance.
      val.respond_to?(:storage) && val.storage == :heap ? :heap : :frame
    end
    # :receiver_storage and unknown symbols: return nil (fall back to entry alloc)
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
    when :list, :list_with_elem_cleanup, :string_map, :numeric_map, :set, :fixed_soa
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
        strategy = t.list_collection? ? :list : :bg_string
        result << MIR::Promote.new(bg.token, name, t.zig_type, strategy, nil)
      end
    end
  end

  # Insert MIR::Promote(:catch_string_dupe) before a ReturnNode in a catch
  # function when the return value is string-typed. Both success and error
  # paths must return heap-backed strings for consistent caller cleanup.
  def insert_catch_string_dupe!(result, ret_node)
    return unless ret_node.value
    ft = ret_node.value.respond_to?(:full_type) ? ret_node.value.full_type : nil
    return unless ft
    t = Type.new(ft)
    return unless t.string?
    result << MIR::Promote.new(ret_node.token, :__catch_ret, "[]const u8", :catch_string_dupe, nil)
  end

  # Insert MIR::Promote(:or_fallback_dupe) before a statement that contains
  # an OrRescue where the success path is heap-promoted and the fallback is
  # a struct literal. Signals the transpiler to heap-dupe string fields in the
  # fallback so cleanup semantics match the success path.
  def insert_or_fallback_dupe!(result, stmt)
    or_node = find_or_rescue_in_value(stmt)
    return unless or_node
    return unless or_node.right.is_a?(AST::StructLit)
    return unless or_rescue_needs_fallback_dupe?(or_node)
    result << MIR::Promote.new(or_node.token, :__or_fallback, nil, :or_fallback_dupe, nil)
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
          when AST::Assignment then stmt.value
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
    val_ti = stmt.value.type_info rescue nil
    return unless val_ti
    val_ti = Type.new(val_ti) if val_ti && !val_ti.is_a?(Type)
    return unless val_ti.needs_promotion?(@schema_lookup)

    result << MIR::Promote.new(stmt.token, nil, val_ti.zig_type, :container_store, nil)
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

    # Struct-level field promotion: insert MIR::Promote with :ret_fields strategy
    # so the StaticLeakChecker can verify it. The transpiler consumes this as a
    # pending flag and wraps the return value in `var __ret` + per-field promote calls.
    if filtered[:struct_promote] && PromotionClassifier.needs_promote?(filtered, ret_node)
      ret_node.promote_ret_wrap = :var
      result << MIR::Promote.new(
        ret_node.token, :__ret,
        filtered[:struct_promote], :ret_fields,
        filtered[:unhandled_promote_fields]
      )
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
    @current_hpt_fn = fn
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
        if stmt.is_a?(AST::BindExpr) && stmt.mode == :assign
          # Scan reassignment RHS for HPTs (sub-expressions only, like Assignment).
          stmt.value = hoist_hpt_in_expr(stmt.value, stmt, hoisted, is_bind_value: true)
        else
          val = stmt.value
          if val.is_a?(AST::BinaryOp) && val.op == :OR_RESCUE
            # Left side is the bind value; right side may have HPTs.
            stmt.value.right = hoist_hpt_in_expr(val.right, stmt, hoisted, is_bind_value: false)
          else
            # The top-level value is the bind value. Scan sub-expressions only.
            stmt.value = hoist_hpt_in_expr(val, stmt, hoisted, is_bind_value: true)
          end
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
        if replaced != stmt
          # Entire call was hoisted to a VarDecl with cleanup. The leftover
          # Identifier is a no-op -- skip it to avoid Zig `_ = __hpt_N` conflicts.
          result.concat(hoisted)
          next
        end
      when AST::IfStatement
        # Hoist heap-returning calls out of IF conditions (evaluated once).
        stmt.condition = hoist_hpt_in_expr(stmt.condition, stmt, hoisted, is_bind_value: false)
      when AST::WhileLoop
        # WHILE conditions are evaluated every iteration -- cannot hoist out.
        # Reject heap-returning calls in WHILE conditions at compile time.
        check_no_heap_call_in_while_condition!(stmt)
      when AST::MatchStatement
        # Hoist heap-returning calls out of MATCH subjects (evaluated once).
        stmt.expr = hoist_hpt_in_expr(stmt.expr, stmt, hoisted, is_bind_value: false)
      when AST::ForEach
        # Hoist heap-returning calls out of FOR-EACH collections (evaluated once).
        stmt.collection = hoist_hpt_in_expr(stmt.collection, stmt, hoisted, is_bind_value: false)
      when AST::Assert
        # Hoist heap-returning calls out of ASSERT conditions and messages.
        stmt.condition = hoist_hpt_in_expr(stmt.condition, stmt, hoisted, is_bind_value: false)
        if stmt.message
          stmt.message = hoist_hpt_in_expr(stmt.message, stmt, hoisted, is_bind_value: false)
        end
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

  # WHILE conditions are evaluated every iteration. Hoisting a heap-returning
  # call out would change semantics (evaluate once instead of per-iteration),
  # and leaving it in leaks a heap allocation per iteration with no cleanup.
  # Reject at compile time; user must assign to a variable.
  def check_no_heap_call_in_while_condition!(while_node)
    cond = while_node.condition
    return unless cond
    heap_call = find_heap_call_in_expr(cond)
    return unless heap_call
    line = heap_call.token&.line || while_node.token&.line || "?"
    call_name = heap_call.is_a?(AST::MethodCall) ? heap_call.method_name : heap_call.name
    raise "[Error] (line #{line}) Heap-allocating call '#{call_name}' in WHILE condition " \
          "leaks every iteration. Assign to a variable before the loop."
  end

  # Walk an expression looking for a FuncCall/MethodCall with heap_provenance.
  def find_heap_call_in_expr(node)
    return nil unless node
    case node
    when AST::FuncCall, AST::MethodCall
      ti = node.type_info rescue nil
      ti = ti.is_a?(Type) ? ti : nil
      return node if ti&.heap_provenance?
      # Check children (args, object).
      node.args.each do |arg|
        found = find_heap_call_in_expr(arg)
        return found if found
      end
      if node.is_a?(AST::MethodCall)
        found = find_heap_call_in_expr(node.object)
        return found if found
      end
    when AST::BinaryOp
      return find_heap_call_in_expr(node.left) || find_heap_call_in_expr(node.right)
    when AST::GetField
      return find_heap_call_in_expr(node.target)
    when AST::GetIndex
      return find_heap_call_in_expr(node.target) || find_heap_call_in_expr(node.index)
    when AST::MoveNode
      return find_heap_call_in_expr(node.value)
    end
    nil
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
    # Insert MIR::Promote before the ReturnNode so the checker can verify.
    if stmt_node.is_a?(AST::ReturnNode)
      ret_ti = stmt_node.value&.type_info rescue nil
      ret_ti = ret_ti.is_a?(Type) ? ret_ti : nil
      if ret_ti&.string?
        # Use heap allocator for the dupe when the function returns heap-provenance
        # data. This ensures the returned string's allocator matches what the caller
        # expects (INV-1: single allocator per binding).
        dupe_alloc = @current_hpt_fn&.return_provenance == :heap ? :heap : :frame
        stmt_node.hpt_return_promote = MIR::Promote.new(stmt_node.token, nil, "[]const u8", :hpt_string_dupe, dupe_alloc)
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
          zig_t = Type.new(resolved).zig_type
          stmt_node.hpt_return_promote = MIR::Promote.new(stmt_node.token, nil, zig_t, :hpt_promote, nil)
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
