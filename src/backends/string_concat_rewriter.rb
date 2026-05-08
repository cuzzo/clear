# typed: true
require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../ast/type"

# String Concat Rewriter — flattens chained string + into StringConcat nodes.
#
# Runs AFTER annotation (needs type_info to distinguish string + from numeric +).
#
# Before: BinaryOp(:ADD, BinaryOp(:ADD, "a", name), "!")
# After:  StringConcat(["a", name, "!"])
#
# Any backend emits one allocation for all parts instead of N-1 nested concats.

class StringConcatRewriter
    extend T::Sig

  sig { params(ast: AST::Program).returns(Array) }
  def rewrite!(ast)
    ast.statements.each { |stmt| rewrite_in_node!(stmt) }
  end

  private

  sig { params(node: T.untyped).returns(T.untyped) }
  def rewrite_in_node!(node)
    return node unless node
    rewrite_children!(node)

    if string_concat?(node)
      parts = collect_parts(node)
      if parts.length > 2
        concat = AST::StringConcat.new(node.token, parts)
        concat.full_type = node.full_type
        concat.storage = node.storage if node.respond_to?(:storage)
        return concat
      end
    end

    node
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def rewrite_children!(node)
    case node
    when AST::FunctionDef
      node.body.map!.with_index { |s, _| rewrite_in_node!(s) }
    when AST::VarDecl, AST::BindExpr
      node.value = rewrite_in_node!(node.value) if node.value
    when AST::Assignment
      node.value = rewrite_in_node!(node.value) if node.value
    when AST::ReturnNode
      node.value = rewrite_in_node!(node.value) if node.value
    when AST::IfStatement
      node.then_branch&.map! { |s| rewrite_in_node!(s) }
      node.else_branch&.map! { |s| rewrite_in_node!(s) }
    when AST::MatchStatement
      node.cases.each { |c| c[:body]&.map! { |s| rewrite_in_node!(s) } }
      node.default_case.map! { |s| rewrite_in_node!(s) } if node.default_case
    when AST::WhileLoop
      b = node.do_branch
      b.map! { |s| rewrite_in_node!(s) } if b.is_a?(Array)
    when AST::ForRange, AST::ForEach
      node.body.map! { |s| rewrite_in_node!(s) }
    when AST::BinaryOp
      node.left = rewrite_in_node!(node.left) if node.left
      node.right = rewrite_in_node!(node.right) if node.right
    when AST::FuncCall, AST::MethodCall
      node.args.map! { |a| rewrite_in_node!(a) }
    when AST::StructLit
      node.fields.each { |k, v| node.fields[k] = rewrite_in_node!(v) }
    end
  end

  # Is this a string + operation?
  sig { params(node: T.untyped).returns(T.nilable(T::Boolean)) }
  def string_concat?(node)
    return true if node.is_a?(AST::StringConcat)
    return false unless node.is_a?(AST::BinaryOp)
    node.string_concat
  end

  # Flatten chained string + into a flat list of parts.
  sig { params(node: T.untyped).returns(Array) }
  def collect_parts(node)
    if node.is_a?(AST::StringConcat)
      node.parts
    elsif string_concat?(node)
      collect_parts(node.left) + collect_parts(node.right)
    else
      [node]
    end
  end
end
