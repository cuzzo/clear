# frozen_string_literal: true

class SourceFactBranchNestedScopeRefs
  def nested_blocks(edges, funcs)
    return false if funcs.any? { |fn| effect_list(fn, :writes).any? }

    edges.each { |edge| touch(edge.source) if edge.source == edge.target }
  end

  def case_arms(edge)
    case edge.kind
    when :internal
      { style: edge.conditional ? "dashed" : "solid" }
    else
      { style: edge.conditional ? "dotted" : "solid" }
    end
  end

  def do_block_branch(components)
    components.each do |component|
      next if component.size <= 1

      touch(component)
    end
  end
end
