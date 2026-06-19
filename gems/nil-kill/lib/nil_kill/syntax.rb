# typed: false
# frozen_string_literal: true

sibling_syntax = File.expand_path("../../../fact-mine/lib/fact_mine/syntax", __dir__)
if File.file?("#{sibling_syntax}.rb")
  require sibling_syntax
else
  require "fact_mine/syntax"
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
        parser = FactMine::Syntax::TreeSitterAdapter.new.send(:parser_for, :ruby)
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
      attr_reader :source, :root, :path

      def initialize(source, root, path)
        @source = source
        @root = root
        @path = path
        @cache = {}
        @children_cache = {}
        @named_children_cache = {}
        @named_field_cache = {}
        @locals_by_scope = {}
        scan_scopes(root)
      end

      def wrap(raw, force: nil)
        return nil unless raw
        return nil if raw.respond_to?(:named?) && !raw.named? && force.nil?

        klass = force || node_class(raw)
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
        key = [raw_key(raw), name.to_s]
        return @named_field_cache[key] if @named_field_cache.key?(key)

        @named_field_cache[key] = raw.child_by_field_name(name)
      rescue StandardError
        nil
      end

      def children(raw)
        key = raw_key(raw)
        @children_cache.fetch(key) do
          @children_cache[key] = Array(raw.children)
        end
      rescue StandardError
        []
      end

      def named_children(raw)
        key = raw_key(raw)
        @named_children_cache.fetch(key) do
          @named_children_cache[key] = Array(raw.named_children)
        end
      rescue StandardError
        []
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

      def raw_key(raw)
        [raw.start_byte, raw.end_byte, raw.kind]
      end

      def scope_locals_for(raw)
        locals = Set.new
        @locals_by_scope.each do |(start_byte, end_byte, _kind), scope_locals|
          locals.merge(scope_locals) if raw.start_byte >= start_byte && raw.end_byte <= end_byte
        end

        node = raw
        seen = Set.new
        while node
          key = scope_key(node)
          break if seen.include?(key)
          seen.add(key)
          locals.merge(@locals_by_scope[key]) if @locals_by_scope.key?(key)
          node = node.parent
        end
        locals
      end

      private

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
        raw.named_children.any? { |child| child.kind == "interpolation" } ? InterpolatedStringNode : StringNode
      end

      def assignment_class(raw)
        lhs = named_field(raw, "left") || raw.named_children.first
        if lhs&.kind == "element_reference"
          return IndexOrWriteNode if raw.kind == "operator_assignment" && raw.children.any? { |child| child.text.to_s == "||=" }
          return IndexAndWriteNode if raw.kind == "operator_assignment" && raw.children.any? { |child| child.text.to_s == "&&=" }
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
        op = raw.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s
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
        return true if raw.children.first&.kind == "def"

        modifier_def_container(raw)
      end

      def modifier_def_container(raw)
        return nil unless %w[body_statement call].include?(raw.kind)

        raw.named_children.find { |child| child.kind == "argument_list" && child.children.first&.kind == "def" }
      end

      def hidden_def_container(raw)
        raw.children.first&.kind == "def" ? raw : modifier_def_container(raw)
      end

      def hidden_method_definition?(raw)
        return true if raw.kind == "body_statement" && raw.children.first&.kind == "def"
        return true if modifier_def_container(raw)

        false
      end

      def return_body_statement?(raw)
        return false unless %w[body_statement block_body then].include?(raw.kind)
        return false unless raw.children.first&.kind == "return"
        return false if %w[block_body then].include?(raw.kind) && raw.named_children.any? { |child| child.kind == "return" }

        true
      end

      def singleton_class_body_statement?(raw)
        raw.kind == "body_statement" &&
          raw.children.first&.kind == "class" &&
          !raw.children.first.named? &&
          raw.children.any? { |child| !child.named? && child.text.to_s == "<<" }
      end

      def class_body_statement?(raw)
        raw.kind == "body_statement" &&
          raw.children.first&.kind == "class" &&
          !raw.children.first.named? &&
          !singleton_class_body_statement?(raw)
      end

      def module_body_statement?(raw)
        raw.kind == "body_statement" && raw.children.first&.kind == "module" && !raw.children.first.named?
      end

      def control_body_statement?(raw)
        !!control_body_statement_class(raw)
      end

      def control_body_statement_class(raw)
        return nil unless raw.kind == "body_statement"
        return nil if wrapped_control_statement_list?(raw)

        case raw.children.first&.kind
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
        return false unless %w[if unless while until case begin].include?(raw.children.first&.kind)

        first_named = raw.named_children.first
        %w[body_statement if unless while until case begin].include?(first_named&.kind) && raw.named_children.size > 1
      end

      def scan_scopes(raw)
        return unless raw

        if scope_boundary?(raw)
          @locals_by_scope[scope_key(raw)] = collect_locals(raw)
        end
        raw.children.each { |child| scan_scopes(child) }
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
            lhs = named_field(node, "left") || node.named_children.first
            locals << lhs.text.to_s if lhs&.kind == "identifier"
          elsif node.kind == "rescue"
            variable = named_field(node, "variable")
            variable&.named_children&.each { |child| locals << child.text.to_s if child.kind == "identifier" }
          end
          node.children.each { |child| walk.call(child) }
        end
        walk.call(scope)
        locals
      end

      def collect_param_names(scope, locals)
        params =
          if %w[method singleton_method].include?(scope.kind)
            named_field(scope, "parameters")
          elsif hidden_method_definition?(scope)
            hidden_def_container(scope)&.named_children&.find { |child| child.kind == "method_parameters" }
          elsif %w[block do_block].include?(scope.kind)
            named_field(scope, "parameters")
          end
        return unless params

        params.named_children.each do |param|
          name = named_field(param, "name") ||
                 param.named_children.find { |child| child.kind == "identifier" } ||
                 (param.kind == "identifier" ? param : nil)
          locals << name.text.to_s if name
        end
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
        if raw.children.first&.text.to_s == "{" && raw.children.last&.text.to_s == "}"
          return @statements ||= StatementsNode.synthetic(context, raw, [context.wrap(raw, force: HiddenHashNode)].compact)
        end
        if raw.children.first&.text.to_s == "[" && raw.children.last&.text.to_s == "]"
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
        super(context, raw, children || statement_children(context, raw))
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
            return [context.wrap(raw.named_children.first)].compact
          end

          return [context.wrap(raw, force: expression_class(context, raw))].compact
        end

        context.named_children(raw).filter_map { |child| context.wrap(child) }
      end

      def expression_container?(raw)
        %w[body_statement block_body then].include?(raw.kind)
      end

      def hidden_def_statement?(raw)
        raw.kind == "body_statement" && (raw.children.first&.kind == "def" ||
          raw.named_children.any? { |child| child.kind == "argument_list" && child.children.first&.kind == "def" })
      end

      def return_body_statement?(raw)
        return false unless %w[body_statement block_body then].include?(raw.kind)
        return false unless raw.children.first&.kind == "return"
        return false if %w[block_body then].include?(raw.kind) && raw.named_children.any? { |child| child.kind == "return" }

        true
      end

      def control_body_statement?(raw)
        raw.kind == "body_statement" &&
          %w[if unless while until case begin].include?(raw.children.first&.kind) &&
          !wrapped_control_statement_list?(raw)
      end

      def control_body_statement_class(raw)
        case raw.children.first&.kind
        when "if" then IfNode
        when "unless" then UnlessNode
        when "while" then WhileNode
        when "until" then UntilNode
        when "case" then CaseNode
        when "begin" then BeginNode
        end
      end

      def wrapped_control_statement_list?(raw)
        first_named = raw.named_children.first
        %w[body_statement if unless while until case begin].include?(first_named&.kind) && raw.named_children.size > 1
      end

      def expression_body_statement?(raw)
        first = raw.children.first
        return false if first && %w[def class module if unless while until case begin rescue ensure].include?(first.kind)
        return false if raw.named_children.any? { |child| %w[method singleton_method class module].include?(child.kind) }
        return false if top_level_statement_list?(raw)

        true
      end

      def top_level_statement_list?(raw)
        return false unless %w[body_statement block_body then].include?(raw.kind)
        return false if raw.named_children.size <= 1
        return false if direct_token?(raw, ".") || direct_token?(raw, "&.")
        return false if direct_token?(raw, "[") || direct_token?(raw, "]")
        return false if raw.children.first&.text.to_s == "["
        return false if raw.children.first&.text.to_s == "{"
        return false if direct_token?(raw, "=")
        return false if direct_token?(raw, "rescue")
        return false if direct_token?(raw, "?") && direct_token?(raw, ":")
        return false if raw.children.any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\.\.\.?|\+|-|\*|\/|%|\|\||&&|or|and)\z/) }
        return false if raw.named_children.any? { |child| %w[argument_list block do_block].include?(child.kind) }

        true
      end

      def simple_child_expression?(raw)
        raw.named_children.size == 1 &&
          !raw.children.any? { |child| !child.named? && %w[. &. [ ] " ' ! not].include?(child.text.to_s) } &&
          !raw.children.any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\.\.\.?|\+|-|\*|\/|%|\|\||&&|or|and)\z/) }
      end

      def expression_class(parse_context, raw)
        texts = raw.children.map { |child| child.text.to_s }
        return HiddenArrayNode if raw.children.first&.text.to_s == "[" && texts.include?("]")
        return HiddenHashNode if raw.children.first&.text.to_s == "{" && texts.include?("}")
        if (assignment_class = hidden_assignment_class(raw))
          return assignment_class
        end
        return RescueModifierNode if texts.include?("rescue")
        return HiddenUnaryNode if %w[! not].include?(raw.children.first&.text.to_s)
        return HiddenElementReferenceNode if texts.include?("[") && texts.include?("]")
        if (texts & %w[|| or]).any?
          return HiddenOrNode
        end
        return RangeNode if (texts & %w[.. ...]).any?
        return HiddenBinaryNode if raw.children.any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\+|-|\*|\/|%)\z/) }
        return HiddenCallNode if texts.include?(".") || raw.children.any? { |child| %w[argument_list block do_block].include?(child.kind) }
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

        child = raw.named_children.first
        return ConstantReadNode if child&.kind == "constant"
        return InstanceVariableReadNode if child&.kind == "instance_variable"
        return ClassVariableReadNode if child&.kind == "class_variable"
        return GlobalVariableReadNode if child&.kind == "global_variable"
        if raw.named_children.empty?
          text = raw.text.to_s.strip
          return ClassVariableReadNode if text.start_with?("@@")
          return InstanceVariableReadNode if text.start_with?("@")
          return GlobalVariableReadNode if text.start_with?("$")
        end

        Node
      end

      def direct_token?(raw, text)
        raw.children.any? { |child| !child.named? && child.text.to_s == text }
      end

      def hidden_assignment_class(raw)
        return false unless direct_token?(raw, "=")
        return false if raw.children.any? { |child| !child.named? && %w[== != <= >= ===].include?(child.text.to_s) }

        lhs = raw.named_children.first
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
        context.wrap(context.named_field(raw, "name") || raw.named_children.first, force: ConstantReadNode)
      end

      def body
        body_raw = context.named_field(raw, "body") ||
                   (raw.kind == "body_statement" ? raw.named_children.find { |child| child.kind == "body_statement" } : nil)
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
          %w[class module].include?(node.children.first&.kind) &&
          !node.children.first.named? &&
          !node.children.any? { |child| !child.named? && child.text.to_s == "<<" }
      end

      def hidden_singleton_class_statement?(node)
        node.kind == "body_statement" &&
          node.children.first&.kind == "class" &&
          !node.children.first.named? &&
          node.children.any? { |child| !child.named? && child.text.to_s == "<<" }
      end
    end

    class ModuleNode < ClassNode; end

    class SingletonClassNode < Node
      def expression
        context.wrap(context.named_field(raw, "value") || raw.named_children.first)
      end

      def body
        body_raw = context.named_field(raw, "body") || raw.named_children.last
        body_raw ? context.wrap(body_raw, force: StatementsNode) : nil
      end

      def child_nodes
        [expression, body].compact
      end
    end

    class DefNode < Node
      def name
        if hidden_body_statement_def?
          hidden_def_container.named_children.find { |child| child.kind == "identifier" }&.text.to_s.to_sym
        else
          (context.named_field(raw, "name") || raw.named_children.find { |child| child.kind == "identifier" })&.text.to_s.to_sym
        end
      end

      def receiver
        if hidden_body_statement_def?
          container = hidden_def_container
          dot = container.children.index { |child| !child.named? && child.text.to_s == "." }
          return nil unless dot

          return context.wrap(container.children[dot - 1]) if dot.positive?
        end

        context.wrap(context.named_field(raw, "object"))
      end

      def parameters
        node = if hidden_body_statement_def?
                 hidden_def_container.named_children.find { |child| child.kind == "method_parameters" }
               else
                 context.named_field(raw, "parameters")
               end
        node ? context.wrap(node, force: ParametersNode) : nil
      end

      def body
        body_raw = if hidden_body_statement_def?
                     hidden_def_container.named_children.reverse.find { |child| child.kind == "body_statement" || !%w[identifier method_parameters self].include?(child.kind) }
                   else
                     context.named_field(raw, "body") || raw.named_children.reverse.find { |child| child.kind != "method_parameters" && child.kind != "identifier" && child.kind != "self" }
                   end
        return nil unless body_raw
        return begin_body(body_raw) if body_raw.kind == "body_statement" && body_raw.named_children.any? { |child| %w[rescue ensure].include?(child.kind) }

        statement_node(body_raw)
      end

      def name_loc
        node = if hidden_body_statement_def?
                 hidden_def_container.named_children.find { |child| child.kind == "identifier" }
               else
                 context.named_field(raw, "name")
               end
        node && context.location(node)
      end

      def rparen_loc
        token = hidden_body_statement_def? ? hidden_def_container.children.find { |child| child.text.to_s == ")" } : raw.children.find { |child| child.text.to_s == ")" }
        token && context.location(token)
      end

      def end_keyword_loc
        token = hidden_body_statement_def? ? hidden_def_container.children.reverse.find { |child| child.text.to_s == "end" } : raw.children.reverse.find { |child| child.text.to_s == "end" }
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
        return raw if raw.children.first&.kind == "def"

        raw.named_children.find { |child| child.kind == "argument_list" && child.children.first&.kind == "def" }
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
        raw.named_children.each do |child|
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
               raw.named_children.find { |child| child.kind == "identifier" } ||
               (raw.kind == "identifier" ? raw : nil)
        node&.text&.to_sym
      end

      def value
        node = context.named_field(raw, "value") || raw.named_children.find { |child| child != context.named_field(raw, "name") && child.kind != "identifier" }
        context.wrap(node)
      end
    end

    class BlockNode < Node
      def parameters
        node = context.named_field(raw, "parameters")
        node ? context.wrap(node, force: BlockParametersNode) : nil
      end

      def body
        node = context.named_field(raw, "body") || raw.named_children.reject { |child| child.kind == "block_parameters" }.last
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
        context.named_field(raw, "left") || raw.named_children.first
      end

      def name
        target&.text.to_s.to_sym
      end

      def value
        context.wrap(context.named_field(raw, "right") || context.named_field(raw, "value") || raw.named_children[1])
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
        context.named_field(raw, "left") || raw.named_children.first
      end
    end

    class CallNode < Node
      def receiver
        if raw.kind == "element_reference"
          context.wrap(context.named_field(raw, "object") || raw.named_children.first)
        elsif %w[assignment operator_assignment].include?(raw.kind)
          lhs = context.named_field(raw, "left") || raw.named_children.first
          context.wrap(context.named_field(lhs, "object") || lhs&.named_children&.first)
        elsif raw.kind == "binary"
          context.wrap(raw.named_children.first)
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
          raw.children.find { |child| !child.named? }&.text.to_s.to_sym
        elsif raw.kind == "argument_list"
          text = raw.text.to_s.strip
          return text.to_sym if text.match?(/\A[a-z_]\w*[!?=]?\z/)

          nil
        elsif raw.kind == "identifier"
          raw.text.to_s.to_sym
        else
          node = context.named_field(raw, "method") || method_after_dot || raw.named_children.find { |child| child.kind == "identifier" }
          return node.text.to_s.to_sym if node
          return raw.text.to_s.strip.to_sym if %w[body_statement block_body then].include?(raw.kind) && raw.text.to_s.strip.match?(/\A[a-z_]\w*[!?=]?\z/)

          nil
        end
      end

      def arguments
        args =
          if raw.kind == "element_reference"
            raw.named_children.drop(1)
          elsif %w[assignment operator_assignment].include?(raw.kind)
            lhs = context.named_field(raw, "left") || raw.named_children.first
            lhs_args = lhs ? lhs.named_children.drop(1) : []
            lhs_args + [context.named_field(raw, "right") || raw.named_children[1]].compact
          elsif raw.kind == "binary"
            [raw.named_children[1]].compact
          else
            arg_raw = context.named_field(raw, "arguments")
            arg_raw ||= raw.named_children.find { |child| child.kind == "argument_list" }
            return context.wrap(arg_raw, force: ArgumentsNode) if arg_raw

            []
          end
        ArgumentsNode.synthetic(context, raw, args.filter_map { |child| context.wrap(child) })
      end

      def block
        node = context.named_field(raw, "block") || raw.named_children.find { |child| %w[block do_block].include?(child.kind) }
        context.wrap(node, force: BlockNode)
      end

      def safe_navigation?
        raw.children.any? { |child| child.text.to_s == "&." }
      end

      def child_nodes
        [receiver, arguments, block].compact
      end

      private

      def operator_token
        raw.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }
      end

      def dot_index
        raw.children.index { |child| !child.named? && %w[. &.].include?(child.text.to_s) }
      end

      def receiver_before_dot
        idx = dot_index
        return nil unless idx

        raw.children[0...idx].reverse.find(&:named?)
      end

      def method_after_dot
        idx = dot_index
        return nil unless idx

        raw.children[(idx + 1)..].to_a.find { |child| child.named? && child.kind == "identifier" }
      end
    end

    class HiddenCallNode < CallNode
      def receiver
        return nil unless dot_index

        context.wrap(raw.named_children.first)
      end

      def name
        if (idx = dot_named_index)
          raw.named_children[idx]&.text.to_s.to_sym
        else
          raw.named_children.first&.text.to_s.to_sym
        end
      end

      def arguments
        if (arg_raw = raw.named_children.find { |child| child.kind == "argument_list" })
          return context.wrap(arg_raw, force: ArgumentsNode)
        end

        start = dot_named_index ? dot_named_index + 1 : 1
        args = raw.named_children[start..].to_a.reject { |child| %w[block do_block].include?(child.kind) }
        ArgumentsNode.synthetic(context, raw, args.filter_map { |child| context.wrap(child) })
      end

      def block
        node = raw.named_children.find { |child| %w[block do_block].include?(child.kind) }
        context.wrap(node, force: BlockNode)
      end

      def safe_navigation?
        raw.children.any? { |child| child.text.to_s == "&." }
      end

      private

      def dot_index
        @dot_index ||= raw.children.index { |child| !child.named? && %w[. &.].include?(child.text.to_s) }
      end

      def dot_named_index
        return nil unless dot_index

        raw.named_children.index { |child| child.start_byte > raw.children[dot_index].start_byte }
      end
    end

    class HiddenUnaryNode < CallNode
      def receiver
        nil
      end

      def name
        raw.children.first&.text.to_s.to_sym
      end

      def arguments
        ArgumentsNode.synthetic(context, raw, raw.named_children.first(1).filter_map { |child| context.wrap(child) })
      end
    end

    class HiddenElementReferenceNode < CallNode
      def receiver
        context.wrap(raw.named_children.first)
      end

      def name
        :[]
      end

      def arguments
        ArgumentsNode.synthetic(context, raw, raw.named_children.drop(1).filter_map { |child| context.wrap(child) })
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
            lhs = context.wrap(raw.named_children.first, force: HiddenElementReferenceNode)
            (lhs.arguments&.arguments || []) + [context.wrap(raw.named_children[1])].compact
          else
            [context.wrap(raw.named_children[1])].compact
          end
        ArgumentsNode.synthetic(context, raw, args)
      end

      private

      def lhs_element_reference?
        raw.named_children.first&.kind == "element_reference"
      end

      def lhs_call
        @lhs_call ||= context.wrap(raw.named_children.first)
      end
    end

    class HiddenBinaryNode < CallNode
      def receiver
        context.wrap(raw.named_children.first)
      end

      def name
        raw.children.find { |child| !child.named? && !%w[( )].include?(child.text.to_s) }&.text.to_s.to_sym
      end

      def arguments
        ArgumentsNode.synthetic(context, raw, [context.wrap(raw.named_children[1])].compact)
      end
    end

    class ArgumentsNode < SyntheticNode
      def self.synthetic(context, raw, children)
        new(context, raw, children)
      end

      def initialize(context, raw, children = nil)
        super(context, raw, children || build_arguments(context, raw))
      end

      def arguments
        child_nodes
      end

      private

      def build_arguments(context, raw)
        if quoted_argument_list?(raw)
          klass = raw.named_children.any? { |child| child.kind == "interpolation" } ? InterpolatedStringNode : StringNode
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

        first = raw.children.first&.text.to_s
        last = raw.children.last&.text.to_s
        %w[" '].include?(first) && first == last
      end

      def scalar_expression_argument_list_class(context, raw)
        return nil unless raw.kind == "argument_list"
        return nil if parenthesized_argument_list?(raw)

        texts = raw.children.map { |child| child.text.to_s }
        first = texts.first
        return HiddenArrayNode if first == "[" && texts.include?("]")
        return HiddenHashNode if first == "{" && texts.include?("}")
        return nil if texts.include?(",")
        return HiddenElementReferenceNode if texts.include?("[") && texts.include?("]")
        return HiddenOrNode if (texts & %w[|| or]).any?
        return RangeNode if (texts & %w[.. ...]).any?
        return HiddenBinaryNode if raw.children.any? { |child| !child.named? && child.text.to_s.match?(/\A(?:==|!=|===|<=>|<=|>=|<<|>>|<|>|\+|-|\*|\/|%)\z/) }
        return HiddenCallNode if texts.include?(".") || raw.named_children.any? { |child| %w[argument_list block do_block].include?(child.kind) }

        scalar_argument_class(context, raw)
      end

      def parenthesized_argument_list?(raw)
        raw.children.first&.text.to_s == "(" && raw.children.last&.text.to_s == ")"
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
        context.wrap(context.named_field(raw, "key") || raw.named_children.first)
      end

      def value
        context.wrap(context.named_field(raw, "value") || raw.named_children[1])
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
        args = raw.named_children.flat_map do |child|
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
        context.wrap(raw.named_children.first)
      end

      def child_nodes
        [body].compact
      end
    end

    class IfNode < Node
      def predicate
        context.wrap(context.named_field(raw, "condition") || raw.named_children.first)
      end

      def statements
        node = context.named_field(raw, "consequence") ||
               raw.named_children.find { |child| child.kind == "then" } ||
               raw.named_children[1]
        statement_node(node)
      end

      def subsequent
        node = context.named_field(raw, "alternative") ||
               raw.named_children.find { |child| %w[else elsif].include?(child.kind) } ||
               raw.named_children[2]
        context.wrap(node)
      end

      def child_nodes
        [predicate, statements, subsequent].compact
      end
    end

    class UnlessNode < Node
      def predicate
        context.wrap(context.named_field(raw, "condition") || raw.named_children.first)
      end

      def statements
        node = context.named_field(raw, "consequence") ||
               raw.named_children.find { |child| child.kind == "then" } ||
               raw.named_children[1]
        statement_node(node)
      end

      def subsequent
        node = context.named_field(raw, "alternative") ||
               raw.named_children.find { |child| %w[else elsif].include?(child.kind) } ||
               raw.named_children[2]
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
        context.wrap(context.named_field(raw, "condition") || raw.named_children.first)
      end

      def statements
        node = context.named_field(raw, "body") ||
               raw.named_children.find { |child| child.kind == "then" } ||
               raw.named_children[1]
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
        context.wrap(context.named_field(raw, "value") || raw.named_children.first)
      end

      def conditions
        raw.named_children.select { |child| child.kind == "when" }.filter_map { |child| context.wrap(child, force: WhenNode) }
      end

      def else_clause
        node = raw.named_children.find { |child| child.kind == "else" }
        context.wrap(node, force: ElseNode)
      end

      def child_nodes
        [predicate, *conditions, else_clause].compact
      end
    end

    class WhenNode < Node
      def conditions
        nodes = raw.named_children.take_while { |child| child.kind != "then" }
        nodes.filter_map { |child| context.wrap(child) }
      end

      def statements
        body = context.named_field(raw, "body") || raw.named_children.find { |child| child.kind == "then" }
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
        body_children = raw.named_children.reject { |child| %w[rescue ensure else].include?(child.kind) }
        StatementsNode.synthetic(context, raw, body_children.filter_map { |child| context.wrap(child) })
      end

      def rescue_clause
        node = raw.named_children.find { |child| child.kind == "rescue" }
        context.wrap(node, force: RescueNode)
      end

      def else_clause
        node = raw.named_children.find { |child| child.kind == "else" }
        context.wrap(node, force: ElseNode)
      end

      def ensure_clause
        node = raw.named_children.find { |child| child.kind == "ensure" }
        context.wrap(node, force: EnsureNode)
      end

      def child_nodes
        [statements, rescue_clause, else_clause, ensure_clause].compact
      end
    end

    class RescueNode < Node
      def exceptions
        node = context.named_field(raw, "exceptions") || raw.named_children.find { |child| child.kind == "exceptions" }
        node ? node.named_children.filter_map { |child| context.wrap(child) } : []
      end

      def statements
        body = context.named_field(raw, "body") || raw.named_children.find { |child| child.kind == "then" }
        statement_node(body)
      end

      def subsequent
        body = context.named_field(raw, "body") || raw.named_children.find { |child| child.kind == "then" }
        return nil unless body

        seen_body = false
        node = raw.named_children.find do |child|
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
        context.wrap(raw.named_children.first)
      end

      def rescue_expression
        context.wrap(raw.named_children[1])
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
        context.wrap(raw.named_children.first)
      end

      def right
        context.wrap(raw.named_children[1])
      end

      def child_nodes
        [left, right].compact
      end
    end

    class HiddenOrNode < OrNode
      def left
        context.wrap(raw.named_children.first)
      end

      def right
        context.wrap(raw.named_children[1])
      end
    end
  end
end
