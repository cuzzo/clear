# alloc.rb — Frame arena allocation analysis for CLEAR.
#
# Provides helpers to determine whether loop bodies allocate from
# the frame arena and whether those allocations escape the iteration
# (stored in outer-scope variables). Used by visit_WhileLoop to decide
# whether per-iteration mark/rewind is safe.
#
# Also provides downgrade_frame_to_stack for loop-local SROA.
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
  def resolve_resource_close(node, final_type)
    ft_obj = node.type_info
    is_pool        = ft_obj&.pool?
    is_open_stream = ft_obj&.open_stream?
    is_inf_stream  = ft_obj&.inf_stream?

    is_set = ft_obj&.set_collection?

    if is_pool
      return [true, "{0}.deinit(rt.heapAlloc())"]
    elsif is_set
      return [true, "{0}.deinit(rt.heapAlloc())"]
    elsif is_open_stream || is_inf_stream
      return [true, "{0}.deinit()"]
    end

    resource_schema = lookup_type_schema(final_type)
    is_resource     = resource_schema&.dig(:kind) == :resource
    resource_close  = is_resource ? resource_schema[:close_zig] : nil

    # Recursive check: if it's a user struct, check if any fields are resources.
    if !is_resource && resource_schema.is_a?(Hash) && resource_schema[:kind].nil?
      closes = []
      resource_schema.each do |fname, ftype|
        next if fname == :type_params || fname == :methods
        f_resolved = Type.new(ftype).resolved
        f_schema = lookup_type_schema(f_resolved)
        if f_schema&.dig(:kind) == :resource
          closes << f_schema[:close_zig].gsub("{0}", "{0}.#{fname}")
        end
      end
      if closes.any?
        is_resource = true
        resource_close = closes.join("; ")
      end
    end

    [is_resource, resource_close]
  end

  # Returns true if any statement in stmts allocates from the frame arena.
  def loop_allocates_frame?(stmts)
    return false if stmts.nil?
    stmts = [stmts] unless stmts.is_a?(Array)
    stmts.any? { |s| node_allocates_frame?(s) }
  end

  def node_allocates_frame?(node)
    return false if node.nil?
    case node
    when AST::VarDecl, AST::BindExpr
      return true if node.storage == :frame
      node_allocates_frame?(node.value)
    when AST::FuncCall
      return true if node.respond_to?(:stdlib_allocates) && node.stdlib_allocates
      return false if node.respond_to?(:extern_call) && node.extern_call
      fn = @fn_nodes&.[](node.name)
      return true if fn && fn.respond_to?(:uses_frame) && fn.uses_frame
      node.args&.any? { |a| node_allocates_frame?(a) } || false
    when AST::MethodCall
      return false if node.respond_to?(:pool_method) && node.pool_method
      return false if node.respond_to?(:set_method) && node.set_method
      return true if node.respond_to?(:stdlib_allocates) && node.stdlib_allocates
      fn = @fn_nodes&.[](node.name)
      return true if fn && fn.respond_to?(:uses_frame) && fn.uses_frame
      ([node.object] + (node.args || [])).any? { |a| node_allocates_frame?(a) }
    when AST::BinaryOp
      # String concat (+) allocates from the frame arena (transpiles to CheatLib.concat).
      if node.op == :ADD
        lt = node.left.type_info rescue nil
        rt = node.right.type_info rescue nil
        return true if (lt.is_a?(Type) ? lt.string? : lt == :String) || (rt.is_a?(Type) ? rt.string? : rt == :String)
      end
      node_allocates_frame?(node.left) || node_allocates_frame?(node.right)
    when AST::UnaryOp
      node_allocates_frame?(node.right)
    when AST::IfStatement
      loop_allocates_frame?(node.then_branch) || loop_allocates_frame?(node.else_branch)
    when AST::WhileLoop
      loop_allocates_frame?(node.do_branch)
    when AST::ForRange, AST::ForEach
      loop_allocates_frame?(node.body)
    when AST::MatchStatement
      node.cases.any? { |c| loop_allocates_frame?(c[:body]) } ||
        loop_allocates_frame?(node.default_case)
    when AST::GetIndex
      node_allocates_frame?(node.index)
    when AST::ReturnNode
      node_allocates_frame?(node.value)
    when AST::Assignment
      node_allocates_frame?(node.value)
    else
      false
    end
  end

  # Collects AST nodes whose frame allocations escape the loop iteration
  # into outer-scope variables. These nodes need heap promotion so loop
  # marks can safely rewind without corrupting live data.
  def collect_loop_escapes(stmts, outer_vars, preserve_vars: nil)
    return [] if stmts.nil?
    stmts = [stmts] unless stmts.is_a?(Array)
    escapes = []
    stmts.each { |s| collect_node_escapes(s, outer_vars, escapes, preserve_vars: preserve_vars) }
    escapes
  end

  def collect_node_escapes(node, outer_vars, escapes, preserve_vars: nil)
    return if node.nil?
    case node
    when AST::FuncCall
      if node.args&.first.is_a?(AST::Identifier) && outer_vars.include?(node.args.first.name)
        if node.respond_to?(:mutates_receiver) && node.mutates_receiver
          # append(outer_list, value) — the value arg escapes into the container.
          # Promote the value arg (index 1) and the container's backing (index 0).
          escapes << { node: node, container: node.args.first.name, kind: :mutates_receiver }
          return
        end
        if (node.respond_to?(:stdlib_allocates) && node.stdlib_allocates) ||
           (@fn_nodes&.[](node.name)&.respond_to?(:uses_frame) && @fn_nodes[node.name].uses_frame)
          escapes << { node: node, container: node.args.first.name, kind: :call_escapes }
          return
        end
      end
    when AST::MethodCall
      if node.respond_to?(:object) && node.object.is_a?(AST::Identifier) && outer_vars.include?(node.object.name)
        if node.respond_to?(:mutates_receiver) && node.mutates_receiver
          escapes << { node: node, container: node.object.name, kind: :mutates_receiver }
          return
        end
        if (node.respond_to?(:stdlib_allocates) && node.stdlib_allocates) ||
           (@fn_nodes&.[](node.name)&.respond_to?(:uses_frame) && @fn_nodes[node.name].uses_frame)
          escapes << { node: node, container: node.object.name, kind: :call_escapes }
          return
        end
      end
    when AST::Assignment
      target_name = case node.name
                    when AST::Identifier then node.name.name
                    when AST::GetField then node.name.target.is_a?(AST::Identifier) ? node.name.target.name : nil
                    when AST::GetIndex then node.name.target.is_a?(AST::Identifier) ? node.name.target.name : nil
                    when String then node.name
                    end
      if target_name && outer_vars.include?(target_name)
        if node.name.is_a?(AST::GetIndex) || node_allocates_frame?(node.value)
          escapes << { node: node, container: target_name, kind: :assignment }
          return
        end
      end
    when AST::BindExpr
      if node.name.is_a?(String) && outer_vars.include?(node.name) && node_allocates_frame?(node.value)
        # MUTABLE string reassignment is handled by loopPreserveAndRewind
        # (keeps data on frame, preserves across rewind). NOT heap-promoted
        # because heap promotion would leak old values.
        if node.mode == :assign && preserve_vars
          ti = node.type_info
          ti = Type.new(ti) if ti && !ti.is_a?(Type)
          if ti&.string?
            preserve_vars << node.name
            return
          end
        end
        escapes << { node: node, container: node.name, kind: :reassignment }
        return
      end
    when AST::WhileLoop
      collect_loop_escapes(node.do_branch, outer_vars, preserve_vars: preserve_vars).each { |e| escapes << e }
    when AST::ForRange
      collect_loop_escapes(node.body, outer_vars, preserve_vars: preserve_vars).each { |e| escapes << e }
    when AST::IfStatement
      collect_loop_escapes(node.then_branch, outer_vars, preserve_vars: preserve_vars).each { |e| escapes << e }
      collect_loop_escapes(node.else_branch, outer_vars, preserve_vars: preserve_vars).each { |e| escapes << e }
    when AST::MatchStatement
      node.cases.each { |c| collect_loop_escapes(c[:body], outer_vars, preserve_vars: preserve_vars).each { |e| escapes << e } }
      collect_loop_escapes(node.default_case, outer_vars, preserve_vars: preserve_vars).each { |e| escapes << e }
    end
  end

  # Promote frame-escaping loop data to heap. For each escape action,
  # set the container and escaping expression storage to :heap.
  # This ensures {alloc} resolves to heapAlloc() in the transpiler
  # for both the container backing and the escaping values.
  def promote_loop_escapes!(escape_actions)
    return if escape_actions.empty?

    escape_actions.each do |action|
      call_node = action[:node]
      case action[:kind]
      when :mutates_receiver
        # keys.append(value) or append(keys, value)
        # Promote the container's AST node so {alloc} for backing uses heapAlloc.
        if call_node.is_a?(AST::MethodCall)
          promote_expr_to_heap!(call_node.object)
          promote_expr_to_heap!(call_node.args[0])
        elsif call_node.is_a?(AST::FuncCall)
          promote_expr_to_heap!(call_node.args[0])
          promote_expr_to_heap!(call_node.args[1])
        end
      when :call_escapes
        # stdlib_allocates or uses_frame call on outer container
        if call_node.is_a?(AST::MethodCall)
          promote_expr_to_heap!(call_node.object)
        elsif call_node.is_a?(AST::FuncCall)
          promote_expr_to_heap!(call_node.args&.first)
        end
      when :assignment
        # outer_map[key] = value or outer.field = value
        promote_expr_to_heap!(call_node.value) if call_node.respond_to?(:value)
        if call_node.name.is_a?(AST::GetIndex) && call_node.name.index
          promote_expr_to_heap!(call_node.name.index)
        end
      when :reassignment
        # MUTABLE string reassignment: handled by loopPreserveAndRewind, NOT heap-promoted.
        # Heap promotion would leak old values each iteration (loop mark doesn't free heap).
        nil
      end
    end
  end

  # Set an expression node's storage to :heap so {alloc} resolves to heapAlloc().
  # Only promotes types where storage controls the ALLOCATOR (strings, collections),
  # NOT types where storage changes the Zig TYPE (structs, unions -> *T pointer).
  #
  # Special case: when node is a FuncCall/MethodCall returning a frame string
  # (return_provenance != :heap), setting storage alone has no effect because
  # the call doesn't use {alloc}. Instead mark heap_dupe_result = true so the
  # transpiler wraps the call in rt.heapAlloc().dupe(u8, result).
  #
  # For StructLit: the struct itself is a value type (copied into the container),
  # but String/collection FIELDS inside it are pointers to the frame arena.
  # When the struct escapes a loop iteration, those field pointers are invalidated
  # by the loop mark rewind. Recurse into fields and promote them.
  def promote_expr_to_heap!(node)
    return unless node
    # StructLit: value type, don't change struct's own storage.
    # Recurse into String/collection fields so pointer fields survive loop rewind.
    if node.is_a?(AST::StructLit)
      node.fields.each_value { |v| promote_expr_to_heap!(v) }
      return
    end
    return unless node.respond_to?(:storage=)
    ti = node.type_info rescue nil
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    # Strings: storage controls which allocator std.mem.concat / dupe uses.
    # Collections (@list, @pool, HashMap): storage controls backing allocator.
    # Value types (Int64, Bool, enums, plain unions/structs): copied by value
    # into the container - no allocator involved, don't change storage.
    if ti&.string? || ti&.list_collection? || ti&.map?
      # node.storage = :heap uses @storage_override (node-local) so it does NOT
      # mutate the shared Type object (e.g. STRING_TYPE, or function return types).
      node.storage = :heap
      # For Identifier containers: update the DECLARATION node's type_info so
      # CleanupClassifier.classify_binding sees heap_provenance? = true and emits heapAlloc().
      # FuncCall/MethodCall type_infos are shared (function return type), so we skip
      # them — mutating shared Types would corrupt function signatures.
      if node.is_a?(AST::Identifier)
        scope = lookup_scope_for(node.name) rescue nil
        decl_node = scope&.locals&.dig(node.name)&.reg
        decl_ti = decl_node&.type_info rescue nil
        if decl_ti.is_a?(Type)
          decl_ti.provenance = :heap
          decl_ti.cleanup_alloc = :heap
        end
      end
      # If the node is a call expression returning a frame string, the return
      # value is in the caller's frame and will be destroyed by the next loop
      # mark rewind. Heap-dupe the result at the call site instead.
      if (node.is_a?(AST::FuncCall) || node.is_a?(AST::MethodCall)) && ti&.string?
        callee_fn = @fn_nodes&.[](node.name)
        if callee_fn && callee_fn.return_provenance != :heap
          node.heap_dupe_result = true
        end
      end
    end
  end
end
