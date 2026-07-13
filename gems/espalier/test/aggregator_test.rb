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
              complexity_trigger: "sort names"
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
    refute run.fetch("results").any? { |result|
      result.fetch("ruleId") == "espalier.function" &&
        result.dig("properties", "function", "name") == "sort_names"
    }
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

  def test_big_o_uses_signature_param_types
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

end
