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
      "owners" => %w[name kind line],
      "calls" => %w[receiver message function line conditional control safe_navigation block arguments],
      "state_declarations" => %w[field owner type line],
      "state_param_origins" => %w[field receiver owner param function line],
      "state_reads" => %w[receiver field function line],
      "state_writes" => %w[receiver field function line],
      "decisions" => %w[kind members function line predicate],
      "branch_decisions" => %w[function line predicate state_refs],
      "branch_arms" => %w[function kind line decision_line predicate member body],
      "dispatch_sites" => %w[variant_set arm_members outside function line],
      "semantic_effects" => %w[kind detail function line],
      "predicate_bodies" => %w[name owner body line],
      "comparisons" => %w[source raw canon_source operator function line],
      "path_conditions" => %w[guards action function line],
      "protocol_method_effects" => %w[owner name line reads writes],
      "protocol_call_paths" => %w[owner name line calls],
      "clone_candidates" => %w[method_name node_name line mass fingerprint child_fingerprints child_masses],
      "redundant_nil_guards" => %w[defn line local guard proof],
      "local_methods" => %w[id owner name line statements boundaries local_contract_assignments],
      "local_complexity_scores" => %w[id score signals]
    }.fetch(section)
  end

  def syntax_rows(rows, keys)
    Array(rows).map do |row|
      projected = pick(row, keys)
      canonicalize_local_method_statements(projected) if projected.key?("statements")
      projected
    end
  end

  def canonicalize_local_method_statements(row)
    row["statements"] = Array(row["statements"]).map do |statement|
      next statement unless statement.is_a?(Hash)

      statement.merge("co_uses" => canonical_co_uses(statement.fetch("co_uses", [])))
    end
  end

  def project_local_flow(fixture_path, engine)
    output = JSON.parse(
      Decomplex::DetectorRunner.canonical_json("local-flow", [fixture_path], engine: engine)
    )
    Array(output).map do |method|
      {
        "method" => method["name"],
        "statements" => Array(method["statements"]).map do |statement|
          row = pick(statement, %w[reads writes dependencies co_uses])
          row["co_uses"] = canonical_co_uses(row.fetch("co_uses", []))
          row
        end,
        "boundaries" => Array(method["boundaries"]).map do |boundary|
          pick(boundary, %w[before_index after_index kind])
        end
      }
    end
  end

  def canonical_co_uses(co_uses)
    Array(co_uses).map { |pair| Array(pair).map(&:to_s).sort }
                  .sort_by { |pair| JSON.generate(pair) }
  end

  def pick(row, keys)
    keys.each_with_object({}) do |key, out|
      out[key] = row[key] if row.key?(key)
    end
  end
end
