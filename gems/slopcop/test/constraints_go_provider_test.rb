# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/slopcop"

class ConstraintsGoProviderTest < Minitest::Test
  def test_go_provider_is_registered
    assert_same SlopCop::Constraints::GoProvider, SlopCop::Constraints.providers.fetch("go")
  end

  def test_scans_go_concurrency_hazards
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "worker.go"), <<~GO)
        package demo

        import "sync/atomic"

        func run(ch chan int) {
          go func() { ch <- 1 }()
          _ = atomic.LoadInt64(&counter)
          // go ignored()
        }
      GO

      hazards = SlopCop::Constraints::GoProvider.scan_hazards(repo: dir)

      hazard_types = hazards.map { |hazard| hazard[:hazard_type] }
      assert_includes hazard_types, "go_race_goroutine"
      assert_includes hazard_types, "go_concurrency_channel"
      assert_includes hazard_types, "go_race_atomic"
      refute hazards.any? { |hazard| hazard[:source].include?("ignored") }
    end
  end

  def test_findings_are_suppressed_by_matching_coverage_evidence
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "worker.go"), <<~GO)
        package demo

        func run(ch chan int) {
          go func() { ch <- 1 }()
        }
      GO
      coverage = File.join(dir, "coverage.json")
      File.write(
        coverage,
        JSON.dump(
          coverage: {
            "worker.go" => {
              "4" => 1
            }
          }
        )
      )
      evidence = SlopCop::Constraints::Evidence.from_specs(["race:#{coverage}", "concurrency:#{coverage}"], repo: dir)

      findings = SlopCop::Constraints::GoProvider.findings(
        repo: dir,
        additions: { "worker.go" => [4] },
        evidence: evidence
      )

      assert_empty findings
    end
  end

  def test_uncovered_changed_go_hazard_gets_finding
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "worker.go"), <<~GO)
        package demo

        func run(ch chan int) {
          ch <- 1
        }
      GO
      evidence = SlopCop::Constraints::Evidence.from_specs([], repo: dir)

      findings = SlopCop::Constraints::GoProvider.findings(
        repo: dir,
        additions: { "worker.go" => [4] },
        evidence: evidence
      )

      assert_equal 1, findings.length
      assert_equal "slopcop-go-concurrency-uncovered", findings.first.rule_id
      assert_equal "go_concurrency_channel", findings.first.hazard_type
    end
  end
end
