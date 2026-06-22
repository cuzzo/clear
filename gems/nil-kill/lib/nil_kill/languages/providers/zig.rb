# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Zig < Provider
        def language
          "zig"
        end

        def display_name
          "Zig"
        end

        def extensions
          [".zig"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for Zig"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Zig.new)
