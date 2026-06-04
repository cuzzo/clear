# frozen_string_literal: true

require "fileutils"
require "open3"

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
      kcov_dir,
      bin_path,
    ]
    run_output, run_status = Open3.capture2e(env, *kcov_args, chdir: run_dir || build_dir)
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
    output, status = Open3.capture2e("kcov", "--merge", merged, *inputs, chdir: ROOT)
    raise Error, "kcov merge failed for #{root}:\n#{output}" unless status.success?

    File.join(merged, "kcov-merged", "cobertura.xml")
  end
end
