require_relative "type"

# Pass C: Escape Promotion Planning
#
# Computed after annotation (full type + ownership info available).
# Produces a concrete plan per function that the transpiler executes
# mechanically with zero decisions.
#
# Zig's CheatLib.promote(T, rt, &x) handles the type-specific logic:
#   ArrayList  → promoteList (dupes .items to heap)
#   StringMap  → .alloc = heapAlloc (O(1) pointer swap)
#   String     → heapAlloc.dupe (O(N) copy)
#   Struct     → recurse fields
#   Union      → promote active variant
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
  # @param schema_lookup [Proc] lambda(type_name_sym) → schema hash or nil
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

# Pass C (caller side): Cleanup Planning
#
# For each function, decides which local bindings need defer cleanup
# and with what allocator. Replaces the decision logic in emit_cleanup
# (ownership_generator.rb) with a testable, declarative plan.
#
# The plan answers: "does this binding ever hold heap data that must be freed?"
# It uses:
#   - Type information (collection?, map?, rc?, etc.)
#   - Call graph (does the binding receive a returns_promoted call result?)
#   - Schema lookup (does the union/struct have heap variants?)

class CleanupPlan
  # Hash of var_name => { alloc: :heap/:frame, kind: symbol }
  attr_reader :bindings

  def initialize(bindings: {})
    @bindings = bindings.freeze
  end

  EMPTY = new.freeze

  # Compute cleanup plan for a function.
  #
  # @param fn_node [AST::FunctionDef]
  # @param fn_nodes [Hash] name => FunctionDef for all functions (for returns_promoted lookup)
  # @param schema_lookup [Proc] lambda(type_sym) => schema hash
  def self.compute(fn_node, fn_nodes:, schema_lookup:)
    return EMPTY unless fn_node.body

    # Build set of function names that return promoted data (transitively).
    promoted_fns = compute_promoted_fns(fn_nodes)

    bindings = {}

    # Walk all declarations and assignments in the function body.
    walk_bindings(fn_node.body, promoted_fns, schema_lookup, bindings)

    bindings.empty? ? EMPTY : new(bindings: bindings)
  end

  private

  # Compute the transitive closure of returns_promoted functions.
  def self.compute_promoted_fns(fn_nodes)
    promoted = Set.new
    fn_nodes.each { |name, fn| promoted << name if fn.returns_promoted }

    # Transitive: if fn returns a call to a promoted fn, fn is also promoted.
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

  # Check if a function body has a RETURN of a call to a promoted function.
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

  # Walk function body, find bindings that need cleanup.
  def self.walk_bindings(body, promoted_fns, schema_lookup, bindings)
    nodes = body.is_a?(Array) ? body : [body]
    nodes.each do |node|
      case node
      when AST::VarDecl, AST::BindExpr
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

  # Decide if a binding needs cleanup and with what allocator.
  # Returns { alloc: :heap/:frame, kind: symbol } or nil.
  def self.classify_binding(name, ti, node, promoted_fns, schema_lookup)
    return nil unless ti

    # Container borrows: no cleanup — the container owns the data.
    return nil if ti.container_borrow

    # Escaped via return — cleanup suppressed (caller takes ownership)
    return nil if ti.escaped_return && (ti.collection? || ti.string?)

    # Resource: handled separately by emit_cleanup (not in plan yet)
    return nil if node.respond_to?(:resource_close_zig) && node.resource_close_zig

    # Collections: always need cleanup
    return { alloc: :frame, kind: :list } if ti.list_collection? && !ti.sharded? && !ti.heap_promoted
    return { alloc: :heap, kind: :list } if ti.list_collection?
    return { alloc: :heap, kind: :string_map } if ti.map? && !ti.numeric_map?
    return { alloc: :heap, kind: :numeric_map } if ti.numeric_map?
    return { alloc: :heap, kind: :pool } if ti.pool?
    return { alloc: :heap, kind: :set } if ti.set_collection?

    # RC/link: always need cleanup
    return { alloc: :heap, kind: :rc } if ti.any_rc? || ti.link?

    # Sync (locked/write_locked)
    return { alloc: :heap, kind: :locked } if ti.locked?
    return { alloc: :heap, kind: :write_locked } if ti.write_locked?

    # Heap-promoted bindings (from returns_promoted callee)
    if ti.heap_promoted
      return { alloc: :heap, kind: :heap_string } if ti.string?
      return { alloc: :heap, kind: :heap_slice } if ti.array? && !ti.collection?
      # Union/struct with heap data
      resolved = ti.resolved
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Hash) && schema[:kind] == :union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        return { alloc: :heap, kind: :heap_union } if has_heap
      end
      if schema.is_a?(Hash) && !schema[:kind]
        has_escapable = schema.any? do |k, v|
          next false if k.is_a?(Symbol)
          ft = v.is_a?(Type) ? v : Type.new(v.is_a?(Hash) ? (v[:type] || :Any) : (v || :Any))
          ft.needs_escape_promotion?
        end
        return { alloc: :heap, kind: :heap_struct } if has_escapable
      end
    end

    # Check if binding receives a call to a returns_promoted function
    # (even if heap_promoted wasn't set by walk_promote_callers)
    val = node.respond_to?(:value) ? node.value : nil
    if val.is_a?(AST::FuncCall) && promoted_fns.include?(val.name)
      resolved = ti.resolved
      schema = schema_lookup.call(resolved) rescue nil
      if schema.is_a?(Hash) && schema[:kind] == :union
        has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        return { alloc: :heap, kind: :heap_union } if has_heap
      end
      return { alloc: :heap, kind: :heap_slice } if ti.array? && !ti.collection?
    end

    # Struct with RC/link fields
    resolved = ti.resolved
    schema = schema_lookup.call(resolved) rescue nil
    if schema.is_a?(Hash) && !schema[:kind]
      has_rc = schema.any? do |k, v|
        next false if k.is_a?(Symbol)
        ft = v.is_a?(Type) ? v : Type.new(v.is_a?(Hash) ? (v[:type] || :Any) : (v || :Any))
        ft.link? || ft.any_rc?
      end
      return { alloc: :heap, kind: :struct_rc } if has_rc
    end

    # Heap storage plain struct
    storage = node.respond_to?(:storage) ? node.storage : nil
    if storage == :heap && !ti.any_rc? && !ti.any_sync? && !ti.link?
      return { alloc: :heap, kind: :heap_struct_plain }
    end

    nil
  end
end
