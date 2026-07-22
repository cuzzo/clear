# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require_relative "analyzer"
require_relative "location_resolver"
require_relative "mutation_report"
require_relative "reporter"
require_relative "evidence/report"

module TestMiser
  class CorpusError < StandardError; end

  module CanonicalJSON
    module_function

    def generate(value)
      JSON.generate(sort(value))
    end

    def sort(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h { |key| [key, sort(value.fetch(key))] }
      when Array
        value.map { |item| sort(item) }
      else
        value
      end
    end

    def digest(value)
      "sha256:#{Digest::SHA256.hexdigest(generate(value))}"
    end
  end

  module ZstdJSON
    module_function

    def read(path)
      JSON.parse(uncompressed_bytes(path))
    rescue JSON::ParserError => error
      raise CorpusError, "invalid JSON in #{path}: #{error.message}"
    end

    def uncompressed_bytes(path)
      if path.end_with?(".zst")
        stdout, stderr, status = Open3.capture3("zstd", "-q", "-d", "-c", path)
        raise CorpusError, "zstd decompression failed: #{stderr}" unless status.success?

        stdout
      else
        File.binread(path)
      end
    rescue Errno::ENOENT
      raise CorpusError, "zstd executable is required for .zst artifacts" if path.end_with?(".zst")

      raise
    end

    def write(path, value)
      json = "#{CanonicalJSON.generate(value)}\n"
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      if path.end_with?(".zst")
        stdout, stderr, status = Open3.capture3("zstd", "-q", "-6", "-c", stdin_data: json)
        raise CorpusError, "zstd compression failed: #{stderr}" unless status.success?

        atomic_write(path, stdout)
      else
        atomic_write(path, json)
      end
      json
    rescue Errno::ENOENT
      raise CorpusError, "zstd executable is required for .zst artifacts"
    end

    def atomic_write(path, bytes)
      temporary = "#{path}.tmp-#{Process.pid}"
      File.binwrite(temporary, bytes)
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end
  end

  class MutationCorpus
    SCHEMA = "mutation-corpus/v1"
    DELTA_SCHEMA = "mutation-delta/v1"
    MANIFEST_SCHEMA = "mutation-corpus-manifest/v1"

    attr_reader :payload, :delta

    def self.update(repository:, commit:, parent_commit:, base: nil, inventories: {}, reports: {}, required_suites: [])
      new(
        repository: repository,
        commit: commit,
        parent_commit: parent_commit,
        base: base,
        inventories: inventories,
        reports: reports,
        required_suites: required_suites
      ).tap(&:update)
    end

    def initialize(repository:, commit:, parent_commit:, base:, inventories:, reports:, required_suites:)
      @repository = repository
      @commit = commit
      @parent_commit = parent_commit
      @base = base
      @inventory_paths = inventories
      @report_paths = reports
      @required_suites = required_suites
    end

    def update
      validate_base!
      previous = @base ? deep_copy(@base) : empty_corpus
      @payload = deep_copy(previous)
      @payload["repository"] = @repository
      @payload["commit"] = @commit
      @payload["parent_commit"] = @parent_commit

      @inventory_paths.each do |suite, path|
        inventory = normalize_inventory(suite, JSON.parse(File.read(path)))
        @payload["inventories"][suite] = inventory
        expected = inventory.fetch("components").map { |entry| entry.fetch("id") }.to_h { |id| [id, true] }
        @payload["components"].delete_if do |id, component|
          component["suite"] == suite && !expected.key?(id)
        end
      end

      @report_paths.each do |suite, paths|
        paths = Array(paths)
        next if paths.empty?

        inventory = @payload.fetch("inventories").fetch(suite) do
          raise CorpusError, "suite #{suite} has reports but no inventory"
        end
        components = {}
        tests = {}
        paths.each do |path|
          normalized = normalize_report(suite, JSON.parse(File.read(path)), inventory, source: path)
          normalized.fetch("components").each { |component| components[component.fetch("id")] = component }
          normalized.fetch("tests").each { |test| tests[test.fetch("id")] = test }
        end
        components.each { |id, component| @payload["components"][id] = component }
        @payload["tests"][suite] = tests.values.sort_by { |test| test.fetch("id") }
      end

      validate_complete!
      @payload["components"] = @payload.fetch("components").sort.to_h
      @payload["inventories"] = @payload.fetch("inventories").sort.to_h
      @payload["tests"] = @payload.fetch("tests").sort.to_h
      @payload["complete"] = true
      @payload["state_digest"] = state_digest(@payload)
      @delta = build_delta(previous, @payload)
      self
    rescue JSON::ParserError => error
      raise CorpusError, "invalid mutation artifact JSON: #{error.message}"
    rescue Errno::ENOENT => error
      raise CorpusError, error.message
    end

    def write(output:, manifest:, delta: nil, materialize: nil)
      corpus_json = ZstdJSON.write(output, @payload)
      delta_json = delta && ZstdJSON.write(delta, @delta)
      members = {
        File.basename(output) => member_metadata(output, corpus_json)
      }
      members[File.basename(delta)] = member_metadata(delta, delta_json) if delta
      lineage_members = []
      if materialize
        materialized = materialize_to(materialize)
        materialized.each do |path|
          relative = Pathname.new(path).relative_path_from(Pathname.new(File.dirname(File.expand_path(manifest)))).to_s
          raise CorpusError, "materialized member is outside the artifact directory: #{path}" if relative.start_with?("../")

          members[relative] = member_metadata(path, File.binread(path))
          lineage_members << relative
        end
      end
      manifest_payload = {
        "schema" => MANIFEST_SCHEMA,
        "repository" => @repository,
        "commit" => @commit,
        "parent_commit" => @parent_commit,
        "state_digest" => @payload.fetch("state_digest"),
        "complete" => true,
        "members" => members.sort.to_h,
        "lineage" => {
          "mutant_facts" => lineage_members.select { |path| File.basename(path).start_with?("mutant-facts-") }.sort,
          "sarif" => lineage_members.select { |path| path.end_with?(".sarif") }.sort
        }
      }
      ZstdJSON.write(manifest, manifest_payload)
      manifest_payload
    end

    def materialize_to(directory)
      FileUtils.mkdir_p(directory)
      written = []
      @payload.fetch("inventories").each_key do |suite|
        facts = facts_for(suite)
        token = Digest::SHA256.hexdigest(suite)[0, 12]
        facts_path = File.join(directory, "mutant-facts-#{token}.json")
        ZstdJSON.write(facts_path, facts)
        written << File.expand_path(facts_path)
      end

      sarif_runs = @payload.fetch("inventories").keys.filter_map do |suite|
        facts = facts_for(suite)
        report = MutationReport.new(facts, source: "mutation corpus #{suite}")
        analysis = Analyzer.new(report).analyze
        JSON.parse(Reporter.new(analysis).sarif).fetch("runs").first
      end
      sarif_path = File.join(directory, "weak-tests.sarif")
      ZstdJSON.write(sarif_path, {
        "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "version" => "2.1.0",
        "runs" => sarif_runs
      })
      written << File.expand_path(sarif_path)

      evidence_runs = @payload.fetch("inventories").keys.filter_map do |suite|
        facts = facts_for(suite)
        report = MutationReport.new(facts, source: "mutation corpus #{suite}")
        corpus = Evidence::Corpus.from_report(report)
        scope = corpus.evidence_scope(revision: @commit)
        contributions = Evidence::ContributionAnalyzer.new(corpus, scope: scope).analyze
        subsumption = Evidence::SubsumptionAnalyzer.new(corpus, scope: scope).analyze(contributions: contributions)
        evidence = Evidence::ReportBuilder.new(corpus, scope: scope).build(
          contributions: contributions,
          subsumption: subsumption,
        )
        JSON.parse(evidence.sarif).fetch("runs").first
      end
      evidence_path = File.join(directory, "evidence.sarif")
      ZstdJSON.write(evidence_path, {
        "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "version" => "2.1.0",
        "runs" => evidence_runs,
      })
      written << File.expand_path(evidence_path)
      written
    end

    def facts_for(suite)
      components = @payload.fetch("components").values.select { |component| component["suite"] == suite }
      {
        "schema" => "mutant-facts/v1",
        "source" => "test-miser-corpus",
        "language" => components.first&.fetch("language", nil) || "unknown",
        "mutation_kind" => "stochastic",
        "subjects" => components.flat_map { |component| component.fetch("subjects") }
          .sort_by { |subject| [subject["file"].to_s, subject["method"].to_s] },
        "tests" => @payload.dig("tests", suite) || [],
        "mutants" => components.flat_map { |component| component.fetch("mutants") }
          .sort_by { |mutant| mutant.fetch("id") },
        "test_miser" => {
          "complete" => true,
          "attribution_complete" => true,
          "run_to_complete" => true,
          "corpus_state_digest" => @payload.fetch("state_digest"),
          "commit" => @commit,
          "suite" => suite
        }
      }
    end

    def self.verify!(corpus_path:, manifest_path:)
      corpus = ZstdJSON.read(corpus_path)
      manifest = ZstdJSON.read(manifest_path)
      raise CorpusError, "unsupported corpus schema" unless corpus["schema"] == SCHEMA
      raise CorpusError, "unsupported manifest schema" unless manifest["schema"] == MANIFEST_SCHEMA
      raise CorpusError, "corpus is not complete" unless corpus["complete"] == true && manifest["complete"] == true
      raise CorpusError, "manifest repository mismatch" unless manifest["repository"] == corpus["repository"]
      raise CorpusError, "manifest commit mismatch" unless manifest["commit"] == corpus["commit"]
      raise CorpusError, "manifest parent mismatch" unless manifest["parent_commit"] == corpus["parent_commit"]
      actual_state = state_digest(corpus)
      raise CorpusError, "corpus state digest mismatch" unless corpus["state_digest"] == actual_state
      raise CorpusError, "manifest state digest mismatch" unless manifest["state_digest"] == actual_state

      verify_members!(manifest, manifest_path)
      raise CorpusError, "manifest does not describe the requested corpus" unless
        manifest.fetch("members").key?(File.basename(corpus_path))

      corpus
    rescue KeyError => error
      raise CorpusError, "invalid corpus manifest: #{error.message}"
    end

    def self.state_digest(payload)
      logical = payload.reject { |key, _value| %w[commit parent_commit state_digest].include?(key) }
      CanonicalJSON.digest(logical)
    end

    def state_digest(payload)
      self.class.state_digest(payload)
    end

    def self.sha256(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def self.verify_members!(manifest, manifest_path)
      root = File.dirname(File.expand_path(manifest_path))
      manifest.fetch("members").each do |relative, metadata|
        path = File.expand_path(relative, root)
        unless path.start_with?("#{root}/") && File.file?(path)
          raise CorpusError, "missing or unsafe manifest member: #{relative}"
        end

        bytes = File.binread(path)
        uncompressed = ZstdJSON.uncompressed_bytes(path)
        raise CorpusError, "member size mismatch: #{relative}" unless metadata["bytes"] == bytes.bytesize
        raise CorpusError, "member digest mismatch: #{relative}" unless metadata["digest"] == sha256(bytes)
        unless metadata["uncompressed_bytes"] == uncompressed.bytesize
          raise CorpusError, "uncompressed member size mismatch: #{relative}"
        end
        unless metadata["uncompressed_digest"] == sha256(uncompressed)
          raise CorpusError, "uncompressed member digest mismatch: #{relative}"
        end
      end
    end

    private

    def validate_base!
      return unless @base
      raise CorpusError, "unsupported base corpus schema" unless @base["schema"] == SCHEMA
      raise CorpusError, "base corpus is incomplete" unless @base["complete"] == true
      raise CorpusError, "base repository mismatch" unless @base["repository"] == @repository
      raise CorpusError, "base commit #{@base['commit']} does not equal parent #{@parent_commit}" unless @base["commit"] == @parent_commit
      raise CorpusError, "base state digest mismatch" unless @base["state_digest"] == state_digest(@base)
    end

    def validate_complete!
      suites = (@required_suites + @payload.fetch("inventories").keys).uniq
      suites.each do |suite|
        inventory = @payload.fetch("inventories")[suite]
        raise CorpusError, "required suite #{suite} has no inventory" unless inventory
        actual = @payload.fetch("components").values
          .select { |component| component["suite"] == suite }
          .to_h { |component| [component.fetch("id"), component] }
        missing = inventory.fetch("components").filter_map do |entry|
          id = entry.fetch("id")
          id unless actual[id]&.fetch("complete", false)
        end
        raise CorpusError, "suite #{suite} is missing complete components: #{missing.join(', ')}" unless missing.empty?
        raise CorpusError, "suite #{suite} has no current test inventory" unless @payload.fetch("tests").key?(suite)
      end
    end

    def empty_corpus
      {
        "schema" => SCHEMA,
        "repository" => @repository,
        "commit" => @commit,
        "parent_commit" => @parent_commit,
        "inventories" => {},
        "tests" => {},
        "components" => {},
        "complete" => false
      }
    end

    def normalize_inventory(suite, payload)
      rows = if payload["schemaVersion"] == "test-miser-subject-inventory/v1"
        payload.fetch("subjects").map do |entry|
          identity = entry.fetch("expression")
          {
            "id" => component_id(suite, identity),
            "identity" => identity,
            "file" => entry.fetch("file"),
            "line" => entry["line"]
          }.compact
        end
      elsif payload["subjects"].is_a?(Array) && payload["subjects"].all? { |entry| entry["source"] }
        payload.fetch("subjects").map do |entry|
          identity = entry.fetch("source")
          {
            "id" => component_id(suite, identity),
            "identity" => identity,
            "file" => identity
          }
        end
      else
        raise CorpusError, "unsupported inventory for suite #{suite}"
      end
      {
        "suite" => suite,
        "fingerprint" => CanonicalJSON.digest(rows),
        "components" => rows.sort_by { |entry| entry.fetch("id") }
      }
    end

    def normalize_report(suite, payload, inventory, source:)
      if payload["files"].is_a?(Hash)
        normalize_mte_report(suite, payload, inventory, source: source)
      elsif payload["schema"].to_s.start_with?("mutant-facts/")
        normalize_facts_report(suite, payload, inventory, source: source)
      else
        raise CorpusError, "#{source}: unsupported mutation report"
      end
    end

    def normalize_mte_report(suite, payload, inventory, source:)
      metadata = payload.fetch("testMiser", {})
      raise CorpusError, "#{source}: incomplete MTE report" unless metadata["complete"] == true && metadata["runToComplete"] == true
      inventory_by_identity = inventory.fetch("components").to_h { |entry| [entry.fetch("identity"), entry] }
      full = metadata["selectionScope"] != "pr"
      selected = if full
        inventory_by_identity.keys
      else
        Array(metadata["matchedSubjects"] || metadata["mutationCompatibleSubjects"])
      end
      mutants_by_subject = Hash.new { |hash, key| hash[key] = [] }
      payload.fetch("files").each do |file, details|
        Array(details["mutants"]).each do |row|
          subject = row["subject"] || subject_from_mte_id(row.fetch("id"), file)
          raise CorpusError, "#{source}: mutant #{row['id']} has no stable subject" unless subject
          selected << subject
          mutants_by_subject[subject] << normalize_mutant(row, file: file, subject: subject)
        end
      end
      components = selected.uniq.filter_map do |identity|
        entry = inventory_by_identity[identity]
        next unless entry
        rows = mutants_by_subject[identity].sort_by { |mutant| mutant.fetch("id") }
        component(suite, entry, "ruby", rows, source: "ruby-mutant")
      end
      {
        "components" => components,
        "tests" => mte_tests(payload)
      }
    end

    def normalize_facts_report(suite, payload, inventory, source:)
      metadata = payload.fetch("test_miser", {})
      unless metadata["complete"] == true && metadata["attribution_complete"] == true && metadata["run_to_complete"] == true
        raise CorpusError, "#{source}: incomplete mutant-facts report"
      end
      files = Array(payload["mutants"]).map { |row| row["file"] }.compact.uniq
      files = Array(payload["subjects"]).map { |row| row["file"] }.compact.uniq if files.empty?
      selected = Array(metadata["selected_components"])
      selected = files if selected.empty?
      raise CorpusError, "#{source}: facts report does not identify a source component" if selected.empty?

      inventory_by_identity = inventory.fetch("components").to_h { |entry| [entry.fetch("identity"), entry] }
      mutants_by_file = Array(payload["mutants"]).group_by { |row| row["file"] }
      subjects_by_file = Array(payload["subjects"]).group_by { |row| row["file"] }
      components = selected.uniq.map do |identity|
        entry = inventory_by_identity[identity]
        raise CorpusError, "#{source}: source #{identity} is absent from suite inventory" unless entry

        mutants = Array(mutants_by_file[identity]).map do |row|
          normalize_mutant(row, file: identity, subject: row["method"])
        end
        subjects = Array(subjects_by_file[identity]).map { |row| normalize_subject(row) }
        normalized = component(suite, entry, payload["language"] || "unknown", mutants, source: payload["source"])
        normalized["subjects"] = subjects unless subjects.empty?
        normalized
      end
      {
        "components" => components,
        "tests" => Array(payload["tests"]).map { |test| normalize_test(test) }
      }
    end

    def component(suite, entry, language, mutants, source:)
      subjects = subject_summaries(entry, mutants, source: source, language: language)
      {
        "id" => entry.fetch("id"),
        "suite" => suite,
        "identity" => entry.fetch("identity"),
        "language" => language,
        "complete" => true,
        "subjects" => subjects,
        "mutants" => mutants,
        "digest" => CanonicalJSON.digest([subjects, mutants])
      }
    end

    def subject_summaries(entry, mutants, source:, language:)
      groups = mutants.group_by { |mutant| mutant["method"] || entry.fetch("identity") }
      groups[entry.fetch("identity")] ||= []
      groups.map do |method, rows|
        killed = rows.count { |row| row["outcome"] == "killed" }
        alive = rows.count { |row| row["outcome"] == "survived" }
        {
          "file" => entry.fetch("file"),
          "method" => method,
          "source" => source || "test-miser",
          "language" => language,
          "mutation_kind" => "stochastic",
          "mutations" => rows.length,
          "killed" => killed,
          "alive" => alive,
          "kill_rate" => rows.empty? ? nil : (killed * 100.0 / rows.length).round(2)
        }.compact
      end.sort_by { |row| row.fetch("method") }
    end

    def normalize_mutant(row, file:, subject:)
      {
        "id" => row.fetch("id"),
        "file" => file,
        "method" => subject,
        "kind" => row["kind"] || row["mutatorName"],
        "outcome" => normalize_outcome(row["outcome"] || row["status"]),
        "line" => row["line"] || line_from_mte_id(row.fetch("id"), file),
        "column" => row["column"],
        "covered_by" => Array(row["covered_by"] || row["coveredBy"]).sort,
        "killed_by" => Array(row["killed_by"] || row["killedBy"]).sort
      }.compact
    end

    def normalize_outcome(value)
      {
        "Killed" => "killed", "Survived" => "survived", "NoCoverage" => "no_coverage",
        "Timeout" => "timeout", "RuntimeError" => "error", "AuditSkipped" => "skipped"
      }.fetch(value.to_s, value.to_s.downcase)
    end

    def normalize_subject(row)
      row.slice("file", "method", "source", "language", "mutation_kind", "kill_rate", "gate_status",
        "mutations", "killed", "alive", "selected_tests")
    end

    def normalize_test(row)
      {
        "id" => row.fetch("id"),
        "name" => row["name"] || row.fetch("id"),
        "file" => row["file"],
        "line" => row["line"]
      }.compact
    end

    def mte_tests(payload)
      payload.fetch("testFiles", {}).flat_map do |file, details|
        Array(details["tests"]).map { |test| normalize_test(test.merge("file" => test["file"] || file)) }
      end.sort_by { |test| test.fetch("id") }
    end

    def subject_from_mte_id(id, file)
      id[/\A[^:]+:(.*?):#{Regexp.escape(file)}:\d+:/, 1]
    end

    def line_from_mte_id(id, file)
      value = id[/\A[^:]+:.*?:#{Regexp.escape(file)}:(\d+):/, 1]
      value&.to_i
    end

    def component_id(suite, identity)
      "#{suite}/#{Digest::SHA256.hexdigest(identity)[0, 24]}"
    end

    def build_delta(before, after)
      before_components = before.fetch("components", {})
      after_components = after.fetch("components")
      changed = after_components.filter_map do |id, component|
        component unless before_components[id] == component
      end
      removed = before_components.keys - after_components.keys
      delta = {
        "schema" => DELTA_SCHEMA,
        "repository" => @repository,
        "base" => @base && { "commit" => @parent_commit, "state_digest" => @base["state_digest"] },
        "head" => { "commit" => @commit, "state_digest" => after.fetch("state_digest") },
        "inventories" => after.fetch("inventories"),
        "tests" => after.fetch("tests"),
        "upsert_components" => changed.sort_by { |component| component.fetch("id") },
        "remove_components" => removed.sort,
        "complete" => true
      }
      delta["artifact_id"] = CanonicalJSON.digest(delta)
      delta
    end

    def member_metadata(path, uncompressed)
      bytes = File.binread(path)
      {
        "digest" => self.class.sha256(bytes),
        "bytes" => bytes.bytesize,
        "uncompressed_digest" => self.class.sha256(uncompressed),
        "uncompressed_bytes" => uncompressed.bytesize,
        "encoding" => path.end_with?(".zst") ? "zstd" : "identity"
      }
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
