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
      lambda_node = nodes_of_type(root, "LAMBDA").find { |node| node.text.start_with?("function(path)") }

      refute_nil lambda_node
      if_node = nodes_of_type(lambda_node, "IF").first
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

  def test_wrapped_return_statement_normalizes_return_value_before_tail_elision
    with_language_file(<<~RUBY, ".rb", :ruby) do |file|
      def check
        return value
      end
    RUBY
      root, = parse_language(file, :ruby)
      defn = nodes_of_type(root, "DEFN").find { |node| node.children.first == :check }

      refute_nil defn
      body = defn.children[1].children[2]
      assert_equal "VCALL", body.type.to_s
      assert_equal :value, body.children.first
    end

    with_language_file(<<~PY, ".py", :python) do |file|
      def check():
          return value
    PY
      root, = parse_language(file, :python)
      defn = nodes_of_type(root, "DEFN").find { |node| node.children.first == :check }

      refute_nil defn
      body = defn.children[1].children[2]
      assert_equal "RETURN", body.type.to_s
      assert_equal "LVAR", body.children.first.type.to_s
    end

    with_language_file(<<~LUA, ".lua", :lua) do |file|
      function check()
        return value
      end
    LUA
      root, = parse_language(file, :lua)
      defn = nodes_of_type(root, "DEFN").find { |node| node.children.first == :check }

      refute_nil defn
      body = defn.children[1].children[2]
      assert_equal "RETURN", body.type.to_s
      assert_equal "EXPRESSION_LIST", body.children.first.type.to_s
    end
  end

  def test_ruby_singleton_method_receiver_ignores_method_body
    with_language_file(<<~RUBY, ".rb", :ruby) do |file|
      def object.hidden
        value
      end
    RUBY
      root, = parse_language(file, :ruby)
      defs = nodes_of_type(root, "DEFS").find { |node| node.children[1] == :hidden }

      refute_nil defs
      receiver = defs.children[0]
      assert_equal "VCALL", receiver.type.to_s
      assert_equal :object, receiver.children[0]
      assert_equal "object", receiver.text
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
    normalizer.instance_variable_set(:@document, fake_document(:ruby))
    ruby_source = "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n"

    assert normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "!flag"))
    assert normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "!!flag"))
    refute normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "-flag"))
    refute normalizer.send(:unary_not_expression?, ruby_syntax_node(ruby_source, "unary", "not flag"))

    with_language_file("function check(flag: boolean) { return !flag; }\n", ".ts", :typescript) do |file|
      document = parse_syntax(file, :typescript)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "unary_expression" && candidate.text == "!flag" }
      refute_nil node
      assert normalizer.send(:unary_not_expression?, node)
    end

    with_language_file("if not flag:\n    pass\n", ".py", :python) do |file|
      document = parse_syntax(file, :python)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "not_operator" && candidate.text == "not flag" }
      refute_nil node
      refute normalizer.send(:unary_not_expression?, node)
    end

    with_language_file("if not flag then end\n", ".lua", :lua) do |file|
      document = parse_syntax(file, :lua)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      node = ts_nodes(document.root).find { |candidate| candidate.kind == "unary_expression" && candidate.text == "not flag" }
      refute_nil node
      refute normalizer.send(:unary_not_expression?, node)
    end
  end

  def test_unary_minus_expression_predicate
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
    normalizer.instance_variable_set(:@document, fake_document(:ruby))
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

  def test_tree_sitter_normalizer_rejects_unsupported_normalization_languages
    error = assert_raises(Decomplex::Ast::UnsupportedLanguageError) do
      Decomplex::Ast::TreeSitterNormalizationAdapter.for(fake_document(:go))
    end

    assert_includes error.message, ":go"
  end

  def test_parse_semantic_returns_language_neutral_ruby_facts
    with_language_file(<<~RB, ".rb", :ruby) do |file|
      class User
        def active?
          admin?
        end
      end
    RB
      root, = Decomplex::Ast.parse_semantic(file, language: :ruby)

      assert Decomplex::Ast.semantic_node?(root)
      assert_equal :root, root.type
      assert_equal :ruby, root.language
      assert root.children.any? { |node| node.type == :owner && node[:name] == "User" }
      assert root.children.any? { |node| node.type == :function && node[:name] == "active?" }
      assert root.children.any? { |node| node.type == :call && node[:message] == "admin?" }
      refute root.children.any? { |node| %i[DEFN VCALL FCALL CALL].include?(node.type) }
    end
  end

  def test_parse_semantic_returns_language_neutral_python_facts
    with_python_file(<<~PY) do |file|
      def check(user):
          return user.active()
    PY
      root, = Decomplex::Ast.parse_semantic(file, language: :python)

      assert Decomplex::Ast.semantic_node?(root)
      assert_equal :root, root.type
      assert_equal :python, root.language
      assert root.children.any? { |node| node.type == :function && node[:name] == "check" }
      assert root.children.any? { |node| node.type == :call && node[:receiver] == "user" && node[:message] == "active" }
      refute root.children.any? { |node| %i[DEFN VCALL FCALL CALL].include?(node.type) }
    end
  end

  def test_safe_navigation_call_recognizes_typescript_optional_chain
    with_language_file("user?.name;\nuser?.name();\n", ".ts", :typescript) do |file|
      document = parse_syntax(file, :typescript)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      member = ts_nodes(document.root).find { |candidate| candidate.kind == "member_expression" && candidate.text == "user?.name" }
      call = ts_nodes(document.root).find { |candidate| candidate.kind == "call_expression" && candidate.text == "user?.name()" }

      refute_nil member
      refute_nil call
      assert normalizer.send(:safe_navigation_call?, member)
      assert normalizer.send(:safe_navigation_call?, call)
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

  def test_operator_call_expression_predicate
    {
      ruby: ["def calc\n  left + right\n  left && right\nend\n", ".rb", "binary", "left + right", "binary", "left && right"],
      typescript: ["const value = left + right && other;\n", ".ts", "binary_expression", "left + right", "binary_expression", "left + right && other"],
      python: ["value = left + right and other\n", ".py", "binary_operator", "left + right", "boolean_operator", "left + right and other"],
      lua: ["local value = left + right\nlocal other = left and right\n", ".lua", "expression_list", "left + right", "expression_list", "left and right"]
    }.each do |language, (source, suffix, positive_kind, positive_text, negative_kind, negative_text)|
      with_language_file(source, suffix, language) do |file|
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
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        opcall = nodes_of_type(root, "OPCALL").find { |node| node.text == "left + right" }

        refute_nil opcall
        assert_equal "+", opcall.children[1].to_s
      end
    end
  end

  def test_lua_boolean_expression_normalizes_as_and
    with_language_file("local value = left and right\n", ".lua", :lua) do |file|
      root, = parse_language(file, :lua)
      and_node = nodes_of_type(root, "AND").find { |node| node.text == "left and right" }

      refute_nil and_node
      assert_equal %w[LVAR LVAR], and_node.children.map(&:type).map(&:to_s)
    end
  end

  def test_lua_comparison_expression_normalizes_as_opcall
    with_language_file("local value = left == right\n", ".lua", :lua) do |file|
      root, = parse_language(file, :lua)
      opcall = nodes_of_type(root, "OPCALL").find { |node| node.text == "left == right" }

      refute_nil opcall
      assert_equal "==", opcall.children[1].to_s
      assert_equal %w[LVAR LVAR], [opcall.children[0].type, opcall.children[2].children.first.type].map(&:to_s)
    end
  end

  def test_lua_long_string_assignment_normalizes_as_literal_expression_list
    with_language_file("local c_module_source = [[\n   #include <lua.h>\n]]\n", ".lua", :lua) do |file|
      root, = parse_language(file, :lua)
      assignment = nodes_of_type(root, "LASGN").find { |node| node.children.first == "c_module_source" }

      refute_nil assignment
      expression_list = assignment.children[1]
      assert_equal "EXPRESSION_LIST", expression_list.type.to_s
      assert_equal "[[\n   #include <lua.h>\n]]", expression_list.text
      assert_equal ["STR"], expression_list.children.map(&:type).map(&:to_s)
      assert_equal "\n   #include <lua.h>\n", expression_list.children.first.children.first
      assert_empty nodes_of_type(root, "OPCALL").select { |node| node.text.include?("<lua.h>") }
    end
  end

  def test_comparison_operator
    {
      ruby: ["def calc\n  left == right\nend\n", ".rb", "body_statement", "left == right", "identifier", "left"],
      typescript: ["const value = left === right;\n", ".ts", "binary_expression", "left === right", "identifier", "left"],
      python: ["value = left == right\n", ".py", "comparison_operator", "left == right", "identifier", "left"],
      lua: ["local value = left == right\nlocal other = left + right\n", ".lua", "expression_list", "left == right", "expression_list", "left + right"]
    }.each do |language, (source, suffix, positive_kind, positive_text, negative_kind, negative_text)|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        positive = ts_nodes(document.root).find { |candidate| candidate.kind == positive_kind && candidate.text == positive_text }
        negative = ts_nodes(document.root).find { |candidate| candidate.kind == negative_kind && candidate.text == negative_text }

        refute_nil positive
        refute_nil negative
        refute_empty normalizer.send(:comparison_operator, positive).to_s
        assert_empty normalizer.send(:comparison_operator, negative).to_s
      end
    end
  end

  def test_spaced_text
    {
      ruby: ["def calc\n  left + right\nend\n", ".rb", "body_statement", "left + right"],
      typescript: ["const value = left + right;\n", ".ts", "binary_expression", "left + right"],
      python: ["value = left + right\n", ".py", "binary_operator", "left + right"],
      lua: ["local value = left + right\n", ".lua", "expression_list", "left + right"]
    }.each do |language, (source, suffix, kind, text)|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal " #{text} ", normalizer.send(:spaced_text, node)
      end
    end
  end

  def test_class_node_predicate
    {
      ruby: ["class Thing; end\n", ".rb", "class", "class Thing; end", true],
      python: ["class Thing:\n    pass\n", ".py", "class_definition", "class Thing:\n    pass", true],
      typescript: ["class Thing {}\n", ".ts", "class_declaration", "class Thing {}", true],
      lua: ["local Thing = {}\n", ".lua", "variable_declaration", "local Thing = {}", false]
    }.each do |language, (source, suffix, kind, text, expected)|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:class_node?, node)
      end
    end
  end

  def test_empty_class_scope_uses_class_source
    with_language_file("class Thing; end\n", ".rb", :ruby) do |file|
      root, = parse_language(file, :ruby)
      class_node = nodes_of_type(root, "CLASS").find { |node| node.text == "class Thing; end" }

      refute_nil class_node
      scope = class_node.children[2]
      assert_equal "SCOPE", scope.type.to_s
      assert_equal "class Thing; end", scope.text
      assert_equal [1, 0, 1, 16], [scope.first_lineno, scope.first_column, scope.last_lineno, scope.last_column]
    end
  end

  def test_unwrap_node_predicate
    cases = [
      [:ruby, "def check\n  (value)\n  value\nend\n", ".rb", "parenthesized_statements", "(value)", true],
      [:python, "value\n(value)\n", ".py", "expression_statement", "value", false],
      [:python, "value\n(value)\n", ".py", "expression_statement", "(value)", true],
      [:typescript, "const value = (other);\n", ".ts", "parenthesized_expression", "(other)", true],
      [:lua, "local first = (other)\nlocal second = left + right\n", ".lua", "expression_list", "(other)", true],
      [:lua, "local first = (other)\nlocal second = left + right\n", ".lua", "expression_list", "left + right", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:unwrap_node?, node)
      end
    end
  end

  def test_statement_node_predicate
    cases = [
      [:ruby, "def check\n  return value\nend\n", ".rb", "body_statement", "return value", true],
      [:ruby, "def check\n  return value\nend\n", ".rb", "identifier", "check", false],
      [:python, "value\n(value)\n", ".py", "expression_statement", "(value)", true],
      [:python, "value\n(value)\n", ".py", "identifier", "value", false],
      [:typescript, "function check() { return value + other; }\n", ".ts", "return_statement", "return value + other;", true],
      [:typescript, "function check() { return value + other; }\n", ".ts", "binary_expression", "value + other", true],
      [:typescript, "function check() { return value + other; }\n", ".ts", "identifier", "value", false],
      [:lua, "return value\n", ".lua", "return_statement", "return value", true],
      [:lua, "return value\n", ".lua", "expression_list", "value", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:statement_node?, node)
      end
    end
  end

  def test_local_identifier_predicate
    cases = [
      [:ruby, "def check\nend\nclass Thing; end\n", ".rb", "identifier", "check", true],
      [:ruby, "def check\nend\nclass Thing; end\n", ".rb", "constant", "Thing", false],
      [:python, "def check(value):\n    pass\n", ".py", "identifier", "value", true],
      [:python, "def check(value):\n    pass\n", ".py", "parameters", "(value)", false],
      [:typescript, "const value = object.field;\n", ".ts", "identifier", "value", true],
      [:typescript, "const value = object.field;\n", ".ts", "property_identifier", "field", true],
      [:typescript, "const value = object.field;\n", ".ts", "lexical_declaration", "const value = object.field;", false],
      [:lua, "local value = other\nprint(value)\n", ".lua", "identifier", "value", true],
      [:lua, "local value = other\n", ".lua", "expression_list", "other", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:local_identifier?, node)
      end
    end
  end

  def test_ruby_local_name_predicate
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
    normalizer.instance_variable_set(:@local_stack, [
      Set.new(%w[outer shared]),
      Set.new(%w[inner])
    ])

    assert normalizer.send(:ruby_local_name?, "outer")
    assert normalizer.send(:ruby_local_name?, "inner")
    assert normalizer.send(:ruby_local_name?, "shared")
    refute normalizer.send(:ruby_local_name?, "missing")
  end

  def test_ruby_predicate
    {
      ruby: true,
      python: false,
      lua: false,
      typescript: false
    }.each do |language, expected|
      normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
      normalizer.instance_variable_set(:@document, fake_document(language))

      assert_equal expected, normalizer.send(:ruby?)
    end
  end

  def test_interpolated_string_predicate
    cases = [
      [:ruby, "name = \"hi \#{user}\"\nplain = \"hi\"\n", ".rb", "string", "\"hi \#{user}\"", true],
      [:ruby, "name = \"hi \#{user}\"\nplain = \"hi\"\n", ".rb", "string", "\"hi\"", false],
      [:python, "name = f\"hi {user}\"\nplain = \"hi\"\n", ".py", "string", "f\"hi {user}\"", true],
      [:python, "name = f\"hi {user}\"\nplain = \"hi\"\n", ".py", "string", "\"hi\"", false],
      [:typescript, "const name = `hi ${user}`;\nconst plain = `hi`;\n", ".ts", "template_string", "`hi ${user}`", true],
      [:typescript, "const name = `hi ${user}`;\nconst plain = `hi`;\n", ".ts", "template_string", "`hi`", false],
      [:lua, "local name = \"hi\"\n", ".lua", "expression_list", "\"hi\"", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:interpolated_string?, node)
      end
    end
  end

  def test_const_node_predicate
    cases = [
      [:ruby, "class Thing; end\ndef check; end\n", ".rb", "constant", "Thing", true],
      [:ruby, "class Thing; end\ndef check; end\n", ".rb", "identifier", "check", false],
      [:python, "class Thing:\n    pass\n", ".py", "identifier", "Thing", false],
      [:typescript, "type Thing = Other;\nconst value = Thing;\n", ".ts", "type_identifier", "Thing", true],
      [:typescript, "type Thing = Other;\nconst value = Thing;\n", ".ts", "identifier", "value", false],
      [:lua, "local Thing = {}\n", ".lua", "variable_list", "Thing", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:const_node?, node)
      end
    end
  end

  def test_self_node_predicate
    cases = [
      [:ruby, "self\nother\n", ".rb", "self", "self", true],
      [:ruby, "self\nother\n", ".rb", "identifier", "other", false],
      [:python, "self.value\nother.value\n", ".py", "identifier", "self", true],
      [:python, "self.value\nother.value\n", ".py", "identifier", "other", false],
      [:typescript, "this.value;\nother;\n", ".ts", "this", "this", true],
      [:typescript, "this.value;\nother;\n", ".ts", "identifier", "other", false],
      [:lua, "print(self.value)\nprint(other.value)\n", ".lua", "identifier", "self", true],
      [:lua, "print(self.value)\nprint(other.value)\n", ".lua", "identifier", "other", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:self_node?, node)
      end
    end
  end

  def test_instance_variable_predicate
    cases = [
      [:ruby, "@value\nname\n", ".rb", "instance_variable", "@value", true],
      [:ruby, "@value\nname\n", ".rb", "identifier", "name", false],
      [:python, "@decorator\ndef call():\n    pass\n", ".py", "decorator", "@decorator", false],
      [:typescript, "@sealed\nclass Thing {}\n", ".ts", "decorator", "@sealed", false],
      [:lua, "print(value)\n", ".lua", "identifier", "value", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:instance_variable?, node)
      end
    end
  end

  def test_global_variable_predicate
    cases = [
      [:ruby, "$value\nname\n", ".rb", "global_variable", "$value", true],
      [:ruby, "$value\nname\n", ".rb", "identifier", "name", false],
      [:python, "value = \"$name\"\n", ".py", "string_content", "$name", false],
      [:typescript, "const $value = other;\n", ".ts", "identifier", "$value", false],
      [:lua, "print(\"$name\")\n", ".lua", "string_content", "$name", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:global_variable?, node)
      end
    end
  end

  def test_literal_fragment_assignment_context_predicate
    cases = [
      [:ruby, "value = \"left = right\"\n", ".rb", "string_content", "left = right", true],
      [:ruby, "value = 1\n", ".rb", "identifier", "value", false],
      [:python, "value = \"left = right\"\n", ".py", "string_content", "left = right", true],
      [:typescript, "const value = \"left = right\";\n", ".ts", "string_fragment", "left = right", true],
      [:lua, "local value = \"left = right\"\n", ".lua", "string_content", "left = right", true],
      [:lua, "local value = other\n", ".lua", "variable_list", "value", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:literal_fragment_assignment_context?, node)
      end
    end
  end

  def test_collect_identifier_names
    cases = [
      [:ruby, "left, *rest = values\n", ".rb", "left_assignment_list", "left, *rest", %w[left rest]],
      [:typescript, "const value = { shorthand };\n", ".ts", "object", "{ shorthand }", %w[shorthand]],
      [:lua, "local value = other\n", ".lua", "variable_declaration", "local value = other", %w[other value]]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }
        locals = Set.new

        refute_nil node
        normalizer.send(:collect_identifier_names, node, locals)
        assert_equal expected, locals.to_a.sort
      end
    end
  end

  def test_assignment_operator_predicate
    cases = [
      [:ruby, "=", true],
      [:ruby, "**=", true],
      [:ruby, "??=", false],
      [:python, ":=", true],
      [:python, "//=", true],
      [:python, "&&=", false],
      [:typescript, "??=", true],
      [:typescript, ">>>=", true],
      [:typescript, ":=", false],
      [:lua, "=", true],
      [:lua, "+=", false]
    ]

    cases.each do |language, text, expected|
      normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
      normalizer.instance_variable_set(:@document, fake_document(language))

      assert_equal expected, normalizer.send(:assignment_operator?, text)
    end
  end

  def test_operator_assignment_operator
    cases = [
      [:ruby, "value **= other\nflag ||= fallback\n", ".rb", "operator_assignment", "value **= other", :"**"],
      [:ruby, "value **= other\nflag ||= fallback\n", ".rb", "operator_assignment", "flag ||= fallback", :"||"],
      [:python, "value //= other\n", ".py", "expression_statement", "value //= other", :"//"],
      [:typescript, "value ??= other;\ncount >>>= 1;\n", ".ts", "augmented_assignment_expression", "value ??= other", :"??"],
      [:typescript, "value ??= other;\ncount >>>= 1;\n", ".ts", "augmented_assignment_expression", "count >>>= 1", :">>>"]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:operator_assignment_operator, node)
      end
    end
  end

  def test_ruby_global_augmented_assignment_uses_global_read_receiver
    with_language_file("$value += 1\n", ".rb", :ruby) do |file|
      root, = parse_language(file, :ruby)
      assignment = nodes_of_type(root, "GASGN").find { |node| node.text == "$value += 1" }

      refute_nil assignment
      call = assignment.children[1]
      assert_equal "CALL", call.type.to_s
      receiver = call.children[0]
      assert_equal "GVAR", receiver.type.to_s
      assert_equal ["$value"], receiver.children
    end
  end

  def test_lua_member_assignment_normalizes_as_attribute_assignment
    with_language_file("user.name = value\n", ".lua", :lua) do |file|
      root, = parse_language(file, :lua)
      assignment = nodes_of_type(root, "ATTRASGN").find { |node| node.text == "user.name = value" }

      refute_nil assignment
      receiver = assignment.children[0]
      assert_equal "LVAR", receiver.type.to_s
      assert_equal ["user"], receiver.children
      assert_equal :name=, assignment.children[1]
      assert_equal "LIST", assignment.children[2].type.to_s
    end
  end

  def test_first_named
    cases = [
      [:ruby, "class Thing; end\nname\n", ".rb", "class", "class Thing; end", ["constant", "Thing"]],
      [:ruby, "class Thing; end\nname\n", ".rb", "identifier", "name", nil],
      [:python, "def check(value):\n    return value\n", ".py", "function_definition", "def check(value):\n    return value", ["identifier", "check"]],
      [:typescript, "function check(value) { return value; }\n", ".ts", "function_declaration", "function check(value) { return value; }", ["identifier", "check"]],
      [:lua, "print(value)\n", ".lua", "function_call", "print(value)", ["identifier", "print"]]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:first_named, node)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_block_child
    cases = [
      [:ruby, "def check\n  call\nend\n", ".rb", "method", "def check\n  call\nend", ["body_statement", "call"]],
      [:ruby, "items.each do\n  call\nend\n", ".rb", "call", "items.each do\n  call\nend", ["do_block", "do\n  call\nend"]],
      [:python, "def check():\n    call()\n", ".py", "function_definition", "def check():\n    call()", ["block", "call()"]],
      [:typescript, "function check() { call(); }\n", ".ts", "function_declaration", "function check() { call(); }", ["statement_block", "{ call(); }"]],
      [:lua, "function check()\n  call()\nend\n", ".lua", "function_declaration", "function check()\n  call()\nend", ["block", "call()"]],
      [:ruby, "name\n", ".rb", "identifier", "name", nil]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:block_child, node)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_branch_child
    cases = [
      [:ruby, "if ready\n  call\nelse\n  stop\nend\n", ".rb", "if", "if ready\n  call\nelse\n  stop\nend", "identifier", "ready", 0, ["then", "\n  call"]],
      [:ruby, "if ready\n  call\nelse\n  stop\nend\n", ".rb", "if", "if ready\n  call\nelse\n  stop\nend", "identifier", "ready", 1, nil],
      [:ruby, "if ready\n  # note\n  call\nend\n", ".rb", "if", "if ready\n  # note\n  call\nend", "identifier", "ready", 0, ["then", "\n  call"]],
      [:python, "if ready:\n    call()\nelse:\n    stop()\n", ".py", "if_statement", "if ready:\n    call()\nelse:\n    stop()", "identifier", "ready", 1, ["else_clause", "else:\n    stop()"]],
      [:typescript, "if (ready) { call(); } else { stop(); }\n", ".ts", "if_statement", "if (ready) { call(); } else { stop(); }", "parenthesized_expression", "(ready)", 0, ["statement_block", "{ call(); }"]],
      [:lua, "if ready then\n  call()\nelse\n  stop()\nend\n", ".lua", "if_statement", "if ready then\n  call()\nelse\n  stop()\nend", "identifier", "ready", 1, ["else_statement", "else\n  stop()"]]
    ]

    cases.each do |language, source, suffix, kind, text, cond_kind, cond_text, index, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }
        condition = ts_nodes(document.root).find { |candidate| candidate.kind == cond_kind && candidate.text == cond_text }

        refute_nil node
        refute_nil condition
        found = normalizer.send(:branch_child, node, condition, index)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_explicit_alternative
    cases = [
      [:ruby, "if ready\n  call\nelsif other\n  stop\nend\n", ".rb", "if", "if ready\n  call\nelsif other\n  stop\nend", ["elsif", "elsif other\n  stop"]],
      [:ruby, "if ready\n  call\nend\n", ".rb", "if", "if ready\n  call\nend", nil],
      [:python, "if ready:\n    call()\nelif other:\n    stop()\n", ".py", "if_statement", "if ready:\n    call()\nelif other:\n    stop()", ["elif_clause", "elif other:\n    stop()"]],
      [:typescript, "if (ready) { call(); } else { stop(); }\n", ".ts", "if_statement", "if (ready) { call(); } else { stop(); }", ["else_clause", "else { stop(); }"]],
      [:lua, "if ready then\n  call()\nelseif other then\n  stop()\nend\n", ".lua", "if_statement", "if ready then\n  call()\nelseif other then\n  stop()\nend", ["elseif_statement", "elseif other then\n  stop()"]]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:explicit_alternative, node)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_wrap
    cases = [
      [:ruby, "first\nsecond\n", ".rb", "identifier", "second"],
      [:python, "first\nsecond\n", ".py", "expression_statement", "second"],
      [:typescript, "first;\nsecond;\n", ".ts", "identifier", "second"],
      [:lua, "print(first)\nprint(second)\n", ".lua", "identifier", "second"]
    ]

    cases.each do |language, source, suffix, kind, text|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        wrapped = normalizer.send(:wrap, :WRAPPED, children: [:child], source: node)
        assert_equal :WRAPPED, wrapped.type
        assert_equal [:child], wrapped.children
        assert_equal node.start_point.row + 1, wrapped.first_lineno
        assert_equal node.start_point.column, wrapped.first_column
        assert_equal node.end_point.row + 1, wrapped.last_lineno
        assert_equal node.end_point.column, wrapped.last_column
        assert_equal node.text, wrapped.text

        inner = normalizer.send(:wrap, :INNER, children: [], source: node)
        outer = normalizer.send(:wrap, :OUTER, children: [:child], source: inner)
        assert_equal :OUTER, outer.type
        assert_equal [:child], outer.children
        assert_equal inner.first_lineno, outer.first_lineno
        assert_equal inner.first_column, outer.first_column
        assert_equal inner.last_lineno, outer.last_lineno
        assert_equal inner.last_column, outer.last_column
        assert_equal inner.text, outer.text
      end
    end
  end

  def test_source_before_child
    cases = [
      [:ruby, "if ready\n  call\nend\n", ".rb", "if", "if ready\n  call\nend", "then", "\n  call", "if ready"],
      [:python, "if ready:\n    call()\n", ".py", "if_statement", "if ready:\n    call()", "block", "call()", "if ready:"],
      [:typescript, "if (ready) { call(); }\n", ".ts", "if_statement", "if (ready) { call(); }", "statement_block", "{ call(); }", "if (ready)"],
      [:lua, "if ready then\n  call()\nend\n", ".lua", "if_statement", "if ready then\n  call()\nend", "block", "call()", "if ready then"],
      [:ruby, "puts value\n", ".rb", "call", "puts value", "identifier", "puts", "puts value"],
      [:python, "call()\n", ".py", "expression_statement", "call()", "identifier", "call", "call()"],
      [:typescript, "call();\n", ".ts", "expression_statement", "call();", "identifier", "call", "call();"],
      [:lua, "call()\n", ".lua", "function_call", "call()", "identifier", "call", "call()"]
    ]

    cases.each do |language, source, suffix, kind, text, child_kind, child_text, expected_text|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }
        child = ts_nodes(document.root).find { |candidate| candidate.kind == child_kind && candidate.text == child_text }

        refute_nil node
        refute_nil child
        source_node = normalizer.send(:source_before_child, node, child)
        wrapped = normalizer.send(:wrap, :WRAPPED, children: [], source: source_node)

        assert_equal expected_text, wrapped.text
        assert_equal node.start_point.row + 1, wrapped.first_lineno
        assert_equal node.start_point.column, wrapped.first_column
      end
    end
  end

  def test_source_from_normalized_nodes
    cases = [
      [:ruby, "first\nsecond\n", ".rb", "identifier", "first", "identifier", "second", "first\nsecond"],
      [:python, "first\nsecond\n", ".py", "expression_statement", "first", "expression_statement", "second", "first\nsecond"],
      [:typescript, "first;\nsecond;\n", ".ts", "expression_statement", "first;", "expression_statement", "second;", "first;\nsecond;"],
      [:lua, "print(first)\nprint(second)\n", ".lua", "function_call", "print(first)", "function_call", "print(second)", "print(first)\nprint(second)"],
      [:ruby, "first + second\n", ".rb", "identifier", "first", "identifier", "second", "first + second"]
    ]

    cases.each do |language, source, suffix, first_kind, first_text, last_kind, last_text, expected_text|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        first_raw = ts_nodes(document.root).find { |candidate| candidate.kind == first_kind && candidate.text == first_text }
        last_raw = ts_nodes(document.root).find { |candidate| candidate.kind == last_kind && candidate.text == last_text }

        refute_nil first_raw
        refute_nil last_raw
        first_node = normalizer.send(:wrap, :FIRST, children: [], source: first_raw)
        last_node = normalizer.send(:wrap, :LAST, children: [], source: last_raw)
        source_node = normalizer.send(:source_from_normalized_nodes, first_node, last_node)

        assert_equal :SOURCE, source_node.type
        assert_equal [], source_node.children
        assert_equal first_node.first_lineno, source_node.first_lineno
        assert_equal first_node.first_column, source_node.first_column
        assert_equal last_node.last_lineno, source_node.last_lineno
        assert_equal last_node.last_column, source_node.last_column
        assert_equal expected_text, source_node.text
      end
    end
  end

  def test_named_field
    cases = [
      [:ruby, "def check(value)\n  value\nend\n", ".rb", "method", "def check(value)\n  value\nend", "name", ["identifier", "check"]],
      [:ruby, "def check(value)\n  value\nend\n", ".rb", "method", "def check(value)\n  value\nend", "missing", nil],
      [:python, "if ready:\n    call()\n", ".py", "if_statement", "if ready:\n    call()", "body", ["block", "call()"]],
      [:python, "if ready:\n    call()\n", ".py", "if_statement", "if ready:\n    call()", "condition", ["identifier", "ready"]],
      [:typescript, "function check(value) { return value; }\n", ".ts", "function_declaration", "function check(value) { return value; }", "body", ["statement_block", "{ return value; }"]],
      [:lua, "function check(value)\n  return value\nend\n", ".lua", "function_declaration", "function check(value)\n  return value\nend", "body", ["block", "return value"]]
    ]

    cases.each do |language, source, suffix, kind, text, field, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:named_field, node, field)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_parent_node
    cases = [
      [:ruby, "def check\nend\n", ".rb", "identifier", "check", ["method", "def check\nend"]],
      [:ruby, "value\n", ".rb", "program", "value\n", nil],
      [:python, "if ready:\n    call()\n", ".py", "identifier", "ready", ["if_statement", "if ready:\n    call()"]],
      [:typescript, "call(value);\n", ".ts", "identifier", "value", ["arguments", "(value)"]],
      [:lua, "call(value)\n", ".lua", "identifier", "value", ["arguments", "(value)"]]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:parent_node, node)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_next_sibling
    cases = [
      [:ruby, "a + b\n", ".rb", "identifier", "a", ["+", "+"]],
      [:python, "a + b\n", ".py", "identifier", "a", ["+", "+"]],
      [:typescript, "a + b;\n", ".ts", "identifier", "a", ["+", "+"]],
      [:lua, "print(a, b)\n", ".lua", "identifier", "a", [",", ","]],
      [:ruby, "a\n", ".rb", "identifier", "a", nil]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:next_sibling, node)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_prev_sibling
    cases = [
      [:ruby, "a + b\n", ".rb", "identifier", "b", ["+", "+"]],
      [:python, "a + b\n", ".py", "identifier", "b", ["+", "+"]],
      [:typescript, "a + b;\n", ".ts", "identifier", "b", ["+", "+"]],
      [:lua, "print(a, b)\n", ".lua", "identifier", "b", [",", ","]],
      [:ruby, "a\n", ".rb", "identifier", "a", nil]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:prev_sibling, node)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_next_named_sibling
    cases = [
      [:ruby, "a + b\n", ".rb", "identifier", "a", ["identifier", "b"]],
      [:python, "a + b\n", ".py", "identifier", "a", ["identifier", "b"]],
      [:typescript, "a + b;\n", ".ts", "identifier", "a", ["identifier", "b"]],
      [:lua, "print(a, b)\n", ".lua", "identifier", "a", ["identifier", "b"]],
      [:ruby, "a\n", ".rb", "identifier", "a", nil]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        found = normalizer.send(:next_named_sibling, node)
        if expected
          assert_equal expected, [found&.kind, found&.text]
        else
          assert_nil found
        end
      end
    end
  end

  def test_ternary_statement_predicate
    cases = [
      [:ruby, "def f(cond, a, b)\n  cond ? a : b\nend\n", ".rb", "body_statement", "cond ? a : b", true],
      [:python, "value = a if cond else b\n", ".py", "conditional_expression", "a if cond else b", true],
      [:typescript, "const value = cond ? a : b;\n", ".ts", "ternary_expression", "cond ? a : b", true],
      [:lua, "local value = cond and a or b\n", ".lua", "expression_list", "cond and a or b", false],
      [:ruby, "def f(cond)\n  cond\nend\n", ".rb", "body_statement", "cond", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:ternary_statement?, node)
      end
    end
  end

  def test_ternary_statement_normalizes_to_if_across_languages
    {
      ruby: ["def f(cond, a, b)\n  cond ? a : b\nend\n", ".rb"],
      python: ["def f(cond, a, b):\n    return a if cond else b\n", ".py"],
      typescript: ["function f(cond: boolean, a: number, b: number) { return cond ? a : b; }\n", ".ts"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        if_node = nodes_of_type(root, "IF").find { |node| node.text.include?("cond") }

        refute_nil if_node
        assert_equal %w[cond a b], if_node.children.map(&:text)
      end
    end
  end

  def test_case_argument_list_predicate
    cases = [
      [
        :ruby,
        "def f(x)\n  return case x\n  when 1 then :one\n  else :other\n  end\nend\n",
        ".rb",
        "argument_list",
        "case x\n  when 1 then :one\n  else :other\n  end",
        true
      ],
      [:ruby, "case x\nwhen 1 then :one\nelse :other\nend\n", ".rb", "case", "case x\nwhen 1 then :one\nelse :other\nend", false],
      [:python, "match value:\n    case 1:\n        one()\n", ".py", "case_clause", "case 1:\n        one()", false],
      [:typescript, "switch (value) { case 1: one(); break; }\n", ".ts", "switch_case", "case 1: one(); break;", false],
      [:lua, "if value == 1 then one() end\n", ".lua", "if_statement", "if value == 1 then one() end", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:case_argument_list?, node)
      end
    end
  end

  def test_leading_function_statement_predicate
    cases = [
      [:ruby, "def outer\n  def inner\n    x\n  end\nend\n", ".rb", "body_statement", "def inner\n    x\n  end", true],
      [:python, "def outer():\n    def inner():\n        x\n", ".py", "block", "def inner():\n        x", true],
      [:lua, "function outer()\n  function inner()\n    x()\n  end\nend\n", ".lua", "block", "function inner()\n    x()\n  end", true],
      [:typescript, "function outer() { function inner() { x; } }\n", ".ts", "function_declaration", "function inner() { x; }", false],
      [:ruby, "def outer\n  x\nend\n", ".rb", "body_statement", "x", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:leading_function_statement?, node)
      end
    end
  end

  def test_leading_function_statement_normalizes_nested_functions
    {
      ruby: ["def outer\n  def inner\n    x\n  end\nend\n", ".rb"],
      python: ["def outer():\n    def inner():\n        x\n", ".py"],
      lua: ["function outer()\n  function inner()\n    x()\n  end\nend\n", ".lua"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        inner = nodes_of_type(root, "DEFN").find { |node| node.children.first == :inner }

        refute_nil inner
        assert_empty nodes_of_type(root, "ITER").select { |node| node.text.include?("inner") }
      end
    end
  end

  def test_lambda_expression_predicate
    cases = [
      [:ruby, "fn = ->(x) { x + 1 }\n", ".rb", "lambda", "->(x) { x + 1 }", true],
      [:python, "fn = lambda x: x + 1\n", ".py", "lambda", "lambda x: x + 1", true],
      [:typescript, "const fn = (x) => x + 1;\n", ".ts", "arrow_function", "(x) => x + 1", true],
      [:typescript, "const fn = function(x) { return x + 1; };\n", ".ts", "function_expression", "function(x) { return x + 1; }", true],
      [:lua, "local fn = function(x) return x + 1 end\n", ".lua", "expression_list", "function(x) return x + 1 end", true],
      [:lua, "function f(x) return x + 1 end\n", ".lua", "function_declaration", "function f(x) return x + 1 end", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:lambda_expression?, node)
      end
    end
  end

  def test_lambda_expressions_normalize_across_languages
    {
      ruby: ["fn = ->(x) { x + 1 }\n", ".rb"],
      python: ["fn = lambda x: x + 1\n", ".py"],
      typescript: ["const fn = (x) => x + 1;\n", ".ts"],
      lua: ["local fn = function(x) return x + 1 end\n", ".lua"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)

        refute_empty nodes_of_type(root, "LAMBDA"), "expected LAMBDA for #{language}"
      end
    end
  end

  def test_leading_owner_statement_predicate
    cases = [
      [:ruby, "def outer\n  class Inner\n    value\n  end\nend\n", ".rb", "body_statement", "class Inner\n    value\n  end", true],
      [:ruby, "def outer\n  module Inner\n    value\n  end\nend\n", ".rb", "body_statement", "module Inner\n    value\n  end", true],
      [:python, "def outer():\n    class Inner:\n        pass\n", ".py", "block", "class Inner:\n        pass", true],
      [:typescript, "function outer() { class Inner {} }\n", ".ts", "class_declaration", "class Inner {}", false],
      [:lua, "function outer()\n  Inner = {}\nend\n", ".lua", "block", "Inner = {}", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:leading_owner_statement?, node)
      end
    end
  end

  def test_leading_owner_statement_normalizes_nested_classes
    {
      ruby: ["def outer\n  class Inner\n    value\n  end\nend\n", ".rb"],
      python: ["def outer():\n    class Inner:\n        pass\n", ".py"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        inner = nodes_of_type(root, "CLASS").find { |node| node.text.include?("Inner") }

        refute_nil inner
        assert_empty nodes_of_type(root, "ITER").select { |node| node.text.include?("Inner") }
      end
    end
  end

  def test_zero_child_identifier_call_predicate
    cases = [
      [:ruby, "foo?\n", ".rb", "call", "foo?", true],
      [:ruby, "foo!\n", ".rb", "call", "foo!", true],
      [:ruby, "foo()\n", ".rb", "call", "foo()", false],
      [:python, "foo()\n", ".py", "expression_statement", "foo()", false],
      [:typescript, "foo();\n", ".ts", "call_expression", "foo()", false],
      [:lua, "foo()\n", ".lua", "function_call", "foo()", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:zero_child_identifier_call?, node)
      end
    end
  end

  def test_zero_child_identifier_call_normalizes_to_vcall
    %w[foo? foo!].each do |call|
      with_language_file("#{call}\n", ".rb", :ruby) do |file|
        root, = parse_language(file, :ruby)
        vcall = nodes_of_type(root, "VCALL").find { |node| node.text == call }

        refute_nil vcall
        assert_equal call.to_sym, vcall.children.first
      end
    end
  end

  def test_dotted_call_parts
    cases = [
      [:ruby, "user.name\n", ".rb", "call", "user.name", "identifier", "user", "name"],
      [:ruby, "user&.name\n", ".rb", "call", "user&.name", "identifier", "user", "name"],
      [:python, "user.name()\n", ".py", "attribute", "user.name", "identifier", "user", "name"],
      [:typescript, "user.name();\n", ".ts", "member_expression", "user.name", "identifier", "user", "name"],
      [:typescript, "user.name;\n", ".ts", "expression_statement", "user.name;", "identifier", "user", "name"],
      [:lua, "user.name()\n", ".lua", "dot_index_expression", "user.name", "identifier", "user", "name"]
    ]

    cases.each do |language, source, suffix, kind, text, receiver_kind, receiver_text, method_name|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        receiver, method = normalizer.send(:dotted_call_parts, node)
        assert_equal receiver_kind, receiver.kind
        assert_equal receiver_text, receiver.text.to_s
        assert_equal method_name, method
      end
    end
  end

  def test_python_bare_dotted_expression_normalizes_as_call
    with_language_file("user.name\n", ".py", :python) do |file|
      root, = parse_language(file, :python)
      call = nodes_of_type(root, "CALL").find { |node| node.text == "user.name" }

      refute_nil call
      assert_equal "LVAR", call.children.first.type.to_s
      assert_equal :name, call.children[1]
    end
  end

  def test_typescript_bare_dotted_expression_normalizes_as_call
    with_language_file("user.name;\n", ".ts", :typescript) do |file|
      document = parse_syntax(file, :typescript)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      node = ts_nodes(document.root).find do |candidate|
        candidate.kind == "expression_statement" && candidate.text == "user.name;"
      end
      call = normalizer.send(:normalize_dotted_expression, node)

      refute_nil call
      assert_equal "CALL", call.type.to_s
      assert_equal "LVAR", call.children.first.type.to_s
      assert_equal :name, call.children[1]
    end
  end

  def test_leading_if_statement_predicate
    cases = [
      [:ruby, "def f\n  if x\n    y\n  end\nend\n", ".rb", "body_statement", "if x\n    y\n  end", true],
      [:python, "def f():\n    if x:\n        y()\n", ".py", "block", "if x:\n        y()", true],
      [:lua, "function f()\n  if x then\n    y()\n  end\nend\n", ".lua", "block", "if x then\n    y()\n  end", true],
      [:typescript, "function f() { if (x) { y(); } }\n", ".ts", "if_statement", "if (x) { y(); }", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:leading_if_statement?, node)
      end
    end
  end

  def test_leading_if_statement_normalizes_across_languages
    {
      ruby: ["def f\n  if x\n    y\n  end\nend\n", ".rb"],
      python: ["def f():\n    if x:\n        y()\n", ".py"],
      lua: ["function f()\n  if x then\n    y()\n  end\nend\n", ".lua"],
      typescript: ["function f() { if (x) { y(); } }\n", ".ts"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)

        refute_empty nodes_of_type(root, "IF")
      end
    end
  end

  def test_leading_case_statement_predicate
    cases = [
      [
        :ruby,
        "def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n",
        ".rb",
        "body_statement",
        "case x\n  when 1 then y\n  else z\n  end",
        true
      ],
      [
        :python,
        "def f(x):\n    match x:\n        case 1:\n            y()\n",
        ".py",
        "block",
        "match x:\n        case 1:\n            y()",
        true
      ],
      [
        :typescript,
        "function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n",
        ".ts",
        "switch_statement",
        "switch (x) { case 1: y(); break; default: z(); }",
        false
      ],
      [
        :lua,
        "function f(x)\n  if x == 1 then y() end\nend\n",
        ".lua",
        "block",
        "if x == 1 then y() end",
        false
      ]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:leading_case_statement?, node)
      end
    end
  end

  def test_leading_case_statement_normalizes_across_languages
    {
      ruby: ["def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n", ".rb"],
      python: ["def f(x):\n    match x:\n        case 1:\n            y()\n", ".py"],
      typescript: ["function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n", ".ts"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)

        refute_empty nodes_of_type(root, "CASE")
      end
    end
  end

  def test_case_default_branches_normalize_as_when_fallbacks
    {
      python: ["match x:\n    case 1:\n        one()\n    case _:\n        other()\n", ".py", "other()"],
      typescript: ["switch (x) { case 1: one(); break; default: other(); }\n", ".ts", "other()"]
    }.each do |language, (source, suffix, fallback_text)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        case_node = nodes_of_type(root, "CASE").first

        refute_nil case_node
        whens = nodes_of_type(case_node, "WHEN")
        assert_equal 1, whens.size
        fallback = whens.first.children[2]
        assert Decomplex::Ast.node?(fallback)
        assert_equal "VCALL", fallback.type.to_s
        assert_equal fallback_text, fallback.text
      end
    end
  end

  def test_ruby_case_patterns_preserve_childless_tree_sitter_pattern_text
    with_language_file("case value\nwhen Foo\n  one\nend\ncase\nwhen ready\n  two\nend\n", ".rb", :ruby) do |file|
      root, = parse_language(file, :ruby)
      whens = nodes_of_type(root, "WHEN")

      const_pattern = whens.find { |node| node.text == "when Foo\n  one" }.children.first.children.first
      assert_equal "CONST", const_pattern.type.to_s
      assert_equal :Foo, const_pattern.children.first

      call_pattern = whens.find { |node| node.text == "when ready\n  two" }.children.first.children.first
      assert_equal "VCALL", call_pattern.type.to_s
      assert_equal :ready, call_pattern.children.first
    end
  end

  def test_leading_loop_statement_predicate
    cases = [
      [:ruby, "def f(x)\n  while x\n    y\n  end\nend\n", ".rb", "body_statement", "while x\n    y\n  end", true],
      [:python, "def f(x):\n    while x:\n        y()\n", ".py", "block", "while x:\n        y()", true],
      [:lua, "function f(x)\n  while x do\n    y()\n  end\nend\n", ".lua", "block", "while x do\n    y()\n  end", true],
      [:typescript, "function f(x) { while (x) { y(); } }\n", ".ts", "while_statement", "while (x) { y(); }", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:leading_loop_statement?, node)
      end
    end
  end

  def test_leading_loop_statement_normalizes_across_languages
    {
      ruby: ["def f(x)\n  while x\n    y\n  end\nend\n", ".rb"],
      python: ["def f(x):\n    while x:\n        y()\n", ".py"],
      lua: ["function f(x)\n  while x do\n    y()\n  end\nend\n", ".lua"],
      typescript: ["function f(x) { while (x) { y(); } }\n", ".ts"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)

        refute_empty nodes_of_type(root, "WHILE")
      end
    end
  end

  def test_rescue_body_statement_predicate
    cases = [
      [
        :ruby,
        "def f\n  work\nrescue Error => e\n  handle\nend\n",
        ".rb",
        "body_statement",
        "work\nrescue Error => e\n  handle",
        true
      ],
      [
        :python,
        "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
        ".py",
        "try_statement",
        "try:\n    work()\nexcept Error as e:\n    handle(e)",
        true
      ],
      [
        :python,
        "def f():\n    try:\n        work()\n    except Error as e:\n        handle(e)\n",
        ".py",
        "block",
        "try:\n        work()\n    except Error as e:\n        handle(e)",
        true
      ],
      [
        :typescript,
        "try { work(); } catch (e) { handle(e); }\n",
        ".ts",
        "try_statement",
        "try { work(); } catch (e) { handle(e); }",
        true
      ],
      [
        :lua,
        "local ok, err = pcall(work)\n",
        ".lua",
        "variable_declaration",
        "local ok, err = pcall(work)",
        false
      ]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:rescue_body_statement?, node)
      end
    end
  end

  def test_python_flattened_bare_except_normalizes_as_rescue
    with_python_file(<<~PY) do |file|
      def get_exception():
          try:
              pass
          except:
              foobarbaz
    PY
      root, = parse_python(file)
      rescue_node = nodes_of_type(root, "RESCUE").first
      resbody = nodes_of_type(root, "RESBODY").first

      refute_nil rescue_node
      refute_nil resbody
      assert_nil rescue_node.children.first
      assert_nil resbody.children.first
      assert_equal "VCALL", resbody.children[1].type.to_s
      assert_equal :foobarbaz, resbody.children[1].children.first
    end
  end

  def test_python_flattened_try_except_preserves_try_body
    with_python_file(<<~PY) do |file|
      def f():
          try:
              work()
          except Error as e:
              handle(e)
    PY
      root, = parse_python(file)
      rescue_node = nodes_of_type(root, "RESCUE").first
      resbody = nodes_of_type(root, "RESBODY").first

      refute_nil rescue_node
      assert_equal "VCALL", rescue_node.children.first.type.to_s
      assert_equal "work()", rescue_node.children.first.text
      refute_nil resbody.children.first
    end
  end

  def test_rescue_body_statement_normalizes_across_languages
    {
      ruby: ["def f\n  work\nrescue Error => e\n  handle\nend\n", ".rb"],
      python: ["try:\n    work()\nexcept Error as e:\n    handle(e)\n", ".py"],
      typescript: ["try { work(); } catch (e) { handle(e); }\n", ".ts"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)

        refute_empty nodes_of_type(root, "RESCUE")
        resbodies = nodes_of_type(root, "RESBODY")
        refute_empty resbodies
        refute_nil resbodies.first.children.first if %i[ruby python].include?(language)
      end
    end
  end

  def test_rescue_clause_preserves_qualified_exception_constant
    with_language_file("begin\n  work\nrescue Net::Error\n  handle\nend\n", ".rb", :ruby) do |file|
      root, = parse_language(file, :ruby)
      resbody = nodes_of_type(root, "RESBODY").first

      refute_nil resbody
      exceptions = resbody.children.first
      assert_equal "LIST", exceptions.type.to_s
      assert_equal ["Net::Error"], exceptions.children.map { |child| child.children.first.to_s }
    end
  end

  def test_ensure_body_statement_predicate
    cases = [
      [
        :ruby,
        "def f\n  work\nensure\n  cleanup\nend\n",
        ".rb",
        "body_statement",
        "work\nensure\n  cleanup",
        true
      ],
      [
        :python,
        "try:\n    work()\nfinally:\n    cleanup()\n",
        ".py",
        "try_statement",
        "try:\n    work()\nfinally:\n    cleanup()",
        true
      ],
      [
        :typescript,
        "try { work(); } finally { cleanup(); }\n",
        ".ts",
        "try_statement",
        "try { work(); } finally { cleanup(); }",
        true
      ],
      [
        :lua,
        "work()\ncleanup()\n",
        ".lua",
        "function_call",
        "work()",
        false
      ]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:ensure_body_statement?, node)
      end
    end
  end

  def test_ensure_body_statement_normalizes_across_languages
    {
      ruby: ["def f\n  work\nensure\n  cleanup\nend\n", ".rb"],
      python: ["try:\n    work()\nfinally:\n    cleanup()\n", ".py"],
      typescript: ["try { work(); } finally { cleanup(); }\n", ".ts"],
      python_rescue: ["try:\n    work()\nexcept Error as e:\n    handle(e)\nfinally:\n    cleanup()\n", ".py"]
    }.each do |language, (source, suffix)|
      parse_language_name = language == :python_rescue ? :python : language
      with_language_file(source, suffix, parse_language_name) do |file|
        root, = parse_language(file, parse_language_name)

        refute_empty nodes_of_type(root, "ENSURE")
        refute_empty nodes_of_type(root, "RESCUE") if language == :python_rescue
      end
    end
  end

  def test_array_literal_statement_predicate
    cases = [
      [:ruby, "def f\n  [a, b]\nend\n", ".rb", "body_statement", "[a, b]", true],
      [:python, "def f():\n    [a, b]\n", ".py", "block", "[a, b]", true],
      [:typescript, "function f() { [a, b]; }\n", ".ts", "expression_statement", "[a, b];", true],
      [:lua, "function f()\n  {a, b}\nend\n", ".lua", "block", "\n  {a, b}", true],
      [:lua, "function f()\n  {x = a, y = b}\nend\n", ".lua", "block", "\n  {x = a, y = b}", false],
      [
        :lua,
        "local rocks_path = table.concat({rocks_tree, \"a_rock\"})\n",
        ".lua",
        "arguments",
        "({rocks_tree, \"a_rock\"})",
        false
      ]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:array_literal_statement?, node)
      end
    end
  end

  def test_array_literal_statement_normalizes_across_languages
    {
      ruby: ["def f\n  [a, b]\nend\n", ".rb"],
      python: ["def f():\n    [a, b]\n", ".py"],
      typescript: ["function f() { [a, b]; }\n", ".ts"],
      lua: ["function f()\n  {a, b}\nend\n", ".lua"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        lists = nodes_of_type(root, "LIST")

        refute_empty lists
        assert lists.any? { |node| node.text.include?("a") && node.text.include?("b") }
      end
    end
  end

  def test_element_reference_statement_predicate
    cases = [
      [:ruby, "def f\n  items[0]\nend\n", ".rb", "body_statement", "items[0]", true],
      [:ruby, "def f\n  [0]\nend\n", ".rb", "body_statement", "[0]", false],
      [:python, "def f():\n    items[0]\n", ".py", "block", "items[0]", true],
      [:python, "return items[0]\n", ".py", "subscript", "items[0]", true],
      [:typescript, "function f() { items[0]; }\n", ".ts", "expression_statement", "items[0];", true],
      [:typescript, "return items[0];\n", ".ts", "subscript_expression", "items[0]", true],
      [:lua, "return items[1]\n", ".lua", "expression_list", "items[1]", true],
      [:lua, "print(items[1])\n", ".lua", "bracket_index_expression", "items[1]", true]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:element_reference_statement?, node)
      end
    end
  end

  def test_element_reference_statement_normalizes_across_languages
    {
      ruby: ["def f\n  items[0]\nend\n", ".rb"],
      python: ["def f():\n    items[0]\n", ".py"],
      typescript: ["function f() { items[0]; }\n", ".ts"],
      lua: ["return items[1]\n", ".lua"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        calls = nodes_of_type(root, "CALL")

        assert calls.any? { |node| node.children[1] == :[] && node.text.include?("items") },
               "expected element reference CALL for #{language}"
      end
    end
  end

  def test_hash_literal_statement_predicate
    cases = [
      [:ruby, "def f\n  {a: b}\nend\n", ".rb", "body_statement", "{a: b}", true],
      [:python, "def f():\n    {\"a\": b}\n", ".py", "block", "{\"a\": b}", true],
      [:typescript, "function f() { ({a: b}); }\n", ".ts", "expression_statement", "({a: b});", true],
      [:typescript, "return {a: b};\n", ".ts", "object", "{a: b}", true],
      [:lua, "function f()\n  {a = b}\nend\n", ".lua", "block", "\n  {a = b}", true],
      [:lua, "function f()\n  {a, b}\nend\n", ".lua", "block", "\n  {a, b}", false],
      [
        :lua,
        "assert.same(install, { bin = { P\"bin/binfile\" } })\n",
        ".lua",
        "arguments",
        "(install, { bin = { P\"bin/binfile\" } })",
        false
      ]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:hash_literal_statement?, node)
      end
    end
  end

  def test_hash_literal_statement_normalizes_across_languages
    {
      ruby: ["def f\n  {a: b}\nend\n", ".rb"],
      python: ["def f():\n    {\"a\": b}\n", ".py"],
      typescript: ["function f() { ({a: b}); }\n", ".ts"],
      lua: ["function f()\n  {a = b}\nend\n", ".lua"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        hashes = nodes_of_type(root, "HASH")

        assert hashes.any? { |node| node.text.include?("a") && node.text.include?("b") },
               "expected hash literal HASH for #{language}"
        assert_empty nodes_of_type(root, "OBJECT") if language == :typescript
        assert_empty nodes_of_type(root, "FCALL").select { |node| node.children.first == :"" } if language == :lua
      end
    end
  end

  def test_lua_call_arguments_with_keyed_table_preserve_argument_list
    with_language_file("assert.same(install, { bin = { P\"bin/binfile\" } })\n", ".lua", :lua) do |file|
      root, = parse_language(file, :lua)
      call = nodes_of_type(root, "FUNCTION_CALL").find { |node| node.text.start_with?("assert.same") }

      refute_nil call
      arguments = call.children[1]
      assert_equal "ARGUMENTS", arguments.type.to_s
      assert_equal %w[LVAR HASH], arguments.children.map(&:type).map(&:to_s)
      assert_equal "install", arguments.children.first.children.first
    end
  end

  def test_lua_call_arguments_with_positional_table_preserve_table_fields
    with_language_file("local rocks_path = table.concat({rocks_tree, \"a_rock\"})\n", ".lua", :lua) do |file|
      root, = parse_language(file, :lua)
      arguments = nodes_of_type(root, "ARGUMENTS").find { |node| node.text == "({rocks_tree, \"a_rock\"})" }

      refute_nil arguments
      table = arguments.children.first
      assert_equal "ARGUMENTS", arguments.type.to_s
      assert_equal "HASH", table.type.to_s
      assert_equal %w[FIELD FIELD], table.children.map(&:type).map(&:to_s)
      assert_empty table.children.first.children
      assert_equal "STR", table.children[1].children.first.type.to_s
    end
  end

  def test_empty_body_statement_predicate
    cases = [
      [:python, "def f():\n    pass\n", ".py", "block", "pass", true],
      [:typescript, "function f() {}\n", ".ts", "statement_block", "{}", true],
      [:typescript, "function f() { work(); }\n", ".ts", "statement_block", "{ work(); }", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:empty_body_statement?, node)
      end
    end
  end

  def test_empty_body_statement_normalizes_across_languages
    {
      python: ["def f():\n    pass\n", ".py"],
      typescript: ["function f() {}\n", ".ts"]
    }.each do |language, (source, suffix)|
      with_language_file(source, suffix, language) do |file|
        root, = parse_language(file, language)
        defn = nodes_of_type(root, "DEFN").first
        scope = defn.children[1]

        assert_nil scope.children[2]
        assert_empty nodes_of_type(root, "VCALL").select { |node| node.text == "pass" } if language == :python
      end
    end
  end

  def test_heredoc_body_statement_predicate
    ruby_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n"
    cases = [
      [:ruby, ruby_source, ".rb", "body_statement", "puts <<~TXT\n    hi\n  TXT", true],
      [:ruby, ruby_source, ".rb", "call", "puts <<~TXT", false],
      [:python, "def f():\n    value = 1\n", ".py", "block", "value = 1", false],
      [:typescript, "function f() { value = 1; }\n", ".ts", "statement_block", "{ value = 1; }", false],
      [:lua, "function f()\n  value = 1\nend\n", ".lua", "block", "value = 1", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:heredoc_body_statement?, node)
      end
    end
  end

  def test_heredoc_call_for_body_predicate
    ruby_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n"
    cases = [
      [:ruby, ruby_source, ".rb", "body_statement", "puts <<~TXT\n    hi\n  TXT", true],
      [:ruby, ruby_source, ".rb", "call", "puts <<~TXT", true],
      [:ruby, ruby_source, ".rb", "argument_list", "<<~TXT", true],
      [:ruby, ruby_source, ".rb", "method", ruby_source.chomp, false],
      [:python, "def f():\n    value = 1\n", ".py", "block", "value = 1", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:heredoc_call_for_body?, node)
      end
    end
  end

  def test_ruby_heredoc_argument_normalizes_as_dynamic_string
    with_language_file("def f\n  puts <<~TXT\n    hi\n  TXT\nend\n", ".rb", :ruby) do |file|
      root, = parse_language(file, :ruby)
      call = nodes_of_type(root, "FCALL").find { |node| node.text == "puts <<~TXT" }

      refute_nil call
      assert_equal :puts, call.children[0]

      args = call.children[1]
      assert_equal "LIST", args.type.to_s
      dstr = args.children.first
      assert_equal "DSTR", dstr.type.to_s
      assert_equal ["STR"], dstr.children.map { |child| child.type.to_s }
      assert_equal "\n    hi\n  ", dstr.children.first.children.first
    end
  end

  def test_normalize_children_skips_heredoc_body
    with_language_file("def f\n  x = <<~TXT\n    hi\n  TXT\nend\n", ".rb", :ruby) do |file|
      document = parse_syntax(file, :ruby)
      normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
      body = ts_nodes(document.root).find do |node|
        node.kind == "body_statement" && node.text.include?("<<~TXT")
      end

      refute_nil body
      children = normalizer.send(:normalize_children, body)
      assert_equal ["LASGN"], children.map { |child| child.type.to_s }
      assert_equal ["STR"], children.first.children[1].children.map { |child| child.type.to_s }
    end
  end

  def test_with_current_heredoc_body_restores_previous_body
    normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
    normalizer.instance_variable_set(:@current_heredoc_body, :outer)

    result = normalizer.send(:with_current_heredoc_body, :inner) do
      assert_equal :inner, normalizer.instance_variable_get(:@current_heredoc_body)
      :result
    end

    assert_equal :result, result
    assert_equal :outer, normalizer.instance_variable_get(:@current_heredoc_body)
  end

  def test_interpolated_statement_predicate
    cases = [
      [:ruby, "def f\n  \"hi \#{name}\"\nend\n", ".rb", "body_statement", "\"hi \#{name}\"", true],
      [:python, "def f():\n    f\"hi {name}\"\n", ".py", "block", "f\"hi {name}\"", false],
      [:typescript, "function f() { `hi ${name}`; }\n", ".ts", "expression_statement", "`hi ${name}`;", false],
      [:lua, "function f()\n  \"hi\"\nend\n", ".lua", "block", "\n  \"hi\"", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:interpolated_statement?, node)
      end
    end
  end

  def test_concatenated_string_statement_predicate
    cases = [
      [:ruby, "def f\n  \"a\" \"b\"\nend\n", ".rb", "body_statement", "\"a\" \"b\"", true],
      [:python, "def f():\n    \"a\" \"b\"\n", ".py", "block", "\"a\" \"b\"", true],
      [:typescript, "function f() { \"a\"; }\n", ".ts", "expression_statement", "\"a\";", false],
      [:lua, "function f()\n  \"a\"\nend\n", ".lua", "block", "\n  \"a\"", false]
    ]

    cases.each do |language, source, suffix, kind, text, expected|
      with_language_file(source, suffix, language) do |file|
        document = parse_syntax(file, language)
        normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
        node = ts_nodes(document.root).find { |candidate| candidate.kind == kind && candidate.text == text }

        refute_nil node
        assert_equal expected, normalizer.send(:concatenated_string_statement?, node)
      end
    end
  end

  def test_concatenated_string_statement_normalizes_python_adjacent_strings
    with_python_file(<<~PY) do |file|
      def f():
          "a" "b"
    PY
      root, = parse_python(file)
      dstr = nodes_of_type(root, "DSTR").find { |node| node.text == "\"a\"" }

      refute_nil dstr
      assert_equal %w[STR STR], dstr.children.map(&:type).map(&:to_s)
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
