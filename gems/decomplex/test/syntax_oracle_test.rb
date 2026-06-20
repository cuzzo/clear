# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/decomplex/syntax_oracle"

class SyntaxOracleTest < Minitest::Test
  EXAMPLES_ROOT = File.expand_path("../examples/syntax-facts", __dir__)
  ORACLE_ROOT = File.join(EXAMPLES_ROOT, "oracles")
  ENGINES = %w[ruby rust].freeze

  FIXTURES = Dir[File.join(EXAMPLES_ROOT, "*", "*")]
             .select { |path| File.file?(path) && Decomplex::Syntax.supported_source?(path) }
             .sort
             .freeze

  def test_syntax_fact_fixtures_exist
    refute_empty FIXTURES
  end

  FIXTURES.product(ENGINES).each_with_index do |(fixture_path, engine), index|
    language = File.basename(File.dirname(fixture_path))
    name = File.basename(fixture_path, File.extname(fixture_path))
    method_name = "test_#{index}_#{engine}_#{language}_#{name}_syntax_facts_match_oracle"

    define_method(method_name) do
      assert_syntax_facts_match_oracle(fixture_path, engine)
    end
  end

  private

  def assert_syntax_facts_match_oracle(fixture_path, engine)
    language = File.basename(File.dirname(fixture_path))
    name = File.basename(fixture_path, File.extname(fixture_path))
    oracle_path = File.join(ORACLE_ROOT, "#{language}-#{name}.json")

    assert File.file?(oracle_path), "missing syntax oracle #{oracle_path}"

    expected = JSON.parse(File.read(oracle_path))
    actual = Decomplex::SyntaxOracle.project([fixture_path], engine: engine, language: language)

    assert_equal expected, actual, "#{engine} #{fixture_path}"
  end
end
