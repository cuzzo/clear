# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class PathConditionTest < Minitest::Test
  def rep(ruby)
    f = Tempfile.new(["pc", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::PathCondition.scan([f.path])
  ensure
    @files = [f.path]
  end

  def test_nested_if_and_flat_conjunction_are_the_same_path_condition
    r = rep(<<~RB)
      def nested(x, y)
        if x.a?
          if y.b?
            do_it(x)
          end
        end
      end
      def flat(x, y)
        do_it(x) if x.a? && y.b?
      end
    RB
    sc = r.scattered(min_scatter: 2)
    assert_equal 1, sc.size, "nested-if and flat-&& must unify to one guard set"
    assert_equal %w[x.a? y.b?], sc.first[:guards]
    assert_equal 2, sc.first[:scatter]
  end

  def test_polarity_is_folded_else_branch_is_negated
    r = rep(<<~RB)
      def a(x, y)
        if x.f?
          nil
        else
          act(y) if y.g?
        end
      end
      def b(x, y)
        act(y) if !x.f? && y.g?
      end
    RB
    sc = r.scattered(min_scatter: 2)
    assert_equal 1, sc.size
    assert_includes sc.first[:guards], "!x.f?"
    assert_includes sc.first[:guards], "y.g?"
  end

  def test_neglected_path_condition_flags_the_site_missing_one_guard
    r = rep(<<~RB)
      def a(x, y, z); go(x) if x.p? && y.q? && z.r?; end
      def b(x, y, z); go(x) if x.p? && y.q? && z.r?; end
      def c(x, y, z); go(x) if x.p? && y.q? && z.r?; end
      def bug(x, y, z); go(x) if x.p? && y.q?; end
    RB
    ng = r.neglected(min_support: 3)
    assert ng.any? { |h| h[:missing] == "z.r?" && h[:at].include?("bug") }
  end

  def test_single_guard_action_is_not_a_site
    r = rep("def a(x); go if x.p?; end\ndef b(x); go if x.p?; end\n")
    assert_empty r.scattered(min_scatter: 2)
  end

  def test_clean_unique_code_yields_nothing
    r = rep(<<~RB)
      def only(x, y); go(x) if x.a? && y.b?; end
    RB
    assert_empty r.scattered(min_scatter: 2)
    assert_empty r.neglected(min_support: 3)
  end
end
