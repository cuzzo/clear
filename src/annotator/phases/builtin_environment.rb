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

      sig { void }
      def setup_builtins
        T.bind(self, SemanticAnnotator)

        STD_LIB.each_key do |name|
          current_scope.declare(name, nil, :Intrinsic, false, false, nil, :stack)
        end

        BUILTIN_GLOBAL_BINDINGS.each do |binding|
          current_scope.declare(binding.name, nil, binding.type, false, false, nil, binding.storage)
        end

        BUILTIN_TYPE_BINDINGS.each do |binding|
          current_scope.install_type(binding.name, binding.schema_factory.call)
        end
        nil
      end
    end
  end
end
