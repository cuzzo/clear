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
        actions.concat(static_fact_actions)
        actions.concat(param_nullability_actions)
        actions.concat(return_nullability_actions)
        actions.concat(field_nullability_actions)
        actions.sort_by { |action| [action["path"].to_s, action["line"].to_i, action["kind"].to_s, action.dig("data", "name").to_s] }
      end

      private

      def static_fact_actions
        facts = Hash(@static["facts"])
        actions = Array(facts["dead_nil_checks"]).filter_map { |fact| dead_nil_check_action(fact) }
        actions.concat(Array(facts["deterministic_guards"]).filter_map { |fact| deterministic_guard_action(fact) })
        actions.uniq { |action| action["id"] }
      end

      def dead_nil_check_action(fact)
        return unless fact.is_a?(Hash)

        operation = fact["kind"] == "nil_check" ? "replace_condition" : "remove_safe_navigation"
        build_static_action(
          fact,
          "dead_nil_check",
          fact["reason"].to_s,
          fact.merge("operation" => operation)
        )
      end

      def deterministic_guard_action(fact)
        return unless fact.is_a?(Hash)
        return unless fact["proof_tier"] == "static_proven"
        return if fact["predicate_kind"] == "nil_check"

        build_static_action(
          fact,
          "deterministic_guard",
          "#{fact["code"]} is always #{fact["truth_value"]}: #{fact["reason"]}",
          fact
        )
      end

      def build_static_action(fact, provenance_kind, message, data)
        path = fact["path"].to_s
        line = fact["line"].to_i
        language = static_fact_language(fact, path)
        symbol_id = [language, path, "static_fact", provenance_kind, line, fact["code"]].join("\0")
        Actions::Record.build(
          kind: "replace_deterministic_guard",
          language: language,
          confidence: REVIEW,
          target: { "path" => path, "line" => line, "symbol_id" => symbol_id },
          message: message,
          data: data,
          provenance: { "static_fact" => provenance_kind }
        )
      end

      def static_fact_language(fact, path)
        return fact["language"].to_s unless fact["language"].to_s.empty?

        file = Array(@static["files"]).find { |entry| entry.is_a?(Hash) && entry["path"].to_s == path }
        return file["language"].to_s if file && !file["language"].to_s.empty?

        languages = Array(@evidence["languages"]).map(&:to_s).reject(&:empty?).uniq
        languages.one? ? languages.first : ""
      end

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
