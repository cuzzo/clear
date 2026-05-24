# typed: strict
require "sorbet-runtime"

module MIRLoweringFunctions
  extend T::Sig
  extend T::Helpers

  requires_ancestor { MIRLowering }

  class CallArgFacts < T::Struct
    const :ast_arg, T.untyped
    const :type_info, Type
    const :callee_sig, T.nilable(FunctionSignature)
    const :callee_param, T.nilable(AST::Param)
    const :callee_param_type, Type
    const :takes, T::Boolean
    const :copy_to_owning, T::Boolean
    const :arg_alloc, Symbol
    const :param_index, Integer
  end

  class CallOwnershipFacts < T::Struct
    extend T::Sig

    const :takes_indices, T::Set[Integer]
    const :consumed_names, T::Array[String]

    sig { params(index: Integer).returns(T::Boolean) }
    def takes?(index)
      takes_indices.include?(index)
    end

    sig { returns(T::Boolean) }
    def takes_any?
      !takes_indices.empty?
    end

    sig { returns(MIR::OwnershipContract) }
    def ownership_contract
      MIR::OwnershipContract.consumes(consumed_names)
    end
  end

  class StdlibCallArgFact < T::Struct
    extend T::Sig

    COERCIBLE_PRIMITIVES = T.let(
      Set[:Int64, :Float64, :Int32, :Int16, :Int8, :UInt64, :UInt32, :UInt16, :UInt8, :Bool].freeze,
      T::Set[Symbol],
    )

    const :index, Integer
    const :ast_arg, T.untyped
    const :takes, T::Boolean
    const :coerce_type, T.nilable(Symbol)

    sig { params(arg_zig: String).returns(String) }
    def coerce_zig(arg_zig)
      type_sym = coerce_type
      return arg_zig unless type_sym
      return arg_zig unless COERCIBLE_PRIMITIVES.include?(type_sym)

      zig_t = Type.new(type_sym).zig_type
      "@as(#{zig_t}, #{arg_zig})"
    end
  end

  class StdlibCallFacts < T::Struct
    extend T::Sig

    const :args, T::Array[StdlibCallArgFact]
    const :ownership, CallOwnershipFacts

    sig { params(index: Integer).returns(T::Boolean) }
    def takes?(index)
      fact = args[index]
      !!(fact && fact.takes)
    end

    sig { params(index: Integer).returns(T.untyped) }
    def ast_arg(index)
      args.fetch(index).ast_arg
    end

    sig { params(arg_zig: String, index: Integer).returns(String) }
    def coerce_zig(arg_zig, index)
      fact = args[index]
      fact ? fact.coerce_zig(arg_zig) : arg_zig
    end
  end

  sig { params(node: AST::ExternFnDecl).returns(T.untyped) }
  def lower_extern_fn(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @emitted_extern_modules = T.let(@emitted_extern_modules, T.untyped)
    mod = node.from_module
    if @emitted_extern_modules.add?(mod)
      mod_parts = mod.split(".")
      import_expr = "@import(\"#{mod_parts.first}\")" + mod_parts[1..].map { |p| ".#{p}" }.join
      mod_alias = mod.gsub(".", "_")
      module_path = MIRLowering::EXTERN_MODULE_ROOTS.include?(mod_parts.first) ? mod_parts.first : "#{mod_parts.first}.zig"
      MIR::Import.new(mod_alias, module_path, mod_parts.length > 1 ? mod_parts[1..].join(".") : nil)
    else
      MIR::Noop.new("extern_fn_import_already_emitted")
    end
  end

  sig { params(node: AST::ExternStructDecl).returns(T.untyped) }
  def lower_extern_struct(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @emitted_extern_modules = T.let(@emitted_extern_modules, T.untyped)
    if node.from_module
      mod = node.from_module
      mod_parts = mod.split(".")
      mod_alias = mod.gsub(".", "_")

      items = []
      if @emitted_extern_modules.add?(mod)
        member_chain = mod_parts[1..].any? ? mod_parts[1..].join(".") : nil
        module_path = MIRLowering::EXTERN_MODULE_ROOTS.include?(mod_parts.first) ? mod_parts.first : "#{mod_parts.first}.zig"
        items << MIR::Import.new(mod_alias, module_path, member_chain)
      end
      # AS "ZigTypeExpr" allows aliasing to parameterized types like Parsed(JsonRecord).
      zig_rhs = node.as_type ? "#{mod_alias}.#{node.as_type}" : "#{mod_alias}.#{node.name}"
      items << MIR::TypeAlias.new(node.name, zig_rhs)
      items.length == 1 ? items.first : items
    elsif node.field_decls.empty?
      MIR::Noop.new("empty_local_extern_struct")
    else
      fields = node.field_decls.map { |name, fd|
        zig_t = transpile_type(fd.type, is_field: true)
        MIR::FieldDef.new(name.to_s, zig_t, nil)
      }
      MIR::StructDef.new(node.name, fields, nil, nil)
    end
  end

  # ================================================================
  # Functions
  # ================================================================

  sig { params(node: AST::FunctionDef).returns(T.untyped) }
  def lower_function_def(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_bindings = T.let(@current_bindings, T.untyped)
    @current_fn_collection_params = T.let(@current_fn_collection_params, T.untyped)
    @current_fn_has_catch = T.let(@current_fn_has_catch, T.untyped)
    @current_fn_has_rt = T.let(@current_fn_has_rt, T.untyped)
    @current_fn_mutable_scalar_params = T.let(@current_fn_mutable_scalar_params, T.untyped)
    @current_fn_param_names = T.let(@current_fn_param_names, T.untyped)
    @current_fn_takes_param_names = T.let(@current_fn_takes_param_names, T.untyped)
    @current_fn_heap_carry_return = T.let(@current_fn_heap_carry_return, T.untyped)
    @current_fn_heap_carry_return_vars = T.let(@current_fn_heap_carry_return_vars, T.untyped)
    @current_fn_return_payload_zig = T.let(@current_fn_return_payload_zig, T.untyped)
    @current_fn_returned_names = T.let(@current_fn_returned_names, T.untyped)
    @current_fn_snapshot_types = T.let(@current_fn_snapshot_types, T.untyped)
    @current_fn_tail_call = T.let(@current_fn_tail_call, T.untyped)
    @current_fn_zig_name = T.let(@current_fn_zig_name, T.untyped)
    @decl_zig_name_map = T.let(@decl_zig_name_map, T.untyped)
    @fn_alloc_marked_names = T.let(@fn_alloc_marked_names, T.untyped)
    @fn_name_rename_map = T.let(@fn_name_rename_map, T.untyped)
    @guarded_cleanup_names = T.let(@guarded_cleanup_names, T.untyped)
    @enum_schemas = T.let(@enum_schemas, T.untyped)
    @struct_schemas = T.let(@struct_schemas, T.untyped)
    @union_schemas = T.let(@union_schemas, T.untyped)
    ret_type = node.return_type || :Void
    if ret_type.is_a?(Type) && ret_type.frame? && ret_type.struct?
      ret_type = Type.new(ret_type.resolved)
    end
    final_type = transpile_type(ret_type)

    fn_needs_rt = finalized_needs_rt!(node)
    # Synthesized trampolines allocate child frames, so they need rt even
    # when the user body does not otherwise mention it.
    fn_needs_rt = true if node.thunk_plan
    # Mutual trampolines call rt.checkYield() each iteration.
    fn_needs_rt = true if node.mutual_thunk_plan
    fn_can_fail = node.can_fail.nil? ? true : node.can_fail
    @current_fn_has_rt = fn_needs_rt
    @current_fn_tail_call = node.tail_call
    @current_fn_zig_name = T.let(zig_safe_name(node.name), T.nilable(String))
    @current_fn_return_payload_zig = T.let(final_type.sub(/\Aanyerror!/, "").sub(/\A!/, ""), T.nilable(String))
    @current_fn_returned_names = collect_fn_returned_names(node.body)
    @current_fn_heap_carry_return = node.respond_to?(:heap_carry_return) && node.heap_carry_return
    @current_fn_heap_carry_return_vars = node.respond_to?(:heap_carry_return_vars) ? node.heap_carry_return_vars : nil

    # Set current bindings so lower_var_decl can look up cleanup info.
    @current_bindings = node.cleanup_bindings || {}
    # Per-function name disambiguation: when two variables share the same Zig
    # name but have different allocators (different scopes), the MIR checker's
    # flat name-keyed allocs dict would conflate them.  Track which names have
    # had AllocMarks emitted and remap collisions to <name>_L<line>.
    @fn_alloc_marked_names = {}   # safe_name => true (seen at least once)
    @lowered_alloc_names = T.let(Set.new, T.nilable(T::Set[T.untyped]))
    @lowered_guarded_cleanup_names = T.let(Set.new, T.nilable(T::Set[T.untyped]))
    @decl_zig_name_map    = {}    # node.object_id => disambiguated Zig name
    @guarded_cleanup_names = {}   # safe Zig local name => true when a moved guard was emitted
    # Name-keyed fallback used by AST-level markers (SuppressCleanup, Drop,
    # ReassignCleanup) whose lowering doesn't have access to the decl's
    # AST node. Populated by lower_var_decl in lowering order: whichever
    # branch's decl was lowered most recently wins, which matches the
    # lexical-scope assumption that SuppressCleanup for a binding appears
    # between its decl and the next same-name decl.
    @fn_name_rename_map   = {}    # original_name => disambiguated Zig name

    # Mutable scalar params: Zig params are const, need shadow vars.
    # Collections (MUTABLE @list / pool / etc.) are pointer-passed and
    # mutated through the pointer — NOT scalar shadows. Exclude them
    # explicitly: `transpile_type` returns "anytype" for MUTABLE @list
    # which doesn't match the [] / * prefix check, so without this they
    # incorrectly received the `_m_` rename. The rename then masked the
    # original name from MIR-level checks (notably the new
    # INV-CROSS-FRAME-PARAM-ALLOC verifier in mir_checker.rb).
    mutable_scalar_params = node.params.select { |p|
      next false unless p.mutable
      p_type_obj = p.type || Type.new(:Any)
      next false if p_type_obj && (p_type_obj.collection? ||
                                    (p_type_obj.respond_to?(:needs_pointer_passing?) && p_type_obj.needs_pointer_passing?))
      !transpile_type(p.type, is_param: true).start_with?("[]", "*")
    }.map { |p| p.name }.to_set
    @current_fn_mutable_scalar_params = T.let(mutable_scalar_params, T.nilable(T::Set[T.untyped]))

    # Collection params: already passed by pointer, skip & at recursive
    # call sites. Includes `MUTABLE xs: T[]@list` -- those are passed
    # by pointer too (see the call-site routing below). Without this,
    # forwarding a `MUTABLE @list` param to another `MUTABLE @list`
    # callee adds a second `&`, producing `**ArrayList` which Zig's
    # one-level method auto-deref can't unwrap.
    @current_fn_collection_params = node.params.select { |p|
      p_type_obj = p.type || Type.new(:Any)
      p_type_obj.needs_pointer_passing? ||
        (p.mutable && p_type_obj.list_collection?)
    }.map { |p| p.name }.to_set
    @current_fn_collection_params.each do |name|
      @current_bindings[name.to_s] ||= CleanupEntry.no_cleanup(alloc: :heap, scope: :heap)
    end

    # All param names: used to distinguish params (slices) from locals (ArrayLists)
    @current_fn_param_names = node.params.map { |p| p.name }.to_set
    @current_fn_takes_param_names = node.params.select { |p| p.takes }.map { |p| p.name }.to_set

    # Build param list
    params_mir = T.let(node.params.map { |param|
      p_name = mutable_scalar_params.include?(param.name) ? "_m_#{param.name}" : param.name
      p_type_sym = param.type&.resolved
      p_type_obj = param.type || Type.new(:Any)
      is_user_struct = @struct_schemas&.key?(p_type_sym)
      # Atomic params need `anytype` so call sites pass the cell itself,
      # allowing WITH MATCH comptime probes to dispatch by actual family.
      sym = param.symbol
      atomic_sync = sym && (sym.atomic? ||
                            (sym.sync_families && sym.sync_families.include?(:ATOMIC)))
      zig_t = if p_type_obj.shared? && p_type_obj.resolved.to_s.match?(/\A[A-Z]\z/)
        "CheatLib.Arc(#{p_type_obj.resolved})"
      elsif is_user_struct
        "anytype"
      elsif p_type_obj.collection?
        "anytype"
      elsif atomic_sync
        "anytype"
      else
        transpile_type(param.type, is_param: true)
      end
      zig_t = "*#{zig_t}" if mutable_scalar_params.include?(param.name) && zig_t != "anytype"
      # `pointer_passed`: this param's receiver is a pointer-to-T at the
      # Zig level, so allocations made inside this function on its behalf
      # outlive the function. Mirrors `@current_fn_collection_params`'s
      # criteria so the MIR checker can independently verify the
      # allocator-routing decision (see INV-CROSS-FRAME-PARAM-ALLOC).
      pointer_passed = p_type_obj.needs_pointer_passing? ||
                       (param.mutable && p_type_obj.list_collection?) ||
                       mutable_scalar_params.include?(param.name)
      MIR::Param.new(p_name, zig_t, pointer_passed)
    }, T::Array[MIR::Param])

    # Prepend rt param
    if fn_needs_rt
      params_mir.unshift(MIR::Param.new("rt", "*Runtime", false))
    end

    # Comptime params
    comptime_params = (node.type_params || []).map { |tp| "comptime #{tp}: type" }

    # Build return type string. The error prefix is baked into the string,
    # so can_fail on MIR::FnDef is always false (emitter would double it).
    tied_shared_return = tied_shared_family_return_param(node, mutable_scalar_params)
    return_type_str = if tied_shared_return
      tied_shared_return
    elsif fn_can_fail
      # If the user declared `RETURNS !T`, `final_type` already carries the
      # error union. Don't double-prefix.
      if final_type.include?("anyerror!") || final_type.include?("error{")
        final_type
      elsif node.reentrant == :reentrant && final_type.start_with?("!")
        # Reentrant / mutually-recursive fns must carry `anyerror!T`
        # rather than the bare `!T`. Zig's inferred-error-set
        # convergence fails for cycles where two `!T` fns call each
        # other (`'eval' uses inferred error set of function
        # 'evalList' here -> dependency loop`). The `anyerror`
        # prefix makes the error set concrete and breaks the loop.
        "anyerror#{final_type}"
      elsif final_type.start_with?("!")
        final_type
      elsif node.reentrant == :reentrant
        "anyerror!#{final_type}"
      else
        "!#{final_type}"
      end
    else
      final_type
    end

    vis = (node.visibility == :pub) ? :pub : :private

    # Determine used names for param suppression
    used_names = collect_identifier_names(node.body)

    # Build prologue statements
    prologue = []

    # Frame mark save/restore.
    # uses_frame from annotation is stale after escape analysis marks locals heap.
    # When cleanup_bindings is set (post-MIRPass), derive from it: it reflects the
    # final allocators. Fall back to uses_frame when cleanup_bindings is absent
    # (synthetic functions, specs). Generic allocator use is not a frame
    # lifetime fact; heap-only stdlib calls must not force frame save/restore.
    has_frame_bindings = if node.cleanup_bindings
                           node.cleanup_bindings.any? { |_, e| e.alloc == :frame }
                         else
                           node.uses_frame
                         end
    uses_frame_or_alloc = has_frame_bindings
    ret_type_obj = node.return_type || Type.new(:Void)
    # Unwrap `!T` so value-type and string-return classification sees the
    # payload; otherwise frame save/restore is skipped for error-union returns.
    bare_ret = if ret_type_obj.respond_to?(:error_union?) && ret_type_obj.error_union? &&
                  ret_type_obj.respond_to?(:payload_type)
                 ret_type_obj.payload_type || ret_type_obj
               else
                 ret_type_obj
               end
    returns_value_type = bare_ret.void? || bare_ret.primitive? || bare_ret.resource? ||
                         @enum_schemas&.key?(bare_ret.resolved) ||
                         @union_schemas&.key?(bare_ret.resolved)
    returns_string = ret_type_obj.string? || (ret_type_obj.error_union? && ret_type_obj.payload_type&.string?)
    heap_carry_return = node.respond_to?(:heap_carry_return) && node.heap_carry_return
    if fn_needs_rt
      prologue << MIR::ExprStmt.new(
        MIR::Call.new("@setEvalBranchQuota", [MIR::Lit.new("100000")], false, false, MIR::CallableContract.no_ownership(1)),
        false,
      )
      # FrameRestore is safe only when the return value is NOT frame-allocated:
      #   - value types (primitives, enums): no frame pointer returned
      #   - heap carry return strings: result is on heap, frame rewind is safe
      # For frame-string returns (no heap_carry_return), we skip the mark/restore
      # entirely: the returned string lives in the caller's frame region.
      if uses_frame_or_alloc && (returns_value_type || (returns_string && heap_carry_return))
        prologue << MIR::FrameSave.new(@rt_name)
        prologue << MIR::FrameRestore.new(@rt_name)
      else
        prologue << MIR::Suppress.new("rt")
      end
    end

    # NonReentrant guard. Two prologue shapes:
    #   :NOT_LOGICAL (max_depth_n nil) -> StackGuard linked-list
    #     (raises System UnexpectedRecursion on re-entry)
    #   :MAX_DEPTH(N) (max_depth_n set) -> per-fn depth counter
    #     (raises System MaxDepthExceeded above N).
    if node.reentrant == :non_reentrant
      if node.max_depth_n
        # try safety.enterDepth(@src(), N);
        # defer safety.exitDepth(@src());
        enter_call = MIR::Call.new(
          "safety.enterDepth",
          [MIR::Call.new("@src", [], false, false, MIR::CallableContract.no_ownership(0)), MIR::Lit.new(node.max_depth_n.to_s)],
          false,
          false,
          MIR::CallableContract.no_ownership(2),
        )
        prologue.unshift(MIR::DeferStmt.new(MIR::Call.new(
          "safety.exitDepth",
          [MIR::Call.new("@src", [], false, false, MIR::CallableContract.no_ownership(0))],
          false,
          false,
          MIR::CallableContract.no_ownership(1),
        )))
        prologue.unshift(MIR::ExprStmt.new(MIR::TryExpr.new(enter_call), false))
      else
        guard_init = MIR::Let.new("_guard",
          MIR::TryExpr.new(MIR::Call.new(
            "safety.StackGuard.enter",
            [MIR::Call.new("@src", [], false, false, MIR::CallableContract.no_ownership(0))],
            false,
            false,
            MIR::CallableContract.no_ownership(1),
          )),
          true, nil, nil)
        guard_push = MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new("_guard"), "push", [], false, MIR::CallableContract.no_ownership(0)), false)
        guard_defer = MIR::DeferStmt.new(MIR::MethodCall.new(MIR::Ident.new("_guard"), "pop", [], false, MIR::CallableContract.no_ownership(0)))
        prologue.unshift(guard_defer)
        prologue.unshift(guard_push)
        prologue.unshift(guard_init)
      end
    end

    # Recursion co-op yield: emit `rt.checkYield();` at fn entry for
    # every recursive fn that isn't TIGHT. Same opt-out + same budget
    # (4096 inline counter ticks before scheduler hand-off) as
    # `WHILE`. The :THUNK trampoline body has its own checkYield;
    # for the user's TIGHT request we strip that one in
    # ThunkTransform::Emit (driven by node.tight_reentrance).
    if fn_needs_rt && needs_recursion_yield?(node)
      prologue.unshift(MIR::ExprStmt.new(
        MIR::MethodCall.new(MIR::Ident.new(@rt_name), "checkYield", [], false, MIR::CallableContract.no_ownership(0)),
        false
      ))
    end

    # Param suppressions for unused params
    node.params.each do |p|
      next if used_names.include?(p.name)
      suppress_name = mutable_scalar_params.include?(p.name) ? "_m_#{p.name}" : p.name
      prologue << MIR::Suppress.new(suppress_name)
    end

    # Mutable scalar param shadows
    mutable_scalar_params.each do |name|
      next unless used_names.include?(name)
      ptr_name = "_m_#{name}"
      prologue << MIR::Let.new(name, MIR::Deref.new(MIR::Ident.new(ptr_name)), true, nil, "_ = &#{name};")
      prologue << MIR::DeferStmt.new(MIR::ScopeBlock.new([
        MIR::Set.new(MIR::Deref.new(MIR::Ident.new(ptr_name)), MIR::Ident.new(name))
      ]))
    end

    # Emit AllocMark + Cleanup for TAKES parameters (replaces insert_takes_drops! from MIRPass).
    # TAKES params own their value from function entry; cleanup is always defer (Cleanup, not ErrCleanup).
    takes_mir = []
    node.params.select { |p| p.takes }.each do |p|
      entry = @current_bindings[p.name.to_s] || CleanupEntry::NONE
      ti = p.type || Type.new(:Any)
      next unless ownership_tracked_transfer_type?(ti) || (entry.present? && entry.alloc == :heap)

      drop_entry = entry.dup
      alloc = entry.present? ? entry.alloc : :heap
      scope = entry.present? ? entry.scope : :heap
      mark = MIR::AllocMark.new(p.name.to_s, alloc, ti)
      mark.scope = scope
      takes_mir << mark
      if entry.needs_cleanup?
        build_drop_entry!(drop_entry, ti, nil)
        (@guarded_cleanup_names ||= {})[zig_safe_name(p.name.to_s)] = true if drop_entry.has_moved_guard?
        takes_mir << MIR::Cleanup.new(zig_safe_name(p.name.to_s), drop_entry)
      end
    end
    takes_mir.each do |node|
      T.must(@lowered_alloc_names) << node.name.to_s if node.is_a?(MIR::AllocMark)
      T.must(@lowered_guarded_cleanup_names) << node.name.to_s if (node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)) && node.cleanup_entry.has_moved_guard?
    end

    pointer_param_mir = []

    # Lower body (track snapshot types for catch blocks)
    has_catch = node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
    @current_fn_has_catch = has_catch
    @current_fn_snapshot_types = Set.new if has_catch
    # Trampoline bodies are synthesized directly while preserving the
    # normal function signature seen by callers.
    if node.thunk_plan
      body_mir = takes_mir + pointer_param_mir + [ThunkTransform::Emit.build_trampoline(node, self)]
    elsif node.mutual_thunk_plan
      body_mir = takes_mir + pointer_param_mir + [ThunkTransform::Emit.build_mutual_trampoline(node, self)]
    else
      pre_checks = lower_pre_clauses(node)
      body_mir = takes_mir + pointer_param_mir + pre_checks + T.must(lower_body(node.body))
    end

    # POST + CATCH is rejected at annotation time (see
    # visit_post_clauses! in capabilities.rb) with a clean CLEAR error,
    # so by the time we reach lowering this combination is impossible.
    has_post = node.respond_to?(:post_clauses) && node.post_clauses && node.post_clauses.any?

    if has_post
      # Inner/outer pair: inner contains the original body, outer wraps
      # in a debug-mode POST validator. In release builds the wrapper's
      # body collapses to a single tail call to the inner, which LLVM
      # inlines into every callsite — zero overhead.
      [build_post_inner_fn(node, params_mir, return_type_str, prologue, body_mir, comptime_params),
       build_post_outer_fn(node, params_mir, return_type_str, fn_needs_rt, vis, comptime_params)]
    elsif has_catch
      # Emit inner/outer function pair
      inner_name = "__#{node.name}_body"
      already_error_union = final_type.start_with?("!") ||
                            final_type.include?("anyerror!") ||
                            final_type.include?("error{")
      inner_ret = if already_error_union
                    final_type
                  elsif fn_can_fail
                    "anyerror!#{final_type}"
                  else
                    "!#{final_type}"
                  end

      inner_fn = MIR::FnDef.new(inner_name, params_mir, inner_ret,
                                 prologue + body_mir, :private, false, comptime_params)

      # Outer function: calls inner, catches errors
      call_args = fn_needs_rt ? ["rt"] + node.params.map { |p| p.name } : node.params.map { |p| p.name }
      inner_call = "#{inner_name}(#{call_args.join(', ')})"

      catch_zig, catch_clause_bodies = build_catch_clauses(node, fn_can_fail)
      error_reassigns = collect_catch_reassigns(node)
      catch_meta = (node.catch_clauses || []).map { |clause|
        {
          kinds: clause.kinds.map(&:to_s),
          types: clause.types.map(&:to_s),
          filter_types: clause.filter_types.map(&:to_s),
          filter_messages: clause.filter_messages.map { |m| lower(m) },
        }
      }
      has_default = node.default_catch.is_a?(Array) && node.default_catch.any?
      outer_body = [
        MIR::CatchWrapper.new("return #{inner_call} catch {\n    #{catch_zig}\n};", error_reassigns, catch_clause_bodies, catch_meta, has_default)
      ]

      outer_fn = MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                                  outer_body, vis, false, comptime_params)

      # Return both FnDefs as an array (lower_program/lower_module flatten arrays)
      [inner_fn, outer_fn]
    else
      MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                      prologue + body_mir, vis, false, comptime_params)
    end
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def finalized_needs_rt!(node)
    return true if node.thunk_plan || node.mutual_thunk_plan
    return node.needs_rt if node.needs_rt == true || node.needs_rt == false

    Kernel.raise "function #{node.name} missing finalized needs_rt metadata before MIR lowering"
  end

  # Build the inner function for a POST-having FunctionDef. Holds the
  # original body verbatim. Marked :private so callers go through the
  # outer wrapper (which validates).
  sig { params(node: AST::FunctionDef, params_mir: T::Array[MIR::Param], return_type_str: String, prologue: T::Array[T.untyped], body_mir: T::Array[T.untyped], comptime_params: T::Array[T.untyped]).returns(MIR::FnDef) }
  def build_post_inner_fn(node, params_mir, return_type_str, prologue, body_mir, comptime_params)
    T.bind(self, MIRLowering) rescue nil
    inner_name = "__#{zig_safe_name(node.name)}_post_body"
    MIR::FnDef.new(inner_name, params_mir, return_type_str,
                   prologue + body_mir, :private, false, comptime_params)
  end

  # Build the outer wrapper for a POST-having FunctionDef. Calls the
  # inner, captures the result, evaluates each POST predicate inside a
  # debug-mode `if` block, panics on violation, returns the result.
  sig { params(node: AST::FunctionDef, params_mir: T::Array[MIR::Param], return_type_str: String, fn_needs_rt: T::Boolean, vis: Symbol, comptime_params: T::Array[T.untyped]).returns(MIR::FnDef) }
  def build_post_outer_fn(node, params_mir, return_type_str, fn_needs_rt, vis, comptime_params)
    T.bind(self, MIRLowering) rescue nil
    inner_name = "__#{zig_safe_name(node.name)}_post_body"
    # The outer wrapper sees parameters under their Zig-level names —
    # MUTABLE-by-value params get renamed to `_m_<name>` (see
    # `mutable_scalar_params` in lower_function_def). The inner body
    # uses the same renaming, so the call must forward the renamed
    # names verbatim. Forwarding the user-level name would produce
    # "use of undeclared identifier" at the wrapper's call site.
    mutable_scalar = node.params.select { |p|
      p.mutable && !transpile_type(p.type, is_param: true).start_with?("[]", "*")
    }.map { |p| p.name }.to_set
    forward_name = ->(p) { mutable_scalar.include?(p.name) ? "_m_#{p.name}" : p.name }
    arg_idents = node.params.map { |p| MIR::Ident.new(forward_name.call(p)) }
    arg_idents = [MIR::Ident.new("rt")] + arg_idents if fn_needs_rt

    # Use the structured Type from the FunctionDef rather than parsing
    # the emitted Zig string — the latter misses `?void`,
    # `anyerror!T`, and any whitespace variants the formatter might
    # emit. Type#error_union? / Type#void? / Type#payload_type are
    # the single source of truth.
    rt_obj = node.return_type
    is_error_union = !!(rt_obj && rt_obj.error_union?)
    payload_type   = is_error_union ? rt_obj.payload_type : rt_obj
    is_void        = !!(payload_type && payload_type.respond_to?(:void?) && payload_type.void?)

    # Structured: MIR::Call(callee, args, try_wrap).
    # The `try_wrap` field forwards errors verbatim before any POST
    # predicate evaluates; on success, `result` binds the payload.
    inner_call_mir = MIR::Call.new(inner_name, arg_idents, is_error_union, call_owned_return?(node))
    call_zig = emit_expr(inner_call_mir)

    # Each predicate check decomposes into structured MIR:
    #   MIR::IfStmt(!cond, [MIR::Panic("DEBUG_POST failed: <source>")])
    # The lowered cond is the same MIR expression the annotator type-
    # checked against Bool. Only the wrapping comptime-debug-mode gate
    # remains as InlineZig — Zig's `@import("builtin").mode == .Debug`
    # has no MIR representation today (would need a new MIR node like
    # MIR::ComptimeIf or MIR::DebugBlock; see follow-up).
    check_stmts = (node.post_clauses || []).map do |entry|
      expr   = entry[:expr]
      source = entry[:source]
      cond_mir = lower(expr)
      msg_text = source && !source.empty? ? "DEBUG_POST failed: #{source}" : "DEBUG_POST failed"
      MIR::IfStmt.new(MIR::UnaryOp.new("!", cond_mir),
                      [MIR::Panic.new(msg_text)],
                      nil)
    end

    checks_zig = emit_stmts_zig(check_stmts, indent: "        ")

    debug_block = if check_stmts.empty?
      ""
    else
      <<~ZIG.rstrip
        if (@import("builtin").mode == .Debug) {
        #{checks_zig}
        }
      ZIG
    end

    body_zig = if is_void
      # Void return: no `result` to bind (visit_post_clauses! never
      # declares it for void-payload functions, so a predicate can't
      # reference it). Just call inner, run checks, return.
      <<~ZIG.rstrip
        #{call_zig};
        #{debug_block}
        return;
      ZIG
    else
      <<~ZIG.rstrip
        const result = #{call_zig};
        _ = &result;
        #{debug_block}
        return result;
      ZIG
    end

    iz = MIR::InlineZig.new(body_zig, "post_outer_body")
    iz.stdlib_def = FunctionSignature.empty_borrow_intrinsic

    MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                   [iz], vis, false, comptime_params)
  end

  # Returns [zig_string, clause_bodies] where clause_bodies is an array of
  # MIR stmt arrays (one per clause + optional default). Using lower_body
  # ensures flush_pending is called per statement so hoisted Lets stay in scope.
  sig { params(node: AST::FunctionDef, fn_can_fail: T::Boolean).returns(T::Array[T.untyped]) }
  def build_catch_clauses(node, fn_can_fail)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    rt_name = @rt_name
    clause_bodies = []

    # Build snapshot declaration if function has exactly one snapshot type
    snap_types = node.respond_to?(:snapshot_types) ? (node.snapshot_types || Set.new) : Set.new
    snapshot_decl = ""
    if snap_types.size == 1
      snap_zig = transpile_type(snap_types.first)
      snapshot_decl = "const __snap_ptr = #{rt_name}.__error.snapshotAs(#{snap_zig});\n" \
                      "            const snapshot = if (__snap_ptr) |p| p.* else undefined;\n" \
                      "            const __has_snapshot = __snap_ptr != null;\n" \
                      "            _ = &snapshot; _ = &__has_snapshot;\n            "
    end

    parts = (node.catch_clauses || []).map { |clause|
      # The annotator produces four lowering-ready fields:
      #   kinds, types, filter_types, filter_messages.
      # Match semantics:
      #   (any kind matches OR any type matches)
      #   AND
      #   (no filters OR any filter_type OR any filter_message matches)
      kinds            = clause.kinds
      types            = clause.types
      filter_types     = clause.filter_types
      filter_messages  = clause.filter_messages

      clause_mir = lower_body(clause.body)
      clause_bodies << clause_mir
      clause_body_zig = T.must(clause_mir).map { |m| emit_expr(m) }.join("\n            ")

      # Item side — kinds ORed with types.
      item_checks = []
      kinds.each { |k| item_checks << "#{rt_name}.__error.matchesKind(.#{k})" }
      types.each { |t| item_checks << "#{rt_name}.__error.matchesName(@intFromEnum(ErrorName.#{t}))" }
      item_cond = if item_checks.empty?
        "true"  # defensive; a malformed clause with no items would still short-circuit
      elsif item_checks.size == 1
        item_checks.first
      else
        "(#{item_checks.join(' or ')})"
      end

      # Filter side — types ORed with messages.
      filter_checks = []
      filter_types.each { |t| filter_checks << "#{rt_name}.__error.matchesName(@intFromEnum(ErrorName.#{t}))" }
      filter_messages.each { |m_node| filter_checks << "#{rt_name}.__error.matchesMessage(#{emit_expr(lower(m_node))})" }

      cond = if filter_checks.empty?
        item_cond
      elsif filter_checks.size == 1
        "#{item_cond} and #{filter_checks.first}"
      else
        "#{item_cond} and (#{filter_checks.join(' or ')})"
      end

      "if (#{cond}) {\n            #{snapshot_decl}const __error = #{rt_name}.__error;\n            _ = &__error;\n            defer #{rt_name}.freeSnapshot();\n            #{clause_body_zig}\n        }"
    }.join(" else ")

    default_code = if node.default_catch.is_a?(Array) && node.default_catch.any?
      # Use lower_body for the same reason as above.
      default_mir = lower_body(node.default_catch)
      clause_bodies << default_mir
      default_body = T.must(default_mir).map { |m| emit_expr(m) }.join("\n            ")
      " else {\n            const __error = #{rt_name}.__error;\n            _ = &__error;\n            defer #{rt_name}.freeSnapshot();\n            #{default_body}\n        }"
    elsif fn_can_fail
      " else {\n            #{rt_name}.freeSnapshot();\n            return error.CheatError;\n        }"
    else
      " else {\n            #{rt_name}.freeSnapshot();\n            unreachable;\n        }"
    end

    ["#{parts}#{default_code}", clause_bodies]
  end

  # Extract error-path reassignment metadata from catch clauses (INV-9).
  # Returns [{ name:, alloc:, line: }] for each reassignment to an existing
  # binding inside a catch body. Used by MIRChecker to verify allocator consistency.
  sig { params(node: AST::FunctionDef).returns(T::Array[T.untyped]) }
  def collect_catch_reassigns(node)
    T.bind(self, MIRLowering) rescue nil
    reassigns = []
    catch_bodies = []
    (node.catch_clauses || []).each { |c| catch_bodies << c.body if c.body }
    catch_bodies << node.default_catch if node.default_catch.is_a?(Array)

    catch_bodies.each do |body|
      walk_catch_body_for_reassigns(body, reassigns)
    end
    reassigns
  end

  sig { params(stmts: T::Array[T.untyped], reassigns: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def walk_catch_body_for_reassigns(stmts, reassigns)
    T.bind(self, MIRLowering) rescue nil
    return unless stmts.is_a?(Array)
    stmts.each do |stmt|
      case stmt
      when AST::BindExpr
        if stmt.mode == :assign
          alloc = infer_catch_value_allocator(stmt.value)
          reassigns << { name: stmt.name.to_s, alloc: alloc, line: stmt.token.line } if alloc
        end
      when AST::Assignment
        if stmt.name.is_a?(AST::Identifier)
          alloc = infer_catch_value_allocator(stmt.value)
          reassigns << { name: stmt.name.name.to_s, alloc: alloc, line: stmt.token.line } if alloc
        end
      when AST::IfStatement
        walk_catch_body_for_reassigns(stmt.then_branch, reassigns)
        walk_catch_body_for_reassigns(stmt.else_branch, reassigns)
      when AST::MatchStatement
        stmt.cases.each { |c| walk_catch_body_for_reassigns(c.body, reassigns) }
        walk_catch_body_for_reassigns(stmt.default_case, reassigns)
      end
    end
  end

  sig { params(expr: T.untyped).returns(T.nilable(Symbol)) }
  def infer_catch_value_allocator(expr)
    T.bind(self, MIRLowering) rescue nil
    return nil unless expr
    return :heap if expr.respond_to?(:symbol) && expr.symbol&.heap_storage? == true
    storage = expr.respond_to?(:storage) ? expr.storage : nil
    return :heap if SymbolEntry.heap_storage_value?(storage)
    return :frame if SymbolEntry.frame_storage_value?(storage)
    nil
  end

  # ================================================================
  # Function / method calls
  # ================================================================

  # Apply the calling-convention rule to one argument.
  #
  # ONE place decides how an arg crosses a fn boundary:
  #  - Slice-typed callee receiving an ArrayList: extract .items
  #  - Callee expects *T (mutable param, needs_pointer_passing,
  #    universal-poly auto-borrow): AddressOf, unless the arg is an
  #    identifier already pointer-shaped (collection param or BG capture)
  #  - Otherwise: pass through unchanged
  #
  # callee_param is nilable only because intrinsic/extern call paths can
  # arrive without a signature; the helper degrades to "pass as-is".
  sig do
    params(arg: T.untyped, a: T.untyped,
           callee_param: T.nilable(AST::Param),
           callee_param_type: Type,
           callee_sig: T.untyped, idx: Integer).returns(T.untyped)
  end
  def cross_boundary_arg(arg, a, callee_param, callee_param_type, callee_sig, idx)
    T.bind(self, MIRLowering) rescue nil
    ti = a.full_type
    ti = Type.from_node(a) unless ti.is_a?(Type)

    moved_arg = a.is_a?(AST::MoveNode) ||
                (a.respond_to?(:was_moved) && a.was_moved == true &&
                 !a.is_a?(AST::CopyNode) && !a.is_a?(AST::CloneNode) &&
                 !arg.is_a?(MIR::DupeSlice) && !arg.is_a?(MIR::DeepCopy))
    if callee_param&.takes && moved_arg &&
       ti.is_a?(Type) && ti.direct_indexable_collection? && !callee_param_type.collection?
      sink_alloc = allocator_for_takes_param!(callee_param)
      return MIR::OwnedSlice.new(arg, sink_alloc)
    end

    if callee_param&.takes
      sink_alloc = allocator_for_takes_param!(callee_param)
      placed = materialize_owned_sink_value(arg, a, sink_alloc, callee_param_type)
      arg = hoist_alloc(placed, a, err_cleanup: true)
    end

    if ti.is_a?(Type) && ti.non_string_array? && !ti.pool? &&
       !a.is_a?(AST::CopyNode) && !a.is_a?(AST::MoveNode) &&
       !callee_param_type.collection?
      return MIR::ItemsAccess.new(arg, true)
    end

    return arg unless wants_ptr?(a, ti, callee_param, callee_param_type, callee_sig, idx)
    return arg if arg_already_pointer_shaped?(a)
    MIR::AddressOf.new(arg)
  end

  sig { params(sig: T.nilable(FunctionSignature), ast_args: T::Array[T.untyped]).returns(T.nilable(MIR::CallableContract)) }
  def callable_contract_for(sig, ast_args)
    T.bind(self, MIRLowering) rescue nil
    return nil unless sig

    facts = call_ownership_facts_for_signature(sig, ast_args)
    MIR::CallableContract.new(sig, facts.ownership_contract, ast_args.length)
  end

  sig { params(ast_arg: T.untyped, callee_sig: T.nilable(FunctionSignature), param_index: Integer).returns(CallArgFacts) }
  def call_arg_facts(ast_arg, callee_sig, param_index)
    T.bind(self, MIRLowering) rescue nil
    ti = Type.from_node!(ast_arg, context: "call argument")
    callee_param = callee_sig ? callee_sig.params[param_index] : nil
    takes = call_arg_consumes_ownership?(ast_arg, callee_param)
    callee_param_type = (callee_param && callee_param.type) || Type.new(:Any)
    copy_to_owning = (ast_arg.is_a?(AST::CopyNode) &&
                      callee_param_type.collection? &&
                      ti.collection_value?) == true
    CallArgFacts.new(
      ast_arg: ast_arg,
      type_info: ti,
      callee_sig: callee_sig,
      callee_param: callee_param,
      callee_param_type: callee_param_type,
      takes: takes,
      copy_to_owning: copy_to_owning,
      arg_alloc: takes ? allocator_for_takes_param!(callee_param) : :heap,
      param_index: param_index,
    )
  end

  sig { params(sig: FunctionSignature, ast_args: T::Array[T.untyped]).returns(CallOwnershipFacts) }
  def call_ownership_facts_for_signature(sig, ast_args)
    T.bind(self, MIRLowering) rescue nil
    takes_indices = T.let(Set.new, T::Set[Integer])
    consumed = T.let([], T::Array[String])
    ast_args.each_with_index do |arg, idx|
      callee_param = sig.params[idx]
      next unless call_arg_consumes_ownership?(arg, callee_param)
      takes_indices << idx
      next unless ownership_tracked_transfer_type?(Type.from_node!(arg, context: "call ownership argument"))
      root = moved_arg_root(arg)
      next unless root
      entry = @current_bindings[root] || CleanupEntry::NONE
      next unless entry.present?
      consumed << transfer_binding_name(root)
    end
    CallOwnershipFacts.new(takes_indices: takes_indices, consumed_names: consumed.uniq)
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).returns(StdlibCallFacts) }
  def stdlib_call_facts(node)
    sig = FunctionSignature.unwrap(node.matched_stdlib_def) if node.respond_to?(:matched_stdlib_def) && node.matched_stdlib_def
    return empty_stdlib_call_facts unless sig

    ast_args = node.is_a?(AST::MethodCall) ? [node.object] + node.args : node.args
    if sig.arg_spec && sig.params.length != ast_args.length
      Kernel.raise "stdlib call #{node.name}: signature has #{sig.params.length} params for #{ast_args.length} args"
    end
    ownership = call_ownership_facts_for_signature(sig, ast_args)
    facts = T.let([], T::Array[StdlibCallArgFact])
    ast_args.each_with_index do |ast_arg, index|
      param = sig.params[index]
      next unless param
      facts << StdlibCallArgFact.new(
        index: index,
        ast_arg: ast_arg,
        takes: ownership.takes?(index),
        coerce_type: stdlib_coerce_type(param.type),
      )
    end
    StdlibCallFacts.new(args: facts, ownership: ownership)
  end

  sig { returns(StdlibCallFacts) }
  def empty_stdlib_call_facts
    StdlibCallFacts.new(
      args: [],
      ownership: CallOwnershipFacts.new(takes_indices: Set.new, consumed_names: []),
    )
  end

  sig { params(type_info: T.untyped).returns(T.nilable(Symbol)) }
  def stdlib_coerce_type(type_info)
    ti = Type.from_node(type_info)
    return nil unless ti

    resolved = ti.resolved
    resolved.is_a?(Symbol) ? resolved : nil
  end

  sig { params(facts: CallArgFacts).returns(T.untyped) }
  def lower_call_arg_from_facts(facts)
    T.bind(self, MIRLowering) rescue nil
    raw_arg = with_decl_alloc(facts.arg_alloc) do
      if facts.copy_to_owning
        MIR::DeepCopy.new(lower(facts.ast_arg.value), nil, nil, :full_value, :heap)
      else
        lower(facts.ast_arg)
      end
    end
    arg = hoist_alloc(raw_arg, facts.ast_arg, err_cleanup: facts.takes, mutable: facts.copy_to_owning)
    cross_boundary_arg(
      arg,
      facts.ast_arg,
      facts.callee_param,
      facts.callee_param_type,
      facts.callee_sig,
      facts.param_index,
    )
  end

  sig do
    params(
      node: T.untyped,
      callee: String,
      args: T::Array[T.untyped],
      can_fail: T::Boolean,
      owned_return: T::Boolean,
      contract: T.nilable(MIR::CallableContract),
    ).returns(T.untyped)
  end
  def finalize_call_result(node, callee, args, can_fail, owned_return, contract)
    call = MIR::Call.new(callee, args, can_fail, owned_return, contract)
    return call unless node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
    return call if owned_return

    MIR::DupeSlice.new(call, :heap)
  end

  sig do
    params(a: T.untyped, ti: T.untyped,
           callee_param: T.nilable(AST::Param),
           callee_param_type: Type,
           callee_sig: T.untyped, idx: Integer).returns(T::Boolean)
  end
  private def wants_ptr?(a, ti, callee_param, callee_param_type, callee_sig, idx)
    T.bind(self, MIRLowering) rescue nil
    mutable_callee     = !callee_param.nil? && !!callee_param.mutable
    wants_ptr_mut_list  = mutable_callee &&
                          callee_param.type.respond_to?(:list_collection?) &&
                          callee_param.type.list_collection?
    wants_ptr_mut_value = mutable_callee &&
                          a.is_a?(AST::Identifier) &&
                          !wants_ptr_mut_list &&
                          !callee_param_type.needs_pointer_passing?
    wants_ptr_intrinsic = ti.is_a?(Type) && Type.new(ti).needs_pointer_passing?
    wants_ptr_poly      = T.unsafe(self).universal_poly_arg_needs_addr?(a, callee_sig, idx)
    !!(wants_ptr_mut_list || wants_ptr_mut_value || wants_ptr_intrinsic || wants_ptr_poly)
  end

  sig { params(a: T.untyped).returns(T::Boolean) }
  private def arg_already_pointer_shaped?(a)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @current_bg_pointer_captures = T.let(@current_bg_pointer_captures, T.untyped)
    @current_fn_collection_params = T.let(@current_fn_collection_params, T.untyped)
    return false unless a.is_a?(AST::Identifier)
    !!(@current_fn_collection_params&.include?(a.name) ||
       @current_bg_pointer_captures&.include?(a.name))
  end

  sig { params(node: AST::FuncCall).returns(T.untyped) }
  def lower_func_call(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @fn_sigs = T.let(@fn_sigs, T.untyped)
    @rt_name = T.let(@rt_name, T.untyped)
    if (intercept = stub_intercept_for(node.name, nil, node.args))
      return intercept
    end

    # Intrinsic pattern: already resolved by annotator
    return lower_intrinsic(node) if node.zig_pattern

    # Extern FFI call
    if node.respond_to?(:extern_call) && node.extern_call
      return lower_extern_call(node)
    end

    # Standard call
    callee_sig = @fn_sigs&.dig(node.name) || @fn_sigs&.dig(node.name.to_s) ||
                 @fn_sigs&.dig("#{node.name}!")
    args_mir = node.args.each_with_index.map do |a, idx|
      lower_call_arg_from_facts(call_arg_facts(a, callee_sig, idx))
    end

    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    mod_prefix = mod_alias ? "#{mod_alias.gsub('.', '_')}." : ""

    if node.respond_to?(:fn_var_call) && node.fn_var_call
      # fn-type variable call
      all_args = [MIR::Ident.new(@rt_name)] + args_mir
      contract = callable_contract_for(FunctionSignature.unwrap(node.matched_signature), node.args)
      return MIR::Call.new("try #{node.name}", all_args, false, call_owned_return?(node), contract)
    end

    # Resolve rt/fail from fn_sigs
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)

    # Generic type args
    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(generic_type_arg_zig(t)) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(@rt_name)] : []
    all_args = type_args + rt_args + args_mir
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    owned_return = call_owned_return?(node)

    finalize_call_result(node, fn_zig, all_args, can_fail, owned_return, callable_contract_for(callee_sig, node.args))
  end

  sig { params(node: AST::MethodCall).returns(T.untyped) }
  def lower_method_call(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @fn_sigs = T.let(@fn_sigs, T.untyped)
    # Stub interception: a UFCS call `x.query(args)` lowers to `query(x, args)`,
    # so STUB query intercepts must apply here too.
    if (intercept = stub_intercept_for(node.name, node.object, node.args))
      return intercept
    end

    # Intrinsic pattern: already resolved by annotator
    if node.zig_pattern
      return lower_safe_nav_method_call(node) if node.object.is_a?(AST::OptionalUnwrap)
      return lower_intrinsic(node)
    end

    # Extern method dispatch
    if node.instance_variable_get(:@extern_method)
      return lower_extern_method(node)
    end

    # Standard UFCS call: method(object, args...)
    obj_mir = lower(node.object)
    callee_sig = @fn_sigs&.dig(node.name) || @fn_sigs&.dig(node.name.to_s)
    args_mir = node.args.each_with_index.map do |a, idx|
      lower_call_arg_from_facts(call_arg_facts(a, callee_sig, idx + 1))
    end

    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    mod_prefix = mod_alias ? "#{mod_alias.gsub('.', '_')}." : ""
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)

    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(generic_type_arg_zig(t)) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(@rt_name)] : []
    all_args = type_args + rt_args + [obj_mir] + args_mir
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    owned_return = call_owned_return?(node)

    finalize_call_result(node, fn_zig, all_args, can_fail, owned_return, callable_contract_for(callee_sig, [node.object] + node.args))
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def call_owned_return?(node)
    T.bind(self, MIRLowering) rescue nil
    sig = @fn_sigs&.dig(node.name) || @fn_sigs&.dig(node.name.to_s) if node.respond_to?(:name)
    sig ||= FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    return false if sig && sig.respond_to?(:return_lifetime) && !sig.return_lifetime.empty?
    dep = call_owned_return_from_args?(node, sig)
    return dep unless dep.nil?
    ti = sig&.return_type || Type.from_node(node)
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    return false unless ti
    ti = ti.payload_type if ti.error_union?
    return false unless ti
    if ti.string?
      return false if ti.symbol? || ti.raw?
      return true if sig&.heap_carry_return == true
      return true if sig&.heap_return_alloc?
      return false if sig
      return ti.heap?
    end
    schema_lookup = T.unsafe(self).instance_variable_get(:@schema_lookup)
    ti.indirect? || ti.collection? || ti.any_rc? || ti.any_sync? ||
      ti.resource? || ti.recursive_cleanup_shape?(schema_lookup)
  end

  sig { params(node: T.untyped, sig_obj: T.untyped).returns(T.nilable(T::Boolean)) }
  def call_owned_return_from_args?(node, sig_obj)
    return nil unless sig_obj && sig_obj.respond_to?(:heap_carry_return_vars)
    return nil unless sig_obj.heap_carry_return_vars && !sig_obj.heap_carry_return_vars.empty?
    by_name = T.let({}, T::Hash[String, Integer])
    sig_obj.params.each_with_index { |param, idx| by_name[param.name.to_s] = idx }
    has_param_return = T.let(false, T::Boolean)
    sig_obj.heap_carry_return_vars.each do |name|
      idx = by_name[name.to_s]
      unless idx
        return true
      end
      has_param_return = true
      arg = node.args[idx]
      return true if ast_expr_produces_heap?(arg)
    end
    if has_param_return
      ret = T.let(sig_obj.respond_to?(:return_type) ? sig_obj.return_type : nil, T.untyped)
      ret = Type.new(ret) if ret && !ret.is_a?(Type)
      return false unless ret.is_a?(Type)
      ret = ret.payload_type if ret&.error_union?
      schema_lookup = T.unsafe(self).instance_variable_get(:@schema_lookup)
      return true if ret&.string? || ret&.recursive_cleanup_shape?(schema_lookup)
      return false
    end
    nil
  end

  sig { params(expr: T.untyped).returns(T::Boolean) }
  def ast_expr_produces_heap?(expr)
    node = expr
    node = node.value if node.is_a?(AST::MoveNode)
    node = node.left if node.is_a?(AST::BinaryOp) && node.op == :OR_RESCUE
    return false if node.respond_to?(:storage) && [:rodata, :borrow].include?(node.storage)
    return false if node.respond_to?(:rodata_provenance?) && node.rodata_provenance?
    return false if node.respond_to?(:borrow_provenance?) && node.borrow_provenance?
    return true if node.respond_to?(:heap_storage?) && node.heap_storage?
    return true if node.respond_to?(:symbol) && node.symbol&.heap_storage?
    return true if node.is_a?(AST::StringConcat)
    return true if node.is_a?(AST::BinaryOp) && node.op == :ADD && node.string_concat
    ti = Type.from_node(node)
    return false unless ti
    schema_lookup = T.unsafe(self).instance_variable_get(:@schema_lookup)
    ti.heap_ptr? || ti.recursive_cleanup_shape?(schema_lookup)
  end

  # Safe navigation for method calls: expr?.method(args)
  # Wraps the call in (if (expr) |_snav_N| call_with_N_as_receiver else null).
  sig { params(node: T.untyped).returns(MIR::IfOptional) }
  def lower_safe_nav_method_call(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @safe_nav_counter = T.let(@safe_nav_counter, T.untyped)
    @safe_nav_counter = (@safe_nav_counter || 0) + 1
    snav_var = "_snav_#{@safe_nav_counter}"

    inner_mir = lower(node.object.target)

    snav_ident = AST::Identifier.new(node.object.token, snav_var)
    snav_ident.full_type = node.object.full_type  # T (unwrapped)

    synthetic = node.dup
    synthetic.object = snav_ident

    call_mir  = lower_intrinsic(synthetic)

    MIR::IfOptional.new(inner_mir, snav_var, call_mir, MIR::Lit.new("null"))
  end

  sig { params(node: T.untyped).returns(T.untyped) }
  def lower_intrinsic(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @target = T.let(@target, T.untyped)
    # Symbol-based intrinsics are complex special builtins
    if node.zig_pattern.is_a?(Symbol)
      case node.zig_pattern
      when :macro_print
        return lower_macro_print(node)
      when :macro_map
        raise "BUG: macro_map should have been rewritten by PipelineRewriter"
      else
        raise "MIRLowering: unhandled symbol intrinsic: #{node.zig_pattern}"
      end
    end

    # Template-based intrinsics: resolve destination allocator before lowering
    # TAKES args. COPY inside append/put/etc. must be constructed in the
    # receiver/container allocator so cleanup remains one-allocator-per-owner.
    pattern = node.zig_pattern.dup
    pre_resolved_alloc = nil
    if pattern.include?("{alloc}")
      alloc_sym = node.matched_stdlib_def&.emit&.alloc || :node_storage
      pre_resolved_alloc = resolve_alloc_sym(alloc_sym, nil, node)
    end
    stdlib_facts = stdlib_call_facts(node)
    ownership_facts = stdlib_facts.ownership

    # Template-based intrinsics: lower args to MIR, apply ownership transforms, emit
    mir_args = if node.is_a?(AST::MethodCall)
      obj_mir = lower(node.object)
      # Auto-deref Arc/Rc-wrapped receivers: obj.ctrl.data.*
      # Zig only -- BC has no Arc-wrapping. Without the gate, methods on
      # shared collections (e.g. map.contains?, map.count) get rewritten
      # to operate on `Deref(map.ctrl.data)`, which the bc_emitter doesn't
      # resolve to the underlying MapRef.
      obj_ti = node.object.full_type
      if (obj_ti&.shared? || obj_ti&.multiowned?) && @target != :bc
        obj_mir = MIR::Deref.new(MIR::FieldGet.new(MIR::FieldGet.new(obj_mir, "ctrl"), "data"))
      elsif obj_ti&.frozen?
        # *const T auto-derefs for method calls in Zig — no _root deref needed
      end
      lowered_args = node.args.each_with_index.map do |a, ai|
        takes = ownership_facts.takes?(ai + 1)
        takes && pre_resolved_alloc ? with_decl_alloc(pre_resolved_alloc) { lower(a) } : lower(a)
      end
      [obj_mir] + lowered_args
    else
      node.args.each_with_index.map do |a, ai|
        takes = ownership_facts.takes?(ai)
        takes && pre_resolved_alloc ? with_decl_alloc(pre_resolved_alloc) { lower(a) } : lower(a)
      end
    end

    # Hot-path collection lengths should lower to direct `.len` / `.items.len`
    # instead of going through CheatLib.len, which adds avoidable call overhead
    # in tight loops. Streams are not handled here; they stay on NEXT-based paths.
    if node.zig_pattern == "CheatLib.len({0})"
      len_expr = lower_direct_length(node)
      return len_expr if len_expr
    end

    # Target :bc with a bc-opted-in stdlib_def: emit MIR::InlineBc carrying the
    # method/function name + unlowered MIR args. bc_emitter dispatches via
    # compile_inline_bc. Done before Zig-specific pattern rewrites below.
    # When the entry has an explicit :bc_op, prefer it over the AST name so
    # the BC dispatch key is decoupled from CLEAR's surface naming
    # (e.g. fileReadAll -> :file_read_all).
    if @target == :bc && node.matched_stdlib_def&.emit&.bc
      op_name = node.matched_stdlib_def.emit&.bc_op || node.name.to_s.to_sym
      return MIR::InlineBc.new(op_name, mir_args, node.matched_stdlib_def)
    end

    # Resolve {alloc} to a symbol. The {alloc} PLACEHOLDER stays in the
    # pattern -- the emitter substitutes it.
    #
    # Stdlib TAKES metadata feeds the same owned-sink materialization used by
    # indexed/container stores. The stdlib registry decides whether ownership
    # transfers; this code only ensures a borrowed/rodata value becomes owned
    # in the allocator selected for that sink.
    resolved_allocs = {}
    if pattern.include?("{alloc}")
      resolved = pre_resolved_alloc || :heap
      resolved_allocs[:alloc] = resolved
    end

    if stdlib_facts.args.any?
      sink_alloc = resolved_allocs[:alloc] || pre_resolved_alloc || :heap
      stdlib_facts.args.each do |arg_fact|
        i = arg_fact.index
        next unless ownership_facts.takes?(i)
        mir_args[i] = materialize_owned_sink_value(mir_args[i], arg_fact.ast_arg, sink_alloc)
      end
    end

    # Intrinsic templates inline their arguments directly into Zig. Heap-owning
    # argument expressions still need the same hoist/cleanup treatment as normal
    # calls: borrowed sinks clean them after the call, TAKES sinks clean only on
    # error because ownership transfers on success.
    if stdlib_facts.args.any?
      mir_args = mir_args.each_with_index.map do |arg_mir, i|
        hoist_alloc(arg_mir, stdlib_facts.ast_arg(i), err_cleanup: ownership_facts.takes?(i))
      end
    end
    consumed_names = ownership_facts.consumed_names.dup
    if ownership_facts.takes_any?
      @pending_stmts = T.let(@pending_stmts, T.untyped)
      mir_args.each_with_index do |arg_mir, i|
        next unless ownership_facts.takes?(i)
        arg_mir = mir_args[i]
        if arg_mir.is_a?(MIR::Ident)
          if @guarded_cleanup_names&.[](arg_mir.name.to_s)
            consumed_names << arg_mir.name
          end
        else
          mir_ident_names(arg_mir).each do |name|
            consumed_names << name if @guarded_cleanup_names&.[](name.to_s)
          end
        end
      end
      consumed_names.uniq!
      if !consumed_names.empty? && resolved_allocs[:val_alloc].nil?
        consumed_alloc = consumed_names.filter_map do |name|
          mark = @pending_stmts.reverse.find { |stmt| stmt.is_a?(MIR::AllocMark) && stmt.name.to_s == name.to_s }
          mark&.alloc
        end.uniq
        resolved_allocs[:val_alloc] = consumed_alloc.first if consumed_alloc.length == 1
      end
    end

    # Emit all args to Zig strings
    args_zig = mir_args.map { |a| emit_expr(a) }

    # Coerce each arg to its declared type at the boundary. This makes the
    # template rely on typed args instead of hoping Zig figures out a
    # comptime_int / unknown-typed RHS. Bug 256 (`sleep(1)` -> `@bitCast(1)`
    # rejected because comptime_int has no bit width) is the canonical
    # example: with `@as(i64, 1)` wrapping the literal at the boundary,
    # the existing `@bitCast` in the template just works.
    #
    # Coercion is a no-op when the arg is already the declared type, so
    # non-literal args pay nothing. We skip it for `:Any` (anytype) and
    # for arg specs without a concrete declared type (Hash forms whose
    # `:type` is missing or :Any).
    if stdlib_facts.args.any?
      args_zig = args_zig.each_with_index.map do |arg_zig, i|
        stdlib_facts.coerce_zig(arg_zig, i)
      end
    end

    # Resolve {rt} to the in-scope runtime variable. Inside a BG / DO /
    # CONCURRENT body the runtime is renamed (e.g. `__rt_bg0`) and the
    # template's literal `rt` would refer to a different scope's binding
    # that Zig rejects with "'rt' not accessible from inner function".
    pattern = pattern.gsub("{rt}", @rt_name) if pattern.include?("{rt}")

    # Resolve {key_zig} and {val_zig} from receiver type (numeric/sharded maps)
    if pattern.include?("{key_zig}") || pattern.include?("{val_zig}")
      obj_ti = node.is_a?(AST::MethodCall) ? node.object.full_type : nil
      map_ft = obj_ti ? Type.new(obj_ti) : nil
      pattern = pattern.gsub("{key_zig}", map_ft&.key_type&.zig_type || "i64")
      pattern = pattern.gsub("{val_zig}", map_ft&.value_type&.zig_type || "f64")
    end

    # Resolve &{N} as address-of for positional args
    args_zig.each_with_index { |val, i| pattern = pattern.gsub("&{#{i}}") { "&#{val}" } }

    # Substitute positional args
    args_zig.each_with_index { |val, i| pattern = pattern.gsub("{#{i}}") { val } }

    iz = MIR::InlineZig.new(pattern, "intrinsic")
    # zig_pattern was set by the annotator together with matched_stdlib_def
    # (src/annotator.rb). Both are always present together.
    iz.stdlib_def = node.matched_stdlib_def
    iz.allocs = resolved_allocs unless resolved_allocs.empty?
    if ownership_facts.takes_any?
      iz.ownership_contract = MIR::OwnershipContract.consumes(consumed_names)
    end
    # Store target variable name for checker cross-reference with AllocMark.
    # Use extract_root_var_name so renamed variables (same-name collision fix)
    # get the correct disambiguated Zig name.
    if node.is_a?(AST::MethodCall) && node.object.respond_to?(:name)
      iz.target_var = extract_root_var_name(node.object)
    elsif node.mutates_receiver && node.args&.first&.respond_to?(:name)
      iz.target_var = extract_root_var_name(node.args.first)  # UFCS: first arg is receiver
    end
    iz
  end

  sig { params(node: AST::FuncCall).returns(T.untyped) }
  def lower_extern_call(node)
    T.bind(self, MIRLowering) rescue nil
    return lower_extern_direct_call(node) if node.respond_to?(:extern_effects) && node.extern_effects&.dig(:safe)
    build_extern_trampoline_call(node)
  end

  sig { params(node: AST::MethodCall).returns(T.any(MIR::InlineZig, MIR::MethodCall)) }
  def lower_extern_method(node)
    T.bind(self, MIRLowering) rescue nil
    return lower_extern_direct_method(node) if node.respond_to?(:extern_effects) && node.extern_effects&.dig(:safe)
    build_extern_trampoline_method(node)
  end

  sig { params(node: AST::FuncCall).returns(MIR::Call) }
  def lower_extern_direct_call(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @rt_name = T.let(@rt_name, T.untyped)
    args = node.args.map { |a| lower(a) }
    if node.respond_to?(:extern_effects) && (alloc_kind = node.extern_effects&.dig(:alloc))
      rt = MIR::Ident.new(@rt_name)
      alloc_call = alloc_kind == :heap \
        ? MIR::MethodCall.new(rt, "heapAlloc",  [], false, MIR::CallableContract.no_ownership(0)) \
        : MIR::MethodCall.new(rt, "frameAlloc", [], false, MIR::CallableContract.no_ownership(0))
      n_comptime = node.args.count { |a| a.full_type == :Type }
      args = T.must(args[0, n_comptime]) + [alloc_call] + T.must(args[n_comptime..])
    end
    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    mod_prefix = mod_alias ? "#{mod_alias.gsub('.', '_')}." : ""
    sig = FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    MIR::Call.new("#{mod_prefix}#{node.name}", args, false, false, callable_contract_for(sig, node.args))
  end

  sig { params(node: AST::MethodCall).returns(MIR::MethodCall) }
  def lower_extern_direct_method(node)
    T.bind(self, MIRLowering) rescue nil
    obj = lower(node.object)
    args = node.args.map { |a| lower(a) }
    sig = FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    MIR::MethodCall.new(obj, node.name.to_s, args, false, callable_contract_for(sig, [node.object] + node.args))
  end

  # Lower an extern trampoline argument, stripping the Byte[N]→String coercion
  # (@as([]const u8, "lit")) so string literals keep their native Zig type
  # *const [N:0]u8, which coerces to both []const u8 AND [*:0]const u8.
  # Without this, string literals passed to C-string params would fail with
  # "expected [*:0]const u8, found []const u8".
  sig { params(ast_arg: T.untyped).returns(T.untyped) }
  def lower_extern_arg(ast_arg)
    T.bind(self, MIRLowering) rescue nil
    mir = lower(ast_arg)
    if mir.is_a?(MIR::Cast) && mir.method == :as && mir.target_type == "[]const u8" && mir.expr.is_a?(MIR::Lit)
      mir.expr
    else
      mir
    end
  end

  sig { params(node: AST::FuncCall).returns(MIR::InlineZig) }
  def build_extern_trampoline_call(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @extern_counter = T.let(@extern_counter, T.untyped)
    @fn_sigs = T.let(@fn_sigs, T.untyped)
    @extern_counter = (@extern_counter || 0) + 1
    id = @extern_counter
    alloc_kind = node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil
    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    mod_prefix = mod_alias ? "#{mod_alias.gsub('.', '_')}." : ""
    fn_zig = "#{mod_prefix}#{node.name}"

    # Separate comptime type args (full_type == :Type) from runtime args.
    # Comptime args can't be struct fields (Zig type is `type`, comptime-only).
    # They are baked directly into the call_zig string.
    comptime_args, runtime_ast_args = node.args.partition { |a| a.full_type == :Type }
    comptime_codes = comptime_args.map { |a| emit_expr(lower_extern_arg(a)) }

    args = runtime_ast_args.map { |a| lower_extern_arg(a) }
    arg_codes = args.map { |a| emit_expr(a) }
    arg_tuple = arg_codes.empty? ? ".{}" : ".{ #{arg_codes.join(', ')} }"

    # Use declared param types for struct fields to avoid comptime_int (e.g. @TypeOf(19876)).
    # Skip extern/module functions: their CLEAR types (e.g. String -> []const u8) may differ
    # from the actual Zig/C types (e.g. [*:0]const u8), breaking implicit coercions.
    sig = @fn_sigs&.dig(node.name) || @fn_sigs&.dig(node.name.to_sym) || @fn_sigs&.dig(node.name.to_s)
    sig_params = (sig&.params || sig&.dig(:params) || []).reject { |p| p.comptime }
    arg_field_types = if sig&.module_alias
      nil
    else
      types = sig_params.each_with_index.map do |p, i|
        next nil unless i < runtime_ast_args.length
        pt = p.type
        pt.is_a?(Type) ? pt.zig_type(is_param: true) : (Type::ZIG_TYPE_MAP[pt] || nil)
      end
      types.empty? || types.all?(&:nil?) ? nil : types
    end

    call_parts = comptime_codes + (alloc_kind ? ["_alloc_"] : []) + arg_codes.each_index.map { |i| "f.a#{i}" }
    call_zig = "#{fn_zig}(#{call_parts.map { |p| p == "_alloc_" ? "f.alloc" : p }.join(', ')})"

    build_extern_trampoline_common(
      id: id,
      prefix: "__Ext",
      args_tuple_name: "__ext#{id}_args",
      frame_name: "__ext#{id}_frame",
      arg_codes: arg_codes,
      arg_field_types: arg_field_types,
      arg_tuple: arg_tuple,
      alloc_kind: alloc_kind,
      return_type: node.full_type,
      call_zig: call_zig,
      receiver_field: nil,
      ast_node: node
    )
  end

  sig { params(node: AST::MethodCall).returns(MIR::InlineZig) }
  def build_extern_trampoline_method(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @extern_counter = T.let(@extern_counter, T.untyped)
    @extern_counter = (@extern_counter || 0) + 1
    id = @extern_counter
    obj = lower(node.object)
    args = node.args.map { |a| lower_extern_arg(a) }
    arg_codes = args.map { |a| emit_expr(a) }
    arg_tuple = arg_codes.empty? ? ".{}" : ".{ #{arg_codes.join(', ')} }"
    receiver_code = emit_expr(obj)
    build_extern_trampoline_common(
      id: id,
      prefix: "__ExtM",
      args_tuple_name: "__extm#{id}_args",
      frame_name: "__extm#{id}_frame",
      arg_codes: arg_codes,
      arg_field_types: nil,
      arg_tuple: arg_tuple,
      alloc_kind: node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil,
      return_type: node.full_type,
      call_zig: "f.self_val.#{node.name}(#{extern_call_args_zig(arg_codes.length, node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil)})",
      receiver_field: receiver_code,
      ast_node: node
    )
  end

  sig { params(argc: Integer, alloc_kind: NilClass).returns(String) }
  def extern_call_args_zig(argc, alloc_kind)
    T.bind(self, MIRLowering) rescue nil
    parts = []
    parts << "f.alloc" if alloc_kind
    argc.times { |i| parts << "f.a#{i}" }
    parts.join(", ")
  end

  sig { params(id: Integer, prefix: String, args_tuple_name: String, frame_name: String, arg_codes: T::Array[T.untyped], arg_field_types: NilClass, arg_tuple: String, alloc_kind: T.nilable(Symbol), return_type: Type, call_zig: String, receiver_field: T.nilable(String), ast_node: T.untyped).returns(MIR::InlineZig) }
  def build_extern_trampoline_common(id:, prefix:, args_tuple_name:, frame_name:, arg_codes:, arg_field_types:, arg_tuple:, alloc_kind:, return_type:, call_zig:, receiver_field:, ast_node: nil)
    T.bind(self, MIRLowering) rescue nil
    ret_t = return_type
    can_fail = ret_t.error_union?
    payload_t = can_fail ? ret_t.payload_type : ret_t
    returns_void = payload_t.void?

    fields = []
    fields << "self_val: @TypeOf(#{receiver_field})" if receiver_field
    fields << "alloc: std.mem.Allocator" if alloc_kind
    arg_codes.each_index do |i|
      field_type = arg_field_types&.[](i)
      fields << "a#{i}: #{field_type || "@TypeOf(#{args_tuple_name}[#{i}])"}"
    end
    fields << "err: ?anyerror = null" if can_fail
    fields << "ret: #{payload_t.zig_type} = undefined" unless returns_void

    call_stmt = if can_fail
      if returns_void
        "#{call_zig} catch |err| { f.err = err; return; };"
      else
        "f.ret = (#{call_zig} catch |err| { f.err = err; return; });"
      end
    else
      returns_void ? "#{call_zig};" : "f.ret = #{call_zig};"
    end

    init_fields = []
    init_fields << ".self_val = #{receiver_field}" if receiver_field
    arg_codes.each_index { |i| init_fields << ".a#{i} = #{args_tuple_name}[#{i}]" }
    if alloc_kind
      alloc_expr = alloc_kind == :heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
      init_fields << ".alloc = #{alloc_expr}"
    end

    # f is referenced in call_stmt only when the struct has data fields.
    f_needed = receiver_field || alloc_kind || arg_codes.any? || !returns_void || can_fail
    f_binding = f_needed ? "const f: *@This() = @ptrCast(@alignCast(ptr));" : "_ = ptr;"

    code = +""
    if returns_void
      code << "{ "
    else
      code << "blk_ext#{id}: { "
    end
    # Only emit the args tuple when there are arguments that reference it.
    code << "const #{args_tuple_name} = #{arg_tuple}; " if arg_codes.any?
    field_decls = fields.empty? ? "" : "#{fields.join(', ')}, "
    code << "const #{prefix}#{id} = struct { #{field_decls}fn run(ptr: ?*anyopaque) callconv(.c) void { #{f_binding} #{call_stmt} } }; "
    code << "var #{frame_name} = #{prefix}#{id}{ #{init_fields.join(', ')} }; "
    code << "#{@rt_name}.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &#{prefix}#{id}.run), @ptrCast(&#{frame_name})); "
    code << "if (#{frame_name}.err) |e| return e; " if can_fail
    code << "break :blk_ext#{id} #{frame_name}.ret; " unless returns_void
    code << "}"

    iz = MIR::InlineZig.new(code, "extern_trampoline")
    pt = payload_t.is_a?(Type) ? payload_t : (Type.new(payload_t) rescue nil)
    is_heap = (ast_node.respond_to?(:symbol) && ast_node.symbol&.heap_storage? == true) || !!pt&.heap?
    iz.stdlib_def = is_heap ? FunctionSignature.allocating_intrinsic : FunctionSignature.borrowing_intrinsic
    iz
  end


  # ================================================================
  # Lambda
  # ================================================================

  sig { params(node: AST::LambdaLit).returns(MIR::LambdaExpr) }
  def lower_lambda(node)
    T.bind(self, MIRLowering) rescue nil
    # mir-lowering strict ivars
    @lambda_counter = T.let(@lambda_counter, T.untyped)
    sig = node.full_type
    sig = sig.raw if sig.is_a?(Type)
    @lambda_counter = (@lambda_counter || 0) + 1
    fn_name = "_lambda_#{@lambda_counter}"

    params_list = sig.params
    params_mir = T.let([MIR::Param.new("_rt", "*Runtime", false)] + params_list.map { |p|
      p_type = p.type
      type_str = p_type.is_a?(Type) ? p_type.zig_type(is_param: true) : transpile_type(p_type || :Any, is_param: true)
      pt_obj = p_type.is_a?(Type) ? p_type : (Type.new(p_type) rescue nil)
      pp = !!(pt_obj && (pt_obj.respond_to?(:needs_pointer_passing?) && pt_obj.needs_pointer_passing? ||
                         (p.mutable && pt_obj.respond_to?(:list_collection?) && pt_obj.list_collection?)))
      MIR::Param.new(p.name, type_str, pp)
    }, T::Array[MIR::Param])

    ret_zig = sig.return_type.zig_type
    ret_str = if ret_zig.start_with?("!") || ret_zig.include?("anyerror!") || ret_zig.include?("error{")
                ret_zig
              else
                "anyerror!#{ret_zig}"
              end

    # Build body: suppressions + return expr
    body_mir = []
    body_mir << MIR::Suppress.new("_rt")
    params_list.each { |p| body_mir << MIR::Suppress.new(p.name) }
    body_mir << MIR::ReturnStmt.new(lower(node.body))

    fn_def = MIR::FnDef.new(fn_name, params_mir, ret_str, body_mir, nil, false, nil)
    captures = node.captures&.map { |c|
      if c.is_a?(Hash)
        c[:name].to_s
      elsif c.respond_to?(:name)
        c.name.to_s
      else
        c.to_s
      end
    } || []
    MIR::LambdaExpr.new(fn_def, captures)
  end

  # ================================================================
  # Collections
  # ================================================================


end
