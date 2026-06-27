# typed: strict
require "sorbet-runtime"
require_relative "../../ast/ast"

AutoInferenceWalkNode = T.type_alias do
  T.nilable(T.any(
    AST::Node,
    AST::RawBody,
    T::Hash[BasicObject, BasicObject],
    Struct,
    T::Struct,
    SymbolEntry,
    Symbol,
    String,
    Numeric,
    TrueClass,
    FalseClass,
    Lexer::Token,
    Type,
  ))
end
AutoInferenceDeclBlock = T.type_alias { T.proc.params(decl: T.any(AST::BindExpr, AST::VarDecl)).void }

class AutoSlotId
    extend T::Sig

  sig { returns(Symbol) }
  attr_reader :kind
  sig { returns(T.nilable(String)) }
  attr_reader :fn_name
  sig { returns(T.nilable(Integer)) }
  attr_reader :index
  sig { returns(T.nilable(Integer)) }
  attr_reader :decl_id

  sig do
    params(
      kind: Symbol,
      fn_name: T.nilable(String),
      index: T.nilable(Integer),
      decl_id: T.nilable(Integer),
    ).void
  end
  def initialize(kind:, fn_name: nil, index: nil, decl_id: nil)
    @kind = T.let(kind, Symbol)
    @fn_name = T.let(fn_name, T.nilable(String))
    @index = T.let(index, T.nilable(Integer))
    @decl_id = T.let(decl_id, T.nilable(Integer))
  end

  sig { params(fn_name: String, index: Integer).returns(AutoSlotId) }
  def self.param(fn_name, index)
    new(kind: :param, fn_name: fn_name, index: index)
  end

  sig { params(fn_name: String).returns(AutoSlotId) }
  def self.return(fn_name)
    new(kind: :return, fn_name: fn_name)
  end

  sig { params(decl_node: AST::Locatable).returns(AutoSlotId) }
  def self.local(decl_node)
    new(kind: :local, decl_id: decl_node.object_id)
  end

  sig { params(decl_node: AST::Locatable).returns(AutoSlotId) }
  def self.list_element(decl_node)
    new(kind: :list_element, decl_id: decl_node.object_id)
  end

  sig { params(decl_node: AST::Locatable).returns(AutoSlotId) }
  def self.map_key(decl_node)
    new(kind: :map_key, decl_id: decl_node.object_id)
  end

  sig { params(decl_node: AST::Locatable).returns(AutoSlotId) }
  def self.map_value(decl_node)
    new(kind: :map_value, decl_id: decl_node.object_id)
  end

  sig { returns(Integer) }
  def hash
    [@kind, @fn_name, @index, @decl_id].hash
  end

  sig { params(other: AutoSlotId).returns(T::Boolean) }
  def eql?(other)
    return false unless other.is_a?(AutoSlotId)
    @kind == other.kind &&
      @fn_name == other.fn_name &&
      @index == other.index &&
      @decl_id == other.decl_id
  end

  alias == eql?
end

class AutoMapShapeEntry
    extend T::Sig

  sig { returns(AutoSlotId) }
  attr_reader :key
  sig { returns(AutoSlotId) }
  attr_reader :value

  sig { params(key: AutoSlotId, value: AutoSlotId).void }
  def initialize(key:, value:)
    @key = T.let(key, AutoSlotId)
    @value = T.let(value, AutoSlotId)
  end
end

