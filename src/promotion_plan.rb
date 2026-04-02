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
    # Gate: if the function never allocates, nothing is frame-owned.
    return EMPTY unless fn_allocates?(fn_node)

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
        # Direct variable return: promote the variable itself.
        ti = val.type_info
        ti = Type.new(ti) if ti && !ti.is_a?(Type)
        if ti&.escaped_return && !ti.string?
          var_promotes << { var: val.name, zig_type: ti.zig_type }
          suppress_defers << val.name
        end
      end
    end

    # Struct-level promote: only when per-variable promotion found escaped vars
    # AND the struct has additional promotable fields not covered (e.g., string literals).
    # Without per-variable escapes, no collection_return → no promotion at all.
    struct_promote = if var_promotes.any?
      compute_struct_promote(ret_type, schema_lookup, handled_fields)
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
    type.resolved.to_s
  end
end
