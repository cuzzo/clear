# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/architecture_analyzer"

class ArchitectureAnalyzerCovTest < Minitest::Test
  def test_class_methods
    modules = [
      {
        module: "Hub", privacy: "public", properties: ["stateful"],
        edges: [
          { target: "C1", count: 2, conditional_count: 0, public_target: false, stateful: true },
          { target: "C2", count: 2, conditional_count: 0, public_target: false, stateful: true },
          { target: "C3", count: 2, conditional_count: 0, public_target: false, stateful: true },
          { target: "C4", count: 2, conditional_count: 0, public_target: false, stateful: true },
          { target: "C5", count: 2, conditional_count: 0, public_target: false, stateful: true },
          { target: "C6", count: 2, conditional_count: 0, public_target: false, stateful: true }
        ]
      },
      { module: "C1", privacy: "public", properties: [], edges: [{ target: "C2", count: 1, conditional_count: 0, public_target: false, stateful: false }] },
      { module: "C2", privacy: "public", properties: [], edges: [{ target: "C3", count: 1, conditional_count: 0, public_target: false, stateful: false }] },
      { module: "C3", privacy: "public", properties: [], edges: [{ target: "C1", count: 1, conditional_count: 0, public_target: false, stateful: false }] },
      { module: "C4", privacy: "public", properties: [], edges: [] },
      { module: "C5", privacy: "public", properties: [], edges: [] },
      { module: "C6", privacy: "public", properties: [], edges: [] }
    ]

    assert Espalier::ArchitectureAnalyzer.encapsulation_pressure(modules, threshold: 0)
    assert Espalier::ArchitectureAnalyzer.collaboration_meshes(modules, threshold: 0)
    assert Espalier::ArchitectureAnalyzer.mediator_candidates(modules, threshold: 0)
    assert Espalier::ArchitectureAnalyzer.owner_state_cohesion(modules, threshold: 0)
    assert Espalier::ArchitectureAnalyzer.cohesive_value_facade_profiles(modules)
    
    analyzer = Espalier::ArchitectureAnalyzer.new(modules)
    row = analyzer.send(:mesh_row, kind: :dense_cycle, owners: ["A", "B"], driver: "A", edges: [{source: "A", target: "B", count: 1, stateful_count: 1, conditional_count: 1}], fan_out: 1)
    assert row
    
    score = analyzer.send(:mesh_score, kind: :dense_cycle, node_count: 2, edge_count: 1, total_calls: 1, density: 0.5, bidirectional_pairs: 0, fan_out: 1, stateful_calls: 1, conditional_calls: 1)
    assert score
    
    labels = analyzer.send(:top_edge_labels, [{source: "A", target: "B", count: 1}])
    assert_equal ["A -> B (1)"], labels
    
    internal = analyzer.send(:internal_edges_for, ["A"])
    assert_equal [], internal
    
    bidir = analyzer.send(:bidirectional_pair_count, ["A", "B"])
    assert_equal 0, bidir
  end
end
