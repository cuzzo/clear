# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"
require "zlib"

module Espalier
  # Manifest-driven producer for source-analyzed standard-library complexity
  # summaries. Language-specific build and source selection live in YAML; the
  # indexing, FactMine profiling, soundness checks, export, consumer comparison,
  # and publication flow are shared.
  class StdlibMap
    SCHEMA = "fact-mine.stdlib-map.v1"
    SUMMARY_SCHEMA = "fact-mine.external-complexity-summary.v2"

    class CommandRunner
      def run!(command, chdir:, env: {})
        warn "$ (cd #{Shellwords.escape(chdir)} && #{display_command(command)})"
        success = system(env, *command, chdir: chdir)
        raise "command failed: #{display_command(command)}" unless success
      end

      def capture(command, chdir:, env: {})
        stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
        [stdout, stderr, status]
      end

      private

      def display_command(command)
        shown = command.first(12).map { |argument| Shellwords.escape(argument) }
        shown << "... (#{command.length} arguments)" if command.length > shown.length
        shown.join(" ")
      end
    end

    attr_reader :manifest, :manifest_path

    def self.run_cli(arguments)
      options = {
        work_dir: nil,
        keep_work: false,
        index_override: nil,
        source_root_override: nil,
        summary_output: nil,
        fact_mine: nil
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: espalier stdlib-map --manifest FILE [options]"
        opts.on("--manifest FILE", "Mapping manifest") { |value| options[:manifest] = value }
        opts.on("--work-dir DIR", "Retain intermediate index/profile artifacts here") do |value|
          options[:work_dir] = value
        end
        opts.on("--keep-work", "Keep an automatically-created work directory") do
          options[:keep_work] = true
        end
        opts.on("--index FILE", "Reuse an existing SCIP index") do |value|
          options[:index_override] = value
        end
        opts.on("--source-root DIR", "Reuse an existing pinned source checkout") do |value|
          options[:source_root_override] = value
        end
        opts.on("--output FILE", "Override the summary output path") do |value|
          options[:summary_output] = value
        end
        opts.on("--fact-mine FILE", "FactMine Rust binary") { |value| options[:fact_mine] = value }
      end
      parser.parse!(arguments)
      raise ArgumentError, parser.to_s unless arguments.empty? && options[:manifest]

      new(
        options.fetch(:manifest),
        work_dir: options.fetch(:work_dir),
        keep_work: options.fetch(:keep_work),
        index_override: options.fetch(:index_override),
        source_root_override: options.fetch(:source_root_override),
        summary_output: options.fetch(:summary_output),
        fact_mine: options.fetch(:fact_mine)
      ).run
      0
    rescue StandardError => error
      warn "stdlib-map failed: #{error.message}"
      1
    end

    def initialize(manifest_path, work_dir: nil, keep_work: false, index_override: nil,
                   source_root_override: nil,
                   summary_output: nil, fact_mine: nil, runner: CommandRunner.new)
      @manifest_path = File.expand_path(manifest_path)
      @manifest_dir = File.dirname(@manifest_path)
      @workspace_root = File.expand_path("../../../..", __dir__)
      @manifest = load_manifest
      @keep_work = keep_work
      @owned_work_dir = work_dir.nil?
      @work_dir = File.expand_path(work_dir || Dir.mktmpdir("fact-mine-stdlib-map-"))
      @index_override = index_override && File.expand_path(index_override)
      @source_root_override = source_root_override && File.expand_path(source_root_override)
      @summary_output_override = summary_output && File.expand_path(summary_output)
      @fact_mine_override = fact_mine && File.expand_path(fact_mine)
      @runner = runner
      validate_manifest!
    end

    def run
      FileUtils.mkdir_p(@work_dir)
      source_root = resolve_source_root
      source_revision = verify_source_revision(source_root)
      prepare_source(source_root)
      files = source_files(source_root)
      analysis_root, files = stage_selected_source(source_root, files)
      index = produce_index(analysis_root)
      profile = File.join(@work_dir, "stdlib.profile.json")
      run_profile(files, index, profile)
      profile_data = JSON.parse(File.read(profile))
      profile_validation = validate_profile!(profile_data, files)

      producer_summary = File.join(@work_dir, "stdlib.producer-summary.json.gz")
      export_summary(profile, producer_summary, relocate: false)
      producer_summary_data = read_json(producer_summary)
      producer_validation = validate_summary!(producer_summary_data, relocated: false)
      producer_join_validation = verify_summary_join(profile_data, producer_summary_data)

      relocation = fetch_hash(manifest, "summary")["symbol_relocation"]
      staged_summary = if relocation
                         path = File.join(@work_dir, "stdlib.summary.json.gz")
                         export_summary(profile, path, relocate: true)
                         path
                       else
                         producer_summary
                       end
      summary_validation = validate_summary!(read_json(staged_summary), relocated: !relocation.nil?)
      consumer_results = run_consumer_checks(staged_summary)

      output = summary_output
      publish_summary(staged_summary, output)
      report = {
        "schema" => "fact-mine.stdlib-map-report.v1",
        "manifest" => manifest_path,
        "language" => manifest.fetch("language"),
        "source_root" => source_root,
        "analysis_root" => analysis_root,
        "source_revision" => source_revision,
        "source_files" => files.length,
        "index" => index,
        "profile" => profile_validation,
        "producer_summary" => producer_validation.merge(producer_join_validation),
        "summary" => summary_validation.merge("output" => output),
        "consumers" => consumer_results
      }
      report_path = File.join(@work_dir, "stdlib-map-report.json")
      File.write(report_path, JSON.pretty_generate(report))
      puts JSON.pretty_generate(report)
      report
    ensure
      FileUtils.remove_entry(@work_dir) if @owned_work_dir && !@keep_work && File.exist?(@work_dir)
    end

    private

    def load_manifest
      raw = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
      expand_environment(raw)
    rescue Psych::Exception => error
      raise ArgumentError, "invalid stdlib manifest #{manifest_path}: #{error.message}"
    end

    def validate_manifest!
      raise ArgumentError, "unsupported stdlib manifest schema: #{manifest['schema'].inspect}" unless manifest["schema"] == SCHEMA
      raise ArgumentError, "language must be present" if manifest["language"].to_s.empty?
      source = fetch_hash(manifest, "source")
      if source["root"].to_s.empty? && !Array(source["root_command"]).any? && !source["git"]
        raise ArgumentError, "source.root, source.root_command, or source.git must be present"
      end
      includes = Array(source["include"])
      raise ArgumentError, "source.include must contain at least one glob" if includes.empty?
      raise ArgumentError, "source.revision must be present" if source["revision"].to_s.empty?
      if source["git"]
        git = fetch_hash(source, "git")
        raise ArgumentError, "source.git.repository must be present" if git["repository"].to_s.empty?
        raise ArgumentError, "source.git.commit must be present" if git["commit"].to_s.empty?
        unless git["commit"].match?(/\A[0-9a-f]{40}\z/)
          raise ArgumentError, "source.git.commit must be a full 40-character commit"
        end
      else
        revision_check = fetch_hash(source, "revision_check")
        unless Array(revision_check["command"]).any?
          raise ArgumentError, "source.revision_check.command must be present"
        end
        matches = Array(revision_check["includes"])
        exact = revision_check["equals"]
        if matches.empty? && exact.nil?
          raise ArgumentError, "source.revision_check requires equals or includes"
        end
        if !matches.empty? && !exact.nil?
          raise ArgumentError, "source.revision_check cannot use both equals and includes"
        end
      end

      index = fetch_hash(manifest, "index")
      unless @index_override || index["path"] || Array(index["command"]).any?
        raise ArgumentError, "index.path or index.command is required"
      end
      expected = fetch_hash(index, "expected")
      raise ArgumentError, "index.expected.tool is required" if expected["tool"].to_s.empty?
      raise ArgumentError, "index.expected.version is required" if expected["version"].to_s.empty?

      summary = fetch_hash(manifest, "summary")
      %w[corpus output].each do |key|
        raise ArgumentError, "summary.#{key} is required" if summary[key].to_s.empty?
      end
      relocation = summary["symbol_relocation"]
      if relocation
        relocation = fetch_hash(summary, "symbol_relocation")
        if relocation["from"].to_s.empty? || relocation["to"].to_s.empty?
          raise ArgumentError, "summary.symbol_relocation requires from and to"
        end
      end
    end

    def source_files(root, config = fetch_hash(manifest, "source"))
      includes = Array(config.fetch("include"))
      excludes = Array(config["exclude"])
      files = includes.flat_map do |pattern|
        Dir.glob(File.join(root, pattern), File::FNM_EXTGLOB)
      end
      files.select! { |path| File.file?(path) }
      files.reject! do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        excludes.any? { |pattern| File.fnmatch?(pattern, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
      end
      files.map! { |path| File.expand_path(path) }
      files.uniq!
      files.sort!
      raise ArgumentError, "source globs selected no files below #{root}" if files.empty?

      files
    end

    def resolve_source_root
      return @source_root_override if @source_root_override

      source = fetch_hash(manifest, "source")
      return materialize_git_source(source) if source["git"]
      return expanded_path(source["root"]) if source["root"]

      command = expand_command(source.fetch("root_command"), {})
      cwd = expanded_path(source.fetch("root_working_directory", @workspace_root))
      stdout, stderr, status = @runner.capture(command, chdir: cwd)
      raise "source.root_command failed: #{stderr}" unless status.success?
      root = stdout.strip
      raise "source.root_command returned an empty path" if root.empty?

      suffix = source["root_suffix"].to_s
      File.expand_path(File.join(root, suffix))
    end

    def materialize_git_source(source)
      config = fetch_hash(source, "git")
      checkout = expanded_path(
        config.fetch(
          "directory",
          File.join(@workspace_root, ".cache", "stdlib-sources", safe_name(source.fetch("revision")))
        )
      )
      FileUtils.mkdir_p(checkout)
      unless File.directory?(File.join(checkout, ".git"))
        @runner.run!(["git", "init", "--quiet"], chdir: checkout)
        @runner.run!(
          ["git", "remote", "add", "origin", config.fetch("repository")],
          chdir: checkout
        )
      end
      remote, stderr, status = @runner.capture(
        ["git", "remote", "get-url", "origin"],
        chdir: checkout
      )
      unless status.success?
        raise "failed to inspect git source remote: #{stderr}"
      end
      unless remote.strip == config.fetch("repository")
        raise "git source remote mismatch: expected #{config.fetch('repository').inspect}, got #{remote.strip.inspect}"
      end
      if Array(config["sparse_paths"]).any?
        @runner.run!(["git", "sparse-checkout", "init", "--cone"], chdir: checkout)
        @runner.run!(
          ["git", "sparse-checkout", "set", *Array(config["sparse_paths"]).map(&:to_s)],
          chdir: checkout
        )
      end
      commit = config.fetch("commit")
      current, = @runner.capture(["git", "rev-parse", "HEAD"], chdir: checkout)
      unless current.strip == commit
        @runner.run!(["git", "fetch", "--depth", "1", "origin", commit], chdir: checkout)
        @runner.run!(["git", "checkout", "--quiet", "--detach", "FETCH_HEAD"], chdir: checkout)
      end
      root = File.expand_path(File.join(checkout, source["root_suffix"].to_s))
      raise "git source root does not exist after checkout: #{root}" unless File.directory?(root)

      root
    end

    def prepare_source(source_root)
      source = fetch_hash(manifest, "source")
      substitutions = {
        "source_root" => source_root,
        "work_dir" => @work_dir,
        "manifest_dir" => @manifest_dir,
        "workspace_root" => @workspace_root
      }
      Array(source["prepare"]).each do |command|
        raise ArgumentError, "each source.prepare entry must be a command array" unless command.is_a?(Array)

        @runner.run!(
          expand_command(command, substitutions),
          chdir: expanded_path(source.fetch("prepare_working_directory", @workspace_root), substitutions)
        )
      end
    end

    def stage_selected_source(source_root, files)
      source = fetch_hash(manifest, "source")
      return [source_root, files] unless source["stage_selected_files"] == true

      stage_root = File.join(@work_dir, "selected-source")
      FileUtils.rm_rf(stage_root)
      FileUtils.mkdir_p(stage_root)
      staged_files = files.map do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(source_root)).to_s
        destination = File.join(stage_root, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.copy_file(path, destination)
        destination
      end
      [stage_root, staged_files]
    end

    def verify_source_revision(source_root)
      source = fetch_hash(manifest, "source")
      if source["git"]
        checkout = source_root
        checkout = File.dirname(checkout) until File.directory?(File.join(checkout, ".git")) ||
          File.dirname(checkout) == checkout
        raise "git metadata not found above source root #{source_root}" unless File.directory?(File.join(checkout, ".git"))

        stdout, stderr, status = @runner.capture(["git", "rev-parse", "HEAD"], chdir: checkout)
        raise "source revision command failed: #{stderr}" unless status.success?
        expected = fetch_hash(source, "git").fetch("commit")
        unless stdout.strip == expected
          raise "source revision mismatch: expected #{expected.inspect}, got #{stdout.strip.inspect}"
        end
        return source.fetch("revision")
      end
      check = fetch_hash(source, "revision_check")
      substitutions = {
        "source_root" => source_root,
        "work_dir" => @work_dir,
        "manifest_dir" => @manifest_dir,
        "workspace_root" => @workspace_root
      }
      command = expand_command(check.fetch("command"), substitutions)
      cwd = expanded_path(check.fetch("working_directory", source_root), substitutions)
      env = fetch_hash(check, "environment", required: false)
        .transform_values { |value| expand_string(value.to_s, substitutions) }
      stdout, stderr, status = @runner.capture(command, chdir: cwd, env: env)
      raise "source revision command failed: #{stderr}" unless status.success?

      output = stdout.strip
      exact = check["equals"]
      includes = Array(check["includes"])
      matches = if exact
                  output == exact.to_s
                else
                  includes.all? { |fragment| output.include?(fragment.to_s) }
                end
      unless matches
        expectation = exact ? exact.inspect : "all of #{includes.inspect}"
        raise "source revision mismatch: expected #{expectation}, got #{output.inspect}"
      end

      source.fetch("revision")
    end

    def produce_index(source_root)
      return checked_file(@index_override, "SCIP index") if @index_override

      config = fetch_hash(manifest, "index")
      return checked_file(expanded_path(config["path"]), "SCIP index") if config["path"]

      output = File.join(@work_dir, config.fetch("output", "stdlib.scip"))
      substitutions = {
        "source_root" => source_root,
        "work_dir" => @work_dir,
        "index" => output,
        "manifest_dir" => @manifest_dir,
        "workspace_root" => @workspace_root
      }
      command = expand_command(config.fetch("command"), substitutions)
      cwd = expanded_path(config.fetch("working_directory", source_root), substitutions)
      env = fetch_hash(config, "environment", required: false)
        .transform_values { |value| expand_string(value.to_s, substitutions) }
      @runner.run!(command, chdir: cwd, env: env)
      checked_file(output, "generated SCIP index")
    end

    def run_profile(files, index, output, summary: nil, language: manifest.fetch("language"))
      command = [
        fact_mine_binary, "profile", "espalier",
        "--language", language,
        "--scip-index", index,
        "--no-bundled-complexity-summaries",
        "--output", output
      ]
      command.concat(["--complexity-summary", summary]) if summary
      command.concat(files)
      @runner.run!(command, chdir: @workspace_root)
    end

    def export_summary(profile, output, relocate:)
      summary = fetch_hash(manifest, "summary")
      indexer = fetch_hash(fetch_hash(manifest, "index"), "expected")
      command = [
        RbConfig.ruby,
        File.join(@workspace_root, "gems/espalier/script/export_complexity_summary.rb"),
        "--corpus", summary.fetch("corpus"),
        "--source-revision", fetch_hash(manifest, "source").fetch("revision"),
        "--indexer", "#{indexer.fetch('tool')}@#{indexer.fetch('version')}"
      ]
      if relocate && (relocation = summary["symbol_relocation"])
        command.concat(["--symbol-prefix-from", relocation.fetch("from")])
        command.concat(["--symbol-prefix-to", relocation.fetch("to")])
      end
      command.concat([profile, output])
      @runner.run!(command, chdir: @workspace_root)
    end

    def validate_profile!(profile, files)
      coverage = fetch_hash(profile, "input_coverage")
      selected = coverage.fetch("selected_files", 0).to_i
      parsed = coverage.fetch("parsed_files", 0).to_i
      raise "profile selected #{selected} files, expected #{files.length}" unless selected == files.length
      raise "profile parsed only #{parsed}/#{selected} selected files" unless parsed == selected
      recovery_files = Array(coverage["parse_recovery_files"])
      recoveries = Array(coverage["parse_recoveries"])
      eligible_methods = Array(profile["methods"]).select do |method|
        method["source_export_eligible"] == true
      end
      recovery_overlaps = recoveries.sum do |recovery|
        path = recovery["path"].to_s
        spans = Array(recovery["spans"])
        eligible_methods.count do |method|
          method["path"].to_s == path && spans.any? do |span|
            spans_overlap?(Array(method["span"]), Array(span))
          end
        end
      end
      if recovery_overlaps.positive?
        raise "parser recovery overlaps #{recovery_overlaps} source-export eligible methods"
      end

      expected = fetch_hash(fetch_hash(manifest, "index"), "expected")
      indexes = Array(profile["semantic_indexes"])
      unless indexes.any? { |row| row["tool"] == expected["tool"] && row["version"] == expected["version"] }
        raise "SCIP metadata did not contain #{expected['tool']}@#{expected['version']}"
      end
      methods = Array(profile["methods"])
      eligible = methods.count { |method| method["source_export_eligible"] == true }
      minimum = fetch_hash(manifest, "soundness", required: false).fetch("minimum_export_eligible_methods", 1).to_i
      raise "only #{eligible} methods are source-export eligible; expected at least #{minimum}" if eligible < minimum

      calls = fetch_hash(profile, "call_resolution_coverage", required: false)
      raw_call_gaps = calls.fetch("raw_calls_not_normalized_inside_function", 0).to_i
      eligible_gap_overlaps = calls
        .fetch("source_export_eligible_methods_overlapping_raw_call_loss", 0)
        .to_i
      if eligible_gap_overlaps.positive?
        raise "parser call loss overlaps #{eligible_gap_overlaps} source-export eligible methods; analyzer eligibility revocation is unsound"
      end
      {
        "methods" => methods.length,
        "source_export_eligible_methods" => eligible,
        "raw_calls_not_normalized" => calls.fetch("raw_calls_not_normalized", 0).to_i,
        "raw_calls_not_normalized_inside_function" => raw_call_gaps,
        "eligible_methods_overlapping_call_loss" => eligible_gap_overlaps,
        "parse_recovery_files" => recovery_files.length,
        "parse_recovery_spans" => recoveries.sum { |recovery| Array(recovery["spans"]).length },
        "eligible_methods_overlapping_parse_recovery" => recovery_overlaps,
        "semantic_index" => "#{expected['tool']}@#{expected['version']}"
      }
    end

    def validate_summary!(summary, relocated: true)
      raise "unexpected summary schema: #{summary['schema'].inspect}" unless summary["schema"] == SUMMARY_SCHEMA
      symbols = fetch_hash(summary, "symbols")
      source = fetch_hash(summary, "source")
      declared = source.fetch("complete_symbol_count").to_i
      raise "summary count #{declared} does not match #{symbols.length} symbols" unless declared == symbols.length

      config = fetch_hash(manifest, "summary")
      minimum = config.fetch("minimum_symbols", 1).to_i
      raise "summary exported #{symbols.length} symbols; expected at least #{minimum}" if symbols.length < minimum
      prefix = if !relocated && config["symbol_relocation"]
                 fetch_hash(config, "symbol_relocation").fetch("from")
               else
                 config["expected_symbol_prefix"]
               end
      if prefix
        bad = symbols.keys.find { |symbol| !symbol.start_with?(prefix) }
        raise "summary symbol does not use expected prefix: #{bad}" if bad
      end
      {
        "symbols" => symbols.length,
        "source_proven_methods" => source.fetch("source_proven_method_count").to_i,
        "profile_sha256" => source.fetch("profile_sha256"),
        "indexer" => source.fetch("indexer")
      }
    end

    def verify_summary_join(profile, summary)
      symbols = fetch_hash(summary, "symbols")
      joined = Array(profile["calls"]).count do |call|
        symbols.key?(call["semantic_symbol"].to_s)
      end
      {"verified_join_call_sites" => joined}
    end

    def run_consumer_checks(summary)
      Array(manifest["consumers"]).map do |consumer|
        name = consumer.fetch("name")
        root = expanded_path(consumer.fetch("source_root"))
        files = source_files(root, consumer)
        index = produce_consumer_index(consumer, name, root)
        baseline = File.join(@work_dir, "consumer-#{safe_name(name)}-baseline.json")
        generated = File.join(@work_dir, "consumer-#{safe_name(name)}-generated.json")
        run_profile(files, index, baseline, language: consumer.fetch("language", manifest.fetch("language")))
        run_profile(files, index, generated, summary: summary,
                    language: consumer.fetch("language", manifest.fetch("language")))
        before = coverage_report(baseline, root, consumer)
        after = coverage_report(generated, root, consumer)
        before_mapped = before.dig("coverage", "mapped").to_i
        after_mapped = after.dig("coverage", "mapped").to_i
        raise "#{name} regressed from #{before_mapped} to #{after_mapped} complete functions" if after_mapped < before_mapped
        minimum = consumer.fetch("minimum_complete_percent", 85.0).to_f
        percent = after.dig("coverage", "mapped_percent").to_f
        raise "#{name} completeness #{percent}% is below #{minimum}%" if percent < minimum

        {
          "name" => name,
          "before" => before.fetch("coverage").slice("functions", "mapped", "mapped_percent"),
          "after" => after.fetch("coverage").slice("functions", "mapped", "mapped_percent"),
          "complete_delta" => after_mapped - before_mapped,
          "percentage_point_delta" =>
            (after.dig("coverage", "mapped_percent").to_f - before.dig("coverage", "mapped_percent").to_f).round(2)
        }
      end
    end

    def produce_consumer_index(consumer, name, source_root)
      config = consumer.fetch("index")
      return checked_file(expanded_path(config), "#{name} SCIP index") if config.is_a?(String)
      raise ArgumentError, "#{name} consumer index must be a path or mapping" unless config.is_a?(Hash)
      return checked_file(expanded_path(config.fetch("path")), "#{name} SCIP index") if config["path"]

      output = File.join(
        @work_dir,
        config.fetch("output", "consumer-#{safe_name(name)}.scip")
      )
      substitutions = {
        "source_root" => source_root,
        "work_dir" => @work_dir,
        "index" => output,
        "manifest_dir" => @manifest_dir,
        "workspace_root" => @workspace_root
      }
      command = expand_command(config.fetch("command"), substitutions)
      cwd = expanded_path(config.fetch("working_directory", source_root), substitutions)
      env = fetch_hash(config, "environment", required: false)
        .transform_values { |value| expand_string(value.to_s, substitutions) }
      @runner.run!(command, chdir: cwd, env: env)
      checked_file(output, "generated #{name} SCIP index")
    end

    def coverage_report(profile, root, consumer)
      command = [
        RbConfig.ruby,
        File.join(@workspace_root, "gems/espalier/script/check_big_o_coverage.rb"),
        "--source-root", root,
        "--minimum", "0"
      ]
      Array(consumer["repositories"]).each { |repository| command.concat(["--repository", repository]) }
      command << profile
      stdout, stderr, status = @runner.capture(command, chdir: @workspace_root)
      raise "coverage report failed: #{stderr}" unless status.success?

      JSON.parse(stdout)
    end

    def fact_mine_binary
      candidate = @fact_mine_override || ENV["FACT_MINE_RUST"] ||
        File.join(@workspace_root, "gems/fact-mine/target/release/fact-mine-rust")
      checked_file(File.expand_path(candidate), "FactMine binary")
    end

    def summary_output
      @summary_output_override || expanded_path(fetch_hash(manifest, "summary").fetch("output"))
    end

    def publish_summary(staged_summary, output)
      directory = File.dirname(output)
      FileUtils.mkdir_p(directory)
      temporary = File.join(
        directory,
        ".#{File.basename(output)}.stdlib-map-#{Process.pid}-#{rand(1 << 32)}"
      )
      FileUtils.copy_file(staged_summary, temporary)
      File.rename(temporary, output)
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def read_json(path)
      if File.extname(path) == ".gz"
        JSON.parse(Zlib::GzipReader.open(path, &:read))
      else
        JSON.parse(File.read(path))
      end
    end

    def checked_file(path, label)
      raise ArgumentError, "#{label} not found: #{path}" unless path && File.file?(path)
      raise ArgumentError, "#{label} is empty: #{path}" unless File.size?(path)

      path
    end

    def fetch_hash(parent, key, required: true)
      value = parent[key]
      if value.nil? && !required
        return {}
      end
      raise ArgumentError, "#{key} must be a mapping" unless value.is_a?(Hash)

      value
    end

    def expanded_path(value, substitutions = {})
      path = expand_string(value.to_s, substitutions)
      return File.expand_path(path) if Pathname.new(path).absolute?

      File.expand_path(path, @manifest_dir)
    end

    def expand_command(command, substitutions)
      Array(command).map { |token| expand_string(token.to_s, substitutions) }
    end

    def expand_string(value, substitutions = {})
      builtins = {
        "manifest_dir" => @manifest_dir,
        "workspace_root" => @workspace_root,
        "work_dir" => @work_dir
      }.merge(substitutions)
      value.gsub(/\{([a-z_]+)\}/) do
        builtins.fetch(Regexp.last_match(1)) do
          raise ArgumentError, "unknown manifest placeholder {#{Regexp.last_match(1)}}"
        end
      end
    end

    def expand_environment(value)
      case value
      when Hash
        value.to_h { |key, child| [key.to_s, expand_environment(child)] }
      when Array
        value.map { |child| expand_environment(child) }
      when String
        value.gsub(/\$\{([A-Z][A-Z0-9_]*)\}/) do
          ENV.fetch(Regexp.last_match(1)) do
            raise ArgumentError, "environment variable #{Regexp.last_match(1)} is required by #{manifest_path}"
          end
        end
      else
        value
      end
    end

    def safe_name(value)
      value.to_s.gsub(/[^a-zA-Z0-9_.-]+/, "-")
    end

    def spans_overlap?(left, right)
      return false unless left.length == 4 && right.length == 4

      point_before_or_equal?(left[0], left[1], right[2], right[3]) &&
        point_before_or_equal?(right[0], right[1], left[2], left[3])
    end

    def point_before_or_equal?(left_line, left_column, right_line, right_column)
      left_line = left_line.to_i
      right_line = right_line.to_i
      left_line < right_line ||
        (left_line == right_line && left_column.to_i <= right_column.to_i)
    end
  end
end
