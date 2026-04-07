# control_flow.rb - MIR node insertion pass
#
# Phase 1: Reads existing CleanupPlan/PromotionPlan results and inserts
# the corresponding MIR nodes (Drop, Promote, SuppressCleanup) into AST
# statement lists. The transpiler currently ignores these nodes (no-op
# handlers). In Phase 2+, this pass will be replaced by CFG-based
# dataflow analysis that computes the decisions directly.
#
# Runs AFTER annotation + plan computation, BEFORE transpilation.

require_relative "ast"

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

    # Insert Drop nodes for TAKES params at the top of the function body.
    takes_drops = build_takes_drops(fn, cleanup)

    fn.body = takes_drops + transform_body(fn.body, cleanup, promo)
  end

  # Build Drop nodes for TAKES parameters (cleanup at function scope exit).
  def build_takes_drops(fn, cleanup)
    return [] unless cleanup && fn.deferred_drops
    drops = []
    fn.deferred_drops.each do |dd|
      name = dd.is_a?(Hash) ? dd[:name] : dd.to_s
      entry = cleanup.lookup(name)
      next unless entry && entry[:needs_cleanup]
      drop = MIR::Drop.new(fn.token, name, entry[:kind], entry[:alloc],
                           entry[:has_moved_guard], nil, entry[:resource_close_zig])
      drops << drop
    end
    drops
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
      entry[:has_moved_guard], stmt.type_info, entry[:resource_close_zig]
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
