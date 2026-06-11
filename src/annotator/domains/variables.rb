# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module Variables
      extend T::Sig

      sig { params(node: AST::VarDecl).void }
      def visit_VarDecl(node)
        T.bind(self, SemanticAnnotator)

        if node.value.is_a?(AST::ListLit) && node.type&.fixed?
          node.value.storage = :stack
        end
        visit(node.value)
        promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
        promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)
        finalize_decl_node!(node, node.mutable)
        stamp_init_contents_heap!(node)
        stamp_bg_handle_lifetime!(node)
      end

      # Shared declaration body used by visit_VarDecl and the declaration path of
      # visit_BindExpr. mutable_flag is node.mutable for VarDecl and false for BindExpr
      # (BindExpr declarations are immutable by default).
      # Pipeline-terminal observable detection. When the bind site has shape:
      #
      #   running: ~Int64@observable = stream |> SUM _;
      #
      # The pipe's apparent scalar type has to be lifted to the LHS observable
      # type so coerce! accepts the assignment and codegen chooses the
      # accumulator path instead of an inline fold.

      DeclarationNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr) }

      sig { params(node: DeclarationNode).returns(T.nilable(Type)) }
      def promote_pipe_to_observable_dest!(node)
        T.bind(self, SemanticAnnotator)

        return unless node.respond_to?(:type) && node.type
        return unless node.value
        target = node.type
        return unless target.future? && target.observable?
        pipe = node.value
        return unless pipe.is_a?(AST::BinaryOp) && pipe.smooth?
        return unless pipe.observable_terminal
        pipe.observable_dest = true
        # Preserve the terminal kind set by lift_to_observable_if_terminal!.
        # The LHS annotation (`~Int64@observable`) carries no terminal info;
        # only the fold's analyzer knows whether this is :sum/:count/:max/...
        # Copying it onto node.type also propagates the kind to the binding's
        # symbol entry (so WITH VIEW / NEXT / cleanup all see it).
        pipe_type = pipe.full_type!(context: "observable pipe")
        if pipe_type.observable_terminal
          pipe_terminal = pipe_type.observable_terminal
          target_t = node.type
          # The pipe is the authority on terminal kind: only the fold's
          # analyzer knows whether this is :sum / :count / :max / ... .
          # The LHS annotation (`~Int64@observable`) never carries one, so
          # an existing non-nil stamp here means a prior pass disagreed
          # with the analyzer. Reject loudly instead of silently winning
          # one of the two via `||=` (H7).
          if target_t.observable_terminal && target_t.observable_terminal != pipe_terminal
            error!(node, :OBSERVABLE_TERMINAL_MISMATCH,
              lhs: target_t.observable_terminal.inspect,
              pipe: pipe_terminal.inspect)
          end
          target_t.stamp_observable_terminal!(pipe_terminal)
          node.type = target_t
          # node.full_type is the resolved Type read by mir_lowering's
          # transpile_type; propagate the terminal kind there too so
          # OBSERVABLE_WRAPPERS can find it. Without this, the binding's
          # emitted Zig wrapper would default-or-raise. Same mismatch
          # check as above.
          stamp_type!(node, target_t)
        end
        stamp_type!(pipe, node.type)
      end

      sig { params(node: DeclarationNode, mutable_flag: T::Boolean).void }
      def finalize_decl_node!(node, mutable_flag)
        T.bind(self, SemanticAnnotator)

        verify_unrestricted!(node)
        handle_assign_move(node)
        handle_assign_borrow(node)

        validate_type_annotation!(node, node.type) if node.type
        validate_stream_type!(node)

        promote_pipe_to_observable_dest!(node)

        # An `~T@observable` binding has no usable shape unless it was
        # initialized by a fold-pipe over a tense stream: the
        # heap-allocated wrapper, the producer fiber, and the WaitGroup
        # bridge are all created in lower_range_fold_observable_default.
        # A bare `running: ~Int64@observable` (no initializer) or one
        # initialized from another value would dangle: no producer fiber
        # exists, NEXT/COLLECT would deadlock, and the cleanup recipe
        # would call destroy() on an uninitialized struct. Reject here
        # before downstream passes see the bad shape. The post-promote
        # check is correct because promote_pipe_to_observable_dest! sets
        # `observable_dest` only when the RHS is a SMOOTH-pipe over a
        # tense source; any other shape leaves it false.
        if node.type&.future? && node.type.observable?
          pipe = node.value
          ok = pipe.is_a?(AST::BinaryOp) && pipe.smooth? && pipe.observable_dest
          unless ok
            msg = "`~T@observable` bindings must be initialized by a pipeline-terminal fold " \
                  "over a tense stream (e.g. `running: ~Int64@observable = stream |> SUM _`). " \
                  "The producer fiber, atomic accumulator, and WaitGroup wiring all live in " \
                  "the fold's codegen path -- a bare declaration or a non-fold initializer has " \
                  "no producer, so NEXT/COLLECT would deadlock and cleanup would touch an " \
                  "uninitialized wrapper."

            # Offer a fixable that drops `@observable` from the type
            # annotation. When the parser captured a token for the
            # `@observable` capability, we can target it precisely. If the
            # capability was chained (`~Int64@locked:observable` → token's
            # value is `:observable` rather than `@observable`), we span
            # the colon-prefix; otherwise the token is `@observable`. This
            # lands as :interactive (not :auto) because the user almost
            # always wanted a fold-pipe initializer instead — dropping
            # @observable changes the type semantics. We only offer the
            # drop fix; the "add a fold-pipe initializer" alternative is
            # too context-specific to template.
            fixes = []
            obs_tok = node.type.observable_token if node.type.respond_to?(:observable_token)
            if obs_tok
              # Token value is `@observable` (first cap) or `:observable`
              # (chained after another cap). Match length to the actual
              # token text so the edit deletes exactly the right span.
              tok_text = obs_tok.value.to_s
              fixes << Fix.new(
                description: "Drop `#{tok_text}` from the binding's type annotation. The remaining type behaves as a regular binding (no producer fiber, no WITH VIEW); use this if you didn't actually want streaming-aggregate semantics.",
                confidence: :interactive,
                edits: [Edit.new(
                  span: Span.new(file: nil, line: obs_tok.line, col: obs_tok.column, length: tok_text.length),
                  replacement: "",
                )],
              )
            end

            return error!(node, :VARDECL_TYPE_MISMATCH_FIXABLE, message: msg) if fixes.empty?
            fixable!(node, message: msg, category: :type, level: :error,
                     fixes: fixes, raise_in_collector: false)
          end
        end

        final_type, error = node.value.coerce!(node.type)
        error!(node, :TYPE_COERCION_FAILED, message: error) if error

        # Empty collection literals annotated as Auto need a permissive
        # container type in scope so method dispatch works during the body walk;
        # the declaration annotation remains Auto for the later constraint pass.
        if AST.empty_auto_collection_literal_decl?(node)
          final_type = node.value.type_object
        end

        check_prefixed_int_range!(node.value, node.value.coerced_type || final_type)
        propagate_declared_type_to_value!(node, final_type)

        storage = finalize_decl_storage!(node, final_type)
        propagate_collection_metadata!(node, final_type)
        propagate_call_flags!(node)
        set_cleanup_alloc!(node)
        # The symbol is born with the annotation-derived placement only.
        # Escape analysis is the single writer that makes Symbol#storage
        # definitive (promotes to :heap when the binding escapes); the
        # annotator must not pre-fold a type's heap-capable provenance onto
        # the symbol -- that over-promotes (e.g. a union typed heap-capable
        # but never actually escaping).
        is_resource, resource_close = resolve_resource_close(node)
        node.resource_close_plan = resource_close
        node_type = node.full_type!(context: "var declaration")
        node_type.is_resource = true if is_resource && node_type.respond_to?(:is_resource=)

        Capabilities.validate!(node, node_type) { |n, msg| error!(n, :CAPABILITY_INVALID, message: msg) }

        node_sync = node_type.sync
        node_layout = node_type.layout
        # Preserve collection metadata (e.g. :set from DISTINCT) in scope so
        # resolve_full_type returns the correct dispatch_key for method lookup.
        # Do NOT store the full node.full_type — it embeds ownership/sync from
        # finalize_storage!, which breaks resolve_type in declare_capability_scope!
        # (WITH EXCLUSIVE unwrapping reads the raw entry.type expecting just the base type).
        scope_type = if node_type.collection && !(final_type.is_a?(Type) && final_type.collection)
          ft = Type.new(final_type)
          ft.copy_collection_shape_from!(node_type)
          ft
        else
          final_type
        end
        current_scope.declare(
          node.name, node, scope_type, mutable_flag, false, node.slot_size, storage,
          Set.new, [],
          sync: node_sync,
          layout: node_layout,
          resource: is_resource,
          close_plan: resource_close
        )
        record_capture_local!(node.name.to_s)
        node.symbol = current_scope.local_entry!(node.name)
        sym = T.must(node.symbol)
        sym.async_result_shape = node.value.async_result_shape if node.value.is_a?(AST::BgBlock)
        # (The late-provenance fold now happens BEFORE declare, above, so the
        # symbol is born with the correct storage -- no post-declare write.)
        # Propagate @link_source from the value type to the scope entry.
        val_ti = node.value&.full_type!(context: "declaration link source value")
        if val_ti&.link?
          link_src = val_ti.link_source
          sym.link_source = link_src if link_src
        end
        # `~T@observable` bindings are non_escaping: the heap accumulator's
        # producer fiber holds a borrow of the source iterator (`gen`),
        # which is bound to this scope's frame. Returning, GIVE-ing, or
        # capturing the binding into a longer-lived context (BG fiber,
        # struct field, collection element) leaves the producer fiber
        # with a dangling pointer when the original frame rewinds. The
        # existing Lockdown 2/3 checks (BG capture / struct+collection
        # store) fire automatically once non_escaping is set; RETURN is
        # rejected by visit_ReturnNode's non_escaping guard. Users get the
        # value out via `|> COLLECT` (joins + extracts scalar) or
        # `WITH MATERIALIZED VIEW` (deep-copy snapshot).
        if node_type.observable?
          sym.mark_non_escaping!
        end
        # Bare `T@versioned` is legal but unusual: a single-owner MVCC cell
        # cannot be reached from another thread, so suggest the shared form.
        if node_type.versioned? && node_type.ownership == :affine
          cap_tok = node.value.is_a?(AST::CapabilityWrap) ? node.value.token : nil
          fixes = []
          if cap_tok && cap_tok.value.to_s == "@versioned"
            fixes << Fix.new(
              description: "Upgrade `@versioned` to `@shared:versioned` for cross-thread sharing.",
              confidence: :auto,
              edits: [Edit.new(
                span: Span.new(file: nil, line: cap_tok.line, col: cap_tok.column, length: "@versioned".length),
                replacement: "@shared:versioned",
              )],
            )
          end
          msg = "Bare `@versioned` on '#{node.name}' is unusual: a single-owner " \
                "MVCC cell isn't reachable from another thread, so the lock-free " \
                "commit path has no concurrent benefit. Use `@shared:versioned` " \
                "for cross-thread sharing, or remove `@versioned` if the cell is " \
                "truly local."
          if fixes.any?
            fixable!(node, message: msg, category: :lint, level: :warning, fixes: fixes)
          else
            note!(node, msg)
          end
        end
        classify_ownership!(sym)
        og_declare(node.name, node, node.full_type!(context: "var declaration"))
        register_container_borrow!(node)
        # Non-Copy union locals need rt for cleanup (heapAlloc for *T/@indirect fields).
        ti = node.full_type!(context: "var declaration ownership")
        if ti && !ti.implicitly_copyable? { |t| lookup_type_schema(t) }
          current_fn_ctx&.record_heap_use!
        end
        accumulate_stack_bytes(storage, node)
        track_union_alias(node.name, node.value)
        record_capability_binding(node.name, node, final_type, storage)
        nil
      end

      # Keywordless `x = val` or `x: Type = val`.
      # If x is not yet in scope → immutable declaration (like old VAR x = val).
      # If x is in scope and mutable → assignment (like old SET x = val).
      # If x is in scope and immutable → error.

      sig { params(node: AST::BindExpr).void }
      def visit_BindExpr(node)
        T.bind(self, SemanticAnnotator)

        # Same pre-set as visit_VarDecl: mark fixed-array list literals as :stack before visiting.
        if node.value.is_a?(AST::ListLit) && node.type&.fixed?
          node.value.storage = :stack
        end
        visit(node.value)

        scope = current_scope
        # `_` is a discard sink: every `_ = expr;` is an independent
        # declaration, never a reassignment.
        if !scope.entry?(node.name) || node.name == "_"
          # Declaration path
          promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
          promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)
          node.mode = :decl
          finalize_decl_node!(node, false)
          if node.value.instance_variable_get(:@has_borrowed_fields)
            sym = T.must(node.symbol)
            sym.mark_non_escaping!
            sym.mark_borrowed_alias!
          end
          stamp_init_contents_heap!(node)
          stamp_bg_handle_lifetime!(node)

        elsif scope.is_immutable?(node.name)
          node.symbol = scope.resolve_entry(node.name)
          stamp_type!(node, scope.resolve_type(node.name))
          emit_immutable_assignment_error!(node, scope)

        else
          # Assignment path
          node.mode = :assign

          verify_unrestricted!(node)
          node.symbol = scope.entry_for_write(node.name)
          validate_assignment_type(node, scope.resolve_type(node.name), node.value.resolved_type)
          stamp_type!(node, scope.resolve_type(node.name))

          handle_assign_move(node)
          handle_assign_borrow(node)

          mark_var_mutated(node.name)
          og_set_live(node.name)

          # Atomic compound assignments must become fetch ops; load+add+store
          # would lose atomicity.
          target_sync = scope.resolve_entry(node.name)&.sync
          if target_sync == :atomic
            op = case node.compound_op
                 when nil  then :store
                 when :ADD then :fetchAdd
                 when :SUB then :fetchSub
                 when :MUL, :DIV
                   op_str = node.compound_op == :MUL ? "*=" : "/="
                   error!(node, :ATOMIC_NO_MUL_DIV_COMPOUND,
                     op: op_str)
                   nil
                 else
                   error!(node, :ATOMIC_UNSUPPORTED_COMPOUND, op: node.compound_op)
                   nil
                 end
            node.auto_atomic_op = op if op
            record_effect(EffectTracker::CONTENTION)
          end
        end
      end

      sig { params(node: AST::Identifier).returns(T.nilable(SymbolEntry)) }
      def visit_Identifier(node)
        T.bind(self, SemanticAnnotator)

        predicate_identifier_allowed!(node)

        # Pipeline expressions (inside |>) are closures over the enclosing scope —
        # lookup_scope_for searches all scopes. Normal code uses resolve_variable_scope
        # which restricts to local scope + function-as-value references.
        scope = smooth_depth > 0 ? lookup_scope_for(node.name) : resolve_variable_scope(node.name)
        unless scope
          # Check if it's a type name used as a comptime argument (e.g., parseFromSlice(MyDoc, ...))
          type_schema = lookup_type_schema(node.name.to_sym)
          if type_schema
            stamp_type!(node, :Type)
            return
          end
          emit_typo_suggestion!(
            node.token, node.name, outer_scope_vars.to_a,
            "Undefined variable '#{node.name}'",
            "closest in-scope variable"
          )
          return
        end

        # 1. Check Validity (View Invalidation Logic)
        scope.check_validity!(node.name)

        # 2. Resolve Type
        raw_type = scope.resolve_full_type(node.name)
        if raw_type.raw.is_a?(FunctionSignature)
          # Named function used as a value — re-wrap the signature in a Type
          # tagged as a fn_ref so the transpiler emits `&fn_name`.
          stamp_type!(node, Type.new(raw_type.raw))
          node.fn_ref = true
        elsif raw_type.is_a?(Type) && raw_type.atomic? && raw_type.layout != :indirect
          # Atomic reads type as the inner value; the symbol keeps :atomic so
          # assignment targets and MIR lowering still see the cell semantics.
          stamp_type!(node, Type.new(raw_type.raw))
          # Atomic loads contend on the cache line but never park.
          record_effect(EffectTracker::CONTENTION)
        else
          stamp_type!(node, raw_type)
        end

        # 3. Liveness
        if ownership_graph.moved?(node.name)
          emit_use_of_moved_error!(node, T.must(ownership_graph.nodes[node.name]))
        end

        # 5. Mark variable as read so the transpiler can skip `_ = &x` suppression.
        owner = lookup_scope_for(node.name)
        owner&.mark_read(node.name)
        node.symbol = owner&.entry_for_write(node.name)
        record_capture_identifier!(node)
        node.symbol
      end

      # DEPRECATED (SROA hint only, no memory safety role): Sets ownership_kind on scope entries
      # to guide the LLVM backend's SROA pass (whether to emit `_ = &name;` suppression).
      # This has no effect on correctness or memory safety — it is purely a performance annotation.
      # When SROA is revisited (likely as part of a dedicated LLVM codegen pass), this method and
      # all call sites should be removed. The MIR layer owns all memory decisions; this is a
      # leftover from before that architecture was established. Do not add new cases here.

      sig { params(entry: SymbolEntry).returns(T.nilable(Symbol)) }
      def classify_ownership!(entry)
        T.bind(self, SemanticAnnotator)

        return unless entry
        type_obj = entry.type
        return if type_obj.fn_type? # function signature, not a variable
        entry.ownership_kind = if entry.resource
          :resource
        elsif type_obj.multiowned? || type_obj.shared? ||
              entry.rc_stored?
          :rc
        elsif entry.sync
          :sync
        elsif type_obj.collection?
          :collection
        elsif !entry.takes && type_obj.implicitly_copyable? { |t| lookup_type_schema(t) }
          :value
        else
          # TAKES parameters own the data — always affine so cleanup is emitted.
          :affine
        end
      end

      # Accumulate stack-local variable bytes for the current function context.
      # Only counts :stack storage — :frame and :heap don't consume fiber stack.
      # Track alias relationships for union values extracted from collections.
      # When x = f(source) where f returns a union and source is a union/collection,
      # x's backing data may alias source's. Skip cleanup for x.
      # Track alias relationships for union values extracted from collections.
      # Only UFCS method calls (x.get(key) returning same union type) are aliasing.
      # FuncCall (parseValue!(json, pos, penv, depth)) creates new data, not aliasing.
      # Track alias relationships for union values extracted from another union/collection.
      # Aliased variables share backing data with the source - skip cleanup to avoid double-free.

      sig { params(var_name: String, value_node: AST::Node).returns(T.nilable(T::Array[OwnershipGraph::Edge])) }
      def track_union_alias(var_name, value_node)
        T.bind(self, SemanticAnnotator)

        return unless value_node.is_a?(AST::FuncCall) || value_node.is_a?(AST::MethodCall)
        ret_type = value_node.full_type!(context: "union alias return")
        return unless ret_type
        ret_type_obj = ret_type.is_a?(Type) ? ret_type : Type.new(ret_type)

        # Check if the return type is a union with heap variants
        schema = lookup_type_schema(ret_type_obj.resolved)
        return unless Schemas.union?(schema)
        has_heap = (schema.variants || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
        return unless has_heap

        # Get the first argument (object for MethodCall, first arg for FuncCall)
        first_arg = if value_node.is_a?(AST::MethodCall)
          value_node.object
        elsif value_node.args.any?
          value_node.args.first
        end
        return unless first_arg.is_a?(AST::Identifier)
        arg_type = first_arg.resolved_type

        # Alias when: first arg is the SAME union type (extraction like jsonGet)
        # or first arg is a map (HashMap lookup returning union value)
        if arg_type == ret_type_obj.resolved || first_arg.full_type!(context: "union alias source").map?
          ownership_graph.add_edge(OwnershipGraph::Edge.new(from: var_name, to: first_arg.name, kind: :aliases))
        end
        nil
      end

      sig { params(storage: Symbol, node: DeclarationNode).returns(T.nilable(Integer)) }
      def accumulate_stack_bytes(storage, node)
        T.bind(self, SemanticAnnotator)

        fn_ctx = current_fn_ctx
        return unless storage == :stack && fn_ctx
        bytes = (node.slot_size || 1) * 8
        fn_ctx.record_stack_bytes!(bytes)
        bytes
      end

      sig { params(name: String).void }
      def mark_var_mutated(name)
        T.bind(self, SemanticAnnotator)

        scope = lookup_scope_for(name)
        return unless scope
        entry = scope.entry_for_write(name)
        return unless entry
        entry.mark_mutated!(touch_declaration: true)
      end

      # Mark a binding as mutated INDIRECTLY (e.g. via a function call that
      # takes the binding by mutable reference). Sets only the SymbolEntry
      # flag — does NOT touch decl_node.var_mutated. The lint
      # ("MUTABLE never reassigned") and the var/const emit decision both
      # key off decl_node.var_mutated; promoting them here would cause Zig
      # to emit `var` for a local that has no visible Zig-level mutation,
      # tripping Zig's "var never mutated" safety check. The SymbolEntry
      # flag is what post-annotation passes (like
      # validate_with_guard_no_body_mutation!) read to detect any mutation,
      # direct or indirect.

      sig { params(name: String).void }
      def mark_var_mutated_via_call(name)
        T.bind(self, SemanticAnnotator)

        scope = lookup_scope_for(name)
        return unless scope
        entry = scope.entry_for_write(name)
        return unless entry
        entry.mark_mutated_via_reference!
      end

      # Walk a chained access expression (GetField/GetIndex chain rooted at an
      # Identifier) and return the root identifier name, or nil if the chain
      # doesn't bottom out at one. Used to attribute receiver mutation back to
      # the declared binding.

      sig { params(node: T.any(AST::GetField, AST::GetIndex, AST::Identifier)).returns(T.nilable(String)) }
      def chain_root_name(node)
        T.bind(self, SemanticAnnotator)

        curr = T.let(node, T.any(AST::GetField, AST::GetIndex, AST::Identifier))
        while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex)
          curr = curr.target
        end
        curr.is_a?(AST::Identifier) ? curr.name : nil
      end

      # ==========================================
      # Assignment
      # ==========================================

      sig { params(node: AST::Assignment).returns(T.nilable(Symbol)) }
      def visit_Assignment(node)
        T.bind(self, SemanticAnnotator)

        # If the assignment target is a `@locked` / `@writeLocked` field
        # write (e.g. `c.value = c.value + 1`), the auto-lock path emits
        # a single lock acquire that covers BOTH the LHS write AND the
        # RHS reads. Set the auto-lock context before visiting the RHS
        # so visit_GetField's CAP_FIELD_NEEDS_WITH_EXCLUSIVE check skips
        # the in-RHS read of the same `@locked` binding (it's safe under
        # the auto-lock).
        previous_auto_lock = phase_receiver_state.auto_locked_assign_name
        auto_lock_name = T.let(previous_auto_lock, T.nilable(String))
        target = node.name
        if target.is_a?(AST::GetField) && target.target.is_a?(AST::Identifier)
          # Symbol isn't stamped until visit_Identifier runs, so look up
          # the binding's sync from the scope directly.
          tname = target.target.name
          tscope = lookup_scope_for(tname)
          tsym = tscope&.resolve_entry(tname)
          if tsym&.locked? || tsym&.write_locked? || tsym&.atomic_ptr?
            auto_lock_name = tname
          end
        end

        phase_receiver_state.auto_locked_assign_name = auto_lock_name
        begin
          visit(node.value)
        ensure
          phase_receiver_state.auto_locked_assign_name = previous_auto_lock
        end

        verify_unrestricted!(node)
        # Tied-lifetime values cannot be stored into destinations that outlive
        # any of their lifetime sources.
        verify_tied_assignment!(node)

        target = node.name
        case target
        when AST::Identifier
          visit_assignment_variable(target, node)

        when AST::GetIndex
          visit_assignment_index(target, node)

        when AST::GetField
          visit_assignment_field(target, node)

        else
          error!(node, :INVALID_ASSIGNMENT_TARGET, got: target.class)
        end

        handle_assign_move(node)
        handle_assign_borrow(node)

        og_set_live(node.name.name) if node.name.is_a?(AST::Identifier)
      end

      sig { params(identifier: AST::Identifier, node: AST::Assignment).returns(T::Boolean) }
      def visit_assignment_variable(identifier, node)
        T.bind(self, SemanticAnnotator)

        var_name = identifier.name
        scope = current_scope
        if !scope.entry?(var_name)
          error!(node, :ASSIGN_UNDEFINED_VAR, name: var_name)
        end

        if scope.is_immutable?(var_name)
          fix = build_declare_mutable_fix(var_name, scope)
          if fix
            fixable!(node,
              message: T.must(DiagnosticRegistry.format(:ASSIGN_VAR_IMMUTABLE, name: var_name)),
              category: :ownership,
              level: :error,
              fixes: [fix])
          else
            error!(node, :ASSIGN_VAR_IMMUTABLE, name: var_name)
          end
        end

        validate_assignment_type(node, scope.resolve_type(var_name), node.value.resolved_type)
        stamp_type!(node, scope.resolve_type(var_name))
        mark_var_mutated(var_name)
        true
      end

      sig { params(index_node: AST::GetIndex, assignment_node: AST::Assignment).returns(NilClass) }
      def visit_assignment_index(index_node, assignment_node)
        T.bind(self, SemanticAnnotator)

        visit(index_node)

        mark_chain_needs_mut_ref!(index_node)

        if index_node.target.is_a?(AST::Identifier)
          var_name = index_node.target.name
          if current_scope.is_immutable?(var_name)
            emit_immutable_index_assignment_error!(assignment_node, current_scope, var_name)
          end
          mark_var_mutated(var_name)
        else
          # Chained target (e.g. `y.items[0] = ...`). Mark the root binding
          # mutated so post-annotation passes (GUARD validation, etc.) can see
          # it. Immutability is enforced by the assignment_field visitor on
          # the way up.
          root = chain_root_name(index_node.target)
          mark_var_mutated(root) if root
        end

        # Map reads return ?V, but map writes store V.
        assign_type = index_node.full_type!(context: "index assignment target")
        if assign_type&.optional?
          assign_type_resolved = T.must(assign_type.wrapped_type).resolved
        else
          assign_type_resolved = index_node.resolved_type
        end
        validate_assignment_type(assignment_node, assign_type_resolved, assignment_node.value.resolved_type)

        stamp_type!(assignment_node, T.must(assign_type_resolved))

        # HashMap put may allocate, so needs_rt must propagate.
        target_type = index_node.target.full_type!(context: "index assignment collection")
        if target_type&.map?
          current_fn_ctx&.record_heap_use!
          record_effect(EffectTracker::HEAP)
        end
      end

      sig { params(field_node: AST::GetField, assignment_node: AST::Assignment).returns(T.nilable(Symbol)) }
      def visit_assignment_field(field_node, assignment_node)
        T.bind(self, SemanticAnnotator)

        # Field writes go through the auto-lock path, not the WITH-required
        # diagnostic used for reads.
        field_node.is_assignment_lhs = true
        visit(field_node)

        # AtomicPtr publishes whole-T snapshots; only the WITH SNAPSHOT MUTABLE
        # alias can accept field assignments.
        reject_bare_atomic_ptr_mutation!(field_node, assignment_node)

        mark_chain_needs_mut_ref!(field_node)

        # @alwaysMutable (RefCell) allows field mutation through const bindings.
        if field_node.target.is_a?(AST::Identifier)
          var_name = field_node.target.name
          syn = field_node.target.symbol&.sync
          if current_scope.is_immutable?(var_name) && syn != :always_mutable
            emit_immutable_field_assignment_error!(assignment_node, current_scope, var_name, field_node.field)
          end
          mark_var_mutated(var_name)

          # 3. Auto-lock: if the target variable is @locked or @writeLocked, mark the
          # assignment for inline guard emission. The borrow cannot escape because
          # field assignments are statements (not expressions).
          syn = field_node.target.symbol&.sync
          if syn == :locked || syn == :write_locked || syn == :always_mutable
            assignment_node.auto_lock = AST::AutoLockPlan.new(var: var_name, sync: syn)
          end
        else
          # Chained target (e.g. `y.items.field = ...` or `obj.f.g = ...`).
          # Attribute mutation to the chain root so post-annotation passes
          # see it without re-walking the AST.
          root = chain_root_name(field_node.target)
          mark_var_mutated(root) if root
        end

        # 4. Type Check
        validate_assignment_type(assignment_node, field_node.resolved_type, assignment_node.value.resolved_type)

        # Assignments are statements (void), not expressions that produce a value.
        stamp_type!(assignment_node, :Void)
      end

      sig { params(node: T.any(AST::Assignment, AST::BindExpr), target_type: T.nilable(Type::TypeInput), value_type: Symbol).void }
      def validate_assignment_type(node, target_type, value_type)
        T.bind(self, SemanticAnnotator)

        return if target_type.nil? || target_type == :Any || value_type == :Any
        return if target_type == :NIL # Allow narrowing from initial NIL
        return if target_type == value_type

        if !is_safe_autocast?(value_type, target_type)
          emit_type_mismatch_assign_error!(node, target_type, value_type)
        else
          node.value.coerced_type = target_type
        end
      end

      # ==========================================
      # INVALIDATION LOGIC (The "Dependencies" feature)
      # ==========================================
      private :finalize_decl_node!
    end
  end
end
