# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Providers
      class Python < Provider
        def language
          "python"
        end

        def aliases
          ["py"]
        end

        def display_name
          "Python"
        end

        def extensions
          %w[.py .pyi]
        end

        def annotation_systems
          ["python-typing"]
        end

        def runtime_tracing?
          true
        end

        def type_next_annotation_advice?
          true
        end

        def runtime_trace_events
          %w[
            process_start
            process_end
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

        def notes
          ["annotation parsing is Tree-sitter static evidence; no Python type-checker backend is wired yet"]
        end


        private

      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Python.new)
