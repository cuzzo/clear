# frozen_string_literal: true

module FactMine
  module Syntax
    class TreeSitterLanguageAdapter
      private

      def c_family_function_params(node)
        return nil unless node.kind == "function_definition"

        declarator = named_field(node, "declarator") ||
                     node.named_children.find { |child| child.kind == "function_declarator" }
        params = declarator&.named_children&.find { |child| child.kind == "parameter_list" }
        return nil unless params

        params.named_children.filter_map { |param| c_family_parameter_name(param) || parameter_name(param) }.uniq
      end

      def c_family_parameter_name(param)
        declarator = param.named_children.reverse.find { |child| child.kind.end_with?("_declarator") }
        name = c_family_declarator_name_node(declarator)
        return name.text if name

        direct = param.named_children.select do |child|
          parameter_identifier_node_kinds.include?(child.kind)
        end.last
        direct&.text
      end

      def c_family_declarator_name_node(node)
        return nil unless ts_node?(node)
        return node if parameter_identifier_node_kinds.include?(node.kind)

        node.named_children.reverse_each do |child|
          nested = c_family_declarator_name_node(child)
          return nested if nested
        end
        nil
      end

      def boolean_expression_list?(node, operator)
        return false unless node.kind == "expression_list"
        return false unless direct_operator(node) == operator
        return false if node.named_children.size < 2

        node.children.all? do |child|
          child.named? || [operator, "(", ")"].include?(child.text.to_s)
        end
      end
    end
  end
end
