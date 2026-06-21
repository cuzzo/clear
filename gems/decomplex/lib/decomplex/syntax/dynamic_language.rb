# frozen_string_literal: true

module Decomplex
  module Syntax
    module DynamicLanguageSyntax
      def dynamic_predicate_def(function_def)
        expression = dynamic_single_expression_function_body(function_def.body) ||
                     dynamic_predicate_expression_body(function_def.body)
        return nil unless expression

        body = normalize_text(expression.text).delete_suffix(";").strip
        return nil if body.empty? || body == "nil" || body.length > 200
        return nil unless dynamic_predicate_body?(body)

        PredicateDef.new(
          file: function_def.file,
          name: function_def.name,
          owner: function_def.owner,
          body: body,
          line: function_def.line,
          span: function_def.span
        )
      end

      def dynamic_local_methods(document)
        document.function_defs.map do |function_def|
          statements = dynamic_function_body_statements(function_def.body)
          local_names = dynamic_local_names(function_def, statements)
          local_statements = statements.each_with_index.map do |statement, index|
            dynamic_local_statement(statement, index, local_names)
          end
          owner = dynamic_local_flow_owner(document, function_def.owner)

          LocalMethod.new(
            id: "#{owner}##{function_def.name}",
            owner: owner,
            name: function_def.name,
            file: function_def.file,
            line: function_def.line,
            span: function_def.span,
            node: function_def.body,
            statements: local_statements,
            boundaries: dynamic_structural_boundaries(document, local_statements)
          )
        end
      end

      def dynamic_path_condition_sites(document)
        out = []
        document.function_defs.each do |function_def|
          dynamic_function_body_statements(function_def.body).each do |statement|
            dynamic_path_walk(document, statement, function_def.name, [], out)
          end
        end
        out.uniq { |site| [site.guards, site.action, site.file, site.function, site.line] }
      end

      private

      def dynamic_single_expression_function_body(node)
        body = dynamic_method_body_wrapper(node)
        return dynamic_endless_function_expression(node) unless body

        dynamic_single_expression_body_child(body)
      end

      def dynamic_predicate_expression_body(node)
        body = dynamic_method_body_wrapper(node)
        return nil unless body

        expression = dynamic_single_expression_body_child(body)
        return expression if expression

        source = normalize_text(body.text).delete_suffix(";").strip
        return body if dynamic_flat_predicate_body_statement?(body, source)

        nil
      end

      def dynamic_single_expression_body_child(body)
        named = body.named_children.reject { |child| child.kind == "comment" }
        return body if named.empty?
        return named.first if named.size == 1
        return named.first if dynamic_heredoc_body?(body, named)

        nil
      end

      def dynamic_predicate_body?(source)
        text = source.to_s
        lower = text.downcase
        %w[true false].include?(lower) ||
          lower.include?("true") ||
          lower.include?("false") ||
          lower.include?("null") ||
          lower.include?("nil") ||
          text.include?("==") ||
          text.include?("!=") ||
          text.include?("&&") ||
          text.include?("||") ||
          lower.include?(" and ") ||
          lower.include?(" or ")
      end

      def dynamic_function_body_statements(node)
        body = dynamic_method_body_wrapper(node)
        return [] unless body

        named = body.named_children.reject { |child| child.kind == "comment" }
        return [] if named.empty? && body.text.to_s.strip.empty?
        return [body] if dynamic_hidden_if?(body) || dynamic_hidden_modifier_if?(body) || dynamic_hidden_case?(body)
        return [body] if dynamic_flat_assignment_statement?(body)
        return [body] if named.empty? || dynamic_heredoc_body?(body, named)

        named
      end

      def dynamic_local_names(function_def, statements)
        names = Set.new(function_def.params.to_a.map(&:to_s))
        statements.each do |statement|
          dynamic_walk_local(statement) do |node|
            names.add(node.text.to_s) if dynamic_local_write_identifier?(node)
          end
        end
        names
      end

      def dynamic_local_statement(node, index, local_names)
        reads = dynamic_local_reads(node, local_names).uniq
        writes = dynamic_local_writes(node).uniq
        LocalStatement.new(
          index: index,
          line: line(node),
          end_line: span(node)[2],
          span: span(node),
          source: normalize_text(node.text),
          reads: reads.to_set,
          writes: writes.to_set,
          dependencies: dynamic_assignment_dependencies(node, local_names),
          co_uses: reads.sort.combination(2).map { |left, right| [left, right] }
        )
      end

      def dynamic_local_reads(node, local_names)
        reads = []
        dynamic_walk_local(node) do |child|
          reads << child.text.to_s if dynamic_local_read_identifier?(child, local_names)
        end
        reads
      end

      def dynamic_local_writes(node)
        writes = []
        dynamic_walk_local(node) do |child|
          writes << child.text.to_s if dynamic_local_write_identifier?(child)
        end
        writes
      end

      def dynamic_assignment_dependencies(node, local_names)
        deps = []
        if dynamic_flat_assignment_statement?(node)
          lhs = node.named_children.first
          rhs = node.named_children[1]
          dynamic_local_reads(rhs, local_names).uniq.each do |read|
            deps << [lhs.text.to_s, read] unless lhs.text.to_s == read
          end
          return deps.uniq
        end

        dynamic_walk_local(node) do |child|
          next unless child.kind == "assignment"

          lhs = child.named_children.first
          rhs = child.named_children[1]
          next unless lhs&.kind == "identifier" && rhs

          dynamic_local_reads(rhs, local_names).uniq.each do |read|
            deps << [lhs.text.to_s, read] unless lhs.text.to_s == read
          end
        end
        deps.uniq
      end

      def dynamic_structural_boundaries(document, statements)
        statements.each_cons(2).filter_map do |left, right|
          boundary = dynamic_source_boundary(document, left.end_line + 1, right.line - 1)
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

      def dynamic_source_boundary(document, first_line, last_line)
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

      def dynamic_walk_local(node, &block)
        return unless ts_node?(node)

        stack = [node]
        until stack.empty?
          current = stack.pop
          next unless ts_node?(current)
          next if current != node && dynamic_nested_local_scope?(current)

          yield current
          current.children.reverse_each { |child| stack << child }
        end
      end

      def dynamic_path_walk(document, node, function, guards, out)
        return unless ts_node?(node)

        if dynamic_path_if_node?(node)
          dynamic_path_walk_if(document, node, function, guards, out)
          return
        end

        if guards.size >= 2 && dynamic_path_action_node?(node)
          record_dynamic_path_condition(document, node, function, guards, out)
          return
        end

        node.children.each { |child| dynamic_path_walk(document, child, function, guards, out) }
      end

      def dynamic_path_walk_if(document, node, function, guards, out)
        condition = dynamic_path_condition(node)
        atoms = dynamic_path_condition_atoms(condition)
        then_guards = dynamic_unless_node?(node) ? dynamic_negate_guards(atoms) : atoms
        else_guards = dynamic_unless_node?(node) ? atoms : dynamic_negate_guards(atoms)

        dynamic_path_body_nodes(dynamic_path_then_body(node)).each do |child|
          dynamic_path_walk(document, child, function, guards + then_guards, out)
        end
        dynamic_path_body_nodes(dynamic_path_else_body(node)).each do |child|
          dynamic_path_walk(document, child, function, guards + else_guards, out)
        end
        dynamic_path_walk(document, condition, function, guards, out)
      end

      def dynamic_path_if_node?(node)
        return false unless ts_node?(node)
        return true if node.named? && dynamic_path_if_node_kinds.include?(node.kind)

        dynamic_hidden_if?(node) || dynamic_hidden_modifier_if?(node)
      end

      def dynamic_unless_node?(node)
        node.kind.to_s.include?("unless") || first_token_kind(node) == "unless"
      end

      def dynamic_path_condition(node)
        if dynamic_hidden_modifier_if?(node) || dynamic_modifier_if_node_kind?(node.kind)
          node.named_children.last
        elsif dynamic_hidden_if?(node)
          node.named_children.first
        else
          node.named_children.first
        end
      end

      def dynamic_path_then_body(node)
        if dynamic_hidden_modifier_if?(node) || dynamic_modifier_if_node_kind?(node.kind)
          node.named_children.first
        else
          node.named_children.find { |child| child.kind == "then" } || node.named_children[1]
        end
      end

      def dynamic_path_else_body(node)
        return nil if dynamic_hidden_modifier_if?(node) || dynamic_modifier_if_node_kind?(node.kind)

        node.named_children.find { |child| child.kind == "else" } ||
          node.named_children.find { |child| child.kind == "elsif" } ||
          node.named_children[2]
      end

      def dynamic_path_body_nodes(node)
        return [] unless ts_node?(node)
        return [node] if dynamic_path_action_node?(node) || dynamic_path_if_node?(node)

        node.named_children.reject { |child| child.kind == "comment" }
      end

      def dynamic_path_condition_atoms(condition)
        return [] unless ts_node?(condition)

        flatten_boolean_and(condition).map do |atom|
          text, negated = dynamic_path_canon_polarity(decision_member_text(atom))
          [text, negated]
        end
      end

      def dynamic_path_canon_polarity(text)
        source = text.to_s.strip
        return [source[1..].to_s.strip, true] if source.start_with?("!")

        [source, false]
      end

      def dynamic_negate_guards(guards)
        guards.map { |text, negated| [text, !negated] }
      end

      def dynamic_path_action_node?(node)
        return true if (dynamic_path_action_node_kinds + dynamic_assignment_node_kinds + %w[binary]).include?(node.kind)

        dynamic_flat_assignment_statement?(node)
      end

      def record_dynamic_path_condition(document, node, function, guards, out)
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

      def dynamic_method_body_wrapper(node)
        node
      end

      def dynamic_endless_function_expression(_node)
        nil
      end

      def dynamic_heredoc_body?(_body, _named_children)
        false
      end

      def dynamic_flat_predicate_body_statement?(_body, _source)
        false
      end

      def dynamic_hidden_if?(node)
        false
      end

      def dynamic_hidden_modifier_if?(_node)
        false
      end

      def dynamic_hidden_case?(_node)
        false
      end

      def dynamic_nested_local_scope?(_node)
        false
      end

      def dynamic_local_read_identifier?(_node, _local_names)
        false
      end

      def dynamic_local_write_identifier?(_node)
        false
      end

      def dynamic_flat_assignment_statement?(_node)
        false
      end

      def dynamic_local_flow_owner(_document, owner)
        owner
      end

      def dynamic_path_if_node_kinds
        dynamic_const(:IF_NODE_KINDS)
      end

      def dynamic_path_action_node_kinds
        dynamic_const(:PATH_ACTION_NODE_KINDS)
      end

      def dynamic_assignment_node_kinds
        dynamic_const(:ASSIGNMENT_NODE_KINDS)
      end

      def dynamic_modifier_if_node_kind?(_kind)
        false
      end

      def dynamic_const(name)
        self.class.const_defined?(name, false) ? self.class.const_get(name) : []
      end
    end
  end
end
