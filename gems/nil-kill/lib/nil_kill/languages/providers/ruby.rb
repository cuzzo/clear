# typed: false
# frozen_string_literal: true

require_relative "ruby/sorbet"

module NilKill
  module Languages
    module Providers
      class Ruby < Provider
        def language
          "ruby"
        end

        def extensions
          [".rb"]
        end

        def static_parser
          "tree_sitter"
        end

        def type_systems
          sorbet.type_systems
        end

        def runtime_tracing?
          true
        end

        def runtime_trace_events
          %w[
            method_call
            method_return
            method_raise
            param_observed
            field_observed
            collection_observed
            hash_shape_observed
            call_edge
            coverage
          ]
        end

        def runtime_capabilities
          super.merge(
            "method_calls" => true,
            "params" => true,
            "returns" => true,
            "exceptions" => true,
            "fields" => true,
            "collections" => true,
            "hash_shapes" => true,
            "call_edges" => true,
            "line_coverage" => true
          )
        end

        def autofix?
          true
        end

        def notes
          ["runtime collection uses the existing nil-kill collect command and Ruby source instrumentation"]
        end

        def method_source(function_def)
          sorbet.method_source(function_def)
        end

        def static_method_signature(function_def)
          sorbet.signature_for(function_def)
        end

        def type_definitions(document:, facts:, rel_path:, methods:, state_declarations:)
          sorbet.type_definitions(
            rel_path: rel_path,
            function_defs: Array(facts[:function_defs]),
            state_declarations: state_declarations,
            provider: self
          )
        end

        def return_type_index(root:)
          sorbet.return_type_index(root: root)
        end

        def field_type_index(root:)
          sorbet.field_type_index(root: root)
        end

        def external_type_definitions(root:)
          sorbet.external_type_definitions(root: root)
        end

        def sorbet
          @sorbet ||= Sorbet.new
        end

        private

        def self_receiver_names
          %w[self]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Ruby.new)
