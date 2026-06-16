# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::AliasRecommendations do
  it "recommends existing aliases for matching static type slots" do
    recommendations = described_class.build(type_definitions: [
      {
        "language" => "ruby",
        "type_system" => "sorbet",
        "kind" => "type_alias",
        "path" => "src/ast/ast.rb",
        "owner" => "AST",
        "name" => "RawBody",
        "line" => 15,
        "target" => "T::Array[AST::Node]",
      },
      {
        "language" => "ruby",
        "type_system" => "sorbet",
        "kind" => "method_signature",
        "path" => "src/demo.rb",
        "owner" => "AST",
        "name" => "parse",
        "line" => 9,
        "params" => [{"name" => "body", "type" => "T::Array[AST::Node]"}],
        "return_type" => "T.nilable(T::Array[AST::Node])",
      },
    ])

    expect(recommendations.size).to eq(1)
    recommendation = recommendations.first
    expect(recommendation).to include(
      "alias" => "AST::RawBody",
      "target" => "T::Array[AST::Node]",
      "slot_count" => 2,
      "confidence" => NilKill::HIGH
    )
    expect(recommendation["slots"]).to include(
      a_hash_including("slot_kind" => "param", "slot" => "body", "replacement_type" => "AST::RawBody"),
      a_hash_including("slot_kind" => "return", "replacement_type" => "T.nilable(AST::RawBody)")
    )
  end

  it "does not recommend broad aliases or oversized unions" do
    recommendations = described_class.build(type_definitions: [
      {
        "language" => "ruby",
        "type_system" => "sorbet",
        "kind" => "type_alias",
        "path" => "src/demo.rb",
        "owner" => "Demo",
        "name" => "Huge",
        "line" => 1,
        "target" => "T.any(A, B, C, D, E)",
      },
      {
        "language" => "ruby",
        "type_system" => "sorbet",
        "kind" => "method_signature",
        "path" => "src/demo.rb",
        "owner" => "Demo",
        "name" => "call",
        "line" => 4,
        "return_type" => "T.any(A, B, C, D, E)",
      },
    ])

    expect(recommendations).to be_empty
  end
end

RSpec.describe NilKill::Languages::Providers::Ruby do
  FakeDocument = Struct.new(:lines, keyword_init: true)

  it "extracts Sorbet type aliases as static type definitions" do
    provider = described_class.new
    document = FakeDocument.new(lines: [
      "module Demo\n",
      "  RawBody = T.type_alias { T::Array[AST::Node] }\n",
      "  ScopeType = T.type_alias do\n",
      "    T.any(Schemas::EnumSchema, Schemas::StructSchema)\n",
      "  end\n",
      "end\n",
    ])

    definitions = provider.type_definitions(
      document: document,
      facts: { function_defs: [] },
      rel_path: "src/demo.rb",
      methods: [],
      state_declarations: []
    )

    expect(definitions).to include(
      a_hash_including("kind" => "type_alias", "owner" => "Demo", "name" => "RawBody",
        "target" => "T::Array[AST::Node]"),
      a_hash_including("kind" => "type_alias", "owner" => "Demo", "name" => "ScopeType",
        "target" => "T.any(Schemas::EnumSchema, Schemas::StructSchema)")
    )
  end
end
