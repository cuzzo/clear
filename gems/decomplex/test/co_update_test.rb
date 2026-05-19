# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class CoUpdateTest < Minitest::Test
  def scan(ruby)
    f = Tempfile.new(["cu", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::CoUpdate.scan([f.path])
  ensure
    f&.unlink
  end

  def test_co_written_pair_detected_across_methods
    r = scan(<<~RB)
      def a(n); n.storage = :heap; n.provenance = :heap; end
      def b(n); n.storage = :heap; n.provenance = :heap; end
      def c(n); n.storage = :heap; n.provenance = :heap; end
    RB
    pairs = r.co_written_pairs(min_support: 3)
    assert_equal 1, pairs.size
    assert_equal %w[provenance storage], pairs.first[:pair]
    assert_equal 3, pairs.first[:support]
  end

  def test_a_method_writing_one_without_the_other_is_a_neglected_update
    r = scan(<<~RB)
      def a(n); n.storage = :heap; n.provenance = :heap; end
      def b(n); n.storage = :heap; n.provenance = :heap; end
      def c(n); n.storage = :heap; n.provenance = :heap; end
      def bug(n); n.storage = :heap; end
    RB
    nu = r.neglected_updates(min_support: 3)
    assert_equal 1, nu.size
    assert_equal "storage", nu.first[:has]
    assert_equal "provenance", nu.first[:missing]
    assert_includes nu.first[:at], "bug"
    assert_equal "n", nu.first[:recv]
  end

  def test_consistent_codebase_has_no_neglected_update
    r = scan(<<~RB)
      def a(n); n.storage = :heap; n.provenance = :heap; end
      def b(n); n.storage = :heap; n.provenance = :heap; end
      def c(n); n.storage = :heap; n.provenance = :heap; end
    RB
    assert_empty r.neglected_updates(min_support: 3)
  end

  # Regression: indexed assignment must not manufacture `["[]", *]`
  # pairs, and must not mask a real attr pairing.
  def test_indexed_assignment_is_not_mined
    r = scan(<<~RB)
      def build; e = {}; e[:kind] = 1; e[:alloc] = 2; e; end
      def from(h); e = {}; h.each { |k, v| e[k] = v }; e; end
      def a(n); n.storage = :heap; n.provenance = :heap; end
      def b(n); n.storage = :heap; n.provenance = :heap; end
      def c(n); n.storage = :heap; n.provenance = :heap; end
    RB
    pairs = r.co_written_pairs(min_support: 3)
    assert_equal 1, pairs.size
    assert_equal %w[provenance storage], pairs.first[:pair]
    refute(pairs.any? { |h| h[:pair].include?("[]") })
    assert_empty r.neglected_updates(min_support: 3)
  end
end
