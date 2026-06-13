require "rspec"
require "set"

require_relative "../src/annotator/helpers/lock_helper" unless defined?(LockHelper::LockAnalysisState)

# Unit tests for the Tarjan SCC implementation in LockHelper. The whole
# Phase 2 cycle-detection story bottoms out on scc_is_cyclic? + tarjan_scc
# agreeing on which subgraphs are cyclic; we want direct coverage on
# synthetic graphs without going through the annotator pipeline so
# algorithm-level regressions show up as algorithm-level failures.
RSpec.describe LockHelper do
  # Host class so we can mix in the module without standing up the full
  # SemanticAnnotator. Only the SCC methods are exercised here.
  let(:host) {
    Class.new do
      include LockHelper
    end.new
  }

  def adj_from(edges)
    # edges: [[from, to], ...]. Nodes set is the union of endpoints.
    adj = Hash.new { |h, k| h[k] = Set.new }
    nodes = Set.new
    edges.each do |(from, to)|
      adj[from] << to
      nodes << from
      nodes << to
    end
    [nodes, adj]
  end

  describe "#tarjan_scc" do
    it "returns an empty array for an empty graph" do
      expect(host.send(:tarjan_scc, Set.new, Hash.new { |h, k| h[k] = Set.new })).to eq([])
    end

    it "returns a singleton SCC for each isolated node" do
      nodes, adj = adj_from([])
      # Populate with nodes that have no edges.
      nodes << :A
      nodes << :B
      nodes << :C
      sccs = host.send(:tarjan_scc, nodes, adj)
      expect(sccs.map(&:sort)).to match_array([[:A], [:B], [:C]])
    end

    it "returns a single SCC for a self-loop" do
      nodes, adj = adj_from([[:A, :A]])
      sccs = host.send(:tarjan_scc, nodes, adj)
      expect(sccs).to eq([[:A]])
    end

    it "returns three singletons for a DAG chain A->B->C" do
      nodes, adj = adj_from([[:A, :B], [:B, :C]])
      sccs = host.send(:tarjan_scc, nodes, adj)
      expect(sccs.map(&:sort)).to match_array([[:A], [:B], [:C]])
    end

    it "returns a single 2-node SCC for an AB/BA cycle" do
      nodes, adj = adj_from([[:A, :B], [:B, :A]])
      sccs = host.send(:tarjan_scc, nodes, adj)
      expect(sccs.length).to eq(1)
      expect(sccs.first.to_set).to eq(Set[:A, :B])
    end

    it "returns a single 3-node SCC for A->B->C->A" do
      nodes, adj = adj_from([[:A, :B], [:B, :C], [:C, :A]])
      sccs = host.send(:tarjan_scc, nodes, adj)
      expect(sccs.length).to eq(1)
      expect(sccs.first.to_set).to eq(Set[:A, :B, :C])
    end

    it "separates disjoint SCCs" do
      nodes, adj = adj_from([
        [:A, :B], [:B, :A],       # SCC {A, B}
        [:C, :D], [:D, :C],       # SCC {C, D}
        [:E, :F],                  # DAG {E -> F}
      ])
      sccs = host.send(:tarjan_scc, nodes, adj).map(&:to_set)
      expect(sccs).to include(Set[:A, :B])
      expect(sccs).to include(Set[:C, :D])
      expect(sccs).to include(Set[:E])
      expect(sccs).to include(Set[:F])
    end

    it "merges two cycles that share a node into one SCC" do
      # A <-> B and A <-> C share A: everything reaches everything.
      nodes, adj = adj_from([
        [:A, :B], [:B, :A],
        [:A, :C], [:C, :A],
      ])
      sccs = host.send(:tarjan_scc, nodes, adj)
      expect(sccs.length).to eq(1)
      expect(sccs.first.to_set).to eq(Set[:A, :B, :C])
    end

    it "handles a graph with a self-loop inside a larger DAG" do
      nodes, adj = adj_from([
        [:A, :B],
        [:B, :B],   # self-loop
        [:B, :C],
      ])
      sccs = host.send(:tarjan_scc, nodes, adj)
      scc_sets = sccs.map(&:to_set)
      expect(scc_sets).to include(Set[:A])
      expect(scc_sets).to include(Set[:B])
      expect(scc_sets).to include(Set[:C])
    end

    it "does not blow the stack on a long chain (iterative Tarjan sanity)" do
      # Guard against naive recursive Tarjan: a 10k-node chain DAG should
      # complete fine with the iterative work-list implementation.
      n = 10_000
      edges = (0...n - 1).map { |i| [i, i + 1] }
      nodes, adj = adj_from(edges)
      sccs = host.send(:tarjan_scc, nodes, adj)
      expect(sccs.length).to eq(n) # each node is its own singleton SCC
    end
  end

  describe "#scc_is_cyclic?" do
    it "flags a multi-node SCC as cyclic" do
      _, adj = adj_from([[:A, :B], [:B, :A]])
      expect(host.send(:scc_is_cyclic?, [:A, :B], adj)).to be true
    end

    it "flags a single-node SCC with a self-loop as cyclic" do
      _, adj = adj_from([[:A, :A]])
      expect(host.send(:scc_is_cyclic?, [:A], adj)).to be true
    end

    it "does not flag a single-node SCC without a self-loop as cyclic" do
      _, adj = adj_from([[:A, :B]])
      expect(host.send(:scc_is_cyclic?, [:A], adj)).to be false
    end
  end
end
