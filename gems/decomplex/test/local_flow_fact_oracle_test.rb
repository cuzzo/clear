# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/detector_runner"

class LocalFlowFactOracleTest < Minitest::Test
  EXAMPLES_ROOT = File.expand_path("../examples/facts/local-flow", __dir__)
  ENGINES = %w[rust].freeze

  FIXTURE_PATHS = Dir[File.join(EXAMPLES_ROOT, "*.json")].sort.freeze

  def test_local_flow_fact_fixtures_exist
    refute_empty FIXTURE_PATHS
  end

  FIXTURE_PATHS.product(ENGINES).each_with_index do |(fixture_path, engine), index|
    name = File.basename(fixture_path, ".json")
    method_name = "test_#{index}_#{engine}_#{name.tr("-", "_")}_local_flow_consumers_match_oracle"

    define_method(method_name) do
      assert_local_flow_fact_fixture(fixture_path, engine)
    end
  end

  private

  def assert_local_flow_fact_fixture(fixture_path, engine)
    fixture = JSON.parse(File.read(fixture_path))
    input = fixture.fetch("input")
    fixture.fetch("expected").each do |detector, expected|
      Tempfile.create(["decomplex-local-flow-fact", ".json"]) do |file|
        file.write(JSON.pretty_generate({ "detector" => detector, "input" => input, "expected" => expected }))
        file.flush
        actual = JSON.parse(Decomplex::DetectorRunner.canonical_json_from_fact_fixture(file.path, engine: engine))
        assert_equal expected, actual, "#{engine} #{fixture_path} #{detector}"
      end
    end
  end
end
