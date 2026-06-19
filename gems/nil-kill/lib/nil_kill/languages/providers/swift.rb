# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Swift < Provider
        def language
          "swift"
        end

        def display_name
          "Swift"
        end

        def extensions
          [".swift"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for Swift"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Swift.new)
