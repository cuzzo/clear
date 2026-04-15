require "rspec"
require "tmpdir"
require "fileutils"
require "digest"

# Tests for the ./clear CLI binary.
# Each test creates a temp directory with .cht files and runs ./clear build.

CLEAR_BIN = File.expand_path("../clear", __dir__)

RSpec.describe "./clear build" do
  def clear_build(source_path, *args, env: {})
    env_prefix = env.map { |k, v| "#{k}=#{v}" }.join(" ")
    env_prefix = "#{env_prefix} " unless env_prefix.empty?
    cmd = "#{env_prefix}#{CLEAR_BIN} build #{source_path} #{args.join(' ')} 2>&1"
    output = `#{cmd}`
    [output, $?.success?]
  end

  def clear_run(source_path)
    cmd = "#{CLEAR_BIN} run #{source_path} 2>&1"
    output = `#{cmd}`
    [output, $?.success?]
  end

  def clear_cache_dir
    File.expand_path("../zig/.clear-cache", __dir__)
  end

  def transpile_cache_dir
    File.expand_path("../zig/.clear-transpile-cache", __dir__)
  end

  def cache_entries_for(source_path)
    source_hash = Digest::SHA256.hexdigest(File.expand_path(source_path))[0, 16]
    Dir.glob(File.join(clear_cache_dir, source_hash, "*"), File::FNM_DOTMATCH)
       .reject { |p| [".", ".."].include?(File.basename(p)) }
       .sort
  end

  def transpile_cache_entries
    Dir.glob(File.join(transpile_cache_dir, "*.zig")).sort
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

    it "supports nested src/ layouts when resolving pkg imports" do
      dir = Dir.mktmpdir

      math_dir = File.join(dir, "packages", "math", "src")
      FileUtils.mkdir_p(math_dir)
      File.write(File.join(math_dir, "lib.cht"), <<~CLEAR)
        PUB FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END
      CLEAR

      src_dir = File.join(dir, "src")
      FileUtils.mkdir_p(src_dir)
      main_path = File.join(src_dir, "main.cht")
      File.write(main_path, <<~CLEAR)
        REQUIRE "pkg:math";
        FN main() RETURNS Void ->
          ASSERT add(20, 22) == 42;
          print("NESTED");
          RETURN;
        END
      CLEAR

      output, ok = clear_run(main_path)
      expect(ok).to eq(true), "Expected nested package build+run to succeed, got: #{output}"
      expect(output).to include("NESTED")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  context "incremental builds" do
    it "skips rebuilding unchanged single-file programs and preserves cached Zig output mtimes" do
      dir = Dir.mktmpdir
      main_path = File.join(dir, "main.cht")
      File.write(main_path, <<~CLEAR)
        FN main() RETURNS Void ->
          print("cache");
          RETURN;
        END
      CLEAR

      output1, ok1 = clear_build(main_path, "--safe")
      expect(ok1).to be true
      expect(output1).to include("Built:")

      cached_before = cache_entries_for(main_path)
      root_zig_before = cached_before.find { |p| File.basename(p).end_with?(".zig") }
      expect(root_zig_before).not_to be_nil
      mtime_before = File.mtime(root_zig_before)

      output2, ok2 = clear_build(main_path, "--safe")
      expect(ok2).to be true
      expect(output2).to include("up-to-date:")
      expect(File.mtime(root_zig_before)).to eq(mtime_before)
    ensure
      FileUtils.rm_rf(dir)
    end

    it "reuses the persistent transpilation cache on forced rebuilds" do
      dir = Dir.mktmpdir
      main_path = File.join(dir, "main.cht")
      File.write(main_path, <<~CLEAR)
        FN main() RETURNS Void ->
          print("cache-hit");
          RETURN;
        END
      CLEAR

      before_entries = transpile_cache_entries

      output1, ok1 = clear_build(main_path, "--safe", "--force", env: { "CLEAR_DEBUG_CACHE" => "1" })
      expect(ok1).to be true
      expect(output1).to include("[transpile-cache] miss build_root main.cht")

      after_first = transpile_cache_entries
      new_entries = after_first - before_entries
      expect(new_entries).not_to be_empty

      output2, ok2 = clear_build(main_path, "--safe", "--force", env: { "CLEAR_DEBUG_CACHE" => "1" })
      expect(ok2).to be true
      expect(output2).to include("[transpile-cache] hit build_root main.cht")
      expect(transpile_cache_entries).to eq(after_first)
    ensure
      FileUtils.rm_rf(dir)
    end

    it "rebuilds when a required local module changes" do
      dir = Dir.mktmpdir
      helper_path = File.join(dir, "helper.cht")
      File.write(helper_path, <<~CLEAR)
        PUB FN value() RETURNS Int64 ->
          RETURN 1;
        END
      CLEAR

      main_path = File.join(dir, "main.cht")
      File.write(main_path, <<~CLEAR)
        REQUIRE "helper.cht";
        FN main() RETURNS Void ->
          ASSERT value() == 1;
          RETURN;
        END
      CLEAR

      output1, ok1 = clear_build(main_path, "--safe")
      expect(ok1).to be true
      expect(output1).to include("Built:")

      sleep 1
      File.write(helper_path, <<~CLEAR)
        PUB FN value() RETURNS Int64 ->
          RETURN 2;
        END
      CLEAR

      output2, ok2 = clear_build(main_path, "--safe")
      expect(ok2).to be true
      expect(output2).to include("Built:")
      expect(output2).not_to include("up-to-date:")
    ensure
      FileUtils.rm_rf(dir)
    end

    it "rebuilds when a required package module changes" do
      dir = Dir.mktmpdir

      math_dir = File.join(dir, "packages", "math", "src")
      FileUtils.mkdir_p(math_dir)
      lib_path = File.join(math_dir, "lib.cht")
      File.write(lib_path, <<~CLEAR)
        PUB FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b;
        END
      CLEAR

      main_path = File.join(dir, "main.cht")
      File.write(main_path, <<~CLEAR)
        REQUIRE "pkg:math";
        FN main() RETURNS Void ->
          ASSERT add(2, 3) == 5;
          RETURN;
        END
      CLEAR

      output1, ok1 = clear_build(main_path, "--safe")
      expect(ok1).to be true
      expect(output1).to include("Built:")

      sleep 1
      File.write(lib_path, <<~CLEAR)
        PUB FN add(a: Int64, b: Int64) RETURNS Int64 ->
          RETURN a + b + 1;
        END
      CLEAR

      output2, ok2 = clear_build(main_path, "--safe")
      expect(ok2).to be true
      expect(output2).to include("Built:")
      expect(output2).not_to include("up-to-date:")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
