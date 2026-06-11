# typed: strict
require "sorbet-runtime"

module MIRLoweringExpressions
  extend T::Sig
  extend T::Helpers

  requires_ancestor { MIRLowering }

  StructLitFieldType = T.type_alias { T.nilable(T.any(Type::TypeInput, Schemas::InlineStructVariant)) }
  StructLitTypeSubst = T.type_alias { T::Hash[Symbol, Type::TypeInput] }
  UnionVariantFieldTypes = T.type_alias { T::Hash[String, Type::TypeInput] }

  class OrExitFacts < T::Struct
    const :kind, T.nilable(String)
    const :error_name, T.nilable(String)
    const :name_id, T.nilable(Integer)
    const :clear_type, T::Boolean
    const :has_message, T::Boolean
    const :line, Integer
  end

  class OrRescueFacts < T::Struct
    const :left_is_error, T::Boolean
    const :line, Integer
    const :target, Symbol
  end

  class BinaryIntArithmeticFacts < T::Struct
    const :both_int, T::Boolean
    const :has_comptime_number_literal, T::Boolean
    const :has_float_coercion, T::Boolean
  end

  class UnitVariantAccess < T::Struct
    const :type_name, Symbol
    const :variant_name, String
  end

  class BinaryMirOperands < T::Struct
    const :left, MIR::Node
    const :right, MIR::Node
  end

  class BinaryOperandFacts < T::Struct
    const :node, AST::BinaryOp
    const :op, Symbol
    const :left, MIR::Node
    const :right, MIR::Node
    const :left_type, Type
    const :right_type, Type
    const :int_arithmetic, BinaryIntArithmeticFacts
    const :left_unit_variant, T.nilable(UnitVariantAccess)
    const :right_unit_variant, T.nilable(UnitVariantAccess)
  end

  class BinaryOperationPlan < T::Struct
    const :kind, Symbol
    const :facts, BinaryOperandFacts
    const :builtin, T.nilable(Symbol), default: nil
    const :op_str, T.nilable(String), default: nil
    const :type_arg, T.nilable(String), default: nil
    const :variant, T.nilable(UnitVariantAccess), default: nil
    const :tag_source, T.nilable(Symbol), default: nil
    const :union_error_type, T.nilable(Symbol), default: nil
    const :optional_side, T.nilable(Symbol), default: nil
    const :optional_capture, T.nilable(String), default: nil
  end

  class FieldAccessPlan < T::Struct
    extend T::Sig

    const :target, MIR::Node
    const :field, String
    const :path, Symbol
    const :union_payload, T::Boolean
    const :union_payload_zig, T.nilable(String)
    const :indirect, T::Boolean

    sig { returns(T::Boolean) }
    def union_payload?
      union_payload
    end

    sig { returns(MIR::Node) }
    def value
      value_for(target)
    end

    sig { params(root: MIR::Node).returns(MIR::Node) }
    def value_for(root)
      result = if union_payload?
        MIR::UnionVariantGet.new(root, field, T.must(union_payload_zig))
      else
        MIR::FieldGet.new(field_root(root), field)
      end
      indirect ? MIR::Deref.new(result) : result
    end

    private

    sig { params(root: MIR::Node).returns(MIR::Node) }
    def field_root(root)
      case path
      when :ctrl_data
        MIR::FieldGet.new(MIR::FieldGet.new(root, "ctrl"), "data")
      when :data
        MIR::FieldGet.new(root, "data")
      else
        root
      end
    end
  end

  class IndexAccessPlan < T::Struct
    extend T::Sig

    const :target, MIR::Node
    const :index, MIR::Node
    const :optional, T::Boolean
    const :optional_source, T.nilable(MIR::Node)
    const :target_ast, AST::Node
    const :type_info, Type
    const :target_name, T.nilable(String)
    const :needs_mut_ref, T::Boolean

    sig { returns(T::Boolean) }
    def optional?
      optional
    end
  end

  INTEGER_LITERAL_CASTS = T.let({
    INT8: "i8",
    INT16: "i16",
    INT32: "i32",
    UINT16: "u16",
    UINT32: "u32",
    UINT64: "u64"
  }.freeze, T::Hash[Symbol, String])

  WRAPPING_BUILTINS = T.let({
    WRAP_ADD: :wrapAdd,
    WRAP_SUB: :wrapSub,
    WRAP_MUL: :wrapMul
  }.freeze, T::Hash[Symbol, Symbol])

  CHECKED_BUILTINS = T.let({
    CHECK_ADD: :checkAdd,
    CHECK_SUB: :checkSub,
    CHECK_MUL: :checkMul
  }.freeze, T::Hash[Symbol, Symbol])

  INTEGER_ARITHMETIC_BUILTINS = T.let({
    ADD: :intAdd,
    SUB: :intSub,
    MUL: :intMul
  }.freeze, T::Hash[Symbol, Symbol])

  STRING_COMPARISON_OPS = T.let({
    EQ: "==",
    NEQ: "!=",
    LT: "<",
    LTE: "<=",
    GT: ">",
    GTE: ">=",
  }.freeze, T::Hash[Symbol, String])

  OPTIONAL_COMPARISON_OPS = T.let([:EQ, :NEQ, :LT, :LTE, :GT, :GTE].freeze, T::Array[Symbol])

  BINARY_PLAN_EMITTERS = T.let({
    pow: :emit_power_binary_plan,
    builtin: :emit_builtin_binary_plan,
    optional_comparison: :emit_optional_comparison_plan,
    symbol_comparison: :emit_symbol_binary_plan,
    string_comparison: :emit_string_binary_comparison,
    unit_variant_comparison: :emit_unit_variant_comparison,
    union_equality_error: :raise_union_equality_error,
    standard: :emit_standard_binary_plan,
  }.freeze, T::Hash[Symbol, Symbol])

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
        MIR::Lit.new(float_literal_text(node.value))
      end
    when :INT8, :INT16, :INT32, :UINT16, :UINT32, :UINT64
      MIR::Cast.new(MIR::Lit.new(node.value.to_s), INTEGER_LITERAL_CASTS.fetch(node.type), :as)
    when :FLOAT32
      MIR::Cast.new(MIR::Lit.new(float_literal_text(node.value)), "f32", :as)
    when :NIL      then MIR::Lit.new("null")
    else
      MIR::Lit.new(node.value.to_s)
    end
  end

  sig { params(value: T.untyped).returns(String) }
  def float_literal_text(value)
    s = value.to_s
    value == value.to_i && !s.include?('.') ? "#{s}.0" : s
  end

  sig { params(node: AST::Identifier).returns(T.untyped) }
  def lower_identifier(node)
    T.bind(self, MIRLowering) rescue nil
    # Pipeline bindings ($u, $v, $item, ...) are substituted by PipelineHost
    # before reaching the MIR lowering. If one arrives here it means it was
    # used outside its pipeline context (after the pipeline expression ended,
    # or in a pipeline that doesn't have a matching AS declaration).
    if synthetic_pipeline_binding_name?(node.name)
      line = node.token&.line || "?"
      raise "line #{line}: Undefined pipeline binding '#{node.name}'. " \
            "Pipeline bindings must be declared with 'AS #{node.name}' " \
            "in the same pipeline expression where they are used."
    end

    return MIR::FnRef.new(zig_safe_name(node.name)) if node.respond_to?(:fn_ref) && node.fn_ref

    # Inside a WITH block, use the unwrapped inner alias instead of the Rc handle
    rc_map = capability_state.rc_unwrap_map || {}
    return MIR::Ident.new(rc_map[node.name]) if rc_map.key?(node.name)

    # Inside a WITH EXCLUSIVE block, rewrite original var name to the unwrapped inner alias
    locked_map = capability_state.locked_unwrap_map || {}
    alias_name = locked_map[node.name]
    return MIR::Ident.new(alias_name) if alias_name.is_a?(String)

    # Inside a DO block branch, access captured outer variables via ctx pointer
    capture_map = capture_state.do_capture_map || {}
    if capture_map.key?(node.name)
      ident = MIR::Ident.new(capture_map[node.name])
      if atomic_capture_load?(node)
        return MIR::MethodCall.new(ident, "load", [], false, MIR::CallableContract.no_ownership(0))
      end
      return ident
    end

    # Use disambiguated Zig name if the declaration was renamed to avoid
    # same-name collision in the MIR checker (see lower_var_decl).
    decl_node = node.symbol&.reg
    zig_name = (decl_node && function_state.decl_zig_names[decl_node.object_id]) ||
               zig_safe_name(node.name)
    ident = MIR::Ident.new(zig_name)

    # Atomic reads normally lower to `.load()`, but raw emission and
    # atomic-borrow call sites need the cell reference itself.
    symbol = node.symbol
    if symbol&.atomic? && !capability_state.atomic_emit_raw
      return ident if node.atomic_borrow
      # AtomicPtr reads go through WITH SNAPSHOT; the bare identifier is the
      # cell pointer and AtomicPtr has no `.load()` method.
      if symbol.indirect?
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

  sig { params(name: String).returns(T::Boolean) }
  def synthetic_pipeline_binding_name?(name)
    return false unless name.start_with?("$")
    return false if name.length < 2

    codepoint = T.must(name[1]).ord
    codepoint >= 97 && codepoint <= 122
  end

  sig { params(node: AST::Identifier).returns(T::Boolean) }
  def atomic_capture_load?(node)
    T.bind(self, MIRLowering) rescue nil
    sym = node.symbol
    !!(sym&.atomic? && !capability_state.atomic_emit_raw && !node.atomic_borrow && sym.layout != :indirect)
  end

  sig { params(ft: Type, field_node: AST::Node, field_alloc: T.nilable(Symbol), field_sink_alloc: Symbol).returns(T::Boolean) }
  def recursive_field_copy_required?(ft, field_node, field_alloc, field_sink_alloc)
    T.bind(self, MIRLowering) rescue nil
    !!(ft.recursive_cleanup_shape?(mir_schema_lookup) &&
      !ast_expr_produces_heap?(field_node) && field_alloc != field_sink_alloc)
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
    return lower_smooth(node) if node.smooth?

    # Error chain: expr OR handler
    return lower_or_rescue(node) if node.op == :OR_RESCUE

    # Named pipeline binding (AS $v): passthrough to LHS value.
    # The $v registration is handled by the pipeline host at the binding point.
    return lower(node.left) if node.op == :BIND_VAR

    return lower_lazy_boolean_op(node) if node.op == :AND || node.op == :OR

    # String concat (2-part) uses std.mem.concat
    if node.string_concat
      left = hoist_alloc(lower(node.left), node.left)
      right = hoist_alloc(lower(node.right), node.right)
      alloc = alloc_for_node(node)
      return MIR::ConcatStr.new([left, right], alloc, nil)
    end

    emit_binary_operation_plan(binary_operation_plan(node))
  end

  sig { params(node: AST::BinaryOp).returns(BinaryOperationPlan) }
  def binary_operation_plan(node)
    T.bind(self, MIRLowering) rescue nil
    facts = binary_operand_facts(node)
    classify_binary_operation(facts)
  end

  sig { params(node: AST::BinaryOp).returns(BinaryOperandFacts) }
  def binary_operand_facts(node)
    T.bind(self, MIRLowering) rescue nil
    BinaryOperandFacts.new(
      node: node,
      op: T.cast(node.op, Symbol),
      left: T.cast(lower(node.left), MIR::Node),
      right: T.cast(lower(node.right), MIR::Node),
      left_type: Type.from_node!(node.left, context: "binary lhs"),
      right_type: Type.from_node!(node.right, context: "binary rhs"),
      int_arithmetic: binary_int_arithmetic_facts(node),
      left_unit_variant: unit_variant_access(node.left),
      right_unit_variant: unit_variant_access(node.right),
    )
  end

  sig { params(facts: BinaryOperandFacts).returns(BinaryOperationPlan) }
  def classify_binary_operation(facts)
    T.bind(self, MIRLowering) rescue nil
    return BinaryOperationPlan.new(kind: :pow, facts: facts, type_arg: binary_power_type_arg(facts)) if facts.op == :POW
    return BinaryOperationPlan.new(kind: :builtin, facts: facts, builtin: :intMod) if signed_integer_modulo?(facts)

    optional_plan = classify_optional_binary_comparison(facts)
    return optional_plan if optional_plan

    string_plan = classify_string_binary_operation(facts)
    return string_plan if string_plan
    return BinaryOperationPlan.new(kind: :builtin, facts: facts, builtin: :intDiv) if integer_division?(facts)

    builtin = direct_binary_builtin(facts)
    return BinaryOperationPlan.new(kind: :builtin, facts: facts, builtin: builtin) if builtin

    unit_plan = classify_unit_variant_comparison(facts)
    return unit_plan if unit_plan

    union_error_type = invalid_union_equality_type(facts)
    return BinaryOperationPlan.new(kind: :union_equality_error, facts: facts, union_error_type: union_error_type) if union_error_type

    op_str = ZigTypeMapper::ZIG_OPS[facts.op]
    raise "MIRLowering: unknown binary op #{facts.op}" unless op_str

    BinaryOperationPlan.new(kind: :standard, facts: facts, op_str: op_str)
  end

  sig { params(facts: BinaryOperandFacts).returns(String) }
  def binary_power_type_arg(facts)
    facts.left_type.resolved == :Int64 ? "i64" : "f64"
  end

  sig { params(facts: BinaryOperandFacts).returns(T::Boolean) }
  def signed_integer_modulo?(facts)
    facts.op == :MOD && facts.left_type.resolved == :Int64
  end

  sig { params(facts: BinaryOperandFacts).returns(T.nilable(BinaryOperationPlan)) }
  def classify_string_binary_operation(facts)
    return nil unless facts.left_type.string? || facts.right_type.string?

    if facts.left_type.symbol? && facts.right_type.symbol?
      return nil unless facts.op == :EQ || facts.op == :NEQ
      return BinaryOperationPlan.new(kind: :symbol_comparison, facts: facts)
    end

    op_str = string_comparison_operator(facts.op)
    return nil unless op_str

    BinaryOperationPlan.new(kind: :string_comparison, facts: facts, op_str: op_str)
  end

  sig { params(op: Symbol).returns(T.nilable(String)) }
  def string_comparison_operator(op)
    STRING_COMPARISON_OPS[op]
  end

  sig { params(facts: BinaryOperandFacts).returns(T.nilable(BinaryOperationPlan)) }
  def classify_optional_binary_comparison(facts)
    return nil unless OPTIONAL_COMPARISON_OPS.include?(facts.op)
    return nil unless facts.left_type.optional? != facts.right_type.optional?

    optional_side = facts.left_type.optional? ? :left : :right
    payload_type = optional_side == :left ? facts.right_type : facts.left_type
    return nil if payload_type.resolved == :NIL

    BinaryOperationPlan.new(
      kind: :optional_comparison,
      facts: facts,
      optional_side: optional_side,
      optional_capture: "__opt_cmp_#{lowering_counters.next_tmp_id}",
    )
  end

  sig { params(facts: BinaryOperandFacts).returns(T::Boolean) }
  def integer_division?(facts)
    facts.op == :DIV && facts.left_type.integer? && facts.right_type.integer?
  end

  sig { params(facts: BinaryOperandFacts).returns(T.nilable(Symbol)) }
  def direct_binary_builtin(facts)
    direct = WRAPPING_BUILTINS[facts.op] || CHECKED_BUILTINS[facts.op]
    return direct if direct

    fn = INTEGER_ARITHMETIC_BUILTINS[facts.op]
    return nil unless fn
    return nil unless facts.int_arithmetic.both_int
    return nil if facts.int_arithmetic.has_comptime_number_literal
    return nil if facts.int_arithmetic.has_float_coercion

    fn
  end

  sig { params(facts: BinaryOperandFacts).returns(T.nilable(BinaryOperationPlan)) }
  def classify_unit_variant_comparison(facts)
    return nil unless facts.op == :EQ || facts.op == :NEQ
    lhs_uv = facts.left_unit_variant
    rhs_uv = facts.right_unit_variant
    op_str = facts.op == :EQ ? "==" : "!="
    if lhs_uv && !rhs_uv
      return BinaryOperationPlan.new(kind: :unit_variant_comparison, facts: facts, op_str: op_str, variant: lhs_uv, tag_source: :right)
    end
    if rhs_uv && !lhs_uv
      return BinaryOperationPlan.new(kind: :unit_variant_comparison, facts: facts, op_str: op_str, variant: rhs_uv, tag_source: :left)
    end
    nil
  end

  sig { params(facts: BinaryOperandFacts).returns(T.nilable(Symbol)) }
  def invalid_union_equality_type(facts)
    T.bind(self, MIRLowering)
    return nil unless facts.op == :EQ || facts.op == :NEQ

    left_resolved = facts.left_type.resolved
    right_resolved = facts.right_type.resolved
    return left_resolved if union_schemas.key?(left_resolved)
    return right_resolved if union_schemas.key?(right_resolved)

    nil
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::Node) }
  def emit_binary_operation_plan(plan)
    T.bind(self, MIRLowering) rescue nil
    emitter = BINARY_PLAN_EMITTERS[plan.kind]
    raise "MIRLowering: unknown binary operation plan #{plan.kind}" unless emitter

    T.cast(T.unsafe(self).__send__(emitter, plan), MIR::Node)
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::Call) }
  def emit_power_binary_plan(plan)
    facts = plan.facts
    MIR::Call.new(
      "std.math.pow",
      [MIR::Ident.new(T.must(plan.type_arg)), facts.left, facts.right],
      false,
      false,
      MIR::CallableContract.no_ownership(3),
    )
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::Node) }
  def emit_builtin_binary_plan(plan)
    T.bind(self, MIRLowering)
    facts = plan.facts
    emit_builtin(T.must(plan.builtin), [facts.left, facts.right])
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::IfOptional) }
  def emit_optional_comparison_plan(plan)
    T.bind(self, MIRLowering)
    facts = plan.facts
    capture = T.must(plan.optional_capture)
    optional_side = T.must(plan.optional_side)
    capture_ref = MIR::Ident.new(capture)
    optional_source = optional_side == :left ? facts.left : facts.right
    then_expr = emit_optional_comparison_then_expr(facts, optional_side, capture_ref)
    else_expr = MIR::Lit.new(facts.op == :NEQ ? "true" : "false")
    result = MIR::IfOptional.new(optional_source, capture, then_expr, else_expr)
    result.result_type = Type.new(:Bool)
    result
  end

  sig { params(facts: BinaryOperandFacts, optional_side: Symbol, capture_ref: MIR::Ident).returns(MIR::Node) }
  def emit_optional_comparison_then_expr(facts, optional_side, capture_ref)
    inner_type = optional_side == :left ? T.must(facts.left_type.wrapped_type) : T.must(facts.right_type.wrapped_type)
    inner_facts = BinaryOperandFacts.new(
      node: facts.node,
      op: facts.op,
      left: optional_side == :left ? capture_ref : facts.left,
      right: optional_side == :right ? capture_ref : facts.right,
      left_type: optional_side == :left ? inner_type : facts.left_type,
      right_type: optional_side == :right ? inner_type : facts.right_type,
      int_arithmetic: facts.int_arithmetic,
      left_unit_variant: facts.left_unit_variant,
      right_unit_variant: facts.right_unit_variant,
    )
    emit_binary_operation_plan(classify_binary_operation(inner_facts))
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::Node) }
  def emit_symbol_binary_plan(plan)
    emit_symbol_binary_comparison(plan.facts)
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::BinOp) }
  def emit_standard_binary_plan(plan)
    facts = plan.facts
    MIR::BinOp.new(T.must(plan.op_str), facts.left, facts.right)
  end

  sig { params(facts: BinaryOperandFacts).returns(MIR::Node) }
  def emit_symbol_binary_comparison(facts)
    T.bind(self, MIRLowering)
    cmp = emit_builtin(:symbolEql, [facts.left, facts.right])
    facts.op == :NEQ ? MIR::UnaryOp.new("!", cmp) : cmp
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::Node) }
  def emit_string_binary_comparison(plan)
    T.bind(self, MIRLowering)
    facts = plan.facts
    operands = string_comparison_operands(facts)
    eql_call = emit_builtin(:eql, [operands.left, operands.right])
    return eql_call if facts.op == :EQ
    return MIR::UnaryOp.new("!", eql_call) if facts.op == :NEQ

    MIR::BinOp.new(
      T.must(plan.op_str),
      emit_builtin(:strcmp, [operands.left, operands.right]),
      MIR::Lit.new("0"),
    )
  end

  sig { params(facts: BinaryOperandFacts).returns(BinaryMirOperands) }
  def string_comparison_operands(facts)
    T.bind(self, MIRLowering)
    node = facts.node
    left = string_comparison_operand(facts.left, node.left)
    right = string_comparison_operand(facts.right, node.right)
    BinaryMirOperands.new(left: hoist_alloc(left, node.left), right: hoist_alloc(right, node.right))
  end

  sig { params(value: MIR::Node, ast_node: AST::Node).returns(MIR::Node) }
  def string_comparison_operand(value, ast_node)
    T.bind(self, MIRLowering)
    if ast_node.is_a?(AST::BinaryOp) && ast_node.op == :OR_RESCUE
      return place_value_for_destination(value, ast_node, :heap, ast_node.full_type!)
    end
    value
  end

  sig { params(plan: BinaryOperationPlan).returns(MIR::BinOp) }
  def emit_unit_variant_comparison(plan)
    T.bind(self, MIRLowering)
    facts = plan.facts
    tag_target = plan.tag_source == :left ? facts.left : facts.right
    MIR::BinOp.new(
      T.must(plan.op_str),
      active_tag_call(tag_target),
      MIR::EnumTag.new(variant: T.must(plan.variant).variant_name),
    )
  end

  sig { params(plan: BinaryOperationPlan).returns(T.noreturn) }
  def raise_union_equality_error(plan)
    type_name = T.must(plan.union_error_type)
    Kernel.raise "BinaryOp #{plan.facts.op} on union '#{type_name}': Zig `==` does not " \
          "work on tagged unions. Either compare against a unit variant " \
          "(e.g. `s == #{type_name}.Variant`) -- which lowers to " \
          "std.meta.activeTag(s) == .Variant -- or use a MATCH expression " \
          "to discriminate the active variant.\n" \
          "(See transpile-tests/255_union_equality.cht.)"
  end

  sig { params(node: AST::BinaryOp).returns(MIR::BinOp) }
  def lower_lazy_boolean_op(node)
    T.bind(self, MIRLowering) rescue nil
    op_str = ZigTypeMapper::ZIG_OPS[node.op]
    raise "MIRLowering: unknown boolean op #{node.op}" unless op_str

    left = lower(node.left)
    right = lower_scoped { lower(node.right) }
    MIR::BinOp.new(op_str, left, right)
  end

  # Returns [union_type_name, variant_name] when `node` is a unit-variant
  # access on a known union (e.g. `Status.Active` -> [:Status, "Active"]),
  # otherwise nil. Used by lower_binary_op to lower
  # `union_value == Type.Variant` to std.meta.activeTag.
  sig { params(node: T.untyped).returns(T.nilable(UnitVariantAccess)) }
  def unit_variant_access(node)
    T.bind(self, MIRLowering) rescue nil
    return nil unless node.is_a?(AST::GetField)
    return nil unless node.target.is_a?(AST::Identifier)
    type_name = node.target.name.to_sym
    schema = union_schemas.dig(type_name)
    return nil unless schema.is_a?(Schemas::UnionSchema)
    field_key = union_variant_key(schema, node.field)
    return nil unless field_key

    var_data = schema.variants[field_key]
    # Unit variants have nil / Symbol / Type variant data. Inline-struct
    # variants are Hashes with :kind => :inline_struct; payload variants
    # like `Idle: Int64` are Symbols/Types -- both could appear at this
    # AST shape, but only the no-payload `.Active` form binds with a
    # bare GetField. Inline-struct construction goes through StructLit;
    # payload variant construction goes through MethodCall. Bare
    # GetField on a payload-having variant is invalid CLEAR (annotator
    # would have raised).
    return nil if Schemas.inline_struct?(var_data)
    UnitVariantAccess.new(type_name: type_name, variant_name: node.field)
  end

  sig { params(schema: Schemas::UnionSchema, field: T.any(String, Symbol)).returns(T.nilable(T.any(String, Symbol))) }
  def union_variant_key(schema, field)
    return field if schema.variants.key?(field)

    field_s = field.to_s
    return field_s if schema.variants.key?(field_s)

    field_sym = field_s.to_sym
    return field_sym if schema.variants.key?(field_sym)

    nil
  end

  # ================================================================
  # Pipeline (SMOOTH) operator
  # ================================================================

  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def lower_smooth(node)
    T.bind(self, MIRLowering) rescue nil
    function_state.current_decl_alloc = T.let(function_state.current_decl_alloc, T.nilable(Symbol))
    rhs = node.right

    return lower_complex_smooth(node) if AST.pipeline_complex_op?(rhs)
    return lower_collect_smooth(node, rhs) if rhs.is_a?(AST::CollectOp)
    return lower_recover_smooth(node, rhs) if rhs.is_a?(AST::RecoverOp)

    lower_call_smooth(node)
  end

  sig { params(node: AST::BinaryOp).returns(MIR::Node) }
  def lower_complex_smooth(node)
    T.bind(self, MIRLowering) rescue nil
    rhs = node.right
    source_type = node.left.is_a?(AST::RangeLit) ? :range : nil
    mir_result = pipeline_host.lower_pipeline(node)
    result_type = Type.from_node!(node, context: "pipeline result ownership")
    sink_alloc = if result_type.observable?
      :heap
    elsif ownership_tracked_transfer_type?(result_type)
      function_state.current_decl_alloc || placement_for_node(node)
    end
    return MIR::Pipeline.new(node, mir_result, source_type, nil, nil, sink_alloc) if mir_result

    Kernel.raise "lower_smooth: unsupported pipeline op #{rhs.class}; legacy pipeline fallback has been removed"
  end

  sig { params(node: AST::BinaryOp, rhs: AST::CollectOp).returns(MIR::Node) }
  def lower_collect_smooth(node, rhs)
    T.bind(self, MIRLowering) rescue nil
    left = T.cast(lower(node.left), MIR::Node)
    ft = node.left.full_type!
    collect_method = (ft.observable? && ft.tense_type&.array?) ? "materializeNext" : "next"
    collect_alloc = function_state.current_decl_or_frame_alloc
    collect_args = collect_method == "materializeNext" ? [MIR::AllocatorRef.new(collect_alloc)] : []
    collect_type = smooth_collect_type(ft, collect_method)
    collect_alloc_fact = collect_method == "materializeNext" ? collect_alloc : nil
    return smooth_collect_call(left, collect_method, collect_args, collect_type, collect_alloc_fact) if node.left.is_a?(AST::Identifier)

    smooth_collect_block(left, ft, collect_method, collect_args, collect_type, collect_alloc_fact)
  end

  sig { params(type_info: Type, collect_method: String).returns(Type) }
  def smooth_collect_type(type_info, collect_method)
    if collect_method == "materializeNext"
      elem_t = type_info.tense_type.element_type
      Type.new("#{T.must(elem_t).resolved}[]", collection: :list)
    else
      type_info.tense_type ? Type.new(type_info.tense_type) : Type.new(type_info)
    end
  end

  sig do
    params(
      receiver: MIR::Node,
      collect_method: String,
      collect_args: T::Array[MIR::Node],
      collect_type: Type,
      collect_alloc_fact: T.nilable(Symbol)
    ).returns(MIR::MethodCall)
  end
  def smooth_collect_call(receiver, collect_method, collect_args, collect_type, collect_alloc_fact)
    call = MIR::MethodCall.new(receiver, collect_method, collect_args, true,
      MIR::CallableContract.no_ownership(collect_args.length), collect_alloc_fact)
    call.result_type = collect_type
    call
  end

  sig do
    params(
      left: MIR::Node,
      ft: Type,
      collect_method: String,
      collect_args: T::Array[MIR::Node],
      collect_type: Type,
      collect_alloc_fact: T.nilable(Symbol)
    ).returns(MIR::BlockExpr)
  end
  def smooth_collect_block(left, ft, collect_method, collect_args, collect_type, collect_alloc_fact)
    T.bind(self, MIRLowering) rescue nil
    acc_zig = transpile_type(ft)
    block_id = lowering_counters.next_block_expr_id
    label = "__collect_blk_#{block_id}"
    collect_var = "__collect_acc_#{block_id}"
    val_var = "__collect_val_#{block_id}"
    left_effect = MIR::OwnershipEffect.of(left)
    collect_source_alloc = ft.observable? ? :heap : (left_effect.produces_owned ? (left_effect.alloc || :heap) : :heap)
    collect_cleanup = CleanupEntry.build(:uniform, alloc: collect_source_alloc,
      has_moved_guard: false, zig_type: acc_zig)
    MIR::BlockExpr.new(label, [
      MIR::Let.new(collect_var, left, false, ft, nil),
      MIR::Cleanup.new(collect_var, collect_cleanup),
      MIR::Let.new(val_var,
        smooth_collect_call(MIR::Ident.new(collect_var), collect_method, collect_args, collect_type, collect_alloc_fact),
        false, collect_type, nil),
      MIR::BreakStmt.new(label, MIR::Ident.new(val_var))
    ])
  end

  sig { params(node: AST::BinaryOp, rhs: AST::RecoverOp).returns(MIR::TryCatch) }
  def lower_recover_smooth(node, rhs)
    T.bind(self, MIRLowering) rescue nil
    left = lower(node.left)
    default_val = lower(rhs.default_expr)
    out = MIR::TryCatch.new(strip_try(left), default_val, nil)
    out.result_type = Type.new(node.full_type!(context: "RECOVER result"))
    out
  end

  sig { params(node: AST::BinaryOp).returns(MIR::Node) }
  def lower_call_smooth(node)
    T.bind(self, MIRLowering) rescue nil
    left = T.cast(lower(node.left), MIR::Node)
    snapshot_stmts = smooth_snapshot_stmts(node, left)
    left = MIR::Ident.new("__snap_input") if snapshot_stmts
    call_mir = lower_smooth_call_rhs(node)
    return call_mir unless snapshot_stmts

    label = "__snap_blk"
    MIR::BlockExpr.new(label, snapshot_stmts + [MIR::BreakStmt.new(label, call_mir)])
  end

  sig { params(node: AST::BinaryOp, left: MIR::Node).returns(T.nilable(T::Array[MIR::Stmt])) }
  def smooth_snapshot_stmts(node, left)
    T.bind(self, MIRLowering) rescue nil
    return nil unless current_function_has_catch? && current_function_snapshot_types.size == 1

    t = Type.new(node.left.full_type!)
    return nil unless t.catch_snapshot_payload?

    snap_zig_type = transpile_type(t)
    [
      MIR::Let.new("__snap_input", left, false, nil, nil),
      MIR::ExprStmt.new(
        MIR::MethodCall.new(MIR::Ident.new(runtime_binding_name), "captureSnapshot", [
          MIR::Ident.new(snap_zig_type),
          MIR::AddressOf.new(MIR::Ident.new("__snap_input"))
        ], false, MIR::CallableContract.no_ownership(2)), false)
    ]
  end

  sig { params(node: AST::BinaryOp).returns(MIR::Node) }
  def lower_smooth_call_rhs(node)
    T.bind(self, MIRLowering) rescue nil
    rhs = node.right
    if rhs.is_a?(AST::Identifier)
      return lower_smooth_identifier_call(node, rhs)
    elsif rhs.is_a?(AST::FuncCall)
      return lower_smooth_func_call(node, rhs)
    end

    Kernel.raise "MIRLowering: unhandled SMOOTH RHS #{rhs.class}"
  end

  sig { params(node: AST::BinaryOp, rhs: AST::Identifier).returns(MIR::Node) }
  def lower_smooth_identifier_call(node, rhs)
    T.bind(self, MIRLowering) rescue nil
    synthetic = AST::FuncCall.new(rhs.token, rhs.name, [node.left])
    AST.stamp_synthetic_type!(synthetic, node.full_type!(context: "pipeline synthetic call"), context: "synthetic AST type")
    synthetic.storage = node.storage
    synthetic.zig_pattern = rhs.zig_pattern if rhs.zig_pattern
    T.cast(lower_func_call(synthetic), MIR::Node)
  end

  sig { params(node: AST::BinaryOp, rhs: AST::FuncCall).returns(MIR::Node) }
  def lower_smooth_func_call(node, rhs)
    T.bind(self, MIRLowering) rescue nil
    synthetic = AST::FuncCall.new(rhs.token, rhs.name, [node.left] + rhs.args)
    AST.stamp_synthetic_type!(synthetic, node.full_type!(context: "pipeline synthetic call"), context: "synthetic AST type")
    synthetic.storage = node.storage
    synthetic.zig_pattern = rhs.zig_pattern if rhs.zig_pattern
    synthetic.coerced_type = rhs.coerced_type if rhs.coerced_type
    T.cast(lower_func_call(synthetic), MIR::Node)
  end

  # ================================================================
  # OR_RESCUE error chain
  # ================================================================

  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def lower_or_rescue(node)
    T.bind(self, MIRLowering) rescue nil
    facts = or_rescue_facts(node)

    left = lower(node.left)

    # OR RAISE: bubble up error (Zig's try)
    if node.right.is_a?(AST::OrRaise)
      # Extern trampolines already propagate errors internally (if frame.err |e| return e).
      # Wrapping in TryExpr produces invalid `try { block }` — Zig's try takes an expression.
      return left if left.is_a?(MIR::ExternTrampoline)
      return MIR::TryExpr.new(strip_try(left)) if facts.left_is_error
      return left
    end

    # OR EXIT <unified form>: selectively update kind / error_name /
    # message on rt.__error before propagating. Unspecified fields
    # inherit from whatever the failing call set. Kind-without-Type
    # clears the type explicitly (to avoid carrying a stale type
    # from the prior context that no longer matches the new kind).
    if node.right.is_a?(AST::OrExit)
      if facts.left_is_error && facts.target == :bc
        # Register VM: structured sibling (no Zig text). One InlineBc
        # carries the reassignment; RETURN error.CheatError propagates
        # via the bc error-union (EGUARD / inline-exit).
        ex = node.right
        exit_facts = or_exit_facts(ex, facts.line)
        msg_mir = ex.message ? lower(ex.message) : nil
        catch_block = MIR::ScopeBlock.new([
          MIR::ExprStmt.new(or_exit_bc_reassign(exit_facts, msg_mir), false),
          MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError"))
        ])
        return try_catch_with_provenance(left, catch_block, "__exit_err")
      end

      if facts.left_is_error
        ex = node.right
        exit_facts = or_exit_facts(ex, facts.line)
        msg_mir = ex.message ? lower(ex.message) : nil
        catch_block = or_exit_scope(exit_facts, msg_mir, MIR::Ident.new("__exit_err"))
        return try_catch_with_provenance(left, catch_block, "__exit_err")
      end
      return left
    end

    # OR PASS: ignore error (Zig's catch undefined)
    if node.right.is_a?(AST::OrPass)
      return try_catch_with_provenance(left, or_pass_fallback(node.left), nil) if facts.left_is_error
      return left
    end

    # OR BREAK: error-to-break (Zig's catch break)
    if node.right.is_a?(AST::OrBreak)
      return try_catch_with_provenance(left, MIR::BreakExpr.new(nil, nil), nil) if facts.left_is_error
      return left
    end

    # OR PRUNE: same as OR PASS for now
    if node.right.is_a?(AST::OrPrune)
      return try_catch_with_provenance(left, or_pass_fallback(node.left), nil) if facts.left_is_error
      return left
    end

    # Default: expr OR fallback -> error union catch or optional orelse.
    # The fallback is evaluated lazily (only when left short-circuits to it),
    # so any allocations done while lowering it must NOT escape to outer
    # function_state.pending_stmts. AST::BinaryOp#lazy_fields declares :right as lazy when
    # op == :OR_RESCUE; descend() consults that and wraps the right side in
    # a MIR::BlockExpr containing the scoped pending stmts. Hot path: zero
    # allocation. Fallback path: dupes (auto-COPY etc.) happen inside the
    # block, only when actually entered.
    fallback_type = or_fallback_expected_type(node)
    right = lower_scoped do
      with_expected_type(fallback_type) do
        materialize_or_fallback_value(lower(node.right), node.right)
      end
    end

    if facts.left_is_error
      return try_catch_with_provenance(left, right, nil, fallback: right)
    end

    # Optional orelse
    out = MIR::Orelse.new(left, right)
    out.result_type = Type.from_node!(node, context: "optional OR result")
    out
  end

  sig { params(node: AST::BinaryOp).returns(T.untyped) }
  def or_fallback_expected_type(node)
    T.bind(self, MIRLowering) rescue nil
    function_state.current_expected_type = T.let(function_state.current_expected_type, T.nilable(Type))
    left_type = Type.from_node!(node.left, context: "OR fallback left type")
    success = left_type.success_type
    return success if success && !success.any?

    error_union = node.left.respond_to?(:error_union_type) ? node.left.error_union_type : nil
    if error_union
      eu_type = Type.new(error_union)
      eu_success = eu_type.success_type
      return eu_success if eu_success && !eu_success.any?
    end

    function_state.current_expected_type || node.full_type!(context: "OR fallback expected type")
  end

  sig { params(value: T.untyped, ast_node: T.untyped).returns(T.untyped) }
  def materialize_or_fallback_value(value, ast_node)
    T.bind(self, MIRLowering) rescue nil
    return hoist_alloc(value, ast_node, err_cleanup: false) if mir_allocates?(value)
    return value unless or_fallback_access_path?(ast_node)

    return value unless ast_node.is_a?(AST::Locatable)
    ti = ast_node.full_type!(context: "OR fallback materialization")
    return value unless ti.string? || ti.recursive_cleanup_shape?(mir_schema_lookup) || ti.needs_cleanup?(mir_schema_lookup)

    alloc = function_state.current_decl_alloc || :heap
    copied = MIR::DeepCopy.new(value, ti.zig_type, nil, :full_value, alloc)
    hoist_alloc(copied, ast_node, err_cleanup: false)
  end

  sig { params(ast_node: T.untyped).returns(T::Boolean) }
  def or_fallback_access_path?(ast_node)
    ast_node.is_a?(AST::GetField) || ast_node.is_a?(AST::GetIndex)
  end

  sig { params(node: AST::BinaryOp).returns(OrRescueFacts) }
  def or_rescue_facts(node)
    T.bind(self, MIRLowering) rescue nil
    left_type = Type.from_node!(node.left, context: "OR/OR_RESCUE left")
    # CLEAR's auto-propagate strips `!T` from a fallible call's
    # full_type (so `x = call()` is x: T at the binding level). The
    # original `!T` is stashed on `error_union_type`. OR-RESCUE needs
    # to honor that to keep emitting `catch fallback` (error union)
    # rather than `orelse fallback` (optional).
    has_error_union = node.left.respond_to?(:error_union_type) && node.left.error_union_type
    can_fail = node.left.respond_to?(:can_fail) && node.left.can_fail
    OrRescueFacts.new(
      left_is_error: left_type.error_union? || can_fail || !!has_error_union,
      line: node.token&.line || 0,
      target: lowering_target
    )
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def or_pass_fallback(node)
    T.bind(self, MIRLowering) rescue nil
    ti = Type.from_node!(node, context: "OR fallback")
    ti = ti.success_type || ti
    return MIR::DefaultValue.new(kind: :string_empty) if ti.string?
    return MIR::DefaultValue.new(kind: :collection_empty, zig_type: ti.zig_type) if ti.list_collection?
    MIR::DefaultValue.new(kind: :undefined)
  end

  sig { params(node: AST::GetField).returns(T.untyped) }
  def lower_get_field(node)
    T.bind(self, MIRLowering) rescue nil
    constructor = unit_variant_constructor(node)
    return constructor if constructor

    target_node = node.target
    # Safe field access on any ?T: expr?.field
    # Always generate safe navigation so nil propagates instead of panicking.
    if target_node.is_a?(AST::OptionalUnwrap)
      inner_mir = lower(target_node.target)
      plan = field_access_plan(node, MIR::Ident.new("_r"))
      return MIR::IfOptional.new(
        inner_mir, "_r",
        plan.value,
        MIR::Lit.new("null")
      )
    end

    target = lower(node.target)
    field_access_plan(node, T.cast(target, MIR::Node)).value
  end

  sig { params(node: AST::GetField).returns(T.nilable(MIR::StructInit)) }
  def unit_variant_constructor(node)
    T.bind(self, MIRLowering) rescue nil
    target_node = node.target
    return nil unless target_node.is_a?(AST::Identifier)

    schema = union_schemas.dig(target_node.name.to_sym)
    return nil unless schema.is_a?(Schemas::UnionSchema)

    field_key = union_variant_key(schema, node.field)
    return nil unless field_key

    var_data = schema.variants[field_key]
    return nil if Schemas.inline_struct?(var_data)

    MIR::StructInit.new(target_node.name, [{ name: node.field.to_s, value: MIR::VoidLiteral.new }])
  end

  sig { params(node: AST::GetField, target: MIR::Node).returns(FieldAccessPlan) }
  def field_access_plan(node, target)
    T.bind(self, MIRLowering) rescue nil
    target_node = node.target
    ti = Type.from_node!(target_node, context: "field target")

    rc_map = capability_state.rc_unwrap_map || {}
    locked_map = capability_state.locked_unwrap_map || {}
    is_rc_unwrapped = T.let(target_node.is_a?(AST::Identifier) ? rc_map.key?(target_node.name.to_s) : false, T::Boolean)
    is_locked_unwrapped = T.let(target_node.is_a?(AST::Identifier) ? locked_map.key?(target_node.name.to_s) : false, T::Boolean)

    target_sync = if target_node.is_a?(AST::OptionalUnwrap)
      target_node.target.symbol&.sync
    else
      target_node.symbol&.sync
    end
    path = field_access_path(ti, target_sync, is_rc_unwrapped, is_locked_unwrapped)

    target_type_sym = ti.resolved.to_s.to_sym
    union_schema = union_schemas.dig(target_type_sym)
    union_variants = union_schema.is_a?(Schemas::UnionSchema) ? union_schema.variants : nil
    field_str = node.field.to_s
    union_payload = union_variants && (union_variants.key?(node.field) ||
                                       union_variants.key?(field_str) ||
                                       union_variants.key?(field_str.to_sym))

    FieldAccessPlan.new(
      target: target,
      field: field_str,
      path: path,
      union_payload: union_payload == true,
      union_payload_zig: union_payload ? ti.zig_type : nil,
      indirect: node.indirect_field == true,
    )
  end

  sig do
    params(
      type_info: Type,
      target_sync: T.nilable(Symbol),
      is_rc_unwrapped: T::Boolean,
      is_locked_unwrapped: T::Boolean
    ).returns(Symbol)
  end
  def field_access_path(type_info, target_sync, is_rc_unwrapped, is_locked_unwrapped)
    return :ctrl_data if (type_info.multiowned? || type_info.shared?) && !is_rc_unwrapped
    return :ctrl_data if (target_sync == :locked || target_sync == :write_locked) && !is_locked_unwrapped
    return :data if target_sync == :always_mutable && !is_locked_unwrapped
    :direct
  end

  sig { params(ex: AST::OrExit, line: T.untyped).returns(OrExitFacts) }
  def or_exit_facts(ex, line)
    kind = T.let(nil, T.nilable(String))
    error_name = T.let(nil, T.nilable(String))
    name_id = T.let(nil, T.nilable(Integer))
    clear_type = T.let(false, T::Boolean)

    if ex.kind
      kind = ex.kind.to_s
      if ex.error_name
        error_name = ex.error_name.to_s
        name_id = AST.id_of_type(ex.error_name.to_sym)
      else
        clear_type = true
      end
    elsif ex.error_name && AST.error_type?(ex.error_name.to_sym)
      kind = AST.kind_of_type(ex.error_name.to_sym).to_s
      error_name = ex.error_name.to_s
      name_id = AST.id_of_type(ex.error_name.to_sym)
    end

    OrExitFacts.new(
      kind: kind,
      error_name: error_name,
      name_id: name_id,
      clear_type: clear_type,
      has_message: !ex.message.nil?,
      line: line.to_i
    )
  end

  sig { params(field: String).returns(MIR::FieldGet) }
  def runtime_error_field(field)
    T.bind(self, MIRLowering) rescue nil
    MIR::FieldGet.new(MIR::FieldGet.new(MIR::Ident.new(runtime_binding_name), "__error"), field)
  end

  sig { params(facts: OrExitFacts).returns(T::Array[T.untyped]) }
  def or_exit_error_update_stmts(facts)
    T.bind(self, MIRLowering) rescue nil
    stmts = T.let([], T::Array[T.untyped])
    if facts.kind
      stmts << MIR::Set.new(runtime_error_field("kind"), MIR::EnumTag.new(variant: T.must(facts.kind)))
      if facts.error_name
        name_id = MIR::EnumOrdinal.new(
          MIR::FieldGet.new(MIR::Ident.new("ErrorName"), facts.error_name),
        )
        stmts << MIR::Set.new(runtime_error_field("error_name"), name_id)
      elsif facts.clear_type
        stmts << MIR::Set.new(runtime_error_field("error_name"), MIR::Lit.new("0"))
      end
    end
    stmts
  end

  sig { params(facts: OrExitFacts, msg_mir: T.nilable(MIR::Node)).returns(MIR::OrExitBcRewrite) }
  def or_exit_bc_reassign(facts, msg_mir)
    MIR::OrExitBcRewrite.new(
      facts.kind,
      facts.name_id,
      facts.clear_type,
      facts.has_message,
      facts.line,
      msg_mir,
    )
  end

  sig { params(facts: OrExitFacts, msg_mir: T.nilable(MIR::Node), return_value: MIR::Node).returns(MIR::ScopeBlock) }
  def or_exit_scope(facts, msg_mir, return_value)
    T.bind(self, MIRLowering) rescue nil
    stmts = or_exit_error_update_stmts(facts)
    stmts << MIR::Set.new(runtime_error_field("message"), msg_mir) if msg_mir
    stmts << MIR::Set.new(runtime_error_field("clear_line"), MIR::Lit.new(facts.line.to_s))
    stmts << MIR::ReturnStmt.new(return_value)
    MIR::ScopeBlock.new(stmts.map { |s| (s.is_a?(MIR::ReturnStmt) || s.is_a?(MIR::Set)) ? s : MIR::ExprStmt.new(s, false) })
  end

  sig { params(node: AST::BinaryOp).returns(BinaryIntArithmeticFacts) }
  def binary_int_arithmetic_facts(node)
    left_ti = node.left.full_type!(context: "binary left operand")
    right_ti = node.right.full_type!(context: "binary right operand")
    BinaryIntArithmeticFacts.new(
      both_int: left_ti&.integer? == true && right_ti&.integer? == true,
      has_comptime_number_literal: comptime_number_literal?(node.left, left_ti) ||
        comptime_number_literal?(node.right, right_ti),
      has_float_coercion: float_coercion?(node.left) || float_coercion?(node.right)
    )
  end

  sig { params(node: T.untyped, ti: T.nilable(Type)).returns(T::Boolean) }
  def comptime_number_literal?(node, ti)
    return false unless node.is_a?(AST::Literal)
    return false unless node.type == :NUMBER
    ti.nil? || !ti.integer?
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def float_coercion?(node)
    coerced = node.coerced_type_info
    return false if coerced.nil?
    coerced.integer? != true
  end

  sig { params(node: AST::GetIndex).returns(MIR::Node) }
  def lower_get_index(node)
    T.bind(self, MIRLowering) rescue nil
    plan = index_access_plan(node)
    value = index_access_value(plan)
    return MIR::IfOptional.new(T.must(plan.optional_source), "_r", value, MIR::Lit.new("null")) if plan.optional?

    value
  end

  sig { params(node: AST::GetIndex).returns(IndexAccessPlan) }
  def index_access_plan(node)
    T.bind(self, MIRLowering) rescue nil
    target_node = node.target
    target_ast = T.cast(target_node, AST::Node)
    optional = target_node.is_a?(AST::OptionalUnwrap)
    optional_source = optional ? T.cast(lower(target_node.target), MIR::Node) : nil
    target = optional ? MIR::Ident.new("_r") : T.cast(lower(target_node), MIR::Node)

    IndexAccessPlan.new(
      target: target,
      index: T.cast(lower(node.index), MIR::Node),
      optional: optional,
      optional_source: optional_source,
      target_ast: target_ast,
      type_info: Type.from_node!(target_node, context: "index target"),
      target_name: target_node.is_a?(AST::Identifier) ? target_node.name : nil,
      needs_mut_ref: node.needs_mut_ref == true,
    )
  end

  sig { params(plan: IndexAccessPlan).returns(MIR::Node) }
  def index_access_value(plan)
    T.bind(self, MIRLowering) rescue nil
    shard = shard_context

    # Auto-deref Arc/Rc-wrapped maps: target.ctrl.data.*
    # Zig only -- BC has no Arc-wrapping (values are uniformly value-typed
    # and shared maps live as a single MapRef cell). Without this gate the
    # PUT path (which short-circuits the Arc deref for BC) and the GET
    # path use different identifiers; PUTs land in `map` while GETs read
    # from `Deref(map.ctrl.data)` and miss every entry.
    target = plan.target
    index = plan.index
    ti = plan.type_info
    if ti.rc_map? && !bc_target?
      target = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(target, "ctrl"), "data"))
    end

    return index_collection_value(target, index, plan) if plan.optional?

    if plan.target_ast.metatype == :hashmap
      map_ft = Type.from_node!(plan.target_ast, context: "hashmap index target")
      kind = map_ft.numeric_map? ? :numeric_map : :string_map
      op_spec = INDEX_OPS.dig(kind, :get)
      op = FunctionSignature.unwrap(IntrinsicRegistry.fs(op_spec, :"#{kind}_get"))
      raise "indexed access: missing registry signature for #{kind}" unless op

      # Structural MIR::ShardedMapGet for both backends. Carries the
      # full INDEX_OPS entry (templates, ownership effects) so the
      # checker can validate ownership semantics. shard_idx is set
      # only inside a SHARD pipeline body where the shard index var
      # is computed by the surrounding loop -- direct dispatch skips
      # routing.
      shard_direct = shard && plan.target_name == shard[:map]
      template_kind = if shard_direct then :shard_direct_zig
                      elsif (map_ft.sharded? || map_ft.striped?) && op.intrinsic_template(:sharded_zig)
                        :sharded_zig
                      else :zig
                      end
      resolved_allocs = T.let({}, T::Hash[Symbol, Symbol])
      [:alloc, :key_alloc, :val_alloc, :shard_alloc].each do |alloc_key|
        registry_alloc = indexed_assignment_registry_alloc(op, alloc_key)
        next unless registry_alloc
        sym = registry_alloc || :heap
        resolved_allocs[alloc_key] = resolve_alloc_sym(sym, plan.target_ast, plan.target_ast)
      end
      alloc_metadata = MIR::InlineAllocMetadata.new(resolved_allocs)
      key_type = (kind == :numeric_map) ? map_ft.key_type : nil
      value_type = (kind == :numeric_map) ? map_ft.value_type : nil
      if shard_direct
        return MIR::ShardedMapGet.new(target, index,
          MIR::Ident.new(shard[:idx]),
          MIR::Ident.new(shard[:key]),
          kind, op, key_type, value_type, alloc_metadata, template_kind)
      end
      MIR::ShardedMapGet.new(target, index, nil, nil, kind, op, key_type, value_type, alloc_metadata, template_kind)
    elsif ti.pool?
      # Both backends consume MIR::InlineBc(:get, [target, index], POOL_METHODS["get"]).
      # BC dispatches via compile_inline_bc :get on tag == :pool_method
      # (-> list-ref). Zig emits {0}.get({1}) from stdlib_def[:zig]. The
      # `elem` field carries the element type name so bc_emitter can
      # stamp the capture slot's struct hint when this gets bound via
      # `IF pool[id] AS env`.
      elem_t = ti.element_type
      elem_name = elem_t.respond_to?(:resolved) ? T.must(elem_t).resolved.to_s : elem_t.to_s
      pool_get_def = T.must(IntrinsicRegistry.sig(POOL_METHODS, "get")).dup
      pool_get_def.emit = (pool_get_def.emit ? pool_get_def.emit.dup : IntrinsicEmit.new)
      pool_get_def.emit.elem = elem_name
      return MIR::InlineBc.new(:get, [target, index], pool_get_def)
    elsif plan.needs_mut_ref
      # target.items[@as(usize, @intCast(index))]
      items = MIR::ListItems.new(target)
      cast_idx = MIR::Cast.new(index, "usize", :intCast)
      MIR::IndexGet.new(items, cast_idx)
    else
      index_collection_value(target, index, plan)
    end
  end

  sig { params(target: MIR::Node, index: MIR::Node, plan: IndexAccessPlan).returns(MIR::Node) }
  def index_collection_value(target, index, plan)
    T.bind(self, MIRLowering) rescue nil
    ti = plan.type_info
    if ti.set_collection?
      elem_zig = T.must(ti.element_type).zig_type
      emit_builtin(:setMemberGet, [target, index, MIR::Ident.new(elem_zig)])
    elsif ti.direct_indexable_collection?
      lower_direct_or_builtin_index_get(target, index, plan.target_ast, ti)
    else
      lower_builtin_index_get(target, index, ti)
    end
  end

  sig { params(target: MIR::Node, index: MIR::Node, ast_node: AST::Node, ti: Type).returns(MIR::Node) }
  def lower_direct_or_builtin_index_get(target, index, ast_node, ti)
    T.bind(self, MIRLowering) rescue nil
    direct_index_get(target, index, ast_node, ti) || lower_builtin_index_get(target, index, ti)
  end

  sig { params(target: MIR::Node, index: MIR::Node, ti: Type).returns(T.any(MIR::InlineBc, MIR::RegistryCall)) }
  def lower_builtin_index_get(target, index, ti)
    T.bind(self, MIRLowering) rescue nil
    builtin = INDEX_OPS.dig(ti.dispatch_key, :get, :builtin) || :getAt
    emit_builtin(builtin, [target, index])
  end

  # Resolves field-name -> Type for both struct and union schemas. Returns {}
  # when no schema is registered (e.g. tuple-style literals) so callers can
  # safely lookup without nil checks.
  sig { params(node: AST::StructLit).returns(T::Hash[String, StructLitFieldType]) }
  def struct_lit_field_types(node)
    T.bind(self, MIRLowering) rescue nil
    schema = mir_schema_lookup.call(node.name.to_sym)
    case schema
    when Schemas::UnionSchema
      union_subst = T.let({}, StructLitTypeSubst)
      schema.variants.each_with_object({}) { |(k, t), h| h[k.to_s] = substitute_mir_type(t, union_subst) }
    when Schemas::StructSchema
      struct_subst = struct_lit_type_subst(schema, node)
      schema.fields.each_with_object({}) do |(k, f), h|
        raw = f.is_a?(AST::StructField) ? f.type : f
        h[k.to_s] = substitute_mir_type(raw, struct_subst)
      end
    else
      {}
    end
  end

  sig { params(schema: T.any(Schemas::StructSchema, Schemas::InlineStructVariant), node: AST::StructLit).returns(StructLitTypeSubst) }
  def struct_lit_type_subst(schema, node)
    params = schema.is_a?(Schemas::StructSchema) ? schema.type_params : nil
    args = node.type_args || []
    return {} unless params&.any? && args.any?
    out = T.let({}, StructLitTypeSubst)
    params.zip(args).each do |param, arg|
      next unless param
      out[param.to_sym] = arg
    end
    out
  end

  sig { params(raw_type: StructLitFieldType, subst: StructLitTypeSubst).returns(StructLitFieldType) }
  def substitute_mir_type(raw_type, subst)
    return raw_type if subst.empty?
    return raw_type unless raw_type
    return raw_type if raw_type.is_a?(Schemas::InlineStructVariant)

    type_input = raw_type
    t = Type.new(type_input)
    resolved = t.resolved
    if subst.key?(resolved)
      replacement = Type.new(subst.fetch(resolved))
      copy_type_capabilities(t, replacement)
      return replacement
    end

    if t.generic_instance?
      new_args = t.generic_args.map { |arg| T.cast(substitute_mir_type(arg, subst), Type::TypeInput) }
      replacement = Type.generic_instance_of(t.generic_base, new_args)
      copy_type_capabilities(t, replacement)
      return replacement
    end

    if t.array?
      element_type = T.must(t.element_type)
      new_element = T.cast(substitute_mir_type(element_type, subst), Type::TypeInput)
      return raw_type if Type.surface_name(element_type) == Type.surface_name(new_element)

      replacement = Type.array_of(new_element, capacity: t.capacity)
      copy_type_capabilities(t, replacement)
      return replacement
    end

    if t.error_union?
      payload_type = T.must(t.payload_type)
      new_payload = T.cast(substitute_mir_type(payload_type, subst), Type::TypeInput)
      return raw_type if Type.surface_name(payload_type) == Type.surface_name(new_payload)

      replacement = Type.error_union_of(new_payload)
      copy_type_capabilities(t, replacement)
      return replacement
    end

    if t.optional?
      wrapped_type = T.must(t.wrapped_type)
      new_wrapped = T.cast(substitute_mir_type(wrapped_type, subst), Type::TypeInput)
      return raw_type if Type.surface_name(wrapped_type) == Type.surface_name(new_wrapped)

      replacement = Type.optional_of(new_wrapped)
      copy_type_capabilities(t, replacement)
      return replacement
    end

    if t.tense?
      tense_type = t.tense_type
      new_tense_type = T.cast(substitute_mir_type(tense_type, subst), Type::TypeInput)
      return raw_type if Type.surface_name(tense_type) == Type.surface_name(new_tense_type)

      replacement = Type.tense_of(new_tense_type)
      copy_type_capabilities(t, replacement)
      return replacement
    end

    raw_type
  end

  sig { params(source: Type, target: Type).void }
  def copy_type_capabilities(source, target)
    target.merge_capabilities_from!(source)
  end

  # True when the destination is a dynamic slice (`[]T`, no capacity), as
  # opposed to a fixed-capacity array (`[N]T`) or an owning container
  # (`@list` / `@set` / `@pool`). Comptime selector handles ArrayList -> .items
  # vs slice passthrough at zero cost.
  sig { params(ft: T.nilable(Type), k: T.any(String, Symbol), node: AST::StructLit).returns(T::Boolean) }
  def struct_field_wants_slice?(ft, k, node)
    T.bind(self, MIRLowering) rescue nil
    return true if node.borrowed_field_names&.include?(k.to_s)
    aggregate_field_wants_dynamic_slice?(ft)
  end

  sig { params(ft: T.nilable(Type)).returns(T::Boolean) }
  def aggregate_field_wants_dynamic_slice?(ft)
    return false unless ft
    ft.array? && ft.dynamic? && !ft.collection? && !ft.string?
  end

  sig { params(val: MIR::Node, ft: T.nilable(Type), borrowed_field: T::Boolean, sink_alloc: Symbol, ast_node: T.nilable(AST::Node)).returns(MIR::Node) }
  def aggregate_dynamic_slice_field_value(val, ft, borrowed_field, sink_alloc, ast_node = nil)
    return val unless aggregate_field_wants_dynamic_slice?(ft)
    return MIR::ItemsAccess.new(val, true) if borrowed_field

    source = T.cast(T.unsafe(self).mir_produces_owned_result?(val) && !val.is_a?(MIR::Ident) ?
      T.unsafe(self).hoist_alloc(val, ast_node, err_cleanup: true) : val, MIR::Node)
    T.cast(T.unsafe(self).with_ownership_consumption(
      MIR::OwnedSlice.new(source, sink_alloc),
      T.unsafe(self).mir_ident_names(source),
      "MIR::OwnedSlice",
      target_alloc: sink_alloc,
    ), MIR::OwnedSlice)
  end

  sig { params(node: AST::StructLit).returns(T.untyped) }
  def lower_struct_lit(node)
    T.bind(self, MIRLowering) rescue nil
    hoisted = []
    field_types = struct_lit_field_types(node)
    struct_alloc = alloc_for_node(node)

    fields = node.fields.map { |k, v|
      ft = field_types[k.to_s]
      field_type_input = T.let(ft.is_a?(Schemas::InlineStructVariant) ? nil : ft, T.nilable(Type::TypeInput))
      borrowed_field = T.let(node.borrowed_field_names&.include?(k.to_s) == true, T::Boolean)
      field_node = borrowed_field && v.is_a?(AST::CopyNode) ? v.value : v
      field_sink_alloc = aggregate_field_sink_alloc(field_type_input, field_node, struct_alloc)
      move_mark_field!(field_node)
      expected_ft = field_type_input ? (field_type_input.is_a?(Type) ? field_type_input : Type.new(field_type_input)) : nil
      val = with_decl_alloc(field_sink_alloc) do
        with_expected_type(expected_ft) do
        if borrowed_field
          aggregate_dynamic_slice_field_value(lower(field_node), expected_ft, true, field_sink_alloc, field_node)
        elsif rc_retain_needed?(field_node)
          hoist_alloc(make_rc_retain(field_node), field_node, err_cleanup: true)
        elsif field_node.is_a?(AST::CopyNode) && expected_ft&.collection?
          hoist_alloc(MIR::DeepCopy.new(lower(field_node.value), expected_ft.zig_type, nil, :full_value, field_sink_alloc),
            field_node, err_cleanup: true)
        else
          field_value = materialize_owned_sink_value(lower(field_node), field_node, field_sink_alloc, field_type_input)
          if struct_field_wants_slice?(expected_ft, k, node)
            field_value = aggregate_dynamic_slice_field_value(field_value, expected_ft, borrowed_field, field_sink_alloc, field_node)
          end
          field_alloc = mir_owned_alloc(field_value)
          lowered = hoist_alloc(field_value, field_node, err_cleanup: true)
          if expected_ft && recursive_field_copy_required?(expected_ft, field_node, field_alloc, field_sink_alloc)
            hoist_alloc(MIR::DeepCopy.new(lowered, expected_ft.zig_type, nil, :full_value, field_sink_alloc),
              field_node, err_cleanup: true)
          else
            lowered
          end
        end
        end
      end
      # @indirect field: hoist HeapCreate to a named temp so it is a Let-init,
      # not an anonymous sub-expression (INV-H).
      if v.needs_heap_create
        zig_t = transpile_type(v.full_type!.resolved.to_s)
        temp = "__ind_#{lowering_counters.next_block_expr_id}_#{k}"
        hc = T.cast(with_ownership_consumption_for_value(
          MIR::HeapCreate.new(zig_t, val, :heap, "blk_#{k}"),
          val,
          field_node,
          "MIR::HeapCreate",
          target_alloc: :heap,
        ), MIR::HeapCreate)
        hoisted.concat(MIR::BindingMaterialization.new(
          name: temp,
          expr: hc,
          alloc: :heap,
          type_info: v.full_type!(context: "indirect struct field allocation"),
          mutable: false,
          scope: :heap
        ).statements)
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

    init = T.cast(with_ownership_consumption(
      MIR::StructInit.new(type_name, fields),
      fields.flat_map { |field| field[:alloc].is_a?(Symbol) ? mir_ident_names(field[:value]) : [] },
      "MIR::StructInit",
      target_alloc: struct_alloc,
    ), MIR::StructInit)

    # Struct literals remain value-shaped. Heap/frame placement is a storage
    # decision for the owning binding or wrapper; it must not change `T` into
    # `*T` here, or ordinary RVO/value returns and container inserts break.
    result = init

    wrap_indirect_field_hoists(hoisted, result)
  end

  sig { params(node: AST::UnionVariantLit).returns(T.untyped) }
  def lower_union_variant_lit(node)
    T.bind(self, MIRLowering) rescue nil
    # Collect hoisted statements for @indirect fields (same pattern as lower_struct_lit).
    hoisted = []
    variant_alloc = alloc_for_node(node)
    variant_field_types = union_variant_lit_field_types(node)

    variant_struct_name = "#{node.union_name}_#{node.variant_name}"
    field_values = node.fields.map { |k, v|
      ft = variant_field_types[k.to_s]
      expected_ft = ft ? (ft.is_a?(Type) ? ft : Type.new(ft)) : nil
      field_sink_alloc = aggregate_field_sink_alloc(ft, v, variant_alloc)
      # err_cleanup: union owns its payload on success; only clean up on error.
      move_mark_field!(v)
      val = with_decl_alloc(field_sink_alloc) do
        with_expected_type(expected_ft) do
        materialized = materialize_owned_sink_value(lower(v), v, field_sink_alloc, ft)
        materialized = aggregate_dynamic_slice_field_value(materialized, expected_ft, false, field_sink_alloc, v)
        hoist_alloc(materialized, v, err_cleanup: true)
        end
      end
      # @indirect is signalled by the annotator's needs_heap_create stamp
      # (same single source the struct-literal path reads).
      if v.needs_heap_create
        field_sym = Type.from_node!(v, context: "indirect union field").resolved
        zig_t = transpile_type(field_sym.to_s)
        # @indirect union fields: HeapCreate emits __p.* = val (shallow copy).
        # Borrowed field access has no owned local to transfer, so the
        # indirect cell needs an independent copy. Identifier payloads move
        # into the cell and are guarded by ordinary ownership transfer marks.
        needs_deep_cleanup = union_schemas.key?(field_sym) && v.is_a?(AST::GetField)
        if needs_deep_cleanup
          val = MIR::DeepCopy.new(val, zig_t, nil, :full_value, :heap)
        end
        temp = "__ind_#{lowering_counters.next_block_expr_id}_#{k}"
        hc = T.cast(with_ownership_consumption_for_value(
          MIR::HeapCreate.new(zig_t, val, :heap, "blk_#{k}"),
          val,
          v,
          "MIR::HeapCreate",
          target_alloc: :heap,
        ), MIR::HeapCreate)
        hoisted.concat(MIR::BindingMaterialization.new(
          name: temp,
          expr: hc,
          alloc: :heap,
          type_info: v.full_type!(context: "indirect union field allocation"),
          mutable: false,
          scope: :heap
        ).statements)
        if needs_deep_cleanup
          # Deep copy owns heap data inside __p.*; errdefer must clean it up
          # before destroying the pointer, otherwise those allocations leak.
          cleanup_call = emit_builtin(:cleanup, [
            MIR::Ident.new(zig_t),
            MIR::AllocatorRef.new(:heap),
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

    inner = T.cast(with_ownership_consumption(
      MIR::StructInit.new(variant_struct_name, field_values),
      field_values.flat_map { |field| field[:alloc].is_a?(Symbol) ? mir_ident_names(field[:value]) : [] },
      "MIR::StructInit",
      target_alloc: variant_alloc,
    ), MIR::StructInit)
    result = T.cast(with_ownership_consumption(
      MIR::StructInit.new(node.union_name.to_s, [
        { name: node.variant_name.to_s, value: inner }
      ]),
      mir_ident_names(inner),
      "MIR::StructInit",
      target_alloc: variant_alloc,
    ), MIR::StructInit)

    wrap_indirect_field_hoists(hoisted, result)
  end

  sig { params(hoisted: T::Array[MIR::Node], result: MIR::Node).returns(MIR::Node) }
  def wrap_indirect_field_hoists(hoisted, result)
    T.bind(self, MIRLowering) rescue nil
    return result if hoisted.empty?

    label = "__ind_blk_#{lowering_counters.next_block_expr_id}"
    local_alloc_names = hoisted.each_with_object(Set.new) do |stmt, names|
      names << stmt.name.to_s if stmt.is_a?(MIR::AllocMark)
    end
    alloc_by_name = hoisted.each_with_object({}) do |stmt, allocs|
      allocs[stmt.name.to_s] = stmt.alloc if stmt.is_a?(MIR::AllocMark)
    end
    result_names = mir_ident_names(result).map(&:to_s).to_set
    local_alloc_names.intersection(result_names).each do |name|
      hoisted.concat(ownership_transfer_marks(name, :block_result, target_alloc: alloc_by_name[name]))
    end
    hoisted << MIR::BreakStmt.new(label, result)
    inherited_alloc_names = function_state.lowered_alloc_names.dup
    inherited_guarded_names = function_state.lowered_guarded_cleanup_names.dup
    function_state.guarded_cleanup_names.each_key do |name|
      inherited_guarded_names << name.to_s
    end
    MIR::BlockExpr.new(label, append_ownership_transfers_for_mir_body(
      hoisted,
      inherited_alloc_names,
      inherited_guarded_names,
    ))
  end

  sig { params(node: AST::UnionVariantLit).returns(UnionVariantFieldTypes) }
  def union_variant_lit_field_types(node)
    T.bind(self, MIRLowering) rescue nil
    schema = union_schemas[node.union_name.to_sym]
    return {} unless schema.is_a?(Schemas::UnionSchema)
    variant_data = schema.variants[node.variant_name.to_sym] || schema.variants[node.variant_name.to_s]
    return {} unless variant_data

    if Schemas.inline_struct?(variant_data)
      fields = T.cast(variant_data, Schemas::InlineStructVariant).fields
      fields.each_with_object(T.let({}, UnionVariantFieldTypes)) do |(k, field_type), h|
        h[k.to_s] = field_type
      end
    elsif node.fields.length == 1
      key = node.fields.keys.first.to_s
      { key => Type.from_node(T.cast(variant_data, Type::TypeInput)) }
    else
      {}
    end
  end

  sig { params(_field_type: T.nilable(Type::TypeInput), value: AST::Node, aggregate_alloc: Symbol).returns(Symbol) }
  def aggregate_field_sink_alloc(_field_type, value, aggregate_alloc)
    T.bind(self, MIRLowering) rescue nil
    if value.is_a?(AST::Identifier)
      ti = Type.from_node!(value, context: "aggregate field sink")
      if ownership_tracked_transfer_type?(ti) &&
         (AST.moved?(value) || value.symbol&.heap_storage?)
        source_alloc = placement_for_node(value)
        return source_alloc if source_alloc == aggregate_alloc
      end
    end

    aggregate_alloc
  end

  sig { params(node: AST::StringConcat).returns(MIR::ConcatStr) }
  def lower_string_concat(node)
    T.bind(self, MIRLowering) rescue nil
    parts = node.parts.map { |p| hoist_alloc(lower(p), p) }
    alloc = alloc_for_node(node)
    MIR::ConcatStr.new(parts, alloc, runtime_binding_name)
  end

  sig { params(node: AST::BlockExpr).returns(MIR::BlockExpr) }
  def lower_block_expr(node)
    T.bind(self, MIRLowering) rescue nil
    label = "__blk_#{lowering_counters.next_block_expr_id}"
    transfer_name = T.let(nil, T.nilable(String))
    if node.result.is_a?(AST::Identifier)
      raw_name = node.result.name.to_s
      entry = function_state.bindings[raw_name]
      transfer_name = zig_safe_name(raw_name)
      if entry&.needs_cleanup?
        entry.mark_moved_guard!
        function_state.guarded_cleanup_names[transfer_name] = true
      end
    end
    body = lower_body(node.body)
    result = lower(node.result)
    if transfer_name
      cleanup = body.find do |stmt|
        (stmt.is_a?(MIR::Cleanup) || stmt.is_a?(MIR::ErrCleanup)) && stmt.name.to_s == transfer_name
      end
      if cleanup
        T.cast(cleanup, T.any(MIR::Cleanup, MIR::ErrCleanup)).cleanup_entry.mark_moved_guard!
        body.concat(ownership_transfer_marks(transfer_name, :block_result, move_guarded: true))
      end
    end
    body << MIR::BreakStmt.new(label, result)
    MIR::BlockExpr.new(label, body)
  end

  sig { params(node: AST::RangeLit).returns(MIR::RangeLit) }
  def lower_range_lit(node)
    T.bind(self, MIRLowering) rescue nil
    s = lower(node.start)
    e = lower(node.finish)
    elem_type = node.full_type!.tense_type&.element_type&.resolved
    range = if node.inclusive
      MIR::RangeLit.new(s, MIR::BinOp.new("+", e, MIR::Lit.new("1")), elem_type)
    else
      MIR::RangeLit.new(s, e, elem_type)
    end
    range.result_type = Type.new(node.full_type!)
    range
  end

  sig { params(node: AST::Slice).returns(MIR::SliceExpr) }
  def lower_slice(node)
    T.bind(self, MIRLowering) rescue nil
    target = lower(node.target)
    start_expr = lower(node.start)
    end_expr = lower(node.end)
    exclusive = node.exclusive

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

    elem_zig = node.target.full_type!.element_type ? Type.new(node.target.full_type!.element_type).zig_type : "u8"
    MIR::SliceExpr.new(target, start_cast, end_cast, elem_zig)
  end

  sig { params(node: AST::Assert).returns(T.any(MIR::AssertStmt, MIR::InlineBc, MIR::Call)) }
  def lower_assert(node)
    T.bind(self, MIRLowering) rescue nil
    # Specialized lowering for `ASSERT a == b` — dispatch to one of
    # Zig's stdlib testing helpers so failures get a structured diff
    # instead of a bare `assertion failed` panic. Falls back to
    # CheatLib.assert for non-equality conditions and for `!=`.
    #
    # Skip for the :bc (register VM) target: the bytecode VM cannot
    # execute raw Zig, so a raw Zig assert helper would leave the
    # test register-pending forever. The CheatLib.assert fallback path
    # below evaluates the condition as a normal MIR expression and
    # routes through the runtime's bool-assert opcode.
    if !bc_target? && (eq_lowering = try_lower_equality_assert(node))
      return eq_lowering
    end

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
    MIR::AssertStmt.new(cond, "\"#{msg}\"")
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
  sig { params(node: AST::Assert).returns(T.nilable(MIR::Call)) }
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
    left_mir = hoist_alloc(lower(left), left)
    right_mir = hoist_alloc(lower(right), right)

    helper, extra_args = pick_equality_helper(left, right)
    return nil unless helper

    # Argument order matches the Zig stdlib convention: expected
    # first, actual second. CLEAR doesn't distinguish, so we use
    # left=expected, right=actual.
    args_mir = T.let(extra_args.map { |arg| MIR::Ident.new(arg) }, T::Array[MIR::Emittable])
    args_mir << T.cast(left_mir, MIR::Emittable)
    args_mir << T.cast(right_mir, MIR::Emittable)
    params = args_mir.each_index.map do |idx|
      AST::Param.new(name: "__assert_eq_arg#{idx}", type: Type.new(:Any))
    end
    sig = FunctionSignature.new(params: params, return_type: Type.new(:Void), intrinsic: true)
    sig.can_fail = true
    sig.emit = IntrinsicEmit.new(borrows: :all)
    contract = MIR::OwnershipContract.new(covers_consuming_params: true)
    MIR::Call.new(
      "std.testing.#{helper}",
      args_mir,
      true,
      false,
      MIR::CallableContract.new(sig, contract, args_mir.length),
    )
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

    if (lt&.string_comparable_with?(rt)) || (rt&.string_comparable_with?(lt))
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
    rt = MIR::Ident.new(runtime_binding_name)
    kind = (node.kind || :Unknown).to_s
    # error_name is a u32 id into the per-program ErrorName enum.
    name_expr = if node.error_name && !node.error_name.empty?
      MIR::EnumOrdinal.new(MIR::FieldGet.new(MIR::Ident.new("ErrorName"), node.error_name))
    else
      MIR::Lit.new("0")
    end
    msg_expr = node.message_expr ? lower(node.message_expr) : MIR::Lit.new('""')
    line = node.token.line.to_s

    set_error = MIR::MethodCall.new(rt, "setError", [
      MIR::EnumTag.new(variant: kind),
      name_expr,
      msg_expr,
      MIR::Lit.new(line)
    ], false, MIR::CallableContract.no_ownership(4))

    ret = MIR::ReturnStmt.new(MIR::FieldGet.new(MIR::Ident.new("error"), "CheatError"))
    MIR::ScopeBlock.new([MIR::ExprStmt.new(set_error, false), ret])
  end

  # ================================================================
  # Memory / capability expressions
  # ================================================================

  sig { params(node: AST::CopyNode).returns(MIR::Node) }
  def lower_copy(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    function_state.current_sink_type = T.let(function_state.current_sink_type, T.nilable(Type))
    function_state.current_expected_type = T.let(function_state.current_expected_type, T.nilable(Type))
    source = lower(node.value)
    source = hoist_alloc(source, node.value) if mir_allocates?(source)
    ti = copy_source_type_info(node.value)
    sink_type = function_state.current_sink_type || function_state.current_expected_type
    dst_ti = sink_type ? (sink_type.is_a?(Type) ? sink_type : Type.new(sink_type)) : ti
    # Copy placement is destination-driven. Auto-COPY sites may stamp alloc
    # directly; otherwise the active sink allocator flows through
    # with_decl_alloc. Only a context-free explicit COPY defaults to heap.
    alloc = function_state.current_decl_alloc || node.alloc || :heap

    if ti.any_rc?
      func = ti.shared? ? "arcRetain" : "rcRetain"
      MIR::RcRetain.new(source, rc_payload_zig_type(ti), func)
    elsif ti.optional? && ti.needs_cleanup?(mir_schema_lookup)
      MIR::DeepCopy.new(source, ti.zig_type, nil, :full_value, alloc)
    elsif ti.string?
      MIR::DeepCopy.new(source, "[]const u8", nil, :full_value, alloc)
    elsif ti.direct_indexable_collection? && dst_ti.direct_indexable_collection? && !dst_ti.string?
      copy_zig = copy_source_zig_type(node.value, ti, dst_ti)
      MIR::DeepCopy.new(source, copy_zig, nil, :full_value, alloc)
    else
      copy_zig = if dst_ti.collection? && !dst_ti.string?
                   dst_ti.zig_type
                 elsif union_schemas.key?(ti.resolved)
                   transpile_type(ti.resolved.to_s)
                 elsif ti.any_sync? || ti.collection_value? || ti.collection? ||
                       (ti.struct? && ti.needs_promotion?(mir_schema_lookup))
                   ti.zig_type
                 end
      copy_zig ? MIR::DeepCopy.new(source, copy_zig, nil, :full_value, alloc) :
                 MIR::DeepCopy.new(source, nil, nil, :passthrough, nil)
    end
  end

  sig { params(source: T.untyped).returns(Type) }
  def copy_source_type_info(source)
    if source.respond_to?(:typed?) && source.typed?
      return source.full_type!(context: "COPY value")
    end

    if source.is_a?(AST::GetIndex)
      target_ti = Type.from_node!(source.target, context: "COPY index target")
      elem = target_ti.element_type
      return elem if elem
    end

    sym_type = if source.is_a?(AST::Identifier) && source.symbol.respond_to?(:type)
      T.must(source.symbol).type
    end
    return sym_type if sym_type.is_a?(Type) && !sym_type.untyped?

    Type.from_node!(source, context: "COPY value")
  end

  sig { params(source: T.untyped, source_type: Type, dest_type: Type).returns(String) }
  def copy_source_zig_type(source, source_type, dest_type)
    if source_type.non_string_array? && source.is_a?(AST::Identifier) && source.symbol&.is_param
      return source_type.zig_type(is_param: true)
    end

    source_type.non_string_array? && dest_type.collection? ? source_type.zig_type : dest_type.zig_type
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

  # A struct/union literal field store is a consuming site: a moved
  # binding placed in a field transfers ownership, so its guarded
  # cleanup must be suppressed via MoveMark -- the same mechanism
  # element stores and TAKES args use (INV-13/14).
  sig { params(v: T.untyped).void }
  def move_mark_field!(v)
    T.bind(self, MIRLowering) rescue nil
    return unless v.is_a?(AST::Identifier)
    ti = v.full_type!(context: "field move mark")
    tracked = ti && !ti.primitive? && !ti.void? && !ti.any? &&
              (ti.string? || ti.heap_ptr? || ti.collection_value? || ti.recursive_cleanup_shape?(mir_schema_lookup))
    return unless tracked
    nm = zig_safe_name(v.name)
    rename_map = function_state.rename_map
    nm = rename_map.fetch(nm, nm)
    entry = function_state.bindings[v.name.to_s] || CleanupEntry::NONE
    return unless entry.present?
    entry.mark_moved_guard!
    function_state.guarded_cleanup_names[nm] = true
  end

  sig { params(node: AST::MoveNode).returns(MIR::Ident) }
  def lower_move(node)
    T.bind(self, MIRLowering) rescue nil
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
    source_ti = node.value.full_type!
    source_ti = Type.new(source_ti) if source_ti && !source_ti.is_a?(Type)
    raise "Internal: lower_share requires typed source" unless source_ti

    zig_base = rc_payload_zig_type(source_ti)

    if source_ti.shared?
      return MIR::RcRetain.new(lower(node.value), zig_base, "arcRetain")
    end

    if source_ti.multiowned?
      source = lower(node.value)
      return T.cast(with_ownership_consumption(
        MIR::SharePromote.new(source, zig_base, :heap),
        mir_ident_names(source),
        "MIR::SharePromote",
        target_alloc: :heap,
      ), MIR::SharePromote)
    end

    source = lower(node.value)
    T.cast(with_ownership_consumption(
      MIR::CapWrap.new(source, zig_base, :own_only, nil, nil, "arcCreate", :heap),
      mir_ident_names(source),
      "MIR::CapWrap",
      target_alloc: :heap,
    ), MIR::CapWrap)
  end

  sig { params(node: AST::CapabilityWrap).returns(MIR::CapWrap) }
  def lower_cap_wrap(node)
    T.bind(self, MIRLowering) rescue nil
    inner = with_decl_alloc(:heap) do
      value = lower(node.value)
      place_value_for_destination(value, node.value, :heap, node.value.full_type!)
    end
    base_type = node.value.resolved_type.to_s
    zig_base = transpile_type(base_type)
    alloc = :heap

    # AtomicPtr and primitive Atomic use different constructors but both use
    # bare-pointer ownership without an outer Arc/Rc wrapper.
    is_atomic_ptr = node.atomic_ptr?
    sync_fn = sync_wrap_constructor(node.sync, atomic_ptr: is_atomic_ptr)
    sync_type = sync_wrap_type(node.sync, zig_base, atomic_ptr: is_atomic_ptr)
    # Atomic cells are already thread-safe; AtomicPtr also owns an
    # Arc-managed payload internally, so an outer Arc/Rc would double-wrap.
    own_fn = case node.ownership
             when :shared then (node.atomic? ? nil : "arcCreate")
             when :multiowned then (node.atomic? ? nil : "rcCreate")
             end

    strategy = if node.local_storage_wrap?
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

    T.cast(with_ownership_consumption(
      MIR::CapWrap.new(inner, zig_base, strategy, sync_fn, sync_type, own_fn, alloc),
      mir_ident_names(inner),
      "MIR::CapWrap",
      target_alloc: alloc,
    ), MIR::CapWrap)
  end

  sig { params(node: AST::LinkNode).returns(MIR::RcDowngrade) }
  def lower_link(node)
    T.bind(self, MIRLowering) rescue nil
    inner = lower(node.value)
    ti = node.value.full_type!
    base = transpile_type(ti.resolved.to_s)
    func = ti.shared? ? "arcDowngrade" : "rcDowngrade"
    MIR::RcDowngrade.new(inner, base, func)
  end

  sig { params(node: AST::ResolveNode).returns(MIR::WeakUpgrade) }
  def lower_resolve(node)
    T.bind(self, MIRLowering) rescue nil
    inner = lower(node.value)
    ti = node.value.full_type!
    base = transpile_type(ti.resolved.to_s)
    source = ti.link_source || :multiowned
    func = source == :shared ? "weakArcUpgrade" : "weakRcUpgrade"
    MIR::WeakUpgrade.new(inner, base, func)
  end

  sig { params(node: AST::FreezeNode).returns(MIR::FreezeExpr) }
  def lower_freeze(node)
    T.bind(self, MIRLowering) rescue nil
    ti = node.value.full_type!
    zig_base = transpile_type(ti.non_optional_type.resolved)
    inner = lower(node.value)
    # Dereference Rc data pointer to get *const T for freeze()
    rc_data = MIR::FieldGet.new(MIR::FieldGet.new(inner, "ctrl"), "data")
    MIR::FreezeExpr.new(rc_data, zig_base, MIR::AllocatorRef.new(:heap))
  end

  sig { params(ti: Type).returns(String) }
  def rc_payload_zig_type(ti)
    T.bind(self, MIRLowering) rescue nil
    if ti.generic_type_parameter? && ti.shared?
      return ti.resolved.to_s
    end
    ::FiberCtxBuilder.rc_payload_zig_type(ti)
  end

  sig { params(type: T.untyped).returns(String) }
  def generic_type_arg_zig(type)
    T.bind(self, MIRLowering) rescue nil
    if type.is_a?(Type) && type.generic_payload_type_arg?
      return rc_payload_zig_type(type)
    end
    Type.new(type).zig_type
  end

  private :emit_optional_comparison_then_expr

end
