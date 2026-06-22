# frozen_string_literal: true

require_relative "base"

module FactMine
  module Ast
    class RubyTreeSitterNormalizationAdapter < TreeSitterNormalizationAdapter
      ASSIGNMENT_OPERATORS = (COMMON_ASSIGNMENT_OPERATORS + %w[**= &&= ||= &= |= ^= <<= >>=]).freeze

      def ruby?
        true
      end

      def yield_statement?(node)
        %w[body_statement block block_body statement].include?(node.kind) &&
          node.children.first&.text == "yield"
      rescue StandardError
        false
      end

      def identifier_yield?(node)
        TreeSitterNormalizationAdapter::IDENTIFIER_KINDS.include?(node.kind) && node.text.to_s == "yield"
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

      def branch_child_fallback?
        false
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

      def with_local_scope(node, reset: false)
        previous = @local_stack || []
        @local_stack = [] if reset
        @local_stack = (@local_stack || []) + [ruby_scope_locals(node)]
        yield
      ensure
        @local_stack = previous
      end

      def local_name?(name)
        (@local_stack || []).reverse.any? { |scope| scope.include?(name) }
      end

      def definition_identifier?(node, helpers:)
        parent = helpers.__send__(:parent_node, node)
        return false unless helpers.__send__(:ts_node?, parent)

        if %w[method singleton_method].include?(parent.kind)
          name = helpers.__send__(:named_field, parent, "name") ||
                 parent.named_children.find do |child|
                   TreeSitterNormalizationAdapter::IDENTIFIER_KINDS.include?(child.kind)
                 end
          return helpers.__send__(:same_ts_node?, name, node)
        end

        %w[
          method_parameters block_parameters lambda_parameters
          optional_parameter keyword_parameter block_parameter
        ].include?(parent.kind)
      end

      def implicit_call_identifier?(node, helpers:)
        return false unless TreeSitterNormalizationAdapter::IDENTIFIER_KINDS.include?(node.kind)
        return false if helpers.__send__(:assignment_lhs?, node)
        return false if definition_identifier?(node, helpers: helpers)

        !local_name?(node.text.to_s)
      end

      def logical_operator_assignment?(_left, operator, helpers:)
        [:"||", :"&&"].include?(operator)
      end

      def normalize_operator_call_override(node, left, operator, right, helpers:)
        return nil unless operator == "=~"

        if helpers.__send__(:regex_literal?, right)
          return helpers.__send__(
            :wrap,
            :MATCH3,
            children: [helpers.__send__(:normalize_node, right), helpers.__send__(:normalize_node, left)],
            source: node
          )
        end

        helpers.__send__(
          :wrap,
          :CALL,
          children: [
            helpers.__send__(:normalize_node, left),
            :=~,
            helpers.__send__(:list, [helpers.__send__(:normalize_node, right)].compact, source: right)
          ],
          source: node
        )
      end

      def element_reference_override(node, receiver, arguments, helpers:)
        return nil unless helpers.__send__(:self_node?, receiver)

        helpers.__send__(:wrap, :FCALL, children: [:[], helpers.__send__(:list, arguments, source: node)], source: node)
      end

      def hash_pair_value_override(key, value, helpers:)
        return nil unless key&.kind == "hash_key_symbol" && value.nil?

        helpers.__send__(:local_or_call_for_name, key.text.to_s, key)
      end

      def argument_list_call?(node)
        node.kind == "argument_list"
      rescue StandardError
        false
      end

      def argument_list_element_reference?(node)
        node.kind == "argument_list" &&
          node.children.first&.text != "[" &&
          node.children.any? { |child| !child.named? && child.text == "[" } &&
          node.children.any? { |child| !child.named? && child.text == "]" } &&
          node.named_children.size >= 2 &&
          node.named_children.none? { |child| %w[block do_block].include?(child.kind) }
      rescue StandardError
        false
      end

      def callable_yield?(function)
        function&.text == "yield"
      end

      def callable_constant_as_function?(function, helpers:)
        function && helpers.__send__(:const_node?, function)
      end

      def elide_single_symbol_return?(children, elide_symbol)
        elide_symbol && children.size == 1 && children.first.respond_to?(:type) && children.first.type == :LIT
      end

      def normalize_case_pattern_override(pattern, helpers:)
        return nil unless %w[pattern case_pattern match_pattern switch_pattern when_condition expression_list].include?(pattern.kind)
        return nil unless pattern.named_children.empty?

        pattern_text = pattern.text.to_s
        if pattern_text.match?(/\A:[A-Za-z_]\w*[!?=]?\z/)
          return [helpers.__send__(:wrap, :LIT, children: [pattern_text.delete_prefix(":").to_sym], source: pattern)]
        end
        if pattern_text.match?(/\A[A-Z]\w*\z/)
          return [helpers.__send__(:wrap, :CONST, children: [pattern_text.to_sym], source: pattern)]
        end
        if pattern_text.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
          return [helpers.__send__(:local_or_call_for_name, pattern_text, pattern)]
        end

        nil
      end

      def argument_list_unary_not?(node)
        node.kind == "argument_list" && node.children.first&.text == "!" && node.named_children.size == 1
      rescue StandardError
        false
      end

      def normalize_dynamic_scope(node, helpers:)
        return node unless node.respond_to?(:type)
        return node if %i[DEFN DEFS CLASS MODULE SCLASS LAMBDA].include?(node.type)

        node.type = :DASGN if node.type == :LASGN
        node.type = :DVAR if node.type == :LVAR
        node.children = node.children.map { |child| normalize_dynamic_scope(child, helpers: helpers) }
        node
      end

      def inline_def_source?(source)
        ts_node?(source)
      end

      def inline_def_wrapper_mid?(text)
        %w[public protected private private_class_method module_function].include?(text.to_s)
      end

      def normalize_tail_returns(node, helpers:)
        return node unless node.is_a?(Node)
        return node if %i[DEFN DEFS CLASS MODULE SCLASS LAMBDA ITER].include?(node.type)
        return node.children.first if node.type == :RETURN

        case node.type
        when :BLOCK
          children = node.children.dup
          children[-1] = normalize_tail_returns(children[-1], helpers: helpers) if children.any?
          node.children = children
        when :SCOPE
          children = node.children.dup
          children[2] = normalize_tail_returns(children[2], helpers: helpers)
          node.children = children
        when :IF, :UNLESS
          children = node.children.dup
          children[1] = normalize_tail_returns(children[1], helpers: helpers)
          children[2] = normalize_tail_returns(children[2], helpers: helpers) if children.size > 2
          node.children = children
        when :CASE
          children = node.children.dup
          children[1] = normalize_tail_returns(children[1], helpers: helpers)
          node.children = children
        when :CASE2
          children = node.children.dup
          children[0] = normalize_tail_returns(children[0], helpers: helpers)
          node.children = children
        when :WHEN
          children = node.children.dup
          children[1] = normalize_tail_returns(children[1], helpers: helpers)
          children[2] = normalize_tail_returns(children[2], helpers: helpers) if children.size > 2
          node.children = children
        when :RESCUE
          children = node.children.dup
          children[0] = normalize_tail_returns(children[0], helpers: helpers)
          children[1] = normalize_tail_returns(children[1], helpers: helpers)
          node.children = children
        when :RESBODY
          children = node.children.dup
          children[1] = normalize_tail_returns(children[1], helpers: helpers)
          children[2] = normalize_tail_returns(children[2], helpers: helpers) if children.size > 2
          node.children = children
        end

        node
      end

      def normalize_implicit_nil_body(node, helpers:)
        node = drop_trailing_nil_statement(node)
        return nil if node.is_a?(Node) && node.type == :NIL

        node
      end

      def inline_parameter_begin(function_node)
        return nil unless ts_node?(function_node)

        params = named_field(function_node, "parameters") ||
                 function_node.named_children.find { |child| child.kind == "method_parameters" }
        return nil unless params

        semicolon = params.next_sibling
        return nil unless semicolon && !semicolon.named? && semicolon.text == ";"

        Node.new(
          type: :BEGIN,
          children: [nil],
          first_lineno: semicolon.start_point.row + 1,
          first_column: semicolon.start_point.column,
          last_lineno: semicolon.start_point.row + 1,
          last_column: semicolon.start_point.column,
          text: ""
        )
      rescue StandardError
        nil
      end

      def normalize_parameters(node, helpers:)
        return nil unless ts_node?(node)

        pre_init = node.named_children.filter_map do |param|
          name = helpers.__send__(:parameter_name, param)
          next unless name

          value = helpers.__send__(:named_field, param, "value") ||
                  helpers.__send__(:parameter_default_value, param, name)
          helpers.__send__(
            :wrap,
            :LASGN,
            children: [name.to_sym, value ? helpers.__send__(:normalize_node, value) : nil],
            source: param
          )
        end
        return nil if pre_init.empty?

        helpers.__send__(:wrap, :ARGS, children: pre_init, source: node)
      end

      def normalize_block_parameters(block, helpers:)
        return nil unless ts_node?(block)

        params = block.named_children.find { |child| child.kind == "block_parameters" }
        return nil unless params

        destructured = params.named_children.select { |child| child.kind == "destructured_parameter" }
        pre_init = destructured.map do |param|
          helpers.__send__(:normalize_destructured_block_parameter, param)
        end.compact
        return nil if pre_init.empty?

        helpers.__send__(:wrap, :ARGS, children: pre_init, source: params)
      end

      def local_or_call_for_name(name, source, helpers:)
        return helpers.__send__(:wrap, :VCALL, children: [name.to_sym], source: source) unless local_name?(name)

        helpers.__send__(:wrap, :LVAR, children: [name], source: source)
      end

      private

      def assignment_operators
        ASSIGNMENT_OPERATORS
      end

      def ruby_instance_variable_text?(text)
        text.to_s.match?(/\A@[A-Za-z_]\w*[!?=]?\z/)
      end

      def ruby_global_variable_text?(text)
        text.to_s.match?(/\A\$[A-Za-z_]\w*[!?=]?\z/)
      end

      def drop_trailing_nil_statement(node)
        return node unless node.is_a?(Node) && node.type == :BLOCK

        children = node.children.compact
        children.pop while children.last.is_a?(Node) && children.last.type == :NIL
        return nil if children.empty?
        return children.first if children.size == 1

        node.children = children
        node
      end

      def ruby_scope_locals(node)
        locals = Set.new
        collect_ruby_scope_locals(node, locals, root: true)
        locals
      end

      def collect_ruby_scope_locals(node, locals, root: false)
        return unless ts_node?(node)
        return if !root && ruby_scope_boundary?(node)

        collect_ruby_parameter_locals(node, locals)
        collect_ruby_assignment_locals(node, locals)

        node.named_children.each do |child|
          next if ruby_scope_child_boundary?(child)

          collect_ruby_scope_locals(child, locals)
        end
      end

      def collect_ruby_parameter_locals(node, locals)
        return unless %w[method_parameters block_parameters lambda_parameters].include?(node.kind)

        node.named_children.each do |child|
          collect_identifier_names(child, locals)
        end
      end

      def collect_ruby_assignment_locals(node, locals)
        if node.kind == "exception_variable"
          collect_identifier_names(node, locals)
          return
        end

        return unless ruby_assignment_node?(node)

        left = assignment_left(node)
        collect_assignment_target_names(left, locals)
      end

      def ruby_assignment_node?(node)
        return false unless ts_node?(node)
        return true if %w[assignment operator_assignment].include?(node.kind)
        return true if node.kind == "pattern" && node.children.any? { |child| !child.named? && child.text == "=" }

        %w[body_statement block_body statement].include?(node.kind) &&
          node.children.any? { |child| !child.named? && assignment_operators.include?(child.text.to_s) }
      end

      def collect_assignment_target_names(node, locals)
        return unless ts_node?(node)

        if TreeSitterNormalizationAdapter::IDENTIFIER_KINDS.include?(node.kind)
          locals.add(node.text.to_s.sub(/\A\*/, ""))
          return
        end

        return unless %w[left_assignment_list expression_list splat splat_parameter rest_assignment].include?(node.kind)

        node.named_children.each { |child| collect_assignment_target_names(child, locals) }
      end

      def collect_identifier_names(node, locals)
        return unless ts_node?(node)

        locals.add(node.text.to_s.sub(/\A\*/, "")) if TreeSitterNormalizationAdapter::IDENTIFIER_KINDS.include?(node.kind)
        locals.add(node.text.to_s) if identifier_text_node?(node)
        node.children.select(&:named?).each { |child| collect_identifier_names(child, locals) }
      end

      def ruby_scope_boundary?(node)
        return false if %w[block do_block].include?(node.kind) && parent_node(node)&.kind == "lambda"

        TreeSitterNormalizer::FUNCTION_KINDS.include?(node.kind) || class_node?(node) ||
          (node.kind == "module" && named_field(node, "name")) ||
          %w[singleton_class lambda block do_block].include?(node.kind)
      end

      def ruby_scope_child_boundary?(node)
        ruby_scope_boundary?(node)
      end

      def assignment_left(node)
        named_field(node, "left") || node.named_children.first
      rescue StandardError
        nil
      end

      def parent_node(node)
        node.parent
      rescue StandardError
        nil
      end

      def ts_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:children)
      end
    end

  end
end
