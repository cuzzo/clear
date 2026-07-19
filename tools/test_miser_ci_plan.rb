#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "optparse"

module TestMiserCIPlan
  class Error < StandardError; end

  class Planner
    ZIG_FULL_FILES = ["zig/build.zig", "zig/build.zig.zon"].freeze
    GLOBAL_RUBY_FILES = [
      "Gemfile", "Gemfile.lock", "gems/test-miser/config/ci-suites.json",
      "gems/test-miser/lib/test_miser/mutant_collector.rb",
      "gems/test-miser/lib/test_miser/runtime_map_collector.rb",
      "gems/test-miser/lib/test_miser/run_to_complete.rb",
      "gems/test-miser/lib/test_miser/run_to_complete_minitest.rb"
    ].freeze

    def initialize(
      root:, base:, zig_manifest:, suite_config: "gems/test-miser/config/ci-suites.json",
      lines_per_shard: 40, max_ruby_jobs: 6, max_zig_jobs: 12,
      canonical: false, force_full: false
    )
      @root = File.expand_path(root)
      @base = base
      @zig_manifest = zig_manifest
      @suite_config_path = suite_config
      @lines_per_shard = lines_per_shard
      @max_ruby_jobs = max_ruby_jobs
      @max_zig_jobs = max_zig_jobs
      @canonical = canonical
      @force_full = force_full
      @suite_config = JSON.parse(File.read(File.join(@root, suite_config)))
      raise Error, "unsupported suite config" unless @suite_config["schema"] == "test-miser-ci-suites/v1"
    rescue JSON::ParserError, Errno::ENOENT => error
      raise Error, "invalid Test Miser suite config #{suite_config}: #{error.message}"
    end

    def call
      changed = changed_lines
      ruby = ruby_plan(changed)
      rust = native_plan(changed, "rust")
      go = native_plan(changed, "go")
      zig = zig_plan(changed)
      {
        "base" => @base,
        "required_suites" => required_suites,
        "ruby" => ruby,
        "rust" => rust,
        "go" => go,
        "zig" => zig
      }
    end

    private

    def required_suites
      %w[ruby rust go].flat_map do |language|
        Array(@suite_config[language]).select { |entry| entry.fetch("enabled", true) }.map { |entry| entry.fetch("suite") }
      end + ["zig:clear"]
    end

    def ruby_plan(changed)
      global_full = @force_full || changed.keys.any? { |path| GLOBAL_RUBY_FILES.include?(path) }
      tasks = Array(@suite_config["ruby"]).filter_map do |suite|
        next unless suite.fetch("enabled", true)

        source_root = suite.fetch("source_root")
        test_root = suite.fetch("test_root")
        source_changes = changed.keys.select { |path| path.start_with?("#{source_root}/") && path.end_with?(".rb") }
        gem_root = source_root.delete_suffix("/lib")
        full = global_full || changed.keys.any? do |path|
          path.start_with?("#{test_root}/") || path == "#{gem_root}/#{suite.fetch('id')}.gemspec" ||
            path.start_with?("#{gem_root}/script/")
        end
        next unless full || !source_changes.empty?

        weight = if full
          ruby_source_weight(source_root)
        else
          source_changes.sum { |path| changed.fetch(path) }
        end
        task = suite.merge(
          "token" => token(suite.fetch("suite")),
          "mode" => full ? "full" : "diff",
          "weight" => [weight, 1].max,
          "desired" => shard_count(weight, @max_ruby_jobs),
          "count" => 1
        )
        task["integration_arguments"] = suite["integration"] == "rspec" ? [test_root] : []
        task
      end
      allocate_jobs(tasks, @max_ruby_jobs)
      prepare = tasks.map { |task| task.except("weight", "desired", "count") }
      matrix = tasks.flat_map do |task|
        (0...task.fetch("count")).map do |index|
          task.except("weight", "desired", "count").merge(
            "index" => index + 1, "index0" => index, "total" => task.fetch("count")
          )
        end
      end
      {
        "run" => !matrix.empty?,
        "prepare_matrix" => { "include" => prepare },
        "matrix" => { "include" => matrix }
      }
    end

    def native_plan(changed, language)
      tasks = Array(@suite_config[language]).filter_map do |suite|
        next unless suite.fetch("enabled", true)

        glob = suite.fetch("source_glob")
        sources = Dir.glob(File.join(@root, glob)).select { |path| File.file?(path) }
          .map { |path| path.delete_prefix("#{@root}/") }.reject { |path| path.end_with?("_test.go") }.sort
        root = suite["crate_root"] || suite.fetch("module_root")
        source_changes = changed.keys.select { |path| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        deleted_source = source_changes.any? { |path| !File.file?(File.join(@root, path)) }
        support_change = changed.keys.any? do |path|
          path == @suite_config_path || path == "#{root}/Cargo.toml" || path == "#{root}/Cargo.lock" || path == "#{root}/go.mod" ||
            path == "#{root}/go.sum" || path.start_with?("#{root}/tests/") ||
            (suite["test_glob"] && File.fnmatch?(suite["test_glob"], path, File::FNM_PATHNAME | File::FNM_EXTGLOB))
        end
        affected = @force_full || support_change || !source_changes.empty?
        next unless affected

        full = @force_full || support_change || deleted_source || language == "go"

        selected = full ? sources : source_changes.select { |path| sources.include?(path) }
        suite.merge(
          "token" => token(suite.fetch("suite")),
          "mode" => full ? "full" : "components",
          "sources" => sources,
          "selected_components" => selected
        )
      end
      { "run" => !tasks.empty?, "matrix" => { "include" => tasks } }
    end

    def zig_plan(changed)
      manifest_path = File.join(@root, @zig_manifest)
      manifest = JSON.parse(File.read(manifest_path))
      global_full = @force_full || (ZIG_FULL_FILES + [@zig_manifest]).any? { |path| changed.key?(path) }
      tasks = Array(manifest.fetch("subjects")).filter_map do |subject|
        source = subject.fetch("source")
        next unless File.file?(File.join(@root, source))

        test_files = subject.fetch("test_command").scan(/-Dtest-file=([^\s&]+)/).flatten.map { |path| File.basename(path) }
        test_changed = changed.keys.any? do |path|
          path.end_with?(".zig") && test_files.include?(File.basename(path))
        end
        source_changed = changed.key?(source)
        next unless global_full || test_changed || source_changed

        mode = (global_full || test_changed || @canonical) ? "full" : "diff"
        weight = mode == "full" ? @lines_per_shard * 2 : changed.fetch(source, 1)
        {
          "token" => token(source), "source" => source,
          "test_command" => subject.fetch("test_command"),
          "timeout" => subject.fetch("timeout_seconds", 120),
          "mode" => mode, "weight" => weight,
          "desired" => @canonical ? 1 : shard_count(weight, @max_zig_jobs), "count" => 1
        }
      end
      allocate_jobs(tasks, @max_zig_jobs) unless @canonical
      matrix = tasks.flat_map do |task|
        (0...task.fetch("count")).map do |index|
          task.slice("token", "source", "test_command", "timeout", "mode").merge(
            "index" => index + 1, "index0" => index, "total" => task.fetch("count")
          )
        end
      end
      { "run" => !matrix.empty?, "matrix" => { "include" => matrix } }
    rescue JSON::ParserError, KeyError => error
      raise Error, "invalid Zig Mutants manifest #{@zig_manifest}: #{error.message}"
    end

    def ruby_source_weight(root)
      Dir.glob(File.join(@root, root, "**", "*.rb")).sum { |path| File.foreach(path).count }
    end

    def allocate_jobs(tasks, maximum)
      budget = [maximum, tasks.length].max
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

    def token(value)
      Digest::SHA256.hexdigest(value)[0, 10]
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
      output.puts "required_suites=#{JSON.generate(plan.fetch('required_suites'))}"
      %w[ruby rust go zig].each do |language|
        output.puts "#{language}_run=#{plan.dig(language, 'run')}"
        output.puts "#{language}_matrix=#{JSON.generate(plan.dig(language, 'matrix'))}"
      end
      output.puts "ruby_prepare_matrix=#{JSON.generate(plan.dig('ruby', 'prepare_matrix'))}"
    end
  end

  def main(argv)
    options = {
      root: Dir.pwd, zig_manifest: "gems/zig-mutants/subjects.json",
      suite_config: "gems/test-miser/config/ci-suites.json",
      lines_per_shard: 40, max_ruby_jobs: 6, max_zig_jobs: 12,
      canonical: false, force_full: false, github_output: ENV["GITHUB_OUTPUT"]
    }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: test_miser_ci_plan.rb --base REVISION [options]"
      opts.on("--base REVISION") { |value| options[:base] = value }
      opts.on("--root DIR") { |value| options[:root] = value }
      opts.on("--zig-manifest FILE") { |value| options[:zig_manifest] = value }
      opts.on("--suite-config FILE") { |value| options[:suite_config] = value }
      opts.on("--lines-per-shard N", Integer) { |value| options[:lines_per_shard] = value }
      opts.on("--max-ruby-jobs N", Integer) { |value| options[:max_ruby_jobs] = value }
      opts.on("--max-zig-jobs N", Integer) { |value| options[:max_zig_jobs] = value }
      opts.on("--canonical") { options[:canonical] = true }
      opts.on("--force-full") { options[:force_full] = true }
      opts.on("--github-output FILE") { |value| options[:github_output] = value }
      opts.on("-h", "--help") { puts opts; return 0 }
    end
    parser.parse!(argv)
    raise Error, "--base is required" unless options[:base]
    unless options.values_at(:lines_per_shard, :max_ruby_jobs, :max_zig_jobs).all?(&:positive?)
      raise Error, "job and line limits must be positive"
    end

    plan = Planner.new(**options.slice(
      :root, :base, :zig_manifest, :suite_config, :lines_per_shard,
      :max_ruby_jobs, :max_zig_jobs, :canonical, :force_full
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
