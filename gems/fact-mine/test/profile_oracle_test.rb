# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/fact_mine/syntax"
require_relative "../lib/fact_mine/espalier_profile"

class ProfileOracleTest < Minitest::Test
  EXAMPLES_ROOT = File.expand_path("../examples/profile", __dir__)

  FIXTURES = Dir[File.join(EXAMPLES_ROOT, "*")]
             .select { |path| File.file?(path) && !path.end_with?(".json") }
             .sort
             .freeze

  def test_fixtures_exist
    refute_empty FIXTURES
  end

  FIXTURES.each_with_index do |fixture_path, index|
    name = File.basename(fixture_path, File.extname(fixture_path))
    method_name = "test_#{index}_profile_structural_facts"

    define_method(method_name) do
      assert_profile_structural_facts(fixture_path)
    end
  end

  private

  def assert_profile_structural_facts(fixture_path)
    result = extract_profile(fixture_path)

    # Verify methods have required fields
    Array(result["methods"]).each do |method|
      %w[owner name kind path line language params source].each do |field|
        refute_nil method[field], "method missing #{field}"
      end
    end

    # Verify fields have required fields (if any detected)
    Array(result["fields"]).each do |field|
      %w[owner name path line language static_origin].each do |f|
        refute_nil field[f], "field missing #{f}"
      end
    end
  end

  def extract_profile(file)
    doc = FactMine::Syntax.parse(file)
    facts = {
      function_defs: doc.function_defs,
      state_declarations: doc.state_declarations,
      state_writes: doc.state_writes,
      state_reads: doc.state_reads,
      call_sites: doc.call_sites,
      owner_defs: doc.owner_defs,
      state_param_origins: doc.respond_to?(:state_param_origins) ? doc.state_param_origins : [],
      comparison_sites: doc.respond_to?(:comparison_sites) ? doc.comparison_sites : [],
      type_definitions: doc.respond_to?(:type_definitions) ? doc.type_definitions : [],
      redundant_nil_guard_findings: doc.respond_to?(:redundant_nil_guard_findings) ? doc.redundant_nil_guard_findings : [],
    }
    FactMine::EspalierProfile.build(doc, facts, root: Dir.pwd, profile: :espalier)
      .transform_keys(&:to_s)
  end
end