# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tempfile"
require "tmpdir"
require_relative "../lib/boobytrap"

class LineageRiskTest < Minitest::Test
  def test_load_invokes_lineage_json_summary
    db = Tempfile.new(["lineage", ".sqlite"])
    db.write("placeholder")
    db.close
    cmd = Tempfile.new(["lineage-command", ".rb"])
    cmd.write(<<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      puts JSON.dump([
        {
          "id" => "u1",
          "name" => "compile",
          "kind" => "function",
          "original_path" => "src/compiler.rb",
          "total_events" => 7,
          "changes" => 2,
          "moves" => 1,
          "fixes" => 4,
          "risk_score" => 3.5,
          "current_distinct_tests" => 2,
          "current_test_types" => "integration,unit",
          "current_mutant_verified_tests" => 1,
          "current_mutant_killed_tests" => 1,
          "last_test_exposure_at" => 20,
          "latest_fix_at" => 10,
          "fixes_after_test_exposure" => 0
        }
      ])
    RUBY
    cmd.close
    File.chmod(0o755, cmd.path)

    data = Boobytrap::LineageRisk.load(
      db.path,
      repo: Dir.pwd,
      only: ["src/"],
      command: cmd.path
    )

    assert_equal :ok, data[:status]
    unit = data[:index].fetch(["src/compiler.rb", "compile"])
    assert_equal 3.5, unit.risk_score
    assert_equal 4, unit.fixes
    assert data[:has_test_exposure]
    assert_equal ["integration", "unit"], unit.current_test_types
    assert_equal "lineage: 2 tests; integration/unit; mutant killed 1/1; hardened after latest fix",
                 Boobytrap::LineageRisk.test_exposure_status(unit)
    assert_equal "mutation-killed exposure (lineage)",
                 Boobytrap::LineageRisk.exposure_profile(unit)
    assert_operator Boobytrap::LineageRisk.exposure_multiplier(
      unit,
      active: true,
      complexity: 8,
      history: 1.0,
      coverage_gap: 1.0
    ), :<, 1.0
  ensure
    db&.unlink
    cmd&.unlink
  end

  def test_stale_lineage_test_exposure_is_reported_but_not_discounted
    unit = Boobytrap::LineageRisk.unit_from_json(
      "id" => "u1",
      "name" => "compile",
      "kind" => "function",
      "original_path" => "src/compiler.rb",
      "total_events" => 7,
      "changes" => 2,
      "moves" => 1,
      "fixes" => 4,
      "risk_score" => 3.5,
      "current_distinct_tests" => 3,
      "current_test_types" => "unit",
      "current_mutant_verified_tests" => 3,
      "current_mutant_killed_tests" => 3,
      "last_test_exposure_at" => 10,
      "latest_fix_at" => 20,
      "fixes_after_test_exposure" => 1
    )

    assert_equal "stale lineage exposure ignored",
                 Boobytrap::LineageRisk.exposure_profile(unit)
    assert_includes Boobytrap::LineageRisk.test_exposure_status(unit),
                    "ignored: 1 later fix(es)"
    assert_equal 1.0, Boobytrap::LineageRisk.exposure_multiplier(
      unit,
      active: true,
      complexity: 8,
      history: 1.0,
      coverage_gap: 1.0
    )
  end

  def test_load_falls_back_to_cargo_when_local_binary_is_stale
    Dir.mktmpdir do |dir|
      db = File.join(dir, "lineage.sqlite")
      File.write(db, "placeholder")
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(File.join(repo, "gems", "lineage", "target", "release"))
      FileUtils.mkdir_p(File.join(repo, "gems", "lineage"))
      File.write(File.join(repo, "gems", "lineage", "Cargo.toml"), "[package]\n")
      stale = File.join(repo, "gems", "lineage", "target", "release", "lineage")
      File.write(stale, <<~SH)
        #!/bin/sh
        echo "error: unexpected argument '--format' found" >&2
        exit 2
      SH
      File.chmod(0o755, stale)

      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      cargo = File.join(bin, "cargo")
      File.write(cargo, <<~SH)
        #!/bin/sh
        printf '%s\n' '[{"id":"u2","name":"branchy","kind":"function","original_path":"src/branchy.zig","total_events":4,"changes":1,"moves":2,"fixes":1,"risk_score":2.25}]'
      SH
      File.chmod(0o755, cargo)

      old_path = ENV["PATH"]
      ENV["PATH"] = "#{bin}:#{old_path}"
      data = Boobytrap::LineageRisk.load(db, repo: repo, only: ["src/"])

      assert_equal :ok, data[:status]
      unit = data[:index].fetch(["src/branchy.zig", "branchy"])
      assert_equal 2.25, unit.risk_score
      assert_equal 2, unit.moves
    ensure
      ENV["PATH"] = old_path
    end
  end
end
