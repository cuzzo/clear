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

  # Class-1 FP (the dominant one): a binding assigned from a
  # conditional whose arm computes a local used to PRODUCE that
  # binding. Pre-fix this flagged `init` "derived from is_move;
  # is_move reassigned" -- a false positive. Must now be empty.
  def test_branch_local_init_is_not_flagged
    out = scan(<<~RB)
      def f(node)
        init = if node.list?
                 is_move = node.move?
                 is_move ? node.a : node.b
               end
        use(init)
      end
    RB
    assert_empty out, "branch-local init is not a method-scope reassignment"
  end

  # Fail-safety regression: a GENUINE top-level reassignment is still
  # caught even when its own RHS is a conditional (we only stop
  # descending INTO a conditional RHS; the LASGN itself is still
  # recorded). Proves the rule cannot mask the real desync.
  def test_real_desync_with_conditional_rhs_still_flagged
    out = scan(<<~RB)
      def f(a)
        b = transform(a)
        a = if cond then x else y end
        use(b)
      end
    RB
    assert_equal 1, out.size
    assert_equal "b", out.first[:derived]
    assert_equal "a", out.first[:source]
  end

  def test_scan_does_not_use_legacy_ast_parse
    Decomplex::Ast.stub(:parse, ->(*) { raise "legacy Ast.parse should not be used" }) do
      out = scan(<<~RB)
        def f(a)
          b = a + 1
          a = recompute(a)
          use(b)
        end
      RB

      assert_equal 1, out.size
    end
  end
end
