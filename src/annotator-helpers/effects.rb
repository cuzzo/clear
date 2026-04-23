require 'set'

# EffectTracker — Silent effect tracking for CLEAR functions.
#
# Tracks which side-effects each function can produce, both directly
# and transitively through the call graph.  This is infrastructure for
# the future STRICT mode / #HOT annotation system.
#
# Effects are computed in two phases:
#   1. Direct collection (during visit_* methods in pass 3)
#   2. Transitive propagation (fixed-point over @call_graph, after pass 5b)
#
# The result is stored on each FunctionDef node as `node.effects` (a frozen Set).
#
# Also includes reentrancy analysis helpers (scan_for_calls,
# check_indirect_reentrancy!, scan_for_raises) since reentrancy is
# both an effect and a call-graph property.
module EffectTracker
  # Core effect constants.
  HEAP         = :HEAP
  BLOCKING     = :BLOCKING
  REENTRANT    = :REENTRANT
  LOOP_UNBOUND = :LOOP_UNBOUND
  EXTERN       = :EXTERN

  ALL_EFFECTS = [HEAP, BLOCKING, REENTRANT, LOOP_UNBOUND, EXTERN].freeze

  # --- Phase 1: Direct collection ---

  def effects_init!
    @fn_direct_effects = {}   # fn_name => Set of direct effect symbols
  end

  # Called at the start of visit_FunctionDef to prepare a fresh effect set.
  def effects_begin_function(fn_name)
    @fn_direct_effects[fn_name] = Set.new
  end

  # Record a direct effect for the function currently being analyzed.
  def record_effect(effect)
    return unless current_fn_ctx&.name
    @fn_direct_effects[current_fn_ctx.name]&.add(effect)
  end

  # --- Phase 2: Transitive propagation ---

  # Fixed-point propagation through @call_graph.
  # Follows the same pattern as compute_needs_rt! and compute_can_fail!.
  def compute_effects!
    # Seed from direct effects.
    resolved = {}
    @fn_direct_effects.each { |name, effs| resolved[name] = effs.dup }

    # Propagate: if foo calls bar, foo inherits bar's effects.
    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        current = resolved[fn_name] ||= Set.new
        callees.each do |callee|
          callee_effs = resolved[callee]
          next unless callee_effs
          before = current.size
          current.merge(callee_effs)
          changed = true if current.size > before
        end
      end
    end

    # Store frozen effect sets on FunctionDef nodes.
    @fn_nodes.each do |name, fn_node|
      fn_node.effects = (resolved[name] || Set.new).freeze
    end
  end

  # --- Call-graph fixed-point passes ---

  # Post-pass: compute needs_rt for every function.
  # A function needs rt if it uses the frame arena, calls a fn pointer, or any
  # transitive callee needs rt. main always needs rt (entry point).
  def compute_needs_rt!
    needs_rt = {}
    @fn_nodes.each do |name, fn_node|
      ret_type = fn_node.full_type.is_a?(Type) ? fn_node.full_type[:return]&.dig(:type) : nil
      heap_return = ret_type.is_a?(Type) && (ret_type.heap? || ret_type.dynamic?)
      has_takes_heap = fn_node.params&.any? { |p|
        next unless p[:takes]
        ti = Type.new(p[:type] || :Any)
        ti.string? || ti.array? || ti.list_collection? || ti.map?
      }
      has_catch = fn_node.catch_clauses.is_a?(Array) && fn_node.catch_clauses.any?
      has_raise = @fn_raises_directly[name]
      needs_rt[name] = fn_node.uses_frame || fn_node.uses_heap || fn_node.uses_alloc || heap_return || (@fn_has_fnptr[name] == true) || has_takes_heap || has_catch || has_raise || name == "main"
    end

    # Seed imported (cross-module) functions: if a callee is not a local function
    # but is imported with needs_rt=true, include it so propagation works.
    @call_graph.each do |_, callees|
      callees.each do |c|
        next if needs_rt.key?(c)
        scope = lookup_scope_for(c)
        next unless scope
        sig = scope.locals[c]&.type
        sig = sig.is_a?(FunctionSignature) ? sig : nil
        needs_rt[c] = true if sig&.needs_rt
      end
    end

    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        next if needs_rt[fn_name]
        if callees.any? { |c| needs_rt[c] }
          needs_rt[fn_name] = true
          changed = true
        end
      end
    end

    @fn_nodes.each do |name, fn_node|
      fn_node.needs_rt = (needs_rt[name] == true)
    end
  end

  # Post-pass: compute can_fail for every function.
  # A function can fail if it has direct failure sources (Raise/OrRaise, frame alloc,
  # fn pointer call, @nonReentrant StackGuard try) or any transitive callee can fail.
  # main always can_fail (entry point). Callees not in @fn_nodes (stdlib/extern)
  # are excluded from propagation — they don't use CLEAR's error union convention.
  def compute_can_fail!
    can_fail = {}
    @fn_nodes.each do |name, _|
      can_fail[name] = @fn_raises_directly[name] == true || name == "main"
    end

    # Seed imported (cross-module) functions that can fail.
    @call_graph.each do |_, callees|
      callees.each do |c|
        next if can_fail.key?(c)
        scope = lookup_scope_for(c)
        next unless scope
        sig = scope.locals[c]&.type
        sig = sig.is_a?(FunctionSignature) ? sig : nil
        can_fail[c] = true if sig&.can_fail
      end
    end

    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        next if can_fail[fn_name]
        if callees.any? { |c| can_fail[c] }
          can_fail[fn_name] = true
          changed = true
        end
      end
    end

    @fn_nodes.each do |name, fn_node|
      fn_node.can_fail = (can_fail[name] == true)
    end
  end

  # PASS 5b: scan all AST nodes for Identifiers used as fn-type arguments.
  # Any named function referenced as a value must adopt the rt-bearing calling
  # convention (*Runtime, params) !return — mark it needs_rt=true and can_fail=true.
  def mark_fn_value_references!(program_node)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FuncCall, AST::MethodCall
        n.args&.each do |arg|
          arg_ft = arg.respond_to?(:full_type) ? arg.full_type : nil
          if arg.is_a?(AST::Identifier) && arg_ft.is_a?(Type) && arg_ft.fn_type?
            fn = @fn_nodes[arg.name]
            if fn
              fn.needs_rt = true
              fn.can_fail  = true
            end
          end
          traverse.call(arg)
        end
        traverse.call(n.respond_to?(:object) ? n.object : nil)
      when AST::VarDecl, AST::BindExpr
        traverse.call(n.value)
      when AST::ReturnNode
        traverse.call(n.value)
      when AST::FunctionDef
        traverse.call(n.body)
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(program_node.statements)
  end

  # --- Stack tier recommendation ---
  #
  # Maps each function's effect set + stack variable usage to a fiber stack tier.
  # The tier is a lower bound: the runtime control plane can upsize adaptively.
  #
  # Tiers:
  #   :micro    (4 KB)   - pure compute, no allocations, no blocking
  #   :standard (16 KB)  - heap allocations, extern calls, moderate locals
  #   :large    (64 KB)  - recursive functions, deep call chains
  #   :xl       (256 KB) - recursive + heap-heavy
  #   :service  (2 MB)   - reentrant functions (auto-assigned when call chain is unbounded)
  #
  STACK_TIER_BUDGET = { micro: 4096, standard: 16384, large: 65536, xl: 262144, service: 2_097_152 }.freeze

  def compute_stack_tiers!
    # Phase 1: assign base tier per function from its own effects.
    @fn_nodes.each do |name, fn_node|
      effs = fn_node.effects || Set.new
      stack_bytes = fn_node.stack_vars_bytes || 0

      # Reentrant functions are :unbounded - their total stack is depth * frame_size.
      if fn_node.reentrant == :reentrant
        fn_node.stack_tier = :unbounded
        fn_node.stack_vars_bytes = stack_bytes
        next
      end

      tier = if effs.include?(HEAP) || effs.include?(BLOCKING) || effs.include?(EXTERN)
        :standard
      elsif fn_node.needs_rt
        :standard
      else
        :micro
      end

      # Promote tier if stack-local variables alone exceed the tier budget.
      budget = STACK_TIER_BUDGET[tier]
      while stack_bytes > budget / 2 && tier != :xl
        tier = case tier
               when :micro    then :standard
               when :standard then :large
               when :large    then :xl
               else :xl
               end
        budget = STACK_TIER_BUDGET[tier]
      end

      fn_node.stack_tier = tier
      fn_node.stack_vars_bytes = stack_bytes
    end

    # Phase 2: propagate :unbounded through call graph.
    # Any function that transitively calls an :unbounded function is also :unbounded.
    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        fn = @fn_nodes[fn_name]
        next unless fn
        next if fn.stack_tier == :unbounded
        if callees.any? { |c| @fn_nodes[c]&.stack_tier == :unbounded }
          fn.stack_tier = :unbounded
          changed = true
        end
      end
    end
  end

  # Compute the maximum stack tier needed by a set of function names,
  # following the call graph transitively. :unbounded propagates.
  TIER_ORDER = { micro: 0, standard: 1, large: 2, xl: 3, service: 4, unbounded: 5 }.freeze

  def max_tier_for_calls(fn_names)
    visited = Set.new
    max = :micro
    queue = fn_names.to_a.dup

    until queue.empty?
      name = queue.shift
      next if visited.include?(name)
      visited << name

      fn = @fn_nodes[name]
      if fn&.stack_tier
        max = fn.stack_tier if TIER_ORDER.fetch(fn.stack_tier, 0) > TIER_ORDER.fetch(max, 0)
      end

      (@call_graph[name] || []).each { |callee| queue << callee }
    end

    max
  end

  # --- Queries (for future use by #HOT / STRICT mode) ---

  def effects_for(fn_name)
    node = @fn_nodes[fn_name]
    node&.effects
  end

  # --- TIGHT loop validation ---

  # Deep validation for TIGHT loops: walks the full AST subtree looking for
  # calls to @reentrant or EXTERN FN functions. Stops at FunctionDef boundaries.
  def validate_tight_body!(stmts, loop_node)
    return if stmts.nil?
    stmts = [stmts] unless stmts.is_a?(Array)
    stmts.each { |s| validate_tight_node!(s, loop_node) }
  end

  def validate_tight_node!(node, loop_node)
    return if node.nil?
    case node
    when Symbol, String, Integer, Float, TrueClass, FalseClass, Type
    when Array
      node.each { |n| validate_tight_node!(n, loop_node) }
    when AST::FunctionDef
      # Don't descend into nested function definitions.
    when AST::FuncCall
      if node.respond_to?(:extern_call) && node.extern_call
        error!(loop_node, "TIGHT loop cannot call EXTERN FN '#{node.name}' (opaque to scheduler)")
      end
      fn = @fn_nodes[node.name]
      if fn&.reentrant == :reentrant
        error!(loop_node, "TIGHT loop cannot call @reentrant function '#{node.name}'")
      end
      node.args&.each { |a| validate_tight_node!(a, loop_node) }
    when AST::MethodCall
      if node.respond_to?(:extern_call) && node.extern_call
        error!(loop_node, "TIGHT loop cannot call EXTERN FN '#{node.name}' (opaque to scheduler)")
      end
      fn = @fn_nodes[node.name]
      if fn&.reentrant == :reentrant
        error!(loop_node, "TIGHT loop cannot call @reentrant function '#{node.name}'")
      end
      validate_tight_node!(node.respond_to?(:object) ? node.object : nil, loop_node)
      node.args&.each { |a| validate_tight_node!(a, loop_node) }
    else
      node.each_pair { |_, v| validate_tight_node!(v, loop_node) } if node.respond_to?(:each_pair)
    end
  end

  # --- Reentrancy analysis ---

  # Recursively walk an annotated AST subtree and collect:
  #   - names of every directly-called named function (FuncCall where !fn_var_call)
  #   - whether any fn-type variable or lambda is invoked (fn_var_call)
  #
  # Does NOT descend into nested FunctionDef bodies (none exist in practice in CLEAR —
  # all functions are top-level — but guarded for safety).
  def scan_for_calls(node)
    calls    = Set.new
    has_fnptr = [false]

    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
        # terminals
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef
        # Don't descend into nested function definitions (own scope).
      when AST::FuncCall
        if n.fn_var_call
          has_fnptr[0] = true
        else
          calls.add(n.name)
        end
        traverse.call(n.args)
      else
        if n.respond_to?(:each_pair)
          n.each_pair { |_, v| traverse.call(v) }
        end
      end
    end

    traverse.call(node)
    [calls, has_fnptr[0]]
  end

  # Post-pass: detect indirect mutual recursion in the call graph.
  # DFS reachability: for each function F, walk F's callees transitively
  # and report an error if F is reachable from itself.
  def check_indirect_reentrancy!
    @call_graph.each_key do |fn_name|
      node = @fn_nodes[fn_name]
      next if node.nil?
      next if node.reentrant  # already annotated — no complaint needed

      visited = Set.new
      queue   = (@call_graph[fn_name] || Set.new).to_a

      until queue.empty?
        callee = queue.shift
        next if visited.include?(callee)
        visited.add(callee)

        if callee == fn_name
          @fn_direct_effects[fn_name]&.add(EffectTracker::REENTRANT)
          error!(node, "Reentrancy Error: '#{fn_name}' is part of a mutually recursive call cycle. " \
                       "Add @reentrant or @nonReentrant to the function signature.")
          break
        end

        (@call_graph[callee] || Set.new).each { |c| queue << c }
      end
    end
  end

  # Scan a function body for direct failure sources (Raise/OrRaise nodes).
  # Does not descend into nested FunctionDef nodes.
  def scan_for_raises(body)
    found = [false]
    traverse = lambda do |n|
      return if found[0]
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef
        # Don't descend into nested function definitions.
      when AST::Raise, AST::OrRaise
        found[0] = true
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(body)
    found[0]
  end
end
