# control_flow.rb - CFG construction + MIR node insertion
#
# Two components:
#   1. FunctionCFG: builds a control flow graph from an annotated AST function.
#      Basic blocks contain references to AST statements. Edges represent
#      branch/join/loop structure. Used as an analysis-only structure for
#      ownership dataflow (Phase 2b+).
#
#   2. MIRPass: reads CleanupPlan/PromotionPlan results and inserts MIR nodes
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
    build_body(fn_node.body || [], cfg.entry, cfg.exit_block, cfg)
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
