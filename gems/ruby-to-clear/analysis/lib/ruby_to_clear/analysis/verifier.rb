# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "prism"
require "rbconfig"
require "time"

module RubyToClear
  module Analysis
    class Verifier
      GATE_DEFAULTS = {
        "g0" => "not_run", "g1" => "not_run", "g2" => "not_run",
        "g3" => "not_run", "g4" => "not_run", "g5" => "not_configured"
      }.freeze

      FAILURE_PATTERNS = {
        "C0" => /Parser\s*Error|Lexer\s*Error|parse error|syntax error|unexpected token|unterminated|unclosed interpolation|expected .+ (?:at|before|after)/i,
        "C2" => /type mismatch|type error|unknown type|result type|implicitly copyable|union|variant|optional|cannot assign|incompatible type|expected type|field .+ expected .+, got/i,
        "C3" => /ownership|lifetime|borrow|mutable|mutating|effect|capabilit|moved?\b|frame_|rewind|transfer_without_alloc|double.free|use.after.free/i,
        "C1" => /unknown (?:variable|name|method|function|constant|field)|undefined|not defined|no such|require error|file not found|circular dependency|duplicate declaration/i
      }.freeze

      attr_reader :root, :manifest_path, :jobs, :timeout_seconds

      def initialize(root:, manifest_path:, artifacts_dir:, report_dir:, jobs: 2,
                     timeout_seconds: nil, autofix: false, only: nil, runner: Runner.new,
                     out: $stdout)
        @root = File.expand_path(root)
        @manifest_path = File.expand_path(manifest_path, @root)
        @artifacts_dir = File.expand_path(artifacts_dir, @root)
        @report_dir = File.expand_path(report_dir, @root)
        @jobs = [jobs, 1].max
        @timeout_override = timeout_seconds
        @autofix = autofix
        @only = only && Regexp.new(only)
        @runner = runner
        @out = out
        @print_mutex = Mutex.new
      end

      def run
        load_manifest
        prepare_run
        units = build_units
        raise "no source units matched the manifest and --only filter" if units.empty?

        say "G0/G1: parsing and strictly transpiling #{units.length} units with #{jobs} job(s)"
        parallel_map!(units) { |unit| parse_and_transpile(unit) }
        say "G2/G3: compiling raw generated roots through the CLEAR frontend and MIR backend"
        parallel_map!(units) { |unit| compile_frontend(unit, @raw_generated_root, "raw") }
        say "G4: building frontend-clean roots through clear test and Zig"
        parallel_map!(units) { |unit| build_zig(unit, @raw_generated_root, "raw") }
        run_autofix(units) if @autofix

        report = assemble_report(units)
        write_reports(report)
        report
      end

      def self.classify(diagnostic, timed_out: false, backend: false)
        return "H0" if timed_out
        return "Z0" if backend

        primary = primary_diagnostic_line(diagnostic)
        FAILURE_PATTERNS.each { |code, pattern| return code if primary.match?(pattern) }
        "C4"
      end

      def self.fingerprint(diagnostic)
        normalized = primary_diagnostic_line(diagnostic).dup
        normalized.gsub!(%r{(?<![A-Za-z0-9_.-])(?:/[^\s:]+)+}, "<path>")
        normalized.sub!(/\A[^\s:]+:\d+(?::\d+)?:in [`'][^`']+[`']:\s*/, "")
        normalized.sub!(/\A[^\s:]+:\d+:\d+:\s*/, "")
        normalized.gsub!(/0x[0-9a-f]+/i, "<hex>")
        normalized.gsub!(/\b\d+\b/, "<n>")
        normalized.gsub!(/\s+/, " ")
        normalized[0, 240]
      end

      def self.primary_diagnostic_line(diagnostic)
        lines = diagnostic.each_line.map do |candidate|
          candidate.gsub(/\e\[[\d;]*m/, "").strip
        end
        candidates = lines.reject do |candidate|
          candidate.empty? ||
            candidate.start_with?("from ", "warning:", "[Warning]", "[WARN]", "[INFO]") ||
            candidate == "TEST FAILED" || candidate == "Transpilation failed"
        end
        explicit = candidates.find { |candidate| candidate.start_with?("[Parser Error]", "[Compiler Error]") }
        explicit ||
          candidates.find { |candidate| candidate.match?(/Lexer\s*Error:|Parser\s*Error:|MIR ownership verification failed|\berror:|Error: Unsupported|mismatch|unknown|undefined/i) } ||
          candidates.first || "no diagnostic output"
      end

      private

      def load_manifest
        @manifest_bytes = File.binread(manifest_path)
        @manifest = JSON.parse(@manifest_bytes)
        raise "unsupported manifest schema" unless @manifest["schema_version"] == 1

        @timeout_seconds = @timeout_override || @manifest.fetch("timeout_seconds", 240)
        corpus = @manifest.fetch("corpus")
        @source_root = File.expand_path(corpus.fetch("source_root"), root)
        @checked_generated_root = File.expand_path(corpus.fetch("generated_root"), root)
        @source_glob = corpus.fetch("glob")
      end

      def prepare_run
        revision = git_revision
        manifest_hash = Digest::SHA256.hexdigest(@manifest_bytes)
        @run_id = "#{revision[0, 12]}-#{manifest_hash[0, 12]}"
        @artifact_root = File.join(@artifacts_dir, @run_id)
        FileUtils.rm_rf(@artifact_root)
        @raw_generated_root = File.join(@artifact_root, "raw", "compiler", "src")
        FileUtils.mkdir_p(File.dirname(@raw_generated_root))
        FileUtils.cp_r(@checked_generated_root, @raw_generated_root)
        FileUtils.mkdir_p(File.join(@artifact_root, "units"))
        @revision = revision
        @manifest_hash = manifest_hash
      end

      def build_units
        files = Dir[File.join(@source_root, @source_glob)].select { |path| File.file?(path) }.sort
        files.select! { |path| @only.match?(relative(path)) } if @only
        units = files.map do |source|
          source_relative = Pathname.new(source).relative_path_from(Pathname.new(@source_root)).to_s
          generated_relative = source_relative.sub(/\.rb\z/, ".clear")
          target = File.join(@raw_generated_root, generated_relative)
          FileUtils.rm_f(target)
          {
            "id" => generated_relative.delete_suffix(".clear").gsub(%r{[^a-zA-Z0-9_.-]+}, "__"),
            "source" => relative(source),
            "source_absolute" => source,
            "generated" => relative(File.join(@checked_generated_root, generated_relative)),
            "generated_relative" => generated_relative,
            "raw_target" => target,
            "source_loc" => File.foreach(source).count { |line| !line.strip.empty? },
            "prism_nodes" => {},
            "gates" => GATE_DEFAULTS.dup,
            "commands" => {},
            "autofix" => { "g4" => "not_run" }
          }
        end
        units
      end

      def parse_and_transpile(unit)
        source = File.binread(unit.fetch("source_absolute"))
        result = Prism.parse(source)
        unit["prism_nodes"] = count_prism_nodes(result.value)
        if result.failure?
          unit["gates"]["g0"] = "fail"
          diagnostic = result.errors.map(&:message).join("; ")
          fail_unit(unit, "R0", diagnostic)
          unit["gates"]["g1"] = "skipped"
          later_skipped(unit)
          return progress(unit, "R0")
        end
        unit["gates"]["g0"] = "pass"

        FileUtils.mkdir_p(File.dirname(unit.fetch("raw_target")))
        dir = unit_artifact_dir(unit, "raw")
        command = [RbConfig.ruby, File.join(root, "gems/ruby-to-clear/exe/ruby-to-clear"), "--strict"]
        helper_config = @manifest["helper_config"]
        command += ["--helper-config", File.expand_path(helper_config, root)] if helper_config
        command << unit.fetch("source_absolute")
        run = @runner.run(command, stdout_path: unit.fetch("raw_target"),
                          stderr_path: File.join(dir, "transpile.stderr.log"),
                          timeout_seconds: timeout_seconds, chdir: root)
        unit["commands"]["transpile"] = portable_run(run)
        diagnostic = @runner.diagnostic_text(run)
        unless run["success"]
          code = run["timed_out"] || run["harness_error"] ? "H0" : "T0"
          unit["gates"]["g1"] = "fail"
          FileUtils.rm_f(unit.fetch("raw_target"))
          fail_unit(unit, code, diagnostic)
          later_skipped(unit)
          return progress(unit, code)
        end

        output = File.binread(unit.fetch("raw_target"))
        forbidden = @manifest.fetch("forbidden_output_patterns", []).select { |marker| output.include?(marker) }
        if forbidden.any?
          unit["gates"]["g1"] = "fail"
          fail_unit(unit, "T1", "forbidden output marker(s): #{forbidden.join(", ")}")
          later_skipped(unit)
          return progress(unit, "T1")
        end

        unit["gates"]["g1"] = "pass"
        unit["generated_sha256"] = Digest::SHA256.file(unit.fetch("raw_target")).hexdigest
        unit["generated_bytes"] = File.size(unit.fetch("raw_target"))
        progress(unit, "G1 pass")
      rescue StandardError => e
        unit["gates"]["g0"] = "fail" if unit.dig("gates", "g0") == "not_run"
        unit["gates"]["g1"] = "fail"
        fail_unit(unit, "H0", "#{e.class}: #{e.message}")
        later_skipped(unit)
        progress(unit, "H0")
      end

      def compile_frontend(unit, generated_root, variant)
        gates = variant == "raw" ? unit.fetch("gates") : (unit["autofix"] ||= {})
        prerequisite = variant == "raw" ? gates["g1"] == "pass" : File.file?(variant_target(unit, generated_root))
        unless prerequisite
          gates["g2"] = "skipped"
          gates["g3"] = "skipped"
          return
        end

        missing = missing_dependencies(variant_target(unit, generated_root), generated_root)
        if missing.any?
          gates["g2"] = "fail"
          gates["g3"] = "skipped"
          if variant == "raw"
            fail_unit(unit, "C1", "missing generated dependency: #{missing.first}", details: { "missing_dependencies" => missing })
          end
          return progress(unit, "#{variant} C1 dependency")
        end

        dir = unit_artifact_dir(unit, variant)
        command = [RbConfig.ruby, File.join(root, "compiler/ruby/backends/transpiler.rb"),
                   "--default-stack", "Large"]
        @manifest.fetch("packages", {}).each do |name, path|
          command += ["--pkg", "#{name}=#{File.expand_path(path, root)}"]
        end
        command << variant_target(unit, generated_root)
        run = @runner.run(command, stdout_path: File.join(dir, "generated.zig"),
                          stderr_path: File.join(dir, "frontend.stderr.log"),
                          timeout_seconds: timeout_seconds, chdir: root)
        command_key = variant == "raw" ? "frontend" : "autofix_frontend"
        unit["commands"][command_key] = portable_run(run)
        if run["success"]
          gates["g2"] = "pass"
          gates["g3"] = "pass"
          return progress(unit, "#{variant} G3 pass")
        end

        diagnostic = @runner.diagnostic_text(run)
        code = self.class.classify(diagnostic, timed_out: run["timed_out"] || run["harness_error"])
        case code
        when "C0", "H0"
          gates["g2"] = "fail"
          gates["g3"] = "skipped"
        when "C1", "C2", "C3"
          gates["g2"] = "pass"
          gates["g3"] = "fail"
        else
          gates["g2"] = "unknown"
          gates["g3"] = "unknown"
        end
        fail_unit(unit, code, diagnostic) if variant == "raw"
        progress(unit, "#{variant} #{code}")
      end

      def build_zig(unit, generated_root, variant)
        gates = variant == "raw" ? unit.fetch("gates") : unit.fetch("autofix")
        unless gates["g3"] == "pass"
          gates["g4"] = "skipped"
          return
        end

        provision_native_modules(variant_target(unit, generated_root))
        dir = unit_artifact_dir(unit, variant)
        command = [File.join(root, "clear"), "test", variant_target(unit, generated_root), "--strict"]
        run = @runner.run(command, stdout_path: File.join(dir, "build.stdout.log"),
                          stderr_path: File.join(dir, "build.stderr.log"),
                          timeout_seconds: timeout_seconds, chdir: root,
                          env: { "NO_COLOR" => "1" })
        command_key = variant == "raw" ? "build" : "autofix_build"
        unit["commands"][command_key] = portable_run(run)
        if run["success"]
          gates["g4"] = "pass"
          return progress(unit, "#{variant} G4 pass")
        end

        gates["g4"] = "fail"
        diagnostic = @runner.diagnostic_text(run)
        code = self.class.classify(diagnostic, timed_out: run["timed_out"] || run["harness_error"], backend: true)
        fail_unit(unit, code, diagnostic) if variant == "raw"
        progress(unit, "#{variant} #{code}")
      end

      def run_autofix(units)
        say "Autofix: copying raw output, fixing each generated file independently, and retrying raw failures"
        fixed_root = File.join(@artifact_root, "autofix", "compiler", "src")
        FileUtils.mkdir_p(File.dirname(fixed_root))
        FileUtils.cp_r(@raw_generated_root, fixed_root)
        targets = units.select { |unit| unit.dig("gates", "g1") == "pass" }
        parallel_map!(targets) { |unit| fix_unit(unit, fixed_root) }
        retry_units = units.select { |unit| unit.dig("gates", "g4") != "pass" && unit.dig("gates", "g1") == "pass" }
        parallel_map!(retry_units) { |unit| compile_frontend(unit, fixed_root, "autofix") }
        parallel_map!(retry_units) { |unit| build_zig(unit, fixed_root, "autofix") }
      end

      def fix_unit(unit, fixed_root)
        dir = unit_artifact_dir(unit, "autofix")
        fixed_target = variant_target(unit, fixed_root)
        before_sha256 = Digest::SHA256.file(fixed_target).hexdigest
        command = [File.join(root, "clear"), "fix", "--loop=20", fixed_target]
        run = @runner.run(command,
          stdout_path: File.join(dir, "fix.stdout.log"),
          stderr_path: File.join(dir, "fix.stderr.log"),
          timeout_seconds: timeout_seconds, chdir: root)
        unit["commands"]["autofix"] = portable_run(run)
        unit["autofix"]["fix"] = run["success"] ? "pass" : "fail"
        after_sha256 = Digest::SHA256.file(fixed_target).hexdigest
        unit["autofix"]["before_sha256"] = before_sha256
        unit["autofix"]["after_sha256"] = after_sha256
        unit["autofix"]["changed"] = before_sha256 != after_sha256
        write_autofix_diff(unit, fixed_target, dir) if unit.dig("autofix", "changed")
        progress(unit, "autofix #{unit.dig("autofix", "fix")}")
      end

      def write_autofix_diff(unit, fixed_target, dir)
        diff, _stderr, _status = Open3.capture3(
          "diff", "-u", "--label", "raw/#{unit.fetch("generated_relative")}",
          "--label", "autofix/#{unit.fetch("generated_relative")}",
          unit.fetch("raw_target"), fixed_target
        )
        File.write(File.join(dir, "autofix.diff"), diff)
      end

      def missing_dependencies(target, generated_root)
        missing = []
        seen = {}
        visit = lambda do |path|
          expanded = File.expand_path(path)
          return if seen[expanded]
          seen[expanded] = true
          unless File.file?(expanded)
            missing << relative_to(expanded, generated_root)
            return
          end
          File.foreach(expanded) do |line|
            spec = line[/\AREQUIRE\s+"([^"]+)"/, 1]
            next unless spec
            next if spec.start_with?("pkg:")

            visit.call(File.expand_path(spec, File.dirname(expanded)))
          end
        end
        visit.call(target)
        missing.uniq.sort
      end

      def provision_native_modules(target)
        @manifest.fetch("native_modules", {}).each do |name, source|
          source_path = File.expand_path(source, root)
          destination = File.join(File.dirname(target), "#{name}.zig")
          next if File.expand_path(source_path) == File.expand_path(destination)

          FileUtils.cp(source_path, destination)
        end
      end

      def count_prism_nodes(root_node)
        counts = Hash.new(0)
        walk = lambda do |node|
          return unless node.is_a?(Prism::Node)
          counts[node.class.name.delete_prefix("Prism::")] += 1
          node.child_nodes.each { |child| walk.call(child) if child }
        end
        walk.call(root_node)
        counts.sort.to_h
      end

      def assemble_report(units)
        clean_units = units.map { |unit| unit.reject { |key, _| key.end_with?("_absolute") || key == "raw_target" } }
        report = {
          "schema_version" => 1,
          "generated_at" => Time.now.utc.iso8601,
          "revision" => @revision,
          "manifest" => relative(manifest_path),
          "manifest_sha256" => @manifest_hash,
          "artifact_root" => relative(@artifact_root),
          "configuration" => {
            "jobs" => jobs,
            "timeout_seconds" => timeout_seconds,
            "autofix" => @autofix,
            "only" => @only&.source
          },
          "units" => clean_units
        }
        report["aggregate"] = Reporter.aggregate(clean_units)
        report["prism_nodes"] = Reporter.node_metrics(clean_units)
        report
      end

      def write_reports(report)
        FileUtils.mkdir_p(@report_dir)
        json = JSON.pretty_generate(report) + "\n"
        markdown = Reporter.markdown(report)
        File.write(File.join(@artifact_root, "report.json"), json)
        File.write(File.join(@artifact_root, "report.md"), markdown)
        File.write(File.join(@report_dir, "latest.json"), json)
        File.write(File.join(@report_dir, "latest.md"), markdown)
        say "Reports: #{relative(File.join(@report_dir, "latest.json"))} and #{relative(File.join(@report_dir, "latest.md"))}"
      end

      def parallel_map!(items, &block)
        queue = Queue.new
        items.each { |item| queue << item }
        workers = [jobs, items.length].min.times.map do
          Thread.new do
            loop do
              item = queue.pop(true)
              block.call(item)
            rescue ThreadError
              break
            rescue StandardError => e
              fail_unit(item, "H0", "#{e.class}: #{e.message}") if item
              progress(item, "H0 harness") if item
            end
          end
        end
        workers.each(&:join)
      end

      def fail_unit(unit, code, diagnostic, details: {})
        return if unit["failure"] && unit.dig("failure", "code") != "Z0"

        diagnostic_text = diagnostic.to_s
        excerpt = if diagnostic_text.bytesize > 4000
                    diagnostic_text.byteslice(diagnostic_text.bytesize - 4000, 4000)
                  else
                    diagnostic_text
                  end
        unit["failure"] = {
          "code" => code,
          "fingerprint" => self.class.fingerprint(diagnostic_text),
          "diagnostic_excerpt" => excerpt,
          **details
        }
      end

      def later_skipped(unit)
        %w[g2 g3 g4].each { |gate| unit["gates"][gate] = "skipped" }
      end

      def variant_target(unit, generated_root)
        File.join(generated_root, unit.fetch("generated_relative"))
      end

      def unit_artifact_dir(unit, variant)
        path = File.join(@artifact_root, "units", unit.fetch("id"), variant)
        FileUtils.mkdir_p(path)
        path
      end

      def portable_run(run)
        return unless run
        run.transform_values do |value|
          if value.is_a?(String) && value.start_with?(root)
            relative(value)
          elsif value.is_a?(Array)
            value.map { |entry| entry.is_a?(String) && entry.start_with?(root) ? relative(entry) : entry }
          else
            value
          end
        end
      end

      def relative(path)
        Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(root)).to_s
      rescue ArgumentError
        path
      end

      def relative_to(path, base)
        Pathname.new(path).relative_path_from(Pathname.new(base)).to_s
      rescue ArgumentError
        path
      end

      def git_revision
        stdout, status = Open3.capture2("git", "rev-parse", "HEAD", chdir: root)
        status.success? ? stdout.strip : "unknown"
      end

      def progress(unit, result)
        say "[#{unit.fetch("source")}] #{result}"
      end

      def say(message)
        @print_mutex.synchronize { @out.puts(message) }
      end
    end
  end
end
