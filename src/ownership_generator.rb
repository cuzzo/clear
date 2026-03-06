module OwnershipGenerator
  # Generates the `_moved` flag and `defer` cleanup block for a variable.
  def emit_cleanup(name, type_info, storage)
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
      # Explicit MOVE for RC, or automatic MOVE for unique heap/arrays/sync
      is_rc = rhs_node.type_info&.any_rc?
      is_sync = rhs_node.type_info&.any_sync?
      should_suppress = (is_rc && @current_rhs_is_move) || 
                        (!is_rc && (rhs_node.type_info&.requires_move? || is_sync) && rhs_node.storage == :heap)
      
      return "#{rhs_node.name}_moved = true;" if should_suppress
    end
    ""
  end

  def transpile_rc_retain(type_info, name)
    func = type_info.shared? ? "arcRetain" : "rcRetain"
    "CheatLib.#{func}(#{transpile_type(type_info.resolved.to_s)}, #{name})"
  end
end
