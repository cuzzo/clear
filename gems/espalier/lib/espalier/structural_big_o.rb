# frozen_string_literal: true

require "set"
require_relative "symbolic_complexity"

module Espalier
  # Calculates time/space complexity from canonical facts emitted by FactMine.
  #
  # This class deliberately has no filesystem or source-text access. Syntax,
  # containment, recursion, and iteration semantics belong to FactMine's
  # Tree-sitter normalization layer. Missing facts remain unknown rather than
  # being guessed from source strings.
  class StructuralBigO
    CLOSED_CANDIDATE_MAX_QUALITY = "upper_bound_closed_candidate_max"
    def initialize(facts_by_method: {}, method_complexities: {}, method_spaces: {}, method_time_complete: {}, method_space_complete: {}, method_symbolic_time: {}, method_bound_qualities: {}, method_assumptions: {}, internal_calls: nil, recursive_edges: nil, resolved_calls: {}, candidate_calls: {}, resolved_recursive_edges: {}, authoritative_call_graph_methods: Set.new)
      @facts_by_method = facts_by_method
      @method_complexities = method_complexities
      @method_spaces = method_spaces
      @method_time_complete = method_time_complete
      @method_space_complete = method_space_complete
      @method_symbolic_time = method_symbolic_time
      @method_bound_qualities = method_bound_qualities
      @method_assumptions = method_assumptions
      @internal_calls = internal_calls
      @recursive_edges = recursive_edges || {}
      @resolved_calls = resolved_calls
      @candidate_calls = candidate_calls
      @resolved_recursive_edges = resolved_recursive_edges
      @recursive_component_cache = {}
      @recursive_components_by_graph = {}
      @state_replay_summary_cache = {}
      @state_rescan_summary_cache = {}
      @reachable_methods_cache = {}
      @receiver_state_dependent_by_owner = {}
      @authoritative_call_graph_methods = authoritative_call_graph_methods
      @summary_versions = Hash.new(0)
      @hint_dependencies = {}
      @hint_cache = {}
    end

    def apply_summary_delta!(method_id, owner, method, delta)
      values = [
        [@method_complexities, :time],
        [@method_spaces, :space],
        [@method_time_complete, :time_complete],
        [@method_space_complete, :space_complete],
        [@method_symbolic_time, :symbolic_time],
        [@method_bound_qualities, :bound_qualities],
        [@method_assumptions, :assumptions]
      ]
      values.each do |index, key|
        (index[owner.to_s] ||= {})[method.to_s] = delta[key]
        index[method_id.to_s] = delta[key] unless method_id.to_s.empty?
      end
      keys = [[owner.to_s, method.to_s]]
      keys << method_id.to_s unless method_id.to_s.empty?
      keys.each { |key| @summary_versions[key] += 1 }
    end

    def hints_for(_file, method, owner)
      method_id = method[:id].to_s
      facts = Array(@facts_by_method[method_id])
      if method_id.empty? || !@facts_by_method.key?(method_id)
        facts = Array(@facts_by_method[[owner.to_s, method[:name].to_s]])
      end
      caller_key = method_id.empty? ? [owner.to_s, method[:name].to_s] : method_id
      dependencies = (@hint_dependencies[caller_key] ||= hint_dependencies(
        facts, method_id, owner.to_s, method[:name].to_s
      ))
      version = dependencies.map { |dependency| [dependency, @summary_versions[dependency]] }
      cached = @hint_cache[caller_key]
      return cached[1] if cached && cached[0] == version

      hints = facts.map do |fact|
        summary_hint(
          fact,
          method,
          owner.to_s,
          # When SCIP covers every call in the method, resolved SCC edges below
          # are the recursion authority. The syntax-level same-name heuristic
          # must not independently poison overloads or duplicate exact edges.
          suppress_syntactic_recursion: @authoritative_call_graph_methods.include?(method_id)
        )
      end

      facts.each do |fact|
        Array(fact["call_contexts"]).each do |context|
          caller = method[:name].to_s
          message = context["message"].to_s
          line = context.fetch("line", method[:line]).to_i
          span = normalized_call_span(context["span"])
          # FactMine already priced this call site (a builtin operator, a
          # language intrinsic, or a stdlib-registry hit). Use that proven bound
          # directly instead of demanding a resolved project target - otherwise
          # a trivially O(1) operator leaves the function unknown.
          if (known_time = context["known_time_complexity"])
            hints << {
              type: :structural,
              line: line,
              complexity: propagated_call_complexity(context, known_time),
              space: context["known_space_complexity"] || "O(1)",
              is_dynamic: known_time != "O(1)",
              operation: message,
              reason: "fact-mine modeled call cost",
              confidence: "high",
              time_complete: true,
              space_complete: true,
              fact_source: "fact_mine"
            }
            next
          end
          resolved_target = resolved_call(method_id, owner.to_s, caller, message, span, line)
          candidate_call = candidate_call(method_id, owner.to_s, caller, message, span, line)
          if !resolved_target && candidate_call &&
              (candidate_bound = candidate_upper_bound(candidate_call, context))
            hints << {
              type: :structural,
              line: line,
              complexity: candidate_bound.fetch(:time),
              space: candidate_bound.fetch(:space),
              is_dynamic: true,
              operation: message,
              reason: "conservative upper bound over compiler-provided implementation candidates",
              confidence: "partial",
              time_complete: true,
              space_complete: true,
              complexity_bound_qualities: ([CLOSED_CANDIDATE_MAX_QUALITY] +
                candidate_bound.fetch(:qualities)).uniq,
              complexity_candidates: candidate_bound.fetch(:ids),
              complexity_assumptions: candidate_bound.fetch(:assumptions),
              fact_source: "fact_mine"
            }
            next
          end
          if resolved_target
            callee_owner = resolved_target[0].to_s
            callee = resolved_target[1].to_s
            callee_id = resolved_target[2].to_s
            recursive_edge = if !method_id.empty? && !callee_id.empty?
                               @resolved_recursive_edges[[method_id, callee_id]]
                             else
                               @resolved_recursive_edges[[owner.to_s, caller, callee_owner, callee]]
                             end
            if recursive_edge
              state_bound = if callee_owner == owner.to_s
                              state_replay_recursion_summary(owner.to_s, caller) ||
                                state_rescan_recursion_summary(owner.to_s, caller)
                            end
              recursive_bound = state_bound || resolved_recursive_bound(context)
              proven = recursive_bound.fetch(:time) != "unknown"
              hints << {
                type: :structural,
                line: line,
                complexity: recursive_bound.fetch(:time),
                space: recursive_bound.fetch(:space),
                is_dynamic: true,
                operation: message,
                reason: recursive_bound.fetch(:reason),
                confidence: if proven
                              recursive_bound[:quality] ? "partial" : "high"
                            else
                              "unknown"
                            end,
                time_complete: proven,
                space_complete: proven,
                evidence_gaps: proven ? nil : ["unresolved_recursive_progress"],
                complexity_bound_quality: recursive_bound[:quality],
                complexity_assumptions: Array(recursive_bound[:assumption]),
                fact_source: "fact_mine"
              }.compact
              next
            end
          else
            callee = message
            callee_owner = owner.to_s
            callee_id = ""
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
                evidence_gaps: mutual ? nil : ["unresolved_recursive_progress"],
                fact_source: "fact_mine"
              }.compact
            end
            next
          end

          callee_complexity = summary_value(@method_complexities, callee_id, callee_owner, callee)
          callee_space = summary_value(@method_spaces, callee_id, callee_owner, callee)
          callee_symbolic = summary_value(@method_symbolic_time, callee_id, callee_owner, callee)
          callee_time_complete = summary_value(@method_time_complete, callee_id, callee_owner, callee) != false
          callee_space_complete = summary_value(@method_space_complete, callee_id, callee_owner, callee) != false
          callee_bound_qualities = Array(summary_value(@method_bound_qualities, callee_id, callee_owner, callee))
          callee_assumptions = Array(summary_value(@method_assumptions, callee_id, callee_owner, callee))
          next unless callee_complexity || callee_space
          next if callee_complexity == "O(1)" && (!callee_space || callee_space == "O(1)") &&
            callee_time_complete && callee_space_complete

          propagated_symbolic = propagated_call_symbolic(
            callee_owner,
            callee,
            callee_id,
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
            complexity_bound_qualities: (callee_bound_qualities + (
              conservative_cardinality_product?(context) ? ["upper_bound_unknown_cardinality_relation"] : []
            )).uniq,
            complexity_assumptions: (callee_assumptions + (
              conservative_cardinality_product?(context) ?
                ["execution count and callee input size are conservatively treated as independent worst-case domains"] : []
            )).uniq,
            fact_source: "fact_mine"
          }.compact
        end
      end
      hints.freeze.tap { |value| @hint_cache[caller_key] = [version, value] }
    end

    private

    def resolved_call(method_id, owner, caller, message, span, line)
      target = @resolved_calls[[method_id, message, span]] if !method_id.empty? && span
      target ||= @resolved_calls[[owner, caller, message, span]] if span
      target ||= @resolved_calls[[method_id, message, line]] unless method_id.empty?
      target || @resolved_calls[[owner, caller, message, line]]
    end

    def candidate_call(method_id, owner, caller, message, span, line)
      target = @candidate_calls[[method_id, message, span]] if !method_id.empty? && span
      target ||= @candidate_calls[[owner, caller, message, span]] if span
      target ||= @candidate_calls[[method_id, message, line]] unless method_id.empty?
      target || @candidate_calls[[owner, caller, message, line]]
    end

    def hint_dependencies(facts, method_id, owner, caller)
      dependencies = Set.new
      facts.each do |fact|
        Array(fact["call_contexts"]).each do |context|
          message = context["message"].to_s
          line = context.fetch("line", 0).to_i
          span = normalized_call_span(context["span"])
          if (target = resolved_call(method_id, owner, caller, message, span, line))
            callee_owner, callee, callee_id = target.map(&:to_s)
            dependencies << (callee_id.to_s.empty? ? [callee_owner, callee] : callee_id)
          elsif (candidate = candidate_call(method_id, owner, caller, message, span, line))
            Array(candidate[:ids]).each { |id| dependencies << id.to_s unless id.to_s.empty? }
          elsif @internal_calls && Array(@internal_calls.dig(owner, caller)).include?(message)
            dependencies << [owner, message]
          end
        end
      end
      dependencies.to_a.sort_by(&:to_s).freeze
    end

    def candidate_upper_bound(candidate_call, context)
      ids = Array(candidate_call[:ids]).map(&:to_s).reject(&:empty?).uniq
      return nil if ids.empty?

      rows = ids.map do |id|
        time = @method_complexities[id]
        space = @method_spaces[id]
        complete = @method_time_complete[id] != false && @method_space_complete[id] != false
        return nil unless time && space && complete

        [propagated_call_complexity(context, time), space]
      end
      source_qualities = ids.flat_map { |id| Array(@method_bound_qualities[id]) }
      source_assumptions = ids.flat_map { |id| Array(@method_assumptions[id]) }
      closed_set_assumption = "#{candidate_call[:reason]} implementation set is closed for this analysis"
      {
        ids: ids.sort,
        time: rows.map(&:first).reduce("O(1)") { |bound, value| max_complexity(bound, value) },
        space: rows.map(&:last).reduce("O(1)") { |bound, value| max_space_complexity(bound, value) },
        qualities: source_qualities.map(&:to_s).reject(&:empty?).uniq.sort,
        assumptions: (source_assumptions + [closed_set_assumption]).map(&:to_s).reject(&:empty?).uniq.sort
      }
    end

    def summary_value(index, method_id, owner, method)
      return index[method_id] if !method_id.to_s.empty? && index.key?(method_id)

      index.dig(owner, method)
    end

    def propagated_call_symbolic(owner, callee, callee_id, caller_fact, context, callee_symbolic, receiver_state_dependent: false)
      return nil unless callee_symbolic

      exact_facts_available = !callee_id.to_s.empty? && @facts_by_method.key?(callee_id)
      callee_facts = Array(@facts_by_method[callee_id]) if exact_facts_available
      callee_facts = Array(@facts_by_method[[owner, callee]]) unless exact_facts_available
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
      # Substitute the callee's callback cost C with the cost of the callable
      # passed at this call site, under the same rule the externally-parametric
      # path uses.
      callable = callback_argument_cost(caller_fact["path"], context["span"])
      if callable
        callee_symbolic = Espalier::SymbolicComplexity.substitute_callback_cost(
          callee_symbolic, callable.fetch(:expression), callable_constant: callable.fetch(:constant)
        )
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
      return Espalier::SymbolicComplexity.multiply(execution, substituted) if
        Espalier::SymbolicComplexity.degree(substituted).zero?

      relation = context["argument_cardinality_relation"]
      if receiver_state_dependent || relation == "independent_of"
        Espalier::SymbolicComplexity.multiply(execution, substituted)
      elsif relation == "partition_of"
        Espalier::SymbolicComplexity.sum(execution, substituted)
      else
        nil
      end
    end

    # The cost of the callable passed at one call site, as the shared
    # substitution rule wants it.
    def callback_argument_cost(path, span)
      ids = Array(@callback_arg_by_call && @callback_arg_by_call[[path, normalized_call_span(span)]])
      return nil if ids.empty?

      Espalier::SymbolicComplexity.worst_callable(
        ids.map do |id|
          key = id.to_s
          {
            expression: @method_symbolic_time && @method_symbolic_time[key],
            constant: @method_complexities[key] == "O(1)" && @method_time_complete[key] != false
          }
        end
      )
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
      Espalier::SymbolicComplexity.normalize(expression.merge(domains: domains))
    end

    def mutual_recursion_summary(owner, member)
      graph = @internal_calls&.fetch(owner, nil)
      return nil unless graph

      members = recursive_component_members(graph, member)
      return nil if members.length < 2

      replay = state_replay_recursion_summary(owner, member, members: members)
      return replay if replay
      rescan = state_rescan_recursion_summary(owner, member, members: members)
      return rescan if rescan

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

    # A single recursive continuation that advances a receiver cursor has
    # linear depth. If every level calls a scan over the remaining collection,
    # its per-level cost must be multiplied by that depth. FactMine supplies
    # cursor aliases and collection domains, keeping this recurrence generic
    # across source languages.
    def state_rescan_recursion_summary(owner, member, members: nil)
      graph = @internal_calls&.fetch(owner, nil)
      return nil unless graph

      members ||= recursive_component_members(graph, member)
      return nil if members.empty?

      component_key = [owner, members.sort]
      return @state_rescan_summary_cache[component_key] if @state_rescan_summary_cache.key?(component_key)

      component_facts = members.flat_map { |name| Array(@facts_by_method[[owner, name]]) }
      recursive_call_sites = component_facts.sum do |fact|
        Array(fact["call_contexts"]).count do |context|
          members.include?(context["message"].to_s)
        end
      end
      return @state_rescan_summary_cache[component_key] = nil unless recursive_call_sites == members.length

      progress_domains = component_facts.flat_map do |fact|
        Array(fact["state_progress"]).filter_map do |progress|
          progress["state_domain"].to_s if %w[advance retreat].include?(progress["direction"].to_s)
        end
      end.uniq
      return @state_rescan_summary_cache[component_key] = nil if progress_domains.empty?

      reachable = reachable_methods(graph, members)
      reachable_facts = reachable.flat_map { |name| Array(@facts_by_method[[owner, name]]) }
      cursor_pairs = reachable_facts.flat_map { |fact| Array(fact["state_cursor_domains"]) }

      summary = cursor_pairs.filter_map do |cursor|
        cursor_domain = cursor["cursor_domain"].to_s
        collection_domain = cursor["collection_domain"].to_s
        next unless progress_domains.include?(cursor_domain)
        next unless recursion_bounded_by_domain?(component_facts, collection_domain)

        scan_costs = reachable_facts.flat_map do |fact|
          Array(fact["iterations"]).filter_map do |iteration|
            factors = Array(iteration.dig("symbolic_time", "factors"))
            next unless factors.any? { |factor| factor["domain_id"].to_s == collection_domain }

            Espalier::SymbolicComplexity.render(
              Espalier::SymbolicComplexity.from_fact(iteration["symbolic_time"], fact["size_domains"])
            )&.first || iteration["execution_multiplicity"].to_s
          end
        end
        next if scan_costs.empty?

        scan_cost = scan_costs.max_by { |cost| complexity_rank(cost) }
        {
          time: multiply("O(N)", scan_cost),
          space: "O(N)",
          reason: "receiver-state recursive depth repeatedly scans the cursor-bounded collection"
        }
      end.first

      @state_rescan_summary_cache[component_key] = summary
    end

    def recursion_bounded_by_domain?(component_facts, collection_domain)
      comparison_messages = %w[< <= > >= == !=]
      component_facts.any? do |fact|
        Array(fact["call_contexts"]).any? do |context|
          next false unless comparison_messages.include?(context["message"].to_s)

          domains = Array(context["receiver_size_domains"]) +
            Array(context["argument_size_domains"]).flatten
          domains.map(&:to_s).include?(collection_domain)
        end
      end
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

    def normalized_call_span(span)
      values = Array(span)
      return nil unless values.length == 4

      values.map(&:to_i).freeze
    end

    def summary_hint(fact, method, owner = nil, suppress_syntactic_recursion: false)
      iterations = Array(fact["iterations"])
      recursion = suppress_syntactic_recursion ? {} : fact.fetch("recursion", {})
      evidence_gaps = iterations.filter_map { |row| row["evidence_gap"] }
      evidence_gaps.concat(Array(fact["allocations"]).filter_map { |row| row["evidence_gap"] })
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
      state_rescan = owner && state_rescan_recursion_summary(owner, method[:name].to_s)
      state_recursion = state_replay || state_rescan
      recursion_time, recursion_space, recursion_reason = if state_recursion
                                                            state_recursion.values_at(:time, :space, :reason)
                                                          else
                                                            recursion_complexity(
                                                              recursion, Array(fact["parameters"]).length
                                                            )
                                                          end
      evidence_gaps << "unresolved_recursive_progress" if recursion_reason&.include?("unknown")
      allocation_space, symbolic_space = allocation_complexity(
        Array(fact["allocations"]),
        fact["size_domains"]
      )
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
        evidence_gaps: evidence_gaps.uniq.sort,
        symbolic_time: symbolic_time,
        symbolic_space: symbolic_space,
        fact_source: "fact_mine"
      }
    end

    def allocation_complexity(allocations, domains)
      return [nil, nil] if allocations.empty?
      return ["unknown", nil] if allocations.any? { |row| row["cardinality_relation"] == "unknown" }

      symbolic = Espalier::SymbolicComplexity.sum(
        allocations.filter_map do |row|
          Espalier::SymbolicComplexity.from_fact(row["symbolic_size"], domains)
        end
      )
      rendered_symbolic = Espalier::SymbolicComplexity.render(symbolic)&.first
      return [rendered_symbolic, symbolic] if rendered_symbolic
      return ["O(N)", nil] if allocations.any? { |row| row["bound_classification"] == "input" }

      ["O(1)", nil]
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

    def receiver_state_dependent?(owner, method, _visiting = nil)
      dependent = @receiver_state_dependent_by_owner[owner] ||= begin
        graph = @internal_calls&.fetch(owner, nil) || {}
        reverse = Hash.new { |hash, key| hash[key] = Set.new }
        graph.each do |caller, callees|
          reverse[caller.to_s]
          Array(callees).each { |callee| reverse[callee.to_s] << caller.to_s }
        end
        seeds = reverse.each_key.select do |candidate|
          Array(@facts_by_method[[owner, candidate]]).any? do |fact|
            Array(fact["iterations"]).any? do |iteration|
              Array(iteration["state_domains"]).any?
            end
          end
        end
        reachable_callers = Set.new(seeds)
        queue = seeds.dup
        until queue.empty?
          callee = queue.shift
          reverse[callee].each do |caller|
            queue << caller if reachable_callers.add?(caller)
          end
        end
        reachable_callers
      end
      dependent.include?(method.to_s)
    end

    def propagated_call_complexity(context, callee_complexity, receiver_state_dependent: false)
      multiplicity = context.fetch("execution_multiplicity", "O(1)")
      return callee_complexity if multiplicity == "O(1)"
      # A constant callee repeated according to a proven execution domain has
      # that domain's cost. No argument/receiver cardinality relation is needed
      # because the callee contributes no size-dependent factor.
      return multiplicity if callee_complexity == "O(1)"
      return multiply(multiplicity, callee_complexity) if receiver_state_dependent

      case context["argument_cardinality_relation"]
      when "partition_of"
        max_complexity(multiplicity, callee_complexity)
      when "independent_of"
        multiply(multiplicity, callee_complexity)
      else
        # The relationship is not precise enough to simplify the product, but
        # multiplying the two individually proven upper bounds is still a safe
        # upper bound. Consumers retain an explicit quality flag because the
        # result may substantially overstate partitioned/amortized behavior.
        multiply(multiplicity, callee_complexity)
      end
    end

    def conservative_cardinality_product?(context)
      context.fetch("execution_multiplicity", "O(1)") != "O(1)" &&
        !%w[partition_of independent_of].include?(context["argument_cardinality_relation"])
    end

    def resolved_recursive_bound(context)
      progress = context["argument_progress"].to_s
      multiplicity = context.fetch("execution_multiplicity", "O(1)")
      if multiplicity == "O(1)" && progress == "halving"
        return { time: "O(log N)", space: "O(log N)", reason: "exact recursive edge with normalized halving progress" }
      end
      if multiplicity == "O(1)" && progress == "shrinking"
        return { time: "O(N)", space: "O(N)", reason: "exact recursive edge with normalized shrinking progress" }
      end
      # A recursive edge whose argument is a partition of the receiver - the
      # loop's own iteration binding over a decomposition, i.e. a tree/graph
      # traversal - reaches every element exactly once, so the work is linear
      # in the structure. This proof outranks the multiplicity reading below:
      # a traversal argument that merely happens to spell an offset
      # (`walk(kids[i - 1])`) reads as loop-contained shrinking progress and
      # would otherwise be priced O(N!).
      if context["argument_cardinality_relation"] == "partition_of"
        return {
          time: "O(N)", space: "O(N)",
          reason: "recursive traversal over a partition of the input reaches each element once"
        }
      end
      if %w[halving shrinking].include?(progress)
        return {
          time: "O(N!)", space: "O(N)",
          reason: "conservative upper bound for loop-contained exact recursive progress",
          quality: "upper_bound_recursive_multiplicity"
        }
      end

      # Nothing proved this edge makes progress, and one call context cannot
      # establish a branching factor, so no bound follows - not even an
      # exponential one. Report the missing proof the way the syntactic
      # classifier does, so the gap is attributable instead of being published
      # as a complete result.
      {
        time: "unknown", space: "unknown",
        reason: "exact recursive edge progress is unknown"
      }
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
