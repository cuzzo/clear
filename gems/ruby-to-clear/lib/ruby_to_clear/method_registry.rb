# frozen_string_literal: true

module RubyToClear
  module MethodRegistry
    REGISTRY = {}

    def self.register(ruby_name, &block)
      REGISTRY[ruby_name.to_s] = block
    end

    def self.translate(ruby_name, receiver, args, block_node, transpiler)
      handler = REGISTRY[ruby_name.to_s]
      if handler
        handler.call(receiver, args, block_node, transpiler)
      else
        nil
      end
    end

    # --- Registrations ---

    register("map") do |receiver, args, block_node, transpiler|
      if block_node
        param_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        transpiler.with_renames({ param_name => "_" }) do
          block_body = transpiler.visit(block_node.body)
          "#{receiver} |> SELECT #{block_body}"
        end
      else
        "#{receiver} |> SELECT _"
      end
    end

    register("collect") do |receiver, args, block_node, transpiler|
      REGISTRY["map"].call(receiver, args, block_node, transpiler)
    end

    register("select") do |receiver, args, block_node, transpiler|
      if block_node
        param_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        transpiler.with_renames({ param_name => "_" }) do
          block_body = transpiler.visit(block_node.body)
          "#{receiver} |> WHERE #{block_body}"
        end
      else
        receiver
      end
    end

    register("filter") do |receiver, args, block_node, transpiler|
      REGISTRY["select"].call(receiver, args, block_node, transpiler)
    end

    register("reduce") do |receiver, args, block_node, transpiler|
      init_val = args.first || "0"
      if block_node
        acc_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        item_name = block_node.parameters&.parameters&.requireds&.last&.name&.to_s
        transpiler.with_renames({ acc_name => "acc", item_name => "_" }) do
          block_body = transpiler.visit(block_node.body)
          "#{receiver} |> REDUCE(#{init_val}) #{block_body}"
        end
      else
        "#{receiver} |> REDUCE(#{init_val}) acc + _"
      end
    end

    register("inject") do |receiver, args, block_node, transpiler|
      REGISTRY["reduce"].call(receiver, args, block_node, transpiler)
    end

    register("gsub") do |receiver, args, block_node, transpiler|
      "#{receiver}.replace(#{args[0]}, #{args[1]})"
    end

    register("include?") do |receiver, args, block_node, transpiler|
      "#{receiver}.contains?(#{args.join(', ')})"
    end
  end
end
