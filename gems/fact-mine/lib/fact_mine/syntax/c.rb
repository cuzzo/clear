# frozen_string_literal: true

module FactMine
  module Syntax
    C_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bNULL\b/].freeze,
      guard_mids: %w[isNull isSome].freeze,
      type_guard_patterns: [
        /\bNULL\b/,
        /\bsizeof\s*\(/,
        /\b_Generic\s*\(/
      ].freeze,
      diagnostic_patterns: [
        /\b(?:assert|abort|exit)\s*\(/,
        /\breturn\s+errno\b/
      ].freeze,
      trivial_patterns: [
        /\A(?:NULL|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:NULL|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    C_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[dlsym dlopen GetProcAddress].freeze,
      meta_mids: %w[setjmp longjmp va_start va_arg].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[FILE DIR pthread mutex atomic].freeze,
      io_bare: %w[printf fprintf fopen open read write close system exec abort exit assert puts print].freeze,
      dir_context: %w[getcwd getenv].freeze,
      context_pairs: {}.freeze,
      context_bare: %w[rand time clock].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock mutex atomic subscribe callback hook pthread_mutex_lock pthread_mutex_unlock].freeze,
      core_consts: [].freeze
    ).freeze
    Syntax.register_effect_lexicon(:c, C_EFFECT_LEXICON)

    class CSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_definition].freeze
      CALL_NODE_KINDS = %w[call_expression].freeze
      CLASS_OWNER_NODE_KINDS = [].freeze
      STRUCT_OWNER_NODE_KINDS = %w[struct_specifier].freeze
      UNION_OWNER_NODE_KINDS = %w[union_declaration].freeze
      ENUM_OWNER_NODE_KINDS = %w[enum_declaration].freeze
      ANONYMOUS_OWNER_NODE_KINDS = %w[struct_declaration union_declaration enum_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameter_list].freeze
      FUNCTION_BODY_NODE_KINDS = %w[compound_statement].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = %w[field_identifier].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[declaration init_declarator].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[init_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter_declaration init_declarator function_declarator struct_specifier].freeze
      FIRST_ARGUMENT_RECEIVER_TYPE_NODE_KINDS = %w[type_identifier primitive_type qualified_identifier scoped_type_identifier].freeze
      FIRST_ARGUMENT_RECEIVER_NAME_NODE_KINDS = %w[identifier field_identifier].freeze
      RECEIVER_PARAMETER_NODE_KINDS = %w[parameter_declaration].freeze
      BOUND_CONTAINER_WRAPPER_NODE_KINDS = %w[ERROR expression_statement return_expression].freeze
      BOUND_CONTAINER_PARENT_NODE_KINDS = %w[declaration field_declaration].freeze
      BOUND_CONTAINER_NAME_NODE_KINDS = %w[identifier field_identifier type_identifier].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[call_expression expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[compound_statement].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement for_statement switch_statement].freeze
      LOOP_NODE_KINDS = %w[for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_definition struct_specifier].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[case_statement else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier field_identifier type_identifier].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        c_visibility(node)
      end

      def function_params(node)
        c_family_function_params(node) || super
      end

      private

      def receiver_convention_owner_name(node, **_context)
        return nil unless first_argument_receiver?
        return nil unless node.kind == "function_definition"

        receiver = first_argument_receiver_parameter(node)
        return nil unless receiver && receiver[:name] == "self"

        normalize_type_owner(receiver[:type])
      end

      def c_visibility(node)
        node.children.any? { |child| child.text == "static" } ? :private : :public
      end
    end
  end
end

module FactMine
  module Syntax
    class CNormalizedExtractionBehavior < NormalizedExtractionBehavior
      C_FIELD_MODIFIERS = %w[const volatile struct union enum].freeze

      def call_receiver(parts)
        receiver = parts.fetch(:receiver)
        return receiver unless receiver == "self"

        first_arg = parts.fetch(:arguments).first.to_s
        field = first_arg[/\Aself->([A-Za-z_]\w*)\z/, 1]
        field ? "self.#{field}" : receiver
      end

      def self_member_receiver(message)
        "self->#{message}"
      end

      def suppress_state_read_for_call?(call, span_source:)
        call.fetch("receiver").to_s.start_with?("self.") && !call.fetch("arguments").empty?
      end

      def suppress_self_call_state_read?(call)
        call.fetch("receiver") == "self" && !call.fetch("arguments").empty?
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

      def state_declaration_from_node(node, owner:)
        return nil unless node.type.to_s == "FIELD_DECLARATION"
        return nil if node.text.to_s.include?("(")

        member = c_member_declaration(node.text)
        member && { "field" => member.fetch(:name), "type" => member.fetch(:type) }
      end

      def owner_for_function(name, node, current_owner:, file_owner:)
        return current_owner unless current_owner == file_owner

        params = parameter_list_source(node.text.to_s)
        first = params.split(",", 2).first.to_s.strip
        typed_self = first[/\A(?:const\s+)?(?:struct\s+)?([A-Za-z_]\w*)\s*\*\s*self\z/, 1]
        return typed_self if typed_self
        typed_receiver = first[/\A(?:const\s+)?(?:struct\s+)?([A-Za-z_]\w*)\s*\*\s*[A-Za-z_]\w*\z/, 1]
        return typed_receiver if typed_receiver && name.downcase.start_with?("#{typed_receiver.downcase}_")

        name[/\A([A-Z]\w*)_/, 1] || current_owner
      end

      def receiver_aliases_for_function(node)
        params = parameter_list_source(node.text.to_s)
        first = params.split(",", 2).first.to_s.strip
        name = first[/\b([A-Za-z_]\w*)\s*\z/, 1]
        pointer = first.include?("*")
        name && pointer ? { name => "self" } : {}
      end

      def function_visibility(name, node, lines:)
        return "private" if node.text.to_s.strip.start_with?("static ")

        super
      end

      def wrap_branch_predicate?(_branch)
        true
      end

      def case_pattern_display(pattern)
        pattern.to_s.sub(/\AAST_([A-Z]\w*)\z/, 'AST.\1')
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

      def c_member_declaration(source)
        text = source.to_s.strip.sub(/=.*/m, "").delete_suffix(";").strip
        name = text.scan(/[A-Za-z_]\w*/).last
        return nil unless name && simple_identifier?(name)

        type = text.sub(/\b#{Regexp.escape(name)}\b\s*\z/, "").split.reject { |token| C_FIELD_MODIFIERS.include?(token) }.join(" ")
        type = type.gsub(/\s+\*/, " *").strip
        type = type.delete_suffix(" *").strip
        return nil if type.empty?

        { name: name, type: type }
      end
    end

    NormalizedExtractionBehavior.register(:c, CNormalizedExtractionBehavior)
  end
end
