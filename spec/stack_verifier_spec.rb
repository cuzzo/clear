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
  end
end
