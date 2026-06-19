# frozen_string_literal: true

module Decomplex
  module Syntax
    RUBY_PROTOCOL_PATH_LIMIT = 64
    RUBY_PROTOCOL_DECLARATIVE_MIDS = %w[
      abstract! alias_method any attr_accessor attr_reader attr_writer bind
      cast checked enum extend final include interface! let must must_because
      nilable override overridable params prepend private private_class_method
      protected public require require_relative requires_ancestor sealed! sig
      type_member type_template untyped unsafe void
    ].freeze
    RUBY_PROTOCOL_TEST_DSL_MIDS = %w[
      a_kind_of after around before be be_a be_an be_empty be_falsey be_nil
      be_truthy change contain_exactly context describe eq eql equal expect
      have_attributes have_key have_received it match not_to raise_error
      receive subject to
    ].freeze
    RUBY_PROTOCOL_IGNORED_MIDS = (RUBY_PROTOCOL_DECLARATIVE_MIDS + RUBY_PROTOCOL_TEST_DSL_MIDS).freeze
    RUBY_PROTOCOL_OPTIONAL_DIAGNOSTIC_MIDS = %w[
      error! fixable! read_interpolated_string warn!
    ].freeze
    RUBY_PROTOCOL_MUTATING_MIDS = %w[
      << []= add append clear collect! compact! concat declare delete delete_if
      each_key= fill filter! keep_if mark merge! move push reject! replace
      resolve shift stamp store unshift update write
    ].freeze
    RUBY_PROTOCOL_NON_MUTATING_OPERATOR_MIDS = %w[! != !~].freeze
    RUBY_PROTOCOL_MUTATING_SUFFIXES = %w[!].freeze

    class RubySyntaxAdapter
      def protocol_method_effects(document)
        document.function_defs.map do |function_def|
          reads = Set.new
          writes = Set.new
          statements = ruby_function_body_statements(function_def.body)
          local_names = ruby_local_names(function_def, statements)
          ruby_protocol_collect_state_access(function_def.body, reads, writes,
                                             local_names: local_names,
                                             root: true)
          ProtocolMethodEffect.new(
            file: function_def.file,
            owner: function_def.owner,
            name: ruby_protocol_method_name(function_def.name),
            line: function_def.line,
            reads: reads.to_a.sort,
            writes: writes.to_a.sort
          )
        end
      end

      def protocol_call_paths(document)
        document.function_defs.flat_map do |function_def|
          statements = ruby_function_body_statements(function_def.body)
          local_names = ruby_local_names(function_def, statements)
          ruby_protocol_paths_for_statements(statements, local_names: local_names).map do |path|
            ProtocolMethodPath.new(
              file: function_def.file,
              owner: function_def.owner,
              name: ruby_protocol_method_name(function_def.name),
              line: function_def.line,
              calls: path.calls
            )
          end
        end
      end

      private

      def ruby_protocol_method_name(name)
        name.to_s.split(".").last
      end

      def ruby_protocol_collect_state_access(node, reads, writes, local_names:, root: false)
        return unless ts_node?(node)
        return if !root && ruby_protocol_nested_boundary?(node)

        case node.kind
        when "assignment"
          lhs = named_field(node, "left") || node.named_children.first
          rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
          ruby_protocol_record_write(lhs, writes, local_names)
          ruby_protocol_collect_state_access(rhs, reads, writes, local_names: local_names)
          return
        when "operator_assignment"
          lhs = named_field(node, "left") || node.named_children.first
          if (state = ruby_protocol_state_target(lhs, local_names))
            reads << state
            writes << state
          end
          rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
          ruby_protocol_collect_state_access(rhs, reads, writes, local_names: local_names)
          return
        when "instance_variable"
          reads << ruby_protocol_normalize_state(node.text)
        when "call"
          ruby_protocol_collect_call_state(node, reads, writes, local_names)
        when "identifier"
          reads << ruby_protocol_normalize_state(node.text) if ruby_protocol_bare_reader?(node, local_names)
        end

        node.named_children.each do |child|
          ruby_protocol_collect_state_access(child, reads, writes, local_names: local_names)
        end
      end

      def ruby_protocol_collect_call_state(node, reads, writes, local_names)
        target = ruby_proc_call_target(node) || ruby_call_target(node)
        return unless target

        mid = target[:message].to_s
        receiver = target[:receiver].to_s
        if receiver == "self" && target[:arguments].to_a.empty? &&
            !ruby_protocol_mutating_mid?(mid) && !RUBY_PROTOCOL_IGNORED_MIDS.include?(mid)
          reads << ruby_protocol_normalize_state(mid)
        end

        return unless ruby_protocol_mutating_mid?(mid)

        token = ruby_protocol_receiver_state_token(receiver, local_names)
        writes << token if token
      end

      def ruby_protocol_record_write(lhs, writes, local_names)
        state = ruby_protocol_state_target(lhs, local_names)
        writes << state if state
      end

      def ruby_protocol_state_target(node, local_names)
        return nil unless ts_node?(node)

        case node.kind
        when "instance_variable"
          ruby_protocol_normalize_state(node.text)
        when "element_reference"
          ruby_protocol_receiver_state_token(node.named_children.first&.text, local_names)
        when "call"
          target = ruby_proc_call_target(node) || ruby_call_target(node)
          return nil unless target

          receiver = ruby_protocol_receiver_state_token(target[:receiver], local_names)
          field = target[:message].to_s.sub(/=\z/, "")
          return ruby_protocol_normalize_state(field) if receiver == "self"
          return "#{receiver}.#{field}" if receiver

          nil
        else
          nil
        end
      end

      def ruby_protocol_receiver_state_token(receiver, local_names)
        text = receiver.to_s
        return nil if text.empty?
        return "self" if text == "self"
        return ruby_protocol_normalize_state(text) if text.start_with?("@")
        return ruby_protocol_normalize_state(text) if text.match?(/\A[a-z_]\w*[!?]?\z/)
        return nil if local_names.include?(text)

        nil
      end

      def ruby_protocol_bare_reader?(node, local_names)
        name = node.text.to_s
        return false unless name.match?(/\A[a-z_]\w*[!?]?\z/)
        return false if local_names.include?(name)
        return false if RUBY_PROTOCOL_IGNORED_MIDS.include?(name)

        parent = parent_node(node)
        return false unless parent
        return false if ruby_declaration_name?(node, parent)
        return false if %w[call method_parameters block_parameters argument_list assignment
                           operator_assignment pair hash_key_symbol].include?(parent.kind)
        return false if next_sibling(node)&.text == "=" || prev_sibling(node)&.text == "="
        return false if next_sibling(node)&.text == "." || prev_sibling(node)&.text == "."
        return false if next_sibling(node)&.text == ":" || prev_sibling(node)&.text == ":"

        true
      end

      def ruby_protocol_paths_for_statements(statements, local_names:)
        statements.compact.each_with_object([ruby_protocol_empty_path]) do |statement, paths|
          statement_paths = ruby_protocol_paths_for(statement, local_names: local_names)
          paths.replace(ruby_protocol_combine_path_lists(paths, statement_paths))
        end
      end

      def ruby_protocol_paths_for(node, local_names:)
        return [ruby_protocol_empty_path] unless ts_node?(node)
        return [ruby_protocol_empty_path] if ruby_protocol_nested_boundary?(node)

        if ruby_path_if_node?(node)
          return ruby_protocol_branch_paths(node, local_names: local_names)
        end
        return ruby_protocol_case_paths(node, local_names: local_names) if ruby_protocol_case_node?(node)

        paths = ruby_protocol_generic_paths(node, local_names: local_names)
        return paths unless %w[return break next redo retry].include?(node.kind)

        paths.map { |path| ProtocolPath.new(calls: path.calls, terminal: true) }
      end

      def ruby_protocol_branch_paths(node, local_names:)
        condition_paths = ruby_protocol_paths_for(ruby_path_condition(node), local_names: local_names)
        then_paths = ruby_protocol_body_paths(ruby_path_then_body(node), local_names: local_names)
        else_node = ruby_path_else_body(node)
        else_paths = else_node ? ruby_protocol_body_paths(else_node, local_names: local_names) : [ruby_protocol_empty_path]
        alternatives = then_paths + else_paths
        ruby_protocol_combine_path_lists(condition_paths, alternatives)
      end

      def ruby_protocol_case_paths(node, local_names:)
        subject = ruby_protocol_case_subject(node)
        subject_paths = subject ? ruby_protocol_paths_for(subject, local_names: local_names) : [ruby_protocol_empty_path]
        branches = ruby_protocol_case_branch_paths(node, local_names: local_names)
        ruby_protocol_combine_path_lists(subject_paths, branches.empty? ? [ruby_protocol_empty_path] : branches)
      end

      def ruby_protocol_case_subject(node)
        first = node.named_children.first
        return nil unless first
        return nil if %w[when else].include?(first.kind)

        first
      end

      def ruby_protocol_case_branch_paths(node, local_names:)
        node.named_children.flat_map do |child|
          case child.kind
          when "when"
            pattern_paths = child.named_children.take_while { |part| part.kind != "then" }
                                 .each_with_object([ruby_protocol_empty_path]) do |pattern, paths|
              paths.replace(ruby_protocol_combine_path_lists(
                              paths,
                              ruby_protocol_paths_for(pattern, local_names: local_names)
                            ))
            end
            body = child.named_children.find { |part| part.kind == "then" }
            ruby_protocol_combine_path_lists(pattern_paths, ruby_protocol_body_paths(body, local_names: local_names))
          when "else"
            ruby_protocol_body_paths(child, local_names: local_names)
          else
            []
          end
        end.first(RUBY_PROTOCOL_PATH_LIMIT)
      end

      def ruby_protocol_body_paths(node, local_names:)
        return [ruby_protocol_empty_path] unless ts_node?(node)

        if %w[then else body_statement block block_body].include?(node.kind)
          return ruby_protocol_paths_for_statements(
            node.named_children.reject { |child| child.kind == "comment" },
            local_names: local_names
          )
        end

        ruby_protocol_paths_for(node, local_names: local_names)
      end

      def ruby_protocol_generic_paths(node, local_names:)
        children = ruby_protocol_child_nodes(node)
        child_paths = children.each_with_object([ruby_protocol_empty_path]) do |child, paths|
          paths.replace(ruby_protocol_combine_path_lists(
                          paths,
                          ruby_protocol_paths_for(child, local_names: local_names)
                        ))
        end

        mid = ruby_protocol_internal_call(node, local_names)
        return child_paths unless mid

        call_path = ProtocolPath.new(calls: [ruby_protocol_raw_call(mid, node)], terminal: false)
        ruby_protocol_combine_path_lists([call_path], child_paths)
      end

      def ruby_protocol_child_nodes(node)
        return [] if ruby_protocol_nested_boundary?(node)

        case node.kind
        when "call"
          node.named_children.select { |child| %w[argument_list block do_block].include?(child.kind) }
        when "assignment", "operator_assignment"
          rhs = named_field(node, "right") || named_field(node, "value") || node.named_children[1]
          rhs ? [rhs] : []
        else
          node.named_children.reject { |child| child.kind == "comment" }
        end
      end

      def ruby_protocol_internal_call(node, local_names)
        target =
          case node.kind
          when "call"
            ruby_proc_call_target(node) || ruby_call_target(node)
          when "identifier"
            ruby_bare_call_target(node)
          end
        return nil unless target
        return nil unless target[:receiver].to_s == "self"

        mid = target[:message].to_s
        return nil if local_names.include?(mid)
        return nil if RUBY_PROTOCOL_IGNORED_MIDS.include?(mid)

        mid
      end

      def ruby_protocol_raw_call(mid, node)
        ProtocolCall.new(
          mid: mid,
          file: nil,
          owner: nil,
          defn: nil,
          line: line(node),
          span: span(node)
        )
      end

      def ruby_protocol_combine_path_lists(left_paths, right_paths)
        left_paths.flat_map do |path|
          if path.terminal
            [path]
          else
            right_paths.map do |right_path|
              ProtocolPath.new(calls: path.calls + right_path.calls, terminal: right_path.terminal)
            end
          end
        end.first(RUBY_PROTOCOL_PATH_LIMIT)
      end

      def ruby_protocol_empty_path
        ProtocolPath.new(calls: [], terminal: false)
      end

      def ruby_protocol_case_node?(node)
        ts_node?(node) && (node.kind == "case" || hidden_case?(node))
      end

      def ruby_protocol_nested_boundary?(node)
        return false unless ts_node?(node)
        return true if %w[class module method singleton_method lambda].include?(node.kind)
        return true if hidden_ruby_method_definition?(node) || hidden_ruby_owner_declaration?(node)

        false
      end

      def ruby_protocol_mutating_mid?(mid)
        return false if RUBY_PROTOCOL_NON_MUTATING_OPERATOR_MIDS.include?(mid)

        RUBY_PROTOCOL_MUTATING_MIDS.include?(mid) ||
          RUBY_PROTOCOL_MUTATING_SUFFIXES.any? { |suffix| mid.end_with?(suffix) }
      end

      def ruby_protocol_normalize_state(name)
        name.to_s.sub(/\A@/, "").sub(/=\z/, "")
      end
    end
  end
end
