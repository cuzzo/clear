module OwnershipGenerator
  # Generates the `_moved` flag and `defer` cleanup block for a variable.
  def emit_cleanup(name, node)
    type_info = node.type_info
    storage = node.storage
    resource_close = node.resource_close_zig


    # Resources use a simple `defer close()` - use moved-flag to prevent double-close.
    if resource_close
      close_stmt = resource_close.gsub("{0}", name)
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) #{close_stmt};\n"
    end

    # Skip cleanup if ownership transferred via return (collections + strings)
    return "" if type_info&.escaped_return && (type_info.collection? || type_info.string?)

    # CleanupPlan-driven: check if the plan says this binding needs heap cleanup.
    # Covers all heap-promoted bindings (from returns_promoted callees) including
    # cases that walk_promote_callers missed (IF/MATCH branches, chained calls).
    fn_name = current_tp_ctx&.fn_name
    plan_entry = @cleanup_plans&.dig(fn_name)&.bindings&.dig(name.to_s)
    if plan_entry && plan_entry[:alloc] == :heap
      case plan_entry[:kind]
      when :heap_string
        return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) rt.heapAlloc().free(#{name});\n"
      when :heap_slice
        zig_type = type_info.zig_type
        return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
      when :heap_union
        zig_type = transpile_type(type_info.resolved.to_s)
        return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
      when :heap_struct
        zig_type = transpile_type(type_info.resolved.to_s)
        return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
      end
    end

    # ── Simple cases: use unified CheatLib.cleanup ──────────────────

    # Lists (non-sharded, non-heap-promoted): cleanup handles ArrayList.
    if type_info&.list_collection? && !type_info&.sharded? && !type_info&.heap_promoted
      zig_type = type_info.zig_type
      elem_type = type_info.element_type
      elem_resolved = elem_type&.resolved
      elem_schema = (@union_schemas ||= {})[elem_resolved]
      if elem_schema && elem_schema.any? { |_, vt| Type.variant_has_heap?(vt) }
        elem_zig = transpile_type(elem_resolved.to_s)
        return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) { for (#{name}.items) |*__e| { CheatLib.cleanup(#{elem_zig}, rt.heapAlloc(), __e); } #{name}.deinit(rt.frameAlloc()); };\n"
      end
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.frameAlloc(), &#{name});\n"
    end

    # Sharded/promoted lists: heapAlloc
    if type_info&.list_collection?
      zig_type = type_info.zig_type
      return "defer CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
    end

    # Pool
    if type_info&.pool?
      return "defer #{name}.deinit(rt.heapAlloc());\n"
    end

    # Set
    if type_info&.set_collection?
      zig_type = type_info.zig_type
      return "defer CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
    end

    # String maps: always heapAlloc (keys duped via heapAlloc)
    if type_info&.map? && !type_info&.numeric_map?
      zig_type = type_info.zig_type
      if type_info&.shared?
        return emit_rc_cleanup(name, type_info)
      end
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
    end

    # Numeric maps: frameAlloc (no key copies, backing array in frame arena)
    if type_info&.numeric_map?
      zig_type = type_info.zig_type
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.frameAlloc(), &#{name});\n"
    end

    # Struct with RC/link fields (non-RC, non-link, non-sync root)
    if !type_info&.any_rc? && !type_info&.link? && !type_info&.any_sync?
      resolved = type_info&.resolved
      schema = (@struct_schemas ||= {})[resolved]
      if schema && schema.any? { |k, v| !k.is_a?(Symbol) && (ft = v.is_a?(Hash) ? v[:type] : v; t = ft.is_a?(Type) ? ft : Type.new(ft || :Any); t.link? || t.any_rc?) }
        zig_type = transpile_type(resolved.to_s)
        return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
      end
    end

    return "" unless type_info&.requires_move? || type_info&.any_rc? || type_info&.any_sync? || type_info&.link?

    # ── Capability-wrapped types: RC, Sync, Link, Heap ──────────────
    is_link         = type_info&.link?
    is_rc           = type_info&.any_rc?
    is_shared       = type_info&.shared?
    is_locked       = type_info&.locked?
    is_write_locked = type_info&.write_locked?
    is_any_sync     = is_locked || is_write_locked
    is_heap         = storage == :heap && !is_rc && !is_any_sync && !is_link

    # RC types: use unified cleanup
    if is_rc || is_link
      return emit_rc_cleanup(name, type_info)
    end

    # Locked/RwLocked: use specific destroy (they need heap destroy, not field walk)
    if is_locked
      zig_inner_t = transpile_type(type_info.resolved.to_s)
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.lockedDestroy(#{zig_inner_t}, rt.heapAlloc(), #{name});\n"
    end
    if is_write_locked
      zig_inner_t = transpile_type(type_info.resolved.to_s)
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.rwLockedDestroy(#{zig_inner_t}, rt.heapAlloc(), #{name});\n"
    end

    # Heap-allocated plain structs: use free
    if is_heap
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.free(rt, #{name});\n"
    end

    "" # Stack type with no custom drop
  end

  # Emit cleanup for RC (Rc/Arc) and link (WeakRc/WeakArc) types.
  def emit_rc_cleanup(name, type_info)
    is_optional = type_info.optional?
    is_shared = type_info.shared?
    is_link = type_info.link?

    base_type = type_info.resolved.to_s
    base_type = base_type.sub(/^\?/, '') if is_optional

    zig_type = type_info.zig_type

    moved_guard = "var #{name}_moved = false; _ = &#{name}_moved;\n"

    if is_link
      source = type_info.link_source || :multiowned
      release_func = source == :shared ? "weakArcRelease" : "weakRcRelease"
      moved_guard += "defer if (!#{name}_moved) CheatLib.#{release_func}(#{transpile_type(base_type)}, #{name});\n"
    elsif is_optional
      release_func = is_shared ? "arcRelease" : "rcRelease"
      moved_guard += "defer if (!#{name}_moved) { if (#{name}) |_strong_ref| CheatLib.#{release_func}(#{transpile_type(base_type)}, rt.heapAlloc(), _strong_ref); };\n"
    else
      moved_guard += "defer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"
    end

    # RC structs: also emit releaseFields on the inner data.
    if type_info.any_rc? && !is_link && !is_optional
      base_zig = transpile_type(base_type)
      schema = (@struct_schemas ||= {})[type_info.resolved]
      if schema
        moved_guard += "defer if (!#{name}_moved) CheatLib.releaseFields(#{base_zig}, rt.heapAlloc(), #{name}.ctrl.data.*);\n"
      end
    end

    moved_guard
  end

  # Marks the source identifier as moved if it requires affine transfer.
  def emit_move_suppression(rhs_node)
    if rhs_node.is_a?(AST::Identifier)
      ti = rhs_node.type_info
      return "" unless ti

      is_rc = ti.any_rc? rescue false
      is_sync = ti.any_sync? rescue false
      is_resource = ti.resource? rescue false
      is_collection = ti.collection? rescue false
      is_heap = rhs_node.storage == :heap

      # Escaped variables have no _moved guard (cleanup suppressed for return)
      return "" if ti.escaped_return && (is_collection || ti.string?)

      # RC types: only move on explicit GIVE
      if is_rc
        return "#{rhs_node.name}_moved = true;" if @current_rhs_is_move
        return ""
      end

      # Move when: heap storage, resource, sync, or any type that requires move
      should_suppress = (ti.requires_move? || is_sync || is_resource) &&
                        (is_heap || is_resource)

      # Also move for collections (map, list, pool, set) — they have _moved guards
      should_suppress ||= is_collection

      # Also move for non-copyable types (unions with heap variants, etc.)
      unless should_suppress
        schema_lookup = ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) }
        should_suppress = !ti.implicitly_copyable?(schema_lookup)
      end

      # Only emit _moved for local variables (not function parameters).
      # Parameters don't have var X_moved = false guards.
      if should_suppress
        sym = rhs_node.respond_to?(:symbol) ? rhs_node.symbol : nil
        decl = sym&.reg
        is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
        # Only emit if the variable has a _moved guard (mutable + defer with _moved).
        # Check if variable has a _moved guard: mutable locals, heap_promoted, or CleanupPlan.
        fn_name = current_tp_ctx&.fn_name
        plan_entry = @cleanup_plans&.dig(fn_name)&.bindings&.dig(rhs_node.name)
        has_moved_guard = is_local && (sym&.mutable || ti.heap_promoted || plan_entry)
        return "#{rhs_node.name}_moved = true;" if has_moved_guard
      end
    end
    ""
  end

  # Emit _moved = true statements for arguments consumed by a call or construction.
  # Called after visit() for FuncCall (TAKES/append), StructLit, UnionVariantLit.
  def emit_consumed_moves(node)
    moves = []
    # Unwrap VarDecl/BindExpr to get the value expression (FuncCall, StructLit, etc.)
    inner = node
    inner = node.value if node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    inner = inner.value if inner.is_a?(AST::MoveNode)

    args = case inner
    when AST::StructLit
      inner.fields.values.select { |v| v.is_a?(AST::Identifier) }
    when AST::FuncCall, AST::MethodCall
      consumed = inner.args.select { |a| a.respond_to?(:was_moved) && a.was_moved && a.is_a?(AST::Identifier) } +
        inner.args.select { |a| a.is_a?(AST::MoveNode) && a.value.is_a?(AST::Identifier) }.map(&:value)
      # Intrinsic append: the value arg is consumed by the collection.
      # For MethodCall: args = [value], object = list
      # For FuncCall (UFCS): args = [list, value]
      if inner.respond_to?(:zig_pattern) && inner.zig_pattern.is_a?(String) && inner.zig_pattern.include?("append")
        val_arg = inner.args.last
        val_arg = val_arg.is_a?(AST::MoveNode) ? val_arg.value : val_arg
        consumed << val_arg if val_arg.is_a?(AST::Identifier) && !consumed.include?(val_arg)
      end
      consumed
    else
      []
    end

    args.each do |arg|
      name = arg.respond_to?(:name) ? arg.name : nil
      next unless name
      ti = arg.type_info
      ti = Type.new(ti) if ti && !ti.is_a?(Type)
      next unless ti

      # Only emit _moved for local variables that have a _moved guard.
      # Skip: parameters, immutable-without-plan, escaped variables (no defer).
      sym = arg.respond_to?(:symbol) ? arg.symbol : nil
      decl = sym&.reg
      is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
      next unless is_local
      next if ti.escaped_return && (ti.collection? || ti.string?)
      fn_name = current_tp_ctx&.fn_name
      plan_entry = @cleanup_plans&.dig(fn_name)&.bindings&.dig(name)
      has_guard = sym&.mutable || ti.heap_promoted || plan_entry
      next unless has_guard

      needs_move = ti.collection? || ti.map? || (ti.requires_move? rescue false) ||
                   ti.any_rc? || ti.any_sync? || ti.link? || ti.heap_promoted
      moves << "#{zig_safe_name(name)}_moved = true;" if needs_move
    end

    moves.join("\n")
  end

  def transpile_rc_retain(type_info, name)
    func = type_info.shared? ? "arcRetain" : "rcRetain"
    "CheatLib.#{func}(#{transpile_type(type_info.resolved.to_s)}, #{name})"
  end
end
