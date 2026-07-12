# frozen_string_literal: true

require "yaml"
require_relative "big_o_analyzer"
require_relative "structural_big_o"

module Espalier
  # Coalescing agent that imports the static skeleton maps and merges secondary
  # metadata from: decomplex (decisions/clones), nil-kill (types), and boobytrap/slopcop (risk/coverage).
  class Aggregator
    def initialize(
      decomplex_data: {},
      nil_kill_data: {},
      risk_data: {},
      nil_kill_loops: {},
      nil_kill_evidence: nil
    )
      @decomplex_data = decomplex_data
      @nil_kill_data = nil_kill_data
      @risk_data = risk_data
      @nil_kill_loops = nil_kill_loops
      @nil_kill_evidence = nil_kill_evidence
    end

    # Aggregate extracted AST structure with auxiliary indicators
    def aggregate(modules)
      analyzer = Espalier::BigOAnalyzer.new(
        language: :ruby,
        nil_kill: @nil_kill_evidence
      )
      method_complexities = structural_method_complexities(modules)
      structural_big_o = Espalier::StructuralBigO.new(
        method_complexities: method_complexities
      )

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

          file = mod[:file]
          ast_nodes = big_o_nodes_for(mod, m)
          ast_nodes.concat(structural_big_o.hints_for(file, m, mod[:name]))

          analyzer.instance_variable_set(:@class_name, mod[:name])
          analyzer.instance_variable_set(:@ivar_types, mod[:ivar_types] || {})
          
          big_o_result = analyzer.analyze_method(key, ast_nodes, local_types: local_types_for_signature(sig))
          quality[:big_o] = big_o_result[:lower_bound_complexity]
          quality[:big_o_space] = big_o_result[:space_complexity] if big_o_result[:space_complexity]
          quality[:big_o_dynamic] = big_o_result[:is_dynamic]
          quality[:complexity_trigger] = big_o_result[:trigger] if big_o_result[:trigger]
          quality[:big_o_warnings] = big_o_result[:warnings] unless big_o_result[:warnings].empty?
          quality[:big_o_unknowns] = big_o_result[:unknown_operations] unless big_o_result[:unknown_operations].empty?

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
          line: mod[:line],
          span: mod[:span],
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
      co_updates = @decomplex_data["#{class_name}::STATE_CO_UPDATE"]
      if co_updates && co_updates.include?(state_var)
        props << "co-updates with #{co_updates[state_var]}"
      end
      props
    end

    def method_line_bounds(methods, method)
      start_line = method[:line] || 0
      span = method[:span]
      if span.is_a?(Array) && span[2]
        return [start_line, span[2].to_i, true]
      end

      next_method = methods[methods.index(method) + 1]
      [start_line, next_method ? (next_method[:line] || Float::INFINITY) : Float::INFINITY, false]
    end

    def line_in_method_bounds?(line, start_line, end_line, end_inclusive)
      return false unless line >= start_line
      end_inclusive ? line <= end_line : line < end_line
    end

    def preliminary_method_complexities(modules)
      analyzer = Espalier::BigOAnalyzer.new(
        language: :ruby,
        nil_kill: @nil_kill_evidence
      )
      modules.each_with_object(Hash.new { |h, k| h[k] = {} }) do |mod, complexities|
        Array(mod[:methods]).each do |method|
          analyzer.instance_variable_set(:@class_name, mod[:name])
          analyzer.instance_variable_set(:@ivar_types, mod[:ivar_types] || {})
          key = "#{mod[:name]}##{method[:name]}"
          sig = @nil_kill_data[key] || method[:signature]
          result = analyzer.analyze_method(
            key,
            big_o_nodes_for(mod, method),
            local_types: local_types_for_signature(sig)
          )
          complexities[mod[:name]][method[:name].to_s] = result[:lower_bound_complexity]
        end
      end
    end

    def structural_method_complexities(modules)
      complexities = preliminary_method_complexities(modules)
      structural_big_o = Espalier::StructuralBigO.new(method_complexities: complexities)

      cores = ENV.fetch("CORES", ENV.fetch("JOBS", "4")).to_i

      8.times do
        changed = false
        # Update method complexities on the cached structural_big_o
        structural_big_o.instance_variable_set(:@method_complexities, complexities.transform_values { |methods|
          methods.transform_values { |c| c }
        })

        slices = modules.each_slice((modules.size.to_f / cores).ceil).to_a
        threads = slices.map do |slice|
          Thread.new do
            local_analyzer = Espalier::BigOAnalyzer.new(
              language: :ruby,
              nil_kill: @nil_kill_evidence
            )
            local_changes = []
            slice.each do |mod|
              Array(mod[:methods]).each do |method|
                local_analyzer.instance_variable_set(:@class_name, mod[:name])
                local_analyzer.instance_variable_set(:@ivar_types, mod[:ivar_types] || {})
                key = "#{mod[:name]}##{method[:name]}"
                sig = @nil_kill_data[key] || method[:signature]
                nodes = big_o_nodes_for(mod, method)
                nodes.concat(structural_big_o.hints_for(mod[:file], method, mod[:name]))
                result = local_analyzer.analyze_method(key, nodes, local_types: local_types_for_signature(sig))
                current = complexities[mod[:name]][method[:name].to_s] || "O(1)"
                if complexity_rank(result[:lower_bound_complexity]) > complexity_rank(current)
                  local_changes << [mod[:name], method[:name].to_s, result[:lower_bound_complexity]]
                end
              end
            end
            local_changes
          end
        end

        results = threads.flat_map(&:join).flat_map(&:value)
        results.each do |mod_name, method_name, complexity|
          complexities[mod_name][method_name] = complexity
          changed = true
        end

        break unless changed
      end

      complexities
    end

    def complexity_rank(complexity)
      case complexity.to_s
      when "O(1)" then 1
      when "O(log N)" then 2
      when "O(N)" then 10
      when "O(N log N)" then 11
      when "O(N * M)" then 14
      when /\AO\(N\^(\d+)( log N)?\)\z/
        10 + ($1.to_i * 2) + ($2 ? 1 : 0)
      when "O(2^N)" then 100
      when "O(N!)" then 200
      else
        1
      end
    end

    def big_o_nodes_for(mod, method)
      nodes = Array(method[:delegations]).map do |delegation|
        {
          type: :call,
          receiver: delegation[:receiver],
          method: delegation[:message],
          line: delegation[:line] || method[:line] || 0
        }
      end

      meth_line, end_line, end_inclusive = method_line_bounds(mod[:methods], method)
      file = mod[:file]
      if file && @nil_kill_loops && @nil_kill_loops[file]
        @nil_kill_loops[file].each do |line, calls|
          if line_in_method_bounds?(line, meth_line, end_line, end_inclusive) && calls > 0
            nodes << { type: :loop, line: line, calls: calls }
          end
        end
      end

      nodes
    end

    def local_types_for_signature(signature)
      params_source = signature_params_source(signature.to_s)
      return {} unless params_source

      split_signature_args(params_source).each_with_object({}) do |entry, types|
        name, type = entry.split(":", 2)
        next unless name && type

        types[name.strip] = type.strip
      end
    end

    def signature_params_source(signature)
      start_idx = signature.index("params(")
      return nil unless start_idx

      idx = start_idx + "params(".length
      depth = 1
      while idx < signature.length
        case signature[idx]
        when "(", "[", "{"
          depth += 1
        when ")", "]", "}"
          depth -= 1
          return signature[(start_idx + "params(".length)...idx] if depth.zero?
        end
        idx += 1
      end

      nil
    end

    def split_signature_args(source)
      parts = []
      start_idx = 0
      depth = 0
      source.each_char.with_index do |char, idx|
        case char
        when "(", "[", "{"
          depth += 1
        when ")", "]", "}"
          depth -= 1
        when ","
          next unless depth.zero?

          parts << source[start_idx...idx].strip
          start_idx = idx + 1
        end
      end
      parts << source[start_idx..].to_s.strip
      parts.reject(&:empty?)
    end
  end
end
