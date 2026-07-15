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

        # TypeScript declarations are optional and structurally inferred. An
        # unresolved flow root can therefore be actionable review advice: it
        # may need an annotation, a narrower declaration, or a compiler-backed
        # verification. This is unlike Go/C++/Java, where an absent declared
        # type is normally an analyzer extraction failure rather than a source
        # authoring decision.
        def type_next_annotation_advice?
          true
        end

        def notes
          ["annotation parsing is Tree-sitter static evidence; no TypeScript compiler backend is wired yet"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::TypeScript.new)
