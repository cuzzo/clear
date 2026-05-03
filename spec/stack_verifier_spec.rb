require "rspec"
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
