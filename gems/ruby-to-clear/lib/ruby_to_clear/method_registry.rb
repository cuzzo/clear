# frozen_string_literal: true

module RubyToClear
  module MethodRegistry
    UNSAFE_VALUE_BLOCK_NODES = %w[
      ReturnNode BreakNode NextNode YieldNode SuperNode ForwardingSuperNode
      RescueNode RescueModifierNode EnsureNode
    ].freeze

    CallContext = Struct.new(
      :ruby_name,
      :receiver_code,
      :receiver_kind,
      :receiver_name,
      :receiver_shape,
      :node,
      :transpiler,
      keyword_init: true
    )

    BlockLowering = Struct.new(
      :parameter_names,
      :value_lines,
      :effect_lines,
      :source_location,
      keyword_init: true
    ) do
      def value_code
        return value_lines.first if value_lines.length == 1

        "{\n#{value_lines.join("\n")}\n}"
      end

      def effect_code
        effect_lines.join("\n")
      end

      def multiline_effect?
        effect_lines.length > 1 || effect_lines.any? { |line| line.include?("\n") }
      end
    end

    REGISTRY = {}

    def self.register(ruby_name, receiver: :any, &block)
      REGISTRY[[receiver.to_s, ruby_name.to_s]] = block
    end

    def self.translate(ruby_name, receiver, node, transpiler, receiver_kind: nil, receiver_name: nil, receiver_shape: nil)
      context = CallContext.new(
        ruby_name: ruby_name.to_s,
        receiver_code: receiver,
        receiver_kind: receiver_kind&.to_s,
        receiver_name: receiver_name&.to_s,
        receiver_shape: receiver_shape&.to_s,
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
        REGISTRY[[context.receiver_shape, context.ruby_name]] ||
        (context.receiver_code ? REGISTRY[["any", context.ruby_name]] : nil)
    end

    def self.call_handler(handler, context)
      if handler.arity == 1
        handler.call(context)
      else
        handler.call(context.receiver_code, context.node, context.transpiler)
      end
    end

    def self.unsupported(transpiler, node, message)
      transpiler.unsupported_expression(node, message)
    end

    def self.argument_nodes(context)
      context.node.arguments ? context.node.arguments.arguments : []
    end

    def self.arguments(context)
      argument_nodes(context).map { |arg| context.transpiler.visit(arg) }
    end

    def self.static_first_argument_name(context)
      arg = argument_nodes(context).first
      case arg
      when Prism::ConstantReadNode
        arg.name.to_s
      when Prism::ConstantPathNode
        arg.location.slice.strip
      when Prism::SymbolNode
        arg.value.to_s
      when Prism::StringNode
        arg.content
      end
    end

    def self.regex_node?(node)
      node.is_a?(Prism::RegularExpressionNode) ||
        node.is_a?(Prism::InterpolatedRegularExpressionNode)
    end

    def self.static_call(context, clear_name, min:, max: min)
      args = arguments(context)
      unless args.length >= min && args.length <= max
        expected = min == max ? min.to_s : "#{min}..#{max}"
        return unsupported(context.transpiler, context.node, "#{context.receiver_name}.#{context.ruby_name} expects #{expected} arguments")
      end
      "#{clear_name}(#{args.join(', ')})"
    end

    def self.package_call(context, package, clear_name, min:, max: min, fallible: false)
      args = arguments(context)
      unless args.length >= min && args.length <= max
        expected = min == max ? min.to_s : "#{min}..#{max}"
        return unsupported(context.transpiler, context.node, "#{context.receiver_name}.#{context.ruby_name} expects #{expected} arguments")
      end

      context.transpiler.require_package(package)
      context.transpiler.mark_current_function_fallible! if fallible
      call = "#{clear_name}(#{args.join(', ')})"
      fallible ? "#{call} OR RAISE" : call
    end

    def self.fs_call(context, clear_name, min:, max: min, fallible: false)
      package_call(context, "fs", clear_name, min: min, max: max, fallible: fallible)
    end

    def self.path_call(context, clear_name, min:, max: min)
      package_call(context, "path", clear_name, min: min, max: max)
    end

    def self.unsupported_result?(value)
      value.is_a?(String) && (value.include?("# [UNSUPPORTED:") || value.include?("unsupportedRuby("))
    end

    def self.pipeline_source(receiver)
      receiver.include?(" OR ") ? "(#{receiver})" : receiver
    end

    def self.block_required_parameter_names(node, block_node, transpiler, method_label, min:, max:)
      params = block_node.parameters&.parameters
      requireds = params&.requireds || []

      if params && (params.optionals.any? || params.rest || params.posts.any? ||
                    params.keywords.any? || params.keyword_rest || params.block)
        return unsupported(transpiler, node, "#{method_label} block parameter shape is not supported")
      end

      unless requireds.length >= min && requireds.length <= max
        expected = min == max ? min.to_s : "#{min}..#{max}"
        return unsupported(transpiler, node, "#{method_label} block expects #{expected} required parameters")
      end

      unless requireds.all? { |param| param.respond_to?(:name) }
        return unsupported(transpiler, node, "#{method_label} block parameter destructuring is not supported")
      end

      requireds.map { |param| param.name.to_s }
    end

    def self.pipeline_block_aliases(param_names)
      case param_names.length
      when 0
        {}
      when 1
        { param_names[0] => "_" }
      when 2
        { param_names[0] => "_[0]", param_names[1] => "_[1]" }
      else
        {}
      end
    end

    def self.unsafe_value_block_node(block_node, allow_next: false, allow_yield: false)
      found = nil
      walk = lambda do |node|
        return unless node.is_a?(Prism::Node)
        return if found
        return if node != block_node && node.is_a?(Prism::BlockNode)

        node_name = node.class.name.split("::").last
        if allow_next && node_name == "NextNode"
          node.child_nodes.each { |child| walk.call(child) if child }
          return
        end
        if allow_yield && node_name == "YieldNode"
          node.child_nodes.each { |child| walk.call(child) if child }
          return
        end
        if UNSAFE_VALUE_BLOCK_NODES.include?(node_name)
          found = node_name
          return
        end

        node.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(block_node)
      found
    end

    def self.statement_code?(code)
      code.end_with?(";") || code.end_with?("END") || code.lstrip.start_with?("#")
    end

    def self.statement_line(code)
      statement_code?(code) ? code : "#{code};"
    end

    def self.indent_block_line(code)
      code.split("\n").map { |line| "  #{line}" }.join("\n")
    end

    def self.lower_literal_block(node, block_node, transpiler, method_label, min_params:, max_params:, rename:, allow_next: false, allow_yield: false)
      unless block_node.is_a?(Prism::BlockNode)
        return unsupported(transpiler, node, "Unsupported #{method_label} block type: #{block_node.class.name}")
      end

      param_names = block_required_parameter_names(node, block_node, transpiler, method_label, min: min_params, max: max_params)
      return param_names if unsupported_result?(param_names)

      aliases = rename.call(param_names)
      transpiler.with_block_local_scope do
        transpiler.with_renames(aliases) do
          if (unsafe = unsafe_value_block_node(block_node, allow_next: allow_next, allow_yield: allow_yield))
            next unsupported(transpiler, node, "#{method_label} block contains unsupported #{unsafe}")
          end

          lowering = lower_block_body(block_node, transpiler)
          lowering.parameter_names = param_names if lowering.is_a?(BlockLowering)
          lowering
        end
      end
    end

    def self.lower_block_body(block_node, transpiler)
      body = block_node.body
      unless body.is_a?(Prism::StatementsNode) && body.body.any?
        return unsupported(transpiler, block_node, "Pipeline block must contain at least one expression")
      end

      statements = body.body
      source_location = block_node.location

      rendered = statements.map do |stmt|
        transpiler.visit(stmt)
      end

      value_lines = rendered.map.with_index do |code, index|
        line = index < rendered.length - 1 ? statement_line(code) : code
        indent_block_line(line)
      end

      effect_lines = rendered.map do |code|
        indent_block_line(statement_line(code))
      end

      if statements.length == 1
        value_lines = [rendered.first]
        effect_lines = [statement_line(rendered.first)]
      end

      BlockLowering.new(
        parameter_names: [],
        value_lines: value_lines,
        effect_lines: effect_lines,
        source_location: source_location
      )
    end

    def self.render_block_value(block_node, transpiler)
      lowering = lower_block_body(block_node, transpiler)
      return lowering if unsupported_result?(lowering)

      lowering.value_code
    end

    def self.render_effect_block(lowering)
      if lowering.multiline_effect?
        "{\n#{lowering.effect_code}\n}"
      else
        "{ #{lowering.effect_code} }"
      end
    end

    def self.pipeline_value_stage(receiver, stage_name, node, transpiler, method_label)
      block_body = block_value_expression(receiver, node, transpiler, method_label)
      return block_body if unsupported_result?(block_body)

      "#{pipeline_source(receiver)} |> #{stage_name} #{block_body}"
    end

    def self.pipeline_effect_stage(receiver, source, node, transpiler, method_label)
      lowering = block_effect_lowering(node, transpiler, method_label)
      return lowering if unsupported_result?(lowering)

      "#{pipeline_source(source)} |> EACH #{render_effect_block(lowering)}"
    end

    def self.mutable_receiver?(receiver)
      receiver.match?(/\A[a-z_]\w*\z/)
    end

    def self.static_ruby_type_for_shape(shape)
      case shape.to_s
      when "array" then "Array"
      when "hash" then "Hash"
      when "string" then "String"
      when "symbol" then "Symbol"
      when "nil" then "NilClass"
      when "bool" then "Boolean"
      when "numeric" then "Numeric"
      end
    end

    SHAPE_METHODS = {
      "array" => %w[any? all? collect each empty? filter filter_map find flat_map include? join length map map! reduce reject reverse reverse_each select size sort_by sum],
      "hash" => %w[any? each each_key each_pair each_value empty? include? key? keys length size values],
      "string" => %w[delete_prefix empty? end_with? include? index length lines size split start_with? strip]
    }.freeze

    def self.block_value_lowering(node, transpiler, method_label, min_params: 0, max_params: 2)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "#{method_label} without a block is not supported")
      end

      lower_literal_block(
        node,
        block_node,
        transpiler,
        method_label,
        min_params: min_params,
        max_params: max_params,
        rename: lambda do |param_names|
          pipeline_block_aliases(param_names)
        end
      )
    end

    def self.block_value_expression(receiver, node, transpiler, method_label)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "#{method_label} without a block is not supported")
      end

      if block_node.is_a?(Prism::BlockArgumentNode)
        method_name = block_node.expression.value.to_s
        method_name = "toString" if method_name == "to_s"
        return "_.#{method_name}()"
      end

      lowering = block_value_lowering(node, transpiler, method_label)
      return lowering if unsupported_result?(lowering)

      lowering.value_code
    end

    def self.block_effect_lowering(node, transpiler, method_label, min_params: 0, max_params: 2)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "#{method_label} without a block is not supported")
      end

      lower_literal_block(
        node,
        block_node,
        transpiler,
        method_label,
        min_params: min_params,
        max_params: max_params,
        rename: lambda do |param_names|
          pipeline_block_aliases(param_names)
        end,
        allow_next: true,
        allow_yield: true
      )
    end

    def self.reduce_block_lowering(node, transpiler)
      block_node = node.block
      unless block_node
        return unsupported(transpiler, node, "reduce without a block is not supported")
      end

      lower_literal_block(
        node,
        block_node,
        transpiler,
        "reduce",
        min_params: 2,
        max_params: 2,
        rename: lambda do |param_names|
          { param_names[0] => "acc", param_names[1] => "_" }
        end
      )
    end

    def self.block_expression(receiver, node, transpiler, method_label)
      block_value_expression(receiver, node, transpiler, method_label)
    end

    # --- Registrations ---

    register("read", receiver: "File") do |context|
      fs_call(context, "read", min: 1, max: 1, fallible: true)
    end

    register("readlines", receiver: "File") do |context|
      fs_call(context, "readLines", min: 1, max: 1, fallible: true)
    end

    register("foreach", receiver: "File") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "File.foreach expects 1 argument")
      end

      context.transpiler.require_package("fs")
      context.transpiler.mark_current_function_fallible!
      lines = "readLines(#{args.first}) OR RAISE"
      block_node = context.node.block
      next lines unless block_node

      unless block_node.is_a?(Prism::BlockNode)
        next unsupported(context.transpiler, context.node, "File.foreach block must be a literal block")
      end

      pipeline_effect_stage(lines, lines, context.node, context.transpiler, "File.foreach")
    end

    register("write", receiver: "File") do |context|
      fs_call(context, "write", min: 2, max: 2, fallible: true)
    end

    register("binwrite", receiver: "File") do |context|
      fs_call(context, "write", min: 2, max: 2, fallible: true)
    end

    register("size", receiver: "File") do |context|
      fs_call(context, "size", min: 1, max: 1, fallible: true)
    end

    register("exist?", receiver: "File") do |context|
      fs_call(context, "exists?", min: 1, max: 1)
    end

    register("exists?", receiver: "File") do |context|
      fs_call(context, "exists?", min: 1, max: 1)
    end

    register("file?", receiver: "File") do |context|
      fs_call(context, "file?", min: 1, max: 1)
    end

    register("directory?", receiver: "File") do |context|
      fs_call(context, "dir?", min: 1, max: 1)
    end

    register("delete", receiver: "File") do |context|
      fs_call(context, "delete", min: 1, max: 1, fallible: true)
    end

    register("mtime", receiver: "File") do |context|
      fs_call(context, "mtime", min: 1, max: 1, fallible: true)
    end

    register("readlink", receiver: "File") do |context|
      fs_call(context, "readLink", min: 1, max: 1, fallible: true)
    end

    register("symlink", receiver: "File") do |context|
      fs_call(context, "symlink", min: 2, max: 2, fallible: true)
    end

    register("symlink?", receiver: "File") do |context|
      fs_call(context, "symlink?", min: 1, max: 1)
    end

    register("join", receiver: "File") do |context|
      path_call(context, "join", min: 1, max: 64)
    end

    register("expand_path", receiver: "File") do |context|
      path_call(context, "expand", min: 1, max: 2)
    end

    register("basename", receiver: "File") do |context|
      path_call(context, "basename", min: 1, max: 2)
    end

    register("dirname", receiver: "File") do |context|
      path_call(context, "dirname", min: 1, max: 1)
    end

    register("glob", receiver: "Dir") do |context|
      fs_call(context, "glob", min: 1, max: 1, fallible: true)
    end

    register("exist?", receiver: "Dir") do |context|
      fs_call(context, "dir?", min: 1, max: 1)
    end

    register("exists?", receiver: "Dir") do |context|
      fs_call(context, "dir?", min: 1, max: 1)
    end

    register("children", receiver: "Dir") do |context|
      fs_call(context, "list", min: 1, max: 1, fallible: true)
    end

    register("entries", receiver: "Dir") do |context|
      fs_call(context, "listAll", min: 1, max: 1, fallible: true)
    end

    register("pwd", receiver: "Dir") do |context|
      fs_call(context, "pwd", min: 0, max: 0, fallible: true)
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
      unsupported(context.transpiler, context.node, "Regexp.last_match depends on Ruby's implicit regexp match state; use an explicit match result")
    end

    register("new", receiver: "Regexp") do |context|
      unsupported(context.transpiler, context.node, "Regexp.new is not supported; use explicit scanner or parser logic")
    end

    register("new", receiver: "StringScanner") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "StringScanner.new expects 1 argument")
      end
      "Scanner{ source: #{args.first}, pos: 0 }"
    end

    register("new", receiver: "Set") do |context|
      args = arguments(context)
      if args.empty?
        if context.node.block
          next unsupported(context.transpiler, context.node, "Set.new with a block requires a source enumerable")
        end
        next "Set[]"
      end

      unless args.length == 1
        next unsupported(context.transpiler, context.node, "Set.new expects 0 or 1 arguments")
      end

      source = args.first
      if context.node.block
        projection = block_expression(source, context.node, context.transpiler, "Set.new")
        "#{pipeline_source(source)} |> SELECT #{projection} |> DISTINCT _"
      else
        "#{pipeline_source(source)} |> DISTINCT _"
      end
    end

    register("[]", receiver: "Set") do |context|
      args = arguments(context)
      args.empty? ? "Set[]" : "[#{args.join(', ')}] |> DISTINCT _"
    end

    %w[array string].each do |shape|
      register("length", receiver: shape) do |context|
        "#{context.receiver_code}.length()"
      end

      register("size", receiver: shape) do |context|
        "#{context.receiver_code}.length()"
      end

      register("empty?", receiver: shape) do |context|
        "(#{context.receiver_code}.length() == 0)"
      end
    end

    register("length", receiver: "hash") do |context|
      "#{context.receiver_code}.count()"
    end

    register("size", receiver: "hash") do |context|
      "#{context.receiver_code}.count()"
    end

    register("empty?", receiver: "hash") do |context|
      "(#{context.receiver_code}.count() == 0)"
    end

    register("split", receiver: "string") do |context|
      args = arguments(context)
      separator = args.first || "\"\\n\""
      "#{context.receiver_code}.split(#{separator})"
    end

    register("delete_prefix", receiver: "string") do |context|
      args = arguments(context)
      unless args.length == 1
        next unsupported(context.transpiler, context.node, "delete_prefix expects 1 argument")
      end

      "#{context.receiver_code}.deletePrefix(#{args.first})"
    end

    register("nil?") do |receiver, _node, _transpiler|
      "(#{receiver} == NIL)"
    end

    register("is_a?") do |context|
      expected = static_first_argument_name(context)
      unless expected
        next context.transpiler.unsupported_expression(context.node, "is_a? requires a static type argument")
      end

      receiver = context.receiver_code
      actual = static_ruby_type_for_shape(context.receiver_shape)
      type_param = context.transpiler.current_type_param_for_receiver(context.receiver_name)
      next "#{type_param} IS_A #{context.transpiler.clear_type_expr(expected)}" if type_param

      expected_clear = context.transpiler.clear_type_expr(expected)
      receiver_type = context.transpiler.static_clear_type_for_receiver(context.receiver_name)
      next "TRUE" if receiver_type && receiver_type != "Auto" && receiver_type.to_s == expected_clear
      if receiver_type && context.transpiler.runtime_union_narrowing_candidate?(receiver_type, expected_clear)
        next "#{receiver} IS_A #{expected_clear}"
      end

      next "isA?(#{receiver}, #{expected.inspect})" unless actual

      actual == expected ? "TRUE" : "FALSE"
    end

    register("respond_to?") do |context|
      method_name = static_first_argument_name(context)
      unless method_name
        next context.transpiler.unsupported_expression(context.node, "respond_to? requires a static method name")
      end

      receiver = context.receiver_code
      methods = SHAPE_METHODS[context.receiver_shape.to_s]
      next "respondsTo?(#{receiver}, #{method_name.inspect})" unless methods

      methods.include?(method_name) ? "TRUE" : "FALSE"
    end

    register("strip") do |receiver, _node, _transpiler|
      "#{receiver}.trim()"
    end

    register("to_i") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      unless args.empty?
        next unsupported(transpiler, node, "to_i expects 0 arguments")
      end

      "(#{receiver}.toInt() OR 0)"
    end

    register("match?") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      unless args.length == 1
        next unsupported(transpiler, node, "match? expects 1 argument")
      end

      pattern = transpiler.visit(args.first)
      if regex_node?(args.first)
        "regexMatch?(#{receiver}, #{pattern})"
      else
        "#{receiver}.match?(#{pattern})"
      end
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

    register("map") do |context|
      next nil unless context.node.block || context.receiver_shape == "array"

      pipeline_value_stage(context.receiver_code, "SELECT", context.node, context.transpiler, "map")
    end

    register("map!") do |receiver, node, transpiler|
      unless mutable_receiver?(receiver)
        next unsupported(transpiler, node, "map! is only supported on a mutable local receiver")
      end

      block_body = block_expression(receiver, node, transpiler, "map!")
      next block_body if unsupported_result?(block_body)

      "#{receiver} = #{pipeline_source(receiver)} |> SELECT #{block_body}"
    end

    register("collect") do |context|
      translate(
        "map",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("select") do |receiver, node, transpiler|
      pipeline_value_stage(receiver, "WHERE", node, transpiler, "select")
    end

    register("filter") do |context|
      translate(
        "select",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("reject") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "reject")
      next block_body if unsupported_result?(block_body)

      "#{pipeline_source(receiver)} |> WHERE !(#{block_body})"
    end

    register("any?") do |receiver, node, transpiler|
      if node.block
        pipeline_value_stage(receiver, "ANY", node, transpiler, "any?")
      else
        "#{pipeline_source(receiver)} |> ANY _"
      end
    end

    register("all?") do |receiver, node, transpiler|
      if node.block
        pipeline_value_stage(receiver, "ALL", node, transpiler, "all?")
      else
        "#{pipeline_source(receiver)} |> ALL _"
      end
    end

    register("find") do |receiver, node, transpiler|
      pipeline_value_stage(receiver, "FIND", node, transpiler, "find")
    end

    register("detect") do |context|
      translate(
        "find",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("filter_map") do |receiver, node, transpiler|
      block_body = block_expression(receiver, node, transpiler, "filter_map")
      next block_body if unsupported_result?(block_body)

      "#{pipeline_source(receiver)} |> SELECT #{block_body} |> WHERE _ != NIL"
    end

    register("flat_map") do |receiver, node, transpiler|
      pipeline_value_stage(receiver, "UNNEST", node, transpiler, "flat_map")
    end

    register("sort_by") do |receiver, node, transpiler|
      pipeline_value_stage(receiver, "ORDER_BY", node, transpiler, "sort_by")
    end

    register("sum") do |receiver, node, transpiler|
      if node.block
        pipeline_value_stage(receiver, "SUM", node, transpiler, "sum")
      else
        "#{pipeline_source(receiver)} |> SUM _"
      end
    end

    register("reduce") do |context|
      args = argument_nodes(context)
      if args.empty? && !context.node.block && context.receiver_shape.nil?
        next nil
      end

      init_val = args.first ? context.transpiler.visit(args.first) : "0"
      lowering = reduce_block_lowering(context.node, context.transpiler)
      next lowering if unsupported_result?(lowering)

      "#{pipeline_source(context.receiver_code)} |> REDUCE(#{init_val}) #{lowering.value_code}"
    end

    register("inject") do |context|
      translate(
        "reduce",
        context.receiver_code,
        context.node,
        context.transpiler,
        receiver_kind: context.receiver_kind,
        receiver_name: context.receiver_name,
        receiver_shape: context.receiver_shape
      )
    end

    register("gsub") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      if node.block || args.length != 2
        next unsupported(transpiler, node, "gsub with regex or block is not supported")
      end

      pattern = transpiler.visit(args[0])
      replacement = transpiler.visit(args[1])
      if regex_node?(args[0])
        "regexReplaceAll(#{receiver}, #{pattern}, #{replacement})"
      else
        "#{receiver}.replace(#{pattern}, #{replacement})"
      end
    end

    register("sub") do |receiver, node, transpiler|
      args = node.arguments ? node.arguments.arguments : []
      if node.block || args.length != 2
        next unsupported(transpiler, node, "sub with block or invalid arguments is not supported")
      end

      pattern = transpiler.visit(args[0])
      replacement = transpiler.visit(args[1])
      if regex_node?(args[0])
        "regexReplaceFirst(#{receiver}, #{pattern}, #{replacement})"
      else
        "replaceFirst(#{receiver}, #{pattern}, #{replacement})"
      end
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
      pipeline_effect_stage(receiver, receiver, node, transpiler, "each")
    end

    register("reverse_each") do |receiver, node, transpiler|
      pipeline_effect_stage(receiver, "#{receiver}.reverse()", node, transpiler, "reverse_each")
    end

    register("each_key") do |receiver, node, transpiler|
      pipeline_effect_stage(receiver, "#{receiver}.keys()", node, transpiler, "each_key")
    end

    register("each_value") do |receiver, node, transpiler|
      pipeline_effect_stage(receiver, "#{receiver}.values()", node, transpiler, "each_value")
    end

    register("each_pair") do |_receiver, node, transpiler|
      unsupported(transpiler, node, "each_pair requires pair/destructuring block support")
    end

    register("each_with_index") do |receiver, node, transpiler|
      if node.block
        pipeline_effect_stage(receiver, "#{receiver}.eachWithIndex()", node, transpiler, "each_with_index")
      else
        "#{receiver}.eachWithIndex()"
      end
    end

    register("loop", receiver: "implicit") do |_receiver, node, transpiler|
      unsupported(transpiler, node, "Ruby loop requires exact break/next semantics before lowering")
    end
  end
end
