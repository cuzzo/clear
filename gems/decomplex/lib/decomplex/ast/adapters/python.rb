# frozen_string_literal: true

require_relative "base"

module Decomplex
  module Ast
    class PythonTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
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
        leading_function_statement_with_keyword?(node, "def", PYTHON_LEADING_FUNCTION_WRAPPER_KINDS)
      end

      def leading_function_body(node)
        node.named_children.reverse.find { |child| child.kind == "block" }
      rescue StandardError
        nil
      end

      def leading_owner_target(node)
        return node if PYTHON_LEADING_OWNER_WRAPPER_KINDS.include?(node.kind)

        super
      rescue StandardError
        nil
      end

      def leading_if_target(node)
        if PYTHON_LEADING_IF_WRAPPER_KINDS.include?(node.kind)
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

      private

      def flattened_try_block?(node, clauses:)
        node.kind == "block" &&
          node.children.first&.text == "try" &&
          node.named_children.any? { |child| clauses.include?(child.kind) }
      rescue StandardError
        false
      end

      def python_body_field(node, name)
        return nil unless %w[body consequence].include?(name.to_s)
        return nil unless PYTHON_BODY_FIELD_KINDS.include?(node.kind)

        node.named_children.find { |child| child.kind == "block" }
      rescue StandardError
        nil
      end

      def assignment_operators
        PYTHON_ASSIGNMENT_OPERATORS
      end

      def operator_call_expression_kinds
        super + %w[binary_operator]
      end

      def concatenated_string_wrapper_kinds
        PYTHON_CONCATENATED_STRING_WRAPPER_KINDS
      end

      def dotted_expression_wrapper_kinds
        PYTHON_DOTTED_EXPRESSION_WRAPPER_KINDS
      end
    end

  end
end
