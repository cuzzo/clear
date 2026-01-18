require_relative "./ast"

module OwnershipTracker
  # If the RHS is an Identifier, and it's an Affine or Linear Type,
  # We must MOVE it.
  def handle_assign_move(node)
    # TODO: Allow swap for pointers and optionals.
    if node.value.is_a?(AST::GetField)
      error!(node, "NOT YET SUPPORTED: Cannot move field '#{node.value.field}' directly. Use 'swap' to replace it, or 'copy' (future) to clone it.")
    end

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

  # TODO: Only works for simple borrows
  def handle_assign_borrow(node)
    return if !node.value.is_a?(AST::FuncCall) && !node.value.is_a?(AST::MethodCall)

    call_node = node.value

    func_name = call_node.is_a?(AST::MethodCall) ? call_node.name : call_node.name
    scope = lookup_scope_for(func_name)
    if scope.nil?
      error!(node, "Method not found")
    end

    func_type = scope.resolve_type(func_name)
    return unless func_type.is_a?(Hash)
    # TODO: intrinsics should have a real function signature
    # error!(node, "Missing Function Signature") if !func_type.is_a?(Hash)

    # Most functions don't have a lifetime -> this is expected
    lifetime = func_type.dig(:return, :lifetime)
    return if lifetime.nil?

    param_index = func_type[:params].find_index { |p| p[:name] == lifetime }
    error!(node, "Missing lifetime") if param_index.nil?

    args = if call_node.is_a?(AST::MethodCall)
      [call_node.object] + call_node.args  # UFCS: object is first arg
    else
      call_node.args
    end

    actual_arg = args[param_index]
    error!(node, "Missing borrowed param") if actual_arg.nil?

    path = get_path_to_root(actual_arg)
    # e.g. borrow(Node{v: 1, child: Node { v: 2} }) -> this is fine
    return if path.nil?

    root_var = path.first.to_s
    borrowed_scope = lookup_scope_for(root_var)
    error!(node, "Variable not found") if borrowed_scope.nil?

    # 3. Check Mutability
    # (If the root is immutable, we don't care about borrows usually, unless you want Read-Write locks)
    return if borrowed_scope.is_immutable?(root_var)

    # 4. Check Path Conflicts
    borrow_type = node.mutable ? :mutable : :immutable
    if !borrowed_scope.can_borrow?(root_var, path, borrow_type)
      error!(node, "Lifetime Error: '#{root_var}' (or part of it) is already borrowed.")
    end

    current_scope.mark_borrowed(root_var, path, borrow_type)
  end

  def verify_unrestricted!(node)
    # 1. Calculate the path being written to (e.g. foo.b)
    target_node = node.name # Identifier, GetField, or GetIndex
    path = get_path_to_root(target_node)

    return if path.nil?

    root_name = path.first.to_s
    scope = lookup_scope_for(root_name)
    return if scope.nil?

    # Writing requires EXCLUSIVE (Mutable) access.
    if !scope.can_borrow?(root_name, path, :mutable)
      error!(node, "Lifetime Error: Cannot assign to '#{root_name}' because it is currently borrowed.")
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

  def get_path_to_root(node)
    path = []
    curr = node
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      if curr.is_a?(AST::GetField)
        path.unshift(curr.field.to_sym)
      elsif curr.is_a?(AST::GetIndex)
        # For arrays, we might just track the whole array, or use a wildcard :*
        # For now, let's treat index access as "modifying the container"
        path.unshift(:*)
      end
      curr = curr.target
    end

    return nil unless curr.is_a?(AST::Identifier)
    path.unshift(curr.name.to_sym) # The root variable is first
    path
  end

  # TODO: Save lifetime path as a path, not a string.
  def get_lifetime_path(func_node)
    get_path_to_root(func_node.return_lifetime)&.join(".")
  end
end
