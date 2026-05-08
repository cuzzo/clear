require_relative "type"
require_relative "schemas"

# ==========================================
# AST
# ==========================================
module AST
  # Walk all statements in a body, recursing into control flow branches.
  # Yields each statement node. Handles IfStatement, MatchStatement,
  # WhileLoop, ForRange, ForEach, and generic nodes with .body.
  # Adding a new control flow node type requires updating only this method.
  def self.walk_body(body, &visitor)
    return unless body
    Array(body).each do |node|
      yield node
      next unless node.is_a?(HasBodies)
      node.child_bodies.each { |b| walk_body(b, &visitor) }
    end
  end

  # Yield every BgBlock / BgStreamBlock reachable from `body`, including
  # nested ones inside control flow (WHILE/MATCH/IF/FOR/WITH/DO),
  # expression positions (VarDecl.value, FuncCall.args), and inside
  # other BG bodies. Use this when classifying every BG in a function.
  # The single source of truth replacing the parallel walkers in
  # escape_analysis (e2_each_bg) and elsewhere.
  def self.each_bg_block(body, &block)
    return unless body
    nodes = body.is_a?(Array) ? body : [body]
    nodes.each { |n| _bg_visit_recursive(n, &block) }
  end

  def self._bg_visit_recursive(node, &block)
    if node.is_a?(BgBlock) || node.is_a?(BgStreamBlock)
      yield node
    end
    case node
    when HasBodies
      node.child_bodies.each { |b| each_bg_block(b, &block) }
    when VarDecl, BindExpr, Assignment, ReturnNode
      _expr_each_bg_block_recursive(node.value, &block)
    when FuncCall
      node.args&.each { |a| _expr_each_bg_block_recursive(a, &block) }
    when MethodCall
      _expr_each_bg_block_recursive(node.object, &block)
      node.args&.each { |a| _expr_each_bg_block_recursive(a, &block) }
    end
  end

  def self._expr_each_bg_block_recursive(expr, &block)
    return unless expr
    case expr
    when BgBlock, BgStreamBlock
      yield expr
      each_bg_block(expr.body, &block)
    when FuncCall
      expr.args&.each { |a| _expr_each_bg_block_recursive(a, &block) }
    when MethodCall
      _expr_each_bg_block_recursive(expr.object, &block)
      expr.args&.each { |a| _expr_each_bg_block_recursive(a, &block) }
    end
  end

  # Yield ONLY the BgBlocks directly embedded in `stmt`'s expression
  # positions -- does NOT descend into nested control-flow branches OR
  # into the bodies of BGs found here. Use when emitting per-stmt MIR
  # markers (MIR::SuppressCleanup, MIR::Promote): nested control flow
  # gets its own transform_body call which handles its BGs separately;
  # nested BGs capture from their parent BG body's scope, not this
  # stmt's scope.
  def self.each_bg_block_in_stmt(stmt, &block)
    case stmt
    when BgBlock, BgStreamBlock
      yield stmt
    when VarDecl, BindExpr, Assignment
      _expr_each_bg_block_shallow(stmt.value, &block) if stmt.respond_to?(:value)
    when FuncCall
      stmt.args&.each { |a| _expr_each_bg_block_shallow(a, &block) }
    when MethodCall
      _expr_each_bg_block_shallow(stmt.object, &block)
      stmt.args&.each { |a| _expr_each_bg_block_shallow(a, &block) }
    when ReturnNode
      _expr_each_bg_block_shallow(stmt.value, &block) if stmt.respond_to?(:value)
    end
  end

  def self._expr_each_bg_block_shallow(expr, &block)
    return unless expr
    case expr
    when BgBlock, BgStreamBlock
      yield expr
      # Stop here -- do not descend into BG body.
    when FuncCall
      expr.args&.each { |a| _expr_each_bg_block_shallow(a, &block) }
    when MethodCall
      _expr_each_bg_block_shallow(expr.object, &block)
      expr.args&.each { |a| _expr_each_bg_block_shallow(a, &block) }
    end
  end

  # Yield every CaptureAnalysis instance reachable from `body`. A
  # CaptureAnalysis is attached to any "fiber-like context" -- BG block,
  # BgStream block, DO block branch, or ConcurrentOp (CONCURRENT
  # SELECT/WHERE/EACH/etc.). All four use the same `analyze_fiber_captures`
  # machinery; this single walker lets BgCaptureClassifier process every
  # one with one pass per function. Replaces the per-source-type
  # iteration that used to live in lower_bg_block, lower_do_block, and
  # the pipeline_host concurrent lowerings.
  def self.each_capture_analysis(body, &block)
    each_bg_block(body) do |bg|
      yield bg.capture_analysis if bg.capture_analysis
    end
    walk_body(body) do |node|
      if node.is_a?(DoBlock)
        node.branches&.each do |b|
          yield b[:capture_analysis] if b[:capture_analysis]
        end
      end
      _expr_each_concurrent_capture(node, &block)
    end
  end

  def self._expr_each_concurrent_capture(node, &block)
    case node
    when ConcurrentOp
      yield node.capture_analysis if node.capture_analysis
    when BinaryOp
      # `x |> CONCURRENT EACH { ... }` parses as BinaryOp(op=:SMOOTH);
      # the ConcurrentOp lives on .right. (Other binary ops can also
      # contain ConcurrentOps in either side via nested expressions.)
      _expr_each_concurrent_capture(node.left, &block) if node.respond_to?(:left)
      _expr_each_concurrent_capture(node.right, &block) if node.respond_to?(:right)
    when VarDecl, BindExpr, Assignment
      _expr_each_concurrent_capture(node.value, &block) if node.respond_to?(:value)
    when ReturnNode
      _expr_each_concurrent_capture(node.value, &block) if node.respond_to?(:value)
    when FuncCall
      node.args&.each { |a| _expr_each_concurrent_capture(a, &block) }
    when MethodCall
      _expr_each_concurrent_capture(node.object, &block)
      node.args&.each { |a| _expr_each_concurrent_capture(a, &block) }
    end
  end

  # Declarative metadata for AST nodes that own one or more statement
  # lists (control flow, blocks, function bodies). Generic walkers like
  # `walk_body` iterate via `child_bodies` instead of hand-coded
  # case chains. Adding a new such node type means including this and
  # defining child_bodies — no walker edit required.
  module HasBodies
    # Override in including classes. Returns Array of stmt lists (each
    # itself an Array of statements). Nil/empty entries are filtered by
    # the walker via `Array(...)`/`.compact`.
    def child_bodies
      []
    end
  end

  module Locatable
    def line; token.line; end
    def column; token.column; end
    def token_value; token.value; end

    attr_reader :coerced_type_object
    attr_reader :type_object
    attr_accessor :zig_pattern
    attr_accessor :matched_stdlib_def  # Hash from STD_LIB entry (for return_alloc etc.)
    attr_accessor :stdlib_allocates  # true when matched stdlib entry has allocates: true
    attr_accessor :mutates_receiver  # true when matched stdlib entry has mutates_receiver: true
    attr_accessor :was_moved
    attr_accessor :container_borrow     # true when value is borrowed from container (map/list/pool access)
    attr_accessor :needs_mut_ref        # true when GetIndex must emit pointer access (mutation through indexed element)
    attr_accessor :target_is_list_field # true when value targets a struct/union @list field (skip .items conversion)
    attr_accessor :needs_heap_create    # true when value must be heap-allocated via create(*T) — @indirect union payload
    attr_accessor :collection_return    # true when return value is a collection needing escape promotion
    attr_accessor :slot_size
    attr_accessor :resource_close_zig   # set by annotator on resource declarations
    attr_accessor :can_fail             # true when this call node can produce an error (stdlib can_fail, user !T return)
    attr_accessor :error_kind           # Symbol — one of the 6 kinds (:Transient, :Input, :System, :NotFound, :Permission, :Canceled); nil = unclassified
    attr_accessor :error_type           # Symbol — specific error name (:LockTimeout, :LockCycle, :Deadlock, ...); nil = unspecified. Narrower than error_kind.
    attr_accessor :var_used             # true when the variable is read in user code
    attr_accessor :var_mutated          # true when the variable is reassigned after declaration
    attr_accessor :symbol               # SymbolEntry — set by annotator for resolved bindings

    # Set full_type. Accepts a Type object (stored directly) or any other
    # value (wrapped in Type.new for backward compatibility).
    def full_type=(val)
      @type_object = val.is_a?(Type) ? val : Type.new(val)
    end

    # Returns the Type object directly. Callers use type_info for rich access
    # and == / .to_s / Type.new(full_type) for interop.
    def full_type
      @type_object
    end

    def coerced_type=(val)
      return @coerced_type_object = nil if val.nil?

      # Same logic: Wrap raw values, accept Type objects
      @coerced_type_object = val.is_a?(Type) ? val : Type.new(val)
    end

    def coerced_type
      @coerced_type_object&.raw
    end

    # Use this to access the rich object for coerced types
    def coerced_type_info
      @coerced_type_object
    end

    # Resolves the final type, handling coercion if needed.
    # Returns [final_type, error]. Error is nil if ok.
    #
    # @param declared_type [Symbol, nil] The explicitly declared type (or nil/:Any for inference)
    # @return [Array(Symbol, String|nil)] [final_type, error_message]
    #
    def coerce!(declared_type)
      # fn_type must not be flattened to its return type — preserve the full Type object.
      return [@type_object, nil] if @type_object&.fn_type? && (declared_type.nil? || declared_type == :Any)

      inferred = @type_object&.resolved

      # No explicit type or :Any -> use inferred, no coercion needed
      return [inferred, nil] if declared_type.nil? || declared_type == :Any

      # Explicit type matches inferred -> no coercion needed
      return [declared_type, nil] if declared_type == inferred

      # Check if coercion is valid
      error = Type.coerce_error(@type_object, declared_type)
      return [nil, error] if error

      # Valid coercion - set coerced_type and return declared
      self.coerced_type = declared_type
      [declared_type, nil]
    end

    # Finalizes storage for a declaration node (VarDecl, etc.).
    # Calculates slot_size, determines storage, and sets full_type.
    # Returns the storage location (:stack, :frame, :heap).
    #
    # @param final_type [Symbol] The resolved type after coercion
    # @yield [name] Block to look up struct schema by name
    # @return [Symbol] The storage location
    #
    def finalize_storage!(final_type, &schema_lookup)
      # Calculate slot size
      type_obj = Type.new(final_type)
      @slot_size = type_obj.slot_size(&schema_lookup)

      # Determine storage from value's type if this node has a value
      if respond_to?(:value) && value.type_object
        value_type = value.type_object
        storage = value_type.finalize_storage(@slot_size, value.storage)
        # Declared type overrides: pointer types (%Type annotation) or sync types
        storage = :heap if type_obj.heap? || type_obj.any_sync?
        # Declared @list annotation requires frame (unless already upgraded to heap)
        storage = :frame if type_obj.list_collection? && storage != :heap
        value.storage = storage if value.respond_to?(:storage=)
      else
        storage = type_obj.finalize_storage(@slot_size, nil)
      end

      # Determine if value has a sync capability
      value_sync = nil
      if respond_to?(:value) && value.type_object
        vt = value.type_object
        value_sync = vt.sync
      end

      # Build a Type that carries the resolved base type plus storage-derived capabilities.
      # For fn_type, preserve the full type object — do not reduce to the return-type symbol.
      t = if final_type.is_a?(Type) && final_type.fn_type?
        final_type
      else
        base_sym = final_type.is_a?(Type) ? final_type.resolved : final_type
        new_t = Type.new(base_sym)
        # Carry shard_count + sync + soa through finalize — not encoded in the base symbol.
        # Check both final_type and the value's type_info (for constructor sugar: List[], Pool[]).
        val_ti = respond_to?(:value) && value.respond_to?(:type_info) ? value.type_info : nil
        new_t.shard_count = final_type.shard_count if final_type.is_a?(Type) && final_type.shard_count
        new_t.shard_count ||= val_ti.shard_count if val_ti&.shard_count
        new_t.sync = final_type.sync if final_type.is_a?(Type) && final_type.sync
        new_t.soa = final_type.soa if final_type.is_a?(Type) && final_type.soa
        new_t.soa ||= val_ti.soa if val_ti&.respond_to?(:soa) && val_ti.soa
        new_t.collection = val_ti.collection if val_ti&.collection && !new_t.collection
        # Carry @observable through finalize_storage! — without this the
        # binding's full_type loses the @is_observable bit and downstream
        # cleanup classification can't recognise `~T@observable`. The
        # terminal kind (`:sum`/`:count`/.../`:distinct`) must come along
        # too so OBSERVABLE_WRAPPERS can pick the right wrapper Zig type;
        # without it the lookup falls back to a default and silently
        # emits the wrong wrapper.
        new_t.is_observable = true if (final_type.is_a?(Type) && final_type.observable?) ||
                                       (val_ti.respond_to?(:observable?) && val_ti.observable?)
        if final_type.is_a?(Type) && final_type.observable_terminal
          new_t.observable_terminal = final_type.observable_terminal
        elsif val_ti.respond_to?(:observable_terminal) && val_ti.observable_terminal
          new_t.observable_terminal = val_ti.observable_terminal
        end
        new_t.elem_ownership = final_type.elem_ownership if final_type.is_a?(Type) && final_type.elem_ownership
        new_t.elem_ownership ||= val_ti.elem_ownership if val_ti&.respond_to?(:elem_ownership) && val_ti&.elem_ownership
        new_t.elem_sync = final_type.elem_sync if final_type.is_a?(Type) && final_type.elem_sync
        new_t.elem_sync ||= val_ti.elem_sync if val_ti&.respond_to?(:elem_sync) && val_ti&.elem_sync
        # Propagate @link_source from value's type
        if val_ti&.link?
          link_src = val_ti.link_source
          new_t.link_source = link_src if link_src
        end
        new_t
      end
      # Propagate @link ownership from the value's LinkNode
      val_ti = respond_to?(:value) && value.respond_to?(:type_info) ? value.type_info : nil
      if val_ti&.link?
        storage = :link
      end

      case storage
      when :frozen
        t.ownership = :frozen
      when :multiowned
        t.ownership = :multiowned
      when :shared
        t.ownership = :shared
      when :link
        t.ownership = :link
      when :rodata
        t.provenance = :rodata
      when :frame
        t.provenance = :frame
      when :heap
        if value_sync == :locked
          t.sync = :locked          # sync= setter sets provenance = :heap
        elsif value_sync == :write_locked
          t.sync = :write_locked    # sync= setter sets provenance = :heap
        else
          t.provenance = :heap
        end
        t.provenance = :heap
      # :stack — leave provenance nil; set_cleanup_alloc! may upgrade via ||= alloc
      end

      # Propagate additional capability fields from the value's type_object
      if respond_to?(:value) && value.type_object
        vt = value.type_object
        t.ownership = vt.ownership if vt.ownership && vt.ownership != :affine
        t.sync      = vt.sync      if vt.sync
        # AtomicPtr M3.5: carry the :layout axis (e.g. :indirect from
        # @indirect:atomic on the VALUE) into the binding's full_type
        # so visit_VarDecl's `node.type_info&.layout` -> SymbolEntry
        # propagation lands. Mirrors the sync line above.
        t.layout    = vt.layout    if vt.layout
      end

      self.full_type = t

      # Override storage in case Type's default differs from finalized storage
      self.storage = storage

      storage
    end

    # -- NEW PREFERRED ACCESSOR --
    # Use this in new code to get the rich object
    def type_info
      @type_object
    end

    # -- REFACTORED HELPERS --
    # Delegate to the new class
    def resolved_type
      @type_object&.resolved
    end

    def base_type
      @type_object&.base_type
    end

    def storage
      @storage_override || (@type_object && (@type_object.provenance || :stack))
    end

    def storage=(val)
      # Use a node-local override rather than mutating @type_object.provenance.
      # @type_object may be a shared Type (e.g. STRING_TYPE from std_lib, or the
      # function return type from FunctionSignature). Mutating it would corrupt every
      # other AST node that shares the same Type object. The override is node-local
      # so promote_expr_to_heap! can mark individual call-site nodes as heap without
      # touching the shared type.
      @storage_override = val
    end


    def metatype
      return :lambda if self.is_a?(LambdaLit)
      return :named_function if self.is_a?(FunctionDef)

      t = @type_object
      return nil unless t

      return :void if t.resolved == :Void
      return :die if t.resolved == :NoReturn
      return :array if t.array?
      return :hashmap if t.map?
      return :struct if !t.primitive?
      return :primitive
    end
  end

  Program      = Struct.new(:token, :statements) do
    include Locatable
    # True-Sync-Polymorphism (#325): the resolved program-level
    # SYNC POLICY (the user-written one if present, else the baked-in
    # system default). Stamped by SemanticAnnotator.visit_Program after
    # validation. Lowering (#328) reads this when filling unhandled
    # WITH error slots.
    attr_accessor :sync_policy
  end
  # kind: :local (REQUIRE "file.cht") or :package (REQUIRE "pkg:name")
  RequireNode  = Struct.new(:token, :path, :namespace, :kind) { include Locatable }
  FunctionDef  = Struct.new(:token, :name, :params, :captures, :return_type, :return_lifetime, :body, :catch_clauses, :default_catch, :visibility, :deferred_drops, :uses_frame) do
    include Locatable
    include HasBodies
    def child_bodies = [body].compact
    attr_accessor :type_params   # Array of type param name strings, e.g. ["T", "K"], or nil
    # Post-#335: the user EXPLICITLY wrote a `RETURNS T` clause (vs
    # implicit-Void / annotator-inferred return). Stamped at parse
    # time so the fallible-signature check only enforces on user-
    # authored return types.
    attr_accessor :explicit_return_type
    attr_accessor :requires      # P2: REQUIRES clause — { param_name => Set[Family] } or nil
                                 #     Family symbols: :LOCKED, :VERSIONED, :ACTOR, :LOCK_FREE
    attr_accessor :effect_set    # P3: projected EffectSet (yield/alloc_heap/io/fail)
                                 #     view over fn.effects + fn.can_fail
    attr_accessor :inferred_effects  # alias of effect_set; used by formatter
    attr_accessor :reentrant     # :reentrant, :non_reentrant, or nil (default: non-reentrant, no guard)
    attr_accessor :tail_call     # true if @reentrant:tailCall — compiler emits @call(.always_tail, ...)
    attr_accessor :reentrant_token   # Token for the legacy @reentrant annotation (drives `clear fix` span)
    attr_accessor :arrow_token       # Token for the `->` after the function header (drives REQUIRES insertion span)
    attr_accessor :name_token        # Token for the function name itself (drives the `!`-suffix fix for STYLE_MUTABLE_PARAM_NEEDS_BANG)
    # Phase 4f.2: { start_tok:, end_tok: } pair covering the full
    # `EFFECTS REENTRANT[:VARIANT]` clause text. Used by `clear fix`
    # to swap variants (e.g., `:THUNK` -> plain or `:NOT_LOGICAL`).
    attr_accessor :effects_span
    # Phase 4f.3: positive Int from `EFFECTS REENTRANT:MAX_DEPTH(N)`.
    # Set on parse; the bridge validates `!T` return and the prologue
    # codegen path emits `safety.enterDepth(@src(), N)` /
    # `defer safety.exitDepth(@src())`.
    attr_accessor :max_depth_n
    # When true, the function declared `:TIGHT` (or `:TIGHT:VARIANT`)
    # — skip the entry `rt.checkYield()` co-op-yield injection.
    # Mirrors `TIGHT WHILE`; same opt-out, same risks (long
    # workloads stall the scheduler). For `:MAX_DEPTH(N)` TIGHT is
    # IMPLIED and not user-settable; the bridge force-flips it on
    # iff `N <= YIELD_BUDGET`.
    attr_accessor :tight_reentrance
    # Token at the start of the return type annotation (after RETURNS,
    # past any lifetime-prefix). Used for fixable spans that prepend
    # `!` to the declared return type.
    attr_accessor :return_type_token
    # Thunk Phase 1: declared via `EFFECTS REENTRANT[:VARIANT]` after RETURNS.
    # Values:
    #   nil                       no declaration
    #   :reentrant                EFFECTS REENTRANT (plain — must run on @service or @size:canSmash)
    #   :reentrant_thunk          EFFECTS REENTRANT:THUNK (CPS state machine + trampoline; non-contagious)
    #   :reentrant_tail_call      EFFECTS REENTRANT:TAIL_CALL (self-loop; verified by stack pass)
    #   :reentrant_not_logical    EFFECTS REENTRANT:NOT_LOGICAL (runtime StackGuard;
    #                                                            requires `!T` return type)
    #   :reentrant_max_depth      EFFECTS REENTRANT:MAX_DEPTH(N) (runtime depth counter;
    #                                                             requires `!T` return type;
    #                                                             max_depth_n stamped on FunctionDef)
    # The annotator bridges this with the legacy `@reentrant`/`tail_call` attrs into a
    # canonical reentrance_kind via src/annotator-helpers/reentrance.rb (Phase 1.3).
    attr_accessor :effects_decl
    # Thunk Phase 1.3: canonical, post-bridge reentrance kind. Read THIS, not
    # `effects_decl` or `reentrant` directly. Same value space as effects_decl;
    # the bridge unifies legacy and new declarations into one field.
    attr_accessor :reentrance_kind
    # Thunk Phase 4c: when the splitter recognizes a simple-recurrence
    # shape on a `:reentrant_thunk` function, the annotator stamps the
    # Plan here and lifts the Phase 4b "non-tail" error. Phase 4d's
    # MIR lowering then synthesizes the trampoline body from this.
    attr_accessor :thunk_plan
    # Thunk Phase 4f.1: when every member of a `:reentrant_thunk` cycle
    # matches the tail-position-mutual shape, the annotator stamps a
    # MutualThunkPlan on each member naming the cycle and the per-
    # member tail target. MIR lowering synthesizes a tagged-union
    # trampoline body from it (one trampoline per entry fn; same union
    # shape across cycle members).
    attr_accessor :mutual_thunk_plan
    # Thunk Phase 1.2: `REQUIRES <name>: NON_REENTRANT` clauses constrain function-typed
    # parameters. Hash mapping param name (String) to constraint symbol (e.g. :non_reentrant).
    attr_accessor :requires_clauses
    attr_accessor :needs_rt      # computed by compute_needs_rt! post-pass; nil = not yet computed
    attr_accessor :can_fail      # computed by compute_can_fail! post-pass; nil = not yet computed
    attr_accessor :uses_heap     # true when body allocates from heap (rt.heapAlloc)
    attr_accessor :uses_alloc    # true when body calls stdlib fns that use rt.frameAlloc (e.g. append)
    attr_accessor :uses_rt       # true when body references rt without allocating (e.g. Versioned.read for EBR pin)
    attr_accessor :return_provenance # :rodata, :frame, :heap — provenance of the return value
    attr_accessor :effects       # Set of effect symbols, computed by EffectTracker post-pass
    attr_accessor :snapshot_types # Set of pipeline input types that could be snapshots (for CATCH)
    attr_accessor :stack_tier        # recommended fiber tier (:micro, :standard, :large, :xl)
    attr_accessor :stack_vars_bytes  # lower-bound estimate of stack-local variable bytes
    attr_accessor :has_promotion      # set by MIRPass when function has escape promotions
    attr_accessor :moved_guard_info   # stamped by MIRPass: { var_name => bool } for has_moved_guard lookups
    attr_accessor :cleanup_bindings   # stamped by MIRPass: { var_name => entry_hash } for MIRLowering
    attr_accessor :heap_carry_return      # true when a heap carry var is the return value (caller must free)
    attr_accessor :heap_carry_return_vars # Set of var names that are heap carry return vars (their cleanup is skipped inside __pr_body)
    # FSM Phase A: set by FsmClassifier. fsm_eligible=true means this function can be
    # compiled as an FsmTask (state-machine resume fn) rather than a stackful fiber.
    # fsm_suspend_points is an Array of { id:, kind:, node: } enumerating the
    # yield-relevant call sites inside the body.
    attr_accessor :fsm_eligible
    attr_accessor :fsm_ineligible_reason  # Symbol: :reentrant, :extern, :self_recursive, :no_suspends
    attr_accessor :fsm_suspend_points
    # PRE clauses: Array of expression AST nodes parsed from
    # `PRE: <expr>` between RETURNS and `->`. Each predicate is checked
    # at function entry, fail-fast, raising PreconditionFail.
    # See docs / spec/with_pre_spec.rb for semantics.
    attr_accessor :pre_clauses
    # DEBUG_POST clauses: same shape as pre_clauses (Array of
    # {expr:, source:}). Checked in a debug-only wrapper after the
    # function body returns; panics on violation. See spec/with_post_spec.rb.
    attr_accessor :post_clauses
    # True when declared via `METHOD name(...)` instead of `FN name(...)`.
    # Purely a fmt directive: METHOD-flagged FNs have their prefix call
    # sites (`foo(v, ...)`) rewritten to UFCS form (`v.foo(...)`) by
    # `clear fmt`. Semantically identical to FN — same lookup, same
    # call resolution, same UFCS at call sites at the language level.
    attr_accessor :is_method
  end
  StructDef    = Struct.new(:token, :name, :fields, :visibility, :type_params) { include Locatable }
  VarDecl      = Struct.new(:token, :name, :type, :value, :mutable) do
    include Locatable
    attr_accessor :mir_binding_entry  # stamped by CleanupClassifier: per-node cleanup entry (avoids same-name collision)
  end
  Assignment   = Struct.new(:token, :name, :value) do
    include Locatable
    attr_accessor :auto_lock  # set by annotator when target is @locked/@writeLocked (inline guard)
    attr_accessor :field_pre_cleanup  # stamped by MIRPass: { zig_type:, alloc: } for field overwrite cleanup
    attr_accessor :container_promote_zig_type  # stamped by MIRPass: Zig type string when indexed store needs frame-to-heap promote
    # Atomics M1.5: stamped by parser when `target += rhs` etc. desugars
    # into `target = target op rhs`. The annotator reads this to decide
    # whether the target's @atomic sync should rewrite the assignment to
    # an atomic_fetch_<op> instead of load+op+store.
    attr_accessor :compound_op
    # Atomics M1.5: stamped by annotator when target is @shared:atomic.
    # MIR-lowering reads this to emit MethodCall(cell, op, args) instead
    # of plain Set. One of: :store, :fetchAdd, :fetchSub, :fetchAnd,
    # :fetchOr, :fetchXor.
    attr_accessor :auto_atomic_op
  end
  # Keywordless bind: `x = val` or `x: Type = val`. Annotator sets mode to :decl or :assign.
  BindExpr     = Struct.new(:token, :name, :type, :value) do
    include Locatable
    attr_accessor :mode
    attr_accessor :reassign_cleanup  # stamped by MIRPass: { kind:, alloc: } for reassignment pre-cleanup
    attr_accessor :mir_binding_entry  # stamped by CleanupClassifier: per-node cleanup entry (avoids same-name collision)
    # Atomics M1.5: see Assignment#compound_op / #auto_atomic_op.
    attr_accessor :compound_op
    attr_accessor :auto_atomic_op
  end
  BinaryOp     = Struct.new(:token, :left, :op, :right) do
    include Locatable
    attr_accessor :string_concat  # true when this is string + (stamped by annotator)
    attr_accessor :storage        # :heap when carry-var concat promoted to heap (stamped by Phase 1.5c)
    attr_accessor :or_fallback_dupe  # true when OR_RESCUE fallback struct needs string-field heap dupe
    attr_accessor :paren_bind     # true when this :BIND_VAR was wrapped in parens: (expr AS name)
    # Lazy positions: fields whose lowering must NOT leak @pending_stmts to
    # outer scope. The lowering's `descend` helper consults this and wraps
    # the field's emission in MIR::BlockExpr when the field actually emitted
    # any pending allocs. OR_RESCUE's right side is the fallback expression;
    # its allocations must only run when the orelse short-circuits to it.
    def lazy_fields = (op == :OR_RESCUE ? [:right] : [])
    # Observable Phase 2.2: true on a `|> SUM/MAX/MIN/COUNT/AVERAGE/ANY/ALL/FIND/DISTINCT/REDUCE`
    # whose source is a still-running tense stream — fold terminal is backed by
    # an Observable<T> / atomic accumulator and may be observed via WITH VIEW.
    attr_accessor :observable_terminal
    # Pipeline-terminal observable wiring (Commit 3): set by the
    # annotator when the pipe's destination is a `~T@observable`
    # binding. Read by pipeline_generator.rb (Commit 4) to switch
    # from inline-fold to fiber-spawn-with-accumulator codegen.
    attr_accessor :observable_dest
  end
  UnaryOp      = Struct.new(:token, :op, :right) { include Locatable }
  # Thunk Phase 4.1 / 4.2: parser-only placeholder for `@thunk(N) f(args)`
  # and `@maxDepth(N) f(args)` call-site overrides. `kind` is :thunk or
  # :maxDepth. The annotator emits a "not yet implemented" diagnostic
  # for both -- runtime semantics defer to v0.3 (per-call-site
  # monomorphization of the callee).
  CallSiteOverride = Struct.new(:token, :kind, :n, :inner) { include Locatable }
  Identifier   = Struct.new(:token, :name) do
    include Locatable
    attr_accessor :fn_ref           # true when the identifier refers to a named function used as a value
    attr_accessor :heap_dupe_result # true when this identifier's value must be heap-duped at use site
    attr_accessor :atomic_borrow    # Atomics M1.7: true when sync=:atomic ident is in fn-arg position (skip load wrap)
    def wildcard?; false end
    def name; self[:name].to_s end
  end
  Literal      = Struct.new(:token, :type, :value, :storage) { include Locatable }
  ListLit      = Struct.new(:token, :items, :storage) { 
    include Locatable 

    def coerce!(declared_type)
      res, error = super(declared_type)
      return [nil, error] if error

      # Recursively coerce items if the container is being coerced
      if res && items.any?
        element_type = Type.new(res).element_type
        if element_type
          items.each { |item| item.coerce!(element_type.resolved) }
        end
      end
      [res, nil]
    end
  }
  HashLit      = Struct.new(:token, :pairs, :storage) { include Locatable }
  DefaultLit   = Struct.new(:token) { include Locatable }
  StructLit    = Struct.new(:token, :name, :fields, :storage, :type_args) do
    include Locatable
    # Parallel map of field_name (String) -> the lexer Token that parsed
    # the name. Populated by the parser so `clear fix` can locate a
    # misspelled field-name for a fixable edit span.
    attr_accessor :field_tokens
  end
  LambdaLit    = Struct.new(:token, :params, :captures, :body, :storage, :deferred_drops) { include Locatable }
  IfStatement  = Struct.new(:token, :condition, :then_branch, :else_branch, :then_drops, :else_drops) do
    include Locatable
    include HasBodies
    def child_bodies = [then_branch, else_branch].compact
    attr_accessor :expr_mode           # true when used as an expression (x = IF ...)
    attr_accessor :then_result_type    # Type of last value expression in then_branch
    attr_accessor :else_result_type    # Type of last value expression in else_branch
  end
  # IF x AS y [&& z AS a] THEN ... [ELSE ...] END
  # bindings: Array of { expr:, name:, name_token: }
  # single binding emits: if (expr) |y| { ... }
  # multi binding emits labeled block: blk: { const y = expr1 orelse break :blk; const a = expr2 orelse break :blk; ... }
  IfBind       = Struct.new(:token, :bindings, :then_branch, :else_branch) do
    include Locatable
  end
  WhileLoop    = Struct.new(:token, :condition, :do_branch, :deferred_drops) do
    include Locatable
    include HasBodies
    def child_bodies = [do_branch].compact
    attr_accessor :mark_per_iter
    attr_accessor :tight        # true when declared with TIGHT WHILE — no yield injection, no loop marks
  end
  WhileBindLoop = Struct.new(:token, :condition, :binding_name, :binding_token, :do_branch, :deferred_drops) do
    include Locatable
    include HasBodies
    def child_bodies = [do_branch].compact
    attr_accessor :mark_per_iter
    attr_accessor :tight
  end
  BreakNode    = Struct.new(:token) { include Locatable }
  ContinueNode = Struct.new(:token) { include Locatable }
  FuncCall     = Struct.new(:token, :name, :args) do
    include Locatable
    attr_accessor :module_alias
    attr_accessor :extern_call       # true when calling a native EXTERN FN (no rt, no try)
    attr_accessor :extern_effects    # Set of effect symbols (:Alloc, etc.) from EXTERN FN EFFECTS declaration
    attr_accessor :generic_type_args # Array of inferred type symbols for generic fns, e.g. [:Number]
    attr_accessor :fn_var_call       # true when calling a fn-type variable (not a named function)
    attr_accessor :pipe_lhs           # original LHS AST node when rewritten from pipeline (for CATCH snapshot)
    attr_accessor :heap_dupe_result  # true when result must be heap-duped (frame string escaping to outer container)
    attr_accessor :arg_families      # Atomics M1.6.5: per-arg Set<Family> for ?-form effect resolution
    attr_accessor :collapsed_errors  # True-Sync-Polymorphism (#329): Set<Symbol> of errors this
                                     # specific call site can surface, projected per actual-family of
                                     # each REQUIRES'd arg. Strictly a subset of the callee fn's full
                                     # !T error union -- for `tick(myVersioned)` where tick has
                                     # REQUIRES x: SNAPSHOTTED, this is {:MvccConflict} (not the full
                                     # {:MvccConflict, :AtomicConflict}). nil for calls that don't
                                     # touch any REQUIRES'd param's family axis.
    attr_accessor :error_union_type  # CLEAR's auto-propagate (post-#338): when the callee
                                     # returns `!T`, `full_type` is stripped to the success
                                     # type `T` (so `x = call()` makes x of type T). The
                                     # original `!T` is stashed here for OR-RESCUE consumers
                                     # that need to know whether to emit `catch fallback`
                                     # (error union) or `orelse fallback` (optional).
    def wildcard?; false end
    def name; self[:name].to_s end
  end

  MethodCall   = Struct.new(:token, :object, :name, :args) do
    include Locatable
    attr_accessor :pool_method    # :insert, :get, :remove — set by annotator for Pool dispatch
    attr_accessor :set_method     # :insert, :contains, :remove, :count — set by annotator for Set dispatch
    attr_accessor :map_method     # :delete, :contains, :count, :keys, :values — set by annotator for HashMap dispatch
    attr_accessor :extern_call       # true when calling a native EXTERN method
    attr_accessor :extern_effects    # Hash of effect symbols from EXTERN FN EFFECTS declaration
    attr_accessor :generic_type_args # Array of inferred type symbols for generic methods
    attr_accessor :heap_dupe_result  # true when result must be heap-duped (frame string escaping to outer container)
    def wildcard?; false end
    def name; self[:name].to_s end
  end
  GetField     = Struct.new(:token, :target, :field) do
    include Locatable
    def wildcard?; field == '*' end
    def name; target.name end
  end
  GetIndex     = Struct.new(:token, :target, :index) do
    include Locatable
    def name; target.name end
  end
  Cast         = Struct.new(:token, :value, :target) { include Locatable }
  ReturnNode   = Struct.new(:token, :value) do
    include Locatable
    attr_accessor :promote_ret_wrap       # :const or :var — set by MIRPass for return wrapping
    attr_accessor :catch_string_dupe_ret  # true: frame string in catch fn needs heap dupe on return
    attr_accessor :ret_field_promote_data # Hash { zig_type:, fields: } for struct field promotion on return
  end
  Assert       = Struct.new(:token, :condition, :message) { include Locatable }
  # RAISE Kind, ErrorName, "message"
  # kind: symbol (:Transient, :Input, :System, :NotFound, :Permission, :Canceled)
  # error_name: optional string (user-defined error enum name)
  # message_expr: optional string expression
  Raise        = Struct.new(:token, :kind, :error_name, :message_expr) { include Locatable }
  ThrowNode    = Struct.new(:token, :value) { include Locatable }
  DieNode      = Struct.new(:token, :status) { include Locatable }
  Slice        = Struct.new(:token, :target, :start, :end) { include Locatable }
  Require      = Struct.new(:token, :path) { include Locatable }
  # lock_error_clause: optional Hash describing ON TIMEOUT / RETRY handling for
  # EXCLUSIVE / write_locked_read captures. Shape:
  #   { action: :raise | :pass | :exit | :block, message: <string|nil>, body: <Array|nil>, retries: <Integer|nil> }
  # retries > 0 means RETRY(N) THEN <action>; retries nil/0 means plain ON TIMEOUT <action>.
  WithBlock    = Struct.new(:token, :capabilities, :body, :deferred_drops) do
    include Locatable
    include HasBodies
    def child_bodies = [body].compact
    attr_accessor :lock_error_clause
    # Per-WITH opt-out from a static nested-lock check. Hash shape:
    #   { kind: :deadlock | :lock_cycle, token: Token }
    # nil = no opt-out; annotator rejects violating nesting.
    attr_accessor :deadlock_escape
    # P2.3: arms for the WITH MATCH form. nil for plain WITH (single-family).
    # Array of { family: Symbol, body: [stmts], lock_error_clauses: [clause, ...], token: Token }.
    # Single-family WITH is a one-arm WithMatch internally; the parser
    # leaves arms nil when no MATCH keyword was used.
    attr_accessor :arms
    # Observables Phase 2.3/2.4: :view (cheap immutable borrow on
    # ~T@observable) or :materialized_view (owned snapshot on any ~T
    # aggregate). nil for traditional capability blocks.
    attr_accessor :view_kind
    # MVCC L4: :read for `WITH SNAPSHOT a AS y { ... }` (one or more
    # immutable cell views), :transaction for `WITH SNAPSHOT a AS
    # MUTABLE va, ... { ... } ON MvccConflict ...` (one or more mutable
    # cell views, ON MvccConflict required). nil for traditional
    # capability blocks. Each capability entry carries `:alias_mutable`
    # already; `snapshot_mode` is the rolled-up classification used by
    # downstream passes.
    attr_accessor :snapshot_mode
    # True-Sync-Polymorphism step 1: `WITH POLYMORPHIC ...` opts into
    # the polymorphic comptime-dispatch lowering. The annotator enforces
    # that POLYMORPHIC is required iff the binding's REQUIRES admits
    # more than one storage axis (and rejected otherwise).
    attr_accessor :polymorphic
    # True-Sync-Polymorphism Gate 3: stamped by the annotator on a
    # WITH POLYMORPHIC whose bound parameter has no narrow REQUIRES
    # (universal polymorphism — admits every sync family). The
    # lowering routes such a block to MIR::PolymorphicMutate, which
    # comptime-dispatches per the caller's actual sync family.
    attr_accessor :universal_poly
  end

  # True-Sync-Polymorphism step 1: top-level `SYNC POLICY START ... END`
  # block. The handlers list is the same shape as `WithBlock#lock_error_clause`
  # (an array of those clauses, since a SYNC POLICY may declare multiple).
  # Validation (single-instance, main-file-only, completeness, inline-only
  # error guard for Deadlock/LockCycle) lives in the annotator (#325).
  SyncPolicyDecl = Struct.new(:token, :handlers) { include Locatable }

  SelectOp     = Struct.new(:token, :expression) { include Locatable }
  WhereOp      = Struct.new(:token, :expression) { include Locatable }
  IndexOp      = Struct.new(:token, :expression) { include Locatable }
  ReduceOp     = Struct.new(:token, :initial_value, :expression) { include Locatable }
  OrderByOp    = Struct.new(:token, :expression) { include Locatable }
  LimitOp      = Struct.new(:token, :count) { include Locatable }
  UnnestOp     = Struct.new(:token, :expression) { include Locatable }
  DistinctOp   = Struct.new(:token, :expression) { include Locatable }
  # EachOp: side-effect iteration over a collection.
  # Uses `_` as the implicit item binding. Body is a list of statements.
  # Syntax: collection |> EACH { _.field = value; };
  # On sharded pools, auto-dispatches N parallel fibers (one per shard).
  EachOp       = Struct.new(:token, :body) { include Locatable }
  # TAP: side-effect observer — runs body for each item, returns original list unchanged.
  # Unlike EACH, TAP passes through the collection (not void).
  TapOp        = Struct.new(:token, :body) { include Locatable }
  # SKIP: skip first N elements, return rest (inverse of LIMIT).
  SkipOp       = Struct.new(:token, :count) { include Locatable }
  # COLLECT: pipe-terminal that consumes a `~T@observable` (typically
  # produced by a fold over a tense stream) by blocking until the
  # producer's `finish()`, then returning the underlying T. Lowers
  # to `lhs.next()` (same shape as NEXT for ~T promises).
  CollectOp    = Struct.new(:token) { include Locatable }
  # TAKE_WHILE: take elements from the front while predicate is true.
  TakeWhileOp = Struct.new(:token, :expression) { include Locatable }
  # WINDOW(size): sliding window of `size` elements. _ is the sub-slice.
  WindowOp = Struct.new(:token, :size, :expression) { include Locatable }
  # WINDOW(size: N, time: 'Xms'): batch/tumbling window. _ is a T[] batch.
  # options = { "size" => size_node, "time" => time_node } (at least one required)
  BatchWindowOp = Struct.new(:token, :options, :expression) { include Locatable }
  # JOIN(right_source) key_expr_or_lambda
  # Equi-join: shared key applied to both sides, or lambda(a, b) -> Bool.
  # Result: anonymous struct { left: L, right: ?R } for each left element.
  JoinOp = Struct.new(:token, :right_source, :key_expr) { include Locatable }
  # Phase 3 predicate query operators — return scalar values (not new lists).
  # All use `_` as the implicit item binding (like SELECT/WHERE).
  FindOp   = Struct.new(:token, :expression) { include Locatable } # ?ElemType
  AnyOp    = Struct.new(:token, :expression) { include Locatable } # Bool
  AllOp    = Struct.new(:token, :expression) { include Locatable } # Bool
  CountOp  = Struct.new(:token, :expression) { include Locatable } # Int64
  # Phase 4 numeric aggregation operators — expression must be numeric.
  # SUM/AVERAGE return 0 for empty list; MIN/MAX panic on empty list.
  SumOp     = Struct.new(:token, :expression) { include Locatable } # Number
  AverageOp = Struct.new(:token, :expression) { include Locatable } # Number
  MinOp     = Struct.new(:token, :expression) { include Locatable } # Number (panics on empty)
  MaxOp     = Struct.new(:token, :expression) { include Locatable } # Number (panics on empty)
  # ShardOp: route items to owning schedulers by key hash.
  # Syntax: collection |> SHARD(key_expr, target_map) |> CONCURRENT EACH { body }
  # key_expr uses `_` as the implicit item binding (consistent with SELECT/WHERE).
  # target_map is the @sharded HashMap whose shardIndex determines routing.
  ShardOp = Struct.new(:token, :key_expr, :target_map) { include Locatable }
  # ConcurrentOp: CONCURRENT modifier wrapping a pipeline op for parallel execution.
  # op: SelectOp | WhereOp | EachOp
  # options: Hash of String => ASTNode  (e.g. {"pool_size" => Literal(8)})
  ConcurrentOp = Struct.new(:token, :op, :options) do
    include Locatable
    attr_accessor :shard_context  # set by annotator: { map_var:, shard_count:, key_expr: }
    attr_accessor :capture_analysis
  end
  Placeholder  = Struct.new(:token) { include Locatable }
  Copy         = Struct.new(:token, :value) { include Locatable }
  OptionalUnwrap = Struct.new(:token, :target) do
    include Locatable
    def name; target.respond_to?(:name) ? target.name : nil end
  end
  OrRaise        = Struct.new(:token) { include Locatable }  # OR RAISE - bubble up error (Zig's try)
  # OR EXIT forms under the unified error system. Unspecified fields
  # inherit from the pre-existing rt.__error set by the failing call:
  #   OR EXIT "msg"                — message-only override (kind/type inherited)
  #   OR EXIT Kind                 — set kind, clear type
  #   OR EXIT Kind, "msg"          — kind + msg, clear type
  #   OR EXIT Kind, Type           — kind + type
  #   OR EXIT Kind, Type, "msg"    — full override
  #   OR EXIT Type                 — set type (kind auto-resolved)
  #   OR EXIT Type, "msg"          — type + msg
  OrExit         = Struct.new(:token, :kind, :error_name, :message) { include Locatable }
  OrPass         = Struct.new(:token) { include Locatable }  # OR PASS - ignore error, use undefined
  OrPrune        = Struct.new(:token) { include Locatable }  # OR PRUNE - discard error, skip item (concurrent only)
  OrBreak        = Struct.new(:token) { include Locatable }  # OR BREAK - error-to-break coercion in loops
  # CATCH block: error handler at function bottom. Multiple CATCH clauses + optional DEFAULT.
  # catch_clauses: [{ error_name: String|nil, with_msg: String|nil, body: [ASTNode] }]
  # default_body: [ASTNode] or nil
  CatchBlock     = Struct.new(:token, :catch_clauses, :default_body) { include Locatable }
  # RECOVER(default): pipeline operator that replaces errors with a default value.
  RecoverOp      = Struct.new(:token, :default_expr) { include Locatable }

  # BlockExpr: sequence of statements that produces a value.
  # Used by pipeline rewriter to express loops-that-return-a-value.
  # Transpiles to Zig labeled block: blk: { stmts; break :blk result; }
  # body: Array of statement AST nodes
  # result: AST node whose value is the block's result
  BlockExpr      = Struct.new(:token, :body, :result) { include Locatable }

  # StringConcat: flattened string concatenation.
  # parts: Array of AST nodes (strings, identifiers, expressions)
  # Rewritten from chained BinaryOp(:ADD) on string types.
  # Any backend emits a single allocation covering all parts.
  StringConcat   = Struct.new(:token, :parts) do
    include Locatable
    attr_accessor :storage  # :heap when carry-var concat promoted to heap (stamped by Phase 1.5c)
  end

  # CapabilityWrap: single AST node for all capability wrapping.
  # ownership: nil | :multiowned | :shared
  # sync:      nil | :locked | :write_locked | :local
  # layout:    nil | :indirect
  CapabilityWrap    = Struct.new(:token, :value, :ownership, :sync, :layout) do
    include Locatable
    # Optional integer rank on @locked(rank: N) / @writeLocked(rank: N).
    # Used by Phase 3 to prove LockCycle freedom: when all participating
    # locks are ranked, acquiring any lock requires the new rank to be
    # strictly greater than every held rank, which makes cycles
    # structurally unrepresentable.
    attr_accessor :lock_rank
  end
  MoveNode          = Struct.new(:token, :value) { include Locatable }  # MOVE expr               -> transfer Rc/Arc handle without retain
  CopyNode          = Struct.new(:token, :value) { include Locatable; attr_accessor :deep_copy }  # COPY expr -> explicit deep-copy; deep_copy: true for unions with heap variants
  CloneNode         = Struct.new(:token, :value) { include Locatable }  # CLONE expr              -> explicit handle retain for non-affine replay/shared futures
  ShareNode         = Struct.new(:token, :value) { include Locatable }  # SHARE expr              -> promote/retain as T@shared (semantic lowering follows)
  LinkNode          = Struct.new(:token, :value) { include Locatable }  # LINK expr               -> downgrade Rc/Arc to WeakRc/WeakArc
  ResolveNode       = Struct.new(:token, :value) { include Locatable }  # RESOLVE expr            -> upgrade WeakRc/WeakArc to ?Rc/?Arc
  FreezeNode        = Struct.new(:token, :value) { include Locatable }  # FREEZE expr             -> compact @multiowned tree into contiguous buffer
  # PassStmt: no-op statement (like Python's `pass`).
  PassStmt          = Struct.new(:token) { include Locatable }
  # StructPattern: destructuring pattern for MATCH.
  # fields: Array of { name: String, value: ASTNode | :wildcard }
  # partial: Boolean — true when `...` is present (remaining fields ignored)
  StructPattern     = Struct.new(:token, :fields, :partial) { include Locatable }
  # RangeLit: a range expression (start..<end) or (start..<=end).
  # inclusive: false = exclusive end (..<), true = inclusive end (..<=)
  RangeLit          = Struct.new(:token, :start, :finish, :inclusive) { include Locatable }
  # ExternFnDecl: EXTERN FN name<T>(params) RETURNS type [EFFECTS :alloc] FROM "module"
  # Or method:    EXTERN FN TypeName<T>.method(params) RETURNS type FROM "module"
  # Declares a native Zig/C function importable via @import("module").
  ExternFnDecl     = Struct.new(:token, :name, :params, :return_type, :from_module, :effects) {
    include Locatable
    attr_accessor :owner_type        # "TypeName" for method declarations (nil for free functions)
    attr_accessor :owner_type_params # [:T, :U] for TypeName<T, U>.method
    attr_accessor :fn_type_params    # [:T] for fnName<T>(...)
  }
  # ExternStructDecl: EXTERN STRUCT Name { fields } [CLOSE "method"] FROM "module"
  # Declares a native Zig/C struct type for CLEAR type-checking purposes.
  # CLOSE registers the type as a resource with auto-defer cleanup (RAII).
  ExternStructDecl = Struct.new(:token, :name, :fields, :from_module) {
    include Locatable
    attr_accessor :type_params   # [:T, :U] for EXTERN STRUCT Name<T, U>
    attr_accessor :close_method  # "deinit" for CLOSE "deinit" — auto-defer on scope exit
    attr_accessor :as_type       # "Parsed(JsonRecord)" for AS "ZigTypeExpr" — parameterized alias
  }
  # EnumDef: ENUM Name { Variant1, Variant2, ... }
  # Declares a Zig enum type. variants is an Array of variant name strings.
  EnumDef          = Struct.new(:token, :name, :variants, :visibility) { include Locatable }
  # UnionDef: UNION Name { Variant1: Type, Variant2: Type, UnitVariant }
  # Declares a Zig tagged union (union(enum)). variants is a Hash of
  # { "VariantName" => value } where value is:
  #   nil                                          — unit variant (void payload)
  #   Type object                                  — single-type payload (existing)
  #   { kind: :inline_struct, fields: { "f" => Type } } — inline struct payload (new)
  # methods (optional): Array of { token:, name:, params: [{name:, type:},...], return_type: }
  #   — compile-time constraints verified after function registration.
  UnionDef         = Struct.new(:token, :name, :variants, :visibility) do
    include Locatable
    attr_accessor :type_params   # Array of type param name strings, e.g. ["T"], or nil
    attr_accessor :methods       # Array of method requirement hashes, or nil
  end

  # UnionVariantLit: TypeName.VariantName{ field: val, ... }
  # Constructs an inline-struct variant of a union type.
  # union_name: String (e.g., "Shape"), variant_name: String (e.g., "Circle")
  # fields: Hash<String, ASTNode>
  UnionVariantLit  = Struct.new(:token, :union_name, :variant_name, :fields, :storage) { include Locatable }

  # StaticCall: TypeName::method(args) — type-level static method call.
  # type_name: AST::Identifier (the type), method_name: String, args: Array of ASTNode
  StaticCall        = Struct.new(:token, :type_name, :method_name, :args) { include Locatable }

  # DoBlock: fork-join parallel execution.
  # branches: Array of { body: Array<ASTNode>, pinned: Boolean, stack_size: :standard | :micro | :large | :xl | nil }
  # pinned=true      → dispatch to least-loaded scheduler (spawnBest) instead of current (submitSpawn)
  # stack_size nil   → defaults to :standard (16 KB total: 12 KB stack + 4 KB arena)
  DoBlock           = Struct.new(:token, :branches) do
    include Locatable
    include HasBodies
    def child_bodies = (branches || []).filter_map { |b| b[:body] }
  end

  # BgBlock: background execution — spawns a fiber and returns a linear Promise (~T).
  # body: Array of expression nodes. The last expression's type determines T.
  # Captured affine variables are MOVED into the fiber (not borrowed by pointer).
  # stack_size: :standard (default, 16 KB) | :micro (4 KB) | :large (64 KB) | :xl (256 KB)
  BgBlock           = Struct.new(:token, :body, :deferred_drops, :stack_size, :pinned, :parallel, :arena_mode, :can_smash) do
    include Locatable
    include HasBodies
    def child_bodies = [body].compact
    attr_accessor :return_provenance # :heap when BG body calls a returns_promoted function
    attr_accessor :computed_stack_tier  # auto-computed tier from call-graph analysis (:micro, :standard, :large, :xl)
    attr_accessor :captures_resource  # true when BG captures a TCP/resource fd — spawn on accepting scheduler
    attr_accessor :capture_analysis  # CaptureAnalysis: captures, strategies, derived sets, safety flags
    attr_accessor :exit_promote  # Hash { strategy: :string_dupe } when exit value needs scope-exit promotion
    attr_accessor :capture_string_dupes  # Set of capture names that need heap-dupe inside the BG run fn
    # FSM Phase A: spawn_form = :fsm or :stackful. Chosen by FsmClassifier based
    # on the BG body's transitive call set. Phase A only records this; Phase B
    # will use it to emit spawnFsmBest / spawnFsmOn instead of spawnBest.
    attr_accessor :spawn_form
    attr_accessor :fsm_ineligible_reason
    attr_accessor :fsm_suspend_points
    # Phase 4g: tokens that drive `clear fix` for stack-tier sigil
    # rewrites. open_brace_token = `{` (insert @service -> after);
    # prefix_token = the user's existing tier sigil (replace).
    # can_smash_token = the `@canSmash` sigil token specifically
    # (drives the @canSmash -> @service auto-fix).
    attr_accessor :open_brace_token, :prefix_token, :can_smash_token
  end

  # ThenChain: sequential chaining of steps inside a BG block fiber.
  # steps: Array of { expr: ASTNode, binding: String | nil }
  # Each step may bind its result to a name for use in subsequent steps.
  # The last step's type determines the ThenChain's full_type.
  ThenChain         = Struct.new(:token, :steps) { include Locatable }

  # BgStreamBlock: background generator — spawns a fiber that YIELDs values into a Stream.
  # body: Array of statements; YIELD expressions push values. Returns ~T[?] (open stream).
  # stack_size: :standard (default, 16 KB) | :micro (4 KB) | :large (64 KB) | :xl (256 KB)
  BgStreamBlock     = Struct.new(:token, :body, :deferred_drops, :stack_size) do
    include Locatable
    include HasBodies
    def child_bodies = [body].compact
    attr_accessor :computed_stack_tier
    attr_accessor :capture_analysis  # CaptureAnalysis with captures hash
    attr_accessor :capture_string_dupes  # Set of capture names that need heap-dupe inside the stream run fn
    attr_accessor :yields_frame_strings  # true when any YIELD expr is a frame string (NEXT caller owns the duped copy)
    # FSM Phase A: set by FsmClassifier (see effects.rb).
    attr_accessor :spawn_form
    attr_accessor :fsm_ineligible_reason
    attr_accessor :fsm_suspend_points
  end

  # YieldExpr: push a value into the enclosing BG STREAM's buffer.
  # Only valid inside a BgStreamBlock body. expr: the value to yield.
  YieldExpr         = Struct.new(:token, :expr) do
    include Locatable
    attr_accessor :yield_dupe  # true when the yielded value must be heap-duped before push (frame string)
  end

  # NextExpr: consume a Promise (~T), blocking the current fiber until the result is ready.
  # expr: the ~T expression to wait on (must be a tense type). Marks the promise as moved.
  NextExpr          = Struct.new(:token, :expr) do
    include Locatable
  end

  # MatchStatement: pattern-matching on a value.
  # cases: Array of { value: ASTNode, body: [ASTNode] }
  # default_case: [ASTNode] or nil
  # case_drops: Array of drop-arrays (parallel to cases), filled by annotator
  # default_drops: drop-array for default branch (or nil), filled by annotator
  MatchStatement    = Struct.new(:token, :expr, :cases, :default_case, :case_drops, :default_drops, :exhaustive, :takes) do
    include Locatable
    include HasBodies
    def child_bodies
      bodies = (cases || []).filter_map { |c| c[:body] }
      bodies << default_case if default_case
      bodies
    end
    attr_accessor :string_match       # set by annotator: true when expr is string type (use strEql)
    attr_accessor :expr_mode          # true when used as an expression (x = MATCH ...)
    attr_accessor :case_result_types  # Array of Types (parallel to cases), for expression-MATCH
    attr_accessor :default_result_type # Type of last value expression in default_case
  end

  # ForRange: FOR var IN (start ..= end) DO body END
  # inclusive: true = ..= (start to end), false = ..< (start to end-1)
  ForRange          = Struct.new(:token, :var_name, :start_expr, :end_expr, :inclusive, :body, :deferred_drops, :mark_per_iter) do
    include Locatable
    include HasBodies
    def child_bodies = [body].compact
    attr_accessor :tight
  end

  # ForEach: FOR var IN collection DO body END
  ForEach           = Struct.new(:token, :var_name, :collection, :body, :deferred_drops, :is_mutable) do
    include Locatable
    include HasBodies
    def child_bodies = [body].compact
    attr_accessor :mark_per_iter
    attr_accessor :tight
  end

  # ── Test Framework ───────────────────────────────────────────────

  # TEST name DO setup... WHEN... END
  TestBlock = Struct.new(:token, :name, :setup, :whens) do
    include Locatable
    include HasBodies
    def child_bodies
      bodies = []
      bodies << setup if setup
      (before_each || []).each { |b| bodies << b }
      (after_each  || []).each { |b| bodies << b }
      (before_all  || []).each { |b| bodies << b }
      (after_all   || []).each { |b| bodies << b }
      (whens || []).each do |w|
        bodies << w.setup if w.setup
        (w.tests || []).each { |t| bodies << t.body if t.body }
      end
      bodies
    end
    # Hook bodies. Each is an Array of statement Arrays (multiple
    # `BEFORE EACH DO ... END` blocks at the same level run in
    # declaration order). TestLowering composes outer (TEST-level)
    # hooks around the inner (WHEN-level) ones around each TEST THAT.
    #
    # `before_all` / `after_all` lower to dedicated Zig `test` blocks
    # that run before / after the rest of the suite (Zig executes tests
    # in declaration order). Each ALL block has its own runtime; state
    # propagation to TEST THATs requires file-scope vars and is not
    # yet supported in v1.
    attr_accessor :before_each, :after_each, :before_all, :after_all
    # LET fixtures (Array of AST::LetBinding) declared at the TEST
    # level. Lowered as auto-injected declarations at the top of every
    # TEST THAT body. Inheritable: WHEN-level LETs override by name.
    attr_accessor :lets
  end

  # WHEN "description" DO setup... TEST THAT... BENCHMARK... END
  WhenBlock = Struct.new(:token, :description, :setup, :tests, :benchmarks) do
    include Locatable
    attr_accessor :before_each, :after_each, :before_all, :after_all
    attr_accessor :lets
    # Tags declared on the WHEN via `WHEN "..." TAGS [tag1, tag2] DO ...`.
    # Array of bare-identifier strings; every TEST THAT inside this WHEN
    # inherits these tags. Lowered as `#tag` suffixes on the emitted Zig
    # test name so `clear test --tag slow` can use Zig's --test-filter.
    attr_accessor :tags
  end

  # LET <name> = <expr>;  — fixture declaration valid inside TEST or
  # WHEN bodies. Lowering injects a fresh evaluation of <expr> at the
  # top of every TEST THAT in the enclosing block, so each test sees
  # an independent value. WHEN-level LETs override TEST-level LETs of
  # the same name (the inner declaration wins).
  LetBinding = Struct.new(:token, :name, :expr) { include Locatable }

  # TEST THAT "description" DO body... END
  TestThat = Struct.new(:token, :description, :body) do
    include Locatable
    attr_accessor :synthetic_fn # AST::FunctionDef wrapper synthesized by
                                # CompilerFrontend.synthesize_test_body_wrappers!
                                # so MIRPass treats the test body the same as
                                # a regular FN body. mir_lowering reads
                                # synthetic_fn.cleanup_bindings to scope its
                                # @current_bindings while walking the body.
    attr_accessor :pending      # true when declared `PENDING TEST THAT ...`.
                                # The MIR lowering prepends
                                # `return error.SkipZigTest;` to the body so
                                # Zig's runner reports the test as skipped
                                # rather than passing or failing.
  end

  # ASSERT_RAISES Kind, expr  OR  ASSERT_RAISES Kind, ErrorName, expr
  AssertRaises = Struct.new(:token, :kind, :error_name, :expression) { include Locatable }

  # BENCHMARK expr x<N>
  BenchmarkStmt = Struct.new(:token, :expression, :iterations) { include Locatable }

  # SMASH expr
  SmashStmt = Struct.new(:token, :expression) { include Locatable }

  # PROFILE expr
  ProfileStmt = Struct.new(:token, :expression) { include Locatable }

  # STUB fn RETURNS value | STUB fn CAPTURES var | STUB fn SEQUENCE [...] | STUB fn WITH lambda
  StubDecl = Struct.new(:token, :function_name, :kind, :value) { include Locatable }
  # kind: :returns, :captures, :sequence, :with

  UNARY_OPS = ['-', '!', '~']

  PRIMITIVE_TYPES = [:Number, :Bool, :Byte, :Int64, :Float64,
                     :Int8, :Int16, :Int32,
                     :UInt8, :UInt16, :UInt32, :UInt64,
                     :Float32]

  PRECEDENCE_MAP = {
    8 => { ops: ['**'], assoc: :right },
    7 => { ops: ['*', '/', 'MOD'], assoc: :left },
    6 => { ops: ['+', '-'], assoc: :left },
    5 => { ops: ['==', '!=', '<', '>', '<=', '>='], assoc: :left },
    4 => { ops: ['&&'], assoc: :left },
    3 => { ops: ['||'], assoc: :left },
    # LEVEL 1: Both Pipe and Rescue live here.
    # They bind loosely and strictly left-to-right.
    1 => { ops: ['OR', '|>', 'AS'], assoc: :left }
  }
  MAX_PRECEDENCE = PRECEDENCE_MAP.keys.max

  OP_CODE_SENDABLE_SYMS = {
    :SUB => :-,
    :MUL => :*,
    :DIV => :/,
    :POW => :**,
    :MOD => :%,
    :EQ => :==,
    :NEQ => :!=,
    :LT => :<,
    :GT => :>,
    :LTE => :<=,
    :GTE => :>=,
    :BITWISE_NOT => :~,
  }

  # Canonical definitions are in Type class. These aliases maintain backward compat.
  NUMBER_RESULT_OPS = Type::NUMBER_RESULT_OPS
  BOOL_RESULT_OPS = Type::BOOL_RESULT_OPS

  # TODO: Make these symbols
  OP_TO_OP_CODE = {
    '+' => :ADD,
    '-' => :SUB,
    '*' => :MUL,
    '/' => :DIV,
    '**' => :POW,
    '==' => :EQ,
    '!=' => :NEQ,
    '<'  => :LT,
    '<=' => :LTE,
    '>'  => :GT,
    '>=' => :GTE,
    '!' => :NOT,
    '&&' => :AND,
    '||' => :OR,
    'MOD' => :MOD,
    'OR' => :OR_RESCUE, # TODO: Check if this is necessary
    '~' => :BITWISE_NOT,
    'AS' => :BIND_VAR,
    '%+' => :WRAP_ADD,
    '%-' => :WRAP_SUB,
    '%*' => :WRAP_MUL,
    '!+' => :CHECK_ADD,
    '!-' => :CHECK_SUB,
    '!*' => :CHECK_MUL,
  }

  CAPABILITIES = [:RESTRICT, :EXCLUSIVE, :BORROWED, :VIEW, :MATERIALIZED_VIEW, :SNAPSHOT]
