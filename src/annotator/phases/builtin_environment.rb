# typed: strict
require "sorbet-runtime"

module Annotator
  module Phases
    module BuiltinEnvironment
      extend T::Sig

      sig { void }
      def initialize_builtin_environment!
        T.bind(self, SemanticAnnotator)
        setup_builtins
      end
    end
  end
end
