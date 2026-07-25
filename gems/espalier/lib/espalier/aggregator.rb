# frozen_string_literal: true

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
      prepare_module_indexes(modules)
      analyzer = Espalier::BigOAnalyzer.new(
        nil_kill: @nil_kill_evidence,
        declared_fields: declared_fields_for(modules)
      )
      internal_calls = internal_calls_by_method(modules)
      recursive_edges = recursive_internal_edges(internal_calls)
      resolved_calls = resolved_calls_by_site(modules)
      candidate_calls = candidate_calls_by_site(modules)
      resolved_recursive_edges = recursive_resolved_edges(modules)
      method_complexities, method_spaces, method_time_complete, method_space_complete, method_symbolic_time,
        method_bound_qualities, method_assumptions = structural_method_complexities(modules)
      structural_big_o = Espalier::StructuralBigO.new(
        facts_by_method: complexity_facts_by_method(modules),
        method_complexities: method_complexities,
        method_spaces: method_spaces,
        method_time_complete: method_time_complete,
        method_space_complete: method_space_complete,
        method_symbolic_time: method_symbolic_time,
        method_bound_qualities: method_bound_qualities,
        method_assumptions: method_assumptions,
        internal_calls: internal_calls,
        recursive_edges: recursive_edges,
        resolved_calls: resolved_calls,
        candidate_calls: candidate_calls,
        resolved_recursive_edges: resolved_recursive_edges,
        authoritative_call_graph_methods: authoritative_call_graph_methods(modules)
      )

      manifest = modules.map do |mod|
        internal_edges = internal_edges_for(mod)
        transitive_effects = transitive_effects_for(mod, internal_edges)
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
          effects = transitive_effects.fetch(m[:name].to_s)

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
          result_identity = m[:id].to_s.empty? ? [mod[:name].to_s, m[:name].to_s] : m[:id].to_s
          big_o_result = @structural_big_o_results&.fetch(result_identity, nil)
          unless big_o_result
            ast_nodes = big_o_nodes_for(mod, m)
            ast_nodes.concat(structural_big_o.hints_for(file, m, mod[:name]))
            analyzer.instance_variable_set(:@class_name, mod[:name])
            analyzer.instance_variable_set(:@ivar_types, mod[:ivar_types] || {})
            big_o_result = analyzer.analyze_method(
              key,
              ast_nodes,
              local_types: local_types_for_signature(sig)
            )
          end
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
          quality[:big_o_unknown_operation_evidence] = big_o_result[:unknown_operation_evidence] unless big_o_result[:unknown_operation_evidence].empty?
          quality[:big_o_evidence_gaps] = big_o_result[:evidence_gaps] unless big_o_result[:evidence_gaps].empty?
          quality[:big_o_bound_qualities] = big_o_result[:bound_qualities] unless big_o_result[:bound_qualities].empty?
          quality[:big_o_assumptions] = big_o_result[:complexity_assumptions] unless big_o_result[:complexity_assumptions].empty?

          {
            id: m[:id],
            name: m[:name],
            signature: sig,
            visibility: m[:visibility] || :public,
            line: m[:line],
            span: m[:span],
            language: mod[:language],
            EFFECTS: {
              reads: effects[:reads].to_a.sort,
              writes: effects[:writes].to_a.sort
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
          proof_boundary: mod[:proof_boundary],
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

    def transitive_effects_for(mod, internal_edges)
      effects = Array(mod[:methods]).to_h do |method|
        direct = method[:effects] || {}
        [
          method[:name].to_s,
          {
            reads: Set.new(
              direct[:reads].respond_to?(:to_a) ? direct[:reads].to_a : Array(direct[:reads])
            ),
            writes: Set.new(
              direct[:writes].respond_to?(:to_a) ? direct[:writes].to_a : Array(direct[:writes])
            ),
          },
        ]
      end

      changed = true
      while changed
        changed = false
        internal_edges.each do |edge|
          caller = effects[edge[:caller].to_s]
          callee = effects[edge[:callee].to_s]
          next unless caller && callee

          before = [caller[:reads].size, caller[:writes].size]
          caller[:reads].merge(callee[:reads])
          caller[:writes].merge(callee[:writes])
          changed ||= before != [caller[:reads].size, caller[:writes].size]
        end
      end
      effects
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
      cached = @method_line_bounds&.fetch(method.object_id, nil)
      return cached if cached

      start_line = method[:line] || 0
      span = method[:span]
      if span.is_a?(Array) && span[2]
        return [start_line, span[2].to_i, true]
      end

      next_method = methods[methods.index(method) + 1]
      [start_line, next_method ? (next_method[:line] || Float::INFINITY) : Float::INFINITY, false]
    end

    def prepare_module_indexes(modules)
      Espalier::SymbolicComplexity.reset_intern_pool!
      @module_method_names = {}
      @method_line_bounds = {}
      @big_o_nodes_cache = {}
      modules.each do |mod|
        methods = Array(mod[:methods])
        @module_method_names[mod.object_id] = methods.map { |method| method[:name].to_s }.to_set
        methods.each_with_index do |method, index|
          start_line = method[:line] || 0
          span = method[:span]
          @method_line_bounds[method.object_id] = if span.is_a?(Array) && span[2]
                                                   [start_line, span[2].to_i, true]
                                                 else
                                                   next_method = methods[index + 1]
                                                   [start_line,
                                                    next_method ? (next_method[:line] || Float::INFINITY) : Float::INFINITY,
                                                    false]
                                                 end
        end
      end
    end

    def line_in_method_bounds?(line, start_line, end_line, end_inclusive)
      return false unless line >= start_line
      end_inclusive ? line <= end_line : line < end_line
    end

    def preliminary_method_complexities(modules)
      analyzer = Espalier::BigOAnalyzer.new(
        nil_kill: @nil_kill_evidence,
        declared_fields: declared_fields_for(modules)
      )
      complexities = Hash.new { |h, k| h[k] = {} }
      spaces = Hash.new { |h, k| h[k] = {} }
      time_complete = Hash.new { |h, k| h[k] = {} }
      space_complete = Hash.new { |h, k| h[k] = {} }
      symbolic_time = Hash.new { |h, k| h[k] = {} }
      bound_qualities = Hash.new { |h, k| h[k] = {} }
      assumptions = Hash.new { |h, k| h[k] = {} }
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
          bound_qualities[mod[:name]][method_name] = result[:bound_qualities]
          assumptions[mod[:name]][method_name] = result[:complexity_assumptions]
          unless method[:id].to_s.empty?
            complexities[method[:id].to_s] = result[:known_time_component]
            spaces[method[:id].to_s] = result[:known_space_component]
            time_complete[method[:id].to_s] = result[:time_complete]
            space_complete[method[:id].to_s] = result[:space_complete]
            symbolic_time[method[:id].to_s] = result[:symbolic_time]
            bound_qualities[method[:id].to_s] = result[:bound_qualities]
            assumptions[method[:id].to_s] = result[:complexity_assumptions]
          end
        end
      end
      [complexities, spaces, time_complete, space_complete, symbolic_time, bound_qualities, assumptions]
    end

    def structural_method_complexities(modules)
      @structural_big_o_results = {}
      return preliminary_method_complexities(modules) if modules.empty?

      complexities, spaces, time_complete, space_complete, symbolic_time, bound_qualities, assumptions = preliminary_method_complexities(modules)
      internal_calls = internal_calls_by_method(modules)
      resolved_calls = resolved_calls_by_site(modules)
      candidate_calls = candidate_calls_by_site(modules)
      resolved_recursive_edges = recursive_resolved_edges(modules)
      structural_big_o = Espalier::StructuralBigO.new(
        facts_by_method: complexity_facts_by_method(modules),
        method_complexities: complexities,
        method_spaces: spaces,
        method_time_complete: time_complete,
        method_space_complete: space_complete,
        method_symbolic_time: symbolic_time,
        method_bound_qualities: bound_qualities,
        method_assumptions: assumptions,
        internal_calls: internal_calls,
        recursive_edges: recursive_internal_edges(internal_calls),
        resolved_calls: resolved_calls,
        candidate_calls: candidate_calls,
        resolved_recursive_edges: resolved_recursive_edges,
        authoritative_call_graph_methods: authoritative_call_graph_methods(modules)
      )

      structural_big_o.instance_variable_set(:@method_complexities, complexities)
      structural_big_o.instance_variable_set(:@method_spaces, spaces)
      structural_big_o.instance_variable_set(:@method_time_complete, time_complete)
      structural_big_o.instance_variable_set(:@method_space_complete, space_complete)
      structural_big_o.instance_variable_set(:@method_symbolic_time, symbolic_time)
      structural_big_o.instance_variable_set(:@method_bound_qualities, bound_qualities)
      structural_big_o.instance_variable_set(:@method_assumptions, assumptions)
      # Lambdas passed as callback arguments: indexed by (file, span) so a call
      # site can find the lambda inside its argument span and substitute its cost
      # for the callee's callback C.
      lambda_index = modules.flat_map do |mod|
        Array(mod[:methods]).select { |m| m[:dispatch_kind].to_s == "lambda" && m[:span] }
          .map { |m| { file: mod[:file], span: m[:span], id: m[:id] } }
      end
      structural_big_o.instance_variable_set(:@lambda_index, lambda_index)

      local_analyzer = Espalier::BigOAnalyzer.new(
        nil_kill: @nil_kill_evidence,
        declared_fields: declared_fields_for(modules)
      )

      # Components are ordered callee-first. Acyclic components therefore run
      # exactly once. Within a recursive SCC, only callers of a changed method
      # are re-enqueued; unrelated methods are never rescanned.
      summary_dependency_components(modules).each do |component|
        entries = component.fetch(:entries)
        by_identity = entries.to_h { |identity, mod, method| [identity, [mod, method]] }
        base_nodes = entries.to_h do |identity, mod, method|
          [identity, big_o_nodes_for(mod, method).freeze]
        end
        queue = entries.map(&:first)
        queued = queue.to_set
        queue_index = 0
        observed_states = Hash.new { |hash, identity| hash[identity] = Set.new }
        while queue_index < queue.length
          graph_identity = queue[queue_index]
          queue_index += 1
          queued.delete(graph_identity)
          mod, method = by_identity.fetch(graph_identity)
          local_analyzer.instance_variable_set(:@class_name, mod[:name])
          local_analyzer.instance_variable_set(:@ivar_types, mod[:ivar_types] || {})
          key = "#{mod[:name]}##{method[:name]}"
          sig = @nil_kill_data[key] || method[:signature]
          nodes = base_nodes.fetch(graph_identity) +
            structural_big_o.hints_for(mod[:file], method, mod[:name])
          result = local_analyzer.analyze_method(key, nodes, local_types: local_types_for_signature(sig))
          @structural_big_o_results[graph_identity] = result
          method_identity = method[:id].to_s.empty? ? nil : method[:id].to_s
          method_name = method[:name].to_s
          current = (method_identity && complexities[method_identity]) || complexities[mod[:name]][method_name] || "O(1)"
          current_space = (method_identity && spaces[method_identity]) || spaces[mod[:name]][method_name] || "O(1)"
          current_time_complete = method_identity ? time_complete[method_identity] : time_complete[mod[:name]][method_name]
          current_space_complete = method_identity ? space_complete[method_identity] : space_complete[mod[:name]][method_name]
          current_symbolic = method_identity ? symbolic_time[method_identity] : symbolic_time[mod[:name]][method_name]
          current_bound_qualities = method_identity ? bound_qualities[method_identity] : bound_qualities[mod[:name]][method_name]
          current_assumptions = method_identity ? assumptions[method_identity] : assumptions[mod[:name]][method_name]
          time_changed = complexity_rank(result[:known_time_component]) > complexity_rank(current)
          space_changed = complexity_rank(result[:known_space_component]) > complexity_rank(current_space)
          symbolic_changed = result[:symbolic_time] && result[:symbolic_time] != current_symbolic
          next_time_complete = result[:time_complete]
          next_space_complete = result[:space_complete]
          result_changed = time_changed || space_changed || symbolic_changed ||
            next_time_complete != current_time_complete ||
            next_space_complete != current_space_complete ||
            result[:bound_qualities] != current_bound_qualities ||
            result[:complexity_assumptions] != current_assumptions
          next unless result_changed

          complexity = (time_changed || symbolic_changed) ? result[:known_time_component] : current
          space = space_changed ? result[:known_space_component] : current_space
          expression = symbolic_changed ? result[:symbolic_time] : current_symbolic
          qualities = result[:bound_qualities]
          method_assumptions = result[:complexity_assumptions]
          complete_time = next_time_complete
          complete_space = next_space_complete
          structural_big_o.apply_summary_delta!(method_identity, mod[:name], method_name, {
            time: complexity,
            space: space,
            time_complete: complete_time,
            space_complete: complete_space,
            symbolic_time: expression,
            bound_qualities: qualities,
            assumptions: method_assumptions
          })
          state = [complexity, space, complete_time, complete_space, expression,
                   qualities, method_assumptions]
          next unless observed_states[graph_identity].add?(state)

          component.fetch(:callers).fetch(graph_identity, Set.new).each do |caller|
            next if queued.include?(caller)

            queue << caller
            queued << caller
          end
        end
      end

      [complexities, spaces, time_complete, space_complete, symbolic_time, bound_qualities, assumptions]
    end

    def summary_dependency_components(modules)
      entries = {}
      aliases = {}
      modules.each do |mod|
        Array(mod[:methods]).each do |method|
          fallback = [mod[:name].to_s, method[:name].to_s]
          identity = method[:id].to_s.empty? ? fallback : method[:id].to_s
          entries[identity] = [mod, method]
          aliases[fallback] = identity
          aliases[method[:id].to_s] = identity unless method[:id].to_s.empty?
        end
      end

      graph = entries.each_key.to_h { |identity| [identity, Set.new] }
      entries.each do |source, (mod, method)|
        Array(method[:delegations]).each do |delegation|
          target = if !delegation[:target_id].to_s.empty?
                     aliases[delegation[:target_id].to_s]
                   elsif delegation[:target_owner] && delegation[:target_method]
                     aliases[[delegation[:target_owner].to_s, delegation[:target_method].to_s]]
                   elsif delegation[:receiver].to_s == "self"
                     aliases[[mod[:name].to_s, delegation[:message].to_s]]
                   end
          graph[source] << target if target
          Array(delegation[:candidate_target_ids]).each do |candidate|
            candidate_target = aliases[candidate.to_s]
            graph[source] << candidate_target if candidate_target
          end
        end
      end

      components = strongly_connected_component_ids(graph)
      members = Hash.new { |hash, key| hash[key] = [] }
      entries.each_key { |identity| members[components.fetch(identity)] << identity }
      component_graph = members.each_key.to_h { |component| [component, Set.new] }
      reverse = Hash.new { |hash, key| hash[key] = Set.new }
      graph.each do |source, targets|
        targets.each do |target|
          source_component = components.fetch(source)
          target_component = components.fetch(target)
          next if source_component == target_component

          component_graph[source_component] << target_component
          reverse[target_component] << source_component
        end
      end

      remaining_dependencies = component_graph.transform_values(&:length)
      ready = remaining_dependencies.filter_map { |component, count| component if count.zero? }.sort
      ordered = []
      until ready.empty?
        component = ready.shift
        component_members = members.fetch(component).sort_by(&:to_s)
        member_set = component_members.to_set
        callers = Hash.new { |hash, key| hash[key] = Set.new }
        component_members.each do |caller|
          graph.fetch(caller).each do |callee|
            callers[callee] << caller if member_set.include?(callee)
          end
        end
        ordered << {
          entries: component_members.map do |identity|
            mod, method = entries.fetch(identity)
            [identity, mod, method]
          end,
          callers: callers,
        }
        reverse[component].sort.each do |caller|
          remaining_dependencies[caller] -= 1
          ready << caller if remaining_dependencies[caller].zero?
        end
        ready.sort!
      end
      ordered
    end

    def resolved_summary_depth(modules)
      identities = {}
      modules.each do |mod|
        Array(mod[:methods]).each do |method|
          fallback = [mod[:name].to_s, method[:name].to_s]
          identities[method[:id].to_s.empty? ? fallback : method[:id].to_s] = true
          identities[fallback] = true
        end
      end

      graph = Hash.new { |hash, key| hash[key] = Set.new }
      modules.each do |mod|
        Array(mod[:methods]).each do |method|
          source = method[:id].to_s.empty? ?
            [mod[:name].to_s, method[:name].to_s] : method[:id].to_s
          graph[source]
          Array(method[:delegations]).each do |delegation|
            next unless delegation[:target_owner] && delegation[:target_method]

            target = delegation[:target_id].to_s.empty? ?
              [delegation[:target_owner].to_s, delegation[:target_method].to_s] :
              delegation[:target_id].to_s
            graph[source] << target if identities[target]
          end
          Array(method[:delegations]).flat_map { |delegation| Array(delegation[:candidate_target_ids]) }
            .map(&:to_s).each do |target|
              graph[source] << target if identities[target]
            end
        end
      end
      return 0 if graph.empty?

      components = strongly_connected_component_ids(graph)
      component_graph = Hash.new { |hash, key| hash[key] = Set.new }
      reverse = Hash.new { |hash, key| hash[key] = Set.new }
      components.each_value { |component| component_graph[component] }
      graph.each do |source, targets|
        source_component = components[source]
        targets.each do |target|
          target_component = components[target]
          next if source_component == target_component

          component_graph[source_component] << target_component
          reverse[target_component] << source_component
        end
      end

      remaining = component_graph.transform_values(&:length)
      depth = Hash.new(0)
      queue = remaining.filter_map { |component, count| component if count.zero? }
      until queue.empty?
        component = queue.pop
        reverse[component].each do |caller|
          depth[caller] = [depth[caller], depth[component] + 1].max
          remaining[caller] -= 1
          queue << caller if remaining[caller].zero?
        end
      end
      depth.values.max || 0
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

            span = normalized_call_span(delegation[:span])
            keys = [[mod[:name].to_s, method[:name].to_s, delegation[:message].to_s,
                     (delegation[:line] || method[:line] || 0).to_i]]
            keys.unshift([mod[:name].to_s, method[:name].to_s,
                          delegation[:message].to_s, span]) if span
            unless method[:id].to_s.empty?
              keys.unshift([method[:id].to_s, delegation[:message].to_s,
                            (delegation[:line] || method[:line] || 0).to_i])
              keys.unshift([method[:id].to_s, delegation[:message].to_s, span]) if span
            end
            target = [delegation[:target_owner].to_s, delegation[:target_method].to_s,
                      delegation[:target_id]&.to_s]
            keys.each do |key|
              if index.key?(key) && index[key] != target
                index[key] = nil
              else
                index[key] = target
              end
            end
          end
        end
      end.compact
    end

    def candidate_calls_by_site(modules)
      modules.each_with_object({}) do |mod, index|
        Array(mod[:methods]).each do |method|
          Array(method[:delegations]).each do |delegation|
            candidates = Array(delegation[:candidate_target_ids]).map(&:to_s).reject(&:empty?).uniq.sort
            next if candidates.empty?

            span = normalized_call_span(delegation[:span])
            line = (delegation[:line] || method[:line] || 0).to_i
            keys = [[mod[:name].to_s, method[:name].to_s, delegation[:message].to_s, line]]
            keys.unshift([mod[:name].to_s, method[:name].to_s,
                          delegation[:message].to_s, span]) if span
            unless method[:id].to_s.empty?
              keys.unshift([method[:id].to_s, delegation[:message].to_s, line])
              keys.unshift([method[:id].to_s, delegation[:message].to_s, span]) if span
            end
            value = { ids: candidates, reason: delegation[:candidate_reason].to_s }
            keys.each do |key|
              if index.key?(key) && index[key] != value
                index[key] = nil
              else
                index[key] = value
              end
            end
          end
        end
      end.compact
    end

    def recursive_resolved_edges(modules)
      graph = Hash.new { |hash, key| hash[key] = Set.new }
      modules.each do |mod|
        Array(mod[:methods]).each do |method|
          source = method[:id].to_s.empty? ? [mod[:name].to_s, method[:name].to_s] : method[:id].to_s
          Array(method[:delegations]).each do |delegation|
            next unless delegation[:target_owner] && delegation[:target_method]

            target = if delegation[:target_id].to_s.empty?
                       [delegation[:target_owner].to_s, delegation[:target_method].to_s]
                     else
                       delegation[:target_id].to_s
                     end
            graph[source] << target
          end
        end
      end

      components = strongly_connected_component_ids(graph)
      graph.each_with_object({}) do |(source, targets), recursive|
        targets.each do |target|
          next unless components[source] == components[target]

          key = if source.is_a?(String) && target.is_a?(String)
                  [source, target]
                else
                  [source[0], source[1], target[0], target[1]]
                end
          recursive[key] = true
        end
      end
    end

    def authoritative_call_graph_methods(modules)
      modules.flat_map do |mod|
        Array(mod[:methods]).filter_map do |method|
          method[:id].to_s if method[:semantic_call_identity_complete] && !method[:id].to_s.empty?
        end
      end.to_set
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

    def duplicate_summary_index(index)
      index.transform_values { |value| value.is_a?(Hash) ? value.dup : value }
    end

    def big_o_nodes_for(mod, method)
      cache_key = [mod.object_id, method.object_id]
      cached = @big_o_nodes_cache&.fetch(cache_key, nil)
      return cached.dup if cached
      @big_o_nodes_cache ||= {}
      module_method_names = @module_method_names&.fetch(mod.object_id, nil) ||
        Array(mod[:methods]).map { |candidate| candidate[:name].to_s }.to_set

      contexts = Array(method[:complexity_facts]).flat_map do |fact|
        Array(fact["call_contexts"]).map do |context|
          context.merge(
            "collection_parameters" => Array(fact["collection_parameters"]),
            "size_domains" => Array(fact["size_domains"])
          )
        end
      end
      contexts_by_span = contexts.each_with_object({}) do |row, index|
        span = normalized_call_span(row["span"])
        next unless span

        key = [row["message"].to_s, span]
        index[key] = row if !index[key] || row["power"].to_i > index[key]["power"].to_i
      end
      contexts_by_line = contexts.group_by { |row| [row["message"].to_s, row["line"].to_i] }
      callback_params = Array(method[:callback_params]).map(&:to_s).to_set
      iterations = Array(method[:complexity_facts]).flat_map { |fact| Array(fact["iterations"]) }
      nodes = Array(method[:delegations]).map do |delegation|
        message = delegation[:message].to_s
        span = normalized_call_span(delegation[:span])
        context = contexts_by_span[[message, span]] if span
        if !context
          line_rows = contexts_by_line[[message, (delegation[:line] || method[:line] || 0).to_i]]
          context = line_rows.first if line_rows&.one?
        end
        # A call to a callback parameter has a cost parametric in that callback
        # (C), a complete algebraic atom that a loop composes to O(N*C) and a
        # caller resolves by substituting the passed callable's cost.
        callback_cost = if callback_params.include?(message) &&
            !delegation[:target_method] && !delegation[:known_time_complexity]
          # The callback runs once per iteration of its enclosing loop, so its
          # cost is that loop's size domain times C. Match the loop by span
          # containment and reuse its parameter size domain (which a caller can
          # also substitute), giving O(N*C); no enclosing loop gives O(C).
          cb_line = (delegation[:line] || method[:line] || 0).to_i
          loop_fact = iterations.find do |it|
            bounds = it["span"]
            bounds && cb_line >= bounds[0].to_i && cb_line <= bounds[2].to_i
          end
          mult_id = loop_fact && Array(loop_fact.dig("symbolic_time", "factors")).first&.fetch("domain_id", nil)
          mult_domains = mult_id ? [{ "id" => mult_id, "name" => Array(loop_fact["parameter_domains"]).first.to_s, "source_kind" => "parameter" }] : []
          Espalier::SymbolicComplexity.parameterized_cost(
            id: "cost:#{delegation[:call_id]}", name: message, source_kind: "callback_cost",
            multiplicity_domain: mult_id, domains: mult_domains
          )
        end
        {
          type: :call,
          call_id: delegation[:call_id],
          span: span,
          receiver: delegation[:receiver],
          method: delegation[:message],
          line: delegation[:line] || method[:line] || 0,
          execution_complexity: context && context["execution_multiplicity"],
          # The canonical CallRecord is enriched after syntax normalization by
          # SCIP and dependency summaries. Its exact symbol cost must outrank
          # an earlier adapter-level context model for the same source span.
          known_time_complexity: (callback_cost && (Espalier::SymbolicComplexity.render(callback_cost)&.first || "O(C)")) ||
            delegation[:known_time_complexity] || (context && context["known_time_complexity"]),
          known_space_complexity: delegation[:known_space_complexity] || (context && context["known_space_complexity"]),
          complexity_provenance: delegation[:complexity_provenance],
          complexity_bound_quality: delegation[:complexity_bound_quality],
          complexity_candidates: delegation[:complexity_candidates],
          complexity_assumptions: delegation[:complexity_assumptions],
          evidence_gap: if delegation[:known_time_complexity] || delegation[:known_space_complexity] || callback_cost
                          nil
                        else
                          context && context["evidence_gap"]
                        end,
          symbolic_time: callback_cost || parametric_call_symbolic(delegation, context) ||
            (context && symbolic_call_complexity(context)),
          collection_arguments: context && context["power"].to_i.positive? &&
            (Array(context["parameter_arguments"]) & Array(context["collection_parameters"])),
          internal_call: (delegation[:receiver].to_s == "self" &&
            module_method_names.include?(delegation[:message].to_s)) ||
            (delegation[:target_owner] && delegation[:target_method] && context) ||
            (Array(delegation[:candidate_target_ids]).any? && context)
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

      @big_o_nodes_cache[cache_key] = nodes
      nodes.dup
    end

    def normalized_call_span(span)
      values = Array(span)
      return nil unless values.length == 4

      values.map(&:to_i).freeze
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

    def parametric_call_symbolic(delegation, context)
      quality = delegation[:complexity_bound_quality].to_s
      return nil unless quality.start_with?("upper_bound_parametric_")

      linear = quality.end_with?("_linear")
      context_domains = Array(context && context["size_domains"])
      multiplicity_domain = if linear
                              Array(context && context["argument_size_domains"])
                                .find { |domains| !Array(domains).empty? }
                                &.first
                            end
      if linear && !multiplicity_domain
        multiplicity_domain = "input:#{delegation[:call_id]}"
        context_domains += [{
          "id" => multiplicity_domain,
          "name" => "input to #{delegation[:message]}",
          "source_kind" => "call_input_size"
        }]
      end
      reflective = quality.include?("reflective")
      Espalier::SymbolicComplexity.parameterized_cost(
        id: "cost:#{delegation[:call_id]}",
        name: "#{delegation[:receiver]}.#{delegation[:message]}",
        source_kind: reflective ? "reflective_target_cost" : "callback_cost",
        multiplicity_domain: multiplicity_domain,
        domains: context_domains
      )
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
