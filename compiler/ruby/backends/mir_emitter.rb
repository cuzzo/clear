# typed: strict
# src/backends/mir_emitter.rb -- MIR -> Zig template engine.
#
# CONTRACT: This file is a pure template engine. Each MIR node type maps to
# exactly one fixed Zig text fragment. There is no ownership logic, no
# allocator decisions, no type introspection. Every choice (which allocator,
# which cleanup strategy, defer vs errdefer) was made by the lowering pass
# and is encoded structurally in the MIR node type or its pre-computed fields.
#
# THE MOMENT this file makes a decision not already secured by the MIRChecker,
# the system is unsafe. Unverified emitter logic is silent corruption:
# double-frees, leaks, and use-after-frees with no compile-time signal.
#
# Node -> Zig template mapping (ownership nodes):
#   MIR::Cleanup(name, entry)    -> defer [if (!name_moved)] cleanup(name)
#   MIR::ErrCleanup(name, entry) -> errdefer cleanup(name)
#   MIR::MoveMark(name)          -> name_moved = true;
#   MIR::AllocMark               -> (no Zig emitted; checker marker only)
#
# IMPORTANT: This file must NOT require type.rb, annotator.rb, scope.rb,
# or any analysis module. It depends only on mir.rb.

require "sorbet-runtime"

require_relative "../ast/error_registry"
require_relative "../mir/mir"
require_relative "../mir/cleanup_entry"
require_relative "../mir/placement"
require_relative "zig_type"

