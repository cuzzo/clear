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

      # Whether an unresolved static-flow root is a useful request for a
      # maintainer to add or verify a source annotation. This is deliberately
      # separate from parsing and tracing: in a language with mandatory
      # declarations, it is analyzer precision work rather than user advice.
      def type_next_annotation_advice?
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
          "runtime_scip_calls" => false,
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
          "type_next_annotation_advice" => type_next_annotation_advice?,
          "runtime_trace_events" => runtime_trace_events.map(&:to_s).sort,
          "runtime_capabilities" => runtime_capabilities,
          "notes" => notes.map(&:to_s),
        }
      end

      def collect_runtime(argv:, root:, output:, targets:, append: false)
        raise UnsupportedRuntimeTracer, "#{display_name} does not have a Nil-Kill runtime tracer provider"
      end

      # Opaque semantic-environment claims attached to runtime SCIP output.
      # Language and package-manager discovery belongs in providers; the
      # shared SCIP encoder only records and hashes supplied values.
      def runtime_scip_environment(root:)
        {}
      end

      # Mechanically decode one tracer-owned call event into the neutral
      # runtime-evidence call shape. Package/symbol grammar and source-language
      # naming conventions belong to the provider.
      def runtime_scip_call_evidence(event:, root:)
        raise UnsupportedRuntimeTracer,
          "#{display_name} does not implement runtime call evidence decoding"
      end

      # Serialize tracer-owned value observations into the shared FactMine
      # runtime evidence contract. Providers may decode their own trace storage
      # here, but must not inspect source or infer flow relationships.
      def runtime_value_observations(runtime_dir:, root:)
        []
      end

      # Language-owned serialization of native runtime identities into
      # canonical SCIP symbols. Shared protocol code treats these as opaque.
      def runtime_evidence_type_symbol(type)
        raise UnsupportedRuntimeTracer,
          "#{display_name} does not implement runtime type SCIP identities"
      end

      def runtime_evidence_singleton_symbol(type)
        raise UnsupportedRuntimeTracer,
          "#{display_name} does not implement runtime singleton SCIP identities"
      end

      def runtime_evidence_provenance
        {
          "provider" => "#{language}-runtime",
          "provider_version" => "1",
        }
      end

      # Stable digest of source semantics that can affect runtime evidence.
      # Providers may ignore representation-only edits, but must fall back to
      # content hashing whenever they cannot prove such an edit irrelevant.
      def runtime_incremental_fingerprint(path)
        Digest::SHA256.file(path).hexdigest
      end

      # Optional language-owned test discovery/command sharding. Returning nil
      # preserves the supplied commands as opaque, correctness-first shards.
      def runtime_test_plan(root:, targets:, commands:)
        nil
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
