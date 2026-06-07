require "rspec"
require "tmpdir"
require_relative "../src/tools/fmt_verifier"

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
      path = write_cht("a.cht")
      allow(FmtVerifier).to receive(:transpile).and_return("pub fn clearMain() void {}\n")
      allow(Formatter).to receive(:format).and_return("formatted source")

      result = FmtVerifier.verify(path)

      expect(result.ok).to be true
      expect(result.error).to be_nil
      expect(result.diff_excerpt).to be_nil
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
      expect(result.ok).to be false
      expect(result.diff_excerpt).to include("const x = 1;")
      expect(result.diff_excerpt).to include("const x = 2;")
    end

    it "captures errors with class+message when transpile raises" do
      path = write_cht("a.cht")
      allow(FmtVerifier).to receive(:transpile)
        .and_raise(ArgumentError, "missing source dir")

      result = FmtVerifier.verify(path)
      expect(result.ok).to be false
      expect(result.error).to include("ArgumentError")
      expect(result.error).to include("missing source dir")
      expect(result.diff_excerpt).to be_nil
    end

    it "captures errors when Formatter.format raises" do
      path = write_cht("a.cht")
      allow(FmtVerifier).to receive(:transpile).and_return("zig output")
      allow(Formatter).to receive(:format).and_raise(Formatter::Error, "parse error")

      result = FmtVerifier.verify(path)
      expect(result.ok).to be false
      expect(result.error).to include("Formatter::Error")
      expect(result.error).to include("parse error")
    end
  end

  describe ".normalize_for_compare" do
    it "strips standalone `// CLR:N` lines" do
      input = "// CLR:5\nconst x = 1;\n// CLR:6\nconst y = 2;\n"
      expected = "const x = 1;\nconst y = 2;\n"
      expect(FmtVerifier.normalize_for_compare(input)).to eq(expected)
    end

    it "leaves trailing inline `// CLR:N` markers alone (only matches whole-line)" do
      # Inline form `code // CLR:7` is intentionally kept — the
      # whole-line normalization targets only the standalone form
      # the emitter actually produces.
      input = "const x = 1; // CLR:5\n"
      expect(FmtVerifier.normalize_for_compare(input)).to eq(input)
    end

    it "is a no-op on Zig output without CLR markers" do
      input = "pub fn main() void {\n  return;\n}\n"
      expect(FmtVerifier.normalize_for_compare(input)).to eq(input)
    end

    it "normalizes lowering-generated temp identifiers" do
      input = "const __guard_12 = __tmp_5_6;\n"
      expect(FmtVerifier.normalize_for_compare(input)).to eq("const __guard_N = __tmp_N_6;\n")
    end
  end

  describe ".verify_dir" do
    it "returns one Result per .cht file under the directory" do
      sub = File.join(@tmp, "nested")
      FileUtils.mkdir_p(sub)
      a = File.join(@tmp, "a.cht")
      b = File.join(sub, "b.cht")
      File.write(a, "FN main() RETURNS Void -> RETURN; END\n")
      File.write(b, "FN main() RETURNS Void -> RETURN; END\n")

      allow(FmtVerifier).to receive(:transpile).and_return("zig\n")
      allow(Formatter).to receive(:format).and_return("fmt\n")

      results = FmtVerifier.verify_dir(@tmp)
      expect(results.length).to eq(2)
      expect(results.map(&:path)).to include(a, b)
      expect(results).to all(have_attributes(ok: true))
    end
  end

  describe ".transpile" do
    it "transpiles a minimal source string with the configured importer" do
      zig = FmtVerifier.transpile("FN main() RETURNS Void -> RETURN; END\n", @tmp)

      expect(zig).to include("pub fn")
    end
  end

  describe ".report" do
    it "returns 0 fail count when all results are OK" do
      results = [
        FmtVerifier::Result.new("a.cht", true, nil, nil),
        FmtVerifier::Result.new("b.cht", true, nil, nil),
      ]
      io = StringIO.new
      expect(FmtVerifier.report(results, io: io)).to eq(0)
      expect(io.string).to include("2 passed, 0 failed")
    end

    it "returns the count of failures and prints details" do
      results = [
        FmtVerifier::Result.new("ok.cht", true, nil, nil),
        FmtVerifier::Result.new("bad.cht", false, nil, "--- a\n+++ b\n@@ ...\n"),
        FmtVerifier::Result.new("err.cht", false, "RuntimeError: boom", nil),
      ]
      io = StringIO.new
      expect(FmtVerifier.report(results, io: io)).to eq(2)
      expect(io.string).to include("ok.cht")
      expect(io.string).to include("bad.cht")
      expect(io.string).to include("err.cht")
      expect(io.string).to include("RuntimeError: boom")
      expect(io.string).to include("1 passed, 2 failed")
    end
  end
end
