# typed: strict
require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../ast/scope"
require_relative "../annotator/function_registry"

class SemanticIndex < T::Struct
  extend T::Sig

  const :program, AST::Program
  const :root_scope, Scope
  const :function_registry, Annotator::FunctionRegistry

  sig { returns(T::Hash[String, AST::FunctionDef]) }
  def function_nodes
    function_registry.nodes
  end

  sig { params(name: String).returns(T.nilable(AST::FunctionDef)) }
  def function_node(name)
    function_registry.fetch(name)
  end
end
