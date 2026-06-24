# typed: false
# frozen_string_literal: true

module NilKill
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      # Self-heal first: if a prior `collect` crashed mid-instrumentation
      # src/ is still wrapped. Restore pristine bytes BEFORE any guard or
      # subcommand reads src (a stale wrapped tree poisons everything).
      NilKill.ensure_src_restored!
      command = @argv.shift
      case command
      when "collect" then collect
      when "infer" then guard_fresh_runtime!; Infer.new(@argv).run
      when "static" then Commands::StaticCommand.new(@argv).run
      when "collect-runtime" then Commands::CollectRuntimeCommand.new(@argv).run
      when "collect-python" then Commands::CollectPythonCommand.new(@argv).run
      when "normalize" then Commands::NormalizeCommand.new(@argv).run
      when "analyze" then Commands::AnalyzeCommand.new(@argv).run
      when "trace-spec" then Commands::TraceSpecCommand.new(@argv).run
      when "focus-hash-record" then FocusHashRecord.new(@argv).run
      when "report" then guard_fresh_evidence! unless explicit_evidence_path?(@argv); Report.new(@argv).run
      when "struct-rbi" then StructRBI.new(@argv).run
      when "doctor" then Doctor.new.run
      when "help", nil then help
      else
        warn "unknown command: #{command}"
        help
        exit 2
      end
    end

    STALE_OVERRIDE = "--allow-stale-runtime"
    COLLECT_HINT = "bundle exec tools/nil-kill collect -- bash tools/clear-nil-kill-runtime.sh"

    def collect_meta_path
      File.join(RUNTIME_DIR, "collect-meta.json")
    end

    def explicit_evidence_path?(argv)
      argv.any? { |arg| arg == "--evidence" || arg.start_with?("--evidence=") }
    end

    def git_capture(*args)
      out, status = Open3.capture2e("git", "-C", ROOT, *args)
      status.success? ? out : nil
    rescue StandardError
      nil
    end

    # Snapshot the src/ state the collect ran against: HEAD + the
    # working-tree status of the target dirs. Compared content-wise at
    # guard time, so a git-touched mtime (the false-positive that
    # forced an override) no longer trips it.
    def write_collect_meta!
      head = git_capture("rev-parse", "HEAD")
      return unless head
      status = git_capture("status", "--porcelain", "--", *NilKill.target_dirs)
      File.write(collect_meta_path,
        JSON.generate("head" => head.strip, "dirty" => status.to_s))
    rescue StandardError
      nil
    end

    # false  = targets provably unchanged since collect (fresh)
    # Array  = [collect_head, cur_head, [changed files]] (stale)
    # :unknown = no metadata / git unavailable -> caller falls back to mtime
    def targets_changed_since_collect
      return :unknown unless File.file?(collect_meta_path)
      meta = JSON.parse(File.read(collect_meta_path))
      cur_head = git_capture("rev-parse", "HEAD")&.strip or return :unknown
      status = git_capture("status", "--porcelain", "--", *NilKill.target_dirs) or return :unknown
      return false if cur_head == meta["head"] && status == meta["dirty"].to_s
      files = []
      if cur_head != meta["head"]
        diff = git_capture("diff", "--name-only", "#{meta["head"]}..#{cur_head}", "--", *NilKill.target_dirs)
        files.concat(diff.to_s.split("\n"))
      end
      files.concat(status.to_s.lines.map { |l| l[3..].to_s })
      files = files.map(&:strip).reject { |f| f.empty? || f == "." }.uniq
      # HEAD moved / status differs but ZERO target files actually
      # changed (e.g. commits only touched gems/nil-kill, not src/) ->
      # the runtime is still valid. Fresh, not stale.
      return false if files.empty?
      [meta["head"], cur_head, files]
    rescue StandardError
      :unknown
    end

    def mtime_stale?(against_time)
      newest_src = NilKill.target_files.map { |f| File.mtime(f) rescue nil }.compact.max
      newest_src && against_time && newest_src > against_time
    end

    # Default-safe: refuse to infer on stale/partial runtime. Inferring
    # against stale runtime joins old method records onto changed code
    # -> joins miss, NoEvidence balloons. Git-aware (content, not mtime)
    # with an mtime fallback when git/metadata is unavailable.
    def guard_fresh_runtime!
      return if @argv.delete(STALE_OVERRIDE)
      runtime = Dir.glob(File.join(RUNTIME_DIR, "*.jsonl"))
      if runtime.empty?
        abort "nil-kill: NO runtime evidence in #{RUNTIME_DIR}. Inference would be 100% static -- partial and useless.\nCollect FULL evidence first:\n  #{COLLECT_HINT}\n(knowing override: nil-kill infer #{STALE_OVERRIDE})"
      end
      case (chg = targets_changed_since_collect)
      when false
        nil # provably unchanged since the collect -> fresh
      when Array
        meta_h, cur_h, files = chg
        more = files.size > 8 ? ", +#{files.size - 8} more" : ""
        abort "nil-kill: src/ changed since the collect that produced this runtime " \
          "(collect @ #{meta_h.to_s[0, 9]}, now #{cur_h.to_s[0, 9]}). Changed: #{files.first(8).join(", ")}#{more}.\n" \
          "Inferring now joins STALE runtime against changed code -- the partial-evidence trap.\n" \
          "Re-collect FULL evidence first:\n  #{COLLECT_HINT}\n(knowing override: nil-kill infer #{STALE_OVERRIDE})"
      else # :unknown -> conservative mtime fallback
        if mtime_stale?(runtime.map { |f| File.mtime(f) }.max)
          abort "nil-kill: src/ mtime is newer than the runtime and git metadata is unavailable (conservative).\n" \
            "Re-collect FULL evidence first:\n  #{COLLECT_HINT}\n(knowing override: nil-kill infer #{STALE_OVERRIDE})"
        end
      end
    end

    # Reports render from evidence.json; refuse a stale one (same
    # git-aware signal, then mtime fallback vs evidence.json).
    def guard_fresh_evidence!
      return if @argv.delete(STALE_OVERRIDE)
      evidence = File.join(TMP_DIR, "evidence.json")
      unless File.file?(evidence)
        abort "nil-kill: no evidence.json. Run a full collect + infer first.\n(knowing override: nil-kill report #{STALE_OVERRIDE})"
      end
      case (chg = targets_changed_since_collect)
      when false
        nil
      when Array
        meta_h, cur_h, files = chg
        more = files.size > 8 ? ", +#{files.size - 8} more" : ""
        abort "nil-kill: src/ changed since the collect behind this evidence " \
          "(collect @ #{meta_h.to_s[0, 9]}, now #{cur_h.to_s[0, 9]}). Changed: #{files.first(8).join(", ")}#{more}.\n" \
          "This report would be stale/partial. Re-collect + infer first.\n(knowing override: nil-kill report #{STALE_OVERRIDE})"
      else
        if mtime_stale?(File.mtime(evidence))
          abort "nil-kill: evidence.json is older than src/ and git metadata is unavailable (conservative). " \
            "Re-collect + infer first.\n(knowing override: nil-kill report #{STALE_OVERRIDE})"
        end
      end
    end

    def collect
      append = @argv.delete("--append-runtime")
      instrument_source = !@argv.delete("--no-instrument-source")
      instrument_source = true if @argv.delete("--instrument-source")
      commands = collect_commands
      abort "usage: bundle exec tools/nil-kill collect [--commands FILE] [--continue-on-error] -- <command...>" if commands.empty?
      FileUtils.rm_rf(RUNTIME_DIR) unless append
      FileUtils.mkdir_p(RUNTIME_DIR)
      write_collect_meta!
      trace_plan_enabled = ENV["NIL_KILL_TRACE_PLAN"] != "0"
      TracePlan.write if trace_plan_enabled
      snapshot_dir = File.join(RUNTIME_DIR, "src-snapshot")
      if instrument_source
        acquire_inplace_lock!
        # Sentinel + traps BEFORE the first byte of src is overwritten,
        # with the full candidate list -> a crash mid-wrap is healed.
        NilKill.write_inplace_sentinel!(snapshot_dir, NilKill.target_files.map { |f| NilKill.rel(f) })
        install_inplace_restore_traps!
        SourceInstrumenter.new.run_in_place(snapshot_dir)
      end
      tracer = File.expand_path("runtime_trace.rb", __dir__)
      rubyopt = (ENV["RUBYOPT"].to_s.split + ["-r#{tracer}"]).join(" ")
      env = ENV.to_h.merge("NIL_KILL_TRACE" => "1", "RUBYOPT" => rubyopt)
      # Source-wrap path: targeted TracePoints off by default (the
      # injected recorder is authoritative). No NIL_KILL_INSTRUMENTED_ROOT
      # any more -- the wrapped file IS the real src path.
      env["NIL_KILL_TRACE_METHODS"] ||= "0" if instrument_source && trace_plan_enabled
      continue = @argv.delete("--continue-on-error")
      begin
        commands.each_with_index do |cmd, i|
          puts "[#{i + 1}/#{commands.size}] NIL_KILL_TRACE=1 RUBYOPT=#{rubyopt.shellescape} #{cmd.shelljoin}"
          ok = system(env, *cmd)
          next if ok || continue
          exit($?&.exitstatus || 1)
        end
      ensure
        NilKill.restore_inplace_snapshot! if instrument_source
      end
      assert_collect_coverage_produced! if instrument_source
    end

    # A second concurrent `collect` would race in-place writes against
    # this one and corrupt src/. flock auto-releases on process exit.
    def acquire_inplace_lock!
      FileUtils.mkdir_p(RUNTIME_DIR)
      @collect_lock = File.open(File.join(RUNTIME_DIR, ".nk-collect.lock"), File::RDWR | File::CREAT, 0o644)
      return if @collect_lock.flock(File::LOCK_EX | File::LOCK_NB)
      abort "nil-kill: another `collect` is already running (in-place src instrumentation is exclusive). " \
        "Wait for it to finish or kill it; src/ will self-heal on the next nil-kill run."
    end

    # Restore pristine src on INT/TERM/HUP too (the ensure covers normal
    # exit and `exit`/raises; signals would otherwise leave src wrapped
    # until the next run's ensure_src_restored!). `prev` is block-local
    # per iteration, so the three traps don't clobber each other.
    def install_inplace_restore_traps!
      %w[INT TERM HUP].each do |sig|
        Signal.trap(sig) do
          NilKill.restore_inplace_snapshot!
          exit(false)
        end
      end
    end

    # A traced collect that produced ZERO Ruby Coverage means Coverage
    # failed to start in the workload; the dead-vs-missed split (unseen
    # vs collect_ran_untraced) then cannot be computed and would silently
    # degrade to "never_run". Make that a hard, loud failure instead.
    def assert_collect_coverage_produced!
      cov = Dir.glob(File.join(RUNTIME_DIR, "coverage-*.jsonl"))
      meth = Dir.glob(File.join(RUNTIME_DIR, "methods-*.jsonl"))
      cov_bytes = cov.sum { |f| File.size(f) }
      meth_bytes = meth.sum { |f| File.size(f) }
      if cov_bytes.zero? || meth_bytes.zero?
        abort "nil-kill: the traced collect produced NO usable evidence " \
          "(coverage=#{cov_bytes}B, method observations=#{meth_bytes}B in " \
          "#{NilKill.rel(RUNTIME_DIR)}). Empty .jsonl files exist but hold nothing -- " \
          "Coverage failed to start, or an exception escaped instrumented src during " \
          "require and aborted the run before any method returned. The dead-vs-missed " \
          "split cannot be computed. Fix the workload/tracer; do not infer on this collect."
      end
      by_pid = Hash.new { |h, k| h[k] = {} }
      cov.each { |f| (p = f[/-(\d+)\.jsonl\z/, 1]) && by_pid[p][:cov] = File.size(f) }
      meth.each { |f| (p = f[/-(\d+)\.jsonl\z/, 1]) && by_pid[p][:meth] = File.size(f) }
      ran = by_pid.values.select { |v| v[:cov].to_i.positive? }
      aborted = ran.count { |v| v[:meth].to_i.zero? }
      return unless aborted.positive? && aborted > ran.size - aborted
      abort "nil-kill: #{aborted}/#{ran.size} traced processes produced src coverage " \
        "but ZERO method observations -- a systemic instrumentation abort (an " \
        "exception escaping instrumented src during require zeroed those processes' " \
        "evidence). Aggregate .jsonl is non-empty only because other stages traced " \
        "normally; inference would use partial, misleading evidence. Fix the " \
        "workload/tracer; do not infer on this collect."
    end

    def collect_commands
      commands = []
      while (idx = @argv.index("--commands"))
        file = @argv[idx + 1] || abort("--commands requires a file")
        @argv.slice!(idx, 2)
        commands.concat(read_command_file(file))
      end
      while (idx = @argv.index("--cmd"))
        command = @argv[idx + 1] || abort("--cmd requires a command string")
        @argv.slice!(idx, 2)
        commands << Shellwords.split(command)
      end
      while (idx = @argv.index("--glob"))
        pattern = @argv[idx + 1] || abort("--glob requires a pattern")
        template_idx = @argv.index("--template") || abort("--glob requires --template")
        template = @argv[template_idx + 1] || abort("--template requires a command template")
        [idx, template_idx].sort.reverse_each { |remove_idx| @argv.slice!(remove_idx, 2) }
        Dir.glob(pattern).sort.each do |file|
          commands << Shellwords.split(template.gsub("{file}", file))
        end
      end
      sep = @argv.index("--")
      commands << @argv[(sep + 1)..] if sep
      commands
    end

    def read_command_file(path)
      File.readlines(path, chomp: true).filter_map do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")
        Shellwords.split(stripped)
      end
    end

    def help
      puts <<~TEXT
        Usage:
          bundle exec tools/nil-kill collect -- <command...>
          bundle exec tools/nil-kill collect --commands runtime-commands.txt
          bundle exec tools/nil-kill collect --cmd "bundle exec rspec" --cmd "./clear test transpile-tests"
          bundle exec tools/nil-kill collect --glob "lib/**/*.rb" --template "ruby {file}"
          bundle exec tools/nil-kill collect --append-runtime --commands more-runtime-commands.txt
          bundle exec tools/nil-kill collect --instrument-source -- <command...>
          bundle exec tools/nil-kill collect --no-instrument-source -- <command...>
          bundle exec tools/nil-kill infer [--no-sorbet]
          bundle exec tools/nil-kill static [--root DIR] [--language ruby|python|typescript|rust|zig] [--vcs git] [--output static.json] [targets...]
          bundle exec tools/nil-kill collect-runtime --language python [--target src] [--output traces/] -- <python test command...>
          bundle exec tools/nil-kill collect-python [--root DIR] [--target src] [--output traces/] -- <python test command...>
          bundle exec tools/nil-kill normalize [--root DIR] --static static.json [--traces traces/] [--output evidence.json]
          bundle exec tools/nil-kill analyze [--evidence evidence.json] [--output evidence.json]
          bundle exec tools/nil-kill trace-spec
          bundle exec tools/nil-kill focus-hash-record STRUCT [--targets path[:path...]]
          bundle exec tools/nil-kill report [--evidence evidence.json] [--format markdown|sarif|json] [--json report.sarif] [--sarif report.sarif] [--with-links] [--output-path PATH] [--hygiene]
          bundle exec tools/nil-kill struct-rbi [--complete] [--output sorbet/rbi/nil-kill-structs.rbi]
          bundle exec tools/nil-kill doctor

          # Source rewrites live in auto-type:
          bundle exec auto-type apply [--dry-run]
          bundle exec auto-type review [--kind replace_nil_with_default]
          bundle exec auto-type loop [--defaults] [--try-levenshtein] [--hash-records] [--signature-backflow] [--return-backflow] [--narrow-generic] [--narrow-tlet] -- <verify command...>
          bundle exec auto-type guarded-autocorrect [--max-iterations N]

        Config:
          NIL_KILL_TARGETS=src[:other_dir]   target Ruby source roots
          NIL_KILL_EXCLUDE_TARGETS=src/tools  exclude Ruby source roots
          NIL_KILL_MIN_CALLS=20              runtime confidence threshold
          NIL_KILL_UNION_POLICY=untyped|any  default: untyped
          NIL_KILL_LEVENSHTEIN_DISTANCE=2    max param-name/class-name distance for speculative narrowing
          NIL_KILL_LEVENSHTEIN_LIMIT=50      max speculative actions per loop iteration; 0 = unlimited
          NIL_KILL_HASH_RECORD_LIMIT=1        max review hash-record promotions per loop iteration; 0 = unlimited
          NIL_KILL_SIGNATURE_BACKFLOW_LIMIT=5 max review static param backflow fixes per loop iteration; 0 = unlimited
          NIL_KILL_RETURN_BACKFLOW_LIMIT=5    max review return-backflow fixes per loop iteration; 0 = unlimited
          NIL_KILL_NARROW_GENERIC_LIMIT=0     max review narrow-generic fixes per loop iteration; 0 = unlimited
          NIL_KILL_NARROW_TLET_LIMIT=0        max review narrow-tlet fixes per loop iteration; 0 = unlimited
          NIL_KILL_PRESSURE_SORT=priority|slots|hotness
          NIL_KILL_ELEMENT_SAMPLE=20          container elements sampled by runtime tracing
          NIL_KILL_TRACE_PLAN=0               disable trace-plan pruning during collect
          NIL_KILL_TRACE_METHODS=0            disable TracePoint method collection
          NIL_KILL_SLOT_TYPE_OVERRIDES=file   opt-in JSON field/ivar type override rules
      TEXT
    end
  end
end
