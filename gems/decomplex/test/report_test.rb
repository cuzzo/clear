# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class ReportTest < Minitest::Test
  def report
    f = Tempfile.new(["rep", ".rb"])
    f.write("def a(n)\n  case n\n  when A then 1\n  when B then 2\n  end\nend\n" \
            "def b(n)\n  case n\n  when A then 3\n  when B then 4\n  end\nend\n")
    f.close
    Decomplex::Report.new([f.path])
  ensure
    @f = f
  end

  def test_nav_turns_file_method_line_into_navigable_link
    r = report
    assert_equal "`src/x.rb:15` (foo)", r.nav("src/x.rb:foo:15")
  end

  def test_nav_handles_top_level_and_colonless_paths
    r = report
    assert_equal "`a/b.rb:9` ((top-level))", r.nav("a/b.rb:(top-level):9")
  end

  def test_nav_passes_through_when_not_a_triple
    r = report
    assert_equal "already plain", r.nav("already plain")
  end

  def test_markdown_orders_sections_by_signal_tier_not_volume
    md = report.to_markdown
    prio = md[/## Project Prioritization.*?\n\n(.*?)\n\n/m, 1].to_s
    # Missing Abstractions is tier 1; it must precede any tier-2/3
    # section even though others may have more candidates.
    mi = prio.index("Missing Abstractions")
    refute_nil mi
    %w[Neglected Broken].each do |noisy|
      idx = prio.index(noisy)
      assert(idx.nil? || mi < idx, "tier-1 must precede #{noisy}")
    end
  end

  def test_findings_are_marked_possible_not_likely_bug
    md = report.to_markdown
    refute_includes md, "likely bug"
    assert_includes md, "*POSSIBLE*"
  end
end
