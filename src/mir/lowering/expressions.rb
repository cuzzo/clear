# typed: strict
require "sorbet-runtime"

module MIRLoweringExpressions
    extend T::Sig
    extend T::Helpers

  requires_ancestor { MIRLowering }

  sig { params(node: AST::Literal).returns(T.untyped) }
  def lower_literal(node)
    T.bind(self, MIRLowering) rescue nil
    case node.type
    when :STRING, :SYMBOL
      escaped = node.value.bytes.map { |b|
        case b
        when 0x5C then '\\\\'
        when 0x22 then '\\"'
        when 0x0A then '\\n'
        when 0x0D then '\\r'
        when 0x09 then '\\t'
        when 0x00 then '\\x00'
        when 0x80..0xFF then "\\x#{'%02x' % b}"
        else b.chr
        end
      }.join
      MIR::Lit.new("\"#{escaped}\"")
    when :NUMBER
      if node.coerced_type == :Int64
        MIR::Lit.new(node.value.to_i.to_s)
      else
        s = node.value.to_s
        s = "#{s}.0" if node.value == node.value.to_i && !s.include?('.')
        MIR::Lit.new(s)
      end
    when :INT64    then MIR::Lit.new(node.value.to_s)
    when :INT8     then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "i8", :as)
    when :INT16    then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "i16", :as)
    when :INT32    then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "i32", :as)
    when :UINT16   then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "u16", :as)
    when :UINT32   then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "u32", :as)
    when :UINT64   then MIR::Cast.new(MIR::Lit.new(node.value.to_s), "u64", :as)
    when :FLOAT32
      s = node.value.to_s
      s = "#{s}.0" if node.value == node.value.to_i && !s.include?('.')
      MIR::Cast.new(MIR::Lit.new(s), "f32", :as)
    when :BOOLEAN  then MIR::Lit.new(node.value.to_s)
    when :NIL      then MIR::Lit.new("null")
    else
      MIR::Lit.new(node.value.to_s)
    end
  end

  sig { params(node: AST::Identifier).returns(T.untyped) }
  def lower_identifier(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @atomic_emit_raw = T.let(@atomic_emit_raw, T.untyped)
    @decl_zig_name_map = T.let(@decl_zig_name_map, T.untyped)
    @do_capture_map = T.let(@do_capture_map, T.untyped)
    @locked_unwrap_map = T.let(@locked_unwrap_map, T.untyped)
    @rc_unwrap_map = T.let(@rc_unwrap_map, T.untyped)
    # Pipeline bindings ($u, $v, $item, ...) are substituted by PipelineHost
    # before reaching the MIR lowering. If one arrives here it means it was
    # used outside its pipeline context (after the pipeline expression ended,
    # or in a pipeline that doesn't have a matching AS declaration).
    if node.name.match?(/\A\$[a-z]/)
      line = node.token&.line || "?"
      raise "line #{line}: Undefined pipeline binding '#{node.name}'. " \
            "Pipeline bindings must be declared with 'AS #{node.name}' " \
            "in the same pipeline expression where they are used."
    end

    return MIR::FnRef.new(zig_safe_name(node.name)) if node.respond_to?(:fn_ref) && node.fn_ref

    # Inside a WITH block, use the unwrapped inner alias instead of the Rc handle
    rc_map = @rc_unwrap_map || {}
    return MIR::Ident.new(rc_map[node.name]) if rc_map.key?(node.name)

    # Inside a WITH EXCLUSIVE block, rewrite original var name to the unwrapped inner alias
    locked_map = @locked_unwrap_map || {}
    alias_name = locked_map[node.name]
    return MIR::Ident.new(alias_name) if alias_name.is_a?(String)

    # Inside a DO block branch, access captured outer variables via ctx pointer
    capture_map = @do_capture_map || {}
    if capture_map.key?(node.name)
      ident = MIR::Ident.new(capture_map[node.name])
      if node.symbol&.atomic? && !@atomic_emit_raw && !node.atomic_borrow && node.symbol&.layout != :indirect
        return MIR::MethodCall.new(ident, "load", [], false, MIR::CallableContract.no_ownership(0))
      end
      return ident
    end

    # Use disambiguated Zig name if the declaration was renamed to avoid
    # same-name collision in the MIR checker (see lower_var_decl).
    decl_node = node.symbol&.reg
    zig_name = (@decl_zig_name_map && decl_node && @decl_zig_name_map[decl_node.object_id]) ||
               zig_safe_name(node.name)
    ident = MIR::Ident.new(zig_name)

    # Atomic reads normally lower to `.load()`, but raw emission and
    # atomic-borrow call sites need the cell reference itself.
    if node.symbol&.atomic? && !@atomic_emit_raw
      return ident if node.atomic_borrow
      # AtomicPtr reads go through WITH SNAPSHOT; the bare identifier is the
      # cell pointer and AtomicPtr has no `.load()` method.
      if node.symbol&.indirect?
        return ident
      end
      # Dereference bare atomic cells before loading; AtomicPtr reads use the
      # snapshot path above.
      return MIR::MethodCall.new(MIR::Deref.new(ident), "load", [], false, MIR::CallableContract.no_ownership(0))
    end

    # Loop-carry string: identifier was marked for heap dupe at the use site
    # (frame string being assigned to a heap-carry outer variable).
    return MIR::DupeSlice.new(ident, :heap) if node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
    ident
  end

  sig { params(node: AST::UnaryOp).returns(MIR::UnaryOp) }
  def lower_unary_op(node)
    T.bind(self, MIRLowering) rescue nil
    right = lower(node.right)
    case node.op
    when :NOT, "!" then MIR::UnaryOp.new("!", right)
    when :SUB, "-" then MIR::UnaryOp.new("-", right)
    when :BITWISE_NOT, "~" then MIR::UnaryOp.new("~", right)
    else raise "MIRLowering: unknown unary op #{node.op}"
    end
  end

  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def lower_binary_op(node)
    T.bind(self, MIRLowering) rescue nil
    # Pipeline operator: x |> f -> f(x), or complex pipeline ops
    return lower_smooth(node) if node.op == :SMOOTH

    # Error chain: expr OR handler
    return lower_or_rescue(node) if node.op == :OR_RESCUE

    # Named pipeline binding (AS $v): passthrough to LHS value.
    # The $v registration is handled by the pipeline host at the binding point.
    return lower(node.left) if node.op == :BIND_VAR

    # String concat (2-part) uses std.mem.concat
    if node.string_concat
      left = hoist_alloc(lower(node.left), node.left)
      right = hoist_alloc(lower(node.right), node.right)
      alloc = alloc_for_node(node)
      return MIR::ConcatStr.new([left, right], alloc, nil)
    end

    left = lower(node.left)
    right = lower(node.right)

    # Power operator
    if node.op == :POW
      left_type = node.left.full_type
      resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
      type_arg = resolved == :Int64 ? "i64" : "f64"
      return MIR::Call.new("std.math.pow", [MIR::Ident.new(type_arg), left, right], false)
    end

    # Modulo on signed int — routed through the builtin registry so the :bc
    # target can dispatch to MOD_I64 via MIR::InlineBc instead of parsing a
    # "@mod" callee string at codegen time.
    if node.op == :MOD
      left_type = node.left.full_type
      resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
      if resolved == :Int64
        return emit_builtin(:intMod, [left, right])
      end
    end

    # String comparison
    if Type.new(node.left.full_type).string? || Type.new(node.right.full_type).string?
      left_ti  = Type.new(node.left.full_type)
      right_ti = Type.new(node.right.full_type)

      # Symbol == symbol: O(1) pointer+length comparison. No allocation possible,
      # so no hoist_alloc needed. Falls through to content comparison if either
      # side is a plain string (cross-type comparison stays correct).
      if left_ti.symbol? && right_ti.symbol?
        cmp_node = case node.op
              when :EQ  then emit_builtin(:symbolEql, [left, right])
              when :NEQ then MIR::UnaryOp.new("!", emit_builtin(:symbolEql, [left, right]))
              end
        return cmp_node if cmp_node
      end

      # General string comparison: hoist allocating sub-expressions so heap strings get cleanup.
      # (e.g. ASSERT f() == "x" -- f() returns a heap string that needs freeing)
      left = place_value_for_destination(left, node.left, :heap, node.left.full_type) if node.left.is_a?(AST::BinaryOp) && node.left.op == :OR_RESCUE
      right = place_value_for_destination(right, node.right, :heap, node.right.full_type) if node.right.is_a?(AST::BinaryOp) && node.right.op == :OR_RESCUE
      left = hoist_alloc(left, node.left)
      right = hoist_alloc(right, node.right)
      cmp_node = case node.op
            when :EQ  then emit_builtin(:eql, [left, right])
            when :NEQ then MIR::UnaryOp.new("!", emit_builtin(:eql, [left, right]))
            when :LT  then MIR::BinOp.new("<",  emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            when :LTE then MIR::BinOp.new("<=", emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            when :GT  then MIR::BinOp.new(">",  emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            when :GTE then MIR::BinOp.new(">=", emit_builtin(:strcmp, [left, right]), MIR::Lit.new("0"))
            end
      return cmp_node if cmp_node
    end

    # Integer division — same rationale as :MOD above (registry instead of
    # raw "@divTrunc" callee string).
    if node.op == :DIV
      left_ti = node.left.full_type
      right_ti = node.right.full_type
      if left_ti&.integer? && right_ti&.integer?
        return emit_builtin(:intDiv, [left, right])
      end
    end

    # Wrapping operators
    if %i[WRAP_ADD WRAP_SUB WRAP_MUL].include?(node.op)
      fn = { WRAP_ADD: :wrapAdd, WRAP_SUB: :wrapSub, WRAP_MUL: :wrapMul }[node.op]
      return emit_builtin(fn, [left, right])
    end

    # Checked operators
    if %i[CHECK_ADD CHECK_SUB CHECK_MUL].include?(node.op)
      fn = { CHECK_ADD: :checkAdd, CHECK_SUB: :checkSub, CHECK_MUL: :checkMul }[node.op]
      return emit_builtin(fn, [left, right])
    end

    # Default integer arithmetic: checked in debug
    if %i[ADD SUB MUL].include?(node.op)
      left_ti = node.left.full_type
      right_ti = node.right.full_type
      left_is_comptime = node.left.is_a?(AST::Literal) && node.left.type == :NUMBER && !left_ti&.integer?
      right_is_comptime = node.right.is_a?(AST::Literal) && node.right.type == :NUMBER && !right_ti&.integer?
      both_int = left_ti&.integer? && right_ti&.integer?
      no_lits = !left_is_comptime && !right_is_comptime
      no_float_coerce = !node.left.respond_to?(:coerced_type) || node.left.coerced_type.nil? || Type.new(node.left.coerced_type).integer?
      no_float_coerce &&= !node.right.respond_to?(:coerced_type) || node.right.coerced_type.nil? || Type.new(node.right.coerced_type).integer?
      if both_int && no_lits && no_float_coerce
        fn = { ADD: :intAdd, SUB: :intSub, MUL: :intMul }[node.op]
        return emit_builtin(fn, [left, right])
      end
    end

    # Union value compared to a unit variant: Zig's `==` doesn't work on
    # tagged unions, so we lower to `std.meta.activeTag(<v>) == .<Variant>`.
    # This is the only EQ shape we structurally accept on unions; comparing
    # two arbitrary union values is ambiguous (which payload field counts?)
    # and Refuse below points users at MATCH, which CLEAR already supports.
    if %i[EQ NEQ].include?(node.op)
      lhs_uv = unit_variant_access(node.left)
      rhs_uv = unit_variant_access(node.right)
      if lhs_uv && !rhs_uv
        op_str = node.op == :EQ ? "==" : "!="
        tag_call = MIR::Call.new("std.meta.activeTag", [right], false)
        return MIR::BinOp.new(op_str, tag_call, MIR::Lit.new(".#{lhs_uv[1]}"))
      elsif rhs_uv && !lhs_uv
        op_str = node.op == :EQ ? "==" : "!="
        tag_call = MIR::Call.new("std.meta.activeTag", [left], false)
        return MIR::BinOp.new(op_str, tag_call, MIR::Lit.new(".#{rhs_uv[1]}"))
      end
    end

    # Refuse: any EQ/NEQ where either side is a union/struct value that
    # Zig's `==` doesn't accept. Falling through to `MIR::BinOp("==", ...)`
    # would emit a Zig error the user can't easily map back to their
    # CLEAR source. Raise a CLEAR-level diagnostic instead, naming the
    # type and pointing at MATCH (the canonical CLEAR pattern for
    # discriminating tagged values).
    if %i[EQ NEQ].include?(node.op)
      left_ti = node.left.full_type
      right_ti = node.right.full_type
      left_resolved = left_ti.is_a?(Type) ? left_ti.resolved : (left_ti && Type.new(left_ti.to_s).resolved)
      right_resolved = right_ti.is_a?(Type) ? right_ti.resolved : (right_ti && Type.new(right_ti.to_s).resolved)
      union_lhs = left_resolved && @union_schemas&.key?(left_resolved)
      union_rhs = right_resolved && @union_schemas&.key?(right_resolved)
      if union_lhs || union_rhs
        type_name = union_lhs ? left_resolved : right_resolved
        raise "BinaryOp #{node.op} on union '#{type_name}': Zig `==` does not " \
              "work on tagged unions. Either compare against a unit variant " \
              "(e.g. `s == #{type_name}.Variant`) -- which lowers to " \
              "std.meta.activeTag(s) == .Variant -- or use a MATCH expression " \
              "to discriminate the active variant.\n" \
              "(See transpile-tests/255_union_equality.cht.)"
      end
    end

    # Standard operators
    op_str = ZigTypeMapper::ZIG_OPS[node.op]
    raise "MIRLowering: unknown binary op #{node.op}" unless op_str
    MIR::BinOp.new(op_str, left, right)
  end

  # Returns [union_type_name, variant_name] when `node` is a unit-variant
  # access on a known union (e.g. `Status.Active` -> [:Status, "Active"]),
  # otherwise nil. Used by lower_binary_op to lower
  # `union_value == Type.Variant` to std.meta.activeTag.
  sig { params(node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def unit_variant_access(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @union_schemas = T.let(@union_schemas, T.untyped)
    return nil unless node.is_a?(AST::GetField)
    return nil unless node.target.is_a?(AST::Identifier)
    type_name = node.target.name.to_sym
    schema = @union_schemas&.dig(type_name)
    return nil unless schema.is_a?(Schemas::UnionSchema)
    var_data = schema.variants[node.field]
    return nil unless schema.variants.key?(node.field)
    # Unit variants have nil / Symbol / Type variant data. Inline-struct
    # variants are Hashes with :kind => :inline_struct; payload variants
    # like `Idle: Int64` are Symbols/Types -- both could appear at this
    # AST shape, but only the no-payload `.Active` form binds with a
    # bare GetField. Inline-struct construction goes through StructLit;
    # payload variant construction goes through MethodCall. Bare
    # GetField on a payload-having variant is invalid CLEAR (annotator
    # would have raised).
    return nil if Schemas.inline_struct?(var_data)
    [type_name, node.field]
  end

  # ================================================================
  # Pipeline (SMOOTH) operator
  # ================================================================

  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def lower_smooth(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    @current_fn_has_catch = T.let(@current_fn_has_catch, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    rhs = node.right

    # Complex pipeline ops that survived PipelineRewriter (pool/sharded/SOA
    # sources, OrderByOp, IndexOp, WindowOp, JoinOp, ConcurrentOp).
    # All decisions are made here in lowering.
    complex_ops = [
      AST::SelectOp, AST::WhereOp, AST::IndexOp, AST::ReduceOp,
      AST::OrderByOp, AST::LimitOp, AST::UnnestOp, AST::DistinctOp,
      AST::EachOp, AST::FindOp, AST::AnyOp, AST::AllOp,
      AST::CountOp, AST::SumOp, AST::AverageOp, AST::MinOp, AST::MaxOp,
      AST::TakeWhileOp, AST::WindowOp, AST::BatchWindowOp, AST::JoinOp,
      AST::TapOp, AST::SkipOp, AST::ShardOp, AST::ConcurrentOp
    ]
    if complex_ops.any? { |t| rhs.is_a?(t) }
      host = pipeline_host

      # Detect source type for pipeline IR metadata.
      source_type = node.left.is_a?(AST::RangeLit) ? :range : nil

      # Try MIR path first (migrated operators return MIR node tree)
      mir_result = host.lower_pipeline(node)
      if mir_result.is_a?(MIR::BlockExpr)
        mir_result.body = append_ownership_transfers_for_mir_body(mir_result.body)
      end
      return MIR::Pipeline.new(node, mir_result, source_type, nil, nil, nil) if mir_result

      raise "lower_smooth: unsupported pipeline op #{rhs.class}; legacy pipeline fallback has been removed"
    end

    # COLLECT: x |> COLLECT -> joins the observable + destroys the heap
    # allocation when `x` is an inline sub-expression (no binding owns
    # cleanup). When `x` is a named binding, the binding's
    # `:observable` cleanup entry handles destroy at scope exit;
    # COLLECT only needs to call .next() to read the final value.
    if rhs.is_a?(AST::CollectOp)
      left = lower(node.left)
      ft = node.left.full_type
      # Collection observable (DISTINCT producing `~T[]@set:observable`):
      # COLLECT must yield an owned ArrayList(T), not the StreamSetSnapshot
      # that `next()` returns. Mirrors lower_next_expr's collection branch
      # so `final = stream |> DISTINCT _ |> COLLECT` and `final = NEXT
      # (stream |> DISTINCT _)` produce the same shape.
      collect_method = (ft && ft.observable? && ft.tense_type&.array?) ? "materializeNext" : "next"
      # The materialized list is placed by the receiving binding's
      # allocator -- one allocator per binding.
      @current_decl_alloc = T.let(@current_decl_alloc, T.untyped)
      collect_alloc = @current_decl_alloc == :heap ? :heap : :frame
      collect_args = collect_method == "materializeNext" ?
        [MIR::AllocatorRef.new(collect_alloc)] : []
      named_source = node.left.is_a?(AST::Identifier)
      if named_source
        return MIR::MethodCall.new(left, collect_method, collect_args, true, MIR::CallableContract.no_ownership(collect_args.length))
      end
      inner_zig = ft && ft.tense? && ft.tense_type ? Type.new(ft.tense_type).zig_type : "i64"
      # The accumulator's Zig type comes from the observable's full_type
      # (e.g. *ObservableCount() / *ObservableSum(i64) / *ObservableMax(f64))
      # — `transpile_type` honors `observable_terminal` to pick the right
      # per-terminal wrapper. Hardcoding ObservableSum here breaks every
      # non-SUM terminal (COUNT/AVG/MIN/MAX/ANY/ALL/FIND/...).
      acc_zig = ft ? transpile_type(ft) : "*CheatLib.obs.ObservableSum(#{inner_zig})"
      @block_expr_counter += 1
      label = "__collect_blk_#{@block_expr_counter}"
      collect_var = "__collect_acc_#{@block_expr_counter}"
      val_var = "__collect_val_#{@block_expr_counter}"
      return MIR::BlockExpr.new(label, [
        MIR::Let.new(collect_var, left, false,
          acc_zig, nil),
        # Let Zig infer the View type — observable terminals expose
        # different View shapes per terminal (scalars expose T directly;
        # DISTINCT exposes StreamSetSnapshot(T); etc.). Hardcoding
        # `inner_zig` from `tense_type` only matches scalar terminals
        # and breaks DISTINCT/REDUCE-collection paths.
        MIR::Let.new(val_var,
          MIR::MethodCall.new(MIR::Ident.new(collect_var), collect_method, collect_args, true,
            MIR::CallableContract.no_ownership(collect_args.length)),
          false, nil, nil),
        MIR::ExprStmt.new(
          MIR::MethodCall.new(
            MIR::Ident.new(collect_var),
            "destroy",
            [MIR::AllocatorRef.new(:heap)],
            false,
            MIR::CallableContract.no_ownership(1)
          ),
          false
        ),
        MIR::BreakStmt.new(label, MIR::Ident.new(val_var))
      ])
    end

    # RecoverOp: x |> RECOVER(default) -> (x catch default)
    if rhs.is_a?(AST::RecoverOp)
      left = lower(node.left)
      default_val = lower(rhs.default_expr)
      return MIR::TryCatch.new(strip_try(left), default_val, nil)
    end

    # Simple pipe: x |> f -> f(x) or x |> f(y) -> f(x, y)
    left = lower(node.left)
    left_zig = emit_expr(left)

    # Capture snapshot for CATCH blocks: store LHS before the failable call
    snapshot_stmts = nil
    if @current_fn_has_catch
      lhs_type = node.left.full_type
      if lhs_type
        t = Type.new(lhs_type)
        unless t.void? || t.error_union?
          snap_zig_type = transpile_type(t)
          snapshot_stmts = [
            MIR::Let.new("__snap_input", left, false, nil, nil),
            MIR::ExprStmt.new(
              MIR::MethodCall.new(MIR::Ident.new(@rt_name), "captureSnapshot", [
                MIR::Ident.new(snap_zig_type),
                MIR::AddressOf.new(MIR::Ident.new("__snap_input"))
              ], false, MIR::CallableContract.no_ownership(2)), false)
          ]
          # Rewrite left to use the hoisted variable
          left = MIR::Ident.new("__snap_input")
        end
      end
    end

    call_mir = if rhs.is_a?(AST::Identifier)
      # x |> f -> f(x)
      synthetic = AST::FuncCall.new(rhs.token, rhs.name, [node.left])
      synthetic.full_type = node.full_type
      synthetic.storage = node.storage
      synthetic.zig_pattern = rhs.zig_pattern if rhs.zig_pattern
      lower_func_call(synthetic)
    elsif rhs.is_a?(AST::FuncCall)
      # x |> f(y) -> f(x, y)
      synthetic = AST::FuncCall.new(rhs.token, rhs.name, [node.left] + rhs.args)
      synthetic.full_type = node.full_type
      synthetic.storage = node.storage
      synthetic.zig_pattern = rhs.zig_pattern if rhs.zig_pattern
      synthetic.coerced_type = rhs.coerced_type if rhs.coerced_type
      lower_func_call(synthetic)
    else
      raise "MIRLowering: unhandled SMOOTH RHS #{rhs.class}"
    end

    if snapshot_stmts
      label = "__snap_blk"
      MIR::BlockExpr.new(label, snapshot_stmts + [MIR::BreakStmt.new(label, call_mir)])
    else
      call_mir
    end
  end

  # ================================================================
  # OR_RESCUE error chain
  # ================================================================

  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def lower_or_rescue(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @pending_stmts = T.let(@pending_stmts, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    @target = T.let(@target, T.untyped)
    t_left = Type.new(node.left.full_type)
    # CLEAR's auto-propagate strips `!T` from a fallible call's
    # full_type (so `x = call()` is x: T at the binding level). The
    # original `!T` is stashed on `error_union_type`. OR-RESCUE needs
    # to honor that to keep emitting `catch fallback` (error union)
    # rather than `orelse fallback` (optional).
    has_eu = node.left.respond_to?(:error_union_type) && node.left.error_union_type
    is_error = (t_left&.error_union?) ||
               (node.left.respond_to?(:can_fail) && node.left.can_fail) ||
               has_eu

    left = lower(node.left)

    # OR RAISE: bubble up error (Zig's try)
    if node.right.is_a?(AST::OrRaise)
      # Extern trampolines already propagate errors internally (if frame.err |e| return e).
      # Wrapping in TryExpr produces invalid `try { block }` — Zig's try takes an expression.
      return left if left.is_a?(MIR::InlineZig) && left.reason == "extern_trampoline"
      return MIR::TryExpr.new(strip_try(left)) if is_error
      return left
    end

    # OR EXIT <unified form>: selectively update kind / error_name /
    # message on rt.__error before propagating. Unspecified fields
    # inherit from whatever the failing call set. Kind-without-Type
    # clears the type explicitly (to avoid carrying a stale type
    # from the prior context that no longer matches the new kind).
    if node.right.is_a?(AST::OrExit)
      if is_error && @target == :bc
        # Register VM: structured sibling (no Zig text). One InlineBc
        # carries the reassignment; RETURN error.CheatError propagates
        # via the bc error-union (EGUARD / inline-exit).
        ex = node.right
        bc_kind = nil
        bc_name_id = nil
        bc_clear_type = false
        if ex.kind
          bc_kind = ex.kind.to_s
          if ex.error_name
            bc_name_id = AST.id_of_type(ex.error_name.to_sym)
          else
            bc_clear_type = true
          end
        elsif ex.error_name && AST.error_type?(ex.error_name.to_sym)
          bc_kind = AST.kind_of_type(ex.error_name.to_sym).to_s
          bc_name_id = AST.id_of_type(ex.error_name.to_sym)
        end
        msg_mir = ex.message ? lower(ex.message) : nil
        reassign = MIR::InlineBc.new(:or_exit, [msg_mir].compact, {
          kind: bc_kind, name_id: bc_name_id,
          clear_type: bc_clear_type, has_message: !ex.message.nil?,
          line: (node.token&.line || 0).to_i
        })
        catch_block = MIR::ScopeBlock.new([
          MIR::ExprStmt.new(reassign, false),
          MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError"))
        ])
        return try_catch_with_provenance(left, catch_block, "__exit_err")
      end

      if is_error
        rt_name = @rt_name
        ex = node.right
        line = node.token&.line || 0
        stmts = []

        if ex.kind
          stmts << MIR::InlineZig.new("#{rt_name}.__error.kind = .#{ex.kind}", "or_exit_kind")
          if ex.error_name
            stmts << MIR::InlineZig.new("#{rt_name}.__error.error_name = @intFromEnum(ErrorName.#{ex.error_name})", "or_exit_type")
          else
            stmts << MIR::InlineZig.new("#{rt_name}.__error.error_name = 0", "or_exit_clear_type")
          end
        elsif ex.error_name && AST.error_type?(ex.error_name.to_sym)
          # Type-only: the annotator seeded the registry; look up the kind.
          registered_kind = AST.kind_of_type(ex.error_name.to_sym)
          stmts << MIR::InlineZig.new("#{rt_name}.__error.kind = .#{registered_kind}", "or_exit_kind_from_type")
          stmts << MIR::InlineZig.new("#{rt_name}.__error.error_name = @intFromEnum(ErrorName.#{ex.error_name})", "or_exit_type")
        end

        if ex.message
          msg_zig = emit_expr(lower(ex.message))
          stmts << MIR::InlineZig.new("#{rt_name}.__error.message = #{msg_zig}", "or_exit_msg")
        end

        stmts << MIR::InlineZig.new("#{rt_name}.__error.clear_line = #{line}", "or_exit_line")
        stmts << MIR::ReturnStmt.new(MIR::Ident.new("__exit_err"))
        catch_block = MIR::ScopeBlock.new(stmts.map { |s| s.is_a?(MIR::ReturnStmt) ? s : MIR::ExprStmt.new(s, false) })
        return try_catch_with_provenance(left, catch_block, "__exit_err")
      end
      return left
    end

    # OR PASS: ignore error (Zig's catch undefined)
    if node.right.is_a?(AST::OrPass)
      return try_catch_with_provenance(left, or_pass_fallback(node.left), nil) if is_error
      return left
    end

    # OR BREAK: error-to-break (Zig's catch break)
    if node.right.is_a?(AST::OrBreak)
      return try_catch_with_provenance(left, MIR::Ident.new("break"), nil) if is_error
      return left
    end

    # OR PRUNE: same as OR PASS for now
    if node.right.is_a?(AST::OrPrune)
      return try_catch_with_provenance(left, or_pass_fallback(node.left), nil) if is_error
      return left
    end

    # Default: expr OR fallback -> error union catch or optional orelse.
    # The fallback is evaluated lazily (only when left short-circuits to it),
    # so any allocations done while lowering it must NOT escape to outer
    # @pending_stmts. AST::BinaryOp#lazy_fields declares :right as lazy when
    # op == :OR_RESCUE; descend() consults that and wraps the right side in
    # a MIR::BlockExpr containing the scoped pending stmts. Hot path: zero
    # allocation. Fallback path: dupes (auto-COPY etc.) happen inside the
    # block, only when actually entered.
    right = descend(node, :right)

    if is_error
      return try_catch_with_provenance(left, right, nil, fallback: right)
    end

    # Optional orelse
    MIR::Orelse.new(left, right)
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def or_pass_fallback(node)
    T.bind(self, MIRLowering) rescue nil
    ti = Type.from_node!(node, context: "OR fallback")
    ti = ti.payload_type || ti if ti.error_union?
    return MIR::Lit.new('@as([]const u8, "")') if ti.string?
    return MIR::Lit.new("@as(#{ti.zig_type}, .empty)") if ti.list_collection?
    MIR::Ident.new("undefined")
  end

  sig { params(node: AST::GetField).returns(T.untyped) }
  def lower_get_field(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @union_schemas = T.let(@union_schemas, T.untyped)
    # Union unit-variant constructor: Type{ .Variant = {} }
    if node.target.is_a?(AST::Identifier)
      schema = @union_schemas&.dig(node.target.name.to_sym)
      if schema.is_a?(Schemas::UnionSchema)
        var_data = schema.variants[node.field]
        unless Schemas.inline_struct?(var_data)
          return MIR::StructInit.new(node.target.name, [{ name: node.field.to_s, value: MIR::Lit.new("{}") }])
        end
      end
    end

    # Safe field access on any ?T: expr?.field
    # Always generate safe navigation so nil propagates instead of panicking.
    if node.target.is_a?(AST::OptionalUnwrap)
      inner_ti = Type.from_node!(node.target, context: "optional field target")  # T (unwrapped)
      inner_mir = lower(node.target.target)
      inner_sync = node.target.target.symbol&.sync
      field_expr = if inner_ti.multiowned? || inner_ti.shared? ||
                       inner_sync == :locked || inner_sync == :write_locked
        "_r.ctrl.data.#{node.field}"
      elsif inner_ti.frozen?
        "_r.#{node.field}"
      elsif inner_sync == :always_mutable
        "_r.data.#{node.field}"
      else
        "_r.#{node.field}"
      end
      return MIR::IfOptional.new(
        inner_mir, "_r",
        MIR::Ident.new(field_expr),
        MIR::Lit.new("null")
      )
    end

    target = lower(node.target)
    ti = Type.from_node!(node.target, context: "field target")

    # Rc/Arc: unwrap through .ctrl.data
    rc_map = @rc_unwrap_map || {}
    locked_map = @locked_unwrap_map || {}
    is_rc_unwrapped = node.target.is_a?(AST::Identifier) && rc_map.key?(node.target.name)
    is_locked_unwrapped = node.target.is_a?(AST::Identifier) && locked_map.key?(node.target.name)

    target_sync = node.target.symbol&.sync
    if (ti.multiowned? || ti.shared?) && !is_rc_unwrapped
      # target.ctrl.data.field
      ctrl = MIR::FieldGet.new(target, "ctrl")
      data = MIR::FieldGet.new(ctrl, "data")
      return MIR::FieldGet.new(data, node.field.to_s)
    elsif ti.frozen?
      # *const T auto-derefs in Zig — no _root needed
      return MIR::FieldGet.new(target, node.field.to_s)
    elsif (target_sync == :locked || target_sync == :write_locked) && !is_locked_unwrapped
      # target.ctrl.data.field
      ctrl = MIR::FieldGet.new(target, "ctrl")
      data = MIR::FieldGet.new(ctrl, "data")
      return MIR::FieldGet.new(data, node.field.to_s)
    elsif target_sync == :always_mutable && !is_locked_unwrapped
      # target.data.field
      data = MIR::FieldGet.new(target, "data")
      return MIR::FieldGet.new(data, node.field.to_s)
    end

    # Detect union-variant payload access: target has a union type and the
    # field name matches a declared variant. Emit MIR::UnionVariantGet so
    # bc_emitter / checker can dispatch on node class rather than name
    # matching (vs. plain struct-field access).
    target_type_sym = ti.resolved.to_s.to_sym
    union_schema = @union_schemas&.dig(target_type_sym)
    union_variants = Schemas.union?(union_schema) ? union_schema.variants : nil
    field_str = node.field.to_s
    if union_variants && (union_variants.key?(node.field) ||
                          union_variants.key?(field_str) ||
                          union_variants.key?(field_str.to_sym))
      return MIR::UnionVariantGet.new(target, field_str, ti.zig_type)
    end

    result = MIR::FieldGet.new(target, field_str)

    return MIR::Deref.new(result) if node.is_a?(AST::GetField) && node.indirect_field

    result
  end

  sig { params(node: AST::GetIndex).returns(T.untyped) }
  def lower_get_index(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @shard_context = T.let(@shard_context, T.untyped)
    @target = T.let(@target, T.untyped)
    target = lower(node.target)
    index = lower(node.index)
    ti = Type.from_node!(node.target, context: "index target")

    # Auto-deref Arc/Rc-wrapped maps: target.ctrl.data.*
    # Zig only -- BC has no Arc-wrapping (values are uniformly value-typed
    # and shared maps live as a single MapRef cell). Without this gate the
    # PUT path (which short-circuits the Arc deref for BC) and the GET
    # path use different identifiers; PUTs land in `map` while GETs read
    # from `Deref(map.ctrl.data)` and miss every entry.
    if ti.map? && (ti.shared? || ti.multiowned?) && @target != :bc
      target = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(target, "ctrl"), "data"))
    end

    if node.target.metatype == :hashmap
      target_var = node.target.is_a?(AST::Identifier) ? node.target.name : nil
      map_ft = Type.new(node.target.full_type)
      kind = map_ft.numeric_map? ? :numeric_map : :string_map
      op = INDEX_OPS.dig(kind, :get)

      # Structural MIR::ShardedMapGet for both backends. Carries the
      # full INDEX_OPS entry (templates, ownership effects) so the
      # checker can validate ownership semantics. shard_idx is set
      # only inside a SHARD pipeline body where the shard index var
      # is computed by the surrounding loop -- direct dispatch skips
      # routing.
      shard_direct = @shard_context && target_var == @shard_context[:map]
      template_kind = if shard_direct then :shard_direct_zig
                      elsif (map_ft.sharded? || map_ft.striped?) && op[:sharded_zig]
                        :sharded_zig
                      else :zig
                      end
      template = op[template_kind]
      resolved_allocs = {}
      [:alloc, :key_alloc, :val_alloc, :shard_alloc].each do |alloc_key|
        next unless template&.include?("{#{alloc_key}}")
        sym = op[alloc_key] || :heap
        resolved_allocs[alloc_key] = resolve_alloc_sym(sym, node.target, node)
      end
      key_zig = (kind == :numeric_map) ? map_ft.key_type.zig_type : nil
      val_zig = (kind == :numeric_map) ? map_ft.value_type.zig_type : nil
      if shard_direct
        return MIR::ShardedMapGet.new(target, index,
          MIR::Ident.new(@shard_context[:idx]),
          MIR::Ident.new(@shard_context[:key]),
          kind, op, key_zig, val_zig, resolved_allocs, template_kind)
      end
      MIR::ShardedMapGet.new(target, index, nil, nil, kind, op, key_zig, val_zig, resolved_allocs, template_kind)
    elsif ti.pool?
      # Both backends consume MIR::InlineBc(:get, [target, index], POOL_METHODS["get"]).
      # BC dispatches via compile_inline_bc :get on tag == :pool_method
      # (-> list-ref). Zig emits {0}.get({1}) from stdlib_def[:zig]. The
      # `elem` field carries the element type name so bc_emitter can
      # stamp the capture slot's struct hint when this gets bound via
      # `IF pool[id] AS env`.
      elem_t = (ti.is_a?(Type) ? ti : Type.new(ti)).element_type
      elem_name = elem_t.respond_to?(:resolved) ? T.must(elem_t).resolved.to_s : elem_t.to_s
      pool_get_def = T.must(IntrinsicRegistry.sig(POOL_METHODS, "get")).dup
      pool_get_def.emit = (pool_get_def.emit ? pool_get_def.emit.dup : IntrinsicEmit.new)
      pool_get_def.emit.elem = elem_name
      return MIR::InlineBc.new(:get, [target, index], pool_get_def)
    elsif ti.set_collection?
      # @set[item]: membership check — returns ?T (item if present, null otherwise)
      elem_zig = T.must((ti.is_a?(Type) ? ti : Type.new(ti)).element_type).zig_type
      emit_builtin(:setMemberGet, [target, index, MIR::Ident.new(elem_zig)])
    elsif node.needs_mut_ref
      # target.items[@as(usize, @intCast(index))]
      items = MIR::ListItems.new(target)
      cast_idx = MIR::Cast.new(index, "usize", :intCast)
      MIR::IndexGet.new(items, cast_idx)
    elsif ti && direct_indexable_collection_type?(ti)
      direct_index_get(target, index, node.target, ti) || begin
        builtin = INDEX_OPS.dig(ti.dispatch_key, :get, :builtin) || :getAt
        emit_builtin(builtin, [target, index])
      end
    else
      # Registry-driven: dispatch_key → INDEX_OPS get :builtin (string_raw → charAt,
      # array → getAt, etc.). Falls back to :getAt for unregistered types.
      builtin = INDEX_OPS.dig(ti.dispatch_key, :get, :builtin) || :getAt
      emit_builtin(builtin, [target, index])
    end
  end

  # Resolves field-name -> Type for both struct and union schemas. Returns {}
  # when no schema is registered (e.g. tuple-style literals) so callers can
  # safely lookup without nil checks.
  sig { params(node: AST::StructLit).returns(T::Hash[String, T.untyped]) }
  def struct_lit_field_types(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @schema_lookup = T.let(@schema_lookup, T.untyped)
    schema = @schema_lookup&.call(node.name.to_sym)
    return {} unless schema
    subst = struct_lit_type_subst(schema, node)
    if schema.respond_to?(:variants) && schema.variants
      schema.variants.each_with_object({}) { |(k, t), h| h[k.to_s] = substitute_mir_type(t, subst) }
    elsif schema.respond_to?(:fields) && schema.fields
      schema.fields.each_with_object({}) do |(k, f), h|
        raw = f.respond_to?(:type) ? f.type : f
        h[k.to_s] = substitute_mir_type(raw, subst)
      end
    else
      {}
    end
  end

  sig { params(schema: T.untyped, node: AST::StructLit).returns(T::Hash[Symbol, T.untyped]) }
  def struct_lit_type_subst(schema, node)
    params = schema.respond_to?(:type_params) ? schema.type_params : nil
    args = node.type_args || []
    return {} unless params&.any? && args.any?
    out = T.let({}, T::Hash[Symbol, T.untyped])
    params.zip(args).each do |param, arg|
      next unless param
      out[param.to_sym] = arg
    end
    out
  end

  sig { params(raw_type: T.untyped, subst: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
  def substitute_mir_type(raw_type, subst)
    return raw_type if subst.empty?
    t = raw_type.is_a?(Type) ? Type.new(raw_type) : Type.new(raw_type)
    resolved = t.resolved
    if subst.key?(resolved)
      replacement = Type.new(subst.fetch(resolved))
      copy_type_capabilities(t, replacement)
      return replacement
    end

    if t.generic_instance?
      new_args = t.generic_args.map { |arg| substitute_mir_type(arg, subst) }
      arg_names = new_args.map { |arg| generic_subst_source(arg) }.join(",")
      replacement = Type.new(:"#{t.generic_base}<#{arg_names}>")
      copy_type_capabilities(t, replacement)
      return replacement
    end

    str = resolved.to_s
    if str.end_with?("[]")
      inner = T.must(str[0..-3]).to_sym
      if subst.key?(inner)
        replacement = Type.new(:"#{subst.fetch(inner)}[]")
        copy_type_capabilities(t, replacement)
        return replacement
      end
    end

    if (prefix = str.match(/\A([!?~]+)/)&.[](1))
      inner = T.must(str[prefix.length..]).to_sym
      if subst.key?(inner)
        replacement = Type.new(:"#{prefix}#{subst.fetch(inner)}")
        copy_type_capabilities(t, replacement)
        return replacement
      end
    end

    raw_type
  end

  sig { params(type_obj: T.untyped).returns(String) }
  def generic_subst_source(type_obj)
    t = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    t.resolved.to_s
  end

  sig { params(source: Type, target: Type).void }
  def copy_type_capabilities(source, target)
    target.ownership = source.ownership if source.ownership != :affine
    target.sync = source.sync if source.sync
    target.layout = source.layout if source.layout
    target.elem_ownership = source.elem_ownership if source.elem_ownership
    target.elem_sync = source.elem_sync if source.elem_sync
  end

  # True when the destination is a dynamic slice (`[]T`, no capacity), as
  # opposed to a fixed-capacity array (`[N]T`) or an owning container
  # (`@list` / `@set` / `@pool`). Comptime selector handles ArrayList -> .items
  # vs slice passthrough at zero cost.
  sig { params(ft: T.untyped, k: T.untyped, node: AST::StructLit).returns(T::Boolean) }
  def struct_field_wants_slice?(ft, k, node)
    T.bind(self, MIRLowering) rescue nil
    return true if node.borrowed_field_names&.include?(k)
    return false unless ft.is_a?(Type)
    ft.array? && ft.dynamic? && !ft.collection? && !ft.string?
  end

  sig { params(node: AST::StructLit).returns(T.untyped) }
  def lower_struct_lit(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    hoisted = []
    field_types = struct_lit_field_types(node)
    struct_alloc = alloc_for_node(node)

    fields = node.fields.map { |k, v|
      ft = field_types[k.to_s]
      borrowed_field = !!node.borrowed_field_names&.include?(k.to_s)
      field_node = borrowed_field && v.is_a?(AST::CopyNode) ? v.value : v
      field_sink_alloc = aggregate_field_sink_alloc(ft, field_node, struct_alloc)
      move_mark_field!(field_node)
      val = with_decl_alloc(field_sink_alloc) do
        if borrowed_field
          lower(field_node)
        elsif rc_retain_needed?(field_node)
          make_rc_retain(field_node)
        elsif field_node.is_a?(AST::CopyNode) && ft.is_a?(Type) && ft.collection?
          hoist_alloc(MIR::DeepCopy.new(lower(field_node.value), nil, nil, :full_value, field_sink_alloc),
            field_node, err_cleanup: true, transfer_on_success: false)
        else
          field_value = materialize_owned_sink_value(lower(field_node), field_node, field_sink_alloc, ft)
          field_alloc = mir_owned_alloc(field_value)
          lowered = hoist_alloc(field_value, field_node, err_cleanup: true, transfer_on_success: false)
          if ft.is_a?(Type) && ft.recursive_cleanup_shape?(@schema_lookup) &&
             !ast_expr_produces_heap?(field_node) && field_alloc != field_sink_alloc
            hoist_alloc(MIR::DeepCopy.new(lowered, ft.zig_type, nil, :full_value, field_sink_alloc),
              field_node, err_cleanup: true, transfer_on_success: false)
          else
            lowered
          end
        end
      end
      if struct_field_wants_slice?(ft, k, node)
        val = MIR::ItemsAccess.new(val, true)
      end
      # @indirect field: hoist HeapCreate to a named temp so it is a Let-init,
      # not an anonymous sub-expression (INV-H).
      if v.needs_heap_create
        zig_t = transpile_type(v.full_type.resolved.to_s)
        @block_expr_counter += 1
        temp = "__ind_#{@block_expr_counter}_#{k}"
        hc = MIR::HeapCreate.new(zig_t, val, :heap, "blk_#{k}")
        mark = MIR::AllocMark.new(temp, :heap, nil)
        mark.scope = :heap
        hoisted << mark
        hoisted << MIR::Let.new(temp, hc, false, nil, nil)
        # errdefer cleans this field if a later allocation (another field or
        # the outer struct pointer) fails.
        hoisted << MIR::ErrDeferStmt.new(
          MIR::DestroyPtr.new(MIR::Ident.new(temp), :heap)
        )
        val = MIR::Ident.new(temp)
      end
      { name: k.to_s, value: val, alloc: field_sink_alloc }
    }

    type_name = if node.type_args&.any?
      zig_args = node.type_args.map { |a| Type.new(a.to_sym).zig_type }.join(", ")
      "#{node.name}(#{zig_args})"
    else
      node.name.to_s
    end

    init = MIR::StructInit.new(type_name, fields)

    # Struct literals remain value-shaped. Heap/frame placement is a storage
    # decision for the owning binding or wrapper; it must not change `T` into
    # `*T` here, or ordinary RVO/value returns and container inserts break.
    result = init

    # Wrap in BlockExpr if @indirect fields were hoisted, so the AllocMark
    # nodes are visible to the MIR checker.
    if hoisted.any?
      @block_expr_counter += 1
      label = "__ind_blk_#{@block_expr_counter}"
      local_alloc_names = hoisted.each_with_object(Set.new) do |stmt, names|
        names << stmt.name.to_s if stmt.is_a?(MIR::AllocMark)
      end
      result_names = mir_ident_names(result).map(&:to_s).to_set
      local_alloc_names.intersection(result_names).each do |name|
        hoisted << MIR::TransferMark.new(name, :block_result)
      end
      hoisted << MIR::BreakStmt.new(label, result)
      MIR::BlockExpr.new(label, append_ownership_transfers_for_mir_body(hoisted))
    else
      result
    end
  end

  sig { params(node: AST::UnionVariantLit).returns(T.untyped) }
  def lower_union_variant_lit(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    @union_schemas = T.let(@union_schemas, T.untyped)
    # Collect hoisted statements for @indirect fields (same pattern as lower_struct_lit).
    hoisted = []
    variant_alloc = alloc_for_node(node)
    variant_field_types = union_variant_lit_field_types(node)

    variant_struct_name = "#{node.union_name}_#{node.variant_name}"
    field_values = node.fields.map { |k, v|
      ft = variant_field_types[k.to_s]
      field_sink_alloc = aggregate_field_sink_alloc(ft, v, variant_alloc)
      # err_cleanup: union owns its payload on success; only clean up on error.
      move_mark_field!(v)
      val = with_decl_alloc(field_sink_alloc) do
        materialized = materialize_owned_sink_value(lower(v), v, field_sink_alloc, ft)
        hoist_alloc(materialized, v, err_cleanup: true, transfer_on_success: false)
      end
      # @indirect is signalled by the annotator's needs_heap_create stamp
      # (same single source the struct-literal path reads).
      if v.needs_heap_create
        field_sym = Type.from_node!(v, context: "indirect union field").resolved
        zig_t = transpile_type(field_sym.to_s)
        # @indirect union fields: HeapCreate emits __p.* = val (shallow copy).
        # If the field holds a union value, deep-copy so the new allocation's
        # internal heap pointers are independent of the source binding's cleanup.
        # Deep-copy only when source is an existing binding (GetField / Identifier):
        # those have independent cleanup that would free the same heap data, causing
        # UAF in the new allocation. Fresh literals (StructLit, FuncCall, COPY, etc.)
        # transfer ownership naturally via HeapCreate and need no extra copy.
        source_is_binding = v.is_a?(AST::GetField) || v.is_a?(AST::Identifier)
        needs_deep_cleanup = @union_schemas&.key?(field_sym) && source_is_binding
        if needs_deep_cleanup
          val = MIR::DeepCopy.new(val, zig_t, nil, :full_value, :heap)
        end
        @block_expr_counter += 1
        temp = "__ind_#{@block_expr_counter}_#{k}"
        hc = MIR::HeapCreate.new(zig_t, val, :heap, "blk_#{k}")
        mark = MIR::AllocMark.new(temp, :heap, nil)
        mark.scope = :heap
        hoisted << mark
        hoisted << MIR::Let.new(temp, hc, false, nil, nil)
        if needs_deep_cleanup
          # Deep copy owns heap data inside __p.*; errdefer must clean it up
          # before destroying the pointer, otherwise those allocations leak.
          cleanup_call = emit_builtin(:cleanup, [
            MIR::Ident.new(zig_t),
            MIR::Ident.new(alloc_zig_str(:heap)),
            MIR::Ident.new(temp),
          ])
          hoisted << MIR::ErrDeferStmt.new(MIR::ScopeBlock.new([
            MIR::ExprStmt.new(cleanup_call, false),
            MIR::ExprStmt.new(MIR::DestroyPtr.new(MIR::Ident.new(temp), :heap), false)
          ]))
        else
          hoisted << MIR::ErrDeferStmt.new(
            MIR::DestroyPtr.new(MIR::Ident.new(temp), :heap)
          )
        end
        val = MIR::Ident.new(temp)
      end
      { name: k.to_s, value: val, alloc: field_sink_alloc }
    }

    inner = MIR::StructInit.new(variant_struct_name, field_values)
    result = MIR::StructInit.new(node.union_name.to_s, [
      { name: node.variant_name.to_s, value: inner }
    ])

    if hoisted.any?
      @block_expr_counter += 1
      label = "__ind_blk_#{@block_expr_counter}"
      local_alloc_names = hoisted.each_with_object(Set.new) do |stmt, names|
        names << stmt.name.to_s if stmt.is_a?(MIR::AllocMark)
      end
      result_names = mir_ident_names(result).map(&:to_s).to_set
      local_alloc_names.intersection(result_names).each do |name|
        hoisted << MIR::TransferMark.new(name, :block_result)
      end
      hoisted << MIR::BreakStmt.new(label, result)
      MIR::BlockExpr.new(label, append_ownership_transfers_for_mir_body(hoisted))
    else
      result
    end
  end

  sig { params(node: AST::UnionVariantLit).returns(T::Hash[String, T.untyped]) }
  def union_variant_lit_field_types(node)
    T.bind(self, MIRLowering) rescue nil
    @union_schemas = T.let(@union_schemas, T.untyped)
    schema = @union_schemas[node.union_name.to_sym]
    return {} unless schema.is_a?(Schemas::UnionSchema)
    variant_data = schema.variants[node.variant_name.to_sym] || schema.variants[node.variant_name.to_s]
    return {} unless variant_data

    if Schemas.inline_struct?(variant_data)
      variant_data.fields.each_with_object({}) do |(k, f), h|
        h[k.to_s] = f.respond_to?(:type) ? f.type : f
      end
    elsif node.fields.length == 1
      key = node.fields.keys.first.to_s
      { key => Type.from_node(variant_data) }
    else
      {}
    end
  end

  sig { params(_field_type: T.untyped, value: T.untyped, aggregate_alloc: Symbol).returns(Symbol) }
  def aggregate_field_sink_alloc(_field_type, value, aggregate_alloc)
    T.bind(self, MIRLowering) rescue nil
    if value.is_a?(AST::Identifier)
      ti = Type.from_node(value) rescue nil
      if ownership_tracked_transfer_type?(ti) &&
         (value.was_moved == true || value.symbol&.heap_storage?)
        return placement_for_node(value)
      end
    end

    aggregate_alloc
  end

  sig { params(node: AST::StringConcat).returns(MIR::ConcatStr) }
  def lower_string_concat(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    parts = node.parts.map { |p| hoist_alloc(lower(p), p) }
    alloc = alloc_for_node(node)
    MIR::ConcatStr.new(parts, alloc, @rt_name)
  end

  sig { params(node: AST::BlockExpr).returns(MIR::BlockExpr) }
  def lower_block_expr(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @block_expr_counter = T.let(@block_expr_counter, T.untyped)
    @current_bindings = T.let(@current_bindings, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    @block_expr_counter += 1
    label = "__blk_#{@block_expr_counter}"
    transfer_name = T.let(nil, T.nilable(String))
    if node.result.is_a?(AST::Identifier)
      raw_name = node.result.name.to_s
      entry = @current_bindings[raw_name]
      transfer_name = zig_safe_name(raw_name)
      if entry&.needs_cleanup?
        entry[:has_moved_guard] = true
        (@guarded_cleanup_names ||= {})[T.must(transfer_name)] = true
      end
    end
    body = lower_body(node.body)
    result = lower(node.result)
    if transfer_name
      cleanup = T.must(body).find do |stmt|
        (stmt.is_a?(MIR::Cleanup) || stmt.is_a?(MIR::ErrCleanup)) && stmt.name.to_s == transfer_name
      end
      if cleanup
        cleanup.cleanup_entry[:has_moved_guard] = true
        T.must(body) << MIR::TransferMark.new(transfer_name, :block_result)
        T.must(body) << MIR::MoveMark.new(transfer_name)
      end
    end
    T.must(body) << MIR::BreakStmt.new(label, result)
    MIR::BlockExpr.new(label, body)
  end

  sig { params(node: AST::RangeLit).returns(MIR::RangeLit) }
  def lower_range_lit(node)
    T.bind(self, MIRLowering) rescue nil
    s = lower(node.start)
    e = lower(node.finish)
    elem_type = node.full_type.tense_type&.element_type&.resolved
    if node.inclusive
      MIR::RangeLit.new(s, MIR::BinOp.new("+", e, MIR::Lit.new("1")), elem_type)
    else
      MIR::RangeLit.new(s, e, elem_type)
    end
  end

  sig { params(node: AST::Slice).returns(MIR::SliceExpr) }
  def lower_slice(node)
    T.bind(self, MIRLowering) rescue nil
    target = lower(node.target)
    start_expr = lower(node.start)
    end_expr = lower(node.end)
    exclusive = node.instance_variable_get(:@exclusive)

    target_ti = Type.from_node!(node.target, context: "slice target")
    if target_ti.direct_indexable_collection?
      target = MIR::ItemsAccess.new(target, true)
    end

    start_cast = MIR::Cast.new(start_expr, "usize", :intCast)
    end_cast = if exclusive
      MIR::Cast.new(end_expr, "usize", :intCast)
    else
      MIR::BinOp.new("+", MIR::Cast.new(end_expr, "usize", :intCast), MIR::Lit.new("1"))
    end

    elem_zig = node.target.full_type.element_type ? Type.new(node.target.full_type.element_type).zig_type : "u8"
    MIR::SliceExpr.new(target, start_cast, end_cast, elem_zig)
  end

  sig { params(node: AST::Assert).returns(T.any(MIR::InlineBc, MIR::InlineZig)) }
  def lower_assert(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @target = T.let(@target, T.untyped)
    # Specialized lowering for `ASSERT a == b` — dispatch to one of
    # Zig's stdlib testing helpers so failures get a structured diff
    # instead of a bare `assertion failed` panic. Falls back to
    # CheatLib.assert for non-equality conditions and for `!=`.
    #
    # Skip for the :bc (register VM) target: the bytecode VM cannot
    # execute raw Zig, so an InlineZig assert helper would leave the
    # test register-pending forever. The CheatLib.assert fallback path
    # below evaluates the condition as a normal MIR expression and
    # routes through the runtime's bool-assert opcode.
    if @target != :bc && (eq_lowering = try_lower_equality_assert(node))
      return eq_lowering
    end

    mark_explicit_moves_for_cleanup(node.condition)
    cond = lower(node.condition)
    # Parser's optional-pattern slot pushes the symbol :Any when no message
    # follows the assertion's condition. Normalize to "assertion failed"
    # so the user-visible message isn't the literal string "Any".
    raw = node.message
    msg_str = if raw.nil? || raw == :Any || raw.empty?
      "assertion failed"
    else
      raw.to_s
    end
    msg = msg_str.gsub('"', '\\"')
    emit_builtin(:assert, [cond, MIR::Lit.new("\"#{msg}\"")])
  end

  # Detect `ASSERT a == b` and lower to the most specific Zig stdlib
  # testing helper for the operand types. Returns nil if the assertion
  # isn't a binary `==` (caller falls back to the generic
  # CheatLib.assert path).
  #
  # Dispatch order (first match wins):
  #   String  ==  String   -> std.testing.expectEqualStrings
  #   Slice   ==  Slice     -> std.testing.expectEqualSlices(T, ...)
  #   anything == anything  -> std.testing.expectEqualDeep
  #
  # All three return `error.TestExpectedEqual` on mismatch (no panic),
  # which the surrounding test wrapper propagates via `try`. The
  # diagnostic output (field-by-field for structs, length+index for
  # slices, in-context highlight for strings) is rendered by Zig's
  # stdlib.
  sig { params(node: AST::Assert).returns(T.nilable(MIR::InlineZig)) }
  def try_lower_equality_assert(node)
    T.bind(self, MIRLowering) rescue nil
    cond = node.condition
    return nil unless cond.is_a?(AST::BinaryOp) && cond.op == :EQ

    # When the user supplied an explicit message (`ASSERT a == b, "msg"`)
    # they want that message in the failure output. Zig's stdlib testing
    # helpers don't accept a custom message — the diff is the message —
    # so fall back to CheatLib.assert when a message is present so we
    # don't silently drop user-authored context.
    raw = node.message
    has_message = !(raw.nil? || raw == :Any || (raw.respond_to?(:empty?) && raw.empty?))
    return nil if has_message

    left  = cond.left
    right = cond.right
    left_zig  = emit_expr(hoist_alloc(lower(left), left))
    right_zig = emit_expr(hoist_alloc(lower(right), right))

    helper, extra_args = pick_equality_helper(left, right)
    return nil unless helper

    # Argument order matches the Zig stdlib convention: expected
    # first, actual second. CLEAR doesn't distinguish, so we use
    # left=expected, right=actual.
    args = []
    args.concat(extra_args)
    args << left_zig
    args << right_zig

    code = "try std.testing.#{helper}(#{args.join(', ')});"
    iz = MIR::InlineZig.new(code, "assert_eq_#{helper}")
    iz.stdlib_def = { allocates: false, borrows: :all, can_fail: true }
    iz
  end

  # Picks the most specific Zig stdlib equality helper for the given
  # operands. Returns [helper_name, extra_prefix_args] or [nil, nil].
  # Type info comes from the annotator's stamps; if neither operand
  # has resolved type info we fall back to expectEqualDeep, which
  # works on any equatable value.
  sig { params(left: T.untyped, right: T.untyped).returns(T::Array[T.untyped]) }
  def pick_equality_helper(left, right)
    T.bind(self, MIRLowering) rescue nil
    lt = type_info_for(left)
    rt = type_info_for(right)

    if (lt&.string? && (rt.nil? || rt.string?)) ||
       (rt&.string? && (lt.nil? || lt.string?))
      return ["expectEqualStrings", []]
    end

    # expectEqualSlices needs the element type as a comptime arg.
    # Use it only when we can confidently render that type as Zig.
    if (slice_elem = slice_element_zig_type(lt) || slice_element_zig_type(rt))
      return ["expectEqualSlices", [slice_elem]]
    end

    ["expectEqualDeep", []]
  end

  sig { params(ast_node: T.untyped).returns(Type) }
  def type_info_for(ast_node)
    T.bind(self, MIRLowering) rescue nil
    Type.from_node!(ast_node, context: "equality helper")
  end

  # If `t` is a list/slice type whose element type renders cleanly to
  # Zig, return the Zig element-type string. Otherwise nil — caller
  # falls back to expectEqualDeep.
  sig { params(t: Type).returns(T.nilable(String)) }
  def slice_element_zig_type(t)
    T.bind(self, MIRLowering) rescue nil
    return nil unless t.respond_to?(:array?) && t.array?
    return nil if t.string?  # strings handled by expectEqualStrings
    elem = t.respond_to?(:element_type) ? t.element_type : nil
    return nil unless elem
    elem.respond_to?(:zig_type) ? elem.zig_type : nil
  rescue StandardError
    nil
  end

  sig { params(node: AST::Raise).returns(MIR::ScopeBlock) }
  def lower_raise(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    rt = MIR::Ident.new(@rt_name)
    kind = ".#{node.kind || :Unknown}"
    # error_name is a u32 id into the per-program ErrorName enum. Emit
    # `@intFromEnum(ErrorName.Foo)` when a specific type is named; use
    # `0` (the None sentinel) when it's a kind-only RAISE.
    name_expr = if node.error_name && !node.error_name.empty?
      "@intFromEnum(ErrorName.#{node.error_name})"
    else
      "0"
    end
    msg_expr = node.message_expr ? lower(node.message_expr) : MIR::Lit.new('""')
    line = node.token.line.to_s

    set_error = MIR::MethodCall.new(rt, "setError", [
      MIR::Ident.new(kind),
      MIR::Ident.new(name_expr),
      msg_expr,
      MIR::Lit.new(line)
    ], false, MIR::CallableContract.no_ownership(4))

    ret = MIR::ReturnStmt.new(MIR::Ident.new("error.CheatError"))
    MIR::ScopeBlock.new([MIR::ExprStmt.new(set_error, false), ret])
  end

  # ================================================================
  # Memory / capability expressions
  # ================================================================

  sig { params(node: AST::CopyNode).returns(MIR::DeepCopy) }
  def lower_copy(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @schema_lookup = T.let(@schema_lookup, T.untyped)
    @union_schemas = T.let(@union_schemas, T.untyped)
    source = lower(node.value)
    source = hoist_alloc(source, node.value) if mir_allocates?(source)
    ti = Type.from_node!(node.value, context: "COPY value")
    # Copy placement is destination-driven. Auto-COPY sites may stamp alloc
    # directly; otherwise the active sink allocator flows through
    # with_decl_alloc. Only a context-free explicit COPY defaults to heap.
    alloc = @current_decl_alloc || node.alloc || :heap

    if @union_schemas&.key?(ti.resolved)
      MIR::DeepCopy.new(source, transpile_type(ti.resolved.to_s), nil, :full_value, alloc)
    elsif ti.optional? && ti.needs_cleanup?(@schema_lookup)
      MIR::DeepCopy.new(source, ti.zig_type, nil, :full_value, alloc)
    elsif ti.any_sync?
      MIR::DeepCopy.new(source, nil, nil, :full_value, alloc)
    elsif ti.string?
      MIR::DeepCopy.new(source, "[]const u8", nil, :full_value, alloc)
    elsif ti.direct_indexable_collection?
      # COPY of a list/slice: ItemsAccess produces a []T view; the slice arm of
      # CheatLib.dupeValue allocates a fresh buffer and per-element dupes when
      # elements need cleanup (or @memcpy when they don't). Subsumes the old
      # :list_shallow + :list_deep dispatch. The element T (for the cleanup
      # type) is stamped so cleanup hoist gets the right []T.
      elem_zig = transpile_type(ti.element_type)
      src = MIR::ItemsAccess.new(source, true)
      MIR::DeepCopy.new(src, "[]#{elem_zig}", elem_zig, :full_value, alloc)
    elsif ti.collection? || (ti.struct? && ti.needs_promotion?(@schema_lookup))
      MIR::DeepCopy.new(source, ti.zig_type, nil, :full_value, alloc)
    else
      MIR::DeepCopy.new(source, nil, nil, :passthrough, nil)
    end
  end

  sig { params(node: AST::CloneNode).returns(MIR::RcRetain) }
  def lower_clone(node)
    T.bind(self, MIRLowering) rescue nil
    ti = Type.from_node!(node.value, context: "CLONE value")
    func = if ti.split_open_stream?
      "splitRetain"
    elsif ti.shared_promise? || ti.shared?
      "arcRetain"
    elsif ti.multiowned?
      "rcRetain"
    else
      raise "Internal: lower_clone on unsupported type #{ti.resolved || node.value.resolved_type}"
    end
    zig_base = ti.split_open_stream? ? ti.zig_type : rc_payload_zig_type(ti)
    MIR::RcRetain.new(lower(node.value), zig_base, func)
  end

  sig { params(node: T.untyped).void }
  def mark_explicit_moves_for_cleanup(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_bindings = T.let(@current_bindings, T.untyped)
    @fn_name_rename_map = T.let(@fn_name_rename_map, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    @pending_stmts = T.let(@pending_stmts, T.untyped)
    return unless node
    if node.is_a?(AST::MoveNode) && node.value.is_a?(AST::Identifier)
      ident_name = zig_safe_name(node.value.name)
      ident_name = @fn_name_rename_map[ident_name] if @fn_name_rename_map&.key?(ident_name)
      entry = @current_bindings[node.value.name.to_s] || CleanupEntry::NONE
      guarded = entry.needs_cleanup? && (entry.has_moved_guard? || @guarded_cleanup_names&.[](ident_name))
      @pending_stmts << MIR::MoveMark.new(ident_name) if guarded
      return
    end
    mark_explicit_moves_for_cleanup(node.value) if node.respond_to?(:value)
    mark_explicit_moves_for_cleanup(node.left) if node.respond_to?(:left)
    mark_explicit_moves_for_cleanup(node.right) if node.respond_to?(:right)
    mark_explicit_moves_for_cleanup(node.condition) if node.respond_to?(:condition) && !node.is_a?(AST::IfStatement)
    node.args&.each { |a| mark_explicit_moves_for_cleanup(a) } if node.respond_to?(:args)
  end

  # A struct/union literal field store is a consuming site: a moved
  # binding placed in a field transfers ownership, so its guarded
  # cleanup must be suppressed via MoveMark -- the same mechanism
  # element stores and TAKES args use (INV-13/14).
  sig { params(v: T.untyped).void }
  def move_mark_field!(v)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_bindings = T.let(@current_bindings, T.untyped)
    @fn_name_rename_map = T.let(@fn_name_rename_map, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    @pending_stmts = T.let(@pending_stmts, T.untyped)
    return unless v.is_a?(AST::Identifier)
    ti = Type.from_node(v) rescue nil
    tracked = ti && !ti.primitive? && !ti.void? && !ti.any? &&
              (ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(@schema_lookup))
    return unless v.was_moved == true || (tracked && v.symbol&.heap_storage?)
    nm = zig_safe_name(v.name)
    nm = @fn_name_rename_map[nm] if @fn_name_rename_map&.key?(nm)
    entry = @current_bindings[v.name.to_s] || CleanupEntry::NONE
    return unless entry.present?
    entry[:has_moved_guard] = true
    (@guarded_cleanup_names ||= {})[nm] = true
  end

  sig { params(node: AST::MoveNode).returns(MIR::Ident) }
  def lower_move(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_bindings = T.let(@current_bindings, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    @pending_stmts = T.let(@pending_stmts, T.untyped)
    if node.value.is_a?(AST::Identifier)
      # Route through lower_identifier so BG capture-map rewrites apply:
      # GIVE lst inside BG { ... } must emit __ctx_N.lst, not lst.
      ident = lower_identifier(node.value)
      ident
    else
      lower(node.value)
    end
  end

  sig { params(node: AST::ShareNode).returns(T.untyped) }
  def lower_share(node)
    T.bind(self, MIRLowering) rescue nil
    source_ti = node.value.full_type
    source_ti = Type.new(source_ti) if source_ti && !source_ti.is_a?(Type)
    raise "Internal: lower_share requires typed source" unless source_ti

    zig_base = rc_payload_zig_type(source_ti)

    if source_ti.shared?
      return MIR::RcRetain.new(lower(node.value), zig_base, "arcRetain")
    end

    if source_ti.multiowned?
      return MIR::SharePromote.new(lower(node.value), zig_base, :heap)
    end

    MIR::CapWrap.new(lower(node.value), zig_base, :own_only, nil, nil, "arcCreate", :heap)
  end

  sig { params(node: AST::CapabilityWrap).returns(MIR::CapWrap) }
  def lower_cap_wrap(node)
    T.bind(self, MIRLowering) rescue nil
    inner = with_decl_alloc(:heap) do
      value = lower(node.value)
      place_value_for_destination(value, node.value, :heap, node.value.full_type)
    end
    base_type = node.value.resolved_type.to_s
    zig_base = transpile_type(base_type)
    alloc = :heap

    # AtomicPtr and primitive Atomic use different constructors but both use
    # bare-pointer ownership without an outer Arc/Rc wrapper.
    is_atomic_ptr = node.atomic_ptr?
    sync_fn = case node.sync
              when :locked then "lockedCreate"
              when :write_locked then "rwLockedCreate"
              when :always_mutable then "refCellCreate"
              when :versioned then "versionedCreate"
              when :atomic then (is_atomic_ptr ? "atomicPtrCreate" : "atomicCreate")
              end
    sync_type = case node.sync
                when :locked then "CheatLib.Locked(#{zig_base})"
                when :write_locked then "CheatLib.RwLocked(#{zig_base})"
                when :always_mutable then "CheatLib.RefCell(#{zig_base})"
                when :versioned then "CheatLib.Versioned(#{zig_base})"
                when :atomic then (is_atomic_ptr ? "CheatLib.AtomicPtr(#{zig_base})" : "CheatLib.Atomic(#{zig_base})")
                end
    # Atomic cells are already thread-safe; AtomicPtr also owns an
    # Arc-managed payload internally, so an outer Arc/Rc would double-wrap.
    own_fn = case node.ownership
             when :shared then (node.atomic? ? nil : "arcCreate")
             when :multiowned then (node.atomic? ? nil : "rcCreate")
             end

    strategy = if node.local? || (node.indirect? && !node.sync && !node.ownership)
      :local
    elsif sync_fn && own_fn
      :both
    elsif sync_fn
      :sync_only
    elsif own_fn
      :own_only
    else
      :passthrough
    end

    MIR::CapWrap.new(inner, zig_base, strategy, sync_fn, sync_type, own_fn, alloc)
  end

  sig { params(node: AST::LinkNode).returns(MIR::RcDowngrade) }
  def lower_link(node)
    T.bind(self, MIRLowering) rescue nil
    inner = lower(node.value)
    ti = node.value.full_type
    base = transpile_type(ti.resolved.to_s)
    func = ti.shared? ? "arcDowngrade" : "rcDowngrade"
    MIR::RcDowngrade.new(inner, base, func)
  end

  sig { params(node: AST::ResolveNode).returns(MIR::WeakUpgrade) }
  def lower_resolve(node)
    T.bind(self, MIRLowering) rescue nil
    inner = lower(node.value)
    ti = node.value.full_type
    base = transpile_type(ti.resolved.to_s)
    source = ti.link_source || :multiowned
    func = source == :shared ? "weakArcUpgrade" : "weakRcUpgrade"
    MIR::WeakUpgrade.new(inner, base, func)
  end

  sig { params(node: AST::FreezeNode).returns(MIR::FreezeExpr) }
  def lower_freeze(node)
    T.bind(self, MIRLowering) rescue nil
    ti = node.value.full_type
    base = ti.resolved.to_s.sub(/^\?/, '')
    zig_base = transpile_type(base)
    inner = lower(node.value)
    # Dereference Rc data pointer to get *const T for freeze()
    rc_data = MIR::FieldGet.new(MIR::FieldGet.new(inner, "ctrl"), "data")
    MIR::FreezeExpr.new(rc_data, zig_base)
  end

  sig { params(ti: Type).returns(String) }
  def rc_payload_zig_type(ti)
    T.bind(self, MIRLowering) rescue nil
    if ti.resolved.to_s.match?(/\A[A-Z]\z/) && ti.shared?
      return ti.resolved.to_s
    end
    payload = Type.new(ti)
    payload.ownership = :affine
    payload.provenance = nil
    payload.instance_variable_set(:@zig_type_cache, nil)
    if payload.any_sync? && !(payload.map? && payload.striped?)
      inner = payload.bare_data_type.zig_type
      inner = "CheatLib.Locked(#{inner})"   if payload.locked?
      inner = "CheatLib.RwLocked(#{inner})" if payload.write_locked?
      inner = "CheatLib.RefCell(#{inner})"  if payload.sync == :always_mutable
      inner = "CheatLib.Versioned(#{inner})" if payload.versioned?
      if payload.atomic?
        inner = payload.indirect? ? "CheatLib.AtomicPtr(#{inner})" : "CheatLib.Atomic(#{inner})"
      end
      return inner
    end
    payload.zig_type
  end

  sig { params(type: T.untyped).returns(String) }
  def generic_type_arg_zig(type)
    T.bind(self, MIRLowering) rescue nil
    if type.is_a?(Type) && type.instance_variable_get(:@generic_payload_type_arg)
      return rc_payload_zig_type(type)
    end
    t = type.is_a?(Type) ? Type.new(type) : Type.new(type)
    t.zig_type
  end


end
