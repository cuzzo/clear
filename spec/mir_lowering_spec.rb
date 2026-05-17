require "rspec"
require "ostruct"
require "stringio"
require_relative "../src/mir/mir"
require_relative "../src/ast/std_lib"
require_relative "../src/mir/mir_lowering"
require_relative "../src/mir/mir_emitter"
require_relative "../src/mir/mir_checker"
require_relative "../src/ast/ast"
require_relative "../src/ast/lexer"
require_relative "../src/ast/type"
require_relative "../src/backends/importer"
require_relative "../src/backends/compiler_frontend"

RSpec.describe MIRLowering do
  let(:tok) { Lexer::Token.new(:KEYWORD, "test", 1, 1) }
  let(:emitter) { MIREmitter.new }

  def lowering(**opts)
    MIRLowering.new(**opts)
  end

  def emit(mir_node)
    emitter.emit(mir_node)
  end

  def make_lit(type, value, full_type: nil, storage: nil)
    node = AST::Literal.new(tok, type, value, storage)
    node.full_type = full_type || case type
                                  when :NUMBER then :Number
                                  when :INT64 then :Int64
                                  when :STRING then :String
                                  when :BOOLEAN then :Boolean
                                  when :NIL then :Nil
                                  else :Any
                                  end
    node
  end

  def make_id(name, full_type: :Int64, sync: nil)
    node = AST::Identifier.new(tok, name)
    node.full_type = full_type
    if sync
      node.symbol = SymbolEntry.new(reg: name, type: full_type, mutable: true, storage: :stack, sync: sync)
    end
    node
  end

  def make_binop(left, op, right)
    node = AST::BinaryOp.new(tok, left, op, right)
    node.full_type = left.full_type
    node
  end

  def compile_first_assignment(src, target: :zig)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = CompilerFrontend.compile(src, importer: importer, source_dir: Dir.pwd)
    fn = result.ast.statements.find { |s| s.is_a?(AST::FunctionDef) }
    assignment = fn.body.find { |s| s.is_a?(AST::Assignment) }
    low = lowering(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      importer: importer,
      source_dir: Dir.pwd,
      target: target
    )
    [low, assignment]
  end

  def compile_fixture_lowering(path)
    src_path = File.expand_path(path, Dir.pwd)
    importer = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    result = nil
    begin
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      result = CompilerFrontend.compile(File.read(src_path), importer: importer, source_dir: File.dirname(src_path))
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
    low = lowering(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: File.dirname(src_path),
      debug_mode: true
    )
    [low, result]
  end

  def lower_fixture_mir(path)
    low, result = compile_fixture_lowering(path)
    low.lower_program(result.ast)
  end

  def lower_fixture_program(path)
    emit(lower_fixture_mir(path))
  end

  def expect_checker_clean(mir_program, strict: true)
    errors = MIRChecker.new.check_program!(mir_program, strict: strict)
    expect(errors).to be_empty
  end

  def collect_mir_nodes(root, klass)
    seen = {}
    nodes = []
    visit = nil
    visit = lambda do |obj|
      return if obj.nil?
      if obj.is_a?(Array)
        obj.each { |v| visit.call(v) }
        return
      end
      if obj.is_a?(Hash)
        obj.each { |k, v| visit.call(k); visit.call(v) }
        return
      end
      return unless obj.class.name&.start_with?("MIR::")
      oid = obj.object_id
      return if seen[oid]
      seen[oid] = true
      nodes << obj if obj.is_a?(klass)
      obj.each_pair { |_name, value| visit.call(value) } if obj.respond_to?(:each_pair)
      obj.instance_variables.each { |ivar| visit.call(obj.instance_variable_get(ivar)) }
    end
    visit.call(root)
    nodes
  end

  describe "task profile helpers" do
    it "injects profile fields into empty and non-empty task configs" do
      low = lowering

      expect(low.send(:task_config_with_profile, ".{}", 9, :parallel)).to eq(".{ .profile_site_id = 9, .profile_dispatch = 2 }")
      expect(low.send(:task_config_with_profile, ".{ .stack_size = .Large }", 4, :shared))
        .to eq(".{ .stack_size = .Large , .profile_site_id = 4, .profile_dispatch = 3 }")
    end

    it "maps unknown dispatches to local and emits profile comments" do
      low = lowering

      expect(low.send(:profile_dispatch_id, :unexpected)).to eq(1)
      expect(low.send(:bg_profile_site_comment, 5, 12, 3, :unexpected, :stack))
        .to eq("// CLEAR_PROFILE_TASK_SITE id=5 kind=BG line=12 column=3 dispatch=unexpected form=stack")
    end

    it "routes parallel fiber spawn through spawnBest" do
      low = lowering

      out = low.send(:fiber_spawn_call_zig, "__rt", "__Worker", "__worker", ".{}", :parallel)

      expect(out).to include("CheatHeader.spawnBest")
      expect(out).to include("&__Worker.run")
      expect(out).to include("__worker")
    end
  end

  # =========================================================================
  # Old MIR translation
  # =========================================================================

  describe "old MIR node translation" do
    it "translates MIR::Drop to MIR::Cleanup" do
      entry = { kind: :list, zig_type: "ArrayList(i64)", alloc: :frame, has_moved_guard: false }
      drop = MIR::Drop.new(tok, "items", :list, :frame, false, nil, nil, nil)
      drop.cleanup_entry = entry

      l = lowering
      result = l.lower(drop)
      expect(result).to be_a(MIR::Cleanup)
      expect(result.name).to eq("items")
      expect(result.cleanup_entry).to eq(entry)
    end

    it "translates MIR::SuppressCleanup to MIR::MoveMark" do
      suppress = MIR::SuppressCleanup.new(tok, "buf")
      result = lowering.lower(suppress)
      expect(result).to be_a(MIR::MoveMark)
      expect(result.name).to eq("buf")
      expect(emit(result)).to eq("buf_moved = true;")
    end

    it "translates MIR::Alloc to MIR::AllocMark" do
      alloc = MIR::Alloc.new(tok, "x", :list, :heap)
      result = lowering.lower(alloc)
      expect(result).to be_a(MIR::AllocMark)
      expect(result.name).to eq("x")
      expect(result.alloc).to eq(:heap)
      expect(emit(result)).to be_nil
    end

    it "translates MIR::Return to MIR::ReturnMark" do
      ret = MIR::Return.new(tok, ["x", "y"])
      result = lowering.lower(ret)
      expect(result).to be_a(MIR::ReturnMark)
      expect(result.escaped_vars).to eq(["x", "y"])
      expect(emit(result)).to be_nil
    end

    it "translates MIR::ReassignCleanup to MIR::ReassignMark" do
      rc = MIR::ReassignCleanup.new(tok, "buf", :heap)
      result = lowering.lower(rc)
      expect(result).to be_a(MIR::ReassignMark)
      expect(result.name).to eq("buf")
    end

    it "translates MIR::Promote to MIR::EscapePromote" do
      promote = MIR::Promote.new(tok, "items", "ArrayListUnmanaged(i64)", :list, nil, "i64")
      result = lowering.lower(promote)
      expect(result).to be_a(MIR::EscapePromote)
      expect(result.name).to eq("items")
      expect(result.strategy).to eq(:list)
      expect(result.zig_type).to eq("ArrayListUnmanaged(i64)")
      expect(result.elem_type).to eq("i64")
      zig = emit(result)
      expect(zig).to include("promoteList")
    end
  end

  describe "#apply_container_promote_zig" do
    it "uses the bare pointee type for promoted values" do
      zig = lowering.send(:apply_container_promote_zig, "val", "rt", "*Value")
      expect(zig).to include("CheatLib.promote(Value, rt, &__prm)")
      expect(zig).not_to include("CheatLib.promote(*Value")
    end
  end

  describe "#emit_builtin" do
    it "passes a bare type name through to dupeUnionValue unchanged" do
      mir = lowering.send(
        :emit_builtin,
        :dupeUnionValue,
        [MIR::Ident.new("Value"), MIR::Ident.new("val"), MIR::Ident.new("rt.heapAlloc()")]
      )
      zig = emit(mir)
      expect(zig).to eq("try CheatLib.dupeUnionValue(Value, val, rt.heapAlloc())")
    end
  end

  # =========================================================================
  # Literals
  # =========================================================================

  describe "literals" do
    it "lowers string literal" do
      node = make_lit(:STRING, "hello")
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Lit)
      expect(emit(result)).to eq('"hello"')
    end

    it "escapes string literal special chars" do
      node = make_lit(:STRING, "line\nnext")
      result = lowering.lower(node)
      expect(emit(result)).to eq('"line\\nnext"')
    end

    it "escapes backslash in string literal to two backslashes" do
      node = make_lit(:STRING, "\\")
      result = lowering.lower(node)
      expect(emit(result)).to eq('"\\\\"')
    end

    it "gsub block form: backslash in string not mangled by eql builtin substitution" do
      # Ruby gsub(pattern, string) mangles \\ to \ in the replacement.
      # Using gsub(pattern) { string } avoids this. Regression test.
      # When a string literal containing a backslash is used as an arg to a builtin
      # (like CheatLib.eql), the Zig output must contain "\\\\" (escaped backslash),
      # not "\\"" (escaped double-quote, which is a Zig syntax error).
      backslash_node = make_lit(:STRING, "\\")
      backslash_node.full_type = :String

      id_s = AST::Identifier.new(tok, "s")
      id_s.full_type = :String
      id_i = AST::Identifier.new(tok, "i")
      id_i.full_type = :Int64

      # charAt(s, i) == "\\"
      charat = AST::FuncCall.new(tok, "charAt", [id_s, id_i])
      charat.full_type = :String
      charat.matched_stdlib_def = STD_LIB["charAt"].first
      eq_node = AST::BinaryOp.new(tok, charat, :EQ, backslash_node)
      eq_node.full_type = :Boolean
      eq_node.left.full_type = :String

      l = lowering
      result = l.lower(eq_node)
      zig = emit(result)
      expect(zig).to include('"\\\\"')
      expect(zig).not_to include('"\\"")')
    end

    it "lowers integer literal" do
      node = make_lit(:NUMBER, 42, full_type: :Int64)
      node.coerced_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Lit)
      expect(emit(result)).to eq("42")
    end

    it "lowers float literal" do
      node = make_lit(:NUMBER, 3.14)
      result = lowering.lower(node)
      expect(emit(result)).to eq("3.14")
    end

    it "lowers float literal with integer value" do
      node = make_lit(:NUMBER, 5.0)
      result = lowering.lower(node)
      expect(emit(result)).to eq("5.0")
    end

    it "lowers boolean literal" do
      node = make_lit(:BOOLEAN, true)
      result = lowering.lower(node)
      expect(emit(result)).to eq("true")
    end

    it "lowers nil literal" do
      node = make_lit(:NIL, nil)
      result = lowering.lower(node)
      expect(emit(result)).to eq("null")
    end

    it "lowers i8 literal with cast" do
      node = make_lit(:INT8, 7)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Cast)
      expect(emit(result)).to eq("@as(i8, 7)")
    end

    it "lowers i32 literal with cast" do
      node = make_lit(:INT32, 100)
      result = lowering.lower(node)
      expect(emit(result)).to eq("@as(i32, 100)")
    end

    it "lowers u64 literal with cast" do
      node = make_lit(:UINT64, 999)
      result = lowering.lower(node)
      expect(emit(result)).to eq("@as(u64, 999)")
    end

    it "lowers f32 literal with cast" do
      node = make_lit(:FLOAT32, 2.5)
      result = lowering.lower(node)
      expect(emit(result)).to eq("@as(f32, 2.5)")
    end

    it "lowers INT64 literal" do
      node = make_lit(:INT64, 100)
      result = lowering.lower(node)
      expect(emit(result)).to eq("100")
    end
  end

  # =========================================================================
  # Identifiers
  # =========================================================================

  describe "identifiers" do
    it "lowers simple identifier" do
      node = make_id("count")
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("count")
    end

    it "lowers identifier with bang suffix" do
      node = make_id("push!")
      result = lowering.lower(node)
      expect(emit(result)).to eq("push")
    end

    it "lowers identifier with question mark" do
      node = make_id("empty?")
      result = lowering.lower(node)
      expect(emit(result)).to eq("empty")
    end

    it "renames main to clearMain" do
      node = make_id("main")
      result = lowering.lower(node)
      expect(emit(result)).to eq("clearMain")
    end
  end

  # =========================================================================
  # Unary operations
  # =========================================================================

  describe "unary operations" do
    it "lowers NOT" do
      inner = make_lit(:BOOLEAN, true)
      node = AST::UnaryOp.new(tok, :NOT, inner)
      node.full_type = :Boolean
      result = lowering.lower(node)
      expect(result).to be_a(MIR::UnaryOp)
      expect(emit(result)).to eq("!true")
    end

    it "lowers negation" do
      inner = make_lit(:NUMBER, 5.0)
      node = AST::UnaryOp.new(tok, :SUB, inner)
      node.full_type = :Number
      result = lowering.lower(node)
      expect(emit(result)).to eq("-5.0")
    end
  end

  # =========================================================================
  # Binary operations
  # =========================================================================

  describe "binary operations" do
    it "lowers simple addition (float)" do
      left = make_lit(:NUMBER, 1.5)
      right = make_lit(:NUMBER, 2.5)
      node = make_binop(left, :ADD, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BinOp)
      expect(emit(result)).to eq("(1.5 + 2.5)")
    end

    it "lowers integer addition with checked math" do
      left = make_id("a", full_type: :Int64)
      right = make_id("b", full_type: :Int64)
      node = make_binop(left, :ADD, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      expect(result.stdlib_def.emit.borrows).to eq(:all)
      expect(emit(result)).to eq("CheatLib.intAdd(a, b)")
    end

    it "lowers comparison" do
      left = make_id("x")
      right = make_lit(:NUMBER, 10.0)
      node = make_binop(left, :GT, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BinOp)
      expect(emit(result)).to eq("(x > 10.0)")
    end

    it "lowers string equality" do
      left = make_id("name", full_type: :String)
      right = make_lit(:STRING, "alice")
      node = make_binop(left, :EQ, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      expect(result.stdlib_def.emit.borrows).to eq(:all)
      expect(emit(result)).to include("CheatLib.eql(name,")
    end

    it "lowers string inequality" do
      left = make_id("a", full_type: :String)
      right = make_id("b", full_type: :String)
      node = make_binop(left, :NEQ, right)
      result = lowering.lower(node)
      expect(emit(result)).to include("!CheatLib.eql(a, b)")
    end

    it "lowers wrapping add" do
      left = make_id("a")
      right = make_id("b")
      node = make_binop(left, :WRAP_ADD, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      expect(result.stdlib_def.emit.borrows).to eq(:all)
      expect(emit(result)).to eq("CheatLib.wrapAdd(a, b)")
    end

    it "lowers checked mul" do
      left = make_id("a")
      right = make_id("b")
      node = make_binop(left, :CHECK_MUL, right)
      result = lowering.lower(node)
      expect(emit(result)).to eq("CheatLib.checkMul(a, b)")
    end

    it "lowers integer division to @divTrunc" do
      left = make_id("a", full_type: :Int64)
      right = make_id("b", full_type: :Int64)
      node = make_binop(left, :DIV, right)
      result = lowering.lower(node)
      # Routed through the builtin registry (:intDiv) so the :bc target can
      # dispatch to DIV_I64. Zig emission still renders @divTrunc(a, b).
      expect(emit(result)).to include("@divTrunc(a, b)")
    end

    it "lowers signed modulo to @mod" do
      left = make_id("a", full_type: :Int64)
      right = make_id("b", full_type: :Int64)
      node = make_binop(left, :MOD, right)
      result = lowering.lower(node)
      expect(emit(result)).to include("@mod(a, b)")
    end

    it "lowers boolean AND" do
      left = make_lit(:BOOLEAN, true)
      right = make_lit(:BOOLEAN, false)
      node = make_binop(left, :AND, right)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BinOp)
      expect(emit(result)).to eq("(true and false)")
    end
  end

  # =========================================================================
  # Field and index access
  # =========================================================================

  describe "field and index access" do
    it "lowers field access" do
      target = make_id("user", full_type: :User)
      node = AST::GetField.new(tok, target, "name")
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::FieldGet)
      expect(emit(result)).to eq("user.name")
    end

    it "falls back to getAt for local dynamic-array index access" do
      target = make_id("items", full_type: :"Int64[]")
      index = make_lit(:NUMBER, 0, full_type: :Int64)
      index.coerced_type = :Int64
      node = AST::GetIndex.new(tok, target, index)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      expect(emit(result)).to eq("CheatLib.getAt(items, 0)")
    end

    it "lowers parameter slice index access directly" do
      target = make_id("items", full_type: :"Int64[]")
      index = make_lit(:NUMBER, 0, full_type: :Int64)
      index.coerced_type = :Int64
      node = AST::GetIndex.new(tok, target, index)
      node.full_type = :Int64
      l = lowering
      l.instance_variable_set(:@current_fn_param_names, ["items"])
      result = l.lower(node)
      expect(result).to be_a(MIR::IndexGet)
      expect(emit(result)).to eq("items[@as(usize, @intCast(0))]")
    end

    it "lowers string length to direct len" do
      target = make_id("items", full_type: :String)
      node = AST::MethodCall.new(tok, target, "length", [])
      node.full_type = :Int64
      node.zig_pattern = "CheatLib.len({0})"
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Cast)
      expect(emit(result)).to eq("@as(i64, @intCast(items.len))")
    end

    it "falls back to CheatLib.len for local dynamic-array length" do
      target = make_id("items", full_type: :"Int64[]")
      node = AST::MethodCall.new(tok, target, "length", [])
      node.full_type = :Int64
      node.zig_pattern = "CheatLib.len({0})"
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      expect(emit(result)).to eq("CheatLib.len(items)")
    end

    it "lowers parameter array length via the polymorphic CheatLib.len helper" do
      # Defers to runtime polymorphism: CheatLib.len uses comptime @hasField
      # to dispatch ArrayList (.items.len) vs slice (.len). The lowering does
      # NOT re-derive container shape from "is_param" anymore.
      target = make_id("items", full_type: :"Int64[]")
      node = AST::MethodCall.new(tok, target, "length", [])
      node.full_type = :Int64
      node.zig_pattern = "CheatLib.len({0})"
      l = lowering
      l.instance_variable_set(:@current_fn_param_names, ["items"])
      result = l.lower(node)
      expect(emit(result)).to eq("CheatLib.len(items)")
    end
  end

  # =========================================================================
  # Type definitions
  # =========================================================================

  describe "type definitions" do
    it "lowers enum definition" do
      node = AST::EnumDef.new(tok, "Direction", [:North, :South, :East, :West], nil)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::EnumDef)
      expect(emit(result)).to eq("const Direction = enum { North, South, East, West };")
    end

    it "lowers simple struct definition" do
      fields = { name: { type: :String }, age: { type: :Int64 } }
      node = AST::StructDef.new(tok, "User", fields, nil, nil)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::StructDef)
      zig = emit(result)
      expect(zig).to include("const User = struct {")
      expect(zig).to include("name: []const u8")
      expect(zig).to include("age: i64")
    end

    it "lowers generic struct to FnDef returning anonymous StructDef" do
      fields = { value: { type: :T } }
      node = AST::StructDef.new(tok, "Box", fields, nil, ["T"])
      result = lowering.lower(node)
      expect(result).to be_a(MIR::FnDef)
      expect(result.comptime_params).to eq(["comptime T: type"])
      expect(result.ret_type).to eq("type")
      zig = emit(result)
      expect(zig).to include("fn Box(comptime T: type)")
      expect(zig).to include("return struct {")
    end

    it "lowers union definition with unit and payload variants" do
      variants = { Ok: :Int64, Err: :String, Empty: nil }
      node = AST::UnionDef.new(tok, "Result", variants, nil)
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("union(enum)")
      expect(zig).to include("Ok: i64")
      expect(zig).to include("Err: []const u8")
      expect(zig).to include("Empty: void")
    end

    it "filters Zig type definition blocks by visible imported names" do
      source = <<~ZIG
        const Keep = struct {
            value: i64,
        };
        const Drop = enum {
            A,
        };
        const AlsoKeep = union(enum) {
            One: i64,
        };
      ZIG

      filtered = lowering.send(:filter_zig_blocks, source, Set["Keep", "AlsoKeep"])

      expect(filtered).to include("const Keep")
      expect(filtered).to include("const AlsoKeep")
      expect(filtered).not_to include("const Drop")
    end

    it "emits only public or same-directory package-visible imported type definitions once" do
      pub_struct = AST::StructDef.new(tok, "PubThing", {}, :pub, nil)
      pkg_enum = AST::EnumDef.new(tok, "PkgThing", [:A], nil)
      private_struct = AST::StructDef.new(tok, "PrivateThing", {}, :private, nil)
      inline_union = AST::UnionDef.new(tok, "Value", { Pair: { kind: :inline_struct, fields: {} } }, :pub)
      ast = AST::Program.new(tok, [pub_struct, pkg_enum, private_struct, inline_union])
      type_defs = <<~ZIG
        const PubThing = struct {};
        const PkgThing = enum { A };
        const PrivateThing = struct {};
        const Value = union(enum) { Pair: Value_Pair };
        const Value_Pair = struct {};
      ZIG
      mod = ModuleImporter::CompiledModule.new(ast, nil, nil, Dir.pwd, {}, {}, {}, type_defs)
      low = lowering

      same_dir_defs = low.send(:visible_type_defs, mod, same_dir: true)
      second_pass = low.send(:visible_type_defs, mod, same_dir: true)
      other_dir_defs = lowering.send(:visible_type_defs, mod, same_dir: false)

      expect(same_dir_defs).to include("const PubThing")
      expect(same_dir_defs).to include("const PkgThing")
      expect(same_dir_defs).to include("const Value")
      expect(same_dir_defs).to include("const Value_Pair")
      expect(same_dir_defs).not_to include("const PrivateThing")
      expect(second_pass).to be_nil
      expect(other_dir_defs).to include("const PubThing")
      expect(other_dir_defs).not_to include("const PkgThing")
    end
  end

  # =========================================================================
  # Declarations
  # =========================================================================

  describe "declarations" do
    it "lowers immutable var decl" do
      value = make_lit(:NUMBER, 42, full_type: :Int64)
      value.coerced_type = :Int64
      node = AST::VarDecl.new(tok, "x", nil, value, false)
      node.full_type = :Int64
      node.var_used = true
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Let)
      expect(result.mutable).to eq(false)
      zig = emit(result)
      expect(zig).to include("const x")
      expect(zig).to include("42")
    end

    it "lowers mutable var decl" do
      value = make_lit(:NUMBER, 0, full_type: :Int64)
      value.coerced_type = :Int64
      node = AST::VarDecl.new(tok, "count", nil, value, true)
      node.full_type = :Int64
      node.var_used = true
      node.var_mutated = true
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Let)
      expect(result.mutable).to eq(true)
      zig = emit(result)
      expect(zig).to start_with("var count")
    end

    it "lowers unused const with suppression" do
      value = make_lit(:NUMBER, 1.0)
      node = AST::VarDecl.new(tok, "unused", nil, value, false)
      node.full_type = :Number
      node.var_used = false
      result = lowering.lower(node)
      expect(result.suppression).to eq("_ = unused;")
    end

    it "lowers BindExpr in decl mode" do
      value = make_lit(:STRING, "hello")
      node = AST::BindExpr.new(tok, "greeting", nil, value)
      node.full_type = :String
      node.var_used = true
      node.instance_variable_set(:@mode, :decl)
      def node.mode; @mode; end
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Let)
      expect(result.name).to eq("greeting")
    end

    it "lowers BindExpr in assign mode" do
      value = make_lit(:NUMBER, 5.0)
      node = AST::BindExpr.new(tok, "x", nil, value)
      node.full_type = :Number
      node.instance_variable_set(:@mode, :assign)
      def node.mode; @mode; end
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Set)
      expect(emit(result)).to eq("x = 5.0;")
    end

    it "lowers BindExpr assign with reassign cleanup" do
      value = make_lit(:STRING, "new")
      node = AST::BindExpr.new(tok, "buf", nil, value)
      node.full_type = :String
      node.instance_variable_set(:@mode, :assign)
      def node.mode; @mode; end
      node.instance_variable_set(:@reassign_cleanup, { zig_type: "[]const u8", alloc: :heap })
      def node.reassign_cleanup; @reassign_cleanup; end
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ReassignWithCleanup)
      zig = emit(result)
      expect(zig).to include("CheatLib.cleanup")
      expect(zig).to include("buf = __new_buf")
    end

    it "lowers Assignment" do
      target = make_id("x")
      value = make_lit(:NUMBER, 10.0)
      node = AST::Assignment.new(tok, "x", value)
      node.full_type = :Number
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Set)
      expect(emit(result)).to eq("x = 10.0;")
    end
  end

  describe "indexed assignment lowering" do
    it "lowers synthetic index targets without type info as direct Set(IndexGet)" do
      target = AST::Identifier.new(tok, "soa_items")
      index = make_lit(:NUMBER, 2, full_type: :Int64)
      index.coerced_type = :Int64
      value = make_lit(:NUMBER, 9, full_type: :Int64)
      value.coerced_type = :Int64
      get_index = AST::GetIndex.new(tok, target, index)
      node = AST::Assignment.new(tok, get_index, value)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::Set)
      expect(result.target).to be_a(MIR::IndexGet)
      expect(emit(result)).to eq("soa_items[2] = 9;")
    end

    it "uses structural IndexGet assignment for the bytecode backend" do
      low, assignment = compile_first_assignment(<<~CLEAR, target: :bc)
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["a"] = 1_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::Set)
      expect(result.target).to be_a(MIR::IndexGet)
      expect(emit(result)).to eq('m["a"] = 1;')
    end

    it "lowers raw fixed-size array writes to native indexed Set with usize cast" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[4] = [0_i64, 0_i64, 0_i64, 0_i64];
          xs[1_i64] = 7_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::Set)
      expect(result.target).to be_a(MIR::IndexGet)
      expect(result.target.index).to be_a(MIR::Cast)
      expect(emit(result)).to eq("xs[@as(usize, @intCast(1))] = 7;")
    end

    it "lowers string HashMap writes to structured ShardedMapPut" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["a"] = 1_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ShardedMapPut)
      expect(result.map_kind).to eq(:string_map)
      expect(result.key_zig).to be_nil
      expect(result.val_zig).to be_nil
      expect(result.template_kind).to eq(:zig)
    end

    it "carries numeric HashMap key/value Zig types into ShardedMapPut" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64, Float64> = {};
          m[3_i64] = 4.5;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ShardedMapPut)
      expect(result.map_kind).to eq(:numeric_map)
      expect(result.key_zig).to eq("i64")
      expect(result.val_zig).to eq("f64")
    end

    it "uses shard-direct placeholders when lowering inside a shard context" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE m: HashMap<Int64> = {};
          m["a"] = 1_i64;
          RETURN;
        END
      CLEAR
      low.shard_context = { map: "m", idx: "__sh.idx", key: "__sh.key" }

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ShardedMapPut)
      expect(result.shard_idx).to be_a(MIR::Ident)
      expect(result.shard_key).to be_a(MIR::Ident)
      expect(result.shard_idx.name).to eq("__sh.idx")
      expect(result.shard_key.name).to eq("__sh.key")
      expect(result.template_kind).to eq(:shard_direct_zig)
    end

    it "keeps list writes on the indexed template path with target metadata" do
      low, assignment = compile_first_assignment(<<~CLEAR)
        FN main() RETURNS Void ->
          MUTABLE xs: Int64[]@list = [];
          xs[0_i64] = 9_i64;
          RETURN;
        END
      CLEAR

      result = low.lower(assignment)

      expect(result).to be_a(MIR::ExprStmt)
      expect(result.expr).to be_a(MIR::InlineZig)
      expect(result.expr.reason).to eq("index_set")
      expect(result.expr.target_var).to eq("xs")
      expect(emit(result)).to include("CheatLib.setAt(xs, 0, 9)")
    end

    it "falls back to setAt for unknown indexable receiver types" do
      target = make_id("bag", full_type: :Bag)
      index = make_lit(:INT64, 0, full_type: :Int64)
      value = make_lit(:INT64, 42, full_type: :Int64)
      get_index = AST::GetIndex.new(tok, target, index)
      node = AST::Assignment.new(tok, get_index, value)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ExprStmt)
      expect(emit(result)).to eq("CheatLib.setAt(bag, 0, 42);")
    end

    it "promotes container values before indexed storage when requested" do
      target = make_id("items", full_type: :"Value[]@list")
      index = make_lit(:INT64, 0, full_type: :Int64)
      value = make_id("value", full_type: :Value)
      get_index = AST::GetIndex.new(tok, target, index)
      node = AST::Assignment.new(tok, get_index, value)
      node.container_promote_zig_type = "Value"

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ExprStmt)
      expect(result.expr).to be_a(MIR::InlineZig)
      expect(result.expr.stdlib_def.emit.value_transforms).not_to be_nil
      expect(emit(result)).to include("CheatLib.setAt(items, 0,")
    end

    it "cleans up overwritten list elements that own heap fields before indexed storage" do
      target = make_id("items", full_type: Type.new(:"Point[]", collection: :list))
      index = make_lit(:INT64, 0, full_type: :Int64)
      value = make_id("next_point", full_type: :Point)
      node = AST::Assignment.new(tok, AST::GetIndex.new(tok, target, index), value)
      heap_string = Type.new(:String)
      heap_string.provenance = :heap
      point_schema = Schemas::StructSchema.new(fields: { "name" => heap_string })

      result = lowering(struct_schemas: { Point: point_schema }).lower(node)

      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("CheatLib.cleanupAt(Point, items, rt.heapAlloc(), 0)")
      expect(zig).to include("CheatLib.setAt(items, 0, next_point)")
    end
  end

  # =========================================================================
  # Control flow
  # =========================================================================

  describe "control flow" do
    it "lowers if statement" do
      cond = make_lit(:BOOLEAN, true)
      then_body = make_lit(:NUMBER, 1.0)
      node = AST::IfStatement.new(tok, cond, [then_body], nil, nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::IfStmt)
      zig = emit(result)
      expect(zig).to include("if (true)")
      expect(zig).to include("1.0")
    end

    it "lowers if/else statement" do
      cond = make_lit(:BOOLEAN, false)
      then_stmt = make_lit(:NUMBER, 1.0)
      else_stmt = make_lit(:NUMBER, 2.0)
      node = AST::IfStatement.new(tok, cond, [then_stmt], [else_stmt], nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("if (false)")
      expect(zig).to include("} else {")
    end

    it "lowers while loop" do
      cond = make_lit(:BOOLEAN, true)
      body_stmt = make_lit(:NUMBER, 1.0)
      node = AST::WhileLoop.new(tok, cond, [body_stmt], nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::WhileStmt)
      zig = emit(result)
      expect(zig).to include("while (true)")
    end

    it "lowers return with value" do
      value = make_lit(:NUMBER, 42, full_type: :Int64)
      value.coerced_type = :Int64
      node = AST::ReturnNode.new(tok, value)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ReturnStmt)
      expect(emit(result)).to eq("return 42;")
    end

    it "lowers bare return" do
      node = AST::ReturnNode.new(tok, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(emit(result)).to eq("return;")
    end

    it "lowers break" do
      node = AST::BreakNode.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BreakStmt)
      expect(emit(result)).to eq("break;")
    end

    it "lowers continue" do
      node = AST::ContinueNode.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ContinueStmt)
      expect(emit(result)).to eq("continue;")
    end

    it "lowers for-each" do
      coll = make_id("items", full_type: :List)
      body_stmt = make_lit(:NUMBER, 1.0)
      node = AST::ForEach.new(tok, "item", coll, [body_stmt], nil, false)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ForStmt)
      zig = emit(result)
      expect(zig).to include("for")
      expect(zig).to include("|item|")
    end

    it "lowers pass statement" do
      node = AST::PassStmt.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Noop)
    end
  end

  # =========================================================================
  # Match statement
  # =========================================================================

  describe "match statement" do
    it "lowers enum match to SwitchStmt" do
      expr = make_id("dir", full_type: :Direction)

      case_val = AST::GetField.new(tok, make_id("Direction"), "North")
      case_val.full_type = :Direction
      case_body = [make_lit(:NUMBER, 1.0)]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      l = lowering(enum_schemas: { Direction: [:North, :South] })
      result = l.lower(node)
      expect(result).to be_a(MIR::SwitchStmt)
      zig = emit(result)
      expect(zig).to include("switch (dir)")
      expect(zig).to include(".North")
    end

    it "lowers union match to IfChain" do
      expr = make_id("result", full_type: :Result)

      case_val = AST::GetField.new(tok, make_id("Result"), "Ok")
      case_val.full_type = :Result
      case_body = [make_lit(:NUMBER, 1.0)]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      l = lowering(union_schemas: { Result: { Ok: :Int64, Err: :String } })
      result = l.lower(node)
      expect(result).to be_a(MIR::IfChain)
      zig = emit(result)
      expect(zig).to include("std.meta.activeTag")
      expect(zig).to include(".Ok")
    end

    it "lowers string match to IfChain with strEql" do
      expr = make_id("cmd", full_type: :String)

      case_val = make_lit(:STRING, "quit")
      case_body = [make_lit(:NUMBER, 0, full_type: :Int64)]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void
      node.string_match = true

      result = lowering.lower(node)
      expect(result).to be_a(MIR::IfChain)
      zig = emit(result)
      expect(zig).to include("CheatLib.strEql")
    end

    it "lowers match with default case" do
      expr = make_id("x", full_type: :Int64)

      case_val = make_lit(:INT64, 1)
      case_body = [make_lit(:STRING, "one")]
      default_body = [make_lit(:STRING, "other")]

      cases = [AST::MatchCase.new(kind: :eq, value: case_val, body: case_body)]
      node = AST::MatchStatement.new(tok, expr, cases, default_body, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::SwitchStmt)
      zig = emit(result)
      expect(zig).to include("else =>")
    end

    it "lowers integer match arms with extra values into a shared switch prong" do
      expr = make_id("x", full_type: :Int64)
      cases = [AST::MatchCase.new(
        kind: :eq,
        value: make_lit(:INT64, 1, full_type: :Int64),
        extra_values: [make_lit(:INT64, 2, full_type: :Int64), make_lit(:INT64, 3, full_type: :Int64)],
        body: [make_lit(:STRING, "small")]
      )]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering.lower(node)

      expect(result).to be_a(MIR::SwitchStmt)
      expect(result.arms.first[:pattern]).to eq("1, 2, 3")
      expect(result.default_body).to eq([])
    end

    it "adds an empty default for non-exhaustive enum switches" do
      expr = make_id("dir", full_type: :Direction)
      north = AST::GetField.new(tok, make_id("Direction"), "North")
      north.full_type = :Direction
      node = AST::MatchStatement.new(tok, expr, [AST::MatchCase.new(kind: :eq, value: north, body: [make_lit(:NUMBER, 1.0)])], nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering(enum_schemas: { Direction: [:North, :South] }).lower(node)

      expect(result).to be_a(MIR::SwitchStmt)
      expect(result.default_body).to eq([])
    end

    it "lowers expression-mode match to a BlockExpr" do
      expr = make_id("x", full_type: :Int64)
      cases = [AST::MatchCase.new(kind: :eq, value: make_lit(:INT64, 1, full_type: :Int64), body: [make_lit(:INT64, 10, full_type: :Int64)])]
      node = AST::MatchStatement.new(tok, expr, cases, [make_lit(:INT64, 0, full_type: :Int64)], nil, nil, true, nil)
      node.full_type = :Int64
      node.expr_mode = true

      result = lowering.lower(node)

      expect(result).to be_a(MIR::BlockExpr)
      expect(result.body.first).to be_a(MIR::SwitchStmt)
    end

    it "expands multi-variant union binding arms so payload reads match the active tag" do
      expr = make_id("result", full_type: :Result)
      ok = AST::GetField.new(tok, make_id("Result"), "Ok")
      ok.full_type = :Result
      err = AST::GetField.new(tok, make_id("Result"), "Err")
      err.full_type = :Result
      cases = [AST::MatchCase.new(
        kind: :eq,
        value: ok,
        extra_values: [err],
        binding: "payload",
        body: [make_lit(:NUMBER, 1.0)]
      )]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering(union_schemas: { Result: { Ok: :Int64, Err: :Int64 } }).lower(node)

      expect(result).to be_a(MIR::IfChain)
      expect(result.branches.length).to eq(2)
      expect(result.branches[0][:body].first).to be_a(MIR::Let)
      expect(result.branches[0][:body].first.init.field).to eq("Ok")
      expect(result.branches[1][:body].first.init.field).to eq("Err")
    end

    it "lowers WHEN guard arms before subject equality dispatch" do
      expr = make_id("x", full_type: :Int64)
      guard = make_lit(:BOOLEAN, true, full_type: :Boolean)
      cases = [AST::MatchCase.new(kind: :when, value: guard, body: [make_lit(:STRING, "guarded")])]
      node = AST::MatchStatement.new(tok, expr, cases, nil, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering.lower(node)

      expect(result).to be_a(MIR::IfChain)
      expect(result.branches.first[:cond]).to be_a(MIR::Lit)
      expect(emit(result.branches.first[:cond])).to eq("true")
    end
  end

  # =========================================================================
  # Memory / capability expressions
  # =========================================================================

  describe "memory operations" do
    it "lowers COPY of string" do
      inner = make_id("s", full_type: :String)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:string)
      expect(emit(result)).to include("dupe(u8,")
    end

    it "lowers COPY passthrough for value types" do
      inner = make_id("x", full_type: :Int64)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:passthrough)
      zig = emit(result)
      expect(zig).to include("blk_copy_value")
      expect(zig).to include("const __src = x")
      expect(zig).to include("break :blk_copy_value __src")
    end

    it "lowers COPY of sync values as full-value dupes" do
      locked_type = Type.new(:Counter, sync: :locked)
      inner = make_id("c", full_type: locked_type)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = locked_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:full_value)
      expect(emit(result)).to eq("try CheatLib.dupeValue(@TypeOf(c), c, rt.heapAlloc())")
    end

    it "emits cleanup for declarations initialized from COPY of sync values" do
      locked_type = Type.new(:Counter, sync: :locked)
      inner = make_id("src", full_type: locked_type)
      copy = AST::CopyNode.new(tok, inner)
      copy.full_type = locked_type

      node = AST::VarDecl.new(tok, "dst", nil, copy, false)
      node.full_type = locked_type
      node.var_used = true

      result = lowering.lower(node)
      expect(result).to be_a(Array)
      expect(result[0]).to be_a(MIR::AllocMark)
      expect(result[1]).to be_a(MIR::Let)
      expect(result[1].mutable).to be true
      expect(result[1].init).to be_a(MIR::DeepCopy)
      expect(result[1].init.strategy).to eq(:full_value)
      expect(result[2]).to be_a(MIR::Cleanup)
      expect(result[2].cleanup_entry).to include(kind: :locked, alloc: :heap)
    end

    it "lowers MOVE as identity" do
      inner = make_id("handle", full_type: :Resource)
      node = AST::MoveNode.new(tok, inner)
      node.full_type = :Resource
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("handle")
    end

    it "lowers CLONE of a shared handle to Arc retain" do
      source_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::CloneNode.new(tok, inner)
      node.full_type = source_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RcRetain)
      expect(result.func).to eq("arcRetain")
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to eq("CheatLib.arcRetain(Box, box)")
    end

    it "lowers SHARE of a bare value to Arc creation" do
      inner = make_id("box", full_type: :Box)
      shared_type = Type.new(:Box, ownership: :shared)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = shared_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::CapWrap)
      expect(result.own_fn).to eq("arcCreate")
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to eq("try CheatLib.arcCreate(Box, rt.heapAlloc(), box)")
    end

    it "lowers SHARE of an existing shared handle to Arc retain" do
      source_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = source_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RcRetain)
      expect(result.func).to eq("arcRetain")
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to eq("CheatLib.arcRetain(Box, box)")
    end

    it "lowers SHARE of a multiowned handle to Rc-to-Arc promotion" do
      source_type = Type.new(:Box, ownership: :multiowned)
      shared_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = shared_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::SharePromote)
      expect(result.zig_base).to eq("Box")
      expect(emit(result)).to include("CheatLib.rcRelease(Box, rt.heapAlloc(), __share_src);")
    end

    it "records cleanup metadata for hoisted SharePromote allocations" do
      source_type = Type.new(:Box, ownership: :multiowned)
      shared_type = Type.new(:Box, ownership: :shared)
      inner = make_id("box", full_type: source_type)
      node = AST::ShareNode.new(tok, inner)
      node.full_type = shared_type

      promote = MIR::SharePromote.new(MIR::Ident.new("box"), "Box", :heap)
      l = lowering
      expect(l.send(:mir_allocates?, promote)).to be true
      entry = l.send(:hoist_cleanup_entry, promote, node)
      expect(entry).to include(kind: :rc, alloc: :heap, zig_type: "CheatLib.Arc(Box)")
    end

    it "lowers CLONE of a multiowned handle to Rc retain" do
      source_type = Type.new(:Box, ownership: :multiowned)
      inner = make_id("box", full_type: source_type)
      node = AST::CloneNode.new(tok, inner)
      node.full_type = source_type

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RcRetain)
      expect(result.func).to eq("rcRetain")
      expect(result.zig_base).to eq("Box")
    end

    it "lowers COPY of union" do
      inner = make_id("val", full_type: :Value)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :Value

      l = lowering(union_schemas: { Value: { Num: :Number, Str: :String } })
      result = l.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:union)
      expect(emit(result)).to include("dupeUnionValue")
    end

    it "lowers COPY of borrowed union using bare union type" do
      borrowed_union = Type.new(:Value)
      borrowed_union.ownership = :borrow
      inner = make_id("val", full_type: borrowed_union)
      node = AST::CopyNode.new(tok, inner)
      node.full_type = :Value

      l = lowering(union_schemas: { Value: { Num: :Number, Str: :String } })
      result = l.lower(node)
      expect(result).to be_a(MIR::DeepCopy)
      expect(result.strategy).to eq(:union)
      expect(result.zig_type).to eq("Value")
      expect(emit(result)).to eq("try CheatLib.dupeUnionValue(Value, val, rt.heapAlloc())")
    end
  end

  # =========================================================================
  # Struct literals
  # =========================================================================

  describe "struct literals" do
    it "lowers struct literal" do
      name_val = make_lit(:STRING, "alice")
      age_val = make_lit(:NUMBER, 30, full_type: :Int64)
      age_val.coerced_type = :Int64

      node = AST::StructLit.new(tok, "User", { name: name_val, age: age_val }, nil, nil)
      node.full_type = :User

      result = lowering.lower(node)
      expect(result).to be_a(MIR::StructInit)
      zig = emit(result)
      expect(zig).to include("User{")
      expect(zig).to include('.name = "alice"')
      expect(zig).to include(".age = 30")
    end

    it "lowers heap-allocated struct literal" do
      val = make_lit(:NUMBER, 1.0)
      node = AST::StructLit.new(tok, "Node", { value: val }, :heap, nil)
      node.full_type = :Node

      result = lowering.lower(node)
      expect(result).to be_a(MIR::HeapCreate)
      zig = emit(result)
      expect(zig).to include("create(Node)")
      expect(zig).to include(".value = 1.0")
    end
  end

  # =========================================================================
  # String concat
  # =========================================================================

  describe "string concatenation" do
    it "lowers StringConcat" do
      p1 = make_lit(:STRING, "hello ")
      p2 = make_id("name", full_type: :String)
      node = AST::StringConcat.new(tok, [p1, p2])
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ConcatStr)
      zig = emit(result)
      expect(zig).to include("std.mem.concat")
      expect(zig).to include('"hello "')
      expect(zig).to include("name")
    end
  end

  # =========================================================================
  # Range literal
  # =========================================================================

  describe "range literal" do
    it "lowers exclusive range" do
      s = make_lit(:NUMBER, 0, full_type: :Int64)
      s.coerced_type = :Int64
      e = make_lit(:NUMBER, 10, full_type: :Int64)
      e.coerced_type = :Int64
      node = AST::RangeLit.new(tok, s, e, false)
      node.full_type = Type.new(:"~Int64[]")
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RangeLit)
      zig = emit(result)
      expect(zig).to include("CheatLib.IntRange")
      expect(zig).to include(".start = 0")
      expect(zig).to include(".end = 10")
    end

    it "lowers inclusive range (adds 1 to end)" do
      s = make_lit(:NUMBER, 0, full_type: :Int64)
      s.coerced_type = :Int64
      e = make_lit(:NUMBER, 5, full_type: :Int64)
      e.coerced_type = :Int64
      node = AST::RangeLit.new(tok, s, e, true)
      node.full_type = Type.new(:"~Int64[]")
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("(5 + 1)")
    end
  end

  # =========================================================================
  # Assert and Raise
  # =========================================================================

  describe "assert and raise" do
    it "lowers assert" do
      cond = make_lit(:BOOLEAN, true)
      node = AST::Assert.new(tok, cond, "should be true")
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      expect(result.stdlib_def.emit.borrows).to eq(:all)
      expect(emit(result)).to include("CheatLib.assert(true,")
    end

    it "lowers raise" do
      msg = AST::Literal.new(tok, :String, "timed out")
      msg.full_type = :String
      node = AST::Raise.new(tok, :Transient, :Timeout, msg)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      code = emit(result)
      expect(code).to include('setError(.Transient, @intFromEnum(ErrorName.Timeout)')
      expect(code).to include("return error.CheatError")
    end

    it "lowers raise with no message" do
      node = AST::Raise.new(tok, :NotFound, nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      code = emit(result)
      # No specific type named -> None id (0) is emitted, message is "".
      expect(code).to include('setError(.NotFound, 0,')
      expect(code).to include("return error.CheatError")
    end
  end

  # =========================================================================
  # Optional unwrap
  # =========================================================================

  describe "optional unwrap" do
    it "lowers optional unwrap" do
      inner = make_id("maybe_val", full_type: :Int64)
      node = AST::OptionalUnwrap.new(tok, inner)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::OptionalUnwrap)
      expect(emit(result)).to eq("maybe_val.?")
    end
  end

  # =========================================================================
  # Block expression
  # =========================================================================

  describe "block expression" do
    it "lowers block expression" do
      body_stmt = make_lit(:NUMBER, 1.0)
      result_expr = make_lit(:NUMBER, 42, full_type: :Int64)
      result_expr.coerced_type = :Int64
      node = AST::BlockExpr.new(tok, [body_stmt], result_expr)
      node.full_type = :Int64

      result = lowering.lower(node)
      expect(result).to be_a(MIR::BlockExpr)
      zig = emit(result)
      expect(zig).to include("__blk_1:")
      expect(zig).to include("break")
    end
  end

  # =========================================================================
  # lower_body
  # =========================================================================

  describe "lower_body" do
    it "lowers array of statements" do
      stmts = [
        make_lit(:NUMBER, 1.0),
        make_lit(:NUMBER, 2.0),
      ]
      result = lowering.lower_body(stmts)
      lits = result.reject { |n| n.is_a?(MIR::Comment) }
      expect(lits.length).to eq(2)
      expect(lits.all? { |n| n.is_a?(MIR::Lit) }).to eq(true)
    end

    it "returns empty array for nil" do
      expect(lowering.lower_body(nil)).to eq([])
    end
  end

  # =========================================================================
  # End-to-end: lower then emit
  # =========================================================================

  describe "end-to-end lowering + emission" do
    it "lowers and emits a var decl with string literal" do
      value = make_lit(:STRING, "world")
      node = AST::VarDecl.new(tok, "greeting", nil, value, false)
      node.full_type = :String
      node.var_used = true
      mir = lowering.lower(node)
      zig = emit(mir)
      expect(zig).to eq('const greeting: []const u8 = "world";')
    end

    it "lowers and emits an if with binary condition" do
      left = make_id("x")
      right = make_lit(:NUMBER, 0.0)
      cond = make_binop(left, :GT, right)
      body = make_lit(:NUMBER, 1.0)

      node = AST::IfStatement.new(tok, cond, [body], nil, nil, nil)
      node.full_type = :Void
      mir = lowering.lower(node)
      zig = emit(mir)
      expect(zig).to include("if ((x > 0.0))")
    end
  end

  # =========================================================================
  # Phase 3: FunctionDef
  # =========================================================================

  describe "function definitions" do
    def make_fn(name, params: [], return_type: :Void, body: [], visibility: nil,
                needs_rt: true, can_fail: true, uses_frame: false, uses_alloc: false,
                type_params: nil, catch_clauses: nil, default_catch: nil, has_promotion: false)
      fn = AST::FunctionDef.new(tok, name, params, nil, return_type, nil, body,
                                 catch_clauses, default_catch, visibility, nil, uses_frame)
      fn.full_type = return_type
      fn.needs_rt = needs_rt
      fn.can_fail = can_fail
      fn.uses_alloc = uses_alloc
      fn.type_params = type_params
      fn.has_promotion = has_promotion
      fn
    end

    it "lowers simple void function" do
      ret = make_lit(:NIL, nil, full_type: :Void)
      body = [AST::ReturnNode.new(tok, nil).tap { |n| n.full_type = :Void }]
      fn = make_fn("greet", body: body)
      result = lowering.lower(fn)
      expect(result).to be_a(MIR::FnDef)
      expect(result.name).to eq("greet")
      expect(result.visibility).to eq(:private)
      zig = emit(result)
      expect(zig).to include("fn greet(rt: *Runtime)")
      expect(zig).to include("!void")
      expect(zig).to include("return;")
    end

    it "lowers pub function" do
      fn = make_fn("hello", visibility: :pub, body: [])
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to start_with("pub fn")
    end

    it "lowers function with params" do
      params = [{ name: "x", type: :Int64, mutable: false },
                { name: "y", type: :Number, mutable: false }]
      fn = make_fn("add", params: params, return_type: :Number)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("x: i64")
      expect(zig).to include("y: f64")
    end

    it "stack struct param uses anytype — SROA candidate, no const-ptr" do
      # Structs with no heap provenance live on the stack. Zig/LLVM SROAs them
      # into registers. Do NOT pass by *const T — that would prevent SROA.
      params = [{ name: "p", type: :Point, mutable: false }]
      l = lowering(struct_schemas: { Point: { x: { type: :Number }, y: { type: :Number } } })
      fn = make_fn("sum3", params: params)
      result = l.lower(fn)
      zig = emit(result)
      expect(zig).to include("p: anytype")
      expect(zig).not_to include("*const Point")
    end

    it "includes frame save/restore for value-returning frame functions" do
      fn = make_fn("compute", return_type: :Int64, uses_frame: true)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("saveFrameMark")
      expect(zig).to include("restoreFrameMark")
    end

    it "skips frame mark for frame-string-returning functions (no heap_carry_return)" do
      fn = make_fn("getName", return_type: :String, uses_frame: true)
      result = lowering.lower(fn)
      zig = emit(result)
      # Frame string returns: no mark/restore (result lives in caller's frame region).
      expect(zig).not_to include("saveFrameMark")
      expect(zig).not_to include("restoreFrameMark")
      expect(zig).not_to include("preserveAndRewind")
    end

    it "emits _ = &rt when no frame allocation" do
      fn = make_fn("simple", body: [])
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("_ = &rt;")
    end

    it "lowers function without rt when needs_rt=false" do
      fn = make_fn("pure", needs_rt: false, can_fail: false)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).not_to include("rt: *Runtime")
    end

    it "renames main to clearMain" do
      fn = make_fn("main")
      result = lowering.lower(fn)
      expect(result.name).to eq("clearMain")
    end

    it "emits comptime params for generic functions" do
      fn = make_fn("identity", type_params: ["T"])
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("comptime T: type")
    end

    it "handles mutable scalar param shadows" do
      params = [{ name: "count", type: :Int64, mutable: true }]
      body_stmt = make_id("count")
      fn = make_fn("inc", params: params, body: [body_stmt])
      result = lowering.lower(fn)
      zig = emit(result)
      # Mutable scalar params are passed by pointer so the callee can update
      # the caller's binding (ce525d5a). The shadow unpacks on entry and
      # writes back on exit via a defer.
      expect(zig).to include("_m_count: *i64")
      expect(zig).to include("var count = _m_count.*;")
      expect(zig).to include("_m_count.* = count;")
    end
  end

  describe "fallible sorted lock acquire lowering" do
    it "emits ordered acquire-or-error code with retries, reverse release, and error bubbling" do
      a = make_id("a", full_type: :Counter, sync: :locked)
      b = make_id("b", full_type: :Counter, sync: :write_locked)
      caps = [
        { capability: :EXCLUSIVE, var_node: a, alias: "left", resolved_type: Type.new(:Counter) },
        { capability: :write_locked_read, var_node: b, alias: "right", resolved_type: Type.new(:Counter) }
      ]
      clause = {
        action: :pass,
        matched_types: [:LockTimeout],
        bubble_types: [:Deadlock],
        retries: 3
      }
      with_node = AST::WithBlock.new(tok, caps, [], nil)

      zig = lowering.send(:emit_sorted_lock_acquires_fallible, caps, clause, "__with_label", with_node)

      expect(zig).to include("acquireOrErr")
      expect(zig).to include("readOrErr")
      expect(zig).to include("var __held")
      expect(zig).to include("if (__retry + 1 < 3) continue")
      expect(zig).to include("error.LockTimeout")
      expect(zig).to include("error.Deadlock")
      expect(zig).to include("return error.CheatError")
      expect(zig).to include("defer if (__held")
      expect(zig).to include("const left")
      expect(zig).to include("const right")
    end
  end

  describe "targeted control-flow and ownership lowering" do
    it "lowers atomic compound writes through the mutable scalar parameter cell" do
      target = make_id("c", full_type: :Int64)
      amount = make_lit(:INT64, 3, full_type: :Int64)
      value = AST::BinaryOp.new(tok, target, :ADD, amount)
      node = AST::BindExpr.new(tok, "c", nil, value)
      node.compound_op = :ADD
      node.auto_atomic_op = :fetchAdd
      low = lowering
      low.instance_variable_set(:@current_fn_mutable_scalar_params, Set["c"])

      result = low.lower(node)

      expect(result).to be_a(MIR::ExprStmt)
      expect(result.discard).to be(true)
      expect(emit(result)).to eq("_ = _m_c.*.fetchAdd(3);")
    end

    it "lowers atomic stores without discarding a return value" do
      node = AST::BindExpr.new(tok, "c", nil, make_lit(:INT64, 5, full_type: :Int64))
      node.auto_atomic_op = :store

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ExprStmt)
      expect(result.discard).to be(false)
      expect(emit(result)).to eq("c.*.store(5);")
    end

    it "adds release defers and loop marks to WHILE RESOLVE bindings" do
      link = make_id("weak_node", full_type: :"Node@link")
      cond = AST::ResolveNode.new(tok, link)
      node = AST::WhileBindLoop.new(tok, cond, "node", tok, [AST::ContinueNode.new(tok)], nil)
      node.mark_per_iter = true
      low = lowering
      low.instance_variable_set(:@current_fn_has_rt, true)

      result = low.lower(node)

      expect(result).to be_a(MIR::WhileStmt)
      expect(result.capture).to eq("node")
      body_zig = result.body.map { |stmt| emit(stmt) }.join("\n")
      expect(body_zig).to include("CheatLib.rcRelease")
      expect(body_zig).to include("saveLoopMark")
      expect(body_zig).to include("restoreLoopMark")
      expect(body_zig).not_to include("checkYield")
    end

    it "adds release defers to IF RESOLVE bindings before the then body" do
      link = make_id("weak_node", full_type: :"Node@link")
      cond = AST::ResolveNode.new(tok, link)
      node = AST::IfBind.new(tok, [AST::Binding.new(expr: cond, name: "node", name_token: tok)], [AST::BreakNode.new(tok)], nil)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::IfBindStmt)
      then_zig = result.then_body.map { |stmt| emit(stmt) }.join("\n")
      expect(then_zig).to include("defer CheatLib.rcRelease")
      expect(then_zig).to include("break;")
    end

    it "lowers FOR EACH over maps through keyIterator optional binding" do
      coll = make_id("scores", full_type: :"HashMap<Int64>")
      node = AST::ForEach.new(tok, "name", coll, [AST::ContinueNode.new(tok)], nil, false)
      low = lowering
      low.instance_variable_set(:@current_fn_has_rt, true)

      result = low.lower(node)

      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("var __kit_")
      expect(zig).to include("scores.keyIterator()")
      expect(zig).to include("while (__kit_")
      expect(zig).to include(") |name|")
      expect(zig).to include("rt.checkYield()")
    end

    it "lowers FOR EACH over bounded streams with deinit and nextOrNull" do
      coll = make_id("stream", full_type: :"~Int64[4]")
      node = AST::ForEach.new(tok, "item", coll, [AST::BreakNode.new(tok)], nil, false)

      result = lowering.lower(node)

      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("defer stream.deinit()")
      expect(zig).to include("while (try stream.nextOrNull()) |item|")
    end

    it "uses ItemsAccess for list parameters in FOR EACH" do
      coll = make_id("items", full_type: :"Int64[]@list")
      node = AST::ForEach.new(tok, "item", coll, [AST::BreakNode.new(tok)], nil, false)
      low = lowering
      low.instance_variable_set(:@current_fn_param_names, Set["items"])

      result = low.lower(node)

      expect(result).to be_a(MIR::ForStmt)
      expect(result.iter).to be_a(MIR::ItemsAccess)
      expect(emit(result)).to include('if (@hasField(@TypeOf(__x), "items")) __x.items else @constCast(__x[0..])')
    end
  end

  # =========================================================================
  # Phase 3: FuncCall / MethodCall
  # =========================================================================

  describe "function calls" do
    it "lowers simple function call with rt and try" do
      arg = make_lit(:NUMBER, 42, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::FuncCall.new(tok, "compute", [arg])
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Call)
      zig = emit(result)
      expect(zig).to include("try compute(rt, 42)")
    end

    it "lowers call without rt when fn_sig says needs_rt=false" do
      sig = Struct.new(:needs_rt, :can_fail, :params, :return_type).new(false, false, [], :Int64)
      l = lowering(fn_sigs: { "pure" => sig })
      node = AST::FuncCall.new(tok, "pure", [])
      node.full_type = :Int64
      result = l.lower(node)
      zig = emit(result)
      expect(zig).to eq("pure()")
    end

    it "passes stack struct by value — SROA candidate, no const-ptr" do
      # Structs with no heap provenance live on the stack. Zig/LLVM SROAs them
      # into registers. Do NOT pass by *const T — that would prevent SROA.
      sig = Struct.new(:needs_rt, :can_fail, :params, :return_type)
                  .new(false, false, [AST::Param.new(name: "p", type: :Point, mutable: false, takes: false)], :Int64)
      l = lowering(
        fn_sigs: { "sum3" => sig },
        struct_schemas: { Point: { x: :Int64, y: :Int64 } }
      )
      arg = make_id("point", full_type: :Point)
      node = AST::FuncCall.new(tok, "sum3", [arg])
      node.full_type = :Int64
      result = l.lower(node)
      expect(emit(result)).to eq("sum3(point)")
    end

    it "passes runtime to function variable calls" do
      arg = make_lit(:NUMBER, 5, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::FuncCall.new(tok, "callback", [arg])
      node.full_type = :Int64
      node.fn_var_call = true

      result = lowering.lower(node)

      expect(result).to be_a(MIR::Call)
      expect(result.callee).to eq("try callback")
      expect(result.args.map { |a| emit(a) }).to eq(["rt", "5"])
    end

    it "wraps heap-duped function results in DupeSlice" do
      node = AST::FuncCall.new(tok, "name", [])
      node.full_type = :String
      node.heap_dupe_result = true

      result = lowering.lower(node)

      expect(result).to be_a(MIR::DupeSlice)
      expect(result.alloc).to eq(:heap)
      expect(result.source).to be_a(MIR::Call)
    end

    it "passes mutable scalar arguments by address when the callee requires mutation" do
      arg = make_id("count", full_type: :Int64)
      node = AST::FuncCall.new(tok, "bump", [arg])
      node.full_type = :Void
      sig = FunctionSignature.new(
        params: [{ name: "count", type: Type.new(:Int64), mutable: true }],
        return_type: Type.new(:Void)
      )

      result = lowering(fn_sigs: { "bump" => sig }).lower(node)

      expect(result).to be_a(MIR::Call)
      expect(result.args.last).to be_a(MIR::AddressOf)
      expect(emit(result.args.last)).to eq("&count")
    end

    it "passes generic type args before runtime and value args" do
      arg = make_lit(:NUMBER, 7, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::FuncCall.new(tok, "identity", [arg])
      node.full_type = :Int64
      node.generic_type_args = [:Int64]
      sig = FunctionSignature.new(params: [{ name: "x", type: Type.new(:Int64) }], return_type: Type.new(:Int64))
      sig.needs_rt = true

      result = lowering(fn_sigs: { "identity" => sig }).lower(node)

      expect(result).to be_a(MIR::Call)
      expect(result.args.map { |a| emit(a) }).to eq(["i64", "rt", "7"])
    end

    it "lowers method call as UFCS" do
      obj = make_id("user", full_type: :User)
      node = AST::MethodCall.new(tok, obj, "greet", [])
      node.full_type = :String
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Call)
      zig = emit(result)
      expect(zig).to include("try greet(rt, user)")
    end

    it "lowers intrinsic with zig_pattern" do
      arg = make_id("x", full_type: :Int64)
      node = AST::FuncCall.new(tok, "toString", [arg])
      node.full_type = :String
      node.zig_pattern = "try CheatLib.intToString({alloc}, {0})"
      node.matched_stdlib_def = { alloc: :frame }
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      zig = emit(result)
      expect(zig).to include("CheatLib.intToString")
      expect(zig).to include("frameAlloc")
    end
  end

  # =========================================================================
  # Phase 3: ListLit / HashLit
  # =========================================================================

  describe "list literals" do
    it "lowers empty list as empty slice" do
      node = AST::ListLit.new(tok, [], nil)
      node.full_type = Type.new(:"Int64[]")
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("i64")
    end

    it "lowers non-empty list as MakeList" do
      items = [make_lit(:NUMBER, 1, full_type: :Int64), make_lit(:NUMBER, 2, full_type: :Int64)]
      items.each { |i| i.coerced_type = :Int64 }
      node = AST::ListLit.new(tok, items, nil)
      node.full_type = Type.new(:"Int64[]")
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("makeList")
    end
  end

  describe "hash literals" do
    it "lowers empty hash as map_bare" do
      node = AST::HashLit.new(tok, [], :heap)
      node.full_type = :StringMap
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include(".alloc =")
    end
  end

  # =========================================================================
  # Phase 3: Lambda
  # =========================================================================

  describe "lambda literals" do
    it "lowers lambda to LambdaExpr" do
      body = make_lit(:NUMBER, 42, full_type: :Int64)
      body.coerced_type = :Int64
      node = AST::LambdaLit.new(tok, [], nil, body, nil, nil)
      node.full_type = FunctionSignature.new(params: [], return_type: Type.new(:Int64))
      result = lowering.lower(node)
      expect(result).to be_a(MIR::LambdaExpr)
      zig = emit(result)
      expect(zig).to include("struct")
      expect(zig).to include("_lambda_")
      expect(zig).to include("return 42")
    end
  end

  # =========================================================================
  # Phase 3: Escape hatch nodes
  # =========================================================================

  describe "escape hatch nodes" do
    it "lowers ThrowNode" do
      node = AST::ThrowNode.new(tok, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(emit(result)).to include("return error.CheatError")
    end

    it "lowers Cast" do
      inner = make_lit(:NUMBER, 42, full_type: :Int64)
      inner.coerced_type = :Int64
      node = AST::Cast.new(tok, inner, :Int32)
      node.full_type = :Int32
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Cast)
      expect(emit(result)).to eq("@as(i32, 42)")
    end

    it "lowers DieNode" do
      node = AST::DieNode.new(tok, 2)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(emit(result)).to include("std.process.exit(2)")
    end

    it "lowers PassStmt" do
      node = AST::PassStmt.new(tok)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Noop)
    end
  end

  # =========================================================================
  # Phase 4: WithBlock
  # =========================================================================

  describe "WithBlock lowering" do
    it "lowers multiowned capability unwrap" do
      var_node = make_id("counter", full_type: :Counter)
      cap = { var_node: var_node, alias: nil, capability: :multiowned, resolved_type: nil }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("__counter_unwrap")
      expect(zig).to include("ctrl.data.*")
    end

    it "lowers shared capability unwrap" do
      var_node = make_id("counter", full_type: :Counter)
      cap = { var_node: var_node, alias: nil, capability: :shared, resolved_type: nil }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("__counter_unwrap")
      expect(zig).to include("ctrl.data.*")
    end

    it "lowers EXCLUSIVE mutex capability with acquire/release" do
      var_node = make_id("counter", full_type: :Counter, sync: :locked)
      resolved = Type.new(:Counter, sync: :locked)
      cap = { var_node: var_node, alias: "c", capability: :EXCLUSIVE, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to match(/__counter_guard_\d+/)
      expect(zig).to include(".acquire()")
      expect(zig).to match(/defer __counter_guard_\d+\.release\(\)/)
      expect(zig).to include("const c =")
    end

    it "lowers EXCLUSIVE write_locked capability with write()" do
      var_node = make_id("counter", full_type: :Counter, sync: :write_locked)
      resolved = Type.new(:Counter, sync: :write_locked)
      cap = { var_node: var_node, alias: "c", capability: :EXCLUSIVE, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include(".write()")
      expect(zig).to match(/defer __counter_guard_\d+\.release\(\)/)
    end

    it "lowers write_locked_read capability with read()" do
      var_node = make_id("counter", full_type: :Counter, sync: :write_locked)
      resolved = Type.new(:Counter, sync: :write_locked)
      cap = { var_node: var_node, alias: "c", capability: :write_locked_read, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include(".read()")
      expect(zig).to match(/defer __counter_guard_\d+\.release\(\)/)
    end

    it "lowers BORROWED capability" do
      var_node = make_id("data", full_type: :Data)
      cap = { var_node: var_node, alias: "d", capability: :BORROWED, resolved_type: nil }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("const d = data")
    end

    it "lowers RESTRICT capability" do
      var_node = make_id("buf", full_type: :Buffer)
      resolved = Type.new(:Buffer)
      cap = { var_node: var_node, alias: "b", capability: :RESTRICT, alias_mutable: false, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("const b = buf")
    end

    it "lowers RESTRICT mutable capability with pointer" do
      var_node = make_id("buf", full_type: :Buffer)
      resolved = Type.new(:Buffer)
      cap = { var_node: var_node, alias: "b", capability: :RESTRICT, alias_mutable: true, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("const b = &buf")
    end

    it "lowers empty WithBlock" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      expect(result.body).not_to be_empty
    end
  end

  # =========================================================================
  # Phase 4: DoBlock
  # =========================================================================

  describe "DoBlock lowering" do
    it "lowers single-branch DoBlock with WaitGroup" do
      body_lit = make_lit(:NUMBER, 42, full_type: :Int64)
      body_lit.coerced_type = :Int64
      branch = {
        body: [body_lit],
        capture_analysis: nil,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil
      }
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::DoBlock)
      zig = emit(result)
      expect(zig).to include("WaitGroup")
      expect(zig).to include(".add(1)")
      expect(zig).to include(".wait()")
      expect(zig).to include("__DoBranchCtx")
      expect(zig).to include("fn run(")
    end

    it "lowers multi-branch DoBlock" do
      lit1 = make_lit(:NUMBER, 1, full_type: :Int64)
      lit1.coerced_type = :Int64
      lit2 = make_lit(:NUMBER, 2, full_type: :Int64)
      lit2.coerced_type = :Int64
      branches = [
        { body: [lit1], capture_analysis: nil, pinned: false, stack_size: nil, computed_stack_tier: nil },
        { body: [lit2], capture_analysis: nil, pinned: true, stack_size: nil, computed_stack_tier: nil }
      ]
      node = AST::DoBlock.new(tok, branches)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("__DoBranchCtx")
      # Per-spawn add(1) replaces upfront add(N); errdefer guards partial-spawn failures.
      expect(zig).to include(".add(1)")
      expect(zig).not_to include(".add(2)")
      expect(zig).to include("errdefer")
      # Pinned branch uses submitSpawn, unpinned uses spawnBest
      expect(zig).to include("spawnBest")
      expect(zig).to include("submitSpawn")
    end

    it "lowers DoBlock with captures" do
      body_id = make_id("x", full_type: :Int64)
      captures_hash = { "x" => :Int64 }
      analysis = OpenStruct.new(captures: captures_hash)
      branch = {
        body: [body_id],
        capture_analysis: analysis,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil
      }
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      # Same pattern as BG: @TypeOf for the field type, direct value
      # init, no deref in body. Replaces the previous *const T + &name
      # + ctx.x.* triplet that diverged from BG codegen.
      expect(zig).to include("x: @TypeOf(x)")
      expect(zig).to include(".x = x")
    end

    it "merges nested BG capture analysis into the DoBlock context" do
      nested_body = make_id("inner", full_type: :Int64)
      nested_analysis = OpenStruct.new(
        captures: { "inner" => :Int64 },
        capture_symbols: {},
        close_patterns: {},
        pointer_captures: Set.new,
        string_captures: Set.new,
        resource_captures: Set.new
      )
      nested_bg = AST::BgBlock.new(tok, [nested_body], nil, nil, nil, nil, nil, nil)
      nested_bg.full_type = :"~Void"
      nested_bg.capture_analysis = nested_analysis

      branch_analysis = OpenStruct.new(
        captures: {},
        capture_symbols: {},
        close_patterns: {},
        pointer_captures: Set.new,
        string_captures: Set.new,
        resource_captures: Set.new
      )
      branch = {
        body: [nested_bg],
        capture_analysis: branch_analysis,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil
      }
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      zig = emit(lowering.lower(node))
      expect(zig).to include("inner: @TypeOf(inner)")
      expect(zig).to include(".inner = inner")
      expect(zig).to include("_ = try __discard_bg_")
      expect(zig).to include(".next()")
    end

    it "flattens array-lowered DoBlock body declarations" do
      locked_type = Type.new(:Counter, sync: :locked)
      inner = make_id("src", full_type: locked_type)
      copy = AST::CopyNode.new(tok, inner)
      copy.full_type = locked_type
      decl = AST::VarDecl.new(tok, "dst", nil, copy, false)
      decl.full_type = locked_type
      decl.var_used = true
      branch = {
        body: [decl],
        capture_analysis: nil,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: nil
      }
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      zig = emit(lowering.lower(node))
      expect(zig).to include("var dst = try CheatLib.dupeValue")
      expect(zig).to include("defer CheatLib.lockedDestroy")
    end

    it "lowers DoBlock with stack tier" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      branch = {
        body: [body_lit],
        capture_analysis: nil,
        pinned: false,
        stack_size: nil,
        computed_stack_tier: :large
      }
      node = AST::DoBlock.new(tok, [branch])
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("stack_size = .Large")
    end
  end

  # =========================================================================
  # Phase 4: BgBlock
  # =========================================================================

  describe "BgBlock lowering" do
    it "lowers void BgBlock with promise spawn" do
      body_lit = make_lit(:NUMBER, 42, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      expect(result).to be_a(MIR::BgBlock)
      zig = emit(result)
      expect(zig).to include("__BgCtx")
      expect(zig).to include(".spawn(")
      expect(zig).to include("fn run(")
      expect(zig).to include("submitSpawn")
      expect(zig).to include(".profile_dispatch = 1")
      expect(zig).not_to include("spawnBest")
    end

    it "lowers BgBlock with captures" do
      body_id = make_id("x", full_type: :Int64)
      captures_hash = { "x" => :Int64 }
      analysis = OpenStruct.new(
        captures: captures_hash,
        capture_symbols: {},
        close_patterns: {},
        pointer_captures: Set.new(["x"]),
        resource_captures: Set.new
      )
      node = AST::BgBlock.new(tok, [body_id], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"
      node.capture_analysis = analysis

      result = lowering.lower(node)
      zig = emit(result)
      # Pointer captures (HashMap, @pool, @sharded:locked, ...) flow as
      # `*T` into the fiber context so writes inside the fiber land on
      # the outer instance. Without this the fiber operates on a value
      # copy and per-shard locks become independent mutexes -- writes
      # never appear to outer readers (regressed examples/graphdb).
      expect(zig).to include("x: @TypeOf(&x)")
      expect(zig).to include(".x = &x")
    end

    it "lowers pinned BgBlock with submitSpawn" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, true, nil, nil, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("submitSpawn")
      expect(zig).not_to include("spawnBest")
    end

    it "lowers BgBlock with arena mode" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, nil, nil, true, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("arena_mode = true")
    end

    it "lowers BgBlock with stack tier" do
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::BgBlock.new(tok, [body_lit], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"
      node.computed_stack_tier = :large

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("stack_size = .Large")
    end

    it "flattens ThenChain in BgBlock body" do
      step1 = make_lit(:NUMBER, 1, full_type: :Int64)
      step1.coerced_type = :Int64
      step2 = make_lit(:NUMBER, 2, full_type: :Int64)
      step2.coerced_type = :Int64
      chain = AST::ThenChain.new(tok, [
        { expr: step1, binding: "a" },
        { expr: step2, binding: nil }
      ])
      chain.full_type = :Int64
      node = AST::BgBlock.new(tok, [chain], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("const a = 1")
    end
  end

  # =========================================================================
  # Phase 4: BgStreamBlock + Yield
  # =========================================================================

  describe "BgStreamBlock lowering" do
    it "lowers basic stream generator" do
      yield_expr = make_lit(:NUMBER, 42, full_type: :Int64)
      yield_expr.coerced_type = :Int64
      yield_node = AST::YieldExpr.new(tok, yield_expr)
      yield_node.full_type = :Void
      node = AST::BgStreamBlock.new(tok, [yield_node], nil, nil)
      node.full_type = :"~?Void[]"

      result = lowering.lower(node)
      expect(result).to be_a(MIR::BgBlock)
      zig = emit(result)
      expect(zig).to include("__SgCtx")
      expect(zig).to include("spawnNew")
      expect(zig).to include(".close()")
      expect(zig).to include(".push(")
    end

    it "refuses unsafe BG STREAM captures with ownership-specific guidance" do
      node = AST::BgStreamBlock.new(tok, [], nil, nil)
      node.full_type = :"~?Int64[]"
      node.capture_analysis = OpenStruct.new(
        captures: { "items" => Type.new(:"Int64[]@list") },
        strategies: { "items" => CaptureStrategy::Refuse.new(:list_borrow_without_transfer, "items") }
      )

      expect { lowering.lower(node) }
        .to raise_error(/BG block captures values.*'items' is @list.*GIVE.*COPY/m)
    end

    it "lowers finite BG STREAM to an eager block for the bytecode backend" do
      yield_expr = make_lit(:INT64, 1, full_type: :Int64)
      yield_node = AST::YieldExpr.new(tok, yield_expr)
      yield_node.full_type = :Void
      node = AST::BgStreamBlock.new(tok, [yield_node], nil, nil)
      node.full_type = :"~?Int64[]"

      result = lowering(target: :bc).lower(node)

      expect(result).to be_a(MIR::BlockExpr)
      expect(result.body.first).to be_a(MIR::Let)
      expect(result.body.first.init).to be_a(MIR::MakeList)
      expect(result.body.last).to be_a(MIR::BreakStmt)
    end

    it "lowers infinite BG STREAM to StreamSpawn for the bytecode backend" do
      yield_expr = make_lit(:INT64, 1, full_type: :Int64)
      yield_node = AST::YieldExpr.new(tok, yield_expr)
      yield_node.full_type = :Void
      node = AST::BgStreamBlock.new(tok, [yield_node], nil, nil)
      node.full_type = :"~Int64[INF]"
      node.capture_analysis = OpenStruct.new(captures: { "seed" => :Int64 })

      result = lowering(target: :bc).lower(node)

      expect(result).to be_a(MIR::StreamSpawn)
      expect(result.captures).to eq({ "seed" => :Int64 })
    end
  end

  # =========================================================================
  # Phase 4: YieldExpr (standalone)
  # =========================================================================

  describe "YieldExpr lowering" do
    it "lowers yield outside stream context" do
      expr = make_lit(:NUMBER, 7, full_type: :Int64)
      expr.coerced_type = :Int64
      node = AST::YieldExpr.new(tok, expr)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::MethodCall)
      zig = emit(result)
      expect(zig).to include("try __stream_local.push(7)")
    end
  end

  # =========================================================================
  # Phase 4: NextExpr
  # =========================================================================

  describe "NextExpr lowering" do
    it "lowers NEXT expression" do
      inner = make_id("promise", full_type: :"~Int64")
      node = AST::NextExpr.new(tok, inner)
      node.full_type = :Int64

      result = lowering.lower(node)
      expect(result).to be_a(MIR::MethodCall)
      zig = emit(result)
      expect(zig).to include("try promise.next()")
    end
  end

  # =========================================================================
  # Phase 4: StaticCall
  # =========================================================================

  describe "StaticCall lowering" do
    it "lowers static call with pattern substitution" do
      arg = make_lit(:NUMBER, 10, full_type: :Int64)
      arg.coerced_type = :Int64
      node = AST::StaticCall.new(tok, "Math", "sqrt", [arg])
      node.full_type = :Number
      node.zig_pattern = "std.math.sqrt({0})"

      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      zig = emit(result)
      expect(zig).to eq("std.math.sqrt(10)")
    end

    it "lowers static call with multiple args" do
      arg0 = make_lit(:NUMBER, 1, full_type: :Int64)
      arg0.coerced_type = :Int64
      arg1 = make_lit(:NUMBER, 2, full_type: :Int64)
      arg1.coerced_type = :Int64
      node = AST::StaticCall.new(tok, "Math", "max", [arg0, arg1])
      node.full_type = :Number
      node.zig_pattern = "std.math.max({0}, {1})"

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to eq("std.math.max(1, 2)")
    end
  end

  # =========================================================================
  # Phase 4: Or* error chains
  # =========================================================================

  describe "Or* error chain lowering" do
    it "lowers OrRaise to Ident" do
      node = AST::OrRaise.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("error.OrRaise")
    end

    it "lowers OrBreak to BreakStmt" do
      node = AST::OrBreak.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::BreakStmt)
      expect(emit(result)).to eq("break;")
    end

    it "lowers OrPass to Ident undefined" do
      node = AST::OrPass.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("undefined")
    end

    it "lowers OrPrune to Ident undefined" do
      node = AST::OrPrune.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("undefined")
    end

    it "lowers OrExit with message (pure message override)" do
      # New unified OR EXIT: 4-arg (token, kind, error_name, message).
      # Pure "msg" form passes nil kind + nil error_name; lowering
      # inherits both from rt.__error and only updates message.
      msg = make_lit(:STRING, "fatal", full_type: :String)
      node = AST::OrExit.new(tok, nil, nil, msg)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("rt.__error.message")
      expect(zig).to include("return error.CheatError")
      # No kind / error_name writes because both were nil.
      expect(zig).not_to include("rt.__error.kind =")
      expect(zig).not_to include("rt.__error.error_name =")
    end

    it "lowers OrExit Kind,Type,msg (full override) with direct field writes" do
      msg = make_lit(:STRING, "bad", full_type: :String)
      node = AST::OrExit.new(tok, :Input, "ParseErr", msg)
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("rt.__error.kind = .Input")
      expect(zig).to include("rt.__error.error_name = @intFromEnum(ErrorName.ParseErr)")
      expect(zig).to include("rt.__error.message")
      expect(zig).to include("return error.CheatError")
    end

    it "lowers OrExit Kind (kind-only) with type cleared to 0" do
      node = AST::OrExit.new(tok, :Input, nil, nil)
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("rt.__error.kind = .Input")
      # Kind-without-type clears the stale type explicitly.
      expect(zig).to include("rt.__error.error_name = 0")
    end

    it "lowers fallible OR PASS to TryCatch while preserving heap provenance" do
      call = AST::FuncCall.new(tok, "make", [])
      call.full_type = Type.new(:"Int64[]", collection: :list)
      call.error_union_type = Type.new(:"!Int64[]")
      call.can_fail = true
      sig = FunctionSignature.new(params: [], return_type: Type.new(:"!Int64[]"))
      sig.return_provenance = :heap
      node = AST::BinaryOp.new(tok, call, :OR_RESCUE, AST::OrPass.new(tok))
      node.full_type = Type.new(:"Int64[]", collection: :list)

      result = lowering(fn_sigs: { "make" => sig }).lower(node)

      expect(result).to be_a(MIR::TryCatch)
      expect(result.heap_provenance).to be true
      expect(emit(result)).to include("make(rt) catch undefined")
    end

    it "hoists heap-provenance TryCatch returns with err cleanup" do
      call = AST::FuncCall.new(tok, "make", [])
      call.full_type = Type.new(:"Int64[]", collection: :list)
      call.error_union_type = Type.new(:"!Int64[]")
      call.can_fail = true
      sig = FunctionSignature.new(params: [], return_type: Type.new(:"!Int64[]"))
      sig.return_provenance = :heap
      value = AST::BinaryOp.new(tok, call, :OR_RESCUE, AST::OrPass.new(tok))
      value.full_type = Type.new(:"Int64[]", collection: :list)
      ret = AST::ReturnNode.new(tok, value)
      ret.full_type = value.full_type

      body = lowering(fn_sigs: { "make" => sig }).lower_body([ret])

      temp_let = body.grep(MIR::Let).find { |stmt| stmt.init.is_a?(MIR::TryCatch) }
      expect(temp_let).not_to be_nil

      temp_name = temp_let.name
      alloc = body.grep(MIR::AllocMark).find { |stmt| stmt.name == temp_name }
      cleanup = body.grep(MIR::ErrCleanup).find { |stmt| stmt.name == temp_name }
      ret_stmt = body.grep(MIR::ReturnStmt).find do |stmt|
        stmt.value.is_a?(MIR::Ident) && stmt.value.name == temp_name
      end

      expect(alloc&.alloc).to eq(:heap)
      expect(cleanup&.cleanup_entry).to include(kind: :list, alloc: :heap)
      expect(ret_stmt).not_to be_nil
    end

    it "lowers OR EXIT on fallible expressions to a catch block that rewrites error context" do
      call = AST::FuncCall.new(tok, "parse", [])
      call.full_type = :Int64
      call.error_union_type = Type.new(:"!Int64")
      call.can_fail = true
      exit = AST::OrExit.new(tok, :Input, "ParseErr", make_lit(:STRING, "bad", full_type: :String))
      node = AST::BinaryOp.new(tok, call, :OR_RESCUE, exit)
      node.full_type = :Int64

      result = lowering.lower(node)
      zig = emit(result)

      expect(result).to be_a(MIR::TryCatch)
      expect(zig).to include("catch |__exit_err|")
      expect(zig).to include("rt.__error.kind = .Input")
      expect(zig).to include("ErrorName.ParseErr")
      expect(zig).to include("return __exit_err")
    end

    it "lowers OR fallback to error catch and optional orelse based on left type" do
      fallible = AST::FuncCall.new(tok, "fallible", [])
      fallible.full_type = :Int64
      fallible.error_union_type = Type.new(:"!Int64")
      fallback = make_lit(:INT64, 0, full_type: :Int64)
      error_node = AST::BinaryOp.new(tok, fallible, :OR_RESCUE, fallback)
      error_node.full_type = :Int64

      maybe = make_id("maybe", full_type: :"?Int64")
      optional_node = AST::BinaryOp.new(tok, maybe, :OR_RESCUE, fallback)
      optional_node.full_type = :Int64

      expect(lowering.lower(error_node)).to be_a(MIR::TryCatch)
      expect(lowering.lower(optional_node)).to be_a(MIR::Orelse)
    end
  end

  # =========================================================================
  # Phase 4: TestBlock
  # =========================================================================

  describe "TestBlock lowering" do
    it "lowers basic test block with WHEN and TEST THAT" do
      body_lit = make_lit(:BOOLEAN, true, full_type: :Boolean)
      assert_node = AST::Assert.new(tok, body_lit, nil)
      assert_node.full_type = :Void
      test_that = AST::TestThat.new(tok, "works", [assert_node])
      when_block = AST::WhenBlock.new(tok, "given input", [], [test_that], [])
      node = AST::TestBlock.new(tok, "MyTest", [], [when_block])
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(Array)
      expect(result.first).to be_a(MIR::TestDef)
      zig = result.map { |t| emit(t) }.join("\n")
      expect(zig).to include('test "MyTest: given input: works"')
      expect(zig).to include("Runtime.init(allocator")
      expect(zig).to include("rt.wireAllocator()")
    end

    it "lowers test block with setup code" do
      setup_lit = make_lit(:NUMBER, 0, full_type: :Int64)
      setup_lit.coerced_type = :Int64
      body_lit = make_lit(:BOOLEAN, true, full_type: :Boolean)
      assert_node = AST::Assert.new(tok, body_lit, nil)
      assert_node.full_type = :Void
      test_that = AST::TestThat.new(tok, "passes", [assert_node])
      when_block = AST::WhenBlock.new(tok, "setup", [], [test_that], [])
      node = AST::TestBlock.new(tok, "WithSetup", [setup_lit], [when_block])
      node.full_type = :Void

      result = lowering.lower(node)
      zig = result.map { |t| emit(t) }.join("\n")
      expect(zig).to include('test "WithSetup: setup: passes"')
    end
  end

  # =========================================================================
  # Phase 4: AssertRaises
  # =========================================================================

  describe "AssertRaises lowering" do
    it "lowers assert raises with kind" do
      expr = make_lit(:BOOLEAN, true, full_type: :Boolean)
      node = AST::AssertRaises.new(tok, :Runtime, nil, expr)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
      zig = emit(result)
      expect(zig).to include("ASSERT_RAISES")
      expect(zig).to include("matchesKind(.Runtime)")
    end

    it "lowers assert raises with kind and error name" do
      expr = make_lit(:BOOLEAN, true, full_type: :Boolean)
      node = AST::AssertRaises.new(tok, :Type, "NotFound", expr)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("matchesKind(.Type)")
      expect(zig).to include('matchesName(@intFromEnum(ErrorName.NotFound))')
    end
  end

  # =========================================================================
  # Phase 4: RequireNode
  # =========================================================================

  describe "RequireNode lowering" do
    it "lowers package require to MIR::Import" do
      node = AST::RequireNode.new(tok, "math", "math", :package)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::Import)
      zig = emit(result)
      expect(zig).to include('@import("math.zig")')
    end

    it "raises on local require when no importer available" do
      node = AST::RequireNode.new(tok, "utils.cht", nil, :local)
      node.full_type = :Void

      expect { lowering.lower(node) }.to raise_error(/no importer available/)
    end
  end

  # =========================================================================
  # Phase 4: StubDecl, BenchmarkStmt, SmashStmt, ProfileStmt
  # =========================================================================

  describe "test framework helpers" do
    it "lowers StubDecl :returns to MIR::Let" do
      node = AST::StubDecl.new(tok, "getData", :returns, make_lit(:NUMBER, 42))
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Let)
      expect(result.name).to eq("__stub_getData")
    end

    it "lowers BenchmarkStmt to Comment" do
      node = AST::BenchmarkStmt.new(tok, make_lit(:NUMBER, 1), 1000)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
    end

    it "lowers SmashStmt to Comment" do
      node = AST::SmashStmt.new(tok, make_lit(:NUMBER, 1))
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
    end

    it "lowers ProfileStmt to Comment" do
      node = AST::ProfileStmt.new(tok, make_lit(:NUMBER, 1))
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
    end
  end

  # =========================================================================
  # Phase 4: ThenChain error
  # =========================================================================

  describe "ThenChain" do
    it "raises when encountered directly" do
      node = AST::ThenChain.new(tok, [])
      node.full_type = :Void
      expect { lowering.lower(node) }.to raise_error(/ThenChain should be flattened/)
    end
  end

  # =========================================================================
  # Phase 5: Program node
  # =========================================================================

  describe "Program lowering" do
    it "lowers empty program with standard imports" do
      prog = AST::Program.new(tok, [])
      result = lowering.lower(prog)
      expect(result).to be_a(MIR::Program)
      zig = emit(result)
      expect(zig).to include('@import("std")')
      expect(zig).to include('@import("runtime/runtime-header.zig")')
      expect(zig).to include("CheatLib")
      expect(zig).to include("Runtime")
      expect(zig).to include("EbrContext")
    end

    it "lowers program with statements and source line comments" do
      enum_node = AST::EnumDef.new(tok, "Color", ["Red", "Blue"], nil)
      enum_node.full_type = :Void
      prog = AST::Program.new(tok, [enum_node])
      result = lowering.lower(prog)
      zig = emit(result)
      expect(zig).to include("// CLR:1")
      expect(zig).to include("Color")
    end

    it "includes safety import when requested" do
      prog = AST::Program.new(tok, [])
      result = lowering.lower_program(prog, needs_safety: true)
      zig = emit(result)
      expect(zig).to include('@import("runtime/../lib/safety.zig")')
    end

    it "includes USE_C_ALLOCATOR when requested" do
      prog = AST::Program.new(tok, [])
      result = lowering.lower_program(prog, use_c_allocator: true)
      zig = emit(result)
      expect(zig).to include("USE_C_ALLOCATOR")
    end
  end

  describe "source fixture MIR lowering corpus" do
    fixture_expectations = {
      "transpile-tests/253_while_bind.cht" => {
        description: "WHILE bind and RESOLVE traversal",
        required_patterns: [/while \(items\.pop\(\)\) \|v\|/, /CheatLib\.rcRelease/]
      },
      "transpile-tests/305_observable_collect.cht" => {
        description: "observable COLLECT wait/destroy cleanup",
        required_patterns: [/running\.wait\(\)/, /running\.destroy\(rt\.heapAlloc\(\)\)/, /try running\.next\(\)/]
      },
      "transpile-tests/329_versioned_snapshot_mutable.cht" => {
        description: "versioned mutable snapshot update conflict handling",
        required_patterns: [/\.update\(rt, rt\.heapAlloc\(\)/, /MvccConflict/]
      },
      "transpile-tests/337_atomic_basic_ops.cht" => {
        description: "primitive atomic load/store/fetch operations",
        required_patterns: [/\.load\(\)/, /\.store\(/, /\.fetchAdd\(/, /\.fetchSub\(/]
      },
      "transpile-tests/342_atomic_ptr_read.cht" => {
        description: "atomic pointer snapshot read guards",
        required_patterns: [/\.read\(rt\)/, /\.release\(\)/]
      },
      "transpile-tests/349_polymorphic_transaction_acceptance.cht" => {
        description: "polymorphic lock and snapshot dispatch",
        required_patterns: [/acquire\(\)/, /\.update\(rt, rt\.heapAlloc\(\)/, /@hasField/]
      }
    }

    fixture_expectations.each do |path, expectation|
      it "lowers #{expectation[:description]} fixture to checker-clean MIR" do
        mir = lower_fixture_mir(path)
        expect_checker_clean(mir)

        zig = emit(mir)
        expectation[:required_patterns].each do |pattern|
          expect(zig).to match(pattern)
        end
      end
    end

  end

  # =========================================================================
  # Phase 5: SMOOTH (pipeline) operator
  # =========================================================================

  describe "SMOOTH pipeline lowering" do
    it "lowers simple pipe x |> f to function call via intrinsic pattern" do
      lhs = make_lit(:NUMBER, 42, full_type: :Number)
      lhs.coerced_type = nil
      rhs = AST::Identifier.new(tok, "double")
      rhs.full_type = :Number
      rhs.zig_pattern = "double({0})"

      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("double")
      expect(zig).to include("42")
    end

    it "lowers pipe with args x |> f(y) to f(x, y) via intrinsic pattern" do
      lhs = make_lit(:NUMBER, 10, full_type: :Number)
      lhs.coerced_type = nil
      arg = make_lit(:NUMBER, 20, full_type: :Number)
      arg.coerced_type = nil
      rhs = AST::FuncCall.new(tok, "add", [arg])
      rhs.full_type = :Number
      rhs.zig_pattern = "add({0}, {1})"

      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("add")
      expect(zig).to include("10")
      expect(zig).to include("20")
    end

    it "lowers RECOVER directly to TryCatch without legacy pipeline fallback" do
      lhs = AST::FuncCall.new(tok, "fallible", [])
      lhs.full_type = :Int64
      lhs.error_union_type = Type.new(:"!Int64")
      lhs.can_fail = true
      rhs = AST::RecoverOp.new(tok, make_lit(:INT64, 0, full_type: :Int64))
      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Int64

      result = lowering.lower(node)

      expect(result).to be_a(MIR::TryCatch)
      expect(result.expr).to be_a(MIR::Call)
      expect(result.expr.callee).to eq("fallible")
      expect(result.catch_body).to be_a(MIR::Lit)
      expect(emit(result)).to eq("(fallible(rt) catch 0)")
    end

    it "lowers BatchWindowOp through structural MIR instead of the legacy pipeline host" do
      mir = lower_fixture_mir("transpile-tests/243_batch_window.cht")

      expect(collect_mir_nodes(mir, MIR::BatchWindowPush)).not_to be_empty
      expect(collect_mir_nodes(mir, MIR::BatchWindowFlush)).not_to be_empty
      raw_reasons = collect_mir_nodes(mir, MIR::RawZig).map(&:reason)
      expect(raw_reasons).not_to include("pipeline_legacy_host")

      zig = emit(mir)
      expect(zig).to include("CheatLib.BatchWindow(i64).init")
      expect(zig).to include(".freeBatch(")
    end

    it "lowers non-mutual THUNK recursion through structural MIR instead of RawZig" do
      mir = lower_fixture_mir("transpile-tests/526_non_mutual_thunk_trampoline.cht")

      thunk_nodes = collect_mir_nodes(mir, MIR::ThunkTrampoline)
      expect(thunk_nodes.length).to eq(1)
      thunk = thunk_nodes.fetch(0)
      expect(thunk.fn_name).to eq("sum_down")
      expect(thunk.ret_zig).to eq("i64")
      expect(thunk.base_cases.length).to eq(1)
      expect(thunk.base_cases.first.fetch(:value_zig)).to eq("0")
      expect(thunk.combine_lhs_zig).to eq("current.n")
      expect(thunk.op_zig).to eq("+")
      expect(thunk.recurse_arg_inits.length).to eq(1)
      expect(thunk.recurse_arg_inits.first).to include("current.n")
      expect(thunk.yield_line).to eq("rt.checkYield();")
      raw_reasons = collect_mir_nodes(mir, MIR::RawZig).map(&:reason)
      expect(raw_reasons).not_to include(:thunk_trampoline_body)
    end

    it "lowers mutual THUNK recursion through structural MIR instead of RawZig" do
      mir = lower_fixture_mir("transpile-tests/525_mutual_thunk_trampoline.cht")

      thunk_nodes = collect_mir_nodes(mir, MIR::MutualThunkTrampoline)
      expect(thunk_nodes.map(&:fn_name)).to contain_exactly("is_even", "is_odd")
      thunk_nodes.each do |thunk|
        expect(thunk.variants.map { |v| v.fetch(:name) }).to contain_exactly("is_even", "is_odd")
        expect(thunk.initial_variant).to eq(thunk.fn_name)
        expect(thunk.initial_fields).to eq([".n = n"])
        expect(thunk.yield_line).to eq("rt.checkYield();")
      end

      even = thunk_nodes.find { |n| n.fn_name == "is_even" }
      expect(even).not_to be_nil
      even_arm = even.arms.find { |a| a.fetch(:variant_name) == "is_even" }
      expect(even_arm).not_to be_nil
      expect(even_arm.fetch(:base_cases).first.fetch(:value_zig)).to eq("true")
      expect(even_arm.fetch(:target_variant)).to eq("is_odd")
      expect(even_arm.fetch(:target_arg_inits).first).to include("f.n")

      odd = thunk_nodes.find { |n| n.fn_name == "is_odd" }
      expect(odd).not_to be_nil
      odd_arm = odd.arms.find { |a| a.fetch(:variant_name) == "is_odd" }
      expect(odd_arm).not_to be_nil
      expect(odd_arm.fetch(:base_cases).first.fetch(:value_zig)).to eq("false")
      expect(odd_arm.fetch(:target_variant)).to eq("is_even")
      expect(odd_arm.fetch(:target_arg_inits).first).to include("f.n")

      raw_reasons = collect_mir_nodes(mir, MIR::RawZig).map(&:reason)
      expect(raw_reasons).not_to include(:thunk_trampoline_body)
    end

    it "collects named observables by calling next directly" do
      lhs = make_id("running", full_type: :"~Int64@observable")
      rhs = AST::CollectOp.new(tok)
      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Int64

      result = lowering.lower(node)

      expect(result).to be_a(MIR::MethodCall)
      expect(result.method).to eq("next")
      expect(emit(result)).to eq("try running.next()")
    end

    it "collects inline collection observables through materializeNext and destroys the accumulator" do
      lhs = AST::FuncCall.new(tok, "makeDistinct", [])
      lhs.full_type = Type.new(:"~Int64[]", collection: :set, observable: true, observable_terminal: :distinct)
      rhs = AST::CollectOp.new(tok)
      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = Type.new(:"Int64[]@list")

      result = lowering.lower(node)
      zig = emit(result)

      expect(result).to be_a(MIR::BlockExpr)
      expect(zig).to include("materializeNext(rt.heapAlloc())")
      expect(zig).to include(".destroy(rt.heapAlloc())")
    end

    it "raises on unhandled SMOOTH RHS" do
      lhs = make_lit(:NUMBER, 1, full_type: :Number)
      rhs = make_lit(:NUMBER, 2, full_type: :Number) # Literal is not a valid pipe target

      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Number

      expect { lowering.lower(node) }.to raise_error(/unhandled SMOOTH/)
    end
  end

  # =========================================================================
  # Phase 5: OR_RESCUE error chain
  # =========================================================================

  describe "OR_RESCUE error chain lowering" do
    def make_error_expr(name)
      id = make_id(name, full_type: :"!Number")
      # Simulate error union type
      allow(id).to receive(:can_fail).and_return(true)
      id
    end

    it "lowers OR RAISE with error to try" do
      left = make_error_expr("getData")
      right = AST::OrRaise.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("try")
      expect(zig).to include("getData")
    end

    it "lowers OR RAISE with non-error to passthrough" do
      left = make_id("x", full_type: :Number)
      right = AST::OrRaise.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to eq("x")
    end

    it "lowers OR PASS with error to catch undefined" do
      left = make_error_expr("getData")
      right = AST::OrPass.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch undefined")
    end

    it "lowers OR BREAK with error to catch break" do
      left = make_error_expr("getData")
      right = AST::OrBreak.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch break")
    end

    it "lowers OR EXIT with error to catch + setError" do
      left = make_error_expr("getData")
      msg = make_lit(:STRING, "failed", full_type: :String)
      right = AST::OrExit.new(tok, msg)
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("__exit_err")
      expect(zig).to include("return __exit_err")
    end

    it "lowers error union with default fallback to catch" do
      left = make_error_expr("getData")
      right = make_lit(:NUMBER, 0, full_type: :Number)
      right.coerced_type = nil
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch")
      expect(zig).to include("0")
    end

    it "lowers optional with fallback to orelse" do
      left = make_id("maybe", full_type: :"?Number")
      right = make_lit(:NUMBER, 99, full_type: :Number)
      right.coerced_type = nil
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("orelse")
      expect(zig).to include("99")
    end

    it "lowers OR PRUNE with error to catch undefined" do
      left = make_error_expr("getData")
      right = AST::OrPrune.new(tok)
      node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
      node.full_type = :Number

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("catch undefined")
    end

    context "lazy fallback scoping (descend + lower_scoped)" do
      # The fallback expression is evaluated lazily. Any allocations done
      # while lowering it must NOT escape to outer @pending_stmts -- they
      # belong to the orelse/catch fallback branch and must only run when
      # that branch is actually taken. AST::BinaryOp#lazy_fields declares
      # :right as lazy when op == :OR_RESCUE; descend() wraps the right
      # side in MIR::BlockExpr containing the scoped pending stmts.
      it "wraps an allocating fallback (struct lit with heap field) in BlockExpr" do
        # Allocating fallback: a StructLit whose String field gets a
        # CopyNode-wrapped rodata literal. Lowering the field invokes
        # hoist_alloc which pushes a `Let __tmp = DeepCopy(...)` into
        # @pending_stmts. With lazy scoping that hoisted Let must land
        # inside the MIR::BlockExpr wrapping the fallback, NOT in outer
        # @pending_stmts.
        left = make_id("opt_node", full_type: :"?Node")
        lit  = make_lit(:STRING, "?", full_type: Type.new(:String, location: :rodata))
        copy = AST::CopyNode.new(tok, lit)
        copy.full_type = Type.new(:String, location: :heap)
        struct_lit = AST::StructLit.new(tok, "Node", { "label" => copy })
        struct_lit.full_type = :Node

        node = AST::BinaryOp.new(tok, left, :OR_RESCUE, struct_lit)
        node.full_type = :Node

        l = lowering(struct_schemas: { Node: { "label" => { type: Type.new(:String) } } })
        result = l.lower(node)
        expect(l.instance_variable_get(:@pending_stmts)).to be_empty
        expect(result).to be_a(MIR::Orelse)
        expect(result.fallback).to be_a(MIR::BlockExpr)
        # The hoisted dupe Let lives inside the BlockExpr's body.
        expect(result.fallback.body).to include(an_instance_of(MIR::Let))
      end

      it "leaves a non-allocating fallback unwrapped" do
        # Pure rodata fallback, no allocations -> no BlockExpr wrapping.
        left  = make_id("opt_str", full_type: :"?String")
        right = make_lit(:STRING, "default", full_type: Type.new(:String, location: :rodata))

        node = AST::BinaryOp.new(tok, left, :OR_RESCUE, right)
        node.full_type = :String

        l = lowering
        result = l.lower(node)
        expect(result).to be_a(MIR::Orelse)
        expect(result.fallback).not_to be_a(MIR::BlockExpr)
      end
    end
  end
end

RSpec.describe "MIRLowering allocation cleanup classification" do
  let(:tok) { Lexer::Token.new(:KEYWORD, "test", 1, 1) }

  def lowering(**opts)
    MIRLowering.new(**opts)
  end

  def typed_node(type)
    AST::Identifier.new(tok, "value").tap { |node| node.full_type = type }
  end

  it "only treats heap-backed MIR allocation nodes as cleanup-relevant" do
    l = lowering

    expect(l.send(:mir_allocates?, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap))).to be(true)
    expect(l.send(:mir_allocates?, MIR::DupeSlice.new(MIR::Ident.new("s"), :frame))).to be(false)
    expect(l.send(:mir_allocates?, MIR::AllocSlice.new("i64", MIR::Lit.new("4"), :heap))).to be(true)
    expect(l.send(:mir_allocates?, MIR::AllocSlice.new("i64", MIR::Lit.new("4"), :frame))).to be(false)
    expect(l.send(:mir_allocates?, MIR::HeapCreate.new("Node", MIR::StructInit.new("Node", []), :frame, nil))).to be(true)
  end

  it "recurses through casts when deciding whether an expression allocates" do
    l = lowering
    heap_copy = MIR::DeepCopy.new(MIR::Ident.new("s"), nil, nil, :string, :heap)
    frame_copy = MIR::DeepCopy.new(MIR::Ident.new("s"), nil, nil, :string, :frame)

    expect(l.send(:mir_allocates?, MIR::Cast.new(heap_copy, "[]const u8", :as))).to be(true)
    expect(l.send(:mir_allocates?, MIR::Cast.new(frame_copy, "[]const u8", :as))).to be(false)
  end

  it "classifies direct allocation cleanup entries by allocation shape" do
    l = lowering

    expect(l.send(:hoist_cleanup_entry, MIR::DupeSlice.new(MIR::Ident.new("s"), :heap), nil)).to include(kind: :heap_string)
    expect(l.send(:hoist_cleanup_entry, MIR::ConcatStr.new([MIR::Ident.new("a"), MIR::Ident.new("b")], :heap, "rt"), nil)).to include(kind: :heap_string)
    expect(l.send(:hoist_cleanup_entry, MIR::AllocSlice.new("i64", MIR::Lit.new("4"), :heap), nil)).to include(kind: :takes_slice, elem_zig_type: "i64")
    expect(l.send(:hoist_cleanup_entry, MIR::MakeList.new("i64", [MIR::Lit.new("1")], :heap), nil)).to include(kind: :list, zig_type: "std.ArrayListUnmanaged(i64)")
    expect(l.send(:hoist_cleanup_entry, MIR::HeapCreate.new("Node", MIR::StructInit.new("Node", []), :heap, nil), nil)).to include(kind: :heap_struct_plain, zig_type: "Node")
    expect(l.send(:hoist_cleanup_entry, MIR::ContainerInit.new("std.ArrayListUnmanaged(i64)", :list_empty, :heap, nil), nil)).to include(kind: :list)
  end

  it "classifies DeepCopy cleanup entries by copy strategy" do
    l = lowering

    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("s"), nil, nil, :string, :heap), nil)).to include(kind: :heap_string)
    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("xs"), nil, "i64", :list_shallow, :heap), nil)).to include(kind: :takes_slice, elem_zig_type: "i64")
    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("xs"), nil, "Value", :list_deep, :heap), nil)).to include(kind: :takes_slice, elem_zig_type: "Value")
    expect(l.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("v"), "Value", nil, :union, :heap), nil)).to include(kind: :non_copy_union, zig_type: "Value")
  end

  it "raises when a heap DeepCopy strategy lacks a cleanup mapping" do
    expect {
      lowering.send(:hoist_cleanup_entry, MIR::DeepCopy.new(MIR::Ident.new("x"), nil, nil, :full_value, :heap), nil)
    }.to raise_error(/DeepCopy with unknown strategy :full_value/)
  end

  it "classifies capability wrappers and share promotion cleanup entries" do
    l = lowering

    locked = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :sync_only, "lockedCreate", "CheatLib.Locked(Box)", nil, :heap)
    rw_locked = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :sync_only, "rwLockedCreate", "CheatLib.RwLocked(Box)", nil, :heap)
    owned = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :own_only, nil, nil, "arcCreate", :heap)
    passthrough = MIR::CapWrap.new(MIR::Ident.new("box"), "Box", :passthrough, nil, nil, nil, :heap)
    shared_node = typed_node(Type.new(:Box, ownership: :shared))

    expect(l.send(:hoist_cleanup_entry, locked, nil)).to include(kind: :locked, zig_type: "CheatLib.Locked(Box)")
    expect(l.send(:hoist_cleanup_entry, rw_locked, nil)).to include(kind: :write_locked, zig_type: "CheatLib.RwLocked(Box)")
    expect(l.send(:hoist_cleanup_entry, owned, shared_node)).to include(kind: :rc, zig_type: "CheatLib.Arc(Box)")
    expect(l.send(:hoist_cleanup_entry, passthrough, nil)).to be_nil
    expect(l.send(:hoist_cleanup_entry, MIR::SharePromote.new(MIR::Ident.new("box"), "Box", :heap), shared_node)).to include(kind: :rc, zig_type: "CheatLib.Arc(Box)")
  end

  it "delegates cleanup classification through Cast wrappers" do
    l = lowering
    inner = MIR::DeepCopy.new(MIR::Ident.new("s"), nil, nil, :string, :heap)

    expect(l.send(:hoist_cleanup_entry, MIR::Cast.new(inner, "[]const u8", :as), nil)).to include(kind: :heap_string)
  end
end
