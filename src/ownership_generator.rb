module OwnershipGenerator
  # Generates the `_moved` flag and `defer` cleanup block for a variable.
  def emit_cleanup(name, node)
    type_info = node.type_info
    storage = node.storage
    resource_close = node.resource_close_zig
    # Resources use a simple `defer close()` — use moved-flag to prevent double-close.
    if resource_close
      close_stmt = resource_close.gsub("{0}", name)
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) #{close_stmt};\n"
    end

    # Skip cleanup if ownership transferred via return (collections + strings)
    return "" if type_info&.escaped_return && (type_info.collection? || type_info.string?)

    # Heap-promoted strings from callee returns: free with heapAlloc.
    # Uses moved-flag guard so GIVE can suppress the defer.
    if type_info&.string? && type_info.heap_promoted
      return "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) rt.heapAlloc().free(#{name});\n"
    end

    # @list backing buffer lives in the frame arena — deinit is a no-op but safe.
    # Sharded lists are shared across fibers and must stay heap-backed.
    # Promoted lists (returned from frame-using functions) were copied to heap and
    # must be freed with heapAlloc() to avoid leaking the GPA allocation.
    if type_info&.list_collection?
      alloc = (type_info.sharded? || type_info.heap_promoted) ? "rt.heapAlloc()" : "rt.frameAlloc()"
      if type_info.elem_ownership
        # List with ref-counted elements: comptime deinitList releases each element.
        elem_zig = type_info.element_type.zig_type
        return "defer CheatLib.deinitList(#{elem_zig}, #{alloc}, rt.heapAlloc(), &#{name});\n"
      end
      return "defer #{name}.deinit(#{alloc});\n"
    end
    # @pool backing arrays are heap-allocated; auto-deinit.
    if type_info&.pool?
      return "defer #{name}.deinit(rt.heapAlloc());\n"
    end
    # @set: comptime deinitSet releases RC elements then frees backing hashmap.
    if type_info&.set_collection?
      elem_zig = type_info.element_type&.zig_type || "[]const u8"
      return "defer CheatLib.deinitSet(#{elem_zig}, rt.heapAlloc(), &#{name});\n"
    end

    # Sharded/striped maps: shared across fibers, use heapAlloc for keys and buckets.
    # Arc-wrapped striped maps use arcRelease instead of direct deinit.
    if type_info&.map? && (type_info&.sharded? || type_info&.striped?)
      if type_info.shared?
        bare = Type.new(type_info.resolved.to_s)
        bare.shard_count = type_info.shard_count
        bare.sync = type_info.sync if type_info.sync
        return "defer CheatLib.arcRelease(#{bare.zig_type}, rt.heapAlloc(), #{name});\n"
      end
      if type_info.numeric_map?
        return "defer #{name}.deinit(rt.heapAlloc());\n"
      else
        return "defer #{name}.deinit(rt.heapAlloc(), rt.heapAlloc());\n"
      end
    end

    # String map: always use heapAlloc for deinit — matches put allocator.
    # Keys are duped via heapAlloc in put(); deinit must free with same allocator.
    # For frame-local maps, heapAlloc.free on frame pointers is a no-op (safe).
    # Arc-wrapped maps use arcRelease instead of direct deinit.
    if type_info&.map? && !type_info&.numeric_map?
      if type_info.shared?
        inner_zig = type_info.sync == :write_locked ? "CheatLib.RwLocked(#{Type.new(type_info.resolved.to_s).zig_type})" :
                    type_info.sync == :locked ? "CheatLib.Locked(#{Type.new(type_info.resolved.to_s).zig_type})" :
                    Type.new(type_info.resolved.to_s).zig_type
        return "defer CheatLib.arcRelease(#{inner_zig}, rt.heapAlloc(), #{name});\n"
      end
      return "defer #{name}.deinit(rt.heapAlloc(), rt.heapAlloc());\n"
    end
    # Numeric map: no key copies; bucket array in frameAlloc.
    if type_info&.numeric_map?
      key_zig = type_info.key_type.zig_type
      val_zig = type_info.value_type.zig_type
      return "defer CheatLib.numericMapDeinit(#{key_zig}, #{val_zig}, rt.frameAlloc(), &#{name});\n"
    end

    # Struct containing promoted fields from function returns:
    # emit field-level cleanup so heap-promoted data is freed by caller.
    # Uses moved-flag guard so GIVE can suppress the defer.
    if type_info&.heap_promoted && !type_info&.collection?
      resolved = type_info&.resolved
      schema = (@struct_schemas ||= {})[resolved]
      if schema
        cleanups = schema.filter_map do |fname, fdef|
          ftype = fdef.is_a?(Hash) ? fdef[:type] : fdef
          ft = ftype.is_a?(Type) ? ftype : Type.new(ftype || :Any)
          ft.escape_cleanup_code("#{name}.#{fname}")
        end
        unless cleanups.empty?
          moved_guard = "var #{name}_moved = false; _ = &#{name}_moved;\n"
          defers = cleanups.map { |c| c.sub("defer ", "defer if (!#{name}_moved) ") }.join
          return moved_guard + defers
        end
      end
    end

    # Structs containing RC/link fields: emit comptime releaseFields.
    # The scan detects whether to emit; releaseFields handles the actual
    # field-by-field cleanup at Zig comptime (zero-cost for non-RC structs).
    if !type_info&.any_rc? && !type_info&.link? && !type_info&.any_sync?
      resolved = type_info&.resolved
      schema = (@struct_schemas ||= {})[resolved]
      if schema && schema.any? { |k, v| !k.is_a?(Symbol) && (ft = v.is_a?(Hash) ? v[:type] : v; t = ft.is_a?(Type) ? ft : Type.new(ft || :Any); t.link? || t.any_rc?) }
        zig_type = transpile_type(resolved.to_s)
        moved_guard = "var #{name}_moved = false; _ = &#{name}_moved;\n"
        moved_guard += "defer if (!#{name}_moved) CheatLib.releaseFields(#{zig_type}, rt.heapAlloc(), #{name});\n"
        return moved_guard
      end
    end

    return "" unless type_info&.requires_move? || type_info&.any_rc? || type_info&.any_sync? || type_info&.link?

    is_link         = type_info&.link?
    is_rc           = type_info&.any_rc?
    is_shared       = type_info&.shared?
    is_locked       = type_info&.locked?
    is_write_locked = type_info&.write_locked?
    is_any_sync     = is_locked || is_write_locked
    is_heap         = storage == :heap && !is_rc && !is_any_sync && !is_link

    base_logic = "var #{name}_moved = false; _ = &#{name}_moved;\n"

    cleanup_stmt = if is_link
      base_type = type_info.resolved.to_s
      source = type_info.link_source || :multiowned
      release_func = source == :shared ? "weakArcRelease" : "weakRcRelease"
      "CheatLib.#{release_func}(#{transpile_type(base_type)}, #{name})"
    elsif is_rc
      base_type = type_info.resolved.to_s
      is_optional_rc = type_info.optional?
      base_type = base_type.sub(/^\?/, '') if is_optional_rc
      release_func = is_shared ? "arcRelease" : "rcRelease"
      if is_optional_rc
        "{ if (#{name}) |_strong_ref| CheatLib.#{release_func}(#{transpile_type(base_type)}, rt.heapAlloc(), _strong_ref); }"
      else
        "CheatLib.#{release_func}(#{transpile_type(base_type)}, rt.heapAlloc(), #{name})"
      end
    elsif is_locked
      zig_inner_t = transpile_type(type_info.resolved.to_s)
      "CheatLib.lockedDestroy(#{zig_inner_t}, rt.heapAlloc(), #{name})"
    elsif is_write_locked
      zig_inner_t = transpile_type(type_info.resolved.to_s)
      "CheatLib.rwLockedDestroy(#{zig_inner_t}, rt.heapAlloc(), #{name})"
    elsif is_heap
      "CheatLib.free(rt, #{name})"
    else
      return "" # Stack type with no custom drop
    end

    base_logic += "defer if (!#{name}_moved) #{cleanup_stmt};\n"

    # RC structs: unconditionally emit releaseFields on the inner data.
    # Comptime eliminates it for structs without RC/link fields.
    if is_rc
      schema = (@struct_schemas ||= {})[type_info.resolved]
      if schema
        zig_type = transpile_type(type_info.resolved.to_s)
        base_logic += "defer if (!#{name}_moved) CheatLib.releaseFields(#{zig_type}, rt.heapAlloc(), #{name}.ctrl.data.*);\n"
      end
    end

    base_logic
  end

  # Marks the source identifier as moved if it requires affine transfer.
  def emit_move_suppression(rhs_node)
    if rhs_node.is_a?(AST::Identifier)
      # Explicit MOVE for RC, or automatic MOVE for unique heap/arrays/sync/resources
      is_rc = rhs_node.type_info&.any_rc?
      is_sync = rhs_node.type_info&.any_sync?
      
      # Determine if the RHS is a resource based on its declaration node
      # If we don't have decl_node, it might be a method call result or something;
      # resources are always affine and should be moved.
      ti = rhs_node.type_info
      is_resource = ti&.resource?

      should_suppress = (is_rc && @current_rhs_is_move) || 
                        (!is_rc && (rhs_node.type_info&.requires_move? || is_sync || is_resource) && 
                         (rhs_node.storage == :heap || is_resource))
      
      return "#{rhs_node.name}_moved = true;" if should_suppress
    end
    ""
  end

  def transpile_rc_retain(type_info, name)
    func = type_info.shared? ? "arcRetain" : "rcRetain"
    "CheatLib.#{func}(#{transpile_type(type_info.resolved.to_s)}, #{name})"
  end
end
