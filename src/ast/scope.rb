# typed: strict
require "sorbet-runtime"

require "set"
require_relative "./symbol_entry"

class Scope
    extend T::Sig

  attr_accessor :locals, :dependencies, :owned_names
  attr_accessor :depth   # stack depth at scope creation; 0 for root
  attr_reader   :types

  sig { void }
  def initialize
    @locals = T.let({}, T::Hash[T.untyped, T.untyped])
    @dependencies = T.let({}, T::Hash[T.untyped, T.untyped])
    @types = T.let({}, T::Hash[T.untyped, T.untyped])
    @owned_names = T.let(Set.new, T::Set[T.untyped])  # Variables declared in THIS scope (not inherited from parent)
    @depth = T.let(0, Integer)
  end

  sig { params(name: String, reg: T.untyped, type: T.untyped, is_mutable: T.untyped, is_rebindable: T::Boolean, size: T.nilable(Integer), storage: Symbol, capabilities: T::Set[Symbol], _borrowed_paths: T::Array[T.untyped], sync: T.nilable(Symbol), layout: T.nilable(Symbol), resource: T.nilable(T::Boolean), close_zig: T.nilable(String)).returns(SymbolEntry) }
  def declare(name, reg, type, is_mutable = true, is_rebindable = false, size = nil, storage = :stack, capabilities = Set.new, _borrowed_paths = [], sync: nil, layout: nil, resource: nil, close_zig: nil)
    @owned_names.add(name)
    entry = SymbolEntry.new(
      reg: reg,
      type: type,
      mutable: is_mutable,
      storage: storage,
      sync: sync,
      layout: layout,
      rebindable: is_rebindable,
      size: size || 0,
      capabilities: capabilities,
      resource: resource,
      close_zig: close_zig,
    )
    entry.scope = self
    # Stamp declaring depth so escape checks can compare source and destination
    # lifetimes by scope nesting.
    entry.scope_depth = @depth
    @locals[name] = entry
  end

  # Deep-copy contract (read before adding a pass that mutates SymbolEntry):
  #
  # `Scope.dup` deep-copies every entry in @locals. This is intentional --
  # nested scopes mutate scope-local fields like `live`, `moved`,
  # `borrowed_alias`, `valid` independently of the parent. Without the
  # deep copy, an `if`/`with`/`bg` body would scribble its borrow state
  # back onto the function-level entry, and ownership analysis would
  # blow up.
  #
  # The cost: storage / sync / type changes that happen AFTER the body
  # has been visited (notably `EscapeAnalysis.propagate_caller_sync!`,
  # which mutates `param.symbol`) do NOT propagate to the deep-copied
  # entries inside nested scopes. A pass that reads `node.symbol.storage`
  # off an Identifier inside a nested scope sees the pre-propagation
  # value.
  #
  # The rule for any post-annotation pass that needs a param's CURRENT
  # storage / sync:
  #
  #   * mutate `param.symbol` (the function-level entry)
  #   * read against `Scope.live_param_syms(fn)` to refresh stale
  #     references
  #
  # See `BgCaptureClassifier.classify_one!` for the canonical example
  # (refreshes `capture_analysis.capture_symbols` against the live param
  # entries before reading sync/storage). See
  # `docs/agents/sync-boundary-unification.md` Gap C for the full
  # rationale and alternative options (B: shared boxed entries, C:
  # split scope-local vs global fields). Option A (this contract +
  # helper) is the current choice.
  sig { params(original: Scope).void }
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

  # Build a {param_name => live SymbolEntry} map from a FunctionDef.
  #
  # The "live" entry is the one stored on `param.symbol` -- the entry
  # that lives at the function scope and that `propagate_caller_sync!`
  # mutates in place. Any pass that has a `capture_symbols` (or similar)
  # cache of SymbolEntry references collected during annotation should
  # refresh those references through this helper before querying
  # storage / sync, otherwise it sees the pre-propagation snapshot
  # captured by `Scope.dup`.
  #
  # See the deep-copy contract on `Scope#initialize_copy` for why.
  sig { params(fn: AST::FunctionDef).returns(T::Hash[String, SymbolEntry]) }
  def self.live_param_syms(fn)
    return {} unless fn.respond_to?(:params)
    (fn.params || []).each_with_object({}) do |p, h|
      h[p.name.to_s] = p.symbol if p.symbol
    end
  end

  sig { params(name: Symbol, schema: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
  def declare_type(name, schema)
    @types[name] = {
      schema: schema,
      # Might add metadata here later (e.g., is_packed, alignment)
    }
  end

  sig { params(name: Symbol).returns(T.untyped) }
  def resolve_type_definition(name)
    entry = @types[name]
    entry ? entry[:schema] : nil
  end

  # Returns a Type carrying the variable's base type plus storage-derived capabilities.
  sig { params(name: String).returns(Type) }
  def resolve_full_type(name)
    entry = @locals[name]
    return Type.new(:Any) if entry.nil?

    base_type = entry.type

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
    base_type.layout = entry.layout if entry.layout && !base_type.layout
    if entry.sync == :atomic && entry.layout == :indirect && base_type.ownership == :affine
      base_type.ownership = :shared
    end

    base_type
  end

  sig { params(name: String).returns(T.untyped) }
  def resolve_type(name)
    entry = @locals[name]
    entry ? entry.type : :Any
  end

  sig { params(name: String).returns(T.untyped) }
  def is_mutable?(name)
    entry = @locals[name]
    entry ? entry.mutable : true
  end

  sig { params(name: String).returns(T::Boolean) }
  def is_immutable?(name)
    !is_mutable?(name)
  end

  sig { params(name: String).returns(T::Boolean) }
  def is_restricted?(name)
    @locals[name]&.capabilities&.include?(:RESTRICT)
  end

  # Mark a variable as read (used as an r-value in user code).
  sig { params(name: String).returns(T.untyped) }
  def mark_read(name)
    entry = @locals[name]
    return unless entry
    entry.read = true
    entry.reg&.tap { |r| r.var_used = true if r.respond_to?(:var_used=) }
  end

  # Returns the new SymbolEntry on success, nil if the binding wasn't found
  # in the cap's old_scope (caller is responsible for emitting a diagnostic).
  sig { params(capability: T::Hash[Symbol, T.untyped]).returns(T.nilable(SymbolEntry)) }
  def declare_with_new_capability(capability)
    name = capability[:var_node].name
    local = capability[:old_scope].locals[name]
    return nil if local.nil?
    local = local.dup
    # Whole-variable or field restriction: add capability marker.
    # Borrow conflict detection is handled by the OwnershipGraph.
    local.capabilities << capability[:capability]
    @locals[name] = local
  end

  sig { params(node: T.untyped).returns(T::Array[Symbol]) }
  def get_path_to_root(node)
    path = []
    curr = T.let(node, T.untyped)
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

  sig { params(name: String).void }
  def check_validity!(name)
    entry = @locals[name]
    return unless entry

    if entry.valid == false
      raise "Compile Error: Cannot use variable '#{name}'. Reason: #{entry.invalid_reason}"
    end
  end

end

# Helper module for scope stack management.
# Include in classes that maintain @scope_stack.
module ScopeHelper
    extend T::Sig

  # @scope_stack is initialized by the host class. Access it through this
  # private helper so Sorbet strict mode can verify the element type without
  # requiring a T.let declaration inside a module (which has no initialize).
  sig { returns(T::Array[Scope]) }
  def scope_stack
    T.cast(T.unsafe(self).instance_variable_get(:@scope_stack), T::Array[Scope])
  end
  private :scope_stack

  sig { returns(Scope) }
  def current_scope
    T.must(scope_stack.last)
  end

  sig { params(name: String).returns(T.nilable(Scope)) }
  def lookup_scope_for(name)
    # Search from Top (last) to Bottom (first)
    scope_stack.reverse_each do |scope|
      return scope if scope.resolve_type(name) != :Any || scope.locals.key?(name)
    end
    nil
  end

  # Resolve a name as either a local variable or a function-as-value reference.
  # Returns the scope where the name is found, or nil if undefined.
  # Checks current scope locals first, then falls back to lookup_scope_for
  # to find named functions used as values (fn-type references).
  sig { params(name: String).returns(T.nilable(Scope)) }
  def resolve_variable_scope(name)
    scope = current_scope
    if scope.locals.key?(name)
      scope
    else
      fn_scope = lookup_scope_for(name)
      fn_scope && FunctionSignature.unwrap(fn_scope.resolve_type(name)) ? fn_scope : nil
    end
  end

  sig { params(name: Symbol).returns(T.untyped) }
  def lookup_type_schema(name)
    # For generic instances like :"Pair<Number>", look up the base type ":Pair"
    base_name = name.to_s.sub(/<.*>$/, '').to_sym
    # Search from Top (newest) to Bottom (global)
    scope_stack.reverse_each do |scope|
      schema = scope.resolve_type_definition(base_name)
      return schema if schema
    end
    nil
  end

  # Every type name visible from the current scope (struct, enum, union,
  # generic). Used by typo-suggestion fixes that need a candidate set.
  sig { returns(T::Array[String]) }
  def all_known_type_names
    names = []
    scope_stack.each do |scope|
      types = scope.instance_variable_get(:@types)
      names.concat(types.keys.map(&:to_s)) if types
    end
    names.uniq
  end

  sig { params(scope: T.nilable(Scope), blk: T.untyped).returns(T.nilable(Scope)) }
  def with_new_scope(scope = nil, &blk)
    new_scope = scope.nil? ? Scope.new : scope.dup
    # Root scope keeps depth 0; each `with_new_scope` nest increases depth by
    # one so declarations can record their lifetime boundary.
    new_scope.depth = scope_stack.size
    scope_stack.push(new_scope)
    blk.call
    scope_stack.pop
  end

end
