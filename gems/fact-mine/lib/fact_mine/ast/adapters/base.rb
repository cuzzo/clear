# frozen_string_literal: true

module FactMine
  module Ast
    UnsupportedLanguageError = Class.new(StandardError)

    # Language-specific syntax-shape decisions live here, before nodes
    # are converted into FactMine's shared AST vocabulary.
    class TreeSitterNormalizationAdapter
      BINARY_WRAPPER_KINDS = %w[
        binary binary_expression binary_operator boolean_operator comparison_operator
      ].freeze
      CLASS_KINDS = %w[class class_definition class_declaration class_specifier].freeze
      COMMON_ASSIGNMENT_OPERATORS = %w[= += -= *= /= %=].freeze
      OPERATOR_CALL_OPERATORS = %w[+ - * / % ** | & ^ << >> =~ !~].freeze
      BOOLEAN_EXPRESSION_KINDS = %w[binary binary_expression boolean_operator conjunction_expression].freeze
      COMPARISON_EXPRESSION_KINDS = %w[binary binary_expression comparison_operator].freeze
      DOTTED_EXPRESSION_WRAPPER_KINDS = %w[body_statement block_body statement argument_list].freeze
      LITERAL_CONTAINER_KINDS = %w[string delimited_symbol regex regex_literal].freeze
      LITERAL_FRAGMENT_KINDS = %w[string_content escape_sequence interpolation string_fragment].freeze
      CASE_ARGUMENT_WHEN_KINDS = %w[
        when switch_case case_clause expression_case case_statement switch_section
        switch_block_statement_group switch_entry when_entry match_arm
      ].freeze
      CASE_ELSE_KINDS = %w[default_case default_statement else switch_default].freeze
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
      OWNER_STATEMENT_NESTED_KIND = %w[class class_definition class_declaration module].freeze
      LEADING_OWNER_WRAPPER_KINDS = %w[body_statement statement].freeze
      IF_NODE_KINDS = %w[if if_statement if_modifier unless unless_modifier if_expression conditional].freeze
      LEADING_IF_WRAPPER_KINDS = %w[body_statement block block_body expression_statement statement].freeze
      LEADING_CASE_WRAPPER_KINDS = %w[body_statement block block_body statement].freeze
      LEADING_LOOP_WRAPPER_KINDS = %w[body_statement block block_body expression_statement statement].freeze
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
      CONCATENATED_STRING_NODE_KINDS = %w[chained_string concatenated_string].freeze
      UNWRAP_KINDS = %w[
        parenthesized_expression parenthesized_statements expression_statement statement
        case_pattern match_pattern pattern
      ].freeze
      QUESTION_COLON_TERNARY_KINDS = %w[body_statement block_body statement argument_list conditional].freeze

      attr_reader :document

      def initialize(document)
        @document = document
      end

      def yield_statement?(_node)
        false
      end

      def identifier_yield?(_node)
        false
      end

      def super_statement?(_node)
        false
      end

      def with_local_scope(_node, reset: false)
        yield
      end

      def local_name?(_name)
        false
      end

      def definition_identifier?(_node, helpers:)
        false
      end

      def implicit_call_identifier?(node, helpers:)
        return false unless helpers.__send__(:local_identifier?, node)
        return false if helpers.__send__(:assignment_lhs?, node)
        return false if helpers.__send__(:assignment_rhs?, node)

        parent = helpers.__send__(:parent_node, node)
        return false unless helpers.__send__(:ts_node?, parent)
        return false if %w[method method_parameters parameter_list argument_list arguments].include?(parent.kind)
        return false if helpers.__send__(:member_read_node?, parent)
        return false if helpers.__send__(:dotted_expression?, parent)

        return true if %w[body_statement block_body then].include?(parent.kind) &&
                       helpers.__send__(:parent_named_child?, parent, node)
        return true if %w[if_modifier unless_modifier].include?(parent.kind) &&
                       helpers.__send__(:same_ts_node?, parent.named_children.first, node)

        false
      end

      def logical_operator_assignment?(_left, _operator, helpers:)
        false
      end

      def explicit_alternative(node)
        alternative = node.named_children.find { |child| %w[else else_clause else_statement].include?(child.kind) }
        return nil unless alternative
        return alternative unless alternative.kind == "else" && alternative.named_children.empty?

        index = node.named_children.index(alternative)
        node.named_children[index.to_i + 1] || alternative
      rescue StandardError
        nil
      end

      def branch_child_fallback?
        true
      end

      def special_if_statement?(_node)
        false
      end

      def normalize_special_if(_node, helpers:)
        nil
      end

      def typed_assignment_statement?(_node)
        false
      end

      def normalize_typed_assignment_statement(_node, helpers:)
        nil
      end

      def normalize_parameters(_node, helpers:)
        nil
      end

      def normalize_block_parameters(_block, helpers:)
        nil
      end

      def text_loop_statement?(node)
        %w[expression_statement labeled_statement].include?(node.kind) &&
          node.text.to_s.lstrip.start_with?("for ")
      rescue StandardError
        false
      end

      def normalize_text_loop_statement(node, helpers:)
        body = helpers.__send__(:block_child, node) ||
               node.named_children.reverse.find { |child| child.kind == "block_expression" }
        cond = node.named_children.find { |child| child != body }
        helpers.__send__(
          :wrap,
          :FOR,
          children: [helpers.__send__(:normalize_node, cond), helpers.__send__(:normalize_body, body)],
          source: node
        )
      end

      def normalize_operator_call_override(_node, _left, _operator, _right, helpers:)
        nil
      end

      def element_reference_override(_node, _receiver, _arguments, helpers:)
        nil
      end

      def hash_pair_value_override(_key, _value, helpers:)
        nil
      end

      def argument_list_call?(_node)
        false
      end

      def argument_list_element_reference?(_node)
        false
      end

      def callable_yield?(_function)
        false
      end

      def callable_constant_as_function?(_function, helpers:)
        false
      end

      def elide_single_symbol_return?(_children, _elide_symbol)
        false
      end

      def case_pattern_prefix(_node)
        []
      end

      def normalize_case_pattern_override(_pattern, helpers:)
        nil
      end

      def argument_list_unary_not?(_node)
        false
      end

      def normalize_dynamic_scope(node, helpers:)
        node
      end

      def inline_def_source?(_source)
        false
      end

      def normalize_tail_returns(node, helpers:)
        node
      end

      def normalize_implicit_nil_body(node, helpers:)
        node
      end

      def inline_parameter_begin(_function_node)
        nil
      end

      def local_or_call_for_name(name, source, helpers:)
        helpers.__send__(:wrap, :LVAR, children: [name], source: source)
      end

      def call_arguments_from_text?(_node)
        false
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
          %w[while until for].include?(target.children.first&.kind.to_s) &&
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
