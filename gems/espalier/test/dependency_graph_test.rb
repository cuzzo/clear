# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class DependencyGraphTest < Minitest::Test
  def test_dot_output_renders_owner_function_and_dependency_edges
    dot = Espalier::Formatter.to_dot(service_manifest)

    assert_includes dot, "digraph espalier_dependencies"
    assert_includes dot, "\"cluster_Service\""
    assert_includes dot, "\"owner:Service\""
    assert_includes dot, "\"fn:Service#run\""
    assert_includes dot, "\"fn:Repository#fetch\""
    assert_includes dot, "\"fn:Service#run\" -> \"fn:Service#prepare\""
    assert_includes dot, "label=\"internal x2\""
    assert_includes dot, "\"fn:Service#run\" -> \"fn:Repository#fetch\""
    assert_includes dot, "label=\"calls fetch\""
    assert_includes dot, "\"fn:Service#run\" -> \"fn:Repository#retry\""
    assert_includes dot, "label=\"conditional calls retry\""
    assert_includes dot, "style=\"dashed\""
    assert_includes dot, "\"owner:Service\" -> \"owner:Repository\""
    assert_includes dot, "label=\"state @repo\""
    assert_includes dot, "style=\"dotted\""
    refute_includes dot, "external:String"
  end

  def test_graph_aggregates_duplicate_internal_edges
    graph = Espalier::DependencyGraph.from_manifest(service_manifest)
    edges = graph.edges.select do |edge|
      edge.source == "fn:Service#run" &&
        edge.target == "fn:Service#prepare" &&
        edge.kind == :internal_call
    end

    assert_equal 1, edges.size
    assert_equal 2, edges.first.weight
  end

  def test_dot_output_escapes_labels_and_tooltips
    manifest = [
      {
        module: "Quoted\"Owner",
        file: "src/quoted.rb",
        type: :class,
        functions: [
          {
            name: "say_\"hello\"",
            signature: "def say_\"hello\"",
            line: 3,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: {}
          }
        ]
      }
    ]

    dot = Espalier::Formatter.to_dot(manifest)

    assert_includes dot, "\"owner:Quoted\\\"Owner\""
    assert_includes dot, "label=\"Quoted\\\"Owner"
    assert_includes dot, "say_\\\"hello\\\""
  end

  def test_string_key_manifest_from_yaml_is_supported
    manifest = [
      {
        "module" => "Client",
        "file" => "src/client.rb",
        "type" => "class",
        "state" => [{ "name" => "@server", "type" => "Server" }],
        "functions" => [
          {
            "name" => "call",
            "line" => 5,
            "EFFECTS" => { "reads" => ["@server"], "writes" => [] },
            "DELEGATIONS" => { "always_calls" => ["@server.handle"] }
          }
        ]
      },
      {
        "module" => "Server",
        "file" => "src/server.rb",
        "type" => "class",
        "functions" => [
          {
            "name" => "handle",
            "EFFECTS" => { "reads" => [], "writes" => [] },
            "DELEGATIONS" => {}
          }
        ]
      }
    ]

    dot = Espalier::Formatter.to_dot(manifest)

    assert_includes dot, "\"fn:Client#call\" -> \"fn:Server#handle\""
    assert_includes dot, "URL=\"src/client.rb#L5\""
  end

  def test_cycles_are_highlighted
    dot = Espalier::Formatter.to_dot(
      [
        owner("A", calls: ["B.call"]),
        owner("B", calls: ["A.call"])
      ]
    )

    assert_includes dot, "\"fn:A#call\" -> \"fn:B#call\""
    assert_includes dot, "\"fn:B#call\" -> \"fn:A#call\""
    assert_includes dot, "penwidth=2.0"
    assert_includes dot, "color=\"#b91c1c\""
  end

  private

  def service_manifest
    [
      {
        module: "Service",
        file: "src/service.rb",
        type: :class,
        line: 1,
        state: [{ name: "@repo", type: "Repository", properties: [] }],
        functions: [
          {
            name: "run",
            signature: "def run",
            visibility: :public,
            line: 4,
            EFFECTS: { reads: ["@repo"], writes: [] },
            DELEGATIONS: {
              always_calls: ["prepare", "@repo.fetch", "String.upcase"],
              conditionally_calls: ["Repository.retry"]
            },
            CALL_GRAPH: { internal_calls: ["prepare"] }
          },
          {
            name: "prepare",
            signature: "def prepare",
            visibility: :private,
            line: 10,
            EFFECTS: { reads: [], writes: ["@repo"] },
            DELEGATIONS: {},
            CALL_GRAPH: { internal_callers: ["run"] }
          }
        ],
        call_graph: {
          internal_edges: [{ caller: "run", callee: "prepare", type: :always }]
        }
      },
      {
        module: "Repository",
        file: "src/repository.rb",
        type: :class,
        state: [],
        functions: [
          {
            name: "fetch",
            signature: "def fetch",
            visibility: :public,
            line: 3,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: {}
          },
          {
            name: "retry",
            signature: "def retry",
            visibility: :public,
            line: 8,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: {}
          }
        ]
      }
    ]
  end

  def owner(name, calls:)
    {
      module: name,
      file: "src/#{name.downcase}.rb",
      type: :class,
      functions: [
        {
          name: "call",
          EFFECTS: { reads: [], writes: [] },
          DELEGATIONS: { always_calls: calls }
        }
      ]
    }
  end
end
