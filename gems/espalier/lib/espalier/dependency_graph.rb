# frozen_string_literal: true

require "set"

module Espalier
  # Builds a manifest-derived dependency graph without owning rendering.
  class DependencyGraph
    Node = Struct.new(:id, :kind, :label, :owner, :file, :line, :metadata, keyword_init: true)
    Edge = Struct.new(:source, :target, :kind, :label, :conditional, :weight, :metadata, keyword_init: true)

    CORE_TYPES = %w[
      Array BasicObject Boolean Class FalseClass Float Hash Integer NilClass
      Object Proc Set String Symbol T TrueClass
    ].freeze

    attr_reader :nodes_by_id, :edges_by_key

    def self.from_manifest(manifest, include_external: false)
      Builder.new(manifest, include_external: include_external).build
    end

    def self.owner_node_id(owner)
      "owner:#{owner}"
    end

    def self.function_node_id(owner, function_name)
      "fn:#{owner}##{function_name}"
    end

    def self.external_node_id(name)
      "external:#{name}"
    end

    def initialize
      @nodes_by_id = {}
      @edges_by_key = {}
    end

    def add_node(node)
      @nodes_by_id[node.id] ||= node
    end

    def add_edge(edge)
      edge.weight ||= 1
      edge.conditional = !!edge.conditional
      key = [edge.source, edge.target, edge.kind, edge.label, edge.conditional]
      existing = @edges_by_key[key]
      if existing
        existing.weight += edge.weight
      else
        @edges_by_key[key] = edge
      end
    end

    def nodes
      @nodes_by_id.values.sort_by { |node| [node.kind.to_s, node.owner.to_s, node.id] }
    end

    def edges
      @edges_by_key.values.sort_by do |edge|
        [edge.source, edge.target, edge.kind.to_s, edge.label.to_s, edge.conditional ? 1 : 0]
      end
    end

    def owner_nodes
      nodes.select { |node| node.kind == :owner }
    end

    def function_nodes
      nodes.select { |node| node.kind == :function }
    end

    def nodes_for_owner(owner)
      nodes.select { |node| node.owner == owner && node.kind != :external }
    end

    def cyclic_node_ids
      @cyclic_node_ids ||= begin
        cyclic = Set.new
        strongly_connected_components.each do |component|
          next if component.size <= 1

          component.each { |node_id| cyclic << node_id }
        end
        edges.each { |edge| cyclic << edge.source if edge.source == edge.target }
        cyclic
      end
    end

    def cycle_component_by_node
      @cycle_component_by_node ||= begin
        out = {}
        strongly_connected_components.each_with_index do |component, index|
          next if component.size <= 1

          component.each { |node_id| out[node_id] = index }
        end
        out
      end
    end

    private

    def strongly_connected_components
      @strongly_connected_components ||= begin
        index = 0
        stack = []
        indices = {}
        lowlinks = {}
        on_stack = Set.new
        components = []
        adjacency = edges.each_with_object(Hash.new { |h, k| h[k] = [] }) do |edge, out|
          out[edge.source] << edge.target
        end

        visit = lambda do |node_id|
          indices[node_id] = index
          lowlinks[node_id] = index
          index += 1
          stack << node_id
          on_stack << node_id

          adjacency[node_id].each do |target|
            if !indices.key?(target)
              visit.call(target)
              lowlinks[node_id] = [lowlinks[node_id], lowlinks[target]].min
            elsif on_stack.include?(target)
              lowlinks[node_id] = [lowlinks[node_id], indices[target]].min
            end
          end

          return unless lowlinks[node_id] == indices[node_id]

          component = []
          loop do
            member = stack.pop
            on_stack.delete(member)
            component << member
            break if member == node_id
          end
          components << component.sort
        end

        @nodes_by_id.each_key { |node_id| visit.call(node_id) unless indices.key?(node_id) }
        components
      end
    end

    class Builder
      def initialize(manifest, include_external:)
        @manifest = Array(manifest)
        @include_external = include_external
        @graph = DependencyGraph.new
        @owners = Set.new
        @owner_by_simple = {}
        @functions_by_owner = Hash.new { |h, k| h[k] = Set.new }
        @state_types_by_owner = Hash.new { |h, k| h[k] = {} }
      end

      def build
        index_manifest
        add_nodes
        add_state_type_edges
        add_internal_call_edges
        add_delegation_edges
        @graph
      end

      private

      def index_manifest
        @manifest.each do |mod|
          owner = value(mod, :module).to_s
          next if owner.empty?

          @owners << owner
          functions(mod).each { |fn| @functions_by_owner[owner] << value(fn, :name).to_s }
          @state_types_by_owner[owner] = state_type_index(mod)
        end

        grouped = @owners.group_by { |owner| owner.split("::").last }
        @owner_by_simple = grouped.each_with_object({}) do |(simple, owners), out|
          out[simple] = owners.first if owners.size == 1
        end
      end

      def add_nodes
        @manifest.each do |mod|
          owner = value(mod, :module).to_s
          next if owner.empty?

          @graph.add_node(owner_node(mod, owner))
          functions(mod).each do |fn|
            name = value(fn, :name).to_s
            next if name.empty?

            @graph.add_node(function_node(mod, fn, owner, name))
          end
        end
      end

      def owner_node(mod, owner)
        Node.new(
          id: DependencyGraph.owner_node_id(owner),
          kind: :owner,
          label: owner,
          owner: owner,
          file: value(mod, :file),
          line: value(mod, :line),
          metadata: {
            type: value(mod, :type),
            language: value(mod, :language),
            function_count: functions(mod).size,
            state_count: states(mod).size
          }
        )
      end

      def function_node(mod, fn, owner, name)
        effects = value(fn, :EFFECTS) || {}
        Node.new(
          id: DependencyGraph.function_node_id(owner, name),
          kind: :function,
          label: name,
          owner: owner,
          file: value(mod, :file),
          line: value(fn, :line),
          metadata: {
            visibility: value(fn, :visibility) || :public,
            signature: value(fn, :signature),
            reads: Array(value(effects, :reads)),
            writes: Array(value(effects, :writes))
          }
        )
      end

      def add_state_type_edges
        @manifest.each do |mod|
          source_owner = value(mod, :module).to_s
          states(mod).each do |state|
            target_owner = owner_for_type(value(state, :type))
            next unless target_owner
            next if target_owner == source_owner

            @graph.add_edge(
              Edge.new(
                source: DependencyGraph.owner_node_id(source_owner),
                target: DependencyGraph.owner_node_id(target_owner),
                kind: :state_type,
                label: "state #{value(state, :name)}",
                conditional: false,
                weight: 1,
                metadata: { state: value(state, :name) }
              )
            )
          end
        end
      end

      def add_internal_call_edges
        @manifest.each do |mod|
          owner = value(mod, :module).to_s
          graph = value(mod, :call_graph) || {}
          Array(value(graph, :internal_edges)).each do |edge|
            caller = value(edge, :caller).to_s
            callee = value(edge, :callee).to_s
            next unless function?(owner, caller) && function?(owner, callee)

            conditional = value(edge, :type).to_s == "conditional"
            add_call_edge(
              source_owner: owner,
              source_function: caller,
              target_id: DependencyGraph.function_node_id(owner, callee),
              kind: :internal_call,
              label: conditional ? "conditional internal" : "internal",
              conditional: conditional
            )
          end
        end
      end

      def add_delegation_edges
        @manifest.each do |mod|
          owner = value(mod, :module).to_s
          functions(mod).each do |fn|
            source_function = value(fn, :name).to_s
            delegation_calls(fn).each do |call|
              target = target_for_call(owner, call[:name])
              next unless target

              add_call_edge(
                source_owner: owner,
                source_function: source_function,
                target_id: target[:id],
                kind: target[:kind],
                label: target[:kind] == :internal_call ? internal_label(call[:conditional]) : call_label(call[:name], call[:conditional], target[:method]),
                conditional: call[:conditional],
                metadata: { call: call[:name] }
              )
            end
          end
        end
      end

      def add_call_edge(source_owner:, source_function:, target_id:, kind:, label:, conditional:, metadata: {})
        source_id = DependencyGraph.function_node_id(source_owner, source_function)
        return unless @graph.nodes_by_id.key?(source_id)
        return unless @graph.nodes_by_id.key?(target_id)

        @graph.add_edge(
          Edge.new(
            source: source_id,
            target: target_id,
            kind: kind,
            label: label,
            conditional: conditional,
            weight: 1,
            metadata: metadata
          )
        )
      end

      def delegation_calls(fn)
        delegations = value(fn, :DELEGATIONS) || {}
        always = Array(value(delegations, :always_calls)).map do |name|
          { name: name.to_s, conditional: false }
        end
        conditional = Array(value(delegations, :conditionally_calls)).map do |name|
          { name: name.to_s, conditional: true }
        end
        always + conditional
      end

      def target_for_call(source_owner, call_name)
        if function?(source_owner, call_name)
          return {
            id: DependencyGraph.function_node_id(source_owner, call_name),
            kind: :internal_call,
            method: call_name
          }
        end

        receiver = receiver_for(call_name)
        return nil unless receiver

        method = method_for(call_name)
        target_owner = owner_for_receiver(source_owner, receiver)
        if target_owner
          if method && function?(target_owner, method)
            return {
              id: DependencyGraph.function_node_id(target_owner, method),
              kind: :delegation,
              method: method
            }
          end

          return {
            id: DependencyGraph.owner_node_id(target_owner),
            kind: :owner_call,
            method: method
          }
        end

        external_target(receiver, method)
      end

      def external_target(receiver, method)
        return nil unless @include_external
        return nil unless receiver.match?(/\A[A-Z]/)

        id = DependencyGraph.external_node_id(receiver)
        @graph.add_node(
          Node.new(
            id: id,
            kind: :external,
            label: receiver,
            owner: nil,
            file: nil,
            line: nil,
            metadata: { method: method }
          )
        )
        { id: id, kind: :external_call, method: method }
      end

      def owner_for_receiver(source_owner, receiver)
        return nil if receiver == "self" || receiver == "this"
        return source_owner if receiver == source_owner

        state_type = state_type_for(source_owner, receiver)
        return owner_for_type(state_type) if state_type

        return nil unless receiver.match?(/\A[A-Z]/)

        owner_for_type(receiver)
      end

      def state_type_for(owner, receiver)
        state_types = @state_types_by_owner[owner]
        return state_types[receiver] if state_types.key?(receiver)

        if receiver.start_with?("@")
          state_name = receiver.split(".").first
          return state_types[state_name]
        end

        if receiver.start_with?("self.", "this.")
          field = receiver.split(".")[1]
          return state_types[field] || state_types["@#{field}"]
        end

        nil
      end

      def call_label(call_name, conditional, method)
        label = method ? "calls #{method}" : "calls"
        conditional ? "conditional #{label}" : label
      end

      def internal_label(conditional)
        conditional ? "conditional internal" : "internal"
      end

      def receiver_for(call_name)
        return nil unless call_name.include?(".")

        parts = call_name.split(".")
        parts[0...-1].join(".")
      end

      def method_for(call_name)
        return nil unless call_name.include?(".")

        call_name.split(".").last
      end

      def function?(owner, function_name)
        @functions_by_owner[owner].include?(function_name.to_s)
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
          state_name = value(state, :name).to_s
          type = value(state, :type)
          out[state_name] = type.to_s if type && !type.to_s.empty?
        end
      end

      def functions(mod)
        Array(value(mod, :functions))
      end

      def states(mod)
        Array(value(mod, :state))
      end

      def value(hash, key)
        return nil unless hash.respond_to?(:[])

        hash[key] || hash[key.to_s]
      end
    end
  end
end
