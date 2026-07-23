# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../lib/espalier"

class StaticEvidenceCovTest < Minitest::Test
  def test_full_coverage_of_rust_facts
    Dir.mktmpdir("espalier-static-cov", Dir.pwd) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      file_path = File.join(src, "cov.rb")
      File.write(file_path, "class Cov; end")

      facts_payload = {
        "language" => "ruby",
        "call_graph_edges" => [
          { "kind" => "internal_call", "source" => "fn:Cov#method1", "target" => "fn:Cov#method2", "conditional" => true }
        ],
        "state_protocol_records" => [
          { "owner" => "Cov", "function" => "method1", "field" => "@state", "protocol" => "each" }
        ],
        "state_param_origin_records" => [
          { "owner" => "Cov", "function" => "method1", "field" => "@state", "param" => "p" }
        ],
        "hash_record_blockers" => [
          { "path" => file_path, "line" => 10, "kind" => "dynamic_key" }
        ],
        "tlet_sites" => [
          { "path" => file_path, "line" => 12 }
        ],
        "dead_nil_checks" => [
          { "path" => file_path, "line" => 14, "kind" => "redundant" }
        ],
        "deterministic_guards" => [
          { "path" => file_path, "line" => 15, "code" => "is_a?" }
        ],
        "return_origins" => [
          { "path" => file_path, "line" => 16, "method" => "method1" }
        ],
        "noreturn_methods" => [
          { "path" => file_path, "owner" => "Cov", "name" => "panic!" }
        ],
        "hash_record_escape_sites" => [
          { "path" => file_path, "line" => 20 }
        ],
        "rbi_field_types" => [
          { "class" => "Cov", "field" => "@state" }
        ],
        "collection_index_lookups" => [
          { "path" => file_path, "line" => 21, "code" => "foo[:bar]" }
        ],
        "nullable_refinements" => [
          { "condition_node_id" => "condition:1", "place_id" => "place:cache:value", "state_on_edge" => "definitely_non_null" }
        ],
        "nullable_states" => [
          { "node_id" => "node:1", "place_id" => "place:cache:value", "state" => "definitely_null", "complete" => true }
        ],
        "nullable_summaries" => [
          { "owner" => "Cov", "function" => "lookup", "return_state" => "definitely_null", "complete" => true }
        ],
        "nullable_operations" => [
          { "path" => file_path, "span" => [24, 2, 24, 9], "node_id" => "node:deref", "place_id" => "place:cache:value", "operation_kind" => "pointer_dereference", "nil_behavior" => "undefined_behavior", "complete" => true }
        ],
        "presence_correlations" => [
          { "group_id" => "presence:cache", "value_place_id" => "place:cache:value", "presence_place_id" => "place:cache:ok", "semantics" => "map_presence" }
        ],
        "methods" => [
          { "id" => "fn:Cov#method1", "name" => "method1", "owner" => "Cov", "path" => file_path, "line" => 5 }
        ],
        "fields" => [
          { "id" => "var:Cov#@state", "name" => "@state", "owner" => "Cov", "path" => file_path }
        ]
      }

      facts_file = File.join(dir, "facts.json")
      File.write(facts_file, JSON.generate(facts_payload))

      ENV["FACT_MINE_FACTS_FILE"] = facts_file
      begin
        evidence = Espalier::StaticEvidence.build([file_path], root: dir)
        assert_equal "espalier_static_evidence", evidence["kind"]
        assert_equal 1, evidence.dig("facts", "state_protocol_records").length
        assert_equal 1, evidence.dig("facts", "state_param_origin_records").length
        assert_equal 1, evidence.dig("facts", "collection_index_lookups").length
        assert_equal "definitely_null", evidence.dig("facts", "nullable_states", 0, "state")
        assert_equal "undefined_behavior", evidence.dig("facts", "nullable_operations", 0, "nil_behavior")
        assert_equal "presence:cache", evidence.dig("facts", "presence_correlations", 0, "group_id")
      ensure
        ENV.delete("FACT_MINE_FACTS_FILE")
      end
    end
  end

  def test_project_modules_coverage
    evidence = {
      "methods" => [
        { "id" => "fn:Cov#method1", "name" => "method1", "owner" => "Cov", "path" => "cov.rb", "line" => 5 }
      ],
      "fields" => [
        { "id" => "var:Cov#@state", "name" => "@state", "owner" => "Cov", "path" => "cov.rb" }
      ],
      "facts" => {
        "call_graph_edges" => [
          { "kind" => "internal_call", "source" => "fn:Cov#method1", "target" => "fn:Cov#method2", "conditional" => true }
        ],
        "state_protocol_records" => [
          { "owner" => "Cov", "function" => "method1", "field" => "@state", "protocol" => "each" }
        ],
        "state_param_origin_records" => [
          { "owner" => "Cov", "function" => "method1", "field" => "@state", "param" => "p" }
        ]
      }
    }
    modules = Espalier::StaticEvidence.project_modules(evidence)
    assert_equal 1, modules.length
    assert_equal "Cov", modules.first[:name]
  end

  def test_profile_for_rbi_file_coverage
    evidence = Espalier::StaticEvidence.new([__FILE__], include_annotations: true, language: :ruby)
    Dir.mktmpdir do |dir|
      rbi = File.join(dir, "foo.rbi")
      File.write(rbi, "class Foo; end")
      
      # Mock system to return false
      evidence.define_singleton_method(:system) do |*args|
        false
      end
      
      res = evidence.send(:profile_for_rbi_file, rbi)
      assert_equal [], res
    end
  end

  def test_normalize_methods
    evidence = Espalier::StaticEvidence.new([])
    assert_equal :cpp, evidence.send(:normalize_language, "c++")
    assert_equal :csharp, evidence.send(:normalize_language, "c#")
    assert_equal :typescript, evidence.send(:normalize_language, "ts")
    assert_equal :python, evidence.send(:normalize_language, "py")
    assert_equal :rust, evidence.send(:normalize_language, "rs")
    assert_equal :go, evidence.send(:normalize_language, "golang")
    assert_equal :kotlin, evidence.send(:normalize_language, "kt")
    assert_equal :ruby, evidence.send(:normalize_language, "ruby")
    assert_nil evidence.send(:normalize_language, "  ")
    
    assert_equal :git, evidence.send(:normalize_vcs, "git")
    assert_nil evidence.send(:normalize_vcs, "none")
    assert_nil evidence.send(:normalize_vcs, "")
  end
end
