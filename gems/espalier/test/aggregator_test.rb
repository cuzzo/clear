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
      risk_data: risk_data,
      closed_world: true
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

  def test_propagates_impurity_to_callers_to_a_fixed_point
    modules = [{
      type: :class,
      name: "Pipeline",
      file: "pipeline.rb",
      states: %w[@value].to_set,
      methods: [
        {
          name: "run", effects: {reads: Set.new, writes: Set.new},
          delegations: [{receiver: "self", message: "step", type: :always}],
        },
        {
          name: "step", effects: {reads: Set.new, writes: Set.new},
          delegations: [{receiver: "self", message: "store", type: :always}],
        },
        {
          name: "store", effects: {reads: Set.new, writes: %w[@value].to_set},
          delegations: [{receiver: "self", message: "step", type: :conditional}],
        },
      ],
    }]

    functions = Espalier::Aggregator.new.aggregate(modules).first[:functions].to_h do |function|
      [function[:name], function]
    end

    assert_equal %w[@value], functions["run"][:EFFECTS][:writes]
    assert_equal %w[@value], functions["step"][:EFFECTS][:writes]
    assert_equal %w[@value], functions["store"][:EFFECTS][:writes]
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
          },
          {
            name: "sort_names",
            signature: "def sort_names(names)",
            visibility: :public,
            line: 14,
            span: [14, 0, 16, 3],
            EFFECTS: { reads: [], writes: [] },
            quality_metrics: {
              big_o: "O(N log N)",
              big_o_space: "O(N)",
              big_o_dynamic: true,
              complexity_trigger: "sort names",
              big_o_variables: [
                { symbol: "N", name: "names", source_kind: "parameter", path: "lib/conn.rb", span: [14, 15, 14, 20] }
              ]
            }
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
    complexity = run.fetch("results").find do |result|
      result.fetch("ruleId") == "complexity.observation" &&
        result.dig("properties", "complexity", "subject_name") == "ConnectionManager#sort_names"
    end
    refute_nil complexity, "pure functions must retain their complexity observation"
    assert_equal "O(N log N)", complexity.dig("properties", "complexity", "time")
    assert_equal "O(N)", complexity.dig("properties", "complexity", "auxiliary_space")
    assert_equal ["sort names"], complexity.dig("properties", "complexity", "triggers")
    assert_equal "names", complexity.dig("properties", "complexity", "variables", 0, "name")
    assert_equal "N is the size of `names` (parameter)", complexity.dig("relatedLocations", 0, "message", "text")
    assert_equal 14, complexity.dig("relatedLocations", 0, "physicalLocation", "region", "startLine")
    refute run.fetch("results").any? { |result|
      result.fetch("ruleId") == "espalier.function" &&
        result.dig("properties", "function", "name") == "sort_names"
    }
    assert_equal "espalier.manifest.sarif.v1", run.dig("properties", "format")
    assert_equal "unknown", complexity.dig("properties", "fact_mine.proof_boundary", "input_completeness")
    assert_equal "observed", complexity.dig("properties", "fact_mine.proof_boundary", "claim_status")
    fixture = JSON.parse(File.read(File.expand_path("../../hazard-contract/fixtures/proof-boundary.v3.json", __dir__)))
    assert_equal fixture.dig("representative", "espalier"), complexity.dig("properties", "fact_mine.proof_boundary")
    assert_equal 3, run.dig("properties", "fact_mine.proof_boundary_summary", "results_with_boundary")
    assert_equal 0, run.dig("properties", "fact_mine.proof_boundary_summary", "invalid_boundaries")
    assert_equal 0, run.dig("properties", "fact_mine.proof_boundary_summary", "missing_boundaries")
    assert_equal 0, run.dig("properties", "fact_mine.proof_boundary_summary", "input_completeness", "complete")
    assert_equal 3, run.dig("properties", "fact_mine.proof_boundary_summary", "input_completeness", "unknown")
  end

  def test_formatter_sarif_marks_incomplete_complexity_as_partial
    manifest = [{
      module: "Parser",
      file: "lib/parser.rb",
      proof_boundary: {
        input_completeness: "complete",
        input_blockers: []
      },
      functions: [{
        name: "parse",
        line: 3,
        quality_metrics: {
          big_o: "unknown",
          big_o_space: "O(1)",
          big_o_complete: false,
          big_o_space_complete: true,
          big_o_unknowns: ["dispatch target unresolved"]
        }
      }]
    }]

    run = JSON.parse(Espalier::Formatter.to_sarif(manifest)).fetch("runs").first
    result = run.fetch("results").first
    boundary = result.dig("properties", "fact_mine.proof_boundary")
    assert_equal "complete", boundary.fetch("input_completeness")
    assert_equal "observed", boundary.fetch("claim_status")
    assert_equal "partial", result.dig("properties", "complexity", "model_completeness")
    assert_includes result.dig("properties", "complexity", "model_blockers"), { "kind" => "call_resolution" }
    assert_equal 1, run.dig("properties", "fact_mine.proof_boundary_summary", "input_completeness", "complete")
  end

  def test_formatter_sarif_preserves_extractor_input_boundary
    manifest = [{
      module: "Parser",
      file: "lib/parser.rb",
      proof_boundary: {
        input_completeness: "partial",
        input_blockers: [{ "kind" => "missing_evidence" }]
      },
      functions: [{
        name: "parse",
        line: 3,
        quality_metrics: { big_o: "O(N)", big_o_space: "O(1)", big_o_complete: true, big_o_space_complete: true }
      }]
    }]

    run = JSON.parse(Espalier::Formatter.to_sarif(manifest)).fetch("runs").first
    boundary = run.fetch("results").first.dig("properties", "fact_mine.proof_boundary")
    assert_equal "partial", boundary.fetch("input_completeness")
    assert_equal [{ "kind" => "missing_evidence" }], boundary.fetch("blockers")
    assert_equal 1, run.dig("properties", "fact_mine.proof_boundary_summary", "input_completeness", "partial")
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

  def test_big_o_loop_attribution_uses_last_method_span
    modules = [
      {
        type: :class,
        name: "Formatter",
        file: "lib/formatter.rb",
        states: Set.new,
        methods: [
          {
            name: "last_method",
            signature: "def last_method",
            parameters: [],
            visibility: :public,
            line: 10,
            span: [10, 2, 12, 5],
            effects: { reads: Set.new, writes: Set.new },
            delegations: []
          }
        ]
      }
    ]

    aggregator = Espalier::Aggregator.new(
      nil_kill_loops: {
        "lib/formatter.rb" => {
          30 => 10
        }
      }
    )

    manifest = aggregator.aggregate(modules)
    fn = manifest.first[:functions].first

    assert_equal "O(1)", fn[:quality_metrics][:big_o]
  end

  def test_big_o_uses_fact_mine_normalized_call_costs
    modules = [
      {
        type: :class,
        name: "SegmentRenumber",
        file: "lib/segment_renumber.rb",
        states: Set.new,
        methods: [
          {
            name: "self.renumber_with_entry",
            signature: "sig { params(segments: T::Array[Segment], entry: Integer).returns(Result) }",
            parameters: ["segments", "entry"],
            visibility: :public,
            line: 20,
            span: [20, 2, 25, 5],
            effects: { reads: Set.new, writes: Set.new },
            complexity_facts: [{
              "line" => 20, "parameters" => ["segments", "entry"],
              "collection_parameters" => ["segments"], "iterations" => [],
              "allocations" => [], "size_domains" => [],
              "recursion" => { "calls" => 0 },
              "call_contexts" => [{
                "line" => 24, "message" => "sort_by", "execution_multiplicity" => "O(1)",
                "power" => 0, "argument_cardinality_relation" => "same",
                "known_time_complexity" => "O(N log N)", "known_space_complexity" => "O(N)"
              }]
            }],
            delegations: [
              { receiver: "segments", message: "sort_by", line: 24, type: :always }
            ]
          }
        ]
      }
    ]

    manifest = Espalier::Aggregator.new.aggregate(modules)
    fn = manifest.first[:functions].first

    assert_equal "O(N log N)", fn[:quality_metrics][:big_o]
    assert_equal "O(N log N)", fn[:quality_metrics][:big_o_known_component]
    assert_equal true, fn[:quality_metrics][:big_o_complete]
    assert_equal true, fn[:quality_metrics][:big_o_space_complete]
    refute fn[:quality_metrics].key?(:big_o_unknowns)
  end

  def incomplete_recursive_module(language, owner, fn_name)
    [
      {
        # project_modules disambiguates owners as "name@path"; the override
        # must key on the bare leaf.
        type: :class, name: "#{owner}@src/#{owner}.x", file: "src/#{owner}.x", states: Set.new,
        language: language,
        methods: [
          {
            name: fn_name, signature: "func #{fn_name}()",
            parameters: ["data"], visibility: :public, line: 20, span: [20, 0, 40, 1],
            effects: { reads: Set.new, writes: Set.new },
            complexity_facts: [{
              "line" => 20, "parameters" => ["data"], "collection_parameters" => ["data"],
              "iterations" => [], "allocations" => [], "size_domains" => [],
              "recursion" => { "calls" => 2, "unknown_progress_calls" => 2 },
              "call_contexts" => []
            }]
          }
        ]
      }
    ]
  end

  def test_manual_override_completes_only_incomplete_registered_functions
    modules = incomplete_recursive_module(:go, "sort", "Sort")
    fn = Espalier::Aggregator.new.aggregate(modules).first[:functions].first

    assert_equal "O(N log N)", fn[:quality_metrics][:big_o]
    assert_equal true, fn[:quality_metrics][:big_o_complete]
    assert_equal :manual_override, fn[:quality_metrics][:big_o_provenance]
    assert_equal :complete_override, fn[:quality_metrics][:big_o_status]
    assert_equal "O(log N)", fn[:quality_metrics][:big_o_space]
  end

  def test_manual_override_ignores_unregistered_functions
    # Same incomplete shape, but no registry entry for sort.Frobnicate.
    modules = incomplete_recursive_module(:go, "sort", "Frobnicate")
    fn = Espalier::Aggregator.new.aggregate(modules).first[:functions].first

    refute_equal true, fn[:quality_metrics][:big_o_complete]
    refute_equal :manual_override, fn[:quality_metrics][:big_o_provenance]
    assert_equal :incomplete, fn[:quality_metrics][:big_o_status]
  end

  def test_manual_override_never_replaces_a_complete_bound
    # A registered name (list.sort / python) but a COMPLETE derived bound:
    # the override must not fire.
    modules = [
      {
        type: :class, name: "list", file: "x.py", states: Set.new, language: :python,
        methods: [{
          name: "sort", signature: "def sort(self)", parameters: [], visibility: :public,
          line: 1, span: [1, 0, 2, 1], effects: { reads: Set.new, writes: Set.new },
          complexity_facts: [{
            "line" => 1, "parameters" => [], "collection_parameters" => [],
            "iterations" => [], "allocations" => [], "size_domains" => [],
            "recursion" => { "calls" => 0 }, "call_contexts" => []
          }]
        }]
      }
    ]
    fn = Espalier::Aggregator.new.aggregate(modules).first[:functions].first

    assert_equal true, fn[:quality_metrics][:big_o_complete]
    refute_equal :manual_override, fn[:quality_metrics][:big_o_provenance]
    refute_equal "O(N log N)", fn[:quality_metrics][:big_o]
    assert_equal :complete, fn[:quality_metrics][:big_o_status]
  end

  def test_big_o_status_distinguishes_parametric_from_complete
    # The core "complete" vs "complete worst case" distinction. A bound carrying
    # an open callback/reflective parameter (C/R) is complete only parametrically
    # - it is the tier a worst-case substitution upgrades to :complete_worst_case
    # and must NOT read as a plain (closed) :complete bound.
    agg = Espalier::Aggregator.new
    classify = ->(q) { agg.send(:classify_big_o_status, q) }

    assert_equal :complete, classify.call(big_o: "O(N)", big_o_complete: true)
    assert_equal :parametric, classify.call(big_o: "O(N * C)", big_o_complete: true)
    assert_equal :parametric, classify.call(big_o: "O(R)", big_o_complete: true)
    assert_equal :incomplete, classify.call(big_o: "unknown", big_o_complete: false)
    assert_equal :complete_override,
                 classify.call(big_o: "O(N log N)", big_o_complete: true,
                               big_o_provenance: :manual_override)
  end

  def test_lambda_argument_closes_an_external_parametric_callback_bound
    # A stdlib higher-order call is priced O(N*C) from its compiler symbol. The
    # closure passed at that call site is analyzed like any other function, so C
    # is not open - substituting it is what turns a partial bound into a closed
    # one.
    modules = [{
      type: :class, name: "demo", file: "demo.rs", states: Set.new, language: :rust,
      methods: [{
        id: "caller", name: "run", line: 1, span: [1, 0, 3, 1], parameters: ["xs"],
        visibility: :public, effects: { reads: Set.new, writes: Set.new },
        delegations: [{
          call_id: "c1", receiver: "xs.iter()", message: "map", line: 2,
          span: [2, 4, 2, 40], known_time_complexity: "O(N)",
          complexity_bound_quality: "upper_bound_parametric_callback_linear"
        }],
        complexity_facts: [{
          "line" => 1, "parameters" => ["xs"], "collection_parameters" => ["xs"],
          "iterations" => [], "allocations" => [], "recursion" => { "calls" => 0 },
          "size_domains" => [{ "id" => "param:xs", "name" => "xs", "source_kind" => "parameter" }],
          "call_contexts" => [{
            "line" => 2, "span" => [2, 4, 2, 40], "message" => "map",
            "execution_multiplicity" => "O(1)", "power" => 0,
            "argument_size_domains" => [["param:xs"]],
            "size_domains" => [{ "id" => "param:xs", "name" => "xs", "source_kind" => "parameter" }]
          }]
        }]
      }, {
        id: "lambda", name: "<lambda@2:20>", line: 2, span: [2, 20, 2, 34],
        dispatch_kind: "lambda", parameters: ["x"], visibility: :private,
        effects: { reads: Set.new, writes: Set.new }, delegations: [],
        complexity_facts: [{
          "line" => 2, "parameters" => ["x"], "collection_parameters" => [],
          "iterations" => [], "allocations" => [], "recursion" => { "calls" => 0 },
          "size_domains" => [], "call_contexts" => []
        }]
      }]
    }]

    functions = Espalier::Aggregator.new.aggregate(modules).first[:functions]
    quality = functions.find { |fn| fn[:name] == "run" }.fetch(:quality_metrics)

    assert_equal "O(N)", quality[:big_o]
    assert_equal :complete, quality[:big_o_status]
  end

  def test_costly_lambda_argument_keeps_its_own_cost_in_the_bound
    # Substitution is not erasure: an O(M) callable multiplies in rather than
    # dropping out, so O(N*C) becomes O(N*M), not O(N).
    modules = [{
      type: :class, name: "demo", file: "demo.rs", states: Set.new, language: :rust,
      methods: [{
        id: "caller", name: "run", line: 1, span: [1, 0, 3, 1], parameters: ["xs"],
        visibility: :public, effects: { reads: Set.new, writes: Set.new },
        delegations: [{
          call_id: "c1", receiver: "xs.iter()", message: "map", line: 2,
          span: [2, 4, 2, 40], known_time_complexity: "O(N)",
          complexity_bound_quality: "upper_bound_parametric_callback_linear"
        }],
        complexity_facts: [{
          "line" => 1, "parameters" => ["xs"], "collection_parameters" => ["xs"],
          "iterations" => [], "allocations" => [], "recursion" => { "calls" => 0 },
          "size_domains" => [{ "id" => "param:xs", "name" => "xs", "source_kind" => "parameter" }],
          "call_contexts" => [{
            "line" => 2, "span" => [2, 4, 2, 40], "message" => "map",
            "execution_multiplicity" => "O(1)", "power" => 0,
            "argument_size_domains" => [["param:xs"]],
            "size_domains" => [{ "id" => "param:xs", "name" => "xs", "source_kind" => "parameter" }]
          }]
        }]
      }, {
        id: "lambda", name: "<lambda@2:20>", line: 2, span: [2, 20, 2, 34],
        dispatch_kind: "lambda", parameters: ["y"], visibility: :private,
        effects: { reads: Set.new, writes: Set.new }, delegations: [],
        complexity_facts: [{
          "line" => 2, "parameters" => ["y"], "collection_parameters" => ["y"],
          "iterations" => [{
            "line" => 2, "span" => [2, 20, 2, 34], "power" => 1,
            "parameter_domains" => ["y"],
            "symbolic_time" => { "factors" => [{ "domain_id" => "param:y", "exponent" => 1 }] }
          }],
          "allocations" => [], "recursion" => { "calls" => 0 },
          "size_domains" => [{ "id" => "param:y", "name" => "y", "source_kind" => "parameter" }],
          "call_contexts" => []
        }]
      }]
    }]

    functions = Espalier::Aggregator.new.aggregate(modules).first[:functions]
    quality = functions.find { |fn| fn[:name] == "run" }.fetch(:quality_metrics)

    assert_equal "O(N*M)", quality[:big_o]
    assert_equal :complete, quality[:big_o_status]
  end

  def test_callable_of_unknown_cost_leaves_the_callback_parameter_open
    # Substitution must never price an unproven callable as free. A closure
    # whose own bound is not symbolically known keeps C open rather than
    # silently dropping out of the caller's bound.
    modules = [{
      type: :class, name: "demo", file: "demo.rs", states: Set.new, language: :rust,
      methods: [{
        id: "caller", name: "run", line: 1, span: [1, 0, 3, 1], parameters: ["xs"],
        visibility: :public, effects: { reads: Set.new, writes: Set.new },
        delegations: [{
          call_id: "c1", receiver: "xs.iter()", message: "map", line: 2,
          span: [2, 4, 2, 40], known_time_complexity: "O(N)",
          complexity_bound_quality: "upper_bound_parametric_callback_linear"
        }],
        complexity_facts: [{
          "line" => 1, "parameters" => ["xs"], "collection_parameters" => ["xs"],
          "iterations" => [], "allocations" => [], "recursion" => { "calls" => 0 },
          "size_domains" => [{ "id" => "param:xs", "name" => "xs", "source_kind" => "parameter" }],
          "call_contexts" => [{
            "line" => 2, "span" => [2, 4, 2, 40], "message" => "map",
            "execution_multiplicity" => "O(1)", "power" => 0,
            "argument_size_domains" => [["param:xs"]],
            "size_domains" => [{ "id" => "param:xs", "name" => "xs", "source_kind" => "parameter" }]
          }]
        }]
      }, {
        id: "lambda", name: "<lambda@2:20>", line: 2, span: [2, 20, 2, 34],
        dispatch_kind: "lambda", parameters: ["x"], visibility: :private,
        effects: { reads: Set.new, writes: Set.new },
        delegations: [{
          call_id: "c2", receiver: "sink", message: "consume", line: 2, span: [2, 24, 2, 33]
        }],
        complexity_facts: [{
          "line" => 2, "parameters" => ["x"], "collection_parameters" => [],
          "iterations" => [], "allocations" => [], "recursion" => { "calls" => 0 },
          "size_domains" => [],
          "call_contexts" => [{
            "line" => 2, "span" => [2, 24, 2, 33], "message" => "consume",
            "execution_multiplicity" => "O(1)", "power" => 0
          }]
        }]
      }]
    }]

    functions = Espalier::Aggregator.new.aggregate(modules).first[:functions]
    caller = functions.find { |fn| fn[:name] == "run" }.fetch(:quality_metrics)
    callable = functions.find { |fn| fn[:name] == "<lambda@2:20>" }.fetch(:quality_metrics)

    refute callable[:big_o_complete], "the closure's own cost must be unproven for this case"
    assert_equal "O(N*C)", caller[:big_o]
    assert_equal :parametric, caller[:big_o_status]
  end

  def test_worst_callable_rule
    worst = ->(rows) { Espalier::SymbolicComplexity.worst_callable(rows) }
    linear = Espalier::SymbolicComplexity.from_fact(
      { "factors" => [{ "domain_id" => "param:y", "exponent" => 1 }] },
      [{ "id" => "param:y", "name" => "y", "source_kind" => "parameter" }]
    )

    assert_nil worst.call([])
    # One unknown callable poisons the site.
    assert_equal({ expression: nil, constant: false },
                 worst.call([{ expression: linear, constant: false },
                             { expression: nil, constant: false }]))
    # Otherwise the costliest known cost wins, and constants alone close it.
    assert_equal linear, worst.call([{ expression: linear, constant: false },
                                     { expression: nil, constant: true }]).fetch(:expression)
    assert_equal({ expression: nil, constant: true },
                 worst.call([{ expression: nil, constant: true }]))
  end

  def test_complexity_overrides_lookup_semantics
    assert_equal "O(N log N)",
                 Espalier::ComplexityOverrides.lookup(:go, "sort", "Sort")["time"]
    # Unknown function / wrong language / missing owner all miss.
    assert_nil Espalier::ComplexityOverrides.lookup(:go, "sort", "Frobnicate")
    assert_nil Espalier::ComplexityOverrides.lookup(:rust, "sort", "Sort")
    assert_nil Espalier::ComplexityOverrides.lookup(:go, nil, nil)
  end

  def test_big_o_joins_same_line_calls_by_exact_span
    method = {
      id: "caller", name: "run", line: 2,
      complexity_facts: [{
        "collection_parameters" => [], "size_domains" => [],
        "call_contexts" => [{
          "line" => 3, "span" => [3, 4, 3, 18], "message" => "add",
          "execution_multiplicity" => "O(1)", "power" => 0,
          "known_time_complexity" => "O(1)"
        }, {
          "line" => 3, "span" => [3, 22, 3, 39], "message" => "add",
          "execution_multiplicity" => "O(1)", "power" => 0,
          "known_time_complexity" => "O(N)"
        }]
      }],
      delegations: [{
        call_id: "first", receiver: "left", message: "add", line: 3,
        span: [3, 4, 3, 18]
      }, {
        call_id: "second", receiver: "right", message: "add", line: 3,
        span: [3, 22, 3, 39]
      }]
    }
    mod = { name: "Source", file: "source.java", methods: [method] }

    nodes = Espalier::Aggregator.new.send(:big_o_nodes_for, mod, method)

    assert_equal "O(1)", nodes.find { |node| node[:call_id] == "first" }[:known_time_complexity]
    assert_equal "O(N)", nodes.find { |node| node[:call_id] == "second" }[:known_time_complexity]
  end

  def test_canonical_call_cost_outranks_earlier_context_cost_and_gap
    method = {
      id: "caller", name: "run", line: 2,
      complexity_facts: [{
        "collection_parameters" => [], "size_domains" => [],
        "call_contexts" => [{
          "line" => 3, "span" => [3, 4, 3, 18], "message" => "format",
          "execution_multiplicity" => "O(1)", "power" => 0,
          "known_time_complexity" => "O(1)",
          "known_space_complexity" => "O(1)",
          "evidence_gap" => "unmodeled_typed_operation"
        }]
      }],
      delegations: [{
        call_id: "format", receiver: "String", message: "format", line: 3,
        span: [3, 4, 3, 18], known_time_complexity: "O(N)",
        known_space_complexity: "O(N)"
      }]
    }
    mod = { name: "Source", file: "Source.java", methods: [method] }

    node = Espalier::Aggregator.new.send(:big_o_nodes_for, mod, method).first

    assert_equal "O(N)", node[:known_time_complexity]
    assert_equal "O(N)", node[:known_space_complexity]
    refute node.key?(:evidence_gap)
  end

  def test_big_o_detects_fixpoint_loop_over_collection
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "worker.rb")
      File.write(file, <<~RUBY)
        class Worker
          def resolve!
            progress = true
            while progress
              progress = false
              @slots.each do |id, slot|
                progress = true if slot
              end
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Worker",
          file: file,
          states: Set.new(["@slots"]),
          ivar_types: { "@slots" => "Hash" },
          methods: [
            {
              name: "resolve!",
              signature: "def resolve!",
              parameters: [],
              visibility: :public,
              line: 2,
              span: [2, 2, 9, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      assert_equal "O(1)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("fixpoint loop") }
    end
  end

  def test_big_o_detects_linear_project_call_inside_loop
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "worker.rb")
      File.write(file, <<~RUBY)
        class Worker
          def helper
            while more?
              advance
            end
          end

          def driver
            while progress
              helper
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Worker",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "helper",
              signature: "def helper",
              parameters: [],
              visibility: :public,
              line: 2,
              span: [2, 2, 6, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            },
            {
              name: "driver",
              signature: "def driver",
              parameters: [],
              visibility: :public,
              line: 8,
              span: [8, 2, 12, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new(
        nil_kill_loops: {
          file => { 3 => 5 }
        }
      ).aggregate(modules)
      driver = manifest.first[:functions].find { |fn| fn[:name] == "driver" }

      assert_equal "O(1)", driver[:quality_metrics][:big_o]
      refute Array(driver[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("project call inside fixpoint") }
    end
  end

  def test_big_o_does_not_promote_scanner_helper_inside_plain_loop
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "lexer.rb")
      File.write(file, <<~RUBY)
        class Lexer
          def read_interpolated_string
            while more?
              advance
            end
          end

          def tokenize
            while more?
              read_interpolated_string
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Lexer",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "read_interpolated_string",
              signature: "def read_interpolated_string",
              parameters: [],
              visibility: :public,
              line: 2,
              span: [2, 2, 6, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            },
            {
              name: "tokenize",
              signature: "def tokenize",
              parameters: [],
              visibility: :public,
              line: 8,
              span: [8, 2, 12, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new(
        nil_kill_loops: {
          file => { 3 => 5, 9 => 5 }
        }
      ).aggregate(modules)
      tokenize = manifest.first[:functions].find { |fn| fn[:name] == "tokenize" }

      assert_equal "O(N)", tokenize[:quality_metrics][:big_o]
      refute Array(tokenize[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("known linear project call") }
    end
  end

  def test_big_o_detects_aggregate_scan_inside_collection_loop
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "checker.rb")
      File.write(file, <<~RUBY)
        class Checker
          def normalize(states)
            names.each do |name|
              released_count = states.count { |state| state.released.include?(name) }
              next unless states.all? { |state| state.guarded.include?(name) }
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Checker",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "normalize",
              signature: "def normalize",
              parameters: ["states"],
              visibility: :public,
              line: 2,
              span: [2, 2, 7, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      assert_equal "O(1)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("aggregate collection scan") }
    end
  end

  def test_big_o_detects_insert_inside_loop_shift
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "hoist.rb")
      File.write(file, <<~RUBY)
        class Hoist
          def self.hoist_body!(body)
            i = 0
            while i < body.length
              hoists.each_with_index { |decl, j| body.insert(i + j, decl) }
              i += 1
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Hoist",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "self.hoist_body!",
              signature: "def self.hoist_body!",
              parameters: ["body"],
              visibility: :public,
              line: 2,
              span: [2, 2, 8, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      assert_equal "O(1)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("array insert") }
    end
  end

  def test_big_o_detects_triple_nested_loop
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "cubic.rb")
      File.write(file, <<~RUBY)
        class Cubic
          def triple(xs, ys, zs)
            xs.each do |x|
              ys.each do |y|
                zs.each do |z|
                  use(x, y, z)
                end
              end
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Cubic",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "triple",
              signature: "def triple",
              parameters: %w[xs ys zs],
              visibility: :public,
              line: 2,
              span: [2, 2, 10, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      assert_equal "O(1)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("loop domains") }
    end
  end

  def test_big_o_propagates_quadratic_helper_inside_loop
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "driver.rb")
      File.write(file, <<~RUBY)
        class Driver
          def pairwise(xs, ys)
            xs.each do |x|
              ys.each do |y|
                use(x, y)
              end
            end
          end

          def run(groups)
            groups.each do |group|
              pairwise(group.left, group.right)
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Driver",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "pairwise",
              signature: "def pairwise",
              parameters: %w[xs ys],
              visibility: :public,
              line: 2,
              span: [2, 2, 8, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            },
            {
              name: "run",
              signature: "def run",
              parameters: ["groups"],
              visibility: :public,
              line: 10,
              span: [10, 2, 14, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      pairwise = manifest.first[:functions].find { |fn| fn[:name] == "pairwise" }
      run = manifest.first[:functions].find { |fn| fn[:name] == "run" }

      assert_equal "O(1)", pairwise[:quality_metrics][:big_o]
      assert_equal "O(1)", run[:quality_metrics][:big_o]
      refute Array(run[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("project call inside loop") }
    end
  end

  def test_big_o_detects_exponential_branching_recursion
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "fib.rb")
      File.write(file, <<~RUBY)
        class Fib
          def fib(n)
            return n if n <= 1
            fib(n - 1) + fib(n - 2)
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Fib",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "fib",
              signature: "def fib",
              parameters: ["n"],
              visibility: :public,
              line: 2,
              span: [2, 2, 5, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      assert_equal "O(1)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("recursive branches") }
    end
  end

  def test_big_o_does_not_treat_linear_case_recursion_as_exponential
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "pipeline.rb")
      File.write(file, <<~RUBY)
        class Pipeline
          def build(stages)
            remaining = stages[1..-1]
            case stages.first
            when :where
              build(remaining)
            when :select
              build(remaining)
            else
              []
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Pipeline",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "build",
              signature: "def build",
              parameters: ["stages"],
              visibility: :public,
              line: 2,
              span: [2, 2, 12, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      refute_equal "O(2^N)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("multiple recursive branches") }
    end
  end

  def test_big_o_detects_factorial_recursive_branching
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "permuter.rb")
      File.write(file, <<~RUBY)
        class Permuter
          def permute(items)
            return [[]] if items.empty?
            items.each do |item|
              remaining = items.reject { |candidate| candidate == item }
              permute(remaining)
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Permuter",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "permute",
              signature: "def permute",
              parameters: ["items"],
              visibility: :public,
              line: 2,
              span: [2, 2, 8, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      assert_equal "O(1)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("recursive branching") }
    end
  end

  def test_big_o_does_not_build_fake_depth_from_sequential_single_line_maps
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "catch_builder.rb")
      File.write(file, <<~RUBY)
        class CatchBuilder
          def build(clauses)
            clauses.each do |clause|
              kinds = clause.kinds.map(&:to_s)
              types = clause.types.map(&:to_s)
              filters = clause.filters.map(&:to_s)
              use(kinds, types, filters)
            end
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "CatchBuilder",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "build",
              signature: "def build",
              parameters: ["clauses"],
              visibility: :public,
              line: 2,
              span: [2, 2, 10, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      refute_equal "O(N^4)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("nested loop containment depth 4") }
    end
  end

  def test_big_o_does_not_build_fake_depth_from_sequential_brace_blocks
    Dir.mktmpdir("espalier-big-o") do |dir|
      file = File.join(dir, "emitter.rb")
      File.write(file, <<~RUBY)
        class Emitter
          def emit(entries)
            first = entries.map { |entry|
              emit_one(entry)
            }.join("\\n")
            second = entries.map { |entry|
              emit_two(entry)
            }.join("\\n")
            third = entries.map { |entry|
              emit_three(entry)
            }.join("\\n")
            [first, second, third].join("\\n")
          end
        end
      RUBY

      modules = [
        {
          type: :class,
          name: "Emitter",
          file: file,
          states: Set.new,
          methods: [
            {
              name: "emit",
              signature: "def emit",
              parameters: ["entries"],
              visibility: :public,
              line: 2,
              span: [2, 2, 14, 5],
              effects: { reads: Set.new, writes: Set.new },
              delegations: []
            }
          ]
        }
      ]

      manifest = Espalier::Aggregator.new.aggregate(modules)
      fn = manifest.first[:functions].first

      refute_equal "O(N^3)", fn[:quality_metrics][:big_o]
      refute Array(fn[:quality_metrics][:big_o_warnings]).any? { |warning| warning.include?("nested loop containment depth 3") }
    end
  end

  def test_big_o_propagates_resolved_cross_owner_calls_end_to_end
    caller_fact = {
      "line" => 2, "parameters" => [], "collection_parameters" => [],
      "iterations" => [], "allocations" => [], "size_domains" => [],
      "recursion" => { "calls" => 0 },
      "call_contexts" => [{
        "line" => 3, "message" => "work", "execution_multiplicity" => "O(1)",
        "argument_cardinality_relation" => "same", "power" => 0
      }]
    }
    target_fact = {
      "line" => 10, "parameters" => ["items"], "collection_parameters" => ["items"],
      "iterations" => [{
        "line" => 11, "power" => 1, "execution_multiplicity" => "O(N)",
        "cardinality_relation" => "independent_of", "bound_classification" => "input"
      }],
      "allocations" => [], "call_contexts" => [], "size_domains" => [],
      "recursion" => { "calls" => 0 }
    }
    modules = [
      {
        type: :class, name: "Caller", file: "caller.rb", states: Set.new,
        methods: [{
          name: "run", signature: "def run", parameters: [], visibility: :public,
          line: 2, span: [2, 0, 4, 3], effects: { reads: Set.new, writes: Set.new },
          complexity_facts: [caller_fact],
          delegations: [{
            receiver: "Target", message: "work", line: 3, type: :always,
            target_owner: "Target", target_method: "self.work", target_id: "target-work"
          }]
        }]
      },
      {
        type: :class, name: "Target", file: "target.rb", states: Set.new,
        methods: [{
          id: "target-work", name: "self.work", signature: "def self.work", parameters: ["items"],
          visibility: :public, line: 10, span: [10, 0, 12, 3],
          effects: { reads: Set.new, writes: Set.new }, complexity_facts: [target_fact],
          delegations: []
        }]
      }
    ]

    manifest = Espalier::Aggregator.new.aggregate(modules)
    caller = manifest.find { |mod| mod[:module] == "Caller" }[:functions].first
    assert_equal "O(N)", caller[:quality_metrics][:big_o]
    assert caller[:quality_metrics][:big_o_complete]
    assert caller[:quality_metrics][:big_o_space_complete]
    refute_includes Array(caller[:quality_metrics][:big_o_unknowns]), "Target#work"
  end

  def test_big_o_uses_exact_target_id_when_overloads_share_owner_and_name
    caller_fact = {
      "line" => 2, "parameters" => [], "collection_parameters" => [],
      "iterations" => [], "allocations" => [], "size_domains" => [],
      "recursion" => { "calls" => 0 },
      "call_contexts" => [{
        "line" => 3, "message" => "work", "execution_multiplicity" => "O(1)",
        "argument_cardinality_relation" => "same", "power" => 0
      }]
    }
    linear_fact = {
      "line" => 10, "parameters" => ["items"], "collection_parameters" => ["items"],
      "iterations" => [{
        "line" => 11, "power" => 1, "execution_multiplicity" => "O(N)",
        "cardinality_relation" => "independent_of", "bound_classification" => "input"
      }],
      "allocations" => [], "call_contexts" => [], "size_domains" => [],
      "recursion" => { "calls" => 0 }
    }
    constant_fact = linear_fact.merge(
      "line" => 20,
      "iterations" => []
    )
    modules = [{
      type: :class, name: "Caller", file: "caller.java", states: Set.new,
      methods: [{
        id: "caller", name: "run", signature: "void run()", parameters: [],
        visibility: :public, line: 2, span: [2, 0, 4, 1],
        effects: { reads: Set.new, writes: Set.new }, complexity_facts: [caller_fact],
        delegations: [{
          receiver: "Target", message: "work", line: 3, type: :always,
          target_owner: "Target", target_method: "work", target_id: "work-linear",
          target_provenance: "scip"
        }]
      }]
    }, {
      type: :class, name: "Target", file: "target.java", states: Set.new,
      methods: [{
        id: "work-linear", name: "work", signature: "void work(List items)", parameters: ["items"],
        visibility: :public, line: 10, span: [10, 0, 13, 1],
        effects: { reads: Set.new, writes: Set.new }, complexity_facts: [linear_fact], delegations: []
      }, {
        id: "work-constant", name: "work", signature: "void work(int value)", parameters: ["value"],
        visibility: :public, line: 20, span: [20, 0, 22, 1],
        effects: { reads: Set.new, writes: Set.new }, complexity_facts: [constant_fact], delegations: []
      }]
    }]

    caller = Espalier::Aggregator.new.aggregate(modules).find { |mod| mod[:module] == "Caller" }[:functions].first
    assert_equal "O(N)", caller[:quality_metrics][:big_o]
    assert caller[:quality_metrics][:big_o_complete]
  end

  def test_scip_complete_call_graph_rejects_false_overload_recursion
    fact = {
      "line" => 2, "parameters" => ["value"], "collection_parameters" => [],
      "iterations" => [], "allocations" => [], "size_domains" => [],
      "recursion" => { "calls" => 1, "unknown_progress_calls" => 1 },
      "call_contexts" => [{
        "line" => 3, "message" => "visit", "execution_multiplicity" => "O(1)",
        "argument_cardinality_relation" => "same", "power" => 0
      }]
    }
    modules = [{
      type: :class, name: "Visitor", file: "visitor.java", states: Set.new,
      methods: [{
        id: "visit-int", name: "visit", signature: "void visit(int value)", parameters: ["value"],
        semantic_call_identity_complete: true,
        visibility: :public, line: 2, span: [2, 0, 4, 1],
        effects: { reads: Set.new, writes: Set.new }, complexity_facts: [fact],
        delegations: [{
          receiver: "this", message: "visit", line: 3, type: :always,
          target_owner: "Visitor", target_method: "visit", target_id: "visit-string",
          target_provenance: "scip"
        }]
      }, {
        id: "visit-string", name: "visit", signature: "void visit(String value)", parameters: ["value"],
        visibility: :public, line: 6, span: [6, 0, 7, 1],
        effects: { reads: Set.new, writes: Set.new }, complexity_facts: [], delegations: []
      }]
    }]

    function = Espalier::Aggregator.new.aggregate(modules).first[:functions].find { |row| row[:line] == 2 }
    assert_equal "O(1)", function[:quality_metrics][:big_o]
    assert function[:quality_metrics][:big_o_complete]
    refute_includes Array(function[:quality_metrics][:big_o_evidence_gaps]), "unresolved_recursive_progress"
  end

  def test_empty_exact_fact_set_does_not_fall_back_to_an_overload
    recursive_fact = {
      "line" => 10, "parameters" => [], "collection_parameters" => [],
      "iterations" => [], "allocations" => [], "size_domains" => [], "call_contexts" => [],
      "recursion" => { "calls" => 1, "unknown_progress_calls" => 1 }
    }
    modules = [{
      type: :class, name: "Factory", file: "factory.java", states: Set.new,
      methods: [{
        id: "create-constant", name: "create", signature: "create(int value)", parameters: ["value"],
        visibility: :public, line: 2, span: [2, 0, 3, 1], effects: { reads: Set.new, writes: Set.new },
        complexity_facts: [], delegations: []
      }, {
        id: "create-recursive", name: "create", signature: "create(String value)", parameters: ["value"],
        visibility: :public, line: 10, span: [10, 0, 12, 1], effects: { reads: Set.new, writes: Set.new },
        complexity_facts: [recursive_fact], delegations: []
      }]
    }]

    functions = Espalier::Aggregator.new.aggregate(modules).first[:functions]
    constant = functions.find { |function| function[:line] == 2 }
    assert_equal "O(1)", constant[:quality_metrics][:big_o]
    assert constant[:quality_metrics][:big_o_complete]
  end

  def test_big_o_consumes_normalized_constant_call_cost_without_source_guessing
    modules = [{
      type: :class, name: "Source", file: "source.rb", states: Set.new,
      methods: [{
        name: "run", signature: "def run", parameters: [], visibility: :public,
        line: 2, span: [2, 0, 4, 3], effects: { reads: Set.new, writes: Set.new },
        delegations: [{
          receiver: "Generated", message: "new", line: 3, type: :always,
          known_time_complexity: "O(1)", known_space_complexity: "O(1)"
        }]
      }]
    }]

    function = Espalier::Aggregator.new.aggregate(modules).first[:functions].first
    assert_equal "O(1)", function[:quality_metrics][:big_o]
    assert_equal "O(1)", function[:quality_metrics][:big_o_space]
    assert function[:quality_metrics][:big_o_complete]
    assert function[:quality_metrics][:big_o_space_complete]
    refute_includes Array(function[:quality_metrics][:big_o_unknowns]), "Generated#new"
  end

  def test_big_o_exposes_fact_mine_evidence_gaps
    modules = [{
      type: :class, name: "Source", file: "source.rb", states: Set.new,
      methods: [{
        name: "run", signature: "def run", parameters: [], visibility: :public,
        line: 2, span: [2, 0, 4, 3], effects: { reads: Set.new, writes: Set.new },
        complexity_facts: [{
          "line" => 2, "parameters" => [], "collection_parameters" => [],
          "iterations" => [], "allocations" => [], "size_domains" => [],
          "recursion" => { "calls" => 0 },
          "call_contexts" => [{
            "line" => 3, "message" => "scan", "execution_multiplicity" => "O(1)",
            "power" => 0, "argument_cardinality_relation" => "same",
            "evidence_gap" => "unmodeled_typed_operation"
          }]
        }],
        delegations: [{ receiver: "items", message: "scan", line: 3, type: :always }]
      }]
    }]

    function = Espalier::Aggregator.new.aggregate(modules).first[:functions].first
    assert_equal ["unmodeled_typed_operation"], function[:quality_metrics][:big_o_evidence_gaps]
  end

  def test_resolved_recursion_uses_stack_safe_component_analysis
    chain_length = 5_000
    methods = Array.new(chain_length) do |index|
      target = index + 1
      {
        name: "m#{index}", line: index + 1,
        delegations: target < chain_length ? [{
          message: "m#{target}", line: index + 1,
          target_owner: "Chain", target_method: "m#{target}"
        }] : []
      }
    end
    methods[-1][:delegations] << {
      message: "m2500", line: chain_length,
      target_owner: "Chain", target_method: "m2500"
    }

    recursive = Espalier::Aggregator.new.send(
      :recursive_resolved_edges,
      [{ name: "Chain", methods: methods }]
    )

    refute recursive[["Chain", "m2499", "Chain", "m2500"]]
    assert recursive[["Chain", "m2500", "Chain", "m2501"]]
    assert recursive[["Chain", "m4999", "Chain", "m2500"]]
  end

  def test_big_o_closure_reaches_beyond_eight_resolved_call_edges
    chain_length = 12
    methods = Array.new(chain_length) do |index|
      line = index * 3 + 1
      target = index + 1
      fact = {
        "line" => line, "parameters" => [], "collection_parameters" => [],
        "allocations" => [], "size_domains" => [], "recursion" => { "calls" => 0 },
        "iterations" => target == chain_length ? [{
          "line" => line + 1, "power" => 1, "execution_multiplicity" => "O(N)",
          "cardinality_relation" => "independent_of", "bound_classification" => "input"
        }] : [],
        "call_contexts" => target < chain_length ? [{
          "line" => line + 1, "message" => "m#{target}",
          "execution_multiplicity" => "O(1)", "argument_cardinality_relation" => "same",
          "power" => 0
        }] : []
      }
      {
        id: "m#{index}", name: "m#{index}", signature: "m#{index}()", parameters: [],
        visibility: :public, line: line, span: [line, 0, line + 2, 1],
        effects: { reads: Set.new, writes: Set.new }, complexity_facts: [fact],
        delegations: target < chain_length ? [{
          receiver: "Chain", message: "m#{target}", line: line + 1, type: :always,
          target_owner: "Chain", target_method: "m#{target}", target_id: "m#{target}",
          target_provenance: "scip"
        }] : []
      }
    end
    modules = [{
      type: :class, name: "Chain", file: "chain.rb", states: Set.new,
      methods: methods
    }]

    functions = Espalier::Aggregator.new.aggregate(modules).first[:functions]
    root = functions.find { |function| function[:id] == "m0" }

    assert_equal "O(N)", root[:quality_metrics][:big_o]
    assert root[:quality_metrics][:big_o_complete]
  end

  def test_big_o_joins_compiler_implementation_candidates_as_a_modeled_upper_bound
    constant_fact = {
      "line" => 10, "parameters" => [], "collection_parameters" => [],
      "iterations" => [], "allocations" => [], "call_contexts" => [],
      "size_domains" => [], "recursion" => { "calls" => 0 }
    }
    linear_fact = constant_fact.merge(
      "line" => 20,
      "iterations" => [{
        "line" => 21, "power" => 1, "execution_multiplicity" => "O(N)",
        "cardinality_relation" => "independent_of", "bound_classification" => "input"
      }]
    )
    caller_fact = constant_fact.merge(
      "line" => 2,
      "call_contexts" => [{
        "line" => 3, "message" => "work", "execution_multiplicity" => "O(1)",
        "argument_cardinality_relation" => "same", "power" => 0
      }]
    )
    modules = [{
      type: :class, name: "Caller", file: "caller.go", states: Set.new,
      methods: [{
        id: "caller", name: "run", signature: "run()", parameters: [],
        visibility: :public, line: 2, span: [2, 0, 4, 1],
        effects: { reads: Set.new, writes: Set.new }, complexity_facts: [caller_fact],
        delegations: [{
          receiver: "worker", message: "work", line: 3, type: :always,
          candidate_target_ids: %w[fast slow], candidate_reason: "scip_implementation_set"
        }]
      }]
    }, {
      type: :class, name: "Workers", file: "workers.go", states: Set.new,
      methods: [{
        id: "fast", name: "work", signature: "work()", parameters: [], visibility: :public,
        line: 10, span: [10, 0, 12, 1], effects: { reads: Set.new, writes: Set.new },
        complexity_facts: [constant_fact], delegations: []
      }, {
        id: "slow", name: "work", signature: "work()", parameters: [], visibility: :public,
        line: 20, span: [20, 0, 22, 1], effects: { reads: Set.new, writes: Set.new },
        complexity_facts: [linear_fact], delegations: []
      }]
    }]

    caller = Espalier::Aggregator.new.aggregate(modules).first[:functions].first

    assert_equal "O(N)", caller[:quality_metrics][:big_o]
    assert caller[:quality_metrics][:big_o_complete]
    assert_includes caller[:quality_metrics][:big_o_bound_qualities], "upper_bound_closed_candidate_max"
    assert_includes caller[:quality_metrics][:big_o_assumptions].first, "implementation set is closed"
  end

end
