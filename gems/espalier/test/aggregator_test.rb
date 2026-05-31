# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class AggregatorTest < Minitest::Test
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
            effects: { reads: %w[@max_limit].to_set, writes: %w[@active_connections].to_set },
            delegations: [
              { receiver: "self", message: "limit_reached?", type: :conditional },
              { receiver: "Socket", message: "open", type: :always }
            ]
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
    fn = mod[:functions].first
    assert_equal "def connect(id: String) -> Socket", fn[:signature]
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
end
