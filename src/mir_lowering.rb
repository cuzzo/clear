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

    # --- Memory / capability expressions ---
    when AST::CopyNode          then lower_copy(node)
    when AST::MoveNode          then lower_move(node)
    when AST::CapabilityWrap    then lower_cap_wrap(node)
    when AST::LinkNode          then lower_link(node)
    when AST::ResolveNode       then lower_resolve(node)
    when AST::Copy              then lower(node.value) # Zig copies structs by value

    # --- Slice ---
    when AST::Slice             then lower_slice(node)

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
