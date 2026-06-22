# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Kotlin < Provider
        def language
          "kotlin"
        end

        def aliases
          ["kt"]
        end

        def display_name
          "Kotlin"
        end

        def extensions
          %w[.kt .kts]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for Kotlin"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Kotlin.new)
