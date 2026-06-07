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

  def test_ignores_typed_struct_const_fact_readers_but_keeps_props
    rows = scan(<<~RB)
      class CapabilityFact < T::Struct
        const :alias_mutable, T::Boolean
        prop :remaining, Integer
      end

      sig { params(fact: CapabilityFact).void }
      def declare(fact)
        mark if fact.alias_mutable
        warn if fact.remaining
      end
    RB

    row = rows.find { |h| h[:method] == "declare" }
    refute_nil row
    assert_equal 1, row[:decisions]
    assert_includes row[:state_refs], "fact.remaining"
    refute_includes row[:state_refs], "fact.alias_mutable"
  end

  def test_ignores_multiline_sig_typed_struct_const_fact_readers
    rows = scan(<<~RB)
      class Fact < T::Struct
        const :active, T::Boolean
      end

      sig do
        params(
          fact: Fact,
        ).void
      end
      def declare(fact)
        save if fact.active
      end
    RB

    assert_empty rows
  end

  def test_ignores_typed_struct_const_fact_readers_in_bang_methods
    rows = scan(<<~RB)
      class Fact < T::Struct
        const :active, T::Boolean
      end

      sig { params(fact: Fact).void }
      def declare!(fact)
        save if fact.active
      end
    RB

    assert_empty rows
  end
end
