# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class ScipLanguageInventoryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SUPPORT = File.join(
    ROOT,
    "fact-mine",
    "config",
    "stdlib_maps",
    "support.yml"
  )

  def test_all_static_scip_language_families_are_inventoried
    languages = YAML.safe_load_file(SUPPORT).fetch("languages")
    %w[
      c
      cpp
      csharp
      dart
      go
      java
      kotlin
      rust
      scala
      typescript
      visual_basic
    ].each do |language|
      assert languages.key?(language), "missing SCIP support status for #{language}"
    end
  end

  def test_unparsed_static_languages_fail_closed_before_stdlib_mapping
    languages = YAML.safe_load_file(SUPPORT).fetch("languages")
    %w[dart scala visual_basic].each do |language|
      entry = languages.fetch(language)
      assert_equal "blocked", entry.fetch("status")
      assert_equal "fact_mine_language_adapter_missing", entry.fetch("blocker")
    end
  end
end
