# src/mir_lowering.rb - Lowers annotated AST (post-MIRPass) into MIR tree
#
# Pipeline: Parse -> Annotate -> MIRPass -> Lower -> Emit
#
# The lowering reads the annotated AST with old MIR nodes (Drop, Promote,
# SuppressCleanup, etc.) already inserted by MIRPass, and produces a
# complete MIR tree that the MIREmitter can emit to Zig.
#
# This pass subsumes the transpiler's visit_node dispatch. All type
# introspection and allocator resolution happens HERE, not in the emitter.

require_relative "mir"
require_relative "ast"
require_relative "type"
require_relative "zig_type_mapper"

class MIRLowering
  include ZigTypeMapper

  ZIG_PRIMITIVE_RE = /\A[uif]\d+\z/

  def initialize(struct_schemas: {}, enum_schemas: {}, union_schemas: {},
                 fn_sigs: {}, moved_guard_info: {})
    @struct_schemas = struct_schemas || {}
    @enum_schemas = enum_schemas || {}
    @union_schemas = union_schemas || {}
    @fn_sigs = fn_sigs || {}
    @moved_guard_info = moved_guard_info || {}
    @rt_name = "rt"
    @emitted_extern_modules = Set.new
    @block_expr_counter = 0
    @indirect_fields = {}
  end

  # Lower an AST node (or old MIR node) into a new MIR node.
  def lower(node)
    case node

    # --- Old MIR nodes (from MIRPass) -> new MIR nodes ---
    when MIR::Drop              then lower_drop(node)
    when MIR::Promote           then lower_promote(node)
    when MIR::SuppressCleanup   then MIR::MoveMark.new(zig_safe_name(node.name))
    when MIR::Alloc             then MIR::AllocMark.new(node.name, node.kind, node.alloc)
    when MIR::Return            then MIR::ReturnMark.new(node.escaped_vars)
    when MIR::ReassignCleanup   then MIR::ReassignMark.new(node.name, node.alloc)
    when MIR::FieldCleanup      then MIR::FieldCleanupMark.new(node.target_name, node.field, node.alloc)

    # --- Type definitions ---
    when AST::EnumDef           then lower_enum_def(node)
    when AST::UnionDef          then lower_union_def(node)
    when AST::StructDef         then lower_struct_def(node)
    when AST::ExternFnDecl      then lower_extern_fn(node)
    when AST::ExternStructDecl  then lower_extern_struct(node)

    # --- Declarations & assignments ---
    when AST::VarDecl           then lower_var_decl(node)
    when AST::BindExpr          then lower_bind_expr(node)
    when AST::Assignment        then lower_assignment(node)

    # --- Control flow ---
    when AST::IfStatement       then lower_if(node)
    when AST::WhileLoop         then lower_while(node)
    when AST::ForEach           then lower_for_each(node)
    when AST::ForRange          then lower_for_range(node)
    when AST::MatchStatement    then lower_match(node)
    when AST::ReturnNode        then lower_return(node)
    when AST::BreakNode         then MIR::BreakStmt.new(nil, nil)
    when AST::ContinueNode      then MIR::ContinueStmt.new(nil)
    when AST::PassStmt          then MIR::RawZig.new("{}", "pass")

    # --- Functions & calls ---
    when AST::FunctionDef       then lower_function_def(node)
    when AST::FuncCall          then lower_func_call(node)
    when AST::MethodCall        then lower_method_call(node)
    when AST::LambdaLit         then lower_lambda(node)

    # --- Collections ---
    when AST::ListLit           then lower_list_lit(node)
    when AST::HashLit           then lower_hash_lit(node)

    # --- Expressions ---
    when AST::Literal           then lower_literal(node)
    when AST::Identifier        then lower_identifier(node)
    when AST::BinaryOp          then lower_binary_op(node)
    when AST::UnaryOp           then lower_unary_op(node)
    when AST::GetField          then lower_get_field(node)
    when AST::GetIndex          then lower_get_index(node)
    when AST::StructLit         then lower_struct_lit(node)
    when AST::UnionVariantLit   then lower_union_variant_lit(node)
    when AST::StringConcat      then lower_string_concat(node)
    when AST::BlockExpr         then lower_block_expr(node)
    when AST::RangeLit          then lower_range_lit(node)
    when AST::OptionalUnwrap    then MIR::OptionalUnwrap.new(lower(node.target))
    when AST::Assert            then lower_assert(node)
    when AST::Raise             then lower_raise(node)
    when AST::Cast              then lower_cast(node)
    when AST::ThrowNode         then MIR::RawZig.new("return error.CheatError;", "throw")
    when AST::DieNode           then MIR::RawZig.new("std.process.exit(#{node.status || 1});", "die")

    # --- Memory / capability expressions ---
    when AST::CopyNode          then lower_copy(node)
    when AST::MoveNode          then lower_move(node)
    when AST::CapabilityWrap    then lower_cap_wrap(node)
    when AST::LinkNode          then lower_link(node)
    when AST::ResolveNode       then lower_resolve(node)
    when AST::Copy              then lower(node.value) # Zig copies structs by value

    # --- Slice ---
    when AST::Slice             then lower_slice(node)

    # --- Concurrent / capability blocks ---
    when AST::BgBlock          then lower_bg_block(node)
    when AST::BgStreamBlock    then lower_bg_stream_block(node)
    when AST::WithBlock        then lower_with_block(node)
    when AST::DoBlock          then lower_do_block(node)
    when AST::TestBlock        then lower_test_block(node)
    when AST::RequireNode      then lower_require(node)
    when AST::YieldExpr        then lower_yield(node)
    when AST::NextExpr         then lower_next_expr(node)
    when AST::StaticCall       then lower_static_call(node)
    when AST::OrRaise          then MIR::InlineZig.new("error.OrRaise", "or_raise")
    when AST::OrBreak          then MIR::RawZig.new("break;", "or_break")
    when AST::OrPass           then MIR::InlineZig.new("undefined", "or_pass")
    when AST::OrPrune          then MIR::InlineZig.new("undefined", "or_prune")
    when AST::OrExit           then lower_or_exit(node)
    when AST::ThenChain        then raise "Internal: ThenChain should be flattened by BgBlock lowering"
    when AST::AssertRaises     then lower_assert_raises(node)
    when AST::StubDecl         then lower_stub_decl(node)
    when AST::BenchmarkStmt    then lower_benchmark(node)
    when AST::SmashStmt        then lower_smash(node)
    when AST::ProfileStmt      then lower_profile(node)

    else
      raise "MIRLowering: unhandled node type #{node.class} at #{node.respond_to?(:token) && node.token ? "line #{node.token.line}" : 'unknown'}"
    end
  end

  # Lower a body (array of statements) into an array of MIR nodes.
  def lower_body(stmts)
    return [] unless stmts
    stmts.filter_map { |s| lower(s) }
  end

  private

  # ================================================================
  # Name and type helpers
  # ================================================================

  def zig_safe_name(name)
    cleaned = (name.end_with?('!') || name.end_with?('?')) ? name[0..-2] : name
    cleaned = "clearMain" if cleaned == "main"
    cleaned =~ ZIG_PRIMITIVE_RE ? "@\"#{cleaned}\"" : cleaned
  end

  def alloc_for_node(node)
    kind = (node.respond_to?(:storage) && node.storage == :heap) ? :heap : :frame
    alloc_expr(kind, @rt_name)
  end

  def alloc_expr(kind, rt_name = @rt_name)
    kind == :heap ? "#{rt_name}.heapAlloc()" : "#{rt_name}.frameAlloc()"
  end

  def alloc_from_sym(sym)
    case sym
    when :heap  then "#{@rt_name}.heapAlloc()"
    when :frame then "#{@rt_name}.frameAlloc()"
    else "#{@rt_name}.heapAlloc()"
    end
  end

  # ================================================================
  # Old MIR translation
  # ================================================================

  def lower_drop(node)
    MIR::Cleanup.new(zig_safe_name(node.name), node.cleanup_entry)
  end

  def lower_promote(node)
    MIR::EscapePromote.new(
      node.name ? zig_safe_name(node.name) : node.name,
      node.zig_type,
      node.strategy,
      node.fields,
      @rt_name
    )
  end

  # ================================================================
  # Type definitions
  # ================================================================

  def lower_enum_def(node)
    @enum_schemas[node.name.to_sym] = node.variants
    MIR::EnumDef.new(node.name, node.variants.map(&:to_s), nil)
  end

  def lower_struct_def(node)
    @struct_schemas[node.name.to_sym] = node.fields

    if node.type_params&.any?
      # Generic struct: fn Name(comptime T: type) type { return struct { ... }; }
      params = node.type_params.map { |p| "comptime #{p}: type" }.join(", ")
      fields = node.fields.map { |name, fd|
        zig_t = transpile_type(fd[:type], is_field: true)
        "        #{name}: #{zig_t},"
      }.join("\n")
      MIR::RawZig.new(
        "fn #{node.name}(#{params}) type {\n    return struct {\n#{fields}\n    };\n}",
        "generic_struct"
      )
    else
      fields = node.fields.map { |name, fd|
        zig_t = transpile_type(fd[:type], is_field: true)
        MIR::FieldDef.new(name.to_s, zig_t, nil)
      }
      MIR::StructDef.new(node.name, fields, nil, nil)
    end
  end

  def lower_union_def(node)
    @union_schemas[node.name.to_sym] = node.variants

    # Track @indirect fields
    node.variants.each do |var_name, var_data|
      next unless var_data.is_a?(Hash) && var_data[:indirect_fields]
      var_data[:indirect_fields].each do |fname|
        @indirect_fields["#{node.name}_#{var_name}.#{fname}"] = true
      end
    end

    # Emit helper structs for inline struct variants
    helper_structs = node.variants.filter_map do |var_name, var_data|
      next unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
      indirect = var_data[:indirect_fields] || Set.new
      fields = var_data[:fields].map { |fname, ftype|
        zig_t = transpile_type(ftype, is_field: true)
        zig_t = "*#{zig_t}" if indirect.include?(fname)
        MIR::FieldDef.new(fname.to_s, zig_t, nil)
      }

      deinit_lines = (var_data[:deinit_entries] || []).flat_map { |de|
        case de[:kind]
        when :indirect
          ["        CheatLib.cleanup(#{de[:zig_type]}, alloc, self.#{de[:field]});",
           "        alloc.destroy(self.#{de[:field]});"]
        when :array
          ["        if (comptime CheatLib.needsCleanup(#{de[:elem_zig_type]})) { for (self.#{de[:field]}) |*__e| { CheatLib.cleanup(#{de[:elem_zig_type]}, alloc, __e); } }",
           "        if (self.#{de[:field]}.len > 0) alloc.free(self.#{de[:field]});"]
        else []
        end
      }

      methods = if deinit_lines.any?
        body = deinit_lines.join("\n")
        deinit_fn = MIR::RawZig.new(
          "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n#{body}\n    }",
          "union_inline_struct_deinit"
        )
        [deinit_fn]
      end

      MIR::StructDef.new("#{node.name}_#{var_name}", fields, methods, nil)
    end

    # Build variant list
    variants = node.variants.map { |var_name, var_data|
      zig_t = if var_data.nil?
        "void"
      elsif var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
        "#{node.name}_#{var_name}"
      elsif var_data.is_a?(Hash) && var_data[:kind] == :indirect_payload
        "*#{transpile_type(var_data[:type], is_field: true)}"
      else
        transpile_type(var_data, is_field: true)
      end
      { name: var_name.to_s, zig_type: zig_t }
    }

    if node.type_params&.any?
      # Generic union
      params = node.type_params.map { |p| "comptime #{p}: type" }.join(", ")
      variant_lines = variants.map { |v| "    #{v[:name]}: #{v[:zig_type]}," }.join("\n")
      raw = "fn #{node.name}(#{params}) type {\n    return union(enum) {\n#{variant_lines}\n    };\n}"
      if helper_structs.any?
        # Combine helper structs + generic union into a multi-item RawZig
        helper_code = helper_structs.map { |s| emit_struct_def_inline(s) }.join("\n\n")
        MIR::RawZig.new("#{helper_code}\n\n#{raw}", "generic_union_with_helpers")
      else
        MIR::RawZig.new(raw, "generic_union")
      end
    else
      union_node = MIR::UnionTypeDef.new(node.name, variants, nil)
      if helper_structs.any?
        # Return array of nodes: helpers first, then union
        # Wrap in a program-like container... actually we need a way to return multiple nodes
        # For now, emit helper structs as RawZig and combine
        helper_code = helper_structs.map { |s| emit_struct_def_inline(s) }.join("\n\n")
        MIR::RawZig.new("#{helper_code}\n\n#{emit_union_inline(union_node)}", "union_with_helpers")
      else
        union_node
      end
    end
  end

  # Quick inline emit for struct defs used as union helpers.
  def emit_struct_def_inline(sdef)
    fields = sdef.fields.map { |f| "    #{f.name}: #{f.zig_type}," }.join("\n")
    methods = (sdef.methods || []).map { |m|
      m.is_a?(MIR::RawZig) ? "\n    #{m.code}" : ""
    }.join
    "const #{sdef.name} = struct {\n#{fields}#{methods}\n};"
  end

  def emit_union_inline(udef)
    fields = udef.variants.map { |v| "    #{v[:name]}: #{v[:zig_type]}," }.join("\n")
    "const #{udef.name} = union(enum) {\n#{fields}\n};"
  end

  def lower_extern_fn(node)
    mod = node.from_module
    if @emitted_extern_modules.add?(mod)
      mod_parts = mod.split(".")
      import_expr = "@import(\"#{mod_parts.first}\")" + mod_parts[1..].map { |p| ".#{p}" }.join
      mod_alias = mod.gsub(".", "_")
      MIR::Import.new(mod_alias, mod_parts.first, mod_parts.length > 1 ? mod_parts[1..].join(".") : nil)
    else
      MIR::Noop.new("extern_fn_import_already_emitted")
    end
  end

  def lower_extern_struct(node)
    if node.from_module
      mod = node.from_module
      mod_parts = mod.split(".")
      mod_alias = mod.gsub(".", "_")

      items = []
      if @emitted_extern_modules.add?(mod)
        import_expr = "@import(\"#{mod_parts.first}\")" + mod_parts[1..].map { |p| ".#{p}" }.join
        items << MIR::RawZig.new("const #{mod_alias} = #{import_expr};", "extern_struct_import")
      end
      items << MIR::TypeAlias.new(node.name, "#{mod_alias}.#{node.name}")
      items.length == 1 ? items.first : MIR::RawZig.new(items.map { |i| emit_item(i) }.join("\n"), "extern_struct")
    elsif node.fields.empty?
      MIR::Noop.new("empty_local_extern_struct")
    else
      fields = node.fields.map { |name, fd|
        zig_t = transpile_type(fd[:type], is_field: true)
        MIR::FieldDef.new(name.to_s, zig_t, nil)
      }
      MIR::StructDef.new(node.name, fields, nil, nil)
    end
  end

  # Minimal emit for combining multi-node results.
  def emit_item(node)
    case node
    when MIR::RawZig then node.code
    when MIR::TypeAlias then "const #{node.name} = #{node.target};"
    when MIR::Import
      base = "@import(\"#{node.module_path}\")"
      base = "#{base}.#{node.member}" if node.member
      "const #{node.alias_name} = #{base};"
    else node.to_s
    end
  end

  # ================================================================
  # Functions
  # ================================================================

  def lower_function_def(node)
    ret_type = node.return_type || :Void
    if ret_type.is_a?(Type) && ret_type.frame? && ret_type.struct?
      ret_type = Type.new(ret_type.resolved)
    end
    final_type = transpile_type(ret_type)

    fn_needs_rt = node.needs_rt.nil? ? true : node.needs_rt
    fn_can_fail = node.can_fail.nil? ? true : node.can_fail

    # Mutable scalar params: Zig params are const, need shadow vars
    mutable_scalar_params = (node.params || []).select { |p|
      p[:mutable] && !transpile_type(p[:type], is_param: true).start_with?("[]", "*")
    }.map { |p| p[:name] }.to_set

    # Build param list
    params_mir = (node.params || []).map { |param|
      p_name = mutable_scalar_params.include?(param[:name]) ? "_m_#{param[:name]}" : param[:name]
      p_type_sym = param[:type].is_a?(Type) ? param[:type].resolved : param[:type]
      p_type_obj = param[:type].is_a?(Type) ? param[:type] : Type.new(param[:type] || :Any)
      is_user_struct = @struct_schemas&.key?(p_type_sym)
      zig_t = if is_user_struct
        "anytype"
      elsif p_type_obj.collection?
        "anytype"
      else
        transpile_type(param[:type], is_param: true)
      end
      MIR::Param.new(p_name, zig_t)
    }

    # Prepend rt param
    if fn_needs_rt
      params_mir.unshift(MIR::Param.new("rt", "*Runtime"))
    end

    # Comptime params
    comptime_params = (node.type_params || []).map { |tp| "comptime #{tp}: type" }

    # Build return type string
    return_type_str = if fn_can_fail
      if final_type.start_with?("!")
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

    # Frame mark save/restore
    uses_frame_or_alloc = node.uses_frame || node.uses_alloc
    ret_type_obj = node.return_type.is_a?(Type) ? node.return_type : Type.new(node.return_type || :Void)
    returns_value_type = ret_type_obj.void? || ret_type_obj.primitive? || ret_type_obj.resource? ||
                         @enum_schemas&.key?(ret_type_obj.resolved) ||
                         @union_schemas&.key?(ret_type_obj.resolved)
    returns_string = ret_type_obj.string? || (ret_type_obj.error_union? && ret_type_obj.payload_type&.string?)
    has_promotion = node.has_promotion

    if fn_needs_rt
      prologue << MIR::RawZig.new("@setEvalBranchQuota(100000);", "eval_branch_quota")
      if uses_frame_or_alloc && returns_value_type
        prologue << MIR::FrameSave.new(@rt_name)
        prologue << MIR::FrameRestore.new(@rt_name)
      elsif uses_frame_or_alloc && returns_string && !has_promotion
        prologue << MIR::FrameSave.new(@rt_name)
        # No FrameRestore -- preserveAndRewind at return sites
      else
        prologue << MIR::RawZig.new("_ = &rt;", "rt_suppress")
      end
    end

    # NonReentrant guard
    if node.reentrant == :non_reentrant
      prologue.unshift(MIR::RawZig.new(
        "var _guard = try safety.StackGuard.enter(@src());\n    _guard.push();\n    defer _guard.pop();",
        "non_reentrant_guard"
      ))
    end

    # Param suppressions for unused params
    (node.params || []).each do |p|
      next if used_names.include?(p[:name])
      suppress_name = mutable_scalar_params.include?(p[:name]) ? "_m_#{p[:name]}" : p[:name]
      prologue << MIR::RawZig.new("_ = &#{suppress_name};", "param_suppress")
    end

    # Mutable scalar param shadows
    mutable_scalar_params.each do |name|
      next unless used_names.include?(name)
      prologue << MIR::RawZig.new("var #{name} = _m_#{name}; _ = &#{name};", "mutable_param_shadow")
    end

    # Track preserveAndRewind state for return lowering
    @current_fn_preserve_rewind = fn_needs_rt && uses_frame_or_alloc && returns_string && !has_promotion

    # Lower body
    body_mir = lower_body(node.body)

    # Handle catch clauses
    has_catch = node.catch_clauses.is_a?(Array) && node.catch_clauses.any?

    if has_catch
      # Emit inner/outer function pair
      inner_name = "__#{node.name}_body"
      inner_ret = fn_can_fail ? "anyerror!#{final_type}" : "!#{final_type}"

      inner_fn = MIR::FnDef.new(inner_name, params_mir, inner_ret,
                                 prologue + body_mir, :private, true, comptime_params)

      # Outer function: calls inner, catches errors
      call_args = fn_needs_rt ? ["rt"] + (node.params || []).map { |p| p[:name] } : (node.params || []).map { |p| p[:name] }
      inner_call = "#{inner_name}(#{call_args.join(', ')})"

      catch_zig = build_catch_clauses(node, fn_can_fail)
      outer_body = [
        MIR::RawZig.new("return #{inner_call} catch {\n    #{catch_zig}\n};", "catch_wrapper")
      ]

      outer_fn = MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                                  outer_body, vis, fn_can_fail, comptime_params)

      # Return both as RawZig combining them
      inner_zig = emit_expr(inner_fn)
      outer_zig = emit_expr(outer_fn)
      MIR::RawZig.new("#{inner_zig}\n\n#{outer_zig}", "catch_function_pair")
    elsif @current_fn_preserve_rewind
      # Wrap body in a labeled block for preserveAndRewind
      pr_body = prologue + [
        MIR::RawZig.new("const __pr_val = __pr_body: {", "preserve_rewind_start")
      ] + body_mir + [
        MIR::RawZig.new("};", "preserve_rewind_end"),
        MIR::RawZig.new("return try #{@rt_name}.preserveAndRewind(frame_mark, __pr_val);", "preserve_rewind_return")
      ]
      MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                      pr_body, vis, fn_can_fail, comptime_params)
    else
      MIR::FnDef.new(zig_safe_name(node.name), params_mir, return_type_str,
                      prologue + body_mir, vis, fn_can_fail, comptime_params)
    end
  end

  def build_catch_clauses(node, fn_can_fail)
    rt_name = @rt_name
    parts = (node.catch_clauses || []).map { |clause|
      kind = clause[:kind]
      error_name = clause[:error_name]
      clause_body_zig = clause[:body].map { |s| emit_expr(lower(s)) }.join("\n            ")

      cond_parts = ["#{rt_name}.__error.matchesKind(.#{kind})"]
      cond_parts << "#{rt_name}.__error.matchesName(\"#{error_name}\")" if error_name
      cond = cond_parts.join(" and ")

      "if (#{cond}) {\n            const __error = #{rt_name}.__error;\n            _ = &__error;\n            defer #{rt_name}.freeSnapshot();\n            #{clause_body_zig}\n        }"
    }.join(" else ")

    default_code = if node.default_catch.is_a?(Array) && node.default_catch.any?
      default_body = node.default_catch.map { |s| emit_expr(lower(s)) }.join("\n            ")
      " else {\n            const __error = #{rt_name}.__error;\n            _ = &__error;\n            defer #{rt_name}.freeSnapshot();\n            #{default_body}\n        }"
    elsif fn_can_fail
      " else {\n            #{rt_name}.freeSnapshot();\n            return error.CheatError;\n        }"
    else
      " else {\n            #{rt_name}.freeSnapshot();\n            unreachable;\n        }"
    end

    "#{parts}#{default_code}"
  end

  # ================================================================
  # Function / method calls
  # ================================================================

  def lower_func_call(node)
    # Intrinsic pattern: already resolved by annotator
    return lower_intrinsic(node) if node.zig_pattern

    # Extern FFI call
    if node.respond_to?(:extern_call) && node.extern_call
      return lower_extern_call(node)
    end

    # Standard call
    args_mir = node.args.map { |a|
      arg = lower(a)
      # Array/List args: convert to slice via .items
      if a.type_info&.array? && !a.is_a?(AST::CopyNode) && !a.is_a?(AST::MoveNode)
        MIR::ItemsAccess.new(arg, true)
      elsif a.type_info.is_a?(Type) && Type.new(a.type_info).needs_pointer_passing?
        MIR::AddressOf.new(arg)
      else
        arg
      end
    }

    mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""

    if node.respond_to?(:fn_var_call) && node.fn_var_call
      # fn-type variable call
      all_args = [MIR::Ident.new(@rt_name)] + args_mir
      return MIR::Call.new("try #{node.name}", all_args, false)
    end

    # Resolve rt/fail from fn_sigs
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)

    # Generic type args
    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(Type.new(t).zig_type) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(@rt_name)] : []
    all_args = type_args + rt_args + args_mir
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    # Heap dupe result
    if node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
      inner_call = MIR::Call.new(fn_zig, all_args, can_fail)
      return MIR::DupeSlice.new(inner_call, "#{@rt_name}.heapAlloc()")
    end

    MIR::Call.new(fn_zig, all_args, can_fail)
  end

  def lower_method_call(node)
    # Intrinsic pattern: already resolved by annotator
    return lower_intrinsic(node) if node.zig_pattern

    # Extern method dispatch
    if node.instance_variable_get(:@extern_method)
      return lower_extern_method(node)
    end

    # Pool/set/map methods
    return lower_pool_method(node) if node.respond_to?(:pool_method) && node.pool_method
    return lower_set_method(node) if node.respond_to?(:set_method) && node.set_method
    return lower_map_method(node) if node.respond_to?(:map_method) && node.map_method

    # Standard UFCS call: method(object, args...)
    obj_mir = lower(node.object)
    args_mir = node.args.map { |a|
      arg = lower(a)
      if a.type_info&.array? && !a.is_a?(AST::CopyNode) && !a.is_a?(AST::MoveNode)
        MIR::ItemsAccess.new(arg, true)
      elsif a.type_info.is_a?(Type) && Type.new(a.type_info).needs_pointer_passing?
        MIR::AddressOf.new(arg)
      else
        arg
      end
    }

    mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""
    needs_rt = callee_needs_rt?(node.name)
    can_fail = callee_can_fail?(node.name)

    type_args = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
      node.generic_type_args.map { |t| MIR::Ident.new(Type.new(t).zig_type) }
    else
      []
    end

    rt_args = needs_rt ? [MIR::Ident.new(@rt_name)] : []
    all_args = type_args + rt_args + [obj_mir] + args_mir
    fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

    if node.respond_to?(:heap_dupe_result) && node.heap_dupe_result
      inner_call = MIR::Call.new(fn_zig, all_args, can_fail)
      return MIR::DupeSlice.new(inner_call, "#{@rt_name}.heapAlloc()")
    end

    MIR::Call.new(fn_zig, all_args, can_fail)
  end

  def lower_intrinsic(node)
    # Symbol-based intrinsics are complex special builtins
    if node.zig_pattern.is_a?(Symbol)
      return MIR::InlineZig.new("/* intrinsic: #{node.zig_pattern} */", "symbol_intrinsic_#{node.zig_pattern}")
    end

    # Template-based intrinsics: resolve placeholders
    args_zig = if node.is_a?(AST::MethodCall)
      [emit_expr(lower(node.object))] + node.args.map { |a| emit_expr(lower(a)) }
    else
      node.args.map { |a| emit_expr(lower(a)) }
    end

    pattern = node.zig_pattern.dup

    # Resolve {alloc}
    if pattern.include?("{alloc}")
      alloc_sym = node.matched_stdlib_def&.dig(:alloc) || :node_storage
      resolved_alloc = resolve_intrinsic_alloc(alloc_sym, node)
      pattern = pattern.gsub("{alloc}", resolved_alloc)

      # Dupe non-heap strings at TAKES positions
      stdlib_args = node.matched_stdlib_def&.dig(:args)
      if stdlib_args.is_a?(Array)
        raw_args = node.is_a?(AST::MethodCall) ? node.args : node.args[1..]
        raw_args&.each_with_index do |arg_node, ai|
          param_def = stdlib_args[ai + 1]
          next unless param_def.is_a?(Hash) && param_def[:takes]
          zig_idx = node.is_a?(AST::MethodCall) ? ai + 1 : ai
          args_zig[zig_idx] = heap_dupe_takes_string_zig(args_zig[zig_idx], arg_node, resolved_alloc)
        end
      end
    end

    # Substitute positional args
    args_zig.each_with_index { |val, i| pattern = pattern.gsub("{#{i}}", val) }

    MIR::InlineZig.new(pattern, "intrinsic")
  end

  def resolve_intrinsic_alloc(alloc_sym, node)
    case alloc_sym
    when :heap  then "#{@rt_name}.heapAlloc()"
    when :frame then "#{@rt_name}.frameAlloc()"
    when :node_storage
      storage = node.respond_to?(:storage) ? node.storage : nil
      storage == :heap ? "#{@rt_name}.heapAlloc()" : "#{@rt_name}.frameAlloc()"
    when :cleanup
      "#{@rt_name}.cleanupAlloc()"
    else
      "#{@rt_name}.frameAlloc()"
    end
  end

  def heap_dupe_takes_string_zig(arg_zig, arg_node, alloc_zig)
    ti = arg_node.type_info
    return arg_zig unless ti&.string?
    storage = arg_node.respond_to?(:storage) ? arg_node.storage : nil
    return arg_zig if storage == :heap
    "try #{alloc_zig}.dupe(u8, #{arg_zig})"
  end

  def lower_extern_call(node)
    # Extern FFI calls use trampolines -- complex Zig codegen.
    # Bridge via InlineZig for now, tracked for Phase 4 migration.
    args_zig = node.args.map { |a| emit_expr(lower(a)) }
    mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""
    MIR::InlineZig.new("#{mod_prefix}#{node.name}(#{args_zig.join(', ')})", "extern_call")
  end

  def lower_extern_method(node)
    obj_zig = emit_expr(lower(node.object))
    args_zig = node.args.map { |a| emit_expr(lower(a)) }
    MIR::InlineZig.new("#{obj_zig}.#{node.name}(#{args_zig.join(', ')})", "extern_method")
  end

  def lower_pool_method(node)
    obj_zig = emit_expr(lower(node.object))
    args_zig = node.args.map { |a| emit_expr(lower(a)) }
    case node.pool_method
    when :get    then MIR::InlineZig.new("#{obj_zig}.get(#{args_zig[0]})", "pool_get")
    when :remove then MIR::InlineZig.new("#{obj_zig}.remove(#{args_zig[0]})", "pool_remove")
    when :count  then MIR::InlineZig.new("#{obj_zig}.count()", "pool_count")
    when :insert then MIR::InlineZig.new("try #{obj_zig}.insert(#{@rt_name}.heapAlloc(), #{args_zig[0]})", "pool_insert")
    else MIR::InlineZig.new("#{obj_zig}.#{node.pool_method}(#{args_zig.join(', ')})", "pool_method")
    end
  end

  def lower_set_method(node)
    obj_zig = emit_expr(lower(node.object))
    args_zig = node.args.map { |a| emit_expr(lower(a)) }
    MIR::InlineZig.new("#{obj_zig}.#{node.set_method}(#{args_zig.join(', ')})", "set_method")
  end

  def lower_map_method(node)
    obj_zig = emit_expr(lower(node.object))
    args_zig = node.args.map { |a| emit_expr(lower(a)) }
    MIR::InlineZig.new("#{obj_zig}.#{node.map_method}(#{args_zig.join(', ')})", "map_method")
  end

  # ================================================================
  # Lambda
  # ================================================================

  def lower_lambda(node)
    sig = node.full_type
    @lambda_counter = (@lambda_counter || 0) + 1
    fn_name = "_lambda_#{@lambda_counter}"

    params_zig = (sig.respond_to?(:params) ? sig.params : sig[:params] || []).map { |p|
      p_type = p[:type]
      type_str = p_type.is_a?(Type) ? p_type.zig_type(is_param: true) : transpile_type(p_type || :Any, is_param: true)
      "#{p[:name]}: #{type_str}"
    }

    ret = sig.respond_to?(:return_type) ? (sig.return_type || :Void) : (sig[:return]&.fetch(:type, nil) || :Void)
    ret_zig = ret.is_a?(Type) ? ret.zig_type : transpile_type(ret)
    ret_str = ret_zig.start_with?("!") ? ret_zig : "anyerror!#{ret_zig}"

    all_params = ["_rt: *Runtime"] + params_zig
    body_zig = emit_expr(lower(node.body))

    rt_sup = "_ = &_rt;"
    param_sups = (sig[:params] || []).map { |p| "_ = &#{p[:name]};" }.join(" ")
    sups = [rt_sup, param_sups].reject(&:empty?).join(" ")

    MIR::InlineZig.new(
      "&(struct { fn #{fn_name}(#{all_params.join(', ')}) #{ret_str} { #{sups} return #{body_zig}; } }).#{fn_name}",
      "lambda"
    )
  end

  # ================================================================
  # Collections
  # ================================================================

  def lower_list_lit(node)
    items_mir = node.items.map { |i| lower(i) }
    ti = node.type_info || Type.new(node.full_type || :Any)

    if node.storage == :stack && (ti.respond_to?(:fixed?) && ti.fixed? || node.items.length > 0)
      # Stack-allocated fixed array
      elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
      return MIR::ArrayInit.new(elem_zig, node.items.length.to_s, items_mir)
    end

    if node.items.empty?
      # Empty list: MIR expression depends on collection type
      if ti.respond_to?(:list_collection?) && ti.list_collection?
        zig_t = transpile_type(ti)
        alloc = alloc_for_node(node)
        return MIR::ContainerInit.new(zig_t, :list_empty, alloc, nil)
      end
      # Empty slice
      elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
      return MIR::InlineZig.new("&[_]#{elem_zig}{}", "empty_array")
    end

    # Non-empty list literal -> makeList
    elem_zig = ti.element_type ? transpile_type(ti.element_type) : "u8"
    alloc = alloc_for_node(node)
    MIR::MakeList.new(elem_zig, items_mir, alloc)
  end

  def lower_hash_lit(node)
    # HashMaps are always heap-allocated
    ti = node.type_info || Type.new(node.full_type || :Any)
    zig_t = transpile_type(ti)
    alloc = "#{@rt_name}.heapAlloc()"

    if node.pairs.empty?
      return MIR::ContainerInit.new(zig_t, :map_bare, alloc, nil)
    end

    # Non-empty hash: init + puts
    items = []
    items << MIR::RawZig.new("var __hm = #{zig_t}{ .alloc = #{alloc} };", "hashmap_init")
    node.pairs.each do |pair|
      k = emit_expr(lower(pair[:key]))
      v = emit_expr(lower(pair[:value]))
      items << MIR::RawZig.new("try __hm.put(#{k}, #{v});", "hashmap_put")
    end
    items << MIR::RawZig.new("break :__hm_blk __hm;", "hashmap_break")
    MIR::BlockExpr.new("__hm_blk", items)
  end

  def lower_cast(node)
    inner = lower(node.value)
    target_type = transpile_type(node.target)
    MIR::Cast.new(inner, target_type, :as)
  end

  # ================================================================
  # Concurrent / capability blocks
  # ================================================================

  def lower_with_block(node)
    rt_name = @rt_name
    bindings = []

    (node.capabilities || []).each do |cap|
      var_name = cap[:var_node].respond_to?(:name) ? cap[:var_node].name : cap[:var_node].to_s
      alias_name = cap[:alias] || var_name
      resolved = cap[:resolved_type]
      zig_var = var_name

      case cap[:capability]
      when :multiowned, :shared
        inner = "__#{var_name}_unwrap"
        bindings << "const #{inner} = #{zig_var}.ctrl.data.*;\n_ = &#{inner};"
      when :EXCLUSIVE
        guard_var = "__#{var_name}_guard"
        lock_expr = resolved&.any_rc? ? "#{zig_var}.ctrl.data.*" : zig_var
        if resolved&.write_locked?
          bindings << "var #{guard_var} = #{lock_expr}.write();\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
        else
          bindings << "var #{guard_var} = #{lock_expr}.acquire();\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
        end
      when :write_locked_read
        guard_var = "__#{var_name}_guard"
        lock_expr = resolved&.any_rc? ? "#{zig_var}.ctrl.data.*" : zig_var
        bindings << "var #{guard_var} = #{lock_expr}.read();\ndefer #{guard_var}.release();\nconst #{alias_name} = #{guard_var}.get();\n_ = &#{alias_name};"
      when :BORROWED
        source_zig = emit_expr(lower(cap[:var_node]))
        bindings << "const #{zig_safe_name(alias_name)} = #{source_zig};\n_ = &#{zig_safe_name(alias_name)};"
      when :RESTRICT
        if !resolved&.any_sync?
          source_zig = emit_expr(lower(cap[:var_node]))
          if cap[:alias_mutable]
            bindings << "const #{zig_safe_name(alias_name)} = &#{source_zig};"
          else
            bindings << "const #{zig_safe_name(alias_name)} = #{source_zig};\n_ = &#{zig_safe_name(alias_name)};"
          end
        end
      end
    end

    body_zig = lower_body(node.body).filter_map { |s| emit_expr(s) }.join("\n")
    all_bindings = bindings.reject(&:empty?).join("\n")
    MIR::RawZig.new("{\n#{all_bindings}\n#{body_zig}\n}", "with_block")
  end

  def lower_do_block(node)
    @do_block_counter = (@do_block_counter || 0) + 1
    id = @do_block_counter - 1
    n = node.branches.length
    wg_var = "__do#{id}_wg"

    branch_parts = node.branches.each_with_index.map { |branch, i|
      ctx_type = "__DoBranchCtx#{id}_#{i}"
      ctx_var = "__do#{id}_ctx#{i}"
      analysis = branch[:capture_analysis]
      captured = analysis&.captures || {}
      pinned = branch[:pinned]

      capture_fields = captured.map { |name, type_obj|
        zig_t = type_obj ? Type.new(type_obj).zig_type : "anyopaque"
        "#{name}: *const #{zig_t},"
      }.join("\n    ")

      capture_inits = ([".wg = &#{wg_var}"] + captured.map { |name, _| ".#{name} = &#{name}" }).join(", ")

      body_code = branch[:body].map { |e|
        code = emit_expr(lower(e))
        code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
        code
      }.join("\n        ")

      task_cfg = task_config_zig(branch[:stack_size], branch[:computed_stack_tier])
      spawn_fn = pinned ? "try #{wg_var}.sched.submitSpawn" : "try CheatHeader.spawnBest"

      <<~ZIG.chomp
        const #{ctx_type} = struct {
            wg: *CheatHeader.WaitGroup,
            #{capture_fields}
            fn run(__raw_rt_do#{id}_#{i}: *anyopaque, __raw_args_do#{id}_#{i}: ?*anyopaque) anyerror!void {
                const __rt = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_do#{id}_#{i})));
                #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_do#{id}_#{i}.?)));
                defer ctx.wg.done();
                #{body_code}
            }
        };
        var #{ctx_var} = #{ctx_type}{ #{capture_inits} };
        #{spawn_fn}(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
            &#{ctx_var},
            #{task_cfg}
        );
      ZIG
    }

    inner = branch_parts.join("\n")
    MIR::RawZig.new(<<~ZIG.chomp, "do_block")
      {
          var #{wg_var} = CheatHeader.WaitGroup.init(rt.getSched());
          #{wg_var}.add(#{n});
          #{inner}
          #{wg_var}.wait();
      }
    ZIG
  end

  def lower_bg_block(node)
    @bg_block_counter = (@bg_block_counter || 0) + 1
    id = @bg_block_counter - 1

    tense_t = Type.new(node.full_type || :"~Void")
    inner_t = Type.new(tense_t.tense_type)
    inner_zig = inner_t.zig_type
    promise_zig = tense_t.zig_type
    is_void = inner_zig == "void"

    ctx_type = "__BgCtx#{id}"
    alloc_var = "__bg#{id}_alloc"
    promise_var = "__bg#{id}_promise"
    ctx_var = "__bg#{id}_ctx"
    blk_label = "__bg#{id}"
    bg_rt = "__rt_bg#{id}"

    analysis = node.capture_analysis
    captured = analysis&.captures || {}
    capture_close_zig = analysis&.close_patterns || {}
    pointer_captures = analysis&.pointer_captures || Set.new
    resource_captures = analysis&.resource_captures || Set.new

    rt_name = @rt_name

    # Build capture fields
    capture_fields = captured.map { |name, type_obj|
      t = type_obj ? Type.new(type_obj) : nil
      zig_t = t ? t.zig_type : "anyopaque"
      pointer_captures.include?(name) ? "#{name}: *#{zig_t}," : "#{name}: #{zig_t},"
    }.join("\n        ")

    # String promotions from MIR::Promote(:bg_string)
    bg_string_promotes = @pending_bg_string_promotes || Set.new
    @pending_bg_string_promotes = nil
    promoted_names = {}
    bg_string_promotes.each { |name| promoted_names[name] = "__bgp_#{id}_#{name}" }

    capture_inits = ([".inner = #{promise_var}.inner", ".alloc = #{alloc_var}"] +
      captured.map { |name, _|
        if pointer_captures.include?(name)
          ".#{name} = &#{name}"
        elsif promoted_names[name]
          ".#{name} = #{promoted_names[name]}"
        else
          ".#{name} = #{name}"
        end
      }).join(", ")

    # Flatten ThenChain + lower body
    flat_steps = []
    node.body.each { |stmt|
      if stmt.is_a?(AST::ThenChain)
        stmt.steps.each { |s| flat_steps << s }
      else
        flat_steps << { expr: stmt, binding: nil }
      end
    }
    last_step = flat_steps.pop
    pre_steps = flat_steps

    stmt_code = pre_steps.map { |step|
      code = emit_expr(lower(step[:expr]))
      if step[:binding]
        "const #{step[:binding]} = #{code};"
      elsif code.strip.end_with?(";") || code.strip.end_with?("}")
        code
      else
        expr_type = step[:expr].respond_to?(:full_type) ? step[:expr].full_type : :Void
        is_void_step = expr_type.nil? || expr_type == :Void || (expr_type.respond_to?(:to_s) && Type.new(expr_type).zig_type == "void")
        is_void_step ? "#{code};" : "_ = #{code};"
      end
    }.join("\n            ")

    last_is_assign = last_step && last_step[:expr].is_a?(AST::Assignment)
    result_line = if last_step.nil? || is_void || last_is_assign
      if last_step
        last_code = emit_expr(lower(last_step[:expr]))
        (last_code.strip.end_with?("}") || last_code.strip.end_with?(";")) ? last_code : "#{last_code};"
      else
        ""
      end
    else
      result_code = emit_expr(lower(last_step[:expr]))
      result_code = result_code.sub(/\Atry /, '') if result_code.start_with?("try ")
      "__ctx_#{id}.inner.result = #{result_code};"
    end

    arena_init = node.arena_mode ? "#{bg_rt}.arena_mode = true;" : ""

    capture_frees = captured.filter_map { |name, _|
      if bg_string_promotes.include?(name)
        "defer __ctx_#{id}.alloc.free(__ctx_#{id}.#{name});"
      elsif capture_close_zig[name]
        "defer #{capture_close_zig[name].gsub('{0}', "__ctx_#{id}.#{name}")};"
      end
    }.join("\n                    ")

    promoted_decls = promoted_names.map { |name, promoted|
      "const #{promoted} = try #{alloc_var}.dupe(u8, #{name});\n            errdefer #{alloc_var}.free(#{promoted});"
    }.join("\n            ")

    task_cfg = task_config_zig(node.stack_size, node.respond_to?(:computed_stack_tier) ? node.computed_stack_tier : nil)
    spawn_call = bg_spawn_call_zig(node, rt_name, ctx_type, ctx_var, task_cfg)

    MIR::RawZig.new(<<~ZIG.chomp, "bg_block")
      #{blk_label}: {
          const #{ctx_type} = struct {
              inner: *#{promise_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_#{id}: *anyopaque, __raw_args_#{id}: ?*anyopaque) anyerror!void {
                  const #{bg_rt} = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_#{id})));
                  #{(stmt_code + result_line + capture_frees + arena_init).include?(bg_rt) ? "" : "_ = &#{bg_rt};"}
                  #{arena_init}
                  const __ctx_#{id} = @as(*@This(), @ptrCast(@alignCast(__raw_args_#{id}.?)));
                  defer __ctx_#{id}.alloc.destroy(__ctx_#{id});
                  defer __ctx_#{id}.inner.wg.done();
                  errdefer |fiber_err| __ctx_#{id}.inner.result = fiber_err;
                  #{capture_frees}
                  #{stmt_code}
                  #{result_line}
                  #{is_void ? "__ctx_#{id}.inner.result = {};" : ""}
              }
          };
          const #{alloc_var} = #{rt_name}.getSched().allocator;
          const #{promise_var} = try #{promise_zig}.spawn(#{alloc_var}, #{rt_name}.getSched());
          #{promoted_decls}
          const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
          errdefer #{alloc_var}.destroy(#{ctx_var});
          #{ctx_var}.* = .{ #{capture_inits} };
          #{spawn_call}
          break :#{blk_label} #{promise_var};
      }
    ZIG
  end

  def lower_bg_stream_block(node)
    @stream_gen_counter = (@stream_gen_counter || 0) + 1
    id = @stream_gen_counter - 1

    tense_t = Type.new(node.full_type || :"~Void[?]")
    is_inf = tense_t.inf_stream?
    stream_zig = tense_t.zig_type

    ctx_type = "__SgCtx#{id}"
    alloc_var = "__sg#{id}_alloc"
    stream_var = "__sg#{id}_stream"
    ctx_var = "__sg#{id}_ctx"
    blk_label = "__sg#{id}"
    local_stream = "__sg#{id}_local"

    analysis = node.capture_analysis
    captured = analysis&.captures || {}
    rt_name = @rt_name

    bg_string_promotes = @pending_bg_string_promotes || Set.new
    @pending_bg_string_promotes = nil
    promoted_names = {}
    bg_string_promotes.each { |name| promoted_names[name] = "__sgp_#{id}_#{name}" }

    capture_fields = captured.map { |name, type_obj|
      zig_t = type_obj ? Type.new(type_obj).zig_type : "anyopaque"
      "#{name}: #{zig_t},"
    }.join("\n        ")

    capture_inits = ([".stream_inner = #{stream_var}.inner", ".alloc = #{alloc_var}"] +
      captured.map { |name, _|
        promoted_names[name] ? ".#{name} = #{promoted_names[name]}" : ".#{name} = #{name}"
      }).join(", ")

    # Save/restore stream context for YieldExpr
    prev_stream_local = @current_stream_local
    prev_stream_is_inf = @current_stream_is_inf
    @current_stream_local = local_stream
    @current_stream_is_inf = is_inf

    body_code = node.body.map { |expr|
      code = emit_expr(lower(expr))
      code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
      code
    }.join("\n            ")

    @current_stream_local = prev_stream_local
    @current_stream_is_inf = prev_stream_is_inf

    promoted_decls = promoted_names.map { |name, promoted|
      "const #{promoted} = try #{alloc_var}.dupe(u8, #{name});\n            errdefer #{alloc_var}.free(#{promoted});"
    }.join("\n            ")
    string_frees = bg_string_promotes.filter_map { |n| "defer ctx.alloc.free(ctx.#{n});" }.join("\n                    ")

    task_cfg = task_config_zig(node.stack_size, node.respond_to?(:computed_stack_tier) ? node.computed_stack_tier : nil)

    MIR::RawZig.new(<<~ZIG.chomp, "bg_stream_block")
      #{blk_label}: {
          const #{ctx_type} = struct {
              stream_inner: *#{stream_zig}.Inner,
              alloc: std.mem.Allocator,
              #{capture_fields}
              fn run(__raw_rt_sg#{id}: *anyopaque, __raw_args_sg#{id}: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(__raw_rt_sg#{id})));
                  #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                  const ctx = @as(*@This(), @ptrCast(@alignCast(__raw_args_sg#{id}.?)));
                  defer ctx.alloc.destroy(ctx);
                  #{is_inf ? "defer ctx.alloc.destroy(ctx.stream_inner);" : ""}
                  #{string_frees}
                  var #{local_stream} = #{stream_zig}{ .inner = ctx.stream_inner, .alloc = ctx.alloc };
                  defer #{local_stream}.close();
                  errdefer |gen_err| #{local_stream}.inner.err = gen_err;
                  #{body_code}
              }
          };
          const #{alloc_var} = #{rt_name}.getSched().allocator;
          const #{stream_var} = try #{stream_zig}.spawnNew(#{alloc_var}, #{rt_name}.getSched());
          #{promoted_decls}
          const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
          errdefer #{alloc_var}.destroy(#{ctx_var});
          #{ctx_var}.* = .{ #{capture_inits} };
          try #{rt_name}.getSched().submitSpawn(
              @intFromPtr(&Runtime.entryWrapper),
              @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
              #{ctx_var},
              #{task_cfg}
          );
          break :#{blk_label} #{stream_var};
      }
    ZIG
  end

  def lower_yield(node)
    stream_local = @current_stream_local || "__stream_local"
    expr_zig = emit_expr(lower(node.expr))
    MIR::InlineZig.new("try #{stream_local}.push(#{expr_zig})", "yield")
  end

  def lower_next_expr(node)
    inner = emit_expr(lower(node.expr))
    MIR::InlineZig.new("try #{inner}.next()", "next")
  end

  def lower_static_call(node)
    pattern = node.zig_pattern.dup
    arg_strs = node.args.map { |a| emit_expr(lower(a)) }
    arg_strs.each_with_index { |arg, i| pattern = pattern.gsub("{#{i}}", arg) }
    MIR::InlineZig.new(pattern, "static_call")
  end

  def lower_or_exit(node)
    msg = node.message ? emit_expr(lower(node.message)) : '""'
    MIR::RawZig.new("{ #{@rt_name}.setError(.System, \"\", #{msg}, #{node.token.line}); return error.CheatError; }", "or_exit")
  end

  # ================================================================
  # Test framework
  # ================================================================

  def lower_test_block(node)
    test_name = node.name
    setup_zig = lower_body(node.setup).filter_map { |s| emit_expr(s) }.join("\n    ")

    tests = []
    (node.whens || []).each do |when_block|
      when_desc = when_block.description

      stubs = when_block.setup.select { |s| s.is_a?(AST::StubDecl) }
      non_stub_setup = when_block.setup.reject { |s| s.is_a?(AST::StubDecl) }
      when_setup_zig = lower_body(non_stub_setup).filter_map { |s| emit_expr(s) }.join("\n    ")
      stub_decls = stubs.map { |s| emit_expr(lower(s)) }.join("\n    ")

      (when_block.tests || []).each do |test_that|
        full_name = "#{test_name}: #{when_desc}: #{test_that.description}"
        body_zig = lower_body(test_that.body).filter_map { |s| emit_expr(s) }.join("\n    ")

        tests << <<~ZIG
          test "#{full_name}" {
              var __rt_instance = try Runtime.init(.{});
              defer __rt_instance.deinit();
              const rt: *Runtime = &__rt_instance;
              #{stub_decls}
              #{setup_zig}
              #{when_setup_zig}
              #{body_zig}
          }
        ZIG
      end

      (when_block.benchmarks || []).each do |b|
        bench_name = "#{test_name}: #{when_desc}: benchmark"
        bench_zig = emit_expr(lower(b))
        tests << <<~ZIG
          test "#{bench_name}" {
              var __rt_instance = try Runtime.init(.{});
              defer __rt_instance.deinit();
              const rt: *Runtime = &__rt_instance;
              #{stub_decls}
              #{setup_zig}
              #{when_setup_zig}
              #{bench_zig}
          }
        ZIG
      end
    end

    MIR::RawZig.new(tests.join("\n"), "test_block")
  end

  def lower_assert_raises(node)
    rt_name = @rt_name
    kind = node.kind
    expr_zig = emit_expr(lower(node.expression))
    error_check = node.error_name ? " and !#{rt_name}.__error.matchesName(\"#{node.error_name}\")" : ""
    MIR::RawZig.new(<<~ZIG.chomp, "assert_raises")
      {
          if (#{expr_zig}) |_| {
              @panic("ASSERT_RAISES: expected #{kind} error but none raised");
          } else |_| {
              if (!#{rt_name}.__error.matchesKind(.#{kind})#{error_check}) {
                  @panic("ASSERT_RAISES: expected #{kind} error, got different kind");
              }
          }
      }
    ZIG
  end

  def lower_stub_decl(node)
    # StubDecl is handled at test framework level
    MIR::RawZig.new("// stub: #{node.respond_to?(:name) ? node.name : 'unknown'}", "stub_decl")
  end

  def lower_benchmark(node)
    MIR::RawZig.new("// benchmark lowering placeholder", "benchmark")
  end

  def lower_smash(node)
    MIR::RawZig.new("// smash test placeholder", "smash")
  end

  def lower_profile(node)
    MIR::RawZig.new("// profile placeholder", "profile")
  end

  def lower_require(node)
    if node.kind == :package
      MIR::Import.new(node.namespace || node.path, node.namespace || node.path, nil)
    else
      # Local require: needs module compilation (handled by importer at higher level)
      MIR::RawZig.new("// REQUIRE \"#{node.path}\" — needs importer integration", "require_local")
    end
  end

  # ================================================================
  # Helpers for concurrent blocks
  # ================================================================

  def task_config_zig(stack_size, computed_tier)
    tier = computed_tier || :standard
    case tier
    when :micro  then ".{ .stack_size = 16384 }"
    when :large  then ".{ .stack_size = 262144 }"
    when :xl     then ".{ .stack_size = 1048576 }"
    else
      stack_size ? ".{ .stack_size = #{stack_size} }" : ".{}"
    end
  end

  def bg_spawn_call_zig(node, rt_name, ctx_type, ctx_var, task_cfg)
    pinned = node.respond_to?(:pinned) && node.pinned
    if pinned
      "try #{rt_name}.getSched().submitSpawn(\n" \
      "    @intFromPtr(&Runtime.entryWrapper),\n" \
      "    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),\n" \
      "    #{ctx_var},\n" \
      "    #{task_cfg}\n" \
      ");"
    else
      "try CheatHeader.spawnBest(\n" \
      "    @intFromPtr(&Runtime.entryWrapper),\n" \
      "    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),\n" \
      "    #{ctx_var},\n" \
      "    #{task_cfg}\n" \
      ");"
    end
  end

  # ================================================================
  # Expressions
  # ================================================================

  def lower_literal(node)
    case node.type
    when :STRING
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

  def lower_identifier(node)
    return MIR::FnRef.new(zig_safe_name(node.name)) if node.respond_to?(:fn_ref) && node.fn_ref
    MIR::Ident.new(zig_safe_name(node.name))
  end

  def lower_unary_op(node)
    right = lower(node.right)
    case node.op
    when :NOT, "!" then MIR::UnaryOp.new("!", right)
    when :SUB, "-" then MIR::UnaryOp.new("-", right)
    when :BITWISE_NOT, "~" then MIR::UnaryOp.new("~", right)
    else raise "MIRLowering: unknown unary op #{node.op}"
    end
  end

  def lower_binary_op(node)
    # String concat (2-part) uses std.mem.concat
    if node.string_concat
      left = lower(node.left)
      right = lower(node.right)
      alloc = alloc_for_node(node)
      return MIR::InlineZig.new(
        "try std.mem.concat(#{alloc}, u8, &.{ #{emit_expr(left)}, #{emit_expr(right)} })",
        "string_concat_2part"
      )
    end

    left = lower(node.left)
    right = lower(node.right)

    # Power operator
    if node.op == :POW
      left_type = node.left.full_type
      resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
      fn = resolved == :Int64 ? "std.math.pow(i64, " : "std.math.pow(f64, "
      return MIR::InlineZig.new("#{fn}#{emit_expr(left)}, #{emit_expr(right)})", "pow")
    end

    # Modulo on signed int
    if node.op == :MOD
      left_type = node.left.full_type
      resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
      if resolved == :Int64
        return MIR::InlineZig.new("@mod(#{emit_expr(left)}, #{emit_expr(right)})", "signed_mod")
      end
    end

    # String comparison
    if Type.new(node.left.full_type).string? || Type.new(node.right.full_type).string?
      l = emit_expr(left)
      r = emit_expr(right)
      zig = case node.op
            when :EQ  then "CheatLib.eql(#{l}, #{r})"
            when :NEQ then "!CheatLib.eql(#{l}, #{r})"
            when :LT  then "(CheatLib.strcmp(#{l}, #{r}) < 0)"
            when :LTE then "(CheatLib.strcmp(#{l}, #{r}) <= 0)"
            when :GT  then "(CheatLib.strcmp(#{l}, #{r}) > 0)"
            when :GTE then "(CheatLib.strcmp(#{l}, #{r}) >= 0)"
            end
      return MIR::InlineZig.new(zig, "string_cmp") if zig
    end

    # Integer division
    if node.op == :DIV
      left_ti = node.left.type_info
      right_ti = node.right.type_info
      if left_ti&.integer? && right_ti&.integer?
        return MIR::InlineZig.new("@divTrunc(#{emit_expr(left)}, #{emit_expr(right)})", "int_div")
      end
    end

    # Wrapping operators
    if %i[WRAP_ADD WRAP_SUB WRAP_MUL].include?(node.op)
      fn = { WRAP_ADD: "wrapAdd", WRAP_SUB: "wrapSub", WRAP_MUL: "wrapMul" }[node.op]
      return MIR::Call.new("CheatLib.#{fn}", [left, right], false)
    end

    # Checked operators
    if %i[CHECK_ADD CHECK_SUB CHECK_MUL].include?(node.op)
      fn = { CHECK_ADD: "checkAdd", CHECK_SUB: "checkSub", CHECK_MUL: "checkMul" }[node.op]
      return MIR::Call.new("CheatLib.#{fn}", [left, right], false)
    end

    # Default integer arithmetic: checked in debug
    if %i[ADD SUB MUL].include?(node.op)
      left_ti = node.left.type_info
      right_ti = node.right.type_info
      left_is_comptime = node.left.is_a?(AST::Literal) && node.left.type == :NUMBER && !left_ti&.integer?
      right_is_comptime = node.right.is_a?(AST::Literal) && node.right.type == :NUMBER && !right_ti&.integer?
      both_int = left_ti&.integer? && right_ti&.integer?
      no_lits = !left_is_comptime && !right_is_comptime
      no_float_coerce = !node.left.respond_to?(:coerced_type) || node.left.coerced_type.nil? || Type.new(node.left.coerced_type).integer?
      no_float_coerce &&= !node.right.respond_to?(:coerced_type) || node.right.coerced_type.nil? || Type.new(node.right.coerced_type).integer?
      if both_int && no_lits && no_float_coerce
        fn = { ADD: "intAdd", SUB: "intSub", MUL: "intMul" }[node.op]
        return MIR::Call.new("CheatLib.#{fn}", [left, right], false)
      end
    end

    # Standard operators
    op_str = ZigTypeMapper::ZIG_OPS[node.op]
    raise "MIRLowering: unknown binary op #{node.op}" unless op_str
    MIR::BinOp.new(op_str, left, right)
  end

  def lower_get_field(node)
    MIR::FieldGet.new(lower(node.target), node.field.to_s)
  end

  def lower_get_index(node)
    MIR::IndexGet.new(lower(node.target), lower(node.index))
  end

  def lower_struct_lit(node)
    fields = node.fields.map { |k, v|
      val = lower(v)
      # @indirect field: wrap in HeapCreate
      if v.respond_to?(:needs_heap_create) && v.needs_heap_create
        zig_t = v.type_info ? transpile_type(v.type_info.resolved.to_s) : "UNKNOWN"
        val = MIR::HeapCreate.new(zig_t, val, "#{@rt_name}.heapAlloc()", "blk_#{k}")
      end
      { name: k.to_s, value: val }
    }

    type_name = if node.type_args&.any?
      zig_args = node.type_args.map { |a| Type.new(a.to_sym).zig_type }.join(", ")
      "#{node.name}(#{zig_args})"
    else
      node.name.to_s
    end

    init = MIR::StructInit.new(type_name, fields)

    # Heap/frame allocated struct → pointer
    if node.storage == :heap || node.storage == :frame
      alloc = alloc_for_node(node)
      MIR::HeapCreate.new(type_name, init, alloc, "blk")
    else
      init
    end
  end

  def lower_union_variant_lit(node)
    schema = @union_schemas&.dig(node.union_name.to_sym)
    var_data = schema&.dig(node.variant_name)
    indirect = (var_data.is_a?(Hash) && var_data[:indirect_fields]) || Set.new

    variant_struct_name = "#{node.union_name}_#{node.variant_name}"
    field_values = node.fields.map { |k, v|
      val = lower(v)
      if indirect.include?(k)
        zig_t = transpile_type(var_data[:fields][k])
        val = MIR::HeapCreate.new(zig_t, val, "#{@rt_name}.heapAlloc()", "blk_#{k}")
      end
      { name: k.to_s, value: val }
    }

    inner = MIR::StructInit.new(variant_struct_name, field_values)
    MIR::StructInit.new(node.union_name.to_s, [
      { name: node.variant_name.to_s, value: inner }
    ])
  end

  def lower_string_concat(node)
    parts = node.parts.map { |p| lower(p) }
    alloc = alloc_for_node(node)
    MIR::ConcatStr.new(parts, alloc, @rt_name)
  end

  def lower_block_expr(node)
    @block_expr_counter += 1
    label = "__blk_#{@block_expr_counter}"
    body = lower_body(node.body)
    result = lower(node.result)
    body << MIR::BreakStmt.new(label, result)
    MIR::BlockExpr.new(label, body)
  end

  def lower_range_lit(node)
    s = lower(node.start)
    e = lower(node.finish)
    if node.inclusive
      MIR::RangeLit.new(s, MIR::BinOp.new("+", e, MIR::Lit.new("1")))
    else
      MIR::RangeLit.new(s, e)
    end
  end

  def lower_slice(node)
    target = lower(node.target)
    start_expr = lower(node.start)
    end_expr = lower(node.end)
    exclusive = node.instance_variable_get(:@exclusive)

    target_ti = node.target.type_info
    if target_ti&.list_collection? || target_ti&.array?
      target = MIR::ItemsAccess.new(target, true)
    end

    start_cast = MIR::Cast.new(start_expr, "usize", :intCast)
    end_cast = if exclusive
      MIR::Cast.new(end_expr, "usize", :intCast)
    else
      MIR::BinOp.new("+", MIR::Cast.new(end_expr, "usize", :intCast), MIR::Lit.new("1"))
    end

    elem_zig = node.target.type_info&.element_type ? Type.new(node.target.type_info.element_type).zig_type : "u8"
    MIR::SliceExpr.new(target, start_cast, end_cast, elem_zig)
  end

  def lower_assert(node)
    cond = lower(node.condition)
    MIR::InlineZig.new("CheatLib.assert(#{emit_expr(cond)}, \"#{node.message}\")", "assert")
  end

  def lower_raise(node)
    MIR::RawZig.new("return error.CheatError", "raise")
  end

  # ================================================================
  # Memory / capability expressions
  # ================================================================

  def lower_copy(node)
    source = lower(node.value)
    ti = node.value.type_info
    alloc = "#{@rt_name}.heapAlloc()"

    if ti && @union_schemas&.key?(ti.resolved)
      MIR::DeepCopy.new(source, transpile_type(ti), nil, :union, alloc)
    elsif ti&.string?
      MIR::DeepCopy.new(source, nil, nil, :string, alloc)
    elsif ti&.list_collection? || (ti&.array? && !ti&.string?)
      elem_type = ti.element_type
      elem_zig = transpile_type(elem_type)
      needs_deep = node.respond_to?(:deep_copy) && node.deep_copy
      strategy = needs_deep ? :list_deep : :list_shallow
      src = ti&.list_collection? ? MIR::ItemsAccess.new(source, false) : source
      MIR::DeepCopy.new(src, nil, elem_zig, strategy, alloc)
    else
      MIR::DeepCopy.new(source, nil, nil, :passthrough, nil)
    end
  end

  def lower_move(node)
    if node.value.is_a?(AST::Identifier)
      MIR::Ident.new(zig_safe_name(node.value.name))
    else
      lower(node.value)
    end
  end

  def lower_cap_wrap(node)
    inner = lower(node.value)
    base_type = node.value.resolved_type.to_s
    zig_base = transpile_type(base_type)
    alloc = "#{@rt_name}.heapAlloc()"

    sync_fn = case node.sync
              when :locked then "lockedCreate"
              when :write_locked then "rwLockedCreate"
              when :always_mutable then "refCellCreate"
              end
    sync_type = case node.sync
                when :locked then "CheatLib.Locked(#{zig_base})"
                when :write_locked then "CheatLib.RwLocked(#{zig_base})"
                when :always_mutable then "CheatLib.RefCell(#{zig_base})"
                end
    own_fn = case node.ownership
             when :shared then "arcCreate"
             when :multiowned then "rcCreate"
             end

    strategy = if node.sync == :local || (node.layout == :indirect && !node.sync && !node.ownership)
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

  def lower_link(node)
    inner = lower(node.value)
    ti = node.value.type_info
    base = transpile_type(ti.resolved.to_s)
    func = ti.shared? ? "arcDowngrade" : "rcDowngrade"
    MIR::RcDowngrade.new(inner, base, func)
  end

  def lower_resolve(node)
    inner = lower(node.value)
    ti = node.value.type_info
    base = transpile_type(ti.resolved.to_s)
    source = ti.link_source || :multiowned
    func = source == :shared ? "weakArcUpgrade" : "weakRcUpgrade"
    MIR::WeakUpgrade.new(inner, base, func)
  end

  # ================================================================
  # Declarations
  # ================================================================

  def lower_var_decl(node)
    is_mutable = node.respond_to?(:mutable) && node.mutable
    ft = Type.new(node.full_type || :Void)
    is_mutable ||= ft.bounded_stream? || ft.shared_promise? || ft.open_stream? || ft.inf_stream?
    is_mutable ||= ft.collection?
    is_mutable ||= ft.resource? || node.resource_close_zig
    is_mutable = false if ft.local?

    actually_mutated = is_mutable && node.respond_to?(:var_mutated) && node.var_mutated == true
    has_mutable_cleanup = node.has_cleanup || ft&.collection? || ft&.bounded_stream? || ft&.shared_promise? ||
                          ft&.open_stream? || ft&.inf_stream? || (ft&.array? && ft&.dynamic?) ||
                          ft&.heap_provenance? || ft&.resource? || node.resource_close_zig
    forced_var = is_mutable && has_mutable_cleanup
    keyword_mutable = if !is_mutable
      false
    elsif actually_mutated || forced_var
      true
    else
      false
    end

    zig_type = transpile_type(node.full_type)
    needs_annotation = ZigTypeMapper::ZIG_PRIMITIVES.include?(zig_type) || ft.fn_type? ||
                       (node.value.is_a?(AST::Literal) && node.value.type == :NIL)
    annotation = needs_annotation ? zig_type : nil

    # Resolve init value
    init = lower(node.value)

    safe_name = zig_safe_name(node.name)
    has_mir_drop = node.has_cleanup

    suppression = if keyword_mutable
      if actually_mutated && node.var_used && !forced_var
        nil
      else
        "_ = &#{safe_name};"
      end
    else
      (node.var_used || has_mir_drop) ? nil : "_ = #{safe_name};"
    end

    MIR::Let.new(safe_name, init, keyword_mutable, annotation, suppression)
  end

  def lower_bind_expr(node)
    if node.mode == :decl
      # Proxy to VarDecl logic
      proxy = AST::VarDecl.new(node.token, node.name, node.type, node.value, false)
      proxy.full_type = node.full_type
      proxy.storage = node.storage
      proxy.slot_size = node.slot_size
      proxy.resource_close_zig = node.resource_close_zig
      proxy.var_used = node.var_used
      proxy.cleanup_alloc = node.cleanup_alloc
      proxy.has_cleanup = node.has_cleanup
      lower_var_decl(proxy)
    else
      safe = zig_safe_name(node.name)
      value = lower(node.value)
      if node.reassign_cleanup
        zig_type = node.reassign_cleanup[:zig_type] || "UNKNOWN"
        alloc = alloc_from_sym(node.reassign_cleanup[:alloc])
        MIR::ReassignWithCleanup.new(safe, value, zig_type, alloc)
      else
        MIR::Set.new(MIR::Ident.new(safe), value)
      end
    end
  end

  def lower_assignment(node)
    target = if node.name.is_a?(String)
      MIR::Ident.new(zig_safe_name(node.name))
    else
      lower(node.name)
    end
    value = lower(node.value)
    MIR::Set.new(target, value)
  end

  # ================================================================
  # Control flow
  # ================================================================

  def lower_if(node)
    cond = lower(node.condition)
    then_body = lower_body(node.then_branch)
    else_body = (node.else_branch && !node.else_branch.empty?) ? lower_body(node.else_branch) : nil
    MIR::IfStmt.new(cond, then_body, else_body)
  end

  def lower_while(node)
    cond = lower(node.condition)
    b = node.do_branch
    body = b.is_a?(Array) ? lower_body(b) : []
    MIR::WhileStmt.new(cond, body, nil)
  end

  def lower_for_each(node)
    coll = lower(node.collection)
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)
    MIR::ForStmt.new(coll, var, body, nil)
  end

  def lower_for_range(node)
    start_expr = lower(node.start)
    end_expr = lower(node.end)
    var = zig_safe_name(node.var_name)
    body = lower_body(node.body)

    # ForRange maps to: for (@intCast(start)..@intCast(end)) |var|
    range = MIR::InlineZig.new(
      "@as(usize, @intCast(#{emit_expr(start_expr)}))..@as(usize, @intCast(#{emit_expr(end_expr)}))",
      "for_range"
    )
    MIR::ForStmt.new(range, var, body, nil)
  end

  def lower_match(node)
    subject = lower(node.expr)

    # Determine if union MATCH
    union_lookup = begin
      t = Type.new(node.expr.resolved_type || :Any)
      t.generic_instance? ? t.generic_base : t.resolved
    end
    is_union = @union_schemas&.key?(union_lookup)

    # For simple int/enum matches, emit SwitchStmt
    expr_type = node.expr.resolved_type
    expr_type_sym = expr_type.is_a?(Type) ? expr_type.resolved : expr_type

    is_int_match = !is_union && !node.string_match &&
      (expr_type == :Int64 || expr_type == :Int32 || expr_type == :Int16 || expr_type == :Int8 ||
       (expr_type.is_a?(Type) && expr_type.integer?)) &&
      node.cases.all? { |c| c[:kind] != :when && c[:kind] != :struct_pattern &&
                            c[:value].is_a?(AST::Literal) && (c[:value].type == :INT64 || c[:value].type == :NUMBER) }

    is_enum_match = !is_union && !node.string_match && @enum_schemas&.key?(expr_type_sym) &&
      node.cases.all? { |c| c[:kind] != :when && c[:kind] != :struct_pattern &&
                            c[:value].is_a?(AST::GetField) }

    if is_int_match || is_enum_match
      arms = node.cases.map { |c|
        body = lower_body(c[:body])
        pattern = if is_enum_match
          ".#{c[:value].field}"
        else
          emit_expr(lower(c[:value]))
        end
        { pattern: pattern, body: body }
      }
      default = (node.default_case && !node.default_case.empty?) ? lower_body(node.default_case) : nil
      MIR::SwitchStmt.new(subject, arms, default)
    else
      # If-chain for unions, strings, and complex patterns
      branches = node.cases.map { |c|
        body = lower_body(c[:body])
        cond = if is_union
          variant = case c[:value]
                    when AST::GetField then c[:value].field
                    when AST::MethodCall then c[:value].name
                    else emit_expr(lower(c[:value]))
                    end
          MIR::InlineZig.new(
            "std.meta.activeTag(#{emit_expr(subject)}) == .#{variant}",
            "union_match"
          )
        elsif node.string_match
          val = lower(c[:value])
          MIR::InlineZig.new(
            "CheatLib.strEql(#{emit_expr(subject)}, #{emit_expr(val)})",
            "string_match"
          )
        else
          val = lower(c[:value])
          MIR::BinOp.new("==", subject, val)
        end
        { cond: cond, body: body }
      }
      default = (node.default_case && !node.default_case.empty?) ? lower_body(node.default_case) : nil
      MIR::IfChain.new(branches, default)
    end
  end

  def lower_return(node)
    value = node.value ? lower(node.value) : nil
    MIR::ReturnStmt.new(value)
  end

  # ================================================================
  # Helpers
  # ================================================================

  def callee_needs_rt?(name)
    return true if name.nil? || name.to_s.empty?
    sig = @fn_sigs&.dig(name)
    sig ? (sig.needs_rt.nil? ? true : sig.needs_rt) : true
  end

  def callee_can_fail?(name)
    return true if name.nil? || name.to_s.empty?
    sig = @fn_sigs&.dig(name)
    sig ? (sig.can_fail.nil? ? true : sig.can_fail) : true
  end

  def collect_identifier_names(nodes)
    names = Set.new
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array then n.each { |item| traverse.call(item) }
      when Hash then n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef then nil # Don't descend into nested defs
      when AST::Identifier then names.add(n.name)
      else n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(nodes)
    names
  end

  # Quick emit for an MIR expression (used when embedding in InlineZig).
  # This is a temporary bridge -- ideally all expressions stay as MIR nodes.
  def emit_expr(node)
    @_emitter ||= begin
      require_relative "mir_emitter"
      MIREmitter.new
    end
    @_emitter.emit(node)
  end
end
