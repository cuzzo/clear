# frozen_string_literal: true

module RubyToClear
  module MethodRegistry
    REGISTRY = {}

    def self.register(ruby_name, &block)
      REGISTRY[ruby_name.to_s] = block
    end

    def self.translate(ruby_name, receiver, node, transpiler)
      handler = REGISTRY[ruby_name.to_s]
      if handler
        handler.call(receiver, node, transpiler)
      else
        nil
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

    register("collect") do |receiver, node, transpiler|
      REGISTRY["map"].call(receiver, node, transpiler)
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

    register("filter") do |receiver, node, transpiler|
      REGISTRY["select"].call(receiver, node, transpiler)
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

    register("inject") do |receiver, node, transpiler|
      REGISTRY["reduce"].call(receiver, node, transpiler)
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
