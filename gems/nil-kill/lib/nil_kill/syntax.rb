# typed: false
# frozen_string_literal: true

sibling_syntax = File.expand_path("../../../decomplex/lib/decomplex/syntax", __dir__)
if File.file?("#{sibling_syntax}.rb")
  require sibling_syntax
else
  require "decomplex/syntax"
end
require "set"

module NilKill
  # Tree-sitter-backed Ruby syntax facade for Nil-Kill's existing Ruby
  # static analysis. The facade intentionally exposes only the parser-shaped
  # API Nil-Kill consumes, so the rest of the pipeline can share the same
  # parser boundary used by Python/Zig static evidence.
  module Syntax
    VERSION = "tree-sitter"

    module_function

    def parse(source, path: nil)
      Parser.new(source, path: path).parse
    end

    def parse_file(path)
      parse(File.read(path), path: path)
    end

    class ParseResult
      attr_reader :value, :errors

      def initialize(value, errors = [])
        @value = value
        @errors = errors
      end

      def success?
        @errors.empty? && !tree_error?(@value)
      end

      private

      def tree_error?(node)
        return false unless node.respond_to?(:raw)

        node.raw.respond_to?(:has_error?) && node.raw.has_error?
      end
    end

    class Parser
      def initialize(source, path: nil)
        @source = source.to_s
        @path = path
      end

      def parse
        parser = Decomplex::Syntax::TreeSitterAdapter.new.send(:parser_for, :ruby)
        tree = parser.parse(@source)
        context = Context.new(@source, tree.root_node, @path)
        ParseResult.new(context.wrap(tree.root_node), [])
      rescue StandardError => e
        ParseResult.new(nil, [e])
      end
    end

    Location = Struct.new(:start_line, :start_column, :end_line, :end_column,
                          :start_offset, :end_offset, keyword_init: true) do
      def length
        end_offset.to_i - start_offset.to_i
      end
    end

    class Context
      EMPTY_SET = Set.new.freeze

      attr_reader :source, :root, :path

      def initialize(source, root, path)
        @source = source
        @root = root
        @path = path
        @cache = {}
        @node_class_cache = {}
        @children_cache = {}
        @named_children_cache = {}
        @named_field_cache = {}
        @locals_by_scope = {}
        @scope_parent = {}
        @scope_for_node = {}
        @effective_locals_by_scope = {}
        scan_scopes(root, [])
        build_effective_locals!
      end

      def wrap(raw, force: nil)
        return nil unless raw
        return nil if raw.respond_to?(:named?) && !raw.named? && force.nil?

        klass = force || cached_node_class(raw)
        return nil unless klass

        key = [raw.start_byte, raw.end_byte, raw.kind, klass.name]
        @cache[key] ||= klass.new(self, raw)
      end

      def location(raw)
        Location.new(
          start_line: raw.start_point.row + 1,
          start_column: raw.start_point.column,
          end_line: raw.end_point.row + 1,
          end_column: raw.end_point.column,
          start_offset: raw.start_byte,
          end_offset: raw.end_byte
        )
      end

      def slice(raw)
        @source.byteslice(raw.start_byte...raw.end_byte).to_s
      end

      def named_field(raw, name)
        key = [scope_key(raw), name]
        return @named_field_cache[key] if @named_field_cache.key?(key)

        @named_field_cache[key] = raw.child_by_field_name(name)
      rescue StandardError
        nil
      end

      def children(raw)
        key = scope_key(raw)
        return @children_cache[key] if @children_cache.key?(key)

        @children_cache[key] = Array(raw.children)
      end

      def named_children(raw)
        key = scope_key(raw)
        return @named_children_cache[key] if @named_children_cache.key?(key)

        @named_children_cache[key] = Array(raw.named_children)
      end

      def child_token(raw, text)
        children(raw).find { |child| !child.named? && child.text.to_s == text }
      end

      def first_child_kind(raw, kind)
        children(raw).find { |child| child.kind == kind }
      end

      def previous_named(raw)
        node = raw.prev_sibling
        node = node.prev_sibling while node && !node.named?
        node
      rescue StandardError
        nil
      end

      def next_named(raw)
        node = raw.next_sibling
        node = node.next_sibling while node && !node.named?
        node
      rescue StandardError
        nil
      end

      def local_name?(raw)
        name = raw.text.to_s
        scope_locals_for(raw).include?(name)
      end

      def scope_locals_for(raw)
        scope = @scope_for_node[scope_key(raw)]
        scope ? @effective_locals_by_scope.fetch(scope, EMPTY_SET) : EMPTY_SET
      end

      private

      def cached_node_class(raw)
        key = scope_key(raw)
        return @node_class_cache[key] if @node_class_cache.key?(key)

        @node_class_cache[key] = node_class(raw)
      end

      def node_class(raw)
        return nil if raw.kind == "comment"

        case raw.kind
        when "program" then ProgramNode
        when "body_statement" then body_statement_class(raw)
        when "block_body", "then" then StatementsNode
        when "class" then ClassNode
        when "module" then ModuleNode
        when "singleton_class" then SingletonClassNode
        when "method", "singleton_method" then DefNode
        when "method_parameters" then ParametersNode
        when "block_parameters" then BlockParametersNode
        when "block", "do_block" then BlockNode
        when "assignment", "operator_assignment" then assignment_class(raw)
        when "call" then hidden_method_definition?(raw) ? DefNode : CallNode
        when "element_reference" then CallNode
        when "binary" then binary_class(raw)
        when "unary" then CallNode
        when "array" then ArrayNode
        when "hash" then HashNode
        when "pair" then AssocNode
        when "argument_list" then ArgumentsNode
        when "string" then string_class(raw)
        when "simple_symbol", "hash_key_symbol", "symbol" then SymbolNode
        when "integer" then IntegerNode
        when "float" then FloatNode
        when "true" then TrueNode
        when "false" then FalseNode
        when "nil" then NilNode
        when "range" then RangeNode
        when "return" then ReturnNode
        when "yield" then YieldNode
        when "if" then IfNode
        when "unless" then UnlessNode
        when "while" then WhileNode
        when "until" then UntilNode
        when "case" then CaseNode
        when "when" then WhenNode
        when "else" then ElseNode
        when "begin" then BeginNode
        when "rescue" then RescueNode
        when "ensure" then EnsureNode
        when "rescue_modifier" then RescueModifierNode
        when "parenthesized_statements", "parenthesized_expression" then ParenthesesNode
        when "lambda" then LambdaNode
        when "self" then SelfNode
        when "constant" then ConstantReadNode
        when "scope_resolution" then ConstantPathNode
        when "instance_variable" then InstanceVariableReadNode
        when "class_variable" then ClassVariableReadNode
        when "global_variable" then GlobalVariableReadNode
        when "identifier" then identifier_class(raw)
        else Node
        end
      end

      def identifier_class(raw)
        parent = raw.parent
        if parent && named_field(parent, "name") == raw && !%w[body_statement block_body then].include?(parent.kind)
          return Node
        end
        return SourceLineNode if raw.text.to_s == "__LINE__"
        return CallNode unless local_name?(raw)

        LocalVariableReadNode
      end

      def string_class(raw)
        named_children(raw).any? { |child| child.kind == "interpolation" } ? InterpolatedStringNode : StringNode
      end

      def assignment_class(raw)
        lhs = named_field(raw, "left") || named_children(raw).first
        if lhs&.kind == "element_reference"
          return IndexOrWriteNode if raw.kind == "operator_assignment" && children(raw).any? { |child| child.text.to_s == "||=" }
          return IndexAndWriteNode if raw.kind == "operator_assignment" && children(raw).any? { |child| child.text.to_s == "&&=" }
          return IndexOperatorWriteNode if raw.kind == "operator_assignment"

          return CallNode
        end

        case lhs&.kind
        when "call" then HiddenSetterCallNode
        when "identifier" then LocalVariableWriteNode
        when "instance_variable" then InstanceVariableWriteNode
        when "class_variable" then ClassVariableWriteNode
        when "global_variable" then GlobalVariableWriteNode
        when "constant" then ConstantWriteNode
        when "scope_resolution" then ConstantPathWriteNode
        else Node
        end
      end

      def binary_class(raw)
        op = children(raw).find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s
        %w[|| or].include?(op) ? OrNode : CallNode
      end

      def body_statement_class(raw)
        return DefNode if method_body_statement?(raw)
        return SingletonClassNode if singleton_class_body_statement?(raw)
        return ClassNode if class_body_statement?(raw)
        return ModuleNode if module_body_statement?(raw)
        return ReturnNode if return_body_statement?(raw)
        return control_body_statement_class(raw) if control_body_statement?(raw)

        StatementsNode
      end

      def method_body_statement?(raw)
        return false unless raw.kind == "body_statement"
        return true if children(raw).first&.kind == "def"

        modifier_def_container(raw)
      end

      def modifier_def_container(raw)
        return nil unless %w[body_statement call].include?(raw.kind)

        named_children(raw).find { |child| child.kind == "argument_list" && children(child).first&.kind == "def" }
      end

      def hidden_def_container(raw)
        children(raw).first&.kind == "def" ? raw : modifier_def_container(raw)
      end

      def hidden_method_definition?(raw)
        return true if raw.kind == "body_statement" && children(raw).first&.kind == "def"
        return true if modifier_def_container(raw)

        false
      end

      def return_body_statement?(raw)
        return false unless %w[body_statement block_body then].include?(raw.kind)
        return false unless children(raw).first&.kind == "return"
        return false if %w[block_body then].include?(raw.kind) && named_children(raw).any? { |child| child.kind == "return" }

        true
      end

      def singleton_class_body_statement?(raw)
        raw.kind == "body_statement" &&
          children(raw).first&.kind == "class" &&
          !children(raw).first.named? &&
          children(raw).any? { |child| !child.named? && child.text.to_s == "<<" }
      end

      def class_body_statement?(raw)
        raw.kind == "body_statement" &&
          children(raw).first&.kind == "class" &&
          !children(raw).first.named? &&
          !singleton_class_body_statement?(raw)
      end

      def module_body_statement?(raw)
        raw.kind == "body_statement" && children(raw).first&.kind == "module" && !children(raw).first.named?
      end

      def control_body_statement?(raw)
        !!control_body_statement_class(raw)
      end

      def control_body_statement_class(raw)
        return nil unless raw.kind == "body_statement"
        return nil if wrapped_control_statement_list?(raw)

        case children(raw).first&.kind
        when "if" then IfNode
        when "unless" then UnlessNode
        when "while" then WhileNode
        when "until" then UntilNode
        when "case" then CaseNode
        when "begin" then BeginNode
        else nil
        end
      end

      def wrapped_control_statement_list?(raw)
        return false unless raw.kind == "body_statement"
        return false unless %w[if unless while until case begin].include?(children(raw).first&.kind)

        first_named = named_children(raw).first
        %w[body_statement if unless while until case begin].include?(first_named&.kind) && named_children(raw).size > 1
      end

      def scan_scopes(raw, scope_stack)
        return unless raw

        entered_scope = false
        if scope_boundary?(raw)
          key = scope_key(raw)
          @locals_by_scope[key] = collect_locals(raw)
          @scope_parent[key] = scope_stack.last
          scope_stack.push(key)
          entered_scope = true
        end
        @scope_for_node[scope_key(raw)] = scope_stack.last
        children(raw).each { |child| scan_scopes(child, scope_stack) }
      ensure
        scope_stack.pop if entered_scope
      end

      def scope_boundary?(raw)
        %w[program method singleton_method block do_block lambda].include?(raw.kind) || hidden_method_definition?(raw)
      end

      def scope_key(raw)
        [raw.start_byte, raw.end_byte, raw.kind]
      end

      def collect_locals(scope)
        locals = Set.new
        collect_param_names(scope, locals)
        walk = lambda do |node|
          return if node != scope && %w[method singleton_method class module singleton_class lambda].include?(node.kind)

          if %w[assignment operator_assignment].include?(node.kind)
            lhs = named_field(node, "left") || named_children(node).first
            locals << lhs.text.to_s if lhs&.kind == "identifier"
          elsif node.kind == "rescue"
            variable = named_field(node, "variable")
            named_children(variable).each { |child| locals << child.text.to_s if child.kind == "identifier" } if variable
          end
          children(node).each { |child| walk.call(child) }
        end
        walk.call(scope)
        locals
      end

      def collect_param_names(scope, locals)
        params =
          if %w[method singleton_method].include?(scope.kind)
            named_field(scope, "parameters")
          elsif hidden_method_definition?(scope)
            container = hidden_def_container(scope)
            container && named_children(container).find { |child| child.kind == "method_parameters" }
          elsif %w[block do_block].include?(scope.kind)
            named_field(scope, "parameters")
        end
        return unless params

        named_children(params).each do |param|
          name = named_field(param, "name") ||
                 named_children(param).find { |child| child.kind == "identifier" } ||
                 (param.kind == "identifier" ? param : nil)
          locals << name.text.to_s if name
        end
      end

      def build_effective_locals!
        @locals_by_scope.each_key { |scope| effective_locals_for(scope, Set.new) }
      end

      def effective_locals_for(scope, seen)
        return @effective_locals_by_scope[scope] if @effective_locals_by_scope.key?(scope)
        return EMPTY_SET if scope.nil? || seen.include?(scope)

        seen.add(scope)
        parent = @scope_parent[scope]
        locals = parent ? effective_locals_for(parent, seen).dup : Set.new
        locals.merge(@locals_by_scope.fetch(scope, EMPTY_SET))
        @effective_locals_by_scope[scope] = locals.freeze
      end
    end

    class Node
      attr_reader :context, :raw

      def initialize(context, raw)
        @context = context
        @raw = raw
      end

      def location
        @location ||= context.location(raw)
      end

      def slice
        context.slice(raw)
      end

      def child_nodes
        context.named_children(raw).filter_map { |child| context.wrap(child) }
      end

      def compact_child_nodes
        child_nodes.compact
      end

      def full_name
        slice
      end

      private

      def children(node = raw)
        return [] unless node

        context.children(node)
      end

      def named_children(node = raw)
        return [] unless node

        context.named_children(node)
      end

      def statement_node(node)
        return nil unless node
        if %w[body_statement block_body then].include?(node.kind)
          context.wrap(node, force: StatementsNode)
        else
          StatementsNode.synthetic(context, node, [context.wrap(node)].compact)
        end
      end
    end

    class ProgramNode < Node
      def statements
        if children.first&.text.to_s == "{" && children.last&.text.to_s == "}"
          return @statements ||= StatementsNode.synthetic(context, raw, [context.wrap(raw, force: HiddenHashNode)].compact)
        end
        if children.first&.text.to_s == "[" && children.last&.text.to_s == "]"
          return @statements ||= StatementsNode.synthetic(context, raw, [context.wrap(raw, force: HiddenArrayNode)].compact)
        end

        @statements ||= StatementsNode.synthetic(
          context,
          raw,
          context.named_children(raw).filter_map { |child| context.wrap(child) }
        )
      end

      def child_nodes
        [statements]
      end
    end

    class SyntheticNode < Node
      def initialize(context, raw, children)
        super(context, raw)
        @children = children
      end

      def child_nodes
        @children
      end

      def compact_child_nodes
        @children.compact
      end
    end

    class StatementsNode < SyntheticNode
      def self.synthetic(context, raw, children)
        new(context, raw, children)
      end

      def initialize(context, raw, children = nil)
        super(context, raw, children || [])
        @children = statement_children(context, raw) unless children
      end

      def body
        child_nodes
      end

      private

      def statement_children(context, raw)
        if hidden_def_statement?(raw)
          return [context.wrap(raw, force: DefNode)].compact
        end

        if return_body_statement?(raw)
          return [context.wrap(raw, force: ReturnNode)].compact
        end

        if control_body_statement?(raw)
          return [context.wrap(raw, force: control_body_statement_class(raw))].compact
        end

        if expression_container?(raw) && expression_body_statement?(raw)
          if simple_child_expression?(raw)
            return [context.wrap(named_children(raw).first)].compact
          end

          return [context.wrap(raw, force: expression_class(context, raw))].compact
        end

        context.named_children(raw).filter_map { |child| context.wrap(child) }
      end

      def expression_container?(raw)
        %w[body_statement block_body then].include?(raw.kind)
      end

      def hidden_def_statement?(raw)
        raw.kind == "body_statement" && (children(raw).first&.kind == "def" ||
          named_children(raw).any? { |child| child.kind == "argument_list" && children(child).first&.kind == "def" })
      end

      def return_body_statement?(raw)
        return false unless %w[body_statement block_body then].include?(raw.kind)
        return false unless children(raw).first&.kind == "return"
        return false if %w[block_body then].include?(raw.kind) && named_children(raw).any? { |child| child.kind == "return" }

        true
      end

      def control_body_statement?(raw)
        raw.kind == "body_statement" &&
          %w[if unless while until case begin].include?(children(raw).first&.kind) &&
          !wrapped_control_statement_list?(raw)
      end

      def control_body_statement_class(raw)
        case children(raw).first&.kind
        when "if" then IfNode
        when "unless" then UnlessNode
        when "while" then WhileNode
        when "until" then UntilNode
        when "case" then CaseNode
        when "begin" then BeginNode
        end
      end

      def wrapped_control_statement_list?(raw)
        first_named = named_children(raw).first
        %w[body_statement if unless while until case begin].include?(first_named&.kind) && named_children(raw).size > 1
      end

      def expression_body_statement?(raw)
        first = children(raw).first
        return false if first && %w[def class module if unless while until case begin rescue ensure].include?(first.kind)
        return false if named_children(raw).any? { |child| %w[method singleton_method class module].include?(child.kind) }
        return false if top_level_statement_list?(raw)

        true
      end

      def top_level_statement_list?(raw)
        return false unless %w[body_statement block_body then].include?(raw.kind)
        return false if named_children(raw).size <= 1
        return false if direct_token?(raw, ".") || direct_token?(raw, "&.")
        return false if direct_token?(raw, "[") || direct_token?(raw, "]")
        return false if children(raw).first&.text.to_s == "["
        return false if children(raw).first&.text.to_s == "{"
        return false if direct_token?(raw, "=")
        return false if direct_token?(raw, "rescue")
        return false if direct_token?(raw, "?") && direct_token?(raw, ":")
        return false if children(raw).any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\.\.\.?|\+|-|\*|\/|%|\|\||&&|or|and)\z/) }
        return false if named_children(raw).any? { |child| %w[argument_list block do_block].include?(child.kind) }

        true
      end

      def simple_child_expression?(raw)
        named_children(raw).size == 1 &&
          !children(raw).any? { |child| !child.named? && %w[. &. [ ] " ' ! not].include?(child.text.to_s) } &&
          !children(raw).any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\.\.\.?|\+|-|\*|\/|%|\|\||&&|or|and)\z/) }
      end

      def expression_class(parse_context, raw)
        texts = children(raw).map { |child| child.text.to_s }
        return HiddenArrayNode if children(raw).first&.text.to_s == "[" && texts.include?("]")
        return HiddenHashNode if children(raw).first&.text.to_s == "{" && texts.include?("}")
        if (assignment_class = hidden_assignment_class(raw))
          return assignment_class
        end
        return RescueModifierNode if texts.include?("rescue")
        return HiddenUnaryNode if %w[! not].include?(children(raw).first&.text.to_s)
        return HiddenElementReferenceNode if texts.include?("[") && texts.include?("]")
        if (texts & %w[|| or]).any?
          return HiddenOrNode
        end
        return RangeNode if (texts & %w[.. ...]).any?
        return HiddenBinaryNode if children(raw).any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\+|-|\*|\/|%)\z/) }
        return HiddenCallNode if texts.include?(".") || children(raw).any? { |child| %w[argument_list block do_block].include?(child.kind) }
        return StringNode if texts.first == "\"" || texts.first == "'"
        return SymbolNode if raw.text.to_s.start_with?(":")
        return IntegerNode if raw.text.to_s.match?(/\A\s*-?\d+\s*\z/)
        return FloatNode if raw.text.to_s.match?(/\A\s*-?\d+\.\d+\s*\z/)
        return TrueNode if raw.text.to_s.strip == "true"
        return FalseNode if raw.text.to_s.strip == "false"
        return NilNode if raw.text.to_s.strip == "nil"
        if identifier_like_text?(raw.text.to_s.strip)
          return parse_context.local_name?(raw) ? LocalVariableReadNode : CallNode
        end

        child = named_children(raw).first
        return ConstantReadNode if child&.kind == "constant"
        return InstanceVariableReadNode if child&.kind == "instance_variable"
        return ClassVariableReadNode if child&.kind == "class_variable"
        return GlobalVariableReadNode if child&.kind == "global_variable"
        if named_children(raw).empty?
          text = raw.text.to_s.strip
          return ClassVariableReadNode if text.start_with?("@@")
          return InstanceVariableReadNode if text.start_with?("@")
          return GlobalVariableReadNode if text.start_with?("$")
        end

        Node
      end

      def direct_token?(raw, text)
        children(raw).any? { |child| !child.named? && child.text.to_s == text }
      end

      def hidden_assignment_class(raw)
        return false unless direct_token?(raw, "=")
        return false if children(raw).any? { |child| !child.named? && %w[== != <= >= ===].include?(child.text.to_s) }

        lhs = named_children(raw).first
        case lhs&.kind
        when "call", "element_reference" then HiddenSetterCallNode
        when "identifier" then LocalVariableWriteNode
        when "instance_variable" then InstanceVariableWriteNode
        when "class_variable" then ClassVariableWriteNode
        when "global_variable" then GlobalVariableWriteNode
        when "constant" then ConstantWriteNode
        when "scope_resolution" then ConstantPathWriteNode
        end
      end

      def identifier_like_text?(text)
        text.match?(/\A[a-z_]\w*[!?=]?\z/)
      end
    end

    class ClassNode < Node
      def constant_path
        context.wrap(context.named_field(raw, "name") || named_children.first, force: ConstantReadNode)
      end

      def body
        body_raw = context.named_field(raw, "body") ||
                   (raw.kind == "body_statement" ? named_children.find { |child| child.kind == "body_statement" } : nil)
        return nil unless body_raw
        if hidden_class_or_module_statement?(body_raw) || hidden_singleton_class_statement?(body_raw)
          return StatementsNode.synthetic(context, body_raw, [context.wrap(body_raw)].compact)
        end

        context.wrap(body_raw, force: StatementsNode)
      end

      def child_nodes
        [constant_path, body].compact
      end

      private

      def hidden_class_or_module_statement?(node)
        node.kind == "body_statement" &&
          %w[class module].include?(children(node).first&.kind) &&
          !children(node).first.named? &&
          !children(node).any? { |child| !child.named? && child.text.to_s == "<<" }
      end

      def hidden_singleton_class_statement?(node)
        node.kind == "body_statement" &&
          children(node).first&.kind == "class" &&
          !children(node).first.named? &&
          children(node).any? { |child| !child.named? && child.text.to_s == "<<" }
      end
    end

    class ModuleNode < ClassNode; end

    class SingletonClassNode < Node
      def expression
        context.wrap(context.named_field(raw, "value") || named_children.first)
      end

      def body
        body_raw = context.named_field(raw, "body") || named_children.last
        body_raw ? context.wrap(body_raw, force: StatementsNode) : nil
      end

      def child_nodes
        [expression, body].compact
      end
    end

    class DefNode < Node
      def name
        if hidden_body_statement_def?
          named_children(hidden_def_container).find { |child| child.kind == "identifier" }&.text.to_s.to_sym
        else
          (context.named_field(raw, "name") || named_children.find { |child| child.kind == "identifier" })&.text.to_s.to_sym
        end
      end

      def receiver
        if hidden_body_statement_def?
          container = hidden_def_container
          dot = children(container).index { |child| !child.named? && child.text.to_s == "." }
          return nil unless dot

          return context.wrap(children(container)[dot - 1]) if dot.positive?
        end

        context.wrap(context.named_field(raw, "object"))
      end

      def parameters
        node = if hidden_body_statement_def?
                 named_children(hidden_def_container).find { |child| child.kind == "method_parameters" }
               else
                 context.named_field(raw, "parameters")
               end
        node ? context.wrap(node, force: ParametersNode) : nil
      end

      def body
        body_raw = if hidden_body_statement_def?
                     named_children(hidden_def_container).reverse.find { |child| child.kind == "body_statement" || !%w[identifier method_parameters self].include?(child.kind) }
                   else
                     context.named_field(raw, "body") || named_children.reverse.find { |child| child.kind != "method_parameters" && child.kind != "identifier" && child.kind != "self" }
                   end
        return nil unless body_raw
        return begin_body(body_raw) if body_raw.kind == "body_statement" && named_children(body_raw).any? { |child| %w[rescue ensure].include?(child.kind) }

        statement_node(body_raw)
      end

      def name_loc
        node = if hidden_body_statement_def?
                 named_children(hidden_def_container).find { |child| child.kind == "identifier" }
               else
                 context.named_field(raw, "name")
               end
        node && context.location(node)
      end

      def rparen_loc
        token = hidden_body_statement_def? ? children(hidden_def_container).find { |child| child.text.to_s == ")" } : children.find { |child| child.text.to_s == ")" }
        token && context.location(token)
      end

      def end_keyword_loc
        token = hidden_body_statement_def? ? children(hidden_def_container).reverse.find { |child| child.text.to_s == "end" } : children.reverse.find { |child| child.text.to_s == "end" }
        token && context.location(token)
      end

      def child_nodes
        [receiver, parameters, body].compact
      end

      private

      def begin_body(body_raw)
        context.wrap(body_raw, force: BeginNode)
      end

      def hidden_body_statement_def?
        %w[body_statement call].include?(raw.kind) && hidden_def_container
      end

      def hidden_def_container
        return raw if children.first&.kind == "def"

        named_children.find { |child| child.kind == "argument_list" && children(child).first&.kind == "def" }
      end
    end

    class ParametersNode < Node
      attr_reader :requireds, :optionals, :keywords, :rest, :keyword_rest, :block

      def initialize(context, raw)
        super
        @requireds = []
        @optionals = []
        @keywords = []
        @rest = nil
        @keyword_rest = nil
        @block = nil
        named_children.each do |child|
          param = ParameterNode.new(context, child)
          case child.kind
          when "optional_parameter"
            @optionals << param
          when "keyword_parameter", "optional_keyword_parameter"
            @keywords << param
          when "splat_parameter"
            @rest = param
          when "hash_splat_parameter"
            @keyword_rest = param
          when "block_parameter"
            @block = param
          when "identifier"
            @requireds << param
          else
            @requireds << param if param.name
          end
        end
      end

      def child_nodes
        requireds + optionals + keywords + [rest, keyword_rest, block].compact
      end
    end

    class BlockParametersNode < Node
      def parameters
        @parameters ||= ParametersNode.new(context, raw)
      end

      def child_nodes
        [parameters]
      end
    end

    class ParameterNode < Node
      def name
        node = context.named_field(raw, "name") ||
               named_children.find { |child| child.kind == "identifier" } ||
               (raw.kind == "identifier" ? raw : nil)
        node&.text&.to_sym
      end

      def value
        node = context.named_field(raw, "value") || named_children.find { |child| child != context.named_field(raw, "name") && child.kind != "identifier" }
        context.wrap(node)
      end
    end

    class BlockNode < Node
      def parameters
        node = context.named_field(raw, "parameters")
        node ? context.wrap(node, force: BlockParametersNode) : nil
      end

      def body
        node = context.named_field(raw, "body") || named_children.reject { |child| child.kind == "block_parameters" }.last
        statement_node(node)
      end

      def child_nodes
        [parameters, body].compact
      end
    end

    class VariableNode < Node
      def name
        slice.to_sym
      end
    end

    class LocalVariableReadNode < VariableNode; end
    class InstanceVariableReadNode < VariableNode; end
    class ClassVariableReadNode < VariableNode; end
    class GlobalVariableReadNode < VariableNode; end

    class ConstantReadNode < VariableNode
      def full_name
        slice
      end
    end

    class ConstantPathNode < ConstantReadNode; end

    class WriteNode < VariableNode
      def target
        context.named_field(raw, "left") || named_children.first
      end

      def name
        target&.text.to_s.to_sym
      end

      def value
        context.wrap(context.named_field(raw, "right") || context.named_field(raw, "value") || named_children[1])
      end

      def child_nodes
        [value].compact
      end
    end

    class LocalVariableWriteNode < WriteNode; end
    class InstanceVariableWriteNode < WriteNode; end
    class ClassVariableWriteNode < WriteNode; end
    class GlobalVariableWriteNode < WriteNode; end
    class ConstantWriteNode < WriteNode; end

    class ConstantPathWriteNode < WriteNode
      def target
        context.named_field(raw, "left") || named_children.first
      end
    end

    class CallNode < Node
      def receiver
        if raw.kind == "element_reference"
          context.wrap(context.named_field(raw, "object") || named_children.first)
        elsif %w[assignment operator_assignment].include?(raw.kind)
          lhs = context.named_field(raw, "left") || named_children.first
          context.wrap(context.named_field(lhs, "object") || (lhs ? named_children(lhs).first : nil))
        elsif raw.kind == "binary"
          context.wrap(named_children.first)
        elsif raw.kind == "unary"
          nil
        elsif raw.kind == "argument_list"
          nil
        elsif raw.kind == "identifier"
          nil
        else
          context.wrap(context.named_field(raw, "receiver") || receiver_before_dot)
        end
      end

      def name
        if raw.kind == "element_reference"
          :[]
        elsif %w[assignment operator_assignment].include?(raw.kind)
          :[]=
        elsif raw.kind == "binary"
          operator_token&.text.to_s.to_sym
        elsif raw.kind == "unary"
          children.find { |child| !child.named? }&.text.to_s.to_sym
        elsif raw.kind == "argument_list"
          text = raw.text.to_s.strip
          return text.to_sym if text.match?(/\A[a-z_]\w*[!?=]?\z/)

          nil
        elsif raw.kind == "identifier"
          raw.text.to_s.to_sym
        else
          node = context.named_field(raw, "method") || method_after_dot || named_children.find { |child| child.kind == "identifier" }
          return node.text.to_s.to_sym if node
          return raw.text.to_s.strip.to_sym if %w[body_statement block_body then].include?(raw.kind) && raw.text.to_s.strip.match?(/\A[a-z_]\w*[!?=]?\z/)

          nil
        end
      end

      def arguments
        args =
          if raw.kind == "element_reference"
            named_children.drop(1)
          elsif %w[assignment operator_assignment].include?(raw.kind)
            lhs = context.named_field(raw, "left") || named_children.first
            lhs_args = lhs ? named_children(lhs).drop(1) : []
            lhs_args + [context.named_field(raw, "right") || named_children[1]].compact
          elsif raw.kind == "binary"
            [named_children[1]].compact
          else
            arg_raw = context.named_field(raw, "arguments")
            arg_raw ||= named_children.find { |child| child.kind == "argument_list" }
            return context.wrap(arg_raw, force: ArgumentsNode) if arg_raw

            []
          end
        ArgumentsNode.synthetic(context, raw, args.filter_map { |child| context.wrap(child) })
      end

      def block
        node = context.named_field(raw, "block") || named_children.find { |child| %w[block do_block].include?(child.kind) }
        context.wrap(node, force: BlockNode)
      end

      def safe_navigation?
        children.any? { |child| child.text.to_s == "&." }
      end

      def child_nodes
        [receiver, arguments, block].compact
      end

      private

      def operator_token
        children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }
      end

      def dot_index
        children.index { |child| !child.named? && %w[. &.].include?(child.text.to_s) }
      end

      def receiver_before_dot
        idx = dot_index
        return nil unless idx

        children[0...idx].reverse.find(&:named?)
      end

      def method_after_dot
        idx = dot_index
        return nil unless idx

        children[(idx + 1)..].to_a.find { |child| child.named? && child.kind == "identifier" }
      end
    end

    class HiddenCallNode < CallNode
      def receiver
        return nil unless dot_index

        context.wrap(named_children.first)
      end

      def name
        if (idx = dot_named_index)
          named_children[idx]&.text.to_s.to_sym
        else
          named_children.first&.text.to_s.to_sym
        end
      end

      def arguments
        if (arg_raw = named_children.find { |child| child.kind == "argument_list" })
          return context.wrap(arg_raw, force: ArgumentsNode)
        end

        start = dot_named_index ? dot_named_index + 1 : 1
        args = named_children[start..].to_a.reject { |child| %w[block do_block].include?(child.kind) }
        ArgumentsNode.synthetic(context, raw, args.filter_map { |child| context.wrap(child) })
      end

      def block
        node = named_children.find { |child| %w[block do_block].include?(child.kind) }
        context.wrap(node, force: BlockNode)
      end

      def safe_navigation?
        children.any? { |child| child.text.to_s == "&." }
      end

      private

      def dot_index
        @dot_index ||= children.index { |child| !child.named? && %w[. &.].include?(child.text.to_s) }
      end

      def dot_named_index
        return nil unless dot_index

        named_children.index { |child| child.start_byte > children[dot_index].start_byte }
      end
    end

    class HiddenUnaryNode < CallNode
      def receiver
        nil
      end

      def name
        children.first&.text.to_s.to_sym
      end

      def arguments
        ArgumentsNode.synthetic(context, raw, named_children.first(1).filter_map { |child| context.wrap(child) })
      end
    end

    class HiddenElementReferenceNode < CallNode
      def receiver
        context.wrap(named_children.first)
      end

      def name
        :[]
      end

      def arguments
        ArgumentsNode.synthetic(context, raw, named_children.drop(1).filter_map { |child| context.wrap(child) })
      end
    end

    class HiddenSetterCallNode < CallNode
      def receiver
        lhs_call&.receiver
      end

      def name
        return :[]= if lhs_element_reference?

        :"#{lhs_call&.name}="
      end

      def arguments
        args =
          if lhs_element_reference?
            lhs = context.wrap(named_children.first, force: HiddenElementReferenceNode)
            (lhs.arguments&.arguments || []) + [context.wrap(named_children[1])].compact
          else
            [context.wrap(named_children[1])].compact
          end
        ArgumentsNode.synthetic(context, raw, args)
      end

      private

      def lhs_element_reference?
        named_children.first&.kind == "element_reference"
      end

      def lhs_call
        @lhs_call ||= context.wrap(named_children.first)
      end
    end

    class HiddenBinaryNode < CallNode
      def receiver
        context.wrap(named_children.first)
      end

      def name
        children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s.to_sym
      end

      def arguments
        ArgumentsNode.synthetic(context, raw, [context.wrap(named_children[1])].compact)
      end
    end

    class ArgumentsNode < SyntheticNode
      def self.synthetic(context, raw, children)
        new(context, raw, children)
      end

      def initialize(context, raw, children = nil)
        super(context, raw, children || [])
        @children = build_arguments(context, raw) unless children
      end

      def arguments
        child_nodes
      end

      private

      def build_arguments(context, raw)
        if quoted_argument_list?(raw)
          klass = named_children(raw).any? { |child| child.kind == "interpolation" } ? InterpolatedStringNode : StringNode
          return [context.wrap(raw, force: klass)].compact
        end
        if (klass = scalar_expression_argument_list_class(context, raw))
          return [context.wrap(raw, force: klass)].compact
        end

        children = context.named_children(raw)
        if children.empty?
          klass = scalar_argument_class(context, raw)
          return [context.wrap(raw, force: klass)].compact if klass
        end
        args = []
        keyword_pairs = []
        children.each do |child|
          if child.kind == "pair"
            keyword_pairs << child
          else
            flush_keywords(context, raw, args, keyword_pairs)
            args << context.wrap(child)
          end
        end
        flush_keywords(context, raw, args, keyword_pairs)
        args.compact
      end

      def flush_keywords(context, raw, args, keyword_pairs)
        return if keyword_pairs.empty?

        args << KeywordHashNode.synthetic(context, raw, keyword_pairs.map { |pair| context.wrap(pair, force: AssocNode) })
        keyword_pairs.clear
      end

      def scalar_argument_class(context, raw)
        text = raw.text.to_s.strip
        return StringNode if text.start_with?("\"", "'") && text.end_with?("\"", "'")
        return SymbolNode if text.start_with?(":")
        return IntegerNode if text.match?(/\A-?\d+\z/)
        return FloatNode if text.match?(/\A-?\d+\.\d+\z/)
        return TrueNode if text == "true"
        return FalseNode if text == "false"
        return NilNode if text == "nil"
        return ClassVariableReadNode if text.start_with?("@@")
        return InstanceVariableReadNode if text.start_with?("@")
        return GlobalVariableReadNode if text.start_with?("$")
        return context.local_name?(raw) ? LocalVariableReadNode : CallNode if text.match?(/\A[a-z_]\w*[!?=]?\z/)
        return ConstantReadNode if text.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)

        nil
      end

      def quoted_argument_list?(raw)
        return false unless raw.kind == "argument_list"

        first = children(raw).first&.text.to_s
        last = children(raw).last&.text.to_s
        %w[" '].include?(first) && first == last
      end

      def scalar_expression_argument_list_class(context, raw)
        return nil unless raw.kind == "argument_list"
        return nil if parenthesized_argument_list?(raw)

        texts = children(raw).map { |child| child.text.to_s }
        first = texts.first
        return HiddenArrayNode if first == "[" && texts.include?("]")
        return HiddenHashNode if first == "{" && texts.include?("}")
        return nil if texts.include?(",")
        return HiddenElementReferenceNode if texts.include?("[") && texts.include?("]")
        return HiddenOrNode if (texts & %w[|| or]).any?
        return RangeNode if (texts & %w[.. ...]).any?
        return HiddenBinaryNode if children(raw).any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\+|-|\*|\/|%)\z/) }
        return HiddenCallNode if texts.include?(".") || named_children(raw).any? { |child| %w[argument_list block do_block].include?(child.kind) }

        scalar_argument_class(context, raw)
      end

      def parenthesized_argument_list?(raw)
        children(raw).first&.text.to_s == "(" && children(raw).last&.text.to_s == ")"
      end
    end

    class ArrayNode < Node
      def elements
        context.named_children(raw).filter_map { |child| context.wrap(child) }
      end

      def child_nodes
        elements
      end
    end

    class HiddenArrayNode < ArrayNode; end

    class HashNode < Node
      def elements
        context.named_children(raw).filter_map { |child| context.wrap(child, force: AssocNode) if child.kind == "pair" }
      end

      def child_nodes
        elements
      end
    end

    class HiddenHashNode < HashNode; end

    class KeywordHashNode < SyntheticNode
      def self.synthetic(context, raw, elements)
        new(context, raw, elements)
      end

      def elements
        child_nodes
      end
    end

    class AssocNode < Node
      def key
        context.wrap(context.named_field(raw, "key") || named_children.first)
      end

      def value
        value_raw = context.named_field(raw, "value") || named_children[1]
        return context.wrap(value_raw) if value_raw

        key_raw = context.named_field(raw, "key") || named_children.first
        if key_raw && context.local_name?(key_raw)
          context.wrap(key_raw, force: LocalVariableReadNode)
        end
      end

      def child_nodes
        [key, value].compact
      end
    end

    class StringNode < Node
      def unescaped
        text = slice
        if text.start_with?("\"", "'") && text.end_with?("\"", "'")
          text[1...-1]
        else
          text
        end
      end
    end

    class InterpolatedStringNode < StringNode; end

    class SymbolNode < Node
      def value
        unescaped.to_sym
      end

      def unescaped
        slice.delete_prefix(":").delete_suffix(":")
      end
    end

    class IntegerNode < Node
      def value
        slice.to_i
      end
    end

    class FloatNode < Node
      def value
        slice.to_f
      end
    end

    class TrueNode < Node; end
    class FalseNode < Node; end
    class NilNode < Node; end
    class RangeNode < Node; end
    class SplatNode < Node; end
    class SelfNode < Node; end
    class SourceLineNode < Node; end
    class YieldNode < Node; end

    class ReturnNode < Node
      def arguments
        args = named_children.flat_map do |child|
          node = context.wrap(child)
          node.is_a?(ArgumentsNode) ? node.arguments : [node].compact
        end
        ArgumentsNode.synthetic(context, raw, args)
      end

      def child_nodes
        [arguments]
      end
    end

    class ParenthesesNode < Node
      def body
        context.wrap(named_children.first)
      end

      def child_nodes
        [body].compact
      end
    end

    class IfNode < Node
      def predicate
        context.wrap(context.named_field(raw, "condition") || named_children.first)
      end

      def statements
        node = context.named_field(raw, "consequence") ||
               named_children.find { |child| child.kind == "then" } ||
               named_children[1]
        statement_node(node)
      end

      def subsequent
        node = context.named_field(raw, "alternative") ||
               named_children.find { |child| %w[else elsif].include?(child.kind) } ||
               named_children[2]
        context.wrap(node)
      end

      def child_nodes
        [predicate, statements, subsequent].compact
      end
    end

    class UnlessNode < Node
      def predicate
        context.wrap(context.named_field(raw, "condition") || named_children.first)
      end

      def statements
        node = context.named_field(raw, "consequence") ||
               named_children.find { |child| child.kind == "then" } ||
               named_children[1]
        statement_node(node)
      end

      def subsequent
        node = context.named_field(raw, "alternative") ||
               named_children.find { |child| %w[else elsif].include?(child.kind) } ||
               named_children[2]
        context.wrap(node)
      end

      def else_clause
        subsequent
      end

      def child_nodes
        [predicate, statements, subsequent].compact
      end
    end

    class WhileNode < Node
      def predicate
        context.wrap(context.named_field(raw, "condition") || named_children.first)
      end

      def statements
        node = context.named_field(raw, "body") ||
               named_children.find { |child| child.kind == "then" } ||
               named_children[1]
        statement_node(node)
      end

      def subsequent
        nil
      end

      def child_nodes
        [predicate, statements].compact
      end
    end

    class UntilNode < WhileNode; end

    class CaseNode < Node
      def predicate
        context.wrap(context.named_field(raw, "value") || named_children.first)
      end

      def conditions
        named_children.select { |child| child.kind == "when" }.filter_map { |child| context.wrap(child, force: WhenNode) }
      end

      def else_clause
        node = named_children.find { |child| child.kind == "else" }
        context.wrap(node, force: ElseNode)
      end

      def child_nodes
        [predicate, *conditions, else_clause].compact
      end
    end

    class WhenNode < Node
      def conditions
        nodes = named_children.take_while { |child| child.kind != "then" }
        nodes.filter_map { |child| context.wrap(child) }
      end

      def statements
        body = context.named_field(raw, "body") || named_children.find { |child| child.kind == "then" }
        statement_node(body)
      end

      def child_nodes
        conditions + [statements].compact
      end
    end

    class ElseNode < Node
      def statements
        node = context.named_children(raw).find { |child| child.kind != "comment" }
        statement_node(node)
      end

      def child_nodes
        [statements].compact
      end
    end

    class BeginNode < Node
      def statements
        body_children = named_children.reject { |child| %w[rescue ensure else].include?(child.kind) }
        StatementsNode.synthetic(context, raw, body_children.filter_map { |child| context.wrap(child) })
      end

      def rescue_clause
        node = named_children.find { |child| child.kind == "rescue" }
        context.wrap(node, force: RescueNode)
      end

      def else_clause
        node = named_children.find { |child| child.kind == "else" }
        context.wrap(node, force: ElseNode)
      end

      def ensure_clause
        node = named_children.find { |child| child.kind == "ensure" }
        context.wrap(node, force: EnsureNode)
      end

      def child_nodes
        [statements, rescue_clause, else_clause, ensure_clause].compact
      end
    end

    class RescueNode < Node
      def exceptions
        node = context.named_field(raw, "exceptions") || named_children.find { |child| child.kind == "exceptions" }
        node ? named_children(node).filter_map { |child| context.wrap(child) } : []
      end

      def statements
        body = context.named_field(raw, "body") || named_children.find { |child| child.kind == "then" }
        statement_node(body)
      end

      def subsequent
        body = context.named_field(raw, "body") || named_children.find { |child| child.kind == "then" }
        return nil unless body

        seen_body = false
        node = named_children.find do |child|
          if seen_body && child.kind == "rescue"
            true
          else
            seen_body ||= same_raw_node?(child, body)
            false
          end
        end
        context.wrap(node, force: RescueNode)
      end

      def child_nodes
        exceptions + [statements, subsequent].compact
      end

      private

      def same_raw_node?(left, right)
        left && right &&
          left.kind == right.kind &&
          left.start_byte == right.start_byte &&
          left.end_byte == right.end_byte
      end
    end

    class EnsureNode < Node
      def statements
        node = context.named_children(raw).first
        statement_node(node)
      end

      def child_nodes
        [statements].compact
      end
    end

    class RescueModifierNode < Node
      def expression
        context.wrap(named_children.first)
      end

      def rescue_expression
        context.wrap(named_children[1])
      end

      def child_nodes
        [expression, rescue_expression].compact
      end
    end

    class LambdaNode < Node; end

    class IndexOperatorWriteNode < CallNode
      def value
        arguments.arguments.last
      end
    end

    class IndexAndWriteNode < IndexOperatorWriteNode; end
    class IndexOrWriteNode < IndexOperatorWriteNode; end

    class OrNode < Node
      def left
        context.wrap(named_children.first)
      end

      def right
        context.wrap(named_children[1])
      end

      def child_nodes
        [left, right].compact
      end
    end

    class HiddenOrNode < OrNode
      def left
        context.wrap(named_children.first)
      end

      def right
        context.wrap(named_children[1])
      end
    end
  end
end
