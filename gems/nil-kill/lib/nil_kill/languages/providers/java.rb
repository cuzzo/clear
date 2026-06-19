# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Java < Provider
        def language
          "java"
        end

        def display_name
          "Java"
        end

        def extensions
          [".java"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for Java"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Java.new)
