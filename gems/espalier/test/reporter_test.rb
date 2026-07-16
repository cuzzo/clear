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
            line: 2,
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

  def test_report_links_absolute_sources_from_configured_link_base
    Dir.mktmpdir do |dir|
      src_dir = File.join(dir, "src")
      report_dir = File.join(dir, "reports")
      FileUtils.mkdir_p(src_dir)
      FileUtils.mkdir_p(report_dir)
      source = File.join(src_dir, "compiler_phase.rb")
      File.write(source, <<~RB)
        class CompilerPhase
          def coordinate(node)
          end
        end
      RB

      manifest = [
        {
          module: "CompilerPhase",
          file: source,
          type: :class,
          functions: [
            {
              name: "coordinate",
              signature: "def coordinate(node)",
              line: 2,
              EFFECTS: { reads: [], writes: [] },
              DELEGATIONS: { conditionally_calls: Array.new(12) { |idx| "branch_#{idx}" } }
            }
          ]
        }
      ]

      report = Espalier::Reporter.new(manifest, root: dir, link_base: report_dir).to_markdown

      assert_includes report, "[`#{source}`](../src/compiler_phase.rb#L2)"
    end
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

  def test_state_owner_pressure_explicitly_flags_state_heavy_owners
    manifest = [
      {
        module: "StateBucket",
        file: "src/state_bucket.rb",
        type: :class,
        state: Array.new(6) { |idx| { name: "@s#{idx}", type: "Object", properties: [] } },
        functions: Array.new(6) do |idx|
          {
            name: "mutate_#{idx}",
            signature: "def mutate_#{idx}(value)",
            EFFECTS: { reads: [], writes: ["@s#{idx}"] },
            DELEGATIONS: {}
          }
        end
      }
    ]

    report = Espalier::Reporter.new(manifest, root: Dir.pwd).to_markdown

    assert_includes report, "## State Owner Pressure"
    assert_includes report, "flags"
    assert_includes report, "state-heavy"
    assert_includes report, "many-mutators"
  end

  def test_state_owner_pressure_marks_cohesive_value_facades
    manifest = [
      {
        module: "PartShape",
        file: "src/part_shape.rb",
        type: :class,
        state: [],
        functions: %w[raw resolved with].map { |name| mini_fn(name) }
      },
      {
        module: "PartCaps",
        file: "src/part_caps.rb",
        type: :class,
        state: [],
        functions: %w[ownership sync with].map { |name| mini_fn(name) }
      },
      {
        module: "PartPlace",
        file: "src/part_place.rb",
        type: :class,
        state: [],
        functions: %w[provenance with].map { |name| mini_fn(name) }
      },
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
          mini_fn("initialize", writes: %w[@shape @caps @place], calls: %w[PartShape.raw PartCaps.ownership PartPlace.provenance]),
          mini_fn("raw", reads: %w[@shape @caps], calls: %w[PartShape.raw PartCaps.ownership]),
          mini_fn("resolved", reads: %w[@shape], calls: %w[PartShape.resolved]),
          mini_fn("ownership", reads: %w[@caps], calls: %w[PartCaps.ownership]),
          mini_fn("sync", reads: %w[@caps @place], calls: %w[PartCaps.sync PartPlace.provenance]),
          mini_fn("provenance", reads: %w[@place @shape], calls: %w[PartPlace.provenance PartShape.resolved]),
          mini_fn("with_caps", reads: %w[@caps], writes: %w[@caps], calls: %w[PartCaps.with]),
          mini_fn("with_place", reads: %w[@place], writes: %w[@place], calls: %w[PartPlace.with])
        ]
      }
    ]

    report = Espalier::Reporter.new(manifest, root: Dir.pwd).to_markdown

    assert_includes report, "cohesive-value-facade"
    assert_includes report, "delegation is mostly value facade"
  end

  def test_report_lists_owner_state_cohesion_candidates
    manifest = [
      {
        module: "SplitWorkflow",
        file: "src/split_workflow.rb",
        type: :class,
        state: [
          { name: "@parse_cache", type: "Hash", properties: [] },
          { name: "@parse_errors", type: "Array", properties: [] },
          { name: "@emit_buffer", type: "String", properties: [] },
          { name: "@emit_stats", type: "Hash", properties: [] }
        ],
        functions: [
          {
            name: "run",
            visibility: :public,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: { always_calls: %w[parse_input emit_output] },
            CALL_GRAPH: { internal_calls: %w[parse_input emit_output] }
          },
          {
            name: "parse_input",
            visibility: :public,
            EFFECTS: { reads: ["@parse_cache"], writes: ["@parse_errors"] },
            DELEGATIONS: {}
          },
          {
            name: "normalize_input",
            visibility: :public,
            EFFECTS: { reads: ["@parse_errors"], writes: ["@parse_cache"] },
            DELEGATIONS: {}
          },
          {
            name: "emit_output",
            visibility: :public,
            EFFECTS: { reads: ["@emit_buffer"], writes: ["@emit_stats"] },
            DELEGATIONS: {}
          },
          {
            name: "flush_output",
            visibility: :public,
            EFFECTS: { reads: ["@emit_stats"], writes: ["@emit_buffer"] },
            DELEGATIONS: {}
          }
        ]
      }
    ]

    report = Espalier::Reporter.new(manifest, root: Dir.pwd).to_markdown

    assert_includes report, "## Owner State Cohesion"
    assert_includes report, "`SplitWorkflow`"
    assert_includes report, "orchestration-bridges"
    assert_includes report, "`run`"
    assert_includes report, "@parse_cache"
    assert_includes report, "@emit_buffer"
  end

  def test_report_lists_conservative_privatization_candidates
    manifest = [
      {
        module: "CompilerPhase",
        file: "src/compiler_phase.rb",
        type: :class,
        functions: [
          {
            name: "run",
            signature: "def run(node)",
            visibility: :public,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: { always_calls: ["prepare", "validate"] },
            CALL_GRAPH: { internal_calls: ["prepare", "validate"] }
          },
          {
            name: "prepare",
            signature: "def prepare(node)",
            visibility: :public,
            EFFECTS: { reads: ["@state"], writes: ["@state"] },
            DELEGATIONS: {},
            CALL_GRAPH: { internal_callers: ["run"] }
          },
          {
            name: "validate",
            signature: "def validate(node)",
            visibility: :public,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: {},
            CALL_GRAPH: { internal_callers: ["run"] }
          }
        ]
      },
      {
        module: "ExternalUser",
        file: "src/external_user.rb",
        type: :class,
        functions: [
          {
            name: "call_phase",
            signature: "def call_phase(phase)",
            visibility: :public,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: { always_calls: ["phase.validate"] }
          }
        ]
      }
    ]

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src/compiler_phase.rb"), <<~RB)
        class CompilerPhase
          def run(node); end
          def prepare(node); end
          def validate(node); end
        end
      RB

      report = Espalier::Reporter.new(manifest, root: dir, closed_world: true).to_markdown

      assert_includes report, "## Privatization Candidates"
      assert_includes report, "`CompilerPhase#prepare`"
      assert_includes report, "medium"
      assert_includes report, "public but only has same-owner callers"
      refute_includes report, "`CompilerPhase#validate`"
    end
  end

  private

  def mini_fn(name, reads: [], writes: [], calls: [])
    {
      name: name,
      visibility: :public,
      EFFECTS: { reads: reads, writes: writes },
      DELEGATIONS: { always_calls: calls },
      CALL_GRAPH: {}
    }
  end
end
