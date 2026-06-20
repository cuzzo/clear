# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/decomplex/detector_runner"
require_relative "../lib/decomplex/syntax_oracle"

class SourceFactsOracleTest < Minitest::Test
  EXAMPLES_ROOT = File.expand_path("../examples/source-facts", __dir__)
  ORACLE_ROOT = File.join(EXAMPLES_ROOT, "oracles")
  ENGINES = %w[ruby rust].freeze

  FIXTURES = Dir[File.join(EXAMPLES_ROOT, "ruby", "*.rb")].sort.freeze

  def test_ruby_source_fact_fixtures_exist
    refute_empty FIXTURES
  end

  FIXTURES.product(ENGINES).each_with_index do |(fixture_path, engine), index|
    name = File.basename(fixture_path, ".rb")
    method_name = "test_#{index}_#{engine}_ruby_#{name}_source_facts_match_oracle"

    define_method(method_name) do
      assert_source_facts_match_oracle(fixture_path, engine)
    end
  end

  private

  def assert_source_facts_match_oracle(fixture_path, engine)
    name = File.basename(fixture_path, ".rb")
    oracle_path = File.join(ORACLE_ROOT, "ruby-#{name}.json")
    assert File.file?(oracle_path), "missing source-facts oracle #{oracle_path}"

    expected = JSON.parse(File.read(oracle_path))
    actual = {}
    actual["syntax"] = project_syntax(fixture_path, engine, expected.fetch("syntax", {})) if expected.key?("syntax")
    actual["local_flow"] = project_local_flow(fixture_path, engine) if expected.key?("local_flow")

    assert_equal expected, actual, "#{engine} #{fixture_path}"
  end

  def project_syntax(fixture_path, engine, expected)
    document = Decomplex::SyntaxOracle.project([fixture_path], engine: engine, language: :ruby)
                                      .fetch("documents")
                                      .first
    expected.keys.each_with_object({}) do |section, out|
      out[section] = syntax_rows(document.fetch(section), syntax_keys(section))
    end
  end

  def syntax_keys(section)
    {
      "functions" => %w[name owner line visibility params],
      "calls" => %w[receiver message function line conditional control safe_navigation block arguments],
      "state_reads" => %w[receiver field function line],
      "state_writes" => %w[receiver field function line],
      "semantic_effects" => %w[kind detail function line]
    }.fetch(section)
  end

  def syntax_rows(rows, keys)
    Array(rows).map { |row| pick(row, keys) }
  end

  def project_local_flow(fixture_path, engine)
    output = JSON.parse(
      Decomplex::DetectorRunner.canonical_json("local-flow", [fixture_path], engine: engine)
    )
    Array(output).map do |method|
      {
        "method" => method["name"],
        "statements" => Array(method["statements"]).map do |statement|
          pick(statement, %w[reads writes dependencies co_uses])
        end,
        "boundaries" => Array(method["boundaries"]).map do |boundary|
          pick(boundary, %w[before_index after_index kind])
        end
      }
    end
  end

  def pick(row, keys)
    keys.each_with_object({}) do |key, out|
      out[key] = row[key] if row.key?(key)
    end
  end
end
