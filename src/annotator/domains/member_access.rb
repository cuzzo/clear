# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module MemberAccess
      extend T::Sig

      sig { params(node: AST::GetIndex).returns(T.nilable(Type)) }
      def visit_GetIndex(node)
        T.bind(self, SemanticAnnotator)

        visit(node.target)
        visit(node.index)

        target_type_info = node.target.full_type!(context: "index target")

        # Look up index operation from the registry
        op = resolve_index_op(target_type_info, :get)

        if op
          # Registry-driven: type and ownership from INDEX_OPS
          result_type = IntrinsicRegistry.to_return_def(op[:return_type])
                                        .resolve(target_type_info, [], self)
          if node.target.is_a?(AST::OptionalUnwrap) && !result_type.optional?
            result_type = Type.new(:"?#{result_type.resolved}")
          end
          stamp_type!(node, result_type)
          node.container_borrow = true if op[:container_borrow]

          # Validate key types for maps
          if target_type_info.map?
            index_type_info = node.index.full_type!(context: "index key")
            if target_type_info.numeric_map?
              error!(node, :NUMERIC_MAP_KEY_BAD, got: node.index.resolved_type) unless index_type_info&.numeric?
            else
              error!(node, :STRING_MAP_KEY_BAD, got: node.index.resolved_type) unless index_type_info&.string?
            end
          end

        # Special cases not covered by INDEX_OPS
        elsif target_type_info.promise_list?
          # Promise list indexing yields ~T (tense type); dispatch_key returns :array
          # but resolve_index_op guards against this above.
          elem_t = target_type_info.tense_type.element_type
          stamp_type!(node, Type.new(:"~#{elem_t.resolved}"))
        elsif target_type_info.string? && !target_type_info.raw?
          error!(node, :STRING_INDEX_BY_INT)
        elsif node.target.metatype == :struct
          # Struct field access via index (rare legacy path)
          stamp_type!(node, target_type_info.element_type)
          node.container_borrow = true
        else
          error!(node, :UNSUPPORTED_INDEX)
        end

        nil
      end

      sig { params(node: AST::GetField).returns(T.nilable(Object)) }
      def visit_GetField(node)
        T.bind(self, SemanticAnnotator)

        # Enum/Union variant access: TypeName.Variant
        # Must be checked BEFORE visiting target to avoid "variable not found" error.
        return if resolve_variant_access(node)

        visit(node.target)

        emit_moved_field_path_error_if_needed!(node)

        type = node.target.resolved_type

        # Struct Field Lookup
        if node.wildcard?
          stamp_type!(node, :Void)
          return
        end

        emit_capability_field_access_error_if_needed!(node)

        raw_schema = lookup_type_schema(type)
        if Schemas.enum?(raw_schema)
          error!(node, :ENUM_FIELD_ACCESS, enum: type)
          return
        end

        if raw_schema.is_a?(Schemas::UnionSchema) || (Schemas.union?(raw_schema))
          error!(node, :UNION_FIELD_ACCESS, union: type)
          return
        end

        unless Schemas.field_bearing?(raw_schema)
          error!(node, :ILLEGAL_FIELD_LOOKUP, field: node.field, type: type)
          return
        end

        struct_schema = T.cast(raw_schema, T.any(Schemas::StructSchema, Schemas::ResourceSchema))
        field_def = struct_schema.fields[node.field]
        unless field_def
          if node.token
            # Struct schema resolved but the requested field doesn't exist;
            # emit a typo suggestion when one of the fields is close.
            valid_fields = struct_schema.fields.keys.reject { |k| k.is_a?(Symbol) || k.to_s.start_with?('_') }
            emit_typo_suggestion!(
              node.token, node.field, valid_fields,
              "Struct '#{type}' has no field '#{node.field}'",
              "field of #{type}",
              category: :type, cascade: true
            )
          else
            error!(node, :ILLEGAL_FIELD_LOOKUP, field: node.field, type: type)
          end
          return
        end

        field_type = field_def.type
        # SOA tracking: record field access on pipeline variable `_`
        if phase_receiver_state.pipeline_accessed_fields && node.target.is_a?(AST::Identifier) && node.target.name == "_"
          T.must(phase_receiver_state.pipeline_accessed_fields).add(node.field)
        end
        # For generic instances (e.g. Pair<Number>), substitute type params into field type.
        # Handles compound types like T[], ?T, !T via apply_type_subst.
        # BORROWED fields are stored as plain types in the schema (borrowed_fields tracks which).
        type_obj = Type.new(type)
        if type_obj.generic_instance? && struct_schema.type_params
          subst = {}
          struct_schema.type_params.zip(type_obj.generic_args).each do |param, arg|
            subst[param] = arg.resolved
          end
          field_type = apply_type_subst(field_type, subst)
        end
        if field_type.indirect?
          # A struct-pointee @indirect field is an owned heap pointer that
          # moves like the old `%T`: bind/move the `*T`, let Zig auto-deref
          # field access, and free once. An explicit read-deref there turns
          # the move into a value copy and leaks the box. String/scalar and
          # union/enum pointees still need the read-deref (Zig won't coerce
          # `*T` -> `T` for those consumers).
          psch = lookup_type_schema(field_type.resolved)
          struct_pointee = Schemas.struct?(psch)
          node.indirect_field = true unless struct_pointee
          # For non-struct pointees, the read-deref produces a value of the
          # inner type (layout no longer applies). For struct pointees, the
          # binding holds the *T pointer directly -- keep layout=:indirect so
          # ti.zig_type renders "*T".
          if !struct_pointee
            field_type = field_type.dup
            field_type.strip_layout!
          end
        end
        if node.target.is_a?(AST::OptionalUnwrap) && !field_type.optional?
          field_type = Type.new(:"?#{field_type.resolved}")
        end
        stamp_type!(node, field_type)
      end

      sig { params(node: AST::GetField).void }
      def emit_moved_field_path_error_if_needed!(node)
        T.bind(self, SemanticAnnotator)

        path = get_path_to_root(node)
        return unless path

        # Check root, then progressively longer sub-paths.
        check = T.let("", String)
        path.each do |seg|
          check = check.empty? ? seg.to_s : "#{check}.#{seg}"
          if ownership_graph.moved?(check)
            emit_use_of_moved_path_error!(node, path, ownership_graph[check])
            break
          end
        end
      end
      private :emit_moved_field_path_error_if_needed!

      sig { params(node: AST::GetField).void }
      def emit_capability_field_access_error_if_needed!(node)
        T.bind(self, SemanticAnnotator)

        # Capability-wrapped bindings hide the inner T behind a lock /
        # atomic cell. Direct field access on the outer binding skips the
        # unwrap and produces a Zig-level "no field named X" since the
        # wrapper type doesn't have the field. Catch this early with a
        # CLEAR-level diagnostic that names the right WITH form.
        # Skip when this GetField is the LHS of an assignment -- field
        # writes are handled by visit_assignment_field's auto-lock path
        # (`assignment_node.auto_lock`), which emits the correct
        # lock-acquire-and-release inline.
        return unless node.target.is_a?(AST::Identifier)
        return if node.is_assignment_lhs

        sym = node.target.symbol
        in_auto_lock = phase_receiver_state.auto_locked_assign_name == node.target.name
        in_with_block = inside_with_block?
        cap_error = [
          [sym&.locked?, :CAP_FIELD_NEEDS_WITH_EXCLUSIVE, "EXCLUSIVE", "@locked"],
          [sym&.write_locked?, :CAP_FIELD_NEEDS_WITH_EXCLUSIVE, "EXCLUSIVE", "@writeLocked"],
          [sym&.atomic_ptr?, :CAP_FIELD_NEEDS_WITH_SNAPSHOT, "SNAPSHOT", "@indirect:atomic"],
        ].find { |candidate| candidate[0] }
        if cap_error && !in_auto_lock && !in_with_block
          emit_cap_field_needs_with!(node,
            cap_error[1], perm: cap_error[2],
            name: node.target.name, field: node.field, cap: cap_error[3])
        end
      end
      private :emit_capability_field_access_error_if_needed!

      sig { params(node: AST::Slice).void }
      def visit_Slice(node)
        T.bind(self, SemanticAnnotator)

        visit(node.target)
        visit(node.start) if node.start
        visit(node.end) if node.end

        # A slice of T[] is T[]
        # A slice of T[3] is T[] (Fixed becomes Dynamic view)
        target_type = node.target.full_type!(context: "slice target")
        if target_type&.array?
          element = target_type.element_type.resolved
          stamp_type!(node, Type.new(:"#{element}[]"))
        else
          stamp_type!(node, :Any)
        end
      end

      # Call-site recursion overrides are parsed but not lowered yet; emit a
      # precise diagnostic instead of silently generating wrong code.

      sig { params(node: AST::HashLit).void }
      def visit_HashLit(node)
        T.bind(self, SemanticAnnotator)

        # 1. Analyze values to find the Value Type (V)
        #    Assumption: Maps are homogeneous for now (e.g. all Int64)
        if node.pairs.empty?
          stamp_type!(node, :"HashMap<Any>")
          node.storage = :stack
          return
        end

        # Visiting keys populates type_info used by Auto inference for HashMap
        # key shape slots.
        node.pairs.each { |k, v| visit(k); visit(v) }

        # Infer Type from first value
        first_val_type = node.pairs.values.first.resolved_type

        # Simple check: Ensure all values match
        node.pairs.each do |k, v|
          if v.resolved_type != first_val_type
            error!(node, :HASHMAP_MIXED_VALUES)
          end
        end

        stamp_type!(node, Type.new(:"HashMap<#{first_val_type}>"))
        node.storage = :stack
      end

      sig { params(node: AST::StructLit).returns(T.nilable(Symbol)) }
      def visit_StructLit(node)
        T.bind(self, SemanticAnnotator)

        schema = lookup_type_schema(node.name.to_sym)
        if schema.nil?
          tok = node.token
          if tok
            emit_typo_suggestion!(
              tok, node.name, all_known_type_names,
              "Unknown struct type '#{node.name}'",
              "closest declared type",
              category: :type, cascade: true
            )
          else
            error!(node, :UNKNOWN_STRUCT_TYPE, name: node.name)
          end
        end

        # Union literal: Result{ Ok: 42 } or Option<Number>{ Some: 42.0 }
        # Reuses struct-literal syntax — no new parser changes required.
        if Schemas.union?(schema)
          if node.fields.length != 1
            error!(node, :UNION_LITERAL_VARIANT_COUNT, name: node.name, got: node.fields.length)
          end

          union_subst = literal_type_substitution!(node, schema)

          variant_name, val_node = node.fields.first
          unless schema.variants.key?(variant_name)
            anchor = variant_anchor_from_unionlit(node, variant_name)
            if anchor
              emit_variant_typo!(
                anchor, variant_name, schema.variants.keys,
                "Type Error: Union '#{node.name}' has no variant '#{variant_name}'.",
                "variant of union #{node.name}",
                cascade: true
              )
            else
              error!(node, :UNION_UNKNOWN_VARIANT, union: node.name, variant: variant_name)
            end
          end
          raw_expected = schema.variants[variant_name]
          if raw_expected.nil?
            error!(node, :UNION_VARIANT_IS_UNIT_NO_PAYLOAD, variant: variant_name, union: node.name, variant2: variant_name)
          end
          if Schemas.inline_struct?(raw_expected)
            error!(node, :UNION_INLINE_VARIANT_OLD_SYNTAX, union: node.name, variant: variant_name, union2: node.name, variant2: variant_name)
          end
          # @indirect single-type payload: unwrap inner type for type-checking;
          # mark the value node so the transpiler heap-allocates it via create(*T).
          indirect_payload = raw_expected.is_a?(Type) && raw_expected.indirect?
          raw_for_check = if indirect_payload
                            d = raw_expected.dup
                            d.strip_layout!
                            d
                          else
                            raw_expected
                          end
          # Apply type param substitution (e.g. T → Number for generic unions)
          expected_type = T.let(apply_type_subst(raw_for_check, union_subst), Type)
          visit(val_node)
          reject_borrowed_value!(val_node, "#{node.name}.#{variant_name}")
          # Ensure value is owned data (implicit COPY for @list/rodata strings).
          owned = T.let(ensure_owned_value!(val_node, expected_type, "#{node.name}.#{variant_name}"), T.nilable(AST::CopyNode))
          if owned
            node.fields[variant_name] = owned
            val_node = owned
          end
          if indirect_payload
            val_node.needs_heap_create = true
            current_fn_ctx&.record_heap_use!  # heapAlloc().create(*T) needs rt
          end
          actual = val_node.full_type!(context: "union payload")
          unless expected_type.accepts?(actual)
            error!(node, :UNION_PAYLOAD_MISMATCH, variant: variant_name, expected: expected_type.resolved, got: actual&.resolved)
          end
          move_if_not_copyable!(val_node)
          stamp_type!(node, literal_instance_type(node))
          return
        end

        # Empty struct literal: MyStruct{} — use all struct field defaults.
        if node.fields.empty?
          field_names = schema.fields.keys
          unless field_names.empty?
            field_defaults = schema.field_defaults || {}
            missing = field_names.reject { |f| field_defaults.key?(f) }
            if missing.any?
              error!(node, :STRUCT_LITERAL_MISSING_FIELDS, name: node.name, fields: missing.join(', '))
            end
          end
          stamp_type!(node, node.name.to_sym)
          return
        end

        # Build type param substitution map for generic struct instantiation.
        # e.g. Pair<Number>{ first: 1.0 } → { :T => :Float64 }
        type_subst = literal_type_substitution!(node, schema)

        # Iterate Fields (Validation)
        node.fields.each do |field_name, val_node|
          visit(val_node) # Resolve value type

          raw_expected = T.let(schema.fields[field_name]&.type, T.nilable(T.any(Type, Symbol)))
          if raw_expected.nil?
            valid_fields = schema.fields.keys.reject { |k| k.to_s.start_with?("_") }
            name_tok = node.field_tokens&.[](field_name)
            if name_tok
              emit_typo_suggestion!(
                name_tok, field_name, valid_fields,
                "Struct '#{node.name}' has no field '#{field_name}'",
                "field of #{node.name}",
                category: :type, cascade: true
              )
            else
              error!(node, :STRUCT_FIELD_UNRESOLVABLE, struct: node.name, field: field_name)
            end
          end

          # Check if this field is declared BORROWED in the struct definition
          field_is_borrowed = schema.borrowed_fields&.include?(field_name)

          # Apply type param substitution (e.g., T → Number, T[] → String[])
          expected_type = T.let(apply_type_subst(raw_expected, type_subst), Type)

          # BORROWED fields accept borrowed values — skip ownership checks.
          # Non-borrowed fields require owned data.
          unless field_is_borrowed
            reject_borrowed_value!(val_node, "#{node.name}.#{field_name}")
          end
          # Skip CopyNode wrapping for rodata strings in call argument structs.
          # The struct is a temporary - rodata strings are valid for the call's
          # lifetime. The callee dupes strings it needs to escape.
          is_call_arg = node.instance_variable_get(:@is_call_arg)
          owned = T.let(unless field_is_borrowed || is_call_arg
            ensure_owned_value!(val_node, expected_type, "#{node.name}.#{field_name}")
          end, T.nilable(AST::CopyNode))
          if owned
            node.fields[field_name] = owned
            val_node = owned
          end

          # Simple Type Check
          if val_node.full_type!(context: "struct field value") != expected_type
            unless is_safe_autocast?(val_node.resolved_type, expected_type)
              error!(node, :FIELD_TYPE_MISMATCH, field: field_name, expected: expected_type, got: val_node.resolved_type)
            end
            val_node.coerced_type = expected_type
          end

          move_if_not_copyable!(val_node) unless field_is_borrowed
        end

        # Non-escaping propagation: structs with BORROWED fields inherit non_escaping.
        node.borrowed_field_names = schema.borrowed_fields
        node.instance_variable_set(:@has_borrowed_fields, true) if schema.borrowed_fields&.any?

        stamp_type!(node, literal_instance_type(node))
      end

      sig { params(node: AST::ListLit).returns(T.nilable(T.any(Symbol, Type))) }
      def visit_ListLit(node)
        T.bind(self, SemanticAnnotator)

        # 1. Analyze all items
        node.items.each { |item| visit(item) }

        # Bounded stream literal: [BG{...}, BG{...}] where all items are promises.
        # Produces ~T[N] type — a fixed-size stream of N concurrent BG fibers.
        # This must be checked before the general array logic, since ~T items would
        # otherwise produce a bare ~T[] type (which is a compiler error).
        if !node.items.empty? && node.items.all? { |i| Type.new(i.resolved_type).future? }
          inner_types = node.items.map { |i| Type.new(i.resolved_type).tense_type.to_sym }.uniq
          if inner_types.size > 1
            error!(node, :BOUNDED_STREAM_MIXED_TYPES, types: inner_types.join(', '))
          end
          stamp_type!(node, Type.new(:"~#{inner_types.first}[#{node.items.size}]"))
          node.storage   = :stack
          return
        end

        if node.items.empty?
          # Untyped constructor: List[] or Pool[] — deferred element type.
          # The collection type is set; element type resolves on first append/insert.
          if (coll = node.instance_variable_get(:@constructor_collection))
            t = Type.new(:"Any[]", collection: coll)
            t.apply_constructor_collection!(
              collection: nil,
              soa: !!node.instance_variable_get(:@constructor_soa),
              shard_count: node.instance_variable_get(:@constructor_shard_count)
            )
            t.mark_heap_allocated! if coll == :pool || coll == :set
            stamp_type!(node, t)
            node.storage = (coll == :pool || coll == :set) ? :heap : :stack
            record_effect(EffectTracker::HEAP)
            return
          end
          if node.storage == :heap
            stamp_type!(node, Type.new(:"Any[]", location: :heap))
          else
            stamp_type!(node, :"Any[]")
          end
          return
        end

        # 2. Infer base type from the first element.
        #    If all items are string-like (Byte[N] or String), widen to String so mixed
        #    string lengths ("a", "bb", "ccc") don't produce a type error.
        if node.items.all? { |i| Type.new(i.resolved_type).string? }
          base_type = :String
        else
          base_type = node.items.first.resolved_type
          # 3. Validate Consistency — all items must share the same type.
          node.items.each_with_index do |item, index|
            next if index == 0
            if item.resolved_type != base_type
              error!(node, :LIST_LITERAL_MIXED_TYPES, base: base_type, index: index+1, got: item.resolved_type)
            end
          end
        end

        if node.storage == :stack
          stamp_type!(node, Type.new(:"#{base_type}[#{node.items.size}]"))
        else
          t = Type.new(:"#{base_type}[]", location: :heap)
          t.mark_frame_allocated!  # makeList uses frameAlloc for backing
          stamp_type!(node, t)
        end
      end

      sig { params(node: AST::DefaultArrayLit).returns(Type) }
      def visit_DefaultArrayLit(node)
        T.bind(self, SemanticAnnotator)
        type_info = Type.new(node.type_info)
        stamp_type!(node, type_info)
        node.storage = :stack
        type_info
      end

      sig { params(node: AST::RangeLit).returns(T.nilable(Type)) }
      def visit_RangeLit(node)
        T.bind(self, SemanticAnnotator)

        visit(node.start)
        visit(node.finish)

        start_type = node.start.resolved_type
        finish_type = node.finish.resolved_type

        unless Type.new(start_type).numeric?
          error!(node, :RANGE_START_NEEDS_NUMERIC, got: start_type)
        end

        unless Type.new(finish_type).numeric?
          error!(node, :RANGE_END_NEEDS_NUMERIC, got: finish_type)
        end

        # Only coerce to Float64 when mixing int and float bounds.
        # Pure-integer ranges stay Int64 (no unnecessary float conversion).
        start_is_float = Type.new(start_type).float?
        finish_is_float = Type.new(finish_type).float?
        if start_is_float != finish_is_float
          # Mixed: coerce both to Float64
          node.start.coerced_type = :Float64 unless start_is_float
          node.finish.coerced_type = :Float64 unless finish_is_float
        elsif start_is_float
          # Both float: no coercion needed
        else
          # Both integer: keep as-is (Int64 range)
        end

        base_type = if start_is_float || finish_is_float
          :Float64
        else
          :Int64
        end
        stamp_type!(node, Type.new(:"~#{base_type}[]"))
      end

      sig { params(args: T::Array[AST::Node], node: T.nilable(AST::Node)).returns(Symbol) }
      def infer_element_type(args, node)
        T.bind(self, SemanticAnnotator)

        receiver = args.first
        ti = receiver.is_a?(AST::Locatable) ? receiver.full_type!(context: "element receiver") : nil
        ti&.element_type&.resolved || :Any
      end

      # Infer return type for list.pop() — returns ?T (optional element type).

      sig { params(args: T::Array[AST::Node], node: T.nilable(AST::Node)).returns(Symbol) }
      def infer_optional_element_type(args, node)
        T.bind(self, SemanticAnnotator)

        receiver = args.first
        ti = receiver.is_a?(AST::Locatable) ? receiver.full_type!(context: "optional element receiver") : nil
        elem = ti&.element_type&.resolved || :Any
        :"?#{elem}"
      end

      # Infer return type for stream/list `.toList()` — an owned heap list
      # of the receiver's element type (unwrapping stream/promise tenses).

      sig { params(args: T::Array[AST::Node], node: T.nilable(AST::Node)).returns(Type) }
      def infer_to_list(args, node)
        T.bind(self, SemanticAnnotator)

        recv_t = Type.new(T.must(args[0]).resolved_type)
        elem_t = if recv_t.dynamic_stream? || recv_t.promise_list?
          recv_t.tense_type.element_type
        elsif recv_t.bounded_stream?
          recv_t.stream_element_type
        elsif recv_t.inf_stream?
          recv_t.inf_stream_element_type
        elsif recv_t.open_stream?
          recv_t.open_stream_element_type
        else
          recv_t.element_type
        end
        Type.new(:"#{T.must(elem_t).resolved}[]", collection: :list, location: :heap)
      end
    end
  end
end
