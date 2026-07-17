# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/espalier"

class BigOGoldenTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/big_o", __dir__)

  def test_fixture_corpus_matches_oracle
    oracle = JSON.parse(File.read(File.join(FIXTURE_ROOT, "oracle.json")))
    files = oracle.keys.map { |name| File.join(FIXTURE_ROOT, name) }
    evidence = Espalier::StaticEvidence.build(files, root: FIXTURE_ROOT)
    modules = Espalier::StaticEvidence.project_modules(evidence)
    manifest = Espalier::Aggregator.new.aggregate(modules)

    actual = manifest.each_with_object(Hash.new { |hash, file| hash[file] = {} }) do |owner, by_file|
      file = File.basename(owner.fetch(:file))
      owner.fetch(:functions).each do |function|
        metrics = function.fetch(:quality_metrics)
        by_file[file][function.fetch(:name)] = {
          total: metrics.fetch(:big_o), known: metrics.fetch(:big_o_known_component),
          variables: Array(metrics[:big_o_variables])
        }
      end
    end

    actual_space = manifest.each_with_object(Hash.new { |hash, file| hash[file] = {} }) do |owner, by_file|
      file = File.basename(owner.fetch(:file))
      owner.fetch(:functions).each do |function|
        metrics = function.fetch(:quality_metrics)
        by_file[file][function.fetch(:name)] = {
          total: metrics.fetch(:big_o_space), known: metrics.fetch(:big_o_space_known_component)
        }
      end
    end

    oracle.each do |file, functions|
      functions.each do |name, expected|
        key = expected == "unknown" ? :total : :known
        assert_equal expected, actual.dig(file, name, key), "#{file}:#{name}"
      end
    end
    JSON.parse(File.read(File.join(FIXTURE_ROOT, "space_oracle.json"))).each do |file, functions|
      functions.each do |name, expected|
        key = expected == "unknown" ? :total : :known
        assert_equal expected, actual_space.dig(file, name, key), "space #{file}:#{name}"
      end
    end
    JSON.parse(File.read(File.join(FIXTURE_ROOT, "partial_oracle.json"))).each do |file, functions|
      functions.each do |name, expected|
        assert_equal expected.fetch("time"), actual.dig(file, name, :known), "partial time #{file}:#{name}"
        assert_equal expected.fetch("space"), actual_space.dig(file, name, :known), "partial space #{file}:#{name}"
      end
    end
    cartesian_variables = actual.dig("ruby_product.rb", "cartesian_product", :variables)
    assert_equal %w[N M], cartesian_variables.map { |variable| variable[:symbol] }
    assert_equal %w[xs ys], cartesian_variables.map { |variable| variable[:name] }
    assert cartesian_variables.all? { |variable| variable[:path].end_with?("ruby_product.rb") }

    repeated_helper_variables = actual.dig("normalized_domains.rb", "repeated_helper", :variables)
    assert_equal ["items"], repeated_helper_variables.map { |variable| variable[:name] }
    assert_equal ["param:normalized_domains#repeated_helper:items"],
                 repeated_helper_variables.map { |variable| variable[:domain_id] }
  end

  def test_analyzer_oracle
    oracle = JSON.parse(File.read(File.join(FIXTURE_ROOT, "analyzer_oracle.json")))
    config = oracle.fetch("config")
    evidence = Object.new
    evidence.define_singleton_method(:method_signatures) { config.fetch("method_signatures") }
    evidence.define_singleton_method(:state_types) { config.fetch("state_types") }
    analyzer = Espalier::BigOAnalyzer.new(
      class_name: config.fetch("class_name"),
      ivar_types: config.fetch("ivar_types"),
      local_types: config.fetch("local_types"),
      nil_kill_evidence: config.fetch("nil_kill_evidence"),
      nil_kill: evidence
    )

    oracle.fetch("type_resolutions").each do |receiver, expected|
      line = receiver == "evidence_items" ? 20 : 1
      assert_equal expected, analyzer.send(:resolve_type, receiver, line), receiver
    end

    nodes = oracle.dig("analysis", "nodes").map do |node|
      node.transform_keys(&:to_sym).tap { |row| row[:type] = row.fetch(:type).to_sym }
    end
    result = analyzer.analyze_method("oracle", nodes)
    assert_equal "unknown", result.fetch(:lower_bound_complexity)
    assert_equal "unknown", result.fetch(:space_complexity)
    assert_equal oracle.dig("analysis", "expected_complexity"), result.fetch(:known_time_component)
    assert_equal oracle.dig("analysis", "expected_space"), result.fetch(:known_space_component)
    refute result.fetch(:time_complete)
    refute result.fetch(:space_complete)
    assert result.fetch(:is_dynamic)
    assert_equal "normalized-domain", result.fetch(:trigger)
    assert_includes result.fetch(:unknown_operations), "Widget#work"
    assert_includes result.fetch(:unknown_operations), "mystery.work"

    oracle.fetch("multiplications").each do |left, right, expected|
      assert_equal expected, analyzer.send(:multiply_complexity, left, right), "#{left} * #{right}"
    end
    oracle.fetch("ranks").each do |value, expected|
      assert_equal expected, analyzer.send(:complexity_rank, value), value
    end
    assert_equal 10, analyzer.send(:space_complexity_rank, "O(N)")
    assert_equal 5, analyzer.send(:space_complexity_rank, "O(log N)")
    assert_equal 1, analyzer.send(:space_complexity_rank, "unknown")
  end

  def test_go_and_python_call_provenance_excludes_unrelated_sibling_loops
    files = %w[python_call_provenance.py go_call_provenance.go]
      .map { |name| File.join(FIXTURE_ROOT, name) }
    evidence = Espalier::StaticEvidence.build(files, root: FIXTURE_ROOT)
    manifest = Espalier::Aggregator.new.aggregate(
      Espalier::StaticEvidence.project_modules(evidence)
    )
    functions = manifest.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |owner, rows|
      extension = File.extname(owner.fetch(:file))
      owner.fetch(:functions).each do |function|
        rows[[extension, function.fetch(:name)]] << function
      end
    end

    %w[.py .go].each do |extension|
      helper = functions.fetch([extension, "helper"]).first.fetch(:quality_metrics)
      unrelated = functions.fetch([extension, "unrelated"]).first.fetch(:quality_metrics)
      caller = functions.fetch([extension, "caller"]).first.fetch(:quality_metrics)
      assert_equal "O(N)", helper.fetch(:big_o_known_component)
      assert_equal "O(N*M)", unrelated.fetch(:big_o_known_component)
      assert_equal "O(N)", caller.fetch(:big_o_known_component)
      assert_equal ["items"], Array(caller[:big_o_variables]).map { |variable| variable[:name] }
    end
  end
end
