# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class C < Provider
        def language
          "c"
        end

        def display_name
          "C"
        end

        def extensions
          %w[.c .h]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for C"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::C.new)
