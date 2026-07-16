# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class ArchitectureArtifactTest < Minitest::Test
  def test_projects_first_class_state_edges_and_citations
    evidence = {
      "root" => "/repo",
      "corpus" => { "complete" => false, "reason" => "subdirectory target" },
      "owners" => [{ "id" => "owner:1", "name" => "Demo", "kind" => "class", "language" => "ruby", "path" => "/repo/demo.rb", "line" => 1, "span" => [1, 0, 8, 3] }],
      "methods" => [{ "id" => "fn:1", "owner_id" => "owner:1", "owner" => "Demo", "name" => "run", "visibility" => "private", "language" => "ruby", "path" => "/repo/demo.rb", "line" => 2, "span" => [2, 0, 5, 3] }],
      "fields" => [{ "id" => "state:1", "owner_id" => "owner:1", "owner" => "Demo", "name" => "@value", "language" => "ruby", "path" => "/repo/demo.rb", "line" => 3, "span" => [3, 2, 3, 8] }],
      "facts" => {
        "calls" => [],
        "state_accesses" => [{ "id" => "edge:1", "function_id" => "fn:1", "state_id" => "state:1", "owner" => "Demo", "function" => "run", "field" => "@value", "receiver" => "self", "kind" => "writes", "path" => "/repo/demo.rb", "line" => 3, "span" => [3, 2, 3, 8], "conditional" => false, "confidence" => "high" }]
      }
    }

    artifact = Espalier::ArchitectureArtifact.build(evidence, root: "/repo", commit: "abc")
    assert_equal "espalier.architecture.v1", artifact["kind"]
    refute artifact.dig("corpus", "complete")
    assert_equal "subdirectory target", artifact.dig("corpus", "completeness_reason")
    assert_equal %w[function owner state], artifact["nodes"].map { |node| node["kind"] }.sort
    edge = artifact["edges"].fetch(0)
    assert_equal ["fn:1", "state:1", "writes"], edge.values_at("source", "target", "kind")
    assert_equal "demo.rb", edge.dig("spans", 0, "path")
    function = artifact["nodes"].find { |node| node["id"] == "fn:1" }
    assert_equal "private", function.dig("metadata", "visibility")
  end
end
