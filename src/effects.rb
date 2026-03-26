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
module EffectTracker
  # Core effect constants.
  #
  # HEAP           — dynamic allocation (@list, @pool, HashMap, capability wraps)
  # BLOCKING       — WITH EXCLUSIVE (mutex acquisition, may yield the fiber)
  # REENTRANT      — function is directly or indirectly recursive
  # LOOP_UNBOUND   — contains WHILE TRUE, unbounded WHILE, or infinite BG STREAM
  # EXTERN         — calls an EXTERN FN (opaque to the compiler — may do I/O, syscalls, etc.)
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
    return unless @current_function_name
    @fn_direct_effects[@current_function_name]&.add(effect)
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

  # --- Queries (for future use by #HOT / STRICT mode) ---

  # Returns the computed effect set for a named function, or nil if unknown.
  def effects_for(fn_name)
    node = @fn_nodes[fn_name]
    node&.effects
  end
end
