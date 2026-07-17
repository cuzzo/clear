require "rspec"
require "tmpdir"
require "fileutils"
require "digest"

# Tests for the ./clear CLI binary.
# Each test creates a temp directory with .clear files and runs ./clear build.

CLEAR_BIN = File.expand_path("../../clear", __dir__)

RSpec.describe "./clear build", :integration do
  def clear_build(source_path, *args, env: {})
    env_prefix = env.map { |k, v| "#{k}=#{v}" }.join(" ")
    env_prefix = "#{env_prefix} " unless env_prefix.empty?
    cmd = "#{env_prefix}#{CLEAR_BIN} build #{source_path} #{args.join(' ')} 2>&1"
    output = `#{cmd}`
    [output, $?.success?]
  end

  def clear_run(source_path, *args)
    cmd = "#{CLEAR_BIN} run #{source_path} #{args.join(' ')} 2>&1"
    output = `#{cmd}`
    [output, $?.success?]
  end

  def clear_cache_dir
    File.expand_path("../../zig/.clear-cache", __dir__)
  end

  def cache_entries_for(source_path)
    source_hash = Digest::SHA256.hexdigest(File.expand_path(source_path))[0, 16]
    Dir.glob(File.join(clear_cache_dir, source_hash, "*"), File::FNM_DOTMATCH)
       .reject { |p| [".", ".."].include?(File.basename(p)) }
       .sort
  end

  context "single file" do
    it "builds and runs a simple program" do
      dir = Dir.mktmpdir
      File.write(File.join(dir, "main.clear"), <<~CLEAR)
        FN main() RETURNS Void ->
          print("hello");
          RETURN;
        END
      CLEAR
      output, ok = clear_run(File.join(dir, "main.clear"))
      expect(ok).to be true
      expect(output).to include("hello")
    ensure
      FileUtils.rm_rf(dir)
    end

    it "autofixes explicit mutation before running in EASY mode" do
      dir = Dir.mktmpdir
      source_path = File.join(dir, "main.clear")
      File.write(source_path, <<~CLEAR)
        FN increment(MUTABLE value: Int64) RETURNS Void ->
          value = value + 1_i64;
        END
        FN main() RETURNS Void ->
          value = 1_i64;
          increment(value);
          ASSERT value == 2_i64;
        END
      CLEAR

      output, ok = clear_run(source_path, "--easy")
      rewritten = File.read(source_path)
      expect(ok).to eq(true), "Expected EASY autofix+run to succeed, got: #{output}"
      expect(rewritten).to include("MUTABLE value = 1_i64;")
      expect(rewritten).to include("increment(&value);")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  context "package imports" do
    it "builds a program that REQUIRE pkg:math with packages/ convention" do
      dir = Dir.mktmpdir

      # Create package: packages/math/src/lib.clear
      math_dir = File.join(dir, "packages", "math", "src")
      FileUtils.mkdir_p(math_dir)
      File.write(File.join(math_dir, "lib.clear"), <<~CLEAR)
        PUB FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END
      CLEAR

      # Create main
      File.write(File.join(dir, "main.clear"), <<~CLEAR)
        REQUIRE "pkg:math";
        FN main() RETURNS Void ->
          result = add(3, 4);
          ASSERT result == 7;
          print("PASS");
          RETURN;
        END
      CLEAR

      output, ok = clear_run(File.join(dir, "main.clear"))
      expect(ok).to eq(true), "Expected build+run to succeed, got: #{output}"
      expect(output).to include("PASS")
    ensure
      FileUtils.rm_rf(dir)
    end

  end

  context "incremental builds" do
    it "skips rebuilding unchanged single-file programs and preserves cached Zig output mtimes" do
      dir = Dir.mktmpdir
      main_path = File.join(dir, "main.clear")
      File.write(main_path, <<~CLEAR)
        FN main() RETURNS Void ->
          print("cache");
          RETURN;
        END
      CLEAR

      output1, ok1 = clear_build(main_path, "--debug")
      expect(ok1).to be true
      expect(output1).to include("Built:")

      cached_before = cache_entries_for(main_path)
      root_zig_before = cached_before.find { |p| File.basename(p).end_with?(".zig") }
      expect(root_zig_before).not_to be_nil
      mtime_before = File.mtime(root_zig_before)

      output2, ok2 = clear_build(main_path, "--debug")
      expect(ok2).to be true
      expect(output2).to include("up-to-date:")
      expect(File.mtime(root_zig_before)).to eq(mtime_before)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
