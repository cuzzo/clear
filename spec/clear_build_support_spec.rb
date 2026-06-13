require "rspec"
require "tmpdir"
require "fileutils"
require "stringio"

require_relative "../src/tools/clear_build_support" unless defined?(ClearBuildSupport::Config)

RSpec.describe ClearBuildSupport do
  def support_tree
    Dir.mktmpdir do |dir|
      src_dir = File.join(dir, "src")
      zig_dir = File.join(dir, "zig")
      FileUtils.mkdir_p(File.join(src_dir, "tools"))
      FileUtils.mkdir_p(File.join(zig_dir, "runtime"))
      FileUtils.mkdir_p(File.join(zig_dir, "lib"))
      FileUtils.mkdir_p(File.join(zig_dir, ".clear-transpile-cache"))
      write(File.join(src_dir, "compiler.rb"), "compiler")
      write(File.join(zig_dir, "runtime", "runtime-header.zig"), "header")
      write(File.join(zig_dir, "runtime", "runtime-footer.zig"), "footer")
      write(File.join(zig_dir, "runtime", "switch.S"), "switch")
      write(File.join(zig_dir, "lib", "runtime.zig"), "runtime")
      script_path = write(File.join(dir, "clear"), "#!/usr/bin/env ruby\n")
      transpiler_path = write(File.join(dir, "transpile.rb"), "puts 'zig'\n")
      config = described_class::Config.new(
        src_dir: src_dir,
        zig_dir: zig_dir,
        script_path: script_path,
        zig_path: File.join(zig_dir, "zig"),
        transpiler_path: transpiler_path,
        transpiler_cache_dir: File.join(zig_dir, ".clear-transpile-cache")
      )
      yield dir, config
    end
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def touch_at(path, seconds)
    time = Time.at(seconds)
    File.utime(time, time, path)
  end

  def simple_signature(config, source, output, extra_flags: ["-fno-llvm"])
    described_class.build_signature(
      config: config,
      source: source,
      output: output,
      opt_level: "Debug",
      extra_flags: extra_flags,
      module_mode: false,
      profile: false,
      use_c_allocator: false,
      use_debug_allocator: false,
      default_stack: "Large",
      strict_test: false,
      exact_tiers: nil,
      main_tier: nil,
      profile_max: nil
    )
  end

  it "writes only changed files and keeps symlinks pointed at the requested target" do
    support_tree do |dir, _config|
      path = File.join(dir, "out", "file.txt")
      expect(described_class.write_if_changed(path, "one")).to be(true)
      expect(described_class.write_if_changed(path, "one")).to be(false)
      expect(described_class.write_if_changed(path, "two")).to be(true)

      target_one = write(File.join(dir, "target-one"), "one")
      target_two = write(File.join(dir, "target-two"), "two")
      link_path = File.join(dir, "link")
      described_class.ensure_symlink(link_path, target_one)
      expect(File.readlink(link_path)).to eq(target_one)

      described_class.ensure_symlink(link_path, target_one)
      expect(File.readlink(link_path)).to eq(target_one)

      described_class.ensure_symlink(link_path, target_two)
      expect(File.readlink(link_path)).to eq(target_two)

      FileUtils.rm_f(link_path)
      FileUtils.mkdir_p(link_path)
      described_class.ensure_symlink(link_path, target_one)
      expect(File.readlink(link_path)).to eq(target_one)
    end
  end

  it "round-trips build signatures and tolerates absent or corrupt metadata" do
    support_tree do |dir, config|
      source = write(File.join(dir, "main.cht"), "FN main() RETURNS Void -> RETURN; END\n")
      output = File.join(dir, "main")
      signature = simple_signature(config, source, output)

      tiered = described_class.build_signature(
        config: config,
        source: source,
        output: output,
        opt_level: "ReleaseFast",
        extra_flags: [],
        module_mode: true,
        profile: true,
        use_c_allocator: true,
        use_debug_allocator: true,
        default_stack: nil,
        strict_test: true,
        exact_tiers: { 0 => :large },
        main_tier: :large,
        profile_max: 4096
      )
      expect(tiered["exact_tiers"]).to eq({ "0" => :large })
      expect(tiered["zig"]).to eq(config.zig_path)

      expect(described_class.read_build_signature(output)).to be_nil
      expect(described_class.write_build_signature(output, signature)).to be(true)
      expect(described_class.write_build_signature(output, signature)).to be(false)
      expect(described_class.read_build_signature(output)).to eq(signature)

      File.write(described_class.build_metadata_path(output), "[]")
      expect(described_class.read_build_signature(output)).to be_nil

      File.write(described_class.build_metadata_path(output), "{broken")
      expect(described_class.read_build_signature(output)).to be_nil
    end
  end

  it "resolves local and package dependencies from nested source layouts" do
    support_tree do |dir, _config|
      src_dir = File.join(dir, "app", "src")
      helper = write(File.join(src_dir, "helper.cht"), "PUB FN value() RETURNS Int64 -> RETURN 1; END\n")
      package = write(
        File.join(dir, "app", "packages", "math", "src", "lib.cht"),
        "PUB FN add(a: Int64, b: Int64) RETURNS Int64 -> RETURN a + b; END\n"
      )
      zig_package = write(
        File.join(dir, "app", "packages", "http", "src", "lib.zig"),
        "pub fn ok() bool { return true; }\n"
      )
      main = write(
        File.join(src_dir, "main.cht"),
        "REQUIRE \"helper.cht\";\nREQUIRE \"pkg:math\";\nFN main() RETURNS Int64 -> RETURN value(); END\n"
      )

      expect(described_class.find_package_source("math", start_dir: src_dir)).to eq(package)
      expect(described_class.find_package_source("missing", start_dir: src_dir)).to be_nil
      expect(described_class.find_zig_package_source("http", start_dir: src_dir)).to eq(zig_package)
      expect(described_class.find_zig_package_source("missing", start_dir: src_dir)).to be_nil
      expect(described_class.resolve_clear_require("helper.cht", caller_dir: src_dir)).to eq(helper)
      expect(described_class.resolve_clear_require("pkg:math", caller_dir: src_dir)).to eq(package)
      expect {
        described_class.resolve_clear_require("pkg:missing", caller_dir: src_dir)
      }.to raise_error(described_class::PackageMissingError, /Package 'missing'/)

      deps = described_class.collect_clear_dependencies(main)
      expect(deps).to include(File.expand_path(main), File.expand_path(helper), File.expand_path(package))
      expect {
        described_class.collect_clear_dependencies(File.join(src_dir, "missing.cht"))
      }.to raise_error(described_class::FileMissingError, /File not found/)
    end
  end

  it "handles dependency cycles without revisiting already seen files" do
    support_tree do |dir, _config|
      a = write(File.join(dir, "a.cht"), "REQUIRE \"b.cht\";\n")
      b = write(File.join(dir, "b.cht"), "REQUIRE \"a.cht\";\n")

      expect(described_class.collect_clear_dependencies(a)).to eq(Set[File.expand_path(a), File.expand_path(b)])
    end
  end

  it "decides rebuilds from output metadata, build flags, and transitive mtimes" do
    support_tree do |dir, config|
      app_dir = File.join(dir, "app")
      helper = write(File.join(app_dir, "helper.cht"), "PUB FN value() RETURNS Int64 -> RETURN 1; END\n")
      package = write(
        File.join(app_dir, "packages", "math", "src", "lib.cht"),
        "PUB FN add(a: Int64, b: Int64) RETURNS Int64 -> RETURN a + b; END\n"
      )
      source = write(
        File.join(app_dir, "main.cht"),
        "REQUIRE \"helper.cht\";\nREQUIRE \"pkg:math\";\nFN main() RETURNS Int64 -> RETURN value(); END\n"
      )
      output = write(File.join(app_dir, "main"), "binary")
      signature = simple_signature(config, source, output)
      described_class.write_build_signature(output, signature)

      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH)
         .reject { |path| [".", ".."].include?(File.basename(path)) || File.directory?(path) }
         .each { |path| touch_at(path, 100) }
      touch_at(output, 200)
      touch_at(described_class.build_metadata_path(output), 200)

      expect(described_class.newest_build_dependency_mtime(source, config: config)).to eq(Time.at(100))
      expect(described_class.build_up_to_date?(
        source: source,
        output: output,
        signature: signature,
        config: config,
        force: false,
        module_mode: false,
        profile: false
      )).to be(true)

      expect(described_class.build_up_to_date?(
        source: source,
        output: File.join(app_dir, "missing-bin"),
        signature: signature,
        config: config,
        force: false,
        module_mode: false,
        profile: false
      )).to be(false)
      expect(described_class.build_up_to_date?(
        source: source,
        output: output,
        signature: signature,
        config: config,
        force: true,
        module_mode: false,
        profile: false
      )).to be(false)
      expect(described_class.build_up_to_date?(
        source: source,
        output: output,
        signature: signature,
        config: config,
        force: false,
        module_mode: true,
        profile: false
      )).to be(false)
      expect(described_class.build_up_to_date?(
        source: source,
        output: output,
        signature: signature,
        config: config,
        force: false,
        module_mode: false,
        profile: true
      )).to be(false)
      expect(described_class.build_up_to_date?(
        source: source,
        output: output,
        signature: simple_signature(config, source, output, extra_flags: []),
        config: config,
        force: false,
        module_mode: false,
        profile: false
      )).to be(false)

      touch_at(helper, 300)
      expect(described_class.build_up_to_date?(
        source: source,
        output: output,
        signature: signature,
        config: config,
        force: false,
        module_mode: false,
        profile: false
      )).to be(false)

      touch_at(helper, 100)
      touch_at(package, 400)
      expect(described_class.build_up_to_date?(
        source: source,
        output: output,
        signature: signature,
        config: config,
        force: false,
        module_mode: false,
        profile: false
      )).to be(false)
    end
  end

  it "keys transpile cache entries by compiler signature and dependency content" do
    support_tree do |dir, config|
      helper = write(File.join(dir, "helper.cht"), "PUB FN value() RETURNS Int64 -> RETURN 1; END\n")
      source = write(File.join(dir, "main.cht"), "REQUIRE \"helper.cht\";\nFN main() RETURNS Int64 -> RETURN value(); END\n")
      source_text = File.read(source)

      first_compiler_signature = described_class.compiler_signature(config)
      expect(described_class.compiler_signature(config)).to eq(first_compiler_signature)
      first_dependency_signature = described_class.transpile_dependency_signature(source)
      first_key = described_class.transpile_cache_key(
        config: config,
        source_path: source,
        mode: :build_root,
        transpile_flag: "",
        source_text: source_text
      )

      File.write(helper, "PUB FN value() RETURNS Int64 -> RETURN 2; END\n")
      expect(described_class.transpile_dependency_signature(source)).not_to eq(first_dependency_signature)
      expect(described_class.transpile_cache_key(
        config: config,
        source_path: source,
        mode: :build_root,
        transpile_flag: "",
        source_text: source_text
      )).not_to eq(first_key)
    end
  end

  it "fetches, bypasses, and records transpilation cache entries with debug output" do
    support_tree do |dir, config|
      source = write(File.join(dir, "main.cht"), "FN main() RETURNS Void -> RETURN; END\n")
      calls = 0
      runner = lambda do |_config, _flag, _path|
        calls += 1
        "zig-#{calls}"
      end
      debug = StringIO.new

      zig_code, cache_file = described_class.transpile_cached(
        config: config,
        source_path: source,
        mode: :build_root,
        transpile_flag: "",
        source_text: File.read(source),
        debug_cache: true,
        debug_stream: debug,
        runner: runner
      )
      expect(zig_code).to eq("zig-1")
      expect(File.read(cache_file)).to eq("zig-1")
      expect(debug.string).to include("[transpile-cache] miss build_root main.cht")

      hit_code, hit_file = described_class.transpile_cached(
        config: config,
        source_path: source,
        mode: :build_root,
        transpile_flag: "",
        source_text: File.read(source),
        debug_cache: true,
        debug_stream: debug,
        runner: ->(_config, _flag, _path) { raise "should not run on cache hit" }
      )
      expect([hit_code, hit_file, calls]).to eq(["zig-1", cache_file, 1])
      expect(debug.string).to include("[transpile-cache] hit build_root main.cht")

      bypass_code, bypass_file = described_class.transpile_cached(
        config: config,
        source_path: source,
        mode: :build_root,
        transpile_flag: "",
        source_text: File.read(source),
        bypass: true,
        debug_cache: true,
        debug_stream: debug,
        runner: runner
      )
      expect([bypass_code, bypass_file, calls]).to eq(["zig-2", cache_file, 2])
      expect(File.read(cache_file)).to eq("zig-2")
      expect(debug.string).to include("[transpile-cache] bypass build_root main.cht")

      expect {
        described_class.transpile_cached(
          config: config,
          source_path: source,
          mode: :build_root,
          transpile_flag: "--strict",
          source_text: File.read(source),
          runner: ->(_config, _flag, _path) { nil }
        )
      }.to raise_error(described_class::TranspileError, /Transpilation failed/)

      quiet = StringIO.new
      described_class.emit_debug_cache("hidden", enabled: false, stream: quiet)
      expect(quiet.string).to eq("")
    end
  end

  it "runs the configured transpiler command and returns nil on failure" do
    support_tree do |dir, config|
      source = write(File.join(dir, "main.cht"), "FN main() RETURNS Void -> RETURN; END\n")
      ok_transpiler = write(File.join(dir, "ok_transpile.rb"), "puts ARGV.join('|')\n")
      ok_config = described_class::Config.new(
        src_dir: config.src_dir,
        zig_dir: config.zig_dir,
        script_path: config.script_path,
        zig_path: config.zig_path,
        transpiler_path: ok_transpiler,
        transpiler_cache_dir: config.transpiler_cache_dir
      )
      expect(described_class.run_transpiler(ok_config, "--module", source)).to include("--module|#{source}")

      failing_transpiler = write(File.join(dir, "fail_transpile.rb"), "exit 7\n")
      failing_config = described_class::Config.new(
        src_dir: config.src_dir,
        zig_dir: config.zig_dir,
        script_path: config.script_path,
        zig_path: config.zig_path,
        transpiler_path: failing_transpiler,
        transpiler_cache_dir: config.transpiler_cache_dir
      )
      expect(described_class.run_transpiler(failing_config, "", source)).to be_nil
    end
  end
end
