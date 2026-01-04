class Scope
  attr_accessor :locals, :var_states

  def initialize
    @locals = {}
    @dependencies = {}
    @types = {}
    @var_states = {}
  end

  def declare(name, reg, type, is_mutable = true, is_rebindable = false, size = nil, storage = :stack)
    @locals[name] = {
      reg: reg,
      type: type,
      mutable: is_mutable,
      storage: storage,
      rebindable: is_rebindable,
      size: size || 0,  # TODO: see if size is ever nil
      valid: true,
      invalid_reason: nil
    }
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
    prefix = entry[:storage] == :heap ? "%" : ""
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

  def is_on_heap?(name)
    entry = @locals[name]
    entry ? entry[:storage] == :heap : false
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

