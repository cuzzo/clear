# frozen_string_literal: true

require "yaml"

module Espalier
  # Coalescing agent that imports the static skeleton maps and merges secondary
  # metadata from: decomplex (decisions/clones), nil-kill (types), and boobytrap/slopcop (risk/coverage).
  class Aggregator
    def initialize(
      decomplex_data: {},
      nil_kill_data: {},
      risk_data: {}
    )
      @decomplex_data = decomplex_data
      @nil_kill_data = nil_kill_data
      @risk_data = risk_data
    end

    # Aggregate extracted AST structure with auxiliary indicators
    def aggregate(modules)
      manifest = modules.map do |mod|
        internal_edges = internal_edges_for(mod)
        callers_by_method = internal_edges.each_with_object(Hash.new { |h, k| h[k] = [] }) do |edge, index|
          index[edge[:callee]] << edge[:caller]
        end
        callees_by_method = internal_edges.each_with_object(Hash.new { |h, k| h[k] = [] }) do |edge, index|
          index[edge[:caller]] << edge[:callee]
        end

        aggregated_states = mod[:states].map do |state_var|
          # Merge state context if dynamic updates or properties exist
          type_str = mod[:ivar_types] ? mod[:ivar_types][state_var] : nil

          props = collect_state_properties(mod[:name], state_var)
          if mod[:ivar_properties] && mod[:ivar_properties][state_var]
            props.concat(mod[:ivar_properties][state_var])
          end

          {
            name: state_var,
            type: type_str,
            properties: props
          }.compact
        end

        aggregated_methods = mod[:methods].map do |m|
          key = "#{mod[:name]}##{m[:name]}"

          # 1. Capture concrete type signature if nil-kill supplied custom RBI/data
          sig = @nil_kill_data[key] || m[:signature]

          # 2. Map structural DELEGATIONS to simplified compact groups
          always_calls = []
          conditionally_calls = []

          Array(m[:delegations]).uniq.each do |del|
            receiver = del[:receiver]
            if receiver.start_with?("@") && mod[:ivar_types] && (type_name = mod[:ivar_types][receiver])
              receiver = type_name
            end

            target = receiver == "self" ? del[:message] : "#{receiver}.#{del[:message]}"
            if del[:type] == :conditional
              conditionally_calls << target
            else
              always_calls << target
            end
          end

          always_calls.uniq!
          conditionally_calls.uniq!

          delegations = {}
          delegations[:always_calls] = always_calls unless always_calls.empty?
          delegations[:conditionally_calls] = conditionally_calls unless conditionally_calls.empty?

          # 3. Decorate quality metrics
          quality = {}
          if decomplex_info = @decomplex_data[key]
            quality[:complexity] = decomplex_info[:deviance] || "high (decomplex deviance)"
            quality[:broken_protocol] = true if decomplex_info[:broken_protocol]
          end

          file_risk = @risk_data[mod[:file]]
          if file_risk
            quality[:churn_risk] = file_risk[:churn]
            quality[:coverage_gap] = file_risk[:coverage_gap] if file_risk[:coverage_gap]
          end

          {
            name: m[:name],
            signature: sig,
            visibility: m[:visibility] || :public,
            line: m[:line],
            span: m[:span],
            language: mod[:language],
            EFFECTS: {
              reads: m[:effects][:reads].to_a.sort,
              writes: m[:effects][:writes].to_a.sort
            },
            DELEGATIONS: delegations.empty? ? nil : delegations,
            CALL_GRAPH: call_graph_for(m[:name], callers_by_method, callees_by_method),
            quality_metrics: quality.empty? ? nil : quality
          }.compact
        end

        mod_row = {
          module: mod[:name],
          file: mod[:file],
          language: mod[:language],
          type: mod[:type],
          state: aggregated_states.empty? ? nil : aggregated_states,
          functions: aggregated_methods
        }.compact
        mod_row[:call_graph] = { internal_edges: internal_edges } unless internal_edges.empty?
        mod_row
      end
      PrivacyAnalyzer.annotate!(manifest)
    end

    private

    def internal_edges_for(mod)
      legacy_internal_edges_for(mod)
    end

    def legacy_internal_edges_for(mod)
      method_names = mod[:methods].map { |m| m[:name].to_s }
      mod[:methods].flat_map do |method|
        caller = method[:name].to_s
        Array(method[:delegations]).filter_map do |delegation|
          callee = delegation[:message].to_s
          next unless delegation[:receiver] == "self"
          next unless method_names.include?(callee)
          next if caller == callee

          {
            caller: caller,
            callee: callee,
            type: delegation[:type] || :always
          }
        end
      end.uniq.sort_by { |edge| [edge[:callee], edge[:caller], edge[:type].to_s] }
    end

    def call_graph_for(method_name, callers_by_method, callees_by_method)
      graph = {}
      callers = callers_by_method[method_name.to_s].uniq.sort
      callees = callees_by_method[method_name.to_s].uniq.sort
      graph[:internal_callers] = callers unless callers.empty?
      graph[:internal_calls] = callees unless callees.empty?
      graph.empty? ? nil : graph
    end

    def collect_state_properties(class_name, state_var)
      props = []
      # Look for de-complex co-update observations on state
      if @decomplex_data["#{class_name}::STATE_CO_UPDATE"]&.include?(state_var)
        paired = @decomplex_data["#{class_name}::STATE_CO_UPDATE"][state_var]
        props << "co-updates with #{paired}"
      end
      props
    end
  end
end
