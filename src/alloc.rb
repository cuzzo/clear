# alloc.rb — Frame arena helpers for CLEAR.
#
# Provides storage-tier finalization and resource-close resolution.
# Loop frame analysis (mark_per_iter, container heap promotion) lives in
# LoopFrameAnalysis (control_flow.rb), which runs in Pass 2 after
# CleanupClassifier has finalized every binding's allocator.
module AllocHelper
  # Downgrade :frame to :stack for struct literals inside loop bodies.
  # The OS stack reclaims them each iteration; LLVM can SROA the fields.
  def downgrade_frame_to_stack(node, storage)
    return storage unless storage == :frame && (current_fn_ctx&.loop_depth || @loop_depth) > 0
    return storage unless node.value.is_a?(AST::StructLit)

    node.type_info.location = :stack
    node.storage            = :stack
    node.value.storage      = :stack
    :stack
  end

  # Finalize storage tier (stack/frame/heap) and record allocation effects.
  def finalize_decl_storage!(node, final_type)
    storage = node.finalize_storage!(final_type) { |n| lookup_type_schema(n) }
    storage = downgrade_frame_to_stack(node, storage)
    current_fn_ctx.frame_count += 1 if current_fn_ctx && storage == :frame
    if storage == :heap
      current_fn_ctx.heap_count += 1 if current_fn_ctx
      record_effect(EffectTracker::HEAP)
    end
    storage
  end

  # Resolve resource cleanup for pools, streams, resources, and structs with resource fields.
  # Returns [is_resource, resource_close_zig].
  # Delegates to Type#resolve_resource_close for type-specific logic.
  def resolve_resource_close(node, final_type)
    ft_obj = node.type_info
    return [false, nil] unless ft_obj
    ti = ft_obj.is_a?(Type) ? ft_obj : Type.new(ft_obj)
    ti.resolve_resource_close(->(name) { lookup_type_schema(name) })
  end

end
