# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../vopr_coverage"
require_relative "../loom_atomic_coverage"

class ZigHazardCoverageTest < Minitest::Test
  def test_nested_retry_ranges_keep_parent_open
    Dir.mktmpdir do |repo|
      source_dir = File.join(repo, "zig", "runtime")
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "nested.zig"), <<~ZIG)
        // VOPR-START-RETRY
        outer_before();
        // VOPR-START-RETRY
        inner();
        // VOPR-END-RETRY
        outer_after();
        // VOPR-END-RETRY
      ZIG

      sites = VoprCoverage.scan_sites(["zig/runtime"], repo)
      bodies = sites.select { |site| site[:category] == :retry_body }.map { |site| site[:source].strip }
      assert_equal ["outer_before();", "inner();", "outer_after();"], bodies
    end
  end

  def test_retry_body_omits_uninstrumentable_scope_punctuation
    refute VoprCoverage.executable_retry_line?("}")
    refute VoprCoverage.executable_retry_line?("} else {")
    assert VoprCoverage.executable_retry_line?("while (true) {")
    assert VoprCoverage.executable_retry_line?("return value;")
  end

  def test_dwarf_hidden_lines_are_not_actionable_gaps
    hidden = { hits: nil, file_loaded: true, dwarf_hidden: true, kcov_elided: false }
    zero_hit = { hits: 0, file_loaded: true, dwarf_hidden: false, kcov_elided: false }
    unloaded = { hits: nil, file_loaded: false, dwarf_hidden: false, kcov_elided: false }

    refute VoprCoverage.actionable_gap?(hidden)
    refute LoomAtomicCoverage.actionable_gap?(hidden)
    assert VoprCoverage.actionable_gap?(zero_hit)
    assert LoomAtomicCoverage.actionable_gap?(unloaded)
  end
end
