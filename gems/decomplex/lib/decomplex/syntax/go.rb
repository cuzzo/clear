# frozen_string_literal: true

module Decomplex
  module Syntax
    GO_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnil\b/].freeze,
      type_guard_patterns: [
        /\bnil\b/,
        /\.\(type\)/,
        /\.\([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\)/
      ].freeze,
      diagnostic_patterns: [
        /\bpanic\s*\(/,
        /\breturn\s+error[.\w]*/
      ].freeze,
      trivial_patterns: [
        /\A(?:nil|true|false|0|1|break|continue|fallthrough)\s*;?\z/,
        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class GoSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_declaration method_declaration].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      ADJACENT_CALL_NODE_KINDS = %w[selector_expression identifier].freeze
      GENERIC_OWNER_NODE_KINDS = %w[type_spec].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameter_list].freeze
      METHOD_PARAMETER_LIST_NODE_KINDS = %w[parameter_list].freeze
      METHOD_RECEIVER_NODE_KINDS = %w[method_declaration].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block statement_list].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = %w[statement_list].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = %w[field_identifier].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier].freeze
      LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS = %w[expression_list literal_element].freeze
      INDEXED_LHS_NODE_KINDS = %w[index_expression slice_expression].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[short_var_declaration range_clause var_declaration variable_declaration].freeze
      SHORT_VARIABLE_DECLARATION_NODE_KINDS = %w[short_var_declaration range_clause].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[expression_list var_spec variable_declaration].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter_declaration function_declaration method_declaration type_spec].freeze
      RECEIVER_TYPE_NODE_KINDS = %w[pointer_type type_identifier].freeze
      RECEIVER_PARAMETER_NODE_KINDS = %w[parameter_declaration].freeze
      FIRST_ARGUMENT_RECEIVER_TYPE_NODE_KINDS = %w[type_identifier pointer_type].freeze
      FIRST_ARGUMENT_RECEIVER_NAME_NODE_KINDS = %w[identifier field_identifier].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_statement].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_statement].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block statement_list].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_statement expression_switch_statement].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[expression_switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[expression_switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      HIDDEN_IF_WRAPPER_NODE_KINDS = %w[block statement_list].freeze
      HIDDEN_IF_TOKEN_KINDS = %w[if].freeze
      CASE_ARM_NODE_KINDS = %w[expression_case].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[expression_case].freeze
      CASE_PATTERN_NODE_KINDS = [].freeze
      CASE_SUBJECT_NODE_KINDS = [].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_declaration method_declaration type_spec].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[expression_case else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      BOOLEAN_WRAPPER_NODE_KINDS = %w[expression_list].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier type_identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      EXPRESSION_LIST_NODE_KINDS = %w[expression_list].freeze
      FIELD_LIKE_NODE_KINDS = %w[selector_expression expression_list].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        exported_name_visibility(function_name(node))
      end

      def function_params(node)
        lists = node.named_children.select { |child| child.kind == "parameter_list" }
        params = node.kind == "method_declaration" ? lists[1] : lists.first
        return super unless params

        params.named_children.filter_map { |param| parameter_name(param) }.uniq
      end

      def call_target(document, node)
        return generic_call_target(document, node) if call_node_kinds.include?(node.kind)
        return go_adjacent_call_target(node) if adjacent_call_node_kinds.include?(node.kind)

        nil
      end

      def state_read_target(node)
        go_literal_element_member_target(node) || super
      end

      def generic_function_body_statements(node)
        body = generic_function_body_node(node)
        return super unless body

        named = body.named_children.reject { |child| comment_node?(child) }
        if named.size == 1 && named.first.kind == "statement_list" && go_adjacent_call_statement?(named.first)
          return [named.first]
        end

        super
      end

      def generic_local_identifier_text(node)
        name = super
        name == "_" ? nil : name
      end

      def generic_local_declaration_text(node)
        return nil if node.text == "_"

        super
      end

      def generic_local_write_node?(node)
        go_update_statement_target?(node) || super
      end

      def skip_local_read_identifier?(node)
        go_keyed_element_key?(node) || super
      end

      def generic_local_declaration_name_nodes(node)
        return go_var_spec_name_nodes(node) if node.kind == "var_declaration"

        super
      end

      def indexed_lhs_node?(node)
        super || (node.kind == "expression_list" && node.children.any? { |child| !child.named? && child.text == "[" })
      end

      def suppress_field_receiver_lhs_reads?
        true
      end

      def field_assignment_writes_receiver?
        true
      end

      private

      def boolean_container?(node)
        return true if boolean_expression_list?(node, "&&")

        super
      end

      def go_update_statement_target?(node)
        parent = parent_node(node)
        return false unless parent && %w[inc_statement dec_statement].include?(parent.kind)

        parent.named_children.first == node
      end

      def go_adjacent_call_statement?(node)
        named = node.named_children.reject { |child| comment_node?(child) }
        named.size == 2 &&
          adjacent_call_node_kinds.include?(named.first.kind) &&
          argument_list_node_kinds.include?(named.last.kind)
      end

      def go_adjacent_call_target(node)
        target = adjacent_argument_call_target(node)
        return nil unless target

        args = next_sibling(node) || next_sibling(parent_node(node))
        source = go_adjacent_call_source_node(node, args)
        target.merge(source_node: source)
      end

      def go_adjacent_call_source_node(node, args)
        parent = parent_node(node)
        return node unless parent && args

        call_text = "#{node.text}#{args.text}"
        parent.text.to_s.include?(call_text) ? parent : node
      end

      def go_keyed_element_key?(node)
        parent = parent_node(node)
        return false unless parent&.kind == "keyed_element"

        parent.named_children.first == node
      end

      def go_literal_element_member_target(node)
        return nil unless node.kind == "literal_element"
        return nil if go_keyed_element_key?(node)

        receiver, field = node.named_children
        return nil unless receiver && field
        return nil unless generic_identifier?(receiver) && field_identifier_node_kinds.include?(field.kind)

        { receiver: normalize_text(receiver.text), field: field.text }
      end

      def go_var_spec_name_nodes(node)
        go_var_spec_nodes(node).flat_map do |spec|
          names = spec.named_children.take_while { |child| child.kind == "identifier" }
          names.empty? ? [] : names
        end
      end

      def go_var_spec_nodes(node)
        return [node] if node.kind == "var_spec"

        node.named_children.flat_map { |child| go_var_spec_nodes(child) }
      end
    end
  end
end
