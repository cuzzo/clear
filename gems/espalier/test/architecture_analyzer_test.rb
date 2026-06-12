# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class ArchitectureAnalyzerTest < Minitest::Test
  def test_detects_cohesive_value_facade_without_flagging_split_state_coordinator
    analyzer = Espalier::ArchitectureAnalyzer.new(value_facade_manifest + split_coordinator_manifest)
    profiles = analyzer.cohesive_value_facade_profiles

    facade = profiles["ValueFacade"]
    refute_nil facade
    assert_in_delta 1.0, facade[:discountable_call_ratio], 0.01
    assert_operator facade[:delegation_discount], :>, 0
    assert_equal %w[PartCaps PartPlace PartShape], facade[:state_targets]

    assert_nil profiles["SplitCoordinator"]
  end

  def test_encapsulation_pressure_marks_facade_but_keeps_public_surface_signal
    rows = Espalier::ArchitectureAnalyzer.new(value_facade_manifest).encapsulation_pressure(threshold: 0)
    row = rows.find { |candidate| candidate[:owner] == "ValueFacade" }

    refute_nil row
    assert_includes row[:flags], "cohesive-value-facade"
    assert_operator row[:public_methods], :>=, 8
    assert_operator row[:score], :>, 0
  end

  private

  def value_facade_manifest
    [
      value_object("PartShape", methods: %w[raw resolved with]),
      value_object("PartCaps", methods: %w[ownership sync with]),
      value_object("PartPlace", methods: %w[provenance with]),
      {
        module: "ValueFacade",
        file: "src/value_facade.rb",
        type: :class,
        state: [
          { name: "@shape", type: "PartShape", properties: [] },
          { name: "@caps", type: "PartCaps", properties: [] },
          { name: "@place", type: "PartPlace", properties: [] }
        ],
        functions: [
          fn("initialize", writes: %w[@shape @caps @place], calls: %w[PartShape.raw PartCaps.ownership PartPlace.provenance]),
          fn("raw", reads: %w[@shape @caps], calls: %w[PartShape.raw PartCaps.ownership]),
          fn("resolved", reads: %w[@shape], calls: %w[PartShape.resolved]),
          fn("ownership", reads: %w[@caps], calls: %w[PartCaps.ownership]),
          fn("sync", reads: %w[@caps @place], calls: %w[PartCaps.sync PartPlace.provenance]),
          fn("provenance", reads: %w[@place @shape], calls: %w[PartPlace.provenance PartShape.resolved]),
          fn("with_caps", reads: %w[@caps], writes: %w[@caps], calls: %w[PartCaps.with]),
          fn("with_place", reads: %w[@place], writes: %w[@place], calls: %w[PartPlace.with])
        ]
      }
    ]
  end

  def split_coordinator_manifest
    [
      value_object("ParseHelper", methods: %w[read write]),
      value_object("EmitHelper", methods: %w[read write]),
      value_object("CheckHelper", methods: %w[read write]),
      {
        module: "SplitCoordinator",
        file: "src/split_coordinator.rb",
        type: :class,
        state: [
          { name: "@parse", type: "ParseHelper", properties: [] },
          { name: "@emit", type: "EmitHelper", properties: [] },
          { name: "@check", type: "CheckHelper", properties: [] }
        ],
        functions: [
          fn("parse_a", reads: %w[@parse], calls: %w[ParseHelper.read]),
          fn("parse_b", writes: %w[@parse], calls: %w[ParseHelper.write]),
          fn("emit_a", reads: %w[@emit], calls: %w[EmitHelper.read]),
          fn("emit_b", writes: %w[@emit], calls: %w[EmitHelper.write]),
          fn("check_a", reads: %w[@check], calls: %w[CheckHelper.read]),
          fn("check_b", writes: %w[@check], calls: %w[CheckHelper.write]),
          fn("run", calls: %w[parse_a emit_a check_a]),
          fn("reset", calls: %w[parse_b emit_b check_b])
        ]
      }
    ]
  end

  def value_object(name, methods:)
    {
      module: name,
      file: "src/#{name.downcase}.rb",
      type: :class,
      state: [],
      functions: methods.map { |method_name| fn(method_name) }
    }
  end

  def fn(name, reads: [], writes: [], calls: [])
    {
      name: name,
      visibility: :public,
      EFFECTS: { reads: reads, writes: writes },
      DELEGATIONS: { always_calls: calls },
      CALL_GRAPH: {}
    }
  end
end
