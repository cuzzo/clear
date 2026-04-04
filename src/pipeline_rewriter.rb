require_relative "ast"
require_relative "type"

# Pipeline Rewriter — transforms pipeline s> operators into plain AST nodes.
#
# Runs after annotation (needs type info) but before transpilation.
#
# Phase 1 (implemented): Simple function pipes
#   x s> f         ->  FuncCall(f, [x])
#   x s> f(y)      ->  FuncCall(f, [x, y])
#
# Collection operators (WHERE, SELECT, etc.) and fusion remain in the
# transpiler's pipeline_generator.rb because they create new AST nodes
# that require full type annotation. Moving them here would require
# either a re-annotation pass or manual type propagation.
#
# Future: when a re-annotation pass exists, collection ops can move here.

class PipelineRewriter
  def initialize
    @counter = 0
  end

  def rewrite!(ast)
    ast.statements.each { |stmt| rewrite_in_node!(stmt) }
  end

  private

  def rewrite_in_node!(node)
    return node unless node
    rewrite_children!(node)

    if node.is_a?(AST::BinaryOp) && node.op == :SMOOTH
      return rewrite_pipeline(node.left, node.right, node)
    end

    node
  end

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
      b.map! { |s| rewrite_in_node!(s) } if b.is_a?(Array)
    when AST::ForRange, AST::ForEach
      node.body&.map! { |s| rewrite_in_node!(s) }
    when AST::BinaryOp
      node.left = rewrite_in_node!(node.left) if node.left
      node.right = rewrite_in_node!(node.right) if node.right
    when AST::FuncCall, AST::MethodCall
      node.args&.map! { |a| rewrite_in_node!(a) }
    end
  end

  def rewrite_pipeline(lhs, rhs, original)
    case rhs
    when AST::Identifier
      call = AST::FuncCall.new(rhs.token, rhs.name, [lhs])
      propagate_type_info!(call, rhs, original, lhs)
      call
    when AST::FuncCall
      call = AST::FuncCall.new(rhs.token, rhs.name, [lhs] + rhs.args)
      propagate_type_info!(call, rhs, original, lhs)
      call
    else
      # Collection operators (WHERE, SELECT, etc.) stay as BinaryOp(:SMOOTH)
      # for the transpiler's pipeline_generator.
      original
    end
  end

  def propagate_type_info!(call, rhs, original, lhs)
    call.zig_pattern = rhs.zig_pattern if rhs.respond_to?(:zig_pattern) && rhs.zig_pattern
    call.full_type = rhs.full_type if rhs.respond_to?(:full_type) && rhs.full_type
    call.coerced_type = rhs.coerced_type if rhs.respond_to?(:coerced_type) && rhs.coerced_type
    call.heap_promoted_call = rhs.heap_promoted_call if rhs.respond_to?(:heap_promoted_call)
    call.extern_call = rhs.extern_call if rhs.respond_to?(:extern_call) && rhs.extern_call
    call.extern_effects = rhs.extern_effects if rhs.respond_to?(:extern_effects) && rhs.extern_effects
    call.was_moved = original.was_moved if original.respond_to?(:was_moved) && original.was_moved
    call.pipe_lhs = lhs
  end
end
