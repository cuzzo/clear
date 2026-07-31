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

    def collect
      fast = @argv.delete("--fast")
      append = @argv.delete("--append-runtime")
      abort "nil-kill: --fast and --append-runtime cannot be combined" if fast && append
      # Source rewriting is gone: the collector observes the running program
      # directly. The flags are still accepted so an existing invocation does
      # not break, but neither of them changes what happens.
      @argv.delete("--no-instrument-source")
      @argv.delete("--instrument-source")
      commands = collect_commands
      if commands.empty? && !fast
        abort "usage: bundle exec tools/nil-kill collect [--fast] [--commands FILE] [--continue-on-error] -- <command...>"
      end
      trace_plan_enabled = ENV["NIL_KILL_TRACE_PLAN"] != "0"
      stage("trace-plan") { TracePlan.write if trace_plan_enabled }
      trace_plan = File.file?(TRACE_PLAN_PATH) ? JSON.parse(File.read(TRACE_PLAN_PATH)) : {}
      trace_plan_digest = trace_plan.dig("runtime_evidence", "plan_digest").to_s
      target_files = NilKill.target_files
      inventory = stage("function-inventory") do
        Runtime::FunctionInventory.build(
          root: ROOT,
          files: target_files,
          trace_plan: trace_plan
        )
      end
      snapshot = fast && begin
        Runtime::Snapshot.load(root: ROOT, runtime_dir: RUNTIME_DIR)
      rescue ArgumentError => error
        abort "nil-kill: #{error.message}"
      end
      workload =
        if fast && commands.empty?
          Runtime::WorkloadPlan.from_h(root: ROOT, value: snapshot.manifest.fetch("workload"))
        else
          Runtime::WorkloadPlan.build(
            root: ROOT,
            targets: target_files,
            commands: commands
          )
        end
      selection =
        if fast
          snapshot.select_increment(
            files: target_files,
            function_inventory: inventory.to_h,
            workload_plan: workload,
            trace_plan_digest: trace_plan_digest
          )
        else
          {
            "selected_shards" => workload.shard_ids,
            "deleted_shards" => [],
            "changed_functions" => inventory.functions.keys,
            "added_functions" => [],
            "deleted_functions" => [],
            "changed_tests" => workload.tests.keys,
            "deleted_tests" => [],
            "uncertain_closure" => false,
            "rebuild" => true,
            "current_hashes" => Runtime::Snapshot.new(root: ROOT, runtime_dir: RUNTIME_DIR)
              .source_hashes(target_files),
            "environment" => {},
            "functions" => inventory.to_h,
            "workload" => workload.to_h,
            "trace_plan_digest" => trace_plan_digest,
          }
        end
      if fast && !selection.fetch("rebuild")
        puts "nil-kill: incremental snapshot is current; no semantic source/test changes, workload skipped"
        return
      end
      selected = workload.shards.select do |shard|
        selection.fetch("selected_shards").include?(shard.fetch("id"))
      end
      FileUtils.rm_rf(RUNTIME_DIR) unless append || fast
      FileUtils.mkdir_p(RUNTIME_DIR)
      generation = snapshot ? snapshot.manifest.fetch("generation").to_i + 1 : 0
      working_runtime_dir = File.join(
        RUNTIME_DIR,
        fast ? "increments" : "runs",
        format("%06d", generation)
      )
      FileUtils.rm_rf(working_runtime_dir)
      FileUtils.mkdir_p(working_runtime_dir)
      require "etc"
      jobs = ENV["NK_JOBS"] || ENV["NIL_KILL_JOBS"] || Etc.nprocessors.to_s rescue "4"
      shard_jobs = ENV.fetch(
        "NIL_KILL_SHARD_JOBS",
        [[jobs.to_i, 1].max, [selected.size, 1].max].min.to_s
      ).to_i.clamp(1, [selected.size, 1].max)
      default_inner_jobs = [[jobs.to_i, 1].max / shard_jobs, 1].max.to_s
      # The collector is the extension itself. Requiring the object installs
      # it, so the traced program loads no nil-kill Ruby at all.
      tracer = NilKill::COLLECTOR_EXTENSION
      rubyopt = (ENV["RUBYOPT"].to_s.split + ["-r#{tracer}"]).join(" ")
      source_roles_path = File.join(working_runtime_dir, "source-roles.json")
      File.write(
        source_roles_path,
        JSON.generate(
          "nonproduction" => (
            workload.tests.keys + workload.support_files.keys
          ).uniq.sort
        )
      )
      base_env = ENV.to_h.merge(
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_RUNTIME_SCIP" => "1",
        "NIL_KILL_SOURCE_ROLES" => source_roles_path,
        # Every path the collector reports, and every source-role lookup it
        # makes, is relative to this root. It used to be rederived from the
        # tracer file's own location, which only worked while a Ruby tracer
        # was being loaded to do the rederiving.
        "NIL_KILL_ROOT" => ROOT,
        "NIL_KILL_PROJECT_NAME" => ENV["NIL_KILL_PROJECT_NAME"] || File.basename(ROOT),
        "NIL_KILL_PROJECT_VERSION" => ENV["NIL_KILL_PROJECT_VERSION"] ||
          git_capture("rev-parse", "HEAD")&.strip || "workspace",
        "RUBYOPT" => rubyopt,
        "WORKERS" => ENV["WORKERS"] || default_inner_jobs,
        "NK_JOBS" => ENV["NK_JOBS"] || default_inner_jobs,
        "NIL_KILL_JOBS" => ENV["NIL_KILL_JOBS"] || default_inner_jobs
      )
      continue = @argv.delete("--continue-on-error")
      dependency_updates = {}
      callsite_updates = {}
      staged_evidence = {}
      shard_run_ids = {}
      failed_shards = []
      begin
        runs = selected.each_with_index.map do |shard, i|
          shard_dir = File.join(working_runtime_dir, shard.fetch("id"))
          FileUtils.mkdir_p(shard_dir)
          line_map = File.join(working_runtime_dir, ".nk-linemap.json")
          FileUtils.cp(line_map, File.join(shard_dir, ".nk-linemap.json")) if File.file?(line_map)
          run_id = "#{generation}:#{shard.fetch("id")}:#{SecureRandom.uuid}"
          shard_run_ids[shard.fetch("id")] = run_id
          env = base_env.merge(
            "NIL_KILL_RUNTIME_DIR" => shard_dir,
            "NIL_KILL_RUN_ID" => run_id,
            "NIL_KILL_SHARD_ID" => shard.fetch("id")
          )
          cmd = shard.fetch("command")
          [i, shard.fetch("id"), env, cmd]
        end
        queue = Queue.new
        runs.each { |run| queue << run }
        result_lock = Mutex.new
        stop = false
        Array.new(shard_jobs) do
          Thread.new do
            loop do
              break if result_lock.synchronize { stop }
              run = queue.pop(true)
              i, shard_id, env, cmd = run
              result_lock.synchronize do
                puts "[#{i + 1}/#{selected.size}] NIL_KILL_TRACE=1 " \
                  "RUBYOPT=#{rubyopt.shellescape} #{cmd.shelljoin}"
              end
              next if system(env, *cmd)

              result_lock.synchronize do
                failed_shards << shard_id
                stop = true unless continue
              end
            rescue ThreadError
              break
            end
          end
        end.each(&:join)
      end
      if failed_shards.any?
        snapshot&.mark_stale!(
          reason: "required trace shard(s) failed: #{failed_shards.join(", ")}",
          selection: selection
        )
        abort "nil-kill: required trace shard(s) failed; canonical evidence was not replaced: " \
          "#{failed_shards.join(", ")}"
      end
      # A traced program writes what it saw. What those observations *mean* --
      # what counts as a shape, when two collections are the same shape, which
      # names are test-only -- is the same arithmetic in every language, so it
      # runs once here rather than being rewritten for each language's shim.
      stage("derive-domains") do
        Runtime::DomainDeriver.run(
          documents: selected.flat_map do |shard|
            Dir.glob(File.join(working_runtime_dir, shard.fetch("id"),
                               Runtime::CollectorExport::RAW_GLOB))
          end,
          source_roles: source_roles_path,
          root: ROOT
        )
      end
      # The traced programs wrote what the collector saw; shaping it into rows
      # needs no VM, so it happens here.
      stage("collector-export") do
        selected.each do |shard|
          Runtime::CollectorExport.write(
            runtime_dir: File.join(working_runtime_dir, shard.fetch("id")),
            plan: trace_plan, root: ROOT
          )
        end
      end
      staged_traces = {}
      stage("shard-bookkeeping") { selected.each do |shard|
        shard_id = shard.fetch("id")
        shard_dir = File.join(working_runtime_dir, shard_id)
        dependency_updates[shard_id] = dependencies_for_shard(shard_dir, inventory)
        callsite_updates[shard_id] = callsites_for_shard(shard_dir)
        assert_incremental_shard_sound!(shard_dir, inventory, dependency_updates[shard_id])
        compress_runtime_evidence!(shard_dir)
        staged_traces[shard_id] = File.join(shard_dir, Runtime::TraceArtifact::DEFAULT_NAME)
        staged_evidence[shard_id] =
          File.join(shard_dir, Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      end }
      # A traced program writes what it saw and nothing else. Turning those
      # observations into the trace document needs no VM, so it happens here --
      # which is what lets a traced process load the collector and no other
      # nil-kill code at all. Shards are independent, so they build together.
      stage("trace-documents") do
        trace_plan_document = Runtime::EvidenceProtocol.plan
        queue = Queue.new
        selected.each { |shard| queue << shard.fetch("id") }
        errors = Queue.new
        Array.new(shard_jobs) do
          Thread.new do
            loop do
              shard_id = queue.pop(true)
              Runtime::TraceArtifact.write(
                root: ROOT,
                runtime_dir: File.join(working_runtime_dir, shard_id),
                plan: trace_plan_document,
                languages: ["ruby"],
                run_ids: [shard_run_ids[shard_id]].compact
              )
            rescue ThreadError
              break
            rescue StandardError => error
              errors << "#{shard_id}: #{error.message}"
              break
            end
          end
        end.each(&:join)
        abort "nil-kill: could not build trace documents: #{errors.size} shard(s)" \
          " (#{errors.pop})" unless errors.empty?
      end
      # FactMine already holds every shard's evidence in memory at the end of the
      # join, so it can merge there instead of writing each document out for
      # this process to read them all back. Only valid when the canonical set is
      # exactly this run's shards; an incremental collect mixes in stored ones
      # and still merges below.
      merged_candidate = File.join(working_runtime_dir, "merged-evidence.v1.json.gz")
      stage("join (batched)") do
        Runtime::TraceArtifact.join_all(
          root: ROOT, traces: staged_traces, merged: merged_candidate
        )
      end
      shard_store = File.join(RUNTIME_DIR, "shard-evidence")
      FileUtils.mkdir_p(shard_store)
      current_shards = workload.shard_ids
      destinations = current_shards.to_h do |shard_id|
        [shard_id, File.join(shard_store, "#{shard_id}.json.gz")]
      end
      effective = current_shards.filter_map do |shard_id|
        staged_evidence[shard_id] || destinations[shard_id] if
          staged_evidence[shard_id] || File.file?(destinations[shard_id])
      end
      dependencies = fast ? Marshal.load(Marshal.dump(snapshot.manifest.fetch("dependencies", {}))) : {}
      callsites = fast ? Marshal.load(Marshal.dump(snapshot.manifest.fetch("callsites", {}))) : {}
      selection.fetch("deleted_shards").each { |shard_id| dependencies.delete(shard_id) }
      selection.fetch("deleted_shards").each { |shard_id| callsites.delete(shard_id) }
      dependency_updates.each { |shard_id, keys| dependencies[shard_id] = keys }
      callsite_updates.each { |shard_id, sites| callsites[shard_id] = sites }
      transaction_paths = (
        destinations.values +
        selection.fetch("deleted_shards").map { |id| File.join(shard_store, "#{id}.json.gz") }
      ).uniq
      emitted = with_canonical_snapshot_transaction(extra_paths: transaction_paths) do
        canonical_target = File.join(RUNTIME_DIR, Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
        canonical_evidence = stage("evidence-merge") do
          if effective.sort == staged_evidence.values.sort && File.file?(merged_candidate)
            FileUtils.mkdir_p(File.dirname(canonical_target))
            FileUtils.cp(merged_candidate, canonical_target)
            canonical_target
          else
            Runtime::EvidenceMerger.write(
              effective, canonical_target, plan: Runtime::EvidenceProtocol.plan
            )
          end
        end
        result = stage("scip-index") { Runtime::ScipEmitter.emit(
          root: ROOT,
          runtime_dir: working_runtime_dir,
          output: File.join(RUNTIME_DIR, "runtime.scip.json"),
          attestation: File.join(RUNTIME_DIR, "runtime-attestation.json.gz"),
          files: target_files,
          value_evidence_path: canonical_evidence,
          environment: selection.fetch("environment").merge(
            "runtime_scip.snapshot_mode" => fast ? "fast" : "full",
            "runtime_scip.potentially_stale" => selection.fetch("uncertain_closure").to_s
          )
        ) }
        staged_evidence.each do |shard_id, path|
          Runtime::JsonIO.write(destinations.fetch(shard_id), Runtime::JsonIO.read(path))
        end
        selection.fetch("deleted_shards").each do |shard_id|
          path = File.join(shard_store, "#{shard_id}.json.gz")
          File.delete(path) if File.file?(path)
        end
        if fast
          snapshot.write_incremental!(
            selection: selection,
            evidence_path: canonical_evidence,
            dependencies: dependencies,
            callsites: callsites
          )
        else
          Runtime::Snapshot.new(root: ROOT, runtime_dir: RUNTIME_DIR).write_full!(
            files: target_files,
            evidence_path: canonical_evidence,
            workload_digest: workload.command_digest,
            function_inventory: inventory.to_h,
            workload: workload.to_h,
            dependencies: dependencies,
            callsites: callsites,
            trace_plan_digest: trace_plan_digest
          )
        end
        result
      end
      write_collect_meta!
      puts "wrote runtime SCIP index to #{emitted.fetch("index")}"
      if fast
        puts "updated compressed canonical snapshot generation #{generation}; " \
          "#{selection.fetch("changed_functions").length} changed functions, " \
          "#{selection.fetch("changed_tests").length} changed tests, " \
          "#{selected.length} traced shards"
      end
    end

    # A traced collect that produced ZERO Ruby Coverage means Coverage
    # failed to start in the workload; the dead-vs-missed split (unseen
    # vs collect_ran_untraced) then cannot be computed and would silently
    # degrade to "never_run". Make that a hard, loud failure instead.
    def assert_collect_coverage_produced!(runtime_dir = RUNTIME_DIR)
      cov = Dir.glob(File.join(runtime_dir, "coverage-*.jsonl"))
      meth = Dir.glob(File.join(runtime_dir, "methods-*.jsonl"))
      cov_bytes = cov.sum { |f| File.size(f) }
      meth_bytes = meth.sum { |f| File.size(f) }
      if cov_bytes.zero? || meth_bytes.zero?
        abort "nil-kill: the traced collect produced NO usable evidence " \
          "(coverage=#{cov_bytes}B, method observations=#{meth_bytes}B in " \
          "#{NilKill.rel(runtime_dir)}). Empty .jsonl files exist but hold nothing -- " \
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

    def compress_runtime_evidence!(runtime_dir)
      return if ENV["NIL_KILL_COMPRESS_EVIDENCE"] == "0"

      Dir.glob(File.join(runtime_dir, "*.jsonl")).sort.each do |path|
        Runtime::JsonIO.gzip_file(path)
      end
    end

    def dependencies_for_shard(runtime_dir, inventory)
      keys = Set.new
      entry_files = Runtime::JsonIO.matching(runtime_dir, "function-entries-*.jsonl")
      entry_files.each do |path|
        Runtime::JsonIO.foreach(path) do |line|
          row = JSON.parse(line)
          key = inventory.key_for_entry(
            path: row.fetch("path"),
            owner: row.fetch("owner"),
            name: row.fetch("name"),
            kind: row.fetch("kind"),
            line: row["line"]
          )
          keys << key if key
        rescue JSON::ParserError, KeyError
          next
        end
      end
      return keys.to_a.sort unless entry_files.empty?

      Runtime::JsonIO.matching(runtime_dir, "coverage-*.jsonl").each do |path|
        Runtime::JsonIO.foreach(path) do |line|
          row = JSON.parse(line)
          keys.merge(inventory.keys_for_coverage(row.fetch("path"), row.fetch("lines", [])))
        rescue JSON::ParserError, KeyError
          next
        end
      end
      keys.to_a.sort
    end

    def callsites_for_shard(runtime_dir)
      sites = Set.new
      files = Runtime::JsonIO.matching(runtime_dir, "executed-callsites-*.jsonl")
      files = Runtime::JsonIO.matching(runtime_dir, "runtime-calls-*.jsonl") if files.empty?
      files.each do |path|
        Runtime::JsonIO.foreach(path) do |line|
          row = JSON.parse(line)
          callsite = row["callsite"] || row
          sites << [
            NilKill.rel(callsite.fetch("path")),
            callsite.fetch("line").to_i,
            callsite["selector"].to_s,
          ]
        rescue JSON::ParserError, KeyError
          next
        end
      end
      sites.to_a.sort
    end

    # Empty runtime values are valid when the shard did not reach a function
    # for which the trace plan requested values. They are an error only when
    # demanded, covered functions produced no method observations at all.
    def assert_incremental_shard_sound!(runtime_dir, inventory, covered_function_keys)
      demanded = Array(covered_function_keys).any? do |key|
        inventory.functions.dig(key, "runtime_demand")
      end
      return unless demanded

      methods = Runtime::JsonIO.matching(runtime_dir, "methods-*.jsonl")
      return if methods.sum { |path| File.size(path) }.positive?

      abort "nil-kill: shard #{File.basename(runtime_dir)} covered runtime-demanded " \
        "functions but produced no method observations; refusing a partial incremental snapshot"
    end

    # A failed FactMine regeneration must not leave the manifest/evidence at a
    # newer generation than the consumer SCIP index. Keep the four canonical
    # files as one recoverable transaction; delta evidence remains available
    # for diagnosis and a retry.
    def with_canonical_snapshot_transaction(extra_paths: [])
      paths = [
        File.join(RUNTIME_DIR, Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT),
        File.join(RUNTIME_DIR, Runtime::Snapshot::MANIFEST),
        File.join(RUNTIME_DIR, "runtime.scip.json"),
        File.join(RUNTIME_DIR, "runtime-attestation.json.gz"),
        *Array(extra_paths),
      ].uniq
      before = paths.to_h { |path| [path, File.file?(path) ? Runtime::JsonIO.read(path) : nil] }
      yield
    rescue Exception # rubocop:disable Lint/RescueException -- rollback before preserving exits/signals
      before.each do |path, contents|
        if contents
          Runtime::JsonIO.write(path, contents)
        elsif File.file?(path)
          File.delete(path)
        end
      end
      raise
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
          bundle exec tools/nil-kill collect --fast -- <command...>
          bundle exec tools/nil-kill collect --commands runtime-commands.txt
          bundle exec tools/nil-kill collect --cmd "bundle exec rspec" --cmd "./clear test transpile-tests"
          bundle exec tools/nil-kill collect --glob "lib/**/*.rb" --template "ruby {file}"
          bundle exec tools/nil-kill collect --append-runtime --commands more-runtime-commands.txt
          bundle exec tools/nil-kill infer [--no-sorbet]
          bundle exec tools/nil-kill static [--root DIR] [--language ruby|python|typescript|rust|zig] [--vcs git] [--source-role production|test|benchmark|example|generated|vendored|vcs_metadata|all] [--output static.json] [targets...]
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
          NIL_KILL_RUNTIME_SCIP_NATIVE=0      Ruby-call-only SCIP evidence for rapid feedback
          NIL_KILL_COLLECT_COVERAGE=0         disable Ruby line coverage for SCIP-only rapid feedback
          NIL_KILL_SLOT_TYPE_OVERRIDES=file   opt-in JSON field/ivar type override rules
      TEXT
    end
  end
end
