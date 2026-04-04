require_relative "ast"
require_relative "type"

# Pipeline Rewriter — transforms pipeline s> operators into plain AST nodes.
#
# Runs after annotation (needs type info) but before transpilation.
# The transpiler never sees pipeline operators — only FuncCalls and loops.
#
# Each pipeline operator is an independent rewrite:
#   x s> f         ->  FuncCall(f, [x])
#   x s> f(y)      ->  FuncCall(f, [x, y])
#   x s> WHERE(p)  ->  (handled by transpiler's existing loop generation)
#   x s> SELECT(e) ->  (handled by transpiler's existing loop generation)
#
# Fusion (WHERE+SELECT -> single loop) is a separate optimization that
# detects chains and combines them.
#
# Design: each operator handler is tested independently. Fusion is tested
# with pairs. Adding a new operator = one method + one test.

class PipelineRewriter
  # Rewrite all pipeline nodes in the AST.
  # Modifies the AST in place by replacing Smooth BinaryOp nodes
  # with their rewritten forms.
  def rewrite!(ast)
    ast.statements.each { |stmt| rewrite_in_node!(stmt) }
  end

  private

  # Recursively walk the AST and rewrite Smooth (pipeline) nodes.
  # Returns the replacement node (or original if no rewrite needed).
  def rewrite_in_node!(node)
    return node unless node

    # Recurse into children first (bottom-up rewriting)
    rewrite_children!(node)

    # Rewrite this node if it's a pipeline
    if node.is_a?(AST::BinaryOp) && node.op == :SMOOTH
      return rewrite_pipeline(node.left, node.right, node)
    end

    node
  end

  # Recurse into all child nodes that may contain pipelines.
  def rewrite_children!(node)
    case node
    when AST::FunctionDef
      node.body&.map!.with_index { |s, _| rewrite_in_node!(s) }
    when AST::VarDecl, AST::BindExpr
      node.value = rewrite_in_node!(node.value) if node.value
    when AST::Assignment
      node.value = rewrite_in_node!(node.value) if node.respond_to?(:value) && node.value
    when AST::ReturnNode
      node.value = rewrite_in_node!(node.value) if node.value
    when AST::IfStatement
      node.then_branch&.map! { |s| rewrite_in_node!(s) }
      node.else_branch&.map! { |s| rewrite_in_node!(s) }
    when AST::MatchStatement
      (node.cases || []).each { |c| c[:body]&.map! { |s| rewrite_in_node!(s) } }
      node.default_case&.map! { |s| rewrite_in_node!(s) } if node.default_case
    when AST::WhileLoop
      b = node.do_branch
      if b.is_a?(Array)
        b.map! { |s| rewrite_in_node!(s) }
      end
    when AST::ForRange, AST::ForEach
      node.body&.map! { |s| rewrite_in_node!(s) }
    when AST::BinaryOp
      node.left = rewrite_in_node!(node.left) if node.left
      node.right = rewrite_in_node!(node.right) if node.right
    when AST::FuncCall, AST::MethodCall
      node.args&.map! { |a| rewrite_in_node!(a) }
    end
  end

  # Rewrite a single pipeline: lhs s> rhs
  # Returns the rewritten AST node.
  def rewrite_pipeline(lhs, rhs, original)
    # Higher-order pipeline operators are left for the transpiler
    # (they generate loops, which is Zig-specific code generation).
    # Only rewrite simple function pipe: x s> f, x s> f(y)
    case rhs
    when AST::Identifier
      # x s> f  ->  f(x)
      call = AST::FuncCall.new(rhs.token, rhs.name, [lhs])
      propagate_type_info!(call, rhs, original, lhs)
      call
    when AST::FuncCall
      # x s> f(y)  ->  f(x, y)
      call = AST::FuncCall.new(rhs.token, rhs.name, [lhs] + rhs.args)
      propagate_type_info!(call, rhs, original, lhs)
      call
    else
      # Pipeline operators (WHERE, SELECT, REDUCE, etc.) stay as BinaryOp(:SMOOTH)
      # for the transpiler to handle with loop generation.
      original
    end
  end

  # Copy type info from the original pipeline RHS to the synthetic call.
  def propagate_type_info!(call, rhs, original, lhs)
    call.zig_pattern = rhs.zig_pattern if rhs.respond_to?(:zig_pattern) && rhs.zig_pattern
    call.full_type = rhs.full_type if rhs.respond_to?(:full_type) && rhs.full_type
    call.coerced_type = rhs.coerced_type if rhs.respond_to?(:coerced_type) && rhs.coerced_type
    call.heap_promoted_call = rhs.heap_promoted_call if rhs.respond_to?(:heap_promoted_call)
    call.extern_call = rhs.extern_call if rhs.respond_to?(:extern_call) && rhs.extern_call
    call.extern_effects = rhs.extern_effects if rhs.respond_to?(:extern_effects) && rhs.extern_effects
    call.was_moved = original.was_moved if original.respond_to?(:was_moved) && original.was_moved
    # Track original pipeline LHS for CATCH snapshot capture.
    call.pipe_lhs = lhs
  end
end
