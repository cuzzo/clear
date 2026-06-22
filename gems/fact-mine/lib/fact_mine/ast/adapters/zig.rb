# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class ZigTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      def case_pattern_prefix(node)
        return [] unless node.kind == "switch_case"

        node.named_children.take_while { |child| child.kind == "field_expression" }
      rescue StandardError
        []
      end

      def call_arguments_from_text?(node)
        node.kind == "call_expression"
      rescue StandardError
        false
      end
    end
  end
end
