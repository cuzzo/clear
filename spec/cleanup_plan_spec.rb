require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/promotion_plan"
require_relative "../src/control_flow"

# Tests CleanupClassifier - classifies which bindings need cleanup.
# MIRPass consumes this to insert MIR::Drop nodes and stamp AST.
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

RSpec.describe CleanupClassifier do
  def cleanup_for(src, fn_name)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }

    CleanupClassifier.classify(
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
        expect(plan["val"]).to be_nil
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
        entry = plan["val"]
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
        entry = plan["v"]
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        expect(entry[:has_moved_guard]).to eq(true)
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
        expect(plan["v"]).to be_nil
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
        entry = plan["s"]
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
        entry = plan["items"]
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
        expect(plan["items"]).to be_nil
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
        entry = plan["items"]
        expect(entry).not_to be_nil
        expect(entry[:needs_cleanup]).to eq(true)
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:kind]).to eq(:match_as_slice)
      end

      it "uses heap allocator (slice contents may be heap-allocated via COPY/promote)" do
        entry = plan["items"]
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
        expect(plan["n"]).to be_nil
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
        entry = plan["vals"]
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
        entry = plan["m"]
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
        entry = plan["list1"]
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
        entry = plan["result"]
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
        entry = plan["v"]
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
        entry = plan["v"]
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
        expect(plan["x"]).to be_nil
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
        expect(plan["s"]).to be_nil
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
        expect(plan["r"]).to be_nil
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
        entry = plan["pool"]
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:kind]).to eq(:resource)
      end
    end
  end

  # =========================================================================
  # HPT classification (tested through heap_temps entries)
  # =========================================================================
  describe "HPT hoisting via MIRPass" do
    it "hoists heap string sub-expression into VarDecl" do
      plan, _, fn = hpt_for(<<~CLEAR, "main")
        FN makeStr!() RETURNS String -> RETURN COPY "hi"; END
        FN consume(s: String) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
            consume(makeStr!());
            RETURN;
        END
      CLEAR
      expect(count_hoisted_hpts(fn)).to eq(1)
      hpt_var = fn.body.find { |s| s.is_a?(AST::VarDecl) && s.hpt_hoisted }
      entry = plan[hpt_var.name]
      expect(entry[:kind]).to eq(:heap_string)
    end

    it "does not hoist primitive return" do
      _, _, fn = hpt_for(<<~CLEAR, "main")
        FN getNum() RETURNS Int64 -> RETURN 42_i64; END
        FN consume(n: Int64) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
            consume(getNum());
            RETURN;
        END
      CLEAR
      expect(count_hoisted_hpts(fn)).to eq(0)
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
      entry = plan["p"]
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
      entry = plan["p"]
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
      entry = plan["r"]
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
      entry = plan["items"]
      expect(entry).not_to be_nil, "struct array literal with string fields should have cleanup"
      expect(entry[:kind]).to eq(:array_with_struct_strings)
    end
  end

  # ── COPY union as non-TAKES call arg needs caller cleanup ──────
  describe "COPY union as non-TAKES call argument" do
    it "COPY union passed to non-TAKES callee is a compile error or requires TAKES" do
      # When a non-Copy union is passed to a non-TAKES function, the caller
      # retains ownership but has no cleanup path for the COPY data.
      # The architecturally correct fix: the callee should declare TAKES
      # when it may consume the input. This test documents that TAKES
      # is required for correct COPY-union ownership transfer.
      src = <<~CLEAR
        UNION Value { Nil, Error { msg: String } }
        FN consume(TAKES v: Value) RETURNS Value -> RETURN Value.Nil; END
        FN main() RETURNS Void ->
            err = Value.Error{ msg: "x" };
            result = consume(COPY err);
            RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = Parser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      # With TAKES, the callee owns the COPY and handles cleanup.
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "consume" }
      expect(fn.params.first[:takes]).to be_truthy
    end

    it "TAKES callee does NOT mark COPY arg for caller cleanup" do
      src = <<~CLEAR
        UNION Value { Nil, Error { msg: String } }
        FN consume(TAKES v: Value) RETURNS Value -> RETURN Value.Nil; END
        FN main() RETURNS Void ->
            err = Value.Error{ msg: "x" };
            result = consume(COPY err);
            RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = Parser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
      call = nil
      fn.body.each do |stmt|
        next unless stmt.is_a?(AST::BindExpr) && stmt.name == "result"
        call = stmt.value
      end
      copy_arg = call.args.first
      expect(copy_arg).to be_a(AST::CopyNode)
      # TAKES: callee owns the COPY. No @needs_caller_cleanup.
      expect(copy_arg.instance_variable_get(:@needs_caller_cleanup)).to be_nil,
        "TAKES callee: COPY arg should NOT be marked @needs_caller_cleanup"
    end
  end

  # ── HPT hoisting: MIRPass hoists sub-expression calls into VarDecls ──

  def hpt_for(src, fn_name)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir.transform!(ast)
    fn_node = fn_nodes[fn_name]
    plan = mir.cleanup_bindings[fn_name]
    [plan, ast, fn_node]
  end

  # Count hoisted VarDecls (__hpt_N) in a function body.
  def count_hoisted_hpts(fn_node)
    fn_node.body.count { |s| s.is_a?(AST::VarDecl) && s.hpt_hoisted }
  end

  describe "HPT hoisting: MIRPass hoists sub-expression calls into VarDecls" do
    context "sub-expression call gets hoisted" do
      it "hoists heap FuncCall inside another call's args" do
        _, _, fn = hpt_for(<<~CLEAR, "main")
          UNION Value { Nil, Str: String }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN wrap(v: Value) RETURNS Value -> RETURN v; END
          FN main() RETURNS Void ->
              result = wrap(makeVal!());
              RETURN;
          END
        CLEAR
        expect(count_hoisted_hpts(fn)).to be >= 1, "sub-expression makeVal!() should be hoisted"
      end
    end

    context "direct bind call does NOT get hoisted" do
      it "skips FuncCall that is the direct RHS of a binding" do
        _, _, fn = hpt_for(<<~CLEAR, "main")
          UNION Value { Nil, Str: String }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN main() RETURNS Void ->
              v = makeVal!();
              RETURN;
          END
        CLEAR
        expect(count_hoisted_hpts(fn)).to eq(0), "direct bind call should NOT be hoisted"
      end
    end

    context "direct return skips hoisting (ownership transfers to caller)" do
      it "does NOT hoist direct return" do
        _, _, fn = hpt_for(<<~CLEAR, "wrapper")
          UNION Value { Nil, Str: String }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN wrapper() RETURNS Value -> RETURN makeVal!(); END
          FN main() RETURNS Void -> v = wrapper(); RETURN; END
        CLEAR
        expect(count_hoisted_hpts(fn)).to eq(0), "direct return should not be hoisted"
      end
    end

    context "nested sub-expression" do
      it "hoists heap call nested in another call" do
        _, _, fn = hpt_for(<<~CLEAR, "main")
          UNION Value { Nil, Str: String }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN wrap(v: Value) RETURNS Value -> RETURN v; END
          FN outer(v: Value) RETURNS Value -> RETURN v; END
          FN main() RETURNS Void ->
              result = outer(wrap(makeVal!()));
              RETURN;
          END
        CLEAR
        expect(count_hoisted_hpts(fn)).to be >= 1, "nested makeVal!() should be hoisted"
      end
    end

    context "struct literal as bind target" do
      it "does NOT hoist direct field that is a heap FuncCall" do
        _, _, fn = hpt_for(<<~CLEAR, "main")
          UNION Value { Nil, Str: String }
          STRUCT Wrapper { val: Value }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN main() RETURNS Void ->
              w = Wrapper{ val: makeVal!() };
              RETURN;
          END
        CLEAR
        expect(count_hoisted_hpts(fn)).to eq(0),
          "direct struct field makeVal!() should NOT be hoisted — struct owns the value"
      end

      it "still hoists heap call nested in a function arg within a struct field" do
        _, _, fn = hpt_for(<<~CLEAR, "main")
          UNION Value { Nil, Str: String }
          STRUCT Wrapper { val: Value }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN wrap(v: Value) RETURNS Value -> RETURN v; END
          FN main() RETURNS Void ->
              w = Wrapper{ val: wrap(makeVal!()) };
              RETURN;
          END
        CLEAR
        expect(count_hoisted_hpts(fn)).to be >= 1,
          "makeVal!() as arg to wrap() inside a struct field should still be hoisted"
      end
    end

    context "list literal as bind target" do
      it "does NOT hoist direct list item that is a heap FuncCall" do
        _, _, fn = hpt_for(<<~CLEAR, "main")
          UNION Value { Nil, Str: String }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN main() RETURNS Void ->
              items: Value[] = [makeVal!()];
              RETURN;
          END
        CLEAR
        expect(count_hoisted_hpts(fn)).to eq(0),
          "direct list item makeVal!() should NOT be hoisted — list owns the value"
      end
    end

    context "heap arg to non-TAKES callee in return expression" do
      it "hoists heap arg passed to the direct-return function" do
        _, _, fn = hpt_for(<<~CLEAR, "caller")
          UNION Value { Nil, Str: String }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN prStr(v: Value) RETURNS String -> RETURN "result"; END
          FN caller() RETURNS String -> RETURN prStr(makeVal!()); END
        CLEAR
        expect(count_hoisted_hpts(fn)).to be >= 1,
          "makeVal!() is non-TAKES arg to prStr — needs HPT hoisting"
      end

      it "does NOT hoist the direct-return FuncCall itself" do
        plan, _, fn = hpt_for(<<~CLEAR, "caller")
          UNION Value { Nil, Str: String }
          FN makeVal!() RETURNS Value -> RETURN Value{ Str: COPY "hi" }; END
          FN prStr(v: Value) RETURNS String -> RETURN "result"; END
          FN caller() RETURNS String -> RETURN prStr(makeVal!()); END
        CLEAR
        # Only makeVal!() should be hoisted, not prStr()
        hoisted = fn.body.select { |s| s.is_a?(AST::VarDecl) && s.hpt_hoisted }
        hoisted_values = hoisted.map { |v| v.value }
        expect(hoisted_values.none? { |v| v.is_a?(AST::FuncCall) && v.name == "prStr" }).to be(true),
          "prStr() is the direct return — should NOT be hoisted"
      end
    end
  end
end
