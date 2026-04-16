require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

RSpec.describe SemanticAnnotator do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    return ast
  end

  def get_last_type(source)
    run(source).statements.last.resolved_type
  end

  let(:ast) { run(code) }
  let(:result) { ast.statements.last.resolved_type }

  # ===========================================================================
  # Collection Types — Phase 1 (@list, @pool, Id<T>)
  # ===========================================================================
  describe "Collection Types — Phase 1" do
    def transpile_fn(src)
      ZigTranspiler.new.transpile(src)
    end

    # -------------------------------------------------------------------------
    # @list type annotation
    # -------------------------------------------------------------------------
    describe "@list (explicit heap list)" do
      it "accepts User[]@list as a valid type annotation" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String }
            FN f() RETURNS Void ->
              MUTABLE items: User[]@list = [];
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves User[]@list full_type to a list_collection? Type" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE items: User[]@list = [];
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::VarDecl) && n.name == "items" }
        expect(bind.type_info.list_collection?).to be true
      end

      it "raises when @list is applied to a non-array type" do
        expect {
          run('FN f() RETURNS Void -> x: Float64@list = 1; RETURN; END')
        }.to raise_error(SourceError, /@list requires an array type/)
      end

      it "emits ArrayListUnmanaged Zig code for @list (same as plain dynamic array)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE items: User[]@list = [];
            RETURN;
          END
        CLEAR
        expect(out).to include("ArrayListUnmanaged(User)")
      end
    end

    # -------------------------------------------------------------------------
    # @pool type annotation
    # -------------------------------------------------------------------------
    describe "@pool (generational pool)" do
      it "accepts User[100]@pool as a valid type annotation" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String, score: Float64 }
            FN f() RETURNS Void ->
              MUTABLE pool: User[100]@pool = [];
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves User[100]@pool full_type to a pool? Type" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String, score: Float64 }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::VarDecl) && n.name == "pool" }
        expect(bind.type_info.pool?).to be true
      end

      it "raises when @pool is applied to a non-array type" do
        expect {
          run('FN f() RETURNS Void -> x: Float64@pool = 1; RETURN; END')
        }.to raise_error(SourceError, /@pool requires an array type/)
      end

      it "emits CheatLib.Pool Zig type for @pool declarations" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.Pool(User).initCapacity(rt.heapAlloc(), 100)")
      end

      it "emits plain defer pool.deinit when pool is never moved" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            RETURN;
          END
        CLEAR
        expect(out).to include("defer pool.deinit(rt.heapAlloc())")
        expect(out).not_to include("pool_moved")
      end
    end

    # -------------------------------------------------------------------------
    # Id<T> type annotation
    # -------------------------------------------------------------------------
    describe "Id<T> (generational handle type)" do
      it "accepts Id<User> as a valid type annotation" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String }
            FN f() RETURNS Void ->
              MUTABLE pool: User[100]@pool = [];
              id: Id<User> = pool.insert(User{ name: "alice" });
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves Id<User> to a generic_instance Type with base :Id" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id: Id<User> = pool.insert(User{ name: "alice" });
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "id" }
        expect(bind.type_info.generic_instance?).to be true
        expect(bind.type_info.generic_base).to eq(:Id)
      end

      it "emits u64 as the Zig type for Id<T>" do
        t = Type.new(:"Id<User>")
        expect(t.zig_type).to eq("u64")
      end
    end

    # -------------------------------------------------------------------------
    # Pool method: insert
    # -------------------------------------------------------------------------
    describe "Pool#insert" do
      it "resolves pool.insert return type as Id<ElemType>" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "bob" });
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "id" }
        expect(bind.full_type.to_sym).to eq(:"Id<User>")
      end

      it "emits try pool.insert(rt.heapAlloc(), ...) in Zig" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "bob" });
            RETURN;
          END
        CLEAR
        expect(out).to include("pool.insert(rt.heapAlloc(),")
        expect(out).to include("try pool.insert")
      end

      it "raises when insert is called with zero arguments" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String }
            FN f() RETURNS Void ->
              MUTABLE pool: User[100]@pool = [];
              pool.insert();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Pool.*\.insert requires exactly 1 argument/)
      end

      it "raises when insert receives wrong element type" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String }
            FN f() RETURNS Void ->
              MUTABLE pool: User[100]@pool = [];
              pool.insert(42);
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Pool.insert/)
      end
    end

    # -------------------------------------------------------------------------
    # Pool method: get
    # -------------------------------------------------------------------------
    describe "Pool#get" do
      it "resolves pool.get return type as ?ElemType (optional)" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "alice" });
            result = pool.get(id);
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "result" }
        expect(bind.full_type.optional?).to be true
      end

      it "emits pool.get(id) without try in Zig" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "alice" });
            result = pool.get(id);
            RETURN;
          END
        CLEAR
        expect(out).to include("pool.get(id)")
        expect(out).not_to include("try pool.get")
      end

      it "raises when get is called with zero arguments" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String }
            FN f() RETURNS Void ->
              MUTABLE pool: User[100]@pool = [];
              pool.get();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Pool.*\.get requires exactly 1 argument/)
      end
    end

    # -------------------------------------------------------------------------
    # Pool method: remove
    # -------------------------------------------------------------------------
    describe "Pool#remove" do
      it "resolves pool.remove return type as Void" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "alice" });
            pool.remove(id);
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        call = fn_node.body.find { |n| n.is_a?(AST::MethodCall) && n.name == "remove" }
        expect(call.full_type.to_sym).to eq(:Void)
      end

      it "emits pool.remove(id) in Zig" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "alice" });
            pool.remove(id);
            RETURN;
          END
        CLEAR
        expect(out).to include("pool.remove(id)")
      end

      it "raises when remove is called with zero arguments" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String }
            FN f() RETURNS Void ->
              MUTABLE pool: User[100]@pool = [];
              pool.remove();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Pool.*\.remove requires exactly 1 argument/)
      end
    end

    # -------------------------------------------------------------------------
    # Unknown pool method
    # -------------------------------------------------------------------------
    describe "unknown pool method" do
      it "raises a clear error for unknown method names on a pool" do
        expect {
          run(<<~CLEAR)
            STRUCT User { name: String }
            FN f() RETURNS Void ->
              MUTABLE pool: User[100]@pool = [];
              pool.frobnicate(42);
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Unknown method 'frobnicate' on Pool<User>/)
      end
    end

    # -------------------------------------------------------------------------
    # Zig output: full pipeline for pool declaration + insert + get + remove
    # -------------------------------------------------------------------------
    describe "Zig code generation for pool operations" do
      it "emits CheatLib.Pool init, defer deinit, insert, get, and remove" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "alice" });
            result = pool.get(id);
            pool.remove(id);
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.Pool(User).initCapacity(rt.heapAlloc(), 100)")
        expect(out).to include("defer pool.deinit(rt.heapAlloc())")
        expect(out).not_to include("pool_moved")
        expect(out).to include("try pool.insert(rt.heapAlloc(),")
        expect(out).to include("pool.get(id)")
        expect(out).to include("pool.remove(id)")
      end

      it "passes @pool parameter as pointer (&pool) not by value (.items)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Item { val: Int64 }
          FN setup!(MUTABLE pool: Item[100]@pool) RETURNS Void ->
            pool.insert(Item{ val: 1 });
            RETURN;
          END
          FN f() RETURNS Void ->
            MUTABLE pool: Item[100]@pool = [];
            setup!(pool);
            RETURN;
          END
        CLEAR
        expect(out).to include("setup(rt, &pool)")
        expect(out).not_to include("pool.items")
      end
    end
  end

end
