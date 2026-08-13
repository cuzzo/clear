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

    temporary = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
    begin
      File.binwrite(temporary, content)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary)
    end
    true
  end

  # The per-program build caches live on a tmpfs that fills after a few dozen
  # large builds, and a full cache is reported as `DWARF TODO: 'NoSpaceLeft'`
  # rather than as a disk error. Drop the ones nobody has touched in a while.
  #
  # Age, not entry count, is the only safe criterion: parallel workers each
  # build their own cache key, so a count-based rule deletes a directory
  # another process is building into and that process then fails to symlink
  # into its own cache.
  CACHE_ENTRY_MAX_AGE_SECONDS = 3600

  sig { params(cache_root: String, keep: String).void }
  def self.prune_build_cache!(cache_root, keep:)
    keep_real = File.expand_path(keep)
    # This build is using its directory now, whether or not it just created it.
    FileUtils.touch(keep) if File.directory?(keep)
    cutoff = Time.now - CACHE_ENTRY_MAX_AGE_SECONDS
    Dir.glob(File.join(cache_root, '*')).each do |path|
      next unless File.directory?(path)
      next if File.expand_path(path) == keep_real
      next if File.mtime(path) > cutoff

      FileUtils.rm_rf(path)
    end
  rescue StandardError
    # Pruning is opportunistic; a build must never fail because of it.
    nil
  end

  # A build killed mid-run (ENOSPC, timeout, SIGKILL) never reaches its
  # rm_rf, so `.build-<pid>` directories accumulate. Reap the ones whose
  # process is gone.
  sig { params(zig_dir: String).void }
  def self.reap_orphan_build_dirs!(zig_dir)
    Dir.glob(File.join(zig_dir, '.build-*')).each do |path|
      pid = File.basename(path).delete_prefix('.build-').to_i
      next if pid <= 0 || pid == Process.pid

      begin
        Process.kill(0, pid)
        next # still running
      rescue Errno::ESRCH
        FileUtils.rm_rf(path)
      rescue Errno::EPERM
        next # someone else's process
      end
    end
  rescue StandardError
    nil
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
      profile_max: T.nilable(Integer),
      ownership_mode: Symbol
    ).returns(BuildSignature)
  end
  def self.build_signature(config:, source:, output:, opt_level:, extra_flags:, module_mode:, profile:,
                           use_c_allocator:, default_stack:, strict_test:, exact_tiers:, main_tier: nil,
                           use_debug_allocator: false, profile_max: nil, ownership_mode: :default)
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
      "ownership_mode" => ownership_mode.to_s,
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

  @registered_packages = T.let({}, T::Hash[String, String])

  # Generated package trees (e.g. ruby-to-clear "rtoc_..." modules) live outside
  # the packages/<name>/src/lib.clear layout, so builds register them explicitly
  # with --pkg name=/path. Registrations take precedence over discovery.
  sig { params(specs: T::Hash[String, String]).void }
  def self.register_packages(specs)
    specs.each do |name, path|
      # A comma-separated value registers a MULTI-FILE package: every member
      # must exist; the members compile together as one unit.
      resolved_list = path.to_s.split(",").map { |member| File.expand_path(member.strip) }
      resolved_list.each do |member|
        unless File.file?(member)
          raise BuildError, "--pkg #{name}=#{path}: package source not found: #{member}"
        end
      end

      @registered_packages[name] = resolved_list.join(",")
    end
  end

  sig { void }
  def self.clear_registered_packages!
    @registered_packages = {}
  end

  # Materialize a registered multi-file package as a single merged root
  # source file (used by `clear test pkg:<name>` / `clear build pkg:<name>`).
  # Returns the merged file path.
  sig { params(pkg_name: String).returns(String) }
  def self.materialize_package_root(pkg_name)
    registered = @registered_packages[pkg_name]
    raise BuildError, "pkg:#{pkg_name}: not registered (pass --pkg #{pkg_name}=a.clear,b.clear)" unless registered

    require "tmpdir"
    require_relative "../compiler/package_source"
    members = registered.split(",")
    merged = PackageSource.merge(members, resolve_pkg: ->(name) { @registered_packages[name] })
    out = File.join(Dir.tmpdir, "clear_pkg_#{pkg_name}.clear")
    File.write(out, merged.source)
    out
  end

  # Run `block` over `items` in forked workers purely for its cache side
  # effects, then return. Every expensive step behind it -- transpile_cached,
  # the module cache -- is content-addressed on disk, so a child populates
  # exactly what the serial pass that follows will look up. Nothing is read
  # back from the children, which is what keeps this to one call site instead
  # of threading results through the build.
  #
  # Falls back to serial when jobs <= 1 or fork is unavailable.
  sig do
    params(items: T::Array[T.untyped], jobs: Integer, block: T.proc.params(item: T.untyped).void).void
  end
  def self.prewarm_in_parallel(items, jobs:, &block)
    return if items.empty?
    if jobs <= 1 || !Process.respond_to?(:fork)
      items.each { |item| block.call(item) }
      return
    end

    queue = items.dup
    running = T.let({}, T::Hash[Integer, T::Boolean])
    until queue.empty? && running.empty?
      while running.size < jobs && !queue.empty?
        item = queue.shift
        pid = Process.fork do
          begin
            block.call(item)
          rescue StandardError, SystemExit
            # A warm-up failure is never fatal: the serial pass re-runs the
            # same work and reports the real diagnostic in the right order.
          end
          Process.exit!(0)
        end
        running[pid] = true
      end
      pid, _ = Process.wait2
      running.delete(pid)
    end
    nil
  end

  sig { params(pkg_name: String, start_dir: String).returns(T.nilable(String)) }
  def self.find_package_source(pkg_name, start_dir:)
    registered = @registered_packages[pkg_name]
    return registered if registered

    dir = File.expand_path(start_dir)
    loop do
      candidate = File.join(dir, "packages", pkg_name, "src", "lib.clear")
      return candidate if File.exist?(candidate)

      candidate = File.join(dir, "stdlib", pkg_name, "src", "lib.clear")
      return candidate if File.exist?(candidate)

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    nil
  end

  sig { params(pkg_name: String, start_dir: String).returns(T.nilable(String)) }
  def self.find_zig_package_source(pkg_name, start_dir:)
    dir = File.expand_path(start_dir)
    loop do
      candidate = File.join(dir, "packages", pkg_name, "src", "lib.zig")
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

  # A multi-file package registers as one comma-separated value. Anything that
  # walks a resolved REQUIRE as a filesystem path must see the members, not the
  # joined spec.
  sig { params(resolved: String).returns(T::Array[String]) }
  def self.package_member_paths(resolved)
    resolved.split(",").map { |member| member.strip }.reject(&:empty?)
  end

  # A member of a multi-file package never compiles alone, so requiring it by
  # its own single-file name really depends on the owning package. Returns
  # [name, spec] of that owner, or nil when the path stands on its own.
  sig { params(path: String).returns(T.nilable([String, String])) }
  def self.owning_package(path)
    expanded = File.expand_path(path)
    owner = @registered_packages.find do |_name, spec|
      spec.include?(",") && package_member_paths(spec).include?(expanded)
    end
    owner && [owner.fetch(0), owner.fetch(1)]
  end

  # The root compiler resolves imports before the package-module build pass.
  # Register every reachable package up front, including a package required by
  # another package and one reached through a local REQUIRE dependency.
  sig { params(source_path: String).returns(T::Hash[String, String]) }
  def self.collect_package_dependencies(source_path)
    packages = T.let({}, T::Hash[String, String])
    seen = T.let(Set.new, T::Set[String])
    collect_package_dependencies_into(File.expand_path(source_path), packages, seen)
    packages
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
      resolved = resolve_clear_require(T.must(raw), caller_dir: caller_dir)
      package_member_paths(resolved).each do |dep_path|
        collect_clear_dependencies_into(dep_path, seen)
      end
    end
  end

  sig do
    params(
      path: String,
      packages: T::Hash[String, String],
      seen: T::Set[String]
    ).void
  end
  private_class_method def self.collect_package_dependencies_into(path, packages, seen)
    return if seen.include?(path)
    raise FileMissingError, "File not found: #{path}" unless File.exist?(path)

    seen.add(path)
    source = File.read(path)
    caller_dir = File.dirname(path)
    source.scan(/REQUIRE\s+"([^"]+)"/).flatten.uniq.each do |raw|
      if raw.start_with?("pkg:")
        package_name = raw.delete_prefix("pkg:")
        package_path = find_package_source(package_name, start_dir: caller_dir)
        raise PackageMissingError, "Package '#{package_name}' not found from #{caller_dir}" unless package_path

        packages[package_name] ||= package_path
        # Requiring a member by its own name really depends on the owning
        # multi-file package; register that too so the importer can redirect
        # the member to the whole unit instead of splitting it.
        owner_name, owner_spec = owning_package(package_path)
        packages[owner_name] ||= owner_spec if owner_name
        package_member_paths(owner_spec || package_path).each do |member|
          collect_package_dependencies_into(member, packages, seen)
        end
      else
        collect_package_dependencies_into(File.expand_path(raw, caller_dir), packages, seen)
      end
    end
  end
end
