# frozen_string_literal: true

module FactMine
  module Syntax
    RUST_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bNone\b/].freeze,
      guard_mids: %w[is_none is_some].freeze,
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

    RUST_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[downcast downcast_ref downcast_mut call call_mut call_once].freeze,
      meta_mids: %w[transmute from_raw_parts from_raw_parts_mut].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[std tokio fs env process net io].freeze,
      io_bare: %w[panic todo unimplemented unreachable print].freeze,
      dir_context: %w[current_dir home_dir].freeze,
      context_pairs: {
        "SystemTime" => %w[now],
        "Instant" => %w[now]
      }.freeze,
      context_bare: [].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock mutex atomic subscribe callback hook read write spawn await].freeze,
      core_consts: [].freeze
    ).freeze
    Syntax.register_effect_lexicon(:rust, RUST_EFFECT_LEXICON)

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

      def owner_kind(node, default_kind:)
        return "impl" if node.text.to_s.strip.start_with?("impl ")

        default_kind
      end

      def owner_name_from_text(node)
        node.text.to_s[/\b(?:impl|struct)\s+([A-Za-z_]\w*)/, 1]
      end

      def declarative_owner(node, current_owner:)
        return nil unless node.type.to_s == "STRUCT_ITEM"

        name = node.text.to_s[/\bstruct\s+([A-Za-z_]\w*)/, 1]
        name ? { name: name, kind: "struct" } : nil
      end

      def owner_name_span(_name, node, default_span:)
        return default_span if node.type.to_s == "STRUCT_ITEM"

        keyword_block_span(node, "struct") || default_span
      end

      def state_declaration_from_node(node, owner:)
        return nil unless node.type.to_s == "FIELD_DECLARATION"

        match = node.text.to_s.match(/\A(?:pub(?:\([^)]*\))?\s+)?([A-Za-z_]\w*)\s*:\s*([^,}]+)/)
        return nil unless match

        type = match[2].to_s.strip
        return nil if type.empty?

        { "field" => match[1], "type" => type }
      end

      def function_visibility(_name, node, lines:)
        return "public" if node.text.to_s.strip.start_with?("pub ")

        "private"
      end

      def parameter_name_from_signature(param)
        text = param.to_s.strip
        return text if text.match?(/\A&(?:mut\s+)?self\z/)
        if text.include?(":")
          name = text.split(":", 2).first.to_s.strip.sub(/\Amut\s+/, "")
          return name if name.match?(/\A[A-Za-z_]\w*\z/)
        end

        super
      end

      def function_name_from_text(text)
        text.to_s.strip[/\A(?:pub\s+)?fn\s+([A-Za-z_]\w*)\b/, 1] || super
      end

      def nil_guard_fact(message, subject)
        return nil unless subject

        case message.to_s
        when "is_some"
          { local: subject, non_nil_when_true: true }
        when "is_none"
          { local: subject, non_nil_when_true: false }
        end
      end
    end

    NormalizedExtractionBehavior.register(:rust, RustNormalizedExtractionBehavior)
  end
end
