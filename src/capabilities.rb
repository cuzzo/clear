# capabilities.rb — Capability validation, audit, and helpers for CLEAR's type system.
#
# Three concerns, three modules:
#   Capabilities       — static validation of capability combinations on Type objects
#   CapabilityHelper   — runtime validation and inference for WITH blocks
#   CapabilityAudit    — "Architecture Consultant" that warns about over-engineered capabilities

require 'set'

# ============================================================================
# Capabilities — Static validation of capability combinations
# ============================================================================
module Capabilities
  # Capability groups — at most one from each group is allowed.
  GROUPS = {
    ownership: %i[multiowned shared],
    sync:      %i[locked write_locked local],
    layout:    %i[soa],
  }.freeze

  # Capabilities that are mutually exclusive with each other.
  CONFLICTS = [
    [[:soa],     [:shared, :multiowned], "SOA layout is incompatible with reference-counted ownership"],
    [[:arena],   [:parallel],            "@arena cannot be combined with @parallel — arena memory is thread-local"],
    [[:local],   [:parallel],            "@local requires single-scheduler affinity, incompatible with @parallel"],
  ].freeze

  def self.errors_for(type)
    return [] unless type.is_a?(Type)

    errors = []
    caps = active_capabilities(type)

    GROUPS.each do |group_name, members|
      active = members.select { |c| caps.include?(c) }
      if active.size > 1
        errors << "Conflicting #{group_name} capabilities: #{active.map { |c| "@#{c}" }.join(' and ')}. Only one #{group_name} capability is allowed."
      end
    end

    CONFLICTS.each do |set_a, set_b, message|
      has_a = set_a.any? { |c| caps.include?(c) }
      has_b = set_b.any? { |c| caps.include?(c) }
      errors << message if has_a && has_b
    end

    errors
  end

  def self.validate!(node, type, &error_handler)
    errs = errors_for(type)
    return if errs.empty?
    error_handler.call(node, errs.first) if error_handler
  end

  def self.active_capabilities(type)
    caps = Set.new
    caps << type.ownership if type.ownership && type.ownership != :affine
    caps << type.sync if type.sync
    caps << :soa if type.respond_to?(:soa?) && type.soa?
    caps << :sharded if type.respond_to?(:sharded?) && type.sharded?
    caps << :pool if type.respond_to?(:pool?) && type.pool?
    caps << :list if type.respond_to?(:list_collection?) && type.list_collection?
    caps
  end
end

