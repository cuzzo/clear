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

      clear_required_tail = param_infos.rindex do |info|
        info[:default] && !parameter_default_supported?(info[:default])
      end
      max_index = [max_index, clear_required_tail].compact.max

      (0..max_index).map do |idx|
        rendered[idx] || default_argument_for_parameter(param_infos[idx])
      end
    end

    def argument_for_parameter(arg_node, param_info)
      code = visit(arg_node)
      wrap_argument_for_parameter_type(code, arg_node, param_info && param_info[:type])
    end

    def sorbet_must_unwrap_code(value_code, value_type)
      target_type = value_type.to_s.delete_prefix("?")
      if function_clear_type?(target_type)
        return "CAST(#{value_code} AS #{target_type})"
      end

      if target_type.end_with?("@symbol")
        value_type = target_type.delete_suffix("@symbol")
        fallback = value_type.empty? ? 'panic("T.must failed")' : "CAST(panic(\"T.must failed\") AS #{value_type})"
        return "symbol(#{value_code} OR #{fallback})"
      end

      fallback = if target_type.empty?
        'panic("T.must failed")'
      else
        "CAST(panic(\"T.must failed\") AS #{target_type})"
      end
      "(#{value_code} OR #{fallback})"
    end

    def default_argument_for_parameter(param_info)
      code = default_argument_for(param_info)
      wrap_argument_for_parameter_type(code, param_info && param_info[:default], param_info && param_info[:type])
    end

    def wrap_argument_for_parameter_type(code, arg_node, param_type, seen_union_types = [])
      return code unless param_type

      expected = param_type.to_s
      optional_expected = expected.start_with?("?")
      union_type = expected.delete_prefix("?")
      return code if seen_union_types.include?(union_type)

      arg_type = sentinel_type_for_node(arg_node) || inferred_clear_type(arg_node)
      if !optional_expected && arg_type.to_s.start_with?("?") && arg_type.to_s.delete_prefix("?") == expected
        return sorbet_must_unwrap_code(code, arg_type)
      end
      if !@union_types.key?(union_type) &&
         (payload_cast = union_payload_cast_code(code, arg_type, expected))
        return payload_cast
      end

      members = @union_types[union_type]
      return code unless members
      return code if optional_expected && code == "NIL"
      return code if code.start_with?("#{union_type}{")

      return code if arg_type == union_type || arg_type == expected
      if (subset_cast = union_subset_cast_code(code, arg_type, expected))
        return subset_cast
      end

      if optional_expected && arg_type.to_s.start_with?("?")
        inner_type = arg_type.to_s.delete_prefix("?")
        inner_names = type_lookup_names(inner_type)
        optional_member = members.find do |candidate|
          union_member_payload_type_match?(candidate, inner_type, inner_names)
        end
        if optional_member
          variant = union_variant_name(optional_member, union_type)
          helper_suffix = [inner_type, union_type].join("_").gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
          helper = "ruby_wrap_optional_#{helper_suffix}"
          @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
            FN #{helper}(value: ?#{inner_type}) RETURNS ?#{union_type} ->
              IF value AS optional_payload THEN
                RETURN #{union_type}{ #{variant}: COPY optional_payload };
              END
              NIL;
            END
          CLEAR
          return "#{helper}(#{code})"
        end
      end

      arg_type_names = type_lookup_names(arg_type)
      nested_payload = nil
      member = members.find do |candidate|
        if (array_payload = union_array_payload_code(code, arg_node, candidate, arg_type, seen_union_types + [union_type]))
          nested_payload = array_payload
          true
        elsif union_member_payload_type_match?(candidate, arg_type, arg_type_names)
          true
        elsif @union_types[candidate.to_s.delete_prefix("?")]
          wrapped = wrap_argument_for_parameter_type(code, arg_node, candidate, seen_union_types + [union_type])
          if wrapped != code
            nested_payload = wrapped
            true
          else
            false
          end
        else
          false
        end
      end
      return code unless member

      variant = union_variant_name(member, union_type)
      payload = nested_payload || union_payload_code(code, arg_node, member, variant)
      "#{union_type}{ #{variant}: #{payload} }"
    end

    def union_array_payload_code(code, arg_node, candidate, arg_type, seen_union_types)
      candidate_element_type = array_element_clear_type(candidate)
      arg_element_type = array_element_clear_type(arg_type)
      return nil unless candidate_element_type && arg_element_type

      if union_member_payload_type_match?(candidate_element_type, arg_element_type)
        return union_payload_code(code, arg_node, candidate, "ArrayValue")
      end

      wrapped_element = wrap_known_type_code("_", arg_element_type, candidate_element_type, seen_union_types)
      return nil unless wrapped_element && wrapped_element != "_"

      source = code.start_with?("COPY ") ? code.delete_prefix("COPY ") : code
      "#{source} |> SELECT #{wrapped_element}"
    end

    def wrap_known_type_code(code, arg_type, param_type, seen_union_types = [])
      expected = param_type.to_s
      optional_expected = expected.start_with?("?")
      union_type = expected.delete_prefix("?")
      return code if seen_union_types.include?(union_type)

      members = @union_types[union_type]
      return code unless members
      return code if optional_expected && code == "NIL"
      return code if code.start_with?("#{union_type}{")
      return code if arg_type == union_type || arg_type == expected

      arg_type_names = type_lookup_names(arg_type)
      nested_payload = nil
      member = members.find do |candidate|
        if union_member_payload_type_match?(candidate, arg_type, arg_type_names)
          true
        elsif @union_types[candidate.to_s.delete_prefix("?")]
          wrapped = wrap_known_type_code(code, arg_type, candidate, seen_union_types + [union_type])
          if wrapped != code
            nested_payload = wrapped
            true
          else
            false
          end
        else
          false
        end
      end
      return code unless member

      variant = union_variant_name(member, union_type)
      payload = nested_payload || union_payload_code(code, nil, member, variant)
      "#{union_type}{ #{variant}: #{payload} }"
    end

    def union_payload_code(code, arg_node, member, variant)
      arg_type = inferred_clear_type(arg_node).to_s if arg_node
      if arg_type&.start_with?("?") && !member.to_s.start_with?("?")
        code = sorbet_must_unwrap_code(code, arg_type)
      end
      return code if code.start_with?("COPY ")
      return "COPY #{code}" if member.to_s == "String"
      return code if immediate_copy_safe_node?(arg_node)
      return "COPY #{code}" if member.to_s == "String@symbol"
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

    def scalar_identity_type?(type)
      text = type.to_s.delete_prefix("?")
      return true if %w[Bool String@symbol Nil].include?(text)
      return true if text.match?(/\A(?:U?Int|Byte)\d*\z/)

      %w[Float32 Float64].include?(text)
    end

    def union_member_payload_type_match?(candidate, arg_type, arg_type_names = type_lookup_names(arg_type))
      candidate_text = candidate.to_s
      arg_text = arg_type.to_s
      return true if candidate_text == arg_text
      return false if candidate_text.end_with?("[]") != arg_text.end_with?("[]")
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
      if node.receiver.nil? && node.name.to_s == "Array"
        args = node.arguments ? node.arguments.arguments : []
        return visit(args.first) if args.length == 1
      end

      if node.safe_navigation? && !@lowering_safe_navigation.include?(node.object_id)
        unless pure_expression?(node.receiver)
          return unsupported_expression(node, "Safe navigation requires an expression-safe receiver")
        end

        receiver = visit(node.receiver)
        unwrapped = optional_unwrap_code(receiver)
        @lowering_safe_navigation << node.object_id
        inner = with_node_code_override(node.receiver, unwrapped) { visit_call_node(node) }
        @lowering_safe_navigation.delete(node.object_id)
        return "(IF #{receiver} != NIL THEN\n#{indent}  #{inner}\n#{indent}ELSE\n#{indent}  NIL\n#{indent}END)"
      end

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

      if array_concat_call?(node)
        return array_concat_expression_code(node)
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

        extra_args = args.drop(1).map { |arg| expression_argument_code(arg) }
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
            if value_node.is_a?(Prism::LocalVariableReadNode)
              name = value_node.name.to_s
              if value_code == optional_unwrap_code(name)
                return value_code
              end

              if value_type.to_s.start_with?("?") &&
                 !union_like_type?(value_type.to_s.delete_prefix("?"))
                return optional_unwrap_code(name)
              end

              return sorbet_must_unwrap_code(value_code, value_type) if value_type.to_s.start_with?("?")

              if value_type.to_s.start_with?("?") &&
                 @narrowed_optional_storage_locals.include?(name)
                return optional_unwrap_code(name)
              end
            end
            return sorbet_must_unwrap_code(value_code, value_type) if value_type.to_s.start_with?("?")

            return value_code
          end
        end

        if (unwrapped = sorbet_unwrapped_value(node))
          return expression_argument_code(unwrapped)
        end
      end

      if node.name.to_s == "freeze" && (!node.arguments || node.arguments.arguments.empty?)
        return node.receiver ? visit(node.receiver) : ""
      end

      if (pairs_to_hash = array_pairs_to_hash_code(node))
        return pairs_to_hash
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

      if node.name.to_s == "equal?" && node.receiver && node.arguments&.arguments&.length == 1
        argument_node = node.arguments.arguments.first
        argument_type = inferred_clear_type(argument_node).to_s.delete_prefix("?")
        if scalar_identity_type?(argument_type)
          receiver_code = visit(node.receiver)
          argument_code = visit(argument_node)
          receiver_type = inferred_clear_type(node.receiver)
          argument_code = wrap_argument_for_parameter_type(argument_code, argument_node, receiver_type)
          return "(#{receiver_code} == #{argument_code})"
        end
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

        rec_code = node.receiver ? method_call_receiver_expression(node.receiver) : nil
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
      when "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "**", "&&", "||", "&", "|"
        rhs_node = node.arguments.arguments.first
        if ["==", "!="].include?(node.name.to_s) &&
           (safe_comparison = safe_navigation_equality_code(node, rhs_node))
          return safe_comparison
        end
        lhs = visit(node.receiver)
        rhs = visit(rhs_node)
        if node.name.to_s == "%" && inferred_clear_type(node.receiver).to_s.delete_prefix("?") == "String"
          return helper_config.call_or(:string_format, "compilerFormatTemplate", [lhs])
        end
        if node.name.to_s == "*" && inferred_clear_type(node.receiver).to_s.delete_prefix("?") == "String"
          return helper_config.call_or(:string_repeat, "compilerRepeatString", [lhs, rhs])
        end
        lhs = "(#{lhs})" if lhs.include?("|>")
        rhs = "(#{rhs})" if rhs.include?("|>")
        if ["==", "!="].include?(node.name.to_s)
          lhs_type = inferred_clear_type(node.receiver).to_s.delete_prefix("?")
          rhs_type = inferred_clear_type(rhs_node).to_s.delete_prefix("?")
          if @union_types.key?(lhs_type) && !@union_types.key?(rhs_type)
            rhs = wrap_argument_for_parameter_type(rhs, rhs_node, lhs_type)
          elsif @union_types.key?(rhs_type) && !@union_types.key?(lhs_type)
            lhs = wrap_argument_for_parameter_type(lhs, node.receiver, rhs_type)
          end
        end
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
        rhs_node = node.arguments.arguments.first
        rhs = visit(rhs_node)
        rhs = "COPY #{rhs}" if container_index_access_node?(rhs_node)
        method = set_receiver?(node.receiver) ? "insert" : "append"
        "#{method_receiver_code(lhs)}.#{method}(#{rhs})"
      when "fetch"
        lhs = visit(node.receiver)
        arg_nodes = node.arguments ? node.arguments.arguments : []
        return unsupported_expression(node, "fetch requires an index or key") if arg_nodes.empty?
        return unsupported_expression(node, "fetch with a block is not supported") if node.block

        key = visit(arg_nodes.first)
        if arg_nodes.length == 1
          receiver_type = (clear_type_for_receiver_node(node.receiver) || inferred_clear_type(node.receiver)).to_s.delete_prefix("?")
          receiver_type.start_with?("HashMap<") ? "#{lhs}[#{key}]?" : "#{lhs}[#{key}]"
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
        if (field_access = self_struct_field_index_access(node.receiver, arg_nodes))
          field_access
        elsif arg_nodes.length == 1 && arg_nodes.first.is_a?(Prism::RangeNode)
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
          args = if arg_nodes.length == 1 && (key_type = map_key_clear_type(clear_type_for_receiver_node(node.receiver)))
            key_node = arg_nodes.first
            wrap_argument_for_parameter_type(visit(key_node), key_node, key_type)
          else
            visit(node.arguments)
          end
          "#{lhs}[#{args}]"
        end
      when "[]="
        lhs = visit(node.receiver)
        args = node.arguments.arguments
        if (field_name = self_struct_field_index_name(node.receiver, args.first))
          value = expression_argument_code(args.last)
          value = "COPY #{value}" if stored_borrowed_value?(args.last)
          if @current_class
            field_type = @class_instance_field_types[@current_class][field_name]
            value = wrap_argument_for_parameter_type(value, args.last, field_type)
          end
          return "self.#{field_name} = #{value}"
        end
        index = visit(args.first)
        value = expression_argument_code(args.last)
        value = "COPY #{value}" if stored_borrowed_value?(args.last)
        if (value_type = map_value_clear_type(clear_type_for_receiver_node(node.receiver)))
          value = wrap_argument_for_parameter_type(value, args.last, value_type)
        end
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

        rec_code = node.receiver ? method_call_receiver_expression(node.receiver) : nil
        name_str = node.name.to_s
        receiver_type_for_call = if node.receiver
          clear_type_for_receiver_node(node.receiver) || constant_receiver_name(node.receiver)
        elsif @inside_instance_method || @inside_class_method
          @current_class
        elsif @current_class && !@inside_function
          @current_class
        end
        if (struct_with = struct_with_call(node, receiver_type_for_call))
          return struct_with
        end

        setter_owner = if receiver_type_for_call && name_str.end_with?("=")
          instance_method_owner_type(receiver_type_for_call, clear_function_name(name_str))
        end
        if rec_code && name_str.end_with?("=") && setter_owner.nil?
          args = node.arguments ? node.arguments.arguments : []
          return unsupported_expression(node, "Attribute writer calls must have exactly one argument") unless args.length == 1

          field_name = name_str.delete_suffix("=")
          value = expression_argument_code(args.first)
          value = "COPY #{value}" if stored_borrowed_value?(args.first)
          if receiver_type_for_call
            value = wrap_argument_for_parameter_type(value, args.first, class_instance_field_type(receiver_type_for_call, field_name))
          end
          return "#{method_receiver_code(rec_code)}.#{field_name} = #{value}"
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
          node.arguments ? node.arguments.arguments.map { |arg| expression_argument_code(arg) } : []
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
          if receiver_type_for_call.to_s.start_with?("?")
            return unsupported_expression(node, "Proc#call on optional function receivers is not supported; assign T.must(receiver) to a local first")
          end

          # CLEAR accepts calls on parenthesized function expressions, so
          # `factory().call(x)` can remain expression-shaped.
          return "#{rec_code}(#{args_list.join(', ')})"
        end

        clear_name = clear_function_name(name_str)
        if rec_code
          if (self_class = self_class_receiver_name(node.receiver)) &&
             @class_class_method_names[self_class].include?(clear_name)
            return "#{clear_name}(#{args_list.join(', ')})"
          end
          receiver_type = receiver_type_for_call
          if (receiver_class = constant_receiver_name(node.receiver)) &&
             @class_class_method_names[receiver_class].include?(clear_name)
            return "#{clear_name}(#{args_list.join(', ')})"
          end
          if receiver_type
            if (owner_type = instance_method_owner_type(receiver_type, clear_name))
              return "#{instance_function_name(owner_type, name_str)}(#{[rec_code, *args_list].join(', ')})"
            end
            if args_list.empty? && shared_union_field_type(receiver_type, name_str)
              return shared_union_field_access(rec_code, receiver_type, name_str)
            end
            if args_list.empty? && struct_field_reader?(receiver_type, name_str)
              return "#{method_receiver_code(rec_code)}.#{name_str}"
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

        rec = rec_code ? "#{method_receiver_code(rec_code)}." : ""
        args_str = args_list.join(", ")

        call_name = mutable_parameter_function_name?(name_str) ? clear_name : name_str
        "#{rec}#{call_name}(#{args_str})"
      end
    end

    def safe_navigation_equality_code(node, rhs_node)
      safe_node = node.receiver
      return nil unless safe_node.is_a?(Prism::CallNode) && safe_node.safe_navigation?
      return nil unless safe_navigation_static_rhs?(rhs_node)

      rhs_type = inferred_clear_type(rhs_node).to_s
      return nil if rhs_type.empty? || rhs_type == "Any" || rhs_type == "Auto" || rhs_type.start_with?("?")

      receiver = visit(safe_node.receiver)
      unwrapped = optional_unwrap_code(receiver)
      @lowering_safe_navigation << safe_node.object_id
      lhs = with_node_code_override(safe_node.receiver, unwrapped) { visit_call_node(safe_node) }
      @lowering_safe_navigation.delete(safe_node.object_id)
      rhs = visit(rhs_node)

      lhs_type = inferred_clear_type(safe_node).to_s.delete_prefix("?")
      if @union_types.key?(lhs_type) && !@union_types.key?(rhs_type.delete_prefix("?"))
        rhs = wrap_argument_for_parameter_type(rhs, rhs_node, lhs_type)
      end

      if node.name.to_s == "=="
        "((#{receiver} != NIL) && (#{lhs} == #{rhs}))"
      else
        "((#{receiver} == NIL) || (#{lhs} != #{rhs}))"
      end
    ensure
      @lowering_safe_navigation&.delete(safe_node.object_id) if safe_node
    end

    def container_index_access_node?(node)
      node.is_a?(Prism::CallNode) && node.receiver && node.name.to_s == "[]"
    end

    def safe_navigation_static_rhs?(node)
      node.is_a?(Prism::IntegerNode) ||
        node.is_a?(Prism::FloatNode) ||
        node.is_a?(Prism::StringNode) ||
        node.is_a?(Prism::SymbolNode) ||
        node.is_a?(Prism::FalseNode) ||
        node.is_a?(Prism::TrueNode) ||
        node.is_a?(Prism::ConstantReadNode) ||
        node.is_a?(Prism::ConstantPathNode)
    end

    def array_concat_call?(node)
      return false unless node.is_a?(Prism::CallNode)
      return false unless node.receiver && node.name.to_s == "concat" && !node.block

      args = node.arguments ? node.arguments.arguments : []
      return false unless args.length == 1

      !!array_element_clear_type(clear_type_for_receiver_node(node.receiver))
    end

    def array_pairs_to_hash_code(node)
      return nil unless node.receiver && node.name.to_s == "to_h" && !node.block
      return nil unless !node.arguments || node.arguments.arguments.empty?

      receiver_type = clear_type_for_receiver_node(node.receiver).to_s
      return nil unless receiver_type.start_with?("Tuple<") && receiver_type.end_with?(">[]")

      member_types = split_top_level_clear_list(receiver_type.delete_prefix("Tuple<").delete_suffix(">[]"))
      return nil unless member_types.length == 2

      key_type, value_type = member_types.map(&:strip)
      return nil unless ["String", "String@symbol"].include?(key_type)

      result_type = "HashMap<#{key_type}, #{value_type}>"
      helper_suffix = [key_type, value_type].join("_").gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      helper_name = "ruby_pairs_to_hash_#{helper_suffix}"
      @generated_support_helper_defs[helper_name] ||= <<~CLEAR.chomp
        FN #{helper_name}(pairs: #{receiver_type}) RETURNS #{result_type} ->
          MUTABLE result: #{result_type} = {};
          pairs |> EACH { result[COPY _[0]] = COPY _[1]; };
          result;
        END
      CLEAR
      "#{helper_name}(#{method_receiver_code(visit(node.receiver))})"
    end

    def array_concat_expression_code(node)
      receiver_type = clear_type_for_receiver_node(node.receiver).to_s
      helper_suffix = receiver_type.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      helper_name = "ruby_array_concat_#{helper_suffix}"
      @generated_support_helper_defs[helper_name] ||= <<~CLEAR.chomp
        FN #{helper_name}(left: #{receiver_type}, right: #{receiver_type}) RETURNS #{receiver_type} ->
          MUTABLE result: #{receiver_type} = [];
          left |> EACH { result.append(COPY _); };
          right |> EACH { result.append(COPY _); };
          result;
        END
      CLEAR

      arg = node.arguments.arguments.first
      arg_code = expression_argument_code(arg)
      arg_type = inferred_clear_type(arg).to_s
      arg_code = "CAST(#{arg_code} AS #{receiver_type})" unless arg_type == receiver_type
      "#{helper_name}(#{method_receiver_code(visit(node.receiver))}, #{arg_code})"
    end

    def array_concat_statement_code(node)
      receiver = method_receiver_code(visit(node.receiver))
      "#{receiver} = #{array_concat_expression_code(node)}"
    end

    def method_receiver_code(code)
      text = code.to_s
      return text if text.empty?
      return text if text.start_with?("(") && text.end_with?(")")
      return "(#{text})" if text.end_with?("?")
      return text if simple_method_receiver_code?(text)

      "(#{text})"
    end
    public :method_receiver_code

    def method_call_receiver_expression(receiver)
      if sorbet_call?(receiver, "must")
        args = receiver.arguments ? receiver.arguments.arguments : []
        if args.length == 1
          value_node = args.first
          value_type = inferred_clear_type(value_node)
          if value_type.to_s.start_with?("?")
            return sorbet_must_unwrap_code(visit(value_node), value_type)
          end
        end
      end

      visit(receiver)
    end

    def shared_union_field_access(receiver_code, receiver_type, field_name)
      union_name = expand_non_emitted_type_alias(receiver_type).to_s.delete_prefix("?")
      arms = @union_types.fetch(union_name).map do |member|
        variant = union_variant_name(member, union_name)
        "#{union_name}.#{variant} AS item -> item.#{field_name}"
      end
      "(MATCH #{receiver_code} START #{arms.join(', ')} END)"
    end

    def self_struct_field_index_access(receiver, arg_nodes)
      return nil unless arg_nodes.length == 1

      field_name = self_struct_field_index_name(receiver, arg_nodes.first)
      field_name ? "self.#{field_name}" : nil
    end

    def self_struct_field_index_name(receiver, key_node)
      return nil unless receiver.is_a?(Prism::SelfNode)

      field_name = keyword_call_key(key_node)
      return nil unless field_name
      return nil unless @current_instance_field_names.include?(field_name)

      field_name
    end

    def simple_method_receiver_code?(code)
      code.match?(
        /\A[A-Za-z_]\w*[!?]?(?:\[[^\n\]]+\]|\.[A-Za-z_]\w*[!?]?(?:\([^()\n]*\))?)*\z/
      )
    end

    def struct_field_reader?(receiver_type, field_name)
      type_lookup_names(receiver_type).any? do |type_name|
        @class_instance_field_names[type_name].include?(field_name) ||
          Array(@struct_fields[type_name]).include?(field_name)
      end
    end

    def instance_method_owner_type(receiver_type, clear_name)
      type_lookup_names(receiver_type).find do |type_name|
        @class_instance_method_names[type_name].include?(clear_name)
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

    def self_class_receiver_name(node)
      return nil unless @current_class
      return nil unless node.is_a?(Prism::CallNode)
      return nil unless node.name.to_s == "class"
      return nil unless node.receiver.is_a?(Prism::SelfNode)
      return nil unless node.arguments.nil? || node.arguments.arguments.empty?

      @current_class
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
