# frozen_string_literal: true

require "espalier/tree_sitter"

module NilKill
  module TreeSitterAdapter
    VERSION = "tree-sitter"

    def self.parse(source, path: nil)
      source = source.to_s
      source = source.dup.force_encoding("UTF-8") if source.encoding != Encoding::UTF_8
      parser = Espalier::TreeSitter.parser_for(:ruby)
      tree = parser.parse(source)
      Context.new(source, tree, path)
    end

    def self.parse_file(path)
      parse(File.read(path), path: path)
    end

    class Location
      attr_reader :start_line, :start_column, :end_line, :end_column, :start_offset, :end_offset

      def initialize(raw)
        @start_line = raw.start_point.row + 1
        @start_column = raw.start_point.column
        @end_line = raw.end_point.row + 1
        @end_column = raw.end_point.column
        @start_offset = raw.start_byte
        @end_offset = raw.end_byte
      end

      def length
        @end_offset - @start_offset
      end
    end

    class Context
      attr_reader :tree, :root, :path, :child_map

      def initialize(source, tree, path)
        @source = source
        @tree = tree
        @root = tree&.root_node
        @path = path
        @cache = {}
        build_child_map!
      end

      def source
        @binary_source ||= @source.b
      end

      def success?
        !@root.nil? && !@root.has_error?
      end

      def value
        wrap(@root)
      end

      def errors
        []
      end

      def wrap(raw, force: nil)
        return nil unless raw
        return nil if !force && !raw.named? && raw.type != "self" && raw.type != "nil" && raw.type != "end" && raw.type != "true" && raw.type != "false"
        
        klass = force || class_for_type(raw.type, raw)
        return nil unless klass
        
        key = [raw.start_byte, raw.end_byte, raw.type, klass.name]
        @cache[key] ||= klass.new(self, raw)
      end

      def location(raw)
        Location.new(raw)
      end

      def named_field(raw, name)
        raw.child_by_field_name(name)
      end

      def children(raw)
        return [] unless raw
        key = [raw.start_byte, raw.end_byte, raw.type]
        @child_map[key] || []
      end

      def named_children(raw)
        children(raw)
      end

      def native_children(raw)
        return [] unless raw
        raw.respond_to?(:children) ? raw.children : []
      end

      private

      def build_child_map!
        @child_map = Hash.new { |h, k| h[k] = [] }
        return unless @root && @tree

        lang = @tree.language rescue nil
        return unless lang

        query = ::TreeSitter::Query.new(lang, "(_) @node")
        cursor = ::TreeSitter::QueryCursor.new
        res = cursor.captures(query, @root, @source)

        stack = [@root]
        res.each do |c|
          node = c.node
          next if node.start_byte == @root.start_byte && node.end_byte == @root.end_byte && node.type == @root.type
          while !stack.empty?
            parent = stack.last
            if parent.start_byte <= node.start_byte && parent.end_byte >= node.end_byte &&
               (parent.start_byte != node.start_byte || parent.end_byte != node.end_byte || parent.type != node.type)
              break
            else
              stack.pop
            end
          end
          
          if !stack.empty?
            parent = stack.last
            key = [parent.start_byte, parent.end_byte, parent.type]
            @child_map[key] << node
          end
          stack << node
        end
      end

      def class_for_type(type, raw)
        case type
        when "program" then ProgramNode
        when "body_statement" then BodyStatementNode
        when "block_body", "then" then StatementsNode
        when "class" then ClassNode
        when "module" then ModuleNode
        when "singleton_class" then SingletonClassNode
        when "method", "singleton_method" then DefNode
        when "method_parameters", "block_parameters" then ParametersNode
        when "block", "do_block" then BlockNode
        when "assignment", "operator_assignment"
          lhs = raw.child_by_field_name("left") || raw.named_children.first
          return WriteNode unless lhs
          if lhs.type == "element_reference"
            if raw.type == "operator_assignment"
              op_children = native_children(raw)
              is_or = op_children.any? { |c| !c.named? && source[c.start_byte...c.end_byte] == "||=" }
              is_and = op_children.any? { |c| !c.named? && source[c.start_byte...c.end_byte] == "&&=" }
              if is_or
                return IndexOrWriteNode
              elsif is_and
                return IndexAndWriteNode
              else
                return IndexOperatorWriteNode
              end
            else
              return CallNode
            end
          end
          case lhs.type
          when "identifier" then LocalVariableWriteNode
          when "instance_variable" then InstanceVariableWriteNode
          when "class_variable" then ClassVariableWriteNode
          when "global_variable" then GlobalVariableWriteNode
          when "constant" then ConstantWriteNode
          when "scope_resolution" then ConstantPathWriteNode
          else WriteNode
          end
        when "call", "command", "command_call", "element_reference", "binary", "unary" then CallNode
        when "array" then ArrayNode
        when "hash" then HashNode
        when "pair" then AssocNode
        when "argument_list" then ArgumentsNode
        when "string"
          has_interpolation = native_children(raw).any? { |c| c.type == "interpolation" }
          has_interpolation ? InterpolatedStringNode : StringNode
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
        when "identifier"
          parent = raw.parent
          if parent
            if %w[call command command_call].include?(parent.type) && parent.child_by_field_name("method") == raw
              return Node
            end
            if %w[method singleton_method class module].include?(parent.type) && parent.child_by_field_name("name") == raw
              return Node
            end
          end
          if source[raw.start_byte...raw.end_byte] == "__LINE__"
            return SourceLineNode
          end
          LocalVariableReadNode
        else
          Node
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
        @location ||= Location.new(@raw)
      end

      def slice
        @context.source.byteslice(@raw.start_byte...@raw.end_byte)
      end

      def child_nodes
        @child_nodes ||= @context.children(@raw).map { |c| @context.wrap(c) }.compact
      end

      def compact_child_nodes
        child_nodes
      end

      def kind
        @raw.respond_to?(:kind) ? @raw.kind : @raw.type
      end

      def type
        @raw.type
      end

      def statement_node(raw_node)
        return nil unless raw_node
        if %w[body_statement block_body then].include?(raw_node.type)
          @context.wrap(raw_node)
        else
          StatementsNode.synthetic(@context, raw_node, [@context.wrap(raw_node)].compact)
        end
      end
    end

    class ProgramNode < Node
      def statements
        @statements ||= StatementsNode.synthetic(
          @context,
          @raw,
          @context.named_children(@raw).map { |child| @context.wrap(child) }.compact
        )
      end

      def child_nodes
        [statements].compact
      end
    end

    class SyntheticNode < Node
      def self.synthetic(context, raw, children)
        new(context, raw, children)
      end

      def initialize(context, raw, children = nil)
        super(context, raw)
        @children = children || context.children(raw).map { |c| context.wrap(c) }.compact
      end

      def child_nodes
        @children
      end

      def compact_child_nodes
        @children.compact
      end
    end

    class StatementsNode < SyntheticNode
      def body
        child_nodes
      end
    end

    class ClassNode < Node
      def constant_path
        path_node = @raw.child_by_field_name("name") || @raw.named_children.first
        @context.wrap(path_node)
      end

      def body
        body_node = @raw.child_by_field_name("body") || @raw.named_children.find { |child| child.type == "body_statement" }
        statement_node(body_node)
      end
    end

    class ModuleNode < ClassNode; end

    class SingletonClassNode < Node
      def expression
        rec = @raw.child_by_field_name("value") || @raw.named_children.first
        @context.wrap(rec)
      end

      def body
        body_node = @raw.child_by_field_name("body") || @raw.named_children.find { |child| child.type == "body_statement" }
        statement_node(body_node)
      end
    end

    class DefNode < Node
      def name
        name_node = @raw.child_by_field_name("name") || @raw.named_children.find { |child| child.type == "identifier" }
        name_node ? @context.source.byteslice(name_node.start_byte...name_node.end_byte).to_sym : nil
      end

      def receiver
        rec = if @raw.type == "singleton_method"
          @raw.child_by_field_name("object")
        else
          @raw.child_by_field_name("receiver")
        end
        rec ? @context.wrap(rec) : nil
      end

      def parameters
        params_node = @raw.child_by_field_name("parameters")
        params_node ? @context.wrap(params_node) : nil
      end

      def body
        body_node = @raw.child_by_field_name("body") || @raw.named_children.find { |child| child.type == "body_statement" }
        statement_node(body_node)
      end

      def end_keyword_loc
        token = @context.native_children(@raw).reverse.find { |child| !child.named? && child.type == "end" }
        token ? @context.location(token) : nil
      end

      def rparen_loc
        token = @context.native_children(@raw).find { |child| !child.named? && child.type == ")" }
        token ? @context.location(token) : nil
      end

      def name_loc
        name_node = @raw.child_by_field_name("name")
        name_node ? @context.location(name_node) : nil
      end
    end

    class ParametersNode < Node
      attr_reader :requireds, :optionals, :keywords, :rest, :keyword_rest, :block

      def initialize(context, raw)
        super(context, raw)
        @requireds = []
        @optionals = []
        @keywords = []
        @rest = nil
        @keyword_rest = nil
        @block = nil
        raw.named_children.each do |child|
          param = ParameterNode.new(context, child)
          case child.type
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
        @parameters ||= ParametersNode.new(@context, @raw)
      end

      def child_nodes
        [parameters]
      end
    end

    class ParameterNode < Node
      def name
        node = @raw.child_by_field_name("name") ||
               @raw.named_children.find { |child| child.type == "identifier" } ||
               (@raw.type == "identifier" ? @raw : nil)
        node ? @context.source.byteslice(node.start_byte...node.end_byte).to_sym : nil
      end

      def value
        node = @raw.child_by_field_name("value") ||
               @raw.named_children.find { |child| child != @raw.child_by_field_name("name") && child.type != "identifier" }
        @context.wrap(node)
      end
    end

    class BlockNode < Node
      def parameters
        node = @raw.child_by_field_name("parameters") || @raw.named_children.find { |child| child.type == "block_parameters" }
        node ? @context.wrap(node, force: BlockParametersNode) : nil
      end

      def body
        node = @raw.child_by_field_name("body") || @raw.named_children.reject { |child| child.type == "block_parameters" }.last
        statement_node(node)
      end

      def child_nodes
        [parameters, body].compact
      end
    end

    class VariableNode < Node
      def name
        name_node = @raw.child_by_field_name("name") || @raw.named_children.first || @raw
        @context.source.byteslice(name_node.start_byte...name_node.end_byte).to_sym
      end
    end

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
      def value
        val_node = @raw.child_by_field_name("value") || @raw.named_children.last
        @context.wrap(val_node)
      end
    end

    class LocalVariableWriteNode < WriteNode; end
    class InstanceVariableWriteNode < WriteNode; end
    class ClassVariableWriteNode < WriteNode; end
    class GlobalVariableWriteNode < WriteNode; end
    class ConstantWriteNode < WriteNode; end
    class ConstantPathWriteNode < WriteNode; end

    class CallNode < Node
      def name
        case @raw.type
        when "assignment", "operator_assignment"
          :[]=
        when "element_reference"
          :[]
        when "binary"
          op = @raw.child_by_field_name("operator")
          txt = op && @context.source ? @context.source.byteslice(op.start_byte...op.end_byte) : nil
          txt ? txt.to_sym : nil
        when "unary"
          op = @raw.child_by_field_name("operator")
          txt = op && @context.source ? @context.source.byteslice(op.start_byte...op.end_byte) : nil
          txt ? txt.to_sym : nil
        else
          method_node = @raw.child_by_field_name("method") || @raw.named_children.find { |child| child.type == "identifier" }
          txt = method_node && @context.source ? @context.source.byteslice(method_node.start_byte...method_node.end_byte) : nil
          txt ? txt.to_sym : nil
        end
      end

      def receiver
        case @raw.type
        when "assignment", "operator_assignment"
          lhs = @raw.child_by_field_name("left") || @raw.named_children.first
          if lhs && lhs.type == "element_reference"
            rec = lhs.child_by_field_name("object")
            rec ? @context.wrap(rec) : nil
          else
            nil
          end
        when "element_reference"
          rec = @raw.child_by_field_name("object")
          rec ? @context.wrap(rec) : nil
        when "binary"
          rec = @raw.child_by_field_name("left")
          rec ? @context.wrap(rec) : nil
        when "unary"
          rec = @raw.child_by_field_name("operand")
          rec ? @context.wrap(rec) : nil
        else
          rec = @raw.child_by_field_name("receiver")
          rec ? @context.wrap(rec) : nil
        end
      end

      def safe_navigation?
        @raw.children.any? { |c| c.type == "&." }
      end

      def arguments
        case @raw.type
        when "assignment", "operator_assignment"
          lhs = @raw.child_by_field_name("left") || @raw.named_children.first
          right = @raw.child_by_field_name("value") || @raw.child_by_field_name("right") || @raw.named_children.last
          if lhs && lhs.type == "element_reference"
            obj = lhs.child_by_field_name("object")
            lhs_keys = lhs.named_children.reject { |c| c.start_byte == obj&.start_byte && c.end_byte == obj&.end_byte && c.type == obj&.type }
            ArgumentsNode.synthetic(@context, @raw, (lhs_keys + [right]).map { |c| @context.wrap(c) }.compact)
          else
            ArgumentsNode.synthetic(@context, @raw, [@context.wrap(right)].compact)
          end
        when "element_reference"
          obj = @raw.child_by_field_name("object")
          args = @raw.named_children.reject { |c| c.start_byte == obj&.start_byte && c.end_byte == obj&.end_byte && c.type == obj&.type }
          ArgumentsNode.synthetic(@context, @raw, args.map { |c| @context.wrap(c) }.compact)
        when "binary"
          right = @raw.child_by_field_name("right")
          ArgumentsNode.synthetic(@context, @raw, [@context.wrap(right)].compact)
        when "unary"
          nil
        else
          args_node = @raw.child_by_field_name("arguments")
          args_node ? @context.wrap(args_node) : nil
        end
      end

      def block
        block_node = @raw.child_by_field_name("block")
        block_node ? @context.wrap(block_node) : nil
      end
    end

    class IndexOperatorWriteNode < CallNode
      def value
        val = @raw.child_by_field_name("value") || @raw.child_by_field_name("right") || @raw.named_children.last
        @context.wrap(val)
      end
    end

    class IndexAndWriteNode < IndexOperatorWriteNode; end
    class IndexOrWriteNode < IndexOperatorWriteNode; end

    class LocalVariableReadNode < CallNode
      def name
        @context.source.byteslice(@raw.start_byte...@raw.end_byte).to_sym
      end
    end

    class ArgumentsNode < SyntheticNode
      def initialize(context, raw, children = nil)
        if children
          super(context, raw, children)
        else
          raw_children = context.children(raw).map { |c| context.wrap(c) }.compact
          pairs = []
          non_pairs = []
          raw_children.each do |child|
            if child.is_a?(AssocNode)
              pairs << child
            else
              non_pairs << child
            end
          end
          if !pairs.empty?
            kw_hash = KeywordHashNode.new(context, raw, pairs)
            super(context, raw, non_pairs + [kw_hash])
          else
            super(context, raw, raw_children)
          end
        end
      end

      def arguments
        child_nodes
      end
    end

    class ArrayNode < Node
      def elements
        child_nodes
      end
    end

    class HashNode < Node
      def elements
        child_nodes
      end
    end

    class KeywordHashNode < SyntheticNode
      def elements
        child_nodes
      end
    end

    class AssocNode < Node
      def key
        @context.wrap(@raw.child_by_field_name("key") || @raw.named_children.first)
      end

      def value
        @context.wrap(@raw.child_by_field_name("value") || @raw.named_children.last)
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
      def unescaped
        slice.delete_prefix(":").delete_suffix(":")
      end

      def value
        unescaped.to_sym
      end
    end

    class IntegerNode < Node; end
    class FloatNode < Node; end
    class TrueNode < Node; end
    class FalseNode < Node; end
    class NilNode < Node; end
    class RangeNode < Node; end
    class YieldNode < Node; end

    class ReturnNode < Node
      def arguments
        args = @raw.named_children.flat_map do |child|
          node = @context.wrap(child)
          node.is_a?(ArgumentsNode) ? node.arguments : [node].compact
        end
        ArgumentsNode.synthetic(@context, @raw, args)
      end

      def child_nodes
        [arguments]
      end
    end

    class ParenthesesNode < Node
      def body
        body_node = @raw.named_children.first
        @context.wrap(body_node)
      end
    end

    class IfNode < Node
      def predicate
        @context.wrap(@raw.child_by_field_name("condition") || @raw.named_children.first)
      end

      def condition
        predicate
      end

      def statements
        body_node = @raw.child_by_field_name("consequence") || @raw.named_children.find { |child| child.type == "body_statement" || child.type == "then" }
        statement_node(body_node)
      end

      def subsequent
        alternative = @raw.child_by_field_name("alternative") ||
                      @raw.named_children.find { |child| %w[else elsif].include?(child.type) } ||
                      @raw.named_children[2]
        @context.wrap(alternative)
      end

      def else_clause
        subsequent
      end

      def child_nodes
        [predicate, statements, subsequent].compact
      end
    end

    class UnlessNode < IfNode; end

    class WhileNode < Node
      def predicate
        @context.wrap(@raw.child_by_field_name("condition") || @raw.named_children.first)
      end

      def condition
        predicate
      end

      def statements
        body_node = @raw.child_by_field_name("body") ||
                    @raw.named_children.find { |child| child.type == "then" } ||
                    @raw.named_children[1]
        statement_node(body_node)
      end

      def child_nodes
        [predicate, statements].compact
      end
    end

    class UntilNode < WhileNode; end

    class CaseNode < Node
      def predicate
        pred_node = @raw.child_by_field_name("value")
        pred_node ? @context.wrap(pred_node) : nil
      end

      def conditions
        @raw.named_children.select { |child| child.type == "when" }.map { |c| @context.wrap(c) }
      end

      def else_clause
        node = @raw.named_children.find { |child| child.type == "else" }
        @context.wrap(node, force: ElseNode)
      end

      def child_nodes
        [predicate, *conditions, else_clause].compact
      end
    end

    class WhenNode < Node
      def conditions
        @raw.named_children.reject { |child| child.type == "then" || child.type == "body_statement" }.map { |c| @context.wrap(c) }
      end

      def statements
        body_node = @raw.child_by_field_name("body") || @raw.named_children.find { |child| child.type == "body_statement" || child.type == "then" }
        statement_node(body_node)
      end
    end

    class ElseNode < Node
      def statements
        body = @raw.named_children.find { |child| child.type != "comment" }
        statement_node(body)
      end

      def child_nodes
        [statements].compact
      end
    end

    class BodyStatementNode < Node
      def statements
        clause_types = %w[rescue ensure else]
        non_clauses = @context.named_children(@raw).reject { |child| clause_types.include?(child.type) }
        StatementsNode.synthetic(@context, @raw, non_clauses.map { |c| @context.wrap(c) }.compact)
      end

      def rescue_clause
        node = @context.named_children(@raw).find { |child| child.type == "rescue" }
        @context.wrap(node)
      end

      def else_clause
        node = @context.named_children(@raw).find { |child| child.type == "else" }
        @context.wrap(node)
      end

      def ensure_clause
        node = @context.named_children(@raw).find { |child| child.type == "ensure" }
        @context.wrap(node)
      end

      def child_nodes
        [statements, rescue_clause, else_clause, ensure_clause].compact
      end
    end

    class BeginNode < Node
      def statements
        clause_types = %w[rescue ensure else]
        non_clauses = @raw.named_children.reject { |child| clause_types.include?(child.type) }
        StatementsNode.synthetic(@context, @raw, non_clauses.map { |c| @context.wrap(c) }.compact)
      end

      def rescue_clause
        node = @raw.named_children.find { |child| child.type == "rescue" }
        @context.wrap(node)
      end

      def else_clause
        node = @raw.named_children.find { |child| child.type == "else" }
        @context.wrap(node)
      end

      def ensure_clause
        node = @raw.named_children.find { |child| child.type == "ensure" }
        @context.wrap(node)
      end

      def child_nodes
        [statements, rescue_clause, else_clause, ensure_clause].compact
      end
    end

    class RescueNode < Node
      def exceptions
        node = @raw.child_by_field_name("exceptions") || @raw.named_children.find { |child| child.type == "exceptions" }
        node ? node.named_children.map { |child| @context.wrap(child) }.compact : []
      end

      def statements
        body_node = @raw.child_by_field_name("body") || @raw.named_children.find { |child| child.type == "body_statement" }
        statement_node(body_node)
      end

      def subsequent
        parent = @raw.parent
        return nil unless parent
        siblings = @context.named_children(parent)
        idx = siblings.index { |s| s.start_byte == @raw.start_byte }
        return nil unless idx
        next_sibling = siblings[idx + 1]
        next_sibling && next_sibling.type == "rescue" ? @context.wrap(next_sibling) : nil
      end
    end

    class EnsureNode < Node
      def statements
        body = @raw.named_children.first
        statement_node(body)
      end

      def child_nodes
        [statements].compact
      end
    end

    class RescueModifierNode < Node
      def expression
        @context.wrap(@raw.named_children.first)
      end

      def rescue_expression
        @context.wrap(@raw.named_children.last)
      end
    end

    class LambdaNode < Node
      def body
        body_node = @raw.child_by_field_name("body") || @raw.named_children.find { |child| child.type == "body_statement" }
        statement_node(body_node)
      end
    end

    class SourceLineNode < Node; end
    class ConstantNode < Node; end
    class SelfNode < Node; end
  end
end
