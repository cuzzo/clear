# typed: strict
require "sorbet-runtime"

require_relative "cleanup_entry"
require_relative "../ast/type"
require_relative "../ast/symbol_entry"
require_relative "../annotator/helpers/function_signature"
require_relative "local_binding_facts"

# =========================================================================
# Pass C (caller side): Cleanup Classification
#
# Classifies each variable binding's cleanup requirements. Pure analysis -
# no code emission. MIRPass consumes the result to insert MIR::Drop nodes
# and stamp AST nodes.
#
# Per-binding entry:
#   needs_cleanup:  true/false       - whether a defer is emitted
#   alloc:          :heap/:frame     - which allocator
#   kind:           symbol           - drives Zig template selection
#   has_moved_guard: true/false      - whether var X_moved = false is emitted
#
# Data sources (all from annotator, no re-inference):
#   - type_info (cleanup_alloc, collection?, map?, etc.)
#   - node.container_borrow (set by register_container_borrow!)
#   - node.resource_close_zig (set by annotator)
#   - fn_node.params (TAKES params, via walk_takes_params)
#   - MatchStatement cases with bindings + was_moved
#   - union/struct schemas (for non-Copy checks)
# =========================================================================
module CleanupClassifier
    extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }

  # Classify all bindings in a function that need cleanup.
  #
  # @param fn_node [AST::FunctionDef]
  # @param fn_nodes [Hash] name => FunctionDef for all functions
  # @param schema_lookup [Proc] lambda(type_sym) => schema hash
  # @return [Hash] { var_name => entry_hash } or empty hash
  sig { params(fn_node: AST::FunctionDef, fn_nodes: FnNodes, schema_lookup: Proc).returns(T::Hash[String, CleanupEntry]) }
  def self.classify(fn_node, fn_nodes:, schema_lookup:)
    return {} unless fn_node.body

    promoted_fns = compute_promoted_fns(fn_nodes)
    bindings = {}

    # 1. Walk all VarDecl/BindExpr in the function body.
    walk_bindings(fn_node.body, promoted_fns, schema_lookup, bindings)

    # 2. TAKES parameters from fn_node.params.
    walk_takes_params(fn_node, schema_lookup, bindings)

    # 2b. Any binding consumed by GIVE/TAKES/NEXT/COLLECT-style analysis
    # needs a moved guard so lowering can suppress exactly that cleanup.
    walk_moved_source_guards(fn_node.body, bindings)

    # 3. MATCH AS bindings (non-Copy payloads need cleanup with _moved guard).
    walk_match_as_bindings(fn_node.body, schema_lookup, bindings)

    # 4. WHILE-bind / IF-bind captures from ownership-transferring call results.
    walk_capture_bindings(fn_node.body, promoted_fns, schema_lookup, bindings)

    prune_container_borrow_bindings(fn_node.body, bindings)
    stamp_cleanup_scopes!(fn_node.body, bindings)

    bindings
  end

  sig { params(body: T::Array[T.untyped], bindings: T::Hash[String, CleanupEntry]).void }
  private_class_method def self.prune_container_borrow_bindings(body, bindings)
    AST.each_locatable(body) do |node|
      next unless (node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)) && binding_container_borrow?(node)

      bindings.delete(node.name.to_s)
      node.mir_binding_entry = nil if node.respond_to?(:mir_binding_entry=)
    end
    nil
  end

  sig { params(body: T::Array[T.untyped], bindings: T::Hash[String, CleanupEntry]).void }
  private_class_method def self.walk_moved_source_guards(body, bindings)
    AST.each_locatable(body) do |node|
      next unless node.is_a?(AST::Identifier)
      next unless AST.moved?(node)
      entry = bindings[node.name.to_s]
      entry[:has_moved_guard] = true if entry&.present?
    end
  end

  sig { params(body: T::Array[T.untyped], bindings: T::Hash[String, CleanupEntry]).void }
  private_class_method def self.stamp_cleanup_scopes!(body, bindings)
    stamp_default_scopes!(body, loop_depth: 0)
    stamp_extended_loop_lifetimes!(body, bindings)
  end

  sig { params(body: T::Array[T.untyped], loop_depth: Integer).void }
  private_class_method def self.stamp_default_scopes!(body, loop_depth:)
    body.each do |node|
      stamp_binding_default_scope!(node, loop_depth)
      child_depth = AST.loop_node?(node) ? loop_depth + 1 : loop_depth
      AST.child_bodies(node).each { |child_body| stamp_default_scopes!(child_body, loop_depth: child_depth) }
    end
  end

  sig { params(node: T.untyped, loop_depth: Integer).void }
  private_class_method def self.stamp_binding_default_scope!(node, loop_depth)
    return unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
    return if node.is_a?(AST::BindExpr) && node.mode == :assign
    entry = node.respond_to?(:mir_binding_entry) ? node.mir_binding_entry : nil
    return unless entry&.present?
    entry[:scope] = if entry.alloc == :heap
                      :heap
                    elsif loop_depth.positive?
                      :iteration
                    else
                      :function
                    end
  end

  sig { params(body: T::Array[T.untyped], bindings: T::Hash[String, CleanupEntry]).void }
  private_class_method def self.stamp_extended_loop_lifetimes!(body, bindings)
    body.each do |node|
      AST.child_bodies(node).each do |child_body|
        stamp_loop_extensions!(child_body, bindings) if AST.loop_node?(node)
        stamp_extended_loop_lifetimes!(child_body, bindings)
      end
    end
  end

  sig { params(body: T::Array[T.untyped], bindings: T::Hash[String, CleanupEntry]).void }
  private_class_method def self.stamp_loop_extensions!(body, bindings)
    local_facts = MIR::LocalBindingAnalysis.direct_loop_body_facts(body)
    local_names = local_facts.names
    local_entries = local_facts.entries
    MIR::LocalBindingAnalysis.each_direct_loop_node(body) do |node|
      case node
      when AST::BindExpr
        next unless node.mode == :assign
        next if local_names.include?(node.name.to_s)
        entry = bindings[node.name.to_s]
        promote_entry_to_heap_cleanup!(entry, node.value) if entry&.present? && value_extends_loop?(node.value)
      when AST::Assignment
        target = AST.root_identifier(node.name)
        next if target&.name && local_names.include?(target.name.to_s)
        mark_iteration_values_function!(node.value, local_entries)
      when AST::FuncCall
        mark_call_lifetime_extensions!(node.args, params_for_call(node), local_entries, nil)
      when AST::MethodCall
        receiver = AST.root_identifier(node.object)
        receiver_nonlocal = !!(receiver&.name && !local_names.include?(receiver.name.to_s))
        mark_call_lifetime_extensions!(node.args, params_for_method_call(node).drop(1), local_entries, receiver_nonlocal)
      end
    end
  end

  sig { params(value: T.untyped).returns(T::Boolean) }
  private_class_method def self.value_extends_loop?(value)
    Type.from_node!(value, context: "cleanup lifetime extension").heap_ptr?
  end

  sig { params(entry_obj: CleanupEntry, value: T.untyped).void }
  private_class_method def self.promote_entry_to_heap_cleanup!(entry_obj, value)
    ti = Type.from_node!(value, context: "cleanup lifetime promotion")
    entry_obj[:needs_cleanup] = true
    entry_obj[:alloc] = :heap
    entry_obj[:scope] = :heap
    entry_obj[:kind] = ti.string? ? :heap_string : :uniform
    entry_obj[:has_moved_guard] = true
  end

  sig { params(args: T::Array[T.untyped], params: T::Array[AST::Param], local_entries: T::Hash[String, CleanupEntry], receiver_nonlocal: T.nilable(T::Boolean)).void }
  private_class_method def self.mark_call_lifetime_extensions!(args, params, local_entries, receiver_nonlocal)
    return unless receiver_nonlocal
    params.each_with_index do |param, idx|
      next unless param.takes || param.mutable
      arg = args[idx]
      mark_iteration_values_function!(arg, local_entries) if arg
    end
  end

  sig { params(expr: T.untyped, local_entries: T::Hash[String, CleanupEntry]).void }
  private_class_method def self.mark_iteration_values_function!(expr, local_entries)
    ident = AST.root_identifier(expr) rescue nil
    return unless ident

    entry = local_entries[ident.name.to_s]
    return unless entry&.present?

    entry[:scope] = :function if entry.alloc == :frame && entry.scope == :iteration
  end

  sig { params(call: AST::FuncCall).returns(T::Array[AST::Param]) }
  private_class_method def self.params_for_call(call)
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    sig ? sig.params : []
  end

  sig { params(call: AST::MethodCall).returns(T::Array[AST::Param]) }
  private_class_method def self.params_for_method_call(call)
    sig = call.respond_to?(:matched_signature) ? FunctionSignature.unwrap(call.matched_signature) : nil
    sig ? sig.params : []
  end

  # Walk field assignments that need pre-cleanup (free old value before overwrite).
  # Stamps Assignment.field_pre_cleanup with the allocator Symbol (:heap or :frame).
  sig { params(body: T::Array[T.untyped], bindings: T::Hash[String, CleanupEntry], schema_lookup: T.nilable(Proc)).void }
  def self.stamp_field_pre_cleanups!(body, bindings, schema_lookup: nil)
    AST.walk_body(body) do |stmt|
      next unless stmt.is_a?(AST::Assignment)
      next unless stmt.name.is_a?(AST::GetField)
      target_node = stmt.name.target

      field_ti = Type.from_node!(stmt.name, context: "field pre-cleanup")
      field_needs_cleanup =
        field_ti.needs_cleanup?(schema_lookup) ||
        field_ti.recursive_cleanup_shape?(schema_lookup)

      # Auto-lock string fields: locked/always_mutable structs heap-dupe
      # string fields, so overwriting needs explicit free of the old value.
      if !field_needs_cleanup && stmt.auto_lock && field_ti.string?
        stmt.field_pre_cleanup = :heap
        next
      end

      heap_field_alloc = heap_owned_field_pre_cleanup_alloc(field_ti, target_node, bindings)
      if !field_needs_cleanup && heap_field_alloc
        stmt.field_pre_cleanup = heap_field_alloc
        next
      end

      next unless field_needs_cleanup

      stmt.field_pre_cleanup = field_owner_cleanup_alloc(target_node, bindings)
    end
  end

  sig { params(field_ti: Type, target_node: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(Symbol)) }
  private_class_method def self.heap_owned_field_pre_cleanup_alloc(field_ti, target_node, bindings)
    return nil unless field_ti.string?
    field_owner_cleanup_alloc(target_node, bindings) == :heap ? :heap : nil
  end

  sig { params(target_node: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(Symbol) }
  private_class_method def self.field_owner_cleanup_alloc(target_node, bindings)
    return :frame unless target_node.is_a?(AST::Identifier)

    target_entry = bindings[target_node.name.to_s]
    target_entry&.alloc == :heap ? :heap : :frame
  end

  # ── Promoted function detection ──────────────────────────────────

  sig { params(fn_nodes: FnNodes).returns(T::Set[String]) }
  private_class_method def self.compute_promoted_fns(fn_nodes)
    promoted = Set.new

    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      fn_nodes.each do |name, fn|
        next if promoted.include?(name)
        next unless fn.body
        if body_calls_promoted?(fn.body, promoted)
          promoted << name
          changed = T.let(true, T::Boolean)
        end
      end
    end
    promoted
  end

  sig { params(body: T::Array[T.untyped], promoted: T::Set[String]).returns(T::Boolean) }
  private_class_method def self.body_calls_promoted?(body, promoted)
    found = T.let(false, T::Boolean)
    AST.walk_body(body) do |node|
      if node.is_a?(AST::ReturnNode) && node.value.is_a?(AST::FuncCall) && promoted.include?(node.value.name)
        found = true
      end
    end
    found
  end

  # ── Walk VarDecl / BindExpr ──────────────────────────────────────

  sig { params(body: T::Array[T.untyped], promoted_fns: T::Set[String], schema_lookup: Proc, bindings: T::Hash[String, CleanupEntry]).returns(T::Array[T.untyped]) }
  private_class_method def self.walk_bindings(body, promoted_fns, schema_lookup, bindings)
    classify_in_body = ->(b) {
      AST.each_locatable(b) do |node|
        next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
        next if node.is_a?(AST::BindExpr) && node.mode == :assign

        var_name = node.name.is_a?(String) ? node.name : node.name.to_s
        moved_alloc = moved_payload_alloc(node.respond_to?(:value) ? node.value : nil, bindings)
        cleanup = classify_binding(var_name, node.full_type!, node, promoted_fns, schema_lookup)
        cleanup ||= transferred_payload_entry(node.full_type!, schema_lookup) if moved_alloc
        if !cleanup && node.respond_to?(:symbol) && node.symbol&.heap_storage? &&
            !optional_empty_initializer?(node.respond_to?(:value) ? node.value : nil)
          ti = node.full_type!
          cleanup = entry(:uniform, alloc: :heap) if ti.needs_explicit_cleanup?(:heap, schema_lookup)
        end
        if cleanup
          cleanup[:alloc] = moved_alloc if moved_alloc
        else
          cleanup = no_cleanup_alloc_entry(node.full_type!, schema_lookup)
        end
        # Stamp on node for identity-based lookup in lower_var_decl (avoids
        # same-name collisions when two vars share a name in different scopes).
        node.mir_binding_entry = cleanup if cleanup
        bindings[var_name] = cleanup if cleanup
      end
    }
    classify_in_body.call(body)
    # AST.walk_body recurses into statement-position HasBodies but not into
    # expression-position BG blocks (`x = BG STREAM { ... }`). AST.each_bg_block
    # is the canonical "every BG fiber reachable from this body" walker; its
    # body is exactly the set of additional cleanup-bearing scopes we must
    # classify.
    AST.each_bg_block(body) { |bg| classify_in_body.call(bg.body) if bg.body }
    bindings.values
  end

  sig { params(full_type: T.untyped, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.no_cleanup_alloc_entry(full_type, schema_lookup)
    ti = full_type.is_a?(Type) ? full_type : Type.new(full_type)
    return nil unless ti.heap_ptr? || ti.collection_value?
    alloc = ti.cleanup_allocator(schema_lookup)
    CleanupEntry.no_cleanup(alloc: alloc, scope: alloc == :heap ? :heap : :function)
  rescue
    nil
  end

  sig { params(node: T.untyped, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(Symbol)) }
  private_class_method def self.moved_payload_alloc(node, bindings)
    return nil unless ownership_transfer_payload?(node)
    names = []
    collect_payload_binding_names(node, names)
    allocs = names.filter_map do |name|
      entry = bindings[name]
      entry&.needs_cleanup? ? entry.alloc : nil
    end
    return nil if allocs.empty?
    allocs.include?(:heap) ? :heap : :frame
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  private_class_method def self.ownership_transfer_payload?(node)
    return false unless node
    return true if node.is_a?(AST::MoveNode)
    return true if AST.moved?(node)
    AST.wrapped_children(node).any? { |child| ownership_transfer_payload?(child) }
  end

  sig { params(node: T.untyped, names: T::Array[String]).void }
  private_class_method def self.collect_payload_binding_names(node, names)
    if node.is_a?(AST::Identifier)
      names << node.name.to_s
      return
    end
    AST.wrapped_children(node).each { |child| collect_payload_binding_names(child, names) }
  end

  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.transferred_payload_entry(ti, schema_lookup)
    takes_param_base_entry(ti, schema_lookup)
  end

  # ── Walk TAKES parameters ───────────────────────────────────────

  # TAKES params get the SAME cleanup recipe a local of the same type would
  # get — there is one source of truth for "what does cleanup look like for
  # this type?" (the entry/classify_* helpers below). This implements
  # CLAUDE.md INV-14: cleanup contracts are inherited, never synthesized at
  # the destination via a parallel dispatch table.
  #
  # Three TAKES-specific overrides on top of the base recipe:
  #   1. has_moved_guard: true    — MATCH AS / re-consumption inside the fn
  #                                  body always requires a moved guard.
  #   2. alloc: :heap             — INV-1 commits the callee to heap-freeing;
  #                                  the caller must supply heap-owned values
  #                                  (enforced by EscapeAnalysis condition 8
  #                                  for cross-fn GIVE/TAKES).
  #   3. via_pointer: true        — needs_pointer_passing? types (HashMap,
  #                                  Pool) arrive at the callee already as
  #                                  *T; cleanup must NOT re-apply &.
  sig { params(fn_node: AST::FunctionDef, schema_lookup: Proc, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(T::Array[CleanupEntry])) }
  private_class_method def self.walk_takes_params(fn_node, schema_lookup, bindings)
    fn_node.params.select { |p| p.takes }.each do |p|
      ti = p.type || Type.new(:Any)
      name = p.name.to_s

      base = takes_param_base_entry(ti, schema_lookup)
      next unless base

      base[:has_moved_guard] = true
      base[:alloc] = :heap
      base[:source_kind] ||= :takes_param
      base[:via_pointer] = true if ti.respond_to?(:needs_pointer_passing?) && ti.needs_pointer_passing?
      bindings[name] = base
    end
  end

  # Build the base cleanup entry for a TAKES param of type ti. Defers to the
  # same per-kind helpers locals use (classify_collection, etc.) so adding a
  # new collection kind requires updating ONE dispatch site, not two.
  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.takes_param_base_entry(ti, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil

    # Schema-driven kinds: resource (close_zig) and union (heap variants).
    if Schemas.resource?(schema)
      return entry(:resource, resource_close_zig: schema.close_zig)
    end
    if Schemas.union?(schema)
      has_heap = union_variants_need_cleanup?(schema, schema_lookup)
      return has_heap ? entry(:takes_union) : nil
    end

    opt = classify_optional(ti, schema_lookup)
    return opt if opt

    return entry(:heap_string) if ti.string?

    # Collection kinds: reuse the locals classifier (covers @list, @pool,
    # @set, @sharded list, HashMap, numeric map, fixed_soa, RC-wrapped maps).
    coll = classify_collection(ti, schema_lookup)
    return coll if coll

    # Plain slice (Int64[] without a collection modifier).
    if ti.direct_indexable_collection?
      elem_zig = ti.element_type ? (Type.new(ti.element_type).zig_type rescue ti.element_type.to_s) : "UNKNOWN"
      return entry(:uniform, elem_zig_type: elem_zig)
    end

    # Struct fallback (strings/collections/rc as fields).
    classify_struct_cleanup_fields(ti, nil, schema_lookup)
  end

  # ── Walk MATCH AS bindings ──────────────────────────────────────

  sig { params(body: T::Array[T.untyped], schema_lookup: Proc, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(T::Array[T.untyped])) }
  private_class_method def self.walk_match_as_bindings(body, schema_lookup, bindings)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::MatchStatement)
      next unless node.takes
      next unless node.expr.is_a?(AST::Identifier) && node.expr.was_moved

      source_ti = node.expr.full_type!
      union_lookup = source_ti.generic_instance? ? source_ti.generic_base : source_ti.resolved
      schema = schema_lookup.call(union_lookup) rescue nil
      next unless Schemas.union?(schema)

      node.cases.each do |c|
        next unless c.binding
        variant_name = case c.value
                       when AST::GetField then c.value.field
                       when AST::MethodCall then c.value.name
                       else nil
                       end
        next unless variant_name

        variant_type = (schema.variants || {})[variant_name]
        next unless variant_type

        e = match_as_entry_for(variant_type, union_lookup, variant_name)
        src_entry = bindings[node.expr.name.to_s]
        e[:alloc] = src_entry.alloc if e && src_entry
        bindings[c.binding] = e if e
      end
    end
  end

  # Single dispatch point for MATCH AS variant cleanup. Returns nil when the
  # variant doesn't need an AS-binding cleanup (unit variants, @indirect
  # pointees, plain non-heap-bearing inline structs).
  sig { params(variant_type: T.untyped, union_lookup: T.untyped, variant_name: T.untyped).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.match_as_entry_for(variant_type, union_lookup, variant_name)
    common = { needs_cleanup: true, alloc: :heap, has_moved_guard: true, match_as: true }
    if Schemas.inline_struct?(variant_type)
      return nil unless Type.variant_has_heap?(variant_type)
      # Inline-struct variant cleanup uses the unified :non_copy_union path
      # (same CheatLib.cleanup emit). match_as: true distinguishes the MATCH
      # AS origin for downstream guards.
      return CleanupEntry.from(common.merge(kind: :uniform))
    end
    return nil if variant_type.is_a?(Type) && variant_type.indirect?

    pt = variant_type.is_a?(Type) ? variant_type : Type.new(variant_type)
    if pt.array? && !pt.string?
      elem_zig = pt.element_type ? (Type.new(pt.element_type).zig_type rescue pt.element_type.to_s) : "UNKNOWN"
      return CleanupEntry.from(common.merge(kind: :uniform, elem_zig_type: elem_zig))
    elsif pt.map?
      return CleanupEntry.from(common.merge(kind: :uniform))
    end
    nil
  end

  # Classify ownership-transferring captures from WHILE-bind / IF-bind nodes.
  # Both shapes carry the same contract: a binding name + an optional-producing
  # expression whose successful capture creates a new owner. Plain
  # variable/field optional access is a borrow and remains the source owner's
  # cleanup responsibility.
  sig { params(body: T::Array[T.untyped], promoted_fns: T::Set[String], schema_lookup: Proc, bindings: T::Hash[String, CleanupEntry]).returns(T.nilable(T::Array[T.untyped])) }
  private_class_method def self.walk_capture_bindings(body, promoted_fns, schema_lookup, bindings)
    each_capture_binding(body) do |name, expr, anchor_node|
      next unless capture_expr_owns_result?(expr)
      expr_ti = Type.from_node!(expr, context: "capture binding")
      inner_ti = expr_ti.wrapped_type
      next unless inner_ti
      e = classify_binding(name, inner_ti, anchor_node, promoted_fns, schema_lookup)
      e ||= entry(:heap_string, has_moved_guard: true) if inner_ti.string?
      e ||= entry(:uniform) if inner_ti.needs_explicit_cleanup?(:heap, schema_lookup)
      next unless e
      e[:alloc] = :heap if capture_expr_heap?(expr, promoted_fns, schema_lookup)
      e[:zig_type] ||= (Type.new(inner_ti.resolved).zig_type rescue inner_ti.resolved.to_s)
      if inner_ti.element_type
        e[:elem_zig_type] ||= (Type.new(inner_ti.element_type).zig_type rescue "UNKNOWN")
      end
      bindings[name] = e
    end
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.capture_expr_owns_result?(expr)
    AST.call?(expr) || expr.is_a?(AST::MethodCall) || expr.is_a?(AST::ResolveNode)
  end

  sig { params(expr: T.untyped, promoted_fns: T::Set[String], schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.capture_expr_heap?(expr, promoted_fns, schema_lookup)
    case expr
    when AST::ResolveNode
      true
    when AST::FuncCall
      return false if call_has_return_lifetime?(expr)
      call_returns_heap_owned?(expr, schema_lookup) ||
        promoted_fns.include?(expr.name.to_s) ||
        (expr.respond_to?(:heap_storage?) && expr.heap_storage?)
    when AST::MethodCall
      return false if call_has_return_lifetime?(expr)
      return true if call_returns_heap_owned?(expr, schema_lookup)
      return true if expr.respond_to?(:heap_storage?) && expr.heap_storage?
      receiver = expr.object
      !!(receiver.respond_to?(:symbol) && receiver.symbol&.heap_storage?)
    else
      false
    end
  end

  sig { params(expr: T.untyped, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.call_returns_heap_owned?(expr, schema_lookup)
    sig = expr.respond_to?(:matched_signature) ? FunctionSignature.unwrap(expr.matched_signature) : nil
    return false unless sig
    return false if sig.respond_to?(:return_lifetime) && !sig.return_lifetime.empty?
    return true if sig.respond_to?(:heap_carry_return) && sig.heap_carry_return == true
    return true if sig.heap_return_alloc?
    return false if sig.frame_return_alloc?
    return false unless sig.respond_to?(:return_type)
    ret = Type.new(sig.return_type)
    ret = ret.success_type || ret
    !!ret && ret.needs_explicit_cleanup?(:heap, schema_lookup)
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  private_class_method def self.call_has_return_lifetime?(expr)
    sig = expr.respond_to?(:matched_signature) ? FunctionSignature.unwrap(expr.matched_signature) : nil
    !!sig && !sig.return_lifetime.empty?
  end

  # Yield (binding_name, expression, anchor_node) for every IF-bind / WHILE-bind
  # capture in body. The anchor is the IfBind / WhileBindLoop node that owns
  # the capture's lifetime.
  sig { params(body: T::Array[T.untyped], block: T.untyped).returns(T.untyped) }
  private_class_method def self.each_capture_binding(body, &block)
    AST.walk_body(body) do |node|
      case node
      when AST::WhileBindLoop
        yield node.binding_name.to_s, node.condition, node
      when AST::IfBind
        node.bindings.each { |b| yield b.name.to_s, b.expr, node }
      end
    end
  end

  # ── classify_binding: dispatch pipeline ─────────────────────────
  #
  # Each classify_* method handles one cleanup category, returning a
  # cleanup entry hash or nil. Order matters: earlier categories take
  # priority (e.g. resource before collection, RC before sync).

  # Dispatch chain: each kind family is checked in priority order, the
  # FIRST matching arm wins. Simple predicate-based kinds (observable,
  # frozen, inf_stream, atomic_ptr, resource, sync, owned_string,
  # non_copy_union) inline here; complex ones (collection, optional,
  # heap_storage, struct_cleanup_fields, rc_or_link, heap_struct_plain,
  # array_struct_strings) stay as separate methods due to their size.
  sig { params(name: String, ti: Type, node: T.untyped, promoted_fns: T::Set[String], schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_binding(name, ti, node, promoted_fns, schema_lookup)
    node_sym = node.respond_to?(:symbol) ? node.symbol : nil
    value = node.respond_to?(:value) ? node.value : nil
    return nil if binding_container_borrow?(node)
    return nil if ti.optional? && optional_empty_initializer?(value) &&
                  !(node.is_a?(AST::VarDecl) && node.mutable == true &&
                    node.respond_to?(:var_mutated) && node.var_mutated)
    return nil if !node_sym&.heap_storage? &&
                  (node_sym&.borrow_provenance? ||
                   (node.respond_to?(:borrow_provenance?) && node.borrow_provenance?))
    return nil if ti.string? && !node_sym&.heap_storage? &&
                  !mutable_owning_slot?(ti, node, schema_lookup) &&
                  (node_sym&.rodata_provenance? ||
                   (node.respond_to?(:rodata_provenance?) && node.rodata_provenance?))

    sync = node_sym&.sync
    entry = nil
    schema = schema_lookup.call(ti.resolved) rescue nil

    if Schemas.resource?(schema)
      entry = entry(:resource, resource_close_zig: schema.close_zig)
    end

    entry ||= entry(:uniform, has_moved_guard: false) if ti.tense_observable? && !ti.promise_list?
    if !entry && ti.frozen?
      entry = entry(:frozen, has_moved_guard: false)
      entry[:fixed_alloc] = true
    end
    entry ||= entry(:uniform, has_moved_guard: true) if stream_handle_type?(ti)
    if !entry && node.respond_to?(:resource_close_zig) && node.resource_close_zig
      entry = entry(:resource, resource_close_zig: node.resource_close_zig)
    end
    entry ||= classify_mutable_owning_slot(ti, node, schema_lookup)
    entry ||= classify_optional(ti, schema_lookup, node: node)
    if !entry && node_sym&.heap_storage? && ti.recursive_cleanup_shape?(schema_lookup)
      entry = entry(:uniform, has_moved_guard: false)
      entry[:fixed_alloc] = true
    end
    entry ||= classify_owned_return_call(ti, node, schema_lookup)
    entry ||= classify_collection(ti, schema_lookup, node: node)
    if !entry && ti.direct_indexable_collection? && elem_needs_cleanup?(ti, schema_lookup)
      entry = entry(:uniform, has_moved_guard: true)
    end
    entry ||= entry(:uniform, has_moved_guard: true) if !ti.optional? && (ti.heap_ptr? || ti.indirect?)
    entry ||= classify_array_struct_strings(ti, node, schema_lookup)
    if !entry && ti.respond_to?(:atomic?) && ti.atomic? && ti.respond_to?(:indirect?) && ti.indirect?
      entry = entry(:uniform)
    end
    entry ||= classify_rc_or_link(ti, schema_lookup)
    entry ||= entry(:uniform, has_moved_guard: false) if ti.any_sync? || SymbolEntry.cleanup_sync?(sync)
    entry ||= classify_owned_string(ti, node, promoted_fns, schema_lookup)
    entry ||= classify_heap_storage(ti, node, schema_lookup, sync)
    entry ||= classify_heap_composite(ti, node, schema_lookup, sync)
    entry ||= classify_struct_cleanup_fields(ti, node, schema_lookup)
    entry ||= classify_non_copy_union(ti, schema_lookup)
    finalize_alloc_from_storage!(entry, node, ti, schema_lookup)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  private_class_method def self.binding_container_borrow?(node)
    return true if node.respond_to?(:container_borrow) && node.container_borrow

    value = node.respond_to?(:value) ? node.value : nil
    return true if value.respond_to?(:container_borrow) && value.container_borrow
    if value.is_a?(AST::BinaryOp) && (value.op == :OR || value.op == :OR_RESCUE)
      return true if value.left.respond_to?(:container_borrow) && value.left.container_borrow
    end

    false
  end

  sig { params(entry: T.nilable(CleanupEntry), node: T.untyped, ti: Type, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.finalize_alloc_from_storage!(entry, node, ti, schema_lookup)
    return nil unless entry
    return entry unless node.respond_to?(:symbol)
    sym = node.symbol
    decl = sym&.respond_to?(:reg) ? sym.reg : nil
    decl_sym = decl && decl.respond_to?(:symbol) ? decl.symbol : nil
    storage = decl_sym&.storage || sym&.storage
    type_alloc = ti.cleanup_allocator(schema_lookup)
    return entry if entry[:fixed_alloc]
    entry[:alloc] = (type_alloc == :heap || storage == :heap) ? :heap : :frame
    entry
  end

  # ── Individual classifiers ───────────────────────────────────────

  sig { params(kind: Symbol, alloc: Symbol, has_moved_guard: T::Boolean, extra: T.untyped).returns(CleanupEntry) }
  private_class_method def self.entry(kind, alloc: :heap, has_moved_guard: true, **extra)
    CleanupEntry.build(kind, alloc: alloc, has_moved_guard: has_moved_guard, **extra)
  end

  sig { params(ti: Type).returns(T::Boolean) }
  private_class_method def self.stream_handle_type?(ti)
    ti.dynamic_stream? || ti.bounded_stream? || ti.open_stream? ||
      ti.inf_stream? || ti.split_open_stream? || ti.shared_promise?
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.mutable_owning_slot?(ti, node, schema_lookup)
    return false unless node.respond_to?(:var_mutated) && node.var_mutated == true
    ownership_bearing_type?(ti, schema_lookup)
  end

  sig { params(ti: Type, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.ownership_bearing_type?(ti, schema_lookup)
    ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(schema_lookup)
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_mutable_owning_slot(ti, node, schema_lookup)
    return nil unless mutable_owning_slot?(ti, node, schema_lookup)
    kind = ti.string? ? :heap_string : :uniform
    alloc = ti.cleanup_allocator(schema_lookup)
    e = entry(kind, alloc: alloc, has_moved_guard: true)
    e
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_owned_return_call(ti, node, schema_lookup)
    return nil unless node.respond_to?(:value) && contains_call?(node.value)
    sym = node.respond_to?(:symbol) ? node.symbol : nil
    return nil unless sym&.storage == :heap
    ret = ti.success_type
    return nil unless ret && (
      ret.needs_explicit_cleanup?(:heap, schema_lookup) ||
        ret.heap_ptr? ||
        ret.recursive_cleanup_shape?(schema_lookup)
    )

    schema = schema_lookup.call(ret.resolved) rescue nil
    kind = ret.string? ? :heap_string : :uniform
    e = entry(kind, alloc: :heap, has_moved_guard: true)
    e[:fixed_alloc] = true
    e
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  private_class_method def self.contains_call?(node)
    found = T.let(false, T::Boolean)
    AST.each_locatable(node) do |cur|
      if AST.call?(cur)
        found = true
        break
      end
    end
    found
  end

  sig { params(ti: Type, schema_lookup: Proc, node: T.untyped).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_collection(ti, schema_lookup, node: nil)
    # Group 1 / Group 2 separation: when a collection is wrapped with
    # Arc/Rc ownership, the cleanup is `arcRelease` / `rcRelease` — which
    # cascades through the wrapper down to the inner data shape's deinit.
    # Defer to classify_rc_or_link instead of emitting a bare-shape
    # `pool.deinit()` / `list.deinit()` / etc. against the outer wrapper.
    return nil if ti.any_rc?

    # T[N]@soa: fixed SOA array backed by SoaList — needs deinit like a list.
    return entry(:uniform, alloc: wrapper_alloc(ti), has_moved_guard: false) if ti.fixed_soa?
    node_sym = node.respond_to?(:symbol) ? node.symbol : nil
    is_heap = !!node_sym&.heap_storage?
    if ti.list_collection? && !ti.sharded? && !is_heap
      has_heap_elems = elem_needs_cleanup?(ti, schema_lookup)
      return entry(:uniform, alloc: :frame, elem_needs_cleanup: has_heap_elems)
    end
    return entry(:uniform, has_moved_guard: true) if ti.list_collection?
    return entry(:uniform) if ti.map?
    return entry(:uniform, alloc: wrapper_alloc(ti), has_moved_guard: true) if ti.pool?
    return entry(:uniform, alloc: wrapper_alloc(ti), has_moved_guard: true) if ti.set_collection?
    nil
  end

  # Single-source allocator selection for type-intrinsic-heap wrappers
  # (pool, set, fixed_soa, rc/arc). Reads Type-level provenance when explicit;
  # otherwise defaults to :heap because all these shapes are always heap-
  # allocated at the wrapper level.
  sig { params(ti: Type).returns(Symbol) }
  private_class_method def self.wrapper_alloc(ti)
    ti.provenance_alloc || :heap
  end

  # Plain `T[]` slice (no @list modifier) where elements own cleanup.
  # Route uniformly through CheatLib.cleanup: it iterates elements,
  # recurses into structs/unions/slices, then frees the buffer with the
  # binding's allocator.
  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_array_struct_strings(ti, node, schema_lookup)
    val = node.respond_to?(:value) ? node.value : nil
    return nil unless ti.non_string_array? && !ti.collection? && val.is_a?(AST::ListLit)
    et = ti.element_type
    return nil unless et && elem_type_needs_cleanup?(et, schema_lookup)
    sym = node.respond_to?(:symbol) ? node.symbol : nil
    container_alloc = container_alloc_from(sym, node)
    entry(:uniform, alloc: container_alloc, has_moved_guard: false)
  end

  # Map binding storage to cleanup allocator. Heap-wrapper storage modes
  # (sync/shared/multiowned/link/frozen) all imply heap; stack/frame
  # imply frame. Reads decl symbol via sym.reg for the authoritative
  # post-escape-analysis storage.
  sig { params(sym: T.untyped, node: T.untyped).returns(Symbol) }
  private_class_method def self.container_alloc_from(sym, node)
    decl = sym && sym.respond_to?(:reg) ? sym.reg : nil
    decl_sym = decl && decl.respond_to?(:symbol) ? decl.symbol : nil
    storage = decl_sym&.storage || sym&.storage ||
              (node.respond_to?(:storage) ? node.storage : nil)
    case storage
    when :frame, :stack then :frame
    else :heap
    end
  end

  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_rc_or_link(ti, schema_lookup)
    return nil unless ti.any_rc? || ti.link?

    # Strong / weak / optional Rc/Arc all flow through CheatLib.cleanup's
    # refInnerType + releaseOne arms (which detect weak/atomic via
    # comptime). The Ruby just needs the binding's allocator and -- for
    # struct-wrapping-Rc bindings -- a side-channel to release inner
    # heap fields after Rc strong=0 (no field cleanup is done by the
    # uniform releaseOne path).
    if ti.link?
      entry(:rc)
    elsif ti.optional?
      entry(:rc, rc_alloc: wrapper_alloc(ti))
    else
      rc_alloc = wrapper_alloc(ti)
      e = entry(:rc, rc_alloc: rc_alloc)
      if ti.any_rc? && !ti.sync
        schema = schema_lookup.call(ti.resolved) rescue nil
        if Schemas.field_bearing?(schema)
          base_type = ti.resolved.to_s
          base_type = base_type.sub(/^\?/, '') if ti.optional?
          e[:needs_release_fields] = true
          e[:base_zig] = Type.new(base_type).zig_type rescue base_type
        end
      end
      e
    end
  end

  sig { params(ti: Type, schema_lookup: Proc, node: T.untyped).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_optional(ti, schema_lookup, node: nil)
    return nil unless ti.optional?
    inner = ti.wrapped_type
    return nil unless inner
    return nil unless optional_payload_needs_cleanup?(inner, schema_lookup)
    # rodata/borrow provenance: the payload is a string literal in the binary
    # or a borrowed view -- never heap-owned, so freeing it (cleanupAlloc only
    # skips frame, not rodata) is an invalid free. No cleanup needed.
    node_sym = node.respond_to?(:symbol) ? node.symbol : nil
    value = node.respond_to?(:value) ? node.value : nil
    return nil if optional_empty_initializer?(value)
    is_rodata = !!node_sym&.rodata_provenance?
    is_borrow = !!node_sym&.borrow_provenance?
    return nil if is_rodata || is_borrow
    # Optional binding alloc inherits from the binding's authoritative
    # storage. Escape analysis marks optionals receiving cross-fiber/heap
    # data to heap; the rest stay frame. The runtime cleanup arm uses
    # the binding's allocator to free the payload -- frame.free is a
    # no-op for frame strings (arena reclaim), heap.free for heap
    # strings. No vtable / ptrIsFrameOwned needed.
    storage = node_sym&.storage
    alloc = storage == :heap ? :heap : :frame
    e = entry(:uniform, alloc: alloc)
    if value.is_a?(AST::NextExpr)
      e[:alloc] = :heap
      e[:fixed_alloc] = true
    end
    e
  end

  sig { params(value: T.untyped).returns(T::Boolean) }
  private_class_method def self.optional_empty_initializer?(value)
    value.is_a?(AST::Literal) && value.type == :NIL ? true : false
  end

  sig { params(inner: Type, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.optional_payload_needs_cleanup?(inner, schema_lookup)
    return true if inner.string?
    return true if inner.recursive_cleanup_shape?(schema_lookup)
    return true if inner.needs_cleanup?(schema_lookup)
    schema = schema_lookup.call(inner.resolved) rescue nil
    return union_variants_need_cleanup?(schema, schema_lookup) if Schemas.union?(schema)
    return elem_has_string_fields?(schema) if Schemas.field_bearing?(schema)
    false
  end

  sig { params(ti: Type, node: T.untyped, promoted_fns: T::Set[String], schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_owned_string(ti, node, promoted_fns, schema_lookup)
    return nil unless ti.string?
    value = node.respond_to?(:value) ? node.value : nil
    node_sym = node.respond_to?(:symbol) ? node.symbol : nil
    return nil if !node_sym&.heap_storage? &&
                  (node_sym&.rodata_provenance? || node_sym&.borrow_provenance?)
    fixed_heap = value.is_a?(AST::NextExpr) || capture_expr_heap?(value, promoted_fns, schema_lookup)
    owns_heap = value.is_a?(AST::CopyNode) ||
                fixed_heap ||
                node_sym&.heap_storage? ||
                value.is_a?(AST::StringConcat) ||
                (value.is_a?(AST::BinaryOp) && value.op == :ADD && value.string_concat)
    return nil unless owns_heap
    e = entry(:heap_string, has_moved_guard: true)
    e[:fixed_alloc] = true if fixed_heap
    e
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc, sync: T.nilable(Symbol)).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_heap_storage(ti, node, schema_lookup, sync = nil)
    node_sym = node.respond_to?(:symbol) ? node.symbol : nil
    is_heap = node_sym&.heap_storage?
    return nil unless is_heap
    return nil if ti.any_rc? || ti.link? || SymbolEntry.cleanup_sync?(sync)
    return nil if ti.implicitly_copyable?(schema_lookup)
    return nil if ti.collection?

    return entry(:heap_string) if ti.string?
    return entry(:uniform) if ti.array? && !ti.collection?

    schema = schema_lookup.call(ti.resolved) rescue nil
    if Schemas.union?(schema)
      has_heap = union_variants_need_cleanup?(schema, schema_lookup)
      return entry(:uniform) if has_heap
    end
    if Schemas.field_bearing?(schema)
      has_escapable = elem_has_cleanup_fields?(schema, schema_lookup)
      has_escapable = false if has_escapable && struct_lit_borrows_cleanup_fields?(node, schema, schema_lookup)
      return entry(:uniform) if has_escapable
      return entry(:uniform)
    end
    nil
  end

  # Catch-all for heap pointers not handled by classify_heap_storage.
  # Heap-stored composite (struct or union) whose cleanup the uniform
  # CheatLib.cleanup path handles via @TypeOf comptime dispatch.
  # Covers @alwaysMutable / @indirect annotations AND structs promoted
  # to heap by MIRPass upgrade phases where type_info.provenance is not
  # set (only node.@storage_override is set).
  #
  # The runtime arms differentiate based on actual Zig type shape; the
  # Ruby kind label is now informational only:
  #   - :heap_union for tagged-union schemas with heap variants
  #   - :heap_struct for everything else (struct-recursive cleanup;
  #     all-primitive struct collapses to a no-op via inline-for)
  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc, sync: T.nilable(Symbol)).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_heap_composite(ti, node, schema_lookup, sync = nil)
    return nil unless node.respond_to?(:heap_storage?) && node.heap_storage?
    return nil if ti.any_rc? || ti.link? || SymbolEntry.cleanup_sync?(sync)
    return nil if ti.implicitly_copyable?(schema_lookup)
    # Primitives (f64, i64, Bool, Byte) are stack values -- never need heap cleanup
    # even if storage was incorrectly set to :heap by upstream passes.
    return nil if ti.primitive?

    schema = schema_lookup.call(ti.resolved) rescue nil
    if Schemas.union?(schema)
      has_heap = union_variants_need_cleanup?(schema, schema_lookup)
      return entry(:uniform) if has_heap
    end
    if Schemas.field_bearing?(schema)
      return nil unless elem_has_cleanup_fields?(schema, schema_lookup)
      return nil if struct_lit_borrows_cleanup_fields?(node, schema, schema_lookup)
    end
    entry(:uniform)
  end

  sig { params(node: T.untyped, schema: T.untyped, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.struct_lit_borrows_cleanup_fields?(node, schema, schema_lookup)
    value = node.respond_to?(:value) ? node.value : nil
    return false unless value.is_a?(AST::StructLit)
    borrowed = schema.respond_to?(:borrowed_fields) ? schema.borrowed_fields : Set.new
    schema.fields.all? do |k, field|
      ft = field.is_a?(AST::StructField) ? field.type : field
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      next true unless elem_type_needs_cleanup?(t, schema_lookup)
      fval = value.fields[k.to_s] || value.fields[k]
      (field.is_a?(AST::StructField) && field.borrowed) ||
        borrowed.include?(k.to_s) ||
        (fval.respond_to?(:symbol) && fval.symbol&.borrow_provenance?) ||
        (fval && Type.from_node!(fval, context: "struct literal borrowed field").provenance == :borrow)
    end
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_struct_cleanup_fields(ti, node, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil
    return nil unless Schemas.field_bearing?(schema)

    # Same `node` shape concerns as classify_array_struct_strings: WHILE-bind /
    # IF-bind capture nodes don't carry `.value`; only VarDecl/BindExpr do.
    struct_lit = node.respond_to?(:value) && node.value.is_a?(AST::StructLit) ? node.value : nil
    borrowed = schema.respond_to?(:borrowed_fields) ? schema.borrowed_fields : Set.new
    has_cleanup = schema.fields.any? do |k, v|
      next false if borrowed.include?(k.to_s)
      ft = v.is_a?(AST::StructField) ? v.type : v
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      # Rodata string fields don't need cleanup
      if struct_lit
        fval = struct_lit.fields[k.to_s] || struct_lit.fields[k]
        next false if fval.respond_to?(:symbol) && fval.symbol&.borrow_provenance?
        if fval
          fval_ti = Type.from_node!(fval, context: "struct cleanup field")
          next false if fval_ti.rodata? || fval_ti.provenance == :borrow
        end
      end
      elem_type_needs_cleanup?(t, schema_lookup)
    end
    return nil unless has_cleanup
    # NOTE: cannot uniformly use container_alloc here yet -- doing so
    # exposes a pre-existing FRAME_NO_REWIND gap for structs containing
    # @list fields inside loop bodies (255_bind_cleanup_heap). The
    # struct's :frame alloc causes the AllocMark to be :frame, but the
    # surrounding loop's mark_per_iter detection (LoopFrameAnalysis)
    # doesn't see this struct as a frame_decl. To enable, either
    # LoopFrameAnalysis must include frame-cleanup-alloc bindings, OR
    # we accept :cleanup as a fallback. Keeping :cleanup until that's
    # addressed.
    # Struct with cleanup-needing fields: alloc inherits provenance.
    # Frame structs have frame-allocated nested collection/string fields
    # (uniform via the same escape-analysis storage decision that handles direct
    # @list bindings); the runtime's frame.free is a no-op for them,
    # so the arena reclaim is correct. The previous :cleanup fallback
    # was a workaround for the same mismatch class the list-elem case
    # had; no longer needed.
    alloc = ti.provenance_alloc == :frame ? :frame : :heap
    entry(:uniform, alloc: alloc)
  end

  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(CleanupEntry)) }
  private_class_method def self.classify_non_copy_union(ti, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil
    return nil unless Schemas.union?(schema)
    is_copy = ti.implicitly_copyable? { |t| schema_lookup.call(t) rescue nil } rescue true
    return nil if is_copy
    has_heap_variants = union_variants_need_cleanup?(schema, schema_lookup)
    alloc = has_heap_variants ? :heap : (ti.provenance_alloc || :frame)
    e = entry(:uniform, alloc: alloc)
    e[:fixed_alloc] = true if has_heap_variants
    e
  end

  # ── Schema helpers ───────────────────────────────────────────────

  sig { params(ti: Type, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.elem_needs_cleanup?(ti, schema_lookup)
    et = ti.element_type
    return false unless et
    elem_type_needs_cleanup?(et, schema_lookup)
  end

  sig { params(et: Type, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.elem_type_needs_cleanup?(et, schema_lookup)
    return false if et.provenance == :borrow
    return true if et.string?
    return true if et.needs_cleanup?(schema_lookup)
    elem_schema = schema_lookup.call(et.resolved) rescue nil
    return union_variants_need_cleanup?(elem_schema, schema_lookup) if Schemas.union?(elem_schema)
    return elem_has_cleanup_fields?(elem_schema, schema_lookup) if Schemas.field_bearing?(elem_schema)
    false
  end

  sig { params(schema: T.untyped, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.union_variants_need_cleanup?(schema, schema_lookup)
    return false unless Schemas.union?(schema)
    (schema.variants || {}).any? do |_, vt|
      variant_type_needs_cleanup?(vt, schema_lookup)
    end
  end

  sig { params(vt: T.untyped, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.variant_type_needs_cleanup?(vt, schema_lookup)
    if Schemas.inline_struct?(vt)
      return elem_has_cleanup_fields?(vt, schema_lookup)
    end
    t = vt.is_a?(Type) ? vt : (Type.new(vt) rescue nil)
    return false unless t
    elem_type_needs_cleanup?(t, schema_lookup)
  end

  sig { params(schema: T.untyped).returns(T::Boolean) }
  private_class_method def self.elem_has_string_fields?(schema)
    elem_has_cleanup_fields?(schema, nil)
  end

  sig { params(schema: T.untyped, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.elem_has_cleanup_fields?(schema, schema_lookup)
    return false unless Schemas.field_bearing?(schema) || Schemas.inline_struct?(schema)
    borrowed = schema.respond_to?(:borrowed_fields) ? schema.borrowed_fields : Set.new
    schema.fields.any? do |name, v|
      next false if borrowed.include?(name.to_s)
      ft = v.is_a?(AST::StructField) ? v.type : v
      next false if v.is_a?(AST::StructField) && v.borrowed
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      t.string? ||
        t.non_string_array? ||
        t.collection? ||
        t.indirect? ||
        t.any_rc? ||
        t.link? ||
        (schema_lookup && t.recursive_cleanup_shape?(schema_lookup)) ||
        (schema_lookup && t.needs_cleanup?(schema_lookup))
    end
  end

end
