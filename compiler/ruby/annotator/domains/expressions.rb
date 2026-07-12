# typed: true
# frozen_string_literal: true

module Annotator
  module Domains
    module Expressions
      extend T::Sig


      sig { params(fn_node: AST::FunctionDef).returns(T::Array[String]) }
      def infer_implicit_type_params(fn_node)
        T.bind(self, SemanticAnnotator)

        explicit = fn_node.type_params.map(&:to_s)
        return explicit unless explicit.empty?
        inferred = []
        ([fn_node.return_type] + fn_node.params.map { |p| p.type }).each do |type|
          collect_implicit_type_params(type, inferred, explicit)
        end
        (explicit + inferred).uniq
      end

      sig { params(type: T.nilable(Type), out: T::Array[String], explicit: T::Array[String]).void }
      def collect_implicit_type_params(type, out, explicit)
        T.bind(self, SemanticAnnotator)

        return unless type.is_a?(Type)
        name = type.resolved.to_s
        if name.match?(/\A[A-Z]\z/) && !explicit.include?(name) && !lookup_type_schema(name.to_sym)
          out << name
        end
        if type.generic_instance?
          type.generic_args.each { |arg| collect_implicit_type_params(arg, out, explicit) }
        end
        collect_implicit_type_params(type.payload_type, out, explicit) if type.respond_to?(:error_union?) && type.error_union?
        collect_implicit_type_params(type.wrapped_type, out, explicit) if type.respond_to?(:optional?) && type.optional?
        collect_implicit_type_params(type.element_type, out, explicit) if type.respond_to?(:array?) && type.array?
      end

      # Loop-local SROA: when a large struct literal (storage == :frame) is declared
      # inside a loop body, downgrade it to :stack allocation.
      #
      # Rationale: the frame arena's save/restore mark is per-function, not per-iteration.
      # A :frame allocation inside a loop bumps the arena every iteration and never
      # reclaims it until function exit — burning O(N) memory for N iterations.
      # A Zig `var BigVec` on the OS stack is reclaimed automatically each iteration;
      # LLVM then SROAs the fields to registers and dead-code-eliminates unused ones.
      #
      # Safety: CLEAR uses value semantics for structs (pass/return by copy).  A large
      # struct on the stack cannot have its address escape the loop body through normal
      # CLEAR operations, so :stack is always safe here.
      sig { params(node: AST::Cast).returns(Type) }
      def visit_Cast(node)
        T.bind(self, SemanticAnnotator)

        target_type = Type.new(node.target)
        if node.value.is_a?(AST::ListLit) && target_type.tuple?
          node.value.coerced_type = target_type
        elsif node.value.is_a?(AST::HashLit) && target_type.map?
          node.value.coerced_type = target_type
        end
        visit(node.value) # Resolve 'json' -> :HashMap

        # node.target is "Config" or a full Type such as String@symbol.
        # In a strict language, we'd check if :HashMap can cast to Config.
        # For now, just trust the user and carry the full type forward so
        # data capabilities are not collapsed to the bare resolved symbol.
        stamp_type!(node, target_type)
      end

      sig { params(node: AST::CallSiteOverride).void }
      def visit_CallSiteOverride(node)
        T.bind(self, SemanticAnnotator)

        sigil = node.kind == :thunk ? "@thunk" : "@maxDepth"
        variant_hint = node.kind == :thunk ? "'EFFECTS REENTRANT:THUNK'" : "'EFFECTS REENTRANT:MAX_DEPTH(#{node.n})'"
        error!(node, :CALL_SITE_OVERRIDE_UNIMPLEMENTED,
          sigil: sigil, n: node.n, variant_hint: variant_hint)
      end

      sig { params(node: AST::UnaryOp).returns(T.any(Type, Symbol)) }
      def visit_UnaryOp(node)
        T.bind(self, SemanticAnnotator)

        visit(node.right)

        case node.op
        when :NOT, "!"
          stamp_type!(node, :Bool)
        when :EXISTS
          operand_type = node.right.full_type!(context: "EXISTS operand")
          unless Type.new(operand_type).optional?
            error!(node, :EXISTS_REQUIRES_OPTIONAL, got: operand_type)
          end
          stamp_type!(node, :Bool)
        else
          stamp_type!(node, node.right.full_type!(context: "unary right"))
        end
      end

      # ==========================================
      # LITERALS & BINARY OPS
      # ==========================================
      sig { params(node: AST::Literal).returns(Type) }
      def visit_Literal(node)
        T.bind(self, SemanticAnnotator)

        literal_type = case node.type
          when :NUMBER then Type.new(:Float64)
          when :INT64 then Type.new(:Int64)
          when :STRING
            # SIMP-13f: stamp storage_override so Locatable#rodata_provenance? returns
            # true without needing the type.provenance fallback.
            if node.storage == :stack
              node.storage = :rodata
              Type.new(:"Byte[#{node.value.length}]", location: :rodata)
            else
              node.storage = :rodata
              Type.new(Type::STRING_TYPE, location: :rodata)
            end
          when :SYMBOL
            # Symbol literals: compile-time interned, static lifetime, O(1) equality by pointer.
            node.storage = :rodata
            Type.new(Type::STRING_TYPE, sync: :symbol, location: :rodata)
          when :BYTE, :PREFIXED_INT then Type.new(:Byte)  # Default; overflows checked after coercion context is known
          when :INT8    then Type.new(:Int8)
          when :INT16   then Type.new(:Int16)
          when :INT32   then Type.new(:Int32)
          when :UINT16  then Type.new(:UInt16)
          when :UINT32  then Type.new(:UInt32)
          when :UINT64  then Type.new(:UInt64)
          when :FLOAT32 then Type.new(:Float32)
          when :BOOLEAN then Type.new(:Bool)
          when :NIL then Type.new(:NIL)
          else
            error!(node, :UNKNOWN_LITERAL)
            Type.new(:Any)
          end
        stamp_type!(node, literal_type)
      end

      sig { params(node: AST::DefaultLit).returns(Symbol) }
      def visit_DefaultLit(node)
        T.bind(self, SemanticAnnotator)

        # Resolved type is set by declare_and_verify_params / visit_StructLit context.
        # Standalone DEFAULT is not valid; callers validate the context.
        stamp_type!(node, :Any)
      end

      sig { params(node: AST::BinaryOp).returns(T.nilable(T.any(Type, Symbol, Integer))) }
      def visit_BinaryOp(node)
        T.bind(self, SemanticAnnotator)

        # Special operators that need custom handling
        case node.op
        when :SMOOTH then return visit_Smooth(node)
        when :BIND_VAR then return visit_BindVar(node)
        when :OR_ELSE then return visit_OrElse(node)
        end

        # Standard binary operations - visit children first
        visit(node.left)
        visit(node.right)
        promote_to_expr_if!(node, node.left) if node.left.is_a?(AST::IfStatement)
        promote_to_expr_match!(node, node.left) if node.left.is_a?(AST::MatchStatement)
        promote_to_expr_if!(node, node.right) if node.right.is_a?(AST::IfStatement)
        promote_to_expr_match!(node, node.right) if node.right.is_a?(AST::MatchStatement)
        validate_predicate_purity! if current_predicate_context

        # Delegate type resolution to Type class
        left_type = node.left.full_type!(context: "binary left")
        right_type = node.right.full_type!(context: "binary right")
        if node.op == :AND || node.op == :OR
          validate_logical_presence_operand!(node.left, left_type, node.op)
          validate_logical_presence_operand!(node.right, right_type, node.op)
        end
        logical_presence = (node.op == :AND || node.op == :OR) &&
          (Type.new(left_type).optional? || Type.new(right_type).optional?)
        result = logical_presence ? BinaryOpResult.new(type: Type.new(:Bool)) : Type.binary_op(node.op, left_type, right_type)

        if result.error
          error!(node, :TYPE_ERROR_GENERIC, detail: result.error)
        end

        stamp_type!(node, result.type)
        node.left.coerced_type = result.left_coercion if result.left_coercion
        node.right.coerced_type = result.right_coercion if result.right_coercion
        node.storage = result.storage if result.storage

        # String concat (+) transpiles to std.mem.concat(rt.frameAlloc(), ...) —
        # mark as frame allocation so needs_rt and loop mark elision are correct.
        if node.op == :ADD && (left_type.string? || right_type.string?)
          node.string_concat = true
          current_fn_ctx&.record_frame_use!
          # String concat result is frame-allocated.
          node.storage = :frame
          ti = node.full_type!(context: "binary result")
          ti.mark_frame_allocated! if ti.is_a?(Type)
        end
        result.type
      end

      sig { params(operand: AST::Node, operand_type: Type, op: Symbol).void }
      def validate_logical_presence_operand!(operand, operand_type, op)
        ti = Type.new(operand_type)
        return unless ti.optional?
        return unless T.must(ti.wrapped_type).resolved == :Bool

        fixes = T.let([], T::Array[Fix])
        if operand.is_a?(AST::Identifier)
          token = operand.token
          span = Span.new(file: nil, line: token.line, col: token.column, length: operand.name.length)
          fixes << Fix.new(
            description: "Test whether the optional Bool is present with `#{operand.name} EXISTS`.",
            confidence: :interactive,
            edits: [Edit.new(span: span, replacement: "#{operand.name} EXISTS")]
          )
          fixes << Fix.new(
            description: "Use the Bool payload, defaulting NIL to FALSE, with `(#{operand.name} OR_ELSE FALSE)`.",
            confidence: :interactive,
            edits: [Edit.new(span: span, replacement: "(#{operand.name} OR_ELSE FALSE)")]
          )
        end
        fixable!(operand,
          code: :AMBIGUOUS_OPTIONAL_BOOL_LOGIC,
          op: op,
          category: :type,
          level: :error,
          fixes: fixes)
      end

      sig { params(node: AST::Placeholder).returns(T.nilable(SymbolEntry)) }
      def visit_Placeholder(node)
        T.bind(self, SemanticAnnotator)

        # Just resolve it like an identifier
        result = visit_Identifier(AST::Identifier.new(node.token, "_"))
        result if result.is_a?(SymbolEntry)
      end

      # =========================================================
      # BIND VAR (AS / @)
      # =========================================================
      sig { params(node: AST::BinaryOp).returns(Type) }
      def visit_BindVar(node)
        T.bind(self, SemanticAnnotator)

        # Logic: expression AS @name
        # The value flows through, but we declare a new variable in the scope.

        visit(node.left)
        lhs_type = node.left.full_type!(context: "bind left")

        # node.right is the Identifier for the new variable
        var_name = node.right.name

        # When binding a collection source (users AS $u), $u refers to each *element*,
        # not the collection. Subsequent $u.field accesses need the element type.
        # collection_value? covers declared collections plus plain non-string arrays.
        lhs_ti = Type.new(lhs_type)
        binding_type = if lhs_ti.collection_value? && lhs_ti.element_type
          lhs_ti.element_type.to_s
        else
          lhs_type
        end

        # Register in scope (Immutable, Stack storage)
        current_scope.declare(
          var_name,
          nil,
          binding_type,
          false, # Immutable
          false, # Not rebindable
          nil,
          :stack
        )

        # The bound identifier ($u) IS the per-element binding — type it
        # exactly as it was declared (binding_type), not a guess.
        stamp_type!(node.right, binding_type)

        # The result of the operation is the collection itself (passthrough for pipeline)
        stamp_type!(node, lhs_type)
      end

      sig { params(node: AST::CapabilityWrap).returns(T.nilable(Type)) }
      def visit_CapabilityWrap(node)
        T.bind(self, SemanticAnnotator)

        visit(node.value)

        base_type = node.value.resolved_type  # e.g. :Node
        ti = Type.new(base_type)

        # Primitive types (Int64, Number, Bool, Byte, Float64) cannot have capabilities.
        # Wrapping a primitive in @local/@locked/@shared creates a heap pointer to a
        # value you can't meaningfully dereference.  Wrap in a STRUCT instead.
        #
        # Exception: @shared:atomic IS the primitive-as-cell case — the whole point
        # of an atomic primitive is the bare-cell form (Int64@shared:atomic =
        # AtomicInt64). The annotator validates that @atomic is only applied to
        # types the runtime supports (Int64, Float64, Bool, sized variants); other
        # primitives error.
        is_atomic_primitive = node.atomic? && !node.indirect?

        # `@indirect:atomic` is the struct-as-AtomicPtr form. Reject it on
        # primitives before the generic primitive-capability error so the
        # diagnostic can name the right migration path.
        if ti.primitive? && node.atomic_ptr?
          error!(node, :INDIRECT_ATOMIC_PRIMITIVE, type: base_type)
        end

        if ti.primitive? && !is_atomic_primitive && node.capability?
          cap_name = node.sync || node.ownership || node.layout
          error!(node, :CAPABILITY_ON_PRIMITIVE,
            cap: cap_name,
            type: base_type)
        end

        # Struct atomics need AtomicPtr snapshot semantics; direct atomic ops only
        # make sense for CAS-sized primitive cells.
        if !ti.primitive? && node.atomic? && !node.indirect?
          error!(node, :STRUCT_ATOMIC_NEEDS_INDIRECT, type: base_type)
        end

        # AtomicPtr is cross-thread by design; @local is pointless and
        # @multiowned's Rc backing is not thread-safe.
        if node.atomic_ptr?
          if node.ownership == :local
            error!(node, :LOCAL_INDIRECT_ATOMIC)
          elsif node.multiowned?
            error!(node, :MULTIOWNED_INDIRECT_ATOMIC)
          end
        end

        ti.apply_declared_type_capabilities!(
          ownership: node.ownership,
          sync: node.sync,
          lock_rank: node.lock_rank,
          layout: node.layout
        )
        # AtomicPtr implies shared ownership because escaping the declaring
        # scope is the point of the construct; local and multiowned cases were
        # rejected above.
        if node.atomic_ptr? && !node.ownership
          ti.apply_reference_ownership!(:shared)
        end
        # @indirect forces heap location (same as @local, but different intent).
        ti.pin_heap_for_indirect!       if node.indirect?

        # Lock ranks induce a total order only if every declaration of a type
        # uses the same rank.
        if node.lock_rank && node.locked_sync?
          record_lock_type_rank!(ti.base_type, node.lock_rank, node)
        end

        # CapabilityWrap always allocates on the heap.
        if node.ownership || node.sync || node.layout
          current_fn_ctx&.record_heap_use!
          current_fn_ctx&.record_alloc_use!
          current_fn_ctx&.mark_runtime_used!
          record_effect(EffectTracker::HEAP)
        end

        # Store the Type directly — full_type= accepts Type objects
        stamp_type!(node, ti)
      end

      sig { params(node: AST::OptionalUnwrap).returns(Type) }
      def visit_OptionalUnwrap(node)
        T.bind(self, SemanticAnnotator)

        visit(node.target)

        # Validate that the target is actually an optional type
        type = node.target.full_type!(context: "optional unwrap target")
        unless type&.optional?
          error!(node, :UNWRAP_NON_OPTIONAL, got: node.target.resolved_type)
        end

        # The result type is the wrapped type (without the ?)
        # Preserve ownership/sync so Rc/Arc auto-deref works on the unwrapped value.
        unwrapped = type.wrapped_type
        result = Type.new(T.must(unwrapped))
        result.merge_capabilities_from!(type, include_affine_ownership: true)
        stamp_type!(node, result)
      end

      # Returns the Type of the last value-producing expression in a branch body,
      # or nil if the branch doesn't end with a usable expression.
      # Used to determine whether an IF/MATCH node can be promoted to expression mode.
      sig { params(branch: T::Array[AST::Node]).returns(T.nilable(Type)) }
      def expr_result_type(branch)
        T.bind(self, SemanticAnnotator)

        return nil if branch.empty?
        last = branch.last
        # ELSE_IF chain: the last element is a nested IfStatement — use its result type
        if last.is_a?(AST::IfStatement)
          return last.then_result_type
        end
        return nil unless last.is_a?(AST::Locatable)
        ti = last.full_type!(context: "branch result")
        return ti if ti.resolved == :NoReturn
        return nil if ti.void?
        # These are statement-level constructs, not value-producing expressions
        return nil if AST.statement_result_void?(last)
        ti
      end

      # Promotes an AST::IfStatement that is used in expression position
      # (value of a VarDecl, BindExpr, ReturnNode, or FuncCall arg).
      # Sets expr_mode = true and full_type = result_type if valid; errors otherwise.
      sig { params(parent_node: AST::Node, if_node: AST::IfStatement).returns(T.nilable(Type)) }
      def promote_to_expr_if!(parent_node, if_node)
        T.bind(self, SemanticAnnotator)

        # Recursively promote ELSE_IF chains first
        if if_node.else_branch&.length == 1 && (nested = if_node.else_branch.first).is_a?(AST::IfStatement)
          promote_to_expr_if!(if_node, nested)
          else_result = nested.full_type!(context: "nested expression if result")
        else
          else_result = if_node.else_result_type
        end

        then_result = if_node.then_result_type

        unless then_result
          error!(if_node, :IF_EXPR_THEN_NEEDS_VALUE)
        end
        unless else_result
          if if_node.else_branch.nil? || if_node.else_branch.empty?
            error!(if_node, :IF_EXPR_NEEDS_ELSE)
          else
            error!(if_node, :IF_EXPR_ELSE_NEEDS_VALUE)
          end
        end
        unless then_result && else_result
          fallback = Type.new(:Any)
          if_node.expr_mode = true
          stamp_type!(if_node, fallback)
          return fallback
        end

        branch_types = [then_result, else_result]
        value_types = branch_types.reject { |type| type.resolved == :NoReturn }
        result_type = merged_expression_branch_type(branch_types)
        compare_types = value_types.map { |type| expression_branch_compare_type(type) }
        unless result_type || compare_types.length <= 1 || compare_types[0] == compare_types[1] || compare_types.include?(:Any)
          error!(if_node, :IF_EXPR_BRANCHES_INCOMPATIBLE, then_type: compare_types[0], else_type: compare_types[1])
        end

        result_type ||= value_types.find { |type| !type.any? } || value_types.first || then_result
        unless result_type.implicitly_copyable? { |t| lookup_type_schema(t) }
          error!(if_node, :IF_EXPR_RESULT_NOT_COPYABLE, type: result_type.resolved)
        end

        if_node.expr_mode = true
        stamp_type!(if_node, (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type)
      end

      # Promotes an AST::MatchStatement that is used in expression position.
      sig { params(parent_node: AST::Node, match_node: AST::MatchStatement).returns(T.nilable(Type)) }
      def promote_to_expr_match!(parent_node, match_node)
        T.bind(self, SemanticAnnotator)

        case_types = match_node.case_result_types || []
        default_type = match_node.default_result_type

        # All case bodies must produce values
        case_types.each_with_index do |t, i|
          unless t
            error!(match_node, :MATCH_EXPR_BRANCH_NEEDS_VALUE)
          end
        end

        # PARTIAL MATCH expressions must have a DEFAULT branch -- without
        # one a non-exhaustive match leaves the result undefined for missing
        # variants. Plain MATCH is exhaustive by construction (annotator
        # already verified all variants are covered) so the implicit return
        # value is always defined.
        if !default_type && !match_node.exhaustive
          error!(match_node, :PARTIAL_MATCH_EXPR_NEEDS_DEFAULT)
        end

        all_types = case_types.compact
        all_types << default_type if default_type

        if all_types.empty?
          error!(match_node, :MATCH_EXPR_NEEDS_CASE)
          fallback = Type.new(:Any)
          match_node.expr_mode = true
          stamp_type!(match_node, fallback)
          return fallback
        end

        result_type = merged_expression_branch_type(all_types)
        value_types = all_types.reject { |t| t.resolved == :NoReturn }
        resolved_types = value_types.map { |t| expression_branch_compare_type(t) }.uniq.reject { |t| t == :Any }
        if !result_type && resolved_types.size > 1
          error!(match_node, :MATCH_EXPR_BRANCHES_INCOMPATIBLE, types: resolved_types.join(', '))
        end

        result_type ||= value_types.first || all_types.first
        unless result_type.implicitly_copyable? { |t| lookup_type_schema(t) }
          error!(match_node, :MATCH_EXPR_RESULT_NOT_COPYABLE, type: result_type.resolved)
        end

        match_node.expr_mode = true
        stamp_type!(match_node, (result_type.string? && !result_type.symbol?) ? Type.new(:String, location: :rodata) : result_type)
      end
      private :collect_implicit_type_params

      sig { params(type: Type).returns(Symbol) }
      def expression_branch_compare_type(type)
        type.string? ? :String : type.resolved
      end

      sig { params(types: T::Array[Type]).returns(T.nilable(Type)) }
      def merged_expression_branch_type(types)
        value_types = types.reject { |type| type.resolved == :NoReturn }
        return Type.new(:NoReturn) if value_types.empty?

        concrete = value_types.reject { |type| type.resolved == :NIL || type.any? }
        nil_seen = concrete.length != value_types.reject(&:any?).length
        return nil unless nil_seen && concrete.any?
        compare_types = concrete.map { |type| expression_branch_compare_type(type) }.uniq
        return nil unless compare_types.length == 1

        Type.optional_of(concrete.first)
      end
      private :expression_branch_compare_type, :merged_expression_branch_type

end
  end
end
