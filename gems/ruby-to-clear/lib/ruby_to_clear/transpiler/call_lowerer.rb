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
      code = wrap_argument_for_parameter_type(code, arg_node, param_info && param_info[:type])
      param_info && param_info[:mutable] ? mutable_argument_code(code) : code
    end

    # CLEAR correctly rejects `f(&self, self.field)`: the mutable borrow of
    # the aggregate overlaps a second argument derived from it. Ruby evaluates
    # arguments before entering the callee, so preserve those semantics by
    # snapshotting conflicting argument expressions before taking the mutable
    # receiver borrow.
    def materialize_mutable_receiver_alias_arguments(receiver, arguments)
      path = receiver.to_s.delete_prefix("&")
      return [arguments, []] unless mutable_storage_path?(path)

      reference = /(?<![A-Za-z0-9_])#{Regexp.escape(path)}(?=\z|[.\[])/
      setup = []
      rendered = arguments.map do |argument|
        next argument unless argument.to_s.match?(reference)

        temporary = next_generated_local("mutable_alias_arg")
        # A plain binding can preserve the borrow provenance of a field/view
        # expression, leaving the aggregate RESTRICTed when the mutable call
        # begins. Ruby has already evaluated and retained the argument at this
        # point, so materialize an independent value before borrowing the
        # receiver.
        setup << "MUTABLE #{temporary} = COPY #{argument};"
        temporary
      end
      [rendered, setup]
    end

    def wrap_call_after_argument_setup(call, setup)
      return call if setup.empty?

      "{ MUTABLE rtoc_value_block_marker = 0; #{setup.join(' ')}\n#{call} }"
    end

    def sorbet_must_unwrap_code(value_code, value_type, expected_type = nil)
      target_type = expected_type ? expected_type.to_s.delete_prefix("?") : value_type.to_s.delete_prefix("?")
      if target_type.match?(/\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)+\z/)
        target_type = clear_type_expr(target_type)
      end
      unwrapped = "UNWRAP (#{value_code})"
      if function_clear_type?(target_type)
        return "CAST(#{unwrapped} AS #{target_type})"
      end

      if target_type.end_with?("@symbol")
        return "symbol(#{unwrapped})"
      end

      unwrapped
    end

    def default_argument_for_parameter(param_info)
      code = default_argument_for(param_info)
      wrap_argument_for_parameter_type(code, param_info && param_info[:default], param_info && param_info[:type])
    end

    def wrap_argument_for_parameter_type(code, arg_node, param_type, seen_union_types = [])
      return code unless param_type

      param_type_str = param_type.to_s
      optional_param = param_type_str.start_with?("?")
      base_param = param_type_str.delete_prefix("?")
      resolved = type_alias_for_path(base_param) || type_alias_for_name(base_param) || @type_aliases[base_param]
      # A synthesized union can intentionally reuse the Ruby alias name (most
      # notably AST::Node). Once emitted, that union is the parameter type;
      # resolving the source alias again would incorrectly collapse it to its
      # marker module such as Locatable.
      expected = if @union_types.key?(base_param)
        base_param
      elsif resolved
        resolved.to_s
      else
        clear_type_expr(base_param)
      end
      expected = optional_param ? optional_clear_type(expected) : expected

      if expected.to_s.include?("@multiowned") &&
         (match = code.to_s.match(/\ACAST\((rubyToClearTypeFromFunctionSignature\(.+\)) AS Type\)\z/m))
        return match[1]
      end

      contextual_array_type = expected.sub(/@(?:multiowned|shared)\z/, "")
      if arg_node.is_a?(Prism::ArrayNode) && contextual_array_type.end_with?("[]")
        if arg_node.elements.empty?
          empty_name = next_generated_local("empty_list")
          return "( { MUTABLE #{empty_name}: #{contextual_array_type} = List[]; #{empty_name} } )"
        end

        element_type = contextual_array_type.delete_suffix("[]")
        if arg_node.elements.any?(Prism::SplatNode)
          segments = []
          literal_elements = []
          flush_literals = lambda do
            next if literal_elements.empty?

            segments << "CAST([#{literal_elements.join(', ')}] AS #{contextual_array_type})"
            literal_elements.clear
          end
          arg_node.elements.each do |element|
            if element.is_a?(Prism::SplatNode)
              flush_literals.call
              expression = element.expression
              segment = expression_argument_code(expression)
              segment = "COPY #{segment}" if stored_borrowed_value?(expression) && !segment.start_with?("COPY ")
              segments << segment
            else
              element_code = expression_argument_code(element)
              wrapped = wrap_argument_for_parameter_type(element_code, element, element_type, seen_union_types)
              literal_elements << (element_type == "Any" ? "CAST(#{wrapped} AS Any)" : wrapped)
            end
          end
          flush_literals.call
          return segments.first if segments.one?

          return "(#{segments.join(' + ')})"
        end

        elements = arg_node.elements.map do |element|
          element_code = expression_argument_code(element)
          wrapped = wrap_argument_for_parameter_type(element_code, element, element_type, seen_union_types)
          # CLEAR validates a list literal's element homogeneity before it
          # applies the surrounding parameter type.  A Ruby T::Array[T.untyped]
          # can therefore contain (for example) both Any and Any[] only when
          # every element is explicitly erased to Any first.
          element_type == "Any" ? "CAST(#{wrapped} AS Any)" : wrapped
        end
        return "[#{elements.join(', ')}]"
      end

      if arg_node.is_a?(Prism::HashNode) || arg_node.is_a?(Prism::KeywordHashNode)
        typed_hash = typed_hash_literal_code(arg_node, expected)
        return typed_hash if typed_hash
      end

      optional_expected = expected.start_with?("?")
      union_type = expected.delete_prefix("?")
      return code if seen_union_types.include?(union_type)

      arg_type = sentinel_type_for_node(arg_node) || inferred_clear_type(arg_node)
      semantic_arg_type = if arg_node.is_a?(Prism::CallNode) &&
                             (call = @typed_ir.call_for(arg_node))
        call.result_type_identity || call.return_type&.to_clear || arg_type
      else
        arg_type
      end
      semantic_resolved = type_alias_for_path(semantic_arg_type) ||
        type_alias_for_name(semantic_arg_type) || @type_aliases[semantic_arg_type.to_s]
      semantic_union = semantic_resolved.to_s.delete_prefix("?")
      if @union_types.key?(semantic_union)
        # A getter can deliberately expose a union even when its backing field
        # has a concrete structural type. Trust the resolved call contract;
        # wrapping that already-unioned result again produces an invalid union
        # payload (for example FsmOpsExpr.StateField(FsmOpsExpr)).
        arg_type = semantic_resolved.to_s
        semantic_arg_type = semantic_resolved.to_s
      end
      if arg_node && (arg_node.class.name.end_with?("WriteNode") ||
                      (arg_node.is_a?(Prism::CallNode) && (arg_node.name.to_s == "[]=" || arg_node.name.to_s.end_with?("="))))
        parsed = Prism.parse(code.to_s).value.statements.body.first rescue nil
        arg_type = inferred_clear_type(parsed) if parsed
        semantic_arg_type = arg_type
      end
      # `COPY x` is still a read of x, so a narrowed binding's type has to win
      # here too - otherwise the un-narrowed optional type from the AST node
      # survives and re-adds an UNWRAP the EXISTS AS guard already performed.
      if (narrowed_name = code.to_s[/\A(?:COPY )?([A-Za-z_]\w*)\z/, 1])
        narrowed_type = static_clear_type_for_receiver(narrowed_name)
        arg_type = narrowed_type if narrowed_type && !["Auto", "Any"].include?(narrowed_type.to_s)
      end
      arg_nonoptional_base = arg_type.to_s.delete_prefix("?").split("@").first
      expected_nonoptional_base = expected.to_s.delete_prefix("?").split("@").first
      expected_owned = expected.to_s.include?("@multiowned") || expected.to_s.include?("@shared")
      argument_owned = arg_type.to_s.include?("@multiowned") || arg_type.to_s.include?("@shared")
      if argument_owned && !expected_owned && arg_nonoptional_base == expected_nonoptional_base
        materialized = if stored_borrowed_value?(arg_node) && !code.to_s.start_with?("COPY ")
          "COPY #{code}"
        else
          code
        end
        return "CAST(#{materialized} AS #{expected})"
      end
      if expected.to_s.start_with?("?") && !arg_type.to_s.start_with?("?") &&
         arg_nonoptional_base == expected_nonoptional_base &&
         (expected.to_s.include?("@multiowned") || expected.to_s.include?("@shared"))
        capability = expected.to_s.include?("@multiowned") ? "multiowned" : "shared"
        # Retained identity v4: keep-analysis normalizes plain values into
        # @multiowned destinations at the call edge (retain/move/wrap), so
        # the native emission is the plain value - no COPY, no helper.
        return code if capability == "multiowned"
        helper_suffix = [arg_nonoptional_base, "to_optional", capability].join("_").gsub(/[^A-Za-z0-9]+/, "_")
        helper = "ruby_wrap_#{helper_suffix}"
        @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
          FN #{helper}(value: #{arg_nonoptional_base}) RETURNS ?#{arg_nonoptional_base}@#{capability} ->
            RETURN COPY value;
          END
        CLEAR
        return "#{helper}(#{code})"
      end
      if arg_type.to_s.start_with?("?") && expected.to_s.start_with?("?")
        arg_base = arg_type.to_s.delete_prefix("?").split("@").first
        expected_base = expected.to_s.delete_prefix("?").split("@").first
        if arg_base == expected_base && @aliasable_classes&.include?(arg_base)
          is_expected_owned = expected.to_s.include?("@multiowned") || expected.to_s.include?("@shared")
          is_arg_owned = arg_type.to_s.include?("@multiowned") || arg_type.to_s.include?("@shared")
          if is_expected_owned && !is_arg_owned
            cap_sigil = expected.to_s.include?("@multiowned") ? "@multiowned" : "@shared"
            # Keep-analysis owns the @multiowned edge; emit the plain value.
            return code if cap_sigil == "@multiowned"
            helper_suffix = "#{arg_base}_to_owned"
            helper = "ruby_wrap_optional_#{helper_suffix}"
            @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
              FN #{helper}(value: ?#{arg_base}) RETURNS ?#{arg_base}#{cap_sigil} ->
                IF value EXISTS AS value_value THEN
                  RETURN COPY value_value;
                END
                NIL;
              END
            CLEAR
            return "#{helper}(#{code})"
          end
        end
      end

      if expected.to_s.include?("@shared") &&
         !arg_type.to_s.include?("@multiowned") && !arg_type.to_s.include?("@shared") &&
         @typed_ir.value_for(arg_node)&.access != :owned &&
         !code.to_s.start_with?("COPY ") && code.to_s != "NIL"
        code = "COPY #{code}"
      end
      if (arg_type.to_s == "String" || arg_type.to_s == "?String") && (expected.to_s == "String@symbol" || expected.to_s == "?String@symbol")
        if arg_type.to_s == "String"
          return "symbol(#{code})"
        else
          helper_suffix = "string_to_symbol"
          helper = "ruby_wrap_optional_#{helper_suffix}"
          @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
            FN #{helper}(value: ?String) RETURNS ?String@symbol ->
              IF value EXISTS AS value_value THEN
                RETURN symbol(value_value);
              END
              NIL;
            END
          CLEAR
          return "#{helper}(#{code})"
        end
      end
      if (arg_type.to_s == "String@symbol" || arg_type.to_s == "?String@symbol") && (expected.to_s == "String" || expected.to_s == "?String")
        if arg_type.to_s == "String@symbol"
          return "CAST(#{code} AS String)"
        else
          helper_suffix = "symbol_to_string"
          helper = "ruby_wrap_optional_#{helper_suffix}"
          @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
            FN #{helper}(value: ?String@symbol) RETURNS ?String ->
              IF value EXISTS AS value_value THEN
                RETURN CAST(value_value AS String);
              END
              NIL;
            END
          CLEAR
          return "#{helper}(#{code})"
        end
      end

      arg_base = arg_type.to_s.delete_prefix("?").split("@").first
      expected_base = expected.to_s.delete_prefix("?").split("@").first
      if !optional_expected && arg_type.to_s.start_with?("?") && arg_base == expected_base
        return sorbet_must_unwrap_code(code, arg_type, expected)
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
        optional_interface_member = union_interface_member(members, inner_type)
        optional_member ||= optional_interface_member
        if optional_member
          variant = union_variant_name(optional_member, union_type)
          payload = if optional_member == optional_interface_member
            "COPY CAST(optional_payload AS #{clear_type_expr(optional_member)})"
          else
            wrapped_payload = wrap_known_type_code("optional_payload", inner_type, optional_member, seen_union_types + [union_type])
            wrapped_payload == "optional_payload" ? "COPY optional_payload" : wrapped_payload
          end
          emitted_inner_type = if inner_type.match?(/\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)+\z/)
            clear_type_expr(inner_type)
          else
            inner_type
          end
          helper_suffix = [inner_type, union_type].join("_").gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
          helper = "ruby_wrap_optional_#{helper_suffix}"
          @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
            FN #{helper}(value: ?#{emitted_inner_type}) RETURNS ?#{union_type} ->
              IF value EXISTS AS optional_payload THEN
                RETURN #{union_type}{ #{variant}: #{payload} };
              END
              NIL;
            END
          CLEAR
          return "#{helper}(#{code})"
        end
      end

      arg_type_names = type_lookup_names(semantic_arg_type)
      member = members.find do |candidate|
        union_member_payload_type_match?(candidate, semantic_arg_type, arg_type_names)
      end
      interface_member = union_interface_member(members, semantic_arg_type.to_s.delete_prefix("?"))
      member ||= interface_member
      if member
        variant = union_variant_name(member, union_type)
        payload = if member == interface_member
          "COPY CAST(#{code} AS #{clear_type_expr(member)})"
        else
          union_payload_code(code, arg_node, member, variant)
        end
        return "#{union_type}{ #{variant}: #{payload} }"
      end

      nested_payload = nil
      member = members.find do |candidate|
        if (array_payload = union_array_payload_code(code, arg_node, candidate, arg_type, seen_union_types + [union_type]))
          nested_payload = array_payload
          true
        elsif candidate.to_s == "String@symbol" && (arg_type == "String" || arg_type == "?String")
          nested_payload = wrap_argument_for_parameter_type(code, arg_node, candidate, seen_union_types + [union_type])
          true
        elsif candidate.to_s == "String" && (arg_type == "String@symbol" || arg_type == "?String@symbol")
          nested_payload = wrap_argument_for_parameter_type(code, arg_node, candidate, seen_union_types + [union_type])
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

    def union_interface_member(members, concrete_type)
      concrete_names = type_lookup_names(concrete_type)
      includes = concrete_names.flat_map { |name| transitive_includes(name) }.uniq
      members.find do |candidate|
        candidate_names = type_lookup_names(candidate)
        (candidate_names & includes).any?
      end
    end

    def union_array_payload_code(code, arg_node, candidate, arg_type, seen_union_types)
      candidate_element_type = array_element_clear_type(candidate)
      arg_element_type = array_element_clear_type(arg_type)
      return nil unless candidate_element_type && arg_element_type

      if candidate_element_type.to_s.split("@").first == "Any"
        erased = "CAST(#{code} AS #{candidate})"
        return union_payload_code(erased, arg_node, candidate, "ArrayValue")
      end

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

      if @union_types[arg_type.to_s.delete_prefix("?")] &&
         (subset_cast = union_subset_cast_code(code, arg_type, expected))
        return subset_cast
      end

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
      candidate_text = candidate.to_s.end_with?("@symbol") ? candidate.to_s : (candidate.to_s.split("@").first || "")
      arg_text = arg_type.to_s.end_with?("@symbol") ? arg_type.to_s : (arg_type.to_s.split("@").first || "")
      return true if candidate_text == arg_text
      return false if candidate_text.end_with?("[]") != arg_text.end_with?("[]")

      !(type_lookup_names(candidate_text) & type_lookup_names(arg_text)).empty?
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
      if (with_object = each_with_object_expression(node))
        return with_object
      end
      if (indexed_with_object = indexed_enumerator_with_object(node))
        return indexed_with_object
      end
      if (indexed_enumerator = indexed_enumerator_value_chain(node))
        return indexed_enumerator
      end

      return "{}" if hash_new_call?(node)
      if (anonymous_struct = anonymous_struct_constructor(node))
        return anonymous_struct
      end
      if (or_write = parenthesized_index_or_write(node.receiver)) && %w[<< add append].include?(node.name.to_s)
        args = node.arguments&.arguments || []
        if args.length == 1
          receiver = visit(or_write.receiver)
          indexes = or_write.arguments&.arguments || []
          if indexes.length == 1
            index = visit(indexes.first)
            lhs = "#{receiver}[#{index}]"
            default = expression_argument_code(or_write.value)
            value = expression_argument_code(args.first)
            set_default = or_write.value.is_a?(Prism::CallNode) &&
              or_write.value.receiver.is_a?(Prism::ConstantReadNode) &&
              or_write.value.receiver.name.to_s == "Set"
            method = set_default || set_like_clear_type?(inferred_clear_type(or_write.value)) ? "insert" : "append"
            return "IF #{lhs} == NIL THEN\n#{indent}  #{lhs} = #{default};\n#{indent}END\n#{optional_unwrap_code(lhs)}.#{method}(#{value});"
          end
        end
      end

      if node.receiver.nil? && node.name.to_s == "Array"
        args = node.arguments ? node.arguments.arguments : []
        return visit(args.first) if args.length == 1
      end

      if node.name.to_s == "puts" && node.receiver.is_a?(Prism::GlobalVariableReadNode) &&
         %w[$stderr $stdout].include?(node.receiver.name.to_s)
        args = node.arguments&.arguments || []
        return "print(#{args.map { |arg| expression_argument_code(arg) }.join(', ')})"
      end

      if node.safe_navigation? && !@lowering_safe_navigation.include?(node.object_id)
        if (field_fact = @typed_ir.field_for(node))
          receiver = method_receiver_code(visit(node.receiver))
          code = "#{receiver}?.#{field_fact.field.name}"
          if field_fact.field_type.capability == "symbol"
            helper = "ruby_wrap_optional_string_to_symbol"
            @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
              FN #{helper}(value: ?String) RETURNS ?String@symbol ->
                IF value EXISTS AS value_value THEN
                  RETURN symbol(value_value);
                END
                NIL;
              END
            CLEAR
            return "#{helper}(#{code})"
          end
          return %w[multiowned shared].include?(field_fact.field_type.capability) ? "KEEP #{code}" : code
        end

        receiver_fact = @typed_ir.value_for(node.receiver)
        if receiver_fact && !receiver_fact.type.unresolved? && !receiver_fact.type.optional
          @lowering_safe_navigation << node.object_id
          begin
            return visit_call_node(node)
          ensure
            @lowering_safe_navigation.delete(node.object_id)
          end
        end

        if node.receiver.is_a?(Prism::CallNode) && node.receiver.safe_navigation?
          nested_call = node.receiver
          base = visit(nested_call.receiver)
          @lowering_safe_navigation << nested_call.object_id
          nested_value = with_node_code_override(nested_call.receiver, optional_unwrap_code(base)) do
            visit_call_node(nested_call)
          end
          @lowering_safe_navigation.delete(nested_call.object_id)
          @lowering_safe_navigation << node.object_id
          present_value = with_node_code_override(nested_call, nested_value) { visit_call_node(node) }
          @lowering_safe_navigation.delete(node.object_id)
          return "(IF #{base} != NIL THEN\n#{indent}  #{present_value}\n#{indent}ELSE\n#{indent}  NIL\n#{indent}END)"
        end

        unless pure_expression?(node.receiver)
          return unsupported_expression(node, "Safe navigation requires an expression-safe receiver")
        end

        receiver = visit(node.receiver)
        unwrapped = optional_unwrap_code(receiver)
        @lowering_safe_navigation << node.object_id
        inner = with_node_code_override(node.receiver, unwrapped) { visit_call_node(node) }
        @lowering_safe_navigation.delete(node.object_id)
        if node.name.to_s == "map!"
          inner = inner.sub(/\A#{Regexp.escape(unwrapped)}\s*=/, "#{receiver} =")
        end
        if node.block && %w[each each_with_index reverse_each each_key each_value each_pair].include?(node.name.to_s)
          inner = format_statement_code(inner)
          body = inner.lines.map { |line| "#{indent}  #{line}" }.join
          return "IF #{receiver} != NIL THEN\n#{body}\n#{indent}END"
        end
        semantic_call = @typed_ir.call_for(node)
        if semantic_call&.receiver_ownership == :borrow_mut &&
           semantic_call.return_type&.to_clear == "Void"
          inner = format_statement_code(inner)
          body = inner.lines.map { |line| "#{indent}  #{line}" }.join
          return "IF #{receiver} != NIL THEN\n#{body}\n#{indent}END"
        end
        return "(IF #{receiver} != NIL THEN\n#{indent}  #{inner}\n#{indent}ELSE\n#{indent}  NIL\n#{indent}END)"
      end

      if (distributed = union_field_dispatch_distribution(node))
        return distributed
      end

      keyword_arg = keyword_hash_argument(node.arguments)

      if ruby_raise_call?(node)
        return ruby_raise_code(node)
      end

      if (macro_code = closed_attribute_macro_call(node))
        return macro_code
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

      if node.receiver.nil? && node.name.to_s == "alias_method"
        return alias_method_call_code(node)
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

        if (visitor_dispatch = dynamic_visitor_send_code(node, args))
          return visitor_dispatch
        end
        if (writer_dispatch = dynamic_attribute_writer_send_code(node, args))
          return writer_dispatch
        end

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
            if scanner_scan_value_node?(value_node)
              return sorbet_must_unwrap_code(value_code, "?String")
            end
            value_type = inferred_clear_type(value_node)
            if value_node.is_a?(Prism::CallNode) && value_node.name.to_s == "[]" &&
               value_node.receiver
              receiver_type = clear_type_for_receiver_node(value_node.receiver)
              indexed_type = array_element_clear_type(receiver_type) ||
                map_value_clear_type(receiver_type)
              value_type = optional_clear_type(indexed_type) if indexed_type
            end
            return value_code if @active_narrowed_binding_names.include?(value_code)
            narrowed_value_type = static_clear_type_for_receiver(value_code)
            if narrowed_value_type && !narrowed_value_type.to_s.start_with?("?")
              return value_code
            end
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

      if node.name.to_s == "to_f" && node.receiver &&
         inferred_clear_type(node.receiver).to_s.delete_prefix("?").match?(/\A(?:U?Int\d*|Byte\d*|Float\d*)\z/)
        return "#{method_receiver_code(visit(node.receiver))}.toFloat()"
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
          # After the nil guard, CLEAR's AND-narrowing types the receiver as
          # the payload; a redundant `?` unwrap is rejected there.
          return "((#{receiver_code} != NIL) AND (#{receiver_code} IS_A #{sentinel_type}))"
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

      substitution_args = node.arguments&.arguments || []
      if (node.name.to_s == "gsub" || node.name.to_s == "sub") &&
         (node.block || substitution_args.length == 2)
        if node.name.to_s == "gsub" && node.block && substitution_args.length == 1 &&
           regex_pattern_expression?(substitution_args.first) &&
           (replacement = regex_gsub_block_code(node, substitution_args.first))
          return replacement
        end

        if node.name.to_s == "gsub" && substitution_args.length == 1 &&
           literal_replacement_expression?(substitution_args.first) &&
           (replacement = literal_replacement_block_expression(node.block))
          receiver = method_call_receiver_expression(node.receiver)
          pattern = visit(substitution_args.first)
          return "#{method_receiver_code(receiver)}.replace(#{pattern}, #{replacement})"
        end

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
        inferred_clear_type(node.receiver).to_s.delete_prefix("?") == "String" ? visit(node.receiver) : "(+#{visit(node.receiver)})"
      when "==", "!=", "<", "<=", ">", ">=", "+", "-", "*", "/", "%", "**", "&&", "||", "&", "|", "^", ">>"
        rhs_node = node.arguments.arguments.first
        if node.name.to_s == "|" && inferred_clear_type(node.receiver).to_s.end_with?("@set")
          return set_union_expression_code(node.receiver, rhs_node)
        end
        left_operator_type = inferred_clear_type(node.receiver).to_s
        right_operator_type = inferred_clear_type(rhs_node).to_s
        if node.name.to_s == "&" && [left_operator_type, right_operator_type].any? do |type|
             type.end_with?("@set") || type.end_with?("[]")
           end
          return set_intersection_expression_code(node.receiver, rhs_node)
        end
        if ["==", "!="].include?(node.name.to_s) &&
           (safe_comparison = safe_navigation_equality_code(node, rhs_node))
          return safe_comparison
        end
        if ["==", "!="].include?(node.name.to_s) &&
           (union_comparison = union_scalar_equality_code(node, rhs_node))
          return union_comparison
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
        if node.name.to_s == "+" && left_operator_type.delete_prefix("?") == "String"
          return "(#{lhs} $+ #{rhs})"
        end
        "(#{lhs} #{clear_binary_operator(node.name)} #{rhs})"
      when "=~"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        regex_match_code(lhs, rhs)
      when "!~"
        lhs = visit(node.receiver)
        rhs = visit(node.arguments.arguments.first)
        "!(#{regex_match_code(lhs, rhs)})"
      when "<<"
        receiver_type = clear_type_for_receiver_node(node.receiver) || @typed_ir.value_for(node.receiver)&.type&.to_clear
        if receiver_type.to_s.delete_prefix("?").split("@").first.to_s.match?(/\A(?:U?Int|Byte)\d*\z/)
          return "(#{visit(node.receiver)} << #{visit(node.arguments.arguments.first)})"
        end
        if (slot_statement = map_slot_mutation_statement(node))
          return slot_statement
        end
        if (append_chain = string_append_chain(node))
          return append_chain
        end
        lhs = visit(node.receiver)
        rhs_node = node.arguments.arguments.first
        rhs = visit(rhs_node)
        preserves_string_value = registry_receiver_shape(node.receiver) == "string" &&
          !immediate_copy_safe_node?(rhs_node)
        renamed_index_borrow = rhs_node.is_a?(Prism::LocalVariableReadNode) &&
          @renames[rhs_node.name.to_s].to_s.include?("[")
        semantic_value = @typed_ir.value_for(rhs_node)
        typed_borrow = semantic_value&.access == :borrowed && copyable_storage_type?(semantic_value.type.to_clear)
        storage_ownership = @typed_ir.storage_ownership_for(node)
        typed_storage_copy = storage_ownership&.mode == :copy
        typed_storage_retain = storage_ownership&.mode == :retain
        needs_copy = container_index_access_node?(rhs_node) || renamed_index_borrow || preserves_string_value ||
          (!typed_storage_retain && typed_borrow) || typed_storage_copy
        # A borrowed source needs the COPY before the element-type wrap runs,
        # not after: the wrap's optional-unwrap branch only adds UNWRAP, so
        # COPY-after-wrap and COPY-suppressed-by-having-wrapped both leave a
        # bare borrow passed to a TAKES `insert`/`append` param. COPY first
        # gives `UNWRAP (COPY x)`, and wrap_argument_for_parameter_type's own
        # ownership-upgrade branches already guard on a leading "COPY " to
        # avoid doubling it.
        rhs = "COPY #{rhs}" if needs_copy && !rhs.start_with?("COPY ")
        if typed_storage_retain && retained_identity_source?(rhs_node)
          rhs = "KEEP #{rhs}" unless rhs.start_with?("KEEP ")
        end
        # container_element_clear_type is the array_element_clear_type
        # superset: also understands `[Set]T` / `T@set`, so a Set<<-append
        # gets the same "?T at the read, T at the container" coercion an
        # array append already did.
        element_type = container_element_clear_type(receiver_type)
        element_type ||= receiver_type.to_s.delete_suffix("[]") if receiver_type.to_s.end_with?("[]")
        rhs = wrap_argument_for_parameter_type(rhs, rhs_node, element_type) if element_type
        # CLEAR strings grow by reassign-concat; String has no in-place append.
        if registry_receiver_shape(node.receiver) == "string"
          rhs = wrap_argument_for_parameter_type(rhs, rhs_node, "String")
          return "#{lhs} = (#{lhs} $+ #{rhs})"
        end
        method = set_receiver?(node.receiver) ? "insert" : "append"
        "#{mutable_method_receiver_code(lhs)}.#{method}(#{rhs})"
      when "fetch"
        lhs = visit(node.receiver)
        lhs = method_receiver_code(lhs) if lhs.start_with?("CAST(")
        arg_nodes = node.arguments ? node.arguments.arguments : []
        return unsupported_expression(node, "fetch requires an index or key") if arg_nodes.empty?
        if node.block
          parameters = node.block.parameters&.parameters
          has_parameters = parameters && parameters.child_nodes.compact.any?
          unless !has_parameters && arg_nodes.length == 1
            return unsupported_expression(node, "fetch fallback blocks must be parameterless and receive one key")
          end
          key = visit(arg_nodes.first)
          fallback = MethodRegistry.render_block_value(node.block, self)
          return fallback if MethodRegistry.unsupported_result?(fallback)
          return "(#{lhs}[#{key}] OR_ELSE #{fallback})"
        end

        key = visit(arg_nodes.first)
        if arg_nodes.length == 1
          receiver_type = (clear_type_for_receiver_node(node.receiver) || inferred_clear_type(node.receiver)).to_s.delete_prefix("?")
          if receiver_type.start_with?("HashMap<") && !receiver_type.end_with?("[]")
            "#{lhs}[#{key}]?"
          else
            # Ruby's no-default `fetch` RAISES when the index is missing, so
            # its result is not optional - which is exactly what the type
            # inference already reports. Emitting a bare indexed read
            # contradicted that (indexing yields an optional in CLEAR) and the
            # frontend rejected the binding with "Cannot infer `x` from an
            # optional value". UNWRAP restores the non-optional type and keeps
            # the raise-on-missing contract. (The `OR_ELSE CAST(panic(...) AS
            # T)` idiom the hash reads use miscompiles here - it emits Zig
            # "unreachable code" for a struct element type, verified directly.)
            # An already-optional element type (`[]?String`) needs no unwrap:
            # the indexed read is `?String` either way, which is exactly what
            # fetch's own result type is - unwrapping would over-strip it.
            element_type = array_element_clear_type(clear_type_for_receiver_node(node.receiver)).to_s
            if element_type.start_with?("?")
              "#{lhs}[#{key}]"
            else
              "UNWRAP (#{lhs}[#{key}])"
            end
          end
        elsif arg_nodes.length == 2
          "(#{lhs}[#{key}] OR_ELSE #{visit(arg_nodes[1])})"
        else
          unsupported_expression(node, "fetch supports at most a default value")
        end
      when "[]"
        if node.receiver
          lhs = visit(node.receiver)
          arg_nodes = node.arguments ? node.arguments.arguments : []
          if (semantic_field = @typed_ir.field_for(node))
            require_type_dependency(semantic_field.receiver_type.to_clear)
            return lower_typed_ir_field_call(node, lhs, semantic_field)
          end
          if (field_access = struct_field_index_access(node.receiver, arg_nodes, lhs))
            return field_access
          end
          receiver_type = clear_type_for_receiver_node(node.receiver)
          tuple_type = receiver_type.to_s.delete_prefix("?")
          if tuple_type.start_with?("Tuple<") && tuple_type.end_with?(">")
            unless arg_nodes.length == 1 && arg_nodes.first.is_a?(Prism::IntegerNode)
              return unsupported_expression(node, "Tuple access requires one literal position; CLEAR tuples use ._0, ._1, and so on")
            end
            position = arg_nodes.first.value
            members = split_top_level_clear_list(tuple_type.delete_prefix("Tuple<").delete_suffix(">"))
            if position.negative? || position >= members.length
              return unsupported_expression(node, "Tuple position #{position} is outside 0...#{members.length}")
            end
            return "#{method_receiver_code(lhs)}._#{position}"
          end
          if receiver_type && (owner_type = instance_method_owner_type(receiver_type, "get_index"))
            args = node.arguments ? node.arguments.arguments.map { |arg| expression_argument_code(arg) } : []
            return "#{instance_function_name(owner_type, "[]")}(#{[lhs, *args].join(', ')})"
          end
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
        if arg_nodes.length == 1 &&
           clear_type_for_receiver_node(node.receiver).to_s.delete_prefix("?") == "CompilerRegexScanner"
          # Ruby `matchdata[n]` is capture group n of the match.
          return "compilerRegexCapture(#{lhs}, #{visit(arg_nodes.first)})"
        end
        if arg_nodes.length == 1 && arg_nodes.first.is_a?(Prism::RangeNode)
          range = arg_nodes.first
          start = range.left ? visit(range.left) : "0"
          if range.right
            finish = visit(range.right)
            # Ruby range ends may be negative (offsets from the end):
            # str[3..-4] means end index len - 4. Normalize statically for
            # literal negatives; dynamic ends stay positive-only (matching
            # every current compiler-source use).
            if range.right.is_a?(Prism::IntegerNode) && range.right.value.negative?
              finish = "(#{lhs}.length() - #{range.right.value.abs})"
            end
            length_expr = range.exclude_end? ? "(#{finish} - #{start})" : "((#{finish} - #{start}) + 1)"
            "#{lhs}.substr(#{start}, #{length_expr})"
          else
            "#{lhs}.substr(#{start}, (#{lhs}.length() - #{start}))"
          end
        elsif arg_nodes.length == 1 && regex_pattern_expression?(arg_nodes.first)
          # Ruby `str[/re/]` is the whole first match (or nil), not a substring.
          "compilerRegexFirstMatch(#{lhs}, #{visit(arg_nodes.first)})"
        elsif arg_nodes.length == 2 && regex_pattern_expression?(arg_nodes.first)
          # Ruby `str[/re/, n]` is capture group n of the first match.
          "compilerRegexMatchGroup(#{lhs}, #{visit(arg_nodes.first)}, #{visit(arg_nodes[1])})"
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
          "#{method_receiver_code(lhs)}[#{args}]"
        end
      when "[]="
        lhs = visit(node.receiver)
        args = node.arguments.arguments
        storage_ownership = @typed_ir.storage_ownership_for(node)
        storage_retain = storage_ownership&.mode == :retain
        storage_copy = storage_ownership&.mode == :copy
        if (field_name = struct_field_index_name(node.receiver, args.first))
          value = expression_argument_code(args.last)
          value = "COPY #{value}" if (storage_copy || (!storage_retain && stored_borrowed_value?(args.last))) &&
            !value.start_with?("COPY ")
          field_type = class_instance_field_type(clear_type_for_receiver_node(node.receiver), field_name)
          if storage_retain && retained_identity_source?(args.last)
            value = "KEEP #{value}" unless value.start_with?("KEEP ")
          end
          value = wrap_argument_for_parameter_type(value, args.last, field_type) if field_type
          return "#{method_receiver_code(lhs)}.#{field_name} = #{value}"
        end
        receiver_type = clear_type_for_receiver_node(node.receiver)
          if receiver_type && (owner_type = instance_method_owner_type(receiver_type, "set_index"))
          rendered_args = args.map { |arg| expression_argument_code(arg) }
          return "#{instance_function_name(owner_type, "[]=")}(#{[mutable_argument_code(lhs), *rendered_args].join(', ')})"
        end
        index = visit(args.first)
        value = expression_argument_code(args.last)
        value = "COPY #{value}" if (storage_copy || (!storage_retain && stored_borrowed_value?(args.last))) &&
          !value.start_with?("COPY ")
        if (value_type = map_value_clear_type(clear_type_for_receiver_node(node.receiver)))
          if storage_retain && retained_identity_source?(args.last)
            value = "KEEP #{value}" unless value.start_with?("KEEP ")
          end
          value = wrap_argument_for_parameter_type(value, args.last, value_type)
        end
        unless lhs.match?(/\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\z/)
          receiver = next_generated_local("index_receiver")
          return "MUTABLE #{receiver} = #{lhs};\n#{receiver}[#{index}] = #{value}"
        end
        "#{lhs}[#{index}] = #{value}"
      else
        if constant_constructor_call?(node)
          require_type_dependency(constructor_receiver_class_name(node.receiver) || constructor_output_name(node.receiver))
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
        semantic_field = @typed_ir.field_for(node)
        semantic_call = @typed_ir.call_for(node)
        receiver_type_for_call = if node.receiver
          narrowed_receiver = if node.receiver.is_a?(Prism::LocalVariableReadNode) &&
                                 @renames.key?(node.receiver.name.to_s)
            clear_type_for_receiver_node(node.receiver)
          end
          narrowed_receiver || semantic_field&.receiver_type&.to_clear ||
            semantic_call&.receiver_type&.to_clear || clear_type_for_receiver_node(node.receiver) ||
            constant_receiver_name(node.receiver) || module_function_receiver_name(node.receiver)
        elsif @inside_instance_method || @inside_class_method
          @current_class
        elsif @current_class && !@inside_function
          @current_class
        end
        if (struct_with = struct_with_call(node, receiver_type_for_call))
          return struct_with
        end

        if semantic_field
          require_type_dependency(semantic_field.receiver_type.to_clear)
          return lower_typed_ir_field_call(node, rec_code || "self", semantic_field)
        end

        # Sorbet can resolve `T::Array[Element]#any?` to an `Element#any?`
        # method when the element class defines the same name. The receiver's
        # collection shape is authoritative here: a literal block on an
        # array-valued receiver is Enumerable ANY/ALL, not an element method.
        receiver_shape = registry_receiver_shape(node.receiver)
        if rec_code && node.block && receiver_shape == "array" && %w[any? all?].include?(name_str)
          translated = MethodRegistry.translate(
            name_str,
            rec_code,
            node,
            self,
            receiver_kind: registry_receiver_kind(node.receiver),
            receiver_name: registry_receiver_name(node.receiver),
            receiver_shape: receiver_shape
          )
          return translated if translated
        end

        setter_owner = if receiver_type_for_call && name_str.end_with?("=")
          instance_method_owner_type(receiver_type_for_call, clear_function_name(name_str))
        end
        class_setter_owner = if name_str.end_with?("=")
          self_class_receiver_name(node.receiver) || constant_receiver_name(node.receiver)
        end
        class_setter = class_setter_owner &&
          @class_class_method_names[class_setter_owner].include?(clear_function_name(name_str))
        if rec_code && name_str.end_with?("=") && setter_owner.nil? && !class_setter
          args = node.arguments ? node.arguments.arguments : []
          return unsupported_expression(node, "Attribute writer calls must have exactly one argument") unless args.length == 1

          field_name = name_str.delete_suffix("=")
          value = expression_argument_code(args.first)
          value = "COPY #{value}" if stored_borrowed_value?(args.first)
          target_field_type = nil
          writer_receiver_type = receiver_type_for_call || clear_type_for_receiver_node(node.receiver)
          if writer_receiver_type
            target_field_type = class_instance_field_type(writer_receiver_type, field_name) ||
              shared_union_field_type(writer_receiver_type, field_name)
            value = wrap_argument_for_parameter_type(value, args.first, target_field_type)
          end
          target_field_type ||= inferred_if_assignment_type(args.first) if args.first.is_a?(Prism::IfNode)
          receiver_code = method_receiver_code(rec_code)
          if writer_receiver_type &&
             (union_assignment = shared_union_field_write(
               receiver_code,
               writer_receiver_type,
               field_name,
               value,
               args.first,
               target_field_type
             ))
            return union_assignment
          end
          prefix = nil
          unless simple_method_receiver_code?(rec_code)
            temp = next_generated_local("writer_receiver")
            receiver_type = receiver_type_for_call.to_s
            typed = ["", "Any", "Auto"].include?(receiver_type) ? "" : ": #{receiver_type}"
            prefix = "MUTABLE #{temp}#{typed} = #{rec_code};"
            receiver_code = temp
          end
          if args.first.is_a?(Prism::IfNode) && target_field_type && affine_clear_type?(target_field_type)
            assignment = if_assignment_code("#{receiver_code}.#{field_name}", args.first, target_field_type)
            return prefix ? "#{prefix}\n#{assignment}" : assignment
          end
          if args.first.is_a?(Prism::CallNode) && args.first.safe_navigation?
            safe_call = args.first
            safe_receiver = visit(safe_call.receiver)
            narrowed_receiver = flow_narrowable_optional_receiver?(safe_call.receiver) ?
              safe_receiver : optional_unwrap_code(safe_receiver)
            @lowering_safe_navigation << safe_call.object_id
            present_value = with_node_code_override(safe_call.receiver, narrowed_receiver) do
              visit_call_node(safe_call)
            end
            @lowering_safe_navigation.delete(safe_call.object_id)
            present_value = "COPY #{present_value}" if stored_borrowed_value?(safe_call)
            assignment = "IF #{safe_receiver} != NIL THEN\n#{indent}  #{receiver_code}.#{field_name} = #{present_value};\n" \
              "#{indent}ELSE\n#{indent}  #{receiver_code}.#{field_name} = NIL;\n#{indent}END"
            return prefix ? "#{prefix}\n#{assignment}" : assignment
          end
          assignment = "#{receiver_code}.#{field_name} = #{value}"
          if node.receiver.is_a?(Prism::LocalVariableReadNode)
            local_name = @renames[node.receiver.name.to_s] || node.receiver.name.to_s
            if (backing = @hash_backed_locals[local_name])
              assignment = "#{assignment};\n#{backing.fetch(:receiver)}[#{backing.fetch(:key)}] = COPY #{local_name}"
            end
          end
          return prefix ? "#{prefix}\n#{assignment}" : assignment
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

        # This method is a deliberately skipped Ruby/Open3 implementation.
        # Its self-hosted spelling is supplied by the compiler native module,
        # so it must override the semantic target collected from the skipped
        # Ruby declaration.
        if name_str == "compiler_zig_translate_c" && args_list.length == 3 &&
           (helper = @helper_config.call(:zig_translate_c, args_list))
          return propagate_fallible_expression(helper)
        end
        if name_str == "zig_executable" && args_list.empty? &&
           (helper = @helper_config.call(:zig_executable, args_list))
          return helper
        end

        # Typed user/class/module calls take precedence over Ruby stdlib names.
        # Otherwise a domain method such as OwnershipEdgePlanner.select is
        # mistaken for Enumerable#select.
        known_class_call = if node.receiver && (receiver_class = constant_receiver_name(node.receiver))
          @class_class_method_names[receiver_class].include?(clear_function_name(name_str))
        end
        unless semantic_call || known_class_call
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
        end

        if node.block
          block_params = method_params_for(name_str, receiver_type_for_call)
          block_param = block_params&.find { |info| info[:kind] == :block }
          block_returns_void = block_param && block_param[:type].to_s.match?(/(?:->|RETURNS)\s*Void\z/)
          block_returns_void ||= %w[each each_with_index reverse_each each_key each_value each_pair
                                    each_char each_line times upto downto
                                    each_locatable each_child_node].include?(name_str)
          local_types = block_local_types_for_call(node, receiver_type_for_call)
          args_list << with_local_types(local_types) do
            block_to_lambda(node.block, returns_void: block_returns_void)
          end
        end


        if semantic_call
          target = semantic_call.target
          require_method_dependency(target.owner, target.name)
          # A bare call inside `class << self` is a singleton sibling call.
          # The semantic resolver may also see an instance method with the
          # same Ruby name; the lexical singleton context is decisive.
          if @inside_class_method && !node.receiver &&
             (@class_class_method_names[@current_class].include?(clear_function_name(name_str)) ||
              @module_function_names[@current_class].include?(clear_function_name(name_str)))
            call = "#{class_method_function_name(@current_class, name_str)}(#{args_list.join(', ')})"
            return propagate_known_fallible_call(call, name_str, @current_class)
          end
          case semantic_call.dispatch
          when :instance
            receiver_argument = rec_code || "self"
            actual_receiver_type = node.receiver ? clear_type_for_receiver_node(node.receiver).to_s : semantic_call.receiver_type.to_clear
            if node.receiver && ["Any", "Auto"].include?(actual_receiver_type.delete_prefix("?").split("@").first)
              emitted_receiver_type = clear_type_name_for_emit(semantic_call.receiver_type.to_clear)
              receiver_argument = "CAST(#{rec_code} AS #{emitted_receiver_type})"
            end
            function_name = instance_function_name(target.owner, target.name)
            if semantic_call.receiver_ownership == :borrow_mut &&
               !mutable_storage_path?(receiver_argument)
              temporary = next_generated_local("mutable_receiver")
              call = "#{function_name}(#{[mutable_argument_code(temporary), *args_list].join(', ')})"
              call = propagate_known_fallible_call(call, target.name, target.owner)
              # Emit the receiver materialization as a VALUE BLOCK so the call
              # stays a single expression in every position (assignment value,
              # IF condition, argument). Statement positions unwrap the block
              # back into plain statements in statement_code.
              return "{ MUTABLE rtoc_value_block_marker = 0; MUTABLE #{temporary} = #{receiver_argument};\n#{call} }"
            end
            if semantic_call.receiver_ownership != :borrow_mut &&
               @aliasable_classes.include?(target.owner.to_s) &&
               !mutable_storage_path?(receiver_argument)
              temporary = next_generated_local("local_receiver")
              call = "#{function_name}(#{[temporary, *args_list].join(', ')})"
              call = propagate_known_fallible_call(call, target.name, target.owner)
              # Aliasable instance methods carry `REQUIRES self: LOCAL`.
              # A constructor/getter result has ownership metadata but no
              # binding family until it is named. Materializing it as a local
              # gives the capability checker the same LOCAL fact Ruby has for
              # the temporary object.
              return "{ MUTABLE rtoc_value_block_marker = 0; MUTABLE #{temporary} = #{receiver_argument};\n#{call} }"
            end
            argument_setup = []
            if semantic_call.receiver_ownership == :borrow_mut
              args_list, argument_setup = materialize_mutable_receiver_alias_arguments(receiver_argument, args_list)
              receiver_argument = mutable_argument_code(receiver_argument)
            end
            call = "#{function_name}(#{[receiver_argument, *args_list].join(', ')})"
            call = propagate_known_fallible_call(call, target.name, target.owner)
            return wrap_call_after_argument_setup(call, argument_setup)
          when :class
            call = "#{class_method_function_name(target.owner, target.name)}(#{args_list.join(', ')})"
            return propagate_known_fallible_call(call, target.name, target.owner)
          when :module
            call = "#{class_method_function_name(target.owner, target.name)}(#{args_list.join(', ')})"
            return propagate_known_fallible_call(call, target.name, target.owner)
          end
        end

        if rec_code && name_str == "call" && function_like_clear_type?(receiver_type_for_call)
          if receiver_type_for_call.to_s.start_with?("?") && !@lowering_safe_navigation.include?(node.object_id)
            return unsupported_expression(node, "Proc#call on optional function receivers is not supported; assign T.must(receiver) to a local first")
          end

          # CLEAR accepts calls on parenthesized function expressions, so
          # `factory().call(x)` can remain expression-shaped.
          call = "#{rec_code}(#{args_list.join(', ')})"
          function_parts = function_clear_type_parts(receiver_type_for_call.to_s.delete_prefix("?"))
          if function_parts&.last&.start_with?("!")
            mark_current_function_fallible!
            return "TRY (#{call})"
          end
          return call
        end

        clear_name = clear_function_name(name_str)
        if rec_code
          if (self_class = self_class_receiver_name(node.receiver)) &&
             @class_class_method_names[self_class].include?(clear_name)
            call = "#{class_method_function_name(self_class, name_str)}(#{args_list.join(', ')})"
            return propagate_known_fallible_call(call, name_str, self_class)
          end
          receiver_type = receiver_type_for_call
          receiver_type = nil if receiver_type.to_s.delete_prefix("?") == "Any"
          if (receiver_class = constant_receiver_name(node.receiver)) &&
             @class_class_method_names[receiver_class].include?(clear_name)
            call = "#{class_method_function_name(receiver_class, name_str)}(#{args_list.join(', ')})"
            return propagate_known_fallible_call(call, name_str, receiver_class)
          end
          if receiver_type
            require_type_dependency(receiver_type)
            if (owner_type = instance_method_owner_type(receiver_type, clear_name))
              receiver_argument = mutating_instance_method?(owner_type, name_str) ? mutable_argument_code(rec_code) : rec_code
              call = "#{instance_function_name(owner_type, name_str)}(#{[receiver_argument, *args_list].join(', ')})"
              return propagate_known_fallible_call(call, name_str, owner_type)
            end
            if args_list.empty? && shared_union_field_type(receiver_type, name_str)
              return shared_union_field_access(rec_code, receiver_type, name_str)
            end
            if args_list.empty? && struct_field_reader?(receiver_type, name_str)
              field_type = class_instance_field_type(receiver_type, name_str)
              code = "#{indexed_receiver_access(method_receiver_code(rec_code), receiver_type: receiver_type)}#{name_str}"
              if direct_retained_carrier_type?(field_type)
                code = "KEEP #{code}"
              end
              return code
            end
          elsif (owner_type = unique_instance_method_owner(clear_name))
            receiver_argument = mutating_instance_method?(owner_type, name_str) ? mutable_argument_code(rec_code) : rec_code
            call = "#{instance_function_name(owner_type, name_str)}(#{[receiver_argument, *args_list].join(', ')})"
            return propagate_known_fallible_call(call, name_str, owner_type)
          end
          if (receiver_module = module_function_receiver_name(node.receiver)) &&
             @module_function_names[receiver_module].include?(clear_name)
            call = "#{class_method_function_name(receiver_module, name_str)}(#{args_list.join(', ')})"
            return propagate_known_fallible_call(call, name_str, receiver_module)
          end
        elsif @inside_instance_method
          if args_list.empty? && @current_instance_field_names.include?(name_str)
            return "self.#{name_str}"
          end
          if @current_instance_method_names.include?(clear_name)
            receiver_argument = mutating_instance_method?(@current_class, name_str) ? mutable_argument_code("self") : "self"
            call = "#{instance_function_name(@current_class, name_str)}(#{[receiver_argument, *args_list].join(', ')})"
            return propagate_known_fallible_call(call, name_str, @current_class)
          end
        elsif @inside_class_method &&
              (@class_class_method_names[@current_class].include?(clear_name) ||
               @module_function_names[@current_class].include?(clear_name))
          call = "#{class_method_function_name(@current_class, name_str)}(#{args_list.join(', ')})"
          return propagate_known_fallible_call(call, name_str, @current_class)
        end

        rec = if rec_code
          receiver = ruby_mutating_receiver_call?(node) ? mutable_method_receiver_code(rec_code) : method_receiver_code(rec_code)
          "#{receiver}."
        else
          ""
        end
        args_str = args_list.join(", ")

        call_name = clear_name
        if node.receiver.is_a?(Prism::SelfNode)
          if @inside_class_method &&
             (@class_class_method_names[@current_class].include?(clear_name) ||
              @module_function_names[@current_class].include?(clear_name))
            call = "#{class_method_function_name(@current_class, name_str)}(#{args_str})"
            return propagate_known_fallible_call(call, name_str, @current_class)
          end
          if @inside_instance_method && @current_instance_method_names.include?(clear_name)
            receiver_argument = mutating_instance_method?(@current_class, name_str) ? mutable_argument_code("self") : "self"
            call = "#{instance_function_name(@current_class, name_str)}(#{[receiver_argument, *args_list].join(', ')})"
            return propagate_known_fallible_call(call, name_str, @current_class)
          end
        end
        # A no-receiver sibling call inside a module/class method resolves to
        # another method of the same owner; its fallibility is registered under
        # the scoped key, so pass the owner for the propagation lookup.
        call_owner = rec_code ? nil : @current_class
        propagate_known_fallible_call("#{rec}#{call_name}(#{args_str})", name_str, call_owner)
      end
    end

    def block_local_types_for_call(node, receiver_type)
      block = node.block
      return {} unless block.is_a?(Prism::BlockNode) || block.is_a?(Prism::LambdaNode)

      requireds = block.parameters&.parameters&.requireds || []
      types = {}
      block_param = method_params_for(node.name.to_s, receiver_type)&.find { |info| info[:kind] == :block }
      if block_param && (function_parts = function_clear_type_parts(block_param[:type]))
        function_parts.first.each_with_index do |parameter_type, index|
          parameter = requireds[index]
          next unless parameter&.respond_to?(:name)

          types[parameter.name.to_s] = function_type_param_type(parameter_type)
        end
      end
      return types unless node.name.to_s == "each_with_object"

      element_param, accumulator_param = requireds
      return types unless element_param&.respond_to?(:name) && accumulator_param&.respond_to?(:name)

      element_type = array_element_clear_type(receiver_type.to_s.delete_prefix("?"))
      types[element_param.name.to_s] = element_type if element_type

      accumulator_node = node.arguments&.arguments&.first
      accumulator_type = inferred_clear_type_for_node(accumulator_node).to_s
      unless accumulator_type.empty? || ["Any", "Auto"].include?(accumulator_type)
        types[accumulator_param.name.to_s] = accumulator_type
      end
      types
    end

    # `recv.` normally, `recv?.` when the receiver is an indexed read.
    # Indexing yields an optional in CLEAR for arrays and hashes alike, so a
    # field access on one needs safe navigation - `?.` is the operator built
    # for it (`!.` is tense navigation; the frontend redirects to `?.` here).
    # The receiver often arrives as TEXT rather than an AST node -
    # each_with_index aliases its block parameter to `items[rtoc_idx]` - so
    # this is matched on the emitted code, and only for a bare `name[expr]`.
    def indexed_receiver_access(receiver, receiver_type: nil)
      text = receiver.to_s
      return "#{text}." unless text.match?(/\A[A-Za-z_@][\w.@]*\[[^\[\]]+\]\z/)
      return "#{text}." if receiver_type && !receiver_type.to_s.start_with?("?")

      "#{text}?."
    end

    def lower_typed_ir_field_call(node, receiver_code, fact)
      receiver = method_receiver_code(receiver_code)
      field_name = fact.field.name
      if fact.write
        args = node.arguments&.arguments || []
        return unsupported_expression(node, "Resolved field writer must have exactly one argument") unless args.length == 1

        field_type = fact.field_type.to_clear
        if args.first.is_a?(Prism::IfNode) && affine_clear_type?(field_type)
          if simple_method_receiver_code?(receiver_code)
            return if_assignment_code("#{receiver}.#{field_name}", args.first, field_type)
          end
          temporary = next_generated_local("writer_receiver")
          declaration = "MUTABLE #{temporary}: #{fact.receiver_type.to_clear} = #{receiver_code};"
          return "#{declaration}\n#{if_assignment_code("#{temporary}.#{field_name}", args.first, field_type)}"
        end

        if args.first.is_a?(Prism::CallNode) && args.first.safe_navigation? && affine_clear_type?(field_type)
          target = receiver
          prefix = nil
          unless simple_method_receiver_code?(receiver_code)
            temporary = next_generated_local("writer_receiver")
            prefix = "MUTABLE #{temporary}: #{fact.receiver_type.to_clear} = #{receiver_code};"
            target = temporary
          end

          safe_call = args.first
          safe_receiver = visit(safe_call.receiver)
          narrowed_receiver = flow_narrowable_optional_receiver?(safe_call.receiver) ?
            safe_receiver : optional_unwrap_code(safe_receiver)
          @lowering_safe_navigation << safe_call.object_id
          present_value = with_node_code_override(safe_call.receiver, narrowed_receiver) do
            visit_call_node(safe_call)
          end
          @lowering_safe_navigation.delete(safe_call.object_id)
          present_value = wrap_argument_for_parameter_type(present_value, safe_call, field_type.to_s.delete_prefix("?"))
          present_value = "COPY #{present_value}" if stored_borrowed_value?(safe_call) &&
            !direct_retained_carrier_type?(field_type) && !present_value.start_with?("COPY ")
          assignment = "IF #{safe_receiver} != NIL THEN\n#{indent}  #{target}.#{field_name} = #{present_value};\n" \
            "#{indent}ELSE\n#{indent}  #{target}.#{field_name} = NIL;\n#{indent}END"
          return prefix ? "#{prefix}\n#{assignment}" : assignment
        end

        value = expression_argument_code(args.first)
        value = wrap_argument_for_parameter_type(value, args.first, field_type)
        value = "COPY #{value}" if stored_borrowed_value?(args.first) &&
          !direct_retained_carrier_type?(field_type) && !value.start_with?("COPY ")
        unless simple_method_receiver_code?(receiver_code)
          temporary = next_generated_local("writer_receiver")
          declaration = "MUTABLE #{temporary}: #{fact.receiver_type.to_clear} = #{receiver_code};"
          return "#{declaration}\n#{temporary}.#{field_name} = #{value}"
        end
        "#{receiver}.#{field_name} = #{value}"
      else
        if @helper_config.ruby_types_for(fact.receiver_type.to_clear).any?
          getter = "#{class_function_prefix(fact.receiver_type.to_clear)}__#{emitted_field_identity(field_name)}"
          value = "#{getter}(#{receiver})"
          return %w[multiowned shared].include?(fact.field_type.capability) ? "KEEP #{value}" : value
        end
        code = "#{indexed_receiver_access(receiver, receiver_type: fact.receiver_type.to_clear)}#{field_name}"
        %w[multiowned shared].include?(fact.field_type.capability) ? "KEEP #{code}" : code
      end
    end

    def dynamic_visitor_send_code(node, args)
      return nil unless node.receiver.nil? && @current_function_name == "visit"
      return nil unless args.length == 2 && args.first.is_a?(Prism::LocalVariableReadNode)
      return nil unless args.first.name.to_s == "method_name"

      candidates = @method_params.each_with_object({}) do |(key, params), result|
        method_name = key.to_s[/#(visit_([A-Z][A-Za-z0-9_]*))\z/, 1]
        next unless method_name && params.length == 1

        type = params.first[:type].to_s.delete_prefix("?")
        next unless method_name.delete_prefix("visit_") == type

        result[method_name] ||= type
      end
      return nil if candidates.empty?

      subject = expression_argument_code(args.last)
      arms = candidates.sort.map do |method_name, type|
        "AST.#{type} -> #{clear_function_name(method_name)}(_),"
      end
      arms << 'DEFAULT -> panic("missing generated AST visitor")'
      body = arms.map { |arm| "#{indent}  #{arm}" }.join("\n")
      "PARTIAL MATCH #{subject} START\n#{body}\n#{indent}END"
    end

    def dynamic_attribute_writer_send_code(node, args)
      return nil unless node.receiver && args.length == 2
      return nil unless args.first.is_a?(Prism::InterpolatedSymbolNode)

      match = args.first.location.slice.match(/\A:"#\{([A-Za-z][A-Za-z0-9_]*)\}="\z/)
      return nil unless match

      receiver_type = clear_type_for_receiver_node(node.receiver).to_s.delete_prefix("?")
      receiver_class = receiver_type.split(".").last
      fields = (@class_instance_field_names[receiver_type] | @class_instance_field_names[receiver_class])
        .grep(/_method\z/).sort
      return nil if fields.empty?

      receiver = method_call_receiver_expression(node.receiver)
      selector = @renames[match[1]] || match[1]
      value = expression_argument_code(args.last)
      chunks = fields.map.with_index do |field, index|
        keyword = index.zero? ? "IF" : "ELSE_IF"
        "#{keyword} #{selector} == :#{field} THEN\n#{indent}  #{method_receiver_code(receiver)}.#{field} = #{value};"
      end
      chunks << "ELSE\n#{indent}  panic(\"unknown generated attribute writer\");"
      "#{chunks.join("\n")}\n#{indent}END"
    end

    def indexed_enumerator_value_chain(node)
      return nil unless %w[map collect filter_map flat_map select sort_by to_a to_h all? any? count].include?(node.name.to_s)
      return nil if node.name.to_s != "to_a" && !node.block

      enumerator = node.receiver
      return nil unless enumerator.is_a?(Prism::CallNode) && enumerator.name.to_s == "each_with_index"
      return nil if enumerator.block || !enumerator.receiver

      source_node = enumerator.receiver
      source = visit(source_node)
      source_type = clear_type_for_receiver_node(source_node).to_s.delete_prefix("?")
      return unsupported_expression(node, "each_with_index requires a statically typed collection") if
        source_type.empty? || ["Any", "Auto"].include?(source_type)

      element_type = array_element_clear_type(source_type)
      return unsupported_expression(node, "each_with_index requires an array-shaped collection") unless element_type

      items_name = next_generated_local("indexed_items")
      index_name = next_generated_local("indexed_i")
      element_expr = "#{items_name}[#{index_name}]"
      lowering = if node.name.to_s == "to_a"
        nil
      else
        MethodRegistry.lower_literal_block(
          node,
          node.block,
          self,
          "each_with_index.#{node.name}",
          min_params: 2,
          max_params: 2,
          rename: lambda do |param_names|
            { param_names[0] => element_expr, param_names[1] => index_name }
          end,
          local_types: lambda do |param_names|
            { param_names[0] => element_type, param_names[1] => "Int64" }
          end,
          allow_next: true,
          allow_return: indexed_enumerator_nil_return_chain?(node)
        )
      end
      return lowering if lowering && MethodRegistry.unsupported_result?(lowering)

      output_name = next_generated_local("indexed_output")
      initial = case node.name.to_s
      when "to_h" then "{}"
      when "all?" then "true"
      when "any?" then "false"
      when "count" then "0"
      else "[]"
      end
      action = if node.name.to_s == "to_a"
        "#{mutable_method_receiver_code(output_name)}.append(Tuple{COPY #{element_expr}, #{index_name}});"
      elsif node.name.to_s == "to_h"
        pair_name = next_generated_local("indexed_pair")
        "MUTABLE #{pair_name} = #{lowering.value_code};\n    #{output_name}[#{pair_name}._0] = #{pair_name}._1;"
      elsif node.name.to_s == "select"
        "IF #{lowering.value_code} THEN\n      #{mutable_method_receiver_code(output_name)}.append(COPY #{element_expr});\n    END"
      elsif node.name.to_s == "filter_map"
        value_name = next_generated_local("indexed_value")
        "MUTABLE #{value_name} = #{lowering.value_code};\n" \
          "    IF #{value_name} EXISTS AS #{value_name}_value THEN\n" \
          "      #{mutable_method_receiver_code(output_name)}.append(COPY #{value_name}_value);\n" \
          "    END"
      elsif node.name.to_s == "flat_map"
        value_name = next_generated_local("indexed_value")
        item_name = next_generated_local("indexed_flattened")
        "MUTABLE #{value_name} = #{lowering.value_code};\n" \
          "    FOR #{item_name} IN #{value_name} DO\n" \
          "      #{mutable_method_receiver_code(output_name)}.append(COPY #{item_name});\n" \
          "    END"
      elsif node.name.to_s == "sort_by"
        "#{mutable_method_receiver_code(output_name)}.append(Tuple{COPY #{element_expr}, #{lowering.value_code}});"
      elsif node.name.to_s == "all?" || node.name.to_s == "any?"
        "#{output_name} = #{lowering.value_code};"
      elsif node.name.to_s == "count"
        "IF #{lowering.value_code} THEN\n      #{output_name} = #{output_name} + 1;\n    END"
      else
        "#{mutable_method_receiver_code(output_name)}.append(#{lowering.value_code});"
      end
      result = node.name.to_s == "sort_by" ? "#{output_name} |> ORDER_BY _._1 |> SELECT _._0" : output_name
      loop_guard = if node.name.to_s == "all?"
        "#{index_name} < #{items_name}.length() AND #{output_name}"
      elsif node.name.to_s == "any?"
        "#{index_name} < #{items_name}.length() AND !#{output_name}"
      else
        "#{index_name} < #{items_name}.length()"
      end
      "{\n" \
        "  MUTABLE rtoc_value_block_marker = 0;\n" \
        "  MUTABLE #{items_name}: #{source_type} = #{source};\n" \
        "  MUTABLE #{output_name} = #{initial};\n" \
        "  MUTABLE #{index_name} = 0;\n" \
        "  WHILE #{loop_guard} DO\n" \
        "    #{action}\n" \
        "    #{index_name} = #{index_name} + 1;\n" \
        "  END\n" \
        "  #{result}\n" \
        "}"
    end

    def indexed_enumerator_nil_return_chain?(node)
      return false unless node.is_a?(Prism::CallNode) && node.block
      return false unless node.receiver.is_a?(Prism::CallNode) && node.receiver.name.to_s == "each_with_index"

      returns = []
      walk = lambda do |current|
        return unless current.is_a?(Prism::Node)
        return if current != node.block && current.is_a?(Prism::BlockNode)

        returns << current if current.is_a?(Prism::ReturnNode)
        current.child_nodes.each { |child| walk.call(child) if child }
      end
      walk.call(node.block)
      returns.any? && returns.all? do |return_node|
        args = return_node.arguments&.arguments || []
        args.empty? || (args.length == 1 && args.first.is_a?(Prism::NilNode))
      end
    end

    def indexed_enumerator_with_object(node)
      return nil unless node.name.to_s == "with_object" && node.block

      enumerator = node.receiver
      return nil unless enumerator.is_a?(Prism::CallNode) && enumerator.name.to_s == "each_with_index"
      return nil if enumerator.block || !enumerator.receiver
      initial_node = node.arguments&.arguments&.first
      return unsupported_expression(node, "each_with_index.with_object requires one accumulator") unless initial_node

      requireds = node.block.parameters&.parameters&.requireds || []
      pair_param, accumulator_param = requireds
      pair_names = simple_multi_target_names(pair_param)
      return unsupported_expression(node, "each_with_index.with_object requires a pair and accumulator block pattern") unless
        pair_names&.length == 2 && accumulator_param&.respond_to?(:name)

      source_node = enumerator.receiver
      source = visit(source_node)
      source_type = clear_type_for_receiver_node(source_node).to_s.delete_prefix("?")
      element_type = array_element_clear_type(source_type)
      return unsupported_expression(node, "each_with_index.with_object requires a statically typed array") unless element_type

      items_name = next_generated_local("indexed_items")
      index_name = next_generated_local("indexed_i")
      accumulator_name = next_generated_local("indexed_acc")
      aliases = {
        pair_names[0] => "#{items_name}[#{index_name}]",
        pair_names[1] => index_name,
        accumulator_param.name.to_s => accumulator_name,
      }
      local_types = {
        pair_names[0] => element_type,
        pair_names[1] => "Int64",
      }
      body_lines = with_block_local_scope do
        with_local_types(local_types) do
          with_renames(aliases) do
            (node.block.body&.body || []).filter_map do |statement|
              code = visit(statement)
              statement_code(code) unless code.empty?
            end
          end
        end
      end
      body = body_lines.flat_map { |line| line.lines.map { |part| "    #{part.rstrip}" } }.join("\n")
      initial = expression_argument_code(initial_node)
      "(%(#{items_name}: #{source_type}) -> {\n" \
        "  MUTABLE #{accumulator_name} = #{initial};\n" \
        "  MUTABLE #{index_name} = 0;\n" \
        "  WHILE #{index_name} < #{items_name}.length() DO\n" \
        "#{body}\n" \
        "    #{index_name} = #{index_name} + 1;\n" \
        "  END\n" \
        "  #{accumulator_name}\n" \
        "})(#{source})"
    end

    def each_with_object_expression(node)
      return nil unless node.name.to_s == "each_with_object" && node.receiver && node.block

      initial_node = node.arguments&.arguments&.first
      return unsupported_expression(node, "each_with_object requires one accumulator") unless initial_node

      requireds = node.block.parameters&.parameters&.requireds || []
      element_param, accumulator_param = requireds
      return nil unless element_param&.respond_to?(:name) && accumulator_param&.respond_to?(:name)

      source_type = clear_type_for_receiver_node(node.receiver).to_s.delete_prefix("?")
      element_type = array_element_clear_type(source_type)
      return nil unless element_type

      initial = expression_argument_code(initial_node)
      accumulator_type = inferred_clear_type_for_node(initial_node).to_s
      if ["", "Any", "Auto"].include?(accumulator_type) || accumulator_type.match?(/\AHashMap<Any,\s*Any>\z/)
        expected_type = expected_expression_type.to_s
        expected_type = @current_function_return_type.to_s if ["", "Any", "Auto"].include?(expected_type)
        accumulator_type = expected_type unless ["", "Any", "Auto"].include?(expected_type)
      end

      aliases = {
        element_param.name.to_s => "_",
        accumulator_param.name.to_s => "acc",
      }
      local_types = {
        element_param.name.to_s => element_type,
        accumulator_param.name.to_s => accumulator_type,
      }
      body_lines = with_block_local_scope do
        with_local_types(local_types) do
          with_renames(aliases) do
            (node.block.body&.body || []).filter_map do |statement|
              code = visit(statement)
              statement_code(code) unless code.empty?
            end
          end
        end
      end
      body = body_lines.flat_map { |line| line.lines.map { |part| "  #{part.rstrip}" } }.join("\n")
      "#{visit(node.receiver)} |> REDUCE(#{initial}) {\n#{body}\n  acc\n}"
    end

    def parenthesized_index_or_write(receiver)
      return nil unless receiver.is_a?(Prism::ParenthesesNode)

      body = receiver.body&.body || []
      body.one? && body.first.is_a?(Prism::IndexOrWriteNode) ? body.first : nil
    end

    def string_append_chain(node)
      values = []
      current = node
      while current.is_a?(Prism::CallNode) && current.name.to_s == "<<" &&
            current.arguments&.arguments&.length == 1
        values << current.arguments.arguments.first
        current = current.receiver
      end
      return nil if values.length < 2
      return nil unless registry_receiver_shape(current) == "string"

      receiver = method_receiver_code(visit(current))
      # CLEAR strings grow by reassign-concat (the old value is freed by
      # reassignment); String has no in-place append.
      values.reverse.map do |value_node|
        value = wrap_argument_for_parameter_type(visit(value_node), value_node, "String")
        "#{receiver} = (#{receiver} $+ #{value})"
      end.join(";\n#{indent}")
    end

    def safe_navigation_equality_code(node, rhs_node)
      safe_node = node.receiver
      return nil unless safe_node.is_a?(Prism::CallNode) && safe_node.safe_navigation?
      return nil unless safe_navigation_static_rhs?(rhs_node)

      rhs_type = inferred_clear_type(rhs_node).to_s
      return nil if rhs_type.empty? || rhs_type == "Any" || rhs_type == "Auto" || rhs_type.start_with?("?")

      receiver = visit(safe_node.receiver)
      # In `(local != NIL) AND ...`, CLEAR flow-narrows a stable local for the
      # right operand. Applying `?` again produces UNWRAP_NON_OPTIONAL. Calls
      # and fields are not stable bindings, so they still need an explicit
      # unwrap of their repeated receiver expression.
      unwrapped = if safe_node.receiver.is_a?(Prism::LocalVariableReadNode)
        receiver
      else
        optional_unwrap_code(receiver)
      end
      @lowering_safe_navigation << safe_node.object_id
      lhs = with_node_code_override(safe_node.receiver, unwrapped) { visit_call_node(safe_node) }
      @lowering_safe_navigation.delete(safe_node.object_id)
      rhs = visit(rhs_node)

      lhs_type = inferred_clear_type(safe_node).to_s.delete_prefix("?")
      if @union_types.key?(lhs_type) && !@union_types.key?(rhs_type.delete_prefix("?"))
        rhs = wrap_argument_for_parameter_type(rhs, rhs_node, lhs_type)
      end

      if node.name.to_s == "=="
        "((#{receiver} != NIL) AND (#{lhs} == #{rhs}))"
      else
        "((#{receiver} == NIL) OR (#{lhs} != #{rhs}))"
      end
    ensure
      @lowering_safe_navigation&.delete(safe_node.object_id) if safe_node
    end

    def flow_narrowable_optional_receiver?(node)
      return true if node.is_a?(Prism::LocalVariableReadNode) ||
        node.is_a?(Prism::InstanceVariableReadNode)
      return false unless node.is_a?(Prism::CallNode)
      return false unless @typed_ir.field_for(node)
      return false if node.arguments&.arguments&.any? || node.block

      node.receiver.is_a?(Prism::SelfNode) ||
        flow_narrowable_optional_receiver?(node.receiver)
    end

    def union_scalar_equality_code(node, rhs_node)
      lhs_type = inferred_clear_type(node.receiver).to_s
      rhs_type = inferred_clear_type(rhs_node).to_s
      union_type = lhs_type.delete_prefix("?")
      members = @union_types[union_type]
      return nil unless members && !@union_types.key?(rhs_type.delete_prefix("?"))
      return nil if rhs_type.empty? || %w[Any Auto].include?(rhs_type) || rhs_type.start_with?("?")
      return nil unless members.any? { |member| union_member_payload_type_match?(member, rhs_type) }

      optional = lhs_type.start_with?("?")
      helper_parts = []
      helper_parts << "optional" if optional
      helper_parts.concat([union_type, rhs_type])
      helper_suffix = helper_parts.join("_").gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "")
      helper = "ruby_union_scalar_equal_#{helper_suffix}"
      lines = ["FN #{helper}(value: #{lhs_type}, expected: #{rhs_type}) RETURNS Bool ->"]
      lines << "  IF value EXISTS AS equality_value THEN" if optional
      indent = optional ? "    " : "  "
      subject = optional ? "equality_value" : "value"
      lines << "#{indent}IF #{subject} IS_A #{rhs_type} AS equality_payload THEN"
      lines << "#{indent}  RETURN equality_payload == expected;"
      lines << "#{indent}END"
      lines << "  END" if optional
      lines << "  FALSE;"
      lines << "END"
      @generated_support_helper_defs[helper] ||= lines.join("\n")

      comparison = "#{helper}(#{visit(node.receiver)}, #{visit(rhs_node)})"
      node.name.to_s == "!=" ? "!(#{comparison})" : comparison
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
          pairs |> EACH { result[COPY _._0] = COPY _._1; };
          result;
        END
      CLEAR
      "#{helper_name}(#{method_receiver_code(visit(node.receiver))})"
    end

    # Ruby String#delete_prefix / #delete_suffix as a support helper: the result
    # is a heap String, so it needs statement-IF + RETURN, not an IF-expression.
    def string_delete_affix_code(kind, target_code, affix_code)
      helper = "rtoc_delete_#{kind}"
      test = kind == :prefix ? "startsWith?" : "endsWith?"
      slice = kind == :prefix ? "s.substr(affix.length(), (s.length() - affix.length()))" : "s.substr(0, (s.length() - affix.length()))"
      @generated_support_helper_defs[helper] ||= <<~CLEAR.chomp
        FN #{helper}(s: String, affix: String) RETURNS String ->
          IF s.#{test}(affix) THEN
            RETURN #{slice};
          END
          RETURN COPY s;
        END
      CLEAR
      "#{helper}(#{target_code}, #{affix_code})"
    end
    public :string_delete_affix_code

    def array_concat_expression_code(node)
      receiver_type = clear_type_for_receiver_node(node.receiver).to_s
      helper_suffix = receiver_type.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      helper_name = "ruby_array_concat_#{helper_suffix}"
      @generated_support_helper_defs[helper_name] ||= <<~CLEAR.chomp
        FN #{helper_name}(left: #{receiver_type}, right: #{receiver_type}) RETURNS #{receiver_type} ->
          MUTABLE result: #{receiver_type} = [];
          left |> EACH { &result.append(COPY _); };
          right |> EACH { &result.append(COPY _); };
          RETURN result;
        END
      CLEAR

      arg = node.arguments.arguments.first
      arg_code = expression_argument_code(arg)
      setup = nil
      if arg_code.include?("\n")
        if arg_code.lstrip.start_with?("{ MUTABLE rtoc_value_block_marker")
          # A value block is a self-contained expression — collapse to one
          # line instead of splitting it mid-expression.
          arg_code = arg_code.lines.map(&:strip).join(" ")
        else
          lines = arg_code.lines.map(&:rstrip).reject(&:empty?)
          arg_code = lines.pop
          setup = lines.join(" ")
        end
      end
      arg_type = inferred_clear_type(arg).to_s
      arg_code = "CAST(#{arg_code} AS #{receiver_type})" unless arg_type == receiver_type
      call = "#{helper_name}(#{method_receiver_code(visit(node.receiver))}, #{arg_code})"
      setup ? "( { #{setup} #{call} } )" : call
    end

    def array_concat_statement_code(node)
      receiver = method_receiver_code(visit(node.receiver))
      "#{receiver} = #{array_concat_expression_code(node)}"
    end

    def set_union_expression_code(left_node, right_node)
      set_type = inferred_clear_type(left_node).to_s
      helper_suffix = set_type.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      helper_name = "ruby_set_union_#{helper_suffix}"
      @generated_support_helper_defs[helper_name] ||= <<~CLEAR.chomp
        FN #{helper_name}(left: #{set_type}, right: #{set_type}) RETURNS #{set_type} ->
          MUTABLE result: #{set_type} = COPY left;
          right |> EACH {
            IF !(result.contains?(_)) THEN
              &result.insert(COPY _);
            END
          };
          RETURN result;
        END
      CLEAR
      "#{helper_name}(#{visit(left_node)}, #{visit(right_node)})"
    end

    def set_intersection_expression_code(left_node, right_node)
      operand_types = [inferred_clear_type(left_node).to_s, inferred_clear_type(right_node).to_s]
      set_type = operand_types.find { |type| type.end_with?("@set") } ||
        operand_types.find { |type| type.end_with?("[]") } || operand_types.first
      insertion = set_type.end_with?("@set") ? "insert" : "append"
      helper_suffix = set_type.gsub(/[^A-Za-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      helper_name = "ruby_set_intersection_#{helper_suffix}"
      @generated_support_helper_defs[helper_name] ||= <<~CLEAR.chomp
        FN #{helper_name}(left: #{set_type}, right: #{set_type}) RETURNS #{set_type} ->
          MUTABLE result: #{set_type} = [];
          left |> EACH {
            IF right.contains?(_) AND !(result.contains?(_)) THEN
              &result.#{insertion}(COPY _);
            END
          };
          RETURN result;
        END
      CLEAR
      "#{helper_name}(#{visit(left_node)}, #{visit(right_node)})"
    end

    def generic_set_intersection_operator_code(left_code, right_code)
      helper_name = "ruby_set_intersection"
      @generated_support_helper_defs[helper_name] ||= <<~CLEAR.chomp
        FN #{helper_name}<T>(left: T[]@set, right: T[]@set) RETURNS T[]@set ->
          MUTABLE result: T[]@set = Set[];
          left |> EACH {
            IF right.contains?(_) AND !(result.contains?(_)) THEN
              &result.insert(COPY _);
            END
          };
          RETURN result;
        END
      CLEAR
      "#{helper_name}(#{left_code}, #{right_code})"
    end

    def generic_set_union_operator_code(left_code, right_code)
      helper_name = "ruby_set_union"
      @generated_support_helper_defs[helper_name] ||= <<~CLEAR.chomp
        FN #{helper_name}<T>(left: T[]@set, right: T[]@set) RETURNS T[]@set ->
          MUTABLE result: T[]@set = COPY left;
          right |> EACH {
            IF !(result.contains?(_)) THEN
              &result.insert(COPY _);
            END
          };
          RETURN result;
        END
      CLEAR
      "#{helper_name}(#{left_code}, #{right_code})"
    end

    public :generic_set_intersection_operator_code, :generic_set_union_operator_code

    def method_receiver_code(code)
      text = code.to_s
      return text if text.empty?
      return text if text.start_with?("(") && text.end_with?(")")
      return "(#{text})" if text.start_with?("CAST(")
      return text if text.match?(/\A[A-Za-z_]\w*(?:(?:\.[A-Za-z_]\w*)|(?:\[[^\[\]\n]+\]))+\?\z/)
      return "(#{text})" if text.end_with?("?")
      return text if text.match?(
        /\A[a-z_]\w*[!?]?\([^()\n]*\)(?:\[[^\n\]]+\]|\.[A-Za-z_]\w*[!?]?(?:\([^()\n]*\))?)*\z/
      )
      return text if simple_method_receiver_code?(text)
      return text if text.match?(/\A"(?:[^"\\]|\\.)*"\z/) || text.match?(/\A\d[\d_]*(?:\.\d+)?\z/)

      "(#{text})"
    end
    public :method_receiver_code

    def method_call_receiver_expression(receiver)
      if @node_code_overrides.key?(receiver.object_id)
        return method_receiver_code(@node_code_overrides[receiver.object_id])
      end
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

      method_receiver_code(visit(receiver))
    end

    # `T.must(map[key]).field << v` must mutate the map slot in place:
    # UNWRAP yields a value copy (a const view in the emitted Zig), so the
    # update is lost or rejected. Lower through the CLEAR slot idiom - bind
    # a mutable pointer with IF-EXISTS and re-emit the call against the
    # binding; the ELSE arm preserves T.must's raise-on-nil.
    def map_slot_mutation_statement(node)
      current = node.receiver
      while current.is_a?(Prism::CallNode) && current.receiver && !current.block &&
            (current.arguments.nil? || current.arguments.arguments.empty?) &&
            !sorbet_call?(current, "must")
        current = current.receiver
      end
      return nil unless current.is_a?(Prism::CallNode) && sorbet_call?(current, "must")
      return nil if @node_code_overrides.key?(current.object_id)

      args = current.arguments ? current.arguments.arguments : []
      return nil unless args.length == 1

      index_read = args.first
      return nil unless index_read.is_a?(Prism::CallNode) && index_read.name.to_s == "[]" && index_read.receiver

      index_args = index_read.arguments ? index_read.arguments.arguments : []
      return nil unless index_args.length == 1

      map_type = expand_clear_type_alias(clear_type_for_receiver_node(index_read.receiver).to_s).to_s.delete_prefix("?")
      return nil unless map_type.start_with?("{", "HashMap<")

      slot = next_generated_local("map_slot")
      inner = with_node_code_override(current, slot) { visit_call_node(node) }
      return nil if inner.include?("\n")

      map_code = method_receiver_code(visit(index_read.receiver))
      key_code = expression_argument_code(index_args.first)
      exists_block =
        "IF #{map_code}[#{key_code}] EXISTS AS #{slot} THEN\n" \
        "#{indent}  #{statement_code(inner)}\n"
      # A Hash.new-with-default receiver seeds missing keys on read, so
      # T.must over it can never raise: seed the slot instead of panicking.
      if (default_spec = hash_default_spec_for_receiver(index_read.receiver))
        seed = hash_default_code(default_spec, map_code, key_code)
        "IF #{map_code}[#{key_code}] == NIL THEN\n" \
          "#{indent}  #{map_code}[#{key_code}] = #{seed};\n" \
          "#{indent}END\n" \
          "#{indent}#{exists_block}" \
          "#{indent}END"
      else
        "#{exists_block}" \
          "#{indent}ELSE\n" \
          "#{indent}  panic(\"T.must: map slot is NIL\");\n" \
          "#{indent}END"
      end
    end

    # A call consuming a shared-union-field read of heap type
    # (`reg.token.empty?`) cannot lower as `(MATCH ...).empty?` — expression
    # MATCH rejects non-copyable results (MATCH_EXPR_RESULT_NOT_COPYABLE).
    # The consuming call is distributed into the arms instead, where the
    # field read stays borrow-local and the call result is copyable.
    def union_field_dispatch_distribution(node)
      recv = node.receiver
      return nil unless recv.is_a?(Prism::CallNode) && recv.receiver
      return nil if recv.arguments && !recv.arguments.arguments.empty?
      return nil if recv.block || node.block
      return nil if @node_code_overrides.key?(recv.object_id)

      receiver_type = clear_type_for_receiver_node(recv.receiver)
      return nil unless receiver_type

      field_name = recv.name.to_s
      field_type = shared_union_field_type(receiver_type, field_name)
      return nil unless field_type && !match_expr_copyable_field_type?(field_type)

      union_name = expand_non_emitted_type_alias(receiver_type).to_s.delete_prefix("?")
      members = @union_types[union_name]
      return nil unless members

      subject = method_call_receiver_expression(recv.receiver)
      arm_body = with_node_code_override(recv, "item.#{field_name}") { visit_call_node(node) }
      return nil if arm_body.include?("\n")

      arms = members.map do |member|
        "#{union_name}.#{union_variant_name(member, union_name)} AS item -> #{arm_body}"
      end
      "(MATCH #{subject} START #{arms.join(', ')} END)"
    end

    # Expression-MATCH results must be IMPLICITLY copyable (primitive,
    # symbol, rodata string) — narrower than copyable_storage_type?, which
    # also admits heap values that an explicit COPY could duplicate.
    def match_expr_copyable_field_type?(type)
      normalized = expand_clear_type_alias(type.to_s).to_s.delete_prefix("?")
      return true if normalized == "String@symbol"

      normalized.match?(/\A(?:Bool|Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Float|Float32|Float64)\z/)
    end

    def shared_union_field_access(receiver_code, receiver_type, field_name)
      union_name = expand_non_emitted_type_alias(receiver_type).to_s.delete_prefix("?")
      arms = @union_types.fetch(union_name).map do |member|
        variant = union_variant_name(member, union_name)
        "#{union_name}.#{variant} AS item -> item.#{field_name}"
      end
      "(MATCH #{receiver_code} START #{arms.join(', ')} END)"
    end

    # A field shared by every member of a closed interface is still stored on
    # each variant payload, not on the union value itself. MATCH payload
    # bindings are borrowed and immutable, even when the union binding itself
    # is MUTABLE. Copy the selected payload, update that local, and rebuild the
    # union variant. Besides satisfying exclusive mutability, the reconstruction
    # is what makes the write observable after the MATCH.
    def shared_union_field_write(receiver_code, receiver_type, field_name, value, value_node = nil, value_type = nil)
      union_name = expand_non_emitted_type_alias(receiver_type).to_s.delete_prefix("?")
      members = @union_types[union_name]
      return nil unless members
      return nil unless shared_union_field_type(receiver_type, field_name)
      return nil unless mutable_storage_path?(receiver_code)

      value_prefix = nil
      if value_node.is_a?(Prism::CallNode)
        value_name = next_generated_local("union_field_value")
        value_prefix = shared_union_field_statement_assignment(value_name, value_node, value_type)
        value = value_name if value_prefix
      end

      arms = members.map do |member|
        variant = union_variant_name(member, union_name)
        "#{indent}  #{union_name}.#{variant} AS item ->\n" \
          "#{indent}    MUTABLE item_mutable = COPY item;\n" \
          "#{indent}    item_mutable.#{field_name} = #{value};\n" \
          "#{indent}    #{receiver_code} = #{union_name}{ #{variant}: item_mutable };,"
      end
      assignment = "MATCH #{receiver_code} START\n#{arms.join("\n")}\n#{indent}END"
      value_prefix ? "#{value_prefix}\n#{indent}#{assignment}" : assignment
    end

    # A bare shared-union field read normally lowers to an expression MATCH.
    # CLEAR intentionally rejects heap-valued expression MATCH results, so an
    # assignment such as `type = node.type_object` must instead initialize the
    # destination and fill it from a statement MATCH arm-by-arm.
    def shared_union_field_statement_assignment(name, node, explicit_type = nil)
      return nil unless node.receiver
      return nil if node.block || (node.arguments && !node.arguments.arguments.empty?)

      receiver_type = clear_type_for_receiver_node(node.receiver)
      return nil unless receiver_type

      field_name = node.name.to_s
      field_type = shared_union_field_type(receiver_type, field_name)
      return nil unless field_type && !match_expr_copyable_field_type?(field_type)

      union_name = expand_non_emitted_type_alias(receiver_type).to_s.delete_prefix("?")
      members = @union_types[union_name]
      return nil unless members

      assignment_type = explicit_type || field_type
      declaration = unless @declared_locals.include?(name)
        @declared_locals << name
        @local_types[name] = assignment_type
        @local_shapes[name] = clear_type_shape(assignment_type)
        "MUTABLE #{name}: #{assignment_type} = #{default_value_for_type(assignment_type)};\n"
      end
      subject = method_call_receiver_expression(node.receiver)
      arms = members.map do |member|
        variant = union_variant_name(member, union_name)
        "#{indent}  #{union_name}.#{variant} AS item ->\n" \
          "#{indent}    #{name} = COPY item.#{field_name};,"
      end
      "#{declaration}#{indent}MATCH #{subject} START\n#{arms.join("\n")}\n#{indent}END"
    end

    def struct_field_index_access(receiver, arg_nodes, receiver_code = nil)
      return nil unless arg_nodes.length == 1

      field_name = struct_field_index_name(receiver, arg_nodes.first)
      return nil unless field_name

      receiver_type = if receiver.is_a?(Prism::SelfNode)
        @current_class
      else
        clear_type_for_receiver_node(receiver)
      end
      field_type = class_instance_field_type(receiver_type, field_name) if receiver_type

      code = "#{method_receiver_code(receiver_code || visit(receiver))}.#{field_name}"
      if direct_retained_carrier_type?(field_type)
        code = "KEEP #{code}"
      end
      code
    end

    def struct_field_index_name(receiver, key_node)
      field_name = keyword_call_key(key_node)
      return nil unless field_name

      if receiver.is_a?(Prism::SelfNode)
        return nil unless @current_instance_field_names.include?(field_name)
      else
        receiver_type = clear_type_for_receiver_node(receiver)
        return nil unless receiver_type && struct_field_reader?(receiver_type, field_name)
      end

      field_name
    end

    def simple_method_receiver_code?(code)
      code.match?(
        /\A[A-Za-z_]\w*[!?]?(?:\[[^\n\]]+\]|\.[A-Za-z_]\w*[!?]?(?:\([^()\n]*\))?)*\z/
      )
    end

    def struct_field_reader?(receiver_type, field_name)
      type_lookup_names(receiver_type).any? do |type_name|
        type_name = resolve_qualified_class_name(type_name)
        @class_instance_field_names[type_name].include?(field_name) ||
          Array(@struct_fields[type_name]).include?(field_name)
      end
    end
    public :struct_field_reader?

    def instance_method_owner_type(receiver_type, clear_name)
      type_lookup_names(receiver_type).each do |type_name|
        method_matches = @class_instance_method_names.filter_map do |candidate, methods|
          next unless methods.include?(clear_name)
          next unless candidate == type_name || candidate.end_with?("::#{type_name}") || candidate.end_with?(".#{type_name}")

          candidate
        end
        return method_matches.first if method_matches.one?

        resolved_type = resolve_qualified_class_name(type_name)
        return resolved_type if @class_instance_method_names[resolved_type].include?(clear_name)
      end

      nil
    end

    def class_instance_field_type(receiver_type, field_name)
      cache_key = [receiver_type.to_s, field_name.to_s]
      if @metadata_finalized && @class_instance_field_type_cache.key?(cache_key)
        return @class_instance_field_type_cache[cache_key]
      end

      type_lookup_names(receiver_type).each do |type_name|
        type_name = resolve_qualified_class_name(type_name)
        field_type = @class_instance_field_types[type_name][field_name.to_s]
        if field_type
          @class_instance_field_type_cache[cache_key] = field_type if @metadata_finalized
          return field_type
        end

        suffix = "::#{type_name}"
        matching_key = @class_instance_field_types.keys.find { |k| k.end_with?(suffix) }
        if matching_key
          field_type = @class_instance_field_types[matching_key][field_name.to_s]
          if field_type
            @class_instance_field_type_cache[cache_key] = field_type if @metadata_finalized
            return field_type
          end
        end
      end

      @class_instance_field_type_cache[cache_key] = nil if @metadata_finalized
      nil
    end

    def type_lookup_names(type)
      text = type.to_s.delete_prefix("?")
      return [] if text.empty?

      base = text.end_with?("@symbol") ? text : text.split("@").first.to_s.delete_suffix("[]")
      names = [text, base]
      names << base.tr(".", "::") if base.include?(".")
      names << base.split("::").last if base.include?("::")
      names << base.split(".").last if base.include?(".")
      # A dependency may have selected a namespace-qualified emitted name to
      # avoid colliding with one of its own imports (MIR::UnaryOp becomes
      # MIRUnaryOp when AST::UnaryOp is already visible). Keep that emitted
      # identity in type comparisons so downstream union wrapping does not
      # discard the semantic constructor identity.
      emitted = clear_constant_type_name(base)
      names << emitted if emitted && emitted != base
      @emitted_type_names.each do |source_name, emitted_name|
        names << source_name if emitted_name == base
      end
      names.concat(@helper_config.ruby_types_for(base))
      names.uniq.reject(&:empty?)
    end

    def constant_receiver_name(node)
      return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      name = node.location.slice.strip
      candidates = [name]
      candidates.unshift(@module_aliases[name]) if @module_aliases[name]
      candidates << name.split("::").last if name.include?("::")
      qualified = resolve_qualified_class_name(name)
      candidates.unshift(qualified) if qualified
      if !name.include?("::")
        suffix_matches = @class_class_method_names.keys.select { |candidate| candidate.split("::").last == name }
        candidates.unshift(suffix_matches.first) if suffix_matches.one?
      end
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
      candidates.unshift(@module_aliases[name]) if @module_aliases[name]
      candidates << name.split("::").last if name.include?("::")
      candidates.find { |candidate| @module_function_names.key?(candidate) }
    end
    end
  end
end
