# typed: strict
require "sorbet-runtime"

module MIRLoweringCapabilities
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  SYNC_WRAP_CONSTRUCTORS = T.let({
    locked: "lockedCreate",
    write_locked: "rwLockedCreate",
    always_mutable: "refCellCreate",
    versioned: "versionedCreate",
    atomic: "atomicCreate",
    atomic_ptr: "atomicPtrCreate",
    local: nil,
  }.freeze, T::Hash[Symbol, T.nilable(String)])

  SYNC_WRAP_TYPES = T.let({
    locked: "CheatLib.Locked",
    write_locked: "CheatLib.RwLocked",
    always_mutable: "CheatLib.RefCell",
    versioned: "CheatLib.Versioned",
    atomic: "CheatLib.Atomic",
    atomic_ptr: "CheatLib.AtomicPtr",
    local: nil,
  }.freeze, T::Hash[Symbol, T.nilable(String)])

  sig { params(sync: T.nilable(Symbol), atomic_ptr: T::Boolean).returns(T.nilable(String)) }
  def sync_wrap_constructor(sync, atomic_ptr:)
    return nil unless sync
    SYNC_WRAP_CONSTRUCTORS[atomic_ptr ? :atomic_ptr : sync]
  end

  sig { params(sync: T.nilable(Symbol), bare_zig_t: String, atomic_ptr: T::Boolean).returns(T.nilable(String)) }
  def sync_wrap_type(sync, bare_zig_t, atomic_ptr:)
    return nil unless sync
    wrapper = SYNC_WRAP_TYPES[atomic_ptr ? :atomic_ptr : sync]
    wrapper ? "#{wrapper}(#{bare_zig_t})" : nil
  end

  sig { params(var_node: AST::Identifier).returns(String) }
  def with_cap_var_name(var_node)
    T.bind(self, MIRLowering) rescue nil
    case var_node
    when AST::GetField then var_node.field.to_s
    else
      var_node.respond_to?(:name) ? var_node.name : var_node.to_s
    end
  end

  # Sync + storage flags for the bound entity.
  # Identifier → from the symbol entry (post-propagation).
  # GetField   → from the field's declared type (carries @sync/@ownership
  #              from the struct field declaration).
  #
  # Inside a fiber-like callback (BG/BG STREAM/DO/CONCURRENT), prefer
  # the LIVE SymbolEntry from @current_fiber_capture_symbols. The AST
  # node's var_node.symbol can carry a stale snapshot of sync/storage;
  # the live entry was refreshed by EscapeAnalysis.propagate_caller_sync!
  # and recorded into capture_analysis.capture_symbols by
  # _unified_capture_walk. This is what makes WITH EXCLUSIVE c inside a
  # CONCURRENT EACH callback take the direct c.ctrl.data.* Arc-unwrap
  # path (storage = :shared) instead of the polymorphic c.* path that
  # only works for non-Arc parameters.
  sig { params(var_node: AST::Identifier).returns(T::Array[T.nilable(Symbol)]) }
  def with_cap_sync_storage(var_node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_fiber_capture_symbols = T.let(@current_fiber_capture_symbols, T.untyped)
    if var_node.is_a?(AST::GetField)
      ft = var_node.full_type!(context: "WITH field capability")
      sync = ft.sync
      storage = ft.ownership_storage
      return [sync, storage]
    end
    if var_node.is_a?(AST::Identifier) &&
       (live = @current_fiber_capture_symbols&.dig(var_node.name))
      return [live.sync, live.storage]
    end
    sym = var_node.symbol
    ti = var_node.full_type!(context: "WITH capability variable")
    [sym&.sync || ti&.sync, sym&.storage]
  end

  sig { params(capability: T.any(AST::Capability, T::Hash[Symbol, T.untyped])).returns(T::Array[T.untyped]) }
  def with_alias_ownership_marks(capability)
    []
  end

  # Zig expression naming the locked-inner. Identifier → its Zig name (or
  # DO-capture rename). GetField → the chained field path (e.g.
  # `env.vars`), built recursively for nested fields.
  sig { params(var_node: AST::Identifier, var_name: String).returns(String) }
  def with_cap_zig_target(var_node, var_name)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @decl_zig_name_map = T.let(@decl_zig_name_map, T.untyped)
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    if var_node.is_a?(AST::GetField)
      build_field_path_zig(var_node)
    else
      decl = var_node.respond_to?(:symbol) ? var_node.symbol&.reg : nil
      mapped = (@decl_zig_name_map && decl && @decl_zig_name_map[decl.object_id]) || nil
      @do_capture_map&.dig(var_name) || mapped || var_name
    end
  end

  # True when the WITH-bound entity is a function parameter (vs. a local
  # binding). Parameters' runtime wrappers come from the caller and may
  # not be statically known at this fn's codegen time.
  sig { params(var_node: AST::Identifier).returns(T::Boolean) }
  def with_cap_is_param?(var_node)
    T.bind(self, MIRLowering) rescue nil
    return false unless var_node.is_a?(AST::Identifier)
    var_node.symbol&.is_param == true
  end

  # Comptime-dispatched lock target: at compile time, Zig picks
  # `x.ctrl.data.*` if the underlying type is `Arc(...)` (has a `ctrl`
  # field), else the bare value. The same fn body then works for both
  # `Locked(T)` and `Arc(Locked(T))` callers without runtime overhead.
  # Mutable parameters arrive as `*T`, so probe and deref through `*`.
  sig { params(zig_var: String).returns(String) }
  def comptime_arc_unwrap_expr(zig_var)
    T.bind(self, MIRLowering) rescue nil
    "(if (@hasField(@TypeOf(#{zig_var}.*), \"ctrl\")) #{zig_var}.ctrl.data.* else #{zig_var}.*)"
  end

  sig { params(lock_expr: String, var_sync: T.nilable(Symbol), fallible: T::Boolean).returns(String) }
  def lock_acquire_call_expr(lock_expr, var_sync, fallible)
    T.bind(self, MIRLowering) rescue nil
    if var_sync == :write_locked
      return "#{lock_expr}.#{fallible ? "writeOrErr" : "write"}()"
    end
    if var_sync == :locked
      return "#{lock_expr}.#{fallible ? "acquireOrErr" : "acquire"}()"
    end

    write_method = fallible ? "writeOrErr" : "write"
    acquire_method = fallible ? "acquireOrErr" : "acquire"
    "(if (comptime @hasDecl(@TypeOf(#{lock_expr}), \"#{write_method}\")) " \
      "#{lock_expr}.#{write_method}() else #{lock_expr}.#{acquire_method}())"
  end

  # Recursively build the Zig string for a (possibly nested) field path.
  # Stops at the root Identifier; intermediate GetFields chain via `.`.
  sig { params(node: T.untyped).returns(String) }
  def build_field_path_zig(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    case node
    when AST::Identifier
      @do_capture_map&.dig(node.name) || node.name
    when AST::GetField
      "#{build_field_path_zig(node.target)}.#{node.field}"
    else
      node.to_s
    end
  end

  sig { params(node: AST::WithBlock).returns(T.untyped) }
  def lower_with_block(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @atomic_emit_raw = T.let(@atomic_emit_raw, T.untyped)
    @current_fn_return_payload_zig = T.let(@current_fn_return_payload_zig, T.untyped)
    @locked_unwrap_map = T.let(@locked_unwrap_map, T.untyped)
    @rc_unwrap_map = T.let(@rc_unwrap_map, T.untyped)
    @with_alias_alloc_map = T.let(@with_alias_alloc_map, T.untyped)
    @with_alias_owner_map = T.let(@with_alias_owner_map, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    return lower_with_match_block(node) if node.arms

    # Universal polymorphic WITH lowers to a helper that dispatches by
    # actual family at the call site.
    if node.universal_poly && (node.capabilities || []).length == 1
      return lower_polymorphic_universal(node)
    end
    rt_name = @rt_name
    bindings = []
    # Structured representation of any fallible-acquire clause(s) for the
    # BC backend (Zig backend uses the InlineZig text emitted into
    # `bindings`). Each entry: { var_name, action_kind, action_mir,
    # exit_msg_mir, retries, matched_types, bubble_types }. Both backends
    # see the same node; only BC consumes `:fallible_clauses`.
    fallible_clauses = []
    clause = node.lock_error_clause
    # Only RAISE/EXIT exit via `return`; PASS and `-> { stmts }` exit by
    # breaking out of this labeled block. Emit the label only when used
    # so Zig doesn't complain about an unused label.
    needs_label = clause && (clause[:action] == :pass || clause[:action] == :block)
    with_label = needs_label ? "__with_#{node.object_id.abs}" : nil

    # Collect fallible captures first to decide whether to apply runtime
    # lock sorting. Any WITH block that acquires 2+ locks simultaneously is
    # globally ordered by underlying mutex address, so two sites that name
    # the same set of locks in different source orders cannot form a
    # held-acquire edge that contradicts each other. This preserves the
    # safety invariant that multi-acquire WITH blocks cannot, on their own,
    # produce a LockCycle at runtime.
    fallible_caps = (node.capabilities || []).select { |c|
      c[:capability] == :EXCLUSIVE || c[:capability] == :write_locked_read
    }
    needs_sort = fallible_caps.length >= 2

    if needs_sort
      if clause
        bindings << emit_sorted_lock_acquires_fallible(fallible_caps, clause, with_label, node)
        # Per-cap descriptors for the BC backend's fallible-acquire dispatch.
        # Zig backend renders inline above; this populates fallible_clauses
        # so BC consumers see the same shape as the single-cap path.
        fallible_caps.each do |cap|
          var_name = with_cap_var_name(cap[:var_node])
          alias_name = cap[:alias] || var_name
          fallible_clauses << build_fallible_clause_mir(var_name, alias_name, clause)
        end
      else
        bindings << emit_sorted_lock_acquires(fallible_caps, node)
      end
    end

    (node.capabilities || []).each do |cap|
      # var_name is the user-visible name of the bound entity. For an
      # Identifier it's the variable name; for a GetField (`obj.field`)
      # we use the field name so guard variables are named after what's
      # being locked (`__vars_guard_X`, not `__obj_guard_X`).
      var_node = cap[:var_node]
      var_name = with_cap_var_name(var_node)
      alias_name = cap[:alias] || var_name
      resolved = cap[:resolved_type]
      var_sync, var_storage = with_cap_sync_storage(var_node)
      # zig_var is the Zig expression that names the inner being locked.
      # Identifier → variable name (or its DO-capture rename). GetField
      # → the full field path emitted as Zig (`obj.field`).
      zig_var = with_cap_zig_target(var_node, var_name)

      case cap[:capability]
      when :multiowned, :shared
        inner = "__#{var_name}_unwrap"
        bindings << "const #{inner} = #{zig_var}.ctrl.data.*;\n_ = &#{inner};"
      when :EXCLUSIVE
        next if needs_sort
        # Include the WITH node's object_id in the guard name so nested
        # WITHs on the same variable (permitted via POSSIBLE_DEADLOCK)
        # don't produce colliding Zig identifiers.
        # Use source position (line_col) — stable across process invocations
        # and across refactors that shift Ruby object IDs. Two WITHs at the
        # same source position can't exist (they'd be the same WITH).
        guard_var = "__#{var_name}_guard_#{node.object_id.abs}"
        is_arc = SymbolEntry.rc_storage?(var_storage) || resolved&.any_rc?
        # For function parameters, the caller's wrapper is unknown at
        # this fn's standalone codegen time (cross-module case). Emit
        # comptime-dispatched lock_expr so the SAME function body works
        # for both `Locked(T)` and `Arc(Locked(T))` callers.
        is_param = with_cap_is_param?(var_node)
        lock_sync = node.polymorphic && is_param ? nil : var_sync
        lock_expr = if is_param && !is_arc
          comptime_arc_unwrap_expr(zig_var)
        else
          is_arc ? "#{zig_var}.ctrl.data.*" : zig_var
        end
        if clause
          bindings << emit_fallible_lock_binding(lock_acquire_call_expr(lock_expr, lock_sync, true), guard_var, alias_name, clause, with_label, node)
          fallible_clauses << build_fallible_clause_mir(var_name, alias_name, clause)
        else
          bindings << "var #{guard_var} = #{lock_acquire_call_expr(lock_expr, lock_sync, false)};\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
        end
      when :write_locked_read
        next if needs_sort
        # Use source position (line_col) — stable across process invocations
        # and across refactors that shift Ruby object IDs. Two WITHs at the
        # same source position can't exist (they'd be the same WITH).
        guard_var = "__#{var_name}_guard_#{node.object_id.abs}"
        is_arc = SymbolEntry.rc_storage?(var_storage) || resolved&.any_rc?
        lock_expr = is_arc ? "#{zig_var}.ctrl.data.*" : zig_var
        if clause
          bindings << emit_fallible_lock_binding("#{lock_expr}.readOrErr()", guard_var, alias_name, clause, with_label, node)
          fallible_clauses << build_fallible_clause_mir(var_name, alias_name, clause)
        else
          bindings << "var #{guard_var} = #{lock_expr}.read();\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
        end
      when :BORROWED
        # PURE: cap[:var_node] is always an Identifier or field ref; never allocating.
        source_zig = emit_expr(lower(cap[:var_node]))
        # Polymorphic params need the comptime unwrap probe so plain T,
        # @local, and @multiowned all bind as `*T`.
        is_param = with_cap_is_param?(cap[:var_node])
        if is_param && (var_sync.nil? || var_sync == :local) &&
           cap[:var_node].symbol && !cap[:var_node].symbol.mutable
          aliased_value = with_match_unwrap_value(T.must(source_zig))
          bindings << "const #{zig_safe_name(alias_name)} = #{aliased_value};\n_ = &#{zig_safe_name(alias_name)};"
        else
          bindings << "const #{zig_safe_name(alias_name)} = #{source_zig};\n_ = &#{zig_safe_name(alias_name)};"
        end
      when :RESTRICT
        # Plain and @local aliases lower directly: no Guard, Arc unwrap,
        # or snapshot.
        #
        # For polymorphic params (anytype), use the comptime
        # `with_match_unwrap_value` probe so the alias resolves
        # uniformly per actual binding shape:
        #   - by-value T            -> `&c`
        #   - `*T` (already ptr)    -> `c`
        #   - Arc(T) / *Arc(T)      -> `c.ctrl.data`
        # The probe always produces a `*T`; binding without `&` keeps
        # the alias pointer-typed so `x.field = ...` works.
        #
        # For non-poly bindings (concrete locals), the legacy emission
        # is preserved: `const x = &c;` for mutable / `const x = c;`
        # for read-only.
        if var_sync.nil? || var_sync == :local
          source_zig = emit_expr(lower(cap[:var_node]))
          is_param = with_cap_is_param?(cap[:var_node])
          if is_param
            # Poly param: comptime probe resolves to `*T` regardless
            # of caller shape.
            aliased_value = with_match_unwrap_value(T.must(source_zig))
            bindings << "const #{zig_safe_name(alias_name)} = #{aliased_value};"
          elsif var_sync == :local
            # Concrete @local: localCreate returns a `*T` already, so
            # the alias is the source directly (no extra `&`). Adding
            # `&` here would produce `*const *T` and break field
            # access. The body's `x.field = ...` mutation flows back
            # to the binding through the inherent pointer.
            bindings << "const #{zig_safe_name(alias_name)} = #{source_zig};"
          elsif cap[:alias_mutable]
            bindings << "const #{zig_safe_name(alias_name)} = &#{source_zig};"
          else
            bindings << "const #{zig_safe_name(alias_name)} = #{source_zig};\n_ = &#{zig_safe_name(alias_name)};"
          end
        end
      when :VIEW
        # Observable backings expose a uniform `.view()` method.
        #   - Scalar wrappers (Atomic*) return the current value by
        #     copy; no resource to release.
        #   - Collection / handle wrappers (StreamSet, Observable<T>)
        #     return a refcounted snapshot whose `.release()` must
        #     run on scope exit.
        # `inner` is the tense element type; collection / non-primitive
        # shapes get a `defer s.release()`. Primitive scalars do not.
        #
        # After the view, yield cooperatively (when the scheduler is
        # active) so a hot-poll WHILE loop gives the producer fiber a
        # turn. Without this, a `WHILE done == FALSE { WITH VIEW
        # running AS s { ... } }` loop monopolises the CPU and the
        # producer never advances. The yield is a no-op when no other
        # task is ready (single-fiber programs).
        source_zig = emit_expr(lower(cap[:var_node]))
        safe_alias = zig_safe_name(alias_name)
        rt = resolved.is_a?(Type) ? resolved : Type.new(resolved)
        inner_t = rt.future? && rt.tense_type ? rt.tense_type : rt
        # Value-shaped types — no `.release()` needed:
        #   - `T` where T is primitive (Int64 / Bool / etc.)
        #   - `T` where T is a string (heap-managed but FIND/scalar
        #     observables return them by value or as `?String`)
        #   - `?T` where T is primitive OR string (FIND on
        #     `~Int64@observable` or `~String@observable`)
        # Without these carve-outs the codegen emits
        # `defer s.release()` on a value that has no `release()`.
        is_value_shape = inner_t.primitive? || inner_t.string? ||
                         (inner_t.optional? && inner_t.wrapped_type &&
                          (inner_t.wrapped_type.primitive? || inner_t.wrapped_type.string?))
        wants_release = !is_value_shape && (inner_t.collection_value? || !inner_t.primitive?)
        # Drain channels FIRST so SPSC-queued spawns (e.g. the consumer
        # fiber for a sibling observable) become Ready before pickNext;
        # without this, in a tight `WHILE { WITH VIEW ... }` loop a
        # pinned main always wins over a not-yet-drained consumer
        # (scheduler.zig:825-830 picks pinned-first).
        coop_yield = "if (CheatHeader.scheduler.scheduler_running) { CheatHeader.scheduler.active_scheduler.drainChannels(); CheatHeader.scheduler.active_scheduler.coopYield(); }"
        if wants_release
          bindings << "var #{safe_alias} = #{source_zig}.view();\ndefer #{safe_alias}.release();\n#{coop_yield}\n_ = &#{safe_alias};"
        else
          bindings << "const #{safe_alias} = #{source_zig}.view();\n#{coop_yield}\n_ = &#{safe_alias};"
        end
      when :SNAPSHOT
        # Read-only snapshots acquire Guards. Any mutable snapshot makes the
        # whole WITH a transaction; the
        #   post-loop `emit_snapshot_mutable_call` covers all cells
        #   via `update()` (single) or `versionedUpdateMulti(...)`
        #   (multi). Skip per-cell binding for the whole WITH so the
        #   read-only cells in a mixed WITH don't emit a redundant
        #   `.read()` alongside the txn.
        # Multi-cell read-only -> N independent `.read()` calls.
        any_mutable = (node.capabilities || []).any? { |c| c[:capability] == :SNAPSHOT && c[:alias_mutable] }
        next if any_mutable # handled in the mutable-snapshot block below
        source_zig = emit_expr(lower(cap[:var_node]))
        safe_alias = zig_safe_name(alias_name)
        guard_var = "__#{var_name}_snap_#{node.object_id.abs}"
        # Shape-agnostic unwrap so the same emit works for *Versioned,
        # *Arc<Versioned>, and Arc<Versioned> by value (the BG-capture
        # case). The MIR::SnapshotRead node carries the
        # structured fields; mir_emitter.rb renders them. Pre-migration
        # this was an InlineZig blob -- the heap-allocated read Guard
        # was invisible to the checker (INV-12 violation).
        unwrap = with_match_unwrap_value(T.must(source_zig))
        bindings << MIR::SnapshotRead.new(unwrap, rt_name, safe_alias, guard_var, nil)
      when :MATERIALIZED_VIEW
        # Materialized views perform an explicit copy. Scalar observables
        # return values; collection observables return owned slices that must
        # be freed at the end of WITH.
        #
        # We detect collection shape from the source binding's type:
        # `tense_type.array?` means the source is `~T[]@set:observable`
        # (DISTINCT), whose materialize returns `[]T`. Scalars skip
        # the defer.
        source_zig = emit_expr(lower(cap[:var_node]))
        safe_alias = zig_safe_name(alias_name)
        rt = resolved.is_a?(Type) ? resolved : Type.new(resolved)
        is_collection = rt.observable_array_future? || rt.array?
        materialize = MIR::MethodCall.new(
          MIR::Ident.new(source_zig),
          "materialize",
          [MIR::AllocatorRef.new(:heap)],
          true,
          MIR::CallableContract.no_ownership(1),
          is_collection ? :heap : nil,
        )
        if is_collection
          mark = MIR::AllocMark.new(T.must(safe_alias), :heap, rt.tense_type)
          mark.scope = :heap
          entry = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
          bindings << mark
          bindings << MIR::Let.new(safe_alias, materialize, true, nil, "_ = &#{safe_alias};")
          bindings << MIR::Cleanup.new(safe_alias, entry)
        else
          bindings << MIR::Let.new(safe_alias, materialize, true, nil, "_ = &#{safe_alias};")
        end
      end
    end

    # Set up unwrap maps so lower_get_field uses aliases inside the WITH body
    prev_locked = @locked_unwrap_map
    prev_rc = @rc_unwrap_map
    prev_alias_alloc = @with_alias_alloc_map
    prev_alias_owner = @with_alias_owner_map
    @locked_unwrap_map = (prev_locked || {}).dup
    @rc_unwrap_map = (prev_rc || {}).dup
    @with_alias_alloc_map = (prev_alias_alloc || {}).dup
    @with_alias_owner_map = (prev_alias_owner || {}).dup

    (node.capabilities || []).each do |cap|
      var_name = cap[:var_node].respond_to?(:name) ? cap[:var_node].name : cap[:var_node].to_s
      alias_name = cap[:alias] || var_name
      if cap[:alias]
        @with_alias_alloc_map[alias_name.to_s] = placement_for_node(cap[:var_node])
        @with_alias_owner_map[alias_name.to_s] = var_name.to_s
      end
      case cap[:capability]
      when :EXCLUSIVE, :write_locked_read
        @locked_unwrap_map[alias_name] = true
        # Also map original var_name → alias so field accesses on the original
        # variable get rewritten to use the unwrapped inner alias.
        @locked_unwrap_map[var_name] = alias_name if alias_name != var_name
      when :multiowned, :shared
        @rc_unwrap_map[var_name] = "__#{var_name}_unwrap"
      end
    end

    # Mutable snapshots own the WITH body inside an update closure, so no
    # body statements remain for the surrounding WITH scope.
    mutable_snap_caps = (node.capabilities || []).select { |c|
      c[:capability] == :SNAPSHOT && c[:alias_mutable]
    }
    if mutable_snap_caps.any?
      bindings << emit_snapshot_mutable_call(node, with_label)
      body_stmts = []
    else
      body_stmts = lower_body(node.body)
      body_stmts = wrap_body_with_guard(node, T.must(body_stmts), with_label)
    end
    @locked_unwrap_map = prev_locked
    @rc_unwrap_map = prev_rc
    @with_alias_alloc_map = prev_alias_alloc
    @with_alias_owner_map = prev_alias_owner

    # Bindings is mixed: legacy WITH paths (EXCLUSIVE / BORROWED /
    # RESTRICT / multiowned / shared) push String entries that get
    # joined into one InlineZig blob; MVCC paths push structured MIR
    # nodes (MIR::SnapshotRead, MIR::SnapshotTransaction, etc.) that
    # the checker walks directly. Split + emit accordingly. Eventually
    # the legacy paths should also migrate off InlineZig (their patterns
    # are simpler than MVCC's so they're less urgent), but the MVCC
    # entries are not aggregated into the InlineZig blob.
    string_bindings = bindings.select { |b| b.is_a?(String) }.reject(&:empty?)
    mir_bindings    = bindings.reject { |b| b.is_a?(String) }
    all_bindings = string_bindings.join("\n")
    borrows = (node.capabilities || []).filter_map { |c|
      vn = c[:var_node]
      vn.respond_to?(:name) ? vn.name.to_s : nil
    }
    stmts = []
    (node.capabilities || []).each do |cap|
      stmts.concat(with_alias_ownership_marks(cap))
    end
    unless all_bindings.empty?
      bindings_iz = MIR::InlineZig.new(all_bindings, "with_block_bindings")
      sd = { allocates: false, borrows: borrows }
      sd[:fallible_clauses] = fallible_clauses unless fallible_clauses.empty?
      bindings_iz.stdlib_def = sd
      stmts << bindings_iz
    end
    stmts.concat(mir_bindings)
    stmts.concat(body_stmts)
    with_label ? MIR::BlockExpr.new(with_label, stmts) : MIR::ScopeBlock.new(stmts)
  end

  # Structured representation of a fallible-acquire clause for the BC
  # backend. The Zig backend renders the clause inline as Zig text via
  # `emit_fallible_lock_binding`; the BC backend can't parse the Zig
  # block, so it consumes this descriptor instead. `action_mir` is the
  # already-lowered MIR body (only for `:block`); `exit_msg_mir` is the
  # lowered message expression (only for `:exit`). `matched_types` and
  # `bubble_types` are the annotator-resolved selector lists; `retries`
  # is the RETRY(N) count or nil.
  sig { params(var_name: String, alias_name: String, clause: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def build_fallible_clause_mir(var_name, alias_name, clause)
    T.bind(self, MIRLowering) rescue nil
    desc = {
      var_name:      var_name.to_s,
      alias_name:    alias_name.to_s,
      action_kind:   clause[:action],
      retries:       clause[:retries],
      matched_types: clause[:matched_types] || [],
      bubble_types:  clause[:bubble_types] || [],
    }
    case clause[:action]
    when :block
      desc[:action_mir] = lower_body(clause[:body])
    when :exit
      desc[:exit_msg_mir] = lower(clause[:message])
    end
    desc
  end


  # WITH MATCH lowers to a comptime if-else chain that probes the bound
  # variable's wrapper type. Zig elides not-taken branches, so one function
  # body works for every family declared in REQUIRES.
  #
  # Family probes:
  #   :VERSIONED  -> @hasDecl(<inner_type>, "Inner")
  #                  Versioned(T) re-exports `pub const Inner = T`;
  #                  Locked(T) and bare T do not.
  #   :LOCKED   -> @hasField(<inner_type>, "mutex")
  #                  Locked(T) has a `mutex` field; bare T doesn't.
  #   :LOCAL      -> else branch (no probe; runtime fallback).
  #
  # Each probe is wrapped in a comptime Arc unwrap so bare and Arc-wrapped
  # callers share the same generated body.

  # Per-family probe for WITH MATCH dispatch. Routes through the
  # comptime helper `CheatLib.WithMatchInner` (runtime-header.zig)
  # which peels off an outer pointer and an outer Arc-wrapper to
  # reach the cell type. The same probe then matches whether the
  # caller's binding is `@versioned`, `@shared:versioned`, `@locked`,
  # or `@shared:locked` -- the parameter shape (pointer-to-T vs
  # value-Arc(T)) is invisible to the probe.
  #
  # Recognized families today: LOCKED, VERSIONED. ACTOR and LOCK_FREE
  # are parser-reserved but have no probe yet (raise on use). See
  # WithMatchCheck.LOCKED_SYNCS / VERSIONED_SYNCS for the inverse
  # mapping that classifies a binding's family at the call site.
  sig { params(family: Symbol, zig_var: String, node: T.nilable(AST::WithBlock)).returns(String) }
  def with_match_probe_for_family(family, zig_var, node = nil)
    T.bind(self, MIRLowering) rescue nil
    inner_t = "CheatLib.WithMatchInner(@TypeOf(#{zig_var}))"
    snapshot = node.respond_to?(:snapshot_mode) && T.must(node).snapshot_mode
    case family
    # Versioned and AtomicPtr both expose `pub const Inner = T`, so a
    # bare `@hasDecl(..., "Inner")` probe would match AtomicPtr too.
    # That's harmless in non-SNAPSHOT WITH MATCH (Versioned/AtomicPtr
    # never appear in those polymorphic call sites today) but
    # silently miscompiles in SNAPSHOT MATCH where AtomicPtr cells
    # are first-class. Tighten with `!@hasDecl(..., "compareAndPublish")`
    # which is unique to AtomicPtr -- routes AtomicPtr cells to the
    # ATOMIC arm in SNAPSHOT MATCH.
    when :VERSIONED
      if snapshot
        "(@hasDecl(#{inner_t}, \"Inner\") and !@hasDecl(#{inner_t}, \"compareAndPublish\"))"
      else
        "@hasDecl(#{inner_t}, \"Inner\")"
      end
    when :LOCKED then "@hasField(#{inner_t}, \"mutex\")"
    # Primitive atomics expose `cmpxchgStrong`; AtomicPtr exposes
    # `compareAndPublish`. Pick the probe from the surrounding mode.
    when :ATOMIC
      if snapshot
        "@hasDecl(#{inner_t}, \"compareAndPublish\")"
      else
        "@hasDecl(#{inner_t}, \"cmpxchgStrong\")"
      end
    else
      raise "WITH MATCH: no probe for family #{family.inspect} (only " \
            ":VERSIONED, :LOCKED, :ATOMIC are wired today)"
    end
  end

  # Resolve to a `*Inner` value regardless of param shape. Invalid
  # expressions in not-taken comptime branches are elided by Zig.
  sig { params(zig_var: String).returns(String) }
  def with_match_unwrap_value(zig_var)
    T.bind(self, MIRLowering) rescue nil
    is_ptr  = "@typeInfo(@TypeOf(#{zig_var})) == .pointer"
    inner_t = "@typeInfo(@TypeOf(#{zig_var})).pointer.child"
    "(if (comptime #{is_ptr}) " \
      "(if (comptime @typeInfo(#{inner_t}) == .@\"struct\") " \
        "(if (comptime @hasField(#{inner_t}, \"ctrl\")) #{zig_var}.ctrl.data else #{zig_var}) " \
       "else " \
        "(if (comptime @typeInfo(#{inner_t}) == .pointer) " \
          "(if (comptime @typeInfo(@typeInfo(#{inner_t}).pointer.child) == .@\"struct\") " \
            "(if (comptime @hasField(@typeInfo(#{inner_t}).pointer.child, \"ctrl\")) #{zig_var}.*.ctrl.data else #{zig_var}.*) " \
           "else #{zig_var}.*) " \
         "else #{zig_var})) " \
    "else " \
      "(if (comptime @typeInfo(@TypeOf(#{zig_var})) == .@\"struct\") " \
        "(if (comptime @hasField(@TypeOf(#{zig_var}), \"ctrl\")) #{zig_var}.ctrl.data else &#{zig_var}) " \
       "else &#{zig_var}))"
  end

  # Per-arm prelude that binds the user's alias (`va` in
  # `WITH c AS va MATCH`) to a `*Inner` for this arm's family.
  # Both VERSIONED and LOCKED arms produce `const <alias>: *T = ...`
  # so the body's `<alias>.field` access lowers identically across
  # families. The Guard's `defer release()` handles teardown.
  sig { params(family: Symbol, zig_var: String, alias_name: String, node: AST::WithBlock).returns(T.nilable(String)) }
  def with_match_arm_prelude(family, zig_var, alias_name, node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    safe_alias = zig_safe_name(alias_name)
    unwrap = with_match_unwrap_value(zig_var)
    guard_var = "__#{alias_name}_match_#{node.object_id.abs}"
    case family
    when :VERSIONED
      <<~ZIG.rstrip
        var #{guard_var} = #{unwrap}.*.read(#{@rt_name});
        defer #{guard_var}.release();
        const #{safe_alias} = #{guard_var}.get();
        _ = &#{safe_alias};
      ZIG
    when :LOCKED
      <<~ZIG.rstrip
        var #{guard_var} = #{unwrap}.*.acquire();
        defer #{guard_var}.release();
        const #{safe_alias} = #{guard_var}.get();
        _ = &#{safe_alias};
      ZIG
    # Atomic primitives have no Guard/acquire/release; the alias binds
    # directly to the cell pointer so arm bodies can call atomic methods.
    #
    # In SNAPSHOT MATCH, AtomicPtr binds through a Guard like VERSIONED.
    # Mutable publish-via-CAS requires a larger lowering change.
    when :ATOMIC
      if node.respond_to?(:snapshot_mode) && node.snapshot_mode
        <<~ZIG.rstrip
          var #{guard_var} = #{unwrap}.*.read(#{@rt_name});
          defer #{guard_var}.release();
          const #{safe_alias} = #{guard_var}.get();
          _ = &#{safe_alias};
        ZIG
      else
        <<~ZIG.rstrip
          const #{safe_alias} = #{unwrap};
          _ = &#{safe_alias};
        ZIG
      end
    end
  end

  sig { params(node: AST::WithBlock).returns(MIR::ScopeBlock) }
  def lower_with_match_block(node)
    T.bind(self, MIRLowering) rescue nil
    cap = node.capabilities.first
    var_name = with_cap_var_name(cap[:var_node])
    zig_var  = with_cap_zig_target(cap[:var_node], var_name)
    alias_name = cap[:alias] || var_name

    arms_meta = node.arms.map { |arm|
      {
        family:      arm[:family],
        probe:       with_match_probe_for_family(arm[:family], zig_var, node),
        prelude_zig: with_match_arm_prelude(arm[:family], zig_var, alias_name, node),
        body:        lower_body(arm[:body]),
      }
    }
    MIR::ScopeBlock.new([MIR::WithMatchDispatch.new(zig_var, arms_meta)])
  end

  # Emit the acquire-or-catch binding for a fallible lock under a
  # WithBlock#lock_error_clause. The switch dispatches per error type
  # using the error registry:
  #   - Types in clause[:matched_types]  -> run the user action.
  #   - Types in clause[:bubble_types]   -> setError(kind, name) + return
  #                                         error.CheatError.
  # Deadlock is always in bubble_types unless the user explicitly selected
  # it (e.g. `ON :Deadlock -> { ... }`), in which case its action runs.
  sig { params(acquire_call: String, guard_var: String, alias_name: String, clause: T::Hash[Symbol, T.untyped], with_label: T.nilable(String), with_node: AST::WithBlock).returns(String) }
  def emit_fallible_lock_binding(acquire_call, guard_var, alias_name, clause, with_label, with_node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    action_zig = emit_lock_action_zig(clause, with_label, with_node)
    retries    = clause[:retries]
    matched    = clause[:matched_types]
    bubble     = clause[:bubble_types]
    acquire_blk = "__acq_#{with_node.object_id.abs}_#{guard_var}"
    line = with_node.token&.line.to_s

    arms = []
    unless matched.empty?
      matched_errs = matched.map { |t| "error.#{AST.zig_name_of_type(t)}" }.join(", ")
      if retries
        arms << "#{matched_errs} => { if (__retry + 1 < #{retries}) continue;\n#{action_zig} }"
      else
        arms << "#{matched_errs} => { #{action_zig} }"
      end
    end
    bubble.each do |t|
      zig = AST.zig_name_of_type(t)
      kind = AST.kind_of_type(t)
      arms << %Q(error.#{zig} => { #{@rt_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{zig}), "lock #{zig}", #{line}); return error.CheatError; })
    end
    handler = "switch (__err) {\n#{arms.join(",\n")}\n}"

    if retries
      acquire_expr = <<~ZIG.rstrip
        #{acquire_blk}: {
          var __retry: usize = 0;
          while (true) : (__retry += 1) {
            if (#{acquire_call}) |__g| {
              break :#{acquire_blk} __g;
            } else |__err| {
              #{handler}
            }
          }
        }
      ZIG
    else
      acquire_expr = <<~ZIG.rstrip
        #{acquire_blk}: {
          if (#{acquire_call}) |__g| {
            break :#{acquire_blk} __g;
          } else |__err| {
            #{handler}
          }
        }
      ZIG
    end

    <<~ZIG.rstrip
      var #{guard_var} = #{acquire_expr};
      defer #{guard_var}.release();
      const #{alias_name} = #{guard_var}.get();
      _ = &#{alias_name};
    ZIG
  end

  # Emit a single-cell or multi-cell snapshot transaction whose closure
  # runs the WITH body. Conflict handlers become catch arms.
  #
  # Single-cell shape:
  #   cell.update(rt, alloc, struct {
  #     fn run(va: *T) void { <body_zig> }
  #   }.run, .{}) catch |__err| switch (__err) {
  #     error.UpdateRetriesExhausted => { <conflict_action> },
  #     else => return __err,
  #   };
  #
  # Multi-cell shape:
  #   CheatLib.versionedUpdateMulti(.{a, b, ...}, rt, alloc, struct {
  #     fn run(views: anytype) anyerror!void {
  #       const va = views[0]; _ = &va;
  #       const vb = views[1]; _ = &vb;
  #       <body_zig>
  #     }
  #   }.run, .{}) catch |__err| switch (__err) {
  #     error.UpdateRetriesExhausted => { <conflict_action> },
  #     else => return __err,
  #   };
  # Return structured MIR so the checker can see the transaction body and
  # runtime heap allocation instead of treating them as opaque InlineZig.
  sig { params(node: AST::WithBlock).returns(T.untyped) }
  def lower_polymorphic_universal(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @atomic_emit_raw = T.let(@atomic_emit_raw, T.untyped)
    @current_fn_return_payload_zig = T.let(@current_fn_return_payload_zig, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    cap = node.capabilities.first
    var_node   = cap[:var_node]
    var_name   = with_cap_var_name(var_node)
    alias_name = cap[:alias] || var_name
    safe_alias = zig_safe_name(alias_name)
    # Emit the cell raw, with no auto-`.load()` injection. The atomic-
    # cell read path that visit_Identifier installs (line 4056 in
    # annotator/helpers/cell access) wraps `@atomic` reads in `.load()`,
    # which returns a value -- but `polymorphicMutate` needs the cell
    # OBJECT to dispatch by `@hasDecl`. Set `@atomic_emit_raw` so the
    # surrounding emit_expr returns the bare ident.
    prev_raw = @atomic_emit_raw
    @atomic_emit_raw = true
    cell_zig = emit_expr(lower(var_node))
    @atomic_emit_raw = prev_raw
    cell_zig = "&#{cell_zig}"
    # The body's `x` alias is a `*T` -- grab the bare T (post-Arc,
    # post-sync-wrapper) for the closure signature.
    resolved   = cap[:resolved_type]
    rt_obj     = resolved.is_a?(Type) ? resolved : Type.new(resolved)
    bare_t_zig = rt_obj.respond_to?(:bare_data_type) ? rt_obj.bare_data_type.zig_type : rt_obj.zig_type
    body_mir = lower_body(node.body)
    guard_cond = combined_guard_cond(node)
    if polymorphic_flow_required?(node)
      guard_fail = guard_cond ? guard_fail_flow_body(node) : []
      MIR::PolymorphicMutateFlow.new(
        cell_zig, @rt_name, safe_alias, bare_t_zig,
        @current_fn_return_payload_zig || "void",
        body_mir, guard_cond, guard_fail
      )
    else
      body_mir = wrap_body_with_guard(node, T.must(body_mir), nil)
      MIR::PolymorphicMutate.new(cell_zig, @rt_name, safe_alias, bare_t_zig, body_mir)
    end
  end

  sig { params(node: AST::WithBlock).returns(T::Boolean) }
  def polymorphic_flow_required?(node)
    T.bind(self, MIRLowering) rescue nil
    return true if (node.capabilities || []).any? { |cap| cap[:guard_expr] }
    ast_contains_return?(node.body)
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def ast_contains_return?(node)
    T.bind(self, MIRLowering) rescue nil
    case node
    when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      false
    when Array
      node.any? { |item| ast_contains_return?(item) }
    when Hash
      node.values.any? { |item| ast_contains_return?(item) }
    when AST::FunctionDef
      false
    when AST::ReturnNode
      true
    else
      node.respond_to?(:each_pair) && node.each_pair.any? { |_, v| ast_contains_return?(v) }
    end
  end

  sig { params(node: AST::WithBlock).returns(T.nilable(T.any(T::Array[T.untyped], T::Array[T.untyped]))) }
  def guard_fail_flow_body(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    clause = node.lock_error_clause
    return [] unless clause && (clause[:matched_types] || []).include?(:GuardFail)

    line = node.token&.line.to_s
    case clause[:action]
    when :pass
      []
    when :return
      [MIR::ReturnStmt.new(lower(clause[:value]))]
    when :raise
      fail = MIR::InlineZig.new(%Q(#{@rt_name}.setError(.Transient, @intFromEnum(ErrorName.GuardFail), "WITH GUARD predicate failed", #{line})), "with_guard_fail_raise")
      fail.stdlib_def = FunctionSignature.empty_borrow_intrinsic
      flow = MIR::InlineZig.new("__flow.* = .{ .kind = .raise_no_commit }", "with_guard_fail_raise_flow")
      flow.stdlib_def = FunctionSignature.empty_borrow_intrinsic
      [
        MIR::ExprStmt.new(fail, false),
        MIR::ExprStmt.new(flow, false),
        MIR::ReturnStmt.new(nil)
      ]
    when :exit
      msg_zig = emit_expr(lower(clause[:message]))
      fail = MIR::InlineZig.new(%Q(#{@rt_name}.setError(.Transient, @intFromEnum(ErrorName.GuardFail), #{msg_zig}, #{line})), "with_guard_fail_exit")
      fail.stdlib_def = FunctionSignature.empty_borrow_intrinsic
      flow = MIR::InlineZig.new("__flow.* = .{ .kind = .raise_no_commit }", "with_guard_fail_exit_flow")
      flow.stdlib_def = FunctionSignature.empty_borrow_intrinsic
      [
        MIR::ExprStmt.new(fail, false),
        MIR::ExprStmt.new(flow, false),
        MIR::ReturnStmt.new(nil)
      ]
    when :block
      lower_body(clause[:body])
    else
      []
    end
  end

  # Emit MIR for each PRE clause on a function definition. Each
  # predicate is lowered to a guarded if-statement that, when the
  # predicate is false, sets PreconditionFail on the runtime context
  # and returns the CheatError sentinel. Fail-fast: the first failing
  # PRE returns; later PREs are not evaluated.
  sig { params(node: AST::FunctionDef).returns(T::Array[T.untyped]) }
  def lower_pre_clauses(node)
    T.bind(self, MIRLowering) rescue nil
    pre_clauses = node.respond_to?(:pre_clauses) ? (node.pre_clauses || []) : []
    return [] if pre_clauses.empty?

    pre_clauses.map do |entry|
      expr   = entry[:expr]
      source = entry[:source]
      cond = lower(expr)
      line = expr.token ? expr.token.line.to_s : "0"

      msg_text = if source && !source.empty?
        "PRE failed: #{source}"
      else
        "precondition failed"
      end
      msg_zig = zig_string_lit(msg_text)

      fail_zig = %Q(#{@rt_name}.setError(.Input, @intFromEnum(ErrorName.PreconditionFail), #{msg_zig}, #{line});\nreturn error.CheatError;)
      iz = MIR::InlineZig.new(fail_zig, "pre_fail")
      iz.stdlib_def = FunctionSignature.empty_borrow_intrinsic
      MIR::IfStmt.new(MIR::UnaryOp.new("!", cond), [iz], nil)
    end
  end

  # Escape an arbitrary Ruby string for embedding as a Zig string
  # literal. `\` and `"` are escape-prefixed; named-escape control
  # characters (\n \r \t) get their named form; every other byte in
  # 0x00..0x1F or 0x7F gets a `\xNN` hex escape. Anything 0x20+
  # (printable + UTF-8 high bytes) passes through verbatim — Zig
  # accepts UTF-8 in string literals.
  sig { params(text: String).returns(String) }
  def zig_string_lit(text)
    T.bind(self, MIRLowering) rescue nil
    out = +'"'
    text.each_byte do |b|
      case b
      when 0x5c  then out << '\\\\'      # backslash
      when 0x22  then out << '\\"'        # double quote
      when 0x0a  then out << '\\n'
      when 0x0d  then out << '\\r'
      when 0x09  then out << '\\t'
      when 0x00..0x1f, 0x7f
        out << format('\\x%02x', b)
      else
        out << b.chr(Encoding::ASCII_8BIT)
      end
    end
    out << '"'
    out
  end

  sig { params(node: AST::WithBlock, body_mir: T::Array[T.untyped], with_label: T.nilable(String)).returns(T::Array[T.untyped]) }
  def wrap_body_with_guard(node, body_mir, with_label)
    T.bind(self, MIRLowering) rescue nil
    guard_cond = combined_guard_cond(node)
    return body_mir unless guard_cond

    fail_body = guard_fail_body(node, with_label)
    [MIR::IfStmt.new(guard_cond, body_mir, fail_body)]
  end

  # Lower every per-capability `guard_expr` and AND them together so the
  # body runs only when every predicate holds (multi-object consistency).
  sig { params(node: AST::WithBlock).returns(T.nilable(MIR::BinOp)) }
  def combined_guard_cond(node)
    T.bind(self, MIRLowering) rescue nil
    guarded = (node.capabilities || []).select { |cap| cap[:guard_expr] }
    return nil if guarded.empty?
    guarded.map { |g| lower(g[:guard_expr]) }
           .reduce { |acc, e| MIR::BinOp.new("and", acc, e) }
  end

  sig { params(node: AST::WithBlock, with_label: T.nilable(String)).returns(T.nilable(T::Array[T.untyped])) }
  def guard_fail_body(node, with_label)
    T.bind(self, MIRLowering) rescue nil
    clause = node.lock_error_clause
    return nil unless clause && (clause[:matched_types] || []).include?(:GuardFail)

    action = emit_error_action_zig(clause, with_label, node, :GuardFail, "WITH GUARD predicate failed")
    iz = MIR::InlineZig.new(action, "with_guard_fail")
    iz.stdlib_def = FunctionSignature.empty_borrow_intrinsic
    [iz]
  end

  sig { params(node: AST::WithBlock, with_label: T.nilable(String)).returns(T.untyped) }
  def emit_snapshot_mutable_call(node, with_label)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    snap_caps = node.capabilities || []
    body_mir = lower_body(node.body)
    # User RETRY(N) wraps the whole snapshot call; runtime update helpers
    # already do their own inner CAS retry budget.
    retries = node.lock_error_clause&.dig(:retries)
    alloc_zig = "#{@rt_name}.heapAlloc()"

    if snap_caps.length == 1
      cap = snap_caps.first
      var_node   = cap[:var_node]
      var_name   = T.let(with_cap_var_name(var_node), String)
      alias_name = T.let(cap[:alias] || var_name, String)
      safe_alias = T.let(zig_safe_name(alias_name), T.nilable(String))
      source_zig = emit_expr(lower(var_node))
      # Shape-agnostic Arc-unwrap so the same emit works for *Versioned,
      # *Arc<Versioned>, and Arc<Versioned> by value (the BG-capture
      # case). Mirrors the read-mode SNAPSHOT path.
      source_unwrap = with_match_unwrap_value(T.must(source_zig))
      # cap[:resolved_type] sole producer is var_node.full_type!
      # (Type|nil via the full_type seam; never a Symbol).
      st = cap[:resolved_type] || Type.new(:Any)
      bare_t_zig = st.bare_data_type.zig_type
      # AtomicPtr commits surface AtomicConflict; Versioned commits surface
      # MvccConflict.
      sym = var_node.symbol
      is_atomic_ptr = sym && sym.atomic? && sym.indirect?
      conflict_error = is_atomic_ptr ? :AtomicConflict : :MvccConflict
      conflict_action = emit_conflict_action_zig(
        node.lock_error_clause, with_label, node, conflict_error,
      )
      MIR::SnapshotTransaction.new(
        source_unwrap, @rt_name, alloc_zig, safe_alias, bare_t_zig,
        body_mir, conflict_action, retries, with_label, is_atomic_ptr,
      )
    else
      cells_tuple = ".{ " + snap_caps.map { |c| emit_expr(lower(c[:var_node])) }.join(", ") + " }"
      alias_decls = snap_caps.each_with_index.map { |c, i|
        var_node   = T.let(c[:var_node], T.untyped)
        var_name   = T.let(with_cap_var_name(var_node), T.untyped)
        alias_name = T.let(c[:alias] || var_name, T.untyped)
        safe_alias = T.let(zig_safe_name(alias_name), T.untyped)
        "const #{safe_alias} = views[#{i}]; _ = &#{safe_alias};"
      }.join("\n            ")
      # Multi-cell SNAPSHOT is Versioned-only because AtomicPtr has no
      # portable multi-pointer CAS.
      conflict_action = emit_conflict_action_zig(
        node.lock_error_clause, with_label, node, :MvccConflict,
      )
      MIR::SnapshotMultiTxn.new(
        cells_tuple, @rt_name, alloc_zig, alias_decls,
        body_mir, conflict_action, retries, with_label,
      )
    end
  end

  # Emit the user's snapshot-conflict action using the conflict error chosen
  # for the cell family. Retry loops are handled around the transaction call,
  # not inside this action.
  sig { params(clause: T::Hash[Symbol, T::Array[T.untyped]], with_label: T.nilable(String), with_node: AST::WithBlock, conflict_error: Symbol).returns(String) }
  def emit_conflict_action_zig(clause, with_label, with_node, conflict_error = :MvccConflict)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    line = with_node.token&.line.to_s
    err_name = conflict_error.to_s
    msg = err_name == "AtomicConflict" ? "atomic CAS retries exhausted" : "MVCC commit conflict"
    return %Q(#{@rt_name}.setError(.Transient, @intFromEnum(ErrorName.#{err_name}), "#{msg}", #{line});\nreturn error.CheatError;) unless clause
    emit_error_action_zig(clause, with_label, with_node, conflict_error, msg)
  end

  # Zig statements for the matched-selector action. Must terminate: return
  # / @panic, or break :__with_<id> (for PASS / `-> { }`).
  sig { params(clause: T::Hash[Symbol, T.untyped], with_label: T.nilable(String), with_node: AST::WithBlock).returns(String) }
  def emit_lock_action_zig(clause, with_label, with_node)
    T.bind(self, MIRLowering) rescue nil
    emit_error_action_zig(clause, with_label, with_node, :LockTimeout, "lock acquire timed out")
  end

  sig { params(clause: T::Hash[Symbol, T::Array[T.untyped]], with_label: T.nilable(String), with_node: AST::WithBlock, error_type: Symbol, default_msg: String).returns(String) }
  def emit_error_action_zig(clause, with_label, with_node, error_type, default_msg)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    line = with_node.token&.line.to_s
    err_name = error_type.to_s
    kind = AST.kind_of_type(error_type) || :Transient
    case clause[:action]
    when :raise
      %Q(#{@rt_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{err_name}), "#{default_msg}", #{line});\nreturn error.CheatError;)
    when :exit
      msg_zig = emit_expr(lower(clause[:message]))
      %Q(#{@rt_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{err_name}), #{msg_zig}, #{line});\nreturn error.CheatError;)
    when :pass
      "break :#{with_label};"
    when :return
      value_zig = emit_expr(lower(clause[:value]))
      "return #{value_zig};"
    when :block
      body_zig = emit_stmts_zig(T.must(lower_body(clause[:body])))
      "#{body_zig}\nbreak :#{with_label};"
    else
      raise "Internal: unknown lock action #{clause[:action]}"
    end
  end

  # Build the per-capture entry list shared by the panicking and
  # fallible sorted-acquire emitters. `with_node` is the WithBlock AST
  # node; its object_id provides a per-WITH suffix so locals declared
  # at the bindings level (`__sort_guard_*`, `__held_*`) can never
  # collide with locals from a sibling or nested WITH that happens to
  # be lowered into the same Zig scope. Each WITH wraps its bindings
  # in its own labeled block today, so collisions are impossible in
  # practice, but the suffix makes the property defensible against
  # future lowering changes.
  sig { params(fallible_caps: T::Array[T::Hash[Symbol, T.untyped]], fallible: T::Boolean, with_node: T.nilable(AST::WithBlock)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def build_sorted_acquire_entries(fallible_caps, fallible:, with_node: nil)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    suffix = with_node ? "_#{with_node.object_id.abs}" : ""
    fallible_caps.each_with_index.map do |cap, i|
      var_name   = cap[:var_node].respond_to?(:name) ? cap[:var_node].name : cap[:var_node].to_s
      alias_name = cap[:alias] || var_name
      resolved   = cap[:resolved_type]
      zig_var    = @do_capture_map&.dig(var_name) || var_name
      var_storage = cap[:var_node].symbol&.storage
      is_arc = SymbolEntry.rc_storage?(var_storage) || resolved&.any_rc?
      lock_expr  = is_arc ? "#{zig_var}.ctrl.data.*" : zig_var
      addr_expr  = is_arc ? "#{zig_var}.ctrl.data" : "&#{zig_var}"
      var_sync   = cap[:var_node].symbol&.sync
      panic_method, err_method = case cap[:capability]
                                 when :EXCLUSIVE
                                   var_sync == :write_locked ? %w[write writeOrErr] : %w[acquire acquireOrErr]
                                 when :write_locked_read
                                   %w[read readOrErr]
                                 end
      {
        i: i, alias_name: alias_name,
        guard_var: "__sort_guard#{suffix}_#{i}",
        held_var:  "__held#{suffix}_#{i}",
        lock_expr: lock_expr, addr_expr: addr_expr,
        method: fallible ? err_method : panic_method,
      }
    end
  end

  # Emit Zig for acquiring N>=2 fallible lock captures in runtime
  # pointer-address order. Produces:
  #   - one __guardN per capture (undefined, typed via @TypeOf)
  #   - a __ptrs array of usize addresses
  #   - a __order index array, bubble-sorted by __ptrs
  #   - a for-loop over __order with a switch to call the right acquire()
  #   - defer __guardN.release() for each guard
  #   - const alias = __guardN.get() aliases
  # Uses panic-variant acquire methods (acquire / read / write); no
  # ON-clause handling. The fallible-variant emitter sits beside this.
  sig { params(fallible_caps: T::Array[T::Hash[Symbol, T.untyped]], with_node: T.nilable(AST::WithBlock)).returns(String) }
  def emit_sorted_lock_acquires(fallible_caps, with_node = nil)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    n = fallible_caps.length
    entries = build_sorted_acquire_entries(fallible_caps, fallible: false, with_node: with_node)

    guard_decls = entries.map { |e|
      "var #{e[:guard_var]}: @TypeOf(#{e[:lock_expr]}.#{e[:method]}()) = undefined;"
    }.join("\n")

    ptr_init = entries.map { |e| "@intFromPtr(#{e[:addr_expr]})" }.join(", ")
    order_init = (0...n).to_a.join(", ")

    switch_arms = entries.map { |e|
      "#{e[:i]} => #{e[:guard_var]} = #{e[:lock_expr]}.#{e[:method]}(),"
    }.join("\n                ")

    defer_releases = entries.map { |e| "defer #{e[:guard_var]}.release();" }.join("\n")
    alias_decls    = entries.map { |e|
      "const #{e[:alias_name]} = #{e[:guard_var]}.get();\n_ = &#{e[:alias_name]};"
    }.join("\n")

    <<~ZIG.rstrip
      #{guard_decls}
      {
          const __ptrs = [_]usize{ #{ptr_init} };
          var __order = [_]u8{ #{order_init} };
          var __i: usize = 0;
          while (__i < #{n}) : (__i += 1) {
              var __j: usize = 0;
              while (__j + 1 < #{n}) : (__j += 1) {
                  if (__ptrs[__order[__j]] > __ptrs[__order[__j + 1]]) {
                      const __tmp = __order[__j];
                      __order[__j] = __order[__j + 1];
                      __order[__j + 1] = __tmp;
                  }
              }
          }
          for (__order) |__idx| {
              switch (__idx) {
                #{switch_arms}
                else => unreachable,
              }
          }
      }
      #{defer_releases}
      #{alias_decls}
    ZIG
  end

  # Fallible variant of emit_sorted_lock_acquires. Uses the OrErr
  # acquire methods, tracks held guards in a per-cap bool, and on any
  # acquisition error releases held guards in reverse-acquisition order
  # before either retrying (`RETRY(N) THEN ...`) or running the user's
  # ON action. Defers at WITH-scope use the same held-bitmap so they're
  # safe no-ops on the failure path. The on-success path leaves all
  # __heldN flags true; the WITH body runs with all locks held; defers
  # release on scope exit as usual.
  sig { params(fallible_caps: T::Array[T.untyped], clause: T::Hash[T.untyped, T.untyped], with_label: T.nilable(T.any(NilClass, String)), with_node: AST::WithBlock).returns(String) }
  def emit_sorted_lock_acquires_fallible(fallible_caps, clause, with_label, with_node)
    T.bind(self, MIRLowering) rescue nil
    n = fallible_caps.length
    entries = build_sorted_acquire_entries(fallible_caps, fallible: true, with_node: with_node)

    action_zig = emit_lock_action_zig(clause, with_label, with_node)
    matched    = clause[:matched_types] || []
    bubble     = clause[:bubble_types]  || []
    retries    = clause[:retries]
    line       = with_node.token&.line.to_s
    acq_loop   = "__acq_sort_#{with_node.object_id.abs}"

    guard_decls = entries.map { |e|
      "var #{e[:guard_var]}: @TypeOf(try #{e[:lock_expr]}.#{e[:method]}()) = undefined;"
    }.join("\n")
    held_decls = entries.map { |e| "var #{e[:held_var]}: bool = false;" }.join("\n")

    ptr_init   = entries.map { |e| "@intFromPtr(#{e[:addr_expr]})" }.join(", ")
    order_init = (0...n).to_a.join(", ")

    acquire_arms = entries.map { |e|
      <<~ZIG.rstrip
        #{e[:i]} => {
                                        if (#{e[:lock_expr]}.#{e[:method]}()) |__g| {
                                            #{e[:guard_var]} = __g;
                                            #{e[:held_var]} = true;
                                        } else |__err_inner| {
                                            __err_caught = __err_inner;
                                            __success = false;
                                        }
                                    },
      ZIG
    }.join("\n                                ")

    release_arms = entries.map { |e|
      "#{e[:i]} => if (#{e[:held_var]}) { #{e[:guard_var]}.release(); #{e[:held_var]} = false; },"
    }.join("\n                            ")

    handler_arms = []
    unless matched.empty?
      matched_errs = matched.map { |t| "error.#{AST.zig_name_of_type(t)}" }.join(", ")
      handler_arms << "#{matched_errs} => { #{action_zig} }"
    end
    bubble.each do |t|
      zig = AST.zig_name_of_type(t)
      kind = AST.kind_of_type(t)
      handler_arms << %Q(error.#{zig} => { #{@rt_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{zig}), "lock #{zig}", #{line}); return error.CheatError; })
    end
    # Catch-all: __err_caught is `?anyerror`, so Zig requires an else
    # arm. Set a generic System error before propagating so callers
    # don't see CheatError with stale rt.__error content from a prior
    # operation. This path covers Zig errors that aren't in the
    # OrErr method's documented set (defensive).
    handler_arms << %Q(else => |__err_other| { #{@rt_name}.setError(.System, 0, @errorName(__err_other), #{line}); return error.CheatError; })
    handler_switch = "switch (__err_caught.?) {\n                    #{handler_arms.join(",\n                    ")},\n                }"

    retry_branch = if retries
      "if (__retry + 1 < #{retries}) continue;"
    else
      "// no retries configured"
    end

    defer_releases = entries.map { |e| "defer if (#{e[:held_var]}) #{e[:guard_var]}.release();" }.join("\n")
    alias_decls    = entries.map { |e|
      "const #{e[:alias_name]} = #{e[:guard_var]}.get();\n_ = &#{e[:alias_name]};"
    }.join("\n")

    <<~ZIG.rstrip
      #{guard_decls}
      #{held_decls}
      #{acq_loop}: {
          var __retry: usize = 0;
          while (true) : (__retry += 1) {
              const __ptrs = [_]usize{ #{ptr_init} };
              var __order = [_]u8{ #{order_init} };
              var __i: usize = 0;
              while (__i < #{n}) : (__i += 1) {
                  var __j: usize = 0;
                  while (__j + 1 < #{n}) : (__j += 1) {
                      if (__ptrs[__order[__j]] > __ptrs[__order[__j + 1]]) {
                          const __tmp = __order[__j];
                          __order[__j] = __order[__j + 1];
                          __order[__j + 1] = __tmp;
                      }
                  }
              }
              var __success = true;
              var __err_caught: ?anyerror = null;
              var __k: usize = 0;
              while (__k < #{n}) : (__k += 1) {
                  const __idx = __order[__k];
                  switch (__idx) {
                      #{acquire_arms}
                      else => unreachable,
                  }
                  if (!__success) break;
              }
              if (__success) break :#{acq_loop};
              var __r: usize = __k;
              while (__r > 0) {
                  __r -= 1;
                  switch (__order[__r]) {
                      #{release_arms}
                      else => unreachable,
                  }
              }
              #{retry_branch}
              #{handler_switch}
              unreachable;
          }
      }
      #{defer_releases}
      #{alias_decls}
    ZIG
  end


end
