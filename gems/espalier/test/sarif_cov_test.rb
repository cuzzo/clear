# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/type_profile"

class SarifCovTest < Minitest::Test
  def test_sarif_document
    rules = [
      { "id" => "rule-1", "name" => "Rule 1", "fullDescription" => { "text" => "Desc" } }
    ]
    results = [
      { "ruleId" => "rule-1", "message" => { "text" => "Found issue" }, "nil_val" => nil, "nested" => { "val" => 1 } }
    ]

    doc = Decomplex::Sarif.document(
      tool_name: "test-tool",
      rules: rules,
      results: results,
      information_uri: "http://example.com",
      properties: { "custom" => true }
    )

    assert_equal "https://json.schemastore.org/sarif-2.1.0.json", doc["$schema"]
    assert_equal "2.1.0", doc["version"]
    run = doc["runs"].first
    assert_equal "test-tool", run.dig("tool", "driver", "name")
    assert_equal "http://example.com", run.dig("tool", "driver", "informationUri")
    assert_equal true, run["properties"]["custom"]
    assert_equal 1, run["results"].length
    assert_equal "rule-1", run["results"].first["ruleId"]
    assert_equal 0, run["results"].first["ruleIndex"]
    assert_nil run["results"].first["nil_val"]
  end
end
