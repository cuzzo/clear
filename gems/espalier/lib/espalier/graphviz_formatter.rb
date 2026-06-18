# frozen_string_literal: true

module Espalier
  # Renders an Espalier::DependencyGraph as Graphviz DOT.
  class GraphvizFormatter
    GRAPH_ATTRIBUTES = {
      rankdir: "LR",
      compound: true,
      concentrate: true,
      fontsize: 12,
      fontname: "Arial",
      label: "Espalier Dependency Graph",
      labelloc: "t",
      nodesep: 0.35,
      ranksep: 0.75
    }.freeze

    NODE_ATTRIBUTES = {
      shape: "box",
      style: "rounded,filled",
      fillcolor: "#ffffff",
      color: "#6b7280",
      fontname: "Arial",
      fontsize: 10
    }.freeze

    EDGE_ATTRIBUTES = {
      color: "#4b5563",
      fontname: "Arial",
      fontsize: 9,
      arrowsize: 0.7
    }.freeze

    def initialize(graph)
      @graph = graph
    end

    def to_dot
      lines = []
      lines << "digraph espalier_dependencies {"
      lines << "  graph#{attributes(GRAPH_ATTRIBUTES)};"
      lines << "  node#{attributes(NODE_ATTRIBUTES)};"
      lines << "  edge#{attributes(EDGE_ATTRIBUTES)};"
      lines << ""
      owner_clusters.each do |owner, nodes|
        lines.concat(cluster_lines(owner, nodes))
      end
      external_nodes.each do |node|
        lines << "  #{quote(node.id)}#{attributes(node_attributes(node))};"
      end
      lines << ""
      @graph.edges.each do |edge|
        lines << "  #{quote(edge.source)} -> #{quote(edge.target)}#{attributes(edge_attributes(edge))};"
      end
      lines << "}"
      lines.join("\n")
    end

    private

    def owner_clusters
      @graph.owner_nodes.map(&:owner).sort.to_h do |owner|
        [owner, @graph.nodes_for_owner(owner)]
      end
    end

    def external_nodes
      @graph.nodes.select { |node| node.kind == :external }
    end

    def cluster_lines(owner, nodes)
      lines = []
      lines << "  subgraph #{quote(cluster_id(owner))} {"
      lines << "    label=#{quote(owner)};"
      lines << "    color=#{quote("#d1d5db")};"
      lines << "    style=#{quote("rounded")};"
      nodes.sort_by { |node| [node.kind == :owner ? 0 : 1, node.label.to_s] }.each do |node|
        lines << "    #{quote(node.id)}#{attributes(node_attributes(node))};"
      end
      lines << "  }"
      lines << ""
      lines
    end

    def cluster_id(owner)
      "cluster_#{owner.to_s.gsub(/[^A-Za-z0-9_]/, "_")}"
    end

    def node_attributes(node)
      attrs = case node.kind
              when :owner
                owner_node_attributes(node)
              when :function
                function_node_attributes(node)
              else
                external_node_attributes(node)
              end
      if @graph.cyclic_node_ids.include?(node.id)
        attrs = attrs.merge(color: "#b91c1c", penwidth: 2.0, fillcolor: cycle_fill(node))
      end
      attrs
    end

    def owner_node_attributes(node)
      metadata = node.metadata || {}
      details = []
      details << metadata[:type].to_s if metadata[:type]
      details << "#{metadata[:function_count]} fn"
      details << "#{metadata[:state_count]} state"
      {
        shape: "component",
        fillcolor: "#e0f2fe",
        color: "#0369a1",
        label: ([node.label] + details).join("\n"),
        tooltip: tooltip_for(node)
      }.merge(url_attribute(node))
    end

    def function_node_attributes(node)
      metadata = node.metadata || {}
      reads = Array(metadata[:reads]).size
      writes = Array(metadata[:writes]).size
      details = ["#{metadata[:visibility] || :public} R#{reads} W#{writes}"]
      details << "L#{node.line}" if node.line
      {
        shape: writes.positive? ? "box3d" : "box",
        fillcolor: writes.positive? ? "#fff7ed" : "#ffffff",
        color: writes.positive? ? "#c2410c" : "#6b7280",
        label: ([node.label] + details).join("\n"),
        tooltip: tooltip_for(node)
      }.merge(url_attribute(node))
    end

    def external_node_attributes(node)
      {
        shape: "box",
        style: "rounded,dashed,filled",
        fillcolor: "#f3f4f6",
        color: "#9ca3af",
        label: node.label,
        tooltip: tooltip_for(node)
      }
    end

    def edge_attributes(edge)
      attrs = {
        label: edge.weight && edge.weight > 1 ? "#{edge.label} x#{edge.weight}" : edge.label
      }.merge(edge_style(edge))

      source_component = @graph.cycle_component_by_node[edge.source]
      if source_component && source_component == @graph.cycle_component_by_node[edge.target]
        attrs = attrs.merge(color: "#b91c1c", penwidth: 2.0)
      end
      attrs
    end

    def edge_style(edge)
      case edge.kind
      when :state_type
        { color: "#7c3aed", style: "dotted", arrowhead: "vee" }
      when :internal_call
        { color: "#374151", style: edge.conditional ? "dashed" : "solid" }
      when :delegation
        { color: "#2563eb", style: edge.conditional ? "dashed" : "solid" }
      when :owner_call
        { color: "#0891b2", style: edge.conditional ? "dashed" : "solid" }
      when :external_call
        { color: "#9ca3af", style: edge.conditional ? "dashed" : "dotted" }
      else
        { color: "#4b5563", style: edge.conditional ? "dashed" : "solid" }
      end
    end

    def cycle_fill(node)
      node.kind == :owner ? "#fee2e2" : "#fff1f2"
    end

    def tooltip_for(node)
      parts = [node.label]
      parts << node.file if node.file
      parts << "line #{node.line}" if node.line
      if (signature = node.metadata && node.metadata[:signature])
        parts << signature
      end
      parts.join(" | ")
    end

    def url_attribute(node)
      return {} unless node.file

      url = node.file.to_s
      url += "#L#{node.line}" if node.line
      { URL: url }
    end

    def attributes(hash)
      return "" if hash.empty?

      " [" + hash.sort_by { |key, _value| key.to_s }.map { |key, value| "#{key}=#{dot_value(value)}" }.join(", ") + "]"
    end

    def dot_value(value)
      case value
      when true
        "true"
      when false
        "false"
      when Numeric
        value.to_s
      else
        quote(value)
      end
    end

    def quote(value)
      text = value.to_s
      text = text.gsub("\\", "\\\\\\\\")
                 .gsub("\"", "\\\"")
                 .gsub("\n", "\\n")
      "\"#{text}\""
    end
  end
end
