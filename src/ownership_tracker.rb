require_relative "./ast"

module OwnershipTracker
  # If the RHS is an Identifier, and it's an Affine or Linear Type,
  # We must MOVE it.
  def handle_assign_move(node)
    # 1. Handle the Source (RHS)
    return if !node.value.is_a?(AST::Identifier)

    rhs_name = node.value.name
    rhs_type = current_scope.resolve_type(rhs_name)

    # Primitives COPY, everything else MOVES
    if Type.new(rhs_type).requires_move?
      current_scope.set_state(rhs_name, :moved)
    end
  end

  # Only applies if we are assigning a Variable (RHS) to something (LHS)
  def handle_assign_escape(node)
    return if !node.value.is_a?(AST::Identifier)

    rhs_name = node.value.name
    rhs_scope = lookup_scope_for(rhs_name)

    # Check LHS: Where are we putting this?
    target_is_heap = false

    if node.name.is_a?(AST::Identifier)
      # Case 1: Assigning to a Variable
      # lhs = rhs
      lhs_name = node.name.name
      lhs_scope = lookup_scope_for(lhs_name)

      # If LHS is Global or explicitly Heap, RHS escapes
      if lhs_scope && (lhs_scope.is_on_heap?(lhs_name) || is_global_scope?(lhs_scope))
        target_is_heap = true
      end

    elsif node.name.is_a?(AST::GetField) || node.name.is_a?(AST::GetIndex)
      # Walk up to find the root owner (e.g. 'x' in 'x.y.z = rhs')
      root = get_root_object(node.name)

      # Look up the scope directly since AST types aren't resolved yet
      if root.is_a?(AST::Identifier)
        root_name = root.name
        root_scope = lookup_scope_for(root_name)

        if root_scope
          # Check 1: Is it Global? OR Check 2: Is it on the Heap?
          if is_global_scope?(root_scope) || root_scope.is_on_heap?(root_name)
            target_is_heap = true
          end
        end
      end
    end

    # PROMOTE IF NEEDED
    if target_is_heap && rhs_scope
      rhs_type = rhs_scope.resolve_type(rhs_name)

      # Optimization: Only promote if it requires a move (i.e. not a primitive Number)
      if Type.new(rhs_type).requires_move?
        rhs_scope.mark_escaped(rhs_name)
      end
    end
  end

  def finalize_scope(node, branch: nil)
    drops = []

    # Look at all variables in the current scope
    current_scope.locals.each do |name, info|

      # We only care about variables that are:
      # 1. LIVE (Not moved yet)
      # 2. Linear (Have a destructor/need freeing)
      if current_scope.get_state(name) == :live && Type.new(info[:type]).requires_move?

        # AUTOMATICALLY INSERT DROP
        # In a transpiler, you might attach this metadata to the AST node
        # so the code generator knows to emit "free(x)" here.
        drops << { name: name, type: info[:type] }

        # Mark as consumed so we don't double-free
        current_scope.set_state(name, :dropped)
      end
    end

    if branch == :then
      node.then_drops = drops
    elsif branch == :else
      node.else_drops = drops
    else
      node.deferred_drops = drops
    end
  end
end
