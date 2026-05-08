require "rspec"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../src/tools/stack_verifier"

# Most expectations drive a real StackVerifier with canned objdump
# output (no Zig build needed) -- this contributes coverage for
# src/tools/stack_verifier.rb to the unit suite.
#
# A small ":integration" describe at the bottom builds ONE real
# binary in before(:all) and runs the live objdump pipeline against
# it. That single shared build catches upstream objdump-format drift
# that would silently invalidate the canned fixtures above; we don't
# need a fresh build per expectation.

RSpec.describe StackVerifier do
  PREFIX = "._clear_tmp_test"

  # Two functions, frame sizes 0x80 and 0x40, where main calls compute,
  # plus one BG entry function (___BgCtx0.run) calling compute.
  BASIC_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162520 <#{PREFIX}.clearMain>:
     1162520:\t48 81 ec 80 00 00 00 \tsub    $0x80,%rsp
     1162527:\te8 d4 00 00 00       \tcall   1162600 <#{PREFIX}.compute>
     116252c:\t48 81 c4 80 00 00 00 \tadd    $0x80,%rsp

    0000000001162600 <#{PREFIX}.compute>:
     1162600:\t48 81 ec 40 00 00 00 \tsub    $0x40,%rsp
     1162607:\t48 81 c4 40 00 00 00 \tadd    $0x40,%rsp

    0000000001162700 <#{PREFIX}.clearMain.__BgCtx0.run>:
     1162700:\t48 81 ec 60 00 00 00 \tsub    $0x60,%rsp
     1162707:\te8 f4 fe ff ff       \tcall   1162600 <#{PREFIX}.compute>
     116270c:\t48 81 c4 60 00 00 00 \tadd    $0x60,%rsp
  OBJ

  # Heavy frame (0x8000 = 32768 bytes) overflows the standard tier
  # budget (16384 - 4096 = 12288). Drives the overflow path in #analyze.
  HEAVY_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162520 <#{PREFIX}.clearMain>:
     1162520:\t48 81 ec 80 00 00 00 \tsub    $0x80,%rsp

    0000000001162700 <#{PREFIX}.heavy>:
     1162700:\t48 81 ec 00 80 00 00 \tsub    $0x8000,%rsp
  OBJ

  # Frame 0x2800 = 10240 bytes -- between 75% and 100% of the standard
  # tier budget (12288). Drives the "near limit" :warn path in #analyze.
  WARN_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162520 <#{PREFIX}.busy>:
     1162520:\t48 81 ec 00 28 00 00 \tsub    $0x2800,%rsp
  OBJ

  # clearMain calls coopYield (a leaf pattern) which calls deepCallee.
  # If deepest_path_cost honours LEAF_PATTERNS, deepCallee's 0x4000
  # frame is excluded from the cost; if it doesn't, it'd be included
  # and the result would be way bigger.
  LEAF_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162520 <#{PREFIX}.clearMain>:
     1162520:\t48 81 ec 80 00 00 00 \tsub    $0x80,%rsp
     1162527:\te8 d4 00 00 00       \tcall   1162600 <#{PREFIX}.Scheduler.coopYield>

    0000000001162600 <#{PREFIX}.Scheduler.coopYield>:
     1162600:\t48 81 ec 00 01 00 00 \tsub    $0x100,%rsp
     1162607:\te8 f4 00 00 00       \tcall   1162700 <#{PREFIX}.deepCallee>

    0000000001162700 <#{PREFIX}.deepCallee>:
     1162700:\t48 81 ec 00 40 00 00 \tsub    $0x4000,%rsp
  OBJ

  # fact uses jmp <self> (TCO'd); factNotTco uses call <self>.
  TAILCALL_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162600 <#{PREFIX}.fact>:
     1162600:\t48 81 ec 40 00 00 00 \tsub    $0x40,%rsp
     1162607:\te9 f4 ff ff ff       \tjmp    1162600 <#{PREFIX}.fact>

    0000000001162700 <#{PREFIX}.factNotTco>:
     1162700:\t48 81 ec 40 00 00 00 \tsub    $0x40,%rsp
     1162707:\te8 f4 ff ff ff       \tcall   1162700 <#{PREFIX}.factNotTco>
  OBJ

  # Recursive self-call: drives the cycle/in_stack short-circuit in
  # deepest_path_cost. Without the cycle guard, the DFS would loop.
  RECURSIVE_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162520 <#{PREFIX}.clearMain>:
     1162520:\t48 81 ec 80 00 00 00 \tsub    $0x80,%rsp
     1162527:\te8 d4 00 00 00       \tcall   1162520 <#{PREFIX}.clearMain>
  OBJ

  # Two callees of clearMain, both eventually call `shared`; the second
  # visit to `shared` should hit the memoization short-circuit. Also
  # routeA's path beats routeB's, exercising the "smaller cost is NOT
  # the new max" branch in deepest_path_cost.
  SHARED_CALLEE_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162520 <#{PREFIX}.clearMain>:
     1162520:\t48 81 ec 80 00 00 00 \tsub    $0x80,%rsp
     1162527:\te8 d4 00 00 00       \tcall   1162600 <#{PREFIX}.routeA>
     116252c:\te8 cf 01 00 00       \tcall   1162700 <#{PREFIX}.routeB>

    0000000001162600 <#{PREFIX}.routeA>:
     1162600:\t48 81 ec 00 02 00 00 \tsub    $0x200,%rsp
     1162607:\te8 f4 00 00 00       \tcall   1162800 <#{PREFIX}.shared>

    0000000001162700 <#{PREFIX}.routeB>:
     1162700:\t48 81 ec 00 01 00 00 \tsub    $0x100,%rsp
     1162707:\te8 f4 00 00 00       \tcall   1162800 <#{PREFIX}.shared>

    0000000001162800 <#{PREFIX}.shared>:
     1162800:\t48 81 ec 40 00 00 00 \tsub    $0x40,%rsp
  OBJ

  # Tail-call function followed by a non-prefix function (libc / linker
  # symbol). Forces the "non-prefix function header ends prev block"
  # branch in verify_tail_calls (lines 173-180 of stack_verifier.rb).
  TAILCALL_THEN_LIBC_OBJDUMP = <<~OBJ
    test_bin:     file format elf64-x86-64

    Disassembly of section .text:

    0000000001162600 <#{PREFIX}.fact>:
     1162600:\t48 81 ec 40 00 00 00 \tsub    $0x40,%rsp
     1162607:\te9 f4 ff ff ff       \tjmp    1162600 <#{PREFIX}.fact>

    00000000004021c0 <__libc_csu_init>:
     4021c0:\t48 89 5c 24 e8       \tmov    %rbx,-0x18(%rsp)
     4021c5:\t48 89 6c 24 f0       \tmov    %rbp,-0x10(%rsp)
  OBJ

  FnDouble = Struct.new(
    :stack_tier, :stack_vars_bytes, :line,
    :max_depth_n, :reentrance_kind, :tail_call,
    keyword_init: true
  )

  def stub_verifier(objdump_string, prefix: PREFIX)
    v = StackVerifier.new("/dev/null", prefix)
    v.instance_variable_set(:@objdump_output, objdump_string)
    v
  end

  describe "#extract_frame_sizes" do
    it "parses sub $0xN,%rsp instructions into per-fn frame entries" do
      v = stub_verifier(BASIC_OBJDUMP)
      frames = v.extract_frame_sizes

      names = frames.map { |f| f[:name] }
      expect(names).to include("main", "compute", "clearMain.__BgCtx0.run")

      main = frames.find { |f| f[:name] == "main" }
      expect(main[:stack_bytes]).to eq(0x80)

      compute = frames.find { |f| f[:name] == "compute" }
      expect(compute[:stack_bytes]).to eq(0x40)
    end

    it "returns [] when objdump output is empty" do
      expect(stub_verifier("").extract_frame_sizes).to eq([])
    end

    it "ignores functions whose name doesn't start with the module prefix" do
      output = BASIC_OBJDUMP + <<~EXTRA

        0000000001162900 <some_other_module.foo>:
         1162900:\t48 81 ec aa 00 00 00 \tsub    $0xaa,%rsp
      EXTRA
      frames = stub_verifier(output).extract_frame_sizes
      expect(frames.map { |f| f[:name] }).not_to include("some_other_module.foo")
    end
  end

  describe "#analyze" do
    it "cross-references frame sizes with fn_nodes' tier metadata" do
      v = stub_verifier(BASIC_OBJDUMP)
      fn_nodes = {
        "main"    => FnDouble.new(stack_tier: :standard, stack_vars_bytes: 0, line: 1),
        "compute" => FnDouble.new(stack_tier: :standard, stack_vars_bytes: 0, line: 5),
      }
      report = v.analyze(fn_nodes: fn_nodes)

      compute = report[:functions].find { |f| f[:name] == "compute" }
      expect(compute[:tier]).to eq(:standard)
      expect(compute[:budget]).to eq(StackVerifier::TIER_BUDGET[:standard])
    end

    it "emits an :error warning when frame exceeds tier budget" do
      v = stub_verifier(HEAVY_OBJDUMP)
      fn_nodes = {
        "main"  => FnDouble.new(stack_tier: :standard, stack_vars_bytes: 0, line: 1),
        "heavy" => FnDouble.new(stack_tier: :standard, stack_vars_bytes: 0, line: 5),
      }
      report = v.analyze(fn_nodes: fn_nodes)

      heavy = report[:functions].find { |f| f[:name] == "heavy" }
      expect(heavy[:overflow]).to be true
      expect(report[:warnings].any? { |w| w[:level] == :error }).to be true
      expect(v.has_errors?(report)).to be true
    end

    it "emits an :info warning for :unbounded functions" do
      v = stub_verifier(BASIC_OBJDUMP)
      fn_nodes = {
        "compute" => FnDouble.new(stack_tier: :unbounded, stack_vars_bytes: 0, line: 5),
      }
      report = v.analyze(fn_nodes: fn_nodes)

      info = report[:warnings].find { |w| w[:level] == :info }
      expect(info).not_to be_nil
      expect(info[:message]).to include("compute")
      expect(info[:message]).to include("unbounded")
    end

    it "marks unknown functions with tier :unknown" do
      v = stub_verifier(BASIC_OBJDUMP)
      report = v.analyze(fn_nodes: {})

      report[:functions].each { |f| expect(f[:tier]).to eq(:unknown) }
    end

    it "sorts functions by descending stack_bytes" do
      v = stub_verifier(BASIC_OBJDUMP)
      report = v.analyze(fn_nodes: {})
      bytes = report[:functions].map { |f| f[:stack_bytes] }
      expect(bytes).to eq(bytes.sort.reverse)
    end

    it "emits a :warn level when frame is over 75% of budget but under 100%" do
      v = stub_verifier(WARN_OBJDUMP)
      fn_nodes = {
        "busy" => FnDouble.new(stack_tier: :standard, stack_vars_bytes: 0, line: 5),
      }
      report = v.analyze(fn_nodes: fn_nodes)

      busy = report[:functions].find { |f| f[:name] == "busy" }
      expect(busy[:overflow]).to be_falsey
      warn = report[:warnings].find { |w| w[:level] == :warn }
      expect(warn).not_to be_nil
      expect(warn[:message]).to include("busy")
      expect(warn[:message]).to include("budget")
    end

    it "format_location includes file:line when source_file is passed" do
      v = stub_verifier(HEAVY_OBJDUMP)
      fn_nodes = {
        "main"  => FnDouble.new(stack_tier: :standard, stack_vars_bytes: 0, line: 1),
        "heavy" => FnDouble.new(stack_tier: :standard, stack_vars_bytes: 0, line: 42),
      }
      report = v.analyze(fn_nodes: fn_nodes, source_file: "/some/path/test.cht")
      err = report[:warnings].find { |w| w[:level] == :error }
      expect(err[:message]).to include("(test.cht:42)")
    end

    it "treats fn_nodes as empty when nil (covers `&.` nil branch)" do
      v = stub_verifier(BASIC_OBJDUMP)
      report = v.analyze(fn_nodes: nil)
      report[:functions].each { |f| expect(f[:tier]).to eq(:unknown) }
    end

    it "tolerates fn_nodes whose values do not respond to :line" do
      v = stub_verifier(BASIC_OBJDUMP)
      lineless = Struct.new(:stack_tier, :stack_vars_bytes, keyword_init: true)
      report = v.analyze(fn_nodes: { "main" => lineless.new(stack_tier: :standard, stack_vars_bytes: 0) })
      main = report[:functions].find { |f| f[:name] == "main" }
      expect(main[:line]).to be_nil
    end

  end

  describe "#has_errors?" do
    let(:v) { stub_verifier("") }

    it "returns true when an :error-level warning is present" do
      expect(v.has_errors?(warnings: [{ level: :error, message: "x" }])).to be_truthy
    end

    it "returns false when warnings is nil (covers `&.` nil branch)" do
      expect(v.has_errors?({})).to be_falsey
    end

    it "returns false when warnings has no :error entries" do
      expect(v.has_errors?(warnings: [{ level: :warn, message: "x" }])).to be_falsey
    end
  end

  describe "#print_report" do
    let(:v) { stub_verifier("") }
    let(:io) { StringIO.new }

    it "prints function lines including [tier], (usage_pct%), and overflow / unbounded markers" do
      report = {
        functions: [
          { name: "heavy",     stack_bytes: 0x8000, tier: :standard, usage_pct: 266.7, budget: 12288, overflow: true },
          { name: "ok",        stack_bytes: 0x80,   tier: :standard, usage_pct: 1.0,   budget: 12288 },
          { name: "unbounded", stack_bytes: 0x100,  tier: :unbounded, unbounded: true },
          { name: "anon",      stack_bytes: 0x40,   tier: :unknown },
        ],
        warnings: []
      }
      v.print_report(report, io: io)
      out = io.string
      expect(out).to include("heavy")
      expect(out).to include("[standard]")
      expect(out).to include("(266.7%)")
      expect(out).to include("<<<")                          # overflow marker
      expect(out).to include("(per frame, depth unknown)")   # unbounded marker
      expect(out).not_to include("[unknown]")                # known-tier suffix only
    end

    it "prints warnings with one ANSI color code per level" do
      report = {
        functions: [{ name: "x", stack_bytes: 1, tier: :standard, usage_pct: 0.0 }],
        warnings: [
          { level: :error, message: "boom" },
          { level: :warn,  message: "careful" },
          { level: :info,  message: "hint" },
        ]
      }
      v.print_report(report, io: io)
      out = io.string
      expect(out).to include("\e[31m[stack error]\e[0m boom")
      expect(out).to include("\e[33m[stack warning]\e[0m careful")
      expect(out).to include("\e[36m[stack info]\e[0m hint")
    end

    it "is silent when there are no functions" do
      v.print_report({ functions: [], warnings: [] }, io: io)
      expect(io.string).to eq("")
    end

    it "ignores warnings whose :level is unrecognised" do
      report = {
        functions: [{ name: "x", stack_bytes: 1, tier: :standard, usage_pct: 0.0 }],
        warnings: [{ level: :unknown_level, message: "should not appear" }],
      }
      v.print_report(report, io: io)
      expect(io.string).not_to include("should not appear")
    end
  end

  describe "#cost_to_tier" do
    let(:v) { stub_verifier("") }

    it "maps bytes <= 4096 to :micro" do
      expect(v.cost_to_tier(0)).to eq(:micro)
      expect(v.cost_to_tier(4096)).to eq(:micro)
    end

    it "maps bytes <= standard budget to :standard" do
      expect(v.cost_to_tier(4097)).to eq(:standard)
      expect(v.cost_to_tier(16384 - 4096)).to eq(:standard)
    end

    it "maps bytes <= large budget to :large" do
      expect(v.cost_to_tier(16384 - 4096 + 1)).to eq(:large)
      expect(v.cost_to_tier(65536 - 4096)).to eq(:large)
    end

    it "maps bytes > large budget to :xl" do
      expect(v.cost_to_tier(65536 - 4096 + 1)).to eq(:xl)
      expect(v.cost_to_tier(200_000)).to eq(:xl)
    end
  end

  describe "#extract_full_call_graph" do
    it "builds frame_sizes, call_graph, fn_names from objdump" do
      v = stub_verifier(BASIC_OBJDUMP)
      g = v.extract_full_call_graph

      expect(g[:fn_names].values).to include("#{PREFIX}.clearMain", "#{PREFIX}.compute")

      main_addr    = g[:fn_addrs]["#{PREFIX}.clearMain"]
      compute_addr = g[:fn_addrs]["#{PREFIX}.compute"]

      expect(g[:frame_sizes][main_addr]).to eq(0x80)
      expect(g[:frame_sizes][compute_addr]).to eq(0x40)

      expect(g[:call_graph][main_addr]).to include(compute_addr)
    end

    it "identifies BG entries by __BgCtxN.run suffix" do
      v = stub_verifier(BASIC_OBJDUMP)
      g = v.extract_full_call_graph
      expect(g[:bg_entries].length).to eq(1)
      expect(g[:fn_names][g[:bg_entries].first]).to include("__BgCtx0.run")
    end

    it "returns nil when objdump output is empty" do
      expect(stub_verifier("").extract_full_call_graph).to be_nil
    end
  end

  describe "#compute_main_optimal_tier" do
    it "returns entry_name + path_cost + tier for clearMain" do
      v = stub_verifier(BASIC_OBJDUMP)
      r = v.compute_main_optimal_tier
      expect(r[:entry_name]).to include("clearMain")
      # main(0x80) + compute(0x40) along the deepest fiber-stack path.
      expect(r[:path_cost]).to eq(0x80 + 0x40)
      expect(r[:optimal_tier]).to eq(:micro)
    end

    it "returns nil when there's no clearMain function" do
      no_main = BASIC_OBJDUMP.sub(/clearMain/, "notMain")
      expect(stub_verifier(no_main).compute_main_optimal_tier).to be_nil
    end

    it "stops at LEAF_PATTERNS (e.g. Scheduler.coopYield) -- callees beyond don't count" do
      # clearMain(0x80) -> coopYield(0x100) [LEAF, stops here] -> deepCallee(0x4000, NOT counted).
      v = stub_verifier(LEAF_OBJDUMP)
      r = v.compute_main_optimal_tier
      expect(r[:path_cost]).to eq(0x80 + 0x100)  # NOT 0x80 + 0x100 + 0x4000
      expect(r[:optimal_tier]).to eq(:micro)
    end

    it "returns nil when objdump output is empty (graph_data is nil)" do
      expect(stub_verifier("").compute_main_optimal_tier).to be_nil
    end

    it "short-circuits self-recursion via the in_stack cycle check" do
      # clearMain calls itself. Without the in_stack check, DFS would
      # loop. With it, the recursive edge contributes 0, so path cost
      # is just clearMain's own frame.
      v = stub_verifier(RECURSIVE_OBJDUMP)
      r = v.compute_main_optimal_tier
      expect(r[:path_cost]).to eq(0x80)
    end

    it "memoizes shared callees and picks the deepest path among siblings" do
      # clearMain(0x80) calls routeA(0x200) and routeB(0x100); both call
      # shared(0x40). Deepest path: clearMain -> routeA -> shared = 0x80+0x200+0x40 = 0x2C0.
      # routeB's path = 0x80 + 0x100 + 0x40 = 0x1C0 (smaller, must NOT win).
      # On the second visit, `shared` is memoized -- exercises the memo-hit branch.
      v = stub_verifier(SHARED_CALLEE_OBJDUMP)
      r = v.compute_main_optimal_tier
      expect(r[:path_cost]).to eq(0x80 + 0x200 + 0x40)
    end
  end

  describe "#compute_optimal_tiers" do
    it "returns one entry per BG block, sorted by bg_index" do
      v = stub_verifier(BASIC_OBJDUMP)
      tiers = v.compute_optimal_tiers
      expect(tiers.length).to eq(1)
      first = tiers.first
      expect(first[:bg_index]).to eq(0)
      # BG ctx run(0x60) + compute(0x40).
      expect(first[:path_cost]).to eq(0x60 + 0x40)
      expect(first[:optimal_tier]).to eq(:micro)
    end

    it "returns [] when binary has no BG blocks" do
      no_bg = BASIC_OBJDUMP.sub(/0000000001162700.*\z/m, "")
      expect(stub_verifier(no_bg).compute_optimal_tiers).to eq([])
    end

    it "returns [] when objdump output is empty (graph_data is nil)" do
      expect(stub_verifier("").compute_optimal_tiers).to eq([])
    end

    it "skips spoofed bg_entries whose name doesn't match the __BgCtxN.run regex" do
      # extract_full_call_graph only enrolls names matching `__BgCtxN.run$`,
      # so the defensive re-check inside compute_optimal_tiers is unreachable
      # in practice. Stub the graph to force the path: belt-and-suspenders
      # behaviour gets exercised so future refactors that loosen
      # extract_full_call_graph don't silently produce garbage tier output.
      v = stub_verifier("")
      fake_graph = {
        frame_sizes: { "1162520" => 0x100 },
        call_graph:  { "1162520" => Set.new },
        fn_names:    { "1162520" => "#{PREFIX}.notABgCtx" },
        fn_addrs:    { "#{PREFIX}.notABgCtx" => "1162520" },
        bg_entries:  ["1162520"],   # spoof -- name doesn't actually match
      }
      allow(v).to receive(:extract_full_call_graph).and_return(fake_graph)
      expect(v.compute_optimal_tiers).to eq([])
    end
  end

  describe "#verify_tail_calls" do
    it "marks tail-call fns as TCO-verified iff no `call <self>` is present" do
      v = stub_verifier(TAILCALL_OBJDUMP)
      fn_nodes = {
        "fact"       => FnDouble.new(tail_call: true),
        "factNotTco" => FnDouble.new(tail_call: true),
      }
      results = v.verify_tail_calls(fn_nodes)

      fact = results.find { |r| r[:name] == "fact" }
      expect(fact[:tco_verified]).to be true
      expect(fact[:has_self_call]).to be false

      bad = results.find { |r| r[:name] == "factNotTco" }
      expect(bad[:tco_verified]).to be false
      expect(bad[:has_self_call]).to be true
    end

    it "ignores fns whose tail_call attribute is not set" do
      v = stub_verifier(TAILCALL_OBJDUMP)
      results = v.verify_tail_calls({}) # nothing flagged
      expect(results).to eq([])
    end

    it "ends a prefix-fn block when a non-prefix function header follows" do
      # libc / linker symbols (e.g. __libc_csu_init) appear in objdump output
      # without our module prefix. The non-prefix `elsif` branch must finalize
      # the prefix tail-call function it was tracking.
      v = stub_verifier(TAILCALL_THEN_LIBC_OBJDUMP)
      fn_nodes = { "fact" => FnDouble.new(tail_call: true) }
      results = v.verify_tail_calls(fn_nodes)

      expect(results.length).to eq(1)
      expect(results.first[:name]).to eq("fact")
      expect(results.first[:tco_verified]).to be true
    end

    it "skips finalisation when the prev prefix fn is not in tail_call_fns" do
      # "fact" is a prefix fn but only "someUnrelated" is flagged tail-call.
      # When the libc header arrives, the inside-elsif `if` is false and
      # nothing is appended -- exercises the else branch on that `if`.
      v = stub_verifier(TAILCALL_THEN_LIBC_OBJDUMP)
      fn_nodes = { "someUnrelated" => FnDouble.new(tail_call: true) }
      expect(v.verify_tail_calls(fn_nodes)).to eq([])
    end

    it "returns [] when objdump output is empty" do
      v = stub_verifier("")
      results = v.verify_tail_calls({ "fact" => FnDouble.new(tail_call: true) })
      expect(results).to eq([])
    end
  end

  describe "#print_tier_report" do
    let(:v) { stub_verifier("") }
    let(:io) { StringIO.new }

    it "prints one line per BG entry with index, path_cost, tier" do
      results = [
        { bg_index: 0, entry_name: "x", path_cost: 4096,  optimal_tier: :micro },
        { bg_index: 1, entry_name: "y", path_cost: 12000, optimal_tier: :standard },
      ]
      v.print_tier_report(results, io: io)
      out = io.string
      expect(out).to include("Exact stack analysis")
      expect(out).to include("BG#0:")
      expect(out).to include("4096 bytes -> MICRO")
      expect(out).to include("BG#1:")
      expect(out).to include("12000 bytes -> STANDARD")
    end

    it "is silent when there are no results" do
      v.print_tier_report([], io: io)
      expect(io.string).to eq("")
    end
  end

  describe "#detect_prefix (private, via initialize)" do
    it "auto-derives module_prefix from binary basename when no prefix given" do
      v = StackVerifier.new("/tmp/foo.bin")
      expect(v.module_prefix).to eq("._clear_tmp_foo")
    end

    it "strips trailing extensions" do
      v = StackVerifier.new("/some/dir/program.exe")
      expect(v.module_prefix).to eq("._clear_tmp_program")
    end

    it "respects an explicit prefix when given" do
      v = StackVerifier.new("/tmp/foo.bin", "._explicit_prefix")
      expect(v.module_prefix).to eq("._explicit_prefix")
    end
  end

  describe "#format_location (private)" do
    let(:v) { stub_verifier("") }

    it "returns '' when the source file is nil" do
      expect(v.send(:format_location, nil, 5)).to eq("")
    end

    it "renders '(basename:line)' when both file and line are present" do
      expect(v.send(:format_location, "/path/to/foo.cht", 42)).to eq("(foo.cht:42) ")
    end

    it "renders '(basename)' when line is nil" do
      expect(v.send(:format_location, "/path/to/foo.cht", nil)).to eq("(foo.cht) ")
    end
  end

  describe "#zig_to_clear_name (private)" do
    let(:v) { stub_verifier("") }

    it "maps clearMain to main" do
      expect(v.send(:zig_to_clear_name, "#{PREFIX}.clearMain")).to eq("main")
    end

    it "strips module prefix" do
      expect(v.send(:zig_to_clear_name, "#{PREFIX}.compute")).to eq("compute")
    end

    it "strips __anon suffix" do
      expect(v.send(:zig_to_clear_name, "#{PREFIX}.eval__anon_12345")).to eq("eval")
    end

    it "strips Env suffix (recursive function wrappers)" do
      expect(v.send(:zig_to_clear_name, "#{PREFIX}.readFormEnv")).to eq("readForm")
    end

    it "handles nested struct names (BG context runs)" do
      expect(v.send(:zig_to_clear_name, "#{PREFIX}.clearMain.__BgCtx0.run")).to eq("clearMain.__BgCtx0.run")
    end

    it "handles double suffix (__anon + Env)" do
      expect(v.send(:zig_to_clear_name, "#{PREFIX}.tokenizeToEnv__anon_28318")).to eq("tokenizeTo")
    end
  end

  # -- Real-binary smoke ----------------------------------------------
  # Builds ONE binary in before(:all) shared across all expectations
  # below. The build is the dominant cost (~2s); after it, parsing runs
  # in milliseconds. Catches objdump-format drift that would silently
  # invalidate the canned fixtures above.
  describe "real-binary smoke", :integration do
    PROJECT_ROOT = File.expand_path("..", __dir__) unless defined?(PROJECT_ROOT)
    CLEAR_BIN    = File.join(PROJECT_ROOT, "clear") unless defined?(CLEAR_BIN)

    before(:all) do
      @real_dir = Dir.mktmpdir
      src = <<~CLEAR
        FN compute(n: Float64) RETURNS Float64 ->
          a = n * 2.0;
          RETURN a + 1.0;
        END
        FN main() RETURNS Void ->
          x = compute(21.0);
          RETURN;
        END
      CLEAR
      src_path = File.join(@real_dir, "test.cht")
      bin_path = File.join(@real_dir, "test_bin")
      File.write(src_path, src)
      `#{CLEAR_BIN} build #{src_path} -o #{bin_path} 2>&1`
      @real_bin = File.exist?(bin_path) ? bin_path : nil
      @real_prefix = "._clear_tmp_test"
    end

    after(:all) do
      FileUtils.rm_rf(@real_dir) if @real_dir
    end

    it "extract_frame_sizes parses real objdump output (format check)" do
      skip "build failed" unless @real_bin
      v = StackVerifier.new(@real_bin, @real_prefix)
      frames = v.extract_frame_sizes
      expect(frames.map { |f| f[:name] }).to include("main")
      frames.each { |f| expect(f[:stack_bytes]).to be > 0 }
    end

    it "compute_main_optimal_tier returns a valid tier on a real binary" do
      skip "build failed" unless @real_bin
      v = StackVerifier.new(@real_bin, @real_prefix)
      r = v.compute_main_optimal_tier
      expect(r).not_to be_nil
      expect([:micro, :standard, :large, :xl]).to include(r[:optimal_tier])
    end
  end
end
