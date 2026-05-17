# typed: strict
require "sorbet-runtime"
require_relative "../ast/ast"

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
#   current_fn_ctx&.type_params        — Array<Symbol> of active fn type params
#
module GenericAnalysis
    extend T::Sig

  BUILTIN_TYPES = %i[Number Bool Byte Int64 Float64 String Any Void Range].freeze

  # ----------------------------------------
  # Type param list validation
  # ----------------------------------------
  # Validate a list of type parameter names for struct/union/function definitions.
  # Raises on duplicates and on names that shadow built-in types.
  #
  # @param node   AST node (for location in error messages)
  # @param type_params Array<String> e.g. ["T", "K"]
  # @param kind   String — "struct", "union", or "function"
  sig { params(node: T.untyped, type_params: T::Array[String], kind: String).returns(T.nilable(T::Array[String])) }
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
  # Respects current_fn_ctx&.type_params so that Cache<T> in a generic function
  # does not raise "unknown type argument T".
  # Structural capabilities that are allowed on function parameters.
  STRUCTURAL_CAPABILITIES = %i[link].freeze

  sig { params(node: T.untyped, type_obj: T.untyped, is_param: T::Boolean).returns(T.nilable(T::Array[Type])) }
  def validate_type_annotation!(node, type_obj, is_param: false)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless type_obj.is_a?(Type)
    # FN types are structurally typed; their nested param/return types are validated
    # when they are parsed. No named-type schema lookup is needed here.
    return if type_obj.fn_type?

    # --- Capability validation (moved from parser for separation of concerns) ---

    # Ownership/sync capabilities are not allowed on function parameters,
    # except plain @shared. Concrete `T @shared` accepts an Arc handle.
    # Polymorphic shared-family contracts use `SHARED T`; callers with
    # bare/local/multiowned values must use SHARE at the call site.
    # :affine is the default (not a user-set capability). :link is
    # structural (allowed on params).
    # @raw is structural (byte buffer). Collections, @soa, @indirect are also structural.
    if is_param
      has_ownership_cap = %i[multiowned split].include?(type_obj.ownership)
      primitive_atomic_param = type_obj.sync == :atomic && type_obj.primitive?
      has_sync_cap = type_obj.sync && !primitive_atomic_param && !%i[raw symbol].include?(type_obj.sync)
      if has_ownership_cap || has_sync_cap
        error!(node, :FN_PARAM_NO_CAPABILITY)
      end
    end

    if type_obj.split? && !type_obj.stream?
      error!(node, :ATSPLIT_STREAM_ONLY)
    end

    # @list/@pool/@set require an array type.
    # `~T[]@set:observable` (and friends) is a tense-wrapped collection
    # produced by a pipeline-terminal observable; the array shape lives
    # on the inner tense_type, not the outer tense wrapper. Accept those
    # by also checking tense_type.array?.
    inner_array = type_obj.tense? && type_obj.tense_type&.array?
    if type_obj.list_collection? && !type_obj.array? && !type_obj.promise_list? && !inner_array
      error!(node, :COLLECTION_NEEDS_ARRAY_TYPE, cap: '@list', example: 'User[]@list or User[N]@list')
    end
    if type_obj.pool? && !type_obj.array? && !inner_array
      error!(node, :COLLECTION_NEEDS_ARRAY_TYPE, cap: '@pool', example: 'User[]@pool or User[N]@pool')
    end
    if type_obj.set_collection? && !type_obj.array? && !inner_array
      error!(node, :COLLECTION_NEEDS_ARRAY_TYPE, cap: '@set', example: 'String[]@set')
    end

    # `~T[]@observable` (without `@set`) silently miscompiled before --
    # tense_observable? returned false for the array shape, the
    # observable carve-out skipped it, and execution fell through to
    # the promise_list path emitting `ArrayList(Promise(T))`, which
    # is not an observable backing at all. Reject explicitly: the
    # only observable shape over an array today is `@set:observable`
    # (DISTINCT terminal). Plain array observables are not supported.
    if type_obj.tense? && type_obj.observable? && type_obj.tense_type&.array? &&
       !type_obj.set_collection?
      error!(node, :OBSERVABLE_REQUIRES_SET)
    end

    # I2: sync / ownership wrappers on `~T@observable` are nonsensical.
    # The observable IS the synchronization primitive (lock-free atomic
    # accumulator owned by a single producer fiber); wrapping it in
    # @locked / @writeLocked / @shared / @multiowned would either build
    # double-locking around an already-lock-free type, or attempt to
    # share a heap pointer whose lifecycle is owned by the binding's
    # scope (UAF risk). The DISTINCT carve-out (`~T[]@set:observable`)
    # is the only collection shape and `@set` is a data-shape sigil,
    # not a sync wrapper -- explicitly allowed below.
    if type_obj.tense? && type_obj.observable?
      offending_sync = type_obj.sync if type_obj.sync && !%i[raw symbol].include?(type_obj.sync)
      offending_own = type_obj.ownership if %i[multiowned shared split].include?(type_obj.ownership)
      if offending_sync || offending_own
        labels = []
        labels << "sync wrapper :#{offending_sync}" if offending_sync
        labels << "ownership wrapper :#{offending_own}" if offending_own
        # A19: explain the WHY in the same message so users don't
        # have to read source comments to understand the constraint.
        # Two cases, both surfaced:
        #   - sync (@locked / @writeLocked): the observable is itself
        #     lock-free (atomic accumulator); wrapping it in a lock
        #     would double-synchronize for no benefit, and the lock's
        #     guard semantics conflict with WITH VIEW (which is meant
        #     to be a non-blocking single-load).
        #   - ownership (@shared / @multiowned / @split): the wrapper
        #     is a heap pointer owned by the producing scope. The
        #     producer fiber's `defer ctx.acc.finish()` and the scope's
        #     wait()-then-destroy() cleanup template assume one owner.
        #     Sharing the pointer across owners would race the
        #     producer's lifetime against an unbounded set of readers
        #     and corrupt the WaitGroup bridge.
        explain = if offending_sync && offending_own
          "The observable is already a lock-free single-producer accumulator (extra sync is redundant) AND its heap-pointer lifetime is owned by the producing scope (sharing it across owners would race the producer's `finish()` against the cleanup-side `wait(); destroy()`)."
        elsif offending_sync
          "The observable is already a lock-free single-producer accumulator; layering :#{offending_sync} on top would double-synchronize, and its guard semantics conflict with WITH VIEW (which is meant to be a non-blocking single-load)."
        else
          "The observable's heap-pointer lifetime is owned by the producing scope (the producer fiber's `defer ctx.acc.finish()` plus the scope's `wait(); destroy()` cleanup assume exactly one owner). Sharing it via :#{offending_own} would race the producer's lifetime against the destroy and corrupt the WaitGroup bridge."
        end
        error!(node, :OBSERVABLE_NOT_COMBINABLE, labels: labels.join(' / '), explain: explain)
      end
    end

    # @soa requires a fixed-size array (or collection, which handles its own SOA).
    if type_obj.soa? && !type_obj.collection? && (!type_obj.array? || !type_obj.fixed?)
      error!(node, :SOA_NEEDS_FIXED_ARRAY)
    end

    # @sharded requires N >= 2.
    if type_obj.shard_count && type_obj.shard_count < 2
      error!(node, :SHARDED_NEEDS_2_PLUS, got: type_obj.shard_count)
    end

    # Pools require a fixed capacity: Entity[1000]@pool, not Entity[]@pool.
    if type_obj.pool? && !type_obj.fixed?
      error!(node, :POOL_NEEDS_FIXED_CAPACITY, element: type_obj.element_type&.resolved)
    end

    # Unwrap error-union and optional wrappers to get the inner type
    inner = if type_obj.error_union?
      type_obj.payload_type
    elsif type_obj.optional?
      type_obj.wrapped_type
    else
      type_obj
    end
    return unless inner.is_a?(Type)

    if inner.generic_instance?
      base_name = inner.generic_base

      # Id<T> is a compiler intrinsic — no schema needed
      return if base_name == :Id

      schema = lookup_type_schema(base_name)

      if schema.nil?
        tok = node.token
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
      end

      unless schema.is_a?(Hash) && schema[:type_params]
        error!(node, :GENERIC_NOT_GENERIC, type: base_name)
      end

      expected = schema[:type_params].length
      actual   = inner.generic_args.length
      if actual != expected
        error!(node, :GENERIC_WRONG_ARG_COUNT, type: base_name, expected: expected, got: actual)
      end

      fn_tps = current_fn_ctx&.type_params || []
      inner.generic_args.each do |arg|
        next if BUILTIN_TYPES.include?(arg.resolved)
        next if fn_tps.include?(arg.resolved)  # Cache<T> in a generic fn — T is valid
        arg_schema = lookup_type_schema(arg.resolved)
        if arg_schema.nil?
          error!(node, :GENERIC_UNKNOWN_TYPE_ARG, type: arg.resolved)
        end
        if arg_schema.is_a?(Hash) && arg_schema[:type_params]&.any?
          params_hint = arg_schema[:type_params].map(&:to_s).join(', ')
          error!(node, :GENERIC_MISSING_TYPE_ARGS, type: arg.resolved, type2: arg.resolved, hint: params_hint)
        end
      end

    else
      # Plain type name — check if it's a generic struct/union missing args
      base_name = inner.resolved
      return if (current_fn_ctx&.type_params || []).include?(base_name)  # T itself is valid
      schema = lookup_type_schema(base_name)
      if schema.is_a?(Hash) && schema[:type_params]&.any?
        params_hint = schema[:type_params].map(&:to_s).join(', ')
        error!(node, :GENERIC_MISSING_TYPE_ARGS, type: base_name, type2: base_name, hint: params_hint)
      end
    end
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
  sig { params(node: AST::FuncCall, signature: FunctionSignature, actual_args: T::Array[T.untyped], type_params: T::Array[Symbol]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def infer_generic_type_args!(node, signature, actual_args, type_params)
    T.bind(self, SemanticAnnotator) rescue nil
    subst = {}
    signature.params.each_with_index do |param, i|
      arg = actual_args[i]
      next unless arg
      param_type = param.type || Type.new(:Any)
      actual_type = if arg.respond_to?(:full_type) && arg.full_type
        arg.full_type
      else
        Type.new(arg.resolved_type || :Any)
      end
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

  sig { params(node: AST::FuncCall, signature: FunctionSignature, actual_args: T::Array[T.untyped], type_params: T::Array[Symbol]).returns(NilClass) }
  def enforce_shared_family_call_sync!(node, signature, actual_args, type_params)
    T.bind(self, SemanticAnnotator) rescue nil
    shared_args = T.let([], T::Array[T.untyped])
    signature.params.each_with_index do |param, i|
      arg = actual_args[i]
      next unless arg
      param_type = param.type || Type.new(:Any)
      next unless generic_shared_family_param?(param_type) && type_params.include?(param_type.resolved)
      actual_type = if arg.respond_to?(:full_type) && arg.full_type
        arg.full_type
      else
        Type.new(arg.resolved_type || :Any)
      end
      next unless actual_type.shared?
      shared_args << {
        name: param.name,
        type: generic_shared_payload_binding(actual_type)
      }
    end
    return if shared_args.size < 2

    first = shared_args.first
    return unless first
    mismatch = shared_args.find { |arg| !same_shared_call_capability?(first[:type], arg[:type]) }
    return unless mismatch

    error!(node, :POLY_SHARED_INCONSISTENT,
      fn: node.name,
      first: first[:name], first_cap: shared_call_capability_display(first[:type]),
      second: mismatch[:name], second_cap: shared_call_capability_display(mismatch[:type]),
      hint: "")
  end

  # Recursively match param_type against actual_type to bind type params.
  # Handles both direct uses (T) and nested generic uses (Cache<T>).
  sig { params(node: AST::FuncCall, param_type: Type, actual_type: Type, type_params: T::Array[Symbol], subst: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
  def extract_type_bindings!(node, param_type, actual_type, type_params, subst)
    T.bind(self, SemanticAnnotator) rescue nil
    p_res = param_type.resolved
    a_res = actual_type.resolved
    if type_params.include?(p_res)
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
  sig { params(type_obj: T.untyped, subst: T::Hash[Symbol, T.untyped]).returns(Type) }
  def apply_type_subst(type_obj, subst)
    T.bind(self, SemanticAnnotator) rescue nil
    return Type.new(:Any) if type_obj.nil?
    t = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    resolved = t.resolved
    if subst.key?(resolved)
      substituted = Type.new(subst[resolved])
      if generic_type_has_capabilities?(t)
        merged = Type.new(substituted)
        merged.ownership = t.ownership if t.ownership != :affine
        merged.sync = t.sync if t.sync
        merged.layout = t.layout if t.layout
        merged.elem_ownership = t.elem_ownership if t.elem_ownership
        merged.elem_sync = t.elem_sync if t.elem_sync
        merged
      else
        substituted
      end
    elsif t.generic_instance?
      new_args = t.generic_args.map { |arg| generic_binding_source(apply_type_subst(arg, subst)) }
      Type.new(:"#{t.generic_base}<#{new_args.join(',')}>")
    else
      # Handle array suffix: T[] → String[] when T → String
      str = resolved.to_s
      if str.end_with?('[]')
        inner = T.must(str[0..-3]).to_sym
        if subst.key?(inner)
          return Type.new(:"#{subst[inner]}[]")
        end
      end

      # Handle prefixed types: !T, ?T, ~T — substitute the inner type.
      prefix = str.match(/\A([!?~]+)/)&.[](1)
      if prefix
        inner = T.must(str[prefix.length..]).to_sym
        if subst.key?(inner)
          Type.new(:"#{prefix}#{subst[inner]}")
        else
          t
        end
      else
        t
      end
    end
  end

  sig { params(type: Type).returns(T.untyped) }
  def generic_binding_value(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = type.is_a?(Type) ? type : Type.new(type)
    generic_type_has_capabilities?(t) ? Type.new(t) : t.resolved
  end

  sig { params(type: Type).returns(T::Boolean) }
  def generic_shared_family_param?(type)
    T.bind(self, SemanticAnnotator) rescue nil
    type.is_a?(Type) && type.polymorphic_shared? && type.resolved.to_s.match?(/\A[A-Z]\z/)
  end

  sig { params(type: Type).returns(Type) }
  def generic_shared_payload_binding(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = type.is_a?(Type) ? Type.new(type) : Type.new(type)
    t.ownership = :affine
    t.provenance = nil if t.respond_to?(:provenance=)
    t.instance_variable_set(:@generic_payload_type_arg, true)
    t
  end

  sig { params(left: T.untyped, right: T.untyped).returns(T::Boolean) }
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
    l = left.is_a?(Type) ? left : Type.new(left)
    r = right.is_a?(Type) ? right : Type.new(right)
    l.sync == r.sync &&
      l.layout == r.layout &&
      l.elem_ownership == r.elem_ownership &&
      l.elem_sync == r.elem_sync
  end

  sig { params(type: Type).returns(T::Boolean) }
  def generic_type_has_capabilities?(type)
    T.bind(self, SemanticAnnotator) rescue nil
    type.ownership != :affine ||
      !type.sync.nil? ||
      !type.layout.nil? ||
      !type.elem_ownership.nil? ||
      !type.elem_sync.nil?
  end

  sig { params(type: T.untyped).returns(String) }
  def generic_binding_source(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = type.is_a?(Type) ? type : Type.new(type)
    parts = [t.resolved.to_s]

    ownership = case t.ownership
    when :shared then "@shared"
    when :multiowned then "@multiowned"
    when :link then "@link"
    when :split then "@split"
    when :frozen then "@frozen"
    end
    parts << ownership if ownership

    sync = case t.sync
    when :locked then "@locked"
    when :write_locked then "@writeLocked"
    when :versioned then "@versioned"
    when :atomic then "@atomic"
    when :local then "@local"
    when :always_mutable then "@alwaysMutable"
    end
    parts << sync if sync

    parts.join("")
  end

  sig { params(type: Type).returns(String) }
  def shared_call_capability_display(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = type.is_a?(Type) ? type : Type.new(type)
    caps = ["@shared"]
    caps << "indirect" if t.layout == :indirect
    caps << T.must(case t.sync
            when :locked then "locked"
            when :write_locked then "writeLocked"
            when :versioned then "versioned"
            when :atomic then "atomic"
            when :local then "local"
            when :always_mutable then "alwaysMutable"
            end)
    caps.compact.join(":")
  end

  # Build a concrete copy of a generic function signature with all type params
  # replaced by their inferred concrete types.
  sig { params(signature: FunctionSignature, subst: T::Hash[Symbol, Symbol]).returns(FunctionSignature) }
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
  sig { params(node: T.untyped).returns(NilClass) }
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
  sig { params(node: T.untyped, final_type: T.untyped).returns(T.nilable(Type)) }
  def propagate_declared_type_to_value!(node, final_type)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless node.type

    # BgStreamBlock infers ~?T[]; declared ~T[INF] picks the runtime wrapper.
    if node.value.is_a?(AST::BgStreamBlock) && node.type.inf_stream?
      node.value.full_type = final_type
    end

    if node.value.is_a?(AST::BgStreamBlock) && node.type.split_open_stream?
      node.value.full_type = Type.new(node.value.full_type, ownership: :split)
    end

    # Propagate shard_count from declared type into final_type (lost during coerce!).
    if node.type.shard_count
      if final_type.is_a?(Type)
        final_type.shard_count = node.type.shard_count
      end
    end

    # Propagate @shared ownership into BgBlock for SharedPromise.spawn().
    if node.value.is_a?(AST::BgBlock) && node.type.shared_promise?
      node.value.full_type = Type.new(node.value.full_type, ownership: :shared)
    end
  end

  # Propagate collection, shard_count, soa, and sync metadata from the declared
  # type annotation (or inferred value type) into node.full_type and node.full_type.
  # These fields are lost during finalize_storage! and coerce!.
  sig { params(node: T.untyped, final_type: T.untyped).returns(T.nilable(Symbol)) }
  def propagate_collection_metadata!(node, final_type)
    T.bind(self, SemanticAnnotator) rescue nil
    coll_src = if (decl_t = node.type) && decl_t.collection
      decl_t
    elsif node.value.full_type.collection
      node.value.full_type
    end
    if coll_src
      node.full_type.collection  = coll_src.collection
      node.full_type.provenance  = :heap if coll_src.collection == :pool || coll_src.collection == :set
      node.full_type.shard_count = coll_src.shard_count if coll_src.shard_count
      node.full_type.soa         = coll_src.soa if coll_src.respond_to?(:soa) && coll_src.soa
      if node.full_type
        node.full_type.collection  = coll_src.collection unless node.full_type.collection
        node.full_type.soa         = coll_src.soa if coll_src.respond_to?(:soa) && coll_src.soa
        node.full_type.shard_count = coll_src.shard_count if coll_src.shard_count && !node.full_type.shard_count
      end
    end

    # Standalone @soa on fixed arrays (no collection): propagate soa flag directly.
    if !coll_src && (decl_t = node.type) && decl_t.soa
      node.full_type.soa = true if node.full_type
      node.full_type.soa = true
    end

    # Map-specific propagation: maps don't use :collection, so the above doesn't cover them.
    if (decl_t = node.type)
      if decl_t.shard_count && !node.full_type.shard_count
        node.full_type.shard_count = decl_t.shard_count if node.full_type
        node.full_type.instance_variable_set(:@shard_count, decl_t.shard_count)
      end
      if decl_t.sync && node.full_type && !node.full_type.sync
        node.full_type.sync = decl_t.sync
        node.full_type.sync = decl_t.sync
      end
      if decl_t.ownership != :affine && node.full_type
        node.full_type.instance_variable_set(:@ownership, decl_t.ownership)
        node.full_type.instance_variable_set(:@ownership, decl_t.ownership)
      end
    end
  end

  # Propagate heap_promoted flag from function call return values.
  # Looks through OR expressions (BinaryOp :OR) to find the underlying
  # call — `x = failableFunc() OR default` should still propagate
  # heap_promoted from failableFunc's returns_promoted flag.
  sig { params(node: T.untyped).returns(T.nilable(Symbol)) }
  def propagate_call_flags!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    if has_heap_promoted_call?(node.value)
      node.full_type.provenance = :heap
    end
  end


  # Register container borrow in the OG when a binding receives a value
  # from container access (HashMap/Pool/List indexing, through OR).
  sig { params(node: T.untyped).returns(T.nilable(T::Boolean)) }
  def register_container_borrow!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    container = find_container_source(node.value)
    return unless container
    var_name = node.name.is_a?(String) ? node.name : node.name.to_s
    @og = T.let(@og, T.untyped)
    @og[var_name]&.kind = :borrowed
    node.container_borrow = true
  end

  # Walk through OR/OR_RESCUE to find the root container/struct variable name.
  # Returns the root variable name when the expression borrows from a container
  # (GetIndex on map/list) or extracts a non-Copy field from a struct (GetField).
  sig { params(expr: T.untyped).returns(T.nilable(String)) }
  def find_container_source(expr)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil unless expr
    # COPY/CLONE produce owned/retained values; no borrow relationship.
    return nil if expr.is_a?(AST::CopyNode) || expr.is_a?(AST::CloneNode)
    if expr.is_a?(AST::GetIndex) && expr.target.respond_to?(:full_type)
      ti = expr.target.full_type
      if ti&.map? || ti&.pool? || ti&.list_collection? || (ti&.array? && !ti&.string?)
        return root_variable_name(expr.target)
      end
    end
    # Non-Copy field extraction from a struct is a borrow of the parent.
    # Without this, the extracted variable gets its own cleanup defer while
    # the parent's cleanup also frees the field -- double-free.
    # Skip enum/union variant constructors (e.g. Value.Nil) - these create new
    # values, not borrows from an existing variable.
    if expr.is_a?(AST::GetField) && expr.respond_to?(:full_type)
      if expr.target.is_a?(AST::Identifier)
        target_schema = (lookup_type_schema(expr.target.name.to_sym) rescue nil)
        return nil if target_schema.is_a?(Hash) && (target_schema[:kind] == :enum || target_schema[:kind] == :union)
      end
      field_ti = expr.full_type
      if !field_ti.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil }
        return root_variable_name(expr.target)
      end
    end
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_RESCUE)
      return find_container_source(expr.left)
    end
    # pool[id]? parses as OptionalUnwrap(GetIndex) - peel through the unwrap.
    if expr.is_a?(AST::OptionalUnwrap)
      return find_container_source(expr.target)
    end
    nil
  end

  # Check if an expression carries heap_promoted_call, looking through
  # OR/OR_RESCUE wrappers. Used by propagate_call_flags! and visit_BgBlock.
  # Both OR (orelse) and OR_RESCUE (catch) propagate because the transpiler
  # ensures fallback struct values also have their string fields duped to heap.
  sig { params(expr: T.untyped).returns(T::Boolean) }
  def has_heap_promoted_call?(expr)
    T.bind(self, SemanticAnnotator) rescue nil
    return false unless expr
    return true if expr.full_type.heap_provenance?
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_RESCUE)
      return has_heap_promoted_call?(expr.left)
    end
    false
  end

  # Returns true when a BG block's last expression is a string that will be
  # frame-allocated and thus needs heap-duping before the fiber exits.
  # Mirrors bg_exit_needs_string_dupe? in MIRPass but runs at annotation time.
  sig { params(expr: T.untyped).returns(T::Boolean) }
  def bg_exit_frame_string?(expr)
    T.bind(self, SemanticAnnotator) rescue nil
    return false unless expr
    t = expr.full_type
    return false unless t.string?
    return false if t.heap? || t.rodata?
    return true  if t.frame?
    # Check stdlib def for explicit frame allocation (provenance not yet set on expr).
    if expr.respond_to?(:matched_stdlib_def)
      msd = expr.matched_stdlib_def
      return true if msd && msd.emit&.return_alloc == :frame
    end
    false
  end
end
