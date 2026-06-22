# frozen_string_literal: true

module FactMine
  module Syntax
    ZIG_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnull\b/].freeze,
      guard_mids: %w[isNull isSome].freeze,
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

    ZIG_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[field fieldParentPtr ptrCast alignCast call].freeze,
      meta_mids: %w[typeInfo TypeOf ptrCast intFromPtr ptrFromInt eval].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[std os fs process net Thread Mutex Atomic].freeze,
      io_bare: %w[panic unreachable print].freeze,
      dir_context: [].freeze,
      context_pairs: {
        "time" => %w[timestamp nanoTimestamp milliTimestamp]
      }.freeze,
      context_bare: [].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock mutex atomic subscribe callback hook spawn wait signal].freeze,
      core_consts: [].freeze
    ).freeze
    Syntax.register_effect_lexicon(:zig, ZIG_EFFECT_LEXICON)

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

module FactMine
  module Syntax
    class ZigNormalizedExtractionBehavior < NormalizedExtractionBehavior
      def state_write_span(receiver, field, node, default_span:)
        target_span_from_text(node, [receiver, field].reject(&:empty?).join("."))
      end

      def suppress_call_site?(_node, call)
        call.fetch("receiver").to_s == "std.debug" && call.fetch("message").to_s == "print"
      end

      def local_assignment_writes(field, node, default_span:)
        return [] unless field.to_s.start_with?(".")

        [{ receiver: ".literal", field: field.delete_prefix("."), span: default_span }]
      end

      def literal_state_reads(node, normalized_text:, span:, source_text: nil)
        return [] unless normalized_text.start_with?(".")

        field = normalized_text.delete_prefix(".")
        return [] unless simple_identifier?(field)

        [{
          field: field,
          receiver: ".literal",
          line: node.first_lineno,
          span: literal_span(node, normalized_text, span, source_text)
        }]
      end

      def literal_state_refs(_node, normalized_text:)
        return [] unless normalized_text.start_with?(".")

        [".literal.#{normalized_text.delete_prefix(".")}"]
      end

      def suppress_state_read_for_call?(call, span_source:)
        call.fetch("receiver").to_s == "std" && call.fetch("message").to_s == "debug"
      end

      def owner_name_span(_name, node, default_span:)
        keyword_block_span(node, "struct") || default_span
      end

      def declarative_owner(node, current_owner:)
        return nil unless node.type.to_s == "VARIABLE_DECLARATION"

        name = node.text.to_s[/\bconst\s+([A-Za-z_]\w*)\s*=\s*struct\b/, 1]
        name ? { name: name, kind: "struct" } : nil
      end

      def body_owner_for_function(name, node, current_owner:, file_owner:)
        return nil unless current_owner == file_owner
        return nil unless node.text.to_s.match?(/\A(?:pub\s+)?fn\s+#{Regexp.escape(name)}\b/)
        return nil unless node.text.to_s.include?("return struct")

        { name: name, kind: "struct" }
      end

      def state_declaration_from_node(node, owner:)
        return nil unless node.type.to_s == "CONTAINER_FIELD"

        field = node.children.find { |child| child.respond_to?(:type) && child.type.to_s == "LVAR" }
        return nil unless field

        name = field.children.first.to_s
        type = node.text.to_s[/\A#{Regexp.escape(name)}\s*:\s*([^=,\n]+)/, 1].to_s.strip
        return nil if name.empty? || type.empty?

        { "field" => name, "type" => type }
      end

      def owner_for_function(_name, node, current_owner:, file_owner:)
        return current_owner unless current_owner == file_owner

        node.text.to_s[/\A(?:pub\s+)?fn\s+\w+\s*\(\s*self\s*:\s*\*?([A-Za-z_]\w*)/, 1] || current_owner
      end

      def function_visibility(_name, node, lines:)
        return "public" if node.text.to_s.strip.start_with?("pub ")

        "private"
      end

      def function_name_from_text(text)
        text.to_s.strip[/\A(?:pub\s+)?fn\s+([A-Za-z_]\w*)\b/, 1] || super
      end

      def parameter_name_from_signature(param)
        text = param.to_s.strip
        if text.include?(":")
          name = text.split(":", 2).first.to_s.strip
          return name if name.match?(/\A[A-Za-z_]\w*\z/)
        end

        super
      end

      def case_pattern_values(pattern_values)
        pattern_values.first(1)
      end

      def wrap_branch_predicate?(_branch)
        false
      end

      def nil_guard_fact(message, subject)
        return nil unless subject

        case message.to_s
        when "isSome"
          { local: subject, non_nil_when_true: true }
        when "isNull"
          { local: subject, non_nil_when_true: false }
        end

      end

      private

      def literal_span(node, text, node_span, source_text)
        source = source_text || node.text.to_s
        index = source.index(text)
        return node_span unless index && node.first_lineno == node.last_lineno

        [node.first_lineno, node.first_column + index, node.first_lineno, node.first_column + index + text.length]
      end
    end

    NormalizedExtractionBehavior.register(:zig, ZigNormalizedExtractionBehavior)
  end
end
