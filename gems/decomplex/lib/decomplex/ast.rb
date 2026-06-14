# frozen_string_literal: true

require "set"

module Decomplex
  # Shared AST primitives for the v1 detectors. Kept separate from the
  # shipped v0 modules (site_extractor / co_update / predicate_alias)
  # so adding it cannot destabilise them (design principle 3); they
  # will be migrated onto this once it has proven itself.
  module Ast
    Node = Struct.new(
      :type, :children, :first_lineno, :first_column, :last_lineno, :last_column,
      :text,
      keyword_init: true
    )

    module_function

    def parse(file)
      if tree_sitter_enabled?
        require_relative "syntax"
        document = Syntax.parse(file)
        key = [:tree_sitter, document.object_id]
        return normalized_cache.fetch(key) do
          normalized_cache[key] = [TreeSitterNormalizer.new(document).normalize, document.lines]
        end
      end

      src = File.read(file)
      [RubyVM::AbstractSyntaxTree.parse(src, keep_script_lines: true), src.lines]
    end

    def normalized_cache
      @normalized_cache ||= {}
    end

    def node?(n)
      n.is_a?(RubyVM::AbstractSyntaxTree::Node) || n.is_a?(Node)
    end

    # Exact source text of a node, trivial formatting normalised.
    def slice(node, lines)
      return "" unless node?(node)
      return node.text.to_s.strip.gsub(/\s+/, " ") if node.is_a?(Node)

      sl = node.first_lineno
      el = node.last_lineno
      txt =
        if sl == el
          lines[sl - 1].byteslice(node.first_column...node.last_column)
        else
          ([lines[sl - 1].byteslice(node.first_column..) ] +
            lines[sl...(el - 1)] +
            [lines[el - 1].byteslice(0...node.last_column)]).join
      end
      txt.to_s.strip.gsub(/\s+/, " ")
    end

    def tree_sitter_enabled?
      parser = ENV.fetch("DECOMPLEX_PARSER", "rubyvm").to_s.tr("-", "_")
      %w[tree_sitter treesitter].include?(parser)
    end

    # Tree-sitter exposes each grammar's native node names. Decomplex's
    # detectors already share a tiny RubyVM-like AST vocabulary, so this
    # adapter normalizes common syntax categories into that vocabulary:
    # DEFN, CLASS, IF, CASE/WHEN, AND/OR, CALL, LASGN, ATTRASGN, IVAR,
    # LVAR, and friends. The goal is portable structural facts, not
    # Ruby semantics.
    class TreeSitterNormalizer
      FUNCTION_KINDS = %w[
        method function_definition function_declaration method_definition
        method_declaration function_item singleton_method
      ].freeze
      CLASS_KINDS = %w[class class_definition class_declaration].freeze
      MODULE_KINDS = %w[module].freeze
      BLOCK_KINDS = %w[
        block body_statement statement_block statement_list class_body
        switch_body match_block then block_body
      ].freeze
      IF_KINDS = %w[if if_statement if_modifier unless unless_modifier if_expression conditional].freeze
      LOOP_KINDS = {
        "while" => :WHILE,
        "while_statement" => :WHILE,
        "while_modifier" => :WHILE,
        "until_modifier" => :UNTIL,
        "for" => :FOR,
        "for_statement" => :FOR,
        "for_in_clause" => :FOR
      }.freeze
      CASE_KINDS = %w[
        case switch_statement expression_switch_statement switch_expression match_statement match_expression
      ].freeze
      WHEN_KINDS = %w[when switch_case case_clause expression_case match_arm].freeze
      ASSIGNMENT_KINDS = %w[
        assignment assignment_expression assignment_statement augmented_assignment
      ].freeze
      MEMBER_KINDS = %w[
        call attribute member_expression field selector_expression field_expression expression_list
      ].freeze
      CALL_KINDS = %w[call call_expression method_call method_call_expression].freeze
      IDENTIFIER_KINDS = %w[
        identifier property_identifier field_identifier shorthand_property_identifier
      ].freeze
      CONST_KINDS = %w[constant scope_resolution type_identifier scoped_type_identifier].freeze
      STRING_KINDS = %w[
        string string_content string_literal interpreted_string_literal raw_string_literal
      ].freeze
      SYMBOL_KINDS = %w[symbol simple_symbol].freeze
      NIL_KINDS = %w[nil none null].freeze
      RETURN_KINDS = {
        "return" => :RETURN,
        "return_statement" => :RETURN,
        "return_expression" => :RETURN,
        "break" => :BREAK,
        "break_statement" => :BREAK,
        "break_expression" => :BREAK,
        "next" => :NEXT,
        "continue_statement" => :NEXT
      }.freeze
      COMPARISON_OPERATORS = %w[== != === !== < <= > >=].freeze
      OPERATOR_CALL_OPERATORS = %w[+ - * / % ** | & ^ << >> =~ !~].freeze
      INFIX_STATEMENT_OPERATORS = (OPERATOR_CALL_OPERATORS + COMPARISON_OPERATORS).freeze
      INLINE_DEF_WRAPPER_MIDS = %w[
        public protected private private_class_method module_function
      ].freeze

      def initialize(document)
        @document = document
        @local_stack = []
      end

      def normalize
        children =
          if ruby?
            with_ruby_scope(@document.root, reset: true) { normalize_children(@document.root) }
          else
            normalize_children(@document.root)
          end
        wrap(:ROOT, children: children, source: @document.root)
      end

      private

      def normalize_node(node)
        return nil unless ts_node?(node)
        return nil if node.kind == "comment"
        return normalize_assignment_lhs(node) if assignment_lhs?(node)
        return normalize_infix_statement(node) if infix_statement?(node)
        return normalize_dotted_expression(node) if dotted_expression?(node)
        return normalize_unary_not_statement(node) if unary_not_statement?(node)

        if leading_function_statement?(node)
          normalize_leading_function_statement(node)
        elsif modifier_statement?(node)
          normalize_modifier_statement(node)
        elsif ternary_statement?(node)
          normalize_ternary_statement(node)
        elsif statement_call_with_block?(node)
          normalize_statement_call_with_block(node)
        elsif command_call_statement?(node)
          normalize_command_call_statement(node)
        elsif FUNCTION_KINDS.include?(node.kind)
          normalize_function(node)
        elsif class_node?(node)
          normalize_class(node)
        elsif module_node?(node)
          normalize_module(node)
        elsif node.kind == "impl_item"
          normalize_impl(node)
        elsif node.kind == "elsif"
          normalize_elsif(node)
        elsif IF_KINDS.include?(node.kind)
          normalize_if(node)
        elsif LOOP_KINDS.key?(node.kind)
          normalize_loop(node)
        elsif CASE_KINDS.include?(node.kind) || hidden_match?(node)
          normalize_case(node)
        elsif node.kind == "element_reference"
          normalize_element_reference(node)
        elsif node.kind == "rescue_modifier"
          normalize_rescue_modifier(node)
        elsif node.kind == "ensure"
          normalize_ensure_clause(node)
        elsif node.kind == "begin"
          normalize_begin(node)
        elsif node.kind == "operator_assignment"
          normalize_operator_assignment(node)
        elsif ASSIGNMENT_KINDS.include?(node.kind)
          normalize_assignment(node)
        elsif node.kind == "subshell"
          normalize_subshell(node)
        elsif node.kind == "block_argument"
          normalize_block_argument(node)
        elsif node.kind == "pair"
          normalize_pair(node)
        elsif node.kind == "singleton_class"
          normalize_singleton_class(node)
        elsif node.kind == "lambda"
          normalize_lambda(node)
        elsif node.kind == "yield"
          normalize_yield(node)
        elsif yield_argument_list?(node)
          normalize_yield_argument_list(node)
        elsif node.kind == "heredoc_beginning"
          normalize_heredoc_beginning(node)
        elsif node.kind == "chained_string"
          normalize_chained_string(node)
        elsif node.kind == "interpolation"
          normalize_interpolation(node)
        elsif unary_minus_expression?(node)
          normalize_unary_minus(node)
        elsif unary_not_expression?(node)
          normalize_unary_not(node)
        elsif boolean_expression?(node)
          normalize_boolean(node)
        elsif operator_call_expression?(node)
          normalize_operator_call(node)
        elsif comparison_expression?(node)
          normalize_comparison(node)
        elsif CALL_KINDS.include?(node.kind)
          normalize_call(node)
        elsif member_read_node?(node)
          normalize_member_read(node)
        elsif BLOCK_KINDS.include?(node.kind)
          wrap(:BLOCK, children: normalize_children(node), source: node)
        elsif unwrap_node?(node)
          normalize_node(node.named_children.first)
        elsif RETURN_KINDS.key?(node.kind)
          normalize_return(node)
        elsif self_node?(node)
          wrap(:SELF, children: [], source: node)
        elsif instance_variable?(node)
          wrap(:IVAR, children: [node.text.to_s], source: node)
        elsif global_variable?(node)
          normalize_global_variable(node)
        elsif const_node?(node)
          normalize_const(node)
        elsif ruby? && IDENTIFIER_KINDS.include?(node.kind) && node.text.to_s == "yield"
          wrap(:YIELD, children: [nil], source: node)
        elsif ruby_vcall_identifier?(node)
          return wrap(:YIELD, children: [nil], source: node) if node.text.to_s == "yield"

          wrap(:VCALL, children: [node.text.to_s.to_sym], source: node)
        elsif vcall_identifier?(node)
          wrap(:VCALL, children: [node.text.to_s.to_sym], source: node)
        elsif local_identifier?(node)
          wrap(:LVAR, children: [node.text.to_s], source: node)
        elsif NIL_KINDS.include?(node.kind)
          wrap(:NIL, children: [], source: node)
        elsif interpolated_string?(node)
          normalize_interpolated_string(node)
        elsif STRING_KINDS.include?(node.kind)
          wrap(:STR, children: [node.text.to_s], source: node)
        elsif SYMBOL_KINDS.include?(node.kind)
          wrap(:LIT, children: [node.text.to_s.sub(/\A:/, "").to_sym], source: node)
        else
          wrap(kind_type(node.kind), children: normalize_children(node), source: node)
        end
      end

      def normalize_function(node)
        return normalize_singleton_function(node) if node.kind == "singleton_method"

        name = function_name(node)
        args = normalize_parameters(named_field(node, "parameters"))
        body = with_ruby_scope(node, reset: true) do
          elide_implicit_nil_body(
            prepend_inline_parameter_begin(
              node,
              elide_tail_returns(normalize_body(named_field(node, "body") || block_child(node)))
            )
          )
        end
        wrap(:DEFN, children: [name, scope(body, args: args)], source: node)
      end

      def normalize_singleton_function(node)
        receiver = singleton_receiver(node)
        name = singleton_name(node)
        args = normalize_parameters(named_field(node, "parameters"))
        body = with_ruby_scope(node, reset: true) do
          elide_implicit_nil_body(
            prepend_inline_parameter_begin(
              node,
              elide_tail_returns(normalize_body(named_field(node, "body") || block_child(node)))
            )
          )
        end
        wrap(:DEFS, children: [normalize_node(receiver), name, scope(body, args: args)], source: node)
      end

      def normalize_class(node)
        name = const_for(named_field(node, "name") || first_named(node))
        body = normalize_body(named_field(node, "body") || block_child(node))
        wrap(:CLASS, children: [name, nil, scope(body)], source: node)
      end

      def normalize_module(node)
        name = const_for(named_field(node, "name") || first_named(node))
        body = normalize_body(named_field(node, "body") || block_child(node))
        wrap(:MODULE, children: [name, scope(body)], source: node)
      end

      def normalize_impl(node)
        type_node = named_field(node, "type") ||
                    node.named_children.find do |child|
                      %w[type_identifier scoped_type_identifier identifier].include?(child.kind)
                    end
        name = const_for(type_node || node)
        body = normalize_body(named_field(node, "body") || block_child(node) || node)
        wrap(:CLASS, children: [name, nil, scope(body)], source: node)
      end

      def normalize_if(node)
        if %w[if_modifier unless_modifier].include?(node.kind)
          action, cond_raw = node.named_children
          type = node.kind.start_with?("unless") ? :UNLESS : :IF
          return wrap(type, children: [normalize_node(cond_raw), normalize_modifier_action(action), nil], source: node)
        end

        cond_raw = named_field(node, "condition") || named_field(node, "predicate") || first_named(node)
        cond = normalize_node(cond_raw)
        positive_raw = named_field(node, "consequence") || named_field(node, "body") ||
                       node.named_children.find { |child| child.kind == "then" } ||
                       branch_child(node, cond_raw, 0)
        negative_raw = named_field(node, "alternative") ||
                       explicit_alternative(node) ||
                       (branch_child(node, cond_raw, 1) unless ruby?)
        positive = normalize_body(positive_raw)
        negative = normalize_else_or_branch(negative_raw)
        type = node.kind.start_with?("unless") ? :UNLESS : :IF
        wrap(type, children: [cond, positive, negative], source: node)
      end

      def normalize_elsif(node)
        cond = node.named_children.find { |child| !%w[comment then elsif else].include?(child.kind) }
        positive = node.named_children.find { |child| child.kind == "then" }
        negative = node.named_children.find { |child| %w[elsif else].include?(child.kind) }
        wrap(:IF, children: [normalize_node(cond), normalize_body(positive), normalize_else_or_branch(negative)],
                  source: node)
      end

      def normalize_loop(node)
        if %w[while_modifier until_modifier].include?(node.kind)
          action, cond = node.named_children
          return wrap(LOOP_KINDS.fetch(node.kind), children: [normalize_node(cond), normalize_modifier_action(action), true],
                                               source: node)
        end

        cond = normalize_node(named_field(node, "condition") || first_named(node))
        body = normalize_body(named_field(node, "body") || named_field(node, "consequence") || block_child(node))
        wrap(LOOP_KINDS.fetch(node.kind), children: [cond, body], source: node)
      end

      def normalize_case(node)
        value_raw = case_value(node)
        value = normalize_node(value_raw)
        whens = case_arms(node).map { |arm| normalize_when(arm) }.compact
        fallback = case_else_body(node)
        chain = link_when_chain(whens, fallback)
        return wrap(:CASE2, children: [chain], source: node) unless value_raw

        wrap(:CASE, children: [value, chain], source: node)
      end

      def normalize_when(node)
        patterns = normalize_patterns(node)
        body = normalize_body(when_body(node))
        wrap(:WHEN, children: [list(patterns, source: node), body, nil], source: node)
      end

      def normalize_assignment(node)
        left = assignment_left(node)
        right = normalize_node(assignment_right(node))
        return normalize_multiple_assignment(left, right, node) if left&.kind == "left_assignment_list"
        return assignment_target(left, right, source: node) if assignment_target(left, right, source: node)

        wrap(:LASGN, children: [target_name(left), right], source: node)
      end

      def normalize_multiple_assignment(left, right, node)
        targets = left.named_children.map do |child|
          type = global_variable?(child) ? :GASGN : :LASGN
          wrap(type, children: [target_name(child), nil], source: child)
        end
        wrap(:MASGN, children: [right, list(targets, source: left)], source: node)
      end

      def normalize_boolean(node)
        type = boolean_operator(node) == "or" ? :OR : :AND
        operands = node.named_children.map { |child| normalize_node(child) }.compact
        operands = operands.flat_map { |child| Ast.node?(child) && child.type == type ? child.children : [child] }
        wrap(type, children: operands, source: node)
      end

      def normalize_comparison(node)
        operands = node.named_children
        left = normalize_node(operands[0])
        right = normalize_node(operands[1])
        wrap(:OPCALL, children: [left, comparison_operator(node).to_sym, list([right], source: operands[1] || node)],
                      source: node)
      end

      def normalize_operator_call(node)
        operands = node.named_children
        left = normalize_node(operands[0])
        right = normalize_node(operands[1])
        if ruby? && binary_operator(node) == "=~" && regex_literal?(operands[1])
          return wrap(:MATCH3, children: [right, left], source: node)
        elsif ruby? && binary_operator(node) == "=~"
          return wrap(:CALL, children: [left, :=~, list([right], source: operands[1] || node)], source: node)
        end

        wrap(:OPCALL, children: [left, binary_operator(node).to_sym, list([right], source: operands[1] || node)],
                      source: node)
      end

      def normalize_element_reference(node)
        recv = node.named_children.first
        args = node.named_children.drop(1).map { |child| normalize_node(child) }.compact
        if ruby? && self_node?(recv)
          return wrap(:FCALL, children: [:[], list(args, source: node)], source: node)
        end

        wrap(:CALL, children: [normalize_node(recv), :[], list(args, source: node)], source: node)
      end

      def normalize_rescue_modifier(node)
        body = normalize_node(node.named_children.first)
        handler = normalize_node(node.named_children[1])
        resbody = wrap(:RESBODY, children: [nil, handler, nil], source: node)
        wrap(:RESCUE, children: [body, resbody, nil], source: node)
      end

      def normalize_ensure_clause(node)
        normalize_body_nodes(node.named_children, source: node)
      end

      def normalize_begin(node)
        rescue_nodes = node.named_children.select { |child| child.kind == "rescue" }
        ensure_node = node.named_children.find { |child| child.kind == "ensure" }
        if rescue_nodes.empty?
          return wrap(:BEGIN, children: normalize_children(node), source: node) unless ensure_node

          body_nodes = node.named_children.take_while { |child| child.kind != "ensure" }
          body = normalize_body_nodes(body_nodes, source: body_nodes.first || node)
          ensure_body = normalize_body(ensure_node)
          source = source_from_nodes(body_nodes.first || node, ensure_node.named_children.last || ensure_node)
          return wrap(:ENSURE, children: [body, ensure_body], source: source)
        end

        body_nodes = node.named_children.take_while { |child| child.kind != "rescue" }
        body = normalize_body_nodes(body_nodes, source: body_nodes.first || node)
        resbodies = rescue_nodes.map { |child| normalize_rescue_clause(child) }
        source = source_from_nodes(body_nodes.first || node, rescue_source_end(rescue_nodes.last) || rescue_nodes.last || node)
        rescued = wrap(:RESCUE, children: [body, link_rescue_chain(resbodies), nil], source: source)
        return rescued unless ensure_node

        ensure_body = normalize_body(ensure_node)
        ensure_source = source_from_nodes(body_nodes.first || node, ensure_node.named_children.last || ensure_node)
        wrap(:ENSURE, children: [rescued, ensure_body], source: ensure_source)
      end

      def normalize_operator_assignment(node)
        left = assignment_left(node)
        right_raw = assignment_right(node)
        right = normalize_node(right_raw)
        operator = operator_assignment_operator(node)

        if left&.kind == "element_reference"
          recv = left.named_children.first
          args = left.named_children.drop(1).map { |child| normalize_node(child) }.compact
          return wrap(:OP_ASGN1, children: [normalize_node(recv), operator, list(args, source: left), right],
                                 source: node)
        end

        if member_read_node?(left)
          recv, mid = member_parts(left)
          return wrap(:OP_ASGN2, children: [normalize_node(recv), false, mid.to_sym, operator, right], source: node)
        end

        logical = normalize_logical_operator_assignment(left, operator, right, source: node)
        return logical if logical
        if instance_variable?(left) || global_variable?(left)
          return assignment_target(left, augmented_assignment_value(left, operator, right_raw, node), source: node)
        end

        assignment_target(left, right, source: node) ||
          wrap(:LASGN, children: [target_name(left), augmented_assignment_value(left, operator, right_raw, node)],
                       source: node)
      end

      def normalize_subshell(node)
        children = node.named_children.filter_map do |child|
          case child.kind
          when "interpolation" then normalize_interpolation(child)
          when "string_content" then wrap(:STR, children: [child.text.to_s], source: child)
          end
        end
        type = children.any? { |child| child.is_a?(Node) && child.type == :EVSTR } ? :DXSTR : :XSTR
        wrap(type, children: children, source: node)
      end

      def normalize_pair(node)
        key = node.named_children.first
        value = node.named_children[1]
        if node.children.any? { |child| !child.named? && child.text == "=>" }
          return wrap(:HASH, children: [normalize_node(key), normalize_node(value)].compact, source: node)
        end

        key_lit = wrap(:LIT, children: [key.text.to_s.to_sym], source: key || node)
        if ruby? && key&.kind == "hash_key_symbol" && value.nil?
          name = key.text.to_s
          return wrap(:HASH, children: [key_lit, local_or_call_for_name(name, key)], source: node)
        end

        wrap(:HASH, children: [key_lit, normalize_node(value)].compact, source: node)
      end

      def normalize_block_argument(node)
        value = normalize_node(node.named_children.first)
        wrap(:BLOCK_PASS, children: [nil, value], source: node)
      end

      def normalize_singleton_class(node)
        recv = normalize_node(node.named_children.first)
        body = normalize_body(node.named_children[1])
        wrap(:SCLASS, children: [recv, scope(body)], source: node)
      end

      def normalize_lambda(node)
        body_node = named_field(node, "body") || block_child(node) || node.named_children.last
        body = with_ruby_scope(node) do
          dynamic_scope(normalize_body(body_node))
        end
        wrap(:LAMBDA, children: [scope(body)], source: node)
      end

      def normalize_yield(node)
        args_node = node.named_children.find { |child| child.kind == "argument_list" }
        args = args_node ? yield_argument_nodes(args_node) : yield_inline_arguments(node)
        wrap(:YIELD, children: [list(args, source: args_node || node)], source: node)
      end

      def yield_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          node.children.first&.text == "yield"
      rescue StandardError
        false
      end

      def normalize_yield_statement(node)
        args_node = node.named_children.find { |child| child.kind == "argument_list" }
        args = args_node ? yield_argument_nodes(args_node) : yield_inline_arguments(node)
        wrap(:YIELD, children: [list(args, source: args_node || node)], source: node)
      end

      def yield_argument_list?(node)
        node.kind == "argument_list" && parent_node(node)&.children&.first&.text == "yield"
      rescue StandardError
        false
      end

      def normalize_yield_argument_list(node)
        args = yield_argument_nodes(node)
        source = parent_node(node) || node
        wrap(:YIELD, children: [list(args, source: node)], source: source)
      end

      def yield_inline_arguments(node)
        node.named_children.reject { |child| child.kind == "yield" }.map { |child| normalize_node(child) }.compact
      end

      def yield_argument_nodes(node)
        return [scalar_argument_list_value(node)].compact if node.named_children.empty?

        node.named_children.map { |child| normalize_node(child) }.compact
      end

      def super_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          node.named_children.first&.kind == "super" &&
          node.named_children.drop(1).all? { |child| child.kind == "argument_list" }
      rescue StandardError
        false
      end

      def normalize_super_statement(node)
        args_node = node.named_children.find { |child| child.kind == "argument_list" }
        args = args_node ? args_node.named_children.map { |child| normalize_node(child) }.compact : []
        wrap(:SUPER, children: [list(args, source: args_node || node)], source: node)
      end

      def normalize_unary_not(node)
        operand = node.named_children.first
        wrap(:OPCALL, children: [normalize_node(operand), :!, nil], source: node)
      end

      def normalize_unary_not_statement(node)
        operand = node.named_children.first
        wrap(:OPCALL, children: [normalize_node(operand), :!, nil], source: node)
      end

      def normalize_unary_minus(node)
        operand = node.named_children.first
        if ts_node?(operand) && operand.kind == "integer"
          return wrap(:INTEGER, children: [-operand.text.to_i], source: operand)
        end

        wrap(:OPCALL, children: [normalize_node(operand), :-@, nil], source: node)
      end

      def normalize_infix_statement(node)
        left, operator, right = infix_statement_parts(node)
        if ruby? && operator == "=~" && regex_literal?(right)
          return wrap(:MATCH3, children: [normalize_node(right), normalize_node(left)], source: node)
        elsif ruby? && operator == "=~"
          return wrap(:CALL, children: [normalize_node(left), :=~, list([normalize_node(right)].compact, source: right)],
                            source: node)
        end

        wrap(:OPCALL, children: [normalize_node(left), operator.to_sym, list([normalize_node(right)].compact, source: right)],
                      source: node)
      end

      def normalize_dotted_expression(node)
        block = call_block(node)
        call = normalize_dotted_call_expression(node, source: block ? source_before_child(node, block) : node)
        return call unless block

        args = normalize_block_parameters(block)
        body = with_ruby_scope(block) do
          dynamic_scope(normalize_body(named_field(block, "body") || block_child(block) || block))
        end
        wrap(:ITER, children: [call, scope(body, args: args)], source: node)
      end

      def normalize_dotted_call_expression(node, source: node)
        recv, mid = dotted_call_parts(node)
        args = call_arguments(node, nil)
        type = safe_navigation_call?(node) ? :QCALL : :CALL
        wrap(type, children: [normalize_node(recv), mid.to_sym, list(args, source: source)], source: source)
      end

      def normalize_argument_list_call_with_block(node)
        block = call_block(node)
        call = normalize_argument_list_call(node)
        args = normalize_block_parameters(block)
        body = with_ruby_scope(block) do
          dynamic_scope(normalize_body(named_field(block, "body") || block_child(block) || block))
        end
        wrap(:ITER, children: [call, scope(body, args: args)], source: node)
      end

      def normalize_argument_list_call(node)
        function = node.named_children.first
        args_node = node.named_children.find { |child| child.kind == "argument_list" }
        args = args_node ? args_node.named_children.map { |child| normalize_node(child) }.compact : []
        wrap(:FCALL, children: [function.text.to_sym, list(args, source: args_node || node)], source: node)
      end

      def normalize_call(node)
        return normalize_zero_child_call(node) if zero_child_identifier_call?(node)
        return normalize_call_with_block(node) if call_block(node)
        return normalize_visibility_inline_def(node) if visibility_inline_def_call?(node)

        if named_field(node, "receiver") && named_field(node, "method")
          recv, mid = member_parts(node)
          args = call_arguments(node, nil)
          type = safe_navigation_call?(node) ? :QCALL : :CALL
          return wrap(type, children: [normalize_node(recv), mid.to_sym, list(args, source: node)], source: node)
        end

        function = named_field(node, "function") || named_field(node, "call") || node.named_children.first
        args = call_arguments(node, function)
        return wrap(:YIELD, children: [list(args, source: node)], source: node) if ruby? && function&.text == "yield"

        if member_read_node?(function)
          recv, mid = member_parts(function)
          return wrap(:CALL, children: [normalize_node(recv), mid.to_sym, list(args, source: node)], source: node)
        end

        if function && IDENTIFIER_KINDS.include?(function.kind)
          type = args.empty? ? :VCALL : :FCALL
          return wrap(type, children: [function.text.to_sym, list(args, source: node)], source: node)
        end

        if ruby? && function && const_node?(function)
          return wrap(:FCALL, children: [function.text.to_sym, list(args, source: node)], source: node)
        end

        wrap(:CALL, children: [normalize_node(function), :call, list(args, source: node)], source: node)
      end

      def normalize_return(node)
        normalize_return_node(node, elide_symbol: false)
      end

      def normalize_return_node(node, elide_symbol:)
        children = node.named_children.map { |child| normalize_return_value(child) }.compact
        return children.first if elide_symbol && ruby? && children.size == 1 && symbol_literal_node?(children.first)

        wrap(RETURN_KINDS.fetch(node.kind), children: children, source: node)
      end

      def normalize_return_value(node)
        return normalize_node(node) unless ts_node?(node) && node.kind == "argument_list"
        return scalar_argument_list_value(node) if node.named_children.empty?
        return normalize_argument_list_element_reference(node) if argument_list_element_reference?(node)
        return normalize_boolean(node) if boolean_expression?(node)
        return normalize_ternary_statement(node) if ternary_statement?(node)
        return normalize_case(node) if case_argument_list?(node)
        return normalize_argument_list_call_with_block(node) if argument_list_call_with_block?(node)
        return normalize_dotted_expression(node) if dotted_expression?(node)
        return normalize_argument_list_unary_not(node) if argument_list_unary_not?(node)
        return normalize_infix_statement(node) if infix_statement?(node)

        function = node.named_children.first
        nested_args = node.named_children[1]
        if function && IDENTIFIER_KINDS.include?(function.kind) && nested_args&.kind == "argument_list"
          args = nested_args.named_children.map { |child| normalize_node(child) }.compact
          return wrap(:FCALL, children: [function.text.to_sym, list(args, source: nested_args)], source: node)
        end

        values = node.named_children.map { |child| normalize_node(child) }.compact
        return values.first if values.size == 1

        list(values, source: node)
      end

      def argument_list_element_reference?(node)
        node.kind == "argument_list" &&
          node.children.first&.text != "[" &&
          node.children.any? { |child| !child.named? && child.text == "[" } &&
          node.children.any? { |child| !child.named? && child.text == "]" } &&
          node.named_children.size >= 2 &&
          node.named_children.none? { |child| %w[block do_block].include?(child.kind) }
      end

      def normalize_argument_list_element_reference(node)
        recv = node.named_children.first
        args = node.named_children.drop(1).map { |child| normalize_node(child) }.compact
        wrap(:CALL, children: [normalize_node(recv), :[], list(args, source: node)], source: node)
      end

      def normalize_call_with_block(node)
        block = call_block(node)
        call = normalize_call_without_block(node, block)
        args = normalize_block_parameters(block)
        body = with_ruby_scope(block) do
          dynamic_scope(normalize_body(named_field(block, "body") || block_child(block) || block))
        end
        wrap(:ITER, children: [call, scope(body, args: args)], source: node)
      end

      def normalize_call_without_block(node, block)
        call_source = block ? source_before_child(node, block) : node
        if dotted_call?(node)
          recv, mid = dotted_call_parts(node)
          args = call_arguments(node, nil)
          arg_list = args.empty? ? nil : list(args, source: call_source)
          type = safe_navigation_call?(node) ? :QCALL : :CALL
          return wrap(type, children: [normalize_node(recv), mid.to_sym, arg_list], source: call_source)
        end

        function = named_field(node, "function") || named_field(node, "call") ||
                   node.named_children.find { |child| !same_ts_node?(child, block) }
        args = call_arguments(node, function)

        if function && IDENTIFIER_KINDS.include?(function.kind)
          return wrap(:FCALL, children: [function.text.to_sym, list(args, source: call_source)], source: call_source)
        end

        if ruby? && function && const_node?(function)
          return wrap(:FCALL, children: [function.text.to_sym, list(args, source: call_source)], source: call_source)
        end

        if member_read_node?(function)
          recv, mid = member_parts(function)
          type = safe_navigation_call?(function) ? :QCALL : :CALL
          return wrap(type, children: [normalize_node(recv), mid.to_sym, list(args, source: call_source)], source: call_source)
        end

        wrap(:CALL, children: [normalize_node(function), :call, list(args, source: call_source)], source: call_source)
      end

      def normalize_visibility_inline_def(node)
        message = node.named_children.first&.text.to_s
        args = node.named_children.find { |child| child.kind == "argument_list" }
        method = inline_def_from_argument_list(args)
        wrap(:FCALL, children: [message.to_sym, list([method].compact, source: args || node)], source: node)
      end

      def normalize_modifier_statement(node)
        keyword = modifier_keyword(node)
        action, cond = modifier_parts(node)
        type =
          case keyword
          when "unless" then :UNLESS
          when "while" then :WHILE
          when "until" then :UNTIL
          else :IF
          end
        normalized_action = normalize_modifier_action(action)
        children = %i[WHILE UNTIL].include?(type) ? [normalize_node(cond), normalized_action, true] :
          [normalize_node(cond), normalized_action, nil]
        wrap(type, children: children, source: node)
      end

      def normalize_modifier_action(node)
        modifier_return_action?(node) ? normalize_return_node(node, elide_symbol: false) : normalize_node(node)
      end

      def modifier_return_action?(node)
        ts_node?(node) && RETURN_KINDS.key?(node.kind)
      end

      def normalize_command_call_statement(node)
        function = node.named_children.first
        if visibility_inline_def_statement?(node, function)
          method = inline_def_from_statement(node)
          return wrap(:FCALL, children: [function.text.to_sym, list([method].compact, source: node)], source: node)
        end

        args_node = node.named_children.find { |child| %w[argument_list arguments].include?(child.kind) }
        args = args_node ? command_arguments(args_node) : []
        block = call_block(node)
        call_source = block ? source_before_child(node, block) : node
        if ruby? && function&.text == "yield"
          return wrap(:YIELD, children: [list(args, source: args_node || call_source)], source: call_source)
        end

        call = wrap(args.empty? ? :VCALL : :FCALL,
                    children: [function.text.to_sym, list(args, source: args_node || call_source)],
                    source: call_source)
        return call unless block

        block_args = normalize_block_parameters(block)
        body = with_ruby_scope(block) do
          dynamic_scope(normalize_body(named_field(block, "body") || block_child(block) || block))
        end
        wrap(:ITER, children: [call, scope(body, args: block_args)], source: node)
      end

      def dynamic_scope(node)
        return node unless node.is_a?(Node)
        return node if %i[DEFN DEFS CLASS MODULE SCLASS LAMBDA].include?(node.type)

        node.type = :DASGN if node.type == :LASGN
        node.type = :DVAR if node.type == :LVAR
        node.children = node.children.map { |child| dynamic_scope(child) }
        node
      end

      def normalize_zero_child_call(node)
        wrap(:VCALL, children: [node.text.to_s.to_sym], source: node)
      end

      def normalize_member_read(node)
        recv, mid = member_parts(node)
        return wrap(kind_type(node.kind), children: normalize_children(node), source: node) unless recv && mid

        wrap(:CALL, children: [normalize_node(recv), mid.to_sym, nil], source: node)
      end

      def normalize_const(node)
        if %w[scope_resolution scoped_type_identifier].include?(node.kind)
          parts = node.named_children
          base = normalize_const(parts[0]) if parts[0]
          name = (named_field(node, "name") || parts[-1])&.text.to_s
          return wrap(:COLON2, children: [base, name.to_sym], source: node)
        end

        wrap(:CONST, children: [node.text.to_s.to_sym], source: node)
      end

      def normalize_children(node)
        node.named_children.filter_map do |child|
          next if assignment_rhs?(child)

          normalize_node(child)
        end
      end

      def normalize_body(node)
        return nil unless ts_node?(node)
        return normalize_leading_function_statement(node) if leading_function_statement?(node)
        return normalize_leading_owner_statement(node) if leading_owner_statement?(node)
        return normalize_leading_case_statement(node) if leading_case_statement?(node)
        return normalize_ensure_body_statement(node) if ensure_body_statement?(node)
        return normalize_rescue_body_statement(node) if rescue_body_statement?(node)
        return normalize_heredoc_body_statement(node) if heredoc_body_statement?(node)
        return normalize_leading_loop_statement(node) if leading_loop_statement?(node)
        return normalize_leading_if_statement(node) if leading_if_statement?(node)
        return normalize_elsif(node) if node.kind == "elsif"
        return normalize_yield_statement(node) if yield_statement?(node)
        return normalize_super_statement(node) if super_statement?(node)
        return normalize_unary_not_statement(node) if unary_not_statement?(node)
        return normalize_operator_assignment_statement(node) if operator_assignment_statement?(node)
        return normalize_element_reference_statement(node) if element_reference_statement?(node)
        return normalize_hash_literal_statement(node) if hash_literal_statement?(node)
        return normalize_array_literal_statement(node) if array_literal_statement?(node)
        return normalize_concatenated_string_statement(node) if concatenated_string_statement?(node)
        return normalize_interpolated_statement(node) if interpolated_statement?(node)
        return nil if empty_body_statement?(node)
        return normalize_terminal_statement(node) if terminal_statement?(node)
        return normalize_modifier_statement(node) if modifier_statement?(node)
        return normalize_ternary_statement(node) if ternary_statement?(node)
        return normalize_statement_call_with_block(node) if statement_call_with_block?(node)
        return normalize_command_call_statement(node) if command_call_statement?(node)
        return normalize_infix_statement(node) if infix_statement?(node)
        return normalize_boolean(node) if boolean_expression?(node)
        return normalize_dotted_expression(node) if dotted_expression?(node)

        if BLOCK_KINDS.include?(node.kind)
          children = normalize_children(node)
          if children.empty? && bare_identifier_text?(node.text)
            return wrap(:VCALL, children: [node.text.to_s.strip.to_sym], source: node)
          end
          return nil if children.empty?
          return children.first if children.size == 1

          return wrap(:BLOCK, children: children, source: node)
        end

        normalize_node(node)
      end

      def normalize_body_nodes(nodes, source:)
        children = nodes.map { |child| normalize_body(child) }.compact
        return nil if children.empty?
        return children.first if children.size == 1

        wrap(:BLOCK, children: children, source: source)
      end

      def normalize_patterns(node)
        patterns = node.named_children.select do |child|
          %w[pattern case_pattern match_pattern].include?(child.kind)
        end
        patterns = [named_field(node, "value")].compact if patterns.empty?
        patterns = [node.named_children.find { |child| !BLOCK_KINDS.include?(child.kind) && !statement_node?(child) }].compact if patterns.empty?

        patterns.flat_map do |pattern|
          if pattern.text.to_s.include?("::")
            [wrap(:CONST, children: [pattern.text.to_s.to_sym], source: pattern)]
          elsif %w[pattern case_pattern match_pattern expression_list].include?(pattern.kind)
            pattern.named_children.map { |child| normalize_node(child) }.compact
          else
            [normalize_node(pattern)].compact
          end
        end
      end

      def assignment_target(left, right, source: nil)
        return nil unless ts_node?(left)
        source ||= left

        if instance_variable?(left)
          return wrap(:IASGN, children: [left.text.to_s, right], source: source)
        end

        if global_variable?(left)
          return wrap(:GASGN, children: [left.text.to_s, right], source: source)
        end

        if left.kind == "element_reference"
          recv = left.named_children.first
          args = left.named_children.drop(1).map { |child| normalize_node(child) }.compact
          return wrap(:ATTRASGN, children: [normalize_node(recv), :[]=, list(args + [right], source: left)],
                               source: source)
        end

        if member_read_node?(left)
          recv, mid = member_parts(left)
          writer = left.text.to_s.include?("&.") ? mid.to_sym : "#{mid}=".to_sym
          return wrap(:ATTRASGN, children: [normalize_node(recv), writer, list([right], source: left)],
                               source: source)
        end

        return assignment_target(left.named_children.first, right, source: source) if left.kind == "expression_list"

        nil
      end

      def normalize_assignment_lhs(node)
        right = normalize_node(next_named_sibling(node))
        source = parent_node(node) || node
        assignment_target(node, right, source: source) ||
          wrap(:LASGN, children: [target_name(node), right], source: node)
      end

      def target_name(left)
        return left.text.to_s.sub(/\A\*/, "") if ts_node?(left) && IDENTIFIER_KINDS.include?(left.kind)
        return left.text.to_s.sub(/\A\*/, "") if ts_node?(left) && %w[splat splat_parameter rest_assignment].include?(left.kind)
        return left.text.to_s if ts_node?(left)

        Ast.slice(normalize_node(left), @document.lines)
      end

      def case_value(node)
        named_field(node, "value") || named_field(node, "subject") ||
          named_field(node, "condition") ||
          node.named_children.find do |child|
            !WHEN_KINDS.include?(child.kind) && !BLOCK_KINDS.include?(child.kind) && child.kind != "else"
          end
      end

      def case_arms(node)
        arms = []
        stack = node.named_children.dup
        until stack.empty?
          child = stack.shift
          next unless ts_node?(child)

          if WHEN_KINDS.include?(child.kind)
            arms << child
          else
            stack.concat(child.named_children) unless FUNCTION_KINDS.include?(child.kind)
          end
        end
        arms
      end

      def when_body(node)
        named_field(node, "body") || named_field(node, "consequence") ||
          named_field(node, "value") ||
          node.named_children.reverse.find { |child| BLOCK_KINDS.include?(child.kind) || statement_node?(child) }
      end

      def link_when_chain(whens, fallback = nil)
        whens.reverse.inject(fallback) do |next_when, current|
          current.children[2] = next_when
          current
        end
      end

      def case_else_body(node)
        else_node = node.named_children.find { |child| child.kind == "else" }
        normalize_else_or_branch(else_node)
      end

      def normalize_else_or_branch(node)
        return nil unless ts_node?(node)
        return normalize_body(node) unless node.kind == "else"

        normalize_body_nodes(node.named_children, source: node)
      end

      def link_rescue_chain(resbodies)
        resbodies.reverse.inject(nil) do |next_rescue, current|
          current.children[2] = next_rescue
          current
        end
      end

      def boolean_expression?(node)
        (%w[binary binary_expression boolean_operator].include?(node.kind) || boolean_statement?(node)) &&
          %w[and or].include?(boolean_operator(node))
      end

      def boolean_statement?(node)
        return false unless %w[body_statement block_body statement argument_list].include?(node.kind)
        return false unless %w[&& || and or].include?(binary_operator(node))
        return false if node.named_children.size < 2

        node.children.all? do |child|
          child.named? || %w[&& || and or ( )].include?(child.text.to_s)
        end
      end

      def operator_call_expression?(node)
        %w[binary binary_expression].include?(node.kind) &&
          OPERATOR_CALL_OPERATORS.include?(binary_operator(node))
      end

      def infix_statement?(node)
        left, operator, right = infix_statement_parts(node)
        left && right && INFIX_STATEMENT_OPERATORS.include?(operator)
      end

      def dotted_expression?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) && dotted_call?(node)
      end

      def argument_list_call_with_block?(node)
        return false unless node.kind == "argument_list"
        return false if dotted_call?(node)
        return false unless call_block(node)

        IDENTIFIER_KINDS.include?(node.named_children.first&.kind)
      end

      def infix_statement_parts(node)
        return [nil, nil, nil] unless %w[body_statement block_body statement argument_list].include?(node.kind)

        named_index = 0
        left = nil
        right = nil
        operator = nil
        node.children.each do |child|
          if child.named?
            left ||= child
            right = child if operator
            named_index += 1
          elsif INFIX_STATEMENT_OPERATORS.include?(child.text.to_s)
            operator = child.text.to_s
          end
        end
        return [nil, nil, nil] unless named_index == 2 && operator

        [left, operator, right]
      rescue StandardError
        [nil, nil, nil]
      end

      def argument_list_unary_not?(node)
        node.kind == "argument_list" &&
          node.children.first&.text == "!" &&
          node.named_children.size == 1
      rescue StandardError
        false
      end

      def unary_not_statement?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) &&
          node.children.first&.text == "!" &&
          node.named_children.size == 1
      rescue StandardError
        false
      end

      def normalize_argument_list_unary_not(node)
        operand = node.named_children.first
        wrap(:OPCALL, children: [normalize_node(operand), :!, nil], source: node)
      end

      def comparison_expression?(node)
        %w[binary binary_expression comparison_operator].include?(node.kind) &&
          COMPARISON_OPERATORS.include?(comparison_operator(node))
      end

      def regex_literal?(node)
        ts_node?(node) && %w[regex regex_literal].include?(node.kind)
      end

      def unary_not_expression?(node)
        %w[unary unary_expression].include?(node.kind) && node.text.to_s.lstrip.start_with?("!")
      end

      def unary_minus_expression?(node)
        %w[unary unary_expression].include?(node.kind) && node.text.to_s.lstrip.start_with?("-")
      end

      def boolean_operator(node)
        direct = binary_operator(node)
        return "and" if %w[&& and].include?(direct)
        return "or" if %w[|| or].include?(direct)
        return nil if ts_node?(node)

        text = spaced_text(node)
        return "and" if text.include?("&&") || text.match?(/\band\b/)
        return "or" if text.include?("||") || text.match?(/\bor\b/)

        nil
      end

      def comparison_operator(node)
        binary_operator(node) || spaced_text(node)[/(===|!==|==|!=|<=|>=|<|>)/, 1]
      end

      def binary_operator(node)
        node.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s
      end

      def spaced_text(node)
        " #{node.text} "
      end

      def class_node?(node)
        CLASS_KINDS.include?(node.kind)
      end

      def module_node?(node)
        MODULE_KINDS.include?(node.kind) && named_field(node, "name")
      end

      def unwrap_node?(node)
        %w[
          parenthesized_expression parenthesized_statements expression_statement statement
          case_pattern match_pattern pattern
        ].include?(node.kind) && node.named_children.size == 1
      end

      def statement_node?(node)
        node.kind.end_with?("_statement") || node.kind.end_with?("_expression") ||
          %w[return break next].include?(node.kind)
      end

      def local_identifier?(node)
        IDENTIFIER_KINDS.include?(node.kind)
      end

      def ruby_vcall_identifier?(node)
        return false unless ruby?
        return false unless IDENTIFIER_KINDS.include?(node.kind)
        return false if assignment_lhs?(node)
        return false if ruby_definition_identifier?(node)

        !ruby_local_name?(node.text.to_s)
      end

      def ruby_definition_identifier?(node)
        parent = parent_node(node)
        return false unless ts_node?(parent)

        if %w[method singleton_method].include?(parent.kind)
          name = named_field(parent, "name") ||
                 parent.named_children.find { |child| IDENTIFIER_KINDS.include?(child.kind) }
          return same_ts_node?(name, node)
        end

        %w[
          method_parameters block_parameters lambda_parameters
          optional_parameter keyword_parameter block_parameter
        ].include?(parent.kind)
      end

      def ruby_local_name?(name)
        @local_stack.reverse.any? { |scope| scope.include?(name) }
      end

      def ruby?
        @document.language == :ruby
      end

      def interpolated_string?(node)
        node.kind == "string" && node.named_children.any? { |child| child.kind == "interpolation" }
      end

      def normalize_interpolated_string(node)
        wrap(:DSTR, children: normalize_children(node), source: node)
      end

      def vcall_identifier?(node)
        return false unless local_identifier?(node)
        return false if ruby? && ruby_local_name?(node.text.to_s)

        parent = parent_node(node)
        return false unless ts_node?(parent)
        return false if %w[method method_parameters parameter_list argument_list arguments].include?(parent.kind)
        return false if member_read_node?(parent)
        return false if assignment_lhs?(node) || assignment_rhs?(node)

        return true if %w[body_statement block_body then].include?(parent.kind) && parent_named_child?(parent, node)
        return true if %w[if_modifier unless_modifier].include?(parent.kind) && same_ts_node?(parent.named_children.first, node)

        false
      end

      def const_node?(node)
        CONST_KINDS.include?(node.kind)
      end

      def self_node?(node)
        %w[self this].include?(node.kind) || node.text == "self" || node.text == "this"
      end

      def instance_variable?(node)
        node.kind == "instance_variable" || node.text.to_s.match?(/\A@[A-Za-z_]\w*[!?=]?\z/)
      end

      def global_variable?(node)
        node.kind == "global_variable" || node.text.to_s.match?(/\A\$[A-Za-z_]\w*[!?=]?\z/)
      end

      def member_read_node?(node)
        ts_node?(node) && MEMBER_KINDS.include?(node.kind) && member_parts(node).all?
      end

      def assignment_lhs?(node)
        return false if prev_sibling(node)&.text == ":"
        return false if literal_fragment_assignment_context?(node)

        sibling = next_sibling(node)
        sibling && assignment_operator?(sibling.text)
      end

      def assignment_rhs?(node)
        sibling = prev_sibling(node)
        sibling && assignment_operator?(sibling.text)
      end

      def literal_fragment_assignment_context?(node)
        parent = parent_node(node)
        return false unless ts_node?(parent)
        return true if %w[string delimited_symbol regex regex_literal].include?(parent.kind)

        %w[string_content escape_sequence interpolation].include?(node.kind) &&
          ts_node?(parent_node(parent)) &&
          %w[string delimited_symbol regex regex_literal].include?(parent_node(parent).kind)
      end

      def assignment_operator?(text)
        %w[= += -= *= /= %= &&= ||=].include?(text.to_s)
      end

      def operator_assignment_operator(node)
        raw = node.children.find { |child| !child.named? && child.text.to_s.end_with?("=") }&.text.to_s
        op = raw.sub(/=\z/, "")
        op = "||" if raw == "||="
        op = "&&" if raw == "&&="
        op.to_sym
      end

      def augmented_assignment_value(left, operator, right_raw, source)
        receiver = assignment_receiver(left)
        right = normalize_node(right_raw)
        wrap(:CALL, children: [receiver, operator, list([right].compact, source: right_raw || left)], source: source)
      end

      def normalize_logical_operator_assignment(left, operator, right, source:)
        return nil unless ruby? && [:"||", :"&&"].include?(operator)
        return nil unless ts_node?(left) && IDENTIFIER_KINDS.include?(left.kind)

        name = target_name(left)
        type = operator == :"||" ? :OP_ASGN_OR : :OP_ASGN_AND
        receiver = wrap(:LVAR, children: [name], source: left)
        assignment = wrap(:LASGN, children: [name, right], source: source)
        wrap(type, children: [receiver, operator, assignment], source: source)
      end

      def assignment_receiver(left)
        return nil unless ts_node?(left)
        return wrap(:LVAR, children: [left.text.to_s], source: left) if IDENTIFIER_KINDS.include?(left.kind)
        return wrap(:IVAR, children: [left.text.to_s], source: left) if instance_variable?(left)
        return normalize_const(left) if const_node?(left)

        normalize_node(left)
      end

      def with_ruby_scope(node, reset: false)
        return yield unless ruby?

        previous = @local_stack
        @local_stack = [] if reset
        @local_stack = @local_stack + [ruby_scope_locals(node)]
        yield
      ensure
        @local_stack = previous if ruby?
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

        %w[body_statement statement].include?(node.kind) &&
          node.children.any? { |child| !child.named? && assignment_operator?(child.text) }
      end

      def collect_assignment_target_names(node, locals)
        return unless ts_node?(node)

        if IDENTIFIER_KINDS.include?(node.kind)
          locals.add(node.text.to_s.sub(/\A\*/, ""))
          return
        end

        return unless %w[left_assignment_list expression_list splat splat_parameter rest_assignment].include?(node.kind)

        node.named_children.each { |child| collect_assignment_target_names(child, locals) }
      end

      def collect_identifier_names(node, locals)
        return unless ts_node?(node)

        locals.add(node.text.to_s.sub(/\A\*/, "")) if IDENTIFIER_KINDS.include?(node.kind)
        node.named_children.each { |child| collect_identifier_names(child, locals) }
      end

      def ruby_scope_boundary?(node)
        return false if %w[block do_block].include?(node.kind) && parent_node(node)&.kind == "lambda"

        FUNCTION_KINDS.include?(node.kind) || class_node?(node) || module_node?(node) ||
          %w[singleton_class lambda block do_block].include?(node.kind)
      end

      def ruby_scope_child_boundary?(node)
        ruby_scope_boundary?(node)
      end

      def member_parts(node)
        return [nil, nil] if node.kind == "expression_list" &&
                             !(named_field(node, "operand") && named_field(node, "field"))

        return dotted_call_parts(node) if dotted_call?(node)

        recv = named_field(node, "receiver") || named_field(node, "object") ||
               named_field(node, "operand") || named_field(node, "value") ||
               node.named_children.first
        mid = named_field(node, "method") || named_field(node, "field") ||
              named_field(node, "property") || node.named_children.reject { |child| %w[block do_block argument_list arguments].include?(child.kind) }.last
        return [nil, nil] unless recv && mid && recv != mid

        [recv, mid.text.to_s.sub(/=\z/, "")]
      end

      def call_arguments(node, function)
        args = named_field(node, "arguments") || named_field(node, "argument") ||
               node.named_children.find { |child| %w[argument_list arguments].include?(child.kind) }
        return [] unless args

        children = args.named_children.reject { |child| function && child == function }
        return [normalize_dotted_expression(args)] if dotted_expression?(args)
        if children.empty?
          scalar = scalar_argument_list_value(args)
          return [scalar] if scalar

          return literal_arguments_from_text(args)
        end
        return [normalize_infix_statement(args)] if infix_statement?(args)

        children.map { |child| normalize_node(child) }.compact
      end

      def assignment_left(node)
        named_field(node, "left") || node.named_children.first
      end

      def assignment_right(node)
        named_field(node, "right") || node.named_children[1]
      end

      def function_name(node)
        return singleton_name(node) if node.kind == "singleton_method"

        name = named_field(node, "name") ||
               node.named_children.find do |child|
                 IDENTIFIER_KINDS.include?(child.kind) || child.kind == "constant"
               end
        name&.text.to_s.to_sym
      end

      def singleton_receiver(node)
        named_field(node, "receiver") ||
          node.named_children.find { |child| child.kind != "identifier" } ||
          node.named_children.first
      end

      def singleton_name(node)
        name = named_field(node, "name")&.text ||
               node.named_children.reverse.find { |child| IDENTIFIER_KINDS.include?(child.kind) }&.text.to_s
        name.to_s.to_sym
      end

      def first_named(node)
        node.named_children.first
      end

      def block_child(node)
        node.named_children.find { |child| BLOCK_KINDS.include?(child.kind) || %w[block do_block].include?(child.kind) }
      end

      def branch_child(node, cond, index)
        node.named_children.reject { |child| child == cond || %w[comment else elsif].include?(child.kind) }[index]
      end

      def explicit_alternative(node)
        node.named_children.find { |child| %w[elsif else].include?(child.kind) }
      end

      def const_for(node)
        return wrap(:CONST, children: ["(anonymous)".to_sym], source: @document.root) unless ts_node?(node)
        return normalize_const(node) if const_node?(node)

        wrap(:CONST, children: [node.text.to_s.to_sym], source: node)
      end

      def normalize_parameters(node)
        return nil unless ruby? && ts_node?(node)

        defaults = node.named_children.filter_map do |param|
          name = named_field(param, "name")
          value = named_field(param, "value")
          next unless name && value

          wrap(:LASGN, children: [name.text.to_sym, normalize_node(value)], source: param)
        end
        return nil if defaults.empty?

        wrap(:ARGS, children: defaults, source: node)
      end

      def normalize_block_parameters(block)
        return nil unless ruby? && ts_node?(block)

        params = block.named_children.find { |child| child.kind == "block_parameters" }
        return nil unless params

        destructured = params.named_children.select { |child| child.kind == "destructured_parameter" }
        pre_init = destructured.map { |param| normalize_destructured_block_parameter(param) }.compact
        return nil if pre_init.empty?

        wrap(:ARGS, children: pre_init, source: params)
      end

      def normalize_destructured_block_parameter(param)
        targets = []
        param.named_children.each { |child| collect_destructured_parameter_targets(child, targets) }
        return nil if targets.empty?

        wrap(:MASGN,
             children: [
               wrap(:DVAR, children: [nil], source: param),
               list(targets, source: param),
               nil,
             ],
             source: param)
      end

      def collect_destructured_parameter_targets(node, targets)
        return unless ts_node?(node)

        if IDENTIFIER_KINDS.include?(node.kind)
          targets << wrap(:DASGN, children: [node.text.to_s, nil], source: node)
          return
        end

        node.named_children.each { |child| collect_destructured_parameter_targets(child, targets) }
      end

      def scope(body, args: nil)
        wrap(:SCOPE, children: [nil, args, body], source: body || args || @document.root)
      end

      def list(children, source:)
        return nil if children.nil? || children.empty?

        wrap(:LIST, children: children, source: source)
      end

      def wrap(type, children:, source:)
        if source.respond_to?(:start_point)
          first_lineno = source.start_point.row + 1
          first_column = source.start_point.column
          last_lineno = source.end_point.row + 1
          last_column = source.end_point.column
          text = source.text.to_s
        else
          first_lineno = source.first_lineno
          first_column = source.first_column
          last_lineno = source.last_lineno
          last_column = source.last_column
          text = source.text.to_s
        end

        Node.new(
          type: type,
          children: children,
          first_lineno: first_lineno,
          first_column: first_column,
          last_lineno: last_lineno,
          last_column: last_column,
          text: text
        )
      end

      def source_before_child(node, child)
        text = @document.source.byteslice(node.start_byte...child.start_byte).to_s.rstrip
        return node if text.empty?

        lines = text.lines
        last_lineno = node.start_point.row + lines.size
        last_column =
          if lines.size <= 1
            node.start_point.column + text.length
          else
            lines.last.to_s.chomp.length
          end
        Node.new(
          type: :SOURCE,
          children: [],
          first_lineno: node.start_point.row + 1,
          first_column: node.start_point.column,
          last_lineno: last_lineno,
          last_column: last_column,
          text: text
        )
      end

      def source_from_nodes(first_node, last_node)
        return first_node unless ts_node?(first_node) && ts_node?(last_node)

        text = @document.source.byteslice(first_node.start_byte...last_node.end_byte).to_s
        Node.new(
          type: :SOURCE,
          children: [],
          first_lineno: first_node.start_point.row + 1,
          first_column: first_node.start_point.column,
          last_lineno: last_node.end_point.row + 1,
          last_column: last_node.end_point.column,
          text: text
        )
      end

      def source_from_normalized_nodes(first_node, last_node)
        return first_node unless first_node.is_a?(Node) && last_node.is_a?(Node)

        text =
          if first_node.first_lineno == last_node.last_lineno
            @document.lines[first_node.first_lineno - 1].to_s.byteslice(first_node.first_column...last_node.last_column)
          else
            ([@document.lines[first_node.first_lineno - 1].to_s.byteslice(first_node.first_column..)] +
              @document.lines[first_node.first_lineno...(last_node.last_lineno - 1)] +
              [@document.lines[last_node.last_lineno - 1].to_s.byteslice(0...last_node.last_column)]).join
          end
        Node.new(
          type: :SOURCE,
          children: [],
          first_lineno: first_node.first_lineno,
          first_column: first_node.first_column,
          last_lineno: last_node.last_lineno,
          last_column: last_node.last_column,
          text: text.to_s
        )
      end

      def named_field(node, name)
        node.child_by_field_name(name)
      rescue StandardError
        nil
      end

      def parent_node(node)
        node.parent
      rescue StandardError
        nil
      end

      def next_sibling(node)
        node.next_sibling
      rescue StandardError
        nil
      end

      def prev_sibling(node)
        node.prev_sibling
      rescue StandardError
        nil
      end

      def next_named_sibling(node)
        node.next_named_sibling
      rescue StandardError
        nil
      end

      def modifier_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          modifier_keyword(node) &&
          node.named_children.size >= 2
      end

      def ternary_statement?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) &&
          node.named_children.size >= 3 &&
          node.children.any? { |child| !child.named? && child.text == "?" } &&
          node.children.any? { |child| !child.named? && child.text == ":" }
      rescue StandardError
        false
      end

      def normalize_ternary_statement(node)
        cond, positive, negative = node.named_children
        wrap(:IF, children: [normalize_node(cond), normalize_node(positive), normalize_node(negative)], source: node)
      end

      def case_argument_list?(node)
        node.kind == "argument_list" &&
          node.children.any? { |child| !child.named? && child.kind == "case" } &&
          node.named_children.any? { |child| WHEN_KINDS.include?(child.kind) }
      rescue StandardError
        false
      end

      def leading_function_statement?(node)
        %w[body_statement statement].include?(node.kind) &&
          node.children.first&.kind.to_s == "def" &&
          node.named_children.any? { |child| IDENTIFIER_KINDS.include?(child.kind) }
      rescue StandardError
        false
      end

      def normalize_leading_function_statement(node)
        name = node.named_children.find { |child| IDENTIFIER_KINDS.include?(child.kind) }&.text.to_s.to_sym
        body = node.named_children.reverse.find { |child| child.kind == "body_statement" }
        normalized_body = with_ruby_scope(node, reset: true) do
          elide_tail_returns(normalize_body(body))
        end
        wrap(:DEFN, children: [name, scope(normalized_body)], source: node)
      end

      def command_call_statement?(node)
        return false unless %w[body_statement block_body statement].include?(node.kind)
        return false if dotted_call?(node)
        return false unless node.named_children.first&.kind == "identifier"

        node.named_children.any? { |child| %w[argument_list arguments].include?(child.kind) } ||
          call_block(node)
      end

      def zero_child_identifier_call?(node)
        node.kind == "call" && node.named_children.empty? &&
          node.text.to_s.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
      end

      def dotted_call?(node)
        return false unless ts_node?(node)
        return false unless node.children.any? { |child| child.text == "." || child.text == "&." }

        callable = node.named_children.reject { |child| %w[block do_block argument_list arguments].include?(child.kind) }
        return false if callable.any? { |child| %w[string_content interpolation].include?(child.kind) }

        callable.size >= 2
      end

      def safe_navigation_call?(node)
        ts_node?(node) && node.children.any? { |child| !child.named? && child.text == "&." }
      end

      def dotted_call_parts(node)
        callable = node.named_children.reject { |child| %w[block do_block argument_list arguments].include?(child.kind) }
        [callable.first, callable[1].text.to_s.sub(/=\z/, "")]
      end

      def leading_if_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          %w[if unless].include?(node.children.first&.kind.to_s) &&
          node.named_children.size >= 2 &&
          !IF_KINDS.include?(node.named_children.first.kind)
      rescue StandardError
        false
      end

      def leading_case_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          node.children.first&.kind.to_s == "case" &&
          node.named_children.any? { |child| WHEN_KINDS.include?(child.kind) }
      rescue StandardError
        false
      end

      def normalize_leading_case_statement(node)
        value = normalize_node(case_value(node))
        whens = case_arms(node).map { |arm| normalize_when(arm) }.compact
        wrap(:CASE, children: [value, link_when_chain(whens, case_else_body(node))], source: node)
      end

      def leading_loop_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          !node.children.first&.named? &&
          %w[while until].include?(node.children.first&.kind.to_s) &&
          node.named_children.size >= 2
      rescue StandardError
        false
      end

      def rescue_body_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          node.named_children.any? { |child| child.kind == "rescue" }
      rescue StandardError
        false
      end

      def normalize_rescue_body_statement(node)
        named = node.named_children
        rescue_index = named.index { |child| child.kind == "rescue" }
        body = normalize_body_nodes(named[0...rescue_index], source: node)
        rescue_nodes = named[rescue_index..].select { |child| child.kind == "rescue" }
        resbodies = rescue_nodes.map { |child| normalize_rescue_clause(child) }
        source = source_from_nodes(named.first || node, rescue_source_end(rescue_nodes.last) || rescue_nodes.last || node)
        wrap(:RESCUE, children: [body, link_rescue_chain(resbodies), nil], source: source)
      end

      def normalize_rescue_clause(node)
        exceptions = node.named_children.find { |child| child.kind == "exceptions" }
        exception_nodes = exceptions ? exceptions.named_children.map { |child| normalize_node(child) }.compact : []
        exception_variable = rescue_exception_variable(node)
        handler = node.named_children.reverse.find do |child|
          !%w[exceptions exception_variable comment].include?(child.kind)
        end
        body = prepend_rescue_exception_assignment(normalize_body(handler), exception_variable)
        wrap(:RESBODY, children: [list(exception_nodes, source: exceptions || node), body, nil],
                       source: node)
      end

      def rescue_source_end(node)
        return nil unless ts_node?(node)

        handler = node.named_children.reverse.find do |child|
          !%w[exceptions exception_variable comment].include?(child.kind)
        end
        return handler.named_children.last || handler if ts_node?(handler)

        node.named_children.reverse.find { |child| !%w[comment].include?(child.kind) } || node
      end

      def rescue_exception_variable(node)
        var = node.named_children.find { |child| child.kind == "exception_variable" }
        name = var&.named_children&.find { |child| IDENTIFIER_KINDS.include?(child.kind) }
        return nil unless name

        wrap(:LASGN, children: [name.text.to_s, wrap(:ERRINFO, children: [], source: var)], source: var)
      end

      def prepend_rescue_exception_assignment(body, assignment)
        return body unless assignment
        return assignment unless body.is_a?(Node)

        if body.type == :BLOCK
          body.children = [assignment] + body.children.compact
          body
        else
          wrap(:BLOCK, children: [assignment, body], source: source_from_normalized_nodes(assignment, body))
        end
      end

      def ensure_body_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          node.named_children.any? { |child| child.kind == "ensure" }
      rescue StandardError
        false
      end

      def normalize_ensure_body_statement(node)
        named = node.named_children
        ensure_index = named.index { |child| child.kind == "ensure" }
        body = normalize_body_nodes(named[0...ensure_index], source: node)
        ensure_body = normalize_body(named[ensure_index])
        wrap(:ENSURE, children: [body, ensure_body], source: body || node)
      end

      def array_literal_statement?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) &&
          node.children.first&.text == "[" &&
          node.children.last&.text == "]"
      rescue StandardError
        false
      end

      def element_reference_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          node.children.first&.text != "[" &&
          node.children.any? { |child| !child.named? && child.text == "[" } &&
          node.children.any? { |child| !child.named? && child.text == "]" } &&
          node.named_children.size >= 2
      rescue StandardError
        false
      end

      def normalize_element_reference_statement(node)
        recv = node.named_children.first
        args = node.named_children.drop(1).map { |child| normalize_node(child) }.compact
        wrap(:CALL, children: [normalize_node(recv), :[], list(args, source: node)], source: node)
      end

      def hash_literal_statement?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) &&
          node.children.first&.text == "{" &&
          node.children.last&.text == "}"
      rescue StandardError
        false
      end

      def normalize_hash_literal_statement(node)
        wrap(:HASH, children: normalize_children(node), source: node)
      end

      def normalize_array_literal_statement(node)
        values = node.named_children.map { |child| normalize_node(child) }.compact
        return wrap(:ZLIST, children: [], source: node) if values.empty?

        list(values, source: node)
      end

      def empty_body_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          node.named_children.empty? &&
          node.text.to_s.strip.empty?
      end

      def heredoc_body_statement?(node)
        %w[body_statement block_body statement then].include?(node.kind) &&
          node.named_children.any? { |child| child.kind == "heredoc_body" }
      rescue StandardError
        false
      end

      def normalize_heredoc_body_statement(node)
        heredoc_bodies = node.named_children.select { |child| child.kind == "heredoc_body" }
        children = node.named_children.filter_map do |child|
          next if child.kind == "heredoc_body"

          if heredoc_call_for_body?(child)
            with_current_heredoc_body(heredoc_bodies.shift) { normalize_node(child) }
          else
            normalize_body(child)
          end
        end
        return nil if children.empty?
        return children.first if children.size == 1

        wrap(:BLOCK, children: children, source: node)
      end

      def heredoc_call_for_body?(node)
        return false unless ts_node?(node)
        return true if node.kind == "heredoc_beginning"

        node.named_children.any? do |child|
          next false if child.named_children.any? { |grandchild| grandchild.kind == "heredoc_body" }

          heredoc_call_for_body?(child)
        end
      end

      def with_current_heredoc_body(body)
        previous = @current_heredoc_body
        @current_heredoc_body = body
        yield
      ensure
        @current_heredoc_body = previous
      end

      def normalize_heredoc_beginning(node)
        body = @current_heredoc_body
        children = body ? normalize_heredoc_children(body) : []
        wrap(:DSTR, children: children, source: node)
      end

      def normalize_heredoc_children(node)
        node.named_children.filter_map do |child|
          case child.kind
          when "interpolation"
            normalize_interpolation(child)
          when "heredoc_content"
            text = child.text.to_s
            text.empty? ? nil : wrap(:STR, children: [text], source: child)
          else
            nil
          end
        end
      end

      def normalize_interpolation(node)
        exprs = node.named_children.map { |child| normalize_node(child) }.compact
        body = exprs.size == 1 ? exprs.first : list(exprs, source: node)
        wrap(:EVSTR, children: [body].compact, source: node)
      end

      def interpolated_statement?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) &&
          node.named_children.any? { |child| child.kind == "interpolation" }
      rescue StandardError
        false
      end

      def normalize_interpolated_statement(node)
        wrap(:DSTR, children: normalize_children(node), source: node)
      end

      def concatenated_string_statement?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) &&
          node.named_children.size > 1 &&
          node.named_children.all? { |child| child.kind == "string" }
      rescue StandardError
        false
      end

      def normalize_concatenated_string_statement(node)
        normalized = node.named_children.map { |child| [child, normalize_node(child)] }
        parts = normalized.flat_map do |_child, child_node|
          child_node.is_a?(Node) && child_node.type == :DSTR ? child_node.children : [child_node]
        end.compact
        wrap(:DSTR, children: parts, source: dynamic_string_source(normalized) || node.named_children.first)
      end

      def normalize_chained_string(node)
        normalized = node.named_children.map { |child| [child, normalize_node(child)] }
        parts = normalized.flat_map do |_child, child_node|
          child_node.is_a?(Node) && child_node.type == :DSTR ? child_node.children : [child_node]
        end.compact
        wrap(:DSTR, children: parts, source: dynamic_string_source(normalized) || node.named_children.first || node)
      end

      def dynamic_string_source(normalized_children)
        normalized_children.find do |_child, child_node|
          child_node.is_a?(Node) && child_node.type == :DSTR &&
            child_node.children.any? { |part| part.is_a?(Node) && part.type == :EVSTR }
        end&.first
      end

      def terminal_statement?(node)
        %w[body_statement block_body statement argument_list].include?(node.kind) &&
          node.named_children.empty? &&
          !node.text.to_s.strip.empty?
      end

      def normalize_terminal_statement(node)
        text = node.text.to_s.strip
        return wrap(:YIELD, children: [nil], source: node) if ruby? && text == "yield"
        return wrap(:IVAR, children: [text], source: node) if text.match?(/\A@[A-Za-z_]\w*[!?=]?\z/)
        return normalize_global_variable(node) if text.match?(/\A\$/)
        return wrap(:NIL, children: [], source: node) if text == "nil"
        return wrap(:TRUE, children: [], source: node) if text == "true"
        return wrap(:FALSE, children: [], source: node) if text == "false"
        return wrap(:LIT, children: [text.delete_prefix(":").to_sym], source: node) if text.match?(/\A:[A-Za-z_]\w*[!?=]?\z/)
        return wrap(:INTEGER, children: [text.to_i], source: node) if text.match?(/\A-?\d+\z/)
        return wrap(:ZLIST, children: [], source: node) if text == "[]"

        if bare_identifier_text?(text)
          return wrap(:VCALL, children: [text.to_sym], source: node) if ruby? && !ruby_local_name?(text)

          return wrap(:LVAR, children: [text], source: node)
        end

        wrap(kind_type(node.kind), children: [], source: node)
      end

      def normalize_global_variable(node)
        text = node.text.to_s
        return wrap(:NTH_REF, children: [text.delete_prefix("$").to_i], source: node) if text.match?(/\A\$[1-9]\d*\z/)

        wrap(:GVAR, children: [text], source: node)
      end

      def normalize_leading_loop_statement(node)
        keyword = node.children.first.kind
        cond = normalize_node(node.named_children.first)
        body = normalize_body(node.named_children[1])
        wrap(keyword == "until" ? :UNTIL : :WHILE, children: [cond, body], source: node)
      end

      def operator_assignment_statement?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          operator_assignment_statement_parts(node)[1]
      rescue StandardError
        false
      end

      def normalize_operator_assignment_statement(node)
        left, operator, right_raw = operator_assignment_statement_parts(node)
        right = normalize_node(right_raw)

        if left&.kind == "element_reference"
          recv = left.named_children.first
          args = left.named_children.drop(1).map { |child| normalize_node(child) }.compact
          return wrap(:OP_ASGN1, children: [normalize_node(recv), operator, list(args, source: left), right],
                                 source: node)
        end

        if member_read_node?(left)
          recv, mid = member_parts(left)
          return wrap(:OP_ASGN2, children: [normalize_node(recv), false, mid.to_sym, operator, right], source: node)
        end

        logical = normalize_logical_operator_assignment(left, operator, right, source: node)
        return logical if logical
        if instance_variable?(left) || global_variable?(left)
          return assignment_target(left, augmented_assignment_value(left, operator, right_raw, node), source: node)
        end

        assignment_target(left, right, source: node) ||
          wrap(:LASGN, children: [target_name(left), augmented_assignment_value(left, operator, right_raw, node)],
                       source: node)
      end

      def operator_assignment_statement_parts(node)
        left = nil
        operator = nil
        right = nil
        node.children.each do |child|
          if child.named?
            left ||= child
            right = child if operator
          elsif child.text.to_s.match?(/\A(?:[+\-*\/%&|^]|\|\||&&)=\z/)
            raw = child.text.to_s
            operator = raw.sub(/=\z/, "")
            operator = "||" if raw == "||="
            operator = "&&" if raw == "&&="
          end
        end
        return [nil, nil, nil] unless left && operator && right

        [left, operator.to_sym, right]
      end

      def leading_owner_statement?(node)
        %w[body_statement statement].include?(node.kind) &&
          %w[class module].include?(node.children.first&.kind.to_s) &&
          node.named_children.size >= 2 &&
          !OWNER_STATEMENT_NESTED_KIND.include?(node.named_children.first.kind)
      rescue StandardError
        false
      end

      OWNER_STATEMENT_NESTED_KIND = %w[class class_definition class_declaration module].freeze

      def normalize_leading_owner_statement(node)
        keyword = node.children.first.kind
        name = const_for(node.named_children.first)
        body_node = named_field(node, "body") ||
                    node.named_children.reverse.find { |child| BLOCK_KINDS.include?(child.kind) }
        body = normalize_body(body_node)
        if keyword == "module"
          wrap(:MODULE, children: [name, scope(body)], source: node)
        else
          wrap(:CLASS, children: [name, nil, scope(body)], source: node)
        end
      end

      def normalize_leading_if_statement(node)
        keyword = node.children.first.kind
        cond = node.named_children.find { |child| !%w[comment then elsif else].include?(child.kind) }
        consequence = node.named_children.find { |child| child.kind == "then" } ||
                      branch_child(node, cond, 0)
        alternative = explicit_alternative(node)
        type = keyword == "unless" ? :UNLESS : :IF
        wrap(type, children: [normalize_node(cond), normalize_body(consequence), normalize_else_or_branch(alternative)],
                   source: node)
      end

      def modifier_keyword(node)
        seen_named = false
        node.children.each do |child|
          seen_named ||= child.named?
          return child.kind if seen_named && !child.named? && %w[if unless while until].include?(child.kind)
        end
        nil
      rescue StandardError
        nil
      end

      def modifier_parts(node)
        [node.named_children.first, node.named_children.last]
      end

      def call_block(node)
        node.named_children.find { |child| %w[block do_block].include?(child.kind) }
      end

      def statement_call_with_block?(node)
        %w[body_statement block_body statement].include?(node.kind) &&
          call_block(node) &&
          statement_block_call(node)
      end

      def statement_block_call(node)
        return node if dotted_call?(node)

        block = call_block(node)
        node.named_children.find do |child|
          !same_ts_node?(child, block) && (CALL_KINDS.include?(child.kind) || member_read_node?(child))
        end
      end

      def normalize_statement_call_with_block(node)
        block = call_block(node)
        call = normalize_call_without_block(statement_block_call(node), block)
        args = normalize_block_parameters(block)
        body = with_ruby_scope(block) do
          dynamic_scope(normalize_body(named_field(block, "body") || block_child(block) || block))
        end
        wrap(:ITER, children: [call, scope(body, args: args)], source: node)
      end

      def visibility_inline_def_call?(node)
        return false unless node.kind == "call"

        message = node.named_children.first&.text.to_s
        return false unless INLINE_DEF_WRAPPER_MIDS.include?(message)

        args = node.named_children.find { |child| child.kind == "argument_list" }
        args&.text.to_s.lstrip.start_with?("def ")
      end

      def visibility_inline_def_statement?(node, function)
        INLINE_DEF_WRAPPER_MIDS.include?(function&.text.to_s) && node.text.to_s.include?("def ")
      end

      def inline_def_from_argument_list(args)
        return nil unless ts_node?(args)

        inline_def_from_source(args)
      end

      def inline_def_from_statement(node)
        source = node.named_children.find { |child| child.kind == "argument_list" } || node
        inline_def_from_source(source)
      end

      def inline_def_from_source(source)
        body = inline_def_body(source)
        receiver = inline_def_receiver(source)
        normalized_body = with_ruby_scope(source, reset: true) do
          elide_tail_returns(normalize_body(body))
        end
        if receiver
          name = inline_def_name_after_receiver(source, receiver)
          return nil if name.to_s.empty?

          return wrap(:DEFS, children: [normalize_node(receiver), name.to_sym, scope(normalized_body)],
                             source: source)
        end

        name = source.named_children.find { |child| IDENTIFIER_KINDS.include?(child.kind) }&.text.to_s
        return nil if name.to_s.empty?

        wrap(:DEFN, children: [name.to_sym, scope(normalized_body)], source: source)
      end

      def inline_def_receiver(source)
        return nil unless source.text.to_s.match?(/\bdef\s+[^.\s]+\./)

        source.named_children.find { |child| self_node?(child) || const_node?(child) }
      end

      def inline_def_name_after_receiver(source, receiver)
        index = source.named_children.index { |child| same_ts_node?(child, receiver) }
        source.named_children[(index.to_i + 1)..]&.find { |child| IDENTIFIER_KINDS.include?(child.kind) }&.text.to_s
      end

      def inline_def_body(node)
        stack = node.named_children.reverse
        until stack.empty?
          child = stack.shift
          return child if child.kind == "body_statement"

          stack.concat(child.named_children.reverse)
        end
        nil
      end

      def literal_arguments_from_text(args)
        args.text.to_s.scan(/:([A-Za-z_]\w*[!?=]?)/).map do |name|
          wrap(:LIT, children: [name.first.to_sym], source: args)
        end
      end

      def elide_tail_returns(node)
        return node unless ruby?
        return node unless node.is_a?(Node)
        return node if %i[DEFN DEFS CLASS MODULE SCLASS LAMBDA ITER].include?(node.type)
        return node.children.first if node.type == :RETURN

        case node.type
        when :BLOCK
          children = node.children.dup
          children[-1] = elide_tail_returns(children[-1]) if children.any?
          node.children = children
        when :SCOPE
          children = node.children.dup
          children[2] = elide_tail_returns(children[2])
          node.children = children
        when :IF, :UNLESS
          children = node.children.dup
          children[1] = elide_tail_returns(children[1])
          children[2] = elide_tail_returns(children[2]) if children.size > 2
          node.children = children
        when :CASE
          children = node.children.dup
          children[1] = elide_tail_returns(children[1])
          node.children = children
        when :CASE2
          children = node.children.dup
          children[0] = elide_tail_returns(children[0])
          node.children = children
        when :WHEN
          children = node.children.dup
          children[1] = elide_tail_returns(children[1])
          children[2] = elide_tail_returns(children[2]) if children.size > 2
          node.children = children
        when :RESCUE
          children = node.children.dup
          children[0] = elide_tail_returns(children[0])
          children[1] = elide_tail_returns(children[1])
          node.children = children
        when :RESBODY
          children = node.children.dup
          children[1] = elide_tail_returns(children[1])
          children[2] = elide_tail_returns(children[2]) if children.size > 2
          node.children = children
        end

        node
      end

      def elide_implicit_nil_body(node)
        return node unless ruby?
        node = drop_trailing_nil_statement(node)
        return nil if node.is_a?(Node) && node.type == :NIL

        node
      end

      def prepend_inline_parameter_begin(function_node, body)
        marker = inline_parameter_begin_marker(function_node)
        return body unless marker

        children = body.is_a?(Node) && body.type == :BLOCK ? body.children.compact : [body].compact
        return nil if children.empty?

        if body.is_a?(Node) && body.type == :BLOCK
          body.children = [marker] + children
          body
        else
          wrap(:BLOCK, children: [marker] + children, source: function_node)
        end
      end

      def inline_parameter_begin_marker(function_node)
        return nil unless ruby?

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

      def drop_trailing_nil_statement(node)
        return node unless node.is_a?(Node) && node.type == :BLOCK

        children = node.children.compact
        children.pop while children.last.is_a?(Node) && children.last.type == :NIL
        return nil if children.empty?
        return children.first if children.size == 1

        node.children = children
        node
      end

      def scalar_argument_list_value(node)
        text = node.text.to_s.strip
        return wrap(:YIELD, children: [nil], source: node) if ruby? && text == "yield"
        return wrap(:NIL, children: [], source: node) if text == "nil"
        return wrap(:TRUE, children: [], source: node) if text == "true"
        return wrap(:FALSE, children: [], source: node) if text == "false"
        return wrap(:LIT, children: [text.delete_prefix(":").to_sym], source: node) if text.match?(/\A:[A-Za-z_]\w*[!?=]?\z/)
        if text.match?(/\A-?\d+\z/)
          return wrap(:INTEGER, children: [text.to_i], source: node)
        end
        return nil unless bare_identifier_text?(text)

        if ruby? && !ruby_local_name?(text)
          wrap(:VCALL, children: [text.to_sym], source: node)
        else
          wrap(:LVAR, children: [text], source: node)
        end
      end

      def local_or_call_for_name(name, source)
        if ruby? && !ruby_local_name?(name)
          wrap(:VCALL, children: [name.to_sym], source: source)
        else
          wrap(:LVAR, children: [name], source: source)
        end
      end

      def symbol_literal_node?(node)
        node.is_a?(Node) && node.type == :LIT && node.children.first.is_a?(Symbol)
      end

      def command_arguments(args)
        return [scalar_argument_list_value(args)].compact if args.named_children.empty?
        return [normalize_infix_statement(args)] if infix_statement?(args)
        return [normalize_dotted_expression(args)] if dotted_expression?(args)

        args.named_children.map { |child| normalize_node(child) }.compact
      end

      def parent_named_child?(parent, node)
        parent.named_children.any? { |child| same_ts_node?(child, node) }
      end

      def same_ts_node?(left, right)
        left.kind == right.kind && left.start_byte == right.start_byte && left.end_byte == right.end_byte
      rescue StandardError
        false
      end

      def bare_identifier_text?(text)
        text.to_s.strip.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
      end

      def hidden_match?(node)
        node.kind == "expression_statement" &&
          node.text.to_s.lstrip.start_with?("match ") &&
          node.named_children.any? { |child| child.kind == "match_block" }
      end

      def kind_type(kind)
        kind.to_s.upcase.gsub(/[^A-Z0-9]+/, "_").to_sym
      end

      def ts_node?(node)
        node && node.respond_to?(:kind) && node.respond_to?(:named_children)
      end
    end

    # Flatten a && chain (binary-nested OR n-ary, version dependent).
    def flatten_and(node)
      return [node] unless node?(node) && node.type == :AND

      node.children.flat_map { |c| flatten_and(c) }
    end

    # Enclosing def name for a walk; pushes on DEFN/DEFS.
    def def_push(node, stack)
      case node.type
      when :DEFN then stack + [node.children[0].to_s]
      when :DEFS then stack + [node.children[1].to_s]
      else stack
      end
    end

    # Polarity-canonical predicate text: strip a single leading `!`,
    # fold `x == nil`/`x.nil?` style is left as-is (handled by callers).
    # Returns [canonical_text, negated?].
    def canon_polarity(text)
      t = text.strip
      if t.start_with?("!")
        [t[1..].sub(/\A\(/, "").sub(/\)\z/, "").strip, true]
      else
        [t, false]
      end
    end

    # Statements of a method body (BLOCK children, or the single expr).
    def body_stmts(defn_node)
      scope = defn_node.children[defn_node.type == :DEFS ? 2 : 1]
      return [] unless node?(scope) && scope.type == :SCOPE

      body = scope.children[2]
      return [] unless node?(body)

      body.type == :BLOCK ? body.children.compact : [body]
    end
  end
end
