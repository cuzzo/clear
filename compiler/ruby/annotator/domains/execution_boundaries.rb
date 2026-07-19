# typed: true
# frozen_string_literal: true

require_relative "../../semantic/capability_plan"

module Annotator
  module Domains
    module ExecutionBoundaries
      extend T::Sig

      sig { params(node: AST::WithBlock).returns(T.nilable(Symbol)) }
      def visit_WithBlock(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        fn_ctx = current_fn_ctx
        if fn_ctx
          fn_node = function_node_for(fn_ctx.name)
          fn_node.semantic_with_blocks << node if fn_node
        end
        phase_traversal_state.with_block_depth += 1
        begin
        capability_expansion = CapabilityHelper::WithCapabilityExpansion.new
        node.capabilities.each do |cap|
          acquire_capability!(node, cap, capability_expansion)
        end
        node.capability_plan = capability_expansion
        capability_plan = CapabilityPlan.require_for(node)
        expanded_capabilities = capability_plan.all
        lock_capabilities = capability_plan.locks
        validate_with_match_source_shape!(node, capability_expansion)

        check_nested_lock_reacquire!(node, lock_capabilities)

        # Run local rank checks before edge accumulation so ranked violations
        # produce direct diagnostics instead of later SCC errors.
        check_lock_rank_ordering!(node, lock_capabilities)

        # WITH MATCH records blocking effects per arm, but lock-cycle edges stay
        # conservative at the outer level because any LOCKED-eligible call may
        # acquire a lock.
        fn_name_for_lock = current_fn_ctx&.name || "<top>"
        held_entries_now = current_held_lock_types
        is_match_form = !node.arms.nil?
        lock_capabilities.each do |cap|
          record_with_acquire!(fn_name_for_lock, cap, held_entries_now, node.deadlock_escape)
          unless is_match_form
            # Exclusive lock acquisition may suspend the fiber on contention.
            record_effect(EffectTracker::BLOCKING)
            record_effect(EffectTracker::SUSPENDS)
          end
        end

        # The child scope inherits parent variables for reads, but declarations
        # inside the WITH remain isolated. SNAPSHOT transaction bodies also need
        # effect tracking so retryable bodies cannot suspend after mutation starts.
        is_snapshot_txn_body = (node.snapshot_mode == :transaction)
        with_body = proc do
          record_body_fact_with_block!(node)
          with_new_scope(current_scope) do
            expanded_capabilities.each { |cap| declare_capability_scope!(cap) }
            validate_and_visit_with_guards!(node)
            with_body_fact_scope(node) do
              visit_stmts(node.body)
            end
            validate_with_guard_no_body_mutation!(node)
            fallible_sources = retryable_with_fallible_sources(node)
            if is_snapshot_txn_body && !fallible_sources.empty?
              retryable_with_fallible_body_error!(
                node,
                "WITH SNAPSHOT ... AS MUTABLE",
                fallible_sources
              )
            end
            if retryable_with_universal_poly_candidate?(node) && !fallible_sources.empty?
              retryable_with_fallible_body_error!(
                node,
                "WITH POLYMORPHIC",
                fallible_sources
              )
            end
            arms = node.arms
            if arms
              # Record family-specific prelude effects before each arm body so
              # the per-arm delta includes synthetic acquire/snapshot work.
              fn_ctx_name = current_fn_ctx&.name
              direct_effects = effect_direct_effects
              snapshot = fn_ctx_name ? effect_direct_effects_for(fn_ctx_name).dup : nil
              per_arm_effects = []
              arms.each do |arm|
                before = fn_ctx_name ? effect_direct_effects_for(fn_ctx_name).dup : nil
                # Family-specific prelude effects that the lowering will emit
                # for this arm. LOCKED acquires a mutex (BLOCKING + CONTENTION
                # + SUSPENDS); VERSIONED takes a snapshot via EBR pin
                # (CONTENTION); ATOMIC binds the alias to the cell ref so any
                # subsequent body access contends on the cache line (CONTENTION,
                # no BLOCKING — atomics never park).
                with_match_family_effects(arm.family).each { |effect| record_effect(effect) }
                with_new_scope(current_scope) do
                  with_body_fact_scope(node) do
                    visit_stmts(arm.body)
                  end
                  finalize_scope(node)
                end
                if fn_ctx_name
                  after = effect_direct_effects_for(fn_ctx_name)
                  arm_delta = after - T.must(before)
                  per_arm_effects << arm_delta
                  # Roll back the fn's direct effects so the next arm sees a
                  # clean baseline. We re-stamp the consensus and ?-form below.
                  direct_effects[fn_ctx_name] = T.must(snapshot).dup
                end
              end
              if fn_ctx_name && !per_arm_effects.empty?
                # Concrete: effects present in EVERY arm (intersection).
                concrete = per_arm_effects.reduce(:&) || Set.new
                # Maybe: effects present in SOME arm but not all (symmetric diff
                # ∪ across arms minus intersection). Project to ?-form variants
                # for the contention/blocking axis.
                all_union = per_arm_effects.reduce(Set.new, :|)
                maybe_set = all_union - concrete
                maybe_projection = {
                  EffectTracker::CONTENTION => EffectTracker::CONTENTION_MAYBE,
                  EffectTracker::BLOCKING => EffectTracker::BLOCKING_MAYBE,
                }
                target_effects = effect_direct_effects_for(fn_ctx_name)
                concrete.each { |eff| target_effects.add(eff) }
                maybe_set.each { |eff| target_effects.add(maybe_projection.fetch(eff, eff)) }
              end
            end
            finalize_scope(node)
          end
        end
        with_held_locks(node, lock_capabilities) do
          is_snapshot_txn_body ? with_snapshot_transaction_body(node, &with_body) : with_body.call
        end

        # Release borrows after the WITH block exits
        expanded_capabilities.each do |cap|
          vname = cap.var_name
          if cap.restrict?
            ownership_graph.release_borrow("__restrict_#{vname}")
          elsif cap.borrowed?
            ownership_graph.release_borrow("__borrowed_#{vname}")
          end
        end

        validate_no_multi_object_atomic!(node)
        validate_lock_error_clause!(node, lock_capabilities)
        # MVCC: SNAPSHOT-transaction bodies lower to
        # `Versioned.update[Multi](rt, alloc, ...)` (heap-allocates a new
        # version + retires the old via EBR), and a WITH MATCH with a
        # VERSIONED arm lowers to `Versioned.read(rt)` (lock-free, no
        # alloc, but rt is needed for the EBR pin). Both flavors require
        # `rt: *Runtime` threaded through the enclosing fn's signature.
        # Set `needs_rt` directly so compute_needs_rt! picks it up;
        # heap_count is reserved for actual heap allocations (T1 cleanup --
        # earlier code abused heap_count as a needs_rt sentinel).
        mark_with_runtime_requirements!(node)
        # Queue this WITH for the post-pass handler-reachability check. Running
        # it here (during annotation) is too early — cycle information isn't
        # known until compute_lock_cycles! has propagated through function_call_graph.
        record_lock_clause_site!(node, lock_capabilities)

        stamp_type!(node, :Void)
        ensure
          phase_traversal_state.with_block_depth -= 1
        end
      end

      # Reject WITH MATCH shapes that would silently miscompile.
      #
      # `WITH c AS MUTABLE va MATCH ... WHEN VERSIONED -> { va.field = X }`
      # writes through a read snapshot instead of committing the mutation. The
      # plan is already built here, so the check consumes typed capability facts
      # instead of maintaining a second raw AST request path.
      sig { params(node: AST::WithBlock, capability_plan: CapabilityPlan::WithCapabilityPlan).void }
      def validate_with_match_source_shape!(node, capability_plan)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        arms = node.arms
        return unless arms && node.snapshot_mode.nil?

        mutable_cap = capability_plan.all.find(&:alias_mutable)
        if mutable_cap && arms.any? { |arm| arm.family == :VERSIONED }
          error!(node, :WITH_MATCH_VERSIONED_AS_MUTABLE, name: mutable_cap.var_name)
        end

        return unless capability_plan.all.length > 1

        names = capability_plan.all.map(&:var_name).join(", ")
        error!(node, :WITH_MATCH_MULTI_CELL, names: names)
      end

      sig { params(node: AST::WithBlock).void }
      def mark_with_runtime_requirements!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        fn_ctx = current_fn_ctx
        return unless fn_ctx

        # MVCC: any WITH SNAPSHOT lowers to `Versioned.read(rt)` (read mode)
        # or `Versioned.update[Multi](rt, ...)` (transaction mode). Both
        # need rt threaded through the enclosing fn. Plus a WITH MATCH with
        # a VERSIONED arm uses Versioned.read(rt) inside the arm's prelude.
        fn_ctx.uses_rt = true if with_block_uses_runtime?(node)

        # Universal-polymorphic mutation can route through Versioned/AtomicPtr
        # update helpers, so mark rt/fail here before compute_needs_rt! runs.
        mark_unrequired_polymorphic_with_runtime!(node, fn_ctx)
      end

      sig { params(node: AST::WithBlock).returns(T::Boolean) }
      def with_block_uses_runtime?(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        node.snapshot_mode == :read ||
          node.snapshot_mode == :transaction ||
          with_block_has_versioned_arm?(node)
      end
      private :with_block_uses_runtime?

      sig { params(node: AST::WithBlock).returns(T::Boolean) }
      def with_block_has_versioned_arm?(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        !!node.arms&.any? { |arm| arm.family == :VERSIONED }
      end

      sig { params(node: AST::WithBlock, fn_ctx: FunctionContext).void }
      def mark_unrequired_polymorphic_with_runtime!(node, fn_ctx)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        bound_name = unrequired_polymorphic_runtime_bound_name(node)
        return unless bound_name

        fn_node = function_node_for(fn_ctx.name)
        return unless fn_node && !with_requires_binding?(fn_node, bound_name)

        fn_ctx.uses_rt = true
        fn_node.can_fail = true if fn_node.respond_to?(:can_fail=)
      end
      private :mark_unrequired_polymorphic_with_runtime!

      sig { params(node: AST::WithBlock).returns(T.nilable(String)) }
      def unrequired_polymorphic_runtime_bound_name(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        capability_plan = CapabilityPlan.require_for(node)
        return nil unless node.polymorphic && capability_plan.all.length == 1

        bound_fact = capability_plan.first_transition
        bound_var = bound_fact.var_node
        bound_sym = bound_var.respond_to?(:symbol) ? bound_var.symbol : nil
        return nil unless bound_sym && bound_sym.respond_to?(:is_param) && bound_sym.is_param

        bound_fact.var_name
      end
      private :unrequired_polymorphic_runtime_bound_name

      sig { params(fn_node: AST::FunctionDef, bound_name: T.nilable(String)).returns(T::Boolean) }
      def with_requires_binding?(fn_node, bound_name)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        !!(fn_node.respond_to?(:requires) && fn_node.requires && fn_node.requires.key?(bound_name))
      end

      # Validate WithBlock#lock_error_clause. Requires at least one fallible
      # capability, each selector to resolve against the error registry, RETRY
      # to target only Transient-kind errors, and the selector set to overlap
      # the block's possible error set. Visits action message/body so types
      # are annotated. Action runs outside the WITH scope — the lock was never
      # acquired on the error path — so it is visited in the enclosing scope.
      #
      # Possible error set for WITH EXCLUSIVE / write_locked_read:
      #   {:LockTimeout, :LockCycle, :Deadlock}
      # Symbols matched by the clause are stamped onto clause.matched_types;
      # unmatched types bubble up as their registry kind at codegen time.
      LOCK_POSSIBLE_TYPES = %i[LockTimeout LockCycle Deadlock].freeze
      # SNAPSHOT MUTABLE commit errors depend on the cell family.
      # @versioned -> MvccConflict (Versioned.update bounded retry).
      # @boxed:atomic -> AtomicConflict after bounded AtomicPtr retries.
      # The dispatch picks per cell at
      # validate_lock_error_clause! time; SNAPSHOT_POSSIBLE_TYPES is the
      # union over both for the resolve_error_selectors! reachability
      # check.
      SNAPSHOT_POSSIBLE_TYPES = %i[MvccConflict AtomicConflict].freeze

      sig { params(node: AST::WithBlock).returns(T::Array[String]) }
      def retryable_with_fallible_sources(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        sources = T.let([], T::Array[String])
        current_body_fact_scope_nodes(node).each do |source_node|
          case source_node
          when AST::Raise
            sources << "RAISE"
          when AST::OrElseRaise
            sources << "OR_ELSE RAISE"
          when AST::FuncCall
            sources << source_node.name.to_s if retryable_with_call_fallible?(source_node)
          when AST::MethodCall
            sources << "#{source_node.name}()" if retryable_with_call_fallible?(source_node)
          when AST::StaticCall
            sources << source_node.method_name.to_s if retryable_with_call_fallible?(source_node)
          when AST::FreezeNode
            sources << "FREEZE"
          end
        end
        sources.uniq
      end

      sig { params(node: T.any(AST::FuncCall, AST::MethodCall, AST::StaticCall)).returns(T::Boolean) }
      def retryable_with_call_fallible?(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return true if node.respond_to?(:can_fail) && node.can_fail
        return true if node.respond_to?(:error_union_type) && T.unsafe(node).error_union_type
        false
      end

      sig { params(node: AST::WithBlock).returns(T.nilable(T::Boolean)) }
      def retryable_with_universal_poly_candidate?(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return true if node.universal_poly
        capability_plan = CapabilityPlan.require_for(node)
        return false unless node.polymorphic && capability_plan.all.length == 1

        bound_fact = capability_plan.first_transition
        bound_var = bound_fact.var_node
        bound_name = bound_fact.var_name
        bound_sym = bound_var.respond_to?(:symbol) ? bound_var.symbol : nil
        is_param = bound_sym && bound_sym.respond_to?(:is_param) && bound_sym.is_param
        fn_node = function_node_for(current_fn_ctx&.name)
        has_req = fn_node && fn_node.respond_to?(:requires) && fn_node.requires &&
                  fn_node.requires.key?(bound_name)
        is_param && !has_req
      end

      sig { params(node: AST::WithBlock, with_name: String, sources: T::Array[String]).void }
      def retryable_with_fallible_body_error!(node, with_name, sources)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        detail = sources.first(3).join(", ")
        detail += ", ..." if sources.length > 3
        error!(node, :WITH_RETRYABLE_FALLIBLE_BODY, with_name: with_name, detail: detail)
      end

      sig { params(node: AST::WithBlock, lock_capabilities: CapabilityHelper::WithCapabilityFacts).void }
      def validate_lock_error_clause!(node, lock_capabilities)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        clause = node.lock_error_clause
        is_snapshot_txn = node.snapshot_mode == :transaction

        # SNAPSHOT MATCH MUTABLE arms own their conflict handlers, so validate
        # them before the single-arm checks below.
        if node.arms && is_snapshot_txn
          validate_snapshot_match_arms!(node)
          return
        end

        # AtomicPtr and Versioned cells have different conflict surfaces, so
        # choose the handler contract from the participating cell family.
        capability_plan = CapabilityPlan.require_for(node)
        has_atomic_ptr = is_snapshot_txn && capability_plan.snapshot_transitions.any? { |cap|
          sym = cap.source_entry
          sym && sym.atomic? && sym.indirect?
        }

        # Missing per-WITH conflict handlers fall back to SYNC POLICY. Stamp the
        # synthesized clause onto the node so lowering uses the same catch path.
        if is_snapshot_txn && clause.nil?
          target_error = has_atomic_ptr ? :AtomicConflict : :MvccConflict
          synth = synthesize_clause_from_policy(target_error)
          if synth
            node.lock_error_clause = synth
            clause = synth
          else
            error!(node, :WITH_SNAPSHOT_NEEDS_HANDLER, error: target_error)
          end
        end

        # AtomicPtr commits can raise AtomicConflict, not MvccConflict.
        if has_atomic_ptr && clause
          bad_selector = clause.selectors.find { |s| s.form == :type && s.name == :MvccConflict }
          if bad_selector
            error!(node, :WITH_ATOMIC_HANDLER_WRONG_ERROR)
          end
        end

        return unless clause

        # SNAPSHOT-read should not carry a Conflict handler -- pure reads
        # cannot fail. Accept silently for now (parser already restricts the
        # syntax shape); a future polish pass could note the dead clause.

        has_guard = !capability_plan.guarded.empty?
        has_fallible = has_guard || is_snapshot_txn || !lock_capabilities.empty?
        unless has_fallible
          error!(node, :ON_RETRY_NEEDS_FALLIBLE_CAP)
        end

        resolve_error_selectors!(node, clause, is_snapshot_txn)

        case clause.action
        when AST::ErrorActionKind::Exit
          visit(T.must(clause.message))
        when AST::ErrorActionKind::Return
          visit(T.must(clause.value))
        when AST::ErrorActionKind::Block
          visit_stmts(clause.body)
        end
      end

      # Reject `cfg.field = ...` when `cfg` is `@boxed:atomic`. The cell
      # publishes whole-T snapshots via atomic pointer swap, not per-field writes.
      # Only the WITH SNAPSHOT MUTABLE alias (a regular *T pointer
      # passed to AtomicPtr.update's closure) accepts field assignments.
      #
      # The alias's SymbolEntry is declared with sync=nil and
      # layout=nil (capabilities.rb's SNAPSHOT branch passes neither
      # to scope.declare), so this check fires only on the original
      # cell binding -- the alias path falls through.
      #
      # Walks the target's chain to find the root Identifier. For
      # GetField / GetIndex chains rooted at an @boxed:atomic
      # binding, fires the rejection. Other chain shapes (param
      # passing, etc.) are handled elsewhere.

      sig { params(field_node: AST::GetField, assignment_node: AST::Assignment).void }
      def reject_bare_atomic_ptr_mutation!(field_node, assignment_node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        root = T.let(field_node, AST::GetField)
        root = root.target while root.respond_to?(:target) && !root.is_a?(AST::Identifier)
        return unless root.is_a?(AST::Identifier)
        sym = root.symbol
        return unless sym
        return unless sym.atomic?
        return unless sym.respond_to?(:layout) && sym.indirect?

        error!(assignment_node, :INDIRECT_ATOMIC_FIELD_WRITE,
          name: root.name, field: field_name_for_msg(field_node))
      end

      # Pull the leaf field name out of a GetField chain for the error
      # message ("for mutation" snippet). Returns "<field>" or "field".

      sig { params(node: AST::GetField).returns(String) }
      def field_name_for_msg(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return node.field.to_s if node.respond_to?(:field) && node.field
        "<field>"
      end

      # Reject multi-binding WITH when any sync-constrained cell could be atomic:
      # CLEAR has no portable multi-pointer atomic primitive, so the operation
      # would not be atomic across cells.
      #
      # Covers all multi-binding WITH forms (plain, POLYMORPHIC, SNAPSHOT,
      # SNAPSHOT MATCH). Sync-only: BORROWED / RESTRICT / VIEW /
      # MATERIALIZED VIEW capabilities don't count toward the multi-binding
      # threshold (they don't synchronize).
      #
      # Atomic is admitted when:
      #   - a binding has concrete sync `:atomic` (primitive or boxed:atomic).
      #   - a polymorphic param's REQUIRES disjunction includes `:ATOMIC`
      #     literally, or `:SNAPSHOTTED` (which expands to {VERSIONED, ATOMIC}).
      # The fix: narrow REQUIRES to a non-ATOMIC family
      # (e.g. `LOCKED | VERSIONED`), or refactor to single-cell WITHs.

      sig { params(node: AST::WithBlock).void }
      def validate_no_multi_object_atomic!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        capability_plan = CapabilityPlan.require_for(node)
        caps = capability_plan.sync_constrained
        return if caps.size < 2

        arm_admits_atomic = (node.arms || []).any? { |arm| arm.family == :ATOMIC }
        offender = caps.find { |c| cap_admits_atomic?(c) }
        return unless offender || arm_admits_atomic

        var_name = if offender
          offender.var_name
        else
          "this WITH"
        end

        error!(node, :WITH_MULTI_OBJECT_ATOMIC, name: var_name)
      end

      # Does this capability's binding potentially run as `:atomic` at runtime?
      #   - concrete sync `:atomic` (covers primitive @atomic and
      #     boxed:atomic via sym.indirect?, both flagged
      #     by sym.atomic?);
      #   - polymorphic REQUIRES disjunction admitting :ATOMIC or
      #     :SNAPSHOTTED (which expands to {VERSIONED, ATOMIC}).

      sig { params(cap: CapabilityPlan::CapabilityTransition).returns(T::Boolean) }
      def cap_admits_atomic?(cap)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        sym = cap.source_entry
        return false unless sym
        return true if sym.atomic?
        fams = sym.sync_families
        return false unless fams.is_a?(Set)
        expanded = WithMatchCheck.expand_snapshotted(fams)
        expanded.include?(:ATOMIC)
      end

      # Per-arm conflict-handler validation for SNAPSHOT MATCH MUTABLE blocks.
      # The two families have different contracts:
      #   - VERSIONED arm: REQUIRES at least one `ON MvccConflict` clause
      #     (mirrors the single-arm M5 contract; Versioned.update bounds
      #     retries and surfaces UpdateRetriesExhausted -> MvccConflict).
      #   - ATOMIC arm: FORBIDS conflict handlers (today rcu retries
      #     until success; when bounded, the right handler is
      #     `ON AtomicConflict`, not `ON MvccConflict`.
      # Read-mode SNAPSHOT MATCH (no MUTABLE) skips this entirely --
      # read paths can't fail, so neither arm needs / accepts a handler.

      sig { params(node: AST::WithBlock).void }
      def validate_snapshot_match_arms!(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        (node.arms || []).each do |arm|
          clauses = arm.lock_error_clauses
          case arm.family
          when :VERSIONED
            # VERSIONED arms without an inline handler fall back to SYNC POLICY.
            if clauses.empty?
              synth = synthesize_clause_from_policy(:MvccConflict)
              if synth
                arm.lock_error_clauses = [synth]
              else
                error!(node, :WITH_SNAPSHOT_MATCH_VERSIONED_NEEDS_HANDLER)
              end
            end
          when :ATOMIC
            unless clauses.empty?
              error!(node, :WITH_SNAPSHOT_MATCH_ATOMIC_FORBIDS_HANDLER)
            end
          end
        end
        # Visit per-arm ON MvccConflict action bodies so types are
        # annotated. Mirrors the single-arm pass at the bottom of
        # validate_lock_error_clause!.
        (node.arms || []).each do |arm|
          arm.lock_error_clauses.each do |clause|
            case clause.action
            when AST::ErrorActionKind::Exit
              visit(T.must(clause.message))
            when AST::ErrorActionKind::Block
              visit_stmts(clause.body)
            end
          end
        end
      end

      # Expand each selector to its matched error-type symbols against the
      # error registry + the block's possible error set. Enforces:
      #   1. Every :kind selector names one of the 6 ErrorKinds.
      #   2. Every :type selector names a known error type (AST::ERROR_TYPES).
      #   3. Retry selectors resolve to Transient types only.
      #   4. The matched set intersects the block's possible error set.

      sig { params(node: AST::WithBlock, clause: AST::ErrorClause, is_snapshot_txn: T::Boolean).void }
      def resolve_error_selectors!(node, clause, is_snapshot_txn = false)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        possible = Set.new
        possible.merge(SNAPSHOT_POSSIBLE_TYPES) if is_snapshot_txn
        capability_plan = CapabilityPlan.require_for(node)
        if capability_plan.locks.any?
          possible.merge(LOCK_POSSIBLE_TYPES)
        end
        possible << :GuardFail unless capability_plan.guarded.empty?
        possible = possible.to_a
        matched  = []

        clause.selectors.each do |sel|
          form = sel.form
          name = sel.name
          token = sel.token
          diagnostic_token = token || node.token
          case form
          when :kind
            unless AST.error_kind?(name)
              emit_registry_mismatch!(
                diagnostic_token, name, AST::ERROR_KINDS,
                "Unknown error kind '#{name}'. Expected one of: #{AST::ERROR_KINDS.join(', ')}",
                "closest known kind"
              )
            end
            matched.concat(AST.types_for_kind(name)) if AST.error_kind?(name)
          when :type
            unless AST.error_type?(name)
              emit_registry_mismatch!(
                diagnostic_token, name, AST::ERROR_TYPES.keys,
                "Unknown error type '#{name}'. Register it in src/ast/error_registry.rb.",
                "closest registered type"
              )
            end
            matched << name if AST.error_type?(name)
          end
        end

        matched.uniq!

        if clause.retries
          non_transient = matched.reject { |t| AST.kind_of_type(t) == :Transient }
          unless non_transient.empty?
            error!(clause.token || node, :RETRY_ONLY_TRANSIENT, types: non_transient.join(', '))
          end
        end

        overlap = matched & possible
        if overlap.empty?
          error!(node, :SELECTORS_NO_MATCH, matched: matched.join(', '), possible: "any error the WITH acquire can produce (#{possible.join(', ')}).")
        end

        clause.matched_types = overlap
        clause.bubble_types = possible - overlap
      end

      # Walk statements looking for assignments where a borrowed alias escapes
      # to an outer-scope variable.

      sig { params(node: AST::DoBlock).returns(T.nilable(Symbol)) }
      def visit_DoBlock(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        node.branches.each do |branch|
          full_analysis = T.let(nil, T.nilable(CapabilityHelper::CaptureAnalysis))
          with_async_body_fact_frame(branch, node) do
            full_analysis = with_fiber_capture_analysis(is_parallel: branch.parallel) do
              visit_stmts(branch.body)
            end
          end
          analysis_result = T.must(full_analysis)
          branch.capture_analysis = analysis_result

          if branch.parallel
            error!(node, :LOCAL_VAR_NOT_IN_PARALLEL) if analysis_result.has_local
            error!(node, :MULTIOWNED_NOT_IN_PARALLEL) if analysis_result.has_rc
          end

          if analysis_result.has_non_escaping_capture
            error!(node, :DO_CAPTURES_WITH_SCOPED)
          end

          analysis = (!branch.pinned && !branch.parallel && analysis_result.has_shared) ? analysis_result : nil

          if analysis && !branch.pinned
            branch.pinned = true
            note!(node, "DO branch auto-pinned — captures shared/locked resource. Use @parallel to distribute.")
          end
        end
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::BgStreamBlock).void }
      def visit_BgStreamBlock(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        # Effect tracking: generators are inherently unbounded (run until exhausted or cancelled).
        record_effect(EffectTracker::LOOP_UNBOUND)

        stream_analysis = T.let(nil, T.nilable(CapabilityHelper::CaptureAnalysis))
        yield_types = with_stream_yield_frame(node) do
          with_async_body_fact_frame(node, node) do
            stream_analysis = with_fiber_capture_analysis do
              visit_stmts(node.body)
            end
          end
        end
        stream_analysis_result = T.must(stream_analysis)

        if yield_types.empty?
          error!(node, :BG_STREAM_NO_YIELD)
        end

        inferred_join = Type.join_async_results(yield_types)
        if node.declared_yield_type.nil? && !inferred_join.success?
          surfaces = yield_types.map { |type| Type.surface_name(type) }.uniq
          error!(node, :BG_STREAM_INCONSISTENT_YIELD,
            types: surfaces.join(', '), union_shape: "Union<#{surfaces.join(', ')}>")
        elsif node.declared_yield_type.nil? && inferred_join.type &&
              stream_yields_contract_required?(T.must(inferred_join.type))
          emit_missing_stream_yields_contract!(node, T.must(inferred_join.type))
        end

        element_type = node.declared_yield_type || inferred_join.type || Type.new(:Any)
        stamp_type!(node, Type.new(StreamTypeExpression.new(
          cardinality: :FINITE,
          item: element_type.shape.expression,
        )))

        node.capture_analysis = stream_analysis_result

        if stream_analysis_result.has_non_escaping_capture
          error!(node, :BG_STREAM_CAPTURES_WITH_SCOPED)
        end
      end

      sig { params(node: AST::YieldExpr).void }
      def visit_YieldExpr(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        frame = current_stream_yield_frame
        unless frame
          error!(node, :YIELD_OUTSIDE_BG_STREAM)
          return
        end
        error!(node, :YIELD_AFTER_CLOSE) if frame.closed
        visit(node.expr)
        stamp_type!(node, node.expr.full_type!(context: "yield expression"))
        yielded_type = Type.new(node.full_type!(context: "yield result"))
        expected_type = frame.expected_type
        if expected_type && !expected_type.accepts?(yielded_type)
          error!(node, :BG_STREAM_INCONSISTENT_YIELD,
            types: "#{Type.surface_name(expected_type)}, #{Type.surface_name(yielded_type)}",
            union_shape: "Union<#{Type.surface_name(expected_type)}, #{Type.surface_name(yielded_type)}>")
        end
        frame.yield_types << yielded_type
        record_effect(EffectTracker::SUSPENDS)
      end

      sig { params(type: Type).returns(T::Boolean) }
      def stream_yields_contract_required?(type)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        return true if type.future?

        lookup_type_schema(type.resolved).is_a?(Schemas::UnionSchema)
      end

      sig { params(node: AST::BgStreamBlock, contract: Type).void }
      def emit_missing_stream_yields_contract!(node, contract)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)
        contract_name = Type.surface_name(contract)
        source = source_code
        token = node.token
        fix = T.let(nil, T.nilable(Fix))
        if source && token
          line = source.lines[token.line - 1]
          start = token.column - 1
          stream_at = line&.index(/\bSTREAM\b/, start)
          if stream_at
            insert_col = stream_at + "STREAM".length + 1
            fix = Fix.new(
              description: fix_description(:ADD_STREAM_YIELDS_CONTRACT, type: contract_name),
              confidence: :auto,
              edits: [Edit.new(
                span: Span.new(file: nil, line: token.line, col: insert_col, length: 0),
                replacement: " YIELDS #{contract_name}",
              )],
            )
          end
        end

        return error!(node, :BG_STREAM_YIELDS_REQUIRED, type: contract_name) unless fix

        fixable!(node,
          code: :BG_STREAM_YIELDS_REQUIRED,
          type: contract_name,
          category: :type,
          level: :error,
          fixes: [fix])
      end

      sig { params(node: AST::CloseStream).void }
      def visit_CloseStream(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        frame = current_stream_yield_frame
        unless frame
          error!(node, :CLOSE_OUTSIDE_BG_STREAM)
        end
        error!(node, :STREAM_ALREADY_CLOSED) if frame.closed
        frame.closed = true
        stamp_type!(node, :Void)
        phase_traversal_state.branch_terminated = true
      end

      sig { params(node: AST::BgBlock).returns(T.nilable(T::Boolean)) }
      def visit_BgBlock(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        # Body runs in a separate fiber. The last expression's type determines T in ~T.
        # node.stack_size: :standard | :micro | :large | :xl | nil  (nil → STANDARD default)
        record_effect(EffectTracker::YIELD)
        prev_bg_pinned = phase_traversal_state.current_bg_pinned
        phase_traversal_state.current_bg_pinned = !!node.pinned
        begin

        last_type = T.let(Type.new(:Void), Type)
        full_analysis = T.let(nil, T.nilable(CapabilityHelper::CaptureAnalysis))
        with_async_body_fact_frame(node, node) do
          full_analysis = with_fiber_capture_analysis(is_parallel: node.parallel, mark_moves: true) do
            node.body.each do |expr|
              visit(expr)
              last_type = T.cast(expr, AST::Locatable).full_type!(context: "BG body expression")
            end
          end
        end
        analysis_result = T.must(full_analysis)
        # Strip leading `!` from the body's last-expression type: a BG fiber
        # catches its body's errors internally and surfaces them via the
        # Promise's join boundary, not via the surface success type. So
        # `BG { napFor(50); }` (where napFor is `!Void`) is `~Void`, not
        # `~!Void` -- the latter would force callers to write `~!Void[]@list`
        # and break the Zig codegen, which expects `Promise(T)` where `T`
        # is the success type.
        # A contextual `~!T` contract is different: `!T` is deliberately the
        # Promise payload and must survive the join boundary.  Mark the final
        # call so lowering stores the error union as a value instead of applying
        # the usual implicit `try` used for fiber transport failures.
        declared_payload = T.cast(T.unsafe(node).declared_async_payload, T.nilable(Type))
        preserve_payload_error = declared_payload&.error_union? == true
        last_type_str = last_type.to_s
        if last_type_str.start_with?('!') && !preserve_payload_error
          last_type = Type.new(T.must(last_type_str[1..]).to_sym)
        end
        if preserve_payload_error && node.body.last&.respond_to?(:retain_error_channel=)
          T.unsafe(node.body.last).retain_error_channel = true
          last_type = T.must(declared_payload)
        end
        payload_type = owned_async_payload_type(last_type)
        T.unsafe(node).async_result_shape = AsyncResultShape.promise(payload_type)
        stamp_type!(node, Type.new(:"~#{payload_type}"))

        # @arena implies @pinned — thread-local arena memory can't be stolen.
        if node.arena_mode
          node.pinned = true
          if node.parallel
            error!(node, :BG_ARENA_AND_PARALLEL)
          end
        end

        node.capture_analysis = analysis_result

        # Validate: @local in @parallel, @rc in @parallel
        if node.parallel
          error!(node, :LOCAL_VAR_NOT_IN_PARALLEL) if analysis_result.has_local
          error!(node, :MULTIOWNED_NOT_IN_PARALLEL) if analysis_result.has_rc
        end

        # WITH-scoped (BORROWED/RESTRICT) bindings cannot escape into fibers.
        # The fiber may outlive the WITH block, turning the alias into a dangling pointer.
        if analysis_result.has_non_escaping_capture
          error!(node, :BG_CAPTURES_WITH_SCOPED)
        end

        # Auto-pin detection
        analysis = (!node.pinned && !node.parallel && analysis_result.has_shared) ? analysis_result : nil

        # Safety: pinned scope → child BG must also be pinned if it captures outer vars.
        if prev_bg_pinned && !node.pinned && analysis_result.has_outer_ref
          error!(node, :BG_PINNED_CAPTURE_MISMATCH)
        end

        # Auto-pin when shared state is captured.
        if analysis && !node.pinned
          if analysis.has_local
            node.pinned = :local
            note!(node, "BG block auto-pinned — captures @local resource (same-scheduler affinity).")
          elsif analysis.has_affine_locked
            node.pinned = :shared
            note!(node, "BG block auto-pinned — captures @locked resource (round-robin scheduler affinity).")
          else
            node.pinned = :local
            if analysis.has_sharded
              note!(node, "BG block auto-pinned — captures @sharded map (scheduler affinity for shard locality).")
            else
              note!(node, "BG block auto-pinned — captures shared/locked resource. Use @parallel to override.")
            end
          end
        end
        true
        ensure
          phase_traversal_state.current_bg_pinned = prev_bg_pinned
        end
      end

      sig { params(node: AST::ThenChain).void }
      def visit_ThenChain(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        # Sequential chaining: each step runs in order inside the same fiber.
        # Steps with AS bindings declare a local variable accessible to later steps.
        # The last step's type determines the ThenChain's type.
        #
        # Error propagation: if a step returns !T and has an AS binding, the
        # binding type is T (unwrapped). The error propagates to the BG result
        # via try/errdefer in the generated Zig code.
        last_type = T.let(Type.new(:Void), Type)
        node.steps.each do |step|
          visit(step.expr)
          step_type = step.expr.full_type!(context: "THEN step")

          if (binding = step.binding)
            # Unwrap error union for the binding: !T -> T
            bind_type = step_type
            bind_type = step_type.payload_type if step_type.error_union?

            current_scope.declare(
              binding,
              nil,
              bind_type,
              false,  # immutable
              false,  # not rebindable
              nil,
              :stack
            )
            record_capture_local!(step.binding.to_s)
          end

          last_type = step_type
        end
        stamp_type!(node, last_type)
      end

      sig { params(node: AST::NextExpr).returns(T.nilable(Symbol)) }
      def visit_NextExpr(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        record_effect(EffectTracker::YIELD)
        visit(node.expr)
        expr = node.expr
        promise_type = expr.full_type!(context: "NEXT expression")

        unless promise_type.future?
          error!(node, :NEXT_NEEDS_FUTURE, got: expr.full_type!(context: "NEXT non-future expression"))
        end

        # NEXT awaits a promise/stream — always a fiber suspension point.
        record_effect(EffectTracker::SUSPENDS)

        async_shape = expr.is_a?(AST::Identifier) ? expr.symbol&.async_result_shape : nil

        if async_shape&.promise?
          if expr.is_a?(AST::Identifier) && !async_shape.shared_promise?
            og_set_moved(expr.name, at_token: expr.token, action: :next)
          end
          stamp_type!(node, async_shape.payload_type)
          node.storage = :heap if async_next_result_requires_heap?(async_shape.payload_type)
        elsif promise_type.promise_list?
          # NEXT on ~T[]@list: await all promises, return T[]@list.
          # The promise list is linearly consumed — each inner promise is freed by its next() call.
          if expr.is_a?(AST::Identifier)
            og_set_moved(expr.name, at_token: expr.token, action: :next)
          end
          elem_sym = T.must(promise_type.tense_type.element_type).to_sym
          stamp_type!(node, Type.new(:"#{elem_sym}[]", collection: :list))
        elsif promise_type.observable_array_future?
          # NEXT on ~T[]@set:observable: wait for the producer fiber, then
          # take an owned `T[]` snapshot via `materializeNext(alloc)`. The
          # codegen path lives in lower_next_expr; here we just stamp the
          # binding's type so downstream `final.length()` etc. resolve.
          #
          # Mark the source binding moved so a second NEXT is rejected.
          # The cleanup path destroys the StreamSet at end-of-scope; a
          # second NEXT after that would be UAF. Even before scope exit,
          # `materializeNext` waits for `finish()` -- the producer is
          # done after the first call, so a second NEXT would just
          # re-take the same snapshot, violating the consume-or-transfer
          # semantics. Match scalar-NEXT behavior: linearly consume.
          og_set_moved(expr.name, at_token: expr.token, action: :next) if expr.is_a?(AST::Identifier)
          elem_sym = T.must(promise_type.tense_type.element_type).to_sym
          stamp_type!(node, Type.new(:"#{elem_sym}[]"))
          node.storage   = :heap
        elsif promise_type.dynamic_stream?
          elem_sym = T.must(promise_type.tense_type.element_type).to_sym
          if promise_type.canonical_stream?
            stamp_type!(node, Type.stream_step_of(T.must(promise_type.tense_type.element_type)))
          else
            stamp_type!(node, Type.new(:"?#{elem_sym}"))
          end
        elsif promise_type.bounded_stream?
          # Canonical finite streams expose completion as a tagged step so an
          # optional item remains distinguishable from exhaustion. Legacy
          # ~T[N] keeps its direct-T behavior until corpus migration completes.
          element_type = T.must(promise_type.stream_element_type)
          if promise_type.canonical_stream?
            stamp_type!(node, Type.stream_step_of(element_type))
          else
            stamp_type!(node, element_type.to_sym)
          end
        elsif promise_type.shared_promise?
          # NEXT on ~T@shared: returns T, idempotent — same handle can be NEXT'd again.
          # Does NOT mark as moved; multiple consumers may hold their own handles.
          stamp_type!(node, promise_type.tense_type.to_sym)
        elsif promise_type.split_open_stream? || promise_type.open_stream?
          # NEXT on open streams returns ?T — null signals stream exhaustion.
          # Split stream handles advance independently through shared memoized sequence state.
          # Does NOT mark as moved — stream is a resource cleaned up via deinit.
          elem_sym = T.must(promise_type.open_stream_element_type).to_sym
          stamp_type!(node, Type.new(:"?#{elem_sym}"))
        elsif promise_type.inf_stream?
          # NEXT on ~T[INF]: returns T (never nil — stream is infinite, rendezvous-style).
          # Does NOT mark as moved — stream is a resource cleaned up via deinit.
          stamp_type!(node, T.must(promise_type.inf_stream_element_type).to_sym)
        else
          # NEXT on ~T: returns T, marks the promise as linearly consumed.
          if expr.is_a?(AST::Identifier)
            og_set_moved(expr.name, at_token: expr.token, action: :next)
          end
          stamp_type!(node, promise_type.tense_type.to_sym)
        end

        nil
      end

      sig { params(type_info: Type).returns(T::Boolean) }
      def async_next_result_requires_heap?(type_info)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return false if type_info.id_handle?

        type_info.ownership_bearing?(->(name) { lookup_type_schema(name) })
      end

      sig { params(type_info: Type).returns(Type) }
      def owned_async_payload_type(type_info)
        # Literal strings are annotated as rodata byte arrays at their source,
        # but a BG result outlives that fiber and is owned by the promise
        # consumer. Publish the boundary type, not the source provenance.
        return Type.new(:String, location: :heap) if type_info.string? && type_info.rodata?

        type_info
      end

      private :mark_with_runtime_requirements!,
        :validate_no_multi_object_atomic!,
        :validate_lock_error_clause!
      private :async_next_result_requires_heap?
      private :owned_async_payload_type
  private :cap_admits_atomic?
  private :field_name_for_msg
  private :resolve_error_selectors!
  private :retryable_with_call_fallible?
  private :retryable_with_fallible_body_error!
  private :retryable_with_fallible_sources
  private :retryable_with_universal_poly_candidate?
  private :validate_snapshot_match_arms!
  private :validate_with_match_source_shape!
  private :with_block_has_versioned_arm?
  private :with_requires_binding?

end
  end
end
