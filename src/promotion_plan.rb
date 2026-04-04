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
  # Emits: try CheatLib.promote(<struct_promote>, rt, &__ret);
  attr_reader :struct_promote

  # Variables whose defer cleanup must be suppressed.
  attr_reader :suppress_defers

  def initialize(var_promotes: [], struct_promote: nil, suppress_defers: [])
    @var_promotes = var_promotes.freeze
    @struct_promote = struct_promote
    @suppress_defers = suppress_defers.freeze
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
      suppress_defers: @suppress_defers.select { |d| relevant_names.include?(d) },
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
    return EMPTY unless fn_allocates?(fn_node) || fn_node.returns_promoted

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

    return_nodes.each do |ret_node|
      val = ret_node.value
      next unless val

      if val.is_a?(AST::StructLit)
        # Walk struct fields: find escaped variables to promote per-variable.
        val.fields.each do |fname, fval|
          next unless fval.is_a?(AST::Identifier)
          ti = fval.type_info
          ti = Type.new(ti) if ti && !ti.is_a?(Type)
          # Only promote variables marked escaped by the annotator.
          # This ensures we only promote locally-created frame data,
          # not function call results or TAKES parameters.
          next unless ti&.escaped_return

          var_promotes << { var: fval.name, zig_type: ti.zig_type }
          suppress_defers << fval.name
          handled_fields << fname.to_s
        end

      elsif val.is_a?(AST::Identifier)
        # Direct variable return.
        ti = val.type_info
        ti = Type.new(ti) if ti && !ti.is_a?(Type)
        if ti&.escaped_return && !ti.string?
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
    struct_promote ||= if var_promotes.any?
      compute_struct_promote(ret_type, schema_lookup, handled_fields)
    elsif fn_node.returns_promoted && !is_union && ret_type.needs_promotion?(schema_lookup)
      zig_type_for(ret_type)
    end

    if var_promotes.empty? && struct_promote.nil?
      EMPTY
    else
      new(
        var_promotes: var_promotes.uniq { |vp| vp[:var] },
        struct_promote: struct_promote,
        suppress_defers: suppress_defers.uniq,
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
  def self.compute_struct_promote(ret_type, schema_lookup, handled_fields)
    resolved = ret_type.resolved
    schema = schema_lookup.call(resolved) rescue nil
    return nil unless schema.is_a?(Hash) && !schema[:kind]

    has_unhandled = schema.any? do |fname, fdef|
      next false if fname.is_a?(Symbol)
      next false if handled_fields.include?(fname.to_s)
      ft = fdef.is_a?(Type) ? fdef : Type.new(fdef.is_a?(Hash) ? (fdef[:type] || :Any) : (fdef || :Any))
      ft.needs_escape_promotion?
    end

    has_unhandled ? zig_type_for(ret_type) : nil
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

  def initialize(bindings: {})
    @bindings = bindings.freeze
  end

  EMPTY = new.freeze

  # Look up the cleanup entry for a binding by name.
  def lookup(name)
    @bindings[name.to_s]
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

    bindings.empty? ? EMPTY : new(bindings: bindings)
  end

  # Classify a heap-promoted temporary (generated during transpilation,
  # not during annotation). Uses the same classification logic as the
  # main plan but for synthetically created entries.
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

  private

  # ── Promoted function detection ──────────────────────────────────

  def self.compute_promoted_fns(fn_nodes)
    promoted = Set.new
    fn_nodes.each { |name, fn| promoted << name if fn.returns_promoted }

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
    nodes = body.is_a?(Array) ? body : [body]
    nodes.any? do |node|
      case node
      when AST::ReturnNode
        val = node.value
        val.is_a?(AST::FuncCall) && promoted.include?(val.name)
      when AST::IfStatement
        body_calls_promoted?(node.then_branch, promoted) ||
          body_calls_promoted?(node.else_branch, promoted)
      when AST::MatchStatement
        (node.cases || []).any? { |c| body_calls_promoted?(c[:body], promoted) } ||
          (node.default_case && body_calls_promoted?(node.default_case, promoted))
      else
        node.respond_to?(:body) && node.body && body_calls_promoted?(node.body, promoted)
      end
    end
  end

  # ── Walk VarDecl / BindExpr ──────────────────────────────────────

  def self.walk_bindings(body, promoted_fns, schema_lookup, bindings)
    nodes = body.is_a?(Array) ? body : [body]
    nodes.each do |node|
      case node
      when AST::VarDecl, AST::BindExpr
        # Skip reassignments (mode: :assign) - only declarations create entries
        next if node.is_a?(AST::BindExpr) && node.mode == :assign

        var_name = node.name.is_a?(String) ? node.name : node.name.to_s
        ti = node.type_info
        ti = Type.new(ti) if ti && !ti.is_a?(Type)

        cleanup = classify_binding(var_name, ti, node, promoted_fns, schema_lookup)
        bindings[var_name] = cleanup if cleanup

      when AST::IfStatement
        walk_bindings(node.then_branch, promoted_fns, schema_lookup, bindings)
        walk_bindings(node.else_branch, promoted_fns, schema_lookup, bindings)
      when AST::MatchStatement
        (node.cases || []).each { |c| walk_bindings(c[:body], promoted_fns, schema_lookup, bindings) }
        walk_bindings(node.default_case, promoted_fns, schema_lookup, bindings) if node.default_case
      when AST::WhileLoop
        walk_bindings(node.do_branch, promoted_fns, schema_lookup, bindings)
      else
        walk_bindings(node.body, promoted_fns, schema_lookup, bindings) if node.respond_to?(:body) && node.body
      end
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
    return unless body
    nodes = body.is_a?(Array) ? body : [body]
    nodes.each do |node|
      case node
      when AST::MatchStatement
        next unless node.expr.is_a?(AST::Identifier) && node.expr.was_moved

        # Resolve the union schema for the MATCH source
        source_ti = node.expr.type_info
        source_ti = Type.new(source_ti) if source_ti && !source_ti.is_a?(Type)
        union_lookup = source_ti&.generic_instance? ? source_ti.generic_base : source_ti&.resolved
        schema = schema_lookup.call(union_lookup) rescue nil
        next unless schema.is_a?(Hash) && schema[:kind] == :union

        # Determine allocator from source's cleanup_alloc
        source_alloc = source_ti&.cleanup_alloc || :frame

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

          # Classify the payload
          if variant_type.is_a?(Hash) && variant_type[:kind] == :inline_struct
            # Inline struct variant with deinit
            has_heap = Type.variant_has_heap?(variant_type)
            if has_heap
              bindings[c[:binding]] = {
                needs_cleanup: true, alloc: :heap, kind: :match_as_inline_struct,
                has_moved_guard: true, source_kind: :match_as
              }
            end
          else
            pt = variant_type.is_a?(Type) ? variant_type : Type.new(variant_type || :Any)
            # Match the annotator's move criteria (annotator.rb ~line 717):
            # slices, collections, maps need cleanup when extracted from a moved union
            needs_as_cleanup = (pt.array? && !pt.string?) || pt.collection? || pt.map?

            if needs_as_cleanup
              if pt.array? && !pt.string?
                # Always heap: slice contents are heap-allocated via COPY/promoteList.
                bindings[c[:binding]] = {
                  needs_cleanup: true, alloc: :heap, kind: :match_as_slice,
                  has_moved_guard: true, source_kind: :match_as
                }
              end
            end
          end

          # Recurse into branch body
          walk_match_as_bindings(c[:body], schema_lookup, bindings)
        end
        walk_match_as_bindings(node.default_case, schema_lookup, bindings) if node.default_case

      when AST::IfStatement
        walk_match_as_bindings(node.then_branch, schema_lookup, bindings)
        walk_match_as_bindings(node.else_branch, schema_lookup, bindings)
      when AST::WhileLoop
        walk_match_as_bindings(node.do_branch, schema_lookup, bindings)
      else
        walk_match_as_bindings(node.body, schema_lookup, bindings) if node.respond_to?(:body) && node.body
      end
    end
  end

  # ── classify_binding: THE single decision point ─────────────────

  def self.classify_binding(name, ti, node, promoted_fns, schema_lookup)
    return nil unless ti

    # COPY creates heap-allocated data. Mark as heap_promoted so the
    # binding gets cleanup regardless of the underlying type.
    if node.respond_to?(:value) && node.value.is_a?(AST::CopyNode)
      ti = Type.new(ti) if !ti.is_a?(Type)
      if ti.string?
        return { needs_cleanup: true, alloc: :heap, kind: :heap_string, has_moved_guard: true, source_kind: :local }
      end
      resolved = ti.resolved
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Hash) && schema[:kind] == :union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        return { needs_cleanup: true, alloc: :heap, kind: :heap_union, has_moved_guard: true, source_kind: :local } if has_heap
      end
      if ti.array? && !ti.collection?
        return { needs_cleanup: true, alloc: :heap, kind: :heap_slice, has_moved_guard: true, source_kind: :local }
      end
    end

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

    if ti.list_collection? && !ti.sharded? && !ti.heap_promoted
      # Check if elements need cleanup (union elements with heap variants)
      elem_type = ti.element_type
      elem_resolved = elem_type&.resolved
      elem_schema = schema_lookup.call(elem_resolved) rescue nil
      has_heap_elems = elem_schema.is_a?(Hash) && elem_schema[:kind] == :union &&
        (elem_schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }

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
      return { needs_cleanup: true, alloc: ti.cleanup_alloc || :heap, kind: :pool, has_moved_guard: false, source_kind: :local }
    end

    if ti.set_collection?
      return { needs_cleanup: true, alloc: ti.cleanup_alloc || :heap, kind: :set, has_moved_guard: false, source_kind: :local }
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

    # ── Heap-promoted bindings ────────────────────────────────────

    if ti.heap_promoted
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

    # Check if binding receives a call to a returns_promoted function
    val = node.respond_to?(:value) ? node.value : nil
    if val.is_a?(AST::FuncCall) && promoted_fns.include?(val.name)
      resolved = ti.resolved
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Hash) && schema[:kind] == :union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        if has_heap
          return { needs_cleanup: true, alloc: :heap, kind: :heap_union, has_moved_guard: true, source_kind: :local }
        end
      end
      if ti.array? && !ti.collection?
        return { needs_cleanup: true, alloc: :heap, kind: :heap_slice, has_moved_guard: true, source_kind: :local }
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
        alloc = ti.cleanup_alloc || :heap
        return { needs_cleanup: true, alloc: alloc, kind: :struct_with_cleanup_fields, has_moved_guard: true, source_kind: :local }
      end
    end

    # ── Non-Copy unions on stack ──────────────────────────────────

    schema = schema_lookup.call(ti.resolved) rescue nil
    if schema.is_a?(Hash) && schema[:kind] == :union
      is_copy = ti.implicitly_copyable? { |t| schema_lookup.call(t) rescue nil } rescue true
      unless is_copy
        alloc = ti.cleanup_alloc || :frame
        return { needs_cleanup: true, alloc: alloc, kind: :non_copy_union, has_moved_guard: true, source_kind: :local }
      end
    end

    nil
  end
end
