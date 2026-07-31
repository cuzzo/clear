# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"

class PipelinePlaceholderUsage
  extend T::Sig

  sig { params(stmts: T::Array[AST::Node]).returns(T::Boolean) }
  def self.statements_use_placeholder?(stmts)
    stmts.any? { |stmt| contains_placeholder?(stmt, bare: false) }
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.node_uses_placeholder?(node)
    return false unless node

    contains_placeholder?(node, bare: false)
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.node_uses_bare_placeholder?(node)
    return false unless node

    contains_placeholder?(node, bare: true)
  end

  # Bare identity selector: the expression IS the placeholder.
  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.identity_placeholder?(node)
    return false unless node

    node.is_a?(AST::Identifier) && placeholder_identifier?(node)
  end

  # A field/index projection rooted at the placeholder (`_.name`,
  # `_.items[0]`). The projected value BORROWS from the item, so the loop
  # must not release the item out from under it.
  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.placeholder_projection?(node)
    return false unless node

    case node
    when AST::GetField, AST::GetIndex
      target = T.cast(node.target, T.nilable(AST::Node))
      (target.is_a?(AST::Identifier) && target.name == "_") || placeholder_projection?(target)
    else
      false
    end
  end

  sig { params(node: T.nilable(AST::Node)).returns(T::Boolean) }
  def self.moved_placeholder?(node)
    return false unless node
    return AST.moved?(node) if placeholder_identifier?(node)
    return contains_placeholder?(node, bare: false) if node.is_a?(AST::MoveNode)

    found = T.let(false, T::Boolean)
    AST.each_child_node(node) do |child|
      found = true if moved_placeholder?(child)
    end
    found
  end

  sig { params(node: T.nilable(AST::Node), bare: T::Boolean).returns(T::Boolean) }
  def self.contains_placeholder?(node, bare:)
    return false unless node
    return false if bare && AST.soa_placeholder_field?(node)
    return true if placeholder_identifier?(node)

    found = T.let(false, T::Boolean)
    AST.each_child_node(node) do |child|
      found = true if contains_placeholder?(child, bare: bare)
    end
    found
  end
  private_class_method :contains_placeholder?

  sig { params(node: AST::Locatable).returns(T::Boolean) }
  def self.placeholder_identifier?(node)
    node.is_a?(AST::Identifier) && node.name == "_"
  end
  private_class_method :placeholder_identifier?
end
