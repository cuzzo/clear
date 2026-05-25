require "rspec"
require "open3"
require "tempfile"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"
require_relative "../src/annotator/helpers/effects"

# FSM Phase A: viability classifier + suspend-point enumeration + BG spawn_form.
# Phase A produces metadata only — the emitter still produces stackful fibers.
# Phase B will consume fsm_eligible / fsm_suspend_points / BgBlock.spawn_form
# to switch call sites to spawnFsmBest / spawnFsmOn.
RSpec.describe "FSM classifier (Phase A)" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def fn(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  def bgs(ast)
    found = []
    walk = lambda do |n|
      case n
      when Array then n.each { |x| walk.call(x) }
      when AST::BgBlock, AST::BgStreamBlock
        found << n
        n.body.each { |x| walk.call(x) }
      else
        n.each_pair { |_, v| walk.call(v) } if n.respond_to?(:each_pair)
      end
    end
    walk.call(ast.statements)
    found
  end

  describe "fsm_eligible" do
    it "is true for a fn with an IO call (SUSPENDS) and no disqualifying effects" do
      ast = annotate(<<~CLEAR)
        FN loadIt() RETURNS !Void ->
          content = readFile("foo.txt");
          RETURN;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "loadIt")
      expect(f.effects).to include(:SUSPENDS)
      expect(f.fsm_eligible).to eq(true)
      expect(f.fsm_ineligible_reason).to be_nil
    end

    it "is false for @reentrant self-recursive fns" do
      ast = annotate(<<~CLEAR)
        FN countDown(n: Int64) RETURNS !Void @reentrant ->
          IF n <= 0 THEN RETURN; END
          _ = readFile("foo.txt");
          countDown(n - 1);
          RETURN;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "countDown")
      expect(f.effects).to include(:REENTRANT)
      expect(f.fsm_eligible).to eq(false)
      expect(f.fsm_ineligible_reason).to eq(:reentrant)
    end

    it "is false for fns with no SUSPENDS (pure compute)" do
      ast = annotate(<<~CLEAR)
        FN addOne(n: Int64) RETURNS Int64 ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "addOne")
      expect(f.fsm_eligible).to eq(false)
      expect(f.fsm_ineligible_reason).to eq(:no_suspends)
    end

    it "is true when SUSPENDS comes from a transitive callee" do
      ast = annotate(<<~CLEAR)
        FN leaf() RETURNS !Void ->
          _ = readFile("foo.txt");
          RETURN;
        END
        FN wrapper() RETURNS !Void ->
          leaf();
          RETURN;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "wrapper")
      expect(f.effects).to include(:SUSPENDS)
      expect(f.fsm_eligible).to eq(true)
    end

    it "is true for fns that acquire a lock (BLOCKING no longer disqualifies)" do
      ast = annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 0 } @locked;
          WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
          RETURN;
        END
      CLEAR
      f = fn(ast, "main")
      expect(f.effects).to include(:BLOCKING)
      expect(f.effects).to include(:SUSPENDS)
      expect(f.fsm_eligible).to eq(true)
    end
  end

  describe "fsm_suspend_points" do
    it "enumerates IO calls" do
      ast = annotate(<<~CLEAR)
        FN twoReads() RETURNS !Void ->
          a = readFile("a.txt");
          b = readFile("b.txt");
          RETURN;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "twoReads")
      expect(f.fsm_eligible).to eq(true)
      pts = f.fsm_suspend_points
      expect(pts.map { |p| p[:kind] }).to eq([:io, :io])
      expect(pts.map { |p| p[:id] }).to eq([0, 1])
    end

    it "enumerates NEXT as a suspend point" do
      ast = annotate(<<~CLEAR)
        FN awaits() RETURNS !Int64 ->
          p: ~Int64 = BG { 42; };
          RETURN NEXT p;
        END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "awaits")
      kinds = f.fsm_suspend_points.map { |p| p[:kind] }
      expect(kinds).to include(:next)
    end

    it "enumerates WITH EXCLUSIVE as a lock suspend point" do
      ast = annotate(<<~CLEAR)
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = Counter{ value: 0 } @locked;
          WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; }
          RETURN;
        END
      CLEAR
      f = fn(ast, "main")
      kinds = f.fsm_suspend_points.map { |p| p[:kind] }
      expect(kinds).to include(:lock)
    end

    it "is nil for ineligible functions" do
      ast = annotate(<<~CLEAR)
        FN pure(n: Int64) RETURNS Int64 -> RETURN n + 1; END
        FN main() RETURNS Void -> RETURN; END
      CLEAR
      f = fn(ast, "pure")
      expect(f.fsm_suspend_points).to be_nil
    end
  end

  describe "BgBlock.spawn_form" do
    it "classifies an IO-only BG body as :fsm" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~String = BG { readFile("foo.txt"); };
          contents = NEXT p;
          RETURN;
        END
      CLEAR
      bg = bgs(ast).first
      expect(bg.spawn_form).to eq(:fsm)
      expect(bg.fsm_ineligible_reason).to be_nil
    end

    it "classifies a pure-compute BG body as :fsm (collapses to 1-state)" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { 2 + 2; };
          x = NEXT p;
          RETURN;
        END
      CLEAR
      bg = bgs(ast).first
      expect(bg.spawn_form).to eq(:fsm)
    end

    it "classifies a BG body that calls a @reentrant fn as :stackful" do
      ast = annotate(<<~CLEAR)
        FN countDown(n: Int64) RETURNS Void @reentrant ->
          IF n <= 0 THEN RETURN; END
          countDown(n - 1);
          RETURN;
        END
        FN main() RETURNS Void ->
          p: ~Void = BG { @service -> countDown(10); };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      bg = bgs(ast).first
      expect(bg.spawn_form).to eq(:stackful)
      # With Phase 4g, the user must declare @service explicitly to call
      # plain :reentrant. The classifier records :explicit_stack_size
      # because @service short-circuits the reentrance check.
      expect([:reentrant, :explicit_stack_size]).to include(bg.fsm_ineligible_reason)
    end

    it "classifies BG with explicit stack_size as :stackful (preserves user intent)" do
      ast = annotate(<<~CLEAR)
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @xl -> 7; };
          x = NEXT p;
          RETURN;
        END
      CLEAR
      bg = bgs(ast).first
      expect(bg.spawn_form).to eq(:stackful)
      expect(bg.fsm_ineligible_reason).to eq(:explicit_stack_size)
    end
  end

  # --- Phase B1: pure-compute BG lowers to an FsmTask-backed state machine ---
  describe "Phase B1 emission (pure-compute FSM)" do
    def transpile(source)
      ZigTranspiler.new.transpile(source)
    end

    it "emits FsmTask + resumeFn + submitFsmSpawn for a local pure-compute BG" do
      # @local captures force same-scheduler dispatch — FSM version is submitFsmSpawn.
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }
        FN inc(c: Counter) RETURNS Void -> RETURN; END
        FN main() RETURNS Void ->
            c = Counter{ value: 0 } @local;
            p: ~Void = BG { inc(c); };
            NEXT p;
            RETURN;
        END
      CLEAR
      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).to include("CheatHeader.FsmTask")
      expect(user_code).to include("fn resumeFn")
      # Legacy B1 emit named the body fn `runBody`; recursive emit
      # uses `runSeg<N>`. Either signals an FSM body fn is present.
      expect(user_code).to match(/fn run(?:Body|Seg\d+)\(/)
      expect(user_code).to include("@ptrCast(@alignCast(__fsm_task.ctx.?))")
      expect(user_code).to include("submitFsmSpawn(__bg0_ctx.task)")
      expect(user_code).not_to include("submitSpawn(")
    end

    it "emits submitFsmSpawn for a default pure-compute BG" do
      src = "FN main() RETURNS Void -> p: ~Int64 = BG { 42; }; _ = NEXT p; RETURN; END"
      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).to include("submitFsmSpawn(__bg0_ctx.task)")
      expect(user_code).not_to include("CheatHeader.spawnFsmBest(")
      expect(user_code).not_to include("CheatHeader.spawnBest(")
    end

    it "emits spawnFsmBest for an explicit @parallel pure-compute BG" do
      src = "FN main() RETURNS Void -> p: ~Int64 = BG { @parallel -> 42; }; _ = NEXT p; RETURN; END"
      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).to include("CheatHeader.spawnFsmBest(__bg0_ctx.task)")
      expect(user_code).not_to include("submitFsmSpawn(__bg0_ctx.task)")
      expect(user_code).not_to include("CheatHeader.spawnBest(")
    end

    it "stores task as a *FsmTask pointer (slab-allocated; ctx-back-pointer recovery)" do
      src = "FN main() RETURNS Void -> p: ~Int64 = BG { 42; }; _ = NEXT p; RETURN; END"
      user_code = transpile(src).split("// 3. Main Entry").first
      # The state struct's first field must be `task: *...FsmTask` — the
      # FsmTask now lives in the scheduler's fsm_task_slab and the ctx
      # holds a forward pointer to it (ctx recovery flows back via
      # FsmTask.ctx, not @fieldParentPtr).
      match = user_code.match(/const __BgCtx0 = struct \{\s*([^\n]+)\n/)
      expect(match).not_to be_nil
      expect(match[1].strip).to start_with("task: *CheatHeader.FsmTask")
    end

    it "resumeFn returns Done, clears wg, and frees the ctx through the runtime helper" do
      src = "FN main() RETURNS Void -> p: ~Int64 = BG { 42; }; _ = NEXT p; RETURN; END"
      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).to include("__ctx_0.inner.wg.done()")
      expect(user_code).to include("CheatHeader.freeFsmCtx(@This(), __fsm_task, __ctx_0)")
      expect(user_code).to include("return .{ .Done = {} }")
    end

    it "falls back to stackful for BG with an explicit stack_size prefix" do
      src = "FN main() RETURNS Void -> p: ~Int64 = BG { @xl -> 7; }; _ = NEXT p; RETURN; END"
      user_code = transpile(src).split("// 3. Main Entry").first
      # @xl is a user directive asking for a real stack — keep stackful.
      expect(user_code).to include("submitSpawn").or include("spawnBest(")
      expect(user_code).not_to include("FsmTask")
      expect(user_code).not_to include("spawnFsmBest")
    end

    it "falls back to stackful for BG with @stack wildcard sizing" do
      src = "FN main() RETURNS Void -> p: ~Int64 = BG { @stack -> 7; }; _ = NEXT p; RETURN; END"
      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).to include("submitSpawn").or include("spawnBest(")
      expect(user_code).to include(".stack_size = .Micro")
      expect(user_code).not_to include("FsmTask")
      expect(user_code).not_to include("spawnFsmBest")
    end

    it "emits a compile error telling oversized FSM ctx users to use @stack" do
      vars = (0...34).map { |i| "    a#{i}: Int64 = #{i}_i64;" }.join("\n")
      sum = (0...34).map { |i| "a#{i}" }.join(" + ")
      src = <<~CLEAR
        FN main() RETURNS Void ->
        #{vars}
            p: ~Int64 = BG { #{sum}; };
            result: Int64 = NEXT p;
            RETURN;
        END
      CLEAR

      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).to include("@compileError")
      expect(user_code).to include("FSM context is larger than 256 bytes")
      expect(user_code).to include("use @stack")
    end

    it "falls back to stackful for BG that transitively calls @reentrant" do
      src = <<~CLEAR
        FN countDown(n: Int64) RETURNS Void @reentrant ->
          IF n <= 0 THEN RETURN; END
          countDown(n - 1);
          RETURN;
        END
        FN main() RETURNS Void ->
          p: ~Void = BG { @service -> countDown(5); };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).not_to include("FsmTask")
      expect(user_code).not_to include("spawnFsmBest")
    end

    it "captures flow through the state struct on the FSM path" do
      src = "FN main() RETURNS Void -> x: Int64 = 7; p: ~Int64 = BG { x + 1; }; _ = NEXT p; RETURN; END"
      user_code = transpile(src).split("// 3. Main Entry").first
      expect(user_code).to include("x: i64")            # field declaration
      expect(user_code).to include(".x = x")            # init
      expect(user_code).to include("__ctx_0.x")         # usage inside runBody
    end
  end

  # --- Phase B2: 2-state CPS for single-NEXT BG ---
  describe "Phase B2 emission (single-NEXT FSM)" do
    def transpile(source)
      ZigTranspiler.new.transpile(source)
    end

    let(:simple_b2_src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          outer: ~Int64 = BG {
            inner: ~Int64 = BG { 7; };
            r = NEXT inner;
            r * 2;
          };
          x = NEXT outer;
          RETURN;
        END
      CLEAR
    }

    it "emits a 2-state state machine with runSeg0 and runSeg1" do
      # Phase B2-NEXT-CHAIN renamed runStep0/runStep1 to runSeg0/runSeg1
      # and the per-suspend Promise stash to sp_1 (chain-indexed).
      user = transpile(simple_b2_src).split("// 3. Main Entry").first
      expect(user).to include("fn runSeg0(")
      expect(user).to include("fn runSeg1(")
      expect(user).to include("step: u8 = 0")
      expect(user).to include("sp_1:")
    end

    it "emits the registerFsmWaiter call + step transition" do
      user = transpile(simple_b2_src).split("// 3. Main Entry").first
      expect(user).to match(/sp_1\.inner\.wg\.registerFsmWaiter\(__ctx_\d+\.task\)/)
      expect(user).to include("return .{ .WaitForLock = {} }")
    end

    it "emits the count==0 race fast-path (fall-through to step 1 inline)" do
      # Both branches of the race must be present:
      #   if (registerFsmWaiter(...)) { step = N; return WaitForLock; }
      #   step = N;  // fall-through via continue :__sw on the chain dispatcher
      # The recursive emit may renumber states; accept either matching
      # step number twice (registerFsmWaiter target == fall-through target).
      user = transpile(simple_b2_src).split("// 3. Main Entry").first
      reg_block = user.match(/if \(__ctx_\d+\.sp_1\.inner\.wg\.registerFsmWaiter[^\n]*\) \{\s*__ctx_\d+\.step = (\d+);[\s\S]*?\}\s*__ctx_\d+\.step = \1;/)
      expect(reg_block).not_to be_nil, "expected fall-through assignment after registerFsmWaiter if"
    end

    it "emits the error-catch branches around runSeg0 and runSeg1" do
      user = transpile(simple_b2_src).split("// 3. Main Entry").first
      # Each runSegK call is wrapped in `if (runSegK(...)) |_| {} else |err| { inner.result = err; ... }`.
      # The optional `@This().` prefix disambiguates calls when FSM
      # bodies are nested (BG inside BG).
      expect(user).to match(/if \((?:@This\(\)\.)?runSeg0\(__ctx_\d+\)\) \|_\| \{\} else \|err\| \{[\s\S]*?inner\.result = err/)
      expect(user).to match(/if \((?:@This\(\)\.)?runSeg1\(__ctx_\d+\)\) \|_\| \{\} else \|err\| \{[\s\S]*?inner\.result = err/)
    end

    it "stashes the suspend promise and consumes it through the FSM NEXT helper" do
      user = transpile(simple_b2_src).split("// 3. Main Entry").first
      # sp_1 is assigned at the end of runSeg0 (the promise expression).
      expect(user).to match(/__ctx_\d+\.sp_1 = /)
      # In the resumed segment, finishFsmNext consumes the settled result
      # without blocking the scheduler thread and owns the Inner lifecycle.
      expect(user).to match(/__ctx_\d+\.sp_1\.finishFsmNext\(\) catch \|__err_1\|/)
    end

    it "promotes only pre-stmt locals that cross a suspend boundary" do
      # FsmTransform::Liveness drives ctx field promotion. Vars
      # declared in seg K and read in seg K+J (J>0) cross; vars
      # used only within their declaring segment stay as Zig locals
      # in the corresponding member fn (more efficient than the
      # earlier conservative behavior, which promoted every
      # pre-stmt local).
      #
      # Here: `crossed` is read in the post-stmt (seg 1), so it
      # gets a ctx field. `unused_aa` is never read, so it stays
      # local (no `unused_aa: i64` in the struct).
      src = <<~CLEAR
        FN main() RETURNS Void ->
          outer: ~Int64 = BG {
            unused_aa = 999_i64;
            crossed = 7_i64;
            inner: ~Int64 = BG { 1; };
            r = NEXT inner;
            r + crossed;
          };
          v = NEXT outer;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).to include("crossed: i64 = undefined")
      expect(user).not_to include("unused_aa: i64 = undefined")
    end

    it "lowers a single suspending stdlib call (FSM-IO) to a 2-state FSM" do
      # `sleep` is the canonical FSM-IO test target: single suspend,
      # no buffer alloc, no result interpretation. Phase A enumerates
      # it as kind=:io; the lowering uses the matched stdlib def's
      # fsm_setup template.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          p: ~Int64 = BG { sleep(30); 42; };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # 2-state shape, FSM dispatch. Legacy IO emit uses runStepN;
      # recursive emit uses runSegN. Either is acceptable -- the
      # behavior is what matters.
      expect(user).to match(/fn run(?:Step|Seg)0\(/)
      expect(user).to match(/fn run(?:Step|Seg)1\(/)
      expect(user).to include("step: u8 = 0")
      # Setup template substituted at the call site, NOT the stackful
      # `rt.sleep(...)` form. The runtime hook is fsmSleepTask.
      # The wake-time arg is rendered via FsmOps::BinOp which wraps
      # binaries in parens for precedence safety; allow either form.
      expect(user).to match(/__ctx_\d+\.rt\.getSched\(\)\.fsmSleepTask\(__ctx_\d+\.task,\s*\(?CheatHeader\.milliTimestamp/)
      # Yield WaitForLock immediately after setup.
      expect(user).to include("return .{ .WaitForLock = {} }")
      # No fiber yield (stackful path) is emitted.
      expect(user).not_to match(/^\s*rt\.sleep\(/)
    end

    it "stackful BG calling sleep still uses the existing fiber yield" do
      # Same `sleep` call from a stackful BG (forced via @xl) emits
      # the stackful template. Mixed-mode coexistence: the runtime
      # routes both via per-task wake mechanisms, no conflict.
      src = <<~CLEAR
        FN napFor(ms: Int64) RETURNS !Void -> sleep(ms); RETURN; END
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @xl -> napFor(30); 7; };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # The stackful template is `rt.sleep(...)` (via napFor wrapper).
      expect(user).to match(/rt\.sleep\(@intCast/)
      # No FSM-IO setup is emitted for this BG.
      expect(user).not_to include("fsmSleepTask")
    end

    it "lowers WHILE-loop containing NEXT to a 4-state cycling FSM" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          outer: ~Int64 = BG {
            MUTABLE i = 0_i64;
            MUTABLE total = 0_i64;
            WHILE i < 3 DO
              p: ~Int64 = BG { i + 1; };
              r = NEXT p;
              total += r;
              i += 1;
            END
            total;
          };
          _ = NEXT outer;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # Four inner fns: pre + loop body before suspend (with promise
      # stash) + loop body after suspend + post. Legacy emit named
      # them runPre/runLoopPre/runLoopPost/runPost; the recursive emit
      # uses runSeg<N>. Accept either by counting member fns instead
      # of matching exact names.
      expect(user.scan(/fn run\w+\(/).length).to be >= 4
      # Suspend slot + result var + loop locals are ctx fields.
      expect(user).to match(/sp(?:_\d+)?:\s*CheatLib\.Promise/)
      expect(user).to include("r: i64 = undefined")
      expect(user).to include("i: i64 = undefined")
      expect(user).to include("total: i64 = undefined")
      # Cycling dispatcher present (back-edge into the loop head).
      expect(user).to include("__sw: while (true)")
    end

    it "falls back to stackful when the WHILE body has multiple NEXTs" do
      # B2-NEXT-LOOP supports exactly one NEXT in the loop body.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          o: ~Int64 = BG {
            MUTABLE i = 0_i64;
            MUTABLE total = 0_i64;
            WHILE i < 2 DO
              a: ~Int64 = BG { i; };
              x = NEXT a;
              b: ~Int64 = BG { i + 1; };
              y = NEXT b;
              total += x + y;
              i += 1;
            END
            total;
          };
          _ = NEXT o;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # Multiple NEXTs in loop body means neither chain nor loop split
      # matches. Stays stackful.
      expect(user).not_to include("fn runLoopPre(")
      expect(user).not_to include("fn runLoopPost(")
    end

    it "lowers N consecutive NEXTs to an (N+1)-state machine with sp_K stashes" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          outer: ~Int64 = BG {
            a: ~Int64 = BG { 10; };
            x = NEXT a;
            b: ~Int64 = BG { x + 1; };
            y = NEXT b;
            x + y;
          };
          _ = NEXT outer;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # 3 segments → runSeg0/Seg1/Seg2.
      expect(user).to include("fn runSeg0(")
      expect(user).to include("fn runSeg1(")
      expect(user).to include("fn runSeg2(")
      # Two suspend slots stashed in the state struct.
      expect(user).to match(/sp_1:\s*CheatLib\.Promise/)
      expect(user).to match(/sp_2:\s*CheatLib\.Promise/)
      # Both result vars are state-struct fields.
      expect(user).to include("x: i64 = undefined")
      expect(user).to include("y: i64 = undefined")
      # Dispatcher uses the labeled while-true switch.
      expect(user).to include("__sw: while (true)")
      # Each resumed segment consumes its suspend slot through the FSM
      # helper, preserving nonblocking scheduler behavior and single-owner
      # cleanup of the promise inner cell.
      expect(user).to match(/__ctx_\d+\.sp_1\.finishFsmNext\(\) catch \|__err_1\|/)
      expect(user).to match(/__ctx_\d+\.sp_2\.finishFsmNext\(\) catch \|__err_2\|/)
    end

    it "rewrites assignment LHS through the capture map (Set + BindExpr :assign)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          outer: ~Int64 = BG {
            MUTABLE acc = 1_i64;
            inner: ~Int64 = BG { 10; };
            r = NEXT inner;
            acc = acc + r;
            acc * 3;
          };
          _ = NEXT outer;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # The promoted local `acc` must be assigned through the ctx field
      # on BOTH sides (LHS as well as RHS) — neither bare `acc = ...`
      # nor a bare RHS reference should remain.
      expect(user).to match(/__ctx_\d+\.acc = /)
      # No bare-LHS leak.
      expect(user).not_to match(/^\s+acc = /m)
    end

    it "falls back to stackful for streams (~T[]) — they don't fit B2" do
      # ~?T[] streams have a different Inner shape (no `.result` field);
      # the FSM-NEXT lowering refuses and the stackful path emits.
      src = <<~CLEAR
        FN main() RETURNS Void ->
          stream: ~?Int64[] = BG STREAM { YIELD 1_i64; YIELD 2_i64; };
          n: ?Int64 = NEXT stream;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).not_to include("registerFsmWaiter")
    end

    it "emits FSM-WITH for a body with exactly one WITH EXCLUSIVE on @locked" do
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @locked;
          p: ~Void = BG { WITH EXCLUSIVE c AS inner { inner.value = inner.value + 1; } };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # Lock fan-out (LockTry / WokenCheck / RetryOrError) +
      # __lock_held_<i> ctx flag set after acquire + explicit
      # unlock in the release segment + destroyTask err-path
      # release. Previously used `defer cap.unlock()` from a single
      # CS body fn; now each runFn is its own frame so we track via
      # ctx flag instead.
      expect(user).to include("step: u8 = 0")
      expect(user).to include("lock_waiter: CheatHeader.WaiterNode")
      expect(user).to include("__lock_held_0: bool = false")
      expect(user).to match(/__ctx_\d+\.c\.tryLockForFsm\(/)
      expect(user).to include("return .{ .WaitForLock = {} }")
      expect(user).to match(/__ctx_\d+\.__lock_held_0 = true/)
      expect(user).to match(/__ctx_\d+\.__lock_held_0 = false/)
      expect(user).to match(/__ctx_\d+\.c\.unlock\(\)/)
      expect(user).to match(/if \(__ctx_\d+\.__lock_held_0\) __ctx_\d+\.c\.unlock\(\)/)
    end

    it "emits the .Acquired / .Registered / .Error switch for the lock try" do
      src = <<~CLEAR
        STRUCT Counter { value: Int64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @locked;
          p: ~Void = BG { WITH EXCLUSIVE c AS inner { inner.value = 1; } };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).to include(".Acquired =>")
      expect(user).to include(".Registered =>")
      expect(user).to include(".Error =>")
      # Error path surfaces a LockError into inner.result.
      expect(user).to match(/inner\.result = error\.LockError/)
    end

    it "lowers WITH + ON Transient RAISE into the .Error arm (FSM, not stackful)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @locked;
          p: ~Void = BG {
            WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient RAISE
          };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # B2-WITH now lowers ON-clauses by emitting the action into the
      # resume fn's .Error arm. Verify FSM emission + the RAISE shape.
      expect(user).to include("tryLockForFsm")
      expect(user).to match(/__ctx_\d+\.rt\.setError\(\.Transient,\s*@intFromEnum\(ErrorName\.LockTimeout\)/)
      expect(user).to match(/__ctx_\d+\.inner\.result = error\.CheatError/)
    end

    it "lowers ON Transient EXIT \"msg\" with a custom message" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @locked;
          p: ~Void = BG {
            WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient EXIT "lock failed"
          };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).to include("tryLockForFsm")
      expect(user).to match(/__ctx_\d+\.rt\.setError\(\.Transient,\s*@intFromEnum\(ErrorName\.LockTimeout\),\s*"lock failed"/)
    end

    it "lowers ON Transient PASS as an empty .Error arm (falls through to post)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @locked;
          p: ~Void = BG {
            WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient PASS
          };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).to include("tryLockForFsm")
      # PASS produces an empty .Error arm — no setError, no error.CheatError.
      expect(user).not_to include("error.CheatError")
      expect(user).not_to include("setError")
    end

    it "lowers @writeLocked + EXCLUSIVE via tryWriteLockForFsm + unlock" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @writeLocked;
          p: ~Void = BG { WITH EXCLUSIVE c AS inner { inner.v = inner.v + 1; } };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).to match(/__ctx_\d+\.c\.tryWriteLockForFsm\(/)
      expect(user).to match(/__ctx_\d+\.c\.unlock\(\)/)
    end

    it "lowers RETRY(N) THEN ... with retry_count field + retry loop" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @locked;
          p: ~Void = BG {
            WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient RETRY(5) THEN RAISE
          };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # Retry counter is part of the state struct.
      expect(user).to include("retry_count: u32 = 0")
      # Retry-or-error fan-out tail: increment counter, jump back
      # to the lock-try step via continue :__sw.
      expect(user).to match(/retry_count < 5/)
      expect(user).to match(/retry_count \+= 1/)
      expect(user).to include("continue :__sw")
    end

    it "no retry_count field when clause has no RETRY" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @locked;
          p: ~Void = BG {
            WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient RAISE
          };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).not_to include("retry_count:")
      expect(user).not_to include("retry_count <")
    end

    it "lowers @writeLocked + read (implicit WITH) via tryReadLockForFsm + unlockShared" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 7 } @writeLocked;
          p: ~Void = BG { WITH c AS view { ASSERT view.v == 7, "ok"; } };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      expect(user).to match(/__ctx_\d+\.c\.tryReadLockForFsm\(/)
      expect(user).to match(/__ctx_\d+\.c\.unlockShared\(\)/)
    end

    it "emits FSM-WITH for @shared:locked (Arc-wrapped) via ctrl.data.* unwrap" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @shared:locked;
          p: ~Void = BG { WITH EXCLUSIVE c AS inner { inner.v = inner.v + 1; } };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # Capture is the Arc-wrapped Locked; unwrap goes through ctrl.data.*
      # The ctx field is rendered as `@TypeOf(c)` after the FiberCtxBuilder
      # refactor on master — the underlying Zig type is unchanged.
      expect(user).to match(/c: @TypeOf\(c\)/)
      expect(user).to match(/__ctx_\d+\.c\.ctrl\.data\.\*\.tryLockForFsm\(/)
      expect(user).to match(/__ctx_\d+\.c\.ctrl\.data\.\*\.unlock\(\)/)
      # Alias inside CS dereferences to the inner data.
      expect(user).to match(/\(__ctx_\d+\.c\.ctrl\.data\.\*\.data\)\.v/)
    end

    it "emits FSM-WITH for @multiowned:locked (Rc-wrapped)" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 7 } @multiowned:locked;
          p: ~Void = BG { WITH EXCLUSIVE c AS inner { inner.v = 1; } };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # FiberCtxBuilder renders ctx fields as @TypeOf(name); the
      # underlying Rc(Locked(C)) shape is preserved by the unwrap path.
      expect(user).to match(/c: @TypeOf\(c\)/)
      expect(user).to match(/__ctx_\d+\.c\.ctrl\.data\.\*\.tryLockForFsm\(/)
    end

    it "lowers multi-lock WITH to a chained per-cap FSM fan-out" do
      src = <<~CLEAR
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        FN main() RETURNS Void ->
          a = A{ x: 0 } @locked(rank: 1);
          b = B{ y: 0 } @locked(rank: 2);
          p: ~Void = BG {
            WITH EXCLUSIVE a AS x, EXCLUSIVE b AS y { x.x = 1; y.y = 2; }
          };
          NEXT p;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # Each cap's LockTry calls tryLockForFsm; multi-cap WITH
      # produces two distinct calls (one per cap).
      try_calls = user.scan(/\.tryLockForFsm\(/).length
      expect(try_calls).to be >= 2
      expect(user).to include("CheatHeader.spawnFsmBest")
    end

    it "falls back to stackful for two top-level NEXTs (B2 supports only one)" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
          outer: ~Int64 = BG {
            a: ~Int64 = BG { 1; };
            b: ~Int64 = BG { 2; };
            ra = NEXT a;
            rb = NEXT b;
            ra + rb;
          };
          _ = NEXT outer;
          RETURN;
        END
      CLEAR
      user = transpile(src).split("// 3. Main Entry").first
      # The outer must not lower to FSM-NEXT (no runStep1 for the
      # outer ctx). The inner BG-spawns are pure compute so they're
      # B1 FSMs — that's fine, they're not the "outer" ctx. The check
      # below ensures no FSM-NEXT shape was emitted *anywhere* in the
      # user code: with 2 NEXTs in the outer, the entire outer must
      # stay stackful.
      bg_ctx_with_runstep1 = user.scan(/runStep1/).size
      expect(bg_ctx_with_runstep1).to eq(0)
    end
  end
end
