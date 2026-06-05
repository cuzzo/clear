# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "open3"
require_relative "zig_coverage_sanitize"

# Shared kcov wrapper for generated Zig test runners.
#
# `zig build test -Dcoverage` is a build.zig option, not a raw `zig test`
# option. Generated CLEAR/fuzz/corpus bundles use raw `zig test`, so coverage
# mode compiles the test binary without executing it, then runs that binary
# under kcov with repo-relative Zig paths.
module ZigCoverageSupport
  ROOT = File.expand_path("..", __dir__)
  ZIG_DIR = File.join(ROOT, "zig")

  class Error < StandardError; end

  TRUTHY = %w[1 true yes on].freeze
  KCOV_CODECOV_EXCLUDE_PATTERN = "-test.zig,-vopr.zig,-loom.zig,/vopr-,/loom-,/all-tests.zig,/all-fuzz.zig,/._clear_cov_".freeze
  SANITIZER_REMOVALS_FILE = ".zig-coverage-sanitizer-removals.json"

  def self.enabled?
    TRUTHY.include?(ENV.fetch("ZIG_COVERAGE", "0").downcase) ||
      TRUTHY.include?(ENV.fetch("CLEAR_ZIG_COVERAGE", "0").downcase)
  end

  def self.output_root(default_suite)
    override = ENV["ZIG_COVERAGE_DIR"]
    return File.expand_path(override, ROOT) if override && !override.empty?

    suite = ENV.fetch("ZIG_COVERAGE_SUITE", default_suite)
    File.join(ZIG_DIR, "zig-out", "coverage-#{sanitize_name(suite)}")
  end

  def self.sanitize_name(name)
    sanitized = name.to_s.gsub(%r{[^0-9A-Za-z_.-]+}, "_").sub(/\A_+/, "").sub(/_+\z/, "")
    sanitized.empty? ? "run" : sanitized
  end

  def self.kcov_available?
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, "kcov")
      File.file?(path) && File.executable?(path)
    end
  end

  def self.require_kcov!
    return if kcov_available?

    raise Error, "ZIG_COVERAGE=1 requires kcov on PATH"
  end

  def self.run_zig_test(zig:, build_dir:, args:, suite:, name:, env: {}, run_dir: nil)
    return Open3.capture2e(env, zig, "test", *args, chdir: build_dir) unless enabled?

    require_kcov!

    root = output_root(suite)
    FileUtils.mkdir_p(root)
    run_name = sanitize_name(name)
    bin_path = File.join(build_dir, ".zig-coverage-#{run_name}-#{$$}")
    compile_args = [
      zig,
      "test",
      *args,
      "-fllvm",
      "-fno-strip",
      "--test-no-exec",
      "-femit-bin=#{bin_path}",
    ]

    compile_output, compile_status = Open3.capture2e(env, *compile_args, chdir: build_dir)
    return [compile_output, compile_status] unless compile_status.success?

    kcov_dir = File.join(root, run_name)
    FileUtils.mkdir_p(kcov_dir)
    kcov_args = [
      "kcov",
      "--clean",
      "--include-path=#{ZIG_DIR}",
      "--strip-path=#{ROOT}/",
      "--exclude-pattern=#{KCOV_CODECOV_EXCLUDE_PATTERN}",
      kcov_dir,
      bin_path,
    ]
    run_output, run_status = Open3.capture2e(env, *kcov_args, chdir: run_dir || build_dir)
    sanitize_coverage_run!(kcov_dir, bin_path) if run_status.success?
    [compile_output + run_output, run_status]
  ensure
    FileUtils.rm_f(bin_path) if bin_path && ENV["ZIG_COVERAGE_KEEP_BIN"] != "1"
  end

  def self.merge!(suite)
    return unless enabled?

    require_kcov!
    root = output_root(suite)
    return unless Dir.exist?(root)

    inputs = Dir.children(root)
                .reject { |entry| entry == "merged" }
                .map { |entry| File.join(root, entry) }
                .select { |path| File.directory?(path) }
                .sort
    return if inputs.empty?

    merged = File.join(root, "merged")
    FileUtils.mkdir_p(merged)
    output, status = Open3.capture2e(
      "kcov",
      "--merge",
      "--exclude-pattern=#{KCOV_CODECOV_EXCLUDE_PATTERN}",
      merged,
      *inputs,
      chdir: ROOT,
    )
    raise Error, "kcov merge failed for #{root}:\n#{output}" unless status.success?

    xml_path = File.join(merged, "kcov-merged", "cobertura.xml")
    removals = ZigCoverageSanitizer.sanitize_file!(xml_path, allowed_removals: proof_backed_removal_keys(root))
    unless removals.empty?
      warn "Zig coverage sanitizer removed #{removals.length} proof-backed merged orphan runtime-header hit(s): #{ZigCoverageSanitizer.format_hits(removals)}"
    end
    ZigCoverageSanitizer.assert_no_orphan_hits!(xml_path)
    xml_path
  end

  def self.sanitize_coverage_run!(kcov_dir, bin_path)
    all_removals = []
    coverage_xml_paths(kcov_dir).each do |xml_path|
      removals = ZigCoverageSanitizer.sanitize_file!(xml_path, binary: bin_path)
      all_removals.concat(removals)
      unless removals.empty?
        warn "Zig coverage sanitizer removed #{removals.length} proof-backed orphan runtime-header hit(s): #{ZigCoverageSanitizer.format_hits(removals)}"
      end
      ZigCoverageSanitizer.assert_no_orphan_hits!(xml_path)
    end
    write_sanitizer_removals!(kcov_dir, all_removals)
    all_removals
  end

  def self.coverage_xml_paths(kcov_dir)
    return [] unless Dir.exist?(kcov_dir)

    paths = []
    Find.find(kcov_dir) do |path|
      if File.directory?(path)
        Find.prune if File.basename(path) == "kcov-merged"
        next
      end

      paths << path if File.basename(path) == "cobertura.xml"
    end
    paths.sort
  end

  def self.write_sanitizer_removals!(kcov_dir, removals)
    path = File.join(kcov_dir, SANITIZER_REMOVALS_FILE)
    if removals.empty?
      FileUtils.rm_f(path)
      return
    end

    payload = removals.map do |removal|
      {
        "file" => removal.file,
        "function" => removal.function,
        "line" => removal.line,
        "hits" => removal.hits,
      }
    end
    File.write(path, JSON.pretty_generate(payload))
  end

  def self.proof_backed_removal_keys(root)
    return {} unless Dir.exist?(root)

    Dir.children(root).each_with_object({}) do |entry, keys|
      next if entry == "merged"

      marker = File.join(root, entry, SANITIZER_REMOVALS_FILE)
      next unless File.file?(marker)

      JSON.parse(File.read(marker)).each do |row|
        keys[ZigCoverageSanitizer.removal_key(row.fetch("file"), row.fetch("function"), row.fetch("line"))] = true
      end
    end
  end
end
