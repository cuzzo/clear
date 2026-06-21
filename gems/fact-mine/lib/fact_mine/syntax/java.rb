# frozen_string_literal: true

module FactMine
  module Syntax
    JAVA_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnull\b/].freeze,
      type_guard_patterns: [
        /\bnull\b/,
        /\binstanceof\b/,
        /\bObjects\.(?:isNull|nonNull|requireNonNull)\s*\(/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\bassert\b/,
        /\bSystem\.exit\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/,
        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    JAVA_EFFECT_LEXICON = EffectLexicon.new(
      dispatch_mids: %w[invoke getMethod getDeclaredMethod getField getDeclaredField forName].freeze,
      meta_mids: %w[invoke setAccessible newInstance Proxy].freeze,
      method_obj_mids: %w[method].freeze,
      io_consts: %w[System File Files Paths ProcessBuilder Socket HttpClient Thread Lock AtomicReference].freeze,
      io_bare: %w[throw].freeze,
      dir_context: %w[getProperty getenv].freeze,
      context_pairs: {
        "System" => %w[currentTimeMillis nanoTime getenv getProperty],
        "Instant" => %w[now],
        "UUID" => %w[randomUUID],
        "Math" => %w[random]
      }.freeze,
      context_bare: [].freeze,
      callback_set: %w[transaction synchronize lock with_lock unlock mutex atomic subscribe callback hook wait notify notifyAll submit execute].freeze,
      core_consts: [].freeze
    ).freeze
    Syntax.register_effect_lexicon(:java, JAVA_EFFECT_LEXICON)

    class JavaSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[method_declaration].freeze
      CALL_NODE_KINDS = %w[method_invocation].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[formal_parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[block].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier type_identifier].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_DECLARATION_NODE_KINDS = %w[local_variable_declaration variable_declarator].freeze
      VARIABLE_DECLARATION_NODE_KINDS = %w[variable_declarator].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = %w[variable_declarator].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[field_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[formal_parameter variable_declarator method_declaration class_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[method_invocation expression_statement return_statement].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[block].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement enhanced_for_statement switch_expression].freeze
      LOOP_NODE_KINDS = %w[enhanced_for_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_expression].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_expression].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[switch_block_statement_group].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[switch_block_statement_group].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[method_declaration class_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[switch_block_statement_group else line_comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      ADJACENT_METHOD_INVOCATION_NODE_KINDS = %w[method_invocation].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[argument_list].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[identifier type_identifier].freeze
      SELF_RECEIVER_NAMES = %w[this self].freeze
      PUBLIC_VISIBILITY_TOKENS = %w[public pub].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[field_access].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def function_params(node)
        return super unless node.kind == "method_declaration"

        params = node.named_children.find { |child| child.kind == "formal_parameters" }
        return super unless params

        params.named_children.filter_map { |param| parameter_name(param) }.uniq
      end
    end

    class JavaSyntaxAdapter
      private

      def control_context(node)
        return :iterates if node.kind == "enhanced_for_statement"

        super
      end
    end
  end
end

module FactMine
  module Syntax
    class JavaNormalizedExtractionBehavior < NormalizedExtractionBehavior
      def project_call(node, call)
        projected = call.dup
        text = node.text.to_s.strip
        if text.match?(/\Athis\.[A-Za-z_]\w+\(/) && !projected.fetch("arguments").empty?
          projected["message"] = "this"
          projected["receiver"] = "self"
        elsif (field = text[/\Athis\.([A-Za-z_]\w*)\.name\(\)/, 1])
          projected["message"] = field
          projected["receiver"] = "self"
        elsif (stream = text[/\ASystem\.(err|out)\.println\(/, 1])
          projected["message"] = stream
          projected["receiver"] = "System"
        elsif (profile_receiver = text[/\A(.+)\.profile\(\)\.name\(\)/, 1])
          projected["message"] = "profile()"
          projected["receiver"] = profile_receiver
        elsif projected.fetch("message") == "name" &&
              (nested = projected.fetch("receiver").to_s[/\A(.+)\.([A-Za-z_]\w+\(\))\z/, 1])
          projected["message"] = projected.fetch("receiver").split(".").last
          projected["receiver"] = nested
        end
        projected
      end

      def suppress_state_read_for_call?(call, span_source:)
        return true if call.fetch("receiver") != "self"
        return true if span_source.include?(".name()")

        false
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
        true
      end

      def case_pattern_display(pattern)
        "case #{pattern}"
      end

      def method_state_ref?(node, parts)
        parts.fetch(:receiver) != "self" && node.text.to_s.include?("(")
      end
    end

    NormalizedExtractionBehavior.register(:java, JavaNormalizedExtractionBehavior)
  end
end
