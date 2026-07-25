# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/espalier"

class ArchitectureArtifactTest < Minitest::Test
  def test_emits_import_edges_scanned_from_source
    Dir.mktmpdir do |root|
      File.write(File.join(root, "svc.go"), <<~GO)
        package svc

        import (
          "fmt"
          "os/exec"
        )

        import "strings"

        func Run() { fmt.Println("x") }
      GO
      evidence = {
        "root" => root,
        "corpus" => { "complete" => true },
        "owners" => [],
        "methods" => [{ "id" => "fn:1", "owner" => "svc", "name" => "Run", "language" => "go",
                        "path" => File.join(root, "svc.go"), "line" => 10, "span" => [10, 0, 10, 30] }],
        "fields" => [],
        "facts" => { "calls" => [], "state_accesses" => [] }
      }
      artifact = Espalier::ArchitectureArtifact.build(evidence, root: root, commit: "abc")
      imports = artifact["edges"].select { |edge| edge["kind"] == "imports" }
      modules = imports.map { |edge| edge.dig("metadata", "module") }.sort
      assert_equal ["fmt", "os/exec", "strings"], modules
      # Each import edge carries the source line and targets a named module node.
      fmt = imports.find { |edge| edge.dig("metadata", "module") == "fmt" }
      assert_equal "svc.go", fmt.dig("spans", 0, "path")
      assert_equal 4, fmt.dig("spans", 0, "start_line")
      target = artifact["nodes"].find { |node| node["id"] == fmt["target"] }
      assert_equal "fmt", target["name"]
    end
  end

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

  def test_big_o_index_uses_the_known_component_when_the_bound_is_incomplete
    manifest = [
      {
        file: "lib/x.rb",
        functions: [
          { name: "proven",
            quality_metrics: { big_o: "O(1)", big_o_complete: true,
                               big_o_space: "O(1)", big_o_space_complete: true } },
          { name: "looped",
            quality_metrics: { big_o: "unknown", big_o_known_component: "O(N^2)",
                               big_o_complete: false } },
          { name: "opaque",
            quality_metrics: { big_o: "unknown", big_o_complete: false } }
        ]
      }
    ]
    index = Espalier::ArchitectureArtifact.big_o_index(manifest)

    proven = index["lib/x.rb\u0000proven"]
    assert_equal "O(1)", proven["big_o_time"]
    assert_equal true, proven["time_complete"]

    # A known-but-incomplete bound surfaces as a partial bound, not "unknown".
    looped = index["lib/x.rb\u0000looped"]
    assert_equal "O(N^2)", looped["big_o_time"]
    assert_equal false, looped["time_complete"]

    # No bound at all is not indexed.
    assert_nil index["lib/x.rb\u0000opaque"]
  end


  def test_big_o_index_threads_status_and_provenance
    manifest = [
      {
        file: "x.go",
        functions: [
          { name: "each",
            quality_metrics: { big_o: "O(N * C)", big_o_complete: true,
                               big_o_status: :parametric } },
          { name: "Sort",
            quality_metrics: { big_o: "O(N log N)", big_o_complete: true,
                               big_o_status: :complete_override,
                               big_o_provenance: :manual_override } }
        ]
      }
    ]
    index = Espalier::ArchitectureArtifact.big_o_index(manifest)
    each = index.values.find { |node| node["big_o_time"] == "O(N * C)" }
    sort = index.values.find { |node| node["big_o_provenance"] }

    assert_equal "parametric", each["big_o_status"]
    assert_equal "complete_override", sort["big_o_status"]
    assert_equal "manual_override", sort["big_o_provenance"]
    refute each.key?("big_o_provenance")
  end

end
