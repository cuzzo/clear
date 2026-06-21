# frozen_string_literal: true

module Decomplex
  module Syntax
    NilGuardFinding = Struct.new(:file, :defn, :line, :span, :local, :guard,
                                 :proof, keyword_init: true) do
      def to_h
        loc = "#{file}:#{defn}:#{line}"
        super.merge(at: loc, spans: { loc => span })
      end
    end

    class Document
      def redundant_nil_guard_findings
        @redundant_nil_guard_findings ||= adapter.redundant_nil_guard_findings(self)
      end
    end

    class TreeSitterLanguageAdapter
      def redundant_nil_guard_findings(document)
        NilGuardAnalyzer.new(document).scan
      end
    end

    class TreeSitterAdapter
      def redundant_nil_guard_findings(document)
        syntax_profile(document.language).redundant_nil_guard_findings(document)
      end
    end

    class NilGuardAnalyzer
      Flow = Struct.new(:known, :terminated, keyword_init: true)
      NilFact = Struct.new(:local, :non_nil_when_true, keyword_init: true)

      TERMINATING_CALLS = %w[raise fail abort exit exit!].freeze

      attr_reader :document, :findings

      def initialize(document)
        @document = document
        @findings = []
      end

      def scan
        document.function_defs.each do |function|
          process_block(method_statements(function.body), function.name, Set.new)
        end
        findings
      end

      private

      def process_block(stmts, function, known)
        current = known.dup
        stmts.each do |stmt|
          flow = process_stmt(stmt, function, current)
          current = flow.known
          return flow if flow.terminated
        end
        Flow.new(known: current, terminated: false)
      end

      def process_stmt(node, function, known)
        return Flow.new(known: known.dup, terminated: false) unless ts_node?(node)

        if if_node?(node)
          process_branch(node, function, known)
        elsif assignment_node?(node)
          inspect_node(assignment_rhs(node), function, known)
          next_known = known.dup
          next_known.delete(assignment_lhs_name(node).to_s)
          Flow.new(known: next_known, terminated: false)
        else
          inspect_node(node, function, known)
          Flow.new(known: known.dup, terminated: terminating?(node))
        end
      end

      def process_branch(node, function, known)
        cond = branch_condition(node)
        inspect_node(cond, function, known)

        then_known = known_for_branch(node, true, cond, known)
        else_known = known_for_branch(node, false, cond, known)
        then_flow = process_block(stmts_for(branch_then_body(node)), function, then_known)
        else_flow = process_block(stmts_for(branch_else_body(node)), function, else_known)

        if then_flow.terminated && else_flow.terminated
          Flow.new(known: Set.new, terminated: true)
        elsif then_flow.terminated
          Flow.new(known: else_flow.known, terminated: false)
        elsif else_flow.terminated
          Flow.new(known: then_flow.known, terminated: false)
        else
          Flow.new(known: then_flow.known & else_flow.known, terminated: false)
        end
      end

      def known_for_branch(node, body_branch, cond, known)
        next_known = known.dup
        cond_true_branch = unless_node?(node) ? !body_branch : body_branch
        branch_nil_facts(cond, cond_true_branch).each { |fact| next_known.add(fact.local) }
        next_known
      end

      def inspect_node(node, function, known)
        return unless ts_node?(node)

        recorded = record_redundant(node, function, known)
        return if recorded && safe_navigation_call?(node)
        return if method_like_node?(node)

        node.children.each { |child| inspect_node(child, function, known) }
      end

      def record_redundant(node, function, known)
        local = redundant_nil_subject(node, known)
        return false unless local

        @findings << NilGuardFinding.new(
          file: document.file,
          defn: function,
          line: line(node),
          span: span(node),
          local: local,
          guard: normalize_text(node.text),
          proof: "#{local} is already proven non-nil on this path"
        )
        true
      end

      def redundant_nil_subject(node, known)
        subject = safe_navigation_subject(node)
        return subject if subject && known.include?(subject)

        fact = nil_fact(node)
        return nil unless fact && known.include?(fact.local)

        fact.local
      end

      def nil_fact(node)
        return nil unless ts_node?(node)
        return nil_fact(node.named_children.first) if parenthesized_wrapper?(node)

        if nil_predicate_call?(node)
          subject = subject_key(call_receiver_node(node))
          return subject ? NilFact.new(local: subject, non_nil_when_true: false) : nil
        end
        if non_nil_predicate_call?(node)
          subject = subject_key(call_receiver_node(node))
          return subject ? NilFact.new(local: subject, non_nil_when_true: true) : nil
        end

        return negated_nil_fact(node.named_children.first) if unary_not?(node)

        comparison_nil_fact(node)
      end

      def branch_nil_facts(node, cond_truth)
        return [] unless ts_node?(node)
        return branch_nil_facts(node.named_children.first, cond_truth) if parenthesized_wrapper?(node)

        if boolean_and?(node)
          return [] unless cond_truth

          return flatten_boolean_and(node).flat_map { |child| branch_nil_facts(child, true) }
        end

        return branch_nil_facts(node.named_children.first, !cond_truth) if unary_not?(node)

        safe_receiver = safe_nav_receiver_fact(node)
        return [safe_receiver] if safe_receiver && cond_truth

        fact = nil_fact(node)
        return [fact] if fact && cond_truth == fact.non_nil_when_true

        truthy = truthy_subject_fact(node)
        truthy && cond_truth ? [truthy] : []
      end

      def safe_nav_receiver_fact(node)
        subject = safe_navigation_subject(node)
        subject ? NilFact.new(local: subject, non_nil_when_true: true) : nil
      end

      def truthy_subject_fact(node)
        subject = subject_key(node)
        return nil unless subject

        NilFact.new(local: subject, non_nil_when_true: true)
      end

      def negated_nil_fact(node)
        fact = nil_fact(node)
        return nil unless fact

        NilFact.new(local: fact.local,
                    non_nil_when_true: !fact.non_nil_when_true)
      end

      def comparison_nil_fact(node)
        return nil unless ts_node?(node) && node.kind == "binary"

        operator = direct_operator(node)
        return nil unless %w[== !=].include?(operator)

        left, right = node.named_children
        subject = nil
        if nil_literal?(right)
          subject = subject_key(left)
        elsif nil_literal?(left)
          subject = subject_key(right)
        end
        return nil unless subject

        NilFact.new(local: subject, non_nil_when_true: operator == "!=")
      end

      def method_statements(node)
        body = method_body_node(node)
        return [] unless body

        stmts_for(body)
      end

      def method_body_node(node)
        return nil unless ts_node?(node)

        case node.kind
        when "method", "singleton_method", "argument_list", "function_definition", "function_item",
             "function_declaration", "method_declaration"
          node.named_children.reverse.find do |child|
            %w[body_statement block compound_statement function_body statement_block].include?(child.kind)
          end
        when "body_statement", "block", "compound_statement", "function_body", "statement_block"
          if method_like_node?(node)
            node.named_children.reverse.find do |child|
              %w[body_statement block compound_statement function_body statement_block].include?(child.kind)
            end
          else
            node
          end
        end
      end

      def stmts_for(node)
        return [] unless ts_node?(node)
        return [node] if if_node?(node)
        return [node] if assignment_node?(node)
        return [node] if call_node?(node)

        named = node.named_children.reject { |child| child.kind == "comment" }
        if named.size == 1 && %w[statements statement_list].include?(named.first.kind)
          return [named.first] if if_node?(named.first)

          named = named.first.named_children.reject { |child| child.kind == "comment" }
        end
        return [node] if named.empty? && !node.text.to_s.strip.empty?

        named
      end

      def if_node?(node)
        return false unless ts_node?(node)
        return true if %w[if unless if_statement if_expression if_modifier unless_modifier].include?(node.kind) && node.named_children.any?
        return true if node.kind == "expression_statement" && node.text.to_s.lstrip.start_with?("if ")
        return false unless %w[body_statement block statements statement_list].include?(node.kind)

        first_token = node.children.first
        return true if first_token && !first_token.named? && %w[if unless].include?(first_token.kind.to_s)

        seen_named = false
        node.children.any? do |child|
          seen_named ||= child.named?
          seen_named && !child.named? && %w[if unless].include?(child.kind.to_s)
        end
      end

      def unless_node?(node)
        node.kind.to_s.include?("unless") || first_token_kind(node) == "unless"
      end

      def modifier_if_node?(node)
        return true if %w[if_modifier unless_modifier].include?(node.kind)
        return false unless %w[body_statement block statements statement_list].include?(node.kind)

        seen_named = false
        node.children.any? do |child|
          seen_named ||= child.named?
          seen_named && !child.named? && %w[if unless].include?(child.kind.to_s)
        end
      end

      def branch_condition(node)
        modifier_if_node?(node) ? node.named_children.last : node.named_children.first
      end

      def branch_then_body(node)
        if modifier_if_node?(node)
          node.named_children.first
        else
          node.named_children.find { |child| child.kind == "then" } || node.named_children[1]
        end
      end

      def branch_else_body(node)
        return nil if modifier_if_node?(node)

        node.named_children.find { |child| %w[else elsif].include?(child.kind) } || node.named_children[2]
      end

      def assignment_node?(node)
        ts_node?(node) && (%w[assignment assignment_expression assignment_statement].include?(node.kind) || flat_assignment_statement?(node))
      end

      def assignment_lhs_name(node)
        assignment_lhs(node)&.text
      end

      def assignment_lhs(node)
        node.named_children.first if assignment_node?(node)
      end

      def assignment_rhs(node)
        node.named_children[1] if assignment_node?(node)
      end

      def flat_assignment_statement?(node)
        return false unless ts_node?(node) && node.kind == "body_statement"

        node.children.count { |child| !child.named? && child.text == "=" } == 1 &&
          node.named_children.size >= 2
      end

      def nil_predicate_call?(node)
        call_node?(node) && %w[nil? is_none is_null isNull].include?(call_message(node).to_s)
      end

      def non_nil_predicate_call?(node)
        call_node?(node) && %w[is_some isSome present?].include?(call_message(node).to_s)
      end

      def safe_navigation_call?(node)
        ts_node?(node) && node.kind == "call" &&
          node.children.any? { |child| !child.named? && child.text == "&." }
      end

      def safe_navigation_subject(node)
        return nil unless safe_navigation_call?(node)

        subject_key(call_receiver_node(node))
      end

      def call_receiver_node(node)
        return nil unless call_node?(node)

        if adjacent_field_call?(node)
          return named_field(node, "object") || named_field(node, "receiver") ||
                 named_field(node, "expression") || named_field(node, "operand") ||
                 node.named_children.first
        end

        if %w[call call_expression function_call invocation_expression method_invocation method_call].include?(node.kind)
          if node.kind == "call"
            names = node.named_children.select { |child| %w[identifier simple_identifier].include?(child.kind) }
            return names.first if names.size >= 2
          end

          if %w[invocation_expression method_invocation].include?(node.kind)
            names = node.named_children.select { |child| %w[identifier simple_identifier].include?(child.kind) }
            return names.first if names.size >= 2
          end

          callee = named_field(node, "function") || named_field(node, "callee") || node.named_children.first
          if field_like_node?(callee)
            return named_field(callee, "object") || named_field(callee, "receiver") ||
                   named_field(callee, "expression") || named_field(callee, "operand") ||
                   callee.named_children.first
          end
        end

        node.named_children.first
      end

      def call_message(node)
        return nil unless call_node?(node)

        if adjacent_field_call?(node)
          field = named_field(node, "field") || named_field(node, "property") ||
                  named_field(node, "name") || named_field(node, "suffix") ||
                  node.named_children.last
          return field&.text.to_s.sub(/\A[.?]+/, "")
        end

        if %w[call call_expression function_call invocation_expression method_invocation method_call].include?(node.kind)
          if node.kind == "call"
            names = node.named_children.select { |child| %w[identifier simple_identifier].include?(child.kind) }
            return names.last.text if names.size >= 2
          end

          if %w[invocation_expression method_invocation].include?(node.kind)
            names = node.named_children.select { |child| %w[identifier simple_identifier].include?(child.kind) }
            return names[1].text if names.size >= 2
          end

          callee = named_field(node, "function") || named_field(node, "callee") || node.named_children.first
          if field_like_node?(callee)
            field = named_field(callee, "field") || named_field(callee, "property") ||
                    named_field(callee, "name") || named_field(callee, "suffix") ||
                    callee.named_children.last
            return field&.text.to_s.sub(/\A[.?]+/, "")
          end
          return callee.text if %w[identifier simple_identifier].include?(callee&.kind)
        end

        node.named_children.reverse.find { |child| %w[identifier simple_identifier].include?(child.kind) }&.text
      end

      def call_has_arguments?(node)
        ts_node?(node) &&
          (node.named_children.any? { |child| %w[argument_list arguments call_suffix].include?(child.kind) } ||
           %w[argument_list arguments call_suffix].include?(next_sibling(node)&.kind))
      end

      def subject_key(node)
        return nil unless ts_node?(node)

        case node.kind
        when "identifier", "simple_identifier"
          node.text
        when "self", "this"
          "self"
        when "call", "call_expression", "function_call", "method_invocation", "invocation_expression", "method_call"
          return nil if call_has_arguments?(node)

          receiver = call_receiver_node(node)
          message = call_message(node)
          return nil unless message && stable_reader_name?(message)
          return "self.#{message}" if receiver&.kind == "self"

          recv_key = subject_key(receiver)
          recv_key ? "#{recv_key}.#{message}" : nil
        else
          nil
        end
      end

      def stable_reader_name?(name)
        text = name.to_s
        !(text.end_with?("=", "!") || text == "[]")
      end

      def nil_literal?(node)
        ts_node?(node) && node.kind == "nil"
      end

      def unary_not?(node)
        ts_node?(node) && node.kind == "unary" &&
          node.children.any? { |child| !child.named? && child.text == "!" }
      end

      def parenthesized_wrapper?(node)
        ts_node?(node) && %w[condition_clause parenthesized_expression parenthesized_statements].include?(node.kind) &&
          node.named_children.size == 1
      end

      def boolean_and?(node)
        ts_node?(node) && node.kind == "binary" && direct_operator(node) == "&&"
      end

      def flatten_boolean_and(node)
        return [node] unless boolean_and?(node)

        node.named_children.flat_map { |child| flatten_boolean_and(child) }
      end

      def direct_operator(node)
        node.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s
      end

      def terminating?(node)
        return false unless ts_node?(node)
        return true if %w[return break next].include?(node.kind)
        return true if node.text.to_s.strip.match?(/\A(?:return|break|next)\b/)
        return true if node.kind == "identifier" && TERMINATING_CALLS.include?(node.text.to_s)

        call_node?(node) && TERMINATING_CALLS.include?(call_message(node).to_s)
      end

      def method_like_node?(node)
        ts_node?(node) && %w[method singleton_method function_definition function_item function_declaration method_declaration].include?(node.kind)
      end

      def call_node?(node)
        ts_node?(node) &&
          (%w[call argument_list call_expression function_call invocation_expression method_invocation method_call].include?(node.kind) ||
           adjacent_field_call?(node))
      end

      def adjacent_field_call?(node)
        field_like_node?(node) && %w[argument_list arguments call_suffix].include?(next_sibling(node)&.kind)
      end

      def next_sibling(node)
        node.next_sibling
      rescue StandardError
        nil
      end

      def first_token_kind(node)
        node.children.find { |child| !child.named? }&.kind.to_s
      end

      def line(node)
        node.start_point.row + 1
      end

      def span(node)
        [node.start_point.row + 1, node.start_point.column, node.end_point.row + 1, node.end_point.column]
      end

      def normalize_text(text)
        text.to_s.lines.map(&:strip).reject(&:empty?).join(" ")
      end

      def named_field(node, name)
        node.child_by_field_name(name)
      rescue StandardError
        nil
      end

      def field_like_node?(node)
        ts_node?(node) &&
          %w[
            attribute directly_assignable_expression dot_index_expression expression_list field field_access
            field_expression member_access_expression member_expression navigation_expression scoped_identifier
            selector_expression variable_list
          ].include?(node.kind)
      end

      def ts_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:children)
      end
    end
  end
end
