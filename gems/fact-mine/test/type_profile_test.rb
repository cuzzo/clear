# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/fact_mine/syntax"

class TypeProfileTest < Minitest::Test
  def test_ruby_sorbet_profile_owns_builtin_filtering_and_alias_wrappers
    profile = FactMine::Syntax.type_profile(:ruby, type_system: "sorbet")

    assert profile.intrinsic_type?("String")
    assert profile.broad_type?("T.untyped")
    assert_equal %w[Repository], profile.owner_reference_tokens("T.nilable(Repository)")
    assert profile.references_alias?("T.nilable(User)", %w[User])
    refute profile.references_alias?("User$Record", %w[User])
  end

  def test_ruby_sorbet_profile_owns_static_type_synthesis
    profile = FactMine::Syntax.type_profile(:ruby, type_system: "sorbet")

    assert_equal "T::Boolean", profile.static_type(%w[TrueClass FalseClass])
    assert_equal "T.nilable(String)", profile.static_type(%w[String NilClass])
    assert_equal "T.untyped", profile.static_type([])
  end

  def test_native_languages_fall_back_to_generic_profile_without_builtin_vocabularies
    profile = FactMine::Syntax.type_profile(:typescript)

    assert_equal :generic, profile.language
    refute profile.intrinsic_type?("Promise")
    refute profile.broad_type?("unknown")
  end
end
