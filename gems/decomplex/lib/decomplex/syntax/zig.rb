# frozen_string_literal: true

module Decomplex
  module Syntax
    ZIG_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnull\b/].freeze,
      type_guard_patterns: [
        /\bnull\b/,
        /@typeInfo\b/,
        /\bif\s*\([^)]*\)\s*\|/
      ].freeze,
      diagnostic_patterns: [
        /@panic\s*\(/,
        /\bunreachable\b/,
        /\breturn\s+error[.\w]*/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|true|false|0|1|break|continue|unreachable)\s*;?\z/,
        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class ZigSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_declaration].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      ADJACENT_CALL_NODE_KINDS = %w[field_expression identifier].freeze
      ANONYMOUS_OWNER_NODE_KINDS = %w[struct_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block block_expression].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[variable_declaration].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[container_field].freeze
      BOUND_CONTAINER_PARENT_NODE_KINDS = %w[variable_declaration].freeze
      BOUND_CONTAINER_NAME_NODE_KINDS = %w[identifier].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter variable_declaration function_declaration struct_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_expression].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement switch_expression for_statement labeled_statement].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      TEXT_LOOP_NODE_KINDS = %w[labeled_statement].freeze
      BRANCH_LOOP_NODE_KINDS = %w[for_statement labeled_statement].freeze
      CASE_NODE_KINDS = %w[switch_expression].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_expression].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[switch_case].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[switch_case].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_declaration struct_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[switch_case else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default else].freeze
      BOOLEAN_AND_OPERATORS = %w[and &&].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list arguments].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[pub public].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      LITERAL_FIELD_EXPRESSION_NODE_KINDS = %w[field_expression].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        modifier_visibility(node) || :private
      end

      def state_declaration(node)
        return zig_container_field_declaration(node) if node.kind == "container_field"

        super
      end

      private

      def zig_container_field_declaration(node)
        name = node.named_children.find { |child| child.kind == "identifier" }
        return nil unless name

        { field: name.text, type: declared_type_text(node, name) }
      end
    end
  end
end
