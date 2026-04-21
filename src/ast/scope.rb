require "set"
require_relative "./symbol_entry"

class Scope
  attr_accessor :locals, :dependencies, :owned_names
  attr_reader   :types

  def initialize
    @locals = {}
    @dependencies = {}
    @types = {}
    @owned_names = Set.new  # Variables declared in THIS scope (not inherited from parent)
  end

  def declare(name, reg, type, is_mutable = true, is_rebindable = false, size = nil, storage = :stack, capabilities = Set.new, _borrowed_paths = [], sync: nil, resource: nil, close_zig: nil)
    @owned_names.add(name)
    entry = SymbolEntry.new(
      reg: reg,
      type: type,
      mutable: is_mutable,
      storage: storage,
      sync: sync,
      rebindable: is_rebindable,
      size: size || 0,
      capabilities: capabilities,
      resource: resource,
      close_zig: close_zig,
    )
    entry.scope = self
    @locals[name] = entry
  end

  def initialize_copy(original)
    super

    # 1. Deep Copy Locals
    # We must dup the Hash AND the values inside it (the entries)
    # AND mutable objects inside the entries (like the capabilities Set)
    @locals = original.locals.transform_values do |entry|
      new_entry = entry.dup
      # Sets/Arrays inside the entry must be duped too, or they remain shared
      new_entry.capabilities = entry.capabilities.dup
      new_entry.scope = self  # Point to the new (copied) scope
      new_entry
    end

    # 2. Copy State Maps (var state lives on entries, already duped above)
    @dependencies = original.dependencies.dup
    @types = original.types.dup
    # Child scopes inherit variables but don't own them — start with empty owned_names.
    # Only variables declared in this scope (via `declare`) are in @owned_names.
    @owned_names = Set.new

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
    entry ? entry.size : nil
  end

  def resolve_reg(name)
    entry = @locals[name]
    entry ? entry.reg : nil
  end

  # Returns a Type carrying the variable's base type plus storage-derived capabilities.
  def resolve_full_type(name)
    entry = @locals[name]
    return Type.new(:Any) if entry.nil?

    stored = entry.type

    # If already a Type (e.g. from parse_type_annotation), clone and overlay storage
    # If a non-Symbol (e.g. a function signature Hash), wrap as-is
    base_type = stored.is_a?(Type) ? stored : Type.new(stored)

    # Overlay storage-derived capabilities onto the type
    case entry.storage
    when :frozen
      base_type.ownership = :frozen
    when :multiowned
      base_type.ownership = :multiowned
    when :shared
      base_type.ownership = :shared
    when :link
      base_type.ownership = :link
      base_type.link_source = entry.link_source
    when :rodata
      base_type.provenance = :rodata  # string literal: static data, never freed
    when :frame
      base_type.provenance = :frame   # large local var: arena pointer (*T in Zig)
    when :heap
      if entry.sync == :locked
        base_type.sync = :locked
      elsif entry.sync == :write_locked
        base_type.sync = :write_locked
      else
        base_type.provenance = :heap
      end
    end

    # Always propagate sync — it may coexist with an ownership wrapper (e.g. @shared:locked
    # has storage=:shared AND sync=:locked; the case above only sets ownership).
    base_type.sync = entry.sync if entry.sync && !base_type.sync

    base_type
  end

  def resolve_type(name)
    entry = @locals[name]
    entry ? entry.type : :Any
  end

  def is_mutable?(name)
    entry = @locals[name]
    entry ? entry.mutable : true
  end

  def is_immutable?(name)
    !is_mutable?(name)
  end

  def is_restricted?(name)
    @locals[name]&.capabilities&.include?(:RESTRICT)
  end

  def is_on_heap?(name)
    entry = @locals[name]
    entry ? [:heap, :multiowned, :shared].include?(entry.storage) : false
  end

  # Mark a variable as read (used as an r-value in user code).
  def mark_read(name)
    entry = @locals[name]
    return unless entry
    entry.read = true
    entry.reg&.tap { |r| r.var_used = true if r.respond_to?(:var_used=) }
  end

  def declare_with_new_capability(capability)
    name = capability[:var_node].name
    local = capability[:old_scope].locals[name]
    error!("Cannot add capability: #{name}") if local.nil?
    local = local.dup
    # Whole-variable or field restriction: add capability marker.
    # Borrow conflict detection is handled by the OwnershipGraph.
    local.capabilities << capability[:capability]
    @locals[name] = local
  end

  def get_path_to_root(node)
    path = []
    curr = node
    while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
      if curr.is_a?(AST::GetField)
        path.unshift(curr.field.to_sym)
      elsif curr.is_a?(AST::GetIndex)
        path.unshift(:*)
      end
      curr = curr.target
    end
    path.unshift(curr.name.to_sym)
    path
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
        @locals[view_name].valid = false
        @locals[view_name].invalid_reason = "The owner '#{owner_name}' was modified (resized or rebound), invalidating this view."
      end
    end

    # Clear the list (the views are dead, no need to track them anymore)
    @dependencies[owner_name] = []
  end

  def check_validity!(name)
    entry = @locals[name]
    return unless entry

    if entry.valid == false
      raise "Compile Error: Cannot use variable '#{name}'. Reason: #{entry.invalid_reason}"
    end
  end

  def invalidate_size(name)
    if @locals[name]
      @locals[name].size = nil
    end
  end

  def is_boxed?(name)
    entry = @locals[name]
    false  # :boxed is unused — legacy stub
  end

  def narrow_type(name, new_type)
    return unless @locals[name]
    current_type = @locals[name].type
    if current_type == :Any
      @locals[name].type = new_type
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

  # Resolve a name as either a local variable or a function-as-value reference.
  # Returns the scope where the name is found, or nil if undefined.
  # Checks current scope locals first, then falls back to lookup_scope_for
  # to find named functions used as values (fn-type references).
  def resolve_variable_scope(name)
    scope = current_scope
    if scope.locals.key?(name)
      scope
    else
      fn_scope = lookup_scope_for(name)
      fn_scope && fn_scope.resolve_type(name).is_a?(Hash) ? fn_scope : nil
    end
  end

  def lookup_type_schema(name)
    # For generic instances like :"Pair<Number>", look up the base type ":Pair"
    base_name = name.to_s.sub(/<.*>$/, '').to_sym
    # Search from Top (newest) to Bottom (global)
    @scope_stack.reverse_each do |scope|
      schema = scope.resolve_type_definition(base_name)
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

