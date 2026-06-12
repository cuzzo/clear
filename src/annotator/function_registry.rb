# typed: strict
require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "phases/body_analysis"

module Annotator
  class FunctionRegistry < T::Struct
    extend T::Sig

    prop :nodes, T::Hash[String, AST::FunctionDef], factory: -> { {} }
    prop :synthetic_definitions, T::Array[AST::FunctionDef], factory: -> { [] }
    prop :body_summaries, T::Hash[String, Annotator::Phases::FunctionBodySummary], factory: -> { {} }

    sig { params(node: AST::FunctionDef).returns(AST::FunctionDef) }
    def register!(node)
      raise "duplicate function node '#{node.name}'" if nodes.key?(node.name)
      nodes[node.name] = node
      node
    end

    sig { params(name: T.nilable(String)).returns(T.nilable(AST::FunctionDef)) }
    def fetch(name)
      return nil unless name

      nodes[name]
    end

    sig { params(name: String).returns(T::Boolean) }
    def key?(name)
      nodes.key?(name)
    end

    sig { returns(T::Array[String]) }
    def names
      nodes.keys
    end

    sig { params(blk: T.proc.params(node: AST::FunctionDef).void).void }
    def each_node(&blk)
      nodes.each_value(&blk)
    end

    sig { params(node: AST::FunctionDef).returns(AST::FunctionDef) }
    def add_synthetic_definition!(node)
      synthetic_definitions << node
      node
    end

    sig { void }
    def clear_synthetic_definitions!
      synthetic_definitions.clear
    end

    sig { params(summary: Annotator::Phases::FunctionBodySummary).returns(Annotator::Phases::FunctionBodySummary) }
    def record_body_summary!(summary)
      body_summaries[summary.name] = summary
      summary
    end

    sig { returns(T::Hash[String, T::Set[String]]) }
    def call_graph
      body_summaries.transform_values(&:callees)
    end

    sig { returns(T::Hash[String, T::Set[String]]) }
    def propagating_callees
      body_summaries.transform_values(&:propagating_callees)
    end

    sig { params(name: String).returns(T::Boolean) }
    def fnptr_call?(name)
      body_summaries[name]&.has_fnptr_call == true
    end

    sig { params(name: String).returns(T::Boolean) }
    def raises_directly?(name)
      body_summaries[name]&.raises_directly == true
    end
  end
end
