# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/fix_cache"

class HotspotTest < Minitest::Test
  G = FixCache::CoverageGap::File_

  def test_hotspot_is_normalized_fix_times_gap_and_ranked
    scores = { "a.rb" => 10.0, "b.rb" => 5.0, "c.rb" => 10.0 }
    gaps = {
      "a.rb" => G.new(total: 10, uncovered: 8, gap: 0.8),  # 1.0*0.8=0.8
      "b.rb" => G.new(total: 10, uncovered: 9, gap: 0.9),  # 0.5*0.9=0.45
      "c.rb" => G.new(total: 10, uncovered: 1, gap: 0.1)   # 1.0*0.1=0.1
    }
    ranked, unmeasured = FixCache::Hotspot.rank(scores, gaps)
    assert_empty unmeasured
    assert_equal %w[a.rb b.rb c.rb], ranked.map(&:file)
    assert_in_delta 0.8, ranked[0].hotspot, 1e-6
    assert_in_delta 0.45, ranked[1].hotspot, 1e-6
    assert_in_delta 1.0, ranked[0].fix_norm, 1e-6
  end

  def test_fixed_file_without_coverage_goes_to_unmeasured
    scores = { "tracked.rb" => 3.0, "blind.rb" => 7.0 }
    gaps = { "tracked.rb" => G.new(total: 4, uncovered: 2, gap: 0.5) }
    ranked, unmeasured = FixCache::Hotspot.rank(scores, gaps)
    assert_equal %w[tracked.rb], ranked.map(&:file)
    assert_equal %w[blind.rb], unmeasured.map { |h| h[:file] }
  end

  def test_empty_scores
    ranked, unmeasured = FixCache::Hotspot.rank({}, {})
    assert_empty ranked
    assert_empty unmeasured
  end
end
