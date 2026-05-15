# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "json"
require "coverage"
require_relative "../lib/prick"

class ClassifierTest < Minitest::Test
  C = Prick::Classifier

  def node(expr)
    RubyVM::AbstractSyntaxTree.parse(expr).children.last
  end

  def test_type_guard_detects_is_a_nil_respond_and_safe_nav
    assert C.type_guard?(node("x.is_a?(Type)"))
    assert C.type_guard?(node("x.nil?"))
    assert C.type_guard?(node("x.respond_to?(:y)"))
    assert C.type_guard?(node("x&.foo"))
    refute C.type_guard?(node("x + 1"))
    refute C.type_guard?(node("x.bar(1)"))
  end

  def test_trivial_is_the_narrow_inert_residue
    assert C.trivial?(nil)
    assert C.trivial?(node("nil"))
    refute C.trivial?(node("foo(1)"))          # a call
    refute C.trivial?(node("return 5"))        # an outcome
    refute C.trivial?(node("x = 1"))           # an assignment
  end

  def test_categorize_priority_order
    g = node("x.is_a?(Type)")
    # FFI method name wins first
    assert_equal :ffi, C.categorize("lower_require", :if, g, true, nil, ["lower_require"])
    # diagnostic (raise) before type_norm
    assert_equal :diagnostic, C.categorize("m", :if, node("raise 'x'"), true)
    # type_norm before dead/defensive
    assert_equal :type_norm, C.categorize("m", :if, g, false)
    # no sibling taken + not type/diag/ffi -> dead
    assert_equal :dead, C.categorize("m", :if, node("foo(1)"), false)
    # live + trivial -> defensive
    assert_equal :defensive, C.categorize("m", :if, node("nil"), true)
    # live + real body + branch kind -> genuine
    assert_equal :genuine, C.categorize("m", :case, node("foo(1)"), true)
  end

  # Real resultset via stdlib Coverage (same branch-tuple shape SimpleCov
  # uses), so classify_file runs the true path on real dark arms.
  def test_classify_file_on_real_coverage
    src = <<~RB
      def shape(x, n)
        return 0 if x.is_a?(String)        # type_norm (dark: never String)
        if n > 0
          a = 1
        else
          a = 2                            # genuine-ish (dark else, sibling taken)
        end
        a
      end
      shape(7, 5)
    RB
    f = Tempfile.new(["cov", ".rb"])
    f.write(src)
    f.close
    Coverage.start(branches: true)
    load f.path
    res = Coverage.result
    rs = { "T" => { "coverage" => { f.path => { "branches" => res.dig(f.path, :branches) } } } }
    rsf = Tempfile.new(["rs", ".json"])
    rsf.write(JSON.dump(rs))
    rsf.close

    arms = C.classify_file(rsf.path, f.path)
    cats = arms.map(&:category)
    assert_includes cats, :type_norm, "the never-true String guard"
    refute_empty arms
  ensure
    f&.unlink
    rsf&.unlink
  end
end
