# frozen_string_literal: true

require_relative "../gems/espalier/lib/espalier"

RSpec.describe Espalier::ArchitectureAnalyzer do
  def fn(
    name,
    visibility: :public,
    reads: [],
    writes: [],
    calls: [],
    conditional_calls: [],
    callers: [],
    internal_calls: []
  )
    delegations = {}
    delegations[:always_calls] = calls unless calls.empty?
    delegations[:conditionally_calls] = conditional_calls unless conditional_calls.empty?
    graph = {}
    graph[:internal_callers] = callers unless callers.empty?
    graph[:internal_calls] = internal_calls unless internal_calls.empty?
    {
      name: name,
      visibility: visibility,
      EFFECTS: { reads: reads, writes: writes },
      DELEGATIONS: delegations.empty? ? nil : delegations,
      CALL_GRAPH: graph.empty? ? nil : graph
    }.compact
  end

  it "flags public mutable state pressure while suppressing simple data carriers" do
    manifest = [
      {
        module: "OverPublicPhase",
        file: "src/over_public_phase.rb",
        state: [
          { name: "@context", type: "Object", properties: [] },
          { name: "@cache", type: "Hash", properties: [] },
          { name: "@status", type: "Symbol", properties: [] },
          { name: "@frames", type: "Array", properties: ["protocol interfaces: push, pop"] }
        ],
        functions: [
          fn("run", writes: ["@status"], calls: %w[prepare_state validate_state], internal_calls: %w[prepare_state validate_state]),
          fn("prepare_state", reads: ["@context"], writes: ["@cache", "@frames"], callers: ["run"]),
          fn("validate_state", reads: ["@cache", "@status"], callers: ["run"]),
          fn("publish_state", reads: ["@frames"], writes: ["@status"]),
          fn("hidden_step", visibility: :private, writes: ["@status"])
        ]
      },
      {
        module: "DataRecord",
        file: "src/data_record.rb",
        state: [
          { name: "@name", type: "String", properties: [] },
          { name: "@age", type: "Integer", properties: [] }
        ],
        functions: [
          fn("initialize", writes: %w[@name @age]),
          fn("name", reads: ["@name"]),
          fn("age", reads: ["@age"])
        ]
      }
    ]

    rows = described_class.encapsulation_pressure(manifest, threshold: 10.0)
    owners = rows.map { |row| row[:owner] }
    over_public = rows.find { |row| row[:owner] == "OverPublicPhase" }

    expect(owners).to include("OverPublicPhase")
    expect(owners).not_to include("DataRecord")
    expect(over_public[:flags]).to include("public-state-surface")
    expect(over_public[:flags]).to include("public-mutators")
    expect(over_public[:privacy_candidates]).to include("prepare_state")
  end

  it "detects broad collaboration hubs and missing mediator candidates" do
    target_owners = %w[
      CheckoutTaxRules
      CheckoutInvoiceFormatter
      CheckoutPaymentGateway
      CheckoutReceiptPublisher
      CheckoutAuditLog
      CheckoutFraudScreen
    ]
    manifest = [
      {
        module: "CheckoutFlow",
        file: "src/checkout_flow.rb",
        state: [{ name: "@cart", type: "Object", properties: [] }],
        functions: [
          fn(
            "run",
            reads: ["@cart"],
            writes: ["@cart"],
            calls: target_owners.map { |owner| "#{owner}.new" }
          )
        ]
      }
    ] + target_owners.map do |owner|
      {
        module: owner,
        file: "src/#{owner.gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase}.rb",
        functions: [fn("call")]
      }
    end

    meshes = described_class.collaboration_meshes(manifest, threshold: 20.0)
    mediators = described_class.mediator_candidates(manifest, threshold: 20.0)

    expect(meshes.first[:kind]).to eq(:hub)
    expect(meshes.first[:driver]).to eq("CheckoutFlow")
    expect(meshes.first[:fan_out]).to eq(6)
    expect(mediators.first[:common_terms]).to include("checkout")
    expect(mediators.first[:suggestion]).to include("Checkout coordinator/context")
  end

  it "detects dense owner cycles separately from one-way hub fan-out" do
    manifest = [
      {
        module: "AlphaParser",
        file: "src/alpha_parser.rb",
        functions: [fn("run", calls: %w[BetaParser.step GammaParser.step])]
      },
      {
        module: "BetaParser",
        file: "src/beta_parser.rb",
        functions: [fn("step", calls: %w[AlphaParser.run GammaParser.step])]
      },
      {
        module: "GammaParser",
        file: "src/gamma_parser.rb",
        functions: [fn("step", calls: %w[AlphaParser.run BetaParser.step])]
      }
    ]

    dense = described_class.collaboration_meshes(manifest, threshold: 0.0).find do |row|
      row[:kind] == :dense_cycle
    end

    expect(dense).not_to be_nil
    expect(dense[:owners]).to contain_exactly("AlphaParser", "BetaParser", "GammaParser")
    expect(dense[:bidirectional_pairs]).to eq(3)
  end

  it "flags split owner state cohesion without letting orchestration calls hide the split" do
    manifest = [
      {
        module: "SplitWorkflow",
        file: "src/split_workflow.rb",
        state: [
          { name: "@parse_cache", type: "Hash", properties: [] },
          { name: "@parse_errors", type: "Array", properties: [] },
          { name: "@emit_buffer", type: "String", properties: [] },
          { name: "@emit_stats", type: "Hash", properties: [] }
        ],
        functions: [
          fn(
            "run",
            calls: %w[parse_input emit_output],
            internal_calls: %w[parse_input emit_output]
          ),
          fn("parse_input", reads: ["@parse_cache"], writes: ["@parse_errors"]),
          fn("normalize_input", reads: ["@parse_errors"], writes: ["@parse_cache"]),
          fn("emit_output", reads: ["@emit_buffer"], writes: ["@emit_stats"]),
          fn("flush_output", reads: ["@emit_stats"], writes: ["@emit_buffer"])
        ]
      }
    ]

    rows = described_class.owner_state_cohesion(manifest, threshold: 0.0)
    row = rows.fetch(0)

    expect(row[:owner]).to eq("SplitWorkflow")
    expect(row[:component_count]).to eq(2)
    expect(row[:bridge_methods]).to include("run")
    expect(row[:flags]).to include("orchestration-bridges")
    expect(row[:component_samples].map { |sample| sample[:states] }).to include(
      include("@parse_cache", "@parse_errors"),
      include("@emit_buffer", "@emit_stats")
    )
  end

  it "suppresses data carriers and isolated field accessors" do
    manifest = [
      {
        module: "DataRecord",
        file: "src/data_record.rb",
        state: [
          { name: "@name", type: "String", properties: [] },
          { name: "@age", type: "Integer", properties: [] },
          { name: "@active", type: "T::Boolean", properties: [] }
        ],
        functions: [
          fn("initialize", writes: %w[@name @age @active]),
          fn("name", reads: ["@name"]),
          fn("age", reads: ["@age"]),
          fn("active?", reads: ["@active"])
        ]
      }
    ]

    rows = described_class.owner_state_cohesion(manifest, threshold: 0.0)

    expect(rows).to be_empty
  end
