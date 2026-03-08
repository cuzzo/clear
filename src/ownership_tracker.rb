require_relative "./ast"

module OwnershipTracker
  # If the RHS is an Identifier or GetField, and it's an Affine or Linear Type,
  # We must MOVE it.
  def handle_assign_move(node)
    # Case 1: Moving a sub-field (e.g., VAR x = foo.child)
    if node.value.is_a?(AST::GetField) || node.value.is_a?(AST::GetIndex)
      path = get_path_to_root(node.value)
      return if path.nil?

      rhs_type = node.value.resolved_type
      if Type.new(rhs_type).requires_move?
        # Find the scope that owns this variable
        root_name = path.first.to_s
        scope = lookup_scope_for(root_name)
        scope&.mark_path_moved(path) if scope
      end
      return
    end

    # Case 2: Moving a whole variable (e.g., VAR x = foo)
    return if !node.value.is_a?(AST::Identifier)

    rhs_name = node.value.name
    rhs_type = current_scope.resolve_type(rhs_name)
    rhs_info = current_scope.locals[rhs_name]

    # Multiowned (Rc), Shared (Arc), and Sync (locked) vars manage their own lifecycle
    rhs_storage = rhs_info&.dig(:storage)
    rhs_sync    = rhs_info&.dig(:sync)
    return if rhs_storage == :multiowned || rhs_storage == :shared || rhs_sync

    # Primitives COPY, everything else MOVES (including resources)
    if Type.new(rhs_type).requires_move? || rhs_info&.dig(:resource)
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

  # Handles ownership tracking when a value escapes via return.
  # If the returned value is a variable that requires a move, marks it as escaped.
  # Returns true if the variable was promoted from frame to heap, false otherwise.
  #
  # @param value_node [AST::Node] The value being returned
  # @param expected_type [Type, Symbol, nil] The declared return type of the function
  # @return [Boolean] Whether a frame-to-heap promotion occurred
  #
  def handle_return_escape(value_node, expected_type = nil)
    return false if value_node.nil?

    # Only promote if the function EXPECTS a heap return (or dynamic type like array)
    if expected_type
      expected = Type.new(expected_type)
      return false unless expected.heap? || expected.dynamic?
    end

    root = get_root_object(value_node)
    return false unless root.is_a?(AST::Identifier)

    var_name = root.name
    owner_scope = lookup_scope_for(var_name)
    return false unless owner_scope

    # Multiowned (Rc), Shared (Arc), and Sync (locked) values manage their own lifetime
    storage  = owner_scope.locals[var_name]&.dig(:storage)
    var_sync = owner_scope.locals[var_name]&.dig(:sync)
    return false if storage == :multiowned || storage == :shared || var_sync

    type = owner_scope.resolve_type(var_name)
    return false unless Type.new(type).requires_move?

    # Mark as escaped and return whether it was promoted from frame
    is_frame_dec = owner_scope.mark_escaped(var_name)
    if owner_scope.is_on_heap?(var_name) && root.respond_to?(:storage=)
      root.storage = :heap
    end
    is_frame_dec
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

  def check_tense_linear!(node, name, info)
    if Type.new(info[:type]).tense?
      error!(node, "Promise '#{name}' must be consumed before it goes out of scope. Use NEXT, COLLECT, or RETURN it.")
    end
  end

  def finalize_scope(node, branch: nil)
    drops = []

    # Look at all variables in the current scope
    current_scope.locals.each do |name, info|

      next unless current_scope.get_state(name) == :live
      next if info[:storage] == :multiowned || info[:storage] == :shared || info[:sync]

      if info[:resource]
        # Resources auto-close via Zig `defer` emitted at declaration time.
        # Mark as dropped here so the ownership tracker knows the resource is spent.
        drops << { name: name, type: info[:type], resource: true }
        current_scope.set_state(name, :dropped)

      elsif Type.new(info[:type]).requires_move?
        # Tense (Promise) variables are linear — they cannot be silently dropped.
        # The programmer must NEXT, COLLECT, RETURN, or GIVE them before scope ends.
        check_tense_linear!(node, name, info)

        # AUTOMATICALLY INSERT DROP
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

  def collect_scope_drops(node: nil)
    drops = []
    current_scope.locals.each do |name, info|
      next unless current_scope.get_state(name) == :live
      next if info[:storage] == :multiowned || info[:storage] == :shared || info[:sync]

      if info[:resource]
        drops << { name: name, type: info[:type], resource: true }
        current_scope.set_state(name, :dropped)
      elsif Type.new(info[:type]).requires_move?
        check_tense_linear!(node, name, info) if node
        drops << { name: name, type: info[:type] }
        current_scope.set_state(name, :dropped)
      end
    end
    drops
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
