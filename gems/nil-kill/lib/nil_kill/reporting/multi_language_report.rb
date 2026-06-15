# typed: false
# frozen_string_literal: true

module NilKill
  module Reporting
    class MultiLanguageReport
      def initialize(evidence)
        @evidence = evidence
      end

      def lines
        [
          "# Nil Kill Multi-Language Report",
          "",
          "- Schema version: #{@evidence["schema_version"]}",
          "- Languages: #{Array(@evidence["languages"]).join(", ")}",
          "- Static files: #{files.size}",
          "- Static methods/functions: #{methods.size}",
          "- Static fields: #{fields.size}",
          "- Runtime-observed methods/functions: #{method_hits.size}",
          "- Param observations: #{param_observation_count}",
          "- Return observations: #{return_observation_count}",
          "- Field observations: #{field_observation_count}",
          "- Actions: #{actions.size}",
          "- Diagnostics: #{diagnostics.size}",
          "",
        ] + action_lines + diagnostic_lines + observation_lines
      end

      private

      def static
        @evidence["static"] || {}
      end

      def runtime
        @evidence["runtime"] || {}
      end

      def files
        Array(static["files"])
      end

      def methods
        Array(static["methods"])
      end

      def fields
        Array(static["fields"])
      end

      def method_hits
        Hash(runtime["method_hits"])
      end

      def actions
        Array(@evidence["actions"])
      end

      def diagnostics
        Array(@evidence["diagnostics"])
      end

      def param_observation_count
        Hash(runtime["param_observations"]).sum { |_id, params| Hash(params).size }
      end

      def return_observation_count
        Hash(runtime["return_observations"]).size
      end

      def field_observation_count
        Hash(runtime["field_observations"]).size
      end

      def action_lines
        lines = ["## Actions", ""]
        if actions.empty?
          lines << "- None"
          return lines + [""]
        end
        actions.first(100).each do |action|
          path = action.dig("target", "path") || action["path"]
          line = action.dig("target", "line") || action["line"]
          lines << "- #{path}:#{line} #{action["kind"]} [#{action["confidence"]}]: #{action["message"]}"
        end
        lines << "- ... #{actions.size - 100} more" if actions.size > 100
        lines << ""
        lines
      end

      def diagnostic_lines
        lines = ["## Diagnostics", ""]
        if diagnostics.empty?
          lines << "- None"
          return lines + [""]
        end
        diagnostics.first(50).each do |diagnostic|
          site = [diagnostic["path"], diagnostic["line"]].compact.join(":")
          lines << "- #{diagnostic["severity"] || "warning"} #{diagnostic["code"]}: #{[site, diagnostic["message"]].reject(&:empty?).join(" ")}"
        end
        lines << "- ... #{diagnostics.size - 50} more" if diagnostics.size > 50
        lines << ""
        lines
      end

      def observation_lines
        lines = ["## Runtime Observations", ""]
        if method_hits.empty?
          lines << "- None"
          return lines
        end
        method_hits.values.sort_by { |hit| [hit["path"].to_s, hit["line"].to_i, hit["name"].to_s] }.first(100).each do |hit|
          lines << "- #{hit["path"]}:#{hit["line"]} #{hit["owner"]}#{hit["owner"].to_s.empty? ? "" : "#"}#{hit["name"]}: #{hit["calls"]} call(s), #{hit["ok_calls"]} return(s), #{hit["raised_calls"]} raise(s)"
        end
        lines << "- ... #{method_hits.size - 100} more" if method_hits.size > 100
        lines
      end
    end
  end
end
