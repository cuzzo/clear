# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class TemporalOrderingPressureTest < Minitest::Test
  def setup
    @files = []
  end

  def teardown
    @files.each(&:unlink)
  end

  def scan(src)
    f = Tempfile.new(["temporal", ".rb"])
    f.write(src)
    f.close
    @files << f
    Decomplex::TemporalOrderingPressure.scan([f.path])
  end

  def test_flags_public_mutable_lifecycle_surface
    rows = scan(<<~RB)
      class BillingService
        def set_user(user); @user = user; end
        def set_cart(cart); @cart = cart; end
        def validate_user; fail unless @user; @validated = true; end
        def apply_discount; @discount = true if @cart; end
        def process_payment; pay(@user, @cart, @discount); end
      end
    RB

    row = rows.find { |h| h[:owner] == "BillingService" }
    refute_nil row
    assert_equal 5, row[:public_methods]
    assert_equal 5, row[:state_methods]
    assert_operator row[:writers], :>=, 4
    assert_includes row[:shared_fields], "@user"
    assert_includes row[:shared_fields], "@cart"
    assert_equal "5!", row[:orderings]
    assert_equal "2^4", row[:state_space]
  end

  def test_private_helpers_do_not_create_external_ordering_pressure
    rows = scan(<<~RB)
      class InternalPhase
        def run; @state = :start; helper_one; helper_two; @state; end
        private
        def helper_one; @state = :one; end
        def helper_two; @state = :two; end
      end
    RB

    assert_empty rows
  end

  def test_requires_shared_state_not_just_many_independent_writers
    rows = scan(<<~RB)
      class IndependentSetters
        def set_a(v); @a = v; end
        def set_b(v); @b = v; end
        def set_c(v); @c = v; end
      end
    RB

    assert_empty rows
  end
end
