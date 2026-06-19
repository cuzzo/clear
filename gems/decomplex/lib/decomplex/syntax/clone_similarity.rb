# frozen_string_literal: true

require "set"

module Decomplex
  module Syntax
    CloneCandidate = Struct.new(
      :file, :line, :span, :method_name, :node_name, :mass,
      :fingerprint, :raw, :child_fingerprints, :child_masses,
      keyword_init: true
    )

    class Document
      def clone_candidates
        @clone_candidates ||= adapter.clone_candidates(self)
      end
    end

    class TreeSitterAdapter
      def clone_candidates(document)
        syntax_profile(document.language).clone_candidates(document)
      end
    end

    class TreeSitterLanguageAdapter
      CLONE_IDENTIFIER_KINDS = %w[
        identifier constant type_identifier field_identifier property_identifier
        shorthand_property_identifier_pattern simple_identifier variable_name
      ].freeze
      CLONE_LITERAL_KINDS = %w[
        string string_content string_literal interpreted_string_literal raw_string_literal
        integer float int number rational imaginary character char_literal
        symbol simple_symbol true false nil none null
      ].freeze
      CLONE_SKIP_KINDS = %w[
        comment identifier constant type_identifier field_identifier property_identifier
        parameters formal_parameters parameter_list argument_list arguments
        block_parameters call_suffix function_value_parameters method_parameters value_argument
        scope_resolution
      ].freeze
      CLONE_CANDIDATE_KINDS = %w[
        array assignment assignment_statement block case case_clause class
        class_definition class_declaration compound_statement conjunction_expression control_structure_body
        do_block enum_declaration for for_statement function_body hash if if_statement match_expression
        match_statement method method_definition module operator_assignment singleton_method statements
        struct_declaration switch_case switch_expression switch_statement
        unless until while while_statement
      ].freeze
      CLONE_BODY_KINDS = %w[
        body block body_statement declaration_list statement_block compound_statement
        function_body statements suite do_block
      ].freeze
      CLONE_CALL_KINDS = %w[
        call call_expression function_call method_call method_invocation invocation_expression
      ].freeze

      def clone_candidates(document)
        out = []
        seen = Set.new

        document.function_defs.each do |fn|
          candidate = clone_candidate_for(document, fn.body, node_name: "defn", function_name: fn.name)
          clone_add_candidate(out, seen, candidate) if candidate
        end

        clone_walk(document.root) do |node|
          next unless clone_candidate_node?(node)

          function = clone_method_span_for(document, line(node))
          clone_add_candidate(out, seen, clone_candidate_for(document, node, function_name: function&.name))
        end

        out
      rescue StandardError
        []
      end

      private

      def clone_add_candidate(out, seen, candidate)
        return unless candidate
        return if clone_typed_struct_schema_text?(candidate.raw)

        key = [candidate.file, candidate.line, candidate.span, candidate.node_name, candidate.fingerprint]
        return if seen.include?(key)

        seen << key
        out << candidate
      end

      def clone_candidate_for(document, node, node_name: nil, function_name: nil)
        fp, mass = clone_fingerprint(node)
        return nil if fp.to_s.empty?

        line_no = line(node)
        method = clone_method_span_for(document, line_no)
        children = clone_fuzzy_children_for(node)
        child_data = children.map { |child| clone_fingerprint(child) }
                             .reject { |child_fp, child_mass| child_fp.to_s.empty? || child_mass.zero? }

        CloneCandidate.new(
          file: document.file,
          line: line_no,
          span: span(node),
          method_name: function_name || method&.name || "(top-level)",
          node_name: node_name || clone_node_name(node),
          mass: mass,
          fingerprint: fp,
          raw: normalize_text(node.text),
          child_fingerprints: child_data.map(&:first),
          child_masses: child_data.map(&:last)
        )
      end

      def clone_candidate_node?(node)
        return false unless ts_node?(node)
        return false unless node.named?
        return false if CLONE_SKIP_KINDS.include?(node.kind)
        return false unless CLONE_CANDIDATE_KINDS.include?(node.kind)
        return false if clone_typed_struct_schema_text?(node.text)

        node.named_child_count.positive?
      end

      def clone_fuzzy_children_for(node)
        body = clone_body_node(node)
        source = body || node
        children = source.named_children
        children = node.named_children if children.empty?
        children.reject { |child| CLONE_SKIP_KINDS.include?(child.kind) || clone_typed_struct_schema_text?(child.text) }
      end

      def clone_body_node(node)
        named_field(node, "body") ||
          node.named_children.find { |child| CLONE_BODY_KINDS.include?(child.kind) }
      end

      def clone_fingerprint(node, active = nil)
        return ["", 0] unless ts_node?(node)

        active ||= Set.new
        key = node_key(node)
        return ["", 0] if active.include?(key)

        active << key
        begin
          return ["", 0] if node.kind == "comment"
          return clone_fingerprint_call(node, active) if CLONE_CALL_KINDS.include?(node.kind) && clone_call_message(node)

          if node.child_count.zero?
            token = clone_terminal_token(node)
            return ["", 0] if token.empty?

            return [token, 1]
          end

          child_parts = []
          mass = 1
          node.children.each do |child|
            child_fp, child_mass = clone_fingerprint(child, active)
            next if child_fp.empty?

            child_parts << child_fp
            mass += child_mass
          end

          return [clone_terminal_token(node), 1] if child_parts.empty?

          ["#{node.kind}(#{child_parts.join(' ')})", mass]
        ensure
          active.delete(key)
        end
      end

      def clone_fingerprint_call(node, active)
        message = clone_call_message(node)
        child_parts = []
        mass = 1
        node.children.each do |child|
          child_fp, child_mass = clone_fingerprint(child, active)
          next if child_fp.empty?

          child_parts << child_fp
          mass += child_mass
        end
        ["#{node.kind}<#{message}>(#{child_parts.join(' ')})", mass]
      end

      def clone_call_message(node)
        return nil unless node.children.any? { |child| %w[argument_list arguments call_suffix].include?(child.kind) }

        callee = named_field(node, "function") || named_field(node, "callee")
        return clone_callee_message(callee) if callee

        argument_node = node.children.find { |child| %w[argument_list arguments call_suffix].include?(child.kind) }
        named_before_args = node.named_children.select do |child|
          argument_node.nil? || child.start_byte < argument_node.start_byte
        end
        clone_callee_message(named_before_args.last)
      end

      def clone_callee_message(node)
        return nil unless ts_node?(node)
        return node.text if CLONE_IDENTIFIER_KINDS.include?(node.kind)
        return clone_navigation_suffix_message(node) if %w[navigation_expression directly_assignable_expression].include?(node.kind)

        leaf = node.named_children.reverse.find { |child| CLONE_IDENTIFIER_KINDS.include?(child.kind) }
        leaf&.text
      end

      def clone_navigation_suffix_message(node)
        suffix = node.named_children.reverse.find { |child| child.kind == "navigation_suffix" }
        leaf = suffix&.named_children&.reverse&.find { |child| CLONE_IDENTIFIER_KINDS.include?(child.kind) }
        leaf&.text
      end

      def clone_terminal_token(node)
        kind = node.kind.to_s
        return "id" if CLONE_IDENTIFIER_KINDS.include?(kind)
        return clone_literal_token(kind) if CLONE_LITERAL_KINDS.include?(kind)

        text = normalize_text(node.text)
        return "" if text.empty?
        return "id" if text.match?(/\A[A-Za-z_]\w*[!?=]?\z/)
        return "lit" if text.match?(/\A(?::[A-Za-z_]\w*|[-+]?\d+(?:\.\d+)?|".*"|'.*')\z/)

        "#{kind}:#{text}"
      end

      def clone_literal_token(kind)
        case kind
        when "true", "false" then "bool"
        when "nil", "none", "null" then "nil"
        else "lit"
        end
      end

      def clone_node_name(node)
        return "defn" if %w[method function_definition function_declaration method_definition function_item].include?(node.kind)
        return "defs" if node.kind == "singleton_method"

        node.kind
      end

      def clone_typed_struct_schema_text?(text)
        text.to_s.match?(/<\s*T::Struct\b/) ||
          text.to_s.lines.all? { |line| line.strip.empty? || line.match?(/\A\s*(?:const|prop)\s+:[A-Za-z_]\w*\b/) }
      end

      def clone_method_span_for(document, line_no)
        document.function_defs.find { |fn| fn.span[0] <= line_no && line_no <= fn.span[2] }
      rescue StandardError
        nil
      end

      def clone_walk(node, &block)
        return unless ts_node?(node)

        pending = [node]
        seen = Set.new
        until pending.empty?
          current = pending.pop
          next unless ts_node?(current)

          key = node_key(current)
          next if seen.include?(key)

          seen << key
          yield current
          current.children.reverse_each { |child| pending << child }
        end
      end
    end
  end
end
