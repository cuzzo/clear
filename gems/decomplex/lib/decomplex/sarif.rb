# frozen_string_literal: true

require "json"

module Decomplex
  # Small SARIF 2.1.0 builder shared by the generalized gems. It keeps
  # report producers consistent without each gem hand-rolling subtly
  # different JSON.
  module Sarif
    module_function

    SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"

    def document(tool_name:, rules:, results:, information_uri: nil, properties: {})
      normalized_rules = unique_rules(rules)
      rule_index = normalized_rules.each_with_index.to_h { |rule, idx| [rule.fetch("id"), idx] }
      normalized_results = Array(results).map do |result|
        result = compact_hash(json_safe_value(result))
        rule_id = result["ruleId"]
        result["ruleIndex"] = rule_index[rule_id] if rule_id && rule_index.key?(rule_id)
        result
      end

      run = compact_hash(
        {
          "tool" => {
            "driver" => compact_hash(
              {
                "name" => tool_name,
                "informationUri" => information_uri,
                "rules" => normalized_rules
              }
            )
          },
          "results" => normalized_results,
          "properties" => json_safe_value(properties)
        }
      )
      # GitHub code scanning rejects SARIF runs that omit `results`, even
      # when the tool found nothing.
      run["results"] = normalized_results

      compact_hash(
        {
          "version" => "2.1.0",
          "$schema" => SCHEMA,
          "runs" => [run]
        }
      )
    end

    def json(**kwargs)
      JSON.pretty_generate(document(**kwargs))
    end

    def rule(id:, name: nil, short_description: nil, full_description: nil,
             default_level: "warning", help_uri: nil, properties: {})
      compact_hash(
        {
          "id" => id.to_s,
          "name" => name || id.to_s,
          "shortDescription" => { "text" => short_description || name || id.to_s },
          "fullDescription" => (full_description ? { "text" => full_description } : nil),
          "defaultConfiguration" => { "level" => default_level },
          "helpUri" => help_uri,
          "properties" => json_safe_value(properties)
        }
      )
    end

    def result(rule_id:, message:, path: nil, line: nil, start_column: nil,
               end_line: nil, end_column: nil, level: "warning",
               properties: {}, partial_fingerprints: nil)
      compact_hash(
        {
          "ruleId" => rule_id.to_s,
          "level" => level,
          "message" => { "text" => message.to_s },
          "locations" => sarif_locations(
            path: path,
            line: line,
            start_column: start_column,
            end_line: end_line,
            end_column: end_column
          ),
          "partialFingerprints" => json_safe_value(partial_fingerprints),
          "properties" => json_safe_value(properties)
        }
      )
    end

    def sarif_locations(path:, line:, start_column: nil, end_line: nil, end_column: nil)
      return [] if path.to_s.empty?

      [
        {
          "physicalLocation" => compact_hash(
            {
              "artifactLocation" => { "uri" => normalize_path(path) },
              "region" => compact_hash(
                {
                  "startLine" => positive_int(line, 1),
                  "startColumn" => positive_int(start_column),
                  "endLine" => positive_int(end_line),
                  "endColumn" => positive_int(end_column)
                }
              )
            }
          )
        }
      ]
    end

    def normalize_path(path)
      path.to_s.tr("\\", "/").sub(%r{\A\./}, "")
    end

    def slug(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    end

    def json_safe_value(value)
      case value
      when Hash
        value.to_h { |key, child| [key.to_s, json_safe_value(child)] }
      when Array
        value.map { |child| json_safe_value(child) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), out|
        next if value.nil?
        next if value.respond_to?(:empty?) && value.empty?

        out[key] = value
      end
    end

    def positive_int(value, fallback = nil)
      number = value.nil? ? fallback : value
      return nil if number.nil?

      number = number.to_i
      number.positive? ? number : fallback
    end

    def unique_rules(rules)
      seen = {}
      Array(rules).filter_map do |rule|
        rule = json_safe_value(rule)
        id = rule["id"].to_s
        next if id.empty? || seen[id]

        seen[id] = true
        compact_hash(rule)
      end
    end
  end
end
