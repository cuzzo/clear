# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"
require_relative "../lib/decomplex/report"

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

  def test_transient_collection_operations_are_not_contracts
    r = rank(<<~RB)
      def a(stack)
        return nil if stack.pop.nil?
        return nil if stack.shift.nil?
      end
    RB
    assert_empty r
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

  # ---- use-role split (Rapps-Weyuker p-use / c-use) -----------------

  def test_pure_c_use_is_excluded_not_pressure
    # consumption, not a decision -> must produce NO rows.
    assert_empty rank(<<~RB)
      def a(n)
        emit(n.full_type)
        x = n.full_type
        return n.full_type
      end
    RB
  end

  def test_rescue_nil_is_an_eliminable_guard
    r = rank("def a(n)\n  y = n.full_type rescue nil\n  y\nend\n")
    top = r.first
    assert_equal ".full_type", top[:contract]
    assert_operator top[:decisions], :>=, 1, "rescue nil is eliminable"
  end

  def test_pure_essential_dispatch_is_not_a_row
    # `.string?` / `.collection?` over a contract is legitimate
    # polymorphism. With NO eliminable guard it must NOT surface as
    # pressure (telling someone to 'fix' real dispatch is the bug).
    r = rank(<<~RB)
      def a(n)
        return 1 if n.full_type.string?
        return 2 if n.full_type.collection?
      end
    RB
    assert(r.none? { |x| x[:contract] == ".full_type" },
           "essential-only contract is not pressure")
  end

  def test_eliminable_and_essential_are_split_never_summed
    r = rank(<<~RB)
      def a(n)
        ti = n.full_type
        return if ti.nil?
        x = ti.string?
        y = ti.collection?
      end
    RB
    row = r.find { |x| x[:contract] == ".full_type" }
    refute_nil row
    assert_equal 1, row[:decisions], "decisions = ELIMINABLE only (the nil?)"
    assert_equal 2, row[:essential], "string?/collection? are essential, separate"
    refute_equal 3, row[:decisions], "the 3 must NEVER be summed"
  end

  def test_report_shows_split_with_routing_no_blended_scalar
    f = Tempfile.new(["dp", ".rb"])
    f.write(<<~RB)
      def a(n)
        ti = n.full_type
        return if ti.nil?
        x = ti.string?
      end
    RB
    f.close
    md = Decomplex::Report.new([f.path]).to_markdown
    sec = md[/## Decision Pressure.*?\n(.*?)\n## /m, 1].to_s
    assert_includes sec, "ELIMINABLE"
    assert_includes sec, "essential dispatch"
    assert_includes sec, "nil-kill: DELETE"
    refute_match(/\*\*2\*\* (defensive|decisions)/, sec,
                 "must not present eliminable+essential as one number")
  ensure
    f&.unlink
  end

  def test_scan_does_not_use_legacy_ast_parse
    Decomplex::Ast.stub(:parse, ->(*) { raise "legacy Ast.parse should not be used" }) do
      r = rank(<<~RB)
        def a(node)
          ti = node.full_type
          return 1 if ti.is_a?(Type)
        end
      RB

      assert_equal ".full_type", r.first[:contract]
    end
  end
end
