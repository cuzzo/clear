require_relative "../src/ast"

module FunctionAnalysis
  # Converts an intrinsic definition from STD_LIB format to the standard
  # function signature format used by verify_function_signature!.
  #
  # Input format (STD_LIB):
  #   { args: [:Int64, :String], return: :Bool, zig: "..." }
  #
  # Output format (standard signature):
  #   {
  #     params: [
  #       { name: "arg0", type: :Int64, required: true, mutable: false, takes: false },
  #       { name: "arg1", type: :String, required: true, mutable: false, takes: false }
  #     ],
  #     return: { type: :Bool },
  #     zig: "..."
  #   }
  #
  # Supports extended param format for future use:
  #   args: [{ type: :Int64, mutable: true }, :String]
  #
  # Builds a standard function signature from lambda parameters and return type.
  # This allows lambdas to use the same verify_function_signature! validation.
  #
  # @param params [Array] Lambda parameters from AST (each with :name, :type, :mutable, :default, :takes)
  # @param return_type [Symbol] The inferred or declared return type
  # @return [Hash] Standard signature format with :lambda marker
  #
  # Example output:
  #   {
  #     params: [
  #       { name: "x", type: :Float64, required: true, mutable: false, takes: false }
  #     ],
  #     return: { type: :Bool },
  #     lambda: true
  #   }
  #
  # Analyze a function or lambda body: enter scope, declare params/captures,
  # visit all statements, finalize scope, and resolve the return type.
  def analyze_routine(node, body, declared_return, is_implicit)
    # 1. Routine Prologue (Before Scope)
    verify_captures!(node)
    # Save and reset returns on the current FunctionContext (supports nested lambdas).
    saved_returns = current_fn_ctx&.returns
    current_fn_ctx.returns = [] if current_fn_ctx

    # 2. Body Analysis (Inside Scope)
    with_new_scope do
      og_push_scope
      declare_and_verify_params(node)
      declare_captures(node)

      if body.is_a?(Array)
        body.each { |stmt| visit(stmt) }
      else
        visit(body)
      end

      finalize_scope(node)
      og_pop_scope
    end

    # 3. Routine Epilogue (Process Returns)
    found_returns = (current_fn_ctx&.returns || []).uniq
    # Restore saved returns (for enclosing function/lambda).
    current_fn_ctx.returns = saved_returns if current_fn_ctx && saved_returns
    verify_returns(node, found_returns, is_implicit ? nil : declared_return)

    # Resolve return type (infer if implicit or :Any)
    return_type = if body.is_a?(Array)
      found_returns.any? ? found_returns.first[:type] : :Any
    else
      body.resolved_type
    end

    # Update return type if we can narrow it
    if (is_implicit || declared_return == :Any) && found_returns.any?
      inferred = found_returns.first[:type]
      if is_implicit || found_returns.size == 1
        return_type = inferred
      end
    end

    return_type
  end

  def build_lambda_signature(params, return_type)
    normalized_params = params.map do |param|
      {
        name: param[:name],
        type: param[:type],
        required: param[:default].nil?,
        mutable: param[:mutable] || false,
        takes: param[:takes] || false
      }
    end

    {
      params: normalized_params,
      return: { type: return_type },
      lambda: true
    }
  end

  # Resolve a function call: look up the function, dispatch based on type
  # (intrinsic, user-defined, fn-type variable, generic), validate args,
  # and set the call node's full_type. Also tags cross-module, extern,
  # heap_promoted_call flags.
  def resolve_call(node, args)
    func_name = node.name

    scope = lookup_scope_for(func_name)
    unless scope
      error!(node, "Undefined function '#{func_name}'")
      return
    end

    func_type = scope.resolve_type(func_name)

    if func_type == :Intrinsic
      visit_IntrinsicFunc(node, args)

    elsif func_type.is_a?(Hash)
      node.module_alias = func_type.module_alias if node.respond_to?(:module_alias=) && func_type.module_alias
      if node.respond_to?(:extern_call=) && func_type.extern
        node.extern_call = true
        node.extern_effects = func_type.extern_effects if func_type.extern_effects
        record_effect(EffectTracker::EXTERN)
        # EXTERN FN with EFFECTS :alloc needs rt for allocator injection.
        alloc_kind = func_type.extern_effects&.dig(:alloc)
        if alloc_kind && current_fn_ctx
          if alloc_kind == :heap
            current_fn_ctx.heap_count += 1
          else
            current_fn_ctx.frame_count += 1
          end
        end
      end

      if func_type.extern
        args.each do |arg|
          ti = arg.type_info rescue nil
          if ti&.respond_to?(:soa?) && ti.soa?
            error!(arg, "@soa collections cannot be passed to EXTERN FN — SOA memory layout is incompatible with C ABI. Materialize to a regular array first.")
          end
        end
        # Comptime params: extract type args from arguments in comptime positions.
        # The argument is a TYPE_ID Identifier (e.g., MyDoc) — set it as a generic_type_arg.
        comptime_type_args = []
        params = func_type.params || []
        params.each_with_index do |p, i|
          if p[:comptime] && args[i].is_a?(AST::Identifier)
            comptime_type_args << args[i].name.to_sym
            args[i].full_type = :Type  # Mark as type-value, not a variable
          end
        end
        if comptime_type_args.any?
          node.generic_type_args = comptime_type_args if node.respond_to?(:generic_type_args=)
        end
      end

      type_params = func_type.type_params
      if type_params&.any?
        # For EXTERN FN with comptime params, the type bindings come directly from
        # the comptime arguments (e.g. T=JsonRecord), not from inference on resolved_type.
        comptime_type_args ||= []
        if func_type.extern && comptime_type_args.any?
          subst = {}
          type_params.each_with_index { |tp, i| subst[tp] = comptime_type_args[i] if comptime_type_args[i] }
        else
          subst = infer_generic_type_args!(node, func_type, args, type_params)
        end
        node.generic_type_args = type_params.map { |tp| subst[tp] } if node.respond_to?(:generic_type_args=)
        substituted = substitute_type_params(func_type, subst)
        call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
        verify_function_signature!(call_node, substituted)
        node.full_type = substituted[:return][:type]
      else
        call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
        verify_function_signature!(call_node, func_type)
        node.full_type = func_type.return_type
      end


    elsif func_type.is_a?(Type) && func_type.fn_type?
      node.fn_var_call = true if node.respond_to?(:fn_var_call=)
      lookup_scope_for(func_name)&.mark_read(func_name)
      synthetic_sig = {
        params: func_type.raw[:params],
        return: { type: func_type.raw[:return][:type] }
      }
      call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
      verify_function_signature!(call_node, synthetic_sig)
      node.full_type = func_type.raw[:return][:type]

    elsif func_type.is_a?(Symbol)
      node.full_type = func_type

    else
      error!(node, "Cannot call '#{func_name}' - not a function")
    end

    # Tag calls that return collections (direct or via struct fields) so the
    # caller knows to use heapAlloc for cleanup of promoted data.
    # String returns only get heap_promoted_call from callee.returns_promoted
    # (not from type alone) because stdlib string functions like readFile use
    # frameAlloc internally — the caller shouldn't try to free those.
    if node.type_info.is_a?(Type)
      callee_node = @fn_nodes[func_name]
      if callee_node&.return_provenance == :heap
        node.type_info.provenance = :heap if node.type_info.is_a?(Type)
      elsif node.type_info&.needs_escape_promotion? && !node.type_info&.string?
        node.type_info.provenance = :heap if node.type_info.is_a?(Type)
      else
        # Union return types with heap variants need heap_promoted_call
        # when the callee allocates at all (frame, heap, or alloc).
        ret_type = node.type_info
        if ret_type
          ret_sym = ret_type.is_a?(Type) ? ret_type.resolved : ret_type
          schema = lookup_type_schema(ret_sym)
          if schema.is_a?(Hash) && schema[:kind] == :union
            has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
            callee_allocates = callee_node&.return_provenance == :heap || callee_node&.uses_frame || callee_node&.uses_heap || callee_node&.uses_alloc
            if has_heap && callee_allocates
              node.type_info.provenance = :heap if node.type_info.is_a?(Type)
            end
          end
        end
      end
    end
  end

  def normalize_intrinsic_signature(config)
    return nil if config[:args] == :Varargs

    params = config[:args].each_with_index.map do |arg_def, i|
      if arg_def.is_a?(Hash)
        # Extended format: { type: :Int64, mutable: true, takes: false }
        {
          name: arg_def[:name] || "arg#{i}",
          type: arg_def[:type],
          required: true,
          mutable: arg_def[:mutable] || false,
          takes: arg_def[:takes] || false
        }
      else
        # Simple format: just a type symbol
        {
          name: "arg#{i}",
          type: arg_def,
          required: true,
          mutable: false,
          takes: false
        }
      end
    end

    FunctionSignature.new(
      params: params,
      return_type: config[:return],
      intrinsic: true,
      zig_pattern: config[:zig]
    )
  end

  def verify_function_signature!(node, signature)
    params = signature[:params]
    min_args = params.count { |param| param[:required] }
    max_args = params.size
    given_args = node.args.size

    # A. Arity Check (Count)
    if given_args < min_args || given_args > max_args
      if min_args == max_args
        error!(node, :ARITY_MISMATCH, node.name, min_args, given_args)
      else
        error!(node, :ARITY_MISMATCH_RANGE, node.name, min_args, max_args, given_args)
      end
    end

    # For alias overlap
    encountered_args = []

    node.args.each_with_index do |arg_node, i|
      param = params[i]
      next if param[:comptime]  # comptime type params are not type-checked
      verify_param_lifetime!(arg_node, param, signature)

      # B. Check mutability
      if param[:mutable]
        # Rule 1: Must be a Variable (Identifier), not a literal/expression
        if !arg_node.is_a?(AST::Identifier)
          error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_EXPRESSION, i+1, param[:name])
        end

        # Rule 2: The Variable being passed must be MUTABLE
        # We check the scope to see if the user declared it with 'MUTABLE'
        if current_scope.is_immutable?(arg_node.name)
          error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_MUTABLE, i+1, param[:name], arg_node.name)
        end
      end

      # C. Handle ownership (Affine / Linear):
      # TAKES (callee declares ownership) or GIVE (caller relinquishes ownership)
      # Both suppress caller-side cleanup. Unwrap MoveNode to get the identifier.
      is_give = arg_node.is_a?(AST::MoveNode)
      inner_node = is_give ? arg_node.value : arg_node
      if param[:takes] || is_give
        # Reject borrowed values passed to TAKES params.
        # Container index access (arr[i], map[key]) returns a borrow -
        # you cannot take ownership of data inside a container.
        # Use .remove(i) or COPY arr[i] instead.
        if inner_node.respond_to?(:container_borrow) && inner_node.container_borrow
          arg_ti = inner_node.type_info
          arg_ti = Type.new(arg_ti) if arg_ti && !arg_ti.is_a?(Type)
          is_copy = arg_ti&.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil } rescue true
          unless is_copy
            error!(inner_node, "Cannot pass container index access to TAKES parameter. " \
              "Index access returns a borrow. Use .remove(i) to take ownership, or COPY to deep-copy.")
          end
        end

        # Ensure @list args to TAKES params are heap-owned (implicit COPY).
        if inner_node.is_a?(AST::Identifier)
          owned = ensure_owned_value!(inner_node, param[:type])
          node.args[i] = owned if owned
        end

        move_if_not_copyable!(inner_node)
        inner_node.was_moved = true
        arg_node.was_moved = true
      end

      # D0. @link arguments cannot be passed to functions expecting a concrete type.
      # The caller must RESOLVE the weak ref first. Skip for :Any params (intrinsics).
      arg_ti = arg_node.respond_to?(:type_info) ? arg_node.type_info : nil
      expected_raw = param[:type]
      if arg_ti&.link? && expected_raw != :Any
        param_type_obj = expected_raw.is_a?(Type) ? expected_raw : nil
        unless param_type_obj&.link?
          arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
          error!(arg_node, "Cannot pass @link variable '#{arg_name}' to parameter '#{param[:name]}' — RESOLVE it first to get an optional strong reference.")
        end
      end

      # D. Type Check
      expected = param[:type]
      actual = arg_node.resolved_type

      match = false

      # Case 0: fn_type structural check.
      # resolved_type only returns the return-type symbol for fn_types, so we
      # must compare the full Type objects to validate signature compatibility.
      expected_type_obj = expected.is_a?(Type) ? expected : Type.new(expected || :Any)
      if expected_type_obj.fn_type? && arg_node.respond_to?(:full_type)
        actual_type_obj = arg_node.full_type
        if actual_type_obj.is_a?(Type) && expected_type_obj.accepts?(actual_type_obj)
          match = true
        elsif actual_type_obj.is_a?(Type) && actual_type_obj.fn_type? &&
              actual_type_obj.raw[:reentrant] && !expected_type_obj.raw[:reentrant]
          arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
          error!(arg_node,
            "Reentrancy Error: '#{arg_name}' is @reentrant but parameter '#{param[:name]}' " \
            "does not accept @reentrant functions. " \
            "Declare the parameter type as 'FN(...) -> Type @reentrant' to allow this.")
        end
      end

      # Case 1: Exact Match or Any
      if !match && (expected == :Any || actual == :Any || expected == actual)
        match = true

      elsif !match && is_safe_autocast?(actual, expected)
        arg_node.coerced_type = expected
        match = true
      end

      unless match
        arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
        error!(arg_node, :ARGUMENT_TYPE_ERROR, arg_name, i+1, expected, actual)
      end

      # E. Check for Alias overlap (i.e. swap(x, x) -> ERROR!)
      current_path = get_path_to_root(arg_node)

      next if current_path.nil?
      is_mutable = param[:mutable]

      encountered_args.each_with_index do |prev, prev_index|
        # Conflict Condition:
        # 1. At least one of them is MUTABLE (Mut/Mut OR Mut/Immut)
        # 2. The paths overlap (e.g. "x" overlaps "x.child", "x" overlaps "x")
        if (is_mutable || prev[:mutable]) && paths_overlap?(current_path, prev[:path])

          error!(
            arg_node,
            "Aliasing Error: Argument #{i+1} ('#{arg_node.name rescue 'arg'}') conflicts with argument #{prev_index+1}.\n" \
            "Cannot pass the same variable defined at '#{current_path.first}' twice if one usage is MUTABLE.\n" \
            "This violates exclusive mutability."
          )
        end
      end

      # Register this argument for future checks
      encountered_args << {
        path: current_path,
        mutable: is_mutable,
        name: arg_node.respond_to?(:name) ? arg_node.name : "arg"
      }
    end
  end

  # TODO: Needs updated once lifetimes are complex
  # TODO: At definition time, verify the full path is valid
  def verify_param_lifetime!(arg_node, param, signature)
    return true if !arg_node.is_a?(AST::Identifier)

    if param[:mutable] && !@og.can_write?(arg_node.name)
      error!(arg_node, "Lifetime Error: Cannot pass '#{arg_node.name}' as mutable argument because it is currently RESTRICTed.")
    end

    lifetime = signature.dig(:return, :lifetime)
    return true if lifetime.nil?

    borrow_type = param[:mutable] ? :mutable : :immutable
    return true if current_scope.is_immutable?(arg_node.name) || current_scope.is_restricted?(arg_node.name)

    base_path = signature.dig(:return, :lifetime).split(".").first
    return true if param[:name] != base_path

    error!(arg_node, "Lifetime Error: param `#{param[:name]}` is mutable, must be RESTRICTed before it can be borrowed.")
  end

  # TODO: Still only supports simple lifetimes, partially arrays
  # TODO: Need to support wildcard and OR lifetimes
  def verify_lifetime!(node)
    return true if node.return_lifetime.nil?

    # 1. Parse the path (Reuse the robust logic you just verified)
    # This gives you [:f, :b]
    path = get_path_to_root(node.return_lifetime)

    # 2. Check the Root Parameter
    root_param_name = path.first.to_s
    param = node.params.find { |p| p[:name] == root_param_name }

    if param.nil?
      error!(node, "Lifetime Error: Scoped lifetime '#{root_param_name}' is not a parameter.")
    end

    # Extract the resolved type name (Type objects from parse_type_annotation)
    param_type = param[:type]
    current_type_name = param_type.is_a?(Type) ? param_type.resolved : param_type.to_sym

    path.drop(1).each do |field_sym|
      field_name = field_sym.to_s

      # Stop if we hit an Array index wildcard (we can't verify types past a dynamic index easily yet)
      break if field_sym == :* # Look up the definition (e.g. { index: :Float64 })
      # You added this method to Scope earlier!
      schema = current_scope.resolve_type_definition(current_type_name)

      if schema.nil?
        error!(node, "Lifetime Error: Type '#{current_type_name}' is not a struct, cannot access field '#{field_name}'.")
      end

      # Check if the field exists in the schema
      next_type = schema[field_name] || schema[field_sym] # handle string/sym keys

      if next_type.nil?
        error!(node, "Lifetime Error: Type '#{current_type_name}' has no field '#{field_name}'.")
      end

      # Advance to the next type name (Type objects carry the resolved name)
      current_type_name = next_type.is_a?(Type) ? next_type.resolved : next_type.to_sym
    end

    return true
  end

  def declare_and_verify_params(node)
    node.params.each do |param|
      # Validate Defaults (unchanged)
      if param[:default]
        visit(param[:default])

        def_type = param[:default].resolved_type
        param_type = param[:type]

        unless is_safe_autocast?(def_type, param_type)
          error!(node, "Type Error: Default value for '#{param[:name]}' expects #{param_type}, got #{def_type}")
        end
        # TODO: If types different, set coerced_type
      end

      current_scope.declare(
        param[:name], nil, param[:type], param[:mutable], false, nil, :stack
      )
      # TAKES parameters own the data — force :affine so cleanup is emitted.
      current_scope.locals[param[:name]].takes = true if param[:takes]
      classify_ownership!(current_scope.locals[param[:name]])
      og_declare(param[:name], nil, param[:type], :stack)
      # Non-TAKES parameters are implicit borrows. Mark in OG so the
      # annotator prevents storing borrowed data into owned containers.
      unless param[:takes]
        @og[param[:name]]&.kind = :borrowed
      end
      param[:type]
    end
  end

  # Cannot be part of declare, needs to happen in outer-scope
  def verify_captures!(node)
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      # cap is likely a hash: { name: "x" }
      cap_name = cap[:name]

      if !current_scope.locals.key?(cap_name)
        # Check if it's in a higher scope
        owner_scope = lookup_scope_for(cap_name)
        if owner_scope.nil?
           error!(node, "Cannot capture undefined variable '#{cap_name}'")
        end
      else
        # Local capture
        owner_scope = current_scope
      end

      # FORCE HEAP PROMOTION for captures:
      # If captured by a closure, it must be on the heap so it outlives its stack frame.
      entry = owner_scope.locals[cap_name]
      if (entry.storage == :frame || entry.storage == :stack) && Type.new(entry.type).requires_move?
        promote_to_heap(cap_name, owner_scope)
      end

      # SAVE TYPE AND STORAGE (Re-fetch entry after potential promotion)
      entry = owner_scope.locals[cap_name]

      if cap[:mutable] && !entry.mutable
        error!(node, "Cannot capture immutable variable '#{cap_name}' as MUTABLE")
      end

      # Enrich the capture node with the resolved type
      cap[:type] = entry.type
      cap[:storage] = entry.storage
    end
  end

  def declare_captures(node)
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      current_scope.declare(
        cap[:name],
        nil,
        cap[:type],
        cap[:mutable],
        false,
        nil,
        cap[:storage]
      )
    end
  end

  def verify_returns(node, found_returns, declared_return)
    if found_returns.size > 1
      # Normalize: all string-like types (Byte[N], String) → String for comparison
      normalized = found_returns.map { |r|
        t = r[:type].to_s
        (t.start_with?("Byte[") || t == "String") ? :String : r[:type]
      }.uniq.size
      if declared_return != :Any && normalized > 1
        error!(node, "Ambiguous Return: Function returns multiple types #{found_returns}, specify :Any as type")
      end
    end
  end

  def get_return_strategy(return_type)
    type = Type.new(return_type)

    # 1. Small Objects & Pointers -> Return in Register (Fastest)
    if !type.requires_move? || type.heap?
      return :register
    elsif type.void?
      return :void
    else
      # Structs, Fixed Arrays, etc.
      return :destination_pass
    end
  end

  def verify_return(node)

    # Only verify for fields & indexes
    return true if !node.is_a?(AST::GetField) && !node.is_a?(AST::GetIndex)

    # Union variant constructors (Value.Nil, Shape.Point) are new values, not field borrows.
    if node.is_a?(AST::GetField) && node.target.is_a?(AST::Identifier)
      schema = lookup_type_schema(node.target.name.to_sym) rescue nil
      return true if schema.is_a?(Hash) && (schema[:kind] == :union || schema[:kind] == :enum)
    end

    # Get the current function's return lifetime annotation
    lifetime_path = current_fn_ctx&.lifetime

    type_info = node.type_object

    # TODO: Need to propagate GIVE, implement copyable
    has_lifetime = !lifetime_path.nil?
    is_copyable = type_info.copyable?
    has_give = false
    # Type params (e.g. T in a generic function) are always returnable —
    # the Zig comptime system handles copies/moves at specialization time.
    fn_type_params = current_fn_ctx&.type_params || []
    is_type_param = fn_type_params.include?(type_info&.resolved)

    if !has_lifetime && !is_copyable && !has_give && !is_type_param
      if node.is_a?(AST::GetField)
        access_type = "field"
        access_name = "field '#{node.field}'"
      else
        access_type = "element"
        access_name = "element at index"
      end

      error!(
        node,
        "Cannot return #{access_name} without:\n" \
        "  1) A lifetime annotation on the function (e.g., fn foo(...) RETURNS lifetime:Type -> )\n" \
        "  2) GIVE to transfer ownership\n" \
        "  3) COPY for copyable types\n" \
        "#{access_type.capitalize} type '#{node.full_type}' requires one of these."
      )
    end

    # We're done, below we validate lifetime
    return true if !has_lifetime

    # TODO: This needs to change when lifetimes allow splats, ORs
    lifetime_path = lifetime_path.split(".").map(&:to_sym)

    actual_path = get_path_to_root(node)
    if actual_path.nil?
      error!("Lifetime Error: Lifetime '#{lifetime_path}' specified on return, but returned value is not associated.")
    end

    # Logic: The actual return must be "under" the declared lifetime.
    # declared: r.foo -> return: r.foo.bar (OK)
    # declared: r.foo.bar1 -> return: r.foo.bar2 (FAIL)
    # We check if the Actual Path starts with the Expected Path
    if actual_path[0...lifetime_path.size] != lifetime_path
       error!(
         node,
         "Lifetime Error:\n" \
         "  Expected return derived from: #{lifetime_path.join('.')}\n" \
         "  Actual return derived from:   #{actual_path.join('.')}"
       )
    end
  end

  def paths_overlap?(path_a, path_b)
    # 1. Different Roots? (e.g. [:x, ...] vs [:y, ...]) -> No Overlap
    return false if path_a.first != path_b.first

    # 2. Same Root -> Check if one is a prefix of the other.
    # We only compare up to the length of the shorter path.
    # [:x, :a] vs [:x, :b] -> Compare [:x, :a] vs [:x, :b] -> mismatch at index 1 -> Safe.
    # [:x] vs [:x, :y]     -> Compare [:x] vs [:x]          -> match -> Unsafe.

    len = [path_a.size, path_b.size].min
    return path_a[0...len] == path_b[0...len]
  end

  # Finds the first intrinsic overload that matches the given arguments.
  # Returns nil if no overload matches.
  def find_matching_intrinsic(definitions, args)
    definitions.find do |config|
      next true if config[:args] == :Varargs  # Varargs accepts anything

      # Arity check
      next false if args.size != config[:args].size

      # Type check each argument, including capability constraints.
      # Hash args like { type: :String, sync: :raw } check both the base
      # type and the capability. This allows the registry to dispatch to
      # different Zig implementations based on the argument's capability.
      args.each_with_index.all? do |arg, i|
        spec = config[:args][i]
        if spec.is_a?(Hash)
          expected = spec[:type]
          next false unless is_safe_autocast?(arg.resolved_type, expected)
          # Check capability constraints (sync, ownership, etc.)
          arg_type = arg.type_info.is_a?(Type) ? arg.type_info : nil
          next false if spec[:sync] && arg_type&.sync != spec[:sync]
          next false if spec[:ownership] && arg_type&.ownership != spec[:ownership]
          true
        else
          is_safe_autocast?(arg.resolved_type, spec)
        end
      end
    end
  end

  # Formats intrinsic args for error messages
  def format_intrinsic_args(args)
    return "(varargs)" if args == :Varargs
    types = args.map { |a| a.is_a?(Hash) ? a[:type] : a }
    "(#{types.join(', ')})"
  end
end

