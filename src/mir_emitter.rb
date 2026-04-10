# src/mir_emitter.rb - Zig code emitter from MIR nodes
#
# This class takes an MIR tree (produced by the lowering pass) and emits
# Zig source code. It makes ZERO memory decisions -- every allocator,
# cleanup kind, and copy strategy is pre-computed in the MIR nodes.
#
# The emitter is deliberately simple: a case dispatch over node types,
# each case filling a Zig template. If a case requires type introspection
# or schema lookup, the MIR is wrong -- fix the lowering, not the emitter.
#
# IMPORTANT: This file must NOT require type.rb, annotator.rb, scope.rb,
# or any analysis module. It depends only on mir.rb.

require_relative "mir"

class MIREmitter
  def initialize
    @indent = 0
  end

  # Emit Zig code from an MIR node. Returns a String.
  # Accepts MIR nodes or raw Strings (pre-computed Zig fragments).
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
    when MIR::WhileStmt        then emit_while(node)
    when MIR::ForStmt          then emit_for(node)
    when MIR::SwitchStmt       then emit_switch(node)
    when MIR::IfChain          then emit_if_chain(node)
    when MIR::ReturnStmt       then emit_return(node)
    when MIR::BreakStmt        then emit_break(node)
    when MIR::ContinueStmt     then "continue;"
    when MIR::DeferStmt        then emit_defer(node)
    when MIR::ErrDeferStmt     then emit_errdefer(node)
    when MIR::ExprStmt         then emit_expr_stmt(node)
    when MIR::ScopeBlock        then emit_scope_block(node)
    when MIR::RawZig           then node.code
    when MIR::BgBlock          then node.code
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
    when MIR::Cleanup          then emit_cleanup(node)
    when MIR::MoveMark         then emit_move_mark(node)
    when MIR::EscapePromote    then emit_escape_promote(node)
    when MIR::DeepCopy         then emit_deep_copy(node)
    when MIR::ContainerInit    then emit_container_init(node)
    when MIR::CapWrap          then emit_cap_wrap(node)
    when MIR::RcRetain         then emit_rc_retain(node)
    when MIR::RcDowngrade      then emit_rc_downgrade(node)
    when MIR::WeakUpgrade      then emit_weak_upgrade(node)
    when MIR::MakeList         then emit_make_list(node)
    when MIR::FrameSave        then emit_frame_save(node)
    when MIR::FrameRestore     then emit_frame_restore(node)
    when MIR::PreserveAndRewind then emit_preserve_rewind(node)

    # --- Verification-only (no codegen) ---
    when MIR::AllocMark, MIR::ReturnMark, MIR::ReassignMark, MIR::FieldCleanupMark
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
    when MIR::AddressOf        then "&#{emit(node.expr)}"
    when MIR::Deref            then "#{emit(node.expr)}.*"
    when MIR::OptionalUnwrap   then "#{emit(node.expr)}.?"
    when MIR::RangeLit         then emit_range_lit(node)
    when MIR::HasField         then emit_has_field(node)
    when MIR::ItemsAccess      then emit_items_access(node)
    when MIR::LambdaExpr       then emit_lambda(node)
    when MIR::InlineZig        then node.code

    else
      raise "MIREmitter: unknown node type #{node.class}"
    end
  end

  private

  # --- Top-level emitters ---

  def emit_program(node)
    node.items.filter_map { |item| emit(item) }.join("\n\n")
  end

  def emit_fn_def(node)
    vis = node.visibility == :pub ? "pub " : ""
    comptime = (node.comptime_params || []).join(", ")
    params = node.params.map { |p| "#{p.name}: #{p.zig_type}" }.join(", ")
    all_params = [comptime, params].reject(&:empty?).join(", ")

    ret = node.can_fail ? "!#{node.ret_type}" : node.ret_type
    body = emit_body(node.body)

    "#{vis}fn #{node.name}(#{all_params}) #{ret} {\n#{body}\n}"
  end

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

  def emit_enum_def(node)
    vis = node.visibility == :pub ? "pub " : ""
    variants = node.variants.join(", ")
    "#{vis}const #{node.name} = enum { #{variants} };"
  end

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

  def emit_import(node)
    base = "@import(\"#{node.module_path}\")"
    base = "#{base}.#{node.member}" if node.member
    "const #{node.alias_name} = #{base};"
  end

  def emit_type_alias(node)
    "const #{node.name} = #{node.target};"
  end

  def emit_test_def(node)
    body = emit_body(node.body)
    "test \"#{node.name}\" {\n#{body}\n}"
  end

  # --- Statement emitters ---

  def emit_let(node)
    kw = node.mutable ? "var" : "const"
    ann = node.annotation ? ": #{node.annotation}" : ""
    init = emit(node.init)
    sup = node.suppression ? " #{node.suppression}" : ""
    "#{kw} #{node.name}#{ann} = #{init};#{sup}"
  end

  def emit_set(node)
    "#{emit(node.target)} = #{emit(node.value)};"
  end

  def emit_reassign_cleanup(node)
    tmp = "__new_#{node.name}"
    val = emit(node.value)
    "{\nconst #{tmp} = #{val};\nCheatLib.cleanup(#{node.zig_type}, #{node.alloc_expr}, &#{node.name});\n#{node.name} = #{tmp};\n}"
  end

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

  def emit_while(node)
    cond = emit(node.cond)
    cap = node.capture ? " |#{node.capture}|" : ""
    upd = if node.update
      # Strip trailing semicolon for update expression in while header
      update_code = emit(node.update).chomp(";")
      " : (#{update_code})"
    else
      ""
    end
    body = emit_body(node.body)
    "while (#{cond})#{upd}#{cap} {\n#{body}\n}"
  end

  def emit_for(node)
    iter = emit(node.iter)
    captures = [node.capture, node.index_capture].compact.join(", ")
    body = emit_body(node.body)
    "for (#{iter}) |#{captures}| {\n#{body}\n}"
  end

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

  def emit_return(node)
    node.value ? "return #{emit(node.value)};" : "return;"
  end

  def emit_break(node)
    parts = ["break"]
    parts << ":#{node.label}" if node.label
    parts << emit(node.value) if node.value
    "#{parts.join(' ')};"
  end

  def emit_scope_block(node)
    body = emit_body(node.body)
    "{\n#{body}\n}"
  end

  def emit_defer(node)
    body = emit(node.body)
    if body.include?("\n") || body.start_with?("{")
      "defer #{body}"
    else
      "defer #{body};"
    end
  end

  def emit_errdefer(node)
    body = emit(node.body)
    if body.include?("\n") || body.start_with?("{")
      "errdefer #{body}"
    else
      "errdefer #{body};"
    end
  end

  def emit_expr_stmt(node)
    code = emit(node.expr)
    node.discard ? "_ = #{code};" : "#{code};"
  end

  # --- Memory operation emitters ---

  def emit_heap_create(node)
    label = node.label || "__hc"
    init = emit(node.init)
    alloc = node.alloc_expr
    "#{label}: {\n" \
    "    const __p = try #{alloc}.create(#{node.zig_type});\n" \
    "    errdefer #{alloc}.destroy(__p);\n" \
    "    __p.* = #{init};\n" \
    "    break :#{label} __p;\n" \
    "}"
  end

  def emit_dupe_slice(node)
    "try #{node.alloc_expr}.dupe(u8, #{emit(node.source)})"
  end

  def emit_alloc_slice(node)
    "try #{node.alloc_expr}.alloc(#{node.elem_type}, #{emit(node.len)})"
  end

  def emit_free_slice(node)
    "#{node.alloc_expr}.free(#{emit(node.slice)})"
  end

  def emit_destroy_ptr(node)
    "#{node.alloc_expr}.destroy(#{emit(node.ptr)})"
  end

  def emit_cleanup(node)
    entry = node.cleanup_entry
    alloc = alloc_from_entry(entry)
    name = node.name
    g = entry[:has_moved_guard]
    zig_type = entry[:zig_type] || "UNKNOWN"
    elem_zig = entry[:elem_zig_type] || "UNKNOWN"

    case entry[:kind]
    when :resource
      close = entry[:resource_close_zig].gsub("{0}", name)
      guarded_defer(name, close, g)

    when :list_with_elem_cleanup
      body = "{ for (#{name}.items) |*__e| { CheatLib.cleanup(#{elem_zig}, rt.cleanupAlloc(), __e); } #{name}.deinit(rt.frameAlloc()); }"
      guarded_defer(name, body, g)

    when :list, :string_map, :numeric_map
      guarded_cleanup(name, zig_type, alloc, g)

    when :pool, :fixed_soa
      "defer #{name}.deinit(#{alloc});\n"

    when :set
      "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"

    when :rc
      rc_alloc = entry[:rc_alloc] ? alloc_from_sym(entry[:rc_alloc]) : alloc
      case entry[:rc_variant]
      when :link
        guarded_defer(name, "CheatLib.#{entry[:rc_release_func]}(#{entry[:base_zig]}, #{name})", g)
      when :optional
        guarded_defer(name, "{ if (#{name}) |_strong_ref| CheatLib.#{entry[:rc_release_func]}(#{entry[:base_zig]}, #{rc_alloc}, _strong_ref); }", g)
      else
        result = guarded_cleanup(name, zig_type, rc_alloc, g)
        if entry[:needs_release_fields]
          guard = g ? "if (!#{name}_moved) " : ""
          result += "defer #{guard}CheatLib.releaseFields(#{entry[:base_zig]}, #{rc_alloc}, #{name}.ctrl.data.*);\n"
        end
        result
      end

    when :locked
      guarded_defer(name, "CheatLib.lockedDestroy(#{zig_type}, #{alloc}, #{name})", g)

    when :write_locked
      guarded_defer(name, "CheatLib.rwLockedDestroy(#{zig_type}, #{alloc}, #{name})", g)

    when :heap_string, :takes_string
      guarded_defer(name, "rt.heapAlloc().free(#{name})", g)

    when :heap_slice, :heap_union, :heap_struct
      guarded_cleanup(name, zig_type, "rt.heapAlloc()", g)

    when :struct_with_cleanup_fields, :struct_rc, :non_copy_union
      guarded_cleanup(name, zig_type, alloc, g)

    when :heap_struct_plain
      guarded_defer(name, "CheatLib.free(rt, #{name})", g)

    when :array_with_struct_strings
      if entry[:is_fixed]
        guarded_defer(name, "{ for (&#{name}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{alloc}, __e); } }", g)
      else
        guarded_defer(name, "{ for (#{name}.items) |*__e| { CheatLib.cleanup(#{elem_zig}, rt.heapAlloc(), __e); } }", g)
      end

    when :takes_union
      guarded_cleanup(name, zig_type, "rt.heapAlloc()", g)

    when :takes_slice, :match_as_slice
      body = "{ if (comptime CheatLib.needsCleanup(#{elem_zig})) { for (#{name}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{alloc}, __e); } } if (#{name}.len > 0) #{alloc}.free(#{name}); }"
      guarded_defer(name, body, g)

    when :match_as_inline_struct
      guarded_cleanup(name, zig_type, alloc, g)

    else
      raise "MIREmitter#emit_cleanup: unhandled kind :#{entry[:kind]} for '#{name}'"
    end
  end

  def emit_move_mark(node)
    "#{node.name}_moved = true;"
  end

  def emit_escape_promote(node)
    rt = node.rt_expr || "rt"
    case node.strategy
    when :list
      elem = node.zig_type[/ArrayListUnmanaged\((.+)\)/, 1]
      "try CheatLib.promoteList(#{elem}, #{rt}, &#{node.name});"
    when :string_map
      "#{node.name}.alloc = #{rt}.heapAlloc();"
    when :generic
      "try CheatLib.promote(#{node.zig_type}, #{rt}, &#{node.name});"
    when :container_store, :ret_fields, :bg_string,
         :catch_string_dupe, :or_fallback_dupe,
         :hpt_string_dupe, :hpt_promote
      # Pending/consumed by downstream handlers. No direct emission.
      nil
    else
      raise "MIREmitter#emit_escape_promote: unhandled strategy :#{node.strategy}"
    end
  end

  def emit_deep_copy(node)
    src = emit(node.source)
    alloc = node.alloc_expr
    case node.strategy
    when :string
      "try #{alloc}.dupe(u8, #{src})"
    when :union
      "try CheatLib.dupeUnionValue(#{node.zig_type}, #{src}, #{alloc})"
    when :list_shallow
      elem = node.elem_type
      "blk_copy: {\n" \
      "    const __src = #{src};\n" \
      "    if (__src.len > 0) {\n" \
      "        const __buf = try #{alloc}.alloc(#{elem}, __src.len);\n" \
      "        @memcpy(__buf, __src);\n" \
      "        break :blk_copy __buf;\n" \
      "    } else break :blk_copy #{src};\n" \
      "}"
    when :list_deep
      elem = node.elem_type
      "blk_copy: {\n" \
      "    const __src = #{src};\n" \
      "    if (__src.len > 0) {\n" \
      "        const __buf = try #{alloc}.alloc(#{elem}, __src.len);\n" \
      "        errdefer #{alloc}.free(__buf);\n" \
      "        for (__buf, 0..) |*__dst, __i| { __dst.* = try CheatLib.dupeUnionValue(#{elem}, __src[__i], #{alloc}); }\n" \
      "        break :blk_copy __buf;\n" \
      "    } else break :blk_copy #{src};\n" \
      "}"
    when :passthrough
      src
    else
      raise "MIREmitter#emit_deep_copy: unhandled strategy :#{node.strategy}"
    end
  end

  def emit_container_init(node)
    case node.strategy
    when :pool, :list_capacity
      "try #{node.zig_type}.initCapacity(#{node.alloc_expr}, #{node.capacity})"
    when :list_empty, :set_empty, :map_empty
      "#{node.zig_type}{}"
    when :map_bare
      "#{node.zig_type}{ .alloc = #{node.alloc_expr} }"
    else
      raise "MIREmitter#emit_container_init: unhandled strategy :#{node.strategy}"
    end
  end

  def emit_cap_wrap(node)
    inner = emit(node.inner)
    alloc = node.alloc_expr
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

  def emit_rc_retain(node)
    "CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"
  end

  def emit_rc_downgrade(node)
    "CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"
  end

  def emit_weak_upgrade(node)
    "CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"
  end

  def emit_make_list(node)
    items = node.items.map { |i| emit(i) }.join(", ")
    items_expr = node.items.empty? ? "&.{}" : "&.{ #{items} }"
    "try CheatLib.makeList(#{node.elem_type}, #{node.alloc_expr}, #{items_expr})"
  end

  def emit_frame_save(node)
    "const frame_mark = #{node.rt_expr}.saveFrameMark();"
  end

  def emit_frame_restore(node)
    "defer #{node.rt_expr}.restoreFrameMark(frame_mark);"
  end

  def emit_preserve_rewind(node)
    "try #{node.rt_expr}.preserveAndRewind(frame_mark, #{emit(node.value)})"
  end

  # --- Expression emitters ---

  def emit_call(node)
    args = node.args.map { |a| emit(a) }.join(", ")
    call = "#{node.callee}(#{args})"
    node.try_wrap ? "try #{call}" : call
  end

  def emit_tail_call(node)
    args = node.args.map { |a| emit(a) }.join(", ")
    "@call(.always_tail, #{node.callee}, .{#{args}})"
  end

  def emit_method_call(node)
    recv = emit(node.receiver)
    args = node.args.map { |a| emit(a) }.join(", ")
    call = "#{recv}.#{node.method}(#{args})"
    node.try_wrap ? "try #{call}" : call
  end

  def emit_field_get(node)
    obj = emit(node.object)
    # Parenthesize try-expressions to prevent Zig precedence issues
    obj = "(#{obj})" if obj.start_with?("try ")
    "#{obj}.#{node.field}"
  end

  def emit_index_get(node)
    "#{emit(node.object)}[#{emit(node.index)}]"
  end

  def emit_bin_op(node)
    "(#{emit(node.left)} #{node.op} #{emit(node.right)})"
  end

  def emit_unary_op(node)
    "#{node.op}#{emit(node.operand)}"
  end

  def emit_struct_init(node)
    fields = node.fields.map { |f| ".#{f[:name]} = #{emit(f[:value])}" }.join(", ")
    if node.zig_type
      "#{node.zig_type}{ #{fields} }"
    else
      ".{ #{fields} }"
    end
  end

  def emit_array_init(node)
    items = node.items.map { |i| emit(i) }.join(", ")
    "[#{node.count}]#{node.elem_type}{ #{items} }"
  end

  def emit_slice_expr(node)
    target = emit(node.target)
    s = emit(node.start)
    e = emit(node.end_expr)
    if node.elem_type
      "@as([]const #{node.elem_type}, #{target}[#{s}..#{e}])"
    else
      "#{target}[#{s}..#{e}]"
    end
  end

  def emit_block_expr(node)
    body = emit_body(node.body)
    "#{node.label}: {\n#{body}\n}"
  end

  def emit_concat(node)
    parts = node.parts.map { |p| emit(p) }.join(", ")
    "try std.mem.concat(#{node.alloc_expr}, u8, &.{ #{parts} })"
  end

  def emit_cast(node)
    inner = emit(node.expr)
    case node.method
    when :as
      "@as(#{node.target_type}, #{inner})"
    when :intCast
      node.target_type ? "@as(#{node.target_type}, @intCast(#{inner}))" : "@intCast(#{inner})"
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
      "@enumFromInt(#{inner})"
    else
      raise "MIREmitter#emit_cast: unknown method :#{node.method}"
    end
  end

  def emit_try_catch(node)
    expr = emit(node.expr)
    catch_body = emit(node.catch_body)
    cap = node.capture ? " |#{node.capture}|" : ""
    "(#{expr} catch#{cap} #{catch_body})"
  end

  def emit_conditional(node)
    "(if (#{emit(node.cond)}) #{emit(node.then_val)} else #{emit(node.else_val)})"
  end

  def emit_range_lit(node)
    "CheatLib.Range{ .start = #{emit(node.start)}, .end = #{emit(node.end_val)} }"
  end

  def emit_has_field(node)
    "@hasField(@TypeOf(#{emit(node.expr)}), \"#{node.field}\")"
  end

  def emit_lambda(node)
    fn = node.fn_def
    fn_zig = emit_fn_def(fn)
    "&(struct { #{fn_zig} }).#{fn.name}"
  end

  def emit_items_access(node)
    inner = emit(node.expr)
    if node.safe
      "(if (@hasField(@TypeOf(#{inner}), \"items\")) #{inner}.items else #{inner})"
    else
      "#{inner}.items"
    end
  end

  # --- Helpers ---

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

  def alloc_from_entry(entry)
    case entry[:alloc]
    when :heap  then "rt.heapAlloc()"
    when :frame then "rt.frameAlloc()"
    else "rt.heapAlloc()"
    end
  end

  def alloc_from_sym(sym)
    case sym
    when :heap  then "rt.heapAlloc()"
    when :frame then "rt.frameAlloc()"
    else "rt.heapAlloc()"
    end
  end

  def guarded_defer(name, body, guarded)
    if guarded
      "var #{name}_moved = false; _ = &#{name}_moved;\ndefer if (!#{name}_moved) #{body};\n"
    elsif body.start_with?("{") && body.end_with?("}")
      "defer #{body}\n"
    else
      "defer #{body};\n"
    end
  end

  def guarded_cleanup(name, zig_type, alloc, guarded)
    if guarded
      guarded_defer(name, "CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name})", true)
    else
      "defer CheatLib.cleanup(#{zig_type}, #{alloc}, &#{name});\n"
    end
  end
end
