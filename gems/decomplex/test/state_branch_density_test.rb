# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class StateBranchDensityTest < Minitest::Test
  def setup
    @files = []
  end

  def teardown
    @files.each(&:unlink)
  end

  def scan(src)
    f = Tempfile.new(["state_branch", ".rb"])
    f.write(src)
    f.close
    @files << f
    Decomplex::StateBranchDensity.scan([f.path]).findings
  end

  def test_flags_branches_over_ivars_globals_and_object_attributes
    rows = scan(<<~RB)
      $enabled = true
      def risky(user)
        if @ready
          pay if user.name
        end
        return unless $enabled
        process if user.admin?
      end
    RB

    row = rows.find { |h| h[:method] == "risky" }
    refute_nil row
    assert_equal 4, row[:decisions]
    assert_includes row[:state_refs], "@ready"
    assert_includes row[:state_refs], "$enabled"
    assert_includes row[:state_refs], "user.name"
    assert_includes row[:state_refs], "user.admin?"
    assert_operator row[:score], :>=, 4
  end

  def test_does_not_count_pure_local_input_branch
    rows = scan(<<~RB)
      def pure(a, b)
        if a == 0
          b + 1
        else
          b - 1
        end
      end
    RB

    assert_empty rows
  end

  def test_groups_multiple_state_branches_per_method_and_keeps_spans
    rows = scan(<<~RB)
      def lifecycle(order)
        if order.status == :paid
          ship
        end
        if @discount
          apply
        end
      end
    RB

    row = rows.first
    assert_equal 2, row[:decisions]
    assert_equal 2, row[:sites].size
    assert_equal 2, row[:spans].size
    assert_match(/order\.status/, row[:predicate])
  end
end
