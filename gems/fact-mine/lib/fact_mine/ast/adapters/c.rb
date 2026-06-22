# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class CFamilyTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      def named_field(node, name)
        if node.kind == "function_definition"
          return function_declarator_identifier(node) if name.to_s == "name"
          return function_declarator_parameters(node) if name.to_s == "parameters"
          return node.named_children.find { |child| child.kind == "compound_statement" } if name.to_s == "body"
        end

        super
      end

      def unwrap_node?(node)
        return true if node.kind == "condition_clause" && node.named_children.size == 1

        super
      end

      def typed_assignment_statement?(node)
        node.kind == "declaration" && node.named_children.any? { |child| child.kind == "init_declarator" }
      rescue StandardError
        false
      end

      def normalize_typed_assignment_statement(node, helpers:)
        assignments = node.named_children.filter_map do |child|
          next unless child.kind == "init_declarator"

          normalize_init_declarator(child, helpers: helpers)
        end
        return nil if assignments.empty?
        return assignments.first if assignments.size == 1

        helpers.__send__(:wrap, :BLOCK, children: assignments, source: node)
      end

      private

      def function_declarator(node)
        node.named_children.find { |child| child.kind == "function_declarator" }
      end

      def function_declarator_identifier(node)
        declarator_identifier(function_declarator(node))
      end

      def function_declarator_parameters(node)
        function_declarator(node)&.named_children&.find { |child| child.kind == "parameter_list" }
      end

      def declarator_identifier(node)
        return nil unless node.respond_to?(:kind)
        return node if IDENTIFIER_KINDS.include?(node.kind) || node.kind == "field_identifier"

        node.named_children.each do |child|
          found = declarator_identifier(child)
          return found if found
        end
        nil
      end

      def normalize_init_declarator(node, helpers:)
        name = declarator_identifier(node.named_children.first)
        value = node.named_children.reverse.find { |child| child != name && child.kind != "type_identifier" }
        return nil unless name

        helpers.__send__(
          :wrap,
          :LASGN,
          children: [name.text.to_s, helpers.__send__(:normalize_node, value)],
          source: node
        )
      end
    end

    class CTreeSitterNormalizationAdapter < CFamilyTreeSitterNormalizationAdapter
    end

    class CppTreeSitterNormalizationAdapter < CFamilyTreeSitterNormalizationAdapter
    end
  end
end