# Auto inference — Pass B (constraint collection).
#
# Given a parsed program and the @fn_nodes registry produced by
# Pass A, walks the AST and accumulates the set of "constraint source"
# AST nodes for every Auto slot in the program. The unifier reads each
# slot's source list, computes types, and resolves the slot to a single
# concrete type — or routes ambiguity / unresolved cases to the
# fix-emission helpers.
#
# This pass is intentionally lightweight: it does not type-check, does
# not invoke the annotator, and never triggers user-visible errors.
# It just records "expression X is what would have to flow into slot
# Y" so the unifier can decide.
#
# Slot identifiers are AutoSlotId objects:
#   AutoSlotId.param(fn_name, index) — a function parameter typed Auto
#   AutoSlotId.return(fn_name)       — a function return typed Auto
#   AutoSlotId.local(decl_node)      — a BindExpr/VarDecl typed Auto
#
# See docs/agents/gradual-typing.md §4.1 for the constraint-collection
# specification.
class AutoConstraintCollector
    extend T::Sig

  DeclarationNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr) }
  SlotDeclNode = T.type_alias { T.any(AST::FunctionDef, DeclarationNode) }
  ObservedType = T.type_alias { T.any(Type, Symbol) }
  SlotMap = T.type_alias { T::Hash[AutoSlotId, AutoConstraintCollector::Slot] }
  LocalDeclEntry = T.type_alias { T.any(AutoSlotId, AutoMapShapeEntry) }

  # `shape`: nil for scalar slots; for empty `[]` / `{}` initializers, one
  # of `:list_element`, `:map_key`, `:map_value`.
  # Shape slots carry no initializer source — their evidence comes
  # from forward-flow uses (`x.append(e)`, `x[k] = v`) collected by
  # ShapeEvidenceCollector. The unifier resolves them like scalar
  # slots; stamp_slot! wraps the resolved type into a list / map
  # type before stamping the decl.
  #
  # `auto_token`: cached pointer to the original Auto keyword token.
  # `stamp_slot!` overwrites `decl_node.type` with
  # the resolved Type, which loses the auto_token attached to the
  # original Auto Type. Callers that need the source span for the
  # `clear fix` edit (the fixable-helpers' `auto_token_for`) read
  # this cached copy.
  class Slot < T::Struct
    const :kind, Symbol
    const :fn_name, T.nilable(String), default: nil
    const :index, T.nilable(Integer), default: nil
    const :decl_node, SlotDeclNode
    const :sources, T::Array[AST::Locatable]
    const :shape, T.nilable(Symbol), default: nil
    const :auto_token, T.nilable(Lexer::Token), default: nil
    prop :resolved_scalar, T.nilable(Type), default: nil
  end

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }

  sig { params(fn_nodes: FnNodes).void }
  def initialize(fn_nodes)
    # fn_nodes: { name => AST::FunctionDef }, exactly as the existing
    # annotator's signature-collection pass produces.
    @fn_nodes = T.let(fn_nodes, FnNodes)
    @slots = T.let({}, SlotMap)
    # Per-function map of `local_name → slot_id`, threaded through
    # the walk via @local_decls (saved/restored on FunctionDef entry).
    # Lets MUTABLE-local reassignments — `BindExpr(name="x", type=nil)`
    # appearing AFTER an `x: Auto = ...` decl — attach to the original
    # slot. Without this, only the initializer would constrain the
    # slot and re-binding ambiguity (`MUTABLE x: Auto = 0_i64; x =
    # "hello";`) would slip through unification.
    @local_decls = T.let({}, T::Hash[String, LocalDeclEntry])
  end

  # Walk the program. Populates @slots with one entry per Auto slot
  # and accumulates source-node lists. Returns @slots so callers can
  # inspect / pass directly to the unifier.
  sig { params(program_node: AST::Program).returns(SlotMap) }
  def collect!(program_node)
    register_signature_slots
    walk(program_node, current_fn: nil)
    @slots
  end

  private

  # Phase 1: scan every FunctionDef in @fn_nodes and register slots
  # for each Auto-typed param / return. Locals are registered lazily
  # during the walk because they live inside bodies.
  sig { returns(SlotMap) }
  def register_signature_slots
    @fn_nodes.each do |name, fn|
      fn.params.each_with_index do |param, i|
        next unless auto?(param.type)
        @slots[AutoSlotId.param(name, i)] = Slot.new(
          kind: :param, fn_name: name, index: i,
          decl_node: fn, sources: [],
          auto_token: param.type.auto_token,
        )
      end
      if auto?(fn.return_type)
        @slots[AutoSlotId.return(name)] = Slot.new(
          kind: :return, fn_name: name, index: nil,
          decl_node: fn, sources: [],
          auto_token: fn.return_type.auto_token,
        )
      end
    end
    @slots
  end

  sig { params(t: T.nilable(Type)).returns(T::Boolean) }
  def auto?(t)
    !!t&.auto?
  end

  # Generic AST traversal. Tracks the enclosing FunctionDef so
  # AST::ReturnNode constraints attach to the right slot. On
  # FunctionDef entry, resets @local_decls (per-function map of
  # local-name → slot-id) so reassignments only match decls in the
  # same function body.
  sig { params(node: AutoInferenceWalkNode, current_fn: T.nilable(AST::FunctionDef)).void }
  def walk(node, current_fn:)
    return if node.nil?
    case node
    when Symbol, String, Numeric, TrueClass, FalseClass, Lexer::Token, Type, SymbolEntry
      # leaf
    when Array
      node.each { |c| walk(c, current_fn: current_fn) }
    when Hash
      node.each_value { |v| walk(v, current_fn: current_fn) }
    else
      record_constraint(node, current_fn)
      next_fn = node.is_a?(AST::FunctionDef) ? node : current_fn
      saved_local_decls = T.let({}, T::Hash[String, LocalDeclEntry])
      if node.is_a?(AST::FunctionDef)
        saved_local_decls = @local_decls
        @local_decls = {}
      end
      if node.respond_to?(:each_pair)
        T.unsafe(node).each_pair { |_, v| walk(v, current_fn: next_fn) }
      end
      @local_decls = saved_local_decls if node.is_a?(AST::FunctionDef)
    end
  end

  # Per-node-type constraint recording. Each branch corresponds to
  # one of the constraint sources from §4.1 of the spec.
  sig { params(node: AutoInferenceWalkNode, current_fn: T.nilable(AST::FunctionDef)).void }
  def record_constraint(node, current_fn)
    case node
    when AST::FuncCall
      record_call_site(node)
    when AST::ReturnNode
      record_return(node, T.must(current_fn))
    when AST::BindExpr, AST::VarDecl
      record_local(node)
    end
  end

  # Param Auto ← call-site arg type. The arg AST node is the
  # constraint source; the unifier reads its eventual type_info.
  sig { params(call_node: AST::FuncCall).void }
  def record_call_site(call_node)
    callee = @fn_nodes[call_node.name]
    return unless callee
    callee.params.each_with_index do |param, i|
      next unless auto?(param.type)
      arg = call_node.args && call_node.args[i]
      next unless arg
      slot = @slots[AutoSlotId.param(callee.name, i)]
      slot.sources << arg if slot
    end
  end

  # Return Auto ← RETURN expr type. Only attaches the source when
  # the enclosing function actually has an Auto return — a RETURN
  # inside a non-Auto-return function is a regular type-checked stmt.
  sig { params(return_node: AST::ReturnNode, current_fn: AST::FunctionDef).void }
  def record_return(return_node, current_fn)
    return unless current_fn && auto?(current_fn.return_type)
    return unless return_node.value
    slot = @slots[AutoSlotId.return(current_fn.name)]
    slot.sources << return_node.value if slot
  end

  # Local Auto ← initializer + later reassignment RHS.
  #
  # Two cases:
  #
  #   1. Explicit Auto declaration (`x: Auto = init` or
  #      `MUTABLE x: Auto = init`). Register a fresh slot keyed by
  #      the decl-node's object_id. Record the initializer as a
  #      source. Remember the binding name in @local_decls so later
  #      same-named reassignments find this slot.
  #
  #   2. Reassignment to an earlier Auto local (`x = new_val`,
  #      type=nil). The parser produces `BindExpr(name="x",
  #      type=nil, value=new_val)` for this. Attach the new value
  #      as another constraint source on the SAME slot — ambiguity
  #      flows out of the unifier when types disagree.
  sig { params(decl_node: DeclarationNode).void }
  def record_local(decl_node)
    if auto?(decl_node.type)
      # Empty container literals need shape-tagged slots because `Any[]` /
      # `HashMap<Any>` would be meaningless evidence. Forward-flow use sites
      # provide the real element/key/value observations.
      if empty_list_lit?(decl_node.value)
        register_list_shape_slot(decl_node)
        return
      elsif empty_hash_lit?(decl_node.value)
        register_map_shape_slots(decl_node)
        return
      end

      slot_id = AutoSlotId.local(decl_node)
      @slots[slot_id] ||= Slot.new(
        kind: :local, fn_name: nil, index: nil,
        decl_node: decl_node, sources: [], shape: nil,
        auto_token: decl_node.type.auto_token,
      )
      T.must(@slots[slot_id]).sources << T.cast(decl_node.value, AST::Locatable) if decl_node.value
      # Remember this name so later reassignments can find the slot.
      @local_decls[decl_node.name] = slot_id
    elsif decl_node.type.nil? && decl_node.respond_to?(:name)
      # Untyped BindExpr — possibly a reassignment of an earlier
      # Auto local in the same function. If we recognize the name,
      # extend the existing slot with this RHS.
      entry = @local_decls[decl_node.name]
      return unless entry
      record_reassignment_sources(entry, decl_node.value)
    end
  end

  # Reassignment of an Auto-tracked binding. `entry` is what
  # `@local_decls[name]` stores: either a slot_id (scalar /
  # list-shape) or a `{ key: id, value: id }` hash for a map shape
  # pair. Routes the RHS to the right sources list:
  #   - scalar slot: append the whole RHS node.
  #   - :list_element: append each list literal item as evidence.
  #   - map shape: append each pair's key/value to the matching slots.
  sig { params(entry: LocalDeclEntry, rhs: T.nilable(AST::Locatable)).void }
  def record_reassignment_sources(entry, rhs)
    return unless rhs

    if entry.is_a?(AutoMapShapeEntry)
      # Map shape pair. Only HashLit RHSes contribute structured
      # evidence; arbitrary expressions get skipped (we can't see
      # inside them at this layer).
      return unless rhs.is_a?(AST::HashLit)
      key_slot = T.must(@slots[entry.key])
      val_slot = T.must(@slots[entry.value])
      rhs.pairs.each do |k, v|
        key_slot.sources << k
        val_slot.sources << v
      end
      return
    end

    slot = T.must(@slots[entry])

    case slot.shape
    when :list_element
      # Non-empty list literal contributes one element-type
      # observation per item. Other RHS shapes (function calls,
      # variables) are opaque here — leave the slot to the
      # forward-flow evidence collector.
      if rhs.is_a?(AST::ListLit) && !rhs.items.empty?
        rhs.items.each { |item| slot.sources << item }
      end
    when nil
      # Plain scalar slot — record the whole RHS.
      slot.sources << rhs
    end
  end

  # Recognize `[]` (no items, no constructor metadata). A literal
  # like `Pool[]` sets `@constructor_collection`, which means the
  # user picked a specific collection — don't reinterpret as Auto.
  sig { params(node: T.nilable(AST::Locatable)).returns(T::Boolean) }
  def empty_list_lit?(node)
    node.is_a?(AST::ListLit) && node.items.empty? &&
      !node.instance_variable_get(:@constructor_collection)
  end

  sig { params(node: T.nilable(AST::Locatable)).returns(T::Boolean) }
  def empty_hash_lit?(node)
    node.is_a?(AST::HashLit) && node.pairs.empty?
  end

  sig { params(decl_node: DeclarationNode).void }
  def register_list_shape_slot(decl_node)
    slot_id = AutoSlotId.list_element(decl_node)
    @slots[slot_id] ||= Slot.new(
      kind: :local, fn_name: nil, index: nil,
      decl_node: decl_node, sources: [], shape: :list_element,
      auto_token: decl_node.type.auto_token,
    )
    @local_decls[decl_node.name] = slot_id
  end

  sig { params(decl_node: DeclarationNode).void }
  def register_map_shape_slots(decl_node)
    key_id = AutoSlotId.map_key(decl_node)
    val_id = AutoSlotId.map_value(decl_node)
    auto_tok = decl_node.type.auto_token
    @slots[key_id] ||= Slot.new(
      kind: :local, fn_name: nil, index: nil,
      decl_node: decl_node, sources: [], shape: :map_key,
      auto_token: auto_tok,
    )
    @slots[val_id] ||= Slot.new(
      kind: :local, fn_name: nil, index: nil,
      decl_node: decl_node, sources: [], shape: :map_value,
      auto_token: auto_tok,
    )
    # Register the binding name with both shape slot ids so later
    # reassignments can deliver evidence to both halves.
    @local_decls[decl_node.name] = AutoMapShapeEntry.new(key: key_id, value: val_id)
  end
