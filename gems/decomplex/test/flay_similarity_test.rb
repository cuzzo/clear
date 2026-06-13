# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class FlaySimilarityTest < Minitest::Test
  def setup
    require "flay"
  rescue LoadError
    skip "flay gem is not available"
  end

  def scan(ruby, mass: 8, fuzzy: 1)
    f = Tempfile.new(["flay-sim", ".rb"])
    f.write(ruby)
    f.close
    Decomplex::FlaySimilarity.scan([f.path], mass: mass, fuzzy: fuzzy)
  ensure
    @tmp ||= []
    @tmp << f if f
  end

  def test_type2_similarity_uses_flay_clusters
    out = scan(<<~RB)
      def a(node)
        return false unless node.respond_to?(:type)
        node.type == :heap || node.type == :frame
      end
      def b(entry)
        return false unless entry.respond_to?(:kind)
        entry.kind == :heap || entry.kind == :frame
      end
    RB
    hit = out.find { |h| h[:clone_type] == :type2 }
    refute_nil hit
    assert_equal "defn", hit[:node]
    assert_equal 2, hit[:sites].size
    assert(hit[:spans].keys.all? { |k| k.include?(":a:") || k.include?(":b:") })
  end

  def test_type3_similarity_uses_flay_fuzzy_clusters
    out = scan(<<~RB, mass: 4, fuzzy: 1)
      def a(node)
        alpha(node.left)
        beta(node.right)
        gamma(node.name)
        delta(node.type)
      end
      def b(entry)
        alpha(entry.left)
        beta(entry.right)
        delta(entry.type)
      end
    RB
    assert(out.any? { |h| h[:clone_type] == :type3 })
  end

  def test_typed_struct_field_declarations_are_not_clone_pressure
    out = scan(<<~RB, mass: 4, fuzzy: 1)
      class Left < T::Struct
        const :name, String
        prop :active, T::Boolean
      end

      class Right < T::Struct
        const :path, String
        prop :ready, T::Boolean
      end
    RB
    assert_empty out
  end
end
