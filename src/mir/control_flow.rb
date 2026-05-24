# typed: strict
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
#   3. MIRPass: runs CleanupClassifier, inserts MIR nodes
#      (Drop, Promote, SuppressCleanup) into AST statement lists. The transpiler
#      consumes MIR::Drop for variable cleanup. Promote/SuppressCleanup are
#      inserted but not yet consumed.
#
# Runs AFTER annotation + plan computation, BEFORE transpilation.

require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../annotator-helpers/function_signature"
require_relative "cleanup_entry"

# ==========================================
# CFG - Control Flow Graph (analysis only)
# ==========================================

class BasicBlock
    extend T::Sig

  attr_accessor :id, :stmts, :successors, :predecessors

  sig { params(id: Integer).void }
  def initialize(id)
    @id = id
    @stmts = T.let([], T::Array[T.untyped])
    @successors = T.let([], T::Array[T.untyped])
    @predecessors = T.let([], T::Array[T.untyped])
  end

  sig { params(block: BasicBlock).void }
  def add_successor(block)
    @successors << block unless @successors.include?(block)
    block.predecessors << self unless block.predecessors.include?(self)
  end

  sig { void }
  def terminator
    @stmts.last
  end
end

class FunctionCFG
    extend T::Sig

  attr_reader :blocks, :entry, :exit_block, :fn_name

  sig { params(fn_name: String).void }
  def initialize(fn_name)
    @fn_name = fn_name
    @blocks = T.let([], T::Array[T.untyped])
    @block_counter = T.let(0, Integer)
    @entry = T.let(new_block, BasicBlock)
    @exit_block = T.let(new_block, BasicBlock)  # virtual exit - all returns target this
  end

  sig { returns(BasicBlock) }
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
  sig { params(fn_node: AST::FunctionDef, can_fail_fns: T.nilable(T::Set[String])).returns(FunctionCFG) }
  def self.build(fn_node, can_fail_fns: nil)
    cfg = new(fn_node.name)
    cfg.instance_variable_set(:@can_fail_fns, can_fail_fns)
    last_block = build_body(fn_node.body || [], cfg.entry, cfg.exit_block, cfg)
    # Connect fall-through to exit (implicit return at end of function).
    last_block.add_successor(cfg.exit_block) if last_block
    cfg
  end

  private

  sig do
    params(stmts: T::Array[T.untyped], current_block: BasicBlock, exit_target: BasicBlock,
           cfg: FunctionCFG, break_target: T.nilable(BasicBlock),
           continue_target: T.nilable(BasicBlock)).returns(T.nilable(BasicBlock))
  end
  def self.build_body(stmts, current_block, exit_target, cfg, break_target: nil, continue_target: nil)
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

        then_exit = build_body(stmt.then_branch || [], then_block, exit_target, cfg,
                               break_target: break_target, continue_target: continue_target)
        then_exit.add_successor(join_block) if then_exit

        if stmt.else_branch
          else_exit = build_body(stmt.else_branch, T.must(else_block), exit_target, cfg,
                                 break_target: break_target, continue_target: continue_target)
          else_exit.add_successor(join_block) if else_exit
        end

        current_block = join_block

      when AST::WhileLoop
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block

        current_block.add_successor(body_block)   # enter loop
        current_block.add_successor(after_block)   # skip loop

        body_exit = build_body(stmt.do_branch || [], body_block, exit_target, cfg,
                               break_target: after_block, continue_target: current_block)
        body_exit&.add_successor(current_block)    # loop back

        current_block = after_block

      when AST::ForRange, AST::ForEach
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block

        current_block.add_successor(body_block)
        current_block.add_successor(after_block)

        body_exit = build_body(stmt.body, body_block, exit_target, cfg,
                               break_target: after_block, continue_target: current_block)
        body_exit&.add_successor(current_block)    # loop back

        current_block = after_block

      when AST::MatchStatement
        current_block.stmts << stmt
        join_block = cfg.new_block

        stmt.cases.each do |c|
          case_block = cfg.new_block
          current_block.add_successor(case_block)
          case_exit = build_body(c.body, case_block, exit_target, cfg,
                                 break_target: break_target, continue_target: continue_target)
          case_exit.add_successor(join_block) if case_exit
        end
        if stmt.default_case
          default_block = cfg.new_block
          current_block.add_successor(default_block)
          default_exit = build_body(stmt.default_case, default_block, exit_target, cfg,
                                    break_target: break_target, continue_target: continue_target)
          default_exit.add_successor(join_block) if default_exit
        end

        current_block = join_block

      when AST::WithBlock
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block
        current_block.add_successor(body_block)
        current_block.add_successor(after_block)  # WITH can fail to acquire
        body_exit = build_body(stmt.body, body_block, exit_target, cfg,
                               break_target: break_target, continue_target: continue_target)
        body_exit.add_successor(after_block) if body_exit
        current_block = after_block

      when AST::DoBlock
        current_block.stmts << stmt
        join_block = cfg.new_block
        stmt.branches.each do |b|
          branch_block = cfg.new_block
          current_block.add_successor(branch_block)
          branch_exit = build_body(b[:body] || [], branch_block, exit_target, cfg,
                                   break_target: break_target, continue_target: continue_target)
          branch_exit.add_successor(join_block) if branch_exit
        end
        current_block.add_successor(join_block)  # fallthrough if no branches
        current_block = join_block

      when AST::BgBlock, AST::BgStreamBlock
        current_block.stmts << stmt
        body_block = cfg.new_block
        after_block = cfg.new_block
        current_block.add_successor(body_block)
        current_block.add_successor(after_block)
        build_body(stmt.body, body_block, exit_target, cfg,
                   break_target: break_target, continue_target: continue_target)
        # BG body runs in separate fiber -- no fall-through back to parent
        current_block = after_block

      when AST::ReturnNode
        current_block.stmts << stmt
        current_block.add_successor(cfg.exit_block)
        return nil  # no fall-through after return

      when AST::Raise
        current_block.stmts << stmt
        current_block.add_successor(cfg.exit_block)
        return nil  # no fall-through after raise

      when AST::BreakNode
        current_block.stmts << stmt
        current_block.add_successor(break_target) if break_target
        return nil

      when AST::ContinueNode
        current_block.stmts << stmt
        current_block.add_successor(continue_target) if continue_target
        return nil

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
  sig { params(node: T.untyped, can_fail_fns: T::Set[String]).returns(T::Boolean) }
  def self.stmt_can_fail?(node, can_fail_fns)
    return false unless node
    case node
    when AST::FuncCall
      return true if node.can_fail
      return true if can_fail_fns.include?(node.name)
      node.args.any? { |a| stmt_can_fail?(a, can_fail_fns) }
    when AST::MethodCall
      return true if node.can_fail
      return true if can_fail_fns.include?(node.name)
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
    when AST::Raise, AST::OrRaise
      true
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
    extend T::Sig

  UNINIT      = :uninit
  OWNED       = :owned
  MOVED       = :moved
  MAYBE_MOVED = :maybe_moved

  # Per-walk state for collect_ownership_transfers and friends. Reek
  # flagged the (state, consumed) carry-down across 5+ methods.
  # `state` (Hash) and `consumed` (Set) are both mutable; the Data
  # wrapper is frozen but the inner collections are not.
  DataflowStep = Struct.new(:state, :consumed, keyword_init: true) do
    extend T::Sig

    sig { params(state: T.untyped, consumed: T.untyped).void }
    def initialize(state:, consumed:)
      super
    end

    sig { returns(T.untyped) }
    def state
      self[:state]
    end

    sig { returns(T.untyped) }
    def consumed
      self[:consumed]
    end
  end

  # Enriched ownership entry: carries allocator and cleanup info alongside state.
  # Equality is based on :state only (for fixpoint convergence -- allocator and
  # needs_cleanup are immutable properties set at declaration, never change).
  OwnerEntry = Struct.new(:state, :allocator, :needs_cleanup, keyword_init: true) do
    extend T::Sig
    sig { params(other: T.anything).returns(T::Boolean) }
    def ==(other)
      case other
      when OwnerEntry then state == other.state
      when Symbol     then state == other  # backward compat with raw symbols
      else false
      end
    end
    alias_method :eql?, :==

    sig { returns(Integer) }
    def hash
      state.hash
    end
  end

  attr_reader :block_in, :block_out, :point_states

  sig { params(cfg: FunctionCFG, fn_node: AST::FunctionDef, schema_lookup: T.nilable(Proc)).void }
  def initialize(cfg, fn_node, schema_lookup: nil)
    @cfg = cfg
    @fn_node = fn_node
    @schema_lookup = schema_lookup
    @block_in  = T.let({}, T::Hash[T.untyped, T.untyped])  # block.id => { var_name => OwnerEntry }
    @block_out = T.let({}, T::Hash[T.untyped, T.untyped])  # block.id => { var_name => OwnerEntry }
    @point_states = T.let({}, T::Hash[T.untyped, T.untyped]) # [block.id, stmt_index] => { var_name => OwnerEntry }
  end

  # Run the forward dataflow to fixpoint. Returns self for chaining.
  sig { returns(OwnershipDataflow) }
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
  sig { returns(T::Hash[String, OwnershipDataflow::OwnerEntry]) }
  def exit_states
    @block_in[@cfg.exit_block.id] || {}
  end

  # Per-variable summary: { name => { needs_cleanup: bool, has_moved_guard: bool } }
  # Backward-compatible: reads .state from OwnerEntry.
  sig { returns(T::Hash[String, T::Hash[Symbol, T::Boolean]]) }
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
  sig { params(fn_node: AST::FunctionDef, bindings: T::Hash[String, CleanupEntry]).returns(T::Hash[String, CleanupEntry]) }
  def cleanup_decisions!(fn_node, bindings)
    summary = cleanup_summary

    # Rule 1: Use-after-move check.
    checker = UseAfterMoveChecker.new(fn_node, self)
    checker.check!
    unless checker.errors.empty?
      raise "[Ownership Error] #{checker.errors.first}"
    end

    bindings.each do |var, entry|
      next unless entry.needs_cleanup?
      block_entry = block_exit_cleanup_summary(var)
      df_entry = if block_entry && !block_entry[:needs_cleanup]
        block_entry
      else
        summary[var] || block_entry
      end
      next unless df_entry # variable not tracked by dataflow - keep plan

      if !df_entry[:needs_cleanup]
        # Moved on ALL paths -> normally no cleanup needed.
        # Exception: MATCH TAKES unions need the defer with a moved guard.
        if entry.kind == :takes_union || match_takes_var?(fn_node, var)
          entry[:has_moved_guard] = true
        elsif declared_inside_loop?(fn_node.body || [], var)
          entry[:has_moved_guard] = true
        else
          entry[:needs_cleanup] = false
          entry[:has_moved_guard] = false
        end
      elsif !df_entry[:has_moved_guard] && entry.has_moved_guard?
        # Never moved on any path -> unconditional cleanup, no guard.
        entry[:has_moved_guard] = false
      elsif df_entry[:has_moved_guard] && !entry.has_moved_guard?
        # Moved on at least one path -> guard cleanup and let SuppressCleanup
        # mark the transfer at the consuming statement.
        entry[:has_moved_guard] = true
      end
    end
  end

  sig { params(stmts: T::Array[T.untyped], var: String).returns(T::Boolean) }
  def linear_scope_decl_always_moves?(stmts, var)
    stmts.each_with_index do |stmt, idx|
      if declares_name?(stmt, var)
        return stmts[(idx + 1)..].to_a.any? { |s| stmt_moves_name?(s, var) }
      end

      nested = case stmt
               when AST::WhileLoop
                 stmt.do_branch
               when AST::ForRange, AST::ForEach
                 stmt.body
               when AST::IfStatement
                 [stmt.then_branch, stmt.else_branch].compact.flatten
               when AST::MatchStatement
                 bodies = stmt.cases.flat_map { |c| c.respond_to?(:body) ? c.body : [] }
                 stmt.default_case ? bodies + stmt.default_case : bodies
               else
                 []
               end
      return true if !nested.empty? && linear_scope_decl_always_moves?(nested, var)
    end
    false
  end

  sig { params(stmt: T.untyped, var: String).returns(T::Boolean) }
  def declares_name?(stmt, var)
    (stmt.is_a?(AST::VarDecl) || (stmt.is_a?(AST::BindExpr) && stmt.mode == :decl)) &&
      stmt.name.to_s == var
  end

  sig { params(stmt: T.untyped, var: String).returns(T::Boolean) }
  def stmt_moves_name?(stmt, var)
    return false if stmt.is_a?(AST::ReturnNode)
    state = { var => OwnerEntry.new(state: OWNED, allocator: :heap, needs_cleanup: true) }
    collect_binding_moves(stmt, state).include?(var) ||
      collect_explicit_moves(stmt, state).include?(var) ||
      (AST.call?(stmt) && collect_bg_captures_in_args(stmt, state).include?(var))
  end

  sig { params(var: String).returns(T.nilable(T::Hash[Symbol, T::Boolean])) }
  def block_exit_cleanup_summary(var)
    states = @block_out.values.filter_map do |state|
      entry = state[var]
      entry if entry.is_a?(OwnerEntry)
    end
    return nil if states.empty?

    moved = states.any? { |entry| entry.state == MOVED } &&
            states.none? { |entry| entry.state == MAYBE_MOVED }
    maybe = states.any? { |entry| entry.state == MAYBE_MOVED }
    {
      needs_cleanup: !moved,
      has_moved_guard: maybe || (!moved && states.any? { |entry| entry.state == MOVED }),
    }
  end

  private

  sig { params(stmts: T::Array[T.untyped], var_name: String, loop_depth: Integer).returns(T::Boolean) }
  def declared_inside_loop?(stmts, var_name, loop_depth: 0)
    stmts.any? do |stmt|
      return true if loop_depth.positive? && declares_name?(stmt, var_name)
      case stmt
      when AST::WhileLoop, AST::WhileBindLoop
        declared_inside_loop?(stmt.do_branch || [], var_name, loop_depth: loop_depth + 1)
      when AST::ForRange, AST::ForEach
        declared_inside_loop?(stmt.body || [], var_name, loop_depth: loop_depth + 1)
      when AST::IfStatement
        declared_inside_loop?(stmt.then_branch || [], var_name, loop_depth: loop_depth) ||
          declared_inside_loop?(stmt.else_branch || [], var_name, loop_depth: loop_depth)
      when AST::MatchStatement
        stmt.cases.any? { |c| declared_inside_loop?(c.body || [], var_name, loop_depth: loop_depth) } ||
          declared_inside_loop?(stmt.default_case || [], var_name, loop_depth: loop_depth)
      when AST::WithBlock
        declared_inside_loop?(stmt.body || [], var_name, loop_depth: loop_depth)
      when AST::DoBlock
        stmt.branches.any? { |b| declared_inside_loop?(b[:body] || [], var_name, loop_depth: loop_depth) }
      else
        false
      end
    end
  end

  # Returns true if the given variable is the subject of a MATCH TAKES statement.
  sig { params(fn_node: AST::FunctionDef, var_name: String).returns(T::Boolean) }
  def match_takes_var?(fn_node, var_name)
    found = T.let(false, T::Boolean)
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
  sig { params(fn_node: AST::FunctionDef, can_fail_fns: T.nilable(T::Set[String]), schema_lookup: T.nilable(Proc)).returns(OwnershipDataflow) }
  def self.analyze(fn_node, can_fail_fns: nil, schema_lookup: nil)
    cfg = FunctionCFG.build(fn_node, can_fail_fns: can_fail_fns)
    new(cfg, fn_node, schema_lookup: schema_lookup).analyze!
  end

  private

  # TAKES params start as :owned (callee must clean them up).
  # TAKES params are always heap-allocated (caller passes heap ownership).
  sig { returns(T::Hash[String, OwnershipDataflow::OwnerEntry]) }
  def init_entry_state
    state = {}
    @fn_node.params.each do |p|
      next unless p.takes
      name = p.name.to_s
      ti = p.type || Type.new(:Any)
      needs = ti ? ti.needs_explicit_cleanup?(:heap, @schema_lookup) : true
      state[name] = OwnerEntry.new(state: OWNED, allocator: :heap, needs_cleanup: needs)
    end
    state
  end

  # Merge predecessor exit states. Variables present on any path are joined.
  sig { params(block: BasicBlock).returns(T::Hash[String, OwnershipDataflow::OwnerEntry]) }
  def join_predecessors(block)
    preds = block.predecessors
    return {} if preds.empty?

    result = dup_state(@block_out[preds.first.id])
    preds.drop(1).each do |pred|
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
  sig { params(a: T.nilable(OwnershipDataflow::OwnerEntry), b: T.nilable(OwnershipDataflow::OwnerEntry)).returns(T.any(OwnershipDataflow::OwnerEntry, Symbol)) }
  def join_entry(a, b)
    return T.must(b) if a.nil?
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

  sig { params(a: Symbol, b: Symbol).returns(Symbol) }
  def join_state(a, b)
    return b if a == UNINIT
    return a if b == UNINIT
    return a if a == b
    MAYBE_MOVED
  end

  # Process all statements in a block, updating the state map.
  # Stores per-statement snapshots in @point_states.
  sig { params(block: BasicBlock, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T::Hash[String, OwnershipDataflow::OwnerEntry]) }
  def apply_transfer(block, state)
    block.stmts.each_with_index do |stmt, idx|
      transfer_stmt(stmt, state)
      @point_states[[block.id, idx]] = dup_state(state)
    end
    state
  end

  # Transition a variable to :moved, preserving OwnerEntry metadata.
  sig { params(state: T::Hash[String, T.untyped], name: String).returns(T.any(OwnershipDataflow::OwnerEntry, Symbol)) }
  def mark_moved!(state, name)
    existing = state[name]
    if existing.is_a?(OwnerEntry)
      state[name] = OwnerEntry.new(state: MOVED, allocator: existing.allocator, needs_cleanup: existing.needs_cleanup)
    else
      state[name] = MOVED
    end
  end

  # Create an OwnerEntry for a new declaration from its type info.
  sig { params(node: T.untyped).returns(OwnershipDataflow::OwnerEntry) }
  def make_owner_entry(node)
    ti = Type.from_node(node)
    is_heap = node.is_a?(AST::Locatable) && node.heap_storage?
    allocator = ti ? ((ti.provenance_alloc rescue nil) || (is_heap ? :heap : :frame)) : :frame
    needs = ti ? (ti.needs_explicit_cleanup?(allocator, @schema_lookup) rescue false) : false
    OwnerEntry.new(state: OWNED, allocator: allocator, needs_cleanup: needs)
  end

  # Single source for "the resource captures of a BG node" (empty when
  # the node has no capture_analysis or no resource captures). Collapses
  # the `resource_captures(x).each` decision-pressure
  # chain that decomplex flagged as recomputed across the capture_analysis
  # root-cause cluster (transfer_stmt / collect_ownership_transfers /
  # _walk_bg_captures_in_expr / collect_bg_body_gives + siblings).
  sig { params(node: T.untyped).returns(T::Enumerable[T.untyped]) }
  def resource_captures(node)
    node.capture_analysis&.resource_captures || []
  end

  # Transfer function for a single statement.
  sig { params(stmt: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T.untyped) }
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
      resource_captures(stmt).each do |name|
        mark_moved!(state, name) if state[name]
      end
      # User-written GIVE x inside the BG body (where x is a captured
      # outer binding) transfers ownership out of the outer scope too.
      # COPY/CLONE do NOT consume — those deep-copy / rc-clone.
      collect_bg_body_gives(stmt).each do |name|
        mark_moved!(state, name) if state[name]
      end
    else
      collect_explicit_moves(stmt, state).each { |n| mark_moved!(state, n) }
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
  sig { params(node: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T::Array[String]) }
  def collect_binding_moves(node, state)
    return [] unless node
    step = DataflowStep.new(state: state, consumed: Set.new)
    collect_ownership_transfers(node, step)
    step.consumed.to_a
  end

  # Recursively find ownership-transferring identifiers.
  sig { params(node: T.untyped, step: OwnershipDataflow::DataflowStep).returns(T.untyped) }
  def collect_ownership_transfers(node, step)
    return unless node

    case node
    when AST::Identifier
      name = node.name.to_s
      return unless step.state[name]
      return if copy_type?(node) # Copy types are never consumed
      step.consumed << name

    when AST::StructLit
      node.fields&.each_value { |v| collect_ownership_transfers(v, step) }

    when AST::MethodCall
      # Union constructors: U.Variant(payload) - payload transfers ownership.
      # Regular method calls in binding RHS: only was_moved args.
      # Distinguish by token type: TYPE_ID = union constructor, VAR_ID = method call.
      if node.object.is_a?(AST::Identifier) && node.object.token&.type == :TYPE_ID
        node.args.each { |a| collect_ownership_transfers(a, step) }
      else
        collect_explicit_in(node, step)
      end

    when AST::FuncCall
      collect_explicit_in(node, step)

    when AST::ListLit
      node.items.each { |i| collect_ownership_transfers(i, step) }

    when AST::GetField
      if owning_field_move?(node)
        root = AST.root_identifier(node)
        step.consumed << root.name.to_s if root && step.state[root.name.to_s]
      else
        collect_explicit_in(node, step)
      end

    when AST::MoveNode
      inner = node.value
      if inner.is_a?(AST::Identifier)
        name = inner.name.to_s
        step.consumed << name if step.state[name]
      end

    when AST::ShareNode
      collect_share_transfer(node, step)

    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      # COPY / FREEZE do NOT move the source.

    when AST::CapabilityWrap
      # Unwrap: S{ field: x } @shared still consumes x.
      collect_ownership_transfers(node.value, step)

    when AST::BgBlock, AST::BgStreamBlock
      # Resources captured by BG fibers transfer ownership.
      resource_captures(node).each do |name|
        step.consumed << name if step.state[name]
      end
      # GIVE x inside the BG body moves the outer x into the fiber.
      collect_bg_body_gives(node).each do |name|
        step.consumed << name if step.state[name]
      end

    else
      collect_explicit_in(node, step)
    end
  end

  # Collect only was_moved identifiers from an expression subtree.
  # Skips CopyNode children: COPY wraps a was_moved identifier but the
  # source is NOT consumed (the copy is what transfers ownership).
  sig { params(node: T.untyped, step: OwnershipDataflow::DataflowStep).returns(T.untyped) }
  def collect_explicit_in(node, step)
    walk_expr_skip_copy(node) do |n|
      next unless n.is_a?(AST::Identifier) && n.was_moved
      name = n.name.to_s
      next unless step.state[name]
      next if copy_type?(n)
      step.consumed << name
    end
    collect_share_transfers_in(node, step)
  end

  # Collect only explicitly moved identifiers (was_moved set by annotator).
  # Used for function calls where non-TAKES args are borrowed, not moved.
  sig { params(node: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T::Array[String]) }
  def collect_explicit_moves(node, state)
    return [] unless node
    step = DataflowStep.new(state: state, consumed: Set.new)
    walk_expr_skip_copy(node) do |n|
      next unless n.is_a?(AST::Identifier) && n.was_moved
      name = n.name.to_s
      next unless step.state[name]
      next if copy_type?(n)
      step.consumed << name
    end
    collect_share_transfers_in(node, step)
    step.consumed.to_a
  end

  sig { params(node: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T::Array[String]) }
  def collect_map_store_moves(node, state)
    collect_binding_moves(node, state)
  end

  sig { params(node: T.untyped, step: OwnershipDataflow::DataflowStep).returns(T.untyped) }
  def collect_share_transfers_in(node, step)
    walk_expr(node) do |n|
      collect_share_transfer(n, step) if n.is_a?(AST::ShareNode)
    end
  end

  sig { params(node: AST::ShareNode, step: OwnershipDataflow::DataflowStep).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def collect_share_transfer(node, step)
    source = node.value
    return if source.is_a?(AST::CopyNode)

    if source.is_a?(AST::Identifier)
      ti = Type.from_node!(source, context: "share transfer")
      return if ti.shared?
      name = source.name.to_s
      step.consumed << name if step.state[name]
      return
    end

    collect_ownership_transfers(source, step)
  end

  # Collect resource captures from BG blocks nested in function/method call args.
  # Without this, the dataflow doesn't see ownership transfers via BG capture
  # when the BG block appears inside a MethodCall like tasks.append(BG { ... }).
  sig { params(stmt: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T::Array[String]) }
  def collect_bg_captures_in_args(stmt, state)
    consumed = []
    args = stmt.args || []
    args.each do |arg|
      _walk_bg_captures_in_expr(arg, state, consumed)
    end
    consumed
  end

  sig { params(expr: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry], consumed: T::Array[String]).returns(T.nilable(T::Array[T.untyped])) }
  def _walk_bg_captures_in_expr(expr, state, consumed)
    return unless expr
    case expr
    when AST::BgBlock, AST::BgStreamBlock
      resource_captures(expr).each do |name|
        consumed << name if state[name]
      end
      collect_bg_body_gives(expr).each do |name|
        consumed << name if state[name]
      end
    when AST::FuncCall
      expr.args.each { |a| _walk_bg_captures_in_expr(a, state, consumed) }
    when AST::MethodCall
      _walk_bg_captures_in_expr(expr.object, state, consumed)
      expr.args.each { |a| _walk_bg_captures_in_expr(a, state, consumed) }
    end
  end

  # Walks the BG body looking for `GIVE capture` (MoveNode wrapping an
  # Identifier whose name is in the BG's capture set). Each such GIVE
  # transfers ownership of the outer binding into the fiber. COPY/CLONE
  # do not consume — those paths deep-copy / rc-clone instead.
  #
  # Reads `bg.capture_analysis.move_mark_names` (computed once by
  # BgCaptureClassifier in the annotator). Previously this re-walked
  # the BG body via walk_expr_skip_copy + a dataflow-private MoveNode/
  # was_moved-CopyNode detector that drifted from the parallel
  # implementation in MIRPass._walk_expr_for_give (the 378036a0 class
  # of bug). Now there is one writer and three readers (this method,
  # MIRPass.insert_bg_give_suppress!, EscapeAnalysis), all reading the
  # same field.
  sig { params(bg_node: T.untyped).returns(T::Array[String]) }
  def collect_bg_body_gives(bg_node)
    bg_node.capture_analysis&.move_mark_names&.to_a || []
  end

  # Returns true if this identifier's type is Copy (no move on assignment).
  # Primitives, strings, enums, :Any, and RC types are Copy-like.
  # RC assignment is clone (rcRetain), not move. Only GIVE/MOVE transfers
  # ownership (handled by was_moved from the annotator).
  sig { params(ident: AST::Identifier).returns(T::Boolean) }
  def copy_type?(ident)
    ti = Type.from_node(ident)
    return true unless ti  # unknown type, assume Copy (safe)
    # Heap-allocated strings own their backing buffer; RETURN/move
    # transfers ownership to the receiver (just like a heap-allocated
    # collection or struct). Rodata / frame / param strings are still
    # treated as Copy — those don't own heap memory. Symbol#storage is
    # the canonical provenance (SIMP-13f) that EscapeAnalysis makes
    # definitive; read it, not the VarDecl node's annotation-time value.
    if ti.string? && ident.symbol&.heap_storage?
      return false
    end
    is_atomic_ptr = ti.atomic_ptr?
    ti.primitive? || ti.string? || ti.any? || ti.void? || (ti.any_rc? && !is_atomic_ptr)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def owning_field_move?(node)
    return false unless node.is_a?(AST::GetField)
    ti = Type.from_node(node)
    ti.is_a?(Type) && ti.indirect?
  rescue
    false
  end

  sig { params(node: T.untyped, block: T.untyped).returns(T.untyped) }
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
      node.args.each { |a| walk_expr(a, &block) }
    when AST::MethodCall
      walk_expr(node.object, &block)
      node.args.each { |a| walk_expr(a, &block) }
    when AST::GetField
      walk_expr(node.target, &block)
    when AST::GetIndex
      walk_expr(node.target, &block)
      walk_expr(node.index, &block)
    when AST::StructLit
      node.fields&.each_value { |v| walk_expr(v, &block) }
    when AST::ListLit
      node.items.each { |i| walk_expr(i, &block) }
    when AST::HashLit
      node.pairs.each { |_k, v| walk_expr(v.is_a?(Array) ? v[1] : v, &block) }
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      walk_expr(node.value, &block)
    when AST::ShareNode
      walk_expr(node.value, &block)
    when AST::MoveNode
      walk_expr(node.value, &block)
    when AST::CapabilityWrap
      walk_expr(node.value, &block)
    when AST::ReturnNode
      walk_expr(node.value, &block)
    when AST::Assert
      walk_expr(node.condition, &block)
    when AST::Assignment
      walk_expr(node.value, &block)
    when AST::VarDecl, AST::BindExpr
      walk_expr(node.value, &block)
    end
  end

  # Like walk_expr but does NOT recurse into CopyNode. CopyNode wraps
  # was_moved identifiers for implicit copies -- the source is NOT consumed.
  sig { params(node: T.untyped, block: T.untyped).returns(T.untyped) }
  def walk_expr_skip_copy(node, &block)
    return unless node
    yield node
    case node
    when AST::CopyNode, AST::CloneNode, AST::FreezeNode
      # Do not recurse: COPY/FREEZE does not consume the source.
    when AST::ShareNode
      walk_expr_skip_copy(node.value, &block)
    when AST::BinaryOp
      walk_expr_skip_copy(node.left, &block)
      walk_expr_skip_copy(node.right, &block)
    when AST::UnaryOp
      walk_expr_skip_copy(node.right, &block)
    when AST::FuncCall
      node.args.each { |a| walk_expr_skip_copy(a, &block) }
    when AST::MethodCall
      walk_expr_skip_copy(node.object, &block)
      node.args.each { |a| walk_expr_skip_copy(a, &block) }
    when AST::GetField
      walk_expr_skip_copy(node.target, &block)
    when AST::GetIndex
      walk_expr_skip_copy(node.target, &block)
      walk_expr_skip_copy(node.index, &block)
    when AST::StructLit
      node.fields&.each_value { |v| walk_expr_skip_copy(v, &block) }
    when AST::ListLit
      node.items.each { |i| walk_expr_skip_copy(i, &block) }
    when AST::HashLit
      node.pairs.each { |_k, v| walk_expr_skip_copy(v.is_a?(Array) ? v[1] : v, &block) }
    when AST::MoveNode
      walk_expr_skip_copy(node.value, &block)
    when AST::CapabilityWrap
      walk_expr_skip_copy(node.value, &block)
    when AST::ReturnNode
      walk_expr_skip_copy(node.value, &block)
    when AST::Assert
      walk_expr_skip_copy(node.condition, &block)
    when AST::Assignment
      walk_expr_skip_copy(node.value, &block)
    when AST::VarDecl, AST::BindExpr
      walk_expr_skip_copy(node.value, &block)
    end
  end

  sig { params(state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T::Hash[String, OwnershipDataflow::OwnerEntry]) }
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
    extend T::Sig

  attr_reader :errors

  sig { params(fn_node: T.untyped, dataflow: T.untyped).void }
  def initialize(fn_node, dataflow)
    @fn_node = fn_node
    @dataflow = dataflow
    @errors = T.let([], T::Array[T.untyped])
  end

  # Run the check. Returns self for chaining.
  sig { returns(UseAfterMoveChecker) }
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
  sig { params(fn_node: AST::FunctionDef, can_fail_fns: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Array[T.untyped]) }
  def self.check(fn_node, can_fail_fns: nil, schema_lookup: nil)
    df = OwnershipDataflow.analyze(fn_node, can_fail_fns: can_fail_fns, schema_lookup: schema_lookup)
    checker = new(fn_node, df)
    checker.check!
    checker.errors
  end

  private

  # Check all read positions in a statement for use-after-move.
  sig { params(stmt: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T.untyped) }
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
  sig { params(call_node: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T::Array[T.untyped]) }
  def check_call_reads(call_node, state)
    (call_node.args || []).each do |arg|
      if arg.is_a?(AST::Identifier) && arg.was_moved
        # This is a TAKES/GIVE arg -- the move itself is valid, not a read.
        next
      elsif arg.is_a?(AST::MoveNode)
        # GIVE wrapper: inner is being moved, not read.
        next
      elsif arg.is_a?(AST::ShareNode)
        check_share_reads(arg, state)
      elsif arg.is_a?(AST::CopyNode) || arg.is_a?(AST::CloneNode) || arg.is_a?(AST::FreezeNode)
        # COPY/FREEZE: the source IS read (must be live to copy/freeze from).
        check_reads_in_expr(arg.value, state)
      else
        check_reads_in_expr(arg, state)
      end
    end
  end

  # Recursively walk an expression, checking all Identifier reads.
  sig { params(node: T.untyped, state: T::Hash[String, OwnershipDataflow::OwnerEntry]).returns(T.untyped) }
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

    when AST::ShareNode
      check_share_reads(node, state)

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
      node.items.each { |i| check_reads_in_expr(i, state) }

    when AST::HashLit
      node.pairs.each { |_k, v|
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

  sig { params(node: AST::ShareNode, state: T::Hash[T.untyped, T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def check_share_reads(node, state)
    source = node.value
    if source.is_a?(AST::CopyNode)
      check_reads_in_expr(source.value, state)
    elsif source.is_a?(AST::Identifier)
      ti = Type.from_node!(source, context: "share read")
      check_identifier_read(source.name.to_s, state, source.token) if ti.shared?
    else
      check_reads_in_expr(source, state)
    end
  end

  # Check a single identifier read against the ownership state.
  sig { params(name: String, state: T::Hash[String, OwnershipDataflow::OwnerEntry], token: Lexer::Token).returns(T.nilable(T::Array[String])) }
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
# frame-alloc flags. Runs after CleanupClassifier has finalized every binding's
# allocator, before MIR node insertion.
#
# A loop is only a repeated scope boundary. It may request a per-iteration frame
# rewind when finalized cleanup facts prove every direct frame allocation in the
# loop is iteration-local. It must not infer escaping from method names or
# collection shapes.
#
module LoopFrameAnalysis

  extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }

  # Entry point.  Call once per pass, after CleanupClassifier.
  sig { params(fn_nodes: FnNodes, schema_lookup: T.nilable(Proc)).returns(FnNodes) }
  def self.analyze!(fn_nodes, schema_lookup = nil)
    fn_nodes.each_value do |fn|
      next unless fn.body
      walk_stmts!(fn.body, schema_lookup)
      update_shard_contexts!(fn.body, fn_nodes)
    end
  end

  # ── recursive AST walk ────────────────────────────────────────────────────

  sig { params(stmts: T.nilable(T::Array[T.untyped]), schema_lookup: T.nilable(Proc)).void }
  def self.walk_stmts!(stmts, schema_lookup = nil)
    return unless stmts.is_a?(Array)
    stmts.each { |s| walk_stmt!(s, schema_lookup) }
    nil
  end

  sig { params(stmt: T.untyped, schema_lookup: T.nilable(Proc)).void }
  def self.walk_stmt!(stmt, schema_lookup = nil)
    case stmt
    when AST::WhileLoop, AST::WhileBindLoop
      walk_stmts!(stmt.do_branch, schema_lookup)          # inner loops first
      process_loop!(stmt, stmt.do_branch, schema_lookup)
    when AST::ForRange
      walk_stmts!(stmt.body, schema_lookup)
      process_loop!(stmt, stmt.body, schema_lookup)
    when AST::ForEach
      walk_stmts!(stmt.body, schema_lookup)
      process_loop!(stmt, stmt.body, schema_lookup)
    when AST::IfStatement
      walk_stmts!(stmt.then_branch, schema_lookup)
      walk_stmts!(stmt.else_branch, schema_lookup)
    when AST::MatchStatement
      stmt.cases.each { |c| walk_stmts!(c.body, schema_lookup) }
      walk_stmts!(stmt.default_case, schema_lookup)
    when AST::WithBlock
      walk_stmts!(stmt.body, schema_lookup)
    when AST::DoBlock
      stmt.branches.each { |b| walk_stmts!(b[:body], schema_lookup) }
    end
    nil
  end

  # ── loop analysis ─────────────────────────────────────────────────────────

  sig { params(loop_node: T.untyped, body: T::Array[T.untyped], schema_lookup: T.nilable(Proc)).void }
  def self.process_loop!(loop_node, body, schema_lookup = nil)
    return if loop_node.tight
    local_names = collect_local_names(body)
    has_iteration_frame_locals = local_iteration_frame_decls(body, local_names).any? || loop_capture_frame_alloc?(loop_node, schema_lookup)
    has_extended_frame_locals = local_frame_decls(body, local_names).any? do |decl|
      entry = decl.respond_to?(:mir_binding_entry) ? decl.mir_binding_entry : nil
      entry&.present? && entry.alloc == :frame && entry.scope != :iteration
    end || outer_frame_receiver_alloc?(body, local_names)
    loop_node.mark_per_iter = has_iteration_frame_locals && !has_extended_frame_locals
    nil
  end

  sig { params(body: T::Array[T.untyped], local_names: T::Set[String]).returns(T::Boolean) }
  def self.outer_frame_receiver_alloc?(body, local_names)
    found = T.let(false, T::Boolean)
    scan_direct(body) do |node|
      next unless node.is_a?(AST::MethodCall)
      sig = node.respond_to?(:matched_signature) ? FunctionSignature.unwrap(node.matched_signature) : nil
      emit = sig&.emit
      next unless emit&.allocates && emit&.mutates_receiver
      root = AST.root_identifier(node.object)
      next unless root&.symbol
      next if local_names.include?(root.name.to_s)
      decl = root.symbol.respond_to?(:reg) ? root.symbol.reg : nil
      sym = (decl && decl.respond_to?(:symbol) && decl.symbol) || root.symbol
      found = true unless sym.heap_storage?
    end
    found
  end

  sig { params(loop_node: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  def self.loop_capture_frame_alloc?(loop_node, schema_lookup = nil)
    return false unless loop_node.is_a?(AST::WhileBindLoop)
    cond_t = Type.from_node(loop_node.condition)
    inner = cond_t&.wrapped_type
    return false unless inner.is_a?(Type)
    inner.needs_cleanup?(schema_lookup) && inner.cleanup_allocator(schema_lookup) == :frame
  rescue
    false
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Set[String]) }
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

  sig { params(body: T::Array[T.untyped], _local_names: T::Set[String]).returns(T::Array[T.untyped]) }
  def self.local_frame_decls(body, _local_names)
    decls = []
    scan_direct(body) do |s|
      case s
      when AST::VarDecl
        next unless s.name.is_a?(String)
        entry = s.respond_to?(:mir_binding_entry) ? s.mir_binding_entry : nil
        decls << s if binding_frame_allocates?(s, entry)
      when AST::BindExpr
        next unless s.mode == :decl && s.name.is_a?(String)
        entry = s.respond_to?(:mir_binding_entry) ? s.mir_binding_entry : nil
        decls << s if binding_frame_allocates?(s, entry)
      end
    end
    decls
  end

  sig { params(node: T.untyped, entry: T.nilable(CleanupEntry)).returns(T::Boolean) }
  def self.binding_frame_allocates?(node, entry)
    return false unless entry&.present? && entry.alloc == :frame
    return true if entry.needs_cleanup?
    value = node.respond_to?(:value) ? node.value : nil
    return false if value.nil?
    return false if value.is_a?(AST::Literal) || value.is_a?(AST::Identifier)
    true
  end

  sig { params(body: T::Array[T.untyped], local_names: T::Set[String]).returns(T::Array[T.untyped]) }
  def self.local_iteration_frame_decls(body, local_names)
    local_frame_decls(body, local_names).select do |decl|
      entry = decl.respond_to?(:mir_binding_entry) ? decl.mir_binding_entry : nil
      entry&.present? && entry.alloc == :frame && entry.scope == :iteration
    end
  end

  # Walk DIRECT body: yield each stmt, recurse into if/match/with but STOP at
  # nested loops and function definitions.
  #
  # `body` is always an Array (non-nil): a statement body. then_branch /
  # else_branch / WithBlock#body / DoBlock branch bodies are array
  # invariants (the parser uses `[]` for an absent else, never nil).
  # Only MatchStatement#default_case is `[ASTNode] or nil` by AST design
  # (ast.rb:1171) -- so that ONE recurse site is guarded here (mirrors
  # `bodies << default_case if default_case` in ast.rb). No nil ever
  # reaches scan_direct, so the contract sig is strictly non-nil.
  sig { params(body: T::Array[T.untyped], block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def self.scan_direct(body, &block)
    body.each do |s|
      yield s
      case s
      when AST::WhileLoop, AST::WhileBindLoop, AST::ForRange, AST::ForEach, AST::FunctionDef
        next  # boundary -- do not enter nested loop / fn body
      when AST::IfStatement
        scan_direct(s.then_branch, &block)
        scan_direct(s.else_branch, &block)
      when AST::MatchStatement
        s.cases.each { |c| scan_direct(c.body, &block) }
        scan_direct(s.default_case, &block) if s.default_case
      when AST::WithBlock
        scan_direct(s.body, &block)
      when AST::DoBlock
        s.branches.each { |b| scan_direct(b[:body], &block) }
      end
    end
  end

  # ── SHARD context frame-alloc flags ──────────────────────────────────────

  # Deep walk that descends into all struct children, including BinaryOp and
  # DoBlock branches (which are Arrays of Hashes with :body keys).
  # AST.walk_body only recurses into control-flow nodes; pipeline BinaryOp
  # chains are not in that list, so ConcurrentOp nested inside them is missed.
  sig { params(nodes: T.untyped, visited: T::Set[Integer], block: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
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
  sig { params(body: T::Array[T.untyped], fn_nodes: FnNodes).returns(T.nilable(T::Array[T.untyped])) }
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
  #.
  sig { params(expr: T.untyped, fn_nodes: FnNodes).returns(T::Boolean) }
  def self.key_allocates_frame?(expr, fn_nodes)
    case expr
    when AST::FuncCall
      fn = fn_nodes[expr.name]
      # uses_frame=true means the function frame-allocates internally (e.g. intToString
      # intermediates). Those intermediate frame allocations accumulate in the caller's frame arena.
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
    extend T::Sig

  attr_reader :errors

  sig { params(fn_node: AST::FunctionDef, schema_lookup: Proc).returns(T::Array[String]) }
  def self.check(fn_node, schema_lookup:)
    checker = new(fn_node, schema_lookup: schema_lookup)
    checker.check!
    checker.errors
  end

  sig { params(fn_node: T.untyped, schema_lookup: T.nilable(Proc)).void }
  def initialize(fn_node, schema_lookup:)
    @fn_name = T.let(fn_node.name, String)
    @fn_node = fn_node
    @schema_lookup = schema_lookup
    @errors = T.let([], T::Array[T.untyped])
    @active_borrows = T.let({}, T::Hash[T.untyped, T.untyped]) # { source_name => [{ kind: :mutable/:immutable }] }
  end

  sig { returns(T::Array[T.untyped]) }
  def check!
    T.must(check_stmts(@fn_node.body || []))
  end

  private

  # Extract the root variable name from a capability's var_node.
  sig { params(var_node: AST::Identifier).returns(T.nilable(String)) }
  def cap_source_name(var_node)
    AST.root_identifier(var_node)&.name&.to_s
  end

  sig { params(token: Lexer::Token).returns(String) }
  def line_info(token)
    token.line ? " (line #{token.line})" : ""
  end

  sig { params(stmts: T.nilable(T::Array[T.untyped])).returns(T.nilable(T::Array[T.untyped])) }
  def check_stmts(stmts)
    return unless stmts.is_a?(Array)
    stmts.each { |stmt| check_stmt(stmt) }
  end

  sig { params(stmt: T.untyped).returns(T.untyped) }
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
        check_borrowed_move(inner.name.to_s, T.must(stmt.token))
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
      stmt.cases.each { |c| check_stmts(c.body) }
      check_stmts(stmt.default_case)

    when AST::DoBlock
      stmt.branches.each { |b| check_stmts(b[:body]) }

    when AST::BgBlock, AST::BgStreamBlock
      # BG resource captures are ownership transfers
      stmt.capture_analysis&.resource_captures&.each do |name|
        check_borrowed_move(name, stmt.token)
      end
      check_stmts(stmt.body)
    end
  end

  sig { params(stmt: AST::WithBlock).returns(T::Array[String]) }
  def handle_with_block(stmt)
    added = []

    (stmt.capabilities || []).each do |cap|
      source = cap_source_name(cap[:var_node])
      next unless source

      # Only RESTRICT and BORROWED create compile-time borrows.
      capability = cap[:capability]
      next unless capability == :RESTRICT || capability == :BORROWED

      kind = (capability == :RESTRICT) ? :mutable : :immutable
      token = cap[:var_node].token || stmt.token

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
  sig { params(expr: T.untyped, token: Lexer::Token).returns(T.nilable(T::Set[String])) }
  def check_binding_moves(expr, token)
    return unless expr
    moved = collect_moved_names(expr)
    moved.each { |name| check_borrowed_move(name, token) }
  end

  # Check explicit moves (was_moved) in function/method call arguments.
  sig { params(stmt: T.untyped, token: Lexer::Token).returns(T::Array[T.untyped]) }
  def check_explicit_moves(stmt, token)
    walk_for_was_moved(stmt) do |ident|
      next if copy_type?(ident)
      check_borrowed_move(ident.name.to_s, ident.token || token)
    end
  end

  sig { params(name: String, token: Lexer::Token).returns(T.nilable(T::Array[String])) }
  def check_borrowed_move(name, token)
    borrows = @active_borrows[name]
    return unless borrows&.any?
    borrow_kind = borrows.last[:kind]
    @errors << "[MOVE_WHILE_BORROWED] #{@fn_name}::#{name} -- " \
               "cannot move while #{borrow_kind} borrow is active#{line_info(token)}"
  end

  # Collect variable names being moved by an expression (binding RHS context).
  # Non-Copy identifiers in ownership-transferring positions are moves.
  sig { params(node: T.untyped).returns(T::Set[String]) }
  def collect_moved_names(node)
    names = Set.new
    _collect_moves(node, names)
    names
  end

  sig { params(node: T.untyped, names: T::Set[String]).returns(T.untyped) }
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
        node.args.each { |a| _collect_moves(a, names) }
      else
        _collect_was_moved(node, names)
      end
    when AST::FuncCall
      _collect_was_moved(node, names)
    when AST::ListLit
      node.items.each { |i| _collect_moves(i, names) }
    when AST::GetField
      if owning_field_move?(node)
        root = AST.root_identifier(node)
        names << root.name.to_s if root
      else
        _collect_was_moved(node, names)
      end
    when AST::MoveNode
      inner = node.value
      names << inner.name.to_s if inner.is_a?(AST::Identifier)
    when AST::ShareNode
      _collect_share_moves(node, names)
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

  sig { params(node: T.untyped, names: T::Set[String]).returns(T.untyped) }
  def _collect_was_moved(node, names)
    walk_for_was_moved(node) do |ident|
      next if copy_type?(ident)
      names << ident.name.to_s
    end
  end

  sig { params(node: AST::ShareNode, names: T::Set[T.untyped]).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def _collect_share_moves(node, names)
    source = node.value
    return if source.is_a?(AST::CopyNode)

    if source.is_a?(AST::Identifier)
      return if source.full_type.shared?
      names << source.name.to_s
      return
    end

    _collect_moves(source, names)
  end

  # Walk expression tree for was_moved identifiers, skipping CopyNode.
  sig { params(node: T.untyped, block: T.untyped).returns(T.untyped) }
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
      node.args.each { |a| walk_for_was_moved(a, &block) }
    when AST::MethodCall
      walk_for_was_moved(node.object, &block)
      node.args.each { |a| walk_for_was_moved(a, &block) }
    when AST::GetField
      walk_for_was_moved(node.target, &block)
    when AST::GetIndex
      walk_for_was_moved(node.target, &block)
      walk_for_was_moved(node.index, &block)
    when AST::StructLit
      node.fields&.each_value { |v| walk_for_was_moved(v, &block) }
    when AST::ListLit
      node.items.each { |i| walk_for_was_moved(i, &block) }
    when AST::MoveNode
      walk_for_was_moved(node.value, &block)
    when AST::ShareNode
      walk_for_was_moved(node.value, &block)
    when AST::CapabilityWrap
      walk_for_was_moved(node.value, &block)
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def owning_field_move?(node)
    return false unless node.is_a?(AST::GetField)
    ti = Type.from_node(node)
    ti.is_a?(Type) && ti.indirect?
  rescue
    false
  end

  sig { params(ident: AST::Identifier).returns(T::Boolean) }
  def copy_type?(ident)
    ti = ident.full_type
    is_atomic_ptr = ti.atomic_ptr?
    ti.primitive? || ti.string? || ti.any? || ti.void? || ((ti.any_rc? rescue false) && !is_atomic_ptr)
  end
end


# MIRPass is defined in mir_pass.rb (extracted for T2).
require_relative "mir_pass"
