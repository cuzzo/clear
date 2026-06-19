# frozen_string_literal: true

module Decomplex
  module Syntax
    class TreeSitterLanguageAdapter
      private

      def c_family_function_params(node)
        return nil unless node.kind == "function_definition"

        declarator = named_field(node, "declarator") ||
                     node.named_children.find { |child| child.kind == "function_declarator" }
        params = declarator&.named_children&.find { |child| child.kind == "parameter_list" }
        return nil unless params

        params.named_children.filter_map { |param| parameter_name(param) }.uniq
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

require_relative "ruby"
require_relative "python"
require_relative "javascript"
require_relative "typescript"
require_relative "go"
require_relative "rust"
require_relative "zig"
require_relative "lua"
require_relative "c"
require_relative "cpp"
require_relative "csharp"
require_relative "java"
require_relative "swift"
require_relative "kotlin"
require_relative "php"
