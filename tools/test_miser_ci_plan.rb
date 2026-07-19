#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "optparse"
require "pathname"

module TestMiserCIPlan
  class Error < StandardError; end

  class Planner
    RUBY_SOURCE_PREFIX = "gems/espalier/lib/"
    RUBY_FULL_PREFIXES = ["gems/espalier/test/"].freeze
    RUBY_FULL_FILES = [
      "gems/espalier/espalier.gemspec",
      "gems/espalier/script/test_miser_mutant_setup.rb"
    ].freeze
    ZIG_FULL_FILES = ["zig/build.zig", "zig/build.zig.zon"].freeze

    def initialize(root:, base:, zig_manifest:, lines_per_shard: 40, max_ruby_jobs: 6, max_zig_jobs: 12)
      @root = File.expand_path(root)
      @base = base
      @zig_manifest = zig_manifest
      @lines_per_shard = lines_per_shard
      @max_ruby_jobs = max_ruby_jobs
      @max_zig_jobs = max_zig_jobs
    end

    def call
      changed = changed_lines
      {
        "base" => @base,
        "ruby" => ruby_plan(changed),
        "zig" => zig_plan(changed)
      }
    end

    private

    def ruby_plan(changed)
      sources = changed.keys.select { |path| path.start_with?(RUBY_SOURCE_PREFIX) && path.end_with?(".rb") }
      full = changed.keys.any? do |path|
        RUBY_FULL_FILES.include?(path) || RUBY_FULL_PREFIXES.any? { |prefix| path.start_with?(prefix) }
      end
      run = full || !sources.empty?
      weight = if full
        [changed.values.sum, @lines_per_shard * @max_ruby_jobs].max
      else
        sources.sum { |path| changed.fetch(path) }
      end
      count = run ? shard_count(weight, @max_ruby_jobs) : 0
      mode = full ? "full" : "diff"
      {
        "run" => run,
        "mode" => mode,
        "changed_lines" => weight,
        "matrix" => {
          "include" => (1..count).map do |index|
            { "index" => index, "index0" => index - 1, "total" => count, "mode" => mode }
          end
        }
      }
    end

    def zig_plan(changed)
      manifest_path = File.join(@root, @zig_manifest)
      manifest = JSON.parse(File.read(manifest_path))
      global_full = (ZIG_FULL_FILES + [@zig_manifest]).any? { |path| changed.key?(path) }
      tasks = Array(manifest.fetch("subjects")).filter_map do |subject|
        source = subject.fetch("source")
        next unless File.file?(File.join(@root, source))

        test_files = subject.fetch("test_command").scan(/-Dtest-file=([^\s&]+)/).flatten.map { |path| File.basename(path) }
        test_changed = changed.keys.any? do |path|
          path.end_with?(".zig") && test_files.include?(File.basename(path))
        end
        source_changed = changed.key?(source)
        next unless global_full || test_changed || source_changed

        mode = (global_full || test_changed) ? "full" : "diff"
        weight = mode == "full" ? @lines_per_shard * 2 : changed.fetch(source, 1)
        {
          "token" => Digest::SHA256.hexdigest(source)[0, 10],
          "source" => source,
          "test_command" => subject.fetch("test_command"),
          "timeout" => subject.fetch("timeout_seconds", 120),
          "mode" => mode,
          "weight" => weight,
          "desired" => shard_count(weight, @max_zig_jobs),
          "count" => 1
        }
      end
      allocate_zig_jobs(tasks)
      matrix = tasks.flat_map do |task|
        (0...task.fetch("count")).map do |index|
          task.slice("token", "source", "test_command", "timeout", "mode").merge(
            "index" => index + 1,
            "index0" => index,
            "total" => task.fetch("count")
          )
        end
      end
      {
        "run" => !matrix.empty?,
        "matrix" => { "include" => matrix }
      }
    rescue JSON::ParserError, KeyError => error
      raise Error, "invalid Zig Mutants manifest #{@zig_manifest}: #{error.message}"
    end

    def allocate_zig_jobs(tasks)
      budget = [@max_zig_jobs, tasks.length].max
      while tasks.sum { |task| task.fetch("count") } < budget
        candidate = tasks.select { |task| task.fetch("count") < task.fetch("desired") }
          .max_by { |task| task.fetch("weight").fdiv(task.fetch("count")) }
        break unless candidate

        candidate["count"] += 1
      end
    end

    def shard_count(weight, maximum)
      [[(weight.to_f / @lines_per_shard).ceil, 1].max, maximum].min
    end

    def changed_lines
      output, status = Open3.capture2e("git", "diff", "--numstat", @base, "--", chdir: @root)
      raise Error, "git diff failed for #{@base}: #{output}" unless status.success?

      output.lines.to_h do |line|
        added, deleted, path = line.chomp.split("\t", 3)
        count = [added, deleted].sum { |value| Integer(value, exception: false) || 0 }
        [normalize_rename(path), [count, 1].max]
      end
    end

    def normalize_rename(path)
      return path unless path.include?(" => ")

      if (match = /\A(.*)\{.* => (.*)\}(.*)\z/.match(path))
        "#{match[1]}#{match[2]}#{match[3]}"
      else
        path.split(" => ", 2).last
      end
    end
  end

  module_function

  def write_github_outputs(path, plan)
    File.open(path, "a") do |output|
      output.puts "base=#{plan.fetch('base')}"
      output.puts "ruby_run=#{plan.dig('ruby', 'run')}"
      output.puts "ruby_mode=#{plan.dig('ruby', 'mode')}"
      output.puts "ruby_matrix=#{JSON.generate(plan.dig('ruby', 'matrix'))}"
      output.puts "zig_run=#{plan.dig('zig', 'run')}"
      output.puts "zig_matrix=#{JSON.generate(plan.dig('zig', 'matrix'))}"
    end
  end

  def main(argv)
    options = {
      root: Dir.pwd,
      zig_manifest: "gems/zig-mutants/subjects.json",
      lines_per_shard: 40,
      max_ruby_jobs: 6,
      max_zig_jobs: 12,
      github_output: ENV["GITHUB_OUTPUT"]
    }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: test_miser_ci_plan.rb --base REVISION [options]"
      opts.on("--base REVISION", "PR base revision") { |value| options[:base] = value }
      opts.on("--root DIR", "Repository root") { |value| options[:root] = value }
      opts.on("--zig-manifest FILE", "Zig Mutants subject manifest") { |value| options[:zig_manifest] = value }
      opts.on("--lines-per-shard N", Integer, "Changed-line target per job") { |value| options[:lines_per_shard] = value }
      opts.on("--max-ruby-jobs N", Integer, "Maximum Ruby jobs") { |value| options[:max_ruby_jobs] = value }
      opts.on("--max-zig-jobs N", Integer, "Maximum Zig jobs") { |value| options[:max_zig_jobs] = value }
      opts.on("--github-output FILE", "Append GitHub Actions outputs") { |value| options[:github_output] = value }
      opts.on("-h", "--help", "Show this help") { puts opts; return 0 }
    end
    parser.parse!(argv)
    raise Error, "--base is required" unless options[:base]
    unless options.values_at(:lines_per_shard, :max_ruby_jobs, :max_zig_jobs).all?(&:positive?)
      raise Error, "job and line limits must be positive"
    end

    plan = Planner.new(**options.slice(
      :root, :base, :zig_manifest, :lines_per_shard, :max_ruby_jobs, :max_zig_jobs
    )).call
    puts JSON.pretty_generate(plan)
    write_github_outputs(options[:github_output], plan) if options[:github_output]
    0
  rescue Error, Errno::ENOENT => error
    warn "test-miser CI plan: #{error.message}"
    1
  end
end

exit TestMiserCIPlan.main(ARGV) if $PROGRAM_NAME == __FILE__
