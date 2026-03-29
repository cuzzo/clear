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

    # @list backing buffer lives in the frame arena — deinit is a no-op but safe.
    # Sharded lists are shared across fibers and must stay heap-backed.
    # Promoted lists (returned from frame-using functions) were copied to heap and
    # must be freed with heapAlloc() to avoid leaking the GPA allocation.
    if type_info&.list_collection?
      return "" if type_info.escaped_return  # ownership transferred to caller via return
      alloc = (type_info.sharded? || type_info.heap_list) ? "rt.heapAlloc()" : "rt.frameAlloc()"
      return "defer #{name}.deinit(#{alloc});\n"
    end
    # @pool backing arrays are heap-allocated; auto-deinit.
    if type_info&.pool?
      return "defer #{name}.deinit(rt.heapAlloc());\n"
    end

    # Sharded/striped maps: each shard/stripe is independently deinited.
    if type_info&.map? && (type_info&.sharded? || type_info&.striped?)
      if type_info.numeric_map?
        return "defer #{name}.deinit(rt.frameAlloc());\n"
      else
        return "defer #{name}.deinit(rt.frameAlloc(), rt.frameAlloc());\n"
      end
    end

    # String map:
    #   Promoted (heap_map): keys + bucket array are on heapAlloc — full mapDeinit.
    #   Frame-scoped (default): keys + bucket array are on frameAlloc — deinit is a
    #   no-op (smartFree is a no-op; frame rewind reclaims all memory automatically).
    if type_info&.map? && !type_info&.numeric_map?
      return "" if type_info.escaped_return  # ownership transferred to caller via return
      if type_info.heap_map
        return "defer #{name}.deinit(rt.heapAlloc(), rt.heapAlloc());\n"
      else
        return "defer #{name}.deinit(rt.frameAlloc(), rt.frameAlloc());\n"
      end
    end
    # Numeric map: no key copies; bucket array in frameAlloc.
    if type_info&.numeric_map?
      key_zig = type_info.key_type.zig_type
      val_zig = type_info.value_type.zig_type
      return "defer CheatLib.numericMapDeinit(#{key_zig}, #{val_zig}, rt.frameAlloc(), &#{name});\n"
    end

    return "" unless type_info&.requires_move? || type_info&.any_rc? || type_info&.any_sync?

    is_rc           = type_info&.any_rc?
    is_shared       = type_info&.shared?
    is_locked       = type_info&.locked?
    is_write_locked = type_info&.write_locked?
    is_any_sync     = is_locked || is_write_locked
    is_heap         = storage == :heap && !is_rc && !is_any_sync

    base_logic = "var #{name}_moved = false; _ = &#{name}_moved;\n"
    
    cleanup_stmt = if is_rc
      base_type = type_info.resolved.to_s
      release_func = is_shared ? "arcRelease" : "rcRelease"
      "CheatLib.#{release_func}(#{transpile_type(base_type)}, rt.heapAlloc(), #{name})"
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

    # Handle recursive field cleanup for RC structs
    if is_rc
      schema = (@struct_schemas ||= {})[type_info.resolved]
      if schema
        schema.each do |fname, fdef|
          field_type = Type.new(fdef[:type])
          if field_type.any_rc?
            inner = field_type.resolved.to_s
            func = field_type.shared? ? "arcRelease" : "rcRelease"
            base_logic += "defer if (!#{name}_moved) CheatLib.#{func}(#{transpile_type(inner)}, rt.heapAlloc(), #{name}.data.#{fname});\n"
          end
        end
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
      is_resource = (ti&.resolved == :File || ti&.resolved == :TCPServer || ti&.resolved == :TCPClient)

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
