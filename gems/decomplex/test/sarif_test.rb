# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/decomplex/sarif"

class SarifTest < Minitest::Test
  def test_empty_result_runs_keep_required_results_array
    sarif = Decomplex::Sarif.document(
      tool_name: "Empty Tool",
      rules: [],
      results: [],
      properties: { "format" => "empty.sarif.v1" }
    )
    run = sarif.fetch("runs").first

    assert_equal [], run.fetch("results")
    assert_equal "Empty Tool", run.dig("tool", "driver", "name")
  end
end
