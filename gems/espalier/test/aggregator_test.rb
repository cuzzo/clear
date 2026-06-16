# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../lib/espalier"

class AggregatorTest < Minitest::Test
  def skip_unless_ruby_grammar
    grammar = ENV["DECOMPLEX_TS_RUBY_PATH"]
    skip "set DECOMPLEX_TS_RUBY_PATH to run Ruby Tree-sitter extractor test" unless grammar && File.file?(grammar)
  end

  def test_aggregates_sibling_data_into_clean_schema
    # Mock extracted AST data
    modules = [
      {
        type: :class,
        name: "ConnectionManager",
        file: "lib/conn.rb",
        states: %w[@active_connections @max_limit].to_set,
        methods: [
          {
            name: "connect",
            signature: "def connect(id)",
            parameters: ["id"],
            visibility: :public,
            effects: { reads: %w[@max_limit].to_set, writes: %w[@active_connections].to_set },
            delegations: [
              { receiver: "self", message: "limit_reached?", type: :conditional },
              { receiver: "Socket", message: "open", type: :always }
            ]
          },
          {
            name: "limit_reached?",
            signature: "def limit_reached?",
            parameters: [],
            visibility: :public,
            effects: { reads: %w[@max_limit].to_set, writes: Set.new },
            delegations: []
          }
        ]
      }
    ]

    # Mock Decomplex, Nil-kill, and Risk reports
    decomplex_data = {
      "ConnectionManager#connect" => { deviance: 1.5, broken_protocol: true },
      "ConnectionManager::STATE_CO_UPDATE" => { "@active_connections" => "@connections_count" }
    }
    nil_kill_data = {
      "ConnectionManager#connect" => "def connect(id: String) -> Socket"
    }
    risk_data = {
      "lib/conn.rb" => { churn: 0.85, coverage_gap: 0.4 }
    }

    aggregator = Espalier::Aggregator.new(
      decomplex_data: decomplex_data,
      nil_kill_data: nil_kill_data,
      risk_data: risk_data
    )

    modules.first[:ivar_properties] = {
      "@active_connections" => ["loaded from param: socket_params", "protocol interfaces: write, close"]
    }

    manifest = aggregator.aggregate(modules)
    assert_equal 1, manifest.size
    
    mod = manifest.first
    assert_equal "ConnectionManager", mod[:module]
    
    # State check
    state_conn = mod[:state].find { |s| s[:name] == "@active_connections" }
    assert_includes state_conn[:properties], "co-updates with @connections_count"
    assert_includes state_conn[:properties], "loaded from param: socket_params"
    assert_includes state_conn[:properties], "protocol interfaces: write, close"

    # Function check
    fn = mod[:functions].find { |f| f[:name] == "connect" }
    assert_equal "def connect(id: String) -> Socket", fn[:signature]
    assert_equal :public, fn[:visibility]
    assert_equal %w[@max_limit], fn[:EFFECTS][:reads]
    assert_equal %w[@active_connections], fn[:EFFECTS][:writes]
    
    # Delegation mapping
    assert_includes fn[:DELEGATIONS][:conditionally_calls], "limit_reached?"
    assert_includes fn[:DELEGATIONS][:always_calls], "Socket.open"

    # Metrics integration
    assert_equal 1.5, fn[:quality_metrics][:complexity]
    assert_equal true, fn[:quality_metrics][:broken_protocol]
    assert_equal 0.85, fn[:quality_metrics][:churn_risk]
    assert_equal 0.4, fn[:quality_metrics][:coverage_gap]

    helper = mod[:functions].find { |f| f[:name] == "limit_reached?" }
    assert_equal ["connect"], helper[:CALL_GRAPH][:internal_callers]
    assert_equal ["limit_reached?"], fn[:CALL_GRAPH][:internal_calls]
    assert_equal [{ caller: "connect", callee: "limit_reached?", type: :conditional }], mod[:call_graph][:internal_edges]
    assert_equal true, helper[:quality_metrics][:privacy_candidate]
    assert_equal :high, helper[:quality_metrics][:privacy_confidence]
  end

  def test_formatter_json_is_sarif
    manifest = [
      {
        module: "ConnectionManager",
        file: "lib/conn.rb",
        language: :ruby,
        type: :class,
        state: [{ name: "@active", type: "Boolean", properties: [] }],
        functions: [
          {
            name: "prepare_state",
            signature: "def prepare_state",
            visibility: :public,
            line: 4,
            span: [4, 0, 8, 3],
            EFFECTS: { reads: [], writes: ["@active"] },
            quality_metrics: { privacy_candidate: true, privacy_score: 8.0 }
          },
          {
            name: "read_state",
            signature: "def read_state",
            visibility: :public,
            line: 10,
            span: [10, 0, 12, 3],
            EFFECTS: { reads: ["@active"], writes: [] },
            quality_metrics: { privacy_candidate: false }
          }
        ]
      }
    ]

    sarif = JSON.parse(Espalier::Formatter.to_sarif(manifest))
    assert_equal "2.1.0", sarif.fetch("version")
    run = sarif.fetch("runs").first
    assert_equal "Espalier", run.dig("tool", "driver", "name")
    assert run.fetch("results").any? { |result| result.fetch("ruleId") == "espalier.function" }
    assert run.fetch("results").any? { |result| result.dig("properties", "function", "name") == "read_state" }
    assert run.fetch("results").any? { |result| result.dig("message", "text") == "read-only function: ConnectionManager#read_state" }
    refute run.fetch("results").any? { |result| result.dig("message", "text") == "impure function: ConnectionManager#read_state" }
    refute run.fetch("results").any? { |result| result.fetch("ruleId") == "espalier.privacy-candidate" }
    assert_equal "espalier.manifest.sarif.v1", run.dig("properties", "format")
  end

  def test_delegations_mapped_to_concrete_type_when_available
    modules = [
      {
        type: :class,
        name: "MyClient",
        file: "lib/my_client.rb",
        states: %w[@backend].to_set,
        ivar_types: { "@backend" => "RemoteService" },
        methods: [
          {
            name: "fetch",
            signature: "def fetch",
            parameters: [],
            visibility: :public,
            effects: { reads: %w[@backend].to_set, writes: Set.new },
            delegations: [
              { receiver: "@backend", message: "get_data", type: :always },
              { receiver: "@unknown_ivar", message: "process", type: :always }
            ]
          }
        ]
      }
    ]

    aggregator = Espalier::Aggregator.new
    manifest = aggregator.aggregate(modules)
    
    mod = manifest.first
    fn = mod[:functions].find { |f| f[:name] == "fetch" }
    
    # "@backend" mapped to "RemoteService"
    assert_includes fn[:DELEGATIONS][:always_calls], "RemoteService.get_data"
    # "@unknown_ivar" falls back to "@unknown_ivar.process" since we don't have types for it
    assert_includes fn[:DELEGATIONS][:always_calls], "@unknown_ivar.process"
  end

  def test_uses_tree_sitter_delegations_for_internal_call_graph
    skip_unless_ruby_grammar

    Dir.mktmpdir do |dir|
      path = File.join(dir, "worker.rb")
      File.write(path, <<~RB)
        class Worker
          def run
            prepare
            if ready?
              validate
            end
          end

          def prepare; end
          def ready?; true; end
          def validate; end
        end
      RB

      modules = Espalier::AstExtractor.new(path).extract
      manifest = Espalier::Aggregator.new.aggregate(modules)
      mod = manifest.first

      assert_equal [
        { caller: "run", callee: "prepare", type: :always },
        { caller: "run", callee: "ready?", type: :conditional },
        { caller: "run", callee: "validate", type: :conditional }
      ], mod[:call_graph][:internal_edges]

      run = mod[:functions].find { |fn| fn[:name] == "run" }
      prepare = mod[:functions].find { |fn| fn[:name] == "prepare" }
      assert_equal %w[prepare ready? validate], run[:CALL_GRAPH][:internal_calls]
      assert_equal ["run"], prepare[:CALL_GRAPH][:internal_callers]
    end
  end

  def test_tree_sitter_delegations_handle_explicit_self_internal_calls
    skip_unless_ruby_grammar

    Dir.mktmpdir do |dir|
      path = File.join(dir, "phase.rb")
      File.write(path, <<~RB)
        class Phase
          def run
            self.prepare
          end

          def prepare; end
        end
      RB

      modules = Espalier::AstExtractor.new(path).extract
      manifest = Espalier::Aggregator.new.aggregate(modules)

      assert_equal [
        { caller: "run", callee: "prepare", type: :always }
      ], manifest.first[:call_graph][:internal_edges]
    end
  end
end
