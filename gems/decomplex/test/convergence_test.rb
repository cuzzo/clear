# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class ConvergenceTest < Minitest::Test
  C = Decomplex::Convergence

  # ---- parse_loc ------------------------------------------------------

  def test_parse_loc_three_part
    assert_equal ["src/a.rb", "foo", "12"], C.parse_loc("src/a.rb:foo:12")
  end

  def test_parse_loc_two_part_no_line
    assert_equal ["src/a.rb", "foo", nil], C.parse_loc("src/a.rb:foo")
  end

  def test_parse_loc_colon_in_file_path
    # file path may contain colons; split from the right.
    assert_equal ["a:b/c.rb", "m", "9"], C.parse_loc("a:b/c.rb:m:9")
  end

  def test_parse_loc_top_level_method
    assert_equal ["a.rb", "(top-level)", "3"], C.parse_loc("a.rb:(top-level):3")
  end

  def test_parse_loc_degenerate
    assert_equal [nil, nil, nil], C.parse_loc("plain")
    assert_equal [nil, nil, nil], C.parse_loc("")
  end

  # ---- locations ------------------------------------------------------

  def test_locations_reads_only_at_refat_sites
    f = { at: "a.rb:m:1", ref_at: "b.rb:n:2",
          sites: ["c.rb:o:3", "d.rb:p:4"],
          kind: :ignored, detail: "not a location", support: 7 }
    assert_equal %w[a.rb:m:1 b.rb:n:2 c.rb:o:3 d.rb:p:4].sort,
                 C.locations(f).sort
  end

  def test_locations_ignores_non_string_and_missing
    assert_empty C.locations({ support: 3 })
    assert_empty C.locations({ at: nil, sites: nil })
    assert_equal ["x.rb:m:1"], C.locations({ at: "x.rb:m:1", sites: "bad" })
  end

  # ---- rollup ---------------------------------------------------------

  def test_unit_hit_by_two_distinct_detectors_converges
    sections = [
      ["Missing Abstractions", 1, [{ sites: ["f.rb:meth_a:10"] }]],
      ["Broken Protocols", 3, [{ at: "f.rb:meth_a:22" }]]
    ]
    r = C.rollup(sections)
    assert_equal 1, r.size
    u = r.first
    assert_equal "f.rb", u[:file]
    assert_equal "meth_a", u[:method]
    assert_equal 2, u[:n_detectors]
    assert_equal ["Broken Protocols", "Missing Abstractions"], u[:detectors]
    assert_equal 4, u[:score] # tier1=3 + tier3=1
    assert_equal 2, u[:findings]
  end

  def test_single_detector_is_not_convergence_even_if_repeated
    # one detector firing 5x on a unit is that detector's own job, not
    # convergence -- must be filtered (>=2 DISTINCT detectors).
    sections = [
      ["False Simplicity", 3,
       [{ at: "f.rb:hot:1" }, { at: "f.rb:hot:2" },
        { sites: %w[f.rb:hot:3 f.rb:hot:4 f.rb:hot:5] }]]
    ]
    assert_empty C.rollup(sections)
  end

  def test_ranking_distinct_detectors_then_tier_weight
    sections = [
      ["Decision Pressure", 1, [{ at: "f.rb:two_t1:1" }]],
      ["Missing Abstractions", 1, [{ at: "f.rb:two_t1:2" }]],
      ["Broken Protocols", 3, [{ at: "f.rb:two_t3:1" }]],
      ["False Simplicity", 3, [{ at: "f.rb:two_t3:2" }]],
      ["Neglected Conditions", 2, [{ at: "f.rb:three:1" }]],
      ["Derived-State Staleness", 2, [{ at: "f.rb:three:2" }]],
      ["Flay Similarity (Type-2/3)", 2, [{ at: "f.rb:three:3" }]]
    ]
    r = C.rollup(sections)
    # 3-detector unit ranks first (most agreement).
    assert_equal "three", r[0][:method]
    assert_equal 3, r[0][:n_detectors]
    # both remaining have 2 detectors; the two-tier-1 unit (score 6)
    # outranks the two-tier-3 unit (score 2).
    assert_equal "two_t1", r[1][:method]
    assert_equal 6, r[1][:score]
    assert_equal "two_t3", r[2][:method]
    assert_equal 2, r[2][:score]
  end

  def test_min_detectors_param
    sections = [["A", 1, [{ at: "f.rb:m:1" }]]]
    assert_empty C.rollup(sections)
    assert_equal 1, C.rollup(sections, min_detectors: 1).size
  end

  def test_nil_findings_section_skipped
    assert_empty C.rollup([["A", 1, nil], ["B", 2, nil]])
  end

  # ---- by_file --------------------------------------------------------

  def test_by_file_aggregates_units_per_file
    units = [
      { file: "f.rb", method: "a", detectors: %w[X Y], score: 5 },
      { file: "f.rb", method: "b", detectors: %w[Y Z], score: 4 },
      { file: "g.rb", method: "c", detectors: %w[X], score: 3 }
    ]
    bf = C.by_file(units)
    assert_equal 1, bf.size # g.rb has only 1 distinct detector -> dropped
    h = bf.first
    assert_equal "f.rb", h[:file]
    assert_equal %w[X Y Z], h[:detectors]
    assert_equal 3, h[:n_detectors]
    assert_equal 2, h[:methods]
    assert_equal 9, h[:score]
  end

  # ---- Report integration --------------------------------------------

  def test_report_renders_convergence_section_for_real_multi_detector_unit
    # method `a` has BOTH a duplicated case/when dispatch (Missing
    # Abstractions, tier 1, shared with `b`) AND a `send` (False
    # Simplicity, tier 3) -> two independent detectors converge on `a`.
    src = <<~RB
      def a(o)
        o.send(:x)
        case o.k
        when A then 1
        when B then 2
        end
      end
      def b(o)
        case o.k
        when A then 3
        when B then 4
        end
      end
    RB
    f = Tempfile.new(["cv", ".rb"])
    f.write(src)
    f.close
    md = Decomplex::Report.new([f.path]).to_markdown
    assert_includes md, "## Cross-Detector Convergence"
    assert_includes md, "**Start here.**"
    conv = md[/## Cross-Detector Convergence.*?\n\n(.*?)\n\n/m, 1].to_s
    # `a` is flagged by >=2 detectors; `b` by only one -> not listed.
    assert_match(/\(a\) -- \*\*2 detectors\*\*/, conv)
    assert_includes conv, "Missing Abstractions"
    assert_includes conv, "False Simplicity"
    refute_match(/\(b\)/, conv)
    # TOC + Run Summary wired
    assert_includes md, "[Cross-Detector Convergence (1)]"
    assert_includes md, "Convergence: 1 unit(s) flagged"
  ensure
    f
  end
end
