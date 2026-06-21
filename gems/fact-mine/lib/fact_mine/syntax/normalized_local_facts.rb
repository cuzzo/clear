# frozen_string_literal: true

module FactMine
  module Syntax
    class NormalizedLocalFactsAnalyzer
      LocalMethodRow = Struct.new(:row, :node, keyword_init: true)

      def self.analyze(row, language:, file:, lines:)
        new(row, language: language, file: file, lines: lines).analyze
      end

      def initialize(row, language:, file:, lines:)
        @row = row
        @language = language.to_sym
        @file = file
        @lines = lines
      end

      def analyze
        local_method_rows = function_nodes.filter_map { |node| local_method_row(node) }
        {
          "local_methods" => local_method_rows.map(&:row),
          "path_conditions" => path_condition_rows(local_method_rows),
          "local_complexity_scores" => local_complexity_rows(local_method_rows),
          "local_contract_assignments" => local_contract_assignment_rows(local_method_rows)
        }
      end

      private

      def function_nodes
        walk(normalized_root).select { |node| %w[DEFN DEFS].include?(node_type(node)) }
      end

      def local_method_row(function)
        meta = function_meta(function)
        return nil unless meta

        statements = body_statements(function)
        local_names = local_names_for(meta, statements)
        statement_rows = statements.each_with_index.map do |statement, index|
          local_statement_row(statement, index, local_names)
        end
        row = {
          "id" => "#{local_owner(meta.fetch("owner"))}##{meta.fetch("name")}",
          "owner" => local_owner(meta.fetch("owner")),
          "name" => meta.fetch("name"),
          "file" => @file,
          "line" => meta.fetch("line"),
          "span" => meta.fetch("span"),
          "statements" => statement_rows,
          "boundaries" => structural_boundaries(statement_rows)
        }
        LocalMethodRow.new(row: row, node: function)
      end

      def function_meta(function)
        name = function_name(function)
        line = node_line(function)
        @row.fetch("functions").find do |row|
          row.fetch("name").to_s == name && row.fetch("line").to_i == line
        end
      end

      def local_owner(owner)
        file_owner = File.basename(@file, File.extname(@file)).split(/[_-]/).map(&:capitalize).join
        owner_name = owner.to_s
        return "(top-level)" if owner_name == file_owner

        owner_name.sub(/\A#{Regexp.escape(file_owner)}::/, "")
      end

      def body_statements(function)
        scope = function_scope(function)
        body = child_node(scope, 2)
        return [] unless normalized_node?(body)
        return node_children(body) if node_type(body) == "BLOCK"
        return node_children(body) if node_type(body) == "HASH" && node_children(body).all? { |child| node_type(child) == "HASH" }

        [body]
      end

      def function_scope(function)
        case node_type(function)
        when "DEFS"
          child_node(function, 2)
        else
          child_node(function, 1)
        end
      end

      def function_name(function)
        case node_type(function)
        when "DEFS"
          scalar_child(function, 1).to_s
        else
          scalar_child(function, 0).to_s
        end
      end

      def local_names_for(meta, statements)
        names = Set.new(Array(meta.fetch("params", [])).map(&:to_s))
        statements.each do |statement|
          names.merge(local_writes(statement))
        end
        names
      end

      def local_statement_row(node, index, local_names)
        reads = local_reads(node, local_names).uniq
        writes = local_writes(node).uniq
        {
          "index" => index,
          "line" => node_line(node),
          "end_line" => node_span(node)[2],
          "span" => node_span(node),
          "source" => compact_text(node),
          "reads" => reads.sort,
          "writes" => writes.sort,
          "dependencies" => writes.product(reads).reject { |left, right| left == right }.uniq.sort,
          "co_uses" => reads.sort.combination(2).map { |left, right| [left, right] }
        }
      end

      def local_reads(node, local_names)
        reads = []
        walk(node).each do |child|
          name = local_identifier(child)
          next unless name && local_names.include?(name)
          next if assignment_target?(child)
          next if method_message?(child)

          reads << name
        end
        reads
      end

      def local_writes(node)
        writes = []
        walk(node).each do |child|
          case node_type(child)
          when "LASGN", "DASGN"
            name = scalar_child(child, 0).to_s
            writes << name unless name.empty?
          when "MASGN"
            writes.concat(node_children(child).flat_map { |grandchild| local_writes(grandchild) })
          end
        end
        writes
      end

      def assignment_target?(node)
        %w[LASGN DASGN].include?(node_type(parent_of(node))) &&
          scalar_child(parent_of(node), 0).to_s == local_identifier(node).to_s
      end

      def method_message?(node)
        parent = parent_of(node)
        return false unless parent

        case node_type(parent)
        when "CALL", "QCALL"
          scalar_child(parent, 1).to_s == local_identifier(node).to_s
        when "FCALL", "VCALL"
          scalar_child(parent, 0).to_s == local_identifier(node).to_s
        else
          false
        end
      end

      def structural_boundaries(statement_rows)
        statement_rows.each_cons(2).filter_map do |left, right|
          boundary = source_boundary(left.fetch("end_line") + 1, right.fetch("line") - 1)
          next unless boundary

          {
            "before_index" => left.fetch("index"),
            "after_index" => right.fetch("index"),
            "line" => boundary.fetch(:line),
            "kind" => boundary.fetch(:kind).to_s,
            "text" => boundary.fetch(:text)
          }
        end
      end

      def source_boundary(first_line, last_line)
        return nil if first_line > last_line

        blank = nil
        (first_line..last_line).each do |line_number|
          text = @lines[line_number - 1].to_s
          stripped = text.strip
          return { line: line_number, kind: :comment, text: stripped } if stripped.start_with?("#", "//", "--")

          blank ||= { line: line_number, kind: :blank, text: stripped } if stripped.empty?
        end
        blank
      end

      def path_condition_rows(local_method_rows)
        out = []
        local_method_rows.each do |method_row|
          body_statements(method_row.node).each do |statement|
            path_walk(statement, method_row.row.fetch("name"), [], out)
          end
        end
        out.uniq { |site| [site.fetch("guards"), site.fetch("action"), site.fetch("function"), site.fetch("line")] }
      end

      def path_walk(node, function, guards, out)
        return unless normalized_node?(node)

        if branch_node?(node)
          path_walk_branch(node, function, guards, out)
          return
        end

        if guards.size >= 2 && path_action_node?(node)
          out << {
            "guards" => guards.uniq.sort,
            "action" => compact_text(node),
            "file" => @file,
            "function" => function,
            "line" => node_line(node),
            "span" => node_span(node)
          }
          return
        end

        node_children(node).each { |child| path_walk(child, function, guards, out) }
      end

      def path_walk_branch(node, function, guards, out)
        condition = child_node(node, 0)
        atoms = path_condition_atoms(condition)
        then_guards = node_type(node) == "UNLESS" ? negate_guards(atoms) : atoms
        else_guards = node_type(node) == "UNLESS" ? atoms : negate_guards(atoms)

        statements_for(child_node(node, 1)).each { |child| path_walk(child, function, guards + then_guards, out) }
        statements_for(child_node(node, 2)).each { |child| path_walk(child, function, guards + else_guards, out) }
        path_walk(condition, function, guards, out)
      end

      def path_condition_atoms(condition)
        return [] unless normalized_node?(condition)
        return flatten_boolean(condition, "AND").map { |child| compact_text(child) }.uniq.sort if node_type(condition) == "AND"

        [compact_text(condition)]
      end

      def negate_guards(guards)
        guards.map do |guard|
          text = guard.to_s.strip
          text.start_with?("!") ? text.delete_prefix("!").strip : "!#{text}"
        end
      end

      def statements_for(node)
        return [] unless normalized_node?(node)
        return node_children(node) if node_type(node) == "BLOCK"

        [node]
      end

      def path_action_node?(node)
        return false if branch_node?(node)

        assignment_node?(node) || call_node?(node)
      end

      def local_complexity_rows(local_method_rows)
        local_method_rows.to_h do |method_row|
          [method_row.row.fetch("id"), complexity_score(method_row.node)]
        end
      end

      def complexity_score(node)
        signals = Hash.new(0)
        score = score_node(node, nesting: 0, signals: signals)
        {
          "score" => ((score * 10).round / 10.0),
          "signals" => signals.transform_keys(&:to_s)
        }
      end

      def score_node(node, nesting:, signals:)
        return 0.0 unless normalized_node?(node)

        if branch_node?(node)
          signals[:branches] += 1
          signals[:nested] += 1 if nesting.positive?
          return branch_cost(nesting) + predicate_cost(node, signals) +
                 node_children(node).sum { |child| score_node(child, nesting: nesting + 1, signals: signals) }
        end

        return score_children(node, nesting: nesting, signals: signals) if loop_node?(node)

        if case_node?(node)
          signals[:cases] += 1
          return 0.5 + node_children(node).sum { |child| score_node(child, nesting: nesting + 1, signals: signals) }
        end

        return score_children(node, nesting: nesting, signals: signals) if early_exit_node?(node)

        if boolean_node?(node)
          signals[:boolean_ops] += 1
          return 0.25 + node_children(node).sum { |child| score_node(child, nesting: nesting, signals: signals) }
        end

        score_children(node, nesting: nesting, signals: signals)
      end

      def score_children(node, nesting:, signals:)
        node_children(node).sum { |child| score_node(child, nesting: nesting, signals: signals) }
      end

      def predicate_cost(node, signals)
        bools = boolean_count(child_node(node, 0))
        signals[:boolean_ops] += bools
        bools * 0.5
      end

      def boolean_count(node)
        return 0 unless normalized_node?(node)

        own = boolean_node?(node) ? 1 : 0
        own + node_children(node).sum { |child| boolean_count(child) }
      end

      def branch_cost(nesting)
        1.1 + nesting
      end

      def local_contract_assignment_rows(local_method_rows)
        local_method_rows.to_h do |method_row|
          assignments = method_row.row.fetch("statements").each_with_object({}) do |statement, map|
            next unless statement.fetch("writes").size == 1

            name = statement.fetch("writes").first.to_s
            source = local_contract_source(name, statement.fetch("source"))
            map[name] ||= source if source
          end
          [method_row.row.fetch("name"), assignments]
        end
      end

      def local_contract_source(name, source)
        match = source.to_s.match(/\b#{Regexp.escape(name)}\b\s*(?::=|=)\s*(.+?)\s*;?\z/m)
        return nil unless match

        rhs = match[1].strip
        return nil if rhs.match?(/\s(?:if|unless|rescue)\s|\?|:/)

        rhs
      end

      def normalized_root
        @row.fetch("normalized_root")
      end

      def walk(root)
        out = []
        pending = [[root, nil]]
        @parents = {}
        until pending.empty?
          node, parent = pending.pop
          next unless normalized_node?(node)

          @parents[node.object_id] = parent
          out << node
          node_children(node).reverse_each { |child| pending << [child, node] }
        end
        out
      end

      def parent_of(node)
        @parents ||= {}
        @parents[node.object_id]
      end

      def flatten_boolean(node, type)
        return [node] unless node_type(node) == type

        node_children(node).flat_map { |child| flatten_boolean(child, type) }
      end

      def branch_node?(node)
        %w[IF UNLESS].include?(node_type(node))
      end

      def loop_node?(node)
        %w[FOR WHILE UNTIL ITER].include?(node_type(node))
      end

      def case_node?(node)
        %w[CASE CASE2 WHEN].include?(node_type(node))
      end

      def early_exit_node?(node)
        %w[RETURN NEXT BREAK REDO RETRY].include?(node_type(node))
      end

      def boolean_node?(node)
        %w[AND OR].include?(node_type(node))
      end

      def assignment_node?(node)
        %w[LASGN DASGN MASGN IASGN GASGN ATTRASGN OP_ASGN1 OP_ASGN2].include?(node_type(node))
      end

      def call_node?(node)
        %w[CALL QCALL FCALL VCALL ATTRASGN OPCALL].include?(node_type(node))
      end

      def local_identifier(node)
        case node_type(node)
        when "LVAR", "DVAR"
          scalar_child(node, 0).to_s
        else
          nil
        end
      end

      def normalized_node?(node)
        node.is_a?(Hash) || node.respond_to?(:type)
      end

      def node_type(node)
        value_for(node, "type").to_s
      end

      def node_children(node)
        Array(value_for(node, "children")).select { |child| normalized_node?(child) }
      end

      def child_node(node, index)
        child = Array(value_for(node, "children"))[index]
        normalized_node?(child) ? child : nil
      end

      def scalar_child(node, index)
        child = Array(value_for(node, "children"))[index]
        normalized_node?(child) ? nil : child
      end

      def node_line(node)
        value_for(node, "first_lineno").to_i
      end

      def node_span(node)
        [
          value_for(node, "first_lineno").to_i,
          value_for(node, "first_column").to_i,
          value_for(node, "last_lineno").to_i,
          value_for(node, "last_column").to_i
        ]
      end

      def compact_text(node)
        value_for(node, "text").to_s.tr("\u00A0", " ").strip.gsub(/\s+/, " ")
      end

      def value_for(node, key)
        return node[key] if node.is_a?(Hash)
        return node.public_send(key) if node.respond_to?(key)

        nil
      end
    end
  end
end
