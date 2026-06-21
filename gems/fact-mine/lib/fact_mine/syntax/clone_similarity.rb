# frozen_string_literal: true

module FactMine
  module Syntax
    CloneCandidate = Struct.new(
      :file, :line, :span, :method_name, :node_name, :mass,
      :fingerprint, :raw, :child_fingerprints, :child_masses,
      keyword_init: true
    )

    class Document
      def clone_candidates
        @clone_candidates ||= adapter.clone_candidates(self)
      end
    end

    class TreeSitterAdapter
      def clone_candidates(document)
        syntax_profile(document.language).clone_candidates(document)
      end
    end

    class TreeSitterLanguageAdapter
      def clone_candidates(document)
        CloneSimilarityAnalyzer.new(document).scan
      end
    end

    class CloneSimilarityAnalyzer
      CANDIDATE_TYPES = %w[
        DEFN DEFS BLOCK IF UNLESS CASE CASE2 WHEN AND OR FOR WHILE UNTIL ITER
        CALL QCALL FCALL VCALL OPCALL OP_ASGN1 OP_ASGN2 ATTRASGN HASH LIST
      ].freeze
      SKIP_TYPES = %w[ROOT SCOPE ARGS ZLIST].freeze
      IDENTIFIER_TYPES = %w[LVAR DVAR IVAR GVAR CONST SELF].freeze
      LITERAL_TYPES = %w[STR DSTR XSTR RAW_ARGUMENT FIELD_EXPRESSION INTEGER LIT].freeze
      PUBLIC_NODE_TYPES = {
        "CLASS" => "class",
        "MODULE" => "module",
        "SCOPE" => "body",
        "BLOCK" => "body_statement",
        "DEFN" => "method",
        "DEFS" => "method",
        "ARGS" => "parameters",
        "LASGN" => "assignment",
        "DASGN" => "assignment",
        "IASGN" => "assignment",
        "GASGN" => "assignment",
        "MASGN" => "assignment",
        "ATTRASGN" => "assignment",
        "OP_ASGN1" => "assignment",
        "OP_ASGN2" => "assignment",
        "IF" => "if",
        "UNLESS" => "unless",
        "CASE" => "case",
        "CASE2" => "case",
        "WHEN" => "when",
        "CALL" => "call",
        "QCALL" => "call",
        "FCALL" => "call",
        "VCALL" => "call",
        "OPCALL" => "call",
        "LIST" => "argument_list",
        "HASH" => "hash",
        "ITER" => "block",
        "AND" => "and",
        "OR" => "or",
        "FOR" => "for",
        "WHILE" => "while",
        "UNTIL" => "until"
      }.freeze

      def self.scan_normalized_row(row)
        new(OpenStruct.new(
          file: row.fetch("file"),
          normalized_root: row.fetch("normalized_root")
        )).scan.map(&:to_h)
      end

      def initialize(document)
        @document = document
        @parents = {}
      end

      def scan
        out = []
        seen = Set.new
        walk(normalized_root).each do |node|
          next unless candidate_node?(node)

          candidate = clone_candidate_for(node, function_name: enclosing_function_name(node))
          next unless candidate

          key = [candidate.file, candidate.line, candidate.span, candidate.node_name, candidate.fingerprint]
          next if seen.include?(key)

          seen << key
          out << candidate
        end
        out
      rescue StandardError
        []
      end

      private

      attr_reader :document

      def clone_candidate_for(node, function_name:)
        fingerprint, mass = fingerprint_for(node)
        return nil if fingerprint.empty? || mass.zero?

        child_data = candidate_children(node).map { |child| fingerprint_for(child) }
                                           .reject { |child_fp, child_mass| child_fp.empty? || child_mass.zero? }
        CloneCandidate.new(
          file: document.file,
          line: node_line(node),
          span: node_span(node),
          method_name: function_name || "(top-level)",
          node_name: node_name(node),
          mass: mass,
          fingerprint: fingerprint,
          raw: compact_text(node),
          child_fingerprints: child_data.map(&:first),
          child_masses: child_data.map(&:last)
        )
      end

      def candidate_node?(node)
        return false unless normalized_node?(node)
        return false if SKIP_TYPES.include?(node_type(node))
        return false unless CANDIDATE_TYPES.include?(node_type(node))

        node_children(node).any?
      end

      def candidate_children(node)
        body = body_node(node)
        children = node_children(body || node)
        children.reject { |child| SKIP_TYPES.include?(node_type(child)) }
      end

      def body_node(node)
        node_children(node).find { |child| node_type(child) == "BLOCK" }
      end

      def fingerprint_for(node, active = nil)
        return ["", 0] unless normalized_node?(node)

        active ||= Set.new
        key = object_key(node)
        return ["", 0] if active.include?(key)

        active << key
        begin
          token = terminal_token(node)
          return [token, 1] unless token.empty?

          parts = scalar_tokens(node)
          mass = 1
          node_children(node).each do |child|
            child_fp, child_mass = fingerprint_for(child, active)
            next if child_fp.empty?

            parts << child_fp
            mass += child_mass
          end
          return ["", 0] if parts.empty?

          ["#{fingerprint_label(node)}(#{parts.join(' ')})", mass]
        ensure
          active.delete(key)
        end
      end

      def scalar_tokens(node)
        Array(value_for(node, "children")).reject { |child| normalized_node?(child) }.filter_map do |child|
          scalar_token(child)
        end
      end

      def scalar_token(value)
        text = value.to_s
        return nil if text.empty?

        text.match?(/\A[A-Za-z_@:$]\w*[!?=]?\z/) ? "id" : "lit"
      end

      def fingerprint_label(node)
        label = public_node_type(node)
        message = call_message(node)
        message ? "#{label}<#{message}>" : label
      end

      def call_message(node)
        return nil unless %w[CALL QCALL FCALL VCALL ATTRASGN].include?(node_type(node))

        message =
          case node_type(node)
          when "CALL", "QCALL", "ATTRASGN" then scalar_child(node, 1)
          when "FCALL", "VCALL" then scalar_child(node, 0)
          end
        args = child_node(node, %w[CALL QCALL ATTRASGN].include?(node_type(node)) ? 2 : 1)
        return nil unless args && !node_children(args).empty?

        message.to_s
      end

      def terminal_token(node)
        type = node_type(node)
        return "id" if IDENTIFIER_TYPES.include?(type)
        return "bool" if %w[TRUE FALSE].include?(type)
        return "nil" if type == "NIL"
        return "lit" if LITERAL_TYPES.include?(type)

        children = Array(value_for(node, "children"))
        scalars = children.reject { |child| normalized_node?(child) }.map(&:to_s).reject(&:empty?)
        return scalars.map { |scalar| scalar.match?(/\A[A-Za-z_]\w*[!?=]?\z/) ? "id" : scalar }.join(":") if node_children(node).empty?

        ""
      end

      def node_name(node)
        case node_type(node)
        when "DEFN" then "defn"
        when "DEFS" then "defs"
        else public_node_type(node)
        end
      end

      def public_node_type(node)
        PUBLIC_NODE_TYPES.fetch(node_type(node), node_type(node).downcase)
      end

      def enclosing_function_name(node)
        current = node
        while current
          return function_name(current) if %w[DEFN DEFS].include?(node_type(current))

          current = parent_of(current)
        end
        nil
      end

      def function_name(node)
        case node_type(node)
        when "DEFS"
          scalar_child(node, 1).to_s
        else
          scalar_child(node, 0).to_s
        end
      end

      def normalized_root
        document.normalized_root
      end

      def walk(root)
        out = []
        pending = [[root, nil]]
        until pending.empty?
          node, parent = pending.pop
          next unless normalized_node?(node)

          set_parent(node, parent)
          out << node
          node_children(node).reverse_each { |child| pending << [child, node] }
        end
        out
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

      def scalar_child(node, index)
        child = Array(value_for(node, "children"))[index]
        normalized_node?(child) ? nil : child
      end

      def child_node(node, index)
        child = Array(value_for(node, "children"))[index]
        normalized_node?(child) ? child : nil
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

      def object_key(node)
        return node.object_id unless node.is_a?(Hash)

        node.object_id
      end

      def parent_of(node)
        @parents[node.object_id]
      end

      def set_parent(node, parent)
        @parents[node.object_id] = parent
      end
    end
  end
end
