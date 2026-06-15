#!/usr/bin/env ruby
# frozen_string_literal: true

# Emit Lineage test-exposure JSON from Zig systems-test coverage.
#
# This is the bridge between the existing Zig safety coverage tools and
# Lineage's language-neutral `test_exposure_events` table. Loom and VOPR
# keep their specialized site classifiers in tools/; this script only
# converts covered sites into the generic Lineage side-input format.

require "json"
require "optparse"

require_relative "loom_atomic_coverage"
require_relative "vopr_coverage"

module LineageZigSystemExposure
  module_function

  DEFAULT_LOOM = "zig/zig-out/coverage-loom/merged/kcov-merged/cobertura.xml"
  DEFAULT_VOPR = "zig/zig-out/coverage-vopr/merged/kcov-merged/cobertura.xml"
  DEFAULT_SCOPE = "zig/runtime,zig/lib"

  def run(argv)
    opts = {
      repo: File.expand_path("..", __dir__),
      loom: DEFAULT_LOOM,
      vopr: DEFAULT_VOPR,
      scope: DEFAULT_SCOPE,
      output: nil,
      include_tests: false
    }

    OptionParser.new do |o|
      o.banner = "Usage: ruby tools/lineage_zig_system_exposure.rb [options]"
      o.on("--repo PATH", "Repository root") { |v| opts[:repo] = v }
      o.on("--loom PATH", "Loom Cobertura XML path") { |v| opts[:loom] = v }
      o.on("--vopr PATH", "VOPR Cobertura XML path") { |v| opts[:vopr] = v }
      o.on("--scope DIRS", "Comma-separated dirs to scan") { |v| opts[:scope] = v }
      o.on("--output PATH", "Write JSON to path instead of stdout") { |v| opts[:output] = v }
      o.on("--include-tests", "Include test/harness files in site scan") { opts[:include_tests] = true }
      o.on("-h", "--help") do
        puts o
        exit 0
      end
    end.parse!(argv)

    repo = File.expand_path(opts[:repo])
    scope = opts[:scope].split(",").map(&:strip).reject(&:empty?)
    hits = []
    hits.concat(loom_hits(repo, scope, opts[:loom], include_tests: opts[:include_tests]))
    hits.concat(vopr_hits(repo, scope, opts[:vopr], include_tests: opts[:include_tests]))

    payload = {
      "schema" => "test-exposure/v1",
      "producer" => "tools/lineage_zig_system_exposure.rb",
      "note" => "One record per Zig systems hazard site covered by typed kcov evidence.",
      "hits" => hits.sort_by { |hit| [hit.fetch("file"), hit.fetch("line"), hit.fetch("test_type")] }
    }
    json = JSON.pretty_generate(payload)
    if opts[:output]
      File.write(opts[:output], "#{json}\n")
      warn "wrote #{opts[:output]} (#{hits.size} hits)"
    else
      puts json
      warn "emitted #{hits.size} hits"
    end
  end

  def loom_hits(repo, scope, coverage, include_tests:)
    coverage_path = File.expand_path(coverage, repo)
    unless File.file?(coverage_path)
      warn "Loom Cobertura XML not found: #{coverage_path}"
      warn "Generate it with: (cd zig && zig build coverage-loom -Dcoverage-loom)"
      return []
    end

    coverage_hits = LoomAtomicCoverage.parse_cobertura(coverage_path)
    sites = LoomAtomicCoverage.scan_atomic_sites(scope, repo, include_tests: include_tests)
    LoomAtomicCoverage.correlate(sites, coverage_hits).filter_map do |site|
      direct = site[:hits].to_i.positive?
      elided = site[:kcov_elided]
      next unless direct || elided

      exposure_record(
        site,
        test_type: "loom",
        test_id: "zig:loom:#{site[:file]}:#{site[:line]}",
        evidence: elided ? "kcov-elided" : "direct",
        hits: site[:hits]
      )
    end
  end

  def vopr_hits(repo, scope, coverage, include_tests:)
    coverage_path = File.expand_path(coverage, repo)
    unless File.file?(coverage_path)
      warn "VOPR Cobertura XML not found: #{coverage_path}"
      warn "Generate it with: (cd zig && zig build coverage-vopr -Dcoverage-vopr)"
      return []
    end

    coverage_hits = VoprCoverage.parse_cobertura(coverage_path)
    sites = VoprCoverage.scan_sites(scope, repo, include_tests: include_tests)
    VoprCoverage.correlate(sites, coverage_hits).filter_map do |site|
      next unless site[:hits].to_i.positive?

      exposure_record(
        site,
        test_type: "vopr",
        test_id: "zig:vopr:#{site[:category]}:#{site[:file]}:#{site[:line]}",
        evidence: site[:category].to_s,
        hits: site[:hits]
      )
    end
  end

  def exposure_record(site, test_type:, test_id:, evidence:, hits:)
    {
      "file" => site[:file],
      "line" => site[:line],
      "context_line" => site[:source].to_s.strip,
      "test_id" => test_id,
      "test_type" => test_type,
      "evidence" => evidence,
      "hits" => hits.to_i
    }
  end
end

LineageZigSystemExposure.run(ARGV) if __FILE__ == $PROGRAM_NAME
