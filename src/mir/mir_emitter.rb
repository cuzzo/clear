# typed: strict
# src/mir_emitter.rb -- MIR -> Zig template engine.
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

require_relative "mir"
require_relative "cleanup_entry"

class MIREmitter
    extend T::Sig

  attr_accessor :rt_name

  sig { void }
  def initialize
    @indent = T.let(0, Integer)
    @rt_name = T.let("rt", String)
    @flow_alias_zig = T.let(nil, T.nilable(String))
    @if_bind_counter = T.let(nil, T.nilable(Integer))
    @discard_counter = T.let(0, Integer)
  end

  # Emit Zig code from an MIR node. Returns a String.
  # Accepts MIR nodes or raw Strings (pre-computed Zig fragments).
  sig { params(node: T.untyped).returns(T.nilable(String)) }
  def emit(node)
    case node
    when String then node
    when nil    then ""

    # --- Top-level ---
    when MIR::Program     then emit_program(node)
    when MIR::FnDef       then emit_fn_def(node)
    when MIR::StructDef   then emit_struct_def(node)
    when MIR::EnumDef     then emit_enum_def(node)
    when MIR::UnionTypeDef then emit_union_def(node)
    when MIR::Import      then emit_import(node)
    when MIR::TypeAlias   then emit_type_alias(node)
    when MIR::TestDef     then emit_test_def(node)

    # --- Statements ---
    when MIR::Let              then emit_let(node)
    when MIR::Set              then emit_set(node)
    when MIR::ReassignWithCleanup then emit_reassign_cleanup(node)
    when MIR::IfStmt           then emit_if_stmt(node)
    when MIR::IfBindStmt       then emit_if_bind_stmt(node)
    when MIR::WhileStmt        then emit_while(node)
    when MIR::ForStmt          then emit_for(node)
    when MIR::SwitchStmt       then emit_switch(node)
    when MIR::IfChain          then emit_if_chain(node)
    when MIR::ReturnStmt       then emit_return(node)
    when MIR::BreakStmt        then emit_break(node)
    when MIR::ContinueStmt     then "continue;"
    when MIR::Panic            then "@panic(#{node.message.inspect});"
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
    when MIR::RawZig           then node.code
    when MIR::BgBlock          then node.code
    when MIR::DoBlock          then node.code
    when MIR::CatchWrapper     then node.code
    when MIR::Comment          then "// #{node.text}"
    when MIR::Suppress         then "_ = &#{node.name};"
    when MIR::PubConst         then "pub const #{node.name} = #{node.value};"
    when MIR::Noop             then nil

    # --- Memory operations ---
    when MIR::HeapCreate       then emit_heap_create(node)
    when MIR::DupeSlice        then emit_dupe_slice(node)
    when MIR::AllocSlice       then emit_alloc_slice(node)
    when MIR::FreeSlice        then emit_free_slice(node)
    when MIR::DestroyPtr       then emit_destroy_ptr(node)
    when MIR::Cleanup          then emit_cleanup(node, errdefer: false)
    when MIR::ErrCleanup       then emit_cleanup(node, errdefer: true)
    when MIR::MoveMark         then emit_move_mark(node)
    when MIR::DeepCopy         then emit_deep_copy(node)
    when MIR::ContainerInit    then emit_container_init(node)
    when MIR::CapWrap          then emit_cap_wrap(node)
    when MIR::SharePromote     then emit_share_promote(node)
    when MIR::RcRetain         then emit_rc_retain(node)
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
    # --- Verification-only (no codegen) ---
    when MIR::AllocMark, MIR::ReturnMark, MIR::TransferMark, MIR::ReassignMark, MIR::FieldCleanupMark
      nil

    # --- Expressions ---
    when MIR::Call             then emit_call(node)
    when MIR::TailCall         then emit_tail_call(node)
    when MIR::MethodCall       then emit_method_call(node)
    when MIR::FieldGet         then emit_field_get(node)
    when MIR::IndexGet         then emit_index_get(node)
    when MIR::BinOp            then emit_bin_op(node)
    when MIR::UnaryOp          then emit_unary_op(node)
    when MIR::Lit              then node.value
    when MIR::Ident            then node.name
    when MIR::FnRef            then "&#{node.name}"
    when MIR::StructInit       then emit_struct_init(node)
    when MIR::ArrayInit        then emit_array_init(node)
    when MIR::SliceExpr        then emit_slice_expr(node)
    when MIR::BlockExpr        then emit_block_expr(node)
    when MIR::ConcatStr        then emit_concat(node)
    when MIR::Cast             then emit_cast(node)
    when MIR::TryExpr          then "try #{emit(node.expr)}"
    when MIR::TryCatch         then emit_try_catch(node)
    when MIR::Orelse           then "(#{emit(node.expr)} orelse #{emit(node.fallback)})"
    when MIR::Conditional      then emit_conditional(node)
    when MIR::IfOptional       then emit_if_optional(node)
    when MIR::Comptime         then "comptime #{emit(node.expr)}"
    when MIR::UnionVariantGet  then "#{paren_if_try(T.must(emit(node.object)))}.#{node.variant}"
    when MIR::ListItems        then "#{paren_if_try(T.must(emit(node.list)))}.items"
    when MIR::ListLength       then "#{paren_if_try(T.must(emit(node.expr)))}.len"
    when MIR::AddressOf        then "&#{emit(node.expr)}"
    when MIR::Deref            then "#{emit(node.expr)}.*"
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
    when MIR::InlineZig        then emit_inline_zig(node)
    when MIR::InlineBc         then emit_inline_bc_as_zig(node)
    when MIR::RawBc            then emit_raw_bc_as_zig(node)
    when MIR::ShardedMapPut    then emit_sharded_map_put(node)
    when MIR::ShardedMapGet    then emit_sharded_map_get(node)

    else
      raise "MIREmitter: unknown node type #{node.class}"
    end
  end

  # InlineBc nodes are the :bc-target sibling of InlineZig. In the Zig emitter
  # we only see them when a :bc-target lowering pipeline (e.g. bc_run.rb) still
  # routes through a Zig-producing lowering step that calls emit_expr. Fall
  # back to the Zig template from the registry so emission completes.
  sig { params(node: MIR::InlineBc).returns(String) }
  def emit_inline_bc_as_zig(node)
    entry = node.stdlib_def
    raise "emit_inline_bc_as_zig: node has no stdlib_def (:#{node.op})" unless entry && entry.emit&.zig
    pattern = entry.emit.zig.to_s.dup
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
  sig { params(node: T.untyped).returns(T.untyped) }
  def sharded_map_template(node)
    op = node.stdlib_def
    kind = node.template_kind || :zig
    op.emit&.public_send(kind) or raise "ShardedMap: op has no :#{kind} template (emit=#{op.emit.inspect})"
  end

  sig { params(pattern: String, node: T.untyped).returns(String) }
  def sharded_map_substitute_common(pattern, node)
    if node.shard_idx
      pattern = pattern
        .gsub("{shard_idx}", T.must(emit(node.shard_idx)))
        .gsub("{shard_key}", T.must(emit(node.shard_key)))
    end
    pattern = pattern.gsub("{key_zig}", node.key_zig) if node.key_zig
    pattern = pattern.gsub("{val_zig}", node.val_zig) if node.val_zig
    (node.resolved_allocs || {}).each do |alloc_key, sym|
      pattern = pattern.gsub("{#{alloc_key}}", alloc_zig(sym))
    end
    pattern
  end

  # RawBc is the :bc-target sibling of RawZig. Nothing in current lowering
  # emits it (Phase 0 scaffolding only). If a :bc lowering path ever feeds
  # a RawBc into a Zig-producing step, fall back to the :zig field of the
  # registry entry so emission completes. Registry entries that reach Zig
  # without :zig set is a bug in the migration — raise loudly.
  sig { params(node: T.untyped).returns(String) }
  def emit_raw_bc_as_zig(node)
    entry = node.stdlib_def
    raise "emit_raw_bc_as_zig: node has no stdlib_def" unless entry && entry.emit&.zig
    pattern = entry.emit.zig.to_s.dup
    node.args.each_with_index { |a, i| pattern = pattern.gsub("{#{i}}") { emit(a) } }
    pattern
  end

  private

  # Emit InlineZig, resolving allocator placeholders from the allocs field.
  sig { params(node: MIR::InlineZig).returns(String) }
  def emit_inline_zig(node)
    code = node.code
    if node.allocs
      node.allocs.each do |key, sym|
        code = code.gsub("{#{key}}", alloc_zig(sym))
      end
    end
    code
  end

  # --- MVCC SNAPSHOT / WITH MATCH emitters ---
  #
  # These render structured nodes 1:1 to the same Zig text we used to
  # emit via InlineZig blobs in mir_lowering, but the construct is now
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
    parts = [
      "var #{node.guard_var} = #{node.cell_unwrap}.*.read(#{node.rt});",
      "defer #{node.guard_var}.release();",
      "const #{node.alias_zig} = #{node.guard_var}.get();",
      "_ = &#{node.alias_zig};",
    ]
    parts << body unless body.empty?
    parts.join("\n")
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
    <<~ZIG.rstrip
      try CheatLib.polymorphicMutate(#{node.cell_zig}, #{node.rt}, struct {
          fn run(#{node.alias_zig}: *#{node.bare_t_zig}) void {
              _ = &#{node.alias_zig};
              #{body_zig}
          }
      }.run, .{});
    ZIG
  end

  sig { params(node: MIR::PolymorphicMutateFlow).returns(String) }
  def emit_polymorphic_mutate_flow(node)
    old_flow_alias = @flow_alias_zig
    @flow_alias_zig = node.alias_zig
    body_zig = emit_body_flow(node.body || [], :ret_commit)
    guard_zig = ""
    if node.guard_cond
      fail_zig = emit_body_flow(node.guard_fail_body || [], :ret_no_commit)
      unless flow_body_terminates?(node.guard_fail_body || [])
        fail_zig += "\n__flow.* = .{ .kind = .skip_no_commit };\nreturn;"
      end
      guard_zig = <<~ZIG
        if (!(#{emit(node.guard_cond)})) {
            #{indent_block(fail_zig, 12)}
        }
      ZIG
    end
    fallthrough_arm = flow_always_exits?(node) ? "unreachable" : "{}"
    result = <<~ZIG.rstrip
      const __PolyFlow = struct {
          kind: enum { cont_commit, skip_no_commit, ret_commit, ret_no_commit, raise_no_commit },
          ret: #{node.ret_zig} = undefined,
      };
      var __poly_flow = __PolyFlow{ .kind = .cont_commit };
      try CheatLib.polymorphicMutateFlow(#{node.cell_zig}, #{node.rt}, struct {
          fn run(#{node.alias_zig}: *#{node.bare_t_zig}, __flow: *__PolyFlow) void {
              _ = &#{node.alias_zig};
              #{guard_zig}
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
    @flow_alias_zig = old_flow_alias
    result
  end

  sig { params(stmts: T::Array[T.untyped], return_kind: Symbol).returns(String) }
  def emit_body_flow(stmts, return_kind)
    return "" unless stmts
    stmts.filter_map { |s| emit_flow_stmt(s, return_kind) }.join("\n")
  end

  sig { params(stmt: T.untyped, return_kind: Symbol).returns(T.nilable(String)) }
  def emit_flow_stmt(stmt, return_kind)
    case stmt
    when MIR::ReturnStmt
      ret = stmt.value ? emit(stmt.value) : "{}"
      ret = "#{ret}.*" if @flow_alias_zig && ret == @flow_alias_zig
      "__flow.* = .{ .kind = .#{return_kind}, .ret = #{ret} };\nreturn;"
    when MIR::ScopeBlock
      inner = emit_body_flow(stmt.body || [], return_kind)
      "{\n#{indent_block(inner, 4)}\n}"
    when MIR::IfStmt
      then_zig = emit_body_flow(stmt.then_body || [], return_kind)
      else_zig = emit_body_flow(stmt.else_body || [], return_kind)
      if stmt.else_body && !stmt.else_body.empty?
        "if (#{emit(stmt.cond)}) {\n#{indent_block(then_zig, 4)}\n} else {\n#{indent_block(else_zig, 4)}\n}"
      else
        "if (#{emit(stmt.cond)}) {\n#{indent_block(then_zig, 4)}\n}"
      end
    else
      emit(stmt)
    end
  end

  sig { params(stmts: T::Array[T.untyped]).returns(T::Boolean) }
  def flow_body_terminates?(stmts)
    return false unless stmts && !stmts.empty?
    last = stmts.last
    case last
    when MIR::ReturnStmt
      true
    when MIR::RawZig
      last.code.to_s.include?("return;") || last.code.to_s.include?("return ")
    when MIR::ScopeBlock
      flow_body_terminates?(last.body || [])
    when MIR::IfStmt
      flow_body_terminates?(last.then_body || []) &&
        last.else_body && !last.else_body.empty? &&
        flow_body_terminates?(last.else_body || [])
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
    core = <<~ZIG.rstrip
      #{node.cell_unwrap}.*.update(#{node.rt}, #{node.alloc}, struct {
          fn run(#{node.alias_zig}: *#{node.bare_t_zig}) void {
              _ = &#{node.alias_zig};
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
    core = <<~ZIG.rstrip
      CheatLib.versionedUpdateMulti(#{node.cells_tuple}, #{node.rt}, #{node.alloc}, struct {
          fn run(views: anytype) anyerror!void {
              #{node.alias_decls}
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
    arm_strs = node.arms.each_with_index.map { |arm, i|
      head = i.zero? ? "if (comptime #{arm[:probe]})" : "else if (comptime #{arm[:probe]})"
      body_zig = emit_body(arm[:body] || [])
      prelude = arm[:prelude_zig].to_s
      inner = prelude.empty? ? body_zig : "#{prelude}\n#{body_zig}"
      "#{head} {\n    #{inner}\n}"
    }
    chain = arm_strs.join(" ") + " else { unreachable; }"
    "#{chain}\n_ = &#{node.cell_zig};"
  end

  # Helper: wrap a Versioned.update[Multi] / AtomicPtr.update call
  # expression with the conflict handler (and optional RETRY(N)
  # outer-retry shape). Parameterize the Zig error name so the same wrapper works for both families:
  # `UpdateRetriesExhausted` (Versioned bridge to MvccConflict) and
  # `AtomicConflict` (AtomicPtr bridge to AtomicConflict).
  sig { params(core_call: String, conflict_action: String, retries: NilClass, zig_error_name: String).returns(String) }
  def wrap_conflict_handler(core_call, conflict_action, retries, zig_error_name = "UpdateRetriesExhausted")
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
                        #{conflict_action}
                    },
                    else => return __err,
                }
            }
        }
      ZIG
    else
      <<~ZIG.rstrip
        #{core_call} catch |__err| switch (__err) {
            error.#{zig_error_name} => { #{conflict_action} },
            else => return __err,
        };
      ZIG
    end
  end

  # --- Top-level emitters ---

  sig { params(node: MIR::Program).returns(String) }
  def emit_program(node)
    parts = node.items.filter_map { |item| emit(item) }
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
    ann = node.annotation ? ": #{node.annotation}" : ""
    init = emit(node.init)
    sup = node.suppression ? " #{node.suppression}" : ""
    "#{kw} #{node.name}#{ann} = #{init};#{sup}"
  end

  sig { params(node: MIR::Set).returns(String) }
  def emit_set(node)
    "#{emit(node.target)} = #{emit(node.value)};"
  end

  sig { params(node: MIR::ReassignWithCleanup).returns(String) }
  def emit_reassign_cleanup(node)
    tmp = "__new_#{node.name}"
    val = emit(node.value)
    alloc = alloc_zig(node.alloc)
    "{\nconst #{tmp} = #{val};\nCheatLib.cleanup(@TypeOf(#{node.name}), #{alloc}, &#{node.name});\n#{node.name} = #{tmp};\n}"
  end

  sig { params(node: MIR::IfStmt).returns(String) }
  def emit_if_stmt(node)
    cond = emit(node.cond)
    then_body = emit_body(node.then_body)
    result = "if (#{cond}) {\n#{then_body}\n}"
    if node.else_body && !node.else_body.empty?
      else_body = emit_body(node.else_body)
      result += " else {\n#{else_body}\n}"
    end
    result
  end

  sig { params(node: MIR::IfBindStmt).returns(String) }
  def emit_if_bind_stmt(node)
    then_body = emit_body(node.then_body)
    else_body = node.else_body && !node.else_body.empty? ? emit_body(node.else_body) : nil

    if node.bindings.length == 1
      b = node.bindings[0]
      expr = emit(b[:expr])
      result = "if (#{expr}) |#{b[:capture]}| {\n#{then_body}\n}"
      result += " else {\n#{else_body}\n}" if else_body
      result
    else
      # Multi-binding: labeled break block
      @if_bind_counter = (@if_bind_counter || 0) + 1
      label = "__ib_#{@if_bind_counter}"
      ok_var = "__ib_ok_#{@if_bind_counter}"
      inner = node.bindings.map { |b|
        "const #{b[:capture]} = #{emit(b[:expr])} orelse break :#{label};"
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
    "while (#{cond})#{upd}#{cap} {\n#{body}\n}"
  end

  sig { params(node: MIR::ForStmt).returns(String) }
  def emit_for(node)
    iter = emit(node.iter)
    captures = [node.capture, node.index_capture].compact.join(", ")
    body = emit_body(node.body)
    if node.iter.is_a?(MIR::IterRange) && node.iter.capture_type == :i64 && node.index_capture.nil? &&
       node.capture.is_a?(String) && !node.capture.start_with?("*")
      raw_capture = "__#{node.capture}_usize"
      return "for (#{iter}) |#{raw_capture}| {\nconst #{node.capture}: i64 = @intCast(#{raw_capture});\n#{body}\n}"
    end
    "for (#{iter}) |#{captures}| {\n#{body}\n}"
  end

  sig { params(node: MIR::SwitchStmt).returns(String) }
  def emit_switch(node)
    subject = emit(node.subject)
    arms = node.arms.map { |arm|
      body = emit_body(arm[:body])
      "#{arm[:pattern]} => {\n#{body}\n}"
    }
    if node.default_body
      body = node.default_body.empty? ? "" : emit_body(node.default_body)
      arms << "else => {\n#{body}\n}"
    end
    "switch (#{subject}) {\n    #{arms.join(",\n    ")},\n}"
  end

  sig { params(node: MIR::IfChain).returns(String) }
  def emit_if_chain(node)
    parts = node.branches.map { |br|
      cond = emit(br[:cond])
      body = emit_body(br[:body])
      "if (#{cond}) {\n#{body}\n}"
    }
    result = parts.join(" else ")
    if node.default_body && !node.default_body.empty?
      body = emit_body(node.default_body)
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
    param_field_decls = node.param_field_decls.join("\n            ")
    param_init = node.param_init_fields.join(", ")
    base_case_branches = node.base_cases.map { |bc|
      <<~ZIG.chomp
        if (#{bc.fetch(:cond_zig)}) {
                            const result: #{node.ret_zig} = #{bc.fetch(:value_zig)};
        #{emit_thunk_return_or_pop}
                        }
      ZIG
    }.join("\n                    ")
    recurse_arg_inits = node.recurse_arg_inits.join(", ")

    <<~ZIG
      const Frame = struct {
              #{param_field_decls}
              step: u8 = 0,
              child_result: #{node.ret_zig} = undefined,
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
              #{node.yield_line}
              switch (current.step) {
                  0 => {
                      #{base_case_branches}
                      // recursive call -- push child frame
                      const child = rt.heapAlloc().create(Frame) catch unreachable;
                      child.* = .{ #{recurse_arg_inits}, .parent = current };
                      current.step = 1;
                      current = child;
                      continue;
                  },
                  1 => {
                      const result: #{node.ret_zig} = #{node.combine_lhs_zig} #{node.op_zig} current.child_result;
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
                              if (current != &initial) rt.heapAlloc().destroy(current);
                              current = p;
                              continue;
                          }
                          return result;
    ZIG
  end

  sig { params(node: MIR::MutualThunkTrampoline).returns(String) }
  def emit_mutual_thunk_trampoline(node)
    variant_decls = node.variants.map { |variant|
      fields = variant.fetch(:param_field_decls).join("\n          ")
      <<~ZIG.chomp
        #{variant.fetch(:name)}: struct {
                  #{fields}
              },
      ZIG
    }.join("\n      ")
    initial_fields = node.initial_fields.join(", ")
    switch_arms = node.arms.map { |arm| emit_mutual_thunk_arm(arm) }.join("\n              ")

    <<~ZIG
      const Frame = union(enum) {
          #{variant_decls}
      };
      var current: Frame = .{ .#{node.initial_variant} = .{ #{initial_fields} } };
      while (true) {
          #{node.yield_line}
          switch (current) {
              #{switch_arms}
          }
      }
    ZIG
  end

  sig { params(arm: T.untyped).returns(String) }
  def emit_mutual_thunk_arm(arm)
    base_branches = arm.fetch(:base_cases).map { |bc|
      <<~ZIG.chomp
        if (#{bc.fetch(:cond_zig)}) {
                              return #{bc.fetch(:value_zig)};
                          }
      ZIG
    }.join("\n                      ")
    target_arg_inits = arm.fetch(:target_arg_inits).join(", ")

    <<~ZIG.chomp
      .#{arm.fetch(:variant_name)} => |f| {
                      #{base_branches}
                      current = .{ .#{arm.fetch(:target_variant)} = .{ #{target_arg_inits} } };
                      continue;
                  },
    ZIG
  end

  sig { params(node: T.untyped, source: String).returns(String) }
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
    body = emit(node.body)
    if T.must(body).include?("\n") || T.must(body).start_with?("{")
      "defer #{body}"
    else
      "defer #{body};"
    end
  end

  sig { params(node: MIR::ErrDeferStmt).returns(String) }
  def emit_errdefer(node)
    body = emit(node.body)
    if T.must(body).include?("\n") || T.must(body).start_with?("{")
      "errdefer #{body}"
    else
      "errdefer #{body};"
    end
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

  # Accepts either a Symbol (:heap/:frame/:cleanup, resolved via rt) or a MIR
  # expression node (used as the allocator directly, e.g. a parameter name).
  sig { params(alloc: T.untyped).returns(T.nilable(String)) }
  def alloc_expr(alloc)
    alloc.is_a?(Symbol) ? alloc_zig(alloc) : emit(alloc)
  end

  # Emit cleanup for MIR::Cleanup (defer) and MIR::ErrCleanup (errdefer).
  # errdefer: true  -> always emits `errdefer cleanup(name)` (no moved guard).
  # errdefer: false -> emits `defer cleanup(name)` with optional moved guard
  #                    based on entry.has_moved_guard?.
  # The caller (emit dispatch) decides which; this method applies the template.
  sig { params(node: T.untyped, errdefer: T::Boolean).returns(String) }
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
      # Schema-driven close hook: user-provided Zig snippet with `{0}` =
      # the binding name. Future: lift into a deinit method on the type
      # itself (requires wrapping raw-fd sockets as Zig structs).
      close = entry.resource_close_zig.gsub("{0}", name)
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
          alloc_from_sym(entry.rc_alloc)
        else
          alloc
        end
      use_name = entry.kind == :frozen ? "#{name}__buf" : name
      # via_pointer bindings hold *T directly; strip one pointer level
      # so cleanup's T matches the pointee shape.
      use_type = vp ? "@TypeOf(#{use_name}.*)" : "@TypeOf(#{use_name})"
      result = guarded_cleanup(use_name, use_type, use_alloc, g, errdefer:, via_pointer: vp)
      if entry.kind == :rc && entry.needs_release_fields?
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
      type_arg = node.zig_type || "@TypeOf(#{src})"
      if type_arg.start_with?("[]")
        "#{bc}: { const __copy_src = #{src}; break :#{bc} try CheatLib.dupeValue(#{type_arg}, __copy_src, #{alloc}); }"
      else
        pointer_type_arg = node.zig_type || "@TypeOf(__copy_src)"
        pointer_value = node.zig_type && !node.zig_type.start_with?("*") ? "__copy_src.*" : "__copy_src"
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
    when :list_empty, :set_empty, :map_empty
      if node.zig_type.start_with?("std.ArrayListUnmanaged(") ||
         node.zig_type.start_with?("CheatLib.ArrayListUnmanaged(")
        "@as(#{node.zig_type}, .empty)"
      else
        "#{node.zig_type}{}"
      end
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
    "try CheatLib.freeze(#{node.zig_base}, rt.heapAlloc(), #{emit(node.inner)})"
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
    call = "#{node.callee}(#{args})"
    node.try_wrap ? "try #{call}" : call
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

  sig { params(node: MIR::StructInit).returns(String) }
  def emit_struct_init(node)
    fields = node.fields.map { |f| ".#{f[:name]} = #{emit(f[:value])}" }.join(", ")
    if node.zig_type
      "#{node.zig_type}{ #{fields} }"
    else
      ".{ #{fields} }"
    end
  end

  sig { params(node: MIR::ArrayInit).returns(String) }
  def emit_array_init(node)
    items = node.items.map { |i| emit(i) }.join(", ")
    "[#{node.count}]#{node.elem_type}{ #{items} }"
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
    target_t = "anyerror#{target_t}" if target_t&.start_with?("!")
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

    if discard_success_only?(node.expr)
      opt = "#{name}_opt"
      expr = emit(node.expr.expr)
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

  sig { params(expr: T.untyped).returns(T::Boolean) }
  def discard_success_only?(expr)
    expr.is_a?(MIR::TryCatch) &&
      expr.capture.nil? &&
      ((expr.catch_body.is_a?(MIR::Ident) && expr.catch_body.name.to_s == "undefined") ||
       expr.catch_body.is_a?(MIR::Undef))
  end

  sig { params(node: MIR::Conditional).returns(String) }
  def emit_conditional(node)
    "(if (#{emit(node.cond)}) #{emit(node.then_val)} else #{emit(node.else_val)})"
  end

  sig { params(node: MIR::IfOptional).returns(String) }
  def emit_if_optional(node)
    "(if (#{emit(node.optional)}) |#{node.capture}| #{emit(node.then_expr)} else #{emit(node.else_expr)})"
  end

  sig { params(node: MIR::AllocatorRef).returns(String) }
  def emit_allocator_ref(node)
    # Use @rt_name (matches alloc_zig) so callers that swap rt_name
    # — e.g. lower_range_fold_observable's body-emit phase, which
    # rewrites `rt` to the consumer fiber's `__rt_obs_N` — produce
    # consistent allocator strings across both AllocatorRef and
    # alloc_zig-emitted call sites.
    rt = @rt_name || "rt"
    case node.kind
    when :heap    then "#{rt}.heapAlloc()"
    when :frame   then "#{rt}.frameAlloc()"
    else               "#{rt}.heapAlloc()"
    end
  end

  sig { params(node: MIR::TypeSentinel).returns(T.nilable(String)) }
  def emit_type_sentinel(node)
    t = node.zig_type.to_s
    case node.extreme
    when :max
      if t =~ /\Af/         then "std.math.floatMax(#{t})"
      elsif t =~ /\A(u|i)\d+/ then "std.math.maxInt(#{t})"
      else                       "std.math.floatMax(f64)"
      end
    when :min
      if t =~ /\Af/         then "-std.math.floatMax(#{t})"
      elsif t =~ /\A(u|i)\d+/ then "std.math.minInt(#{t})"
      else                       "-std.math.floatMax(f64)"
      end
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

  sig { params(node: T.untyped).returns(String) }
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

  sig { params(stmts: T::Array[T.untyped]).returns(String) }
  def emit_body(stmts)
    return "" unless stmts
    stmts.filter_map { |s|
      code = emit(s)
      next nil unless code
      # Expression nodes used as statements need trailing semicolons.
      # Statement nodes (Let, Set, If, While, etc.) already include them
      # or end with }. Block openers ({) and closers (}) never get ;.
      stripped = code.strip
      if s.expr? && !stripped.end_with?(";") && !stripped.end_with?("}") && !stripped.end_with?("{")
        "#{code};"
      else
        code
      end
    }.join("\n")
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
    rt = @rt_name || "rt"
    case sym
    when :heap    then "#{rt}.heapAlloc()"
    when :frame   then "#{rt}.frameAlloc()"
    else raise "alloc_zig: unknown allocator symbol :#{sym.inspect}"
    end
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
    zig_type = zig_type[1..] if zig_type.start_with?("!")
    if guarded
      guarded_defer(name, "CheatLib.cleanup(#{zig_type}, #{alloc}, #{arg})", true, errdefer:)
    else
      "#{kw} CheatLib.cleanup(#{zig_type}, #{alloc}, #{arg});\n"
    end
  end
end
