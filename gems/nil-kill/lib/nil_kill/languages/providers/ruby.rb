# typed: false
# frozen_string_literal: true

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
          "prism"
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

        private

        def self_receiver_names
          %w[self]
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Ruby.new)
