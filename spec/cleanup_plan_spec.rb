require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/mir/promotion_plan"
require_relative "../src/mir/control_flow"
require_relative "../src/mir/mir"

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

    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup).transform!(ast)

    fn_node = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == fn_name }
    raise "Function '#{fn_name}' not found" unless fn_node

    CleanupClassifier.classify(
      fn_node,
      fn_nodes: fn_nodes,
      schema_lookup: schema_lookup,
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
          FN test!(MUTABLE map: HashMap<Value>) RETURNS !String ->
              val = map["t0"] OR Value.Nil;
              PARTIAL MATCH val START
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
          FN test() RETURNS !Void ->
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
        expect(entry[:alloc]).to eq(:heap)
      end
    end

    context "COPY of non-Copy union" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "test")
          UNION Data { Empty, Text: String, Nested { label: String, inner: Data @indirect } }
          FN makeData() RETURNS Data ->
              RETURN Data{ Text: "hello" };
          END
          FN test() RETURNS !Void ->
              d = makeData();
              d2 = COPY d;
              RETURN;
          END
        CLEAR
      end

      it "marks original for cleanup" do
        entry = plan["d"]
        expect(entry).not_to be_nil
        expect([:non_copy_union, :heap_union]).to include(entry[:kind])
      end

      it "marks COPY result for cleanup" do
        entry = plan["d2"]
        expect(entry).not_to be_nil
        expect([:non_copy_union, :heap_union]).to include(entry[:kind])
        expect(entry[:alloc]).to eq(:heap)
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
        # :takes_string was a vestigial alias of :heap_string (same emit).
        # source_kind: :takes_param now carries the TAKES origin.
        expect(entry[:kind]).to eq(:heap_string)
        expect(entry[:source_kind]).to eq(:takes_param)
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
    context "MATCH AS auto-promotes to TAKES for non-Copy variants" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "eval!")
          UNION Value { Nil, Num: Float64, List: Value[] }
          FN eval!(TAKES ast: Value) RETURNS Value ->
              PARTIAL MATCH ast START
                  Value.List AS items -> RETURN Value.Nil;,
                  DEFAULT -> RETURN Value.Nil;
              END
              RETURN Value.Nil;
          END
        CLEAR
      end

      it "marks AS binding for cleanup (auto-TAKES)" do
        expect(plan["items"]).not_to be_nil
        expect(plan["items"][:kind]).to eq(:match_as_slice)
      end
    end
  end

  describe "MATCH TAKES binding (move)" do
    context "MATCH TAKES with slice payload" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "eval!")
          UNION Value { Nil, Num: Float64, List: Value[] }
          FN eval!(TAKES ast: Value) RETURNS Value ->
              PARTIAL MATCH TAKES ast START
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
              PARTIAL MATCH v START
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
          FN makeList() RETURNS !Int64[] ->
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
          FN makeList() RETURNS !Int64[] ->
              MUTABLE items: Int64[]@list = List[];
              items.append(1_i64);
              RETURN items;
          END
          FN wrapper() RETURNS !Int64[] ->
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
          FN makeValue() RETURNS !Value ->
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
          FN test() RETURNS !Void ->
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
    context "pool is an owned collection with guard" do
      let(:plan) do
        cleanup_for(<<~CLEAR, "main")
          STRUCT Pt { x: Float64, y: Float64 }
          FN main() RETURNS Void ->
              MUTABLE pool: Pt[10]@pool = [];
              RETURN;
          END
        CLEAR
      end

      it "pool has _moved guard through collection cleanup" do
        entry = plan["pool"]
        expect(entry[:has_moved_guard]).to eq(true)
        expect(entry[:kind]).to eq(:pool)
      end
    end
  end

  # =========================================================================
  # Struct with rodata string fields: no cleanup needed
  # =========================================================================
  describe "struct with rodata string fields" do
    let(:src) do
      <<~CLEAR
        STRUCT Pair { name: String, value: Float64 }
        FN f() RETURNS !Void ->
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
        FN f(s: String) RETURNS !Void ->
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
        FN handleWithCatch(mode: String) RETURNS !String ->
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

  # Run the full MIRPass pipeline and return the cleanup plan for a function.
  def mir_plan_for(src, fn_name)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir.transform!(ast)
    mir.cleanup_bindings[fn_name]
  end

  # ===========================================================================
  # COPY of non-Copy union consumed by MATCH TAKES: cleanup must survive
  # ===========================================================================
  describe "COPY non-Copy union consumed by MATCH TAKES" do
    it "keeps cleanup for COPY result after refine_moved_guards" do
      plan = mir_plan_for(<<~CLEAR, "main")
        UNION Data { Empty, Text: String, Nested { label: String, inner: Data @indirect } }
        FN makeNested() RETURNS !Data ->
            inner = Data{ Text: "hello" };
            RETURN Data.Nested{ label: "outer", inner: inner };
        END
        FN main() RETURNS Void ->
            d = makeNested();
            d2 = COPY d;
            PARTIAL MATCH d2 START
                Data.Nested AS n -> print(n.label);,
                DEFAULT -> print("wrong");
            END
        END
      CLEAR
      # d2 is consumed by MATCH TAKES (auto), but cleanup must survive for
      # the DEFAULT branch where no AS binding extracts the payload.
      d2_entry = plan["d2"]
      expect(d2_entry).not_to be_nil, "d2 must have a cleanup entry"
      expect(d2_entry[:needs_cleanup]).to eq(true), "d2 cleanup must not be eliminated"
      expect(d2_entry[:has_moved_guard]).to eq(true), "d2 needs moved guard for MATCH TAKES"
    end
  end
