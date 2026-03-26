require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/transpiler"
require_relative "../src/ast"

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

  # ---------------------------------------------------------------------------
  # DO block (fork-join parallelism)
  # ---------------------------------------------------------------------------

  describe "DO block (fork-join parallelism)" do
    context "simple expression branches" do
      let(:code) {
        <<~FLUX
          STRUCT Task { id: Number }
          FN process(t: Task) RETURNS Void -> RETURN; END
          a = Task{ id: 1 };
          b = Task{ id: 2 };
          DO {
            process(a),
            process(b)
          }
        FLUX
      }

      it "annotates as Void" do
        expect(result).to eq(:Void)
      end

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end
    end

    context "block branches with @locked shared state" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
          DO {
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
          }
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end

      it "annotates as Void" do
        expect(result).to eq(:Void)
      end
    end

    context "block branches with @writeLocked shared state" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @writeLocked;
          DO {
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH c AS inner_r { }
          }
        FLUX
      }

      it "succeeds (one write branch, one read branch)" do
        expect { ast }.not_to raise_error
      end
    end

    context "single branch DO block" do
      let(:code) {
        <<~FLUX
          FN work() RETURNS Void -> RETURN; END
          DO {
            work()
          }
        FLUX
      }

      it "succeeds and resolves to Void" do
        expect { ast }.not_to raise_error
        expect(result).to eq(:Void)
      end
    end

    context "type error inside a DO branch" do
      let(:code) {
        <<~FLUX
          FN add(a: Number, b: Number) RETURNS Number -> RETURN a + b; END
          x = "not-a-number";
          DO {
            add(x, 1)
          }
        FLUX
      }

      it "propagates the type error from inside the branch" do
        expect { ast }.to raise_error(/Type Error/i)
      end
    end
  end

  describe "DO block — Phase 5: @pinned branch syntax" do
    subject(:ast) { run(code) }
    let(:result) { ast.statements.last.full_type&.resolved }

    context "@pinned branch in single-branch DO block" do
      let(:code) {
        <<~FLUX
          FN work() RETURNS Void -> RETURN; END
          DO { @pinned -> work() }
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Void" do
        expect(result).to eq(:Void)
      end
    end

    context "mixed pinned and unpinned branches" do
      let(:code) {
        <<~FLUX
          FN alpha() RETURNS Void -> RETURN; END
          FN beta()  RETURNS Void -> RETURN; END
          DO {
            alpha(),
            @pinned -> beta()
          }
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end

      it "resolves to Void" do
        expect(result).to eq(:Void)
      end
    end

    context "all pinned branches" do
      let(:code) {
        <<~FLUX
          FN a() RETURNS Void -> RETURN; END
          FN b() RETURNS Void -> RETURN; END
          DO {
            @pinned -> a(),
            @pinned -> b()
          }
        FLUX
      }

      it "succeeds without errors" do
        expect { ast }.not_to raise_error
      end
    end

    context "type error inside @pinned branch is still reported" do
      let(:code) {
        <<~FLUX
          FN add(x: Number, y: Number) RETURNS Number -> RETURN x + y; END
          bad = "not-a-number";
          DO { @pinned -> add(bad, 1) }
        FLUX
      }

      it "raises a Type Error" do
        expect { ast }.to raise_error(/Type Error/i)
      end
    end

    context "Zig output: @pinned branch emits submitSpawn (pin to local)" do
      let(:code) {
        <<~FLUX
          FN work() RETURNS Void -> RETURN; END
          DO { @pinned -> work() }
        FLUX
      }

      it "emits submitSpawn for pinned branch" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("submitSpawn")
      end
    end

    context "Zig output: unpinned branch emits spawnBest, pinned emits submitSpawn" do
      let(:code) {
        <<~FLUX
          FN a() RETURNS Void -> RETURN; END
          FN b() RETURNS Void -> RETURN; END
          DO { a(), @pinned -> b() }
        FLUX
      }

      it "emits both spawnBest (regular) and submitSpawn (pinned)" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("submitSpawn")
        expect(zig).to include("CheatHeader.spawnBest")
      end
    end
  end

  describe "Auto-pinning — shared/locked captures" do
    let(:counter_struct) { "STRUCT Counter { value: Int64 }\n" }

    context "BG block capturing @locked variable" do
      let(:code) {
        counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @locked;
              p: ~Void = BG { WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; } };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "auto-pins to local scheduler (emits submitSpawn, not spawnBest)" do
        zig = ZigTranspiler.new.transpile(code)
        # The BG block should be auto-pinned: emits submitSpawn, not spawnBest
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("submitSpawn")
        expect(user_code).not_to include("spawnBest")
      end
    end

    context "BG block capturing @writeLocked variable" do
      let(:code) {
        counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @writeLocked;
              p: ~Void = BG { WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; } };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "auto-pins to local scheduler" do
        zig = ZigTranspiler.new.transpile(code)
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("submitSpawn")
        expect(user_code).not_to include("spawnBest")
      end
    end

    context "BG block with @parallel override on @locked capture" do
      let(:code) {
        counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @locked;
              p: ~Void = BG { @parallel -> WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; } };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "respects @parallel — emits spawnBest, not submitSpawn" do
        zig = ZigTranspiler.new.transpile(code)
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("spawnBest")
        expect(user_code).not_to include("submitSpawn")
      end
    end

    context "BG block without shared/locked captures" do
      let(:code) {
        <<~FLUX
          FN f() RETURNS Void ->
              p: ~Number = BG { 42.0; };
              r: Number = NEXT p;
              RETURN;
          END
        FLUX
      }

      it "uses spawnBest by default (no auto-pin)" do
        zig = ZigTranspiler.new.transpile(code)
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("spawnBest")
      end
    end

    context "DO block with @locked capture in unpinned branch" do
      let(:code) {
        counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @locked;
              DO { WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; } }
              RETURN;
          END
        FLUX
      }

      it "auto-pins the branch (emits submitSpawn)" do
        zig = ZigTranspiler.new.transpile(code)
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("submitSpawn")
      end
    end

    context "DO block with @parallel override on @locked capture" do
      let(:code) {
        counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @locked;
              DO { @parallel -> WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; } }
              RETURN;
          END
        FLUX
      }

      it "respects @parallel — emits spawnBest" do
        zig = ZigTranspiler.new.transpile(code)
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("spawnBest")
      end
    end
  end

  describe "@local capability" do
    let(:counter_struct) { "STRUCT Counter { value: Int64 }\n" }

    context "type predicates" do
      it "local? returns true for @local type" do
        t = Type.new(:Counter, sync: :local)
        expect(t.local?).to be true
        expect(t.locked?).to be false
        expect(t.any_sync?).to be true
      end

      it "zig_type returns *Counter for @local" do
        t = Type.new(:Counter, sync: :local)
        expect(t.zig_type).to eq("*Counter")
      end

      it "requires_move? returns false for @local" do
        t = Type.new(:Counter, sync: :local)
        expect(t.requires_move?).to be false
      end
    end

    context "transpiler" do
      it "emits localCreate for @local" do
        code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @local; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("CheatLib.localCreate(Counter")
      end

      it "emits const (not var) for @local binding" do
        code = counter_struct + "FN f() RETURNS Void -> MUTABLE c = Counter{ value: 0 } @local; RETURN; END"
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("const c =")
        expect(zig).not_to include("var c =")
      end

      it "BG capturing @local emits submitSpawn (auto-pinned)" do
        code = counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              MUTABLE c = Counter{ value: 0 } @local;
              p: ~Void = BG { c.value = 1; };
              NEXT p;
              RETURN;
          END
        FLUX
        zig = ZigTranspiler.new.transpile(code)
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("submitSpawn")
        expect(user_code).not_to include("spawnBest")
      end
    end

    context "@parallel + @local = compile error" do
      it "raises error when @parallel BG captures @local" do
        code = counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              MUTABLE c = Counter{ value: 0 } @local;
              p: ~Void = BG { @parallel -> c.value = 1; };
              NEXT p;
              RETURN;
          END
        FLUX
        expect { run(code) }.to raise_error(CompilerError, /@local.*@parallel/)
      end
    end

    context "primitive types cannot have capabilities" do
      it "raises error when @local is used on a number literal" do
        code = "FN f() RETURNS Void -> x = 10 @local; RETURN; END"
        expect { run(code) }.to raise_error(CompilerError, /Capability @local cannot be applied to primitive type/)
      end

      it "raises error when @locked is used on a number literal" do
        code = "FN f() RETURNS Void -> x = 10 @locked; RETURN; END"
        expect { run(code) }.to raise_error(CompilerError, /Capability @locked cannot be applied to primitive type/)
      end

      it "raises error when @indirect is used on a number literal" do
        code = "FN f() RETURNS Void -> x = 42 @indirect; RETURN; END"
        expect { run(code) }.to raise_error(CompilerError, /Capability @indirect cannot be applied to primitive type/)
      end
    end
  end

  describe "BG/DO capture safety — thread-safety enforcement" do
    let(:counter_struct) { "STRUCT Counter { value: Int64 }\n" }
    let(:noop_fn) { "FN noop() RETURNS Void -> RETURN; END\n" }

    # --- @multiowned (Rc) safety ---

    context "BG capturing @multiowned without @parallel" do
      let(:code) {
        counter_struct + noop_fn + <<~FLUX
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @multiowned;
              p: ~Void = BG { noop(); };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "compiles without error" do
        expect { run(code) }.not_to raise_error
      end
    end

    context "BG @parallel + @multiowned (direct identifier reference)" do
      let(:code) {
        counter_struct + <<~FLUX
          FN useRc(c: Counter) RETURNS Void -> RETURN; END
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @multiowned;
              p: ~Void = BG { @parallel -> useRc(c); };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "raises compile error (Rc is not thread-safe)" do
        expect { run(code) }.to raise_error(CompilerError, /multiowned.*Rc.*non-atomic/)
      end
    end

    context "DO @parallel + @multiowned (direct identifier reference)" do
      let(:code) {
        counter_struct + <<~FLUX
          FN useRc(c: Counter) RETURNS Void -> RETURN; END
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @multiowned;
              DO { @parallel -> useRc(c) }
              RETURN;
          END
        FLUX
      }

      it "raises compile error (Rc is not thread-safe)" do
        expect { run(code) }.to raise_error(CompilerError, /multiowned.*Rc.*non-atomic/)
      end
    end

    # --- @local safety ---

    context "BG @parallel + @local" do
      let(:code) {
        counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              MUTABLE c = Counter{ value: 0 } @local;
              p: ~Void = BG { @parallel -> c.value = 1; };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "raises compile error (@local has no sync)" do
        expect { run(code) }.to raise_error(CompilerError, /@local.*@parallel/)
      end
    end

    # --- @shared (Arc) — thread-safe, @parallel is allowed ---

    context "BG @parallel + @shared (no WITH needed — just reference)" do
      let(:code) {
        counter_struct + <<~FLUX
          FN useArc(c: Counter) RETURNS Void -> RETURN; END
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @shared;
              p: ~Void = BG { @parallel -> useArc(c); };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "allows @parallel (Arc is thread-safe)" do
        expect { run(code) }.not_to raise_error
      end
    end

    # --- @locked — thread-safe, @parallel is allowed ---

    context "BG @parallel + @locked (no WITH needed — just reference)" do
      let(:code) {
        counter_struct + <<~FLUX
          FN useLocked(c: Counter) RETURNS Void -> RETURN; END
          FN f() RETURNS Void ->
              c = Counter{ value: 0 } @locked;
              p: ~Void = BG { @parallel -> useLocked(c); };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "allows @parallel (Mutex is thread-safe)" do
        expect { run(code) }.not_to raise_error
      end
    end

    # --- Plain affine type — moved into BG, not shared ---

    context "BG capturing affine struct" do
      let(:code) {
        counter_struct + <<~FLUX
          FN f() RETURNS Void ->
              c = Counter{ value: 0 };
              p: ~Void = BG { print(c.value); };
              NEXT p;
              RETURN;
          END
        FLUX
      }

      it "moves the struct (outer scope loses access)" do
        expect { run(code) }.not_to raise_error
      end
    end

    # --- Primitives — always safe (value copy) ---

    context "BG capturing primitive Int64" do
      let(:code) {
        <<~FLUX
          FN f() RETURNS Void ->
              x: Int64 = 42;
              p: ~Int64 = BG { x; };
              r: Int64 = NEXT p;
              RETURN;
          END
        FLUX
      }

      it "copies the value (no move, no pinning needed)" do
        expect { run(code) }.not_to raise_error
      end
    end
  end

  describe "DO block — stack size prefix syntax" do
    subject(:ast) { run(code) }
    let(:preamble) { "FN work() RETURNS Void -> RETURN; END\n" }

    context "bare @micro -> branch" do
      let(:code) { preamble + "DO { @micro -> work() }" }

      it "parses without error" do
        expect { ast }.not_to raise_error
      end

      it "sets stack_size :micro on the branch" do
        branch = ast.statements.last.branches.first
        expect(branch[:stack_size]).to eq(:micro)
        expect(branch[:pinned]).to eq(false)
      end
    end

    context "bare @large -> branch" do
      let(:code) { preamble + "DO { @large -> work() }" }

      it "sets stack_size :large on the branch" do
        expect(ast.statements.last.branches.first[:stack_size]).to eq(:large)
      end
    end

    context "bare @xl -> branch" do
      let(:code) { preamble + "DO { @xl -> work() }" }

      it "sets stack_size :xl on the branch" do
        expect(ast.statements.last.branches.first[:stack_size]).to eq(:xl)
      end
    end

    context "bare @standard -> branch" do
      let(:code) { preamble + "DO { @standard -> work() }" }

      it "sets stack_size :standard on the branch" do
        expect(ast.statements.last.branches.first[:stack_size]).to eq(:standard)
      end
    end

    context "no prefix — branch defaults to nil stack_size" do
      let(:code) { preamble + "DO { work() }" }

      it "leaves stack_size nil" do
        expect(ast.statements.last.branches.first[:stack_size]).to be_nil
      end
    end

    context "@micro:pinned join (size first)" do
      let(:code) { preamble + "DO { @micro:pinned -> work() }" }

      it "sets both stack_size :micro and pinned true" do
        branch = ast.statements.last.branches.first
        expect(branch[:stack_size]).to eq(:micro)
        expect(branch[:pinned]).to eq(true)
      end
    end

    context "@pinned:large join (pin first)" do
      let(:code) { preamble + "DO { @pinned:large -> work() }" }

      it "sets both pinned true and stack_size :large (order-independent)" do
        branch = ast.statements.last.branches.first
        expect(branch[:stack_size]).to eq(:large)
        expect(branch[:pinned]).to eq(true)
      end
    end

    context "mixed branches with different sizes" do
      let(:code) {
        preamble +
        "FN heavy() RETURNS Void -> RETURN; END\n" \
        "DO { @micro -> work(), @large -> heavy(), work() }"
      }

      it "assigns the right sizes to each branch" do
        branches = ast.statements.last.branches
        expect(branches[0][:stack_size]).to eq(:micro)
        expect(branches[1][:stack_size]).to eq(:large)
        expect(branches[2][:stack_size]).to be_nil
      end
    end

    context "Zig output: DO @micro branch emits .Micro task config" do
      let(:code) { preamble + "DO { @micro -> work() }" }

      it "emits .stack_size = .Micro in submitSpawn" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Micro")
      end
    end

    context "Zig output: DO @large branch emits .Large task config" do
      let(:code) { preamble + "DO { @large -> work() }" }

      it "emits .stack_size = .Large in submitSpawn" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Large")
      end
    end

    context "Zig output: DO no-prefix branch emits .Standard task config" do
      let(:code) { preamble + "DO { work() }" }

      it "emits .stack_size = .Standard (the default)" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Standard")
      end
    end

    context "Zig output: @xl:pinned emits .Xl in submitSpawn (pinned to local)" do
      let(:code) { preamble + "DO { @xl:pinned -> work() }" }

      it "emits submitSpawn with .stack_size = .Xl" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include("submitSpawn")
        expect(zig).to include(".stack_size = .Xl")
      end
    end
  end

  describe "BG block — stack size prefix syntax" do
    subject(:ast) { run(code) }
    let(:work_fn) { "FN work() RETURNS Void -> RETURN; END\n" }

    context "BG { @micro -> expr; }" do
      let(:code) { work_fn + "FN f() RETURNS Void -> p: ~Void = BG { @micro -> work(); }; NEXT p; RETURN; END" }

      it "parses without error" do
        expect { ast }.not_to raise_error
      end

      it "sets stack_size :micro on the BgBlock" do
        fn   = ast.statements.last
        bg   = fn.body.first.value
        expect(bg).to be_a(AST::BgBlock)
        expect(bg.stack_size).to eq(:micro)
      end
    end

    context "BG { @large -> expr; }" do
      let(:code) { work_fn + "FN f() RETURNS Void -> p: ~Void = BG { @large -> work(); }; NEXT p; RETURN; END" }

      it "sets stack_size :large on the BgBlock" do
        fn = ast.statements.last
        bg = fn.body.first.value
        expect(bg.stack_size).to eq(:large)
      end
    end

    context "BG { expr; } with no prefix" do
      let(:code) { work_fn + "FN f() RETURNS Void -> p: ~Void = BG { work(); }; NEXT p; RETURN; END" }

      it "leaves stack_size nil" do
        fn = ast.statements.last
        bg = fn.body.first.value
        expect(bg.stack_size).to be_nil
      end
    end

    context "BG with @xl prefix" do
      let(:code) {
        "FN add(x: Number, y: Number) RETURNS Number -> RETURN x + y; END\n" \
        "FN f() RETURNS Void -> p: ~Number = BG { @xl -> add(1.0, 2.0); }; r: Number = NEXT p; RETURN; END"
      }

      it "parses and type-checks correctly" do
        expect { ast }.not_to raise_error
      end

      it "sets stack_size :xl on the BgBlock" do
        fn = ast.statements.last
        bg = fn.body.first.value
        expect(bg.stack_size).to eq(:xl)
      end
    end

    context "Zig output: BG @micro emits .Micro task config" do
      let(:code) { work_fn + "FN f() RETURNS Void -> p: ~Void = BG { @micro -> work(); }; NEXT p; RETURN; END" }

      it "emits .stack_size = .Micro in submitSpawn" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Micro")
      end
    end

    context "Zig output: BG no prefix emits .Standard task config" do
      let(:code) { work_fn + "FN f() RETURNS Void -> p: ~Void = BG { work(); }; NEXT p; RETURN; END" }

      it "emits .stack_size = .Standard" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Standard")
      end
    end
  end

  describe "CONCURRENT — size option parsing" do
    subject(:ast) { run(code) }
    let(:preamble) {
      "FN double(x: Number) RETURNS Number -> RETURN x * 2.0; END\n"
    }

    context "CONCURRENT(size: LARGE) SELECT" do
      let(:code) {
        preamble +
        "FN f() RETURNS Void -> items: Number[] = [1.0, 2.0]; " \
        "r = items s> CONCURRENT(size: LARGE) SELECT double(_); RETURN; END"
      }

      it "parses without error" do
        expect { ast }.not_to raise_error
      end

      it "captures size option as an Identifier node" do
        fn   = ast.statements.last
        # r = items s> CONCURRENT(...) SELECT ...
        # fn.body[0] = items decl, fn.body[1] = r bind (BinaryOp SMOOTH on RHS)
        pipe = fn.body[1].value        # BinaryOp(:SMOOTH, items, ConcurrentOp)
        conc = pipe.right              # ConcurrentOp
        expect(conc).to be_a(AST::ConcurrentOp)
        size_node = conc.options["size"]
        expect(size_node).to be_a(AST::Identifier)
        expect(size_node.name).to eq("LARGE")
      end
    end

    context "CONCURRENT(workers: 4, size: MICRO) WHERE" do
      let(:code) {
        preamble +
        "FN big(x: Number) RETURNS Bool -> RETURN x > 1.0; END\n" \
        "FN f() RETURNS Void -> items: Number[] = [1.0, 2.0]; " \
        "r = items s> CONCURRENT(workers: 4, size: MICRO) WHERE big(_); RETURN; END"
      }

      it "parses both workers and size options" do
        fn   = ast.statements.last
        pipe = fn.body[1].value        # BinaryOp(:SMOOTH, items, ConcurrentOp)
        conc = pipe.right
        expect(conc).to be_a(AST::ConcurrentOp)
        expect(conc.options["workers"]).to be_a(AST::Literal)
        size_node = conc.options["size"]
        expect(size_node).to be_a(AST::Identifier)
        expect(size_node.name).to eq("MICRO")
      end
    end

    context "CONCURRENT(size: STANDARD) EACH" do
      let(:code) {
        preamble +
        "FN f() RETURNS Void -> items: Number[] = [1.0]; " \
        "items s> CONCURRENT(size: STANDARD) EACH { double(_); }; RETURN; END"
      }

      it "accepts STANDARD as a valid size" do
        expect { ast }.not_to raise_error
      end
    end

    context "CONCURRENT(size: XL) SELECT" do
      let(:code) {
        preamble +
        "FN f() RETURNS Void -> items: Number[] = [1.0]; " \
        "r = items s> CONCURRENT(size: XL) SELECT double(_); RETURN; END"
      }

      it "accepts XL as a valid size" do
        expect { ast }.not_to raise_error
      end
    end

    context "CONCURRENT(size: HUGE) — invalid size" do
      let(:code) {
        preamble +
        "FN f() RETURNS Void -> items: Number[] = [1.0]; " \
        "r = items s> CONCURRENT(size: HUGE) SELECT double(_); RETURN; END"
      }

      it "raises a Compiler Error" do
        expect { ast }.to raise_error(/CONCURRENT size must be one of/i)
      end
    end

    context "Zig output: CONCURRENT(size: MICRO) emits .Micro task config" do
      let(:code) {
        preamble +
        "FN f() RETURNS Void -> items: Number[] = [1.0, 2.0]; " \
        "r = items s> CONCURRENT(size: MICRO) SELECT double(_); RETURN; END"
      }

      it "emits .stack_size = .Micro in each spawned fiber" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Micro")
      end
    end

    context "Zig output: CONCURRENT with no size emits .Standard" do
      let(:code) {
        preamble +
        "FN f() RETURNS Void -> items: Number[] = [1.0, 2.0]; " \
        "r = items s> CONCURRENT SELECT double(_); RETURN; END"
      }

      it "emits .stack_size = .Standard (the default)" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Standard")
      end
    end

    context "Zig output: CONCURRENT(size: LARGE) WHERE emits .Large" do
      let(:code) {
        preamble +
        "FN big(x: Number) RETURNS Bool -> RETURN x > 1.0; END\n" \
        "FN f() RETURNS Void -> items: Number[] = [1.0, 2.0]; " \
        "r = items s> CONCURRENT(size: LARGE) WHERE big(_); RETURN; END"
      }

      it "emits .stack_size = .Large" do
        zig = ZigTranspiler.new.transpile(code)
        expect(zig).to include(".stack_size = .Large")
      end
    end
  end

end
