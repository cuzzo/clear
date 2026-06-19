# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex"

class FlaySimilarityTest < Minitest::Test
  def grammar_available?(language)
    env = "DECOMPLEX_TS_#{language.to_s.upcase}_PATH"
    return true if ENV[env] && File.file?(ENV[env])

    adapter = Decomplex::Syntax::TreeSitterAdapter.new
    adapter.send(:grammar_candidates, language).any? { |path| File.file?(path) }
  end

  def scan(source, ext: ".rb", mass: 8, fuzzy: 1)
    f = Tempfile.new(["flay-sim", ext])
    f.write(source)
    f.close
    Decomplex::FlaySimilarity.scan([f.path], mass: mass, fuzzy: fuzzy)
  ensure
    @tmp ||= []
    @tmp << f if f
  end

  def test_type2_similarity_uses_tree_sitter_clusters
    skip "set DECOMPLEX_TS_RUBY_PATH to run Ruby similarity test" unless grammar_available?(:ruby)

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

  def test_type3_similarity_uses_tree_sitter_fuzzy_clusters
    skip "set DECOMPLEX_TS_RUBY_PATH to run Ruby fuzzy similarity test" unless grammar_available?(:ruby)

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

  def test_python_similarity_uses_generalized_tree_sitter_scanner
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python similarity test" unless grammar_available?(:python)

    out = scan(<<~PY, ext: ".py", mass: 8, fuzzy: 1)
      def a(node):
          if node.ready and node.enabled:
              return node.left == node.right
          return False

      def b(entry):
          if entry.open and entry.active:
              return entry.first == entry.second
          return False
    PY

    hit = out.find { |h| h[:clone_type] == :type2 && h[:node] == "defn" }
    refute_nil hit
    assert_equal 2, hit[:sites].size
    assert(hit[:sites].all? { |site| site.include?(":a:") || site.include?(":b:") })
  end

  def test_zig_similarity_uses_generalized_tree_sitter_scanner
    skip "set DECOMPLEX_TS_ZIG_PATH to run Zig similarity test" unless grammar_available?(:zig)

    out = scan(<<~ZIG, ext: ".zig", mass: 8, fuzzy: 1)
      pub fn a(node: Node) bool {
          if (node.ready and node.enabled) return node.left == node.right;
          return false;
      }

      pub fn b(entry: Node) bool {
          if (entry.open and entry.active) return entry.first == entry.second;
          return false;
      }
    ZIG

    hit = out.find { |h| h[:clone_type] == :type2 && h[:node] == "defn" }
    refute_nil hit
    assert_equal 2, hit[:sites].size
  end

  def test_typed_struct_field_declarations_are_not_clone_pressure
    skip "set DECOMPLEX_TS_RUBY_PATH to run Ruby typed struct similarity test" unless grammar_available?(:ruby)

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
