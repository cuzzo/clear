# frozen_string_literal: true

module Decomplex
  module Ast
    UnsupportedLanguageError = Class.new(StandardError)

    # Language-specific syntax-shape decisions live here, before nodes
    # are converted into Decomplex's shared AST vocabulary.
    class TreeSitterNormalizationAdapter
      BINARY_WRAPPER_KINDS = %w[
        binary binary_expression binary_operator boolean_operator comparison_operator
      ].freeze
      CLASS_KINDS = %w[class class_definition class_declaration class_specifier].freeze
      COMMON_ASSIGNMENT_OPERATORS = %w[= += -= *= /= %=].freeze
      RUBY_ASSIGNMENT_OPERATORS = (COMMON_ASSIGNMENT_OPERATORS + %w[**= &&= ||= &= |= ^= <<= >>=]).freeze
      PYTHON_ASSIGNMENT_OPERATORS = (COMMON_ASSIGNMENT_OPERATORS + %w[//= **= @= &= |= ^= <<= >>= :=]).freeze
      LUA_ASSIGNMENT_OPERATORS = %w[=].freeze
      TYPESCRIPT_ASSIGNMENT_OPERATORS = (
        COMMON_ASSIGNMENT_OPERATORS + %w[**= <<= >>= >>>= &= |= ^= &&= ||= ??=]
      ).freeze
      OPERATOR_CALL_OPERATORS = %w[+ - * / % ** | & ^ << >> =~ !~].freeze
      BOOLEAN_EXPRESSION_KINDS = %w[binary binary_expression boolean_operator].freeze
      COMPARISON_EXPRESSION_KINDS = %w[binary binary_expression comparison_operator].freeze
      DOTTED_EXPRESSION_WRAPPER_KINDS = %w[body_statement block_body statement argument_list].freeze
      PYTHON_DOTTED_EXPRESSION_WRAPPER_KINDS = (DOTTED_EXPRESSION_WRAPPER_KINDS + %w[expression_statement]).freeze
      LITERAL_CONTAINER_KINDS = %w[string delimited_symbol regex regex_literal].freeze
      LITERAL_FRAGMENT_KINDS = %w[string_content escape_sequence interpolation string_fragment].freeze
      CASE_ARGUMENT_WHEN_KINDS = %w[
        when switch_case case_clause expression_case case_statement switch_section
        switch_block_statement_group switch_entry when_entry match_arm
      ].freeze
      CASE_ELSE_KINDS = %w[else switch_default].freeze
      CASE_DEFAULT_PATTERN_KINDS = %w[case_pattern match_pattern pattern].freeze
      ADAPTER_FUNCTION_KINDS = %w[
        method function_definition function_declaration method_definition
        method_declaration function_item singleton_method
      ].freeze
      STATEMENT_BLOCK_PARENT_KINDS = %w[
        method_declaration constructor_declaration function_declaration function_body
        if_statement while_statement for_statement enhanced_for_statement try_statement
        catch_clause finally_clause do_statement lambda_expression
      ].freeze
      IDENTIFIER_KINDS = %w[
        identifier simple_identifier property_identifier field_identifier shorthand_property_identifier
      ].freeze
      LEADING_FUNCTION_WRAPPER_KINDS = %w[body_statement statement].freeze
      PYTHON_LEADING_FUNCTION_WRAPPER_KINDS = %w[block].freeze
      LUA_LEADING_FUNCTION_WRAPPER_KINDS = %w[block].freeze
      OWNER_STATEMENT_NESTED_KIND = %w[class class_definition class_declaration module].freeze
      LEADING_OWNER_WRAPPER_KINDS = %w[body_statement statement].freeze
      PYTHON_LEADING_OWNER_WRAPPER_KINDS = %w[block].freeze
      IF_NODE_KINDS = %w[if if_statement if_modifier unless unless_modifier if_expression conditional].freeze
      LEADING_IF_WRAPPER_KINDS = %w[body_statement block block_body statement].freeze
      PYTHON_LEADING_IF_WRAPPER_KINDS = %w[block].freeze
      LUA_LEADING_IF_WRAPPER_KINDS = %w[block].freeze
      LEADING_CASE_WRAPPER_KINDS = %w[body_statement block block_body statement].freeze
      LEADING_LOOP_WRAPPER_KINDS = %w[body_statement block block_body statement].freeze
      RESCUE_BODY_WRAPPER_KINDS = %w[body_statement block_body statement].freeze
      ENSURE_BODY_WRAPPER_KINDS = %w[body_statement block_body statement].freeze
      ARRAY_LITERAL_WRAPPER_KINDS = %w[
        body_statement block block_body statement argument_list expression_statement
      ].freeze
      ARRAY_LITERAL_NODE_KINDS = %w[array list].freeze
      ELEMENT_REFERENCE_WRAPPER_KINDS = %w[
        body_statement block block_body statement expression_statement expression_list
      ].freeze
      ELEMENT_REFERENCE_NODE_KINDS = %w[
        element_reference subscript subscript_expression bracket_index_expression
      ].freeze
      HASH_LITERAL_WRAPPER_KINDS = %w[
        body_statement block block_body statement argument_list expression_statement parenthesized_expression
      ].freeze
      HASH_LITERAL_NODE_KINDS = %w[hash dictionary object table_constructor].freeze
      EMPTY_BODY_WRAPPER_KINDS = %w[body_statement block block_body statement].freeze
      HEREDOC_BODY_WRAPPER_KINDS = %w[body_statement block_body statement then].freeze
      INTERPOLATED_STATEMENT_WRAPPER_KINDS = %w[body_statement block_body statement argument_list].freeze
      CONCATENATED_STRING_WRAPPER_KINDS = %w[body_statement block_body statement argument_list].freeze
      PYTHON_CONCATENATED_STRING_WRAPPER_KINDS = (CONCATENATED_STRING_WRAPPER_KINDS + %w[block expression_statement]).freeze
      CONCATENATED_STRING_NODE_KINDS = %w[chained_string concatenated_string].freeze
      UNWRAP_KINDS = %w[
        parenthesized_expression parenthesized_statements expression_statement statement
        case_pattern match_pattern pattern
      ].freeze
      PYTHON_BODY_FIELD_KINDS = %w[
        elif_clause else_clause for_statement function_definition if_statement
        try_statement while_statement with_statement
      ].freeze
      QUESTION_COLON_TERNARY_KINDS = %w[body_statement block_body statement argument_list conditional].freeze
      TYPESCRIPT_TERNARY_KINDS = (QUESTION_COLON_TERNARY_KINDS + %w[ternary_expression]).freeze

      class << self
        def for(document)
          case document&.language&.to_sym
          when :ruby then RubyTreeSitterNormalizationAdapter.new(document)
          when :python then PythonTreeSitterNormalizationAdapter.new(document)
          when :lua then LuaTreeSitterNormalizationAdapter.new(document)
          when :typescript, :javascript then TypeScriptTreeSitterNormalizationAdapter.new(document)
          else
            raise UnsupportedLanguageError,
                  "unsupported AST normalization language #{document&.language.inspect}"
          end
        end
      end

      attr_reader :document

      def initialize(document)
        @document = document
      end

      def ruby?
        false
      end

      def yield_statement?(_node)
        false
      end

      def super_statement?(_node)
        false
      end

      def explicit_alternative(node)
        node.named_children.find { |child| %w[else else_clause else_statement].include?(child.kind) }
      rescue StandardError
        nil
      end

      def unary_not_expression?(node)
        %w[unary unary_expression].include?(node.kind) && node.text.to_s.lstrip.start_with?("!")
      end

      def unary_minus_expression?(node)
        %w[unary unary_expression].include?(node.kind) && node.text.to_s.lstrip.start_with?("-")
      end

      def binary_operator(node)
        direct_binary_operator(node).to_s
      end

      def class_node?(node)
        CLASS_KINDS.include?(node.kind)
      end

      def unwrap_node?(node)
        UNWRAP_KINDS.include?(node.kind) && node.named_children.size == 1
      end

      def interpolated_string?(node)
        node.kind == "string" && node.named_children.any? { |child| child.kind == "interpolation" }
      end

      def lambda_expression?(node)
        !lambda_target(node).nil?
      rescue StandardError
        false
      end

      def lambda_target(node)
        return node if node.kind == "lambda"

        nil
      rescue StandardError
        nil
      end

      def interpolation_node?(node)
        node.kind == "interpolation"
      rescue StandardError
        false
      end

      def instance_variable?(node)
        node.kind == "instance_variable"
      rescue StandardError
        false
      end

      def global_variable?(node)
        node.kind == "global_variable"
      rescue StandardError
        false
      end

      def member_assignment_target?(_node)
        false
      end

      def identifier_text_node?(_node)
        false
      end

      def literal_fragment_assignment_context?(node)
        parent = node.parent
        return false unless parent.respond_to?(:kind)
        return true if literal_container_kind?(parent)

        literal_fragment_kind?(node) &&
          parent.parent.respond_to?(:kind) &&
          literal_container_kind?(parent.parent)
      rescue StandardError
        false
      end

      def assignment_operator?(text)
        assignment_operators.include?(text.to_s)
      end

      def named_field(node, name)
        node.child_by_field_name(name)
      rescue StandardError
        nil
      end

      def safe_navigation_call?(_node)
        false
      end

      def ternary_statement?(node)
        !ternary_parts(node).nil?
      end

      def ternary_parts(node)
        question_colon_ternary_parts(node, QUESTION_COLON_TERNARY_KINDS)
      end

      def case_argument_list?(_node)
        false
      end

      def case_arm?(node)
        case_arm_kind?(node) && !case_else_arm?(node)
      rescue StandardError
        false
      end

      def case_else_node(node)
        stack = node.named_children.dup
        until stack.empty?
          child = stack.shift
          next unless child.respond_to?(:kind)

          return child if case_else_node?(child)
          next if case_arm_kind?(child)

          stack.concat(child.named_children) unless adapter_function_kind?(child)
        end

        nil
      rescue StandardError
        nil
      end

      def case_else_arm?(_node)
        false
      end

      def case_else_node?(node)
        CASE_ELSE_KINDS.include?(node&.kind) || case_else_arm?(node)
      rescue StandardError
        false
      end

      def leading_function_statement?(_node)
        false
      end

      def leading_function_name(node)
        node.named_children.find { |child| identifier_kind?(child) }&.text
      rescue StandardError
        nil
      end

      def leading_function_body(node)
        node.named_children.reverse.find { |child| child.kind == "body_statement" }
      rescue StandardError
        nil
      end

      def leading_owner_statement?(node)
        target = leading_owner_target(node)
        return false unless target

        %w[class module].include?(target.children.first&.kind.to_s) &&
          target.named_children.size >= 2 &&
          !OWNER_STATEMENT_NESTED_KIND.include?(target.named_children.first.kind)
      rescue StandardError
        false
      end

      def leading_owner_target(node)
        node if LEADING_OWNER_WRAPPER_KINDS.include?(node.kind)
      rescue StandardError
        nil
      end

      def leading_if_statement?(node)
        target = leading_if_target(node)
        return false unless target

        !!(
          %w[if unless].include?(target.children.first&.kind.to_s) &&
          target.named_children.size >= 2 &&
          !IF_NODE_KINDS.include?(target.named_children.first.kind)
        )
      rescue StandardError
        false
      end

      def leading_if_target(node)
        node if LEADING_IF_WRAPPER_KINDS.include?(node.kind)
      rescue StandardError
        nil
      end

      def leading_case_statement?(node)
        target = leading_case_target(node)
        return false unless target

        %w[case match switch].include?(target.children.first&.kind.to_s) && case_arm_descendant?(target)
      rescue StandardError
        false
      end

      def leading_case_target(node)
        node if LEADING_CASE_WRAPPER_KINDS.include?(node.kind)
      rescue StandardError
        nil
      end

      def leading_loop_statement?(node)
        target = leading_loop_target(node)
        return false unless target

        !target.children.first&.named? &&
          %w[while until].include?(target.children.first&.kind.to_s) &&
          target.named_children.size >= 2
      rescue StandardError
        false
      end

      def leading_loop_target(node)
        node if LEADING_LOOP_WRAPPER_KINDS.include?(node.kind)
      rescue StandardError
        nil
      end

      def rescue_body_statement?(node)
        rescue_clauses(node).any?
      rescue StandardError
        false
      end

      def rescue_body_target(node)
        node if RESCUE_BODY_WRAPPER_KINDS.include?(node.kind)
      rescue StandardError
        nil
      end

      def rescue_body_nodes(node)
        target = rescue_body_target(node) || node
        named = target.named_children
        rescue_index = named.index { |child| rescue_clause?(child) }
        return [] unless rescue_index

        named[0...rescue_index]
      rescue StandardError
        []
      end

      def rescue_clauses(node)
        target = rescue_body_target(node)
        return [] unless target

        target.named_children.select { |child| rescue_clause?(child) }
      rescue StandardError
        []
      end

      def rescue_clause_exceptions(node)
        exceptions = node.named_children.find { |child| child.kind == "exceptions" }
        return [] unless exceptions
        return [exceptions] if exceptions.text.to_s.match?(/\A[A-Z]\w*(?:::\w+)*\z/)
        return [exceptions] if exceptions.named_children.empty? && !exceptions.text.to_s.strip.empty?

        exceptions.named_children
      rescue StandardError
        []
      end

      def rescue_clause_exceptions_source(node)
        node.named_children.find { |child| child.kind == "exceptions" }
      rescue StandardError
        nil
      end

      def rescue_clause_exception_variable_name(node)
        var = node.named_children.find { |child| child.kind == "exception_variable" }
        var&.named_children&.find { |child| identifier_kind?(child) }
      rescue StandardError
        nil
      end

      def rescue_clause_exception_variable_source(node)
        node.named_children.find { |child| child.kind == "exception_variable" }
      rescue StandardError
        nil
      end

      def rescue_clause_handler(node)
        node.named_children.reverse.find do |child|
          !%w[exceptions exception_variable comment].include?(child.kind)
        end
      rescue StandardError
        nil
      end

      def ensure_body_statement?(node)
        !ensure_clause(node).nil?
      rescue StandardError
        false
      end

      def ensure_body_target(node)
        node if ENSURE_BODY_WRAPPER_KINDS.include?(node.kind)
      rescue StandardError
        nil
      end

      def ensure_body_nodes(node)
        target = ensure_body_target(node) || node
        named = target.named_children
        ensure_index = named.index { |child| ensure_clause?(child) }
        return [] unless ensure_index

        named[0...ensure_index]
      rescue StandardError
        []
      end

      def ensure_clause(node)
        target = ensure_body_target(node)
        return nil unless target

        target.named_children.find { |child| ensure_clause?(child) }
      rescue StandardError
        nil
      end

      def ensure_clause_body(_node)
        nil
      end

      def array_literal_statement?(node)
        !array_literal_target(node).nil?
      rescue StandardError
        false
      end

      def array_literal_target(node)
        return node if ARRAY_LITERAL_NODE_KINDS.include?(node.kind)
        return nil unless ARRAY_LITERAL_WRAPPER_KINDS.include?(node.kind)
        return node if bracketed?(node, "[", "]")

        child = exact_single_named_child(node, kinds: ARRAY_LITERAL_NODE_KINDS)
        return child if child

        named = node.named_children
        return nil unless named.size == 1 && ARRAY_LITERAL_NODE_KINDS.include?(named.first.kind)

        child = named.first
        stripped = node.text.to_s.strip
        child if stripped == child.text.to_s || stripped == "#{child.text};"
      rescue StandardError
        nil
      end

      def array_literal_values(node)
        target = array_literal_target(node) || node
        target.named_children
      rescue StandardError
        []
      end

      def element_reference_statement?(node)
        !element_reference_target(node).nil?
      rescue StandardError
        false
      end

      def element_reference_target(node)
        return node if ELEMENT_REFERENCE_NODE_KINDS.include?(node.kind)
        return nil unless ELEMENT_REFERENCE_WRAPPER_KINDS.include?(node.kind)

        named = node.named_children
        if named.size == 1 && ELEMENT_REFERENCE_NODE_KINDS.include?(named.first.kind)
          stripped = node.text.to_s.strip
          child = named.first
          return child if stripped == child.text.to_s || stripped == "#{child.text};"
        end

        node if element_reference_shape?(node)
      rescue StandardError
        nil
      end

      def element_reference_receiver(node)
        target = element_reference_target(node) || node
        target.named_children.first
      rescue StandardError
        nil
      end

      def element_reference_arguments(node)
        target = element_reference_target(node) || node
        target.named_children.drop(1)
      rescue StandardError
        []
      end

      def hash_literal_statement?(node)
        !hash_literal_target(node).nil?
      rescue StandardError
        false
      end

      def hash_literal_target(node)
        return node if HASH_LITERAL_NODE_KINDS.include?(node.kind)
        return nil unless HASH_LITERAL_WRAPPER_KINDS.include?(node.kind)
        return nil if statement_block_wrapper?(node)
        return node if bracketed?(node, "{", "}")

        named = node.named_children
        return nil unless named.size == 1

        child = named.first
        return hash_literal_target(child) if node.kind == "parenthesized_expression"

        stripped = node.text.to_s.strip
        if stripped == child.text.to_s || stripped == "#{child.text};"
          return child if HASH_LITERAL_NODE_KINDS.include?(child.kind)
          return hash_literal_target(child) if HASH_LITERAL_WRAPPER_KINDS.include?(child.kind)
        end

        nil
      rescue StandardError
        nil
      end

      def hash_literal_values(node)
        target = hash_literal_target(node) || node
        target.named_children
      rescue StandardError
        []
      end

      def empty_body_statement?(node)
        EMPTY_BODY_WRAPPER_KINDS.include?(node.kind) &&
          node.named_children.empty? &&
          node.text.to_s.strip.empty?
      rescue StandardError
        false
      end

      def heredoc_body_statement?(node)
        HEREDOC_BODY_WRAPPER_KINDS.include?(node.kind) &&
          node.named_children.any? { |child| child.kind == "heredoc_body" }
      rescue StandardError
        false
      end

      def heredoc_call_for_body?(_node)
        false
      end

      def interpolated_statement?(node)
        INTERPOLATED_STATEMENT_WRAPPER_KINDS.include?(node.kind) &&
          node.named_children.any? { |child| child.kind == "interpolation" }
      rescue StandardError
        false
      end

      def concatenated_string_statement?(node)
        !concatenated_string_target(node).nil?
      rescue StandardError
        false
      end

      def concatenated_string_target(node)
        return node if concatenated_string_node?(node)
        return nil unless concatenated_string_wrapper_kinds.include?(node.kind)

        named = node.named_children
        return node if named.size > 1 && named.all? { |child| child.kind == "string" }
        return named.first if named.size == 1 && concatenated_string_node?(named.first)

        nil
      rescue StandardError
        nil
      end

      def zero_child_identifier_call?(_node)
        false
      end

      def operator_call_expression?(node)
        operator_call_expression_kinds.include?(node.kind) &&
          OPERATOR_CALL_OPERATORS.include?(binary_operator(node))
      rescue StandardError
        false
      end

      def boolean_expression_kind?(node)
        boolean_expression_kinds.include?(node.kind)
      rescue StandardError
        false
      end

      def comparison_expression_kind?(node)
        comparison_expression_kinds.include?(node.kind)
      rescue StandardError
        false
      end

      def dotted_expression_wrapper?(node)
        dotted_expression_wrapper_kinds.include?(node.kind)
      rescue StandardError
        false
      end

      private

      def assignment_operators
        COMMON_ASSIGNMENT_OPERATORS
      end

      def operator_call_expression_kinds
        %w[binary binary_expression]
      end

      def boolean_expression_kinds
        BOOLEAN_EXPRESSION_KINDS
      end

      def comparison_expression_kinds
        COMPARISON_EXPRESSION_KINDS
      end

      def dotted_expression_wrapper_kinds
        DOTTED_EXPRESSION_WRAPPER_KINDS
      end

      def concatenated_string_wrapper_kinds
        CONCATENATED_STRING_WRAPPER_KINDS
      end

      def concatenated_string_node?(node)
        CONCATENATED_STRING_NODE_KINDS.include?(node&.kind) &&
          node.named_children.size > 1 &&
          node.named_children.all? { |child| child.kind == "string" }
      end

      def direct_binary_operator(node)
        node.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text
      rescue StandardError
        nil
      end

      def question_colon_ternary_parts(node, kinds)
        return nil unless kinds.include?(node.kind)
        return nil unless node.children.any? { |child| !child.named? && child.text == "?" }
        return nil unless node.children.any? { |child| !child.named? && child.text == ":" }

        children = node.named_children
        return nil unless children.size >= 3

        children.first(3)
      rescue StandardError
        nil
      end

      def leading_function_statement_with_keyword?(node, keyword, wrapper_kinds)
        wrapper_kinds.include?(node.kind) &&
          node.children.first&.kind.to_s == keyword &&
          node.named_children.any? { |child| identifier_kind?(child) }
      rescue StandardError
        false
      end

      def identifier_kind?(node)
        IDENTIFIER_KINDS.include?(node&.kind)
      end

      def exact_single_named_child(node, kinds:)
        children = node.named_children
        return nil unless children.size == 1

        child = children.first
        return nil unless kinds.include?(child.kind)
        return nil unless node.text.to_s == child.text.to_s

        child
      rescue StandardError
        nil
      end

      def case_arm_kind?(node)
        CASE_ARGUMENT_WHEN_KINDS.include?(node&.kind)
      end

      def default_case_pattern?(node)
        pattern = node.named_children.find { |child| CASE_DEFAULT_PATTERN_KINDS.include?(child.kind) }
        pattern&.text.to_s.strip == "_"
      rescue StandardError
        false
      end

      def adapter_function_kind?(node)
        ADAPTER_FUNCTION_KINDS.include?(node&.kind)
      end

      def statement_block_wrapper?(node)
        node.kind == "block" && STATEMENT_BLOCK_PARENT_KINDS.include?(node.parent&.kind)
      rescue StandardError
        false
      end

      def case_arm_descendant?(node)
        stack = node.named_children.dup
        until stack.empty?
          child = stack.shift
          next unless child.respond_to?(:kind)
          return true if CASE_ARGUMENT_WHEN_KINDS.include?(child.kind)

          stack.concat(child.named_children)
        end

        false
      rescue StandardError
        false
      end

      def literal_container_kind?(node)
        LITERAL_CONTAINER_KINDS.include?(node&.kind)
      end

      def literal_fragment_kind?(node)
        LITERAL_FRAGMENT_KINDS.include?(node&.kind)
      end

      def rescue_clause?(node)
        node&.kind == "rescue"
      end

      def ensure_clause?(node)
        node&.kind == "ensure"
      end

      def bracketed?(node, opening, closing)
        node.children.first&.text == opening && node.children.last&.text == closing
      rescue StandardError
        false
      end

      def element_reference_shape?(node)
        node.children.first&.text != "[" &&
          node.children.any? { |child| !child.named? && child.text == "[" } &&
          node.children.any? { |child| !child.named? && child.text == "]" } &&
          node.named_children.size >= 2 &&
          node.named_children.none? { |child| %w[block do_block].include?(child.kind) }
      rescue StandardError
        false
      end

      def descendant(node, kinds:)
        stack = node&.named_children.to_a
        until stack.empty?
          child = stack.shift
          next unless child.respond_to?(:kind)
          return child if kinds.include?(child.kind)

          stack.concat(child.named_children)
        end

        nil
      end
    end

  end
end
