# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    def struct_new_call?(node)
      node.is_a?(Syntax::CallNode) &&
        node.name == :new &&
        node.receiver.is_a?(Syntax::ConstantReadNode) &&
        node.receiver.name == :Struct
    end

    def data_define_call?(node)
      node.is_a?(Syntax::CallNode) &&
        node.name == :define &&
        node.receiver.is_a?(Syntax::ConstantReadNode) &&
        node.receiver.name == :Data
    end

    def struct_fields(node)
      (node.arguments&.arguments || []).filter_map do |arg|
        arg.value.to_s if arg.is_a?(Syntax::SymbolNode)
      end
    end

    def const_name(node)
      return "" unless node
      node.respond_to?(:full_name) ? (node.full_name rescue node.slice) : node.slice
    end

    def inspect_struct_constructor(node)
      return unless node.name == :new && node.receiver
      klass = const_name(node.receiver)
      fields = @struct_fields_by_name[klass] || @struct_fields_by_name[klass.split("::").last] ||
        self.class.struct_fields_by_name[klass] || self.class.struct_fields_by_name[klass.split("::").last]
      full_class = @struct_full_by_name[klass] || @struct_full_by_name[klass.split("::").last] ||
        self.class.struct_full_by_name[klass] || self.class.struct_full_by_name[klass.split("::").last] || klass
      return unless fields
      args = node.arguments&.arguments || []
      args.each_with_index do |arg, idx|
        next if idx >= fields.size || arg.is_a?(Syntax::KeywordHashNode)
        unless @warm_only
          @struct_field_static << TypedRecords::StructFieldStaticRecord.new(
            path: @rel,
            line: node.location.start_line,
            owner: full_class,
            field: fields[idx],
            static_type: expression_type(arg),
            expression: arg.slice,
          ).to_source_index_hash
        end
        merge_struct_field_static_type(full_class, fields[idx], expression_type(arg))
        merge_struct_field_hash_shape(full_class, fields[idx], hash_shape_for_value(arg))
        merge_struct_field_array_element_shape(full_class, fields[idx], array_element_shape_for_value(arg))
      end
    end

    def inspect_class_constructor_fields(node)
      return unless node.name == :new && node.receiver
      klass = const_name(node.receiver)
      return if klass.empty? || klass == "Struct"
      keyword_args = (node.arguments&.arguments || []).grep(Syntax::KeywordHashNode)
      keyword_args.each do |keywords|
        keywords.elements.each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          field = hash_key_name(assoc.key)
          next unless field
          merge_struct_field_static_type(klass, field, expression_type(assoc.value))
          merge_struct_field_hash_shape(klass, field, hash_shape_for_value(assoc.value))
          merge_struct_field_array_element_shape(klass, field, array_element_shape_for_value(assoc.value))
        end
      end
    end

    def inspect_array_literal(node)
      elements = node.elements || []
      return if elements.size < 2 || elements.any? { |elem| elem.is_a?(Syntax::SplatNode) }
      types = elements.map { |elem| expression_type(elem) }
      known = types.compact
      return if known.size != elements.size || known.uniq.size < 2
      @tuple_arrays << TypedRecords::TupleArrayRecord.new(
        path: @rel,
        line: node.location.start_line,
        size: elements.size,
        types: types,
        confidence: tuple_confidence(types),
        code: node.slice,
      ).to_source_index_hash
    end

    def inspect_hash_literal(node)
      elements = node.elements || []
      return if elements.empty?
      keys = []
      values = []
      value_hash_shapes = {}
      value_array_element_shapes = {}
      elements.each do |assoc|
        next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
        key = hash_key_name(assoc.key)
        next unless key
        keys << key
        values << expression_type(assoc.value)
        value_hash_shapes[key] = hash_shape_for_value(assoc.value) if hash_shape_for_value(assoc.value)
        value_array_element_shapes[key] = array_element_shape_for_value(assoc.value) if array_element_shape_for_value(assoc.value)
      end
      return if keys.size < 2 || keys.size != elements.size
      @hash_shapes << TypedRecords::HashShapeObservationRecord.new(
        path: @rel,
        line: node.location.start_line,
        keys: keys,
        value_types: values,
        value_hash_shapes: value_hash_shapes,
        value_array_element_shapes: value_array_element_shapes,
        code: node.slice,
      ).to_source_index_hash
    end

    def inspect_local_container_origin(node)
      origin = container_origin_for_value(node.value, name: node.name.to_s)
      if origin
        @local_container_origins[node.name.to_s] = origin
      else
        @local_container_origins.delete(node.name.to_s)
      end
    end

    def inspect_ivar_container_origin(node)
      origin = container_origin_for_value(node.value, name: node.name.to_s)
      @ivar_container_origins[node.name.to_s] = origin if origin
    end

    def container_origin_for_value(value, name:)
      return nil unless value
      case value
      when Syntax::ArrayNode
        types = Array(value.elements).map { |elem| expression_type(elem) }
        TypedRecords::ContainerOriginRecord.new(
          kind: "array literal",
          name: name,
          path: @rel,
          line: value.location.start_line,
          code: value.slice,
          array_element_types: types.compact.uniq.sort,
        )
      when Syntax::HashNode
        key_types = []
        value_types = []
        Array(value.elements).each do |assoc|
          next unless assoc.respond_to?(:key) && assoc.respond_to?(:value)
          key_types << expression_type(assoc.key)
          value_types << expression_type(assoc.value)
        end
        TypedRecords::ContainerOriginRecord.new(
          kind: "hash literal",
          name: name,
          path: @rel,
          line: value.location.start_line,
          code: value.slice,
          hash_key_types: key_types.compact.uniq.sort,
          hash_value_types: value_types.compact.uniq.sort,
        )
      when Syntax::LocalVariableReadNode
        @local_container_origins[value.name.to_s]&.merge("name" => name, "alias_of" => value.name.to_s)
      when Syntax::InstanceVariableReadNode, Syntax::ClassVariableReadNode, Syntax::GlobalVariableReadNode
        @ivar_container_origins[value.name.to_s]&.merge("name" => name, "alias_of" => value.name.to_s)
      when Syntax::CallNode
        TypedRecords::ContainerOriginRecord.new(
          kind: "forwarded return",
          name: name,
          path: @rel,
          line: value.location.start_line,
          code: value.slice,
          callee: value.name.to_s,
        )
      end
    end

    def inspect_index_lookup(node, scope)
      return unless %i[[] fetch].include?(node.name) && node.receiver
      return if sorbet_type_index_syntax?(node.receiver)
      args = node.arguments&.arguments || []
      return unless args.size >= 1
      return if node.name == :fetch && args.size > 1
      receiver_type = expression_type(node.receiver)
      lookup_type = collection_index_return_type(node, receiver_type)
      index_type = expression_type(args.first)
      @collection_index_lookups << TypedRecords::CollectionIndexLookupRecord.new(
        path: @rel,
        line: node.location.start_line,
        enclosing_scope: scope.join("::"),
        code: node.slice,
        receiver: node.receiver.slice,
        index: args.first.slice,
        receiver_type: receiver_type,
        index_type: index_type,
        lookup_type: lookup_type,
        status: collection_index_status(receiver_type, lookup_type),
        origin: receiver_collection_origin(node.receiver),
      ).to_source_index_hash
    end

    def inspect_hash_record_blocker(node, scope)
      return unless node.receiver
      name = node.name.to_s
      args = node.arguments&.arguments || []
      if %w[[] fetch].include?(name)
        return if name == "fetch" && args.size > 1
        return if args.empty? || hash_key_name(args.first)
        origin = hash_record_blocker_origin_for_receiver(node.receiver)
        return unless hash_record_blocker_origin?(origin)
        @hash_record_blockers << TypedRecords::HashRecordBlockerRecord.new(
          path: @rel,
          line: node.location.start_line,
          enclosing_scope: scope.join("::"),
          kind: "dynamic_key",
          code: node.slice,
          receiver: node.receiver.slice,
          index: args.first&.slice,
          origin: origin,
          message: "dynamic hash-record key prevents struct accessor rewrite",
        ).to_source_index_hash
      elsif %w[[]= merge! update delete clear shift].include?(name)
        origin = hash_record_blocker_origin_for_receiver(node.receiver)
        return unless hash_record_blocker_origin?(origin)
        @hash_record_blockers << TypedRecords::HashRecordBlockerRecord.new(
          path: @rel,
          line: node.location.start_line,
          enclosing_scope: scope.join("::"),
          kind: "mutation",
          code: node.slice,
          receiver: node.receiver.slice,
          origin: origin,
          message: "shape-changing hash-record mutation prevents broad struct rewrite",
        ).to_source_index_hash
      end
    end

    def inspect_hash_record_member_call(node, scope)
      receiver = node.receiver
      return unless receiver.is_a?(Syntax::CallNode)
      return unless %i[[] fetch].include?(receiver.name)
      return if receiver.name == :fetch && (receiver.arguments&.arguments || []).size > 1
      args = receiver.arguments&.arguments || []
      key = hash_key_name(args.first)
      return unless key
      origin = receiver_collection_origin(receiver.receiver)
      return unless hash_record_blocker_origin?(origin) || origin["kind"] == "local hash shape"
      @hash_record_member_calls << TypedRecords::HashRecordMemberCallRecord.new(
        path: @rel,
        line: node.location.start_line,
        enclosing_scope: scope.join("::"),
        field: key,
        member: node.name.to_s,
        code: node.slice,
        lookup_code: receiver.slice,
        receiver: receiver.receiver&.slice,
        origin: origin,
      ).to_source_index_hash
    end

    def hash_record_blocker_origin?(origin)
      ["hash literal", "method parameter", "forwarded return", "instance variable", "local hash shape"].include?(origin&.fetch("kind", nil).to_s)
    end

    def hash_record_blocker_origin_for_receiver(receiver)
      origin = receiver_collection_origin(receiver)
      return origin if hash_record_blocker_origin?(origin)
      if receiver.is_a?(Syntax::LocalVariableReadNode) && @current_hash_shapes[receiver.name.to_s]
        TypedRecords::ContainerOriginRecord.new(
          kind: "local hash shape",
          name: receiver.name.to_s,
          path: @rel,
          line: receiver.location.start_line,
          shape: @current_hash_shapes[receiver.name.to_s],
        )
      else
        origin
      end
    end

    def sorbet_type_index_syntax?(receiver)
      text = receiver.slice.to_s
      text.match?(/\A(?:T::)?(?:Array|Hash|Set|Enumerable)\z/) || text.start_with?("T::")
    end

    def collection_index_status(type, lookup_type = nil)
      return "typed lookup" if NilKill.useful_type?(lookup_type) && !NilKill.weak_type?(lookup_type)
      text = type.to_s
      return "unknown receiver type" if text.empty?
      return "weak collection receiver" if text.include?("T.untyped")
      return "typed collection receiver" if text.match?(/\A(?:Array|Hash|T::Array|T::Hash)\b/)
      "non-collection or unresolved receiver"
    end

    def receiver_collection_origin(node)
      case node
      when Syntax::LocalVariableReadNode
        name = node.name.to_s
        origin = @local_container_origins[name]
        if origin && origin["kind"] == "method parameter" && @current_hash_shapes[name]
          origin.merge("shape" => @current_hash_shapes[name])
        elsif origin
          origin
        elsif @current_hash_shape_sources[name]
          @current_hash_shape_sources[name].merge("receiver" => name, "shape" => @current_hash_shapes[name])
        elsif @current_hash_shapes[name]
          TypedRecords::ContainerOriginRecord.new(
            kind: "local hash shape",
            name: name,
            path: @rel,
            line: node.location.start_line,
            shape: @current_hash_shapes[name],
          )
        else
          TypedRecords::ContainerOriginRecord.new(kind: "local variable", name: name)
        end
      when Syntax::InstanceVariableReadNode, Syntax::ClassVariableReadNode, Syntax::GlobalVariableReadNode
        @ivar_container_origins[node.name.to_s] ||
          TypedRecords::ContainerOriginRecord.new(kind: "instance variable", name: node.name.to_s)
      when Syntax::ArrayNode
        container_origin_for_value(node, name: "literal")
      when Syntax::HashNode
        container_origin_for_value(node, name: "literal")
      when Syntax::CallNode
        if (shape = hash_shape_for_receiver(node))
          TypedRecords::ContainerOriginRecord.new(
            kind: "local hash shape",
            name: node.slice,
            path: @rel,
            line: node.location.start_line,
            shape: shape,
          )
        else
          TypedRecords::ContainerOriginRecord.new(
            kind: "forwarded return",
            callee: node.name.to_s,
            path: @rel,
            line: node.location.start_line,
            code: node.slice,
          )
        end
      else
        TypedRecords::ContainerOriginRecord.new(kind: node.class.name.split("::").last, code: node.slice)
      end
    end

    def inspect_dispatcher(node, record)
      param = record["params"].first
      return unless param
      arms = []
      collect_dispatch_arms(node.body, param["name"], arms)
      arms.group_by { |arm| arm["helper"] }.each do |helper, helper_arms|
        classes = helper_arms.flat_map { |arm| arm["classes"] }.uniq.sort
        next if classes.empty?
        type = classes.size == 1 ? classes.first : "T.any(#{classes.join(", ")})"
        @dispatcher_inferences << TypedRecords::DispatcherInferenceRecord.new(
          path: @rel,
          line: record["line"],
          owner: record["class"],
          method_kind: record["kind"],
          dispatcher: record["method"],
          helper: helper,
          inferred_type: type,
          classes: classes,
        ).to_source_index_hash
      end
    end

    def collect_dispatch_arms(node, param_name, arms)
      return unless node
      if node.is_a?(Syntax::CaseNode)
        node.conditions.each do |condition|
          next unless condition.is_a?(Syntax::WhenNode)
          helper = dispatch_helper_call(condition.statements, param_name)
          next unless helper
          classes = condition.conditions.filter_map { |cond| const_name(cond) }
          unless classes.empty?
            arms << TypedRecords::DispatchArmRecord.new(helper: helper, classes: classes)
          end
        end
      end
      node.compact_child_nodes.each { |child| collect_dispatch_arms(child, param_name, arms) } if node.respond_to?(:child_nodes)
    end

    def dispatch_helper_call(statements, param_name)
      body = statements&.body || []
      return nil unless body.size == 1
      call = body.first
      return nil unless call.is_a?(Syntax::CallNode)
      return nil if call.receiver
      args = call.arguments&.arguments || []
      return nil unless args.size == 1
      arg = args.first
      return nil unless arg.is_a?(Syntax::LocalVariableReadNode) && arg.name.to_s == param_name
      call.name.to_s
    end

    def hash_key_name(node)
      case node
      when Syntax::SymbolNode
        node.respond_to?(:value) ? node.value.to_s : node.slice.delete_prefix(":")
      when Syntax::StringNode
        node.respond_to?(:unescaped) ? node.unescaped : node.slice.delete_prefix("\"").delete_prefix("'").delete_suffix("\"").delete_suffix("'")
      else
        nil
      end
    end

    def tuple_confidence(types)
      constants = types.grep(/\A[A-Z]\w*(?:::[A-Z]\w*)*/)
      namespaces = constants.filter_map { |type| type.include?("::") ? type.split("::").first : nil }.uniq
      return "review" if namespaces.size == 1 && constants.size == types.size
      types.uniq.size == types.size ? "high" : "review"
    end

    def non_nil_return_sig?(sig)
      match = sig.match(/\.returns\((.+?)\)/)
      return false unless match
      type = match[1]
      !type.include?("T.nilable") && type != "T.untyped" && type != "NilClass"
    end

  end
end
