# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/espalier/type_profile"

class TypeProfileCovTest < Minitest::Test
  def test_sorbet_static_type
    sys = FactMine::Syntax::RubySorbetTypeProfile.new(language: "ruby")
    assert_equal "T.untyped", sys.static_type([])
    assert_equal "NilClass", sys.static_type(["NilClass"])
    assert_equal "T.nilable(String)", sys.static_type(["String", "NilClass"])
    assert_equal "T::Boolean", sys.static_type(["TrueClass", "FalseClass"])
    assert_equal "T.any(Integer, String)", sys.static_type(["String", "Integer"], union_policy: "any")
    assert_equal "T.untyped", sys.static_type(["String", "Integer"], union_policy: "untyped")
    assert_equal "T.noreturn", sys.static_type(["T.noreturn"])
  end

  def test_sorbet_extract_param_entries
    sys = FactMine::Syntax::RubySorbetTypeProfile.new(language: "ruby")
    entries = sys.extract_param_entries("sig { params(foo: String, bar: Integer).void }")
    assert_equal [["foo", "String"], ["bar", "Integer"]], entries
  end

  def test_sorbet_normalize_static_type
    sys = FactMine::Syntax::RubySorbetTypeProfile.new(language: "ruby")
    assert_equal "T::Array[T.untyped]", sys.normalize_static_type("Array")
    assert_equal "T::Hash[T.untyped, T.untyped]", sys.normalize_static_type("Hash")
    assert_equal "T::Set[T.untyped]", sys.normalize_static_type("Set")
  end

  def test_exceeds_union_cutoff
    sys = FactMine::Syntax::RubySorbetTypeProfile.new(language: "ruby")
    sys.instance_variable_set(:@union_wrappers, [{name: "T.any", open: "(", close: ")"}])
    sys.instance_variable_set(:@union_operators, ["|"])
    assert sys.broad_union_type?("T.any(A, B, C, D, E)", max: 3)
    assert sys.broad_union_type?("A | B | C | D | E", max: 3)
  end

  def test_extract_call_args_missing
    sys = FactMine::Syntax::RubySorbetTypeProfile.new(language: "ruby")
    assert_nil sys.extract_call_args("foo", "params")
    assert_nil sys.extract_call_args("params(", "params")
  end

  def test_balanced_inner_unbalanced
    sys = FactMine::Syntax::RubySorbetTypeProfile.new(language: "ruby")
    assert_nil sys.send(:balanced_inner, "foo(bar", 3, "(", ")")
    assert_equal "\"bar)\"", sys.send(:balanced_inner, "foo(\"bar)\")", 3, "(", ")")
    assert_equal "'bar)'", sys.send(:balanced_inner, "foo('bar)')", 3, "(", ")")
  end

  def test_each_wrapped_argument_source
    sys = FactMine::Syntax::RubySorbetTypeProfile.new(language: "ruby")
    yielded = []
    wrapper = { name: "T.any", open: "(", close: ")" }
    sys.send(:each_wrapped_argument_source, "T.any(A, B) and T.any(C)", wrapper) do |inner|
      yielded << inner
    end
    assert_equal ["A, B", "C"], yielded
  end
end
