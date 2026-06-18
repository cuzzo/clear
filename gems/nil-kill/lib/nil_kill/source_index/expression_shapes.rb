# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    def update_local_fact(node)
      name = node.name.to_s
      builder = collection_builder_for_assignment(node.value)
      hash_shape = hash_shape_for_value(node.value)
      array_shape = array_element_shape_for_value(node.value)
      if builder
        @current_collection_builders[name] = builder
      elsif !preserve_collection_builder_assignment?(node.value)
        @current_collection_builders.delete(name)
      end
      if hash_shape
        @current_hash_shapes[name] = hash_shape
        @current_hash_shape_sources[name] = hash_record_source_for_assignment(node, hash_shape)
      elsif preserve_hash_shape_assignment?(node.value)
        @current_hash_shapes[name] = dup_hash_shape(@current_hash_shapes[node.value.name.to_s])
        @current_hash_shape_sources[name] = @current_hash_shape_sources[node.value.name.to_s]&.merge("alias" => name)
      else
        @current_hash_shapes.delete(name)
        @current_hash_shape_sources.delete(name)
      end
      if array_shape
        @current_array_element_shapes[name] = array_shape
      elsif preserve_array_element_shape_assignment?(node.value)
        @current_array_element_shapes[name] = dup_hash_shape(@current_array_element_shapes[node.value.name.to_s])
      else
        @current_array_element_shapes.delete(name)
      end
      type = expression_type(node.value)
      if NilKill.useful_type?(type)
        @current_local_types[name] = type
      elsif builder
        @current_local_types[name] = synthesized_collection_builder_type(builder)
      else
        @current_local_types.delete(name)
      end
      if non_nil_literal?(node.value) && !@maybe_nil_locals.include?(name)
        @non_nil_locals.add(name)
      else
        @non_nil_locals.delete(name)
        @maybe_nil_locals.add(name)
      end
    end

    def hash_shape_for_value(value)
      return nil unless value
      case value
      when Syntax::HashNode, Syntax::KeywordHashNode
        shape = TypedRecords::HashShapeRecord.empty
        value.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          key = hash_key_name(assoc.key)
          type = expression_type(assoc.value)
          if key && (NilKill.useful_type?(type) || type == "NilClass")
            shape["keys"][key] ||= []
            shape["keys"][key] |= [type]
            if (nested_hash = hash_shape_for_value(assoc.value))
              shape["value_hash_shapes"][key] = nested_hash
            end
            if (nested_array = array_element_shape_for_value(assoc.value))
              shape["value_array_element_shapes"][key] = nested_array
            end
          elsif key
            shape["keys"][key] ||= []
            shape["keys"][key] |= ["T.untyped"]
          elsif !key
            shape["poisoned"] = true
          end
        end
        shape
      when Syntax::LocalVariableReadNode
        dup_hash_shape(@current_hash_shapes[value.name.to_s])
      when Syntax::CallNode
        if assignment_call?(value)
          hash_shape_for_value(assignment_value_expression(value))
        elsif value.receiver&.slice == "T" && %i[must cast let].include?(value.name)
          hash_shape_for_value(value.arguments&.arguments&.first)
        elsif %i[find detect].include?(value.name)
          array_element_shape_for_receiver(value.receiver)
        elsif %i[first last].include?(value.name)
          array_element_shape_for_receiver(value.receiver)
        elsif !value.receiver
          dup_hash_shape(@static_hash_return_shapes[value.name.to_s])
        else
          attribute_hash_shape_for_call(value)
        end
      when Syntax::OrNode
        merge_optional_hash_shape(hash_shape_for_value(value.left), hash_shape_for_value(value.right))
      end
    end

    def array_element_shape_for_value(value)
      return nil unless value
      case value
      when Syntax::ArrayNode
        shapes = value.elements.filter_map { |elem| hash_shape_for_value(elem) }
        return nil if shapes.empty?
        shapes.reduce { |acc, shape| merge_hash_record_shapes(acc, shape) }
      when Syntax::LocalVariableReadNode
        dup_hash_shape(@current_array_element_shapes[value.name.to_s])
      when Syntax::CallNode
        if assignment_call?(value)
          array_element_shape_for_value(assignment_value_expression(value))
        elsif value.receiver&.slice == "T" && %i[must cast let].include?(value.name)
          array_element_shape_for_value(value.arguments&.arguments&.first)
        elsif %i[map filter_map].include?(value.name)
          hash_shape_for_block_return(value)
        elsif %i[select reject compact].include?(value.name)
          array_element_shape_for_receiver(value.receiver)
        elsif !value.receiver
          dup_hash_shape(@static_array_element_return_shapes[value.name.to_s])
        elsif value.receiver
          attribute_array_element_shape_for_call(value)
        end
      when Syntax::OrNode
        merge_optional_hash_shape(array_element_shape_for_value(value.left), array_element_shape_for_value(value.right))
      end
    end

    def merge_optional_hash_shape(left, right)
      return dup_hash_shape(left) if left && !right
      return dup_hash_shape(right) if right && !left
      return nil unless left && right
      merge_hash_record_shapes(left, right)
    end

    def attribute_hash_shape_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode)
      return nil if node.name.to_s.end_with?("=")
      if (shape = struct_field_hash_shape_for_call(node))
        return shape
      end
      dup_hash_shape(self.class.attribute_hash_shapes[node.name.to_s])
    end

    def attribute_array_element_shape_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode)
      return nil if node.name.to_s.end_with?("=")
      if (shape = struct_field_array_element_shape_for_call(node))
        return shape
      end
      dup_hash_shape(self.class.attribute_array_element_shapes[node.name.to_s])
    end

    def hash_shape_for_block_return(call_node)
      block = call_node.block
      return nil unless block && block.respond_to?(:body)
      old_hash_shapes = @current_hash_shapes
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        shape = block_param_shapes_for_call(call_node)[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      expr = implicit_return_expression(block.body)
      shape = hash_shape_for_expression(expr)
      if (!shape || Hash(shape["keys"]).empty?) && (literal_shape = hash_shape_for_literal_keys(expr))
        shape = literal_shape
      end
      shape
    ensure
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    def hash_shape_for_literal_keys(value)
      return nil unless value.is_a?(Syntax::HashNode) || value.is_a?(Syntax::KeywordHashNode)
      shape = TypedRecords::HashShapeRecord.empty
      value.elements.each do |assoc|
        next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
        key = hash_key_name(assoc.key)
        if key
          type = expression_type(assoc.value)
          shape["keys"][key] ||= []
          shape["keys"][key] |= [NilKill.useful_type?(type) || type == "NilClass" ? type : "T.untyped"]
          if (nested_hash = hash_shape_for_value(assoc.value))
            shape["value_hash_shapes"][key] = nested_hash
          end
          if (nested_array = array_element_shape_for_value(assoc.value))
            shape["value_array_element_shapes"][key] = nested_array
          end
        else
          shape["poisoned"] = true
        end
      end
      Hash(shape["keys"]).empty? ? nil : shape
    end

    def struct_field_hash_shape_for_call(node)
      struct_field_shape_for_call(node, self.class.struct_field_hash_shapes)
    end

    def struct_field_array_element_shape_for_call(node)
      struct_field_shape_for_call(node, self.class.struct_field_array_element_shapes)
    end

    def sym_to_s(sym)
      @sym_str[sym] ||= sym.to_s
    end

    def struct_field_shape_for_call(node, index)
      receiver_type = expression_type(node.receiver)
      name = sym_to_s(node.name)
      classes = receiver_classes_for_field_shape(receiver_type)
      classes.each do |klass|
        shape = index[[klass, name]]
        return dup_hash_shape(shape) if shape
      end
      if classes.empty?
        matching = index.select { |(_klass, field), _shape| field == name }.values
        return dup_hash_shape(matching.first) if matching.size == 1
      end
      nil
    end

    def struct_field_static_type_for_call(node)
      return nil unless node.is_a?(Syntax::CallNode) && node.receiver
      receiver_type = expression_type(node.receiver)
      name = sym_to_s(node.name)
      types = receiver_classes_for_field_shape(receiver_type).flat_map do |klass|
        Array(self.class.struct_field_static_types[[klass, name]])
      end
      NilKill.static_sorbet_type(types.uniq)
    end

    # Pure function of `type` -> memoize. .dup so callers keep getting
    # a fresh array.
    def receiver_classes_for_field_shape(type)
      (@rcfs_memo[type] ||= receiver_classes_for_field_shape_uncached(type)).dup
    end

    def receiver_classes_for_field_shape_uncached(type)
      raw = NilKill.strip_nilable_type(type.to_s)
      return [] if raw.empty? || raw == "T.untyped"
      if raw.start_with?("T.any(")
        return NilKill.split_top_level(NilKill.extract_call_args(raw, "T.any") || "").flat_map { |inner| receiver_classes_for_field_shape(inner) }.uniq
      end
      [raw, raw.split("::").last].uniq
    end

    def collection_builder_for_assignment(value)
      return nil unless value
      case value
      when Syntax::ArrayNode
        builder = collection_builder("array")
        value.elements.each { |elem| add_collection_type(builder, elem) }
        builder
      when Syntax::HashNode
        builder = collection_builder("hash")
        value.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          add_hash_collection_types(builder, assoc.key, assoc.value)
        end
        builder
      when Syntax::CallNode
        if value.name == :new && value.receiver&.slice == "Set"
          collection_builder("set")
        end
      end
    end

    def preserve_collection_builder_assignment?(value)
      value.is_a?(Syntax::LocalVariableReadNode) && @current_collection_builders.key?(value.name.to_s)
    end

    def preserve_hash_shape_assignment?(value)
      value.is_a?(Syntax::LocalVariableReadNode) && @current_hash_shapes.key?(value.name.to_s)
    end

    def hash_record_source_for_assignment(node, shape)
      value = node.value
      if value.is_a?(Syntax::HashNode) || value.is_a?(Syntax::KeywordHashNode)
        TypedRecords::ContainerOriginRecord.new(
          kind: "hash literal",
          name: node.name.to_s,
          path: @rel,
          line: node.location.start_line,
          code: value.slice,
          shape: shape,
        )
      else
        TypedRecords::ContainerOriginRecord.new(
          kind: "local hash shape",
          name: node.name.to_s,
          path: @rel,
          line: node.location.start_line,
          code: value&.slice,
          shape: shape,
        )
      end
    end

    def preserve_array_element_shape_assignment?(value)
      value.is_a?(Syntax::LocalVariableReadNode) && @current_array_element_shapes.key?(value.name.to_s)
    end

    def inspect_variable_write(node)
      if node.value.is_a?(Syntax::CallNode) && node.value.name == :let && node.value.receiver&.slice == "T"
        @ivar_tlet_names.add(node.name.to_s)
        return
      end
      return if @ivar_tlet_names.include?(node.name.to_s)
      type = static_expression_type(node.value)
      return if type == "NilClass"
      return unless type
      @tlet_sites << TypedRecords::TLetSiteRecord.new(
        path: @rel,
        line: node.location.start_line,
        tlet: false,
        name: node.name.to_s,
        candidate_type: type,
      ).to_source_index_hash
    end

    # Sound because expression_type only READS state and every mutation
    # of its read surface bumps @ep (the @current_* maps via EpochHash;
    # the writes to @static_return_types/@ivar_tlet_types/
    # @method_return_types); @current_class_name is in the key.
    # NIL_KILL_EXPR_SHADOW asserts memo == fresh per call.
    def expression_type(node)
      return expression_type_uncached(node) unless @expr_use_memo && node

      key = node.object_id
      ent = @expr_memo[key]
      if ent && ent[0] == @ep[0] && ent[1] == @current_class_name
        if @expr_shadow
          fresh = expression_type_uncached(node)
          if fresh != ent[2]
            @expr_shadow_bad += 1
            warn "EXPR_SHADOW MISMATCH #{node.class} cached=#{ent[2].inspect} fresh=#{fresh.inspect}" if @expr_shadow_bad <= 8
          end
        end
        return ent[2]
      end
      r = expression_type_uncached(node)
      @expr_memo[key] = [@ep[0], @current_class_name, r]
      r
    end

    def expression_type_uncached(node)
      return nil unless node
      if return_node?(node)
        args = node.respond_to?(:arguments) ? node.arguments : nil
        values = args&.arguments || []
        return expression_type(values.first) || "NilClass"
      end
      if node.is_a?(Syntax::CallNode) && node.name == :let && node.receiver&.slice == "T"
        return node.arguments&.arguments&.[](1)&.slice
      end
      if node.is_a?(Syntax::CallNode) && node.name == :must && node.receiver&.slice == "T"
        return expression_type(node.arguments&.arguments&.first)
      end
      if node.is_a?(Syntax::LocalVariableReadNode)
        name = node.name.to_s
        builder_type = synthesized_collection_builder_type(@current_collection_builders[name])
        return builder_type if builder_has_evidence?(@current_collection_builders[name]) && NilKill.useful_type?(builder_type)
        return "T::Hash[T.untyped, T.untyped]" if @current_hash_shapes[name]
        return "T::Array[T::Hash[T.untyped, T.untyped]]" if @current_array_element_shapes[name]
        return @current_local_types[name] if NilKill.useful_type?(@current_local_types[name])
        return @current_param_types[name]
      end
      if node.is_a?(Syntax::InstanceVariableReadNode)
        return ivar_expression_type(node.name.to_s)
      end
      if node.is_a?(Syntax::ParenthesesNode)
        return expression_type(implicit_return_expression(node.body))
      end
      if node.is_a?(Syntax::StatementsNode)
        return expression_type(node.body&.last)
      end
      if node.is_a?(Syntax::ElseNode)
        return expression_type(implicit_return_expression(node.statements))
      end
      if node.is_a?(Syntax::IfNode)
        left = expression_type(implicit_return_expression(node.statements))
        right = node.subsequent ? expression_type(implicit_return_expression(node.subsequent)) : "NilClass"
        return NilKill.static_sorbet_type([left, right].compact)
      end
      if node.is_a?(Syntax::UnlessNode)
        left = expression_type(implicit_return_expression(node.statements))
        right = node.respond_to?(:else_clause) && node.else_clause ? expression_type(implicit_return_expression(node.else_clause)) : "NilClass"
        return NilKill.static_sorbet_type([left, right].compact)
      end
      if node.is_a?(Syntax::WhileNode) || node.is_a?(Syntax::UntilNode)
        return "NilClass"
      end
      if node.is_a?(Syntax::OrNode)
        left = expression_type(node.left)
        right = expression_type(node.right)
        non_nil = [left, right].compact.reject { |type| type == "NilClass" }
        normalized = non_nil.map { |type| NilKill.strip_nilable_type(type.to_s) }.uniq
        return normalized.first if normalized.size == 1 && NilKill.useful_type?(normalized.first)
        return non_nil.first if non_nil.size == 1 && NilKill.useful_type?(non_nil.first)
        return left if left == right && NilKill.useful_type?(left)
      end
      if node.is_a?(Syntax::CallNode)
        if assignment_call?(node)
          return expression_type(assignment_value_expression(node))
        end
        return "T::Hash[T.untyped, T.untyped]" if hash_shape_for_receiver(node)
        return "T::Array[T::Hash[T.untyped, T.untyped]]" if array_element_shape_for_receiver(node)
        field_type = struct_field_static_type_for_call(node)
        return field_type if NilKill.useful_type?(field_type)
        ret = known_return_type(node.name.to_s, node: node, allow_rbi: rbi_return_candidate?(node))
        return ret if NilKill.useful_type?(ret)
      end
      return "T::Array[T::Hash[T.untyped, T.untyped]]" if array_element_shape_for_value(node)
      constant_expression_type(node) || literal_type(node)
    end

    def ivar_expression_type(name)
      return nil unless @current_class_name
      tlet_type = @ivar_tlet_types[[@current_class_name, name]]
      return tlet_type if NilKill.useful_type?(tlet_type)
      field = name.sub(/\A@/, "")
      class_chain = @current_class_name.split("::")
      while class_chain.any?
        candidate = class_chain.join("::")
        rbi_type = SourceIndex.rbi_field_types[[candidate, field]]
        return rbi_type if NilKill.useful_type?(rbi_type)
        rbi_type_short = SourceIndex.rbi_field_types[[class_chain.last, field]]
        return rbi_type_short if NilKill.useful_type?(rbi_type_short)
        class_chain.pop
      end
      nil
    end

    def array_receiver_type?(type)
      type.to_s.match?(/\A(?:Array|T::Array)\b/)
    end

    def hash_receiver_type?(type)
      type.to_s.match?(/\A(?:Hash|T::Hash)\b/)
    end

    def collection_receiver_type?(type)
      array_receiver_type?(type) || hash_receiver_type?(type) || type.to_s.match?(/\A(?:Set|T::Set)\b/)
    end

    def collection_index_return_type(node, receiver_type)
      args = node.arguments&.arguments || []
      return nil unless args.size == 1
      shape_type = hash_shape_index_return_type(node.receiver, args.first)
      return shape_type if NilKill.useful_type?(shape_type)
      info = collection_type_info(receiver_type)
      return nil unless info
      case info["kind"]
      when "array"
        elem = info["element"]
        return nil if elem.to_s.empty? || elem.include?("T.untyped")
        index = args.first
        if index.is_a?(Syntax::RangeNode)
          "T::Array[#{elem}]"
        elsif expression_type(index) == "Integer"
          nilable_type(elem)
        end
      when "hash"
        value = info["value"]
        return nil if value.to_s.empty? || value.include?("T.untyped")
        nilable_type(value)
      end
    end

    def hash_shape_index_return_type(receiver, index)
      shape = hash_shape_for_receiver(receiver)
      return nil unless shape && !shape["poisoned"]
      key = hash_key_name(index)
      return nil unless key
      types = Array(shape.dig("keys", key))
      return nil if types.empty?
      value = NilKill.static_sorbet_type(types)
      return nil unless NilKill.useful_type?(value)
      nilable_type(value)
    end

    def hash_shape_for_receiver(receiver)
      case receiver
      when Syntax::LocalVariableReadNode
        @current_hash_shapes[receiver.name.to_s]
      when Syntax::HashNode, Syntax::KeywordHashNode
        hash_shape_for_value(receiver)
      when Syntax::CallNode
        if receiver.receiver&.slice == "T" && %i[must cast let].include?(receiver.name)
          hash_shape_for_receiver(receiver.arguments&.arguments&.first)
        elsif %i[first last].include?(receiver.name)
          array_element_shape_for_receiver(receiver.receiver)
        else
          attribute_hash_shape_for_call(receiver)
        end
      end
    end

    def collection_map_return_type(node, receiver_type)
      info = collection_type_info(receiver_type)
      return nil unless info
      return nil unless array_receiver_type?(receiver_type)
      block_type = block_return_type(node, block_param_types_for_collection(info), block_param_shapes_for_collection(node, info))
      return nil unless NilKill.useful_type?(block_type)
      return nil if block_type.include?("T.untyped")
      "T::Array[#{block_type}]"
    end

    def collection_filter_map_return_type(node, receiver_type)
      info = collection_type_info(receiver_type)
      return nil unless info
      return nil unless array_receiver_type?(receiver_type)
      block_type = block_return_type(node, block_param_types_for_collection(info), block_param_shapes_for_collection(node, info))
      return nil unless NilKill.useful_type?(block_type)
      elem = non_nil_type(block_type)
      return nil if elem.to_s.empty? || elem.include?("T.untyped") || elem == "NilClass"
      "T::Array[#{elem}]"
    end

    def collection_compact_return_type(receiver_type)
      info = collection_type_info(receiver_type)
      return nil unless info && info["kind"] == "array"
      elem = non_nil_type(info["element"])
      return nil if elem.to_s.empty? || elem.include?("T.untyped") || elem == "NilClass"
      "T::Array[#{elem}]"
    end

    def block_return_type(call_node, param_types, param_shapes = [])
      block = call_node.block
      return nil unless block && block.respond_to?(:body)
      old_local_types = @current_local_types
      old_hash_shapes = @current_hash_shapes
      self.current_local_types = @current_local_types.dup
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        type = param_types[idx]
        @current_local_types[name] = type if name && NilKill.useful_type?(type)
        shape = param_shapes[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      expression_type(implicit_return_expression(block.body))
    ensure
      self.current_local_types = old_local_types if old_local_types
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    def block_param_names(block)
      return [] unless block.respond_to?(:parameters)
      params = block.parameters&.parameters
      return [] unless params
      (params.requireds + params.optionals).filter_map { |param| param.name.to_s if param.respond_to?(:name) && param.name }
    end

    def block_param_types_for_collection(info)
      case info["kind"]
      when "array", "set"
        [info["element"]]
      when "hash"
        [info["key"], info["value"]]
      else
        []
      end
    end

    def block_param_shapes_for_collection(call_node, info)
      return [] unless info["kind"] == "array"
      shape = array_element_shape_for_receiver(call_node.receiver)
      shape ? [shape] : []
    end

    def block_param_shapes_for_call(call_node)
      return [] unless %w[each map filter_map select reject find detect any? all? none? one?].include?(call_node.name.to_s)
      shape = array_element_shape_for_receiver(call_node.receiver)
      shape ? [shape] : []
    end

    def array_element_shape_for_receiver(receiver)
      case receiver
      when Syntax::LocalVariableReadNode
        @current_array_element_shapes[receiver.name.to_s]
      when Syntax::ArrayNode
        array_element_shape_for_value(receiver)
      when Syntax::CallNode
        if receiver.receiver&.slice == "T" && %i[must cast let].include?(receiver.name)
          array_element_shape_for_receiver(receiver.arguments&.arguments&.first)
        elsif %i[select reject compact].include?(receiver.name)
          array_element_shape_for_receiver(receiver.receiver)
        else
          attribute_array_element_shape_for_call(receiver)
        end
      end
    end

    def non_nil_type(type)
      raw = type.to_s
      return nil if raw.empty?
      if raw.start_with?("T.nilable(")
        return NilKill.strip_nilable_type(raw)
      end
      if raw.start_with?("T.any(")
        parts = NilKill.split_top_level(NilKill.extract_call_args(raw, "T.any") || "")
        parts = parts.reject { |part| part == "NilClass" }
        return NilKill.static_sorbet_type(parts)
      end
      raw
    end

    def collection_type_info(type)
      raw = NilKill.strip_nilable_type(type.to_s.strip)
      return nil if raw.empty?
      case raw
      when /\A(?:Array|T::Array)(?:\[(.*)\])?\z/
        TypedRecords::CollectionTypeInfoRecord.new(kind: "array", element: $1)
      when /\A(?:Hash|T::Hash)(?:\[(.*)\])?\z/
        args = $1 ? NilKill.split_top_level($1) : []
        TypedRecords::CollectionTypeInfoRecord.new(kind: "hash", key: args[0], value: args[1])
      when /\A(?:Set|T::Set)(?:\[(.*)\])?\z/
        TypedRecords::CollectionTypeInfoRecord.new(kind: "set", element: $1)
      end
    end

    def constant_expression_type(node)
      return nil unless node.is_a?(Syntax::ConstantReadNode) || node.is_a?(Syntax::ConstantPathNode)
      name = node.slice
      return nil if name.to_s.empty?
      return "T.class_of(#{name})" if CORE_CLASS_CONSTANTS.include?(name.delete_prefix("::"))
      return "T.class_of(#{name})" if @class_like_constants.include?(name.delete_prefix("::"))
      nil
    end

    def static_expression_type(node)
      constant_expression_type(node) || literal_type(node)
    end

    def static_expression_reason(type)
      type.to_s.start_with?("T.class_of(") ? "class constant #{type.delete_prefix("T.class_of(").delete_suffix(")")}" : type
    end

    def literal_type(node)
      case node
      when Syntax::StringNode then "String"
      when Syntax::SymbolNode then "Symbol"
      when Syntax::IntegerNode then "Integer"
      when Syntax::FloatNode then "Float"
      when Syntax::TrueNode, Syntax::FalseNode then "T::Boolean"
      when Syntax::NilNode then "NilClass"
      when Syntax::RangeNode then "Range"
      when Syntax::InterpolatedStringNode then "String"
      when Syntax::ArrayNode then "T::Array[T.untyped]"
      when Syntax::HashNode then "T::Hash[T.untyped, T.untyped]"
      else
        node.is_a?(Syntax::CallNode) && node.name == :new && node.receiver ? node.receiver.slice : nil
      end
    end

    def non_nil_literal?(node)
      type = static_expression_type(node)
      type && type != "NilClass"
    end

  end
end
