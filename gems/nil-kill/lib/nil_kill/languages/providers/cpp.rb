# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Cpp < Provider
        def language
          "cpp"
        end

        def aliases
          ["c++", "cplusplus"]
        end

        def display_name
          "C++"
        end

        def extensions
          %w[.cc .cpp .cxx .hh .hpp .hxx]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for C++", "use --language cpp for C++ .h headers"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Cpp.new)
