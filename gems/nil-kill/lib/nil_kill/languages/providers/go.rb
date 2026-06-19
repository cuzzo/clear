# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Go < Provider
        def language
          "go"
        end

        def aliases
          ["golang"]
        end

        def display_name
          "Go"
        end

        def extensions
          [".go"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for Go"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Go.new)