# ============================================================================
# CapabilityHelper — WITH block validation and capability acquisition
# ============================================================================
# Mixed into SemanticAnnotator. Provides validate_capability and
# acquire_capability! used by visit_WithBlock.
module CapabilityHelper
  # Validate that a capability type is legal for the given variable.
  def validate_capability(node, capability_type, var_node)
    var_type = var_node.full_type
    if !var_node.is_a?(AST::Identifier) && !var_node.is_a?(AST::GetField)
      error!(var_node, "WITH #{capability_type} expects an identifier or field, got '#{var_node.class}'.")
    end

    case capability_type
    when :EXCLUSIVE
      syn = var_node.symbol&.sync
      unless syn
        storage = var_node.symbol&.storage
        error!(node, "EXCLUSIVE capability requires a @locked or @writeLocked variable, got #{storage || 'unknown'}")
      end

    when :write_locked_read
      syn = var_node.symbol&.sync
      unless syn == :write_locked
        error!(node, "WITH #{var_node.name}: read access requires a @writeLocked variable")
      end

    when :RESTRICT
      if var_node.symbol && !var_node.symbol.mutable
        error!(node, "EXCLUSIVE capability requires a mutable variable, but '#{var_node.name}' is immutable")
      end

    when :multiowned
      unless var_node.symbol&.storage == :multiowned
        error!(node, "WITH #{var_node.name}: expected a @multiowned variable")
      end

    when :shared
      unless var_node.symbol&.storage == :shared
        error!(node, "WITH #{var_node.name}: expected a @shared variable")
      end

    else
      error!(node, "Unknown capability type: #{capability_type}")
    end
  end

  # Resolve and validate a single capability entry from a WITH block.
  # Visits the var_node, infers capability if needed, validates it,
  # records effects/audit, and handles wildcard expansion.
  #
  # @param node [AST::WithBlock] the WITH block (for error reporting)
  # @param cap [Hash] the capability entry { :capability, :var_node, :alias }
  # @param expanded [Array] accumulator for resolved capabilities
  def acquire_capability!(node, cap, expanded)
    var_node = cap[:var_node]
    visit(var_node)
    cap[:resolved_type] = var_node.full_type

    cap[:old_scope] = lookup_scope_for(var_node.name)

    # Infer capability from the variable's storage when not stated explicitly
    if cap[:capability] == :infer
      storage = var_node.symbol&.storage
      syn     = var_node.symbol&.sync
      cap[:capability] = case
                         when syn == :locked            then :EXCLUSIVE
                         when syn == :write_locked      then :write_locked_read
                         when storage == :multiowned    then :multiowned
                         when storage == :shared        then :shared
                         else
                           error!(node, "WITH #{var_node.name}: cannot infer capability; variable must be @multiowned, @shared, @locked, @writeLocked, or another capability type")
                           :unknown
                         end
    end

    validate_capability(node, cap[:capability], var_node)

    # Effect tracking: EXCLUSIVE access acquires a mutex — may block the fiber.
    record_effect(EffectTracker::BLOCKING) if cap[:capability] == :EXCLUSIVE

    # Capability audit: mark variable as mutated if EXCLUSIVE access is used.
    if cap[:capability] == :EXCLUSIVE && var_node.is_a?(AST::Identifier)
      audit_mark_mutated(var_node.name)
    end

    # Handle Wildcard Borrow: WITH RESTRICT node.* { ... }
    if var_node.is_a?(AST::GetField) && var_node.wildcard?
      target_type = var_node.target.resolved_type
      schema = lookup_type_schema(target_type)

      unless schema
        error!(node, "Wildcard borrow '*' requires a struct type, but '#{var_node.target.name}' is #{target_type}")
      end

      schema.each do |field_name, _|
        field_node = AST::GetField.new(var_node.token, var_node.target, field_name)
        expanded << {
          capability: cap[:capability],
          var_node: field_node,
          old_scope: cap[:old_scope]
        }
      end
    else
      expanded << cap
    end
  end

  # Declare a resolved capability into the current scope.
  # For locked/write_locked vars, declares the alias as the plain inner type
  # (mutable, stack-allocated) and re-declares the locked var for accessibility.
  # For all others, delegates to scope.declare_with_new_capability.
  def declare_capability_scope!(cap)
    var_name = cap[:var_node].name
    syn = cap[:old_scope]&.locals&.[](var_name)&.sync
    if syn && !cap[:var_node].is_a?(AST::GetField)
      inner_type = cap[:old_scope].resolve_type(var_name)
      alias_name = cap[:alias] || var_name
      current_scope.declare(alias_name, nil, inner_type, true, false, nil, :stack)
      current_scope.set_state(alias_name, :live)
      current_scope.declare_with_new_capability(cap)
    else
      current_scope.declare_with_new_capability(cap)
    end
  end

  # --- Fiber capture analysis (shared by BG and DO blocks) ---

  # Result of analyzing a fiber body's captured variables.
  # Computed once per body by analyze_fiber_captures, queried by multiple consumers.
  CaptureAnalysis = Struct.new(
    :has_local,        # captures @local var (sync == :local)
    :has_rc,           # captures @multiowned (Rc) var
    :has_shared,       # captures any shared/locked/write_locked/local/multiowned/sharded var
    :has_sharded,      # specifically captures @sharded (for auto-pin reason)
    :has_outer_ref,    # references any outer-scope variable
    keyword_init: true
  ) do
    def pin_reason; has_sharded ? :sharded : :shared; end
  end

  # Single walk over a fiber body that computes ALL capture properties at once.
  # Replaces 6 separate walks (_captures_with_storage?, _captures_with_sync?,
  # _captures_shared?, _auto_pin_reason, _has_outer_ref?, _audit_walk_captures).
  def analyze_fiber_captures(body_exprs, is_parallel: false)
    result = CaptureAnalysis.new(
      has_local: false, has_rc: false, has_shared: false,
      has_sharded: false, has_outer_ref: false
    )
    _unified_capture_walk(body_exprs, Set.new, result, is_parallel)
    result
  end

  # Validate capture safety using pre-computed analysis.
  def validate_fiber_captures!(node, body, is_parallel, is_pinned)
    analysis = analyze_fiber_captures(body, is_parallel: is_parallel)

    if is_parallel
      if analysis.has_local
        error!(node, "@local variable cannot be used in @parallel block — it requires single-scheduler affinity.")
      end
      if analysis.has_rc
        error!(node, "@multiowned (Rc) variable cannot be used in @parallel block — Rc uses a non-atomic reference count. Use @shared (Arc) for cross-scheduler sharing.")
      end
    end

    if !is_pinned && !is_parallel && analysis.has_shared
      return analysis  # caller should set pinned = true; return analysis for pin_reason
    end
    nil
  end

  # Walk a BG block's body AST and mark any outer-scope resource, affine, or
  # frame-allocated variables as :moved. Stops at nested BgBlock boundaries.
  def walk_bg_capture_moves(stmts, scope, locally_bound)
    stmts.each { |expr| _bg_walk(expr, scope, locally_bound) }
  end

  # Returns true if body references any outer-scope variable not in locally_bound.
  def captures_outer_variables?(body, locally_bound)
    result = CaptureAnalysis.new(
      has_local: false, has_rc: false, has_shared: false,
      has_sharded: false, has_outer_ref: false
    )
    _unified_capture_walk(body, locally_bound, result, false)
    result.has_outer_ref
  end

  private

  # One recursive walk that checks each outer-scope identifier for ALL properties.
  def _unified_capture_walk(nodes, locally_bound, result, is_parallel)
    nodes.each do |node|
      next unless node.is_a?(AST::Locatable)

      # Track locally-declared names so we don't treat them as outer captures.
      if (node.is_a?(AST::BindExpr) || node.is_a?(AST::VarDecl)) && node.name.is_a?(String)
        locally_bound = locally_bound | Set[node.name]
      end

      if node.is_a?(AST::Identifier)
        name = node.name
        next if locally_bound.include?(name)
        next if %w[TRUE FALSE VOID _].include?(name)

        info = current_scope.locals[name]
        if info
          result.has_outer_ref = true

          result.has_local   = true if info.sync == :local
          result.has_rc      = true if info.storage == :multiowned
          result.has_shared  = true if info.sync == :locked || info.sync == :write_locked || info.sync == :local
          result.has_shared  = true if info.storage == :shared || info.storage == :multiowned
          ti = info.type
          if ti.is_a?(Type) && ti.sharded?
            result.has_sharded = true
            result.has_shared  = true
          end

          # Audit: mark capability usage for over-engineering warnings
          if current_fn_ctx&.name
            key = "#{current_fn_ctx.name}:#{name}"
            if @capability_audit&.dig(key)
              @capability_audit[key][:captured_bg] = true
              @capability_audit[key][:captured_parallel] = true if is_parallel
            end
          end
        elsif lookup_scope_for(name)
          result.has_outer_ref = true
        end
        next
      end

      # WithBlock: check var_nodes for sync/shared captures
      if node.is_a?(AST::WithBlock) && node.capabilities.is_a?(Array)
        node.capabilities.each do |cap|
          var_node = cap[:var_node]
          next unless var_node.is_a?(AST::Identifier)
          name = var_node.name
          next if locally_bound.include?(name)
          info = current_scope.locals[name]
          next unless info
          result.has_outer_ref = true
          result.has_local  = true if info.sync == :local
          result.has_shared = true if info.sync == :locked || info.sync == :write_locked || info.sync == :local
          result.has_shared = true if info.storage == :shared

          if current_fn_ctx&.name
            key = "#{current_fn_ctx.name}:#{name}"
            if @capability_audit&.dig(key)
              @capability_audit[key][:captured_bg] = true
              @capability_audit[key][:captured_parallel] = true if is_parallel
            end
          end
        end
      end

      # Don't recurse into nested BG/DO blocks — they have their own capture scope.
      next if node.is_a?(AST::BgBlock) || node.is_a?(AST::DoBlock)

      node.class.members.each do |member|
        val = node[member]
        if val.is_a?(Array)
          _unified_capture_walk(val, locally_bound, result, is_parallel)
        elsif val.is_a?(AST::Locatable)
          _unified_capture_walk([val], locally_bound, result, is_parallel)
        end
      end
    end
  end

  def _bg_walk(node, scope, locally_bound)
    return unless node.is_a?(AST::Locatable)
    return if node.is_a?(AST::BgBlock)

    if node.is_a?(AST::Identifier)
      name = node.name
      return if locally_bound.include?(name)
      info = scope.locals[name]
      return unless info && scope.owned_names.include?(name)
      classify_ownership!(info) unless info.ownership_kind
      kind = info.ownership_kind
      ti = info.type
      if info.state == :live
        if kind == :resource || kind == :affine
          scope.set_state(name, :moved)
        elsif ti.is_a?(Type) && ti.needs_escape_promotion?
          scope.set_state(name, :moved)
        end
      end
      return
    end

    lb = locally_bound
    if node.is_a?(AST::BindExpr) || node.is_a?(AST::VarDecl)
      lb = lb | Set[node.name.to_s] if node.name.is_a?(String)
    end

    node.class.members.each do |member|
      val = node[member]
      if val.is_a?(Array)
        val.each { |v| _bg_walk(v, scope, lb) }
      elsif val.is_a?(AST::Locatable)
        _bg_walk(val, scope, lb)
      end
    end
  end