end

class AutoShapeSlots
    extend T::Sig

  sig { returns(T.nilable(AutoConstraintCollector::Slot)) }
  attr_reader :list
  sig { returns(T.nilable(AutoConstraintCollector::Slot)) }
  attr_reader :key
  sig { returns(T.nilable(AutoConstraintCollector::Slot)) }
  attr_reader :value

  sig do
    params(
      list: T.nilable(AutoConstraintCollector::Slot),
      key: T.nilable(AutoConstraintCollector::Slot),
      value: T.nilable(AutoConstraintCollector::Slot),
    ).void
  end
  def initialize(list:, key:, value:)
    @list = list
    @key = key
    @value = value
  end
end

# Auto inference — Pass C (unification + resolution).
#
# Reads the slot map produced by AutoConstraintCollector (Pass B) and
# resolves each slot to a single concrete type. Three outcomes per
# slot, mirroring §4.3 of the spec:
#
#   * Exactly one observed type → resolved. The slot's decl-node has
#     its `type` / `return_type` field replaced with the resolved
#     concrete Type, so Pass D body validation sees normal types.
#   * Zero observed types        → unresolved (cannot infer; user picks).
#   * Two or more observed types → ambiguous (§6 ranked options).
#
# Iterates to fixpoint. Round 1 resolves slots whose source types are
# already concrete (e.g., a param Auto called only with literals).
# Round 2+ picks up slots whose sources became typeable once their
# upstream Auto dependencies resolved.
#
# The unifier itself does NOT emit diagnostics. It produces a
# structured Result that fix emission consumes and turns into FixableFindings
# with the appropriate ranked options.
class AutoUnifier
    extend T::Sig

  # A successfully resolved slot — exactly one observed concrete
  # type. The fix-emission helpers read `slot` (label / token) and
  # `type` (the source form to write into the user's code).
  class Resolution < T::Struct
    const :slot, AutoConstraintCollector::Slot
    const :type, AutoConstraintCollector::ObservedType
    const :sources, T::Array[AST::Locatable]
  end

  # A slot with two-or-more incompatible observations. The
  # diagnostic builder reads `observed_types` to enumerate options
  # and `sources` to attribute each observation to its callsite.
  class Ambiguity < T::Struct
    const :slot, AutoConstraintCollector::Slot
    const :observed_types, T::Array[AutoConstraintCollector::ObservedType]
    const :sources, T::Array[AST::Locatable]
  end

  class MapPairResolution
      extend T::Sig

    sig { returns(T.nilable(AutoUnifier::Resolution)) }
    attr_accessor :key
    sig { returns(T.nilable(AutoUnifier::Resolution)) }
    attr_accessor :value

    sig { void }
    def initialize
      @key = T.let(nil, T.nilable(AutoUnifier::Resolution))
      @value = T.let(nil, T.nilable(AutoUnifier::Resolution))
    end
  end

  ResultMap = T.type_alias { T::Hash[AutoSlotId, AutoUnifier::Resolution] }
  AmbiguityMap = T.type_alias { T::Hash[AutoSlotId, AutoUnifier::Ambiguity] }
  UnresolvedMap = T.type_alias { T::Hash[AutoSlotId, AutoConstraintCollector::Slot] }
  TypeResolver = T.type_alias do
    T.proc.params(node: AST::Locatable).returns(T.nilable(AutoConstraintCollector::ObservedType))
  end

  # Aggregated unifier output. Each map keys by the same slot id
  # used in @slots: resolved → Resolution, ambiguous → Ambiguity,
  # unresolved → the original Slot (no observations gathered).
  class Result < T::Struct
    const :resolved, AutoUnifier::ResultMap
    const :ambiguous, AutoUnifier::AmbiguityMap
    const :unresolved, AutoUnifier::UnresolvedMap
  end

  sig { params(slots: AutoConstraintCollector::SlotMap, type_of: T.nilable(TypeResolver)).void }
  def initialize(slots, type_of: nil)
    @slots = T.let(slots, AutoConstraintCollector::SlotMap)
    # `type_of` lets callers plug in a custom source-type resolver.
    # Default reads the finalized per-node type. The tolerant body-pass
    # populates type_info on each constraint source before this unifier runs.
    @type_of = T.let(type_of || ->(node) { node.full_type!(context: "AUTO inference source") }, TypeResolver)
  end

  sig { returns(AutoUnifier::Result) }
  def resolve!
    resolved   = T.let({}, ResultMap)
    ambiguous  = T.let({}, AmbiguityMap)

    progress = T.let(true, T::Boolean)
    while progress
      progress = false
      @slots.each do |id, slot|
        next if resolved.key?(id) || ambiguous.key?(id)

        observed = collect_observed_types(slot)
        case observed.length
        when 1
          type = T.must(observed.first)
          stamp_slot!(slot, type)
          resolved[id] = Resolution.new(slot: slot, type: type, sources: slot.sources)
          progress = true
        when 0
          # Defer: maybe a later round resolves a dependency that
          # makes a source typeable. Only finalize as unresolved
          # AFTER fixpoint.
        else
          ambiguous[id] = Ambiguity.new(
            slot: slot, observed_types: observed, sources: slot.sources,
          )
          progress = true
        end
      end
    end

    unresolved = T.let({}, UnresolvedMap)
    @slots.each do |id, slot|
      next if resolved.key?(id) || ambiguous.key?(id)
      unresolved[id] = slot
    end

    Result.new(resolved: resolved, ambiguous: ambiguous, unresolved: unresolved)
  end

  private

  # Walks a slot's source AST nodes, asks @type_of for each one's
  # current type, and returns the deduped list of concrete types
  # observed. Auto / nil sources are skipped — they may become
  # typeable in a later round (or stay nil and lead to an
  # unresolved diagnostic at fixpoint).
  #
  # `Byte[N]` (the type of a string literal like `"hello"` → `Byte[5]`)
  # is widened to `String` for all slots. Without widening, diagnostics report
  # `Byte[5]` (confusing) and resolved container types come out as
  # `HashMap<Byte[1], V>` (unfit for use). The user almost always
  # means `String` when they pass / store a string literal; widening
  # converts the diagnostic to the type they actually want.
  sig { params(slot: AutoConstraintCollector::Slot).returns(T::Array[AutoConstraintCollector::ObservedType]) }
  def collect_observed_types(slot)
    seen = T.let([], T::Array[AutoConstraintCollector::ObservedType])
    slot.sources.each do |source|
      t = @type_of.call(source)
      next if t.nil?
      next if t.is_a?(Type) && t.auto?
      t = widen_byte_array_to_string(t)
      next if seen.any? { |existing| types_equal?(existing, t) }
      seen << t
    end
    seen
  end

  sig { params(t: AutoConstraintCollector::ObservedType).returns(AutoConstraintCollector::ObservedType) }
  def widen_byte_array_to_string(t)
    sym = t.is_a?(Type) ? t.resolved : t
    return :String if sym.is_a?(Symbol) && sym.to_s.start_with?("Byte[") && sym.to_s.end_with?("]")
    t
  end

  # Type comparison that handles bare symbols and Type objects.
  # The annotator sometimes stores `:Int64` and sometimes `Type.new(:Int64)`;
  # for unification purposes we treat them as the same observation.
  sig { params(a: AutoConstraintCollector::ObservedType, b: AutoConstraintCollector::ObservedType).returns(T::Boolean) }
  def types_equal?(a, b)
    return true if a == b
    return false unless a.is_a?(Type) || b.is_a?(Type)
    a_sym = a.is_a?(Type) ? a.resolved : a
    b_sym = b.is_a?(Type) ? b.resolved : b
    a_sym == b_sym
  end

  # Replace the Auto Type sentinel on the decl with the resolved
  # concrete type so downstream consumers (Pass D body validation,
  # MIR lowering) see ordinary types. Wrap raw symbols in Type.new
  # so the decl always carries a Type object.
  #
  # Shape-tagged slots wrap the resolved scalar before stamping.
  # `:list_element T` → `T[]`. `:map_key` and
  # `:map_value` are stamped jointly by the post-pass below; this
  # method records the resolution on the slot and leaves the decl
  # untouched until both sub-slots resolve.
  sig { params(slot: AutoConstraintCollector::Slot, type: AutoConstraintCollector::ObservedType).void }
  def stamp_slot!(slot, type)
    resolved_type = type.is_a?(Type) ? type : Type.new(type)
    case slot.shape
    when :list_element
      element_sym = resolved_type.resolved
      T.cast(slot.decl_node, AutoConstraintCollector::DeclarationNode).type = Type.new(:"#{element_sym}[]")
      return
    when :map_key, :map_value
      # Defer: stamp_map_pairs! below builds the joint HashMap<K,V>
      # type once both sub-slots resolve. Record the resolved scalar
      # on the slot for the post-pass to read.
      slot.resolved_scalar = resolved_type
      return
    end

    case slot.kind
    when :param
      fn = T.cast(slot.decl_node, AST::FunctionDef)
      fn.params[T.must(slot.index)][:type] = resolved_type
    when :return
      T.cast(slot.decl_node, AST::FunctionDef).return_type = resolved_type
    when :local
      T.cast(slot.decl_node, AutoConstraintCollector::DeclarationNode).type = resolved_type
    end
  end

  public

  # Reads the @resolved_scalar stamps left by stamp_slot! for
  # `:map_key` / `:map_value` shape slots. When both halves of a
  # decl_node are resolved, builds `HashMap<K, V>` and stamps the
  # decl. Returns the list of decl_nodes whose stamping is
  # incomplete (only one half resolved) — the caller emits per-slot
  # unresolved findings for those.
  sig { params(resolved_slots: ResultMap).void }
  def stamp_map_pairs!(resolved_slots)
    by_decl = T.let(
      Hash.new { |h, k| h[k] = MapPairResolution.new },
      T::Hash[Integer, MapPairResolution],
    )
    resolved_slots.each_value do |resolution|
      next unless resolution.slot.shape == :map_key || resolution.slot.shape == :map_value
      pair = T.must(by_decl[resolution.slot.decl_node.object_id])
      if resolution.slot.shape == :map_key
        pair.key = resolution
      else
        pair.value = resolution
      end
    end

    by_decl.each do |_decl_id, pair|
      key_res = pair.key
      val_res = pair.value
      next unless key_res && val_res
      decl = T.cast(key_res.slot.decl_node, AutoConstraintCollector::DeclarationNode)
      key_type = key_res.type
      val_type = val_res.type
      k_sym = key_type.is_a?(Type) ? key_type.resolved : key_type
      v_sym = val_type.is_a?(Type) ? val_type.resolved : val_type
      decl.type = Type.new(:"HashMap<#{k_sym}, #{v_sym}>")
    end
  end
