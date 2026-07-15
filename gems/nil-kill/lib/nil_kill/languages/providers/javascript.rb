# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class JavaScript < Provider
        def language
          "javascript"
        end

        def aliases
          ["js", "node"]
        end

        def display_name
          "JavaScript"
        end

        def extensions
          %w[.js .jsx .mjs .cjs]
        end

        def annotation_systems
          ["jsdoc"]
        end

        def runtime_tracing?
          false
        end

        def type_next_annotation_advice?
          true
        end

        def notes
          ["JSDoc parsing is Tree-sitter static evidence; no JavaScript runtime tracer is wired yet"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::JavaScript.new)
