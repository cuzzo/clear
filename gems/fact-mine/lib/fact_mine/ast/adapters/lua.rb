# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class LuaTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      ASSIGNMENT_OPERATORS = %w[=].freeze
      LEADING_FUNCTION_WRAPPER_KINDS = %w[block].freeze
      LEADING_IF_WRAPPER_KINDS = %w[block].freeze

      def explicit_alternative(node)
        node.named_children.find { |child| %w[elseif_statement else else_statement].include?(child.kind) }
      rescue StandardError
        nil
      end

      def unary_minus_expression?(node)
        super ||
          (node.kind == "expression_list" && node.children.first&.text == "-" && node.named_children.size == 1)
      rescue StandardError
        false
      end

      def binary_operator(node)
        direct = direct_binary_operator(node)
        return direct.to_s if direct

        child = exact_single_named_child(node, kinds: BINARY_WRAPPER_KINDS)
        child ? binary_operator(child) : ""
      end

      def unwrap_node?(node)
        super ||
          (node.kind == "expression_list" &&
            node.named_children.size == 1 &&
            node.children.first&.text == "(" &&
            node.children.last&.text == ")")
      rescue StandardError
        false
      end

      def leading_function_statement?(node)
        leading_function_statement_with_keyword?(node, "function", LEADING_FUNCTION_WRAPPER_KINDS)
      end

      def leading_function_body(node)
        node.named_children.reverse.find { |child| child.kind == "block" }
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

      def special_if_statement?(node)
        node.kind == "if_statement"
      rescue StandardError
        false
      end

      def normalize_special_if(node, helpers:)
        named = node.named_children
        cond = named.first
        positive = named.find { |child| child.kind == "block" }
        alternatives = named.drop_while { |child| child != positive }.drop(1)
        helpers.__send__(
          :wrap,
          :IF,
          children: [
            helpers.__send__(:normalize_node, cond),
            helpers.__send__(:normalize_body, positive),
            normalize_lua_alternatives(alternatives, helpers: helpers)
          ],
          source: node
        )
      end

      def array_literal_target(node)
        if node.kind == "block"
          named = node.named_children
          if named.size == 2 && named.first.kind == "identifier" && named.first.text.to_s.empty?
            target = lua_positional_table_arguments(named[1])
            return target if target
          end
        end

        target = lua_positional_table_arguments(node)
        return target if target

        super
      rescue StandardError
        nil
      end

      def hash_literal_target(node)
        target = lua_keyed_table_arguments(node)
        return target if target

        super
      rescue StandardError
        nil
      end

      def hash_literal_values(node)
        target = hash_literal_target(node) || node
        return target.named_children if target.kind == "arguments"

        super
      rescue StandardError
        []
      end

      def identifier_text_node?(node)
        %w[variable_list expression_list].include?(node.kind) &&
          node.text.to_s.match?(/\A[A-Za-z_]\w*\z/)
      rescue StandardError
        false
      end

      def member_assignment_target?(node)
        return false unless node.kind == "variable_list"

        node.named_children.size == 2 &&
          node.children.any? { |child| !child.named? && child.text == "." }
      rescue StandardError
        false
      end

      def literal_fragment_assignment_context?(node)
        return true if super

        literal_fragment_kind?(node) && node.parent&.kind == "expression_list"
      rescue StandardError
        false
      end

      def lambda_target(node)
        return node if node.kind == "function_definition"

        if node.kind == "expression_list"
          return node if node.children.first&.kind == "function" &&
            node.named_children.any? { |child| child.kind == "block" }

          named = node.named_children
          return named.first if named.size == 1 && named.first.kind == "function_definition"
        end

        super
      rescue StandardError
        nil
      end

      private

      def normalize_lua_alternatives(nodes, helpers:)
        return nil if nodes.empty?

        current = nodes.first
        rest = nodes.drop(1)
        if current.kind == "elseif_statement"
          cond = current.named_children.first
          positive = current.named_children.find { |child| child.kind == "block" }
          return helpers.__send__(
            :wrap,
            :IF,
            children: [
              helpers.__send__(:normalize_node, cond),
              helpers.__send__(:normalize_body, positive),
              normalize_lua_alternatives(rest, helpers: helpers)
            ],
            source: current
          )
        end
        return helpers.__send__(:normalize_else_or_branch, current) if current.kind == "else_statement"

        normalize_lua_alternatives(rest, helpers: helpers)
      end

      def lua_positional_table_arguments(node)
        return nil unless node&.kind == "arguments"
        return nil unless bracketed?(node, "{", "}")

        fields = node.named_children
        return nil if fields.empty?
        return nil unless fields.all? { |field| field.kind == "field" && field.named_children.size <= 1 }

        node
      end

      def lua_keyed_table_arguments(node)
        if node&.kind == "block"
          named = node.named_children
          if named.size == 2 && named.first.kind == "identifier" && named.first.text.to_s.empty?
            return lua_keyed_table_arguments(named[1])
          end
        end

        return nil unless node&.kind == "arguments"
        return nil unless bracketed?(node, "{", "}")

        fields = node.named_children
        return node if fields.empty?
        return nil if fields.all? { |field| field.kind == "field" && field.named_children.size <= 1 }

        node
      end

      private

      def assignment_operators
        ASSIGNMENT_OPERATORS
      end

      def operator_call_expression_kinds
        super + %w[expression_list]
      end

      def boolean_expression_kinds
        super + %w[expression_list]
      end

      def comparison_expression_kinds
        super + %w[expression_list]
      end
    end

  end
end
