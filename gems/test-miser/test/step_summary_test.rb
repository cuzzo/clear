# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "tmpdir"

class StepSummaryTest < Minitest::Test
  SCRIPT = File.expand_path("../../../tools/test_miser_step_summary.rb", __dir__)

  def run_summary(*argv)
    stdout, stderr, status = Open3.capture3("ruby", SCRIPT, *argv)
    assert status.success?, stderr
    stdout
  end

  def test_tallies_mte_and_mutant_facts_shapes_per_suite
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([File.join(dir, "ruby"), File.join(dir, "zig")])
      File.write(File.join(dir, "ruby/mutants.json"), JSON.generate(
        "schemaVersion" => "2.0",
        "files" => { "lib/a.rb" => { "mutants" => [
          { "id" => "1", "coveredBy" => ["t1"], "killedBy" => ["t1"] },
          { "id" => "2", "coveredBy" => ["t1"], "killedBy" => [] },
          { "id" => "3", "coveredBy" => [], "killedBy" => [] }
        ] } }
      ))
      File.write(File.join(dir, "ruby/suite.txt"), "ruby:gems\n")
      File.write(File.join(dir, "zig/mutant-facts.json"), JSON.generate(
        "schema" => "mutant-facts/v1",
        "mutants" => [
          { "id" => "z:1", "covered_by" => ["t"], "killed_by" => ["t"] },
          { "id" => "z:2", "covered_by" => ["t"], "killed_by" => [] }
        ],
        "test_miser" => { "suite" => "zig:clear" }
      ))

      out = run_summary(dir)
      assert_includes out, "| ruby:gems | 3 | 1 | 1 | 1 |"
      assert_includes out, "| zig:clear | 2 | 1 | 1 | 0 |"
      assert_includes out, "| **total** | **5** | **2** | **2** | **1** |"
      assert_includes out, "canonical default-branch snapshot"
    end
  end

  def test_subjects_only_facts_fall_back_to_aggregate_counts
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "facts.json"), JSON.generate(
        "schema" => "mutant-facts/v1",
        "subjects" => [{ "file" => "z.zig", "method" => "f", "mutations" => 4, "killed" => 3, "alive" => 1 }],
        "test_miser" => { "suite" => "zig:clear" }
      ))
      out = run_summary(dir)
      assert_includes out, "| zig:clear | 4 | 3 | 1 | 0 |"
    end
  end

  def test_reports_empty_run_without_failing
    Dir.mktmpdir do |dir|
      out = run_summary(dir)
      assert_includes out, "No mutation reports were produced by this run."
    end
  end
end
