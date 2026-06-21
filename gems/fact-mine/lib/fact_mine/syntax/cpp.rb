# frozen_string_literal: true

module FactMine
  module Syntax
    CPP_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\b(?:nullptr|NULL)\b/].freeze,
      type_guard_patterns: [
        /\b(?:nullptr|NULL)\b/,
        /\b(?:dynamic_cast|typeid)\s*[<(]/,
        /\bstd::(?:get_if|holds_alternative)\s*[<(]/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\b(?:assert|abort|exit)\s*\(/,
        /\bstd::terminate\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:nullptr|NULL|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:nullptr|NULL|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class CppSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_definition].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_specifier].freeze
      STRUCT_OWNER_NODE_KINDS = %w[struct_specifier].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameter_list].freeze
      FUNCTION_BODY_NODE_KINDS = %w[compound_statement].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier type_identifier qualified_identifier namespace_identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = %w[field_identifier].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[declaration init_declarator].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[init_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter_declaration init_declarator function_declarator class_specifier struct_specifier].freeze
      RECEIVER_TYPE_NODE_KINDS = %w[type_identifier qualified_identifier scoped_type_identifier].freeze
      FIRST_ARGUMENT_RECEIVER_TYPE_NODE_KINDS = %w[type_identifier primitive_type qualified_identifier scoped_type_identifier].freeze
      FIRST_ARGUMENT_RECEIVER_NAME_NODE_KINDS = %w[identifier field_identifier].freeze
      RECEIVER_PARAMETER_NODE_KINDS = %w[parameter_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[compound_statement].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_range_loop switch_statement].freeze
      LOOP_NODE_KINDS = %w[for_range_loop].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_definition class_specifier struct_specifier].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[case_statement else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[condition_clause parenthesized_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier type_identifier field_identifier qualified_identifier].freeze
      SELF_RECEIVER_NAMES = %w[this self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        modifier_visibility(node) || cpp_visibility(node)
      end

      def function_params(node)
        c_family_function_params(node) || super
      end

      def implicit_state_accesses?
        true
      end

      def field_declaration_name_node(node)
        declarator = node.named_children.reverse.find { |child| child.kind.end_with?("_declarator") }
        name = declarator&.named_children&.reverse&.find do |child|
          (identifier_node_kinds + field_identifier_node_kinds).include?(child.kind)
        end
        return name if name

        super
      end

      private

      def control_context(node)
        return :iterates if node.kind == "for_range_loop"

        super
      end

      def cpp_visibility(node)
        visibility = previous_cpp_access_specifier(node)
        return visibility if visibility

        owner = nearest_owner_declaration(node)
        return :public if owner&.kind == "struct_specifier"

        :private
      end

      def previous_cpp_access_specifier(node)
        sibling = prev_sibling(node)
        while sibling
          return sibling.text.to_sym if sibling.kind == "access_specifier" &&
                                       %w[public private protected].include?(sibling.text)

          sibling = prev_sibling(sibling)
        end
        nil
      end

      def nearest_owner_declaration(node)
        parent = parent_node(node)
        seen = Set.new
        while parent && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return parent if %w[class_specifier struct_specifier class class_definition class_declaration].include?(parent.kind)

          parent = parent_node(parent)
        end
        nil
      end
    end
  end
end
