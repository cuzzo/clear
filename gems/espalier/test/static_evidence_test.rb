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
    skip "hash shapes / collection lookups not yet implemented in Rust FactMine (Phase 2c)"

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

  private

  def loaded_nil_kill_features
    $LOADED_FEATURES.grep(%r{/nil[-_]kill/}).sort
  end
end