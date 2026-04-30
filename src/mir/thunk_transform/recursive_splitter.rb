# thunk_transform/recursive_splitter.rb -- AST -> segment graph
# splitter for `:reentrant_thunk` function bodies.
#
# Mirrors fsm_transform/recursive_splitter.rb's structural shape:
# walk the AST top-down, accumulate linear stmts into segments,
# split at every PIVOT (in this case, a recursive self-call) into
# distinct segments. Tail-position recursive calls become
# RecurseTail tails; non-tail calls become RecurseStep tails with
# a pending_op assigned per call site.
#
# Phase 4c lands ONE pattern: the simple recurrence shape
# (factorial / fibonacci-individual-call / similar):
#
#   FN f(args...) RETURNS T
#     EFFECTS REENTRANT:THUNK ->
#     IF base_cond -> RETURN base_value;       -- 0 or more base cases
#     IF base_cond -> RETURN base_value;
#     ...
#     RETURN combine_lhs <op> f(recurse_args); -- exactly one self-call
#   END
#
# `<op>` is one of `*`, `+`, `-`, `/`. The lhs is any expression
# that doesn't contain a self-call. The recursive call's args may
# reference parameters; they're evaluated before the recurse-push.
# If the body matches this shape, split returns a Plan record;
# otherwise nil (caller errors with a "Phase 4d/4c.X handles this
# shape" message).
#
# Phase 4d will land the Zig codegen that consumes the Plan; Phase
# 4d-e will widen the recognized shapes (multiple recursive calls,
# arbitrary control flow with recursion, etc.).

require_relative "segments"

