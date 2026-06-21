# frozen_string_literal: true

module FactMine
  module Syntax
    CPP_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\b(?:nullptr|NULL)\b/].freeze,
      type_guard_patterns: [
        /\b(?:nullptr|NULL)\b/,
        /\b(?:dynamic_cast|typeid)\s*[<(]/,
        /\bstd::(?:get_if|holds_alternative)\s*[<(]/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\b(?:assert|abort|exit)\s*\(/,
        /\bstd::terminate\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:nullptr|NULL|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:nullptr|NULL|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    CPP_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[dynamic_cast typeid any_cast get_if visit invoke].freeze,
      meta_mids: %w[reinterpret_cast const_cast dlsym dlopen].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[std filesystem fstream iostream thread mutex atomic].freeze,
      io_bare: %w[throw abort exit assert system].freeze,
      dir_context: %w[current_path].freeze,
      context_pairs: {
        "chrono" => %w[now],
        "random_device" => %w[operator()]
      }.freeze,
      context_bare: [].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock mutex atomic subscribe callback hook try_lock wait notify_one notify_all].freeze,
      core_consts: [].freeze
    ).freeze
    Syntax.register_effect_lexicon(:cpp, CPP_EFFECT_LEXICON)

    class CppSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_definition].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_specifier].freeze
      STRUCT_OWNER_NODE_KINDS = %w[struct_specifier].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameter_list].freeze
      FUNCTION_BODY_NODE_KINDS = %w[compound_statement].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier type_identifier qualified_identifier namespace_identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = %w[field_identifier].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[declaration init_declarator].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[init_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter_declaration init_declarator function_declarator class_specifier struct_specifier].freeze
      RECEIVER_TYPE_NODE_KINDS = %w[type_identifier qualified_identifier scoped_type_identifier].freeze
      FIRST_ARGUMENT_RECEIVER_TYPE_NODE_KINDS = %w[type_identifier primitive_type qualified_identifier scoped_type_identifier].freeze
      FIRST_ARGUMENT_RECEIVER_NAME_NODE_KINDS = %w[identifier field_identifier].freeze
      RECEIVER_PARAMETER_NODE_KINDS = %w[parameter_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[compound_statement].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_range_loop switch_statement].freeze
      LOOP_NODE_KINDS = %w[for_range_loop].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_definition class_specifier struct_specifier].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[case_statement else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[condition_clause parenthesized_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier type_identifier field_identifier qualified_identifier].freeze
      SELF_RECEIVER_NAMES = %w[this self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        modifier_visibility(node) || cpp_visibility(node)
      end

      def function_params(node)
        c_family_function_params(node) || super
      end

      def implicit_state_accesses?
        true
      end

      def field_declaration_name_node(node)
        declarator = node.named_children.reverse.find { |child| child.kind.end_with?("_declarator") }
        name = declarator&.named_children&.reverse&.find do |child|
          (identifier_node_kinds + field_identifier_node_kinds).include?(child.kind)
        end
        return name if name

        super
      end

      private

      def control_context(node)
        return :iterates if node.kind == "for_range_loop"

        super
      end

      def cpp_visibility(node)
        visibility = previous_cpp_access_specifier(node)
        return visibility if visibility

        owner = nearest_owner_declaration(node)
        return :public if owner&.kind == "struct_specifier"

        :private
      end

      def previous_cpp_access_specifier(node)
        sibling = prev_sibling(node)
        while sibling
          return sibling.text.to_sym if sibling.kind == "access_specifier" &&
                                       %w[public private protected].include?(sibling.text)

          sibling = prev_sibling(sibling)
        end
        nil
      end

      def nearest_owner_declaration(node)
        parent = parent_node(node)
        seen = Set.new
        while parent && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return parent if %w[class_specifier struct_specifier class class_definition class_declaration].include?(parent.kind)

          parent = parent_node(parent)
        end
        nil
      end
    end
  end
end

module FactMine
  module Syntax
    class CppNormalizedExtractionBehavior < NormalizedExtractionBehavior
      def implicit_owner_fields?
        true
      end

      def field_name_from_declaration(node)
        return nil unless %w[FIELD_DECLARATION PROPERTY_DECLARATION VARIABLE_DECLARATOR PROPERTY_ELEMENT].include?(node.type.to_s)
        return nil if node.text.to_s.include?("(")

        text = node.text.to_s.strip.sub(/=.*/, "").delete_suffix(";").strip
        name = text.scan(/[A-Za-z_]\w*/).last
        return nil unless name && name.match?(/\A[A-Za-z_]\w*\z/)
        return nil if %w[private protected public mutable static const constexpr volatile unsigned signed short long int char float double bool string].include?(name)

        name
      end

      def source_message_text(message, node)
        return "#{message}()" if node && node.text.to_s.include?("#{message}()")

        message
      end

      def initializer_field_reads(node, owner:, owner_fields:, function_name:)
        return [] unless owner_fields

        reads = []
        text = node.text.to_s
        text.to_enum(:scan, /(?:[:,]\s*)([A-Za-z_]\w*)\s*\(\s*0\s*\)/).each do
          field = Regexp.last_match(1)
          next unless owner_fields.include?(field)

          start_line = node.first_lineno
          line_offset = text[0...Regexp.last_match.begin(1)].count("\n")
          line_text = text.lines[line_offset].to_s
          column = line_text.index(field).to_i
          reads << {
            field: field,
            receiver: "self",
            function: function_name,
            line: start_line + line_offset,
            span: [start_line + line_offset, column, start_line + line_offset, column + field.length]
          }
        end
        reads
      end

      def owner_name_span(_name, node, default_span:)
        keyword_block_span(node, "struct") || default_span
      end

      def declarative_owner(node, current_owner:)
        return nil unless node.type.to_s == "TYPE_DEFINITION"

        text = node.text.to_s
        name = text[/}\s*([A-Za-z_]\w*)\s*;/m, 1]
        name && text.include?("struct") ? { name: name, kind: "struct" } : nil
      end

      def function_visibility(name, node, lines:)
        current = "private"
        lines.first(node.first_lineno - 1).each do |line|
          match = line.match(/^\s*(public|private|protected)\s*:/)
          next unless match

          current = match[1] == "public" ? "public" : "private"
        end
        current
      end

      def case_predicate_text(text)
        text.start_with?("(") && text.end_with?(")") ? text[1...-1] : text
      end

      def suppress_self_call_state_read?(call)
        call.fetch("receiver") == "self" && !call.fetch("arguments").empty?
      end

      def stream_insertion_operator?(node)
        node.text.to_s.include?("std::")
      end
    end

    NormalizedExtractionBehavior.register(:cpp, CppNormalizedExtractionBehavior)
  end
end