end

# ==========================================
# MIR — Mid-level IR nodes
# ==========================================
# Inserted into AST statement lists by the MIR pass (future Phase 3).
# The transpiler handles these alongside AST nodes via `when MIR::Drop`, etc.
# Each node carries pre-computed decisions so the transpiler is purely mechanical.
module MIR
  # Drop: cleanup instruction inserted after variable declarations or before
  # field overwrites. Emits Zig `defer` cleanup code (or inline cleanup for
  # field pre-cleanup). Replaces CleanupClassifier lookups in transpiler.
  #
  # kind:              cleanup template symbol (matches emit_cleanup_from_entry cases):
  #                    :resource, :list, :list_with_elem_cleanup, :string_map, :numeric_map,
  #                    :pool, :set, :rc, :locked, :write_locked, :heap_string, :heap_slice,
  #                    :heap_union, :heap_struct, :heap_struct_plain, :struct_with_cleanup_fields,
  #                    :struct_rc, :array_with_struct_strings, :non_copy_union, :takes_union,
  #                    :takes_string, :takes_slice
  # alloc:             :heap or :frame — which allocator owns this value
  # has_moved_guard:   boolean — emit `var x_moved = false; defer if (!x_moved) ...`
  # resource_close_zig: string template for :resource kind (e.g. "{0}.deinit()")
  Drop = Struct.new(:token, :name, :kind, :alloc, :has_moved_guard, :type_info,
                     :resource_close_zig, :source_node) do
    include AST::Locatable
    attr_accessor :cleanup_entry  # full classifier hash with pre-computed RC fields
    def needs_cleanup; true; end
  end

  # Promote: escape promotion inserted before return statements.
  # Emits frame->heap copy/promotion code. Replaces PromotionClassifier lookups in transpiler.
  #
  # strategy:  :list     — promoteList (dupe backing buffer to heap; elem_type required)
  #            :string_map — swap allocator to heapAlloc
  #            :fields   — promoteFields (recursive field promotion)
  #            :generic  — promote (single value deep copy)
  Promote = Struct.new(:token, :name, :zig_type, :strategy, :fields, :elem_type) do
    include AST::Locatable
    # fields: Set of field names for :fields strategy (nil = all fields)
    # elem_type: Zig element type for :list promotion.
  end

  # SuppressCleanup: move suppression marker inserted at consumption points
  # (TAKES calls, GIVE, return escapes). Emits `x_moved = true;` to prevent
  # double-free via the defer guard emitted by Drop.
  SuppressCleanup = Struct.new(:token, :name) do
    include AST::Locatable
  end

  # Alloc: marks an allocation point - a variable binding that owns a resource
  # and will need cleanup. Inserted alongside MIR::Drop for each VarDecl/BindExpr
  # with cleanup. The StaticLeakChecker verifies every Alloc has exactly one
  # Drop or Move/Escape on every path through the function.
  #
  # kind:  cleanup template symbol (same as Drop - :list, :string_map, etc.)
  # alloc: :heap or :frame - which allocator owns this value
  Alloc = Struct.new(:token, :name, :kind, :alloc) do
    include AST::Locatable
  end

  # Return: marks function exit where local variable ownership transfers to
  # the caller. Inserted before ReturnNode. The checker uses this to know
  # that escaped variables don't need local cleanup (caller takes ownership).
  #
  # escaped_vars: [String] variable names whose ownership escapes via return
  Return = Struct.new(:token, :escaped_vars) do
    include AST::Locatable
  end

  # ReassignCleanup: verification marker for mutable variable reassignment.
  # Inserted after BindExpr :assign nodes where the old value needs cleanup
  # before overwrite. The checker verifies these exist for all reassignment
  # sites on cleanup-needing bindings.
  ReassignCleanup = Struct.new(:token, :name, :alloc) do
    include AST::Locatable
  end

  # FieldCleanup: verification marker for field overwrite pre-cleanup.
  # Inserted after Assignment nodes where a GetField target holds a
  # cleanup-needing value that must be freed before overwrite.
  FieldCleanup = Struct.new(:token, :target_name, :field, :alloc) do
    include AST::Locatable
  end
end
