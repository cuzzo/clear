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

    def self.argument_nodes(context)
      context.node.arguments ? context.node.arguments.arguments : []
    end

    def self.arguments(context)
      argument_nodes(context).map { |arg| context.transpiler.visit(arg) }
    end

    def self.static_call(context, clear_name, min:, max: min)
      args = arguments(context)
      unless args.length >= min && args.length <= max
        expected = min == max ? min.to_s : "#{min}..#{max}"
        return context.transpiler.raise_unsupported("#{context.receiver_name}.#{context.ruby_name} expects #{expected} arguments", context.node)
      end
      "#{clear_name}(#{args.join(', ')})"
    end

    def self.block_expression(receiver, node, transpiler, method_label)
      block_node = node.block
      unless block_node
        transpiler.raise_unsupported("#{method_label} without a block is not supported", node)
      end

      if block_node.is_a?(Prism::BlockArgumentNode)
        method_name = block_node.expression.value.to_s
        method_name = "toString" if method_name == "to_s"
        "_.#{method_name}()"
      elsif block_node.is_a?(Prism::BlockNode)
        unless transpiler.simple_block_expression?(block_node)
          transpiler.raise_unsupported("#{method_label} block must be a single expression", node)
        end
        param_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
        transpiler.with_renames({ param_name => "_" }) do
          transpiler.visit(block_node.body.body.first)
        end
      else
        transpiler.raise_unsupported("Unsupported #{method_label} block type: #{block_node.class.name}", node)
      end
    end

    # --- Registrations ---

    register("read", receiver: "File") do |context|
      static_call(context, "readFile", min: 1)
    end

    register("readlines", receiver: "File") do |context|
      args = arguments(context)
      unless args.length == 1
        next context.transpiler.raise_unsupported("File.readlines expects 1 argument", context.node)
      end
      "readFile(#{args.first}).split(\"\\n\")"
    end

    register("foreach", receiver: "File") do |context|
      args = arguments(context)
      unless args.length == 1
        next context.transpiler.raise_unsupported("File.foreach expects 1 argument", context.node)
      end

      lines = "readFile(#{args.first}).split(\"\\n\")"
      block_node = context.node.block
      return lines unless block_node

      unless block_node.is_a?(Prism::BlockNode)
        next context.transpiler.raise_unsupported("File.foreach block must be a literal block", context.node)
      end

      param_name = block_node.parameters&.parameters&.requireds&.first&.name&.to_s
      context.transpiler.with_renames({ param_name => "_" }) do
        "#{lines} |> EACH { #{context.transpiler.visit(block_node.body)} }"
      end
    end

    register("write", receiver: "File") do |context|
      static_call(context, "writeFile", min: 2, max: 2)
    end

    register("binwrite", receiver: "File") do |context|
      static_call(context, "writeFile", min: 2, max: 2)
    end

    register("size", receiver: "File") do |context|
      static_call(context, "fileSize", min: 1, max: 1)
    end

    register("exist?", receiver: "File") do |context|
      static_call(context, "fileExists?", min: 1, max: 1)
    end

    register("exists?", receiver: "File") do |context|
      static_call(context, "fileExists?", min: 1, max: 1)
    end

    register("file?", receiver: "File") do |context|
      static_call(context, "regularFile?", min: 1, max: 1)
    end

    register("delete", receiver: "File") do |context|
      static_call(context, "deleteFile", min: 1, max: 1)
    end

    register("mtime", receiver: "File") do |context|
      static_call(context, "fileModifiedTime", min: 1, max: 1)
    end

    register("readlink", receiver: "File") do |context|
      static_call(context, "readLink", min: 1, max: 1)
    end

    register("symlink", receiver: "File") do |context|
      static_call(context, "createSymlink", min: 2, max: 2)
    end

    register("symlink?", receiver: "File") do |context|
      static_call(context, "symlinkExists?", min: 1, max: 1)
    end

    register("join", receiver: "File") do |context|
      static_call(context, "joinPath", min: 1, max: 64)
    end

    register("expand_path", receiver: "File") do |context|
      static_call(context, "expandPath", min: 1, max: 2)
    end

    register("basename", receiver: "File") do |context|
      static_call(context, "baseName", min: 1, max: 2)
    end

    register("dirname", receiver: "File") do |context|
      static_call(context, "dirName", min: 1, max: 1)
    end

    register("glob", receiver: "Dir") do |context|
      static_call(context, "globPaths", min: 1, max: 1)
    end

    register("exist?", receiver: "Dir") do |context|
      static_call(context, "dirExists?", min: 1, max: 1)
    end

    register("exists?", receiver: "Dir") do |context|
      static_call(context, "dirExists?", min: 1, max: 1)
    end

    register("children", receiver: "Dir") do |context|
      static_call(context, "listDir", min: 1, max: 1)
    end

    register("entries", receiver: "Dir") do |context|
      static_call(context, "listAll", min: 1, max: 1)
    end

    register("pwd", receiver: "Dir") do |context|
      static_call(context, "currentDirectory", min: 0, max: 0)
    end

    register("parse", receiver: "JSON") do |context|
      static_call(context, "parseJson", min: 1, max: 1)
    end

    register("generate", receiver: "JSON") do |context|
      static_call(context, "generateJson", min: 1, max: 1)
    end

    register("pretty_generate", receiver: "JSON") do |context|
      static_call(context, "prettyGenerateJson", min: 1, max: 1)
    end

    register("escape", receiver: "Regexp") do |context|
      static_call(context, "escapeRegex", min: 1, max: 1)
    end

    register("last_match", receiver: "Regexp") do |context|
      context.transpiler.raise_unsupported("Regexp.last_match depends on Ruby's implicit regexp match state; use an explicit match result", context.node)
    end

    register("new", receiver: "Regexp") do |context|
      context.transpiler.raise_unsupported("Regexp.new is not supported; use explicit scanner or parser logic", context.node)
    end

    register("new", receiver: "StringScanner") do |context|
      args = arguments(context)
      unless args.length == 1
        next context.transpiler.raise_unsupported("StringScanner.new expects 1 argument", context.node)
      end
      "Scanner{ source: #{args.first}, pos: 0 }"
    end

    register("new", receiver: "Set") do |context|
      args = arguments(context)
      if args.empty?
        if context.node.block
          next context.transpiler.raise_unsupported("Set.new with a block requires a source enumerable", context.node)
        end
        next "Set[]"
      end

      unless args.length == 1
        next context.transpiler.raise_unsupported("Set.new expects 0 or 1 arguments", context.node)
      end

      source = args.first
      if context.node.block
        projection = block_expression(source, context.node, context.transpiler, "Set.new")
        "#{source} |> SELECT #{projection} |> DISTINCT _"
      else
        "#{source} |> DISTINCT _"
      end
    end

    register("[]", receiver: "Set") do |context|
      args = arguments(context)
      args.empty? ? "Set[]" : "[#{args.join(', ')}] |> DISTINCT _"
    end

    register("strip") do |receiver, _node, _transpiler|
      "#{receiver}.trim()"
    end

    register("start_with?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{receiver}.startsWith?(#{args.join(', ')})"
    end

    register("end_with?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{receiver}.endsWith?(#{args.join(', ')})"
    end

    register("index") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      "#{receiver}.indexOf(#{args.join(', ')})"
    end

    register("lines") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      separator = args.first || "\"\\n\""
      "#{receiver}.split(#{separator})"
    end

    register("join") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments.map { |a| transpiler.visit(a) } : []
      separator = args.first || "\"\""
      "#{receiver}.join(#{separator})"
    end

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

    register("reject") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "reject")
      "#{receiver} |> WHERE !(#{block_body})"
    end

    register("any?") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "any?")
      "#{receiver} |> ANY #{block_body}"
    end

    register("all?") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "all?")
      "#{receiver} |> ALL #{block_body}"
    end

    register("find") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "find")
      "#{receiver} |> FIND #{block_body}"
    end

    register("detect") do |context|
      translate(
        "find",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name
      )
    end

    register("filter_map") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "filter_map")
      "#{receiver} |> SELECT #{block_body} |> WHERE _ != NIL"
    end

    register("flat_map") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "flat_map")
      "#{receiver} |> UNNEST #{block_body}"
    end

    register("sort_by") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "sort_by")
      "#{receiver} |> ORDER_BY #{block_body}"
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
