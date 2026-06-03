# typed: strict

require "digest"
require "fileutils"
require "json"
require "set"
require "shellwords"
require "stringio"
require "sorbet-runtime"

module ClearBuildSupport
  extend T::Sig

  class BuildError < StandardError; end
  class FileMissingError < BuildError; end
  class PackageMissingError < BuildError; end
  class TranspileError < BuildError; end

  class Config < T::Struct
    const :src_dir, String
    const :zig_dir, String
    const :script_path, String
    const :zig_path, String
    const :transpiler_path, String
    const :transpiler_cache_dir, String
  end

  TierKey = T.type_alias { T.any(String, Integer, Symbol) }
  TierValue = T.type_alias { T.any(String, Symbol) }
  ExactTiers = T.type_alias { T::Hash[TierKey, TierValue] }
  ExactTiersSignature = T.type_alias { T::Hash[String, TierValue] }
  BuildSignatureValue = T.type_alias do
    T.any(String, Integer, T::Boolean, NilClass, T::Array[String], ExactTiersSignature)
  end
  BuildSignature = T.type_alias { T::Hash[String, BuildSignatureValue] }
  DebugStream = T.type_alias { T.any(IO, StringIO) }
  TranspileRunner = T.type_alias do
    T.proc.params(config: Config, transpile_flag: String, source_path: String).returns(T.nilable(String))
  end

  @compiler_signatures = T.let({}, T::Hash[String, String])

  sig { params(path: String, content: String).returns(T::Boolean) }
  def self.write_if_changed(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    return false if File.exist?(path) && File.read(path) == content

    File.write(path, content)
    true
  end

  sig { params(link_path: String, target_path: String).void }
  def self.ensure_symlink(link_path, target_path)
    if File.symlink?(link_path)
      return if File.readlink(link_path) == target_path

      File.delete(link_path)
    elsif File.exist?(link_path)
      FileUtils.rm_rf(link_path)
    end
    File.symlink(target_path, link_path)
  end

  sig { params(output: String).returns(String) }
  def self.build_metadata_path(output)
    File.join(File.dirname(output), ".#{File.basename(output)}.clear-build.json")
  end

  sig do
    params(
      config: Config,
      source: String,
      output: String,
      opt_level: String,
      extra_flags: T::Array[String],
      module_mode: T::Boolean,
      profile: T::Boolean,
      use_c_allocator: T::Boolean,
      default_stack: T.nilable(String),
      strict_test: T::Boolean,
      exact_tiers: T.nilable(ExactTiers),
      main_tier: T.nilable(Symbol),
      use_debug_allocator: T::Boolean,
      profile_max: T.nilable(Integer)
    ).returns(BuildSignature)
  end
  def self.build_signature(config:, source:, output:, opt_level:, extra_flags:, module_mode:, profile:,
                           use_c_allocator:, default_stack:, strict_test:, exact_tiers:, main_tier: nil,
                           use_debug_allocator: false, profile_max: nil)
    {
      "source" => File.expand_path(source),
      "output" => File.expand_path(output),
      "opt_level" => opt_level,
      "extra_flags" => extra_flags,
      "module_mode" => module_mode,
      "profile" => profile,
      "profile_max" => profile_max,
      "use_c_allocator" => use_c_allocator,
      "use_debug_allocator" => use_debug_allocator,
      "default_stack" => default_stack,
      "strict_test" => strict_test,
      "exact_tiers" => exact_tiers&.transform_keys(&:to_s),
      "main_tier" => main_tier,
      "zig" => config.zig_path
    }
  end

  sig { params(output: String).returns(T.nilable(BuildSignature)) }
  def self.read_build_signature(output)
    meta_path = build_metadata_path(output)
    return nil unless File.exist?(meta_path)

    parsed = JSON.parse(File.read(meta_path))
    return nil unless parsed.is_a?(Hash)

    T.cast(parsed, BuildSignature)
  rescue JSON::ParserError
    nil
  end

  sig { params(output: String, signature: BuildSignature).returns(T::Boolean) }
  def self.write_build_signature(output, signature)
    write_if_changed(build_metadata_path(output), JSON.pretty_generate(signature))
  end

  sig { params(pkg_name: String, start_dir: String).returns(T.nilable(String)) }
  def self.find_package_source(pkg_name, start_dir:)
    dir = File.expand_path(start_dir)
    loop do
      candidate = File.join(dir, "packages", pkg_name, "src", "lib.cht")
      return candidate if File.exist?(candidate)

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    nil
  end

  sig { params(raw: String, caller_dir: String).returns(String) }
  def self.resolve_clear_require(raw, caller_dir:)
    if raw.start_with?("pkg:")
      pkg_name = raw.sub(/\Apkg:/, "")
      pkg_path = find_package_source(pkg_name, start_dir: caller_dir)
      raise PackageMissingError, "Package '#{pkg_name}' not found from #{caller_dir}" unless pkg_path

      pkg_path
    else
      File.expand_path(raw, caller_dir)
    end
  end

  sig { params(path: String).returns(T::Set[String]) }
  def self.collect_clear_dependencies(path)
    seen = T.let(Set.new, T::Set[String])
    collect_clear_dependencies_into(File.expand_path(path), seen)
    seen
  end

  sig { params(source: String, config: Config).returns(Time) }
  def self.newest_build_dependency_mtime(source, config:)
    dep_paths = collect_clear_dependencies(source).to_a
    compiler_paths = Dir.glob(File.join(config.src_dir, "**", "*.rb"))
    runtime_paths = Dir.glob(File.join(config.zig_dir, "runtime", "**", "*.zig")) +
                    Dir.glob(File.join(config.zig_dir, "runtime", "**", "*.S")) +
                    Dir.glob(File.join(config.zig_dir, "lib", "**", "*.zig"))
    tracked = dep_paths + compiler_paths + runtime_paths + [config.script_path]
    tracked.filter_map { |path| File.exist?(path) ? File.mtime(path) : nil }.max || Time.at(0)
  end

  sig do
    params(
      source: String,
      output: String,
      signature: BuildSignature,
      config: Config,
      force: T::Boolean,
      module_mode: T::Boolean,
      profile: T::Boolean
    ).returns(T::Boolean)
  end
  def self.build_up_to_date?(source:, output:, signature:, config:, force:, module_mode:, profile:)
    return false if force || module_mode || profile
    return false unless File.exist?(output)

    File.mtime(output) >= newest_build_dependency_mtime(source, config: config) &&
      read_build_signature(output) == signature
  end

  sig { params(config: Config).returns(String) }
  def self.compiler_signature(config)
    key = [config.src_dir, config.zig_dir].join("\0")
    cached = @compiler_signatures[key]
    return cached if cached

    tracked = Dir.glob(File.join(config.src_dir, "**", "*.rb")).sort +
              Dir.glob(File.join(config.zig_dir, "runtime", "runtime-footer.zig")).sort +
              Dir.glob(File.join(config.zig_dir, "runtime", "runtime-header.zig")).sort
    digest = Digest::SHA256.new
    tracked.each do |path|
      digest << path
      digest << File.read(path)
    end
    @compiler_signatures[key] = digest.hexdigest
  end

  sig { params(source_path: String).returns(String) }
  def self.transpile_dependency_signature(source_path)
    digest = Digest::SHA256.new
    collect_clear_dependencies(source_path).to_a.sort.each do |path|
      digest << File.expand_path(path)
      digest << File.read(path)
    end
    digest.hexdigest
  end

  sig do
    params(
      config: Config,
      source_path: String,
      mode: Symbol,
      transpile_flag: String,
      source_text: String
    ).returns(String)
  end
  def self.transpile_cache_key(config:, source_path:, mode:, transpile_flag:, source_text:)
    Digest::SHA256.hexdigest([
      mode,
      transpile_flag,
      compiler_signature(config),
      transpile_dependency_signature(source_path),
      File.expand_path(source_path),
      source_text
    ].join("\0"))
  end

  sig do
    params(
      config: Config,
      source_path: String,
      mode: Symbol,
      transpile_flag: String,
      source_text: String,
      bypass: T::Boolean,
      debug_cache: T::Boolean,
      debug_stream: DebugStream,
      runner: T.nilable(TranspileRunner)
    ).returns([String, String])
  end
  def self.transpile_cached(config:, source_path:, mode:, transpile_flag:, source_text:, bypass: false,
                            debug_cache: false, debug_stream: $stderr, runner: nil)
    cache_key = transpile_cache_key(
      config: config,
      source_path: source_path,
      mode: mode,
      transpile_flag: transpile_flag,
      source_text: source_text
    )
    cache_file = File.join(config.transpiler_cache_dir, "#{cache_key}.zig")

    if !bypass && File.exist?(cache_file)
      emit_debug_cache("hit #{mode} #{File.basename(source_path)}", enabled: debug_cache, stream: debug_stream)
      return [File.read(cache_file), cache_file]
    end

    emit_debug_cache("#{bypass ? 'bypass' : 'miss'} #{mode} #{File.basename(source_path)}",
      enabled: debug_cache, stream: debug_stream)
    zig_code = runner ? runner.call(config, transpile_flag, source_path) : run_transpiler(config, transpile_flag, source_path)
    raise TranspileError, "Transpilation failed" unless zig_code

    write_if_changed(cache_file, zig_code)
    [zig_code, cache_file]
  end

  sig { params(config: Config, transpile_flag: String, source_path: String).returns(T.nilable(String)) }
  def self.run_transpiler(config, transpile_flag, source_path)
    flag_part = transpile_flag.empty? ? "" : "#{transpile_flag} "
    cmd = "ruby #{Shellwords.escape(config.transpiler_path)} #{flag_part}#{Shellwords.escape(source_path)}"
    zig_code = `#{cmd} 2>/dev/null`
    return zig_code if $?.success?

    system("#{cmd} > /dev/null")
    nil
  end

  sig { params(message: String, enabled: T::Boolean, stream: DebugStream).void }
  def self.emit_debug_cache(message, enabled:, stream:)
    stream.puts("[transpile-cache] #{message}") if enabled
  end

  sig { params(path: String, seen: T::Set[String]).void }
  private_class_method def self.collect_clear_dependencies_into(path, seen)
    return if seen.include?(path)
    raise FileMissingError, "File not found: #{path}" unless File.exist?(path)

    seen.add(path)
    source = File.read(path)
    caller_dir = File.dirname(path)
    source.scan(/REQUIRE\s+"([^"]+)"/).flatten.uniq.each do |raw|
      dep_path = resolve_clear_require(T.must(raw), caller_dir: caller_dir)
      collect_clear_dependencies_into(dep_path, seen)
    end
  end
end
