require "rspec"
require "ostruct"
require_relative "../src/mir"
require_relative "../src/mir_lowering"
require_relative "../src/mir_emitter"
require_relative "../src/ast"
require_relative "../src/lexer"
require_relative "../src/type"

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

  def make_id(name, full_type: :Int64)
    node = AST::Identifier.new(tok, name)
    node.full_type = full_type
    node
  end

  def make_binop(left, op, right)
    node = AST::BinaryOp.new(tok, left, op, right)
    node.full_type = left.full_type
    node
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
      expect(result.kind).to eq(:list)
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
      promote = MIR::Promote.new(tok, "items", "ArrayListUnmanaged(i64)", :list, nil)
      result = lowering.lower(promote)
      expect(result).to be_a(MIR::EscapePromote)
      expect(result.name).to eq("items")
      expect(result.strategy).to eq(:list)
      expect(result.zig_type).to eq("ArrayListUnmanaged(i64)")
      zig = emit(result)
      expect(zig).to include("promoteList")
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
      expect(result).to be_a(MIR::Call)
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
      expect(result).to be_a(MIR::Call)
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
      expect(result).to be_a(MIR::Call)
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
      expect(result).to be_a(MIR::Call)
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

    it "lowers index access" do
      target = make_id("items", full_type: :Int64)
      index = make_lit(:NUMBER, 0, full_type: :Int64)
      index.coerced_type = :Int64
      node = AST::GetIndex.new(tok, target, index)
      node.full_type = :Int64
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Call)
      expect(emit(result)).to eq("CheatLib.getAt(items, 0)")
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
      node.has_cleanup = true
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

      cases = [{ value: case_val, body: case_body }]
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

      cases = [{ value: case_val, body: case_body }]
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

      cases = [{ value: case_val, body: case_body }]
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

      cases = [{ value: case_val, body: case_body }]
      node = AST::MatchStatement.new(tok, expr, cases, default_body, nil, nil, false, nil)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::SwitchStmt)
      zig = emit(result)
      expect(zig).to include("else =>")
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
      expect(emit(result)).to eq("x")
    end

    it "lowers MOVE as identity" do
      inner = make_id("handle", full_type: :Resource)
      node = AST::MoveNode.new(tok, inner)
      node.full_type = :Resource
      result = lowering.lower(node)
      expect(result).to be_a(MIR::Ident)
      expect(emit(result)).to eq("handle")
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
      node.full_type = :Range
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RangeLit)
      zig = emit(result)
      expect(zig).to include("CheatLib.Range")
      expect(zig).to include(".start = 0")
      expect(zig).to include(".end = 10")
    end

    it "lowers inclusive range (adds 1 to end)" do
      s = make_lit(:NUMBER, 0, full_type: :Int64)
      s.coerced_type = :Int64
      e = make_lit(:NUMBER, 5, full_type: :Int64)
      e.coerced_type = :Int64
      node = AST::RangeLit.new(tok, s, e, true)
      node.full_type = :Range
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
      expect(result).to be_a(MIR::Call)
      expect(emit(result)).to include("CheatLib.assert(true,")
    end

    it "lowers raise" do
      node = AST::Raise.new(tok, :ERROR, nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ReturnStmt)
      expect(emit(result)).to include("return error.CheatError")
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
      expect(result.length).to eq(2)
      expect(result.all? { |n| n.is_a?(MIR::Lit) }).to eq(true)
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

    it "uses anytype for struct params" do
      params = [{ name: "p", type: :Point, mutable: false }]
      l = lowering(struct_schemas: { Point: { x: { type: :Number }, y: { type: :Number } } })
      fn = make_fn("move", params: params)
      result = l.lower(fn)
      zig = emit(result)
      expect(zig).to include("p: anytype")
    end

    it "includes frame save/restore for value-returning frame functions" do
      fn = make_fn("compute", return_type: :Int64, uses_frame: true)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("saveFrameMark")
      expect(zig).to include("restoreFrameMark")
    end

    it "skips frame restore for string-returning functions" do
      fn = make_fn("getName", return_type: :String, uses_frame: true)
      result = lowering.lower(fn)
      zig = emit(result)
      expect(zig).to include("saveFrameMark")
      expect(zig).to include("preserveAndRewind")
      expect(zig).not_to include("restoreFrameMark")
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
      expect(zig).to include("_m_count: i64")
      expect(zig).to include("var count = _m_count;")
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
    it "lowers lambda to anonymous struct" do
      body = make_lit(:NUMBER, 42, full_type: :Int64)
      body.coerced_type = :Int64
      node = AST::LambdaLit.new(tok, [], nil, body, nil, nil)
      sig_hash = { params: [], return: { type: :Int64 }, lambda: true }
      node.full_type = sig_hash
      result = lowering.lower(node)
      expect(result).to be_a(MIR::InlineZig)
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
      expect(result).to be_a(MIR::RawZig)
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
      var_node = make_id("counter", full_type: :Counter)
      resolved = Type.new(:Counter, sync: :locked)
      cap = { var_node: var_node, alias: "c", capability: :EXCLUSIVE, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("__counter_guard")
      expect(zig).to include(".acquire()")
      expect(zig).to include("defer __counter_guard.release()")
      expect(zig).to include("const c =")
    end

    it "lowers EXCLUSIVE write_locked capability with write()" do
      var_node = make_id("counter", full_type: :Counter)
      resolved = Type.new(:Counter, sync: :write_locked)
      cap = { var_node: var_node, alias: "c", capability: :EXCLUSIVE, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include(".write()")
      expect(zig).to include("defer __counter_guard.release()")
    end

    it "lowers write_locked_read capability with read()" do
      var_node = make_id("counter", full_type: :Counter)
      resolved = Type.new(:Counter, sync: :write_locked)
      cap = { var_node: var_node, alias: "c", capability: :write_locked_read, resolved_type: resolved }
      body_lit = make_lit(:NUMBER, 1, full_type: :Int64)
      body_lit.coerced_type = :Int64
      node = AST::WithBlock.new(tok, [cap], [body_lit], nil)
      node.full_type = :Void

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include(".read()")
      expect(zig).to include("defer __counter_guard.release()")
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
      expect(result).to be_a(MIR::RawZig)
      expect(result.reason).to eq("with_block")
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
      expect(result).to be_a(MIR::RawZig)
      expect(result.reason).to eq("do_block")
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
      expect(zig).to include(".add(2)")
      expect(zig).to include("__DoBranchCtx")
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
      expect(zig).to include("x: *const")
      expect(zig).to include(".x = &x")
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
      expect(result).to be_a(MIR::RawZig)
      expect(result.reason).to eq("bg_block")
      zig = emit(result)
      expect(zig).to include("__BgCtx")
      expect(zig).to include(".spawn(")
      expect(zig).to include("fn run(")
      expect(zig).to include("spawnBest")
    end

    it "lowers BgBlock with captures" do
      body_id = make_id("x", full_type: :Int64)
      captures_hash = { "x" => :Int64 }
      analysis = OpenStruct.new(
        captures: captures_hash,
        close_patterns: {},
        pointer_captures: Set.new(["x"]),
        resource_captures: Set.new
      )
      node = AST::BgBlock.new(tok, [body_id], nil, nil, nil, nil, nil, nil)
      node.full_type = :"~Void"
      node.capture_analysis = analysis

      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include("x: *")
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
      node.full_type = :"~Void[?]"

      result = lowering.lower(node)
      expect(result).to be_a(MIR::RawZig)
      expect(result.reason).to eq("bg_stream_block")
      zig = emit(result)
      expect(zig).to include("__SgCtx")
      expect(zig).to include("spawnNew")
      expect(zig).to include(".close()")
      expect(zig).to include(".push(")
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

    it "lowers OrExit with message" do
      msg = make_lit(:STRING, "fatal", full_type: :String)
      node = AST::OrExit.new(tok, msg)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::ScopeBlock)
      zig = emit(result)
      expect(zig).to include("setError")
      expect(zig).to include("return error.CheatError")
    end

    it "lowers OrExit without message" do
      node = AST::OrExit.new(tok, nil)
      result = lowering.lower(node)
      zig = emit(result)
      expect(zig).to include('""')
      expect(zig).to include("setError")
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
      expect(result).to be_a(MIR::RawZig)
      expect(result.reason).to eq("test_block")
      zig = emit(result)
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
      zig = emit(result)
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
      expect(result).to be_a(MIR::RawZig)
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
      expect(zig).to include('matchesName("NotFound")')
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
      expect(zig).to include('@import("math")')
    end

    it "lowers local require to Comment placeholder when no importer" do
      node = AST::RequireNode.new(tok, "utils.cht", nil, :local)
      node.full_type = :Void

      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
      expect(result.text).to include("utils.cht")
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
      expect(zig).to include('@import("runtime-header.zig")')
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
      expect(zig).to include('@import("safety.zig")')
    end

    it "includes USE_C_ALLOCATOR when requested" do
      prog = AST::Program.new(tok, [])
      result = lowering.lower_program(prog, use_c_allocator: true)
      zig = emit(result)
      expect(zig).to include("USE_C_ALLOCATOR")
    end
  end

  # =========================================================================
  # Phase 5: SMOOTH (pipeline) operator
  # =========================================================================

  describe "SMOOTH pipeline lowering" do
    it "lowers simple pipe x s> f to function call via intrinsic pattern" do
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

    it "lowers pipe with args x s> f(y) to f(x, y) via intrinsic pattern" do
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

    it "lowers complex pipeline ops to Comment placeholder" do
      lhs = make_id("items", full_type: :List)
      rhs = AST::CountOp.new(tok)
      rhs.full_type = :Number

      node = AST::BinaryOp.new(tok, lhs, :SMOOTH, rhs)
      node.full_type = :Number

      result = lowering.lower(node)
      expect(result).to be_a(MIR::Comment)
      expect(result.text).to include("PIPELINE")
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
  end
end