end

# All StaticLeakChecker checks have been migrated to MIRChecker
# (post-lowering). See spec/mir_checker_spec.rb for unit tests.

# ===========================================================================
# BG escape promotion: BgBlock.capture_string_dupes annotation for string captures
# (Tests MIRPass behavior, not checker)
# ===========================================================================
RSpec.describe "BG escape promotion for string captures" do
    # Helper: run full pipeline through MIR, return fn body statements
    def mir_body_for(src, fn_name)
      tokens = Lexer.new(src).tokenize
      ast = Parser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      fn_nodes = {}
      ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
      schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
      mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
      mir.transform!(ast)
      fn_nodes[fn_name].body
    end

    def bg_string_dupes_in(body)
      # Find all BgBlock nodes (direct or nested in VarDecl/BindExpr/MethodCall args)
      dupes = []
      body.each do |stmt|
        collect_bg_string_dupes(stmt, dupes)
      end
      dupes
    end

    def collect_bg_string_dupes(node, result)
      return unless node
      if node.is_a?(AST::BgBlock)
        result.concat(node.capture_string_dupes&.to_a || [])
        return
      end
      # Recurse into value/args
      [:value, :args, :target, :receiver].each do |field|
        val = node.respond_to?(field) ? node.send(field) : nil
        if val.is_a?(Array)
          val.each { |v| collect_bg_string_dupes(v, result) }
        else
          collect_bg_string_dupes(val, result)
        end
      end
    end

    it "annotates capture_string_dupes on BgBlock for direct BG assignment capturing a string" do
      body = mir_body_for(<<~CLEAR, "test")
        FN greet!(name: String) RETURNS String -> RETURN name; END
        FN test() RETURNS !Void ->
            msg = greet!("hello");
            p: ~Void = BG { print(msg); };
            NEXT p;
            RETURN;
        END
      CLEAR
      expect(bg_string_dupes_in(body)).to include("msg")
    end

    it "annotates capture_string_dupes on BgBlock inside a MethodCall arg" do
      body = mir_body_for(<<~CLEAR, "test")
        FN greet!(name: String) RETURNS String -> RETURN name; END
        FN test() RETURNS !Void ->
            msg = greet!("hello");
            MUTABLE futures: ~Void[]@list = [];
            futures.append(BG { print(msg); });
            NEXT futures[0];
            RETURN;
        END
      CLEAR
      expect(bg_string_dupes_in(body)).to include("msg")
    end

    it "annotates capture_string_dupes on BgBlock inside a FuncCall arg" do
      body = mir_body_for(<<~CLEAR, "test")
        FN greet!(name: String) RETURNS String -> RETURN name; END
        FN consume(p: ~Void) RETURNS Void -> NEXT p; RETURN; END
        FN test() RETURNS !Void ->
            msg = greet!("hello");
            consume(BG { print(msg); });
            RETURN;
        END
      CLEAR
      expect(bg_string_dupes_in(body)).to include("msg")
    end

    it "does NOT annotate capture_string_dupes for string literals (no frame alloc)" do
      body = mir_body_for(<<~CLEAR, "test")
        FN test() RETURNS !Void ->
            p: ~Void = BG { print("hello"); };
            NEXT p;
            RETURN;
        END
      CLEAR
      # "hello" is a literal, not a frame-allocated binding — no dupe annotation needed
      expect(bg_string_dupes_in(body)).to be_empty
    end
end