end

# Forward-flow evidence collector for shape-tagged Auto slots.
#
# Empty container literals (`x: Auto = []`, `m: Auto = {}`) carry
# no element-type information at the declaration site. Constraint
# evidence comes from later uses:
#
#   `xs.append(e)`            → element type observation (e)
#   `xs[i] = e`               → element type observation (e)
#   `m[k] = v`                → key=k, value=v observations
#   `m.put(k, v)`             → key=k, value=v observations
#
# This walker scans each function body, finds the binding-name to
# shape-slot mapping, and appends source AST nodes to the
# corresponding slot's `sources` list. The unifier then resolves
# them like any other slot.
class ShapeEvidenceCollector
    extend T::Sig

  NameShapeMap = T.type_alias { T::Hash[String, AutoShapeSlots] }

  sig { params(slots: AutoConstraintCollector::SlotMap, fn_nodes: AutoConstraintCollector::FnNodes).void }
  def initialize(slots, fn_nodes)
    @slots = T.let(slots, AutoConstraintCollector::SlotMap)
    @fn_nodes = T.let(fn_nodes, AutoConstraintCollector::FnNodes)
  end

  sig { returns(AutoConstraintCollector::SlotMap) }
  def collect!
    @fn_nodes.each_value { |fn| collect_in_function(fn) }
    @slots
  end

  private

  # Build a per-function map from binding-name to the slot triple
  # `{ list: slot, key: slot, value: slot }`. Only includes shape
  # slots whose decl_node lives inside this function body.
  sig { params(fn: AST::FunctionDef).void }
  def collect_in_function(fn)
    name_map = build_name_map(fn)
    return if name_map.empty?
    walk(fn.body, name_map)
  end

  # Walk body for shape-bearing decls and map their name → shape slots.
  sig { params(fn: AST::FunctionDef).returns(NameShapeMap) }
  def build_name_map(fn)
    map = T.let({}, NameShapeMap)
    walk_for_shape_decls(fn.body) do |decl|
      list_slot = @slots[AutoSlotId.list_element(decl)]
      key_slot  = @slots[AutoSlotId.map_key(decl)]
      val_slot  = @slots[AutoSlotId.map_value(decl)]
      next unless list_slot || key_slot || val_slot
      map[decl.name] = AutoShapeSlots.new(list: list_slot, key: key_slot, value: val_slot)
    end
    map
  end

  sig { params(node: AutoInferenceWalkNode, block: AutoInferenceDeclBlock).void }
  def walk_for_shape_decls(node, &block)
    return if node.nil?
    case node
    when AST::BindExpr, AST::VarDecl
      yield node if node.type&.auto?
      walk_for_shape_decls(node.value, &block)
    when AST::FunctionDef
      # Don't recurse into nested function definitions.
    when Lexer::Token
      # metadata leaf
    when Array
      node.each { |c| walk_for_shape_decls(c, &block) }
    when Hash
      node.each_value { |v| walk_for_shape_decls(v, &block) }
    else
      if node.respond_to?(:each_pair)
        T.unsafe(node).each_pair { |_, v| walk_for_shape_decls(v, &block) }
      end
    end
  end

  # Walk the body and record evidence into shape slots.
  sig { params(node: AutoInferenceWalkNode, name_map: NameShapeMap).void }
  def walk(node, name_map)
    return if node.nil?
    case node
    when AST::MethodCall
      record_method_call(node, name_map)
      walk(node.object, name_map)
      node.args.each { |a| walk(a, name_map) }
    when AST::Assignment
      record_index_assign(node, name_map)
      walk(node.value, name_map)
    when AST::FunctionDef
      # Don't recurse into nested function definitions.
    when Lexer::Token
      # metadata leaf
    when Array
      node.each { |c| walk(c, name_map) }
    when Hash
      node.each_value { |v| walk(v, name_map) }
    else
      if node.respond_to?(:each_pair)
        T.unsafe(node).each_pair { |_, v| walk(v, name_map) }
      end
    end
  end

  # Record collection-shape evidence for mutating stdlib methods. The
  # method classes come from std_lib metadata, not from local method-name
  # switches, so adding a new collection mutator updates inference by
  # updating the registry entry.
  sig { params(call: AST::MethodCall, name_map: NameShapeMap).void }
  def record_method_call(call, name_map)
    target = call.object
    return unless target.is_a?(AST::Identifier)
    slots = name_map[target.name]
    return unless slots
    args = call.args || []

    if slots.list && IntrinsicRegistry.collection_element_evidence_method?(call.name, args.length)
      T.must(slots.list).sources << args[0]
    elsif IntrinsicRegistry.map_pair_evidence_method?(call.name, args.length)
      record_map_pair_evidence(slots, args)
    end
  end

  # Append (k, v) to the matching map sub-slots when the slot map
  # carries both halves. No-op for non-map shapes — keeps
  # method-call dispatch noise out of the call sites.
  sig { params(slots: AutoShapeSlots, args: T::Array[T.untyped]).void }
  def record_map_pair_evidence(slots, args)
    return unless slots.key && slots.value
    T.must(slots.key).sources << args[0]
    T.must(slots.value).sources << args[1]
  end

  # Detect `x[i] = v`. For list shape: v is element evidence. For
  # map shape: i is key, v is value.
  sig { params(assign: AST::Assignment, name_map: NameShapeMap).void }
  def record_index_assign(assign, name_map)
    target = assign.name
    return unless target.is_a?(AST::GetIndex)
    base = target.target
    return unless base.is_a?(AST::Identifier)
    slots = name_map[base.name]
    return unless slots

    if slots.list
      T.must(slots.list).sources << assign.value
    elsif slots.key && slots.value
      T.must(slots.key).sources << target.index
      T.must(slots.value).sources << assign.value
    end
  end
