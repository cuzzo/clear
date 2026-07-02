# frozen_string_literal: true

require "prism"
require "set"

require_relative "method_registry"

module RubyToClear
  class Transpiler
    class TranspilationError < StandardError; end

    LambdaParameters = Struct.new(
      :parameter_names,
      :scope_names,
      :setup_lines,
      keyword_init: true
    )

    DYNAMIC_RUBY_CALLS = {
      "send" => "dynamic dispatch; replace with a closed case/table over known method names",
      "__send__" => "dynamic dispatch; replace with a closed case/table over known method names",
      "public_send" => "dynamic dispatch; replace with a closed case/table over known method names",
      "const_get" => "dynamic constant lookup; replace with an explicit registry map",
      "const_defined?" => "dynamic constant lookup; replace with an explicit registry map",
      "instance_variable_get" => "dynamic instance state; replace with declared fields or a typed side table",
      "instance_variable_set" => "dynamic instance state; replace with declared fields or a typed side table",
      "define_method" => "dynamic method definition; generate explicit methods or a closed dispatcher",
      "method_missing" => "dynamic method definition; replace with explicit protocol methods",
      "eval" => "dynamic evaluation; refactor before translation",
      "instance_eval" => "dynamic evaluation; refactor before translation",
      "class_eval" => "dynamic evaluation; refactor before translation",
      "module_eval" => "dynamic evaluation; refactor before translation",
    }.freeze

    CLEAR_KEYWORDS = %w[
      MUTABLE
      FN METHOD RETURN RETURNS USE
      IF THEN ELSE ELSE_IF END COMPTIME IS_A
      WHILE DO FOR IN BG NEXT BREAK CONTINUE
      CAST AS
      STRUCT ENUM UNION TRUE FALSE NIL Auto
      ASSERT RAISE CATCH EXIT DIE PASS PRUNE
      MOD OR
      REQUIRE
      SELECT WHERE INDEX REDUCE ORDER_BY LIMIT SKIP UNNEST DISTINCT EACH TAP FIND ANY ALL COUNT SUM AVERAGE MIN MAX CONCURRENT SHARD TAKE_WHILE WINDOW JOIN RECOVER COLLECT
      GIVE TAKES COPY MOVE CLONE SHARE LINK RESOLVE FREEZE
      WITH EXCLUSIVE RESTRICT BORROWED ON RETRY POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE VIEW MATERIALIZED SNAPSHOT GUARD PRE DEBUG_POST
      POLYMORPHIC SHARED SYNC POLICY
      REQUIRES
      MATCH PARTIAL START DEFAULT WHEN
      PUB PRIVATE
      EXTERN FROM EFFECTS CLOSE
      STREAM YIELD
      TIGHT
      TEST THAT STUB BENCHMARK SMASH PROFILE ASSERT_RAISES CAPTURES SEQUENCE
      PENDING BEFORE AFTER LET TAGS
    ].to_set.freeze

    def initialize(source, raise_on_error: true, source_path: nil)
      @source = source
      @source_path = source_path
      @raise_on_error = raise_on_error
      @indent_level = 0
      @declared_locals = Set.new
      @class_variables = Set.new
      @struct_fields = {}
      @method_params = {}
      @constructor_params = {}
      @loaded_metadata_files = Set.new
      @constant_names = {}
      @current_class = nil
      @renames = {}
      @mutable_params = nil
      @type_aliases = {}
      @union_types = {}
      @generated_union_defs = {}
      @method_return_types = {}
      @required_packages = Set.new
      @current_function_can_fail = false
      @inside_function = false
      @current_function_returns_value = false
      @local_shapes = {}
      @local_types = {}
      @singleton_class_depth = 0
      @current_function_type_bindings = {}
    end

    def transpile(program_node)
      preload_required_metadata(program_node)
      collect_type_aliases_from_node(program_node)
      collect_ast_node_variants_from_node(program_node)
      collect_method_signature_metadata_from_node(program_node)
      collect_method_params_from_node(program_node)
      body = visit(program_node)
      requires = @required_packages.sort.map { |package| "REQUIRE \"pkg:#{package}\"" }
      generated_unions = @generated_union_defs.keys.sort.map { |name| @generated_union_defs[name] }
      (requires + generated_unions + [body]).reject(&:empty?).join("\n")
    end

    def visit(node)
      return "" unless node

      node_name = node.class.name.split("::").last
      method_name = "visit_#{node_name.gsub(/(?<!^)(?=[A-Z])/, '_').downcase}"
      if respond_to?(method_name, true)
        send(method_name, node)
      else
        raise_unsupported("Unsupported node #{node_name}", node)
      end
    end

    def with_renames(new_renames)
      old_renames = @renames.dup
      @renames.merge!(new_renames.compact)
      yield
    ensure
      @renames = old_renames
    end

    def with_block_local_scope
      old_declared = @declared_locals.dup
      old_shapes = @local_shapes.dup
      old_types = @local_types.dup
      yield
    ensure
      @declared_locals = old_declared
      @local_shapes = old_shapes
      @local_types = old_types
    end

    def require_package(package)
      @required_packages << package.to_s
    end

    def mark_current_function_fallible!
      @current_function_can_fail = true
    end

    def raise_unsupported(message, node)
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      err_msg = "Unsupported Ruby syntax: #{message} at line #{source_loc}\nSource: #{loc.slice.strip}"
      
      if @raise_on_error
        raise TranspilationError, err_msg
      else
        unsupported_comment(node, message)
      end
    end

    def simple_block_expression?(block_node)
      body_node = block_node.body
      return false unless body_node.is_a?(Prism::StatementsNode)
      return false unless body_node.body.size == 1
      pure_expression?(body_node.body.first)
    end

    def pure_expression?(node)
      return false unless node
      case node.class.name.split("::").last
      when "CallNode", "LocalVariableReadNode", "IntegerNode", "StringNode", "SymbolNode", "SelfNode",
           "AndNode", "OrNode", "ParenthesesNode", "NilNode", "FalseNode", "TrueNode",
           "ArrayNode", "HashNode", "RangeNode", "ConstantReadNode", "ConstantPathNode"
        true
      else
        false
      end
    end

    def parse_sig(sig_call_node)
      param_types = {}
      return_type = "Auto"
      
      return [param_types, return_type] unless sig_call_node&.block
      
      body_node = sig_call_node.block.body
      return [param_types, return_type] unless body_node.is_a?(Prism::StatementsNode)
      
      body_node.body.each do |stmt|
        walk_sig_chain = ->(call_node) do
          return unless call_node.is_a?(Prism::CallNode)
          
          case call_node.name.to_s
          when "void"
            return_type = "Void"
          when "returns"
            if call_node.arguments && call_node.arguments.arguments.first
              return_type = convert_sorbet_type(call_node.arguments.arguments.first, union_name: "ReturnValue", emit_union: true)
            end
          when "params"
            if call_node.arguments && call_node.arguments.arguments.first.is_a?(Prism::KeywordHashNode)
              call_node.arguments.arguments.first.elements.each do |assoc|
                if assoc.is_a?(Prism::AssocNode)
                  param_name = assoc.key.value.to_s
                  param_type = convert_sorbet_type(assoc.value, union_name: camel_type_name(param_name), emit_union: true)
                  param_types[param_name] = param_type
                end
              end
            end
          end
          
          walk_sig_chain.call(call_node.receiver) if call_node.receiver
        end
        
        walk_sig_chain.call(stmt)
      end
      
      [param_types, return_type]
    end

    def convert_sorbet_type(node, union_name: nil, emit_union: false)
      return "Auto" unless node
      
      case node.class.name.split("::").last
      when "ConstantReadNode"
        name = node.name.to_s
        return @type_aliases[name] if @type_aliases.key?(name)

        case name
        when "Integer" then "Int64"
        when "Float" then "Float64"
        when "String" then "String"
        when "StringScanner" then "Scanner"
        when "Symbol" then "String@symbol"
        when "NilClass" then "Void"
        when "Boolean" then "Bool"
        when "TrueClass", "FalseClass" then "Bool"
        when "T" then "Auto"
        else name
        end
      when "ConstantPathNode"
        path = node.location.slice.strip
        if path == "AST::Node"
          ensure_ast_node_union!(emit: emit_union)
          return "Node"
        end

        case path
        when "T::Boolean" then "Bool"
        when "T::Array" then "Any"
        when "T::Hash" then "Any"
        when "T::Set" then "Any"
        when "T.untyped" then "Auto"
        else path.split("::").last
        end
      when "CallNode"
        if node.receiver && node.receiver.location.slice.strip == "T"
          case node.name.to_s
          when "nilable"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "Auto" if inner == "Auto"

            return "?#{inner}"
          when "any"
            args = node.arguments ? node.arguments.arguments : []
            non_nil_args = args.reject { |a| a.location.slice.strip == "NilClass" }
            if non_nil_args.length == 1
              inner = convert_sorbet_type(non_nil_args.first)
              return "?#{inner}"
            elsif (union = sorbet_union_from_any_args(non_nil_args, union_name: union_name, emit_union: emit_union))
              return union
            else
              return "Auto"
            end
          when "untyped", "anything"
            return "Auto"
          end
        end
        
        if node.name.to_s == "[]"
          receiver_name = node.receiver ? node.receiver.location.slice.strip : ""
          if receiver_name == "T::Array" || receiver_name == "Array"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "Any" if inner == "Auto"

            return "#{collection_element_type(inner)}[]"
          elsif receiver_name == "T::Hash" || receiver_name == "Hash"
            args = node.arguments ? node.arguments.arguments : []
            key = convert_sorbet_type(args[0])
            value = convert_sorbet_type(args[1])
            return "Any" if key == "Auto" || value == "Auto"

            return "HashMap<#{collection_element_type(key)}, #{collection_element_type(value)}>"
          elsif receiver_name == "T::Set" || receiver_name == "Set"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "Any" if inner == "Auto"

            return "#{collection_element_type(inner)}[]@set"
          elsif receiver_name == "T::Enumerable" || receiver_name == "Enumerable"
            inner = convert_sorbet_type(node.arguments&.arguments&.first)
            return "Any" if inner == "Auto"

            return "#{collection_element_type(inner)}[]"
          end
        end
        
        "Auto"
      when "ArrayNode"
        members = node.elements.map { |element| convert_sorbet_type(element) }
        return "Auto" if members.empty? || members.any? { |member| member == "Auto" }

        "Tuple<#{members.join(', ')}>"
      else
        "Auto"
      end
    end

    def ensure_ast_node_union!(emit:)
      members = @union_types["Node"]
      return nil unless members && members.any?

      @generated_union_defs["Node"] = union_definition("Node", members) if emit
      "Node"
    end

    def sorbet_union_from_any_args(args, union_name:, emit_union:)
      return nil unless union_name

      members = args.map { |arg| convert_sorbet_type(arg) }
      return nil if members.length < 2
      return nil unless members.all? { |type| union_member_type?(type) }

      register_union_type(union_name, members, emit: emit_union)
    end

    def union_member_type?(type)
      text = type.to_s
      return false if text.empty? || text == "Auto" || text == "Any"
      return false if text.start_with?("?") || text.include?("[]") || text.start_with?("HashMap<")

      !%w[Int64 Float64 String Bool Void String@symbol].include?(text)
    end

    def register_union_type(name, members, emit:)
      clear_name = camel_type_name(name)
      normalized_members = members.map { |member| clear_type_expr(member) }.uniq
      return "Auto" if normalized_members.empty?

      normalized_members = ((@union_types[clear_name] || []) + normalized_members).uniq
      @union_types[clear_name] = normalized_members
      @generated_union_defs[clear_name] = union_definition(clear_name, normalized_members) if emit
      clear_name
    end

    def union_definition(name, members)
      variants = members.map { |member| "#{union_variant_name(member)}: #{member}" }.join(", ")
      "UNION #{name} { #{variants} }"
    end

    def union_variant_name(type)
      type.to_s.split(".").last
    end

    def camel_type_name(name)
      parts = name.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?)
      return "Value" if parts.empty?

      parts.map { |part| part[0].upcase + part[1..].to_s }.join
    end

    private

    def collection_element_type(type)
      type.to_s.split("@").first
    end

    def indent
      "  " * @indent_level
    end

    def with_indent
      @indent_level += 1
      yield
    ensure
      @indent_level -= 1
    end

    def format_statement_code(code)
      unless code.end_with?(";") || block_statement_output?(code) || code.lstrip.start_with?("#")
        code = "#{code};"
      end

      code.split("\n").map { |line| line.start_with?(" ") ? line : "#{indent}#{line}" }.join("\n")
    end

    def clear_string_literal(content)
      if content.include?("\n") && !content.include?('"""') && !content.include?("\r")
        "\"\"\"#{content}\"\"\""
      else
        "\"#{clear_string_escape(content)}\""
      end
    end

    def clear_string_escape(content)
      content.each_codepoint.map do |codepoint|
        case codepoint
        when 0x08 then "\\b"
        when 0x09 then "\\t"
        when 0x0A then "\\n"
        when 0x0D then "\\r"
        when 0x22 then "\\\""
        when 0x5C then "\\\\"
        else
          if codepoint < 0x20 || codepoint == 0x7F
            "\\x#{codepoint.to_s(16).upcase.rjust(2, '0')}"
          elsif codepoint > 0x7E
            "\\u{#{codepoint.to_s(16).upcase}}"
          else
            codepoint.chr(Encoding::UTF_8)
          end
        end
      end.join
    end

    def translate_rspec_call(node)
      return translate_rspec_suite(node) if rspec_suite_call?(node)
      return nil unless rspec_dsl_call?(node)

      case node.name.to_s
      when "describe", "context"
        rspec_when_blocks(node).join("\n")
      when "it", "specify"
        translate_rspec_example(node)
      when "to", "not_to"
        translate_rspec_expectation(node)
      end
    end

    def rspec_suite_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.name.to_s == "describe"

      receiver = node.receiver
      receiver.is_a?(Prism::ConstantReadNode) && receiver.name.to_s == "RSpec"
    end

    def rspec_dsl_call?(node)
      node.is_a?(Prism::CallNode) && ["describe", "context", "it", "specify", "to", "not_to"].include?(node.name.to_s)
    end

    def translate_rspec_suite(node)
      name = test_block_name(rspec_description(node))
      body = rspec_block_statements(node)
      setup_nodes, group_nodes, example_nodes = partition_rspec_body(body)
      setup = setup_nodes.map { |stmt| format_statement_code(visit(stmt)) }.reject(&:empty?)
      whens = group_nodes.flat_map { |group| rspec_when_blocks(group) }
      if example_nodes.any?
        whens << render_rspec_when("examples", [], example_nodes)
      end

      sections = setup + whens
      inner = sections.empty? ? "" : with_indent { sections.map { |section| indent_multiline(section) }.join("\n") }
      "TEST #{name} DO\n#{inner}\nEND"
    end

    def rspec_when_blocks(node, prefix = nil, inherited_setup = [])
      desc = rspec_description(node)
      full_desc = [prefix, desc].compact.reject(&:empty?).join(" / ")
      body = rspec_block_statements(node)
      setup_nodes, group_nodes, example_nodes = partition_rspec_body(body)
      setup = inherited_setup + setup_nodes.map { |stmt| format_statement_code(visit(stmt)) }.reject(&:empty?)

      blocks = []
      blocks << render_rspec_when(full_desc, setup, example_nodes) if example_nodes.any?
      group_nodes.each do |group|
        blocks.concat(rspec_when_blocks(group, full_desc, setup))
      end
      blocks
    end

    def render_rspec_when(desc, setup, example_nodes)
      body_sections = setup + example_nodes.map { |example| translate_rspec_example(example) }
      body = with_indent { body_sections.map { |section| indent_multiline(section) }.join("\n") }
      "WHEN #{clear_string_literal(desc)} DO\n#{body}\nEND"
    end

    def translate_rspec_example(node)
      desc = rspec_description(node)
      body_code = with_indent { visit(node.block&.body) }
      "TEST THAT #{clear_string_literal(desc)} DO\n#{body_code}\nEND"
    end

    def translate_rspec_expectation(node)
      expected_positive = node.name.to_s == "to"
      expect_call = node.receiver
      return nil unless expect_call&.name.to_s == "expect"

      matcher = node.arguments&.arguments&.first
      return unsupported_expression(node, "RSpec expectation without matcher is not supported") unless matcher

      if matcher.is_a?(Prism::CallNode) && matcher.name.to_s == "raise_error"
        return translate_rspec_raise_error(expect_call, matcher)
      end

      actual_arg = expect_call.arguments&.arguments&.first
      return unsupported_expression(expect_call, "RSpec block expectations only support raise_error") unless actual_arg

      actual = visit(actual_arg)
      assertion = rspec_matcher_assertion(actual, matcher, expected_positive)
      return assertion if assertion

      unsupported_expression(matcher, "RSpec matcher #{matcher.location.slice.strip} is not supported")
    end

    def translate_rspec_raise_error(expect_call, matcher)
      block_body = expect_call.block&.body
      unless block_body.is_a?(Prism::StatementsNode) && block_body.body.length == 1
        return unsupported_expression(expect_call, "RSpec raise_error needs a single-expression block")
      end

      expr = visit(block_body.body.first).delete_suffix(";")
      args = matcher.arguments ? matcher.arguments.arguments : []
      kind = if args.first&.location&.slice&.include?("ParserError")
        "Input"
      else
        "Input"
      end
      "ASSERT_RAISES #{kind}, #{expr}"
    end

    def rspec_matcher_assertion(actual, matcher, positive)
      return nil unless matcher.is_a?(Prism::CallNode)

      args = matcher.arguments ? matcher.arguments.arguments : []
      pred = case matcher.name.to_s
      when "eq"
        return nil unless args.length == 1

        "#{actual} == #{visit(args.first)}"
      when "be"
        return nil unless args.length == 1

        "#{actual} == #{visit(args.first)}"
      when "be_nil"
        "#{actual} == NIL"
      when "be_truthy"
        actual
      when "be_falsey"
        "!(#{actual})"
      when "be_a", "be_an"
        return nil unless args.length == 1

        type_name = static_type_name(args.first)
        return nil unless type_name

        "isA?(#{actual}, #{type_name.inspect})"
      when "all"
        return nil unless args.length == 1
        nested = args.first
        return nil unless nested.is_a?(Prism::CallNode) && ["be_a", "be_an"].include?(nested.name.to_s)

        nested_args = nested.arguments ? nested.arguments.arguments : []
        return nil unless nested_args.length == 1

        type_name = static_type_name(nested_args.first)
        return nil unless type_name

        "#{actual} |> ALL isA?(_, #{type_name.inspect})"
      when "include"
        return nil if args.empty?

        args.map { |arg| "#{actual}.contains?(#{visit(arg)})" }.join(" && ")
      end
      return nil unless pred

      pred = "!(#{pred})" unless positive
      "ASSERT #{pred}, #{clear_string_literal(rspec_assertion_message(actual, matcher, positive))}"
    end

    def rspec_assertion_message(actual, matcher, positive)
      expectation = positive ? "to" : "not_to"
      "expected #{actual} #{expectation} #{matcher.location.slice.strip}"
    end

    def static_type_name(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        node.location.slice.strip
      when Prism::StringNode
        node.content
      when Prism::SymbolNode
        node.value.to_s
      end
    end

    RUBY_TYPE_TO_CLEAR_TYPE = {
      "Integer" => "Int64",
      "Float" => "Float64",
      "String" => "String",
      "StringScanner" => "Scanner",
      "Symbol" => "String@symbol",
      "NilClass" => "Void",
      "Boolean" => "Bool",
      "TrueClass" => "Bool",
      "FalseClass" => "Bool",
      "Numeric" => "Float64",
    }.freeze

    def clear_type_expr(ruby_type_name)
      raw = ruby_type_name.to_s
      RUBY_TYPE_TO_CLEAR_TYPE.fetch(raw) { raw.gsub("::", ".") }
    end

    public :clear_type_expr

    def partition_rspec_body(body)
      setup = []
      groups = []
      examples = []
      body.each do |stmt|
        if rspec_group_node?(stmt)
          groups << stmt
        elsif rspec_example_node?(stmt)
          examples << stmt
        else
          setup << stmt
        end
      end
      [setup, groups, examples]
    end

    def rspec_group_node?(node)
      node.is_a?(Prism::CallNode) && ["describe", "context"].include?(node.name.to_s) && node.block
    end

    def rspec_example_node?(node)
      node.is_a?(Prism::CallNode) && ["it", "specify"].include?(node.name.to_s) && node.block
    end

    def rspec_block_statements(node)
      body = node.block&.body
      return [] unless body.is_a?(Prism::StatementsNode)

      body.body
    end

    def rspec_description(node)
      arg = node.arguments&.arguments&.first
      case arg
      when Prism::StringNode
        arg.content
      when Prism::SymbolNode
        arg.value.to_s
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        arg.location.slice.strip.split("::").last
      else
        node.name.to_s
      end
    end

    def test_block_name(description)
      words = description.to_s.scan(/[A-Za-z0-9]+/)
      name = words.map { |word| word[0].upcase + word[1..].to_s }.join
      name = "RSpec" if name.empty?
      name = "RSpec#{name}" unless name.match?(/\A[A-Z]/)
      name
    end

    def indent_multiline(code)
      code.split("\n").map { |line| line.empty? ? line : "#{indent}#{line}" }.join("\n")
    end

    def class_variable_name(name)
      name.to_s.delete_prefix("@@")
    end

    def clear_function_name(name)
      raw = name.to_s
      return "initialize!" if raw == "initialize"
      return "set_#{raw.delete_suffix('=')}!" if raw.end_with?("=")

      raw
    end

    def constant_variable_name(name)
      name.to_s.downcase
    end

    def simple_multi_target_names(param)
      return nil unless param.is_a?(Prism::MultiTargetNode)
      return nil if param.rest || param.rights.any?
      return nil unless param.lefts.all? { |left| left.respond_to?(:name) }

      param.lefts.map { |left| left.name.to_s }
    end

    def block_lambda_parameters(block_node)
      params_node = block_node.parameters&.parameters
      return LambdaParameters.new(parameter_names: [], scope_names: [], setup_lines: []) unless params_node

      if params_node.optionals.any? || params_node.rest || params_node.posts.any? ||
         params_node.keywords.any? || params_node.keyword_rest || params_node.block
        return unsupported_expression(block_node.parameters, "Block parameter shape is not supported")
      end

      parameter_names = []
      scope_names = []
      setup_lines = []
      params_node.requireds.each_with_index do |param, index|
        if param.respond_to?(:name)
          name = param.name.to_s
          parameter_names << name
          scope_names << name
          next
        end

        target_names = simple_multi_target_names(param)
        return unsupported_expression(param, "Block parameter destructuring is not supported") unless target_names

        tuple_name = "tuple_param_#{index}"
        parameter_names << tuple_name
        scope_names << tuple_name
        target_names.each_with_index do |target_name, target_index|
          scope_names << target_name
          setup_lines << "MUTABLE #{target_name} = #{tuple_name}[#{target_index}];"
        end
      end

      LambdaParameters.new(
        parameter_names: parameter_names,
        scope_names: scope_names,
        setup_lines: setup_lines
      )
    end

    def block_lambda_parameter_names(block_node)
      params = block_lambda_parameters(block_node)
      return params if unsupported_output?(params)

      params.parameter_names
    end

    def with_lambda_scope(parameter_names)
      old_declared = @declared_locals.dup
      old_shapes = @local_shapes.dup
      old_types = @local_types.dup
      parameter_names.each { |name| @declared_locals << name }
      yield
    ensure
      @declared_locals = old_declared
      @local_shapes = old_shapes
      @local_types = old_types
    end

    def unsupported_output?(value)
      value.is_a?(String) && (value.include?("# [UNSUPPORTED:") || value.include?("unsupportedRuby("))
    end

    def statement_code(code)
      return code if code.end_with?(";") || block_statement_output?(code) || code.lstrip.start_with?("#")

      "#{code};"
    end

    def indent_lambda_line(code)
      code.split("\n").map { |line| line.empty? ? line : "  #{line}" }.join("\n")
    end

    def lambda_statement_node?(stmt)
      case stmt
      when Prism::LocalVariableWriteNode,
           Prism::InstanceVariableWriteNode,
           Prism::ClassVariableWriteNode,
           Prism::ConstantWriteNode,
           Prism::MultiWriteNode
        true
      when Prism::CallNode
        name = stmt.name.to_s
        name == "[]=" || name.end_with?("=")
      else
        false
      end
    end

    def render_lambda_body(block_node, setup_lines: [])
      body = block_node.body
      return setup_lines.empty? ? "NIL" : "{\n#{setup_lines.map { |line| indent_lambda_line(line) }.join("\n")}\n}" unless body.is_a?(Prism::StatementsNode)

      statements = body.body
      if statements.last.is_a?(Prism::IfNode)
        prefix = statements[0...-1].map { |stmt| visit(stmt) }.reject(&:empty?).map { |code| statement_code(code) }
        lines = setup_lines.map { |code| indent_lambda_line(statement_code(code)) }
        lines.concat(prefix.map { |code| indent_lambda_line(code) })
        lines << indent_lambda_line(render_lambda_returning_statement(statements.last))
        lines << "  NIL"
        return "{\n#{lines.join("\n")}\n}"
      end

      rendered_pairs = statements.map { |stmt| [stmt, visit(stmt)] }.reject { |_stmt, code| code.empty? }
      rendered = rendered_pairs.map(&:last)
      if rendered.empty?
        return "NIL" if setup_lines.empty?

        lines = setup_lines.map { |code| indent_lambda_line(statement_code(code)) }
        return "{\n#{lines.join("\n")}\n}"
      end
      if setup_lines.empty? && rendered_pairs.length == 1 &&
         !block_statement_output?(rendered_pairs.first.last) &&
         !lambda_statement_node?(rendered_pairs.first.first)
        return rendered.first.delete_suffix(";")
      end

      lines = setup_lines.map { |code| indent_lambda_line(statement_code(code)) }
      lines.concat(rendered_pairs.map.with_index do |(stmt, code), index|
        final_statement = index == rendered_pairs.length - 1 && lambda_statement_node?(stmt)
        line = if final_statement
          statement_code(code)
        elsif index == rendered_pairs.length - 1
          code.delete_suffix(";")
        else
          statement_code(code)
        end
        indent_lambda_line(line)
      end)
      lines << "  NIL" if lambda_statement_node?(rendered_pairs.last.first)
      "{\n#{lines.join("\n")}\n}"
    end

    def render_lambda_returning_statement(stmt)
      case stmt
      when Prism::IfNode
        render_lambda_returning_if_node(stmt)
      else
        "RETURN #{visit(stmt).delete_suffix(';')};"
      end
    end

    def render_lambda_returning_statements(statements_node)
      statements = statements_node&.body || []
      return "RETURN NIL;" if statements.empty?

      prefix = statements[0...-1].map { |stmt| visit(stmt) }.reject(&:empty?).map { |code| statement_code(code) }
      prefix << render_lambda_returning_statement(statements.last)
      prefix.join("\n")
    end

    def render_lambda_returning_if_node(node)
      pred = visit(node.predicate)
      body = indent_lambda_line(render_lambda_returning_statements(node.statements))
      consequent = render_lambda_returning_consequent(node.consequent)
      "IF #{pred} THEN\n#{body}#{consequent}\nEND"
    end

    def render_lambda_returning_consequent(consequent)
      return "" unless consequent

      if consequent.is_a?(Prism::IfNode)
        pred = visit(consequent.predicate)
        body = indent_lambda_line(render_lambda_returning_statements(consequent.statements))
        nested = render_lambda_returning_consequent(consequent.consequent)
        return "\nELSE_IF #{pred} THEN\n#{body}#{nested}"
      end

      body = indent_lambda_line(render_lambda_returning_statements(consequent.statements))
      "\nELSE\n#{body}"
    end

    def block_to_lambda(block_node)
      if block_node.is_a?(Prism::BlockArgumentNode)
        return visit(block_node.expression)
      end

      unless block_node.is_a?(Prism::BlockNode) || block_node.is_a?(Prism::LambdaNode)
        return raise_unsupported("Unsupported block type #{block_node.class.name}", block_node)
      end

      params = block_lambda_parameters(block_node)
      return params if unsupported_output?(params)

      body = with_lambda_scope(params.scope_names) { render_lambda_body(block_node, setup_lines: params.setup_lines) }
      "%(#{params.parameter_names.join(', ')}) -> #{body}"
    end

    def render_ruby_loop(node)
      block_node = node.block
      unless block_node.is_a?(Prism::BlockNode)
        return unsupported_expression(node, "Ruby loop requires a literal block")
      end

      params = block_lambda_parameters(block_node)
      return params if unsupported_output?(params)
      unless params.parameter_names.empty?
        return unsupported_expression(node, "Ruby loop block parameters are not supported")
      end

      body = with_indent { visit(block_node.body) }
      "WHILE TRUE DO\n#{body}\nEND"
    end

    def check_arguments!(arguments_node)
      return unless arguments_node
      arguments_node.arguments.each do |arg|
        if arg.is_a?(Prism::KeywordHashNode)
          res = raise_unsupported("Keyword arguments are not supported", arg)
          return res if res.is_a?(String) && res.include?("# [UNSUPPORTED:")
        end
      end
      nil
    end

    def check_parameters!(parameters_node)
      return unless parameters_node
      if parameters_node.keyword_rest
        return raise_unsupported("Keyword rest parameters are not supported", parameters_node.keyword_rest)
      end
      nil
    end

    def collect_written_variables(node, parameter_names = Set.new, exclude_defs: false)
      written = Set.new
      walk = ->(n) do
        return unless n
        if exclude_defs && n.is_a?(Prism::DefNode)
          return
        end
        return if n.is_a?(Prism::BlockNode)

        if n.respond_to?(:name) && n.class.name.start_with?("Prism::LocalVariable") && 
           (n.class.name.end_with?("WriteNode") || n.class.name.end_with?("TargetNode"))
          written << n.name.to_s
        end
        n.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
      written
    end

    def extract_parameter_names(def_node)
      names = Set.new
      return names unless def_node.parameters
      
      params = def_node.parameters
      params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      names << params.rest.name.to_s if params.rest && params.rest.respond_to?(:name)
      params.posts.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      params.keywords.each { |p| names << p.name.to_s if p.respond_to?(:name) }
      names << params.keyword_rest.name.to_s if params.keyword_rest && params.keyword_rest.respond_to?(:name)
      names << params.block.name.to_s if params.block && params.block.respond_to?(:name)
      
      names
    end

    def type_predicate_argument(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "is_a?"

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1

      static_type_name(args.first)
    end

    def parameter_type_predicate_receiver(node, param_names)
      return nil unless type_predicate_argument(node)
      receiver = node.receiver
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

      name = receiver.name.to_s
      param_names.include?(name) ? name : nil
    end

    def exact_clear_type_match?(declared_type, expected_type)
      return false unless declared_type && declared_type != "Auto" && declared_type != "Any"

      declared_type.to_s == expected_type.to_s
    end

    def runtime_union_narrowing_candidate?(declared_type, expected_type)
      declared = declared_type.to_s
      expected = expected_type.to_s
      return false if declared.empty? || expected.empty?
      return false if declared.start_with?("?")

      members = @union_types[declared]
      if members
        expected_names = runtime_union_target_names(expected)
        return members.any? do |member|
          member_names = runtime_union_target_names(member)
          !(member_names & expected_names).empty?
        end
      end

      return true if declared == "Node" && !expected.end_with?(".Node")
      return false unless declared.end_with?(".Node")

      namespace = declared.delete_suffix(".Node")
      expected.start_with?("#{namespace}.")
    end

    def runtime_union_target_names(type)
      text = clear_type_expr(type).to_s
      [text, text.split(".").last].compact.uniq
    end

    def infer_function_type_bindings(body_node, param_names, param_types)
      candidates = []
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)
        return if node.is_a?(Prism::DefNode)
        return if node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

        if (param_name = parameter_type_predicate_receiver(node, param_names))
          expected_type = clear_type_expr(type_predicate_argument(node))
          declared_type = param_types[param_name]
          unless exact_clear_type_match?(declared_type, expected_type) ||
                 runtime_union_narrowing_candidate?(declared_type, expected_type)
            candidates << param_name
          end
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(body_node)

      names = candidates.uniq
      names.each_with_index.to_h do |param_name, index|
        [param_name, function_type_param_name(param_name, index, names.length)]
      end
    end

    def function_type_param_name(param_name, index, total)
      return "T" if total == 1

      suffix = param_name.split(/[^A-Za-z0-9]+/).reject(&:empty?).map { |part| part[0].upcase + part[1..].to_s }.join
      suffix = (index + 1).to_s if suffix.empty?
      "T#{suffix}"
    end

    def current_type_param_for_receiver(receiver_name)
      @current_function_type_bindings[receiver_name.to_s]
    end

    def static_clear_type_for_receiver(receiver_name)
      return nil unless receiver_name

      name = receiver_name.to_s
      (@local_types && @local_types[name]) || (@param_types && @param_types[name])
    end

    public :current_type_param_for_receiver, :runtime_union_narrowing_candidate?, :static_clear_type_for_receiver

    def sorbet_call?(node, name = nil)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver&.location&.slice == "T"

      name.nil? || node.name.to_s == name.to_s
    end

    def sorbet_unwrapped_value(node)
      return nil unless sorbet_call?(node)

      case node.name.to_s
      when "let", "cast", "must", "unsafe"
        node.arguments&.arguments&.first
      end
    end

    def sorbet_typed_value(node)
      return nil unless sorbet_call?(node)
      return nil unless ["let", "cast"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2

      [args.first, convert_sorbet_type(args[1])]
    end

    def inferred_shape(node)
      return nil unless node

      if (typed_value = sorbet_typed_value(node))
        return inferred_shape(typed_value.first)
      end

      if (unwrapped = sorbet_unwrapped_value(node))
        return inferred_shape(unwrapped)
      end

      case node
      when Prism::ArrayNode
        "array"
      when Prism::HashNode, Prism::KeywordHashNode
        "hash"
      when Prism::StringNode, Prism::InterpolatedStringNode
        "string"
      when Prism::SymbolNode
        "symbol"
      when Prism::IntegerNode, Prism::FloatNode
        "numeric"
      when Prism::NilNode
        "nil"
      when Prism::TrueNode, Prism::FalseNode
        "bool"
      when Prism::LocalVariableReadNode
        @local_shapes[node.name.to_s]
      when Prism::CallNode
        inferred_call_shape(node)
      end
    end

    def inferred_call_shape(node)
      receiver_name = registry_receiver_name(node.receiver)
      receiver_shape = node.receiver ? registry_receiver_shape(node.receiver) : nil

      case node.name.to_s
      when "readlines"
        return "array" if receiver_name == "File"
      when "split", "lines"
        return "array" if receiver_shape == "string"
      when "keys", "values"
        return "array" if receiver_shape == "hash"
      when "map", "collect", "select", "filter", "reject", "filter_map", "flat_map", "sort_by"
        return "array" if receiver_shape == "array"
      end

      nil
    end

    def sorbet_type_alias_value(node, alias_name: nil)
      return nil unless sorbet_call?(node, "type_alias")
      return nil unless node.block&.body.is_a?(Prism::StatementsNode)

      body = node.block.body.body
      return nil unless body.length == 1
      if alias_name.to_s == "Node" && body.first.is_a?(Prism::ConstantReadNode) && body.first.name.to_s == "Locatable"
        return ensure_ast_node_union!(emit: false) || "Node"
      end

      convert_sorbet_type(body.first, union_name: alias_name, emit_union: false)
    end

    def inferred_clear_type(node)
      return nil unless node

      if (typed_value = sorbet_typed_value(node))
        return typed_value[1] unless typed_value[1] == "Auto"

        return inferred_clear_type(typed_value.first)
      end

      if (unwrapped = sorbet_unwrapped_value(node))
        return inferred_clear_type(unwrapped)
      end

      case node
      when Prism::LocalVariableReadNode
        static_clear_type_for_receiver(node.name.to_s)
      when Prism::CallNode
        if constant_constructor_call?(node)
          name = constructor_output_name(node.receiver)
          return name if name && !name.empty?
        end

        receiver = node.receiver
        if receiver.nil? || receiver.is_a?(Prism::SelfNode)
          @method_return_types[node.name.to_s]
        end
      when Prism::ArrayNode
        "Any[]"
      when Prism::HashNode, Prism::KeywordHashNode
        "HashMap<Any, Any>"
      when Prism::StringNode, Prism::InterpolatedStringNode
        "String"
      when Prism::SymbolNode
        "String@symbol"
      when Prism::IntegerNode
        "Int64"
      when Prism::FloatNode
        "Float64"
      when Prism::TrueNode, Prism::FalseNode
        "Bool"
      when Prism::NilNode
        "Void"
      end
    end

    def t_struct_class?(node)
      node.superclass&.location&.slice == "T::Struct"
    end

    def t_struct_field(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.receiver.nil?
      return nil unless ["const", "prop"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2
      return nil unless args.first.is_a?(Prism::SymbolNode)

      [args.first.value.to_s, convert_sorbet_type(args[1])]
    end

    def concrete_struct_type(type)
      type.to_s.gsub(/\bAuto\b/, "Any")
    end

    def inferred_field_type_from_value(node)
      if (typed_value = sorbet_typed_value(node))
        return concrete_struct_type(typed_value[1])
      end

      if (unwrapped = sorbet_unwrapped_value(node))
        return inferred_field_type_from_value(unwrapped)
      end

      case node
      when Prism::StringNode, Prism::InterpolatedStringNode
        "String"
      when Prism::IntegerNode
        "Int64"
      when Prism::FloatNode
        "Float64"
      when Prism::TrueNode, Prism::FalseNode
        "Bool"
      when Prism::ArrayNode
        "Any[]"
      when Prism::HashNode, Prism::KeywordHashNode
        "HashMap<Any, Any>"
      when Prism::CallNode
        if constant_constructor_call?(node)
          name = constructor_output_name(node.receiver)
          return name if name && !name.empty?
        end
      end

      "Any"
    end

    def dynamic_ruby_call_reason(name)
      DYNAMIC_RUBY_CALLS[name.to_s]
    end

    def keyword_hash_argument(arguments_node)
      return nil unless arguments_node

      arguments_node.arguments.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
    end

    def constant_constructor_call?(node)
      node.name.to_s == "new" &&
        (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode))
    end

    def constructor_field_names(receiver)
      names = []
      names << receiver.location.slice.strip if receiver
      names << receiver.location.slice.strip.split("::").last if receiver.is_a?(Prism::ConstantPathNode)
      names << receiver.name.to_s if receiver.respond_to?(:name)

      names.uniq.each do |name|
        return @struct_fields[name] if @struct_fields[name]
      end

      nil
    end

    def preload_required_metadata(program_node)
      return unless @source_path
      return unless program_node.respond_to?(:statements)

      require_relative_paths(program_node.statements).each do |relative|
        path = File.expand_path(relative.end_with?(".rb") ? relative : "#{relative}.rb", File.dirname(@source_path))
        collect_metadata_from_file(path)
      end
    end

    def require_relative_paths(statements_node)
      return [] unless statements_node

      paths = []
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name.to_s == "require_relative"
          arg = node.arguments&.arguments&.first
          paths << arg.content if arg.is_a?(Prism::StringNode)
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(statements_node)
      paths
    end

    def collect_metadata_from_file(path)
      return if @loaded_metadata_files.include?(path)
      return unless File.file?(path)

      @loaded_metadata_files << path
      result = Prism.parse_file(path)
      return if result.failure?

      require_relative_paths(result.value.statements).each do |relative|
        nested = File.expand_path(relative.end_with?(".rb") ? relative : "#{relative}.rb", File.dirname(path))
        collect_metadata_from_file(nested)
      end
      collect_struct_fields_from_node(result.value)
      collect_type_aliases_from_node(result.value)
      collect_ast_node_variants_from_node(result.value)
      collect_method_signature_metadata_from_node(result.value)
      collect_method_params_from_node(result.value)
    rescue StandardError
      nil
    end

    def collect_type_aliases_from_node(node)
      return unless node

      if node.is_a?(Prism::ConstantWriteNode)
        if (type_alias = sorbet_type_alias_value(node.value, alias_name: node.name.to_s))
          @type_aliases[node.name.to_s] ||= type_alias
        end
      end

      node.child_nodes.each { |child| collect_type_aliases_from_node(child) if child }
    end

    def collect_ast_node_variants_from_node(node, namespace = [])
      return unless node

      case node
      when Prism::ModuleNode
        name = node.constant_path.location.slice.strip.split("::").last
        collect_ast_node_variants_from_node(node.body, namespace + [name])
        return
      when Prism::ClassNode
        name = node.constant_path.location.slice.strip.split("::").last
        register_ast_node_variant(name) if namespace.last == "AST" && class_includes_locatable?(node)
      when Prism::ConstantWriteNode
        register_ast_node_variant(node.name.to_s) if namespace.last == "AST" && struct_value_includes_locatable?(node.value)
      end

      node.child_nodes.each { |child| collect_ast_node_variants_from_node(child, namespace) if child }
    end

    def register_ast_node_variant(name)
      return if name.to_s.empty? || name.to_s == "Node"

      members = (@union_types["Node"] ||= [])
      members << name.to_s unless members.include?(name.to_s)
    end

    def class_includes_locatable?(node)
      body = node.body
      return false unless body.respond_to?(:body)

      body.body.any? { |stmt| include_locatable_call?(stmt) }
    end

    def struct_value_includes_locatable?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless struct_new_field_names(node)

      body = node.block&.body
      return false unless body.respond_to?(:body)

      body.body.any? { |stmt| include_locatable_call?(stmt) }
    end

    def include_locatable_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver.nil? && node.name.to_s == "include"

      arg = node.arguments&.arguments&.first
      case arg
      when Prism::ConstantReadNode
        arg.name.to_s == "Locatable"
      when Prism::ConstantPathNode
        arg.location.slice.strip == "AST::Locatable"
      else
        false
      end
    end

    def collect_method_signature_metadata_from_node(node, current_class = nil)
      return unless node

      if node.is_a?(Prism::ClassNode)
        class_name = node.constant_path.location.slice.strip.split("::").last
        collect_method_signature_metadata_from_node(node.body, class_name)
        return
      end

      if node.is_a?(Prism::StatementsNode)
        last_sig = nil
        node.body.each do |stmt|
          if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
            last_sig = stmt
            next
          end

          if stmt.is_a?(Prism::DefNode) && last_sig
            _params, return_type = parse_sig(last_sig)
            @method_return_types[stmt.name.to_s] ||= return_type unless return_type == "Auto"
          end
          last_sig = nil unless stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"

          collect_method_signature_metadata_from_node(stmt, current_class)
        end
        return
      end

      node.child_nodes.each { |child| collect_method_signature_metadata_from_node(child, current_class) if child }
    end

    def collect_method_params_from_node(node, current_class = nil)
      return unless node

      if node.is_a?(Prism::ClassNode)
        class_name = node.constant_path.location.slice.strip.split("::").last
        node.child_nodes.each { |child| collect_method_params_from_node(child, class_name) if child }
        return
      end

      if node.is_a?(Prism::DefNode)
        params = method_parameter_info(node.parameters)
        if current_class && node.name.to_s == "initialize"
          @constructor_params[current_class] ||= params if params.any?
        else
          @method_params[node.name.to_s] ||= params if params.any?
        end
      end

      node.child_nodes.each { |child| collect_method_params_from_node(child, current_class) if child }
    end

    def method_parameter_info(parameters_node)
      return [] unless parameters_node

      infos = []
      parameters_node.requireds.each do |param|
        infos << { name: param.name.to_s, default: nil } if param.respond_to?(:name)
      end
      parameters_node.optionals.each do |param|
        infos << { name: param.name.to_s, default: param.value } if param.respond_to?(:name)
      end
      parameters_node.keywords.each do |param|
        infos << { name: param.name.to_s, default: param.respond_to?(:value) ? param.value : nil } if param.respond_to?(:name)
      end
      infos
    end

    def collect_struct_fields_from_node(node, namespace = [])
      return unless node

      case node
      when Prism::ModuleNode
        collect_struct_fields_from_node(node.body, namespace + [node.constant_path.location.slice.strip.split("::").last])
        return
      when Prism::ClassNode
        name = node.constant_path.location.slice.strip.split("::").last
        if t_struct_class?(node)
          body_nodes = node.body&.body || []
          fields = body_nodes.filter_map { |stmt| t_struct_field(stmt)&.first }
          register_constructor_fields(namespace, name, fields) if fields.any?
        end
      when Prism::ConstantWriteNode
        if (fields = struct_new_field_names(node.value))
          register_constructor_fields(namespace, node.name.to_s, fields)
        end
      end

      node.child_nodes.each { |child| collect_struct_fields_from_node(child, namespace) if child }
    end

    def register_constructor_fields(namespace, name, fields)
      @struct_fields[name] ||= fields
      @struct_fields[(namespace + [name]).join("::")] ||= fields if namespace.any?
    end

    def struct_new_field_names(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "new"
      receiver = node.receiver
      return nil unless receiver.nil? || receiver.location.slice.strip == "Struct"

      args = node.arguments ? node.arguments.arguments : []
      fields = args.take_while { |arg| arg.is_a?(Prism::SymbolNode) }.map { |arg| arg.value.to_s }
      fields.empty? ? nil : fields
    end

    def constructor_output_name(receiver)
      receiver.location.slice.strip.split("::").last
    end

    def keyword_constructor_pairs(keyword_hash)
      keyword_hash.elements.map do |assoc|
        unless assoc.is_a?(Prism::AssocNode)
          return raise_unsupported("Constructor keyword splats are not supported", keyword_hash)
        end

        key = if assoc.key.is_a?(Prism::SymbolNode)
          assoc.key.value.to_s
        elsif assoc.key.is_a?(Prism::StringNode)
          assoc.key.content
        else
          return raise_unsupported("Constructor keyword names must be static", assoc.key)
        end

        "#{key}: #{visit(assoc.value)}"
      end
    end

    def constructor_from_arguments(receiver, arguments_node)
      fields = constructor_field_names(receiver)
      return nil unless fields

      class_name = constructor_output_name(receiver)
      args = arguments_node ? arguments_node.arguments : []
      keyword_hash = args.last if args.last.is_a?(Prism::KeywordHashNode)
      positional_args = keyword_hash ? args[0...-1] : args

      assoc_pairs = []
      positional_args.each_with_index do |arg, idx|
        field_name = fields[idx] || "field_#{idx}"
        assoc_pairs << "#{field_name}: #{visit(arg)}"
      end

      if keyword_hash
        keyword_pairs = keyword_constructor_pairs(keyword_hash)
        return keyword_pairs if keyword_pairs.is_a?(String) && keyword_pairs.include?("# [UNSUPPORTED:")

        assoc_pairs.concat(keyword_pairs)
      end

      "#{class_name}{ #{assoc_pairs.join(', ')} }"
    end

    def constructor_call_from_keywords(receiver, arguments_node)
      class_name = constructor_output_name(receiver)
      param_infos = @constructor_params[class_name]
      return nil unless param_infos

      args = arguments_from_keywords(param_infos, arguments_node)
      return nil unless args && args.none?(&:nil?)

      "#{visit(receiver)}.new(#{args.join(', ')})"
    end

    def constructor_call_from_positional(receiver, arguments_node)
      class_name = constructor_output_name(receiver)
      return nil unless @constructor_params[class_name]

      args = arguments_node ? arguments_node.arguments.map { |arg| visit(arg) } : []
      "#{visit(receiver)}.new(#{args.join(', ')})"
    end

    def call_arguments_from_keywords(method_name, arguments_node)
      param_infos = @method_params[method_name.to_s]
      return nil unless param_infos

      arguments_from_keywords(param_infos, arguments_node)
    end

    def arguments_from_keywords(param_infos, arguments_node)
      args = arguments_node ? arguments_node.arguments : []
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      return args.map { |arg| visit(arg) } unless keyword_hash

      positional = args.reject { |arg| arg.equal?(keyword_hash) }
      rendered = positional.map { |arg| visit(arg) }
      max_index = rendered.length - 1

      keyword_hash.elements.each do |assoc|
        return nil unless assoc.is_a?(Prism::AssocNode)

        key = keyword_call_key(assoc.key)
        return nil unless key

        index = param_infos.index { |info| info[:name] == key }
        return nil unless index
        return nil if index < positional.length

        max_index = [max_index, index].max
        rendered[index] = visit(assoc.value)
      end

      (0..max_index).map do |idx|
        rendered[idx] || default_argument_for(param_infos[idx])
      end
    end

    def arguments_with_keyword_hash(arguments_node)
      args = arguments_node ? arguments_node.arguments : []
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      return args.map { |arg| visit(arg) } unless keyword_hash

      positional = args.reject { |arg| arg.equal?(keyword_hash) }.map { |arg| visit(arg) }
      positional + [visit(keyword_hash)]
    end

    def keyword_call_key(node)
      case node
      when Prism::SymbolNode
        node.value.to_s
      when Prism::StringNode
        node.content
      end
    end

    def default_argument_for(param_info)
      return nil unless param_info
      return visit(param_info[:default]) if param_info[:default]

      nil
    end

    # --- Node Visitors ---

    def visit_program_node(node)
      visit(node.statements)
    end


    def visit_statements_node(node)
      visit_statement_list(node.body)
    end

    def visit_statement_list(statements)
      last_sig = nil
      rendered = []
      index = 0
      while index < statements.length
        stmt = statements[index]
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          index += 1
          next
        end

        if stmt.is_a?(Prism::DefNode)
          @current_sig = last_sig
          last_sig = nil
        else
          last_sig = nil
        end

        if (guard = runtime_is_a_exit_guard(stmt)) && index < statements.length - 1
          code = render_runtime_is_a_guard(guard, statements[(index + 1)..])
          @current_sig = nil
          rendered << format_statement_code(code) unless code.empty?
          break
        end

        code = visit(stmt)
        if @inside_function && @current_function_returns_value && index == statements.length - 1 && ternary_if_node?(stmt)
          code = "RETURN #{code}"
        end
        @current_sig = nil
        rendered << format_statement_code(code) unless code.empty?

        index += 1
      end
      rendered.join("\n")
    end

    def runtime_is_a_exit_guard(stmt)
      return nil unless stmt.is_a?(Prism::UnlessNode)
      return nil if stmt.consequent

      runtime_is_a = runtime_is_a_predicate(stmt.predicate)
      return nil unless runtime_is_a

      body = stmt.statements&.body || []
      return nil unless body.length == 1
      return nil unless guard_exit_statement?(body.first)

      runtime_is_a.merge(exit_statement: body.first)
    end

    def guard_exit_statement?(stmt)
      stmt.is_a?(Prism::ReturnNode) || stmt.is_a?(Prism::BreakNode) || stmt.is_a?(Prism::NextNode)
    end

    def render_runtime_is_a_guard(guard, rest_statements)
      pred = "#{guard[:receiver_code]} IS_A #{guard[:expected_type]} AS #{guard[:binding_name]}"
      then_body = with_indent do
        with_narrowing_context(guard) do
          visit_statement_list(rest_statements)
        end
      end
      else_body = with_indent { format_statement_code(visit(guard[:exit_statement])) }
      "IF #{pred} THEN\n#{then_body}\nELSE\n#{else_body}\nEND"
    end

    def with_narrowing_context(runtime_is_a)
      binding_name = runtime_is_a[:binding_name]
      old_types = @local_types.dup
      @local_types[binding_name] = runtime_is_a[:expected_type]
      with_renames(runtime_is_a[:renames]) { yield }
    ensure
      @local_types = old_types
    end

    def visit_else_node(node)
      visit(node.statements)
    end

    def visit_integer_node(node)
      node.value.to_s
    end

    def visit_float_node(node)
      node.value.to_s
    end

    def visit_string_node(node)
      clear_string_literal(node.content)
    end

    def visit_symbol_node(node)
      value = node.value.to_s
      if value.match?(/\A[A-Za-z]\w*[!?]?\z/) && !CLEAR_KEYWORDS.include?(value)
        return ":#{value}"
      end

      "symbol(#{value.inspect})"
    end

    def static_send_method_name(node)
      name = case node
             when Prism::SymbolNode
               node.value.to_s
             when Prism::StringNode
               node.content
             end
      return nil unless name&.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
      return nil if CLEAR_KEYWORDS.include?(name)

      name
    end

    def visit_local_variable_read_node(node)
      name = node.name.to_s
      @renames[name] || name
    end

    def visit_self_node(node)
      "self"
    end

    def visit_local_variable_target_node(node)
      name = node.name.to_s
      @renames[name] || name
    end

    def visit_block_parameters_node(node)
      visit(node.parameters)
    end

    def visit_instance_variable_read_node(node)
      if @singleton_class_depth.positive? || (@current_class && !@inside_function)
        return node.name.to_s.delete_prefix("@")
      end

      "self.#{node.name.to_s.delete_prefix('@')}"
    end

    def visit_class_variable_read_node(node)
      class_variable_name(node.name)
    end

    def visit_class_variable_write_node(node)
      name = class_variable_name(node.name)
      val = visit(node.value)
      if @class_variables.include?(name) || @inside_function
        "#{name} = #{val}"
      else
        @class_variables << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_constant_read_node(node)
      name = node.name.to_s
      @constant_names[name] || name
    end

    def visit_constant_path_node(node)
      node.location.slice.gsub("::", ".")
    end

    def visit_arguments_node(node)
      node.arguments.map { |arg| visit(arg) }.join(", ")
    end

    def visit_local_variable_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      value_node = node.value
      type_annotation = nil
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
      end

      if value_node.is_a?(Prism::IfNode) && !if_expression_code(value_node)
        return visit_local_variable_if_assignment(name, value_node, type_annotation)
      end

      val = if value_node.is_a?(Prism::IfNode)
        visit_if_expression_or_placeholder(value_node)
      elsif value_node.is_a?(Prism::CaseNode)
        visit_case_expression_or_placeholder(value_node)
      else
        visit(value_node)
      end
      shape = inferred_shape(value_node)
      inferred_type = type_annotation || inferred_clear_type(value_node)
      if @declared_locals.include?(name)
        @local_shapes[name] = shape
        @local_types[name] = inferred_type if inferred_type && inferred_type != "Auto"
        "#{name} = #{val}"
      else
        @declared_locals << name
        @local_shapes[name] = shape
        @local_types[name] = inferred_type if inferred_type && inferred_type != "Auto"
        typed = type_annotation && type_annotation != "Auto" ? ": #{type_annotation}" : ""
        "MUTABLE #{name}#{typed} = #{val}"
      end
    end

    def visit_local_variable_if_assignment(name, if_node, type_annotation)
      shape = inferred_shape(if_node)
      prefix = ""
      unless @declared_locals.include?(name)
        @declared_locals << name
        @local_shapes[name] = shape
        @local_types[name] = type_annotation if type_annotation && type_annotation != "Auto"
        typed = type_annotation && type_annotation != "Auto" ? ": #{type_annotation}" : ""
        prefix = "MUTABLE #{name}#{typed} = NIL;\n"
      end

      @local_shapes[name] = shape
      @local_types[name] = type_annotation if type_annotation && type_annotation != "Auto"
      "#{prefix}#{if_assignment_code(name, if_node)}"
    end

    def visit_local_variable_operator_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      op = node.operator.to_s.delete_suffix("=")
      val = visit(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} #{op} #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_instance_variable_operator_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      op = node.operator.to_s.delete_suffix("=")
      val = visit(node.value)
      "self.#{name} = (self.#{name} #{op} #{val})"
    end

    def visit_local_variable_or_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      val = visit(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} || #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_local_variable_and_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      val = visit(node.value)
      if @declared_locals.include?(name)
        "#{name} = (#{name} && #{val})"
      else
        @declared_locals << name
        "MUTABLE #{name} = #{val}"
      end
    end

    def visit_instance_variable_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      val = visit(node.value)
      if @singleton_class_depth.positive?
        return "#{name} = #{val}" if @declared_locals.include?(name) || @class_variables.include?(name)

        @class_variables << name
        return "MUTABLE #{name} = #{val}"
      end
      if @current_class && !@inside_function
        @class_variables << name
        return "MUTABLE #{name} = #{val}"
      end

      "self.#{name} = #{val}"
    end

    def visit_constant_write_node(node)
      name = node.name.to_s

      if (type_alias = sorbet_type_alias_value(node.value, alias_name: name))
        @type_aliases[name] = type_alias
        return union_definition(type_alias, @union_types[type_alias]) if @union_types.key?(type_alias)

        return ""
      end

      if node.value.is_a?(Prism::CallNode) &&
         (node.value.receiver.nil? || (node.value.receiver.is_a?(Prism::ConstantReadNode) && node.value.receiver.name == :Struct)) &&
         node.value.name == :new

        fields = []
        if node.value.arguments
          node.value.arguments.arguments.each do |arg|
            fields << arg.value.to_s if arg.is_a?(Prism::SymbolNode)
          end
        end
        @struct_fields[name] = fields

        field_decls = fields.map { |f| "  #{f}: Any" }.join(",\n")
        return "STRUCT #{name} {\n#{field_decls}\n}"
      end

      clear_name = constant_variable_name(name)
      @constant_names[name] = clear_name
      "MUTABLE #{clear_name} = #{visit(node.value)}"
    end

    def visit_range_node(node)
      left = node.left ? visit(node.left) : ""
      right = node.right ? visit(node.right) : ""
      op = node.exclude_end? ? "..<" : "..="
      "#{left} #{op} #{right}"
    end

    def visit_required_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      "#{prefix}#{node.name}: #{type}"
    end

    def visit_parameters_node(node)
      requireds = node.requireds.map { |param| visit(param) }
      optionals = node.optionals.map { |param| visit(param) }
      keywords = node.keywords.map { |param| visit(param) }
      block = node.block ? [visit(node.block)] : []
      (requireds + optionals + keywords + block).join(", ")
    end

    def visit_optional_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      return "#{prefix}#{node.name}: #{type}" unless parameter_default_supported?(node.value)

      default_val = visit(node.value)
      "#{prefix}#{node.name} = #{default_val}: #{type}"
    end

    def visit_required_keyword_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      "#{prefix}#{node.name}: #{type}"
    end

    def visit_optional_keyword_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      return "#{prefix}#{node.name}: #{type}" unless parameter_default_supported?(node.value)

      default_val = visit(node.value)
      "#{prefix}#{node.name} = #{default_val}: #{type}"
    end

    def visit_block_parameter_node(node)
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      "#{node.name} = NIL: #{type}"
    end

    def visit_array_node(node)
      elements = node.elements.map { |el| visit(el) }.join(", ")
      "[#{elements}]"
    end

    def visit_splat_node(node)
      unsupported_expression(node, "Splat arguments require an explicit call shape or generated overload")
    end

    def visit_hash_node(node)
      elements = node.elements.map { |el| visit(el) }.join(", ")
      "{#{elements}}"
    end

    def visit_keyword_hash_node(node)
      elements = node.elements.map { |el| visit(el) }.join(", ")
      "{#{elements}}"
    end

    def visit_assoc_node(node)
      key = visit(node.key)
      key = node.key.value.to_s if node.key.is_a?(Prism::SymbolNode)
      val = visit(node.value)
      "#{key}: #{val}"
    end

    def visit_and_node(node)
      lhs = visit(node.left)
      rhs = visit(node.right)
      "(#{lhs} && #{rhs})"
    end

    def visit_or_node(node)
      lhs = visit(node.left)
      rhs = visit(node.right)
      "(#{lhs} || #{rhs})"
    end

    def visit_nil_node(node)
      "NIL"
    end

    def visit_false_node(node)
      "FALSE"
    end

    def visit_true_node(node)
      "TRUE"
    end

    def visit_parentheses_node(node)
      if node.body
        if node.body.is_a?(Prism::StatementsNode) && node.body.body.length == 1
          "(#{visit(node.body.body.first).delete_suffix(";")})"
        else
          "(#{visit(node.body).delete_suffix(";")})"
        end
      else
        "()"
      end
    end

    def visit_until_node(node)
      pred = visit(node.predicate)
      body = with_indent { visit(node.statements) }
      "WHILE !(#{pred}) DO\n#{body}\nEND"
    end

    def and_condition_nodes(node)
      if node.is_a?(Prism::AndNode)
        and_condition_nodes(node.left) + and_condition_nodes(node.right)
      else
        [node]
      end
    end

    def parenthesized_single_expression(node)
      return node unless node.is_a?(Prism::ParenthesesNode)
      return node unless node.body.is_a?(Prism::StatementsNode)
      return node unless node.body.body.length == 1

      node.body.body.first
    end

    def while_assignment_guard_lines(predicate)
      return nil unless contains_node_type?(predicate, Prism::LocalVariableWriteNode)

      lines = []
      and_condition_nodes(predicate).each do |condition|
        expression = parenthesized_single_expression(condition)
        if expression.is_a?(Prism::LocalVariableWriteNode)
          assignment = visit(expression).delete_suffix(";")
          name = expression.name.to_s
          lines << "#{assignment};"
          lines << "IF !(#{name}) THEN"
          lines << "  BREAK;"
          lines << "END"
        elsif contains_node_type?(expression, Prism::LocalVariableWriteNode)
          return nil
        else
          pred = visit(condition)
          lines << "IF !(#{pred}) THEN"
          lines << "  BREAK;"
          lines << "END"
        end
      end
      lines
    end

    def visit_while_node(node)
      if (guard_lines = while_assignment_guard_lines(node.predicate))
        body = with_indent do
          guard_code = guard_lines.map { |line| "#{indent}#{line}" }.join("\n")
          body_code = visit(node.statements)
          [guard_code, body_code].reject(&:empty?).join("\n")
        end
        return "WHILE TRUE DO\n#{body}\nEND"
      end

      pred = visit(node.predicate)
      body = with_indent { visit(node.statements) }
      "WHILE #{pred} DO\n#{body}\nEND"
    end

    def visit_return_node(node)
      if node.arguments
        "RETURN #{visit(node.arguments)}"
      else
        "RETURN"
      end
    end

    def visit_break_node(node)
      "BREAK"
    end

    def visit_next_node(node)
      "CONTINUE"
    end

    def visit_if_node(node)
      return "" if ruby_scaffolding_conditional?(node)
      return visit_ternary_if_node(node) if ternary_if_node?(node)

      predicate_prefix = ""
      pred_assignment = predicate_assignment_node(node.predicate)
      runtime_is_a = runtime_is_a_predicate(node.predicate)
      pred = if runtime_is_a
        "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
      elsif pred_assignment
        predicate_prefix = "#{visit(pred_assignment)};\n"
        @renames[pred_assignment.name.to_s] || pred_assignment.name.to_s
      else
        visit(node.predicate)
      end
      keyword = comptime_predicate?(pred) ? "COMPTIME IF" : "IF"
      body = with_indent do
        if runtime_is_a
          with_narrowing_context(runtime_is_a) { visit(node.statements) }
        else
          visit(node.statements)
        end
      end
      consequent_code = node.consequent ? format_consequent(node.consequent) : ""
      "#{predicate_prefix}#{keyword} #{pred} THEN\n#{body}#{consequent_code}\nEND"
    end

    def visit_unless_node(node)
      return "" if ruby_scaffolding_conditional?(node)

      pred = visit(node.predicate)
      keyword = comptime_predicate?(pred) ? "COMPTIME IF" : "IF"
      body = with_indent { visit(node.statements) }
      consequent_code = node.consequent ? format_consequent(node.consequent) : ""
      "#{keyword} !(#{pred}) THEN\n#{body}#{consequent_code}\nEND"
    end

    def comptime_predicate?(code)
      left = code.to_s.strip[/\A([A-Za-z_][A-Za-z0-9_]*)\s+IS_A\s+/, 1]
      return false unless left

      @current_function_type_bindings.value?(left)
    end

    def runtime_is_a_predicate(node)
      expected_raw = type_predicate_argument(node)
      return nil unless expected_raw

      receiver = node.receiver
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

      receiver_name = receiver.name.to_s
      expected_type = clear_type_expr(expected_raw)
      receiver_type = static_clear_type_for_receiver(receiver_name)
      return nil unless receiver_type && runtime_union_narrowing_candidate?(receiver_type, expected_type)

      binding_name = runtime_is_a_binding_name(expected_type, receiver_name)
      {
        receiver_name: receiver_name,
        receiver_code: visit(receiver),
        expected_type: expected_type,
        binding_name: binding_name,
        renames: { receiver_name => binding_name },
      }
    end

    def runtime_is_a_binding_name(expected_type, receiver_name)
      base = expected_type.to_s.split(".").last
      snake = base
        .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .downcase
      snake = "#{receiver_name}_as_#{snake}" if snake == receiver_name
      snake.empty? ? "#{receiver_name}_payload" : snake
    end

    def visit_case_node(node)
      if node.predicate.nil?
        first_when = node.conditions.first
        other_whens = node.conditions[1..-1] || []

        pred = visit(first_when.conditions.first)
        body = with_indent { visit(first_when.statements) }

        consequent_code = ""
        other_whens.each do |w|
          w_pred = visit(w.conditions.first)
          w_body = with_indent { visit(w.statements) }
          consequent_code += "\nELSE_IF #{w_pred} THEN\n#{w_body}"
        end

        if node.consequent
          else_body = with_indent { visit(node.consequent) }
          consequent_code += "\nELSE\n#{else_body}"
        end

        "IF #{pred} THEN\n#{body}#{consequent_code}\nEND"
      else
        target = visit(node.predicate)
        arms = []
        node.conditions.each do |w|
          w.conditions.each do |cond|
            cond_val = visit(cond)
            stmt_val = visit(w.statements)
            arms << "#{cond_val} -> #{stmt_val},"
          end
        end

        if node.consequent
          else_val = visit(node.consequent)
          arms << "DEFAULT -> #{else_val}"
        end

        arms_body = with_indent do
          arms.map { |arm| arm.split("\n").map { |l| "#{indent}#{l}" }.join("\n") }.join("\n")
        end

        "PARTIAL MATCH #{target} START\n#{arms_body}\nEND"
      end
    end

    def visit_regular_expression_node(node)
      clear_string_literal(node.unescaped)
    end

    def visit_interpolated_regular_expression_node(node)
      return unsupported_expression(node, "Regular expressions are not supported")
    end

    def visit_numbered_reference_read_node(node)
      "regexCapture(#{node.number})"
    end

    def visit_defined_node(node)
      return unsupported_expression(node, "defined? is not supported")
    end

    def visit_lambda_node(node)
      block_to_lambda(node)
    end

    def visit_interpolated_string_node(node)
      if node.parts.none? { |part| part.is_a?(Prism::EmbeddedStatementsNode) }
        return clear_string_literal(node.parts.map { |part| interpolated_string_part(part) }.join)
      end

      parts = node.parts.map { |part| interpolated_string_part_for_literal(part) }.join
      "\"#{parts}\""
    end

    def visit_embedded_statements_node(node)
      "${#{embedded_statement_expression(node)}}"
    end

    def interpolated_string_part(part)
      case part
      when Prism::StringNode
        part.content
      when Prism::EmbeddedStatementsNode
        "${#{embedded_statement_expression(part)}}"
      when Prism::InterpolatedStringNode
        part.parts.map { |nested_part| interpolated_string_part(nested_part) }.join
      else
        visit(part).delete_suffix(";")
      end
    end

    def interpolated_string_part_for_literal(part)
      case part
      when Prism::StringNode
        clear_string_escape(part.content)
      when Prism::EmbeddedStatementsNode
        "${#{embedded_statement_expression(part)}}"
      when Prism::InterpolatedStringNode
        part.parts.map { |nested_part| interpolated_string_part_for_literal(nested_part) }.join
      else
        clear_string_escape(visit(part).delete_suffix(";"))
      end
    end

    def embedded_statement_expression(node)
      statements = node.statements
      return "" unless statements

      unless statements.body.length == 1
        return raise_unsupported("String interpolation must contain a single expression", node)
      end

      visit(statements.body.first).delete_suffix(";")
    end

    def visit_call_node(node)
      keyword_arg = keyword_hash_argument(node.arguments)

      if (rspec_code = translate_rspec_call(node))
        return rspec_code
      end

      if ruby_scaffolding_call?(node)
        return ""
      end

      if %w[send __send__ public_send].include?(node.name.to_s)
        args = node.arguments ? node.arguments.arguments : []
        return unsupported_expression(node, "#{node.name} requires at least a method name") if args.empty?

        receiver = node.receiver ? visit(node.receiver) : "self"
        method_name = static_send_method_name(args.first)
        unless method_name
          return unsupported_expression(node, "#{node.name} requires a static symbol or string method name")
        end

        extra_args = args.drop(1).map { |arg| visit(arg) }
        return "#{receiver}.#{method_name}(#{extra_args.join(', ')})"
      end

      if (reason = dynamic_ruby_call_reason(node.name.to_s))
        return unsupported_expression(node, "#{node.name} is a Ruby dynamic/reflection call: #{reason}")
      end

      if sorbet_call?(node)
        return "" if node.name.to_s == "bind"

        if (unwrapped = sorbet_unwrapped_value(node))
          return visit(unwrapped)
        end
      end

      if node.name.to_s == "freeze" && node.receiver && (!node.arguments || node.arguments.arguments.empty?)
        return visit(node.receiver)
      end

      if node.receiver.nil? && node.name.to_s == "loop" && node.block
        return render_ruby_loop(node)
      end

      if node.receiver.nil? && node.name.to_s == "lambda" && node.block
        return block_to_lambda(node.block)
      end

      if node.name.to_s == "gsub" || node.name.to_s == "sub"
        if (unsupported_reason = unsupported_gsub_sub_reason(node))
          return unsupported_expression(node, unsupported_reason)
        end

        rec_code = node.receiver ? visit(node.receiver) : nil
        if rec_code
          translated = MethodRegistry.translate(
            node.name.to_s,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated && !MethodRegistry.unsupported_result?(translated)
        end
        return unsupported_expression(node, "gsub/sub with dynamic regex, block, or invalid arguments is not supported")
      end

      case node.name.to_s
      when "!"
        "!(#{visit(node.receiver)})"
      when "-@"
        "(-#{visit(node.receiver)})"
      when "+@"
        "(+#{visit(node.receiver)})"
      when "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "&&", "||", "&", "|"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "(#{lhs} #{node.name} #{rhs})"
      when "=~"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "regexMatch?(#{lhs}, #{rhs})"
      when "!~"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "!(regexMatch?(#{lhs}, #{rhs}))"
      when "<<"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "#{lhs}.append(#{rhs})"
      when "[]"
        if node.receiver
          lhs = visit(node.receiver)
          translated = MethodRegistry.translate(
            node.name.to_s,
            lhs,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated
        end
        lhs = visit(node.receiver)
        arg_nodes = node.arguments ? node.arguments.arguments : []
        if arg_nodes.length == 1 && arg_nodes.first.is_a?(Prism::RangeNode)
          range = arg_nodes.first
          start = range.left ? visit(range.left) : "0"
          if range.right
            finish = visit(range.right)
            length_expr = range.exclude_end? ? "(#{finish} - #{start})" : "((#{finish} - #{start}) + 1)"
            "#{lhs}.substr(#{start}, #{length_expr})"
          else
            "#{lhs}.substr(#{start}, (#{lhs}.length() - #{start}))"
          end
        elsif arg_nodes.length == 2
          start = visit(arg_nodes[0])
          length = visit(arg_nodes[1])
          "#{lhs}.substr(#{start}, #{length})"
        else
          args = visit(node.arguments)
          "#{lhs}[#{args}]"
        end
      when "[]="
        lhs = visit(node.receiver)
        index = visit(node.arguments.arguments.first)
        value = visit(node.arguments.arguments.last)
        "#{lhs}[#{index}] = #{value}"
      else
        if constant_constructor_call?(node)
          rec_code = visit(node.receiver)
          if keyword_arg
            constructor = constructor_from_arguments(node.receiver, node.arguments)
            return constructor if constructor

            constructor_call = constructor_call_from_keywords(node.receiver, node.arguments)
            return constructor_call if constructor_call

            return unsupported_expression(keyword_arg, "Keyword arguments are not supported for this constructor")
          end

          translated = MethodRegistry.translate(
            node.name.to_s,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated

          constructor = constructor_from_arguments(node.receiver, node.arguments)
          return constructor if constructor

          constructor_call = constructor_call_from_positional(node.receiver, node.arguments)
          return constructor_call if constructor_call

          return unsupported_expression(node, "Constructor call needs known field names")
        end

        rec_code = node.receiver ? visit(node.receiver) : nil
        name_str = node.name.to_s
        if rec_code && name_str.end_with?("=")
          args = node.arguments ? node.arguments.arguments : []
          return unsupported_expression(node, "Attribute writer calls must have exactly one argument") unless args.length == 1

          return "#{rec_code}.#{name_str.delete_suffix('=')} = #{visit(args.first)}"
        end

        args_list = if keyword_arg
          mapped = call_arguments_from_keywords(name_str, node.arguments)
          if mapped && mapped.none?(&:nil?)
            mapped
          else
            arguments_with_keyword_hash(node.arguments)
          end
        else
          node.arguments ? node.arguments.arguments.map { |arg| visit(arg) } : []
        end

        if rec_code
          translated = MethodRegistry.translate(
            name_str,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated
        else
          translated = MethodRegistry.translate(
            name_str,
            nil,
            node,
            self,
            receiver_kind: "implicit",
            receiver_name: nil,
            receiver_shape: nil
          )
          return translated if translated
        end

        if node.block
          args_list << block_to_lambda(node.block)
        end

        rec = rec_code ? "#{rec_code}." : ""
        args_str = args_list.join(", ")

        "#{rec}#{name_str}(#{args_str})"
      end
    end

    def visit_module_node(node)
      name = node.constant_path.location.slice.strip
      body_code = visit(node.body)

      if body_code.empty?
        "# Ruby module #{name}"
      else
        "# Ruby module #{name}\n#{body_code}\n# End Ruby module #{name}"
      end
    end

    def visit_singleton_class_node(node)
      old_class = @current_class
      @current_class = nil
      @singleton_class_depth += 1
      visit(node.body)
    ensure
      @singleton_class_depth -= 1
      @current_class = old_class
    end

    def visit_class_node(node)
      old_class = @current_class
      @current_class = node.constant_path.location.slice.strip

      if t_struct_class?(node)
        body_nodes = node.body&.body || []
        fields = body_nodes.filter_map { |stmt| t_struct_field(stmt) }
        if fields.length == body_nodes.length
          @struct_fields[@current_class] = fields.map(&:first)
          field_decls = fields.map { |field, type| "  #{field}: #{concrete_struct_type(type)}" }.join(",\n")
          @current_class = old_class
          return "STRUCT #{node.constant_path.location.slice.strip} {\n#{field_decls}\n}"
        end
      end

      instance_fields = collect_instance_fields(node)
      struct_fields = instance_fields.map { |name, type| "  #{name}: #{type}" }.join(",\n")
      struct_code = "STRUCT #{@current_class} {\n#{struct_fields}\n}"

      body_code = visit(node.body)

      @current_class = old_class

      "#{struct_code}\n\n#{body_code}"
    end

    def visit_def_node(node)
      chk = check_parameters!(node.parameters)
      return chk if chk.is_a?(String) && chk.include?("# [UNSUPPORTED:")
      
      name = node.name.to_s
      param_types, sig_return_type = parse_sig(@current_sig)
      param_names = extract_parameter_names(node)
      type_bindings = infer_function_type_bindings(node.body, param_names, param_types)
      param_types = param_types.merge(type_bindings)
      @param_types = param_types
      written_vars = collect_written_variables(node.body, param_names)
      written_params = param_names & written_vars
      
      @mutable_params = written_params
      
      params = []
      if @current_class && !node.receiver
        params << "MUTABLE self: #{@current_class}"
      end

      if node.parameters
        params_str = visit(node.parameters)
        params << params_str unless params_str.empty?
      end

      old_declared = @declared_locals
      old_function_can_fail = @current_function_can_fail
      old_local_shapes = @local_shapes
      old_local_types = @local_types
      old_inside_function = @inside_function
      old_function_returns_value = @current_function_returns_value
      old_function_type_bindings = @current_function_type_bindings
      @declared_locals = Set.new(param_names)
      @current_function_can_fail = false
      @local_shapes = {}
      @local_types = param_types.reject { |_param, type| type == "Auto" || type == "Any" }
      @inside_function = true
      @current_function_returns_value = name != "initialize" && sig_return_type != "Void"
      @current_function_type_bindings = type_bindings
      
      local_vars_to_declare = (written_vars - param_names).to_a.sort
      local_vars_to_declare.each { |var| @declared_locals << var }

      body_code = with_indent { visit(node.body) }
      
      decls_code = local_vars_to_declare.map do |var|
        "#{indent}  MUTABLE #{var} = NIL;"
      end.join("\n")

      full_body = if decls_code.empty?
        body_code
      elsif body_code.empty?
        decls_code
      else
        "#{decls_code}\n#{body_code}"
      end

      function_can_fail = @current_function_can_fail
      @declared_locals = old_declared
      @current_function_can_fail = old_function_can_fail
      @local_shapes = old_local_shapes
      @local_types = old_local_types
      @inside_function = old_inside_function
      @current_function_returns_value = old_function_returns_value
      @current_function_type_bindings = old_function_type_bindings
      @mutable_params = nil
      @param_types = nil

      ret_type = if name == "initialize"
        "Void"
      elsif sig_return_type != "Auto"
        sig_return_type
      else
        "Auto"
      end
      ret_type = fallible_return_type(ret_type) if function_can_fail
      sig_name = clear_function_name(name)
      type_params = type_bindings.values
      type_param_suffix = type_params.empty? ? "" : "<#{type_params.join(', ')}>"

      "FN #{sig_name}#{type_param_suffix}(#{params.join(', ')}) RETURNS #{ret_type} ->\n#{full_body}\nEND"
    end

    def fallible_return_type(ret_type)
      return ret_type if ret_type.start_with?("!")
      return ret_type if ret_type == "Auto"

      "!#{ret_type}"
    end

    def visit_block_argument_node(node)
      "&#{visit(node.expression)}"
    end

    def visit_multi_write_node(node)
      target_names = validated_multi_write_target_names(node)
      return target_names if target_names.is_a?(String)

      first_new_target = multi_write_first_new_target?(target_names)
      target_code = multi_write_target_codes(target_names, first_new_target)
      prefix = first_new_target ? "MUTABLE " : ""
      "#{prefix}#{target_code.join(', ')} = #{visit(node.value)}"
    end

    def validated_multi_write_target_names(node)
      if node.respond_to?(:rest) && node.rest
        return raise_unsupported("Destructuring rest targets are not supported", node)
      end

      if node.respond_to?(:rights) && node.rights.any?
        return raise_unsupported("Destructuring post targets are not supported", node)
      end

      if node.value.is_a?(Prism::ArrayNode) && node.value.elements.any? { |element| element.is_a?(Prism::SplatNode) }
        return raise_unsupported("Destructuring splat values are not supported", node)
      end

      if node.value.is_a?(Prism::ArrayNode) && node.lefts.length != node.value.elements.length
        return raise_unsupported("Multi-write left and right side lengths must match", node)
      end

      target_names = multi_write_target_names(node)
      unless target_names
        return raise_unsupported("Destructuring targets must be local variables or _", node)
      end

      target_names
    end

    def multi_write_target_codes(target_names, first_new_target)
      target_names.each_with_index.map do |name, index|
        multi_write_target_code(name, index, first_new_target)
      end
    end

    def multi_write_target_code(name, index, first_new_target)
      return "_" if name == "_"

      if @declared_locals.include?(name)
        name
      else
        @declared_locals << name
        @local_shapes[name] = nil
        index.zero? || first_new_target ? name : "MUTABLE #{name}"
      end
    end

    def multi_write_first_new_target?(target_names)
      target_names.first != "_" && !@declared_locals.include?(target_names.first)
    end

    def multi_write_target_names(node)
      target_names = node.lefts.map { |target| multi_write_target_name(target) }
      return nil if target_names.any?(&:nil?)

      target_names
    end

    def multi_write_target_name(target)
      return target.name.to_s if target.is_a?(Prism::LocalVariableTargetNode)

      nil
    end

    def visit_rescue_node(node)
      return raise_unsupported("Exception handling (rescue) is not supported", node)
    end

    def visit_rescue_modifier_node(node)
      if node.rescue_expression.is_a?(Prism::NilNode) && sorbet_call?(node.expression, "bind")
        return ""
      end

      return raise_unsupported("Exception handling (rescue) is not supported", node)
    end

    def visit_begin_node(node)
      if node.rescue_clause
        return raise_unsupported("Exception handling (rescue) is not supported", node)
      else
        visit(node.statements)
      end
    end

    def format_consequent(consequent_node)
      if consequent_node.is_a?(Prism::IfNode)
        pred = visit(consequent_node.predicate)
        body = with_indent { visit(consequent_node.statements) }
        nested = consequent_node.consequent ? format_consequent(consequent_node.consequent) : ""
        "\nELSE_IF #{pred} THEN\n#{body}#{nested}"
      else
        body = with_indent { visit(consequent_node) }
        "\nELSE\n#{body}"
      end
    end

    def collect_instance_fields(node)
      fields = {}
      walk = ->(n, in_instance_method = false) do
        next unless n

        if n.is_a?(Prism::SingletonClassNode)
          next
        elsif n.is_a?(Prism::DefNode)
          next if n.receiver

          n.child_nodes.each { |child| walk.call(child, true) if child }
          next
        elsif in_instance_method && n.is_a?(Prism::InstanceVariableReadNode)
          fields[n.name.to_s.delete_prefix("@")] ||= "Any"
        elsif in_instance_method && n.is_a?(Prism::InstanceVariableWriteNode)
          name = n.name.to_s.delete_prefix("@")
          inferred_type = inferred_field_type_from_value(n.value)
          fields[name] = inferred_type == "Any" ? fields.fetch(name, "Any") : inferred_type
        end
        n.child_nodes.each { |child| walk.call(child, in_instance_method) if child }
      end
      walk.call(node)
      fields.sort.to_h
    end

    def registry_receiver_kind(receiver)
      case receiver
      when nil then "implicit"
      when Prism::SelfNode then "self"
      when Prism::LocalVariableReadNode then "local"
      when Prism::InstanceVariableReadNode then "ivar"
      when Prism::ClassVariableReadNode then "class_var"
      when Prism::GlobalVariableReadNode then "global"
      when Prism::ConstantReadNode then "constant"
      when Prism::ConstantPathNode then "constant_path"
      when Prism::CallNode then "call_result"
      when Prism::ParenthesesNode then "parenthesized"
      when Prism::StringNode, Prism::InterpolatedStringNode then "string_literal"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "symbol_literal"
      when Prism::IntegerNode, Prism::FloatNode then "numeric_literal"
      when Prism::ArrayNode then "array_literal"
      when Prism::HashNode then "hash_literal"
      when Prism::NilNode then "nil_literal"
      when Prism::TrueNode, Prism::FalseNode then "bool_literal"
      else receiver.class.name.split("::").last
      end
    end

    def registry_receiver_name(receiver)
      return nil unless receiver

      if receiver.respond_to?(:full_name)
        receiver.full_name
      elsif receiver.respond_to?(:name)
        receiver.name.to_s
      end
    rescue StandardError
      nil
    end

    def registry_receiver_shape(receiver)
      return nil unless receiver

      case receiver
      when Prism::ArrayNode
        "array"
      when Prism::HashNode, Prism::KeywordHashNode
        "hash"
      when Prism::StringNode, Prism::InterpolatedStringNode
        "string"
      when Prism::SymbolNode
        "symbol"
      when Prism::IntegerNode, Prism::FloatNode
        "numeric"
      when Prism::NilNode
        "nil"
      when Prism::TrueNode, Prism::FalseNode
        "bool"
      when Prism::LocalVariableReadNode
        @local_shapes[receiver.name.to_s]
      else
        inferred_shape(receiver)
      end
    end

    def comment_unsupported(node)
      unsupported_comment(node)
    end

    def unsupported_comment(node, message = nil)
      node_name = node.class.name.split("::").last
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      slice = node.location.slice
      lines = slice.split("\n")
      header = "# [UNSUPPORTED: #{node_name} at #{source_loc}]"
      header = "#{header} #{message}" if message
      commented_lines = [header]
      lines.each do |line|
        commented_lines << "# #{line}"
      end
      commented_lines.map { |l| "#{indent}#{l}" }.join("\n")
    end

    def unsupported_expression(node, message)
      return raise_unsupported(message, node) if @raise_on_error

      node_name = node.class.name.split("::").last
      loc = node.location
      source_loc = "#{@source[0...loc.start_offset].count("\n") + 1}:#{loc.start_column}"
      encoded = "#{node_name} at #{source_loc}: #{message}".dump
      "unsupportedRuby(#{encoded})"
    end
    public :unsupported_expression

    def unsupported_gsub_sub_reason(node)
      args = node.arguments ? node.arguments.arguments : []
      if node.block || args.length != 2
        "#{node.name} with block or invalid arguments is not supported"
      end
    end

    def ruby_scaffolding_call?(node)
      return false unless node.is_a?(Prism::CallNode)

      name = node.name.to_s
      return true if node.receiver.nil? && ["require", "require_relative", "private", "public", "protected"].include?(name)

      if name == "extend" && node.receiver.nil?
        args = node.arguments ? node.arguments.arguments : []
        return true if args.length == 1 && args.first.location.slice.strip == "T::Sig"
      end

      false
    end

    def ruby_scaffolding_conditional?(node)
      return false unless node.respond_to?(:statements)
      return false if node.consequent

      statements = node.statements
      return false unless statements.is_a?(Prism::StatementsNode)
      return false if statements.body.empty?

      statements.body.all? { |stmt| ruby_scaffolding_call?(stmt) }
    end

    def block_statement_output?(code)
      stripped = code.lstrip
      return true if stripped.start_with?("IF ", "COMPTIME IF ", "WHILE ", "MATCH ", "PARTIAL MATCH ", "TEST ", "WHEN ")
      return true if stripped.start_with?("FN ", "STRUCT ", "UNION ", "ENUM ")
      return true if stripped.match?(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*\s*=.*;\nIF /m)

      false
    end

    def ternary_if_node?(node)
      node.respond_to?(:if_keyword_loc) && node.if_keyword_loc.nil? && node.consequent
    end

    def predicate_assignment_node(node)
      return node if node.is_a?(Prism::LocalVariableWriteNode)
      if node.is_a?(Prism::ParenthesesNode) &&
         node.body.is_a?(Prism::StatementsNode) &&
         node.body.body.length == 1 &&
         node.body.body.first.is_a?(Prism::LocalVariableWriteNode)
        return node.body.body.first
      end

      nil
    end

    def contains_node_type?(node, type)
      return false unless node.is_a?(Prism::Node)
      return true if node.is_a?(type)

      node.child_nodes.any? { |child| contains_node_type?(child, type) }
    end

    def visit_ternary_if_node(node)
      true_expr = single_expression_from_statements(node.statements)
      false_expr = single_expression_from_statements(node.consequent.statements)
      unless true_expr && false_expr
        return unsupported_expression(node, "Ternary branches must contain one expression")
      end

      pred = visit(node.predicate)
      "IF #{pred} THEN\n#{indent}  #{true_expr}\n#{indent}ELSE\n#{indent}  #{false_expr}\n#{indent}END"
    end

    def visit_if_expression_or_placeholder(node)
      code = if_expression_code(node)
      return code if code

      unsupported_expression(node, "If expression branches must contain one expression")
    end

    def visit_case_expression_or_placeholder(node)
      return unsupported_expression(node, "Case expressions without a target are not supported") if node.predicate.nil?

      target = visit(node.predicate)
      arms = []
      node.conditions.each do |w|
        w.conditions.each do |cond|
          cond_val = visit(cond)
          stmt_val = single_expression_from_statements(w.statements)
          return unsupported_expression(w, "Case expression arms must contain one expression") unless stmt_val

          arms << "#{cond_val} -> #{stmt_val},"
        end
      end

      if node.consequent
        else_val = single_expression_from_statements(node.consequent.statements)
        return unsupported_expression(node.consequent, "Case expression default must contain one expression") unless else_val

        arms << "DEFAULT -> #{else_val}"
      end

      arms_body = with_indent do
        arms.map { |arm| arm.split("\n").map { |l| "#{indent}#{l}" }.join("\n") }.join("\n")
      end

      "PARTIAL MATCH #{target} START\n#{arms_body}\n#{indent}END"
    end

    def if_expression_code(node)
      body = if_expression_branch_code(node, "IF")
      return nil unless body

      "#{body}\n#{indent}END"
    end

    def if_assignment_code(name, node)
      body = if_assignment_branch_code(name, node, "IF")
      "#{body}\n#{indent}END"
    end

    def if_assignment_branch_code(name, node, keyword)
      pred = visit(node.predicate)
      code = "#{indent}#{keyword} #{pred} THEN\n"
      code += with_indent { assignment_branch_statements(name, node.statements) }
      consequent = node.consequent

      if consequent.is_a?(Prism::IfNode)
        code += "\n#{if_assignment_branch_code(name, consequent, 'ELSE_IF')}"
      elsif consequent
        code += "\n#{indent}ELSE\n"
        code += with_indent { assignment_branch_statements(name, consequent.statements) }
      else
        code += "\n#{indent}ELSE\n#{indent}  #{name} = NIL;"
      end

      code
    end

    def assignment_branch_statements(name, statements)
      return "#{indent}#{name} = NIL;" unless statements.is_a?(Prism::StatementsNode) && statements.body.any?

      body = statements.body
      rendered = body[0...-1].map { |stmt| format_statement_code(visit(stmt)) }
      rendered << format_statement_code("#{name} = #{visit(body.last).delete_suffix(';')}")
      rendered.join("\n")
    end

    def if_expression_branch_code(node, keyword)
      true_expr = single_expression_from_statements(node.statements)
      return nil unless true_expr

      pred = visit(node.predicate)
      code = "#{indent}#{keyword} #{pred} THEN\n#{indent}  #{true_expr}"
      consequent = node.consequent

      if consequent.is_a?(Prism::IfNode)
        nested = if_expression_branch_code(consequent, "ELSE_IF")
        return nil unless nested

        code = "#{code}\n#{nested}"
      elsif consequent
        false_expr = single_expression_from_statements(consequent.statements)
        return nil unless false_expr

        code = "#{code}\n#{indent}ELSE\n#{indent}  #{false_expr}"
      else
        code = "#{code}\n#{indent}ELSE\n#{indent}  NIL"
      end

      code
    end

    def single_expression_from_statements(statements)
      return nil unless statements.is_a?(Prism::StatementsNode)
      return nil unless statements.body.length == 1

      visit(statements.body.first)
    end

    def parameter_default_supported?(node)
      !node.is_a?(Prism::ArrayNode) && !node.is_a?(Prism::HashNode)
    end
  end
end
