require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/backends/transpiler"  # loads compiler, annotator, lexer, parser, ast
require_relative "../src/ast/ast"

RSpec.describe SemanticAnnotator do
  # Helper to Lex -> Parse -> Annotate
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

  # ============================================================================
  # 2. Higher-Order Functions & SELECT
  # ============================================================================
  describe "Higher-Order Syntax (SELECT)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic Projection: list s> SELECT _.method()" do
      let(:code) {
        <<~FLUX
          words: String[] = ["a", "bb", "ccc"];
          -- Project List<String> -> List<Int64> using .length()
          lengths = words s> SELECT _.length();
        FLUX
      }

      it "infers the resulting list type based on the projection body" do
        # _.length() returns Int64, so result is Int64[]
        expect(result).to eq(:"Int64[]")
      end
    end

    context "Chained Pipe: string s> split s> SELECT" do
      let(:code) {
        <<~FLUX
          raw = "apple,banana";
          -- 1. split returns String
          -- 2. SELECT iterates Strings
          -- 3. _.length() returns Int64
          lengths = raw s> split(",") s> SELECT _.length();
        FLUX
      }

      it "correctly resolves types through the chain" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "Struct/Hash Projection: list s> SELECT %{...}" do
      let(:code) {
        <<~FLUX
          nums = [10, 20];

          -- Create a List of HashMaps
          complex = nums s> SELECT %{
            "original": _,
            "doubled": _ * 2
          };
        FLUX
      }

      it "infers a List of HashMaps" do
        # The Hash contains Int64s (since _ is Int and 2 is Int inferred)
        # So it is HashMap<Int64>[]
        expect(result).to eq(:"HashMap<Int64>[]")
      end
    end

    context "Array Projection: list s> SELECT [_]" do
      let(:code) {
        <<~FLUX
          nums = [1_i64, 2_i64];
          -- Wrap each item in a list -> [[1], [2]]
          nested = nums s> SELECT [_];
        FLUX
      }

      it "infers a List of Lists (2D Array)" do
        # Inner is Int64[1] (Stack array), wrapped in Heap Array
        # The annotator usually generalizes stack arrays to [] in higher types
        expect(result.to_s).to include("Int64")
        expect(result.to_s).to end_with("][]") # Int64[][] roughly
      end
    end

    context "Error Handling: Selecting on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> SELECT _ + 1;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot SELECT from non-list type/)
      end
    end
  end

  # ============================================================================
  # 2b. Higher-Order Functions: INDEX (Group By)
  # ============================================================================
  describe "Higher-Order Syntax (INDEX)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic INDEX: list s> INDEX _.field" do
      let(:code) {
        <<~FLUX
          STRUCT User { name: String, age: Int64 }
          users = [
            User{ name: %"Alice", age: 30_i64 },
            User{ name: %"Bob", age: 30_i64 },
            User{ name: %"Charlie", age: 25_i64 }
          ];
          grouped = users s> INDEX _.age;
        FLUX
      }

      it "infers HashMap with array values" do
        # INDEX _.age returns HashMap<User[]> (grouped by age)
        expect(result).to eq(:"HashMap<User[]>")
      end
    end

    context "INDEX with string keys: list s> INDEX _.name" do
      let(:code) {
        <<~FLUX
          STRUCT Item { category: String, price: Float64 }
          items = [
            Item{ category: %"food", price: 10 },
            Item{ category: %"electronics", price: 100 },
            Item{ category: %"food", price: 20 }
          ];
          byCategory = items s> INDEX _.category;
        FLUX
      }

      it "infers HashMap with string keys and array values" do
        expect(result).to eq(:"HashMap<Item[]>")
      end
    end

    context "Error Handling: INDEX on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> INDEX _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot SELECT from non-list type/)
      end
    end
  end

  # ============================================================================
  # 2c. Higher-Order Functions: REDUCE (Fold)
  # ============================================================================
  describe "Higher-Order Syntax (REDUCE)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic REDUCE: sum of numbers" do
      let(:code) {
        <<~FLUX
          nums = [1, 2, 3, 4, 5];
          sum = nums s> REDUCE(0) acc + _;
        FLUX
      }

      it "infers the accumulator type from initial value" do
        expect(result).to eq(:Int64)
      end
    end

    context "REDUCE with struct field access" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Int64 }
          items = [
            Item{ value: 10_i64 },
            Item{ value: 20_i64 },
            Item{ value: 30_i64 }
          ];
          total = items s> REDUCE(0_i64) acc + _.value;
        FLUX
      }

      it "infers Int64 from initial value" do
        expect(result).to eq(:Int64)
      end
    end

    context "Error Handling: REDUCE on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> REDUCE(0) acc + _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot REDUCE non-list type/)
      end
    end
  end

  # ============================================================================
  # 2d. Higher-Order Functions: ORDER_BY (Sort)
  # ============================================================================
  describe "Higher-Order Syntax (ORDER_BY)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic ORDER_BY: sort by field" do
      let(:code) {
        <<~FLUX
          STRUCT Item { name: String, value: Int64 }
          items = [
            Item{ name: %"c", value: 30_i64 },
            Item{ name: %"a", value: 10_i64 },
            Item{ name: %"b", value: 20_i64 }
          ];
          sorted = items s> ORDER_BY _.value;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "ORDER_BY with simple values" do
      let(:code) {
        <<~FLUX
          nums = [3_i64, 1_i64, 2_i64];
          sorted = nums s> ORDER_BY _;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "Error Handling: ORDER_BY on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> ORDER_BY _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot SELECT from non-list type/)
      end
    end
  end

  # ============================================================================
  # 2e. Higher-Order Functions: LIMIT
  # ============================================================================
  describe "Higher-Order Syntax (LIMIT)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic LIMIT: take first n items" do
      let(:code) {
        <<~FLUX
          nums = [1_i64, 2_i64, 3_i64, 4_i64, 5_i64];
          first_three = nums s> LIMIT 3;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "LIMIT with structs" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Int64 }
          items = [
            Item{ value: 10_i64 },
            Item{ value: 20_i64 },
            Item{ value: 30_i64 }
          ];
          limited = items s> LIMIT 2;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "Error Handling: LIMIT on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> LIMIT 5;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot LIMIT non-list type/)
      end
    end
  end

  # ============================================================================
  # 2f. Higher-Order Functions: UNNEST (Flatmap)
  # ============================================================================
  describe "Higher-Order Syntax (UNNEST)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic UNNEST: flatten nested arrays" do
      let(:code) {
        <<~FLUX
          STRUCT Container { values: Int64[] }
          containers = [
            Container{ values: [1_i64, 2_i64] },
            Container{ values: [3_i64, 4_i64] }
          ];
          flattened = containers s> UNNEST _.values;
        FLUX
      }

      it "returns the inner element type" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "UNNEST with multiple containers" do
      let(:code) {
        <<~FLUX
          STRUCT Batch { nums: Float64[] }
          batches = [
            Batch{ nums: [10, 20, 30] },
            Batch{ nums: [40] },
            Batch{ nums: [50, 60] }
          ];
          all_nums = batches s> UNNEST _.nums;
        FLUX
      }

      it "returns Float64[]" do
        expect(result).to eq(:"Float64[]")
      end
    end

    context "Error Handling: UNNEST on non-array field" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Int64 }
          items = [Item{ value: 10_i64 }];
          bad = items s> UNNEST _.value;
        FLUX
      }

      it "raises a semantic error suggesting SELECT" do
        expect { run(code) }.to raise_error(/UNNEST requires an array expression.*Use SELECT instead/)
      end
    end

    context "Error Handling: UNNEST on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> UNNEST _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot UNNEST non-list type/)
      end
    end
  end

  # ============================================================================
  # 2g. Higher-Order Functions: DISTINCT (Unique elements)
  # ============================================================================
  describe "Higher-Order Syntax (DISTINCT)" do
    let(:result) { ast.statements.last.full_type }

    context "Basic DISTINCT: unique elements by value" do
      let(:code) {
        <<~FLUX
          nums = [1, 2, 1, 3, 2, 4];
          unique = nums s> DISTINCT _;
        FLUX
      }

      it "returns the same list type" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "DISTINCT by struct field" do
      let(:code) {
        <<~FLUX
          STRUCT Item { id: Int64, name: String }
          items = [
            Item{ id: 1_i64, name: %"a" },
            Item{ id: 2_i64, name: %"b" },
            Item{ id: 1_i64, name: %"c" }
          ];
          unique_by_id = items s> DISTINCT _.id;
        FLUX
      }

      it "returns Set type of the key field" do
        expect(result).to eq(:"Int64[]")
      end
    end

    context "Error Handling: DISTINCT on a non-list" do
      let(:code) {
        <<~FLUX
          num = 100;
          bad = num s> DISTINCT _;
        FLUX
      }

      it "raises a semantic error" do
        expect { run(code) }.to raise_error(/Cannot DISTINCT non-list type/)
      end
    end
  end

  # ===========================================================================
  # Collection Types — Phase 2 (@pool:sharded(N), @list:sharded(N), EACH)
  # ===========================================================================
  describe "Collection Types — Phase 2" do
    def transpile_fn(src)
      ZigTranspiler.new.transpile(src)
    end

    def find_var(tree, fn_name, var_name)
      fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == fn_name }
      fn_node.body.find { |n| n.is_a?(AST::VarDecl) && n.name == var_name }
    end

    # -------------------------------------------------------------------------
    # @pool:sharded(N) type annotation
    # -------------------------------------------------------------------------
    describe "@pool:sharded(N) (sharded generational pool)" do
      it "accepts Score[100]@pool:sharded(4) as a valid type annotation" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              MUTABLE sp: Score[100]@pool:sharded(4) = [];
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves Score[100]@pool:sharded(4) full_type to a sharded pool? Type" do
        tree = run(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE sp: Score[100]@pool:sharded(4) = [];
            RETURN;
          END
        CLEAR
        bind = find_var(tree, "f", "sp")
        expect(bind.type_info.pool?).to be true
        expect(bind.type_info.sharded?).to be true
        expect(bind.type_info.shard_count).to eq(4)
      end

      it "emits CheatLib.ShardedPool Zig type for @pool:sharded(4)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE sp: Score[100]@pool:sharded(4) = [];
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.ShardedPool(Score, 4).initCapacity(rt.heapAlloc(), 100)")
      end

      it "emits plain defer sp.deinit when sharded pool is never moved" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE sp: Score[100]@pool:sharded(4) = [];
            RETURN;
          END
        CLEAR
        expect(out).to include("defer sp.deinit(rt.heapAlloc())")
        expect(out).not_to include("sp_moved")
      end

      it "raises for @pool:sharded(1) — shard count must be >= 2" do
        expect {
          run('FN f() RETURNS !Void -> MUTABLE sp: Float64[100]@pool:sharded(1) = []; RETURN; END')
        }.to raise_error(SourceError, /requires N >= 2/)
      end

      it "raises for @pool:sharded on a non-array type" do
        expect {
          run('FN f() RETURNS !Void -> x: Float64@pool:sharded(2) = 1; RETURN; END')
        }.to raise_error(SourceError, /@pool requires an array type/)
      end

      it "allows insert/get/remove/length on a sharded pool" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              MUTABLE sp: Score[100]@pool:sharded(4) = [];
              id = sp.insert(Score{ value: 1.0 });
              result = sp.get(id);
              sp.remove(id);
              n = sp.length();
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "emits ShardedPool insert/get/remove/length Zig calls" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE sp: Score[100]@pool:sharded(4) = [];
            id = sp.insert(Score{ value: 1.0 });
            result = sp.get(id);
            sp.remove(id);
            n = sp.length();
            RETURN;
          END
        CLEAR
        expect(out).to include("try sp.insert(rt.heapAlloc(),")
        expect(out).to include("sp.get(id)")
        expect(out).to include("sp.remove(id)")
        expect(out).to include("sp.length()")
      end
    end

    # -------------------------------------------------------------------------
    # @list:sharded(N) type annotation
    # -------------------------------------------------------------------------
    describe "@list:sharded(N) (sharded list)" do
      it "accepts Score[]@list:sharded(2) as a valid type annotation" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              MUTABLE sl: Score[]@list:sharded(2) = [];
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "resolves Score[]@list:sharded(2) to a sharded list_collection? Type" do
        tree = run(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE sl: Score[]@list:sharded(2) = [];
            RETURN;
          END
        CLEAR
        bind = find_var(tree, "f", "sl")
        expect(bind.type_info.list_collection?).to be true
        expect(bind.type_info.sharded?).to be true
        expect(bind.type_info.shard_count).to eq(2)
      end

      it "emits CheatLib.ShardedList Zig type for @list:sharded(2)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE sl: Score[]@list:sharded(2) = [];
            RETURN;
          END
        CLEAR
        expect(out).to include("CheatLib.ShardedList(Score, 2){}")
      end

      it "raises for @list:sharded(1) — shard count must be >= 2" do
        expect {
          run('FN f() RETURNS !Void -> MUTABLE sl: Float64[]@list:sharded(1) = []; RETURN; END')
        }.to raise_error(SourceError, /requires N >= 2/)
      end

      it "raises for @list:sharded on a non-array type" do
        expect {
          run('FN f() RETURNS !Void -> x: Float64@list:sharded(2) = 1; RETURN; END')
        }.to raise_error(SourceError, /@list requires an array type/)
      end
    end

    # -------------------------------------------------------------------------
    # EACH pipeline operator
    # -------------------------------------------------------------------------
    describe "EACH side-effect iteration" do
      it "accepts EACH on a plain array" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              items: Score[] = [];
              items s> EACH { _.value = 0.0; };
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts EACH on a @list collection" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              MUTABLE items: Score[]@list = [];
              items s> EACH { _.value = 0.0; };
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts EACH on a @pool collection" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              MUTABLE pool: Score[100]@pool = [];
              pool s> EACH { _.value = 0.0; };
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "accepts EACH on a @pool:sharded(N) collection" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              MUTABLE sp: Score[100]@pool:sharded(4) = [];
              sp s> EACH { _.value = 0.0; };
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises a clear error when EACH is applied to a non-collection" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 42.0;
              x s> EACH { _ = 0.0; };
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot EACH non-collection type/)
      end

      it "emits a sequential for loop for EACH on plain arrays" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            items: Score[] = [];
            items s> EACH { _.value = 0.0; };
            RETURN;
          END
        CLEAR
        expect(out).to include("for (items.items)")
        expect(out).to include("|*__it")
      end

      it "emits pool slot scan for EACH on @pool" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE pool: Score[100]@pool = [];
            pool s> EACH { _.value = 0.0; };
            RETURN;
          END
        CLEAR
        expect(out).to include("slots)")
        expect(out).to include("__each_slot.alive")
      end

      it "emits N parallel fiber structs for EACH on @pool:sharded(4)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE sp: Score[100]@pool:sharded(4) = [];
            sp s> EACH { _.value = 0.0; };
            RETURN;
          END
        CLEAR
        expect(out).to include("WaitGroup")
        expect(out).to include("submitSpawn")
        expect(out).to include("__EachShardCtx0_0")
        expect(out).to include("__EachShardCtx0_1")
        expect(out).to include("__EachShardCtx0_2")
        expect(out).to include("__EachShardCtx0_3")
      end

      it "uses __it in Zig output (Zig reserves _ as discard identifier)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            items: Score[] = [];
            items s> EACH { _.value = 0.0; };
            RETURN;
          END
        CLEAR
        expect(out).to include("__it")
        expect(out).not_to match(/\bconst _ =/)
      end

      it "EACH on array emits mutable pointer iteration (|*__it|)" do
        out = transpile_fn(<<~CLEAR)
          STRUCT Score { value: Float64 }
          FN f() RETURNS !Void ->
            items: Score[] = [];
            items s> EACH { _.value = 0.0; };
            RETURN;
          END
        CLEAR
        expect(out).to include("|*__it")
      end
    end

    describe "HashMap@sharded(N) (sharded hash map)" do
      it "accepts HashMap<Int64>@sharded(2) as a valid type annotation" do
        expect {
          run("FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(2) = {}; RETURN; END")
        }.not_to raise_error
      end

      it "generates ShardedStringMap Zig type" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(2) = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("CheatLib.PartitionedStringMap(i64, 2)")
      end

      it "emits .put() for index assignment on sharded map" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@sharded(2) = {};
              m["key"] = 42_i64;
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.put(')
      end

      it "emits .get() for index access on sharded map" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@sharded(2) = {};
              m["key"] = 42_i64;
              v = m["key"] OR 0;
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.get(')
      end

      it "emits .count() for count method on sharded map" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@sharded(2) = {};
              n: Int64 = m.count();
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.count()')
      end
    end

    describe "HashMap@sharded(N):locked (lock-striped hash map via composition)" do
      it "accepts HashMap<Int64>@sharded(4):locked as a valid type annotation" do
        expect {
          run("FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(4):locked = {}; RETURN; END")
        }.not_to raise_error
      end

      it "generates MutexShardedStringMap (Mutex) Zig type from @sharded:locked" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(4):locked = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("CheatLib.MutexShardedStringMap(i64, 4)")
      end

      it "emits .put() for index assignment" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@sharded(4):locked = {};
              m["key"] = 42_i64;
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.put(')
      end

      it "emits .get() for index access" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@sharded(4):locked = {};
              m["key"] = 42_i64;
              v = m["key"] OR 0;
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.get(')
      end

      it "plain :sharded(4) without @locked generates PartitionedStringMap (shared-nothing)" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(4) = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("CheatLib.PartitionedStringMap(i64, 4)")
        expect(zig).not_to include("Striped")
      end

      it "supports @writeLocked for read-heavy workloads" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(4):writeLocked = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("CheatLib.ShardedStringMap(i64, 4)")
      end
    end

    describe "HashMap@shared:sharded(N):writeLocked (DashMap — Arc-wrapped lock-striped map)" do
      it "accepts @shared:sharded(N):writeLocked as a valid type annotation" do
        expect {
          run("FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@shared:sharded(4):writeLocked = {}; RETURN; END")
        }.not_to raise_error
      end

      it "generates Arc-wrapped ShardedStringMap via arcCreate" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@shared:sharded(4):writeLocked = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("arcCreate(CheatLib.ShardedStringMap(i64, 4)")
      end

      it "generates Arc-wrapped MutexShardedStringMap for @shared:sharded(N):locked" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@shared:sharded(4):locked = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("arcCreate(CheatLib.MutexShardedStringMap(i64, 4)")
      end

      it "emits arcCreate for initialization" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@shared:sharded(4):writeLocked = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("arcCreate(CheatLib.ShardedStringMap(i64, 4)")
      end

      it "emits cleanup for shared sharded map" do
        code = "FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@shared:sharded(4):writeLocked = {}; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("CheatLib.cleanup(")
        expect(zig).to include("rt.heapAlloc()")
      end

      it "auto-derefs Arc for index read (.get)" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@shared:sharded(4):writeLocked = {};
              m["key"] = 42_i64;
              v = m["key"] OR 0;
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.ctrl.data.*.get(')
      end

      it "auto-derefs Arc for index write (.put)" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@shared:sharded(4):writeLocked = {};
              m["key"] = 42_i64;
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.ctrl.data.*.put(')
      end

      it "auto-derefs Arc for .count()" do
        code = <<~CLEAR
          FN f() RETURNS !Void ->
              MUTABLE m: HashMap<Int64>@shared:sharded(4):writeLocked = {};
              n: Int64 = m.count();
              RETURN;
          END
        CLEAR
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include('.ctrl.data.*.count()')
      end
    end
  end

  # ===========================================================================
  # @pool:soa (Structure of Arrays pool)
  # ===========================================================================
  describe "@pool:soa (SOA generational pool)" do
    it "accepts Entity[100]@pool:soa as a valid type annotation" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
        FN f() RETURNS !Void -> MUTABLE pool: Entity[100]@pool:soa = []; RETURN; END
      CLEAR
      expect { run(code) }.not_to raise_error
    end

    it "generates SoaPool Zig type" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
        FN f() RETURNS !Void -> MUTABLE pool: Entity[100]@pool:soa = []; RETURN; END
      CLEAR
      zig = ZigTranspiler.new.transpile(code)
      expect(zig).to include("CheatLib.SoaPool(Entity)")
      expect(zig).not_to include("CheatLib.Pool(Entity)")
    end

    it "plain @pool still generates Pool (not SoaPool)" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64 }
        FN f() RETURNS !Void -> MUTABLE pool: Entity[100]@pool = []; RETURN; END
      CLEAR
      zig = ZigTranspiler.new.transpile(code)
      expect(zig).to include("CheatLib.Pool(Entity)")
      expect(zig).not_to include("SoaPool")
    end

    it "emits defer deinit for @pool:soa" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
        FN f() RETURNS !Void -> MUTABLE pool: Entity[100]@pool:soa = []; RETURN; END
      CLEAR
      zig = ZigTranspiler.new.transpile(code)
      expect(zig).to include("pool.deinit(")
    end
  end

  # ===========================================================================
  # Collection Constructor Sugar (List<T>[], Pool<T>[], List[], etc.)
  # ===========================================================================
  describe "Collection constructor sugar" do
    it "List[] with lazy inference narrows type on append" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS !Void ->
          MUTABLE items = List[];
          append(items, 42_i64);
          RETURN;
        END
      CLEAR
      # Should narrow from Any to i64-compatible
      expect(zig).to include("items.append(")
    end

    it "List[] used in pipeline before append raises helpful error" do
      code = <<~CLEAR
        STRUCT Score { value: Float64 }
        FN f() RETURNS !Void ->
          MUTABLE items = List[];
          total = items s> SUM _.value;
          RETURN;
        END
      CLEAR
      # TODO: improve this error to suggest "append an item first or use explicit type: Score[]@list"
      expect { run(code) }.to raise_error(/Cannot determine struct type.*'Any'/i)
    end

    it "old syntax T[]@list still works" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS !Void -> MUTABLE items: Int64[]@list = []; RETURN; END
      CLEAR
      expect(zig).to include("ArrayListUnmanaged(i64)")
    end
  end

  # ===========================================================================
  # @list:soa (SOA dynamic list)
  # ===========================================================================
  describe "@list:soa (SOA dynamic list)" do
    it "accepts Entity[]@list:soa as a valid type annotation" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
        FN f() RETURNS !Void -> MUTABLE items: Entity[]@list:soa = []; RETURN; END
      CLEAR
      expect { run(code) }.not_to raise_error
    end

    it "generates SoaList Zig type" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
        FN f() RETURNS !Void -> MUTABLE items: Entity[]@list:soa = []; RETURN; END
      CLEAR
      zig = ZigTranspiler.new.transpile(code)
      expect(zig).to include("CheatLib.SoaList(Entity)")
    end

    it "uses field-slice iteration for SUM (no alive check)" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
        FN f() RETURNS !Float64 ->
          MUTABLE items: Entity[]@list:soa = [];
          total = items s> SUM _.health;
          RETURN total;
        END
      CLEAR
      zig = ZigTranspiler.new.transpile(code)
      expect(zig).to include("data.items(.health)")
      # SOA list path should NOT have alive check (that's pool-only)
      user_code = zig.split("// 3. Main Entry").first
      expect(user_code).not_to include("alive")
    end

    it "plain @list still generates ArrayListUnmanaged (not SoaList)" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64 }
        FN f() RETURNS !Void -> MUTABLE items: Entity[]@list = []; RETURN; END
      CLEAR
      zig = ZigTranspiler.new.transpile(code)
      expect(zig).to include("ArrayListUnmanaged(Entity)")
      expect(zig).not_to include("SoaList")
    end
  end

  # ===========================================================================
  # SOA + FFI guard
  # ===========================================================================
  describe "SOA FFI guard" do
    it "rejects @pool:soa passed to EXTERN FN" do
      code = <<~CLEAR
        STRUCT Vec2 { x: Float64, y: Float64 }
        EXTERN FN process_vecs(data: Vec2) RETURNS Void FROM "native";
        FN f() RETURNS !Void ->
          MUTABLE pool: Vec2[100]@pool:soa = [];
          process_vecs(pool);
          RETURN;
        END
      CLEAR
      expect { run(code) }.to raise_error(/@soa.*EXTERN|incompatible.*C ABI/i)
    end

    it "rejects @list:soa passed to EXTERN FN" do
      code = <<~CLEAR
        STRUCT Vec2 { x: Float64, y: Float64 }
        EXTERN FN process_vecs(data: Vec2) RETURNS Void FROM "native";
        FN f() RETURNS !Void ->
          MUTABLE items: Vec2[]@list:soa = [];
          process_vecs(items);
          RETURN;
        END
      CLEAR
      expect { run(code) }.to raise_error(/@soa.*EXTERN|incompatible.*C ABI/i)
    end

    it "allows regular struct passed to EXTERN FN (non-SOA)" do
      code = <<~CLEAR
        STRUCT Vec2 { x: Float64, y: Float64 }
        EXTERN FN process_vec(data: Vec2) RETURNS Void FROM "native";
        FN f() RETURNS !Void ->
          v = Vec2{ x: 1.0, y: 2.0 };
          process_vec(v);
          RETURN;
        END
      CLEAR
      expect { run(code) }.not_to raise_error
    end
  end

  # ===========================================================================
  # Capability validation (capabilities.rb)
  # ===========================================================================
  describe "Capability validation" do
    it "rejects @locked:writeLocked (conflicting sync — caught by parser)" do
      code = "FN f() RETURNS !Void -> MUTABLE x = 1.0 @locked:writeLocked; RETURN; END"
      expect { run(code) }.to raise_error(/Duplicate sync|Conflicting sync/i)
    end

    it "rejects @shared:multiowned (conflicting ownership — caught by parser)" do
      code = "STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 1 } @shared:multiowned; RETURN; END"
      expect { run(code) }.to raise_error(/Duplicate ownership|Conflicting ownership/i)
    end

    it "allows valid combinations (@shared:locked)" do
      code = "STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 1 } @shared:locked; RETURN; END"
      expect { run(code) }.not_to raise_error
    end
  end

  # ===========================================================================
  # SOA Opportunity Detection
  # ===========================================================================
  describe "SOA opportunity warnings" do
    def capture_notes(code)
      notes = []
      allow($stderr).to receive(:puts) do |msg|
        notes << msg if msg.include?("[Note]")
      end
      ZigTranspiler.new.transpile(code)
      notes
    end

    it "warns when pipeline accesses < 50% of fields on a large struct (SUM)" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64, mana: Float64, name: String, level: Float64 }
        FN f() RETURNS !Void ->
          MUTABLE entities: Entity[] = [];
          total = entities s> SUM _.x;
          RETURN;
        END
      CLEAR
      notes = capture_notes(code)
      soa_note = notes.find { |n| n.include?("@soa") }
      expect(soa_note).not_to be_nil
      expect(soa_note).to include("1 of 8")
    end

    it "warns for EACH accessing few fields" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64, mana: Float64, name: String, level: Float64 }
        FN f() RETURNS !Void ->
          MUTABLE entities: Entity[] = [];
          entities s> EACH { _.x = _.x + _.vx; };
          RETURN;
        END
      CLEAR
      notes = capture_notes(code)
      soa_note = notes.find { |n| n.include?("@soa") }
      expect(soa_note).not_to be_nil
      expect(soa_note).to include("2 of 8")
    end

    it "does NOT warn for small structs (< 4 fields)" do
      code = <<~CLEAR
        STRUCT Point { x: Float64, y: Float64, z: Float64 }
        FN f() RETURNS !Void ->
          MUTABLE pts: Point[] = [];
          total = pts s> SUM _.x;
          RETURN;
        END
      CLEAR
      notes = capture_notes(code)
      soa_note = notes.find { |n| n.include?("@soa") }
      expect(soa_note).to be_nil
    end

    it "does NOT warn when >= 50% of fields are accessed" do
      code = <<~CLEAR
        STRUCT Stats { a: Float64, b: Float64, c: Float64, d: Float64 }
        FN f() RETURNS !Void ->
          MUTABLE data: Stats[] = [];
          data s> EACH { _.a = _.a + _.b; };
          RETURN;
        END
      CLEAR
      notes = capture_notes(code)
      soa_note = notes.find { |n| n.include?("@soa") }
      expect(soa_note).to be_nil
    end

    it "does NOT warn when most fields are accessed" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64 }
        FN f() RETURNS !Void ->
          MUTABLE entities: Entity[] = [];
          entities s> EACH { _.x = _.x + _.vx; _.y = _.y + _.vy; _.health = _.health - 1.0; };
          RETURN;
        END
      CLEAR
      notes = capture_notes(code)
      soa_note = notes.find { |n| n.include?("@soa") }
      expect(soa_note).to be_nil
    end

    it "does NOT warn for non-struct element types" do
      code = <<~CLEAR
        FN f() RETURNS !Void ->
          MUTABLE nums: Float64[] = [];
          total = nums s> SUM _;
          RETURN;
        END
      CLEAR
      notes = capture_notes(code)
      soa_note = notes.find { |n| n.include?("@soa") }
      expect(soa_note).to be_nil
    end

    it "warns for WHERE accessing few fields" do
      code = <<~CLEAR
        STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64, mana: Float64, name: String, level: Float64 }
        FN f() RETURNS !Void ->
          MUTABLE entities: Entity[] = [];
          alive = entities s> WHERE _.health > 0;
          RETURN;
        END
      CLEAR
      notes = capture_notes(code)
      soa_note = notes.find { |n| n.include?("@soa") }
      expect(soa_note).not_to be_nil
      expect(soa_note).to include("1 of 8")
    end
  end

  # ===========================================================================
  # TAKE_WHILE
  # ===========================================================================
  describe "TAKE_WHILE" do
    it "returns same element type as input" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            data: Float64[] = [1.0, 2.0, 3.0];
            result = data s> TAKE_WHILE _ < 5.0;
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Float64[]")
    end

    it "rejects non-Bool predicate" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              data: Float64[] = [1.0];
              result = data s> TAKE_WHILE _ + 1.0;
          END
        CLEAR
      }.to raise_error(CompilerError, /TAKE_WHILE predicate must evaluate to Bool/)
    end

    it "rejects non-list input" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              result = x s> TAKE_WHILE _ < 5.0;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot TAKE_WHILE non-list/)
    end
  end

  # ===========================================================================
  # WINDOW
  # ===========================================================================
  describe "WINDOW" do
    it "result type is expression-type[]" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            data: Float64[] = [1.0, 2.0, 3.0];
            result = data s> WINDOW(2) _.length();
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Int64[]")
    end

    it "rejects non-numeric size" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              data: Float64[] = [1.0];
              result = data s> WINDOW("bad") _.length();
          END
        CLEAR
      }.to raise_error(CompilerError, /WINDOW size must be a number/)
    end

    it "rejects non-list input" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              result = x s> WINDOW(2) _.length();
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot WINDOW non-list/)
    end
  end

  # ===========================================================================
  # WINDOW (batch/tumbling)
  # ===========================================================================
  describe "WINDOW(size:, time:)" do
    it "size-only: result type is expression-type[]" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            data: Int64[] = [1, 2, 3, 4, 5];
            result = data s> WINDOW(size: 3) _.length();
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Int64[]")
    end

    it "time-only: result type is expression-type[]" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            data: Int64[] = [1, 2, 3];
            result = data s> WINDOW(time: "500ms") _.length();
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Int64[]")
    end

    it "size + time: both named params accepted" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            data: Int64[] = [1, 2, 3];
            result = data s> WINDOW(size: 2, time: "1s") _.length();
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Int64[]")
    end

    it "rejects when neither size nor time is provided" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              data: Int64[] = [1, 2, 3];
              result = data s> WINDOW(size: 3) _.length();
              result2 = data s> WINDOW(size: 0) _.length();
          END
        CLEAR
      }.to raise_error(CompilerError, /WINDOW size must be > 0/)
    end

    it "rejects unknown option key" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              data: Int64[] = [1, 2, 3];
              result = data s> WINDOW(bad_key: 3) _.length();
          END
        CLEAR
      }.to raise_error(CompilerError, /Unknown WINDOW option/)
    end

    it "rejects non-numeric size" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              data: Int64[] = [1, 2, 3];
              result = data s> WINDOW(size: "bad") _.length();
          END
        CLEAR
      }.to raise_error(CompilerError, /WINDOW size must be a number/)
    end

    it "rejects invalid time format" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              data: Int64[] = [1, 2, 3];
              result = data s> WINDOW(time: "5x") _.length();
          END
        CLEAR
      }.to raise_error(CompilerError, /WINDOW time format must be like/)
    end

    it "rejects non-string time" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              data: Int64[] = [1, 2, 3];
              result = data s> WINDOW(time: 500) _.length();
          END
        CLEAR
      }.to raise_error(CompilerError, /WINDOW time must be a string literal/)
    end

    it "accepts open stream source (~?T[])" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            gen: ~?Int64[] = BG STREAM { YIELD 1; YIELD 2; };
            result = gen s> WINDOW(size: 2) _.length();
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Int64[]")
    end

    it "accepts inf stream source (~T[INF])" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            gen: ~Int64[INF] = BG STREAM { YIELD 1; YIELD 2; };
            result = gen s> WINDOW(size: 2) _.length();
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Int64[]")
    end
  end

  # ===========================================================================
  # JOIN
  # ===========================================================================
  describe "JOIN" do
    it "result type is JoinResult_L_R[]" do
      tree = run(<<~CLEAR)
        STRUCT A { id: Int64 }
        STRUCT B { id: Int64 }
        FN f() RETURNS !Void ->
            as: A[] = [A{ id: 1 }];
            bs: B[] = [B{ id: 1 }];
            result = as s> JOIN(bs) %(a, b) -> a.id == b.id;
        END
      CLEAR
      bind = tree.statements.last.body.last
      expect(bind.full_type.to_s).to include("JoinResult")
      expect(bind.full_type.to_s).to include("[]")
    end

    it "rejects non-list right source" do
      expect {
        run(<<~CLEAR)
          STRUCT A { id: Int64 }
          FN f() RETURNS !Void ->
              as: A[] = [A{ id: 1 }];
              b: Int64 = 1;
              result = as s> JOIN(b) %(a, b2) -> TRUE;
          END
        CLEAR
      }.to raise_error(CompilerError, /JOIN right source must be a list/)
    end

    it "rejects lambda with wrong param count" do
      expect {
        run(<<~CLEAR)
          STRUCT A { id: Int64 }
          STRUCT B { id: Int64 }
          FN f() RETURNS !Void ->
              as: A[] = [A{ id: 1 }];
              bs: B[] = [B{ id: 1 }];
              result = as s> JOIN(bs) %(x) -> TRUE;
          END
        CLEAR
      }.to raise_error(CompilerError, /JOIN lambda must take exactly 2 parameters/)
    end
  end

  # ===========================================================================
  # TAP
  # ===========================================================================
  describe "TAP" do
    it "result type is the input collection type (passthrough)" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            data: Float64[] = [1.0, 2.0, 3.0];
            result = data s> TAP { _ + 0.0; };
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Float64[]")
    end

    it "can be chained before an aggregate" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Float64 ->
            data: Float64[] = [1.0, 2.0];
            total = data s> TAP { _ + 0.0; } s> SUM _;
            RETURN total;
        END
      CLEAR
      fn = tree.statements.first
      expect(fn.body.last.full_type).to eq(:Float64)
    end

    it "rejects non-list input" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              result = x s> TAP { _ + 0.0; };
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot TAP non-collection/)
    end

    it "generates a for loop over the collection elements" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        FN f() RETURNS !Float64 ->
            data: Float64[] = [1.0, 2.0];
            total = data s> TAP { _ + 0.0; } s> SUM _;
            RETURN total;
        END
      CLEAR
      expect(zig).to include("for (")
    end
  end

  # ===========================================================================
  # SKIP
  # ===========================================================================
  describe "SKIP" do
    it "result type matches the input element type" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Void ->
            data: Float64[] = [1.0, 2.0, 3.0];
            rest = data s> SKIP 1_i64;
        END
      CLEAR
      bind = tree.statements.first.body.last
      expect(bind.full_type.to_s).to eq("Float64[]")
    end

    it "preserves element type for struct collections" do
      tree = run(<<~CLEAR)
        STRUCT Item { value: Float64 }
        FN f() RETURNS !Void ->
            items: Item[] = [Item{ value: 1.0 }];
            rest = items s> SKIP 1_i64;
        END
      CLEAR
      fn = tree.statements.last
      bind = fn.body.last
      expect(bind.full_type.to_s).to eq("Item[]")
    end

    it "rejects non-list input" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              result = x s> SKIP 1_i64;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot SKIP non-list/)
    end

    it "can be chained with other operators" do
      tree = run(<<~CLEAR)
        FN f() RETURNS !Float64 ->
            data: Float64[] = [1.0, 2.0, 3.0];
            total = data s> SKIP 1_i64 s> SUM _;
            RETURN total;
        END
      CLEAR
      fn = tree.statements.first
      expect(fn.body.last.full_type).to eq(:Float64)
    end
  end

  # ===========================================================================
  # Collection Types — Phase 3 (FIND, ANY, ALL, COUNT predicate query operators)
  # ===========================================================================
  describe "Collection Types — Phase 3 (FIND, ANY, ALL, COUNT)" do
    def transpile_fn(src)
      ZigTranspiler.new.transpile(src)
    end

    # -------------------------------------------------------------------------
    # FIND — returns ?ElemType
    # -------------------------------------------------------------------------
    describe "FIND predicate operator" do
      it "infers ?Float64 for a FIND on Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0, 3.0];
            result = nums s> FIND _ > 2.0;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.full_type.to_s).to eq("?Float64")
      end

      it "infers ?Item for a FIND on a struct array" do
        tree = run(<<~CLEAR)
          STRUCT Item { x: Float64 }
          FN f() RETURNS !Void ->
            items: Item[] = [];
            result = items s> FIND _.x > 0.0;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.full_type.to_s).to eq("?Item")
      end

      it "raises a clear error when FIND is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> FIND _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot FIND non-list type/)
      end

      it "raises when FIND predicate does not evaluate to Bool" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> FIND _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /FIND clause must evaluate to Bool/)
      end

      it "emits a result variable initialized to null for FIND in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0];
            result = nums s> FIND _ > 1.0;
            RETURN;
          END
        CLEAR
        expect(out).to include("null")
        expect(out).to include("__res")
        expect(out).to include("break")
      end

      it "emits a for loop with break on match for FIND" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> FIND _ > 0.5;
            RETURN;
          END
        CLEAR
        expect(out).to include("__res")
        expect(out).to include("break")
      end
    end

    # -------------------------------------------------------------------------
    # ANY — returns Bool
    # -------------------------------------------------------------------------
    describe "ANY predicate operator" do
      it "infers Bool for ANY on a Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0];
            result = nums s> ANY _ > 1.0;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.resolved_type).to eq(:Bool)
      end

      it "raises when ANY is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> ANY _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot ANY non-list type/)
      end

      it "raises when ANY predicate does not evaluate to Bool" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> ANY _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /ANY clause must evaluate to Bool/)
      end

      it "emits a bool accumulator and short-circuit break in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> ANY _ > 0.0;
            RETURN;
          END
        CLEAR
        expect(out).to include("true")
        expect(out).to include("break")
      end

      it "emits a for loop over collection items" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> ANY _ > 0.0;
            RETURN;
          END
        CLEAR
        expect(out).to include("for (")
        expect(out).to include("__res")
      end
    end

    # -------------------------------------------------------------------------
    # ALL — returns Bool
    # -------------------------------------------------------------------------
    describe "ALL predicate operator" do
      it "infers Bool for ALL on a Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0];
            result = nums s> ALL _ > 0.0;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.resolved_type).to eq(:Bool)
      end

      it "raises when ALL is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> ALL _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot ALL non-list type/)
      end

      it "raises when ALL predicate does not evaluate to Bool" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> ALL _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /ALL clause must evaluate to Bool/)
      end

      it "emits a bool accumulator initialized to true and negated short-circuit in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> ALL _ > 0.0;
            RETURN;
          END
        CLEAR
        expect(out).to include("true")
        expect(out).to include("false")
        expect(out).to include("!")
      end

      it "vacuous truth: accumulator starts as true (correct for empty list)" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [];
            result = nums s> ALL _ > 0.0;
            RETURN;
          END
        CLEAR
        expect(out).to include("true")
        expect(out).to include("__blk_")
      end
    end

    # -------------------------------------------------------------------------
    # COUNT — returns Int64
    # -------------------------------------------------------------------------
    describe "COUNT predicate operator" do
      it "infers Int64 for COUNT on a Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0, 3.0];
            result = nums s> COUNT _ > 1.0;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.resolved_type).to eq(:Int64)
      end

      it "raises when COUNT is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> COUNT _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot COUNT non-list type/)
      end

      it "raises when COUNT predicate does not evaluate to Bool" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> COUNT _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /COUNT clause must evaluate to Bool/)
      end

      it "emits a counter accumulator and increment in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0];
            result = nums s> COUNT _ > 1.0;
            RETURN;
          END
        CLEAR
        expect(out).to include("__res")
        expect(out).to include("+ 1")
      end

      it "wraps the predicate in an if condition in the loop" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> COUNT _ > 0.0;
            RETURN;
          END
        CLEAR
        expect(out).to include("for (")
        expect(out).to include("if (")
      end
    end

    # -------------------------------------------------------------------------
    # Cross-operator and chaining
    # -------------------------------------------------------------------------
    describe "operator chaining and combined usage" do
      it "allows COUNT after WHERE (chained pipeline)" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0, 2.0, 3.0, 4.0];
              filtered: Float64[] = nums s> WHERE _ > 2.0;
              n: Int64 = filtered s> COUNT _ > 3.0;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "allows ANY on a struct field" do
        expect {
          run(<<~CLEAR)
            STRUCT User { active: Bool }
            FN f() RETURNS !Void ->
              users: User[] = [];
              result = users s> ANY _.active == TRUE;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "allows ALL on a struct field" do
        expect {
          run(<<~CLEAR)
            STRUCT User { score: Float64 }
            FN f() RETURNS !Void ->
              users: User[] = [];
              result = users s> ALL _.score > 0.0;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "FIND on a struct array infers the optional struct type" do
        tree = run(<<~CLEAR)
          STRUCT User { score: Float64 }
          FN f() RETURNS !Void ->
            users: User[] = [];
            found = users s> FIND _.score > 50.0;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "found" }
        expect(bind.full_type.to_s).to eq("?User")
      end
    end
  end

  # ===========================================================================
  # Collection Types — Phase 4 (SUM, AVERAGE, MIN, MAX numeric aggregation)
  # ===========================================================================
  describe "Collection Types — Phase 4 (SUM, AVERAGE, MIN, MAX)" do
    def transpile_fn(src)
      ZigTranspiler.new.transpile(src)
    end

    # -------------------------------------------------------------------------
    # SUM — returns Float64 (0 for empty list)
    # -------------------------------------------------------------------------
    describe "SUM aggregation operator" do
      it "infers Float64 for SUM on a Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0];
            result = nums s> SUM _;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.resolved_type).to eq(:Float64)
      end

      it "infers Float64 for SUM of a struct field projection" do
        expect {
          run(<<~CLEAR)
            STRUCT Item { value: Float64 }
            FN f() RETURNS !Void ->
              items: Item[] = [];
              result = items s> SUM _.value;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "raises when SUM is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> SUM _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot SUM non-list type/)
      end

      it "raises when SUM expression is not numeric" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> SUM _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /SUM requires a numeric expression/)
      end

      it "raises when SUM expression is a String" do
        expect {
          run(<<~CLEAR)
            STRUCT Tag { name: String }
            FN f() RETURNS !Void ->
              tags: Tag[] = [];
              tags s> SUM _.name;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /SUM requires a numeric expression/)
      end

      it "emits __res accumulator and += pattern in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> SUM _;
            RETURN;
          END
        CLEAR
        expect(out).to include("__res1: f64")
        expect(out).to include("__res1 + __it2")
      end
    end

    # -------------------------------------------------------------------------
    # AVERAGE — returns Float64 (0 for empty list)
    # -------------------------------------------------------------------------
    describe "AVERAGE aggregation operator" do
      it "infers Float64 for AVERAGE on a Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0, 3.0];
            result = nums s> AVERAGE _;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.resolved_type).to eq(:Float64)
      end

      it "raises when AVERAGE is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> AVERAGE _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot AVERAGE non-list type/)
      end

      it "raises when AVERAGE expression is not numeric" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> AVERAGE _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /AVERAGE requires a numeric expression/)
      end

      it "emits sum/cnt accumulators and division in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> AVERAGE _;
            RETURN;
          END
        CLEAR
        expect(out).to include("__res1_sum")
        expect(out).to include("__res1_cnt")
        expect(out).to include("__res1_sum / __res1_cnt")
      end

      it "emits sum/cnt division for empty list in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [];
            result = nums s> AVERAGE _;
            RETURN;
          END
        CLEAR
        expect(out).to include("__res1_sum / __res1_cnt")
      end
    end

    # -------------------------------------------------------------------------
    # MIN — returns Float64 (panics on empty list)
    # -------------------------------------------------------------------------
    describe "MIN aggregation operator" do
      it "infers Float64 for MIN on a Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0, 3.0];
            result = nums s> MIN _;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.resolved_type).to eq(:Float64)
      end

      it "raises when MIN is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> MIN _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot MIN non-list type/)
      end

      it "raises when MIN expression is not numeric" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> MIN _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /MIN requires a numeric expression/)
      end

      it "raises when MIN expression is a String" do
        expect {
          run(<<~CLEAR)
            STRUCT Tag { name: String }
            FN f() RETURNS !Void ->
              tags: Tag[] = [];
              tags s> MIN _.name;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /MIN requires a numeric expression/)
      end

      it "emits found-flag pattern with less-than guard for MIN in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> MIN _;
            RETURN;
          END
        CLEAR
        expect(out).to include("__res")
        expect(out).to include("_found")
        expect(out).to include("<")
      end

      it "emits assert guard for MIN on empty list in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> MIN _;
            RETURN;
          END
        CLEAR
        expect(out).to include("_found")
        expect(out).to include("assert")
      end
    end

    # -------------------------------------------------------------------------
    # MAX — returns Float64 (panics on empty list)
    # -------------------------------------------------------------------------
    describe "MAX aggregation operator" do
      it "infers Float64 for MAX on a Float64[]" do
        tree = run(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0, 2.0, 3.0];
            result = nums s> MAX _;
            RETURN;
          END
        CLEAR
        fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
        bind = fn_node.body.find { |n| (n.is_a?(AST::BindExpr) || n.is_a?(AST::VarDecl)) && n.name == "result" }
        expect(bind.resolved_type).to eq(:Float64)
      end

      it "raises when MAX is applied to a non-array" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              x: Float64 = 1.0;
              x s> MAX _;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /Cannot MAX non-list type/)
      end

      it "raises when MAX expression is not numeric" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0];
              nums s> MAX _ > 0.0;
              RETURN;
            END
          CLEAR
        }.to raise_error(CompilerError, /MAX requires a numeric expression/)
      end

      it "emits found-flag pattern with greater-than guard for MAX in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> MAX _;
            RETURN;
          END
        CLEAR
        expect(out).to include("__res")
        expect(out).to include("_found")
        expect(out).to include(">")
      end

      it "emits assert guard for MAX on empty list in Zig" do
        out = transpile_fn(<<~CLEAR)
          FN f() RETURNS !Void ->
            nums: Float64[] = [1.0];
            result = nums s> MAX _;
            RETURN;
          END
        CLEAR
        expect(out).to include("_found")
        expect(out).to include("assert")
      end
    end

    # -------------------------------------------------------------------------
    # Cross-operator and chaining
    # -------------------------------------------------------------------------
    describe "aggregation chaining and combined usage" do
      it "allows SUM after WHERE" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0, 2.0, 3.0, 4.0];
              filtered: Float64[] = nums s> WHERE _ > 2.0;
              total = filtered s> SUM _;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "allows MIN after WHERE" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0, 2.0, 3.0];
              filtered: Float64[] = nums s> WHERE _ > 1.0;
              minimum = filtered s> MIN _;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "allows AVERAGE on a struct field" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              scores: Score[] = [];
              avg = scores s> AVERAGE _.value;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "allows MAX on a struct field" do
        expect {
          run(<<~CLEAR)
            STRUCT Score { value: Float64 }
            FN f() RETURNS !Void ->
              scores: Score[] = [];
              result = scores s> MAX _.value;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end

      it "SUM result can be used in further arithmetic" do
        expect {
          run(<<~CLEAR)
            FN f() RETURNS !Void ->
              nums: Float64[] = [1.0, 2.0];
              total = nums s> SUM _;
              doubled = total * 2.0;
              RETURN;
            END
          CLEAR
        }.not_to raise_error
      end
    end
  end

  describe "Collection Types — Phase 5: @list:sharded pipeline operators" do
    subject(:ast) { run(code) }
    let(:result) { ast.statements.last.full_type&.resolved }

    context "sharded list s> SUM _ resolves to Float64" do
      let(:code) {
        <<~FLUX
          MUTABLE slist: Float64[]@list:sharded(2) = [];
          total = slist s> SUM _;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "sharded list s> COUNT predicate resolves to Int64" do
      let(:code) {
        <<~FLUX
          MUTABLE slist: Float64[]@list:sharded(2) = [];
          n = slist s> COUNT _ > 0.0;
        FLUX
      }

      it "resolves to Int64" do
        expect(result).to eq(:Int64)
      end
    end

    context "sharded list s> ANY predicate resolves to Bool" do
      let(:code) {
        <<~FLUX
          MUTABLE slist: Float64[]@list:sharded(2) = [];
          found = slist s> ANY _ > 0.0;
        FLUX
      }

      it "resolves to Bool" do
        expect(result).to eq(:Bool)
      end
    end

    context "Zig output: sharded list pipeline flattens shards" do
      let(:code) {
        <<~FLUSH
          MUTABLE slist: Float64[]@list:sharded(3) = [];
          total = slist s> SUM _;
        FLUSH
      }

      it "emits shard flattening with appendSlice" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("appendSlice")
        expect(zig).to include("shards[__psi].items")
        expect(zig).to include("sum_result")
      end
    end

    context "sharded list s> ALL predicate resolves to Bool" do
      let(:code) {
        <<~FLUX
          MUTABLE slist: Float64[]@list:sharded(2) = [];
          result = slist s> ALL _ > 0.0;
        FLUX
      }

      it "resolves to Bool" do
        expect(result).to eq(:Bool)
      end
    end

    context "sharded list s> AVERAGE _ resolves to Float64" do
      let(:code) {
        <<~FLUX
          MUTABLE slist: Float64[]@list:sharded(2) = [];
          result = slist s> AVERAGE _;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "sharded list s> MIN _ resolves to Float64" do
      let(:code) {
        <<~FLUX
          MUTABLE slist: Float64[]@list:sharded(2) = [];
          result = slist s> MIN _;
        FLUX
      }

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "sharded list s> MAX _ resolves to Float64" do
      let(:code) {
        <<~FLUX
          MUTABLE slist: Float64[]@list:sharded(2) = [];
          result = slist s> MAX _;
        FLUX
      }

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "sharded list s> WHERE predicate resolves to element array type" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE slist: Item[]@list:sharded(2) = [];
          result = slist s> WHERE _.value > 0.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Item[]" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "sharded list s> FIND predicate resolves to optional element type" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE slist: Item[]@list:sharded(2) = [];
          result = slist s> FIND _.value > 0.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to an optional type" do
        # ?Item — the resolved raw includes Item
        expect(result.to_s).to match(/Item/)
      end
    end

    context "Zig output: @list:sharded WHERE/FIND flatten shards before iterating" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE slist: Item[]@list:sharded(2) = [];
            result = slist s> WHERE _.value > 0.0;
            RETURN;
          END
        FLUX
      }

      it "emits appendSlice to flatten shards" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("appendSlice")
        expect(zig).to include("shards[__psi].items")
      end
    end

    context "Zig output: @list:sharded EACH emits parallel fibers" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE slist: Item[]@list:sharded(2) = [];
          slist s> EACH { _.value = 0.0; };
        FLUX
      }

      it "emits parallel fiber structs for EACH shard" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("EachListShardCtx")
        expect(zig).to include("ctx.shard.items")
        expect(zig).to include("WaitGroup")
      end
    end
  end

  describe "Collection Types — Phase 5: Pool pipeline operators" do
    subject(:ast) { run(code) }
    let(:result) { ast.statements.last.full_type&.resolved }

    context "pool s> SUM _.field resolves to Float64" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          total = pool s> SUM _.value;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "pool s> WHERE _.value > 0 resolves to Item[]" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          result = pool s> WHERE _.value > 0.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Item[]" do
        expect(result).to eq(:"Item[]")
      end
    end

    context "pool s> COUNT predicate resolves to Int64" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          n = pool s> COUNT _.value > 0.0;
        FLUX
      }

      it "resolves to Int64" do
        expect(result).to eq(:Int64)
      end
    end

    context "pool s> ANY predicate resolves to Bool" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          found = pool s> ANY _.value > 0.0;
        FLUX
      }

      it "resolves to Bool" do
        expect(result).to eq(:Bool)
      end
    end

    context "pool s> ALL predicate resolves to Bool" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          all_pos = pool s> ALL _.value > 0.0;
        FLUX
      }

      it "resolves to Bool" do
        expect(result).to eq(:Bool)
      end
    end

    context "pool s> MIN _.field resolves to Float64" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          mn = pool s> MIN _.value;
        FLUX
      }

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "pool s> MAX _.field resolves to Float64" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          mx = pool s> MAX _.value;
        FLUX
      }

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "pool s> AVERAGE _.field resolves to Float64" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          avg = pool s> AVERAGE _.value;
        FLUX
      }

      it "resolves to Float64" do
        expect(result).to eq(:Float64)
      end
    end

    context "Zig output: pool pipeline materializes live slots" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          total = pool s> SUM _.value;
        FLUX
      }

      it "emits slot materialization loop" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("pipe_src_list.slots)")
        expect(zig).to include("__pslot.alive")
        expect(zig).to include("pipe_mat.append")
        expect(zig).to include("sum_result")
      end
    end
  end

  describe "Collection Types — Phase 5: Pool FIND operator" do
    subject(:ast) { run(code) }
    let(:result) { ast.statements.last.full_type&.resolved }

    context "pool s> FIND predicate resolves to optional element type" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          found = pool s> FIND _.value == 10.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to ?Item (optional Item)" do
        expect(result.to_s).to match(/\?Item|Item/)
      end
    end

    context "pool s> FIND on empty pool resolves without error" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          MUTABLE pool: Item[100]@pool = [];
          found = pool s> FIND _.value == 99.0;
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end
    end

    context "Zig output: pool s> FIND emits slot materialization and find loop" do
      let(:code) {
        <<~FLUX
          STRUCT Item { value: Float64 }
          FN f() RETURNS !Void ->
            MUTABLE pool: Item[100]@pool = [];
            found = pool s> FIND _.value == 10.0;
            RETURN;
          END
        FLUX
      }

      it "emits alive-slot materialization before the find loop" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("__pslot.alive")
        expect(zig).to include("pipe_mat.append")
      end

      it "emits find_found flag and optional return" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("find_found")
        expect(zig).to include("find_result")
      end
    end
  end

end
