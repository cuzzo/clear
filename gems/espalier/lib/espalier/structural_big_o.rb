# frozen_string_literal: true

require_relative "symbolic_complexity"

module Espalier
  # Calculates time/space complexity from canonical facts emitted by FactMine.
  #
  # This class deliberately has no filesystem or source-text access. Syntax,
  # containment, recursion, and iteration semantics belong to FactMine's
  # Tree-sitter normalization layer. Missing facts remain unknown rather than
  # being guessed from source strings.
  class StructuralBigO
    def initialize(facts_by_method: {}, method_complexities: {}, method_spaces: {}, method_time_complete: {}, method_space_complete: {}, method_symbolic_time: {}, internal_calls: nil, recursive_edges: nil, resolved_calls: {}, resolved_recursive_edges: {})
      @facts_by_method = facts_by_method
      @method_complexities = method_complexities
      @method_spaces = method_spaces
      @method_time_complete = method_time_complete
      @method_space_complete = method_space_complete
      @method_symbolic_time = method_symbolic_time
      @internal_calls = internal_calls
      @recursive_edges = recursive_edges || {}
      @resolved_calls = resolved_calls
      @resolved_recursive_edges = resolved_recursive_edges
      @recursive_component_cache = {}
      @recursive_components_by_graph = {}
      @state_replay_summary_cache = {}
      @reachable_methods_cache = {}
    end

    def hints_for(_file, method, owner)
      method_id = method[:id].to_s
      facts = Array(@facts_by_method[method_id])
      if facts.empty?
        facts = Array(@facts_by_method[[owner.to_s, method[:name].to_s]])
      end

      hints = facts.map { |fact| summary_hint(fact, method, owner.to_s) }

      facts.each do |fact|
        Array(fact["call_contexts"]).each do |context|
          caller = method[:name].to_s
          message = context["message"].to_s
          line = context.fetch("line", method[:line]).to_i
          resolved_target = @resolved_calls[[owner.to_s, caller, message, line]]
          if resolved_target
            callee_owner, callee = resolved_target.map(&:to_s)
            if @resolved_recursive_edges[[owner.to_s, caller, callee_owner, callee]]
              replay = callee_owner == owner.to_s &&
                state_replay_recursion_summary(owner.to_s, caller)
              hints << {
                type: :structural,
                line: line,
                complexity: replay ? replay.fetch(:time) : "unknown",
                space: replay ? replay.fetch(:space) : "unknown",
                is_dynamic: true,
                operation: message,
                reason: replay ? replay.fetch(:reason) : "cross-owner recursive call progress is unknown",
                confidence: replay ? "high" : "unknown",
                time_complete: !!replay,
                space_complete: !!replay,
                fact_source: "fact_mine"
              }
              next
            end
          else
            callee = message
            callee_owner = owner.to_s
            next if @internal_calls && !Array(@internal_calls.dig(owner.to_s, caller)).include?(callee)
          end

          if callee_owner == owner.to_s && @recursive_edges[[owner.to_s, caller, callee]]
            # Direct recursion is classified from FactMine's progress facts in
            # summary_hint. A mutually recursive SCC has no normalized progress
            # proof yet, so multiplying the previous fixed-point estimate would
            # fabricate ever-growing polynomial powers.
            unless caller == callee
              mutual = mutual_recursion_summary(owner.to_s, caller)
              hints << {
                type: :structural,
                line: context.fetch("line", method[:line]).to_i,
                complexity: mutual ? mutual.fetch(:time) : "unknown",
                space: mutual ? mutual.fetch(:space) : "unknown",
                is_dynamic: true,
                operation: callee,
                reason: mutual ? mutual.fetch(:reason) : "mutually recursive call progress is unknown",
                confidence: mutual ? "high" : "unknown",
                time_complete: !mutual.nil?,
                space_complete: !mutual.nil?,
                fact_source: "fact_mine"
              }
            end
            next
          end

          callee_complexity = @method_complexities.dig(callee_owner, callee)
          callee_space = @method_spaces.dig(callee_owner, callee)
          callee_symbolic = @method_symbolic_time.dig(callee_owner, callee)
          callee_time_complete = @method_time_complete.dig(callee_owner, callee) != false
          callee_space_complete = @method_space_complete.dig(callee_owner, callee) != false
          next unless callee_complexity || callee_space
          next if callee_complexity == "O(1)" && (!callee_space || callee_space == "O(1)") &&
            callee_time_complete && callee_space_complete

          propagated_symbolic = propagated_call_symbolic(
            callee_owner,
            callee,
            fact,
            context,
            callee_symbolic,
            receiver_state_dependent: receiver_state_dependent?(callee_owner, callee)
          )
          rendered_symbolic = Espalier::SymbolicComplexity.render(propagated_symbolic)&.first
          hints << {
            type: :structural,
            line: context.fetch("line", method[:line]).to_i,
            complexity: rendered_symbolic || propagated_call_complexity(
              context,
              callee_complexity || "O(1)",
              receiver_state_dependent: receiver_state_dependent?(callee_owner, callee)
            ),
            space: callee_space,
            is_dynamic: true,
            operation: context["message"],
            reason: "normalized call containment and propagated callee complexity",
            confidence: "high",
            time_complete: callee_time_complete,
            space_complete: callee_space_complete,
            symbolic_time: propagated_symbolic,
            fact_source: "fact_mine"
          }
        end
      end
      hints
    end

    private

    def propagated_call_symbolic(owner, callee, caller_fact, context, callee_symbolic, receiver_state_dependent: false)
      return nil unless callee_symbolic

      callee_facts = Array(@facts_by_method[[owner, callee]])
      callee_fact = callee_facts.first
      caller_domains = Espalier::SymbolicComplexity.domain_index(caller_fact["size_domains"])
      execution = Espalier::SymbolicComplexity.from_fact(
        context["symbolic_execution"],
        caller_fact["size_domains"]
      )
      partition_domain_ids = if context["argument_cardinality_relation"] == "partition_of"
                               Array(execution&.dig(:terms)).flat_map { |term| term[:factors].keys }.uniq
                             else
                               []
                             end
      mapping = {}
      if callee_fact
        domains = Array(callee_fact["size_domains"])
        Array(callee_fact["parameters"]).each_with_index do |parameter, index|
          domain = domains.find do |candidate|
            candidate["source_kind"] == "parameter" && candidate["name"] == parameter
          end
          actual = Array(context["argument_size_domains"])[index]
          actual = partition_domain_ids if Array(actual).empty? && partition_domain_ids.length == 1
          mapping[domain["id"]] = Array(actual) if domain && actual
        end
      end
      substituted = Espalier::SymbolicComplexity.substitute(
        callee_symbolic,
        mapping,
        caller_domains: caller_domains
      )
      substituted = annotate_propagated_domains(
        substituted,
        callee_symbolic,
        mapping,
        caller_domains,
        owner,
        callee,
        caller_fact,
        context
      )
      return substituted unless execution
      return substituted if Espalier::SymbolicComplexity.degree(execution).zero?

      relation = context["argument_cardinality_relation"]
      if receiver_state_dependent || relation == "independent_of"
        Espalier::SymbolicComplexity.multiply(execution, substituted)
      elsif relation == "partition_of"
        Espalier::SymbolicComplexity.sum(execution, substituted)
      else
        nil
      end
    end

    def annotate_propagated_domains(expression, callee_expression, mapping, caller_domains, owner, callee, caller_fact, context)
      return expression unless expression

      retained = (callee_expression[:domains] || {}).keys.reject do |domain_id|
        caller_domains.key?(domain_id) || !Array(mapping[domain_id]).empty?
      end
      return expression if retained.empty?

      domains = (expression[:domains] || {}).transform_values(&:dup)
      retained.each do |domain_id|
        domain = domains[domain_id]
        next unless domain

        domain["origin_owner"] = owner
        domain["origin_function"] = callee
        domain["propagated_via"] = {
          "owner" => caller_fact["owner"],
          "function" => caller_fact["function"],
          "message" => context["message"],
          "line" => context["line"]
        }.compact
      end
      expression.merge(domains: domains)
    end

    def mutual_recursion_summary(owner, member)
      graph = @internal_calls&.fetch(owner, nil)
      return nil unless graph

      members = recursive_component_members(graph, member)
      return nil if members.length < 2

      replay = state_replay_recursion_summary(owner, member, members: members)
      return replay if replay

      progress = members.flat_map do |caller|
        recursive_targets = Array(graph[caller]).select { |callee| members.include?(callee.to_s) }
        return nil unless recursive_targets.length == 1

        contexts = Array(@facts_by_method[[owner, caller]]).flat_map do |fact|
          Array(fact["call_contexts"])
        end.select { |context| context["message"].to_s == recursive_targets.first.to_s }
        return nil unless contexts.length == 1

        edge_progress = contexts.first["argument_progress"].to_s
        return nil unless %w[shrinking halving].include?(edge_progress)
        edge_progress
      end

      logarithmic = progress.all? { |value| value == "halving" }
      {
        time: logarithmic ? "O(log N)" : "O(N)",
        space: logarithmic ? "O(log N)" : "O(N)",
        reason: "size-change proof for single-branch mutually recursive component"
      }
    end

    # A checkpoint/restore region can make a receiver-state traversal execute
    # the same suffix again.  FactMine supplies only normalized protocol and
    # domain evidence; this SCC-level recurrence classification is deliberately
    # independent of parser names and source language.
    def state_replay_recursion_summary(owner, member, members: nil)
      graph = @internal_calls&.fetch(owner, nil)
      return nil unless graph

      members ||= recursive_component_members(graph, member)
      return nil if members.empty?

      component_key = [owner, members.sort]
      return @state_replay_summary_cache[component_key] if @state_replay_summary_cache.key?(component_key)

      @state_replay_summary_cache[component_key] = compute_state_replay_recursion_summary(
        owner, graph, members
      )
    end

    def compute_state_replay_recursion_summary(owner, graph, members)
      component_facts = members.flat_map { |name| Array(@facts_by_method[[owner, name]]) }
      replays = component_facts.flat_map { |fact| Array(fact["state_replays"]) }
      return nil if replays.empty?

      # A simple directed cycle is one recursive continuation, not branching.
      # Count normalized call sites so two calls to the same member are
      # preserved even when the project call graph de-duplicates its edges.
      recursive_call_sites = component_facts.sum do |fact|
        Array(fact["call_contexts"]).count do |context|
          members.include?(context["message"].to_s)
        end
      end
      return nil unless recursive_call_sites > members.length

      reachable = reachable_methods(graph, members)
      reachable_facts = reachable.flat_map { |name| Array(@facts_by_method[[owner, name]]) }
      progress_domains = reachable_facts.flat_map do |fact|
        Array(fact["state_progress"]).filter_map do |progress|
          progress["state_domain"].to_s unless progress["direction"].to_s == "monotonic_update"
        end
      end.uniq
      cursor_domains = reachable_facts.flat_map do |fact|
        Array(fact["state_cursor_domains"]).map { |cursor| cursor["cursor_domain"].to_s }
      end.uniq

      replay = replays.find do |candidate|
        domain = candidate["state_domain"].to_s
        progress_domains.include?(domain) &&
          cursor_domains.include?(domain) &&
          Array(candidate["replayed_calls"]).any? do |call|
            members.include?(call["message"].to_s)
          end
      end
      return nil unless replay

      {
        time: "O(2^N)",
        space: "O(N)",
        reason: "receiver-state checkpoint restoration replays a progressing recursive component"
      }
    end

    def recursive_component_members(graph, member)
      cache_key = [graph.object_id, member.to_s]
      return @recursive_component_cache[cache_key] if @recursive_component_cache.key?(cache_key)

      components = @recursive_components_by_graph[graph.object_id] ||= strongly_connected_components(graph)
      components.each do |component|
        component.each do |candidate|
          @recursive_component_cache[[graph.object_id, candidate]] = component
        end
      end
      @recursive_component_cache[cache_key] || []
    end

    def strongly_connected_components(graph)
      nodes = (graph.keys + graph.values.flatten).map(&:to_s).uniq
      adjacency = nodes.to_h { |node| [node, Array(graph[node]).map(&:to_s)] }
      visited = {}
      order = []
      nodes.each do |root|
        next if visited[root]

        pending = [[root, false]]
        until pending.empty?
          node, expanded = pending.pop
          if expanded
            order << node
            next
          end
          next if visited[node]

          visited[node] = true
          pending << [node, true]
          adjacency[node].reverse_each do |target|
            pending << [target, false] unless visited[target]
          end
        end
      end

      reversed = nodes.to_h { |node| [node, []] }
      adjacency.each do |source, targets|
        targets.each { |target| reversed[target] << source }
      end
      assigned = {}
      order.reverse_each.filter_map do |root|
        next if assigned[root]

        component = []
        pending = [root]
        until pending.empty?
          node = pending.pop
          next if assigned[node]

          assigned[node] = true
          component << node
          pending.concat(reversed[node])
        end
        component
      end
    end

    def reachable_methods(graph, starts)
      cache_key = [graph.object_id, Array(starts).map(&:to_s).sort]
      return @reachable_methods_cache[cache_key] if @reachable_methods_cache.key?(cache_key)

      pending = Array(starts).map(&:to_s)
      visited = {}
      until pending.empty?
        current = pending.pop
        next if visited[current]

        visited[current] = true
        pending.concat(Array(graph[current]).map(&:to_s))
      end
      @reachable_methods_cache[cache_key] = visited.keys
    end

    def reachable?(graph, start, target)
      pending = [start.to_s]
      visited = {}
      until pending.empty?
        current = pending.pop
        return true if current == target.to_s
        next if visited[current]

        visited[current] = true
        pending.concat(Array(graph[current]).map(&:to_s))
      end
      false
    end

    def summary_hint(fact, method, owner = nil)
      iterations = Array(fact["iterations"])
      recursion = fact.fetch("recursion", {})
      symbolic_time = Espalier::SymbolicComplexity.sum(
        iterations.filter_map do |row|
          Espalier::SymbolicComplexity.from_fact(row["symbolic_time"], fact["size_domains"])
        end
      )
      rendered_symbolic = Espalier::SymbolicComplexity.render(symbolic_time)&.first
      iteration_time = if iterations.any? { |row| row["cardinality_relation"] == "unknown" }
                         "unknown"
                       elsif rendered_symbolic
                         rendered_symbolic
                       else
                         iterations.max_by { |row| row["power"].to_i }&.fetch("execution_multiplicity", "O(1)") || "O(1)"
                       end
      state_replay = owner && state_replay_recursion_summary(owner, method[:name].to_s)
      recursion_time, recursion_space, recursion_reason = if state_replay
                                                            state_replay.values_at(:time, :space, :reason)
                                                          else
                                                            recursion_complexity(
                                                              recursion, Array(fact["parameters"]).length
                                                            )
                                                          end
      allocation_space = allocation_complexity(Array(fact["allocations"]))
      complexity = max_complexity(iteration_time, recursion_time)

      {
        type: :structural,
        line: fact.fetch("line", method[:line]).to_i,
        complexity: complexity,
        space: max_space_complexity(allocation_space, recursion_space),
        is_dynamic: complexity != "O(1)",
        operation: "normalized_complexity_facts",
        reason: recursion_reason || iteration_reason(iterations),
        confidence: complexity == "unknown" ? "unknown" : "high",
        time_complete: complexity != "unknown" && (!symbolic_time || symbolic_time.fetch(:complete, true)),
        space_complete: max_space_complexity(allocation_space, recursion_space) != "unknown",
        symbolic_time: symbolic_time,
        fact_source: "fact_mine"
      }
    end

    def allocation_complexity(allocations)
      return nil if allocations.empty?
      return "unknown" if allocations.any? { |row| row["cardinality_relation"] == "unknown" }
      return "O(N)" if allocations.any? { |row| row["bound_classification"] == "input" }

      "O(1)"
    end

    def max_space_complexity(left, right)
      return right unless left
      return left unless right
      return "unknown" if left == "unknown" || right == "unknown"

      complexity_rank(left) >= complexity_rank(right) ? left : right
    end

    def recursion_complexity(recursion, parameter_count)
      calls = recursion.fetch("calls", 0).to_i
      return ["O(1)", nil, nil] if calls.zero?
      unknown = recursion.fetch("unknown_progress_calls", 0).to_i
      return ["unknown", "unknown", "recursive argument progress is unknown"] if unknown.positive?
      visited = recursion.fetch("visited_guarded_calls", 0).to_i
      if visited.positive?
        return ["O(N)", "O(N)", "visited-set guarded structural recursion"]
      end

      shrinking = recursion.fetch("shrinking_calls", 0).to_i
      halving = recursion.fetch("halving_calls", 0).to_i
      loop_shrinking = recursion.fetch("loop_contained_shrinking_calls", 0).to_i
      return ["unknown", "unknown", "multi-dimensional recursive progress is unknown"] unless parameter_count == 1
      return ["O(N!)", "O(N)", "shrinking recursive call is loop-contained"] if loop_shrinking.positive?
      return ["O(2^N)", "O(N)", "multiple shrinking recursive branches"] if shrinking >= 2
      return ["O(N)", "O(log N)", "multiple halving recursive branches"] if halving >= 2
      return ["O(log N)", "O(log N)", "halving recursive progress"] if halving == 1

      ["O(N)", "O(N)", "single shrinking recursive progress"]
    end

    def iteration_reason(iterations)
      return "normalized iteration cardinality is unknown" if iterations.any? { |row| row["cardinality_relation"] == "unknown" }

      "complexity calculated from normalized iteration cardinality facts"
    end

    def max_complexity(left, right)
      return "unknown" if left == "unknown" || right == "unknown"

      complexity_rank(left) >= complexity_rank(right) ? left : right
    end

    def complexity_rank(value)
      Espalier::SymbolicComplexity.rank_string(value) * 10
    end

    def multiply(left, right)
      return "unknown" if left == "unknown" || right == "unknown"
      return "O(N!)" if left == "O(N!)" || right == "O(N!)"
      return "O(2^N)" if left == "O(2^N)" || right == "O(2^N)"

      left_power, left_log = polynomial_parts(left)
      right_power, right_log = polynomial_parts(right)
      power = left_power + right_power
      log = left_log || right_log
      return(log ? "O(log N)" : "O(1)") if power.zero?
      return(log ? "O(N log N)" : "O(N)") if power == 1

      log ? "O(N^#{power} log N)" : "O(N^#{power})"
    end

    def receiver_state_dependent?(owner, method, visiting = {})
      key = [owner, method]
      return false if visiting[key]

      visiting = visiting.merge(key => true)
      facts = Array(@facts_by_method[[owner, method]])
      return true if facts.any? do |fact|
        Array(fact["iterations"]).any? { |iteration| Array(iteration["state_domains"]).any? }
      end

      Array(@internal_calls&.dig(owner, method)).any? do |callee|
        receiver_state_dependent?(owner, callee.to_s, visiting)
      end
    end

    def propagated_call_complexity(context, callee_complexity, receiver_state_dependent: false)
      multiplicity = context.fetch("execution_multiplicity", "O(1)")
      return callee_complexity if multiplicity == "O(1)"
      return multiply(multiplicity, callee_complexity) if receiver_state_dependent

      case context["argument_cardinality_relation"]
      when "partition_of"
        max_complexity(multiplicity, callee_complexity)
      when "independent_of"
        multiply(multiplicity, callee_complexity)
      else
        "unknown"
      end
    end

    def polynomial_parts(value)
      case value
      when "O(N)" then [1, false]
      when "O(log N)" then [0, true]
      when "O(N log N)" then [1, true]
      when /\AO\(N\^(\d+)( log N)?\)\z/ then [Regexp.last_match(1).to_i, !Regexp.last_match(2).nil?]
      else [0, false]
      end
    end
  end
end
