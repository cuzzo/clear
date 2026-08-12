# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/type"

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

  sig { params(ast: AST::Program).returns(T::Array[AST::Node]) }
  def rewrite!(ast)
    # `rewrite_in_node!` mutates its argument. Iterating with `each` hands
    # the self-hosted lowering a borrowed element, which cannot satisfy the
    # generated mutable parameter (and drops a replacement at top level).
    # Reuse the indexed body rewriter so replacements are written back.
    body = ast.statements
    rewrite_body!(body)
    # The local body is the mutable argument. Reassign it explicitly so the
    # host AST receives the rewritten list and the parameter's mutation is
    # visible to the generated function signature.
    ast.statements = body
    body
  end

  private

  sig { params(node: T.nilable(AST::Node)).returns(T.nilable(AST::Node)) }
  def rewrite_in_node!(node)
    return node unless node
    rewrite_children!(node)

    parts = collect_parts(node)
    if parts.length > 2
      return node unless node.is_a?(AST::BinaryOp)

      binary = T.cast(node, AST::BinaryOp)
      concat = AST::StringConcat.new(binary.token, parts)
      binary_type = binary.type_object
      raise "synthetic AST type: source BinaryOp has no type" unless binary_type
      concrete_type = T.cast(binary_type, Type)
      raise "synthetic AST type: source BinaryOp is untyped" if concrete_type.untyped?
      concat.type_object = concrete_type
      concat.storage_override = binary.storage_override
      return concat
    end

    node
  end

  sig { params(node: AST::Node).returns(AST::Node) }
  def rewrite_required_node!(node)
    node_mutable = node
    T.must(rewrite_in_node!(node_mutable))
  end

  sig { params(body: T::Array[AST::Node]).void }
  def rewrite_body!(body)
    index = 0
    while index < body.length
      body[index] = rewrite_required_node!(body[index])
      index += 1
    end
  end

  sig { params(node: AST::Node).void }
  def rewrite_children!(node)
    case node
    when AST::FunctionDef
      # Lower through a local body slot. Passing `&function_def.body` tries to
      # take a mutable borrow through the immutable pattern binding generated
      # by the type case, which CLEAR correctly rejects.
      function_def = T.cast(node, AST::FunctionDef)
      body = function_def.body
      rewrite_body!(body)
      function_def.body = body
    when AST::VarDecl, AST::BindExpr, AST::Assignment, AST::DestructuringAssignment, AST::ReturnNode
      node.value = rewrite_in_node!(node.value)
    when AST::IfStatement
      then_branch = node.then_branch
      else_branch = node.else_branch
      rewrite_body!(then_branch) if then_branch
      rewrite_body!(else_branch) if else_branch
    when AST::MatchStatement
      node.cases.each { |c| rewrite_body!(c.body) }
      default_body = node.default_case
      rewrite_body!(default_body) if default_body
    when AST::WhileLoop
      body = node.do_branch
      rewrite_body!(body) if body.is_a?(Array)
    when AST::ForRange, AST::ForEach
      rewrite_body!(node.body)
    when AST::BinaryOp
      node.left = rewrite_in_node!(node.left)
      node.right = rewrite_in_node!(node.right)
    when AST::FuncCall, AST::MethodCall
      rewrite_body!(node.args)
    when AST::StructLit
      fields = node.fields
      keys = fields.keys
      index = 0
      while index < keys.length
        key = keys.fetch(index)
        value = fields.fetch(key)
        fields[key] = rewrite_required_node!(value)
        index += 1
      end
    end
  end

  # Is this a string + operation?
  sig { params(node: T.nilable(AST::Node)).returns(T.nilable(T::Boolean)) }
  def string_concat?(node)
    return true if node.is_a?(AST::StringConcat)
    return false unless node.is_a?(AST::BinaryOp)
    node.string_concat == true
  end

  # Flatten chained string + into a flat list of parts.
  sig { params(node: AST::Node).returns(T::Array[AST::Node]) }
  def collect_parts(node)
    case node
    when AST::StringConcat
      node.parts
    when AST::BinaryOp
      if string_concat?(node)
        collect_parts(node.left) + collect_parts(node.right)
      else
        [node]
      end
    else
      [node]
    end
  end
end
