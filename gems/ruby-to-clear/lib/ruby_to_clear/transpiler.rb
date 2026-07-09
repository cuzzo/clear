# frozen_string_literal: true

require "prism"
require "pathname"
require "set"

require_relative "helper_config"
require_relative "method_registry"
require_relative "transpiler/call_lowerer"
require_relative "transpiler/constructor_lowerer"
require_relative "transpiler/local_analyzer"
require_relative "transpiler/metadata_collector"
require_relative "transpiler/require_resolver"
require_relative "transpiler/type_env"

module RubyToClear
  class Transpiler
    class TranspilationError < StandardError; end

    LambdaParameters = Struct.new(
      :parameter_names,
      :scope_names,
      :setup_lines,
      :renames,
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

    SCHEMA_HELPER_TYPE_PREDICATES = {
      "struct?" => "Schemas.StructSchema",
      "union?" => "Schemas.UnionSchema",
      "enum?" => "Schemas.EnumSchema",
      "resource?" => "Schemas.ResourceSchema",
      "inline_struct?" => "Schemas.InlineStructVariant",
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

    include TypeEnv
    include LocalAnalyzer
    include RequireResolver
    include MetadataCollector
    include ConstructorLowerer
    include CallLowerer

    def initialize(source, raise_on_error: true, source_path: nil, helper_config: nil)
      @source = source
      @source_path = source_path
      @raise_on_error = raise_on_error
      @helper_config = HelperConfig.load(helper_config)
      @indent_level = 0
      @declared_locals = Set.new
      @class_variables = Set.new
      @struct_fields = {}
      @emitted_class_structs = Set.new
      @emitted_constructor_wrappers = Set.new
      @class_instance_field_names = Hash.new { |hash, key| hash[key] = Set.new }
      @class_instance_field_types = Hash.new { |hash, key| hash[key] = {} }
      @class_instance_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @class_class_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @class_mutating_instance_method_names = Hash.new { |hash, key| hash[key] = Set.new }
      @module_function_names = Hash.new { |hash, key| hash[key] = Set.new }
      @imported_class_names = Set.new
      @collecting_imported_metadata = false
      @method_params = {}
      @method_param_types = {}
      @constructor_params = {}
      @struct_field_defaults = {}
      @loaded_metadata_files = Set.new
      @constant_names = {}
      @current_class = nil
      @renames = {}
      @mutable_params = nil
      @type_aliases = {}
      @union_types = {}
      @generated_union_defs = {}
      @generated_cast_helper_defs = {}
      @body_union_defs = Set.new
      @regex_constants = Set.new
      @type_alias_union_deps = Hash.new { |hash, key| hash[key] = Set.new }
      @type_alias_context = []
      @method_return_types = {}
      @required_packages = Set.new
      @current_function_can_fail = false
      @inside_function = false
      @current_function_returns_value = false
      @function_statement_list_depth = 0
      @local_shapes = {}
      @local_types = {}
      @narrowed_optional_storage_locals = Set.new
      @singleton_class_depth = 0
      @current_function_type_bindings = {}
      @required_files = Set.new
      @private_method_names = Set.new
      @private_section = false
      @current_param_names = Set.new
      @current_function_return_type = nil
      @current_instance_field_names = Set.new
      @current_instance_method_names = Set.new
      @current_mutating_instance_method_names = Set.new
      @inside_instance_method = false
      @inside_class_method = false
      @duplicate_instance_method_names = Set.new
    end

    def transpile(program_node)
      preload_required_metadata(program_node)
      collect_local_requires_from_node(program_node)
      collect_struct_fields_from_node(program_node)
      collect_type_aliases_from_node(program_node)
      collect_ast_node_variants_from_node(program_node)
      collect_method_signature_metadata_from_node(program_node)
      collect_method_params_from_node(program_node)
      collect_regex_constants_from_node(program_node)
      preload_class_instance_metadata(program_node)
      @duplicate_instance_method_names = duplicate_instance_method_names(program_node)
      body = visit(program_node)
      requires = @required_packages.sort.map { |package| "REQUIRE \"pkg:#{package}\"" }
      requires += @required_files.sort.map { |path| "REQUIRE \"#{path}\"" }
      requires += @helper_config.require_lines
      generated_unions = generated_union_definitions_for_body(body)
      generated_cast_helpers = @generated_cast_helper_defs.keys.sort.map { |name| @generated_cast_helper_defs.fetch(name) }
      (requires.uniq + @helper_config.prelude_lines + generated_unions + [body] + generated_cast_helpers).reject(&:empty?).join("\n")
    end

    def generated_union_definitions_for_body(body)
      selected = {}

      loop do
        changed = false
        @generated_union_defs.keys.sort.each do |name|
          next if @body_union_defs.include?(name) || selected.key?(name)

          haystacks = [body] + selected.values
          next unless haystacks.any? { |text| type_name_referenced?(text, name) }

          selected[name] = @generated_union_defs[name]
          changed = true
        end
        break unless changed
      end

      selected.keys.sort.map { |name| selected[name] }
    end

    def type_name_referenced?(text, name)
      !!text.match?(/\b#{Regexp.escape(name)}\b/)
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

    def with_local_types(new_types)
      old_types = @local_types.dup
      new_types.each do |name, type|
        @local_types[name] = type if type && type != "Auto" && type != "Any"
      end
      yield
    ensure
      @local_types = old_types
    end

    def require_package(package)
      @required_packages << package.to_s
    end

    def mark_current_function_fallible!
      @current_function_can_fail = true
    end

    def helper_config
      @helper_config
    end

    def regex_literal_code(pattern_code, interpolated: false)
      if interpolated
        @helper_config.regex_interpolated_literal(pattern_code)
      else
        @helper_config.regex_literal(pattern_code)
      end
    end

    def regex_match_code(subject_code, pattern_code)
      @helper_config.call_or(:regex_match, "regexMatch?", [subject_code, pattern_code])
    end

    def regex_match_data_code(subject_code, pattern_code)
      @helper_config.call(:regex_match_data, [subject_code, pattern_code])
    end

    def regex_replace_all_code(subject_code, pattern_code, replacement_code)
      @helper_config.call_or(:regex_replace_all, "regexReplaceAll", [subject_code, pattern_code, replacement_code])
    end

    def regex_replace_first_code(subject_code, pattern_code, replacement_code)
      @helper_config.call_or(:regex_replace_first, "regexReplaceFirst", [subject_code, pattern_code, replacement_code])
    end

    def regex_escape_code(value_code)
      @helper_config.call_or(:regex_escape, "escapeRegex", [value_code])
    end

    def regex_capture_code(number_code)
      @helper_config.call_or(:regex_capture, "regexCapture", [number_code])
    end

    def regex_pattern_code(value_code)
      @helper_config.call(:regex_pattern, [value_code]) || value_code
    end

    public :helper_config, :regex_literal_code, :regex_match_code, :regex_match_data_code, :regex_replace_all_code,
           :regex_replace_first_code, :regex_escape_code, :regex_capture_code, :regex_pattern_code

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
      "BasicObject" => "Any",
      "Array" => "Any[]",
      "Hash" => "HashMap<Any>",
      "Set" => "Any[]@set",
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
      return "equals?" if raw == "=="
      return "not_equals?" if raw == "!="
      return "lte?" if raw == "<="
      return "gte?" if raw == ">="
      return "set_#{raw.delete_suffix('=')}!" if raw.end_with?("=")
      return "lt?" if raw == "<"
      return "gt?" if raw == ">"

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
      renames = {}
      params_node.requireds.each_with_index do |param, index|
        if param.respond_to?(:name)
          ruby_name = param.name.to_s
          clear_name = clear_lambda_parameter_name(ruby_name, index)
          parameter_names << clear_name
          scope_names << clear_name
          renames[ruby_name] = clear_name if clear_name != ruby_name
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
        setup_lines: setup_lines,
        renames: renames
      )
    end

    def clear_lambda_parameter_name(name, index)
      return name unless name.start_with?("_")

      suffix = name.delete_prefix("_")
      suffix = index.to_s if suffix.empty?
      "ignored_#{suffix}"
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

    def render_returning_statement(stmt)
      return visit(stmt) if guard_exit_statement?(stmt)

      case stmt
      when Prism::IfNode
        render_returning_if_node(stmt)
      when Prism::CaseNode
        render_returning_case_node(stmt)
      else
        "RETURN #{visit(stmt).delete_suffix(';')};"
      end
    end

    def render_returning_statements(statements_node)
      statements = statements_node&.body || []
      return "RETURN NIL;" if statements.empty?

      prefix = statements[0...-1].map { |stmt| visit(stmt) }.reject(&:empty?).map { |code| format_statement_code(code) }
      prefix << format_statement_code(render_returning_statement(statements.last))
      prefix.join("\n")
    end

    def render_returning_if_node(node)
      pred = visit(node.predicate)
      body = with_indent { render_returning_statements(node.statements) }
      consequent = render_returning_consequent(node.consequent)
      "IF #{pred} THEN\n#{body}#{consequent}\nEND"
    end

    def render_returning_consequent(consequent)
      return "" unless consequent

      if consequent.is_a?(Prism::IfNode)
        pred = visit(consequent.predicate)
        body = with_indent { render_returning_statements(consequent.statements) }
        nested = render_returning_consequent(consequent.consequent)
        return "\nELSE_IF #{pred} THEN\n#{body}#{nested}"
      end

      body = with_indent { render_returning_statements(consequent.statements) }
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

      body = with_renames(params.renames || {}) do
        with_lambda_scope(params.scope_names) { render_lambda_body(block_node, setup_lines: params.setup_lines) }
      end
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
      nil
    end

    def t_struct_class?(node)
      node.superclass&.location&.slice == "T::Struct"
    end

    def t_enum_class?(node)
      node.superclass&.location&.slice == "T::Enum"
    end

    def t_enum_variants(node)
      body_nodes = node.body&.body || []
      enum_call = body_nodes.find do |stmt|
        stmt.is_a?(Prism::CallNode) &&
          stmt.receiver.nil? &&
          stmt.name.to_s == "enums" &&
          stmt.block
      end
      return [] unless enum_call

      enum_call.block&.body&.body&.filter_map do |stmt|
        next unless stmt.is_a?(Prism::ConstantWriteNode)
        next unless sorbet_enum_new_call?(stmt.value)

        stmt.name.to_s
      end || []
    end

    def sorbet_enum_new_call?(node)
      node.is_a?(Prism::CallNode) &&
        node.receiver.nil? &&
        node.name.to_s == "new"
    end

    def t_struct_field(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.receiver.nil?
      return nil unless ["const", "prop"].include?(node.name.to_s)

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length >= 2
      return nil unless args.first.is_a?(Prism::SymbolNode)

      [args.first.value.to_s, convert_sorbet_type(args[1]), t_struct_field_default(args)]
    end

    def t_struct_field_default(args)
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      return nil unless keyword_hash

      assoc = keyword_hash.elements.find do |element|
        element.is_a?(Prism::AssocNode) && keyword_call_key(element.key) == "default"
      end
      return nil unless assoc&.value

      visit(assoc.value)
    end

    def concrete_struct_type(type)
      expand_non_emitted_type_alias(type.to_s.gsub(/\bAuto\b/, "Any"))
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

    def same_class_constructor_call?(node)
      node.name.to_s == "new" &&
        node.receiver.nil? &&
        @current_class &&
        @inside_class_method
    end

    def constructor_field_names(receiver)
      names = []
      names << @current_class if receiver.nil? && @current_class
      names << receiver.location.slice.strip if receiver
      names << receiver.location.slice.strip.split("::").last if receiver.is_a?(Prism::ConstantPathNode)
      names << receiver.name.to_s if receiver.respond_to?(:name)

      names.uniq.each do |name|
        return @struct_fields[name] if @struct_fields[name]
      end

      nil
    end

    def constructor_field_defaults(receiver)
      names = []
      names << @current_class if receiver.nil? && @current_class
      names << receiver.location.slice.strip if receiver
      names << receiver.location.slice.strip.split("::").last if receiver.is_a?(Prism::ConstantPathNode)
      names << receiver.name.to_s if receiver.respond_to?(:name)

      names.uniq.each do |name|
        return @struct_field_defaults[name] if @struct_field_defaults[name]
      end

      nil
    end

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
      private_names = statements.flat_map { |stmt| private_class_method_names(stmt) }
      old_private_method_names = @private_method_names
      old_private_section = @private_section
      old_function_statement_list_depth = @function_statement_list_depth
      top_level_function_body = @inside_function && old_function_statement_list_depth.zero?
      @function_statement_list_depth = old_function_statement_list_depth + 1
      @private_method_names = @private_method_names | private_names.to_set
      while index < statements.length
        stmt = statements[index]
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          index += 1
          next
        end

        if visibility_section_call?(stmt)
          @private_section = stmt.name.to_s != "public"
          last_sig = nil
          index += 1
          next
        end

        if declaration_comment?(stmt, "ruby-to-clear: skip")
          last_sig = nil
          index += 1
          next
        end

        if stmt.is_a?(Prism::DefNode) || private_class_method_def_call?(stmt)
          @current_sig = last_sig
          last_sig = nil
        else
          last_sig = nil
        end

        if (guard = optional_nil_exit_guard(stmt)) && index < statements.length - 1
          code = render_optional_nil_guard(guard, statements[(index + 1)..])
          @current_sig = nil
          rendered << format_statement_code(code) unless code.empty?
          break
        end

        if (guard = runtime_is_a_exit_guard(stmt)) && index < statements.length - 1
          code = render_runtime_is_a_guard(guard, statements[(index + 1)..])
          @current_sig = nil
          rendered << format_statement_code(code) unless code.empty?
          break
        end

        code = if top_level_function_body && @current_function_returns_value && index == statements.length - 1 && ternary_if_node?(stmt)
          render_returning_if_node(stmt)
        elsif top_level_function_body && @current_function_returns_value && index == statements.length - 1 && stmt.is_a?(Prism::CaseNode)
          render_returning_case_node(stmt)
        else
          visit(stmt)
        end
        @current_sig = nil
        rendered << format_statement_code(code) unless code.empty?

        index += 1
      end
      @private_method_names = old_private_method_names
      @private_section = old_private_section
      @function_statement_list_depth = old_function_statement_list_depth
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

    def optional_nil_exit_guard(stmt)
      return nil unless stmt.is_a?(Prism::UnlessNode)
      return nil if stmt.consequent
      return nil unless stmt.predicate.is_a?(Prism::LocalVariableReadNode)

      receiver_name = stmt.predicate.name.to_s
      receiver_type = static_clear_type_for_receiver(receiver_name)
      return nil unless receiver_type.to_s.start_with?("?")

      body = stmt.statements&.body || []
      return nil unless body.any?
      return nil unless guard_exit_statement?(body.last)

      {
        receiver_name: receiver_name,
        receiver_code: visit(stmt.predicate),
        payload_type: receiver_type.to_s.delete_prefix("?"),
        exit_statements: body,
      }
    end

    def render_optional_nil_guard(guard, rest_statements)
      then_body = with_indent do
        with_optional_unwrap_context(guard) do
          visit_statement_list(rest_statements)
        end
      end
      else_body = with_indent do
        guard[:exit_statements].map { |stmt| format_statement_code(visit(stmt)) }.join("\n")
      end
      "IF #{guard[:receiver_code]} THEN\n#{then_body}\nELSE\n#{else_body}\nEND"
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

    def with_optional_unwrap_context(guard)
      receiver_name = guard[:receiver_name]
      payload_type = guard[:payload_type]
      old_types = @local_types.dup
      old_shapes = @local_shapes.dup
      old_narrowed_optional_storage_locals = @narrowed_optional_storage_locals.dup
      @local_types[receiver_name] = payload_type
      @local_shapes[receiver_name] = clear_type_shape(payload_type)
      @narrowed_optional_storage_locals << receiver_name if union_like_type?(payload_type)
      renames = { receiver_name => optional_unwrap_code(receiver_name) }
      with_renames(renames) { yield }
    ensure
      @local_types = old_types
      @local_shapes = old_shapes
      @narrowed_optional_storage_locals = old_narrowed_optional_storage_locals
    end

    def with_narrowing_context(runtime_is_a)
      binding_name = runtime_is_a[:binding_name]
      old_types = @local_types.dup
      old_shapes = @local_shapes.dup
      @local_types[binding_name] = runtime_is_a[:expected_type]
      @local_shapes[binding_name] = clear_type_shape(runtime_is_a[:expected_type])
      with_renames(runtime_is_a[:renames]) { yield }
    ensure
      @local_types = old_types
      @local_shapes = old_shapes
    end

    def with_runtime_is_a_else_context(runtime_is_a)
      return yield unless runtime_is_a

      receiver_name = runtime_is_a[:receiver_name]
      receiver_type = static_clear_type_for_receiver(receiver_name)
      unwrap_code = optional_unwrap_code(receiver_name)
      unless @renames[receiver_name] == unwrap_code && receiver_type && !receiver_type.to_s.start_with?("?")
        return yield
      end

      old_renames = @renames.dup
      @renames.delete(receiver_name)
      yield
    ensure
      @renames = old_renames if old_renames
    end

    def optional_union_truthy_if_guard(predicate)
      return nil unless predicate.is_a?(Prism::LocalVariableReadNode)

      receiver_name = predicate.name.to_s
      return nil if @current_param_names.include?(receiver_name)

      receiver_type = static_clear_type_for_receiver(receiver_name)
      return nil unless receiver_type.to_s.start_with?("?")

      payload_type = receiver_type.to_s.delete_prefix("?")
      return nil unless union_like_type?(payload_type)

      {
        receiver_name: receiver_name,
        payload_type: payload_type,
      }
    end

    def with_optional_truthy_context(guard)
      receiver_name = guard[:receiver_name]
      payload_type = guard[:payload_type]
      old_types = @local_types.dup
      old_shapes = @local_shapes.dup
      old_narrowed_optional_storage_locals = @narrowed_optional_storage_locals.dup
      @local_types[receiver_name] = payload_type
      @local_shapes[receiver_name] = clear_type_shape(payload_type)
      @narrowed_optional_storage_locals << receiver_name
      yield
    ensure
      @local_types = old_types
      @local_shapes = old_shapes
      @narrowed_optional_storage_locals = old_narrowed_optional_storage_locals
    end

    def union_like_type?(type)
      @union_types[type] || @generated_union_defs[type] || @type_aliases[type]
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

    def visit_interpolated_symbol_node(node)
      parts = node.parts.map { |part| interpolated_string_part_for_literal(part) }.join
      "symbol(\"#{parts}\")"
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
      if name == "UNSET" && @current_class
        return sentinel_literal_for("#{@current_class}::UNSET") || name
      end

      @constant_names[name] || name
    end

    def visit_constant_path_node(node)
      path = node.location.slice.strip
      sentinel_literal_for(path) || path.gsub("::", ".")
    end

    def sentinel_literal_for(path)
      sentinel = sentinel_type_for_path(path)
      "#{sentinel}{}" if sentinel
    end

    def sentinel_type_for_node(node)
      case node
      when Prism::ConstantReadNode
        return nil unless node.name.to_s == "UNSET" && @current_class

        sentinel_type_for_path("#{@current_class}::UNSET")
      when Prism::ConstantPathNode
        sentinel_type_for_path(node.location.slice.strip)
      end
    end

    def sentinel_type_for_path(path)
      case path
      when "TypeCapabilities::UNSET"
        "TypeCapabilityUnset"
      when "TypePlacement::UNSET"
        "TypePlacementUnset"
      end
    end

    def visit_arguments_node(node)
      node.arguments.map { |arg| visit(arg) }.join(", ")
    end

    def visit_local_variable_write_node(node)
      name = node.name.to_s
      name = @renames[name] || name
      value_node = node.value
      type_annotation = nil
      cast_value = sorbet_cast_expression(value_node) if sorbet_call?(value_node, "cast")
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
      end

      if value_node.is_a?(Prism::IfNode) && (type_annotation || !if_expression_code(value_node))
        return visit_local_variable_if_assignment(name, value_node, type_annotation)
      end

      val = if value_node.is_a?(Prism::IfNode)
        visit_if_expression_or_placeholder(value_node)
      elsif value_node.is_a?(Prism::CaseNode)
        visit_case_expression_or_placeholder(value_node)
      else
        cast_value || sorbet_must_assignment_unwrap_code(value_node) || visit(value_node)
      end
      val = "COPY #{val}" if copyable_local_read_source?(value_node)
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

    def sorbet_must_assignment_unwrap_code(node)
      return nil unless sorbet_call?(node, "must")

      args = node.arguments ? node.arguments.arguments : []
      return nil unless args.length == 1
      return nil unless args.first.is_a?(Prism::LocalVariableReadNode)

      source_name = args.first.name.to_s
      return nil unless @narrowed_optional_storage_locals.include?(source_name)

      optional_unwrap_code(source_name)
    end

    def visit_local_variable_if_assignment(name, if_node, type_annotation)
      shape = inferred_shape(if_node)
      assignment_type = type_annotation || inferred_if_assignment_type(if_node)
      prefix = ""
      unless @declared_locals.include?(name)
        @declared_locals << name
        @local_shapes[name] = shape
        @local_types[name] = assignment_type if assignment_type && assignment_type != "Auto"
        prefix = "#{predeclared_local_declaration(name, assignment_type)}\n"
      end

      @local_shapes[name] = shape
      @local_types[name] = assignment_type if assignment_type && assignment_type != "Auto"
      "#{prefix}#{if_assignment_code(name, if_node, assignment_type)}"
    end

    def inferred_if_assignment_type(if_node)
      types = []
      current = if_node

      loop do
        types << inferred_branch_statement_type(current.statements)
        consequent = current.consequent
        if consequent.is_a?(Prism::IfNode)
          current = consequent
          next
        elsif consequent
          types << inferred_branch_statement_type(consequent.statements)
        end
        break
      end

      compact_types = types.compact
      compact_types.uniq.one? ? compact_types.first : nil
    end

    def inferred_branch_statement_type(statements)
      return nil unless statements.is_a?(Prism::StatementsNode) && statements.body.any?

      inferred_clear_type(statements.body.last)
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

    def visit_instance_variable_or_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      val = visit(node.value)
      "self.#{name} = (self.#{name} || #{val})"
    end

    def visit_instance_variable_and_write_node(node)
      name = node.name.to_s.delete_prefix("@")
      val = visit(node.value)
      "self.#{name} = (self.#{name} && #{val})"
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
      val = field_assignment_value(node.value)
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

    def field_assignment_value(value_node)
      val = visit(value_node)
      return val unless copyable_local_read_source?(value_node)

      "COPY #{val}"
    end

    def copyable_local_read_source?(node)
      value_node = node
      type_annotation = nil
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
      elsif (unwrapped = sorbet_unwrapped_value(value_node))
        value_node = unwrapped
      end

      return false unless value_node.is_a?(Prism::LocalVariableReadNode)

      local_name = value_node.name.to_s

      type = type_annotation || @local_types[local_name] || (@param_types && @param_types[local_name])
      copyable_storage_type?(type)
    end

    def copyable_storage_type?(type)
      return false if type.nil? || type == "Auto" || type == "Any" || type == "Void"

      normalized = expand_clear_type_alias(type.to_s).to_s.delete_prefix("?")
      return false if normalized.include?("@raw")
      base = normalized.split("@").first
      return true if base.end_with?("[]") || normalized.start_with?("HashMap<")

      string_like_clear_type?(normalized)
    end

    def visit_constant_write_node(node)
      name = node.name.to_s
      @regex_constants << name if regex_value_node?(node.value)

      if name == "UNSET" && @current_class && sentinel_literal_for("#{@current_class}::UNSET")
        return ""
      end

      alias_key = type_alias_key(name)
      alias_name = type_alias_clear_name(name)
      if (type_alias = sorbet_type_alias_value(node.value, alias_name: alias_name))
        @type_aliases[alias_key] = type_alias
        union_defs = union_definitions_for_alias(alias_name, type_alias)
        return union_defs.join("\n") unless union_defs.empty?

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
        return "#{declaration_visibility_prefix(node)}STRUCT #{name} {\n#{field_decls}\n}"
      end

      clear_name = constant_variable_name(name)
      @constant_names[name] = clear_name
      value_node = node.value
      type_annotation = nil
      if (typed_value = sorbet_typed_value(value_node))
        value_node, type_annotation = typed_value
      end

      type_suffix = type_annotation && type_annotation != "Auto" ? ": #{type_annotation}" : ""
      "MUTABLE #{clear_name}#{type_suffix} = #{visit(value_node)}"
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
      rest = node.rest ? [visit(node.rest)] : []
      keywords = node.keywords.map { |param| visit(param) }
      keyword_rest = node.keyword_rest ? [visit(node.keyword_rest)] : []
      block = node.block ? [visit(node.block)] : []
      (requireds + optionals + rest + keywords + keyword_rest + block).join(", ")
    end

    def visit_optional_parameter_node(node)
      prefix = (@mutable_params && @mutable_params.include?(node.name.to_s)) ? "MUTABLE " : ""
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      return "#{prefix}#{node.name}: #{type}" unless parameter_default_supported?(node.value)

      default_val = parameter_default_code(node.value, type)
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

      default_val = parameter_default_code(node.value, type)
      "#{prefix}#{node.name} = #{default_val}: #{type}"
    end

    def parameter_default_code(value_node, type)
      value = visit(value_node)
      sentinel_type = sentinel_type_for_node(value_node)
      union_type = sentinel_union_type_for_parameter(type, sentinel_type) if sentinel_type
      return value unless union_type

      "#{union_type}{ #{union_variant_name(sentinel_type)}: #{value} }"
    end

    def sentinel_union_type_for_parameter(type, sentinel_type)
      normalized = type.to_s.delete_prefix("?")
      return nil unless @union_types[normalized]&.include?(sentinel_type)

      normalized
    end

    def optional_sentinel_union_receiver?(receiver, sentinel_type)
      type = inferred_clear_type(receiver)
      return false unless type.to_s.start_with?("?")

      !!sentinel_union_type_for_parameter(type, sentinel_type)
    end

    def optional_unwrap_code(code)
      code.match?(/\A[A-Za-z_]\w*\z/) ? "#{code}?" : "(#{code})?"
    end

    def visit_block_parameter_node(node)
      type = (@param_types && @param_types[node.name.to_s]) || "Auto"
      return "#{node.name}: #{type}" unless type == "Auto" || type.to_s.start_with?("?")

      "#{node.name} = NIL: #{type}"
    end

    def visit_rest_parameter_node(node)
      name = node.name ? node.name.to_s : "args"
      type = rest_parameter_type(name)
      "#{name} = []: #{type}"
    end

    def visit_keyword_rest_parameter_node(node)
      name = node.name ? node.name.to_s : "kwargs"
      type = keyword_rest_parameter_type(name)
      "#{name} = {}: #{type}"
    end

    def rest_parameter_type(name)
      type = @param_types && @param_types[name]
      return "Auto[]" if type.nil? || type == "Auto" || type == "Any"
      return type if type.end_with?("[]")

      "#{type}[]"
    end

    def keyword_rest_parameter_type(name)
      type = @param_types && @param_types[name]
      return "HashMap<String@symbol, Auto>" if type.nil? || type == "Auto" || type == "Any"
      return type if type.start_with?("HashMap<")

      "HashMap<String@symbol, #{type}>"
    end

    def visit_array_node(node)
      elements = node.elements.map { |el| visit(el) }.join(", ")
      "[#{elements}]"
    end

    def visit_splat_node(node)
      unsupported_expression(node, "Splat arguments require an explicit call shape or generated overload")
    end

    def visit_assoc_splat_node(node)
      visit(node.value)
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
      if node.key.is_a?(Prism::SymbolNode)
        key = symbol_hash_key_code(node.key.value.to_s)
      end
      val = visit(node.value)
      "#{key}: #{val}"
    end

    def symbol_hash_key_code(raw_key)
      raw_key.match?(/\A[A-Za-z]\w*[!?]?\z/) && !CLEAR_KEYWORDS.include?(raw_key) ? ":#{raw_key}" : "symbol(#{raw_key.inspect})"
    end

    def visit_and_node(node)
      lhs = visit(node.left)
      rhs = visit(node.right)
      "(#{lhs} && #{rhs})"
    end

    def visit_or_node(node)
      lhs = visit(node.left)
      rhs = visit(node.right)
      op = nilable_expression?(node.left) ? "OR" : "||"
      "(#{lhs} #{op} #{rhs})"
    end

    def nilable_expression?(node)
      type = inferred_clear_type(node)
      type.to_s.start_with?("?")
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
        args = node.arguments.arguments
        if args.length == 1 && args.first.is_a?(Prism::IfNode)
          return render_returning_if_node(args.first)
        end

        if args.length == 1 && args.first.is_a?(Prism::CaseNode)
          return render_returning_case_node(args.first)
        end

        if args.length == 1
          code = visit(args.first)
          code = wrap_argument_for_parameter_type(code, args.first, @current_function_return_type)
          return "RETURN #{code}"
        end

        "RETURN #{visit(node.arguments)}"
      else
        "RETURN"
      end
    end

    def visit_super_node(node)
      args = node.arguments ? visit(node.arguments) : ""
      "super(#{args})"
    end

    def visit_forwarding_super_node(_node)
      "super()"
    end

    def visit_yield_node(node)
      args = node.arguments ? visit(node.arguments) : ""
      "yield(#{args})"
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
      optional_truthy = runtime_is_a || pred_assignment ? nil : optional_union_truthy_if_guard(node.predicate)
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
        elsif optional_truthy
          with_optional_truthy_context(optional_truthy) { visit(node.statements) }
        else
          visit(node.statements)
        end
      end
      consequent_code = node.consequent ? format_consequent(node.consequent, runtime_is_a) : ""
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
      if (helper_predicate = schema_helper_type_predicate(node))
        receiver_name = helper_predicate[:receiver_name]
        receiver_type = static_clear_type_for_receiver(receiver_name)
        expected_type = runtime_is_a_expected_type(receiver_type, helper_predicate[:expected_type])
        return nil unless receiver_type && runtime_union_narrowing_candidate?(receiver_type, expected_type)

        binding_name = runtime_is_a_binding_name(expected_type, receiver_name)
        receiver_code = runtime_is_a_receiver_code(
          receiver_name,
          helper_predicate[:receiver_code],
          receiver_type,
        )
        receiver_code = optional_unwrap_code(receiver_code) if receiver_type.to_s.start_with?("?")
        return {
          receiver_name: receiver_name,
          receiver_code: receiver_code,
          expected_type: expected_type,
          binding_name: binding_name,
          renames: { receiver_name => binding_name },
        }
      end

      expected_raw = type_predicate_argument(node)
      return nil unless expected_raw

      receiver = node.receiver
      return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

      receiver_name = receiver.name.to_s
      receiver_type = static_clear_type_for_receiver(receiver_name)
      expected_type = runtime_is_a_expected_type(receiver_type, expected_raw)
      return nil unless receiver_type && runtime_union_narrowing_candidate?(receiver_type, expected_type)

      binding_name = runtime_is_a_binding_name(expected_type, receiver_name)
      receiver_code = runtime_is_a_receiver_code(receiver_name, visit(receiver), receiver_type)
      receiver_code = optional_unwrap_code(receiver_code) if receiver_type.to_s.start_with?("?")
      {
        receiver_name: receiver_name,
        receiver_code: receiver_code,
        expected_type: expected_type,
        binding_name: binding_name,
        renames: { receiver_name => binding_name },
      }
    end

    def runtime_is_a_receiver_code(receiver_name, receiver_code, receiver_type)
      unwrap_code = optional_unwrap_code(receiver_name)
      local_receiver = !@current_param_names.include?(receiver_name)
      if local_receiver && receiver_code == unwrap_code && !receiver_type.to_s.start_with?("?")
        return receiver_name
      end

      receiver_code
    end

    def runtime_is_a_binding_name(expected_type, receiver_name)
      base = if expected_type.to_s.start_with?("HashMap<")
        "hash"
      elsif expected_type.to_s.end_with?("[]")
        "array"
      else
        expected_type.to_s.split(".").last
      end
      snake = base
        .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .downcase
        .gsub(/[^a-z0-9_]+/, "_")
        .gsub(/\A_+|_+\z/, "")
      snake = "#{receiver_name}_as_#{snake}" if snake == receiver_name
      snake.empty? ? "#{receiver_name}_payload" : snake
    end

    def visit_case_node(node)
      if node.predicate.nil?
        return render_case_as_condition_chain(node, nil)
      else
        target = visit(node.predicate)
        if statement_case_condition_chain?(node)
          return render_case_as_condition_chain(node, target)
        end

        arms = []
        node.conditions.each do |w|
          w.conditions.each do |cond|
            cond_val = visit(cond)
            stmt_val = match_statement_arm_body(visit(w.statements))
            arms << "#{cond_val} -> #{stmt_val},"
          end
        end

        if node.consequent
          else_val = match_statement_arm_body(visit(node.consequent))
          arms << "DEFAULT -> #{else_val}"
        end

        arms_body = with_indent do
          arms.map { |arm| arm.split("\n").map { |l| "#{indent}#{l}" }.join("\n") }.join("\n")
        end

        "PARTIAL MATCH #{target} START\n#{arms_body}\nEND"
      end
    end

    def statement_case_condition_chain?(node)
      return true if node.conditions.any? { |w| w.conditions.any? { |cond| cond.is_a?(Prism::SplatNode) } }

      node.conditions.any? { |w| !case_expression_statements?(w.statements) } ||
        (node.consequent && !case_expression_statements?(node.consequent.statements))
    end

    def render_case_as_condition_chain(node, target, returning: false)
      chunks = []
      node.conditions.each_with_index do |when_node, index|
        keyword = index.zero? ? "IF" : "ELSE_IF"
        pred = case_when_predicate(target, when_node)
        body = with_indent do
          returning ? returning_branch_statements(when_node.statements) : visit(when_node.statements)
        end
        chunks << "#{keyword} #{pred} THEN\n#{body}"
      end

      if node.consequent
        else_body = with_indent do
          returning ? returning_branch_statements(node.consequent.statements) : visit(node.consequent)
        end
        chunks << "ELSE\n#{else_body}"
      elsif returning
        chunks << "ELSE\n#{indent}  RETURN NIL;"
      end

      "#{chunks.join("\n")}#{chunks.empty? ? "" : "\n"}END"
    end

    def case_when_predicate(target, when_node)
      when_node.conditions.map { |cond| case_condition_predicate(target, cond) }.join(" || ")
    end

    def case_condition_predicate(target, cond)
      return visit(cond) unless target

      if cond.is_a?(Prism::SplatNode)
        return "#{visit(cond.expression)}.contains?(#{target})"
      end

      "(#{target} == #{visit(cond)})"
    end

    def visit_regular_expression_node(node)
      regex_literal_code(clear_string_literal(node.unescaped))
    end

    def visit_interpolated_regular_expression_node(node)
      pattern = interpolated_regex_pattern_code(node)
      regex_literal_code(pattern, interpolated: true)
    end

    def visit_numbered_reference_read_node(node)
      regex_capture_code(node.number.to_s)
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

    def interpolated_regex_pattern_code(node)
      if node.parts.none? { |part| part.is_a?(Prism::EmbeddedStatementsNode) }
        return clear_string_literal(node.parts.map { |part| interpolated_regex_part(part) }.join)
      end

      parts = node.parts.map { |part| interpolated_regex_part_for_literal(part) }.join
      "\"#{parts}\""
    end

    def interpolated_regex_part(part)
      case part
      when Prism::StringNode
        part.unescaped
      when Prism::EmbeddedStatementsNode
        "${#{embedded_regex_pattern_expression(part)}}"
      else
        visit(part).delete_suffix(";")
      end
    end

    def interpolated_regex_part_for_literal(part)
      case part
      when Prism::StringNode
        clear_string_escape(part.unescaped)
      when Prism::EmbeddedStatementsNode
        "${#{embedded_regex_pattern_expression(part)}}"
      else
        clear_string_escape(visit(part).delete_suffix(";"))
      end
    end

    def embedded_regex_pattern_expression(node)
      statements = node.statements
      return "" unless statements

      unless statements.body.length == 1
        return raise_unsupported("Regex interpolation must contain a single expression", node)
      end

      expression = statements.body.first
      code = regex_constant_read?(expression) ? constant_variable_name(expression.name.to_s) : visit(expression).delete_suffix(";")
      regex_pattern_expression?(expression) ? regex_pattern_code(code) : code
    end

    def regex_pattern_expression?(node)
      return true if regex_value_node?(node)
      return true if regex_constant_read?(node)

      false
    end

    def regex_constant_read?(node)
      node.is_a?(Prism::ConstantReadNode) && @regex_constants.include?(node.name.to_s)
    end

    def regex_value_node?(node)
      return false unless node

      unwrapped = sorbet_unwrapped_value(node)
      return regex_value_node?(unwrapped) if unwrapped && !unwrapped.equal?(node)

      return true if node.is_a?(Prism::RegularExpressionNode) || node.is_a?(Prism::InterpolatedRegularExpressionNode)

      node.is_a?(Prism::CallNode) &&
        node.name.to_s == "freeze" &&
        (!node.arguments || node.arguments.arguments.empty?) &&
        regex_value_node?(node.receiver)
    end

    def visit_module_node(node)
      name = node.constant_path.location.slice.strip
      @module_function_names[name].merge(collect_class_method_names(node))
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
      class_name = node.constant_path.location.slice.strip
      @current_class = class_name

      if t_enum_class?(node)
        variants = t_enum_variants(node)
        @current_class = old_class
        return "ENUM #{class_name} { #{variants.join(', ')} }"
      end

      if t_struct_class?(node)
        body_nodes = node.body&.body || []
        fields = body_nodes.filter_map { |stmt| t_struct_field(stmt) }
        register_constructor_fields([], @current_class, fields.map(&:first))
        field_decls = fields.map { |field, type| "  #{field}: #{concrete_struct_type(type)}" }.join(",\n")
        body_without_fields = body_nodes.reject { |stmt| t_struct_field(stmt) }
        old_instance_field_names = @current_instance_field_names
        old_instance_method_names = @current_instance_method_names
        old_mutating_instance_method_names = @current_mutating_instance_method_names
        fields.each { |field, type| @class_instance_field_types[class_name][field] = concrete_struct_type(type) }
        @class_instance_field_names[class_name].merge(fields.map(&:first))
        @class_instance_method_names[class_name].merge(collect_instance_method_names(node))
        @class_class_method_names[class_name].merge(collect_class_method_names(node))
        @class_mutating_instance_method_names[class_name].merge(collect_mutating_instance_method_names(node))
        @current_instance_field_names = @class_instance_field_names[class_name].dup
        @current_instance_method_names = @class_instance_method_names[class_name].dup
        @current_mutating_instance_method_names = @class_mutating_instance_method_names[class_name].dup
        body_code = visit_statement_list(body_without_fields)
        @current_instance_field_names = old_instance_field_names
        @current_instance_method_names = old_instance_method_names
        @current_mutating_instance_method_names = old_mutating_instance_method_names
        @current_class = old_class
        return body_code if @emitted_class_structs.include?(class_name)

        @emitted_class_structs << class_name
        struct_code = "#{declaration_visibility_prefix(node)}STRUCT #{node.constant_path.location.slice.strip} {\n#{field_decls}\n}"
        return body_code.empty? ? struct_code : "#{struct_code}\n\n#{body_code}"
      end

      if struct_new_superclass?(node.superclass)
        fields = struct_new_field_names(node.superclass)
        register_constructor_fields([], @current_class, fields)
        old_instance_field_names = @current_instance_field_names
        old_instance_method_names = @current_instance_method_names
        old_mutating_instance_method_names = @current_mutating_instance_method_names
        fields.each { |field| @class_instance_field_types[class_name][field] ||= "Any" }
        @class_instance_field_names[class_name].merge(fields)
        @class_instance_method_names[class_name].merge(collect_instance_method_names(node))
        @class_class_method_names[class_name].merge(collect_class_method_names(node))
        @class_mutating_instance_method_names[class_name].merge(collect_mutating_instance_method_names(node))
        @current_instance_field_names = @class_instance_field_names[class_name].dup
        @current_instance_method_names = @class_instance_method_names[class_name].dup
        @current_mutating_instance_method_names = @class_mutating_instance_method_names[class_name].dup
        body_code = visit(node.body)
        @current_instance_field_names = old_instance_field_names
        @current_instance_method_names = old_instance_method_names
        @current_mutating_instance_method_names = old_mutating_instance_method_names
        @current_class = old_class
        return body_code if @emitted_class_structs.include?(class_name)

        @emitted_class_structs << class_name
        field_decls = fields.map { |field| "  #{field}: Any" }.join(",\n")
        struct_code = "#{declaration_visibility_prefix(node)}STRUCT #{class_name} {\n#{field_decls}\n}"
        return body_code.empty? ? struct_code : "#{struct_code}\n\n#{body_code}"
      end

      instance_fields = collect_instance_fields(node)
      old_instance_field_names = @current_instance_field_names
      old_instance_method_names = @current_instance_method_names
      old_mutating_instance_method_names = @current_mutating_instance_method_names
      instance_fields.each { |field, type| @class_instance_field_types[class_name][field] = type }
      @class_instance_field_names[class_name].merge(instance_fields.keys)
      @class_instance_method_names[class_name].merge(collect_instance_method_names(node))
      @class_class_method_names[class_name].merge(collect_class_method_names(node))
      @class_mutating_instance_method_names[class_name].merge(collect_mutating_instance_method_names(node))
      @current_instance_field_names = @class_instance_field_names[class_name].dup
      @current_instance_method_names = @class_instance_method_names[class_name].dup
      @current_mutating_instance_method_names = @class_mutating_instance_method_names[class_name].dup
      body_code = visit(node.body)
      constructor_wrapper = constructor_wrapper_for_class(node, class_name, instance_fields)
      body_code = [body_code, constructor_wrapper].compact.reject(&:empty?).join("\n")
      @current_instance_field_names = old_instance_field_names
      @current_instance_method_names = old_instance_method_names
      @current_mutating_instance_method_names = old_mutating_instance_method_names

      @current_class = old_class

      return body_code if @emitted_class_structs.include?(class_name)
      return body_code if namespace_only_class?(node, instance_fields)
      return body_code if imported_class_extension?(class_name, instance_fields)

      @emitted_class_structs << class_name
      struct_fields = instance_fields.map { |name, type| "  #{name}: #{type}" }.join(",\n")
      struct_code = "#{declaration_visibility_prefix(node)}STRUCT #{class_name} {\n#{struct_fields}\n}"
      "#{struct_code}\n\n#{body_code}"
    end

    def constructor_wrapper_for_class(class_node, class_name, instance_fields)
      return nil if @emitted_constructor_wrappers.include?(class_name)

      initialize_def = class_initializer_def(class_node)
      return nil unless initialize_def

      @emitted_constructor_wrappers << class_name

      params, type_params = constructor_wrapper_parameters(class_node, initialize_def)
      defaults = initializer_field_defaults(initialize_def, instance_fields)
      pairs = instance_fields.map do |field, type|
        "#{field}: #{defaults.fetch(field) { default_value_for_type(type) }}"
      end
      literal = pairs.empty? ? "#{class_name}{}" : "#{class_name}{ #{pairs.join(', ')} }"
      args = method_parameter_info(initialize_def.parameters).map { |info| info[:name] }
      init_name = instance_function_name(class_name, "initialize")
      type_param_suffix = type_params.empty? ? "" : "<#{type_params.join(', ')}>"
      lines = []
      lines << "FN #{constructor_function_name(class_name)}#{type_param_suffix}(#{params}) RETURNS #{class_name} ->"
      lines << "  MUTABLE self = #{literal};"
      lines << "  #{init_name}(#{['self', *args].join(', ')});"
      lines << "  self;"
      lines << "END"
      lines.join("\n")
    end

    def class_initializer_def(class_node)
      body_nodes = class_node.body&.body || []
      body_nodes.find { |stmt| stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && stmt.name.to_s == "initialize" }
    end

    def signature_for_def_in_class(class_node, def_node)
      last_sig = nil
      (class_node.body&.body || []).each do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
          last_sig = stmt
          next
        end

        return last_sig if stmt.equal?(def_node)

        last_sig = nil unless stmt.is_a?(Prism::CallNode) && stmt.name.to_s == "sig"
      end
      nil
    end

    def constructor_wrapper_parameters(class_node, initialize_def)
      old_param_types = @param_types
      old_mutable_params = @mutable_params
      sig_node = signature_for_def_in_class(class_node, initialize_def)
      param_types, _return_type, sig_type_params = parse_sig(sig_node)
      param_names = extract_parameter_names(initialize_def)
      type_bindings = infer_function_type_bindings(initialize_def.body, param_names, param_types, sig_type_params)
      param_types = param_types.merge(type_bindings)
      type_params = (sig_type_params + type_bindings.values).uniq

      @param_types = param_types
      @mutable_params = Set.new
      params = initialize_def.parameters ? visit(initialize_def.parameters) : ""
      [params, type_params]
    ensure
      @param_types = old_param_types
      @mutable_params = old_mutable_params
    end

    def initializer_field_defaults(initialize_def, instance_fields)
      param_names = extract_parameter_names(initialize_def)
      defaults = {}
      walk = lambda do |node|
        return unless node
        return if node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode)

        if node.is_a?(Prism::InstanceVariableWriteNode)
          field = node.name.to_s.delete_prefix("@")
          if instance_fields.key?(field) && !defaults.key?(field)
            value = constructor_initial_field_value(node.value, param_names, instance_fields[field])
            defaults[field] = value if value
          end
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(initialize_def.body)
      defaults
    end

    def constructor_initial_field_value(value_node, param_names, field_type = nil)
      if (typed_value = sorbet_typed_value(value_node))
        return constructor_initial_field_value(typed_value.first, param_names, field_type)
      end

      if (unwrapped = sorbet_unwrapped_value(value_node))
        return constructor_initial_field_value(unwrapped, param_names, field_type)
      end

      case value_node
      when Prism::LocalVariableReadNode
        return nil unless param_names.include?(value_node.name.to_s)

        code = visit(value_node)
        copyable_storage_type?(field_type) ? "COPY #{code}" : code
      when Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::StringNode,
           Prism::InterpolatedStringNode, Prism::SymbolNode, Prism::IntegerNode,
           Prism::FloatNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
           Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode
        visit(value_node)
      when Prism::CallNode
        if value_node.name.to_s == "dup" &&
           value_node.receiver.is_a?(Prism::LocalVariableReadNode) &&
           param_names.include?(value_node.receiver.name.to_s)
          return "COPY #{visit(value_node.receiver)}"
        end

        visit(value_node) if constant_constructor_call?(value_node)
      end
    end

    def declaration_visibility_prefix(node)
      declaration_comment?(node, "ruby-to-clear: pub") ? "PUB " : ""
    end

    def declaration_comment?(node, marker)
      return false unless node&.location

      loc = if node.respond_to?(:def_keyword_loc) && node.def_keyword_loc
        node.def_keyword_loc
      else
        node.location
      end
      lines = @source.lines
      line_index = loc.start_line - 1
      same_line_prefix = lines.fetch(line_index, "")[0...loc.start_column].to_s
      return true if same_line_prefix.include?(marker)

      cursor = line_index - 1
      loop do
        return false if cursor.negative?

        line = lines.fetch(cursor, "").to_s.strip
        return false if line.empty?
        if line.start_with?("sig ")
          cursor -= 1
          next
        end
        return true if line.include?(marker)
        return false unless line.start_with?("#")

        cursor -= 1
      end
    end

    def namespace_only_class?(node, instance_fields)
      return false unless instance_fields.empty?

      body_nodes = node.body&.body || []
      body_nodes.none? { |stmt| class_body_instance_member?(stmt) }
    end

    def imported_class_extension?(class_name, instance_fields)
      instance_fields.empty? &&
        @imported_class_names.include?(class_name)
    end

    def class_body_instance_member?(stmt)
      case stmt
      when Prism::DefNode
        stmt.receiver.nil?
      when Prism::CallNode
        stmt.receiver.nil? && %w[attr_reader attr_accessor attr_writer].include?(stmt.name.to_s)
      else
        false
      end
    end

    def visit_def_node(node)
      chk = check_parameters!(node.parameters)
      return chk if chk.is_a?(String) && chk.include?("# [UNSUPPORTED:")
      
      name = node.name.to_s
      param_types, sig_return_type, sig_type_params = parse_sig(@current_sig)
      param_names = extract_parameter_names(node)
      type_bindings = infer_function_type_bindings(node.body, param_names, param_types, sig_type_params)
      param_types = param_types.merge(type_bindings)
      @param_types = param_types
      written_vars = collect_written_variables(node.body, param_names)
      local_var_types = collect_local_variable_type_annotations(node.body)
      written_params = param_names & written_vars
      
      @mutable_params = written_params
      
      params = []
      if @current_class && !node.receiver
        self_prefix = mutates_instance_state?(node.body, name) ? "MUTABLE " : ""
        params << "#{self_prefix}self: #{@current_class}"
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
      old_inside_instance_method = @inside_instance_method
      old_inside_class_method = @inside_class_method
      old_function_returns_value = @current_function_returns_value
      old_function_statement_list_depth = @function_statement_list_depth
      old_function_type_bindings = @current_function_type_bindings
      old_current_param_names = @current_param_names
      old_current_function_return_type = @current_function_return_type
      @declared_locals = Set.new(param_names)
      @current_function_can_fail = false
      @local_shapes = {}
      @local_types = param_types.reject { |_param, type| type == "Auto" || type == "Any" }
      @inside_function = true
      @inside_instance_method = !!(@current_class && !node.receiver)
      @inside_class_method = !!(@current_class && node.receiver.is_a?(Prism::SelfNode))
      @current_function_returns_value = name != "initialize" && sig_return_type != "Void"
      @function_statement_list_depth = 0
      @current_function_type_bindings = type_bindings
      @current_param_names = param_names.to_set
      @current_function_return_type = sig_return_type
      
      local_vars_to_declare = collect_predeclared_local_variables(node.body, param_names)
        .select { |var| predeclare_local_variable?(local_var_types[var]) }
        .to_a
        .sort
      local_vars_to_declare.each { |var| @declared_locals << var }

      body_code = with_indent { visit(node.body) }
      
      decls_code = local_vars_to_declare.map do |var|
        "#{indent}  #{predeclared_local_declaration(var, local_var_types[var])}"
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
      @inside_instance_method = old_inside_instance_method
      @inside_class_method = old_inside_class_method
      @current_function_returns_value = old_function_returns_value
      @function_statement_list_depth = old_function_statement_list_depth
      @current_function_type_bindings = old_function_type_bindings
      @current_param_names = old_current_param_names
      @current_function_return_type = old_current_function_return_type
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
      sig_name = if @current_class && !node.receiver
        instance_function_name(@current_class, name)
      else
        clear_function_name(name)
      end
      type_params = (sig_type_params + type_bindings.values).uniq
      type_param_suffix = type_params.empty? ? "" : "<#{type_params.join(', ')}>"

      visibility = if @private_section || @private_method_names.include?(name) || declaration_comment?(node, "ruby-to-clear: private")
        "PRIVATE "
      else
        ""
      end
      effects = function_effects_suffix(node)
      "#{visibility}FN #{sig_name}#{type_param_suffix}(#{params.join(', ')}) RETURNS #{ret_type}#{effects} ->\n#{full_body}\nEND"
    end

    def function_effects_suffix(node)
      return " EFFECTS REENTRANT" if declaration_comment?(node, "ruby-to-clear: effects reentrant")
      return " EFFECTS REENTRANT" if recursive_method_call?(node.body, node.name.to_s)

      ""
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

    def format_consequent(consequent_node, else_context = nil)
      if else_context
        return with_runtime_is_a_else_context(else_context) do
          format_consequent(consequent_node)
        end
      end

      if consequent_node.is_a?(Prism::IfNode)
        runtime_is_a = runtime_is_a_predicate(consequent_node.predicate)
        pred = if runtime_is_a
          "#{runtime_is_a[:receiver_code]} IS_A #{runtime_is_a[:expected_type]} AS #{runtime_is_a[:binding_name]}"
        else
          visit(consequent_node.predicate)
        end
        body = with_indent do
          if runtime_is_a
            with_narrowing_context(runtime_is_a) { visit(consequent_node.statements) }
          else
            visit(consequent_node.statements)
          end
        end
        nested = consequent_node.consequent ? format_consequent(consequent_node.consequent, runtime_is_a) : ""
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

    def collect_instance_method_names(node)
      body_nodes = node.body&.body || []
      body_nodes.each_with_object(Set.new) do |stmt, names|
        next unless stmt.is_a?(Prism::DefNode)
        next if stmt.receiver

        names << clear_function_name(stmt.name.to_s)
      end
    end

    def collect_mutating_instance_method_names(node)
      body_nodes = node.body&.body || []
      method_bodies = body_nodes.each_with_object({}) do |stmt, methods|
        next unless stmt.is_a?(Prism::DefNode)
        next if stmt.receiver

        methods[stmt.name.to_s] = stmt.body
      end

      mutating = method_bodies.each_with_object(Set.new) do |(name, body), names|
        names << name if name == "initialize" || directly_mutates_instance_state?(body)
      end

      changed = true
      while changed
        changed = false
        method_bodies.each do |name, body|
          next if mutating.include?(name)
          next unless calls_mutating_instance_method?(body, mutating)

          mutating << name
          changed = true
        end
      end

      mutating
    end

    def collect_class_method_names(node)
      body_nodes = node.body&.body || []
      body_nodes.each_with_object(Set.new) do |stmt, names|
        next unless stmt.is_a?(Prism::DefNode)
        next unless stmt.receiver.is_a?(Prism::SelfNode)

        names << clear_function_name(stmt.name.to_s)
      end
    end

    def preload_class_instance_metadata(node)
      walk = ->(n) do
        next unless n

        if n.is_a?(Prism::ModuleNode)
          module_name = n.constant_path.location.slice.strip
          @module_function_names[module_name].merge(collect_class_method_names(n))
        elsif n.is_a?(Prism::ClassNode)
          class_name = n.constant_path.location.slice.strip
          body_nodes = n.body&.body || []
          fields = if t_struct_class?(n)
            body_nodes.filter_map { |stmt| t_struct_field(stmt) }.to_h { |field, type, _default| [field, concrete_struct_type(type)] }
          elsif struct_new_superclass?(n.superclass)
            struct_new_field_names(n.superclass).to_h { |field| [field, "Any"] }
          else
            collect_instance_fields(n)
          end

          fields.each do |field, type|
            @class_instance_field_names[class_name] << field
            @class_instance_field_types[class_name][field] = type
          end
          @class_instance_method_names[class_name].merge(collect_instance_method_names(n))
          @class_class_method_names[class_name].merge(collect_class_method_names(n))
          @class_mutating_instance_method_names[class_name].merge(collect_mutating_instance_method_names(n))
        end

        n.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node)
    end

    def duplicate_instance_method_names(node)
      classes_by_method = Hash.new { |hash, key| hash[key] = Set.new }
      @class_instance_method_names.each do |class_name, names|
        names.each { |name| classes_by_method[name] << class_name }
      end

      walk = ->(n, current_class = nil) do
        next unless n

        if n.is_a?(Prism::ClassNode)
          class_name = n.constant_path.location.slice.strip
          n.child_nodes.each { |child| walk.call(child, class_name) if child }
          next
        end

        if current_class && n.is_a?(Prism::DefNode) && !n.receiver
          clear_name = clear_function_name(n.name.to_s)
          classes_by_method[clear_name] << current_class
          next
        end

        n.child_nodes.each { |child| walk.call(child, current_class) if child }
      end
      walk.call(node)
      classes_by_method.each_with_object(Set.new) do |(name, classes), duplicates|
        duplicates << name if classes.size > 1
      end
    end

    def class_function_prefix(class_name)
      prefix = class_name.to_s.gsub("::", "_").gsub(/[^A-Za-z0-9_]/, "_")
      prefix[0] = prefix[0].downcase if prefix[0]
      prefix
    end

    def instance_function_name(class_name, method_name)
      clear_name = clear_function_name(method_name.to_s)
      return clear_name unless @duplicate_instance_method_names.include?(clear_name)

      "#{class_function_prefix(class_name)}__#{clear_name}"
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

      if receiver.is_a?(Prism::LocalVariableReadNode)
        name = receiver.name.to_s
        renamed = @renames[name]
        renamed && static_clear_type_for_receiver(renamed) ? renamed : name
      elsif receiver.respond_to?(:full_name)
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
        name = receiver.name.to_s
        renamed = @renames[name]
        renamed_shape = renamed && (@local_shapes[renamed] || clear_type_shape(static_clear_type_for_receiver(renamed)))
        renamed_shape || @local_shapes[name] || clear_type_shape(static_clear_type_for_receiver(name))
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

    def private_class_method_def_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver.nil? && node.name.to_s == "private_class_method"

      args = node.arguments&.arguments || []
      args.length == 1 && args.first.is_a?(Prism::DefNode)
    end

    def private_class_method_names(node)
      return [] unless node.is_a?(Prism::CallNode)
      return [] unless node.receiver.nil? && node.name.to_s == "private_class_method"

      args = node.arguments&.arguments || []
      return [] if args.any? { |arg| arg.is_a?(Prism::DefNode) }

      args.filter_map do |arg|
        arg.value.to_s if arg.is_a?(Prism::SymbolNode)
      end
    end

    def visibility_section_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver.nil?
      return false unless ["private", "protected", "public"].include?(node.name.to_s)

      args = node.arguments&.arguments || []
      args.empty?
    end

    def ruby_scaffolding_call?(node)
      return false unless node.is_a?(Prism::CallNode)

      name = node.name.to_s
      return true if node.receiver.nil? && ["require", "require_relative", "private", "public", "protected", "attr_reader", "attr_accessor", "attr_writer"].include?(name)
      return true if node.receiver.nil? && name == "private_class_method" && private_class_method_names(node).any?

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
      return true if stripped.start_with?("FN ", "PRIVATE FN ", "STRUCT ", "UNION ", "ENUM ")
      return true if stripped.start_with?("PUB STRUCT ", "PUB UNION ", "PUB ENUM ")
      return true if stripped.match?(/\A(?:MUTABLE\s+)?[A-Za-z_]\w*(?:\s*:\s*[^=]+)?\s*=[^\n]*;\n\s*(?:IF|COMPTIME IF|WHILE|MATCH|PARTIAL MATCH|TEST|WHEN) /)

      false
    end

    def ruby_raise_call?(node)
      return false unless node.name.to_s == "raise"
      return true if node.receiver.nil?

      node.receiver.location.slice.strip == "Kernel"
    end

    def ruby_raise_code(node)
      "panic(#{ruby_raise_message_code(node)})"
    end

    def ruby_raise_message_code(node)
      args = node.arguments ? node.arguments.arguments : []
      return clear_string_literal("Ruby exception raised") if args.empty?

      return visit(args.first) if raise_message_argument?(args.first)
      return visit(args[1]) if args.length >= 2 && raise_message_argument?(args[1])

      if (message_arg = exception_constructor_message_arg(args.first))
        return visit(message_arg)
      end

      clear_string_literal("Ruby exception raised")
    end

    def exception_constructor_message_arg(node)
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "new"

      args = node.arguments ? node.arguments.arguments : []
      args.find { |arg| raise_message_argument?(arg) }
    end

    def raise_message_argument?(node)
      return true if node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode)

      inferred_clear_type(node).to_s == "String"
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
      code = case_expression_code(node)
      return code if code

      return unsupported_expression(node, "Case expressions without a target are not supported") if node.predicate.nil?

      unsupported_expression(unsupported_case_expression_node(node), "Case expression arms must contain one expression")
    end

    def unsupported_case_expression_node(node)
      node.conditions.find { |when_node| !case_expression_statements?(when_node.statements) } ||
        (node.consequent if node.consequent && !case_expression_statements?(node.consequent.statements)) ||
        node
    end

    def case_expression_code(node)
      return nil if node.predicate.nil?

      target = visit(node.predicate)
      arms = []
      node.conditions.each do |w|
        w.conditions.each do |cond|
          cond_val = visit(cond)
          stmt_val = single_expression_from_statements(w.statements)
          return nil unless stmt_val

          stmt_val = match_arm_expression(stmt_val)
          arms << "#{cond_val} -> #{stmt_val},"
        end
      end

      if node.consequent
        else_val = single_expression_from_statements(node.consequent.statements)
        return nil unless else_val

        else_val = match_arm_expression(else_val)
        arms << "DEFAULT -> #{else_val}"
      else
        arms << "DEFAULT -> NIL"
      end

      arms_body = with_indent do
        arms.map { |arm| arm.split("\n").map { |l| "#{indent}#{l}" }.join("\n") }.join("\n")
      end

      "PARTIAL MATCH #{target} START\n#{arms_body}\n#{indent}END"
    end

    def case_expression_statements?(statements)
      statements.is_a?(Prism::StatementsNode) && statements.body.length == 1
    end

    def render_returning_case_node(node)
      if (code = case_expression_code(node))
        return "RETURN #{code}"
      end

      target = node.predicate ? visit(node.predicate) : nil
      render_case_as_condition_chain(node, target, returning: true)
    end

    def if_expression_code(node)
      body = if_expression_branch_code(node, "IF")
      return nil unless body

      "#{body}\n#{indent}END"
    end

    def if_assignment_code(name, node, type = nil)
      body = if_assignment_branch_code(name, node, "IF", type)
      "#{body}\n#{indent}END"
    end

    def if_assignment_branch_code(name, node, keyword, type = nil)
      pred = visit(node.predicate)
      code = "#{indent}#{keyword} #{pred} THEN\n"
      code += with_indent { assignment_branch_statements(name, node.statements) }
      consequent = node.consequent

      if consequent.is_a?(Prism::IfNode)
        code += "\n#{if_assignment_branch_code(name, consequent, 'ELSE_IF', type)}"
      elsif consequent
        code += "\n#{indent}ELSE\n"
        code += with_indent { assignment_branch_statements(name, consequent.statements) }
      else
        code += "\n#{indent}ELSE\n#{indent}  #{name} = #{default_value_for_type(type)};"
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

    def returning_branch_statements(statements)
      render_returning_statements(statements)
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

    def match_arm_expression(code)
      code.to_s.strip.delete_suffix(";")
    end

    def match_statement_arm_body(code)
      stripped = code.to_s.strip
      return stripped if stripped.include?("\n")

      statement_code(stripped)
    end

    def parameter_default_supported?(node)
      !node.is_a?(Prism::ArrayNode) && !node.is_a?(Prism::HashNode)
    end
  end
end
