# typed: strict
require "sorbet-runtime"

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
    extend T::Sig

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
  sig { params(fn_node: AST::FunctionDef, schema_lookup: Proc).returns(T::Hash[Symbol, T.any(T::Array[T::Hash[Symbol, String]], T::Set[Integer])]) }
  def self.classify(fn_node, schema_lookup:)
    return {} unless fn_allocates?(fn_node) || fn_node.return_provenance == :heap || fn_has_escapable_return?(fn_node, schema_lookup)

    ret_type_sym = fn_node.return_type
    return {} unless ret_type_sym
    ret_type = ret_type_sym.is_a?(Type) ? ret_type_sym : Type.new(ret_type_sym)
    # Unwrap `!T` so the union/struct schema lookup below (and string?/Void
    # short-circuits) sees the underlying type. Post-#338, `RETURNS !Val`
    # is common; without this unwrap, schema_lookup(:!Val) misses the
    # registered :Val schema and the promote path never fires, leaving
    # frame-allocated union variant fields dangling at the caller.
    if ret_type.error_union? && ret_type.payload_type
      ret_type = ret_type.payload_type
    end
    return {} if ret_type.resolved == :Void
    return {} if ret_type.string?

    return_nodes = collect_returns(fn_node.body)
    return {} if return_nodes.empty?

    var_promotes = []
    handled_fields = Set.new
    struct_promote = T.let(nil, T.untyped)
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

          var_promotes << {
            var: fval.name,
            zig_type: fti.zig_type,
            elem_zig_type: elem_zig_type_for(fti),
          }
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
            if (us = Schemas.as_union_schema(ret_schema))
              has_heap = (us.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
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
            var_promotes << {
              var: val.name,
              zig_type: ti.zig_type,
              elem_zig_type: elem_zig_type_for(ti),
            }
          else
            struct_promote ||= zig_type_for(ret_type)
          end
        end
      end
    end

    schema = schema_lookup.call(ret_type.resolved) rescue nil
    is_union = (schema = Schemas.as_union_schema(schema))
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
  sig { params(plan: T::Hash[Symbol, T.untyped], return_value: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
  def self.filter_for_return(plan, return_value)
    return plan if plan[:var_promotes]&.empty?

    referenced = referenced_vars(return_value)
    relevant = plan[:var_promotes].select { |vp| referenced.include?(vp[:var]) }

    plan.merge(var_promotes: relevant)
  end

  # Check if a specific return node needs struct_promote.
  sig { params(plan: T::Hash[Symbol, T.untyped], ret_node: AST::ReturnNode).returns(T::Boolean) }
  def self.needs_promote?(plan, ret_node)
    return true if plan[:promote_return_ids].nil?
    plan[:promote_return_ids].include?(ret_node.object_id)
  end

  # ── Private helpers ──────────────────────────────────────────────

  sig { params(fn_node: AST::FunctionDef).returns(T.nilable(T::Boolean)) }
  private_class_method def self.fn_allocates?(fn_node)
    fn_node.uses_frame || fn_node.uses_heap || fn_node.uses_alloc
  end

  sig { params(fn_node: AST::FunctionDef, schema_lookup: T.nilable(Proc)).returns(T::Boolean) }
  private_class_method def self.fn_has_escapable_return?(fn_node, schema_lookup = nil)
    collect_returns(fn_node.body).any? do |ret|
      next false unless ret.value.is_a?(AST::Identifier)
      # TAKES params are already heap-owned; returning them doesn't require promotion.
      next false if ret.value.symbol&.takes
      ti = ret.value.full_type
      next true if ti.needs_escape_promotion? && !ti.string? && !ti.heap_provenance?
      next true if schema_lookup && !ti.string? && !ti.heap_provenance? &&
                   struct_has_promotable_fields?(ti, schema_lookup)
      false
    end
  end

  # Returns true iff `ti` is a STRUCT (not union, not primitive) with at least one
  # field that needs escape promotion (string, list, or map).
  # Used to detect when returning a borrowed struct identifier requires promoteDeep.
  # Deliberately excludes union types -- unions are handled separately via
  # struct/union literal returns and dupeUnionValue at call sites.
  sig { params(ti: Type, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.struct_has_promotable_fields?(ti, schema_lookup)
    return false unless schema_lookup && ti
    resolved = ti.resolved
    schema = schema_lookup.call(resolved) rescue nil
    return false unless (schema = Schemas.as_struct_schema(schema))
    schema.fields.any? do |_, v|
      ft = v.is_a?(Hash) ? v[:type] : v
      t = ft.is_a?(Type) ? ft : (Type.new(ft || :Any) rescue nil)
      next false unless t
      t.string? || t.list_collection? || t.map?
    end
  end

  sig { params(body: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  private_class_method def self.collect_returns(body)
    returns = []
    AST.walk_body(body) { |node| returns << node if node.is_a?(AST::ReturnNode) }
    returns
  end

  sig { params(ret_type: Type, schema_lookup: Proc, handled_fields: T::Set[String]).returns(T::Array[T.untyped]) }
  private_class_method def self.compute_struct_promote(ret_type, schema_lookup, handled_fields)
    resolved = ret_type.resolved
    schema = schema_lookup.call(resolved) rescue nil
    return [nil, nil] unless (schema = Schemas.as_struct_schema(schema))

    unhandled = []
    schema.fields.each do |fname, fdef|
      next if handled_fields.include?(fname.to_s)
      ft = fdef.is_a?(Type) ? fdef : Type.new(fdef.is_a?(Hash) ? (fdef[:type] || :Any) : (fdef || :Any))
      unhandled << fname.to_s if ft.needs_escape_promotion?
    end

    unhandled.any? ? [zig_type_for(ret_type), unhandled] : [nil, nil]
  end

  sig { params(type: Type).returns(String) }
  private_class_method def self.zig_type_for(type)
    name = type.resolved.to_s.sub(/^[!?]+/, '')
    Type.new(name).zig_type
  end

  sig { params(type: Type).returns(T.nilable(String)) }
  private_class_method def self.elem_zig_type_for(type)
    elem = type.element_type
    return nil unless elem
    Type.new(elem).zig_type
  rescue
    elem.to_s
  end

  sig { params(node: T.untyped).returns(T::Set[String]) }
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
    extend T::Sig

  # Classify all bindings in a function that need cleanup.
  #
  # @param fn_node [AST::FunctionDef]
  # @param fn_nodes [Hash] name => FunctionDef for all functions
  # @param schema_lookup [Proc] lambda(type_sym) => schema hash
  # @return [Hash] { var_name => entry_hash } or empty hash
  sig { params(fn_node: AST::FunctionDef, fn_nodes: T::Hash[String, T.untyped], schema_lookup: Proc).returns(T.nilable(T::Hash[String, T::Hash[Symbol, T.untyped]])) }
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

    # 4. WHILE bind and IF bind captures from call results (ownership-transferring).
    walk_while_bind_bindings(fn_node.body, promoted_fns, schema_lookup, bindings)
    walk_if_bind_bindings(fn_node.body, promoted_fns, schema_lookup, bindings)

    bindings
  end

  # Walk field assignments that need pre-cleanup (free old value before overwrite).
  # Stamps Assignment nodes directly with { zig_type:, alloc: }.
  sig { params(body: T::Array[T.untyped], bindings: T::Hash[String, T::Hash[Symbol, T.untyped]], schema_lookup: T.nilable(Proc)).returns(T.nilable(T::Array[T.untyped])) }
  def self.stamp_field_pre_cleanups!(body, bindings, schema_lookup: nil)
    AST.walk_body(body) do |stmt|
      next unless stmt.is_a?(AST::Assignment)
      next unless stmt.name.is_a?(AST::GetField)
      target_node = stmt.name.target

      field_ti = stmt.name.full_type

      # Auto-lock string fields: locked/always_mutable structs heap-dupe
      # string fields, so overwriting needs explicit free of the old value.
      if !field_ti&.needs_cleanup?(schema_lookup) && stmt.auto_lock && field_ti&.string?
        stmt.field_pre_cleanup = { zig_type: "[]const u8", alloc: :heap }
        next
      end

      # Heap struct string fields: heap-allocated structs dupe their string
      # fields to heap at creation. Overwriting without freeing the old leaks.
      if field_ti&.string? && !field_ti.needs_cleanup?(schema_lookup) && target_node.is_a?(AST::Identifier)
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

  sig { params(fn_nodes: T::Hash[String, T.untyped]).returns(T::Set[String]) }
  private_class_method def self.compute_promoted_fns(fn_nodes)
    promoted = Set.new
    fn_nodes.each { |name, fn| promoted << name if fn.return_provenance == :heap }

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

  sig { params(body: T::Array[T.untyped], promoted_fns: T::Set[String], schema_lookup: Proc, bindings: T::Hash[String, T::Hash[Symbol, T.untyped]]).returns(T::Array[T.untyped]) }
  private_class_method def self.walk_bindings(body, promoted_fns, schema_lookup, bindings)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)
      next if node.is_a?(AST::BindExpr) && node.mode == :assign

      var_name = node.name.is_a?(String) ? node.name : node.name.to_s
      ti = node.full_type
      cleanup = classify_binding(var_name, T.must(ti), node, promoted_fns, schema_lookup)
      # Stamp on node for identity-based lookup in lower_var_decl (avoids
      # same-name collisions when two vars share a name in different scopes).
      node.mir_binding_entry = cleanup if cleanup
      bindings[var_name] = cleanup if cleanup
    end
    # AST.walk_body doesn't recurse into MethodCall/FuncCall args, so BgBlock
    # bodies used as call arguments are invisible to the visitor above.
    # Walk expression-position BgBlock bodies explicitly so variables declared
    # inside outer BG fibers (e.g. `~T[INF]` streams) are classified correctly.
    T.must(walk_expression_bg_bodies(body, promoted_fns, schema_lookup, bindings))
  end

  # Walk BgBlock bodies found in expression positions within a statement list.
  # Only handles BgBlock (outer consumer fiber), not BgStreamBlock (generator
  # fiber bodies have special YIELD handling and no heap-cleanup variables).
  sig { params(body: T.nilable(T::Array[T.untyped]), promoted_fns: T::Set[String], schema_lookup: Proc, bindings: T::Hash[String, T::Hash[Symbol, T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
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
        stmt.cases.each { |c| walk_expression_bg_bodies(c.body, promoted_fns, schema_lookup, bindings) }
        walk_expression_bg_bodies(stmt.default_case, promoted_fns, schema_lookup, bindings)
      when AST::WithBlock
        walk_expression_bg_bodies(stmt.body, promoted_fns, schema_lookup, bindings)
      end
    end
  end

  # Extract BgBlock bodies from expression-position BG blocks in a statement.
  # Returns [] if none; only BgBlock (not BgStreamBlock).
  sig { params(stmt: T.untyped).returns(T::Array[T::Array[T.untyped]]) }
  private_class_method def self.bg_bodies_from_expr(stmt)
    result = []
    case stmt
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      val = stmt.value
      result << val.body if val.is_a?(AST::BgBlock) && val.body
    when AST::MethodCall
      stmt.args.each { |a| result << a.body if a.is_a?(AST::BgBlock) && a.body }
    when AST::FuncCall
      stmt.args.each { |a| result << a.body if a.is_a?(AST::BgBlock) && a.body }
    end
    result
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
  sig { params(fn_node: AST::FunctionDef, schema_lookup: Proc, bindings: T::Hash[String, T::Hash[Symbol, T.untyped]]).returns(T.nilable(T::Array[T::Hash[Symbol, T.untyped]])) }
  private_class_method def self.walk_takes_params(fn_node, schema_lookup, bindings)
    (fn_node.params || []).select { |p| p.takes }.each do |p|
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
  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.takes_param_base_entry(ti, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil

    # Schema-driven kinds: resource (close_zig) and union (heap variants).
    if (rs = Schemas.as_resource_schema(schema))
      return entry(:resource, resource_close_zig: rs.close_zig)
    end
    if (us = Schemas.as_union_schema(schema))
      has_heap = (us.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      return has_heap ? entry(:takes_union) : nil
    end

    return entry(:takes_string) if ti.string?

    # Collection kinds: reuse the locals classifier (covers @list, @pool,
    # @set, @sharded list, HashMap, numeric map, fixed_soa, RC-wrapped maps).
    coll = classify_collection(ti, schema_lookup)
    return coll if coll

    # Plain slice (Int64[] without a collection modifier).
    return entry(:takes_slice) if ti.array? && !ti.string?

    # Struct fallback (strings/collections/rc as fields).
    classify_struct_cleanup_fields(ti, nil, schema_lookup)
  end

  # ── Walk MATCH AS bindings ──────────────────────────────────────

  sig { params(body: T::Array[T.untyped], schema_lookup: Proc, bindings: T::Hash[String, T::Hash[Symbol, T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  private_class_method def self.walk_match_as_bindings(body, schema_lookup, bindings)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::MatchStatement)
      next unless node.expr.is_a?(AST::Identifier) && node.expr.was_moved

      source_ti = node.expr.full_type
      union_lookup = source_ti.generic_instance? ? source_ti.generic_base : source_ti.resolved
      schema = schema_lookup.call(union_lookup) rescue nil
      next unless (schema = Schemas.as_union_schema(schema))

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

        if variant_type.is_a?(Hash) && variant_type[:kind] == :inline_struct
          has_heap = Type.variant_has_heap?(variant_type)
          if has_heap
            union_zig = Type.new(union_lookup).zig_type rescue union_lookup.to_s
            bindings[c.binding] = {
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
          pt = variant_type.is_a?(Type) ? variant_type : Type.new(variant_type)
          if pt.array? && !pt.string?
            elem_zig = pt.element_type ? (Type.new(pt.element_type).zig_type rescue pt.element_type.to_s) : "UNKNOWN"
            bindings[c.binding] = {
              needs_cleanup: true, alloc: :heap, kind: :match_as_slice,
              has_moved_guard: true, match_as: true,
              elem_zig_type: elem_zig
            }
          elsif pt.collection? || pt.map?
            zig_type = pt.zig_type rescue pt.resolved.to_s
            bindings[c.binding] = {
              needs_cleanup: true, alloc: :heap, kind: pt.map? ? :string_map : :list,
              has_moved_guard: true, match_as: true,
              zig_type: zig_type
            }
          end
        end
      end
    end
  end

  # Classify WHILE bind captures that come from ownership-transferring calls.
  # Only MethodCall/FuncCall results are considered: variable/field access is a
  # borrow and the original binding retains cleanup responsibility.
  # RESOLVE is handled separately (rcRelease in lower_while_bind).
  sig { params(body: T::Array[T.untyped], promoted_fns: T::Set[String], schema_lookup: Proc, bindings: T::Hash[String, T::Hash[Symbol, T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  private_class_method def self.walk_while_bind_bindings(body, promoted_fns, schema_lookup, bindings)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::WhileBindLoop)
      cond = node.condition
      next unless cond.is_a?(AST::MethodCall) || cond.is_a?(AST::FuncCall)
      next if cond.is_a?(AST::ResolveNode)
      ti = cond.full_type
      inner_ti = ti.wrapped_type
      next unless inner_ti
      e = classify_binding(node.binding_name.to_s, inner_ti, node, promoted_fns, schema_lookup)
      next unless e
      e[:zig_type] ||= (Type.new(inner_ti.resolved).zig_type rescue inner_ti.resolved.to_s)
      if inner_ti.element_type
        e[:elem_zig_type] ||= (Type.new(inner_ti.element_type).zig_type rescue "UNKNOWN")
      end
      bindings[node.binding_name.to_s] = e
    end
  end

  # Classify IF bind captures that come from ownership-transferring calls.
  sig { params(body: T::Array[T.untyped], promoted_fns: T::Set[String], schema_lookup: Proc, bindings: T::Hash[String, T::Hash[Symbol, T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  private_class_method def self.walk_if_bind_bindings(body, promoted_fns, schema_lookup, bindings)
    AST.walk_body(body) do |node|
      next unless node.is_a?(AST::IfBind)
      node.bindings.each do |b|
        expr = b[:expr]
        next unless expr.is_a?(AST::MethodCall) || expr.is_a?(AST::FuncCall)
        next if expr.is_a?(AST::ResolveNode)
        ti = expr.full_type
        inner_ti = ti.wrapped_type
        next unless inner_ti
        e = classify_binding(b[:name].to_s, inner_ti, node, promoted_fns, schema_lookup)
        next unless e
        e[:zig_type] ||= (Type.new(inner_ti.resolved).zig_type rescue inner_ti.resolved.to_s)
        if inner_ti.element_type
          e[:elem_zig_type] ||= (Type.new(inner_ti.element_type).zig_type rescue "UNKNOWN")
        end
        bindings[b[:name].to_s] = e
      end
    end
  end

  # ── classify_binding: dispatch pipeline ─────────────────────────
  #
  # Each classify_* method handles one cleanup category, returning a
  # cleanup entry hash or nil. Order matters: earlier categories take
  # priority (e.g. resource before collection, RC before sync).

  sig { params(name: String, ti: Type, node: T.untyped, promoted_fns: T::Set[String], schema_lookup: Proc).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_binding(name, ti, node, promoted_fns, schema_lookup)
    return nil unless ti
    return nil if node.container_borrow
    return nil if ti.borrow_provenance?  # borrow return -- caller owns data

    sync = node.respond_to?(:symbol) ? node.symbol&.sync : nil

    classify_observable(ti) ||
      classify_frozen(ti) ||
      classify_inf_stream(ti) ||
      classify_resource(ti, node) ||
      classify_collection(ti, schema_lookup) ||
      classify_array_struct_strings(ti, node, schema_lookup) ||
      classify_atomic_ptr(ti) ||
      classify_rc_or_link(ti, schema_lookup) ||
      classify_sync(ti, sync) ||
      classify_heap_provenance(ti, node, schema_lookup, sync) ||
      classify_heap_struct_plain(ti, node, schema_lookup, sync) ||
      classify_struct_cleanup_fields(ti, node, schema_lookup) ||
      classify_non_copy_union(ti, schema_lookup)
  end

  # AtomicPtr M3 / review item J: dedicated cleanup kind for
  # `@indirect:atomic` cells. Without this branch the binding
  # falls into classify_rc_or_link (because M3.5 auto-promotes
  # ownership=:shared, making any_rc? true) and gets a `:rc`
  # entry whose rc_variant / rc_release_func fields are unused
  # for atomic-ptr -- the actual cleanup is dispatched in the
  # runtime cleanup() shim via @hasDecl(child, "compareAndPublish").
  # Routing here avoids the misnomer and the unused entry fields.
  # Fires BEFORE classify_rc_or_link so atomic-ptr beats the
  # generic shared-Arc path.
  sig { params(ti: Type).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_atomic_ptr(ti)
    return nil unless ti.respond_to?(:atomic?) && ti.atomic?
    return nil unless ti.respond_to?(:indirect?) && ti.indirect?
    entry(:atomic_ptr, alloc: :heap)
  end

  # ── Individual classifiers ───────────────────────────────────────

  sig { params(kind: Symbol, alloc: Symbol, has_moved_guard: T::Boolean, extra: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
  private_class_method def self.entry(kind, alloc: :heap, has_moved_guard: true, **extra)
    { needs_cleanup: true, alloc: alloc, kind: kind,
      has_moved_guard: has_moved_guard, **extra }
  end

  sig { params(_ti: Type, node: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_resource(_ti, node)
    return nil unless node.respond_to?(:resource_close_zig) && node.resource_close_zig
    entry(:resource, resource_close_zig: node.resource_close_zig)
  end

  # ~T@observable / ~T[]@set:observable: heap-allocated
  # `*Observable<Terminal>(T)` produced by a streaming-aggregate fold
  # over a tense source. The accumulator outlives the producer fiber
  # and is destroyed at the binding's scope exit. Cleanup calls
  # `wait()` (parks on the producer fiber's WaitGroup until `finish()`
  # is published) before `destroy()` to avoid racing the fiber.
  # `ObservableTerminal.destroy` itself comptime-detects whether the
  # Inner has a `deinit()` (StreamSet does; the scalar atomics don't)
  # and calls it before freeing self -- one cleanup recipe handles all
  # terminal shapes. No moved guard: NEXT/COLLECT only read the inner
  # value; the heap pointer always belongs to the binding.
  sig { params(ti: Type).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_observable(ti)
    return nil unless ti.tense_observable?
    return nil if ti.promise_list?
    entry(:observable, alloc: :heap, has_moved_guard: false)
  end

  # ~T[INF] InfStream: heap-allocated generator stream requiring deinit.
  # deinit() sets closed=true and wakes the generator so it exits cleanly.
  # No moved guard: streams are not linearly-affine (requires_move? = false).
  sig { params(ti: Type).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_frozen(ti)
    return nil unless ti.frozen?
    entry(:frozen, alloc: :heap, has_moved_guard: false)
  end

  sig { params(ti: Type).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_inf_stream(ti)
    return nil unless ti.inf_stream?
    entry(:inf_stream, has_moved_guard: false)
  end

  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_collection(ti, schema_lookup)
    # Group 1 / Group 2 separation: when a collection is wrapped with
    # Arc/Rc ownership, the cleanup is `arcRelease` / `rcRelease` — which
    # cascades through the wrapper down to the inner data shape's deinit.
    # Defer to classify_rc_or_link instead of emitting a bare-shape
    # `pool.deinit()` / `list.deinit()` / etc. against the outer wrapper.
    return nil if ti.any_rc?

    # T[N]@soa: fixed SOA array backed by SoaList — needs deinit like a list.
    return entry(:fixed_soa, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.fixed_soa?
    if ti.list_collection? && !ti.sharded? && !ti.heap_provenance?
      has_heap_elems = elem_needs_cleanup?(ti, schema_lookup)
      return entry(has_heap_elems ? :list_with_elem_cleanup : :list,
                   alloc: :frame, elem_needs_cleanup: has_heap_elems)
    end
    return entry(:list, has_moved_guard: !ti.sharded?) if ti.list_collection?
    return entry(:string_map) if ti.map? && !ti.numeric_map?
    return entry(:numeric_map) if ti.numeric_map?
    return entry(:pool, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.pool?
    return entry(:set, alloc: ti.provenance_alloc || :heap, has_moved_guard: false) if ti.set_collection?
    nil
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_array_struct_strings(ti, node, schema_lookup)
    # `node` is the originating AST node for the binding being classified.
    # For VarDecl/BindExpr this is the declaration (which has a `.value`
    # RHS); for IF-bind / WHILE-bind captures it's the binding statement
    # itself (no `.value` accessor — the captured expression lives inside
    # `bindings[:expr]` / `condition`). Guard with respond_to? so non-decl
    # callers don't crash.
    val = node.respond_to?(:value) ? node.value : nil
    return nil unless ti.array? && !ti.string? && !ti.collection? && val.is_a?(AST::ListLit)
    elem_schema = schema_lookup.call(ti.element_type&.resolved) rescue nil
    return nil unless elem_has_string_fields?(elem_schema)
    # Use cleanupAlloc so element cleanup handles both heap-allocated strings
    # (freed normally) and frame-allocated nested data (skipped safely, rewind
    # reclaims it). heapAlloc would crash if any field points into frame memory.
    entry(:array_with_struct_strings, alloc: :cleanup)
  end

  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
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
        if (schema = Schemas.as_struct_schema(schema))
          e[:needs_release_fields] = true
          e[:base_zig] = base_zig
        end
      end
      e
    end
  end

  sig { params(ti: Type, sync: T.nilable(Symbol)).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_sync(ti, sync = nil)
    return entry(:locked) if sync == :locked
    return entry(:write_locked) if sync == :write_locked
    return entry(:always_mutable) if sync == :always_mutable
    return entry(:versioned) if sync == :versioned
    nil
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc, sync: T.nilable(Symbol)).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_heap_provenance(ti, node, schema_lookup, sync = nil)
    return nil unless ti.heap_provenance?
    return nil if ti.any_rc? || ti.link? || sync == :locked || sync == :write_locked || sync == :always_mutable || sync == :versioned
    return nil if ti.collection?

    return entry(:heap_string) if ti.string?
    return entry(:heap_slice) if ti.array? && !ti.collection?

    schema = schema_lookup.call(ti.resolved) rescue nil
    if (us = Schemas.as_union_schema(schema))
      has_heap = (us.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      return entry(:heap_union) if has_heap
    end
    if (ss = Schemas.as_struct_schema(schema))
      has_escapable = ss.fields.any? do |_, v|
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
  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc, sync: T.nilable(Symbol)).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_heap_struct_plain(ti, node, schema_lookup, sync = nil)
    storage = node.respond_to?(:storage) ? node.storage : nil
    return nil unless storage == :heap
    return nil if ti.any_rc? || ti.link? || sync == :locked || sync == :write_locked || sync == :always_mutable || sync == :versioned
    # Primitives (f64, i64, Bool, Byte) are stack values -- never need heap cleanup
    # even if storage was incorrectly set to :heap by upstream passes.
    return nil if ti.primitive?

    # Consult schema to pick the correct cleanup kind.
    schema = schema_lookup.call(ti.resolved) rescue nil
    if (us = Schemas.as_union_schema(schema))
      has_heap = (us.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      return entry(:heap_union) if has_heap
    end
    if (ss = Schemas.as_struct_schema(schema))
      has_escapable = ss.fields.any? do |_, v|
        ft = v.is_a?(Type) ? v : Type.new(v.is_a?(Hash) ? (v[:type] || :Any) : (v || :Any))
        ft.needs_escape_promotion?
      end
      return entry(:heap_struct) if has_escapable
    end

    entry(:heap_struct_plain)
  end

  sig { params(ti: Type, node: T.untyped, schema_lookup: Proc).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  private_class_method def self.classify_struct_cleanup_fields(ti, node, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil
    return nil unless (schema = Schemas.as_struct_schema(schema))

    # Same `node` shape concerns as classify_array_struct_strings: WHILE-bind /
    # IF-bind capture nodes don't carry `.value`; only VarDecl/BindExpr do.
    struct_lit = node.respond_to?(:value) && node.value.is_a?(AST::StructLit) ? node.value : nil
    has_cleanup = schema.fields.any? do |k, v|
      ft = v.is_a?(Hash) ? v[:type] : v
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      next true if t.link? || t.any_rc?
      next true if t.collection? || t.map?
      next false unless t.string?
      # Rodata string fields don't need cleanup
      if struct_lit
        fval = struct_lit.fields[k.to_s] || struct_lit.fields[k]
        fval_ti = fval&.full_type
        fval_ti = Type.new(fval_ti) if fval_ti && !fval_ti.is_a?(Type)
        next false if fval_ti.is_a?(Type) && fval_ti.rodata?
      end
      true
    end
    return nil unless has_cleanup
    entry(:struct_with_cleanup_fields, alloc: ti.provenance_alloc || :heap)
  end

  sig { params(ti: Type, schema_lookup: Proc).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  private_class_method def self.classify_non_copy_union(ti, schema_lookup)
    schema = schema_lookup.call(ti.resolved) rescue nil
    return nil unless (schema = Schemas.as_union_schema(schema))
    is_copy = ti.implicitly_copyable? { |t| schema_lookup.call(t) rescue nil } rescue true
    return nil if is_copy
    has_heap_variants = (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
    alloc = has_heap_variants ? :heap : (ti.provenance_alloc || :frame)
    entry(:non_copy_union, alloc: alloc)
  end

  # ── Schema helpers ───────────────────────────────────────────────

  sig { params(ti: Type, schema_lookup: Proc).returns(T::Boolean) }
  private_class_method def self.elem_needs_cleanup?(ti, schema_lookup)
    et = ti.element_type
    return false unless et
    # Fast path: collection/RC/sync element types always need cleanup.
    return true if et.needs_cleanup?(schema_lookup)
    # Deeper check for union/struct elements: strings in union payloads are
    # always heap-duped even without explicit heap_provenance? on the type.
    elem_schema = schema_lookup.call(et.resolved) rescue nil
    if (us = Schemas.as_union_schema(elem_schema))
      (us.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
    elsif (ss = Schemas.as_struct_schema(elem_schema))
      elem_has_string_fields?(ss)
    else
      false
    end
  end

  sig { params(schema: T.untyped).returns(T::Boolean) }
  private_class_method def self.elem_has_string_fields?(schema)
    return false unless (schema = Schemas.as_struct_schema(schema))
    schema.fields.any? do |_, v|
      ft = v.is_a?(Hash) ? v[:type] : v
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      t.string?
    end
  end

end
