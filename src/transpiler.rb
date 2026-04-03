#! /usr/bin/env ruby

require 'bundler/setup' # so `bundle exec` not needed
require "optparse"
require "logger"
require "set"
require "byebug"

require_relative "./lexer"
require_relative "./parser"
require_relative "./ast"
require_relative "./annotator"
require_relative "./pipeline_generator"
require_relative "./ownership_generator"
require_relative "./zig_type_mapper"
require_relative "./promotion_plan"
require_relative "./importer"
require_relative "./transpiler_context"

class ZigTranspiler
  include PipelineGenerator
  include OwnershipGenerator
  include ZigTypeMapper

  attr_reader :struct_schemas

  def initialize(importer: nil, source_dir: nil)
    @importer   = importer
    @source_dir = source_dir ? File.expand_path(source_dir) : Dir.pwd
    # SOA field-slice rewrite state (active during pipeline expression visits)
    @soa_rewrite_active = false
    @soa_needed_fields = Set.new
    @transpiler_context_stack = []
  end

  def current_tp_ctx; @transpiler_context_stack.last; end

  # Single-file entry point (used by the CLI and simple callers).
  # pkg_paths: { "name" => "/abs/path/to/lib.cht" } for REQUIRE "pkg:name" resolution.
  def transpile(cheat_code, source_dir: @source_dir, pkg_paths: {}, use_c_allocator: false, test_mode: false, strict_test: false)
    @source_dir = File.expand_path(source_dir)
    @test_mode = test_mode
    @active_stubs = {}
    @importer ||= ModuleImporter.new(base_dir: @source_dir, pkg_paths: pkg_paths)

    tokens    = Lexer.new(cheat_code).tokenize
    ast       = Parser.new(tokens, cheat_code).parse
    annotator = SemanticAnnotator.new(importer: @importer, source_dir: @source_dir, strict_test: strict_test)
    annotator.annotate!(ast)

    @ownership_graph = annotator.instance_variable_get(:@og)

    # Pass C: compute promotion + cleanup plans for all functions.
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    @promotion_plans = {}
    @cleanup_plans = {}
    fn_nodes.each do |name, fn|
      @promotion_plans[name] = PromotionPlan.compute(fn, schema_lookup: schema_lookup)
      @cleanup_plans[name] = CleanupPlan.compute(fn, fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    end

    @needs_safety_import = false
    @fn_needs_rt = {}
    @fn_can_fail = {}
    @fn_effects = {}
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      @fn_needs_rt[stmt.name] = stmt.needs_rt.nil? ? true : stmt.needs_rt
      @fn_can_fail[stmt.name] = stmt.can_fail.nil? ? true : stmt.can_fail
      @fn_effects[stmt.name] = stmt.effects || Set.new
    end
    body = visit(ast)
    safety_line = @needs_safety_import ? "const safety = @import(\"safety.zig\");\n" : ""
    # Auto-detect: use c_allocator when @sharded maps or @pinned BG blocks are present.
    # GPA is not suitable for multi-threaded workloads (canary corruption under concurrent load).
    needs_c_alloc = use_c_allocator || @used_sharded_map
    alloc_config = needs_c_alloc ? "pub const USE_C_ALLOCATOR = true;\n" : ""

    <<~ZIG
      const std = @import("std");
      const CheatHeader = @import("runtime-header.zig");
      const CheatLib = CheatHeader.CheatLib;
      const Runtime = CheatHeader.Runtime;
      const EbrContext = CheatHeader.EbrContext;
      #{safety_line}#{alloc_config}
      // -------------------------------------------------------------------------
      // 2. User Types & Functions (Transpiled)
      // -------------------------------------------------------------------------
      #{body}

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

    @needs_safety_import = false
    body = transpile_module(ast)
    safety_line = @needs_safety_import ? "const safety = @import(\"safety.zig\");\n" : ""

    # If the module defines main, emit a Zig test block so the module
    # can be used directly as the root of `zig test` without a wrapper file.
    has_cheat_main = ast.statements.any? { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
    test_block = if has_cheat_main
      <<~ZIG_TEST

        test "cheat main" {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();
            var global_ctx = EbrContext{};
            defer global_ctx.deinit(allocator);
            var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
            defer rt.deinit();
            rt.wireAllocator();
            try clearMain(&rt);
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
      #{safety_line}
      #{body}
      #{test_block}
    ZIG
  end

private

  # Compute cleanup plans from the annotated AST if not already done.
  # Called from visit_node(Program) to handle specs that bypass `transpile`.
  def ensure_cleanup_plans!(program_node)
    return if @cleanup_plans && !@cleanup_plans.empty?
    @cleanup_plans ||= {}
    @promotion_plans ||= {}
    fn_nodes = {}
    program_node.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    schema_lookup = ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) }
    fn_nodes.each do |name, fn|
      @promotion_plans[name] ||= PromotionPlan.compute(fn, schema_lookup: schema_lookup)
      @cleanup_plans[name] ||= CleanupPlan.compute(fn, fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    end
  end

  def visit(node)
    code = visit_node(node)
    # SROA path: stack-allocated fixed-array literals are emitted as raw [N]T{...} which
    # already carries the correct Zig type — applying a coerce wrapper on top would produce
    # invalid @as([]T, [N]T{...}).  Skip the cast for this case.
    sroa_array = node.is_a?(AST::ListLit) && node.storage == :stack &&
                 (node.coerced_type_info || node.type_info)&.fixed?
    if !sroa_array && node.respond_to?(:coerced_type) && node.coerced_type && node.coerced_type != node.full_type
      code = transpile_cast(code, node.full_type, node.coerced_type)
    end
    code
  end

  def visit_node(node)
    case node
    when AST::Program
      ensure_cleanup_plans!(node)
      @emitted_extern_modules = Set.new
      node.statements.map { |stmt|
        code = visit(stmt)
        next nil unless code
        line = stmt.respond_to?(:token) && stmt.token ? stmt.token.line : nil
        line ? "// CLR:#{line}\n#{code}" : code
      }.compact.join("\n\n")

    when AST::ExternFnDecl
      # Emit a Zig @import for the native module (once per unique module name).
      # Dotted paths: FROM "std.json" → @import("std").json, alias __std_json
      @emitted_extern_modules ||= Set.new
      mod = node.from_module
      if @emitted_extern_modules.add?(mod)
        mod_parts = mod.split(".")
        import_expr = "@import(\"#{mod_parts.first}\")" + mod_parts[1..].map { |p| ".#{p}" }.join
        mod_alias = mod.gsub(".", "_")
        "const #{mod_alias} = #{import_expr};"
      else
        nil
      end

    when AST::ExternStructDecl
      if node.from_module
        # Emit @import (once) and a type alias: const TypeName = module.TypeName;
        # Dotted paths: FROM "std.json" → @import("std").json, alias __std_json
        @emitted_extern_modules ||= Set.new
        mod = node.from_module
        mod_parts = mod.split(".")
        import_expr = "@import(\"#{mod_parts.first}\")" + mod_parts[1..].map { |p| ".#{p}" }.join
        mod_alias = mod.gsub(".", "_")
        parts = []
        parts << "const #{mod_alias} = #{import_expr};" if @emitted_extern_modules.add?(mod)
        parts << "const #{node.name} = #{mod_alias}.#{node.name};"
        parts.join("\n")
      else
        # No FROM clause — emit a local Zig struct definition.
        # CLEAR: EXTERN STRUCT JsonRecord { id: Int64, data: Int64[] };
        # ZIG:   const JsonRecord = struct { id: i64, data: []const i64 };
        @local_extern_structs ||= Set.new
        @local_extern_structs << node.name
        if node.fields.empty?
          # Empty local extern struct (e.g. ParseOptions) — no Zig definition needed.
          # Its literal ParseOptions{} emits .{} for Zig type inference.
          nil
        else
          fields_zig = node.fields.map do |name, field_def|
            zig_type = transpile_type(field_def[:type], is_field: true)
            "    #{name}: #{zig_type},"
          end.join("\n")
          "const #{node.name} = struct {\n#{fields_zig}\n};"
        end
      end

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

        # Propagate needs_rt/can_fail from imported functions so call sites
        # correctly omit or inject rt and try.
        if mod.ast
          @fn_needs_rt ||= {}
          @fn_can_fail  ||= {}
          mod.ast.statements.each do |stmt|
            next unless stmt.is_a?(AST::FunctionDef)
            @fn_needs_rt[stmt.name] = stmt.needs_rt.nil? ? true : stmt.needs_rt
            @fn_can_fail[stmt.name]  = stmt.can_fail.nil?  ? true : stmt.can_fail
          end
        end

        body = mod.transpiled_body.strip
        # Indent each line of the module body for readability inside the struct.
        indented = body.lines.map { |l| l.rstrip.empty? ? "" : "    #{l.rstrip}" }.join("\n")

        "const #{node.namespace} = struct {\n#{indented}\n};"
      end

    when AST::EnumDef
      # CHEAT: ENUM Direction { North, South }
      # ZIG:   const Direction = enum { North, South };
      @enum_schemas ||= {}
      @enum_schemas[node.name.to_sym] = node.variants
      variants = node.variants.map { |v| "    #{v}," }.join("\n")
      "const #{node.name} = enum {\n#{variants}\n};"

    when AST::UnionDef
      # CHEAT: UNION Result { Ok: Number, Err: String, Empty }
      # ZIG:   const Result = union(enum) { Ok: f64, Err: []const u8, Empty: void };
      # CHEAT: UNION Option<T> { Some: T, None }
      # ZIG:   fn Option(comptime T: type) type { return union(enum) { Some: T, None: void }; }
      # CHEAT: UNION Shape { Circle { radius: Number }, Point }
      # ZIG:   const Shape_Circle = struct { radius: f64 };
      #        const Shape = union(enum) { Circle: Shape_Circle, Point: void };
      @union_schemas ||= {}
      @union_schemas[node.name.to_sym] = node.variants
      # Track @indirect fields for auto-deref during GetField
      @indirect_fields ||= {}
      node.variants.each do |var_name, var_data|
        next unless var_data.is_a?(Hash) && var_data[:indirect_fields]
        var_data[:indirect_fields].each do |fname|
          @indirect_fields["#{node.name}_#{var_name}.#{fname}"] = true
        end
      end

      # Emit helper structs for inline struct variants before the union declaration.
      helper_structs = node.variants.filter_map do |var_name, var_data|
        next unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
        indirect = var_data[:indirect_fields] || Set.new
        fields = var_data[:fields].map do |fname, ftype|
          zig_t = transpile_type(ftype, is_field: true)  # Union inline struct fields use slices like variant payloads
          zig_t = "*#{zig_t}" if indirect.include?(fname)
          "    #{fname}: #{zig_t},"
        end.join("\n")
        # Generate deinit for inline structs that own heap data (@indirect, []T).
        deinit_lines = []
        var_data[:fields].each do |fname, ftype|
          ft = ftype.is_a?(Type) ? ftype : Type.new(ftype || :Any)
          if indirect.include?(fname)
            zig_t = transpile_type(ftype, is_field: true)
            deinit_lines << "        CheatLib.cleanup(#{zig_t}, alloc, self.#{fname});"
            deinit_lines << "        alloc.destroy(self.#{fname});"
          elsif ft.array? && !ft.string?
            elem_zig = transpile_type(ft.element_type)
            deinit_lines << "        if (comptime CheatLib.needsCleanup(#{elem_zig})) { for (self.#{fname}) |*__e| { CheatLib.cleanup(#{elem_zig}, alloc, __e); } }"
            deinit_lines << "        if (self.#{fname}.len > 0) alloc.free(self.#{fname});"
          end
        end

        if deinit_lines.any?
          deinit_body = deinit_lines.join("\n")
          "const #{node.name}_#{var_name} = struct {\n#{fields}\n\n    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n#{deinit_body}\n    }\n};"
        else
          "const #{node.name}_#{var_name} = struct {\n#{fields}\n};"
        end
      end

      variants = node.variants.map do |var_name, var_data|
        zig_t = if var_data.nil?
          "void"
        elsif var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
          "#{node.name}_#{var_name}"
        else
          transpile_type(var_data, is_field: true)  # Union payloads use slices, not ArrayListUnmanaged
        end
        "    #{var_name}: #{zig_t},"
      end.join("\n")

      union_decl = if node.type_params&.any?
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

      helper_structs.empty? ? union_decl : "#{helper_structs.join("\n\n")}\n\n#{union_decl}"

    when AST::UnionVariantLit
      # CHEAT: Shape.Circle{ radius: 5.0 }
      # ZIG:   Shape{ .Circle = Shape_Circle{ .radius = 5.0 } }
      variant_struct_name = "#{node.union_name}_#{node.variant_name}"
      # Check for @indirect fields in the union schema
      schema = @union_schemas&.dig(node.union_name.to_sym)
      var_data = schema&.dig(node.variant_name)
      indirect = (var_data.is_a?(Hash) && var_data[:indirect_fields]) || Set.new
      rt_name = @do_rt_name || "rt"
      field_inits = node.fields.map do |k, v|
        val = visit(v)
        if indirect.include?(k)
          # Heap-allocate indirect field: create pointer, assign value
          zig_t = transpile_type(var_data[:fields][k])
          "blk_#{k}: {\n    const __p = try #{rt_name}.heapAlloc().create(#{zig_t});\n    __p.* = #{val};\n    break :blk_#{k} __p;\n}"
        else
          val
        end
      end
      field_strs = node.fields.keys.zip(field_inits).map { |k, v| ".#{k} = #{v}" }.join(", ")
      "#{node.union_name}{ .#{node.variant_name} = #{variant_struct_name}{ #{field_strs} } }"

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
      # For the function return type, frame-allocated structs must be returned
      # by value (T, not *T).  The callee's arena is wiped by defer restoreFrameMark
      # on return, so returning a pointer would be use-after-free.  The transpiler
      # emits `return result.*` to copy the value before the wipe.
      ret_type = node.return_type || :Void
      if ret_type.is_a?(Type) && ret_type.frame? && ret_type.struct?
        ret_type = Type.new(ret_type.resolved)  # strip frame location → value type
      end
      final_type = transpile_type(ret_type)

      # For MUTABLE scalar params, Zig function params are const — we can't reassign them.
      # We mangle the Zig param name to `_m_<name>` and emit `var <name> = _m_<name>;`
      # in the prologue, so the body references the mutable shadow.
      # Slice/pointer params ([]T, *T) are fine as-is: element mutation doesn't reassign
      # the param itself.
      mutable_scalar_params = node.params.select do |p|
        p[:mutable] && !transpile_type(p[:type], is_param: true).start_with?("[]", "*")
      end.map { |p| p[:name] }.to_set

      params_zig = node.params.map do |param|
        p_name = mutable_scalar_params.include?(param[:name]) ? "_m_#{param[:name]}" : param[:name]
        p_type_sym = param[:type].is_a?(Type) ? param[:type].resolved : param[:type]
        p_type_obj = param[:type].is_a?(Type) ? param[:type] : Type.new(param[:type] || :Any)
        # Only real structs (not enums/unions/primitives) use anytype for transparent
        # stack/heap monomorphization.  Zig monomorphizes for T and *T automatically.
        is_user_struct = @struct_schemas&.key?(p_type_sym)
        if is_user_struct
          "#{p_name}: anytype"
        elsif p_type_obj.collection?
          # All collection types (map, pool, list, set) use anytype so the function
          # accepts any variant regardless of @sharded. Maps and pools are passed by
          # pointer (shared mutable state); lists and sets use slice conversion.
          "#{p_name}: anytype"
        else
          p_type = transpile_type(param[:type], is_param: true)
          "#{p_name}: #{p_type}"
        end
      end

      # For generic functions, prepend comptime type params before rt
      comptime_params = (node.type_params || []).map { |tp| "comptime #{tp}: type" }

      fn_needs_rt = node.needs_rt.nil? ? true : node.needs_rt
      fn_can_fail = node.can_fail.nil? ? true : node.can_fail
      @current_fn_has_rt = fn_needs_rt

      prev_tail_call_fn = @current_tail_call_fn
      @current_tail_call_fn = node.tail_call ? node.name : nil

      all_params = if fn_needs_rt
        comptime_params + ["rt: *Runtime"] + params_zig
      else
        comptime_params + params_zig
      end
      # Don't add ! if the type is already an error union.
      # @reentrant functions use anyerror! so Zig can resolve recursive error sets.
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
      vis = (node.visibility == :pub || @test_mode) ? "pub " : ""
      signature = "#{vis}fn #{zig_safe_name(node.name)}(#{all_params.join(', ')}) #{return_type_str}"

      @transpiler_context_stack.push(TranspilerContext.new(
        uses_frame: node.uses_frame,
        has_rt: fn_needs_rt,
        fn_name: node.name,
        collection_params: node.params.select { |p|
          pt = p[:type].is_a?(Type) ? p[:type] : Type.new(p[:type] || :Any)
          pt.needs_pointer_passing?
        }.map { |p| p[:name] }.to_set
      ))

      # Frame mark save/restore: rewind the frame arena on return so each
      # function call is a self-cleaning scope. Triggered by direct frame
      # allocations (uses_frame) OR stdlib calls that use {alloc} (uses_alloc).
      # SKIP for functions returning reference types — returned data lives
      # on the caller's frame and must survive past return. Safe for value
      # types: primitives, Void, enums, unions (returned by copy, not pointer).
      uses_frame_or_alloc = node.uses_frame || node.uses_alloc
      ret_type_obj = node.return_type.is_a?(Type) ? node.return_type : Type.new(node.return_type || :Void)
      returns_value_type = ret_type_obj.void? || ret_type_obj.primitive? || ret_type_obj.resource? ||
                           @enum_schemas&.key?(ret_type_obj.resolved) ||
                           @union_schemas&.key?(ret_type_obj.resolved)
      prologue = if fn_needs_rt
        (uses_frame_or_alloc && returns_value_type) ? "const frame_mark = rt.saveFrameMark();\ndefer rt.restoreFrameMark(frame_mark);\n" : "_ = &rt;"
      else
        nil
      end

      # @nonReentrant: insert a StackGuard that errors at runtime on unexpected recursion.
      if node.reentrant == :non_reentrant
        @needs_safety_import = true
        guard = "var _guard = try safety.StackGuard.enter(@src());\n    _guard.push();\n    defer _guard.pop();"
        prologue = prologue ? "#{guard}\n    #{prologue}" : guard
      end
      # Suppress unused-parameter warnings only for params not referenced in the body.
      # Zig 0.15+ errors on any unused function parameter; _ = &x; is a safe no-op.
      # For mutable scalar params the Zig param name is `_m_<name>`, handle them separately.
      used_names = collect_identifier_names(node.body)
      param_suppressions = node.params
        .reject { |p| used_names.include?(p[:name]) }
        .map    { |p| mutable_scalar_params.include?(p[:name]) ? "_ = &_m_#{p[:name]};" : "_ = &#{p[:name]};" }
        .join("\n    ")

      # Emit `var <name> = _m_<name>; _ = &<name>;` for used mutable scalar params.
      # The `_ = &<name>;` suppresses Zig's "never mutated" error for params that
      # are only forwarded to callees (not locally mutated).
      mutable_param_shadows = mutable_scalar_params
        .select { |name| used_names.include?(name) }
        .map    { |name| "var #{name} = _m_#{name}; _ = &#{name};" }
        .join("\n    ")

      # Emit cleanup for TAKES parameters via CleanupPlan.
      # Only when the function has rt (cleanup uses rt.heapAlloc/frameAlloc).
      fn_plan = @cleanup_plans&.dig(node.name)
      takes_cleanup = if fn_needs_rt
        (node.deferred_drops || []).filter_map { |drop|
          param_def = node.params.find { |p| p[:name] == drop[:name] }
          next unless param_def&.dig(:takes)
          entry = fn_plan&.lookup(drop[:name])
          next unless entry && entry[:needs_cleanup]
          ti = drop[:type].is_a?(Type) ? drop[:type] : Type.new(drop[:type] || :Any)
          proxy = Struct.new(:type_info, :storage, :resource_close_zig, :container_borrow).new(ti, :heap, entry[:resource_close_zig], false)
          emit_cleanup_from_entry(zig_safe_name(drop[:name]), entry, proxy)
        }.reject(&:empty?).join("\n    ")
      else
        ""
      end

      prologue_parts = [prologue,
                        param_suppressions.empty? ? nil : param_suppressions,
                        mutable_param_shadows.empty? ? nil : mutable_param_shadows,
                        takes_cleanup.empty? ? nil : takes_cleanup].compact
      prologue = prologue_parts.join("\n    ")

      has_catch = node.catch_clauses.is_a?(Array) && node.catch_clauses.any?
      @current_fn_has_catch = has_catch
      @current_fn_snapshot_types = Set.new if has_catch

      body = transpile_block(node.body)
      @current_tail_call_fn = prev_tail_call_fn
      @transpiler_context_stack.pop

      if !has_catch
        <<~ZIG
          #{signature} {
              #{prologue}
              #{body}
          }
        ZIG
      else
        rt_name = @do_rt_name || "rt"

        snap_types = @current_fn_snapshot_types || Set.new
        snapshot_decl = ""
        if snap_types.size == 1
          snap_zig = transpile_type(snap_types.first)
          snapshot_decl = "const __snap_ptr = #{rt_name}.__error.snapshotAs(#{snap_zig});\n" \
                          "            const snapshot = if (__snap_ptr) |p| p.* else undefined;\n" \
                          "            const __has_snapshot = __snap_ptr != null;\n" \
                          "            _ = &snapshot; _ = &__has_snapshot;"
        end

        catch_dupe = node.returns_promoted && node.catch_clauses.is_a?(Array) && node.catch_clauses.any?

        catch_clauses_zig = node.catch_clauses.map do |clause|
          kind = clause[:kind]
          error_name = clause[:error_name]
          prev_catch_dupe = @catch_dupe_string_returns
          @catch_dupe_string_returns = catch_dupe
          clause_body_code = clause[:body].map { |s| visit(s) }.join("\n            ")
          @catch_dupe_string_returns = prev_catch_dupe

          cond_parts = ["#{rt_name}.__error.matchesKind(.#{kind})"]
          cond_parts << "#{rt_name}.__error.matchesName(\"#{error_name}\")" if error_name
          cond = cond_parts.join(" and ")

          "if (#{cond}) {\n            const __error = #{rt_name}.__error;\n            _ = &__error;\n            #{snapshot_decl}\n            defer #{rt_name}.freeSnapshot();\n            #{clause_body_code}\n        }"
        end.join(" else ")

        default_code = ""
        if node.default_catch.is_a?(Array) && node.default_catch.any?
          prev_catch_dupe = @catch_dupe_string_returns
          @catch_dupe_string_returns = catch_dupe
          default_body = node.default_catch.map { |s| visit(s) }.join("\n            ")
          @catch_dupe_string_returns = prev_catch_dupe
          default_code = " else {\n            const __error = #{rt_name}.__error;\n            _ = &__error;\n            defer #{rt_name}.freeSnapshot();\n            #{default_body}\n        }"
        else
          if fn_can_fail
            default_code = " else {\n            #{rt_name}.freeSnapshot();\n            return error.CheatError;\n        }"
          else
            default_code = " else {\n            #{rt_name}.freeSnapshot();\n            unreachable;\n        }"
          end
        end

        call_args = fn_needs_rt ? (["rt"] + node.params.map { |p| p[:name] }) : node.params.map { |p| p[:name] }
        inner_params = all_params.join(', ')
        inner_ret = fn_can_fail ? (final_type.start_with?("!") ? "anyerror!#{final_type[1..]}" : "anyerror!#{final_type}") : "!#{final_type}"
        inner_name = "__#{node.name}_body"

        <<~ZIG
          fn #{inner_name}(#{inner_params}) #{inner_ret} {
              #{prologue}
              #{body}
          }

          #{signature} {
              return #{inner_name}(#{call_args.join(', ')}) catch {
                  #{catch_clauses_zig}#{default_code}
              };
          }
        ZIG
      end

    when AST::LambdaLit
      # Transpile a lambda literal as an anonymous Zig struct with a named `call` function.
      # This yields a comptime function reference that Zig coerces to *const fn(...).
      # Captures are not yet supported (Phase 2+).
      sig = node.full_type  # Type wrapping { params: [...], return: { type: ... }, lambda: true }
      @lambda_counter ||= 0
      @lambda_counter += 1
      fn_name = "_lambda_#{@lambda_counter}"

      params_zig = (sig[:params] || []).map do |p|
        p_name = p[:name]
        p_type = p[:type]
        type_str = p_type.is_a?(Type) ? p_type.zig_type(is_param: true) : transpile_type(p_type || :Any, is_param: true)
        "#{p_name}: #{type_str}"
      end

      ret = sig[:return]&.fetch(:type, nil) || :Void
      ret_zig = ret.is_a?(Type) ? ret.zig_type : transpile_type(ret)
      ret_str = ret_zig.start_with?("!") ? ret_zig : "anyerror!#{ret_zig}"

      # Use _rt to avoid shadowing an enclosing function's `rt` parameter (Zig 0.13+ forbids it).
      all_params = ["_rt: *Runtime"] + params_zig

      body_expr = visit(node.body)
      # Lambdas have a single-expression body; wrap in return.
      body_str = "return #{body_expr};"

      rt_sup = "_ = &_rt;"
      param_sups = (sig[:params] || []).map { |p| "_ = &#{p[:name]};" }.join(" ")
      sups = [rt_sup, param_sups].reject(&:empty?).join(" ")

      "&(struct { fn #{fn_name}(#{all_params.join(', ')}) #{ret_str} { #{sups} #{body_str} } }).#{fn_name}"

    # TODO: Need to call destroy, have objects recursively destroy pointers / resources
    when AST::VarDecl
      is_mutable = node.respond_to?(:mutable) && node.mutable
      # Bounded/open/infinite streams and shared promises must be `var` even when declared
      # immutable in CLEAR, because their next() methods take *Self (mutate internal state).
      # @list and @pool also need `var` because deinit(*Self, alloc) requires a mutable receiver.
      ft = Type.new(node.full_type || :Void)
      is_mutable ||= ft.bounded_stream? || ft.shared_promise? || ft.open_stream? || ft.inf_stream?
      is_mutable ||= ft.collection?
      is_mutable ||= ft.resource? || node.resource_close_zig  # Resources need var for defer deinit
      # @local pointers are always `const` — mutation goes through the pointer, not the binding.
      # Same as @locked: the pointer itself never changes, only the pointee.
      is_mutable = false if ft.local?
      actually_mutated = is_mutable && node.respond_to?(:var_mutated) && node.var_mutated == true
      # Downgrade unnecessary MUTABLE to const for better Zig codegen (SROA, vectorization).
      # Collections/streams are forced to var for deinit even if never reassigned.
      # Types that require `var` in Zig even if the binding itself is never reassigned:
      # collections (deinit mutates), streams, dynamic arrays, and structs with
      # heap-promoted collection fields (field-level deinit needs mutable access).
      # Check if struct schema contains collection/string fields needing mutable deinit.
      struct_has_cleanup = if ft&.struct? && !ft&.any_rc? && !ft&.any_sync?
        schema = @struct_schemas&.dig(ft.resolved)
        schema&.any? { |fn, fd|
          next if fn.is_a?(Symbol)
          ftype = fd.is_a?(Hash) ? fd[:type] : fd
          ftype_t = ftype.is_a?(Type) ? ftype : Type.new(ftype || :Any)
          ftype_t.collection? || ftype_t.map? || ftype_t.string?
        }
      end
      has_mutable_cleanup = ft&.collection? || ft&.bounded_stream? || ft&.shared_promise? ||
                            ft&.open_stream? || ft&.inf_stream? || (ft&.array? && ft&.dynamic?) ||
                            ft&.heap_promoted || ft&.resource? || node.resource_close_zig || struct_has_cleanup
      forced_var = is_mutable && has_mutable_cleanup
      keyword = if !is_mutable
        "const"
      elsif actually_mutated || forced_var
        "var"
      else
        if node.var_used
          $stderr.puts "\e[33m[Warning]\e[0m MUTABLE '#{node.name}' is never reassigned — consider removing MUTABLE (line #{node.token.line})"
        else
          $stderr.puts "\e[33m[Warning]\e[0m Unused variable '#{node.name}' (line #{node.token.line})"
        end
        "const"  # MUTABLE but never reassigned → emit const for SROA
      end
      zig_type = transpile_type(node.full_type)
      # Always emit explicit type annotation for fn_type (Zig can't always infer *const fn(...)).
      annotation = (ZIG_PRIMITIVES.include?(zig_type) || ft.fn_type?) ? ": #{zig_type}" : ""

      # 1. Resolve MOVE vs RETAIN logic
      @current_rhs_is_move = node.value.is_a?(AST::MoveNode)
      rhs_node = @current_rhs_is_move ? node.value.value : node.value
      rhs_ident = rhs_node if rhs_node.is_a?(AST::Identifier)
      
      # Exception: inside a WITH block the RHS is already the unwrapped plain value, not an Rc/Arc.
      rc_map = @rc_unwrap_map || {}
      rhs_is_unwrapped = rhs_ident && rc_map.key?(rhs_ident.name)
      rhs_ti = rhs_ident&.type_info
      rt_name = @do_rt_name || "rt"

      value_code = if node.full_type&.pool?
        # Pool: pre-allocate with fixed capacity via initCapacity.
        rt_name = @do_rt_name || "rt"
        cap = node.full_type.capacity
        "try #{node.full_type.zig_type}.initCapacity(#{rt_name}.heapAlloc(), #{cap})"
      elsif node.full_type&.set_collection?
        # Set: zero-initialize
        "#{node.full_type.zig_type}{}"
      elsif node.full_type&.list_collection?
        # @list / ShardedList: if the RHS is a function call, use the call result.
        # Otherwise zero-initialize (empty-list-literal path).
        rhs = @current_rhs_is_move ? node.value.value : node.value
        if rhs.is_a?(AST::FuncCall) || rhs.is_a?(AST::MethodCall)
          visit(node.value)
        else
          "#{node.full_type.zig_type}{}"
        end
      elsif node.type.is_a?(Type) && node.type.map? && node.type.striped?
        # Striped map (ShardedStringMap/MutexShardedStringMap): store heapAlloc.
        @used_sharded_map = true
        if node.type.shared? || node.type.multiowned?
          # Arc/Rc-wrapped striped map: build inner map, then wrap with Arc/Rc.
          bare = Type.new(node.type.resolved.to_s)
          bare.shard_count = node.type.shard_count
          bare.sync = node.type.sync
          bare_init = "#{bare.zig_type}{ .alloc = #{rt_name}.heapAlloc() }"
          create_fn = node.type.shared? ? "arcCreate" : "rcCreate"
          "try CheatLib.#{create_fn}(#{bare.zig_type}, #{rt_name}.heapAlloc(), #{bare_init})"
        else
          "#{node.type.zig_type}{ .alloc = #{rt_name}.heapAlloc() }"
        end
      elsif node.type.is_a?(Type) && node.type.map? && node.type.sharded?
        # PartitionedStringMap (shared-nothing): no alloc field.
        @used_sharded_map = true
        "#{node.type.zig_type}{}"
      elsif rhs_ti&.any_rc? && !rhs_is_unwrapped && !@current_rhs_is_move
        transpile_rc_retain(rhs_ti, rhs_ident.name)
      else
        visit(node.value)
      end

      safe_name = zig_safe_name(node.name)
      decl = "#{keyword} #{safe_name}#{annotation} = #{value_code};"

      # 2. Cleanup & Move Suppression (must be computed before suppression decision)
      affine_logic = emit_cleanup(safe_name, node)
      move_source_logic = emit_move_suppression(rhs_ident)
      @current_rhs_is_move = false

      # Suppression: Zig warns on unused variables and never-mutated vars.
      # - `var` (actually mutated + used): no suppression needed
      # - `var` (forced for collections/streams): always `_ = &name;`
      # - `const` (unused): `_ = name;` (no & — preserves SROA)
      suppression = if keyword == "var"
        if actually_mutated && node.var_used && !forced_var
          ""  # used AND mutated — Zig won't warn
        else
          "_ = &#{safe_name};"
        end
      else
        (node.var_used || !affine_logic.empty?) ? "" : "_ = #{safe_name};"
      end

      "#{decl} #{suppression}\n#{affine_logic}\n#{move_source_logic}"


    when AST::BindExpr
      if node.mode == :decl
        # Transpile as immutable declaration — delegate to VarDecl logic via a proxy
        proxy = AST::VarDecl.new(node.token, node.name, node.type, node.value, false)
        proxy.full_type          = node.full_type
        proxy.storage            = node.storage
        proxy.slot_size          = node.slot_size
        proxy.resource_close_zig = node.resource_close_zig
        proxy.var_used           = node.var_used
        visit(proxy)
      else
        # Transpile as reassignment — clean up old value for non-Copy types.
        safe = zig_safe_name(node.name)
        value_str = visit(node.value)
        move_logic = emit_move_suppression(node.value)

        fn_name = current_tp_ctx&.fn_name
        entry = @cleanup_plans&.dig(fn_name)&.lookup(node.name)
        if entry && entry[:needs_cleanup] && entry[:kind] != :resource
          ti = node.type_info
          zig_type = ti ? transpile_type(ti.resolved.to_s) : "UNKNOWN"
          alloc = alloc_expr_from_plan(entry)
          "CheatLib.cleanup(#{zig_type}, #{alloc}, &#{safe});\n#{safe} = #{value_str}; #{move_logic}"
        else
          "#{safe} = #{value_str}; #{move_logic}"
        end
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
          # Auto-lock: emit inline mutex guard for one-line mutations on @locked/@writeLocked vars.
          if node.auto_lock
            var_name  = node.auto_lock[:var]
            sync      = node.auto_lock[:sync]
            guard_var = "__#{var_name}_guard"
            alias_var = "__#{var_name}_inner"
            zig_var   = @do_capture_map&.dig(var_name) || var_name
            lock_expr = zig_var

            if sync == :always_mutable
              # RefCell: direct access through .data, no mutex guard
              field = node.name.field
              prev_locked_map = @locked_unwrap_map || {}
              @locked_unwrap_map = prev_locked_map.merge({ alias_var => true })
              value = visit(node.value).gsub(/\b#{Regexp.escape(zig_var)}\.data\./, "#{alias_var}.")
              @locked_unwrap_map = prev_locked_map
              return "#{zig_var}.get().#{field} = #{value};"
            end

            acquire = sync == :write_locked ? "#{lock_expr}.write()" : "#{lock_expr}.acquire()"
            # Install locked unwrap map so RHS field reads also use the dereferenced pointer.
            prev_locked_map = @locked_unwrap_map || {}
            @locked_unwrap_map = prev_locked_map.merge({ alias_var => true })
            # Transpile field and value with the alias substituted for the target.
            field = node.name.field
            value = visit(node.value).gsub(/\b#{Regexp.escape(zig_var)}\.ctrl\.data\./, "#{alias_var}.")
            @locked_unwrap_map = prev_locked_map

            return "{\nvar #{guard_var} = #{acquire};\ndefer #{guard_var}.release();\nconst #{alias_var} = #{guard_var}.get();\n#{alias_var}.#{field} = #{value};\n}"
          end

          target = visit(node.name.target)
          field  = node.name.field
          value  = visit(node.value)
          return "#{target}.#{field} = #{value};"
        elsif node.name.is_a?(AST::GetIndex)
          # Check if target is a Map
          target_node = node.name.target
          if target_node.metatype == :hashmap
             map_ft   = Type.new(target_node.full_type)
             target_ti = target_node.type_info
             map_ref  = visit(target_node)
             # Auto-deref Arc/Rc-wrapped maps
             map_ref = "#{map_ref}.ctrl.data.*" if target_ti&.map? && (target_ti&.shared? || target_ti&.multiowned?)
             key_ref  = visit(node.name.index)
             val_ref  = visit(node.value)
             rt_name  = @do_rt_name || "rt"

             if map_ft.numeric_map?
               alloc = (map_ft.escaped_return || map_ft.heap_promoted || map_ft.sharded? || map_ft.striped?) ? "#{rt_name}.heapAlloc()" : "#{rt_name}.frameAlloc()"
               if map_ft.sharded? || map_ft.striped?
                 return "try #{map_ref}.put(#{alloc}, #{key_ref}, #{val_ref});"
               else
                 key_zig = map_ft.key_type.zig_type
                 val_zig = map_ft.value_type.zig_type
                 return "try CheatLib.numericMapPut(#{key_zig}, #{val_zig}, #{alloc}, &#{map_ref}, #{key_ref}, #{val_ref});"
               end
             else
               # Shard-direct: putDirect(shard_idx, alloc, key, val) — no hash, no routing
               # Key comes from the pre-routed queue, not recomputed from the body expression.
               if @shard_direct_map && target_node.is_a?(AST::Identifier) && target_node.name == @shard_direct_map
                 return "try #{map_ref}.putDirect(#{@shard_direct_idx}, std.heap.c_allocator, #{@shard_direct_key}, #{val_ref});"
               end
               # The map stores its own allocator from the first put — the allocator
               # passed here is captured by the map and used for all subsequent ops.
               # Frame-local maps get frameAlloc (arena, zero-cost cleanup).
               # Sharded/promoted maps get heapAlloc (GPA, tracked cleanup).
               key_alloc = "#{rt_name}.heapAlloc()"
               val_alloc = (map_ft.sharded? || map_ft.striped?) ? "#{rt_name}.heapAlloc()" : "#{rt_name}.frameAlloc()"
               # String literals in map values must be heap-duped (rodata can't be freed)
               val_ref = heap_dupe_string_literals(val_ref, node.value, rt_name)
               move_logic = emit_move_suppression(node.value)
               code = "try #{map_ref}.put(#{key_alloc}, #{val_alloc}, #{key_ref}, #{val_ref});"
               return move_logic.empty? ? code : "#{code}\n#{move_logic}"
             end
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
        # @list (ArrayListUnmanaged) → slice conversion for struct/union fields expecting []T
        vt = v.type_info.is_a?(Type) ? v.type_info : nil
        val_code = "#{val_code}.items" if vt&.list_collection?
        ".#{k} = #{val_code}"
      end.join(", ")

      struct_name = if node.type_args&.any?
        zig_args = node.type_args.map { |a| Type.new(a.to_sym).zig_type }.join(", ")
        "#{node.name}(#{zig_args})"
      else
        node.name
      end

      # Local EXTERN STRUCT with no fields (e.g. ParseOptions{}) → emit .{}
      # so Zig infers the expected type (e.g. std.json.ParseOptions(T)).
      @local_extern_structs ||= Set.new
      struct_init = if node.fields.empty? && @local_extern_structs.include?(node.name)
        ".{}"
      else
        "#{struct_name}{ #{field_inits} }"
      end
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
      elsif node.storage == :frame
        # Large struct (> 128 slots): allocate in the frame arena so it doesn't bloat the
        # fiber stack.  The frame mark is saved/restored by the enclosing function, so no
        # explicit destroy is needed — O(1) bulk reclaim on function exit.
        <<~ZIG
          blk: {
             #{move_logic}
             const ptr = try rt.frameAlloc().create(#{struct_name});
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

      # Bounded stream: ~T[N] — emit a BoundedStream struct literal.
      # Each element is a BG block expression (labeled Zig block → Promise(T)).
      # We pre-declare each promise as a local const so the array initializer is clean.
      if ti.bounded_stream?
        @stream_lit_counter ||= 0
        s_id = @stream_lit_counter
        @stream_lit_counter += 1

        elem_zig    = ti.stream_element_type.zig_type
        n           = ti.stream_capacity
        promise_zig = "CheatLib.Promise(#{elem_zig})"
        stream_zig  = ti.zig_type

        promise_decls = node.items.each_with_index.map do |item, i|
          "const __stream#{s_id}_item#{i} = #{visit(item)};"
        end.join("\n        ")

        items_list = (0...n).map { |i| "__stream#{s_id}_item#{i}" }.join(", ")

        return <<~ZIG.chomp
          __stream#{s_id}: {
              #{promise_decls}
              break :__stream#{s_id} #{stream_zig}{
                  .items = [#{n}]#{promise_zig}{ #{items_list} },
              };
          }
        ZIG
      end

      element_ti = ti.element_type
      zig_type = element_ti.zig_type

      # 2a. SROA: stack-allocated fixed array → emit a raw Zig array literal so LLVM can
      #     apply Scalar Replacement of Aggregates and keep elements in registers.
      #     This path fires when the declared type is T[N] and the array is small (≤128 slots).
      if node.storage == :stack && ti.fixed?
        items_code = node.items.map { |item| visit(item) }.join(", ")
        return "[#{ti.capacity}]#{zig_type}{ #{items_code} }"
      end

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
      transpile_hash_lit(node)

    when AST::GetIndex
      # 1. Resolve Target and Index
      target = visit(node.target)
      index = visit(node.index)
      target_ti = node.target.type_info

      # Auto-deref Arc/Rc-wrapped maps
      target = "#{target}.ctrl.data.*" if target_ti&.map? && (target_ti&.shared? || target_ti&.multiowned?)

      if node.target.metatype == :hashmap
        map_ft = Type.new(node.target.full_type)

        if map_ft.numeric_map? && !(map_ft.sharded? || map_ft.striped?)
          key_zig = map_ft.key_type.zig_type
          val_zig = map_ft.value_type.zig_type
          "CheatLib.numericMapGet(#{key_zig}, #{val_zig}, #{target}, #{index})"
        else
          # Shard-direct: getDirect(shard_idx, key) — no hash, no routing
          # Key comes from the pre-routed queue, not recomputed from the index expression.
          if @shard_direct_map && node.target.is_a?(AST::Identifier) && node.target.name == @shard_direct_map
            "#{target}.getDirect(#{@shard_direct_idx}, #{@shard_direct_key})"
          else
            # Unified .get() API works for StringMap, PartitionedStringMap, ShardedStringMap
            "#{target}.get(#{index})"
          end
        end
      elsif node.target.type_info&.pool?
        "#{target}.get(#{index})"
      elsif node.target.type_info&.string?
        # String indexing: returns a single-char string ([]const u8), not a byte
        "CheatLib.charAt(#{target}, #{index})"
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
            # Use var if MATCH-as-move will emit deinit (needs mutable self)
            bind_kw = (node.expr.is_a?(AST::Identifier) && node.expr.was_moved) ? "var" : "const"
            binding_decl = "#{bind_kw} #{c[:binding]} = #{subject}.#{variant}; _ = &#{c[:binding]};\n    "
            # MATCH-as-move: if source was consumed by AS extraction, suppress cleanup
            # on source and emit cleanup on the AS binding.
            if node.expr.is_a?(AST::Identifier) && node.expr.was_moved
              src_name = zig_safe_name(node.expr.name)
              sym = node.expr.respond_to?(:symbol) ? node.expr.symbol : nil
              decl = sym&.reg
              is_local = decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
              is_takes_param = sym&.respond_to?(:takes) && sym&.takes
              fn_name = current_tp_ctx&.fn_name
              as_entry = @cleanup_plans&.dig(fn_name)&.lookup(c[:binding])
              if as_entry && as_entry[:needs_cleanup]
                binding_decl += "#{src_name}_moved = true;\n    " if is_local || is_takes_param
                as_alloc = alloc_expr_from_plan(as_entry)
                case as_entry[:kind]
                when :match_as_slice
                  variant_schema = @union_schemas&.dig(union_lookup, variant)
                  payload_t = variant_schema.is_a?(Type) ? variant_schema : (Type.new(variant_schema) rescue nil)
                  elem_zig = transpile_type(payload_t&.element_type)
                  binding_decl += "var #{c[:binding]}_moved = false; _ = &#{c[:binding]}_moved;\n    "
                  binding_decl += "defer if (!#{c[:binding]}_moved) { if (comptime CheatLib.needsCleanup(#{elem_zig})) { for (#{c[:binding]}) |*__e| { CheatLib.cleanup(#{elem_zig}, #{as_alloc}, __e); } } if (#{c[:binding]}.len > 0) #{as_alloc}.free(#{c[:binding]}); };\n    "
                when :match_as_inline_struct
                  binding_decl += "var #{c[:binding]}_moved = false; _ = &#{c[:binding]}_moved;\n    "
                  binding_decl += "defer if (!#{c[:binding]}_moved) #{c[:binding]}.deinit(#{as_alloc});\n    "
                end
              end
            end
            body = "#{binding_decl}#{body}"
          elsif c[:destructure]
            # Union variant destructuring: extract each named field from the payload.
            payload_access = "#{subject}.#{variant}"
            bindings = c[:destructure].fields.filter_map do |f|
              next if f[:value] == :wildcard
              if f[:value] == :bind
                "const #{f[:name]} = #{payload_access}.#{f[:name]}; _ = &#{f[:name]};"
              end
            end
            body = "#{bindings.join("\n    ")}\n    #{body}" if bindings.any?
          end
        else
          case c[:kind]
          when :when
            cond = visit(c[:value])
          when :struct_pattern
            cond, bindings = transpile_struct_pattern(subject, c[:value])
            body = "#{bindings}\n    #{body}" unless bindings.empty?
          else
            val = visit(c[:value])
            expr_type = Type.new(node.expr.resolved_type || :Any)
            cond = if expr_type.string?
              "CheatLib.strEql(#{subject}, #{val})"
            else
              "#{subject} == #{val}"
            end
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

    when AST::ForEach
      coll_code = visit(node.collection)
      var       = zig_safe_name(node.var_name)
      body      = transpile_block(node.body)
      rt_ref    = @do_rt_name || "rt"
      coll_type = node.collection.full_type
      ct        = coll_type.is_a?(Type) ? coll_type : Type.new(coll_type)
      yield_line = current_tp_ctx&.has_rt ? "\n#{rt_ref}.checkYield();" : ""

      if ct.map?
        # HashMap iteration: while-loop over keyIterator
        @for_counter = (@for_counter || 0) + 1
        iter_var = "__kit_#{@for_counter}"
        "{\nvar #{iter_var} = #{coll_code}.keyIterator();\nwhile (#{iter_var}.next()) |#{var}| {\n #{body} #{yield_line}\n}\n}"
      else
        iterable = ct.list_collection? ? "#{coll_code}.items" : "&#{coll_code}"
        "for (#{iterable}) |#{var}| {\n #{body} #{yield_line}\n}"
      end

    when AST::ForRange
      start_val = visit(node.start_expr)
      end_val   = visit(node.end_expr)
      var       = zig_safe_name(node.var_name)
      body      = transpile_block(node.body)
      rt_ref    = @do_rt_name || "rt"
      cmp       = node.inclusive ? "<=" : "<"
      @for_counter = (@for_counter || 0) + 1
      iter_var  = "__for_#{@for_counter}"
      if current_tp_ctx&.has_rt
        "{\nvar #{iter_var}: i64 = #{start_val};\nwhile (#{iter_var} #{cmp} #{end_val}) : (#{iter_var} += 1) {\nconst #{var}: i64 = #{iter_var}; _ = &#{var};\n #{body} \n#{rt_ref}.checkYield();\n}\n}"
      else
        "{\nvar #{iter_var}: i64 = #{start_val};\nwhile (#{iter_var} #{cmp} #{end_val}) : (#{iter_var} += 1) {\nconst #{var}: i64 = #{iter_var}; _ = &#{var};\n #{body} \n}\n}"
      end

    when AST::WhileLoop
      cond   = visit(node.condition)
      body   = transpile_block(node.do_branch)
      rt_ref = @do_rt_name || "rt"

      if node.tight
        # TIGHT: no yield injection, no arena loop marks — pure computation path.
        "while (#{cond}) {\n #{body} \n}"
      elsif node.mark_per_iter && current_tp_ctx&.has_rt
        # Loop-local frame allocs: unwind arena each iteration AND yield at back-edge.
        mark_id  = (@loop_mark_counter = (@loop_mark_counter || 0) + 1)
        mark_var = "__loop_mark_#{mark_id}"
        "while (#{cond}) {\nconst #{mark_var} = #{rt_ref}.saveLoopMark(); defer #{rt_ref}.restoreLoopMark(#{mark_var});\n #{body} \n#{rt_ref}.checkYield();\n}"
      elsif current_tp_ctx&.has_rt
        # Normal loop: inject cooperative yield at back-edge.
        "while (#{cond}) {\n #{body} \n#{rt_ref}.checkYield();\n}"
      else
        # No rt in scope (e.g. static initializer or extern context): no yield possible.
        "while (#{cond}) {\n #{body} \n}"
      end

    when AST::WithBlock
      rc_caps          = node.capabilities.select { |c| [:multiowned, :shared].include?(c[:capability]) }
      mutex_caps       = node.capabilities.select { |c| c[:capability] == :EXCLUSIVE && c[:resolved_type]&.locked? }
      rw_write_caps    = node.capabilities.select { |c| c[:capability] == :EXCLUSIVE && c[:resolved_type]&.write_locked? }
      rw_read_caps     = node.capabilities.select { |c| c[:capability] == :write_locked_read }

      # --- Rc/Arc (multiowned/shared) bindings ---
      rc_bindings = rc_caps.map do |cap|
        name = cap[:var_node].name
        inner = "__#{name}_unwrap"
        "const #{inner} = #{name}.ctrl.data.*;\n_ = &#{inner};"
      end.join("\n")

      # --- Mutex bindings: acquire(), bind alias as *T ---
      # When the variable also has an ownership wrapper (Arc/Rc), the Zig variable is
      # Arc(Locked(T)) or Rc(Locked(T)); dereference through .data.* to reach Locked(T).
      mutex_bindings = mutex_caps.map do |cap|
        var_name   = cap[:var_node].name
        alias_name = cap[:alias] || var_name
        guard_var  = "__#{var_name}_guard"
        zig_var    = @do_capture_map&.dig(var_name) || var_name
        lock_expr  = cap[:resolved_type]&.any_rc? ? "#{zig_var}.ctrl.data.*" : zig_var
        <<~ZIG.chomp
          var #{guard_var} = #{lock_expr}.acquire();
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
        zig_var    = @do_capture_map&.dig(var_name) || var_name
        lock_expr  = cap[:resolved_type]&.any_rc? ? "#{zig_var}.ctrl.data.*" : zig_var
        <<~ZIG.chomp
          var #{guard_var} = #{lock_expr}.write();
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
        zig_var    = @do_capture_map&.dig(var_name) || var_name
        lock_expr  = cap[:resolved_type]&.any_rc? ? "#{zig_var}.ctrl.data.*" : zig_var
        <<~ZIG.chomp
          var #{guard_var} = #{lock_expr}.read();
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

      branch_parts = node.branches.each_with_index.map do |branch, i|
        branch_exprs = branch[:body]
        pinned       = branch[:pinned]
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
        body_code = with_fiber_capture_map(captured.map { |name, _| [name, "ctx.#{name}.*"] }.to_h) do
          branch_exprs.map { |e|
            code = visit(e)
            code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
            code
          }.join("\n        ")
        end

        # Default: spawnBest distributes across all schedulers (work-stealing).
        # @pinned: pin to the current thread's scheduler via submitSpawn.
        task_cfg = task_config_zig(branch[:stack_size])
        spawn_call = if pinned
          <<~ZIG.chomp
            try #{wg_var}.sched.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
                &#{ctx_var},
                #{task_cfg}
            );
          ZIG
        else
          <<~ZIG.chomp
            try CheatHeader.spawnBest(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
                &#{ctx_var},
                #{task_cfg}
            );
          ZIG
        end

        <<~ZIG.chomp
          const #{ctx_type} = struct {
              wg: *CheatHeader.WaitGroup,
              #{capture_fields}
              fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                  const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                  #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                  const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                  defer ctx.wg.done();
                  #{body_code}
              }
          };
          var #{ctx_var} = #{ctx_type}{ #{capture_inits} };
          #{spawn_call}
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
        t = type_obj ? Type.new(type_obj) : nil
        zig_t = t ? t.zig_type : "anyopaque"
        # All maps must be captured by pointer (shared mutable state).
        if t && t.needs_pointer_passing?
          "#{name}: *#{zig_t},"
        else
          "#{name}: #{zig_t},"
        end
      end.join("\n        ")

      # Escape promotions: frame-allocated data captured by BG fibers must be
      # promoted to heap before the fiber spawns. Uses the same escape system
      # as return values — needs_escape_promotion? / escape_promote_code.
      # Strings produce a new binding (dupe returns new slice); collections
      # are promoted in-place (promoteList/mapPromote mutate the original).
      escape_promotions, promoted_names = emit_capture_escape_promotions(
        captured, "#{alloc_var}", rt_name, "__bgp_#{id}"
      )

      capture_inits = ([".inner = #{promise_var}.inner", ".alloc = #{alloc_var}"] +
        captured.map do |name, type_obj|
          t = type_obj ? Type.new(type_obj) : nil
          if t && t.needs_pointer_passing?
            ".#{name} = &#{name}"
          elsif promoted_names[name]
            ".#{name} = #{promoted_names[name]}"
          else
            ".#{name} = #{name}"
          end
        end).join(", ")

      # Resources captured by BG fibers transfer ownership — suppress outer defer close.
      # Without this, the outer scope's `defer socketClose(fd)` fires immediately,
      # closing the fd before the fiber reads it.
      capture_close_zig = @_capture_close_zig || {}
      resource_moves = captured.filter_map do |name, type_obj|
        t = type_obj.is_a?(Type) ? type_obj : nil
        "#{name}_moved = true;" if t&.resource? || capture_close_zig[name]
      end.join("\n")

      rt_name = @do_rt_name || "rt"

      # Flatten ThenChain nodes in the body into individual steps.
      # Each flat step is { expr: ASTNode, binding: String|nil }.
      # Non-ThenChain body nodes become steps with binding=nil.
      flat_steps = []
      node.body.each do |stmt|
        if stmt.is_a?(AST::ThenChain)
          stmt.steps.each { |s| flat_steps << s }
        else
          flat_steps << { expr: stmt, binding: nil }
        end
      end

      last_step  = flat_steps.pop
      pre_steps  = flat_steps

      stmt_code, result_line = with_fiber_capture_map(captured.map { |name, _| [name, "ctx.#{name}"] }.to_h) do
        stmts = pre_steps.map { |step|
          code = visit(step[:expr])
          if step[:binding]
            # Binding: emit as a const declaration for use in subsequent steps
            "const #{step[:binding]} = #{code};"
          else
            # No binding: emit as a statement.
            # If the code is already a complete statement (ends with ; or }), emit as-is.
            # Otherwise, discard non-void results with _ = to satisfy Zig.
            if code.strip.end_with?(";") || code.strip.end_with?("}")
              code
            else
              expr_type = step[:expr].respond_to?(:full_type) ? step[:expr].full_type : :Void
              is_void_step = expr_type.nil? || expr_type == :Void ||
                             (expr_type.respond_to?(:to_s) && Type.new(expr_type).zig_type == "void")
              is_void_step ? "#{code};" : "_ = #{code};"
            end
          end
        }.join("\n            ")
        # Field/index assignments are statements (void in Zig) — never set inner.result.
        last_is_assign = last_step && last_step[:expr].is_a?(AST::Assignment)
        result = if last_step.nil? || is_void || last_is_assign
          if last_step
            last_code = visit(last_step[:expr])
            # Block statements already end with } or ;; don't double-terminate.
            (last_code.strip.end_with?("}") || last_code.strip.end_with?(";")) ? last_code : "#{last_code};"
          else
            ""
          end
        else
          # BG result: store the error union directly (no try unwrap).
          # If the expression errors, the error is captured in inner.result
          # and propagated to the caller on NEXT.
          result_code = visit(last_step[:expr])
          # Strip leading 'try ' so the error union flows through to inner.result.
          # The inner.result type is anyerror!T, matching the callee's return type.
          result_code = result_code.sub(/\Atry /, '') if result_code.start_with?("try ")
          "ctx.inner.result = #{result_code};"
        end
        [stmts, result]
      end

      arena_init = node.arena_mode ? "__rt.arena_mode = true;" : ""

      # Defer-free for promoted captures inside the fiber.
      # Strings need explicit free (duped to heap); collections are freed
      # via their own deinit in the fiber's normal cleanup path.
      # Resources use the schema-driven close_zig pattern from the symbol entry.
      capture_close_zig = @_capture_close_zig || {}
      capture_frees = captured.filter_map do |name, type_obj|
        t = type_obj.is_a?(Type) ? type_obj : (type_obj ? Type.new(type_obj) : nil)
        if t&.string?
          "defer ctx.alloc.free(ctx.#{name});"
        elsif capture_close_zig[name]
          # Resource: use the close_zig pattern from the type schema.
          # {0} is replaced with the context field access.
          "defer #{capture_close_zig[name].gsub('{0}', "ctx.#{name}")};"
        end
      end.compact.join("\n                    ")

      <<~ZIG.chomp
        #{blk_label}: {
            const #{ctx_type} = struct {
                inner: *#{promise_zig}.Inner,
                alloc: std.mem.Allocator,
                #{capture_fields}
                fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                    const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                    #{(stmt_code + result_line + capture_frees + arena_init).include?("__rt") ? "" : "_ = &__rt;"}
                    #{arena_init}
                    const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                    defer ctx.alloc.destroy(ctx);
                    defer ctx.inner.wg.done();
                    errdefer |fiber_err| ctx.inner.result = fiber_err;
                    #{capture_frees}
                    #{stmt_code}
                    #{result_line}
                    #{is_void ? "ctx.inner.result = {};" : ""}
                }
            };
            const #{alloc_var} = #{rt_name}.getSched().allocator;
            const #{promise_var} = try #{promise_zig}.spawn(#{alloc_var}, #{rt_name}.getSched());
            #{escape_promotions.join("\n            ")}
            const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
            #{ctx_var}.* = .{ #{capture_inits} };
            #{resource_moves}
            #{bg_spawn_call(node, rt_name, ctx_type, ctx_var)}
            break :#{blk_label} #{promise_var};
        }
      ZIG

    when AST::BgStreamBlock
      @stream_gen_counter ||= 0
      id = @stream_gen_counter
      @stream_gen_counter += 1

      tense_t    = Type.new(node.full_type || :"~Void[?]")
      is_inf     = tense_t.inf_stream?
      stream_zig = tense_t.zig_type  # "CheatLib.Stream(T)" or "CheatLib.InfStream(T)"

      ctx_type     = "__SgCtx#{id}"
      alloc_var    = "__sg#{id}_alloc"
      stream_var   = "__sg#{id}_stream"
      ctx_var      = "__sg#{id}_ctx"
      blk_label    = "__sg#{id}"
      local_stream = "__sg#{id}_local"

      captured = collect_do_identifiers(node.body)

      capture_fields = captured.map do |name, type_obj|
        zig_t = type_obj ? Type.new(type_obj).zig_type : "anyopaque"
        "#{name}: #{zig_t},"
      end.join("\n        ")

      capture_inits = ([".stream_inner = #{stream_var}.inner", ".alloc = #{alloc_var}"] +
        captured.map { |name, _| ".#{name} = #{name}" }).join(", ")

      rt_name = @do_rt_name || "rt"

      capture_map = captured.map { |name, _| [name, "ctx.#{name}"] }.to_h

      # Set @current_stream_local so that YieldExpr nodes at ANY nesting depth
      # (inside while loops, if statements, etc.) emit the correct push() call.
      # @current_stream_is_inf distinguishes InfStream (push returns void) from
      # Stream (push returns !void) so YIELD knows whether to emit `try`.
      prev_stream_local = @current_stream_local
      prev_stream_is_inf = @current_stream_is_inf
      @current_stream_local = local_stream
      @current_stream_is_inf = is_inf
      body_code = with_fiber_capture_map(capture_map) do
        node.body.map do |expr|
          code = visit(expr)
          code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
          code
        end.join("\n            ")
      end
      @current_stream_local = prev_stream_local
      @current_stream_is_inf = prev_stream_is_inf

      <<~ZIG.chomp
        #{blk_label}: {
            const #{ctx_type} = struct {
                stream_inner: *#{stream_zig}.Inner,
                alloc: std.mem.Allocator,
                #{capture_fields}
                fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                    const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                    #{body_code.include?("__rt") ? "" : "_ = &__rt;"}
                    const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
                    defer ctx.alloc.destroy(ctx);
                    #{is_inf ? "defer ctx.alloc.destroy(ctx.stream_inner);" : ""}
                    var #{local_stream} = #{stream_zig}{ .inner = ctx.stream_inner, .alloc = ctx.alloc };
                    defer #{local_stream}.close();
                    errdefer |gen_err| #{local_stream}.inner.err = gen_err;
                    #{body_code}
                }
            };
            const #{alloc_var} = #{rt_name}.getSched().allocator;
            const #{stream_var} = try #{stream_zig}.spawnNew(#{alloc_var}, #{rt_name}.getSched());
            const #{ctx_var} = try #{alloc_var}.create(#{ctx_type});
            #{ctx_var}.* = .{ #{capture_inits} };
            try #{rt_name}.getSched().submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
                #{ctx_var},
                #{task_config_zig(node.stack_size)},
            );
            break :#{blk_label} #{stream_var};
        }
      ZIG

    when AST::YieldExpr
      # Emits push() on the current generator's local stream handle.
      # Both Stream.push and InfStream.push return !void → always use try.
      # (InfStream.push returns error.StreamClosed when the consumer calls deinit.)
      "try #{@current_stream_local}.push(#{visit(node.expr)})"

    when AST::NextExpr
      # All fiber types (Promise, SharedPromise, Stream, InfStream) now return
      # anyerror!T from next() — errors propagate from fiber to caller.
      "try #{visit(node.expr)}.next()"

    when AST::StaticCall
      pattern  = node.zig_pattern
      arg_strs = node.args.map { |a| visit(a) }
      result   = pattern.dup
      arg_strs.each_with_index { |arg, i| result = result.gsub("{#{i}}", arg) }
      result

    when AST::FuncCall, AST::MethodCall
      # EXTERN method dispatch: obj.method() → direct method call (no UFCS, no module prefix)
      if node.is_a?(AST::MethodCall) && node.instance_variable_get(:@extern_method)
        obj_code = visit(node.object)
        args_code = node.args.map { |a| visit(a) }.join(", ")
        call = args_code.empty? ? "#{obj_code}.#{node.name}()" : "#{obj_code}.#{node.name}(#{args_code})"
        return call
      end

      # Pool method dispatch: pool.insert/get/remove bypass UFCS
      if node.is_a?(AST::MethodCall) && node.pool_method
        return transpile_pool_method(node)
      end

      # Set method dispatch: set.insert/contains/remove/count bypass UFCS
      if node.is_a?(AST::MethodCall) && node.set_method
        return transpile_set_method(node)
      end

      # HashMap method dispatch: map.delete/contains/count/keys/values bypass UFCS
      if node.is_a?(AST::MethodCall) && node.map_method
        return transpile_map_method(node)
      end

      return transpile_Intrinsic(node) if !node.zig_pattern.nil?

      # Standard call (pass rt)
      # Note: We don't add 'try' here - let the caller decide via OR RAISE or context
      args_zig = node.args.map do |a|
        arg_code = visit(a)
        # Struct args: no .* deref needed — functions use `anytype` params which Zig
        # monomorphizes for both T and *T with transparent field access.
        # Array/List args: convert to slice via .items for function params.
        if a.type_info&.is_a?(Type) && Type.new(a.type_info).needs_pointer_passing?
          # Map/Pool params use anytype — pass by pointer so the callee can mutate.
          # BG captures already store as *MapType, so don't double-wrap.
          # Function params that are already pointers (anytype) skip the &.
          is_capture = @do_capture_map&.key?(a.is_a?(AST::Identifier) ? a.name : nil)
          is_collection_param = a.is_a?(AST::Identifier) && current_tp_ctx&.collection_params&.include?(a.name)
          (is_capture || is_collection_param) ? arg_code : "&#{arg_code}"
        elsif a.type_info&.array?
          "(if (@hasField(@TypeOf(#{arg_code}), \"items\")) #{arg_code}.items else #{arg_code})"
        else
          arg_code
        end
      end
      mod_prefix = (node.respond_to?(:module_alias) && node.module_alias) ? "#{node.module_alias.gsub('.', '_')}." : ""

      if node.respond_to?(:extern_call) && node.extern_call
        # Native FFI call: trampoline to g0 stack via onRootStack.
        rt_name = @do_rt_name || "rt"
        @extern_trampoline_counter = (@extern_trampoline_counter || 0) + 1
        tid = @extern_trampoline_counter

        effects = node.extern_effects || Set.new
        alloc_kind = effects.is_a?(Hash) ? effects[:alloc] : (effects.include?(:alloc) ? :frame : nil)
        has_alloc = !!alloc_kind
        ret_type = node.full_type
        ret_type_obj = ret_type.is_a?(Type) ? ret_type : Type.new(ret_type || :Void)
        is_error_union = ret_type_obj.error_union?
        inner_zig = is_error_union ? ret_type_obj.payload_type.zig_type : ret_type_obj.zig_type
        is_void = (inner_zig == "void")

        # Separate comptime (type) args and default-struct args from runtime args.
        # Comptime args go directly into the native call as type names.
        # Default-struct args (empty local EXTERN STRUCT literals) go as .{}.
        # Runtime args go through the trampoline struct.
        @local_extern_structs ||= Set.new
        comptime_type_args = node.respond_to?(:generic_type_args) ? (node.generic_type_args || []) : []
        runtime_indices = []
        default_struct_indices = Set.new
        args_zig.each_with_index do |_, i|
          arg = node.args[i]
          arg_name = arg.is_a?(AST::Identifier) ? arg.name.to_sym : nil
          is_comptime = arg_name && comptime_type_args.include?(arg_name)
          is_default_struct = arg.is_a?(AST::StructLit) && arg.fields.empty? && @local_extern_structs.include?(arg.name)
          if is_comptime || is_default_struct
            default_struct_indices << i if is_default_struct
          else
            runtime_indices << i
          end
        end

        # Build native call args in declaration order
        native_args = []
        field_idx = 0
        args_zig.each_with_index do |_, i|
          arg = node.args[i]
          arg_name = arg.is_a?(AST::Identifier) ? arg.name.to_sym : nil
          if arg_name && comptime_type_args.include?(arg_name)
            # Comptime type arg — emit as bare type name
            native_args << Type.new(node.args[i].name.to_sym).zig_type
          elsif default_struct_indices.include?(i)
            # Empty local extern struct — pass .{} directly (Zig infers the type)
            native_args << ".{}"
          elsif has_alloc && native_args.empty? && !comptime_type_args.any? { |t| native_args.include?(Type.new(t).zig_type) }
            # This shouldn't happen in the normal flow; alloc is injected separately
            native_args << "f.a#{field_idx}"
            field_idx += 1
          else
            native_args << "f.a#{field_idx}"
            field_idx += 1
          end
        end
        # Inject allocator at the right position (after comptime args, before runtime args)
        if has_alloc
          insert_pos = comptime_type_args.length
          native_args.insert(insert_pos, "f.alloc")
        end
        native_call = "#{mod_prefix}#{node.name}(#{native_args.join(', ')})"
        native_call = "(#{native_call} catch |err| { f.err = err; return; })" if is_error_union

        # Build trampoline struct fields — only runtime args (skip comptime)
        runtime_args_zig = runtime_indices.map { |i| args_zig[i] }
        arg_fields = runtime_indices.each_with_index.map { |orig_i, field_i|
          arg_type = node.args[orig_i]&.type_info
          zig_t = arg_type.is_a?(Type) ? arg_type.zig_type : (arg_type ? Type.new(arg_type).zig_type : "@TypeOf(__ext#{tid}_args[#{field_i}])")
          "a#{field_i}: #{zig_t}"
        }.join(", ")
        alloc_field = has_alloc ? "alloc: std.mem.Allocator, " : ""
        arg_tuple = runtime_args_zig.empty? ? ".{}" : ".{ #{runtime_args_zig.join(', ')} }"

        alloc_zig = case alloc_kind
                    when :frame then "#{rt_name}.frameAlloc()"
                    when :heap  then "#{rt_name}.heapAlloc()"
                    else nil
                    end
        alloc_init = has_alloc ? ", .alloc = #{alloc_zig}" : ""
        err_field = is_error_union ? "err: ?anyerror = null, " : ""
        err_check = is_error_union ? "if (__ext#{tid}_frame.err) |e| return e; " : ""

        field_inits = runtime_indices.each_with_index.map { |_, fi| ".a#{fi} = __ext#{tid}_args[#{fi}]" }.join(', ')
        if is_void && !is_error_union
          "{ const __ext#{tid}_args = #{arg_tuple}; " \
          "const __Ext#{tid} = struct { #{alloc_field}#{arg_fields}, " \
          "fn run(ptr: ?*anyopaque) callconv(.c) void { " \
          "const f: *@This() = @ptrCast(@alignCast(ptr)); " \
          "_ = #{native_call}; } }; " \
          "var __ext#{tid}_frame = __Ext#{tid}{ #{field_inits}#{alloc_init} }; " \
          "#{trampoline_call(tid, rt_name, node)}; }"
        else
          "blk_ext#{tid}: { const __ext#{tid}_args = #{arg_tuple}; " \
          "const __Ext#{tid} = struct { #{alloc_field}#{arg_fields}, #{err_field}ret: #{inner_zig} = undefined, " \
          "fn run(ptr: ?*anyopaque) callconv(.c) void { " \
          "const f: *@This() = @ptrCast(@alignCast(ptr)); " \
          "f.ret = #{native_call}; } }; " \
          "var __ext#{tid}_frame = __Ext#{tid}{ #{field_inits}#{alloc_init} }; " \
          "#{trampoline_call(tid, rt_name, node)}; " \
          "#{err_check}break :blk_ext#{tid} __ext#{tid}_frame.ret; }"
        end
      elsif node.respond_to?(:fn_var_call) && node.fn_var_call
        # Calling a fn-type variable: always inject rt, always try (unknown callee)
        rt_name = @do_rt_name || "rt"
        args = [rt_name] + args_zig
        "try #{node.name}(#{args.join(', ')})"
      else
        rt_name = @do_rt_name || "rt"
        # For generic function calls, inject inferred comptime type args after rt
        type_arg_strs = if node.respond_to?(:generic_type_args) && node.generic_type_args&.any?
          node.generic_type_args.map { |t| Type.new(t).zig_type }
        else
          []
        end
        # STUB interception: if this function is stubbed, emit stub value instead of real call.
        stub_info = (@active_stubs || {})[node.name]
        if stub_info
          stub_code = case stub_info[:kind]
          when :returns
            stub_info[:var]
          when :captures
            "{ #{stub_info[:var]} += 1; }"
          when :sequence
            "blk_stub: { const __si = #{stub_info[:var]}_idx; #{stub_info[:var]}_idx += 1; break :blk_stub #{stub_info[:var]}_seq[__si]; }"
          when :with
            "#{stub_info[:var]}(#{args_zig.join(', ')})"
          end
          return stub_code
        end

        # Only inject rt / emit try if the callee actually needs them.
        needs_rt = callee_needs_rt?(node.name)
        can_fail  = callee_can_fail?(node.name)
        # UFCS: inject the object as the first argument for method calls
        ufcs_args = if node.is_a?(AST::MethodCall) && node.respond_to?(:object)
          obj_code = visit(node.object)
          [obj_code]
        else
          []
        end
        args = type_arg_strs + (needs_rt ? [rt_name] : []) + ufcs_args + args_zig
        fn_zig = "#{mod_prefix}#{zig_safe_name(node.name)}"

        is_tail_self_call = @current_tail_call_fn == node.name
        llvm_backend = !(@default_stack_size == "Large")
        if is_tail_self_call && llvm_backend
          call = "@call(.always_tail, #{fn_zig}, .{#{args.join(', ')}})"
          call
        else
          call = "#{fn_zig}(#{args.join(', ')})"
          can_fail ? "try #{call}" : call
        end
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
        is_resource = ti&.resource?
        if is_resource
          safe_name = zig_safe_name(node.value.name)
          return "#{safe_name}_moved = true;\nreturn #{safe_name};"
        end
        if ti&.any_rc?
          return "return #{transpile_rc_retain(ti, node.value.name)};"
        end
      end

      # 2. Standard Return with Move Suppression for unique heap
      rt_name = @do_rt_name || "rt"
      suppress = emit_move_suppression(node.value)

      # Suppress cleanup on TAKES parameters whose data is returned inside
      # struct/union construction (ownership escapes via the return value).
      if node.value.is_a?(AST::StructLit)
        fn_name = current_tp_ctx&.fn_name
        fn_plan = @cleanup_plans&.dig(fn_name)
        node.value.fields.each do |_fname, fval|
          next unless fval.is_a?(AST::Identifier)
          entry = fn_plan&.lookup(fval.name)
          next unless entry && entry[:source_kind] == :takes_param && entry[:has_moved_guard]
          suppress = "#{zig_safe_name(fval.name)}_moved = true;\n#{suppress}"
        end
      end
      val_code = if node.value.nil?
        ""
      elsif node.value.is_a?(AST::Identifier) && node.value.type_info&.frame? && node.value.type_info&.struct?
        "#{visit(node.value)}.*"
      else
        visit(node.value)
      end

      # 3. Escape promotion — driven by PromotionPlan (Pass C).
      plan = @promotion_plans&.dig(current_tp_ctx&.fn_name)
      # Functions with CATCH + returns_promoted must dupe string returns on ALL
      # paths (success + catch) so the caller can uniformly free with heapAlloc.
      needs_string_dupe = @catch_dupe_string_returns || @current_fn_has_catch
      if plan && !plan.empty?
        filtered = plan.filter_for_return(node.value)
        emit_return_from_plan(val_code, filtered, rt_name, suppress)
      elsif needs_string_dupe && node.value
        ret_type = node.value.respond_to?(:full_type) ? Type.new(node.value.full_type) : nil
        if ret_type&.string?
          [suppress, "return #{rt_name}.heapAlloc().dupe(u8, #{val_code}) catch #{val_code};"].reject(&:empty?).join("\n")
        else
          [suppress, "return #{val_code};"].reject(&:empty?).join("\n")
        end
      else
        [suppress, "return #{val_code};"].reject(&:empty?).join("\n")
      end

    when AST::GetField
      # Union unit-variant constructor: Result{ .Empty = {} }
      # Inline struct variants never reach here — the annotator requires UnionVariantLit for those.
      if node.target.is_a?(AST::Identifier)
        schema = @union_schemas&.dig(node.target.name.to_sym)
        if schema
          var_data = schema[node.field]
          # Only emit unit-variant construction; inline struct variants require UnionVariantLit.
          return "#{node.target.name}{ .#{node.field} = {} }" unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
        end
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
        # Rc(T)/Arc(T) store the value as .ctrl.data (*T); Zig auto-derefs through the pointer
        "#{target_code}.ctrl.data.#{node.field}"
      elsif (ti&.locked? || ti&.write_locked?) && !is_locked_unwrapped
        # *Locked(T) / *RwLocked(T): auto-deref pointer, then access .ctrl.data field
        "#{target_code}.ctrl.data.#{node.field}"
      elsif ti&.always_mutable? && !is_locked_unwrapped
        # RefCell(T): access through .data field
        "#{target_code}.data.#{node.field}"
      elsif @soa_rewrite_active && node.target.is_a?(AST::Identifier) && node.target.name == "_"
        # SOA field-slice rewrite: _.field → __soa_field[__soa_i]
        @soa_needed_fields << node.field
        "__soa_#{node.field}[__soa_i]"
      else
        code = "#{target_code}.#{node.field}"
        # Auto-dereference @indirect fields on union variant structs
        target_type = ti&.resolved.to_s
        if @indirect_fields&.dig("#{target_type}.#{node.field}")
          code = "#{code}.*"
        end
        code
      end

    when AST::CapabilityWrap
      inner_code = visit(node.value)
      base_type  = node.value.resolved_type.to_s
      zig_base   = transpile_type(base_type)

      # Build from the inside out: sync layer first, then ownership layer.
      # This handles all 9 legal (ownership × sync) combinations generically.
      sync_fn   = case node.sync
                  when :locked         then "lockedCreate"
                  when :write_locked   then "rwLockedCreate"
                  when :always_mutable then "refCellCreate"
                  end
      sync_type = case node.sync
                  when :locked         then "CheatLib.Locked(#{zig_base})"
                  when :write_locked   then "CheatLib.RwLocked(#{zig_base})"
                  when :always_mutable then "CheatLib.RefCell(#{zig_base})"
                  end
      own_fn    = case node.ownership
                  when :shared     then "arcCreate"
                  when :multiowned then "rcCreate"
                  end

      if node.sync == :local || (node.layout == :indirect && !node.sync && !node.ownership)
        # @local or bare @indirect: heap pointer, no Mutex/RwLock wrapper.
        "try CheatLib.localCreate(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif sync_fn && own_fn
        # Two-layer: sync wraps T, ownership wraps the sync type.
        <<~ZIG.chomp
          blk_cap: {
              const __cap_inner = try CheatLib.#{sync_fn}(#{zig_base}, rt.heapAlloc(), #{inner_code});
              break :blk_cap try CheatLib.#{own_fn}(#{sync_type}, rt.heapAlloc(), __cap_inner);
          }
        ZIG
      elsif sync_fn
        "try CheatLib.#{sync_fn}(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      elsif own_fn
        "try CheatLib.#{own_fn}(#{zig_base}, rt.heapAlloc(), #{inner_code})"
      else
        inner_code
      end

    when AST::CopyNode
      # COPY expr — explicit deep-copy. Produces an owned value.
      val = visit(node.value)
      ti = node.value.type_info
      rt_name = @do_rt_name || "rt"
      if ti && @union_schemas&.key?(ti.resolved)
        zig_t = transpile_type(ti)
        "try CheatLib.dupeUnionValue(#{zig_t}, #{val}, #{rt_name}.heapAlloc())"
      elsif ti&.string?
        "try #{rt_name}.heapAlloc().dupe(u8, #{val})"
      elsif ti&.array? && !ti&.string?
        elem_zig = transpile_type(ti.element_type)
        "blk_copy: {\n    const __src = #{val};\n    if (__src.len > 0) {\n        const __buf = try #{rt_name}.heapAlloc().alloc(#{elem_zig}, __src.len);\n        @memcpy(__buf, __src);\n        break :blk_copy __buf;\n    } else break :blk_copy __src;\n}"
      else
        val
      end

    when AST::LinkNode
      # LINK expr — downgrade Rc/Arc to WeakRc/WeakArc
      inner = visit(node.value)
      ti = node.value.type_info
      base = transpile_type(ti.resolved.to_s)
      func = ti.shared? ? "arcDowngrade" : "rcDowngrade"
      "CheatLib.#{func}(#{base}, #{inner})"

    when AST::ResolveNode
      # RESOLVE expr — upgrade WeakRc/WeakArc to ?Rc/?Arc
      inner = visit(node.value)
      ti = node.value.type_info
      base = transpile_type(ti.resolved.to_s)
      source = ti.link_source || :multiowned
      func = source == :shared ? "weakArcUpgrade" : "weakRcUpgrade"
      "CheatLib.#{func}(#{base}, #{inner})"

    when AST::MoveNode
      # MOVE expr — if it's an identifier, set the moved flag and return the value.
      # This ensures GIVE f; as a statement correctly suppresses the local defer.
      if node.value.is_a?(AST::Identifier)
        safe_name = zig_safe_name(node.value.name)
        "blk: { #{safe_name}_moved = true; break :blk #{safe_name}; }"
      else
        # GIVE expr (non-identifier): ownership transfers to callee.
        saved = current_tp_ctx&.inside_give
        current_tp_ctx.inside_give = true if current_tp_ctx
        result = visit(node.value)
        current_tp_ctx.inside_give = saved if current_tp_ctx
        result
      end

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

      # Named function used as a value: emit a function pointer
      return "&#{zig_safe_name(node.name)}" if node.respond_to?(:fn_ref) && node.fn_ref

      # Inside a WITH block, use the unwrapped inner alias instead of the Rc handle
      rc_map = @rc_unwrap_map || {}
      return rc_map[node.name] if rc_map.key?(node.name)

      # Inside a DO block branch, access captured outer variables via ctx pointer
      capture_map = @do_capture_map || {}
      return capture_map[node.name] if capture_map.key?(node.name)

      zig_safe_name(node.name)

    when AST::Literal
      case node.type
      when :STRING
        escaped = node.value.bytes.map { |b|
          case b
          when 0x5C then '\\\\'  # backslash
          when 0x22 then '\\"'   # double quote
          when 0x0A then '\\n'   # newline
          when 0x0D then '\\r'   # carriage return
          when 0x09 then '\\t'   # tab
          when 0x00 then '\\x00' # null
          else b.chr
          end
        }.join
        "\"#{escaped}\""
      when :NUMBER
        # NUMBER literals are Float64 in CLEAR. Emit as Zig comptime int
        # when coerced to Int64, otherwise preserve float form to avoid
        # integer division bugs (1/t must be float division, not int).
        if node.coerced_type == :Int64
          node.value.to_i.to_s
        else
          s = node.value.to_s
          s = "#{s}.0" if node.value == node.value.to_i && !s.include?('.')
          s
        end
      when :INT64
        node.value.to_s
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
        # Annotator ensures full_type is set (e.g. "String" or "%String")
        rt_ref = @do_rt_name || "rt"
        alloc = node.storage == :heap ? "#{rt_ref}.heapAlloc()" : "#{rt_ref}.frameAlloc()"

        if node.left.type_info&.string? || node.right.type_info&.string?
          # Generate call to runtime helper
          # We use heapAlloc to ensure the result survives (safe default)
          return "try std.mem.concat(#{alloc}, u8, &.{ #{left}, #{right} })"
        end
      end

      if node.op == :POW
        left_type = node.left.full_type
        resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
        if resolved == :Int64
          return "std.math.pow(i64, #{left}, #{right})"
        else
          return "std.math.pow(f64, #{left}, #{right})"
        end
      end

      if node.op == :MOD
        # Zig's `%` only works on unsigned integers; signed i64 requires @mod.
        # Number (f64) can still use `%` directly.
        left_type = node.left.full_type
        resolved = left_type.is_a?(Type) ? left_type.resolved : Type.new(left_type.to_s).resolved
        if resolved == :Int64
          return "@mod(#{left}, #{right})"
        end
      end

      # String comparison: Zig can't use native operators on slices.
      if Type.new(node.left.full_type).string? || Type.new(node.right.full_type).string?
        case node.op
        when :EQ  then return "CheatLib.eql(#{left}, #{right})"
        when :NEQ then return "!CheatLib.eql(#{left}, #{right})"
        when :LT  then return "(CheatLib.strcmp(#{left}, #{right}) < 0)"
        when :LTE then return "(CheatLib.strcmp(#{left}, #{right}) <= 0)"
        when :GT  then return "(CheatLib.strcmp(#{left}, #{right}) > 0)"
        when :GTE then return "(CheatLib.strcmp(#{left}, #{right}) >= 0)"
        end
      end

      if node.op == :DIV
        left_ti = node.left.type_info
        right_ti = node.right.type_info
        if left_ti&.integer? && right_ti&.integer?
          return "@divTrunc(#{left}, #{right})"
        end
      end

      # Explicit wrapping operators (%+, %-, %*)
      if %i[WRAP_ADD WRAP_SUB WRAP_MUL].include?(node.op)
        fn_name = { WRAP_ADD: "wrapAdd", WRAP_SUB: "wrapSub", WRAP_MUL: "wrapMul" }[node.op]
        return "CheatLib.#{fn_name}(#{left}, #{right})"
      end

      # Explicit checked operators (!+, !-, !*)
      if %i[CHECK_ADD CHECK_SUB CHECK_MUL].include?(node.op)
        fn_name = { CHECK_ADD: "checkAdd", CHECK_SUB: "checkSub", CHECK_MUL: "checkMul" }[node.op]
        return "CheatLib.#{fn_name}(#{left}, #{right})"
      end

      # Default integer arithmetic: checked in debug, wrapping in release.
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
          fn_name = { ADD: "intAdd", SUB: "intSub", MUL: "intMul" }[node.op]
          return "CheatLib.#{fn_name}(#{left}, #{right})"
        end
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

    when AST::TestBlock
      transpile_test_block(node)

    when AST::AssertRaises
      transpile_assert_raises(node)

    when AST::BenchmarkStmt
      transpile_benchmark(node)

    when AST::SmashStmt
      transpile_smash(node)

    when AST::ProfileStmt
      transpile_profile(node)

    when AST::StubDecl
      transpile_stub(node)

    when AST::Raise
      # RAISE Kind, ErrorName, "message"
      rt_name = @do_rt_name || "rt"
      kind = node.kind || :System
      error_name = node.error_name || ""
      msg_code = node.message_expr ? visit(node.message_expr) : "\"\""
      if @current_fn_has_rt
        "#{rt_name}.setError(.#{kind}, \"#{error_name}\", #{msg_code}, #{node.token.line});\nreturn error.CheatError"
      else
        "return error.CheatError"
      end

    when AST::BreakNode
      "break"

    when AST::ContinueNode
      "continue"

    # Marker nodes for OR RAISE / OR PASS / OR PRUNE - handled in transpile_OrRescue
    when AST::OrRaise
      "error.OrRaise"  # Should not be visited directly
    when AST::OrBreak
      "break"  # Should not be visited directly
    when AST::OrPass
      "undefined"  # Should not be visited directly
    when AST::OrPrune
      "undefined"  # Should not be visited directly — handled in concurrent pipeline

    when AST::ThenChain
      raise "Internal: ThenChain node reached visit() — should be flattened by BgBlock transpiler"

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

    elsif node.right.is_a?(AST::EachOp)
      return transpile_each(node)

    elsif node.right.is_a?(AST::FindOp)
      return transpile_find(node.left, node.right, node)

    elsif node.right.is_a?(AST::AnyOp)
      return transpile_any(node.left, node.right, node)

    elsif node.right.is_a?(AST::AllOp)
      return transpile_all(node.left, node.right, node)

    elsif node.right.is_a?(AST::CountOp)
      return transpile_count(node.left, node.right, node)

    elsif node.right.is_a?(AST::SumOp)
      return transpile_sum(node.left, node.right, node)

    elsif node.right.is_a?(AST::AverageOp)
      return transpile_average(node.left, node.right, node)

    elsif node.right.is_a?(AST::MinOp)
      return transpile_min(node.left, node.right, node)

    elsif node.right.is_a?(AST::MaxOp)
      return transpile_max(node.left, node.right, node)

    elsif node.right.is_a?(AST::ShardOp)
      # SHARD is consumed by the subsequent CONCURRENT EACH — not visited standalone.
      # The ConcurrentOp handler reads the ShardOp from its LHS.
      raise "SHARD must be followed by s> CONCURRENT EACH"

    elsif node.right.is_a?(AST::ConcurrentOp)
      return transpile_concurrent(node)
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

    # If this function has CATCH blocks and the pipe step can fail,
    # generate snapshot capture: bind LHS to a variable, wrap call in
    # catch that heap-copies the LHS before propagating the error.
    lhs_type = lhs.respond_to?(:full_type) ? lhs.full_type : nil
    lhs_t = lhs_type ? Type.new(lhs_type) : nil
    rhs_fn_name = rhs.is_a?(AST::Identifier) ? rhs.name : (rhs.is_a?(AST::FuncCall) ? rhs.name : nil)
    rhs_can_fail = rhs_fn_name && (@fn_can_fail || {})[rhs_fn_name]

    if @current_fn_has_catch && rhs_can_fail && lhs_t && !lhs_t.void?
      zig_type = transpile_type(lhs_t.resolved.to_s)
      rt_name = @do_rt_name || "rt"
      @snapshot_counter = (@snapshot_counter || 0) + 1
      snap_var = "__snap_#{@snapshot_counter}"
      snap_label = "__snap_blk#{@snapshot_counter}"

      @current_fn_snapshot_types ||= Set.new
      @current_fn_snapshot_types << lhs_t.resolved.to_s

      lhs_code = visit(lhs)

      if rhs.is_a?(AST::Identifier)
        call_zig = "#{rhs.name}(#{rt_name}, #{snap_var})"
      elsif rhs.is_a?(AST::FuncCall)
        extra_args = rhs.args.map { |a| visit(a) }.join(', ')
        fn_name = rhs.name
        call_zig = "#{fn_name}(#{rt_name}, #{snap_var}#{extra_args.empty? ? '' : ', ' + extra_args})"
      else
        return visit(synthetic_call)
      end

      return "#{snap_label}: {\n" \
             "    const #{snap_var} = #{lhs_code};\n" \
             "    break :#{snap_label} #{call_zig} catch |__snap_err| {\n" \
             "        #{rt_name}.captureSnapshot(#{zig_type}, &#{snap_var});\n" \
             "        return __snap_err;\n" \
             "    };\n" \
             "}"
    end

    # Normal path: no CATCH blocks or non-failing step
    visit(synthetic_call)
  end

  # --- ERROR HANDLING (OR RESCUE) ---
  # Check if an expression carries heap_promoted_call, looking through OR wrappers.
  def has_heap_promoted_call?(expr)
    return false unless expr
    return true if expr.respond_to?(:heap_promoted_call) && expr.heap_promoted_call
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_RESCUE)
      return has_heap_promoted_call?(expr.left)
    end
    false
  end

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
        # EXTERN FN trampoline already handles errors (catch + return e).
        # The block produces the payload type, not an error union.
        if node.left.respond_to?(:extern_call) && node.left.extern_call
          return left
        end
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
        return left if node.left.respond_to?(:extern_call) && node.left.extern_call
        return "(#{left_raw} catch undefined)"
      else
        return left
      end
    end

    # Handle OR BREAK: error-to-break coercion (Zig's `catch break`)
    if node.right.is_a?(AST::OrBreak)
      if t_left.error_union?
        return left if node.left.respond_to?(:extern_call) && node.left.extern_call
        return "(#{left_raw} catch break)"
      else
        return left
      end
    end

    # Handle error union with default value: !T OR default -> T
    # EXTERN FN trampoline already handles errors; passthrough.
    if t_left.error_union? && node.left.respond_to?(:extern_call) && node.left.extern_call
      return left
    end

    if t_left.error_union?
      right_code = visit(node.right)

      # When the success path returns heap-promoted data (e.g., struct with duped
      # string fields), the fallback must ALSO have its string fields duped to heap
      # so the caller's cleanup is always valid regardless of which path was taken.
      if has_heap_promoted_call?(node.left) && node.right.is_a?(AST::StructLit)
        ret_type = node.right.full_type
        ret_type = ret_type.is_a?(Type) ? ret_type : Type.new(ret_type) if ret_type
        resolved = ret_type&.resolved
        schema = @struct_schemas&.dig(resolved)
        string_fields = schema&.filter_map do |fname, fdef|
          next if fname.is_a?(Symbol)
          ft = (fdef.is_a?(Hash) ? fdef[:type] : fdef)
          ft = ft.is_a?(Type) ? ft : Type.new(ft || :Any)
          fname if ft.string?
        end || []
        if string_fields.any?
          rt_name = @do_rt_name || "rt"
          promos = string_fields.map { |f| "__fb.#{f} = #{rt_name}.heapAlloc().dupe(u8, __fb.#{f}) catch __fb.#{f};" }.join(" ")
          return "(#{left_raw} catch __fb: { var __fb = #{right_code}; #{promos} break :__fb __fb; })"
        end
      end

      return "(#{left_raw} catch #{right_code})"
    end

    # Standard OR behavior (non-error types)
    right = visit(node.right)
    # Wrap in parens so `orelse` binds correctly when used as a sub-expression.
    # Zig's `orelse` has very low precedence — without parens, `a + b orelse c`
    # parses as `(a + b) orelse c` instead of `a + (b orelse c)`.
    return "((#{left}) orelse #{right})"
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
      # Sharded lists are shared across fibers — must stay heap-backed.
      # Regular @list uses the frame arena (CheatArena grows dynamically via heap pages).
      # @pool is always heap (explicit location: :heap set in annotator).
      first_arg_type = node.respond_to?(:args) ? node.args&.first&.type_info : nil
      force_heap = if node.is_a?(AST::MethodCall)
        node.object.respond_to?(:type_info) &&
          (node.object.type_info&.pool? || node.object.type_info&.sharded?)
      else
        first_arg_type&.pool? || first_arg_type&.sharded?
      end
      target_storage = if force_heap
        :heap
      elsif node.is_a?(AST::MethodCall) && node.object.respond_to?(:storage)
        node.object.storage
      elsif !node.is_a?(AST::MethodCall) && first_arg_type&.list_collection?
        # For list operations (append, etc.), use the list arg's storage,
        # not the call result's storage (which is always :stack for Void returns).
        node.args&.first&.respond_to?(:storage) ? (node.args.first.storage || :stack) : :stack
      else
        node.storage
      end
      rt_ref = @do_rt_name || "rt"
      alloc = target_storage == :heap ? "#{rt_ref}.heapAlloc()" : "#{rt_ref}.frameAlloc()"
      pattern = pattern.gsub("{alloc}", alloc)
    end

    args_zig.each_with_index do |val, i|
      pattern = pattern.gsub("{#{i}}", val)
    end

    pattern
  end

  # Unified return escape promotion.
  #
  # ONE code path for ALL return value shapes. Promotion is driven by TYPE,
  # not by AST node kind. The return expression is bound to a temp var (__ret),
  # frame-allocated fields are promoted to heap, and __ret is returned.
  #
  # For direct types (string, list, map): promotes the value itself.
  # Emit return code from a PromotionPlan. Zero decisions here — the plan
  # already decided what to promote.
  def emit_return_from_plan(val_code, plan, rt_name, suppress)
    parts = [suppress]

    plan.var_promotes.each do |vp|
      vname = zig_safe_name(vp[:var])
      if vp[:zig_type].include?("ArrayListUnmanaged")
        elem = vp[:zig_type][/ArrayListUnmanaged\((.+)\)/, 1]
        parts << "try CheatLib.promoteList(#{elem}, #{rt_name}, &#{vname});"
      elsif vp[:zig_type].include?("StringMap")
        parts << "#{vname}.alloc = #{rt_name}.heapAlloc();"
      else
        parts << "try CheatLib.promote(#{vp[:zig_type]}, #{rt_name}, &#{vname});"
      end
    end

    if plan.struct_promote
      zig_type = transpile_type(plan.struct_promote)
      parts << "var __ret = #{val_code};"
      parts << "try CheatLib.promoteFields(#{zig_type}, #{rt_name}, &__ret);"
      parts << "return __ret;"
    elsif plan.var_promotes.any?
      parts << "const __ret = #{val_code};"
      parts << "return __ret;"
    else
      parts << "return #{val_code};"
    end

    parts.reject(&:empty?).join("\n")
  end

  # For struct types: walks schema + field values, promotes each escapable field.
  # +node+ is the return value AST node (used to inspect StructLit field values).
  def emit_return_with_promotion(val_code, ret_type, rt_name, suppress = "", node: nil)
    ret_type = Type.new(ret_type) if ret_type && !ret_type.is_a?(Type)

    # Direct escapable type (string, list, map)
    if ret_type&.needs_escape_promotion?
      if ret_type.string?
        promoted = "try #{rt_name}.heapAlloc().dupe(u8, #{val_code})"
        return [suppress, "return #{promoted};"].reject(&:empty?).join("\n")
      else
        promo = ret_type.escape_promote_code("__ret", rt_name)
        return [suppress, "var __ret = #{val_code};", promo, "return __ret;"].compact.reject(&:empty?).join("\n")
      end
    end

    # Struct/union: collect promotions from two sources:
    #   1. StructLit field values: promotes source VARIABLES before struct init
    #      (e.g., promoteList on @list before .items is captured in the struct)
    #   2. Schema field types: promotes __ret FIELDS after struct init
    #      (e.g., dupe string fields that are already in the struct)
    pre_promos = []   # Before struct init (operate on source variables)
    post_promos = []  # After struct init (operate on __ret fields)

    # Source 1: StructLit field values — promote source variables.
    # Collections: pre-promo (before struct init) so .items captures heap data.
    # Strings: post-promo (after struct init) via __ret.field = dupe(...).
    promoted_fields = Set.new
    if node&.is_a?(AST::StructLit)
      node.fields.each do |fname, fval|
        fval_type = fval.respond_to?(:type_info) ? fval.type_info : nil
        fval_type = Type.new(fval_type) if fval_type && !fval_type.is_a?(Type)
        next unless fval_type&.needs_escape_promotion? && fval.is_a?(AST::Identifier)
        promoted_fields << fname.to_s
        if fval_type.string?
          # String: dupe to heap after struct init (can't reassign const source var).
          post_promos << "__ret.#{fname} = try #{rt_name}.heapAlloc().dupe(u8, __ret.#{fname});"
        else
          # Collection: promote in-place before struct init so .items is heap-backed.
          pre_promos << fval_type.escape_promote_code("#{zig_safe_name(fval.name)}", rt_name)
        end
      end
    end

    # Source 2: schema walk — promote __ret fields AFTER struct init
    # (covers string fields where the actual value may be a literal or expression)
    resolved = ret_type&.resolved
    schema = @struct_schemas&.dig(resolved)
    if schema
      schema.each do |fname, fdef|
        next if fname.is_a?(Symbol) || promoted_fields.include?(fname.to_s)
        ftype = fdef.is_a?(Hash) ? fdef[:type] : fdef
        ft = ftype.is_a?(Type) ? ftype : Type.new(ftype || :Any)
        next unless ft.needs_escape_promotion?
        if ft.string?
          post_promos << "__ret.#{fname} = try #{rt_name}.heapAlloc().dupe(u8, __ret.#{fname});"
        else
          post_promos << ft.escape_promote_code("__ret.#{fname}", rt_name)
        end
      end
    end

    if pre_promos.any? || post_promos.any?
      return [suppress, *pre_promos.compact, "var __ret = #{val_code};", *post_promos.compact, "return __ret;"].reject(&:empty?).join("\n")
    end

    # No promotion needed.
    [suppress, "return #{val_code};"].reject(&:empty?).join("\n")
  end

  # Emit escape promotions for a set of captured variables (used by BG/DO blocks).
  # Same logic as emit_escape_promotions but works from a {name => type_info} hash
  # instead of AST nodes. Returns [promotions_array, promoted_names_hash].
  # promoted_names maps original names to new bindings for types that produce a new
  # value (strings); collections are promoted in-place and don't need renaming.
  def emit_capture_escape_promotions(captured, alloc_expr, rt_name, prefix)
    promotions = []
    promoted_names = {}

    captured.each do |name, type_obj|
      t = type_obj ? Type.new(type_obj) : nil
      next unless t && t.needs_escape_promotion?
      next if t.needs_pointer_passing?  # pointer captures (maps/pools) are shared, not moved

      code = t.escape_promote_code(name, rt_name, alloc_expr: alloc_expr)
      next unless code

      if t.string?
        # String promotion returns a new slice — bind to a new name.
        promoted = "#{prefix}_#{name}"
        promotions << "const #{promoted} = #{code};"
        promoted_names[name] = promoted
      else
        # Collection promotion is in-place — no new binding needed.
        promotions << code
      end
    end

    [promotions, promoted_names]
  end

  # Emits Zig for pool.insert / pool.get / pool.remove method calls.
  def transpile_pool_method(node)
    obj_code = visit(node.object)
    rt_name  = @do_rt_name || "rt"
    case node.pool_method
    when :insert
      val_code = visit(node.args[0])
      "try #{obj_code}.insert(#{rt_name}.heapAlloc(), #{val_code})"
    when :get
      id_code = visit(node.args[0])
      "#{obj_code}.get(#{id_code})"
    when :remove
      id_code = visit(node.args[0])
      "#{obj_code}.remove(#{id_code})"
    when :count
      "#{obj_code}.count()"
    end
  end

  def transpile_set_method(node)
    obj_code = visit(node.object)
    rt_name  = @do_rt_name || "rt"
    case node.set_method
    when :insert
      val_code = visit(node.args[0])
      "try #{obj_code}.insert(#{rt_name}.heapAlloc(), #{val_code})"
    when :"contains?"
      val_code = visit(node.args[0])
      "#{obj_code}.contains(#{val_code})"
    when :remove
      val_code = visit(node.args[0])
      "#{obj_code}.remove(#{rt_name}.heapAlloc(), #{val_code})"
    when :count
      "#{obj_code}.count()"
    end
  end

  # Emits Zig for a HashMap literal, including any initial key-value pairs.
  # Empty literals emit a bare makeHashMap call; populated literals use a Zig
  # labeled block so all puts happen before the value is yielded.
  def transpile_hash_lit(node)
    # Prefer coerced_type (the declared type) over the inferred HashMap<Any> from empty literals.
    # Use Type objects directly to preserve shard_count (not lost through to_s round-trip).
    # Use coerced_type_info (full Type with capabilities) instead of coerced_type (raw symbol).
    coerced_ti = node.respond_to?(:coerced_type_info) ? node.coerced_type_info : nil
    map_ft = if coerced_ti && node.full_type.map? && node.full_type.value_type.resolved == :Any
      coerced_ti
    else
      node.full_type.is_a?(Type) ? node.full_type : Type.new(node.full_type)
    end
    rt_name  = @do_rt_name || "rt"

    # Build the bare inner map type (without Arc/RwLocked wrapping) for initialization.
    bare_ft = Type.new(map_ft.resolved.to_s)
    bare_ft.shard_count = map_ft.shard_count if map_ft.shard_count
    bare_ft.sync = map_ft.sync if map_ft.shard_count && map_ft.sync

    # StringMap, ShardedStringMap, MutexShardedStringMap store their allocator.
    # Numeric maps and PartitionedStringMap (shared-nothing) don't have alloc.
    if bare_ft.numeric_map? || (bare_ft.sharded? && !bare_ft.striped?)
      bare_init = "#{bare_ft.zig_type}{}"
    else
      # Always use heapAlloc for StringMaps. Frame-allocated keys become
      # dangling after restoreFrameMark in called functions, causing
      # use-after-free when the map is accessed later.
      bare_init = "#{bare_ft.zig_type}{ .alloc = #{rt_name}.heapAlloc() }"
    end

    # Wrap with RwLocked/Locked and Arc/Rc if capabilities require it.
    # Skip Locked/RwLocked wrapping for striped maps - sync is built into the map type.
    if !bare_ft.striped?
      if map_ft.sync == :write_locked
        bare_init = "CheatLib.RwLocked(#{bare_ft.zig_type}).init(#{bare_init})"
      elsif map_ft.sync == :locked
        bare_init = "CheatLib.Locked(#{bare_ft.zig_type}).init(#{bare_init})"
      end
    end

    if map_ft.shared?
      zig_init = "try CheatLib.arcCreate(#{bare_ft.zig_type}, #{rt_name}.heapAlloc(), #{bare_init})"
    elsif map_ft.multiowned?
      zig_init = "try CheatLib.rcCreate(#{bare_ft.zig_type}, #{rt_name}.heapAlloc(), #{bare_init})"
    else
      zig_init = bare_init
    end

    return zig_init if node.pairs.empty?

    @hashlit_counter ||= 0
    id    = @hashlit_counter
    @hashlit_counter += 1
    label = "__hl#{id}"
    var   = "__hl#{id}_map"

    if map_ft.numeric_map?
      key_zig = map_ft.key_type.zig_type
      val_zig = map_ft.value_type.zig_type
      puts_stmts = node.pairs.map do |k, v|
        key_str = visit(k)
        val_str = visit(v)
        "try CheatLib.numericMapPut(#{key_zig}, #{val_zig}, #{rt_name}.frameAlloc(), &#{var}, #{key_str}, #{val_str});"
      end.join("\n            ")
    else
      puts_stmts = node.pairs.map do |k, v|
        key_str = visit(k)
        val_str = visit(v)
        "try #{var}.put(#{rt_name}.heapAlloc(), #{rt_name}.frameAlloc(), #{key_str}, #{val_str});"
      end.join("\n            ")
    end

    "#{label}: {\n            var #{var} = #{zig_init};\n            #{puts_stmts}\n            break :#{label} #{var};\n        }"
  end

  # Emits Zig for map.delete / map.contains / map.count / map.keys / map.values.
  def transpile_map_method(node)
    obj_code = visit(node.object)
    rt_name  = @do_rt_name || "rt"
    map_ft   = Type.new(node.object.full_type)
    # Auto-deref Arc-wrapped maps: map.ctrl.data.* gives the inner map.
    obj_ti = node.object.type_info
    obj_code = "#{obj_code}.ctrl.data.*" if obj_ti&.shared? || obj_ti&.multiowned?

    # Unified .remove()/.contains()/.count() for StringMap, PartitionedStringMap, ShardedStringMap.
    if !map_ft.numeric_map?
      # Always use heapAlloc for string map operations — matches put allocator.
      case node.map_method
      when :delete
        key_code = visit(node.args[0])
        "#{obj_code}.remove(#{rt_name}.heapAlloc(), #{key_code})"
      when :"contains?"
        key_code = visit(node.args[0])
        "#{obj_code}.contains(#{key_code})"
      when :count
        "#{obj_code}.count()"
      when :keys
        if map_ft.sharded? || map_ft.striped?
          # Sharded maps have a direct keys() method that iterates all shards
          "try #{obj_code}.keys(#{rt_name}.heapAlloc())"
        else
          val_zig = map_ft.value_type.zig_type
          "try CheatLib.mapKeys(#{val_zig}, #{rt_name}.frameAlloc(), #{obj_code}.inner)"
        end
      when :values
        if map_ft.sharded? || map_ft.striped?
          "try #{obj_code}.values(#{rt_name}.heapAlloc())"
        else
          val_zig = map_ft.value_type.zig_type
          "try CheatLib.mapValues(#{val_zig}, #{rt_name}.frameAlloc(), #{obj_code}.inner)"
        end
      end
    elsif map_ft.numeric_map?
      key_zig = map_ft.key_type.zig_type
      val_zig = map_ft.value_type.zig_type
      case node.map_method
      when :delete
        key_code = visit(node.args[0])
        "CheatLib.numericMapDelete(#{key_zig}, #{val_zig}, #{rt_name}.frameAlloc(), &#{obj_code}, #{key_code})"
      when :"contains?"
        key_code = visit(node.args[0])
        "CheatLib.numericMapContains(#{key_zig}, #{val_zig}, #{obj_code}, #{key_code})"
      when :count
        "CheatLib.numericMapCount(#{key_zig}, #{val_zig}, #{obj_code})"
      when :keys
        "try CheatLib.numericMapKeys(#{key_zig}, #{val_zig}, #{rt_name}.frameAlloc(), #{obj_code})"
      when :values
        "try CheatLib.numericMapValues(#{key_zig}, #{val_zig}, #{rt_name}.frameAlloc(), #{obj_code})"
      end
    else
      val_zig = map_ft.value_type.zig_type
      case node.map_method
      when :delete
        key_code = visit(node.args[0])
        "#{obj_code}.remove(#{rt_name}.frameAlloc(), #{key_code})"
      when :"contains?"
        key_code = visit(node.args[0])
        "#{obj_code}.contains(#{key_code})"
      when :count
        "#{obj_code}.count()"
      when :keys
        "try CheatLib.mapKeys(#{val_zig}, #{rt_name}.frameAlloc(), #{obj_code}.inner)"
      when :values
        "try CheatLib.mapValues(#{val_zig}, #{rt_name}.frameAlloc(), #{obj_code}.inner)"
      end
    end
  end

  # Maps a CLEAR stack_size symbol (or nil) to a Zig TaskConfig struct literal.
  # nil / :standard → Standard (16 KB); :micro → Micro (4 KB); :large → Large (64 KB); :xl → Xl (256 KB)
  STACK_SIZE_ZIG_VARIANT = {
    nil       => "Standard",
    :micro    => "Micro",
    :standard => "Standard",
    :large    => "Large",
    :xl       => "Xl",
    :service  => "Huge",
  }.freeze

  # BG spawn call: spawnBest by default, spawnPinned when @pinned.
  # spawnPinned distributes fibers round-robin across schedulers — each
  # scheduler gets its own set of pinned fibers (shared-nothing model).
  def bg_spawn_call(node, rt_name, ctx_type, ctx_var)
    task_cfg = task_config_zig(node.stack_size, pinned: !!node.pinned)
    if node.pinned
      <<~ZIG.chomp
        try CheatHeader.spawnPinned(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
                    #{ctx_var},
                    #{task_cfg},
                );
      ZIG
    else
      <<~ZIG.chomp
        try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&#{ctx_type}.run)),
                    #{ctx_var},
                    #{task_cfg},
                );
      ZIG
    end
  end

  def task_config_zig(stack_size, pinned: false)
    variant = STACK_SIZE_ZIG_VARIANT.fetch(stack_size, "Standard")
    if pinned
      ".{ .stack_size = .#{variant}, .pinned = true }"
    else
      ".{ .stack_size = .#{variant} }"
    end
  end

  # ── Test Framework Transpilation ─────────────────────────────────

  def test_preamble
    <<~ZIG
      var gpa = std.heap.GeneralPurposeAllocator(.{}){};
      defer _ = gpa.deinit();
      const allocator = gpa.allocator();
      var global_ctx = EbrContext{};
      defer global_ctx.deinit(allocator);
      var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
      defer rt.deinit();
      rt.wireAllocator();
    ZIG
  end

  def transpile_test_block(node)
    test_name = node.name
    setup_code = transpile_block(node.setup)

    tests = []
    node.whens.each do |when_block|
      when_desc = when_block.description

      stubs = when_block.setup.select { |s| s.is_a?(AST::StubDecl) }
      non_stub_setup = when_block.setup.reject { |s| s.is_a?(AST::StubDecl) }
      when_setup = transpile_block(non_stub_setup)

      prev_stubs = @active_stubs || {}
      @active_stubs = prev_stubs.dup
      stub_decls = stubs.map { |s| transpile_stub(s) }.join("\n")

      when_block.tests.each do |test_that|
        full_name = "#{test_name}: #{when_desc}: #{test_that.description}"
        body_code = transpile_block(test_that.body)

        tests << <<~ZIG
          test "#{full_name}" {
              #{test_preamble}
              #{stub_decls}
              #{setup_code}
              #{when_setup}
              #{body_code}
          }
        ZIG
      end

      when_block.benchmarks.each do |b|
        bench_name = "#{test_name}: #{when_desc}: #{b.class.name.split('::').last.downcase}"
        bench_code = visit(b)
        tests << <<~ZIG
          test "#{bench_name}" {
              #{test_preamble}
              #{stub_decls}
              #{setup_code}
              #{when_setup}
              #{bench_code}
          }
        ZIG
      end

      @active_stubs = prev_stubs
    end

    tests.join("\n")
  end

  def transpile_assert_raises(node)
    rt_name = @do_rt_name || "rt"
    kind = node.kind
    expr_code = visit(node.expression)

    error_name_check = if node.error_name
      " and !#{rt_name}.__error.matchesName(\"#{node.error_name}\")"
    else
      ""
    end

    <<~ZIG
      {
          if (#{expr_code}) |_| {
              @panic("ASSERT_RAISES: expected #{kind} error but none raised");
          } else |_| {
              if (!#{rt_name}.__error.matchesKind(.#{kind})#{error_name_check}) {
                  @panic("ASSERT_RAISES: expected #{kind} error, got different kind");
              }
          }
      }
    ZIG
  end

  def transpile_benchmark(node)
    rt_name = @do_rt_name || "rt"
    expr = node.expression
    iterations = node.iterations

    if expr.is_a?(AST::FuncCall)
      fn_name = zig_safe_name(expr.name)
      args_zig = expr.args.map { |a| visit(a) }
      needs_rt = callee_needs_rt?(expr.name)
      can_fail = callee_can_fail?(expr.name)

      all_args = needs_rt ? ["rt_ptr"] + args_zig : args_zig
      ret_type_str = can_fail ? "anyerror!void" : "void"
      call_str = "#{fn_name}(#{all_args.join(', ')})"
      call_str = "_ = try #{call_str}" if can_fail
      call_str = "_ = #{call_str}" unless can_fail

      suppress_rt = needs_rt ? "" : "_ = rt_ptr; "
      <<~ZIG
        {
            const __bench_wrapper = struct {
                fn run(rt_ptr: *Runtime) #{ret_type_str} {
                    #{suppress_rt}#{call_str};
                }
            };
            const __bench_result = CheatLib.benchmark(__bench_wrapper.run, &#{rt_name}, .{}, #{iterations});
            CheatLib.printBenchmarkResult("#{expr.name}", __bench_result);
        }
      ZIG
    else
      "// BENCHMARK: expression is not a function call, skipping"
    end
  end

  def transpile_smash(node)
    rt_name = @do_rt_name || "rt"
    expr = node.expression

    if expr.is_a?(AST::FuncCall)
      <<~ZIG
        {
            std.debug.print("\\nSMASH #{expr.name}: adversarial workload analysis\\n", .{});
            std.debug.print("  (shard skew generation requires @sharded map parameter)\\n", .{});
        }
      ZIG
    else
      "// SMASH: expression is not a function call, skipping"
    end
  end

  def transpile_profile(node)
    rt_name = @do_rt_name || "rt"
    expr = node.expression

    if expr.is_a?(AST::FuncCall)
      fn_name = zig_safe_name(expr.name)
      args_zig = expr.args.map { |a| visit(a) }
      needs_rt = callee_needs_rt?(expr.name)
      can_fail = callee_can_fail?(expr.name)
      all_args = needs_rt ? ["&#{rt_name}"] + args_zig : args_zig
      call_str = "#{fn_name}(#{all_args.join(', ')})"
      call_str = can_fail ? "try #{call_str}" : call_str

      effects = (@fn_effects || {})[expr.name] || Set.new
      has_blocking = effects.include?(:BLOCKING)
      has_heap = effects.include?(:HEAP)

      suggestions = []
      suggestions << 'std.debug.print("  Suggestion: function has BLOCKING effect (lock contention possible).\\n"' \
                     '  ++ "  Consider @locked instead of @writeLocked for write-heavy workloads.\\n", .{});' if has_blocking
      suggestions << 'std.debug.print("  Suggestion: function has HEAP effect (dynamic allocation).\\n"' \
                     '  ++ "  Check alloc-profile output for hotspots.\\n", .{});' if has_heap
      suggestion_code = suggestions.join("\n")

      <<~ZIG
        {
            const __prof_alloc = @import("alloc-profile.zig");
            const __prof_allocs_before = __prof_alloc.totalAllocs();
            const __prof_bytes_before = __prof_alloc.totalBytes();
            var __prof_timer = std.time.Timer.start() catch unreachable;
            _ = #{call_str};
            const __prof_elapsed = __prof_timer.read();
            const __prof_allocs_after = __prof_alloc.totalAllocs();
            const __prof_bytes_after = __prof_alloc.totalBytes();
            const __prof_allocs = __prof_allocs_after - __prof_allocs_before;
            const __prof_bytes = __prof_bytes_after - __prof_bytes_before;
            std.debug.print("\\nPROFILE #{expr.name}:\\n", .{});
            std.debug.print("  Time:   {d:.3}ms\\n", .{@as(f64, @floatFromInt(__prof_elapsed)) / 1_000_000.0});
            std.debug.print("  Allocs: {d} ({d} KB)\\n", .{__prof_allocs, __prof_bytes / 1024});
            #{suggestion_code}
        }
      ZIG
    else
      "// PROFILE: expression is not a function call, skipping"
    end
  end

  def transpile_stub(node)
    fn_name = node.function_name
    stub_var = "__stub_#{fn_name}"

    case node.kind
    when :returns
      val_code = visit(node.value)
      @active_stubs[fn_name] = { kind: :returns, var: stub_var }
      "const #{stub_var} = #{val_code};"

    when :captures
      cap_name = node.value
      @active_stubs[fn_name] = { kind: :captures, var: cap_name }
      "var #{cap_name}: i64 = 0; _ = &#{cap_name};"

    when :sequence
      values = node.value
      items = if values.respond_to?(:items)
        values.items.map { |v| visit(v) }
      else
        [visit(values)]
      end
      @active_stubs[fn_name] = { kind: :sequence, var: stub_var }
      arr_items = items.map { |v| "#{v}" }.join(", ")
      "const #{stub_var}_seq = [_][]const u8{ #{arr_items} };\nvar #{stub_var}_idx: usize = 0; _ = &#{stub_var}_idx;"

    when :with
      lambda_code = visit(node.value)
      @active_stubs[fn_name] = { kind: :with, var: stub_var }
      "const #{stub_var} = #{lambda_code};"
    end
  end

  # Temporarily installs a new fiber capture map and rt alias, runs the block, then restores.
  # Used by both DoBlock (per-branch) and BgBlock to rewrite identifier access inside fiber bodies.
  def with_fiber_capture_map(new_entries, &blk)
    prev_map = @do_capture_map || {}
    prev_rt  = @do_rt_name
    @do_capture_map = prev_map.merge(new_entries)
    @do_rt_name     = "__rt"
    result = blk.call
    @do_capture_map = prev_map
    @do_rt_name     = prev_rt
    result
  end

  # Collect all AST::Identifier nodes in a list of expressions for DO/BG block capture.
  # Returns a hash of { name => type_info } for each unique outer variable referenced.
  # Variables declared inside the body (BindExpr/VarDecl) are tracked as locally bound
  # so they are not incorrectly added as outer captures.
  def collect_do_identifiers(exprs)
    result = {}
    @_capture_close_zig = {}  # name → close_zig pattern (for resource captures)
    locally_bound = Set.new
    exprs.each do |e|
      walk_do_identifiers(e, result, locally_bound)
      # After processing a declaration, mark the name as locally bound so that
      # subsequent expressions in the same body don't try to capture it from outside.
      if (e.is_a?(AST::BindExpr) || e.is_a?(AST::VarDecl)) && e.name.is_a?(String)
        locally_bound = locally_bound | Set[e.name]
      end
      # ThenChain: all step bindings are locally declared inside the fiber.
      if e.is_a?(AST::ThenChain)
        e.steps.each { |step| locally_bound = locally_bound | Set[step[:binding]] if step[:binding] }
      end
    end
    result
  end

  # Escape CLEAR variable names that would shadow Zig primitive types
  # (uN, iN, fN patterns like u8, i32, f64) using Zig's @"name" quoting syntax.
  # Strips trailing `!` (mutation) and `?` (predicate) suffixes from CLEAR names —
  # these are naming conventions not valid in Zig identifiers.
  def trampoline_call(tid, rt_name, node)
    effects = node.respond_to?(:extern_effects) ? (node.extern_effects || {}) : {}
    is_safe = effects.is_a?(Hash) ? effects[:safe] : false
    if is_safe
      "__Ext#{tid}.run(@ptrCast(&__ext#{tid}_frame))"
    else
      "#{rt_name}.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &__Ext#{tid}.run), @ptrCast(&__ext#{tid}_frame))"
    end
  end

  def trampoline_call_method(tid, rt_name, node)
    effects = node.respond_to?(:extern_effects) ? (node.extern_effects || {}) : {}
    is_safe = effects.is_a?(Hash) ? effects[:safe] : false
    if is_safe
      "__ExtM#{tid}.run(@ptrCast(&__extm#{tid}_frame))"
    else
      "#{rt_name}.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &__ExtM#{tid}.run), @ptrCast(&__extm#{tid}_frame))"
    end
  end

  ZIG_PRIMITIVE_RE = /\A[uif]\d+\z/
  # Wrap string literals in heapAlloc.dupe for HashMap value storage.
  # String literals are rodata - can't be freed by HashMap.deinit.
  def heap_dupe_string_literals(val_ref, val_node, rt_name)
    # Direct string literal: "hello" -> try heapAlloc.dupe(u8, "hello")
    if val_node.is_a?(AST::Literal) && val_node.type_info&.string?
      return "try #{rt_name}.heapAlloc().dupe(u8, #{val_ref})"
    end
    # Union construction with string literal field: Value{ Str: "hello" }
    if val_node.is_a?(AST::StructLit)
      schema = @union_schemas&.dig(val_node.name.to_sym)
      if schema
        val_node.fields.each do |fname, fnode|
          if fnode.type_info&.string? && fnode.is_a?(AST::Literal)
            if fnode.respond_to?(:value) && fnode.value.is_a?(String)
              old_str = "\"#{fnode.value}\""
              new_str = "try #{rt_name}.heapAlloc().dupe(u8, #{old_str})"
              return val_ref.sub(old_str, new_str)
            end
          end
        end
      end
    end
    val_ref
  end

  def zig_safe_name(name)
    cleaned = (name.end_with?('!') || name.end_with?('?')) ? name[0..-2] : name
    # CLEAR's main() must not collide with Zig's pub fn main() entry point.
    cleaned = "clearMain" if cleaned == "main"
    cleaned =~ ZIG_PRIMITIVE_RE ? "@\"#{cleaned}\"" : cleaned
  end

  def walk_do_identifiers(node, result, locally_bound = Set.new)
    return unless node.is_a?(AST::Locatable)
    if node.is_a?(AST::Identifier)
      unless locally_bound.include?(node.name)
        result[node.name] ||= node.type_info
        # Capture the resource close pattern from the symbol entry if available.
        if node.symbol.respond_to?(:close_zig) && node.symbol.close_zig && !@_capture_close_zig.key?(node.name)
          @_capture_close_zig[node.name] = node.symbol.close_zig
        end
      end
      return
    end
    # ThenChain: process steps in order, accumulating bindings into locally_bound
    # so later steps that reference earlier bindings are NOT captured from outer scope.
    if node.is_a?(AST::ThenChain)
      lb = locally_bound
      node.steps.each do |step|
        walk_do_identifiers(step[:expr], result, lb)
        lb = lb | Set[step[:binding]] if step[:binding]
      end
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
  # Returns [condition_string, bindings_string].
  # condition_string: Zig boolean expression for the if-check.
  # bindings_string: Zig const declarations for destructured fields (prepended to body).
  def transpile_struct_pattern(subject, pat)
    conditions = []
    bindings = []

    pat.fields.each do |f|
      next if f[:value] == :wildcard
      if f[:value] == :bind
        bindings << "const #{f[:name]} = #{subject}.#{f[:name]}; _ = &#{f[:name]};"
      else
        conditions << "#{subject}.#{f[:name]} == #{visit(f[:value])}"
      end
    end

    cond = conditions.empty? ? "true" : conditions.join(" and ")
    [cond, bindings.join("\n    ")]
  end

  # True if the AST node is a statement (declaration, assignment, control flow, block)
  # rather than an expression. Expressions used as statements need `_ = ` in Zig
  # to discard their non-void return values.
  def statement_node?(node)
    node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr) ||
    node.is_a?(AST::Assignment) ||
    node.is_a?(AST::IfStatement) || node.is_a?(AST::WhileLoop) ||
    node.is_a?(AST::ForRange) || node.is_a?(AST::ForEach) ||
    node.is_a?(AST::MatchStatement) || node.is_a?(AST::ReturnNode) ||
    node.is_a?(AST::BreakNode) || node.is_a?(AST::ContinueNode) ||
    node.is_a?(AST::WithBlock) || node.is_a?(AST::BgBlock) ||
    node.is_a?(AST::BgStreamBlock) || node.is_a?(AST::DoBlock) ||
    node.is_a?(AST::FunctionDef) || node.is_a?(AST::StructDef) ||
    node.is_a?(AST::UnionDef) || node.is_a?(AST::EnumDef) ||
    node.is_a?(AST::RequireNode) || node.is_a?(AST::PassStmt)
  end

  def transpile_block(statements)
    statements.map do |stmt|
      ctx = current_tp_ctx
      saved_temps = ctx&.pending_heap_temps
      ctx.pending_heap_temps = [] if ctx
      code = visit(stmt)
      # Move suppression: for consumed args (TAKES, append, struct/union construction).
      consumed = emit_consumed_moves(stmt)
      unless consumed.empty?
        if stmt.is_a?(AST::ReturnNode)
          # For returns, emit moves BEFORE the return (after return is unreachable).
          code = "#{consumed}\n#{code}"
        else
          code += ";" unless code.strip.end_with?(";") || code.strip.end_with?("}")
          code = "#{code}\n#{consumed}"
        end
      end
      # Flush heap-promoted temporaries: emit const + defer cleanup before the statement.
      temps = ctx&.pending_heap_temps || []
      if temps.any?
        schema_lookup = ->(name) { @struct_schemas&.dig(name) || @union_schemas&.dig(name) }
        preamble = temps.map { |t|
          ti = t[:type_info].is_a?(Type) ? t[:type_info] : Type.new(t[:type_info] || :Any)
          ti.heap_promoted = true
          zig_t = ti.zig_type
          entry = CleanupPlan.classify_heap_temp(ti, schema_lookup)
          if entry
            proxy = Struct.new(:type_info, :storage, :resource_close_zig, :container_borrow).new(ti, :heap, nil, false)
            cleanup = emit_cleanup_from_entry(t[:var], entry, proxy)
          else
            cleanup = ""
          end
          "const #{t[:var]}: #{zig_t} = #{t[:call]};\n#{cleanup}"
        }.join("\n")
        if stmt.is_a?(AST::ReturnNode) && temps.any? { |t| t[:var] && code.include?(t[:var]) }
          move_suppression = temps.filter_map { |t|
            "#{t[:var]}_moved = true;" if code.include?(t[:var])
          }.join("\n")
          code = "#{preamble}\n#{move_suppression}\n#{code}"
        else
          code = "#{preamble}\n#{code}"
        end
      end
      ctx.pending_heap_temps = saved_temps if ctx
      # Zig requires non-void expression results to be consumed. Any AST node
      # that is an expression (not a declaration, assignment, or control flow)
      # with a non-void return type needs `_ = ` when used as a statement.
      discarded = false
      unless statement_node?(stmt)
        if stmt.respond_to?(:resolved_type) && stmt.resolved_type && stmt.resolved_type != :Void
          unless code.strip.start_with?("_ = ")
            code = "_ = #{code}"
            discarded = true
          end
        end
      end
      # Add ; if it's not a block ending (}) and doesn't have one yet.
      # Exception: `_ = { block }` is a statement expression — always needs ;
      code += ";" unless code.strip.end_with?(";") || (code.strip.end_with?("}") && !discarded)
      # Source line mapping: CLR:N comment traces Zig output back to CLEAR source.
      line = stmt.respond_to?(:token) && stmt.token ? stmt.token.line : nil
      code = "// CLR:#{line}\n#{code}" if line
      code
    end.join("\n")
  end


  def get_zig_format(flux_type)
    t = flux_type.to_s

    # 2. Handle Strings explicitly — covers :String, Byte[N] (stack string literals),
    #    and Byte[] (dynamic byte slices), all of which are []const u8 in Zig.
    return "{s}" if t.include?("String") || t.match?(/^Byte\[/)

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

  # Returns true if the named callee requires an rt: *Runtime argument.
  # Defaults to true (conservative) for unknown/stdlib callees.
  def callee_needs_rt?(name)
    return true if name.nil? || name.empty?
    val = @fn_needs_rt&.fetch(name, nil)
    val.nil? ? true : val
  end

  # Returns true if the named callee returns an error union (!T) and needs try.
  # Defaults to true (conservative) for unknown/stdlib callees.
  def callee_can_fail?(name)
    return true if name.nil? || name.empty?
    val = @fn_can_fail&.fetch(name, nil)
    val.nil? ? true : val
  end

  # Collect all Identifier names referenced in an AST subtree.
  # Used to determine which parameters actually need _ = &name; suppression.
  def collect_identifier_names(nodes)
    names = Set.new
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef
        # Don't descend into nested definitions.
      when AST::Identifier
        names.add(n.name)
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(nodes)
    names
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
    opts.on('--use-c-allocator', 'Use the C allocator (jemalloc/mimalloc) instead of GPA') do
      options[:use_c_allocator] = true
    end
    opts.on('--test', 'Emit as test module') do
      options[:mode] = :test
    end
    opts.on('--default-stack SIZE', 'Default stack size class') do |size|
      options[:default_stack] = size
    end
    opts.on('--strict', 'Strict test mode') do
      options[:strict] = true
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

