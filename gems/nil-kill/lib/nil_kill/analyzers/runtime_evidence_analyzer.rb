# typed: false
# frozen_string_literal: true

module NilKill
  module Analyzers
    class RuntimeEvidenceAnalyzer
      def initialize(evidence)
        @evidence = evidence
        @static = evidence["static"] || {}
        @runtime = evidence["runtime"] || {}
        @methods = Array(@static["methods"]).each_with_object({}) do |method, index|
          id = method["id"].to_s
          index[id] = method unless id.empty?
        end
        @fields = Array(@static["fields"]).each_with_object({}) do |field, index|
          id = field["id"].to_s
          index[id] = field unless id.empty?
        end
      end

      def analyze
        actions = []
        actions.concat(param_nullability_actions)
        actions.concat(return_nullability_actions)
        actions.concat(field_nullability_actions)
        actions.sort_by { |action| [action["path"].to_s, action["line"].to_i, action["kind"].to_s, action.dig("data", "name").to_s] }
      end

      private

      def param_nullability_actions
        Hash(@runtime["param_observations"]).flat_map do |method_id, params|
          method = @methods[method_id] || Hash(@runtime.dig("method_hits", method_id))
          Array(params).filter_map do |name, obs|
            param = Array(method["params"]).find { |entry| entry.is_a?(Hash) && entry["name"].to_s == name.to_s }
            next unless nullable_observed?(obs)
            next unless declared_non_nullable?(param)

            build_action(
              "add_nullability",
              method,
              "param #{name} observed null/nil but static declaration is non-null",
              { "slot" => "param", "name" => name, "observed_types" => display_types(obs), "declared_type" => param["declared_type"] },
              method_id
            )
          end
        end
      end

      def return_nullability_actions
        Hash(@runtime["return_observations"]).filter_map do |method_id, obs|
          method = @methods[method_id] || Hash(@runtime.dig("method_hits", method_id))
          ret = method["return"] || {}
          next unless nullable_observed?(obs)
          next unless declared_non_nullable?(ret)

          build_action(
            "add_nullability",
            method,
            "return observed null/nil but static declaration is non-null",
            { "slot" => "return", "observed_types" => display_types(obs), "declared_type" => ret["declared_type"] },
            method_id
          )
        end
      end

      def field_nullability_actions
        Hash(@runtime["field_observations"]).filter_map do |field_id, obs|
          field = @fields[field_id] || obs
          next unless nullable_observed?(obs)
          next unless declared_non_nullable?(field)

          build_action(
            "add_nullability",
            field,
            "field #{field["name"] || field["field"]} observed null/nil but static declaration is non-null",
            { "slot" => "field", "name" => field["name"] || field["field"], "observed_types" => display_types(obs), "declared_type" => field["declared_type"] },
            field_id
          )
        end
      end

      def build_action(kind, subject, message, data, symbol_id)
        language = subject["language"].to_s
        target = {
          "path" => subject["path"].to_s,
          "line" => subject["line"].to_i,
          "symbol_id" => symbol_id.to_s,
        }
        Actions::Record.build(
          kind: kind,
          language: language,
          confidence: REVIEW,
          target: target,
          message: message,
          data: data,
          provenance: { "runtime" => [symbol_id.to_s] }
        )
      end

      def nullable_observed?(obs)
        Array(obs && obs["types"]).any? { |type| Schema::RuntimeType.nullable?(type) }
      end

      def display_types(obs)
        Array(obs && obs["types"]).map { |type| type["display"] || type["name"] }.compact.uniq.sort
      end

      def declared_non_nullable?(entry)
        return false unless entry.is_a?(Hash)
        return true if entry.key?("nilable") && entry["nilable"] == false

        declared = entry["declared_type"].to_s
        return false if declared.empty?

        !declared.match?(/\b(nil|NilClass|null|None|undefined|Optional)\b|\?/)
      end
    end
  end
end
