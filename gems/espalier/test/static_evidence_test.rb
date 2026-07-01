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
            @client = client
          end

          sig { returns(String) }
          def call
            @client.fetch
          end
        end
      RUBY

      evidence = Espalier::StaticEvidence.build([src], root: dir)

      assert_equal "espalier_static_evidence", evidence["kind"]
      assert_equal 2, evidence.dig("summary", "methods")
      # state_protocols from call_sites (Rust detects @client.fetch)
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
        "state_param_origin_records" => []
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
    assert_includes mod[:methods].first[:delegations], {
      receiver: "@active_connections",
      message: "sort_by",
      line: 23,
      type: :always
    }
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
