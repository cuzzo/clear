# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::Report do
  it "ranks roots by transitive return and param impact" do
    report = described_class.new
    allow(report).to receive(:return_usage_by_name).and_return({})

    origins = [
      {
        "path" => "src/example.rb", "line" => 10, "class" => "Example", "method" => "base",
        "sources" => [{ "kind" => "call_untyped", "callee" => "mystery", "line" => 11 }],
        "blockers" => [],
      },
      {
        "path" => "src/example.rb", "line" => 20, "class" => "Example", "method" => "mid",
        "sources" => [{ "kind" => "call_untyped", "callee" => "base", "line" => 21 }],
        "blockers" => [],
      },
      {
        "path" => "src/example.rb", "line" => 30, "class" => "Example", "method" => "top",
        "sources" => [{ "kind" => "call_untyped", "callee" => "mid", "line" => 31 }],
        "blockers" => [],
      },
      {
        "path" => "src/example.rb", "line" => 40, "class" => "Example", "method" => "sibling",
        "sources" => [{ "kind" => "call_untyped", "callee" => "mystery", "line" => 41 }],
        "blockers" => [],
      },
    ]
    evidence = {
      "methods" => origins.map do |origin|
        { "source" => { "method" => origin["method"], "class" => origin["class"], "path" => origin["path"], "line" => origin["line"] } }
      end,
      "facts" => {
        "param_origins" => [
          { "origin_kind" => "untyped_return", "source_method" => "mid", "path" => "src/use.rb", "line" => 5, "callee" => "consume", "slot" => "0" },
          { "origin_kind" => "untyped_return", "source_method" => "top", "path" => "src/use.rb", "line" => 6, "callee" => "consume", "slot" => "1" },
        ],
      },
    }

    pressure = report.return_cascade_pressure(origins, evidence).to_h

    expect(pressure.fetch("untyped callee mystery")["returns"].size).to eq(4)
    expect(pressure.fetch("untyped callee mystery")["direct"].size).to eq(2)
    expect(pressure.fetch("untyped callee mystery")["cascade"].size).to eq(2)
    expect(pressure.fetch("untyped callee mystery")["params"].size).to eq(2)
    expect(pressure.fetch("untyped callee base")["returns"].size).to eq(2)
  end

  it "does not cascade through ambiguous method names" do
    report = described_class.new
    allow(report).to receive(:return_usage_by_name).and_return({})

    origins = [
      {
        "path" => "src/a.rb", "line" => 10, "class" => "A", "method" => "value",
        "sources" => [{ "kind" => "nil", "line" => 11 }],
        "blockers" => [],
      },
      {
        "path" => "src/b.rb", "line" => 20, "class" => "B", "method" => "value",
        "sources" => [{ "kind" => "nil", "line" => 21 }],
        "blockers" => [],
      },
      {
        "path" => "src/use.rb", "line" => 30, "class" => "Use", "method" => "consumer",
        "sources" => [{ "kind" => "call_untyped", "callee" => "value", "line" => 31 }],
        "blockers" => [],
      },
    ]
    evidence = {
      "methods" => origins.map do |origin|
        { "source" => { "method" => origin["method"], "class" => origin["class"], "path" => origin["path"], "line" => origin["line"] } }
      end,
      "facts" => {
        "param_origins" => [
          { "origin_kind" => "untyped_return", "source_method" => "value", "path" => "src/use.rb", "line" => 40, "callee" => "consume", "slot" => "0" },
        ],
      },
    }

    pressure = report.return_cascade_pressure(origins, evidence).to_h

    expect(pressure.fetch("nil return at src/a.rb:11")["returns"].size).to eq(1)
    expect(pressure.fetch("nil return at src/a.rb:11")["cascade"].size).to eq(0)
    expect(pressure.fetch("nil return at src/a.rb:11")["params"].size).to eq(0)
  end

  it "reports forwarded-return blocker pressure by callee status" do
    report = described_class.new
    origins = [
      { "path" => "src/a.rb", "line" => 10, "class" => "A", "method" => "wrapper", "kind" => "instance",
        "sources" => [{ "kind" => "call_untyped", "callee" => "leaf" }] },
      { "path" => "src/a.rb", "line" => 20, "class" => "A", "method" => "other_wrapper", "kind" => "instance",
        "sources" => [{ "kind" => "call_untyped", "callee" => "leaf" }] },
      { "path" => "src/a.rb", "line" => 30, "class" => "A", "method" => "ambiguous_wrapper", "kind" => "instance",
        "sources" => [{ "kind" => "call_untyped", "callee" => "dup_name" }] },
      { "path" => "src/a.rb", "line" => 40, "class" => "A", "method" => "same_type_ambiguous_wrapper", "kind" => "instance",
        "sources" => [{ "kind" => "call_untyped", "callee" => "dup_same_type" }] },
    ]
    evidence = {
      "facts" => {
        "existing_sigs" => [
          { "method" => "leaf", "sig" => "sig { returns(String) }" },
          { "method" => "dup_name", "sig" => "sig { returns(T.untyped) }" },
          { "method" => "dup_name", "sig" => "sig { returns(T.untyped) }" },
          { "method" => "dup_same_type", "sig" => "sig { returns(String) }" },
          { "method" => "dup_same_type", "sig" => "sig { returns(String) }" },
        ],
        "return_origins" => [
          { "method" => "dup_name", "candidate_type" => "String" },
          { "method" => "dup_name", "candidate_type" => "Integer" },
        ],
        "param_origins" => [
          { "origin_kind" => "untyped_return", "source_method" => "leaf", "path" => "src/use.rb", "line" => 40, "callee" => "sink", "slot" => "0" },
        ],
      },
    }

    pressure = report.forwarded_return_blocker_pressure(origins, evidence)

    expect(pressure.fetch("leaf")).to include("status" => "typed signature String")
    expect(pressure.fetch("leaf")["returns"].size).to eq(2)
    expect(pressure.fetch("leaf")["params"].size).to eq(1)
    expect(pressure.fetch("dup_name")).to include("status" => "ambiguous method name")
    expect(pressure.fetch("dup_same_type")).to include("status" => "unresolved forwarded callee")
  end

  it "categorizes untyped return sources for report triage" do
    report = described_class.new

    expect(report.untyped_return_source_category(
      "return_origin" => { "sources" => [{ "kind" => "ivar_read" }] }
    )).to eq("untyped instance variable")
    expect(report.untyped_return_source_category(
      "return_origin" => { "sources" => [{ "kind" => "call_untyped", "callee" => "fetch" }] }
    )).to eq("untyped forwarded return")
    expect(report.untyped_return_source_category(
      "return_origin" => { "candidate_type" => "T::Array[T.untyped]", "sources" => [{ "kind" => "static", "type" => "T::Array[T.untyped]" }] }
    )).to eq("untyped struct/array/collection value")
    expect(report.untyped_return_source_category(
      "return_origin" => { "sources" => [{ "kind" => "static", "type" => "String" }] }
    )).to eq("untyped literal/static expression")
  end

  it "categorizes untyped param sources for report triage" do
    report = described_class.new

    expect(report.untyped_param_source_category([
      { "origin_kind" => "unknown", "code" => "@cached" },
    ])).to eq("untyped instance variable")
    expect(report.untyped_param_source_category([
      { "origin_kind" => "untyped_return", "code" => "build_value" },
    ])).to eq("untyped forwarded return")
    expect(report.untyped_param_source_category([
      { "origin_kind" => "static", "type" => "T::Array[T.untyped]", "code" => "[]" },
    ])).to eq("untyped struct/array/collection value")
    expect(report.untyped_param_source_category([
      { "origin_kind" => "static", "type" => "String", "code" => "\"x\"" },
    ])).to eq("untyped literal/static expression")
  end

  it "attributes singular unknown expression causes and separates mixed causes" do
    report = described_class.new

    expect(report.unknown_expression_bucket(["forwarded return build"])).to eq("unknown forwarded return build")
    expect(report.unknown_expression_bucket(["instance variable @cached"])).to eq("unknown instance variable @cached")
    expect(report.unknown_expression_bucket(["struct/array/collection value Array"])).to eq("unknown struct/array/collection value Array")
    expect(report.unknown_expression_bucket(["literal/static expression class constant String"])).to eq("unknown literal/static expression class constant String")
    expect(report.unknown_expression_bucket(["operation CallNode", "forwarded return build"])).to eq("unknown forwarded return build")
    expect(report.unknown_expression_bucket(["operation RangeNode", "literal/static expression Integer"])).to eq("unknown operation RangeNode")
    expect(report.unknown_expression_bucket(["forwarded return build", "instance variable @cached"])).to eq("unknown expression with multiple unknown types")
  end

  it "only reports param unknown causes for untyped parameter slots" do
    report = described_class.new
    slots = report.untyped_param_slot_keys([
      { "method" => "target", "sig" => "sig { params(value: T.untyped, typed: String).void }" },
    ])

    expect(report.untyped_param_origin?({ "callee" => "target", "slot" => "value" }, slots)).to eq(true)
    expect(report.untyped_param_origin?({ "callee" => "target", "slot" => "0" }, slots)).to eq(true)
    expect(report.untyped_param_origin?({ "callee" => "target", "slot" => "typed" }, slots)).to eq(false)
    expect(report.untyped_param_origin?({ "callee" => "other", "slot" => "value" }, slots)).to eq(false)
  end

  it "excludes already resolved signature slots from callsite pressure" do
    report = described_class.new
    report.instance_variable_set(:@evidence, {
      "facts" => {
        "existing_sigs" => [
          { "path" => "src/a.rb", "line" => 10, "params" => [
            { "name" => "already_nilable", "type" => "T.nilable(String)" },
            { "name" => "needs_nilable", "type" => "String" },
            { "name" => "already_typed", "type" => "String" },
            { "name" => "needs_union", "type" => "T.untyped" },
          ] },
        ],
        "unsigned_methods" => [],
      },
    })

    nil_pressure = report.send(:callsite_pressure, [
      { "kind" => "nil_param_observed", "path" => "src/a.rb", "line" => 10, "data" => {
        "name" => "already_nilable", "callsites" => { "src/root.rb:1:NilClass" => 10 },
      } },
      { "kind" => "nil_param_observed", "path" => "src/a.rb", "line" => 10, "data" => {
        "name" => "needs_nilable", "callsites" => { "src/root.rb:2:NilClass" => 5 },
      } },
    ], "nil_param_observed")

    union_pressure = report.send(:callsite_pressure, [
      { "kind" => "union_observed", "path" => "src/a.rb", "line" => 10, "data" => {
        "name" => "already_typed", "callsites" => { "src/root.rb:3:String" => 10 },
      } },
      { "kind" => "union_observed", "path" => "src/a.rb", "line" => 10, "data" => {
        "name" => "needs_union", "callsites" => { "src/root.rb:4:String" => 5 },
      } },
    ], "union_observed")

    expect(nil_pressure.keys).to eq(["src/root.rb:2"])
    expect(union_pressure.keys).to eq(["src/root.rb:4"])
  end

  it "summarizes weak collection slots and runtime candidates" do
    report = described_class.new
    evidence = {
      "methods" => [
        {
          "source" => { "path" => "src/a.rb", "line" => 10 },
          "calls" => 5,
          "param_elem" => { "items" => ["String"] },
          "param_kv" => { "map" => [["String"], ["Integer"]] },
          "param_elem_shapes" => {},
          "param_kv_shapes" => {
            "map" => [
              [{ "kind" => "class", "name" => "String" }],
              [
                {
                  "kind" => "array",
                  "elements" => [{ "kind" => "class", "name" => "Integer" }],
                },
              ],
            ],
          },
          "return_elem" => ["Symbol"],
          "return_kv" => [[], []],
          "return_elem_shapes" => [],
          "return_kv_shapes" => [[], []],
        },
      ],
      "facts" => {
        "existing_sigs" => [
          { "path" => "src/a.rb", "line" => 10, "class" => "A", "method" => "m",
            "sig" => "sig { params(items: T::Array[T.untyped], map: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }" },
        ],
      },
    }

    slots = report.collection_signature_slots(evidence)
    candidates = slots.filter_map { |slot| report.collection_slot_candidate(slot) }

    expect(slots.map { |slot| [slot["slot_kind"], slot["slot"], slot.dig("info", "kind"), slot.dig("info", "weak")] }).to include(
      ["param", "items", "array", true],
      ["param", "map", "hash", true],
      ["return", "return", "array", true]
    )
    expect(candidates.map { |candidate| [candidate["slot"], candidate["candidate"]] }).to include(
      ["items", "T::Array[String]"],
      ["map", "T::Hash[String, T::Array[Integer]]"],
      ["return", "T::Array[Symbol]"]
    )
  end

  it "ranks weak collection blockers by affected slots and mutation provenance" do
    report = described_class.new
    evidence = {
      "methods" => [
        {
          "source" => { "path" => "src/a.rb", "line" => 10 },
          "calls" => 12,
          "param_elem" => { "items" => ["Hash"] },
          "param_kv" => {},
          "param_elem_shapes" => {
            "items" => [
              {
                "kind" => "hash",
                "keys" => [{ "kind" => "class", "name" => "Symbol" }],
                "values" => (1..6).map { |idx| { "kind" => "class", "name" => "Value#{idx}" } },
              },
            ],
          },
          "param_kv_shapes" => {},
          "return_elem" => ["Hash"],
          "return_kv" => [[], []],
          "return_elem_shapes" => [
            {
              "kind" => "hash",
              "keys" => [{ "kind" => "class", "name" => "Symbol" }],
              "values" => (1..6).map { |idx| { "kind" => "class", "name" => "Value#{idx}" } },
            },
          ],
          "return_kv_shapes" => [[], []],
        },
      ],
      "facts" => {
        "existing_sigs" => [
          { "path" => "src/a.rb", "line" => 10, "class" => "A", "method" => "m",
            "sig" => "sig { params(items: T::Array[T.untyped]).returns(T::Array[T.untyped]) }" },
        ],
        "collection_runtime" => [
          { "owner_kind" => "method_param", "name" => "items", "path" => "src/a.rb", "line" => 10,
            "kind" => "array", "calls" => 12, "mutation_sites" => { "src/build.rb:20" => 7 } },
          { "owner_kind" => "method_return", "name" => "m", "path" => "src/a.rb", "line" => 10,
            "kind" => "array", "calls" => 12, "mutation_sites" => { "src/build.rb:20" => 5 } },
        ],
      },
    }

    slots = report.collection_signature_slots(evidence)
    pressure = report.collection_blocker_pressure(evidence, slots)
    labels = pressure.keys

    expect(labels).to include(a_string_including("method_param items array at src/a.rb:10; candidate still contains T.untyped"))
    expect(labels).to include(a_string_including("method_return m array at src/a.rb:10; candidate still contains T.untyped"))
    expect(pressure.values.map { |data| data["slots"].size }).to all(eq(1))
    expect(pressure.values.map { |data| data["mutation_sites"].fetch("src/build.rb:20") }).to include(7, 5)
  end

  it "ranks hash maps acting as structs by downstream slot pressure" do
    report = described_class.new
    evidence = {
      "facts" => {
        "collection_index_lookups" => [
          { "path" => "src/caps.rb", "line" => 10, "code" => "c[:capability]", "receiver" => "c", "index" => ":capability",
            "receiver_type" => nil, "status" => "unknown receiver type", "origin" => { "kind" => "local variable", "name" => "c" } },
          { "path" => "src/caps.rb", "line" => 11, "code" => "c[:var_node]", "receiver" => "c", "index" => ":var_node",
            "receiver_type" => "T::Hash[Symbol, T.untyped]", "status" => "weak collection receiver", "origin" => { "kind" => "local variable", "name" => "c" } },
          { "path" => "src/params.rb", "line" => 20, "code" => "param[:name]", "receiver" => "param", "index" => ":name",
            "receiver_type" => nil, "status" => "unknown receiver type", "origin" => { "kind" => "method parameter", "name" => "param" } },
        ],
        "param_origins" => [
          { "path" => "src/use.rb", "line" => 30, "callee" => "sink", "slot" => "0", "code" => "c[:capability]" },
        ],
        "return_origins" => [
          { "sources" => [{ "line" => 40, "code" => "c[:var_node]" }] },
        ],
      },
    }

    rows = report.hash_record_struct_pressure(evidence)

    expect(rows.first).to include(
      "label" => "local hash record c at src/caps.rb",
      "keys" => %w[capability var_node],
      "collection_slots" => 2,
      "param_slots" => 1,
      "return_slots" => 1,
      "total_pressure" => 4
    )
    expect(rows[1]).to include(
      "label" => "method parameter hash record param",
      "keys" => ["name"],
      "total_pressure" => 1
    )
  end
end
