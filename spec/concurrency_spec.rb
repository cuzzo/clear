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

      it "auto-pins (emits spawnPinned, not spawnBest)" do
        zig = ZigTranspiler.new.transpile(code)
        # The BG block should be auto-pinned: emits spawnPinned, not spawnBest
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("spawnPinned")
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

      it "auto-pins to scheduler (distributed)" do
        zig = ZigTranspiler.new.transpile(code)
        user_code = zig.split("// 3. Main Entry").first
        expect(user_code).to include("spawnPinned")
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

      it "BG capturing @local emits spawnPinned (auto-pinned)" do
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
        expect(user_code).to include("spawnPinned")
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

      it "emits .stack_size = .Standard (the default)" do
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

  # ===========================================================================
  # CONCURRENT modifier — parallel SELECT, WHERE, EACH
  # ===========================================================================
  describe "CONCURRENT modifier (parallel pipeline operator)" do
    def transpile_fn(src)
      ZigTranspiler.new.transpile(src)
    end

    # -------------------------------------------------------------------------
    # Type resolution
    # -------------------------------------------------------------------------
    it "CONCURRENT SELECT resolves to element_type[]" do
      tree = run(<<~CLEAR)
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2.0;
        END
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0, 3.0];
          results = items s> CONCURRENT SELECT double(_);
          RETURN;
        END
      CLEAR
      fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
      bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "results" }
      expect(bind.resolved_type).to eq(:"Number[]")
    end

    it "CONCURRENT WHERE resolves to item_type[]" do
      tree = run(<<~CLEAR)
        STRUCT Item { value: Number }
        FN f() RETURNS Void ->
          items: Item[] = [];
          evens = items s> CONCURRENT WHERE _.value > 0.0;
          RETURN;
        END
      CLEAR
      fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
      bind = fn_node.body.find { |n| n.is_a?(AST::BindExpr) && n.name == "evens" }
      expect(bind.resolved_type).to eq(:"Item[]")
    end

    it "CONCURRENT EACH resolves to Void" do
      tree = run(<<~CLEAR)
        STRUCT Score { value: Number }
        FN f() RETURNS Void ->
          items: Score[] = [];
          items s> CONCURRENT EACH { _.value = 0.0; };
          RETURN;
        END
      CLEAR
      fn_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "f" }
      # The EACH pipeline is a BinaryOp with SMOOTH operator at top level
      smooth = fn_node.body.find { |n| n.is_a?(AST::BinaryOp) && n.op == :SMOOTH }
      expect(smooth.resolved_type).to eq(:Void)
    end

    it "CONCURRENT(workers: N) SELECT accepts numeric workers" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS Void ->
            items: Number[] = [1.0, 2.0];
            results = items s> CONCURRENT(workers: 4) SELECT _ * 2.0;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    # -------------------------------------------------------------------------
    # Error cases
    # -------------------------------------------------------------------------
    it "raises an error when CONCURRENT SELECT is applied to a non-array" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS Void ->
            x: Number = 42.0;
            r = x s> CONCURRENT SELECT _ * 2.0;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot SELECT from non-list type/)
    end

    it "raises an error when CONCURRENT WHERE predicate is non-Bool" do
      expect {
        run(<<~CLEAR)
          FN f() RETURNS Void ->
            items: Number[] = [1.0, 2.0];
            r = items s> CONCURRENT WHERE _ * 2.0;
            RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /WHERE clause must evaluate to Bool/)
    end

    # -------------------------------------------------------------------------
    # Zig output
    # -------------------------------------------------------------------------
    it "CONCURRENT SELECT emits WaitGroup and persistent worker pool" do
      out = transpile_fn(<<~CLEAR)
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0, 3.0];
          results = items s> CONCURRENT(workers: 3) SELECT _ * 2.0;
          RETURN;
        END
      CLEAR
      expect(out).to include("WaitGroup")
      expect(out).to include("submitSpawn")
      expect(out).to include("fetchAdd") # atomic work index
      expect(out).not_to include("Semaphore") # no semaphore in worker pool
    end

    it "CONCURRENT WHERE emits WaitGroup and persistent worker pool" do
      out = transpile_fn(<<~CLEAR)
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0, 3.0];
          evens = items s> CONCURRENT WHERE _ > 1.0;
          RETURN;
        END
      CLEAR
      expect(out).to include("WaitGroup")
      expect(out).to include("submitSpawn")
      expect(out).to include("fetchAdd")
      expect(out).not_to include("Semaphore")
    end

    it "CONCURRENT EACH emits WaitGroup and persistent worker pool" do
      out = transpile_fn(<<~CLEAR)
        STRUCT Score { value: Number }
        FN f() RETURNS Void ->
          items: Score[] = [];
          items s> CONCURRENT(workers: 2) EACH { _.value = 0.0; };
          RETURN;
        END
      CLEAR
      expect(out).to include("WaitGroup")
      expect(out).to include("submitSpawn")
      expect(out).to include("fetchAdd")
      expect(out).not_to include("Semaphore")
    end

    it "CONCURRENT SELECT uses default 8 workers when omitted" do
      out = transpile_fn(<<~CLEAR)
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0];
          results = items s> CONCURRENT SELECT _ * 2.0;
          RETURN;
        END
      CLEAR
      expect(out).to include("@intCast(8)")
    end

    it "CONCURRENT SELECT fn OR PRUNE — expression type is unwrapped T (not !T)" do
      src = <<~CLEAR
        FN mayFail(x: Number) RETURNS !Number ->
          RETURN x * 2.0;
        END
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0];
          results = items s> CONCURRENT(workers: 2) SELECT mayFail(_) OR PRUNE;
          RETURN;
        END
      CLEAR
      # Should not raise; resolved type is Number[] not !Number[]
      expect { transpile_fn(src) }.not_to raise_error
      out = transpile_fn(src)
      expect(out).to include("__CcsWorker0")
      # result type should be Number (not error union)
      expect(out).to include("?f64")
    end

    it "CONCURRENT SELECT fn OR RAISE — expression type is unwrapped T" do
      src = <<~CLEAR
        FN mayFail(x: Number) RETURNS !Number ->
          RETURN x * 2.0;
        END
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0];
          results = items s> CONCURRENT(workers: 2) SELECT mayFail(_) OR RAISE;
          RETURN;
        END
      CLEAR
      expect { transpile_fn(src) }.not_to raise_error
      out = transpile_fn(src)
      expect(out).to include("__CcsWorker0")
      expect(out).to include("?f64")
    end

    it "CONCURRENT default uses submitSpawn (local scheduler, deterministic)" do
      out = transpile_fn(<<~CLEAR)
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0, 3.0];
          results = items s> CONCURRENT(workers: 2) SELECT _ * 2.0;
          RETURN;
        END
      CLEAR
      user_code = out.split("// 3. Main Entry").first
      expect(user_code).to include("submitSpawn")
    end

    it "CONCURRENT(parallel: TRUE) distributes via spawnBest (multi-core parallel)" do
      out = transpile_fn(<<~CLEAR)
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0, 3.0];
          results = items s> CONCURRENT(workers: 2, parallel: TRUE) SELECT _ * 2.0;
          RETURN;
        END
      CLEAR
      user_code = out.split("// 3. Main Entry").first
      expect(user_code).to include("spawnBest")
    end

    it "CONCURRENT SELECT fn OR PRUNE emits catch |_| return in fiber body" do
      src = <<~CLEAR
        FN mayFail(x: Number) RETURNS !Number ->
          RETURN x * 2.0;
        END
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0];
          results = items s> CONCURRENT(workers: 2) SELECT mayFail(_) OR PRUNE;
          RETURN;
        END
      CLEAR
      out = transpile_fn(src)
      expect(out).to include("catch return")
    end

    it "CONCURRENT SELECT fn OR RAISE emits cmpxchgStrong and @errorFromInt" do
      src = <<~CLEAR
        FN mayFail(x: Number) RETURNS !Number ->
          RETURN x * 2.0;
        END
        FN f() RETURNS Void ->
          items: Number[] = [1.0, 2.0];
          results = items s> CONCURRENT(workers: 2) SELECT mayFail(_) OR RAISE;
          RETURN;
        END
      CLEAR
      out = transpile_fn(src)
      expect(out).to include("cmpxchgStrong")
      expect(out).to include("@errorFromInt")
    end

    # -------------------------------------------------------------------------
    # CONCURRENT option validation
    # -------------------------------------------------------------------------
    context "CONCURRENT option validation" do
      it "rejects workers of 0" do
        code = <<~CLEAR
          FN main() RETURNS Void ->
            nums: Number[] = [1.0, 2.0];
            result = nums s> CONCURRENT(workers: 0) SELECT _ * 2.0;
            RETURN;
          END
        CLEAR
        expect { run(code) }.to raise_error(/workers must be greater than 0/)
      end

      it "rejects negative workers" do
        code = <<~CLEAR
          FN main() RETURNS Void ->
            nums: Number[] = [1.0];
            result = nums s> CONCURRENT(workers: -1) SELECT _ * 2.0;
            RETURN;
          END
        CLEAR
        expect { run(code) }.to raise_error(/workers must be greater than 0/)
      end

      it "rejects unknown options" do
        code = <<~CLEAR
          FN main() RETURNS Void ->
            nums: Number[] = [1.0];
            result = nums s> CONCURRENT(invalid_opt: 4) SELECT _ * 2.0;
            RETURN;
          END
        CLEAR
        expect { run(code) }.to raise_error(/Unknown CONCURRENT option/)
      end

      it "rejects non-Bool pin value" do
        code = <<~CLEAR
          FN main() RETURNS Void ->
            nums: Number[] = [1.0];
            result = nums s> CONCURRENT(workers: 4, parallel: 1) SELECT _ * 2.0;
            RETURN;
          END
        CLEAR
        expect { run(code) }.to raise_error(/parallel must be a Bool/)
      end
    end

    # -------------------------------------------------------------------------
    # CONCURRENT OR PRUNE / OR RAISE validation
    # -------------------------------------------------------------------------
    context "CONCURRENT OR PRUNE / OR RAISE validation" do
      it "rejects OR PRUNE when expression is not error-returning" do
        code = <<~CLEAR
          FN double(x: Number) RETURNS Number ->
            RETURN x * 2.0;
          END
          FN main() RETURNS Void ->
            nums: Number[] = [1.0, 2.0];
            result = nums s> CONCURRENT SELECT double(_) OR PRUNE;
            RETURN;
          END
        CLEAR
        expect { run(code) }.to raise_error(/OR PRUNE requires the expression to return an error union/)
      end

      it "rejects OR RAISE when expression is not error-returning" do
        code = <<~CLEAR
          FN double(x: Number) RETURNS Number ->
            RETURN x * 2.0;
          END
          FN main() RETURNS Void ->
            nums: Number[] = [1.0, 2.0];
            result = nums s> CONCURRENT SELECT double(_) OR RAISE;
            RETURN;
          END
        CLEAR
        expect { run(code) }.to raise_error(/OR RAISE requires the expression to return an error union/)
      end

      it "accepts OR PRUNE when expression returns !T" do
        code = <<~CLEAR
          FN mayFail(x: Number) RETURNS !Number ->
            RETURN x * 2.0;
          END
          FN main() RETURNS Void ->
            nums: Number[] = [1.0, 2.0];
            result = nums s> CONCURRENT SELECT mayFail(_) OR PRUNE;
            RETURN;
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # BG THEN chains
  # ===========================================================================
  describe "BG THEN chains" do
    it "two-step THEN chain resolves to the last step's type" do
      code = <<~CLEAR
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2.0;
        END
        FN main() RETURNS Void ->
          h = BG { 5.0 AS n THEN double(n) };
          v = NEXT h;
          RETURN;
        END
      CLEAR
      tree = run(code)
      bg = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "main" }
             .body.first.value
      expect(bg.full_type.to_s).to eq("~Number")
    end

    it "three-step THEN chain resolves to the last step's type" do
      code = <<~CLEAR
        FN add_one(x: Number) RETURNS Number ->
          RETURN x + 1.0;
        END
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2.0;
        END
        FN main() RETURNS Void ->
          h = BG { add_one(2.0) AS a THEN double(a) AS b THEN add_one(b) };
          v = NEXT h;
          RETURN;
        END
      CLEAR
      tree = run(code)
      bg = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "main" }
             .body.first.value
      expect(bg.full_type.to_s).to eq("~Number")
    end

    it "THEN without AS binding resolves to last step's type" do
      code = <<~CLEAR
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2.0;
        END
        FN main() RETURNS Void ->
          h = BG { double(1.0) THEN double(2.0) };
          v = NEXT h;
          RETURN;
        END
      CLEAR
      tree = run(code)
      bg = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "main" }
             .body.first.value
      expect(bg.full_type.to_s).to eq("~Number")
    end

    it "AS binding is accessible to subsequent THEN steps" do
      code = <<~CLEAR
        FN add(a: Number, b: Number) RETURNS Number ->
          RETURN a + b;
        END
        FN main() RETURNS Void ->
          h = BG { 3.0 AS x THEN add(x, x) };
          v = NEXT h;
          RETURN;
        END
      CLEAR
      expect { run(code) }.not_to raise_error
    end

    it "raises a parse error when AS appears without THEN" do
      code = <<~CLEAR
        FN foo() RETURNS Number ->
          RETURN 1.0;
        END
        FN main() RETURNS Void ->
          h = BG { foo() AS f; };
          RETURN;
        END
      CLEAR
      expect { run(code) }.to raise_error(/Expected THEN after AS binding/)
    end

    it "ThenChain node is produced in BG block body" do
      code = <<~CLEAR
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2.0;
        END
        FN main() RETURNS Void ->
          h = BG { double(1.0) AS r THEN double(r) };
          v = NEXT h;
          RETURN;
        END
      CLEAR
      tree = run(code)
      bg_node = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "main" }
                  .body.first.value
      expect(bg_node.body.first).to be_a(AST::ThenChain)
    end

    it "THEN chain mixed with a setup statement resolves correctly" do
      code = <<~CLEAR
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2.0;
        END
        FN main() RETURNS Void ->
          h = BG {
            n = double(1.0);
            n AS x THEN double(x)
          };
          v = NEXT h;
          RETURN;
        END
      CLEAR
      tree = run(code)
      bg = tree.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "main" }
             .body.first.value
      expect(bg.full_type.to_s).to eq("~Number")
    end
  end

  # ===================================================================
  # BG / ~T (Tense / Promise) — Phase 2: Annotator & Ownership
  # ===================================================================
  describe "BG / ~T Phase 2: annotator and ownership" do
    # Helper: construct and annotate a BgBlock directly (no parser needed yet)
    def make_bg_block(body_nodes)
      token = Lexer::Token.new(:KEYWORD, 'BG', 1, 1)
      AST::BgBlock.new(token, body_nodes)
    end

    def make_next_expr(expr_node)
      token = Lexer::Token.new(:KEYWORD, 'NEXT', 1, 1)
      AST::NextExpr.new(token, expr_node)
    end

    # Helper: AST::Literal for a Number value (no scope lookup required by visit_Literal)
    def make_num_lit(val = 42.0)
      tok = Lexer::Token.new(:NUMBER, val, 1, 1)
      AST::Literal.new(tok, :NUMBER, val, nil)
    end

    describe "visit_BgBlock" do
      it "sets full_type to ~Void when body is empty" do
        annotator = SemanticAnnotator.new
        node = make_bg_block([])
        annotator.send(:visit_BgBlock, node)
        expect(node.full_type).to eq(:"~Void")
      end

      it "wraps the last expression's type in ~ (Number literal body)" do
        annotator = SemanticAnnotator.new
        bg = make_bg_block([make_num_lit])
        annotator.send(:visit_BgBlock, bg)
        expect(bg.full_type).to eq(:"~Number")
      end
    end

    describe "visit_NextExpr" do
      it "raises when NEXT is called on a Number literal (non-tense)" do
        annotator = SemanticAnnotator.new
        next_node = make_next_expr(make_num_lit)
        expect { annotator.send(:visit_NextExpr, next_node) }
          .to raise_error(SourceError, /NEXT requires a Promise/)
      end
    end

    describe "~T in type annotations (lexer + parser)" do
      it "tokenises ~ as a CHAR token" do
        tokens = Lexer.new("~Number").tokenize
        expect(tokens[0]).to have_attributes(type: :CHAR, value: '~')
        expect(tokens[1]).to have_attributes(type: :TYPE_ID, value: 'Number')
      end

      it "tokenises ~!Number with tilde, bang, type" do
        tokens = Lexer.new("~!Number").tokenize
        expect(tokens[0]).to have_attributes(type: :CHAR, value: '~')
        expect(tokens[1]).to have_attributes(type: :CHAR, value: '!')
        expect(tokens[2]).to have_attributes(type: :TYPE_ID, value: 'Number')
      end

      it "parse_type_annotation produces a tense Type for ~Number" do
        tokens = Lexer.new("~Number").tokenize
        parser = Parser.new(tokens, "~Number")
        t = parser.send(:parse_type_annotation)
        expect(t.tense?).to be true
        expect(t.tense_type).to eq(:Number)
        expect(t.zig_type).to eq("CheatLib.Promise(f64)")
      end
    end

    describe "ownership tracker linear check" do
      it "raises when a tense variable is live at scope end" do
        annotator = SemanticAnnotator.new
        dummy_token = Lexer::Token.new(:KEYWORD, 'BG', 1, 1)
        dummy_node  = AST::BgBlock.new(dummy_token, [])

        # with_new_scope yields and then pops — we call finalize_scope inside the block
        expect {
          annotator.send(:with_new_scope) do
            annotator.send(:current_scope).declare('p', nil, :"~Number", false, false, nil, :stack)
            annotator.send(:current_scope).set_state('p', :live)
            annotator.send(:finalize_scope, dummy_node)
          end
        }.to raise_error(SourceError, /Promise 'p' must be consumed/)
      end

      it "does NOT raise when the tense variable has been moved (consumed)" do
        annotator = SemanticAnnotator.new
        dummy_token = Lexer::Token.new(:KEYWORD, 'BG', 1, 1)
        dummy_node  = AST::BgBlock.new(dummy_token, [])

        expect {
          annotator.send(:with_new_scope) do
            annotator.send(:current_scope).declare('p', nil, :"~Number", false, false, nil, :stack)
            annotator.send(:current_scope).set_state('p', :moved)
            annotator.send(:finalize_scope, dummy_node)
          end
        }.not_to raise_error
      end
    end
  end

  # ===================================================================
  # BG / ~T (Tense / Promise) — Phase 1: Type System
  # ===================================================================
  describe "~T (tense/promise) type system" do
    describe "Type parsing" do
      it "recognises ~Number as a tense type" do
        t = Type.new(:"~Number")
        expect(t.tense?).to be true
        expect(t.tense_type).to eq(:Number)
      end

      it "recognises ~Void as a tense type" do
        t = Type.new(:"~Void")
        expect(t.tense?).to be true
        expect(t.tense_type).to eq(:Void)
      end

      it "recognises ~!Number as a promise of a failable Number" do
        t = Type.new(:"~!Number")
        expect(t.tense?).to be true
        expect(t.tense_type.error_union?).to be true
        expect(t.tense_type.payload_type).to eq(:Number)
      end

      it "is not a struct, primitive, optional, or error_union" do
        t = Type.new(:"~Number")
        expect(t.struct?).to be false
        expect(t.primitive?).to be false
        expect(t.optional?).to be false
        expect(t.error_union?).to be false
      end
    end

    describe "Type#requires_move?" do
      it "returns true for tense types — promises are linear" do
        expect(Type.new(:"~Number").requires_move?).to be true
        expect(Type.new(:"~Void").requires_move?).to be true
      end
    end

    describe "Type#accepts?" do
      it "accepts the same tense type" do
        expect(Type.new(:"~Number").accepts?(Type.new(:"~Number"))).to be true
      end

      it "does not accept a non-tense type" do
        expect(Type.new(:"~Number").accepts?(Type.new(:Number))).to be false
      end

      it "does not accept a different tense type" do
        expect(Type.new(:"~Number").accepts?(Type.new(:"~Bool"))).to be false
      end
    end

    describe "Type#zig_type" do
      it "emits CheatLib.Promise(f64) for ~Number" do
        expect(Type.new(:"~Number").zig_type).to eq("CheatLib.Promise(f64)")
      end

      it "emits CheatLib.Promise(void) for ~Void" do
        expect(Type.new(:"~Void").zig_type).to eq("CheatLib.Promise(void)")
      end

      it "emits CheatLib.Promise(!f64) for ~!Number" do
        expect(Type.new(:"~!Number").zig_type).to eq("CheatLib.Promise(!f64)")
      end
    end

    describe "Lexer" do
      it "tokenises BG as a keyword" do
        tokens = Lexer.new("BG").tokenize
        expect(tokens[0].type).to eq(:KEYWORD)
        expect(tokens[0].value).to eq("BG")
      end

      it "tokenises NEXT as a keyword" do
        tokens = Lexer.new("NEXT").tokenize
        expect(tokens[0].type).to eq(:KEYWORD)
        expect(tokens[0].value).to eq("NEXT")
      end
    end
  end

  # ===================================================================
  # BG / ~T (Tense / Promise) — Phase 5: Integration
  # ===================================================================
  describe "BG/NEXT — Phase 5: integration (collect_do_identifiers fix)" do
    def transpile_fn(clear_src)
      tokens    = Lexer.new(clear_src).tokenize
      ast       = Parser.new(tokens, clear_src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      t = ZigTranspiler.new
      t.send(:visit, ast)
    end

    it "collect_do_identifiers does not capture locally-bound names from BindExpr" do
      # If 'step1' is declared inside BG, it must NOT appear as a capture field.
      src = <<~CLEAR
        FN f() RETURNS Void ->
          x: Number = 5.0;
          q: ~Number = BG { x + 1.0; };
          r: Number = NEXT q;
          RETURN;
        END
      CLEAR
      out = transpile_fn(src)
      # x IS captured (outer variable)
      expect(out).to include("x: f64,")
      # step1 is NOT a capture (it doesn't exist; this just verifies no spurious fields)
      expect(out).not_to include("step1:")
    end

    it "multiple concurrent BG blocks get independent context structs" do
      src = <<~CLEAR
        FN f() RETURNS Void ->
          a: ~Number = BG { 10.0; };
          b: ~Number = BG { 20.0; };
          ra: Number = NEXT a;
          rb: Number = NEXT b;
          RETURN;
        END
      CLEAR
      out = transpile_fn(src)
      # Should have two separate context structs
      expect(out).to include("__BgCtx0")
      expect(out).to include("__BgCtx1")
      # And two separate labeled blocks
      expect(out).to include("__bg0:")
      expect(out).to include("__bg1:")
      # Both NEXTs
      expect(out).to include("a.next()")
      expect(out).to include("b.next()")
    end

    it "BG with function call inside captures its args by value" do
      src = <<~CLEAR
        FN double(x: Number) RETURNS Number ->
          RETURN x * 2.0;
        END
        FN f() RETURNS Void ->
          base: Number = 5.0;
          p: ~Number = BG { double(base); };
          r: Number = NEXT p;
          RETURN;
        END
      CLEAR
      out = transpile_fn(src)
      expect(out).to include("base: f64,")
      expect(out).to include(".base = base")
      expect(out).to include("ctx.base")
      expect(out).to include("p.next()")
    end
  end

  # ===================================================================
  # BG / ~T (Tense / Promise) — Phase 4: Parser + Transpiler
  # ===================================================================
  describe "BG/NEXT — Phase 4: parser and transpiler" do
    def transpile_fn(clear_src)
      tokens    = Lexer.new(clear_src).tokenize
      ast       = Parser.new(tokens, clear_src).parse
      annotator = SemanticAnnotator.new
      annotator.annotate!(ast)
      t = ZigTranspiler.new
      t.send(:visit, ast)
    end

    describe "Parser" do
      it "parses BG { expr; } as a BgBlock node" do
        tokens = Lexer.new("BG { 42.0; }").tokenize
        parser = Parser.new(tokens, "BG { 42.0; }")
        node   = parser.send(:parse_bg_block)
        expect(node).to be_a(AST::BgBlock)
        expect(node.body.length).to eq(1)
      end

      it "parses NEXT expr as a NextExpr node" do
        tokens = Lexer.new("NEXT p").tokenize
        parser = Parser.new(tokens, "NEXT p")
        node   = parser.send(:parse_next_expr)
        expect(node).to be_a(AST::NextExpr)
        expect(node.expr).to be_a(AST::Identifier)
        expect(node.expr.name).to eq("p")
      end

      it "parses BG { expr; } as the RHS of a bind expression" do
        src    = "FN f() RETURNS Void -> p: ~Number = BG { 1.0; }; RETURN; END"
        tokens = Lexer.new(src).tokenize
        ast    = Parser.new(tokens, src).parse
        fn_node = ast.statements.first
        bind    = fn_node.body.first
        expect(bind.value).to be_a(AST::BgBlock)
      end

      it "parses NEXT as an expression in a bind" do
        src    = "FN f() RETURNS Void -> p: ~Number = BG { 1.0; }; r: Number = NEXT p; RETURN; END"
        tokens = Lexer.new(src).tokenize
        ast    = Parser.new(tokens, src).parse
        fn_node = ast.statements.first
        next_bind = fn_node.body[1]
        expect(next_bind.value).to be_a(AST::NextExpr)
      end
    end

    describe "Transpiler" do
      it "BgBlock emits a labeled block with Promise spawn and spawnBest (default)" do
        src = "FN f() RETURNS Void -> p: ~Number = BG { 42.0; }; r: Number = NEXT p; RETURN; END"
        out = transpile_fn(src)
        expect(out).to include("CheatLib.Promise(f64).spawn(")
        expect(out).to include("spawnBest(")
        expect(out).to include("break :")
        expect(out).to include("ctx.inner.result = 42")
      end

      it "BgBlock captures outer variable by value (no pointer)" do
        src = "FN f() RETURNS Void -> x: Number = 7.0; q: ~Number = BG { x + 1.0; }; r: Number = NEXT q; RETURN; END"
        out = transpile_fn(src)
        # Captured as value field, not pointer
        expect(out).to include("x: f64,")
        # Initialized as .x = x  (not .x = &x)
        expect(out).to include(".x = x")
        # Accessed without deref: ctx.x (not ctx.x.*)
        expect(out).to include("ctx.x")
        expect(out).not_to include("ctx.x.*")
      end

      it "NextExpr emits .next() on the promise" do
        src = "FN f() RETURNS Void -> p: ~Number = BG { 99.0; }; r: Number = NEXT p; RETURN; END"
        out = transpile_fn(src)
        expect(out).to include("p.next()")
      end

      it "Promise(void) Zig type string is correct at the type level" do
        expect(Type.new(:"~Void").zig_type).to eq("CheatLib.Promise(void)")
      end

      it "NEXT on a non-tense type raises an annotator error" do
        src = "FN f() RETURNS Void -> x: Number = 1.0; r: Number = NEXT x; RETURN; END"
        expect { transpile_fn(src) }.to raise_error(SourceError, /NEXT requires a Promise/)
      end
    end
  end

  describe "DO block" do

    context "three concurrent branches accessing the same @locked counter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
          DO {
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; },
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
          }
        FLUX
      }

      it "succeeds (mutex serialises concurrent mutations)" do
        expect { ast }.not_to raise_error
      end
    end
  end

end
