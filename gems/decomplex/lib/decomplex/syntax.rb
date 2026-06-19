# frozen_string_literal: true

require "set"
require "rbconfig"

module Decomplex
  module Syntax
    FunctionDef = Struct.new(:file, :name, :owner, :line, :span, :body, :visibility,
                             :params, :signature, :kind, keyword_init: true)
    OwnerDef = Struct.new(:file, :name, :kind, :line, :span, keyword_init: true)
    CallSite = Struct.new(:receiver, :message, :file, :function, :owner, :line, :span,
                          :conditional, :arguments, :control, :safe_navigation, :block,
                          keyword_init: true)
    StateDeclaration = Struct.new(:field, :owner, :type, :file, :line, :span, keyword_init: true)
    StateParamOrigin = Struct.new(:field, :receiver, :owner, :param, :file, :function,
                                  :line, :span, keyword_init: true)
    DecisionSite = Struct.new(:kind, :members, :file, :function, :line, :span, :predicate,
                              :enclosing_span, keyword_init: true)
    StateRead = Struct.new(:field, :receiver, :file, :function, :line, :span, :owner, keyword_init: true)
    StateWrite = Struct.new(:field, :receiver, :file, :function, :line, :span, :owner, keyword_init: true)
    BranchDecision = Struct.new(:file, :function, :line, :span, :predicate, :state_refs, keyword_init: true)
    BranchArm = Struct.new(:file, :function, :kind, :line, :span,
                           :decision_line, :decision_span, :predicate,
                           :member, :body, keyword_init: true)
    PredicateDef = Struct.new(:file, :name, :owner, :body, :line, :span, keyword_init: true)
    ComparisonSite = Struct.new(:file, :function, :line, :span, :source, :operator, keyword_init: true)
    LocalMethod = Struct.new(:id, :owner, :name, :file, :line, :span, :node,
                             :statements, :boundaries, keyword_init: true)
    LocalStatement = Struct.new(:index, :line, :end_line, :span, :source, :reads,
                                :writes, :dependencies, :co_uses, keyword_init: true)
    LocalBoundary = Struct.new(:before_index, :after_index, :line, :kind, :text, keyword_init: true)
    PathConditionSite = Struct.new(:guards, :action, :file, :function, :line, :span, keyword_init: true)
    LanguageLexicon = Struct.new(
      :type_guard_patterns, :diagnostic_patterns, :trivial_patterns,
      :nil_literal_patterns,
      keyword_init: true
    ) do
      def type_guard?(text, allow_literal_nil: true)
        source = text.to_s
        return true if allow_literal_nil && matches?(nil_literal_patterns, source)

        matches?(type_guard_patterns, source)
      end

      def diagnostic?(text, extra_names: [])
        source = text.to_s
        matches?(diagnostic_patterns, source) ||
          call_name?(source, Array(extra_names).map(&:to_s))
      end

      def trivial?(text)
        source = text.to_s.strip
        source.empty? || matches?(trivial_patterns, source)
      end

      private

      def matches?(patterns, source)
        Array(patterns).any? { |pattern| source.match?(pattern) }
      end

      def call_name?(source, names)
        names.reject(&:empty?).any? do |name|
          source.match?(/(?:\A|[^\w!?])#{Regexp.escape(name)}[!?]?(?:\s*\(|\b)/)
        end
      end
    end

    class TreeSitterLanguageAdapter
      EMPTY_NODE_KINDS = [].freeze
      ADAPTER_KIND_METHODS = {
        function_node_kinds: :FUNCTION_NODE_KINDS,
        class_owner_node_kinds: :CLASS_OWNER_NODE_KINDS,
        module_owner_node_kinds: :MODULE_OWNER_NODE_KINDS,
        generic_owner_node_kinds: :GENERIC_OWNER_NODE_KINDS,
        impl_owner_node_kinds: :IMPL_OWNER_NODE_KINDS,
        struct_owner_node_kinds: :STRUCT_OWNER_NODE_KINDS,
        union_owner_node_kinds: :UNION_OWNER_NODE_KINDS,
        enum_owner_node_kinds: :ENUM_OWNER_NODE_KINDS,
        anonymous_owner_node_kinds: :ANONYMOUS_OWNER_NODE_KINDS,
        call_node_kinds: :CALL_NODE_KINDS,
        adjacent_call_node_kinds: :ADJACENT_CALL_NODE_KINDS,
        parameter_list_node_kinds: :PARAMETER_LIST_NODE_KINDS,
        method_parameter_list_node_kinds: :METHOD_PARAMETER_LIST_NODE_KINDS,
        inline_parameter_node_kinds: :INLINE_PARAMETER_NODE_KINDS,
        function_body_node_kinds: :FUNCTION_BODY_NODE_KINDS,
        nested_statement_wrapper_node_kinds: :NESTED_STATEMENT_WRAPPER_NODE_KINDS,
        identifier_node_kinds: :IDENTIFIER_NODE_KINDS,
        local_identifier_wrapper_node_kinds: :LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS,
        assignment_node_kinds: :ASSIGNMENT_NODE_KINDS,
        assignment_operator_tokens: :ASSIGNMENT_OPERATOR_TOKENS,
        local_declaration_node_kinds: :LOCAL_DECLARATION_NODE_KINDS,
        short_variable_declaration_node_kinds: :SHORT_VARIABLE_DECLARATION_NODE_KINDS,
        variable_declaration_node_kinds: :VARIABLE_DECLARATION_NODE_KINDS,
        declaration_assignment_node_kinds: :DECLARATION_ASSIGNMENT_NODE_KINDS,
        path_action_node_kinds: :PATH_ACTION_NODE_KINDS,
        simple_action_wrapper_node_kinds: :SIMPLE_ACTION_WRAPPER_NODE_KINDS,
        comparison_node_kinds: :COMPARISON_NODE_KINDS,
        branch_node_kinds: :BRANCH_NODE_KINDS,
        loop_node_kinds: :LOOP_NODE_KINDS,
        text_loop_node_kinds: :TEXT_LOOP_NODE_KINDS,
        labeled_loop_node_kinds: :LABELED_LOOP_NODE_KINDS,
        case_node_kinds: :CASE_NODE_KINDS,
        hidden_case_wrapper_node_kinds: :HIDDEN_CASE_WRAPPER_NODE_KINDS,
        hidden_match_node_kinds: :HIDDEN_MATCH_NODE_KINDS,
        branch_loop_node_kinds: :BRANCH_LOOP_NODE_KINDS,
        branch_case_node_kinds: :BRANCH_CASE_NODE_KINDS,
        if_node_kinds: :IF_NODE_KINDS,
        hidden_if_token_kinds: :HIDDEN_IF_TOKEN_KINDS,
        hidden_case_token_kinds: :HIDDEN_CASE_TOKEN_KINDS,
        case_arm_node_kinds: :CASE_ARM_NODE_KINDS,
        when_case_arm_node_kinds: :WHEN_CASE_ARM_NODE_KINDS,
        switch_case_arm_node_kinds: :SWITCH_CASE_ARM_NODE_KINDS,
        case_pattern_node_kinds: :CASE_PATTERN_NODE_KINDS,
        case_subject_node_kinds: :CASE_SUBJECT_NODE_KINDS,
        case_container_stop_node_kinds: :CASE_CONTAINER_STOP_NODE_KINDS,
        case_subject_skip_node_kinds: :CASE_SUBJECT_SKIP_NODE_KINDS,
        default_case_patterns: :DEFAULT_CASE_PATTERNS,
        boolean_and_operators: :BOOLEAN_AND_OPERATORS,
        boolean_container_node_kinds: :BOOLEAN_CONTAINER_NODE_KINDS,
        boolean_wrapper_node_kinds: :BOOLEAN_WRAPPER_NODE_KINDS,
        parenthesized_wrapper_node_kinds: :PARENTHESIZED_WRAPPER_NODE_KINDS,
        parenthesized_pattern_node_kinds: :PARENTHESIZED_PATTERN_NODE_KINDS,
        hidden_if_wrapper_node_kinds: :HIDDEN_IF_WRAPPER_NODE_KINDS,
        local_variable_declarator_node_kinds: :LOCAL_VARIABLE_DECLARATOR_NODE_KINDS,
        field_declaration_node_kinds: :FIELD_DECLARATION_NODE_KINDS,
        declaration_site_parent_node_kinds: :DECLARATION_SITE_PARENT_NODE_KINDS,
        receiver_type_node_kinds: :RECEIVER_TYPE_NODE_KINDS,
        method_receiver_node_kinds: :METHOD_RECEIVER_NODE_KINDS,
        receiver_parameter_node_kinds: :RECEIVER_PARAMETER_NODE_KINDS,
        first_argument_receiver_type_node_kinds: :FIRST_ARGUMENT_RECEIVER_TYPE_NODE_KINDS,
        first_argument_receiver_name_node_kinds: :FIRST_ARGUMENT_RECEIVER_NAME_NODE_KINDS,
        bound_container_wrapper_node_kinds: :BOUND_CONTAINER_WRAPPER_NODE_KINDS,
        bound_container_parent_node_kinds: :BOUND_CONTAINER_PARENT_NODE_KINDS,
        bound_container_name_node_kinds: :BOUND_CONTAINER_NAME_NODE_KINDS,
        adjacent_method_invocation_node_kinds: :ADJACENT_METHOD_INVOCATION_NODE_KINDS,
        argument_list_node_kinds: :ARGUMENT_LIST_NODE_KINDS,
        self_call_identifier_node_kinds: :SELF_CALL_IDENTIFIER_NODE_KINDS,
        self_receiver_names: :SELF_RECEIVER_NAMES,
        field_identifier_node_kinds: :FIELD_IDENTIFIER_NODE_KINDS,
        declarator_node_kinds: :DECLARATOR_NODE_KINDS,
        assignment_state_declaration_node_kinds: :ASSIGNMENT_STATE_DECLARATION_NODE_KINDS,
        accessor_call_node_kinds: :ACCESSOR_CALL_NODE_KINDS,
        expression_list_node_kinds: :EXPRESSION_LIST_NODE_KINDS,
        navigation_suffix_node_kinds: :NAVIGATION_SUFFIX_NODE_KINDS,
        literal_field_expression_node_kinds: :LITERAL_FIELD_EXPRESSION_NODE_KINDS,
        block_argument_node_kinds: :BLOCK_ARGUMENT_NODE_KINDS,
        parameter_identifier_node_kinds: :PARAMETER_IDENTIFIER_NODE_KINDS,
        member_access_operator_tokens: :MEMBER_ACCESS_OPERATOR_TOKENS,
        public_visibility_tokens: :PUBLIC_VISIBILITY_TOKENS,
        field_like_node_kinds: :FIELD_LIKE_NODE_KINDS
      }.freeze

      ADAPTER_KIND_METHODS.each do |method_name, constant_name|
        define_method(method_name) { adapter_node_kinds(constant_name) }
      end

      attr_reader :language, :extensions, :lexicon, :package, :grammar_names,
                  :tree_sitter_language_name

      def initialize(language:, extensions:, lexicon:, package:, grammar_names: nil,
                     tree_sitter_language_name: nil, first_argument_receiver: false)
        @language = language.to_sym
        @extensions = Array(extensions).freeze
        @lexicon = lexicon
        @package = package
        @grammar_names = Array(grammar_names || language.to_s).freeze
        @tree_sitter_language_name = tree_sitter_language_name || language.to_s
        @first_argument_receiver = first_argument_receiver
      end

      def first_argument_receiver?
        @first_argument_receiver
      end

      def adapter_node_kinds(constant_name)
        self.class.const_defined?(constant_name) ? self.class.const_get(constant_name) : EMPTY_NODE_KINDS
      end

      def function_name(node)
        return nil unless function_node_kinds.include?(node.kind)

        named_field(node, "name")&.text ||
          declarator_name(named_field(node, "declarator")) ||
          first_named_text(node, identifier_node_kinds + field_identifier_node_kinds)
      end

      def function_kind(_document, node, stack)
        owner_for_node(nil, node, stack: stack) ? :method : :function
      end

      def visibility(_document, node)
        modifier_visibility(node)
      end

      def owner_name_from_declaration(document, node)
        if (class_owner_node_kinds + module_owner_node_kinds).include?(node.kind)
          named_field(node, "name")&.text ||
            first_named_text(node, identifier_node_kinds + field_identifier_node_kinds)
        elsif generic_owner_node_kinds.include?(node.kind)
          named_field(node, "name")&.text ||
            first_named_text(node, identifier_node_kinds + field_identifier_node_kinds)
        elsif impl_owner_node_kinds.include?(node.kind)
          impl_owner_name(node)
        elsif struct_owner_node_kinds.include?(node.kind)
          named_field(node, "name")&.text ||
            first_named_text(node, identifier_node_kinds + field_identifier_node_kinds)
        elsif anonymous_owner_node_kinds.include?(node.kind)
          bound_container_name(node) ||
            returned_container_owner(document, node) ||
            anonymous_owner_name(document, node)
        end
      end

      def owner_kind(node)
        if class_owner_node_kinds.include?(node.kind)
          :class
        elsif module_owner_node_kinds.include?(node.kind)
          :module
        elsif impl_owner_node_kinds.include?(node.kind)
          :impl
        elsif union_owner_node_kinds.include?(node.kind)
          :union
        elsif enum_owner_node_kinds.include?(node.kind)
          :enum
        elsif (struct_owner_node_kinds + anonymous_owner_node_kinds).include?(node.kind)
          :struct
        else :owner
        end
      end

      def function_receiver_name(node, stack)
        receiver_param = method_receiver_param_node(node)
        receiver_param&.text ||
          receiver_convention_param_name(node, stack: stack)
      end

      def receiver_convention_owner_name(node, **_context)
        return nil unless first_argument_receiver?
        return nil unless function_node_kinds.include?(node.kind)

        receiver = first_argument_receiver_parameter(node)
        return nil unless receiver

        type = normalize_type_owner(receiver[:type])
        name = function_name(node).to_s
        return nil if type.empty? || name.empty?

        prefix = snake_case_type_name(type)
        name.start_with?("#{prefix}_") ? type : nil
      end

      def receiver_convention_param_name(node, **_context)
        return nil unless first_argument_receiver?

        first_argument_receiver_parameter(node)&.fetch(:name, nil)
      end

      def generated_prelude?(_document, _node)
        false
      end

      def call_target(document, node)
        if call_node_kinds.include?(node.kind)
          generic_call_target(document, node)
        elsif adjacent_call_node_kinds.include?(node.kind)
          adjacent_argument_call_target(node)
        end
      end

      def state_declaration(node)
        generic_state_declaration(node)
      end

      def state_read_target(node)
        generic_state_read_target(node)
      end

      def state_target(lhs)
        generic_state_target(lhs)
      end
    end

    class TreeSitterLanguageAdapter
      COMPARISON_OPERATORS = %w[== !=].freeze
      NOISE_MESSAGES = %w[! != == === < <= > >= [] []= to_s inspect class].freeze

      def initial_stack(document)
        [{ file_owner: file_owner(document.file), language: document.language }]
      end

      def push_context(document, stack, node)
        next_stack = push_owner_context(document, stack, node)
        name = function_name(node)
        next_stack = name ? next_stack + [function_context(node, next_stack)] : next_stack
        control = control_context(node)
        control ? next_stack + [{ control: control }] : next_stack
      end

      def structural_facts_for_node(document, node, stack)
        out = {
          function_defs: [],
          owner_defs: [],
          call_sites: [],
          state_declarations: [],
          state_param_origins: [],
          state_reads: [],
          state_writes: []
        }
        record_function_def(document, node, stack, out[:function_defs])
        record_owner_def(document, node, stack, out[:owner_defs])
        record_call_site(document, node, stack, out[:call_sites])
        record_state_declaration(document, node, stack, out[:state_declarations])
        record_state_param_origin(document, node, stack, out[:state_param_origins])
        record_state_read(document, node, stack, out[:state_reads])
        record_state_write(document, node, stack, out[:state_writes])
        out
      end

      def after_structural_facts(document, out)
        record_implicit_state_accesses(document, out) if implicit_state_accesses?
      end

      def decision_site_facts(document, node, stack)
        out = []
        record_decision_site(document, node, stack, out)
        out
      end

      def branch_decision_facts(document, node, stack, immutable_readers:, immutable_reader_types:, type_aliases:)
        out = []
        record_branch_decision(
          document,
          node,
          stack,
          out,
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases,
          method_param_types: method_param_types(document)
        )
        out
      end

      def branch_arm_facts(document, node, stack)
        out = []
        record_branch_arm(document, node, stack, out)
        out
      end

      def comparison_site_facts(document, node, stack)
        target = comparison_target(node)
        return [] unless target

        [
          ComparisonSite.new(
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            source: target[:source],
            operator: target[:operator]
          )
        ]
      end

      def implicit_state_accesses?
        false
      end

      def function_params(node)
        params = if method_parameter_list_node_kinds.any? && function_node_kinds.include?(node.kind)
                   lists = node.named_children.select { |child| method_parameter_list_node_kinds.include?(child.kind) }
                   lists.size > 1 ? lists[1] : lists.first
                 else
                   named_field(node, "parameters") ||
                     node.named_children.find do |child|
                       parameter_list_node_kinds.include?(child.kind)
                     end
                 end
        params ||= node.named_children.select { |child| inline_parameter_node_kinds.include?(child.kind) }
        return [] unless params

        Array(params.respond_to?(:named_children) ? params.named_children : params).filter_map do |param|
          parameter_name(param)
        end.uniq
      end

      def function_signature(document, node)
        body = named_field(node, "body")
        text =
          if body
            document.source.byteslice(node.start_byte, body.start_byte - node.start_byte).to_s.strip
          else
            line_text(document, node).strip
          end
        normalize_text(text.empty? ? line_text(document, node) : text)
      rescue StandardError
        normalize_text(line_text(document, node))
      end

      def method_param_types(_document)
        {}
      end

      def immutable_struct_readers(_document)
        {}
      end

      def immutable_struct_reader_types(_document)
        {}
      end

      def type_aliases(_document)
        {}
      end

      def predicate_def(_document, function_def)
        body = generic_predicate_body(function_def.body)
        return nil unless body

        PredicateDef.new(
          file: function_def.file,
          name: function_def.name,
          owner: function_def.owner,
          body: body,
          line: function_def.line,
          span: function_def.span
        )
      end

      def local_methods(document)
        document.function_defs.map do |function_def|
          statements = generic_function_body_statements(function_def.body)
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

      def path_condition_sites(document)
        out = []
        document.function_defs.each do |function_def|
          generic_function_body_statements(function_def.body).each do |statement|
            generic_path_walk(document, statement, function_def.name, [], out)
          end
        end
        out
      end

      private

      def generic_predicate_body(node)
        body = generic_function_body_node(node)
        return nil unless body

        statement = generic_function_body_statements(node).last || body
        source = normalize_text(statement.text)
        source = source.sub(/\Areturn\s+/, "").sub(/;\z/, "").strip
        return nil if source.empty? || source.length > 200
        return nil unless source.match?(/\A(?:true|false)\z|\b(?:true|false|null|nil)\b|(?:==|!=|&&|\|\||\band\b|\bor\b)/i)

        source
      end

      def generic_function_body_node(node)
        return nil unless ts_node?(node)

        named_field(node, "body") ||
          node.named_children.reverse.find do |child|
            function_body_node_kinds.include?(child.kind)
          end
      end

      def generic_function_body_statements(node)
        body = generic_function_body_node(node)
        return [] unless body

        named = body.named_children.reject { |child| comment_node?(child) }
        if named.size == 1 && nested_statement_wrapper_node_kinds.include?(named.first.kind)
          return [named.first] if branch_node?(named.first)

          named = named.first.named_children.reject { |child| comment_node?(child) }
        end
        return [] if named.empty? && body.text.to_s.strip.empty?
        return [body] if branch_node?(body)
        return [body] if generic_assignment_statement?(body)
        return [body] if named.empty?

        named
      end

      def generic_local_names(function_def, statements)
        names = Set.new(function_def.params.to_a.map(&:to_s))
        statements.each do |statement|
          names.merge(generic_local_writes(statement))
        end
        names
      end

      def generic_local_statement(node, index, local_names)
        reads = generic_local_reads(node, local_names).uniq
        writes = generic_local_writes(node).uniq
        LocalStatement.new(
          index: index,
          line: line(node),
          end_line: span(node)[2],
          span: span(node),
          source: normalize_text(node.text),
          reads: reads.to_set,
          writes: writes.to_set,
          dependencies: generic_assignment_dependencies(node, local_names),
          co_uses: reads.combination(2).map { |left, right| [left, right] }
        )
      end

      def generic_local_reads(node, local_names)
        reads = []
        generic_walk_local(node) do |child|
          name = generic_local_identifier_text(child)
          next unless name
          next unless local_names.include?(name)
          next if generic_local_write_node?(child)
          next if generic_declaration_name?(child)
          next if generic_member_name?(child)
          next if generic_call_name?(child)

          reads << name
        end
        reads
      end

      def generic_local_writes(node)
        writes = []
        if (name = generic_local_declaration_name(node))
          writes << name
        end
        writes.concat(generic_assignment_lhs_names(node))

        generic_walk_local(node) do |child|
          next unless generic_identifier?(child)
          next unless generic_local_write_node?(child)

          writes << child.text.to_s
        end
        writes
      end

      def generic_assignment_dependencies(node, local_names)
        lhs_names = generic_local_writes(node)
        return [] if lhs_names.empty?

        reads = generic_local_reads(node, local_names) - lhs_names
        lhs_names.product(reads).reject { |left, right| left == right }.uniq
      end

      def generic_structural_boundaries(document, statements)
        statements.each_cons(2).filter_map do |left, right|
          boundary = generic_source_boundary(document, left.end_line + 1, right.line - 1)
          next unless boundary

          LocalBoundary.new(
            before_index: left.index,
            after_index: right.index,
            line: boundary[:line],
            kind: boundary[:kind],
            text: boundary[:text]
          )
        end
      end

      def generic_source_boundary(document, first_line, last_line)
        return nil if first_line > last_line

        blank = nil
        (first_line..last_line).each do |line_number|
          text = document.lines[line_number - 1].to_s
          stripped = text.strip
          return { line: line_number, kind: :comment, text: stripped } if stripped.start_with?("#", "//", "--")

          blank ||= { line: line_number, kind: :blank, text: stripped } if stripped.empty?
        end
        blank
      end

      def generic_walk_local(node, &block)
        return unless ts_node?(node)

        stack = [node]
        until stack.empty?
          current = stack.pop
          next unless ts_node?(current)
          next if current != node && generic_nested_local_scope?(current)

          yield current
          current.named_children.reverse_each { |child| stack << child }
        end
      end

      def generic_nested_local_scope?(node)
        function_name(node) || owner_name_from_declaration(nil, node)
      end

      def generic_identifier?(node)
        ts_node?(node) && identifier_node_kinds.include?(node.kind)
      end

      def generic_local_identifier_text(node)
        return node.text.to_s if generic_identifier?(node)
        return nil unless ts_node?(node)
        return nil unless local_identifier_wrapper_node_kinds.include?(node.kind)
        return nil unless node.named_children.empty?

        text = node.text.to_s
        simple_identifier_text?(text) ? text : nil
      end

      def generic_assignment_statement?(node)
        ts_node?(node) &&
          (assignment_node_kinds.include?(node.kind) ||
           node.children.any? { |child| !child.named? && assignment_operator_tokens.include?(child.text.to_s) })
      end

      def generic_local_write_node?(node)
        return false unless generic_identifier?(node)

        parent = parent_node(node)
        return false unless parent
        return false if generic_member_name?(node)
        return true if generic_declaration_name?(node)

        if assignment_node_kinds.include?(parent.kind)
          lhs = named_field(parent, "left") || parent.named_children.first
          return lhs == node
        end

        assignment_lhs?(node)
      end

      def generic_declaration_name?(node)
        parent = parent_node(node)
        return false unless parent

        generic_local_declaration_name_node(parent) == node
      end

      def generic_local_declaration_name(node)
        generic_local_declaration_name_node(node)&.text
      end

      def generic_local_declaration_name_node(node)
        return nil unless ts_node?(node)
        return nil unless local_declaration_node_kinds.include?(node.kind)

        if short_variable_declaration_node_kinds.include?(node.kind)
          left = node.named_children.find { |child| variable_declaration_node_kinds.include?(child.kind) }
          if left
            identifier = left.named_children.find { |child| generic_identifier?(child) }
            return identifier if identifier
          end
          return left if simple_identifier_text?(left&.text)
        end

        variable = node.named_children.find { |child| variable_declaration_node_kinds.include?(child.kind) }
        return variable if simple_identifier_text?(variable&.text)

        declaration_assignment = node.named_children.find { |child| declaration_assignment_node_kinds.include?(child.kind) }
        if declaration_assignment
          lhs = declaration_assignment.named_children.first
          identifier = lhs&.named_children&.find { |child| generic_identifier?(child) }
          return identifier if identifier
          return lhs if simple_identifier_text?(lhs&.text)
        end

        named_field(node, "pattern") ||
          named_field(node, "name") ||
          node.named_children.find { |child| local_identifier_wrapper_node_kinds.include?(child.kind) } ||
          node.named_children.find { |child| variable_declaration_node_kinds.include?(child.kind) }&.named_children&.find { |child| generic_identifier?(child) } ||
          node.named_children.find { |child| generic_identifier?(child) }
      end

      def generic_assignment_lhs_names(node)
        return [] unless ts_node?(node)
        return [] unless assignment_node_kinds.include?(node.kind)

        lhs = named_field(node, "left") || node.named_children.first
        return [] unless ts_node?(lhs)
        return [lhs.text] if generic_identifier?(lhs)
        return [lhs.text] if simple_identifier_text?(lhs.text)

        lhs.named_children.filter_map { |child| child.text if generic_identifier?(child) }
      end

      def simple_identifier_text?(text)
        text.to_s.match?(/\A[A-Za-z_]\w*\z/)
      end

      def generic_member_name?(node)
        parent = parent_node(node)
        if parent&.kind == "navigation_suffix"
          owner = parent_node(parent)
          return true if owner && field_like_node?(owner)
        end
        return false if parent && expression_list_node_kinds.include?(parent.kind) && !member_expression_list?(parent)
        return false unless parent && field_like_node?(parent)

        field = named_field(parent, "field") || named_field(parent, "property") ||
                named_field(parent, "name") || named_field(parent, "suffix") ||
                parent.named_children.last
        field == node
      end

      def generic_call_name?(node)
        parent = parent_node(node)
        return false unless parent
        return false if field_like_node?(parent)

        if adjacent_method_invocation_node_kinds.include?(parent.kind)
          names = parent.named_children.select { |child| generic_identifier?(child) }
          return names.size >= 2 ? names.last == node : parent.named_children.first == node
        end

        call_node_kinds.include?(parent.kind) &&
          (named_field(parent, "function") == node || parent.named_children.first == node)
      end

      def generic_path_walk(document, node, function, guards, out)
        return unless ts_node?(node)
        return if generic_nested_local_scope?(node)

        if branch_node?(node)
          condition = generic_branch_condition(node)
          atoms = generic_path_condition_atoms(condition)
          generic_branch_body_nodes(node).each do |child|
            generic_path_walk(document, child, function, guards + atoms, out)
          end
          return
        end

        if guards.size >= 2 && generic_path_action_node?(node)
          out << PathConditionSite.new(
            guards: guards.uniq.sort,
            action: normalize_text(node.text),
            file: document.file,
            function: function,
            line: line(node),
            span: span(node)
          )
          return
        end

        node.named_children.each { |child| generic_path_walk(document, child, function, guards, out) }
      end

      def generic_branch_condition(node)
        named_field(node, "condition") || named_field(node, "value") ||
          named_field(node, "subject") || node.named_children.first
      end

      def generic_branch_body_nodes(node)
        bodies = [
          named_field(node, "consequence"),
          named_field(node, "body"),
          named_field(node, "alternative")
        ].compact
        bodies = node.named_children.drop(1) if bodies.empty?
        bodies.flat_map do |body|
          next [body] if simple_action_wrapper?(body)

          children = body.named_children.reject { |child| comment_node?(child) }
          children.empty? ? [body] : children
        end
      end

      def comment_node?(node)
        node.kind.to_s.include?("comment")
      end

      def generic_path_condition_atoms(condition)
        return [] unless ts_node?(condition)

        if boolean_container?(condition) && boolean_and?(condition)
          flatten_boolean_and(condition).map { |child| decision_member_text(child) }.uniq.sort
        else
          [decision_member_text(condition)]
        end
      end

      def generic_path_action_node?(node)
        return false unless ts_node?(node)
        return false if branch_node?(node)

        return true if simple_action_wrapper?(node)

        generic_assignment_statement?(node) ||
          path_action_node_kinds.include?(node.kind)
      end

      def simple_action_wrapper?(node)
        return false unless simple_action_wrapper_node_kinds.include?(node.kind)

        normalize_text(node.text).match?(/\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?\s*\([^{};]*\)\s*;?\z/)
      end

      def comparison_target(node)
        return nil unless comparison_node_kinds.include?(node.kind)

        operator = direct_operator(node)
        return nil unless COMPARISON_OPERATORS.include?(operator)

        { source: normalize_text(node.text), operator: operator }
      end

      def push_owner_context(document, stack, node)
        owner = owner_name_from_declaration(document, node)
        return stack unless owner

        parent_owner = current_owner_from_stack(stack)
        full_owner = if parent_owner && parent_owner != owner && !owner.include?("::")
                       "#{parent_owner}::#{owner}"
                     else
                       owner
                     end
        stack + [{ owner: full_owner, owner_declaration: true, owner_kind: owner_kind(node) }]
      end

      def current_function(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:function] }
        entry ? entry[:function] : "(top-level)"
      end

      def current_owner(document, stack)
        current_owner_from_stack(stack) || file_owner(document.file)
      end

      def current_owner_from_stack(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:owner] }
        entry && entry[:owner]
      end

      def current_language(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:language] }
        entry && entry[:language]
      end

      def conditional_context?(stack)
        stack.any? { |item| item.is_a?(Hash) && %i[conditional iterates].include?(item[:control]) }
      end

      def current_control(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:control] }
        entry ? entry[:control] : :always
      end

      def function_context(node, stack)
        {
          function: function_name(node),
          owner: function_owner_name(node, stack),
          params: function_params(node),
          receiver: function_receiver_name(node, stack)
        }
      end

      def function_owner_name(node, stack)
        receiver_owner_name(node) ||
          current_owner_from_stack(stack) ||
          receiver_convention_owner_name(node, stack: stack)
      end

      def line_text(document, node)
        document.lines[line(node) - 1].to_s
      end

      def control_context(node)
        return :iterates if loop_node_kinds.include?(node.kind)
        return :iterates if text_loop_node_kinds.include?(node.kind) && node.text.to_s.lstrip.match?(/\A(?:for|while|loop)\b/)
        return :iterates if labeled_loop_node_kinds.include?(node.kind) && node.text.to_s.lstrip.start_with?("for ")
        return :conditional if branch_node?(node)

        nil
      end

      def record_decision_site(document, node, stack, out)
        return if generated_prelude?(document, node)

        if boolean_container?(node) && boolean_and?(node)
          record_conjunction_decision(document, node, stack, out)
          return
        end

        if case_node_kinds.include?(node.kind)
          return if predicate_less_case?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node),
            enclosing_span: span(node)
          )
        elsif hidden_case_wrapper_node_kinds.include?(node.kind)
          return unless hidden_case?(node)
          return if node.named_children.any? { |child| case_node_kinds.include?(child.kind) }
          return if predicate_less_case?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node),
            enclosing_span: span(node)
          )
        elsif hidden_match_node_kinds.include?(node.kind)
          return unless hidden_match?(node)

          patterns = case_patterns(node)
          return if patterns.size < 2

          out << DecisionSite.new(
            kind: :case_dispatch,
            members: patterns,
            file: document.file,
            function: current_function(stack),
            line: line(node),
            span: span(node),
            predicate: decision_predicate(node),
            enclosing_span: span(node)
          )
        end
      end

      def record_conjunction_decision(document, node, stack, out)
        from_wrapper = parenthesized_wrapper?(node)
        return if from_wrapper &&
                  ts_node?(node.parent) &&
                  boolean_container?(node.parent) &&
                  boolean_and?(node.parent)

        node = node.named_children.first if from_wrapper
        return if !from_wrapper &&
                  ts_node?(node.parent) &&
                  boolean_container?(node.parent) &&
                  boolean_and?(node.parent) &&
                  !same_span?(node.parent, node)

        members = flatten_boolean_and(node).map { |child| decision_member_text(child) }.uniq.sort
        return if members.size < 2

        out << DecisionSite.new(
          kind: :conjunction,
          members: members,
          file: document.file,
          function: current_function(stack),
          line: conjunction_span(node)[0],
          span: conjunction_span(node),
          predicate: normalize_text(node.text),
          enclosing_span: decision_enclosing_span(node)
        )
      end

      def decision_enclosing_span(node)
        parent = parent_node(node)
        seen = Set.new
        while ts_node?(parent) && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return span(parent) if branch_node?(parent) || loop_node_kinds.include?(parent.kind)

          parent = parent_node(parent)
        end
        span(node)
      end

      def record_function_def(document, node, stack, out)
        name = function_name(node)
        return unless name

        out << FunctionDef.new(
          file: document.file,
          name: name,
          owner: owner_for_node(document, node, stack: stack),
          line: line(node),
          span: span(node),
          body: node,
          visibility: visibility(document, node),
          params: function_params(node),
          signature: function_signature(document, node),
          kind: function_kind(document, node, stack)
        )
      end

      def record_owner_def(document, node, stack, out)
        owner = owner_name_from_declaration(document, node)
        return unless owner

        full_owner = current_owner(document, stack)
        out << OwnerDef.new(
          file: document.file,
          name: full_owner,
          kind: owner_kind(node),
          line: line(node),
          span: span(node)
        )
      end

      def record_call_site(document, node, stack, out)
        target = call_target(document, node)
        return unless target
        target = normalize_target_receiver(target, stack)
        return if noise_call?(target)

        source_node = target[:source_node] || node
        out << CallSite.new(
          receiver: target[:receiver],
          message: target[:message],
          file: document.file,
          function: current_function(stack),
          owner: current_owner(document, stack),
          line: line(source_node),
          span: span(source_node),
          conditional: conditional_context?(stack),
          arguments: target[:arguments],
          control: current_control(stack),
          safe_navigation: target[:safe_navigation] || false,
          block: target[:block] || call_has_block?(source_node)
        )
      end

      def record_state_declaration(document, node, stack, out)
        declaration = state_declaration(node)
        return unless declaration

        out << StateDeclaration.new(
          field: declaration[:field],
          owner: owner_for_node(document, node, stack: stack),
          type: declaration[:type],
          file: document.file,
          line: line(node),
          span: span(node)
        )
      end

      def record_state_write(document, node, stack, out)
        return if skip_state_write_node?(node)

        lhs =
          if assignment_node_kinds.include?(node.kind)
            named_field(node, "left") || node.named_children.first
          elsif assignment_lhs?(node)
            node
          end
        return unless lhs

        target = state_target(lhs)
        return unless target
        target = normalize_target_receiver(target, stack)
        return if skip_state_write_target?(target)

        source_node = state_write_source_node(node)
        out << StateWrite.new(
          field: target[:field],
          receiver: target[:receiver],
          file: document.file,
          function: current_function(stack),
          line: line(source_node),
          span: span(source_node),
          owner: current_owner(document, stack)
        )
      end

      def skip_state_write_node?(node)
        parent = parent_node(node)
        return false unless parent

        assignment_lhs?(node) &&
          assignment_node_kinds.include?(parent.kind)
      end

      def skip_state_write_target?(target)
        target[:field] == "[]"
      end

      def state_write_source_node(node)
        node
      end

      def record_state_read(document, node, stack, out)
        target = state_read_target(node)
        return unless target
        target = normalize_target_receiver(target, stack)

        out << StateRead.new(
          field: target[:field],
          receiver: target[:receiver],
          file: document.file,
          function: current_function(stack),
          line: line(node),
          span: span(node),
          owner: current_owner(document, stack)
        )
      end

      def record_state_param_origin(document, node, stack, out)
        lhs = nil
        rhs = nil
        if assignment_node_kinds.include?(node.kind)
          lhs = named_field(node, "left") || node.named_children.first
          rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
        elsif assignment_lhs?(node)
          lhs = node
          rhs = next_sibling(next_sibling(node))
        end
        return unless lhs && rhs

        target = state_target(lhs)
        return unless target && rhs
        target = normalize_target_receiver(target, stack)

        params = current_params(stack)
        return if params.empty?

        rhs_param_names(rhs, params).each do |param|
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

      def record_branch_decision(document, node, stack, out, immutable_readers:, immutable_reader_types:, type_aliases:,
                                 method_param_types:)
        return unless branch_node?(node)

        cond = if hidden_modifier_if?(node)
                 modifier_condition(node)
               else
                 named_field(node, "condition") || named_field(node, "value") ||
                   named_field(node, "subject") || node.named_children.first
               end
        return unless cond

        refs = []
        collect_state_refs(
          cond,
          refs,
          defn: current_function(stack),
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases,
          method_param_types: method_param_types
        )
        refs.uniq!
        refs.sort!
        return if refs.empty?

        out << BranchDecision.new(
          file: document.file,
          function: current_function(stack),
          line: line(node),
          span: span(node),
          predicate: normalize_text(cond.text),
          state_refs: refs
        )
      end

      def record_branch_arm(document, node, stack, out)
        return if generated_prelude?(document, node)

        if if_node?(node)
          record_if_arms(document, node, stack, out)
          return
        end

        if branch_loop_node_kinds.include?(node.kind)
          record_loop_arm(document, node, stack, out)
        elsif branch_case_node_kinds.include?(node.kind)
          return if hidden_case_wrapper_node_kinds.include?(node.kind) && !hidden_case?(node)
          return if hidden_match_node_kinds.include?(node.kind) && !hidden_match?(node)

          record_case_arms(document, node, stack, out)
        end
      end

      def record_if_arms(document, node, stack, out)
        predicate = decision_predicate(node)
        dspan = span(node)
        dline = line(node)
        consequence = named_field(node, "consequence") || named_field(node, "body") ||
                      node.named_children[1]
        alternative = named_field(node, "alternative") ||
                      node.named_children.find { |child| child.kind.match?(/else|elsif|alternative/) }
        alternative ||= node.named_children[2] if node.named_children[2] != consequence

        [[consequence, "then"], [alternative, "else"]].each do |arm_node, member|
          next unless ts_node?(arm_node)

          out << BranchArm.new(
            file: document.file,
            function: current_function(stack),
            kind: :if,
            line: line(arm_node),
            span: span(arm_node),
            decision_line: dline,
            decision_span: dspan,
            predicate: predicate,
            member: member,
            body: normalize_text(arm_node.text)
          )
        end
      end

      def record_loop_arm(document, node, stack, out)
        body = named_field(node, "body") || node.named_children[1]
        return unless ts_node?(body)

        out << BranchArm.new(
          file: document.file,
          function: current_function(stack),
          kind: :loop,
          line: line(body),
          span: span(body),
          decision_line: line(node),
          decision_span: span(node),
          predicate: decision_predicate(node),
          member: "body",
          body: normalize_text(body.text)
        )
      end

      def record_case_arms(document, node, stack, out)
        predicate = decision_predicate(node)
        dspan = span(node)
        dline = line(node)
        case_arms(node).each do |arm|
          pattern = case_arm_pattern(arm)
          next if default_case_pattern?(pattern)

          out << BranchArm.new(
            file: document.file,
            function: current_function(stack),
            kind: :case,
            line: line(arm),
            span: span(arm),
            decision_line: dline,
            decision_span: dspan,
            predicate: predicate,
            member: pattern,
            body: normalize_text(case_arm_body(arm))
          )
        end
      end

      def record_implicit_state_accesses(document, out)
        declared = declared_state_index(out[:state_declarations])
        return if declared.empty?

        locals = local_declaration_index(document)
        params = function_param_index(out[:function_defs])
        TreeSitterAdapter.walk_document(document, initial_stack(document), self) do |node, stack|
          next unless implicit_state_identifier?(node)

          owner = current_owner(document, stack)
          function = current_function(stack)
          next if function == "(top-level)"

          field = node.text.to_s
          next unless declared[owner].include?(field)
          next if params[[owner, function]].include?(field)
          next if locals[[owner, function]].include?(field)
          next if identifier_declaration_site?(node)
          next if member_message_identifier?(node)

          if implicit_assignment_lhs?(node)
            out[:state_writes] << StateWrite.new(
              field: field,
              receiver: "self",
              file: document.file,
              function: function,
              line: line(node),
              span: span(node),
              owner: owner
            )
          else
            out[:state_reads] << StateRead.new(
              field: field,
              receiver: "self",
              file: document.file,
              function: function,
              line: line(node),
              span: span(node),
              owner: owner
            )
          end
        end
      end

      def case_patterns(node)
        case_arms(node).flat_map do |child|
          case_arm_patterns(child).reject { |normalized| default_case_pattern?(normalized) }
        end.uniq.sort
      end

      def case_arm_patterns(child)
        if when_case_arm_node_kinds.include?(child.kind)
          patterns = child.named_children.select { |node| case_pattern_node_kinds.include?(node.kind) }
          patterns = [named_field(child, "pattern") || child.named_children.first].compact if patterns.empty?
          case_pattern_texts(patterns)
        elsif switch_case_arm_node_kinds.include?(child.kind)
          return [] if child.text.to_s.lstrip.start_with?("else")

          value = named_field(child, "value") || named_field(child, "pattern") ||
                  child.named_children.find { |candidate| candidate.kind == "when_condition" } ||
                  child.named_children.find { |candidate| candidate.kind == "switch_pattern" } ||
                  child.named_children.first
          value && value.kind !~ /statement|block/ ? [normalize_text(value.text)] : []
        else
          []
        end
      end

      def case_arm_pattern(child)
        patterns = case_arm_patterns(child)
        return nil if patterns.empty?

        patterns.join(", ")
      end

      def case_pattern_texts(patterns)
        return [] if patterns.empty?

        patterns.map { |pattern| normalize_text(pattern.text) }
      end

      def case_arm_body(child)
        pattern = named_field(child, "pattern") || named_field(child, "value") || child.named_children.first
        members = child.named_children
        body = members.drop_while { |node| node == pattern }.drop(1)
        body = members[1..] if body.empty?
        Array(body).map(&:text).join(" ")
      end

      def case_arms(node)
        arms = []
        stack = node.named_children.dup
        until stack.empty?
          child = stack.shift
          next unless ts_node?(child)

          if case_arm_node_kinds.include?(child.kind)
            arms << child
          elsif !case_container_stop_node_kinds.include?(child.kind)
            stack.concat(child.named_children)
          end
        end
        arms
      end

      def decision_predicate(node)
        return normalize_text(modifier_condition(node).text) if hidden_modifier_if?(node) && modifier_condition(node)

        target = decision_subject(node)
        strip_enclosing_parentheses(normalize_text(target ? target.text : node.text))
      end

      def decision_subject(node)
        named_field(node, "value") || named_field(node, "subject") ||
          node.named_children.find { |child| case_subject_node_kinds.include?(child.kind) } ||
          named_field(node, "condition") ||
          node.named_children.find do |child|
            !case_subject_skip_node_kinds.include?(child.kind)
          end
      end

      def predicate_less_case?(node)
        (case_node_kinds.include?(node.kind) || hidden_case?(node)) && !decision_subject(node)
      end

      def default_case_pattern?(text)
        text.nil? || default_case_patterns.include?(text)
      end

      def boolean_and?(node)
        if parenthesized_wrapper?(node)
          child = node.named_children.first
          return boolean_and?(child)
        end

        boolean_and_operators.include?(direct_operator(node))
      end

      def flatten_boolean_and(node)
        return [node] unless ts_node?(node) &&
                             boolean_container?(node) &&
                             boolean_and?(node)
        return flatten_boolean_and(node.named_children.first) if parenthesized_wrapper?(node)

        node.named_children.flat_map { |child| flatten_boolean_and(child) }
      end

      def boolean_container?(node)
        return false unless ts_node?(node)
        return true if boolean_container_node_kinds.include?(node.kind)
        return boolean_container?(node.named_children.first) if parenthesized_wrapper?(node)
        return false unless boolean_wrapper_node_kinds.include?(node.kind)
        return false unless boolean_and_operators.include?(direct_operator(node))
        return false if node.named_children.size < 2

        node.children.all? do |child|
          child.named? || (boolean_and_operators + %w[( )]).include?(child.text.to_s)
        end
      end

      def same_span?(left, right)
        span(left) == span(right)
      end

      def conjunction_span(node)
        base = span(node)
        if parenthesized_pattern_node_kinds.include?(node.kind) && node.text.to_s.lstrip.start_with?("(")
          base = base.dup
          base[1] += 1
        end
        base
      end

      def parenthesized_wrapper?(node)
        ts_node?(node) && parenthesized_wrapper_node_kinds.include?(node.kind) &&
          node.named_children.size == 1
      end

      def decision_member_text(node)
        normalize_text(strip_enclosing_parentheses(node.text))
      end

      def strip_enclosing_parentheses(text)
        value = text.to_s.strip
        loop do
          break value unless value.start_with?("(") && value.end_with?(")")
          break value unless enclosing_parentheses_wrap_all?(value)

          value = value[1...-1].strip
        end
        value
      end

      def enclosing_parentheses_wrap_all?(text)
        depth = 0
        text.each_char.with_index do |char, index|
          depth += 1 if char == "("
          depth -= 1 if char == ")"
          return false if depth.zero? && index < text.length - 1
          return false if depth.negative?
        end
        depth.zero?
      end

      def direct_operator(node)
        node.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s
      rescue StandardError
        ""
      end

      def branch_node?(node)
        branch_node_kinds.include?(node.kind) || hidden_match?(node) || hidden_if?(node) ||
          hidden_modifier_if?(node) || hidden_case?(node)
      end

      def if_node?(node)
        if_node_kinds.include?(node.kind) ||
          hidden_if?(node) || hidden_modifier_if?(node)
      end

      def hidden_if?(node)
        return false unless ts_node?(node)
        return true if hidden_match_node_kinds.include?(node.kind) && node.text.to_s.lstrip.start_with?("if ")
        return false unless hidden_if_wrapper_node_kinds.include?(node.kind)

        first_token = node.children.first
        first_token && !first_token.named? && hidden_if_token_kinds.include?(first_token.kind.to_s)
      end

      def hidden_modifier_if?(node)
        false
      end

      def modifier_condition(node)
        node.named_children.last
      end

      def hidden_case?(node)
        return false unless ts_node?(node)
        return false unless hidden_case_wrapper_node_kinds.include?(node.kind)

        first_token = node.children.first
        first_token && !first_token.named? && hidden_case_token_kinds.include?(first_token.kind.to_s)
      end

      def hidden_match?(node)
        ts_node?(node) &&
          hidden_match_node_kinds.include?(node.kind) &&
          node.text.to_s.lstrip.start_with?("match ")
      end

      def first_token_kind(node)
        node.children.first&.kind.to_s
      end

      def collect_state_refs(node, refs, defn:, immutable_readers:, immutable_reader_types:, type_aliases:,
                             method_param_types:)
        if (ref = direct_state_ref(node))
          refs << ref
        elsif (target = state_read_target(node))
          unless namespace_receiver?(target[:receiver])
            unless immutable_state_read?(target, defn, immutable_readers, immutable_reader_types, type_aliases, method_param_types)
              refs << (target[:receiver] == "self" ? target[:field] : "#{target[:receiver]}.#{target[:field]}")
            end
          end
        end
        node.children.each do |child|
          collect_state_refs(
            child,
            refs,
            defn: defn,
            immutable_readers: immutable_readers,
            immutable_reader_types: immutable_reader_types,
            type_aliases: type_aliases,
            method_param_types: method_param_types
          ) if ts_node?(child)
        end
      end

      def immutable_state_read?(target, defn, immutable_readers, immutable_reader_types, type_aliases, method_param_types)
        receiver = target[:receiver].to_s
        field = target[:field].to_sym
        return false if receiver.empty? || receiver == "self"

        parts = receiver.split(".")
        param = parts.shift
        type = method_param_types.fetch(defn, {})[param]
        return false unless type

        parts.each do |reader|
          type = immutable_reader_result_type(type, reader.to_sym, immutable_reader_types, type_aliases)
          return false unless type
        end
        immutable_reader?(type, field, immutable_readers, type_aliases)
      end

      def immutable_reader?(type_name, field, immutable_readers, type_aliases)
        resolved = resolve_type_alias(type_name, type_aliases)
        short = resolved.to_s.split("::").last
        readers = if immutable_readers.key?(resolved)
                    immutable_readers[resolved]
                  else
                    immutable_readers[short]
                  end
        readers&.include?(field) || false
      end

      def immutable_reader_result_type(type_name, field, immutable_reader_types, type_aliases)
        resolved = resolve_type_alias(type_name, type_aliases)
        short = resolved.to_s.split("::").last
        reader_types = if immutable_reader_types.key?(resolved)
                         immutable_reader_types[resolved]
                       else
                         immutable_reader_types[short]
                       end
        reader_types && reader_types[field]
      end

      def resolve_type_alias(type_name, type_aliases)
        seen = Set.new
        current = type_name.to_s
        loop do
          break current if seen.include?(current)

          seen.add(current)
          target = type_aliases[current] || type_aliases[current.split("::").last]
          break current unless target

          current = target
        end
      end

      def current_params(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:params] }
        Array(entry && entry[:params])
      end

      def rhs_param_names(node, params)
        found = []
        collect_identifiers(node, found)
        found & params
      end

      def collect_identifiers(node, out)
        return unless ts_node?(node)

        pending = [node]
        seen = Set.new
        until pending.empty?
          current = pending.pop
          next unless ts_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key
          out << current.text if current.kind == "identifier"
          current.children.reverse_each { |child| pending << child }
        end
      end

      def declared_state_index(declarations)
        declarations.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |decl, index|
          index[decl.owner.to_s].add(decl.field.to_s)
        end
      end

      def function_param_index(functions)
        functions.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |fn, index|
          index[[fn.owner.to_s, fn.name.to_s]].merge(Array(fn.params).map(&:to_s))
        end
      end

      def local_declaration_index(document)
        index = Hash.new { |h, k| h[k] = Set.new }
        TreeSitterAdapter.walk_document(document, initial_stack(document), self) do |node, stack|
          next unless local_variable_declarator?(node)

          owner = current_owner(document, stack)
          function = current_function(stack)
          next if function == "(top-level)"

          local_name_node(node)&.then { |name| index[[owner, function]].add(name.text.to_s) }
        end
        index
      end

      def local_variable_declarator?(node)
        return false unless ts_node?(node)
        return false unless local_variable_declarator_node_kinds.include?(node.kind)

        !inside_kind?(node, field_declaration_node_kinds)
      end

      def local_name_node(node)
        named_field(node, "name") ||
          node.named_children.find { |child| (identifier_node_kinds + field_identifier_node_kinds).include?(child.kind) }
      end

      def implicit_state_identifier?(node)
        ts_node?(node) && (identifier_node_kinds + field_identifier_node_kinds).include?(node.kind)
      end

      def identifier_declaration_site?(node)
        parent = parent_node(node)
        return false unless parent
        return true if declaration_site_parent_node_kinds.include?(parent.kind)
        return true if inside_kind?(node, field_declaration_node_kinds)

        false
      end

      def member_message_identifier?(node)
        parent = parent_node(node)
        return false unless parent && field_like_node?(parent)

        field = named_field(parent, "field") || named_field(parent, "property") ||
                named_field(parent, "name") || parent.named_children.last
        field == node
      end

      def implicit_assignment_lhs?(node)
        parent = parent_node(node)
        return false unless parent

        if assignment_node_kinds.include?(parent.kind)
          lhs = named_field(parent, "left") || parent.named_children.first
          return lhs == node
        end

        assignment_lhs?(node)
      end

      def inside_kind?(node, kinds)
        parent = parent_node(node)
        seen = Set.new
        while parent && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return true if kinds.include?(parent.kind)

          parent = parent_node(parent)
        end
        false
      end

      def owner_for_node(document, node, stack: nil)
        receiver_owner = receiver_owner_name(node)
        return receiver_owner if receiver_owner
        convention_owner = receiver_convention_owner_name(node)
        return convention_owner if convention_owner

        stacked_owner = current_owner_from_stack(Array(stack))
        return stacked_owner if stacked_owner

        chain = owner_chain_for_node(document, node)
        return chain.join("::") unless chain.empty?

        return file_owner(document.file) if document

        nil
      end

      def owner_chain_for_node(document, node)
        chain = []
        seen = Set.new
        seen_nodes = Set.new
        parent = parent_node(node)
        while parent && !seen_nodes.include?(node_key(parent))
          seen_nodes << node_key(parent)
          if (owner = owner_name_from_declaration(document, parent))
            unless seen.include?(owner)
              chain << owner
              seen << owner
            end
          end
          parent = parent_node(parent)
        end
        chain.reverse
      end

      def impl_owner_name(node)
        type = named_field(node, "type") ||
               node.named_children.find { |child| child.kind.match?(/type|identifier/) }
        normalize_type_owner(type&.text)
      end

      def receiver_owner_name(node)
        receiver_type = method_receiver_type_node(node)
        receiver_type && normalize_type_owner(receiver_type.text)
      end

      def method_receiver_type_node(node)
        declaration = method_receiver_declaration(node)
        return nil unless declaration

        declaration.named_children.reverse.find do |child|
          receiver_type_node_kinds.include?(child.kind)
        end
      end

      def method_receiver_param_node(node)
        declaration = method_receiver_declaration(node)
        return nil unless declaration

        declaration.named_children.find { |child| identifier_node_kinds.include?(child.kind) }
      end

      def method_receiver_declaration(node)
        return nil unless ts_node?(node) && method_receiver_node_kinds.include?(node.kind)

        receiver_params = node.named_children.find { |child| method_parameter_list_node_kinds.include?(child.kind) }
        receiver_params&.named_children&.find { |child| receiver_parameter_node_kinds.include?(child.kind) }
      end

      def first_argument_receiver_parameter(node)
        params = named_field(named_field(node, "declarator"), "parameters") ||
                 named_field(node, "parameters") ||
                 node.named_children.find { |child| parameter_list_node_kinds.include?(child.kind) } ||
                 named_field(node, "declarator")&.named_children&.find { |child| parameter_list_node_kinds.include?(child.kind) }
        first = params&.named_children&.find { |child| receiver_parameter_node_kinds.include?(child.kind) }
        return nil unless first

        type_node = first.named_children.find do |child|
          first_argument_receiver_type_node_kinds.include?(child.kind)
        end
        name_node = first.named_children.reverse.find do |child|
          first_argument_receiver_name_node_kinds.include?(child.kind)
        end
        name_node ||= nested_receiver_name_node(first)
        name_node ||= declarator_name(first)
        return nil unless type_node && name_node

        name = ts_node?(name_node) ? name_node.text : name_node.to_s
        { type: type_node.text, name: name }
      end

      def nested_receiver_name_node(node)
        node.named_children.reverse_each do |child|
          next unless ts_node?(child)

          direct = child.named_children.reverse.find do |grandchild|
            first_argument_receiver_name_node_kinds.include?(grandchild.kind)
          end
          return direct if direct
        end
        nil
      end

      def snake_case_type_name(type)
        type.to_s
            .split("::").last
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
      end

      def bound_container_name(node)
        parent = parent_node(node)
        seen_nodes = Set.new
        while parent && !seen_nodes.include?(node_key(parent)) &&
              bound_container_wrapper_node_kinds.include?(parent.kind)
          seen_nodes << node_key(parent)
          parent = parent_node(parent)
        end
        return nil unless parent

        if bound_container_parent_node_kinds.include?(parent.kind)
          name = named_field(parent, "name") ||
                 parent.named_children.find { |child| bound_container_name_node_kinds.include?(child.kind) }
          return name.text if name
        end
        nil
      end

      def returned_container_owner(document, node)
        parent = parent_node(node)
        seen_nodes = Set.new
        while parent && !seen_nodes.include?(node_key(parent))
          seen_nodes << node_key(parent)
          if (name = function_name(parent))
            return name
          end

          parent = parent_node(parent)
        end
        nil
      end

      def anonymous_owner_name(document, node)
        return nil unless document

        "#{file_owner(document.file)}::anonymous@#{line(node)}"
      end

      def generic_call_target(document, node)
        if adjacent_method_invocation_node_kinds.include?(node.kind)
          adjacent = generic_adjacent_method_invocation_target(node)
          return adjacent if adjacent
        end

        callee = named_field(node, "function") || named_field(node, "callee") || node.named_children.first
        return nil unless callee
        return nil if callee.kind == "builtin_function" || callee.text.to_s.start_with?("@")

        target = target_from_callee(callee).merge(
          arguments: call_argument_nodes(node).map { |argument| normalize_text(argument.text) }
        )
        first_argument_receiver_call_target(document, node, target) || target
      rescue NoMethodError
        nil
      end

      def generic_adjacent_method_invocation_target(node)
        names = node.named_children.select { |child| identifier_node_kinds.include?(child.kind) }
        return nil unless names.size >= 2

        args = node.named_children.find { |child| argument_list_node_kinds.include?(child.kind) }
        {
          receiver: normalize_text(names.first.text),
          message: names[1].text,
          arguments: Array(args&.named_children).map { |child| normalize_text(child.text) }
        }
      end

      def first_argument_receiver_call_target(_document, node, target)
        return nil unless first_argument_receiver?
        return nil unless target[:receiver] == "self"

        first_arg = call_argument_nodes(node).first
        return nil unless first_arg

        arg_target = state_read_target(first_arg)
        return nil unless arg_target

        {
          receiver: "#{arg_target[:receiver]}.#{arg_target[:field]}",
          message: target[:message],
          arguments: target[:arguments]
        }
      end

      def call_argument_nodes(node)
        args = named_field(node, "arguments") ||
               node.named_children.find { |child| argument_list_node_kinds.include?(child.kind) }
        return Array(args&.named_children) if args
        return [] unless call_node_kinds.include?(node.kind)

        callee = named_field(node, "function") || named_field(node, "callee") || node.named_children.first
        node.named_children.reject { |child| child == callee }
      end

      def adjacent_argument_call_target(node)
        return nil if generic_member_name?(node) && !member_message_identifier?(node)
        return nil if call_node_kinds.include?(parent_node(node)&.kind)

        callee = node
        args = nil
        if member_message_identifier?(node)
          parent = parent_node(node)
          if parent && field_like_node?(parent)
            parent_args = next_sibling(parent)
            if argument_list_node_kinds.include?(parent_args&.kind)
              callee = parent
              args = parent_args
            elsif argument_list_node_kinds.include?(next_sibling(node)&.kind)
              callee = parent
              args = next_sibling(node)
            end
          end
        end
        args ||= next_sibling(callee)
        return nil unless argument_list_node_kinds.include?(args&.kind)

        target_from_callee(callee).merge(arguments: args.named_children.map { |child| normalize_text(child.text) })
      rescue NoMethodError
        nil
      end

      def target_from_callee(callee)
        if field_like_node?(callee)
          object = named_field(callee, "object") || named_field(callee, "receiver") ||
                   named_field(callee, "operand") || named_field(callee, "value") ||
                   named_field(callee, "expression") ||
                   callee.named_children.find { |child| child.kind != "navigation_suffix" }
          field = named_field(callee, "field") || named_field(callee, "property") ||
                  named_field(callee, "suffix") ||
                  callee.named_children.find { |child| navigation_suffix_node_kinds.include?(child.kind) } ||
                  callee.named_children.last
          field_text = member_field_text(field)
          return nil unless object && field_text

          {
            receiver: normalize_text(object.text).sub(/\A\*/, ""),
            message: field_text
          }
        elsif self_call_identifier_node_kinds.include?(callee.kind)
          {
            receiver: "self",
            message: callee.text
          }
        else
          text = normalize_text(callee.text)
          return nil if text.empty?

          parts = text.split(".")
          if parts.size > 1
            {
              receiver: parts[0...-1].join("."),
              message: parts[-1]
            }
          else
            {
              receiver: "self",
              message: text
            }
          end
        end
      end

      def noise_call?(target)
        message = target[:message].to_s
        receiver = target[:receiver].to_s
        return true if message.empty?
        return true if NOISE_MESSAGES.include?(message)
        return true if message.start_with?("@")
        return true if receiver.match?(/\A(?:std|builtin|build_options)(?:\.|\z)/)

        false
      end

      def generic_state_declaration(node)
        if assignment_state_declaration_node_kinds.include?(node.kind)
          assignment_state_declaration(node)
        elsif field_declaration_node_kinds.include?(node.kind)
          generic_field_declaration(node)
        end
      end

      def generic_field_declaration(node)
        name = field_declaration_name_node(node)
        return nil unless name

        { field: name.text, type: declared_type_text(node, name) }
      end

      def field_declaration_name_node(node)
        named_field(node, "name") ||
          variable_declarator_name(node) ||
          node.named_children.find { |child| field_identifier_node_kinds.include?(child.kind) } ||
          node.named_children.reverse.find { |child| identifier_node_kinds.include?(child.kind) }
      end

      def variable_declarator_name(node)
        pending = node.named_children.dup
        seen = Set.new
        until pending.empty?
          current = pending.shift
          next unless ts_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key
          if declarator_node_kinds.include?(current.kind)
            direct_name = named_field(current, "name") ||
                          current.named_children.find do |child|
                            (identifier_node_kinds + field_identifier_node_kinds).include?(child.kind)
                          end
            return direct_name if direct_name
            return current if local_variable_declarator_node_kinds.include?(current.kind) && current.text.match?(/\A[A-Za-z_]\w*\z/)
          elsif local_variable_declarator_node_kinds.include?(current.kind)
            return named_field(current, "name") ||
                   current.named_children.find do |child|
                     (identifier_node_kinds + field_identifier_node_kinds).include?(child.kind)
                   end
          end
          pending.concat(current.named_children)
        end
        nil
      end

      def declared_type_text(node, name_node)
        text = node.text.to_s
        after_name = text[(name_node.end_byte - node.start_byte)..].to_s
        if (match = after_name.match(/\A\s*:\s*([^=,\n]+)/))
          normalize_text(match[1])
        elsif (match = text.match(/\A\s*(?:pub\s+)?(?:const|var)\s+\w+\s*:\s*([^=;\n]+)/))
          normalize_text(match[1])
        elsif (match = after_name.match(/\A\s+([^=;,\n]+)/))
          normalize_text(match[1])
        elsif (type = declared_type_before_name(text, node, name_node))
          type
        end
      rescue StandardError
        nil
      end

      def declared_type_before_name(text, node, name_node)
        before_name = text[0...(name_node.start_byte - node.start_byte)].to_s
        before_name = before_name.gsub(/\b(?:public|private|protected|internal|static|readonly|const|pub|mut|var|let)\b/, " ")
        before_name = before_name.gsub(/[;,{].*\z/m, " ")
        before_name = normalize_text(before_name)
        return nil if before_name.empty?

        tokens = before_name.split(/\s+/).reject { |token| token.match?(/\A[*&]+\z/) }
        candidate = tokens.last.to_s.delete_suffix("*").delete_suffix("&")
        return nil if candidate.empty?

        candidate
      end

      def assignment_state_declaration(node)
        lhs = named_field(node, "left") || node.named_children.first
        rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
        target = state_target(lhs)
        return nil unless target
        return nil unless self_receiver_names.include?(target[:receiver].to_s)

        type = inferred_assignment_type(rhs)
        return nil unless type

        { field: target[:field], type: type }
      end

      def inferred_assignment_type(node)
        return nil unless ts_node?(node)

        text = normalize_text(node.text)
        patterns = [
          /\Anew\s+([A-Z][A-Za-z0-9_:]*)\s*(?:[({<]|$)/,
          /\A([A-Z][A-Za-z0-9_:]*)\s*(?:[({<]|$)/
        ]
        match = patterns.filter_map { |pattern| text.match(pattern) }.first
        match && match[1]
      end

      def generic_state_read_target(node)
        if accessor_call_node_kinds.include?(node.kind)
          receiver = named_field(node, "receiver")
          method = named_field(node, "method")
          return nil unless receiver && method
          return nil if namespace_receiver?(receiver.text)
          return nil if NOISE_MESSAGES.include?(method.text)
          return nil if named_field(node, "arguments")

          { receiver: normalize_text(receiver.text), field: method.text }
        elsif field_like_node?(node)
          return nil if expression_list_node_kinds.include?(node.kind) && !(named_field(node, "operand") && named_field(node, "field"))

          object = named_field(node, "object") || named_field(node, "receiver") ||
                   named_field(node, "expression") ||
                   named_field(node, "operand") || named_field(node, "value") ||
                   named_field(node, "argument") ||
                   node.named_children.find { |child| child.kind != "navigation_suffix" }
          field = named_field(node, "field") || named_field(node, "property") ||
                  named_field(node, "name") || named_field(node, "suffix") ||
                  node.named_children.find { |child| navigation_suffix_node_kinds.include?(child.kind) } ||
                  node.named_children.last
          if literal_field_expression_node_kinds.include?(node.kind) && node.text.to_s.start_with?(".")
            field = node.named_children.find { |child| identifier_node_kinds.include?(child.kind) } || field
            return { receiver: ".literal", field: field.text } if field
          end
          field_text = member_field_text(field)
          return nil unless object && field_text
          return nil if namespace_receiver?(object.text)
          return nil if NOISE_MESSAGES.include?(field_text)

          { receiver: normalize_text(object.text), field: field_text }
        end
      end

      def generic_state_target(lhs)
        return nil unless ts_node?(lhs)
        return nil if prev_sibling(lhs)&.text == ":"

        if accessor_call_node_kinds.include?(lhs.kind)
          receiver = named_field(lhs, "receiver")
          method = named_field(lhs, "method")
          return nil unless receiver && method

          { receiver: normalize_text(receiver.text), field: method.text.sub(/=\z/, "") }
        elsif field_like_node?(lhs)
          if expression_list_node_kinds.include?(lhs.kind) && !(named_field(lhs, "operand") && named_field(lhs, "field"))
            return generic_state_target(lhs.named_children.first)
          end

          object = named_field(lhs, "object") || named_field(lhs, "receiver") ||
                   named_field(lhs, "expression") ||
                   named_field(lhs, "operand") || named_field(lhs, "value") ||
                   named_field(lhs, "argument") ||
                   lhs.named_children.find { |child| child.kind != "navigation_suffix" }
          field = named_field(lhs, "field") || named_field(lhs, "property") ||
                  named_field(lhs, "name") || named_field(lhs, "suffix") ||
                  lhs.named_children.find { |child| navigation_suffix_node_kinds.include?(child.kind) } ||
                  lhs.named_children.last
          if literal_field_expression_node_kinds.include?(lhs.kind) && lhs.text.to_s.start_with?(".")
            field = lhs.named_children.find { |child| identifier_node_kinds.include?(child.kind) } || field
            return { receiver: ".literal", field: field.text.sub(/=\z/, "") } if field
          end
          field_text = member_field_text(field)
          return nil unless object && field_text

          { receiver: normalize_text(object.text), field: field_text.sub(/=\z/, "") }
        end
      end

      def assignment_lhs?(node)
        return false if prev_sibling(node)&.text == ":"

        sibling = next_sibling(node)
        sibling && assignment_operator_tokens.include?(sibling.text.to_s)
      end

      def direct_state_ref(_node)
        nil
      end

      def call_has_block?(node)
        ts_node?(node) &&
          node.named_children.any? { |child| block_argument_node_kinds.include?(child.kind) }
      end

      def next_sibling(node)
        node.next_sibling
      rescue StandardError
        nil
      end

      def prev_sibling(node)
        node.prev_sibling
      rescue StandardError
        nil
      end

      def namespace_receiver?(text)
        receiver = text.to_s
        return true if receiver.match?(/\A(?:std|builtin|build_options)(?:\.|\z)/)
        return true if receiver.start_with?("@")

        receiver.match?(/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/)
      end

      def named_field(node, name)
        node.child_by_field_name(name)
      rescue StandardError
        nil
      end

      def parent_node(node)
        node.parent
      rescue StandardError
        nil
      end

      def field_like_node?(node)
        field_like_node_kinds.include?(node.kind)
      end

      def member_expression_list?(node)
        return false unless expression_list_node_kinds.include?(node.kind)
        return true if named_field(node, "operand") && named_field(node, "field")

        node.children.any? do |child|
          !child.named? && member_access_operator_tokens.include?(child.text.to_s)
        end
      end

      def member_field_text(field)
        return nil unless ts_node?(field)

        if navigation_suffix_node_kinds.include?(field.kind)
          suffix = named_field(field, "suffix") ||
                   field.named_children.find { |child| (identifier_node_kinds + field_identifier_node_kinds).include?(child.kind) } ||
                   field.named_children.last
          text = suffix&.text.to_s
          return nil if text.empty?

          return text.sub(/\A[.?]+/, "")
        end

        field.text.to_s.sub(/\A[.?]+/, "")
      end

      def normalize_type_owner(text)
        value = text.to_s.strip
        value = value.sub(/\A[&*]+/, "")
        value = value.gsub(/\b(?:const|mut|var)\b/, "").strip
        value.split(/[({<\s]/).first.to_s.split(".").last
      end

      def first_named_text(node, kinds)
        child = node.named_children.find { |c| kinds.include?(c.kind) }
        child&.text
      end

      def declarator_name(node)
        return nil unless ts_node?(node)

        pending = [node]
        seen = Set.new
        until pending.empty?
          current = pending.pop
          next unless ts_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key
          return current.text if (identifier_node_kinds + field_identifier_node_kinds).include?(current.kind)

          current.named_children.reverse_each { |child| pending << child }
        end
        nil
      end

      def exported_name_visibility(name)
        text = name.to_s
        return nil if text.empty?

        text.match?(/\A[A-Z]/) ? :public : :private
      end

      def modifier_visibility(node)
        return :private if node.children.any? { |child| child.text == "private" }
        return :protected if node.children.any? { |child| child.text == "protected" }
        return :public if node.children.any? { |child| public_visibility_tokens.include?(child.text) }

        nil
      end

      def parameter_name(param)
        return nil unless ts_node?(param)
        return param.text if parameter_identifier_node_kinds.include?(param.kind)

        name = named_field(param, "name") ||
               param.named_children.select do |child|
                 parameter_identifier_node_kinds.include?(child.kind)
               end.last
        text = name&.text.to_s
        return nil if text.empty? || text == "_"

        text
      end

      def normalize_target_receiver(target, stack)
        receiver = target[:receiver].to_s
        return target.merge(receiver: "self") if self_receiver_names.include?(receiver)

        current_receiver = current_receiver_name(stack)
        return target unless current_receiver
        return target.merge(receiver: "self") if receiver == current_receiver

        if receiver.start_with?("#{current_receiver}.")
          return target.merge(receiver: "self.#{receiver.delete_prefix("#{current_receiver}.")}")
        end

        target
      end

      def current_receiver_name(stack)
        entry = stack.reverse.find { |item| item.is_a?(Hash) && item[:receiver] }
        entry && entry[:receiver]
      end

      def file_owner(file)
        base = File.basename(file.to_s, File.extname(file.to_s))
        base.empty? ? "(file)" : base
      end

      def node_key(node)
        [node.kind, node.start_byte, node.end_byte]
      rescue StandardError
        node.object_id
      end

      def ts_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:children)
      end

      def span(node)
        [node.start_point.row + 1, node.start_point.column,
         node.end_point.row + 1, node.end_point.column]
      end

      def line(node)
        node.start_point.row + 1
      end

      def normalize_text(text)
        text.to_s.strip.gsub(/\s+/, " ")
      end
    end

    require_relative "syntax/adapters"

    LanguageProfile = TreeSitterLanguageAdapter

	    LANGUAGE_PROFILES = {
	      ruby: RubySyntaxAdapter.new(
          language: :ruby,
          extensions: %w[.rb],
          lexicon: RUBY_LEXICON,
          package: "tree-sitter-ruby"
        ),
	      python: PythonSyntaxAdapter.new(
          language: :python,
          extensions: %w[.py .pyi],
          lexicon: PYTHON_LEXICON,
          package: "tree-sitter-python"
        ),
	      javascript: JavaScriptSyntaxAdapter.new(
          language: :javascript,
          extensions: %w[.js .jsx .mjs .cjs],
          lexicon: JAVASCRIPT_LEXICON,
          package: "tree-sitter-javascript"
        ),
	      typescript: TypeScriptSyntaxAdapter.new(
          language: :typescript,
          extensions: %w[.ts .tsx],
          lexicon: TYPESCRIPT_LEXICON,
          package: "tree-sitter-typescript"
        ),
	      go: GoSyntaxAdapter.new(
          language: :go,
          extensions: %w[.go],
          lexicon: GO_LEXICON,
          package: "tree-sitter-go"
        ),
	      rust: RustSyntaxAdapter.new(
          language: :rust,
          extensions: %w[.rs],
          lexicon: RUST_LEXICON,
          package: "tree-sitter-rust"
        ),
	      zig: ZigSyntaxAdapter.new(
          language: :zig,
          extensions: %w[.zig],
          lexicon: ZIG_LEXICON,
          package: "@tree-sitter-grammars/tree-sitter-zig"
        ),
	      lua: LuaSyntaxAdapter.new(
          language: :lua,
          extensions: %w[.lua],
          lexicon: LUA_LEXICON,
          package: "@tree-sitter-grammars/tree-sitter-lua"
        ),
	      c: CSyntaxAdapter.new(
          language: :c,
          extensions: %w[.c .h],
          lexicon: C_LEXICON,
          package: "tree-sitter-c",
          first_argument_receiver: true
        ),
	      cpp: CppSyntaxAdapter.new(
          language: :cpp,
          extensions: %w[.cc .cpp .cxx .hh .hpp .hxx],
          lexicon: CPP_LEXICON,
          package: "tree-sitter-cpp"
        ),
	      csharp: CSharpSyntaxAdapter.new(
          language: :csharp,
          extensions: %w[.cs],
          lexicon: CSHARP_LEXICON,
          package: "tree-sitter-c-sharp",
          grammar_names: %w[c-sharp csharp],
          tree_sitter_language_name: "c_sharp"
        ),
	      java: JavaSyntaxAdapter.new(
          language: :java,
          extensions: %w[.java],
          lexicon: JAVA_LEXICON,
          package: "tree-sitter-java"
        ),
	      swift: SwiftSyntaxAdapter.new(
          language: :swift,
          extensions: %w[.swift],
          lexicon: SWIFT_LEXICON,
          package: "tree-sitter-swift"
        ),
	      kotlin: KotlinSyntaxAdapter.new(
          language: :kotlin,
          extensions: %w[.kt .kts],
          lexicon: KOTLIN_LEXICON,
          package: "tree-sitter-kotlin"
        ),
	      php: PhpSyntaxAdapter.new(
          language: :php,
          extensions: %w[.php],
          lexicon: PHP_LEXICON,
          package: "tree-sitter-php"
        )
	    }.freeze

    LANGUAGE_BY_EXTENSION = LANGUAGE_PROFILES.values.each_with_object({}) do |profile, index|
      profile.extensions.each { |extension| index[extension] ||= profile.language }
    end.freeze

    module_function

    def parse(file, language: nil, parser: ENV.fetch("DECOMPLEX_PARSER", "tree_sitter"))
      normalized_parser = parser.to_s.tr("-", "_")
      lang = (language || language_for(file)).to_sym
      key = document_cache_key(file, lang, normalized_parser)
      document_cache.fetch(key) do
        document_cache[key] =
          case normalized_parser
          when "", "tree_sitter", "treesitter"
            TreeSitterAdapter.new.parse(file, language: lang)
          else
            raise ArgumentError, "unknown decomplex parser #{parser.inspect}"
          end
      end
    end

    def document_cache
      @document_cache ||= {}
    end

    def document_cache_key(file, language, parser)
      stat = File.stat(file)
      [File.expand_path(file), language, parser, stat.size, stat.mtime.to_f]
    end

    def parse_uncached(file, language: nil, parser: ENV.fetch("DECOMPLEX_PARSER", "tree_sitter"))
      case parser.to_s.tr("-", "_")
      when "", "tree_sitter", "treesitter"
        TreeSitterAdapter.new.parse(file, language: language)
      else
        raise ArgumentError, "unknown decomplex parser #{parser.inspect}"
      end
    end

    def parser
      ENV.fetch("DECOMPLEX_PARSER", "tree_sitter").to_s.tr("-", "_")
    end

    def tree_sitter?
      %w[tree_sitter treesitter].include?(parser)
    end

	    def language_for(file)
	      forced = ENV["DECOMPLEX_FORCE_LANGUAGE"].to_s.strip
	      return forced.tr("-", "_").to_sym unless forced.empty?

        LANGUAGE_BY_EXTENSION.fetch(File.extname(file).downcase, :ruby)
	    end

    def supported_exts(parser: self.parser)
	      case parser.to_s.tr("-", "_")
	      when "", "tree_sitter", "treesitter"
	        LANGUAGE_PROFILES.values.flat_map(&:extensions).uniq
	      else
	        []
	      end
    end

    def supported_source?(file, parser: self.parser)
      supported_exts(parser: parser).include?(File.extname(file).downcase)
    end

    def language_lexicon(language)
      language_profile(language).lexicon
    end

    def language_profile(language)
      key = language.to_s.empty? ? nil : language.to_sym
      raise ArgumentError, "missing Syntax language profile" unless key

      LANGUAGE_PROFILES.fetch(key)
    rescue KeyError
      raise ArgumentError, "unsupported Syntax language profile: #{language.inspect}"
    end

    class Document
      attr_reader :file, :language, :source, :lines, :root, :adapter

      def initialize(file:, language:, source:, lines:, root:, adapter:)
        @file = file
        @language = language
        @source = source
        @lines = lines
        @tree_sitter_facade = TreeSitterFacadeContext.new(root)
        @root = @tree_sitter_facade.root
        @adapter = adapter
      end

      def decision_sites
        @decision_sites ||= adapter.decision_sites(self)
      end

      def state_writes
        @state_writes ||= adapter.state_writes(self)
      end

      def state_reads
        @state_reads ||= adapter.state_reads(self)
      end

      def branch_decisions(immutable_readers:, immutable_reader_types:, type_aliases:)
        adapter.branch_decisions(
          self,
          immutable_readers: immutable_readers,
          immutable_reader_types: immutable_reader_types,
          type_aliases: type_aliases
        )
      end

      def function_defs
        @function_defs ||= adapter.function_defs(self)
      end

      def owner_defs
        @owner_defs ||= adapter.owner_defs(self)
      end

      def call_sites
        @call_sites ||= adapter.call_sites(self)
      end

      def state_declarations
        @state_declarations ||= adapter.state_declarations(self)
      end

      def state_param_origins
        @state_param_origins ||= adapter.state_param_origins(self)
      end

      def branch_arms
        @branch_arms ||= adapter.branch_arms(self)
      end

      def predicate_defs
        @predicate_defs ||= adapter.predicate_defs(self)
      end

      def comparison_sites
        @comparison_sites ||= adapter.comparison_sites(self)
      end

      def local_methods
        @local_methods ||= adapter.local_methods(self)
      end

      def path_condition_sites
        @path_condition_sites ||= adapter.path_condition_sites(self)
      end

      def immutable_struct_readers
        adapter.immutable_struct_readers(self)
      end

      def immutable_struct_reader_types
        adapter.immutable_struct_reader_types(self)
      end

      def type_aliases
        adapter.type_aliases(self)
      end
    end

    class TreeSitterFacadeContext
      attr_reader :root

      def initialize(raw_root)
        @wrappers = {}
        @children_cache = {}
        @named_children_cache = {}
        @named_field_cache = {}
        @parent_cache = {}
        @prev_sibling_cache = {}
        @next_sibling_cache = {}
        @prev_named_sibling_cache = {}
        @next_named_sibling_cache = {}
        @root = wrap(raw_root)
        index_tree(raw_root)
      end

      def wrap(raw)
        return nil unless raw
        return raw if raw.is_a?(TreeSitterNodeFacade)

        key = node_key(raw)
        @wrappers[key] ||= TreeSitterNodeFacade.new(self, raw, key)
      end

      def children(raw)
        node = unwrap(raw)
        @children_cache.fetch(node_key(node)) { [] }
      end

      def named_children(raw)
        node = unwrap(raw)
        @named_children_cache.fetch(node_key(node)) { [] }
      end

      def child_by_field_name(raw, name)
        node = unwrap(raw)
        key = [node_key(node), name.to_s]
        return @named_field_cache[key] if @named_field_cache.key?(key)

        @named_field_cache[key] = wrap(node.child_by_field_name(name))
      rescue StandardError
        nil
      end

      def parent(raw)
        @parent_cache[node_key(unwrap(raw))]
      end

      def prev_sibling(raw)
        @prev_sibling_cache[node_key(unwrap(raw))]
      end

      def next_sibling(raw)
        @next_sibling_cache[node_key(unwrap(raw))]
      end

      def prev_named_sibling(raw)
        @prev_named_sibling_cache[node_key(unwrap(raw))]
      end

      def next_named_sibling(raw)
        @next_named_sibling_cache[node_key(unwrap(raw))]
      end

      def node_key(raw)
        node = unwrap(raw)
        [node.kind, node.start_byte, node.end_byte, node.named?]
      end

      private

      def unwrap(raw)
        raw.is_a?(TreeSitterNodeFacade) ? raw.raw : raw
      end

      def index_tree(raw_root)
        pending = [raw_root]
        until pending.empty?
          raw = pending.pop
          key = node_key(raw)
          raw_children = Array(raw.children)
          wrapped_children = raw_children.map { |child| wrap(child) }
          @children_cache[key] = wrapped_children
          @named_children_cache[key] = wrapped_children.select(&:named?)

          raw_children.each do |child|
            child_key = node_key(child)
            @parent_cache[child_key] = wrap(raw)
          end

          index_siblings(raw_children, @prev_sibling_cache, @next_sibling_cache)
          index_siblings(raw_children.select(&:named?), @prev_named_sibling_cache, @next_named_sibling_cache)

          pending.concat(raw_children.reverse)
        end
      end

      def index_siblings(raw_children, prev_cache, next_cache)
        raw_children.each_with_index do |child, index|
          key = node_key(child)
          prev_cache[key] = wrap(raw_children[index - 1]) if index.positive?
          next_cache[key] = wrap(raw_children[index + 1]) if index + 1 < raw_children.length
        end
      end
    end

    class TreeSitterNodeFacade
      attr_reader :context, :raw

      def initialize(context, raw, key)
        @context = context
        @raw = raw
        @key = key
      end

      def kind
        @kind ||= raw.kind
      end

      def text
        @text ||= raw.text.to_s
      end

      def start_byte
        raw.start_byte
      end

      def end_byte
        raw.end_byte
      end

      def start_point
        raw.start_point
      end

      def end_point
        raw.end_point
      end

      def named?
        raw.named?
      end

      def has_error?
        raw.respond_to?(:has_error?) && raw.has_error?
      end

      def children
        context.children(self)
      end

      def child_count
        children.length
      end

      def named_children
        context.named_children(self)
      end

      def named_child_count
        named_children.length
      end

      def child_by_field_name(name)
        context.child_by_field_name(self, name)
      end

      def parent
        context.parent(self)
      end

      def prev_sibling
        context.prev_sibling(self)
      end

      def next_sibling
        context.next_sibling(self)
      end

      def prev_named_sibling
        context.prev_named_sibling(self)
      end

      def next_named_sibling
        context.next_named_sibling(self)
      end

      def ==(other)
        other = other.raw if other.is_a?(TreeSitterNodeFacade)
        other.respond_to?(:kind) &&
          kind == other.kind &&
          start_byte == other.start_byte &&
          end_byte == other.end_byte &&
          named? == other.named?
      end

      alias eql? ==

      def hash
        @key.hash
      end

      def inspect
        "#<#{self.class} kind=#{kind.inspect} start_byte=#{start_byte} end_byte=#{end_byte}>"
      end
    end

    class TreeSitterAdapter
      def self.walk_document(document, stack, profile, &block)
        node = document.root
        return unless tree_sitter_node?(node)

        pending = [[node, stack]]
        seen = Set.new
        until pending.empty?
          current, current_stack = pending.pop
          next unless tree_sitter_node?(current)
          key = node_key(current)
          next if seen.include?(key)

          seen << key

          next_stack = profile.push_context(document, current_stack, current)
          yield current, next_stack
          current.children.reverse_each { |child| pending << [child, next_stack] }
        end
      end

      def self.tree_sitter_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:children)
      end

      def self.node_key(node)
        [node.kind, node.start_byte, node.end_byte]
      rescue StandardError
        node.object_id
      end

      def parse(file, language: nil)
        lang = (language || Syntax.language_for(file)).to_sym
        source = File.read(file)
        parser = parser_for(lang)
        tree = parser.parse(source)
        raise "tree-sitter parse timed out for #{file}" unless tree

        Document.new(
          file: file,
          language: lang,
          source: source,
          lines: source.lines,
          root: tree.root_node,
          adapter: self
        )
      end

      def decision_sites(document)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.decision_site_facts(document, node, stack))
        end
        out
      end

      def state_writes(document)
        structural_facts(document).fetch(:state_writes)
      end

      def state_reads(document)
        structural_facts(document).fetch(:state_reads)
      end

      def branch_decisions(document, immutable_readers:, immutable_reader_types:, type_aliases:)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.branch_decision_facts(
            document,
            node,
            stack,
            immutable_readers: immutable_readers,
            immutable_reader_types: immutable_reader_types,
            type_aliases: type_aliases
          ))
        end
        out
      end

      def function_defs(document)
        structural_facts(document).fetch(:function_defs)
      end

      def owner_defs(document)
        structural_facts(document).fetch(:owner_defs)
      end

      def call_sites(document)
        structural_facts(document).fetch(:call_sites)
      end

      def state_declarations(document)
        structural_facts(document).fetch(:state_declarations)
      end

      def state_param_origins(document)
        structural_facts(document).fetch(:state_param_origins)
      end

      def structural_facts(document)
        @structural_fact_cache ||= {}
        @structural_fact_cache[document.object_id] ||= begin
          profile = syntax_profile(document.language)
          out = {
            function_defs: [],
            owner_defs: [],
            call_sites: [],
            state_declarations: [],
            state_param_origins: [],
            state_reads: [],
            state_writes: []
          }
          walk(document, profile) do |node, stack|
            facts = profile.structural_facts_for_node(document, node, stack)
            facts.each do |key, values|
              out.fetch(key).concat(values)
            end
          end
          profile.after_structural_facts(document, out)
          out[:function_defs].uniq! { |fn| [fn.file, fn.owner, fn.name, fn.line] }
          out[:owner_defs].uniq! { |owner| [owner.file, owner.name, owner.kind] }
          out[:call_sites].uniq! { |call| [call.file, call.owner, call.function, call.span, call.receiver, call.message] }
          out[:state_declarations].uniq! { |decl| [decl.file, decl.owner, decl.field] }
          out[:state_param_origins].uniq! { |origin| [origin.file, origin.owner, origin.function, origin.field, origin.param] }
          out[:state_reads].uniq! { |read| [read.file, read.owner, read.function, read.span, read.receiver, read.field] }
          out[:state_writes].uniq! { |write| [write.file, write.owner, write.function, write.span, write.receiver, write.field] }
          out
        end
      end

      def branch_arms(document)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.branch_arm_facts(document, node, stack))
        end
        out
      end

      def predicate_defs(document)
        profile = syntax_profile(document.language)
        document.function_defs.filter_map { |function_def| profile.predicate_def(document, function_def) }
      end

      def comparison_sites(document)
        profile = syntax_profile(document.language)
        out = []
        walk(document, profile) do |node, stack|
          out.concat(profile.comparison_site_facts(document, node, stack))
        end
        out
      end

      def local_methods(document)
        syntax_profile(document.language).local_methods(document)
      end

      def path_condition_sites(document)
        syntax_profile(document.language).path_condition_sites(document)
      end

      def immutable_struct_readers(document)
        syntax_profile(document.language).immutable_struct_readers(document)
      end

      def immutable_struct_reader_types(document)
        syntax_profile(document.language).immutable_struct_reader_types(document)
      end

      def type_aliases(document)
        syntax_profile(document.language).type_aliases(document)
      end

      private

      def syntax_profile(language)
        raise ArgumentError, "missing Syntax language profile context" if language.nil?

        Syntax.language_profile(language)
      end

	      def parser_for(language)
	        require_tree_sitter
	        lang_name = Syntax.language_profile(language).tree_sitter_language_name
	        register_language(lang_name, grammar_path(language))
	        ::TreeSitter::Parser.new.tap { |parser| parser.language = lang_name }
	      end

      def require_tree_sitter
        gem "tree_sitter", "~> 0.1"
        require "tree_sitter"
      rescue Gem::LoadError, LoadError => e
        raise LoadError, "DECOMPLEX_PARSER=tree_sitter requires the tree_sitter gem: #{e.message}"
      end

      def register_language(name, path)
        @registered ||= {}
        return if @registered[name]

        ::TreeSitter.register_language(name, path)
        @registered[name] = true
      end

      def grammar_path(language)
        env_name = "DECOMPLEX_TS_#{language.to_s.upcase}_PATH"
        return ENV.fetch(env_name) if ENV[env_name] && File.file?(ENV[env_name])

        candidates = grammar_candidates(language)
        found = candidates.find { |path| File.file?(path) }
        return found if found

        raise LoadError,
              "missing Tree-sitter grammar for #{language}. Set #{env_name} " \
              "to a parser shared library (.so/.dylib/.node). Checked: #{candidates.join(', ')}"
      end

	      def grammar_candidates(language)
	        profile = Syntax.language_profile(language)
	        pkg = profile.package
	        stems = profile.grammar_names
	        names = stems.flat_map do |stem|
	          ["#{stem}.so", "tree-sitter-#{stem}.so",
	           "libtree-sitter-#{stem}.so", "#{stem}.node",
	           "tree-sitter-#{stem}.node",
	           "#{stem}_binding.node",
	           "tree_sitter_#{stem.tr('-', '_')}_binding.node",
	           "@tree-sitter-grammars+tree-sitter-#{stem}.node"]
	        end
	        roots = [
	          File.expand_path("../../vendor/tree-sitter", __dir__),
	          File.expand_path("../../vendor/tree-sitter/#{language}", __dir__),
          File.expand_path("../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../node_modules/#{pkg}/build/Release", __dir__),
          File.expand_path("../../../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../../../node_modules/#{pkg}/build/Release", __dir__),
          File.expand_path("../../../../../node_modules/#{pkg}", __dir__),
          File.expand_path("../../../../../node_modules/#{pkg}/build/Release", __dir__)
	        ]
	        all_prebuilds = roots.flat_map do |root|
	          stems.flat_map do |stem|
	            Dir.glob(File.join(root, "prebuilds", "*", "*tree-sitter-#{stem}.node"))
	          end
	        end
        prebuilds = platform_prebuilds(all_prebuilds)
        roots.product(names).map { |root, name| File.join(root, name) } + prebuilds
      end

      def platform_prebuilds(paths)
        os = host_os
        arch = host_arch
        return paths if os.nil? || arch.nil?

        paths.select { |path| path.include?("/#{os}-#{arch}/") }
      end

      def host_os
        case RbConfig::CONFIG["host_os"]
        when /linux/i then "linux"
        when /darwin/i then "darwin"
        when /mswin|mingw|cygwin/i then "win32"
        end
      end

      def host_arch
        case RbConfig::CONFIG["host_cpu"]
        when /x86_64|amd64/i then "x64"
        when /aarch64|arm64/i then "arm64"
        end
      end

      def walk(document, profile, &block)
        self.class.walk_document(document, profile.initial_stack(document), profile, &block)
      end

    end

  end
end

require_relative "syntax/effects"
require_relative "syntax/protocols"
require_relative "syntax/contracts"
require_relative "syntax/dispatch"
require_relative "syntax/clone_similarity"
require_relative "syntax/complexity"
require_relative "syntax/nil_guards"
