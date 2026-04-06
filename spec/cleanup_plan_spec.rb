require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/promotion_plan"

# Tests CleanupPlan - THE SINGLE AUTHORITY for all cleanup decisions.
# Every defer/cleanup emission in the transpiler consults this plan.
#
# Categories tested:
# 1. Container borrows (HashMap/List indexing) -> no cleanup
# 2. TAKES parameters -> cleanup with _moved guard
# 3. MATCH AS bindings -> cleanup with _moved guard (double-free fix)
# 4. has_moved_guard correctness for all types
# 5. Collections, RC, sync, resources
# 6. Heap-promoted bindings
# 7. Structs with RC/string fields
# 8. Non-Copy unions on stack
# 9. Negative tests (primitives, Copy unions, strings)

RSpec.describe CleanupPlan do
  def cleanup_for(src, fn_name)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }

    CleanupPlan.compute(
      fn_node,
      fn_nodes: fn_nodes,
      schema_lookup: ->(name) { annotator.lookup_type_schema(name) },
    )
  end

  # =========================================================================
  # Container borrows: data owned by container, no cleanup
  # =========================================================================
  describe "container borrow" do
    context "HashMap get with OR default" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test!")
          UNION Value { Nil, Str: String }
          FN test!(MUTABLE map: HashMap<Value>) RETURNS String ->
              val = map["t0"] OR Value.Nil;
              MATCH val START
                  Value.Str AS s -> RETURN s;,
                  DEFAULT -> RETURN "";
              END
              RETURN "";
          END
        CLEAR
      end

      it "does NOT mark val for cleanup (container owns the data)" do
        expect(plan.lookup("val")).to be_nil
      end
    end

    context "function call returning non-Copy union (not container)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Value { Nil, Str: String }
          FN makeVal() RETURNS Value ->
              RETURN Value.Nil;
          END
          FN test() RETURNS Void ->
              val = makeVal();
              RETURN;
          END
        CLEAR
      end

      it "marks val for cleanup (non-Copy union)" do
        entry = plan.lookup("val")
        expect(entry).not_to be_nil
        # Provenance-based: :heap_union (heap cleanup_alloc for unions with heap variants)
        expect([:non_copy_union, :heap_union]).to include(entry[:kind])
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end
  end

  # =========================================================================
  # TAKES parameters
  # =========================================================================
  describe "TAKES parameters" do
    context "TAKES union parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "consume!")
          UNION Value { Nil, Str: String }
          FN consume!(TAKES v: Value) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "marks TAKES union param for cleanup" do
        entry = plan.lookup("v")
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:source_kind]).to eq(:takes_param)
        expect(entry[:kind]).to eq(:takes_union)
      end
    end

    context "non-TAKES parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "borrow")
          UNION Value { Nil, Str: String }
          FN borrow(v: Value) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "does NOT mark borrowed param for cleanup" do
        expect(plan.lookup("v")).to be_nil
      end
    end

    context "TAKES string parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "consume!")
          FN consume!(TAKES s: String) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "marks TAKES string param for cleanup" do
        entry = plan.lookup("s")
        expect(entry).not_to be_nil
        expect(entry[:kind]).to eq(:takes_string)
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end

    context "TAKES slice parameter" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "process!")
          UNION Value { Nil, Num: Float64 }
          FN process!(TAKES items: Value[]) RETURNS Void ->
              RETURN;
          END
        CLEAR
      end

      it "marks TAKES slice param for cleanup with heap alloc (callee owns buffer)" do
        entry = plan.lookup("items")
        expect(entry).not_to be_nil
        expect(entry[:kind]).to eq(:takes_slice)
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:source_kind]).to eq(:takes_param)
      end
    end
  end

  # =========================================================================
  # MATCH AS bindings (the double-free bug fix)
  # =========================================================================
  describe "MATCH AS binding (borrow)" do
    context "MATCH AS without TAKES is a borrow - no cleanup" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "eval!")
          UNION Value { Nil, Num: Float64, List: Value[] }
          FN eval!(TAKES ast: Value) RETURNS Value ->
              MATCH ast START
                  Value.List AS items -> RETURN Value.Nil;,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      end

      it "does NOT mark AS binding for cleanup (borrow)" do
        expect(plan.lookup("items")).to be_nil
      end
    end
  end

  describe "MATCH TAKES binding (move)" do
    context "MATCH TAKES with slice payload" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "eval!")
          UNION Value { Nil, Num: Float64, List: Value[] }
          FN eval!(TAKES ast: Value) RETURNS Value ->
              MATCH TAKES ast START
                  Value.List AS items -> RETURN Value.Nil;,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      end

      it "marks AS binding for cleanup with _moved guard" do
        entry = plan.lookup("items")
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:source_kind]).to eq(:match_as)
        expect(entry[:kind]).to eq(:match_as_slice)
      end

      it "uses heap allocator (slice contents may be heap-allocated via COPY/promote)" do
        entry = plan.lookup("items")
        expect(entry[:alloc]).to eq(:heap)
      end
    end

    context "Copy payload (Float64)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test!")
          UNION Value { Nil, Num: Float64 }
          FN test!(TAKES v: Value) RETURNS Void ->
              MATCH v START
                  Value.Num AS n -> RETURN;,
                  DEFAULT -> RETURN;
              END
              RETURN;
          END
        CLEAR
      end

      it "does NOT mark Copy payload for cleanup" do
        expect(plan.lookup("n")).to be_nil
      end
    end
  end

  # =========================================================================
  # Collections
  # =========================================================================
  describe "collections" do
    context "local @list" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN main() RETURNS Void ->
              MUTABLE vals: Int64[]@list = List[];
              vals.append(1_i64);
              RETURN;
          END
        CLEAR
      end

      it "marks for frame cleanup with _moved guard" do
        entry = plan.lookup("vals")
        expect(entry[:alloc]).to eq(:frame)
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end

    context "local HashMap" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN main() RETURNS Void ->
              MUTABLE m: HashMap<Int64> = {};
              m["x"] = 1_i64;
              RETURN;
          END
        CLEAR
      end

      it "marks for heap cleanup with _moved guard" do
        entry = plan.lookup("m")
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:kind]).to eq(:string_map)
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end
  end

  # =========================================================================
  # Heap-promoted bindings
  # =========================================================================
  describe "heap-promoted" do
    context "direct binding of promoted list return" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN makeList() RETURNS Int64[] ->
              MUTABLE items: Int64[]@list = List[];
              items.append(1_i64);
              RETURN items;
          END
          FN main() RETURNS Void ->
              list1 = makeList();
              ASSERT list1.length() == 1;
              RETURN;
          END
        CLEAR
      end

      it "marks for heap cleanup" do
        entry = plan.lookup("list1")
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end

    context "chained promoted return" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          FN makeList() RETURNS Int64[] ->
              MUTABLE items: Int64[]@list = List[];
              items.append(1_i64);
              RETURN items;
          END
          FN wrapper() RETURNS Int64[] ->
              RETURN makeList();
          END
          FN main() RETURNS Void ->
              result = wrapper();
              RETURN;
          END
        CLEAR
      end

      it "marks for heap cleanup (transitively promoted)" do
        entry = plan.lookup("result")
        expect(entry[:alloc]).to eq(:heap)
      end
    end

    context "union binding from promoted function" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          UNION Value { Num: Float64, Items: Int64[] }
          FN makeValue() RETURNS Value ->
              MUTABLE items: Int64[]@list = List[];
              items.append(1_i64);
              RETURN Value{ Items: items };
          END
          FN main() RETURNS Void ->
              v = makeValue();
              RETURN;
          END
        CLEAR
      end

      it "marks for heap cleanup (union returned from promoted function)" do
        entry = plan.lookup("v")
        expect(entry[:alloc]).to eq(:heap)
        expect(entry[:kind]).to eq(:heap_union)
      end
    end
  end

  # =========================================================================
  # Non-Copy unions on stack
  # =========================================================================
  describe "non-Copy union on stack" do
    context "union with String variant" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Value { Nil, Str: String }
          FN test() RETURNS Void ->
              v = Value{ Str: COPY "hello" };
              RETURN;
          END
        CLEAR
      end

      it "marks for cleanup with _moved guard" do
        entry = plan.lookup("v")
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        # Provenance-based: :heap_union (COPY produces :heap provenance)
        expect([:non_copy_union, :heap_union]).to include(entry[:kind])
        expect(entry[:has_moved_guard]).to eq(true)
      end
    end
  end

  # =========================================================================
  # Resources
  # =========================================================================
  # Resource test skipped: File.open requires a real filesystem path and
  # the test harness doesn't mock it. Resource cleanup is covered by the
  # transpile-tests (60_file_resource.cht, 63_resource_return.cht).

  # =========================================================================
  # Negative tests: no cleanup needed
  # =========================================================================
  describe "no cleanup needed" do
    context "primitive binding" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          FN test() RETURNS Void ->
              x = 42_i64;
              RETURN;
          END
        CLEAR
      end

      it "has no entries" do
        expect(plan.lookup("x")).to be_nil
      end
    end

    context "string binding (frame-arena managed)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          FN test() RETURNS Void ->
              s = "hello";
              RETURN;
          END
        CLEAR
      end

      it "has no entries" do
        expect(plan.lookup("s")).to be_nil
      end
    end

    context "Copy union (all primitive variants)" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Result { Ok: Float64, Err: Float64 }
          FN test() RETURNS Void ->
              r = Result{ Ok: 42.0 };
              RETURN;
          END
        CLEAR
      end

      it "has no entries (all variants are Copy)" do
        expect(plan.lookup("r")).to be_nil
      end
    end
  end

  # =========================================================================
  # has_moved_guard tests
  # =========================================================================
  describe "has_moved_guard" do
    context "pool is a resource with guard" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          STRUCT Pt { x: Float64, y: Float64 }
          FN main() RETURNS Void ->
              MUTABLE pool: Pt[10]@pool = [];
              RETURN;
          END
        CLEAR
      end

      it "pool has _moved guard (resource-like cleanup)" do
        entry = plan.lookup("pool")
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:kind]).to eq(:resource)
      end
    end
  end

  # =========================================================================
  # classify_heap_temp class method
  # =========================================================================
  describe ".classify_heap_temp" do
    it "classifies string" do
      entry = CleanupPlan.classify_heap_temp(Type.new(:String), ->(_) { nil })
      expect(entry[:kind]).to eq(:heap_string)
      expect(entry[:alloc]).to eq(:heap)
    end

    it "classifies slice" do
      ti = Type.new(:"Int64[]")
      entry = CleanupPlan.classify_heap_temp(ti, ->(_) { nil })
      expect(entry[:kind]).to eq(:heap_slice)
    end

    it "returns nil for primitive" do
      entry = CleanupPlan.classify_heap_temp(Type.new(:Int64), ->(_) { nil })
      expect(entry).to be_nil
    end
  end

  # =========================================================================
  # Struct with rodata string fields: no cleanup needed
  # =========================================================================
  describe "struct with rodata string fields" do
    let(:src) do
      <<~CLEAR
        STRUCT Pair { name: String, value: Float64 }
        FN f() RETURNS Void ->
            s = "hello";
            p = Pair{ name: s, value: 1.0 };
            RETURN;
        END
      CLEAR
    end
    let(:plan) { cleanup_for(src, "f") }

    it "classifies struct as needing cleanup (rodata strings auto-duped to heap)" do
      entry = plan.lookup("p")
      expect(entry).not_to be_nil
      # Provenance-based: :heap_struct (CopyNode field gives :heap provenance)
      expect([:struct_with_cleanup_fields, :heap_struct]).to include(entry[:kind])
    end
  end

  describe "struct with heap string fields" do
    let(:src) do
      <<~CLEAR
        STRUCT Pair { name: String, value: Float64 }
        FN f(s: String) RETURNS Void ->
            p = Pair{ name: COPY s, value: 1.0 };
            RETURN;
        END
      CLEAR
    end
    let(:plan) { cleanup_for(src, "f") }

    it "classifies struct as needing cleanup when string field is COPY" do
      entry = plan.lookup("p")
      expect(entry).not_to be_nil
      # Provenance-based: :heap_struct (COPY field gives :heap provenance)
      expect([:struct_with_cleanup_fields, :heap_struct]).to include(entry[:kind])
    end
  end

  # ── CATCH string return: caller must cleanup heap-duped result ──────
  describe "CATCH function returning String" do
    it "gives caller a heap_string cleanup for the result" do
      plan = cleanup_for(<<~CLEAR, "main")
        FN riskyOp(mode: String) RETURNS !String ->
            RETURN "ok:" + mode;
        END
        FN handleWithCatch(mode: String) RETURNS String ->
            result = riskyOp(mode) OR RAISE;
            RETURN result;
        CATCH Transient
            RETURN "recovered";
        END
        FN main() RETURNS Void ->
            r = handleWithCatch("ok");
            RETURN;
        END
      CLEAR
      entry = plan.lookup("r")
      expect(entry).not_to be_nil, "CATCH string return should have cleanup"
      expect(entry[:kind]).to eq(:heap_string)
    end
  end

  # ── Inline struct arg: no CopyNode wrapping for rodata strings ──────
  describe "struct literal as function argument" do
    it "does NOT get CopyNode wrapping on rodata string fields" do
      src = <<~CLEAR
        STRUCT User { name: String, age: Int64 }
        FN process(u: User) RETURNS Int64 -> RETURN u.age; END
        FN main() RETURNS Void ->
            x = process(User{ name: "Alice", age: 30_i64 });
            RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = Parser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      # Find the FuncCall to process
      call = nil
      fn.body.each do |stmt|
        next unless stmt.is_a?(AST::BindExpr)
        call = stmt.value if stmt.value.is_a?(AST::FuncCall) && stmt.value.name == "process"
      end
      expect(call).not_to be_nil
      struct_arg = call.args.first
      expect(struct_arg).to be_a(AST::StructLit)
      # The name field should NOT be a CopyNode (rodata is valid for call lifetime)
      name_val = struct_arg.fields["name"]
      expect(name_val).not_to be_a(AST::CopyNode), "rodata string in call-arg struct should not be CopyNode-wrapped"
    end
  end

  # ── Array literal of structs with string fields ────────────────────
  describe "array literal of structs with string fields" do
    it "gets :array_with_struct_strings cleanup" do
      plan = cleanup_for(<<~CLEAR, "main")
        STRUCT Item { name: String, value: Int64 }
        FN main() RETURNS Void ->
            items = [Item{ name: "a", value: 1_i64 }];
            RETURN;
        END
      CLEAR
      entry = plan.lookup("items")
      expect(entry).not_to be_nil, "struct array literal with string fields should have cleanup"
      expect(entry[:kind]).to eq(:array_with_struct_strings)
    end
  end
end
