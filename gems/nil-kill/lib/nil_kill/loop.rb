# typed: false
# frozen_string_literal: true

module NilKill
  class Loop
    SKIP_FILE = File.join(ROOT, "tools", "nil-kill-skip.json")
    Z3_SOLVER_PATH = File.expand_path("z3_solver.rb", __dir__)

    def initialize(argv)
      if argv.delete("--defaults")
        warn "nil-kill: --defaults is review-only; nil default rewrites are not auto-applied"
      end
      @try_levenshtein = !!argv.delete("--try-levenshtein")
      @try_hash_records = !!argv.delete("--hash-records")
      @try_struct_rbi = !!argv.delete("--struct-rbi")
      @try_signature_backflow = !!argv.delete("--signature-backflow")
      @try_return_backflow = !!argv.delete("--return-backflow")
      @try_narrow_generic = !!argv.delete("--narrow-generic")
      @try_narrow_tlet = !!argv.delete("--narrow-tlet")
      @verify_spec_subset = !!argv.delete("--verify-spec-subset")
      @levenshtein_distance = ENV.fetch("NIL_KILL_LEVENSHTEIN_DISTANCE", "2").to_i
      @levenshtein_limit = ENV.fetch("NIL_KILL_LEVENSHTEIN_LIMIT", "50").to_i
      @hash_record_limit = ENV.fetch("NIL_KILL_HASH_RECORD_LIMIT", "1").to_i
      @signature_backflow_limit = ENV.fetch("NIL_KILL_SIGNATURE_BACKFLOW_LIMIT", "5").to_i
      @return_backflow_limit = ENV.fetch("NIL_KILL_RETURN_BACKFLOW_LIMIT", "5").to_i
      @narrow_generic_limit = ENV.fetch("NIL_KILL_NARROW_GENERIC_LIMIT", "0").to_i
      @narrow_tlet_limit = ENV.fetch("NIL_KILL_NARROW_TLET_LIMIT", "0").to_i
      sep = argv.index("--")
      @verify_cmd = sep ? argv[(sep + 1)..] : []
      @max_iters = ENV.fetch("NIL_KILL_MAX_ITERS", "10").to_i
      @skipped = Set.new
      @permanent_skip = load_permanent_skip
      @z3_solver = nil
      load_z3_solver
    end

    def load_z3_solver
      require Z3_SOLVER_PATH
    rescue LoadError, SyntaxError => e
      warn "nil-kill: Z3 solver not loaded (#{e.message}); running without pre-filter"
    end

    def load_permanent_skip
      return [] unless File.file?(SKIP_FILE)
      JSON.parse(File.read(SKIP_FILE))
    rescue JSON::ParserError
      []
    end

    def permanently_skipped?(action)
      @permanent_skip.any? do |entry|
        action["kind"] == entry["kind"] &&
          action["path"] == entry["path"] &&
          (entry["code"].nil? || action.dig("data", "code")&.include?(entry["code"]))
      end
    end

    def run
      abort "usage: bundle exec tools/nil-kill loop -- <verify command...>" if @verify_cmd.empty? && !@verify_spec_subset
      iter = 0
      loop do
        iter += 1
        puts "nil-kill loop iteration #{iter}"
        Infer.new([]).run
        evidence = Store.read
        @z3_solver = init_z3_solver(evidence)
        emit_z3_inferred_actions(@z3_solver, evidence) if @z3_solver
        high_actions = evidence["actions"].select do |action|
          next false unless action["confidence"] == HIGH
          next false if @skipped.include?(fingerprint(action))
          next false if permanently_skipped?(action)
          next false if z3_preflight_skip?(action)
          # A4: block nil-check removal actions whose receiver might actually be nil
          if @z3_solver && (action["kind"] == "remove_dead_safe_nav" || action["kind"] == "replace_dead_nil_check")
            next false unless @z3_solver.provably_dead_safe_nav?(action)
          end
          true
        end
        if @try_levenshtein
          speculative = levenshtein_actions(evidence).reject do |action|
            @skipped.include?(fingerprint(action)) || permanently_skipped?(action) || z3_preflight_skip?(action)
          end
          seen = high_actions.map { |action| fingerprint(action) }.to_set
          speculative.reject! { |action| seen.include?(fingerprint(action)) }
          puts "Levenshtein speculative actions: #{speculative.size}"
          high_actions.concat(speculative)
        end
        if @try_hash_records
          review_hash_records = hash_record_review_actions(evidence, high_actions)
          puts "hash-record review actions: #{review_hash_records.size}"
          high_actions.concat(review_hash_records)
        end
        if @try_struct_rbi
          review_struct_rbi = struct_rbi_review_actions(evidence, high_actions)
          puts "struct-rbi review actions: #{review_struct_rbi.size}"
          high_actions.concat(review_struct_rbi)
        end
        if @try_signature_backflow
          review_signature_backflow = signature_backflow_review_actions(evidence, high_actions)
          puts "signature-backflow review actions: #{review_signature_backflow.size}"
          high_actions.concat(review_signature_backflow)
        end
        if @try_return_backflow
          review_return_backflow = return_backflow_review_actions(evidence, high_actions)
          puts "return-backflow review actions: #{review_return_backflow.size}"
          high_actions.concat(review_return_backflow)
        end
        if @try_narrow_generic
          review_narrow_generic = narrow_generic_review_actions(evidence, high_actions)
          puts "narrow-generic review actions: #{review_narrow_generic.size}"
          high_actions.concat(review_narrow_generic)
        end
        if @try_narrow_tlet
          review_narrow_tlet = narrow_tlet_review_actions(evidence, high_actions)
          puts "narrow-tlet review actions: #{review_narrow_tlet.size}"
          high_actions.concat(review_narrow_tlet)
        end
        high = high_actions.size
        puts "high-confidence actions: #{high}"
        break if high.zero?

        applied = apply_verified(high_actions)
        puts "verified actions applied: #{applied}; skipped this run: #{@skipped.size}"
        break if applied.zero?
        break if iter >= @max_iters
      end
    end

    def init_z3_solver(evidence)
      return nil unless defined?(NilKill::Z3Solver)
      Z3Solver.new(evidence, NilKill.target_files)
    rescue StandardError => e
      warn "nil-kill: Z3 solver init failed: #{e.message}"
      nil
    end

    def z3_preflight_skip?(action)
      return false unless @z3_solver
      reason = @z3_solver.preflight_rejection(action)
      return false unless reason
      @skipped << fingerprint(action)
      warn "Z3 preflight skipped #{action["path"]}:#{action["line"]} #{action["kind"]}: #{reason}"
      true
    end

    # Mirrors hash_record_review_actions: feed add_struct_field_sig
    # actions into the same apply_verified bisection. The loop lands the
    # maximal srb-tc-clean subset and records the rest in @skipped --
    # those skipped slots ARE the surfaced "blocked struct fields"
    # (logged here, counted in the report's action sections), replacing
    # struct-rbi --validate's all-or-nothing revert.
    def struct_rbi_review_actions(evidence, existing_actions = [])
      seen = existing_actions.map { |action| fingerprint(action) }.to_set
      Array(evidence["actions"]).select do |action|
        next false unless action["confidence"] == REVIEW
        next false unless action["kind"] == "add_struct_field_sig"
        next false if seen.include?(fingerprint(action))
        next false if @skipped.include?(fingerprint(action))
        next false if permanently_skipped?(action)
        true
      end
    end

    def hash_record_review_actions(evidence, existing_actions = [])
      seen = existing_actions.map { |action| fingerprint(action) }.to_set
      actions = Array(evidence["actions"]).select do |action|
        next false unless action["confidence"] == REVIEW
        next false unless %w[promote_hash_record_to_struct promote_hash_record_cluster_to_struct].include?(action["kind"])
        next false if seen.include?(fingerprint(action))
        next false if @skipped.include?(fingerprint(action))
        next false if permanently_skipped?(action)
        next false if z3_preflight_skip?(action)
        blockers = Array(action.dig("data", "blockers"))
        unless blockers.empty?
          warn "hash-record promotion blocked #{action["path"]}:#{action["line"]}: #{blockers.join("; ")}"
          next false
        end
        true
      end
      actions.sort_by! { |action| [-hash_record_action_pressure(action), action["path"], action["line"].to_i] }
      @hash_record_limit.positive? ? actions.first(@hash_record_limit) : actions
    end

    def hash_record_action_pressure(action)
      action.dig("data", "pressure", "total").to_i
    end

    def signature_backflow_review_actions(evidence, existing_actions = [])
      seen = existing_actions.map { |action| fingerprint(action) }.to_set
      actions = Array(evidence["actions"]).select do |action|
        next false unless action["confidence"] == REVIEW
        next false unless action["kind"] == "fix_sig_param"
        next false unless action.dig("data", "source") == "static_param_backflow"
        next false if seen.include?(fingerprint(action))
        next false if @skipped.include?(fingerprint(action))
        next false if permanently_skipped?(action)
        next false if z3_preflight_skip?(action)
        true
      end
      actions.sort_by! { |action| [-signature_backflow_action_pressure(action), action["path"], action["line"].to_i, action.dig("data", "name").to_s] }
      @signature_backflow_limit.positive? ? actions.first(@signature_backflow_limit) : actions
    end

    def signature_backflow_action_pressure(action)
      action.dig("data", "callsite_count").to_i
    end

    RETURN_BACKFLOW_SOURCES = %w[forwarded_return_chain static_return_origin].freeze

    def return_backflow_review_actions(evidence, existing_actions = [])
      seen = existing_actions.map { |action| fingerprint(action) }.to_set
      actions = Array(evidence["actions"]).select do |action|
        next false unless action["confidence"] == REVIEW
        next false unless action["kind"] == "fix_sig_return"
        next false unless RETURN_BACKFLOW_SOURCES.include?(action.dig("data", "source").to_s)
        next false if seen.include?(fingerprint(action))
        next false if @skipped.include?(fingerprint(action))
        next false if permanently_skipped?(action)
        next false if z3_preflight_skip?(action)
        true
      end
      actions.sort_by! { |action| [-return_backflow_action_pressure(action), action["path"], action["line"].to_i, action.dig("data", "type").to_s] }
      @return_backflow_limit.positive? ? actions.first(@return_backflow_limit) : actions
    end

    def return_backflow_action_pressure(action)
      case action.dig("data", "source").to_s
      when "forwarded_return_chain" then Array(action.dig("data", "chain")).size
      when "static_return_origin" then Array(action.dig("data", "blockers")).size + 1
      else 0
      end
    end

    def narrow_tlet_review_actions(evidence, existing_actions = [])
      seen = existing_actions.map { |action| fingerprint(action) }.to_set
      actions = Array(evidence["actions"]).select do |action|
        next false unless action["confidence"] == REVIEW
        next false unless action["kind"] == "narrow_tlet"
        next false if seen.include?(fingerprint(action))
        next false if @skipped.include?(fingerprint(action))
        next false if permanently_skipped?(action)
        next false if z3_preflight_skip?(action)
        true
      end
      # Sort by file/line for deterministic bisection batches across loop
      # iterations. narrow_tlet actions don't carry a natural pressure metric.
      actions.sort_by! { |action| [action["path"].to_s, action["line"].to_i, action.dig("data", "type").to_s] }
      @narrow_tlet_limit.positive? ? actions.first(@narrow_tlet_limit) : actions
    end

    NARROW_GENERIC_KINDS = %w[narrow_generic_param narrow_generic_return].freeze

    def narrow_generic_review_actions(evidence, existing_actions = [])
      seen = existing_actions.map { |action| fingerprint(action) }.to_set
      actions = Array(evidence["actions"]).select do |action|
        next false unless action["confidence"] == REVIEW
        next false unless NARROW_GENERIC_KINDS.include?(action["kind"])
        next false unless action.dig("data", "source") == "collection_runtime"
        next false if seen.include?(fingerprint(action))
        next false if @skipped.include?(fingerprint(action))
        next false if permanently_skipped?(action)
        next false if z3_preflight_skip?(action)
        true
      end
      # Stable order: parameterised collection narrowings have no natural
      # pressure metric in their data, so sort by file/line/name for
      # deterministic bisection batches across loop iterations.
      actions.sort_by! { |action| [action["path"].to_s, action["line"].to_i, action.dig("data", "name").to_s, action.dig("data", "type").to_s] }
      @narrow_generic_limit.positive? ? actions.first(@narrow_generic_limit) : actions
    end

    # A3: run static inference for unobserved params, write to z3-inferred.json,
    # and print a one-line summary. Actions are REVIEW confidence -- not auto-applied.
    def emit_z3_inferred_actions(solver, evidence)
      actions = solver.infer_unobserved_params(evidence)
      out = File.join(TMP_DIR, "z3-inferred.json")
      File.write(out, JSON.pretty_generate(actions))
      puts "Z3 A3: #{actions.size} static param inference(s) written to #{NilKill.rel(out)}"
    rescue StandardError => e
      warn "nil-kill: Z3 A3 inference failed: #{e.message}"
    end

    def levenshtein_actions(evidence)
      rec_by_source = evidence["methods"].each_with_object({}) do |rec, lookup|
        src = rec["source"]
        lookup[[src["path"], src["line"]]] = rec if src
      end
      actions = []
      Array(evidence.dig("facts", "existing_sigs")).each do |src|
        sig = src["sig"].to_s
        next unless sig.include?("T.untyped")
        rec = rec_by_source[[src["path"], src["line"]]]
        next unless rec
        classes_by_name = params_for_levenshtein(rec)
        Array(src["params"]).each do |param|
          name = param["name"].to_s
          next unless sig.match?(/\b#{Regexp.escape(name)}:\s*T\.untyped\b/)
          observed = Array(classes_by_name[name]).compact.uniq
          concrete = observed.reject { |klass| ignored_levenshtein_class?(klass) }
          next unless concrete.size > 1
          candidate = levenshtein_candidate(name, concrete)
          next unless candidate
          actions << { "kind" => "fix_sig_param", "confidence" => HIGH, "path" => src["path"], "line" => src["line"],
            "message" => "try Levenshtein param #{name} -> #{candidate[:type]} from observed #{concrete.first(8).join(", ")}",
            "data" => { "name" => name, "type" => candidate[:type], "distance" => candidate[:distance],
              "observed_classes" => concrete.sort, "callsites" => param_sites_for_levenshtein(rec)[name] || {} } }
        end
      end
      actions.sort_by! { |action| [action.dig("data", "distance").to_i, -action.dig("data", "observed_classes").to_a.size, action["path"], action["line"].to_i] }
      @levenshtein_limit.positive? ? actions.first(@levenshtein_limit) : actions
    end

    def params_for_levenshtein(rec)
      rec["params_ok"].empty? ? rec["params_by_name"] : rec["params_ok"]
    end

    def param_sites_for_levenshtein(rec)
      rec["param_sites_ok"].empty? ? rec["param_sites"] : rec["param_sites_ok"]
    end

    def ignored_levenshtein_class?(klass)
      klass == "NilClass" || klass == "T.untyped" || klass.to_s.include?("#") || klass.to_s.start_with?("Sorbet::Private::")
    end

    def levenshtein_candidate(param_name, classes)
      scored = classes.filter_map do |klass|
        base = klass.to_s.split("::").last
        score = normalized_param_names(param_name).map { |name| levenshtein_distance(name, normalize_type_name(base)) }.min
        next unless score && score <= @levenshtein_distance
        { type: klass, distance: score, base: base }
      end
      return nil if scored.empty?
      best_distance = scored.map { |item| item[:distance] }.min
      best = scored.select { |item| item[:distance] == best_distance }
      return nil if best.map { |item| normalize_type_name(item[:base]) }.uniq.size > 1
      best.min_by { |item| item[:type].length }
    end

    def normalized_param_names(name)
      normalized = normalize_type_name(name)
      variants = [normalized]
      variants << normalized.delete_suffix("s") if normalized.end_with?("s")
      variants << normalized.delete_suffix("node") if normalized.end_with?("node")
      variants << normalized.delete_suffix("tok") + "token" if normalized.end_with?("tok")
      variants.reject(&:empty?).uniq
    end

    def normalize_type_name(name)
      name.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    def levenshtein_distance(a, b)
      prev = (0..b.length).to_a
      a.each_char.with_index do |char_a, idx_a|
        cur = [idx_a + 1]
        b.each_char.with_index do |char_b, idx_b|
          cur << [
            cur[idx_b] + 1,
            prev[idx_b + 1] + 1,
            prev[idx_b] + (char_a == char_b ? 0 : 1),
          ].min
        end
        prev = cur
      end
      prev[b.length]
    end

    def apply_verified(actions)
      return 0 if actions.empty?

      # Z3 pre-filter: if the batch is provably inconsistent, bisect without
      # running the (expensive) spec suite.
      if actions.size > 1 && @z3_solver
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        consistent = @z3_solver.consistent?(actions)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        unless consistent
          warn "Z3: batch of #{actions.size} actions is UNSAT (#{elapsed.round(3)}s); bisecting without spec run"
          mid = actions.size / 2
          return apply_verified(actions.first(mid)) + apply_verified(actions.drop(mid))
        end
        puts "Z3: batch of #{actions.size} actions is SAT (#{elapsed.round(3)}s); proceeding to verify"
      end

      snapshot = snapshot_files(actions)
      changed = Apply.new([]).apply_actions(actions)
      ok, verify_output = verify(actions: actions)
      return changed if ok

      restore_files(snapshot)
      if actions.size == 1
        action = actions.first
        if (fallback = nilable_widening_fallback(action, verify_output))
          warn "retrying failing action as nilable: #{fallback["path"]}:#{fallback["line"]} #{fallback["kind"]}: #{fallback["message"]}"
          fallback_changed = apply_verified([fallback])
          return fallback_changed if fallback_changed.positive?
        end
        if hash_record_action?(action) && useless_tcast_feedback(verify_output).any?
          tcast_changed = retry_with_useless_tcast_cleanup(action, snapshot, verify_output)
          return tcast_changed if tcast_changed.positive?
        end
        @skipped << fingerprint(action)
        warn "skipping failing action: #{action["path"]}:#{action["line"]} #{action["kind"]}: #{action["message"]}"
        return 0
      end

      mid = actions.size / 2
      apply_verified(actions.first(mid)) + apply_verified(actions.drop(mid))
    end

    # rspec / parallel_rspec return exit 0 even when EVERY spec failed to
    # load (e.g. a NameError when the changed src/ file forward-references
    # something defined later in the same file). The summary in that case
    # is "0 examples, 0 failures, N errors occurred outside of examples"
    # but the process exit code is 0 because no examples ran.
    #
    # Without this check, the verify pipeline silently accepts code that
    # breaks `require` at the load step -- the bisecting loop then lands
    # broken actions and we discover the regression at the next full
    # spec-suite run. Match the two phrases rspec uses to signal load
    # failures and treat their presence as verify failure.
    RSPEC_LOAD_FAILURE_PATTERNS = [
      /\d+ errors? occurred outside of examples/,
      /An error occurred while loading \.\/spec\//,
    ].freeze

    def verify(actions: nil)
      cmd = @verify_spec_subset && actions ? subset_verify_cmd(actions) : @verify_cmd
      puts cmd.shelljoin
      out, err, status = Open3.capture3(*cmd)
      print out unless out.empty?
      warn err unless err.empty?
      combined = out + err
      ok = status.success? && RSPEC_LOAD_FAILURE_PATTERNS.none? { |re| re.match?(combined) }
      if status.success? && !ok
        warn "nil-kill loop: verify exit was 0 but rspec reported spec-load failures; treating as failure"
      end
      [ok, combined]
    end

    # When --verify-spec-subset is active, compute the rspec invocation
    # for ONLY the specs that transitively require any file the action
    # batch touches. Falls back to the full spec suite if no specs are
    # found (e.g. action touches a file no spec exercises -- still want
    # srb tc + at least minimum coverage).
    def subset_verify_cmd(actions)
      paths = snapshot_paths_for_actions(actions).map { |rel| File.expand_path(rel, ROOT) }
      specs = SpecDependencyIndex.instance.specs_depending_on(paths)
      rel_specs = specs.map { |abs| Pathname.new(abs).relative_path_from(Pathname.new(ROOT)).to_s }
      runner = self.class.spec_runner_command
      if rel_specs.empty?
        ["bash", "-c", "bundle exec srb tc"]
      else
        spec_args = rel_specs.map { |s| Shellwords.shellescape(s) }.join(" ")
        ["bash", "-c", "bundle exec srb tc && bundle exec #{runner} #{spec_args}"]
      end
    end

    def snapshot_paths_for_actions(actions)
      actions.flat_map { |action| snapshot_paths_for_action(action) }.uniq
    end

    # `prspec` (parallel_rspec) when installed, plain `rspec` otherwise.
    # Detected once per process; both run the same spec files just with
    # different parallelism semantics.
    def self.spec_runner_command
      return @spec_runner_command if defined?(@spec_runner_command)
      out, _, status = Open3.capture3("bundle", "exec", "which", "prspec")
      @spec_runner_command = status.success? && !out.strip.empty? ? "prspec" : "rspec"
    end

    def nilable_widening_fallback(action, verify_output)
      case action["kind"]
      when "fix_sig_return"
        nilable_return_fallback(action, verify_output)
      when "fix_sig_param"
        nilable_param_fallback(action, verify_output)
      end
    end

    def nilable_return_fallback(action, verify_output)
      original = action.dig("data", "type").to_s
      return nil if original.empty? || original.start_with?("T.nilable(") || original == "T.untyped"
      feedback = feedback_for_action(action, verify_output, "7005")
      return nil unless feedback && feedback["expected"] == original && feedback["found"] == "T.nilable(#{original})"
      widened_action(action, "T.nilable(#{original})", "retry return as T.nilable(#{original}) after Sorbet 7005")
    end

    def nilable_param_fallback(action, verify_output)
      original = action.dig("data", "type").to_s
      name = action.dig("data", "name").to_s
      return nil if original.empty? || name.empty? || original.start_with?("T.nilable(") || original == "T.untyped"
      feedback = feedback_for_action(action, verify_output, "7002")
      return nil unless feedback && feedback["arg"] == name && feedback["expected"] == original && feedback["found"] == "T.nilable(#{original})"
      widened_action(action, "T.nilable(#{original})", "retry param #{name} as T.nilable(#{original}) after Sorbet 7002")
    end

    def feedback_for_action(action, verify_output, code)
      infer = Infer.allocate
      infer.send(:parse_sorbet_feedback, verify_output).find do |feedback|
        feedback["code"] == code && feedback["path"] == action["path"] && feedback["line"].to_i == action["line"].to_i
      end
    end

    def widened_action(action, type, message)
      copy = Marshal.load(Marshal.dump(action))
      copy["message"] = message
      copy["data"]["type"] = type
      copy
    end

    def hash_record_action?(action)
      %w[promote_hash_record_to_struct promote_hash_record_cluster_to_struct].include?(action["kind"])
    end

    def retry_with_useless_tcast_cleanup(action, snapshot, verify_output)
      restore_files(snapshot)
      changed = Apply.new([]).apply_actions([action])
      cleaned = apply_useless_tcast_feedback(useless_tcast_feedback(verify_output), snapshot.keys)
      return 0 if changed.zero? && cleaned.zero?

      # `actions:` is mandatory under --verify-spec-subset, otherwise
      # verify falls through to @verify_cmd which is [] when the user
      # didn't supply a `-- cmd...` suffix. Open3.capture3(*[]) raises
      # ArgumentError, leaving src/ in the just-applied state because
      # the exception bypasses restore_files. Pass the action; wrap in
      # ensure so any unexpected exception still restores the snapshot.
      begin
        ok, second_output = verify(actions: [action])
        return changed + cleaned if ok

        restore_files(snapshot)
        warn second_output unless second_output.empty?
        0
      rescue StandardError => e
        restore_files(snapshot)
        warn "retry_with_useless_tcast_cleanup: verify raised #{e.class}: #{e.message}; restored snapshot"
        0
      end
    end

    def useless_tcast_feedback(output)
      feedback = []
      current = nil
      output.gsub(/\e\[[0-9;]*m/, "").lines.each do |line|
        if line =~ /^(.+?\.rb):(\d+): `T\.cast` is useless because .+ https:\/\/srb\.help\/7015/
          current = { "path" => $1, "line" => $2.to_i }
        elsif current && line =~ /^\s+.+?\.rb:\d+: Replace with `(.+?)`/
          feedback << current.merge("replacement" => $1)
          current = nil
        end
      end
      feedback
    end

    def apply_useless_tcast_feedback(feedback, allowed_paths)
      allowed = allowed_paths.map { |path| File.expand_path(path, ROOT) }.to_set
      grouped = feedback.group_by { |item| File.expand_path(item["path"], ROOT) }
      grouped.sum do |path, items|
        next 0 unless allowed.include?(path) && File.file?(path)
        source = File.read(path)
        parsed = Prism.parse(source)
        next 0 unless parsed.success?
        edits = []
        applier = Apply.allocate
        items.each do |item|
          replacement = item["replacement"].to_s
          next if replacement.empty?
          applier.send(:nodes_matching, parsed.value) do |node|
            node.is_a?(Prism::CallNode) &&
              node.location.start_line == item["line"].to_i &&
              node.name == :cast &&
              node.receiver&.slice == "T" &&
              node.arguments&.arguments&.first&.slice == replacement
          end.each do |node|
            edits << [node.location.start_offset, node.location.end_offset, replacement]
          end
        end
        next 0 if edits.empty?
        File.write(path, applier.send(:apply_source_edits, source, edits))
        edits.size
      end
    end

    def snapshot_files(actions)
      actions.flat_map { |action| snapshot_paths_for_action(action) }.uniq.each_with_object({}) do |rel_path, snapshot|
        path = File.join(ROOT, rel_path)
        snapshot[path] = File.read(path) if File.file?(path)
      end
    end

    def snapshot_paths_for_action(action)
      paths = [action["path"].to_s]
      if action["kind"] == "promote_hash_record_cluster_to_struct"
        data = action["data"] || {}
        paths.concat((Array(data["producers"]) + Array(data["consumers"]) + Array(data["signatures"]))
          .map { |site| site["path"].to_s })
      end
      paths.reject(&:empty?).uniq
    end

    def restore_files(snapshot)
      snapshot.each { |path, content| File.write(path, content) }
    end

    def fingerprint(action)
      JSON.generate([action["kind"], action["path"], action["line"], action["message"], action["data"]])
    end
  end
end
