# frozen_string_literal: true

require "yaml"
require "set"
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
      nil_kill_evidence: nil,
      closed_world: false
    )
      @decomplex_data = decomplex_data
      @nil_kill_data = nil_kill_data
      @risk_data = risk_data
      @nil_kill_loops = nil_kill_loops
      @nil_kill_evidence = nil_kill_evidence
      @closed_world = closed_world
    end

    # Aggregate extracted AST structure with auxiliary indicators
    def aggregate(modules)
      analyzer = Espalier::BigOAnalyzer.new(
        language: :ruby,
        nil_kill: @nil_kill_evidence,
        declared_fields: declared_fields_for(modules)
      )
      internal_calls = internal_calls_by_method(modules)
      recursive_edges = recursive_internal_edges(internal_calls)
      resolved_calls = resolved_calls_by_site(modules)
      resolved_recursive_edges = recursive_resolved_edges(modules)
      method_complexities, method_spaces, method_time_complete, method_space_complete, method_symbolic_time = structural_method_complexities(modules)
      structural_big_o = Espalier::StructuralBigO.new(
        facts_by_method: complexity_facts_by_method(modules),
        method_complexities: method_complexities,
        method_spaces: method_spaces,
        method_time_complete: method_time_complete,
        method_space_complete: method_space_complete,
        method_symbolic_time: method_symbolic_time,
        internal_calls: internal_calls,
        recursive_edges: recursive_edges,
        resolved_calls: resolved_calls,
        resolved_recursive_edges: resolved_recursive_edges
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
          quality[:big_o_known_component] = big_o_result[:known_time_component]
          quality[:big_o_space_known_component] = big_o_result[:known_space_component]
          quality[:big_o_variables] = big_o_result[:complexity_variables] unless big_o_result[:complexity_variables].empty?
          quality[:big_o_complete] = big_o_result[:time_complete]
          quality[:big_o_space_complete] = big_o_result[:space_complete]
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
      PrivacyAnalyzer.annotate!(manifest, closed_world: @closed_world)
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
        nil_kill: @nil_kill_evidence,
        declared_fields: declared_fields_for(modules)
      )
      complexities = Hash.new { |h, k| h[k] = {} }
      spaces = Hash.new { |h, k| h[k] = {} }
      time_complete = Hash.new { |h, k| h[k] = {} }
      space_complete = Hash.new { |h, k| h[k] = {} }
      symbolic_time = Hash.new { |h, k| h[k] = {} }
      modules.each do |mod|
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
          method_name = method[:name].to_s
          complexities[mod[:name]][method_name] = result[:known_time_component]
          spaces[mod[:name]][method_name] = result[:known_space_component]
          time_complete[mod[:name]][method_name] = result[:time_complete]
          space_complete[mod[:name]][method_name] = result[:space_complete]
          symbolic_time[mod[:name]][method_name] = result[:symbolic_time]
        end
      end
      [complexities, spaces, time_complete, space_complete, symbolic_time]
    end

    def structural_method_complexities(modules)
      return preliminary_method_complexities(modules) if modules.empty?

      complexities, spaces, time_complete, space_complete, symbolic_time = preliminary_method_complexities(modules)
      internal_calls = internal_calls_by_method(modules)
      resolved_calls = resolved_calls_by_site(modules)
      resolved_recursive_edges = recursive_resolved_edges(modules)
      structural_big_o = Espalier::StructuralBigO.new(
        facts_by_method: complexity_facts_by_method(modules),
        method_complexities: complexities,
        method_spaces: spaces,
        method_time_complete: time_complete,
        method_space_complete: space_complete,
        method_symbolic_time: symbolic_time,
        internal_calls: internal_calls,
        recursive_edges: recursive_internal_edges(internal_calls),
        resolved_calls: resolved_calls,
        resolved_recursive_edges: resolved_recursive_edges
      )

      cores = [ENV.fetch("CORES", ENV.fetch("JOBS", "4")).to_i, 1].max

      8.times do
        changed = false
        # Update method complexities on the cached structural_big_o
        structural_big_o.instance_variable_set(:@method_complexities, complexities.transform_values { |methods|
          methods.transform_values { |c| c }
        })
        structural_big_o.instance_variable_set(:@method_spaces, spaces.transform_values { |methods|
          methods.transform_values { |space| space }
        })
        structural_big_o.instance_variable_set(:@method_time_complete, time_complete.transform_values { |methods|
          methods.transform_values { |complete| complete }
        })
        structural_big_o.instance_variable_set(:@method_space_complete, space_complete.transform_values { |methods|
          methods.transform_values { |complete| complete }
        })
        structural_big_o.instance_variable_set(:@method_symbolic_time, symbolic_time.transform_values { |methods|
          methods.transform_values { |expression| expression }
        })

        slice_size = [(modules.size.to_f / cores).ceil, 1].max
        slices = modules.each_slice(slice_size).to_a
        threads = slices.map do |slice|
          Thread.new do
            local_analyzer = Espalier::BigOAnalyzer.new(
              language: :ruby,
              nil_kill: @nil_kill_evidence,
              declared_fields: declared_fields_for(modules)
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
                current_space = spaces[mod[:name]][method[:name].to_s] || "O(1)"
                current_time_complete = time_complete[mod[:name]][method[:name].to_s]
                current_space_complete = space_complete[mod[:name]][method[:name].to_s]
                current_symbolic = symbolic_time[mod[:name]][method[:name].to_s]
                time_changed = complexity_rank(result[:known_time_component]) > complexity_rank(current)
                space_changed = complexity_rank(result[:known_space_component]) > complexity_rank(current_space)
                symbolic_changed = result[:symbolic_time] && result[:symbolic_time] != current_symbolic
                next_time_complete = current_time_complete != false && result[:time_complete]
                next_space_complete = current_space_complete != false && result[:space_complete]
                time_complete_changed = next_time_complete != current_time_complete
                space_complete_changed = next_space_complete != current_space_complete
                if time_changed || space_changed || symbolic_changed || time_complete_changed || space_complete_changed
                  local_changes << [
                    mod[:name], method[:name].to_s,
                    (time_changed || symbolic_changed) ? result[:known_time_component] : current,
                    space_changed ? result[:known_space_component] : current_space,
                    next_time_complete,
                    next_space_complete,
                    symbolic_changed ? result[:symbolic_time] : current_symbolic
                  ]
                end
              end
            end
            local_changes
          end
        end

        results = threads.flat_map(&:join).flat_map(&:value)
        results.each do |mod_name, method_name, complexity, space, complete_time, complete_space, expression|
          complexities[mod_name][method_name] = complexity
          spaces[mod_name][method_name] = space
          time_complete[mod_name][method_name] = complete_time
          space_complete[mod_name][method_name] = complete_space
          symbolic_time[mod_name][method_name] = expression
          changed = true
        end

        break unless changed
      end

      [complexities, spaces, time_complete, space_complete, symbolic_time]
    end

    def internal_calls_by_method(modules)
      modules.each_with_object({}) do |mod, owners|
        method_names = Array(mod[:methods]).map { |method| method[:name].to_s }.to_set
        owners[mod[:name].to_s] = Array(mod[:methods]).each_with_object({}) do |method, callers|
          callers[method[:name].to_s] = Array(method[:delegations]).filter_map do |delegation|
            next unless delegation[:receiver].to_s == "self"

            callee = delegation[:message].to_s
            callee if method_names.include?(callee)
          end.to_set
        end
      end
    end

    def resolved_calls_by_site(modules)
      modules.each_with_object({}) do |mod, index|
        Array(mod[:methods]).each do |method|
          Array(method[:delegations]).each do |delegation|
            next unless delegation[:target_owner] && delegation[:target_method]

            key = [mod[:name].to_s, method[:name].to_s, delegation[:message].to_s,
                   (delegation[:line] || method[:line] || 0).to_i]
            target = [delegation[:target_owner].to_s, delegation[:target_method].to_s]
            if index.key?(key) && index[key] != target
              index[key] = nil
            else
              index[key] = target
            end
          end
        end
      end.compact
    end

    def recursive_resolved_edges(modules)
      graph = Hash.new { |hash, key| hash[key] = Set.new }
      modules.each do |mod|
        Array(mod[:methods]).each do |method|
          source = [mod[:name].to_s, method[:name].to_s]
          Array(method[:delegations]).each do |delegation|
            next unless delegation[:target_owner] && delegation[:target_method]

            graph[source] << [delegation[:target_owner].to_s, delegation[:target_method].to_s]
          end
        end
      end

      components = strongly_connected_component_ids(graph)
      graph.each_with_object({}) do |(source, targets), recursive|
        targets.each do |target|
          next unless components[source] == components[target]

          recursive[[source[0], source[1], target[0], target[1]]] = true
        end
      end
    end

    def recursive_internal_edges(internal_calls)
      internal_calls.each_with_object({}) do |(owner, graph), recursive|
        components = strongly_connected_component_ids(graph)
        graph.each do |caller, callees|
          callees.each do |callee|
            recursive[[owner, caller, callee]] = true if components[caller] == components[callee]
          end
        end
      end
    end

    def strongly_connected_component_ids(graph)
      adjacency = Hash.new { |hash, node| hash[node] = Set.new }
      graph.each do |source, targets|
        adjacency[source].merge(Array(targets))
        Array(targets).each { |target| adjacency[target] }
      end

      visited = Set.new
      finish_order = []
      adjacency.each_key do |root|
        next if visited.include?(root)

        pending = [[root, false]]
        until pending.empty?
          node, expanded = pending.pop
          if expanded
            finish_order << node
          elsif visited.add?(node)
            pending << [node, true]
            adjacency[node].each do |target|
              pending << [target, false] unless visited.include?(target)
            end
          end
        end
      end

      reversed = Hash.new { |hash, node| hash[node] = Set.new }
      adjacency.each do |source, targets|
        reversed[source]
        targets.each { |target| reversed[target] << source }
      end

      component_ids = {}
      finish_order.reverse_each do |root|
        next if component_ids.key?(root)

        component_id = component_ids.length
        pending = [root]
        until pending.empty?
          node = pending.pop
          next if component_ids.key?(node)

          component_ids[node] = component_id
          pending.concat(reversed[node].reject { |source| component_ids.key?(source) })
        end
      end
      component_ids
    end

    def complexity_facts_by_method(modules)
      modules.each_with_object({}) do |mod, index|
        Array(mod[:methods]).each do |method|
          facts = Array(method[:complexity_facts])
          index[method[:id].to_s] = facts unless method[:id].to_s.empty?
          index[[mod[:name].to_s, method[:name].to_s]] = facts
        end
      end
    end

    def declared_fields_for(modules)
      modules.first&.fetch(:declared_fields, {}) || {}
    end

    def complexity_rank(complexity)
      return 1 if complexity.nil? || complexity == "O(1)" || complexity == "unknown"
      return 2 if complexity == "O(log N)"
      return 100 if complexity == "O(2^N)"
      return 200 if complexity == "O(N!)"

      rank = Espalier::SymbolicComplexity.rank_string(complexity)
      return 1 if rank.negative?
      return 10 if rank == 1
      return 11 if rank == 1.1

      10 + (rank.floor * 2) + (rank.modulo(1).positive? ? 1 : 0)
    end

    def big_o_nodes_for(mod, method)
      call_contexts = Array(method[:complexity_facts]).flat_map do |fact|
        Array(fact["call_contexts"]).map do |context|
          context.merge(
            "collection_parameters" => Array(fact["collection_parameters"]),
            "size_domains" => Array(fact["size_domains"])
          )
        end
      end
        .each_with_object({}) do |row, index|
          key = [row["message"].to_s, row["line"].to_i]
          index[key] = row if !index[key] || row["power"].to_i > index[key]["power"].to_i
        end
      nodes = Array(method[:delegations]).map do |delegation|
        context = call_contexts[[delegation[:message].to_s, (delegation[:line] || method[:line] || 0).to_i]]
        {
          type: :call,
          receiver: delegation[:receiver],
          method: delegation[:message],
          line: delegation[:line] || method[:line] || 0,
          execution_complexity: context && context["execution_multiplicity"],
          known_time_complexity: (context && context["known_time_complexity"]) || delegation[:known_time_complexity],
          known_space_complexity: (context && context["known_space_complexity"]) || delegation[:known_space_complexity],
          symbolic_time: context && symbolic_call_complexity(context),
          collection_arguments: context && context["power"].to_i.positive? &&
            (Array(context["parameter_arguments"]) & Array(context["collection_parameters"])),
          internal_call: (delegation[:receiver].to_s == "self" && Array(mod[:methods]).any? { |candidate| candidate[:name].to_s == delegation[:message].to_s }) ||
            (delegation[:target_owner] && delegation[:target_method] && context)
        }.compact
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

    def symbolic_call_complexity(context)
      local = Espalier::SymbolicComplexity.relative_call(
        context["known_time_complexity"],
        receiver_domains: context["receiver_size_domains"],
        argument_domains: context["argument_size_domains"],
        domains: context["size_domains"]
      )
      return nil unless local

      execution = Espalier::SymbolicComplexity.from_fact(
        context["symbolic_execution"],
        context["size_domains"]
      )
      Espalier::SymbolicComplexity.multiply(execution, local)
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
