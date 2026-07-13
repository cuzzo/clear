# typed: strict
# alloc.rb — Frame arena helpers for CLEAR.
#
# Provides storage-tier finalization and resource-close resolution.
# Loop frame analysis (mark_per_iter, container heap promotion) lives in
# LoopFrameAnalysis (control_flow.rb), which runs in Pass 2 after
# CleanupClassifier has finalized every binding's allocator.
require "sorbet-runtime"

module AllocHelper
  extend T::Sig

  AllocDeclarationNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr) }

  # Downgrade :frame to :stack for struct literals inside loop bodies.
  # The OS stack reclaims them each iteration; LLVM can SROA the fields.
  sig { params(node: AllocDeclarationNode, storage: Symbol).returns(Symbol) }
  def downgrade_frame_to_stack(node, storage)
    T.bind(self, SemanticAnnotator)
    return storage unless storage == :frame && current_loop_depth.positive?
    return storage unless node.value.is_a?(AST::StructLit)

    node.full_type!.mark_stack_value!
    node.storage = :stack
    node.value.storage = :stack
    :stack
  end

  # Finalize storage tier (stack/frame/heap) and record allocation effects.
  sig { params(node: AllocDeclarationNode, final_type: T.any(Symbol, Type)).returns(Symbol) }
  def finalize_decl_storage!(node, final_type)
    T.bind(self, SemanticAnnotator)
    storage = node.finalize_storage!(final_type) { |n| lookup_type_schema(n.to_sym) }
    storage = downgrade_frame_to_stack(node, storage)
    current_fn_ctx&.record_frame_use! if storage == :frame
    if storage == :heap
      current_fn_ctx&.record_heap_use!
      record_effect(EffectTracker::HEAP)
    end
    storage
  end

  # Resolve resource cleanup for pools, streams, resources, and structs with resource fields.
  # Returns a named resource/close-plan result.
  # Delegates to Type#resolve_resource_close for type-specific logic.
  sig { params(node: AST::Node).returns(Type::ResourceCloseResult) }
  def resolve_resource_close(node)
    T.bind(self, SemanticAnnotator)
    ti = node.full_type!
    ti.resolve_resource_close(->(name) { lookup_type_schema(name) })
  end
  private :downgrade_frame_to_stack

end
