# frozen_string_literal: true

require_relative "base"

module Decomplex
  module Ast
    class RubyTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      def ruby?
        true
      end

      def yield_statement?(node)
        %w[body_statement block block_body statement].include?(node.kind) &&
          node.children.first&.text == "yield"
      rescue StandardError
        false
      end

      def super_statement?(node)
        %w[body_statement block block_body statement].include?(node.kind) &&
          (node.text.to_s.strip == "super" ||
            (node.named_children.first&.kind == "super" &&
              node.named_children.drop(1).all? { |child| child.kind == "argument_list" }))
      rescue StandardError
        false
      end

      def explicit_alternative(node)
        node.named_children.find { |child| %w[elsif else].include?(child.kind) }
      rescue StandardError
        nil
      end

      def instance_variable?(node)
        node.kind == "instance_variable" || ruby_instance_variable_text?(node.text)
      rescue StandardError
        false
      end

      def global_variable?(node)
        node.kind == "global_variable" || ruby_global_variable_text?(node.text)
      rescue StandardError
        false
      end

      def case_argument_list?(node)
        node.kind == "argument_list" &&
          node.children.any? { |child| !child.named? && child.kind == "case" } &&
          node.named_children.any? { |child| CASE_ARGUMENT_WHEN_KINDS.include?(child.kind) }
      rescue StandardError
        false
      end

      def safe_navigation_call?(node)
        node.children.any? { |child| !child.named? && child.text == "&." }
      rescue StandardError
        false
      end

      def leading_function_statement?(node)
        leading_function_statement_with_keyword?(node, "def", LEADING_FUNCTION_WRAPPER_KINDS)
      end

      def zero_child_identifier_call?(node)
        node.kind == "call" && node.named_children.empty? &&
          node.text.to_s.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
      rescue StandardError
        false
      end

      def heredoc_call_for_body?(node)
        return true if node.kind == "heredoc_beginning"
        return true if %w[call argument_list].include?(node.kind) &&
                       node.text.to_s.match?(/(?:\A|[\s(,])<<[-~]?[A-Za-z_]\w*/)

        node.named_children.any? do |child|
          next false if child.named_children.any? { |grandchild| grandchild.kind == "heredoc_body" }

          heredoc_call_for_body?(child)
        end
      rescue StandardError
        false
      end

      private

      def assignment_operators
        RUBY_ASSIGNMENT_OPERATORS
      end

      def ruby_instance_variable_text?(text)
        text.to_s.match?(/\A@[A-Za-z_]\w*[!?=]?\z/)
      end

      def ruby_global_variable_text?(text)
        text.to_s.match?(/\A\$[A-Za-z_]\w*[!?=]?\z/)
      end
    end

  end
end
