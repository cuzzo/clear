require "rspec"
require "set"
require "timeout"

require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)

# Unit tests for the Tarjan SCC implementation in LockHelper. The whole
# Phase 2 cycle-detection story bottoms out on scc_is_cyclic? + tarjan_scc
# agreeing on which subgraphs are cyclic; we want direct coverage on
# synthetic graphs without going through the annotator pipeline so
# algorithm-level regressions show up as algorithm-level failures.
RSpec.describe LockHelper do
  TARJAN_SANITY_TIMEOUT_SECONDS = ENV["NIL_KILL_TRACE"] == "1" ? 60.0 : 5.0
  TARJAN_SANITY_CHAIN_LENGTH = ENV["NIL_KILL_TRACE"] == "1" ? 2_500 : 10_000

  class LockHelperSpecError < StandardError
    attr_reader :node, :code, :payload

    def initialize(node, code, payload)
      super(code.to_s)
      @node = node
      @code = code
      @payload = payload
    end
  end

  # Host class so we can mix in the module without standing up the full
  # SemanticAnnotator. Only the SCC methods are exercised here.
  let(:host) {
    Class.new do
      include LockHelper

      attr_reader :phase_receiver_state, :errors, :notes
      attr_accessor :function_call_graph, :held_locks, :held_lock_types

      def initialize
        @phase_receiver_state = SemanticAnnotator::ReceiverState.new
        @function_call_graph = {}
        @held_locks = {}
        @held_lock_types = []
        @errors = []
        @notes = []
      end

      def current_held_locks = @held_locks

      def current_held_lock_types = @held_lock_types

      def semantic_program = :program

      def error!(node, code, **payload)
        @errors << [node, code, payload]
        raise LockHelperSpecError.new(node, code, payload)
      end

      def note!(node, message)
        @notes << [node, message]
      end
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

  def run_tarjan(host, nodes, adj)
    Timeout.timeout(TARJAN_SANITY_TIMEOUT_SECONDS) { host.send(:tarjan_scc, nodes, adj) }
  end

  def token(line = 1, column = 1, value = "x")
    Lexer::Token.new(:IDENT, value, line, column)
  end

  def identifier(name, line = 1)
    AST::Identifier.new(token(line, 1, name), name)
  end

  def with_block(line: 1, clause: nil, snapshot_mode: nil, plan: nil)
    node = AST::WithBlock.new(token(line), [], [], [], plan || CapabilityPlan::WithCapabilityPlan.new)
    node.lock_error_clause = clause
    node.snapshot_mode = snapshot_mode
    node
  end

  def selector(form, name, line = 1)
    AST::ErrorSelector.new(form: form, name: name, token: token(line, 1, name.to_s))
  end

  def error_clause(*selectors)
    action = AST::ErrorAction.new(action: AST::ErrorActionKind::Return, token: token, value: nil, message: nil, body: [])
    AST::ErrorClause.from_action(selectors: selectors, retries: nil, action: action)
  end

  def cap_fact(name: "lock", type: :LockA, capability: :EXCLUSIVE, line: 1, guard: nil)
    var_node = identifier(name, line)
    source = AST::Capability.new(
      capability: capability,
      var_node: var_node,
      alias: nil,
      alias_mutable: false,
      guard_expr: guard
    )
    request = CapabilityPlan::CapabilityRequest.from_ast(source)
    target = CapabilityPlan::CapabilityTargetFact.new(
      var_node: var_node,
      var_name: name,
      target_label: name,
      field_target: false,
      index_target: false,
      resolved_type: Type.new(type),
      old_scope: nil,
      source_entry: nil,
      source_type: Type.new(type),
      sync: :locked,
      storage: nil,
      layout: nil,
      live_symbol_refreshed: false
    )
    CapabilityPlan.transition_from(request, target, nil)
  end

  def cap_fact_with_entry(name: "lock", type: :LockA, capability: :SNAPSHOT, entry:)
    var_node = identifier(name)
    source = AST::Capability.new(
      capability: capability,
      var_node: var_node,
      alias: nil,
      alias_mutable: false,
      guard_expr: nil
    )
    request = CapabilityPlan::CapabilityRequest.from_ast(source)
    target = CapabilityPlan::CapabilityTargetFact.new(
      var_node: var_node,
      var_name: name,
      target_label: name,
      field_target: false,
      index_target: false,
      resolved_type: Type.new(type),
      old_scope: nil,
      source_entry: entry,
      source_type: Type.new(type),
      sync: entry.sync,
      storage: entry.storage,
      layout: entry.layout,
      live_symbol_refreshed: true
    )
    CapabilityPlan.transition_from(request, target, nil)
  end

  def held_type(type, opted_out: false)
    SemanticAnnotator::HeldLockTypeEntry.new(type: type, opted_out: opted_out)
  end

  def held_lock(line = 1)
    SemanticAnnotator::HeldLockEntry.new(token: token(line))
  end

  describe "#tarjan_scc" do
    it "returns an empty array for an empty graph" do
      expect(run_tarjan(host, Set.new, Hash.new { |h, k| h[k] = Set.new })).to eq([])
    end

    it "returns a singleton SCC for each isolated node" do
      nodes, adj = adj_from([])
      # Populate with nodes that have no edges.
      nodes << :A
      nodes << :B
      nodes << :C
      sccs = run_tarjan(host, nodes, adj)
      expect(sccs.map(&:sort)).to match_array([[:A], [:B], [:C]])
    end

    it "returns a single SCC for a self-loop" do
      nodes, adj = adj_from([[:A, :A]])
      sccs = run_tarjan(host, nodes, adj)
      expect(sccs).to eq([[:A]])
    end

    it "returns three singletons for a DAG chain A->B->C" do
      nodes, adj = adj_from([[:A, :B], [:B, :C]])
      sccs = run_tarjan(host, nodes, adj)
      expect(sccs.map(&:sort)).to match_array([[:A], [:B], [:C]])
    end

    it "returns a single 2-node SCC for an AB/BA cycle" do
      nodes, adj = adj_from([[:A, :B], [:B, :A]])
      sccs = run_tarjan(host, nodes, adj)
      expect(sccs.length).to eq(1)
      expect(sccs.first.to_set).to eq(Set[:A, :B])
    end

    it "returns a single 3-node SCC for A->B->C->A" do
      nodes, adj = adj_from([[:A, :B], [:B, :C], [:C, :A]])
      sccs = run_tarjan(host, nodes, adj)
      expect(sccs.length).to eq(1)
      expect(sccs.first.to_set).to eq(Set[:A, :B, :C])
    end

    it "separates disjoint SCCs" do
      nodes, adj = adj_from([
        [:A, :B], [:B, :A],       # SCC {A, B}
        [:C, :D], [:D, :C],       # SCC {C, D}
        [:E, :F],                  # DAG {E -> F}
      ])
      sccs = run_tarjan(host, nodes, adj).map(&:to_set)
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
      sccs = run_tarjan(host, nodes, adj)
      expect(sccs.length).to eq(1)
      expect(sccs.first.to_set).to eq(Set[:A, :B, :C])
    end

    it "handles a graph with a self-loop inside a larger DAG" do
      nodes, adj = adj_from([
        [:A, :B],
        [:B, :B],   # self-loop
        [:B, :C],
      ])
      sccs = run_tarjan(host, nodes, adj)
      scc_sets = sccs.map(&:to_set)
      expect(scc_sets).to include(Set[:A])
      expect(scc_sets).to include(Set[:B])
      expect(scc_sets).to include(Set[:C])
    end

    it "returns each member once for a diamond-shaped SCC" do
      nodes, adj = adj_from([
        [:A, :D],
        [:D, :B],
        [:D, :C],
        [:B, :A],
        [:C, :A],
      ])

      scc = run_tarjan(host, nodes, adj).find { |component| component.to_set == Set[:A, :B, :C, :D] }
      expect(scc).not_to be_nil
      expect(T.must(scc).length).to eq(4)
    end

    it "does not blow the stack on a long chain (iterative Tarjan sanity)" do
      # Guard against naive recursive Tarjan: a 10k-node chain DAG should
      # complete fine with the iterative work-list implementation. nil-kill
      # tracing hooks the hot T.let path, so keep the traced collect variant
      # large enough to exercise iteration without turning collection into a
      # timeout test.
      n = TARJAN_SANITY_CHAIN_LENGTH
      chain_nodes = (0...n).map { |i| :"N#{i}" }
      edges = (0...n - 1).map { |i| [chain_nodes.fetch(i), chain_nodes.fetch(i + 1)] }
      nodes, adj = adj_from(edges)
      sccs = run_tarjan(host, nodes, adj)
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

  describe "lock rank bookkeeping" do
    it "records the first rank and rejects conflicting declarations" do
      wrap = AST::CapabilityWrap.new(token, identifier("value"), nil, :locked, nil)

      host.record_lock_type_rank!(:Counter, 10, wrap)
      expect(host.phase_receiver_state.lock_analysis.type_ranks).to eq(Counter: 10)
      host.record_lock_type_rank!(:Counter, 10, wrap)

      expect {
        host.record_lock_type_rank!(:Counter, 11, wrap)
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:LOCK_RANK_INCONSISTENT)
        expect(err.payload).to include(type: :Counter, previous: 10, rank: 11)
      }
    end

    it "returns nil for unranked capabilities and rank for ranked capabilities" do
      cap = cap_fact(type: :Counter)
      expect(host.send(:rank_of_cap, cap)).to be_nil

      host.phase_receiver_state.lock_analysis.type_ranks[:Counter] = 7
      expect(host.send(:rank_of_cap, cap)).to eq(7)
    end
  end

  describe "lexical and rank checks" do
    it "rejects same-name nested re-acquires unless the WITH opts out" do
      cap = cap_fact(name: "counter", line: 5)
      node = with_block(line: 5)
      host.held_locks = { "counter" => held_lock(2) }

      expect {
        host.check_nested_lock_reacquire!(node, [cap])
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:LOCK_NESTED_REACQUIRE)
        expect(err.payload).to include(name: "counter", outer_line: 2)
      }

      node.deadlock_escape = { kind: :deadlock, token: token(5) }
      expect { host.check_nested_lock_reacquire!(node, [cap]) }.not_to raise_error
      expect(host.notes.last[1]).to include("POSSIBLE_DEADLOCK accepted")
    end

    it "rejects non-ascending ranked acquires and allows ascending acquires" do
      node = with_block
      host.phase_receiver_state.lock_analysis.type_ranks.merge!(Outer: 10, Inner: 11, Lower: 9)
      host.held_lock_types = [held_type(:Outer)]

      expect { host.check_lock_rank_ordering!(node, [cap_fact(type: :Inner)]) }.not_to raise_error

      expect {
        host.check_lock_rank_ordering!(node, [cap_fact(type: :Lower)])
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:LOCK_RANK_VIOLATION)
        expect(err.payload).to include(cap: :Lower, cap_rank: 9, held: :Outer, held_rank: 10)
      }
    end

    it "downgrades ranked acquire violations to notes when explicitly opted out" do
      node = with_block
      node.deadlock_escape = { kind: :lock_cycle, token: token }
      host.phase_receiver_state.lock_analysis.type_ranks.merge!(Outer: 10, Lower: 9)
      host.held_lock_types = [held_type(:Outer)]

      expect { host.check_lock_rank_ordering!(node, [cap_fact(type: :Lower)]) }.not_to raise_error
      expect(host.notes.last[1]).to include("POSSIBLE_LOCK_CYCLE accepted")
    end
  end

  describe "lock graph collection" do
    it "records acquired lock types and direct held-to-acquired edges" do
      cap = cap_fact(type: :Inner)
      host.record_with_acquire!("fn", cap, [held_type(:Outer)], nil)

      state = host.phase_receiver_state.lock_analysis
      expect(state.direct_acquires["fn"]).to eq(Set[:Inner])
      edge = state.direct_edges["fn"].first
      expect(edge.held).to eq(:Outer)
      expect(edge.acquired).to eq(:Inner)
      expect(edge.opted_out).to be(false)
      expect(edge.fn_name).to eq("fn")
    end

    it "marks direct edges opted out when either holder or acquirer opted out" do
      cap = cap_fact(type: :Inner)
      host.record_with_acquire!("outer_opted", cap, [held_type(:Outer, opted_out: true)], nil)
      host.record_with_acquire!("inner_opted", cap, [held_type(:Outer)], { kind: :deadlock, token: token })

      state = host.phase_receiver_state.lock_analysis
      expect(state.direct_edges["outer_opted"].first.opted_out).to be(true)
      expect(state.direct_edges["inner_opted"].first.opted_out).to be(true)
    end

    it "records held call sites and resolves them through transitive callee acquires" do
      host.record_held_call!("caller", "callee", [held_type(:Outer)], token(8))
      host.send(:resolve_held_calls!, { "callee" => Set[:Inner, :Other] })

      edges = host.phase_receiver_state.lock_analysis.direct_edges["caller"]
      expect(edges.map { |edge| [edge.held, edge.acquired, edge.fn_name] })
        .to match_array([[:Outer, :Inner, "caller"], [:Outer, :Other, "caller"]])
      expect(edges.map { |edge| edge.site_token.line }).to eq([8, 8])
    end

    it "propagates lock acquires through the function call graph to a fixed point" do
      state = host.phase_receiver_state.lock_analysis
      state.direct_acquires["leaf"] << :LeafLock
      state.direct_acquires["middle"] << :MiddleLock
      host.function_call_graph = {
        "root" => Set["middle"],
        "middle" => Set["leaf"],
        "leaf" => Set.new,
      }

      expect(host.send(:propagate_lock_acquires!)).to include(
        "root" => Set[:LeafLock, :MiddleLock],
        "middle" => Set[:LeafLock, :MiddleLock],
        "leaf" => Set[:LeafLock]
      )
    end

    it "filters opted-out edges from the normal cycle graph but keeps them for reachability" do
      state = host.phase_receiver_state.lock_analysis
      state.direct_edges["fn"] << LockHelper::LockEdge.new(
        held: :A, acquired: :B, site_token: token, fn_name: "fn", opted_out: false
      )
      state.direct_edges["fn"] << LockHelper::LockEdge.new(
        held: :B, acquired: :A, site_token: token, fn_name: "fn", opted_out: true
      )

      normal = host.send(:build_lock_graph, include_opted_out: false)
      full = host.send(:build_lock_graph, include_opted_out: true)
      expect(normal.edges.length).to eq(1)
      expect(normal.adj).to include(A: Set[:B])
      expect(full.edges.length).to eq(2)
      expect(full.adj[:B]).to eq(Set[:A])
    end

    it "raises a cycle diagnostic with participating site details" do
      edges = [
        LockHelper::LockEdge.new(held: :A, acquired: :B, site_token: token(3), fn_name: "a", opted_out: false),
        LockHelper::LockEdge.new(held: :B, acquired: :A, site_token: token(4), fn_name: "b", opted_out: false),
      ]

      expect {
        host.send(:report_lock_cycle!, [:A, :B], edges)
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:LOCK_CYCLE_DETECTED)
        expect(err.node.line).to eq(3)
        expect(err.payload[:types]).to include(":A", ":B")
        expect(err.payload[:sites]).to include("a (line 3)", "b (line 4)")
      }
    end

    it "runs the complete cycle post-pass through held calls and reports cycles" do
      state = host.phase_receiver_state.lock_analysis
      state.direct_acquires["callee"] << :B
      state.direct_edges["caller"] << LockHelper::LockEdge.new(
        held: :B, acquired: :A, site_token: token(6), fn_name: "caller", opted_out: false
      )
      state.held_calls["caller"] << LockHelper::LockHeldCallSite.new(
        held: :A, callee: "callee", site_token: token(5), opted_out: false
      )
      host.function_call_graph = { "caller" => Set["callee"], "callee" => Set.new }

      expect {
        host.check_lock_cycles!
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:LOCK_CYCLE_DETECTED)
        expect(err.payload[:sites]).to include("caller")
      }
    end
  end

  describe "lock handler reachability" do
    it "records clause sites only for WITH blocks that have handlers" do
      cap = cap_fact(type: :Counter)
      host.record_lock_clause_site!(with_block(clause: nil), [cap])
      expect(host.phase_receiver_state.lock_analysis.clause_sites).to eq([])

      node = with_block(clause: error_clause(selector(:type, :LockTimeout)))
      host.record_lock_clause_site!(node, [cap])
      site = host.phase_receiver_state.lock_analysis.clause_sites.fetch(0)
      expect(site.node).to equal(node)
      expect(site.cap_types).to eq([:Counter])
    end

    it "accepts timeout and cycle handlers that are possible for a WITH site" do
      node = with_block(clause: error_clause(selector(:type, :LockTimeout), selector(:type, :LockCycle)))
      site = LockHelper::LockClauseSite.new(node: node, cap_types: [:Counter])

      expect {
        host.send(:verify_handler_reachability!, site, Set[:Counter], Set.new)
      }.not_to raise_error
    end

    it "returns immediately for WITH blocks without a handler clause" do
      node = with_block(clause: nil)
      site = LockHelper::LockClauseSite.new(node: node, cap_types: [:Counter])

      expect {
        host.send(:verify_handler_reachability!, site, Set[:Counter], Set[:Counter])
      }.not_to raise_error
      expect(host.errors).to eq([])
    end

    it "rejects dead handlers that cannot be reached by the WITH site" do
      node = with_block(clause: error_clause(selector(:type, :Deadlock)))
      site = LockHelper::LockClauseSite.new(node: node, cap_types: [:Counter])

      expect {
        host.send(:verify_handler_reachability!, site, Set[:Other], Set.new)
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:SELECTOR_NOT_POSSIBLE)
        expect(err.payload).to eq(label: "Deadlock")
      }
    end

    it "treats guarded capabilities as GuardFail-reachable" do
      guarded_plan = CapabilityPlan::WithCapabilityPlan.new
      guarded_plan.add(cap_fact(type: :Counter, guard: identifier("ok")))
      node = with_block(clause: error_clause(selector(:type, :GuardFail)), plan: guarded_plan)
      site = LockHelper::LockClauseSite.new(node: node, cap_types: [])

      expect {
        host.send(:verify_handler_reachability!, site, Set.new, Set.new)
      }.not_to raise_error
    end

    it "narrows snapshot transaction handlers to MVCC/atomic conflict families" do
      node = with_block(
        clause: error_clause(selector(:type, :MvccConflict), selector(:type, :LockTimeout)),
        snapshot_mode: :transaction
      )
      site = LockHelper::LockClauseSite.new(node: node, cap_types: [:Counter])

      expect {
        host.send(:verify_handler_reachability!, site, Set[:Counter], Set.new)
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:SELECTOR_NOT_POSSIBLE)
        expect(err.payload).to eq(label: "LockTimeout")
      }
    end

    it "recognizes atomic-pointer snapshot transactions as AtomicConflict" do
      entry = SymbolEntry.new(
        reg: "cell",
        type: :Counter,
        mutable: true,
        storage: :heap,
        sync: :atomic,
        layout: :indirect
      )
      plan = CapabilityPlan::WithCapabilityPlan.new
      plan.add(cap_fact_with_entry(entry: entry))
      node = with_block(
        clause: error_clause(selector(:type, :AtomicConflict), selector(:type, :MvccConflict)),
        snapshot_mode: :transaction,
        plan: plan
      )
      site = LockHelper::LockClauseSite.new(node: node, cap_types: [:Counter])

      expect {
        host.send(:verify_handler_reachability!, site, Set.new, Set.new)
      }.to raise_error(LockHelperSpecError) { |err|
        expect(err.code).to eq(:SELECTOR_NOT_POSSIBLE)
        expect(err.payload).to eq(label: "MvccConflict")
      }
    end

    it "derives LockCycle reachability from multi-node SCCs in the full graph" do
      node = with_block(clause: error_clause(selector(:type, :LockCycle)))
      host.phase_receiver_state.lock_analysis.clause_sites << LockHelper::LockClauseSite.new(
        node: node,
        cap_types: [:A]
      )
      host.phase_receiver_state.lock_analysis.direct_edges["a"] << LockHelper::LockEdge.new(
        held: :A,
        acquired: :B,
        site_token: token(3),
        fn_name: "a",
        opted_out: false
      )
      host.phase_receiver_state.lock_analysis.direct_edges["b"] << LockHelper::LockEdge.new(
        held: :B,
        acquired: :A,
        site_token: token(4),
        fn_name: "b",
        opted_out: false
      )

      expect { host.send(:check_lock_handler_reachability!) }.not_to raise_error
    end

    it "derives Deadlock reachability from self-loop SCCs" do
      node = with_block(clause: error_clause(selector(:type, :Deadlock)))
      host.phase_receiver_state.lock_analysis.clause_sites << LockHelper::LockClauseSite.new(
        node: node,
        cap_types: [:A]
      )
      host.phase_receiver_state.lock_analysis.direct_edges["a"] << LockHelper::LockEdge.new(
        held: :A,
        acquired: :A,
        site_token: token(3),
        fn_name: "a",
        opted_out: false
      )

      expect { host.send(:check_lock_handler_reachability!) }.not_to raise_error
    end

    it "uses opted-out graph edges for handler reachability" do
      node = with_block(clause: error_clause(selector(:type, :Deadlock)))
      host.phase_receiver_state.lock_analysis.clause_sites << LockHelper::LockClauseSite.new(
        node: node,
        cap_types: [:A]
      )
      host.phase_receiver_state.lock_analysis.direct_edges["a"] << LockHelper::LockEdge.new(
        held: :A,
        acquired: :A,
        site_token: token(3),
        fn_name: "a",
        opted_out: true
      )

      expect { host.send(:check_lock_handler_reachability!) }.not_to raise_error
    end
  end
end
