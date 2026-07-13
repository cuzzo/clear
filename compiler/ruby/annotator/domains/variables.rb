# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module Variables
      extend T::Sig

      sig { params(node: AST::VarDecl).void }
      def visit_VarDecl(node)
        T.bind(self, SemanticAnnotator)

        prepare_implicit_ownership_transport!(node)
        visit_declaration_value!(node)
        finalize_var_declaration!(node)
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

        value = T.must(node.value)
        verify_unrestricted!(node)
        handle_assign_move(node)
        handle_assign_borrow(node)

        declared_type = node.type
        validate_type_annotation!(node, declared_type) if declared_type
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
        return unless validate_observable_binding_initializer!(node)

        final_type, error = value.coerce!(node.type)
        error!(node, :TYPE_COERCION_FAILED, detail: error) if error

        # A capability constructor is the architectural type decision even
        # when the declaration spells only the payload type (`x: Int64 =
        # 0 @shared:atomic`). Keep the validated capability shape as the
        # lowering coercion target; casting the resulting `*Atomic(Int64)`
        # back to the payload `Int64` produces invalid Zig and discards the
        # declared runtime semantics.
        if value.is_a?(AST::CapabilityWrap) && (value.ownership || value.sync || value.layout)
          capability_target = node.type ? Type.new(node.type) : Type.new(value.full_type!(context: "capability declaration value"))
          capability_target.merge_capabilities_from!(value.full_type!(context: "capability declaration value"))
          value.coerced_type = capability_target
          final_type = capability_target
        end

        # Empty collection literals annotated as Auto need a permissive
        # container type in scope so method dispatch works during the body walk;
        # the declaration annotation remains Auto for the later constraint pass.
        if AST.empty_auto_collection_literal_decl?(node)
          final_type = value.type_object
        end

        check_prefixed_int_range!(value, value.coerced_type_info || final_type)
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
        resource_result = resolve_resource_close(node)
        node.resource_close_plan = resource_result.close_plan
        node_type = node.full_type!(context: "var declaration")
        node_type.is_resource = true if resource_result.is_resource && node_type.respond_to?(:is_resource=)

        Capabilities.validate!(node, node_type) { |n, msg| error!(n, :CAPABILITY_INVALID, detail: msg) }

        node_sync = node_type.sync
        node_layout = node_type.layout
        # Preserve collection metadata (e.g. :set from DISTINCT) in scope so
        # resolve_full_type returns the correct dispatch_key for method lookup.
        # Do NOT store the full node.full_type — it embeds ownership/sync from
        # finalize_storage!, which breaks resolve_type in declare_capability_scope!
        # (WITH EXCLUSIVE unwrapping reads the raw entry.type expecting just the base type).
        scope_type = if node_type.collection_value?
          ft = Type.new(final_type)
          ft.copy_collection_shape_from!(node_type)
          ft.copy_element_capabilities_from!(node_type)
          ft
        else
          final_type
        end
        current_scope.declare(
          node.name, node, scope_type, mutable_flag, false, node.slot_size, storage,
          Set.new, [],
          sync: node_sync,
          layout: node_layout,
          resource: resource_result.is_resource,
          close_plan: resource_result.close_plan
        )
        record_capture_local!(node.name.to_s)
        node.symbol = current_scope.local_entry!(node.name)
        sym = T.must(node.symbol)
        sym.async_result_shape = value.async_result_shape if value.is_a?(AST::BgBlock)
        # (The late-provenance fold now happens BEFORE declare, above, so the
        # symbol is born with the correct storage -- no post-declare write.)
        # Propagate @link_source from the value type to the scope entry.
        val_ti = value.full_type!(context: "declaration link source value")
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
          cap_tok = value.is_a?(AST::CapabilityWrap) ? value.token : nil
          fixes = []
          if cap_tok && cap_tok.value.to_s == "@versioned"
            fixes << Fix.new(
              description: fix_description(:UPGRADE_VERSIONED_TO_SHARED),
              confidence: :auto,
              edits: [Edit.new(
                span: Span.new(file: nil, line: cap_tok.line, col: cap_tok.column, length: "@versioned".length),
                replacement: "@shared:versioned",
              )],
            )
          end
          if fixes.any?
            fixable!(node, code: :BARE_VERSIONED_UNSHARED, name: node.name,
                     category: :lint, level: :warning, fixes: fixes)
          else
            note!(node, diagnostic_message(:BARE_VERSIONED_UNSHARED, name: node.name))
          end
        end
        classify_ownership!(sym)
        og_declare(node.name, node, node_type)
        establish_inferred_alias!(node, sym)
        register_container_borrow!(node)
        # Non-Copy union locals need rt for cleanup (heapAlloc for *T/@indirect fields).
        if !node_type.implicitly_copyable? { |t| lookup_type_schema(t) }
          current_fn_ctx&.record_heap_use!
        end
        accumulate_stack_bytes(storage, node)
        track_union_alias(node.name, value)
        record_capability_binding(node.name, node, final_type, storage)
        nil
      end

      sig { params(node: DeclarationNode).returns(T::Boolean) }
      def validate_observable_binding_initializer!(node)
        T.bind(self, SemanticAnnotator)

        return true unless node.type&.future? && node.type.observable?

        pipe = node.value
        ok = pipe.is_a?(AST::BinaryOp) && pipe.smooth? && pipe.observable_dest
        return true if ok

        fixes = observable_binding_drop_fixes(node)
        if fixes.empty?
          error!(node, :OBSERVABLE_BINDING_NEEDS_FOLD_PIPE)
          return false
        end

        fixable!(node, code: :OBSERVABLE_BINDING_NEEDS_FOLD_PIPE, category: :type, level: :error,
                 fixes: fixes, raise_in_collector: false)
        true
      end

      sig { params(node: DeclarationNode).returns(T::Array[Fix]) }
      def observable_binding_drop_fixes(node)
        T.bind(self, SemanticAnnotator)

        fixes = T.let([], T::Array[Fix])
        obs_tok = node.type.observable_token if node.type.respond_to?(:observable_token)
        return fixes unless obs_tok

        # Token value is `@observable` (first cap) or `:observable`
        # (chained after another cap). Match length to the actual token text
        # so the edit deletes exactly the right span.
        tok_text = obs_tok.value.to_s
        fixes << Fix.new(
          description: fix_description(:DROP_OBSERVABLE_CAPABILITY, token: tok_text),
          confidence: :interactive,
          edits: [Edit.new(
            span: Span.new(file: nil, line: obs_tok.line, col: obs_tok.column, length: tok_text.length),
            replacement: "",
          )],
        )
        fixes
      end

      # Keywordless `x = val` or `x: Type = val`.
      # If x is not yet in scope → immutable declaration (like old VAR x = val).
      # If x is in scope and mutable → assignment (like old SET x = val).
      # If x is in scope and immutable → error.

      sig { params(node: AST::BindExpr).void }
      def visit_BindExpr(node)
        T.bind(self, SemanticAnnotator)

        prepare_implicit_ownership_transport!(node) if bind_declares_new_symbol?(node, current_scope)
        visit_declaration_value!(node)

        scope = current_scope
        # `_` is a discard sink: every `_ = expr;` is an independent
        # declaration, never a reassignment.
        if bind_declares_new_symbol?(node, scope)
          finalize_bind_declaration!(node)
        elsif scope.is_immutable?(node.name)
          reject_immutable_bind_assignment!(node, scope)
        else
          finalize_bind_assignment!(node, scope)
        end
      end

      sig { params(node: DeclarationNode).void }
      def visit_declaration_value!(node)
        T.bind(self, SemanticAnnotator)

        # Fixed-array list literals must be storage-stamped before visiting so
        # downstream list analysis sees the intended stack placement.
        if node.value.is_a?(AST::ListLit) && node.type&.fixed?
          node.value.storage = :stack
        end
        if node.value.is_a?(AST::ListLit) && node.type&.tuple?
          node.value.coerced_type = node.type
        end
        if node.value.is_a?(AST::HashLit) && node.type&.map?
          node.value.coerced_type = node.type
        end
        visit(node.value)
      end

      sig { params(node: DeclarationNode).void }
      def prepare_implicit_ownership_transport!(node)
        T.bind(self, SemanticAnnotator)
        plan = T.unsafe(node).ownership_transport_plan
        # STRICT preserves CLEAR's explicit affine contract: a plain
        # non-Copy assignment is a move. Ownership inference is a
        # DEFAULT/EASY feature.
        return if language_mode == :strict
        unless plan.is_a?(OwnershipTransportPlan)
          source = node.value
          return unless OwnershipTransportFacts.source?(source)
          source_name = OwnershipTransportFacts.source_display(source)
          T.unsafe(node).ownership_transport_plan = OwnershipTransportPlan.new(
            action: :pending,
            source: source_name,
            destination: node.name.to_s,
            alias_root: source_name,
          )
          return
        end
        return if plan.action == :pending
        return if plan.action == :move

        # The transport planner deliberately runs before type annotation, but
        # Copy values never create aliases.  Consult the already-declared
        # source binding before applying the planner's conservative alias
        # result so primitive/value mutation remains ordinary value mutation.
        source_type = node.value.full_type!(context: "implicit ownership transport source")
        return if source_type.implicitly_copyable? { |name| lookup_type_schema(name) }

        if plan.conflicting_mutation
          mutation = T.must(plan.conflicting_mutation)
          last_line = plan.last_alias_use&.token&.line || mutation.token&.line || node.token.line
          detail = "Aliasing Error: `#{plan.destination} = #{plan.source}` creates an inferred alias, " \
            "but mutation occurs on line #{mutation.token&.line || node.token.line} while `#{plan.destination}` " \
            "remains live through line #{last_line}. CLEAR will not infer snapshot-versus-shared mutation " \
            "semantics in EASY, DEFAULT, or STRICT. Write `#{plan.destination} = COPY #{plan.source}` for " \
            "an independent value, or explicitly use @multiowned/@shared and `CLONE #{plan.source}`."
          source_token = node.value.token
          fixes = T.let([
            Fix.new(
              description: fix_description(:PREFIX_COPY_SNAPSHOT),
              confidence: :interactive,
              edits: [Edit.new(
                span: Span.new(file: nil, line: source_token.line, col: source_token.column, length: 0),
                replacement: "COPY ",
              )],
            ),
          ], T::Array[Fix])
          if source_type.any_rc? || source_type.split?
            fixes << Fix.new(
              description: fix_description(:PREFIX_EXPLICIT_OWNERSHIP_COST, keyword: "CLONE"),
              confidence: :interactive,
              edits: [Edit.new(
                span: Span.new(file: nil, line: source_token.line, col: source_token.column, length: 0),
                replacement: "CLONE ",
              )],
            )
          end
          fixable!(mutation, code: :INFERRED_ALIAS_MUTATION, detail: detail,
            category: :ownership, level: :error, fixes: fixes, raise_in_collector: true)
        end

        if plan.action == :borrow
          node.storage = :borrow
          return
        end
        return unless plan.action == :materialize

        source = node.value
        source_type = source.full_type!(context: "implicit ownership materialization source")
        keyword = source_type.any_rc? || source_type.split? ? "CLONE" : "COPY"
        if language_mode == :strict
          detail = "STRICT ownership cost: `#{plan.destination} = #{plan.source}` requires an implicit " \
            "#{keyword == 'CLONE' ? 'reference-count retain' : 'deep copy'}. Write " \
            "`#{plan.destination} = #{keyword} #{plan.source}` explicitly, or shorten the lifetime so this is a move/borrow."
          fixable!(node, code: :STRICT_IMPLICIT_OWNERSHIP_COST, detail: detail,
            category: :ownership, level: :error,
            fixes: [Fix.new(
              description: fix_description(:PREFIX_EXPLICIT_OWNERSHIP_COST, keyword: keyword),
              confidence: :auto,
              edits: [Edit.new(
                span: Span.new(file: nil, line: source.token.line, col: source.token.column, length: 0),
                replacement: "#{keyword} ",
              )],
            )],
            raise_in_collector: true)
        end

        wrapper = if keyword == "CLONE"
          AST::CloneNode.new(source.token, source)
        else
          AST::CopyNode.new(source.token, source)
        end
        node.value = wrapper
      end

      sig { params(facts: OwnershipTransportFacts).void }
      def finalize_ownership_transport_facts!(facts)
        T.bind(self, SemanticAnnotator)
        facts.decisions.each do |decision|
          node = decision.alias_fact.declaration
          T.unsafe(node).ownership_transport_plan = decision.plan
          if decision.plan.action == :move
            handle_assign_move(node)
            next
          end

          previous_value = node.value
          prepare_implicit_ownership_transport!(node)
          if !node.value.equal?(previous_value)
            wrapper = node.value
            record_capture_site!(wrapper, copied: true)
            if wrapper.is_a?(AST::CloneNode)
              finish_previsited_clone!(wrapper)
            else
              finish_previsited_copy!(T.cast(wrapper, AST::CopyNode))
            end
          end
          symbol = node.respond_to?(:symbol) ? T.unsafe(node).symbol : nil
          establish_inferred_alias!(node, symbol) if symbol.is_a?(SymbolEntry)
        end
        facts.transfer_decisions.each { |decision| finalize_pending_transfer!(decision) }
      end

      sig { params(decision: OwnershipTransportFacts::TransferDecision).void }
      def finalize_pending_transfer!(decision)
        T.bind(self, SemanticAnnotator)
        transfer = decision.transfer
        source = transfer.source
        if decision.materialize
          if transfer.container.respond_to?(:implicit_layout_cost) &&
              T.unsafe(transfer.container).implicit_layout_cost == true
            error!(source, :INDIRECT_TRANSFER_REQUIRES_COPY, name: source.name)
          end
          source_type = source.full_type!(context: "finalized ownership transfer")
          wrapper = if source_type.any_rc? || source_type.split?
            AST::CloneNode.new(source.token, source)
          else
            AST::CopyNode.new(source.token, source)
          end
          record_capture_site!(wrapper, copied: true)
          if wrapper.is_a?(AST::CloneNode)
            finish_previsited_clone!(wrapper)
          else
            finish_previsited_copy!(T.cast(wrapper, AST::CopyNode))
          end
          container = transfer.container
          case container
          when AST::FuncCall
            container.args[T.cast(transfer.slot, Integer)] = wrapper
          when AST::MethodCall
            index = T.cast(transfer.slot, Integer)
            if index.zero?
              container.object = wrapper
            else
              container.args[index - 1] = wrapper
            end
          when AST::StructLit
            container.fields[T.cast(transfer.slot, String)] = wrapper
          when AST::Assignment
            container.value = wrapper
          end
        else
          source.was_moved = true
          T.unsafe(transfer.container).was_moved = true if transfer.container.respond_to?(:was_moved=)
          og_set_moved(source.name, at_token: source.token, action: :move)
        end
      end

      sig { params(node: DeclarationNode, symbol: SymbolEntry).void }
      def establish_inferred_alias!(node, symbol)
        T.bind(self, SemanticAnnotator)
        plan = T.unsafe(node).ownership_transport_plan
        return unless plan.is_a?(OwnershipTransportPlan)
        return if language_mode == :strict
        return if plan.action == :pending
        return if plan.action == :move || plan.last_alias_use.nil?
        source_type = node.value.full_type!(context: "inferred alias source")
        return if source_type.implicitly_copyable? { |name| lookup_type_schema(name) }

        return unless plan.action == :borrow

        symbol.mark_non_escaping!
        symbol.mark_borrowed_alias!
        graph_node = ownership_graph[plan.destination]
        graph_node.kind = :borrowed if graph_node
      end

      sig { params(node: AST::VarDecl).void }
      def finalize_var_declaration!(node)
        T.bind(self, SemanticAnnotator)

        promote_declaration_value!(node)
        finalize_decl_node!(node, node.mutable)
        stamp_init_contents_heap!(node)
        stamp_bg_handle_lifetime!(node)
      end

      sig { params(node: DeclarationNode).void }
      def promote_declaration_value!(node)
        T.bind(self, SemanticAnnotator)

        promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
        promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)
      end

      sig { params(node: AST::BindExpr, scope: Scope).returns(T::Boolean) }
      def bind_declares_new_symbol?(node, scope)
        !scope.entry?(node.name) || node.name == "_"
      end

      sig { params(node: AST::BindExpr).void }
      def finalize_bind_declaration!(node)
        T.bind(self, SemanticAnnotator)

        promote_declaration_value!(node)
        node.mode = :decl
        finalize_decl_node!(node, false)
        mark_borrowed_field_bind_alias!(node)
        stamp_init_contents_heap!(node)
        stamp_bg_handle_lifetime!(node)
      end

      sig { params(node: AST::BindExpr).void }
      def mark_borrowed_field_bind_alias!(node)
        return unless node.value.is_a?(AST::StructLit) && node.value.borrowed_fields?

        sym = T.must(node.symbol)
        sym.mark_non_escaping!
        sym.mark_borrowed_alias!
      end

      sig { params(node: AST::BindExpr, scope: Scope).void }
      def reject_immutable_bind_assignment!(node, scope)
        T.bind(self, SemanticAnnotator)

        node.symbol = scope.resolve_entry(node.name)
        stamp_type!(node, scope.resolve_type(node.name))
        emit_immutable_assignment_error!(node, scope)
      end

      sig { params(node: AST::BindExpr, scope: Scope).void }
      def finalize_bind_assignment!(node, scope)
        T.bind(self, SemanticAnnotator)

        node.mode = :assign
        verify_unrestricted!(node)
        promote_declaration_value!(node)
        node.symbol = scope.entry_for_write(node.name)
        target_type = scope.resolve_type(node.name)
        validate_assignment_type(node, target_type, node.value.resolved_type)
        stamp_type!(node, target_type)

        handle_assign_move(node)
        handle_assign_borrow(node)

        mark_var_mutated(node.name)
        og_set_live(node.name)
        stamp_atomic_bind_assignment!(node, scope.resolve_entry(node.name)&.sync)
      end

      sig { params(node: AST::BindExpr, target_sync: T.nilable(Symbol)).void }
      def stamp_atomic_bind_assignment!(node, target_sync)
        T.bind(self, SemanticAnnotator)

        return unless target_sync == :atomic

        op = atomic_bind_operation(node)
        node.auto_atomic_op = op if op
        record_effect(EffectTracker::CONTENTION)
      end

      sig { params(node: AST::BindExpr).returns(T.nilable(Symbol)) }
      def atomic_bind_operation(node)
        T.bind(self, SemanticAnnotator)

        # Atomic compound assignments must become fetch ops; load+add+store
        # would lose atomicity.
        case node.compound_op
        when nil  then :store
        when :ADD then :fetchAdd
        when :SUB then :fetchSub
        when :MUL, :DIV
          op_str = node.compound_op == :MUL ? "*=" : "/="
          error!(node, :ATOMIC_NO_MUL_DIV_COMPOUND, op: op_str)
          nil
        else
          error!(node, :ATOMIC_UNSUPPORTED_COMPOUND, op: node.compound_op)
          nil
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
          if current_function_type_param?(node.name.to_sym)
            stamp_type!(node, :Type)
            return
          end
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
        raw_type = refined_comptime_type_param_type(raw_type)
        entry = scope.resolve_entry(node.name)
        if raw_type.fn_type? && entry&.storage == :static
          # Named function used as a value — preserve its function type and tag
          # it so MIR lowering emits a function reference.
          stamp_type!(node, raw_type)
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

      sig { params(var_name: String, value_node: AST::Node).void }
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

      sig { params(node: T.any(AST::GetField, AST::GetIndex, AST::OptionalUnwrap, AST::Identifier)).returns(T.nilable(String)) }
      def chain_root_name(node)
        T.bind(self, SemanticAnnotator)

        curr = T.let(node, T.any(AST::GetField, AST::GetIndex, AST::OptionalUnwrap, AST::Identifier))
        while curr.is_a?(AST::GetField) || curr.is_a?(AST::GetIndex) || curr.is_a?(AST::OptionalUnwrap)
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
        promote_to_expr_if!(node, node.value) if node.value.is_a?(AST::IfStatement)
        promote_to_expr_match!(node, node.value) if node.value.is_a?(AST::MatchStatement)

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
              code: :ASSIGN_VAR_IMMUTABLE,
              name: var_name,
              category: :ownership,
              level: :error,
              fixes: [fix])
          else
            error!(node, :ASSIGN_VAR_IMMUTABLE, name: var_name)
          end
        end

        expected_type = scope.resolve_full_type(var_name)
        if language_mode != :strict && node.value.is_a?(AST::Identifier) &&
            !node.value.full_type!(context: "pending binding assignment").implicitly_copyable? { |name| lookup_type_schema(name) }
          T.unsafe(node.value).ownership_pending_transfer = true
        end
        validate_assignment_type(node, scope.resolve_type(var_name), node.value.resolved_type)
        stamp_type!(node, scope.resolve_type(var_name))
        scope.resolve_entry(var_name)&.reassigned = true
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

        target_type = index_node.target.full_type!(context: "index assignment collection")
        assign_type = if target_type&.map?
          # Map reads return ?V because the key may be absent, but map writes
          # store the declared value type V. If V itself is optional, preserve it.
          target_type.value_type
        else
          index_type = index_node.full_type!(context: "index assignment target")
          if index_type&.optional?
            T.must(index_type.wrapped_type)
          else
            index_type
          end
        end

        if language_mode != :strict && assignment_node.value.is_a?(AST::Identifier) &&
            !assignment_node.value.full_type!(context: "pending indexed assignment").implicitly_copyable? { |name| lookup_type_schema(name) }
          T.unsafe(assignment_node.value).ownership_pending_transfer = true
        end

        validate_assignment_type(assignment_node, assign_type, assignment_node.value.resolved_type)

        stamp_type!(assignment_node, T.must(assign_type))

        # HashMap put may allocate, so needs_rt must propagate.
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
        assignment_field_type = field_node.full_type!(context: "assignment field")
        if field_node.safe_nav_chain == true && assignment_field_type.optional?
          assignment_field_type = T.must(assignment_field_type.wrapped_type)
        end
        if language_mode != :strict && assignment_node.value.is_a?(AST::Identifier) &&
            !assignment_node.value.full_type!(context: "pending field assignment").implicitly_copyable? { |name| lookup_type_schema(name) }
          T.unsafe(assignment_node.value).ownership_pending_transfer = true
        end
        validate_assignment_type(
          assignment_node,
          assignment_field_type,
          assignment_node.value.full_type!(context: "assignment value")
        )

        # Assignments are statements (void), not expressions that produce a value.
        stamp_type!(assignment_node, :Void)
      end

      sig { params(node: T.any(AST::Assignment, AST::BindExpr), target_type: T.nilable(Type::TypeInput), value_type: T.nilable(Type::TypeInput)).void }
      def validate_assignment_type(node, target_type, value_type)
        T.bind(self, SemanticAnnotator)

        return if target_type.nil?

        target = Type.new(target_type)
        value = assignment_value_type(node, value_type)
        return if target.any? || value.any? || value.untyped?
        return if target.resolved == :NIL # Allow narrowing from initial NIL
        if unique_union_payload_variant(target, value)
          node.value.coerced_type = target
          return
        end
        if target.accepts?(value)
          node.value.coerced_type = target if target != value ||
            (target.node_reference? && !value.node_reference?)
          return
        end

        emit_type_mismatch_assign_error!(node, target, value.resolved)
      end

      sig { params(node: T.any(AST::Assignment, AST::BindExpr), fallback: T.nilable(Type::TypeInput)).returns(Type) }
      def assignment_value_type(node, fallback)
        value = node.value
        return value.full_type!(context: "assignment value") if value.respond_to?(:typed?) && value.typed?
        return Type.new(fallback) if fallback

        Type.new(:Untyped)
      end

      # ==========================================
      # INVALIDATION LOGIC (The "Dependencies" feature)
      # ==========================================
      private :assignment_value_type
      private :finalize_decl_node!
      private :accumulate_stack_bytes
      private :atomic_bind_operation
      private :bind_declares_new_symbol?
      private :classify_ownership!
      private :finalize_bind_assignment!
      private :finalize_bind_declaration!
      private :finalize_var_declaration!
      private :mark_borrowed_field_bind_alias!
      private :mark_var_mutated
      private :observable_binding_drop_fixes
      private :promote_declaration_value!
      private :promote_pipe_to_observable_dest!
      private :reject_immutable_bind_assignment!
      private :stamp_atomic_bind_assignment!
      private :track_union_alias
      private :validate_assignment_type
      private :validate_observable_binding_initializer!
      private :visit_declaration_value!
      private :visit_assignment_field
      private :visit_assignment_index
      private :visit_assignment_variable

end
  end
end
