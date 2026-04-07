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

class PromotionPlan
  # Per-variable promotions emitted BEFORE the return expression.
  # Each: { var: "name", zig_type: "std.ArrayListUnmanaged(i64)" }
  # Emits: try CheatLib.promote(<zig_type>, rt, &<var>);
  attr_reader :var_promotes

  # Struct-level promotion on __ret AFTER construction.
  # String (Zig type name) or nil.
  # Emits per-field promote for each unhandled_promote_fields.
  attr_reader :struct_promote

  # Field names that need promotion (unhandled by var_promotes).
  # When nil, ALL fields are promoted (backward compat for returns_promoted).
  # When set, only these fields get per-field promote calls.
  attr_reader :unhandled_promote_fields

  # Set of ReturnNode object_ids that need struct_promote.
  # When set, only returns in this set get promoteFields.
  # When nil, all returns get it (backward compat for struct returns).
  attr_reader :promote_return_ids

  # Variables whose defer cleanup must be suppressed.
  attr_reader :suppress_defers

  def initialize(var_promotes: [], struct_promote: nil, promote_return_ids: nil, suppress_defers: [], unhandled_promote_fields: nil)
    @var_promotes = var_promotes.freeze
    @struct_promote = struct_promote
    @promote_return_ids = promote_return_ids&.freeze
    @suppress_defers = suppress_defers.freeze
    @unhandled_promote_fields = unhandled_promote_fields&.freeze
  end

  # Check if a specific return node needs struct_promote.
  def needs_promote?(ret_node)
    return true if @promote_return_ids.nil?  # nil = all returns (backward compat)
    @promote_return_ids.include?(ret_node.object_id)
  end

  EMPTY = new.freeze

  def empty?
    @var_promotes.empty? && @struct_promote.nil?
  end

  # Return a filtered plan containing only the var_promotes relevant
  # to a specific return expression (variables referenced in the AST node).
  def filter_for_return(return_value)
    return self if @var_promotes.empty?

    referenced = referenced_vars(return_value)
    relevant = @var_promotes.select { |vp| referenced.include?(vp[:var]) }
    relevant_names = relevant.map { |vp| vp[:var] }

    PromotionPlan.new(
      var_promotes: relevant,
      struct_promote: @struct_promote,
      promote_return_ids: @promote_return_ids,
      suppress_defers: @suppress_defers.select { |d| relevant_names.include?(d) },
      unhandled_promote_fields: @unhandled_promote_fields,
    )
  end

  private

  def referenced_vars(node)
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

  # Compute a promotion plan for a single function.
  #
  # @param fn_node [AST::FunctionDef] the annotated function
  # @param schema_lookup [Proc] lambda(type_name_sym) -> schema hash or nil
  # @return [PromotionPlan]
  def self.compute(fn_node, schema_lookup:)
    # Gate: if the function never allocates AND isn't marked returns_promoted
    # (e.g., CATCH wrapper functions that pass through caller's frame data),
    # nothing needs promotion.
    return EMPTY unless fn_allocates?(fn_node) || fn_node.return_provenance == :heap

    ret_type_sym = fn_node.return_type
    return EMPTY unless ret_type_sym
    ret_type = ret_type_sym.is_a?(Type) ? ret_type_sym : Type.new(ret_type_sym)
    return EMPTY if ret_type.resolved == :Void

    # Strings don't need promotion (rodata or caller-frame).
    return EMPTY if ret_type.string?

    # Collect all ReturnNodes from the function body.
    return_nodes = collect_returns(fn_node.body)
    return EMPTY if return_nodes.empty?

    var_promotes = []
    suppress_defers = []
    handled_fields = Set.new
    struct_promote = nil
    promote_return_ids = Set.new

    return_nodes.each do |ret_node|
      val = ret_node.value
      next unless val

      if val.is_a?(AST::StructLit) || val.is_a?(AST::UnionVariantLit)
        # Walk struct/union fields: classify by provenance.
        val.fields.each do |fname, fval|
          fti = fval.type_info
          fti = Type.new(fti) if fti && !fti.is_a?(Type)

          # Heap-provenance fields already own their data (COPY, heap call result).
          # Rodata fields are static and never need promotion.
          # Both are "handled" — compute_struct_promote skips them.
          if fti&.heap_provenance? || fti&.rodata_provenance?
            handled_fields << fname.to_s
            next
          end

          next unless fval.is_a?(AST::Identifier)
          # Frame-provenance variables that escape need promotion.
          next unless fti&.escaped_return

          var_promotes << { var: fval.name, zig_type: fti.zig_type }
          suppress_defers << fval.name
          handled_fields << fname.to_s
        end

        # Union constructor with frame-allocated data: promote so it
        # survives frame rewind. Per-return-node: only this specific return
        # gets promoteFields. Skip when all fields are heap/rodata.
        if var_promotes.empty?
          needs_promote = val.fields.any? do |_, fval|
            fti = fval.type_info
            fti = Type.new(fti) if fti && !fti.is_a?(Type)
            # Only frame-provenance data needs promotion
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
        # Direct variable return.
        ti = val.type_info
        ti = Type.new(ti) if ti && !ti.is_a?(Type)
        # Frame-provenance data escaping via return needs promotion.
        # Heap-provenance data is already promoted; rodata never needs it.
        needs_escape = ti&.escaped_return && !ti&.heap_provenance? && !ti.string?
        if needs_escape
          if ti.list_collection? || ti.map?
            # Collections: promote in-place (they own their allocator/buffer)
            var_promotes << { var: val.name, zig_type: ti.zig_type }
            suppress_defers << val.name
          else
            # Structs: promote via __ret copy (source may be const parameter)
            struct_promote ||= zig_type_for(ret_type)
          end
        end
      end
    end

    # Struct-level promote (if not already set by bare-identifier path):
    # 1. Per-variable promotion found escaped vars AND struct has additional unhandled fields
    # 2. Function is returns_promoted (CATCH wrapper) with no per-variable escapes
    # Only apply struct_promote for struct types (not unions).
    # Union promotion is per-variable via escaped_return.
    schema = schema_lookup.call(ret_type.resolved) rescue nil
    is_union = schema.is_a?(Hash) && schema[:kind] == :union
    unhandled_fields = nil
    if struct_promote.nil?
      if var_promotes.any? || handled_fields.any?
        struct_promote, unhandled_fields = compute_struct_promote(ret_type, schema_lookup, handled_fields)
      elsif (fn_node.return_provenance == :heap) && !is_union && ret_type.needs_promotion?(schema_lookup)
        struct_promote, unhandled_fields = compute_struct_promote(ret_type, schema_lookup, handled_fields)
        # Fallback: if compute_struct_promote returns nil but returns_promoted is set,
        # all fields are already handled (CopyNode). No struct_promote needed.
      end
    end

    if var_promotes.empty? && struct_promote.nil?
      EMPTY
    else
      new(
        var_promotes: var_promotes.uniq { |vp| vp[:var] },
        struct_promote: struct_promote,
        promote_return_ids: promote_return_ids.empty? ? nil : promote_return_ids,
        suppress_defers: suppress_defers.uniq,
        unhandled_promote_fields: unhandled_fields,
      )
    end
  end

  private

  def self.fn_allocates?(fn_node)
    fn_node.uses_frame || fn_node.uses_heap || fn_node.uses_alloc
  end

  def self.collect_returns(body)
    return [] unless body
    nodes = body.is_a?(Array) ? body : [body]
    returns = []
    nodes.each do |node|
      case node
      when AST::ReturnNode
        returns << node
      when AST::IfStatement
        returns.concat(collect_returns(node.then_branch))
        returns.concat(collect_returns(node.else_branch))
      when AST::MatchStatement
        node.cases&.each { |c| returns.concat(collect_returns(c[:body])) }
        returns.concat(collect_returns(node.default_case)) if node.default_case
      else
        # Walk .body for WhileLoop, ForRange, DoBlock, WithBlock, etc.
        returns.concat(collect_returns(node.body)) if node.respond_to?(:body) && node.body
      end
    end
    returns
  end

  # Check if struct has promotable fields not already handled per-variable.
  # Returns [zig_type, unhandled_fields] or [nil, nil].
  def self.compute_struct_promote(ret_type, schema_lookup, handled_fields)
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

  def self.zig_type_for(type)
    # Strip error union (!) and optional (?) prefixes - promote operates on the payload type.
    type.resolved.to_s.sub(/^[!?]+/, '')
  end
