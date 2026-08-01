# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/slopcop"

class ConstraintsTest < Minitest::Test
  # A served bundle is not source. giga-ui ships a content-hashed, minified
  # diff viewer whose single 122,875-character line takes tree-sitter tens of
  # minutes; scanning it exhausted the constraint job's 60-minute budget. The
  # exclusion is shared by every provider, and must not swallow real code that
  # merely sits near an assets directory.
  def test_served_asset_directories_are_excluded_for_every_language
    excluded = {
      SlopCop::Constraints::JavascriptProvider =>
        "gems/gigasail/giga-ui/src/ui/assets/diff/assets/index--_D05yx7.js",
      SlopCop::Constraints::TypescriptProvider => "web/assets/vendor/bundle.ts",
      SlopCop::Constraints::RubyProvider => "app/assets/config.rb",
    }
    excluded.each do |provider, path|
      refute provider.source_path?(path), "#{provider} should skip served asset #{path}"
    end

    included = {
      SlopCop::Constraints::JavascriptProvider => "gems/gigasail/giga-ui/src/ui/widget.js",
      SlopCop::Constraints::TypescriptProvider => "web/src/model.ts",
      SlopCop::Constraints::RubyProvider => "lib/assets_helper.rb",
    }
    included.each do |provider, path|
      assert provider.source_path?(path), "#{provider} should still scan #{path}"
    end
  end

  def test_zig_provider_reports_changed_atomic_without_loom_evidence
    with_zig_file("value.store(1, .release);") do |dir, path|
      audit = audit_for(dir, { path => [1] })

      finding = audit.findings.first
      refute_nil finding
      assert_equal "slopcop-zig-loom-uncovered", finding.rule_id
      assert_equal "loom", finding.required_evidence
    end
  end

  def test_zig_provider_accepts_loom_direct_hit
    with_zig_file("value.store(1, .release);") do |dir, path|
      coverage = cobertura(dir, path, 1 => 1)
      audit = audit_for(dir, { path => [1] }, coverage: ["loom:#{coverage}"])

      assert_empty audit.findings
    end
  end

  def test_zig_provider_accepts_conservative_loom_elision
    source = [
      "const before = true;",
      "value.store(1, .release);",
      "const after = true;"
    ].join("\n")
    with_zig_file(source) do |dir, path|
      coverage = cobertura(dir, path, 1 => 1, 2 => 0, 3 => 1)
      audit = audit_for(dir, { path => [2] }, coverage: ["loom:#{coverage}"])

      assert_empty audit.findings
    end
  end

  def test_zig_provider_accepts_vopr_retry_hit_on_following_instrumented_line
    source = [
      "// VOPR-START-RETRY: retry on empty queue",
      "while (queue.empty()) {}",
      "// VOPR-END-RETRY"
    ].join("\n")
    with_zig_file(source) do |dir, path|
      coverage = cobertura(dir, path, 2 => 1)
      audit = audit_for(dir, { path => [1] }, coverage: ["vopr:#{coverage}"])

      assert_empty audit.findings
    end
  end

  def test_sarif_output_contains_warning_location
    with_zig_file("std.time.milliTimestamp();") do |dir, path|
      audit = audit_for(dir, { path => [1] })
      sarif = JSON.parse(audit.to_sarif)
      result = sarif.fetch("runs").first.fetch("results").first

      assert_equal "2.1.0", sarif.fetch("version")
      assert_equal "slopcop-zig-vopr-uncovered", result.fetch("ruleId")
      assert_equal path, result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")
      assert_equal 1, result.dig("locations", 0, "physicalLocation", "region", "startLine")
      assert_equal "observed", result.dig("properties", "fact_mine.proof_boundary", "claim_status")
      assert_equal "satisfiable", result.dig("properties", "fact_mine.proof_boundary", "coverage_discharge")
      assert_equal 1, sarif.dig("runs", 0, "properties", "fact_mine.proof_boundary_summary", "results_with_boundary")
    end
  end

  private

  def with_zig_file(source)
    Dir.mktmpdir do |dir|
      path = "zig/runtime/example.zig"
      FileUtils.mkdir_p(File.join(dir, "zig/runtime"))
      File.write(File.join(dir, path), "#{source}\n")
      yield dir, path
    end
  end

  def audit_for(dir, additions, coverage: [])
    evidence = SlopCop::Constraints::Evidence.from_specs(coverage, repo: dir)
    provider = SlopCop::Constraints::ZigProvider
    findings = provider.findings(repo: dir, additions: additions, evidence: evidence)
    Struct.new(:findings) do
      def to_sarif
        SlopCop::Constraints::Sarif.render(findings, rules: SlopCop::Constraints::ZigProvider.rules)
      end
    end.new(findings)
  end

  def cobertura(dir, path, hits)
    coverage = File.join(dir, "coverage.xml")
    lines = hits.map do |line, count|
      %(<line number="#{line}" hits="#{count}"/>)
    end.join("\n")
    File.write(coverage, <<~XML)
      <?xml version="1.0" ?>
      <coverage>
        <sources><source>#{dir}</source></sources>
        <packages><package name=""><classes>
          <class name="example" filename="#{path}">
            <lines>
              #{lines}
            </lines>
          </class>
        </classes></package></packages>
      </coverage>
    XML
    coverage
  end
end
