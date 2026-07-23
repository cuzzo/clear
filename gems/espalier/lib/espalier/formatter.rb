# frozen_string_literal: true

require "yaml"
require "json"
require_relative "dependency_graph"
require_relative "graphviz_formatter"
require_relative "type_profile"

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
      results = sarif_results(manifest)
      Decomplex::Sarif.document(
        tool_name: "Espalier",
        information_uri: "https://github.com/codeforreno/litedb",
        rules: sarif_rules,
        results: results,
        properties: {
          "format" => "espalier.manifest.sarif.v1",
          "espalier.manifest" => Decomplex::Sarif.json_safe_value(manifest),
          Decomplex::Sarif::PROOF_BOUNDARY_SUMMARY_PROPERTY => Decomplex::Sarif.proof_boundary_summary(results)
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
        ),
        Decomplex::Sarif.rule(
          id: "complexity.observation",
          name: "Complexity Observation",
          short_description: "Function time and auxiliary-space complexity",
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
      Array(mod[:functions]).flat_map do |fn|
        [impure_function_result(mod, fn), complexity_result(mod, fn)].compact
      end
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
          "source_format" => "espalier.manifest.v1",
          Decomplex::Sarif::PROOF_BOUNDARY_PROPERTY => Decomplex::Sarif.proof_boundary(
            input_completeness: input_completeness_for(mod),
            claim_status: "observed",
            coverage_discharge: "not_applicable",
            authority: ["fact_mine_normalized_ast"],
            claim_kind: "function_effect_observation",
            scope: { kind: "function", closed: false },
            blockers: input_blockers_for(mod)
          )
        }
      )
    end

    def complexity_result(mod, fn)
      metrics = fn[:quality_metrics] || fn["quality_metrics"]
      return nil unless metrics.is_a?(Hash)

      time = metrics[:big_o] || metrics["big_o"]
      space = metrics[:big_o_space] || metrics["big_o_space"] || "O(1)"
      known_time = metrics[:big_o_known_component] || metrics["big_o_known_component"] || time
      known_space = metrics[:big_o_space_known_component] || metrics["big_o_space_known_component"] || space
      time_complete = metrics.key?(:big_o_complete) ? metrics[:big_o_complete] : metrics["big_o_complete"]
      space_complete = metrics.key?(:big_o_space_complete) ? metrics[:big_o_space_complete] : metrics["big_o_space_complete"]
      return nil if time.to_s.empty?

      dynamic = metrics.key?(:big_o_dynamic) ? metrics[:big_o_dynamic] : metrics["big_o_dynamic"]
      dynamic = true if dynamic.nil?
      trigger = metrics[:complexity_trigger] || metrics["complexity_trigger"]
      warnings = Array(metrics[:big_o_warnings] || metrics["big_o_warnings"])
      unknowns = Array(metrics[:big_o_unknowns] || metrics["big_o_unknowns"])
      variables = Array(metrics[:big_o_variables] || metrics["big_o_variables"])
      owner = mod[:module] || mod["module"]
      function_name = fn[:name] || fn["name"]
      subject_name = "#{owner}##{function_name}"
      estimate = if time_complete && space_complete
                   "estimated runtime #{time} and auxiliary space #{space}"
                 else
                   "incomplete complexity evidence (known runtime component #{known_time}, known auxiliary-space component #{known_space})"
                 end

      result = Decomplex::Sarif.result(
        rule_id: "complexity.observation",
        level: "note",
        message: "#{subject_name} has #{estimate}",
        path: mod[:file] || mod["file"],
        line: fn[:line] || fn["line"] || span_line(fn, 0) || 1,
        end_line: span_line(fn, 2),
        partial_fingerprints: { "subject" => subject_name },
        properties: {
          "category" => "complexity",
          "complexity" => {
            "subject_kind" => "function",
            "subject_name" => subject_name,
            "time" => time,
            "auxiliary_space" => space,
            "known_time_component" => known_time,
            "known_auxiliary_space_component" => known_space,
            "time_complete" => time_complete,
            "auxiliary_space_complete" => space_complete,
            # This measures Espalier's complexity model, not whether
            # FactMine supplied complete source input for the finding.
            "model_completeness" => complexity_model_completeness(time_complete, space_complete),
            "model_blockers" => complexity_model_blockers(
              input_completeness_for(mod), unknowns, warnings, time_complete, space_complete
            ),
            "dynamic" => dynamic,
            "basis" => "espalier-static",
            "confidence" => time_complete && space_complete ? "static-lower-bound" : "partial",
            "triggers" => [trigger].compact,
            "warnings" => warnings,
            "unknown_operations" => unknowns,
            "variables" => variables
          },
          Decomplex::Sarif::PROOF_BOUNDARY_PROPERTY => Decomplex::Sarif.proof_boundary(
            # Big-O completeness describes Espalier's estimate, not the
            # completeness of the FactMine input. The extractor supplies the
            # latter explicitly through the projected module boundary.
            input_completeness: input_completeness_for(mod),
            claim_status: "observed",
            coverage_discharge: "not_applicable",
            authority: ["fact_mine_normalized_ast", "espalier_static"],
            claim_kind: "function_complexity",
            scope: { kind: "function", closed: false },
            blockers: input_blockers_for(mod)
          )
        }
      )
      related = complexity_related_locations(variables)
      result["relatedLocations"] = related unless related.empty?
      result
    end

    def complexity_model_blockers(input_completeness, unknowns, warnings, time_complete, space_complete)
      return [] if time_complete && space_complete

      blockers = []
      blockers << { "kind" => "call_resolution" } unless unknowns.empty?
      blockers << { "kind" => "missing_evidence" } unless warnings.empty?
      blockers << { "kind" => (input_completeness == "unknown" ? "unknown" : "missing_evidence") } if blockers.empty?
      blockers.uniq
    end

    def complexity_model_completeness(time_complete, space_complete)
      return "complete" if time_complete && space_complete
      return "partial" if time_complete == false || space_complete == false

      "unknown"
    end

    def input_completeness_for(mod)
      boundary = mod[:proof_boundary] || mod["proof_boundary"] || {}
      value = boundary[:input_completeness] || boundary["input_completeness"]
      %w[complete partial unknown].include?(value.to_s) ? value.to_s : "unknown"
    end

    def input_blockers_for(mod)
      boundary = mod[:proof_boundary] || mod["proof_boundary"] || {}
      blockers = Array(boundary[:input_blockers] || boundary["input_blockers"])
      raise ArgumentError, "input blockers must use proof-boundary objects" unless blockers.all? { |blocker| blocker.is_a?(Hash) }

      normalized = blockers.map { |blocker| blocker.transform_keys(&:to_s) }
      normalized << { "kind" => "unknown" } if normalized.empty? && input_completeness_for(mod) == "unknown"
      normalized.uniq.sort_by { |blocker| JSON.generate(blocker) }
    end

    def complexity_related_locations(variables)
      variables.filter_map.with_index(1) do |variable, index|
        path = variable[:path] || variable["path"]
        span = Array(variable[:span] || variable["span"])
        next if path.to_s.empty? || span.empty?

        symbol = variable[:symbol] || variable["symbol"]
        name = variable[:name] || variable["name"]
        kind = variable[:source_kind] || variable["source_kind"]
        {
          "id" => index,
          "message" => { "text" => "#{symbol} is the size of `#{name}` (#{kind})" },
          "physicalLocation" => {
            "artifactLocation" => { "uri" => Decomplex::Sarif.normalize_path(path) },
            "region" => {
              "startLine" => [span[0].to_i, 1].max,
              "startColumn" => span[1] ? span[1].to_i + 1 : nil,
              "endLine" => span[2]&.to_i,
              "endColumn" => span[3] ? span[3].to_i + 1 : nil
            }.compact
          }
        }
      end
    end

    def span_line(fn, index)
      span = fn[:span] || fn["span"]
      Array(span)[index]
    end
  end
end
