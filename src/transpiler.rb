#! /usr/bin/env ruby

require 'bundler/setup' # so `bundle exec` not needed
require "optparse"
require "logger"
require "byebug"

require_relative "./lexer"
require_relative "./parser"
require_relative "./ast"
require_relative "./annotator"
require_relative "./pipeline_generator"
require_relative "./ownership_generator"
require_relative "./zig_type_mapper"
require_relative "./importer"

class ZigTranspiler
  include PipelineGenerator
  include OwnershipGenerator
  include ZigTypeMapper

  attr_reader :struct_schemas

  def initialize(importer: nil, source_dir: nil)
    @importer   = importer
    @source_dir = source_dir ? File.expand_path(source_dir) : Dir.pwd
  end

  # Single-file entry point (used by the CLI and simple callers).
  # pkg_paths: { "name" => "/abs/path/to/lib.cht" } for REQUIRE "pkg:name" resolution.
  def transpile(cheat_code, source_dir: @source_dir, pkg_paths: {})
    @source_dir = File.expand_path(source_dir)
    @importer ||= ModuleImporter.new(base_dir: @source_dir, pkg_paths: pkg_paths)

    tokens    = Lexer.new(cheat_code).tokenize
    ast       = Parser.new(tokens, cheat_code).parse
    annotator = SemanticAnnotator.new(importer: @importer, source_dir: @source_dir)
    annotator.annotate!(ast)

    <<~ZIG
      const std = @import("std");
      const CheatHeader = @import("runtime-header.zig");
      const CheatLib = CheatHeader.CheatLib;
      const Runtime = CheatHeader.Runtime;
      const EbrContext = CheatHeader.EbrContext;

      // -------------------------------------------------------------------------
      // 2. User Types & Functions (Transpiled)
      // -------------------------------------------------------------------------
      #{visit(ast)}

      // -------------------------------------------------------------------------
      // 3. Main Entry (Test Harness)
      // -------------------------------------------------------------------------
      #{File.read("./zig/runtime-footer.zig")}
    ZIG
  end

  # Module entry point: transpile a pre-parsed+annotated AST, emitting only
  # declarations that are importable (non-private). Used by ModuleImporter.
  def transpile_module(ast)
    @emitted_extern_modules = Set.new
    parts = []
    ast.statements.each do |stmt|
      case stmt
      when AST::FunctionDef
        next if stmt.visibility == :private
        parts << visit(stmt)
      when AST::StructDef
        next if stmt.visibility == :private
        parts << visit(stmt)
      when AST::EnumDef
        next if stmt.visibility == :private
        parts << visit(stmt)
      when AST::UnionDef
        next if stmt.visibility == :private
        parts << visit(stmt)
      when AST::RequireNode
        # Re-export nested REQUIRE namespaces into this module's namespace.
        parts << visit(stmt)
      when AST::ExternFnDecl, AST::ExternStructDecl
        # Emit @import for the native module and (for structs) a type alias.
        parts << visit(stmt)
      # Top-level executable statements (VarDecl, BindExpr, etc.) are not
      # exported — module files are declaration-only at the top level.
      end
    end
    parts.compact.join("\n\n")
  end

  # CLI --module entry point: emit a Zig module file (no runtime footer).
  # Uses @import("cheat_runtime") instead of inlining runtime-header.zig.
  # pkg_paths: { "name" => "/abs/path/to/lib.cht" } for REQUIRE "pkg:name".
  def transpile_as_module(cheat_code, source_dir: @source_dir, pkg_paths: {})
    @source_dir = File.expand_path(source_dir)
    @importer ||= ModuleImporter.new(base_dir: @source_dir, pkg_paths: pkg_paths)

    tokens    = Lexer.new(cheat_code).tokenize
    ast       = Parser.new(tokens, cheat_code).parse
    annotator = SemanticAnnotator.new(importer: @importer, source_dir: @source_dir)
    annotator.annotate!(ast)

    body = transpile_module(ast)

    # If the module defines cheatMain, emit a Zig test block so the module
    # can be used directly as the root of `zig test` without a wrapper file.
    has_cheat_main = ast.statements.any? { |s| s.is_a?(AST::FunctionDef) && s.name == "cheatMain" }
    test_block = if has_cheat_main
      <<~ZIG_TEST

        test "cheat main" {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();
            var global_ctx = EbrContext{};
            defer global_ctx.deinit(allocator);
            var rt = try Runtime.init(allocator, 1024 * 1024, &global_ctx);
            defer rt.deinit();
            rt.wireAllocator();
            try cheatMain(&rt);
        }
      ZIG_TEST
    else
      ""
    end

    <<~ZIG
      const std = @import("std");
      const CheatHeader = @import("cheat_runtime");
      const CheatLib = CheatHeader.CheatLib;
      const Runtime = CheatHeader.Runtime;
      const EbrContext = CheatHeader.EbrContext;

      #{body}
      #{test_block}
    ZIG
  end

