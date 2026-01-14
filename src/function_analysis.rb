require_relative "../src/ast"

module FunctionAnalysis
  def verify_function_signature(node, signature)
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

    node.args.each_with_index do |arg_node, i|
      param = params[i]
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
      if param[:takes]
        # TODO: See if this is correct...
        current_scope.set_state(arg_node.name, :moved)
      end

      # D. Type Check
      expected = param[:type]
      actual = arg_node.resolved_type

      match = false

      # Case 1: Exact Match or Any
      if expected == :Any || actual == :Any || expected == actual
        match = true

      elsif is_safe_autocast?(actual, expected)
        arg_node.coerced_type = expected
        match = true
      end

      unless match
        arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
        error!(arg_node, :ARGUMENT_TYPE_ERROR, arg_name, i+1, expected, actual)
      end
    end
  end

  def verify_lifetime(node)
    return true if node.return_lifetime.nil?

    lifetime = node.return_lifetime.name

    error!(node, "Lifetime Error: Sub-lifetimes not yet supportd.") if lifetime.include?(".")
    error!(node, "Lifetime Error: Scoped lifetime is not a param.") if !node.params.map { |p| p[:name] }.include?(lifetime)
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
        param[:name], nil, param[:type], param[:mutable], false, nil, :stack # TODO: param[:storage]
      )
      param[:type]
    end
  end

  # Cannot be part of declare, needs to happen in outer-scope
  def verify_captures(node)
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      # cap is likely a hash: { name: "x" }
      cap_name = cap[:name]

      if !current_scope.locals.key?(cap_name)
        # Check if it's in a higher scope (Globals are visible without capture in some langs,
        # but if you require USE, we check here)
        owner_scope = lookup_scope_for(cap_name)
        if owner_scope.nil?
           error!(node, "Cannot capture undefined variable '#{cap_name}'")
        end

        # SAVE TYPE AND STORAGE
        # We need to know if the outer var is on the Heap so the inner proxy reflects that.
        entry = owner_scope.locals[cap_name]
      else
        # Local capture (e.g. lambda inside function)
        entry = current_scope.locals[cap_name]
      end

      if cap[:mutable] && !entry[:mutable]
        error!(node, "Cannot capture immutable variable '#{cap_name}' as MUTABLE")
      end

      # Enrich the capture node with the resolved type
      cap[:type] = entry[:type]
      cap[:storage] = entry[:storage]
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
      uniq_return_types = found_returns.map { |r| r[:type] }.uniq.size
      if declared_return != :Any &&uniq_return_types > 1
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
end