end

RSpec.describe Espalier::Reporter do
  it "renders macro architecture sections" do
    manifest = [
      {
        module: "StatefulFacade",
        file: "src/stateful_facade.rb",
        state: Array.new(4) { |idx| { name: "@s#{idx}", type: "Object", properties: [] } },
        functions: [
          {
            name: "run",
            visibility: :public,
            EFFECTS: { reads: [], writes: [] },
            DELEGATIONS: { always_calls: %w[mutate_a mutate_c] },
            CALL_GRAPH: { internal_calls: %w[mutate_a mutate_c] }
          },
          {
            name: "mutate_a",
            visibility: :public,
            EFFECTS: { reads: ["@s0"], writes: ["@s1"] }
          },
          {
            name: "mutate_b",
            visibility: :public,
            EFFECTS: { reads: ["@s1"], writes: ["@s0"] }
          },
          {
            name: "mutate_c",
            visibility: :public,
            EFFECTS: { reads: ["@s2"], writes: ["@s3"] }
          },
          {
            name: "mutate_d",
            visibility: :public,
            EFFECTS: { reads: ["@s3"], writes: ["@s2"] }
          }
        ]
      }
    ]

    report = described_class.new(manifest, root: Dir.pwd).to_markdown

    expect(report).to include("## Encapsulation Pressure")
    expect(report).to include("## Owner State Cohesion")
    expect(report).to include("## Collaboration Meshes")
    expect(report).to include("## Mediator/Reification Candidates")
    expect(report).to include("`StatefulFacade`")
    expect(report).to include("orchestration-bridges")
  end
end
