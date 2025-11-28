module AstMatchers
  class StructureBuilder
    include RSpec::Matchers

    def build(dsl_string)
      clean_code = dsl_string.gsub(/^\s*#/, '').strip
      instance_eval(clean_code)
    end

    # A Custom Matcher that prints readable AST descriptions instead of verbose Hash diffs
    class NodeMatcher
      include RSpec::Matchers::Composable

      def initialize(node_class, attributes)
        @node_class = node_class
        @attributes = attributes
      end

      def matches?(actual)
        @actual = actual
        return false unless actual.is_a?(@node_class)

        @attributes.all? do |key, matcher|
          # Use RSpec's values_match? to handle nested matchers recursively
          actual_value = actual.respond_to?(key) ? actual.public_send(key) : actual[key]

          if matcher.is_a?(String) && actual_value.class.name == "AST::Identifier"
             values_match?(matcher, actual_value.name)

          elsif actual_value.class.name == "AST::Literal"
             # Unbox the literal value so "NOK" matches Literal("NOK")
             values_match?(matcher, actual_value.value)

          elsif actual_value.class.name == "AST::ListLit"
            values_match?(matcher, actual_value.items.map { |x| x.value })

          elsif actual_value.class.name == "AST::HashLit"
            values_match?(matcher, actual_value.pairs.map { |key, val| [key.name.to_sym, val.value] }.to_h)

          else
             values_match?(matcher, actual_value)
          end
        end
      end

      #<struct AST::BinaryOp line=2, left=#<struct AST::BinaryOp line=2, left=#<struct AST::BinaryOp line=2, left=#<struct AST::Identifier line=2, name="x">, op=:SMOOTH, right=#<struct AST::Identifier line=2, name="fail_task">>, op=:OR_RESCUE, right=#<struct AST::ThrowNode line=2, value=#<struct AST::Literal line=2, type=:STRING, value="NOK">>>, op=:SMOOTH, right=#<struct AST::Identifier line=2, name="recover_task">>
      def description
        # Generate a DSL-like description (e.g. "Smooth(left: Var(x), right: ...)")
        name = dsl_name
        args = @attributes.reject { |k, _| k == :op }.map do |k, v|
          val_desc = v.respond_to?(:description) ? v.description : v.inspect
          "#{k}: #{val_desc}"
        end.join(", ")

        "#{name}(#{args})"
      end

      def failure_message
        "expected #{description}\n     got #{format_actual(@actual)}"
      end

      private

      def dsl_name
        return "Smooth" if @attributes[:op] == :SMOOTH
        return "OrRescue" if @attributes[:op] == :OR_RESCUE
        return "Var" if @node_class.name.end_with?("Identifier")
        @node_class.name.split('::').last
      end

      # Recursively format the actual AST node to match DSL syntax
      def format_actual(node)
        return node.inspect unless node.class.name.start_with?("AST::")

        case node
        when AST::BinaryOp
          if node.op == :SMOOTH
            "Smooth(left: #{format_actual(node.left)}, right: #{format_actual(node.right)})"
          elsif node.op == :OR_RESCUE
            "OrRescue(left: #{format_actual(node.left)}, right: #{format_actual(node.right)})"
          else
            "BinaryOp(op: #{node.op.inspect}, left: #{format_actual(node.left)}, right: #{format_actual(node.right)})"
          end
        when AST::FuncCall
          "FuncCall(#{node.name})"
        when AST::Identifier
          "Var(#{node.name})"
        when AST::ThrowNode
          val = node.value ? format_actual(node.value) : "nil"
          "ThrowNode(value: #{val})"
        when AST::ReturnNode
          val = node.value ? format_actual(node.value) : "nil"
          "ReturnNode(value: #{val})"
        when AST::Literal
          node.type == :STRING ? "\"#{node.value}\"" : node.value.to_s
        else
          node.inspect
        end
      end
    end

    # --- DSL Methods ---

    def Smooth(*args, left: nil, right: nil)
      if args.any?
        left = args[0]
        right = args[1]
      end

      attrs = { op: :SMOOTH }
      attrs[:left] = left if left
      attrs[:right] = right if right

      NodeMatcher.new(AST::BinaryOp, attrs)
    end

    def OrRescue(*args, left: nil, right: nil)
      if args.any?
        left = args[0]
        right = args[1]
      end

      attrs = { op: :OR_RESCUE }
      attrs[:left] = left if left
      attrs[:right] = right if right

      NodeMatcher.new(AST::BinaryOp, attrs)
    end

    def FuncCall(name_or_matcher)
      attrs = {}
      if name_or_matcher.respond_to?(:matches?)
        attrs[:name] = name_or_matcher
      else
        attrs[:name] = name_or_matcher.to_s
      end
      NodeMatcher.new(AST::FuncCall, attrs)
    end

    def ThrowNode(value_matcher = anything)
      # If it's the default 'anything', we don't check attributes, just class
      return NodeMatcher.new(AST::ThrowNode, {}) if value_matcher == anything
      NodeMatcher.new(AST::ThrowNode, value: value_matcher)
    end

    def Var(name)
      NodeMatcher.new(AST::Identifier, name: name.to_s)
    end

    def VarDecl(name: nil,  type: nil, value: nil)
      NodeMatcher.new(AST::VarDecl, name: name, type: type, value: value)
    end

    def ListLit(*items)
      NodeMatcher.new(AST::VarDecl, items: items)
    end

    def method_missing(m, *args, &block)
      m.to_s
    end
  end

  def match_ast(dsl_string)
    StructureBuilder.new.build(dsl_string)
  end
end
