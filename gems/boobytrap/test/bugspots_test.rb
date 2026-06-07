# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/boobytrap"

class BugspotsTest < Minitest::Test
  B = Boobytrap::Bugspots

  def test_parse_log_keeps_only_fix_commits_with_files
    log = <<~LOG
      @@@1000\tFix the alloc leak
      src/a.rb
      src/b.rb
      @@@1100\tAdd a shiny feature
      src/c.rb
      @@@1200\tbugfix: double free
      src/a.rb
      @@@1300\tRefactor naming
      src/d.rb
    LOG
    ev = B.parse_log(log)
    assert_equal 2, ev.size
    assert_equal %w[src/a.rb src/b.rb], ev[0].files
    assert_equal %w[src/a.rb], ev[1].files
    refute(ev.any? { |e| e.subject.include?("feature") || e.subject.include?("Refactor") })
  end

  def test_fix_regex_matches_clear_convention_and_variants
    %w[Fix Fixes Fixed fixed close closes closed].each do |w|
      assert B.fix?("#{w} something", B::FIX_RE), w
    end
    assert B.fix?("bug fix: x", B::FIX_RE)
    refute B.fix?("Add feature", B::FIX_RE)
    refute B.fix?("Simplify Puck tokenization", B::FIX_RE)
  end

  def test_score_weights_recent_fixes_higher
    old = B::Event.new(time: 0,    subject: "fix", files: %w[old.rb])
    new = B::Event.new(time: 1000, subject: "fix", files: %w[new.rb])
    s = B.score([old, new])
    assert s["new.rb"] > s["old.rb"], "recent fix must outweigh old"
  end

  def test_score_accumulates_per_file_across_fixes
    e1 = B::Event.new(time: 500,  subject: "fix", files: %w[hot.rb cold.rb])
    e2 = B::Event.new(time: 1000, subject: "fix", files: %w[hot.rb])
    s = B.score([e1, e2])
    assert s["hot.rb"] > s["cold.rb"]
  end

  def test_score_empty_and_single
    assert_empty B.score([])
    one = B::Event.new(time: 42, subject: "fix", files: %w[x.rb])
    # span 0 -> t=1 -> w = 1/(1+e^0) = 0.5
    assert_in_delta 0.5, B.score([one])["x.rb"], 1e-9
  end

  def test_blast_radius_weights_recent_multi_file_fixes
    old = B::Event.new(time: 0, subject: "fix", files: %w[src/a.rb src/b.rb])
    new = B::Event.new(time: 1000, subject: "fix", files: %w[src/c.rb src/d.rb src/e.rb])

    rows = B.blast_radius([old, new])
    c = rows.find { |r| r.file == "src/c.rb" }
    a = rows.find { |r| r.file == "src/a.rb" }

    assert_operator c.score, :>, a.score
    assert_equal 3.0, c.avg_touched
    assert_equal 3, c.max_touched
    assert_equal 2, c.partners.size
  end

  def test_blast_radius_accumulates_partners_per_file
    e1 = B::Event.new(time: 0, subject: "fix", files: %w[src/a.rb src/b.rb])
    e2 = B::Event.new(time: 10, subject: "fix", files: %w[src/a.rb src/b.rb src/c.rb])

    a = B.blast_radius([e1, e2]).find { |r| r.file == "src/a.rb" }

    assert_equal 2, a.fixes
    assert_equal 2.5, a.avg_touched
    assert_equal "src/b.rb", a.partners.first.first
  end
end
