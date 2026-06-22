# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Lua < Provider
        def language
          "lua"
        end

        def display_name
          "Lua"
        end

        def extensions
          [".lua"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for Lua"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Lua.new)