end

# ============================================================================
# CapabilityAudit — "Architecture Consultant"
# ============================================================================
# Mixed into SemanticAnnotator. Tracks capability usage patterns and
# warns about over-engineered capabilities (ghost locks, isolated shares, etc.)
module CapabilityAudit
  def capability_audit_init!
    @capability_audit = {}
  end

  # Record a capability binding for later audit.
  def record_capability_binding(var_name, node, final_type, storage)
    return unless var_name.is_a?(String) && current_fn_ctx&.name

    info = current_scope.locals[var_name]
    sync = info&.sync
    own  = storage if storage == :multiowned || storage == :shared
    return unless sync || own

    # Skip PUB functions — libraries can't know how consumers will use exports.
    fn_node = @fn_nodes[current_fn_ctx&.name]
    return if fn_node.respond_to?(:visibility) && fn_node.visibility == :pub

    key = "#{current_fn_ctx&.name}:#{var_name}"
    line = node.respond_to?(:token) && node.token ? node.token.line : nil
    ft = final_type.is_a?(Type) ? final_type : nil
    is_sharded = ft&.respond_to?(:sharded?) && ft.sharded?
    @capability_audit[key] = {
      fn: current_fn_ctx&.name, var: var_name, line: line,
      sync: sync, ownership: own, storage: storage, sharded: is_sharded,
      mutated: false, captured_bg: false, captured_parallel: false
    }
  end

  def audit_mark_mutated(var_name)
    return unless current_fn_ctx&.name
    key = "#{current_fn_ctx&.name}:#{var_name}"
    @capability_audit[key][:mutated] = true if @capability_audit[key]
  end

  # No longer needed — audit marking is handled by _unified_capture_walk.
  # Kept as a no-op for call-site compatibility.
  def audit_mark_bg_captures(body_exprs, is_parallel)
  end

  def finalize_capability_audit!
    @capability_audit.each do |_key, info|
      loc = info[:line] ? " (line #{info[:line]})" : ""
      sync = info[:sync]
      own  = info[:ownership]

      if (sync == :locked || sync == :write_locked) && !info[:mutated] && !info[:sharded]
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info[:var]}' is @#{sync} but never mutated via WITH EXCLUSIVE. " \
                     "You are paying for lock acquire/release on every access. Consider @local or removing the lock.#{loc}"
      end

      if own == :shared && !info[:captured_parallel]
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info[:var]}' is @shared (Arc) but never leaves the local scheduler. " \
                     "You are paying for atomic ref-counting but never crossing cores. Consider @multiowned or @local.#{loc}"
      end

      if sync == :local && !info[:captured_bg]
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info[:var]}' is @local but never shared across fibers. " \
                     "You are paying for a heap allocation with no sharing benefit. Consider removing @local.#{loc}"
      end
    end
  end

end
