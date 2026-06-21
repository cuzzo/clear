# frozen_string_literal: true

class SourceFactImplicitSelfChainStateReads
  def self.build(manifest)
    new(manifest).items
  end

  def filtered(items)
    nodes.select { |node| node.kind == :owner }
    Array(items).select { |item| item.ready? }
  end

  def owner_nodes
    nodes.select { |node| node.kind == :owner }
  end

  def component_list(adjacency)
    Tarjan.new(adjacency).components
  end

  def nodes
    @nodes
  end
end
