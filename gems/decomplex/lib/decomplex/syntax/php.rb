# frozen_string_literal: true

module Decomplex
  module Syntax
    PHP_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnull\b/i].freeze,
      type_guard_patterns: [
        /\bnull\b/i,
        /\b(?:is_null|isset|empty|is_a|instanceof)\s*(?:\(|\b)/
      ].freeze,
      diagnostic_patterns: [
        /\bthrow\b/,
        /\b(?:die|exit|trigger_error)\s*\(/
      ].freeze,
      trivial_patterns: [
        /\A(?:null|true|false|0|1|break|continue)\s*;?\z/i,
        /\Areturn\s+(?:null|true|false|0|1)\s*;?\z/i
      ].freeze
    ).freeze

    class PhpSyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[function_definition method_declaration].freeze
      CALL_NODE_KINDS = %w[function_call_expression member_call_expression scoped_call_expression print_intrinsic].freeze
      CLASS_OWNER_NODE_KINDS = %w[class_declaration].freeze
      PARAMETER_LIST_NODE_KINDS = %w[formal_parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[compound_statement declaration_list].freeze
      IDENTIFIER_NODE_KINDS = %w[name variable_name].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[name variable_name simple_parameter].freeze
      LOCAL_DECLARATION_NODE_KINDS = [].freeze
      LOCAL_VARIABLE_DECLARATOR_NODE_KINDS = [].freeze
      FIELD_DECLARATION_NODE_KINDS = %w[property_declaration].freeze
      DECLARATION_SITE_PARENT_NODE_KINDS = %w[simple_parameter method_declaration function_definition class_declaration].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment_expression augmented_assignment_expression].freeze
      ASSIGNMENT_STATE_DECLARATION_NODE_KINDS = %w[assignment_expression].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %=].freeze
      PATH_ACTION_NODE_KINDS = %w[function_call_expression member_call_expression scoped_call_expression expression_statement return_statement print_intrinsic].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[compound_statement declaration_list].freeze
      COMPARISON_NODE_KINDS = %w[binary_expression].freeze
      BRANCH_NODE_KINDS = %w[if_statement foreach_statement switch_statement].freeze
      LOOP_NODE_KINDS = %w[foreach_statement].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[switch_statement].freeze
      BRANCH_CASE_NODE_KINDS = %w[switch_statement].freeze
      IF_NODE_KINDS = %w[if_statement].freeze
      CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      SWITCH_CASE_ARM_NODE_KINDS = %w[case_statement].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[function_definition method_declaration class_declaration].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[case_statement else comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary_expression].freeze
      PARENTHESIZED_WRAPPER_NODE_KINDS = %w[parenthesized_expression].freeze
      ARGUMENT_LIST_NODE_KINDS = %w[arguments argument].freeze
      SELF_CALL_IDENTIFIER_NODE_KINDS = %w[name variable_name].freeze
      SELF_RECEIVER_NAMES = %w[$this this self].freeze
      ACCESSOR_CALL_NODE_KINDS = [].freeze
      FIELD_LIKE_NODE_KINDS = %w[
        member_access_expression nullsafe_member_access_expression member_call_expression
        class_constant_access_expression
      ].freeze
      BLOCK_ARGUMENT_NODE_KINDS = [].freeze

      def function_name(node)
        return php_name_text(named_field(node, "name") || node.named_children.find { |child| child.kind == "name" }) if %w[
          function_definition method_declaration
        ].include?(node.kind)

        super
      end

      def owner_name_from_declaration(document, node)
        return php_name_text(named_field(node, "name") || node.named_children.find { |child| child.kind == "name" }) if node.kind == "class_declaration"

        super
      end

      def visibility(_document, node)
        modifier = node.named_children.find { |child| child.kind == "visibility_modifier" }
        return modifier.text.to_sym if modifier && %w[public private protected].include?(modifier.text)

        :public
      end

      def function_params(node)
        params = named_field(node, "parameters") ||
                 node.named_children.find { |child| child.kind == "formal_parameters" }
        return super unless params

        params.named_children.filter_map { |param| php_parameter_name(param) }.uniq
      end

      def call_target(document, node)
        php_call_target(node) || super
      end

      def state_read_target(node)
        return nil if php_assignment_lhs?(node)

        php_argument_member_target(node) || super
      end

      def state_declaration(node)
        php_property_declaration(node) || super
      end

      def predicate_def(document, function_def)
        predicate = super
        return nil unless predicate

        PredicateDef.new(
          file: predicate.file,
          name: predicate.name,
          owner: predicate.owner,
          body: php_normalize_source(predicate.body),
          line: predicate.line,
          span: predicate.span
        )
      end

      def path_condition_sites(document)
        super.map do |site|
          PathConditionSite.new(
            guards: site.guards.map { |guard| php_normalize_source(guard) },
            action: php_normalize_source(site.action),
            file: site.file,
            function: site.function,
            line: site.line,
            span: site.span
          )
        end
      end

      def local_contract_assignments(document, method)
        super.transform_values { |source| php_normalize_source(source) }
      end

      def redundant_nil_guard_findings(document)
        findings = []
        document.function_defs.each do |function_def|
          php_nil_guard_walk(document, function_def.body, function_def.name, Set.new, findings)
        end
        findings
      end

      private

      def php_call_target(node)
        return php_print_target(node) if node.kind == "print_intrinsic"
        return nil unless %w[function_call_expression member_call_expression scoped_call_expression].include?(node.kind)

        names = node.named_children.select do |child|
          php_name_node?(child) || child.kind == "variable_name" || child.kind == "member_access_expression"
        end
        args = node.named_children.find { |child| child.kind == "arguments" }

        case node.kind
        when "member_call_expression"
          receiver = php_member_receiver(node) || names.first
          message = php_member_name(node) || names[1]
          return nil unless receiver && message

          {
            receiver: php_normalize_receiver(php_identifier_text(receiver)),
            message: php_name_text(message),
            arguments: php_argument_texts(args)
          }
        when "scoped_call_expression"
          receiver = names.first
          message = names[1]
          return nil unless receiver && message

          {
            receiver: php_name_text(receiver),
            message: php_name_text(message),
            arguments: php_argument_texts(args)
          }
        when "function_call_expression"
          name = names.first
          return nil unless name

          {
            receiver: "self",
            message: php_name_text(name),
            arguments: php_argument_texts(args)
          }
        end
      end

      def php_print_target(node)
        {
          receiver: "self",
          message: "print",
          arguments: node.named_children.map { |child| php_print_argument_text(child) }
        }
      end

      def conjunction_predicate(node)
        php_normalize_source(super)
      end

      def branch_predicate(node)
        php_normalize_source(super)
      end

      def php_property_declaration(node)
        return nil unless node.kind == "property_declaration"

        property = node.named_children.find { |child| child.kind == "property_element" }
        name = property&.named_children&.find { |child| child.kind == "variable_name" }
        return nil unless name

        { field: php_identifier_text(name), type: declared_type_text(node, name) }
      end

      def php_parameter_name(param)
        variable = param.named_children.find { |child| child.kind == "variable_name" }
        php_identifier_text(variable) || php_identifier_text(param)
      end

      def generic_identifier?(node)
        super || (ts_node?(node) && %w[name variable_name].include?(node.kind))
      end

      def generic_local_identifier_text(node)
        return php_identifier_text(node) if ts_node?(node) && node.kind == "variable_name"

        super
      end

      def generic_member_name?(node)
        return true if parent_node(node)&.kind == "variable_name"
        return false if node.kind == "variable_name"

        super
      end

      def generic_local_writes(node, **kwargs)
        (super(node, **kwargs) + php_local_write_names(node)).map { |name| php_identifier_text_value(name) }.uniq
      end

      def generic_local_write_node?(node)
        return true if ts_node?(node) && node.kind == "variable_name" && php_assignment_lhs?(node)

        super
      end

      def decision_member_text(node)
        php_normalize_source(super)
      end

      def decision_predicate(node)
        php_normalize_source(super)
      end

      def comparison_target(node)
        target = super
        return nil unless target

        target.merge(source: php_normalize_source(target[:source]))
      end

      def control_context(node)
        return :iterates if node.kind == "foreach_statement"

        super
      end

      def target_from_callee(callee)
        target = super
        return target unless target

        target.merge(receiver: php_normalize_receiver(target[:receiver]))
      end

      def generic_state_read_target(node)
        target = super
        return target unless target

        target.merge(receiver: php_normalize_receiver(target[:receiver]))
      end

      def generic_state_target(lhs)
        target = super
        return target unless target

        target.merge(receiver: php_normalize_receiver(target[:receiver]))
      end

      def member_field_text(field)
        php_name_text(field)
      end

      def simple_identifier_text?(text)
        php_identifier_text_value(text).match?(/\A[A-Za-z_]\w*\z/)
      end

      def php_name_node?(node)
        ts_node?(node) && %w[name qualified_name].include?(node.kind)
      end

      def php_assignment_lhs?(node)
        parent = parent_node(node)
        return false unless parent

        %w[assignment_expression augmented_assignment_expression].include?(parent.kind) &&
          parent.named_children.first == node
      end

      def php_local_write_names(node)
        writes = []
        generic_walk_local(node) do |child|
          next unless ts_node?(child) && child.kind == "variable_name"
          next unless php_assignment_lhs?(child)

          writes << php_identifier_text(child)
        end
        writes.compact
      end

      def php_argument_texts(args)
        Array(args&.named_children).map { |child| php_normalize_source(child.text) }
      end

      def php_print_argument_text(node)
        value = php_unwrap_parenthesized(node)
        php_normalize_source(value&.text || node.text)
      end

      def php_argument_member_target(node)
        return nil unless ts_node?(node) && node.kind == "argument"
        return nil unless node.text.to_s.include?("->") || node.text.to_s.include?("::")
        return nil if node.text.to_s.include?("(")

        parts = php_normalize_source(node.text).split(".")
        return nil unless parts.size >= 2

        {
          receiver: php_normalize_receiver(parts[0...-1].join(".")),
          field: php_identifier_text_value(parts.last)
        }
      end

      def php_member_receiver(node)
        return nil unless ts_node?(node)

        named_field(node, "object") || named_field(node, "receiver") ||
          named_field(node, "expression") || node.named_children.first
      end

      def php_member_name(node)
        return nil unless ts_node?(node)

        named_field(node, "name") || named_field(node, "field") ||
          node.named_children.reverse.find { |child| php_name_node?(child) }
      end

      def php_identifier_text(node)
        text = php_identifier_text_value(node&.text)
        text.empty? ? nil : text
      end

      def php_name_text(node)
        text = php_identifier_text_value(node&.text)
        text.empty? ? nil : text
      end

      def php_identifier_text_value(text)
        text.to_s.sub(/\A\$/, "")
      end

      def php_normalize_receiver(receiver)
        value = php_normalize_source(php_identifier_text_value(receiver))
        value == "this" ? "self" : value
      end

      def php_normalize_source(source)
        source.to_s
              .gsub(/\$([A-Za-z_]\w*)/, '\1')
              .gsub(/->|::/, ".")
      end

      def php_nil_guard_walk(document, node, function, known, findings)
        return unless ts_node?(node)
        return if generic_nested_local_scope?(node) && function_name(node) != function

        if node.kind == "if_statement"
          php_process_nil_guard_if(document, node, function, known, findings)
          return
        end

        php_record_redundant_nil_guard(document, node, function, known, findings)
        node.named_children.each do |child|
          php_nil_guard_walk(document, child, function, known, findings)
        end
      end

      def php_process_nil_guard_if(document, node, function, known, findings)
        condition = named_field(node, "condition") || node.named_children.first
        body = named_field(node, "body") || node.named_children[1]
        branch_known = known.dup
        php_non_nil_facts(condition).each { |local| branch_known.add(local) }
        php_nil_guard_walk(document, body, function, branch_known, findings)
      end

      def php_record_redundant_nil_guard(document, node, function, known, findings)
        subject = php_nil_guard_subject(node)
        return unless subject && known.include?(subject)

        findings << NilGuardFinding.new(
          file: document.file,
          defn: function,
          line: line(node),
          span: span(node),
          local: subject,
          guard: php_normalize_source(node.text),
          proof: "#{subject} is already proven non-nil on this path"
        )
      end

      def php_non_nil_facts(node)
        node = php_unwrap_parenthesized(node)
        return [] unless ts_node?(node)

        subject = php_subject_key(node)
        return [subject] if subject

        call = php_member_call_parts(node)
        return [call[:receiver]] if call && %w[isSome is_some present].include?(call[:message])

        comparison = php_nil_comparison(node)
        return [comparison[:subject]] if comparison && %w[!== !=].include?(comparison[:operator])

        []
      end

      def php_nil_guard_subject(node)
        node = php_unwrap_parenthesized(node)
        return nil unless ts_node?(node)

        call = php_member_call_parts(node)
        return call[:receiver] if call && %w[isNull is_null nil is_none].include?(call[:message])

        comparison = php_nil_comparison(node)
        return comparison[:subject] if comparison && %w[=== ==].include?(comparison[:operator])

        function_call = php_function_call_parts(node)
        return function_call[:arguments].first if function_call && %w[is_null].include?(function_call[:message])

        nil
      end

      def php_nil_comparison(node)
        return nil unless ts_node?(node) && node.kind == "binary_expression"

        operator = direct_operator(node)
        return nil unless %w[=== !== == !=].include?(operator)

        left, right = node.named_children
        if php_null_literal?(right)
          subject = php_subject_key(left)
        elsif php_null_literal?(left)
          subject = php_subject_key(right)
        end
        subject ? { subject: subject, operator: operator } : nil
      end

      def php_member_call_parts(node)
        node = php_unwrap_parenthesized(node)
        return nil unless ts_node?(node) && node.kind == "member_call_expression"

        access = node.named_children.find { |child| child.kind == "member_access_expression" }
        receiver_node = access ? php_member_receiver(access) : node.named_children.find { |child| child.kind == "variable_name" }
        message_node = access ? php_member_name(access) : node.named_children.find { |child| php_name_node?(child) }
        receiver = php_subject_key(receiver_node)
        message = php_name_text(message_node)
        return nil unless receiver && message

        { receiver: receiver, message: message }
      end

      def php_function_call_parts(node)
        node = php_unwrap_parenthesized(node)
        return nil unless ts_node?(node) && node.kind == "function_call_expression"

        name = node.named_children.find { |child| php_name_node?(child) }
        args = node.named_children.find { |child| child.kind == "arguments" }
        {
          message: php_name_text(name),
          arguments: Array(args&.named_children).filter_map { |child| php_subject_key(child) }
        }
      end

      def php_subject_key(node)
        node = php_unwrap_parenthesized(node)
        return nil unless ts_node?(node)

        case node.kind
        when "variable_name", "name"
          php_identifier_text(node)
        when "member_access_expression"
          receiver = php_subject_key(php_member_receiver(node))
          message = php_name_text(php_member_name(node))
          receiver && message ? "#{receiver}.#{message}" : nil
        else
          nil
        end
      end

      def php_unwrap_parenthesized(node)
        current = node
        while ts_node?(current) &&
              %w[parenthesized_expression parenthesized_statements].include?(current.kind) &&
              current.named_children.size == 1
          current = current.named_children.first
        end
        current
      end

      def php_null_literal?(node)
        ts_node?(node) && node.kind == "null"
      end
    end
  end
end
