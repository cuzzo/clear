# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class DecisionPressureTest < Minitest::Test
  def rank(ruby)
    f = Tempfile.new(["dp", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::DecisionPressure.scan([f.path]).ranked
  ensure
    f&.unlink
  end

  def test_local_is_resolved_to_the_accessor_it_came_from
    # Two methods, both `ti = node.full_type; ... ti.is_a?(Type)`.
    # The proximate local `ti` must attribute to `.full_type`, and the
    # contract must aggregate across both methods.
    r = rank(<<~RB)
      def a(node)
        ti = node.full_type
        return 1 if ti.is_a?(Type)
      end
      def b(node)
        ti = node.full_type
        return 2 if ti.is_a?(Type)
      end
    RB
    top = r.first
    assert_equal ".full_type", top[:contract]
    assert_equal 2, top[:decisions]
    assert_equal 2, top[:methods]
  end

  def test_hash_key_and_ivar_contracts_are_distinct_and_ranked
    r = rank(<<~RB)
      def a(p)
        return 1 if p[:type].is_a?(Type)
        return 2 if p[:type].nil?
        return 3 if @schema.respond_to?(:x)
      end
    RB
    by = r.to_h { |x| [x[:contract], x[:decisions]] }
    assert_equal 2, by["[:type]"]
    assert_equal 1, by["@schema"]
  end

  def test_safe_nav_counts_as_a_nil_decision_on_its_receiver
    r = rank(<<~RB)
      def a(node)
        x = node.type_info&.heap?
        return x
      end
    RB
    assert_equal ".type_info", r.first[:contract]
    assert_equal 1, r.first[:decisions]
  end

  def test_unresolved_local_is_low_signal_and_sorts_last
    r = rank(<<~RB)
      def a(thing)
        return 1 if thing.is_a?(Type)
        return 2 if other.full_type.is_a?(Type)
      end
    RB
    # .full_type is a named contract -> ranked above the ~local bucket
    assert_equal ".full_type", r.first[:contract]
    assert_equal "~local", r.last[:contract]
  end

  def test_no_guards_no_rows
    assert_empty rank("def a(x); return x + 1; end\n")
  end
end
