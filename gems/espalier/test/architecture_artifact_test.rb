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

  # Real bug, found auditing C repos: fact-mine's C extractor makes a
  # best-effort guess at an owner for a free function when it can't find a
  # real enclosing struct (e.g. inferring "widget" from a `widget_t*`
  # parameter), and tags that guess "confidence: partial" specifically so
  # consumers can tell it apart from a real, declared type. build rendered
  # every owner identically regardless of confidence, so the heuristic guess
  # became indistinguishable from `widget_t` (a real struct, confidence
  # high) - fabricating an architectural entity, and even misattributing an
  # unrelated free function to it.
  def test_partial_confidence_owners_are_not_rendered_as_owner_nodes
    evidence = {
      "root" => "/repo",
      "corpus" => { "complete" => true },
      "owners" => [
        { "id" => "owner:1", "name" => "widget_t", "kind" => "struct", "confidence" => "high", "language" => "c", "path" => "/repo/widget.c", "line" => 1, "span" => [1, 0, 1, 30] },
        { "id" => "owner:2", "name" => "widget", "kind" => "owner", "confidence" => "partial", "language" => "c", "path" => "/repo/widget.c", "line" => 10, "span" => [10, 0, 12, 1] }
      ],
      "methods" => [
        { "id" => "fn:1", "owner_id" => "owner:1", "owner" => "widget_t", "name" => "widget_init", "language" => "c", "path" => "/repo/widget.c", "line" => 2, "span" => [2, 0, 4, 1] },
        { "id" => "fn:2", "owner_id" => "owner:2", "owner" => "widget", "name" => "add_numbers", "language" => "c", "path" => "/repo/widget.c", "line" => 10, "span" => [10, 0, 12, 1] }
      ],
      "fields" => [],
      "facts" => { "calls" => [], "state_accesses" => [] }
    }

    artifact = Espalier::ArchitectureArtifact.build(evidence, root: "/repo")
    owner_nodes = artifact["nodes"].select { |node| node["kind"] == "owner" }
    assert_equal ["widget_t"], owner_nodes.map { |node| node["name"] },
                 "the partial-confidence 'widget' guess must not become a first-class owner node"

    real_owner_fn = artifact["nodes"].find { |node| node["id"] == "fn:1" }
    assert_equal "owner:1", real_owner_fn["owner_id"]

    guessed_owner_fn = artifact["nodes"].find { |node| node["id"] == "fn:2" }
    assert_nil guessed_owner_fn["owner_id"],
               "a function whose only owner is a partial-confidence guess must not link to a fabricated node"
  end
end
