# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/espalier"

class StaticEvidenceTest < Minitest::Test
  def test_builds_static_evidence_using_rust_fact_mine
    nil_kill_features = loaded_nil_kill_features

    Dir.mktmpdir("espalier-static", Dir.pwd) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "client_user.rb"), <<~RUBY)
        class ClientUser
          extend T::Sig

          sig { params(client: T.untyped).void }
          def initialize(client)
            @client = T.let(client, T.untyped)
          end

          sig { returns(String) }
          def call
            @client.fetch
            self.helper
          end

          sig { void }
          def helper
          end
        end
      RUBY

      evidence = Espalier::StaticEvidence.build([src], root: dir)

      assert_equal "espalier_static_evidence", evidence["kind"]
      assert_equal 3, evidence.dig("summary", "methods")
      # State protocols include the field call, but never the explicit
      # owner-method call (`self.helper`).
      assert_equal ["fetch"], evidence.dig("facts", "state_protocols", "ClientUser\u0000@client")
      assert_equal false, evidence.dig("language_capabilities", "ruby", "runtime_tracing")
      assert_equal nil_kill_features, loaded_nil_kill_features
    end
  end

  def test_skips_root_rbi_annotations_for_explicit_non_project_targets
    Dir.mktmpdir("espalier-static-rbi", Dir.pwd) do |dir|
      target = File.join(dir, "tmp_target")
      rbi = File.join(dir, "sorbet", "rbi")
      FileUtils.mkdir_p(target)
      FileUtils.mkdir_p(rbi)
      File.write(File.join(target, "worker.rb"), <<~RUBY)
        class Worker
          def call(value)
            value
          end
        end
      RUBY
      File.write(File.join(rbi, "generated.rbi"), <<~RBI)
        class Generated
          sig { returns(String) }
          def name; end
        end
      RBI

      evidence = Espalier::StaticEvidence.build([target], root: dir)
      rbi_definitions = evidence.dig("facts", "type_definitions").select do |definition|
        definition["path"].to_s.end_with?(".rbi")
      end

      assert_empty rbi_definitions
      assert_equal 0, evidence.dig("summary", "rbi_field_types")
    end
  end

  # Hash shapes / collection lookups not yet implemented in Rust FactMine (Phase 2c).
  # This test documents the expected behavior once implemented.
  def test_static_evidence_includes_hash_record_lookup_facts
    Dir.mktmpdir("espalier-static-hash", Dir.pwd) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "worker.rb"), <<~RUBY)
        class Worker
          def label
            user = {name: "Ada", id: 1}
            "\#{user[:name]}:\#{user.fetch(:id)}"
          end
        end
      RUBY

      evidence = Espalier::StaticEvidence.build([src], root: dir)
      lookups = evidence.dig("facts", "collection_index_lookups")

      assert_equal 2, evidence.dig("summary", "collection_index_lookups")
      assert_includes lookups.map { |lookup| lookup["code"] }, "user[:name]"
      assert_includes lookups.map { |lookup| lookup["code"] }, "user.fetch(:id)"
      assert lookups.all? { |lookup| lookup.dig("origin", "kind") == "hash literal" }
    end
  end

  def test_project_modules_groups_by_owner
    evidence = {
      "methods" => [
        {
          "name" => "connect",
          "signature" => "def connect(id)",
          "params" => ["id"],
          "owner" => "ConnectionManager",
          "path" => "lib/conn.rb",
          "line" => 20,
          "span" => [20, 0, 25, 3],
          "language" => "ruby"
        }
      ],
      "fields" => [
        {
          "name" => "@active_connections",
          "owner" => "ConnectionManager",
          "path" => "lib/conn.rb",
          "line" => 15,
          "span" => [15, 0, 15, 20],
          "language" => "ruby"
        }
      ],
      "facts" => {
        "call_graph_edges" => [],
        "state_protocol_records" => [
          {
            "owner" => "ConnectionManager",
            "function" => "connect",
            "field" => "@active_connections",
            "protocol" => "sort_by",
            "line" => 23
          }
        ],
        "state_param_origin_records" => [],
        "struct_declarations" => [
          {
            "class" => "ConnectionManager",
            "fields" => ["active_connections"]
          }
        ]
      }
    }

    modules = Espalier::StaticEvidence.project_modules(evidence)
    assert_equal 1, modules.size
    mod = modules.first
    assert_equal "ConnectionManager", mod[:name]
    assert_equal "lib/conn.rb", mod[:file]
    assert_includes mod[:states], "@active_connections"
    assert_equal 1, mod[:methods].size
    assert_equal "connect", mod[:methods].first[:name]
    assert_includes mod.dig(:declared_fields, "ConnectionManager"), "active_connections"
    assert_includes mod[:methods].first[:delegations], {
      receiver: "@active_connections",
      message: "sort_by",
      line: 23,
      type: :always
    }
  end

  def test_project_modules_resolves_unique_static_and_flow_typed_targets
    evidence = {
      "methods" => [
        { "id" => "source-run", "owner" => "Source", "name" => "run", "kind" => "instance",
          "dispatch_name" => "run", "path" => "source.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-build", "owner" => "Target", "name" => "self.build", "kind" => "class",
          "dispatch_name" => "build", "path" => "target.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-work", "owner" => "Target", "name" => "work", "kind" => "instance",
          "dispatch_name" => "work", "path" => "target.rb", "line" => 6, "language" => "ruby" }
      ],
      "facts" => {
        "calls" => [
          { "source" => "source-run", "receiver" => "Target", "receiver_kind" => "type",
            "message" => "build", "line" => 3 },
          { "source" => "source-run", "receiver" => "target", "receiver_kind" => "value",
            "message" => "work", "line" => 4 }
        ],
        "flow_local_types" => [
          { "file" => "source.rb", "owner" => "Source", "function" => "run", "name" => "target",
            "line" => 4, "complete" => true,
            "resolved_types" => [FactMine::Syntax::TypeExpr.new("Primitive", "Target", "ruby")] }
        ]
      }
    }

    modules = Espalier::StaticEvidence.project_modules(evidence)
    run = modules.find { |mod| mod[:name] == "Source" }[:methods].first
    static_call = run[:delegations].find { |call| call[:message] == "build" }
    typed_call = run[:delegations].find { |call| call[:message] == "work" }

    assert_equal ["Target", "self.build"], [static_call[:target_owner], static_call[:target_method]]
    assert_equal ["Target", "work"], [typed_call[:target_owner], typed_call[:target_method]]
    assert_equal "high", static_call[:confidence]
    assert_equal "high", typed_call[:confidence]
  end

  def test_project_modules_does_not_guess_ambiguous_or_incomplete_targets
    evidence = {
      "methods" => [
        { "id" => "source-run", "owner" => "Source", "name" => "run", "kind" => "instance",
          "dispatch_name" => "run", "path" => "source.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-build-a", "owner" => "Target", "name" => "self.build", "kind" => "class",
          "dispatch_name" => "build", "path" => "a.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-build-b", "owner" => "Target", "name" => "self.build", "kind" => "class",
          "dispatch_name" => "build", "path" => "b.rb", "line" => 2, "language" => "ruby" },
        { "id" => "target-work", "owner" => "Target", "name" => "work", "kind" => "instance",
          "dispatch_name" => "work", "path" => "target.rb", "line" => 6, "language" => "ruby" }
      ],
      "facts" => {
        "calls" => [
          { "source" => "source-run", "receiver" => "Target", "receiver_kind" => "type",
            "message" => "build", "line" => 3 },
          { "source" => "source-run", "receiver" => "target", "receiver_kind" => "value",
            "message" => "work", "line" => 4 }
        ],
        "flow_local_types" => [{
          "file" => "source.rb", "owner" => "Source", "function" => "run", "name" => "target",
          "line" => 4, "complete" => false,
          "resolved_types" => [FactMine::Syntax::TypeExpr.new("Primitive", "Target", "ruby")]
        }],
        "struct_declarations" => [{
          "class" => "Target", "fields" => [], "constant_operations" => ["build"]
        }]
      }
    }

    run = Espalier::StaticEvidence.project_modules(evidence)
      .find { |mod| mod[:name] == "Source" }[:methods].first
    run[:delegations].each do |call|
      assert_nil call[:target_owner]
      assert_nil call[:target_method]
      assert_nil call[:known_time_complexity], "ambiguous overrides must not fall back to generated cost"
    end
  end

  def test_project_modules_uses_normalized_constructor_and_constant_operation_evidence
    evidence = {
      "methods" => [
        { "id" => "source-run", "owner" => "Source", "name" => "run", "kind" => "instance",
          "dispatch_name" => "run", "path" => "source.rb", "line" => 2, "language" => "ruby" },
        { "id" => "record-init", "owner" => "Record", "name" => "initialize", "kind" => "instance",
          "dispatch_name" => "initialize", "path" => "record.rb", "line" => 2, "language" => "ruby" }
      ],
      "facts" => {
        "calls" => [
          { "source" => "source-run", "receiver" => "Record", "receiver_kind" => "type",
            "message" => "new", "constructor_target" => "initialize", "line" => 3 },
          { "source" => "source-run", "receiver" => "Generated", "receiver_kind" => "type",
            "message" => "new", "constructor_target" => "initialize", "line" => 4 },
          { "source" => "source-run", "receiver" => "self", "receiver_kind" => "value",
            "message" => "[]", "line" => 5 },
          { "source" => "source-run", "receiver" => "T", "receiver_kind" => "type",
            "message" => "let", "known_time_complexity" => "O(1)",
            "known_space_complexity" => "O(1)", "line" => 6 }
        ],
        "struct_declarations" => [
          { "class" => "Source", "fields" => [], "constant_operations" => ["[]"] },
          { "class" => "Record", "fields" => [], "constant_operations" => ["new"] },
          { "class" => "Generated", "fields" => [], "constant_operations" => ["new"] }
        ]
      }
    }

    run = Espalier::StaticEvidence.project_modules(evidence)
      .find { |mod| mod[:name] == "Source" }[:methods].first
    constructor = run[:delegations].find { |call| call[:receiver] == "Record" }
    generated = run[:delegations].find { |call| call[:receiver] == "Generated" }
    reader = run[:delegations].find { |call| call[:message] == "[]" }
    intrinsic = run[:delegations].find { |call| call[:message] == "let" }

    assert_equal ["Record", "initialize"], [constructor[:target_owner], constructor[:target_method]]
    assert_nil constructor[:known_time_complexity], "an exact override must win over generated-operation cost"
    assert_equal ["O(1)", "O(1)"], [generated[:known_time_complexity], generated[:known_space_complexity]]
    assert_equal ["O(1)", "O(1)"], [reader[:known_time_complexity], reader[:known_space_complexity]]
    assert_equal ["O(1)", "O(1)"], [intrinsic[:known_time_complexity], intrinsic[:known_space_complexity]]
  end

  def test_builds_using_fact_mine_facts_file
    Dir.mktmpdir("espalier-mock", Dir.pwd) do |dir|
      mock_file = File.join(dir, "mock.rb")
      File.write(mock_file, "class MockClass; def mock_method; end; end")

      mock_facts = {
        "methods" => [
          {
            "name" => "mock_method",
            "owner" => "MockClass",
            "path" => "mock.rb",
            "line" => 1,
            "language" => "ruby"
          }
        ],
        "flow_local_types" => [
          {
            "file" => "mock.rb",
            "function" => "mock_method",
            "name" => "message",
            "place_id" => "place-1",
            "node_id" => "node-1",
            "line" => 1,
            "span" => [1, 0, 1, 7],
            "types" => ["string"],
            "complete" => true,
            "reaching_definitions" => ["node-0"]
          }
        ]
      }
      Tempfile.create(["mock-facts", ".json"]) do |f|
        f.write(JSON.dump(mock_facts))
        f.close
        begin
          ENV["FACT_MINE_FACTS_FILE"] = f.path
          evidence = Espalier::StaticEvidence.build([mock_file], root: dir)
          assert_equal "espalier_static_evidence", evidence["kind"]
          assert_equal 1, evidence.dig("summary", "methods")
          assert_equal "mock_method", evidence.dig("methods", 0, "name")
          assert_equal 1, evidence.dig("summary", "flow_local_types")
          assert_equal ["string"], evidence.dig("facts", "flow_local_types", 0, "types")
        ensure
          ENV["FACT_MINE_FACTS_FILE"] = nil
        end
      end
    end
  end

  private

  def loaded_nil_kill_features
    $LOADED_FEATURES.grep(%r{/nil[-_]kill/}).sort
  end
end
