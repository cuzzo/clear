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
    end

    module BodyAnalysis
      extend T::Sig

      sig { params(summary: FunctionBodySummary).void }
      def record_function_body_summary!(summary)
        T.bind(self, SemanticAnnotator)
        body_summary_store[summary.name] = summary
      end

      sig { returns(T::Hash[String, FunctionBodySummary]) }
      def function_body_summaries
        T.bind(self, SemanticAnnotator)
        body_summary_store
      end

      sig { params(name: String).returns(T.nilable(FunctionBodySummary)) }
      def function_body_summary_for(name)
        T.bind(self, SemanticAnnotator)
        body_summary_store[name]
      end

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_call_graph
        T.bind(self, SemanticAnnotator)
        body_summary_store.transform_values(&:callees)
      end

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_propagating_callees
        T.bind(self, SemanticAnnotator)
        body_summary_store.transform_values(&:propagating_callees)
      end

      sig { params(name: String).returns(T::Boolean) }
      def function_has_fnptr_call?(name)
        T.bind(self, SemanticAnnotator)
        body_summary_store[name]&.has_fnptr_call == true
      end

      sig { params(name: String).returns(T::Boolean) }
      def function_raises_directly?(name)
        T.bind(self, SemanticAnnotator)
        body_summary_store[name]&.raises_directly == true
      end

      SummaryStore = T.type_alias { T::Hash[String, FunctionBodySummary] }

      sig { returns(SummaryStore) }
      def body_summary_store
        T.bind(self, SemanticAnnotator)
        @body_summaries = T.let(@body_summaries, T.nilable(SummaryStore))
        T.must(@body_summaries)
      end
      private :body_summary_store

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
