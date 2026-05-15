# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class SequenceMineTest < Minitest::Test
  def scan(ruby)
    f = Tempfile.new(["sm", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::SequenceMine.scan([f.path])
  ensure
    f
  end

  def test_co_called_protocol_pair_detected
    r = scan(<<~RB)
      def a; alloc_mark(x); body1; cleanup(x); end
      def b; alloc_mark(y); body2; cleanup(y); end
      def c; alloc_mark(z); body3; cleanup(z); end
      def d; alloc_mark(w); body4; cleanup(w); end
    RB
    pairs = r.co_called_pairs(min_support: 4)
    assert(pairs.any? { |h| h[:pair] == %w[alloc_mark cleanup] && h[:support] == 4 })
  end

  def test_method_calling_one_without_the_other_is_broken_protocol
    r = scan(<<~RB)
      def a; alloc_mark(x); cleanup(x); end
      def b; alloc_mark(y); cleanup(y); end
      def c; alloc_mark(z); cleanup(z); end
      def d; alloc_mark(w); cleanup(w); end
      def leak; alloc_mark(q); use(q); end
    RB
    bp = r.broken_protocol(min_support: 4)
    hit = bp.find { |h| h[:at].include?("leak") }
    refute_nil hit
    assert_equal "alloc_mark", hit[:has]
    assert_equal "cleanup", hit[:missing]
  end

  def test_confidence_suppresses_incidental_pairs_not_pervasive_protocol
    # `log` is in every method (glue); alloc_mark/cleanup is the real
    # protocol with one violator. Confidence ranking must flag the
    # alloc_mark-without-cleanup deviant and NOT flag `log` (which is
    # never "missing" anywhere), even though log is the most frequent.
    # Glue is glue because it also appears in unrelated contexts (e/f),
    # which drops P(cleanup|log) below threshold. Pure directed
    # confidence then keeps the real protocol and drops the glue with
    # no frequency blocklist.
    r = scan(<<~RB)
      def a; log; alloc_mark(x); cleanup(x); end
      def b; log; alloc_mark(y); cleanup(y); end
      def c; log; alloc_mark(z); cleanup(z); end
      def d; log; alloc_mark(w); cleanup(w); end
      def leak; log; alloc_mark(q); use(q); end
      def e; log; helper_one; end
      def f; log; helper_two; end
    RB
    bp = r.broken_protocol(min_support: 4, min_confidence: 0.75)
    hit = bp.find { |h| h[:at].include?("leak") }
    refute_nil hit
    assert_equal %w[alloc_mark cleanup], hit[:pair]
    assert hit[:confidence] >= 0.75
    assert(bp.none? { |h| h[:has] == "log" || h[:missing] == "log" })
  end

  def test_consistent_codebase_has_no_broken_protocol
    r = scan(<<~RB)
      def a; alloc_mark(x); cleanup(x); end
      def b; alloc_mark(y); cleanup(y); end
      def c; alloc_mark(z); cleanup(z); end
      def d; alloc_mark(w); cleanup(w); end
    RB
    assert_empty r.broken_protocol(min_support: 4)
  end
end