end

# =========================================================================
# Pass C (caller side): Cleanup Planning
#
# THE SINGLE AUTHORITY for all cleanup decisions. Every defer/cleanup
# emission in the transpiler consults this plan. No re-inference.
#
# Per-binding entry:
#   needs_cleanup:  true/false       - whether a defer is emitted
#   alloc:          :heap/:frame     - which allocator
#   kind:           symbol           - drives Zig template selection
#   has_moved_guard: true/false      - whether var X_moved = false is emitted
#   source_kind:    symbol           - :local/:takes_param/:match_as/:container_borrow
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
class CleanupPlan
  attr_reader :bindings
  attr_reader :heap_temps          # Hash<FuncCall.object_id => HPT entry>
  attr_reader :field_pre_cleanups  # Hash<Assignment.object_id => { zig_type, alloc }>

  def initialize(bindings: {}, heap_temps: {}, field_pre_cleanups: {})
    @bindings           = bindings.freeze
    @heap_temps         = heap_temps.freeze
    @field_pre_cleanups = field_pre_cleanups.freeze
  end

  EMPTY = new.freeze

  # Look up the cleanup entry for a binding by name.
  def lookup(name)
    @bindings[name.to_s]
  end

  # Look up an HPT entry for a FuncCall node by object_id.
  def lookup_heap_temp(call_node_id)
    @heap_temps[call_node_id]
  end

  # Look up a field pre-cleanup entry for an Assignment node by object_id.
  def lookup_field_pre_cleanup(assignment_node_id)
    @field_pre_cleanups[assignment_node_id]
  end

  # Compute cleanup plan for a function.
  #
  # @param fn_node [AST::FunctionDef]
  # @param fn_nodes [Hash] name => FunctionDef for all functions
  # @param schema_lookup [Proc] lambda(type_sym) => schema hash
  def self.compute(fn_node, fn_nodes:, schema_lookup:)
    return EMPTY unless fn_node.body

    promoted_fns = compute_promoted_fns(fn_nodes)
    bindings = {}

    # 1. Walk all VarDecl/BindExpr in the function body.
    walk_bindings(fn_node.body, promoted_fns, schema_lookup, bindings)

    # 2. TAKES parameters from deferred_drops.
    walk_takes_params(fn_node, schema_lookup, bindings)

    # 3. MATCH AS bindings (non-Copy payloads need cleanup with _moved guard).
    walk_match_as_bindings(fn_node.body, schema_lookup, bindings)

    # 4. Heap-promoted temps: sub-expression FuncCalls with heap provenance
    #    that need hoisting into named temps with defer cleanup.
    heap_temps = {}
    walk_heap_temps(fn_node.body, schema_lookup, heap_temps)

    # 5. Field pre-cleanups: field assignments that must free the old value
    #    before overwriting. Alloc is derived from the target binding's entry.
    field_pre_cleanups = {}
    walk_field_pre_cleanups(fn_node.body, bindings, field_pre_cleanups)

    (bindings.empty? && heap_temps.empty? && field_pre_cleanups.empty?) ? EMPTY :
      new(bindings: bindings, heap_temps: heap_temps, field_pre_cleanups: field_pre_cleanups)
  end

  # Classify a heap-promoted temporary. Called internally by scan_for_hpt
  # during the walk_heap_temps pass. Not part of the public API.
  def self.classify_heap_temp(ti, schema_lookup)
    return nil unless ti
    ti = Type.new(ti) if !ti.is_a?(Type)

    if ti.string?
      return { needs_cleanup: true, alloc: :heap, kind: :heap_string, has_moved_guard: true, source_kind: :heap_temp }
    end

    resolved = ti.resolved
    schema = schema_lookup.call(resolved) rescue nil
    if schema.is_a?(Hash) && schema[:kind] == :union
      has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      if has_heap
        return { needs_cleanup: true, alloc: :heap, kind: :heap_union, has_moved_guard: true, source_kind: :heap_temp }
      end
    end

    if ti.array? && !ti.collection?
      return { needs_cleanup: true, alloc: :heap, kind: :heap_slice, has_moved_guard: true, source_kind: :heap_temp }
    end

    if schema.is_a?(Hash) && !schema[:kind]
      has_escapable = schema.any? do |k, v|
        next false if k.is_a?(Symbol)
        ft = v.is_a?(Type) ? v : Type.new(v.is_a?(Hash) ? (v[:type] || :Any) : (v || :Any))
        ft.needs_escape_promotion?
      end
      if has_escapable
        return { needs_cleanup: true, alloc: :heap, kind: :heap_struct, has_moved_guard: true, source_kind: :heap_temp }
      end
    end

    nil
  end
  private_class_method :classify_heap_temp

  private

  # ── Promoted function detection ──────────────────────────────────

  def self.compute_promoted_fns(fn_nodes)
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

  def self.body_calls_promoted?(body, promoted)
    found = false
    AST.walk_body(body) do |node|
      if node.is_a?(AST::ReturnNode) && node.value.is_a?(AST::FuncCall) && promoted.include?(node.value.name)
        found = true
      end
    end
    found
  end

  # ── Walk VarDecl / BindExpr ──────────────────────────────────────

  def self.walk_bindings(body, promoted_fns, schema_lookup, bindings)
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

  def self.walk_takes_params(fn_node, schema_lookup, bindings)
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
          has_moved_guard: true, source_kind: :takes_param,
          resource_close_zig: close_zig
        }
      elsif is_union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        if has_heap
          bindings[name] = {
            needs_cleanup: true, alloc: :heap, kind: :takes_union,
            has_moved_guard: true, source_kind: :takes_param
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

  def self.walk_match_as_bindings(body, schema_lookup, bindings)
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
            bindings[c[:binding]] = {
              needs_cleanup: true, alloc: :heap, kind: :match_as_inline_struct,
              has_moved_guard: true, source_kind: :match_as
            }
          end
        else
          pt = variant_type.is_a?(Type) ? variant_type : Type.new(variant_type || :Any)
          needs_as_cleanup = (pt.array? && !pt.string?) || pt.collection? || pt.map?
          if needs_as_cleanup && pt.array? && !pt.string?
            bindings[c[:binding]] = {
              needs_cleanup: true, alloc: :heap, kind: :match_as_slice,
              has_moved_guard: true, source_kind: :match_as
            }
          end
        end
      end
    end
  end

  # ── classify_binding: THE single decision point ─────────────────

  def self.classify_binding(name, ti, node, promoted_fns, schema_lookup)
    return nil unless ti

    # Container borrows: data owned by container, no cleanup
    if node.respond_to?(:container_borrow) && node.container_borrow
      return nil
    end

    # Escaped via return: caller takes ownership, no cleanup
    return nil if ti.escaped_return && (ti.collection? || ti.string?)

    # Resources: close on scope exit
    if node.respond_to?(:resource_close_zig) && node.resource_close_zig
      return {
        needs_cleanup: true, alloc: :heap, kind: :resource,
        has_moved_guard: true, source_kind: :local,
        resource_close_zig: node.resource_close_zig
      }
    end

    # ── Collections ────────────────────────────────────────────────

    if ti.list_collection? && !ti.sharded? && !ti.heap_provenance?
      # Check if elements need cleanup (union elements with heap variants,
      # or struct elements with string fields that were heap-duped)
      elem_type = ti.element_type
      elem_resolved = elem_type&.resolved
      elem_schema = schema_lookup.call(elem_resolved) rescue nil
      has_heap_elems = elem_schema.is_a?(Hash) && elem_schema[:kind] == :union &&
        (elem_schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
      has_heap_elems ||= elem_has_string_fields?(elem_schema)

      return {
        needs_cleanup: true, alloc: :frame, kind: has_heap_elems ? :list_with_elem_cleanup : :list,
        has_moved_guard: true, source_kind: :local,
        elem_needs_cleanup: has_heap_elems
      }
    end

    if ti.list_collection?
      return { needs_cleanup: true, alloc: :heap, kind: :list, has_moved_guard: !ti.sharded?, source_kind: :local }
    end

    if ti.map? && !ti.numeric_map?
      if ti.shared?
        return { needs_cleanup: true, alloc: :heap, kind: :rc, has_moved_guard: true, source_kind: :local }
      end
      return { needs_cleanup: true, alloc: :heap, kind: :string_map, has_moved_guard: true, source_kind: :local }
    end

    if ti.numeric_map?
      return { needs_cleanup: true, alloc: :frame, kind: :numeric_map, has_moved_guard: true, source_kind: :local }
    end

    if ti.pool?
      return { needs_cleanup: true, alloc: ti.provenance_alloc || :heap, kind: :pool, has_moved_guard: false, source_kind: :local }
    end

    if ti.set_collection?
      return { needs_cleanup: true, alloc: ti.provenance_alloc || :heap, kind: :set, has_moved_guard: false, source_kind: :local }
    end

    # ── Fixed/dynamic arrays of structs with string fields ──────
    # String fields in struct literals are heap-duped by ensure_owned_value!.
    # Without cleanup, those heap strings leak when the array goes out of scope.
    # Only applies when the RHS is a literal array construction (ListLit).
    # Pipeline results, function calls, etc. don't own the string fields.
    val = node.respond_to?(:value) ? node.value : nil
    if ti.array? && !ti.string? && !ti.collection? && val.is_a?(AST::ListLit)
      elem_type = ti.element_type
      elem_resolved = elem_type&.resolved
      elem_schema = schema_lookup.call(elem_resolved) rescue nil
      if elem_has_string_fields?(elem_schema)
        return {
          needs_cleanup: true, alloc: :heap, kind: :array_with_struct_strings,
          has_moved_guard: true, source_kind: :local
        }
      end
    end

    # ── RC / Link ─────────────────────────────────────────────────

    if ti.any_rc? || ti.link?
      return { needs_cleanup: true, alloc: :heap, kind: :rc, has_moved_guard: true, source_kind: :local }
    end

    # ── Sync (Locked / RwLocked) ──────────────────────────────────

    if ti.locked?
      return { needs_cleanup: true, alloc: :heap, kind: :locked, has_moved_guard: true, source_kind: :local }
    end
    if ti.write_locked?
      return { needs_cleanup: true, alloc: :heap, kind: :write_locked, has_moved_guard: true, source_kind: :local }
    end

    # ── Heap-provenance bindings ─────────────────────────────────
    # Unified: replaces CopyNode check, heap_promoted check, and
    # returns_promoted call check. Provenance is set by the annotator:
    #   - COPY: :heap
    #   - Call to returns_promoted function: :heap
    #   - heap_promoted propagation: :heap
    # Skip types with dedicated cleanup paths (RC, sync, collections, resources, heap-storage structs).
    # These are handled by their own classify sections below.
    heap_prov_eligible = ti.heap_provenance? &&
      !ti.any_rc? && !ti.link? && !ti.locked? && !ti.write_locked? &&
      !ti.collection? && !ti.map? && !ti.pool? && !ti.set_collection?
    storage = node.respond_to?(:storage) ? node.storage : nil
    heap_prov_eligible = false if storage == :heap  # heap_struct_plain path handles this

    if heap_prov_eligible
      if ti.string?
        return { needs_cleanup: true, alloc: :heap, kind: :heap_string, has_moved_guard: true, source_kind: :local }
      end
      if ti.array? && !ti.collection?
        return { needs_cleanup: true, alloc: :heap, kind: :heap_slice, has_moved_guard: true, source_kind: :local }
      end

      resolved = ti.resolved
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Hash) && schema[:kind] == :union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        if has_heap
          return { needs_cleanup: true, alloc: :heap, kind: :heap_union, has_moved_guard: true, source_kind: :local }
        end
      end
      if schema.is_a?(Hash) && !schema[:kind]
        has_escapable = schema.any? do |k, v|
          next false if k.is_a?(Symbol)
          ft = v.is_a?(Type) ? v : Type.new(v.is_a?(Hash) ? (v[:type] || :Any) : (v || :Any))
          ft.needs_escape_promotion?
        end
        if has_escapable
          return { needs_cleanup: true, alloc: :heap, kind: :heap_struct, has_moved_guard: true, source_kind: :local }
        end
      end
    end


    # ── Heap storage plain struct ─────────────────────────────────
    # Must come before struct_with_cleanup_fields because @alwaysMutable
    # and @indirect create *RefCell(T) / *T heap pointers. These need
    # CheatLib.free(rt, name), not CheatLib.cleanup(T, alloc, &name).

    storage = node.respond_to?(:storage) ? node.storage : nil
    is_locked_sync = ti.locked? || ti.write_locked?
    if storage == :heap && !ti.any_rc? && !is_locked_sync && !ti.link?
      return { needs_cleanup: true, alloc: :heap, kind: :heap_struct_plain, has_moved_guard: true, source_kind: :local }
    end

    # ── Struct with RC/link/string fields ─────────────────────────

    resolved = ti.resolved
    schema = schema_lookup.call(resolved) rescue nil
    if schema.is_a?(Hash) && !schema[:kind]
      # Check actual construction values: rodata string fields don't need cleanup.
      struct_lit = node.respond_to?(:value) && node.value.is_a?(AST::StructLit) ? node.value : nil
      has_cleanup_fields = schema.any? do |k, v|
        next false if k.is_a?(Symbol)
        ft = v.is_a?(Hash) ? v[:type] : v
        t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
        next true if t.link? || t.any_rc?
        if t.string?
          # Check if the actual value for this field is rodata (no cleanup needed)
          if struct_lit
            fval = struct_lit.fields[k.to_s] || struct_lit.fields[k]
            fval_ti = fval&.type_info
            fval_ti = Type.new(fval_ti) if fval_ti && !fval_ti.is_a?(Type)
            next false if fval_ti&.rodata?
          end
          next true
        end
        false
      end
      if has_cleanup_fields
        alloc = ti.provenance_alloc || :heap
        return { needs_cleanup: true, alloc: alloc, kind: :struct_with_cleanup_fields, has_moved_guard: true, source_kind: :local }
      end
    end

    # ── Non-Copy unions on stack ──────────────────────────────────

    schema = schema_lookup.call(ti.resolved) rescue nil
    if schema.is_a?(Hash) && schema[:kind] == :union
      is_copy = ti.implicitly_copyable? { |t| schema_lookup.call(t) rescue nil } rescue true
      unless is_copy
        # Use :heap when any variant holds heap data (@indirect, string, collection).
        # frameAlloc.destroy/*free are no-ops for heap pointers — must use heapAlloc.
        has_heap_variants = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        alloc = ti.provenance_alloc || (has_heap_variants ? :heap : :frame)
        return { needs_cleanup: true, alloc: alloc, kind: :non_copy_union, has_moved_guard: true, source_kind: :local }
      end
    end

    nil
  end

  # Returns true if schema is a plain struct with at least one string field.
  def self.elem_has_string_fields?(schema)
    return false unless schema.is_a?(Hash) && !schema[:kind]
    schema.any? do |k, v|
      next false if k.is_a?(Symbol)
      ft = v.is_a?(Hash) ? v[:type] : v
      t = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
      t.string?
    end
  end

  # ── HPT walk: find sub-expression FuncCalls needing heap temp hoisting ──

  def self.walk_heap_temps(body, schema_lookup, heap_temps)
    AST.walk_body(body) do |stmt|
      case stmt
      when AST::VarDecl, AST::BindExpr
        next if stmt.is_a?(AST::BindExpr) && stmt.mode == :assign
        val = stmt.value
        # OR-wrapped calls: the left FuncCall inside OR_RESCUE is the bind value
        if val.is_a?(AST::BinaryOp) && val.op == :OR_RESCUE
          scan_for_hpt(val.left, schema_lookup, heap_temps,
                       stmt_node: stmt, is_bind_value: true, inside_move: false, return_type: nil)
          scan_for_hpt(val.right, schema_lookup, heap_temps,
                       stmt_node: stmt, is_bind_value: false, inside_move: false, return_type: nil)
        else
          scan_for_hpt(val, schema_lookup, heap_temps,
                       stmt_node: stmt, is_bind_value: true, inside_move: false, return_type: nil)
        end
      when AST::ReturnNode
        next unless stmt.value
        ret_ti = stmt.value.type_info rescue nil
        ret_ti = ret_ti.is_a?(Type) ? ret_ti : nil
        scan_for_hpt(stmt.value, schema_lookup, heap_temps,
                     stmt_node: stmt, is_bind_value: false, inside_move: false, return_type: ret_ti)
      when AST::Assignment
        scan_for_hpt(stmt.value, schema_lookup, heap_temps,
                     stmt_node: stmt, is_bind_value: true, inside_move: false, return_type: nil)
      when AST::FuncCall, AST::MethodCall
        # Standalone expression statements (e.g., print(makeVal!()))
        scan_for_hpt(stmt, schema_lookup, heap_temps,
                     stmt_node: stmt, is_bind_value: false, inside_move: false, return_type: nil)
      end
    end
  end

  def self.scan_for_hpt(node, schema_lookup, heap_temps, stmt_node:, is_bind_value:, inside_move:, return_type:)
    return unless node

    case node
    when AST::FuncCall, AST::MethodCall
      ti = node.type_info rescue nil
      ti = ti.is_a?(Type) ? ti : nil
      if ti&.heap_provenance? && !is_bind_value && !node.was_moved && !inside_move
        # Direct return: ownership transfers to caller, no HPT needed.
        is_direct_return = stmt_node.is_a?(AST::ReturnNode) && stmt_node.value.equal?(node)
        unless is_direct_return
          # Unwrap error unions (try unwraps them at Zig level)
          classify_ti = (ti.error_union? && ti.payload_type) ? ti.payload_type : ti
          entry = classify_heap_temp(classify_ti, schema_lookup)
          if entry
            # Indirect return: determine how to handle the return value
            return_handling = if stmt_node.is_a?(AST::ReturnNode)
              return_type&.string? ? :dupe_string : :suppress_non_string
            end
            heap_temps[node.object_id] = entry.merge(return_handling: return_handling)
          end
        end  # unless is_direct_return
      end
      # Recurse into arguments (never bind values, not direct return values)
      args = node.is_a?(AST::MethodCall) ? node.args : node.args
      args.each do |arg|
        scan_for_hpt(arg, schema_lookup, heap_temps,
                     stmt_node: stmt_node, is_bind_value: false,
                     inside_move: inside_move, return_type: return_type)
      end
      # MethodCall: also scan the object
      if node.is_a?(AST::MethodCall)
        scan_for_hpt(node.object, schema_lookup, heap_temps,
                     stmt_node: stmt_node, is_bind_value: false,
                     inside_move: inside_move, return_type: return_type)
      end
    when AST::MoveNode
      scan_for_hpt(node.value, schema_lookup, heap_temps,
                   stmt_node: stmt_node, is_bind_value: is_bind_value,
                   inside_move: true, return_type: return_type)
    when AST::BinaryOp
      scan_for_hpt(node.left, schema_lookup, heap_temps,
                   stmt_node: stmt_node, is_bind_value: false,
                   inside_move: inside_move, return_type: return_type)
      scan_for_hpt(node.right, schema_lookup, heap_temps,
                   stmt_node: stmt_node, is_bind_value: false,
                   inside_move: inside_move, return_type: return_type)
    when AST::StructLit
      node.fields.each_value do |v|
        scan_for_hpt(v, schema_lookup, heap_temps,
                     stmt_node: stmt_node, is_bind_value: false,
                     inside_move: inside_move, return_type: return_type)
      end
    when AST::CopyNode
      scan_for_hpt(node.value, schema_lookup, heap_temps,
                   stmt_node: stmt_node, is_bind_value: false,
                   inside_move: inside_move, return_type: return_type)
    end
  end

  # ── Field pre-cleanup walk ────────────────────────────────────────
  # Finds field-assignment nodes where the old field value must be freed
  # before the new value is written. Records { zig_type, alloc } keyed by
  # node.object_id so the transpiler can look them up without re-inferring.
  #
  # The alloc is derived from the target binding's CleanupPlan entry
  # (already computed in step 1-3 of compute). If the binding uses :heap,
  # the field cleanup also uses heapAlloc; otherwise frameAlloc.
  def self.walk_field_pre_cleanups(body, bindings, field_pre_cleanups)
    AST.walk_body(body) do |stmt|
      next unless stmt.is_a?(AST::Assignment)
      next unless stmt.name.is_a?(AST::GetField)
      target_node = stmt.name.target

      field_ti = stmt.name.type_info rescue nil
      field_ti = Type.new(field_ti) if field_ti && !field_ti.is_a?(Type)
      next unless field_ti&.string? || field_ti&.list_collection?

      # Determine alloc from the target binding when possible.
      # For non-Identifier targets (e.g. arr[i].field), default to :frame.
      alloc = if target_node.is_a?(AST::Identifier)
        target_entry = bindings[target_node.name.to_s]
        (target_entry && target_entry[:alloc] == :heap) ? :heap : :frame
      else
        :frame
      end
      field_pre_cleanups[stmt.object_id] = { zig_type: field_ti.zig_type, alloc: alloc }
    end
  end
  private_class_method :walk_field_pre_cleanups
end
