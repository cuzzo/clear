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

  def test_declarative_ruby_and_sorbet_calls_are_not_protocol_events
    r = scan(<<~RB)
      extend T::Sig
      sig { params(x: T.untyped).returns(T::Boolean) }
      def a(x); x.nil?; end
      sig { returns(T::Boolean) }
      def b; true; end
      sig { returns(T.nilable(String)) }
      def c; nil; end
      sig { params(x: T.any(String, Symbol)).void }
      def d(x); nil; end
      private_class_method def self.e; nil; end
    RB

    mids = r.co_called_pairs(min_support: 1).flat_map { |h| h[:pair] }.uniq
    refute_includes mids, "sig"
    refute_includes mids, "params"
    refute_includes mids, "returns"
    refute_includes mids, "untyped"
    refute_includes mids, "nilable"
    refute_includes mids, "any"
    refute_includes mids, "void"
    refute_includes mids, "extend"
    refute_includes mids, "private_class_method"
  end

  def test_test_dsl_calls_are_not_protocol_events
    r = scan(<<~RB)
      describe "pipeline" do
        let(:item) { build_item }

        it "checks matcher chains" do
          expect(build_item).to eq(item)
          expect(build_item).not_to be_nil
          expect(build_item).to be_a(Item)
          expect { run_pipeline }.to raise_error(RuntimeError)
        end
      end
    RB

    mids = r.co_called_pairs(min_support: 1).flat_map { |h| h[:pair] }.uniq
    %w[
      be_a be_nil describe eq expect it let not_to raise_error to
    ].each do |mid|
      refute_includes mids, mid
    end
    assert_includes mids, "build_item"
    assert_includes mids, "run_pipeline"
  end

  def test_passive_zero_arg_readers_are_not_protocol_events
    r = scan(<<~RB)
      def a(node); node.name; node.type; visit(node); end
      def b(node); node.name; node.type; visit(node); end
      def c(node); node.name; node.type; visit(node); end
      def d(node); node.name; node.type; visit(node); end
      def e(node); node.name; visit(node); end
    RB

    mids = r.co_called_pairs(min_support: 1).flat_map { |h| h[:pair] }.uniq
    refute_includes mids, "name"
    refute_includes mids, "type"
    assert_empty r.broken_protocol(min_support: 4)
  end

  def test_zero_arg_lifecycle_calls_remain_protocol_events
    r = scan(<<~RB)
      def a(lock); lock.acquire; work(lock); lock.release; end
      def b(lock); lock.acquire; work(lock); lock.release; end
      def c(lock); lock.acquire; work(lock); lock.release; end
      def d(lock); lock.acquire; work(lock); lock.release; end
      def leak(lock); lock.acquire; work(lock); end
    RB

    bp = r.broken_protocol(min_support: 4)
    hit = bp.find { |h| h[:at].include?("leak") }
    refute_nil hit
    assert_equal "acquire", hit[:has]
    assert_equal "release", hit[:missing]
  end
end
