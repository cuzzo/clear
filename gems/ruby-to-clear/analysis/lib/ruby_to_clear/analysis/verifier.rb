# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "prism"
require "rbconfig"
require "time"
require_relative "../../../../lib/ruby_to_clear/helper_config"

module RubyToClear
  module Analysis
    class Verifier
      GATE_DEFAULTS = {
        "g0" => "not_run", "g1" => "not_run", "g2" => "not_run",
        "g3" => "not_run", "g4" => "not_run", "g5" => "not_configured"
      }.freeze

      FAILURE_PATTERNS = {
        "C0" => /Parser\s*Error|Lexer\s*Error|parse error|syntax error|unexpected token|unterminated|unclosed interpolation|expected .+ (?:at|before|after)/i,
        "C5" => /ARG_ALIAS_CONFLICT|IMMUTABLE_FIELD_ASSIGNMENT|IMMUTABLE_ARG_PASSED_AS_MUTABLE|MUTABLE_PARAM_NEEDS_RESTRICT|exclusive mutability|is MUTABLE, but you passed immutable|cannot modify field .+ immutable object/i,
        "C6" => /EFFECT_INFERENCE_VIOLATION|effect inference|effect mismatch|requires parameter .+ to be bound under|requires .+ capabilit|capability requirement/i,
        "C2" => /type mismatch|type error|unknown type|result type|implicitly copyable|union|variant|optional|cannot assign|incompatible type|expected type|field .+ expected .+, got|non-list type/i,
        "C1" => /unknown (?:variable|name|method|function|constant|field)|undefined|not defined|no such|require error|file not found|circular dependency|duplicate declaration/i,
        "C3" => /ownership|lifetime|borrow|moved?\b|frame_|rewind|transfer_without_alloc|double.free|use.after.free/i
      }.freeze

      attr_reader :root, :manifest_path, :jobs, :timeout_seconds

      def initialize(root:, manifest_path:, artifacts_dir:, report_dir:, jobs: 2,
                     timeout_seconds: nil, autofix: false, only: nil, g3_from_report: nil,
                     changed: nil, reuse_report: nil, g4: true,
                     allow_toolchain_change: false,
                     runner: Runner.new,
                     out: $stdout)
        @root = File.expand_path(root)
        @manifest_path = File.expand_path(manifest_path, @root)
        @artifacts_dir = File.expand_path(artifacts_dir, @root)
        @report_dir = File.expand_path(report_dir, @root)
        @jobs = [jobs, 1].max
        @timeout_override = timeout_seconds
        @autofix = autofix
        @only = only && Regexp.new(only)
        @g3_from_report = g3_from_report && File.expand_path(g3_from_report, @root)
        @changed_paths = Array(changed).flat_map { |value| value.to_s.split(",") }
          .reject(&:empty?).map { |path| relative(File.expand_path(path, @root)) }.uniq.sort
        @reuse_report_path = reuse_report && File.expand_path(reuse_report, @root)
        @allow_toolchain_change = allow_toolchain_change
        @run_g4 = g4
        @runner = runner
        @out = out
        @print_mutex = Mutex.new
      end

      def run
        load_manifest
        prepare_run
        units = build_units
        raise "no source units matched the manifest and --only filter" if units.empty?
        prepare_incremental_reuse(units) if incremental?
        transpile_units = @invalidated_units || units
        prepare_cfg_facts(transpile_units)

        say "G0/G1: parsing and strictly transpiling #{transpile_units.length}/#{units.length} units with #{jobs} job(s)"
        parallel_map!(transpile_units) { |unit| parse_and_transpile(unit) }
        say "G2: parsing #{transpile_units.length}/#{units.length} generated CLEAR unit(s) with the real CLEAR parser"
        parallel_map!(transpile_units) { |unit| parse_generated(unit, @raw_generated_root, "raw") }
        index_generated_dependencies(units)
        index_generated_source_lines(units)
        provision_generated_packages(@raw_generated_root) if modular_dependencies?
        group_cyclic_units!(units)
        say "grouped #{@package_groups.values.sum(&:length)} units into #{@package_groups.length} cyclic package group(s)" if @package_groups.any?
        g3_units = selected_g3_units(units)
        @incremental_g3_selected = g3_units.length if incremental?
        g3_units.each { |unit| reset_cached_frontend_result!(unit) } if incremental?
        say "G3: compiling #{g3_units.length} parser-clean candidate roots through the CLEAR frontend and MIR backend"
        run_package_groups(units, @raw_generated_root, "frontend", selected_units: g3_units)
        parallel_map!(g3_units) { |unit| compile_frontend(unit, @raw_generated_root, "raw") }
        if @g3_from_report || !@run_g4
          say "G4: skipped#{@g3_from_report ? ' in --g3-from-report mode' : ' by --g3-only'}"
        else
          g4_units = incremental? ? g3_units.select { |unit| unit.dig("gates", "g3") == "pass" } : units
          @incremental_g4_selected = g4_units.length if incremental?
          say "G4: building #{g4_units.length} frontend-clean root(s) through clear test and Zig"
          run_package_groups(units, @raw_generated_root, "build", selected_units: g4_units)
          parallel_map!(g4_units) { |unit| build_zig(unit, @raw_generated_root, "raw") }
          run_autofix(g4_units) if @autofix
        end

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
            candidate.start_with?("from ", "warning:", "[Warning]", "[WARN]", "[INFO]", "[Note]") ||
            candidate == "TEST FAILED" || candidate == "Transpilation failed"
        end
        explicit = candidates.find { |candidate| candidate.start_with?("[Parser Error]", "[Compiler Error]") }
        explicit ||
          candidates.find { |candidate| candidate.match?(/Lexer\s*Error:|Parser\s*Error:|MIR ownership verification failed|\berror:|Error: Unsupported|mismatch|unknown|undefined|\b[A-Za-z]*Error\b/i) } ||
          candidates.first || "no diagnostic output"
      end

      private

      def load_manifest
        @manifest_bytes = File.binread(manifest_path)
        @manifest = JSON.parse(@manifest_bytes)
        raise "unsupported manifest schema" unless @manifest["schema_version"] == 1

        @timeout_seconds = @timeout_override || (incremental? ? 90 : @manifest.fetch("timeout_seconds", 240))
        corpus = @manifest.fetch("corpus")
        @source_root = File.expand_path(corpus.fetch("source_root"), root)
        @checked_generated_root = File.expand_path(corpus.fetch("generated_root"), root)
        @source_glob = corpus.fetch("glob")
        @source_excludes = corpus.fetch("exclude", [])
        helper_path = @manifest["helper_config"] && File.expand_path(@manifest.fetch("helper_config"), root)
        @helper_config_sha256 = helper_path && File.file?(helper_path) ? Digest::SHA256.file(helper_path).hexdigest : nil
        @compiler_frontend_sha256 = compiler_frontend_sha256
        @transpiler_toolchain_sha256 = transpiler_toolchain_sha256
      end

      def prepare_run
        revision = git_revision
        manifest_hash = Digest::SHA256.hexdigest(@manifest_bytes)
        @run_id = "#{revision[0, 12]}-#{manifest_hash[0, 12]}"
        if incremental?
          changed_hash = Digest::SHA256.hexdigest(@changed_paths.join("\0"))[0, 12]
          @run_id = "#{@run_id}-changed-#{changed_hash}"
        end
        @artifact_root = File.join(@artifacts_dir, @run_id)
        # A repeated --changed run commonly uses the report produced by the
        # previous invocation. Its artifact root has the same deterministic
        # name, so deleting the new run directory here would otherwise delete
        # the very raw CLEAR artifacts that --reuse-report is about to copy.
        if reuse_artifact_collision?(@artifact_root)
          @run_id = "#{@run_id}-reuse-#{Process.pid}"
          @artifact_root = File.join(@artifacts_dir, @run_id)
        end
        FileUtils.rm_rf(@artifact_root)
        @raw_generated_root = File.join(@artifact_root, "raw", "compiler", "src")
        FileUtils.mkdir_p(File.dirname(@raw_generated_root))
        FileUtils.cp_r(@checked_generated_root, @raw_generated_root)
        FileUtils.mkdir_p(File.join(@artifact_root, "units"))
        @revision = revision
        @manifest_hash = manifest_hash
      end

      def reuse_artifact_collision?(artifact_root)
        return false unless incremental? && @reuse_report_path && File.file?(@reuse_report_path)

        report = JSON.parse(File.binread(@reuse_report_path))
        cached_root = report["artifact_root"]
        cached_root && File.expand_path(cached_root, root) == artifact_root
      rescue JSON::ParserError
        # prepare_incremental_reuse will give the caller the authoritative
        # malformed-report error after the run directory is prepared.
        false
      end

      def build_units
        files = Dir[File.join(@source_root, @source_glob)].select { |path| File.file?(path) }.sort
        # Corpus scope: host-side dev tooling is excluded so the gates measure
        # the compiler pipeline being self-hosted, not scripts that shell out
        # to perf/objdump, drive an LSP over OS threads, or use String as a
        # byte buffer - all of which need language features CLEAR does not
        # have yet (see docs/agents/error-notes.md) and none of which are
        # compiler code.
        unless @source_excludes.empty?
          files.reject! do |path|
            rel = Pathname.new(path).relative_path_from(Pathname.new(@source_root)).to_s
            @source_excludes.any? { |pattern| File.fnmatch?(pattern, rel, File::FNM_PATHNAME) }
          end
        end
        files = expand_source_closure(files, @only) if @only
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
            "source_sha256" => Digest::SHA256.file(source).hexdigest,
            "source_dependencies" => source_dependency_paths(source),
            "generated_dependencies" => [],
            "prism_nodes" => {},
            "gates" => GATE_DEFAULTS.dup,
            "commands" => {},
            "diagnostics" => [],
            "autofix" => { "g4" => "not_run" }
          }
        end
        @units_by_generated = units.to_h { |unit| [unit.fetch("generated_relative"), unit] }
        @units_by_source = units.to_h { |unit| [unit.fetch("source"), unit] }
        units
      end

      # `--only` selects roots, but a root that is not dependency-closed cannot
      # reach G3: its generated REQUIREs name units this run never produced, and
      # every one of them is reported as a missing generated dependency rather
      # than as whatever the root's own code does wrong. Pull in the
      # require_relative closure of the matched roots so a scoped run measures
      # the same thing a full run does, only over fewer roots.
      def expand_source_closure(files, pattern)
        in_corpus = files.to_h { |path| [File.expand_path(path), true] }
        selected = files.select { |path| pattern.match?(relative(path)) }
        queue = selected.dup
        seen = selected.to_h { |path| [File.expand_path(path), true] }
        until queue.empty?
          source = queue.shift
          source_dependency_paths(source).each do |dep|
            expanded = File.expand_path(dep, root)
            next unless in_corpus[expanded]
            next if seen[expanded]

            seen[expanded] = true
            queue << expanded
          end
        end
        closure = files.select { |path| seen[File.expand_path(path)] }
        extra = closure.length - selected.length
        say "--only matched #{selected.length} root(s); added #{extra} require_relative dependenc(ies) to close them" if extra.positive?
        closure
      end

      def selected_g3_units(units)
        return selected_changed_g3_units(units) if incremental?
        return units unless @g3_from_report

        prior = JSON.parse(File.binread(@g3_from_report))
        failed_sources = prior.fetch("units").filter_map do |unit|
          unit.fetch("source") if unit.dig("gates", "g3") == "fail"
        end.to_h { |source| [source, true] }
        selected = units.select { |unit| failed_sources[unit.fetch("source")] }
        missing = failed_sources.keys - units.map { |unit| unit.fetch("source") }
        say "G3 candidate report contains #{missing.length} source(s) outside the current corpus" if missing.any?
        selected
      end

      # A changed run is deliberately dependency-closed.  It reuses immutable
      # G0--G2 artifacts for source-identical units, then recompiles every
      # generated consumer of an invalidated unit (and its entire SCC).  The
      # frontend still receives the complete generated package set, so this is
      # not the unsound "compile one file in isolation" shortcut.
      def incremental?
        @changed_paths.any?
      end

      def prepare_incremental_reuse(units)
        raise "--changed requires --reuse-report from a completed verifier run" unless @reuse_report_path
        raise "--changed cannot be combined with --g3-from-report" if @g3_from_report

        @reuse_report = JSON.parse(File.binread(@reuse_report_path))
        unless @reuse_report["manifest_sha256"] == @manifest_hash
          raise "reuse report manifest does not match the current manifest"
        end
        unless reuse_helper_config_sha256 == @helper_config_sha256
          raise "reuse report helper configuration does not match the current helper configuration"
        end
        validate_reuse_toolchain!
        @reuse_frontend_results = reuse_compiler_frontend_sha256 == @compiler_frontend_sha256 &&
          !@reuse_toolchain_changed
        @reuse_artifact_root = File.expand_path(@reuse_report.fetch("artifact_root"), root)
        unless File.directory?(File.join(@reuse_artifact_root, "raw", "compiler", "src"))
          raise "reuse report artifact root has no raw generated CLEAR artifacts"
        end

        @cached_units_by_source = @reuse_report.fetch("units").to_h { |unit| [unit.fetch("source"), unit] }
        changed_sources = @changed_paths.select { |path| @units_by_source.key?(path) }
        outside_corpus = @changed_paths - changed_sources
        unless outside_corpus.empty?
          raise "--changed path(s) are outside this manifest corpus: #{outside_corpus.join(", ")}"
        end
        raise "--changed did not match a manifest source unit" if changed_sources.empty?

        # Transpilation is per-source: a require_relative consumer's CLEAR
        # text does not depend on its provider's contents.  Re-render only
        # changed/missing sources, but retain the reverse source closure as a
        # G3 seed because those consumers must be recompiled against the new
        # generated dependency.
        invalidated_sources = changed_sources.to_h { |source| [source, true] }
        @cache_hits = 0
        cache_misses = []
        units.each do |unit|
          next if invalidated_sources[unit.fetch("source")]

          cache_misses << unit unless reuse_unit!(unit)
        end
        @invalidated_units = units.select do |unit|
          invalidated_sources[unit.fetch("source")] || cache_misses.include?(unit)
        end
        g3_sources = reverse_closure(
          @invalidated_units.map { |unit| unit.fetch("source") }, units, "source", "source_dependencies"
        )
        @g3_seed_units = units.select { |unit| g3_sources[unit.fetch("source")] }
        @cache_misses = @invalidated_units.length
        if @reuse_toolchain_changed
          say "focused toolchain-change mode: unchanged generated CLEAR is reused from the prior run; " \
              "results validate the selected dependency-closed delta but are not a full-toolchain census"
        end
        say "incremental cache: #{@cache_hits} G0-G2 hit(s), #{@cache_misses} invalidated/missing; " \
            "#{@invalidated_units.length} source unit(s) will run; #{@g3_seed_units.length} source consumer(s) seed G3"
      end

      def reuse_unit!(unit)
        cached = @cached_units_by_source[unit.fetch("source")]
        return false unless cached && cached_source_sha256(cached) == unit.fetch("source_sha256")

        cached_target = File.join(@reuse_artifact_root, "raw", "compiler", "src", unit.fetch("generated_relative"))
        cached_g1_pass = cached.dig("gates", "g1") == "pass"
        return false if cached_g1_pass && !File.file?(cached_target)

        %w[gates generated_sha256 generated_bytes typed_ir prism_nodes diagnostics failure autofix].each do |key|
          unit[key] = deep_copy(cached[key]) if cached.key?(key)
        end
        unless @reuse_frontend_results
          unit["gates"]["g3"] = "not_run"
          unit["gates"]["g4"] = "not_run"
          unit["autofix"] = { "g4" => "not_run" }
          unit.delete("failure") if unit.dig("gates", "g2") == "pass"
        end
        if cached_g1_pass
          FileUtils.mkdir_p(File.dirname(unit.fetch("raw_target")))
          FileUtils.cp(cached_target, unit.fetch("raw_target"))
        end
        unit["commands"] = {
          "cache" => {
            "reused_gates" => %w[g0 g1 g2],
            "report" => relative(@reuse_report_path),
            "artifact_root" => relative(@reuse_artifact_root)
          }
        }
        @cache_hits += 1
        true
      end

      def cached_source_sha256(cached)
        return cached["source_sha256"] if cached["source_sha256"]

        # Reports written before source hashes existed can still seed the
        # cache when their recorded Git revision is available locally.
        revision = @reuse_report["revision"]
        return unless revision && cached["source"]

        contents, status = Open3.capture2e("git", "show", "#{revision}:#{cached.fetch('source')}", chdir: root)
        Digest::SHA256.hexdigest(contents) if status.success?
      end

      def reuse_helper_config_sha256
        configured = @reuse_report.dig("configuration", "helper_config_sha256")
        return configured if configured

        helper_path = @manifest["helper_config"]
        revision = @reuse_report["revision"]
        return nil unless helper_path && revision

        contents, status = Open3.capture2e("git", "show", "#{revision}:#{helper_path}", chdir: root)
        Digest::SHA256.hexdigest(contents) if status.success?
      end

      def transpiler_toolchain_sha256
        roots = %w[
          gems/ruby-to-clear/lib
          gems/ruby-to-clear/exe
          gems/fact-mine/lib
          gems/fact-mine/bin
        ]
        paths = roots.flat_map do |relative_root|
          absolute_root = File.join(root, relative_root)
          if File.directory?(absolute_root)
            Dir[File.join(absolute_root, "**", "*.rb")]
          elsif File.file?(absolute_root)
            [absolute_root]
          else
            []
          end
        end
        executable = File.join(root, "gems/ruby-to-clear/exe/ruby-to-clear")
        paths << executable if File.file?(executable)
        relative_paths = paths.uniq.map { |path| relative(path) }.sort
        objects, status = Open3.capture2e("git", "hash-object", "--", *relative_paths, chdir: root)
        return "unavailable" unless status.success?

        payload = relative_paths.zip(objects.lines.map(&:strip)).map do |path, object|
          "#{path}\0#{object}"
        end
        Digest::SHA256.hexdigest(payload.join("\n"))
      end

      def reuse_transpiler_toolchain_sha256
        configured = @reuse_report.dig("configuration", "transpiler_toolchain_sha256")
        return configured if configured

        revision = @reuse_report["revision"]
        return nil unless revision

        roots = %w[
          gems/ruby-to-clear/lib
          gems/ruby-to-clear/exe
          gems/fact-mine/lib
          gems/fact-mine/bin
        ]
        listing, status = Open3.capture2e("git", "ls-tree", "-r", revision, "--", *roots, chdir: root)
        return nil unless status.success?

        pairs = listing.lines.filter_map do |line|
          metadata, path = line.split("\t", 2)
          object = metadata.to_s.split.last
          "#{path.to_s.strip}\0#{object}" if object && path
        end
        Digest::SHA256.hexdigest(pairs.sort.join("\n"))
      end

      def validate_reuse_toolchain!
        @reuse_toolchain_changed = reuse_transpiler_toolchain_sha256 != @transpiler_toolchain_sha256
        return unless @reuse_toolchain_changed && !@allow_toolchain_change

        raise "reuse report transpiler toolchain does not match the current implementation; " \
              "run a full verifier pass or use --allow-toolchain-change for focused, non-authoritative validation"
      end

      def compiler_frontend_sha256
        paths, status = Open3.capture2e("git", "ls-files", "-z", "--", "compiler/ruby", chdir: root)
        return "unavailable" unless status.success?

        relative_paths = paths.split("\0").reject(&:empty?).sort
        objects, object_status = Open3.capture2e("git", "hash-object", "--", *relative_paths, chdir: root)
        return "unavailable" unless object_status.success?

        Digest::SHA256.hexdigest(relative_paths.zip(objects.lines.map(&:strip)).map { |path, object| "#{path}\0#{object}" }.join("\n"))
      end

      def reuse_compiler_frontend_sha256
        configured = @reuse_report.dig("configuration", "compiler_frontend_sha256")
        return configured if configured

        revision = @reuse_report["revision"]
        return nil unless revision

        listing, status = Open3.capture2e("git", "ls-tree", "-r", revision, "--", "compiler/ruby", chdir: root)
        return nil unless status.success?

        pairs = listing.lines.filter_map do |line|
          metadata, path = line.split("\t", 2)
          object = metadata.to_s.split.last
          "#{path.to_s.strip}\0#{object}" if object && path
        end
        Digest::SHA256.hexdigest(pairs.join("\n"))
      end

      def selected_changed_g3_units(units)
        seed = @g3_seed_units.map { |unit| unit.fetch("generated_relative") }
        selected_relatives = reverse_closure(seed, units, "generated_relative", "generated_dependencies")
        selected = units.select { |unit| selected_relatives[unit.fetch("generated_relative")] }
        expand_package_groups(selected, units)
      end

      def reset_cached_frontend_result!(unit)
        return unless unit.dig("gates", "g2") == "pass"

        unit["gates"]["g3"] = "not_run"
        unit["gates"]["g4"] = "not_run"
        unit["autofix"] = { "g4" => "not_run" }
        unit.delete("failure")
        unit["diagnostics"] = Array(unit["diagnostics"]).reject do |diagnostic|
          %w[frontend backend].include?(diagnostic["stage"])
        end
      end

      def reverse_closure(seed, units, key, dependencies_key)
        reverse = Hash.new { |hash, item| hash[item] = [] }
        units.each do |unit|
          unit.fetch(dependencies_key, []).each { |dependency| reverse[dependency] << unit.fetch(key) }
        end
        selected = seed.to_h { |item| [item, true] }
        queue = seed.dup
        until queue.empty?
          current = queue.shift
          reverse[current].each do |consumer|
            next if selected[consumer]

            selected[consumer] = true
            queue << consumer
          end
        end
        selected
      end

      def expand_package_groups(selected, units)
        selected_relatives = selected.to_h { |unit| [unit.fetch("generated_relative"), true] }
        (@package_groups || {}).each_value do |members|
          next unless members.any? { |relative_path| selected_relatives[relative_path] }

          members.each { |relative_path| selected_relatives[relative_path] = true }
        end
        units.select { |unit| selected_relatives[unit.fetch("generated_relative")] }
      end

      def source_dependency_paths(source)
        result = Prism.parse_file(source)
        return [] if result.failure?

        dependencies = []
        walk = lambda do |node|
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name.to_s == "require_relative"
            argument = node.arguments&.arguments&.first
            if argument.is_a?(Prism::StringNode)
              candidate = argument.content.end_with?(".rb") ? argument.content : "#{argument.content}.rb"
              absolute = File.expand_path(candidate, File.dirname(source))
              if absolute.start_with?("#{@source_root}/") || absolute == @source_root
                dependencies << relative(absolute)
              end
            end
          end
          node.child_nodes.each { |child| walk.call(child) if child }
        end
        walk.call(result.value)
        dependencies.uniq.sort
      end

      def index_generated_dependencies(units)
        units.each do |unit|
          target = unit.fetch("raw_target")
          next unless File.file?(target)

          dependencies = []
          File.foreach(target) do |line|
            spec = line[/\AREQUIRE\s+"([^"]+)"/, 1]
            next unless spec

            if spec.start_with?("pkg:rtoc_")
              relative_path = generated_relative_from_package(spec.delete_prefix("pkg:"))
              dependencies << relative_path if relative_path
              next
            end
            next if spec.start_with?("pkg:")

            absolute = File.expand_path(spec, File.dirname(target))
            relative_path = relative_to(absolute, @raw_generated_root)
            dependencies << relative_path
          end
          unit["generated_dependencies"] = dependencies.uniq.sort
        end
      end

      def index_generated_source_lines(units)
        @generated_line_index = Hash.new { |hash, key| hash[key] = [] }
        units.each do |unit|
          target = unit.fetch("raw_target")
          next unless File.file?(target)

          File.foreach(target).with_index(1) do |line, line_number|
            content = line.strip
            next if content.empty?

            @generated_line_index[[line_number, content]] << unit.fetch("generated_relative")
          end
        end
      end

      def parse_and_transpile(unit)
        source = File.binread(unit.fetch("source_absolute"))
        result = Prism.parse(source)
        unit["prism_nodes"] = count_prism_nodes(result.value)
        if result.failure?
          unit["gates"]["g0"] = "fail"
          diagnostic = result.errors.map(&:message).join("; ")
          fail_unit(unit, "R0", diagnostic, stage: "ruby_parse")
          unit["gates"]["g1"] = "skipped"
          later_skipped(unit)
          return progress(unit, "R0")
        end
        unit["gates"]["g0"] = "pass"

        FileUtils.mkdir_p(File.dirname(unit.fetch("raw_target")))
        dir = unit_artifact_dir(unit, "raw")
        typed_ir_report_path = File.join(dir, "typed-ir.json")
        command = [RbConfig.ruby, File.join(root, "gems/ruby-to-clear/exe/ruby-to-clear"), "--strict"]
        helper_config = @manifest["helper_config"]
        command += ["--helper-config", File.expand_path(helper_config, root)] if helper_config
        cfg_facts_path = @cfg_facts_by_source&.fetch(unit.fetch("source_absolute"), nil)
        command += ["--cfg-facts", cfg_facts_path] if cfg_facts_path
        command += ["--typed-ir-report", typed_ir_report_path]
        command << unit.fetch("source_absolute")
        run = @runner.run(command, stdout_path: unit.fetch("raw_target"),
                          stderr_path: File.join(dir, "transpile.stderr.log"),
                          timeout_seconds: timeout_seconds, chdir: root)
        unit["commands"]["transpile"] = portable_run(run)
        unit["typed_ir"] = JSON.parse(File.read(typed_ir_report_path)) if File.file?(typed_ir_report_path)
        diagnostic = @runner.diagnostic_text(run)
        unless run["success"]
          code = run["timed_out"] || run["harness_error"] ? "H0" : "T0"
          unit["gates"]["g1"] = "fail"
          FileUtils.rm_f(unit.fetch("raw_target"))
          fail_unit(unit, code, diagnostic, stage: "transpile")
          later_skipped(unit)
          return progress(unit, code)
        end

        output = File.binread(unit.fetch("raw_target"))
        forbidden = @manifest.fetch("forbidden_output_patterns", []).select { |marker| output.include?(marker) }
        if forbidden.any?
          unit["gates"]["g1"] = "fail"
          fail_unit(unit, "T1", "forbidden output marker(s): #{forbidden.join(", ")}", stage: "transpile")
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
        fail_unit(unit, "H0", "#{e.class}: #{e.message}", stage: "transpile")
        later_skipped(unit)
        progress(unit, "H0")
      end

      def prepare_cfg_facts(units)
        binary = fact_mine_binary
        unless binary
          say "CFG admission: fact-mine-rust unavailable; typed IR will remain on the legacy path"
          return
        end

        @cfg_facts_path = File.join(@artifact_root, "fact-mine-cfg.json")
        stderr_path = File.join(@artifact_root, "fact-mine-cfg.stderr.log")
        command = [binary, "syntax-facts", "--language", "ruby", *units.map { |unit| unit.fetch("source_absolute") }]
        run = @runner.run(
          command,
          stdout_path: @cfg_facts_path,
          stderr_path: stderr_path,
          timeout_seconds: timeout_seconds,
          chdir: root
        )
        if run["success"]
          if partition_cfg_facts(units)
            return say("CFG admission: loaded one FactMine batch and partitioned #{units.length} unit file(s)")
          end
          return
        end

        @cfg_facts_path = nil
        @cfg_facts_by_source = nil
        say "CFG admission: FactMine batch failed; typed IR will remain on the legacy path"
      end

      def partition_cfg_facts(units)
        payload = JSON.parse(File.binread(@cfg_facts_path))
        documents = payload.fetch("documents")
        documents_by_source = documents.to_h do |document|
          [File.expand_path(document.fetch("file"), root), document]
        end
        facts_root = File.join(@artifact_root, "fact-mine-cfg")
        FileUtils.mkdir_p(facts_root)
        envelope = payload.reject { |key, _value| key == "documents" }

        @cfg_facts_by_source = units.to_h do |unit|
          source = unit.fetch("source_absolute")
          document = documents_by_source.fetch(File.expand_path(source, root))
          path = File.join(facts_root, "#{unit.fetch('id')}.json")
          File.binwrite(path, JSON.generate(envelope.merge("documents" => [document])))
          [source, path]
        end
      rescue KeyError, JSON::ParserError => e
        @cfg_facts_by_source = nil
        say "CFG admission: could not partition FactMine batch (#{e.class}: #{e.message}); typed IR will remain on the legacy path"
      end

      def fact_mine_binary
        configured = ENV["FACT_MINE_RUST_BINARY"]
        candidates = [
          configured,
          File.join(root, "gems/fact-mine/target/release/fact-mine-rust"),
          File.join(root, "gems/fact-mine/target/debug/fact-mine-rust")
        ].compact
        candidates.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      end

      def compile_frontend(unit, generated_root, variant)
        gates = variant == "raw" ? unit.fetch("gates") : (unit["autofix"] ||= {})
        prerequisite = gates["g2"] == "pass"
        unless prerequisite
          gates["g3"] = "skipped"
          return
        end

        if variant == "raw" && (group = unit["package_group"])
          return apply_group_result(unit, group, "frontend")
        end

        missing = missing_dependencies(variant_target(unit, generated_root), generated_root)
        if missing.any?
          gates["g3"] = "fail"
          message = "missing generated dependency: #{missing.first}"
          if variant == "raw"
            providers = missing.filter_map { |path| @units_by_generated[path] }
            details = { "missing_dependencies" => missing }
            if providers.any?
              details["secondary"] = true
              details["blocked_by"] = providers.map do |provider|
                {
                  "source" => provider.fetch("source"),
                  "gate" => provider.dig("gates", "g1"),
                  "failure_code" => provider.dig("failure", "code"),
                  "failure_fingerprint" => provider.dig("failure", "fingerprint")
                }
              end
              unit["blocked_by"] = details.fetch("blocked_by")
            end
            fail_unit(unit, "C1", message, details: details, stage: "dependency")
          else
            record_diagnostics(unit, "C1", message, stage: "dependency", variant: variant)
          end
          return progress(unit, "#{variant} C1 dependency")
        end

        dir = unit_artifact_dir(unit, variant)
        command = [RbConfig.ruby, File.join(root, "compiler/ruby/backends/transpiler.rb"),
                   "--default-stack", "Large"]
        @manifest.fetch("packages", {}).each do |name, path|
          command += ["--pkg", "#{name}=#{File.expand_path(path, root)}"]
        end
        generated_package_paths(generated_root).each do |name, path|
          command += ["--pkg", "#{name}=#{path}"]
        end
        command += group_pkg_flags(generated_root)
        command << variant_target(unit, generated_root)
        run = @runner.run(command, stdout_path: File.join(dir, "generated.zig"),
                          stderr_path: File.join(dir, "frontend.stderr.log"),
                          timeout_seconds: timeout_seconds, chdir: root)
        command_key = variant == "raw" ? "frontend" : "autofix_frontend"
        unit["commands"][command_key] = portable_run(run)
        if run["success"]
          gates["g3"] = "pass"
          return progress(unit, "#{variant} G3 pass")
        end

        diagnostic = @runner.diagnostic_text(run)
        code = self.class.classify(diagnostic, timed_out: run["timed_out"] || run["harness_error"])
        record_diagnostics(unit, code, diagnostic, stage: "frontend", variant: variant)
        gates["g3"] = "fail"
        fail_unit(unit, code, diagnostic, stage: "frontend", record: false) if variant == "raw"
        progress(unit, "#{variant} #{code}")
      end

      def parse_generated(unit, generated_root, variant)
        gates = variant == "raw" ? unit.fetch("gates") : (unit["autofix"] ||= {})
        prerequisite = variant == "raw" ? gates["g1"] == "pass" : File.file?(variant_target(unit, generated_root))
        unless prerequisite
          gates["g2"] = "skipped"
          return
        end

        dir = unit_artifact_dir(unit, variant)
        command = [
          RbConfig.ruby,
          File.join(root, "gems/ruby-to-clear/analysis/bin/clear-parse"),
          variant_target(unit, generated_root)
        ]
        run = @runner.run(
          command,
          stdout_path: File.join(dir, "parser.stdout.log"),
          stderr_path: File.join(dir, "parser.stderr.log"),
          timeout_seconds: timeout_seconds,
          chdir: root
        )
        command_key = variant == "raw" ? "parser" : "autofix_parser"
        unit["commands"][command_key] = portable_run(run)
        if run["success"]
          gates["g2"] = "pass"
          return progress(unit, "#{variant} G2 pass")
        end

        gates["g2"] = "fail"
        diagnostic = @runner.diagnostic_text(run)
        code = run["timed_out"] || run["harness_error"] ? "H0" : "C0"
        record_diagnostics(unit, code, diagnostic, stage: "parser", variant: variant)
        fail_unit(unit, code, diagnostic, stage: "parser", record: false) if variant == "raw"
        progress(unit, "#{variant} #{code}")
      end

      def build_zig(unit, generated_root, variant)
        gates = variant == "raw" ? unit.fetch("gates") : unit.fetch("autofix")
        unless gates["g3"] == "pass"
          gates["g4"] = "skipped"
          return
        end

        if variant == "raw" && (group = unit["package_group"])
          return apply_group_result(unit, group, "build")
        end

        provision_native_modules(variant_target(unit, generated_root))
        dir = unit_artifact_dir(unit, variant)
        command = [File.join(root, "clear"), "test", variant_target(unit, generated_root), "--strict"]
        @manifest.fetch("packages", {}).each do |name, path|
          command += ["--pkg", "#{name}=#{File.expand_path(path, root)}"]
        end
        generated_package_paths(generated_root).each do |name, path|
          command += ["--pkg", "#{name}=#{path}"]
        end
        command += group_pkg_flags(generated_root)
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
        record_diagnostics(unit, code, diagnostic, stage: "backend", variant: variant)
        fail_unit(unit, code, diagnostic, stage: "backend", record: false) if variant == "raw"
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
        parallel_map!(retry_units) { |unit| parse_generated(unit, fixed_root, "autofix") }
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

      # Cyclic clusters of generated units (mutually-referential Ruby modules)
      # compile as ONE multi-file package: the acyclic-import rule applies
      # between packages, not between a package's files. Each SCC of size > 1
      # becomes a package group; its members share the group's gate results.
      def group_cyclic_units!(units)
        @package_groups = {}
        @group_runs = {}
        by_rel = units.to_h { |unit| [unit.fetch("generated_relative"), unit] }
        # The graph spans every generated file, not only the selected units. A
        # cycle can run through a file this run did not select -- under --only
        # the imported dependencies come from the checked-in tree -- and a
        # graph restricted to units cannot see it. The compiler then receives
        # those files as separate packages and rejects the import cycle, so a
        # scoped run reports CircularDependencyError for its whole corpus and
        # hides every real diagnostic behind it.
        graph = generated_dependency_graph(@raw_generated_root, by_rel)

        tarjan_sccs(graph).each do |scc|
          next unless scc.length > 1

          members = scc.sort
          group_name = "scc_#{File.basename(members.fetch(0), ".clear")}_#{members.length}"
          @package_groups[group_name] = members
          members.each { |rel| by_rel[rel]&.[]=("package_group", group_name) }
        end
      end

      # Relative path => generated REQUIRE targets, over the whole generated
      # tree. Unit dependencies are already indexed; anything else is read off
      # disk, which is what makes cycles through non-selected files visible.
      def generated_dependency_graph(generated_root, by_rel)
        graph = {}
        Dir[File.join(generated_root, "**/*.clear")].sort.each do |path|
          rel = relative_to(path, generated_root)
          unit = by_rel[rel]
          deps = unit ? unit.fetch("generated_dependencies") : generated_requires(path)
          graph[rel] = deps.select { |dep| dep != rel && File.file?(File.join(generated_root, dep)) }
        end
        graph
      end

      def generated_requires(path)
        File.foreach(path).filter_map do |line|
          spec = line[/\AREQUIRE\s+"([^"]+)"/, 1]
          next unless spec

          if spec.start_with?("pkg:rtoc_")
            generated_relative_from_package(spec.delete_prefix("pkg:"))
          elsif !spec.start_with?("pkg:")
            File.expand_path(spec, File.dirname(path)).delete_prefix("#{File.expand_path(@raw_generated_root)}/")
          end
        end.compact
      end

      # Iterative Tarjan (the corpus graph is deep enough to blow Ruby's
      # default recursion limit).
      def tarjan_sccs(graph)
        index = {}
        low = {}
        on_stack = {}
        stack = []
        sccs = []
        counter = 0

        graph.each_key do |root|
          next if index.key?(root)

          work = [[root, 0]]
          until work.empty?
            node, edge_i = work.last
            if edge_i.zero?
              index[node] = low[node] = counter
              counter += 1
              stack << node
              on_stack[node] = true
            end
            advanced = false
            neighbors = graph.fetch(node, [])
            while edge_i < neighbors.length
              neighbor = neighbors.fetch(edge_i)
              edge_i += 1
              if !index.key?(neighbor)
                work[-1] = [node, edge_i]
                work << [neighbor, 0]
                advanced = true
                break
              elsif on_stack[neighbor]
                low[node] = [low.fetch(node), index.fetch(neighbor)].min
              end
            end
            next if advanced

            work.pop
            if low.fetch(node) == index.fetch(node)
              component = []
              loop do
                popped = stack.pop
                on_stack[popped] = false
                component << popped
                break if popped == node
              end
              sccs << component
            end
            unless work.empty?
              parent = work.last.fetch(0)
              low[parent] = [low.fetch(parent), low.fetch(node)].min
            end
          end
        end
        sccs
      end

      # A grouped unit's fate IS its package group's fate: apply the group's
      # single shared run to the member's gates and diagnostics.
      def apply_group_result(unit, group, phase)
        gates = unit.fetch("gates")
        run = @group_runs[[phase, group]]
        unless run
          if phase == "frontend"
            gates["g3"] = "fail"
            fail_unit(unit, "C1", "blocked: cyclic package group '#{group}' has a member that failed G2", stage: "dependency")
          else
            gates["g4"] = "skipped"
          end
          return progress(unit, "raw #{phase} group-blocked")
        end

        unit["commands"]["#{phase}_group"] = portable_run(run)
        if run["success"]
          if phase == "frontend"
            gates["g3"] = "pass"
            return progress(unit, "raw G3 pass (pkg:#{group})")
          end
          gates["g4"] = "pass"
          return progress(unit, "raw G4 pass (pkg:#{group})")
        end

        diagnostic = @runner.diagnostic_text(run)
        timed_out = run["timed_out"] || run["harness_error"]
        if phase == "frontend"
          code = self.class.classify(diagnostic, timed_out: timed_out)
          record_diagnostics(unit, code, diagnostic, stage: "frontend", variant: "raw")
          gates["g3"] = "fail"
          fail_unit(unit, code, diagnostic, stage: "frontend", record: false)
        else
          code = self.class.classify(diagnostic, timed_out: timed_out, backend: true)
          gates["g4"] = "fail"
          record_diagnostics(unit, code, diagnostic, stage: "backend", variant: "raw")
          fail_unit(unit, code, diagnostic, stage: "backend", record: false)
        end
        progress(unit, "raw #{code} (pkg:#{group})")
      end

      def group_pkg_flags(generated_root)
        (@package_groups || {}).flat_map do |name, members|
          spec = members.map { |rel| File.join(generated_root, rel) }.join(",")
          ["--pkg", "#{name}=#{spec}"]
        end
      end

      # Run each package group's gate command ONCE; members consume the shared
      # result in compile_frontend / build_zig.
      def run_package_groups(units, generated_root, phase, selected_units: units)
        return if (@package_groups || {}).empty?

        by_rel = units.to_h { |unit| [unit.fetch("generated_relative"), unit] }
        selected_relatives = selected_units.to_h { |unit| [unit.fetch("generated_relative"), true] }
        groups = @package_groups.to_a.select do |_name, members|
          members.any? { |relative_path| selected_relatives[relative_path] }
        end
        parallel_map!(groups) do |(name, members)|
          # A group can contain files this run did not select as units; they
          # carry no gates of their own and only have to be present on disk.
          member_units = members.filter_map { |rel| by_rel[rel] }
          if phase == "frontend"
            next unless member_units.all? { |u| u.dig("gates", "g2") == "pass" }
          else
            next unless member_units.all? { |u| u.dig("gates", "g3") == "pass" }
          end

          dir = File.join(@artifact_root, "groups", name)
          FileUtils.mkdir_p(dir)
          command = if phase == "frontend"
            [RbConfig.ruby, File.join(root, "compiler/ruby/backends/transpiler.rb"), "--default-stack", "Large"]
          else
            [File.join(root, "clear"), "test", "pkg:#{name}", "--strict"]
          end
          @manifest.fetch("packages", {}).each do |pkg, path|
            command += ["--pkg", "#{pkg}=#{File.expand_path(path, root)}"]
          end
          generated_package_paths(generated_root).each do |pkg, path|
            command += ["--pkg", "#{pkg}=#{path}"]
          end
          command += group_pkg_flags(generated_root)
          command << "pkg:#{name}" if phase == "frontend"
          run = @runner.run(command,
                            stdout_path: File.join(dir, "#{phase}.stdout.log"),
                            stderr_path: File.join(dir, "#{phase}.stderr.log"),
                            timeout_seconds: timeout_seconds, chdir: root,
                            env: phase == "build" ? { "NO_COLOR" => "1" } : {})
          @group_runs[[phase, name]] = run
        end
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

            if spec.start_with?("pkg:rtoc_")
              package = spec.delete_prefix("pkg:")
              dependency = generated_package_paths(generated_root)[package]
              if dependency
                visit.call(dependency)
              elsif (relative_path = generated_relative_from_package(package))
                missing << relative_path
              end
              next
            end
            next if spec.start_with?("pkg:")

            visit.call(File.expand_path(spec, File.dirname(expanded)))
          end
        end
        visit.call(target)
        missing.uniq.sort
      end

      def modular_dependencies?
        helper_path = @manifest["helper_config"]
        return false unless helper_path

        @helper_config ||= HelperConfig.load(File.expand_path(helper_path, root))
        @helper_config.modular_dependencies?
      end

      def generated_package_paths(generated_root)
        @generated_package_paths ||= {}
        key = File.expand_path(generated_root)
        @generated_package_paths[key] ||= Dir[File.join(key, "**/*.clear")].sort.each_with_object({}) do |target, packages|
          relative_path = Pathname.new(target).relative_path_from(Pathname.new(key)).to_s
          packages[HelperConfig.dependency_package_name(relative_path)] = target
        end
      end

      def generated_relative_from_package(package)
        hex = package.to_s.delete_prefix("rtoc_")
        return nil unless hex.match?(/\A(?:[0-9a-f]{2})+\z/)

        [hex].pack("H*")
      end

      def provision_generated_packages(generated_root)
        package_root = File.join(@artifact_root, "packages")
        FileUtils.rm_rf(package_root)
        generated_package_paths(generated_root).each do |name, target|
          lib = File.join(package_root, name, "src", "lib.clear")
          FileUtils.mkdir_p(File.dirname(lib))
          FileUtils.ln_s(target, lib)
        end
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
            "g4_enabled" => @run_g4,
            "only" => @only&.source,
            "g3_from_report" => @g3_from_report && relative(@g3_from_report),
            "changed" => @changed_paths,
            "reuse_report" => @reuse_report_path && relative(@reuse_report_path),
            "incremental_scope" => incremental? ? "changed source reverse-dependency closure plus generated REQUIRE consumers and SCCs" : nil,
            "focused_toolchain_change" => incremental? && !!@reuse_toolchain_changed,
            "cache_hits" => @cache_hits,
            "cache_misses" => @cache_misses,
            "helper_config_sha256" => @helper_config_sha256,
            "transpiler_toolchain_sha256" => @transpiler_toolchain_sha256,
            "compiler_frontend_sha256" => @compiler_frontend_sha256,
            "reused_frontend_results" => @reuse_frontend_results,
            "g3_selected_roots" => @incremental_g3_selected,
            "g4_selected_roots" => @incremental_g4_selected
          },
          "units" => clean_units
        }
        report["aggregate"] = Reporter.aggregate(clean_units)
        report["typed_ir"] = aggregate_typed_ir(clean_units)
        report["prism_nodes"] = Reporter.node_metrics(clean_units)
        report
      end

      def aggregate_typed_ir(units)
        reports = units.filter_map { |unit| unit["typed_ir"] }
        functions = reports.flat_map { |report| Array(report["functions"]) }
        consumption = Hash.new(0)
        ownership_modes = Hash.new(0)
        reports.each do |report|
          aggregate = report.fetch("aggregate", {})
          aggregate.fetch("cfg_consumption", {}).each { |name, count| consumption[name] += count }
          aggregate.fetch("ownership_modes", {}).each { |name, count| ownership_modes[name] += count }
        end
        admitted = functions.count { |function| function["admitted"] }
        {
          "reported_units" => reports.length,
          "functions" => functions.length,
          "admitted_functions" => admitted,
          "rejected_functions" => functions.length - admitted,
          "admission_percent" => functions.empty? ? 0.0 : (100.0 * admitted / functions.length).round(2),
          "rejection_reasons" => functions.filter_map do |function|
            function["reason"] unless function["admitted"]
          end.tally.sort.to_h,
          "cfg_consumption" => consumption.sort.to_h,
          "ownership_modes" => ownership_modes.sort.to_h
        }
      end

      def write_reports(report)
        FileUtils.mkdir_p(@report_dir)
        safe_report = utf8_safe(report)
        json = JSON.pretty_generate(safe_report) + "\n"
        markdown = Reporter.markdown(safe_report)
        File.write(File.join(@artifact_root, "report.json"), json)
        File.write(File.join(@artifact_root, "report.md"), markdown)
        File.write(File.join(@report_dir, "latest.json"), json)
        File.write(File.join(@report_dir, "latest.md"), markdown)
        say "Reports: #{relative(File.join(@report_dir, "latest.json"))} and #{relative(File.join(@report_dir, "latest.md"))}"
      end

      def utf8_safe(value)
        case value
        when String
          value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
        when Array
          value.map { |item| utf8_safe(item) }
        when Hash
          value.to_h { |key, item| [utf8_safe(key), utf8_safe(item)] }
        else
          value
        end
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
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
              fail_unit(item, "H0", "#{e.class}: #{e.message}", stage: "harness") if item
              progress(item, "H0 harness") if item
            end
          end
        end
        workers.each(&:join)
      end

      def fail_unit(unit, code, diagnostic, details: {}, stage: "unknown", record: true)
        record_diagnostics(unit, code, diagnostic, stage: stage, variant: "raw") if record
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

      def record_diagnostics(unit, code, diagnostic, stage:, variant:)
        target = if variant == "raw"
                   unit["diagnostics"] ||= []
                 else
                   unit["autofix"] ||= {}
                   unit["autofix"]["diagnostics"] ||= []
                 end
        extracted = DiagnosticInventory.extract(diagnostic, fallback_code: code, stage: stage)
        extracted.each do |item|
          item["generated_relative"] = unit.fetch("generated_relative")
          infer_diagnostic_provider!(item) if stage == "frontend" || stage == "backend"
          target << item
        end
      end

      def infer_diagnostic_provider!(diagnostic)
        line = diagnostic["line"]
        excerpt = diagnostic["source_excerpt"]&.strip
        return unless line && excerpt && @generated_line_index

        providers = @generated_line_index.fetch([line, excerpt], [])
        diagnostic["provider"] = providers.first if providers.length == 1
        diagnostic["provider_candidates"] = providers if providers.length > 1
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
        stdout, status = Open3.capture2e("git", "rev-parse", "HEAD", chdir: root)
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
