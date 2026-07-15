# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module ControlFlow
      extend T::Sig

      MatchSchema = T.type_alias { T.any(Schemas::EnumSchema, Schemas::StructSchema, Schemas::UnionSchema, Schemas::ResourceSchema) }
      MatchPayload = T.type_alias { T.any(Type::FunctionType, Type, Symbol, String, Schemas::InlineStructVariant, NilClass) }
      BranchSnapshot = T.type_alias { T.nilable(OwnershipGraph::LightweightSnapshot) }

      class BranchAnalysisResult < T::Struct
        const :drops, BasicObject
        const :snapshot, BranchSnapshot
        const :terminated, T::Boolean
      end

      class MatchSubjectPlan < T::Struct
        extend T::Sig

        const :expr_type, Type
        const :type_name, Symbol
        const :schema, T.nilable(MatchSchema)
        const :enum_subject, T::Boolean
        const :union_subject, T::Boolean
        const :union_subst, T::Hash[Symbol, Symbol]

        sig { returns(T::Boolean) }
        def enum?
          enum_subject
        end

        sig { returns(T::Boolean) }
        def union?
          union_subject
        end
      end

      sig { params(branches: T::Array[T.proc.returns(BasicObject)], merge_to_parent: T::Boolean).returns(T::Array[BasicObject]) }
      def analyze_control_flow_branches(branches, merge_to_parent: true)
        T.bind(self, SemanticAnnotator)

        og_snapshot = ownership_graph.fork_lightweight
        branch_results = T.let([], T::Array[BranchAnalysisResult])

        branches.each do |branch_logic|
          branch_results << analyze_control_flow_branch(branch_logic, og_snapshot)
        end

        if merge_to_parent
          # Restore to base, then merge only non-terminating branch results.
          # A terminating branch (RETURN/RAISE) cannot reach the merge point, so
          # its moved states must not poison the post-branch scope.
          ownership_graph.restore_lightweight(og_snapshot) if og_snapshot
          branch_results.each do |branch_result|
            next if branch_result.terminated
            snap = branch_result.snapshot
            next unless snap
            # Lightweight merge: just apply moved states
            snap.each_state do |path, state|
              node = ownership_graph.nodes[path]
              next unless node
              if node.state != state
                if state == :moved
                  node.state = :moved
                  node.move_line = snap.move_line_for(path)
                  node.move_col = snap.move_col_for(path)
                  node.move_action = snap.move_action_for(path)
                end
              end
            end
          end
        else
          ownership_graph.restore_lightweight(og_snapshot) if og_snapshot
        end

        branch_results.map(&:drops)
      end

      sig { params(branch_logic: T.proc.returns(BasicObject), og_snapshot: BranchSnapshot).returns(BranchAnalysisResult) }
      def analyze_control_flow_branch(branch_logic, og_snapshot)
        T.bind(self, SemanticAnnotator)

        # Restore graph to pre-branch state before analyzing each branch.
        ownership_graph.restore_lightweight(og_snapshot) if og_snapshot
        prev_terminated = @branch_terminated
        stream_frame = current_stream_yield_frame
        prev_stream_closed = stream_frame&.closed
        @branch_terminated = false

        begin
          with_new_scope(current_scope) do
            pushed_og_scope = T.let(false, T::Boolean)
            begin
              og_push_scope
              pushed_og_scope = true
              BranchAnalysisResult.new(
                drops: branch_logic.call,
                snapshot: ownership_graph.fork_lightweight,
                terminated: @branch_terminated,
              )
            ensure
              og_pop_scope if pushed_og_scope
            end
          end
        ensure
          @branch_terminated = prev_terminated
          stream_frame.closed = T.must(prev_stream_closed) if stream_frame && !prev_stream_closed.nil?
        end
      end
      private :analyze_control_flow_branch

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

        if node.condition.is_a?(AST::IsA) && node.comptime
          annotate_comptime_is_a!(node.condition)
        else
          if node.condition.is_a?(AST::IsA) && static_type_expr?(node.condition.left)
            emit_is_a_needs_comptime_fix!(node)
          end
          with_if_is_a_condition(node.condition) { visit(node.condition) }
        end

        branch_logic = [
          proc {
            with_conditional_context do
              declare_is_a_binding!(node.condition)
              with_comptime_is_a_then_refinement(node.condition) do
                visit_stmts(node.then_branch)
              end
            end
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

      sig { params(node: AST::IsA).returns(T.nilable(Symbol)) }
      def visit_IsA(node)
        T.bind(self, SemanticAnnotator)

        unless static_type_expr?(node.left)
          annotate_runtime_is_a!(node)
          stamp_type!(node, :Bool)
          return nil
        end

        annotate_comptime_is_a!(node)
        nil
      end

      sig { params(node: AST::IsA).void }
      def annotate_comptime_is_a!(node)
        T.bind(self, SemanticAnnotator)

        annotate_is_a_operand!(node.left, side: "Left")
        annotate_is_a_operand!(node.right, side: "Right")
        stamp_type!(node, :Bool)
      end

      sig { params(condition: AST::Node, blk: T.proc.void).void }
      def with_if_is_a_condition(condition, &blk)
        T.bind(self, SemanticAnnotator)

        previous = @current_if_is_a_condition
        @current_if_is_a_condition = condition
        blk.call
      ensure
        @current_if_is_a_condition = previous
      end

      sig { params(node: AST::IsA).void }
      def annotate_runtime_is_a!(node)
        T.bind(self, SemanticAnnotator)

        visit(node.left)
        subject_type = node.left.full_type!(context: "runtime IS_A subject")
        type_name = T.cast(subject_type.generic_instance? ? subject_type.generic_base : subject_type.resolved, Symbol)
        schema = T.cast(lookup_type_schema(type_name), T.nilable(MatchSchema))
        unless Schemas.union?(schema)
          error!(node.left, :IS_A_RUNTIME_NEEDS_UNION, got: subject_type.to_s)
        end

        union_schema = T.cast(schema, Schemas::UnionSchema)
        subst = match_union_substitution(subject_type, union_schema, true)
        variant_name = resolve_runtime_is_a_variant!(node, union_schema, type_name, subst)
        node.runtime_variant_name = variant_name
        stamp_runtime_is_a_target!(node.right, type_name)

        binding = node.binding
        return unless binding

        raw_payload = runtime_union_payload(union_schema, variant_name)
        if raw_payload.nil?
          error!(node, :MATCH_UNIT_CAPTURE, binding: binding, variant: variant_name)
          return
        end

        match_case = AST::MatchCase.new(kind: :eq, value: node.right, binding: binding, body: [])
        node.runtime_payload_type = match_payload_binding_type(
          MatchSubjectPlan.new(
            expr_type: subject_type,
            type_name: type_name,
            schema: union_schema,
            enum_subject: false,
            union_subject: true,
            union_subst: subst,
          ),
          variant_name,
          raw_payload,
          match_case,
        )
        node.runtime_indirect_payload_as = match_case.indirect_payload_as
      end

      sig do
        params(
          node: AST::IsA,
          schema: Schemas::UnionSchema,
          union_type: Symbol,
          union_subst: T::Hash[Symbol, Symbol]
        ).returns(String)
      end
      def resolve_runtime_is_a_variant!(node, schema, union_type, union_subst)
        T.bind(self, SemanticAnnotator)

        target_names = runtime_is_a_target_names(node.right)
        variant_key = target_names.filter_map { |name| runtime_union_variant_key(schema, name) }.first
        return T.must(variant_key).to_s if variant_key

        payload_matches = schema.variants.keys.select do |variant|
          payload = normalized_runtime_match_payload(T.unsafe(schema.variants[variant]), union_subst)
          runtime_is_a_payload_matches?(payload, target_names, union_type, variant.to_s)
        end

        if payload_matches.length == 1
          return payload_matches.first.to_s
        elsif payload_matches.length > 1
          error!(node, :IS_A_RUNTIME_AMBIGUOUS_PAYLOAD,
            target: runtime_is_a_target_label(node.right),
            union: union_type,
            variants: payload_matches.map(&:to_s).sort.join(', '))
        end

        error!(node, :IS_A_RUNTIME_UNKNOWN_VARIANT,
          target: runtime_is_a_target_label(node.right),
          union: union_type)
      end

      sig { params(node: T.any(AST::Node, Type)).returns(T::Array[String]) }
      def runtime_is_a_target_names(node)
        segments = runtime_is_a_target_segments(node)
        full = segments.join(".")
        [full, segments.last].compact.uniq
      end

      sig { params(node: T.any(AST::Node, Type)).returns(T::Array[String]) }
      def runtime_is_a_target_segments(node)
        case node
        when Type
          [Type.coercion_surface_name(node)]
        when AST::Identifier
          [node.name]
        when AST::GetField
          runtime_is_a_target_segments(T.cast(node.target, AST::Node)) + [node.field.to_s]
        else
          [T.unsafe(node).token_value.to_s]
        end
      end

      sig { params(node: T.any(AST::Node, Type)).returns(String) }
      def runtime_is_a_target_label(node)
        runtime_is_a_target_segments(node).join(".")
      end

      sig { params(schema: Schemas::UnionSchema, name: String).returns(T.nilable(T.any(String, Symbol))) }
      def runtime_union_variant_key(schema, name)
        schema.variants.keys.find { |key| key.to_s == name.to_s }
      end

      sig { params(schema: Schemas::UnionSchema, variant_name: String).returns(MatchPayload) }
      def runtime_union_payload(schema, variant_name)
        key = runtime_union_variant_key(schema, variant_name)
        key ? schema.variants[key] : nil
      end

      sig { params(payload: MatchPayload, target_names: T::Array[String], union_type: Symbol, variant_name: String).returns(T::Boolean) }
      def runtime_is_a_payload_matches?(payload, target_names, union_type, variant_name)
        case payload
        when Type
          payload_name = Type.coercion_surface_name(payload)
          payload_names = [payload_name, payload_name.split(".").last].uniq
          (payload_names & target_names).any?
        when Schemas::InlineStructVariant
          synthetic_name = "#{union_type}_#{variant_name}"
          ([synthetic_name, variant_name] & target_names).any?
        when Symbol
          payload_name = payload.to_s
          ([payload_name, payload_name.split(".").last] & target_names).any?
        else
          false
        end
      end

      sig { params(node: T.any(AST::Node, Type), type_name: Symbol).void }
      def stamp_runtime_is_a_target!(node, type_name)
        T.bind(self, SemanticAnnotator)

        case node
        when Type
          return
        when AST::GetField
          stamp_runtime_is_a_target!(T.cast(node.target, AST::Node), type_name)
          stamp_type!(node, type_name)
        when AST::Identifier
          stamp_type!(node, :Type)
        else
          visit(node)
        end
      end

      sig { params(node: T.any(AST::Node, Type), side: String).void }
      def annotate_is_a_operand!(node, side:)
        T.bind(self, SemanticAnnotator)

        return if node.is_a?(Type)

        if static_type_expr?(node)
          stamp_type!(node, :Type)
        else
          visit(node)
        end

        type_info = node.full_type!(context: "IS_A #{side.downcase} operand")
        return if type_info.resolved == :Type

        error!(node, :IS_A_OPERAND_NEEDS_TYPE, side: side, got: type_info.to_s)
      end

      sig { params(node: T.any(AST::Node, Type)).returns(T::Boolean) }
      def static_type_expr?(node)
        T.bind(self, SemanticAnnotator)

        case node
        when Type
          true
        when AST::Identifier
          name = node.name.to_sym
          current_function_type_param?(name) ||
            Type::ZIG_TYPE_MAP.key?(name) ||
            !!lookup_type_schema(name)
        when AST::GetField
          static_dotted_type_expr?(node)
        else
          false
        end
      end

      sig { params(node: AST::GetField).returns(T::Boolean) }
      def static_dotted_type_expr?(node)
        return false unless node.target.is_a?(AST::Identifier)

        namespace = T.cast(node.target, AST::Identifier).name
        namespace == "AST"
      end

      sig do
        type_parameters(:Result)
          .params(
            condition: AST::Node,
            blk: T.proc.returns(T.type_parameter(:Result)),
          )
          .returns(T.type_parameter(:Result))
      end
      def with_comptime_is_a_then_refinement(condition, &blk)
        refinement = comptime_is_a_type_param_refinement(condition)
        return blk.call unless refinement

        type_param = T.cast(refinement[0], Symbol)
        narrowed_type = T.cast(refinement[1], Type)
        T.unsafe(self).__send__(:with_comptime_type_param_refinement, type_param, narrowed_type) { blk.call }
      end

      sig { params(condition: AST::Node).returns(T.nilable(T::Array[T.untyped])) }
      def comptime_is_a_type_param_refinement(condition)
        return nil unless condition.is_a?(AST::IsA)
        left = condition.left
        return nil unless left.is_a?(AST::Identifier)

        type_param = left.name.to_sym
        return nil unless T.unsafe(self).__send__(:current_function_type_param?, type_param)

        narrowed_type = static_is_a_target_type(condition.right)
        narrowed_type ? [type_param, narrowed_type] : nil
      end

      sig { params(node: T.any(AST::Node, Type)).returns(T.nilable(Type)) }
      def static_is_a_target_type(node)
        case node
        when Type
          Type.new(node)
        when AST::Identifier
          Type.new(node.name.to_sym)
        when AST::GetField
          Type.new(runtime_is_a_target_label(node).to_sym)
        else
          nil
        end
      end

      sig { params(node: AST::IfStatement).void }
      def emit_is_a_needs_comptime_fix!(node)
        fix = Fix.new(
          description: DiagnosticRegistry.fix_description(:INSERT_COMPTIME_BEFORE_IF),
          confidence: :auto,
          edits: [
            Edit.new(
              span: Span.new(file: nil, line: node.token.line, col: node.token.column, length: 0),
              replacement: "COMPTIME ",
            )
          ],
        )
        T.unsafe(self).__send__(:fixable!,
          node,
          category: :type,
          level: :error,
          code: :IS_A_NEEDS_COMPTIME,
          fixes: [fix],
          raise_in_collector: true,
        )
      end

      sig { params(condition: AST::Node).void }
      def declare_is_a_binding!(condition)
        return unless condition.is_a?(AST::IsA)
        binding = condition.binding
        return unless binding

        if condition.runtime_variant_name
          payload_type = condition.runtime_payload_type
          return unless payload_type

          scope = T.unsafe(self).__send__(:current_scope)
          scope.declare(binding, nil, payload_type, false, false, nil, :stack)
          T.unsafe(self).__send__(:og_declare, binding, nil, payload_type)
          T.unsafe(self).__send__(:classify_ownership!, scope.local_entry!(binding))
          borrow_match_payload_binding!(binding)
          return
        end

        T.unsafe(self).__send__(:current_scope).declare(binding, nil, Type.new(:Type), false, false, nil, :stack)
      end

      sig { params(node: AST::IfBind).returns(Symbol) }
      def visit_IfBind(node)
        T.bind(self, SemanticAnnotator)

        branch_logic = [
          proc {
            # Refine and declare left-to-right. A later predicate expression may
            # use an alias introduced by an earlier predicate in the same chain.
            node.bindings.each do |b|
              if b.predicate == :is_ok
                with_body_fact_failure_absorbed(true) { visit(b.expr) }
              else
                visit(b.expr)
              end
              ti = if b.predicate == :is_ok && b.expr.respond_to?(:error_union_type) && T.unsafe(b.expr).error_union_type
                T.unsafe(b.expr).error_union_type
              else
                b.expr.full_type!(context: "IF predicate binding expression")
              end
              unwrapped = if b.predicate == :is_ok
                unless ti.error_union?
                  error!(b.expr, :IS_OK_REQUIRES_FALLIBLE, got: b.expr.resolved_type)
                end
                T.must(ti.success_type)
              else
                if ti.stream_step?
                  b[:predicate] = :stream_item
                  T.must(ti.stream_step_item_type)
                else
                  unless ti.optional?
                    error!(b.expr, :IF_AS_NEEDS_OPTIONAL, got: b.expr.resolved_type)
                  end
                  T.must(ti.wrapped_type)
                end
              end
              if b.expr.is_a?(AST::ResolveNode) && (ti.multiowned? || ti.shared?)
                unwrapped.apply_reference_ownership!(ti.ownership, link_source: ti.link_source)
              end
              b.unwrapped_type = unwrapped
              sym = unwrapped.resolved
              root = AST.root_identifier(b.expr)
              mutable_list_alias = b.expr.is_a?(AST::GetIndex) && root &&
                !current_scope.is_immutable?(root.name) && unwrapped.struct?
              current_scope.declare(b.name, nil, unwrapped, mutable_list_alias, false, nil, :stack)
              entry = current_scope.local_entry!(b.name)
              b.symbol = entry
              # Propagate non_escaping when the source is borrow-derived from a
              # non_escaping binding (a WITH alias or another transitive borrow
              # of one). IF-AS on `p[i]` / `p.field` where `p` is the alias
              # makes the new binding a borrow into locked data; it must not
              # escape the enclosing WITH scope either.
              container_source = find_container_source(b.expr)
              # Compact @node handles and ordinary Copy payloads are returned
              # by value. Binding them does not borrow the collection storage,
              # so a later handle assignment cannot invalidate the binding.
              if unwrapped.node_reference? || unwrapped.implicitly_copyable?
                container_source = nil
              end
              if (src_sym = AST.root_identifier(b.expr)&.symbol)
                entry.mark_non_escaping! if src_sym.non_escaping
                if container_source
                  entry.lifetime = SymbolEntry.tied_lifetime([src_sym])
                  entry.mark_borrowed_alias!
                end
              end
              classify_ownership!(entry)
              og_declare(b.name.to_s, nil, unwrapped)
              if container_source
                ownership_graph[b.name.to_s]&.kind = :borrowed
                ownership_graph.borrow(b.name.to_s, container_source, mutable: mutable_list_alias)
              end
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

      sig { params(match_node: AST::MatchStatement, pat: AST::StructPattern).void }
      def annotate_struct_pattern!(match_node, pat)
        T.bind(self, SemanticAnnotator)

        expr_type = match_node.expr.resolved_type
        primitives = [:Float64, :Bool, :Byte, :Int64, :Float64, :String, :NIL, :BOOLEAN, :Any, :Void]

        if primitives.include?(expr_type)
          error!(match_node, :MATCH_NEEDS_STRUCT_TYPE, got: expr_type)
        end

        schema = lookup_type_schema(T.must(expr_type))

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
              field_type = field_def.type
              current_scope.declare(f.name, nil, field_type, false, false, nil, :stack)
              og_declare(f.name, nil, field_type)
            end
          else
            field_expr = T.must(f.expr)
            visit(field_expr)

            if schema
              field_def = schema.fields[f.name]
              ft = field_def&.type
              field_type = ft.is_a?(Type) ? ft.resolved : ft
              val_type   = field_expr.resolved_type
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
        nil
      end

      sig { params(pattern: AST::Node).returns(T.nilable(String)) }
      def match_variant_name(pattern)
        T.bind(self, SemanticAnnotator)

        case pattern
        when AST::GetField   then pattern.field
        when AST::MethodCall then pattern.name
        end
      end

      sig { params(arm: AST::MatchCase).returns(T::Array[String]) }
      def match_variant_names(arm)
        T.bind(self, SemanticAnnotator)

        [arm.value, *(arm.extra_values || [])].filter_map { |pattern| match_variant_name(pattern) }
      end

      sig { params(payload: MatchPayload, union_subst: T::Hash[Symbol, Symbol]).returns(MatchPayload) }
      def normalized_match_payload(payload, union_subst)
        T.bind(self, SemanticAnnotator)

        return apply_type_subst(payload, union_subst).resolved if payload.is_a?(Type)
        return union_subst.fetch(payload, payload) if payload.is_a?(Symbol)

        payload
      end

      sig { params(payload: MatchPayload, union_subst: T::Hash[Symbol, Symbol]).returns(MatchPayload) }
      def normalized_runtime_match_payload(payload, union_subst)
        T.bind(self, SemanticAnnotator)

        return apply_type_subst(payload, union_subst) if payload.is_a?(Type)
        return union_subst.fetch(payload, payload) if payload.is_a?(Symbol)

        payload
      end

      sig do
        params(
          node: AST::MatchStatement,
          arm: AST::MatchCase,
          schema: Schemas::UnionSchema,
          variant_name: T.nilable(String),
          union_subst: T::Hash[Symbol, Symbol],
          kind: String,
          name: String
        ).void
      end
      def verify_match_multi_arm_payloads!(node, arm, schema, variant_name, union_subst, kind:, name:)
        T.bind(self, SemanticAnnotator)

        return unless variant_name

        head_payload = normalized_match_payload(T.unsafe(schema.variants[variant_name]), union_subst)
        match_variant_names(arm).drop(1).each do |extra_name|
          extra_payload = normalized_match_payload(T.unsafe(schema.variants[extra_name]), union_subst)
          next if head_payload == T.unsafe(extra_payload)

          error!(node, :MATCH_MULTI_ARM_PAYLOAD_MISMATCH,
            head: variant_name, other: extra_name, kind: kind, name: name)
        end
      end

      sig { params(node: AST::StructLit, schema: T.any(Schemas::StructSchema, Schemas::UnionSchema)).returns(T::Hash[Symbol, Symbol]) }
      def literal_type_substitution!(node, schema)
        T.bind(self, SemanticAnnotator)

        type_params = schema.type_params
        subst = {}
        if node.type_args&.any?
          if type_params.empty?
            error!(node, :GENERIC_NOT_GENERIC, type: node.name)
          end
          if node.type_args.length != type_params.length
            error!(node, :GENERIC_WRONG_ARG_COUNT, type: node.name, expected: type_params.length, got: node.type_args.length)
          end
          type_params.zip(node.type_args).each { |param, arg| subst[param] = arg.to_sym }
        elsif type_params.any?
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

      sig { params(node: AST::MatchStatement).returns(MatchSubjectPlan) }
      def match_subject_plan(node)
        T.bind(self, SemanticAnnotator)

        expr_t = Type.new(node.expr.full_type!(context: "MATCH subject"))
        node.string_match = true if expr_t.string?
        type_name = T.cast(expr_t.generic_instance? ? expr_t.generic_base : expr_t.resolved, Symbol)
        schema = T.cast(lookup_type_schema(type_name), T.nilable(MatchSchema))
        is_enum = Schemas.enum?(schema)
        is_union = Schemas.union?(schema)
        MatchSubjectPlan.new(
          expr_type: expr_t,
          type_name: type_name,
          schema: schema,
          enum_subject: is_enum,
          union_subject: is_union,
          union_subst: match_union_substitution(expr_t, schema, is_union),
        )
      end

      sig { params(expr_t: Type, schema: T.nilable(MatchSchema), is_union: T::Boolean).returns(T::Hash[Symbol, Symbol]) }
      def match_union_substitution(expr_t, schema, is_union)
        return {} unless is_union
        return {} unless expr_t.generic_instance?

        union_schema = T.cast(schema, Schemas::UnionSchema)
        type_params = union_schema.type_params
        return {} if type_params.empty?

        subst = T.let({}, T::Hash[Symbol, Symbol])
        type_params.zip(expr_t.generic_args).each do |p, a|
          next unless a

          subst[p] = a.resolved
        end
        subst
      end

      sig { params(plan: MatchSubjectPlan).returns(Schemas::UnionSchema) }
      def match_union_schema(plan)
        T.cast(plan.schema, Schemas::UnionSchema)
      end

      sig { params(plan: MatchSubjectPlan).returns(Schemas::EnumSchema) }
      def match_enum_schema(plan)
        T.cast(plan.schema, Schemas::EnumSchema)
      end

      sig { params(node: AST::MatchStatement, plan: MatchSubjectPlan).void }
      def consume_match_subject_if_takes!(node, plan)
        T.bind(self, SemanticAnnotator)
        expr = node.expr
        return unless node.takes && plan.union? && expr.is_a?(AST::Identifier)

        source_name = expr.name
        graph_node = ownership_graph[source_name]
        return unless graph_node && graph_node.kind != :borrowed

        expr.was_moved = true
        og_set_moved(source_name, at_token: expr.token, action: :takes)
      end

      sig { params(node: AST::MatchStatement, plan: MatchSubjectPlan).returns(T::Array[T.proc.returns(BasicObject)]) }
      def match_branch_logic(node, plan)
        T.bind(self, SemanticAnnotator)
        branches = T.let([], T::Array[T.proc.returns(BasicObject)])
        node.cases.each do |match_case|
          branches << Kernel.proc {
            analyze_match_case!(node, match_case, plan)
            with_conditional_context { visit_stmts(match_case.body) }
            collect_scope_drops(node: node)
          }
        end
        if node.default_case
          branches << Kernel.proc {
            with_conditional_context { visit_stmts(node.default_case) }
            collect_scope_drops(node: node)
          }
        end
        branches
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, plan: MatchSubjectPlan).void }
      def analyze_match_case!(node, match_case, plan)
        T.bind(self, SemanticAnnotator)
        case match_case.kind
        when :when
          analyze_when_match_case!(node, match_case)
        when :struct_pattern
          pattern = match_case.value
          annotate_struct_pattern!(node, pattern) if pattern.is_a?(AST::StructPattern)
        else
          analyze_value_match_case!(node, match_case, plan)
        end
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase).void }
      def analyze_when_match_case!(node, match_case)
        T.bind(self, SemanticAnnotator)
        visit(match_case.value)
        return if match_case.value.resolved_type == :Bool

        error!(node, :WHEN_NEEDS_BOOL, got: match_case.value.resolved_type)
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, plan: MatchSubjectPlan).void }
      def analyze_value_match_case!(node, match_case, plan)
        T.bind(self, SemanticAnnotator)

        visit_match_patterns!(node, match_case)
        validate_match_pattern_types!(node, match_case, plan)
        declare_match_payload_binding!(node, match_case, plan)
        declare_match_destructure_bindings!(node, match_case, plan)
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase).void }
      def visit_match_patterns!(node, match_case)
        T.bind(self, SemanticAnnotator)
        with_match_pattern_context do
          visit(match_case.value)
          match_case.extra_values&.each do |ev|
            if ev.is_a?(AST::StructPattern)
              annotate_struct_pattern!(node, ev)
            else
              visit(ev)
            end
          end
        end
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, plan: MatchSubjectPlan).void }
      def validate_match_pattern_types!(node, match_case, plan)
        T.bind(self, SemanticAnnotator)
        [match_case.value, *(match_case.extra_values || [])].each do |pat|
          next if match_pattern_type_matches_subject?(pat, node, plan)

          error!(node, :MATCH_CASE_TYPE_MISMATCH, case: pat.resolved_type, expr: node.expr.resolved_type)
        end
      end

      sig { params(pattern: AST::Node, node: AST::MatchStatement, plan: MatchSubjectPlan).returns(T::Boolean) }
      def match_pattern_type_matches_subject?(pattern, node, plan)
        case_type = Type.new(pattern.full_type!(context: "MATCH pattern"))
        return true if pattern.resolved_type == node.expr.resolved_type
        return true if node.expr.resolved_type == :Any || pattern.resolved_type == :Any
        return true if plan.expr_type.generic_instance? && plan.expr_type.generic_base == pattern.resolved_type
        return true if plan.expr_type.optional? && T.must(plan.expr_type.wrapped_type).accepts?(case_type)
        return true if plan.expr_type.string? && case_type.string?

        false
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, plan: MatchSubjectPlan).void }
      def declare_match_payload_binding!(node, match_case, plan)
        T.bind(self, SemanticAnnotator)
        binding = match_case.binding
        return unless binding

        if plan.enum?
          error!(node, :MATCH_ENUM_CAPTURE, binding: binding)
          return
        end
        return unless plan.union?

        union_schema = match_union_schema(plan)
        variant_name = match_variant_name(match_case.value)
        verify_match_multi_arm_payloads!(node, match_case, union_schema, variant_name, plan.union_subst, kind: 'AS', name: binding)
        return unless variant_name

        declare_union_payload_binding!(node, match_case, plan, variant_name, binding)
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, plan: MatchSubjectPlan, variant_name: String, binding: String).void }
      def declare_union_payload_binding!(node, match_case, plan, variant_name, binding)
        T.bind(self, SemanticAnnotator)
        raw_payload = match_union_schema(plan).variants[variant_name]
        if raw_payload.nil?
          error!(node, :MATCH_UNIT_CAPTURE, binding: binding, variant: variant_name)
          return
        end

        payload_type = match_payload_binding_type(plan, variant_name, T.unsafe(raw_payload), match_case)
        current_scope.declare(binding, nil, payload_type, false, false, nil, :stack)
        og_declare(binding, nil, payload_type)
        classify_ownership!(current_scope.local_entry!(binding))
        borrow_match_payload_binding!(binding) unless node.takes
      end

      sig { params(plan: MatchSubjectPlan, variant_name: String, raw_payload: MatchPayload, match_case: AST::MatchCase).returns(Type) }
      def match_payload_binding_type(plan, variant_name, raw_payload, match_case)
        T.bind(self, SemanticAnnotator)
        payload = T.must(raw_payload)
        if payload.is_a?(Schemas::InlineStructVariant)
          return Type.new(:"#{plan.type_name}_#{variant_name}")
        end
        if payload.is_a?(Type) && payload.indirect?
          inner_type = payload.dup
          inner_type.strip_layout!
          match_case.indirect_payload_as = true
          return apply_type_subst(inner_type, plan.union_subst)
        end
        apply_type_subst(payload, plan.union_subst)
      end

      sig { params(binding: String).void }
      def borrow_match_payload_binding!(binding)
        T.bind(self, SemanticAnnotator)
        T.must(ownership_graph[binding]).kind = :borrowed
        current_scope.entry_for_write!(binding).storage = :borrow
      end

      sig { params(node: AST::MatchStatement, match_case: AST::MatchCase, plan: MatchSubjectPlan).void }
      def declare_match_destructure_bindings!(node, match_case, plan)
        T.bind(self, SemanticAnnotator)
        destructure = match_case.destructure
        return unless destructure && plan.union?

        stamp_type!(destructure, node.expr.full_type!(context: "union destructure subject"))
        variant_name = match_variant_name(match_case.value)
        union_schema = match_union_schema(plan)
        verify_match_multi_arm_payloads!(node, match_case, union_schema, variant_name, plan.union_subst, kind: 'destructure', name: '{ ... }')
        return unless variant_name

        payload_schema = match_payload_struct_schema(plan, variant_name)
        declare_match_destructure_fields!(node, destructure, T.must(payload_schema), variant_name) if Schemas.struct?(payload_schema)
      end

      sig { params(plan: MatchSubjectPlan, variant_name: String).returns(T.nilable(MatchSchema)) }
      def match_payload_struct_schema(plan, variant_name)
        T.bind(self, SemanticAnnotator)
        raw_payload = match_union_schema(plan).variants[variant_name]
        if Schemas.inline_struct?(raw_payload)
          inline_payload = T.cast(raw_payload, Schemas::InlineStructVariant)
          return Schemas::StructSchema.new(
            fields: inline_payload.fields.transform_values { |t| AST::StructField.new(type: t) },
          )
        end

        return nil unless raw_payload.is_a?(Type)

        payload_type_sym = raw_payload.resolved
        payload_type_sym = plan.union_subst.fetch(payload_type_sym, payload_type_sym)
        T.cast(lookup_type_schema(payload_type_sym), T.nilable(MatchSchema))
      end

      sig { params(node: AST::MatchStatement, destructure: AST::StructPattern, payload_schema: MatchSchema, variant_name: String).void }
      def declare_match_destructure_fields!(node, destructure, payload_schema, variant_name)
        T.bind(self, SemanticAnnotator)
        struct_schema = T.cast(payload_schema, Schemas::StructSchema)
        destructure.fields.each do |field|
          next unless field.bind?
          unless struct_schema.fields.key?(field.name)
            emit_unknown_destructure_field!(node, field, struct_schema, variant_name)
            next
          end
          field_type = struct_schema.fields.fetch(field.name).type
          current_scope.declare(field.name, nil, field_type, false, false, nil, :stack)
          og_declare(field.name, nil, field_type)
        end
      end

      sig { params(node: AST::MatchStatement, field: AST::PatternField, payload_schema: Schemas::StructSchema, variant_name: String).void }
      def emit_unknown_destructure_field!(node, field, payload_schema, variant_name)
        T.bind(self, SemanticAnnotator)
        name_tok = field.name_token
        if name_tok
          valid_fields = payload_schema.fields.keys.reject { |k| k.to_s.start_with?("_") }
          emit_typo_suggestion!(
            name_tok, field.name, valid_fields,
            "MATCH destructure: field '#{field.name}' is not on variant #{variant_name}",
            "field of variant #{variant_name}",
            category: :type, cascade: true
          )
        else
          error!(node, :MATCH_DESTRUCTURE_FIELD_UNKNOWN, field: field.name, variant: variant_name)
        end
      end

      sig { params(node: AST::MatchStatement, plan: MatchSubjectPlan).void }
      def reject_duplicate_match_patterns!(node, plan)
        T.bind(self, SemanticAnnotator)
        return unless plan.enum? || plan.union?

        seen = T.let({}, T::Hash[String, T::Boolean])
        node.cases.each do |match_case|
          next if match_case.kind == :when || match_case.kind == :struct_pattern
          match_variant_names(match_case).each do |name|
            error!(node, :MATCH_DUPLICATE_PATTERN, variant: name) if seen[name]
            seen[name] = true
          end
        end
      end

      sig { params(node: AST::MatchStatement, plan: MatchSubjectPlan).void }
      def check_match_exhaustiveness!(node, plan)
        T.bind(self, SemanticAnnotator)
        return unless node.exhaustive

        unless plan.enum? || plan.union?
          emit_match_partial_fix!(node, :MATCH_NEEDS_ENUM_OR_UNION, type: plan.expr_type.resolved)
        end
        error!(node, :MATCH_FORBIDS_DEFAULT) if node.default_case
        error!(node, :MATCH_FORBIDS_WHEN) if node.cases.any? { |match_case| match_case.kind == :when }
        emit_missing_match_variants!(node, plan)
      end

      sig { params(node: AST::MatchStatement, plan: MatchSubjectPlan).void }
      def emit_missing_match_variants!(node, plan)
        T.bind(self, SemanticAnnotator)
        return unless plan.enum? || plan.union?

        covered = node.cases.flat_map { |match_case| match_variant_names(match_case) }.to_set
        all_variants = plan.enum? ? match_enum_schema(plan).variants.to_set : match_union_schema(plan).variants.keys.to_set
        missing = all_variants - covered
        return if missing.empty?

        type_label = plan.enum? ? "enum" : "union"
        emit_match_partial_fix!(node, :MATCH_NON_EXHAUSTIVE,
          kind: type_label, name: plan.type_name, missing: missing.sort.join(', '))
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
        plan = match_subject_plan(node)
        consume_match_subject_if_takes!(node, plan)

        all_drops = analyze_control_flow_branches(match_branch_logic(node, plan))

        if node.default_case
          node.default_drops = T.must(all_drops).pop
        end
        node.case_drops = all_drops

        reject_duplicate_match_patterns!(node, plan)
        check_match_exhaustiveness!(node, plan)

        # Store case result types so use sites can promote to expression mode.
        node.case_result_types = node.cases.map { |c| expr_result_type(c.body) }
        node.default_result_type = expr_result_type(node.default_case || [])

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
        analyze_loop_control_flow_branches([
          proc {
            current_scope.declare(node.var_name, nil, :Int64, false, false, nil, :stack)
            record_capture_local!(node.var_name.to_s)
            node.symbol = current_scope.local_entry!(node.var_name)
            classify_ownership!(T.must(node.symbol))
            visit_stmts(node.body)
            finalize_scope(node)
            node.deferred_drops
          }
        ], merge_to_parent: false)

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
        elem_type = if ct.dynamic_stream? || (ct.bounded_stream? && ct.canonical_stream?)
          ct.stream_element_type || ct.tense_type.element_type || :Any
        elsif ct.array? || ct.list_collection?
          ct.element_type || ct.value_type || :Any
        elsif ct.map?
          # FOR k IN map iterates over keys (strings)
          :String
        else
          error!(node, :FOR_IN_NEEDS_COLLECTION, got: coll_type)
        end

        elem_ti = elem_type.is_a?(Type) ? elem_type : Type.new(elem_type)

        # 2. Analyze body with loop variable
        analyze_loop_control_flow_branches([
          proc {
            current_scope.declare(node.var_name, nil, elem_ti, node.is_mutable == true, false, nil, :borrow)
            record_capture_local!(node.var_name.to_s)
            node.symbol = current_scope.local_entry!(node.var_name)
            T.must(node.symbol).mark_borrowed_alias!
            classify_ownership!(T.must(node.symbol))
            og_declare(node.var_name.to_s, nil, elem_ti)
            ownership_graph[node.var_name.to_s]&.kind = :borrowed
            visit_stmts(node.body)
            finalize_scope(node)
            node.deferred_drops
          }
        ], merge_to_parent: false)

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
        if (node.condition.is_a?(AST::Identifier) && node.condition.name == "TRUE") ||
           (node.condition.is_a?(AST::Literal) && node.condition.true_boolean?)
          record_effect(EffectTracker::LOOP_UNBOUND)
        end

        # 2. Analyze Body in a New Scope AND increment loop depth
        # We use analyze_control_flow_branches to handle state merging and drops.
        # Note: For a loop, if a variable dies in the body, it dies for the next iteration (merged to parent).
        pre_loop_states = ownership_graph.fork_lightweight

        analyze_loop_control_flow_branches([
          proc {
            if node.do_branch.is_a?(Array)
              visit_stmts(node.do_branch)
            else
              visit(node.do_branch)
            end
            finalize_scope(node)

            validate_moved_values_not_reused_by_loop!(
              node,
              node.do_branch,
              pre_loop_states,
              code: :USE_OF_MOVED_IN_LOOP
            )
            node.deferred_drops
          }
        ], merge_to_parent: false)

        # 4. TIGHT validation: deep-scan the entire loop body AST (including nested
        # if/while/match blocks) for direct calls to plain EFFECTS REENTRANT or EXTERN FN functions.
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
        unless ti.optional? || ti.stream_step?
          error!(node.condition, :WHILE_AS_NEEDS_OPTIONAL, got: node.condition.resolved_type)
        end

        unwrapped = ti.stream_step? ? ti.stream_step_item_type : ti.wrapped_type
        if node.condition.is_a?(AST::ResolveNode) && (ti.multiowned? || ti.shared?)
          unwrapped.apply_reference_ownership!(ti.ownership, link_source: ti.link_source)
        end

        pre_loop_states = ownership_graph.fork_lightweight

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

        analyze_loop_control_flow_branches([
          proc {
            current_scope.declare(node.binding_name, nil, unwrapped, false, false, nil, :stack)
            record_capture_local!(node.binding_name.to_s)
            entry = current_scope.local_entry!(node.binding_name)
            classify_ownership!(entry)
            og_declare(node.binding_name.to_s, nil, unwrapped)

            visit_stmts(node.do_branch)
            finalize_scope(node)

            validate_moved_values_not_reused_by_loop!(
              node,
              node.do_branch,
              pre_loop_states,
              code: :USE_OF_MOVED_IN_LOOP_SHORT,
              ignored_name: node.binding_name.to_s
            )
            node.deferred_drops
          }
        ], merge_to_parent: false)

        node.mark_per_iter = false
        stamp_type!(node, :Void)
      end

      sig do
        params(
          node: T.any(AST::WhileLoop, AST::WhileBindLoop),
          body: T.any(AST::Node, T::Array[AST::Node]),
          pre_loop_states: OwnershipGraph::LightweightSnapshot,
          code: Symbol,
          ignored_name: T.nilable(String)
        ).void
      end
      def validate_moved_values_not_reused_by_loop!(node, body, pre_loop_states, code:, ignored_name: nil)
        T.bind(self, SemanticAnnotator)

        collect_body_identifier_names(body).each do |name|
          next if name == ignored_name
          next unless pre_loop_states.state_for(name) == :live
          graph_node = ownership_graph[name]
          next unless graph_node&.state == :moved
          next if captured_move_consumed_by_loop?(name)
          next if loop_value_copyable?(name)

          emit_use_of_moved_in_loop_error!(node, name, graph_node, code: code)
        end
      end

      sig { params(name: String).returns(T::Boolean) }
      def captured_move_consumed_by_loop?(name)
        T.bind(self, SemanticAnnotator)

        (
          ownership_graph[name]&.move_action == :capture &&
          current_capture_context&.analysis&.captures&.key?(name)
        ) == true
      end

      sig { params(name: String).returns(T::Boolean) }
      def loop_value_copyable?(name)
        T.bind(self, SemanticAnnotator)

        var_type = current_scope.resolve_entry(name)&.type
        type_obj = var_type.is_a?(Type) ? var_type : Type.new(var_type.to_s)
        type_obj.implicitly_copyable? { |type_name| lookup_type_schema(type_name) }
      end

      # Deep validation for TIGHT loops.
      # Walks the full AST subtree (nested ifs, whiles, match blocks) looking for
      # any call to a plain EFFECTS REENTRANT or EXTERN FN function. Stops at FunctionDef
      # boundaries — nested lambdas/closures are separate compilation units.

      sig { params(node: AST::BreakNode).returns(T.nilable(Symbol)) }
      def visit_BreakNode(node)
        T.bind(self, SemanticAnnotator)

        if current_loop_depth <= 0
          error!(node, :BREAK_OUTSIDE_LOOP)
        end
        stamp_type!(node, :Void)
      end

      sig { params(node: AST::ContinueNode).returns(T.nilable(Symbol)) }
      def visit_ContinueNode(node)
        T.bind(self, SemanticAnnotator)

        if current_loop_depth <= 0
          error!(node, :CONTINUE_OUTSIDE_LOOP)
        end
        stamp_type!(node, :Void)
      end

      private :analyze_control_flow_branches,
        :analyze_match_case!,
        :analyze_value_match_case!,
        :check_match_exhaustiveness!,
        :declare_match_destructure_fields!,
        :declare_union_payload_binding!,
        :declare_match_destructure_bindings!,
        :declare_match_payload_binding!,
        :emit_missing_match_variants!,
        :reject_duplicate_match_patterns!,
        :validate_match_pattern_types!,
        :visit_match_patterns!
      private :analyze_when_match_case!
  private :annotate_struct_pattern!
  private :borrow_match_payload_binding!
  private :captured_move_consumed_by_loop?
  private :consume_match_subject_if_takes!
  private :emit_unknown_destructure_field!
  private :loop_value_copyable?
  private :match_branch_logic
  private :match_enum_schema
  private :match_pattern_type_matches_subject?
  private :match_payload_binding_type
  private :match_payload_struct_schema
  private :match_subject_plan
  private :match_union_schema
  private :match_union_substitution
  private :normalized_match_payload
  private :validate_moved_values_not_reused_by_loop!
  private :verify_match_multi_arm_payloads!

end
  end
end
