# frozen_string_literal: true

require "yaml"
require "json"
require_relative "dependency_graph"
require_relative "graphviz_formatter"
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

    def to_dot(manifest)
      GraphvizFormatter.new(DependencyGraph.from_manifest(manifest)).to_dot
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
          id: "espalier.function",
          name: "Impure Function",
          short_description: "Function/method with direct state effects",
          default_level: "note"
        )
      ]
    end

    def sarif_results(manifest)
      Array(manifest).flat_map do |mod|
        function_results(mod)
      end
    end

    def function_results(mod)
      Array(mod[:functions]).filter_map { |fn| impure_function_result(mod, fn) }
    end

    def impure_function_result(mod, fn)
      effects = fn[:EFFECTS] || fn["EFFECTS"] || fn[:effects] || fn["effects"] || {}
      reads = Array(effects[:reads] || effects["reads"])
      writes = Array(effects[:writes] || effects["writes"])
      return nil if reads.empty? && writes.empty?
      effect_kind = writes.empty? ? "read-only function" : "impure function"

      Decomplex::Sarif.result(
        rule_id: "espalier.function",
        level: "note",
        message: "#{effect_kind}: #{mod[:module]}##{fn[:name]}",
        path: mod[:file],
        line: fn[:line] || span_line(fn, 0) || 1,
        end_line: span_line(fn, 2),
        properties: {
          "module" => mod[:module],
          "function" => Decomplex::Sarif.json_safe_value(fn),
          "effects" => {
            "reads" => reads,
            "writes" => writes
          },
          "source_format" => "espalier.manifest.v1"
        }
      )
    end

    def span_line(fn, index)
      span = fn[:span] || fn["span"]
      Array(span)[index]
    end
  end
end
