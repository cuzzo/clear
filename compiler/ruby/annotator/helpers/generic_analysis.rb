# typed: strict
require "sorbet-runtime"
require_relative "../../ast/ast"

# ==========================================
# GENERIC ANALYSIS
# ==========================================
# Shared helpers for generic type validation, type-param substitution,
# and call-site inference. Included into SemanticAnnotator alongside
# FunctionAnalysis, EffectTracker, and PipeAnalysis.
#
# Requires host class to provide:
#   error!(node, msg, *args)       — raise CompilerError
#   lookup_type_schema(name)       — resolve a type name to its schema Hash
#   current_function_type_params      — Array<Symbol> of active fn type params
#
module GenericAnalysis
    extend T::Sig

  BUILTIN_TYPES = %i[Number Bool Byte Int64 Float64 String Any Void Range].freeze
  DeclarationNode = T.type_alias { T.any(AST::VarDecl, AST::BindExpr) }
  TypeShape = T.type_alias { T.any(Type, Symbol, String) }
  GenericSchema = T.type_alias { T.any(Schemas::EnumSchema, Schemas::StructSchema, Schemas::UnionSchema, Schemas::ResourceSchema) }
  GenericCallNode = T.type_alias { T.any(AST::FuncCall, AST::MethodCall) }
  GenericCallArgs = T.type_alias { T::Array[AST::Locatable] }
  AnnotationNode = T.type_alias { T.any(AST::Locatable, Struct) }
  GenericDeclarationNode = T.type_alias { T.any(AST::FunctionDef, AST::StructDef, AST::UnionDef) }
  GenericBinding = T.type_alias { T.any(Type, Symbol) }
  GenericSubstitution = T.type_alias { T::Hash[Symbol, GenericBinding] }

  class SharedGenericArg < T::Struct
    const :name, String
    const :type, Type
  end

  class TypeAnnotationFacts < T::Struct
    const :node, AnnotationNode
    const :type_obj, Type
    const :is_param, T::Boolean
    const :inner, Type
    const :inner_array, T::Boolean
    const :fn_type_params, T::Array[Symbol]
  end

  # ----------------------------------------
  # Type param list validation
  # ----------------------------------------
  # Validate a list of type parameter names for struct/union/function definitions.
  # Raises on duplicates and on names that shadow built-in types.
  #
  # @param node   AST node (for location in error messages)
  # @param type_params Array<String> e.g. ["T", "K"]
  # @param kind   String — "struct", "union", or "function"
  sig { params(node: GenericDeclarationNode, type_params: T::Array[String], kind: String).void }
  def validate_type_param_list!(node, type_params, kind)
    T.bind(self, SemanticAnnotator) rescue nil
    seen = {}
    type_params.each do |param|
      param_sym = param.to_sym
      if seen[param_sym]
        error!(node, :GENERIC_DUP_TYPE_PARAM_KIND, param: param, kind: kind, name: node.name)
      end
      if BUILTIN_TYPES.include?(param_sym)
        error!(node, :GENERIC_TYPE_PARAM_SHADOWS, param: param)
      end
      seen[param_sym] = true
    end
  end

  # ----------------------------------------
  # Type annotation validation
  # ----------------------------------------
  # Validates a user-written type annotation wherever generics are involved.
  # Covers four cases:
  #   1. Generic type used correctly: Pair<Number>   — validate arg count + arg types
  #   2. Non-generic type with args:  User<Number>   — error: not generic
  #   3. Generic type without args:   Pair           — error: args required
  #   4. Non-generic type without args: User         — nothing to validate (normal path)
  #
  # Validates a type annotation where generics are involved.
  # Called whenever a user-written type annotation is resolved (variable decls, params, returns).
  # Covers four cases:
  #   1. Generic type used correctly: Pair<Number> — validate arg count + arg types
  #   2. Generic type missing args: Pair — error
  #   3. Non-generic type with args: Int64<Number> — error
  #   4. Type param used as arg: Cache<T> — skip validation (resolved at monomorphization)
  #
  # Respects current_function_type_params so that Cache<T> in a generic function
  # does not raise "unknown type argument T".
  # Structural capabilities that are allowed on function parameters.
  STRUCTURAL_CAPABILITIES = %i[link].freeze

  sig { params(node: AnnotationNode, type_obj: Type, is_param: T::Boolean).returns(NilClass) }
  def validate_type_annotation!(node, type_obj, is_param: false)
    T.bind(self, SemanticAnnotator) rescue nil
    return if type_obj.fn_type?

    facts = type_annotation_facts(node, type_obj, is_param)
    validate_param_annotation_capabilities!(facts)
    validate_collection_annotation_capabilities!(facts)
    validate_collection_allocation_hint!(facts)
    validate_observable_annotation_capabilities!(facts)
    validate_shape_annotation_capabilities!(facts)
    validate_generic_annotation!(facts)
    nil
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_collection_allocation_hint!(facts)
    T.bind(self, SemanticAnnotator)
    return unless facts.type_obj.preallocation_hint?
    return if !facts.is_param && (facts.node.is_a?(AST::VarDecl) || facts.node.is_a?(AST::BindExpr))

    error!(facts.node, :COLLECTION_HINT_VALUE_ONLY)
  end

  sig { params(node: AnnotationNode, type_obj: Type, is_param: T::Boolean).returns(TypeAnnotationFacts) }
  def type_annotation_facts(node, type_obj, is_param)
    T.bind(self, SemanticAnnotator)
    TypeAnnotationFacts.new(
      node: node,
      type_obj: type_obj,
      is_param: is_param,
      inner: type_annotation_inner(type_obj),
      inner_array: type_obj.tense? && type_obj.tense_type&.array? == true,
      fn_type_params: current_function_type_params,
    )
  end

  sig { params(type_obj: Type).returns(Type) }
  def type_annotation_inner(type_obj)
    return T.must(type_obj.payload_type) if type_obj.error_union?
    return T.must(type_obj.wrapped_type) if type_obj.optional?

    type_obj
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_param_annotation_capabilities!(facts)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless facts.is_param

    type_obj = facts.type_obj
    has_ownership_cap = %i[multiowned split].include?(type_obj.ownership)
    primitive_atomic_param = type_obj.atomic? && type_obj.primitive?
    has_sync_cap = type_obj.sync && !primitive_atomic_param && !%i[raw symbol].include?(type_obj.sync)
    error!(facts.node, :FN_PARAM_NO_CAPABILITY) if has_ownership_cap || has_sync_cap
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_collection_annotation_capabilities!(facts)
    T.bind(self, SemanticAnnotator) rescue nil
    type_obj = facts.type_obj
    shape = facts.inner
    error!(facts.node, :ATSPLIT_STREAM_ONLY) if type_obj.split? && !type_obj.stream?
    error!(facts.node, :COLLECTION_NEEDS_ARRAY_TYPE, cap: '@list', example: 'User[]@list or User[N]@list') if shape.list_requires_array_shape?
    error!(facts.node, :COLLECTION_NEEDS_ARRAY_TYPE, cap: '@pool', example: 'User[]@pool or User[N]@pool') if shape.pool? && !shape.array? && !facts.inner_array
    error!(facts.node, :COLLECTION_NEEDS_ARRAY_TYPE, cap: '@set', example: 'String[]@set') if shape.set_collection? && !shape.array? && !facts.inner_array
    error!(facts.node, :OBSERVABLE_REQUIRES_SET) if type_obj.observable_array_without_set?
    payload = shape.map? ? shape.value_type : shape.element_type
    if payload&.indirect? && payload.primitive?
      error!(facts.node, :INDIRECT_ELEMENT_PRIMITIVE, type: payload.resolved)
    end
    if type_obj.sharded? && payload&.multiowned?
      error!(facts.node, :SHARDED_ELEMENT_REQUIRES_SHARED, got: payload.to_s)
    end
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_observable_annotation_capabilities!(facts)
    T.bind(self, SemanticAnnotator) rescue nil
    type_obj = facts.type_obj
    return unless type_obj.tense? && type_obj.observable?

    offending_sync = type_obj.sync if type_obj.sync && !%i[raw symbol].include?(type_obj.sync)
    offending_own = type_obj.ownership if %i[multiowned shared split].include?(type_obj.ownership)
    return unless offending_sync || offending_own

    labels = observable_capability_labels(offending_sync, offending_own)
    explain = observable_capability_explanation(offending_sync, offending_own)
    error!(facts.node, :OBSERVABLE_NOT_COMBINABLE, labels: labels.join(' / '), explain: explain)
  end

  sig { params(offending_sync: T.nilable(Symbol), offending_own: T.nilable(Symbol)).returns(T::Array[String]) }
  def observable_capability_labels(offending_sync, offending_own)
    labels = T.let([], T::Array[String])
    labels << "sync wrapper :#{offending_sync}" if offending_sync
    labels << "ownership wrapper :#{offending_own}" if offending_own
    labels
  end

  sig { params(offending_sync: T.nilable(Symbol), offending_own: T.nilable(Symbol)).returns(String) }
  def observable_capability_explanation(offending_sync, offending_own)
    if offending_sync && offending_own
      return "The observable is already a lock-free single-producer accumulator (extra sync is redundant) AND its heap-pointer lifetime is owned by the producing scope (sharing it across owners would race the producer's `finish()` against the cleanup-side `wait(); destroy()`)."
    end
    if offending_sync
      return "The observable is already a lock-free single-producer accumulator; layering :#{offending_sync} on top would double-synchronize, and its guard semantics conflict with WITH VIEW (which is meant to be a non-blocking single-load)."
    end
    "The observable's heap-pointer lifetime is owned by the producing scope (the producer fiber's `defer ctx.acc.finish()` plus the scope's `wait(); destroy()` cleanup assume exactly one owner). Sharing it via :#{offending_own} would race the producer's lifetime against the destroy and corrupt the WaitGroup bridge."
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_shape_annotation_capabilities!(facts)
    T.bind(self, SemanticAnnotator) rescue nil
    type_obj = facts.type_obj
    error!(facts.node, :SOA_NEEDS_FIXED_ARRAY) if type_obj.soa_requires_fixed_array?

    shard_count = type_obj.shard_count
    error!(facts.node, :SHARDED_NEEDS_2_PLUS, got: shard_count) if shard_count && shard_count < 2
    error!(facts.node, :POOL_NEEDS_FIXED_CAPACITY, element: type_obj.element_type&.resolved) if type_obj.pool? && !type_obj.fixed?
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_generic_annotation!(facts)
    if facts.inner.generic_instance?
      validate_generic_instance_annotation!(facts)
    else
      validate_plain_type_annotation!(facts)
    end
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_generic_instance_annotation!(facts)
    T.bind(self, SemanticAnnotator) rescue nil
    inner = facts.inner
    base_name = inner.generic_base
    return if base_name == :Id
    if base_name == :Tuple || base_name == :StreamStep
      inner.generic_args.each { |arg| validate_generic_type_arg!(facts, arg) }
      return
    end

    schema = annotation_schema_for!(facts.node, base_name)
    type_params = schema_type_params(schema)
    error!(facts.node, :GENERIC_NOT_GENERIC, type: base_name) if type_params.empty?

    expected = type_params.length
    actual = inner.generic_args.length
    error!(facts.node, :GENERIC_WRONG_ARG_COUNT, type: base_name, expected: expected, got: actual) if actual != expected
    inner.generic_args.each { |arg| validate_generic_type_arg!(facts, arg) }
  end

  sig { params(facts: TypeAnnotationFacts, arg: Type).void }
  def validate_generic_type_arg!(facts, arg)
    T.bind(self, SemanticAnnotator) rescue nil
    if arg.optional? || arg.error_union? || arg.tense?
      wrapped = arg.wrapped_type || arg.payload_type || arg.tense_type
      validate_generic_type_arg!(facts, wrapped)
      return
    end
    if arg.array?
      validate_generic_type_arg!(facts, T.must(arg.element_type))
      return
    end
    # HashMap is a built-in composite type rather than a registered generic
    # schema. Its own annotation validation checks the key/value shape.
    return if arg.map?
    if arg.generic_instance?
      if arg.generic_base == :Tuple || arg.generic_base == :StreamStep
        arg.generic_args.each { |nested_arg| validate_generic_type_arg!(facts, nested_arg) }
        return
      end
      nested_schema = T.cast(lookup_type_schema(arg.generic_base), T.nilable(GenericSchema))
      error!(facts.node, :GENERIC_UNKNOWN_TYPE_ARG, type: arg.resolved) if nested_schema.nil?
      nested_params = schema_type_params(nested_schema)
      if nested_params.length != arg.generic_args.length
        error!(facts.node, :GENERIC_WRONG_ARG_COUNT,
          type: arg.generic_base, expected: nested_params.length, got: arg.generic_args.length)
      end
      arg.generic_args.each { |nested_arg| validate_generic_type_arg!(facts, nested_arg) }
      return
    end
    return if BUILTIN_TYPES.include?(arg.resolved)
    return if facts.fn_type_params.include?(arg.resolved)

    arg_schema = T.cast(lookup_type_schema(arg.resolved), T.nilable(GenericSchema))
    error!(facts.node, :GENERIC_UNKNOWN_TYPE_ARG, type: arg.resolved) if arg_schema.nil?
    type_params = schema_type_params(arg_schema)
    return if type_params.empty?

    params_hint = type_params.map(&:to_s).join(', ')
    error!(facts.node, :GENERIC_MISSING_TYPE_ARGS, type: arg.resolved, type2: arg.resolved, hint: params_hint)
  end

  sig { params(facts: TypeAnnotationFacts).void }
  def validate_plain_type_annotation!(facts)
    T.bind(self, SemanticAnnotator) rescue nil
    base_name = facts.inner.resolved
    return if facts.fn_type_params.include?(base_name)

    schema = T.cast(lookup_type_schema(base_name), T.nilable(GenericSchema))
    type_params = schema_type_params(schema)
    return if type_params.empty?

    params_hint = type_params.map(&:to_s).join(', ')
    error!(facts.node, :GENERIC_MISSING_TYPE_ARGS, type: base_name, type2: base_name, hint: params_hint)
  end

  sig { params(node: AnnotationNode, base_name: Symbol).returns(T.nilable(GenericSchema)) }
  def annotation_schema_for!(node, base_name)
    T.bind(self, SemanticAnnotator) rescue nil
    schema = T.cast(lookup_type_schema(base_name), T.nilable(GenericSchema))
    return schema if schema

    tok = type_annotation_token(node)
    if tok
      emit_typo_suggestion!(
        tok, base_name.to_s, all_known_type_names,
        "Unknown type '#{base_name}'",
        "closest declared type",
        category: :type, cascade: true
      )
    else
      error!(node, :UNKNOWN_TYPE, name: base_name)
    end
    nil
  end

  sig { params(node: AnnotationNode).returns(T.nilable(Lexer::Token)) }
  def type_annotation_token(node)
    return nil unless node.respond_to?(:token)

    T.cast(T.unsafe(node).token, T.nilable(Lexer::Token))
  end

  sig { params(schema: T.nilable(GenericSchema)).returns(T::Array[Symbol]) }
  def schema_type_params(schema)
    return [] unless schema.respond_to?(:type_params)

    T.cast(T.unsafe(schema).type_params, T::Array[Symbol])
  end

  # ----------------------------------------
  # Call-site type-argument inference
  # ----------------------------------------
  # Infer a substitution map { :T => :Number, ... } from actual argument types.
  # Errors on conflicts (two args disagree on T) and missing bindings (T unused).
  #
  # @param node         AST::FuncCall (for error reporting)
  # @param signature    Hash — the function's type signature
  # @param actual_args  Array<AST node> — visited argument nodes
  # @param type_params  Array<Symbol>  — e.g. [:T, :K]
  # @return Hash — e.g. { T: :Number, K: :String }
  sig { params(node: GenericCallNode, signature: FunctionSignature, actual_args: GenericCallArgs, type_params: T::Array[Symbol]).returns(GenericSubstitution) }
  def infer_generic_type_args!(node, signature, actual_args, type_params)
    T.bind(self, SemanticAnnotator) rescue nil
    subst = T.let({}, GenericSubstitution)
    signature.params.each_with_index do |param, i|
      arg = actual_args[i]
      next unless arg
      param_type = param.type
      actual_type = arg.full_type!(context: "generic call argument")
      extract_type_bindings!(node, param_type, actual_type, type_params, subst)
    end
    enforce_shared_family_call_sync!(node, signature, actual_args, type_params)
    type_params.each do |tp|
      unless subst.key?(tp)
        error!(node, :GENERIC_FN_CANNOT_INFER, param: tp, fn: node.name, type: tp)
      end
    end
    subst
  end

  sig { params(node: GenericCallNode, signature: FunctionSignature, actual_args: GenericCallArgs, type_params: T::Array[Symbol]).returns(NilClass) }
  def enforce_shared_family_call_sync!(node, signature, actual_args, type_params)
    T.bind(self, SemanticAnnotator) rescue nil
    shared_args = T.let([], T::Array[SharedGenericArg])
    signature.params.each_with_index do |param, i|
      arg = actual_args[i]
      next unless arg
      param_type = param.type
      next unless generic_shared_family_param?(param_type) && type_params.include?(param_type.resolved)
      actual_type = arg.full_type!(context: "shared generic call argument")
      next unless actual_type.shared?
      shared_args << SharedGenericArg.new(
        name: param.name,
        type: generic_shared_payload_binding(actual_type)
      )
    end
    return if shared_args.size < 2

    first = shared_args.first
    return unless first
    mismatch = shared_args.find { |arg| !same_shared_call_capability?(first.type, arg.type) }
    return unless mismatch

    error!(node, :POLY_SHARED_INCONSISTENT,
      fn: node.name,
      first: first.name, first_cap: shared_call_capability_display(first.type),
      second: mismatch.name, second_cap: shared_call_capability_display(mismatch.type))
  end

  # Recursively match param_type against actual_type to bind type params.
  # Handles both direct uses (T) and nested generic uses (Cache<T>).
  sig { params(node: GenericCallNode, param_type: Type, actual_type: Type, type_params: T::Array[Symbol], subst: GenericSubstitution).void }
  def extract_type_bindings!(node, param_type, actual_type, type_params, subst)
    T.bind(self, SemanticAnnotator) rescue nil
    p_res = param_type.resolved
    a_res = actual_type.resolved
    if param_type.fn_type? && actual_type.fn_type?
      param_fn = param_type.function_type
      actual_fn = actual_type.function_type
      return unless param_fn && actual_fn

      param_fn.params.zip(actual_fn.params).each do |p_param, a_param|
        next unless p_param && a_param
        extract_type_bindings!(node, p_param.type, a_param.type, type_params, subst)
      end
      extract_type_bindings!(node, param_fn.return_type, actual_fn.return_type, type_params, subst)
    elsif type_params.include?(p_res)
      actual_binding = if generic_shared_family_param?(param_type) && actual_type.shared?
        generic_shared_payload_binding(actual_type)
      else
        generic_binding_value(actual_type)
      end
      existing = subst[p_res]
      if existing && !same_generic_binding?(existing, actual_binding)
        error!(node, :GENERIC_FN_CONFLICT, param: p_res, fn: node.name, first: generic_binding_source(existing), second: generic_binding_source(actual_binding))
      end
      subst[p_res] = actual_binding
    elsif param_type.generic_instance? && actual_type.generic_instance? &&
          param_type.generic_base == actual_type.generic_base
      param_type.generic_args.zip(actual_type.generic_args).each do |p_arg, a_arg|
        next unless p_arg && a_arg
        extract_type_bindings!(node, p_arg, a_arg, type_params, subst)
      end
    end
  end

  # ----------------------------------------
  # Type param substitution
  # ----------------------------------------
  # Apply a substitution map to a type object.
  # e.g. apply_type_subst(Type(:T), { T: :Number }) → Type(:Number)
  #      apply_type_subst(Type(:"Cache<T>"), { T: :Number }) → Type(:"Cache<Number>")
  sig { params(type_obj: Type::TypeInput, subst: GenericSubstitution).returns(Type) }
  def apply_type_subst(type_obj, subst)
    T.bind(self, SemanticAnnotator) rescue nil
    return Type.new(:Any) if type_obj.nil?
    t = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    if t.fn_type?
      fn_type = t.function_type
      return t unless fn_type

      params = fn_type.params.map do |param|
        Type::FunctionTypeParam.new(type: apply_type_subst(param.type, subst))
      end
      Type.new(Type::FunctionType.new(
        params: params,
        return_type: apply_type_subst(fn_type.return_type, subst),
        reentrant: fn_type.reentrant,
        source_signature: fn_type.source_signature
      ))
    else
      Type.new(apply_expression_subst(t.shape.expression, subst))
    end
  end

  sig { params(expression: TypeExpression, subst: GenericSubstitution).returns(TypeExpression) }
  def apply_expression_subst(expression, subst)
    T.bind(self, SemanticAnnotator) rescue nil
    case expression
    when NamedTypeExpression
      if expression.arguments.empty? && subst.key?(expression.name)
        replacement = Type.new(T.unsafe(subst[expression.name]))
        if replacement.generic_payload_type_arg? && !expression.capabilities.polymorphic_shared
          replacement.strip_runtime_capabilities!
        end
        parameter = Type.new(expression)
        replacement.merge_capabilities_from!(parameter) if generic_type_has_capabilities?(parameter)
        return replacement.shape.expression
      end
      NamedTypeExpression.new(
        name: expression.name,
        arguments: expression.arguments.map { |argument| apply_expression_subst(argument, subst) },
        capabilities: expression.capabilities
      )
    when FunctionTypeExpression
      signature = expression.signature
      FunctionTypeExpression.new(
        signature: Type::FunctionType.new(
          params: signature.params.map do |param|
            Type::FunctionTypeParam.new(type: apply_type_subst(param.type, subst))
          end,
          return_type: apply_type_subst(signature.return_type, subst),
          reentrant: signature.reentrant,
          source_signature: signature.source_signature
        ),
        capabilities: expression.capabilities
      )
    when TupleTypeExpression
      TupleTypeExpression.new(
        items: expression.items.map { |item| apply_expression_subst(item, subst) },
        capabilities: expression.capabilities
      )
    when OptionalTypeExpression
      OptionalTypeExpression.new(inner: apply_expression_subst(expression.inner, subst),
        capabilities: expression.capabilities)
    when FallibleTypeExpression
      error_set = expression.error_set
      FallibleTypeExpression.new(
        inner: apply_expression_subst(expression.inner, subst),
        error_set: error_set.nil? ? nil : apply_expression_subst(error_set, subst),
        capabilities: expression.capabilities
      )
    when FutureTypeExpression
      FutureTypeExpression.new(inner: apply_expression_subst(expression.inner, subst),
        capabilities: expression.capabilities)
    when LinearTypeExpression
      LinearTypeExpression.new(
        kind: expression.kind,
        dimensions: expression.dimensions,
        item: apply_expression_subst(expression.item, subst),
        allocation_hint: expression.allocation_hint,
        capabilities: expression.capabilities
      )
    when MapTypeExpression
      MapTypeExpression.new(
        key: apply_expression_subst(expression.key, subst),
        value: apply_expression_subst(expression.value, subst),
        key_implicit: expression.key_implicit,
        legacy_separator: expression.legacy_separator,
        capabilities: expression.capabilities
      )
    when StreamTypeExpression
      StreamTypeExpression.new(
        cardinality: expression.cardinality,
        item: apply_expression_subst(expression.item, subst),
        capabilities: expression.capabilities
      )
    else
      expression
    end
  end
  private :apply_expression_subst

  sig { params(type: Type).returns(Type) }
  def generic_binding_value(type)
    T.bind(self, SemanticAnnotator) rescue nil
    Type.new(type)
  end

  sig { params(type: Type).returns(T::Boolean) }
  def generic_shared_family_param?(type)
    T.bind(self, SemanticAnnotator) rescue nil
    type.polymorphic_shared? && type.resolved.to_s.match?(/\A[A-Z]\z/)
  end

  sig { params(type: Type).returns(Type) }
  def generic_shared_payload_binding(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = Type.new(type)
    t.apply_reference_ownership!(:affine)
    t.mark_stack_value!
    t.mark_generic_payload_type_arg!
    t
  end

  sig { params(left: GenericBinding, right: GenericBinding).returns(T::Boolean) }
  def same_generic_binding?(left, right)
    T.bind(self, SemanticAnnotator) rescue nil
    l = left.is_a?(Type) ? left : Type.new(left)
    r = right.is_a?(Type) ? right : Type.new(right)
    l.resolved == r.resolved &&
      l.ownership == r.ownership &&
      l.sync == r.sync &&
      l.layout == r.layout &&
      l.elem_ownership == r.elem_ownership &&
      l.elem_sync == r.elem_sync
  end

  sig { params(left: Type, right: Type).returns(T::Boolean) }
  def same_shared_call_capability?(left, right)
    T.bind(self, SemanticAnnotator) rescue nil
    left.sync == right.sync &&
      left.layout == right.layout &&
      left.elem_ownership == right.elem_ownership &&
      left.elem_sync == right.elem_sync
  end

  sig { params(type: Type).returns(T::Boolean) }
  def generic_type_has_capabilities?(type)
    T.bind(self, SemanticAnnotator) rescue nil
    type.ownership != :affine ||
      !type.sync.nil? ||
      !type.layout.nil? ||
      !type.elem_ownership.nil? ||
      !type.elem_sync.nil? ||
      !type.elem_layout.nil?
  end

  sig { params(type: GenericBinding).returns(String) }
  def generic_binding_source(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = type.is_a?(Type) ? type : Type.new(type)
    parts = [t.resolved.to_s]

    ownership = t.ownership_surface_name
    sync = t.sync_surface_name
    parts << ownership if ownership
    parts << sync if sync
    parts << "@indirect" if t.indirect?

    parts.join("")
  end

  sig { params(type: Type).returns(String) }
  def shared_call_capability_display(type)
    T.bind(self, SemanticAnnotator) rescue nil
    caps = ["@shared"]
    caps << "indirect" if type.indirect?
    caps << T.must(type.sync_family_name)
    caps.compact.join(":")
  end

  # Build a concrete copy of a generic function signature with all type params
  # replaced by their inferred concrete types.
  sig { params(signature: FunctionSignature, subst: GenericSubstitution).returns(FunctionSignature) }
  def substitute_type_params(signature, subst)
    T.bind(self, SemanticAnnotator) rescue nil
    FunctionSignature.new(
      params: signature.params.map { |p| p.dup.tap { |np| np.type = apply_type_subst(p.type, subst) } },
      return_type: apply_type_subst(signature.return_type, subst),
      return_lifetime: signature.return_lifetime,
      visibility: signature.visibility
    )
  end

  # ==========================================
  # Declaration helpers (shared by VarDecl + BindExpr)
  # ==========================================

  # Validate stream type annotations on variable declarations.
  sig { params(node: DeclarationNode).returns(NilClass) }
  def validate_stream_type!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless node.type&.future?
    if node.type.multiowned?
      error!(node, :RC_PROMISE_NEEDS_SHARED)
    end
    if node.type.split? && !node.type.open_stream?
      error!(node, :ATSPLIT_NEEDS_OPEN_STREAM)
    end
  end

  # After coerce! validates type compatibility, propagate declared-type metadata
  # into the value node so the transpiler sees the correct runtime type.
  # Handles: BgStreamBlock ~T[INF] retyping, shard_count, @shared promise ownership.
  sig { params(node: DeclarationNode, final_type: TypeShape).void }
  def propagate_declared_type_to_value!(node, final_type)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless node.type
    final_type_info = final_type.is_a?(Type) ? final_type : Type.new(final_type)

    # BgStreamBlock infers ~?T[]; declared ~T[INF] picks the runtime wrapper.
    if node.value.is_a?(AST::BgStreamBlock) && node.type.inf_stream?
      stream = T.cast(node.value, AST::BgStreamBlock)
      if stream_body_contains_close?(stream.body)
        error!(stream, :INFINITE_STREAM_CLOSE)
      end
      if stream_body_may_fall_through?(stream.body)
        error!(stream, :INFINITE_STREAM_FALLTHROUGH)
      end
    end


    if node.value.is_a?(AST::BgStreamBlock) && node.type.runtime_stream?
      stamp_type!(node.value, final_type_info)
    end

    if node.value.is_a?(AST::BgStreamBlock) && node.type.split_open_stream?
      value_type = node.value.full_type!(context: "BgStreamBlock split_open_stream value")
      stamp_type!(node.value, Type.new(value_type, ownership: :split))
    end

    # Propagate shard_count from declared type into final_type (lost during coerce!).
    if node.type.shard_count
      final_type_info.copy_topology_from!(node.type)
    end

    # Propagate @shared ownership into BgBlock for SharedPromise.spawn().
    if node.value.is_a?(AST::BgBlock) && node.type.shared_promise?
      value_type = node.value.full_type!(context: "BgBlock shared_promise value")
      T.unsafe(node.value).async_result_shape = AsyncResultShape.promise(value_type.tense_type, shared: true)
      stamp_type!(node.value, Type.new(value_type, ownership: :shared))
    end
  end

  sig { params(body: T::Array[AST::Node]).returns(T::Boolean) }
  def stream_body_contains_close?(body)
    body.any? do |stmt|
      stmt.is_a?(AST::CloseStream) || AST.child_bodies(stmt).any? { |child| stream_body_contains_close?(child) }
    end
  end

  sig { params(body: T::Array[AST::Node]).returns(T::Boolean) }
  def stream_body_may_fall_through?(body)
    return true if body.empty?

    stmt = body.last
    return false if stmt.is_a?(AST::CloseStream) || stmt.is_a?(AST::ReturnNode) ||
      stmt.is_a?(AST::Raise) || stmt.is_a?(AST::DieNode)
    if stmt.is_a?(AST::IfStatement)
      return true if stmt.else_branch.nil? || stmt.else_branch.empty?
      return stream_body_may_fall_through?(stmt.then_branch) ||
        stream_body_may_fall_through?(stmt.else_branch)
    end
    if stmt.is_a?(AST::IfBind)
      return true if stmt.else_branch.nil? || stmt.else_branch.empty?
      return stream_body_may_fall_through?(stmt.then_branch) ||
        stream_body_may_fall_through?(stmt.else_branch)
    end
    if stmt.is_a?(AST::WhileLoop)
      condition = stmt.condition
      is_true = condition.is_a?(AST::Literal) && condition.true_boolean?
      return false if is_true && !stream_body_contains_break?(stmt.do_branch)
    end

    true
  end

  sig { params(body: T::Array[AST::Node]).returns(T::Boolean) }
  def stream_body_contains_break?(body)
    body.any? do |stmt|
      next true if stmt.is_a?(AST::BreakNode)
      # BREAK is lexically scoped to its nearest loop. A BREAK inside a
      # nested loop cannot make the outer `WHILE TRUE` producer terminate.
      next false if AST.loop_node?(stmt) || AST.call_like_boundary?(stmt)

      AST.child_bodies(stmt).any? { |child| stream_body_contains_break?(child) }
    end
  end

  # Propagate collection, shard_count, soa, and sync metadata from the declared
  # type annotation (or inferred value type) into node.full_type and node.full_type.
  # These fields are lost during finalize_storage! and coerce!.
  sig { params(node: DeclarationNode, final_type: TypeShape).void }
  def propagate_collection_metadata!(node, final_type)
    T.bind(self, SemanticAnnotator) rescue nil
    _ = final_type
    decl_type = node.type
    node_type = node.full_type!(context: "declaration metadata target")
    value_type = node.value.full_type!(context: "declaration metadata value")

    coll_src = if decl_type&.rank?
      nil
    elsif decl_type&.collection
      decl_type
    elsif value_type.collection
      value_type
    end
    if coll_src
      node_type.copy_collection_shape_from!(coll_src)
      node_type.mark_heap_allocated! if coll_src.pool? || coll_src.set_collection?
    end

    # Standalone @soa on fixed arrays (no collection): propagate soa flag directly.
    if !coll_src && decl_type&.soa
      node_type.mark_soa_layout!
    end

    # Map-specific propagation: maps don't use :collection, so the above doesn't cover them.
    if decl_type
      node_type.copy_declared_collection_modifiers_from!(decl_type)
    end
  end

  sig { params(node: AnnotationNode).returns(T.nilable(Symbol)) }
  def propagate_call_flags!(node)
    _ = node
    nil
  end


  # Register container borrow in the OG when a binding receives a value
  # from container access (HashMap/Pool/List indexing, through OR).
  sig { params(node: DeclarationNode).returns(T.nilable(T::Boolean)) }
  def register_container_borrow!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    container = find_container_source(node.value)
    return unless container
    var_name = node.name.is_a?(String) ? node.name : node.name.to_s
    ownership_graph[var_name]&.kind = :borrowed
    T.must(node.symbol).mark_borrowed_alias! if node.respond_to?(:symbol) && node.symbol
    node.container_borrow = true
    node.value.container_borrow = true if node.value.respond_to?(:container_borrow=)
    node.storage = :borrow if node.respond_to?(:storage=)
    true
  end

  # Walk through OR/OR_ELSE to find the root container/struct variable name.
  # Returns the root variable name when the expression borrows from a container
  # (GetIndex on map/list) or extracts a non-Copy field from a struct (GetField).
  sig { params(expr: T.nilable(AST::Node)).returns(T.nilable(String)) }
  def find_container_source(expr)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil unless expr
    # COPY/CLONE produce owned/retained values; no borrow relationship.
    return nil if expr.is_a?(AST::CopyNode) || expr.is_a?(AST::CloneNode)
    if expr.respond_to?(:container_borrow) && expr.container_borrow
      receiver = if expr.respond_to?(:object)
        T.unsafe(expr).object
      elsif expr.respond_to?(:target)
        T.unsafe(expr).target
      end
      return root_variable_name(receiver) if receiver
    end
    if expr.is_a?(AST::GetIndex)
      ti = expr.target.full_type!(context: "container source")
      if ti.collection_value?
        return root_variable_name(expr.target)
      end
    end
    if expr.is_a?(AST::Slice)
      ti = expr.target.full_type!(context: "slice container source")
      return root_variable_name(expr.target) if ti.array?
    end
    if expr.is_a?(AST::GetField)
      return field_container_source(expr)
    end
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_ELSE)
      return find_container_source(expr.left)
    end
    # pool[id]? parses as OptionalUnwrap(GetIndex) - peel through the unwrap.
    if expr.is_a?(AST::OptionalUnwrap)
      return find_container_source(expr.target)
    end
    nil
  end

  sig { params(expr: AST::GetField).returns(T.nilable(String)) }
  def field_container_source(expr)
    T.bind(self, SemanticAnnotator) rescue nil

    # Non-Copy field extraction from a struct is a borrow of the parent.
    # Without this, the extracted variable gets its own cleanup defer while
    # the parent's cleanup also frees the field -- double-free.
    # Skip enum/union variant constructors (e.g. Value.Nil) - these create new
    # values, not borrows from an existing variable.
    if expr.target.is_a?(AST::Identifier)
      target_schema = lookup_type_schema(expr.target.name.to_sym)
      return nil if (Schemas.union?(target_schema) || Schemas.enum?(target_schema))
    end
    field_ti = expr.full_type!(context: "field container source")
    return nil if field_ti.implicitly_copyable? { |type_name| lookup_type_schema(type_name) }

    root_variable_name(expr.target)
  end

  private :apply_type_subst,
    :enforce_shared_family_call_sync!,
    :field_container_source,
    :extract_type_bindings!,
    :validate_generic_annotation!,
    :validate_observable_annotation_capabilities!,
    :validate_generic_instance_annotation!
     private :annotation_schema_for!
     private :find_container_source
     private :generic_binding_value
     private :generic_shared_family_param?
     private :generic_type_has_capabilities?
     private :observable_capability_explanation
     private :observable_capability_labels
     private :same_generic_binding?
     private :same_shared_call_capability?
     private :shared_call_capability_display
     private :type_annotation_facts
     private :type_annotation_inner
     private :type_annotation_token
     private :validate_collection_annotation_capabilities!
     private :validate_generic_type_arg!
     private :validate_param_annotation_capabilities!
     private :validate_plain_type_annotation!
     private :validate_shape_annotation_capabilities!

end
