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

require_relative "../ast/ast"

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
    when AST::CopyNode, AST::CloneNode, AST::MoveNode, AST::Cast
      stmt_can_fail?(node.value, can_fail_fns)
    when AST::FreezeNode
      true  # freeze() always returns an error union (OOM / Cycle)
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
    (@fn_node.params || []).each do |p|
      next unless p[:takes]
      name = p[:name].to_s
      ti = p[:type].is_a?(Type) ? p[:type] : (Type.new(p[:type] || :Any) rescue nil)
      needs = ti ? ti.needs_explicit_cleanup?(:heap, @schema_lookup) : true
      state[name] = OwnerEntry.new(state: OWNED, allocator: :heap, needs_cleanup: needs)
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
    ti = Type.from_node(node)
    allocator = ti ? ((ti.provenance_alloc rescue nil) || (ti.heap_provenance? ? :heap : :frame)) : :frame
    needs = ti ? (ti.needs_explicit_cleanup?(allocator, @schema_lookup) rescue false) : false
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
      # Map indexed assignments: only skip rhs moves for UNION values (dupeUnionValue
      # creates a true deep copy, so the original retains ownership). For struct values,
      # CheatLib.promote() shallow-copies heap string pointers, so nested list-field
      # variables ARE consumed (moved) into the promoted copy -- suppress their cleanup.
      lhs = stmt.name
      lhs_is_map = lhs.is_a?(AST::GetIndex) && (Type.from_node(lhs.target)&.map? rescue false)
      skip_rhs_move = if lhs_is_map
        val_ti_raw = stmt.value.respond_to?(:type_info) ? (stmt.value.type_info rescue nil) : nil
        val_resolved = val_ti_raw && (val_ti_raw.is_a?(Type) ? val_ti_raw.resolved : val_ti_raw)
        schema = val_resolved && @schema_lookup&.call(val_resolved)
        schema.is_a?(Hash) && schema[:kind] == :union
      else
        false
      end
      collect_binding_moves(stmt.value, state).each { |n| mark_moved!(state, n) } unless skip_rhs_move

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
      # User-written GIVE x inside the BG body (where x is a captured
      # outer binding) transfers ownership out of the outer scope too.
      # COPY/CLONE do NOT consume — those deep-copy / rc-clone.
      collect_bg_body_gives(stmt).each do |name|
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

    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      # COPY / FREEZE do NOT move the source.

    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      collect_ownership_transfers(node.value, state, consumed)

    when AST::BgBlock, AST::BgStreamBlock
      # Resources captured by BG fibers transfer ownership.
      node.capture_analysis&.resource_captures&.each do |name|
        consumed << name if state[name]
      end
      # GIVE x inside the BG body moves the outer x into the fiber.
      collect_bg_body_gives(node).each do |name|
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
      collect_bg_body_gives(expr).each do |name|
        consumed << name if state[name]
      end
    when AST::FuncCall
      expr.args&.each { |a| _walk_bg_captures_in_expr(a, state, consumed) }
    when AST::MethodCall
      _walk_bg_captures_in_expr(expr.object, state, consumed)
      expr.args&.each { |a| _walk_bg_captures_in_expr(a, state, consumed) }
    end
  end

  # Walks the BG body looking for `GIVE capture` (MoveNode wrapping an
  # Identifier whose name is in the BG's capture set). Each such GIVE
  # transfers ownership of the outer binding into the fiber. COPY/CLONE
  # do not consume — those paths deep-copy / rc-clone instead (handled
  # by walk_expr_skip_copy refusing to recurse into CopyNode).
  def collect_bg_body_gives(bg_node)
    capture_names = (bg_node.capture_analysis&.captures || {}).keys.map(&:to_s).to_set
    return [] if capture_names.empty?
    moves = []
    AST.walk_body(bg_node.body) do |stmt|
      walk_expr_skip_copy(stmt) do |sub|
        # Direct GIVE x: MoveNode(Identifier).
        if sub.is_a?(AST::MoveNode) && sub.value.is_a?(AST::Identifier)
          moves << sub.value.name.to_s if capture_names.include?(sub.value.name.to_s)
          next
        end
        # GIVE x to a TAKES param of an adapted type (e.g. @list arg to a
        # slice param) -- function_analysis.rb wraps the user's MoveNode
        # in a CopyNode for the type adaptation but stamps was_moved=true
        # on the wrapper. The user's GIVE intent lives on that flag.
        if sub.is_a?(AST::CopyNode) && sub.respond_to?(:was_moved) && sub.was_moved &&
           sub.value.is_a?(AST::Identifier)
          moves << sub.value.name.to_s if capture_names.include?(sub.value.name.to_s)
        end
      end
    end
    moves.uniq
  end

  # Returns true if this identifier's type is Copy (no move on assignment).
  # Primitives, strings, enums, :Any, and RC types are Copy-like.
  # RC assignment is clone (rcRetain), not move. Only GIVE/MOVE transfers
  # ownership (handled by was_moved from the annotator).
  def copy_type?(ident)
    ti = Type.from_node(ident)
    return true unless ti  # unknown type, assume Copy (safe)
    ti.primitive? || ti.string? || ti.any? || ti.void? || ti.any_rc?
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
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
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
  #
  # Exception: when the user explicitly wrote GIVE inside a CopyNode
  # (which happens when ensure_owned_value! wraps a user's MoveNode for
  # type adaptation -- e.g. GIVE bgCaps to a param expecting Value[]),
  # the move IS real. Yield the inner MoveNode so the dataflow sees the
  # consumption. Without this, BG fibers can't transfer @list ownership
  # because the type-adapter CopyNode hides the user's GIVE.
  def walk_expr_skip_copy(node, &block)
    return unless node
    yield node
    case node
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      if node.is_a?(AST::CopyNode) && node.value.is_a?(AST::MoveNode)
        walk_expr_skip_copy(node.value, &block)
      end
      # Otherwise: COPY/FREEZE does not consume the source.
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
      elsif arg.is_a?(AST::CopyNode) || arg.is_a?(AST::CloneNode) || arg.is_a?(AST::FreezeNode)
        # COPY/FREEZE: the source IS read (must be live to copy/freeze from).
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

    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      # COPY/FREEZE x: x IS read (must be live to copy/freeze from).
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
    when AST::WhileLoop, AST::WhileBindLoop
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
      # When the loop rewinds, backing-store extensions of OUTER frame containers
      # are corrupted — for ANY mutation in this loop's iteration, including
      # ones buried inside nested loops or other nested control-flow. The frame
      # arena is fiber-wide; nested loops share it with the enclosing loop.
      #
      # Authoritative locality data is already on each Identifier: the
      # annotator set `ident.symbol.reg` to the variable's declaration AST
      # node. So "is this receiver outer to the loop?" reduces to "is the
      # declaration node OUTSIDE this loop's body subtree?" — no string-name
      # matching, no ad-hoc scope tracking.
      promote_outer_mutations!(body)
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
        ti = Type.from_node(s)
        next unless ti
        is_frame = ti.frame_provenance? && (ti.list_collection? || ti.map? || ti.string?)
        decls << s if is_frame && s.name.is_a?(String)
      when AST::BindExpr
        ti = Type.from_node(s)
        next unless ti
        is_frame = ti.frame_provenance? && (ti.list_collection? || ti.map? || ti.string?)
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

  # Walk the loop body subtree once. For each mutates_receiver call, ask the
  # symbol table where the receiver was declared and promote it to heap if
  # the declaration is outside this loop's body.
  #
  # Identity check via `ident.symbol.reg` (set by the annotator) is the
  # authoritative locality answer — no need to re-derive it from string-name
  # matching against a recomputed local_names set.
  def self.promote_outer_mutations!(body)
    # Pre-collect the declaration AST nodes that live anywhere within this
    # loop's subtree. AST.walk_body is the existing deep walker; we only
    # need to skip FunctionDef nodes, which are a different frame arena.
    local_decls = Set.new
    AST.walk_body(body) do |n|
      next if n.is_a?(AST::FunctionDef)
      case n
      when AST::VarDecl
        local_decls << n.object_id
      when AST::BindExpr
        local_decls << n.object_id if n.mode == :decl
      end
    end

    AST.walk_body(body) do |n|
      next if n.is_a?(AST::FunctionDef)
      next unless n.respond_to?(:mutates_receiver) && n.mutates_receiver
      receiver = case n
                 when AST::MethodCall then n.object
                 when AST::FuncCall   then n.args&.first
                 end
      next unless receiver.is_a?(AST::Identifier)
      decl = receiver.symbol&.reg
      next if decl.nil? || local_decls.include?(decl.object_id)
      promote_to_heap!(receiver)
    end
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
    # COPY/CLONE produce a detached value/handle -- carry var doesn't need promotion
    return false if expr.is_a?(AST::CopyNode) || expr.is_a?(AST::CloneNode) || expr.is_a?(AST::FreezeNode)
    # Any call (stdlib or user-defined) that returns a String may produce a
    # carry value needing heap promotion. This covers both stdlib_allocates=true
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
      # Identifiers are already handled by :dupe_string_literal in lower_indexed_assignment
      # (for map puts) and are a no-op for struct fields -- skip them to avoid double-dupe.
      next if val.is_a?(AST::Identifier)
      val_ti = val.type_info rescue nil
      next unless val_ti.is_a?(Type) && val_ti.string?
      # Promote the value expression so the concat/dupe uses heapAlloc.
      promote_value_to_heap!(val)
    end
  end

  # Set storage=:heap on an expression node so it uses heapAlloc.
  # Handles BinaryOp, StringConcat, FuncCall/MethodCall (via heap_dupe_result),
  # and nodes with a direct storage= accessor.
  def self.promote_value_to_heap!(node)
    return unless node
    ti = node.type_info rescue nil
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    return unless ti&.string?
    return if ti.heap_provenance?  # already heap
    case node
    when AST::BinaryOp
      if node.string_concat
        node.storage = :heap
        ti.provenance = :heap
      else
        promote_value_to_heap!(node.left)
        promote_value_to_heap!(node.right)
      end
    when AST::StringConcat
      node.storage = :heap
      ti.provenance = :heap
    when AST::FuncCall, AST::MethodCall
      node.heap_dupe_result = true
      ti.provenance = :heap
    when AST::Identifier
      # Identifier referencing a frame string: mark for heap dupe at the assignment
      # site rather than promoting the declaration (which would cause double-free
      # if the declaration's scope is shorter than the carry variable's scope).
      node.heap_dupe_result = true
      ti.provenance = :heap
    else
      if node.respond_to?(:storage=)
        node.storage = :heap
        ti.provenance = :heap
      end
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
      when AST::WhileLoop, AST::WhileBindLoop, AST::ForRange, AST::ForEach, AST::FunctionDef
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

  # Deep walk that descends into all struct children, including BinaryOp and
  # DoBlock branches (which are Arrays of Hashes with :body keys).
  # AST.walk_body only recurses into control-flow nodes; pipeline BinaryOp
  # chains are not in that list, so ConcurrentOp nested inside them is missed.
  def self.walk_all_nodes(nodes, visited = Set.new, &block)
    return unless nodes
    nodes = [nodes] unless nodes.is_a?(Array)
    nodes.each do |node|
      case node
      when AST::Locatable
        next unless visited.add?(node.object_id)
        yield node
        next unless node.class.respond_to?(:members)
        node.class.members.each do |m|
          child = node.send(m) rescue next
          walk_all_nodes(child, visited, &block) if child
        end
      when Array
        walk_all_nodes(node, visited, &block)
      when Hash
        # DoBlock branches: { label:, body: [...] } and similar hash-wrapped bodies
        node.each_value { |v| walk_all_nodes(v, visited, &block) if v }
      end
    end
  end

  # Walk for pipeline nodes that carry a shard_context and update
  # key_allocates_frame / body_allocates_frame.
  def self.update_shard_contexts!(body, fn_nodes)
    walk_all_nodes(body) do |node|
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
      # uses_frame=true means the function frame-allocates internally (e.g. intToString
      # intermediates). Even when return_provenance=:heap (string heap-dup on return),
      # those intermediate frame allocations accumulate in the caller's frame arena.
      # The SHARD loop must saveLoopMark/restoreLoopMark to rewind them each iteration.
      fn&.uses_frame ? true : false
    when AST::MethodCall
      false  # method calls on types are not frame-allocating routing keys
    else
      false
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
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      # COPY/FREEZE does NOT move the source.
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
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode then return
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


# MIRPass is defined in mir_pass.rb (extracted for T2).
require_relative "mir_pass"