module ThunkTransform
  module RecursiveSplitter
    # A detected simple-recurrence shape. Consumed by Phase 4d's
    # Zig emitter.
    Plan = Struct.new(
      :base_cases,    # Array of { cond_ast:, value_ast: } -- 0 or more
      :combine_lhs,   # AST node — left side of the binary op (no self-call)
      :combine_op,    # Symbol — :"*", :"+", :"-", :"/"
      :recurse_args,  # Array of AST nodes — args to the recursive call
      :final_return,  # the AST::ReturnNode containing the recursive call
                      # (kept so the Phase 4d emitter can grab tokens for
                      # error spans and span-edits)
      keyword_init: true,
    )

    # A detected tail-position mutual-recurrence shape. Consumed by
    # Phase 4f.1's tagged-union codegen. Like Plan but without
    # combine_op (the recursive call IS the entire return value)
    # and with target_fn naming the partner being called.
    MutualPlan = Struct.new(
      :base_cases,    # Array of { cond_ast:, value_ast: }
      :target_fn,     # String — name of the partner fn called in tail position
      :target_args,   # Array of AST nodes — args to the partner call
      :final_return,  # AST::ReturnNode
      keyword_init: true,
    )

    # Stamped on every member of a tail-position mutual-recurrence
    # cycle by ReentranceBridge. Consumed by ThunkTransform::Emit
    # to synthesize the tagged-union trampoline. `cycle_fns` is the
    # ordered list of FunctionDef nodes (each with its OWN_PLAN on
    # its mutual_thunk_plan); `own_plan` is the MutualPlan for THIS
    # member. The codegen reads cycle_fns to enumerate union variants
    # and own_plan to know which variant to start in.
    MutualThunkPlan = Struct.new(
      :cycle_fns,     # Array of AST::FunctionDef
      :own_plan,      # MutualPlan for the function this is stamped on
      keyword_init: true,
    )

    module_function

    # Public entry. Given a function body (Array of AST stmts) +
    # the function name, return a Plan if the body matches the
    # simple recurrence shape Phase 4c recognizes, else nil.
    #
    # NOTE: this is detection only. Zig codegen lands in Phase 4d.
    # When the shape matches but codegen isn't yet wired, the
    # caller still errors -- pattern detection alone doesn't make
    # the function compilable.
    def split(body, fn_name, lowering)
      _ = lowering # Phase 4c does pure AST inspection; no lowering needed yet.
      return nil if body.nil? || body.empty?

      # Walk top-level statements: zero or more IF base-cases
      # (each: `IF cond -> RETURN expr;`), then exactly one final
      # RETURN with `expr op self_call(args)` shape.
      stmts = body
      base_cases = []
      i = 0
      while i < stmts.length - 1
        stmt = stmts[i]
        bc = match_base_case(stmt, fn_name)
        return nil if bc.nil?
        base_cases << bc
        i += 1
      end
      final = stmts.last
      return nil unless final.is_a?(AST::ReturnNode) && final.value
      combine = match_recursive_combine(final.value, fn_name)
      return nil if combine.nil?

      Plan.new(
        base_cases:   base_cases,
        combine_lhs:  combine[:lhs],
        combine_op:   combine[:op],
        recurse_args: combine[:args],
        final_return: final,
      )
    end

    # Phase 4f.1: tail-position mutual-recurrence detection. Given a
    # function body, the function name, and the set of partner names
    # in the same cycle, return a MutualPlan if the body matches:
    #
    #   IF base_cond -> RETURN base_value;   -- 0 or more base cases
    #   ...
    #   RETURN partner(args);                -- direct tail call to
    #                                            a partner (not self,
    #                                            not nested in expr)
    #
    # No combine op is permitted (depth=1: tail call replaces the
    # variant in place). Returns nil if the body has any non-tail
    # call to ANY cycle member, or if the final return isn't a
    # direct call to a partner.
    def split_mutual(body, fn_name, partner_names, lowering)
      _ = lowering
      return nil if body.nil? || body.empty?
      cycle = (Array(partner_names) + [fn_name]).map(&:to_s).to_set

      stmts = body
      base_cases = []
      i = 0
      while i < stmts.length - 1
        stmt = stmts[i]
        bc = match_mutual_base_case(stmt, cycle)
        return nil if bc.nil?
        base_cases << bc
        i += 1
      end
      final = stmts.last
      return nil unless final.is_a?(AST::ReturnNode) && final.value
      target = match_tail_mutual_call(final.value, partner_names)
      return nil if target.nil?

      MutualPlan.new(
        base_cases:   base_cases,
        target_fn:    target[:name],
        target_args:  target[:args],
        final_return: final,
      )
    end

    # An IF base case for the mutual shape: `IF <cond> -> RETURN <expr>;`
    # where neither cond nor expr contains ANY call to a cycle member
    # (self or partner). The cycle set includes the current fn name.
    def match_mutual_base_case(stmt, cycle_names)
      return nil unless stmt.is_a?(AST::IfStatement)
      return nil if stmt.else_branch && !stmt.else_branch.empty?
      then_b = stmt.then_branch || []
      return nil if then_b.length != 1
      ret = then_b.first
      return nil unless ret.is_a?(AST::ReturnNode) && ret.value
      return nil if contains_any_call?(stmt.condition, cycle_names)
      return nil if contains_any_call?(ret.value, cycle_names)
      { cond_ast: stmt.condition, value_ast: ret.value }
    end

    # `partner_fn(args...)` directly (not nested), where partner_fn is
    # one of the named partners. Returns { name:, args: } or nil.
    def match_tail_mutual_call(node, partner_names)
      return nil unless node.is_a?(AST::FuncCall)
      partners = Array(partner_names).map(&:to_s).to_set
      return nil unless partners.include?(node.name.to_s)
      { name: node.name.to_s, args: node.args || [] }
    end

    # Like contains_self_call? but for a SET of fn names.
    def contains_any_call?(node, names_set)
      return false if node.nil?
      names = names_set.is_a?(Set) ? names_set : Array(names_set).map(&:to_s).to_set
      if node.is_a?(AST::FuncCall) && names.include?(node.name.to_s)
        return true
      end
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| return true if contains_any_call?(v, names) }
      elsif node.is_a?(Array)
        node.each { |v| return true if contains_any_call?(v, names) }
      end
      false
    end

    # An IF base case: `IF <cond> -> RETURN <expr>;` where neither
    # cond nor expr contains a self-call. Both the shorthand and
    # block IF forms parse to AST::IfStatement; the body is a
    # single-element list with the RETURN.
    def match_base_case(stmt, fn_name)
      return nil unless stmt.is_a?(AST::IfStatement)
      return nil if stmt.else_branch && !stmt.else_branch.empty?
      then_b = stmt.then_branch || []
      return nil if then_b.length != 1
      ret = then_b.first
      return nil unless ret.is_a?(AST::ReturnNode) && ret.value
      return nil if contains_self_call?(stmt.condition, fn_name)
      return nil if contains_self_call?(ret.value, fn_name)
      { cond_ast: stmt.condition, value_ast: ret.value }
    end

    # Match `lhs op self_call(args)` or `self_call(args) op rhs`,
    # for op in *, +, -, /. The non-self-call side must NOT contain
    # a self-call. Returns { lhs, op, args } where lhs is the
    # combine partner (whichever side is not the recursive call).
    # Op symbol is normalized to AST::OP_TO_OP_CODE form (:ADD,
    # :SUB, :MUL, :DIV) so downstream consumers don't need to
    # remember the surface character.
    SUPPORTED_OPS = [:ADD, :SUB, :MUL, :DIV].freeze

    def match_recursive_combine(expr, fn_name)
      return nil unless expr.is_a?(AST::BinaryOp)
      return nil unless SUPPORTED_OPS.include?(expr.op)

      left_call  = direct_self_call(expr.left, fn_name)
      right_call = direct_self_call(expr.right, fn_name)

      if left_call && !contains_self_call?(expr.right, fn_name)
        { lhs: expr.right, op: expr.op, args: left_call }
      elsif right_call && !contains_self_call?(expr.left, fn_name)
        { lhs: expr.left, op: expr.op, args: right_call }
      else
        nil
      end
    end

    # If `node` is exactly `fn_name(args...)`, return its args.
    # Returns nil otherwise (including for nested self-calls).
    def direct_self_call(node, fn_name)
      return nil unless node.is_a?(AST::FuncCall) && node.name == fn_name
      node.args || []
    end

    # Recursive subtree walk: returns true iff any AST::FuncCall
    # whose name == fn_name appears anywhere under `node`.
    def contains_self_call?(node, fn_name)
      return false if node.nil?
      return true if node.is_a?(AST::FuncCall) && node.name == fn_name
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| return true if contains_self_call?(v, fn_name) }
      elsif node.is_a?(Array)
        node.each { |v| return true if contains_self_call?(v, fn_name) }
      end
      false
    end
  end
end
