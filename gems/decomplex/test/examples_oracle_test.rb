# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/decomplex/detector_runner"

class ExamplesOracleTest < Minitest::Test
  EXAMPLES_ROOT = File.expand_path("../examples", __dir__)
  ORACLE_DIR = File.join(EXAMPLES_ROOT, "oracles")
  ENGINES = %w[rust].freeze
  SOURCE_EXTENSIONS = Decomplex::Syntax.supported_exts.freeze
  LOCATION_KEYS = %w[
    at boundaries boundary_crossings component_lines defn examples file
    gap_lines line locations predicate raw reason sites span spans source
  ].freeze

  ORACLE_PATHS = Dir[File.join(ORACLE_DIR, "*.json")].sort.freeze
  FIXTURE_PATHS = Dir[File.join(EXAMPLES_ROOT, "*", "*")]
                  .select { |path| SOURCE_EXTENSIONS.include?(File.extname(path)) }
                  .sort
                  .freeze
  DETECTOR_FACT_PATHS = Dir[File.join(EXAMPLES_ROOT, "facts", "detectors", "*.json")].sort.freeze

  def test_shared_oracle_files_exist
    refute_empty ORACLE_PATHS
  end

  def test_detector_fact_oracles_exist
    refute_empty DETECTOR_FACT_PATHS
  end

  def test_shared_oracles_are_engine_agnostic
    pinned = ORACLE_PATHS.select { |path| JSON.parse(File.read(path)).key?("engine") }

    assert_empty pinned, "shared example oracles must not pin detector engines:\n#{pinned.join("\n")}"
  end

  def test_each_detector_has_one_fixture_per_language
    languages = FIXTURE_PATHS.map { |path| File.basename(File.dirname(path)) }.uniq.sort
    detectors = ORACLE_PATHS.map { |path| File.basename(path, ".json") }.sort

    detectors.each do |detector|
      actual = FIXTURE_PATHS
               .select { |path| File.basename(path, File.extname(path)) == detector }
               .map { |path| File.basename(File.dirname(path)) }
               .sort
      assert_equal languages, actual, "#{detector} fixture languages"
    end
  end

  FIXTURE_PATHS.product(ENGINES).each_with_index do |(fixture_path, engine), index|
    language = File.basename(File.dirname(fixture_path))
    detector = File.basename(fixture_path, File.extname(fixture_path))
    method_name = "test_#{index}_#{engine}_#{language}_#{detector.tr("-", "_")}_matches_shared_oracle"

    define_method(method_name) do
      assert_fixture_matches_shared_oracle(fixture_path, engine)
    end
  end

  DETECTOR_FACT_PATHS.product(ENGINES).each_with_index do |(fixture_path, engine), index|
    detector = File.basename(fixture_path, ".json")
    method_name = "test_detector_fact_#{index}_#{engine}_#{detector.tr("-", "_")}_matches_exact_oracle"

    define_method(method_name) do
      assert_detector_fact_fixture_matches_exact_oracle(fixture_path, engine)
    end
  end

  private

  def assert_fixture_matches_shared_oracle(fixture_path, engine)
    detector = File.basename(fixture_path, File.extname(fixture_path))
    oracle_path = File.join(ORACLE_DIR, "#{detector}.json")

    assert File.file?(oracle_path), "missing shared oracle #{oracle_path}"

    oracle = JSON.parse(File.read(oracle_path))
    expected = oracle.fetch("expected")
    assert meaningful?(expected), "#{oracle_path} expected projection is empty"

    options = symbolize_options(oracle.fetch("options", {}))
    actual = JSON.parse(
      Decomplex::DetectorRunner.canonical_json(
        oracle.fetch("detector"),
        [fixture_path],
        engine: engine,
        **options
      )
    )

    assert_equal expected, project_detector_output(detector, actual), "#{engine} #{fixture_path}"
  end

  def assert_detector_fact_fixture_matches_exact_oracle(fixture_path, engine)
    fixture = JSON.parse(File.read(fixture_path))
    expected = fixture.fetch("expected")
    assert meaningful?(expected), "#{fixture_path} expected output is empty"

    actual = JSON.parse(
      Decomplex::DetectorRunner.canonical_json_from_fact_fixture(fixture_path, engine: engine)
    )

    assert_equal expected, actual, "#{engine} #{fixture_path}"
  end

  def symbolize_options(options)
    options.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
  end

  def project_detector_output(detector, output)
    case detector
    when "co-update"
      {
        "co_written_pairs" => rows(output["co_written_pairs"], %w[pair support]),
        "neglected_updates" => rows(output["neglected_updates"], %w[pair support has missing])
      }
    when "decision-pressure"
      rows(output, %w[contract decisions essential methods])
    when "predicate-alias"
      {
        "alias_clusters" => Array(output["alias_clusters"]).map do |row|
          { "name_count" => Array(row["names"]).size }
        end
      }
    when "miner"
      {
        "missing_abstractions" => Array(output["missing_abstractions"]).map do |row|
          pick(row, %w[kind members support scatter])
        end,
        "neglected_conditions" => rows(output["neglected_conditions"], %w[pattern support missing])
      }
    when "semantic-alias"
      {
        "alias_clusters" => Array(output["alias_clusters"]).map do |row|
          { "canon" => canonical_predicate(row["canon"]), "name_count" => Array(row["names"]).size }
        end,
        "reification_miss_count" => Array(output["reification_misses"]).size
      }
    when "flay-similarity"
      Array(output["findings"]).map do |row|
        pick(row, %w[clone_type node]).merge("site_count" => Array(row["sites"]).size)
      end
    when "temporal-ordering-pressure"
      Array(output).map do |row|
        pick(row, %w[owner public_methods state_methods writers orderings]).merge(
          "state_fields" => canonical_state_refs(row["state_fields"]),
          "shared_fields" => canonical_state_refs(row["shared_fields"])
        )
      end
    when "state-branch-density"
      Array(output).map do |row|
        pick(row, %w[decisions]).merge(
          "method" => canonical_method_name(row["method"]),
          "state_refs" => canonical_state_refs(row["state_refs"])
        )
      end
    when "redundant-nil-guard"
      rows(output, %w[local])
    when "state-mesh"
      project_state_mesh(output)
    when "inconsistent-rename-clone"
      Array(output).map do |row|
        pick(row, %w[ref_name]).merge("divergent_count" => Array(row["divergent"]).size)
      end
    when "derived-state"
      rows(output, %w[derived source])
    when "implicit-control-flow"
      {
        "ordered_protocols" => project_protocols(output["ordered_protocols"]),
        "order_drift" => project_protocols(output["order_drift"])
      }
    when "weighted-inlined-complexity"
      Array(output).map do |row|
        pick(row, %w[method depth]).merge("callee_count" => Array(row["single_caller_callees"]).size)
      end
    when "locality-drag"
      rows(output, %w[variable])
    when "operational-discontinuity"
      rows(output, %w[resets confidence])
    when "oversized-predicate"
      Array(output["findings"]).map do |row|
        pick(row, %w[count]).merge("atom_count" => Array(row["atoms"]).size)
      end
    when "path-condition"
      Array(output["neglected"]).map do |row|
        {
          "pattern" => canonical_predicate_atoms(row["pattern"]),
          "support" => row["support"],
          "missing" => canonical_predicate(row["missing"]),
          "action" => canonical_action(row["action"])
        }
      end
    when "sequence-mine"
      rows(output["broken"], %w[pair support has missing])
    when "function-lcom"
      rows(output, %w[mode components locals statements terminal_join])
    when "false-simplicity"
      rows(output, %w[kind])
    when "fat-union"
      Array(output["fat_unions"]).map do |row|
        pick(row, %w[common variant degenerate support scatter]).merge(
          "variant_set" => canonical_variants(row["variant_set"])
        )
      end
    when "local-flow"
      Array(output).map do |method|
        {
          "method" => method["name"],
          "statements" => Array(method["statements"]).map do |statement|
            row = pick(statement, %w[reads writes dependencies co_uses])
            row["co_uses"] = canonical_co_uses(row.fetch("co_uses", []))
            row
          end,
          "boundaries" => rows(method["boundaries"], %w[before_index after_index kind])
        }
      end
    when "structural-topology"
      {
        "method_count" => Array(output["methods"]).size,
        "edges" => rows(output["edges"], %w[caller_name callee_name type])
      }
    else
      scrub_locations(output)
    end
  end

  def project_state_mesh(output)
    state_mesh = output.fetch("state_mesh", {})
    fields = output.fetch("fields", {})
    {
      "state_mesh" => pick(state_mesh, %w[total_fields total_writes total_reads total_re_derivations]),
      "field_names" => canonical_state_refs(fields.keys)
    }
  end

  def project_protocols(rows)
    Array(rows).map do |row|
      pick(row, %w[protocol dependency support observed missing]).merge(
        "states" => canonical_state_refs(row["states"])
      )
    end
  end

  def canonical_variants(value)
    Array(value).map do |item|
      item.to_s
          .sub(/\A([A-Z][A-Za-z0-9]*)_([A-Z][A-Za-z0-9]*)\z/, '\1.\2')
          .tr(":", ".")
          .gsub(/\.+/, ".")
    end.sort
  end

  def canonical_co_uses(value)
    Array(value).map { |pair| Array(pair).map(&:to_s).sort }.sort_by { |pair| JSON.generate(pair) }
  end

  def canonical_state_refs(value)
    Array(value).map do |item|
      text = item.to_s
      text = text.sub(/\A@/, "")
      text = text.sub(/\A(?:self|this)\./, "")
      text
    end.uniq.sort
  end

  def canonical_method_name(value)
    value.to_s.split(/[.:#]/).last.to_s
  end

  def canonical_predicate_atoms(value)
    Array(value).map { |item| canonical_predicate(item) }.sort
  end

  def canonical_predicate(value)
    text = value.to_s.strip
    text = text.delete_suffix(";").strip
    text = text.gsub(/:([A-Za-z_]\w*)/) { Regexp.last_match(1).upcase }
    text = text.gsub(/\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\.(\w+)\?/, '\1.\2')
    text = text.gsub(/\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\.(\w+)\(\)/, '\1.\2')
    text
  end

  def canonical_action(value)
    canonical_predicate(value).sub(/\A([A-Za-z_]\w*)\((.*)\)\z/, '\1(\2)')
  end

  def present_rows(value)
    Array(value).empty? ? [] : [{ "present" => true }]
  end

  def rows(value, keys)
    Array(value).map { |row| pick(row, keys) }
  end

  def pick(row, keys)
    keys.each_with_object({}) do |key, out|
      out[key] = canonical_value(row[key]) if row.key?(key)
    end
  end

  def canonical_value(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
        original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
        out[key] = canonical_value(value.fetch(original))
      end
    when Array
      value.map { |item| canonical_value(item) }
    when Symbol
      value.to_s
    else
      value
    end
  end

  def scrub_locations(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
        next if LOCATION_KEYS.include?(key)

        original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
        out[key] = scrub_locations(value.fetch(original))
      end
    when Array
      value.map { |item| scrub_locations(item) }
    when Symbol
      value.to_s
    else
      value
    end
  end

  def meaningful?(value)
    case value
    when Hash
      value.any? { |_key, item| meaningful?(item) }
    when Array
      !value.empty? && value.any? { |item| meaningful?(item) }
    when NilClass
      false
    when String
      !value.empty?
    else
      true
    end
  end
end
