# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class TypeScript < Provider
        def language
          "typescript"
        end

        def aliases
          ["ts"]
        end

        def display_name
          "TypeScript"
        end

        def extensions
          %w[.ts .tsx]
        end

        def annotation_systems
          ["typescript"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["annotation parsing is Tree-sitter static evidence; no TypeScript compiler backend is wired yet"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::TypeScript.new)
