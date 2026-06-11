# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class PrivacyAnalyzerTest < Minitest::Test
  def test_flags_public_internal_helper_with_no_external_calls
    rows = Espalier::PrivacyAnalyzer.candidates(manifest)

    candidate = rows.find { |row| row[:name] == "prepare_state" }
    refute_nil candidate
    assert_equal :high, candidate[:confidence]
    assert_equal ["run"], candidate[:callers]
    assert_includes candidate[:reason], "single internal caller"
    assert_includes candidate[:reason], "helper-shaped name"
  end

  def test_suppresses_private_public_surface_external_and_weak_shared_helpers
    rows = Espalier::PrivacyAnalyzer.candidates(manifest)
    names = rows.map { |row| row[:name] }

    refute_includes names, "hidden_step"
    refute_includes names, "validate"
    refute_includes names, "run"
    refute_includes names, "visit_Node"
    refute_includes names, "shared_leaf"
  end

  def test_annotates_manifest_quality_metrics
    data = manifest

    Espalier::PrivacyAnalyzer.annotate!(data)
    fn = data.first[:functions].find { |row| row[:name] == "prepare_state" }

    assert_equal true, fn[:quality_metrics][:privacy_candidate]
    assert_operator fn[:quality_metrics][:privacy_score], :>=, 8.0
    assert_equal :high, fn[:quality_metrics][:privacy_confidence]
  end

  def test_threshold_can_be_tuned_for_lower_confidence_rows
    rows = Espalier::PrivacyAnalyzer.candidates(manifest, threshold: 3.0)

    assert_includes rows.map { |row| row[:name] }, "shared_leaf"
  end

  private

  def manifest
    [
      {
        module: "CompilerPhase",
        file: "src/compiler_phase.rb",
        functions: [
          fn("run", calls: %w[prepare_state validate shared_leaf visit_Node]),
          fn(
            "prepare_state",
            visibility: :public,
            callers: ["run"],
            reads: ["@phase"],
            writes: ["@phase"]
          ),
          fn("hidden_step", visibility: :private, callers: ["run"], writes: ["@phase"]),
          fn("validate", visibility: :public, callers: ["run"]),
          fn("visit_Node", visibility: :public, callers: ["run"], writes: ["@node"]),
          fn("shared_leaf", visibility: :public, callers: %w[run inspect_phase])
        ]
      },
      {
        module: "ExternalCaller",
        file: "src/external_caller.rb",
        functions: [
          fn("call_phase", always_calls: ["phase.validate"])
        ]
      }
    ]
  end

  def fn(
    name,
    visibility: :public,
    callers: [],
    calls: [],
    reads: [],
    writes: [],
    always_calls: [],
    quality_metrics: nil
  )
    {
      name: name,
      visibility: visibility,
      EFFECTS: { reads: reads, writes: writes },
      DELEGATIONS: always_calls.empty? ? nil : { always_calls: always_calls },
      CALL_GRAPH: call_graph(callers, calls),
      quality_metrics: quality_metrics
    }.compact
  end

  def call_graph(callers, calls)
    graph = {}
    graph[:internal_callers] = callers unless callers.empty?
    graph[:internal_calls] = calls unless calls.empty?
    graph
  end
end
