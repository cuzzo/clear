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

RSpec.describe NilKill::FactMineStaticFacts do
  FakeDocument = Struct.new(:language, :file, :lines, :root, keyword_init: true)

  it "extracts Sorbet type aliases through the Nil-kill FactMine fact provider" do
    document = FakeDocument.new(lines: [
      "module Demo\n",
      "  RawBody = T.type_alias { T::Array[AST::Node] }\n",
      "  ScopeType = T.type_alias do\n",
      "    T.any(Schemas::EnumSchema, Schemas::StructSchema)\n",
      "  end\n",
      "end\n",
    ], language: :ruby, file: File.join(NilKill::ROOT, "src/demo.rb"), root: nil)

    facts = described_class.build(document, {
      function_defs: [],
      state_declarations: [],
      state_writes: [],
      state_param_origins: [],
      call_sites: [],
      owner_defs: [],
    })
    definitions = facts.fetch(:type_definitions)

    expect(definitions).to include(
      a_hash_including("kind" => "type_alias", "owner" => "Demo", "name" => "RawBody",
        "target" => "T::Array[AST::Node]"),
      a_hash_including("kind" => "type_alias", "owner" => "Demo", "name" => "ScopeType",
        "target" => "T.any(Schemas::EnumSchema, Schemas::StructSchema)")
    )
  end
end
