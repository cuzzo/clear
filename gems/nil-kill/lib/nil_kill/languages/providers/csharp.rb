# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class CSharp < Provider
        def language
          "csharp"
        end

        def aliases
          ["c#", "c_sharp", "cs"]
        end

        def display_name
          "C#"
        end

        def extensions
          [".cs"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for C#"]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::CSharp.new)
