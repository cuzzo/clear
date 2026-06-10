# typed: strict
require "sorbet-runtime"

require "set"
require_relative "./symbol_entry"
require_relative "./schemas"

class Scope
    extend T::Sig

  EMPTY_CAPABILITIES = T.let(Set.new.freeze, T::Set[Symbol])
  RegInput = T.type_alias { T.nilable(T.any(AST::Node, String, Symbol)) }
  MutabilityInput = T.type_alias { T.nilable(T.any(T::Boolean, Lexer::Token)) }
  ScopeTypeSchema = T.type_alias do
    T.any(Schemas::EnumSchema, Schemas::ResourceSchema, Schemas::StructSchema, Schemas::UnionSchema)
  end

  class ScopeTypeEntry < T::Struct
    extend T::Sig

    const :schema, Scope::ScopeTypeSchema
  end

  class ScopeBindings
    extend T::Sig

    sig { void }
    def initialize
      @entries = T.let({}, T::Hash[String, SymbolEntry])
    end

    sig { returns(T::Hash[String, SymbolEntry]) }
    attr_reader :entries

    sig { params(name: String).returns(T.nilable(SymbolEntry)) }
    def [](name)
      @entries[name]
    end

    sig { params(name: String, entry: SymbolEntry).returns(SymbolEntry) }
    def []=(name, entry)
      @entries[name] = entry
    end

    sig { params(name: String).returns(T::Boolean) }
    def key?(name)
      @entries.key?(name)
    end

    sig { returns(T::Array[String]) }
    def keys
      @entries.keys
    end

    sig { returns(Integer) }
    def length
      @entries.length
    end

    sig { returns(T::Array[[String, SymbolEntry]]) }
    def pairs
      @entries.to_a
    end

    sig { params(block: T.proc.params(name: String, entry: SymbolEntry).void).void }
    def each(&block)
      @entries.each { |name, entry| block.call(name, entry) }
      nil
    end
  end

  class ScopeTypes
    extend T::Sig

    sig { void }
    def initialize
      @entries = T.let({}, T::Hash[Symbol, Scope::ScopeTypeEntry])
    end

    sig { returns(T::Hash[Symbol, Scope::ScopeTypeEntry]) }
    attr_reader :entries

    sig { params(name: Symbol, schema: Scope::ScopeTypeSchema).returns(Scope::ScopeTypeEntry) }
    def declare(name, schema)
      @entries[name] = Scope::ScopeTypeEntry.new(schema: schema)
    end

    sig { params(name: Symbol).returns(T.nilable(Scope::ScopeTypeEntry)) }
    def [](name)
      @entries[name]
    end

    sig { returns(T::Array[Symbol]) }
    def keys
      @entries.keys
    end
  end

  attr_accessor :owned_names
  sig { returns(T::Hash[String, String]) }
  attr_reader :dependencies
  attr_accessor :depth   # stack depth at scope creation; 0 for root
  attr_reader   :types, :parent

  sig { void }
  def initialize
    @parent = T.let(nil, T.nilable(Scope))
    @bindings = T.let(ScopeBindings.new, ScopeBindings)
    @dependencies = T.let({}, T::Hash[String, String])
    @type_store = T.let(ScopeTypes.new, ScopeTypes)
    @types = T.let(@type_store.entries, T::Hash[Symbol, Scope::ScopeTypeEntry])
    @owned_names = T.let(Set.new, T::Set[String])  # Variables declared in THIS scope (not inherited from parent)
    @depth = T.let(0, Integer)
  end

  sig { params(name: String, reg: RegInput, type: SymbolEntry::TypeInput, is_mutable: MutabilityInput, is_rebindable: T::Boolean, size: T.nilable(Integer), storage: Symbol, capabilities: T::Set[Symbol], _borrowed_paths: T::Array[SymbolEntry], sync: T.nilable(Symbol), layout: T.nilable(Symbol), resource: T.nilable(T::Boolean), close_plan: T.nilable(Schemas::ResourceClosePlan)).returns(SymbolEntry) }
  def declare(name, reg, type, is_mutable = true, is_rebindable = false, size = nil, storage = :stack, capabilities = Set.new, _borrowed_paths = [], sync: nil, layout: nil, resource: nil, close_plan: nil)
    @owned_names.add(name)
    entry = SymbolEntry.new(
      reg: reg,
      type: type,
      mutable: !!is_mutable,
      storage: storage,
      sync: sync,
      layout: layout,
      rebindable: is_rebindable,
      size: size || 0,
      capabilities: capabilities,
      resource: resource,
      close_plan: close_plan,
    )
    entry.scope = self
    # Stamp declaring depth so escape checks can compare source and destination
    # lifetimes by scope nesting.
    entry.scope_depth = @depth
    @bindings[name] = entry
  end

  sig { params(name: String, entry: SymbolEntry, owned: T::Boolean).returns(SymbolEntry) }
  def install_entry(name, entry, owned: true)
    @owned_names.add(name) if owned
    entry.scope = self
    entry.scope_depth = @depth
    @bindings[name] = entry
  end

  # Composed-scope contract (read before adding a pass that mutates SymbolEntry):
  #
  # `Scope.dup` creates a child scope with a parent link and an empty local
  # binding table. Reads walk the parent chain. Mutations that need branch-local
  # state MUST use `entry_for_write`, which materializes a local SymbolEntry
  # copy on demand. This keeps branch scopes from eagerly copying every visible
  # local in large branch-heavy functions.
  #
  # This is a migration step toward splitting SymbolEntry declaration metadata
  # from mutable branch flow facts. Do not add new callers of `locals`.
  sig { params(original: Scope).void }
  def initialize_copy(original)
    super

    @parent = original
    @bindings = ScopeBindings.new
    @dependencies = original.dependencies.dup
    @type_store = ScopeTypes.new
    @types = @type_store.entries
    @owned_names = Set.new
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
    fn.params.each_with_object({}) do |p, h|
      h[p.name.to_s] = p.symbol if p.symbol
    end
  end

  sig { params(name: Symbol, schema: ScopeTypeSchema).returns(ScopeTypeEntry) }
  def declare_type(name, schema)
    @type_store.declare(name, schema)
  end

  sig { params(name: Symbol).returns(T.untyped) }
  def resolve_type_definition(name)
    resolve_type_entry(name)&.schema
  end

  sig { params(name: Symbol).returns(T.nilable(ScopeTypeEntry)) }
  def resolve_type_entry(name)
    @type_store[name] || @parent&.resolve_type_entry(name)
  end

  sig { returns(T::Hash[Symbol, ScopeTypeEntry]) }
  def visible_types
    inherited = @parent ? @parent.visible_types : {}
    inherited.merge(@types)
  end

  sig { params(name: String).returns(T.nilable(SymbolEntry)) }
  def local_entry(name)
    @bindings[name]
  end

  sig { params(name: String).returns(SymbolEntry) }
  def local_entry!(name)
    T.must(local_entry(name))
  end

  sig { params(name: String).returns(T.nilable(SymbolEntry)) }
  def resolve_entry(name)
    @bindings[name] || @parent&.resolve_entry(name)
  end

  sig { params(name: String).returns(SymbolEntry) }
  def resolve_entry!(name)
    T.must(resolve_entry(name))
  end

  sig { params(name: String).returns(T::Boolean) }
  def local_entry?(name)
    @bindings.key?(name)
  end

  sig { params(name: String).returns(T::Boolean) }
  def entry?(name)
    local_entry?(name) || !!@parent&.entry?(name)
  end

  sig { params(name: String).returns(T.nilable(SymbolEntry)) }
  def entry_for_write(name)
    entry = @bindings[name]
    return entry if entry

    inherited = @parent&.resolve_entry(name)
    return nil unless inherited

    materialized = clone_entry_for_scope(inherited)
    @bindings[name] = materialized
  end

  sig { params(name: String).returns(SymbolEntry) }
  def entry_for_write!(name)
    T.must(entry_for_write(name))
  end

  sig { params(entry: SymbolEntry).returns(SymbolEntry) }
  def clone_entry_for_scope(entry)
    new_entry = entry.dup
    new_entry.capabilities = entry.capabilities.empty? ? EMPTY_CAPABILITIES : entry.capabilities.dup
    new_entry.scope = self
    new_entry
  end

  sig { returns(T::Hash[String, SymbolEntry]) }
  def local_entries
    @bindings.entries
  end

  sig { returns(Integer) }
  def local_entry_count
    @bindings.length
  end

  sig { returns(Integer) }
  def visible_entry_count
    count_visible_entries!(Set.new)
  end

  sig { params(seen: T::Set[String]).returns(Integer) }
  def count_visible_entries!(seen)
    count = @parent&.count_visible_entries!(seen) || 0
    @bindings.keys.each do |name|
      next if seen.include?(name)

      seen << name
      count += 1
    end
    count
  end

  sig { returns(T::Hash[String, SymbolEntry]) }
  def visible_entries
    inherited = @parent ? @parent.visible_entries : {}
    inherited.merge(@bindings.entries)
  end

  sig { returns(T::Array[String]) }
  def visible_names
    names = T.let([], T::Array[String])
    seen = T.let(Set.new, T::Set[String])
    append_visible_names!(names, seen)
    names
  end

  sig { params(names: T::Array[String], seen: T::Set[String]).void }
  def append_visible_names!(names, seen)
    @parent&.append_visible_names!(names, seen)
    @bindings.keys.each do |name|
      next if seen.include?(name)

      seen << name
      names << name
    end
    nil
  end

  sig { returns(T::Array[[String, SymbolEntry]]) }
  def owned_entries
    @owned_names.filter_map do |name|
      entry = @bindings[name]
      entry ? [name, entry] : nil
    end
  end

  # Returns a Type carrying the variable's base type plus storage-derived capabilities.
  sig { params(name: String).returns(Type) }
  def resolve_full_type(name)
    entry = resolve_entry(name)
    return Type.new(:Any) if entry.nil?

    base_type = entry.type

    value_sync = if entry.locked?
      :locked
    elsif entry.write_locked?
      :write_locked
    end
    base_type.apply_symbol_overlay!(
      storage: entry.storage,
      entry_sync: entry.sync,
      entry_layout: entry.layout,
      value_sync: value_sync,
      link_source: entry.link_source,
      atomic_ptr: entry.atomic_ptr?
    )

    base_type
  end

  sig { params(name: String).returns(Type) }
  def resolve_type(name)
    entry = resolve_entry(name)
    entry ? entry.type : Type.new(:Any)
  end

  sig { params(name: String).returns(T::Boolean) }
  def is_mutable?(name)
    entry = resolve_entry(name)
    entry ? entry.mutable : true
  end

  sig { params(name: String).returns(T::Boolean) }
  def is_immutable?(name)
    !is_mutable?(name)
  end

  sig { params(name: String).returns(T::Boolean) }
  def is_restricted?(name)
    !!resolve_entry(name)&.capabilities&.include?(:RESTRICT)
  end

  # Mark a variable as read (used as an r-value in user code).
  sig { params(name: String).returns(T.untyped) }
  def mark_read(name)
    entry = entry_for_write(name)
    return unless entry
    entry.mark_read!
  end

  # Returns the new SymbolEntry on success, nil if the binding wasn't found
  # in the cap's old_scope (caller is responsible for emitting a diagnostic).
  sig { params(capability: AST::Capability).returns(T.nilable(SymbolEntry)) }
  def declare_with_new_capability(capability)
    name = capability[:var_node].name
    local = capability[:old_scope].resolve_entry(name)
    return nil if local.nil?
    local = local.dup
    local.capabilities = local.capabilities.dup
    # Whole-variable or field restriction: add capability marker.
    # Borrow conflict detection is handled by the OwnershipGraph.
    local.capabilities << capability[:capability]
    local.scope = self
    @bindings[name] = local
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
    entry = resolve_entry(name)
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
      return scope if scope.entry?(name)
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
    if scope.entry?(name)
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
      names.concat(scope.types.keys.map(&:to_s))
    end
    names.uniq
  end

  sig { params(scope: T.nilable(Scope), blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def with_new_scope(scope = nil, &blk)
    new_scope = scope.nil? ? Scope.new : scope.dup
    # Root scope keeps depth 0; each `with_new_scope` nest increases depth by
    # one so declarations can record their lifetime boundary.
    new_scope.depth = scope_stack.size
    scope_stack.push(new_scope)
    blk.call
  ensure
    scope_stack.pop
  end

end
