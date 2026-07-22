# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::Inference::StaticFactProvider do
  it "preserves canonical nullable public facts from static evidence" do
    fixture = File.join(NilKill::ROOT, "gems/fact-mine/tests/fixtures/nullable_operations.c")
    static = NilKill::StaticEvidence.build([fixture], root: NilKill::ROOT)
    store = NilKill::Store.new

    described_class.new.index(store: store, static: static, root: NilKill::ROOT)

    expect(store.facts.fetch("nullable_states")).to include(
      include("state" => "definitely_null", "complete" => true)
    )
    expect(store.facts.fetch("nullable_operations")).to contain_exactly(
      include(
        "operation_kind" => "pointer_dereference",
        "nil_behavior" => "undefined_behavior",
        "state_at_operation" => "definitely_null",
        "complete" => true
      )
    )
  end

  it "turns complete Go comma-ok facts into branch-refinement review evidence" do
    fixture = File.join(NilKill::ROOT, "gems/fact-mine/tests/fixtures/nullable_presence.go")
    static = NilKill::StaticEvidence.build([fixture], root: NilKill::ROOT)
    store = NilKill::Store.new

    described_class.new.index(store: store, static: static, root: NilKill::ROOT)

    correlation = store.facts.fetch("presence_correlations").find { |fact| fact["semantics"] == "map_lookup" }
    expect(correlation).to include("complete" => true, "branch_refinement" => "presence_on_true")
    expect(correlation.fetch("path")).to end_with("nullable_presence.go")
    expect(correlation.fetch("span").first).to be_positive

    actions = NilKill::Analyzers::RuntimeEvidenceAnalyzer.new(
      "static" => static,
      "runtime" => {}
    ).analyze
    action = actions.find { |candidate| candidate["kind"] == "refine_presence_guard" }
    expect(action).to include("language" => "go", "confidence" => NilKill::REVIEW)
    expect(action.fetch("data")).to include("semantics" => "map_lookup")
  end

  it "preserves normalized nilability and adapter-rendered type text" do
    return_type = FactMine::Syntax::TypeExpr.new(
      "Nilable",
      { "kind" => "Primitive", "data" => "Token" },
      "ruby"
    )
    static = {
      "methods" => [{
        "language" => "ruby",
        "path" => "parser.rb",
        "line" => 10,
        "span" => [10, 0, 12, 3],
        "owner" => "Parser",
        "name" => "consume",
        "kind" => "instance_method",
        "signature" => "sig { returns(T.nilable(Token)) }",
        "params" => [],
      }],
      "facts" => {
        "type_definitions" => [{
          "language" => "ruby",
          "path" => "parser.rb",
          "line" => 10,
          "owner" => "Parser",
          "name" => "consume",
          "kind" => "method_signature",
          "return_type" => return_type,
          "params" => [],
        }],
      },
    }
    store = NilKill::Store.new

    described_class.new("ruby").index(store: store, static: static, root: "/repo")

    source = store.facts.fetch("existing_sigs").fetch(0)
    expect(source).to include(
      "return_type" => return_type,
      "return_type_text" => "T.nilable(Token)",
      "non_nil_return_type_text" => "Token"
    )
    expect(source.fetch("non_nil_return_type")).to have_attributes(
      kind: "Primitive",
      data: "Token"
    )
  end
end
