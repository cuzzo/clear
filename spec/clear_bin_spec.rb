require "rspec"
require "tmpdir"
require "fileutils"

# Tests for the ./clear CLI binary.
# Each test creates a temp directory with .cht files and runs ./clear build.

CLEAR_BIN = File.expand_path("../clear", __dir__)

RSpec.describe "./clear build" do
  def clear_build(source_path, *args)
    cmd = "#{CLEAR_BIN} build #{source_path} #{args.join(' ')} 2>&1"
    output = `#{cmd}`
    [output, $?.success?]
  end

  def clear_run(source_path)
    cmd = "#{CLEAR_BIN} run #{source_path} 2>&1"
    output = `#{cmd}`
    [output, $?.success?]
  end

  context "single file" do
    it "builds and runs a simple program" do
      dir = Dir.mktmpdir
      File.write(File.join(dir, "main.cht"), <<~CLEAR)
        FN main() RETURNS Void ->
          print("hello");
          RETURN;
        END
      CLEAR
      output, ok = clear_run(File.join(dir, "main.cht"))
      expect(ok).to be true
      expect(output).to include("hello")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  context "package imports" do
    it "builds a program that REQUIRE pkg:math with packages/ convention" do
      dir = Dir.mktmpdir

      # Create package: packages/math/src/lib.cht
      math_dir = File.join(dir, "packages", "math", "src")
      FileUtils.mkdir_p(math_dir)
      File.write(File.join(math_dir, "lib.cht"), <<~CLEAR)
        PUB FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END
      CLEAR

      # Create main
      File.write(File.join(dir, "main.cht"), <<~CLEAR)
        REQUIRE "pkg:math";
        FN main() RETURNS Void ->
          result = add(3, 4);
          ASSERT result == 7;
          print("PASS");
          RETURN;
        END
      CLEAR

      output, ok = clear_run(File.join(dir, "main.cht"))
      expect(ok).to eq(true), "Expected build+run to succeed, got: #{output}"
      expect(output).to include("PASS")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
