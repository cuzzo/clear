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
      PythonSyntheticStatement = Struct.new(:kind, :children, :text, :start_point, :end_point, keyword_init: true) do
        def named?
          true
        end

        def named_children
          children.select { |child| child.respond_to?(:named?) && child.named? }
        end
      end

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

      def parameter_name(param)
        name = super
        return name if name

        python_nested_parameter_identifier(param)&.text
      end

      def call_target(document, node)
        python_adjacent_call_target(node) || super
      end

      def state_read_target(node)
        return nil if python_hidden_assignment_parts(node) || python_annotation_lhs?(node)

        super
      end

      def record_state_write(document, node, stack, out)
        parts = python_hidden_assignment_parts(node)
        unless parts
          super
          return
        end

        target = state_target(parts.fetch(:lhs))
        return unless target
        target = normalize_target_receiver(target, stack)
        return if skip_state_write_target?(target)

        out << StateWrite.new(
          field: target[:field],
          receiver: target[:receiver],
          file: document.file,
          function: current_function(stack),
          line: line(parts.fetch(:lhs)),
          span: python_assignment_span(parts.fetch(:lhs), parts.fetch(:rhs)),
          owner: current_owner(document, stack)
        )
      end

      def record_state_param_origin(document, node, stack, out)
        parts = python_hidden_assignment_parts(node)
        unless parts
          super
          return
        end

        target = state_target(parts.fetch(:lhs))
        return unless target
        target = normalize_target_receiver(target, stack)

        params = current_params(stack)
        return if params.empty?

        rhs_param_names(parts.fetch(:rhs), params).each do |param|
          out << StateParamOrigin.new(
            field: target[:field],
            receiver: target[:receiver],
            owner: current_owner(document, stack),
            param: param,
            file: document.file,
            function: current_function(stack),
            line: line(parts.fetch(:lhs)),
            span: python_assignment_span(parts.fetch(:lhs), parts.fetch(:rhs))
          )
        end
      end

      def local_methods(document)
        document.function_defs.map do |function_def|
          statements = python_function_body_statements(function_def.body, document)
          local_names = generic_local_names(function_def, statements)
          local_statements = statements.each_with_index.map do |statement, index|
            generic_local_statement(statement, index, local_names)
          end
          owner = function_def.owner.to_s == file_owner(document.file) ? "(top-level)" : function_def.owner

          LocalMethod.new(
            id: "#{owner}##{function_def.name}",
            owner: owner,
            name: function_def.name,
            file: function_def.file,
            line: function_def.line,
            span: function_def.span,
            node: function_def.body,
            statements: local_statements,
            boundaries: generic_structural_boundaries(document, local_statements)
          )
        end
      end

      private

      def hidden_python_function_name(node)
        return nil unless node.kind == "block"
        return nil unless node.children.first&.kind.to_s == "def"

        node.named_children.find { |child| child.kind == "identifier" }&.text
      end

      def python_nested_parameter_identifier(param)
        return nil unless ts_node?(param)
        return nil unless %w[typed_parameter default_parameter].include?(param.kind)

        param.named_children.each do |child|
          next unless %w[list_splat_pattern dictionary_splat_pattern].include?(child.kind)

          identifier = child.named_children.find { |grandchild| parameter_identifier_node_kinds.include?(grandchild.kind) }
          return identifier if identifier
        end
        nil
      end

      def python_function_body_statements(node, document)
        body = named_field(node, "body") ||
               node.named_children.find { |child| child.kind == "block" }
        return [] unless body

        groups = python_statement_child_groups(body)
        return [] if groups.empty? && body.text.to_s.strip.empty?
        return [body] if groups.empty?

        groups.map { |children| python_synthetic_statement(document, children) }
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

      def assignment_lhs?(node)
        super || !!python_hidden_assignment_parts(node)
      end

      def generic_local_write_node?(node)
        super || python_annotation_lhs?(node)
      end

      def python_hidden_assignment_parts(node)
        return nil unless ts_node?(node)

        operator = next_sibling(node)
        return nil unless operator

        if assignment_operator_tokens.include?(operator.text.to_s)
          rhs = next_sibling(operator)
          return { lhs: node, rhs: rhs } if rhs
        elsif operator.text.to_s == ":"
          type_node = next_sibling(operator)
          equal = next_sibling(type_node)
          rhs = next_sibling(equal)
          return { lhs: node, rhs: rhs } if equal&.text.to_s == "=" && rhs
        end

        nil
      end

      def python_annotation_lhs?(node)
        return false unless ts_node?(node)
        return false unless generic_identifier?(node) || field_like_node?(node)

        colon = next_sibling(node)
        return false unless colon&.text.to_s == ":"

        type_node = next_sibling(colon)
        equal = next_sibling(type_node)
        !equal || equal.text.to_s != "="
      end

      def python_assignment_span(lhs, rhs)
        [
          lhs.start_point.row + 1,
          lhs.start_point.column,
          rhs.end_point.row + 1,
          rhs.end_point.column
        ]
      end

      def python_statement_child_groups(body)
        children = body.children.reject { |child| comment_node?(child) }
        return [] if children.empty?

        groups = []
        current = []
        body_column = body.start_point.column

        children.each do |child|
          if current.any? && python_new_statement_child?(current, child, body_column)
            groups << current
            current = []
          end
          current << child
        end
        groups << current if current.any?
        groups
      end

      def python_new_statement_child?(current, child, body_column)
        return false unless child.start_point.row > current.map { |item| item.end_point.row }.max
        return false if %w[elif else except finally case].include?(child.kind)

        child.start_point.column <= body_column
      end

      def python_synthetic_statement(document, children)
        first = children.first
        last = children.last
        PythonSyntheticStatement.new(
          kind: "python_statement",
          children: children,
          text: python_source_slice(document, first.start_point, last.end_point),
          start_point: first.start_point,
          end_point: last.end_point
        )
      end

      def python_source_slice(document, start_point, end_point)
        if start_point.row == end_point.row
          return document.lines[start_point.row].to_s[start_point.column...end_point.column].to_s
        end

        lines = document.lines[start_point.row..end_point.row].to_a
        return "" if lines.empty?

        lines[0] = lines[0].to_s[start_point.column..].to_s
        lines[-1] = lines[-1].to_s[..end_point.column - 1].to_s
        lines.join
      end
    end
  end
end
