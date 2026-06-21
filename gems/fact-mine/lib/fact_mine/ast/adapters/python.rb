# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class PythonTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      ASSIGNMENT_OPERATORS = (COMMON_ASSIGNMENT_OPERATORS + %w[//= **= @= &= |= ^= <<= >>= :=]).freeze
      DOTTED_EXPRESSION_WRAPPER_KINDS = (
        TreeSitterNormalizationAdapter::DOTTED_EXPRESSION_WRAPPER_KINDS + %w[expression_statement]
      ).freeze
      LEADING_FUNCTION_WRAPPER_KINDS = %w[block].freeze
      LEADING_OWNER_WRAPPER_KINDS = %w[block].freeze
      LEADING_IF_WRAPPER_KINDS = %w[block].freeze
      CONCATENATED_STRING_WRAPPER_KINDS = (
        TreeSitterNormalizationAdapter::CONCATENATED_STRING_WRAPPER_KINDS + %w[block expression_statement]
      ).freeze
      BODY_FIELD_KINDS = %w[
        elif_clause else_clause for_statement function_definition if_statement
        try_statement while_statement with_statement
      ].freeze

      def yield_statement?(node)
        (%w[body_statement block block_body expression_statement statement].include?(node.kind) &&
          node.children.first&.text == "yield")
      rescue StandardError
        false
      end

      def explicit_alternative(node)
        node.named_children.find { |child| %w[elif_clause else else_clause].include?(child.kind) }
      rescue StandardError
        nil
      end

      def case_else_arm?(node)
        node.kind == "case_clause" && default_case_pattern?(node)
      rescue StandardError
        false
      end

      def named_field(node, name)
        super || python_body_field(node, name)
      end

      def leading_function_statement?(node)
        leading_function_statement_with_keyword?(node, "def", LEADING_FUNCTION_WRAPPER_KINDS)
      end

      def leading_function_body(node)
        node.named_children.reverse.find { |child| child.kind == "block" }
      rescue StandardError
        nil
      end

      def leading_owner_target(node)
        return node if LEADING_OWNER_WRAPPER_KINDS.include?(node.kind)

        super
      rescue StandardError
        nil
      end

      def leading_if_target(node)
        if LEADING_IF_WRAPPER_KINDS.include?(node.kind)
          child = exact_single_named_child(node, kinds: %w[if_statement])
          return child if child
        end

        super
      end

      def rescue_body_target(node)
        return node if node.kind == "try_statement"
        return node if flattened_try_block?(node, clauses: %w[except_clause])

        if node.kind == "block"
          child = exact_single_named_child(node, kinds: %w[try_statement])
          return child if child
        end

        super
      rescue StandardError
        nil
      end

      def rescue_body_nodes(node)
        target = rescue_body_target(node) || node
        return super unless target.kind == "try_statement" || flattened_try_block?(target, clauses: %w[except_clause])

        target.named_children.take_while { |child| !%w[except_clause finally_clause].include?(child.kind) }
      rescue StandardError
        []
      end

      def rescue_clauses(node)
        target = rescue_body_target(node)
        return [] unless target

        target.named_children.select { |child| child.kind == "except_clause" }
      rescue StandardError
        []
      end

      def rescue_clause_exceptions(node)
        pattern = node.named_children.find { |child| !%w[block comment].include?(child.kind) }
        return [] unless pattern
        return [pattern] unless pattern.kind == "as_pattern"

        exception = pattern.named_children.find { |child| child.kind != "as_pattern_target" }
        exception ? [exception] : []
      rescue StandardError
        []
      end

      def rescue_clause_exceptions_source(node)
        rescue_clause_exceptions(node).first
      rescue StandardError
        nil
      end

      def rescue_clause_exception_variable_name(node)
        pattern = node.named_children.find { |child| child.kind == "as_pattern" }
        descendant(pattern, kinds: %w[as_pattern_target])
      rescue StandardError
        nil
      end

      def rescue_clause_exception_variable_source(node)
        rescue_clause_exception_variable_name(node)
      rescue StandardError
        nil
      end

      def rescue_clause_handler(node)
        node.named_children.reverse.find { |child| child.kind == "block" }
      rescue StandardError
        nil
      end

      def ensure_body_target(node)
        return node if node.kind == "try_statement"
        return node if flattened_try_block?(node, clauses: %w[finally_clause])

        if node.kind == "block"
          child = exact_single_named_child(node, kinds: %w[try_statement])
          return child if child
        end

        super
      rescue StandardError
        nil
      end

      def ensure_body_nodes(node)
        target = ensure_body_target(node) || node
        return super unless target.kind == "try_statement" || flattened_try_block?(target, clauses: %w[finally_clause])

        target.named_children.take_while { |child| child.kind != "finally_clause" }
      rescue StandardError
        []
      end

      def ensure_clause(node)
        target = ensure_body_target(node)
        return nil unless target

        target.named_children.find { |child| child.kind == "finally_clause" }
      rescue StandardError
        nil
      end

      def ensure_clause_body(node)
        node.named_children.reverse.find { |child| child.kind == "block" }
      rescue StandardError
        nil
      end

      def ternary_parts(node)
        return nil unless node.kind == "conditional_expression"

        children = node.named_children
        return nil unless children.size >= 3

        [children[1], children[0], children[2]]
      rescue StandardError
        nil
      end

      def unary_minus_expression?(node)
        (%w[unary unary_expression unary_operator].include?(node.kind) && node.text.to_s.lstrip.start_with?("-"))
      end

      def empty_body_statement?(node)
        super ||
          (node.kind == "block" && node.named_children.empty? && node.text.to_s.strip == "pass") ||
          node.kind == "pass_statement"
      rescue StandardError
        false
      end

      def typed_assignment_statement?(node)
        return false unless %w[block expression_statement statement].include?(node.kind)
        return false if node.kind == "block" && node.text.to_s.lines.size > 1
        return false unless node.children.any? { |child| !child.named? && child.text == ":" }

        node.named_children.size >= 2
      rescue StandardError
        false
      end

      def normalize_typed_assignment_statement(node, helpers:)
        left = node.named_children.first
        right = node.children.any? { |child| !child.named? && child.text == "=" } ? node.named_children.last : nil
        normalized_right = helpers.__send__(:normalize_node, right)
        helpers.__send__(:assignment_target, left, normalized_right, source: node) || helpers.__send__(
          :wrap,
          :LASGN,
          children: [helpers.__send__(:target_name, left), normalized_right],
          source: node
        )
      end

      def special_statement?(node)
        return true if %w[for_statement with_statement].include?(node.kind)
        return false unless node.kind == "block"

        text = node.text.to_s.lstrip
        text.start_with?("for ") || text.start_with?("with ")
      rescue StandardError
        false
      end

      def normalize_special_statement(node, helpers:)
        text = node.text.to_s.lstrip
        if node.kind == "for_statement" || text.start_with?("for ")
          normalize_python_for_statement(node, helpers: helpers)
        elsif node.kind == "with_statement" || text.start_with?("with ")
          normalize_python_with_statement(node, helpers: helpers)
        end
      end

      private

      def normalize_python_for_statement(node, helpers:)
        named = node.named_children
        body = named.reverse.find { |child| child.kind == "block" }
        targets = named.take_while { |child| child != body }
        target = targets[0]
        iterable = targets[1]
        target_name, iterable_name = python_for_header_names(node)
        helpers.__send__(
          :wrap,
          :FOR,
          children: [
            python_loop_name_node(target || target_name, helpers: helpers, source: node),
            python_loop_name_node(iterable || iterable_name, helpers: helpers, source: node),
            helpers.__send__(:normalize_body, body)
          ],
          source: node
        )
      end

      def python_loop_name_node(node, helpers:, source: nil)
        return nil unless node

        text = node.respond_to?(:text) ? node.text.to_s : node.to_s
        helpers.__send__(:wrap, :LVAR, children: [text], source: source || node)
      end

      def python_for_header_names(node)
        header = node.text.to_s.lines.first.to_s
        match = header.match(/\bfor\s+([A-Za-z_]\w*)\s+in\s+([A-Za-z_]\w*)\s*:/)
        match ? [match[1], match[2]] : [nil, nil]
      end

      def normalize_python_with_statement(node, helpers:)
        named = node.named_children
        clause = named.find { |child| child.kind == "with_clause" }
        body = named.reverse.find { |child| child.kind == "block" }
        helpers.__send__(
          :wrap,
          :WITH,
          children: [
            helpers.__send__(:normalize_node, clause),
            helpers.__send__(:normalize_body, body)
          ],
          source: node
        )
      end

      def flattened_try_block?(node, clauses:)
        node.kind == "block" &&
          node.children.first&.text == "try" &&
          node.named_children.any? { |child| clauses.include?(child.kind) }
      rescue StandardError
        false
      end

      def python_body_field(node, name)
        return nil unless %w[body consequence].include?(name.to_s)
        return nil unless BODY_FIELD_KINDS.include?(node.kind)

        node.named_children.find { |child| child.kind == "block" }
      rescue StandardError
        nil
      end

      def assignment_operators
        ASSIGNMENT_OPERATORS
      end

      def operator_call_expression_kinds
        super + %w[binary_operator]
      end

      def concatenated_string_wrapper_kinds
        CONCATENATED_STRING_WRAPPER_KINDS
      end

      def dotted_expression_wrapper_kinds
        DOTTED_EXPRESSION_WRAPPER_KINDS
      end
    end

  end
end
