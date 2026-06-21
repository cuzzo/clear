# frozen_string_literal: true

module FactMine
  module Syntax
    RUST_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bNone\b/].freeze,
      type_guard_patterns: [
        /\b(?:is_some|is_none)\s*\(/,
        /\b(?:Some|None)\b/,
        /\bmatches!\s*\(/
      ].freeze,
      diagnostic_patterns: [
        /\b(?:panic|unreachable|todo|unimplemented)!\s*\(/,
        /\breturn\s+Err\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:None|true|false|0|1|break|continue|unreachable!)\s*;?\z/,
        /\Areturn\s+(?:None|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class RustSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_item].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      IMPL_OWNER_NODE_KINDS = %w[impl_item].freeze
      STRUCT_OWNER_NODE_KINDS = %w[struct_item].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block declaration_list].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = [].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier type_identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = %w[field_identifier].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier self_parameter].freeze
      LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS = %w[pattern].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[let_declaration].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter let_declaration function_item struct_item impl_item].freeze
      RECEIVER_TYPE_NODE_KINDS = %w[type_identifier generic_type scoped_type_identifier].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression compound_assignment_expr].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_expression].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_expression match_expression for_expression].freeze
      LOOP_NODE_KINDS = %w[for_expression].freeze
      TEXT_LOOP_NODE_KINDS = %w[expression_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[match_expression].freeze
      HIDDEN_MATCH_NODE_KINDS = %w[expression_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[match_expression expression_statement].freeze
      IF_NODE_KINDS = %w[if_expression].freeze
      CASE_ARM_NODE_KINDS = %w[match_arm].freeze
      WHEN_CASE_ARM_NODE_KINDS = %w[match_arm].freeze
      CASE_PATTERN_NODE_KINDS = %w[match_pattern pattern].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_item impl_item struct_item].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[match_arm else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression tuple_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[arguments].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier type_identifier field_identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[pub public].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      EXPRESSION_LIST_NODE_KINDS = [].freeze
      NAVIGATION_SUFFIX_NODE_KINDS = [].freeze
      LITERAL_FIELD_EXPRESSION_NODE_KINDS = %w[field_expression].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_expression scoped_identifier].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        modifier_visibility(node) || :private
      end
    end
  end
end

module FactMine
  module Syntax
    class RustNormalizedExtractionBehavior < NormalizedExtractionBehavior
      def source_message_text(message, node)
        return "#{message}()" if node && node.text.to_s.include?("#{message}()")

        message
      end

      def self_member_receiver(message)
        "self.#{message}"
      end

      def owner_name_span(_name, node, default_span:)
        return default_span if node.type.to_s == "STRUCT_ITEM"

        struct_keyword_span(node) || default_span
      end

      def function_visibility(_name, node, lines:)
        return "public" if node.text.to_s.strip.start_with?("pub ")

        "private"
      end

      def function_name_from_text(text)
        text.to_s.strip[/\A(?:pub\s+)?fn\s+([A-Za-z_]\w*)\b/, 1] || super
      end
    end

    NormalizedExtractionBehavior.register(:rust, RustNormalizedExtractionBehavior)
  end
end
