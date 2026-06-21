# frozen_string_literal: true

module FactMine
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

      def self.scan_normalized_row(row)
        new(OpenStruct.new(
          file: row.fetch("file"),
          language: row.fetch("language"),
          normalized_root: row.fetch("normalized_root")
        )).scan.map(&:to_h)
      end

      def initialize(document)
        @document = document
        @behavior = Syntax::NormalizedExtractionBehavior.for(document.language)
        @findings = []
      end

      def scan
        function_nodes.each do |function|
          process_block(body_statements(function), function_name(function), Set.new)
        end
        @findings
      rescue StandardError
        []
      end

      private

      attr_reader :document

      def function_nodes
        walk(normalized_root).select { |node| %w[DEFN DEFS].include?(node_type(node)) }
      end

      def process_block(statements, function, known)
        current = known.dup
        statements.each do |statement|
          flow = process_statement(statement, function, current)
          current = flow.known
          return flow if flow.terminated
        end
        Flow.new(known: current, terminated: false)
      end

      def process_statement(node, function, known)
        if branch_node?(node)
          process_branch(node, function, known)
        elsif assignment_node?(node)
          inspect_node(child_node(node, 1), function, known)
          next_known = known.dup
          next_known.delete(subject_key(child_node(node, 0)).to_s)
          Flow.new(known: next_known, terminated: false)
        else
          inspect_node(node, function, known)
          Flow.new(known: known.dup, terminated: terminating?(node))
        end
      end

      def process_branch(node, function, known)
        condition = child_node(node, 0)
        inspect_node(condition, function, known)

        body_truth = node_type(node) == "UNLESS" ? false : true
        then_known = known_for_condition(condition, body_truth, known)
        else_known = known_for_condition(condition, !body_truth, known)
        then_flow = process_block(statements_for(child_node(node, 1)), function, then_known)
        else_flow = process_block(statements_for(child_node(node, 2)), function, else_known)

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

      def known_for_condition(condition, truth, known)
        next_known = known.dup
        branch_nil_facts(condition, truth).each { |fact| next_known.add(fact.local) }
        next_known
      end

      def inspect_node(node, function, known)
        return unless normalized_node?(node)

        recorded = record_redundant(node, function, known)
        return if recorded && safe_navigation_call?(node)

        node_children(node).each { |child| inspect_node(child, function, known) }
      end

      def record_redundant(node, function, known)
        subject = redundant_nil_subject(node, known)
        return false unless subject

        @findings << NilGuardFinding.new(
          file: document.file,
          defn: function,
          line: node_line(node),
          span: node_span(node),
          local: subject,
          guard: compact_text(node),
          proof: "#{subject} is already proven non-nil on this path"
        )
        true
      end

      def redundant_nil_subject(node, known)
        subject = safe_navigation_subject(node)
        return subject if subject && known.include?(subject)

        fact = nil_fact(node)
        fact&.local if fact && known.include?(fact.local)
      end

      def branch_nil_facts(node, truth)
        return [] unless normalized_node?(node)

        if node_type(node) == "AND"
          return [] unless truth

          return flatten_boolean(node, "AND").flat_map { |child| branch_nil_facts(child, true) }
        end

        if node_type(node) == "OR"
          return [] if truth

          return flatten_boolean(node, "OR").flat_map { |child| branch_nil_facts(child, false) }
        end

        fact = safe_navigation_fact(node) || nil_fact(node) || truthy_subject_fact(node)
        return [] unless fact && truth == fact.non_nil_when_true

        [fact]
      end

      def nil_fact(node)
        return nil unless normalized_node?(node)

        subject = subject_key(call_receiver(node))
        fact = @behavior.nil_guard_fact(call_message(node), subject)
        return NilFact.new(local: fact.fetch(:local), non_nil_when_true: fact.fetch(:non_nil_when_true)) if fact

        comparison_nil_fact(node)
      end

      def comparison_nil_fact(node)
        return nil unless node_type(node) == "OPCALL"

        left = child_node(node, 0)
        operator = scalar_child(node, 1).to_s
        right = child_node(node, 2)
        return nil unless %w[== !=].include?(operator)

        subject = nil
        if nil_literal?(right)
          subject = subject_key(left)
        elsif nil_literal?(left)
          subject = subject_key(right)
        end
        subject ? NilFact.new(local: subject, non_nil_when_true: operator == "!=") : nil
      end

      def safe_navigation_fact(node)
        subject = safe_navigation_subject(node)
        subject ? NilFact.new(local: subject, non_nil_when_true: true) : nil
      end

      def truthy_subject_fact(node)
        subject = subject_key(node)
        subject ? NilFact.new(local: subject, non_nil_when_true: true) : nil
      end

      def safe_navigation_subject(node)
        return nil unless safe_navigation_call?(node)

        subject_key(call_receiver(node))
      end

      def safe_navigation_call?(node)
        node_type(node) == "QCALL"
      end

      def terminating?(node)
        @behavior.terminating_call_message?(call_message(node))
      end

      def body_statements(function)
        scope = node_children(function).find { |child| node_type(child) == "SCOPE" }
        statements_for(child_node(scope, 2))
      end

      def statements_for(node)
        return [] unless normalized_node?(node)
        return node_children(node).select { |child| normalized_node?(child) } if node_type(node) == "BLOCK"

        [node]
      end

      def branch_node?(node)
        %w[IF UNLESS].include?(node_type(node))
      end

      def assignment_node?(node)
        %w[LASGN IASGN GASGN].include?(node_type(node))
      end

      def function_name(node)
        case node_type(node)
        when "DEFS"
          scalar_child(node, 1).to_s
        else
          scalar_child(node, 0).to_s
        end
      end

      def call_message(node)
        case node_type(node)
        when "VCALL"
          scalar_child(node, 0)
        when "FCALL"
          scalar_child(node, 0)
        when "CALL", "QCALL"
          scalar_child(node, 1)
        end
      end

      def call_receiver(node)
        child_node(node, 0) if %w[CALL QCALL].include?(node_type(node))
      end

      def subject_key(node)
        return nil unless normalized_node?(node)

        case node_type(node)
        when "LVAR", "DVAR", "IVAR", "GVAR"
          scalar_child(node, 0).to_s
        else
          text = compact_text(node)
          text if text.match?(/\A[@$]?[A-Za-z_]\w*[!?]?\z/)
        end
      end

      def nil_literal?(node)
        node_type(node) == "NIL"
      end

      def flatten_boolean(node, type)
        return [node] unless node_type(node) == type

        node_children(node).flat_map { |child| flatten_boolean(child, type) }
      end

      def normalized_root
        document.normalized_root
      end

      def normalized_node?(node)
        node.respond_to?(:to_h) || node.respond_to?(:type) || node.is_a?(Hash)
      end

      def walk(root)
        out = []
        pending = [root]
        until pending.empty?
          node = pending.pop
          next unless normalized_node?(node)

          out << node
          node_children(node).reverse_each { |child| pending << child }
        end
        out
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
