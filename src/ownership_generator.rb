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

  # Convert :heap/:frame symbol to Zig allocator expression.
  def alloc_expr(kind, rt_name = "rt")
    kind == :heap ? "#{rt_name}.heapAlloc()" : "#{rt_name}.frameAlloc()"
  end

  # Guarded defer: wraps body in moved-guard pattern.
  def guarded_defer(name, body)
    "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) #{body};\n"
  end

  # Most common pattern: guarded defer calling CheatLib.cleanup.
  def guarded_cleanup(name, zig_type, alloc)
    guarded_defer(name, "CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name})")
  end

  # Mechanical Zig template emitter. Entry has everything needed - no type
  # derivation, no schema lookups. All fields are pre-computed by build_drop_entry.
  # Kinds that require a resolved zig_type to emit correct cleanup code.
  NEEDS_ZIG_TYPE = Set[:list, :list_with_elem_cleanup, :string_map, :numeric_map, :set,
    :rc, :locked, :write_locked, :heap_slice, :heap_union, :heap_struct,
    :struct_with_cleanup_fields, :struct_rc, :non_copy_union, :takes_union,
    :match_as_inline_struct].freeze

  # Kinds that require a resolved elem_zig_type.
  NEEDS_ELEM_ZIG = Set[:list_with_elem_cleanup, :array_with_struct_strings,
    :takes_slice, :match_as_slice].freeze

  def emit_cleanup_from_entry(name, entry)
    alloc = alloc_expr_from_plan(entry)
    zig_type = entry[:zig_type]
    elem_zig = entry[:elem_zig_type]

    if NEEDS_ZIG_TYPE.include?(entry[:kind]) && (zig_type.nil? || zig_type == "UNKNOWN")
      raise "emit_cleanup_from_entry: :#{entry[:kind]} for '#{name}' has unresolved zig_type=#{zig_type.inspect}. " \
            "compute_drop_type_strings! must populate zig_type before emission."
    end
    if NEEDS_ELEM_ZIG.include?(entry[:kind]) && (elem_zig.nil? || elem_zig == "UNKNOWN")
      raise "emit_cleanup_from_entry: :#{entry[:kind]} for '#{name}' has unresolved elem_zig_type=#{elem_zig.inspect}. " \
            "compute_drop_type_strings! must populate elem_zig_type before emission."
    end

    zig_type ||= "UNKNOWN"
    elem_zig ||= "UNKNOWN"

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
      rc_alloc = entry[:rc_alloc] ? alloc_expr_from_plan(alloc: entry[:rc_alloc]) : alloc
      case entry[:rc_variant]
      when :link
        guarded_defer(name, "CheatLib.#{entry[:rc_release_func]}(#{entry[:base_zig]}, #{name})")
      when :optional
        guarded_defer(name, "{ if (#{name}) |_strong_ref| CheatLib.#{entry[:rc_release_func]}(#{entry[:base_zig]}, #{rc_alloc}, _strong_ref); }")
      else
        result = guarded_cleanup(name, zig_type, rc_alloc)
        if entry[:needs_release_fields]
          result += "defer if (!#{name}_moved) CheatLib.releaseFields(#{entry[:base_zig]}, #{rc_alloc}, #{name}.ctrl.data.*);\n"
        end
        result
      end

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
      raise "emit_cleanup_from_entry: unhandled cleanup kind :#{entry[:kind]} for '#{name}'. " \
            "MIR::Drop was generated but the transpiler has no Zig template for this kind."
    end
  end

  def transpile_rc_retain(type_info, name)
    func = type_info.shared? ? "arcRetain" : "rcRetain"
    "CheatLib.#{func}(#{transpile_type(type_info.resolved.to_s)}, #{name})"
  end
end
