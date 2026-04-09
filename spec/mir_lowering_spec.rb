require "rspec"
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
      expect(result).to be_a(MIR::InlineZig)
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
      expect(result).to be_a(MIR::InlineZig)
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
      expect(result).to be_a(MIR::IndexGet)
      expect(emit(result)).to eq("items[0]")
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

    it "lowers generic struct to RawZig" do
      fields = { value: { type: :T } }
      node = AST::StructDef.new(tok, "Box", fields, nil, ["T"])
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RawZig)
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
      expect(zig).to include("for (items)")
      expect(zig).to include("|item|")
    end

    it "lowers pass statement" do
      node = AST::PassStmt.new(tok)
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RawZig)
      expect(emit(result)).to eq("{}")
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
      expect(zig).to include("CheatLib.concat")
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
      expect(result).to be_a(MIR::InlineZig)
      expect(emit(result)).to include("CheatLib.assert(true,")
    end

    it "lowers raise" do
      node = AST::Raise.new(tok, :ERROR, nil, nil)
      node.full_type = :Void
      result = lowering.lower(node)
      expect(result).to be_a(MIR::RawZig)
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
end
