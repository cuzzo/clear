# typed: true
# frozen_string_literal: true

require_relative "../../compiler/entrypoint"

module Annotator
  module Domains
    module Errors
      extend T::Sig
      include RecoverableResult

      # Resolve CATCH clauses after body typing. Explicit RAISE/OR_ELSE EXIT type
      # declarations are already seeded from DeclarationIndex, so CATCH Type
      # clauses are source-order independent while type-only error sites stay
      # strict about requiring a registered name.
      sig { params(declarations: Annotator::Phases::DeclarationIndex).void }
      def resolve_catch_clauses_from_declarations!(declarations)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        declarations.function_declarations.each do |fn|
          fn.catch_clauses.each { |clause| resolve_catch_clause!(clause) }
        end
      end

      sig { params(declarations: Annotator::Phases::DeclarationIndex).void }
      def seed_error_type_registrations!(declarations)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        declarations.error_type_registrations.each do |registration|
          _, conflict = AST.register_type!(
            registration.type_name.to_sym,
            registration.kind,
            site_token: registration.token
          )
          emit_error_type_conflict!(
            registration.token,
            registration.type_name,
            conflict
          ) if conflict
        end
      end

      SYNC_POLICY_REQUIRED_ERRORS = %i[LockTimeout MvccConflict AtomicConflict].freeze
      # Errors that may NEVER appear in a SYNC POLICY block.
      SYNC_POLICY_INLINE_ONLY_ERRORS = %i[Deadlock LockCycle].freeze
      # The baked-in default applied when the user writes no SYNC POLICY.
      # Synthesized as typed clauses so the resolver can use it interchangeably
      # with parser-authored per-WITH clauses.
      sig { returns(T::Array[AST::ErrorClause]) }
      def baked_in_default_sync_policy
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        [
          AST::ErrorClause.new(
            selectors: [AST::ErrorSelector.new(form: :type, name: :LockTimeout, token: nil)],
            retries: 3, action: AST::ErrorActionKind::Raise, token: nil,
          ),
          AST::ErrorClause.new(
            selectors: [AST::ErrorSelector.new(form: :type, name: :MvccConflict, token: nil)],
            retries: nil, action: AST::ErrorActionKind::Raise, token: nil,
          ),
          AST::ErrorClause.new(
            selectors: [AST::ErrorSelector.new(form: :type, name: :AtomicConflict, token: nil)],
            retries: nil, action: AST::ErrorActionKind::Raise, token: nil,
          ),
        ]
      end

      # Walk the program statements; reject more than one SyncPolicyDecl,
      # require an `FN main` when one is present, validate the body, and
      # stamp `program_node.sync_policy` with the resolved handlers (the
      # user's if present, else the baked-in default).
      sig { params(program_node: AST::Program).void }
      def validate_and_resolve_sync_policy!(program_node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        decls = program_node.statements.select { |s| s.is_a?(AST::SyncPolicyDecl) }

        if decls.size > 1
          error!(decls[1], :SYNC_POLICY_DUPLICATE)
        end

        if decls.empty?
          program_node.sync_policy = baked_in_default_sync_policy
          return
        end

        decl = T.cast(T.must(decls.first), AST::SyncPolicyDecl)
        has_main = program_node.statements.any? { |s|
          s.is_a?(AST::FunctionDef) && s.name == Compiler::Entrypoint::NAME
        }
        unless has_main
          error!(decl, :SYNC_POLICY_NEEDS_MAIN_FILE)
        end

        validate_sync_policy_body!(decl)
        program_node.sync_policy = decl.handlers
        stamp_type!(decl, :Void)
      end

      # Per-handler-block validation: every selector must name a type the
      # SYNC POLICY is allowed to handle (LockTimeout, MvccConflict,
      # AtomicConflict); Deadlock / LockCycle are explicitly forbidden;
      # the union of named errors must cover the required set exactly.
      sig { params(decl: AST::SyncPolicyDecl).void }
      def validate_sync_policy_body!(decl)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        seen = []
        (decl.handlers || []).each do |clause|
          clause.selectors.each do |sel|
            next unless sel.form == :type
            name = sel.name
            if SYNC_POLICY_INLINE_ONLY_ERRORS.include?(name)
              error!(sel.token || decl, :SYNC_POLICY_INLINE_ONLY,
                name: name, escape: (name == :Deadlock ? "DEADLOCK" : "LOCK_CYCLE"))
            end
            unless SYNC_POLICY_REQUIRED_ERRORS.include?(name)
              error!(sel.token || decl, :SYNC_POLICY_INVALID_ERROR,
                name: name, required: SYNC_POLICY_REQUIRED_ERRORS.join(', '))
            end
            seen << name
          end
          # Kind selectors (e.g. `ON Transient ...`) inside SYNC POLICY are
          # not supported -- the policy must name each error explicitly so
          # completeness is checkable. Sugar like `RETRY(N) THEN <action>`
          # desugars to `ON Transient ...` at parse time, which would land
          # here with form==:kind.
          clause.selectors.each do |sel|
            next unless sel.form == :kind
            error!(sel.token || decl, :SYNC_POLICY_NEEDS_TYPE_NOT_KIND, name: sel.name)
          end
        end

        seen_set = seen.to_set
        missing = SYNC_POLICY_REQUIRED_ERRORS.reject { |e| seen_set.include?(e) }
        unless missing.empty?
          error!(decl, :SYNC_POLICY_INCOMPLETE,
            required: SYNC_POLICY_REQUIRED_ERRORS.join(', '), missing: missing.join(', '))
        end
      end

      # Project a callee's full !T error union down to only the errors this
      # call site can surface. Forwarded polymorphic args keep the caller's
      # narrower family constraint instead of widening to the callee's full
      # REQUIRES set.
      sig { params(sig: FunctionSignature, args: T::Array[AST::Node]).returns(T::Set[Symbol]) }
      def collapse_errors_for_call(sig, args)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        require_relative 'helpers/with_match_check' unless defined?(WithMatchCheck)
        collapsed = Set.new
        param_indices = sig.params.each_with_index.to_h { |param, index| [param.name.to_s, index] }
        sig.requires.each do |param_name, _families|
          idx = param_indices[param_name.to_s]
          next unless idx
          arg = args[idx]
          next unless arg
          families = WithMatchCheck.family_of_arg_set(arg)
          next if families.nil? || families.empty?
          families.each do |fam|
            axes = WithMatchCheck::FAMILY_AXES[fam] || Set.new
            axes.each do |axis|
              (WithMatchCheck::AXIS_ERRORS[axis] || Set.new).each { |e| collapsed << e }
            end
          end
        end
        collapsed
      end

      # Synthesize the same clause shape as a per-WITH handler so emission can
      # use one path. Inline-only errors intentionally have no policy fallback.
      sig { params(error_name: Symbol).returns(T.nilable(AST::ErrorClause)) }
      def synthesize_clause_from_policy(error_name)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        handlers = semantic_program.sync_policy
        return nil unless handlers
        handlers.find { |h|
          h.selectors.any? { |s| s.form == :type && s.name == error_name }
        }
      end

      # SyncPolicyDecl is validated up front. This visitor keeps the AST walker
      # explicit and visits block-action handler bodies so their types are annotated.
      sig { params(node: AST::SyncPolicyDecl).void }
      def visit_SyncPolicyDecl(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        (node.handlers || []).each do |clause|
          case clause.action
          when AST::ErrorActionKind::Exit
            visit(T.must(clause.message))
          when AST::ErrorActionKind::Block
            visit_stmts(clause.body)
          end
        end
        stamp_type!(node, :Void)
      end

      # Resolve a parsed CATCH clause into its runtime-dispatch form.
      # The parser produces:
      #   { items:   [{ form: :kind|:type, name:, token: }, ...],
      #     filters: [{ form: :type|:message, value:, token: }, ...],
      #     body:    [...] }
      # After this method, the clause carries four lowering-ready fields:
      #   clause[:kinds]            = [Symbol, ...] — kinds from items
      #   clause[:types]            = [String, ...] — types from items
      #   clause[:filter_types]     = [String, ...] — types from WITH
      #   clause[:filter_messages]  = [AST node, ...] — messages from WITH
      # Match semantics: (any kind matches OR any type matches) AND
      #   (filters empty OR any filter_type matches OR any filter_message
      #    matches). No cross-constraint between items and filters — a
      #   mixed `CATCH Kind, Type` simply ORs the two checks.
      sig { params(clause: AST::CatchClause).void }
      def resolve_catch_clause!(clause)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        kinds = []
        types = []
        clause.items.each do |item|
          if item.form == :kind
            kind_sym = item.name.to_sym
            unless AST.error_kind?(kind_sym)
              emit_registry_mismatch!(
                item.token, item.name, AST::ERROR_KINDS,
                "Unknown error kind '#{item.name}'. Expected one of: #{AST::ERROR_KINDS.join(', ')}",
                "closest known kind"
              )
            end
            kinds << kind_sym if AST.error_kind?(kind_sym)
          else
            type_sym = item.name.to_sym
            unless AST.error_type?(type_sym)
              emit_registry_mismatch!(
                item.token, item.name, AST::ERROR_TYPES.keys,
                "CATCH #{item.name}: error type '#{item.name}' is not registered. A type " \
                "must be registered via RAISE/OR_ELSE EXIT before it can be CATCHed.",
                "closest registered type"
              )
            end
            types << item.name if AST.error_type?(type_sym)
          end
        end
        clause.kinds = kinds.uniq
        clause.types = types.uniq

        filter_types    = []
        filter_messages = []
        clause.filters.each do |f|
          case f.form
          when :type
            type_sym = T.cast(f.value, String).to_sym
            unless AST.error_type?(type_sym)
              error!(f.token, :CATCH_WITH_UNREGISTERED, name: f.value)
            end
            filter_types << T.cast(f.value, String)
          when :message
            # value is the parsed STRING expression. Visit so the string
            # literal gets its Type stamped for downstream lowering.
            message_expr = T.cast(f.value, AST::Locatable)
            visit(message_expr)
            filter_messages << message_expr
          end
        end
        clause.filter_types    = filter_types.uniq
        clause.filter_messages = filter_messages
      end

      # ==========================================
      # CONTROL FLOW
      # ==========================================
      # Unifies logic for analyzing multiple code paths (branches).
      # Snapshots initial variable states, executes each branch in a clean scope,
      # and merges states back to the parent scope.
      #
      # @param branches [Array<Proc>] Procs that execute branch logic
      # @return [Array<Array<Hash>>] Array of drops for each branch
      sig { params(node: AST::Assert).returns(T.nilable(Symbol)) }
      def visit_Assert(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        visit(node.condition)
        if node.condition.resolved_type != :Bool
           error!(node, :ASSERT_NEEDS_BOOL)
        end
        # Optional: check message type if it exists
        stamp_type!(node, :Void)
      end

      # Test-grammar visitors (visit_TestBlock, visit_WhenBlock,
      # visit_TestThat, visit_AssertRaises, visit_BenchmarkStmt,
      # visit_SmashStmt, visit_ProfileStmt, visit_StubDecl) are mixed in
      # from annotator/helpers/test_annotation.rb.

      sig { params(node: AST::DieNode).returns(Symbol) }
      def visit_DieNode(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

         # Usually takes an integer status code
         visit(node.status) if node.status
         stamp_type!(node, :NoReturn) # Special type indicating execution stops
      end

      sig { params(node: AST::Raise).returns(T.nilable(T::Boolean)) }
      def visit_Raise(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        visit(node.message_expr) if node.message_expr
        resolve_error_registration!(node, node.kind, node.error_name, node.token)
        current_fn_ctx&.mark_runtime_used!
        stamp_type!(node, :NoReturn) # Raises propagate up or are caught
        phase_traversal_state.branch_terminated = true
      end

      # Unified registration for RAISE / OR_ELSE EXIT / EXIT sites that name an
      # error type. Rules:
      #   - kind given + type given  : register or verify (kind, type).
      #   - kind nil   + type given  : type MUST already be registered;
      #                                node.kind is backfilled to the
      #                                registered kind.
      #   - kind given + type nil    : no-op (no type to register).
      #   - kind nil   + type nil    : no-op (legacy message-only form).
      # On collision, emits a diagnostic anchored at the second site,
      # naming the first registration line for context.
      sig { params(node: T.any(AST::Raise, AST::OrElseExit), kind_sym: T.nilable(Symbol), type_name_str: T.nilable(String), site_tok: Lexer::Token).returns(NilClass) }
      def resolve_error_registration!(node, kind_sym, type_name_str, site_tok)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return if type_name_str.nil?
        type_sym = type_name_str.to_sym

        if kind_sym.nil?
          # Type-only form — require prior registration.
          unless AST.error_type?(type_sym)
            error!(site_tok || node, :ERROR_TYPE_NOT_REGISTERED, name: type_name_str)
            return
          end
          # Backfill the node with the registered kind so downstream
          # passes (mir-lowering) can emit rt.setError(.Kind, ...).
          node.kind = AST.kind_of_type(type_sym)
          return
        end

        # Kind + type: first use registers, subsequent verifies.
        _, conflict = AST.register_type!(type_sym, kind_sym, site_token: site_tok)
        emit_error_type_conflict!(site_tok || node, type_name_str, conflict) if conflict
        nil
      end

      sig { params(site: T.any(AST::Locatable, Lexer::Token), type_name: String, conflict: AST::ErrorTypeConflict).void }
      def emit_error_type_conflict!(site, type_name, conflict)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        first_site = T.cast(conflict[:first_site], T.nilable(Lexer::Token))
        first_loc = first_site ? " (first registered at line #{first_site.line})" : ""
        if conflict[:is_stdlib] == true
          error!(site, :ERROR_TYPE_RESERVED_BY_STDLIB,
                 name: type_name, kind: T.cast(conflict[:existing_kind], Symbol))
        else
          error!(site, :ERROR_TYPE_KIND_CONFLICT,
                 name: type_name, kind: T.cast(conflict[:existing_kind], Symbol), first_loc: first_loc)
        end
      end

      # ==========================================
      # VARIABLES & DEPENDENCIES
      # ==========================================

      sig { params(node: AST::ReturnNode).returns(T.nilable(T::Boolean)) }
      def visit_ReturnNode(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        # Handle optional return node for Void functions.
        fn_ctx = current_fn_ctx!
        expected = fn_ctx.return_type
        raw_value = node.value
        if raw_value.nil?
          # If the function expects a value but we return nothing -> ERROR.
          # `!Void` (error union over Void) accepts a plain `RETURN;` because
          # the success arm is Void; the wrap is implicit at lowering time.
          expected_void_compatible = expected == :Void || expected == :Any ||
                                     (expected.respond_to?(:error_union?) && expected.error_union? &&
                                      expected.respond_to?(:payload_type) &&
                                      (expected.payload_type == :Void || expected.payload_type.nil?))
          unless expected_void_compatible
            error!(node, :RETURN_VOID_FROM_TYPED, expected: expected)
          end

          stamp_type!(node, :Void)
          phase_traversal_state.branch_terminated = true
          return # Stop here, nothing else to analyze
        end

        value = T.must(raw_value)
        return_payload = expected.plain_return_payload_type || expected
        if value.is_a?(AST::BgBlock) && return_payload.single_future?
          T.unsafe(value).declared_async_payload = Type.new(return_payload.tense_type)
        end
        if value.is_a?(AST::ListLit) && (return_payload.collection? || return_payload.tuple?)
          value.coerced_type = return_payload
        elsif value.is_a?(AST::HashLit) && return_payload.map?
          value.coerced_type = return_payload
        end
        visit(value)

        # Inline BG return: `RETURN BG { ... }`, plus composite returns such
        # as `RETURN Holder{ bg: BG { ... } }`. There is no decl_node for
        # `stamp_bg_handle_lifetime!` to fire on, so run the same source walk
        # inline. If any contained BG captures a scope-bounded source, the
        # returned value cannot outlive those captures.
        inline_bg_sources = collect_bg_sources_in_expr(value).uniq
        if inline_bg_sources.any?
          error!(node, :RETURN_BORROWED_NO_COPY_OR_LIFETIME,
            type: value.full_type!(context: "inline BG return").to_s)
        end

        # RETURN inside a WITH block is forbidden ONLY when the returned value
        # carries a borrow of the WITH alias (the `AS` binding). Pure values
        # — primitives, fresh values returned by methods on the alias (e.g.
        # `p.insert(...)` returning a fresh Id<T>) — escape safely. The
        # SymbolEntry#non_escaping flag is set on every WITH alias by
        # declare_capability_scope!; it's the same flag ensure_owned_value!
        # already uses to prevent storing WITH-scoped values in containers.
        if inside_with_block?
          if value.is_a?(AST::Identifier) && value.symbol&.non_escaping
            error!(node, :RETURN_FROM_WITH_SCOPED,
              name: value.name)
          elsif value.is_a?(AST::GetField) && value.target.respond_to?(:symbol) && value.target.symbol&.non_escaping
            returned_type = value.full_type!(context: "WITH-scoped field return")
            unless returned_type.implicitly_copyable? { |type| lookup_type_schema(type) }
              error!(node, :RETURN_FIELD_FROM_WITH_SCOPED)
            end
          elsif value.is_a?(AST::GetIndex) && value.target.respond_to?(:symbol) && value.target.symbol&.non_escaping
            returned_type = value.full_type!(context: "WITH-scoped indexed return")
            unless returned_type.implicitly_copyable? { |type| lookup_type_schema(type) }
              error!(node, :RETURN_INDEX_FROM_WITH_SCOPED)
            end
          end
        end
        promote_to_expr_if!(node, value) if value.is_a?(AST::IfStatement)
        promote_to_expr_match!(node, value) if value.is_a?(AST::MatchStatement)

        verify_return(value)
        verify_tied_return!(node)

        actual = value.resolved_type
        actual_full = return_value_type(value)

        if value.is_a?(AST::Identifier)
          vti = value.full_type!(context: "return identifier")
          if vti && !vti.implicitly_copyable? { |t| lookup_type_schema(t) }
            value.was_moved = true
          end
          # Returning a future consumes the promise; otherwise scope finalization
          # reports it as unconsumed before return-lifetime checks can run.
          vt = vti.is_a?(Type) ? vti : (vti ? Type.new(vti) : nil)
          if vt&.future?
            og_set_moved(value.name, at_token: value.token, action: :return)
          end
        end

        # RETURN COPY expr or RETURN Struct{ field: COPY ... }: the COPY heap-dupes,
        # so the caller receives heap-allocated data.

        # Promote non-identifier literals to heap when the expected return type requires it.
        unless value.is_a?(AST::Identifier)
          if expected.heap_return_storage? &&
             value.respond_to?(:storage=) &&
             value.full_type!(context: "return expression storage").requires_move?
            value.storage = :heap
          end
        end

        # Auto returns are resolved after the body walk, so strict equality here
        # would reject valid programs before the unifier has run.
        actual_is_auto = actual_full.auto?
        expected_is_auto = expected.auto?

        return_checkable = !actual_is_auto && !expected_is_auto && expected != :Void && expected != :Any
        if return_checkable && !return_type_compatible?(actual_full, expected)
          error!(node, :RETURN_MISMATCH, expected: type_display(expected), got: type_display(actual_full))
        elsif return_checkable && actual != expected
          # A value's coercion target is the PAYLOAD, never the error union
          # `!T`. `!` is the channel (added by the return mechanism / fn
          # signature), orthogonal to the value's type. Stamping `!T` here
          # makes lower() emit `@as(anyerror!T, value)`, whose address
          # (`&__tmp`) is `*const anyerror!T` and fails the @list
          # cleanup/return cast (puck-clear-bugs.md #10). A genuinely
          # fallible value (auto-propagate-stripped call: `!T` stashed on
          # error_union_type) keeps the channel target so return-lowering
          # still emits the propagating `try`. Caller-side cleanup of the
          # returned collection is handled by the uniform alloc-fault
          # pipeline (steps 3-4), so unlike the earlier standalone attempt
          # this no longer leaks (#13) and does not need E1 broadening
          # (no 527 double-free). (`expected` is always a Type on master --
          # the FunctionSignature seam coerces nil -> Void.)
          value_is_fallible = !recoverable_result_type(value, context: "return value").nil? ||
            actual_full.error_union?
          coerce_target =
            if !value_is_fallible && expected.plain_return_payload_type
              expected.plain_return_payload_type
            else
              expected
            end
          value.coerced_type = coerce_target  # Don't coerce EXPLICIT returns
          check_prefixed_int_range!(value, coerce_target)
        end

        stamp_type!(node, actual)
        return_fact_type = T.let(value.coerced_type_info || actual_full, Type)

        fn_ctx.returns << AST::ReturnFact.new(
          storage: T.cast(value.storage, T.nilable(Symbol)),
          type: Type.coercion_surface_name(return_fact_type).to_sym,
          metatype: T.cast(value.metatype, T.nilable(Symbol)),
        )

        phase_traversal_state.branch_terminated = true
      end

      sig { params(value: AST::Locatable).returns(Type) }
      def return_value_type(value)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        value.full_type!(context: "return value")
      end

      sig { params(actual_type: Type, expected_type: Type).returns(T::Boolean) }
      def return_type_compatible?(actual_type, expected_type)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return true if expected_type.any? || actual_type.any?
        return true if actual_type.resolved == :NoReturn
        return expected_type.accepts?(actual_type) if expected_type.fn_type?
        return true if expected_type.optional? && actual_type.resolved == :NIL
        return true if union_payload_variant(expected_type, actual_type)
        return false unless same_return_capabilities?(expected_type, actual_type)

        is_safe_autocast?(actual_type, expected_type)
      end
      private :return_type_compatible?

      sig { params(expected_type: Type, actual_type: Type).returns(T.nilable(T.any(String, Symbol))) }
      def union_payload_variant(expected_type, actual_type)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        target_type = expected_type.value_payload_type
        schema = lookup_type_schema(target_type.resolved)
        UnionPayloadCompatibility.unique_variant(expected_type, actual_type, schema)
      end
      private :union_payload_variant

      sig { params(expected_t: Type, actual_t: Type).returns(T::Boolean) }
      def same_return_capabilities?(expected_t, actual_t)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        name = expected_t.resolved.to_s
        if name.match?(/\A[A-Z]\z/) && !lookup_type_schema(name.to_sym) &&
           expected_t.polymorphic_shared? && actual_t.shared? &&
           expected_t.sync.nil? && expected_t.resolved == actual_t.resolved
          return true
        end
        # @boxed on a return type is a storage directive: the value is
        # heap-boxed into a `*T` cell at the RETURN site (escape analysis),
        # so the returned expression need not already carry :indirect.
        layout_ok = expected_t.layout == actual_t.layout || expected_t.indirect?
        expected_t.ownership == actual_t.ownership &&
          expected_t.sync == actual_t.sync &&
          layout_ok &&
          expected_t.elem_ownership == actual_t.elem_ownership &&
          expected_t.elem_sync == actual_t.elem_sync
      end

      sig { params(type: Type).returns(String) }
      def type_display(type)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        parts = [type.resolved.to_s]

        ownership = type.ownership_surface_name
        sync = type.sync_surface_name
        parts << ownership if ownership
        parts << sync if sync

        parts.join(" ")
      end

      # =========================================================
      # OR_ELSE / RESCUE
      # =========================================================
      sig { params(node: AST::BinaryOp).returns(Type) }
      def visit_OrElse(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        # Logic: val OR_ELSE default
        rhs_propagates =
          node.right.is_a?(AST::OrElseRaise) ||
          node.right.is_a?(AST::OrElseExit) ||
          node.right.is_a?(AST::ThrowNode) ||
          node.right.is_a?(AST::ReturnNode)
        with_body_fact_failure_absorbed(!rhs_propagates) do
          visit(node.left)
        end
        visit(node.right)

        t_right_type = node.right.full_type!(context: "OR_ELSE right")

        # Calls retain an explicit `error_union_type` after their success
        # payload is stamped. Recoverability is a source-level fact, not the
        # broad `can_fail` effect (which also includes allocations).
        # Bare NIL gets its optional payload from the fallback. This context
        # has to be applied at the OR_ELSE boundary: visiting NIL alone can
        # only stamp the sentinel :NIL type, and rejecting that sentinel here
        # breaks nested/contextual forms such as `NIL OR_ELSE value`.
        bare_nil = node.left.is_a?(AST::Literal) && node.left.type == :NIL
        t_left_type = if bare_nil && t_right_type.resolved != :NoReturn
          contextual = Type.optional_of(t_right_type)
          stamp_type!(node.left, contextual)
          contextual
        else
          recoverable_result_type(node.left, context: "OR_ELSE left")
        end
        unless t_left_type
          left_value_type = Type.new(node.left.full_type!(context: "OR_ELSE left"))
          if fault_recoverable_result?(node.left)
            t_left_type = Type.error_union_of(left_value_type)
            # A pipeline inside CATCH normally exposes only its success value;
            # the function-level CATCH owns the implicit failure edge.  At an
            # explicit OR_ELSE boundary, restore the error channel on this AST
            # site so MIR emits `catch` instead of treating the fallback as
            # unreachable.
            if node.left.is_a?(AST::BinaryOp) && node.left.smooth? &&
               node.left.respond_to?(:error_union_type=)
              node.left.error_union_type = t_left_type
            end
          elsif left_value_type.optional?
            # Optional return values are already explicit recovery values.
            # Do not defer them as if they were definite user-function
            # results whose allocation effects might later become fallible.
            t_left_type = left_value_type
          elsif node.left.is_a?(AST::FuncCall) && function_node_map.key?(node.left.name)
            record_deferred_recovery_validation!(node, node.left, node.left.name, left_value_type)
            t_left_type = Type.error_union_of(left_value_type)
          else
            t_left_type = left_value_type
          end
        end
        # Validate before handling special recovery forms as well. Otherwise
        # `definite() OR_ELSE RAISE` would silently bypass the ordinary
        # fallback check merely because its right side returns early below.
        unless t_left_type.error_union? || t_left_type.optional?
          error!(node, :OR_ELSE_NEEDS_RECOVERABLE_LEFT, got: type_display(t_left_type))
        end

        if node.right.is_a?(AST::OrElseBreak)
          if current_loop_depth <= 0
            error!(node, :OR_BREAK_OUTSIDE_WHILE)
          end
        end

        operation, recovery = or_else_operation(node.right)
        begin
          plan = TenseOperationPlanner.or_else(
            t_left_type,
            t_right_type,
            operation: operation,
            recovery: recovery,
          )
        rescue ArgumentError
          expected = t_left_type.value_payload_type
          error!(node, :TYPE_MISMATCH_IN_OR, expected: expected.resolved, got: t_right_type.resolved)
          # Fix-collection mode records the diagnostic and continues. Publish
          # the plan the corrected fallback would use so later phases never
          # need a nullable compatibility path.
          plan = TenseOperationPlanner.or_else(
            t_left_type,
            expected,
            operation: operation,
            recovery: recovery,
          )
        end
        plan = T.must(plan)
        node.tense_plan = plan
        coerce_empty_collection_fallback!(node.right, plan.result_type) if recovery == TenseRecovery::Fallback
        stamp_type!(node, plan.result_type)
      end

      sig { params(node: AST::Node).returns([TenseOperationKind, TenseRecovery]) }
      def or_else_operation(node)
        case node
        when AST::OrElseRaise then [TenseOperationKind::OrElseRaise, TenseRecovery::Raise]
        when AST::OrElseExit then [TenseOperationKind::OrElseExit, TenseRecovery::Exit]
        when AST::OrElsePass then [TenseOperationKind::OrElsePass, TenseRecovery::Pass]
        when AST::OrElseBreak then [TenseOperationKind::OrElseBreak, TenseRecovery::Break]
        when AST::OrElsePrune then [TenseOperationKind::OrElsePrune, TenseRecovery::Prune]
        else [TenseOperationKind::OrElseValue, TenseRecovery::Fallback]
        end
      end
      private :or_else_operation

      # An empty collection fallback (`expr OR []` / `OR {}`) is visited
      # with no expected-type context, so visit_ListLit types it `Any[]`
      # and the transpiler defaults its element type (f64). Push the OR
      # success type onto the empty literal -- the same expected-type
      # propagation VarDecl does for `MUTABLE v: T[]@list = []`.
      sig { params(rhs: AST::Node, expected: T.nilable(Type)).void }
      def coerce_empty_collection_fallback!(rhs, expected)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        return unless expected.is_a?(Type)
        empty_list = rhs.is_a?(AST::ListLit) && rhs.items.empty? &&
                     !rhs.collection_constructor?
        empty_hash = rhs.is_a?(AST::HashLit) && rhs.pairs.empty?
        return unless empty_list || empty_hash
        stamp_type!(rhs, expected)
      end

      sig { params(node: AST::OrElseRaise).returns(Symbol) }
      def visit_OrElseRaise(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::OrElseBreak).returns(Symbol) }
      def visit_OrElseBreak(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::OrElsePass).returns(Symbol) }
      def visit_OrElsePass(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        # This is a marker node for OR_ELSE PASS - no type annotation needed
        # The actual type handling is done in visit_OrElse
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::OrElsePrune).returns(Symbol) }
      def visit_OrElsePrune(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        # This is a marker node for OR_ELSE PRUNE - no type annotation needed
        # The actual type handling is done in visit_OrElse
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::OrElseExit).returns(T.nilable(Symbol)) }
      def visit_OrElseExit(node)
        T.bind(self, Annotator::Phases::TypeAnalysisSession)

        visit(node.message) if node.message
        resolve_error_registration!(node, node.kind, node.error_name, node.token)
        current_fn_ctx&.mark_runtime_used!
        stamp_type!(node, :Void)
      end
      private :baked_in_default_sync_policy
  private :coerce_empty_collection_fallback!
  private :emit_error_type_conflict!
  private :resolve_catch_clause!
  private :resolve_error_registration!
  private :return_value_type
  private :same_return_capabilities?
  private :type_display
  private :validate_sync_policy_body!

end
  end
end
