# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/espalier"

class ReporterTest < Minitest::Test
  def test_report_ranks_architecture_specific_findings
    manifest = [
      {
        module: "CompilerPhase",
        file: "src/compiler_phase.rb",
        type: :class,
        state: [
          { name: "@stack", type: "Array", properties: ["protocol interfaces: push, pop, clear"] },
          { name: "@cache", type: "Hash", properties: ["protocol interfaces: [], []="] }
        ],
        functions: [
          {
            name: "coordinate",
            signature: "def coordinate(node)",
            EFFECTS: { reads: ["@stack"], writes: ["@stack", "@cache"] },
            DELEGATIONS: {
              always_calls: ["lower_one", "lower_two", "emit"],
              conditionally_calls: Array.new(12) { |idx| "branch_#{idx}" }
            },
            quality_metrics: { complexity: 8, churn_risk: 0.3 }
          },
          {
            name: "push_state",
            signature: "def push_state(value)",
            EFFECTS: { reads: [], writes: ["@stack"] },
            DELEGATIONS: {}
          }
        ]
      }
    ]

    Dir.mktmpdir do |dir|
      src_dir = File.join(dir, "src")
      FileUtils.mkdir_p(src_dir)
      File.write(File.join(src_dir, "compiler_phase.rb"), <<~RB)
        class CompilerPhase
          def coordinate(node)
          end

          def push_state(value)
          end
        end
      RB

      report = Espalier::Reporter.new(manifest, root: dir, limit: 5).to_markdown

      assert_includes report, "# Espalier Architecture Report"
      assert_includes report, "## State Owner Pressure"
      assert_includes report, "`CompilerPhase#coordinate`"
      assert_includes report, "complexity=8, churn_risk=0.3"
      assert_includes report, "[`src/compiler_phase.rb`](../../src/compiler_phase.rb#L2)"
      assert_includes report, "`@stack`"
      assert_includes report, "wrap protocol in a small lifecycle object"
      assert_includes report, "reify operation variants"
    end
  end

  def test_report_handles_empty_quality_and_missing_source_lines
    manifest = [
      {
        module: "SmallThing",
        file: "src/missing.rb",
        type: :class,
        state: [{ name: "@value", type: "Integer", properties: [] }],
        functions: [
          {
            name: "read",
            signature: "def read",
            EFFECTS: { reads: ["@value"], writes: [] },
            DELEGATIONS: { always_calls: ["Integer.to_s"] }
          }
        ]
      }
    ]

    report = Espalier::Reporter.new(manifest, root: Dir.pwd).to_markdown

    assert_includes report, "SmallThing"
    assert_includes report, "## Run Summary"
    refute_includes report, "#L"
  end

  def test_report_overlays_existing_sibling_reports
    manifest = [
      {
        module: "MIRLoweringExpressions",
        file: "src/mir/lowering/expressions.rb",
        type: :module,
        state: [{ name: "@union_schemas", type: "Hash", properties: [] }],
        functions: [
          {
            name: "lower_smooth",
            signature: "def lower_smooth(node)",
            EFFECTS: { reads: ["@union_schemas"], writes: ["@union_schemas"] },
            DELEGATIONS: { conditionally_calls: Array.new(11) { |idx| "branch_#{idx}" } }
          }
        ]
      }
    ]

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "gems/decomplex"))
      FileUtils.mkdir_p(File.join(dir, "gems/slopcop"))
      FileUtils.mkdir_p(File.join(dir, "gems/boobytrap"))

      File.write(File.join(dir, "gems/decomplex/report.md"), <<~MD)
        - `src/mir/lowering/expressions.rb:484` (lower_smooth) -- **6 detectors** [score 10, 71 findings]: Broken Protocols
      MD
      File.write(File.join(dir, "gems/slopcop/report.md"), <<~MD)
        | 28 | [`src/mir/lowering/expressions.rb:455`](../../src/mir/lowering/expressions.rb#L455) | `lower_smooth` | 0.0508 | **16** |
      MD
      File.write(File.join(dir, "gems/boobytrap/report.md"), <<~MD)
        | 23 | `src/mir/lowering/expressions.rb` | 0.0125 | 0.051 | 24.6% | 153/622 |
      MD

      report = Espalier::Reporter.new(manifest, root: dir).to_markdown

      assert_includes report, "decomplex=6 detectors/score 10"
      assert_includes report, "slopcop=rank 28"
      assert_includes report, "boobytrap=rank 23/hotspot 0.0125"
      assert_includes report, "## Cross-Tool Overlap"
    end
  end
end
