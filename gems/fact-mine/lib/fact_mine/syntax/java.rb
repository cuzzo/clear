# frozen_string_literal: true

module FactMine
  module Syntax
    JAVA_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnull\b/].freeze,
      type_guard_patterns: [
        /\bnull\b/,
        /\binstanceof\b/,
        /\bObjects\.(?:isNull|nonNull|requireNonNull)\s*\(/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\bassert\b/,
        /\bSystem\.exit\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class JavaSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[method_declaration].freeze
      CALL_NODE_KINDS = %w[method_invocation].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[formal_parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier type_identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[local_variable_declaration variable_declarator].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[variable_declarator].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[variable_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[formal_parameter variable_declarator method_declaration class_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[method_invocation expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement enhanced_for_statement switch_expression].freeze
      LOOP_NODE_KINDS = %w[enhanced_for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_expression].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_expression].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[switch_block_statement_group].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[switch_block_statement_group].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[method_declaration class_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[switch_block_statement_group else line_comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      ADJACENT_METHOD_INVOCATION_NODE_KINDS = %w[method_invocation].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier type_identifier].freeze
      SELF_RECEIVER_NAMES = %w[this self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_access].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def function_params(node)
        return super unless node.kind == "method_declaration"

        params = node.named_children.find { |child| child.kind == "formal_parameters" }
        return super unless params

        params.named_children.filter_map { |param| parameter_name(param) }.uniq
      end

      def field_declaration_name_node(node)
        if node.kind == "field_declaration"
          declarator = node.named_children.find { |child| child.kind == "variable_declarator" }
          return declarator if declarator&.text.to_s.match?(/\A[A-Za-z_]\w*\z/)
        end

        super
      end
    end

    class JavaSyntaxAdapter
      private

      def control_context(node)
        return :iterates if node.kind == "enhanced_for_statement"

        super
      end
    end
  end
end
