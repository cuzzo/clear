# frozen_string_literal: true

module FactMine
  module Syntax
    SWIFT_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnil\b/].freeze,
      type_guard_patterns: [
        /\bnil\b/,
        /(?:\?\.|\?\?)/,
        /\b(?:if|guard)\s+let\b/,
        /\b(?:as\?|is)(?:\s|$)/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\b(?:fatalError|preconditionFailure|assertionFailure|assert|precondition)\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:nil|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class SwiftSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_declaration].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      ADJACENT_CALL_NODE_KINDS = %w[navigation_expression directly_assignable_expression simple_identifier].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[function_value_parameters].freeze
      INLINE_PARAMETER_NODE_KINDS = %w[parameter].freeze
      FUNCTION_BODY_NODE_KINDS = %w[function_body statements].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = %w[statements].freeze
      IDENTIFIER_NODE_KINDS = %w[simple_identifier type_identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[simple_identifier].freeze
      LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS = %w[directly_assignable_expression value_argument pattern].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[property_declaration variable_declaration].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[variable_declaration directly_assignable_expression].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[property_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter variable_declaration property_declaration function_declaration class_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression control_transfer_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[statements control_structure_body function_body].freeze
      COMPARISON_NODE_KINDS = %w[equality_expression comparison_expression conjunction_expression additive_expression multiplicative_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_statement switch_statement].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      HIDDEN_IF_WRAPPER_NODE_KINDS = %w[statements].freeze
      HIDDEN_IF_TOKEN_KINDS = %w[if].freeze
      CASE_ARM_NODE_KINDS = %w[switch_entry].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[switch_entry].freeze
      CASE_PATTERN_NODE_KINDS = %w[switch_pattern pattern].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_declaration class_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[switch_entry else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[conjunction_expression equality_expression comparison_expression].freeze
      BOOLEAN_WRAPPER_NODE_KINDS = %w[statements pattern].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[call_suffix value_argument].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[simple_identifier type_identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      NAVIGATION_SUFFIX_NODE_KINDS = %w[navigation_suffix].freeze
      FIELD_LIKE_NODE_KINDS = %w[navigation_expression directly_assignable_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze
    end
  end
end

module FactMine
  module Syntax
    class SwiftNormalizedExtractionBehavior < NormalizedExtractionBehavior
      def self_member_receiver(message)
        "self.#{message}"
      end

      def function_name_from_text(text)
        text.to_s.strip[/\bfunc\s+([A-Za-z_]\w*)\s*\(/, 1] || super
      end

      def access_span_call_site?(message, _current_function)
        message == "fallback"
      end

      def wrap_branch_predicate?(_branch)
        false
      end
    end

    NormalizedExtractionBehavior.register(:swift, SwiftNormalizedExtractionBehavior)
  end
end
