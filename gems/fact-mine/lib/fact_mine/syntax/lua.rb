# frozen_string_literal: true

module FactMine
  module Syntax
    LUA_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnil\b/].freeze,
      type_guard_patterns: [
        /\btype\s*\(/,
        /\bnil\b/,
        /\b(?:pcall|xpcall)\s*\(/
      ].freeze,
      diagnostic_patterns: [
        /\berror\s*\(/,
        /\bassert\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:nil|true|false|0|1|break)\s*;?\z/,
        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class LuaSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_declaration].freeze
      CALL_NODE_KINDS = %w[function_call method_call].freeze
      ADJACENT_CALL_NODE_KINDS = %w[dot_index_expression method_index_expression identifier expression_list variable_list].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = %w[block].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[variable_declaration].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[variable_declaration variable_list].freeze
      DECLARATION_ASSIGNMENT_NODE_KINDS = %w[assignment_statement].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameters variable_declaration function_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_statement].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_statement].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[function_call expression_list return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_statement].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      IF_NODE_KINDS = %w[if_statement].freeze
      HIDDEN_IF_WRAPPER_NODE_KINDS = %w[block].freeze
      HIDDEN_IF_TOKEN_KINDS = %w[if].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[and &&].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      BOOLEAN_WRAPPER_NODE_KINDS = %w[expression_list].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[arguments].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[pub public].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      EXPRESSION_LIST_NODE_KINDS = %w[expression_list].freeze
      FIELD_LIKE_NODE_KINDS = %w[dot_index_expression variable_list].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def function_name(node)
        lua_method_name(node) || super
      end

      def receiver_owner_name(node)
        lua_method_owner_name(node) || super
      end

      def call_target(document, node)
        lua_method_call_target(node) ||
          lua_expression_list_call_target(node) ||
          lua_adjacent_member_call_target(node) ||
          super
      end

      def state_read_target(node)
        target = lua_expression_list_member_target(node) || lua_single_return_member_target(node) || super
        return nil if target && target[:receiver] == "_" && target[:field] == "_"

        target
      end

      def generated_prelude?(document, node)
        return false unless line(node) == 1

        first_line = document.lines.first.to_s
        first_line.include?("_tl_compat") && first_line.include?("compat53.module")
      end

      private

      def boolean_container?(node)
        return true if boolean_expression_list?(node, "and")

        super
      end

      def lua_method_name(node)
        method = lua_method_index_expression(node)
        return nil unless method

        method.named_children.last&.text
      end

      def lua_method_owner_name(node)
        method = lua_method_index_expression(node)
        return nil unless method

        method.named_children.first&.text
      end

      def lua_method_index_expression(node)
        return nil unless node.kind == "function_declaration"

        node.named_children.find { |child| child.kind == "method_index_expression" }
      end

      def lua_expression_list_call_target(node)
        return nil unless node.kind == "expression_list"

        callee = node.named_children.find { |child| field_like_node?(child) }
        args = node.named_children.find { |child| child.kind == "arguments" }
        return nil unless callee && args

        target_from_callee(callee).merge(arguments: args.named_children.map { |child| normalize_text(child.text) })
      rescue StandardError
        nil
      end

      def lua_method_call_target(node)
        if node.kind == "function_call"
          callee = node.named_children.find { |child| child.kind == "method_index_expression" }
          args = node.named_children.find { |child| child.kind == "arguments" }
          return nil unless callee && args

          return lua_method_target(callee, args)
        end

        return nil if call_node_ancestor?(node)
        return nil unless node.kind == "method_index_expression"

        args = next_sibling(node)
        return nil unless args&.kind == "arguments"

        lua_method_target(node, args)
      rescue StandardError
        nil
      end

      def lua_method_target(callee, args)
        receiver = callee.named_children.first
        message = callee.named_children.last
        return nil unless receiver && message

        {
          receiver: normalize_text(receiver.text),
          message: normalize_text(message.text),
          arguments: args.named_children.map { |child| normalize_text(child.text) }
        }
      end

      def lua_expression_list_member_target(node)
        return nil unless node.kind == "expression_list"

        children = node.named_children
        return nil unless children.size == 2
        return nil unless field_like_node?(children.first) && identifier_node_kinds.include?(children.last.kind)

        { receiver: normalize_text(children.first.text), field: children.last.text }
      end

      def lua_adjacent_member_call_target(node)
        return nil if call_node_ancestor?(node)
        return nil unless node.kind == "identifier"

        args = next_sibling(node)
        return nil unless args&.kind == "arguments"

        parent = parent_node(node)
        return nil unless parent && field_like_node?(parent)

        target_from_callee(parent).merge(arguments: args.named_children.map { |child| normalize_text(child.text) })
      rescue StandardError
        nil
      end

      def lua_single_return_member_target(node)
        return nil unless node.kind == "expression_list"

        text = normalize_text(node.text)
        if (match = text.match(/\A([A-Za-z_]\w*)\.([A-Za-z_]\w*)\z/))
          return { receiver: match[1], field: match[2] }
        end

        parent = parent_node(node)
        return nil unless parent&.kind == "block"
        return nil unless prev_sibling(node)&.kind.to_s == "return" ||
                          parent.children.first&.kind.to_s == "return"

        return nil unless node.named_children.size == 1
        child = node.named_children.first
        return nil unless field_like_node?(child)

        generic_state_read_target(child)
      end
    end
  end
end
