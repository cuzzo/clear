# typed: false
# frozen_string_literal: true

module NilKill
  module Schema
    class EvidenceBundle
      SCHEMA_VERSION = 2

      def self.build(root:, static:, runtime:, actions: [], diagnostics: [], languages: nil, metadata: {})
        static = canonical_static(static)
        runtime = canonical_runtime(runtime)
        languages ||= infer_languages(static, runtime, actions)
        {
          "schema_version" => SCHEMA_VERSION,
          "tool" => "nil-kill",
          "generated_at" => Time.now.utc.iso8601,
          "root" => root.to_s,
          "languages" => Array(languages).map(&:to_s).reject(&:empty?).uniq.sort,
          "targets" => NilKill.target_dirs.map { |dir| NilKill.rel(dir) },
          "static" => static,
          "runtime" => runtime,
          "actions" => Array(actions),
          "diagnostics" => Array(diagnostics),
          "metadata" => metadata,
        }
      end

      def self.v2?(evidence)
        evidence.is_a?(Hash) && evidence["schema_version"].to_i == SCHEMA_VERSION && evidence.key?("static")
      end

      def self.canonical_static(static)
        raw = static || {}
        return raw["static"] if raw.is_a?(Hash) && raw["static"].is_a?(Hash)

        {
          "files" => Array(raw["files"]),
          "owners" => Array(raw["owners"]),
          "methods" => Array(raw["methods"]),
          "fields" => Array(raw["fields"]),
          "callsites" => Array(raw["callsites"]),
          "state_reads" => Array(raw["state_reads"]),
          "state_writes" => Array(raw["state_writes"]),
          "param_origins" => Array(raw.dig("facts", "param_origins") || raw["param_origins"]),
          "return_origins" => Array(raw.dig("facts", "return_origins") || raw["return_origins"]),
          "nil_guards" => Array(raw["nil_guards"]),
          "type_assertions" => Array(raw["type_assertions"]),
          "collections" => Array(raw["collections"]),
          "language_capabilities" => Hash(raw["language_capabilities"] || {}),
          "language_extensions" => Hash(raw["language_extensions"] || {}),
        }.tap do |out|
          if raw["kind"] == "espalier_static_evidence"
            out["methods"] = Array(raw["methods"])
            out["facts"] = raw["facts"] || {}
            out["summary"] = raw["summary"] || {}
            out["language_extensions"]["nil_kill_static_evidence"] = {
              "facts" => raw["facts"] || {},
              "summary" => raw["summary"] || {},
              "language_capabilities" => raw["language_capabilities"] || {},
            }
          end
        end
      end

      def self.canonical_runtime(runtime)
        runtime || {
          "runs" => [],
          "method_hits" => {},
          "param_observations" => {},
          "return_observations" => {},
          "field_observations" => {},
          "collection_observations" => {},
          "hash_shape_observations" => {},
          "call_edges" => [],
          "coverage" => {},
          "exceptions" => {},
          "diagnostics" => [],
        }
      end

      def self.infer_languages(static, runtime, actions)
        languages = []
        Array(static["files"]).each { |file| languages << file["language"] }
        Array(static["methods"]).each { |method| languages << (method["language"] || method["lang"]) }
        Array(static["fields"]).each { |field| languages << field["language"] }
        Hash(runtime["method_hits"]).each_value { |hit| languages << hit["language"] }
        Array(actions).each { |action| languages << action["language"] }
        languages.compact
      end
    end
  end
end
