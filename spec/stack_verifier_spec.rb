require "rspec"
require "tmpdir"
require_relative "../src/stack_verifier"
require_relative "../src/transpiler"

RSpec.describe StackVerifier do
  # Build a CLEAR program and return the binary path + annotator fn_nodes.
  def build_and_analyze(source)
    dir = Dir.mktmpdir
    src_path = "#{dir}/test.cht"
    bin_path = "#{dir}/test_bin"

    File.write(src_path, source)

    # Transpile + annotate
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    fn_nodes = annotator.instance_variable_get(:@fn_nodes)

    # Build
    `./clear build #{src_path} -o #{bin_path} 2>&1`

    [bin_path, fn_nodes, dir]
  end

  after do
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  describe "#extract_frame_sizes" do
    it "extracts stack frame sizes from a built binary" do
      src = <<~CLEAR
        FN compute(n: Float64) RETURNS Float64 ->
            a = n * 2.0;
            b = a + 1.0;
            RETURN b;
        END
        FN main() RETURNS Void ->
            x = compute(21.0);
            RETURN;
        END
      CLEAR

      bin_path, _, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      prefix = "._clear_tmp_test"
      verifier = StackVerifier.new(bin_path, prefix)
      frames = verifier.extract_frame_sizes

      # Should find at least clearMain (main) and compute
      names = frames.map { |f| f[:name] }
      expect(names).to include("main")

      # All frame sizes should be positive
      frames.each do |f|
        expect(f[:stack_bytes]).to be > 0
      end
    end
  end

  describe "#analyze" do
    it "cross-references with tier recommendations" do
      src = <<~CLEAR
        FN add(a: Float64, b: Float64) RETURNS Float64 ->
            RETURN a + b;
        END
        FN main() RETURNS Void ->
            x = add(1.0, 2.0);
            RETURN;
        END
      CLEAR

      bin_path, fn_nodes, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      prefix = "._clear_tmp_test"
      verifier = StackVerifier.new(bin_path, prefix)
      report = verifier.analyze(fn_nodes: fn_nodes)

      # Should have function entries
      expect(report[:functions]).not_to be_empty

      # main should have a tier assigned
      main_entry = report[:functions].find { |f| f[:name] == "main" }
      expect(main_entry).not_to be_nil
      expect(main_entry[:tier]).not_to eq(:unknown) if main_entry
    end

    it "detects functions exceeding tier budget" do
      # Create a function with many large stack locals
      vars = (1..500).map { |i| "v#{i} = #{i}.0;" }.join("\n")
      sum = (1..500).map { |i| "v#{i}" }.join(" + ")
      src = <<~CLEAR
        FN heavy() RETURNS Float64 ->
            #{vars}
            RETURN #{sum};
        END
        FN main() RETURNS Void ->
            x = heavy();
            RETURN;
        END
      CLEAR

      bin_path, fn_nodes, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      prefix = "._clear_tmp_test"
      verifier = StackVerifier.new(bin_path, prefix)
      report = verifier.analyze(fn_nodes: fn_nodes)

      # heavy() should have significant stack usage
      heavy = report[:functions].find { |f| f[:name] == "heavy" }
      expect(heavy).not_to be_nil
      expect(heavy[:stack_bytes]).to be > 1000 if heavy
    end
  end

  describe "#cost_to_tier" do
    let(:v) { StackVerifier.new("/dev/null") }

    it "maps bytes <= 4096 to :micro" do
      expect(v.cost_to_tier(0)).to eq(:micro)
      expect(v.cost_to_tier(4096)).to eq(:micro)
    end

    it "maps bytes <= standard budget to :standard" do
      expect(v.cost_to_tier(4097)).to eq(:standard)
      expect(v.cost_to_tier(16384 - 4096)).to eq(:standard) # usable budget
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

  describe "#compute_main_optimal_tier" do
    it "returns a non-nil result with a valid tier" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            x = 42_i64;
            RETURN;
        END
      CLEAR

      bin_path, _, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      prefix = "._clear_tmp_test"
      verifier = StackVerifier.new(bin_path, prefix)
      result = verifier.compute_main_optimal_tier

      expect(result).not_to be_nil
      expect(result[:path_cost]).to be >= 0
      expect(result[:optimal_tier]).to satisfy("be a valid tier") { |t| [:micro, :standard, :large, :xl].include?(t) }
    end

    it "returns nil for a binary without clearMain" do
      # /dev/null has no functions
      verifier = StackVerifier.new("/dev/null", "._clear_tmp_test")
      expect(verifier.compute_main_optimal_tier).to be_nil
    end

    it "optimal_tier fits within its budget" do
      src = <<~CLEAR
        FN helper(n: Int64) RETURNS Int64 ->
            RETURN n %* 2_i64;
        END
        FN main() RETURNS Void ->
            x = helper(10_i64);
            RETURN;
        END
      CLEAR

      bin_path, _, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      verifier = StackVerifier.new(bin_path, "._clear_tmp_test")
      result = verifier.compute_main_optimal_tier

      expect(result).not_to be_nil
      budget = StackVerifier::TIER_BUDGET[result[:optimal_tier]]
      expect(result[:path_cost]).to be <= budget
    end
  end

  describe "#compute_optimal_tiers" do
    it "returns an empty array when there are no BG blocks" do
      src = <<~CLEAR
        FN main() RETURNS Void ->
            x = 1_i64;
            RETURN;
        END
      CLEAR

      bin_path, fn_nodes, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      verifier = StackVerifier.new(bin_path, "._clear_tmp_test")
      expect(verifier.compute_optimal_tiers(fn_nodes: fn_nodes)).to eq([])
    end

    it "returns one entry per BG block with bg_index, path_cost, optimal_tier" do
      src = <<~CLEAR
        FN work(n: Int64) RETURNS Int64 ->
            RETURN n %* 3_i64;
        END
        FN main() RETURNS Void ->
            f = BG { work(5_i64); };
            result = NEXT f;
            RETURN;
        END
      CLEAR

      bin_path, fn_nodes, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      verifier = StackVerifier.new(bin_path, "._clear_tmp_test")
      results = verifier.compute_optimal_tiers(fn_nodes: fn_nodes)

      expect(results.length).to eq(1)
      r = results.first
      expect(r[:bg_index]).to eq(0)
      expect(r[:path_cost]).to be > 0
      expect(r[:optimal_tier]).to satisfy("be a valid tier") { |t| [:micro, :standard, :large, :xl].include?(t) }

      # BG path cost must fit within the assigned tier's budget
      budget = StackVerifier::TIER_BUDGET[r[:optimal_tier]]
      expect(r[:path_cost]).to be <= budget
    end

    it "measures a pure-compute BG block: path fits its assigned tier budget" do
      # Even a trivial BG block includes runtime wrapper overhead in debug mode.
      # The key invariant: path_cost <= TIER_BUDGET[optimal_tier].
      src = <<~CLEAR
        FN crunch(x: Int64) RETURNS Int64 ->
            RETURN x %* 6364136223846793005_i64 %+ 1442695040888963407_i64;
        END
        FN main() RETURNS Void ->
            f = BG { crunch(42_i64); };
            result = NEXT f;
            RETURN;
        END
      CLEAR

      bin_path, fn_nodes, @tmpdir = build_and_analyze(src)
      next unless File.exist?(bin_path)

      verifier = StackVerifier.new(bin_path, "._clear_tmp_test")
      results = verifier.compute_optimal_tiers(fn_nodes: fn_nodes)

      expect(results.length).to eq(1)
      r = results.first
      expect(r[:optimal_tier]).to satisfy("be a valid tier") { |t| [:micro, :standard, :large, :xl].include?(t) }
      budget = StackVerifier::TIER_BUDGET[r[:optimal_tier]]
      expect(r[:path_cost]).to be <= budget
    end
  end

  describe "#zig_to_clear_name" do
    it "maps clearMain to main" do
      v = StackVerifier.new("/dev/null", "._clear_tmp_foo")
      expect(v.send(:zig_to_clear_name, "._clear_tmp_foo.clearMain")).to eq("main")
    end

    it "strips module prefix" do
      v = StackVerifier.new("/dev/null", "._clear_tmp_foo")
      expect(v.send(:zig_to_clear_name, "._clear_tmp_foo.compute")).to eq("compute")
    end

    it "strips __anon suffix" do
      v = StackVerifier.new("/dev/null", "._clear_tmp_foo")
      expect(v.send(:zig_to_clear_name, "._clear_tmp_foo.eval__anon_12345")).to eq("eval")
    end

    it "strips Env suffix (recursive function wrappers)" do
      v = StackVerifier.new("/dev/null", "._clear_tmp_foo")
      expect(v.send(:zig_to_clear_name, "._clear_tmp_foo.readFormEnv")).to eq("readForm")
    end

    it "handles nested struct names (BG context runs)" do
      v = StackVerifier.new("/dev/null", "._clear_tmp_foo")
      # clearMain -> main only when it's the full name, not a prefix
      expect(v.send(:zig_to_clear_name, "._clear_tmp_foo.clearMain.__BgCtx0.run")).to eq("clearMain.__BgCtx0.run")
    end

    it "handles double suffix (__anon + Env)" do
      v = StackVerifier.new("/dev/null", "._clear_tmp_foo")
      expect(v.send(:zig_to_clear_name, "._clear_tmp_foo.tokenizeToEnv__anon_28318")).to eq("tokenizeTo")
    end
  end
end
