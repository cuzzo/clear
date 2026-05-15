# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class SemanticAliasTest < Minitest::Test
  def scan(ruby)
    f = Tempfile.new(["sa", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::SemanticAlias.scan([f.path])
  ensure
    f
  end

  def test_canon_strips_receiver_polarity_and_self_ivar
    c = Decomplex::SemanticAlias.canon("node.provenance == :frame")
    assert_equal "provenance == :frame", c
    assert_equal "provenance == :frame", Decomplex::SemanticAlias.canon("@provenance == :frame")
    assert_equal "provenance == :frame", Decomplex::SemanticAlias.canon("self.provenance == :frame")
    t, neg = Decomplex::Ast.canon_polarity("!x.heap?")
    assert_equal "x.heap?", t
    assert neg
  end

  def test_two_predicate_names_same_canonical_body_cluster
    r = scan(<<~RB)
      def frame?; @provenance == :frame; end
      def is_frame?; provenance == :frame; end
      def heap?; @provenance == :heap; end
    RB
    cl = r.alias_clusters
    assert_equal 1, cl.size
    assert_equal %w[frame? is_frame?].sort, cl.first[:names].sort
  end

  def test_inline_comparison_equal_to_a_predicate_body_is_a_reification_miss
    r = scan(<<~RB)
      def frame?; @provenance == :frame; end
      def somewhere(node)
        return 1 if node.provenance == :frame
      end
    RB
    rm = r.reification_misses
    assert_equal 1, rm.size
    assert_equal "frame?", rm.first[:predicate]
    assert_includes rm.first[:at], "somewhere"
  end

  def test_predicate_own_body_is_not_a_self_reification_miss
    r = scan("def frame?; @provenance == :frame; end\n")
    assert_empty r.reification_misses
  end

  def test_distinct_predicates_do_not_cluster_or_misfire
    r = scan(<<~RB)
      def frame?; @provenance == :frame; end
      def heap?; @provenance == :heap; end
      def use(n); n.provenance == :heap ? 1 : 2; end
    RB
    assert_empty r.alias_clusters
    rm = r.reification_misses
    assert_equal 1, rm.size
    assert_equal "heap?", rm.first[:predicate]
  end
end
