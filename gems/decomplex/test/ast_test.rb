# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/decomplex/ast"
require_relative "../lib/decomplex/syntax"

class AstTest < Minitest::Test
  def test_python_f_string_interpolation_after_literal_equals_is_not_dropped
    with_python_file(<<~PY) do |file|
      class Tag:
          @property
          def markup(self):
              return f"[{self.name}={self.parameters}]"
    PY
      root, = parse_python(file)
      dstr = nodes_of_type(root, "DSTR").find { |node| node.text == 'f"[{self.name}={self.parameters}]"' }

      refute_nil dstr
      assert_equal %w[STRING_START STR EVSTR STR EVSTR STR STRING_END], dstr.children.map(&:type).map(&:to_s)
    end
  end

  def test_lua_elseif_branch_is_preserved_as_if_alternative
    with_language_file(<<~LUA, ".lua", :lua) do |file|
      if test_env.LUA_V == "5.1" then
        one()
      elseif test_env.LUA_V == "5.2" then
        two()
      end
    LUA
      root, = parse_language(file, :lua)
      if_node = nodes_of_type(root, "IF").find { |node| node.text.include?("test_env.LUA_V") }

      refute_nil if_node
      assert_equal "ELSEIF_STATEMENT", if_node.children[2].type.to_s
    end
  end

  def test_lua_assigned_function_if_else_normalizes_as_if_not_iter
    with_language_file(<<~LUA, ".lua", :lua) do |file|
      local make_unreadable = function(path)
        if is_win then
          fs.execute("x")
        else
          fs.execute("y")
        end
      end
    LUA
      root, = parse_language(file, :lua)
      expression_list = nodes_of_type(root, "EXPRESSION_LIST").find { |node| node.text.start_with?("function(path)") }

      refute_nil expression_list
      if_node = expression_list.children.find { |child| Decomplex::Ast.node?(child) && child.type.to_s == "IF" }
      refute_nil if_node
      assert_empty nodes_of_type(root, "ITER")
      assert_equal "ELSE_STATEMENT", if_node.children[2].type.to_s
    end
  end

  def test_python_yield_statement_predicate_recognizes_expression_statement_wrapper
    with_python_file(<<~PY) do |file|
      def gen():
          yield item
          other()
    PY
      document = parse_syntax(file, :python)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      yield_statement = ts_nodes(document.root).find do |node|
        node.kind == "expression_statement" && node.text == "yield item"
      end
      block = ts_nodes(document.root).find do |node|
        node.kind == "block" && node.text == "yield item\n    other()"
      end

      refute_nil yield_statement
      refute_nil block
      assert normalizer.send(:yield_statement?, yield_statement)
      refute normalizer.send(:yield_statement?, block)
    end
  end

  def test_python_yield_in_multi_statement_body_stays_statement_not_whole_block
    with_python_file(<<~PY) do |file|
      def gen():
          yield item
          other()
    PY
      root, = parse_python(file)
      defn = nodes_of_type(root, "DEFN").find { |node| node.text == "def gen():\n    yield item\n    other()" }
      scope = defn.children[1]
      body = scope.children[2]

      refute_nil defn
      assert_equal "BLOCK", body.type.to_s
      assert_equal %w[YIELD EXPRESSION_STATEMENT], body.children.map(&:type).map(&:to_s)
    end
  end

  def test_ruby_super_statement_predicate_recognizes_bare_and_argument_forms
    with_language_file(<<~RUBY, ".rb", :ruby) do |file|
      class Child < Parent
        def bare
          super
        end

        def with_arg
          super :item
        end

        def other
          value
        end
      end
    RUBY
      document = parse_syntax(file, :ruby)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      bare = ts_nodes(document.root).find { |node| node.kind == "body_statement" && node.text == "super" }
      with_arg = ts_nodes(document.root).find { |node| node.kind == "body_statement" && node.text == "super :item" }
      other = ts_nodes(document.root).find { |node| node.kind == "body_statement" && node.text == "value" }

      refute_nil bare
      refute_nil with_arg
      refute_nil other
      assert normalizer.send(:super_statement?, bare)
      assert normalizer.send(:super_statement?, with_arg)
      refute normalizer.send(:super_statement?, other)
    end
  end

  def test_ruby_super_statement_normalizes_bare_and_arguments
    with_language_file(<<~RUBY, ".rb", :ruby) do |file|
      class Child < Parent
        def bare
          super
        end

        def with_arg
          super :item
        end
      end
    RUBY
      root, = parse_language(file, :ruby)
      bare = nodes_of_type(root, "SUPER").find { |node| node.text == "super" }
      with_arg = nodes_of_type(root, "SUPER").find { |node| node.text == "super :item" }

      refute_nil bare
      refute_nil with_arg
      assert_nil bare.children.first
      assert_equal "LIST", with_arg.children.first.type.to_s
      assert_equal "LIT", with_arg.children.first.children.first.type.to_s
    end
  end

  def test_ruby_argument_list_element_reference_predicate
    with_language_file(<<~RUBY, ".rb", :ruby) do |file|
      def indexed
        return items[0]
        return obj.foo[0]
        return [0]
        return items[0], other
        return items[]
        return items[0] { nope }
      end
    RUBY
      document = parse_syntax(file, :ruby)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      argument_lists = ts_nodes(document.root).select { |node| node.kind == "argument_list" }

      assert normalizer.send(:argument_list_element_reference?, argument_lists.find { |node| node.text == "items[0]" })
      assert normalizer.send(:argument_list_element_reference?, argument_lists.find { |node| node.text == "obj.foo[0]" })
      refute normalizer.send(:argument_list_element_reference?, argument_lists.find { |node| node.text == "[0]" })
      refute normalizer.send(:argument_list_element_reference?, argument_lists.find { |node| node.text == "items[0], other" })
      refute normalizer.send(:argument_list_element_reference?, argument_lists.find { |node| node.text == "items[]" })
      refute normalizer.send(:argument_list_element_reference?, argument_lists.find { |node| node.text == "items[0] { nope }" })
    end
  end

  def test_dynamic_scope_rewrites_locals_without_crossing_scope_boundaries
    inner_assignment = ast_node(:LASGN, children: [:inner])
    node = ast_node(:BLOCK, children: [
      ast_node(:LASGN, children: [:value]),
      ast_node(:LVAR, children: [:value]),
      ast_node(:DEFN, children: [:nested, ast_node(:SCOPE, children: [nil, nil, inner_assignment])])
    ])

    result = Decomplex::Ast::TreeSitterNormalizer.allocate.send(:dynamic_scope, node)

    assert_equal :DASGN, result.children[0].type
    assert_equal :DVAR, result.children[1].type
    assert_equal :DEFN, result.children[2].type
    assert_equal :LASGN, inner_assignment.type
  end

  def test_link_when_chain_sets_next_arm_and_pads_short_when_nodes
    fallback = ast_node(:ELSE)
    first = ast_node(:WHEN, children: [:patterns, :body, nil])
    second = ast_node(:WHEN, children: [:patterns, :body, nil])
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate

    result = normalizer.send(:link_when_chain, [first, second], fallback)

    assert_same first, result
    assert_same second, first.children[2]
    assert_same fallback, second.children[2]

    short = ast_node(:WHEN, children: [:patterns])
    result = normalizer.send(:link_when_chain, [short], fallback)

    assert_same short, result
    assert_nil short.children[1]
    assert_same fallback, short.children[2]
  end

  def test_link_rescue_chain_sets_next_rescue_and_pads_short_resbody_nodes
    first = ast_node(:RESBODY, children: [:exceptions, :body, nil])
    second = ast_node(:RESBODY, children: [:exceptions, :body, nil])
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate

    result = normalizer.send(:link_rescue_chain, [first, second])

    assert_same first, result
    assert_same second, first.children[2]
    assert_nil second.children[2]

    short = ast_node(:RESBODY, children: [:exceptions])
    result = normalizer.send(:link_rescue_chain, [short])

    assert_same short, result
    assert_nil short.children[1]
    assert_nil short.children[2]
  end

  def test_infix_statement_parts_extracts_allowed_wrapper_parts
    body = ruby_syntax_node("def calc\n  left + right\nend\n", "body_statement", "left + right")
    return_args = ruby_syntax_node("def calc\n  return left + right\nend\n", "argument_list", "left + right")
    boolean = ruby_syntax_node("def calc\n  left && right\nend\n", "body_statement", "left && right")
    unsupported = ruby_syntax_node("def calc\n  left + right\nend\n", "identifier", "left")
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate

    assert_equal ["left", "+", "right"], infix_parts_text(normalizer, body)
    assert_equal ["left", "+", "right"], infix_parts_text(normalizer, return_args)
    assert_equal [nil, nil, nil], infix_parts_text(normalizer, boolean)
    assert_equal [nil, nil, nil], infix_parts_text(normalizer, unsupported)
  end

  def test_argument_list_unary_not_predicate
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate

    assert normalizer.send(:argument_list_unary_not?, ruby_syntax_node("def check\n  return !flag\nend\n", "argument_list", "!flag"))
    assert normalizer.send(:argument_list_unary_not?, ruby_syntax_node("def check\n  return !!flag\nend\n", "argument_list", "!!flag"))
    refute normalizer.send(:argument_list_unary_not?, ruby_syntax_node("def check\n  return flag\nend\n", "argument_list", "flag"))
    refute normalizer.send(:argument_list_unary_not?, ruby_syntax_node("def check\n  return !flag, other\nend\n", "argument_list", "!flag, other"))
    refute normalizer.send(:argument_list_unary_not?, ruby_syntax_node("def check\n  return (!flag)\nend\n", "argument_list", "(!flag)"))
    refute normalizer.send(:argument_list_unary_not?, ruby_syntax_node("def check\n  return not flag\nend\n", "argument_list", "not flag"))
  end

  def test_unary_not_statement_predicate
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate

    assert normalizer.send(:unary_not_statement?, ruby_syntax_node("def check\n  !flag\nend\n", "body_statement", "!flag"))
    assert normalizer.send(:unary_not_statement?, ruby_syntax_node("def check\n  !!flag\nend\n", "body_statement", "!!flag"))
    refute normalizer.send(:unary_not_statement?, ruby_syntax_node("def check\n  flag\nend\n", "body_statement", "flag"))
    refute normalizer.send(:unary_not_statement?, ruby_syntax_node("def check\n  !flag; other\nend\n", "body_statement", "!flag; other"))
    refute normalizer.send(:unary_not_statement?, ruby_syntax_node("def check\n  (!flag)\nend\n", "body_statement", "(!flag)"))
    refute normalizer.send(:unary_not_statement?, ruby_syntax_node("def check\n  not flag\nend\n", "body_statement", "not flag"))
  end

  def test_unary_not_expression_predicate
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
    ruby_source = "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n"

    assert normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "!flag"))
    assert normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "!!flag"))
    refute normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "-flag"))
    refute normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "not flag"))

    with_language_file("function check(flag: boolean) { return !flag; }\n", ".ts", :typescript) do |file|
      document = parse_syntax(file, :typescript)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "unary_expression" && candidate.text == "!flag" }
      refute_nil node
      assert normalizer.send(:unary_not_expression?, node)
    end

    with_language_file("if not flag:\n    pass\n", ".py", :python) do |file|
      document = parse_syntax(file, :python)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "not_operator" && candidate.text == "not flag" }
      refute_nil node
      refute normalizer.send(:unary_not_expression?, node)
    end

    with_language_file("if not flag then end\n", ".lua", :lua) do |file|
      document = parse_syntax(file, :lua)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "unary_expression" && candidate.text == "not flag" }
      refute_nil node
      refute normalizer.send(:unary_not_expression?, node)
    end
  end

  def test_unary_minus_expression_predicate
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
    ruby_source = "def check\n  -flag\n  !flag\n  value\nend\n"

    assert normalizer.send(:unary_minus_expression?, ruby_syntax_node(ruby_source, "unary", "-flag"))
    refute normalizer.send(:unary_minus_expression?, ruby_syntax_node(ruby_source, "unary", "!flag"))

    with_language_file("function check(value: number) { return -value; }\n", ".ts", :typescript) do |file|
      document = parse_syntax(file, :typescript)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "unary_expression" && candidate.text == "-value" }
      refute_nil node
      assert normalizer.send(:unary_minus_expression?, node)
    end

    with_language_file("x = -value\n", ".py", :python) do |file|
      document = parse_syntax(file, :python)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "unary_operator" && candidate.text == "-value" }
      refute_nil node
      assert normalizer.send(:unary_minus_expression?, node)
    end

    with_language_file("local x = -value\n", ".lua", :lua) do |file|
      document = parse_syntax(file, :lua)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "expression_list" && candidate.text == "-value" }
      refute_nil node
      assert normalizer.send(:unary_minus_expression?, node)
    end
  end

  def test_tree_sitter_normalizer_selects_language_specific_normalization_adapters
    {
      ruby: Decomplex::Ast::RubyTreeSitterNormalizationAdapter,
      python: Decomplex::Ast::PythonTreeSitterNormalizationAdapter,
      lua: Decomplex::Ast::LuaTreeSitterNormalizationAdapter,
      typescript: Decomplex::Ast::TypeScriptTreeSitterNormalizationAdapter,
      javascript: Decomplex::Ast::TypeScriptTreeSitterNormalizationAdapter
    }.each do |language, adapter_class|
      assert_instance_of adapter_class, Decomplex::Ast::TreeSitterNormalizationAdapter.for(fake_document(language))
    end
  end

  def test_binary_operator
    ruby_source = "def calc\n  left + right\n  left && right\n  value\nend\n"

    with_language_file(ruby_source, ".rb", :ruby) do |file|
      document = parse_syntax(file, :ruby)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)

      assert_equal "+", normalizer.send(:binary_operator, ts_nodes(document.root).find { |node| node.kind == "binary" && node.text == "left + right" })
      assert_equal "&&", normalizer.send(:binary_operator, ts_nodes(document.root).find { |node| node.kind == "binary" && node.text == "left && right" })
      assert_equal "", normalizer.send(:binary_operator, ts_nodes(document.root).find { |node| node.kind == "body_statement" && node.text == "left + right\n  left && right\n  value" })
    end

    with_language_file("const value = left + right && other;\n", ".ts", :typescript) do |file|
      document = parse_syntax(file, :typescript)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      outer = ts_nodes(document.root).find { |candidate| candidate.kind == "binary_expression" && candidate.text == "left + right && other" }
      inner = ts_nodes(document.root).find { |candidate| candidate.kind == "binary_expression" && candidate.text == "left + right" }

      refute_nil outer
      refute_nil inner
      assert_equal "&&", normalizer.send(:binary_operator, outer)
      assert_equal "+", normalizer.send(:binary_operator, inner)
    end

    with_language_file("value = left + right and other\n", ".py", :python) do |file|
      document = parse_syntax(file, :python)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      outer = ts_nodes(document.root).find { |candidate| candidate.kind == "boolean_operator" && candidate.text == "left + right and other" }
      inner = ts_nodes(document.root).find { |candidate| candidate.kind == "binary_operator" && candidate.text == "left + right" }

      refute_nil outer
      refute_nil inner
      assert_equal "and", normalizer.send(:binary_operator, outer)
      assert_equal "+", normalizer.send(:binary_operator, inner)
    end

    with_language_file("local value = left + right and other\n", ".lua", :lua) do |file|
      document = parse_syntax(file, :lua)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      outer = ts_nodes(document.root).find { |candidate| candidate.kind == "expression_list" && candidate.text == "left + right and other" }
      inner = ts_nodes(document.root).find { |candidate| candidate.kind == "binary_expression" && candidate.text == "left + right" }

      refute_nil outer
      refute_nil inner
      assert_equal "and", normalizer.send(:binary_operator, outer)
      assert_equal "+", normalizer.send(:binary_operator, inner)
    end
  end

  private

  def ast_node(type, children: [])
    Decomplex::Ast::Node.new(
      type: type,
      children: children,
      first_lineno: 1,
      first_column: 0,
      last_lineno: 1,
      last_column: 1,
      text: type.to_s
    )
  end

  def fake_document(language)
    Object.new.tap { |document| document.define_singleton_method(:language) { language } }
  end

  def ruby_syntax_node(source, kind, text)
    found = nil
    with_language_file(source, ".rb", :ruby) do |file|
      document = parse_syntax(file, :ruby)
      found = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }
    end
    refute_nil found
    found
  end

  def infix_parts_text(normalizer, node)
    normalizer.send(:infix_statement_parts, node).map do |part|
      part.respond_to?(:text) ? part.text : part
    end
  end

  def parse_python(file)
    parse_language(file, :python)
  end

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

  def with_python_file(source)
    with_language_file(source, ".py", :python) { |file| yield file }
  end

  def with_language_file(source, suffix, _language)
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
