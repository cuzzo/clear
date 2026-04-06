module OwnershipGenerator
  # Returns the Zig allocator expression from provenance (or cleanup_alloc fallback).
  def cleanup_alloc_expr(type_info)
    case type_info&.provenance_alloc
    when :heap then "rt.heapAlloc()"
    when :frame then "rt.frameAlloc()"
    else "rt.heapAlloc()" # fallback
    end
  end

  # Returns the Zig allocator expression for NEW allocations (backing stores, buffers).
  def storage_alloc_expr(type_info)
    case type_info&.storage_alloc
    when :heap then "rt.heapAlloc()"
    when :frame then "rt.frameAlloc()"
    else "rt.frameAlloc()" # default: frame arena
    end
  end

  def alloc_expr_from_plan(entry)
    case entry[:alloc]
    when :heap then "rt.heapAlloc()"
    when :frame then "rt.frameAlloc()"
    else "rt.heapAlloc()"
    end
  end

  # ── THE SINGLE CLEANUP EMITTER ────────────────────────────────
  #
  # Generates the `_moved` flag and `defer` cleanup block for a variable.
  # ALL decisions come from the CleanupPlan. No type inference here.
  def emit_cleanup(name, node)
    fn_name = current_tp_ctx&.fn_name
    entry = @cleanup_plans&.dig(fn_name)&.lookup(name.to_s)

    # No plan entry = no cleanup needed.
    return "" unless entry && entry[:needs_cleanup]

    emit_cleanup_from_entry(name, entry, node)
  end

  # Mechanical Zig template emitter. Reads only from the plan entry.
  # No type checks, no schema lookups. The entry has everything.
  def emit_cleanup_from_entry(name, entry, node = nil)
    alloc = alloc_expr_from_plan(entry)
    guard = entry[:has_moved_guard]

    case entry[:kind]
    when :resource
      close_zig = entry[:resource_close_zig]
      close_stmt = close_zig.gsub("{0}", name)
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) #{close_stmt};\n"

    when :list_with_elem_cleanup
      # List with union elements needing cleanup. Elements may contain
      # mixed-provenance strings (heap-duped, frame-arena, rodata).
      # cleanupAlloc checks pointer provenance: skips frame, frees heap.
      ti = node&.type_info
      zig_type = ti&.zig_type || "UNKNOWN"
      elem_zig = ti&.element_type ? transpile_type(ti.element_type.resolved.to_s) : "UNKNOWN"
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) { for (#{name}.items) |*__e| { CheatLib.cleanup(#{elem_zig}, rt.cleanupAlloc(), __e); } #{name}.deinit(rt.frameAlloc()); };\n"

    when :list
      ti = node&.type_info
      zig_type = ti&.zig_type || "UNKNOWN"
      if guard
        "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"
      else
        "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"
      end

    when :string_map, :numeric_map
      ti = node&.type_info
      zig_type = ti&.zig_type || "UNKNOWN"
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"

    when :pool
      "defer #{name}.deinit(#{alloc});\n"

    when :set
      ti = node&.type_info
      zig_type = ti&.zig_type || "UNKNOWN"
      "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"

    when :rc
      # RC/link/shared map: delegate to existing emit_rc_cleanup
      ti = node&.type_info
      return "" unless ti
      emit_rc_cleanup(name, ti)

    when :locked
      ti = node&.type_info
      zig_inner_t = transpile_type(ti.resolved.to_s)
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.lockedDestroy(#{zig_inner_t}, #{alloc}, #{name});\n"

    when :write_locked
      ti = node&.type_info
      zig_inner_t = transpile_type(ti.resolved.to_s)
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.rwLockedDestroy(#{zig_inner_t}, #{alloc}, #{name});\n"

    when :heap_string
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) rt.heapAlloc().free(#{name});\n"

    when :heap_slice, :heap_union, :heap_struct
      ti = node&.type_info
      zig_type = if entry[:kind] == :heap_slice
        # COPY produces a bare slice ([]T). Function returns may produce ArrayList.
        # Check source: CopyNode value -> slice, otherwise use type_info's zig_type.
        is_copy_value = node.respond_to?(:value) && node.value.is_a?(AST::CopyNode)
        if is_copy_value && !ti&.list_collection?
          elem_zig = ti&.element_type ? transpile_type(ti.element_type) : "UNKNOWN"
          "[]#{elem_zig}"
        else
          ti&.zig_type || "UNKNOWN"
        end
      else
        transpile_type((ti&.resolved || :Any).to_s)
      end
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"

    when :struct_with_cleanup_fields, :struct_rc
      ti = node&.type_info
      zig_type = transpile_type((ti&.resolved || :Any).to_s)
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"

    when :heap_struct_plain
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.free(rt, #{name});\n"

    when :array_with_struct_strings
      ti = node&.type_info
      ti = Type.new(ti) if ti && !ti.is_a?(Type)
      elem_zig = ti&.element_type ? transpile_type(ti.element_type) : "UNKNOWN"
      is_fixed = ti&.fixed?
      if is_fixed
        "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) { for (&#{name}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{alloc}, __e); } };\n"
      else
        # Dynamic array (User[]) becomes ArrayListUnmanaged via makeList.
        # Element strings are heap-duped; list backing is frame-allocated
        # (reclaimed automatically). Only need to free string fields.
        "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) { for (#{name}.items) |*__e| { CheatLib.cleanup(#{elem_zig}, rt.heapAlloc(), __e); } };\n"
      end

    when :non_copy_union
      ti = node&.type_info
      zig_type = transpile_type((ti&.resolved || :Any).to_s)
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"

    when :takes_union
      ti = node&.type_info
      zig_type = ti ? transpile_type(ti.resolved.to_s) : "UNKNOWN"
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, rt.heapAlloc(), &#{name});\n"

    when :takes_string
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) rt.heapAlloc().free(#{name});\n"

    when :takes_slice
      # TAKES slice: callee owns the buffer. Clean up elements then free buffer.
      # Caller ensures buffer is heap-owned (via implicit COPY of @list).
      ti = node&.type_info
      elem_zig = ti&.element_type ? transpile_type(ti.element_type.resolved.to_s) : "UNKNOWN"
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) { if (comptime CheatLib.needsCleanup(#{elem_zig})) { for (#{name}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{alloc}, __e); } } if (#{name}.len > 0) #{alloc}.free(#{name}); };\n"

    when :match_as_slice
      # The element type and cleanup are emitted by the MATCH transpiler
      # which has access to the variant schema. This entry just provides
      # the _moved guard decision.
      "" # MATCH transpiler handles the actual defer

    when :match_as_inline_struct
      "" # MATCH transpiler handles the actual defer

    else
      "" # Unknown kind, no cleanup
    end
  end

  # Emit cleanup for RC (Rc/Arc) and link (WeakRc/WeakArc) types.
  def emit_rc_cleanup(name, type_info)
    is_optional = type_info.optional?
    is_shared = type_info.shared?
    is_link = type_info.link?
    alloc = cleanup_alloc_expr(type_info)

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
      moved_guard += "defer if (!#{name}_moved) { if (#{name}) |_strong_ref| CheatLib.#{release_func}(#{transpile_type(base_type)}, #{alloc}, _strong_ref); };\n"
    else
      moved_guard += "defer if (!#{name}_moved) CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"
    end

    # RC structs: also emit releaseFields on the inner data.
    # Skip when a sync layer is present (@shared:locked, etc.) — the Arc/Rc
    # release already handles Locked/RwLocked inner cleanup via arcDeinitInner.
    # Emitting releaseFields(BaseType) would use the wrong type (BaseType vs Locked(BaseType)).
    if type_info.any_rc? && !is_link && !is_optional && !type_info.sync
      base_zig = transpile_type(base_type)
      schema = (@struct_schemas ||= {})[type_info.resolved]
      if schema
        moved_guard += "defer if (!#{name}_moved) CheatLib.releaseFields(#{base_zig}, #{alloc}, #{name}.ctrl.data.*);\n"
      end
    end

    moved_guard
  end

  # ── MOVE SUPPRESSION ──────────────────────────────────────────
  #
  # Sets _moved = true when a binding is consumed.
  # ALL guard decisions come from the CleanupPlan.
  def emit_move_suppression(rhs_node)
    if rhs_node.is_a?(AST::Identifier)
      # OG-driven: if annotator marked this node as moved, emit _moved = true
      if rhs_node.was_moved
        sym = rhs_node.respond_to?(:symbol) ? rhs_node.symbol : nil
        decl = sym&.reg
        is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
        is_takes = sym&.respond_to?(:takes) && sym&.takes
        if is_local || is_takes
          ti = rhs_node.type_info
          return "" if ti&.string?
          return "" if ti&.escaped_return && ti.collection?

          fn_name = current_tp_ctx&.fn_name
          entry = @cleanup_plans&.dig(fn_name)&.lookup(rhs_node.name)
          return "#{zig_safe_name(rhs_node.name)}_moved = true;" if entry && entry[:has_moved_guard]
        end
        return ""
      end

      ti = rhs_node.type_info
      return "" unless ti

      is_rc = ti.any_rc? rescue false
      is_sync = ti.any_sync? rescue false
      is_resource = ti.resource? rescue false
      is_collection = ti.collection? rescue false
      is_heap = rhs_node.storage == :heap

      return "" if ti.escaped_return && (is_collection || ti.string?)

      # RC types: only move on explicit GIVE
      if is_rc
        return "#{rhs_node.name}_moved = true;" if @current_rhs_is_move
        return ""
      end

      # Determine if this binding should be moved
      should_suppress = (ti.requires_move? || is_sync || is_resource) &&
                        (is_heap || is_resource)
      should_suppress ||= is_collection

      unless should_suppress || ti.string?
        schema_lookup = ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) }
        should_suppress = !ti.implicitly_copyable?(schema_lookup)
      end

      if should_suppress
        sym = rhs_node.respond_to?(:symbol) ? rhs_node.symbol : nil
        decl = sym&.reg
        is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
        if is_local
          fn_name = current_tp_ctx&.fn_name
          entry = @cleanup_plans&.dig(fn_name)&.lookup(rhs_node.name)
          return "#{rhs_node.name}_moved = true;" if entry && entry[:has_moved_guard]
        end
      end
    end
    ""
  end

  # Emit _moved = true statements for arguments consumed by a call or construction.
  def emit_consumed_moves(node)
    moves = []
    inner = node
    inner = node.value if node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr) || node.is_a?(AST::ReturnNode)
    inner = inner.value if inner.is_a?(AST::MoveNode)

    args = case inner
    when AST::StructLit
      inner.fields.values.select { |v| v.is_a?(AST::Identifier) }
    when AST::FuncCall, AST::MethodCall
      # was_moved is set by the annotator for TAKES params (both user-defined
      # functions and stdlib intrinsics). No zig_pattern hacks needed.
      consumed = inner.args.select { |a| a.respond_to?(:was_moved) && a.was_moved && a.is_a?(AST::Identifier) } +
        inner.args.select { |a| a.is_a?(AST::MoveNode) && a.value.is_a?(AST::Identifier) }.map(&:value)
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

      sym = arg.respond_to?(:symbol) ? arg.symbol : nil
      decl = sym&.reg
      is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
      next unless is_local
      next if ti.string?
      next if ti.escaped_return && (ti.collection? || ti.string?)

      fn_name = current_tp_ctx&.fn_name
      entry = @cleanup_plans&.dig(fn_name)&.lookup(name)
      next unless entry && entry[:has_moved_guard]

      needs_move = ti.collection? || ti.map? || (ti.requires_move? rescue false) ||
                   ti.any_rc? || ti.any_sync? || ti.link? || ti.heap_provenance?
      moves << "#{zig_safe_name(name)}_moved = true;" if needs_move
    end

    moves.join("\n")
  end

  def transpile_rc_retain(type_info, name)
    func = type_info.shared? ? "arcRetain" : "rcRetain"
    "CheatLib.#{func}(#{transpile_type(type_info.resolved.to_s)}, #{name})"
  end
end
