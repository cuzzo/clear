# frozen_string_literal: true

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
        return [TreeSitterNormalizer.new(document).normalize, document.lines]
      end

      src = File.read(file)
      [RubyVM::AbstractSyntaxTree.parse(src, keep_script_lines: true), src.lines]
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
          lines[sl - 1][node.first_column...node.last_column]
        else
          ([lines[sl - 1][node.first_column..]] +
            lines[sl...(el - 1)] +
            [lines[el - 1][0...node.last_column]]).join
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
        method_declaration function_item
      ].freeze
      CLASS_KINDS = %w[class class_definition class_declaration].freeze
      MODULE_KINDS = %w[module].freeze
      BLOCK_KINDS = %w[
        block body_statement statement_block statement_list class_body
        switch_body match_block then
      ].freeze
      IF_KINDS = %w[if if_statement if_modifier unless unless_modifier if_expression].freeze
      LOOP_KINDS = {
        "while" => :WHILE,
        "while_statement" => :WHILE,
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
        string string_literal interpreted_string_literal raw_string_literal
        symbol simple_symbol
      ].freeze
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

      def initialize(document)
        @document = document
      end

      def normalize
        wrap(:ROOT, children: normalize_children(@document.root), source: @document.root)
      end

      private

      def normalize_node(node)
        return nil unless ts_node?(node)
        return nil if node.kind == "comment"
        return normalize_assignment_lhs(node) if assignment_lhs?(node)

        if FUNCTION_KINDS.include?(node.kind)
          normalize_function(node)
        elsif class_node?(node)
          normalize_class(node)
        elsif module_node?(node)
          normalize_module(node)
        elsif node.kind == "impl_item"
          normalize_impl(node)
        elsif IF_KINDS.include?(node.kind)
          normalize_if(node)
        elsif LOOP_KINDS.key?(node.kind)
          normalize_loop(node)
        elsif CASE_KINDS.include?(node.kind) || hidden_match?(node)
          normalize_case(node)
        elsif ASSIGNMENT_KINDS.include?(node.kind)
          normalize_assignment(node)
        elsif boolean_expression?(node)
          normalize_boolean(node)
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
          wrap(RETURN_KINDS.fetch(node.kind), children: normalize_children(node), source: node)
        elsif self_node?(node)
          wrap(:SELF, children: [], source: node)
        elsif instance_variable?(node)
          wrap(:IVAR, children: [node.text.to_s], source: node)
        elsif global_variable?(node)
          wrap(:GVAR, children: [node.text.to_s], source: node)
        elsif const_node?(node)
          normalize_const(node)
        elsif local_identifier?(node)
          wrap(:LVAR, children: [node.text.to_s], source: node)
        elsif NIL_KINDS.include?(node.kind)
          wrap(:NIL, children: [], source: node)
        elsif STRING_KINDS.include?(node.kind)
          wrap(:STR, children: [node.text.to_s], source: node)
        else
          wrap(kind_type(node.kind), children: normalize_children(node), source: node)
        end
      end

      def normalize_function(node)
        name = function_name(node)
        body = normalize_body(named_field(node, "body") || block_child(node))
        wrap(:DEFN, children: [name, scope(body)], source: node)
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
        cond_raw = named_field(node, "condition") || named_field(node, "predicate") || first_named(node)
        cond = normalize_node(cond_raw)
        positive = normalize_body(named_field(node, "consequence") || named_field(node, "body") ||
                                  branch_child(node, cond_raw, 1))
        negative = normalize_body(named_field(node, "alternative") || branch_child(node, cond_raw, 2))
        type = node.kind.start_with?("unless") ? :UNLESS : :IF
        wrap(type, children: [cond, positive, negative], source: node)
      end

      def normalize_loop(node)
        cond = normalize_node(named_field(node, "condition") || first_named(node))
        body = normalize_body(named_field(node, "body") || named_field(node, "consequence") || block_child(node))
        wrap(LOOP_KINDS.fetch(node.kind), children: [cond, body], source: node)
      end

      def normalize_case(node)
        value = normalize_node(case_value(node))
        whens = case_arms(node).map { |arm| normalize_when(arm) }.compact
        wrap(:CASE, children: [value, link_when_chain(whens)], source: node)
      end

      def normalize_when(node)
        patterns = normalize_patterns(node)
        body = normalize_body(when_body(node))
        wrap(:WHEN, children: [list(patterns, source: node), body, nil], source: node)
      end

      def normalize_assignment(node)
        left = assignment_left(node)
        right = normalize_node(assignment_right(node))
        return assignment_target(left, right) if assignment_target(left, right)

        wrap(:LASGN, children: [target_name(left), right], source: node)
      end

      def normalize_boolean(node)
        type = boolean_operator(node) == "or" ? :OR : :AND
        operands = node.named_children.map { |child| normalize_node(child) }.compact
        wrap(type, children: operands, source: node)
      end

      def normalize_comparison(node)
        operands = node.named_children
        left = normalize_node(operands[0])
        right = normalize_node(operands[1])
        wrap(:OPCALL, children: [left, comparison_operator(node).to_sym, list([right], source: operands[1] || node)],
                      source: node)
      end

      def normalize_call(node)
        if named_field(node, "receiver") && named_field(node, "method")
          recv, mid = member_parts(node)
          args = call_arguments(node, nil)
          return wrap(:CALL, children: [normalize_node(recv), mid.to_sym, list(args, source: node)], source: node)
        end

        function = named_field(node, "function") || named_field(node, "call") || node.named_children.first
        args = call_arguments(node, function)

        if member_read_node?(function)
          recv, mid = member_parts(function)
          return wrap(:CALL, children: [normalize_node(recv), mid.to_sym, list(args, source: node)], source: node)
        end

        if function && IDENTIFIER_KINDS.include?(function.kind)
          return wrap(:FCALL, children: [function.text.to_sym, list(args, source: node)], source: node)
        end

        wrap(:CALL, children: [normalize_node(function), :call, list(args, source: node)], source: node)
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
        return wrap(:BLOCK, children: [], source: @document.root) unless ts_node?(node)
        return normalize_node(node) if BLOCK_KINDS.include?(node.kind)

        wrap(:BLOCK, children: normalize_children(node), source: node)
      end

      def normalize_patterns(node)
        pattern =
          named_field(node, "pattern") || named_field(node, "value") ||
          node.named_children.find { |child| !BLOCK_KINDS.include?(child.kind) && !statement_node?(child) }
        return [] unless pattern

        if %w[pattern case_pattern match_pattern expression_list].include?(pattern.kind)
          pattern.named_children.map { |child| normalize_node(child) }.compact
        else
          [normalize_node(pattern)].compact
        end
      end

      def assignment_target(left, right)
        return nil unless ts_node?(left)

        if instance_variable?(left)
          return wrap(:IASGN, children: [left.text.to_s, right], source: left)
        end

        if member_read_node?(left)
          recv, mid = member_parts(left)
          return wrap(:ATTRASGN, children: [normalize_node(recv), "#{mid}=".to_sym, list([right], source: left)],
                               source: left)
        end

        return assignment_target(left.named_children.first, right) if left.kind == "expression_list"

        nil
      end

      def normalize_assignment_lhs(node)
        right = normalize_node(next_named_sibling(node))
        assignment_target(node, right) ||
          wrap(:LASGN, children: [target_name(node), right], source: node)
      end

      def target_name(left)
        return left.text.to_s if ts_node?(left) && IDENTIFIER_KINDS.include?(left.kind)
        return left.text.to_s if ts_node?(left)

        Ast.slice(normalize_node(left), @document.lines)
      end

      def case_value(node)
        named_field(node, "value") || named_field(node, "subject") ||
          named_field(node, "condition") ||
          node.named_children.find { |child| !WHEN_KINDS.include?(child.kind) && !BLOCK_KINDS.include?(child.kind) }
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

      def link_when_chain(whens)
        whens.reverse.inject(nil) do |next_when, current|
          current.children[2] = next_when
          current
        end
      end

      def boolean_expression?(node)
        %w[binary binary_expression boolean_operator].include?(node.kind) &&
          %w[and or].include?(boolean_operator(node))
      end

      def comparison_expression?(node)
        %w[binary binary_expression comparison_operator].include?(node.kind) &&
          COMPARISON_OPERATORS.include?(comparison_operator(node))
      end

      def boolean_operator(node)
        text = spaced_text(node)
        return "and" if text.include?("&&") || text.match?(/\band\b/)
        return "or" if text.include?("||") || text.match?(/\bor\b/)

        nil
      end

      def comparison_operator(node)
        spaced_text(node)[/(===|!==|==|!=|<=|>=|<|>)/, 1]
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
          parenthesized_expression expression_statement statement
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

      def const_node?(node)
        CONST_KINDS.include?(node.kind)
      end

      def self_node?(node)
        %w[self this].include?(node.kind) || node.text == "self" || node.text == "this"
      end

      def instance_variable?(node)
        node.kind == "instance_variable" || node.text.to_s.start_with?("@")
      end

      def global_variable?(node)
        node.kind == "global_variable" || node.text.to_s.start_with?("$")
      end

      def member_read_node?(node)
        ts_node?(node) && MEMBER_KINDS.include?(node.kind) && member_parts(node).all?
      end

      def assignment_lhs?(node)
        return false if prev_sibling(node)&.text == ":"

        sibling = next_sibling(node)
        sibling && assignment_operator?(sibling.text)
      end

      def assignment_rhs?(node)
        sibling = prev_sibling(node)
        sibling && assignment_operator?(sibling.text)
      end

      def assignment_operator?(text)
        %w[= += -= *= /= %= &&= ||=].include?(text.to_s)
      end

      def member_parts(node)
        return [nil, nil] if node.kind == "expression_list" &&
                             !(named_field(node, "operand") && named_field(node, "field"))

        recv = named_field(node, "receiver") || named_field(node, "object") ||
               named_field(node, "operand") || named_field(node, "value") ||
               node.named_children.first
        mid = named_field(node, "method") || named_field(node, "field") ||
              named_field(node, "property") || node.named_children.last
        return [nil, nil] unless recv && mid && recv != mid

        [recv, mid.text.to_s.sub(/=\z/, "")]
      end

      def call_arguments(node, function)
        args = named_field(node, "arguments") || named_field(node, "argument") ||
               node.named_children.find { |child| %w[argument_list arguments].include?(child.kind) }
        return [] unless args

        args.named_children.reject { |child| child == function }.map { |child| normalize_node(child) }.compact
      end

      def assignment_left(node)
        named_field(node, "left") || node.named_children.first
      end

      def assignment_right(node)
        named_field(node, "right") || node.named_children[1]
      end

      def function_name(node)
        name = named_field(node, "name") ||
               node.named_children.find do |child|
                 IDENTIFIER_KINDS.include?(child.kind) || child.kind == "constant"
               end
        name&.text.to_s
      end

      def first_named(node)
        node.named_children.first
      end

      def block_child(node)
        node.named_children.find { |child| BLOCK_KINDS.include?(child.kind) }
      end

      def branch_child(node, cond, index)
        node.named_children.reject { |child| child == cond }[index]
      end

      def const_for(node)
        return wrap(:CONST, children: ["(anonymous)".to_sym], source: @document.root) unless ts_node?(node)
        return normalize_const(node) if const_node?(node)

        wrap(:CONST, children: [node.text.to_s.to_sym], source: node)
      end

      def scope(body)
        wrap(:SCOPE, children: [nil, nil, body], source: body || @document.root)
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

      def named_field(node, name)
        node.child_by_field_name(name)
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
