# frozen_string_literal: true

require "yaml"
require "json"
sibling_sarif = File.expand_path("../../../decomplex/lib/decomplex/sarif", __dir__)
if File.file?("#{sibling_sarif}.rb")
  require sibling_sarif
else
  require "decomplex/sarif"
end

module Espalier
  # Transforms synthesized schemas into Markdown or clean structured formats
  # optimized for LLM ingestion efficiency.
  module Formatter
    module_function

    def to_markdown(manifest)
      manifest.map do |mod|
        output = []
        output << "## #{mod[:type].to_s.capitalize}: #{mod[:module]}"
        output << "- **File**: `#{mod[:file]}`"
        
        if mod[:state] && !mod[:state].empty?
          output << ""
          output << "### State:"
          mod[:state].each do |s|
            type_suffix = s[:type] ? " [#{s[:type]}]" : ""
            props = s[:properties] && !s[:properties].empty? ? " (#{s[:properties].join(', ')})" : ""
            output << "- `#{s[:name]}`#{type_suffix}#{props}"
          end
        end

        output << ""
        output << "### Functions:"
        mod[:functions].each do |fn|
          output << "#### - `#{fn[:name]}`"
          output << "  - **Signature**: `#{fn[:signature]}`"
          output << "  - **Visibility**: `#{fn[:visibility] || :public}`"
          
          # Print effects compactly
          reads = fn[:EFFECTS][:reads].map { |r| "`#{r}`" }.join(", ")
          writes = fn[:EFFECTS][:writes].map { |w| "`#{w}`" }.join(", ")
          
          output << "  - **EFFECTS**:"
          output << "    - reads: [#{reads}]" unless reads.empty?
          output << "    - writes: [#{writes}]" unless writes.empty?
          output << "    - pure (no effects)" if reads.empty? && writes.empty?

          if fn[:DELEGATIONS]
            output << "  - **DELEGATIONS**:"
            if fn[:DELEGATIONS][:always_calls]
              output << "    - always_calls: [#{fn[:DELEGATIONS][:always_calls].map { |c| "`#{c}`" }.join(', ')}]"
            end
            if fn[:DELEGATIONS][:conditionally_calls]
              output << "    - conditionally_calls: [#{fn[:DELEGATIONS][:conditionally_calls].map { |c| "`#{c}`" }.join(', ')}]"
            end
          end

          if fn[:CALL_GRAPH]
            output << "  - **CALL_GRAPH**:"
            if fn[:CALL_GRAPH][:internal_callers]
              output << "    - internal_callers: [#{fn[:CALL_GRAPH][:internal_callers].map { |c| "`#{c}`" }.join(', ')}]"
            end
            if fn[:CALL_GRAPH][:internal_calls]
              output << "    - internal_calls: [#{fn[:CALL_GRAPH][:internal_calls].map { |c| "`#{c}`" }.join(', ')}]"
            end
          end

          if fn[:quality_metrics] && !fn[:quality_metrics].empty?
            output << "  - **METRICS**:"
            fn[:quality_metrics].each do |k, v|
              output << "    - #{k}: #{v}"
            end
          end
        end

        output.join("\n")
      end.join("\n\n---\n\n")
    end

    def to_yaml(manifest)
      YAML.dump(manifest)
    end

    def to_sarif(manifest)
      JSON.pretty_generate(to_sarif_hash(manifest))
    end

    def to_sarif_hash(manifest)
      Decomplex::Sarif.document(
        tool_name: "Espalier",
        information_uri: "https://github.com/codeforreno/litedb",
        rules: sarif_rules,
        results: sarif_results(manifest),
        properties: {
          "format" => "espalier.manifest.sarif.v1",
          "espalier.manifest" => Decomplex::Sarif.json_safe_value(manifest)
        }
      )
    end

    def sarif_rules
      [
        Decomplex::Sarif.rule(
          id: "espalier.owner",
          name: "Owner",
          short_description: "Static architecture owner/module record",
          default_level: "note"
        ),
        Decomplex::Sarif.rule(
          id: "espalier.state",
          name: "State",
          short_description: "State owned by an architecture owner",
          default_level: "note"
        ),
        Decomplex::Sarif.rule(
          id: "espalier.function",
          name: "Function",
          short_description: "Function/method static architecture record",
          default_level: "note"
        ),
        Decomplex::Sarif.rule(
          id: "espalier.privacy-candidate",
          name: "Privacy Candidate",
          short_description: "Public function appears to be same-owner helper behavior"
        )
      ]
    end

    def sarif_results(manifest)
      Array(manifest).flat_map do |mod|
        owner_result(mod) + state_results(mod) + function_results(mod)
      end
    end

    def owner_result(mod)
      [
        Decomplex::Sarif.result(
          rule_id: "espalier.owner",
          level: "note",
          message: "owner: #{mod[:module]}",
          path: mod[:file],
          line: 1,
          properties: {
            "module" => mod[:module],
            "language" => mod[:language],
            "type" => mod[:type],
            "source_format" => "espalier.manifest.v1"
          }
        )
      ]
    end

    def state_results(mod)
      Array(mod[:state]).map do |state|
        Decomplex::Sarif.result(
          rule_id: "espalier.state",
          level: "note",
          message: "state: #{mod[:module]} #{state[:name]}",
          path: mod[:file],
          line: 1,
          properties: {
            "module" => mod[:module],
            "state" => Decomplex::Sarif.json_safe_value(state),
            "source_format" => "espalier.manifest.v1"
          }
        )
      end
    end

    def function_results(mod)
      Array(mod[:functions]).flat_map do |fn|
        metrics = fn[:quality_metrics] || {}
        base = Decomplex::Sarif.result(
          rule_id: "espalier.function",
          level: "note",
          message: "function: #{mod[:module]}##{fn[:name]}",
          path: mod[:file],
          line: fn[:line] || span_line(fn, 0) || 1,
          end_line: span_line(fn, 2),
          properties: {
            "module" => mod[:module],
            "function" => Decomplex::Sarif.json_safe_value(fn),
            "source_format" => "espalier.manifest.v1"
          }
        )
        privacy = if metrics[:privacy_candidate] || metrics["privacy_candidate"]
                    Decomplex::Sarif.result(
                      rule_id: "espalier.privacy-candidate",
                      level: "warning",
                      message: "privacy candidate: #{mod[:module]}##{fn[:name]}",
                      path: mod[:file],
                      line: fn[:line] || span_line(fn, 0) || 1,
                      end_line: span_line(fn, 2),
                      properties: {
                        "module" => mod[:module],
                        "function" => fn[:name],
                        "quality_metrics" => Decomplex::Sarif.json_safe_value(metrics),
                        "source_format" => "espalier.manifest.v1"
                      }
                    )
                  end
        [base, privacy].compact
      end
    end

    def span_line(fn, index)
      span = fn[:span] || fn["span"]
      Array(span)[index]
    end
  end
end
