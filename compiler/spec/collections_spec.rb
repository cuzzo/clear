require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

RSpec.describe SemanticAnnotator do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
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
            FN f() RETURNS !Void ->
              MUTABLE items: User[]@list = [];
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves User[]@list full_type to a list_collection? Type" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS !Void ->
            MUTABLE items: User[]@list = [];
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::VarDecl) && n.name == "items" }
        expect(bind.full_type.list_collection?).to be true
      end

      it "raises when @list is applied to a non-array type" do
        expect {
          run('FN f() RETURNS Void -> x: Float64@list = 1; RETURN; END')
        }.to raise_error(SourceError, /@list requires an array type/)
      end

      it "emits ArrayListUnmanaged Zig code for @list (same as plain dynamic array)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS !Void ->
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
            FN f() RETURNS !Void ->
              MUTABLE pool: User[100]@pool = [];
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves User[100]@pool full_type to a pool? Type" do
        tree = run(<<~CLEAR)
          STRUCT User { name: String, score: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE pool: User[100]@pool = [];
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::VarDecl) && n.name == "pool" }
        expect(bind.full_type.pool?).to be true
      end

      it "raises when @pool is applied to a non-array type" do
        expect {
          run('FN f() RETURNS Void -> x: Float64@pool = 1; RETURN; END')
        }.to raise_error(SourceError, /@pool requires an array type/)
      end

      it "emits CheatLib.Pool Zig type for @pool declarations" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS !Void ->
            MUTABLE pool: User[100]@pool = [];
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.Pool(User).initCapacity(rt.heapAlloc(), 100)")
      end

      it "emits plain defer cleanup when pool is never moved" do
        out = transpile_fn(<<~CLEAR)
          STRUCT User { name: String }
          FN f() RETURNS !Void ->
            MUTABLE pool: User[100]@pool = [];
            RETURN;
          END
        CLEAR
        # Post-collapse: pool routes through CheatLib.cleanup shim (Pool arm
        # calls .deinit(alloc) internally). Functionally identical.
        expect(out).to include("defer CheatLib.cleanup(@TypeOf(pool), rt.heapAlloc(), &pool)")
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
            FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
            MUTABLE pool: User[100]@pool = [];
            id: Id<User> = pool.insert(User{ name: "alice" });
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "id" }
        expect(bind.full_type.generic_instance?).to be true
        expect(bind.full_type.generic_base).to eq(:Id)
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
          FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
            MUTABLE pool: User[100]@pool = [];
            id = pool.insert(User{ name: "alice" });
            result = pool.get(id);
            pool.remove(id);
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.Pool(User).initCapacity(rt.heapAlloc(), 100)")
        expect(out).to include("defer CheatLib.cleanup(@TypeOf(pool), rt.heapAlloc(), &pool)")
        expect(out).not_to include("pool_moved")
        expect(out).to include("try pool.insert(rt.heapAlloc(),")
        expect(out).to include("pool.get(id)")
        expect(out).to include("pool.remove(id)")
      end

      it "passes @pool parameter as pointer (&pool) not by value (.items)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Item { val: Int64 }
          FN setup!(MUTABLE pool: Item[100]@pool) RETURNS !Void ->
            pool.insert(Item{ val: 1 });
            RETURN;
          END
          FN f() RETURNS !Void ->
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

  # ===========================================================================
  # Collection interchangeability — .length(), .contains?, FOR...IN @set,
  # @set pipelines, @list/@set[i] indexing
  # ===========================================================================
  describe "Collection interchangeability" do
    def compile(src)
      ZigTranspiler.new.transpile(src, test_mode: true)
    end

    # -------------------------------------------------------------------------
    # .length() on @pool
    # -------------------------------------------------------------------------
    describe "@pool .length()" do
      it "resolves pool.length() to Int64" do
        ast = run(<<~CLEAR)
          STRUCT Item { v: Int64 }
          FN f() RETURNS !Void ->
            MUTABLE pool: Item[10]@pool = [];
            n: Int64 = pool.length();
            RETURN;
          END
        CLEAR
        expect { ast }.not_to raise_error
      end

      it "emits pool.length() Zig call" do
        out = compile(<<~CLEAR)
          STRUCT Item { v: Int64 }
          FN main() RETURNS Void ->
            MUTABLE pool: Item[10]@pool = [];
            n: Int64 = pool.length();
            RETURN;
          END
        CLEAR
        expect(out).to include("pool.length()")
      end

      it "raises error for unknown method .count() on pool" do
        expect {
          run(<<~CLEAR)
            STRUCT Item { v: Int64 }
            FN f() RETURNS Void ->
              MUTABLE pool: Item[10]@pool = [];
              n: Int64 = pool.count();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Unknown method 'count' on Pool/)
      end
    end

    # -------------------------------------------------------------------------
    # .length() on @set
    # -------------------------------------------------------------------------
    describe "@set .length()" do
      it "resolves set.length() to Int64" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              MUTABLE s: String[]@set = [];
              s.insert("a");
              n: Int64 = s.length();
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "emits set.length() Zig call" do
        out = compile(<<~CLEAR)
          FN main() RETURNS Void ->
            MUTABLE s: String[]@set = [];
            s.insert("hi");
            n: Int64 = s.length();
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.len(s)")
      end

      it "raises error for .count() on set" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              MUTABLE s: String[]@set = [];
              n: Int64 = s.count();
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Unknown method 'count' on Set/)
      end
    end

    # -------------------------------------------------------------------------
    # .contains? on T[] arrays and @list
    # -------------------------------------------------------------------------
    describe ".contains? on arrays and @list" do
      it "resolves contains?(arr, item) for Int64 array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS Void ->
              nums: Int64[] = [1, 2, 3];
              found: Bool = contains?(nums, 2);
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves contains?(list, item) for @list" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              MUTABLE list: Int64[]@list = List[];
              list.append(1);
              found: Bool = contains?(list, 1);
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "emits CheatLib.sliceContains for array contains?" do
        out = compile(<<~CLEAR)
          FN main() RETURNS Void ->
            nums: Int64[] = [1, 2, 3];
            found: Bool = contains?(nums, 2_i64);
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.sliceContains")
      end

      it "returns Bool for contains? on array" do
        ast = run(<<~CLEAR)
          FN f() RETURNS Void ->
            nums: Int64[] = [1, 2, 3];
            found = contains?(nums, 2);
            RETURN;
          END
        CLEAR
        fn = ast.statements.first
        found_bind = fn.body.find { |s| s.respond_to?(:name) && s.name == "found" }
        expect(found_bind.full_type.resolved).to eq(:Bool)
      end
    end

    # -------------------------------------------------------------------------
    # .contains? on @pool
    # -------------------------------------------------------------------------
    describe "@pool .contains?" do
      it "resolves pool.contains?(id) to Bool" do
        expect {
          run(<<~CLEAR)
            STRUCT Item { v: Int64 }
            FN f() RETURNS !Void ->
              MUTABLE pool: Item[10]@pool = [];
              id = pool.insert(Item{ v: 1 });
              found: Bool = pool.contains?(id);
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "emits pool.get(id) != null for pool.contains?" do
        out = compile(<<~CLEAR)
          STRUCT Item { v: Int64 }
          FN main() RETURNS Void ->
            MUTABLE pool: Item[10]@pool = [];
            id = pool.insert(Item{ v: 1 });
            found: Bool = pool.contains?(id);
            RETURN;
          END
        CLEAR
        expect(out).to include("pool.get(id) != null")
      end
    end

    # -------------------------------------------------------------------------
    # FOR...IN on @set
    # -------------------------------------------------------------------------
    describe "FOR...IN @set" do
      it "compiles FOR...IN on a String[]@set" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              MUTABLE s: String[]@set = [];
              s.insert("a");
              s.insert("b");
              FOR item IN s DO
                RETURN;
              END
            END
          CLEAR
        }.not_to raise_error
      end

      it "emits keyIterator loop for @set FOR...IN" do
        out = compile(<<~CLEAR)
          FN main() RETURNS Void ->
            MUTABLE s: String[]@set = [];
            s.insert("hi");
            FOR item IN s DO
              RETURN;
            END
            RETURN;
          END
        CLEAR
        expect(out).to include("keyIterator()")
        expect(out).to include(".next()")
      end
    end

    # -------------------------------------------------------------------------
    # @set[item] membership check returning ?T
    # -------------------------------------------------------------------------
    describe "@set[item] membership check" do
      it "returns ?T for @set[item] lookup" do
        ast = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            MUTABLE s: Int64[]@set = [];
            s.insert(1);
            val = s[1];
            RETURN;
          END
        CLEAR
        fn = ast.statements.first
        val_bind = fn.body.find { |s| s.respond_to?(:name) && s.name == "val" }
        expect(val_bind.full_type.optional?).to be true
      end
    end

    describe "HashMap.keys() returns String[]@list" do
      let(:repro_src) { <<~CLEAR }
        FN main() RETURNS Void ->
            MUTABLE m: HashMap<Int64> = {};
            m["a"] = 1_i64;
            m["b"] = 2_i64;
            # Direct typed assignment: `.keys()` allocates an owned
            # ArrayList; the destination is the matching
            # `String[]@list`. Round-trips cleanly.
            MUTABLE typed_keys: String[]@list = m.keys();
            ASSERT typed_keys.length() == 2_i64;
            RETURN;
        END
      CLEAR

      it "annotator accepts assigning .keys() to a String[]@list local" do
        expect { run(repro_src) }.not_to raise_error
      end

      it "stamps .keys() with a list-collection type" do
        ast = run(repro_src)
        fn = ast.statements.first
        let_node = fn.body.find { |s|
          s.respond_to?(:name) && s.name == "typed_keys"
        }
        expect(let_node).not_to be_nil
        expect(let_node.full_type.list_collection?).to be(true),
          "expected typed_keys to carry list-collection type, got " \
          "#{let_node.full_type.inspect}"
      end

      it "iterate-and-append over .keys() result still works" do
        # The stack machine pattern (_bc_runner.clear:3120). ArrayList
        # supports `xs[i]` and `.length()`, so the same code that
        # used to consume a slice continues to work unchanged.
        iterate_src = <<~CLEAR
          FN main() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m["a"] = 1_i64;
              m["b"] = 2_i64;
              ks = m.keys();
              MUTABLE typed_keys: String[]@list = [];
              FOR ki IN (0_i64 ..< ks.length()) DO
                  typed_keys.append(COPY ks[ki]);
              END
              ASSERT typed_keys.length() == 2_i64;
              RETURN;
          END
        CLEAR
        expect { run(iterate_src) }.not_to raise_error
      end
    end
  end

end
