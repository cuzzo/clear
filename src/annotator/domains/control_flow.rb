# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module ControlFlow
      extend T::Sig

      sig { params(branches: T::Array[Proc], merge_to_parent: T::Boolean).returns(T.nilable(T::Array[T::Array[T::Hash[Symbol, T.untyped]]])) }
      def analyze_control_flow_branches(branches, merge_to_parent: true)
        T.bind(self, SemanticAnnotator)

        og_snapshot = @og&.fork_lightweight
        og_branch_snapshots = []
        branch_terminates = []
        all_drops = []

        branches.each do |branch_logic|
          # Restore graph to pre-branch state before analyzing each branch
          @og&.restore_lightweight(og_snapshot) if og_snapshot
          prev_terminated = @branch_terminated
          @branch_terminated = false
          with_new_scope(current_scope) do
            og_push_scope
            all_drops << branch_logic.call
            og_branch_snapshots << (@og&.fork_lightweight)
            branch_terminates << @branch_terminated
            og_pop_scope
          end
          @branch_terminated = prev_terminated
        end

        if merge_to_parent
          # Restore to base, then merge only non-terminating branch results.
          # A terminating branch (RETURN/RAISE) cannot reach the merge point, so
          # its moved states must not poison the post-branch scope.
          @og&.restore_lightweight(og_snapshot) if og_snapshot
          og_branch_snapshots.each_with_index do |snap, i|
            next if branch_terminates[i]
            next unless snap
            # Lightweight merge: just apply moved states
            snap[:node_states].each do |path, saved|
              state = saved.is_a?(Hash) ? saved[:state] : saved
              node = @og.nodes[path]
              next unless node
              if node.state != state
                if state == :moved
                  node.state = :moved
                  if saved.is_a?(Hash)
                    node.move_line = saved[:move_line]
                    node.move_col = saved[:move_col]
                    node.move_action = saved[:move_action]
                  end
                end
              end
            end
          end
        else
          @og&.restore_lightweight(og_snapshot) if og_snapshot
        end

        all_drops
      end

      sig { params(node: AST::BlockExpr).returns(T.nilable(Scope)) }
      def visit_BlockExpr(node)
        T.bind(self, SemanticAnnotator)

        with_new_scope(current_scope) do
          node.body.each { |stmt| visit(stmt) }
          visit(node.result)
          stamp_type!(node, node.result.full_type!(context: "catch branch result"))
          node.storage   = node.result.storage
        end
        nil
      end

      sig { params(node: AST::IfStatement).returns(T.nilable(Symbol)) }
      def visit_IfStatement(node)
        T.bind(self, SemanticAnnotator)

        visit(node.condition)

        branch_logic = [
          proc {
            with_conditional_context { visit_stmts(node.then_branch) }
            finalize_scope(node, branch: :then)
            node.then_drops
          },
          proc {
            with_conditional_context { visit_stmts(node.else_branch) }
            finalize_scope(node, branch: :else)
            node.else_drops
          }
        ]

        analyze_control_flow_branches(branch_logic)

        # Store branch result types so use sites can promote to expression mode.
        node.then_result_type = expr_result_type(node.then_branch)
        node.else_result_type = expr_result_type(node.else_branch)

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::IfBind).returns(Symbol) }
      def visit_IfBind(node)
        T.bind(self, SemanticAnnotator)

        # Visit and validate each binding expression.
        node.bindings.each do |b|
          visit(b.expr)
          ti = b.expr.full_type!(context: "IF AS binding expression")
          unless ti.optional?
            error!(b.expr, :IF_AS_NEEDS_OPTIONAL, got: b.expr.resolved_type)
          end
          # Annotate each binding with the unwrapped type for use in lowering.
          unwrapped = ti.wrapped_type
          # RESOLVE returns ?T@multiowned/shared where the caller owns the strong ref.
          # Propagate ownership so field access auto-derefs through .ctrl.data and
          # the lowering knows to inject rcRelease cleanup.
          if b.expr.is_a?(AST::ResolveNode) && (ti.multiowned? || ti.shared?)
            unwrapped.apply_reference_ownership!(ti.ownership, link_source: ti.link_source)
          end
          b.unwrapped_type = unwrapped
        end

        branch_logic = [
          proc {
            # Declare each binding in the then-scope with the unwrapped type.
            node.bindings.each do |b|
              unwrapped = b.unwrapped_type  # always a Type (never nil)
              sym = unwrapped.resolved
              current_scope.declare(b.name, nil, unwrapped, false, false, nil, :stack)
              entry = current_scope.locals[b.name]
              b.symbol = entry
              # Propagate non_escaping when the source is borrow-derived from a
              # non_escaping binding (a WITH alias or another transitive borrow
              # of one). IF-AS on `p[i]` / `p.field` where `p` is the alias
              # makes the new binding a borrow into locked data; it must not
              # escape the enclosing WITH scope either.
              if (src_sym = AST.root_identifier(b.expr)&.symbol)
                entry.mark_non_escaping! if src_sym.non_escaping
                entry.lifetime = SymbolEntry.tied_lifetime([src_sym]) if find_container_source(b.expr)
              end
              classify_ownership!(entry)
              og_declare(b.name.to_s, nil, unwrapped)
            end
            visit_stmts(node.then_branch)
            nil
          },
          proc {
            visit_stmts(node.else_branch)
            nil
          }
        ]

        analyze_control_flow_branches(branch_logic)
        stamp_type!(node, :Void)
      end

      # Type-checks a struct destructuring pattern against the match subject type.
      # Verifies field names exist and value types match the struct schema.

      sig { params(match_node: AST::MatchStatement, pat: AST::StructPattern).returns(T.nilable(T::Array[T::Hash[T.untyped, T.untyped]])) }
      def annotate_struct_pattern!(match_node, pat)
        T.bind(self, SemanticAnnotator)

        expr_type = match_node.expr.resolved_type
        primitives = [:Float64, :Bool, :Byte, :Int64, :Float64, :String, :NIL, :BOOLEAN, :Any, :Void]

        if primitives.include?(expr_type)
          error!(match_node, :MATCH_NEEDS_STRUCT_TYPE, got: expr_type)
        end

        schema = lookup_type_schema(expr_type)

        pat.fields.each do |f|
          next if f.wildcard?

          if schema
            unless schema.fields.key?(f.name)
              name_tok = f.name_token
              if name_tok
                valid_fields = schema.fields.keys.reject { |k| k.to_s.start_with?("_") }
                emit_typo_suggestion!(
                  name_tok, f.name, valid_fields,
                  "MATCH struct pattern: field '#{f.name}' does not exist on type #{expr_type}",
                  "field of #{expr_type}",
                  category: :type, cascade: true
                )
              else
                error!(match_node, :MATCH_FIELD_UNKNOWN, field: f.name, type: expr_type)
              end
            end
          end

          if f.bind?
            # Destructuring bind: declare a local variable with the field's type.
            if schema && schema.fields.key?(f.name)
              field_def = schema.fields[f.name]
              field_type = field_def.is_a?(AST::StructField) ? field_def.type : field_def
              field_type = field_type.is_a?(Type) ? field_type : Type.new(field_type)
              current_scope.declare(f.name, nil, field_type, false, false, nil, :stack)
              og_declare(f.name, nil, field_type)
            end
          else
            visit(f.expr)

            if schema
              field_def = schema.fields[f.name]
              ft = field_def&.type
              field_type = ft.is_a?(Type) ? ft.resolved : ft
              val_type   = f.expr.resolved_type
              is_numeric_promo = (val_type == :Int64 && (field_type == :Float64 || field_type == :Float64))
              unless val_type == field_type || val_type == :Any || field_type == :Any || is_numeric_promo
                error!(match_node, :MATCH_FIELD_TYPE_MISMATCH, field: f.name, declared: field_type, got: val_type)
              end
            end
          end
        end

        # A destructuring pattern's type IS the subject it destructures
        # (the MATCH expr) — not a guess.
        stamp_type!(pat, match_node.expr.full_type!(context: "match destructure subject"))
        nil # sig: returns(T.nilable(T::Array[...])) — don't leak the Type
      end

      sig { params(pattern: T.untyped).returns(T.untyped) }
      def match_variant_name(pattern)
        T.bind(self, SemanticAnnotator)

        case pattern
        when AST::GetField   then pattern.field
        when AST::MethodCall then pattern.name
        end
      end

      sig { params(arm: T.untyped).returns(T::Array[T.untyped]) }
      def match_variant_names(arm)
        T.bind(self, SemanticAnnotator)

        [arm.value, *(arm.extra_values || [])].filter_map { |pattern| match_variant_name(pattern) }
      end

      sig { params(payload: T.untyped, union_subst: T::Hash[Symbol, Symbol]).returns(T.untyped) }
      def normalized_match_payload(payload, union_subst)
        T.bind(self, SemanticAnnotator)

        return apply_type_subst(payload, union_subst).resolved if payload.is_a?(Type)
        return union_subst.fetch(payload, payload) if payload.is_a?(Symbol)

        payload
      end

      sig do
        params(
          node: AST::MatchStatement,
          arm: T.untyped,
          schema: T.untyped,
          variant_name: T.untyped,
          union_subst: T::Hash[Symbol, T.untyped],
          kind: String,
          name: String
        ).void
      end
      def verify_match_multi_arm_payloads!(node, arm, schema, variant_name, union_subst, kind:, name:)
        T.bind(self, SemanticAnnotator)

        return unless variant_name

        head_payload = normalized_match_payload(schema.variants[variant_name], union_subst)
        match_variant_names(arm).drop(1).each do |extra_name|
          extra_payload = normalized_match_payload(schema.variants[extra_name], union_subst)
          next if head_payload == extra_payload

          error!(node, :MATCH_MULTI_ARM_PAYLOAD_MISMATCH,
            head: variant_name, other: extra_name, kind: kind, name: name)
        end
      end

      sig { params(node: AST::StructLit, schema: T.untyped).returns(T::Hash[Symbol, Symbol]) }
      def literal_type_substitution!(node, schema)
        T.bind(self, SemanticAnnotator)

        type_params = schema.type_params
        subst = {}
        if node.type_args&.any?
          if type_params.nil? || type_params.empty?
            error!(node, :GENERIC_NOT_GENERIC, type: node.name)
          end
          if node.type_args.length != type_params.length
            error!(node, :GENERIC_WRONG_ARG_COUNT, type: node.name, expected: type_params.length, got: node.type_args.length)
          end
          type_params.zip(node.type_args).each { |param, arg| subst[param] = arg.to_sym }
        elsif type_params&.any?
          params_hint = type_params.map(&:to_s).join(', ')
          error!(node, :GENERIC_MISSING_TYPE_ARGS, type: node.name, type2: node.name, hint: params_hint)
        end
        subst
      end

      sig { params(node: AST::StructLit).returns(Symbol) }
      def literal_instance_type(node)
        T.bind(self, SemanticAnnotator)

        if node.type_args&.any?
          :"#{node.name}<#{node.type_args.join(',')}>"
        else
          node.name.to_sym
        end
      end

      sig { params(node: AST::PassStmt).returns(Symbol) }
      def visit_PassStmt(node)
        T.bind(self, SemanticAnnotator)

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::MatchStatement).returns(T.nilable(Symbol)) }
      def visit_MatchStatement(node)
        T.bind(self, SemanticAnnotator)

        visit(node.expr)

        # Determine whether the subject is an enum or union for exhaustiveness / payload capture
        expr_t    = Type.new(node.expr.resolved_type || :Any)
        node.string_match = true if expr_t.string?
        type_name = expr_t.generic_instance? ? expr_t.generic_base : expr_t.resolved
        schema    = lookup_type_schema(type_name)
        is_enum   = Schemas.enum?(schema)
        is_union  = Schemas.union?(schema)

        # Build type-param substitution for generic union payload capture
        # e.g. Option<Number> → { T: :Float64 }
        union_subst = {}
        if is_union && expr_t.generic_instance? && schema.type_params&.any?
          schema.type_params.zip(expr_t.generic_args).each { |p, a| union_subst[p] = a.resolved }
        end

        # MATCH TAKES is the only ownership-consuming match form. Plain MATCH and
        # PARTIAL MATCH borrow their subjects; they never infer ownership transfer.
        if node.takes && is_union && node.expr.is_a?(AST::Identifier)
          source_name = node.expr.name
          if @og[source_name] && @og[source_name].kind != :borrowed
            node.expr.was_moved = true
            og_set_moved(source_name, at_token: node.expr.token, action: :takes)
          end
        end

        branch_logic = node.cases.map do |c|
          proc {
            if c.kind == :when
              visit(c.value)
              unless c.value.resolved_type == :Bool
                error!(node, :WHEN_NEEDS_BOOL, got: c.value.resolved_type)
              end
            elsif c.kind == :struct_pattern
              annotate_struct_pattern!(node, c.value)
            else
              # Suppress inline-struct "needs braces" error: variant names in MATCH cases are
              # patterns (tag identifiers), not constructors — they don't need field values.
              with_match_pattern_context do
                visit(c.value)
                # Multi-pattern arm: visit + type-check each extra pattern
                # too. A `{ field }` destructure goes through the SAME
                # handler as a single :struct_pattern arm so it is typed
                # (and its binds declared), not just visited.
                c.extra_values&.each do |ev|
                  if ev.is_a?(AST::StructPattern)
                    annotate_struct_pattern!(node, ev)
                  else
                    visit(ev)
                  end
                end
              end
              expr_t2 = Type.new(node.expr.resolved_type || :Any)
              # Type-check the head pattern, then each extra. Patterns share
              # the arm's body so they must all have the same subject type.
              [c.value, *(c.extra_values || [])].each do |pat|
                case_t2 = Type.new(pat.resolved_type || :Any)
                base_match = expr_t2.generic_instance? && expr_t2.generic_base == pat.resolved_type
                string_match = expr_t2.string? && case_t2.string?
                unless pat.resolved_type == node.expr.resolved_type ||
                       node.expr.resolved_type == :Any ||
                       pat.resolved_type == :Any ||
                       base_match ||
                       string_match
                  error!(node, :MATCH_CASE_TYPE_MISMATCH, case: pat.resolved_type, expr: node.expr.resolved_type)
                end
              end
              case_t2 = Type.new(c.value.resolved_type || :Any)

              # Payload capture: `Shape.Circle AS r ->` (or multi-pattern
              # arm: `R.Ok, R.Other AS r ->`). For multi-arm bindings, every
              # variant in the arm must produce a payload of the SAME shape
              # (same payload type, or same inline-struct fields), since one
              # binding `r` is shared across all patterns in the body.
              if c.binding
                if is_enum
                  error!(node, :MATCH_ENUM_CAPTURE, binding: c.binding)
                elsif is_union
                  variant_name = match_variant_name(c.value)
                  # Verify each extra variant's payload matches the head's.
                  # Apply union_subst before comparing so generic instances
                  # (`Mixed<Int64>` where one variant is `T` and another is
                  # `Int64`) compare equal post-substitution. Variants are
                  # typically stored as Type instances; normalize through
                  # `.resolved` to produce a Symbol that can be compared.
                  verify_match_multi_arm_payloads!(node, c, schema, variant_name, union_subst, kind: 'AS', name: c.binding)
                  if variant_name
                    raw_payload = schema.variants[variant_name]
                    if raw_payload.nil?
                      error!(node, :MATCH_UNIT_CAPTURE, binding: c.binding, variant: variant_name)
                    elsif Schemas.inline_struct?(raw_payload)
                      synthetic_type = :"#{type_name}_#{variant_name}"
                      current_scope.declare(c.binding, nil, Type.new(synthetic_type), false, false, nil, :stack)
                      og_declare(c.binding, nil, Type.new(synthetic_type))
                      classify_ownership!(current_scope.locals[c.binding])
                    elsif raw_payload.is_a?(Type) && raw_payload.indirect?
                      # @indirect payload: bind to the dereferenced inner type (not the *T pointer).
                      inner_type = raw_payload.dup
                      inner_type.strip_layout!
                      inner_type = apply_type_subst(inner_type, union_subst)
                      current_scope.declare(c.binding, nil, inner_type, false, false, nil, :stack)
                      og_declare(c.binding, nil, inner_type)
                      classify_ownership!(current_scope.locals[c.binding])
                      c.indirect_payload_as = true  # transpiler must emit subject.Variant.* (deref *T)
                    else
                      payload_type = apply_type_subst(raw_payload, union_subst)
                      current_scope.declare(c.binding, nil, payload_type, false, false, nil, :stack)
                      og_declare(c.binding, nil, payload_type)
                      classify_ownership!(current_scope.locals[c.binding])
                    end
                    # MATCH AS: borrow view into the source union's payload.
                    # MATCH TAKES: owned extraction - source is consumed.
                    unless node.takes
                      @og[c.binding].kind = :borrowed
                      current_scope.locals[c.binding].storage = :borrow
                    end
                  end
                end
              end

              # Union variant destructuring: `Result.Ok{ value, count } ->`
              # Declares each named field as a local binding with the correct type.
              # For multi-arm `R.A, R.B { x } ->`, every variant must carry
              # the SAME payload (same inline-struct fields and types) — the
              # destructured names are shared across all patterns' bodies.
              if c.destructure && is_union
                # The destructure pattern's type IS the subject it
                # destructures (the MATCH union expr) — same principle as
                # annotate_struct_pattern!; not a guess. Binds are declared
                # below; this only types the pattern node itself.
                stamp_type!(c.destructure, node.expr.full_type!(context: "union destructure subject"))
                variant_name = match_variant_name(c.value)
                verify_match_multi_arm_payloads!(node, c, schema, variant_name, union_subst, kind: 'destructure', name: '{ ... }')
                if variant_name
                  raw_payload = schema.variants[variant_name]
                  # Resolve the payload's field schema (inline struct or named type)
                  payload_schema = if Schemas.inline_struct?(raw_payload)
                    Schemas::StructSchema.new(
                      fields: raw_payload.fields.transform_values { |t| AST::StructField.new(type: t) })
                  else
                    payload_type_sym = raw_payload.is_a?(Type) ? raw_payload.resolved : raw_payload
                    payload_type_sym = union_subst.fetch(payload_type_sym, payload_type_sym)
                    lookup_type_schema(payload_type_sym)
                  end

                  if Schemas.struct?(payload_schema)
                    c.destructure.fields.each do |f|
                      next unless f.bind?
                      unless payload_schema.fields.key?(f.name)
                        name_tok = f.name_token
                        if name_tok
                          valid_fields = payload_schema.fields.keys.reject { |k| k.to_s.start_with?("_") }
                          emit_typo_suggestion!(
                            name_tok, f.name, valid_fields,
                            "MATCH destructure: field '#{f.name}' is not on variant #{variant_name}",
                            "field of variant #{variant_name}",
                            category: :type, cascade: true
                          )
                        else
                          error!(node, :MATCH_DESTRUCTURE_FIELD_UNKNOWN, field: f.name, variant: variant_name)
                        end
                      end
                      field_def = payload_schema.fields[f.name]
                      field_type = field_def.is_a?(AST::StructField) ? field_def.type : field_def
                      field_type = field_type.is_a?(Type) ? field_type : Type.new(field_type)
                      current_scope.declare(f.name, nil, field_type, false, false, nil, :stack)
                      og_declare(f.name, nil, field_type)
                    end
                  end
                end
              end
            end
            with_conditional_context { visit_stmts(c.body) }
            collect_scope_drops(node: node)
          }
        end

        if node.default_case
          branch_logic << proc {
            with_conditional_context { visit_stmts(node.default_case) }
            collect_scope_drops(node: node)
          }
        end

        all_drops = analyze_control_flow_branches(branch_logic)

        if node.default_case
          node.default_drops = T.must(all_drops).pop
        end
        node.case_drops = all_drops

        # Duplicate-pattern detection (enum/union only). A variant repeated
        # across arms — or twice in a single multi-pattern arm — would
        # produce invalid Zig (`.A, .A => ...` or two `.A` prongs); catch
        # at annotate-time so the error names the user-side mistake.
        if is_enum || is_union
          seen = {}
          node.cases.each do |c|
            next if c.kind == :when || c.kind == :struct_pattern
            match_variant_names(c).each do |name|
              if seen[name]
                error!(node, :MATCH_DUPLICATE_PATTERN, variant: name)
              end
              seen[name] = true
            end
          end
        end

        # Exhaustiveness check — enforced for plain MATCH (the default).
        # PARTIAL MATCH bypasses these checks and allows DEFAULT, WHEN, and
        # non-enum/union subjects.
        if node.exhaustive
          # MATCH requires an enum or union subject. Non-discriminated types
          # (Int64, String, ...) can never be statically exhaustive; the user
          # must opt in to PARTIAL MATCH.
          unless is_enum || is_union
            type_label = expr_t.resolved
            emit_match_partial_fix!(node, :MATCH_NEEDS_ENUM_OR_UNION, type: type_label)
          end

          # MATCH forbids DEFAULT — the whole point of an exhaustive MATCH is
          # that every variant is explicitly named. If you want a fallback,
          # write `PARTIAL MATCH`.
          if node.default_case
            error!(node, :MATCH_FORBIDS_DEFAULT)
          end

          # MATCH forbids WHEN guards — they're runtime conditions that break
          # static exhaustiveness. Use `PARTIAL MATCH` for guard-style cases.
          if node.cases.any? { |c| c.kind == :when }
            error!(node, :MATCH_FORBIDS_WHEN)
          end

          # Every variant must appear exactly once. Multi-pattern arms
          # contribute one entry per pattern so they count toward
          # exhaustiveness like single arms would.
          covered = node.cases.flat_map do |c|
            match_variant_names(c)
          end.to_set

          all_variants = is_enum ? schema.variants : schema.variants.keys.to_set
          missing = all_variants - covered
          unless missing.empty?
            type_label2 = is_enum ? "enum" : "union"
            emit_match_partial_fix!(node, :MATCH_NON_EXHAUSTIVE,
              kind: type_label2, name: type_name, missing: missing.sort.join(', '))
          end
        end

        # Store case result types so use sites can promote to expression mode.
        node.case_result_types = node.cases.map { |c| expr_result_type(c.body) }
        node.default_result_type = expr_result_type(node.default_case)

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::ForRange).returns(T.nilable(Symbol)) }
      def visit_ForRange(node)
        T.bind(self, SemanticAnnotator)

        # 1. Type-check range bounds
        visit(node.start_expr)
        visit(node.end_expr)
        start_type = node.start_expr.resolved_type
        end_type   = node.end_expr.resolved_type
        error!(node, :FOR_RANGE_START_NEEDS_INT64, got: start_type) unless start_type == :Int64
        error!(node, :FOR_RANGE_END_NEEDS_INT64, got: end_type) unless end_type == :Int64

        # 2. Analyze body in new scope with loop variable declared as immutable Int64
        if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end
        analyze_control_flow_branches([
          proc {
            current_scope.declare(node.var_name, nil, :Int64, false, false, nil, :stack)
            record_capture_local!(node.var_name.to_s)
            node.symbol = current_scope.locals[node.var_name]
            classify_ownership!(node.symbol)
            visit_stmts(node.body)
            finalize_scope(node)
            node.deferred_drops
          }
        ], merge_to_parent: false)
        if current_fn_ctx then current_fn_ctx.loop_depth -= 1 else @loop_depth -= 1 end

        # 4. TIGHT validation (same as WhileLoop).
        if node.tight
          validate_tight_body!(node.body, node)
        end

        # mark_per_iter is set by LoopFrameAnalysis in Pass 2, after CleanupClassifier
        # has finalized every binding's allocator.
        node.mark_per_iter = false

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::ForEach).returns(T.nilable(Symbol)) }
      def visit_ForEach(node)
        T.bind(self, SemanticAnnotator)

        # 1. Visit collection to determine element type
        visit(node.collection)
        coll_type = node.collection.full_type!(context: "FOR collection")
        ct = coll_type.is_a?(Type) ? coll_type : Type.new(coll_type)

        # Determine element type from collection
        elem_type = if ct.array? || ct.list_collection?
          ct.element_type || ct.value_type || :Any
        elsif ct.map?
          # FOR k IN map iterates over keys (strings)
          :String
        else
          error!(node, :FOR_IN_NEEDS_COLLECTION, got: coll_type)
        end

        elem_sym = elem_type.is_a?(Type) ? elem_type.resolved : elem_type

        # 2. Analyze body with loop variable
        current_fn_ctx.loop_depth += 1
        analyze_control_flow_branches([
          proc {
            current_scope.declare(node.var_name, nil, elem_sym, node.is_mutable == true, false, nil, :stack)
            record_capture_local!(node.var_name.to_s)
            node.symbol = current_scope.locals[node.var_name]
            classify_ownership!(node.symbol)
            visit_stmts(node.body)
            finalize_scope(node)
            node.deferred_drops
          }
        ], merge_to_parent: false)
        current_fn_ctx.loop_depth -= 1

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::WhileLoop).returns(T.nilable(Symbol)) }
      def visit_WhileLoop(node)
        T.bind(self, SemanticAnnotator)

        # 1. Analyze Condition
        visit(node.condition)

        if node.condition.resolved_type != :Bool
          error!(node, :CONDITION_NEEDS_BOOL, got: node.condition.resolved_type)
        end

        # Effect tracking: WHILE TRUE or any non-trivially-bounded loop.
        if node.condition.is_a?(AST::Identifier) && node.condition.name == "TRUE"
          record_effect(EffectTracker::LOOP_UNBOUND)
        elsif node.condition.is_a?(AST::Literal) && node.condition.value == true
          record_effect(EffectTracker::LOOP_UNBOUND)
        end

        # 2. Analyze Body in a New Scope AND increment loop depth
        if current_fn_ctx then current_fn_ctx.loop_depth += 1 else @loop_depth += 1 end

        # We use analyze_control_flow_branches to handle state merging and drops.
        # Note: For a loop, if a variable dies in the body, it dies for the next iteration (merged to parent).
        pre_loop_states = @og&.fork_lightweight

        analyze_control_flow_branches([
          proc {
            if node.do_branch.is_a?(Array)
              visit_stmts(node.do_branch)
            else
              visit(node.do_branch)
            end
            finalize_scope(node)

            # Post-analysis check for loop-specific errors (use of moved value in next iteration)
            # Copyable types (primitives, strings, slices, unions) are exempt — they're copied implicitly.
            # Variables not referenced in the loop body are also exempt — they were moved before the
            # loop (e.g. MATCH struct bindings with field extraction) and aren't consumed by iteration.
            loop_body_names = collect_body_identifier_names(node.do_branch)
            current_scope.locals.each do |name, _entry|
              saved = pre_loop_states&.dig(:node_states, name)
              was_live = (saved.is_a?(Hash) ? saved[:state] : saved) == :live
              is_moved = @og&.moved?(name)
              if was_live && is_moved
                if @og&.[](name)&.move_action == :capture &&
                   current_capture_context&.analysis&.captures&.key?(name)
                  next
                end
                next unless loop_body_names.include?(name)
                var_type = current_scope.locals[name]&.type
                type_obj = var_type.is_a?(Type) ? var_type : Type.new(var_type.to_s)
                is_copy = type_obj.implicitly_copyable? { |t| lookup_type_schema(t) }
                unless is_copy
                  emit_use_of_moved_in_loop_error!(node, name, @og&.[](name), code: :USE_OF_MOVED_IN_LOOP)
                end
              end
            end
            node.deferred_drops
          }
        ], merge_to_parent: false)

        if current_fn_ctx then current_fn_ctx.loop_depth -= 1 else @loop_depth -= 1 end

        # 4. TIGHT validation: deep-scan the entire loop body AST (including nested
        # if/while/match blocks) for direct calls to @reentrant or EXTERN FN functions.
        # Does NOT recurse into bodies of called CLEAR functions — those are separate
        # compilation units and their internal behaviour is their own concern.
        if node.tight
          validate_tight_body!(node.do_branch, node)
        end

        # mark_per_iter is set by LoopFrameAnalysis in Pass 2, after CleanupClassifier
        # has finalized every binding's allocator.
        node.mark_per_iter = false

        stamp_type!(node, :Void)
      end

      sig { params(node: AST::WhileBindLoop).returns(T.nilable(Symbol)) }
      def visit_WhileBindLoop(node)
        T.bind(self, SemanticAnnotator)

        visit(node.condition)
        ti = node.condition.full_type!(context: "WHILE AS condition")
        unless ti&.optional?
          error!(node.condition, :WHILE_AS_NEEDS_OPTIONAL, got: node.condition.resolved_type)
        end

        unwrapped = ti.wrapped_type
        if node.condition.is_a?(AST::ResolveNode) && (ti.multiowned? || ti.shared?)
          unwrapped.apply_reference_ownership!(ti.ownership, link_source: ti.link_source)
        end

        current_fn_ctx.loop_depth += 1

        pre_loop_states = @og&.fork_lightweight

        # Footgun guard: a MethodCall on an immutable receiver cannot advance the
        # loop condition and will loop forever.  RESOLVE is a ResolveNode (not a
        # MethodCall) and is safe; mutable receivers may mutate state each iteration.
        cond = node.condition
        if cond.is_a?(AST::MethodCall)
          recv = cond.object
          if recv.is_a?(AST::Identifier) && current_scope.is_immutable?(recv.name)
            error!(node, :WHILE_AS_IMMUTABLE_RECEIVER, method: cond.name, recv: recv.name, recv2: recv.name)
          end
        end

        analyze_control_flow_branches([
          proc {
            current_scope.declare(node.binding_name, nil, unwrapped, false, false, nil, :stack)
            record_capture_local!(node.binding_name.to_s)
            entry = current_scope.locals[node.binding_name]
            classify_ownership!(entry)
            og_declare(node.binding_name.to_s, nil, unwrapped)

            visit_stmts(node.do_branch)
            finalize_scope(node)

            loop_body_names = collect_body_identifier_names(node.do_branch)
            current_scope.locals.each do |name, _entry|
              next if name == node.binding_name
              saved = pre_loop_states&.dig(:node_states, name)
              was_live = (saved.is_a?(Hash) ? saved[:state] : saved) == :live
              is_moved = @og&.moved?(name)
              if was_live && is_moved
                if @og&.[](name)&.move_action == :capture &&
                   current_capture_context&.analysis&.captures&.key?(name)
                  next
                end
                next unless loop_body_names.include?(name)
                var_type = current_scope.locals[name]&.type
                type_obj = var_type.is_a?(Type) ? var_type : Type.new(var_type.to_s)
                is_copy = type_obj.implicitly_copyable? { |t| lookup_type_schema(t) }
                unless is_copy
                  emit_use_of_moved_in_loop_error!(node, name, @og&.[](name), code: :USE_OF_MOVED_IN_LOOP_SHORT)
                end
              end
            end
            node.deferred_drops
          }
        ], merge_to_parent: false)

        current_fn_ctx.loop_depth -= 1

        node.mark_per_iter = false
        stamp_type!(node, :Void)
      end

      # Deep validation for TIGHT loops.
      # Walks the full AST subtree (nested ifs, whiles, match blocks) looking for
      # any call to a @reentrant or EXTERN FN function. Stops at FunctionDef
      # boundaries — nested lambdas/closures are separate compilation units.

      sig { params(node: AST::BreakNode).returns(T.nilable(Symbol)) }
      def visit_BreakNode(node)
        T.bind(self, SemanticAnnotator)

        if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
          error!(node, :BREAK_OUTSIDE_LOOP)
        end
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::ContinueNode).returns(T.nilable(Symbol)) }
      def visit_ContinueNode(node)
        T.bind(self, SemanticAnnotator)

        if (current_fn_ctx&.loop_depth || @loop_depth) <= 0
          error!(node, :CONTINUE_OUTSIDE_LOOP)
        end
        stamp_type!(node, :Void)
      end
    end
  end
end
