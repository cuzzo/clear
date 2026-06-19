# frozen_string_literal: true

module Decomplex
  module Syntax
    class PythonSyntaxAdapter < TreeSitterLanguageAdapter
      def function_name(node)
        hidden_python_function_name(node) || super
      end

      def visibility(_document, node)
        name = function_name(node).to_s
        return :private if name.start_with?("_") && !name.start_with?("__")

        :public
      end

      def call_target(document, node)
        python_adjacent_call_target(node) || super
      end

      def local_methods(document)
        super
      end

      private

      def hidden_python_function_name(node)
        return nil unless node.kind == "block"
        return nil unless node.children.first&.kind.to_s == "def"

        node.named_children.find { |child| child.kind == "identifier" }&.text
      end

      def python_function_body_statements(node)
        body = named_field(node, "body") ||
               node.named_children.find { |child| child.kind == "block" }
        return [] unless body

        body.named_children.reject { |child| child.kind == "comment" }
      end

      def python_adjacent_call_target(node)
        return nil unless %w[identifier].include?(node.kind)

        args = next_sibling(node)
        return nil unless args&.kind == "argument_list"

        {
          receiver: "self",
          message: node.text,
          arguments: args.named_children.map { |child| normalize_text(child.text) }
        }
      rescue StandardError
        nil
      end
    end

    class GoSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        exported_name_visibility(function_name(node))
      end

      private

      def boolean_container?(node)
        return true if boolean_expression_list?(node, "&&")

        super
      end
    end

    class RustSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || :private
      end
    end

    class JavaScriptSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || private_name_visibility(node)
      end

      private

      def private_name_visibility(node)
        function_name(node).to_s.start_with?("#") ? :private : :public
      end
    end

    class CppSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || cpp_visibility(node)
      end

      def function_params(node)
        c_family_function_params(node) || super
      end

      def implicit_state_accesses?
        true
      end

      private

      def control_context(node)
        return :iterates if node.kind == "for_range_loop"

        super
      end

      def cpp_visibility(node)
        visibility = previous_cpp_access_specifier(node)
        return visibility if visibility

        owner = nearest_owner_declaration(node)
        return :public if owner&.kind == "struct_specifier"

        :private
      end

      def previous_cpp_access_specifier(node)
        sibling = prev_sibling(node)
        while sibling
          return sibling.text.to_sym if sibling.kind == "access_specifier" &&
                                       %w[public private protected].include?(sibling.text)

          sibling = prev_sibling(sibling)
        end
        nil
      end

      def nearest_owner_declaration(node)
        parent = parent_node(node)
        seen = Set.new
        while parent && !seen.include?(node_key(parent))
          seen << node_key(parent)
          return parent if %w[class_specifier struct_specifier class class_definition class_declaration].include?(parent.kind)

          parent = parent_node(parent)
        end
        nil
      end
    end

    class CSharpSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || :private
      end

      def implicit_state_accesses?
        true
      end

      private

      def control_context(node)
        return :iterates if node.kind == "foreach_statement"

        super
      end
    end

    class CSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        c_visibility(node)
      end

      def function_params(node)
        c_family_function_params(node) || super
      end

      private

      def receiver_convention_owner_name(node, **_context)
        return nil unless first_argument_receiver?
        return nil unless node.kind == "function_definition"

        receiver = first_argument_receiver_parameter(node)
        return nil unless receiver && receiver[:name] == "self"

        normalize_type_owner(receiver[:type])
      end

      def c_visibility(node)
        node.children.any? { |child| child.text == "static" } ? :private : :public
      end
    end

    class LuaSyntaxAdapter < TreeSitterLanguageAdapter
      def function_name(node)
        lua_method_name(node) || super
      end

      def receiver_owner_name(node)
        lua_method_owner_name(node) || super
      end

      def call_target(document, node)
        lua_expression_list_call_target(node) ||
          lua_adjacent_member_call_target(node) ||
          super
      end

      def state_read_target(node)
        lua_single_return_member_target(node) || super
      end

      def generated_prelude?(document, node)
        return false unless line(node) == 1

        first_line = document.lines.first.to_s
        first_line.include?("_tl_compat") && first_line.include?("compat53.module")
      end

      private

      def boolean_container?(node)
        return true if boolean_expression_list?(node, "and")

        super
      end

      def lua_method_name(node)
        method = lua_method_index_expression(node)
        return nil unless method

        method.named_children.last&.text
      end

      def lua_method_owner_name(node)
        method = lua_method_index_expression(node)
        return nil unless method

        method.named_children.first&.text
      end

      def lua_method_index_expression(node)
        return nil unless node.kind == "function_declaration"

        node.named_children.find { |child| child.kind == "method_index_expression" }
      end

      def lua_expression_list_call_target(node)
        return nil unless node.kind == "expression_list"

        callee = node.named_children.find { |child| field_like_node?(child) }
        args = node.named_children.find { |child| child.kind == "arguments" }
        return nil unless callee && args

        target_from_callee(callee).merge(arguments: args.named_children.map { |child| normalize_text(child.text) })
      rescue StandardError
        nil
      end

      def lua_adjacent_member_call_target(node)
        return nil unless node.kind == "identifier"

        args = next_sibling(node)
        return nil unless args&.kind == "arguments"

        parent = parent_node(node)
        return nil unless parent && field_like_node?(parent)

        target_from_callee(parent).merge(arguments: args.named_children.map { |child| normalize_text(child.text) })
      rescue StandardError
        nil
      end

      def lua_single_return_member_target(node)
        return nil unless node.kind == "expression_list"

        text = normalize_text(node.text)
        if (match = text.match(/\A([A-Za-z_]\w*)\.([A-Za-z_]\w*)\z/))
          return { receiver: match[1], field: match[2] }
        end

        parent = parent_node(node)
        return nil unless parent&.kind == "block"
        return nil unless prev_sibling(node)&.kind.to_s == "return" ||
                          parent.children.first&.kind.to_s == "return"

        return nil unless node.named_children.size == 1
        child = node.named_children.first
        return nil unless field_like_node?(child)

        generic_state_read_target(child)
      end
    end

    class ZigSyntaxAdapter < TreeSitterLanguageAdapter
      def visibility(_document, node)
        modifier_visibility(node) || :private
      end

      def state_declaration(node)
        return zig_container_field_declaration(node) if node.kind == "container_field"

        super
      end

      private

      def zig_container_field_declaration(node)
        name = node.named_children.find { |child| child.kind == "identifier" }
        return nil unless name

        { field: name.text, type: declared_type_text(node, name) }
      end
    end

    class JavaSyntaxAdapter < TreeSitterLanguageAdapter
      def function_params(node)
        return super unless node.kind == "method_declaration"

        params = node.named_children.find { |child| child.kind == "formal_parameters" }
        return super unless params

        params.named_children.filter_map { |param| parameter_name(param) }.uniq
      end
    end
    class JavaSyntaxAdapter
      private

      def control_context(node)
        return :iterates if node.kind == "enhanced_for_statement"

        super
      end
    end
    class SwiftSyntaxAdapter < TreeSitterLanguageAdapter; end
    class KotlinSyntaxAdapter < TreeSitterLanguageAdapter; end

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
