# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    def inspect_param_origins(node, scope)
      callee = node.name.to_s
      args = node.arguments&.arguments || []
      args.each_with_index do |arg, idx|
        if arg.is_a?(Syntax::KeywordHashNode)
          arg.elements.each do |assoc|
            next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
            key = hash_key_name(assoc.key)
            next unless key
            @param_origins << param_origin_record(node, assoc.value, callee, :keyword, key, scope)
            record_callsite_hash_shape(callee, :keyword, key, assoc.value)
            record_callsite_array_element_shape(callee, :keyword, key, assoc.value)
          end
        else
          @param_origins << param_origin_record(node, arg, callee, :positional, idx, scope)
          record_callsite_hash_shape(callee, :positional, idx, arg)
          record_callsite_array_element_shape(callee, :positional, idx, arg)
        end
      end
    end

    def record_callsite_hash_shape(callee, kind, slot, arg)
      shape = hash_shape_for_value(arg)
      return unless shape && !shape["poisoned"]
      callsite_callee_names(callee).each do |name|
        key = [name, kind.to_s, slot.to_s]
        @inferred_param_hash_shapes[key] =
          if @inferred_param_hash_shapes[key]
            merge_hash_record_shapes(@inferred_param_hash_shapes[key], shape)
          else
            dup_hash_shape(shape)
          end
      end
    end

    def record_callsite_array_element_shape(callee, kind, slot, arg)
      shape = array_element_shape_for_value(arg)
      return unless shape && !shape["poisoned"]
      callsite_callee_names(callee).each do |name|
        key = [name, kind.to_s, slot.to_s]
        @inferred_param_array_element_shapes[key] =
          if @inferred_param_array_element_shapes[key]
            merge_hash_record_shapes(@inferred_param_array_element_shapes[key], shape)
          else
            dup_hash_shape(shape)
          end
      end
    end

    def callsite_callee_names(callee)
      name = callee.to_s
      name == "new" ? ["new", "initialize"] : [name]
    end

    def inspect_attribute_shape_write(node)
      return unless node.is_a?(Syntax::CallNode) && node.receiver
      name = node.name.to_s
      return unless name.end_with?("=") && name != "=="
      args = node.arguments&.arguments || []
      return unless args.size == 1
      attr = name.delete_suffix("=")
      if (shape = hash_shape_for_value(args.first))
        merge_attribute_hash_shape(attr, shape)
      end
      if (shape = array_element_shape_for_value(args.first))
        merge_attribute_array_element_shape(attr, shape)
      end
    end

    def merge_attribute_hash_shape(attr, shape)
      return unless shape && !shape["poisoned"]
      current = self.class.attribute_hash_shapes[attr]
      self.class.attribute_hash_shapes[attr] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_attribute_array_element_shape(attr, shape)
      return unless shape && !shape["poisoned"]
      current = self.class.attribute_array_element_shapes[attr]
      self.class.attribute_array_element_shapes[attr] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_struct_field_hash_shape(klass, field, shape)
      return unless shape && !shape["poisoned"]
      key = [klass.to_s, field.to_s]
      current = self.class.struct_field_hash_shapes[key]
      self.class.struct_field_hash_shapes[key] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_struct_field_array_element_shape(klass, field, shape)
      return unless shape && !shape["poisoned"]
      key = [klass.to_s, field.to_s]
      current = self.class.struct_field_array_element_shapes[key]
      self.class.struct_field_array_element_shapes[key] = current ? merge_hash_record_shapes(current, shape) : dup_hash_shape(shape)
    end

    def merge_struct_field_static_type(klass, field, type)
      return unless NilKill.useful_type?(type) || type == "NilClass"
      key = [klass.to_s, field.to_s]
      self.class.struct_field_static_types[key] ||= []
      self.class.struct_field_static_types[key] |= [type]
    end

    def param_origin_record(call_node, arg, callee, kind, slot, scope)
      type = expression_type(arg)
      origin_kind = type ? "static" : "unknown"
      source_method = nil
      if arg.is_a?(Syntax::CallNode)
        source_method = arg.name.to_s
        ret = known_return_type(source_method, node: arg, allow_rbi: rbi_return_candidate?(arg))
        if ret
          type = ret
          origin_kind = "typed_return"
        elsif NilKill.useful_type?(type)
          origin_kind = "typed_return"
        else
          origin_kind = "untyped_return"
        end
      elsif arg.is_a?(Syntax::LocalVariableReadNode)
        origin_kind = "local"
      end
      TypedRecords::ParamOriginRecord.new(
        path: @rel,
        line: call_node.location.start_line,
        enclosing_scope: scope.join("::"),
        callee: callee,
        arg_kind: kind.to_s,
        slot: slot.to_s,
        origin_kind: origin_kind,
        receiver: call_receiver_name(call_node),
        source_method: source_method,
        arg_type: type,
        code: arg.slice,
        hash_shape: hash_shape_for_value(arg),
        array_element_shape: array_element_shape_for_value(arg),
        unknown_reasons: origin_kind == "unknown" ? unknown_expression_reasons(arg) : [],
      ).to_source_index_hash
    end

    def call_receiver_name(call_node)
      receiver = call_node.receiver
      return nil unless receiver
      const_name(receiver)
    rescue StandardError
      receiver.slice.to_s
    end

    def unknown_expression_reasons(node)
      reasons = Set.new
      collect_unknown_expression_reasons(node, reasons)
      reasons.to_a.sort
    end

    def collect_unknown_expression_reasons(node, reasons)
      return unless node
      case node
      when Syntax::InstanceVariableReadNode, Syntax::InstanceVariableWriteNode
        reasons << "instance variable #{node.name}"
      when Syntax::ClassVariableReadNode, Syntax::ClassVariableWriteNode
        reasons << "class variable #{node.name}"
      when Syntax::GlobalVariableReadNode, Syntax::GlobalVariableWriteNode
        reasons << "global variable #{node.name}"
      when Syntax::LocalVariableReadNode
        reasons << "local variable #{node.name}"
      when Syntax::ConstantReadNode, Syntax::ConstantPathNode
        type = static_expression_type(node)
        reasons << (type ? "literal/static expression #{static_expression_reason(type)}" : "operation unresolved constant #{node.slice}")
        return
      when Syntax::ArrayNode
        reasons << "struct/array/collection value Array"
        return
      when Syntax::HashNode, Syntax::KeywordHashNode
        reasons << "struct/array/collection value Hash"
        return
      when Syntax::CallNode
        if node.receiver&.slice == "T" && %i[let cast unsafe bind].include?(node.name)
          reasons << "literal/static expression explicit #{node.receiver.slice}.#{node.name}"
          args = node.arguments&.arguments || []
          reasons << "literal/static expression explicit T.untyped" if args.any? { |arg| arg.slice == "T.untyped" }
          return
        elsif expression_type(node)
          reasons << "literal/static expression #{static_expression_reason(expression_type(node))}"
          return
        elsif !known_return_type(node.name.to_s, node: node, allow_rbi: rbi_return_candidate?(node))
          reasons << "forwarded return #{node.name}"
          collect_unknown_expression_reasons(node.receiver, reasons)
          return
        end
      else
        type = static_expression_type(node)
        if type
          reasons << "literal/static expression #{static_expression_reason(type)}"
          return
        else
          reasons << "operation #{node.class.name.split("::").last}"
        end
      end
      node.compact_child_nodes.each { |child| collect_unknown_expression_reasons(child, reasons) } if node.respond_to?(:child_nodes)
    end

    def param_protocols(node)
      names = params(node).map { |param| param["name"] }.to_set
      protocols = names.each_with_object({}) { |name, hash| hash[name] = { "methods" => Set.new, "aliases" => Set.new, "gaps" => Set.new } }
      collect_protocols(node.body, protocols, names)
      protocols.transform_values do |data|
        TypedRecords::ParamProtocolRecord.new(
          method_names: data["methods"].to_a.sort,
          aliases: data["aliases"].to_a.sort,
          gaps: data["gaps"].to_a.sort,
        )
      end
    end

    def collect_protocols(node, protocols, param_names)
      return unless node
      if node.is_a?(Syntax::CallNode)
        receiver = node.receiver
        if receiver.is_a?(Syntax::LocalVariableReadNode) && protocols.key?(receiver.name.to_s)
          protocols[receiver.name.to_s]["methods"] << node.name.to_s
        end
        # Covers `@x.token`, `T.must(@x).token`, and safe-nav.
        if receiver.is_a?(Syntax::InstanceVariableReadNode) && @current_class_name
          @ivar_protocols[[@current_class_name, receiver.name.to_s]] << node.name.to_s
        end
        (node.arguments&.arguments || []).each_with_index do |arg, slot|
          if arg.is_a?(Syntax::LocalVariableReadNode) && protocols.key?(arg.name.to_s)
            protocols[arg.name.to_s]["gaps"] << "forwarded to #{node.name} slot #{slot} at #{@rel}:#{node.location.start_line}"
          end
        end
      elsif node.is_a?(Syntax::LocalVariableWriteNode)
        source = unwrap_alias_source(node.value)
        if source && protocols.key?(source)
          protocols[source]["aliases"] << "#{node.name} at #{@rel}:#{node.location.start_line}"
        end
      elsif node.is_a?(Syntax::InstanceVariableWriteNode)
        source = unwrap_alias_source(node.value)
        if source && protocols.key?(source)
          protocols[source]["gaps"] << "captured in #{node.name} at #{@rel}:#{node.location.start_line}"
          @ivar_param_origins[[@current_class_name, node.name.to_s]] << source if @current_class_name
        end
      end
      node.compact_child_nodes.each { |child| collect_protocols(child, protocols, param_names) } if node.respond_to?(:child_nodes)
    end

    def unwrap_alias_source(node)
      case node
      when Syntax::LocalVariableReadNode
        node.name.to_s
      when Syntax::CallNode
        if node.receiver&.slice == "T" && %i[must cast let].include?(node.name)
          unwrap_alias_source(node.arguments&.arguments&.first)
        end
      end
    end

    def sig_above(line)
      idx = line - 2
      idx -= 1 while idx >= 0 && @lines[idx].to_s.strip.empty?
      return nil if idx.negative?

      stripped = @lines[idx].to_s.strip
      return stripped if stripped.match?(/\bsig\s*\{/)

      if stripped == "end"
        floor = [idx - 40, 0].max
        idx.downto(floor) do |start_idx|
          current = @lines[start_idx].to_s
          return @lines[start_idx..idx].join if current.match?(/\bsig\s+do\b/)
          break if current.match?(/^\s*(def|class|module)\b/)
        end
      end

      nil
    end

    def params(node, sig = sig_above(node.location.start_line))
      p = node.parameters
      return [] unless p
      sig_types = NilKill.extract_param_entries(sig).to_h
      nodes = p.requireds + p.optionals + p.keywords
      nodes.filter_map do |n|
        next unless n.respond_to?(:name) && n.name
        name = n.name.to_s
        TypedRecords::MethodParameterRecord.new(
          name: name,
          nil_default: nil_default?(n),
          param_type: sig_types[name],
        )
      end
    end

    # Splat/double-splat/block params can never get runtime evidence
    # and the sig text has no `*`/`**`/`&` marker, so they must be
    # identified from the syntax parameter list, not the sig string.
    def untraceable_param_names(node)
      p = node.parameters
      return [] unless p
      names = []
      names << p.rest.name.to_s if p.rest.respond_to?(:name) && p.rest&.name
      kr = p.respond_to?(:keyword_rest) ? p.keyword_rest : nil
      names << kr.name.to_s if kr.respond_to?(:name) && kr&.name
      names << p.block.name.to_s if p.respond_to?(:block) && p.block.respond_to?(:name) && p.block&.name
      names
    end

    def non_nil_sig_params(sig)
      return [] unless sig
      params_match = sig.match(/params\((.*)\)\./)
      return [] unless params_match
      params_match[1].scan(/\b([a-zA-Z_]\w*):\s*([^,)]+)/).filter_map do |name, type|
        next if type.include?("T.nilable") || type == "T.untyped" || type == "NilClass"
        name
      end
    end

    def nil_default?(node)
      node.respond_to?(:value) && node.value.is_a?(Syntax::NilNode)
    end

    def uses_yield?(node)
      return false unless node&.respond_to?(:child_nodes)
      return true if node.is_a?(Syntax::YieldNode)
      node.compact_child_nodes.any? { |child| uses_yield?(child) }
    end

    def inspect_call(node)
      if node.name == :let && node.receiver&.slice == "T"
        args = node.arguments&.arguments || []
        @tlet_sites << TypedRecords::TLetSiteRecord.new(
          path: @rel,
          line: node.location.start_line,
          tlet: true,
          sorbet_type: args[1]&.slice,
        ).to_source_index_hash
      elsif node.safe_navigation? && provably_non_nil?(node.receiver)
        @dead_nil_checks << TypedRecords::DeadNilCheckRecord.new(
          path: @rel,
          line: node.location.start_line,
          kind: "safe_nav",
          code: node.slice,
          reason: "#{node.receiver.slice} is provably non-nil",
        ).to_source_index_hash
      elsif node.name == :nil? && node.receiver && provably_non_nil?(node.receiver)
        @dead_nil_checks << TypedRecords::DeadNilCheckRecord.new(
          path: @rel,
          line: node.location.start_line,
          kind: "nil_check",
          code: node.slice,
          reason: "#{node.receiver.slice} is provably non-nil; .nil? is always false",
        ).to_source_index_hash
      end
    end

  end
end
