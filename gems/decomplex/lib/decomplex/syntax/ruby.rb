# frozen_string_literal: true

module Decomplex
  module Syntax
    RUBY_LEXICON = LanguageLexicon.new(
      nil_literal_patterns: [/\bnil\b/].freeze,
      type_guard_patterns: [
        /(?:\A|[^\w!?])(?:nil\?|is_a\?|kind_of\?|instance_of\?|respond_to\?)(?:\s*\(|\b)/,
        /&\./
      ].freeze,
      diagnostic_patterns: [
        /(?:\A|[^\w!?])(?:raise|fail|abort)[!?]?(?:\s*\(|\b)/
      ].freeze,
      trivial_patterns: [
        /\A(?:nil|true|false|0|1|break|next)\s*;?\z/,
        /\Areturn\s+(?:nil|true|false|0|1)\s*;?\z/
      ].freeze
    ).freeze

    class RubySyntaxAdapter < TreeSitterLanguageAdapter
      FUNCTION_NODE_KINDS = %w[method].freeze
      CALL_NODE_KINDS = %w[call].freeze
      CLASS_OWNER_NODE_KINDS = %w[class].freeze
      MODULE_OWNER_NODE_KINDS = %w[module].freeze
      PARAMETER_LIST_NODE_KINDS = %w[method_parameters].freeze
      FUNCTION_BODY_NODE_KINDS = %w[body_statement do_block].freeze
      NESTED_STATEMENT_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      IDENTIFIER_NODE_KINDS = %w[identifier constant].freeze
      FIELD_IDENTIFIER_NODE_KINDS = [].freeze
      PARAMETER_IDENTIFIER_NODE_KINDS = %w[identifier].freeze
      LOCAL_IDENTIFIER_WRAPPER_NODE_KINDS = %w[pattern].freeze
      ASSIGNMENT_NODE_KINDS = %w[assignment operator_assignment].freeze
      ASSIGNMENT_OPERATOR_TOKENS = %w[= += -= *= /= %= &&= ||=].freeze
      PATH_ACTION_NODE_KINDS = %w[call return].freeze
      SIMPLE_ACTION_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      COMPARISON_NODE_KINDS = %w[binary].freeze
      BRANCH_NODE_KINDS = %w[if unless if_modifier unless_modifier case while until for].freeze
      LOOP_NODE_KINDS = %w[while until for do_block].freeze
      BRANCH_LOOP_NODE_KINDS = LOOP_NODE_KINDS
      CASE_NODE_KINDS = %w[case].freeze
      BRANCH_CASE_NODE_KINDS = %w[case body_statement].freeze
      IF_NODE_KINDS = %w[if unless if_modifier unless_modifier].freeze
      HIDDEN_IF_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      HIDDEN_CASE_WRAPPER_NODE_KINDS = %w[body_statement].freeze
      HIDDEN_IF_TOKEN_KINDS = %w[if unless].freeze
      HIDDEN_CASE_TOKEN_KINDS = %w[case when].freeze
      CASE_ARM_NODE_KINDS = %w[when].freeze
      WHEN_CASE_ARM_NODE_KINDS = %w[when].freeze
      CASE_PATTERN_NODE_KINDS = %w[pattern].freeze
      CASE_CONTAINER_STOP_NODE_KINDS = %w[method class module].freeze
      CASE_SUBJECT_SKIP_NODE_KINDS = %w[when else then comment].freeze
      DEFAULT_CASE_PATTERNS = %w[_ default else].freeze
      BOOLEAN_AND_OPERATORS = %w[&& and].freeze
      BOOLEAN_CONTAINER_NODE_KINDS = %w[binary].freeze
      BOOLEAN_WRAPPER_NODE_KINDS = %w[body_statement pattern argument_list].freeze
      PARENTHESIZED_PATTERN_NODE_KINDS = %w[pattern].freeze
      ACCESSOR_CALL_NODE_KINDS = %w[call].freeze
      BLOCK_ARGUMENT_NODE_KINDS = %w[block do_block lambda].freeze
      SELF_RECEIVER_NAMES = %w[self].freeze

      def function_name(node)
        case node.kind
        when "body_statement"
          hidden_ruby_method_name(node)
        when "singleton_method"
          receiver = named_field(node, "receiver") ||
                     node.named_children.find { |child| %w[self constant identifier].include?(child.kind) }
          name = named_field(node, "name")&.text ||
                 node.named_children.reverse.find do |child|
                   %w[identifier field_identifier property_identifier].include?(child.kind)
                 end&.text
          receiver_text = receiver&.text.to_s
          name && "#{receiver_text.empty? || receiver_text == "self" ? "self" : receiver_text}.#{name}"
        when "argument_list"
          inline_def_name(node)
        else
          super
        end
      end

      def visibility(_document, node)
        return ruby_inline_def_visibility(node) if inline_def_argument_list?(node)

        ruby_method_visibility(node)
      end

      def owner_name_from_declaration(document, node)
        return hidden_ruby_owner_name(node) if hidden_ruby_owner_declaration?(node)

        super
      end

      def owner_kind(node)
        return hidden_ruby_owner_kind(node) if hidden_ruby_owner_declaration?(node)

        super
      end

      def call_target(document, node)
        case node.kind
        when "call"
          ruby_proc_call_target(node) || ruby_call_target(node)
        when "body_statement"
          ruby_bare_body_call_target(node)
        when "identifier"
          ruby_bare_call_target(node)
        else
          super
        end
      end
    end


    class RubySyntaxAdapter
      def function_params(node)
        return hidden_ruby_method_params(node) if hidden_ruby_method_definition?(node)

        params = super
        if inline_def_argument_list?(node)
          params = node.named_children.find { |child| child.kind == "method_parameters" }
                       &.named_children
                       &.filter_map { |param| parameter_name(param) }
                       &.uniq || params
        end
        params
      end

      def function_signature(document, node)
        if hidden_ruby_method_definition?(node)
          return normalize_text(hidden_ruby_method_signature(document, node))
        end

        signature = preceding_ruby_signature(document, node)
        return signature unless signature.empty?

        super
      end

      def state_declaration(node)
        ruby_t_let_state_declaration(node) || super
      end

      def state_read_target(node)
        ruby_state_variable_target(node) || super
      end

      def state_target(lhs)
        ruby_state_variable_target(lhs) || super
      end

      def after_structural_facts(document, out)
        super
        apply_ruby_visibility!(out)
      end

      def predicate_def(_document, function_def)
        expression = ruby_single_expression_function_body(function_def.body)
        return nil unless expression

        body = normalize_text(expression.text).delete_suffix(";").strip
        return nil if body.empty? || body == "nil" || body.length > 200

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
          statements = ruby_function_body_statements(function_def.body)
          local_names = ruby_local_names(function_def, statements)
          local_statements = statements.each_with_index.map do |statement, index|
            ruby_local_statement(statement, index, local_names)
          end
          owner = ruby_local_flow_owner(document, function_def.owner)

          LocalMethod.new(
            id: "#{owner}##{function_def.name}",
            owner: owner,
            name: function_def.name,
            file: function_def.file,
            line: function_def.line,
            span: function_def.span,
            node: function_def.body,
            statements: local_statements,
            boundaries: ruby_structural_boundaries(document, local_statements)
          )
        end
      end

      def path_condition_sites(document)
        out = []
        document.function_defs.each do |function_def|
          ruby_function_body_statements(function_def.body).each do |statement|
            ruby_path_walk(document, statement, function_def.name, [], out)
          end
        end
        out
      end

      def immutable_struct_readers(document)
        ruby_immutable_struct_readers(document.lines)
      end

      def immutable_struct_reader_types(document)
        ruby_immutable_struct_reader_types(document.lines)
      end

      def type_aliases(document)
        ruby_type_aliases(document.lines)
      end

      private

      def comparison_target(node)
        ruby_nil_predicate_comparison(node) || super
      end

      def ruby_nil_predicate_comparison(node)
        return nil unless node.kind == "call"

        target = ruby_call_target(node)
        return nil unless target && target[:message].to_s == "nil?"

        { source: normalize_text(node.text), operator: "nil?" }
      end

      def inline_def_argument_list?(node)
        ts_node?(node) && node.kind == "argument_list" && node.children.first&.kind.to_s == "def"
      end

      def inline_def_name(node)
        return nil unless inline_def_argument_list?(node)

        receiver_index = node.named_children.index { |child| child.kind == "self" || child.kind == "constant" }
        search = receiver_index ? node.named_children[(receiver_index + 1)..] : node.named_children
        name = search&.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }&.text
        receiver_index ? "self.#{name}" : name
      end

      def hidden_ruby_method_definition?(node)
        ts_node?(node) && node.kind == "body_statement" && node.children.first&.kind.to_s == "def"
      end

      def hidden_ruby_method_name(node)
        return nil unless hidden_ruby_method_definition?(node)

        receiver_index = node.named_children.index { |child| child.kind == "self" || child.kind == "constant" }
        search = receiver_index ? node.named_children[(receiver_index + 1)..] : node.named_children
        name = search&.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }&.text
        receiver_index ? "self.#{name}" : name
      end

      def hidden_ruby_method_params(node)
        params = node.named_children.find { |child| child.kind == "method_parameters" }
        return [] unless params

        params.named_children.filter_map { |param| parameter_name(param) }.uniq
      end

      def hidden_ruby_method_signature(document, node)
        body = node.named_children.find { |child| child.kind == "body_statement" }
        end_byte = body ? body.start_byte : node.end_byte
        document.source.byteslice(node.start_byte, end_byte - node.start_byte).to_s.strip.sub(/;+\z/, "")
      rescue StandardError
        line_text(document, node).strip
      end

      def ruby_single_expression_function_body(node)
        body = ruby_method_body_wrapper(node)
        return ruby_endless_method_expression(node) unless body

        return nil unless body

        ruby_single_expression_body_child(body)
      end

      def ruby_endless_method_expression(node)
        return nil unless ts_node?(node)
        return nil unless %w[method singleton_method].include?(node.kind)
        return nil if node.named_children.any? { |child| child.kind == "body_statement" }

        node.named_children.reverse.find do |child|
          !%w[
            identifier field_identifier property_identifier constant self
            method_parameters superclass
          ].include?(child.kind)
        end
      end

      def ruby_method_body_wrapper(node)
        return nil unless ts_node?(node)

        case node.kind
        when "method", "singleton_method", "argument_list"
          node.named_children.reverse.find { |child| child.kind == "body_statement" }
        when "body_statement"
          if hidden_ruby_method_definition?(node)
            node.named_children.reverse.find { |child| child.kind == "body_statement" }
          else
            node
          end
        end
      end

      def ruby_single_expression_body_child(body)
        named = body.named_children.reject { |child| child.kind == "comment" }
        return body if named.empty?
        return named.first if named.size == 1
        return named.first if ruby_heredoc_body?(body, named)

        nil
      end

      def ruby_heredoc_body?(_body, named_children)
        named_children.first&.kind == "call" &&
          named_children[1..].to_a.all? { |child| child.kind == "heredoc_body" }
      end

      def ruby_function_body_statements(node)
        body = ruby_method_body_wrapper(node)
        return [] unless body

        named = body.named_children.reject { |child| child.kind == "comment" }
        return [] if named.empty? && body.text.to_s.strip.empty?
        return [body] if hidden_if?(body) || hidden_modifier_if?(body) || hidden_case?(body)
        return [body] if ruby_flat_assignment_statement?(body)
        return [body] if named.empty? || ruby_heredoc_body?(body, named)

        named
      end

      def ruby_local_names(function_def, statements)
        names = Set.new(function_def.params.to_a.map(&:to_s))
        statements.each do |statement|
          ruby_walk_local(statement) do |node|
            names.add(node.text.to_s) if ruby_local_write_identifier?(node)
          end
        end
        names
      end

      def ruby_local_statement(node, index, local_names)
        reads = ruby_local_reads(node, local_names).uniq
        writes = ruby_local_writes(node).uniq
        LocalStatement.new(
          index: index,
          line: line(node),
          end_line: span(node)[2],
          span: span(node),
          source: normalize_text(node.text),
          reads: reads.to_set,
          writes: writes.to_set,
          dependencies: ruby_assignment_dependencies(node, local_names),
          co_uses: reads.combination(2).map { |left, right| [left, right] }
        )
      end

      def ruby_local_reads(node, local_names)
        reads = []
        ruby_walk_local(node) do |child|
          reads << child.text.to_s if ruby_local_read_identifier?(child, local_names)
        end
        reads
      end

      def ruby_local_writes(node)
        writes = []
        ruby_walk_local(node) do |child|
          writes << child.text.to_s if ruby_local_write_identifier?(child)
        end
        writes
      end

      def ruby_assignment_dependencies(node, local_names)
        deps = []
        if ruby_flat_assignment_statement?(node)
          lhs = node.named_children.first
          rhs = node.named_children[1]
          ruby_local_reads(rhs, local_names).uniq.each do |read|
            deps << [lhs.text.to_s, read] unless lhs.text.to_s == read
          end
          return deps.uniq
        end

        ruby_walk_local(node) do |child|
          next unless child.kind == "assignment"

          lhs = child.named_children.first
          rhs = child.named_children[1]
          next unless lhs&.kind == "identifier" && rhs

          ruby_local_reads(rhs, local_names).uniq.each do |read|
            deps << [lhs.text.to_s, read] unless lhs.text.to_s == read
          end
        end
        deps.uniq
      end

      def ruby_structural_boundaries(document, statements)
        statements.each_cons(2).filter_map do |left, right|
          boundary = ruby_source_boundary(document, left.end_line + 1, right.line - 1)
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

      def ruby_source_boundary(document, first_line, last_line)
        return nil if first_line > last_line

        blank = nil
        (first_line..last_line).each do |line_number|
          text = document.lines[line_number - 1].to_s
          stripped = text.strip
          return { line: line_number, kind: :comment, text: stripped } if stripped.start_with?("#")

          blank ||= { line: line_number, kind: :blank, text: stripped } if stripped.empty?
        end
        blank
      end

      def ruby_walk_local(node, &block)
        return unless ts_node?(node)

        stack = [node]
        until stack.empty?
          current = stack.pop
          next unless ts_node?(current)
          next if current != node && ruby_nested_local_scope?(current)

          yield current
          current.children.reverse_each { |child| stack << child }
        end
      end

      def ruby_nested_local_scope?(node)
        %w[class module method singleton_method lambda].include?(node.kind)
      end

      def ruby_local_read_identifier?(node, local_names)
        return false unless node.kind == "identifier"
        return false unless local_names.include?(node.text.to_s)
        return false if ruby_local_write_identifier?(node)
        return false if ruby_declaration_name?(node, parent_node(node))
        return false if ruby_call_message_identifier?(node)

        true
      end

      def ruby_local_write_identifier?(node)
        return false unless node.kind == "identifier"

        parent = parent_node(node)
        (parent&.kind == "assignment" && parent.named_children.first == node) ||
          (ruby_flat_assignment_statement?(parent) && parent.named_children.first == node)
      end

      def ruby_flat_assignment_statement?(node)
        return false unless ts_node?(node) && node.kind == "body_statement"

        node.children.count { |child| !child.named? && child.text == "=" } == 1 &&
          node.named_children.size >= 2
      end

      def ruby_call_message_identifier?(node)
        parent = parent_node(node)
        return false unless parent&.kind == "call"

        prev_sibling(node)&.text == "." ||
          (named_field(parent, "receiver").nil? && parent.named_children.first == node)
      end

      def ruby_local_flow_owner(document, owner)
        owner.to_s == file_owner(document.file) ? "(top-level)" : owner
      end

      def ruby_path_walk(document, node, function, guards, out)
        return unless ts_node?(node)

        if ruby_path_if_node?(node)
          ruby_path_walk_if(document, node, function, guards, out)
          return
        end

        if guards.size >= 2 && ruby_path_action_node?(node)
          record_ruby_path_condition(document, node, function, guards, out)
        end

        node.children.each { |child| ruby_path_walk(document, child, function, guards, out) }
      end

      def ruby_path_walk_if(document, node, function, guards, out)
        condition = ruby_path_condition(node)
        atoms = ruby_path_condition_atoms(condition)
        then_guards = ruby_unless_node?(node) ? ruby_negate_guards(atoms) : atoms
        else_guards = ruby_unless_node?(node) ? atoms : ruby_negate_guards(atoms)

        ruby_path_body_nodes(ruby_path_then_body(node)).each do |child|
          ruby_path_walk(document, child, function, guards + then_guards, out)
        end
        ruby_path_body_nodes(ruby_path_else_body(node)).each do |child|
          ruby_path_walk(document, child, function, guards + else_guards, out)
        end
        ruby_path_walk(document, condition, function, guards, out)
      end

      def ruby_path_if_node?(node)
        return false unless ts_node?(node)
        return true if node.named? && %w[if unless if_modifier unless_modifier].include?(node.kind)

        hidden_if?(node) || hidden_modifier_if?(node)
      end

      def ruby_unless_node?(node)
        node.kind.to_s.include?("unless") || first_token_kind(node) == "unless"
      end

      def ruby_path_condition(node)
        if hidden_modifier_if?(node) || %w[if_modifier unless_modifier].include?(node.kind)
          node.named_children.last
        elsif hidden_if?(node)
          node.named_children.first
        else
          node.named_children.first
        end
      end

      def ruby_path_then_body(node)
        if hidden_modifier_if?(node) || %w[if_modifier unless_modifier].include?(node.kind)
          node.named_children.first
        else
          node.named_children.find { |child| child.kind == "then" } || node.named_children[1]
        end
      end

      def ruby_path_else_body(node)
        return nil if hidden_modifier_if?(node) || %w[if_modifier unless_modifier].include?(node.kind)

        node.named_children.find { |child| child.kind == "else" } ||
          node.named_children.find { |child| child.kind == "elsif" } ||
          node.named_children[2]
      end

      def ruby_path_body_nodes(node)
        return [] unless ts_node?(node)

        return [node] if ruby_path_action_node?(node) || ruby_path_if_node?(node)

        node.named_children.reject { |child| child.kind == "comment" }
      end

      def ruby_path_condition_atoms(condition)
        return [] unless ts_node?(condition)

        flatten_boolean_and(condition).map do |atom|
          text, negated = ruby_path_canon_polarity(decision_member_text(atom))
          [text, negated]
        end
      end

      def ruby_path_canon_polarity(text)
        source = text.to_s.strip
        return [source[1..].to_s.strip, true] if source.start_with?("!")

        [source, false]
      end

      def ruby_negate_guards(guards)
        guards.map { |text, negated| [text, !negated] }
      end

      def ruby_path_action_node?(node)
        return true if %w[call assignment operator_assignment binary].include?(node.kind)

        ruby_flat_assignment_statement?(node)
      end

      def record_ruby_path_condition(document, node, function, guards, out)
        members = guards.map { |text, negated| "#{negated ? "!" : ""}#{text}" }.uniq.sort
        return if members.size < 2

        out << PathConditionSite.new(
          guards: members,
          action: normalize_text(node.text)[0, 80],
          file: document.file,
          function: function,
          line: line(node),
          span: span(node)
        )
      end

      def hidden_ruby_owner_declaration?(node)
        return false unless ts_node?(node)
        return false unless node.kind == "body_statement"

        %w[class module].include?(node.children.first&.kind.to_s)
      end

      def hidden_ruby_owner_name(node)
        node.named_children.find { |child| %w[constant identifier type_identifier].include?(child.kind) }&.text
      end

      def hidden_ruby_owner_kind(node)
        node.children.first&.kind.to_s == "module" ? :module : :class
      end

      def ruby_method_visibility(node)
        modifier_visibility(node)
      end

      def ruby_inline_def_visibility(node)
        parent = parent_node(node)
        return nil unless parent&.kind == "call"

        target = ruby_call_target(parent)
        visibility = target && target[:receiver] == "self" && target[:message]&.to_sym
        %i[private protected public].include?(visibility) ? visibility : nil
      end

      def ruby_call_target(node)
        receiver = named_field(node, "receiver")
        method = named_field(node, "method")
        message = method&.text || first_named_text(node, %w[identifier constant])
        message ||= normalize_text(node.text) if receiver.nil? && ruby_simple_call_text?(node.text)
        return nil unless message

        {
          receiver: receiver ? normalize_text(receiver.text) : "self",
          message: message,
          arguments: ruby_argument_texts(node),
          safe_navigation: ruby_safe_navigation_call?(node)
        }
      end

      def ruby_bare_call_target(node)
        return nil unless ruby_bare_call_identifier?(node)

        parent = parent_node(node)
        source_node =
          if parent&.kind == "call" || next_sibling(node)&.kind == "argument_list"
            parent
          else
            node
          end
        {
          receiver: "self",
          message: node.text,
          arguments: ruby_argument_texts(source_node),
          source_node: source_node,
          safe_navigation: source_node && ruby_safe_navigation_call?(source_node)
        }
      end

      def ruby_bare_body_call_target(node)
        return nil if hidden_ruby_method_definition?(node) || hidden_ruby_owner_declaration?(node)

        explicit = ruby_explicit_receiver_body_call_target(node)
        return explicit if explicit

        message = node.text.to_s.strip
        return nil unless ruby_simple_call_text?(message)
        return nil if %w[true false nil self].include?(message)

        {
          receiver: "self",
          message: message,
          arguments: []
        }
      end

      def ruby_explicit_receiver_body_call_target(node)
        receiver, message = node.named_children
        return nil unless receiver && message
        return nil unless %w[self constant identifier].include?(receiver.kind)
        return nil unless %w[identifier constant].include?(message.kind)

        {
          receiver: normalize_text(receiver.text),
          message: message.text,
          arguments: []
        }
      end

      def ruby_simple_call_text?(text)
        text.to_s.strip.match?(/\A[a-z_]\w*[!?=]?\z/)
      end

      def ruby_bare_call_identifier?(node)
        parent = parent_node(node)
        return false unless parent
        return false if ruby_declaration_name?(node, parent)
        return false if %w[method_parameters block_parameters argument_list assignment].include?(parent.kind)
        if parent.kind == "call"
          return false if named_field(parent, "receiver")

          first = parent.named_children.first
          return first == node && next_sibling(node)&.kind == "argument_list"
        end
        return false if next_sibling(node)&.text == "=" || prev_sibling(node)&.text == "="
        return false if next_sibling(node)&.text == "." || prev_sibling(node)&.text == "."

        %w[body_statement then else elsif ensure rescue].include?(parent.kind) ||
          next_sibling(node)&.kind == "argument_list"
      end

      def ruby_declaration_name?(node, parent)
        return true if hidden_ruby_method_definition?(parent)
        return true if hidden_ruby_owner_declaration?(parent)
        return true if %w[method singleton_method class module].include?(parent.kind)

        false
      end

      def ruby_argument_texts(node)
        args = named_field(node, "arguments") || node.named_children.find { |child| child.kind == "argument_list" }
        return [] unless args

        values = args.named_children.map { |child| normalize_text(child.text) }
        return values unless values.empty?

        text = args.text.to_s.strip
        text = text[1...-1] if text.start_with?("(") && text.end_with?(")")
        text.split(/\s*,\s*/).map { |arg| normalize_text(arg) }.reject(&:empty?)
      end

      def ruby_proc_call_target(node)
        return nil unless ts_node?(node) && node.kind == "call"
        return nil unless node.children.any? { |child| !child.named? && child.text == "." }
        return nil unless named_field(node, "method").nil?

        receiver = named_field(node, "receiver") || node.named_children.first
        args = named_field(node, "arguments") ||
               node.named_children.find { |child| child.kind == "argument_list" }
        return nil unless receiver && args

        {
          receiver: normalize_text(receiver.text),
          message: "call",
          arguments: ruby_argument_texts(node),
          safe_navigation: ruby_safe_navigation_call?(node),
          block: call_has_block?(node)
        }
      end

      def ruby_safe_navigation_call?(node)
        ts_node?(node) && node.children.any? { |child| !child.named? && child.text == "&." }
      end

      def ruby_t_let_state_declaration(node)
        lhs = named_field(node, "left") || node.named_children.first
        rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
        target = state_target(lhs)
        return nil unless target && target[:receiver] == "self" && target[:field].to_s.start_with?("@")
        return nil unless rhs&.kind == "call"

        receiver = named_field(rhs, "receiver") || rhs.named_children.first
        method = named_field(rhs, "method") || rhs.named_children.find { |child| child.kind == "identifier" }
        return nil unless receiver&.text == "T" && method&.text == "let"

        args = named_field(rhs, "arguments") || rhs.named_children.find { |child| child.kind == "argument_list" }
        type = args&.named_children&.[](1)&.text
        return nil if type.to_s.empty?

        { field: target[:field], type: normalize_text(type) }
      end

      def skip_state_write_node?(node)
        node.kind == "operator_assignment" ||
          (assignment_lhs?(node) && next_sibling(node)&.text.to_s != "=" && !ruby_instance_variable_node?(node))
      end

      def skip_state_write_target?(target)
        super || target[:field].to_s.start_with?("$")
      end

      def state_write_source_node(node)
        assignment_lhs?(node) ? (parent_node(node) || node) : super
      end

      def direct_state_ref(node)
        node.text if ruby_state_variable_node?(node)
      end

      def hidden_if?(node)
        return false unless ts_node?(node)
        return false unless %w[expression_statement block body_statement].include?(node.kind)

        %w[if unless].include?(first_token_kind(node))
      end

      def hidden_modifier_if?(node)
        return false unless ts_node?(node)
        return false unless node.kind == "body_statement"

        seen_named = false
        node.children.any? do |child|
          seen_named ||= child.named?
          seen_named && !child.named? && %w[if unless].include?(child.kind)
        end
      end

      def modifier_condition(node)
        node.named_children.last
      end

      def hidden_case?(node)
        return false unless ts_node?(node)
        return false unless %w[body_statement block_body argument_list].include?(node.kind)

        first_token_kind(node) == "case"
      end

      def hidden_match?(node)
        node.kind == "expression_statement" &&
          first_token_kind(node) == "match" &&
          node.named_children.any? { |child| child.kind == "match_block" }
      end

      def case_pattern_texts(patterns)
        texts = super
        return texts unless texts.any? { |text| text.start_with?("*") }

        out = []
        pending_plain = []
        texts.each_with_index do |text, index|
          if text.start_with?("*")
            out << pending_plain.join(", ") unless pending_plain.empty?
            pending_plain = []
            out << if texts.size == 1 || index.positive?
                     text.delete_prefix("*")
                   else
                     text
                   end
          else
            pending_plain << text
          end
        end
        out << pending_plain.join(", ") unless pending_plain.empty?
        out
      end

      def ruby_state_variable_target(node)
        return nil unless ruby_state_variable_node?(node)

        { receiver: "self", field: node.text }
      end

      def ruby_state_variable_node?(node)
        return false unless ts_node?(node)
        return true if %w[instance_variable global_variable].include?(node.kind)

        node.named_children.empty? && node.text.to_s.match?(/\A[@$][A-Za-z_]\w*[!?=]?\z/)
      end

      def ruby_instance_variable_node?(node)
        ts_node?(node) && node.kind == "instance_variable"
      end

      def preceding_ruby_signature(document, node)
        cursor = line(node) - 2
        lines = document.lines
        cursor -= 1 while cursor >= 0 && lines[cursor].to_s.strip.empty?
        return "" if cursor.negative?

        stripped = lines[cursor].to_s.strip
        if stripped == "end"
          start = cursor
          while start >= 0
            text = lines[start].to_s.strip
            return normalize_text(lines[start..cursor].join("\n")) if text == "sig do"
            return "" if start != cursor && text.match?(/\A(?:def|class|module)\b/)

            start -= 1
          end
          return "" if start.negative?
        end

        return normalize_text(stripped) if stripped.start_with?("sig ")
        return "" unless stripped == "}" || stripped.end_with?("}")

        start = cursor
        while start >= 0
          text = lines[start].to_s.strip
          return normalize_text(lines[start..cursor].join("\n")) if text.start_with?("sig ")
          return "" if text.match?(/\A(?:def|class|module)\b/)

          start -= 1
        end
        ""
      end

      def method_param_types(document)
        types_by_method = {}
        pending_sig = +""
        document.lines.each do |line|
          pending_sig << line if pending_sig_active?(line, pending_sig)
          if (match = line.match(/\A\s*def\s+([A-Za-z_]\w*[!?=]?)(?:\s|\(|$)/))
            types_by_method[match[1]] = sig_param_types(pending_sig)
            pending_sig = +""
          end
        end
        types_by_method
      end

      def pending_sig_active?(line, pending_sig)
        !pending_sig.empty? || line.match?(/\A\s*sig\b/)
      end

      def sig_param_types(sig_source)
        match = sig_source.match(/params\s*\((.*?)\)/m)
        return {} unless match

        match[1].scan(/([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)/).to_h
      end

      def ruby_immutable_struct_readers(lines)
        readers = Hash.new { |h, k| h[k] = Set.new }
        class_stack = []
        lines.each do |line|
          if (match = line.match(/\A\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b/))
            class_stack << match[1]
            next
          end
          if class_stack.any? && (match = line.match(/\A\s*const\s+:([A-Za-z_]\w*)\b/))
            readers[class_stack.last].add(match[1].to_sym)
            next
          end
          class_stack.pop if class_stack.any? && line.match?(/\A\s*end\s*(?:#.*)?\z/)
        end
        readers
      end

      def ruby_immutable_struct_reader_types(lines)
        reader_types = Hash.new { |h, k| h[k] = {} }
        class_stack = []
        lines.each do |line|
          if (match = line.match(/\A\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b/))
            class_stack << match[1]
            next
          end
          if class_stack.any? && (match = line.match(/\A\s*const\s+:([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\b/))
            reader_types[class_stack.last][match[1].to_sym] = match[2]
            next
          end
          class_stack.pop if class_stack.any? && line.match?(/\A\s*end\s*(?:#.*)?\z/)
        end
        reader_types
      end

      def ruby_type_aliases(lines)
        aliases = {}
        lines.each do |line|
          if (match = line.match(/\A\s*([A-Z]\w*)\s*=\s*T\.type_alias\s*\{\s*([A-Z]\w*(?:::[A-Z]\w*)*)\s*\}/))
            aliases[match[1]] = match[2]
          elsif (match = line.match(/\A\s*([A-Z]\w*)\s*=\s*([A-Z]\w*(?:::[A-Z]\w*)*)\b/))
            aliases[match[1]] = match[2]
          end
        end
        aliases
      end

      def apply_ruby_visibility!(out)
        functions_by_owner = out.fetch(:function_defs).group_by(&:owner)
        calls_by_owner = out.fetch(:call_sites).group_by(&:owner)
        functions_by_owner.each do |owner, functions|
          calls = Array(calls_by_owner[owner])

          visibility = :public
          events = (functions + ruby_visibility_calls(calls)).sort_by do |event|
            [event.line, event.is_a?(CallSite) ? 0 : 1]
          end

          events.each do |event|
            if event.is_a?(FunctionDef)
              event.visibility ||= event.name.to_s.include?(".") ? :public : visibility
            elsif event.arguments.to_a.empty?
              visibility = event.message.to_sym
            else
              event.arguments.each do |arg|
                name = ruby_visibility_arg_name(arg)
                functions.reverse_each do |function|
                  next unless function.name.to_s == name

                  function.visibility = event.message.to_sym
                  break
                end
              end
            end
          end
        end
      end

      def ruby_visibility_calls(calls)
        calls.select do |call|
          call.function == "(top-level)" &&
            call.receiver == "self" &&
            %w[public protected private].include?(call.message.to_s)
        end
      end

      def ruby_visibility_arg_name(arg)
        arg.to_s.strip
           .delete_prefix(":")
           .delete_prefix("\"")
           .delete_suffix("\"")
           .delete_prefix("'")
           .delete_suffix("'")
      end
    end

  end
end
