# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../../ast/ast"

class PipelinePlaceholderUsage
  extend T::Sig

  sig { params(stmts: T::Array[AST::Node]).returns(T::Boolean) }
  def self.statements_use_placeholder?(stmts)
    stmts.any? { |stmt| node_uses_placeholder?(stmt) }
  end

  sig { params(node: T.nilable(T.any(AST::Node, Object))).returns(T::Boolean) }
  def self.node_uses_placeholder?(node)
    contains_placeholder?(node, bare: false)
  end

  sig { params(node: T.nilable(T.any(AST::Node, Object))).returns(T::Boolean) }
  def self.node_uses_bare_placeholder?(node)
    contains_placeholder?(node, bare: true)
  end

  sig { params(node: T.nilable(T.any(AST::Node, Object)), bare: T::Boolean).returns(T::Boolean) }
  def self.contains_placeholder?(node, bare:)
    return false unless node.is_a?(AST::Locatable)
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
