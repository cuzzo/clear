# typed: strict
require "sorbet-runtime"
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
# Slot identifiers:
#   [:param, fn_name, index]  — a function parameter typed Auto
#   [:return, fn_name]        — a function return typed Auto
#   [:local, ast_node_id]     — a BindExpr/VarDecl typed Auto (object_id
#                                of the decl node disambiguates locals
#                                that share a name across scopes)
#
# See docs/agents/gradual-typing.md §4.1 for the constraint-collection
# specification.
class AutoConstraintCollector
    extend T::Sig

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
  Slot = Struct.new(:kind, :fn_name, :index, :decl_node, :sources, :shape, :auto_token, keyword_init: true)

  sig { params(fn_nodes: T::Hash[String, T.untyped]).void }
  def initialize(fn_nodes)
    # fn_nodes: { name => AST::FunctionDef }, exactly as the existing
    # annotator's signature-collection pass produces.
    @fn_nodes = fn_nodes
    @slots = T.let({}, T::Hash[T.untyped, T.untyped])
    # Per-function map of `local_name → slot_id`, threaded through
    # the walk via @local_decls (saved/restored on FunctionDef entry).
    # Lets MUTABLE-local reassignments — `BindExpr(name="x", type=nil)`
    # appearing AFTER an `x: Auto = ...` decl — attach to the original
    # slot. Without this, only the initializer would constrain the
    # slot and re-binding ambiguity (`MUTABLE x: Auto = 0_i64; x =
    # "hello";`) would slip through unification.
    @local_decls = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
  end

  # Walk the program. Populates @slots with one entry per Auto slot
  # and accumulates source-node lists. Returns @slots so callers can
  # inspect / pass directly to the unifier.
  sig { params(program_node: AST::Program).returns(T::Hash[T::Array[T.untyped], AutoConstraintCollector::Slot]) }
  def collect!(program_node)
    register_signature_slots
    walk(program_node, current_fn: nil)
    @slots
  end

  private

  # Phase 1: scan every FunctionDef in @fn_nodes and register slots
  # for each Auto-typed param / return. Locals are registered lazily
  # during the walk because they live inside bodies.
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def register_signature_slots
    @fn_nodes.each do |name, fn|
      (fn.params || []).each_with_index do |param, i|
        next unless auto?(param.type)
        @slots[[:param, name, i]] = Slot.new(
          kind: :param, fn_name: name, index: i,
          decl_node: fn, sources: [],
          auto_token: param.type.auto_token,
        )
      end
      if auto?(fn.return_type)
        @slots[[:return, name]] = Slot.new(
          kind: :return, fn_name: name, index: nil,
          decl_node: fn, sources: [],
          auto_token: fn.return_type.auto_token,
        )
      end
    end
  end

  sig { params(t: T.nilable(Type)).returns(T::Boolean) }
  def auto?(t)
    t.is_a?(Type) && t.auto?
  end

  # Generic AST traversal. Tracks the enclosing FunctionDef so
  # AST::ReturnNode constraints attach to the right slot. On
  # FunctionDef entry, resets @local_decls (per-function map of
  # local-name → slot-id) so reassignments only match decls in the
  # same function body.
  sig { params(node: T.untyped, current_fn: T.nilable(AST::FunctionDef)).returns(T.untyped) }
  def walk(node, current_fn:)
    return if node.nil?
    case node
    when Symbol, String, Numeric, TrueClass, FalseClass, Type
      # leaf
    when Array
      node.each { |c| walk(c, current_fn: current_fn) }
    when Hash
      node.each_value { |v| walk(v, current_fn: current_fn) }
    else
      record_constraint(node, current_fn)
      next_fn = node.is_a?(AST::FunctionDef) ? node : current_fn
      saved_local_decls = nil
      if node.is_a?(AST::FunctionDef)
        saved_local_decls = @local_decls
        @local_decls = {}
      end
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| walk(v, current_fn: next_fn) }
      end
      @local_decls = saved_local_decls if node.is_a?(AST::FunctionDef)
    end
  end

  # Per-node-type constraint recording. Each branch corresponds to
  # one of the constraint sources from §4.1 of the spec.
  sig { params(node: T.untyped, current_fn: T.nilable(AST::FunctionDef)).returns(T.nilable(T::Array[T.untyped])) }
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
  sig { params(call_node: AST::FuncCall).returns(T.nilable(T::Array[T.untyped])) }
  def record_call_site(call_node)
    callee = @fn_nodes[call_node.name]
    return unless callee
    (callee.params || []).each_with_index do |param, i|
      next unless auto?(param.type)
      arg = call_node.args && call_node.args[i]
      next unless arg
      slot = @slots[[:param, callee.name, i]]
      slot.sources << arg if slot
    end
  end

  # Return Auto ← RETURN expr type. Only attaches the source when
  # the enclosing function actually has an Auto return — a RETURN
  # inside a non-Auto-return function is a regular type-checked stmt.
  sig { params(return_node: AST::ReturnNode, current_fn: AST::FunctionDef).returns(T.nilable(T::Array[T.untyped])) }
  def record_return(return_node, current_fn)
    return unless current_fn && auto?(current_fn.return_type)
    return unless return_node.value
    slot = @slots[[:return, current_fn.name]]
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
  sig { params(decl_node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
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

      slot_id = [:local, decl_node.object_id]
      @slots[slot_id] ||= Slot.new(
        kind: :local, fn_name: nil, index: nil,
        decl_node: decl_node, sources: [], shape: nil,
        auto_token: decl_node.type.auto_token,
      )
      @slots[slot_id].sources << decl_node.value if decl_node.value
      # Remember this name so later reassignments can find the slot.
      @local_decls[decl_node.name] = slot_id if @local_decls
    elsif decl_node.type.nil? && @local_decls && decl_node.respond_to?(:name)
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
  sig { params(entry: T.untyped, rhs: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def record_reassignment_sources(entry, rhs)
    return unless rhs

    if entry.is_a?(Hash) && entry[:key] && entry[:value]
      # Map shape pair. Only HashLit RHSes contribute structured
      # evidence; arbitrary expressions get skipped (we can't see
      # inside them at this layer).
      return unless rhs.is_a?(AST::HashLit)
      key_slot = @slots[entry[:key]]
      val_slot = @slots[entry[:value]]
      rhs.pairs.each do |k, v|
        key_slot.sources << k if key_slot && k
        val_slot.sources << v if val_slot && v
      end
      return
    end

    slot = @slots[entry]
    return unless slot

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
  sig { params(node: T.untyped).returns(T::Boolean) }
  def empty_list_lit?(node)
    node.is_a?(AST::ListLit) && node.items.empty? &&
      !node.instance_variable_get(:@constructor_collection)
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Boolean)) }
  def empty_hash_lit?(node)
    node.is_a?(AST::HashLit) && node.pairs.empty?
  end

  sig { params(decl_node: T.untyped).void }
  def register_list_shape_slot(decl_node)
    slot_id = [:list_element, decl_node.object_id]
    @slots[slot_id] ||= Slot.new(
      kind: :local, fn_name: nil, index: nil,
      decl_node: decl_node, sources: [], shape: :list_element,
      auto_token: decl_node.type.auto_token,
    )
    @local_decls[decl_node.name] = slot_id if @local_decls
  end

  sig { params(decl_node: T.untyped).void }
  def register_map_shape_slots(decl_node)
    key_id = [:map_key, decl_node.object_id]
    val_id = [:map_value, decl_node.object_id]
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
    @local_decls[decl_node.name] = { key: key_id, value: val_id } if @local_decls
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

  # Aggregated unifier output. Each map keys by the same slot id
  # used in @slots: resolved → Resolution, ambiguous → Ambiguity,
  # unresolved → the original Slot (no observations gathered).
  Result = Struct.new(:resolved, :ambiguous, :unresolved, keyword_init: true)

  # A successfully resolved slot — exactly one observed concrete
  # type. The fix-emission helpers read `slot` (label / token) and
  # `type` (the source form to write into the user's code).
  Resolution = Struct.new(:slot, :type, :sources, keyword_init: true)

  # A slot with two-or-more incompatible observations. The
  # diagnostic builder reads `observed_types` to enumerate options
  # and `sources` to attribute each observation to its callsite.
  Ambiguity  = Struct.new(:slot, :observed_types, :sources, keyword_init: true)

  sig { params(slots: T::Hash[T::Array[T.untyped], AutoConstraintCollector::Slot], type_of: T.nilable(Proc)).void }
  def initialize(slots, type_of: nil)
    @slots = slots
    # `type_of` lets callers plug in a custom source-type resolver.
    # Default reads `node.full_type` (CLEAR's existing per-node type
    # accessor — set by the annotator on AST nodes during body
    # validation). The tolerant body-pass populates type_info on each
    # constraint source before this unifier runs.
    @type_of = T.let(type_of || ->(node) {
      node.respond_to?(:full_type) ? node.full_type : nil
    }, T.untyped)
  end

  sig { returns(AutoUnifier::Result) }
  def resolve!
    resolved   = {}
    ambiguous  = {}

    progress = T.let(true, T::Boolean)
    while progress
      progress = false
      @slots.each do |id, slot|
        next if resolved.key?(id) || ambiguous.key?(id)

        observed = collect_observed_types(slot)
        case observed.length
        when 1
          type = observed.first
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

    unresolved = {}
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
  sig { params(slot: AutoConstraintCollector::Slot).returns(T::Array[T.untyped]) }
  def collect_observed_types(slot)
    seen = []
    slot.sources.each do |source|
      t = @type_of.call(source)
      next if t.nil?
      next if t.respond_to?(:auto?) && t.auto?
      t = widen_byte_array_to_string(t)
      next if seen.any? { |existing| types_equal?(existing, t) }
      seen << t
    end
    seen
  end

  sig { params(t: Type).returns(T.untyped) }
  def widen_byte_array_to_string(t)
    sym = t.respond_to?(:resolved) ? t.resolved : t
    return :String if sym.is_a?(Symbol) && sym.to_s.start_with?("Byte[") && sym.to_s.end_with?("]")
    t
  end

  # Type comparison that handles bare symbols and Type objects.
  # The annotator sometimes stores `:Int64` and sometimes `Type.new(:Int64)`;
  # for unification purposes we treat them as the same observation.
  sig { params(a: T.untyped, b: T.untyped).returns(T::Boolean) }
  def types_equal?(a, b)
    return true if a == b
    return false unless a.respond_to?(:resolved) || b.respond_to?(:resolved)
    a_sym = a.respond_to?(:resolved) ? a.resolved : a
    b_sym = b.respond_to?(:resolved) ? b.resolved : b
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
  sig { params(slot: AutoConstraintCollector::Slot, type: T.untyped).returns(T.nilable(Type)) }
  def stamp_slot!(slot, type)
    resolved_type = type.is_a?(Type) ? type : Type.new(type)
    case slot.shape
    when :list_element
      element_sym = resolved_type.respond_to?(:resolved) ? resolved_type.resolved : resolved_type
      slot.decl_node.type = Type.new(:"#{element_sym}[]")
      return
    when :map_key, :map_value
      # Defer: stamp_map_pairs! below builds the joint HashMap<K,V>
      # type once both sub-slots resolve. Record the resolved scalar
      # on the slot for the post-pass to read.
      slot.instance_variable_set(:@resolved_scalar, resolved_type)
      return
    end

    case slot.kind
    when :param
      slot.decl_node.params[slot.index][:type] = resolved_type
    when :return
      slot.decl_node.return_type = resolved_type
    when :local
      slot.decl_node.type = resolved_type
    end
  end

  public

  # Reads the @resolved_scalar stamps left by stamp_slot! for
  # `:map_key` / `:map_value` shape slots. When both halves of a
  # decl_node are resolved, builds `HashMap<K, V>` and stamps the
  # decl. Returns the list of decl_nodes whose stamping is
  # incomplete (only one half resolved) — the caller emits per-slot
  # unresolved findings for those.
  sig { params(resolved_slots: T::Hash[T::Array[T.untyped], AutoUnifier::Resolution]).returns(T::Hash[Integer, T::Hash[T.untyped, T.untyped]]) }
  def stamp_map_pairs!(resolved_slots)
    by_decl = Hash.new { |h, k| h[k] = {} }
    resolved_slots.each_value do |resolution|
      next unless resolution.slot.shape == :map_key || resolution.slot.shape == :map_value
      by_decl[resolution.slot.decl_node.object_id][resolution.slot.shape] = resolution
    end

    by_decl.each do |_decl_id, pair|
      key_res = pair[:map_key]
      val_res = pair[:map_value]
      next unless key_res && val_res
      decl = key_res.slot.decl_node
      k_sym = key_res.type.respond_to?(:resolved) ? key_res.type.resolved : key_res.type
      v_sym = val_res.type.respond_to?(:resolved) ? val_res.type.resolved : val_res.type
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

  sig { params(slots: T::Hash[T::Array[T.untyped], AutoConstraintCollector::Slot], fn_nodes: T::Hash[String, T.untyped]).void }
  def initialize(slots, fn_nodes)
    @slots = slots
    @fn_nodes = fn_nodes
  end

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def collect!
    @fn_nodes.each_value { |fn| collect_in_function(fn) }
    @slots
  end

  private

  # Build a per-function map from binding-name to the slot triple
  # `{ list: slot, key: slot, value: slot }`. Only includes shape
  # slots whose decl_node lives inside this function body.
  sig { params(fn: AST::FunctionDef).returns(T.nilable(T::Array[T.untyped])) }
  def collect_in_function(fn)
    name_map = build_name_map(fn)
    return if name_map.empty?
    walk(fn.body, name_map)
  end

  # Walk body for shape-bearing decls and map their name → shape slots.
  sig { params(fn: AST::FunctionDef).returns(T::Hash[String, T::Hash[T.untyped, T.untyped]]) }
  def build_name_map(fn)
    map = {}
    walk_for_shape_decls(fn.body) do |decl|
      list_slot = @slots[[:list_element, decl.object_id]]
      key_slot  = @slots[[:map_key, decl.object_id]]
      val_slot  = @slots[[:map_value, decl.object_id]]
      next unless list_slot || key_slot || val_slot
      map[decl.name] = { list: list_slot, key: key_slot, value: val_slot }
    end
    map
  end

  sig { params(node: T.untyped, block: T.untyped).returns(T.untyped) }
  def walk_for_shape_decls(node, &block)
    return if node.nil?
    case node
    when AST::BindExpr, AST::VarDecl
      yield node if node.type&.auto?
      walk_for_shape_decls(node.value, &block)
    when AST::FunctionDef
      # Don't recurse into nested function definitions.
    when Array
      node.each { |c| walk_for_shape_decls(c, &block) }
    when Hash
      node.each_value { |v| walk_for_shape_decls(v, &block) }
    else
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| walk_for_shape_decls(v, &block) }
      end
    end
  end

  # Walk the body and record evidence into shape slots.
  sig { params(node: T.untyped, name_map: T::Hash[String, T::Hash[T.untyped, T.untyped]]).returns(T.untyped) }
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
    when Array
      node.each { |c| walk(c, name_map) }
    when Hash
      node.each_value { |v| walk(v, name_map) }
    else
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| walk(v, name_map) }
      end
    end
  end

  # Detect `x.append(e)` / `x.insert(e)` / `x.put(k, v)` and record
  # the corresponding evidence onto the shape slots for `x`.
  sig { params(call: AST::MethodCall, name_map: T::Hash[T.untyped, T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def record_method_call(call, name_map)
    target = call.object
    return unless target.is_a?(AST::Identifier)
    slots = name_map[target.name]
    return unless slots
    args = call.args || []

    case call.name.to_s
    when "append", "push", "insert"
      # List-append: 1-arg form is element evidence. Pool/Set
      # `insert(e)` also fits this shape. Pool/Map `insert(k,v)`
      # 2-arg form delivers map-pair evidence.
      if slots[:list] && args.length == 1
        slots[:list].sources << args[0]
      elsif args.length == 2
        record_map_pair_evidence(slots, args)
      end
    when "put"
      # HashMap put(k, v) — key + value evidence.
      record_map_pair_evidence(slots, args) if args.length == 2
    end
  end

  # Append (k, v) to the matching map sub-slots when the slot map
  # carries both halves. No-op for non-map shapes — keeps
  # method-call dispatch noise out of the call sites.
  sig { params(slots: T::Hash[T.untyped, T.untyped], args: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def record_map_pair_evidence(slots, args)
    return unless slots[:key] && slots[:value]
    slots[:key].sources << args[0]
    slots[:value].sources << args[1]
  end

  # Detect `x[i] = v`. For list shape: v is element evidence. For
  # map shape: i is key, v is value.
  sig { params(assign: AST::Assignment, name_map: T::Hash[T.untyped, T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def record_index_assign(assign, name_map)
    target = assign.name
    return unless target.is_a?(AST::GetIndex)
    base = target.target
    return unless base.is_a?(AST::Identifier)
    slots = name_map[base.name]
    return unless slots

    if slots[:list]
      slots[:list].sources << assign.value
    elsif slots[:key] && slots[:value]
      slots[:key].sources << target.index
      slots[:value].sources << assign.value
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

  sig { params(slots: T::Hash[T::Array[T.untyped], AutoConstraintCollector::Slot], fn_nodes: T::Hash[String, T.untyped]).void }
  def initialize(slots, fn_nodes)
    @slots = slots
    @fn_nodes = fn_nodes
    @evidence = T.let(Hash.new { |h, k| h[k] = Set.new }, T::Hash[T.untyped, T.untyped])
  end

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def collect!
    @fn_nodes.each_value { |fn| collect_in_function(fn) }
    @evidence
  end

  private

  sig { params(fn: AST::FunctionDef).returns(T::Array[T.untyped]) }
  def collect_in_function(fn)
    name_to_slot = build_name_map(fn)
    walk_binops(fn.body, name_to_slot, fn)
  end

  # Map from binding-name → slot-id within this function. Includes
  # Auto-typed params (registered by AutoConstraintCollector under
  # [:param, fn_name, i]) and Auto-typed locals (registered under
  # [:local, decl_node.object_id]).
  sig { params(fn: AST::FunctionDef).returns(T::Hash[String, T::Array[T.untyped]]) }
  def build_name_map(fn)
    map = {}
    (fn.params || []).each_with_index do |param, i|
      slot_id = [:param, fn.name, i]
      map[param.name] = slot_id if @slots.key?(slot_id)
    end
    walk_for_local_decls(fn.body) do |decl|
      slot_id = [:local, decl.object_id]
      map[decl.name] = slot_id if @slots.key?(slot_id)
    end
    map
  end

  # Walk for Auto-typed BindExpr / VarDecl, yielding each one.
  sig { params(node: T.untyped, block: T.untyped).returns(T.untyped) }
  def walk_for_local_decls(node, &block)
    return if node.nil?
    case node
    when AST::BindExpr, AST::VarDecl
      yield node if auto?(node.type)
      walk_for_local_decls(node.value, &block)
    when AST::FunctionDef
      # Don't recurse into nested function definitions.
    when Array
      node.each { |c| walk_for_local_decls(c, &block) }
    when Hash
      node.each_value { |v| walk_for_local_decls(v, &block) }
    else
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| walk_for_local_decls(v, &block) }
      end
    end
  end

  # Walk for BinaryOp expressions; record `op` per slot whose
  # binding appears as an Identifier operand. Returns also recorded
  # for return-Auto when the RETURN value is a BinaryOp.
  sig { params(node: T.untyped, name_to_slot: T::Hash[String, T::Array[T.untyped]], fn: AST::FunctionDef).returns(T.untyped) }
  def walk_binops(node, name_to_slot, fn)
    return if node.nil?
    case node
    when AST::BinaryOp
      record_binop(node, name_to_slot)
      walk_binops(node.left, name_to_slot, fn)
      walk_binops(node.right, name_to_slot, fn)
    when AST::ReturnNode
      ret_slot = [:return, fn.name]
      if @slots.key?(ret_slot) && node.value.is_a?(AST::BinaryOp)
        @evidence[ret_slot] << node.value.op
      end
      walk_binops(node.value, name_to_slot, fn)
    when AST::FunctionDef
      # Don't recurse into nested function definitions.
    when Array
      node.each { |c| walk_binops(c, name_to_slot, fn) }
    when Hash
      node.each_value { |v| walk_binops(v, name_to_slot, fn) }
    else
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| walk_binops(v, name_to_slot, fn) }
      end
    end
  end

  sig { params(binop: AST::BinaryOp, name_to_slot: T::Hash[String, T::Array[T.untyped]]).returns(T::Array[T.untyped]) }
  def record_binop(binop, name_to_slot)
    [binop.left, binop.right].each do |operand|
      next unless operand.is_a?(AST::Identifier)
      slot_id = name_to_slot[operand.name]
      @evidence[slot_id] << binop.op if slot_id
    end
  end

  sig { params(t: T.nilable(Type)).returns(T::Boolean) }
  def auto?(t)
    t.is_a?(Type) && t.auto?
  end
end
