# frozen_string_literal: true

module Decomplex
  module Syntax
    PYTHON_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bNone\b/].freeze,
      type_guard_patterns: [
        /\b(?:isinstance|issubclass|hasattr)\s*\(/,
        /\bis\s+(?:not\s+)?None\b/,
        /\btype\s*\([^)]*\)\s*(?:==|is)\s*/
      ].freeze,
      diagnostic_patterns: [
        /\braise\b/,
        /\bassert\b/,
        /\bsys\.exit\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:None|True|False|0|1|break|continue|pass)\s*;?\z/,
        /\Areturn\s+(?:None|True|False|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class PythonSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_definition].freeze
      CALL_NODE_KINDS = %w[call].freeze
      ADJACENT_CALL_NODE_KINDS = %w[attribute identifier].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_definition].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = %w[block].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment augmented_assignment].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block].freeze
      COMPARISON_NODE_KINDS = %w[comparison_operator binary_operator boolean_operator].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_statement match_statement].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[match_statement].freeze
      HIDDEN_CASE_WRAPPER_NODE_KINDS = %w[block].freeze
      HIDDEN_CASE_TOKEN_KINDS = %w[match case].freeze
      BRANCH_CASE_NODE_KINDS = %w[match_statement block].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      HIDDEN_IF_WRAPPER_NODE_KINDS = %w[block statement_list].freeze
      HIDDEN_IF_TOKEN_KINDS = %w[if].freeze
      CASE_ARM_NODE_KINDS = %w[case_clause].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[case_clause].freeze
      CASE_PATTERN_NODE_KINDS = %w[case_pattern pattern].freeze
      CASE_SUBJECT_NODE_KINDS = [].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_definition class_definition].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[case_clause else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[and &&].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_operator boolean_operator comparison_operator].freeze
      BOOLEAN_WRAPPER_NODE_KINDS = %w[block].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      FIELD_DECLARATION_NODE_KINDS = [].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameters].freeze
      ADJACENT_METHOD_INVOCATION_NODE_KINDS = [].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      ACCESSOR_CALL_NODE_KINDS = %w[call].freeze
      FIELD_LIKE_NODE_KINDS = %w[attribute].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def function_name(node)
        hidden_python_function_name(node) || super
      end

      def visibility(_document, node)
        name = function_name(node).to_s
        return :private if name.start_with?("_") && !name.start_with?("__")

        :public
      end

      def call_target(document, node)
        python_adjacent_call_target(node) || super
      end

      def local_methods(document)
        super
      end

      private

      def hidden_python_function_name(node)
        return nil unless node.kind == "block"
        return nil unless node.children.first&.kind.to_s == "def"

        node.named_children.find { |child| child.kind == "identifier" }&.text
      end

      def python_function_body_statements(node)
        body = named_field(node, "body") ||
               node.named_children.find { |child| child.kind == "block" }
        return [] unless body

        body.named_children.reject { |child| child.kind == "comment" }
      end

      def python_adjacent_call_target(node)
        return nil unless %w[identifier].include?(node.kind)

        args = next_sibling(node)
        return nil unless args&.kind == "argument_list"

        {
          receiver: "self",
          message: node.text,
          arguments: args.named_children.map { |child| normalize_text(child.text) }
        }
      rescue StandardError
        nil
      end
    end
  end
end
