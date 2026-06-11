# frozen_string_literal: true

require "set"

module Espalier
  # Ranks macro-level architecture pressure from the normalized Espalier
  # manifest. The analyzer is conservative: it only creates collaboration edges
  # when a delegation target resolves to another manifest-visible owner.
  class ArchitectureAnalyzer
    DEFAULT_ENCAPSULATION_THRESHOLD = 25.0
    DEFAULT_COLLABORATION_THRESHOLD = 30.0
    DEFAULT_MEDIATOR_THRESHOLD = 28.0
    DEFAULT_COHESION_THRESHOLD = 30.0

    ROLE_TERMS = %w[
      analysis analyzer builder checker classifier collector coordinator
      context emit emitter environment facade frontend helper host importer
      manager mediator registry resolver rewriter schema schemas server service
      session state
    ].freeze
    ROLE_PATTERN = /(?:Analysis|Analyzer|Builder|Checker|Classifier|Collector|Coordinator|Context|Emit|Emitter|Environment|Facade|Frontend|Helper|Host|Importer|Manager|Mediator|Registry|Resolver|Rewriter|Schemas?|Server|Service|Session|State)\z/
    CORE_TYPES = %w[
      Array BasicObject Boolean Class FalseClass Float Hash Integer NilClass
      Object Proc Set String Symbol T TrueClass
    ].freeze
    TOKEN_STOP_WORDS = (ROLE_TERMS + %w[
      a an and ast base class common data default domain domains entry file fn
      function helper helpers item kind lib lowerer lowering method methods mir
      module node nodes object phase result src type value values
    ]).to_set.freeze

    def self.encapsulation_pressure(manifest, threshold: DEFAULT_ENCAPSULATION_THRESHOLD)
      new(manifest).encapsulation_pressure(threshold: threshold)
    end

    def self.collaboration_meshes(manifest, threshold: DEFAULT_COLLABORATION_THRESHOLD)
      new(manifest).collaboration_meshes(threshold: threshold)
    end

    def self.mediator_candidates(manifest, threshold: DEFAULT_MEDIATOR_THRESHOLD)
      new(manifest).mediator_candidates(threshold: threshold)
    end

    def self.owner_state_cohesion(manifest, threshold: DEFAULT_COHESION_THRESHOLD)
      new(manifest).owner_state_cohesion(threshold: threshold)
    end

    def initialize(manifest)
      @manifest = Array(manifest)
      @owners = @manifest.map { |mod| mod[:module].to_s }.to_set
      @owner_by_simple = build_owner_by_simple
      @module_by_owner = @manifest.each_with_object({}) do |mod, out|
        out[mod[:module].to_s] ||= mod
      end
    end

    def encapsulation_pressure(threshold: DEFAULT_ENCAPSULATION_THRESHOLD)
      owner_summaries.filter_map do |row|
        next if row[:data_carrier]
        next unless encapsulation_evidence?(row)
        next if row[:score] < threshold

        row
      end.sort_by { |row| [-row[:score], row[:file].to_s, row[:owner].to_s] }
    end

    def collaboration_meshes(threshold: DEFAULT_COLLABORATION_THRESHOLD)
      rows = hub_meshes + dense_cycle_meshes
      rows = dedupe_meshes(rows)
      rows.select { |row| row[:score] >= threshold }
          .sort_by { |row| [-row[:score], row[:kind].to_s, row[:owners].join(",")] }
    end

    def mediator_candidates(threshold: DEFAULT_MEDIATOR_THRESHOLD)
      rows = collaboration_meshes(threshold: DEFAULT_COLLABORATION_THRESHOLD).filter_map do |mesh|
        row = mediator_candidate_for(mesh)
        next unless row
        next if row[:score] < threshold

        row
      end
      rows.sort_by { |row| [-row[:score], row[:owners].join(",")] }
    end

    def owner_state_cohesion(threshold: DEFAULT_COHESION_THRESHOLD)
      owner_summaries.filter_map do |summary|
        row = owner_state_cohesion_row(summary)
        next unless row
        next if row[:score] < threshold

        row
      end.sort_by { |row| [-row[:score], row[:file].to_s, row[:owner].to_s] }
    end

    def owner_edges
      @owner_edges ||= build_owner_edges
    end

    private

    def build_owner_by_simple
      grouped = @owners.group_by { |owner| owner.split("::").last }
      grouped.each_with_object({}) do |(simple, owners), out|
        out[simple] = owners.first if owners.size == 1
      end
    end

    def owner_summaries
      @owner_summaries ||= @manifest.map { |mod| owner_summary(mod) }.uniq do |summary|
        [summary[:owner], summary[:file]]
      end
    end

    def owner_summary(mod)
      owner = mod[:module].to_s
      funcs = functions(mod)
      public_funcs = funcs.select { |fn| visibility_for(fn) == :public }
      private_funcs = funcs - public_funcs
      state_names = states(mod).map { |state| state[:name].to_s }
      write_methods = funcs.count { |fn| effect_list(fn, :writes).any? }
      public_state_methods = public_funcs.count { |fn| state_touch_count(fn).positive? }
      public_mutators = public_funcs.count { |fn| mutating_public_method?(fn) }
      public_ratio = funcs.empty? ? 0.0 : public_funcs.size.to_f / funcs.size
      candidate_names = Array(privacy_candidates_by_owner[owner]).map { |row| row[:name].to_s }
      lifecycle_slots = lifecycle_slot_count(mod)
      fan_out = owner_fan_out(owner)
      data_carrier = data_carrier?(
        state_count: state_names.size,
        public_methods: public_funcs.size,
        public_mutators: public_mutators,
        write_methods: write_methods,
        delegations: delegation_count(funcs),
        privacy_candidates: candidate_names.size
      )
      score = encapsulation_score(
        state_count: state_names.size,
        public_methods: public_funcs.size,
        public_ratio: public_ratio,
        public_state_methods: public_state_methods,
        public_mutators: public_mutators,
        write_methods: write_methods,
        privacy_candidates: candidate_names.size,
        lifecycle_slots: lifecycle_slots,
        fan_out: fan_out,
        data_carrier: data_carrier
      )

      {
        owner: owner,
        file: mod[:file],
        state_count: state_names.size,
        public_methods: public_funcs.size,
        private_methods: private_funcs.size,
        total_methods: funcs.size,
        public_ratio: public_ratio,
        public_state_methods: public_state_methods,
        public_mutators: public_mutators,
        write_methods: write_methods,
        lifecycle_slots: lifecycle_slots,
        privacy_candidates: candidate_names,
        fan_out: fan_out,
        delegations: delegation_count(funcs),
        data_carrier: data_carrier,
        score: round(score),
        flags: encapsulation_flags(
          state_count: state_names.size,
          public_methods: public_funcs.size,
          public_state_methods: public_state_methods,
          public_mutators: public_mutators,
          privacy_candidates: candidate_names.size,
          lifecycle_slots: lifecycle_slots,
          fan_out: fan_out
        )
      }
    end

    def encapsulation_score(
      state_count:,
      public_methods:,
      public_ratio:,
      public_state_methods:,
      public_mutators:,
      write_methods:,
      privacy_candidates:,
      lifecycle_slots:,
      fan_out:,
      data_carrier:
    )
      score = state_count * 2.5
      score += public_methods * 0.3
      score += public_ratio * 5.0 if public_methods >= 6
      score += public_state_methods * 3.0
      score += public_mutators * 5.0
      score += write_methods * 0.8
      score += privacy_candidates * 1.5
      score += lifecycle_slots * 4.0
      score += fan_out * 1.2 if state_count.positive? || public_state_methods.positive?
      score += 8.0 if state_count >= 5 && public_methods >= 10
      score += 8.0 if public_mutators >= 3
      score += 3.0 if privacy_candidates >= 2 && (state_count.positive? || public_state_methods.positive?)
      score -= 8.0 if data_carrier
      score
    end

    def encapsulation_evidence?(row)
      row[:state_count] >= 3 ||
        row[:public_state_methods] >= 3 ||
        row[:public_mutators] >= 2 ||
        (row[:privacy_candidates].any? && (row[:state_count].positive? || row[:public_state_methods].positive?)) ||
        (row[:fan_out] >= 6 && row[:state_count].positive?) ||
        row[:lifecycle_slots] >= 2
    end

    def data_carrier?(state_count:, public_methods:, public_mutators:, write_methods:, delegations:, privacy_candidates:)
      state_count.positive? &&
        public_methods <= state_count + 4 &&
        public_mutators.zero? &&
        write_methods <= 1 &&
        delegations <= state_count * 2 + 4 &&
        privacy_candidates.zero?
    end

    def encapsulation_flags(
      state_count:,
      public_methods:,
      public_state_methods:,
      public_mutators:,
      privacy_candidates:,
      lifecycle_slots:,
      fan_out:
    )
      flags = []
      flags << "state-heavy" if state_count >= 5
      flags << "broad-public-api" if public_methods >= 20
      flags << "public-state-surface" if public_state_methods >= 4
      flags << "public-mutators" if public_mutators >= 2
      flags << "internal-public-helpers" if privacy_candidates.positive?
      flags << "lifecycle-state" if lifecycle_slots >= 2
      flags << "stateful-fanout" if fan_out >= 6 && state_count.positive?
      flags
    end

    def lifecycle_slot_count(mod)
      funcs = functions(mod)
      states(mod).count do |state|
        name = state[:name].to_s
        readers = funcs.count { |fn| effect_list(fn, :reads).include?(name) }
        writers = funcs.count { |fn| effect_list(fn, :writes).include?(name) }
        readers >= 5 || writers >= 3 || actionable_protocol_state?(state)
      end
    end

    def actionable_protocol_state?(state)
      Array(state[:properties]).any? do |prop|
        prop.to_s.include?("protocol interfaces:")
      end
    end

    def owner_fan_out(owner)
      owner_edges.count { |edge| edge[:source] == owner }
    end

    def privacy_candidates_by_owner
      @privacy_candidates_by_owner ||= PrivacyAnalyzer.candidates(@manifest).group_by { |row| row[:module].to_s }
    end

    def build_owner_edges
      grouped = {}
      @manifest.each do |mod|
        source = mod[:module].to_s
        state_types = state_type_index(mod)
        functions(mod).each do |fn|
          calls_for(fn).each do |call|
            target = target_owner_for(call[:name], source, state_types)
            next unless target
            next if target == source
            next if collaboration_target_noise?(target)

            key = [source, target]
            row = grouped[key] ||= {
              source: source,
              target: target,
              count: 0,
              conditional_count: 0,
              stateful_count: 0,
              methods: Set.new,
              samples: []
            }
            row[:count] += 1
            row[:conditional_count] += 1 if call[:conditional]
            row[:stateful_count] += 1 if state_touch_count(fn).positive?
            row[:methods] << fn[:name].to_s
            row[:samples] << call[:name].to_s if row[:samples].size < 4
          end
        end
      end

      grouped.values.map do |row|
        row.merge(
          methods: row[:methods].to_a.sort,
          samples: row[:samples].uniq
        )
      end.sort_by { |row| [-row[:count], row[:source], row[:target]] }
    end

    def collaboration_target_noise?(owner)
      mod = @module_by_owner[owner]
      return false unless mod

      funcs = functions(mod)
      state_count = states(mod).size
      delegations = delegation_count(funcs)
      write_methods = funcs.count { |fn| effect_list(fn, :writes).any? }
      simple = owner.split("::").last

      return true if funcs.empty? && simple.match?(/(?:Entry|Fact|Plan|Record|Result|Shape|Site|Spec)\z/)
      return false unless delegations.zero?

      small_value_name = simple.match?(/(?:Binding|Entry|Fact|Frame|Plan|Record|Result|Shape|Site|Spec|State)\z/)
      small_value_name && state_count <= 4 && funcs.size <= 6 && write_methods <= 1
    end

    def calls_for(fn)
      delegations = fn[:DELEGATIONS] || {}
      always = Array(delegations[:always_calls]).map do |name|
        { name: name.to_s, conditional: false }
      end
      conditional = Array(delegations[:conditionally_calls]).map do |name|
        { name: name.to_s, conditional: true }
      end
      always + conditional
    end

    def target_owner_for(call_name, source_owner, state_types)
      receiver = receiver_for(call_name)
      return nil unless receiver
      return nil if receiver == "self" || receiver == source_owner

      if receiver.start_with?("@")
        state_name = receiver.split(".").first
        return owner_for_type(state_types[state_name])
      end

      return nil unless receiver.match?(/\A[A-Z]/)

      owner_for_type(receiver)
    end

    def receiver_for(call_name)
      return nil unless call_name.include?(".")

      call_name.split(".", 2).first
    end

    def owner_for_type(type_text)
      return nil if type_text.nil?

      text = type_text.to_s
      return text if @owners.include?(text)
      return @owner_by_simple[text] if @owner_by_simple.key?(text)

      owner_type_tokens(text).each do |token|
        next if CORE_TYPES.include?(token)
        return token if @owners.include?(token)
        return @owner_by_simple[token] if @owner_by_simple.key?(token)

        simple = token.split("::").last
        return @owner_by_simple[simple] if @owner_by_simple.key?(simple)
      end
      nil
    end

    def owner_type_tokens(text)
      text.scan(/[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*/)
    end

    def state_type_index(mod)
      states(mod).each_with_object({}) do |state, out|
        out[state[:name].to_s] = state[:type].to_s if state[:type]
      end
    end

    def hub_meshes
      owner_edges.group_by { |edge| edge[:source] }.filter_map do |source, edges|
        targets = edges.map { |edge| edge[:target] }.uniq.sort
        total_edges = edges.sum { |edge| edge[:count] }
        next if targets.size < 6
        next if total_edges < 6

        row = mesh_row(
          kind: :hub,
          owners: ([source] + targets).uniq,
          driver: source,
          edges: edges,
          fan_out: targets.size
        )
        next unless row

        row
      end
    end

    def dense_cycle_meshes
      strongly_connected_components.filter_map do |nodes|
        next if nodes.size < 3

        internal_edges = internal_edges_for(nodes)
        next if internal_edges.size < nodes.size

        row = mesh_row(
          kind: :dense_cycle,
          owners: nodes.sort,
          driver: nodes.sort.first,
          edges: internal_edges,
          fan_out: internal_edges.map { |edge| edge[:target] }.uniq.size
        )
        next unless row
        next if row[:density] < 0.12 && row[:bidirectional_pairs].zero?

        row
      end
    end

    def mesh_row(kind:, owners:, driver:, edges:, fan_out:)
      node_count = owners.size
      return nil if node_count < 2

      possible_edges = node_count * (node_count - 1)
      total_calls = edges.sum { |edge| edge[:count] }
      density = possible_edges.zero? ? 0.0 : edges.size.to_f / possible_edges
      bidirectional_pairs = bidirectional_pair_count(owners)
      stateful_calls = edges.sum { |edge| edge[:stateful_count] }
      conditional_calls = edges.sum { |edge| edge[:conditional_count] }
      score = mesh_score(
        kind: kind,
        node_count: node_count,
        edge_count: edges.size,
        total_calls: total_calls,
        density: density,
        bidirectional_pairs: bidirectional_pairs,
        fan_out: fan_out,
        stateful_calls: stateful_calls,
        conditional_calls: conditional_calls
      )

      {
        kind: kind,
        owners: owners,
        driver: driver,
        node_count: node_count,
        edge_count: edges.size,
        total_calls: total_calls,
        density: round(density),
        bidirectional_pairs: bidirectional_pairs,
        fan_out: fan_out,
        stateful_calls: stateful_calls,
        conditional_calls: conditional_calls,
        common_terms: common_terms_for(owners),
        top_edges: top_edge_labels(edges),
        score: round(score)
      }
    end

    def mesh_score(
      kind:,
      node_count:,
      edge_count:,
      total_calls:,
      density:,
      bidirectional_pairs:,
      fan_out:,
      stateful_calls:,
      conditional_calls:
    )
      score = node_count * 2.0
      score += edge_count * 2.0
      score += [total_calls * 0.7, 45.0].min
      score += density * 35.0
      score += bidirectional_pairs * 8.0
      score += fan_out * 2.0
      score += [stateful_calls * 1.5, 24.0].min
      score += [conditional_calls * 0.7, 16.0].min
      score += 10.0 if kind == :dense_cycle
      score
    end

    def internal_edges_for(nodes)
      node_set = nodes.to_set
      owner_edges.select do |edge|
        node_set.include?(edge[:source]) && node_set.include?(edge[:target])
      end
    end

    def bidirectional_pair_count(nodes)
      node_set = nodes.to_set
      directed = owner_edges.each_with_object(Set.new) do |edge, out|
        next unless node_set.include?(edge[:source]) && node_set.include?(edge[:target])

        out << [edge[:source], edge[:target]]
      end
      directed.count do |source, target|
        source < target && directed.include?([target, source])
      end
    end

    def top_edge_labels(edges)
      edges.sort_by { |edge| [-edge[:count], edge[:source], edge[:target]] }
           .first(5)
           .map { |edge| "#{edge[:source]} -> #{edge[:target]} (#{edge[:count]})" }
    end

    def dedupe_meshes(rows)
      rows.each_with_object({}) do |row, out|
        key = row[:owners].sort
        current = out[key]
        out[key] = row if current.nil? || row[:score] > current[:score]
      end.values
    end

    def strongly_connected_components
      adjacency = owner_edges.each_with_object(Hash.new { |h, k| h[k] = [] }) do |edge, out|
        out[edge[:source]] << edge[:target]
        out[edge[:target]] ||= []
      end
      Tarjan.new(adjacency).components
    end

    def mediator_candidate_for(mesh)
      return nil if mesh[:node_count] < 4

      terms = mesh[:common_terms]
      return nil if terms.empty?

      role_owner = existing_role_owner(mesh[:owners], terms)
      overloaded_role = role_owner && overloaded_owner?(role_owner)
      return nil if role_owner && !overloaded_role

      score = mesh[:score] * 0.55
      score += terms.size * 3.0
      score += mesh[:bidirectional_pairs] * 4.0
      score += 8.0 unless role_owner
      score += 10.0 if overloaded_role

      {
        owners: mesh[:owners],
        driver: role_owner || mesh[:driver],
        source_mesh_kind: mesh[:kind],
        score: round(score),
        common_terms: terms,
        evidence: mediator_evidence(mesh, role_owner, overloaded_role),
        suggestion: mediator_suggestion(terms.first, role_owner, overloaded_role)
      }
    end

    def existing_role_owner(owners, terms)
      owners.find do |owner|
        simple = owner.split("::").last
        next false unless simple.match?(ROLE_PATTERN)

        owner_terms = owner_tokens(owner)
        (owner_terms & terms).any?
      end
    end

    def overloaded_owner?(owner)
      row = owner_summaries.find { |summary| summary[:owner] == owner }
      return false unless row

      row[:score] >= 55.0 ||
        row[:state_count] >= 8 ||
        row[:public_state_methods] >= 8 ||
        row[:privacy_candidates].size >= 3
    end

    def mediator_evidence(mesh, role_owner, overloaded_role)
      evidence = []
      evidence << "#{mesh[:node_count]} owners"
      evidence << "#{mesh[:edge_count]} owner edges"
      evidence << "density=#{mesh[:density]}"
      evidence << "bidirectional=#{mesh[:bidirectional_pairs]}" if mesh[:bidirectional_pairs].positive?
      evidence << "hub fan-out=#{mesh[:fan_out]}" if mesh[:kind] == :hub
      evidence << "existing role #{role_owner} is overloaded" if overloaded_role
      evidence << "no manifest-visible role owner" unless role_owner
      evidence
    end

    def mediator_suggestion(term, role_owner, overloaded_role)
      label = term.to_s.split("_").map(&:capitalize).join
      if overloaded_role
        "split a smaller #{label} context/mediator out of #{role_owner}"
      elsif role_owner
        "review whether #{role_owner} should absorb more of this protocol"
      else
        "look for a missing #{label} coordinator/context boundary"
      end
    end

    def owner_state_cohesion_row(summary)
      mod = @manifest.find { |candidate| candidate[:module].to_s == summary[:owner] }
      return nil unless mod

      state_names = states(mod).map { |state| state[:name].to_s }.to_set
      return nil if state_names.size < 2

      method_touches = direct_method_state_touches(mod, state_names)
      return nil if method_touches.size < 4

      base_components = state_components(method_touches)
      expanded = expand_components_with_internal_call_evidence(
        mod: mod,
        components: base_components,
        direct_touches: method_touches,
        state_names: state_names
      )
      components = expanded[:components]
      bridge_methods = expanded[:bridge_methods]
      return nil if components.size < 2

      method_count = components.sum { |component| component[:methods].size }
      largest = components.map { |component| component[:methods].size }.max
      largest_ratio = largest.to_f / method_count
      fragmentation = 1.0 - largest_ratio
      isolated = components.count { |component| component[:methods].size == 1 }
      return nil if cohesion_noise?(summary, method_count, components, fragmentation, isolated, bridge_methods)

      score = cohesion_score(
        component_count: components.size,
        fragmentation: fragmentation,
        isolated: isolated,
        method_count: method_count,
        state_count: state_names.size,
        public_components: public_component_count(components, mod),
        bridge_count: bridge_methods.size
      )

      {
        owner: summary[:owner],
        file: summary[:file],
        state_count: state_names.size,
        stateful_methods: method_count,
        direct_stateful_methods: method_touches.size,
        component_count: components.size,
        largest_component_methods: largest,
        largest_component_ratio: round(largest_ratio),
        fragmentation: round(fragmentation),
        isolated_components: isolated,
        public_components: public_component_count(components, mod),
        bridge_method_count: bridge_methods.size,
        bridge_methods: bridge_methods.first(5).map { |bridge| bridge[:name] },
        component_samples: component_samples(components),
        score: round(score),
        flags: cohesion_flags(components, fragmentation, isolated, bridge_methods)
      }
    end

    def direct_method_state_touches(mod, state_names)
      funcs = functions(mod)
      funcs.each_with_object({}) do |fn, out|
        next if fn[:name].to_s == "initialize"
        next if trivial_state_accessor?(fn, state_names)

        touches = direct_state_touches(fn, state_names)
        out[fn[:name].to_s] = touches unless touches.empty?
      end
    end

    def expand_components_with_internal_call_evidence(mod:, components:, direct_touches:, state_names:)
      by_name = functions(mod).each_with_object({}) { |fn, out| out[fn[:name].to_s] = fn }
      component_by_state = components.each_with_index.each_with_object({}) do |(component, index), out|
        component[:states].each { |state_name| out[state_name] = index }
      end
      expanded_components = components.map do |component|
        { methods: component[:methods].dup, states: component[:states].dup }
      end
      bridge_methods = []

      functions(mod).each do |fn|
        method_name = fn[:name].to_s
        next if method_name == "initialize"
        next if direct_touches.key?(method_name)
        next if trivial_state_accessor?(fn, state_names)

        touches = propagated_touches_for(fn, by_name, state_names)
        next if touches.empty?

        component_indexes = touches.map { |state_name| component_by_state[state_name] }.compact.uniq
        if component_indexes.size > 1
          bridge_methods << {
            name: method_name,
            component_count: component_indexes.size,
            states: touches.to_a.sort
          }
        end
      end

      {
        components: expanded_components.map do |component|
          {
            methods: component[:methods].uniq.sort,
            states: component[:states].uniq.sort
          }
        end.sort_by { |component| [-component[:methods].size, -component[:states].size, component[:methods].first.to_s] },
        bridge_methods: bridge_methods.sort_by { |bridge| [-bridge[:component_count], bridge[:name]] }
      }
    end

    def propagated_touches_for(fn, by_name, state_names, visiting = Set.new)
      name = fn[:name].to_s
      return Set.new if visiting.include?(name)

      visiting.add(name)
      touches = direct_state_touches(fn, state_names)
      internal_calls_for(fn).each do |callee_name|
        callee = by_name[callee_name.to_s]
        next unless callee

        touches.merge(propagated_touches_for(callee, by_name, state_names, visiting.dup))
      end
      touches
    end

    def direct_state_touches(fn, state_names)
      (effect_list(fn, :reads) + effect_list(fn, :writes))
        .map(&:to_s)
        .select { |name| state_names.include?(name) }
        .to_set
    end

    def internal_calls_for(fn)
      graph = fn[:CALL_GRAPH] || {}
      Array(graph[:internal_calls]).map(&:to_s)
    end

    def trivial_state_accessor?(fn, state_names)
      calls = calls_for(fn)
      return false unless calls.empty? && internal_calls_for(fn).empty?

      touches = direct_state_touches(fn, state_names)
      return false unless touches.size == 1

      method_name = fn[:name].to_s
      state_name = touches.first.delete_prefix("@")
      method_name == state_name ||
        method_name == "#{state_name}=" ||
        method_name == "#{state_name}?" ||
        method_name == "#{state_name}!"
    end

    def state_components(method_touches)
      adjacency = Hash.new { |hash, key| hash[key] = Set.new }
      method_touches.each do |method_name, state_names|
        method_node = "m:#{method_name}"
        state_names.each do |state_name|
          state_node = "s:#{state_name}"
          adjacency[method_node] << state_node
          adjacency[state_node] << method_node
        end
      end

      seen = Set.new
      components = []
      adjacency.keys.sort.each do |start|
        next if seen.include?(start)

        raw_component = connected_component(start, adjacency, seen)
        methods = raw_component.grep(/\Am:/).map { |name| name.delete_prefix("m:") }.sort
        states = raw_component.grep(/\As:/).map { |name| name.delete_prefix("s:") }.sort
        next if methods.empty?

        components << { methods: methods, states: states }
      end
      components.sort_by { |component| [-component[:methods].size, -component[:states].size, component[:methods].first.to_s] }
    end

    def connected_component(start, adjacency, seen)
      stack = [start]
      seen.add(start)
      component = []
      until stack.empty?
        current = stack.pop
        component << current
        adjacency[current].each do |neighbor|
          next if seen.include?(neighbor)

          seen.add(neighbor)
          stack << neighbor
        end
      end
      component
    end

    def cohesion_noise?(summary, method_count, components, fragmentation, isolated, bridge_methods)
      return true if summary[:data_carrier]
      return true if small_helper_object_facade?(method_count, components, bridge_methods)
      return true if method_count < 6 && fragmentation < 0.5 && bridge_methods.empty?
      return true if fragmentation < 0.18 && isolated >= components.size - 1 && bridge_methods.size <= 4
      return true if fragmentation < 0.18 && components.size < 4
      return true if isolated == components.size && summary[:delegations] <= method_count && bridge_methods.empty?
      false
    end

    def small_helper_object_facade?(method_count, components, bridge_methods)
      return false unless method_count <= 5 && components.size <= 3 && bridge_methods.size <= 2

      state_names = components.flat_map { |component| component[:states] }.uniq
      return false if state_names.empty?

      state_names.all? do |state_name|
        state_name.delete_prefix("@").match?(/(?:_store|_stack|_state|_tracker)\z/)
      end
    end

    def cohesion_score(component_count:, fragmentation:, isolated:, method_count:, state_count:, public_components:, bridge_count:)
      score = (component_count - 1) * 8.0
      score += fragmentation * 45.0
      score += isolated * 2.0
      score += method_count * 0.25
      score += state_count * 0.4
      score += public_components * 1.5
      score += [bridge_count, 5].min * 2.0
      score += 4.0 if bridge_count >= 10
      score
    end

    def public_component_count(components, mod)
      visibility_by_name = functions(mod).each_with_object({}) do |fn, out|
        out[fn[:name].to_s] = visibility_for(fn)
      end
      components.count do |component|
        component[:methods].any? { |method_name| visibility_by_name[method_name] == :public }
      end
    end

    def component_samples(components)
      components.first(5).map do |component|
        {
          methods: component[:methods].first(4),
          states: component[:states].first(4),
          method_count: component[:methods].size,
          state_count: component[:states].size
        }
      end
    end

    def cohesion_flags(components, fragmentation, isolated, bridge_methods)
      flags = []
      flags << "split-state-components" if components.size >= 3
      flags << "high-fragmentation" if fragmentation >= 0.5
      flags << "isolated-state-methods" if isolated >= 2
      flags << "orchestration-bridges" if bridge_methods.any?
      flags
    end

    def common_terms_for(owners)
      counts = Hash.new(0)
      owners.each do |owner|
        owner_tokens(owner).uniq.each { |token| counts[token] += 1 }
      end
      minimum = [2, (owners.size / 2.0).ceil].max
      counts.select { |token, count| count >= minimum && !TOKEN_STOP_WORDS.include?(token) }
            .sort_by { |token, count| [-count, token] }
            .map(&:first)
            .first(4)
    end

    def owner_tokens(owner)
      owner.split("::").flat_map do |segment|
        segment.scan(/[A-Z]+(?=[A-Z][a-z]|\b)|[A-Z]?[a-z]+|\d+/).map(&:downcase)
      end
    end

    def functions(mod)
      Array(mod[:functions])
    end

    def states(mod)
      Array(mod[:state])
    end

    def visibility_for(fn)
      (fn[:visibility] || :public).to_sym
    end

    def mutating_public_method?(fn)
      visibility_for(fn) == :public &&
        fn[:name].to_s != "initialize" &&
        effect_list(fn, :writes).any?
    end

    def state_touch_count(fn)
      effect_list(fn, :reads).size + effect_list(fn, :writes).size
    end

    def effect_list(fn, key)
      Array((fn[:EFFECTS] || {})[key])
    end

    def delegation_count(funcs)
      funcs.sum { |fn| calls_for(fn).size }
    end

    def round(value)
      (value.to_f * 100).round / 100.0
    end

    class Tarjan
      def initialize(adjacency)
        @adjacency = adjacency
        @index = 0
        @indices = {}
        @lowlink = {}
        @stack = []
        @on_stack = Set.new
        @components = []
      end

      def components
        @adjacency.keys.sort.each do |node|
          strong_connect(node) unless @indices.key?(node)
        end
        @components
      end

      private

      def strong_connect(node)
        @indices[node] = @index
        @lowlink[node] = @index
        @index += 1
        @stack << node
        @on_stack << node

        @adjacency[node].uniq.sort.each do |target|
          if !@indices.key?(target)
            strong_connect(target)
            @lowlink[node] = [@lowlink[node], @lowlink[target]].min
          elsif @on_stack.include?(target)
            @lowlink[node] = [@lowlink[node], @indices[target]].min
          end
        end

        return unless @lowlink[node] == @indices[node]

        component = []
        loop do
          target = @stack.pop
          @on_stack.delete(target)
          component << target
          break if target == node
        end
        @components << component.sort
      end
    end
  end
end
