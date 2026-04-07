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
#   3. MIRPass: reads CleanupPlan/PromotionPlan results and inserts MIR nodes
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
  def self.build(fn_node)
    cfg = new(fn_node.name)
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
        current_block.stmts << stmt
      end
    end
    current_block  # return the current block for fall-through edges
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

    # Worklist: process blocks until no exit state changes.
    worklist = [@cfg.entry]
    in_worklist = { @cfg.entry.id => true }

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
  def self.analyze(fn_node)
    cfg = FunctionCFG.build(fn_node)
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
      collect_consumed(stmt.value, state).each { |n| state[n] = MOVED }
      state[stmt.name.to_s] = OWNED

    when AST::BindExpr
      collect_consumed(stmt.value, state).each { |n| state[n] = MOVED }
      state[stmt.name.to_s] = OWNED if stmt.mode == :decl

    when AST::Assignment
      collect_consumed(stmt.value, state).each { |n| state[n] = MOVED }

    when AST::ReturnNode
      collect_consumed(stmt.value, state).each { |n| state[n] = MOVED }

    when AST::FuncCall
      collect_consumed(stmt, state).each { |n| state[n] = MOVED }

    when AST::MethodCall
      collect_consumed(stmt, state).each { |n| state[n] = MOVED }

    when AST::IfStatement, AST::WhileLoop, AST::ForRange, AST::ForEach, AST::MatchStatement
      # Control flow headers: only process condition/expr for moves.
      # Branch bodies are in separate basic blocks (handled by CFG edges).
      cond = case stmt
             when AST::IfStatement then stmt.condition
             when AST::WhileLoop then stmt.condition
             when AST::MatchStatement then stmt.expr
             when AST::ForRange then nil  # range bounds don't move
             when AST::ForEach then stmt.collection
             end
      collect_consumed(cond, state).each { |n| state[n] = MOVED } if cond

      # ForEach/ForRange: loop variable is owned in the body block.
      if stmt.is_a?(AST::ForRange) || stmt.is_a?(AST::ForEach)
        state[stmt.var_name.to_s] = OWNED
      end
    end
  end

  # Collect identifiers consumed (moved) by an expression.
  # Two kinds of moves:
  #   1. Explicit: annotator set was_moved = true (TAKES args, GIVE)
  #   2. Implicit: non-Copy owned identifier used as RHS value (affine move)
  # Copy types (primitives, strings, enums) are never moved regardless of was_moved.
  def collect_consumed(node, state)
    return [] unless node
    consumed = []
    walk_expr(node) do |n|
      next unless n.is_a?(AST::Identifier)
      name = n.name.to_s
      next unless state[name] # only track variables we're analyzing
      next if copy_type?(n)   # Copy types are never consumed
      consumed << name if n.was_moved || non_copy_type?(n)
    end
    consumed
  end

  # Returns true if this identifier's type is Copy (no move on assignment).
  # Primitives, strings, enums, and :Any are Copy.
  def copy_type?(ident)
    ti = ident.type_info rescue nil
    return true unless ti  # unknown type, assume Copy (safe)
    ti = Type.new(ti) if !ti.is_a?(Type)
    ti.primitive? || ti.string? || ti.any? || ti.void?
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
      node.pairs&.each { |p| walk_expr(p[:value], &block) }
    when AST::CopyNode
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
  def initialize(cleanup_plans:, promotion_plans:)
    @cleanup_plans = cleanup_plans || {}
    @promotion_plans = promotion_plans || {}
  end

  # Mutates the AST in place, inserting MIR nodes into statement lists.
  def transform!(ast)
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef) && stmt.body
      transform_function!(stmt)
    end
  end

  private

  def transform_function!(fn)
    cleanup = @cleanup_plans[fn.name]
    promo = @promotion_plans[fn.name]
    return unless cleanup || promo

    fn.body = transform_body(fn.body, cleanup, promo)
  end

  # Recursively transform a statement list, inserting MIR nodes.
  # Returns a new array (does not mutate the input).
  def transform_body(stmts, cleanup, promo)
    return stmts unless stmts.is_a?(Array)
    result = []
    stmts.each do |stmt|
      # Recurse into nested control flow first.
      recurse_branches!(stmt, cleanup, promo)

      # Insert Promote + SuppressCleanup before ReturnNode.
      insert_promotion!(result, stmt, promo) if stmt.is_a?(AST::ReturnNode)

      # Emit the original statement.
      result << stmt

      # Insert Drop after VarDecl / BindExpr (decl mode).
      insert_drop!(result, stmt, cleanup)
    end
    result
  end

  # Recurse into control flow branches to transform nested bodies.
  def recurse_branches!(stmt, cleanup, promo)
    case stmt
    when AST::IfStatement
      stmt.then_branch = transform_body(stmt.then_branch, cleanup, promo) if stmt.then_branch
      stmt.else_branch = transform_body(stmt.else_branch, cleanup, promo) if stmt.else_branch
    when AST::WhileLoop
      stmt.do_branch = transform_body(stmt.do_branch, cleanup, promo) if stmt.do_branch
    when AST::ForRange, AST::ForEach
      stmt.body = transform_body(stmt.body, cleanup, promo) if stmt.body
    when AST::MatchStatement
      stmt.cases&.each { |c| c[:body] = transform_body(c[:body], cleanup, promo) if c[:body] }
      if stmt.default_case
        stmt.default_case = transform_body(stmt.default_case, cleanup, promo)
      end
    when AST::WithBlock
      stmt.body = transform_body(stmt.body, cleanup, promo) if stmt.body
    when AST::DoBlock
      stmt.branches&.each do |b|
        b[:body] = transform_body(b[:body], cleanup, promo) if b[:body]
      end
    when AST::BgBlock, AST::BgStreamBlock
      stmt.body = transform_body(stmt.body, cleanup, promo) if stmt.body
    end
  end

  # Insert a MIR::Drop after a variable declaration that needs cleanup.
  def insert_drop!(result, stmt, cleanup)
    return unless cleanup
    name = case stmt
           when AST::VarDecl then stmt.name.to_s
           when AST::BindExpr then stmt.mode == :decl ? stmt.name.to_s : nil
           else nil
           end
    return unless name

    entry = cleanup.lookup(name)
    return unless entry && entry[:needs_cleanup]

    drop = MIR::Drop.new(
      stmt.token, name, entry[:kind], entry[:alloc],
      entry[:has_moved_guard], stmt.type_info, entry[:resource_close_zig],
      stmt
    )
    result << drop
  end

  # Insert MIR::Promote and MIR::SuppressCleanup before a return statement.
  def insert_promotion!(result, ret_node, promo)
    return unless promo && !promo.empty?

    filtered = promo.filter_for_return(ret_node.value)

    # Per-variable promotions.
    filtered.var_promotes.each do |vp|
      strategy = classify_promote_strategy(vp[:zig_type])
      result << MIR::Promote.new(ret_node.token, vp[:var], vp[:zig_type], strategy, nil)
    end

    # Struct-level promotion (promoteFields on __ret).
    if filtered.struct_promote && filtered.needs_promote?(ret_node)
      result << MIR::Promote.new(
        ret_node.token, "__ret", filtered.struct_promote,
        :fields, filtered.unhandled_promote_fields
      )
    end

    # Suppress cleanup for variables whose ownership transfers to caller.
    filtered.suppress_defers.each do |name|
      result << MIR::SuppressCleanup.new(ret_node.token, name)
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
