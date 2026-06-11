# frozen_string_literal: true

require "yaml"

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
  end
end