private

  def visit(node)
    code = visit_node(node)
    if node.respond_to?(:coerced_type) && node.coerced_type && node.coerced_type != node.full_type
      code = transpile_cast(code, node.full_type, node.coerced_type)
    end
    code
  end

  def visit_node(node)
    case node
    when AST::Program
      @emitted_extern_modules = Set.new
      node.statements.map { |stmt| visit(stmt) }.compact.join("\n\n")

    when AST::ExternFnDecl
      # Emit a Zig @import for the native module (once per unique module name).
      @emitted_extern_modules ||= Set.new
      if @emitted_extern_modules.add?(node.from_module)
        "const #{node.from_module} = @import(\"#{node.from_module}\");"
      else
        nil
      end

    when AST::ExternStructDecl
      # Emit @import (once) and a type alias: const TypeName = module.TypeName;
      @emitted_extern_modules ||= Set.new
      parts = []
      parts << "const #{node.from_module} = @import(\"#{node.from_module}\");" if @emitted_extern_modules.add?(node.from_module)
      parts << "const #{node.name} = #{node.from_module}.#{node.name};"
      parts.join("\n")

    when AST::RequireNode
      if node.kind == :package
        # Package imports use Zig's named module system (@import).
        # The build system wires the actual module; we just emit the import.
        "const #{node.namespace} = @import(\"#{node.namespace}\");"
      else
        # Local file imports: inline the compiled module as a Zig const struct namespace.
        # The module body was already transpiled (and cached) by ModuleImporter.
        return "" unless @importer

        mod = @importer.compile_file(node.path, caller_dir: @source_dir)

        # Merge the module's struct schemas so RC cleanup works for imported types.
        if mod.struct_schemas
          @struct_schemas ||= {}
          @struct_schemas.merge!(mod.struct_schemas)
        end

        body = mod.transpiled_body.strip
        # Indent each line of the module body for readability inside the struct.
        indented = body.lines.map { |l| l.rstrip.empty? ? "" : "    #{l.rstrip}" }.join("\n")

        "const #{node.namespace} = struct {\n#{indented}\n};"
      end

    when AST::EnumDef
      # CHEAT: ENUM Direction { North, South }
      # ZIG:   const Direction = enum { North, South };
      variants = node.variants.map { |v| "    #{v}," }.join("\n")
      "const #{node.name} = enum {\n#{variants}\n};"

    when AST::UnionDef
      # CHEAT: UNION Result { Ok: Number, Err: String, Empty }
      # ZIG:   const Result = union(enum) { Ok: f64, Err: []const u8, Empty: void };
      # CHEAT: UNION Option<T> { Some: T, None }
      # ZIG:   fn Option(comptime T: type) type { return union(enum) { Some: T, None: void }; }
      @union_schemas ||= {}
      @union_schemas[node.name.to_sym] = node.variants
      variants = node.variants.map do |var_name, type_obj|
        zig_t = type_obj ? transpile_type(type_obj) : "void"
        "    #{var_name}: #{zig_t},"
      end.join("\n")

      if node.type_params&.any?
        params = node.type_params.map { |p| "comptime #{p}: type" }.join(", ")
        <<~ZIG.strip
          fn #{node.name}(#{params}) type {
              return union(enum) {
          #{variants}
              };
          }
        ZIG
      else
        "const #{node.name} = union(enum) {\n#{variants}\n};"
      end

    when AST::StructDef
      # Cache field schemas so VarDecl can generate field-level Rc cleanup
      @struct_schemas ||= {}
      @struct_schemas[node.name.to_sym] = node.fields

      fields = node.fields.map do |name, field_def|
        zig_type = transpile_type(field_def[:type], is_field: true)
        "        #{name}: #{zig_type},"
      end.join("\n")

      if node.type_params&.any?
        # CLEAR: STRUCT Pair<T> { first: T, second: T }
        # ZIG:   fn Pair(comptime T: type) type { return struct { first: T, second: T }; }
        params = node.type_params.map { |p| "comptime #{p}: type" }.join(", ")
        "fn #{node.name}(#{params}) type {\n    return struct {\n#{fields}\n    };\n}"
      else
        # CLEAR: STRUCT User { id: Number }
        # ZIG:   const User = struct { id: f64, };
        fields_dedented = node.fields.map do |name, field_def|
          zig_type = transpile_type(field_def[:type], is_field: true)
          "    #{name}: #{zig_type},"
        end.join("\n")
        "const #{node.name} = struct {\n#{fields_dedented}\n};"
      end

    when AST::FunctionDef
      # CHEAT: FN test() RETURNS User ->
      # ZIG:   pub fn test(rt: *Runtime) !User {
      final_type = transpile_type(node.return_type || :Void)

      params_zig = node.params.map do |param|
        p_name = param[:name]
        p_type = transpile_type(param[:type], is_param: true)
        "#{p_name}: #{p_type}"
      end

      # For generic functions, prepend comptime type params before rt
      comptime_params = (node.type_params || []).map { |tp| "comptime #{tp}: type" }

      # We inject 'rt' into every function signature
      all_params = comptime_params + ["rt: *Runtime"] + params_zig
      # Don't add ! if the type is already an error union
      return_type_str = final_type.start_with?("!") ? final_type : "!#{final_type}"
      vis = node.visibility == :pub ? "pub " : ""
      signature = "#{vis}fn #{node.name}(#{all_params.join(', ')}) #{return_type_str}"

      prologue = "const frame_mark = rt.saveFrameMark();\ndefer rt.restoreFrameMark(frame_mark);\n"
      prologue = node.uses_frame ? prologue : "_ = &rt;"
      body = transpile_block(node.body)

      <<~ZIG
        #{signature} {
            #{prologue}
            #{body}
        }
      ZIG

    # TODO: Need to call destroy, have objects recursively destroy pointers / resources
    when AST::VarDecl
      is_mutable = node.respond_to?(:mutable) && node.mutable
      keyword = is_mutable ? "var" : "const"
      zig_type = transpile_type(node.full_type)
      annotation = ZIG_PRIMITIVES.include?(zig_type) ? ": #{zig_type}" : ""

      # 1. Resolve MOVE vs RETAIN logic
      @current_rhs_is_move = node.value.is_a?(AST::MoveNode)
      rhs_node = @current_rhs_is_move ? node.value.value : node.value
      rhs_ident = rhs_node if rhs_node.is_a?(AST::Identifier)
      
      # Exception: inside a WITH block the RHS is already the unwrapped plain value, not an Rc/Arc.
      rc_map = @rc_unwrap_map || {}
      rhs_is_unwrapped = rhs_ident && rc_map.key?(rhs_ident.name)
      rhs_ti = rhs_ident&.type_info

      value_code = if rhs_ti&.any_rc? && !rhs_is_unwrapped && !@current_rhs_is_move
        transpile_rc_retain(rhs_ti, rhs_ident.name)
      else
        visit(node.value)
      end

      decl = "#{keyword} #{node.name}#{annotation} = #{value_code};"
      suppression = "_ = &#{node.name};"

      # 2. Cleanup & Move Suppression
      affine_logic = emit_cleanup(node.name, node.type_info, node.storage)
      move_source_logic = emit_move_suppression(rhs_ident)
      @current_rhs_is_move = false

      "#{decl} #{suppression}\n#{affine_logic}\n#{move_source_logic}"


    when AST::BindExpr
      if node.mode == :decl
        # Transpile as immutable declaration — delegate to VarDecl logic via a proxy
        proxy = AST::VarDecl.new(node.token, node.name, node.type, node.value, false)
        proxy.full_type = node.full_type
        proxy.storage   = node.storage
        proxy.slot_size = node.slot_size
        visit(proxy)
      else
        # Transpile as simple assignment
        value_str = visit(node.value)
        move_logic = emit_move_suppression(node.value)
        "#{node.name} = #{value_str}; #{move_logic}"
      end

    when AST::Assignment
      # 1. Resolve the Target string
      #    The target might be a simple String ("i") or a complex Node (GetField/GetIndex)
      target_str =
        if node.name.is_a?(String)
          node.name
        elsif node.name.is_a?(AST::Identifier)
          node.name.name
        elsif node.name.is_a?(AST::GetField)
          target = visit(node.name.target)
          field  = node.name.field
          value  = visit(node.value)
          return "#{target}.#{field} = #{value};"
        elsif node.name.is_a?(AST::GetIndex)
          # Check if target is a Map
          target_node = node.name.target
          if target_node.metatype == :hashmap
             # Generate mapPut

             # TODO: Helper
             inner_type = target_node.full_type.to_s.match(/HashMap<(.+)>/)[1]
             zig_type = transpile_type(inner_type)

             map_ref = visit(target_node)
             key_ref = visit(node.name.index)
             val_ref = visit(node.value)

             # Pass &map_ref because Put modifies the map struct
             return "try CheatLib.mapPut(#{zig_type}, rt.heapAlloc(), &#{map_ref}, #{key_ref}, #{val_ref});"
          end
          arr_ref = visit(target_node)
          idx_ref = visit(node.name.index)
          val_ref = visit(node.value)

          return "CheatLib.setAt(#{arr_ref}, #{idx_ref}, #{val_ref});"
        else
          # Recursive visit for things like 'user.id' or 'list[0]'
          visit(node.name)
        end

      # 2. Resolve the Value
      value_str = visit(node.value)
      move_logic = emit_move_suppression(node.value)

      # 3. Output Zig Code
      "#{target_str} = #{value_str}; #{move_logic}"

    when AST::StructLit
      # CHEAT: User{ id: 1 }
      # ZIG:   User{ .id = 1 }

      # Track heap variables that need to be marked as moved
      move_statements = []
      rc_map = @rc_unwrap_map || {}
      field_inits = node.fields.map do |k, v|
        move_statements << emit_move_suppression(v)

        val_code = if v.is_a?(AST::Identifier) && !rc_map.key?(v.name) && v.type_info&.any_rc?
          transpile_rc_retain(v.type_info, v.name)
        else
          visit(v)
        end
        ".#{k} = #{val_code}"
      end.join(", ")

      struct_name = if node.type_args&.any?
        zig_args = node.type_args.map { |a| Type.new(a.to_sym).zig_type }.join(", ")
        "#{node.name}(#{zig_args})"
      else
        node.name
      end

      struct_init = "#{struct_name}{ #{field_inits} }"
      move_logic = move_statements.reject(&:empty?).join("\n")

      if node.storage == :heap # You set this in the Annotator!
       <<~ZIG
          blk: {
             #{move_logic}
             const ptr = try rt.heapAlloc().create(#{struct_name});
             ptr.* = #{struct_init};
             break :blk ptr;
          }
        ZIG
      else
        if move_logic.empty?
          struct_init
        else
          # Need a block to execute move logic before struct init
          <<~ZIG
            blk: {
               #{move_logic}
               break :blk #{struct_init};
            }
          ZIG
        end
      end


    # TODO: Need overflow logic for frame to overflow to heap / malloc
    when AST::ListLit
      # 1. Determine the Zig Type (T)
      ti = node.coerced_type_info || node.type_info
      element_ti = ti.element_type
      zig_type = element_ti.zig_type

      # 2. Determine Allocator
      allocator = node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

      # 3. Generate Items Slice
      if node.items.empty?
        items_slice = "&.{}"
      else
        items_list = node.items.map do |item|
          item_code = visit(item)
          target_zig = element_ti.zig_type
          
          # 1. If item is a ListLit, it ALWAYS returns an ArrayListUnmanaged.
          # 2. If the target element type expects a slice ([]...), we must convert.
          is_array_list = item.is_a?(AST::ListLit) || (item.type_info&.zig_type&.include?("ArrayListUnmanaged"))
          
          if target_zig&.start_with?("[]") && is_array_list
            "(#{item_code}).items"
          else
            item_code
          end
        end.join(", ")
        items_slice = "&.{ #{items_list} }"
      end

      # 4. Generate the Call
      #    Result: try rt.makeList(i64, rt.frameAlloc(), &.{ 1, 2, 3 })
      "try CheatLib.makeList(#{zig_type}, #{allocator}, #{items_slice})"


    # TODO: Try on frame.
    when AST::HashLit
      # 1. Extract Value Type (V)
      #    "HashMap<Int64>" -> "i64"
      type_str = node.full_type.to_s
      inner_type = type_str.match(/HashMap<(.+)>/)[1]
      zig_type = transpile_type(inner_type)

      # 2. Generate Creation
      #    var map = try CheatLib.makeHashMap(i64);
      creation = "try CheatLib.makeHashMap(#{zig_type})"

      # 3. Generate Initializers (Block Expression)
      #    Zig doesn't have a simple Map Literal syntax, so we stick to creation-only
      #    for the expression, or use a block if we want to populate immediately.
      #    For v0.1, let's just return the empty map creation and let users use 'set'.
      creation

    when AST::GetIndex
      # 1. Resolve Target and Index
      target = visit(node.target)
      index = visit(node.index)

      if node.target.metatype == :hashmap
        inner_type = node.target.full_type.to_s.match(/HashMap<(.+)>/)[1]

        # For INDEX results (HashMap<T[]>), the runtime stores ArrayListUnmanaged(T)
        # We need to pass the actual stored type, not the conceptual slice type
        if inner_type.end_with?("[]")
          element_type = inner_type.gsub(/[\[\]]/, '')
          zig_element = transpile_type(element_type)
          zig_type = "std.ArrayListUnmanaged(#{zig_element})"
        else
          zig_type = transpile_type(inner_type)
        end

        "CheatLib.mapGet(#{zig_type}, #{target}, #{index})"
      else
        "CheatLib.getAt(#{target}, #{index})"
      end

    # TODO: See where drops live
    when AST::IfStatement
      # 1. Transpile Condition
      #    Zig idiomatic: if (cond) { ... }
      cond = visit(node.condition)

      # 2. Transpile THEN Block
      then_body = transpile_block(node.then_branch)

      # 3. Construct Base Statement
      zig_code = "if (#{cond}) {\n    #{then_body}\n    }"

      # 4. Transpile ELSE Block (Optional)
      if node.else_branch && !node.else_branch.empty?
        else_body = transpile_block(node.else_branch)
        zig_code += " else {\n    #{else_body}\n    }"
      end

      zig_code

    when AST::PassStmt
      "{}"

    when AST::MatchStatement
      subject = visit(node.expr)
      union_lookup = begin
        t = Type.new(node.expr.resolved_type || :Any)
        t.generic_instance? ? t.generic_base : t.resolved
      end
      is_union = @union_schemas&.key?(union_lookup)
      parts = node.cases.map do |c|
        body = transpile_block(c[:body])
        if is_union
          # Tagged union: compare active tag rather than value equality
          variant = case c[:value]
                    when AST::GetField   then c[:value].field
                    when AST::MethodCall then c[:value].name
                    else visit(c[:value])
                    end
          cond = "std.meta.activeTag(#{subject}) == .#{variant}"
          # Emit payload binding: `const r = subject.Variant;`
          if c[:binding]
            binding_decl = "const #{c[:binding]} = #{subject}.#{variant};\n    "
            body = "#{binding_decl}#{body}"
          end
        else
          cond = case c[:kind]
                 when :when           then visit(c[:value])
                 when :struct_pattern then transpile_struct_pattern(subject, c[:value])
                 else                      "#{subject} == #{visit(c[:value])}"
                 end
        end
        "if (#{cond}) {\n    #{body}\n    }"
      end

      result = parts.join(" else ")

      if node.default_case && !node.default_case.empty?
        default_body = transpile_block(node.default_case)
        result += " else {\n    #{default_body}\n    }"
      end

      result

    when AST::WhileLoop
      cond = visit(node.condition)
      body = transpile_block(node.do_branch)
      "while (#{cond}) {\n #{body} \n}"

    when AST::WithBlock
      rc_caps          = node.capabilities.select { |c| [:multiowned, :shared].include?(c[:capability]) }
      mutex_caps       = node.capabilities.select { |c| c[:capability] == :EXCLUSIVE && c[:resolved_type]&.locked? }
      rw_write_caps    = node.capabilities.select { |c| c[:capability] == :EXCLUSIVE && c[:resolved_type]&.write_locked? }
      rw_read_caps     = node.capabilities.select { |c| c[:capability] == :write_locked_read }

      # --- Rc/Arc (multiowned/shared) bindings ---
      rc_bindings = rc_caps.map do |cap|
        name = cap[:var_node].name
        inner = "__#{name}_unwrap"
        "const #{inner} = #{name}.data.*;\n_ = &#{inner};"
      end.join("\n")

      # --- Mutex bindings: acquire(), bind alias as *T ---
      mutex_bindings = mutex_caps.map do |cap|
        var_name   = cap[:var_node].name
        alias_name = cap[:alias] || var_name
        guard_var  = "__#{var_name}_guard"
        # Inside a DO branch, the outer variable is accessed via ctx pointer.
        zig_var = @do_capture_map&.dig(var_name) || var_name
        <<~ZIG.chomp
          var #{guard_var} = #{zig_var}.acquire();
          defer #{guard_var}.release();
          const #{alias_name} = #{guard_var}.get();
          _ = &#{alias_name};
        ZIG
      end.join("\n")

      # --- RwLock write bindings: write(), bind alias as *T (exclusive) ---
      rw_write_bindings = rw_write_caps.map do |cap|
        var_name   = cap[:var_node].name
        alias_name = cap[:alias] || var_name
        guard_var  = "__#{var_name}_guard"
        zig_var = @do_capture_map&.dig(var_name) || var_name
        <<~ZIG.chomp
          var #{guard_var} = #{zig_var}.write();
          defer #{guard_var}.release();
          const #{alias_name} = #{guard_var}.get();
          _ = &#{alias_name};
        ZIG
      end.join("\n")

      # --- RwLock read bindings: read(), bind alias as *const T (shared read) ---
      rw_read_bindings = rw_read_caps.map do |cap|
        var_name   = cap[:var_node].name
        alias_name = cap[:alias] || var_name
        guard_var  = "__#{var_name}_guard"
        zig_var = @do_capture_map&.dig(var_name) || var_name
        <<~ZIG.chomp
          var #{guard_var} = #{zig_var}.read();
          defer #{guard_var}.release();
          const #{alias_name} = #{guard_var}.get();
          _ = &#{alias_name};
        ZIG
      end.join("\n")

      # Install Rc unwrap map
      prev_rc_map = @rc_unwrap_map || {}
      @rc_unwrap_map = prev_rc_map.merge(
        rc_caps.map { |c| [c[:var_node].name, "__#{c[:var_node].name}_unwrap"] }.to_h
      )

      # Install locked unwrap map so Identifier resolution uses the alias,
      # and function-call arg transpilation knows to deref (*T → T).
      all_sync_caps = mutex_caps + rw_write_caps + rw_read_caps
      prev_locked_map = @locked_unwrap_map || {}
      @locked_unwrap_map = prev_locked_map.merge(
        all_sync_caps.map { |c| [(c[:alias] || c[:var_node].name), true] }.to_h
      )

      body = transpile_block(node.body)

      @rc_unwrap_map     = prev_rc_map
      @locked_unwrap_map = prev_locked_map

      all_bindings = [rc_bindings, mutex_bindings, rw_write_bindings, rw_read_bindings].reject(&:empty?).join("\n")
      "{\n#{all_bindings}\n#{body}\n}"

    when AST::DoBlock
      @do_block_counter ||= 0
      id = @do_block_counter
      @do_block_counter += 1

      n = node.branches.length
      wg_var = "__do#{id}_wg"

      branch_parts = node.branches.each_with_index.map do |branch_exprs, i|
        ctx_type = "__DoBranchCtx#{id}_#{i}"
        ctx_var  = "__do#{id}_ctx#{i}"

        # Collect all Identifier nodes referenced in this branch for capture
        captured = collect_do_identifiers(branch_exprs)

        capture_fields = captured.map do |name, type_obj|
          # Use the full type (including capabilities like Locked/RwLocked) for correct Zig field type.
          zig_type = type_obj ? Type.new(type_obj).zig_type : "anyopaque"
          "#{name}: *const #{zig_type},"
        end.join("\n    ")

        capture_inits = ([".wg = &#{wg_var}"] + captured.map { |name, _| ".#{name} = &#{name}" }).join(", ")

        # Transpile branch body with identifier → ctx.name.* rewrite
        # and rt → __rt to avoid shadowing the outer function's rt parameter.
        prev_capture_map = @do_capture_map || {}
        prev_rt_name     = @do_rt_name
        @do_capture_map = prev_capture_map.merge(
          captured.map { |name, _| [name, "ctx.#{name}.*"] }.to_h
        )
        @do_rt_name = "__rt"
        body_code = branch_exprs.map { |e|
          code = visit(e)
          code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
          code
        }.join("\n        ")
        @do_capture_map = prev_capture_map
        @do_rt_name     = prev_rt_name

        <<~ZIG.chomp
          const #{ctx_type} = struct {
              wg: *CheatHeader.WaitGroup,
              #{capture_fields}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  _ = &__rt;
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  #{body_code}
              }
          };
          var #{ctx_var} = #{ctx_type}{ #{capture_inits} };
          try #{wg_var}.sched.submitSpawn(
              @intFromPtr(&Runtime.entryWrapper),
              @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
              &#{ctx_var},
              .{}
          );
        ZIG
      end

      inner = branch_parts.join("\n")
      <<~ZIG.chomp
        {
            var #{wg_var} = CheatHeader.WaitGroup.init(rt.getSched());
            #{wg_var}.add(#{n});
            #{inner}
            #{wg_var}.wait();
        }
      ZIG

    when AST::BgBlock
      @bg_block_counter ||= 0
      id = @bg_block_counter
      @bg_block_counter += 1

      tense_t     = Type.new(node.full_type || :"~Void")
      inner_t     = Type.new(tense_t.tense_type)
      inner_zig   = inner_t.zig_type
      promise_zig = tense_t.zig_type
      is_void     = inner_zig == "void"

      ctx_type    = "__BgCtx#{id}"
      alloc_var   = "__bg#{id}_alloc"
      promise_var = "__bg#{id}_promise"
      ctx_var     = "__bg#{id}_ctx"
      blk_label   = "__bg#{id}"

      captured = collect_do_identifiers(node.body)

      capture_fields = captured.map do |name, type_obj|
        zig_t = type_obj ? Type.new(type_obj).zig_type : "anyopaque"
        "#{name}: #{zig_t},"
      end.join("\n        ")

      capture_inits = ([".inner = #{promise_var}.inner", ".alloc = #{alloc_var}"] +
        captured.map { |name, _| ".#{name} = #{name}" }).join(", ")

      rt_name = @do_rt_name || "rt"

      # Transpile body inside fiber — captured vars rewritten to ctx.name (by-value capture)
      prev_capture_map = @do_capture_map || {}
      prev_rt_name     = @do_rt_name
      @do_capture_map  = prev_capture_map.merge(
        captured.map { |name, _| [name, "ctx.#{name}"] }.to_h
      )
      @do_rt_name = "__rt"

      body_stmts = node.body.dup
      last_expr  = body_stmts.pop

      stmt_code = body_stmts.map { |e|
        code = visit(e)
        code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
        code
      }.join("\n            ")

      result_line = if last_expr.nil? || is_void
        last_expr ? "#{visit(last_expr)};" : ""
      else
        "ctx.inner.result = #{visit(last_expr)};"
      end

      @do_capture_map = prev_capture_map
      @do_rt_name     = prev_rt_name

      <<~ZIG.chomp
        #{blk_label}: {
            const #{ctx_type} = struct {
                inner: *#{promise_zig}.Inner,
                alloc: std.mem.Allocator,
                #{capture_fields}
                fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                    const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                    _ = &__rt;
                    const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                    defer ctx.alloc.destroy(ctx);
                    defer ctx.inner.wg.done();
                    #{stmt_code}
                    #{result_line}
                }
            };
            const #{alloc_var} = #{rt_name}.getSched().allocator;
            const #{promise_var} = try #{promise_zig}.spawn(#{alloc_var}, #{rt_name}.getSched());
            const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
            #{ctx_var}.* = .{ #{capture_inits} };
            try #{rt_name}.getSched().submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
                #{ctx_var},
                .{},
            );
            break :#{blk_label} #{promise_var};
        }
      ZIG

    when AST::NextExpr
      "#{visit(node.expr)}.next()"

    when AST::FuncCall, AST::MethodCall
      return transpile_Intrinsic(node) if !node.zig_pattern.nil?

      # Standard call (pass rt)
      # Note: We don't add 'try' here - let the caller decide via OR RAISE or context
      locked_map = @locked_unwrap_map || {}
      args_zig = node.args.map do |a|
        arg_code = visit(a)
        # Locked-unwrap aliases are Zig `*T` pointers; deref to pass as value to functions.
        if a.is_a?(AST::Identifier) && locked_map.key?(a.name)
          "#{arg_code}.*"
        # If argument is an array (ArrayList), convert to slice via .items for function params
        elsif a.type_info&.array?
          "(if (@hasField(@TypeOf(#{arg_code}), \"items\")) #{arg_code}.items else #{arg_code})"
        else
          arg_code
        end
      end
      mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias}." : ""

      if node.respond_to?(:extern_call) && node.extern_call
        # Native FFI call: no rt injection, no try (native Zig/C return convention)
        "#{mod_prefix}#{node.name}(#{args_zig.join(', ')})"
      else
        rt_name = @do_rt_name || "rt"
        # For generic function calls, inject inferred comptime type args after rt
        type_arg_strs = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
          node.generic_type_args.map { |t| Type.new(t).zig_type }
        else
          []
        end
        args = type_arg_strs + [rt_name] + args_zig
        call = "#{mod_prefix}#{node.name}(#{args.join(', ')})"
        "try #{call}"
      end

    when AST::ReturnNode
      rc_map = @rc_unwrap_map || {}

      # 1. Handle MOVE or RC-Retain
      if node.value.is_a?(AST::MoveNode) && node.value.value.is_a?(AST::Identifier)
        src_name = node.value.value.name
        return "#{src_name}_moved = true;\nreturn #{src_name};"
      end

      if node.value.is_a?(AST::Identifier) && !rc_map.key?(node.value.name)
        ti = node.value.type_info
        if ti&.any_rc?
          return "return #{transpile_rc_retain(ti, node.value.name)};"
        end
      end

      # 2. Standard Return with Move Suppression for unique heap
      suppress = emit_move_suppression(node.value)
      val_code = node.value.nil? ? "" : visit(node.value)
      
      if suppress.empty?
        "return #{val_code};"
      else
        "#{suppress}\nreturn #{val_code};"
      end

    when AST::GetField
      # Union unit-variant constructor: Result{ .Empty = {} }
      if node.target.is_a?(AST::Identifier)
        schema = @union_schemas&.dig(node.target.name.to_sym)
        return "#{node.target.name}{ .#{node.field} = {} }" if schema
      end

      target_code = visit(node.target)
      rc_map     = @rc_unwrap_map     || {}
      locked_map = @locked_unwrap_map || {}
      # target_code is already the unwrapped alias when inside a WITH block,
      # so skip the .data. indirection in that case.
      is_rc_unwrapped     = node.target.is_a?(AST::Identifier) && rc_map.key?(node.target.name)
      is_locked_unwrapped = node.target.is_a?(AST::Identifier) && locked_map.key?(node.target.name)
      ti = node.target.type_info
      if (ti&.multiowned? || ti&.shared?) && !is_rc_unwrapped
        # Rc(T)/Arc(T) store the value as .data (*T); Zig auto-derefs through the pointer
        "#{target_code}.data.#{node.field}"
      elsif (ti&.locked? || ti&.write_locked?) && !is_locked_unwrapped
        # *Locked(T) / *RwLocked(T): auto-deref pointer, then access .data field
        "#{target_code}.data.#{node.field}"
      else
        "#{target_code}.#{node.field}"
      end

    when AST::CapabilityWrap
      inner_code = visit(node.value)
      base_type  = node.value.resolved_type.to_s
      zig_base   = transpile_type(base_type)

      if node.sync == :locked && node.ownership == :shared
        # Arc(Locked(T)): lockedCreate then arcCreate
        <<~ZIG.chomp
          blk_sl: {
              const __sl_inner = try CheatLib.lockedCreate(#{zig_base}, rt.heapAlloc(), #{inner_code});
              break :blk_sl try CheatLib.arcCreate(CheatLib.Locked(#{zig_base}), rt.heapAlloc(), __sl_inner);
          }
        ZIG
      elsif node.sync == :locked
        "try CheatLib.lockedCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif node.sync == :write_locked
        "try CheatLib.rwLockedCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif node.ownership == :shared
        "try CheatLib.arcCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif node.ownership == :multiowned
        "try CheatLib.rcCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      else
        inner_code
      end

    when AST::MoveNode
      # MOVE expr — handled by parent VarDecl/ReturnNode; fallback emits raw value
      visit(node.value)

    when AST::Copy
      # Zig copies structs by value on assignment, so just return the inner expression
      visit(node.value)

    when AST::OptionalUnwrap
      # Zig uses .? for optional unwrapping
      "#{visit(node.target)}.?"

    when AST::RangeLit
      start_code = visit(node.start)
      end_code   = visit(node.finish)
      if node.inclusive
        "CheatLib.Range{ .start = #{start_code}, .end = #{end_code} + 1 }"
      else
        "CheatLib.Range{ .start = #{start_code}, .end = #{end_code} }"
      end

    when AST::Identifier
      # [FIX] Handle '_' Identifier acting as a Placeholder
      if node.name == "_" && @placeholder_name
        return @placeholder_name
      end

      # Inside a WITH block, use the unwrapped inner alias instead of the Rc handle
      rc_map = @rc_unwrap_map || {}
      return rc_map[node.name] if rc_map.key?(node.name)

      # Inside a DO block branch, access captured outer variables via ctx pointer
      capture_map = @do_capture_map || {}
      return capture_map[node.name] if capture_map.key?(node.name)

      node.name

    when AST::Literal
      case node.type
      when :STRING
        "\"#{node.value}\""  # Add quotes!
      when :NUMBER, :INT64
        node.value.to_i.to_s # Force Integer for Zig i64 compatibility
      when :BOOLEAN
        node.value.to_s      # "true"/"false" is fine
      when :NIL
        "null"               # Zig's null for optionals
      else
        node.value.to_s
      end

    when AST::UnaryOp
      right = visit(node.right)
      case node.op
      when :NOT, "!"
        "!#{right}"
      when :SUB, "-"
        "-#{right}"
      when :BITWISE_NOT, "~"
        "~#{right}"
      else
        raise "Transpiler Error: Unknown Unary Operator '#{node.op}'"
      end

    # TODO: Use Frame unless marked escaping
    when AST::BinaryOp
      return transpile_Smooth(node) if node.op == :SMOOTH
      return transpile_OrRescue(node) if node.op == :OR_RESCUE

      left = visit(node.left)
      right = visit(node.right)

      if node.op == :ADD || node.op == "+"
        # Check if we are operating on Strings
        # Annotator ensures full_type is set (e.g. "String[]" or "%String[]")
        t_left = node.left.full_type.to_s
        t_right = node.right.full_type.to_s

        alloc = node.storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"

        if Type.new(t_left).string? || Type.new(t_right).string?
          # Generate call to runtime helper
          # We use heapAlloc to ensure the result survives (safe default)
          return "try CheatLib.concat(#{alloc}, #{left}, #{right})"
        end
      end

      if node.op == :POW
        # Assuming i64 for now.
        # If types are float, you might need std.math.pow(f64, ...)
        return "std.math.pow(i64, #{left}, #{right})"
      end

      # Standard Operators
      op_str = ZIG_OPS[node.op]

      unless op_str
        raise "Transpiler Error: Unknown or Unsupported Binary Operator '#{node.op}'"
      end

      "(#{left} #{op_str} #{right})"

    when AST::Assert
      cond = visit(node.condition)
      "CheatLib.assert(#{cond}, \"#{node.message}\")"

    when AST::Raise
      # RAISE "message" - return an error in Zig
      msg = visit(node.message_expr)
      "return error.CheatError"

    # Marker nodes for OR RAISE / OR PASS - handled in transpile_OrRescue
    when AST::OrRaise
      "error.OrRaise"  # Should not be visited directly
    when AST::OrPass
      "undefined"  # Should not be visited directly

    else
      raise "Unknown Node: #{node.class}"
    end
  end

  def transpile_Smooth(node)
    lhs = node.left
    rhs = node.right

    # Check Higher-Order functions
    if node.right.is_a?(AST::SelectOp)
      return transpile_select_projection(node.left, node.right.expression)

    elsif node.right.is_a?(AST::WhereOp)
      return transpile_where_filter(node.left, node.right.expression)

    elsif node.right.is_a?(AST::IndexOp)
      return transpile_index_grouping(node.left, node.right.expression, node)

    elsif node.right.is_a?(AST::ReduceOp)
      return transpile_reduce(node.left, node.right)

    elsif node.right.is_a?(AST::OrderByOp)
      return transpile_order_by(node.left, node.right, node)

    elsif node.right.is_a?(AST::LimitOp)
      return transpile_limit(node.left, node.right, node)

    elsif node.right.is_a?(AST::UnnestOp)
      return transpile_unnest(node.left, node.right, node)

    elsif node.right.is_a?(AST::DistinctOp)
      return transpile_distinct(node.left, node.right, node)
    end

    # We construct a synthetic node that looks like the resulting function call.
    # This delegates all complexity (rt injection, print formatting, recursion)
    # to the existing visit_FuncCall handler.

    synthetic_call = if rhs.is_a?(AST::Identifier)
       # Pattern: x s> f  -->  f(x)
       AST::FuncCall.new(rhs.token, rhs.name, [lhs])

    elsif rhs.is_a?(AST::FuncCall)
       # Pattern: x s> f(y) --> f(x, y)
       # We inject the LHS as the *first* argument
       new_args = [lhs] + rhs.args
       AST::FuncCall.new(rhs.token, rhs.name, new_args)

    else
       raise "Transpiler Error: Invalid Pipe Destination #{rhs.class}"
    end

    # TODO: Clone rhs??
    if rhs.respond_to?(:zig_pattern)
      synthetic_call.zig_pattern = rhs.zig_pattern
    end
    if rhs.respond_to?(:full_type)
      synthetic_call.full_type = rhs.full_type
    end
    if rhs.respond_to?(:coerced_type)
      synthetic_call.coerced_type = rhs.coerced_type
    end

    # Visit the fake node as if it were in the original source
    visit(synthetic_call)
  end

  # --- ERROR HANDLING (OR RESCUE) ---
  def transpile_OrRescue(node)
    t_left = Type.new(node.left.full_type)

    # For error union handling, we need the raw call without 'try'
    # Visit the left normally first (which may add 'try' for error unions)
    left = visit(node.left)

    # If this is an error union, the visit may have added 'try' - strip it
    # because we'll handle it with catch or explicit try here
    left_raw = left.sub(/^try /, '')

    # Handle OR RAISE: bubble up error (Zig's `try`)
    if node.right.is_a?(AST::OrRaise)
      if t_left.error_union?
        # Use Zig's try to propagate error
        return "try #{left_raw}"
      else
        # Non-error type: just return the value
        return left
      end
    end

    # Handle OR PASS: ignore error, use undefined (Zig's `catch |_| undefined`)
    if node.right.is_a?(AST::OrPass)
      if t_left.error_union?
        # Use Zig's catch to ignore error and return undefined
        return "(#{left_raw} catch undefined)"
      else
        return left
      end
    end

    # Handle error union with default value: !T OR default -> T
    if t_left.error_union?
      right = visit(node.right)
      # Use Zig's catch to provide fallback value
      return "(#{left_raw} catch #{right})"
    end

    # Standard OR behavior (non-error types)
    right = visit(node.right)
    return "(#{left}) orelse #{right}"
  end

  def transpile_Intrinsic(node)
    # Special Builtins that can't be handled 1-1 mapping
    return send(node.zig_pattern, node) if node.zig_pattern.is_a?(Symbol)

    # 1. Gather Arguments
    #    Arg 0 is receiver (for methods), Args 1..N are params
    #    We must transpile them first.

    # TODO: Annotator should do this
    args_zig =
      if node.is_a?(AST::MethodCall)
        [visit(node.object)] + node.args.map { |a| visit(a) }
      else
        node.args.map { |a| visit(a) }
      end

    # 2. Resolve Placeholders
    #    {0} -> args_zig[0], {1} -> args_zig[1]
    pattern = node.zig_pattern

    #    {alloc} -> determine allocator automatically
    #    For method calls, use the object's storage (not the result's storage)
    if pattern.include?("{alloc}")
      target_storage = if node.is_a?(AST::MethodCall) && node.object.respond_to?(:storage)
        node.object.storage
      else
        node.storage
      end
      alloc = target_storage == :heap ? "rt.heapAlloc()" : "rt.frameAlloc()"
      pattern = pattern.gsub("{alloc}", alloc)
    end

    args_zig.each_with_index do |val, i|
      pattern = pattern.gsub("{#{i}}", val)
    end

    pattern
  end

  # Collect all AST::Identifier nodes in a list of expressions for DO block capture.
  # Returns a hash of { name => type_info } for each unique local variable referenced.
  def collect_do_identifiers(exprs)
    result = {}
    exprs.each { |e| walk_do_identifiers(e, result) }
    result
  end

  def walk_do_identifiers(node, result, locally_bound = Set.new)
    return unless node.is_a?(AST::Locatable)
    if node.is_a?(AST::Identifier)
      result[node.name] ||= node.type_info unless locally_bound.include?(node.name)
      return
    end
    # WithBlock: visit var_nodes as outer refs but exclude aliases from capture.
    if node.is_a?(AST::WithBlock)
      node.capabilities.each do |cap|
        walk_do_identifiers(cap[:var_node], result, locally_bound) if cap[:var_node]
      end
      aliases = node.capabilities.filter_map { |cap| cap[:alias] || cap[:var_node]&.name }.to_set
      new_bound = locally_bound | aliases
      node.body.each { |stmt| walk_do_identifiers(stmt, result, new_bound) }
      return
    end
    node.members.each do |m|
      child = node.send(m)
      do_walk_child(child, result, locally_bound)
    end
  end

  def do_walk_child(child, result, locally_bound = Set.new)
    case child
    when AST::Locatable
      walk_do_identifiers(child, result, locally_bound)
    when Array
      child.each { |c| do_walk_child(c, result, locally_bound) }
    when Hash
      child.each_value { |v| do_walk_child(v, result, locally_bound) }
    end
  end

  # Semi-colon helper
  # Builds the Zig boolean condition for a StructPattern case.
  # Non-wildcard fields produce `subject.field == value` joined with ` and `.
  # Returns "true" when all fields are wildcards / only `...` was given.
  def transpile_struct_pattern(subject, pat)
    conditions = pat.fields
      .reject { |f| f[:value] == :wildcard }
      .map { |f| "#{subject}.#{f[:name]} == #{visit(f[:value])}" }
    conditions.empty? ? "true" : conditions.join(" and ")
  end

  def transpile_block(statements)
    statements.map do |stmt|
      code = visit(stmt)
      # Add ; if it's not a block ending (}) and doesn't have one yet
      code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
      code
    end.join("\n")
  end


  def get_zig_format(flux_type)
    t = flux_type.to_s

    # 2. Handle Strings explicitly
    #    Flux might call it "String" or "String[]" depending on where it came from
    return "{s}" if t.include?("String")

    # 3. Handle Primitives
    case t
    when "Number", "Int64", "Byte" then "{d}" # Decimal
    when "Bool"                    then "{}"  # Auto (true/false)
    when "Void"                    then "{}"  # Void
    else
      "{any}" # Fallback for Structs/Objects (Debug print)
    end
  end

  def indent_text(text, amount = 4)
    padding = " " * amount
    text.split("\n").map do |line|
      line.strip.empty? ? line : "#{padding}#{line}"
    end.join("\n")
  end

  ### ---- STD LIB MACROS ---

  # [MACRO] Generates type-safe Zig print statements
  # Called automatically via :macro_print in STD_LIB
  def macro_print(node)
    # 1. Build Format String (e.g. "{d} {s}")
    formats = node.args.map do |arg|
      get_zig_format(arg.full_type)
    end.join(" ")

    # 2. Build Value List
    values = node.args.map { |a| visit(a) }.join(", ")

    # 3. Output
    "std.debug.print(\"#{formats}\\n\", .{#{values}});"
  end
end

# --- RUN IT ---


$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{severity}] #{msg}\n"
end

if __FILE__ == $0
  options = { mode: :standalone, pkg_paths: {} }

  OptionParser.new do |opts|
    opts.on('--log-level LEVEL', 'Set log level (DEBUG, INFO, WARN, ERROR)') do |level|
      $logger.level = Logger.const_get(level.upcase)
    end
    opts.on('--module', 'Emit as a Zig module (uses @import("cheat_runtime"), no runtime footer)') do
      options[:mode] = :module
    end
    opts.on('--pkg SPEC', 'Register a package path as "name=/abs/path/to/lib.cht"') do |spec|
      name, path = spec.split('=', 2)
      options[:pkg_paths][name] = File.expand_path(path)
    end
  end.parse!

  script_file = ARGV.first
  if script_file
    code       = File.read(script_file)
    source_dir = File.dirname(File.expand_path(script_file))
    transpiler = ZigTranspiler.new

    case options[:mode]
    when :module
      puts transpiler.transpile_as_module(code, source_dir: source_dir, pkg_paths: options[:pkg_paths])
    else
      puts transpiler.transpile(code, source_dir: source_dir, pkg_paths: options[:pkg_paths])
    end
  else
    $stderr.puts "Usage: ruby transpiler.rb [--module] [--pkg name=/path/to/lib.cht] <script.cht>"
  end
end

