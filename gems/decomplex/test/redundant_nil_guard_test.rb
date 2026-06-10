# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

class RedundantNilGuardTest < Minitest::Test
  def scan(ruby)
    f = Tempfile.new(["rng", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::RedundantNilGuard.scan([f.path])
  ensure
    f&.unlink
  end

  def guards(ruby)
    scan(ruby).map { |finding| finding[:guard] }
  end

  def test_guard_clause_return_dominates_later_nil_check_and_safe_nav
    hits = scan(<<~RB)
      def use(x)
        return if x.nil?
        x.nil?
        x&.call
      end
    RB

    assert_equal 2, hits.size
    assert_equal ["x.nil?", "x&.call"], hits.map { |h| h[:guard] }
    assert_equal ["x"], hits.map { |h| h[:local] }.uniq
    assert(hits.all? { |h| h[:at].include?(":use:") })
    assert(hits.all? { |h| h[:spans].values.first.size == 4 })
  end

  def test_raise_guard_clause_dominates_later_safe_nav
    assert_equal ["x&.call"], guards(<<~RB)
      def use(x)
        raise if x.nil?
        x&.call
      end
    RB
  end

  def test_nested_non_nil_branches_flag_repeated_nil_guards
    hits = guards(<<~RB)
      def use(x, y)
        if !x.nil?
          x.nil?
        end
        unless y.nil?
          y&.call
        end
      end
    RB

    assert_equal ["x.nil?", "y&.call"], hits
  end

  def test_nil_comparisons_prove_non_nil_and_later_guard_is_redundant
    hits = guards(<<~RB)
      def use(x, y)
        if x != nil
          x.nil?
        end
        return if y == nil
        y.nil?
      end
    RB

    assert_equal ["x.nil?", "y.nil?"], hits
  end

  def test_truthy_guard_clause_proves_later_nil_check_and_safe_nav_redundant
    hits = guards(<<~RB)
      def use(x)
        return unless x
        x.nil?
        x&.call
      end
    RB

    assert_equal ["x.nil?", "x&.call"], hits
  end

  def test_truthy_branch_proves_later_nil_check_redundant_inside_branch
    assert_equal ["x.nil?"], guards(<<~RB)
      def use(x)
        if x
          x.nil?
        end
      end
    RB
  end

  def test_conjunction_truthy_branch_proves_each_local_non_nil
    hits = guards(<<~RB)
      def use(x, y)
        if x && y
          x.nil?
          y&.call
        end
      end
    RB

    assert_equal ["x.nil?", "y&.call"], hits
  end

  def test_conjunction_truthy_guard_clause_proves_each_local_non_nil
    hits = guards(<<~RB)
      def use(x, y)
        return unless x && y
        x&.call
        y.nil?
      end
    RB

    assert_equal ["x&.call", "y.nil?"], hits
  end

  def test_safe_nav_guard_clause_proves_receiver_non_nil
    hits = guards(<<~RB)
      def use
        return unless current_fn_ctx&.name
        current_fn_ctx&.record_heap_use!
      end
    RB

    assert_equal ["current_fn_ctx&.record_heap_use!"], hits
  end

  def test_safe_nav_guard_clause_proves_self_accessor_receiver_non_nil
    hits = scan(<<~RB)
      def use
        return unless self.current_fn_ctx&.name
        self.current_fn_ctx&.record_heap_use!
      end
    RB

    assert_equal ["self.current_fn_ctx&.record_heap_use!"], hits.map { |hit| hit[:guard] }
    assert_equal ["self.current_fn_ctx"], hits.map { |hit| hit[:local] }
  end

  def test_safe_nav_guard_does_not_track_calls_with_arguments
    assert_empty scan(<<~RB)
      def use(id)
        return unless lookup(id)&.name
        lookup(id)&.record_heap_use!
      end
    RB
  end

  def test_reader_chain_guard_proves_later_safe_nav_receiver_redundant
    hits = scan(<<~RB)
      def use(info)
        next unless info.reg
        next if info.reg&.respond_to?(:var_mutated) && info.reg.var_mutated
      end
    RB

    assert_equal ["info.reg&.respond_to?(:var_mutated)"], hits.map { |hit| hit[:guard] }
    assert_equal ["info.reg"], hits.map { |hit| hit[:local] }
  end

  def test_safe_nav_guard_does_not_prove_receiver_on_false_branch
    assert_empty scan(<<~RB)
      def use
        unless current_fn_ctx&.name
          current_fn_ctx&.record_heap_use!
        end
      end
    RB
  end

  def test_disjunction_truthy_branch_does_not_prove_each_local_non_nil
    assert_empty scan(<<~RB)
      def use(x, y)
        if x || y
          x.nil?
          y.nil?
        end
      end
    RB
  end

  def test_non_nil_proof_does_not_make_later_truthiness_guard_redundant
    assert_empty scan(<<~RB)
      def use(x)
        return if x.nil?
        return unless x
      end
    RB
  end

  def test_reassignment_invalidates_prior_non_nil_proof
    assert_empty scan(<<~RB)
      def use(x, y)
        return if x.nil?
        x = y
        x.nil?
      end
    RB
  end

  def test_non_terminating_nil_branch_does_not_dominate_following_code
    assert_empty scan(<<~RB)
      def use(x)
        if x.nil?
          warn("missing")
        end
        x.nil?
      end
    RB
  end

  def test_report_renders_redundant_nil_guard_section
    f = Tempfile.new(["rng_report", ".rb"])
    f.write(<<~RB)
      def use(x)
        return if x.nil?
        x&.call
      end
    RB
    f.close

    md = Decomplex::Report.new([f.path]).to_markdown

    assert_includes md, "## Redundant Nil Guards (1)"
    assert_includes md, "redundant nil guard on `x`"
    assert_includes md, "`x&.call`"
  ensure
    f&.unlink
  end
end
