# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/ast"
require_relative "../lib/decomplex/syntax"

class AstTest < Minitest::Test
  def test_operator_call_expression_predicate
    {
      ruby: ["def calc\n  left + right\n  left && right\nend\n", ".rb", "binary", "left + right", "binary", "left && right"],
      typescript: ["const value = left + right && other;\n", ".ts", "binary_expression", "left + right", "binary_expression", "left + right && other"],
      python: ["value = left + right and other\n", ".py", "binary_operator", "left + right", "boolean_operator", "left + right and other"],
      lua: ["local value = left + right\nlocal other = left and right\n", ".lua", "expression_list", "left + right", "expression_list", "left and right"]
    }.each do |language, (source, suffix, positive_kind, positive_text, negative_kind, negative_text)|
      with_language_file(source, suffix) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        positive = ts_nodes(document.root).find { |candidate| candidate.kind == positive_kind && candidate.text == positive_text }
        negative = ts_nodes(document.root).find { |candidate| candidate.kind == negative_kind && candidate.text == negative_text }

        refute_nil positive
        refute_nil negative
        assert normalizer.send(:operator_call_expression?, positive)
        refute normalizer.send(:operator_call_expression?, negative)
      end
    end
  end

  def test_operator_call_normalizes_python_and_lua_arithmetic
    {
      python: ["value = left + right\n", ".py"],
      lua: ["local value = left + right\n", ".lua"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix) do |file|
        root, = parse_language(file, language)
        opcall = nodes_of_type(root, "OPCALL").find { |node| node.text == "left + right" }

        refute_nil opcall
        assert_equal "+", opcall.children[1].to_s
      end
    end
  end

  private

  def parse_language(file, language)
    with_env("DECOMPLEX_FORCE_LANGUAGE", language.to_s) do
      Decomplex::Ast.normalized_cache.clear
      Decomplex::Ast.parse(file)
    end
  rescue LoadError => e
    skip e.message
  end

  def parse_syntax(file, language)
    with_env("DECOMPLEX_FORCE_LANGUAGE", language.to_s) do
      Decomplex::Syntax.parse(file, parser: "tree_sitter")
    end
  rescue LoadError => e
    skip e.message
  end

  def nodes_of_type(node, type)
    out = []
    walk_nodes(node) { |child| out << child if child.type.to_s == type }
    out
  end

  def walk_nodes(node, &block)
    return unless Decomplex::Ast.node?(node)

    yield node
    node.children.each { |child| walk_nodes(child, &block) }
  end

  def ts_nodes(node)
    out = []
    walk_ts_nodes(node) { |child| out << child }
    out
  end

  def walk_ts_nodes(node, &block)
    return unless node.respond_to?(:kind)

    yield node
    node.named_children.each { |child| walk_ts_nodes(child, &block) }
  end

  def with_language_file(source, suffix)
    file = Tempfile.new(["decomplex_ast", suffix])
    file.write(source)
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end
end
