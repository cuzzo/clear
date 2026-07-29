# typed: false
# frozen_string_literal: true

require "open3"
require "tempfile"

module NilKill
  module Runtime
    # Orchestrates the evidence-only NilKill -> FactMine boundary. NilKill
    # serializes observations; FactMine owns source analysis and SCIP output.
    class ScipEmitter
      SCHEMA_VERSION = 1
      TOOL_NAME = "nil-kill-runtime"
      TOOL_VERSION = "2"
      AUTHORITY = "runtime-modeled-world"
      AUTHORITY_ARGUMENT = "--fact-mine-index-authority=#{AUTHORITY}"
      EVENT_GLOB = "runtime-calls-*.jsonl"

      def self.emit(
        root:,
        runtime_dir:,
        output: nil,
        attestation: nil,
        environment: {},
        files: nil,
        value_evidence_path: nil
      )
        new(
          root: root,
          runtime_dir: runtime_dir,
          output: output,
          attestation: attestation,
          environment: environment,
          files: files,
          value_evidence_path: value_evidence_path
        ).emit
      end

      # Produce only the language-neutral value-evidence bundle. Incremental
      # collection uses this to merge a delta into the canonical snapshot
      # before running FactMine once over the merged evidence.
      def self.emit_value_evidence(root:, runtime_dir:, output: nil, languages: nil, run_ids: nil)
        new(root: root, runtime_dir: runtime_dir)
          .emit_value_evidence(output: output, languages: languages, run_ids: run_ids)
      end

      def initialize(
        root:,
        runtime_dir:,
        output: nil,
        attestation: nil,
        environment: {},
        files: nil,
        value_evidence_path: nil
      )
        @root = File.expand_path(root)
        @runtime_dir = File.expand_path(runtime_dir)
        @output = File.expand_path(output || File.join(@runtime_dir, "runtime.scip.json"))
        @attestation = File.expand_path(
          attestation || File.join(@runtime_dir, "runtime-attestation.json.gz")
        )
        @environment = environment.transform_keys(&:to_s).transform_values(&:to_s)
        @files = files
        @value_evidence_path = value_evidence_path && File.expand_path(value_evidence_path)
      end

      def emit
        events, invalid_events = load_events
        semantic_events = events.select do |event|
          Languages.provider_for(event.fetch("language"))
            .runtime_scip_event_eligible?(event: event, root: @root)
        end
        excluded_events = events.length - semantic_events.length
        value_evidence =
          if @value_evidence_path
            parsed = JsonIO.parse(@value_evidence_path)
            {
              "path" => @value_evidence_path,
              "observations" => parsed.fetch("observations", []).length,
              "calls" => parsed.fetch("calls", []).length,
            }
          else
            ValueEvidenceEmitter.emit(
              root: @root,
              runtime_dir: @runtime_dir,
              events: semantic_events
            )
          end
        parsed_evidence = JsonIO.parse(value_evidence.fetch("path"))
        evidence_runs = parsed_evidence.fetch("runs", [])
        evidence_environment = parsed_evidence.fetch("environment", {})
        sources = runtime_sources(semantic_events, value_evidence.fetch("path"))
        index =
          if sources.empty?
            empty_index
          else
            emit_with_fact_mine(value_evidence.fetch("path"), sources)
          end
        documents = index.fetch("documents", [])
        inference = index.fetch("_runtimeEvidence", {})
        inferred_events = inference.fetch("inferredCallSites", 0).to_i

        FileUtils.mkdir_p(File.dirname(@output))
        write_atomically(@output, JSON.pretty_generate(index) + "\n")
        write_atomically(
          @attestation,
          JSON.pretty_generate(
            attestation_payload(
              events,
              documents,
              invalid_events,
              inferred_events,
              excluded_events,
              evidence_runs,
              evidence_environment
            )
          ) + "\n"
        )
        {
          "index" => @output,
          "attestation" => @attestation,
          "events" => events.length,
          "inferred_events" => inferred_events,
          "documents" => documents.length,
          "occurrences" => documents.sum { |document| document.fetch("occurrences").length },
          "invalid_events" => invalid_events,
          "excluded_events" => excluded_events,
          "runtime_evidence" => value_evidence.fetch("path"),
          "runtime_value_observations" => value_evidence.fetch("observations"),
        }
      end

      def emit_value_evidence(output: nil, languages: nil, run_ids: nil)
        events, invalid_events = load_events
        semantic_events = events.select do |event|
          Languages.provider_for(event.fetch("language"))
            .runtime_scip_event_eligible?(event: event, root: @root)
        end
        result = ValueEvidenceEmitter.emit(
          root: @root,
          runtime_dir: @runtime_dir,
          events: semantic_events,
          output: output,
          languages: languages,
          run_ids: run_ids
        )
        result.merge(
          "events" => events.length,
          "invalid_events" => invalid_events,
          "excluded_events" => events.length - semantic_events.length
        )
      end

      private

      def empty_index
        {
          "metadata" => {
            "version" => 0,
            "toolInfo" => {
              "name" => TOOL_NAME,
              "version" => "2",
              "arguments" => [AUTHORITY_ARGUMENT],
            },
            "projectRoot" => project_root_uri,
            "textDocumentEncoding" => 1,
          },
          "documents" => [],
          "externalSymbols" => [],
          "_runtimeEvidence" => {
            "schema" => ValueEvidenceEmitter::SCHEMA,
            "observedCallSites" => 0,
            "inferredCallSites" => 0,
            "typedReceivers" => 0,
            "emittedOccurrences" => 0,
          },
        }
      end

      def runtime_sources(events, evidence_path)
        evidence = JsonIO.parse(evidence_path)
        sources = Array(@files).map { |path| File.expand_path(path, @root) }
        if sources.empty?
          sources.concat(events.filter_map { |event| event.dig("callsite", "path") })
          sources.concat(evidence.fetch("observations", []).filter_map do |observation|
            path = observation.dig("scope", "path").to_s
            File.expand_path(path, @root) unless path.empty?
          end)
        end
        # A runtime call can cross from the selected product source into a
        # sibling workspace implementation (for example `tools/`). Its exact
        # declaration identity is already attested by the runtime event, but
        # FactMine cannot emit a definition occurrence or later export a
        # source summary unless that declaration file is part of this source
        # set. Include only workspace-owned files under this root: dependency
        # implementations remain external, and event eligibility has already
        # rejected test/mocking sources.
        sources.concat(events.filter_map { |event| workspace_callee_source(event) })
        languages = (
          events.map { |event| event.fetch("language") } +
          evidence.fetch("observations", []).map { |row| row.dig("scope", "language") }
        ).compact.uniq
        extensions = languages.flat_map do |language|
          Languages.provider_for(language).extensions
        end.to_set
        sources.compact.map { |path| File.expand_path(path, @root) }
          .select { |path| File.file?(path) }
          .select { |path| extensions.include?(File.extname(path)) }
          .uniq.sort
      end

      def workspace_callee_source(event)
        callee = event.fetch("callee", {})
        return unless callee["package_manager"].to_s == "workspace"

        path = callee["path"].to_s
        return if path.empty?

        absolute = File.expand_path(path, @root)
        return unless absolute.start_with?("#{@root}#{File::SEPARATOR}")
        return unless File.file?(absolute)

        absolute
      end

      def emit_with_fact_mine(evidence_path, sources)
        binary = fact_mine_binary
        with_plain_evidence(evidence_path) do |plain_evidence|
          command = [
            binary,
            "runtime-scip",
            "--runtime-evidence", plain_evidence,
            "--output", @output,
            *sources,
          ]
          stdout, stderr, status = Open3.capture3(*command, chdir: @root)
          unless status.success?
            raise "fact-mine runtime-scip failed with status #{status.exitstatus}: " \
              "#{stderr.strip}#{stdout.empty? ? "" : "\n#{stdout.strip}"}"
          end
        end
        JSON.parse(File.read(@output))
      end

      def with_plain_evidence(path)
        return yield path unless JsonIO.gzip?(path)

        Tempfile.create(["nil-kill-runtime-values", ".json"]) do |file|
          file.binmode
          file.write(JsonIO.read(path))
          file.flush
          yield file.path
        end
      end

      def fact_mine_binary
        return File.expand_path(ENV.fetch("FACT_MINE_RUST_BINARY")) if ENV["FACT_MINE_RUST_BINARY"]

        release = File.join(NilKill::ROOT, "gems", "fact-mine", "target", "release", "fact-mine-rust")
        debug = File.join(NilKill::ROOT, "gems", "fact-mine", "target", "debug", "fact-mine-rust")
        if File.executable?(debug) &&
            (!File.executable?(release) || File.mtime(debug) > File.mtime(release))
          debug
        else
          release
        end
      end

      def load_events
        events = []
        invalid = 0
        JsonIO.matching(@runtime_dir, EVENT_GLOB).each do |path|
          JsonIO.foreach(path) do |line|
            event = JSON.parse(line)
            unless valid_event?(event)
              invalid += 1
              next
            end
            events << event
          rescue JSON::ParserError
            invalid += 1
          end
        end
        [events, invalid]
      end

      def valid_event?(event)
        return false unless event.is_a?(Hash) && event["event"] == "runtime_call"
        return false if event["language"].to_s.empty?

        caller = event["caller"]
        callee = event["callee"]
        callsite = event["callsite"]
        caller.is_a?(Hash) && callee.is_a?(Hash) && callsite.is_a?(Hash) &&
          !caller["path"].to_s.empty? && !callee["name"].to_s.empty? &&
          !callsite["path"].to_s.empty? && callsite["line"].to_i.positive?
      end

      def project_root_uri
        encoded_path = URI::DEFAULT_PARSER.escape(@root)
        URI::Generic.build(scheme: "file", path: encoded_path).to_s
      end

      def attestation_payload(
        events,
        documents,
        invalid_events,
        inferred_events,
        excluded_events,
        evidence_runs,
        evidence_environment
      )
        claims = {
          "runtime_scip.authority" => AUTHORITY,
          "runtime_scip.closure_assumption" =>
            "observed call targets exhaust the attested workload and runtime environment",
          "runtime_scip.producer" => "#{TOOL_NAME}@#{TOOL_VERSION}",
          "runtime_scip.event_schema" => SCHEMA_VERSION.to_s,
          "runtime_scip.event_count" => events.length.to_s,
          "runtime_scip.document_count" => documents.length.to_s,
          "runtime_scip.invalid_event_count" => invalid_events.to_s,
          "runtime_scip.excluded_nonproduction_event_count" => excluded_events.to_s,
          "runtime_scip.inferred_event_count" => inferred_events.to_s,
          "runtime_scip.inference" =>
            "FactMine normalized CFG/DFG overlaid with observed runtime value domains",
          "runtime_scip.run_ids_sha256" => digest(
            Array(evidence_runs).map(&:to_s).reject(&:empty?).uniq.sort.join("\n")
          ),
        }.merge(evidence_environment).merge(observed_environment(events)).merge(@environment)
        {
          "schema" => "fact-mine.semantic-environment.v1",
          "claims" => claims.sort.to_h,
        }
      end

      def observed_environment(events)
        events.map { |event| event["language"].to_s }
          .reject(&:empty?)
          .uniq
          .sort
          .each_with_object({}) do |language, claims|
            provider_claims = Languages.provider_for(language)
              .runtime_scip_environment(root: @root)
            provider_claims.each do |key, value|
              key = key.to_s
              value = value.to_s
              if claims.key?(key) && claims.fetch(key) != value
                raise ArgumentError,
                  "runtime SCIP environment claim #{key} conflicts across traced languages"
              end
              claims[key] = value
            end
          end
      end

      def digest(value)
        "sha256:#{Digest::SHA256.hexdigest(value)}"
      end

      def write_atomically(path, contents)
        JsonIO.write(path, contents)
      end
    end
  end
end
