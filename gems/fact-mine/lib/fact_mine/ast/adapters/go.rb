# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class GoTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      def special_if_statement?(node)
        hidden_if_statement_list?(node)
      end

      def normalize_special_if(node, helpers:)
        cond = node.named_children.first
        body = node.named_children.find { |child| child.kind == "block" }
        helpers.__send__(
          :wrap,
          :IF,
          children: [helpers.__send__(:normalize_node, cond), helpers.__send__(:normalize_body, body), nil],
          source: node
        )
      end

      def special_statement?(node)
        node.kind == "short_var_declaration" || bare_call_statement_list?(node)
      rescue StandardError
        false
      end

      def statement_block_wrapper?(node)
        return true if node.kind == "block" && node.parent&.kind == "statement_list"

        super
      end

      def normalize_special_statement(node, helpers:)
        return normalize_bare_call_statement_list(node, helpers: helpers) if bare_call_statement_list?(node)

        targets = target_names(node.named_children[0])
        value = node.named_children[1]
        return nil if targets.empty?

        assignments = targets.each_with_index.filter_map do |target, index|
          helpers.__send__(
            :wrap,
            :LASGN,
            children: [target, helpers.__send__(:normalize_node, index.zero? ? value : nil)],
            source: node
          )
        end
        return nil if assignments.empty?
        return assignments.first if assignments.size == 1

        helpers.__send__(:wrap, :BLOCK, children: assignments, source: node)
      end

      private

      def hidden_if_statement_list?(node)
        node.kind == "statement_list" &&
          node.text.to_s.lstrip.start_with?("if ") &&
          node.named_children.any? { |child| child.kind == "block" }
      rescue StandardError
        false
      end

      def bare_call_statement_list?(node)
        node.kind == "statement_list" &&
          node.children.first &&
          !node.children.first.named? &&
          node.named_children.first&.kind == "parenthesized_expression"
      rescue StandardError
        false
      end

      def normalize_bare_call_statement_list(node, helpers:)
        message = node.children.first.text.to_s
        args_node = node.named_children.first
        args = args_node.named_children.map do |child|
          helpers.__send__(:normalize_argument_node, child)
        end
        helpers.__send__(
          :wrap,
          :FCALL,
          children: [message.to_sym, helpers.__send__(:list, args, source: args_node || node)],
          source: node
        )
      end

      def target_names(node)
        return [] unless node
        if node.kind == "expression_list"
          names = node.named_children.select { |child| child.kind == "identifier" }.map(&:text)
          text = node.text.to_s.strip
          names << text if names.empty? && text.match?(/\A[A-Za-z_]\w*\z/)
          return names
        end
        return [node.text.to_s] if node.kind == "identifier"

        []
      end
    end
  end
end
