# typed: false
# frozen_string_literal: true

module NilKill
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      # A collect from before source rewriting was removed may have crashed and
      # left src/ wrapped. Restoring is cheap and unconditional, and a tree that
      # was never wrapped is untouched.
      NilKill.ensure_src_restored!
      command = @argv.shift
      case command
      when "collect" then collect
      when "infer" then guard_fresh_runtime!; Infer.new(@argv).run
      when "static" then Commands::StaticCommand.new(@argv).run
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
      runtime = Runtime::JsonIO.matching(RUNTIME_DIR, "*.jsonl")
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

    # Stage timing, off unless asked for. A collect is a pipeline and the only
    # useful question about it is which stage owns the time.
    def stage(name)
      return yield unless ENV["NIL_KILL_STAGE_TIMING"] == "1"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      warn format("stage %-26s %6.2fs", name, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      result
    end

    # A collect runs no Ruby but the program it is tracing. Everything it
    # decides -- the plan, the shards, what an increment must rerun, the
    # transaction around the canonical artifacts -- is FactMine's, so this is
    # the whole of it: hand the argument list over.
    def collect
      binary = NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY
      unless File.executable?(binary)
        abort "nil-kill: #{binary} is not built; run 'cargo build --release' in gems/fact-mine"
      end

      exec(binary, "nil-kill-collect", "--root", ROOT, *@argv)
    end

    def help
      puts <<~TEXT
        Usage:
          bundle exec tools/nil-kill collect -- <command...>
          bundle exec tools/nil-kill collect --fast -- <command...>
          bundle exec tools/nil-kill collect --commands runtime-commands.txt
          bundle exec tools/nil-kill collect --cmd "bundle exec rspec" --cmd "./clear test transpile-tests"
          bundle exec tools/nil-kill collect --glob "lib/**/*.rb" --template "ruby {file}"
          bundle exec tools/nil-kill collect --append-runtime --commands more-runtime-commands.txt
          bundle exec tools/nil-kill infer [--no-sorbet]
          bundle exec tools/nil-kill static [--root DIR] [--language ruby|python|typescript|rust|zig] [--vcs git] [--source-role production|test|benchmark|example|generated|vendored|vcs_metadata|all] [--output static.json] [targets...]
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
          NIL_KILL_RUNTIME_SCIP_NATIVE=0      Ruby-call-only SCIP evidence for rapid feedback
          NIL_KILL_COLLECT_COVERAGE=0         disable Ruby line coverage for SCIP-only rapid feedback
          NIL_KILL_SLOT_TYPE_OVERRIDES=file   opt-in JSON field/ivar type override rules
      TEXT
    end
  end
end
