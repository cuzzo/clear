# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    class UnsupportedRuntimeTracer < StandardError; end

    class Provider
      def language
        raise NotImplementedError
      end

      def aliases
        []
      end

      def display_name
        language.to_s
      end

      def extensions
        []
      end

      def static_analysis?
        true
      end

      def static_parser
        "tree_sitter"
      end

      # Real checker/indexer backends only. Syntax annotations are reported
      # separately so capability metadata does not overclaim semantic typing.
      def type_systems
        []
      end

      def annotation_systems
        []
      end

      def type_indexing?
        !type_systems.empty?
      end

      def runtime_tracing?
        false
      end

      def runtime_trace_events
        []
      end

      def runtime_capabilities
        {
          "method_calls" => false,
          "params" => false,
          "returns" => false,
          "exceptions" => false,
          "fields" => false,
          "collections" => false,
          "hash_shapes" => false,
          "call_edges" => false,
          "line_coverage" => false,
        }
      end

      def notes
        []
      end

      def capability
        {
          "language" => language.to_s,
          "display_name" => display_name,
          "aliases" => aliases.map(&:to_s),
          "extensions" => extensions.map(&:to_s).sort,
          "static_analysis" => static_analysis?,
          "static_parser" => static_parser,
          "annotation_systems" => annotation_systems.map(&:to_s).sort,
          "type_indexing" => type_indexing?,
          "type_systems" => type_systems.map(&:to_s).sort,
          "runtime_tracing" => runtime_tracing?,
          "runtime_trace_events" => runtime_trace_events.map(&:to_s).sort,
          "runtime_capabilities" => runtime_capabilities,
          "notes" => notes.map(&:to_s),
        }
      end

      def collect_runtime(argv:, root:, output:, targets:, append: false)
        raise UnsupportedRuntimeTracer, "#{display_name} does not have a Nil-Kill runtime tracer provider"
      end

      def return_type_index(root:)
        nil
      end

      def field_type_index(root:)
        {}
      end

      def static_diff_findings(root:, added_lines:, context_paths:, finding_class:)
        []
      end
    end

    class GenericTreeSitterProvider < Provider
      def initialize(language)
        @language = language.to_s
      end

      def language
        @language
      end
    end
  end
end
