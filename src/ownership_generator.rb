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

  # Guarded defer: wraps body in moved-guard pattern.
  def guarded_defer(name, body)
    "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) #{body};\n"
  end

  # Most common pattern: guarded defer calling CheatLib.cleanup.
  def guarded_cleanup(name, zig_type, alloc)
    guarded_defer(name, "CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name})")
  end

  # Mechanical Zig template emitter. Entry has everything needed.
  # type_info is only needed for :rc (complex RC/Arc/link cleanup).
  def emit_cleanup_from_entry(name, entry, type_info = nil)
    alloc = alloc_expr_from_plan(entry)
    zig_type = entry[:zig_type] || "UNKNOWN"
    elem_zig = entry[:elem_zig_type] || "UNKNOWN"

    case entry[:kind]
    when :resource
      close_stmt = entry[:resource_close_zig].gsub("{0}", name)
      guarded_defer(name, close_stmt)

    when :list_with_elem_cleanup
      guarded_defer(name, "{ for (#{name}.items) |*__e| { CheatLib.cleanup(#{elem_zig}, rt.cleanupAlloc(), __e); } #{name}.deinit(rt.frameAlloc()); }")

    when :list
      if entry[:has_moved_guard]
        guarded_cleanup(name, zig_type, alloc)
      else
        "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"
      end

    when :string_map, :numeric_map
      guarded_cleanup(name, zig_type, alloc)

    when :pool
      "defer #{name}.deinit(#{alloc});\n"

    when :set
      "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"

    when :rc
      return "" unless type_info
      emit_rc_cleanup(name, type_info)

    when :locked
      guarded_defer(name, "CheatLib.lockedDestroy(#{zig_type}, #{alloc}, #{name})")

    when :write_locked
      guarded_defer(name, "CheatLib.rwLockedDestroy(#{zig_type}, #{alloc}, #{name})")

    when :heap_string, :takes_string
      guarded_defer(name, "rt.heapAlloc().free(#{name})")

    when :heap_slice, :heap_union, :heap_struct
      guarded_cleanup(name, zig_type, "rt.heapAlloc()")

    when :struct_with_cleanup_fields, :struct_rc, :non_copy_union
      guarded_cleanup(name, zig_type, alloc)

    when :heap_struct_plain
      guarded_defer(name, "CheatLib.free(rt, #{name})")

    when :array_with_struct_strings
      if entry[:is_fixed]
        guarded_defer(name, "{ for (&#{name}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{alloc}, __e); } }")
      else
        guarded_defer(name, "{ for (#{name}.items) |*__e| { CheatLib.cleanup(#{elem_zig}, rt.heapAlloc(), __e); } }")
      end

    when :takes_union
      guarded_cleanup(name, zig_type, "rt.heapAlloc()")

    when :takes_slice
      guarded_defer(name, "{ if (comptime CheatLib.needsCleanup(#{elem_zig})) { for (#{name}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{alloc}, __e); } } if (#{name}.len > 0) #{alloc}.free(#{name}); }")

    when :match_as_slice
      guarded_defer(name, "{ if (comptime CheatLib.needsCleanup(#{elem_zig})) { for (#{name}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{alloc}, __e); } } if (#{name}.len > 0) #{alloc}.free(#{name}); }")

    when :match_as_inline_struct
      guarded_cleanup(name, zig_type, alloc)

    else
      ""
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
  # Emit _moved = true when a binding's value is consumed (assigned away).
  # Guard decisions come from moved_guard_info (stamped by MIRPass).
  def emit_move_suppression(rhs_node)
    return "" unless rhs_node.is_a?(AST::Identifier)

    # RC types: only move on explicit GIVE (not on assignment)
    ti = rhs_node.type_info
    if ti && (ti.any_rc? rescue false)
      if @current_rhs_is_move
        fn_name = current_tp_ctx&.fn_name
        return "#{rhs_node.name}_moved = true;" if @moved_guard_info&.dig(fn_name, rhs_node.name)
      end
      return ""
    end

    # Escaped returns transfer ownership to caller - no move suppression
    return "" if ti&.escaped_return && (ti.collection? || ti.string?)

    # Strings are Copy - no move needed
    return "" if ti&.string?

    # Consult moved_guard_info: if the binding has a moved guard, emit it
    fn_name = current_tp_ctx&.fn_name
    return "" unless @moved_guard_info&.dig(fn_name, rhs_node.name)

    # Only emit for was_moved (annotator-marked) or non-Copy types with cleanup
    if rhs_node.was_moved
      sym = rhs_node.respond_to?(:symbol) ? rhs_node.symbol : nil
      decl = sym&.reg
      is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
      is_takes = sym&.respond_to?(:takes) && sym&.takes
      return "#{zig_safe_name(rhs_node.name)}_moved = true;" if is_local || is_takes
    else
      sym = rhs_node.respond_to?(:symbol) ? rhs_node.symbol : nil
      decl = sym&.reg
      is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
      return "#{zig_safe_name(rhs_node.name)}_moved = true;" if is_local
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
      next if ti&.string?
      next if ti&.escaped_return && (ti.collection? || ti&.string?)

      sym = arg.respond_to?(:symbol) ? arg.symbol : nil
      decl = sym&.reg
      next unless decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)

      # Consult moved_guard_info: if the binding has a moved guard, emit it.
      fn_name = current_tp_ctx&.fn_name
      moves << "#{zig_safe_name(name)}_moved = true;" if @moved_guard_info&.dig(fn_name, name)
    end

    moves.join("\n")
  end

  def transpile_rc_retain(type_info, name)
    func = type_info.shared? ? "arcRetain" : "rcRetain"
    "CheatLib.#{func}(#{transpile_type(type_info.resolved.to_s)}, #{name})"
  end
end
