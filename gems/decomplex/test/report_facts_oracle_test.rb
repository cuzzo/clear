# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/report"
require_relative "../lib/decomplex/native/command"

class ReportFactsOracleTest < Minitest::Test
  EXAMPLES_ROOT = File.expand_path("../examples", __dir__)
  REPORT_FACT_PATHS = Dir[File.join(EXAMPLES_ROOT, "facts", "report", "*.json")].sort.freeze

  def test_report_fact_oracles_exist
    refute_empty REPORT_FACT_PATHS
  end

  REPORT_FACT_PATHS.each_with_index do |fixture_path, index|
    name = File.basename(fixture_path, ".json").tr("-", "_")

    define_method("test_report_fact_#{index}_#{name}_matches_ruby_and_rust") do
      assert_report_fact_oracle(fixture_path)
    end
  end

  private

  def assert_report_fact_oracle(fixture_path)
    fixture = JSON.parse(File.read(fixture_path))
    facts = fixture.fetch("input")
    expected = fixture.fetch("expected")

    ruby_report = Decomplex::Report.from_facts(JSON.generate(facts))
    assert_equal expected, project_report(ruby_report), "ruby #{fixture_path}"

    skip "cargo is not available" unless rust_available?

    Tempfile.create(["decomplex-report-facts-oracle", ".json"]) do |file|
      file.write(JSON.pretty_generate(facts))
      file.flush

      rust_markdown = Decomplex::Native::Command.run(
        "render-report", "--input", file.path, "--format", "markdown"
      )
      rust_sarif = JSON.parse(Decomplex::Native::Command.run(
        "render-report", "--input", file.path, "--format", "sarif"
      ))

      assert_equal ruby_report.to_markdown.rstrip, rust_markdown.rstrip, "markdown #{fixture_path}"
      assert_equal JSON.parse(ruby_report.to_sarif), rust_sarif, "sarif #{fixture_path}"
    end
  end

  def project_report(report)
    {
      "convergence" => json_safe(report.instance_variable_get(:@convergence)),
      "root_clusters" => json_safe(report.root_clusters),
      "sarif" => compact_sarif(report)
    }
  end

  def compact_sarif(report)
    compact_sarif_hash(JSON.parse(report.to_sarif(
      include_snapshot: false,
      include_finding_payload: false,
      max_results: 8
    )))
  end

  def compact_sarif_hash(sarif)
    run = sarif.fetch("runs").first
    results = run.fetch("results")
    {
      "rule_count" => run.dig("tool", "driver", "rules").size,
      "result_count" => results.size,
      "rule_ids" => results.map { |result| result.fetch("ruleId") },
      "messages" => results.map { |result| result.dig("message", "text") },
      "locations" => results.map do |result|
        location = result.dig("locations", 0, "physicalLocation")
        {
          "uri" => location.dig("artifactLocation", "uri"),
          "startLine" => location.dig("region", "startLine")
        }
      end
    }
  end

  def json_safe(value)
    case value
    when Hash
      value.to_h { |key, child| [key.to_s, json_safe(child)] }
    when Array
      value.map { |child| json_safe(child) }
    when Symbol
      value.to_s
    else
      value
    end
  end

  def rust_available?
    env = ENV["DECOMPLEX_RUST_BIN"]
    return true if env && !env.empty? && File.executable?(env)

    system("cargo", "--version", out: File::NULL, err: File::NULL)
  end
end
