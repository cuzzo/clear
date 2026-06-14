# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # StructuralTopology is Decomplex's conservative static model of method
  # ownership and direct internal calls over the normalized Tree-sitter AST.
  # It deliberately resolves only same-owner bare/self calls; dynamic dispatch
  # belongs to higher-recall detectors.
  class StructuralTopology
    Method = Struct.new(:id, :owner, :name, :file, :line, :span, :visibility, keyword_init: true)
    Edge = Struct.new(
      :caller, :callee, :caller_name, :callee_name, :file, :line, :span, :type, :kind, :confidence,
      keyword_init: true
    )

    VISIBILITY_MIDS = %i[public protected private].freeze
    OWNER_TYPES = %i[CLASS MODULE].freeze
    METHOD_TYPES = %i[DEFN DEFS].freeze
    SKIP_NESTED_TYPES = %i[CLASS MODULE DEFN DEFS LAMBDA].freeze
    CONDITIONAL_TYPES = %i[IF UNLESS CASE CASE2].freeze
    ITERATION_TYPES = %i[ITER FOR WHILE UNTIL].freeze

    def self.scan(files)
      methods = []
      parsed = files.each_with_object({}) do |file, out|
        out[file] = Ast.parse(file)
      end

      parsed.each do |file, (root, lines)|
        methods.concat(MethodCollector.new(file, lines).scan(root))
      end

      edges = parsed.flat_map do |file, (root, lines)|
        EdgeCollector.new(file, lines, methods).scan(root)
      end

      Graph.new(methods, edges)
    end

    class Graph
      attr_reader :methods, :edges

      def initialize(methods, edges)
        @methods = methods
        @edges = edges
        @method_by_id = methods.to_h { |method| [method.id, method] }
        @methods_by_owner = methods.group_by(&:owner)
        @edges_by_caller = edges.group_by(&:caller)
        @edges_by_callee = edges.group_by(&:callee)
        @edges_by_owner = edges.group_by { |edge| method(edge.caller)&.owner }
      end

      def method(id)
        @method_by_id[id]
      end

      def method_id(owner, name)
        "#{owner}##{name}"
      end

      def method_for(owner, name)
        method(method_id(owner, name))
      end

      def methods_for_owner(owner)
        Array(@methods_by_owner[owner])
      end

      def edges_for_owner(owner)
        Array(@edges_by_owner[owner])
      end

      def internal_calls(id)
        Array(@edges_by_caller[id])
      end

      def internal_callers(id)
        Array(@edges_by_callee[id])
      end

      def single_internal_caller?(id)
        internal_callers(id).map(&:caller).uniq.size == 1
      end

      def visibility(id)
        method(id)&.visibility
      end

      def owner(id)
        method(id)&.owner
      end

      def span(id)
        method(id)&.span
      end

      def call_sites(id)
        internal_calls(id).map do |edge|
          "#{edge.file}:#{edge.caller_name}:#{edge.line}"
        end
      end
    end

    class MethodCollector
      def initialize(file, lines)
        @file = file
        @lines = lines
      end

      def scan(root)
        out = []
        walk(root, [], out)
        out
      end

      private

      def walk(node, owners, out)
        return unless Ast.node?(node)

        if OWNER_TYPES.include?(node.type)
          owner = full_owner_name(owners, node)
          owner_methods(node, owner).each { |method| out << method }
          node.children.each { |child| walk(child, owners + [owner_segment(node)], out) }
        else
          node.children.each { |child| walk(child, owners, out) }
        end
      end

      def owner_methods(owner_node, owner)
        body = owner_body(owner_node)
        return [] unless Ast.node?(body)

        methods = []
        visibility = :public
        owner_statements(body).each do |stmt|
          next unless Ast.node?(stmt)

          if bare_visibility_marker?(stmt)
            visibility = stmt.children[0].to_sym
          elsif visibility_call?(stmt)
            visibility = handle_visibility_call(stmt, owner, visibility, methods)
          elsif METHOD_TYPES.include?(stmt.type)
            methods << method_record(stmt, owner, visibility)
          end
        end
        methods
      end

      def handle_visibility_call(stmt, owner, current_visibility, methods)
        visibility = stmt.children[0].to_sym
        args = stmt.children[1]
        return visibility unless Ast.node?(args)

        each_arg(args) do |arg|
          if METHOD_TYPES.include?(arg.type)
            methods << method_record(arg, owner, visibility)
          elsif (name = literal_method_name(arg))
            method = methods.reverse.find { |row| row.name == name }
            method.visibility = visibility if method
          end
        end

        current_visibility
      end

      def owner_body(owner_node)
        scope = owner_node.children[owner_node.type == :CLASS ? 2 : 1]
        return nil unless Ast.node?(scope) && scope.type == :SCOPE

        scope.children[2]
      end

      def owner_statements(body)
        body.type == :BLOCK ? body.children.compact : [body]
      end

      def bare_visibility_marker?(node)
        node.type == :VCALL && VISIBILITY_MIDS.include?(node.children[0])
      end

      def visibility_call?(node)
        node.type == :FCALL && VISIBILITY_MIDS.include?(node.children[0])
      end

      def each_arg(args)
        args.children.compact.each do |arg|
          yield arg if Ast.node?(arg)
        end
      end

      def literal_method_name(node)
        return node.children[0].to_s if node.type == :LIT && node.children[0].is_a?(Symbol)
        return node.children[0].to_s if %i[STR DSTR].include?(node.type)

        nil
      end

      def method_record(node, owner, visibility)
        name = method_name(node)
        Method.new(
          id: "#{owner}##{name}",
          owner: owner,
          name: name,
          file: @file,
          line: node.first_lineno,
          span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
          visibility: node.type == :DEFS ? :public : visibility
        )
      end

      def method_name(node)
        if node.type == :DEFS
          receiver = node.children[0]
          prefix = Ast.node?(receiver) && receiver.type == :SELF ? "self" : Ast.slice(receiver, @lines)
          "#{prefix}.#{node.children[1]}"
        else
          node.children[0].to_s
        end
      end

      def full_owner_name(owners, node)
        (owners + [owner_segment(node)]).join("::")
      end

      def owner_segment(node)
        text = Ast.slice(node.children[0], @lines)
        text.empty? ? "(anonymous)" : text
      end
    end

    class EdgeCollector
      def initialize(file, lines, methods)
        @file = file
        @lines = lines
        @method_by_id = methods.to_h { |method| [method.id, method] }
      end

      def scan(root)
        out = []
        walk(root, [], out)
        out
      end

      private

      def walk(node, owners, out)
        return unless Ast.node?(node)

        if OWNER_TYPES.include?(node.type)
          owner = (owners + [owner_segment(node)]).join("::")
          owner_methods(node).each do |method_node|
            method = @method_by_id["#{owner}##{method_name(method_node)}"]
            collect_calls(method_node, method, [], out) if method
          end
          node.children.each { |child| walk(child, owners + [owner_segment(node)], out) }
        else
          node.children.each { |child| walk(child, owners, out) }
        end
      end

      def owner_methods(owner_node)
        body = owner_body(owner_node)
        return [] unless Ast.node?(body)

        owner_statements(body).flat_map do |stmt|
          next [] unless Ast.node?(stmt)

          if METHOD_TYPES.include?(stmt.type)
            [stmt]
          elsif visibility_call?(stmt)
            inline_methods(stmt)
          else
            []
          end
        end
      end

      def inline_methods(stmt)
        args = stmt.children[1]
        return [] unless Ast.node?(args)

        args.children.compact.select { |arg| Ast.node?(arg) && METHOD_TYPES.include?(arg.type) }
      end

      def collect_calls(node, caller, context_stack, out)
        return unless Ast.node?(node)
        return if SKIP_NESTED_TYPES.include?(node.type) && !METHOD_TYPES.include?(node.type)

        context_stack = context_stack + [:conditional] if CONDITIONAL_TYPES.include?(node.type)
        context_stack = context_stack + [:iterates] if ITERATION_TYPES.include?(node.type)

        if (edge = internal_edge(node, caller, context_stack))
          out << edge unless edge.caller == edge.callee
        end

        node.children.each { |child| collect_calls(child, caller, context_stack, out) }
      end

      def internal_edge(node, caller, context_stack)
        call = internal_call_name(node, caller)
        return nil unless call

        callee = @method_by_id["#{caller.owner}##{call[:name]}"]
        return nil unless callee

        Edge.new(
          caller: caller.id,
          callee: callee.id,
          caller_name: caller.name,
          callee_name: callee.name,
          file: @file,
          line: node.first_lineno,
          span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
          type: edge_type(context_stack),
          kind: call[:kind],
          confidence: call[:confidence]
        )
      end

      def internal_call_name(node, caller)
        case node.type
        when :FCALL, :VCALL
          { name: scoped_name(caller, node.children[0]), kind: :bare_internal, confidence: :high }
        when :CALL, :OPCALL
          receiver, mid = node.children
          return nil unless Ast.node?(receiver) && receiver.type == :SELF

          { name: scoped_name(caller, mid), kind: :direct_self, confidence: :high }
        end
      end

      def scoped_name(caller, mid)
        caller.name.start_with?("self.") ? "self.#{mid}" : mid.to_s
      end

      def edge_type(context_stack)
        context_stack.last || :always
      end

      def owner_body(owner_node)
        scope = owner_node.children[owner_node.type == :CLASS ? 2 : 1]
        return nil unless Ast.node?(scope) && scope.type == :SCOPE

        scope.children[2]
      end

      def owner_statements(body)
        body.type == :BLOCK ? body.children.compact : [body]
      end

      def visibility_call?(node)
        node.type == :FCALL && VISIBILITY_MIDS.include?(node.children[0])
      end

      def method_name(node)
        if node.type == :DEFS
          receiver = node.children[0]
          prefix = Ast.node?(receiver) && receiver.type == :SELF ? "self" : Ast.slice(receiver, @lines)
          "#{prefix}.#{node.children[1]}"
        else
          node.children[0].to_s
        end
      end

      def owner_segment(node)
        text = Ast.slice(node.children[0], @lines)
        text.empty? ? "(anonymous)" : text
      end
    end
  end
end