end

# Operator-aware evidence collector.
#
# When a slot is unresolvable from constraint sources alone (e.g., a
# function never called, or a return-Auto whose body uses an Auto
# param so the return expression's type also collapses to Auto), the
# body's *operator usage* still gives us strong type hints. This collector
# walks BinaryOp expressions in each function body and accumulates a
# `Set<op>` of operators applied to operands referencing each slot's
# binding. The fix-emission helpers read this evidence and rank candidate
# concrete types per the OPERATOR_CANDIDATES table.
#
# This is a **separate** pass from AutoConstraintCollector so it can
# run independently of constraint resolution — the operator evidence
# is useful even when the slot has no other observations.
#
# Output: { slot_id => Set<op_symbol> }
class OperatorEvidenceCollector
    extend T::Sig

  NameSlotMap = T.type_alias { T::Hash[String, AutoSlotId] }
  EvidenceMap = T.type_alias { T::Hash[AutoSlotId, T::Set[Symbol]] }

  sig { params(slots: AutoConstraintCollector::SlotMap, fn_nodes: AutoConstraintCollector::FnNodes).void }
  def initialize(slots, fn_nodes)
    @slots = T.let(slots, AutoConstraintCollector::SlotMap)
    @fn_nodes = T.let(fn_nodes, AutoConstraintCollector::FnNodes)
    @evidence = T.let(Hash.new { |h, k| h[k] = Set.new }, EvidenceMap)
  end

  sig { returns(EvidenceMap) }
  def collect!
    @fn_nodes.each_value { |fn| collect_in_function(fn) }
    @evidence
  end

  private

  sig { params(fn: AST::FunctionDef).void }
  def collect_in_function(fn)
    name_to_slot = build_name_map(fn)
    walk_binops(fn.body, name_to_slot, fn)
  end

  # Map from binding-name → slot-id within this function. Includes
  # Auto-typed params and locals registered by AutoConstraintCollector
  # under AutoSlotId keys.
  sig { params(fn: AST::FunctionDef).returns(NameSlotMap) }
  def build_name_map(fn)
    map = T.let({}, NameSlotMap)
    fn.params.each_with_index do |param, i|
      slot_id = AutoSlotId.param(fn.name, i)
      map[param.name] = slot_id if @slots.key?(slot_id)
    end
    walk_for_local_decls(fn.body) do |decl|
      slot_id = AutoSlotId.local(decl)
      map[decl.name] = slot_id if @slots.key?(slot_id)
    end
    map
  end

  # Walk for Auto-typed BindExpr / VarDecl, yielding each one.
  sig { params(node: AutoInferenceWalkNode, block: AutoInferenceDeclBlock).void }
  def walk_for_local_decls(node, &block)
    return if node.nil?
    case node
    when AST::BindExpr, AST::VarDecl
      yield node if auto?(node.type)
      walk_for_local_decls(node.value, &block)
    when AST::FunctionDef
      # Don't recurse into nested function definitions.
    when Lexer::Token
      # metadata leaf
    when Array
      node.each { |c| walk_for_local_decls(c, &block) }
    when Hash
      node.each_value { |v| walk_for_local_decls(v, &block) }
    else
      if node.respond_to?(:each_pair)
        T.unsafe(node).each_pair { |_, v| walk_for_local_decls(v, &block) }
      end
    end
  end

  # Walk for BinaryOp expressions; record `op` per slot whose
  # binding appears as an Identifier operand. Returns also recorded
  # for return-Auto when the RETURN value is a BinaryOp.
  sig { params(node: AutoInferenceWalkNode, name_to_slot: NameSlotMap, fn: AST::FunctionDef).void }
  def walk_binops(node, name_to_slot, fn)
    return if node.nil?
    case node
    when AST::BinaryOp
      record_binop(node, name_to_slot)
      walk_binops(node.left, name_to_slot, fn)
      walk_binops(node.right, name_to_slot, fn)
    when AST::ReturnNode
      ret_slot = AutoSlotId.return(fn.name)
      if @slots.key?(ret_slot) && node.value.is_a?(AST::BinaryOp)
        (@evidence[ret_slot] ||= Set.new) << node.value.op
      end
      walk_binops(node.value, name_to_slot, fn)
    when AST::FunctionDef
      # Don't recurse into nested function definitions.
    when Lexer::Token
      # metadata leaf
    when Array
      node.each { |c| walk_binops(c, name_to_slot, fn) }
    when Hash
      node.each_value { |v| walk_binops(v, name_to_slot, fn) }
    else
      if node.respond_to?(:each_pair)
        T.unsafe(node).each_pair { |_, v| walk_binops(v, name_to_slot, fn) }
      end
    end
  end

  sig { params(binop: AST::BinaryOp, name_to_slot: NameSlotMap).void }
  def record_binop(binop, name_to_slot)
    [binop.left, binop.right].each do |operand|
      next unless operand.is_a?(AST::Identifier)
      slot_id = name_to_slot[operand.name]
      (@evidence[slot_id] ||= Set.new) << binop.op if slot_id
    end
  end

  sig { params(t: T.nilable(Type)).returns(T::Boolean) }
  def auto?(t)
    !!t&.auto?
  end
end
