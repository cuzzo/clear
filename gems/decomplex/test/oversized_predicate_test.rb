# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/decomplex/oversized_predicate"

class OversizedPredicateTest < Minitest::Test
  def with_file(src)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "sample.rb")
      File.write(file, src)
      yield file
    end
  end

  def test_flags_predicates_with_more_than_three_atoms
    with_file(<<~RUBY) do |file|
      def eligible(t, info)
        if t.map? && !t.numeric_map? && !info.close_zig && !t.sharded?
          true
        else
          false
        end
      end
    RUBY
      findings = Decomplex::OversizedPredicate.scan([file]).findings

      assert_equal 1, findings.size
      assert_equal 4, findings.first[:count]
      assert_includes findings.first[:at], ":eligible:2"
      assert_includes findings.first[:predicate], "t.map?"
    end
  end

  def test_nested_or_conditions_count_as_atoms
    with_file(<<~RUBY) do |file|
      def ready(a, b, c, d)
        while a && (b || c) && d
          break
        end
      end
    RUBY
      findings = Decomplex::OversizedPredicate.scan([file]).findings

      assert_equal 1, findings.size
      assert_equal ["a", "b", "c", "d"], findings.first[:atoms]
    end
  end

  def test_three_atoms_is_not_flagged
    with_file(<<~RUBY) do |file|
      def ok?(a, b, c)
        a && b && c
      end
    RUBY
      assert_empty Decomplex::OversizedPredicate.scan([file]).findings
    end
  end

  def test_predicate_helper_implementations_are_not_flagged
    with_file(<<~RUBY) do |file|
      def plain_string_map?(t)
        if t.map? && !t.numeric_map? && !t.sharded? && !t.striped?
          true
        else
          false
        end
      end
    RUBY
      assert_empty Decomplex::OversizedPredicate.scan([file]).findings
    end
  end
end
