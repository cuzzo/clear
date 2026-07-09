# frozen_string_literal: true

module RubyToClear
  class Transpiler
    module CallLowerer
    private

    def call_arguments_from_keywords(method_name, arguments_node, class_name = nil)
      param_infos = method_params_for(method_name.to_s, class_name)
      return nil unless param_infos

      arguments_from_keywords(param_infos, arguments_node)
    end

    def arguments_from_keywords(param_infos, arguments_node)
      args = arguments_node ? arguments_node.arguments : []
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      return args.each_with_index.map { |arg, idx| argument_for_parameter(arg, param_infos[idx]) } unless keyword_hash

      positional = args.reject { |arg| arg.equal?(keyword_hash) }
      rendered = []
      rest_index = param_infos.index { |info| info[:kind] == :rest }
      keyword_rest_index = param_infos.index { |info| info[:kind] == :keyword_rest }

      positional.each_with_index do |arg, arg_index|
        if arg.is_a?(Prism::SplatNode)
          return nil unless rest_index

          rendered[rest_index] = argument_for_parameter(arg.expression, param_infos[rest_index])
        elsif rest_index && arg_index >= rest_index
          return nil
        else
          rendered[arg_index] = argument_for_parameter(arg, param_infos[arg_index])
        end
      end
      max_index = rendered.length - 1
      keyword_pairs = []
      keyword_splats = []

      keyword_hash.elements.each do |assoc|
        if assoc.is_a?(Prism::AssocSplatNode)
          return nil unless keyword_rest_index

          keyword_splats << argument_for_parameter(assoc.value, param_infos[keyword_rest_index])
          max_index = [max_index, keyword_rest_index].max
          next
        end
        return nil unless assoc.is_a?(Prism::AssocNode)

        key = keyword_call_key(assoc.key)
        return nil unless key

        index = param_infos.index { |info| info[:name] == key }
        if index
          return nil if index < positional.length

          max_index = [max_index, index].max
          rendered[index] = argument_for_parameter(assoc.value, param_infos[index])
        elsif keyword_rest_index
          keyword_pairs << "#{symbol_hash_key_code(key)}: #{argument_for_parameter(assoc.value, param_infos[keyword_rest_index])}"
          max_index = [max_index, keyword_rest_index].max
        else
          return nil
        end
      end

      if keyword_rest_index
        rendered[keyword_rest_index] = keyword_rest_argument(keyword_pairs, keyword_splats)
      end

      (0..max_index).map do |idx|
        rendered[idx] || default_argument_for_parameter(param_infos[idx])
      end
    end

    def argument_for_parameter(arg_node, param_info)
      code = visit(arg_node)
      wrap_argument_for_parameter_type(code, arg_node, param_info && param_info[:type])
    end

    def default_argument_for_parameter(param_info)
      code = default_argument_for(param_info)
      wrap_argument_for_parameter_type(code, param_info && param_info[:default], param_info && param_info[:type])
    end

    def wrap_argument_for_parameter_type(code, arg_node, param_type)
      return code unless param_type

      expected = param_type.to_s
      optional_expected = expected.start_with?("?")
      union_type = expected.delete_prefix("?")
      members = @union_types[union_type]
      return code unless members
      return code if optional_expected && code == "NIL"
      return code if code.start_with?("#{union_type}{")

      arg_type = sentinel_type_for_node(arg_node) || inferred_clear_type(arg_node)
      return code if arg_type == union_type || arg_type == expected

      arg_type_names = type_lookup_names(arg_type)
      member = members.find do |candidate|
        union_member_payload_type_match?(candidate, arg_type, arg_type_names)
      end
      return code unless member

      variant = union_variant_name(member)
      payload = union_payload_code(code, arg_node, member, variant)
      "#{union_type}{ #{variant}: #{payload} }"
    end

    def union_payload_code(code, arg_node, member, variant)
      return code if code.start_with?("COPY ")
      return "COPY #{code}" if variant == "StringValue"
      return code if immediate_copy_safe_node?(arg_node)
      return code if primitive_union_payload_type?(member)

      "COPY #{code}"
    end

    def primitive_union_payload_type?(type)
      text = type.to_s.delete_prefix("?")
      return true if text == "Bool" || text == "String@symbol"
      return true if text.match?(/\A(?:U?Int|Byte)\d*\z/)
      return true if %w[Float32 Float64].include?(text)

      false
    end

    def union_member_payload_type_match?(candidate, arg_type, arg_type_names = type_lookup_names(arg_type))
      candidate_text = candidate.to_s
      arg_text = arg_type.to_s
      return true if candidate_text == arg_text
      return false if candidate_text.include?("@") || arg_text.include?("@")

      !(type_lookup_names(candidate) & arg_type_names).empty?
    end

    def keyword_rest_argument(keyword_pairs, keyword_splats)
      return "{#{keyword_pairs.join(', ')}}" if keyword_splats.empty?

      base = keyword_splats.first
      return base if keyword_pairs.empty? && keyword_splats.length == 1

      args = []
      args << "{#{keyword_pairs.join(', ')}}" unless keyword_pairs.empty?
      args.concat(keyword_splats)
      "mergeKwargs(#{args.join(', ')})"
    end

    def arguments_with_keyword_hash(arguments_node)
      args = arguments_node ? arguments_node.arguments : []
      keyword_hash = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
      return args.map { |arg| visit(arg) } unless keyword_hash

      positional = args.reject { |arg| arg.equal?(keyword_hash) }.map { |arg| visit(arg) }
      positional + [visit(keyword_hash)]
    end

    def keyword_call_key(node)
      case node
      when Prism::SymbolNode
        node.value.to_s
      when Prism::StringNode
        node.content
      end
    end

    def default_argument_for(param_info)
      return nil unless param_info
      return "[]" if param_info[:kind] == :rest
      return "{}" if param_info[:kind] == :keyword_rest
      return visit(param_info[:default]) if param_info[:default]

      nil
    end

    # --- Node Visitors ---

    def visit_call_node(node)
      keyword_arg = keyword_hash_argument(node.arguments)

      if ruby_raise_call?(node)
        return ruby_raise_code(node)
      end

      if private_class_method_def_call?(node)
        def_code = visit(node.arguments.arguments.first)
        return def_code.sub(/\AFN /, "PRIVATE FN ")
      end

      if (rspec_code = translate_rspec_call(node))
        return rspec_code
      end

      if ruby_scaffolding_call?(node)
        return ""
      end

      if same_class_constructor_call?(node)
        constructor = constructor_from_arguments(node.receiver, node.arguments)
        return constructor if constructor

        constructor_call = constructor_call_from_keywords(node.receiver, node.arguments)
        return constructor_call if constructor_call

        constructor_call = constructor_call_from_positional(node.receiver, node.arguments)
        return constructor_call if constructor_call
      end

      if %w[send __send__ public_send].include?(node.name.to_s)
        args = node.arguments ? node.arguments.arguments : []
        return unsupported_expression(node, "#{node.name} requires at least a method name") if args.empty?

        receiver = node.receiver ? visit(node.receiver) : "self"
        method_name = static_send_method_name(args.first)
        unless method_name
          return unsupported_expression(node, "#{node.name} requires a static symbol or string method name")
        end

        extra_args = args.drop(1).map { |arg| visit(arg) }
        return "#{receiver}.#{method_name}(#{extra_args.join(', ')})"
      end

      if (reason = dynamic_ruby_call_reason(node.name.to_s))
        return unsupported_expression(node, "#{node.name} is a Ruby dynamic/reflection call: #{reason}")
      end

      if sorbet_call?(node)
        return "" if node.name.to_s == "bind"

        if node.name.to_s == "cast" && (cast_code = sorbet_cast_expression(node))
          return cast_code
        end

        if node.name.to_s == "must"
          args = node.arguments ? node.arguments.arguments : []
          if args.length == 1
            value_node = args.first
            value_code = visit(value_node)
            value_type = inferred_clear_type(value_node)
            return "#{value_code}?" if value_type.to_s.start_with?("?")
            if value_node.is_a?(Prism::LocalVariableReadNode)
              name = value_node.name.to_s
              if value_code == optional_unwrap_code(name) &&
                 !@current_param_names.include?(name) &&
                 @narrowed_optional_storage_locals.include?(name)
                return name
              end
            end

            return value_code
          end
        end

        if (unwrapped = sorbet_unwrapped_value(node))
          return visit(unwrapped)
        end
      end

      if node.name.to_s == "freeze" && (!node.arguments || node.arguments.arguments.empty?)
        return node.receiver ? visit(node.receiver) : ""
      end

      if node.name.to_s == "equal?" &&
         node.receiver &&
         node.arguments&.arguments&.length == 1 &&
         (sentinel_type = sentinel_type_for_node(node.arguments.arguments.first))
        receiver_code = visit(node.receiver)
        if optional_sentinel_union_receiver?(node.receiver, sentinel_type)
          return "((#{receiver_code} != NIL) && (#{optional_unwrap_code(receiver_code)} IS_A #{sentinel_type}))"
        end

        return "#{receiver_code} IS_A #{sentinel_type}"
      end

      if node.receiver.nil? && node.name.to_s == "loop" && node.block
        return render_ruby_loop(node)
      end

      if node.receiver.nil? && node.name.to_s == "lambda" && node.block
        return block_to_lambda(node.block)
      end

      if node.name.to_s == "gsub" || node.name.to_s == "sub"
        if (unsupported_reason = unsupported_gsub_sub_reason(node))
          return unsupported_expression(node, unsupported_reason)
        end

        rec_code = node.receiver ? visit(node.receiver) : nil
        if rec_code
          translated = MethodRegistry.translate(
            node.name.to_s,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated && !MethodRegistry.unsupported_result?(translated)
        end
        return unsupported_expression(node, "gsub/sub with dynamic regex, block, or invalid arguments is not supported")
      end

      case node.name.to_s
      when "!"
        "!(#{visit(node.receiver)})"
      when "-@"
        "(-#{visit(node.receiver)})"
      when "+@"
        "(+#{visit(node.receiver)})"
      when "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "&&", "||", "&", "|"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "(#{lhs} #{node.name} #{rhs})"
      when "=~"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        regex_match_code(lhs, rhs)
      when "!~"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "!(#{regex_match_code(lhs, rhs)})"
      when "<<"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        method = set_receiver?(node.receiver) ? "insert" : "append"
        "#{lhs}.#{method}(#{rhs})"
      when "fetch"
        lhs = visit(node.receiver)
        arg_nodes = node.arguments ? node.arguments.arguments : []
        return unsupported_expression(node, "fetch requires an index or key") if arg_nodes.empty?
        return unsupported_expression(node, "fetch with a block is not supported") if node.block

        key = visit(arg_nodes.first)
        if arg_nodes.length == 1
          "#{lhs}[#{key}]"
        elsif arg_nodes.length == 2
          "(#{lhs}[#{key}] OR #{visit(arg_nodes[1])})"
        else
          unsupported_expression(node, "fetch supports at most a default value")
        end
      when "[]"
        if node.receiver
          lhs = visit(node.receiver)
          translated = MethodRegistry.translate(
            node.name.to_s,
            lhs,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated
        end
        lhs = visit(node.receiver)
        arg_nodes = node.arguments ? node.arguments.arguments : []
        if arg_nodes.length == 1 && arg_nodes.first.is_a?(Prism::RangeNode)
          range = arg_nodes.first
          start = range.left ? visit(range.left) : "0"
          if range.right
            finish = visit(range.right)
            length_expr = range.exclude_end? ? "(#{finish} - #{start})" : "((#{finish} - #{start}) + 1)"
            "#{lhs}.substr(#{start}, #{length_expr})"
          else
            "#{lhs}.substr(#{start}, (#{lhs}.length() - #{start}))"
          end
        elsif arg_nodes.length == 1 && string_receiver?(node.receiver)
          "#{lhs}.substr(#{visit(arg_nodes.first)}, 1)"
        elsif arg_nodes.length == 2
          start = visit(arg_nodes[0])
          length = visit(arg_nodes[1])
          "#{lhs}.substr(#{start}, #{length})"
        else
          args = visit(node.arguments)
          "#{lhs}[#{args}]"
        end
      when "[]="
        lhs = visit(node.receiver)
        index = visit(node.arguments.arguments.first)
        value = visit(node.arguments.arguments.last)
        "#{lhs}[#{index}] = #{value}"
      else
        if constant_constructor_call?(node)
          rec_code = visit(node.receiver)
          if keyword_arg
            constructor = constructor_from_arguments(node.receiver, node.arguments)
            return constructor if constructor

            constructor_call = constructor_call_from_keywords(node.receiver, node.arguments)
            return constructor_call if constructor_call

            return unsupported_expression(keyword_arg, "Keyword arguments are not supported for this constructor")
          end

          translated = MethodRegistry.translate(
            node.name.to_s,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated

          constructor = constructor_from_arguments(node.receiver, node.arguments)
          return constructor if constructor

          constructor_call = constructor_call_from_positional(node.receiver, node.arguments)
          return constructor_call if constructor_call

          return unsupported_expression(node, "Constructor call needs known field names")
        end

        rec_code = node.receiver ? visit(node.receiver) : nil
        name_str = node.name.to_s
        receiver_type_for_call = if node.receiver
          clear_type_for_receiver_node(node.receiver) || constant_receiver_name(node.receiver)
        elsif @inside_instance_method || @inside_class_method
          @current_class
        end
        if (struct_with = struct_with_call(node, receiver_type_for_call))
          return struct_with
        end

        if rec_code && name_str.end_with?("=")
          args = node.arguments ? node.arguments.arguments : []
          return unsupported_expression(node, "Attribute writer calls must have exactly one argument") unless args.length == 1

          return "#{rec_code}.#{name_str.delete_suffix('=')} = #{visit(args.first)}"
        end

        args_list = if keyword_arg
          mapped = call_arguments_from_keywords(name_str, node.arguments, receiver_type_for_call)
          if mapped && mapped.none?(&:nil?)
            mapped
          else
            arguments_with_keyword_hash(node.arguments)
          end
        elsif (param_infos = method_params_for(name_str, receiver_type_for_call))
          node.arguments ? node.arguments.arguments.each_with_index.map { |arg, idx| argument_for_parameter(arg, param_infos[idx]) } : []
        else
          node.arguments ? node.arguments.arguments.map { |arg| visit(arg) } : []
        end

        if rec_code
          translated = MethodRegistry.translate(
            name_str,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: registry_receiver_shape(node.receiver)
          )
          return translated if translated
        else
          translated = MethodRegistry.translate(
            name_str,
            nil,
            node,
            self,
            receiver_kind: "implicit",
            receiver_name: nil,
            receiver_shape: nil
          )
          return translated if translated
        end

        if node.block
          args_list << block_to_lambda(node.block)
        end

        if rec_code && name_str == "call" && function_like_clear_type?(receiver_type_for_call)
          unless rec_code.match?(/\A[A-Za-z_]\w*\z/)
            return unsupported_expression(node, "Proc#call on expression receivers is not supported; assign the function to a local first")
          end
          if receiver_type_for_call.to_s.start_with?("?")
            return unsupported_expression(node, "Proc#call on optional function receivers is not supported; assign T.must(receiver) to a local first")
          end

          return "#{rec_code}(#{args_list.join(', ')})"
        end

        clear_name = clear_function_name(name_str)
        if rec_code
          receiver_type = receiver_type_for_call
          if (receiver_class = constant_receiver_name(node.receiver)) &&
             @class_class_method_names[receiver_class].include?(clear_name)
            return "#{clear_name}(#{args_list.join(', ')})"
          end
          if receiver_type
            if args_list.empty? && struct_field_reader?(receiver_type, name_str)
              return "#{rec_code}.#{name_str}"
            end
            if @class_instance_method_names[receiver_type].include?(clear_name)
              return "#{instance_function_name(receiver_type, name_str)}(#{[rec_code, *args_list].join(', ')})"
            end
          end
          if (receiver_module = module_function_receiver_name(node.receiver)) &&
             @module_function_names[receiver_module].include?(clear_name)
            return "#{clear_name}(#{args_list.join(', ')})"
          end
        elsif @inside_instance_method
          if args_list.empty? && @current_instance_field_names.include?(name_str)
            return "self.#{name_str}"
          end
          if @current_instance_method_names.include?(clear_name)
            return "#{instance_function_name(@current_class, name_str)}(#{['self', *args_list].join(', ')})"
          end
        end

        rec = rec_code ? "#{rec_code}." : ""
        args_str = args_list.join(", ")

        "#{rec}#{name_str}(#{args_str})"
      end
    end

    def struct_field_reader?(receiver_type, field_name)
      type_lookup_names(receiver_type).any? do |type_name|
        @class_instance_field_names[type_name].include?(field_name) ||
          Array(@struct_fields[type_name]).include?(field_name)
      end
    end

    def class_instance_field_type(receiver_type, field_name)
      type_lookup_names(receiver_type).each do |type_name|
        field_type = @class_instance_field_types[type_name][field_name.to_s]
        return field_type if field_type
      end

      nil
    end

    def type_lookup_names(type)
      text = type.to_s.delete_prefix("?")
      return [] if text.empty?

      base = text.split("@").first.to_s.delete_suffix("[]")
      names = [text, base]
      names << base.tr(".", "::") if base.include?(".")
      names << base.split("::").last if base.include?("::")
      names << base.split(".").last if base.include?(".")
      names.uniq.reject(&:empty?)
    end

    def constant_receiver_name(node)
      return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      name = node.location.slice.strip
      candidates = [name]
      candidates << name.split("::").last if name.include?("::")
      candidates.find { |candidate| @class_class_method_names.key?(candidate) }
    end

    def module_function_receiver_name(node)
      return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      name = node.location.slice.strip
      candidates = [name]
      candidates << name.split("::").last if name.include?("::")
      candidates.find { |candidate| @module_function_names.key?(candidate) }
    end
    end
  end
end
