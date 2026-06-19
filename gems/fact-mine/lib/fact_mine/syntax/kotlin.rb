# frozen_string_literal: true

module FactMine
  module Syntax
    KOTLIN_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnull\b/].freeze,
      type_guard_patterns: [
        /\bnull\b/,
        /(?:\?\.|\?\?)/,
        /\b(?:is|as\?)(?:\s|$)/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\b(?:error|require|check|assert|TODO)\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class KotlinSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_declaration].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      ADJACENT_CALL_NODE_KINDS = %w[navigation_expression directly_assignable_expression simple_identifier].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[function_value_parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[function_body statements].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = %w[statements].freeze
      IDENTIFIER_NODE_KINDS = %w[simple_identifier type_identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[simple_identifier].freeze
      LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS = %w[directly_assignable_expression value_argument].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[property_declaration variable_declaration].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[variable_declaration directly_assignable_expression].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[property_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter variable_declaration property_declaration function_declaration class_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression jump_expression].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[statements control_structure_body function_body].freeze
      COMPARISON_NODE_KINDS = %w[equality_expression comparison_expression conjunction_expression additive_expression multiplicative_expression].freeze
      BRANCH_NODE_KINDS = %w[if_expression for_statement when_expression].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[when_expression].freeze
      HIDDEN_CASE_WRAPPER_NODE_KINDS = %w[statements].freeze
      HIDDEN_CASE_TOKEN_KINDS = %w[when].freeze
      BRANCH_CASE_NODE_KINDS = %w[when_expression statements].freeze
      IF_NODE_KINDS = %w[if_expression].freeze
      HIDDEN_IF_WRAPPER_NODE_KINDS = %w[statements].freeze
      HIDDEN_IF_TOKEN_KINDS = %w[if].freeze
      CASE_ARM_NODE_KINDS = %w[when_entry].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[when_entry].freeze
      CASE_PATTERN_NODE_KINDS = %w[when_condition pattern].freeze
      CASE_SUBJECT_NODE_KINDS = %w[when_subject].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_declaration class_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[when_entry else line_comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default else].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[conjunction_expression equality_expression comparison_expression].freeze
      BOOLEAN_WRAPPER_NODE_KINDS = %w[statements pattern].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[call_suffix value_argument].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[simple_identifier type_identifier].freeze
      SELF_RECEIVER_NAMES = %w[this self].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      NAVIGATION_SUFFIX_NODE_KINDS = %w[navigation_suffix].freeze
      FIELD_LIKE_NODE_KINDS = %w[navigation_expression directly_assignable_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def field_declaration_name_node(node)
        if node.kind == "property_declaration"
          declaration = node.named_children.find { |child| child.kind == "variable_declaration" }
          name = declaration&.named_children&.find { |child| child.kind == "simple_identifier" }
          return name if name
        end

        super
      end

      def state_read_target(node)
        kotlin_value_argument_state_target(node) || super
      end

      private

      def kotlin_value_argument_state_target(node)
        return nil unless ts_node?(node) && node.kind == "value_argument"

        suffix = node.named_children.find { |child| navigation_suffix_node_kinds.include?(child.kind) }
        receiver = node.named_children.find { |child| child != suffix }
        field = member_field_text(suffix)
        return nil unless receiver && field
        return nil if namespace_receiver?(receiver.text)

        { receiver: normalize_text(receiver.text), field: field }
      end

      def record_state_param_origin(document, node, stack, out)
        return super unless node.kind == "assignment"

        lhs, rhs = node.named_children
        target = lhs && state_target(lhs)
        return unless target && rhs
        target = normalize_target_receiver(target, stack)

        (current_params(stack) & [rhs.text.to_s]).each do |param|
          out << StateParamOrigin.new(
            field: target[:field],
            receiver: target[:receiver],
            owner: current_owner(document, stack),
            param: param,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node)
          )
        end
      end
    end
  end
end
