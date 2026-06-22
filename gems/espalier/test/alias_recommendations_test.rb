# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier"

class AliasRecommendationsTest < Minitest::Test
  def test_alias_reference_guard_does_not_parse_substrings_as_aliases
    records = Espalier::AliasRecommendations.build(
      type_definitions: [
        {
          "language" => "typescript",
          "type_system" => "typescript",
          "kind" => "type_alias",
          "path" => "src/types.ts",
          "owner" => "",
          "name" => "User",
          "line" => 1,
          "target" => "User$Record",
        },
        {
          "language" => "typescript",
          "type_system" => "typescript",
          "kind" => "method_signature",
          "path" => "src/types.ts",
          "owner" => "Service",
          "name" => "load",
          "line" => 5,
          "params" => [{ "name" => "record", "type" => "User$Record" }],
        },
      ]
    )

    assert_equal 1, records.size
    assert_equal "User", records.first["slots"].first["replacement_type"]
  end

  def test_alias_reference_guard_matches_only_generated_alias_forms
    checker = Espalier::AliasRecommendations.new([])
    ruby_profile = FactMine::Syntax.type_profile(:ruby, type_system: "sorbet")

    assert checker.__send__(:references_alias?, "User", "User", "User", ruby_profile)
    assert checker.__send__(:references_alias?, "T.nilable(User)", "User", "User", ruby_profile)
    refute checker.__send__(:references_alias?, "User$Record", "User", "User", ruby_profile)
    refute checker.__send__(:references_alias?, "UserRecord", "User", "User", ruby_profile)
  end
end
