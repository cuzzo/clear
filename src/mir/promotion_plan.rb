require_relative "../ast/type"

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
  # Performance optimization: identifies frame variables that always escape via return
  # and upgrades them to heap at declaration (avoiding runtime CheatLib.promote calls).
  #
  # NOT a correctness requirement. Safety is enforced by OwnershipDataflow which marks
  # returned identifiers as :moved regardless of allocator. Without PromotionClassifier,
  # programs still work correctly -- they just do more runtime frame-to-heap promotions.
  #
  # Classify escape promotions for a single function.
  #
  # @param fn_node [AST::FunctionDef] the annotated function
  # @param schema_lookup [Proc] lambda(type_name_sym) -> schema hash or nil
  # @return [Hash] { var_promotes:, struct_promote:, promote_return_ids:, unhandled_promote_fields: }
  #                or empty hash
  def self.classify(fn_node, schema_lookup:)
    return {} unless fn_allocates?(fn_node) || fn_node.return_provenance == :heap || fn_has_escapable_return?(fn_node, schema_lookup)

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
          fti = Type.from_node(fval)

          if fti&.heap_provenance? || fti&.rodata_provenance?
            handled_fields << fname.to_s
            next
          end

          next unless fval.is_a?(AST::Identifier)
          next unless fti&.needs_escape_promotion? && !fti&.string? && !fti&.heap_provenance?

          var_promotes << { var: fval.name, zig_type: fti.zig_type }
          handled_fields << fname.to_s
        end

        if var_promotes.empty?
          needs_promote = val.fields.any? do |_, fval|
            fti = Type.from_node(fval)
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
        ti = Type.from_node(val)
        # TAKES params are already heap-owned by caller; no promotion needed.
        next if val.symbol&.takes
        needs_escape = (ti&.needs_escape_promotion? || struct_has_promotable_fields?(ti, schema_lookup)) &&
                       !ti&.string? && !ti&.heap_provenance?
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

  private_class_method def self.fn_has_escapable_return?(fn_node, schema_lookup = nil)
    collect_returns(fn_node.body).any? do |ret|
      next false unless ret.value.is_a?(AST::Identifier)
      # TAKES params are already heap-owned; returning them doesn't require promotion.
      next false if ret.value.symbol&.takes
      ti = ret.value.type_info
      ti = Type.new(ti) if ti && !ti.is_a?(Type)
      next true if ti&.needs_escape_promotion? && !ti&.string? && !ti&.heap_provenance?
      next true if schema_lookup && ti && !ti.string? && !ti.heap_provenance? &&
                   struct_has_promotable_fields?(ti, schema_lookup)
      false
    end
  end

  # Returns true iff `ti` is a STRUCT (not union, not primitive) with at least one
  # field that needs escape promotion (string, list, or map).
  # Used to detect when returning a borrowed struct identifier requires promoteDeep.
  # Deliberately excludes union types -- unions are handled separately via
  # struct/union literal returns and dupeUnionValue at call sites.
  private_class_method def self.struct_has_promotable_fields?(ti, schema_lookup)
    return false unless schema_lookup && ti
    resolved = ti.resolved
    schema = schema_lookup.call(resolved) rescue nil
    return false unless schema.is_a?(Hash) && !schema[:kind]  # structs only (no :kind key)
    schema.any? do |k, v|
      next false if k.is_a?(Symbol)
      ft = v.is_a?(Hash) ? v[:type] : v
      t = ft.is_a?(Type) ? ft : (Type.new(ft || :Any) rescue nil)
      next false unless t
      t.string? || t.list_collection? || t.map?
    end
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
#   - node.resource_close_zig (set by annotator)
#   - fn_node.params (TAKES params, via walk_takes_params)
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

    # 2. TAKES parameters from fn_node.params.
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

      # Heap struct string fields: heap-allocated structs dupe their string
      # fields to heap at creation. Overwriting without freeing the old leaks.
      if field_ti&.string? && !field_ti&.needs_cleanup?(schema_lookup) && target_node.is_a?(AST::Identifier)
        target_entry = bindings[target_node.name.to_s]
        if target_entry && target_entry[:alloc] == :heap
          stmt.field_pre_cleanup = { zig_type: "[]const u8", alloc: :heap }
          next
        end
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
    # AST.walk_body doesn't recurse into MethodCall/FuncCall args, so BgBlock
    # bodies used as call arguments are invisible to the visitor above.
    # Walk expression-position BgBlock bodies explicitly so variables declared
    # inside outer BG fibers (e.g. `~T[INF]` streams) are classified correctly.
    walk_expression_bg_bodies(body, promoted_fns, schema_lookup, bindings)
  end

  # Walk BgBlock bodies found in expression positions within a statement list.
  # Only handles BgBlock (outer consumer fiber), not BgStreamBlock (generator
  # fiber bodies have special YIELD handling and no heap-cleanup variables).
  private_class_method def self.walk_expression_bg_bodies(body, promoted_fns, schema_lookup, bindings)
    return unless body.is_a?(Array)
    body.each do |stmt|
      bg_bodies_from_expr(stmt).each do |bg_body|
        walk_bindings(bg_body, promoted_fns, schema_lookup, bindings)
      end
      # Recurse into control-flow containers.
      case stmt
      when AST::IfStatement
        walk_expression_bg_bodies(stmt.then_branch, promoted_fns, schema_lookup, bindings)
        walk_expression_bg_bodies(stmt.else_branch, promoted_fns, schema_lookup, bindings)
      when AST::ForRange, AST::ForEach
        walk_expression_bg_bodies(stmt.body, promoted_fns, schema_lookup, bindings)
      when AST::WhileLoop
        walk_expression_bg_bodies(stmt.do_branch, promoted_fns, schema_lookup, bindings)
      when AST::MatchStatement
        stmt.cases&.each { |c| walk_expression_bg_bodies(c[:body], promoted_fns, schema_lookup, bindings) }
        walk_expression_bg_bodies(stmt.default_case, promoted_fns, schema_lookup, bindings)
      when AST::WithBlock
        walk_expression_bg_bodies(stmt.body, promoted_fns, schema_lookup, bindings)
      end
    end
  end

  # Extract BgBlock bodies from expression-position BG blocks in a statement.
  # Returns [] if none; only BgBlock (not BgStreamBlock).
  private_class_method def self.bg_bodies_from_expr(stmt)
    result = []
    case stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      val = stmt.respond_to?(:value) ? stmt.value : nil
      result << val.body if val.is_a?(AST::BgBlock) && val.body
    when AST::MethodCall
      stmt.args&.each { |a| result << a.body if a.is_a?(AST::BgBlock) && a.body }
    when AST::FuncCall
      stmt.args&.each { |a| result << a.body if a.is_a?(AST::BgBlock) && a.body }
    end
    result
  end

  # ── Walk TAKES parameters ───────────────────────────────────────

  private_class_method def self.walk_takes_params(fn_node, schema_lookup, bindings)
    (fn_node.params || []).select { |p| p[:takes] }.each do |p|
      ti = p[:type].is_a?(Type) ? p[:type] : Type.new(p[:type] || :Any)
      name = p[:name].to_s

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
      elsif ti.list_collection?
        bindings[name] = entry(:list)
      elsif ti.map? && !ti.numeric_map?
        bindings[name] = entry(:string_map)
      elsif ti.numeric_map?
        bindings[name] = entry(:numeric_map)
      else
        # Struct with cleanup fields (strings, collections, rc refs).
        # Pass nil as node -- skips rodata optimization, conservatively adds cleanup.
        result = classify_struct_cleanup_fields(ti, nil, schema_lookup)
        bindings[name] = result if result
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
    return nil if ti.borrow_provenance?  # borrow return -- caller owns data

    classify_frozen(ti) ||
      classify_inf_stream(ti) ||
      classify_resource(ti, node) ||
      classify_collection(ti, schema_lookup) ||
      classify_array_struct_strings(ti, node, schema_lookup) ||
      classify_rc_or_link(ti, schema_lookup) ||
      classify_sync(ti) ||
      classify_heap_provenance(ti, node, schema_lookup) ||
      classify_heap_struct_plain(ti, node, schema_lookup) ||
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

  # ~T[INF] InfStream: heap-allocated generator stream requiring deinit.
  # deinit() sets closed=true and wakes the generator so it exits cleanly.
  # No moved guard: streams are not linearly-affine (requires_move? = false).
  private_class_method def self.classify_frozen(ti)
    return nil unless ti.frozen?
    entry(:frozen, alloc: :heap, has_moved_guard: false)
  end

  private_class_method def self.classify_inf_stream(ti)
    return nil unless ti.inf_stream?
    entry(:inf_stream, has_moved_guard: false)
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
    return entry(:numeric_map) if ti.numeric_map?
    return entry(:pool, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.pool?
    return entry(:set, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.set_collection?
    nil
  end

  private_class_method def self.classify_array_struct_strings(ti, node, schema_lookup)
    val = node.respond_to?(:value) ? node.value : nil
    return nil unless ti.array? && !ti.string? && !ti.collection? && val.is_a?(AST::ListLit)
    elem_schema = schema_lookup.call(ti.element_type&.resolved) rescue nil
    return nil unless elem_has_string_fields?(elem_schema)
    # Use cleanupAlloc so element cleanup handles both heap-allocated strings
    # (freed normally) and frame-allocated nested data (skipped safely, rewind
    # reclaims it). heapAlloc would crash if any field points into frame memory.
    entry(:array_with_struct_strings, alloc: :cleanup)
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
    return entry(:always_mutable) if ti.always_mutable?
    nil
  end

  private_class_method def self.classify_heap_provenance(ti, node, schema_lookup)
    return nil unless ti.heap_provenance?
    return nil if ti.any_rc? || ti.link? || ti.locked? || ti.write_locked? || ti.always_mutable?
    return nil if ti.collection? || ti.map? || ti.pool? || ti.set_collection?

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

  # Catch-all for heap pointers not handled by classify_heap_provenance.
  # Covers @alwaysMutable / @indirect annotations AND structs promoted to heap
  # by MIRPass upgrade phases (upgrade_heap_ptr_returns_to_heap! et al.) where
  # type_info.provenance is not set (only node.@storage_override is set).
  #
  # Consults the schema to choose the right cleanup kind:
  #   - struct with heap-containing fields  -> :heap_struct  (recursive deinit)
  #   - union with heap variants            -> :heap_union   (tagged deinit)
  #   - plain struct (all-primitive fields) -> :heap_struct_plain (free only)
  #
  # This makes the choice based solely on node.storage, so MIRPass upgrades do
  # NOT need to mutate type_info.provenance for struct variables.
  private_class_method def self.classify_heap_struct_plain(ti, node, schema_lookup)
    storage = node.respond_to?(:storage) ? node.storage : nil
    return nil unless storage == :heap
    return nil if ti.any_rc? || ti.link? || ti.locked? || ti.write_locked? || ti.always_mutable?
    # Primitives (f64, i64, Bool, Byte) are stack values -- never need heap cleanup
    # even if storage was incorrectly set to :heap by upstream passes.
    return nil if ti.primitive?

    # Consult schema to pick the correct cleanup kind.
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
    et = ti.element_type
    return false unless et
    # Fast path: collection/RC/sync element types always need cleanup.
    return true if et.needs_cleanup?(schema_lookup)
    # Deeper check for union/struct elements: strings in union payloads are
    # always heap-duped even without explicit heap_provenance? on the type.
    elem_schema = schema_lookup.call(et.resolved) rescue nil
    return false unless elem_schema.is_a?(Hash)
    if elem_schema[:kind] == :union
      (elem_schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
    elsif !elem_schema[:kind]  # struct
      elem_has_string_fields?(elem_schema)
    else
      false
    end
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
