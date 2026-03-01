require "set"

class Scope
  attr_accessor :locals, :var_states, :dependencies, :var_states, :moved_paths

  def initialize
    @locals = {}
    @dependencies = {}
    @types = {}
    @var_states = {}
    @moved_paths = []  # Track moved sub-paths like [:foo, :child]
  end

  def declare(name, reg, type, is_mutable = true, is_rebindable = false, size = nil, storage = :stack, capabilities = Set.new, borrowed_paths = [])
    @locals[name] = {
      reg: reg,
      type: type,
      mutable: is_mutable,
      storage: storage,
      rebindable: is_rebindable,
      size: size || 0,  # TODO: see if size is ever nil
      capabilities: capabilities,
      borrowed_paths: borrowed_paths,
      valid: true,
      invalid_reason: nil
    }
  end

  def initialize_copy(original)
    super

    # 1. Deep Copy Locals
    # We must dup the Hash AND the values inside it (the entries)
    # AND mutable objects inside the entries (like the capabilities Set)
    @locals = original.locals.transform_values do |entry|
      new_entry = entry.dup
      # Sets/Arrays inside the entry must be duped too, or they remain shared
      new_entry[:capabilities] = entry[:capabilities].dup
      new_entry[:borrowed_paths] = entry[:borrowed_paths]&.map(&:dup) # If you implemented the path logic
      new_entry
    end

    # 2. Copy State Maps
    @var_states = original.var_states.dup
    @dependencies = original.dependencies.dup
    @moved_paths = original.moved_paths.map(&:dup)

    # 3. Types are usually static definitions, so a shallow copy is fine
    @types = original.instance_variable_get(:@types).dup
  end

  def declare_type(name, schema)
    @types[name] = {
      schema: schema,
      # Might add metadata here later (e.g., is_packed, alignment)
    }
  end

  def resolve_type_definition(name)
    entry = @types[name]
    entry ? entry[:schema] : nil
  end

  def is_known_type?(name)
    @types.key?(name)
  end

  def get_size(name)
    entry = @locals[name]
    entry ? entry[:size] : nil
  end

  def resolve_reg(name)
    entry = @locals[name]
    entry ? entry[:reg] : nil
  end

  # TODO: Hack, types are registered as a single string, need to be registered as a struct
  def resolve_full_type(name)
    entry = @locals[name]
    return :Any if entry.nil?
    return entry[:type] if !entry[:type].is_a?(Symbol)
    prefix = case entry[:storage]
             when :heap       then "%"
             when :multiowned then "@"
             else                  ""
             end
    :"#{prefix}#{entry[:type]}"
  end

  def resolve_type(name)
    entry = @locals[name]
    entry ? entry[:type] : :Any
  end

  def is_mutable?(name)
    entry = @locals[name]
    entry ? entry[:mutable] : true
  end

  def is_immutable?(name)
    !is_mutable?(name)
  end

  def is_borrowable?(name, requested_path, type)
    is_immutable?(name) ||
      (is_restricted?(name) && can_borrow?(name, requested_path, type))
  end

  def is_restricted?(name)
    @locals.dig(name, :capabilities).include?(:RESTRICT)
  end

  def can_borrow?(name, requested_path, requested_type)
    entry = @locals[name]

    entry[:borrowed_paths].each do |borrow|
      existing_path = borrow[:path]
      existing_type = borrow[:type]

      is_overlapping = path_overlaps?(existing_path, requested_path)
      next unless is_overlapping

      # 2. APPLY RUST RULES
      # Rule A: If I want a WRITER (Mutable), NO ONE else can be there.
      if requested_type == :mutable
        return false # Conflict with ANY existing borrow
      end

      # Rule B: If I want a READER (Immutable), only WRITERS block me.
      # (Existing Readers are fine!)
      if requested_type == :immutable && existing_type == :mutable
        return false # Conflict with existing writer
      end
    end

    true
  end

  def path_overlaps?(p1, p2)
    return true if p1 == p2
    return true if p2.size > p1.size && p2[0...p1.size] == p1
    return true if p1.size > p2.size && p1[0...p2.size] == p2
    false
  end

  def mark_borrowed(name, path, type)
    @locals.dig(name, :borrowed_paths) << { path: path, type: type }
  end

  # Mark a sub-path as moved (e.g., [:foo, :child] for foo.child)
  def mark_path_moved(path)
    @moved_paths << path
  end

  # Check if a path or any of its ancestors has been moved
  # e.g., if [:foo, :child] is moved, then [:foo, :child, :value] is also dead
  def is_path_moved?(path)
    @moved_paths.any? do |moved|
      # Check if 'moved' is a prefix of 'path' (or equal)
      # e.g., moved=[:foo, :child], path=[:foo, :child, :value] -> true
      # e.g., moved=[:foo, :child], path=[:foo] -> false (parent is still valid)
      path.size >= moved.size && path[0...moved.size] == moved
    end
  end

  def is_on_heap?(name)
    entry = @locals[name]
    entry ? [:heap, :multiowned].include?(entry[:storage]) : false
  end

  def set_state(name, state)
    @var_states[name] = state
  end

  def get_state(name)
    @var_states[name] || :uninit
  end

  # Helper for branching
  def clone_states
    @var_states.dup
  end

  def mark_escaped(name)
    entry = @locals[name]
    return unless entry

    # Optimization: Don't promote primitives (Int, Bool, etc).
    # They copy cheaply and don't suffer from "dangling pointer" issues
    # in the same way (unless you support pointers to stack ints).
    type = entry[:type]
    return if !Type.new(type).requires_move?

    # Only promote if currently on Frame or Stack
    if entry[:storage] == :frame || entry[:storage] == :stack
      is_frame_decrement = (entry[:storage] == :frame)
      entry[:storage] = :heap

      # Update AST Node
      if entry[:reg] && entry[:reg].respond_to?(:storage=)
         entry[:reg].storage = :heap

         # Only return true (to decrement counter) if it was actually on the Frame
         return is_frame_decrement
      end
    end
    return false
  end

  def declare_with_new_capability(capability)
    name = capability[:var_node].name
    local = capability[:old_scope].locals[name]
    error!("Cannot add capability: #{name}") if local.nil?
    local = local.dup
    local[:capabilities] << capability[:capability]
    @locals[name] = local
  end

  def register_dependency(owner_name, dependent_name)
    return unless @locals.key?(owner_name) # Only track local vars

    @dependencies[owner_name] ||= []
    @dependencies[owner_name] << dependent_name
  end

  def invalidate_dependents(owner_name)
    return unless @dependencies[owner_name]

    # Mark every view watching this owner as DEAD
    @dependencies[owner_name].each do |view_name|
      if @locals[view_name]
        @locals[view_name][:valid] = false
        @locals[view_name][:invalid_reason] = "The owner '#{owner_name}' was modified (resized or rebound), invalidating this view."
      end
    end

    # Clear the list (the views are dead, no need to track them anymore)
    @dependencies[owner_name] = []
  end

  def check_validity!(name)
    entry = @locals[name]
    return unless entry

    if entry[:valid] == false
      raise "Compile Error: Cannot use variable '#{name}'. Reason: #{entry[:invalid_reason]}"
    end
  end

  def invalidate_size(name)
    if @locals[name]
      @locals[name][:size] = nil
    end
  end

  def is_boxed?(name)
    entry = @locals[name]
    entry ? entry[:boxed] : false
  end

  def narrow_type(name, new_type)
    return unless @locals[name]
    current_type = @locals[name][:type]
    if current_type == :Any
      @locals[name][:type] = new_type
      return true
    end
    # Simplified narrowing logic
    return false
  end
end

# Helper module for scope stack management.
# Include in classes that maintain @scope_stack.
module ScopeHelper
  def current_scope
    @scope_stack.last
  end

  def lookup_scope_for(name)
    # Search from Top (last) to Bottom (first)
    @scope_stack.reverse_each do |scope|
      return scope if scope.resolve_type(name) != :Any || scope.locals.key?(name)
    end
    nil
  end

  def lookup_type_schema(name)
    # Search from Top (newest) to Bottom (global)
    @scope_stack.reverse_each do |scope|
      schema = scope.resolve_type_definition(name)
      return schema if schema
    end
    nil
  end

  def with_new_scope(scope = nil)
    new_scope = scope.nil? ? Scope.new : scope.dup
    @scope_stack.push(new_scope)
    yield
    @scope_stack.pop
  end

  def is_global_scope?(scope)
    # Assuming the first scope in the stack is global
    scope == @scope_stack.first
  end
end

