# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "declaration_index"

module Annotator
  module Phases
    class FunctionBodySummary < T::Struct
      const :name, String
      const :callees, T::Set[String]
      const :propagating_callees, T::Set[String]
      const :has_fnptr_call, T::Boolean
      const :raises_directly, T::Boolean
      const :func_calls, T::Array[AST::FuncCall], factory: -> { [] }
      const :with_blocks, T::Array[AST::WithBlock], factory: -> { [] }
    end

    module BodyAnalysis
      extend T::Sig

      sig { params(summary: FunctionBodySummary).void }
      def record_function_body_summary!(summary)
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.record_body_summary!(summary)
      end

      sig { returns(T::Hash[String, FunctionBodySummary]) }
      def function_body_summaries
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.body_summaries
      end

      sig { params(name: String).returns(T.nilable(FunctionBodySummary)) }
      def function_body_summary_for(name)
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.body_summary_for(name)
      end

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_call_graph
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.call_graph
      end

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_propagating_callees
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.propagating_callees
      end

      sig { params(name: String).returns(T::Boolean) }
      def function_has_fnptr_call?(name)
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.fnptr_call?(name)
      end

      sig { params(name: String).returns(T::Boolean) }
      def function_raises_directly?(name)
        T.bind(self, SemanticAnnotator)
        semantic_function_registry.raises_directly?(name)
      end

      sig { params(declarations: DeclarationIndex, program: AST::Program).void }
      def analyze_program_bodies!(declarations, program)
        T.bind(self, SemanticAnnotator)

        declarations.body_statements.each { |stmt| visit(stmt) }

        synthetic_function_definitions.each do |fn|
          visit_FunctionDef(fn)
          program.statements << fn
        end
      end
    end
  end
end
