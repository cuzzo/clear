# frozen_string_literal: true

module Decomplex
  module Syntax
    JAVASCRIPT_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\b(?:null|undefined)\b/].freeze,
      type_guard_patterns: [
        /\btypeof\b/,
        /\binstanceof\b/,
        /(?:\?\.|\b(?:==|!=|===|!==)\s*(?:null|undefined)\b)/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\bprocess\.exit\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|undefined|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:null|undefined|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class JavaScriptSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_declaration method_definition].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      ADJACENT_CALL_NODE_KINDS = %w[member_expression identifier property_identifier].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[formal_parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[statement_block].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = [].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = %w[property_identifier].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[lexical_declaration variable_declarator].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[variable_declarator].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[variable_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[public_field_definition].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[formal_parameters variable_declarator method_definition function_declaration class_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression augmented_assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %= &&= ||=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[statement_block].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_in_statement switch_statement].freeze
      LOOP_NODE_KINDS = %w[for_in_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[switch_case].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[switch_case].freeze
      CASE_PATTERN_NODE_KINDS = [].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_declaration method_definition class_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[switch_case else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      BOUND_CONTAINER_PARENT_NODE_KINDS = %w[lexical_declaration public_field_definition].freeze
      BOUND_CONTAINER_NAME_NODE_KINDS = %w[identifier property_identifier].freeze
      ADJACENT_METHOD_INVOCATION_NODE_KINDS = [].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[arguments].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier property_identifier].freeze
      SELF_RECEIVER_NAMES = %w[this self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      EXPRESSION_LIST_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[member_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        modifier_visibility(node) || private_name_visibility(node)
      end

      private

      def private_name_visibility(node)
        function_name(node).to_s.start_with?("#") ? :private : :public
      end
    end
  end
end