class MIREmitter
    extend T::Sig

  # Public boundary accepts Object so the explicit unknown-node diagnostic below
  # runs instead of Sorbet's runtime signature error.
  EmitInput = T.type_alias { T.nilable(T.any(Object, MIR::Emittable)) }
  ShardedMapNode = T.type_alias { T.any(MIR::ShardedMapPut, MIR::ShardedMapGet) }

  sig { returns(String) }
  attr_accessor :rt_name

  THUNK_COMBINE_OPERATOR = T.let({
    ADD: "+",
    SUB: "-",
    MUL: "*",
    DIV: "/",
  }.freeze, T::Hash[Symbol, String])

  sig { void }
  def initialize
    @indent = T.let(0, Integer)
    @rt_name = T.let("rt", String)
    @flow_alias_name = T.let(nil, T.nilable(String))
    @if_bind_counter = T.let(nil, T.nilable(Integer))
    @discard_counter = T.let(0, Integer)
    @symbol_literals = T.let({}, T::Hash[String, String])
  end

  # Emit Zig code from a structural MIR node. Returns a String.
  sig { params(node: EmitInput).returns(T.nilable(String)) }
  def emit(node)
    case node
    when nil    then ""
    when String
      raise "MIREmitter cannot emit raw Zig strings; use a structural MIR node"

    # --- Top-level ---
    when MIR::Program     then emit_program(node)
    when MIR::FnDef       then emit_fn_def(node)
    when MIR::StructDef   then emit_struct_def(node)
    when MIR::EnumDef     then emit_enum_def(node)
    when MIR::UnionTypeDef then emit_union_def(node)
    when MIR::Import      then emit_import(node)
    when MIR::TypeAlias   then emit_type_alias(node)
    when MIR::ModuleNamespace then emit_module_namespace(node)
    when MIR::TestDef     then emit_test_def(node)

    # --- Statements ---
    when MIR::Let              then emit_let(node)
    when MIR::Set              then emit_set(node)
    when MIR::DestructureSet   then emit_destructure_set(node)
    when MIR::ReassignWithCleanup then emit_reassign_cleanup(node)
    when MIR::IfStmt           then emit_if_stmt(node)
    when MIR::IfBindStmt       then emit_if_bind_stmt(node)
    when MIR::WhileStmt        then emit_while(node)
    when MIR::ForStmt          then emit_for(node)
    when MIR::SwitchStmt       then emit_switch(node)
    when MIR::UnionMatchStmt   then emit_union_match(node)
    when MIR::IfChain          then emit_if_chain(node)
    when MIR::ReturnStmt       then emit_return(node)
    when MIR::BreakStmt        then emit_break(node)
    when MIR::ContinueStmt     then "continue;"
    when MIR::Panic            then "@panic(#{node.message.inspect});"
    when MIR::AssertStmt       then emit_assert_stmt(node)
    when MIR::AssertRaisesCheck then emit_assert_raises_check(node)
    when MIR::TestPreamble     then emit_test_preamble
    when MIR::DebugOnly        then emit_debug_only(node)
    when MIR::Sort             then emit_sort(node)
    when MIR::SoaFieldAccess   then "#{emit(node.soa_expr)}.data.items(.#{node.field_name})"
    when MIR::TryOrPanic       then "#{emit(node.expr)} catch @panic(#{node.panic_msg.inspect})"
    when MIR::IndexInsert      then emit_index_insert(node)
    when MIR::BatchWindowPush  then emit_batch_window_push(node)
    when MIR::BatchWindowFlush then emit_batch_window_flush(node)
    when MIR::ThunkTrampoline  then emit_thunk_trampoline(node)
    when MIR::MutualThunkTrampoline then emit_mutual_thunk_trampoline(node)
    when MIR::DeferStmt        then emit_defer(node)
    when MIR::ErrDeferStmt     then emit_errdefer(node)
    when MIR::ExprStmt         then emit_expr_stmt(node)
    when MIR::DiscardOwned     then emit_discard_owned(node)
    when MIR::ScopeBlock        then emit_scope_block(node)
    when MIR::Pipeline         then emit(node.inner)
    when MIR::BgBlock          then emit_bg_block(node)
    when MIR::ShardConcurrentEach then emit_shard_concurrent_each(node)
    when MIR::DoBlock          then emit_do_block(node)
    when MIR::CatchWrapper     then emit_catch_wrapper(node)
    when MIR::Comment          then "// #{node.text}"
    when MIR::Suppress         then "_ = &#{node.name};"
    when MIR::PubConst         then "pub const #{node.name} = #{node.value};"

    # --- Memory operations ---
    when MIR::HeapCreate       then emit_heap_create(node)
    when MIR::DupeSlice        then emit_dupe_slice(node)
    when MIR::AllocSlice       then emit_alloc_slice(node)
    when MIR::FreeSlice        then emit_free_slice(node)
    when MIR::DestroyPtr       then emit_destroy_ptr(node)
    when MIR::Cleanup          then emit_cleanup(node)
    when MIR::ErrCleanup       then emit_cleanup(node, errdefer: true)
    when MIR::MoveMark         then emit_move_mark(node)
    when MIR::DeepCopy         then emit_deep_copy(node)
    when MIR::ContainerInit    then emit_container_init(node)
    when MIR::CapWrap          then emit_cap_wrap(node)
    when MIR::SharePromote     then emit_share_promote(node)
    when MIR::RcRetain         then emit_rc_retain(node)
    when MIR::RcRelease        then emit_rc_release(node)
    when MIR::RcDowngrade      then emit_rc_downgrade(node)
    when MIR::WeakUpgrade      then emit_weak_upgrade(node)
    when MIR::FreezeExpr       then emit_freeze(node)
    when MIR::MakeList         then emit_make_list(node)
    when MIR::FrameSave        then emit_frame_save(node)
    when MIR::FrameRestore     then emit_frame_restore(node)
    # --- MVCC SNAPSHOT / WITH MATCH (structured, MIR-checker-visible) ---
    when MIR::SnapshotRead         then emit_snapshot_read(node)
    when MIR::SnapshotTransaction  then emit_snapshot_transaction(node)
    when MIR::SnapshotMultiTxn     then emit_snapshot_multi_txn(node)
    when MIR::PolymorphicMutate    then emit_polymorphic_mutate(node)
    when MIR::PolymorphicMutateFlow then emit_polymorphic_mutate_flow(node)
    when MIR::WithMatchDispatch    then emit_with_match_dispatch(node)
    when MIR::SortedLockAcquire    then emit_sorted_lock_acquire(node)
    when MIR::FallibleLockBinding  then emit_fallible_lock_binding(node)
    # --- Verification-only (no codegen) ---
    when MIR::Noop, MIR::AllocMark, MIR::ReturnMark, MIR::TransferMark, MIR::ReassignMark, MIR::FieldCleanupMark,
         MIR::OwnedCreate, MIR::OwnedDestroy, MIR::OwnedTransfer, MIR::OwnedBorrow, MIR::OwnedStore, MIR::OwnedReturn
      nil

    # --- Expressions ---
    when MIR::Call             then emit_call(node)
    when MIR::RuntimeCall      then emit_runtime_call(node)
    when MIR::TailCall         then emit_tail_call(node)
    when MIR::MethodCall       then emit_method_call(node)
    when MIR::FieldGet         then emit_field_get(node)
    when MIR::UnionPayloadGet  then emit_union_payload_get(node)
    when MIR::IndexGet         then emit_index_get(node)
    when MIR::BinOp            then emit_bin_op(node)
    when MIR::FallibleOk       then "if (#{emit(node.expr)}) |_| true else |_| false"
    when MIR::FutureReady      then "#{emit(node.expr)}.isReady()"
    when MIR::UnaryOp          then emit_unary_op(node)
    when MIR::Lit              then node.value.to_s
    when MIR::SymbolLit        then symbol_literal_name(node.value.to_s)
    when MIR::VoidLiteral      then "{}"
    when MIR::DefaultValue     then emit_default_value(node)
    when MIR::EnumTag          then ".#{node.variant}"
    when MIR::EnumOrdinal      then "@intFromEnum(#{emit(node.value)})"
    when MIR::Ident            then node.name
    when MIR::DestructureTarget then emit_destructure_target(node)
    when MIR::TupleLiteral     then emit_tuple_literal(node)
    when MIR::CapabilityUnwrap then emit_capability_unwrap(node)
    when MIR::CapabilityLockTarget then emit_capability_lock_target(node)
    when MIR::CapabilityLockAddress then emit_capability_lock_address(node)
    when MIR::FnRef            then "&#{node.name}"
    when MIR::LockAcquire      then emit_lock_acquire(node)
    when MIR::TypeOf           then "@TypeOf(#{emit(node.expr)})"
    when MIR::TypeEq           then "(#{emit(node.left)} == #{emit(node.right)})"
    when MIR::StructInit       then emit_struct_init(node)
    when MIR::ArrayInit        then emit_array_init(node)
    when MIR::ArrayDefaultInit then emit_array_default_init(node)
    when MIR::SliceExpr        then emit_slice_expr(node)
    when MIR::BlockExpr        then emit_block_expr(node)
    when MIR::ConcatStr        then emit_concat(node)
    when MIR::Cast             then emit_cast(node)
    when MIR::TryExpr          then "try #{emit(node.expr)}"
    when MIR::TryCatch         then emit_try_catch(node)
    when MIR::BreakExpr        then emit_break_expr(node)
    when MIR::Orelse           then emit_orelse(node)
    when MIR::Conditional      then emit_conditional(node)
    when MIR::IfOptional       then emit_if_optional(node)
    when MIR::Comptime         then "comptime #{emit(node.expr)}"
    when MIR::UnionVariantGet  then "#{paren_if_try(T.must(emit(node.object)))}.#{node.variant}"
    when MIR::ListItems        then "#{paren_if_try(T.must(emit(node.list)))}.items"
    when MIR::ListLength       then "#{paren_if_try(T.must(emit(node.expr)))}.len"
    when MIR::AddressOf        then "&#{emit(node.expr)}"
    when MIR::Deref            then "#{emit(node.expr)}.*"
    when MIR::PointerCast      then emit_pointer_cast(node)
    when MIR::ConstCast        then "@constCast(#{emit(node.expr)})"
    when MIR::DefaultStreamCapacity then emit_default_stream_capacity(node)
    when MIR::NextPromiseList  then emit_next_promise_list(node)
    when MIR::OptionalUnwrap   then "#{emit(node.expr)}.?"
    when MIR::AllocatorRef     then emit_allocator_ref(node)
    when MIR::Undef            then node.zig_type ? "@as(#{node.zig_type}, undefined)" : "undefined"
    when MIR::TypeSentinel     then emit_type_sentinel(node)
    when MIR::IterRange        then "#{emit(node.start)}..#{emit(node.end_val)}"
    when MIR::RangeLit         then emit_range_lit(node)
    when MIR::HasField         then emit_has_field(node)
    when MIR::ItemsAccess      then emit_items_access(node)
    when MIR::OwnedSlice       then emit_owned_slice(node)
    when MIR::LambdaExpr       then emit_lambda(node)
    when MIR::RegistryCall     then emit_registry_call(node)
    when MIR::IndexedStore     then emit_indexed_store(node)
    when MIR::ExternTrampoline then emit_extern_trampoline(node)
    when MIR::ObservableConsumerSpawn then emit_observable_consumer_spawn(node)
    when MIR::InlineBc         then emit_inline_bc_as_zig(node)
    when MIR::ShardedMapPut    then emit_sharded_map_put(node)
    when MIR::ShardedMapGet    then emit_sharded_map_get(node)

    else
      raise "MIREmitter: unknown node type #{node.class}"
    end
  end

  sig { params(node: MIR::BgBlock).returns(String) }
  def emit_bg_block(node)
    plan = node.code
    return emit_bg_stackful_plan(plan) if plan.is_a?(MIR::BgStackfulPlan)
    return emit_bg_stream_plan(plan) if plan.is_a?(MIR::BgStreamPlan)
    return emit_fsm_bg_body(T.cast(plan, T.any(MIR::FsmIoBody, MIR::FsmB1Body, MIR::FsmGenericBody))) if fsm_bg_body_plan?(plan)

    raise "MIR::BgBlock must carry a structural emission plan, got #{plan.class}"
  end

  sig { params(plan: MIR::BgStackfulPlan).returns(String) }
  def emit_bg_stackful_plan(plan)
    run_body_raw = emit_body_with_runtime(plan.run_body, plan.bg_rt)
    capture_frees_raw = emit_capture_cleanup_actions_with_runtime(plan.capture_frees, plan.bg_rt)
    arena_init_raw = T.let(plan.arena_init ? emit_node_with_runtime(T.must(plan.arena_init), plan.bg_rt) : "", String)
    run_body_code = run_body_raw.gsub("\n", "\n                  ")
    promoted_decls = emit_body(plan.promoted_decls).gsub("\n", "\n          ")
    capture_fields = emit_context_field_decls(plan.capture_fields).gsub("\n", "\n              ")
    capture_inits = emit_struct_init_fields(plan.capture_inits)
    capture_frees = capture_frees_raw.gsub("\n", "\n                  ")
    arena_init = arena_init_raw
    spawn_call = emit_fiber_spawn_call(plan.spawn_call).gsub("\n", "\n          ")
    alloc_expr = T.must(emit(plan.alloc_expr))
    profile_comment = emit_profile_task_site(plan.profile_site)
    suppress_line = bg_stackful_runtime_suppress_line(plan, run_body_raw, capture_frees_raw, arena_init_raw)
    <<~ZIG.chomp
      #{plan.blk_label}: {
          #{profile_comment}
          const #{plan.ctx_type} = struct {
              inner: *#{plan.promise_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_#{plan.id}: *anyopaque, __raw_args_#{plan.id}: ?*anyopaque) anyerror!void {
                  const #{plan.bg_rt} = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_#{plan.id})));
                  #{suppress_line}
                  #{arena_init}
                  const __ctx_#{plan.id} = @as(*@This(), @ptrCast(@alignCast(__raw_args_#{plan.id}.?)));
                  defer __ctx_#{plan.id}.alloc.destroy(__ctx_#{plan.id});
                  defer __ctx_#{plan.id}.inner.wg.done();
                  errdefer |fiber_err| __ctx_#{plan.id}.inner.result = fiber_err;
                  #{capture_frees}
                  #{run_body_code}
                  #{plan.is_void ? "__ctx_#{plan.id}.inner.result = {};" : ""}
              }
          };
          const #{plan.alloc_var} = #{alloc_expr};
          const #{plan.promise_var} = try #{plan.promise_zig}.spawn(#{plan.alloc_var}, #{plan.rt_name}.getSched());
          #{promoted_decls}
          const #{plan.ctx_var} = try #{plan.alloc_var}.create(#{plan.ctx_type});
          errdefer #{plan.alloc_var}.destroy(#{plan.ctx_var});
          #{plan.ctx_var}.* = .{ #{capture_inits} };
          #{spawn_call}
          break :#{plan.blk_label} #{plan.promise_var};
      }
    ZIG
  end

  sig { params(plan: MIR::BgStackfulPlan, run_body_code: String, capture_frees: String, arena_init: String).returns(String) }
  def bg_stackful_runtime_suppress_line(plan, run_body_code, capture_frees, arena_init)
    text = run_body_code + capture_frees + arena_init
    text.include?(plan.bg_rt) ? "" : "_ = &#{plan.bg_rt};"
  end

  sig { params(plan: T.untyped).returns(T::Boolean) }
  def fsm_bg_body_plan?(plan)
    plan.is_a?(MIR::FsmIoBody) || plan.is_a?(MIR::FsmB1Body) || plan.is_a?(MIR::FsmGenericBody)
  end

  sig { params(plan: T.any(MIR::FsmIoBody, MIR::FsmB1Body, MIR::FsmGenericBody)).returns(String) }
  def emit_fsm_bg_body(plan)
    require_relative "fsm_wrapper_emitter" unless defined?(FsmWrapperEmitter)
    FsmWrapperEmitter.render(plan)
  end

  sig { params(plan: MIR::BgStreamPlan).returns(String) }
  def emit_bg_stream_plan(plan)
    body_code = emit_body_with_runtime(plan.body, "__rt").gsub("\n", "\n                  ")
    promoted_decls = emit_body_with_runtime(plan.promoted_decls, "__rt").gsub("\n", "\n          ")
    capture_cleanups = emit_body_with_runtime(plan.capture_cleanups, "__rt").gsub("\n", "\n                  ")
    capture_fields = emit_context_field_decls(plan.capture_fields).gsub("\n", "\n              ")
    capture_inits = emit_struct_init_fields(plan.capture_inits)
    spawn_call = emit_fiber_spawn_call(plan.spawn_call).gsub("\n", "\n          ")
    rt_suppress = body_code.include?("__rt") ? "" : "_ = &__rt;"
    <<~ZIG.chomp
      #{plan.blk_label}: {
          const #{plan.ctx_type} = struct {
              stream_inner: *#{plan.stream_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_sg#{plan.id}: *anyopaque, __raw_args_sg#{plan.id}: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_sg#{plan.id})));
                  #{rt_suppress}
                  const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_sg#{plan.id}.?)));
                  defer ctx.alloc.destroy(ctx);
                  #{capture_cleanups}
                  var #{plan.local_stream} = #{plan.stream_zig}{ .inner = ctx.stream_inner, .alloc = ctx.alloc };
                  defer #{plan.local_stream}.close();
                  errdefer |gen_err| #{plan.local_stream}.inner.err = gen_err;
                  #{body_code}
              }
          };
          const #{plan.alloc_var} = #{plan.rt_name}.getSched().allocator;
          const #{plan.stream_var} = try #{plan.stream_zig}.spawnNew(#{plan.alloc_var}, #{plan.rt_name}.getSched());
          #{promoted_decls}
          const #{plan.ctx_var} = try #{plan.alloc_var}.create(#{plan.ctx_type});
          errdefer #{plan.alloc_var}.destroy(#{plan.ctx_var});
          #{plan.ctx_var}.* = .{ #{capture_inits} };
          #{spawn_call}
          break :#{plan.blk_label} #{plan.stream_var};
      }
    ZIG
  end

  sig { params(node: MIR::DoBlock).returns(String) }
  def emit_do_block(node)
    plan = node.code
    return emit_do_block_plan(plan) if plan.is_a?(MIR::DoBlockPlan)

    raise "MIR::DoBlock must carry a structural emission plan, got #{plan.class}"
  end

  sig { params(plan: MIR::DoBlockPlan).returns(String) }
  def emit_do_block_plan(plan)
    branches = plan.branches.map { |branch| emit_do_branch_plan(branch) }.join("\n")
    <<~ZIG.chomp
      {
          var #{plan.wg_var} = CheatHeader.WaitGroup.init(#{@rt_name}.getSched());
          errdefer #{plan.wg_var}.wait();
          #{branches}
      #{plan.wg_var}.wait();
      }
    ZIG
  end

  sig { params(plan: MIR::DoBranchPlan).returns(String) }
  def emit_do_branch_plan(plan)
    body_code = emit_body_with_runtime(plan.body, "__rt").gsub("\n", "\n        ")
    capture_pre_decls = emit_body_with_runtime(plan.capture_pre_decls, "__rt").gsub("\n", "\n        ")
    capture_fields = emit_context_field_decls(plan.capture_fields).gsub("\n", "\n      ")
    capture_inits = emit_struct_init_fields(plan.capture_inits)
    spawn_call = emit_fiber_spawn_call(plan.spawn_call).gsub("\n", "\n    ")
    rt_suppress = body_code.include?("__rt") ? "" : "_ = &__rt;"
    <<~ZIG.chomp
      const #{plan.ctx_type} = struct {
          wg: *CheatHeader.WaitGroup,
          #{capture_fields}
          fn run(#{plan.raw_rt_name}: *anyopaque, #{plan.raw_args_name}: ?*anyopaque) anyerror!void {
              const __rt = @as(*Runtime, @ptrCast(@alignCast(#{plan.raw_rt_name})));
              #{rt_suppress}
              const ctx = @as(*@This(), @ptrCast(@alignCast(#{plan.raw_args_name}.?)));
              defer ctx.wg.done();
              #{body_code}
          }
      };
      #{capture_pre_decls}
      var #{plan.ctx_var} = #{plan.ctx_type}{ #{capture_inits} };
      #{spawn_call}
      #{plan.wg_var}.add(1);
    ZIG
  end

  sig { params(fields: T::Array[MIR::ContextFieldDecl]).returns(String) }
  def emit_context_field_decls(fields)
    fields.map do |field|
      default = field.default_value ? " = #{emit(T.must(field.default_value))}" : ""
      "#{field.name}: #{field.type_zig}#{default},"
    end.join("\n")
  end

  sig { params(fields: T::Array[MIR::StructInitField]).returns(String) }
  def emit_struct_init_fields(fields)
    fields.map do |field|
      ".#{field.name} = #{emit(field.value)}"
    end.join(", ")
  end

  sig { params(actions: T::Array[MIR::CaptureCleanupAction]).returns(String) }
  def emit_capture_cleanup_actions(actions)
    actions.map do |action|
      allocator = action.allocator ? emit(T.must(action.allocator)) : nil
      "defer #{emit_direct_cleanup(T.must(emit(action.target)), action.cleanup_entry, alloc_override: allocator)}"
    end.join("\n")
  end

  sig { params(site: MIR::ProfileTaskSite).returns(String) }
  def emit_profile_task_site(site)
    "// CLEAR_PROFILE_TASK_SITE id=#{site.site_id} kind=BG line=#{site.line} column=#{site.column} dispatch=#{site.dispatch} form=#{site.form}"
  end

  sig { params(plan: MIR::TaskConfigPlan).returns(String) }
  def emit_task_config_plan(plan)
    fields = [".stack_size = .#{plan.stack_variant}"]
    fields << ".profile_site_id = #{plan.profile_site_id}" if plan.profile_site_id
    fields << ".profile_dispatch = #{plan.profile_dispatch_id}" if plan.profile_dispatch_id
    ".{ #{fields.join(', ')} }"
  end

  sig { params(call: MIR::FiberSpawnCall).returns(String) }
  def emit_fiber_spawn_call(call)
    callee = case call.target
             when :runtime_submit
               runtime_name = call.runtime_name || raise("FiberSpawnCall runtime_name required")
               "try #{runtime_name}.getSched().submitSpawn"
             when :pinned
               "try CheatHeader.spawnPinned"
             when :best
               "try CheatHeader.spawnBest"
             when :wait_group_submit
               wait_group_name = call.wait_group_name || raise("FiberSpawnCall wait_group_name required")
               "try #{wait_group_name}.sched.submitSpawn"
             else
               raise "unknown FiberSpawnCall target #{call.target.inspect}"
             end
    task_cfg = emit_task_config_plan(call.task_config)
    ctx_arg = call.pass_ctx_by_address ? "&#{call.ctx_var}" : call.ctx_var
    <<~ZIG.chomp
      #{callee}(
          @intFromPtr(&Runtime.entryWrapper),
          @as(CheatHeader.TaskFn, @ptrCast(&#{call.ctx_type}.run)),
          #{ctx_arg},
          #{task_cfg}
      );
    ZIG
  end

  # InlineBc nodes are the :bc-target stdlib intrinsic carrier. In the Zig emitter
  # we only see them when a :bc-target lowering pipeline (e.g. bc_run.rb) still
  # routes through a Zig-producing lowering step that calls emit_expr. Fall
  # back to the Zig template from the registry so emission completes.
  sig { params(node: MIR::InlineBc).returns(String) }
  def emit_inline_bc_as_zig(node)
    entry = node.stdlib_def
    raise "emit_inline_bc_as_zig: node has no stdlib_def (:#{node.op})" unless entry
    pattern = entry.required_intrinsic_template(IntrinsicTemplateKind::Zig)
    node.args.each_with_index { |a, i| pattern = pattern.gsub("{#{i}}") { emit(a) } }
    pattern
  end

  # Emit Zig source for a sharded HashMap put. Picks the template based
  # on dispatch mode: shard_idx non-nil means we're inside a SHARD body
  # and use putDirect; otherwise pick sharded_zig (when the receiver
  # type is sharded/striped) or default zig. Substitutes positional
  # placeholders, allocator placeholders, and shard-direct identifiers.
  sig { params(node: MIR::ShardedMapPut).returns(String) }
  def emit_sharded_map_put(node)
    pattern = sharded_map_template(node).dup
    pattern = pattern
      .gsub("{target}", emit(node.target))
      .gsub("&{target}", "&#{emit(node.target)}")
      .gsub("{index}", emit(node.key))
      .gsub("{value}", emit(node.value))
    sharded_map_substitute_common(pattern, node)
  end

  sig { params(node: MIR::ShardedMapGet).returns(String) }
  def emit_sharded_map_get(node)
    pattern = sharded_map_template(node).dup
    pattern = pattern
      .gsub("{target}", emit(node.target))
      .gsub("{index}", emit(node.key))
    sharded_map_substitute_common(pattern, node)
  end

  # Pick the Zig template the lowering committed to. template_kind is
  # set on the node by mir_lowering after inspecting shard_context and
  # the receiver type.
  sig { params(node: ShardedMapNode).returns(T.untyped) }
  def sharded_map_template(node)
    op = node.stdlib_def
    kind = node.template_kind || IntrinsicTemplateKind::Zig
    op.intrinsic_template(kind) or raise "ShardedMap: op has no :#{kind.serialize} template (contract=#{op.intrinsic_contract.inspect})"
  end

  sig { params(pattern: String, node: ShardedMapNode).returns(String) }
  def sharded_map_substitute_common(pattern, node)
    if node.shard_idx
      pattern = pattern
        .gsub("{shard_idx}", T.must(emit(node.shard_idx)))
        .gsub("{shard_key}", T.must(emit(node.shard_key)))
    end
    pattern = pattern.gsub("{key_zig}", node.key_type.zig_type) if node.key_type
    pattern = pattern.gsub("{val_zig}", node.value_type.zig_type) if node.value_type
    node.resolved_allocs.each do |alloc_key, sym|
      pattern = pattern.gsub("{#{alloc_key}}", alloc_zig(sym))
    end
    pattern
  end

  private

  sig { params(node: MIR::RegistryCall).returns(String) }
  def emit_registry_call(node)
    code = registry_template(node.entry, IntrinsicTemplateKind::Zig)
    code = substitute_registry_common(code, node.entry, node.allocs, node.key_type, node.value_type)
    node.args.each_with_index do |arg, index|
      rendered = coerce_registry_arg(T.must(emit(arg.expr)), arg.coerce_type)
      code = code.gsub("&{#{index}}") { "&#{rendered}" }
      code = code.gsub("{#{index}}") { rendered }
    end
    node.suppress_try ? code.delete_prefix("try ") : code
  end

  sig { params(node: MIR::IndexedStore).returns(String) }
  def emit_indexed_store(node)
    code = registry_template(node.entry, node.template_kind)
    code = substitute_registry_common(code, node.entry, node.allocs, node.key_type, node.value_type)
    target = T.must(emit(node.target))
    index = T.must(emit(node.index))
    value = T.must(emit(node.value))
    code
      .gsub("&{target}", "&#{target}")
      .gsub("{target}", target)
      .gsub("{index}", index)
      .gsub("{value}", value)
  end

  sig { params(entry: FunctionSignature, template_kind: IntrinsicTemplateKind).returns(String) }
  def registry_template(entry, template_kind)
    entry.required_intrinsic_template(template_kind)
  end

  sig { params(code: String, entry: FunctionSignature, allocs: T.nilable(MIR::InlineAllocMetadata), key_type: T.nilable(Type), value_type: T.nilable(Type)).returns(String) }
  def substitute_registry_common(code, entry, allocs, key_type, value_type)
    out = code.gsub("{rt}", @rt_name)
    out = out.gsub("{key_zig}", key_type.zig_type) if key_type
    out = out.gsub("{val_zig}", value_type.zig_type) if value_type
    allocs&.each do |key, sym|
      out = out.gsub("{#{key}}", alloc_zig(sym))
    end
    out
  end

  sig { params(rendered_arg: String, coerce_type: T.nilable(Symbol)).returns(String) }
  def coerce_registry_arg(rendered_arg, coerce_type)
    return rendered_arg unless coerce_type

    coercible = [:Int64, :Float64, :Int32, :Int16, :Int8, :UInt64, :UInt32, :UInt16, :UInt8, :Bool]
    return rendered_arg unless coercible.include?(coerce_type)

    "@as(#{Type.new(coerce_type).zig_type}, #{rendered_arg})"
  end

  sig { params(node: MIR::ExternTrampoline).returns(String) }
  def emit_extern_trampoline(node)
    payload_t = node.return_type.error_union? ? T.must(node.return_type.payload_type) : node.return_type
    returns_void = payload_t.void?
    can_fail = node.return_type.error_union?
    prefix = node.method_name ? "__ExtM" : "__Ext"
    args_tuple_name = node.method_name ? "__extm#{node.id}_args" : "__ext#{node.id}_args"
    frame_name = node.method_name ? "__extm#{node.id}_frame" : "__ext#{node.id}_frame"
    runtime_arg_codes = node.runtime_args.map { |arg| T.must(emit(arg.expr)) }
    comptime_codes = node.comptime_args.map { |arg| T.must(emit(arg)) }
    arg_tuple = runtime_arg_codes.empty? ? ".{}" : ".{ #{runtime_arg_codes.join(', ')} }"
    receiver_code = node.receiver ? emit(T.must(node.receiver)) : nil

    fields = T.let([], T::Array[String])
    fields << "self_val: @TypeOf(#{receiver_code})" if receiver_code
    fields << "alloc: std.mem.Allocator" if node.alloc_kind
    node.runtime_args.each_with_index do |arg, index|
      field_type = arg.field_type&.zig_type(is_param: true)
      fields << "a#{index}: #{field_type || "@TypeOf(#{args_tuple_name}[#{index}])"}"
    end
    fields << "err: ?anyerror = null" if can_fail
    fields << "ret: #{payload_t.zig_type} = undefined" unless returns_void

    call_zig = extern_trampoline_call(node, comptime_codes, runtime_arg_codes.length)
    call_stmt = if can_fail
      returns_void ? "#{call_zig} catch |err| { f.err = err; return; };" :
        "f.ret = (#{call_zig} catch |err| { f.err = err; return; });"
    else
      returns_void ? "#{call_zig};" : "f.ret = #{call_zig};"
    end

    init_fields = T.let([], T::Array[String])
    init_fields << ".self_val = #{receiver_code}" if receiver_code
    runtime_arg_codes.each_index { |index| init_fields << ".a#{index} = #{args_tuple_name}[#{index}]" }
    if node.alloc_kind
      alloc_expr = node.alloc_kind == :heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
      init_fields << ".alloc = #{alloc_expr}"
    end

    f_needed = !!(receiver_code || node.alloc_kind || runtime_arg_codes.any? || !returns_void || can_fail)
    f_binding = f_needed ? "const f: *@This() = @ptrCast(@alignCast(ptr));" : "_ = ptr;"
    label = "blk_ext#{node.id}"
    code = returns_void ? "{ " : "#{label}: { "
    code += "const #{args_tuple_name} = #{arg_tuple}; " if runtime_arg_codes.any?
    field_decls = fields.empty? ? "" : "#{fields.join(', ')}, "
    code += "const #{prefix}#{node.id} = struct { #{field_decls}fn run(ptr: ?*anyopaque) callconv(.c) void { #{f_binding} #{call_stmt} } }; "
    code += "var #{frame_name} = #{prefix}#{node.id}{ #{init_fields.join(', ')} }; "
    code += "#{@rt_name}.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &#{prefix}#{node.id}.run), @ptrCast(&#{frame_name})); "
    code += "if (#{frame_name}.err) |e| return e; " if can_fail
    code += "break :#{label} #{frame_name}.ret; " unless returns_void
    code + "}"
  end

  sig { params(node: MIR::ExternTrampoline, comptime_codes: T::Array[String], runtime_arg_count: Integer).returns(String) }
  def extern_trampoline_call(node, comptime_codes, runtime_arg_count)
    if node.method_name
      args = []
      args << "f.alloc" if node.alloc_kind
      runtime_arg_count.times { |index| args << "f.a#{index}" }
      return "f.self_val.#{T.must(node.method_name)}(#{args.join(', ')})"
    end

    mod_prefix = node.module_alias ? "#{T.must(node.module_alias).gsub('.', '_')}." : ""
    parts = comptime_codes.dup
    parts << "f.alloc" if node.alloc_kind
    runtime_arg_count.times { |index| parts << "f.a#{index}" }
    "#{mod_prefix}#{node.callee_name}(#{parts.join(', ')})"
  end

  sig { params(node: MIR::ObservableConsumerSpawn).returns(String) }
  def emit_observable_consumer_spawn(node)
    ctx_type = "__ObsConsumerCtx#{node.id}"
    fiber_rt = "__rt_obs_#{node.id}"
    body = emit_body_with_runtime(node.body, fiber_rt)
    body = replace_emit_identifier(replace_emit_identifier(body, node.acc_name, "ctx.acc"), node.source_name, "ctx.gen")
    rt_name = node.runtime_name

    <<~ZIG.chomp
      const #{ctx_type} = struct {
              acc: #{node.acc_type.zig_type},
              gen: @TypeOf(#{node.source_name}),
              fn run(__raw_rt_obs_#{node.id}: *anyopaque, __raw_args_obs_#{node.id}: ?*anyopaque) anyerror!void {
                  const #{fiber_rt} = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_obs_#{node.id})));
                  #{body.include?(fiber_rt) ? "" : "_ = &#{fiber_rt};"}
                  const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_obs_#{node.id}.?)));
                  defer ctx.acc.finish();
                  #{body}
              }
          };
          try CheatHeader.spawnObservableConsumerCtx(
              #{ctx_type},
              #{rt_name},
              .{ .acc = #{node.acc_name}, .gen = #{node.source_name} },
              @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
              .{ .stack_size = .#{node.task_config_variant} }
          )
    ZIG
  end

  sig { params(node: MIR::ShardConcurrentEach).returns(String) }
  def emit_shard_concurrent_each(node)
    id = node.id
    idx_var = "__sh#{id}_i"
    key_var = "__sh#{id}_key"
    sh_var = "__sh#{id}_sh"
    map_ptr = "__sh#{id}_map"
    key_zig = node.key_type.zig_type
    shard_count = node.shard_count
    string_key = !node.map_type.numeric_map?

    body_zig = emit_body_with_runtime(node.body, "__rt")
    worker_body = body_zig.include?("__rt") ? body_zig : "_ = &__rt;\n#{body_zig}"
    producer_key_body = emit_body(node.producer_key_body)
    capture_setup = emit_body(node.capture_setup)
    capture_fields = emit_shard_worker_capture_fields(node, map_ptr)
    capture_inits = emit_shard_worker_capture_inits(node, map_ptr)

    key_loop_mark = if node.key_allocates_frame
      "const __sh#{id}_key_mark = rt.saveLoopMark();\ndefer rt.restoreLoopMark(__sh#{id}_key_mark);"
    else
      ""
    end
    body_loop_mark = if node.body_allocates_frame
      "const __sh#{id}_body_mark = __rt.saveLoopMark();\ndefer __rt.restoreLoopMark(__sh#{id}_body_mark);"
    else
      ""
    end
    key_store_expr = string_key ? "try rt.heapAlloc().dupe(u8, #{key_var})" : key_var
    key_free_work = shard_key_free_work(id, string_key)
    key_free_success = string_key ? "__rt.heapAlloc().free(#{key_var});" : ""
    key_free_remaining = string_key ? "errdefer for (__work.keys[__sh#{id}_ki..]) |__k| __rt.heapAlloc().free(__k);" : ""
    key_slice_cleanup = string_key ? "for (__sh#{id}_keys) |__k| rt.heapAlloc().free(__k);" : ""
    pending_batch_cleanup = string_key ? "for (__sh#{id}_batches[__s].items) |__k| rt.heapAlloc().free(__k);" : ""
    op_str = node.inclusive ? "<=" : "<"

    <<~ZIG.chomp
      {
          const #{map_ptr} = &#{emit(node.map_expr)};
          #{map_ptr}.ensureOwnership();
          const __sh#{id}_cap: usize = #{emit(node.capacity_expr)};
          const __sh#{id}_batch: usize = @max(@as(usize, #{emit(node.batch_size_expr)}), 1);
          const __ShWork#{id} = struct {
              keys: []#{key_zig},
          };
          const __ShCleanup#{id} = struct {
      #{indent_block(emit_shard_cleanup_buffered(id, string_key), 12)}
          };
          var __sh#{id}_chans: [#{shard_count}]CheatLib.BoundedChannel(__ShWork#{id}) = undefined;
          for (0..#{shard_count}) |__s| {
              __sh#{id}_chans[__s] = try CheatLib.BoundedChannel(__ShWork#{id}).init(rt.heapAlloc(), __sh#{id}_cap);
          }
          defer for (0..#{shard_count}) |__s| __sh#{id}_chans[__s].deinit();
      #{indent_block(capture_setup, 4)}
          var __sh#{id}_wg = CheatHeader.WaitGroup.init(rt.getSched());
          var __sh#{id}_err = std.atomic.Value(bool).init(false);
          const __ShWorker#{id} = struct {
              wg: *CheatHeader.WaitGroup,
              chans: *[#{shard_count}]CheatLib.BoundedChannel(__ShWork#{id}),
              err: *std.atomic.Value(bool),
              shard: usize,
      #{indent_block(capture_fields, 8)}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  errdefer {
                      ctx.err.store(true, .release);
                      for (0..#{shard_count}) |__s| ctx.chans[__s].setError(error.CheatError);
                  }
                  while (ctx.chans[ctx.shard].pop() catch |__err| {
                      ctx.err.store(true, .release);
                      for (0..#{shard_count}) |__s| ctx.chans[__s].setError(__err);
                      return __err;
                  }) |__work| {
                      errdefer {
      #{indent_block(key_free_work, 24)}
                      }
                      var __sh#{id}_ki: usize = 0;
                      while (__sh#{id}_ki < __work.keys.len) : (__sh#{id}_ki += 1) {
      #{indent_block(key_free_remaining, 24)}
                          const #{key_var}: #{key_zig} = __work.keys[__sh#{id}_ki];
      #{indent_block(body_loop_mark, 24)}
      #{indent_block(worker_body, 24)}
      #{indent_block(key_free_success, 24)}
                      }
                      __rt.heapAlloc().free(__work.keys);
                      __rt.checkYield();
                  }
              }
          };
          var __sh#{id}_workers: [#{shard_count}]__ShWorker#{id} = undefined;
          __sh#{id}_wg.add(#{shard_count});
          for (0..#{shard_count}) |__s| {
              __sh#{id}_workers[__s] = .{ .wg = &__sh#{id}_wg, .chans = &__sh#{id}_chans, .err = &__sh#{id}_err, .shard = __s#{capture_inits} };
              try CheatHeader.spawnBest(
                  @intFromPtr(&Runtime.entryWrapper),
                  @as(CheatHeader.TaskFn, @ptrCast(&__ShWorker#{id}.run)),
                  &__sh#{id}_workers[__s],
                  .{ .stack_size = .#{node.task_config_variant} },
              );
          }

          var __sh#{id}_batches: [#{shard_count}]std.ArrayListUnmanaged(#{key_zig}) = [_]std.ArrayListUnmanaged(#{key_zig}){.empty} ** #{shard_count};
          defer for (0..#{shard_count}) |__s| {
      #{indent_block(pending_batch_cleanup, 12)}
              __sh#{id}_batches[__s].deinit(rt.heapAlloc());
          };

          var #{idx_var}: i64 = #{emit(node.start_expr)};
          const __sh#{id}_end: i64 = #{emit(node.finish_expr)};
          while ((#{idx_var} #{op_str} __sh#{id}_end) and !__sh#{id}_err.load(.acquire)) : (#{idx_var} += 1) {
      #{indent_block(key_loop_mark, 12)}
      #{indent_block(producer_key_body, 12)}
              const #{sh_var} = @TypeOf(#{map_ptr}.*).shardIndexWithHash(#{key_var});
              try __sh#{id}_batches[#{sh_var}.shard].append(rt.heapAlloc(), #{key_store_expr});
              if (__sh#{id}_batches[#{sh_var}.shard].items.len >= __sh#{id}_batch) {
                  const __sh#{id}_keys = try __sh#{id}_batches[#{sh_var}.shard].toOwnedSlice(rt.heapAlloc());
                  const __sh#{id}_work = __ShWork#{id}{ .keys = __sh#{id}_keys };
                  __sh#{id}_chans[#{sh_var}.shard].push(__sh#{id}_work) catch |__err| {
      #{indent_block(key_slice_cleanup, 20)}
                      rt.heapAlloc().free(__sh#{id}_keys);
                      __sh#{id}_err.store(true, .release);
                      for (0..#{shard_count}) |__s| __sh#{id}_chans[__s].setError(__err);
                      break;
                  };
              }
          }
          for (0..#{shard_count}) |__s| {
              if (__sh#{id}_batches[__s].items.len > 0 and !__sh#{id}_err.load(.acquire)) {
                  const __sh#{id}_keys = try __sh#{id}_batches[__s].toOwnedSlice(rt.heapAlloc());
                  const __sh#{id}_work = __ShWork#{id}{ .keys = __sh#{id}_keys };
                  __sh#{id}_chans[__s].push(__sh#{id}_work) catch |__err| {
      #{indent_block(key_slice_cleanup, 20)}
                      rt.heapAlloc().free(__sh#{id}_keys);
                      __sh#{id}_err.store(true, .release);
                      for (0..#{shard_count}) |__ss| __sh#{id}_chans[__ss].setError(__err);
                      break;
                  };
              }
          }
          for (0..#{shard_count}) |__s| __sh#{id}_chans[__s].close();
          __sh#{id}_wg.wait();
          for (0..#{shard_count}) |__s| __ShCleanup#{id}.cleanupBuffered(&__sh#{id}_chans[__s], rt);
          if (__sh#{id}_err.load(.acquire)) return error.CheatError;
      }
    ZIG
  end

  sig { params(node: MIR::ShardConcurrentEach, map_ptr: String).returns(String) }
  def emit_shard_worker_capture_fields(node, map_ptr)
    fields = T.let([
      "__shard_map: *@TypeOf(#{map_ptr}.*),",
    ], T::Array[String])
    rendered = emit_context_field_decls(node.capture_fields)
    fields << rendered unless rendered.empty?
    fields.join("\n")
  end

  sig { params(node: MIR::ShardConcurrentEach, map_ptr: String).returns(String) }
  def emit_shard_worker_capture_inits(node, map_ptr)
    fields = [".__shard_map = #{map_ptr}"]
    rendered = emit_struct_init_fields(node.capture_inits)
    fields << rendered unless rendered.empty?
    ", #{fields.join(", ")}"
  end

  sig { params(id: Integer, string_key: T::Boolean).returns(String) }
  def emit_shard_cleanup_buffered(id, string_key)
    key_cleanup = if string_key
      "for (__work.keys) |__k| __rt.heapAlloc().free(__k);\n__rt.heapAlloc().free(__work.keys);"
    else
      "__rt.heapAlloc().free(__work.keys);"
    end
    <<~ZIG.chomp
      fn cleanupBuffered(chan: *CheatLib.BoundedChannel(__ShWork#{id}), __rt: *Runtime) void {
          const inner = chan.inner;
          inner.mutex.lock();
          while (inner.tail != inner.head) {
              const __work = inner.buf[inner.tail & inner.mask];
              inner.tail += 1;
      #{indent_block(key_cleanup, 12)}
          }
          inner.mutex.unlock();
      }
    ZIG
  end

  sig { params(id: Integer, string_key: T::Boolean).returns(String) }
  def shard_key_free_work(id, string_key)
    return "__rt.heapAlloc().free(__work.keys);" unless string_key

    "for (__work.keys) |__k| __rt.heapAlloc().free(__k);\n__rt.heapAlloc().free(__work.keys);"
  end

  sig { params(stmts: T::Array[MIR::Emittable], runtime_name: String).returns(String) }
  def emit_body_with_runtime(stmts, runtime_name)
    prior_rt_name = T.let(@rt_name, String)
    @rt_name = runtime_name
    emit_body(stmts)
  ensure
    @rt_name = T.must(prior_rt_name)
  end

  sig { params(node: MIR::Emittable, runtime_name: String).returns(String) }
  def emit_node_with_runtime(node, runtime_name)
    prior_rt_name = T.let(@rt_name, String)
    @rt_name = runtime_name
    T.must(emit(node))
  ensure
    @rt_name = T.must(prior_rt_name)
  end

  sig { params(actions: T::Array[MIR::CaptureCleanupAction], runtime_name: String).returns(String) }
  def emit_capture_cleanup_actions_with_runtime(actions, runtime_name)
    prior_rt_name = T.let(@rt_name, String)
    @rt_name = runtime_name
    emit_capture_cleanup_actions(actions)
  ensure
    @rt_name = T.must(prior_rt_name)
  end

  sig { params(source: String, needle: String, replacement: String).returns(String) }
  def replace_emit_identifier(source, needle, replacement)
    return source if needle.empty?

    idx = 0
    needle_len = needle.bytesize
    result = +""
    while idx < source.bytesize
      if source.byteslice(idx, needle_len) == needle &&
          emit_identifier_boundary?(source, idx - 1) &&
          emit_identifier_boundary?(source, idx + needle_len)
        result << replacement
        idx += needle_len
      else
        result << T.must(source.byteslice(idx, 1))
        idx += 1
      end
    end
    result
  end

  sig { params(source: String, index: Integer).returns(T::Boolean) }
  def emit_identifier_boundary?(source, index)
    return true if index < 0 || index >= source.bytesize

    byte = source.getbyte(index)
    return true unless byte

    !((byte >= 48 && byte <= 57) ||
      (byte >= 65 && byte <= 90) ||
      (byte >= 97 && byte <= 122) ||
      byte == 95)
  end

  # --- MVCC SNAPSHOT / WITH MATCH emitters ---
  #
  # These render structured nodes 1:1 to the same Zig text we used to
  # emit via opaque expression blobs in mir_lowering, but the construct is now
  # MIR-checker-visible. Pre-migration these were inline string blobs
  # that hid heap allocations from the checker (INV-12 violation).

  # `WITH SNAPSHOT cell AS view { body }` (read mode):
  #   var <guard> = <unwrap>.read(<rt>);
  #   defer <guard>.release();
  #   const <alias> = <guard>.get();
  #   _ = &<alias>;
  #   <body>
  sig { params(node: MIR::SnapshotRead).returns(String) }
  def emit_snapshot_read(node)
    body = emit_body(node.body || [])
    cell_unwrap = T.must(emit(node.cell_unwrap))
    parts = [
      "var #{node.guard_var} = #{cell_unwrap}.*.read(#{node.rt});",
      "defer #{node.guard_var}.release();",
      "const #{node.alias_name} = #{node.guard_var}.get();",
      "_ = &#{node.alias_name};",
    ]
    parts << body unless body.empty?
    parts.join("\n")
  end

  sig { params(node: MIR::CapabilityUnwrap).returns(String) }
  def emit_capability_unwrap(node)
    source = T.must(emit(node.source))
    is_ptr = "@typeInfo(@TypeOf(#{source})) == .pointer"
    inner_t = "@typeInfo(@TypeOf(#{source})).pointer.child"
    "(if (comptime #{is_ptr}) " \
      "(if (comptime @typeInfo(#{inner_t}) == .@\"struct\") " \
        "(if (comptime @hasField(#{inner_t}, \"ctrl\")) #{source}.ctrl.data else #{source}) " \
       "else " \
        "(if (comptime @typeInfo(#{inner_t}) == .pointer) " \
          "(if (comptime @typeInfo(@typeInfo(#{inner_t}).pointer.child) == .@\"struct\") " \
            "(if (comptime @hasField(@typeInfo(#{inner_t}).pointer.child, \"ctrl\")) #{source}.*.ctrl.data else #{source}.*) " \
           "else #{source}.*) " \
         "else #{source})) " \
    "else " \
      "(if (comptime @typeInfo(@TypeOf(#{source})) == .@\"struct\") " \
        "(if (comptime @hasField(@TypeOf(#{source}), \"ctrl\")) #{source}.ctrl.data else &#{source}) " \
       "else &#{source}))"
  end

  sig { params(node: MIR::CapabilityLockTarget).returns(String) }
  def emit_capability_lock_target(node)
    source = T.must(emit(node.source))
    return comptime_arc_unwrap_expr(source) if node.comptime_arc_unwrap
    return "#{source}.ctrl.data.*" if node.arc_wrapped

    source
  end

  sig { params(node: MIR::CapabilityLockAddress).returns(String) }
  def emit_capability_lock_address(node)
    source = T.must(emit(node.source))
    node.arc_wrapped ? "#{source}.ctrl.data" : "&#{source}"
  end

  sig { params(source: String).returns(String) }
  def comptime_arc_unwrap_expr(source)
    base_t = "@TypeOf(#{source})"
    "(if (comptime @typeInfo(#{base_t}) == .pointer) " \
      "(if (comptime @typeInfo(@typeInfo(#{base_t}).pointer.child) == .@\"struct\") " \
        "(if (comptime @hasField(@typeInfo(#{base_t}).pointer.child, \"ctrl\")) #{source}.*.ctrl.data.* else #{source}.*) " \
       "else #{source}.*) " \
     "else " \
      "(if (comptime @typeInfo(#{base_t}) == .@\"struct\") " \
        "(if (comptime @hasField(#{base_t}, \"ctrl\")) #{source}.ctrl.data.* else #{source}) " \
       "else #{source}))"
  end

  # `WITH SNAPSHOT cell AS MUTABLE va { body } [ON MvccConflict <action>]`:
  #   <unwrap>.update(<rt>, <alloc>, struct {
  #       fn run(<alias>: *<bare_t>) void {
  #           _ = &<alias>;
  #           <body>
  #       }
  #   }.run, .{}) catch |err| switch (err) { ... };
  # Wraps in a counted retry loop when retries != nil.
  #
  # When node.is_atomic_ptr is set, skip the conflict-handler wrap entirely.
  # AtomicPtr.update retries until success and never returns UpdateRetriesExhausted.
  # Just call with `try` so the only path back to the caller is
  # OOM (which the user can't usefully handle inline anyway).
  # Universally-polymorphic WITH lowers through a runtime helper that
  # comptime-dispatches to the right family-specific path.
  sig { params(node: MIR::PolymorphicMutate).returns(String) }
  def emit_polymorphic_mutate(node)
    body_zig = emit_body(node.body || [])
    cell_zig = T.must(emit(node.cell))
    <<~ZIG.rstrip
      try CheatLib.polymorphicMutate(#{cell_zig}, #{node.rt}, struct {
          fn run(#{node.alias_name}: *#{node.bare_type.zig_type}) void {
              _ = &#{node.alias_name};
              #{body_zig}
          }
      }.run, .{});
    ZIG
  end

  sig { params(node: MIR::PolymorphicMutateFlow).returns(String) }
  def emit_polymorphic_mutate_flow(node)
    old_flow_alias = @flow_alias_name
    @flow_alias_name = node.alias_name
    cell_zig = T.must(emit(node.cell))
    body_zig = emit_body_flow(node.body || [], :ret_commit)
    guard_block = ""
    if node.guard_cond
      fail_zig = emit_body_flow(node.guard_fail_body || [], :ret_no_commit)
      unless flow_body_terminates?(node.guard_fail_body || [])
        fail_zig += "\n__flow.* = .{ .kind = .skip_no_commit };\nreturn;"
      end
      guard_block = <<~ZIG
        if (!(#{emit(node.guard_cond)})) {
            #{indent_block(fail_zig, 12)}
        }
      ZIG
    end
    fallthrough_arm = flow_always_exits?(node) ? "unreachable" : "{}"
    result = <<~ZIG.rstrip
      const __PolyFlow = struct {
          kind: enum { cont_commit, skip_no_commit, ret_commit, ret_no_commit, raise_no_commit },
          ret: #{node.return_type.zig_type} = undefined,
      };
      var __poly_flow = __PolyFlow{ .kind = .cont_commit };
      try CheatLib.polymorphicMutateFlow(#{cell_zig}, #{node.rt}, struct {
          fn run(#{node.alias_name}: *#{node.bare_type.zig_type}, __flow: *__PolyFlow) void {
              _ = &#{node.alias_name};
              #{guard_block}
              #{body_zig}
              #{flow_body_terminates?(node.body || []) ? "" : "__flow.* = .{ .kind = .cont_commit };"}
          }
      }.run, .{&__poly_flow});
      switch (__poly_flow.kind) {
          .ret_commit, .ret_no_commit => return __poly_flow.ret,
          .raise_no_commit => return error.CheatError,
          .cont_commit, .skip_no_commit => #{fallthrough_arm},
      }
    ZIG
    @flow_alias_name = old_flow_alias
    result
  end

  sig { params(stmts: T::Array[MIR::Node], return_kind: Symbol).returns(String) }
  def emit_body_flow(stmts, return_kind)
    return "" unless stmts
    stmts.filter_map { |s| emit_flow_stmt(s, return_kind) }.join("\n")
  end

  sig { params(stmt: MIR::Node, return_kind: Symbol).returns(T.nilable(String)) }
  def emit_flow_stmt(stmt, return_kind)
    case stmt
    when MIR::ReturnStmt
      ret = stmt.value ? emit(stmt.value) : "{}"
      ret = "#{ret}.*" if @flow_alias_name && ret == @flow_alias_name
      "__flow.* = .{ .kind = .#{return_kind}, .ret = #{ret} };\nreturn;"
    when MIR::ScopeBlock
      inner = emit_body_flow(stmt.body || [], return_kind)
      "{\n#{indent_block(inner, 4)}\n}"
    when MIR::IfStmt
      then_zig = emit_body_flow(stmt.then_body || [], return_kind)
      else_zig = emit_body_flow(stmt.else_body || [], return_kind)
      else_body = stmt.else_body
      if else_body && !else_body.empty?
        "if (#{emit(stmt.cond)}) {\n#{indent_block(then_zig, 4)}\n} else {\n#{indent_block(else_zig, 4)}\n}"
      else
        "if (#{emit(stmt.cond)}) {\n#{indent_block(then_zig, 4)}\n}"
      end
    when MIR::PolymorphicFlowSignal
      emit_polymorphic_flow_signal(stmt)
    else
      emit(stmt)
    end
  end

  sig { params(node: MIR::PolymorphicFlowSignal).returns(String) }
  def emit_polymorphic_flow_signal(node)
    fields = [".kind = .#{node.kind}"]
    fields << ".ret = #{emit(node.ret)}" if node.ret
    "__flow.* = .{ #{fields.join(', ')} };\nreturn;"
  end

  sig { params(stmts: T::Array[MIR::Node]).returns(T::Boolean) }
  def flow_body_terminates?(stmts)
    return false unless stmts && !stmts.empty?
    last = stmts.last
    case last
    when MIR::ReturnStmt, MIR::PolymorphicFlowSignal
      true
    when MIR::ScopeBlock
      flow_body_terminates?(last.body || [])
    when MIR::IfStmt
      return false unless flow_body_terminates?(last.then_body || [])
      else_body = last.else_body
      return false unless else_body && !else_body.empty?

      flow_body_terminates?(else_body)
    else
      false
    end
  end

  sig { params(node: MIR::PolymorphicMutateFlow).returns(T::Boolean) }
  def flow_always_exits?(node)
    body_exits = flow_body_terminates?(node.body || [])
    return body_exits unless node.guard_cond
    body_exits && flow_body_terminates?(node.guard_fail_body || [])
  end

  sig { params(code: String, spaces: Integer).returns(String) }
  def indent_block(code, spaces)
    pad = " " * spaces
    code.to_s.lines.map { |line| line.strip.empty? ? line : "#{pad}#{line}" }.join.rstrip
  end

  sig { params(node: MIR::SnapshotTransaction).returns(String) }
  def emit_snapshot_transaction(node)
    body_zig = emit_body(node.body || [])
    cell_unwrap = T.must(emit(node.cell_unwrap))
    alloc = alloc_zig(node.alloc)
    core = <<~ZIG.rstrip
      #{cell_unwrap}.*.update(#{node.rt}, #{alloc}, struct {
          fn run(#{node.alias_name}: *#{node.bare_type.zig_type}) void {
              _ = &#{node.alias_name};
              #{body_zig}
          }
      }.run, .{})
    ZIG
    # Versioned and AtomicPtr surface different retry-exhaustion errors, but
    # share the same catch-and-action wrapper shape.
    zig_error_name = node.is_atomic_ptr ? "AtomicConflict" : "UpdateRetriesExhausted"
    wrap_conflict_handler(core, node.conflict_action, node.retries, zig_error_name)
  end

  # `WITH SNAPSHOT a AS MUTABLE va, b AS MUTABLE vb, ... { body }`:
  # Multi-cell atomic transaction via versionedUpdateMulti.
  sig { params(node: MIR::SnapshotMultiTxn).returns(String) }
  def emit_snapshot_multi_txn(node)
    body_zig = emit_body(node.body || [])
    cells_tuple = ".{ #{(node.cells || []).map { |cell| T.must(emit(cell)) }.join(", ")} }"
    alloc = alloc_zig(node.alloc)
    alias_decls = (node.aliases || []).each_with_index.map do |alias_name, index|
      "const #{alias_name} = views[#{index}]; _ = &#{alias_name};"
    end.join("\n            ")
    core = <<~ZIG.rstrip
      CheatLib.versionedUpdateMulti(#{cells_tuple}, #{node.rt}, #{alloc}, struct {
          fn run(views: anytype) anyerror!void {
              #{alias_decls}
              #{body_zig}
          }
      }.run, .{})
    ZIG
    wrap_conflict_handler(core, node.conflict_action, node.retries)
  end

  # `WITH cell AS va MATCH WHEN F1 -> {...} WHEN F2 -> {...} END`:
  # comptime if-else chain, one branch per family. The `unreachable`
  # else is added by the lowering (WithMatchCheck enforces arm
  # exhaustiveness); we emit exactly what mir_lowering passed in.
  sig { params(node: MIR::WithMatchDispatch).returns(String) }
  def emit_with_match_dispatch(node)
    cell_zig = T.must(emit(node.cell))
    arm_strs = node.arms.each_with_index.map { |arm, i|
      probe = emit_with_match_probe(arm.family, cell_zig, node.snapshot_mode)
      head = i.zero? ? "if (comptime #{probe})" : "else if (comptime #{probe})"
      body_zig = emit_body(arm.body || [])
      prelude = emit_with_match_prelude(arm, cell_zig, node.alias_name, node.rt_name, node.snapshot_mode)
      inner = prelude.empty? ? body_zig : "#{prelude}\n#{body_zig}"
      "#{head} {\n    #{inner}\n}"
    }
    chain = arm_strs.join(" ") + " else { unreachable; }"
    "#{chain}\n_ = &#{cell_zig};"
  end

  sig { params(family: Symbol, cell_zig: String, snapshot_mode: T::Boolean).returns(String) }
  def emit_with_match_probe(family, cell_zig, snapshot_mode)
    inner_t = "CheatLib.WithMatchInner(@TypeOf(#{cell_zig}))"
    case family
    when :VERSIONED
      snapshot_mode ? "(@hasDecl(#{inner_t}, \"Inner\") and !@hasDecl(#{inner_t}, \"compareAndPublish\"))" :
        "@hasDecl(#{inner_t}, \"Inner\")"
    when :LOCKED
      "@hasField(#{inner_t}, \"mutex\")"
    when :ATOMIC
      snapshot_mode ? "@hasDecl(#{inner_t}, \"compareAndPublish\")" :
        "@hasDecl(#{inner_t}, \"cmpxchgStrong\")"
    else
      Kernel.raise "WITH MATCH: no probe for family #{family.inspect}"
    end
  end

  sig { params(arm: MIR::WithMatchArm, cell_zig: String, alias_name: String, rt_name: String, snapshot_mode: T::Boolean).returns(String) }
  def emit_with_match_prelude(arm, cell_zig, alias_name, rt_name, snapshot_mode)
    unwrap = emit_capability_unwrap(MIR::CapabilityUnwrap.new(MIR::Ident.new(cell_zig)))
    case arm.family
    when :VERSIONED
      emit_with_match_guard_prelude(unwrap, arm.guard_var, alias_name, rt_name, :read)
    when :LOCKED
      emit_with_match_guard_prelude(unwrap, arm.guard_var, alias_name, rt_name, :acquire)
    when :ATOMIC
      snapshot_mode ? emit_with_match_guard_prelude(unwrap, arm.guard_var, alias_name, rt_name, :read) :
        "const #{alias_name} = #{unwrap};\n_ = &#{alias_name};"
    else
      ""
    end
  end

  sig { params(unwrap: String, guard_var: String, alias_name: String, rt_name: String, mode: Symbol).returns(String) }
  def emit_with_match_guard_prelude(unwrap, guard_var, alias_name, rt_name, mode)
    call = mode == :read ? "read(#{rt_name})" : "acquire()"
    [
      "var #{guard_var} = #{unwrap}.*.#{call};",
      "defer #{guard_var}.release();",
      "const #{alias_name} = #{guard_var}.get();",
      "_ = &#{alias_name};",
    ].join("\n")
  end

  # Helper: wrap a Versioned.update[Multi] / AtomicPtr.update call
  # expression with the conflict handler (and optional RETRY(N)
  # outer-retry shape). Parameterize the Zig error name so the same wrapper works for both families:
  # `UpdateRetriesExhausted` (Versioned bridge to MvccConflict) and
  # `AtomicConflict` (AtomicPtr bridge to AtomicConflict).
  sig { params(core_call: String, conflict_action: T.nilable(MIR::FailureAction), retries: T.nilable(Integer), zig_error_name: String).returns(String) }
  def wrap_conflict_handler(core_call, conflict_action, retries, zig_error_name = "UpdateRetriesExhausted")
    action_zig = conflict_action ? emit_failure_action(conflict_action) : "return error.#{zig_error_name};"
    if retries
      <<~ZIG.rstrip
        {
            var __retry: usize = 0;
            __snap_retry: while (true) : (__retry += 1) {
                if (#{core_call}) |_| {
                    break :__snap_retry;
                } else |__err| switch (__err) {
                    error.#{zig_error_name} => {
                        if (__retry + 1 < #{retries}) continue;
                        #{action_zig}
                    },
                    else => return __err,
                }
            }
        }
      ZIG
    else
      <<~ZIG.rstrip
        #{core_call} catch |__err| switch (__err) {
            error.#{zig_error_name} => { #{action_zig} },
            else => return __err,
        };
      ZIG
    end
  end

  sig { params(action: MIR::FailureAction).returns(String) }
  def emit_failure_action(action)
    kind = action.kind
    error_name = action.error_type.to_s
    case kind
    when MIR::FailureActionKind::Raise
      "#{action.rt_name}.setError(.#{action.error_kind}, @intFromEnum(ErrorName.#{error_name}), #{zig_string_literal(action.default_message)}, #{action.line});\nreturn error.CheatError;"
    when MIR::FailureActionKind::Exit
      message = action.message ? T.must(emit(action.message)) : zig_string_literal(action.default_message)
      "#{action.rt_name}.setError(.#{action.error_kind}, @intFromEnum(ErrorName.#{error_name}), #{message}, #{action.line});\nreturn error.CheatError;"
    when MIR::FailureActionKind::Pass
      "break :#{required_failure_label(action)};"
    when MIR::FailureActionKind::Return
      "return #{T.must(emit(T.must(action.return_value)))};"
    when MIR::FailureActionKind::Block
      "#{emit_body(action.body)}\nbreak :#{required_failure_label(action)};"
    else
      raise "unknown failure action kind: #{kind.inspect}"
    end
  end

  sig { params(action: MIR::FailureAction).returns(String) }
  def required_failure_label(action)
    label = action.with_label
    Kernel.raise "failure action requires a WITH label" unless label

    label
  end

  sig { params(text: String).returns(String) }
  def zig_string_literal(text)
    text.dump
  end

  sig { params(value: String).returns(String) }
  def symbol_literal_name(value)
    existing = @symbol_literals[value]
    return existing if existing

    name = "__clear_symbol_#{@symbol_literals.length}"
    @symbol_literals[value] = name
    name
  end

  sig { params(text: String).returns(String) }
  def zig_byte_string_literal(text)
    escaped = text.bytes.map do |b|
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
    end.join
    "\"#{escaped}\""
  end

  sig { params(node: MIR::FallibleLockBinding).returns(String) }
  def emit_fallible_lock_binding(node)
    [
      "var #{node.guard_var} = #{emit_fallible_lock_acquire_expr(node)};",
      "defer #{node.guard_var}.release();",
      "const #{node.alias_name} = #{node.guard_var}.get();",
      "_ = &#{node.alias_name};",
    ].join("\n")
  end

  sig { params(node: MIR::FallibleLockBinding).returns(String) }
  def emit_fallible_lock_acquire_expr(node)
    handler = emit_fallible_lock_error_handler(
      node.action,
      node.retries,
      node.matched_types || [],
      node.bubble_types || [],
      node.rt_name,
      node.source_line.to_s,
    )
    acquire_call = T.must(emit(node.acquire_call))
    if node.retries
      <<~ZIG.rstrip
        #{node.acquire_block}: {
          var __retry: usize = 0;
          while (true) : (__retry += 1) {
            if (#{acquire_call}) |__g| {
              break :#{node.acquire_block} __g;
            } else |__err| {
              #{handler}
            }
          }
        }
      ZIG
    else
      <<~ZIG.rstrip
        #{node.acquire_block}: {
          if (#{acquire_call}) |__g| {
            break :#{node.acquire_block} __g;
          } else |__err| {
            #{handler}
          }
        }
      ZIG
    end
  end

  sig do
    params(
      action: MIR::FailureAction,
      retries: T.nilable(Integer),
      matched_types: T::Array[Symbol],
      bubble_types: T::Array[Symbol],
      rt_name: String,
      source_line: String,
    ).returns(String)
  end
  def emit_fallible_lock_error_handler(action, retries, matched_types, bubble_types, rt_name, source_line)
    action_zig = emit_failure_action(action)
    matched_arms = matched_types.map do |type_name|
      matched_errs = "error.#{AST.zig_name_of_type(type_name)}"
      body = retries ? "if (__retry + 1 < #{retries}) continue;\n#{action_zig}" : action_zig
      "#{matched_errs} => { #{body} }"
    end
    bubble_arms = bubble_types.map do |type_name|
      zig = AST.zig_name_of_type(type_name)
      kind = AST.kind_of_type(type_name)
      %Q(error.#{zig} => { #{rt_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{zig}), "lock #{zig}", #{source_line}); return error.CheatError; })
    end
    arms = matched_arms + bubble_arms
    "switch (__err) {\n#{arms.join(",\n")}\n}"
  end

  sig { params(node: MIR::SortedLockAcquire).returns(String) }
  def emit_sorted_lock_acquire(node)
    node.fallible ? emit_sorted_lock_acquire_fallible(node) : emit_sorted_lock_acquire_panic(node)
  end

  sig { params(node: MIR::SortedLockAcquire).returns(String) }
  def emit_sorted_lock_acquire_panic(node)
    entries = node.entries || []
    n = entries.length
    guard_decls = entries.map { |entry|
      "var #{entry.guard_var}: @TypeOf(#{emit(entry.lock_expr)}.#{entry.method_name}()) = undefined;"
    }.join("\n")
    ptr_init = entries.map { |entry| "@intFromPtr(#{emit(entry.address_expr)})" }.join(", ")
    order_init = (0...n).to_a.join(", ")
    switch_arms = entries.map { |entry|
      "#{entry.index} => #{entry.guard_var} = #{emit(entry.lock_expr)}.#{entry.method_name}(),"
    }.join("\n                ")
    defer_releases = entries.map { |entry| "defer #{entry.guard_var}.release();" }.join("\n")
    alias_decls = entries.map { |entry|
      "const #{entry.alias_name} = #{entry.guard_var}.get();\n_ = &#{entry.alias_name};"
    }.join("\n")

    <<~ZIG.rstrip
      #{guard_decls}
      {
          const __ptrs = [_]usize{ #{ptr_init} };
          var __order = [_]u8{ #{order_init} };
          var __i: usize = 0;
          while (__i < #{n}) : (__i += 1) {
              var __j: usize = 0;
              while (__j + 1 < #{n}) : (__j += 1) {
                  if (__ptrs[__order[__j]] > __ptrs[__order[__j + 1]]) {
                      const __tmp = __order[__j];
                      __order[__j] = __order[__j + 1];
                      __order[__j + 1] = __tmp;
                  }
              }
          }
          for (__order) |__idx| {
              switch (__idx) {
                #{switch_arms}
                else => unreachable,
              }
          }
      }
      #{defer_releases}
      #{alias_decls}
    ZIG
  end

  sig { params(node: MIR::SortedLockAcquire).returns(String) }
  def emit_sorted_lock_acquire_fallible(node)
    entries = node.entries || []
    n = entries.length
    action = T.cast(node.action, MIR::FailureAction)
    guard_decls = entries.map { |entry|
      "var #{entry.guard_var}: @TypeOf(try #{emit(entry.lock_expr)}.#{entry.method_name}()) = undefined;"
    }.join("\n")
    held_decls = entries.map { |entry| "var #{entry.held_var}: bool = false;" }.join("\n")
    ptr_init = entries.map { |entry| "@intFromPtr(#{emit(entry.address_expr)})" }.join(", ")
    order_init = (0...n).to_a.join(", ")
    acquire_arms = entries.map { |entry|
      lock_expr = emit(entry.lock_expr)
      <<~ZIG.rstrip
        #{entry.index} => {
                                        if (#{lock_expr}.#{entry.method_name}()) |__g| {
                                            #{entry.guard_var} = __g;
                                            #{entry.held_var} = true;
                                        } else |__err_inner| {
                                            __err_caught = __err_inner;
                                            __success = false;
                                        }
                                    },
      ZIG
    }.join("\n                                ")
    release_arms = entries.map { |entry|
      "#{entry.index} => if (#{entry.held_var}) { #{entry.guard_var}.release(); #{entry.held_var} = false; },"
    }.join("\n                            ")
    handler_switch = emit_sorted_lock_handler_switch(action, node.matched_types || [], node.bubble_types || [],
      node.rt_name, node.source_line.to_s)
    retry_branch = node.retries ? "if (__retry + 1 < #{node.retries}) continue;" : "// no retries configured"
    defer_releases = entries.map { |entry| "defer if (#{entry.held_var}) #{entry.guard_var}.release();" }.join("\n")
    alias_decls = entries.map { |entry|
      "const #{entry.alias_name} = #{entry.guard_var}.get();\n_ = &#{entry.alias_name};"
    }.join("\n")

    <<~ZIG.rstrip
      #{guard_decls}
      #{held_decls}
      #{node.loop_label}: {
          var __retry: usize = 0;
          while (true) : (__retry += 1) {
              const __ptrs = [_]usize{ #{ptr_init} };
              var __order = [_]u8{ #{order_init} };
              var __i: usize = 0;
              while (__i < #{n}) : (__i += 1) {
                  var __j: usize = 0;
                  while (__j + 1 < #{n}) : (__j += 1) {
                      if (__ptrs[__order[__j]] > __ptrs[__order[__j + 1]]) {
                          const __tmp = __order[__j];
                          __order[__j] = __order[__j + 1];
                          __order[__j + 1] = __tmp;
                      }
                  }
              }
              var __success = true;
              var __err_caught: ?anyerror = null;
              var __k: usize = 0;
              while (__k < #{n}) : (__k += 1) {
                  const __idx = __order[__k];
                  switch (__idx) {
                      #{acquire_arms}
                      else => unreachable,
                  }
                  if (!__success) break;
              }
              if (__success) break :#{node.loop_label};
              var __r: usize = __k;
              while (__r > 0) {
                  __r -= 1;
                  switch (__order[__r]) {
                      #{release_arms}
                      else => unreachable,
                  }
              }
              #{retry_branch}
              #{handler_switch}
              unreachable;
          }
      }
      #{defer_releases}
      #{alias_decls}
    ZIG
  end

  sig { params(action: MIR::FailureAction, matched: T::Array[Symbol], bubble: T::Array[Symbol], rt_name: String, source_line: String).returns(String) }
  def emit_sorted_lock_handler_switch(action, matched, bubble, rt_name, source_line)
    handler_arms = T.let([], T::Array[String])
    unless matched.empty?
      matched_errs = matched.map { |type_name| "error.#{AST.zig_name_of_type(type_name)}" }.join(", ")
      handler_arms << "#{matched_errs} => { #{emit_failure_action(action)} }"
    end
    bubble.each do |type_name|
      zig = AST.zig_name_of_type(type_name)
      kind = AST.kind_of_type(type_name)
      handler_arms << %Q(error.#{zig} => { #{rt_name}.setError(.#{kind}, @intFromEnum(ErrorName.#{zig}), "lock #{zig}", #{source_line}); return error.CheatError; })
    end
    handler_arms << %Q(else => |__err_other| { #{rt_name}.setError(.System, 0, @errorName(__err_other), #{source_line}); return error.CheatError; })
    "switch (__err_caught.?) {\n                    #{handler_arms.join(",\n                    ")},\n                }"
  end

  # --- Top-level emitters ---

  sig { params(node: MIR::Program).returns(String) }
  def emit_program(node)
    parts = node.items.filter_map { |item| emit(item) }
    symbol_pool = symbol_pool_declarations
    parts.unshift(symbol_pool) unless symbol_pool.empty?
    out = []
    parts.each_with_index do |part, i|
      if i == 0
        out << part
      elsif T.must(parts[i - 1]).start_with?("// CLR:")
        out << "\n#{part}"
      else
        out << "\n\n#{part}"
      end
    end
    out.join
  end

  sig { returns(String) }
  def symbol_pool_declarations
    return "" if @symbol_literals.empty?

    lines = [
      "// Static String@symbol literal pool.",
    ]
    @symbol_literals.each do |value, name|
      lines << "const #{name}: []const u8 = #{zig_byte_string_literal(value)};"
    end
    lines.join("\n")
  end
  public :symbol_pool_declarations

  sig { params(node: MIR::FnDef).returns(String) }
  def emit_fn_def(node)
    vis = node.visibility == :pub ? "pub " : ""
    comptime = (node.comptime_params || []).join(", ")
    params = node.params.map { |p| "#{p.name}: #{p.zig_type}" }.join(", ")
    all_params = [comptime, params].reject(&:empty?).join(", ")

    ret = node.can_fail ? "!#{node.ret_type}" : node.ret_type
    body = emit_body(node.body)

    "#{vis}fn #{node.name}(#{all_params}) #{ret} {\n#{body}\n}"
  end

  sig { params(node: MIR::StructDef).returns(String) }
  def emit_struct_def(node)
    vis = node.visibility == :pub ? "pub " : ""
    fields = (node.fields || []).map { |f|
      default = f.default ? " = #{emit(f.default)}" : ""
      "#{f.name}: #{f.zig_type}#{default},"
    }.join("\n    ")

    methods = (node.methods || []).map { |m| emit(m) }.join("\n\n    ")

    parts = [fields, methods].reject(&:empty?).join("\n\n    ")
    if node.name
      "#{vis}const #{node.name} = struct {\n    #{parts}\n};"
    else
      "struct {\n    #{parts}\n    }"
    end
  end

  sig { params(node: MIR::EnumDef).returns(String) }
  def emit_enum_def(node)
    vis = node.visibility == :pub ? "pub " : ""
    variants = node.variants.join(", ")
    "#{vis}const #{node.name} = enum { #{variants} };"
  end

  sig { params(node: MIR::UnionTypeDef).returns(String) }
  def emit_union_def(node)
    vis = node.visibility == :pub ? "pub " : ""
    fields = node.variants.map { |v|
      "#{v[:name]}: #{v[:zig_type]}"
    }.join(", ")
    if node.name
      "#{vis}const #{node.name} = union(enum) { #{fields} };"
    else
      "union(enum) { #{fields} }"
    end
  end

  sig { params(node: MIR::Import).returns(String) }
  def emit_import(node)
    base = "@import(\"#{node.module_path}\")"
    base = "#{base}.#{node.member}" if node.member
    "const #{node.alias_name} = #{base};"
  end

  sig { params(node: MIR::TypeAlias).returns(String) }
  def emit_type_alias(node)
    "const #{node.name} = #{node.target};"
  end

  sig { params(node: MIR::ModuleNamespace).returns(String) }
  def emit_module_namespace(node)
    body = emit_body(node.items || [])
    "const #{node.name} = struct {\n#{indent_block(body, 4)}\n};"
  end

  sig { params(node: MIR::TestDef).returns(String) }
  def emit_test_def(node)
    body = emit_body(node.body)
    "test \"#{node.name}\" {\n#{body}\n}"
  end

  # --- Statement emitters ---

  sig { params(node: MIR::Let).returns(String) }
  def emit_let(node)
    if node.init.is_a?(MIR::FreezeExpr)
      buf  = "#{node.name}__buf"
      kw   = node.mutable ? "var" : "const"
      sup  = node.suppression ? " #{node.suppression}" : ""
      return "const #{buf} = #{emit(node.init)};\n#{kw} #{node.name} = #{buf}._root;#{sup}"
    end
    kw = node.mutable ? "var" : "const"
    ann = node.annotation ? ": #{node.annotation.zig_type}" : ""
    init = emit(node.init)
    sup = node.suppression ? " #{node.suppression}" : ""
    "#{kw} #{node.name}#{ann} = #{init};#{sup}"
  end

  sig { params(node: MIR::Set).returns(String) }
  def emit_set(node)
    "#{emit(node.target)} = #{emit(node.value)};"
  end

  sig { params(node: MIR::DestructureSet).returns(String) }
  def emit_destructure_set(node)
    targets = node.targets.map { |target| T.must(emit(target)) }.join(", ")
    "#{targets} = #{emit(node.value)};"
  end

  sig { params(node: MIR::DestructureTarget).returns(String) }
  def emit_destructure_target(node)
    return "_" if node.name.to_s == "_"

    annotation = node.annotation ? ": #{node.annotation.zig_type}" : ""
    case node.declaration_kind
    when :const, :var
      "#{node.declaration_kind} #{node.name}#{annotation}"
    else
      node.name.to_s
    end
  end

  sig { params(node: MIR::ReassignWithCleanup).returns(String) }
  def emit_reassign_cleanup(node)
    if (try_expr = reassign_success_only_expr(node))
      opt = "__new_#{node.name}_opt"
      val = "__new_#{node.name}_val"
      alloc = alloc_zig(node.alloc)
      return [
        "{",
        "const #{opt}: ?#{node.zig_type} = (#{emit(try_expr)} catch null);",
        "if (#{opt}) |#{val}| {",
        "    CheatLib.cleanup(@TypeOf(#{node.name}), #{alloc}, &#{node.name});",
        "    #{node.name} = #{val};",
        "}",
        "}",
      ].join("\n")
    end

    tmp = "__new_#{node.name}"
    val = emit(node.value)
    alloc = alloc_zig(node.alloc)
    "{\nconst #{tmp} = #{val};\nCheatLib.cleanup(@TypeOf(#{node.name}), #{alloc}, &#{node.name});\n#{node.name} = #{tmp};\n}"
  end

  sig { params(node: MIR::ReassignWithCleanup).returns(T.untyped) }
  def reassign_success_only_expr(node)
    value = node.value
    value = value.expr if value.is_a?(MIR::Cast)
    return nil unless value.is_a?(MIR::TryCatch)
    return nil unless value.capture.nil?
    catch_body = value.catch_body
    return nil unless catch_body.is_a?(MIR::Ident)
    return nil unless catch_body.name.to_s == node.name.to_s
    value.expr
  end

  sig { params(node: MIR::IfStmt).returns(String) }
  def emit_if_stmt(node)
    cond = emit(node.cond)
    cond = "comptime #{cond}" if node.comptime
    then_body = emit_body(node.then_body)
    result = "if (#{cond}) {\n#{then_body}\n}"
    if (else_stmts = node.else_body) && !else_stmts.empty?
      else_body = emit_body(else_stmts)
      result += " else {\n#{else_body}\n}"
    end
    result
  end

  sig { params(node: MIR::IfBindStmt).returns(String) }
  def emit_if_bind_stmt(node)
    then_body = emit_body(node.then_body)
    else_stmts = node.else_body
    else_body = else_stmts && !else_stmts.empty? ? emit_body(else_stmts) : nil

    if node.bindings.length == 1
      b = node.bindings[0]
      expr = emit(b[:expr])
      suppress = b[:capture].to_s == "_" ? "" : "_ = &#{b[:capture]};\n"
      if b[:node_ref]
        result = "{\nconst #{b[:capture]} = #{expr};\n"
        result += "if (!#{b[:capture]}.isNil()) {\n#{suppress}#{then_body}\n}"
        result += " else {\n#{else_body}\n}" if else_body
        result += "\n}"
      elsif b[:predicate] == :is_ok
        result = "if (#{expr}) |#{b[:capture]}| {\n#{suppress}#{then_body}\n}"
        result += " else |_| {\n#{else_body}\n}" if else_body
        result += " else |_| {}" unless else_body
      else
        result = "if (#{expr}) |#{b[:capture]}| {\n#{suppress}#{then_body}\n}"
        result += " else {\n#{else_body}\n}" if else_body
      end
      result
    else
      # Multi-binding: labeled break block
      @if_bind_counter = (@if_bind_counter || 0) + 1
      label = "__ib_#{@if_bind_counter}"
      ok_var = "__ib_ok_#{@if_bind_counter}"
      inner = node.bindings.map { |b|
        if b[:node_ref]
          "const #{b[:capture]} = #{emit(b[:expr])}; if (#{b[:capture]}.isNil()) break :#{label};"
        elsif b[:predicate] == :is_ok
          "const #{b[:capture]} = #{emit(b[:expr])} catch break :#{label};"
        else
          "const #{b[:capture]} = #{emit(b[:expr])} orelse break :#{label};"
        end
      }.join("\n")
      result = "var #{ok_var}: bool = false;\n"
      result += "#{label}: {\n#{inner}\n#{then_body}\n#{ok_var} = true;\n}"
      if else_body
        result += "\nif (!#{ok_var}) {\n#{else_body}\n}"
      end
      result
    end
  end

  sig { params(node: MIR::WhileStmt).returns(String) }
  def emit_while(node)
    cond = emit(node.cond)
    cap = node.capture ? " |#{node.capture}|" : ""
    upd = if node.update
      # Strip trailing semicolon for update expression in while header
      update_code = T.must(emit(node.update)).chomp(";")
      " : (#{update_code})"
    else
      ""
    end
    body = emit_body(node.body)
    capture_suppress = node.capture && node.capture.to_s != "_" ? "_ = &#{node.capture};\n" : ""
    "while (#{cond})#{upd}#{cap} {\n#{capture_suppress}#{body}\n}"
  end

  sig { params(node: MIR::ForStmt).returns(String) }
  def emit_for(node)
    iter = emit(node.iter)
    captures = [node.capture, node.index_capture].compact.join(", ")
    body = emit_body(node.body)
    if i64_range_capture_cast_required?(node)
      raw_capture = "__#{node.capture}_usize"
      return "for (#{iter}) |#{raw_capture}| {\nconst #{node.capture}: i64 = @intCast(#{raw_capture});\n#{body}\n}"
    end
    "for (#{iter}) |#{captures}| {\n#{body}\n}"
  end

  sig { params(node: MIR::ForStmt).returns(T::Boolean) }
  def i64_range_capture_cast_required?(node)
    iter = node.iter
    !!(iter.is_a?(MIR::IterRange) && iter.capture_type == :i64 &&
      node.index_capture.nil? && node.capture.is_a?(String) &&
      !node.capture.start_with?("*"))
  end

  sig { params(node: MIR::SwitchStmt).returns(String) }
  def emit_switch(node)
    subject = emit(node.subject)
    arms = node.arms.map { |arm|
      body = emit_body(arm.body)
      "#{emit_switch_patterns(arm.patterns)} => {\n#{body}\n}"
    }
    if (default_body = node.default_body)
      body = default_body.empty? ? "" : emit_body(default_body)
      arms << "else => {\n#{body}\n}"
    end
    "switch (#{subject}) {\n    #{arms.join(",\n    ")},\n}"
  end

  sig { params(patterns: T::Array[MIR::SwitchPattern]).returns(String) }
  def emit_switch_patterns(patterns)
    patterns.map { |pattern| emit_switch_pattern(pattern) }.join(", ")
  end

  sig { params(pattern: MIR::SwitchPattern).returns(String) }
  def emit_switch_pattern(pattern)
    case pattern
    when MIR::EnumSwitchPattern
      ".#{pattern.variant}"
    else
      T.must(emit(pattern))
    end
  end

  sig { params(node: MIR::CatchWrapper).returns(String) }
  def emit_catch_wrapper(node)
    inner_call = T.must(emit(node.inner_call))
    if node.clauses.empty?
      return "return #{inner_call} catch {\n#{indent_block(emit_catch_default_body(node), 4)}\n};"
    end

    branch_parts = node.clauses.each_with_index.map do |clause, index|
      emit_catch_clause(clause, node.rt_name, node.snapshot_type, index.zero?)
    end
    branch_parts << emit_catch_default(node)
    branch_chain = branch_parts.join(" else ")
    "return #{inner_call} catch {\n#{indent_block(branch_chain, 4)}\n};"
  end

  sig { params(clause: MIR::CatchClause, rt_name: String, snapshot_type: T.nilable(Type), first_clause: T::Boolean).returns(String) }
  def emit_catch_clause(clause, rt_name, snapshot_type, first_clause)
    body = emit_catch_body(rt_name, clause.body, snapshot_type)
    "if (#{emit_catch_condition(clause.meta, rt_name)}) {\n#{indent_block(body, 8)}\n}"
  end

  sig { params(node: MIR::CatchWrapper).returns(String) }
  def emit_catch_default(node)
    "{\n#{indent_block(emit_catch_default_body(node), 8)}\n}"
  end

  sig { params(node: MIR::CatchWrapper).returns(String) }
  def emit_catch_default_body(node)
    action = T.cast(node.default_action, MIR::CatchDefaultAction)
    case action
    when MIR::CatchDefaultAction::Body
      emit_catch_body(node.rt_name, node.default_body, nil)
    when MIR::CatchDefaultAction::Propagate
      "#{node.rt_name}.freeSnapshot();\nreturn error.CheatError;"
    when MIR::CatchDefaultAction::Unreachable
      "#{node.rt_name}.freeSnapshot();\nunreachable;"
    else
      T.absurd(action)
    end
  end

  sig { params(rt_name: String, body: T::Array[MIR::Emittable], snapshot_type: T.nilable(Type)).returns(String) }
  def emit_catch_body(rt_name, body, snapshot_type)
    parts = T.let([], T::Array[String])
    snapshot_decl = emit_catch_snapshot_decl(rt_name, snapshot_type)
    parts << snapshot_decl unless snapshot_decl.empty?
    parts << "const __error = #{rt_name}.__error;"
    parts << "_ = &__error;"
    parts << "defer #{rt_name}.freeSnapshot();"
    emitted_body = emit_body(body)
    parts << emitted_body unless emitted_body.empty?
    parts.join("\n")
  end

  sig { params(rt_name: String, snapshot_type: T.nilable(Type)).returns(String) }
  def emit_catch_snapshot_decl(rt_name, snapshot_type)
    return "" unless snapshot_type

    snap_zig = snapshot_type.zig_type
    [
      "const __snap_ptr = #{rt_name}.__error.snapshotAs(#{snap_zig});",
      "const snapshot = if (__snap_ptr) |p| p.* else undefined;",
      "const __has_snapshot = __snap_ptr != null;",
      "_ = &snapshot; _ = &__has_snapshot;",
    ].join("\n")
  end

  sig { params(meta: MIR::CatchClauseMeta, rt_name: String).returns(String) }
  def emit_catch_condition(meta, rt_name)
    item_checks = T.let([], T::Array[String])
    meta.kinds.each { |kind| item_checks << "#{rt_name}.__error.matchesKind(.#{kind})" }
    meta.types.each { |name| item_checks << "#{rt_name}.__error.matchesName(@intFromEnum(ErrorName.#{name}))" }

    item_cond = emit_catch_condition_group(item_checks, default: "true")

    filter_checks = T.let([], T::Array[String])
    meta.filter_types.each { |name| filter_checks << "#{rt_name}.__error.matchesName(@intFromEnum(ErrorName.#{name}))" }
    meta.filter_messages.each { |message| filter_checks << "#{rt_name}.__error.matchesMessage(#{T.must(emit(message))})" }
    return item_cond if filter_checks.empty?

    filter_cond = emit_catch_condition_group(filter_checks, default: "true")
    "#{item_cond} and #{filter_cond}"
  end

  sig { params(checks: T::Array[String], default: String).returns(String) }
  def emit_catch_condition_group(checks, default:)
    return default if checks.empty?
    return T.must(checks.first) if checks.length == 1

    "(#{checks.join(' or ')})"
  end

  sig { params(node: MIR::UnionMatchStmt).returns(String) }
  def emit_union_match(node)
    subject = emit(node.subject)
    arms = node.arms.map do |arm|
      body = emit_body(arm.body)
      payload = arm.payload
      capture = payload ? " |#{payload}|" : ""
      ".#{arm.variant} =>#{capture} {\n#{body}\n}"
    end
    if (default_body = node.default_body)
      body = default_body.empty? ? "" : emit_body(default_body)
      arms << "else => {\n#{body}\n}"
    end
    "switch (#{subject}) {\n    #{arms.join(",\n    ")},\n}"
  end

  sig { params(node: MIR::IfChain).returns(String) }
  def emit_if_chain(node)
    parts = node.branches.map { |br|
      cond = emit(br.cond)
      body = emit_body(br.body)
      "if (#{cond}) {\n#{body}\n}"
    }
    result = parts.join(" else ")
    if (default_body = node.default_body) && !default_body.empty?
      body = emit_body(default_body)
      result += " else {\n#{body}\n}"
    end
    result
  end

  sig { params(node: MIR::ReturnStmt).returns(String) }
  def emit_return(node)
    node.value ? "return #{emit(node.value)};" : "return;"
  end

  sig { params(node: MIR::BreakStmt).returns(String) }
  def emit_break(node)
    parts = ["break"]
    parts << ":#{node.label}" if node.label
    parts << T.must(emit(node.value)) if node.value
    "#{parts.join(' ')};"
  end

  sig { params(node: MIR::BreakExpr).returns(String) }
  def emit_break_expr(node)
    parts = ["break"]
    parts << ":#{node.label}" if node.label
    parts << T.must(emit(node.value)) if node.value
    parts.join(" ")
  end

  sig { params(node: MIR::IndexInsert).returns(String) }
  def emit_index_insert(node)
    map = emit(node.map)
    key = emit(node.key_expr)
    val = emit(node.value_expr)
    key_t = node.key_zig_type || "u8"
    elem_t = node.elem_zig_type
    alloc_str = case node.alloc
                when :heap, nil then "#{@rt_name || 'rt'}.heapAlloc()"
                when :frame     then "#{@rt_name || 'rt'}.frameAlloc()"
                else node.alloc.to_s
                end
    # Decompose to the existing getOrPut + value_ptr.append idiom.
    "{\n" \
    "    const __idx_key_owned = try #{alloc_str}.dupe(#{key_t}, #{key});\n" \
    "    var __gop = #{map}.inner.getOrPut(#{alloc_str}, __idx_key_owned) catch @panic(\"INDEX allocation failed\");\n" \
    "    if (__gop.found_existing) {\n" \
    "        #{alloc_str}.free(__idx_key_owned);\n" \
    "    } else {\n" \
    "        __gop.value_ptr.* = @as(std.ArrayListUnmanaged(#{elem_t}), .empty);\n" \
    "    }\n" \
    "    __gop.value_ptr.append(#{alloc_str}, #{val}) catch @panic(\"INDEX append failed\");\n" \
    "}"
  end

  sig { params(node: MIR::Sort).returns(String) }
  def emit_sort(node)
    et = node.elem_type
    items = emit(node.items_expr)
    "std.mem.sort(#{et}, #{items}, {}, struct {\n" \
      "    pub fn lessThan(_: void, a: #{et}, b: #{et}) bool {\n" \
      "        return #{emit(node.key_a)} < #{emit(node.key_b)};\n" \
      "    }\n" \
      "}.lessThan);"
  end

  sig { params(node: MIR::BatchWindowPush).returns(String) }
  def emit_batch_window_push(node)
    emit_batch_window_emit(node, "try #{node.window}.push(#{emit(node.item_expr)})")
  end

  sig { params(node: MIR::BatchWindowFlush).returns(String) }
  def emit_batch_window_flush(node)
    emit_batch_window_emit(node, "try #{node.window}.flush()")
  end

  sig { params(node: MIR::ThunkTrampoline).returns(String) }
  def emit_thunk_trampoline(node)
    return_type_zig = node.return_type.zig_type
    param_field_lines = emit_thunk_frame_field_decls(node.param_fields, indent: "            ")
    param_init = emit_thunk_frame_inits(node.param_init_fields)
    base_case_branches = node.base_cases.map { |bc|
      <<~ZIG.chomp
        if (#{emit(bc.cond)}) {
                            const result: #{return_type_zig} = #{emit(bc.value)};
        #{emit_thunk_return_or_pop}
                        }
      ZIG
    }.join("\n                    ")
    recurse_arg_inits = emit_thunk_frame_inits(node.recurse_arg_inits)
    combine_op = emit_thunk_combine_op(node.combine_op)

    <<~ZIG
      const Frame = struct {
              #{param_field_lines}
              step: u8 = 0,
              child_result: #{return_type_zig} = undefined,
              parent: ?*@This() = null,
          };
          var initial: Frame = .{ #{param_init} };
          var current: *Frame = &initial;
          while (true) {
              // Cooperative yield: hands control back to the scheduler
              // periodically (rt.checkYield uses its own internal
              // counter -- thunk depth doesn't fight the fiber's
              // own yield budget). Strippable via :TIGHT:THUNK
              // for tight inner loops where the caller manages
              // scheduler hand-off externally.
              #{emit_thunk_yield_statement(node.yield_policy)}
              switch (current.step) {
                  0 => {
                      #{base_case_branches}
                      // recursive call -- push child frame
                      const child = #{@rt_name}.heapAlloc().create(Frame) catch unreachable;
                      child.* = .{ #{recurse_arg_inits}, .parent = current };
                      current.step = 1;
                      current = child;
                      continue;
                  },
                  1 => {
                      const result: #{return_type_zig} = #{emit(node.combine_lhs)} #{combine_op} current.child_result;
      #{emit_thunk_return_or_pop}
                  },
                  else => unreachable,
              }
          }
    ZIG
  end

  sig { returns(String) }
  def emit_thunk_return_or_pop
    <<~ZIG.chomp
                          if (current.parent) |p| {
                              p.child_result = result;
                              if (current != &initial) #{@rt_name}.heapAlloc().destroy(current);
                              current = p;
                              continue;
                          }
                          return result;
    ZIG
  end

  sig { params(node: MIR::MutualThunkTrampoline).returns(String) }
  def emit_mutual_thunk_trampoline(node)
    variant_decls = node.variants.map { |variant|
      fields = emit_thunk_frame_field_decls(variant.param_fields, indent: "          ")
      <<~ZIG.chomp
        #{variant.name}: struct {
                  #{fields}
              },
      ZIG
    }.join("\n      ")
    initial_fields = emit_thunk_frame_inits(node.initial_fields)
    switch_arms = node.arms.map { |arm| emit_mutual_thunk_arm(arm) }.join("\n              ")

    <<~ZIG
      const Frame = union(enum) {
          #{variant_decls}
      };
      var current: Frame = .{ .#{node.initial_variant} = .{ #{initial_fields} } };
      while (true) {
          #{emit_thunk_yield_statement(node.yield_policy)}
          switch (current) {
              #{switch_arms}
          }
      }
    ZIG
  end

  sig { params(arm: MIR::MutualThunkArm).returns(String) }
  def emit_mutual_thunk_arm(arm)
    base_branches = arm.base_cases.map { |bc|
      <<~ZIG.chomp
        if (#{emit(bc.cond)}) {
                              return #{emit(bc.value)};
                          }
      ZIG
    }.join("\n                      ")
    target_arg_inits = emit_thunk_frame_inits(arm.target_arg_inits)

    <<~ZIG.chomp
      .#{arm.variant_name} => |f| {
                      #{base_branches}
                      current = .{ .#{arm.target_variant} = .{ #{target_arg_inits} } };
                      continue;
                  },
    ZIG
  end

  sig { params(inits: T::Array[MIR::ThunkFrameInit]).returns(String) }
  def emit_thunk_frame_inits(inits)
    inits.map { |init| ".#{init.field_name} = #{emit(init.value)}" }.join(", ")
  end

  sig { params(fields: T::Array[MIR::ThunkFrameField], indent: String).returns(String) }
  def emit_thunk_frame_field_decls(fields, indent:)
    fields.map { |field| "#{field.name}: #{field.type_info.zig_type}," }.join("\n#{indent}")
  end

  sig { params(policy: Symbol).returns(String) }
  def emit_thunk_yield_statement(policy)
    case policy
    when :check
      "#{@rt_name}.checkYield();"
    when :tight_skip
      "// (TIGHT: scheduler yield-check skipped)"
    else
      Kernel.raise "unknown thunk yield policy: #{policy.inspect}"
    end
  end

  sig { params(op: Symbol).returns(String) }
  def emit_thunk_combine_op(op)
    THUNK_COMBINE_OPERATOR.fetch(op) { Kernel.raise "unknown thunk combine op: #{op.inspect}" }
  end

  sig { params(node: T.any(MIR::BatchWindowPush, MIR::BatchWindowFlush), source: String).returns(String) }
  def emit_batch_window_emit(node, source)
    slice = "#{node.batch_var}_slice"
    val = "#{node.batch_var}_val"
    alloc = alloc_zig(node.alloc)
    <<~ZIG.strip
      if (#{source}) |#{slice}| {
          defer #{node.window}.freeBatch(#{slice});
          var #{node.batch_var} = std.ArrayListUnmanaged(#{node.elem_zig}){ .items = #{slice}, .capacity = #{slice}.len };
          _ = &#{node.batch_var};
          const #{val} = #{emit(node.value_expr)};
          try #{node.result_var}.append(#{alloc}, #{val});
      }
    ZIG
  end

  sig { params(node: MIR::ScopeBlock).returns(String) }
  def emit_scope_block(node)
    body = emit_body(node.body)
    "{\n#{body}\n}"
  end

  sig { params(node: MIR::DeferStmt).returns(String) }
  def emit_defer(node)
    emit_defer_like("defer", emit_defer_body(node.body))
  end

  sig { params(node: MIR::ErrDeferStmt).returns(String) }
  def emit_errdefer(node)
    emit_defer_like("errdefer", emit_defer_body(node.body))
  end

  sig { params(body: MIR::DeferBody).returns(String) }
  def emit_defer_body(body)
    body.is_a?(Array) ? "{\n#{indent_block(emit_body(body), 4)}\n}" : T.must(emit(body))
  end

  sig { params(keyword: String, body: T.nilable(String)).returns(String) }
  def emit_defer_like(keyword, body)
    body = T.must(body)
    return "#{keyword} #{body}" if body.start_with?("{")

    "#{keyword} #{body};"
  end

  sig { params(node: MIR::ExprStmt).returns(String) }
  def emit_expr_stmt(node)
    code = emit(node.expr)
    node.discard ? "_ = #{code};" : "#{code};"
  end

  # --- Memory operation emitters ---

  sig { params(node: MIR::HeapCreate).returns(String) }
  def emit_heap_create(node)
    label = node.label || "__hc"
    init = emit(node.init)
    alloc = alloc_expr(node.alloc)
    "#{label}: {\n" \
    "    const __p = try #{alloc}.create(#{node.zig_type});\n" \
    "    errdefer #{alloc}.destroy(__p);\n" \
    "    __p.* = #{init};\n" \
    "    break :#{label} __p;\n" \
    "}"
  end

  sig { params(node: MIR::DupeSlice).returns(String) }
  def emit_dupe_slice(node)
    "@as([]const u8, try #{alloc_expr(node.alloc)}.dupe(u8, #{emit(node.source)}))"
  end

  sig { params(node: MIR::AllocSlice).returns(String) }
  def emit_alloc_slice(node)
    "try #{alloc_expr(node.alloc)}.alloc(#{node.elem_type}, #{emit(node.len)})"
  end

  sig { params(node: MIR::FreeSlice).returns(String) }
  def emit_free_slice(node)
    "#{alloc_expr(node.alloc)}.free(#{emit(node.slice)})"
  end

  sig { params(node: MIR::DestroyPtr).returns(String) }
  def emit_destroy_ptr(node)
    "#{alloc_expr(node.alloc)}.destroy(#{emit(node.ptr)})"
  end

  # Allocation-producing MIR nodes carry allocator symbols. Free/destroy nodes
  # may also carry a MIR allocator expression inside generated destructor
  # helpers, where the allocator is an explicit parameter.
  sig { params(alloc: T.any(Symbol, MIR::Emittable)).returns(String) }
  def alloc_expr(alloc)
    alloc.is_a?(Symbol) ? alloc_zig(alloc) : T.must(emit(alloc))
  end

  # Emit cleanup for MIR::Cleanup (defer) and MIR::ErrCleanup (errdefer).
  # errdefer: true  -> always emits `errdefer cleanup(name)` (no moved guard).
  # errdefer: false -> emits `defer cleanup(name)` with optional moved guard
  #                    based on entry.has_moved_guard?.
  # The caller (emit dispatch) decides which; this method applies the template.
  public

  sig { params(stmts: T::Array[MIR::Node]).returns(String) }
  def emit_stmt_list(stmts)
    emit_body(stmts)
  end

  sig { params(name: String, entry: CleanupEntry, alloc_override: T.nilable(String)).returns(String) }
  def emit_direct_cleanup(name, entry, alloc_override: nil)
    alloc = alloc_override || alloc_from_entry(entry)
    guarded = entry.has_moved_guard?
    via_pointer = entry.via_pointer?

    case entry.kind
    when :resource
      close = render_resource_close_plan(T.must(entry.resource_close_plan), name)
      direct_cleanup_statement(name, close, guarded)
    else
      rc_alloc = entry.rc_alloc
      use_alloc =
        if entry.kind == :rc && rc_alloc && alloc_override.nil?
          alloc_from_sym(rc_alloc)
        else
          alloc
        end
      use_name = entry.kind == :frozen ? "#{name}__buf" : name
      use_type = via_pointer ? "@TypeOf(#{use_name}.*)" : "@TypeOf(#{use_name})"
      result = direct_uniform_cleanup(use_name, use_type, use_alloc, guarded, via_pointer:)
      if entry.rc_release_fields_cleanup?
        guard = guarded ? "if (!#{name}_moved) " : ""
        result += "\n#{guard}CheatLib.releaseFields(#{entry.base_zig}, #{use_alloc}, #{name}.ctrl.data.*);"
      end
      result
    end
  end

  private

  sig { params(node: T.any(MIR::Cleanup, MIR::ErrCleanup), errdefer: T::Boolean).returns(String) }
  def emit_cleanup(node, errdefer: false)
    entry = node.cleanup_entry
    alloc = alloc_from_entry(entry)
    name = node.name
    g = entry.has_moved_guard?
    # via_pointer: true when the binding is already *T (e.g. needs_pointer_passing?
    # TAKES params). Cleanup unwraps one pointer level via @TypeOf(name.*).
    vp = entry.via_pointer?

    case entry.kind
    when :resource
      close = render_resource_close_plan(T.must(entry.resource_close_plan), name)
      guarded_defer(name, close, g, errdefer:)

    else
      # The uniform cleanup path. Every other kind dispatches identically
      # through CheatLib.cleanup(@TypeOf(name), alloc, &name) -- the
      # runtime arms (ArrayList, slice, String, Pool, Set, StringMap,
      # Locked, RwLocked, Versioned, Rc/Arc/WeakRc/WeakArc, Observable,
      # struct-with-deinit, struct-recursive, generic *T) comptime-
      # dispatch on the binding's actual type. The kind axis signals
      # three side-channel behaviors:
      #   :rc + rc_alloc          -> binding-specific allocator
      #   :rc + needs_release_fields -> post-cleanup releaseFields call
      #   :frozen                 -> cleanup operates on the paired
      #                              `name__buf` binding
      use_alloc =
        if entry.kind == :rc && entry.rc_alloc
          alloc_from_sym(T.must(entry.rc_alloc))
        else
          alloc
        end
      use_name = entry.kind == :frozen ? "#{name}__buf" : name
      # via_pointer bindings hold *T directly; strip one pointer level
      # so cleanup's T matches the pointee shape.
      use_type = vp ? "@TypeOf(#{use_name}.*)" : "@TypeOf(#{use_name})"
      result = guarded_cleanup(use_name, use_type, use_alloc, g, errdefer:, via_pointer: vp)
      if entry.rc_release_fields_cleanup?
        guard = g ? "if (!#{name}_moved) " : ""
        kw = errdefer ? "errdefer" : "defer"
        result += "#{kw} #{guard}CheatLib.releaseFields(#{entry.base_zig}, #{use_alloc}, #{name}.ctrl.data.*);\n"
      end
      result
    end
  end

  sig { params(node: MIR::MoveMark).returns(String) }
  def emit_move_mark(node)
    "#{node.name}_moved = true;"
  end

  sig { params(node: MIR::DeepCopy).returns(T.nilable(String)) }
  def emit_deep_copy(node)
    src = emit(node.source)
    alloc = node.alloc ? alloc_expr(node.alloc) : nil
    # Uniquify the blk label across nested DeepCopy emits in the same scope.
    @deep_copy_counter = T.let(T.let(@deep_copy_counter || 0, Integer) + 1, T.nilable(Integer))
    bc = "blk_copy_#{@deep_copy_counter}"
    case node.strategy
    when :passthrough
      # Borrow-to-owned passthrough: auto-deref single pointers but keep
      # value-shaped sources unchanged. No allocation -- this is the
      # no-op COPY for Copy-type sources. comptime-evaluated branch.
      "(if (@typeInfo(@TypeOf(#{src})) == .pointer) #{src}.* else #{src})"
    when :full_value
      type_arg = node.copy_shape == :pointer ? "@TypeOf(#{src})" : (node.zig_type || "@TypeOf(#{src})")
      if node.copy_shape == :slice
        "#{bc}: { const __copy_src = #{src}; break :#{bc} try CheatLib.dupeValue(#{type_arg}, __copy_src, #{alloc}); }"
      else
        pointer_type_arg = node.copy_shape == :pointer ? "@TypeOf(#{src})" : (node.zig_type || "@TypeOf(__copy_src)")
        pointer_value = node.copy_shape == :value ? "__copy_src.*" : "__copy_src"
        "#{bc}: { const __copy_src = #{src}; if (comptime @typeInfo(@TypeOf(__copy_src)) == .pointer and @typeInfo(@TypeOf(__copy_src)).pointer.size == .one) { break :#{bc} try CheatLib.dupeValue(#{pointer_type_arg}, #{pointer_value}, #{alloc}); } else { break :#{bc} try CheatLib.dupeValue(#{type_arg}, __copy_src, #{alloc}); } }"
      end
    else
      raise "MIREmitter#emit_deep_copy: unhandled strategy :#{node.strategy}"
    end
  end

  sig { params(node: MIR::ContainerInit).returns(String) }
  def emit_container_init(node)
    case node.strategy
    when :pool, :list_capacity
      "try #{node.zig_type}.initCapacity(#{alloc_zig(node.alloc)}, #{node.capacity})"
    when :array_list_empty
      "@as(#{node.zig_type}, .empty)"
    when :list_empty, :set_empty, :map_empty
      "#{node.zig_type}{}"
    when :map_bare
      "#{node.zig_type}{ .alloc = #{alloc_zig(node.alloc)} }"
    else
      raise "MIREmitter#emit_container_init: unhandled strategy :#{node.strategy}"
    end
  end

  sig { params(node: MIR::CapWrap).returns(T.nilable(String)) }
  def emit_cap_wrap(node)
    inner = emit(node.inner)
    alloc = alloc_zig(node.alloc)
    case node.strategy
    when :local
      "try CheatLib.localCreate(#{node.zig_base}, #{alloc}, #{inner})"
    when :sync_only
      "try CheatLib.#{node.sync_fn}(#{node.zig_base}, #{alloc}, #{inner})"
    when :own_only
      "try CheatLib.#{node.own_fn}(#{node.zig_base}, #{alloc}, #{inner})"
    when :both
      <<~ZIG.chomp
        blk_cap: {
            const __cap_inner = try CheatLib.#{node.sync_fn}(#{node.zig_base}, #{alloc}, #{inner});
            const __cap_val = __cap_inner.*;
            #{alloc}.destroy(__cap_inner);
            break :blk_cap try CheatLib.#{node.own_fn}(#{node.sync_type}, #{alloc}, __cap_val);
        }
      ZIG
    when :passthrough
      inner
    else
      raise "MIREmitter#emit_cap_wrap: unhandled strategy :#{node.strategy}"
    end
  end

  sig { params(node: MIR::SharePromote).returns(String) }
  def emit_share_promote(node)
    source = emit(node.source)
    alloc = alloc_zig(node.alloc)
    <<~ZIG.chomp
      blk_share: {
          const __share_src = #{source};
          errdefer CheatLib.rcRelease(#{node.zig_base}, #{alloc}, __share_src);
          var __share_val = try CheatLib.dupeValue(#{node.zig_base}, __share_src.ctrl.data.*, #{alloc});
          errdefer CheatLib.cleanup(#{node.zig_base}, #{alloc}, &__share_val);
          const __share_arc = try CheatLib.arcCreate(#{node.zig_base}, #{alloc}, __share_val);
          CheatLib.rcRelease(#{node.zig_base}, #{alloc}, __share_src);
          break :blk_share __share_arc;
      }
    ZIG
  end

  sig { params(node: MIR::RcRetain).returns(String) }
  def emit_rc_retain(node)
    "CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"
  end

  sig { params(node: MIR::RcRelease).returns(String) }
  def emit_rc_release(node)
    "CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.alloc)}, #{emit(node.source)})"
  end

  sig { params(node: MIR::RcDowngrade).returns(String) }
  def emit_rc_downgrade(node)
    "CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"
  end

  sig { params(node: MIR::WeakUpgrade).returns(String) }
  def emit_weak_upgrade(node)
    "CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"
  end

  sig { params(node: MIR::FreezeExpr).returns(String) }
  def emit_freeze(node)
    "try CheatLib.freeze(#{node.zig_base}, #{emit(node.alloc_ref)}, #{emit(node.inner)})"
  end

  sig { params(node: MIR::MakeList).returns(String) }
  def emit_make_list(node)
    items = node.items.map { |i| emit(i) }.join(", ")
    items_expr = node.items.empty? ? "&.{}" : "&.{ #{items} }"
    "try CheatLib.makeList(#{node.elem_type}, #{alloc_zig(node.alloc)}, #{items_expr})"
  end

  sig { params(node: MIR::FrameSave).returns(String) }
  def emit_frame_save(node)
    "const frame_mark = #{node.rt_expr}.saveFrameMark();"
  end

  sig { params(node: MIR::FrameRestore).returns(String) }
  def emit_frame_restore(node)
    "defer #{node.rt_expr}.restoreFrameMark(frame_mark);"
  end

  # --- Expression emitters ---

  sig { params(node: MIR::Call).returns(String) }
  def emit_call(node)
    args = node.args.map { |a| emit(a) }.join(", ")
    call = "#{runtime_scoped_callee(node.callee)}(#{args})"
    node.try_wrap ? "try #{call}" : call
  end

  sig { params(node: MIR::RuntimeCall).returns(String) }
  def emit_runtime_call(node)
    emit_call(node.spec.call(node.args))
  end

  sig { params(callee: String).returns(String) }
  def runtime_scoped_callee(callee)
    text = callee.to_s
    text.start_with?("rt.") ? "#{@rt_name}.#{text.delete_prefix("rt.")}" : text
  end

  sig { params(node: MIR::TailCall).returns(String) }
  def emit_tail_call(node)
    args = node.args.map { |a| emit(a) }.join(", ")
    "@call(.always_tail, #{node.callee}, .{#{args}})"
  end

  sig { params(node: MIR::MethodCall).returns(String) }
  def emit_method_call(node)
    recv = emit(node.receiver)
    args = node.args.map { |a| emit(a) }.join(", ")
    call = "#{recv}.#{node.method}(#{args})"
    node.try_wrap ? "try #{call}" : call
  end

  sig { params(node: MIR::FieldGet).returns(String) }
  def emit_field_get(node)
    "#{paren_if_try(T.must(emit(node.object)))}.#{node.field}"
  end

  sig { params(node: MIR::UnionPayloadGet).returns(String) }
  def emit_union_payload_get(node)
    subject = T.must(emit(node.subject))
    variant = node.variant.to_s
    "(switch (#{subject}) { .#{variant} => |payload| payload, else => unreachable })"
  end

  sig { params(node: MIR::AssertStmt).returns(String) }
  def emit_assert_stmt(node)
    "CheatLib.assert(#{emit(node.cond)}, #{node.message});"
  end

  sig { params(node: MIR::AssertRaisesCheck).returns(String) }
  def emit_assert_raises_check(node)
    error_check = node.error_name ? " and !#{node.rt_name}.__error.matchesName(@intFromEnum(ErrorName.#{node.error_name}))" : ""
    <<~ZIG.rstrip
      {
          if (#{emit(node.expr)}) |_| {
              @panic("ASSERT_RAISES: expected #{node.kind} error but none raised");
          } else |_| {
              if (!#{node.rt_name}.__error.matchesKind(.#{node.kind})#{error_check}) {
                  @panic("ASSERT_RAISES: expected #{node.kind} error, got different kind");
              }
          }
      }
    ZIG
  end

  sig { returns(String) }
  def emit_test_preamble
    <<~ZIG.chomp
      var da = std.heap.DebugAllocator(.{}){};
          defer _ = da.deinit();
          const allocator = da.allocator();
          var global_ctx = EbrContext{};
          defer global_ctx.deinit(allocator);
          var __rt_box = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
          defer __rt_box.deinit();
          __rt_box.wireAllocator();
          const rt: *Runtime = &__rt_box; _ = &rt;
    ZIG
  end

  sig { params(node: MIR::DebugOnly).returns(String) }
  def emit_debug_only(node)
    body = emit_body(node.body || [])
    <<~ZIG.rstrip
      if (@import("builtin").mode == .Debug) {
      #{indent_block(body, 4)}
      }
    ZIG
  end

  # Parenthesize try-expressions to prevent Zig precedence issues where
  # `try X.field` parses as `try (X.field)` instead of `(try X).field`.
  sig { params(expr: String).returns(String) }
  def paren_if_try(expr)
    expr.start_with?("try ") ? "(#{expr})" : expr
  end

  sig { params(node: MIR::IndexGet).returns(String) }
  def emit_index_get(node)
    "#{emit(node.object)}[#{emit(node.index)}]"
  end

  sig { params(node: MIR::BinOp).returns(String) }
  def emit_bin_op(node)
    "(#{emit(node.left)} #{node.op} #{emit(node.right)})"
  end

  sig { params(node: MIR::UnaryOp).returns(String) }
  def emit_unary_op(node)
    "#{node.op}#{emit(node.operand)}"
  end

  sig { params(node: MIR::PointerCast).returns(String) }
  def emit_pointer_cast(node)
    "@as(#{node.target_type}, @ptrCast(@alignCast(#{emit(node.expr)})))"
  end

  sig { params(node: MIR::DefaultStreamCapacity).returns(String) }
  def emit_default_stream_capacity(node)
    workers = emit(node.worker_count)
    "blk: { var c: usize = 4; while (c < #{workers} * 4) : (c <<= 1) {} break :blk @min(c, 64); }"
  end

  sig { params(node: MIR::NextPromiseList).returns(String) }
  def emit_next_promise_list(node)
    list_expr = paren_if_try(T.must(emit(node.list_expr)))
    alloc = alloc_zig(node.alloc)
    <<~ZIG.rstrip
      #{node.label}: {
          var #{node.results_var} = std.ArrayListUnmanaged(#{node.elem_zig}).empty;
          for (#{list_expr}.items) |__p| {
              try #{node.results_var}.append(#{alloc}, try __p.next());
          }
          break :#{node.label} #{node.results_var};
      }
    ZIG
  end

  sig { params(node: MIR::StructInit).returns(String) }
  def emit_struct_init(node)
    fields = node.fields.filter_map do |field|
      name = MIR.struct_init_field_name(field)
      value = MIR.struct_init_field_value(field)
      next nil unless name && value

      ".#{name} = #{emit(value)}"
    end.join(", ")
    if node.zig_type
      "#{node.zig_type}{ #{fields} }"
    else
      ".{ #{fields} }"
    end
  end

  sig { params(node: MIR::TupleLiteral).returns(String) }
  def emit_tuple_literal(node)
    ".{#{node.items.map { |item| emit(item) }.join(", ")}}"
  end

  sig { params(node: MIR::LockAcquire).returns(String) }
  def emit_lock_acquire(node)
    lock_expr = T.must(emit(node.lock_expr))
    if node.lock_sync == :write_locked
      return "#{lock_expr}.#{node.fallible ? "writeOrErr" : "write"}()"
    end
    if node.lock_sync == :locked
      return "#{lock_expr}.#{node.fallible ? "acquireOrErr" : "acquire"}()"
    end

    write_method = node.fallible ? "writeOrErr" : "write"
    acquire_method = node.fallible ? "acquireOrErr" : "acquire"
    "(if (comptime @hasDecl(@TypeOf(#{lock_expr}), \"#{write_method}\")) " \
      "#{lock_expr}.#{write_method}() else #{lock_expr}.#{acquire_method}())"
  end

  sig { params(node: MIR::ArrayInit).returns(String) }
  def emit_array_init(node)
    items = node.items.map { |i| emit(i) }.join(", ")
    "[#{node.count}]#{node.elem_type}{ #{items} }"
  end

  sig { params(node: MIR::ArrayDefaultInit).returns(String) }
  def emit_array_default_init(node)
    "[_]#{node.elem_type}{ #{emit(node.default_value)} } ** #{node.count}"
  end

  sig { params(node: MIR::SliceExpr).returns(String) }
  def emit_slice_expr(node)
    target = emit(node.target)
    s = emit(node.start)
    # node.end_expr may be nil to indicate an open-ended slice `target[start..]`.
    range = node.end_expr ? "#{s}..#{emit(node.end_expr)}" : "#{s}.."
    if node.elem_type
      "@as([]const #{node.elem_type}, #{target}[#{range}])"
    else
      "#{target}[#{range}]"
    end
  end

  sig { params(node: MIR::BlockExpr).returns(String) }
  def emit_block_expr(node)
    body = emit_body(node.body)
    label_prefix = node.label ? "#{node.label}: " : ""
    "#{label_prefix}{\n#{body}\n}"
  end

  sig { params(node: MIR::ConcatStr).returns(String) }
  def emit_concat(node)
    parts = node.parts.map { |p| emit(p) }.join(", ")
    "try std.mem.concat(#{alloc_zig(node.alloc)}, u8, &.{ #{parts} })"
  end

  sig { params(node: MIR::Cast).returns(String) }
  def emit_cast(node)
    inner = emit(node.expr)
    # `@as(!T, ...)` and `@as(!?T, ...)` parse as `@as(boolean_not, ...)`
    # in expression context. Force type interpretation by prefixing with
    # `anyerror`. (Same workaround as Promise(anyerror!T) in type.rb's
    # tense path; the inferred error set folds into anyerror at the
    # call site.)
    target_t = node.target_type
    target_t = ZigType.new(target_t).cast_target_type if target_t
    case node.method
    when :as
      "@as(#{target_t}, #{inner})"
    when :intCast
      target_t ? "@as(#{target_t}, @intCast(#{inner}))" : "@intCast(#{inner})"
    when :floatCast
      "@floatCast(#{inner})"
    when :ptrCast
      "@ptrCast(#{inner})"
    when :intFromFloat
      "@intFromFloat(#{inner})"
    when :floatFromInt
      "@floatFromInt(#{inner})"
    when :truncate
      "@truncate(#{inner})"
    when :enumFromInt
      # Modern Zig requires the result type to be known at the call site.
      # When we have one (cast targets a named enum), wrap with @as so it
      # works in any expression position (`const x =`, `arr.append(...)`).
      target_t ? "@as(#{target_t}, @enumFromInt(#{inner}))" : "@enumFromInt(#{inner})"
    else
      raise "MIREmitter#emit_cast: unknown method :#{node.method}"
    end
  end

  sig { params(node: MIR::Orelse).returns(String) }
  def emit_orelse(node)
    fallback = emit(node.fallback)
    result_type = node.result_type
    fallback = "@as(#{result_type.zig_type}, #{fallback})" if result_type
    "(#{emit(node.expr)} orelse #{fallback})"
  end

  sig { params(node: MIR::TryCatch).returns(String) }
  def emit_try_catch(node)
    expr = emit(node.expr)
    catch_body = emit(node.catch_body)
    cap = node.capture ? " |#{node.capture}|" : ""
    "(#{expr} catch#{cap} #{catch_body})"
  end

  sig { params(node: MIR::DiscardOwned).returns(String) }
  def emit_discard_owned(node)
    @discard_counter += 1
    name = "__discard_#{@discard_counter}"

    discard_expr = node.expr
    if discard_success_only?(discard_expr)
      success_expr = T.cast(discard_expr, MIR::TryCatch)
      opt = "#{name}_opt"
      expr = emit(success_expr.expr)
      body = [
        "{",
        "const #{opt}: ?#{node.zig_type} = (#{expr} catch null);",
        "if (#{opt}) |#{name}_val| {",
        "var #{name} = #{name}_val;",
        indent_block(emit_cleanup(MIR::Cleanup.new(name, node.cleanup_entry), errdefer: false), 4),
        "}",
        "}",
      ].join("\n")
      return body
    end

    [
      "{",
      "var #{name} = #{emit(node.expr)};",
      indent_block(emit_cleanup(MIR::Cleanup.new(name, node.cleanup_entry), errdefer: false), 4),
      "}",
    ].join("\n")
  end

  sig { params(expr: MIR::Node).returns(T::Boolean) }
  def discard_success_only?(expr)
    return false unless expr.is_a?(MIR::TryCatch) && expr.capture.nil?

    catch_body = expr.catch_body
    (catch_body.is_a?(MIR::Ident) && catch_body.name.to_s == "undefined") ||
      catch_body.is_a?(MIR::Undef)
  end

  sig { params(node: MIR::Conditional).returns(String) }
  def emit_conditional(node)
    "(if (#{emit(node.cond)}) #{emit(node.then_val)} else #{emit(node.else_val)})"
  end

  sig { params(node: MIR::IfOptional).returns(String) }
  def emit_if_optional(node)
    then_expr = emit(node.then_expr)
    if node.result_type&.optional?
      then_expr = "@as(#{T.must(node.result_type).zig_type}, #{then_expr})"
    end
    "(if (#{emit(node.optional)}) |#{node.capture}| #{then_expr} else #{emit(node.else_expr)})"
  end

  sig { params(node: MIR::AllocatorRef).returns(String) }
  def emit_allocator_ref(node)
    # Use @rt_name (matches alloc_zig) so callers that swap rt_name
    # — e.g. lower_range_fold_observable's body-emit phase, which
    # rewrites `rt` to the consumer fiber's `__rt_obs_N` — produce
    # consistent allocator strings across both AllocatorRef and
    # alloc_zig-emitted call sites.
    MIR::Placement.zig_allocator(node.kind, @rt_name)
  end

  sig { params(node: MIR::TypeSentinel).returns(T.nilable(String)) }
  def emit_type_sentinel(node)
    t = node.zig_type.to_s
    case node.extreme
    when :max
      if ZigType.float_identifier?(t) then "std.math.floatMax(#{t})"
      elsif ZigType.integer_identifier?(t) then "std.math.maxInt(#{t})"
      else "std.math.floatMax(f64)"
      end
    when :min
      if ZigType.float_identifier?(t) then "-std.math.floatMax(#{t})"
      elsif ZigType.integer_identifier?(t) then "std.math.minInt(#{t})"
      else "-std.math.floatMax(f64)"
      end
    end
  end

  sig { params(node: MIR::DefaultValue).returns(String) }
  def emit_default_value(node)
    case node.kind
    when :aggregate_empty
      ".{}"
    when :string_empty
      '@as([]const u8, "")'
    when :collection_empty
      "@as(#{T.must(node.zig_type)}, .empty)"
    when :undefined
      node.zig_type ? "@as(#{node.zig_type}, undefined)" : "undefined"
    else
      raise "unknown MIR::DefaultValue kind #{node.kind.inspect}"
    end
  end

  sig { params(node: MIR::RangeLit).returns(String) }
  def emit_range_lit(node)
    s = emit(node.start)
    e = emit(node.end_val)
    if node.elem_type == :Int64
      "CheatLib.IntRange{ .start = #{s}, .end = #{e} }"
    else
      "CheatLib.Range{ .start = #{s}, .end = #{e} }"
    end
  end

  sig { params(node: MIR::HasField).returns(String) }
  def emit_has_field(node)
    "@hasField(@TypeOf(#{emit(node.expr)}), \"#{node.field}\")"
  end

  sig { params(node: MIR::LambdaExpr).returns(String) }
  def emit_lambda(node)
    fn = node.fn_def
    fn_zig = emit_fn_def(fn)
    "&(struct { #{fn_zig} }).#{fn.name}"
  end

  sig { params(node: MIR::ItemsAccess).returns(String) }
  def emit_items_access(node)
    inner = emit(node.expr)
    if node.safe
      # Slice coercion via comptime block:
      #   ArrayList(T)        -> .items
      #   *ArrayList(T)       -> .*.items  (deref then .items)
      #   [N]T / *const [N]T  -> [0..]   (with @constCast to bridge const
      #                                   fixed-array bindings to mutable
      #                                   slice params; CLEAR's annotator
      #                                   guarantees no mutation through
      #                                   borrow-position params)
      # The `*ArrayList` arm fires for callees whose caller passed a
      # `MUTABLE @list` param straight through (e.g. forwarding a
      # pointer-passed list to a borrow-shape callee).
      # Uniquify the blk label so multiple ItemsAccess emits in the same
      # Zig scope don't redefine each other. Zig rejects duplicate labels
      # even in nested expression positions.
      @items_block_counter = T.let(T.let(@items_block_counter || 0, Integer) + 1, T.nilable(Integer))
      label = "blk_items_#{@items_block_counter}"
      "#{label}: { const __x = if (@typeInfo(@TypeOf(#{inner})) == .pointer and @typeInfo(@TypeOf(#{inner})).pointer.size == .one) #{inner}.* else #{inner}; break :#{label} if (@hasField(@TypeOf(__x), \"items\")) __x.items else @constCast(__x[0..]); }"
    else
      "#{inner}.items"
    end
  end

  sig { params(node: MIR::OwnedSlice).returns(String) }
  def emit_owned_slice(node)
    inner = emit(node.expr)
    label = "blk_owned_slice_#{node.object_id.abs}"
    alloc = alloc_expr(node.alloc)
    "#{label}: { var __x = #{inner}; " \
      "break :#{label} if (comptime @typeInfo(@TypeOf(__x)) == .@\"struct\" and @hasDecl(@TypeOf(__x), \"toOwnedSlice\")) " \
      "try __x.toOwnedSlice(#{alloc}) else " \
      "__x; }"
  end

  # --- Helpers ---

  sig { params(stmts: T::Array[MIR::Node]).returns(String) }
  def emit_body(stmts)
    return "" unless stmts
    stmts.filter_map { |s|
      code = emit(s)
      next nil unless code
      # Expression nodes used as statements need trailing semicolons.
      # Statement nodes (Let, Set, If, While, etc.) already include them
      # or end with }. Block openers ({) and closers (}) never get ;.
      stripped = code.strip
      if semicolon_required?(s, stripped)
        "#{code};"
      else
        code
      end
    }.join("\n")
  end

  sig { params(stmt: MIR::Node, stripped: String).returns(T::Boolean) }
  def semicolon_required?(stmt, stripped)
    stmt.expr? && !stripped.end_with?(";") && !stripped.end_with?("}") &&
      !stripped.end_with?("{")
  end

  sig { params(entry: CleanupEntry).returns(String) }
  def alloc_from_entry(entry)
    alloc_zig(entry.alloc)
  end

  sig { params(sym: Symbol).returns(String) }
  def alloc_from_sym(sym)
    alloc_zig(sym)
  end

  # Single source of truth: symbol -> Zig allocator expression.
  sig { params(sym: Symbol).returns(String) }
  def alloc_zig(sym)
    raise "alloc_zig: unknown allocator symbol :#{sym.inspect}" unless sym == :heap || sym == :frame

    MIR::Placement.zig_allocator(sym, @rt_name)
  end

  sig { params(name: String, body: String, guarded: T::Boolean, errdefer: T::Boolean).returns(String) }
  def guarded_defer(name, body, guarded, errdefer: false)
    kw = errdefer ? "errdefer" : "defer"
    if guarded
      "var #{name}_moved = false; _ = &#{name}_moved;\n#{kw} if (!#{name}_moved) #{body};\n"
    elsif body.start_with?("{") && body.end_with?("}")
      "#{kw} #{body}\n"
    else
      "#{kw} #{body};\n"
    end
  end

  # +via_pointer+: when true, +name+ is already *T (e.g. needs_pointer_passing?
  # TAKES params arrive as *HashMap or *Pool from the call site's & wrapping).
  # CheatLib.cleanup expects *const T, so re-applying & would produce *const *T.
  # Pass +name+ directly in that case.
  sig { params(name: String, zig_type: String, alloc: String, guarded: T::Boolean, errdefer: T::Boolean, via_pointer: T.nilable(T::Boolean)).returns(String) }
  def guarded_cleanup(name, zig_type, alloc, guarded, errdefer: false, via_pointer: false)
    kw = errdefer ? "errdefer" : "defer"
    arg = via_pointer ? name : "&#{name}"
    # Cleanup operates on the storage type, not the error-union type.
    # If the binding came from a fallible call (`MUTABLE x = fn()`
    # where fn is `!T`), the annotator stamps `x` as `!T`, but the
    # Zig variable holds `T` post-`try`. Strip a leading `!`.
    zig_type = ZigType.new(zig_type).cleanup_storage_type
    if guarded
      guarded_defer(name, "CheatLib.cleanup(#{zig_type}, #{alloc}, #{arg})", true, errdefer:)
    else
      "#{kw} CheatLib.cleanup(#{zig_type}, #{alloc}, #{arg});\n"
    end
  end

  sig { params(plan: Schemas::ResourceClosePlan, root_name: String).returns(String) }
  def render_resource_close_plan(plan, root_name)
    plan.actions.map { |action| render_resource_close_action(action, root_name) }.join("; ")
  end

  sig { params(action: Schemas::ResourceCloseAction, root_name: String).returns(String) }
  def render_resource_close_action(action, root_name)
    target = ([root_name] + action.field_path).join(".")
    runtime_args = Array.new(action.runtime_heap_alloc_args) { "#{@rt_name}.heapAlloc()" }
    case action.call_kind
    when Schemas::ResourceCloseCallKind::Method
      "#{target}.#{action.name}(#{runtime_args.join(", ")})"
    when Schemas::ResourceCloseCallKind::Function
      args = [target] + runtime_args
      "#{action.name}(#{args.join(", ")})"
    else
      raise "unknown resource close call kind: #{action.call_kind.inspect}"
    end
  end

  sig { params(name: String, body: String, guarded: T::Boolean).returns(String) }
  def direct_cleanup_statement(name, body, guarded)
    stripped = body.strip
    statement = stripped.end_with?(";", "}") ? stripped : "#{stripped};"
    guarded ? "if (!#{name}_moved) #{statement}" : statement
  end

  sig { params(name: String, zig_type: String, alloc: String, guarded: T::Boolean, via_pointer: T.nilable(T::Boolean)).returns(String) }
  def direct_uniform_cleanup(name, zig_type, alloc, guarded, via_pointer: false)
    arg = via_pointer ? name : "&#{name}"
    storage_type = ZigType.new(zig_type).cleanup_storage_type
    direct_cleanup_statement(name, "CheatLib.cleanup(#{storage_type}, #{alloc}, #{arg})", guarded)
  end

  private :emit_bg_block,
    :emit_bg_stackful_plan,
    :emit_bg_stream_plan,
    :emit_capture_cleanup_actions,
    :emit_do_block_plan,
    :emit_do_branch_plan,
    :emit_sharded_map_get,
    :emit_sharded_map_put
  private :bg_stackful_runtime_suppress_line
  private :emit_context_field_decls
  private :emit_do_block
  private :emit_fiber_spawn_call
  private :emit_fsm_bg_body
  private :emit_inline_bc_as_zig
  private :emit_struct_init_fields
  private :emit_task_config_plan
  private :fsm_bg_body_plan?

end
