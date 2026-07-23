# frozen_string_literal: true

require "digest"
require "mutant"
require "mutant/reporter/null"
require "open3"
require "pathname"
require "set"
require "tmpdir"
require_relative "fast_mutant_fork"
require_relative "run_to_complete"
require_relative "runtime_map_collector"

TestMiser::FastMutantFork.install

module TestMiser
  class CollectionError < StandardError; end

  class MutantCollector
    CHECKPOINT_INTERVAL = 25

    def initialize(
      includes:, requires:, subjects:, timeout: 5.0, progress: nil,
      shard_index: 0, shard_total: 1, resume_payload: nil, checkpoint: nil,
      selection_payload: nil, run_to_complete: false, candidate_signatures: {}, since: nil,
      integration: "minitest", integration_arguments: []
    )
      @includes = includes
      @requires = requires
      @subjects = subjects
      @timeout = timeout
      @progress = progress || ->(_message) {}
      @shard_index = shard_index
      @shard_total = shard_total
      @resume_payload = resume_payload
      @checkpoint = checkpoint || ->(_report) {}
      @selection_payload = selection_payload
      @run_to_complete = run_to_complete
      @candidate_signatures = candidate_signatures
      @since = since
      @integration = integration
      @integration_arguments = integration_arguments
      validate_shard
    end

    def call
      env = bootstrap
      tests = env.integration.all_tests.sort_by(&:id)
      if @selection_payload&.key?("testIds")
        selected_ids = @selection_payload.fetch("testIds").to_set
        tests = tests.select { |test| selected_ids.include?(test.id) }
      end
      raise CollectionError, "#{@integration} integration discovered no tests" if tests.empty?

      selections = @selection_payload ? load_selections(tests) : trace_baselines(env, tests)
      all_mutations = evil_mutations(env)
      matched_subjects = env.subjects.map { |subject| subject.expression.syntax }.uniq.sort
      fingerprint = corpus_fingerprint(all_mutations)
      assigned_mutations = shard(all_mutations)
      rows = resumed_rows(fingerprint, assigned_mutations)
      initialize_audit_candidates(tests, rows)
      completed_ids = rows.to_set { |row| row.fetch("id") }
      pending = assigned_mutations.reject { |mutation| completed_ids.include?(stable_mutation_id(mutation)) }

      @progress.call(
        "Collecting shard #{@shard_index + 1}/#{@shard_total}: " \
        "#{pending.length} pending of #{assigned_mutations.length} mutants across #{tests.length} tests"
      )
      pending.each_with_index do |mutation, index|
        row = collect_mutation(env, mutation, selections, index + 1, pending.length)
        rows << row
        record_audit_result(row)
        checkpoint(tests, rows, all_mutations, fingerprint, matched_subjects) if checkpoint?(index + 1, pending.length)
      end

      build_report(tests, rows, all_mutations, fingerprint, matched_subjects)
    end

    private

    def validate_shard
      valid = @shard_total.positive? && @shard_index >= 0 && @shard_index < @shard_total
      raise CollectionError, "invalid shard #{@shard_index + 1}/#{@shard_total}" unless valid
    end

    def bootstrap
      raise CollectionError, "at least one subject expression is required" if @subjects.empty?

      parser = ::Mutant::Config::DEFAULT.expression_parser
      expressions = @subjects.map do |subject|
        parser.call(subject).from_right { |error| raise CollectionError, error }
      end
      matcher = ::Mutant::Matcher::Config::DEFAULT.with(subjects: expressions)
      if @since
        matcher = matcher.with(
          diffs: [::Mutant::Repository::Diff.new(to: @since, world: ::Mutant::WORLD)]
        )
      end
      config = ::Mutant::Config::DEFAULT.with(
        includes: @includes.map { |path| File.expand_path(path) },
        integration: ::Mutant::Integration::Config::DEFAULT.with(
          name: @integration, arguments: expanded_integration_arguments
        ),
        matcher: matcher,
        mutation: ::Mutant::Mutation::Config::DEFAULT.with(timeout: @timeout),
        reporter: ::Mutant::Reporter::Null.new,
        requires: @requires.map { |path| path.start_with?(".", "/") ? File.expand_path(path) : path },
        usage: ::Mutant::Usage::Opensource.new
      )

      boot = lambda do
        ::Mutant::Bootstrap.call(::Mutant::Env.empty(::Mutant::WORLD, config)).from_right do |error|
          raise CollectionError, error
        end
      end
      Dir.mktmpdir("test-miser-bootstrap") do |directory|
        if @since
          with_repository_git_environment { Dir.chdir(directory) { boot.call } }
        else
          Dir.chdir(directory) { boot.call }
        end
      end
    rescue LoadError, ::Mutant::Repository::Diff::Error => error
      raise CollectionError, error.message
    end

    def expanded_integration_arguments
      @integration_arguments.map { |argument| File.exist?(argument) ? File.expand_path(argument) : argument }
    end

    def with_repository_git_environment
      root, root_status = Open3.capture2e("git", "rev-parse", "--show-toplevel")
      git_dir, dir_status = Open3.capture2e("git", "rev-parse", "--absolute-git-dir")
      unless root_status.success? && dir_status.success?
        raise CollectionError, "--since requires a Git worktree"
      end
      root = root.chomp
      git_dir = git_dir.chomp

      previous_dir = ENV["GIT_DIR"]
      previous_work_tree = ENV["GIT_WORK_TREE"]
      ENV["GIT_DIR"] = git_dir
      ENV["GIT_WORK_TREE"] = root
      yield
    ensure
      previous_dir ? ENV["GIT_DIR"] = previous_dir : ENV.delete("GIT_DIR")
      previous_work_tree ? ENV["GIT_WORK_TREE"] = previous_work_tree : ENV.delete("GIT_WORK_TREE")
    end

    def trace_baselines(env, tests)
      source_paths = env.subjects.to_set { |subject| expanded_path(subject.source_path) }
      selections = Hash.new { |hash, key| hash[key] = [] }
      @progress.call("Tracing #{tests.length} passing baseline tests")

      failures = tests.filter_map do |test|
        result = env.config.isolation.call(@timeout) do
          calls = Set.new
          trace = TracePoint.new(:call) do |event|
            path = expanded_path(event.path)
            calls.add([path, event.lineno]) if source_paths.include?(path)
          end
          test_result = trace.enable { env.integration.call([test]) }
          { "passed" => test_result.passed, "calls" => calls.to_a }
        end
        unless result.valid_value? && result.value.fetch("passed")
          next test.id
        end

        result.value.fetch("calls").each { |key| selections[key] << test }
        nil
      end
      unless failures.empty?
        raise CollectionError, "baseline tests failed or timed out: #{failures.join(', ')}"
      end

      selections
    end

    def load_selections(tests)
      unless @selection_payload["complete"] == true &&
          @selection_payload["sourceFingerprint"] == SourceFingerprint.call(@includes)
        raise CollectionError, "runtime selection map is incomplete or stale"
      end
      test_index = tests.to_h { |test| [test.id, test] }
      expected_tests = @selection_payload["expectedTests"]
      unless expected_tests == tests.length
        raise CollectionError,
          "runtime selection map has a different test inventory " \
          "(map=#{expected_tests.inspect}, collector=#{tests.length})"
      end

      @selection_payload.fetch("selections").to_h do |entry|
        key = [expanded_path(entry.fetch("path")), entry.fetch("line")]
        selected = entry.fetch("tests").map { |id| test_index.fetch(id) }
        [key, selected]
      end
    rescue KeyError => error
      raise CollectionError, "invalid runtime selection map: #{error.message}"
    end

    def evil_mutations(env)
      mutations = env.mutations.reject { |mutation| mutation.identification.start_with?("neutral:") }
        .sort_by { |mutation| stable_mutation_id(mutation) }
      # A selected subject can legitimately have no non-neutral mutations.
      # Report that as a complete empty component; rejecting it makes a corpus
      # generated from SubjectInventory unable to collect itself.
      mutations
    end

    def shard(mutations)
      mutations.each_with_index.filter_map do |mutation, index|
        mutation if (index % @shard_total) == @shard_index
      end
    end

    def collect_mutation(env, mutation, selections, number, total)
      selected_tests = selections.fetch(subject_key(mutation.subject), []).sort_by(&:id)
      audit_tests = if @run_to_complete
        selected_tests.select { |test| @audit_candidate_ids.include?(test.id) }
      else
        selected_tests
      end
      if number == 1 || number == total || (number % CHECKPOINT_INTERVAL).zero?
        @progress.call(
          "[#{number}/#{total}] #{stable_mutation_id(mutation)} " \
          "(#{audit_tests.length}/#{selected_tests.length} audit tests, #{@audit_candidate_ids.length} unresolved)"
        )
      end
      outcome, killed_by = if selected_tests.empty?
        [:no_coverage, []]
      elsif audit_tests.empty?
        [:audit_skipped, []]
      else
        run_tests(env, mutation, audit_tests)
      end
      attribution_complete = @run_to_complete && !%i[timeout error].include?(outcome)

      {
        "id" => stable_mutation_id(mutation),
        "mutatorName" => mutation.class.name,
        "status" => mutation_status(outcome),
        "coveredBy" => selected_tests.map(&:id),
        "killedBy" => killed_by,
        "auditAttributionComplete" => attribution_complete,
        "sourceFile" => relative_path(mutation.subject.source_path),
        "subject" => mutation.subject.expression.syntax,
        "line" => mutation.subject.source_line
      }
    end

    def initialize_audit_candidates(tests, rows)
      @all_test_ids = tests.map(&:id).sort
      @killed_mutants_by_test = @all_test_ids.to_h { |id| [id, Set.new] }
      @candidate_signatures.each do |test_id, signature|
        @killed_mutants_by_test.fetch(test_id).add("prior:#{signature}") if signature
      end
      rows.each { |row| add_kills(row) }
      refresh_audit_candidates
    end

    def record_audit_result(row)
      add_kills(row)
      refresh_audit_candidates
    end

    def add_kills(row)
      row.fetch("killedBy").each do |test_id|
        @killed_mutants_by_test.fetch(test_id).add(row.fetch("id"))
      end
    end

    def refresh_audit_candidates
      signatures = @all_test_ids.group_by do |test_id|
        @killed_mutants_by_test.fetch(test_id).to_a.sort
      end
      @audit_candidate_ids = signatures.each_with_object(Set.new) do |(signature, test_ids), active|
        active.merge(test_ids) if signature.empty? || test_ids.length > 1
      end
    end

    def run_tests(env, mutation, tests)
      isolation_timeout = @run_to_complete ? @timeout * (tests.length + 1) : @timeout
      result = with_scratch_directory do
        env.config.isolation.call(isolation_timeout) do
          env.hooks.run(:mutation_insert_pre, mutation: mutation)
          insertion = mutation.insert(env.world.kernel)
          env.hooks.run(:mutation_insert_post, mutation: mutation)
          insertion.either(
            ->(_error) { { "type" => "insertion_error" } },
            ->(_value) do
              refresh_module_function(mutation.subject)
              test_result = if @run_to_complete
                RunToComplete.call(env.integration, tests, timeout: @timeout)
              else
                standard_result = env.integration.call(tests)
                { "passed" => standard_result.passed, "killedBy" => [] }
              end
              test_result.merge("type" => "test")
            end
          )
        end
      end

      return [:timeout, []] if result.timeout
      return [:error, []] unless result.valid_value?
      return [:error, []] unless result.value.fetch("type") == "test"

      killed_by = result.value.fetch("killedBy")
      outcome = result.value.fetch("passed") ? :survived : :killed
      [outcome, killed_by]
    end

    def with_scratch_directory
      previous = ENV["TMPDIR"]
      Dir.mktmpdir("test-miser-mutant") do |directory|
        ENV["TMPDIR"] = directory
        yield
      ensure
        previous ? ENV["TMPDIR"] = previous : ENV.delete("TMPDIR")
      end
    end

    def refresh_module_function(subject)
      scope = subject.__send__(:scope).raw
      name = subject.name
      return if scope.instance_of?(Class)
      return unless scope.private_instance_methods(false).include?(name)
      return unless scope.singleton_methods(false).include?(name)

      scope.__send__(:module_function, name)
    end

    def mutation_status(outcome)
      {
        no_coverage: "NoCoverage",
        audit_skipped: "AuditSkipped",
        killed: "Killed",
        timeout: "Timeout",
        error: "RuntimeError",
        survived: "Survived"
      }.fetch(outcome)
    end

    def resumed_rows(fingerprint, assigned_mutations)
      return [] unless @resume_payload

      metadata = @resume_payload.fetch("testMiser", {})
      unless metadata["corpusFingerprint"] == fingerprint
        raise CollectionError, "resume report belongs to a different mutant corpus"
      end
      expected_ids = assigned_mutations.to_set { |mutation| stable_mutation_id(mutation) }
      @resume_payload.fetch("files", {}).flat_map do |file, details|
        Array(details["mutants"]).filter_map do |mutant|
          next unless expected_ids.include?(mutant["id"])
          next unless mutant["auditAttributionComplete"] == true

          mutant.merge("sourceFile" => file)
        end
      end
    end

    def checkpoint?(completed, total)
      completed == total || (completed % CHECKPOINT_INTERVAL).zero?
    end

    def checkpoint(tests, rows, all_mutations, fingerprint, matched_subjects)
      @checkpoint.call(build_report(tests, rows, all_mutations, fingerprint, matched_subjects))
    end

    def build_report(tests, rows, all_mutations, fingerprint, matched_subjects)
      files = rows.group_by { |row| row.fetch("sourceFile") }.transform_values do |file_rows|
        { "mutants" => file_rows.map { |row| row.reject { |key, _value| key == "sourceFile" } } }
      end
      test_files = tests.group_by { |test| test_location(test).fetch(:file) }.transform_values do |file_tests|
        {
          "tests" => file_tests.map do |test|
            location = test_location(test)
            { "id" => test.id, "name" => location.fetch(:name), "line" => location[:line] }.compact
          end
        }
      end
      assigned_count = shard(all_mutations).length
      compatible_subjects = all_mutations.map { |mutation| mutation.subject.expression.syntax }.uniq.sort
      audit_attribution_complete = rows.all? { |row| row["auditAttributionComplete"] == true }

      {
        "schemaVersion" => "2.0",
        "thresholds" => { "high" => 100, "low" => 0 },
        "files" => files,
        "testFiles" => test_files,
        "testMiser" => {
          "schemaVersion" => "1",
          "subjectExpressions" => @subjects.sort,
          "selectionScope" => @since ? "pr" : "full",
          "sinceRevision" => @since,
          "matchedSubjects" => matched_subjects,
          "mutationCompatibleSubjects" => compatible_subjects,
          "corpusFingerprint" => fingerprint,
          "expectedMutants" => all_mutations.length,
          "expectedTests" => tests.length,
          "shard" => { "index" => @shard_index, "total" => @shard_total },
          "assignedMutants" => assigned_count,
          "completedMutants" => rows.length,
          "runToComplete" => @run_to_complete,
          "attributionMode" => "audit-candidate-elimination",
          "killSetsComplete" => false,
          "candidateSeedFingerprint" => Digest::SHA256.hexdigest(
            @candidate_signatures.sort_by(&:first).flatten.join("\0")
          ),
          "unresolvedAuditTests" => @audit_candidate_ids.to_a.sort,
          "complete" => @run_to_complete && audit_attribution_complete &&
            @shard_total == 1 && rows.length == all_mutations.length
        }
      }
    end

    def corpus_fingerprint(mutations)
      Digest::SHA256.hexdigest(mutations.map { |mutation| stable_mutation_id(mutation) }.join("\0"))
    end

    def subject_key(subject)
      [expanded_path(subject.source_path), subject.source_line]
    end

    def test_location(test)
      if (match = test.id.match(%r{\Arspec:\d+:(.+):(\d+)/(.*)\z}))
        return {
          file: relative_path(match[1]),
          line: Integer(match[2]),
          name: match[3]
        }
      end

      class_name, method_name = test.id.delete_prefix("minitest:").split("#", 2)
      klass = class_name.split("::").reject(&:empty?).inject(Object) { |namespace, name| namespace.const_get(name) }
      file, line = klass.instance_method(method_name).source_location
      {
        file: file ? relative_path(file) : "(unknown)",
        line: line,
        name: test.id.delete_prefix("minitest:")
      }
    rescue NameError
      { file: "(unknown)", line: nil, name: test.id }
    end

    def expanded_path(path)
      Pathname.new(path).expand_path.to_s
    end

    def relative_path(path)
      Pathname.new(path).expand_path.relative_path_from(Pathname.pwd.expand_path).to_s
    rescue ArgumentError
      path.to_s
    end

    def stable_mutation_id(mutation)
      full_digest = Digest::SHA1.hexdigest(
        mutation.subject.identification + ::Mutant::Mutation::CODE_DELIMITER + mutation.source
      )
      mutation.identification.sub(/:[^:]+\z/, ":#{full_digest}").sub(
        mutation.subject.source_path.to_s,
        relative_path(mutation.subject.source_path)
      )
    end
  end
end
