# frozen_string_literal: true

module RubyToClear
  module MethodRegistry
    CallContext = Struct.new(
      :ruby_name,
      :receiver_code,
      :receiver_kind,
      :receiver_name,
      :node,
      :transpiler,
      keyword_init: true
    )

    REGISTRY = {}

    def self.register(ruby_name, receiver: :any, &block)
      REGISTRY[[receiver.to_s, ruby_name.to_s]] = block
    end

    def self.translate(ruby_name, receiver, node, transpiler, receiver_kind: nil, receiver_name: nil)
      context = CallContext.new(
        ruby_name: ruby_name.to_s,
        receiver_code: receiver,
        receiver_kind: receiver_kind&.to_s,
        receiver_name: receiver_name&.to_s,
        node: node,
        transpiler: transpiler
      )
      handler = lookup(context)
      return nil unless handler

      call_handler(handler, context)
    end

    def self.lookup(context)
      REGISTRY[[context.receiver_name, context.ruby_name]] ||
        REGISTRY[[context.receiver_kind, context.ruby_name]] ||
        REGISTRY[["any", context.ruby_name]]
    end

    def self.call_handler(handler, context)
      if handler.arity == 1
        handler.call(context)
      else
        handler.call(context.receiver_code, context.node, context.transpiler)
      end
    end

    # --- Registrations ---

    register("map") do |receiver, node, transpiler|
      block_node = node.block
      unless block_node
        transpiler.raise_unsupported("map without a block is not supported", node)
      end

      if block_node.is_a?(Prism::BlockArgumentNode)
        method_name = block_node.expression.value.to_s
        method_name = "toString" if method_name == "to_s"
        "#{receiver} |> SELECT _.#{method_name}()"
      elsif block_node.is_a?(Prism::BlockNode)
        unless transpiler.simple_block_expression?(block_node)
          transpiler.raise_unsupported("map block must be a single expression", node)
        end
        param_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        transpiler.with_renames({ param_name => "_" }) do
          block_body = transpiler.visit(block_node.body.body.first)
          "#{receiver} |> SELECT #{block_body}"
        end
      else
        transpiler.raise_unsupported("Unsupported map block type: #{block_node.class.name}", node)
      end
    end

    register("collect") do |context|
      translate(
        "map",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name
      )
    end

    register("select") do |receiver, node, transpiler|
      block_node = node.block
      unless block_node
        transpiler.raise_unsupported("select without a block is not supported", node)
      end

      if block_node.is_a?(Prism::BlockArgumentNode)
        method_name = block_node.expression.value.to_s
        "#{receiver} |> WHERE _.#{method_name}()"
      elsif block_node.is_a?(Prism::BlockNode)
        unless transpiler.simple_block_expression?(block_node)
          transpiler.raise_unsupported("select block must be a single expression", node)
        end
        param_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        transpiler.with_renames({ param_name => "_" }) do
          block_body = transpiler.visit(block_node.body.body.first)
          "#{receiver} |> WHERE #{block_body}"
        end
      else
        transpiler.raise_unsupported("Unsupported select block type: #{block_node.class.name}", node)
      end
    end

    register("filter") do |context|
      translate(
        "select",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name
      )
    end

    register("reduce") do |receiver, node, transpiler|
      block_node = node.block
      unless block_node
        transpiler.raise_unsupported("reduce without a block is not supported", node)
      end

      args = node.arguments ? node.arguments.arguments : []
      init_val = args.first ? transpiler.visit(args.first) : "0"

      if block_node.is_a?(Prism::BlockNode)
        unless transpiler.simple_block_expression?(block_node)
          transpiler.raise_unsupported("reduce block must be a single expression", node)
        end
        acc_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        item_name = block_node.parameters&.parameters&.requireds&.last&.name&.to_s
        transpiler.with_renames({ acc_name => "acc", item_name => "_" }) do
          block_body = transpiler.visit(block_node.body.body.first)
          "#{receiver} |> REDUCE(#{init_val}) #{block_body}"
        end
      else
        transpiler.raise_unsupported("Unsupported reduce block type: #{block_node.class.name}", node)
      end
    end

    register("inject") do |context|
      translate(
        "reduce",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name
      )
    end

    register("gsub") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      if node.block || args.length != 2 || 
         args[0].is_a?(Prism::RegularExpressionNode) || 
         args[0].is_a?(Prism::InterpolatedRegularExpressionNode)
        transpiler.raise_unsupported("gsub with regex or block is not supported", node)
      end
      "#{receiver}.replace(#{transpiler.visit(args[0])}, #{transpiler.visit(args[1])})"
    end

    register("include?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{receiver}.contains?(#{args.join(', ')})"
    end

    register("replace") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{receiver}.replace(#{args.join(', ')})"
    end

    register("each") do |receiver, node, transpiler|
      block_node = node.block
      unless block_node
        transpiler.raise_unsupported("each without a block is not supported", node)
      end

      if block_node.is_a?(Prism::BlockNode)
        param_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        transpiler.with_renames({ param_name => "_" }) do
          block_body = transpiler.visit(block_node.body)
          "#{receiver} |> EACH { #{block_body} }"
        end
      else
        transpiler.raise_unsupported("Unsupported each block type: #{block_node.class.name}", node)
      end
    end
  end
end
