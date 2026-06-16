# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Rust < Provider
        def language
          "rust"
        end

        def aliases
          ["rs"]
        end

        def display_name
          "Rust"
        end

        def extensions
          [".rs"]
        end

        def runtime_tracing?
          false
        end

        def notes
          ["static Tree-sitter evidence is supported; runtime tracing is not implemented for Rust"]
        end

        private

        def self_receiver_names
          %w[self]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Rust.new)
