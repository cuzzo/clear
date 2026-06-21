# frozen_string_literal: true

module FactMine
  module Syntax
    CSHARP_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnull\b/].freeze,
      type_guard_patterns: [
        /\bnull\b/,
        /(?:\?\.|\?\?)/,
        /\b(?:is|as|typeof)\b/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\b(?:Debug\.Assert|Trace\.Assert|Environment\.Exit)\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    CSHARP_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[Invoke GetMethod GetProperty GetField Activator CreateInstance].freeze,
      meta_mids: %w[Invoke GetType Reflection Emit DynamicMethod].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[Console File Directory Path Process Socket HttpClient Environment].freeze,
      io_bare: %w[throw].freeze,
      dir_context: %w[CurrentDirectory GetEnvironmentVariable].freeze,
      context_pairs: {
        "DateTime" => %w[Now UtcNow Today],
        "Guid" => %w[NewGuid],
        "Random" => %w[Next NextDouble]
      }.freeze,
      context_bare: [].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock mutex atomic subscribe callback hook Lock Monitor Enter Exit Wait Pulse].freeze,
      core_consts: [].freeze
    ).freeze
    Syntax.register_effect_lexicon(:csharp, CSHARP_EFFECT_LEXICON)

    class CSharpSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[method_declaration].freeze
      CALL_NODE_KINDS = %w[invocation_expression].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[parameter_list].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block declaration_list].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS = %w[argument].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[local_declaration_statement variable_declaration variable_declarator].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[variable_declaration].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[variable_declarator].freeze
      DECLARATOR_NODE_KINDS = %w[variable_declaration variable_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[parameter variable_declarator method_declaration class_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[invocation_expression expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement foreach_statement switch_statement].freeze
      LOOP_NODE_KINDS = %w[foreach_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[switch_section].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[switch_section].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[method_declaration class_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[switch_section else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      ADJACENT_METHOD_INVOCATION_NODE_KINDS = %w[invocation_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      SELF_RECEIVER_NAMES = %w[this self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[member_access_expression].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def visibility(_document, node)
        modifier_visibility(node) || :private
      end

      def implicit_state_accesses?
        true
      end

      def field_declaration_name_node(node)
        declaration = node.named_children.find { |child| child.kind == "variable_declaration" }
        declarator = declaration&.named_children&.find { |child| child.kind == "variable_declarator" }
        return named_field(declarator, "name") || declarator if declarator

        super
      end

      def state_read_target(node)
        if node.kind == "argument"
          object = named_field(node, "expression")
          field = named_field(node, "name")
          field_text = member_field_text(field)
          return nil unless object && field_text
          return nil if namespace_receiver?(object.text)
          return nil if NOISE_MESSAGES.include?(field_text)

          return { receiver: normalize_text(object.text), field: field_text }
        end

        super
      end

      private

      def control_context(node)
        return :iterates if node.kind == "foreach_statement"

        super
      end
    end
  end
end

module FactMine
  module Syntax
    class CsharpNormalizedExtractionBehavior < NormalizedExtractionBehavior
      def implicit_owner_fields?
        true
      end

      def field_name_from_declaration(node)
        return nil unless %w[FIELD_DECLARATION PROPERTY_DECLARATION VARIABLE_DECLARATOR PROPERTY_ELEMENT].include?(node.type.to_s)
        return nil if node.text.to_s.include?("(")

        text = node.text.to_s.strip.sub(/=.*/, "").delete_suffix(";").strip
        name = text.scan(/[A-Za-z_]\w*/).last
        return nil unless name && name.match?(/\A[A-Za-z_]\w*\z/)
        return nil if %w[private protected public internal readonly static const volatile string int long short byte bool decimal double float var].include?(name)

        name
      end

      def suppress_self_call_state_read?(call)
        call.fetch("receiver") == "self" && !call.fetch("arguments").empty?
      end

      def function_visibility(_name, node, lines:)
        text = node.text.to_s.strip
        return "private" if text.match?(/\A(?:private|protected)\b/)
        return "public" if text.match?(/\Apublic\b/)

        "public"
      end

      def explicit_self_state_ref(_node, message)
        "this.#{message}"
      end

      def wrap_branch_predicate?(_branch)
        false
      end
    end

    NormalizedExtractionBehavior.register(:csharp, CsharpNormalizedExtractionBehavior)
  end
end
