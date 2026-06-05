# frozen_string_literal: true

require "fileutils"
require "open3"
require "rexml/document"

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
  COVERAGE_SOURCE_LINE_SKIP = [
    /\A\s*\z/,
    /\A\s*\/\//,
  ].freeze

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

    cobertura = File.join(merged, "kcov-merged", "cobertura.xml")
    expand_cobertura!(cobertura)
    cobertura
  end

  def self.expand_cobertura!(path, zig_dir: ZIG_DIR)
    return unless File.exist?(path)

    doc = REXML::Document.new(File.read(path))
    classes = REXML::XPath.match(doc, "//class")
    changed = false

    classes.each do |klass|
      filename = klass.attributes["filename"].to_s.sub(%r{\A\./}, "")
      source = source_path_for_coverage_filename(filename, zig_dir)
      next unless source

      tracked = line_hits_for_class(klass)
      source_line_numbers(source).each { |line| tracked[line] ||= 0 }
      changed = true if tracked.size != REXML::XPath.match(klass, "lines/line").size
      rewrite_class_lines!(klass, tracked)
    end

    rewrite_cobertura_totals!(doc)
    File.write(path, xml_string(doc)) if changed
  end

  def self.source_path_for_coverage_filename(filename, zig_dir)
    candidates = [
      File.join(zig_dir, filename),
      File.join(ROOT, filename),
    ]
    candidates.find { |candidate| File.file?(candidate) }
  end

  def self.source_line_numbers(path)
    File.readlines(path).each_with_index.filter_map do |line, idx|
      next if COVERAGE_SOURCE_LINE_SKIP.any? { |pattern| line.match?(pattern) }

      idx + 1
    end
  end

  def self.line_hits_for_class(klass)
    REXML::XPath.match(klass, "lines/line").each_with_object({}) do |line, hits|
      number = line.attributes["number"].to_i
      current = hits.fetch(number, 0)
      hits[number] = [current, line.attributes["hits"].to_i].max
    end
  end

  def self.rewrite_class_lines!(klass, hits)
    lines = klass.elements["lines"] || klass.add_element("lines")
    lines.elements.delete_all("line")
    hits.keys.sort.each do |number|
      line = lines.add_element("line")
      line.add_attribute("number", number.to_s)
      line.add_attribute("hits", hits[number].to_s)
    end
    valid = hits.size
    covered = hits.values.count(&:positive?)
    klass.add_attribute("line-rate", rate(covered, valid))
  end

  def self.rewrite_cobertura_totals!(doc)
    total_valid = 0
    total_covered = 0
    REXML::XPath.each(doc, "//class") do |klass|
      hits = line_hits_for_class(klass)
      total_valid += hits.size
      total_covered += hits.values.count(&:positive?)
    end

    REXML::XPath.each(doc, "/coverage|//package") do |element|
      element.add_attribute("lines-valid", total_valid.to_s) if element.name == "coverage"
      element.add_attribute("lines-covered", total_covered.to_s) if element.name == "coverage"
      element.add_attribute("line-rate", rate(total_covered, total_valid))
    end
  end

  def self.rate(covered, valid)
    return "1.0" if valid.zero?

    format("%.3f", covered.to_f / valid)
  end

  def self.xml_string(doc)
    out = +""
    formatter = REXML::Formatters::Default.new
    formatter.write(doc, out)
    out
  end
end
