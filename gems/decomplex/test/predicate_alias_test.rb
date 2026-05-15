# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class PredicateAliasTest < Minitest::Test
  def files(ruby)
    f = Tempfile.new(["pa", ".rb"])
    f.write(ruby)
    f.close
    [f.path].tap { @f = f }
  end

  def teardown
    @f&.unlink
  end

  def test_same_body_under_two_names_is_an_alias_cluster
    pa = Decomplex::PredicateAlias.scan(files(<<~RB))
      def frame?; @provenance == :frame; end
      def is_frame?; @provenance == :frame; end
      def heap?; @provenance == :heap; end
    RB
    clusters = pa.alias_clusters
    assert_equal 1, clusters.size
    assert_equal %w[frame? is_frame?].sort, clusters.first[:names].sort
    assert_equal "@provenance == :frame", clusters.first[:body]
  end

  def test_unique_predicates_are_not_clustered
    pa = Decomplex::PredicateAlias.scan(files(<<~RB))
      def frame?; @provenance == :frame; end
      def heap?; @provenance == :heap; end
    RB
    assert_empty pa.alias_clusters
  end

  def test_multi_statement_method_is_not_treated_as_a_predicate
    pa = Decomplex::PredicateAlias.scan(files(<<~RB))
      def frame?; x = compute; @provenance == :frame; end
      def is_frame?; @provenance == :frame; end
    RB
    # only the one-liner is a Pred; no cluster of >=2
    assert_empty pa.alias_clusters
  end

  def test_reification_miss_flags_inline_reinvention
    pa = Decomplex::PredicateAlias.scan(files(<<~RB))
      def framey?; a.collection? && b.local?; end
      def somewhere
        return 1 if a.collection? && b.local?
      end
    RB
    sites = Decomplex::SiteExtractor.extract(@f.path)
    rm = pa.reification_misses(sites)
    assert_equal 1, rm.size
    assert_equal "framey?", rm.first[:predicate]
  end
end
