require_relative "type"

# Pass C: Escape Promotion Planning
#
# Computed after annotation (full type + ownership info available).
# Produces a concrete plan per function that the transpiler executes
# mechanically with zero decisions.
#
# Zig's CheatLib.promote(T, rt, &x) handles the type-specific logic:
#   ArrayList  -> promoteList (dupes .items to heap)
#   StringMap  -> .alloc = heapAlloc (O(1) pointer swap)
#   String     -> heapAlloc.dupe (O(N) copy)
#   Struct     -> recurse fields
#   Union      -> promote active variant
#
# Ruby just decides WHICH variables/values to call it on.

module PromotionClassifier
  # Classify escape promotions for a single function.
  #
  # @param fn_node [AST::FunctionDef] the annotated function
  # @param schema_lookup [Proc] lambda(type_name_sym) -> schema hash or nil
  # @return [Hash] { var_promotes:, struct_promote:, promote_return_ids:, unhandled_promote_fields: }
  #                or empty hash
  def self.classify(fn_node, schema_lookup:)
    return {} unless fn_allocates?(fn_node) || fn_node.return_provenance == :heap

    ret_type_sym = fn_node.return_type
    return {} unless ret_type_sym
    ret_type = ret_type_sym.is_a?(Type) ? ret_type_sym : Type.new(ret_type_sym)
    return {} if ret_type.resolved == :Void
    return {} if ret_type.string?

    return_nodes = collect_returns(fn_node.body)
    return {} if return_nodes.empty?

    var_promotes = []
    handled_fields = Set.new
    struct_promote = nil
    promote_return_ids = Set.new

    return_nodes.each do |ret_node|
      val = ret_node.value
      next unless val

      if val.is_a?(AST::StructLit) || val.is_a?(AST::UnionVariantLit)
        val.fields.each do |fname, fval|
          fti = fval.type_info
          fti = Type.new(fti) if fti && !fti.is_a?(Type)

          if fti&.heap_provenance? || fti&.rodata_provenance?
            handled_fields << fname.to_s
            next
          end

          next unless fval.is_a?(AST::Identifier)
          next unless fti&.escaped_return

          var_promotes << { var: fval.name, zig_type: fti.zig_type }
          handled_fields << fname.to_s
        end

        if var_promotes.empty?
          needs_promote = val.fields.any? do |_, fval|
            fti = fval.type_info
            fti = Type.new(fti) if fti && !fti.is_a?(Type)
            next false if fti&.heap_provenance? || fti&.rodata_provenance?
            fti&.string? || fti&.array? || fti&.collection?
          end
          if needs_promote
            ret_schema = schema_lookup.call(ret_type.resolved) rescue nil
            if ret_schema.is_a?(Hash) && ret_schema[:kind] == :union
              has_heap = (ret_schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
              if has_heap
                struct_promote ||= zig_type_for(ret_type)
                promote_return_ids << ret_node.object_id
              end
            end
          end
        end

      elsif val.is_a?(AST::Identifier)
        ti = val.type_info
        ti = Type.new(ti) if ti && !ti.is_a?(Type)
        needs_escape = ti&.escaped_return && !ti&.heap_provenance? && !ti.string?
        if needs_escape
          if ti.list_collection? || ti.map?
            var_promotes << { var: val.name, zig_type: ti.zig_type }
          else
            struct_promote ||= zig_type_for(ret_type)
          end
        end
      end
    end

    schema = schema_lookup.call(ret_type.resolved) rescue nil
    is_union = schema.is_a?(Hash) && schema[:kind] == :union
    unhandled_fields = nil
    if struct_promote.nil?
      if var_promotes.any? || handled_fields.any?
        struct_promote, unhandled_fields = compute_struct_promote(ret_type, schema_lookup, handled_fields)
      elsif (fn_node.return_provenance == :heap) && !is_union && ret_type.needs_promotion?(schema_lookup)
        struct_promote, unhandled_fields = compute_struct_promote(ret_type, schema_lookup, handled_fields)
      end
    end

    if var_promotes.empty? && struct_promote.nil?
      {}
    else
      {
        var_promotes: var_promotes.uniq { |vp| vp[:var] },
        struct_promote: struct_promote,
        promote_return_ids: promote_return_ids.empty? ? nil : promote_return_ids,
        unhandled_promote_fields: unhandled_fields
      }
    end
  end

  # Filter var_promotes to only those referenced in a return expression.
  def self.filter_for_return(plan, return_value)
    return plan if plan[:var_promotes]&.empty?

    referenced = referenced_vars(return_value)
    relevant = plan[:var_promotes].select { |vp| referenced.include?(vp[:var]) }

    plan.merge(var_promotes: relevant)
  end

  # Check if a specific return node needs struct_promote.
  def self.needs_promote?(plan, ret_node)
    return true if plan[:promote_return_ids].nil?
    plan[:promote_return_ids].include?(ret_node.object_id)
  end

  # ── Private helpers ──────────────────────────────────────────────

  private_class_method def self.fn_allocates?(fn_node)
    fn_node.uses_frame || fn_node.uses_heap || fn_node.uses_alloc
  end

  private_class_method def self.collect_returns(body)
    returns = []
    AST.walk_body(body) { |node| returns << node if node.is_a?(AST::ReturnNode) }
    returns
  end

  private_class_method def self.compute_struct_promote(ret_type, schema_lookup, handled_fields)
    resolved = ret_type.resolved
    schema = schema_lookup.call(resolved) rescue nil
    return [nil, nil] unless schema.is_a?(Hash) && !schema[:kind]

    unhandled = []
    schema.each do |fname, fdef|
      next if fname.is_a?(Symbol)
      next if handled_fields.include?(fname.to_s)
      ft = fdef.is_a?(Type) ? fdef : Type.new(fdef.is_a?(Hash) ? (fdef[:type] || :Any) : (fdef || :Any))
      unhandled << fname.to_s if ft.needs_escape_promotion?
    end

    unhandled.any? ? [zig_type_for(ret_type), unhandled] : [nil, nil]
  end

  private_class_method def self.zig_type_for(type)
    name = type.resolved.to_s.sub(/^[!?]+/, '')
    Type.new(name).zig_type
  end

  private_class_method def self.referenced_vars(node)
    vars = Set.new
    return vars unless node
    case node
    when AST::Identifier
      vars << node.name
    when AST::StructLit
      node.fields.each_value { |v| vars.merge(referenced_vars(v)) }
    end
    vars
  end
end

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
#   - type_info.escaped_return (set by mark_symbol_escaped!)
#   - node.resource_close_zig (set by annotator)
#   - deferred_drops (TAKES params)
#   - MatchStatement cases with bindings + was_moved
#   - union/struct schemas (for non-Copy checks)
# =========================================================================
module CleanupClassifier
  # Classify all bindings in a function that need cleanup.
  #
  # @param fn_node [AST::FunctionDef]
  # @param fn_nodes [Hash] name => FunctionDef for all functions
  # @param schema_lookup [Proc] lambda(type_sym) => schema hash
  # @return [Hash] { var_name => entry_hash } or empty hash
  def self.classify(fn_node, fn_nodes:, schema_lookup:)
    return {} unless fn_node.body

    promoted_fns = compute_promoted_fns(fn_nodes)
    bindings = {}

    # 1. Walk all VarDecl/BindExpr in the function body.
    walk_bindings(fn_node.body, promoted_fns, schema_lookup, bindings)

    # 2. TAKES parameters from deferred_drops.
    walk_takes_params(fn_node, schema_lookup, bindings)

    # 3. MATCH AS bindings (non-Copy payloads need cleanup with _moved guard).
    walk_match_as_bindings(fn_node.body, schema_lookup, bindings)

    bindings
  end

  # Walk field assignments that need pre-cleanup (free old value before overwrite).
  # Stamps Assignment nodes directly with { zig_type:, alloc: }.
  def self.stamp_field_pre_cleanups!(body, bindings, schema_lookup: nil)
    AST.walk_body(body) do |stmt|
      next unless stmt.is_a?(AST::Assignment)
      next unless stmt.name.is_a?(AST::GetField)
      target_node = stmt.name.target

      field_ti = stmt.name.type_info rescue nil
      field_ti = Type.new(field_ti) if field_ti && !field_ti.is_a?(Type)

      # Auto-lock string fields: locked/always_mutable structs heap-dupe
      # string fields, so overwriting needs explicit free of the old value.
      if !field_ti&.needs_cleanup?(schema_lookup) && stmt.auto_lock && field_ti&.string?
        stmt.field_pre_cleanup = { zig_type: "[]const u8", alloc: :heap }
        next
      end

      next unless field_ti&.needs_cleanup?(schema_lookup)

      alloc = if target_node.is_a?(AST::Identifier)
        target_entry = bindings[target_node.name.to_s]
        (target_entry && target_entry[:alloc] == :heap) ? :heap : :frame
      else
        :frame
      end
      stmt.field_pre_cleanup = { zig_type: field_ti.zig_type, alloc: alloc }
    end
  end

  # ── Promoted function detection ──────────────────────────────────

  private_class_method def self.compute_promoted_fns(fn_nodes)
    promoted = Set.new
    fn_nodes.each { |name, fn| promoted << name if fn.return_provenance == :heap }

    changed = true
    while changed
      changed = false
      fn_nodes.each do |name, fn|
        next if promoted.include?(name)
        next unless fn.body
        if body_calls_promoted?(fn.body, promoted)
          promoted << name
          changed = true
        end
      end
    end
    promoted
  end

  private_class_method def self.body_calls_promoted?(body, promoted)
    found = false
    AST.walk_body(body) do |node|
      if node.is_a?(AST::ReturnNode) && node.value.is_a?(AST::FuncCall) && promoted.include?(node.value.name)
        found = true
      end
    end
    found
  end

  # ── Walk VarDecl / BindExpr ──────────────────────────────────────

  private_class_method def self.walk_bindings(body, promoted_fns, schema_lookup, bindings)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
      next if node.is_a?(AST::BindExpr) && node.mode == :assign

      var_name = node.name.is_a?(String) ? node.name : node.name.to_s
      ti = node.type_info
      ti = Type.new(ti) if ti && !ti.is_a?(Type)
      cleanup = classify_binding(var_name, ti, node, promoted_fns, schema_lookup)
      bindings[var_name] = cleanup if cleanup
    end
  end

  # ── Walk TAKES parameters ───────────────────────────────────────

  private_class_method def self.walk_takes_params(fn_node, schema_lookup, bindings)
    drops = fn_node.deferred_drops || []
    drops.each do |drop|
      param_def = fn_node.params.find { |p| p[:name] == drop[:name] }
      next unless param_def&.dig(:takes)

      ti = drop[:type].is_a?(Type) ? drop[:type] : Type.new(drop[:type] || :Any)
      name = drop[:name].to_s

      schema = schema_lookup.call(ti.resolved) rescue nil
      is_resource = schema.is_a?(Hash) && schema[:kind] == :resource
      is_union = schema.is_a?(Hash) && schema[:kind] == :union

      if is_resource
        close_zig = schema[:close_zig]
        bindings[name] = {
          needs_cleanup: true, alloc: :heap, kind: :resource,
          has_moved_guard: true,
          resource_close_zig: close_zig
        }
      elsif is_union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        if has_heap
          bindings[name] = {
            needs_cleanup: true, alloc: :heap, kind: :takes_union,
            has_moved_guard: true
          }
        end
      elsif ti.string?
        bindings[name] = {
          needs_cleanup: true, alloc: :heap, kind: :takes_string,
          has_moved_guard: true, source_kind: :takes_param
        }
      elsif ti.array? && !ti.string?
        # TAKES slice param: callee owns the buffer. Caller must pass a
        # heap-owned buffer (via implicit COPY of @list or explicit COPY).
        bindings[name] = {
          needs_cleanup: true, alloc: :heap, kind: :takes_slice,
          has_moved_guard: true, source_kind: :takes_param
        }
      end
    end
  end

  # ── Walk MATCH AS bindings ──────────────────────────────────────

  private_class_method def self.walk_match_as_bindings(body, schema_lookup, bindings)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::MatchStatement)
      next unless node.expr.is_a?(AST::Identifier) && node.expr.was_moved

      source_ti = node.expr.type_info
      source_ti = Type.new(source_ti) if source_ti && !source_ti.is_a?(Type)
      union_lookup = source_ti&.generic_instance? ? source_ti.generic_base : source_ti&.resolved
      schema = schema_lookup.call(union_lookup) rescue nil
      next unless schema.is_a?(Hash) && schema[:kind] == :union

      (node.cases || []).each do |c|
        next unless c[:binding]
        variant_name = case c[:value]
                       when AST::GetField then c[:value].field
                       when AST::MethodCall then c[:value].name
                       else nil
                       end
        next unless variant_name

        variant_type = (schema[:variants] || {})[variant_name]
        next unless variant_type

        if variant_type.is_a?(Hash) && variant_type[:kind] == :inline_struct
          has_heap = Type.variant_has_heap?(variant_type)
          if has_heap
            union_zig = Type.new(union_lookup).zig_type rescue union_lookup.to_s
            bindings[c[:binding]] = {
              needs_cleanup: true, alloc: :heap, kind: :match_as_inline_struct,
              has_moved_guard: true, match_as: true,
              zig_type: "#{union_zig}_#{variant_name}"
            }
          end
        elsif variant_type.is_a?(Hash) && variant_type[:kind] == :indirect_payload
          # @indirect payload: the extracted value is a simple type (behind a
          # pointer in the union). No AS binding cleanup needed.
          next
        else
          pt = variant_type.is_a?(Type) ? variant_type : Type.new(variant_type || :Any)
          if pt.array? && !pt.string?
            elem_zig = pt.element_type ? (Type.new(pt.element_type).zig_type rescue pt.element_type.to_s) : "UNKNOWN"
            bindings[c[:binding]] = {
              needs_cleanup: true, alloc: :heap, kind: :match_as_slice,
              has_moved_guard: true, match_as: true,
              elem_zig_type: elem_zig
            }
          elsif pt.collection? || pt.map?
            zig_type = pt.zig_type rescue pt.resolved.to_s
            bindings[c[:binding]] = {
              needs_cleanup: true, alloc: :heap, kind: pt.map? ? :string_map : :list,
              has_moved_guard: true, match_as: true,
              zig_type: zig_type
            }
          end
        end
      end
    end
  end

  # ── classify_binding: dispatch pipeline ─────────────────────────
  #
  # Each classify_* method handles one cleanup category, returning a
  # cleanup entry hash or nil. Order matters: earlier categories take
  # priority (e.g. resource before collection, RC before sync).

  private_class_method def self.classify_binding(name, ti, node, promoted_fns, schema_lookup)
    return nil unless ti
    return nil if node.respond_to?(:container_borrow) && node.container_borrow

    classify_resource(ti, node) ||
      classify_collection(ti, schema_lookup) ||
      classify_array_struct_strings(ti, node, schema_lookup) ||
      classify_rc_or_link(ti, schema_lookup) ||
      classify_sync(ti) ||
      classify_heap_provenance(ti, node, schema_lookup) ||
      classify_heap_struct_plain(ti, node) ||
      classify_struct_cleanup_fields(ti, node, schema_lookup) ||
      classify_non_copy_union(ti, schema_lookup)
  end

  # ── Individual classifiers ───────────────────────────────────────

  private_class_method def self.entry(kind, alloc: :heap, has_moved_guard: true, **extra)
    { needs_cleanup: true, alloc: alloc, kind: kind,
      has_moved_guard: has_moved_guard, **extra }
  end

  private_class_method def self.classify_resource(_ti, node)
    return nil unless node.respond_to?(:resource_close_zig) && node.resource_close_zig
    entry(:resource, resource_close_zig: node.resource_close_zig)
  end

  private_class_method def self.classify_collection(ti, schema_lookup)
    # T[N]@soa: fixed SOA array backed by SoaList — needs deinit like a list.
    return entry(:fixed_soa, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.fixed_soa?
    if ti.list_collection? && !ti.sharded? && !ti.heap_provenance?
      has_heap_elems = elem_needs_cleanup?(ti, schema_lookup)
      return entry(has_heap_elems ? :list_with_elem_cleanup : :list,
                   alloc: :frame, elem_needs_cleanup: has_heap_elems)
    end
    return entry(:list, has_moved_guard: !ti.sharded?) if ti.list_collection?
    return entry(:rc) if ti.map? && !ti.numeric_map? && ti.shared?
    return entry(:string_map) if ti.map? && !ti.numeric_map?
    return entry(:numeric_map, alloc: :frame) if ti.numeric_map?
    return entry(:pool, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.pool?
    return entry(:set, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.set_collection?
    nil
  end

  private_class_method def self.classify_array_struct_strings(ti, node, schema_lookup)
    val = node.respond_to?(:value) ? node.value : nil
    return nil unless ti.array? && !ti.string? && !ti.collection? && val.is_a?(AST::ListLit)
    elem_schema = schema_lookup.call(ti.element_type&.resolved) rescue nil
    return nil unless elem_has_string_fields?(elem_schema)
    entry(:array_with_struct_strings)
  end

  private_class_method def self.classify_rc_or_link(ti, schema_lookup)
    return nil unless ti.any_rc? || ti.link?

    base_type = ti.resolved.to_s
    base_type = base_type.sub(/^\?/, '') if ti.optional?
    base_zig = Type.new(base_type).zig_type rescue base_type

    if ti.link?
      source = ti.link_source || :multiowned
      entry(:rc,
        rc_variant: :link,
        rc_release_func: source == :shared ? "weakArcRelease" : "weakRcRelease",
        base_zig: base_zig)
    elsif ti.optional?
      entry(:rc,
        rc_variant: :optional,
        rc_release_func: ti.shared? ? "arcRelease" : "rcRelease",
        base_zig: base_zig,
        rc_alloc: ti.provenance_alloc || :heap)
    else
      rc_alloc = ti.provenance_alloc || :heap
      e = entry(:rc, rc_variant: :standard, rc_alloc: rc_alloc)
      if ti.any_rc? && !ti.sync
        schema = schema_lookup.call(ti.resolved) rescue nil
        if schema.is_a?(Hash) && !schema[:kind]
          e[:needs_release_fields] = true
          e[:base_zig] = base_zig
        end
      end
      e
    end
  end

  private_class_method def self.classify_sync(ti)
    return entry(:locked) if ti.locked?
    return entry(:write_locked) if ti.write_locked?
    nil
  end

  private_class_method def self.classify_heap_provenance(ti, node, schema_lookup)
    return nil unless ti.heap_provenance?
    return nil if ti.any_rc? || ti.link? || ti.locked? || ti.write_locked?
    return nil if ti.collection? || ti.map? || ti.pool? || ti.set_collection?
    storage = node.respond_to?(:storage) ? node.storage : nil
    return nil if storage == :heap # heap_struct_plain handles this

    return entry(:heap_string) if ti.string?
    return entry(:heap_slice) if ti.array? && !ti.collection?

    schema = schema_lookup.call(ti.resolved) rescue nil
    if schema.is_a?(Hash) && schema[:kind] == :union
      has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      return entry(:heap_union) if has_heap
    end
    if schema.is_a?(Hash) && !schema[:kind]
      has_escapable = schema.any? do |k, v|
        next false if k.is_a?(Symbol)
        ft = v.is_a?(Type) ? v : Type.new(v.is_a?(Hash) ? (v[:type] || :Any) : (v || :Any))
        ft.needs_escape_promotion?
      end
      return entry(:heap_struct) if has_escapable
    end
    nil
  end

  # @alwaysMutable / @indirect create heap pointers needing CheatLib.free.
  private_class_method def self.classify_heap_struct_plain(ti, node)
    storage = node.respond_to?(:storage) ? node.storage : nil
    return nil unless storage == :heap
    return nil if ti.any_rc? || ti.link? || ti.locked? || ti.write_locked?
    entry(:heap_struct_plain)
  end

  private_class_method def self.classify_struct_cleanup_fields(ti, node, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil
    return nil unless schema.is_a?(Hash) && !schema[:kind]

    struct_lit = node.respond_to?(:value) && node.value.is_a?(AST::StructLit) ? node.value : nil
    has_cleanup = schema.any? do |k, v|
      next false if k.is_a?(Symbol)
      ft = v.is_a?(Hash) ? v[:type] : v
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      next true if t.link? || t.any_rc?
      next true if t.collection? || t.map?
      next false unless t.string?
      # Rodata string fields don't need cleanup
      if struct_lit
        fval = struct_lit.fields[k.to_s] || struct_lit.fields[k]
        fval_ti = fval&.type_info
        fval_ti = Type.new(fval_ti) if fval_ti && !fval_ti.is_a?(Type)
        next false if fval_ti&.rodata?
      end
      true
    end
    return nil unless has_cleanup
    entry(:struct_with_cleanup_fields, alloc: ti.provenance_alloc || :heap)
  end

  private_class_method def self.classify_non_copy_union(ti, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil
    return nil unless schema.is_a?(Hash) && schema[:kind] == :union
    is_copy = ti.implicitly_copyable? { |t| schema_lookup.call(t) rescue nil } rescue true
    return nil if is_copy
    has_heap_variants = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
    alloc = has_heap_variants ? :heap : (ti.provenance_alloc || :frame)
    entry(:non_copy_union, alloc: alloc)
  end

  # ── Schema helpers ───────────────────────────────────────────────

  private_class_method def self.elem_needs_cleanup?(ti, schema_lookup)
    elem_schema = schema_lookup.call(ti.element_type&.resolved) rescue nil
    (elem_schema.is_a?(Hash) && elem_schema[:kind] == :union &&
      (elem_schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }) ||
      elem_has_string_fields?(elem_schema)
  end

  private_class_method def self.elem_has_string_fields?(schema)
    return false unless schema.is_a?(Hash) && !schema[:kind]
    schema.any? do |k, v|
      next false if k.is_a?(Symbol)
      ft = v.is_a?(Hash) ? v[:type] : v
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      t.string?
    end
  end

end
