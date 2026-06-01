# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "declaration_index"

module Annotator
  module Phases
    module BodyAnalysis
      extend T::Sig

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
