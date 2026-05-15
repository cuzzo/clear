# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class DerivedStateTest < Minitest::Test
  def scan(ruby)
    f = Tempfile.new(["ds", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::DerivedState.scan([f.path])
  ensure
    f
  end

  def test_stale_derived_copy_is_flagged
    out = scan(<<~RB)
      def f(a)
        b = a + 1
        a = recompute(a)
        use(b)
      end
    RB
    assert_equal 1, out.size
    assert_equal "b", out.first[:derived]
    assert_equal "a", out.first[:source]
  end

  def test_recomputed_derived_is_not_flagged
    out = scan(<<~RB)
      def f(a)
        b = a + 1
        a = recompute(a)
        b = a + 1
        use(b)
      end
    RB
    assert_empty out
  end

  def test_source_not_reassigned_is_not_flagged
    out = scan(<<~RB)
      def f(a)
        b = a + 1
        use(b)
        use(a)
      end
    RB
    assert_empty out
  end

  def test_reassignment_before_derivation_is_not_flagged
    out = scan(<<~RB)
      def f(a)
        a = normalize(a)
        b = a + 1
        use(b)
      end
    RB
    assert_empty out
  end

  def test_multiple_independent_methods
    out = scan(<<~RB)
      def good(a); b = a + 1; b = a + 1 if a; use(b); end
      def bad(a); c = a * 2; a = a + 1; use(c); end
    RB
    assert_equal 1, out.size
    assert_equal "bad", out.first[:defn]
    assert_equal "c", out.first[:derived]
  end
end
