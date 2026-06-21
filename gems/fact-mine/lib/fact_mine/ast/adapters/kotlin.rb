# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class KotlinTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      def special_statement?(node)
        hidden_when_statement?(node)
      end

      def normalize_special_statement(node, helpers:)
        subject = node.named_children.find { |child| child.kind == "when_subject" }
        entries = node.named_children.select { |child| child.kind == "when_entry" }
        value = subject&.named_children&.first
        whens = entries.map { |entry| normalize_when_entry(entry, helpers: helpers) }.compact
        chain = whens.reverse.inject(nil) do |next_when, current|
          current.children[2] = next_when
          current
        end
        helpers.__send__(
          :wrap,
          :CASE,
          children: [helpers.__send__(:normalize_node, value), chain],
          source: node
        )
      end

      private

      def hidden_when_statement?(node)
        node.kind == "statements" &&
          node.children.first&.kind == "when" &&
          node.named_children.any? { |child| child.kind == "when_entry" }
      rescue StandardError
        false
      end

      def normalize_when_entry(entry, helpers:)
        condition = entry.named_children.find { |child| child.kind == "when_condition" }
        body = entry.named_children.find { |child| child.kind == "control_structure_body" }
        return nil unless condition

        helpers.__send__(
          :wrap,
          :WHEN,
          children: [
            helpers.__send__(:list, [helpers.__send__(:normalize_node, condition)].compact, source: condition),
            helpers.__send__(:normalize_body, body),
            nil
          ],
          source: entry
        )
      end
    end
  end
end
