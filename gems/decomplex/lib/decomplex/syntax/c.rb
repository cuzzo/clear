# frozen_string_literal: true

module Decomplex
  module Syntax
    C_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bNULL\b/].freeze,
      type_guard_patterns: [
        /\bNULL\b/,
        /\bsizeof\s*\(/,
        /\b_Generic\s*\(/
      ].freeze,
      diagnostic_patterns: [
        /\b(?:assert|abort|exit)\s*\(/,
        /\breturn\s+errno\b/
      ].freeze,
      trivial_patterns: [
        /\A(?:NULL|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:NULL|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class CSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_definition].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      CLASS_OWNER_NODE_KINDS = [].freeze
      STRUCT_OWNER_NODE_KINDS = %w[struct_specifier].freeze
      UNION_OWNER_NODE_KINDS = %w[union_declaration].freeze
      ENUM_OWNER_NODE_KINDS = %w[enum_declaration].freeze
      ANONYMOUS_OWNER_NODE_KINDS = %w[struct_declaration union_declaration enum_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameter_list].freeze
      FUNCTION_BODY_NODE_KINDS = %w[compound_statement].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = %w[field_identifier].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[declaration init_declarator].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[init_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter_declaration init_declarator function_declarator struct_specifier].freeze
      FIRST_ARGUMENT_RECEIVER_TYPE_NODE_KINDS = %w[type_identifier primitive_type qualified_identifier scoped_type_identifier].freeze
      FIRST_ARGUMENT_RECEIVER_NAME_NODE_KINDS = %w[identifier field_identifier].freeze
      RECEIVER_PARAMETER_NODE_KINDS = %w[parameter_declaration].freeze
      BOUND_CONTAINER_WRAPPER_NODE_KINDS = %w[ERROR expression_statement return_expression].freeze
      BOUND_CONTAINER_PARENT_NODE_KINDS = %w[declaration field_declaration].freeze
      BOUND_CONTAINER_NAME_NODE_KINDS = %w[identifier field_identifier type_identifier].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[compound_statement].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_statement switch_statement].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_definition struct_specifier].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[case_statement else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier type_identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        c_visibility(node)
      end

      def function_params(node)
        c_family_function_params(node) || super
      end

      private

      def receiver_convention_owner_name(node, **_context)
        return nil unless first_argument_receiver?
        return nil unless node.kind == "function_definition"

        receiver = first_argument_receiver_parameter(node)
        return nil unless receiver && receiver[:name] == "self"

        normalize_type_owner(receiver[:type])
      end

      def c_visibility(node)
        node.children.any? { |child| child.text == "static" } ? :private : :public
      end
    end
  end
end
