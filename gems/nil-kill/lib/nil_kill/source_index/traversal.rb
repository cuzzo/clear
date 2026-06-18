# typed: false
# frozen_string_literal: true

module NilKill
  class SourceIndex
    def walk(node, scope)
      case node
      when Syntax::ClassNode, Syntax::ModuleNode
        new_scope = scope + [node.constant_path.slice]
        old_class = @current_class_name
        old_t_struct_owner = @current_t_struct_owner
        @current_class_name = new_scope.join("::")
        @current_t_struct_owner = t_struct_class_node?(node) ? new_scope.join("::") : nil
        begin
          child_walk(node.body, new_scope)
        ensure
          @current_class_name = old_class
          @current_t_struct_owner = old_t_struct_owner
        end
      when Syntax::DefNode
        record = method_record(node, scope)
        record["return_origin"] = analyze_return_origin(node, record)
        @methods << record unless @warm_only
        @return_origins << record["return_origin"] if record["return_origin"] && !@warm_only
        if record["return_origin"] && record["return_origin"]["confidence"] == "strong"
          type = record["return_origin"]["candidate_type"]
          (@static_return_types[record["method"]] = type; @ep[0] += 1) if NilKill.useful_type?(type)
        end
        if record["return_origin"] && record["return_origin"]["hash_shape"] && !record["return_origin"]["hash_shape"]["poisoned"]
          @static_hash_return_shapes[record["method"]] = record["return_origin"]["hash_shape"]
        end
        if record["return_origin"] && record["return_origin"]["array_element_shape"] && !record["return_origin"]["array_element_shape"]["poisoned"]
          @static_array_element_return_shapes[record["method"]] = record["return_origin"]["array_element_shape"]
        end
        @method_nodes << [node, record] unless @warm_only
        inspect_dispatcher(node, record) unless @warm_only
        old_t_struct_owner = @current_t_struct_owner
        @current_t_struct_owner = nil
        begin
          scoped_facts(record) { child_walk(node.body, scope) }
        ensure
          @current_t_struct_owner = old_t_struct_owner
        end
      when Syntax::IfNode
        inspect_branch_guard(node, inverted: false) unless @warm_only
        child_walk(node, scope)
      when Syntax::UnlessNode
        inspect_branch_guard(node, inverted: true) unless @warm_only
        child_walk(node, scope)
      when Syntax::CallNode
        walk_call(node, scope)
      when Syntax::ConstantWriteNode, Syntax::ConstantPathWriteNode
        if (block_scope = assigned_struct_block_scope(node, scope))
          walk_call(node.value, scope, block_scope: block_scope)
        else
          child_walk(node, scope)
        end
      when Syntax::ArrayNode
        inspect_array_literal(node) unless @warm_only
        child_walk(node, scope)
      when Syntax::HashNode
        inspect_hash_literal(node) unless @warm_only
        child_walk(node, scope)
      when Syntax::LocalVariableWriteNode
        update_local_fact(node)
        inspect_local_container_origin(node) unless @warm_only
        child_walk(node, scope)
      when Syntax::InstanceVariableWriteNode, Syntax::ClassVariableWriteNode, Syntax::GlobalVariableWriteNode
        inspect_variable_write(node) unless @warm_only
        inspect_ivar_container_origin(node) unless @warm_only
        child_walk(node, scope)
      else
        child_walk(node, scope)
      end
    end

    def child_walk(node, scope)
      return unless node&.respond_to?(:child_nodes)
      node.compact_child_nodes.each { |child| walk(child, scope) }
    end

    def walk_call(node, scope, block_scope: scope)
      inspect_param_origins(node, scope) unless @warm_only
      update_collection_builder_call(node)
      inspect_call(node) unless @warm_only
      inspect_included_module(node, scope) unless @warm_only
      inspect_sorbet_state_field(node) unless @warm_only
      inspect_index_lookup(node, scope) unless @warm_only
      inspect_hash_record_blocker(node, scope) unless @warm_only
      inspect_hash_record_member_call(node, scope) unless @warm_only
      inspect_struct_constructor(node)
      inspect_class_constructor_fields(node)
      inspect_attribute_shape_write(node)
      walk_call_children(node, scope, block_scope: block_scope)
    end

    def walk_call_children(node, scope, block_scope: scope)
      block = node.block
      unless block && block.respond_to?(:body)
        child_walk(node, scope)
        return
      end

      old_hash_shapes = @current_hash_shapes
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        shape = block_param_shapes_for_call(node)[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      [node.receiver, node.arguments].compact.each { |child| walk(child, scope) }
      walk(block, block_scope)
    ensure
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    def recompute_return_origins_with_inferred_shapes
      return if @method_nodes.empty?
      latest_origins = []
      2.times do
        latest_origins = []
        @method_nodes.each do |node, record|
          origin = analyze_return_origin(node, record)
          record["return_origin"] = origin
          latest_origins << origin if origin
          if origin && origin["confidence"] == "strong"
            type = origin["candidate_type"]
            (@static_return_types[record["method"]] = type; @ep[0] += 1) if NilKill.useful_type?(type)
          end
          if origin && origin["hash_shape"] && !origin["hash_shape"]["poisoned"]
            @static_hash_return_shapes[record["method"]] = origin["hash_shape"]
          end
          if origin && origin["array_element_shape"] && !origin["array_element_shape"]["poisoned"]
            @static_array_element_return_shapes[record["method"]] = origin["array_element_shape"]
          end
        end
      end
      @return_origins = latest_origins
    end

    def recompute_collection_index_lookups_with_inferred_shapes
      return if @method_nodes.empty?
      @collection_index_lookups = []
      @hash_record_blockers = []
      @method_nodes.each do |node, record|
        scoped_facts(record) do
          collect_collection_index_facts(node.body, Array(record["scope"]))
        end
      end
    end

    # The main walk leaves a `Struct.new(local, ...)` arg untyped
    # (@current_local_types is only populated by the return-origin
    # pass). Re-resolve with local-type facts so the field slot isn't
    # needlessly skipped; a still-unresolvable arg keeps its empty type.
    def recompute_struct_field_static_with_inferred_locals
      return if @method_nodes.empty? || @struct_field_static.empty?
      index = Hash.new { |h, k| h[k] = [] }
      @struct_field_static.each do |entry|
        index[[entry["path"], entry["line"], entry["class"], entry["field"], entry["expression"]]] << entry
      end
      @method_nodes.each do |node, record|
        scoped_facts(record) do
          collect_local_type_facts(node.body)
          refill_struct_constructor_types(node.body, index)
        end
      end
    end

    def refill_struct_constructor_types(node, index)
      return unless node
      return if nested_scope_node?(node)
      if node.is_a?(Syntax::CallNode) && node.name == :new && node.receiver
        klass = const_name(node.receiver)
        fields = @struct_fields_by_name[klass] || @struct_fields_by_name[klass.split("::").last] ||
          self.class.struct_fields_by_name[klass] || self.class.struct_fields_by_name[klass.split("::").last]
        if fields
          full_class = @struct_full_by_name[klass] || @struct_full_by_name[klass.split("::").last] ||
            self.class.struct_full_by_name[klass] || self.class.struct_full_by_name[klass.split("::").last] || klass
          (node.arguments&.arguments || []).each_with_index do |arg, idx|
            next if idx >= fields.size || arg.is_a?(Syntax::KeywordHashNode)
            entries = index[[@rel, node.location.start_line, full_class, fields[idx], arg.slice]]
            next if entries.empty?
            next if entries.all? { |e| NilKill.useful_type?(e["type"].to_s) }
            resolved = expression_type(arg)
            next unless NilKill.useful_type?(resolved)
            entries.each { |e| e["type"] = resolved unless NilKill.useful_type?(e["type"].to_s) }
            merge_struct_field_static_type(full_class, fields[idx], resolved)
          end
        end
      end
      node.compact_child_nodes.each { |child| refill_struct_constructor_types(child, index) } if node.respond_to?(:child_nodes)
    end

    def collect_local_container_origins(node)
      return unless node
      return if nested_scope_node?(node)
      case node
      when Syntax::LocalVariableWriteNode
        inspect_local_container_origin(node)
      when Syntax::InstanceVariableWriteNode, Syntax::ClassVariableWriteNode, Syntax::GlobalVariableWriteNode
        inspect_ivar_container_origin(node)
      end
      node.compact_child_nodes.each { |child| collect_local_container_origins(child) } if node.respond_to?(:child_nodes)
    end

    def collect_collection_index_facts(node, scope)
      return unless node
      return if nested_scope_node?(node)
      case node
      when Syntax::CallNode
        update_collection_builder_call(node)
        inspect_index_lookup(node, scope)
        inspect_hash_record_blocker(node, scope)
        inspect_hash_record_member_call(node, scope)
        collect_call_collection_index_facts(node, scope)
      when Syntax::LocalVariableWriteNode
        update_local_fact(node)
        inspect_local_container_origin(node)
        node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) } if node.respond_to?(:child_nodes)
      else
        node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) } if node.respond_to?(:child_nodes)
      end
    end

    def collect_call_collection_index_facts(node, scope)
      block = node.block
      unless block && block.respond_to?(:body)
        node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) }
        return
      end
      old_hash_shapes = @current_hash_shapes
      self.current_hash_shapes = dup_hash_shapes(@current_hash_shapes)
      block_param_names(block).each_with_index do |name, idx|
        shape = block_param_shapes_for_call(node)[idx]
        @current_hash_shapes[name] = dup_hash_shape(shape) if name && shape
      end
      node.compact_child_nodes.each { |child| collect_collection_index_facts(child, scope) }
    ensure
      self.current_hash_shapes = old_hash_shapes if old_hash_shapes
    end

    # Fused single-traversal replacement for the four pure pre-walk
    # collectors (struct_declarations / class_like_constants /
    # non_nil_method_returns / ivar_tlet_names). They each independently
    # DFS'd the whole file; this performs the union of their per-node
    # work in one DFS. cscope is the const_name-derived scope used by
    # the struct + class-constant logic; iscope is the constant_path
    # .slice-derived scope used by the ivar T.let logic (the two scope
    # strings can differ, so both are threaded). non_nil ignores scope.
    # Accumulators are disjoint and the single DFS order matches each
    # original collector's DFS order, so output is byte-identical.
    def collect_prescan(node, cscope, iscope)
      case node
      when Syntax::ClassNode, Syntax::ModuleNode
        name = const_name(node.constant_path)
        full_name = (cscope + [name]).join("::")
        @class_like_constants.add(full_name)
        @class_like_constants.add(name)
        child_c = cscope + [name]
        child_i = iscope + [node.constant_path.slice]
        node.compact_child_nodes.each { |child| collect_prescan(child, child_c, child_i) }
        return
      when Syntax::ConstantWriteNode, Syntax::ConstantPathWriteNode
        if struct_new_call?(node.value) || data_define_call?(node.value)
          klass_scope = assigned_constant_scope(node, cscope)
          klass = klass_scope.join("::")
          fields = struct_fields(node.value)
          if fields.any?
            rec = TypedRecords::StructDeclarationRecord.new(
              path: @rel,
              line: node.location.start_line,
              owner: klass,
              fields: fields,
            ).to_source_index_hash
            @struct_declarations << rec unless @warm_only
            @struct_fields_by_name[klass] = fields
            self.class.struct_fields_by_name[klass] = fields
            @struct_full_by_name[klass] = klass
            self.class.struct_full_by_name[klass] = klass
            short = klass.split("::").last
            unless @struct_fields_by_name.key?(short)
              @struct_fields_by_name[short] = fields
              @struct_full_by_name[short] = klass
            end
            unless self.class.struct_fields_by_name.key?(short)
              self.class.struct_fields_by_name[short] = fields
              self.class.struct_full_by_name[short] = klass
            end
          end
          @class_like_constants.add(klass)
          @class_like_constants.add(klass_scope.last)
          if node.value.is_a?(Syntax::CallNode) && (block_cscope = assigned_struct_block_scope(node, cscope))
            block_iscope = assigned_struct_block_scope(node, iscope) || block_cscope
            collect_prescan_call(node.value, cscope, iscope, block_cscope: block_cscope, block_iscope: block_iscope)
            return
          end
        end
      when Syntax::InstanceVariableWriteNode
        val = node.value
        if val.is_a?(Syntax::CallNode) && val.name == :let && val.receiver&.slice == "T"
          name = node.name.to_s
          @ivar_tlet_names.add(name)
          type_node = (val.arguments&.arguments || [])[1]
          if type_node && !iscope.empty?
            type_str = type_node.slice
            (@ivar_tlet_types[[iscope.join("::"), name]] = type_str; @ep[0] += 1) if NilKill.useful_type?(type_str)
          end
        end
      when Syntax::DefNode
        sig = sig_above(node.location.start_line)
        if sig
          ret = NilKill.extract_return_type(sig)
          (@method_return_types[node.name.to_s] << ret; @ep[0] += 1) if ret
          @non_nil_method_returns << node.name.to_s if non_nil_return_sig?(sig)
        end
      end
      node.compact_child_nodes.each { |child| collect_prescan(child, cscope, iscope) } if node.respond_to?(:compact_child_nodes)
    end

    def assigned_struct_block_scope(node, scope)
      value = node.value
      return nil unless value.is_a?(Syntax::CallNode)
      return nil unless struct_new_call?(value) || data_define_call?(value)
      block = value.block
      return nil unless block && block.respond_to?(:body)

      assigned_constant_scope(node, scope)
    end

    def inspect_included_module(node, scope)
      return unless node.name == :include
      return if scope.empty?

      owner = scope.join("::")
      (node.arguments&.arguments || []).each do |arg|
        name = const_name(arg)
        next if name.empty?

        @included_modules << TypedRecords::IncludedModuleRecord.new(
          path: @rel,
          line: node.location.start_line,
          owner: owner,
          module_name: qualify_included_module_name(scope, name),
        ).to_source_index_hash
      end
    end

    def inspect_sorbet_state_field(node)
      return unless @current_t_struct_owner
      return unless %i[const prop].include?(node.name)
      return if node.receiver

      args = node.arguments&.arguments || []
      field_arg = args[0]
      type_arg = args[1]
      return unless field_arg.is_a?(Syntax::SymbolNode) && type_arg

      field = field_arg.value.to_s
      declared_type = type_arg.slice.to_s.strip
      return if field.empty? || declared_type.empty?

      @sorbet_state_fields << TypedRecords::SorbetStateFieldRecord.new(
        path: @rel,
        line: node.location.start_line,
        owner: @current_t_struct_owner,
        field: field,
        declared_type: declared_type,
      ).to_source_index_hash
    end

    def t_struct_class_node?(node)
      node.is_a?(Syntax::ClassNode) && node.slice.lines.first.to_s.match?(/<\s*T::Struct\b/)
    end

    def qualify_included_module_name(scope, name)
      raw_name = name.to_s
      return raw_name.delete_prefix("::") if raw_name.include?("::")

      (scope[0...-1] + [raw_name]).join("::")
    end

    def assigned_constant_scope(node, scope)
      raw_name = node.name.to_s
      parts = raw_name.split("::").reject(&:empty?)
      return scope if parts.empty?
      return parts if raw_name.start_with?("::")
      return parts if !scope.empty? && parts.first == scope.first

      scope + parts
    end

    def collect_prescan_call(node, cscope, iscope, block_cscope:, block_iscope:)
      block = node.block
      unless block && block.respond_to?(:body)
        node.compact_child_nodes.each { |child| collect_prescan(child, cscope, iscope) }
        return
      end

      [node.receiver, node.arguments].compact.each { |child| collect_prescan(child, cscope, iscope) }
      collect_prescan(block, block_cscope, block_iscope)
    end

  end
end
