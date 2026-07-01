require "rspec"
require "tmpdir"
require_relative "../ruby/tools/fmt_verifier" unless defined?(FmtVerifier)

# FmtVerifier compares the Zig emitted from a .cht file before and
# after fmt to confirm fmt is semantics-preserving. Heavy parts
# (full transpile pipeline, real Formatter) are stubbed here so the
# tests focus on the equivalence-check logic itself: a normalized
# byte-compare of the two Zig outputs, with `// CLR:N` line markers
# stripped before comparing.

RSpec.describe FmtVerifier do
  around do |ex|
    Dir.mktmpdir do |dir|
      @tmp = dir
      ex.run
    end
  end

  def write_cht(name, content = "FN main() RETURNS Void -> RETURN; END\n")
    path = File.join(@tmp, name)
    File.write(path, content)
    path
  end

  describe ".verify — equivalence logic" do
    it "returns ok=true when both transpilations produce the same Zig" do
      path = write_cht("a.cht", "original source")
      calls = []
      allow(FmtVerifier).to receive(:transpile) do |source, source_dir|
        calls << [source, source_dir]
        "pub fn clearMain() void {}\n"
      end
      allow(Formatter).to receive(:format).with("original source").and_return("formatted source")

      result = FmtVerifier.verify(path)

      expect(calls).to eq([
        ["original source", @tmp],
        ["formatted source", @tmp],
      ])
      expect(result.path).to eq(path)
      expect(result.ok).to be true
      expect(result.error).to be_nil
      expect(result.diff_excerpt).to be_nil
    end

    it "uses an explicit source_dir for both transpilation passes" do
      path = write_cht("a.cht", "source")
      source_dir = File.join(@tmp, "imports")
      FileUtils.mkdir_p(source_dir)
      calls = []
      allow(FmtVerifier).to receive(:transpile) do |source, dir|
        calls << [source, dir]
        "zig\n"
      end
      allow(Formatter).to receive(:format).with("source").and_return("formatted")

      result = FmtVerifier.verify(path, source_dir: source_dir)

      expect(result.path).to eq(path)
      expect(calls).to eq([
        ["source", source_dir],
        ["formatted", source_dir],
      ])
    end

    it "derives the default source_dir from the expanded file path" do
      write_cht("a.cht", "source")
      calls = []
      allow(FmtVerifier).to receive(:transpile) do |source, dir|
        calls << [source, dir]
        "zig\n"
      end
      allow(Formatter).to receive(:format).with("source").and_return("formatted")

      Dir.chdir(@tmp) do
        result = FmtVerifier.verify("a.cht")
        expect(result.path).to eq("a.cht")
      end

      expect(calls).to eq([
        ["source", @tmp],
        ["formatted", @tmp],
      ])
    end

    it "returns ok=false with a diff excerpt when Zig outputs differ" do
      path = write_cht("a.cht")
      call_count = 0
      allow(FmtVerifier).to receive(:transpile) do
        call_count += 1
        call_count == 1 ? "before line\n" : "after line\n"
      end
      allow(Formatter).to receive(:format).and_return("fmt'd source")

      result = FmtVerifier.verify(path)

      expect(result.path).to eq(path)
      expect(result.ok).to be false
      expect(result.error).to be_nil
      expect(result.diff_excerpt).to include("before line")
      expect(result.diff_excerpt).to include("after line")
    end

    it "ignores `// CLR:N` line markers when comparing" do
      path = write_cht("a.cht")
      before_zig = <<~ZIG
        // CLR:5
        const x = 1;
        // CLR:6
        const y = 2;
      ZIG
      after_zig = <<~ZIG
        // CLR:8
        const x = 1;
        // CLR:9
        const y = 2;
      ZIG
      call_count = 0
      allow(FmtVerifier).to receive(:transpile) do
        call_count += 1
        call_count == 1 ? before_zig : after_zig
      end
      allow(Formatter).to receive(:format).and_return("fmt'd")

      result = FmtVerifier.verify(path)
      expect(result.path).to eq(path)
      expect(result.ok).to be true
    end

    it "still flags genuine code-line differences even alongside CLR markers" do
      path = write_cht("a.cht")
      before_zig = <<~ZIG
        // CLR:5
        const x = 1;
      ZIG
      after_zig = <<~ZIG
        // CLR:8
        const x = 2;
      ZIG
      call_count = 0
      allow(FmtVerifier).to receive(:transpile) do
        call_count += 1
        call_count == 1 ? before_zig : after_zig
      end
      allow(Formatter).to receive(:format).and_return("fmt'd")

      result = FmtVerifier.verify(path)
      expect(result.path).to eq(path)
      expect(result.ok).to be false
      expect(result.diff_excerpt).to include("const x = 1;")
      expect(result.diff_excerpt).to include("const x = 2;")
    end

    it "captures errors with class+message when transpile raises" do
      path = write_cht("a.cht")
      allow(FmtVerifier).to receive(:transpile)
        .and_raise(ArgumentError, "missing source dir")

      result = FmtVerifier.verify(path)
      expect(result.path).to eq(path)
      expect(result.ok).to be false
      expect(result.error).to eq("ArgumentError: missing source dir")
      expect(result.diff_excerpt).to be_nil
    end

    it "captures errors when Formatter.format raises" do
      path = write_cht("a.cht")
      allow(FmtVerifier).to receive(:transpile).and_return("zig output")
      allow(Formatter).to receive(:format).and_raise(Formatter::Error, "parse error")

      result = FmtVerifier.verify(path)
      expect(result.path).to eq(path)
      expect(result.ok).to be false
      expect(result.error).to eq("Formatter::Error: parse error")
      expect(result.diff_excerpt).to be_nil
    end

    it "uses the exception message rather than generic exception stringification" do
      error_class = Class.new(StandardError) do
        def message
          "semantic message"
        end

        def to_s
          "debug string"
        end
      end
      stub_const("FmtVerifierSpecError", error_class)
      path = write_cht("a.cht")
      allow(FmtVerifier).to receive(:transpile).and_raise(FmtVerifierSpecError.new)

      result = FmtVerifier.verify(path)

      expect(result.error).to eq("FmtVerifierSpecError: semantic message")
    end
  end

  describe ".normalize_for_compare" do
    it "strips standalone `// CLR:N` lines" do
      input = "// CLR:5\nconst x = 1;\n// CLR:123\nconst y = 2;\n"
      expected = "const x = 1;\nconst y = 2;\n"
      expect(FmtVerifier.send(:normalize_for_compare, input)).to eq(expected)
    end

    it "leaves trailing inline `// CLR:N` markers alone (only matches whole-line)" do
      # Inline form `code // CLR:7` is intentionally kept — the
      # whole-line normalization targets only the standalone form
      # the emitter actually produces.
      input = "const x = 1; // CLR:5\nabc// CLR:7\n"
      expect(FmtVerifier.send(:normalize_for_compare, input)).to eq(input)
    end

    it "is a no-op on Zig output without CLR markers" do
      input = "pub fn main() void {\n  return;\n}\n"
      expect(FmtVerifier.send(:normalize_for_compare, input)).to eq(input)
    end

    it "normalizes lowering-generated temp identifiers" do
      input = "const __guard_12 = __tmp_5_678;\nconst __x_9 = 1;\n"
      expect(FmtVerifier.send(:normalize_for_compare, input)).to eq("const __guard_N = __tmp_N_678;\nconst __x_N = 1;\n")
    end

    it "strips every standalone CLEAR_PROFILE_TASK_SITE line" do
      input = <<~ZIG
        // CLEAR_PROFILE_TASK_SITE
        // CLEAR_PROFILE_TASK_SITE one:1:1
        const x = 1;
          // CLEAR_PROFILE_TASK_SITE two:2:2
        const y = 2;
      ZIG
      expected = <<~ZIG
        const x = 1;
        const y = 2;
      ZIG
      expect(FmtVerifier.send(:normalize_for_compare, input)).to eq(expected)
    end

    it "keeps non-task-site comments and inline CLR text" do
      input = "const x = 1; // CLR:5\n// CLEAR_PROFILE_TASK_SITE_EXTRA keep\n"
      expect(FmtVerifier.send(:normalize_for_compare, input)).to eq(input)
    end
  end

  describe ".verify_dir" do
    it "returns one Result per .cht file under the directory in path order" do
      sub = File.join(@tmp, "nested")
      FileUtils.mkdir_p(sub)
      z = File.join(@tmp, "z.cht")
      b = File.join(sub, "b.cht")
      a = File.join(@tmp, "a.cht")
      File.write(z, "FN main() RETURNS Void -> RETURN; END\n")
      File.write(b, "FN main() RETURNS Void -> RETURN; END\n")
      File.write(a, "FN main() RETURNS Void -> RETURN; END\n")

      allow(FmtVerifier).to receive(:transpile).and_return("zig\n")
      allow(Formatter).to receive(:format).and_return("fmt\n")

      results = FmtVerifier.verify_dir(@tmp)
      expect(results.map(&:path)).to eq([a, b, z].sort)
      expect(results).to all(have_attributes(ok: true))
    end

    it "sorts the globbed paths before verification" do
      a = File.join(@tmp, "a.cht")
      b = File.join(@tmp, "b.cht")
      z = File.join(@tmp, "z.cht")
      allow(Dir).to receive(:glob)
        .with(File.join(@tmp, "**", "*.cht"))
        .and_return([z, a, b])
      allow(FmtVerifier).to receive(:verify) do |path|
        FmtVerifier::Result.new(path, true, nil, nil)
      end

      expect(FmtVerifier.verify_dir(@tmp).map(&:path)).to eq([a, b, z])
    end
  end

  describe ".transpile" do
    it "wires the importer and transpiler with the requested source_dir" do
      importer = instance_double(ModuleImporter)
      transpiler = instance_double(ZigTranspiler)
      expect(ModuleImporter).to receive(:new)
        .with(base_dir: @tmp, use_mir: true)
        .and_return(importer)
      expect(ZigTranspiler).to receive(:new)
        .with(importer: importer, source_dir: @tmp)
        .and_return(transpiler)
      expect(transpiler).to receive(:transpile)
        .with("FN main() RETURNS Void -> RETURN; END\n")
        .and_return("zig")

      expect(FmtVerifier.transpile("FN main() RETURNS Void -> RETURN; END\n", @tmp)).to eq("zig")
    end

    it "transpiles a minimal source string with the configured importer" do
      zig = FmtVerifier.transpile("FN main() RETURNS Void -> RETURN; END\n", @tmp)

      expect(zig).to include("pub fn")
    end
  end

  describe ".diff_excerpt" do
    it "uses forty diff lines by default before the truncation marker" do
      before = (1..80).map { |i| "before #{i}\n" }.join
      after = (1..80).map { |i| "after #{i}\n" }.join

      excerpt = FmtVerifier.diff_excerpt(before, after)

      expect(excerpt.lines.length).to eq(41)
      expect(excerpt.lines.last).to eq("  ... (123 more lines)\n")
    end

    it "honors explicit max_lines and reports the remaining diff-line count" do
      before = (1..10).map { |i| "before #{i}\n" }.join
      after = (1..10).map { |i| "after #{i}\n" }.join

      excerpt = FmtVerifier.diff_excerpt(before, after, max_lines: 5)

      expect(excerpt.lines.length).to eq(6)
      expect(excerpt).to include("-before 1\n")
      expect(excerpt.lines.last).to eq("  ... (18 more lines)\n")
    end

    it "does not append a truncation marker when the diff is short" do
      excerpt = FmtVerifier.diff_excerpt("same\nbefore\n", "same\nafter\n", max_lines: 20)

      expect(excerpt).to include("-before\n")
      expect(excerpt).to include("+after\n")
      expect(excerpt).not_to include("more lines")
    end
  end

  describe ".report" do
    it "writes to stdout by default" do
      results = [FmtVerifier::Result.new("a.cht", true, nil, nil)]

      expect { expect(FmtVerifier.report(results)).to eq(0) }.to output(
        "  \e[32mOK\e[0m  a.cht\n" \
        "\n" \
        "  \e[32m1 passed, 0 failed.\e[0m\n"
      ).to_stdout
    end

    it "returns 0 fail count when all results are OK" do
      results = [
        FmtVerifier::Result.new("a.cht", true, nil, nil),
        FmtVerifier::Result.new("b.cht", true, nil, nil),
      ]
      io = StringIO.new
      expect(FmtVerifier.report(results, io: io)).to eq(0)
      expect(io.string).to eq(
        "  \e[32mOK\e[0m  a.cht\n" \
        "  \e[32mOK\e[0m  b.cht\n" \
        "\n" \
        "  \e[32m2 passed, 0 failed.\e[0m\n"
      )
    end

    it "allows a failure row with no error or diff details" do
      results = [FmtVerifier::Result.new("unknown.cht", false, nil, nil)]
      io = StringIO.new

      expect(FmtVerifier.report(results, io: io)).to eq(1)
      expect(io.string).to eq(
        "  \e[31mDIFFERS\e[0m  unknown.cht\n" \
        "\n" \
        "  \e[31m0 passed, 1 failed.\e[0m\n"
      )
    end

    it "returns the count of failures and prints details" do
      results = [
        FmtVerifier::Result.new("ok.cht", true, nil, nil),
        FmtVerifier::Result.new("bad.cht", false, nil, "--- a\n+++ b\n@@ ...\n"),
        FmtVerifier::Result.new("err.cht", false, "RuntimeError: boom", nil),
      ]
      io = StringIO.new
      expect(FmtVerifier.report(results, io: io)).to eq(2)
      expect(io.string).to eq(
        "  \e[32mOK\e[0m  ok.cht\n" \
        "  \e[31mDIFFERS\e[0m  bad.cht\n" \
        "        --- a\n" \
        "        +++ b\n" \
        "        @@ ...\n" \
        "  \e[31mERROR\e[0m  err.cht\n" \
        "        \e[33mRuntimeError: boom\e[0m\n" \
        "\n" \
        "  \e[31m1 passed, 2 failed.\e[0m\n"
      )
    end
  end
end
