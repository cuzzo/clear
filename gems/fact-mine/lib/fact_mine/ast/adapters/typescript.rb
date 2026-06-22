# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class TypeScriptTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      ASSIGNMENT_OPERATORS = (
        COMMON_ASSIGNMENT_OPERATORS + %w[**= <<= >>= >>>= &= |= ^= &&= ||= ??=]
      ).freeze
      TERNARY_KINDS = (QUESTION_COLON_TERNARY_KINDS + %w[ternary_expression]).freeze

      def explicit_alternative(node)
        node.named_children.find { |child| %w[else else_clause].include?(child.kind) }
      rescue StandardError
        nil
      end

      def safe_navigation_call?(node)
        super ||
          node.children.any? { |child| child.kind == "optional_chain" && child.text.to_s == "?." } ||
          (node.kind == "call_expression" && node.named_children.any? { |child| safe_navigation_call?(child) })
      rescue StandardError
        false
      end

      def ternary_parts(node)
        question_colon_ternary_parts(node, TERNARY_KINDS)
      end

      def interpolated_string?(node)
        super ||
          (node.kind == "template_string" &&
            node.named_children.any? { |child| child.kind == "template_substitution" })
      end

      def lambda_target(node)
        return node if %w[arrow_function function_expression].include?(node.kind)

        super
      rescue StandardError
        nil
      end

      def interpolation_node?(node)
        super || node.kind == "template_substitution"
      rescue StandardError
        false
      end

      def rescue_body_target(node)
        return node if node.kind == "try_statement"

        if node.kind == "statement_block"
          child = exact_single_named_child(node, kinds: %w[try_statement])
          return child if child
        end

        super
      rescue StandardError
        nil
      end

      def rescue_body_nodes(node)
        target = rescue_body_target(node) || node
        return super unless target.kind == "try_statement"

        target.named_children.take_while { |child| !%w[catch_clause finally_clause].include?(child.kind) }
      rescue StandardError
        []
      end

      def rescue_clauses(node)
        target = rescue_body_target(node)
        return [] unless target

        target.named_children.select { |child| child.kind == "catch_clause" }
      rescue StandardError
        []
      end

      def rescue_clause_exception_variable_name(node)
        node.named_children.find { |child| IDENTIFIER_KINDS.include?(child.kind) }
      rescue StandardError
        nil
      end

      def rescue_clause_exception_variable_source(node)
        rescue_clause_exception_variable_name(node)
      rescue StandardError
        nil
      end

      def rescue_clause_handler(node)
        node.named_children.reverse.find { |child| child.kind == "statement_block" }
      rescue StandardError
        nil
      end

      def ensure_body_target(node)
        return node if node.kind == "try_statement"

        if node.kind == "statement_block"
          child = exact_single_named_child(node, kinds: %w[try_statement])
          return child if child
        end

        super
      rescue StandardError
        nil
      end

      def ensure_body_nodes(node)
        target = ensure_body_target(node) || node
        return super unless target.kind == "try_statement"

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
        node.named_children.reverse.find { |child| child.kind == "statement_block" }
      rescue StandardError
        nil
      end

      def empty_body_statement?(node)
        super ||
          (node.kind == "statement_block" && node.named_children.empty? && node.text.to_s.strip == "{}")
      rescue StandardError
        false
      end

      private

      def assignment_operators
        ASSIGNMENT_OPERATORS
      end
    end

  end
end
