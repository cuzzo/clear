# typed: strict
require "sorbet-runtime"
require_relative "../../backends/zig_type"

module MIRLoweringFunctions
  extend T::Sig
  extend T::Helpers

  requires_ancestor { MIRLowering }

  NameSet = T.type_alias { T::Set[String] }
  CleanupBindingMap = T.type_alias { T::Hash[String, CleanupEntry] }
  BindingTypeMap = T.type_alias { T::Hash[String, Type] }
  BoolNameMap = T.type_alias { T::Hash[String, T::Boolean] }
  DeclNameMap = T.type_alias { T::Hash[Integer, String] }
  CallNode = T.type_alias { T.any(AST::FuncCall, AST::MethodCall) }

  class FunctionParamFact < T::Struct
    extend T::Sig

    const :param, AST::Param
    const :name, String
    const :mir_name, String
    const :zig_type, String
    const :mutable_scalar, T::Boolean
    const :collection_param, T::Boolean
    const :pointer_passed, T::Boolean
    const :protocol_map, T::Boolean

    sig { returns(MIR::Param) }
    def to_mir_param
      MIR::Param.new(mir_name, zig_type, pointer_passed)
    end
  end

  class CallArgFacts < T::Struct
    const :ast_arg, AST::Node
    const :copy_source, T.nilable(AST::Node)
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
    const :consumed_operands, T::Array[MIR::OwnershipOperandFact], default: []

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
      MIR::OwnershipContract.consume_operands(operands)
    end

    sig { returns(T::Array[MIR::OwnershipOperandFact]) }
    def operands
      return consumed_operands unless consumed_operands.empty?

      consumed_names.map do |name|
        MIR::OwnershipOperandFact.owned_binding(name.to_s, Type.new(:Any), "call ownership")
      end
    end
  end

  class StdlibCallArgFact < T::Struct
    extend T::Sig

    COERCIBLE_PRIMITIVES = T.let(
      Set[:Int64, :Float64, :Int32, :Int16, :Int8, :UInt64, :UInt32, :UInt16, :UInt8,
          :TargetInt, :TargetUInt, :TargetLong, :TargetULong, :TargetLongLong,
          :TargetULongLong, :Bool].freeze,
      T::Set[Symbol],
    )

    const :index, Integer
    const :ast_arg, AST::Node
    const :takes, T::Boolean
    const :coerce_type, T.nilable(Symbol)
    const :sink_type, T.nilable(Type)

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

    sig { params(index: Integer).returns(AST::Node) }
    def ast_arg(index)
      args.fetch(index).ast_arg
    end

    sig { params(arg_zig: String, index: Integer).returns(String) }
    def coerce_zig(arg_zig, index)
      fact = args[index]
      fact ? fact.coerce_zig(arg_zig) : arg_zig
    end
  end

  class StdlibArgumentMaterialization < T::Struct
    const :mir_args, T::Array[MIR::Node]
    const :consumed_names, T::Array[String]
    const :consumed_operands, T::Array[MIR::OwnershipOperandFact]
    const :val_alloc_placeholder, T.nilable(Symbol)
  end

  class FunctionEntryPlan < T::Struct
    const :prologue, T::Array[MIR::Node]
    const :takes_mir, T::Array[MIR::Node]
  end

  class CatchLoweringPlan < T::Struct
    const :clauses, T::Array[MIR::CatchClause]
    const :default_body, T::Array[MIR::Node]
    const :default_action, MIR::CatchDefaultAction
    const :snapshot_type, T.nilable(Type)
  end

  class FunctionLoweringContext < T::Struct
    const :bindings, CleanupBindingMap
    const :binding_types, BindingTypeMap
    const :collection_params, NameSet
    const :protocol_map_allocators, T::Hash[String, String]
    const :mutable_scalar_params, NameSet
    const :param_names, NameSet
    const :takes_param_names, NameSet
    const :heap_carry_return_vars, T.nilable(NameSet)
    const :returned_names, NameSet
    const :snapshot_types, NameSet
    const :fn_alloc_marked_names, BoolNameMap
    const :lowered_alloc_names, NameSet
    const :lowered_guarded_cleanup_names, NameSet
    const :decl_zig_name_map, DeclNameMap
    const :guarded_cleanup_names, BoolNameMap
    const :fn_name_rename_map, T::Hash[String, String]
    const :has_rt, T::Boolean
    const :tail_call, T::Boolean
    const :zig_name, String
    const :return_payload_zig, String
    const :return_type, Type
    const :heap_carry_return, T::Boolean
    const :has_catch, T::Boolean
  end

  class FunctionState < T::Struct
    extend T::Sig

    prop :current_function_context, T.nilable(FunctionLoweringContext), default: nil
    prop :pending_stmts, T::Array[MIR::Stmt], factory: -> { [] }
    prop :current_decl_alloc, T.nilable(Symbol), default: nil
    prop :current_expected_type, T.nilable(Type), default: nil
    prop :current_sink_type, T.nilable(Type), default: nil
    prop :current_reassignment_target, T.nilable(String), default: nil
    prop :current_bindings, CleanupBindingMap, factory: -> { {} }
    prop :current_binding_types, BindingTypeMap, factory: -> { {} }
    prop :fn_alloc_marked_names, BoolNameMap, factory: -> { {} }
    prop :lowered_alloc_names, NameSet, factory: -> { Set.new }
    prop :lowered_guarded_cleanup_names, NameSet, factory: -> { Set.new }
    prop :decl_zig_name_map, DeclNameMap, factory: -> { {} }
    prop :guarded_cleanup_names, BoolNameMap, factory: -> { {} }
    prop :fn_name_rename_map, T::Hash[String, String], factory: -> { {} }
    prop :node_store_types, T::Set[String], factory: -> { Set.new }

    sig { params(context: FunctionLoweringContext).void }
    def activate!(context)
      self.current_function_context = context
      self.current_bindings = context.bindings
      self.current_binding_types = context.binding_types
      self.decl_zig_name_map = context.decl_zig_name_map
      self.fn_alloc_marked_names = context.fn_alloc_marked_names
      self.lowered_alloc_names = context.lowered_alloc_names
      self.lowered_guarded_cleanup_names = context.lowered_guarded_cleanup_names
      self.fn_name_rename_map = context.fn_name_rename_map
      self.guarded_cleanup_names = context.guarded_cleanup_names
      self.node_store_types = Set.new
    end

    private

    sig { returns(T::Boolean) }
    def current_decl_heap?
      current_decl_alloc == :heap
    end

    public

    sig { returns(Symbol) }
    def current_decl_or_frame_alloc
      current_decl_heap? ? :heap : :frame
    end

    sig { returns(CleanupBindingMap) }
    def bindings
      current_bindings
    end

    sig { returns(BindingTypeMap) }
    def binding_types
      current_binding_types
    end

    sig { returns(BoolNameMap) }
    def alloc_marked_names
      fn_alloc_marked_names
    end

    sig { returns(DeclNameMap) }
    def decl_zig_names
      decl_zig_name_map
    end

    sig { returns(T::Hash[String, String]) }
    def rename_map
      fn_name_rename_map
    end
  end

  sig { params(node: AST::ExternFnDecl).returns(MIR::Node) }
  def lower_extern_fn(node)
    T.bind(self, MIRLowering) rescue nil
    source = node.extern_source
    if source&.abi == :c
      params = node.params.map do |param|
        zig_type = c_abi_param_zig_type(param)
        MIR::Param.new(param.name, zig_type, param.mutable || false)
      end
      return MIR::CExternFnDecl.new(
        source.symbol || node.name,
        params,
        node.annotation_return_type.zig_type,
        source.dependency,
        source.callconv
      )
    end
    mod = node.from_module
    if program_state.emitted_extern_modules.add?(mod)
      mod_parts = mod.split(".")
      root_module = T.must(mod_parts.first)
      tail_modules = mod_parts.drop(1)
      import_expr = "@import(\"#{root_module}\")" + tail_modules.map { |p| ".#{p}" }.join
      mod_alias = mod.gsub(".", "_")
      module_path = MIRLowering::EXTERN_MODULE_ROOTS.include?(root_module) ? root_module : "#{root_module}.zig"
      MIR::Import.new(mod_alias, module_path, tail_modules.empty? ? nil : tail_modules.join("."))
    else
      MIR::Noop.new("extern_fn_import_already_emitted")
    end
  end

  sig { params(node: AST::ExternStructDecl).returns(T.any(MIR::Node, T::Array[MIR::Node])) }
  def lower_extern_struct(node)
    T.bind(self, MIRLowering) rescue nil
    source = node.extern_source
    if source&.abi == :c
      if node.field_decls.empty?
        opaque_name = "#{node.name}__opaque"
        return [
          MIR::TypeAlias.new(opaque_name, "opaque {}"),
          MIR::TypeAlias.new(node.name, "*#{opaque_name}")
        ]
      end
      fields = node.field_decls.map do |name, field|
        MIR::FieldDef.new(name.to_s, field.type.zig_type(is_field: true), nil)
      end
      return MIR::CExternStructDef.new(node.name, fields)
    end
    if (mod = node.from_module)
      mod_parts = mod.split(".")
      mod_alias = mod.gsub(".", "_")

      items = T.let([], T::Array[MIR::Node])
      if program_state.emitted_extern_modules.add?(mod)
        root_module = T.must(mod_parts.first)
        tail_modules = mod_parts.drop(1)
        member_chain = tail_modules.empty? ? nil : tail_modules.join(".")
        module_path = MIRLowering::EXTERN_MODULE_ROOTS.include?(root_module) ? root_module : "#{root_module}.zig"
        items << MIR::Import.new(mod_alias, module_path, member_chain)
      end
      # AS "ZigTypeExpr" allows aliasing to parameterized types like Parsed(JsonRecord).
      zig_rhs = node.as_type ? "#{mod_alias}.#{node.as_type}" : "#{mod_alias}.#{node.name}"
      items << MIR::TypeAlias.new(node.name, zig_rhs)
      items.length == 1 ? T.must(items.first) : items
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

  sig { params(node: AST::FunctionDef).returns(T.any(MIR::FnDef, T::Array[MIR::FnDef])) }
  def lower_function_def(node)
    T.bind(self, MIRLowering) rescue nil
    ret_type = node.lowering_return_type
    if ret_type.is_a?(Type) && ret_type.frame? && ret_type.struct?
      ret_type = Type.new(ret_type.resolved)
    end
    final_type = transpile_type(ret_type)

    fn_needs_rt = finalized_needs_rt!(node) || function_return_retains_shared_handle?(node) ||
      function_uses_node_store?(node)
    if fn_needs_rt
      sig = fn_sigs[node.name.to_s] || fn_sigs[node.name.to_sym]
      sig.mark_runtime_required! if sig
      node.needs_rt = true if node.respond_to?(:needs_rt=)
    end
    fn_can_fail = node.can_fail.nil? ? true : node.can_fail

    # Mutable scalar params: Zig params are const, need shadow vars.
    # Collections (MUTABLE @list / pool / etc.) are pointer-passed and
    # mutated through the pointer — NOT scalar shadows. Exclude them
    # explicitly: `transpile_type` returns "anytype" for MUTABLE @list
    # which doesn't match the [] / * prefix check, so without this they
    # incorrectly received the `_m_` rename. The rename then masked the
    # original name from MIR-level checks (notably the new
    # INV-CROSS-FRAME-PARAM-ALLOC verifier in mir_checker.rb).
    param_facts = function_param_facts(node.params, node.generic_params)
    context = function_lowering_context(node, final_type, ret_type, fn_needs_rt, param_facts)
    activate_function_context(context)

    # Build param list
    params_mir = T.let(param_facts.flat_map do |fact|
      params = [fact.to_mir_param]
      if fact.protocol_map
        params << MIR::Param.new(protocol_map_allocator_name(fact.name), "std.mem.Allocator", false)
      end
      params
    end, T::Array[MIR::Param])

    # Prepend rt param
    if fn_needs_rt
      params_mir.unshift(MIR::Param.new("rt", "*Runtime", false))
    end

    # Comptime params
    comptime_params = node.type_params.map { |tp| "comptime #{tp}: type" }

    # Build return type string. The error prefix is baked into the string,
    # so can_fail on MIR::FnDef is always false (emitter would double it).
    tied_shared_return = tied_shared_family_return_param(node, context.mutable_scalar_params)
    final_zig_type = ZigType.new(final_type)
    return_type_str = if tied_shared_return
      tied_shared_return
    elsif fn_can_fail
      # Reentrant / mutually-recursive fns must carry `anyerror!T`
      # rather than Zig's inferred `!T`. Zig's inferred-error-set
      # convergence fails for cycles where two `!T` fns call each
      # other (`'eval' uses inferred error set of function 'evalList'
      # here -> dependency loop`). The `anyerror` prefix makes the
      # error set concrete and breaks the loop.
      final_zig_type.fallible_return_type_for(reentrant: node.recursive_reentrance_declared?)
    else
      final_type
    end

    vis = (node.visibility == :pub) ? :pub : :private

    # Determine used names for param suppression
    used_names = collect_identifier_names(node.body)

    entry_plan = function_entry_plan(node, fn_needs_rt, context.mutable_scalar_params, used_names)
    prologue = entry_plan.prologue
    takes_mir = entry_plan.takes_mir

    # Zig treats unused parameters as compile errors. The discard is harmless
    # when a protocol operation later consumes the hidden allocator and keeps
    # read-only constrained functions free of special cases.
    pointer_param_mir = context.protocol_map_allocators.values.map { |name| MIR::Suppress.new(name) }

    # Lower body (track snapshot types for catch blocks)
    catch_clauses = function_catch_clauses(node)
    has_catch = context.has_catch
    # Trampoline bodies are synthesized directly while preserving the
    # normal function signature seen by callers.
    if node.thunk_plan
      body_mir = takes_mir + pointer_param_mir + [ThunkTransform::Emit.build_trampoline(node, self)]
    elsif node.mutual_thunk_plan
      body_mir = takes_mir + pointer_param_mir + [ThunkTransform::Emit.build_mutual_trampoline(node, self)]
    else
      pre_checks = lower_pre_clauses(node)
      lowered_body = lower_body(node.body)
      node_stores = function_state.node_store_types.to_a.sort.flat_map do |zig_type|
        bind_call = MIR::MethodCall.new(
          node_store_type_mir(zig_type),
          "bind",
          [MIR::Ident.new(runtime_binding_name)],
          true,
          MIR::CallableContract.no_ownership(1),
        )
        binding = MIR::Ident.new(node_store_binding_name(zig_type))
        release_call = MIR::MethodCall.new(
          node_store_type_mir(zig_type),
          "releaseBound",
          [binding],
          false,
          MIR::CallableContract.no_ownership(1),
        )
        [
          MIR::Let.new(node_store_binding_name(zig_type), bind_call, false, nil, nil),
          MIR::DeferStmt.new(release_call),
        ]
      end
      body_mir = takes_mir + pointer_param_mir + pre_checks + node_stores + lowered_body
    end
    body_mir = append_ownership_transfers_for_mir_body(body_mir)
    if !fn_can_fail && body_has_faulting_alloc?(body_mir)
      fn_can_fail = true
      return_type_str = faulting_return_type_str(final_type, node)
      sig = fn_sigs[node.name.to_s] || fn_sigs[node.name.to_sym]
      sig.mark_faulting_allocation! if sig
      node.can_fail = true if node.respond_to?(:can_fail=)
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
      inner_ret = if final_zig_type.error_union?
                    final_zig_type.source
                  elsif fn_can_fail
                    final_zig_type.concrete_fallible_return_type
                  else
                    final_zig_type.fallible_return_type
                  end

      inner_fn = MIR::FnDef.new(inner_name, params_mir, inner_ret,
                                 append_ownership_transfers_for_mir_body(prologue + body_mir),
                                 :private, false, comptime_params)

      # Outer function: calls inner, catches errors
      call_args = fn_needs_rt ? ["rt"] + node.params.map { |p| p.name } : node.params.map { |p| p.name }
      inner_call = MIR::Call.new(
        inner_name,
        call_args.map { |arg| MIR::Ident.new(arg) },
        false,
        false,
        MIR::CallableContract.no_ownership(call_args.length),
      )

      catch_plan = build_catch_clauses(node, fn_can_fail)
      error_reassigns = collect_catch_reassigns(node)
      outer_body = [
        MIR::CatchWrapper.new(
          inner_call,
          error_reassigns,
          catch_plan.clauses,
          catch_plan.default_body,
          catch_plan.default_action,
          catch_plan.snapshot_type,
          runtime_binding_name,
        )
      ]

      outer_fn = MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                                  append_ownership_transfers_for_mir_body(outer_body),
                                  vis, false, comptime_params)

      # Return both FnDefs as an array (lower_program/lower_module flatten arrays)
      [inner_fn, outer_fn]
    else
      MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                      append_ownership_transfers_for_mir_body(prologue + body_mir),
                      vis, false, comptime_params)
    end
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def function_uses_node_store?(node)
    return true if node.params.any? { |param| Type.new(param.type).node_reference? }
    return_type = node.return_type
    return true if return_type&.node_reference?

    found = T.let(false, T::Boolean)
    AST.each_locatable(node.body) do |candidate|
      type = candidate.full_type!(context: "@node function scan")
      coerced = candidate.respond_to?(:coerced_type_info) ? candidate.coerced_type_info : nil
      if type.node_reference? || coerced&.node_reference?
        found = true
        break
      end
    end
    found
  end

  sig {
    params(
      node: AST::FunctionDef,
      final_type: String,
      return_type_node: T.any(Type, Symbol, String),
      fn_needs_rt: T::Boolean,
      param_facts: T::Array[FunctionParamFact]
    ).returns(FunctionLoweringContext)
  }
  def function_lowering_context(node, final_type, return_type_node, fn_needs_rt, param_facts)
    T.bind(self, MIRLowering) rescue nil
    mutable_scalar_params = T.let(Set.new, NameSet)
    collection_params = T.let(Set.new, NameSet)
    protocol_map_allocators = T.let({}, T::Hash[String, String])
    param_facts.each do |fact|
      mutable_scalar_params << fact.name if fact.mutable_scalar
      collection_params << fact.name if fact.collection_param
      protocol_map_allocators[fact.name] = protocol_map_allocator_name(fact.name) if fact.protocol_map
    end
    bindings = T.let((node.cleanup_bindings || {}).dup, CleanupBindingMap)
    collection_params.each do |name|
      bindings[name] ||= CleanupEntry.no_cleanup(alloc: :heap, scope: :heap)
    end

    has_catch = function_catch_clauses(node).any?
    return_type_info = Type.from_node!(return_type_node, context: "function lowering return type")
    return_payload = return_type_info.plain_return_payload_type
    FunctionLoweringContext.new(
      bindings: bindings,
      binding_types: {},
      collection_params: collection_params,
      protocol_map_allocators: protocol_map_allocators,
      mutable_scalar_params: mutable_scalar_params,
      param_names: node.params.map { |p| p.name.to_s }.to_set,
      takes_param_names: node.params.select(&:takes).map { |p| p.name.to_s }.to_set,
      heap_carry_return_vars: typed_name_set(node.heap_carry_return_vars),
      returned_names: collect_fn_returned_names(node.body),
      snapshot_types: has_catch ? typed_name_set(node.snapshot_types) : Set.new,
      fn_alloc_marked_names: {},
      lowered_alloc_names: Set.new,
      lowered_guarded_cleanup_names: Set.new,
      decl_zig_name_map: {},
      guarded_cleanup_names: {},
      fn_name_rename_map: {},
      has_rt: fn_needs_rt,
      tail_call: node.tail_call == true,
      zig_name: zig_safe_name(node.name),
      return_payload_zig: return_payload ? return_payload.zig_type : final_type,
      return_type: return_type_info,
      heap_carry_return: node.respond_to?(:heap_carry_return) && node.heap_carry_return == true,
      has_catch: has_catch,
    )
  end

  sig { params(context: FunctionLoweringContext).void }
  def activate_function_context(context)
    T.bind(self, MIRLowering) rescue nil
    function_state.activate!(context)
  end

  sig { params(values: T.nilable(T::Enumerable[T.any(String, Symbol, Type)])).returns(NameSet) }
  def typed_name_set(values)
    names = T.let(Set.new, NameSet)
    values&.each { |value| names << value.to_s }
    names
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def finalized_needs_rt!(node)
    return true if node.thunk_plan || node.mutual_thunk_plan
    return node.needs_rt if node.needs_rt == true || node.needs_rt == false

    Kernel.raise "function #{node.name} missing finalized needs_rt metadata before MIR lowering"
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def function_return_retains_shared_handle?(node)
    T.bind(self, MIRLowering) rescue nil

    ret = node.return_type
    return false unless ret.respond_to?(:any_rc?) && ret.any_rc?

    found = T.let(false, T::Boolean)
    AST.each_locatable(node.body) do |child|
      next unless child.is_a?(AST::ReturnNode) && child.value
      found = true if rc_retain_needed?(child.value) &&
        !return_transfers_heap_binding?(child.value)
    end
    found
  end

  sig { params(params: T::Array[AST::Param], generic_params: T::Array[AST::GenericParamDecl]).returns(T::Array[FunctionParamFact]) }
  def function_param_facts(params, generic_params)
    params.map { |param| function_param_fact(param, generic_params) }
  end

  sig { params(param: AST::Param, generic_params: T::Array[AST::GenericParamDecl]).returns(FunctionParamFact) }
  def function_param_fact(param, generic_params)
    T.bind(self, MIRLowering) rescue nil
    type_info = param.type
    base_zig = transpile_type(param.type, is_param: true)
    protocol_map_param = generic_params.any? do |generic_param|
      generic_param.name.to_sym == type_info.resolved &&
        generic_param.bounds.any? { |bound| bound.type.resolved == :Map }
    end
    collection_param = !!(type_info.needs_pointer_passing? ||
                          (param.mutable && type_info.list_collection?) ||
                          protocol_map_param)
    mutable_scalar = !!(param.mutable &&
                     !protocol_map_param &&
                     !type_info.collection? &&
                     !type_info.needs_pointer_passing? &&
                     !base_zig.start_with?("[]", "*"))
    zig_type = protocol_map_param ? "*#{base_zig}" : function_param_zig_type(param, type_info, base_zig)
    zig_type = "*#{zig_type}" if mutable_scalar && zig_type != "anytype"

    FunctionParamFact.new(
      param: param,
      name: param.name.to_s,
      mir_name: mutable_scalar ? "_m_#{param.name}" : zig_safe_name(param.name.to_s),
      zig_type: zig_type,
      mutable_scalar: mutable_scalar,
      collection_param: collection_param,
      pointer_passed: collection_param || mutable_scalar,
      protocol_map: protocol_map_param,
    )
  end

  sig { params(name: String).returns(String) }
  def protocol_map_allocator_name(name)
    "__clear_map_alloc_#{name}"
  end

  sig { params(param: AST::Param, type_info: Type, base_zig: String).returns(String) }
  def function_param_zig_type(param, type_info, base_zig)
    T.bind(self, MIRLowering) rescue nil
    type_sym = param.type.resolved
    is_user_struct = struct_schemas.key?(type_sym)
    # A mutable generic aggregate may arrive wrapped in any of the bind-time
    # synchronization families handled by WITH POLYMORPHIC. Keep that one
    # boundary structural; concrete generic parameters retain their precise
    # monomorphized Zig type.
    polymorphic_generic_struct = param.mutable && type_info.generic_instance? &&
      struct_schemas.key?(type_info.generic_base)
    sym = param.symbol
    atomic_sync = if sym
                    families = sym.sync_families
                    sym.atomic? || (families ? families.include?(:ATOMIC) : false)
                  else
                    false
                  end
    return "CheatLib.Arc(#{type_info.resolved})" if type_info.shared? && type_info.generic_type_parameter?
    # Canonical finite stream parameters accept all compatible producers
    # (range cursors, open generators, and bounded generators). Their shared
    # NEXT protocol is the ABI; their concrete storage representation is not.
    return "anytype" if is_user_struct || polymorphic_generic_struct || type_info.collection? ||
      type_info.canonical_stream? || atomic_sync

    base_zig
  end

  sig { params(body: T::Array[MIR::Node]).returns(T::Boolean) }
  def body_has_faulting_alloc?(body)
    T.bind(self, MIRLowering) rescue nil

    found = T.let(false, T::Boolean)
    MIR.each_node(body) do |mir|
      next if found
      next unless mir.respond_to?(:expr?) && mir.expr?
      found = true if mir_allocates?(mir) ||
        (mir.is_a?(MIR::MethodCall) && mir.method == "bind" && mir.try_wrap)
    end
    found
  end

  sig { params(final_type: String, node: AST::FunctionDef).returns(String) }
  def faulting_return_type_str(final_type, node)
    ZigType.new(final_type).fallible_return_type_for(reentrant: node.recursive_reentrance_declared?)
  end

  sig { params(node: AST::FunctionDef).returns(T::Array[AST::Node]) }
  def default_catch_body(node)
    body = node.default_catch
    body.is_a?(Array) ? body : []
  end

  sig { params(node: AST::FunctionDef).returns(T::Array[AST::CatchClause]) }
  def function_catch_clauses(node)
    clauses = node.catch_clauses
    clauses.is_a?(Array) ? clauses : []
  end

  sig { params(node: AST::FunctionDef).returns(T::Boolean) }
  def has_default_catch?(node)
    !default_catch_body(node).empty?
  end

  sig {
    params(
      node: AST::FunctionDef,
      fn_needs_rt: T::Boolean,
      mutable_scalar_params: NameSet,
      used_names: T::Set[String],
    ).returns(FunctionEntryPlan)
  }
  def function_entry_plan(node, fn_needs_rt, mutable_scalar_params, used_names)
    T.bind(self, MIRLowering) rescue nil
    prologue = T.let([], T::Array[MIR::Node])
    prologue.concat(recursion_yield_prologue(node, fn_needs_rt))
    prologue.concat(reentrance_guard_prologue(node))
    prologue.concat(runtime_frame_prologue(node, fn_needs_rt))
    prologue.concat(unused_param_suppressions(node, mutable_scalar_params, used_names))
    prologue.concat(mutable_scalar_param_shadows(mutable_scalar_params, used_names))
    takes_mir = takes_param_ownership_mir(node)
    record_lowered_entry_markers!(takes_mir)
    FunctionEntryPlan.new(prologue: prologue, takes_mir: takes_mir)
  end

  sig { params(node: AST::FunctionDef, fn_needs_rt: T::Boolean).returns(T::Array[MIR::Node]) }
  def runtime_frame_prologue(node, fn_needs_rt)
    T.bind(self, MIRLowering) rescue nil
    return [] unless fn_needs_rt

    ret_type_obj = node.lowering_return_type
    bare_ret = ret_type_obj.success_type || ret_type_obj
    returns_value_type = bare_ret.void? || bare_ret.primitive? || bare_ret.resource? ||
                         enum_schemas.key?(bare_ret.resolved) ||
                         union_schemas.key?(bare_ret.resolved)
    returns_string = bare_ret.string?
    heap_carry_return = !!(node.respond_to?(:heap_carry_return) && node.heap_carry_return)
    has_frame_bindings = if node.cleanup_bindings
      node.cleanup_bindings.any? { |_, e| e.frame? }
    else
      node.uses_frame
    end

    out = T.let([
      MIR::ExprStmt.new(
        MIR::Call.new("@setEvalBranchQuota", [MIR::Lit.new("100000")], false, false, MIR::CallableContract.no_ownership(1)),
        false,
      ),
    ], T::Array[MIR::Node])

    if runtime_frame_save_required?(has_frame_bindings, returns_value_type, returns_string, heap_carry_return)
      out << MIR::FrameSave.new(runtime_binding_name)
      out << MIR::FrameRestore.new(runtime_binding_name)
    else
      out << MIR::Suppress.new("rt")
    end
    out
  end

  sig do
    params(
      has_frame_bindings: T::Boolean,
      returns_value_type: T::Boolean,
      returns_string: T::Boolean,
      heap_carry_return: T::Boolean,
    ).returns(T::Boolean)
  end
  def runtime_frame_save_required?(has_frame_bindings, returns_value_type, returns_string, heap_carry_return)
    has_frame_bindings && (returns_value_type || (returns_string && heap_carry_return))
  end

  sig { params(node: AST::FunctionDef).returns(T::Array[MIR::Node]) }
  def reentrance_guard_prologue(node)
    return [] unless node.reentrance_guard_required?

    if node.max_depth_n
      enter_call = MIR::Call.new(
        "safety.enterDepth",
        [MIR::Call.new("@src", [], false, false, MIR::CallableContract.no_ownership(0)), MIR::Lit.new(node.max_depth_n.to_s)],
        false,
        false,
        MIR::CallableContract.no_ownership(2),
      )
      [
        MIR::ExprStmt.new(MIR::TryExpr.new(enter_call), false),
        MIR::DeferStmt.new(MIR::Call.new(
          "safety.exitDepth",
          [MIR::Call.new("@src", [], false, false, MIR::CallableContract.no_ownership(0))],
          false,
          false,
          MIR::CallableContract.no_ownership(1),
        )),
      ]
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
      [guard_init, guard_push, guard_defer]
    end
  end

  sig { params(node: AST::FunctionDef, fn_needs_rt: T::Boolean).returns(T::Array[MIR::Node]) }
  def recursion_yield_prologue(node, fn_needs_rt)
    T.bind(self, MIRLowering) rescue nil
    return [] unless fn_needs_rt && needs_recursion_yield?(node)

    [MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new(runtime_binding_name), "checkYield", [], false, MIR::CallableContract.no_ownership(0)),
      false
    )]
  end

  sig { params(node: AST::FunctionDef, mutable_scalar_params: T::Set[String], used_names: T::Set[String]).returns(T::Array[MIR::Node]) }
  def unused_param_suppressions(node, mutable_scalar_params, used_names)
    out = T.let([], T::Array[MIR::Node])
    node.params.each do |p|
      next if used_names.include?(p.name)
      suppress_name = mutable_scalar_params.include?(p.name) ? "_m_#{p.name}" : p.name
      out << MIR::Suppress.new(suppress_name)
    end
    out
  end

  sig { params(mutable_scalar_params: T::Set[String], used_names: T::Set[String]).returns(T::Array[MIR::Node]) }
  def mutable_scalar_param_shadows(mutable_scalar_params, used_names)
    out = T.let([], T::Array[MIR::Node])
    mutable_scalar_params.each do |name|
      next unless used_names.include?(name)
      ptr_name = "_m_#{name}"
      out << MIR::Let.new(name, MIR::Deref.new(MIR::Ident.new(ptr_name)), true, nil, "_ = &#{name};")
      out << MIR::DeferStmt.new(MIR::ScopeBlock.new([
        MIR::Set.new(MIR::Deref.new(MIR::Ident.new(ptr_name)), MIR::Ident.new(name))
      ]))
    end
    out
  end

  sig { params(node: AST::FunctionDef).returns(T::Array[MIR::Node]) }
  def takes_param_ownership_mir(node)
    T.bind(self, MIRLowering) rescue nil
    out = T.let([], T::Array[MIR::Node])
    node.params.select(&:takes).each do |p|
      entry = function_state.bindings[p.name.to_s] || CleanupEntry::NONE
      ti = p.type
      next unless ownership_tracked_transfer_type?(ti) || (entry.present? && entry.heap?)

      drop_entry = entry.dup
      alloc = entry.present? ? entry.alloc : :heap
      scope = entry.present? ? entry.scope : :heap
      mark = MIR::AllocMark.new(p.name.to_s, alloc, ti, scope)
      if entry.needs_cleanup?
        build_drop_entry!(drop_entry, ti, nil)
        function_state.guarded_cleanup_names[zig_safe_name(p.name.to_s)] = true if drop_entry.has_moved_guard?
        out.concat(MIR::MaterializationPacket.markers(mark, MIR::Cleanup.new(zig_safe_name(p.name.to_s), drop_entry)).statements)
      else
        out.concat(MIR::MaterializationPacket.markers(mark).statements)
      end
    end
    out
  end

  sig { params(nodes: T::Array[MIR::Node]).void }
  def record_lowered_entry_markers!(nodes)
    T.bind(self, MIRLowering) rescue nil
    nodes.each do |node|
      function_state.lowered_alloc_names << node.name.to_s if node.is_a?(MIR::AllocMark)
      function_state.lowered_guarded_cleanup_names << node.name.to_s if (node.is_a?(MIR::Cleanup) || node.is_a?(MIR::ErrCleanup)) && node.cleanup_entry.has_moved_guard?
    end
  end

  # Build the inner function for a POST-having FunctionDef. Holds the
  # original body verbatim. Marked :private so callers go through the
  # outer wrapper (which validates).
  sig { params(node: AST::FunctionDef, params_mir: T::Array[MIR::Param], return_type_str: String, prologue: T::Array[MIR::Node], body_mir: T::Array[MIR::Node], comptime_params: T::Array[String]).returns(MIR::FnDef) }
  def build_post_inner_fn(node, params_mir, return_type_str, prologue, body_mir, comptime_params)
    T.bind(self, MIRLowering) rescue nil
    inner_name = "__#{zig_safe_name(node.name)}_post_body"
    MIR::FnDef.new(inner_name, params_mir, return_type_str,
                   prologue + body_mir, :private, false, comptime_params)
  end

  # Build the outer wrapper for a POST-having FunctionDef. Calls the
  # inner, captures the result, evaluates each POST predicate inside a
  # debug-mode `if` block, panics on violation, returns the result.
  sig { params(node: AST::FunctionDef, params_mir: T::Array[MIR::Param], return_type_str: String, fn_needs_rt: T::Boolean, vis: Symbol, comptime_params: T::Array[String]).returns(MIR::FnDef) }
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
    inner_sig = FunctionSignature.from_function_def(node)
    inner_contract = MIR::CallableContract.new(
      inner_sig,
      MIR::OwnershipContract.new(covers_consuming_params: true),
      node.params.length,
    )
    inner_call_mir = MIR::Call.new(inner_name, arg_idents, is_error_union, call_owned_return?(node), inner_contract)
    inner_call_mir.result_type = Type.new(payload_type || :Void)

    # Each predicate check decomposes into structured MIR and runs
    # behind a MIR::DebugOnly gate.
    check_stmts = (node.post_clauses || []).map do |entry|
      expr   = entry[:expr]
      source = entry[:source]
      cond_mir = lower(expr)
      msg_text = source && !source.empty? ? "DEBUG_POST failed: #{source}" : "DEBUG_POST failed"
      MIR::IfStmt.new(MIR::UnaryOp.new("!", cond_mir),
                      [MIR::Panic.new(msg_text)],
                      nil)
    end

    body = if is_void
      [
        MIR::ExprStmt.new(inner_call_mir, false),
        *([MIR::DebugOnly.new(check_stmts)] unless check_stmts.empty?),
        MIR::ReturnStmt.new(nil),
      ].compact
    else
      [
        MIR::Let.new("result", inner_call_mir, false, nil, "_ = &result;"),
        *([MIR::DebugOnly.new(check_stmts)] unless check_stmts.empty?),
        MIR::ReturnStmt.new(MIR::Ident.new("result")),
      ].compact
    end

    MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                   body, vis, false, comptime_params)
  end

  # Returns checker-visible CATCH clauses. Using lower_body ensures
  # flush_pending is called per statement so hoisted Lets stay in scope.
  sig { params(node: AST::FunctionDef, fn_can_fail: T::Boolean).returns(CatchLoweringPlan) }
  def build_catch_clauses(node, fn_can_fail)
    T.bind(self, MIRLowering) rescue nil
    clauses = T.let([], T::Array[MIR::CatchClause])

    # Build snapshot declaration if function has exactly one snapshot type
    snap_types = node.respond_to?(:snapshot_types) ? (node.snapshot_types || Set.new) : Set.new
    snapshot_type = T.let(snap_types.size == 1 ? Type.new(snap_types.first) : nil, T.nilable(Type))

    function_catch_clauses(node).each do |clause|
      # The annotator produces four lowering-ready fields:
      #   kinds, types, filter_types, filter_messages.
      # Match semantics:
      #   (any kind matches OR any type matches)
      #   AND
      #   (no filters OR any filter_type OR any filter_message matches)
      clause_mir = lower_body(clause.body)
      clause_body = T.let(clause_mir, T::Array[MIR::Node])
      clauses << MIR::CatchClause.new(
        meta: MIR::CatchClauseMeta.new(
          kinds: clause.kinds.map(&:to_s),
          types: clause.types.map(&:to_s),
          filter_types: clause.filter_types.map(&:to_s),
          filter_messages: clause.filter_messages.map { |m| T.cast(lower(m), MIR::Node) },
        ),
        body: clause_body,
      )
    end

    default_body = T.let([], T::Array[MIR::Node])
    default_action = T.let(MIR::CatchDefaultAction::Unreachable, MIR::CatchDefaultAction)
    if has_default_catch?(node)
      # Use lower_body for the same reason as above.
      default_mir = lower_body(default_catch_body(node))
      default_body = T.let(default_mir, T::Array[MIR::Node])
      default_action = MIR::CatchDefaultAction::Body
    elsif fn_can_fail
      default_action = MIR::CatchDefaultAction::Propagate
    end

    CatchLoweringPlan.new(
      clauses: clauses,
      default_body: default_body,
      default_action: default_action,
      snapshot_type: snapshot_type,
    )
  end

  # Extract error-path reassignment metadata from catch clauses (INV-9).
  # Returns one typed fact for each reassignment to an existing binding inside
  # a catch body. Used by MIRChecker to verify allocator consistency.
  sig { params(node: AST::FunctionDef).returns(T::Array[MIR::CatchReassign]) }
  def collect_catch_reassigns(node)
    T.bind(self, MIRLowering) rescue nil
    reassigns = T.let([], T::Array[MIR::CatchReassign])
    catch_bodies = T.let([], T::Array[T::Array[AST::Node]])
    function_catch_clauses(node).each { |c| catch_bodies << c.body if c.body }
    default_body = default_catch_body(node)
    catch_bodies << default_body unless default_body.empty?

    catch_bodies.each do |body|
      walk_catch_body_for_reassigns(body, reassigns)
    end
    reassigns
  end

  sig { params(stmts: T::Array[AST::Node], reassigns: T::Array[MIR::CatchReassign]).void }
  def walk_catch_body_for_reassigns(stmts, reassigns)
    T.bind(self, MIRLowering) rescue nil
    stmts.each do |stmt|
      case stmt
      when AST::BindExpr
        if stmt.mode == :assign
          alloc = infer_catch_value_allocator(stmt.value)
          reassigns << MIR::CatchReassign.new(name: stmt.name.to_s, alloc: alloc, line: stmt.token.line) if alloc
        end
      when AST::Assignment
        if stmt.name.is_a?(AST::Identifier)
          alloc = infer_catch_value_allocator(stmt.value)
          reassigns << MIR::CatchReassign.new(name: stmt.name.name.to_s, alloc: alloc, line: stmt.token.line) if alloc
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

  sig { params(expr: T.nilable(AST::Node)).returns(T.nilable(Symbol)) }
  def infer_catch_value_allocator(expr)
    T.bind(self, MIRLowering) rescue nil
    return nil unless expr
    return :heap if expr.respond_to?(:symbol) && expr.symbol&.heap_storage? == true
    sym_storage = expr.respond_to?(:symbol) ? expr.symbol&.storage : nil
    return :frame if SymbolEntry.frame_storage_value?(sym_storage)
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
    params(arg: MIR::Node, a: AST::Node,
           callee_param: T.nilable(AST::Param),
           callee_param_type: Type,
           callee_sig: T.nilable(FunctionSignature), idx: Integer).returns(MIR::Node)
  end
  def cross_boundary_arg(arg, a, callee_param, callee_param_type, callee_sig, idx)
    T.bind(self, MIRLowering) rescue nil
    ti = Type.from_node!(a, context: "call boundary argument")

    moved_arg = a.is_a?(AST::MoveNode) ||
                (AST.moved?(a) &&
                 !a.is_a?(AST::CopyNode) && !a.is_a?(AST::CloneNode) &&
                 !arg.is_a?(MIR::DupeSlice) && !arg.is_a?(MIR::DeepCopy))
    # See the corresponding TAKES branch below. This must precede the
    # list-to-slice fast path: an Rc/Arc list is a handle, not an ArrayList,
    # so `OwnedSlice` cannot consume it directly.
    if callee_param&.takes && ti.any_rc? && !callee_param_type.any_rc? &&
       !callee_param_type.generic_type_parameter?
      sink_alloc = allocator_for_takes_param!(callee_param)
      payload = rc_payload_value(arg, ti)
      materialized = MIR::DeepCopy.new(payload, callee_param_type.zig_type, nil, :full_value, sink_alloc)
      materialized = hoist_alloc(materialized, a, err_cleanup: true)
      if owned_slice_argument_required?(callee_param, moved_arg, ti, callee_param_type)
        owned_slice = MIR::OwnedSlice.new(materialized, sink_alloc)
        return T.cast(with_ownership_consumption(
          owned_slice,
          mir_ident_names(materialized),
          "MIR::OwnedSlice(managed payload)",
          target_alloc: sink_alloc,
        ), MIR::OwnedSlice)
      end

      return MIR::AddressOf.new(materialized) if wants_ptr?(a, ti, callee_param, callee_param_type, callee_sig, idx)
      return materialized
    end
    if owned_slice_argument_required?(callee_param, moved_arg, ti, callee_param_type)
      sink_alloc = allocator_for_takes_param!(callee_param)
      owned_slice = MIR::OwnedSlice.new(arg, sink_alloc)
      # Fixed array literals are copied into the destination allocator by
      # OwnedSlice; their stack binding is not an ownership source.  Dynamic
      # owning containers, by contrast, transfer their backing allocation via
      # toOwnedSlice and must retain the consumption fact.
      owns_slice_input = ownership_tracked_transfer_type?(ti) ||
        mir_ident_names(arg).any? { |name| function_state.lowered_alloc_names.include?(name.to_s) }
      return owned_slice unless owns_slice_input

      return T.cast(with_ownership_consumption(
        owned_slice,
        mir_ident_names(arg),
        "MIR::OwnedSlice",
        target_alloc: sink_alloc,
      ), MIR::OwnedSlice)
    end

    if callee_param&.takes
      sink_alloc = allocator_for_takes_param!(callee_param)
      # Function signatures intentionally expose the payload type, not an
      # Rc/Arc capability wrapper.  A `GIVE COPY managed` argument therefore
      # cannot cross this boundary as the wrapper itself: it must materialize
      # an owned payload for the plain TAKES slot.  The original handle remains
      # caller-owned and is released by its normal cleanup path after the copy.
      placed = materialize_owned_sink_value(arg, a, sink_alloc, callee_param_type)
      arg = hoist_alloc(placed, a, err_cleanup: true)
    end

    if borrowed_array_argument_required?(ti, a, callee_param_type)
      return MIR::ItemsAccess.new(arg, true)
    end

    # @alwaysMutable is already stable interior-mutable storage. Its wrapper
    # owns the addressability contract, so source does not spell `&`; pass the
    # wrapped payload pointer to a MUTABLE parameter directly.
    if callee_param&.mutable && SymbolEntry.always_mutable_sync?(ti.sync)
      return MIR::AddressOf.new(MIR::FieldGet.new(arg, "data"))
    end

    if with_alias_pointer_shaped?(a) && callee_param && !callee_param.mutable &&
        !callee_param_type.needs_pointer_passing?
      return MIR::Deref.new(arg)
    end

    return arg unless wants_ptr?(a, ti, callee_param, callee_param_type, callee_sig, idx)
    return arg if arg_already_pointer_shaped?(a)
    if callee_param&.mutable && AST.root_identifier(a).nil?
      arg = materialize_mutable_call_temporary(arg, a)
    end
    MIR::AddressOf.new(arg)
  end

  sig { params(arg: MIR::Node, ast_arg: AST::Node).returns(MIR::Node) }
  def materialize_mutable_call_temporary(arg, ast_arg)
    T.bind(self, MIRLowering) rescue nil
    hoisted = hoist_alloc(arg, ast_arg, mutable: true)
    return hoisted unless hoisted.equal?(arg)

    name = "__mutable_arg_#{lowering_counters.next_tmp_id}"
    function_state.pending_stmts << MIR::Let.new(name, arg, true, nil, nil)
    MIR::Ident.new(name)
  end

  sig { params(callee_param: T.nilable(AST::Param), moved_arg: T::Boolean, ti: Type, callee_param_type: Type).returns(T::Boolean) }
  def owned_slice_argument_required?(callee_param, moved_arg, ti, callee_param_type)
    !!(callee_param&.takes && moved_arg && ti.direct_indexable_collection? &&
      !callee_param_type.collection?)
  end

  sig { params(ti: Type, ast_arg: AST::Node, callee_param_type: Type).returns(T::Boolean) }
  def borrowed_array_argument_required?(ti, ast_arg, callee_param_type)
    ti.borrowed_array_argument? && !ast_arg.is_a?(AST::MoveNode) &&
      !callee_param_type.collection? && !callee_param_type.generic_type_parameter?
  end

  sig { params(sig: T.nilable(FunctionSignature), ast_args: T::Array[AST::Node]).returns(T.nilable(MIR::CallableContract)) }
  def callable_contract_for(sig, ast_args)
    T.bind(self, MIRLowering) rescue nil
    return nil unless sig

    facts = call_ownership_facts_for_signature(sig, ast_args)
    MIR::CallableContract.new(sig, facts.ownership_contract, ast_args.length)
  end

  sig { params(sig: T.nilable(FunctionSignature), ast_args: T::Array[AST::Node], mir_args: T::Array[MIR::Node]).returns(T.nilable(MIR::CallableContract)) }
  def callable_contract_for_lowered_args(sig, ast_args, mir_args)
    T.bind(self, MIRLowering) rescue nil
    return nil unless sig

    takes_indices = T.let(Set.new, T::Set[Integer])
    consumed = T.let([], T::Array[String])
    operands = T.let([], T::Array[MIR::OwnershipOperandFact])
    ast_args.each_with_index do |arg, idx|
      param = sig.params[idx]
      next unless call_arg_consumes_ownership?(arg, param)
      arg_type = Type.new(T.unsafe(arg.respond_to?(:coerced_type_info) && arg.coerced_type_info ? arg.coerced_type_info :
        Type.from_node!(arg, context: "lowered call ownership argument")))
      takes_indices << idx
      unless ownership_tracked_transfer_type?(arg_type)
        operands << MIR::OwnershipOperandFact.non_owning(arg_type, "call argument #{idx}")
        next
      end
      sink_alloc = allocator_for_takes_param!(param)
      if borrowed_ownership_operand?(arg)
        operands << MIR::OwnershipOperandFact.borrowed_access(moved_arg_root(arg), arg_type, "call argument #{idx}", sink_alloc)
        next
      end
      ownership_consumed_arg_names(mir_args[idx]).each { |name| consumed << name.to_s }
      ownership_consumed_arg_names(mir_args[idx]).each do |name|
        operands << MIR::OwnershipOperandFact.owned_binding(name.to_s, arg_type, "call argument #{idx}", sink_alloc)
      end
    end
    facts = CallOwnershipFacts.new(takes_indices: takes_indices, consumed_names: consumed.uniq, consumed_operands: operands)
    MIR::CallableContract.new(sig, facts.ownership_contract, ast_args.length)
  end

  sig { params(arg: T.nilable(MIR::Node)).returns(T::Array[String]) }
  def ownership_consumed_arg_names(arg)
    T.bind(self, MIRLowering) rescue nil
    case arg
    when MIR::Ident
      [arg.name.to_s]
    when MIR::OwnedSlice, MIR::Cast, MIR::TryExpr, MIR::TryOptional, MIR::AddressOf, MIR::Deref
      ownership_consumed_arg_names(arg.expr)
    else
      mir_ident_names(arg)
    end
  end

  sig { params(ast_arg: AST::Node, callee_sig: T.nilable(FunctionSignature), param_index: Integer).returns(CallArgFacts) }
  def call_arg_facts(ast_arg, callee_sig, param_index)
    T.bind(self, MIRLowering) rescue nil
    ti = Type.from_node!(ast_arg, context: "call argument")
    callee_param = callee_sig ? callee_sig.params[param_index] : nil
    takes = call_arg_consumes_ownership?(ast_arg, callee_param)
    callee_param_type = (callee_param && callee_param.type) || Type.new(:Any)
    copy_to_owning = (ast_arg.is_a?(AST::CopyNode) &&
                      callee_param_type.collection? &&
                      ti.collection_value?) == true
    copy_source = copy_to_owning ? T.cast(ast_arg, AST::CopyNode).value : nil
    CallArgFacts.new(
      ast_arg: ast_arg,
      copy_source: copy_source,
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

  sig { params(sig: FunctionSignature, ast_args: T::Array[AST::Node]).returns(CallOwnershipFacts) }
  def call_ownership_facts_for_signature(sig, ast_args)
    T.bind(self, MIRLowering) rescue nil
    takes_indices = T.let(Set.new, T::Set[Integer])
    consumed = T.let([], T::Array[String])
    operands = T.let([], T::Array[MIR::OwnershipOperandFact])
    ast_args.each_with_index do |arg, idx|
      callee_param = sig.params[idx]
      next unless call_arg_consumes_ownership?(arg, callee_param)
      arg_type = Type.new(T.unsafe(arg.respond_to?(:coerced_type_info) && arg.coerced_type_info ? arg.coerced_type_info :
        Type.from_node!(arg, context: "call ownership argument")))
      takes_indices << idx
      unless ownership_tracked_transfer_type?(arg_type)
        operands << MIR::OwnershipOperandFact.non_owning(arg_type, "call argument #{idx}")
        next
      end
      sink_alloc = allocator_for_takes_param!(callee_param)
      if borrowed_ownership_operand?(arg)
        operands << MIR::OwnershipOperandFact.borrowed_access(moved_arg_root(arg), arg_type, "call argument #{idx}", sink_alloc)
        next
      end
      root = moved_arg_root(arg)
      next unless root
      entry = function_state.bindings[root] || CleanupEntry::NONE
      next unless entry.present?
      consumed << transfer_binding_name(root)
      operands << MIR::OwnershipOperandFact.owned_binding(transfer_binding_name(root), arg_type, "call argument #{idx}", sink_alloc)
    end
    CallOwnershipFacts.new(takes_indices: takes_indices, consumed_names: consumed.uniq, consumed_operands: operands)
  end

  sig { params(arg: AST::Node).returns(T::Boolean) }
  def borrowed_ownership_operand?(arg)
    return false if arg.is_a?(AST::CopyNode) || arg.is_a?(AST::CloneNode)

    AST.borrowed_ownership_view?(arg)
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).returns(StdlibCallFacts) }
  def stdlib_call_facts(node)
    sig = intrinsic_signature_for(node)
    sig ||= FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    return empty_stdlib_call_facts unless sig

    ast_args = node.is_a?(AST::MethodCall) ? [node.object] + node.args : node.args
    if sig.intrinsic_fixed_arg_list? && sig.params.length != ast_args.length
      Kernel.raise "stdlib call #{node.name}: signature has #{sig.params.length} params for #{ast_args.length} args"
    end
    ownership = call_ownership_facts_for_signature(sig, ast_args)
    facts = T.let([], T::Array[StdlibCallArgFact])
    receiver_type = node.is_a?(AST::MethodCall) ? intrinsic_receiver_type(node) : nil
    ast_args.each_with_index do |ast_arg, index|
      param = sig.params[index]
      next unless param
      facts << StdlibCallArgFact.new(
        index: index,
        ast_arg: ast_arg,
        takes: ownership.takes?(index),
        coerce_type: stdlib_coerce_type(param.type),
        sink_type: stdlib_sink_type_for_arg(receiver_type, index, ownership.takes?(index)),
      )
    end
    StdlibCallFacts.new(args: facts, ownership: ownership)
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).returns(T.nilable(FunctionSignature)) }
  def intrinsic_signature_for(node)
    matched = node.respond_to?(:matched_stdlib_def) ? node.matched_stdlib_def : nil
    found = FunctionSignature.unwrap(matched)
    return found if found

    fallback = IntrinsicRegistry.lookup(STD_LIB, T.unsafe(node).name.to_s)
    fallback = T.unsafe(fallback).first if fallback.is_a?(Array)
    FunctionSignature.unwrap(fallback)
  end

  sig { params(receiver_type: T.nilable(Type), index: Integer, takes: T::Boolean).returns(T.nilable(Type)) }
  def stdlib_sink_type_for_arg(receiver_type, index, takes)
    return nil unless takes && receiver_type
    return receiver_type.value_type if receiver_type.map? && index == 2
    return receiver_type.element_type if receiver_type.linear_collection? && index == 1

    nil
  end

  sig { returns(StdlibCallFacts) }
  def empty_stdlib_call_facts
    StdlibCallFacts.new(
      args: [],
      ownership: CallOwnershipFacts.new(takes_indices: Set.new, consumed_names: []),
    )
  end

  sig { params(type_info: Type::TypeInput).returns(T.nilable(Symbol)) }
  def stdlib_coerce_type(type_info)
    ti = Type.from_node(type_info)
    return nil unless ti

    resolved = ti.resolved
    resolved.is_a?(Symbol) ? resolved : nil
  end

  sig { params(node: CallNode).returns(T.nilable(FunctionSignature)) }
  def matched_call_signature(node)
    return nil unless node.respond_to?(:matched_signature)

    raw = node.matched_signature
    unwrapped = FunctionSignature.unwrap(raw)
    return unwrapped if unwrapped
    return FunctionSignature.from_function_def(raw) if raw.is_a?(AST::FunctionDef)

    nil
  end

  sig { params(facts: CallArgFacts).returns(MIR::Node) }
  def lower_call_arg_from_facts(facts)
    T.bind(self, MIRLowering) rescue nil
    raw_arg = with_decl_alloc(facts.arg_alloc) do
      if facts.copy_source
        copy_type = facts.callee_param_type.is_a?(Type) ? facts.callee_param_type.zig_type : nil
        MIR::DeepCopy.new(lower(T.must(facts.copy_source)), copy_type, nil, :full_value, :heap)
      else
        with_expected_type(facts.callee_param_type) { lower(facts.ast_arg) }
      end
    end
    arg = hoist_alloc(
      raw_arg,
      facts.ast_arg,
      err_cleanup: facts.takes,
      mutable: facts.copy_to_owning,
      ownership_materialization_alloc: facts.takes ? facts.arg_alloc : nil,
    )
    boundary_arg = cross_boundary_arg(
      arg,
      facts.ast_arg,
      facts.callee_param,
      facts.callee_param_type,
      facts.callee_sig,
      facts.param_index,
    )
    return hoist_alloc(boundary_arg, facts.ast_arg, err_cleanup: facts.takes) if mir_allocates?(boundary_arg)

    boundary_arg
  end

  sig do
    params(
      node: CallNode,
      callee: String,
      args: T::Array[MIR::Node],
      can_fail: T::Boolean,
      owned_return: T::Boolean,
      contract: T.nilable(MIR::CallableContract),
      ast_args: T::Array[AST::Node],
      mir_args: T::Array[MIR::Node],
    ).returns(MIR::Node)
  end
  def finalize_call_result(node, callee, args, can_fail, owned_return, contract, ast_args = [], mir_args = [])
    call = MIR::Call.new(callee, args, can_fail, owned_return, contract)
    call.never_success = call_never_returns_success?(node)
    if node.respond_to?(:full_type!)
      retained_error = if node.respond_to?(:retain_error_channel) && T.unsafe(node).retain_error_channel == true &&
                          node.respond_to?(:error_union_type)
        T.unsafe(node).error_union_type
      end
      call.result_type = retained_error ? Type.new(retained_error) : Type.from_node!(node, context: "call result")
    end
    attach_explicit_move_consumption!(call, ast_args, mir_args, "call explicit move", contract)
    return call unless node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
    return call if owned_return

    MIR::DupeSlice.new(call, :heap)
  end

  sig { params(call: MIR::Call, ast_args: T::Array[AST::Node], mir_args: T::Array[MIR::Node], source: String, contract: T.nilable(MIR::CallableContract)).void }
  def attach_explicit_move_consumption!(call, ast_args, mir_args, source, contract)
    T.bind(self, MIRLowering) rescue nil
    operands = T.let([], T::Array[MIR::OwnershipOperandFact])
    ast_args.each_with_index do |ast_arg, idx|
      next unless ast_arg.is_a?(AST::MoveNode) || AST.moved?(ast_arg)
      # `GIVE COPY managed` to a plain TAKES parameter is lowered as a fresh
      # payload copy, not a transfer of the Rc/Arc wrapper.  Keep the wrapper's
      # cleanup live so the retained source is released after the call.
      next if managed_handle_materialized_for_plain_takes?(ast_arg, contract, idx)
      mir_arg = mir_args[idx]
      next unless mir_arg
      operands.concat(ownership_operands_for_lowered_takes_arg(mir_arg, ast_arg, source, :heap))
    end
    operands.reject! { |operand| operand.kind == :non_owning }
    return if operands.empty?

    call.ownership_consumption = MIR::OwnershipConsumptionFact.new(
      operands: operands,
      target: :owned_sink,
      target_alloc: :heap,
      source: source,
      covers_consuming_params: true,
    )
  end

  sig { params(ast_arg: AST::Node, contract: T.nilable(MIR::CallableContract), idx: Integer).returns(T::Boolean) }
  def managed_handle_materialized_for_plain_takes?(ast_arg, contract, idx)
    return false unless contract
    param = contract.signature.params[idx]
    return false unless param&.takes

    source = ast_arg.is_a?(AST::MoveNode) ? ast_arg.value : ast_arg
    source_type = Type.from_node!(source, context: "managed TAKES materialization")
    source_type.any_rc? && !Type.new(param.type).any_rc? &&
      !Type.new(param.type).generic_type_parameter?
  end

  sig do
    params(a: AST::Node, ti: Type,
           callee_param: T.nilable(AST::Param),
           callee_param_type: Type,
           callee_sig: T.nilable(FunctionSignature), idx: Integer).returns(T::Boolean)
  end
  private def wants_ptr?(a, ti, callee_param, callee_param_type, callee_sig, idx)
    T.bind(self, MIRLowering) rescue nil
    mutable_callee     = !callee_param.nil? && !!callee_param.mutable
    wants_ptr_mut_list  = mutable_callee &&
                          callee_param.type.respond_to?(:list_collection?) &&
                          callee_param.type.list_collection?
    wants_ptr_mut_value = mutable_callee &&
                          !wants_ptr_mut_list &&
                          !callee_param_type.needs_pointer_passing?
    # `T` generic parameters are emitted as an anytype value. Passing a
    # map/list by address here changes the instantiated T to *Map/*List and
    # breaks value-returning generic functions; their own body decides whether
    # to borrow or materialize the concrete payload.
    wants_ptr_intrinsic = ti.is_a?(Type) && Type.new(ti).needs_pointer_passing? &&
                          !callee_param_type.generic_type_parameter?
    wants_ptr_poly      = universal_poly_arg_needs_addr?(a, callee_sig, idx)
    !!(wants_ptr_mut_list || wants_ptr_mut_value || wants_ptr_intrinsic || wants_ptr_poly)
  end

  sig { params(a: AST::Node).returns(T::Boolean) }
  private def arg_already_pointer_shaped?(a)
    T.bind(self, MIRLowering) rescue nil
    return false unless a.is_a?(AST::Identifier)
    !!(current_function_collection_param?(a.name) ||
       with_alias_pointer_shaped?(a) ||
       capture_state.current_bg_pointer_captures&.include?(a.name))
  end

  sig { params(a: AST::Node).returns(T::Boolean) }
  private def with_alias_pointer_shaped?(a)
    T.bind(self, MIRLowering) rescue nil
    return false unless a.is_a?(AST::Identifier)

    name = a.name.to_s
    return false unless capability_state.with_alias_owner_map&.key?(name) == true
    return capability_state.if_bind_pointer_aliases.include?(name) if capability_state.if_bind_aliases.include?(name)

    a.symbol&.borrowed_alias == true
  end

  sig { params(node: AST::FuncCall).returns(MIR::Node) }
  def lower_func_call(node)
    T.bind(self, MIRLowering) rescue nil
    if (intercept = stub_intercept_for(node.name, nil, node.args))
      return intercept
    end

    if node.protocol_name
      receiver_index = T.must(node.protocol_receiver_index)
      receiver = node.args.fetch(receiver_index)
      return lower_user_protocol_call(node, node.args, receiver.full_type!(context: "protocol function lowering"))
    end

    # Intrinsic pattern: already resolved by annotator
    return lower_intrinsic(node) if node.zig_pattern

    # Extern FFI call
    if node.respond_to?(:extern_call) && node.extern_call
      return lower_extern_call(node)
    end

    # Standard call
    callee_sig = fn_sig_for(node.name)
    callee_sig ||= matched_call_signature(node)
    args_mir = node.args.each_with_index.map do |a, idx|
      lower_call_arg_from_facts(call_arg_facts(a, callee_sig, idx))
    end

    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    mod_prefix = mod_alias ? "#{mod_alias.gsub('.', '_')}." : ""

    if node.respond_to?(:fn_var_call) && node.fn_var_call
      # fn-type variable call
      all_args = [MIR::Ident.new(runtime_binding_name)] + args_mir
      contract = callable_contract_for_lowered_args(FunctionSignature.unwrap(node.matched_signature), node.args, args_mir)
      # Function values use CLEAR's uniform callback ABI:
      #   *const fn (*Runtime, ...) anyerror!R
      # even when R itself is not an error union. The indirect call must
      # therefore always consume/propagate the ABI error channel. Omitting
      # `try` produced invalid Zig for ordinary `FN(Int64) -> Bool` values.
      return MIR::Call.new("try #{node.name}", all_args, false, call_owned_return?(node), contract)
    end

    # Resolve rt/fail from fn_sigs
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)
    can_fail = false if node.respond_to?(:retain_error_channel) && T.unsafe(node).retain_error_channel

    # Generic type args
    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(generic_type_arg_zig(t)) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(runtime_binding_name)] : []
    runtime_args = inject_protocol_map_allocator_args(callee_sig, node.args, args_mir)
    all_args = type_args + rt_args + runtime_args
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    owned_return = call_owned_return?(node)

    finalize_call_result(
      node, fn_zig, all_args, can_fail, owned_return,
      callable_contract_for_lowered_args(callee_sig, node.args, args_mir),
      node.args,
      args_mir,
    )
  end

  sig { params(node: AST::MethodCall).returns(MIR::Node) }
  def lower_method_call(node)
    T.bind(self, MIRLowering) rescue nil
    # Stub interception: a UFCS call `x.query(args)` lowers to `query(x, args)`,
    # so STUB query intercepts must apply here too. Inherent-method resolution
    # mangles `name` for Zig dispatch while preserving the declared spelling in
    # `source_method_name`; STUB declarations always use that source spelling.
    stub_name = node.source_method_name || node.name
    if (intercept = stub_intercept_for(stub_name, node.object, node.args))
      return intercept
    end

    if node.protocol_name
      return lower_user_protocol_method_call(node)
    end

    if node.protocol_operation
      if node.protocol_operation == :put
        return lower_protocol_map_put_call(node.object, T.must(node.args[0]), T.must(node.args[1]))
      end

      receiver = T.cast(lower(node.object), MIR::Node)
      receiver = MIR::AddressOf.new(receiver) unless collection_param_receiver?(node.object)
      arguments = node.args.map { |argument| T.cast(lower(argument), MIR::Node) }
      if node.protocol_operation == :delete
        arguments << protocol_map_allocator_for(node.object)
      end
      return MIR::ProtocolCall.new(:Map, T.must(node.protocol_operation), receiver, arguments)
    end

    # Intrinsic pattern: already resolved by annotator
    if node.zig_pattern
      return lower_safe_nav_method_call(node) if (node.object.is_a?(AST::OptionalUnwrap) && node.object.safe_navigation?) ||
        (node.object.respond_to?(:safe_nav_chain) && node.object.safe_nav_chain == true)
      return lower_intrinsic(node)
    end

    # Extern method dispatch
    if node.extern_call
      return lower_extern_method(node)
    end

    # Standard UFCS call: method(object, args...)
    callee_sig = fn_sig_for(node.name)
    callee_sig ||= matched_call_signature(node)
    obj_mir = lower_call_arg_from_facts(call_arg_facts(node.object, callee_sig, 0))
    args_mir = node.args.each_with_index.map do |a, idx|
      lower_call_arg_from_facts(call_arg_facts(a, callee_sig, idx + 1))
    end

    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    mod_prefix = mod_alias ? "#{mod_alias.gsub('.', '_')}." : ""
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)
    can_fail = false if node.respond_to?(:retain_error_channel) && T.unsafe(node).retain_error_channel

    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(generic_type_arg_zig(t)) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(runtime_binding_name)] : []
    ast_args = [node.object] + node.args
    mir_args = [obj_mir] + args_mir
    runtime_args = inject_protocol_map_allocator_args(callee_sig, ast_args, mir_args)
    all_args = type_args + rt_args + runtime_args
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    owned_return = call_owned_return?(node)

    finalize_call_result(
      node, fn_zig, all_args, can_fail, owned_return,
      callable_contract_for_lowered_args(callee_sig, [node.object] + node.args, [obj_mir] + args_mir),
      [node.object] + node.args,
      [obj_mir] + args_mir,
    )
  end

  sig { params(node: AST::MethodCall).returns(MIR::Node) }
  def lower_user_protocol_method_call(node)
    T.bind(self, MIRLowering) rescue nil

    ast_args = [node.object] + node.args
    receiver_type = node.object.full_type!(context: "protocol receiver lowering")
    lower_user_protocol_call(node, ast_args, receiver_type)
  end
  private :lower_user_protocol_method_call

  sig { params(node: CallNode, ast_args: T::Array[AST::Node], receiver_type: Type).returns(MIR::Node) }
  def lower_user_protocol_call(node, ast_args, receiver_type)
    T.bind(self, MIRLowering) rescue nil

    signature = T.must(matched_call_signature(node))
    mir_args = ast_args.each_with_index.map do |argument, index|
      lower_call_arg_from_facts(call_arg_facts(argument, signature, index))
    end
    receiver_index = node.is_a?(AST::FuncCall) ? (node.protocol_receiver_index || 0) : 0
    receiver = ast_args.fetch(receiver_index)
    type_arg = MIR::Ident.new(user_protocol_receiver_type_arg(receiver, receiver_type))
    all_args = [type_arg, MIR::Ident.new(runtime_binding_name)] + mir_args
    fn_zig = "__clearProtocol_#{T.must(node.protocol_name)}_#{zig_safe_name(T.must(node.protocol_operation).to_s)}"
    can_fail = signature.return_type.error_union?

    finalize_call_result(
      node,
      fn_zig,
      all_args,
      can_fail,
      call_owned_return?(node),
      callable_contract_for_lowered_args(signature, ast_args, mir_args),
      ast_args,
      mir_args,
    )
  end
  private :lower_user_protocol_call

  sig { params(receiver: AST::Node, receiver_type: Type).returns(String) }
  def user_protocol_receiver_type_arg(receiver, receiver_type)
    T.bind(self, MIRLowering) rescue nil

    root = AST.root_identifier(receiver)
    polymorphic_type = root && capability_state.polymorphic_alias_type_map&.[](root.name.to_s)
    polymorphic_type || generic_type_arg_zig(receiver_type)
  end
  private :user_protocol_receiver_type_arg

  sig do
    params(
      signature: T.nilable(FunctionSignature),
      ast_args: T::Array[AST::Node],
      mir_args: T::Array[MIR::Node]
    ).returns(T::Array[MIR::Node])
  end
  def inject_protocol_map_allocator_args(signature, ast_args, mir_args)
    return mir_args unless signature

    mir_args.each_with_index.flat_map do |argument, index|
      param = signature.params[index]
      next [argument] unless param && protocol_map_signature_param?(signature, param)

      [argument, protocol_map_allocator_for(ast_args.fetch(index))]
    end
  end

  sig { params(signature: FunctionSignature, param: AST::Param).returns(T::Boolean) }
  def protocol_map_signature_param?(signature, param)
    bounds = signature.generic_bounds[param.type.resolved]
    !!(bounds && bounds.any? { |bound| bound.resolved == :Map })
  end

  sig { params(node: AST::Node).returns(MIR::Node) }
  def protocol_map_allocator_for(node)
    T.bind(self, MIRLowering) rescue nil
    root = root_receiver_node(node)
    if root
      hidden = current_function_protocol_map_allocator(root.name)
      return MIR::Ident.new(hidden) if hidden
    end

    MIR::AllocatorRef.new(placement_for_node(node))
  end

  sig { params(receiver_node: AST::Node, key_node: AST::Node, value_node: AST::Node).returns(MIR::Node) }
  def lower_protocol_map_put_call(receiver_node, key_node, value_node)
    T.bind(self, MIRLowering) rescue nil
    receiver = T.cast(lower(receiver_node), MIR::Node)
    receiver = MIR::AddressOf.new(receiver) unless collection_param_receiver?(receiver_node)
    sink_alloc = placement_for_node(receiver_node)
    sink_type = TypeProjectionExpression.new(
      owner: receiver_node.full_type!(context: "Map protocol put receiver").resolved,
      member: :Value,
    )
    value = with_sink_type(Type.new(sink_type)) do
      with_decl_alloc(sink_alloc) { T.cast(lower(value_node), MIR::Node) }
    end
    value = materialize_owned_sink_value(value, value_node, sink_alloc, Type.new(sink_type))
    value = hoist_alloc(value, value_node, err_cleanup: true) if mir_allocates?(value)
    allocator = protocol_map_allocator_for(receiver_node)
    call = MIR::ProtocolCall.new(
      :Map,
      :put,
      receiver,
      [T.cast(lower(key_node), MIR::Node), value, allocator, allocator],
    )
    with_ownership_consumption_for_value(
      call,
      value,
      value_node,
      "Map protocol put",
      target_alloc: sink_alloc,
    )
  end

  sig { params(node: T.any(AST::FunctionDef, CallNode)).returns(T::Boolean) }
  def call_owned_return?(node)
    T.bind(self, MIRLowering) rescue nil
    sig = fn_sig_for(node.name) if node.respond_to?(:name)
    sig ||= FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    if sig && sig.respond_to?(:return_lifetime) && !sig.return_lifetime.empty?
      return false unless sig.heap_carry_return == true || sig.heap_return_alloc?
    end
    node_ti = if node.is_a?(AST::FunctionDef)
      node.lowering_return_type
    else
      Type.from_node!(node, context: "call owned return")
    end
    if !node_ti.any? && !node_ti.auto?
      return concrete_call_type_owned_return?(node_ti, sig)
    end

    unless node.is_a?(AST::FunctionDef)
      dep = call_owned_return_from_args?(node, sig)
      return dep unless dep.nil?
    end
    raw_ti = sig&.return_type
    ti = T.let(raw_ti.is_a?(Type) ? raw_ti : (raw_ti ? Type.new(raw_ti) : nil), T.nilable(Type))
    call_type_owned_return?(ti, sig)
  end

  sig { params(node: CallNode).returns(T::Boolean) }
  def call_never_returns_success?(node)
    T.bind(self, MIRLowering) rescue nil
    return false unless node.respond_to?(:name)
    fn = program_state.fn_nodes[node.name.to_s]
    return false unless fn.is_a?(AST::FunctionDef)
    fn_ret = fn.lowering_return_type
    return false unless fn_ret.error_union?

    !function_body_has_value_return?(fn.body)
  end

  sig { params(nodes: AST::RawBody).returns(T::Boolean) }
  def function_body_has_value_return?(nodes)
    nodes.any? do |stmt|
      if stmt.is_a?(AST::ReturnNode)
        !stmt.value.nil?
      else
        body_slots =
          if stmt.is_a?(AST::Locatable)
            AST.body_slots(stmt)
          else
            []
          end
        bodies =
          if body_slots.empty?
            %i[body then_body else_body do_branch].filter_map do |name|
              stmt.respond_to?(name) ? stmt.public_send(name) : nil
            end
          else
            body_slots.map(&:body)
          end
        bodies.any? { |body| function_body_has_value_return?(Kernel.Array(body)) }
      end
    end
  end

  sig { params(ti: Type, sig_obj: T.nilable(FunctionSignature)).returns(T::Boolean) }
  def concrete_call_type_owned_return?(ti, sig_obj)
    call_type_owned_return?(ti, sig_obj)
  end

  sig { params(ti: T.nilable(Type), sig_obj: T.nilable(FunctionSignature)).returns(T::Boolean) }
  def call_type_owned_return?(ti, sig_obj)
    T.bind(self, MIRLowering) rescue nil
    return false unless ti
    ti = ti.success_type || ti
    if ti.string?
      return false if ti.symbol? || ti.raw?
      return true if sig_obj&.heap_carry_return == true
      return true if sig_obj&.heap_return_alloc?
      return false if sig_obj
      return ti.heap?
    end
    schema_name = ti.generic_instance? ? ti.generic_base : ti.resolved
    return false if enum_schemas.key?(schema_name)

    union_schema = union_schemas[schema_name]
    if union_schema
      variants = union_schema.respond_to?(:variants) ? union_schema.variants : {}
      return variants.any? { |_, variant_type| Type.variant_has_heap?(variant_type) }
    end

    ti.ownership_bearing?(T.unsafe(mir_schema_lookup)) ||
      ti.indirect? || ti.collection? || ti.any_rc? || ti.any_sync? ||
      ti.resource? || ti.recursive_cleanup_shape?(T.unsafe(mir_schema_lookup))
  end

  sig { params(node: CallNode, sig_obj: T.nilable(FunctionSignature)).returns(T.nilable(T::Boolean)) }
  def call_owned_return_from_args?(node, sig_obj)
    T.bind(self, MIRLowering) rescue nil
    return nil unless sig_obj
    heap_carry_return_vars = sig_obj.heap_carry_return_vars
    return nil unless heap_carry_return_vars && !heap_carry_return_vars.empty?
    by_name = T.let({}, T::Hash[String, Integer])
    sig_obj.params.each_with_index { |param, idx| by_name[param.name.to_s] = idx }
    has_param_return = T.let(false, T::Boolean)
    heap_carry_return_vars.each do |name|
      idx = by_name[name.to_s]
      unless idx
        return true
      end
      has_param_return = true
      arg = node.args[idx]
      return true unless arg
      return true if ast_expr_produces_heap?(arg)
    end
    if has_param_return
      ret = sig_obj.return_type.success_type
      return true if ret&.string? || ret&.recursive_cleanup_shape?(T.unsafe(mir_schema_lookup))
      return false
    end
    nil
  end

  sig { params(expr: AST::Node).returns(T::Boolean) }
  def ast_expr_produces_heap?(expr)
    T.bind(self, MIRLowering) rescue nil
    node = expr
    node = node.value if node.is_a?(AST::MoveNode)
    node = node.left if node.is_a?(AST::BinaryOp) && node.op == :OR_ELSE
    return false if node.respond_to?(:storage) && [:rodata, :borrow].include?(node.storage)
    return false if node.respond_to?(:rodata_provenance?) && node.rodata_provenance?
    return false if node.respond_to?(:borrow_provenance?) && node.borrow_provenance?
    return true if node.respond_to?(:needs_heap_create) && node.needs_heap_create
    return true if node.respond_to?(:heap_storage?) && node.heap_storage?
    return true if node.respond_to?(:symbol) && node.symbol&.heap_storage?
    return true if node.is_a?(AST::StringConcat)
    return true if node.is_a?(AST::BinaryOp) && node.string_concat
    return false unless node.is_a?(AST::Locatable)
    ti = node.full_type!(context: "heap-producing call expression")
    ti.heap_ptr? || ti.recursive_cleanup_shape?(T.unsafe(mir_schema_lookup))
  end

  # Safe navigation for method calls: expr?.method(args)
  # Wraps the call in (if (expr) |_snav_N| call_with_N_as_receiver else null).
  sig { params(node: AST::MethodCall).returns(MIR::IfOptional) }
  def lower_safe_nav_method_call(node)
    T.bind(self, MIRLowering) rescue nil
    snav_var = "_snav_#{lowering_counters.next_safe_nav_id}"

    explicit = node.object.is_a?(AST::OptionalUnwrap)
    inner_ast = explicit ? node.object.target : node.object
    inner_mir = lower(inner_ast)

    snav_ident = AST::Identifier.new(node.object.token, snav_var)
    receiver_type = node.object.full_type!(context: "safe-nav receiver")
    receiver_type = T.must(receiver_type.wrapped_type) unless explicit
    AST.stamp_synthetic_type!(snav_ident, receiver_type, context: "synthetic AST type")

    synthetic = node.dup
    synthetic.object = snav_ident

    call_mir  = lower_intrinsic(synthetic)

    result_type = node.full_type!(context: "safe-navigation method result")
    result_type = Type.optional_of(result_type) unless result_type.optional?
    result = MIR::IfOptional.new(
      inner_mir, snav_var, call_mir,
      optional_nil_mir(result_type),
    )
    result.result_type = result_type
    result
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).returns(MIR::Node) }
  def lower_intrinsic(node)
    T.bind(self, MIRLowering) rescue nil
    # A literal is already immutable, process-lifetime data and therefore is
    # a complete String@symbol value without a runtime interner lookup. This
    # also keeps keyword-shaped symbols usable in compile-time/global tables.
    if node.is_a?(AST::FuncCall) && node.name.to_s == "symbol" && node.args.length == 1
      literal = node.args.first
      if literal.is_a?(AST::Literal) && literal.type == :STRING
        return MIR::SymbolLit.new(literal.value.to_s)
      end
    end

    # Symbol-based intrinsics are complex special builtins
    if node.zig_pattern.is_a?(Symbol)
      case node.zig_pattern
      when :macro_print
        Kernel.raise "macro_print intrinsic must be a function call" unless node.is_a?(AST::FuncCall)
        return lower_macro_print(node)
      when :macro_map
        raise "BUG: macro_map should have been rewritten by PipelineRewriter"
      else
        raise "MIRLowering: unhandled symbol intrinsic: #{node.zig_pattern}"
      end
    end

    # Registry-backed intrinsics: resolve destination allocator before lowering
    # TAKES args. COPY inside append/put/etc. must be constructed in the
    # receiver/container allocator so cleanup remains one-allocator-per-owner.
    pre_resolved_alloc = nil
    entry = intrinsic_signature_for(node)
    raise "lower_intrinsic: missing stdlib signature for #{node.name}" unless entry
    entry_alloc = entry.intrinsic_alloc(IntrinsicAllocationKind::Alloc)
    if entry_alloc
      pre_resolved_alloc = resolve_alloc_sym(entry_alloc, nil, node)
    end
    receiver_type = intrinsic_receiver_type(node)
    stdlib_facts = stdlib_call_facts(node)
    ownership_facts = stdlib_facts.ownership

    # Template-based intrinsics: lower args to MIR, apply ownership transforms, emit
    mir_args = if node.is_a?(AST::MethodCall)
      obj_mir = with_expected_type(receiver_type) { lower(node.object) }
      # Auto-deref Arc/Rc-wrapped receivers: obj.ctrl.data.*
      # Zig only -- BC has no Arc-wrapping. Without the gate, methods on
      # shared collections (e.g. map.contains?, map.count) get rewritten
      # to operate on `Deref(map.ctrl.data)`, which the bc_emitter doesn't
      # resolve to the underlying MapRef.
      if receiver_type&.any_rc? && !bc_target?
        obj_mir = rc_payload_value(T.cast(obj_mir, MIR::Node), receiver_type)
      elsif receiver_type&.frozen?
        # *const T auto-derefs for method calls in Zig — no _root deref needed
      end
      lowered_args = node.args.each_with_index.map do |a, ai|
        fact = stdlib_facts.args[ai + 1]
        with_sink_type(fact&.sink_type) do
          takes = ownership_facts.takes?(ai + 1)
          takes && pre_resolved_alloc ? with_decl_alloc(pre_resolved_alloc) { lower(a) } : lower(a)
        end
      end
      [obj_mir] + lowered_args
    else
      node.args.each_with_index.map do |a, ai|
        fact = stdlib_facts.args[ai]
        with_sink_type(fact&.sink_type) do
          takes = ownership_facts.takes?(ai)
          takes && pre_resolved_alloc ? with_decl_alloc(pre_resolved_alloc) { lower(a) } : lower(a)
        end
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
    if bc_target? && entry.intrinsic_bc?
      op_name = entry.intrinsic_bc_op_or(node.name.to_s.to_sym)
      return MIR::InlineBc.new(op_name, mir_args, entry)
    end

    # Stdlib TAKES metadata feeds the same owned-sink materialization used by
    # indexed/container stores. The stdlib registry decides whether ownership
    # transfers; this code only ensures a borrowed/rodata value becomes owned
    # in the allocator selected for that sink.
    alloc_placeholder = T.let(nil, T.nilable(Symbol))
    val_alloc_placeholder = T.let(nil, T.nilable(Symbol))
    if entry_alloc
      resolved = pre_resolved_alloc || :heap
      alloc_placeholder = resolved
    end

    arg_materialization = materialize_stdlib_arguments(
      mir_args,
      stdlib_facts,
      ownership_facts,
      alloc_placeholder || pre_resolved_alloc || :heap,
      val_alloc_placeholder,
    )
    mir_args = arg_materialization.mir_args
    consumed_names = arg_materialization.consumed_names
    consumed_operands = arg_materialization.consumed_operands
    val_alloc_placeholder = arg_materialization.val_alloc_placeholder
    mir_args = mir_args.each_with_index.map do |arg_mir, index|
      ast_arg = intrinsic_ast_arg(node, stdlib_facts, index)
      if node_store_create_call?(arg_mir)
        hoist_evaluation_barrier(arg_mir)
      elsif mir_allocates?(arg_mir)
        hoist_alloc(arg_mir, ast_arg, err_cleanup: ownership_facts.takes?(index))
      else
        arg_mir
      end
    end

    result_type = Type.from_node!(node, context: "intrinsic result")
    result_ownership_bearing = intrinsic_result_ownership_bearing?(result_type)
    alloc_metadata = MIR::InlineAllocMetadata.new(alloc: alloc_placeholder, val_alloc: val_alloc_placeholder)
    owned_result_alloc = intrinsic_owned_result_alloc(entry, node, alloc_metadata, result_ownership_bearing)
    ownership_contract = MIR::OwnershipContract.empty
    if ownership_facts.takes_any?
      operands = consumed_operands.empty? ? consumed_names.map { |name|
        MIR::OwnershipOperandFact.owned_binding(name.to_s, Type.new(:Any), "stdlib ownership", val_alloc_placeholder || alloc_placeholder || pre_resolved_alloc || :heap)
      } : consumed_operands
      ownership_contract = MIR::OwnershipContract.consume_operands(operands)
    end
    receiver_mutates = node.mutates_receiver || entry.mutates_receiver?
    target_var = T.let(nil, T.nilable(String))
    if node.is_a?(AST::MethodCall) && receiver_mutates && node.object.respond_to?(:name)
      target_var = extract_root_var_name(node.object)
    elsif receiver_mutates && (first_arg = node.args.first)&.respond_to?(:name)
      target_var = extract_root_var_name(first_arg)
    end
    MIR::RegistryCall.new(
      entry: entry,
      args: registry_call_args(mir_args, stdlib_facts),
      reason: "intrinsic",
      ownership_contract: ownership_contract,
      allocs: alloc_metadata.empty? ? nil : alloc_metadata,
      owned_result_alloc: owned_result_alloc,
      target_var: target_var,
      result_type: result_type,
      result_ownership_bearing: result_ownership_bearing,
      key_type: receiver_type&.key_type,
      value_type: receiver_type&.value_type,
    )
  end

  sig { params(mir_args: T::Array[MIR::Node], stdlib_facts: StdlibCallFacts).returns(T::Array[MIR::RegistryCallArg]) }
  def registry_call_args(mir_args, stdlib_facts)
    facts_by_index = stdlib_facts.args.to_h { |fact| [fact.index, fact] }
    mir_args.each_with_index.map do |arg_mir, index|
      arg_fact = facts_by_index[index]
      MIR::RegistryCallArg.new(expr: arg_mir, coerce_type: arg_fact&.coerce_type)
    end
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall), stdlib_facts: StdlibCallFacts, index: Integer).returns(T.nilable(AST::Node)) }
  def intrinsic_ast_arg(node, stdlib_facts, index)
    fact = stdlib_facts.args[index]
    return fact.ast_arg if fact

    if node.is_a?(AST::MethodCall)
      return node.object if index == 0
      return node.args[index - 1]
    end

    node.args[index]
  end

  sig do
    params(
      mir_args: T::Array[MIR::Node],
      stdlib_facts: StdlibCallFacts,
      ownership_facts: CallOwnershipFacts,
      sink_alloc: Symbol,
      val_alloc_placeholder: T.nilable(Symbol),
    ).returns(StdlibArgumentMaterialization)
  end
  def materialize_stdlib_arguments(mir_args, stdlib_facts, ownership_facts, sink_alloc, val_alloc_placeholder)
    T.bind(self, MIRLowering) rescue nil
    materialized_args = mir_args.dup
    stdlib_facts.args.each do |arg_fact|
      index = arg_fact.index
      next unless ownership_facts.takes?(index)

      placed_arg = place_value_for_destination(
        T.must(materialized_args[index]),
        arg_fact.ast_arg,
        sink_alloc,
        arg_fact.sink_type,
      )
      materialized_args[index] = materialize_owned_sink_value(
        placed_arg,
        arg_fact.ast_arg,
        sink_alloc,
        arg_fact.sink_type,
      )
    end

    materialized_args = materialized_args.each_with_index.map do |arg_mir, index|
      hoist_alloc(
        arg_mir,
        stdlib_facts.ast_arg(index),
        err_cleanup: ownership_facts.takes?(index),
        ownership_materialization_alloc: ownership_facts.takes?(index) ? sink_alloc : nil,
      )
    end if stdlib_facts.args.any?

    consumed_names = ownership_facts.takes_any? ? [] : ownership_facts.consumed_names.dup
    consumed_operands = ownership_facts.takes_any? ? [] : ownership_facts.consumed_operands.dup
    if ownership_facts.takes_any?
      materialized_args.each_with_index do |arg_mir, index|
        next unless ownership_facts.takes?(index)

        operands = ownership_operands_for_lowered_takes_arg(
          arg_mir,
          stdlib_facts.ast_arg(index),
          "stdlib argument #{index}",
          sink_alloc,
          sink_type: stdlib_facts.args[index]&.sink_type,
        )
        consumed_operands.concat(operands)
        operands.each do |operand|
          consumed_names << T.must(operand.name) if operand.kind == :owned_binding && operand.name
        end
      end
      consumed_names.uniq!
      val_alloc_placeholder ||= stdlib_consumed_alloc(consumed_names)
    end

    StdlibArgumentMaterialization.new(
      mir_args: materialized_args,
      consumed_names: consumed_names,
      consumed_operands: consumed_operands,
      val_alloc_placeholder: val_alloc_placeholder,
    )
  end

  sig { params(consumed_names: T::Array[String]).returns(T.nilable(Symbol)) }
  def stdlib_consumed_alloc(consumed_names)
    T.bind(self, MIRLowering) rescue nil
    return nil if consumed_names.empty?

    pending_stmts = function_state.pending_stmts
    allocs = consumed_names.filter_map do |name|
      mark = T.cast(pending_stmts.reverse.find { |stmt| stmt.is_a?(MIR::AllocMark) && stmt.name.to_s == name.to_s }, T.nilable(MIR::AllocMark))
        mark&.alloc || function_state.bindings[name.to_s]&.alloc
    end.uniq
    allocs.length == 1 ? allocs.first : nil
  end

  sig { params(type_info: Type).returns(T::Boolean) }
  def intrinsic_result_ownership_bearing?(type_info)
    T.bind(self, MIRLowering) rescue nil
    ti = type_info.success_type || type_info
    ti = ti.wrapped_type || ti if ti.optional?
    ti.ownership_bearing?(T.unsafe(mir_schema_lookup))
  end

  sig do
    params(
      entry: FunctionSignature,
      node: T.any(AST::FuncCall, AST::MethodCall),
      alloc_metadata: MIR::InlineAllocMetadata,
      result_ownership_bearing: T::Boolean
    ).returns(T.nilable(Symbol))
  end
  def intrinsic_owned_result_alloc(entry, node, alloc_metadata, result_ownership_bearing)
    T.bind(self, MIRLowering) rescue nil
    return nil unless result_ownership_bearing

    alloc = entry.return_alloc
    return nil unless alloc
    return alloc_metadata.primary if entry.emits_allocating? && alloc_metadata.primary
    return alloc if alloc == :heap || alloc == :frame

    resolve_alloc_sym(alloc, nil, node)
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).returns(T.nilable(Type)) }
  def intrinsic_receiver_type(node)
    return nil unless node.is_a?(AST::MethodCall)

    Type.from_node!(node.object, context: "intrinsic receiver")
  end

  sig { params(node: AST::FuncCall).returns(MIR::Node) }
  def lower_extern_call(node)
    T.bind(self, MIRLowering) rescue nil
    return lower_extern_direct_call(node) if node.respond_to?(:extern_effects) && node.extern_effects&.dig(:safe)
    build_extern_trampoline_call(node)
  end

  sig { params(node: AST::MethodCall).returns(MIR::Node) }
  def lower_extern_method(node)
    T.bind(self, MIRLowering) rescue nil
    return lower_extern_direct_method(node) if node.respond_to?(:extern_effects) && node.extern_effects&.dig(:safe)
    build_extern_trampoline_method(node)
  end

  sig { params(node: AST::FuncCall).returns(MIR::Call) }
  def lower_extern_direct_call(node)
    T.bind(self, MIRLowering) rescue nil
    sig = FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    source = node.respond_to?(:extern_source) ? node.extern_source : nil
    args = node.args.each_with_index.map do |arg, index|
      param = sig&.params&.[](index)
      lowered = lower_c_abi_callback_arg(arg, param, source)
      source&.abi == :c && c_abi_param_uses_address?(param) ? MIR::AddressOf.new(lowered) : lowered
    end
    if node.respond_to?(:extern_effects) && (alloc_kind = node.extern_effects&.dig(:alloc))
      rt = MIR::Ident.new(runtime_binding_name)
      alloc_call = alloc_kind == :heap \
        ? MIR::MethodCall.new(rt, "heapAlloc",  [], false, MIR::CallableContract.no_ownership(0)) \
        : MIR::MethodCall.new(rt, "frameAlloc", [], false, MIR::CallableContract.no_ownership(0))
      n_comptime = node.args.count { |a| a.full_type! == :Type }
      args = T.must(args[0, n_comptime]) + [alloc_call] + T.must(args[n_comptime..])
    end
    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    mod_alias = nil if source&.abi == :c
    mod_prefix = mod_alias ? "#{mod_alias.gsub('.', '_')}." : ""
    callee_name = source&.symbol || node.name
    MIR::Call.new(
      "#{mod_prefix}#{callee_name}",
      args,
      false,
      call_owned_return?(node),
      callable_contract_for(sig, node.args),
    )
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
  sig { params(ast_arg: AST::Node).returns(MIR::Node) }
  def lower_extern_arg(ast_arg)
    T.bind(self, MIRLowering) rescue nil
    mir = lower(ast_arg)
    if MIR.const_u8_literal_cast?(mir)
      mir.expr
    else
      mir
    end
  end

  sig { params(node: AST::FuncCall).returns(MIR::ExternTrampoline) }
  def build_extern_trampoline_call(node)
    T.bind(self, MIRLowering) rescue nil
    id = lowering_counters.next_extern_id
    alloc_kind = node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil
    mod_alias = T.unsafe(node).module_alias if node.respond_to?(:module_alias)
    source = node.respond_to?(:extern_source) ? node.extern_source : nil
    mod_alias = nil if source&.abi == :c

    # Separate comptime type args (full_type == :Type) from runtime args.
    # Comptime args can't be struct fields; the emitter renders them directly
    # at the call site after MIRChecker has seen the expression children.
    comptime_args, runtime_ast_args = node.args.partition { |a| a.full_type! == :Type }
    comptime_mir = comptime_args.map { |a| lower_extern_arg(a) }

    sig = fn_sig_for(node.name)
    sig_params = sig ? sig.params.reject { |p| p.comptime } : []
    args = runtime_ast_args.each_with_index.map do |arg, index|
      param = sig_params[index]
      lowered = lower_c_abi_callback_arg(arg, param, source)
      source&.abi == :c && c_abi_param_uses_address?(param) ? MIR::AddressOf.new(lowered) : lowered
    end

    # Use declared scalar param types for struct fields to avoid comptime_int
    # (e.g. @TypeOf(19876)). For module externs, keep non-scalars inferred:
    # their CLEAR types (e.g. String -> []const u8) may differ from the actual
    # Zig/C types (e.g. [*:0]const u8), breaking implicit coercions.
    args_with_types = args.each_with_index.map do |arg, i|
      p = sig_params[i]
      field_type = nil
      field_zig_type = nil
      if p && source&.abi == :c
        field_zig_type = c_abi_param_zig_type(p)
      elsif p
        pt = p.type
        type_obj = pt.is_a?(Type) ? pt : Type.new(pt)
        if sig&.module_alias
          resolved = type_obj.resolved
          type_obj = nil unless type_obj.numeric? || resolved == :Bool || resolved == :Boolean
        end
        field_type = type_obj if type_obj
      end
      MIR::ExternTrampolineArg.new(expr: arg, field_type: field_type, field_zig_type: field_zig_type)
    end

    return_type = extern_trampoline_return_type(node, sig)
    MIR::ExternTrampoline.new(
      id: id.value,
      callee_name: (source&.symbol || node.name).to_s,
      module_alias: mod_alias,
      comptime_args: comptime_mir,
      runtime_args: args_with_types,
      alloc_kind: alloc_kind,
      return_type: return_type,
      stdlib_def: extern_trampoline_stdlib_def(return_type, alloc_kind, node),
    )
  end

  sig { params(node: AST::MethodCall).returns(MIR::ExternTrampoline) }
  def build_extern_trampoline_method(node)
    T.bind(self, MIRLowering) rescue nil
    id = lowering_counters.next_extern_id
    obj = T.cast(lower(node.object), MIR::Emittable)
    args = node.args.map { |a| MIR::ExternTrampolineArg.new(expr: lower_extern_arg(a)) }
    signature = FunctionSignature.unwrap(node.matched_signature) if node.respond_to?(:matched_signature)
    return_type = extern_trampoline_return_type(node, signature)
    MIR::ExternTrampoline.new(
      id: id.value,
      callee_name: node.name.to_s,
      method_name: node.name.to_s,
      receiver: obj,
      runtime_args: args,
      alloc_kind: node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil,
      return_type: return_type,
      stdlib_def: extern_trampoline_stdlib_def(return_type, node.respond_to?(:extern_effects) ? node.extern_effects&.dig(:alloc) : nil, node),
    )
  end

  sig { params(node: AST::Node, signature: T.nilable(FunctionSignature)).returns(Type) }
  def extern_trampoline_return_type(node, signature)
    expression_type = node.full_type!
    return expression_type unless signature&.return_type&.error_union?
    return expression_type if expression_type.error_union?

    # OR_ELSE/RAISE unwraps the expression for its CLEAR consumer, but the
    # root-stack trampoline still calls the original fallible foreign ABI.
    Type.error_union_of(expression_type)
  end

  sig { params(return_type: Type, alloc_kind: T.nilable(Symbol), ast_node: AST::Node).returns(FunctionSignature) }
  def extern_trampoline_stdlib_def(return_type, alloc_kind, ast_node)
    payload_t = return_type.error_union? ? T.must(return_type.payload_type) : return_type
    ast_symbol = ast_node.respond_to?(:symbol) ? ast_node.public_send(:symbol) : nil
    is_heap = !payload_t.c_string? && (
      alloc_kind == :heap ||
      ast_symbol&.heap_storage? == true ||
      payload_t.heap?
    )
    is_heap ? FunctionSignature.allocating_intrinsic : FunctionSignature.borrowing_intrinsic
  end

  sig { params(param: T.nilable(AST::Param)).returns(T::Boolean) }
  def c_abi_param_uses_address?(param)
    return false unless param

    type = Type.new(param.type)
    param.mutable == true || (type.array? && type.fixed? == true && !type.string?)
  end

  sig { params(param: AST::Param).returns(String) }
  def c_abi_param_zig_type(param)
    type = Type.new(param.type)
    zig_type = type.zig_type(is_param: true)
    if type.array? && type.fixed? && !type.string?
      return "#{param.mutable ? "*" : "*const "}#{zig_type}"
    end
    param.mutable ? "*#{zig_type}" : zig_type
  end

  sig { params(arg: AST::Node, param: T.nilable(AST::Param), source: T.nilable(Schemas::ExternSource)).returns(MIR::Node) }
  def lower_c_abi_callback_arg(arg, param, source)
    lowered = lower_extern_arg(arg)
    return lowered unless source&.abi == :c && param

    type = Type.new(param.type)
    signature = type.function_type
    return lowered unless signature&.abi == :c

    clear_function = lowered.is_a?(MIR::AddressOf) ? lowered.expr : lowered
    MIR::CFunctionAdapter.new(clear_function: clear_function, signature: T.must(signature))
  end
  # ================================================================
  # Lambda
  # ================================================================

  sig { params(node: AST::LambdaLit).returns(MIR::LambdaExpr) }
  def lower_lambda(node)
    T.bind(self, MIRLowering) rescue nil
    sig = node.full_type!
    sig = T.must(sig.function_signature) if sig.is_a?(Type)
    fn_name = "_lambda_#{lowering_counters.next_lambda_id}"

    params_list = T.unsafe(sig).params
    params_mir = T.let([MIR::Param.new("_rt", "*Runtime", false)] + params_list.map { |p|
      p_type = p.type
      type_str = p_type.is_a?(Type) ? p_type.zig_type(is_param: true) : transpile_type(p_type || :Any, is_param: true)
      pt_obj = p_type.is_a?(Type) ? p_type : (Type.new(p_type) rescue nil)
      pp = !!(pt_obj && (pt_obj.respond_to?(:needs_pointer_passing?) && pt_obj.needs_pointer_passing? ||
                         (p.mutable && pt_obj.respond_to?(:list_collection?) && pt_obj.list_collection?)))
      MIR::Param.new(p.name, type_str, pp)
    }, T::Array[MIR::Param])

    return_type_zig = T.unsafe(sig).return_type.zig_type
    ret_str = ZigType.new(return_type_zig).anyerror_return_type

    # Build body: suppressions + body prefix + implicit final expression return.
    body_mir = []
    body_mir << MIR::Suppress.new("_rt")
    params_list.each { |p| body_mir << MIR::Suppress.new(p.name) }
    body_nodes = AST.lambda_body_nodes(node.body)
    prefix_nodes = body_nodes[0...-1] || []
    body_mir.concat(lower_body(prefix_nodes))
    return_expr = T.must(body_nodes.last)
    lambda_return = AST::ReturnNode.new(return_expr.respond_to?(:token) ? T.unsafe(return_expr).token : nil, return_expr)
    body_mir.concat(hoist_unhoisted_return_allocs(
      [MIR::ReturnStmt.new(lower(return_expr))],
      [lambda_return],
    ))
    # Lambda bodies are nested functions, not ordinary expression children of
    # the enclosing routine. Run the same allocation normalization and
    # ownership finalization that a top-level function body receives so an
    # owned/fallible final expression is hoisted inside the lambda rather than
    # leaking an unhoisted BlockExpr or TryExpr into its ReturnStmt.
    body_mir = append_ownership_transfers_for_mir_body(body_mir)

    fn_def = MIR::FnDef.new(fn_name, params_mir, ret_str, body_mir, nil, false, nil)
    captures = node.captures&.map { |c|
      if c.respond_to?(:name)
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

  private :build_catch_clauses,
    :build_extern_trampoline_call,
    :build_extern_trampoline_method,
    :call_owned_return?,
    :collect_catch_reassigns

  private :activate_function_context
  private :ast_expr_produces_heap?
  private :attach_explicit_move_consumption!
  private :body_has_faulting_alloc?
  private :borrowed_array_argument_required?
  private :borrowed_ownership_operand?
  private :build_post_inner_fn
  private :build_post_outer_fn
  private :call_never_returns_success?
  private :call_owned_return_from_args?
  private :call_type_owned_return?
  private :c_abi_param_uses_address?
  private :c_abi_param_zig_type
  private :extern_trampoline_return_type
  private :concrete_call_type_owned_return?
  private :cross_boundary_arg
  private :empty_stdlib_call_facts
  private :faulting_return_type_str
  private :finalize_call_result
  private :finalized_needs_rt!
  private :function_body_has_value_return?
  private :function_catch_clauses
  private :function_entry_plan
  private :function_lowering_context
  private :function_param_fact
  private :function_param_facts
  private :function_param_zig_type
  private :inject_protocol_map_allocator_args
  private :protocol_map_allocator_for
  private :protocol_map_allocator_name
  private :protocol_map_signature_param?
  private :lower_protocol_map_put_call
  private :function_return_retains_shared_handle?
  private :has_default_catch?
  private :infer_catch_value_allocator
  private :intrinsic_ast_arg
  private :intrinsic_owned_result_alloc
  private :intrinsic_result_ownership_bearing?
  private :lower_extern_call
  private :lower_extern_direct_call
  private :lower_extern_direct_method
  private :lower_extern_method
  private :lower_c_abi_callback_arg
  private :lower_intrinsic
  private :lower_safe_nav_method_call
  private :materialize_stdlib_arguments
  private :mutable_scalar_param_shadows
  private :owned_slice_argument_required?
  private :ownership_consumed_arg_names
  private :record_lowered_entry_markers!
  private :recursion_yield_prologue
  private :reentrance_guard_prologue
  private :registry_call_args
  private :runtime_frame_prologue
  private :runtime_frame_save_required?
  private :stdlib_call_facts
  private :stdlib_coerce_type
  private :stdlib_consumed_alloc
  private :stdlib_sink_type_for_arg
  private :takes_param_ownership_mir
  private :typed_name_set
  private :unused_param_suppressions
  private :walk_catch_body_for_reassigns

end
