# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"

module Annotator
  module Phases
    module AutoFinalization
      extend T::Sig

      sig { params(program: AST::Program).void }
      def finalize_auto_types!(program)
        T.bind(self, SemanticAnnotator)

        return unless program_has_auto?(program)

        run_auto_inference!(program)
      end
    end
  end
end
