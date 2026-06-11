# typed: strict
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

require "sorbet-runtime"
require "set"
require_relative "../../ast/ast"

module ThunkTransform
  module RecursiveSplitter
    extend T::Sig
    class BaseCase < T::Struct
      const :cond_ast, AST::Node
      const :value_ast, AST::Node
    end

    class RecursiveCombine < T::Struct
      const :lhs, AST::Node
      const :op, Symbol
      const :args, T::Array[AST::Node]
    end

    class MutualTailCall < T::Struct
      const :name, String
      const :args, T::Array[AST::Node]
    end

    # A detected simple-recurrence shape. Consumed by Phase 4d's
    # MIR trampoline builder.
    class Plan < T::Struct
      const :base_cases, T::Array[BaseCase]
      const :combine_lhs, AST::Node
      const :combine_op, Symbol
      const :recurse_args, T::Array[AST::Node]
      const :final_return, AST::ReturnNode
    end

    # A detected tail-position mutual-recurrence shape. Consumed by
    # Phase 4f.1's tagged-union trampoline builder.
    class MutualPlan < T::Struct
      const :base_cases, T::Array[BaseCase]
      const :target_fn, String
      const :target_args, T::Array[AST::Node]
      const :final_return, AST::ReturnNode
    end

    # Stamped on every member of a tail-position mutual-recurrence
    # cycle by ReentranceBridge.
    class MutualThunkPlan < T::Struct
      const :cycle_fns, T::Array[AST::FunctionDef]
      const :own_plan, MutualPlan
    end

    module_function

    # Public entry. Given a function body (Array of AST stmts) +
    # the function name, return a Plan if the body matches the
    # simple recurrence shape Phase 4c recognizes, else nil.
    #
    # NOTE: this is detection only. Zig codegen lands in Phase 4d.
    # When the shape matches but codegen isn't yet wired, the
    # caller still errors -- pattern detection alone doesn't make
    # the function compilable.
    sig { params(body: T.nilable(T::Array[AST::Node]), fn_name: String, lowering: Object).returns(T.nilable(Plan)) }
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
        stmt = T.must(stmts[i])
        bc = match_base_case(stmt, fn_name)
        return nil if bc.nil?
        base_cases << bc
        i += 1
      end
      final = T.must(stmts.last)
      return nil unless final.is_a?(AST::ReturnNode) && final.value
      combine = match_recursive_combine(final.value, fn_name)
      return nil if combine.nil?

      Plan.new(
        base_cases:   base_cases,
        combine_lhs:  combine.lhs,
        combine_op:   combine.op,
        recurse_args: combine.args,
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
    sig { params(body: T.nilable(T::Array[AST::Node]), fn_name: String, partner_names: T::Array[String], lowering: Object).returns(T.nilable(MutualPlan)) }
    def split_mutual(body, fn_name, partner_names, lowering)
      _ = lowering
      return nil if body.nil? || body.empty?
      cycle = (partner_names + [fn_name]).map(&:to_s).to_set

      stmts = body
      base_cases = []
      i = 0
      while i < stmts.length - 1
        stmt = T.must(stmts[i])
        bc = match_mutual_base_case(stmt, cycle)
        return nil if bc.nil?
        base_cases << bc
        i += 1
      end
      final = T.must(stmts.last)
      return nil unless final.is_a?(AST::ReturnNode) && final.value
      target = match_tail_mutual_call(final.value, partner_names)
      return nil if target.nil?

      MutualPlan.new(
        base_cases:   base_cases,
        target_fn:    target.name,
        target_args:  target.args,
        final_return: final,
      )
    end

    # An IF base case for the mutual shape: `IF <cond> -> RETURN <expr>;`
    # where neither cond nor expr contains ANY call to a cycle member
    # (self or partner). The cycle set includes the current fn name.
    sig { params(stmt: AST::Node, cycle_names: T::Set[String]).returns(T.nilable(BaseCase)) }
    def match_mutual_base_case(stmt, cycle_names)
      return nil unless stmt.is_a?(AST::IfStatement)
      return nil if stmt.else_branch && !stmt.else_branch.empty?
      then_b = stmt.then_branch || []
      return nil if then_b.length != 1
      ret = then_b.first
      return nil unless ret.is_a?(AST::ReturnNode) && ret.value
      return nil if contains_any_call?(stmt.condition, cycle_names)
      return nil if contains_any_call?(ret.value, cycle_names)
      BaseCase.new(cond_ast: stmt.condition, value_ast: ret.value)
    end

    # `partner_fn(args...)` directly (not nested), where partner_fn is
    # one of the named partners.
    sig { params(node: AST::Node, partner_names: T::Array[String]).returns(T.nilable(MutualTailCall)) }
    def match_tail_mutual_call(node, partner_names)
      return nil unless node.is_a?(AST::FuncCall)
      partners = partner_names.map(&:to_s).to_set
      return nil unless partners.include?(node.name.to_s)
      MutualTailCall.new(name: node.name.to_s, args: node.args)
    end

    # Like contains_self_call? but for a SET of fn names.
    sig { params(node: T.nilable(Object), names_set: T::Set[String]).returns(T::Boolean) }
    def contains_any_call?(node, names_set)
      return false if node.nil?
      case node
      when Symbol, String, Integer, Float, TrueClass, FalseClass, Type, AST::FunctionDef, AST::LambdaLit
        false
      when Array
        node.any? { |child| contains_any_call?(child, names_set) }
      when AST::FuncCall
        names_set.include?(node.name.to_s) || node.args.any? { |arg| contains_any_call?(arg, names_set) }
      else
        return false unless node.respond_to?(:each_pair)
        T.unsafe(node).each_pair.any? { |_name, value| contains_any_call?(value, names_set) }
      end
    end

    # An IF base case: `IF <cond> -> RETURN <expr>;` where neither
    # cond nor expr contains a self-call. Both the shorthand and
    # block IF forms parse to AST::IfStatement; the body is a
    # single-element list with the RETURN.
    sig { params(stmt: AST::Node, fn_name: String).returns(T.nilable(BaseCase)) }
    def match_base_case(stmt, fn_name)
      return nil unless stmt.is_a?(AST::IfStatement)
      return nil if stmt.else_branch && !stmt.else_branch.empty?
      then_b = stmt.then_branch || []
      return nil if then_b.length != 1
      ret = then_b.first
      return nil unless ret.is_a?(AST::ReturnNode) && ret.value
      return nil if contains_self_call?(stmt.condition, fn_name)
      return nil if contains_self_call?(ret.value, fn_name)
      BaseCase.new(cond_ast: stmt.condition, value_ast: ret.value)
    end

    # Match `lhs op self_call(args)` or `self_call(args) op rhs`,
    # for op in *, +, -, /. The non-self-call side must NOT contain
    # a self-call. Returns { lhs, op, args } where lhs is the
    # combine partner (whichever side is not the recursive call).
    # Op symbol is normalized to AST::OP_TO_OP_CODE form (:ADD,
    # :SUB, :MUL, :DIV) so downstream consumers don't need to
    # remember the surface character.
    SUPPORTED_OPS = [:ADD, :SUB, :MUL, :DIV].freeze

    sig { params(expr: AST::Node, fn_name: String).returns(T.nilable(RecursiveCombine)) }
    def match_recursive_combine(expr, fn_name)
      return nil unless expr.is_a?(AST::BinaryOp)
      return nil unless SUPPORTED_OPS.include?(expr.op)

      left_call  = direct_self_call(expr.left, fn_name)
      right_call = direct_self_call(expr.right, fn_name)

      if left_call && !contains_self_call?(expr.right, fn_name)
        RecursiveCombine.new(lhs: expr.right, op: expr.op, args: left_call)
      elsif right_call && !contains_self_call?(expr.left, fn_name)
        RecursiveCombine.new(lhs: expr.left, op: expr.op, args: right_call)
      else
        nil
      end
    end

    # If `node` is exactly `fn_name(args...)`, return its args.
    # Returns nil otherwise (including for nested self-calls).
    sig { params(node: AST::Node, fn_name: String).returns(T.nilable(T::Array[AST::Node])) }
    def direct_self_call(node, fn_name)
      return nil unless node.is_a?(AST::FuncCall) && node.name == fn_name
      node.args
    end

    # Recursive subtree walk: returns true iff any AST::FuncCall
    # whose name == fn_name appears anywhere under `node`.
    sig { params(node: T.nilable(Object), fn_name: String).returns(T::Boolean) }
    def contains_self_call?(node, fn_name)
      contains_any_call?(node, Set[fn_name])
    end
      private :contains_any_call?
    private :contains_self_call?
    private :direct_self_call
    private :match_base_case
    private :match_mutual_base_case
    private :match_recursive_combine
    private :match_tail_mutual_call
    private_class_method :contains_any_call?
    private_class_method :contains_self_call?
    private_class_method :direct_self_call
    private_class_method :match_base_case
    private_class_method :match_mutual_base_case
    private_class_method :match_recursive_combine
    private_class_method :match_tail_mutual_call

end
end
