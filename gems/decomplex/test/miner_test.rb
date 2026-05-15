# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class MinerTest < Minitest::Test
  def mine(ruby)
    f = Tempfile.new(["decomplex", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::Miner.new(Decomplex::SiteExtractor.extract(f.path))
  ensure
    f&.unlink
  end

  def test_case_dispatch_recomputed_across_defs_is_a_missing_abstraction
    m = mine(<<~RB)
      def a(n)
        case n
        when AST::FuncCall then 1
        when AST::MethodCall then 2
        end
      end
      def b(n)
        case n
        when AST::FuncCall then 3
        when AST::MethodCall then 4
        end
      end
    RB
    ma = m.missing_abstractions
    assert_equal 1, ma.size
    assert_equal :case_dispatch, ma.first[:kind]
    assert_equal 2, ma.first[:support]
    assert_equal 2, ma.first[:scatter]
    assert_equal %w[AST::FuncCall AST::MethodCall], ma.first[:members]
  end

  def test_a_site_missing_one_arm_is_a_neglected_condition
    # The {FuncCall, MethodCall, GetField} dispatch appears 3x; a 4th
    # site handles only {FuncCall, MethodCall} -- GetField neglected.
    body = lambda do |n, *arms|
      "def f#{n}(x)\n  case x\n" +
        arms.map { |a| "  when #{a} then 0" }.join("\n") +
        "\n  end\nend\n"
    end
    src = [
      body.call(1, "AST::FuncCall", "AST::MethodCall", "AST::GetField"),
      body.call(2, "AST::FuncCall", "AST::MethodCall", "AST::GetField"),
      body.call(3, "AST::FuncCall", "AST::MethodCall", "AST::GetField"),
      body.call(4, "AST::FuncCall", "AST::MethodCall")
    ].join("\n")
    nc = mine(src).neglected_conditions(min_support: 3)
    assert_equal 1, nc.size
    assert_equal "AST::GetField", nc.first[:missing]
    assert_equal 3, nc.first[:support]
    assert_includes nc.first[:at], "f4"
  end

  def test_conjunction_operands_are_mined
    m = mine(<<~RB)
      def a(t); return 1 if t.collection? && !t.heap? && !t.rodata?; end
      def b(t); return 2 if t.collection? && !t.heap? && !t.rodata?; end
    RB
    ma = m.missing_abstractions
    conj = ma.find { |h| h[:kind] == :conjunction }
    refute_nil conj
    assert_equal 2, conj[:scatter]
    assert_equal 3, conj[:members].size
  end

  def test_single_use_decision_is_not_flagged
    m = mine(<<~RB)
      def only(n)
        case n
        when AST::FuncCall then 1
        when AST::MethodCall then 2
        end
      end
    RB
    assert_empty m.missing_abstractions
    assert_empty m.neglected_conditions
  end
end
