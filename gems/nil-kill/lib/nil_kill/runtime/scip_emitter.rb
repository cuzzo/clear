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
        value_evidence_path: nil,
        plan: nil
      )
        new(
          root: root,
          runtime_dir: runtime_dir,
          output: output,
          attestation: attestation,
          environment: environment,
          files: files,
          value_evidence_path: value_evidence_path,
          plan: plan
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
        value_evidence_path: nil,
        plan: nil
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
        @runtime_plan = plan
      end

      def emit
        events, invalid_events = load_events
        semantic_events = events
        excluded_events = 0
        parsed_evidence = nil
        value_evidence =
          if @value_evidence_path
            parsed_evidence = JsonIO.parse(@value_evidence_path)
            anchors = parsed_evidence.fetch("anchors", [])
            {
              "path" => @value_evidence_path,
              "observations" => anchors.count {
                |row| row.fetch("executions", []).any? { |bucket| bucket["value"] }
              },
              "calls" => anchors.count {
                |row| row.fetch("executions", []).any? { |bucket| bucket["target"] }
              },
            }
          else
            ValueEvidenceEmitter.emit(
              root: @root,
              runtime_dir: @runtime_dir,
              events: semantic_events,
              plan: runtime_plan
            )
          end
        parsed_evidence ||= JsonIO.parse(value_evidence.fetch("path"))
        evidence_runs = parsed_evidence.fetch("runs", []).map { |run| run.fetch("id") }
        evidence_environment = parsed_evidence.fetch("environment", []).to_h do |claim|
          [claim.fetch("key"), claim.fetch("value")]
        end
        sources = runtime_sources(semantic_events, parsed_evidence)
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
        write_atomically(@output, JSON.generate(index) + "\n")
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
        result = ValueEvidenceEmitter.emit(
          root: @root,
          runtime_dir: @runtime_dir,
          events: events,
          output: output,
          languages: languages,
          run_ids: run_ids,
          plan: runtime_plan
        )
        result.merge(
          "events" => events.length,
          "invalid_events" => invalid_events,
          "excluded_events" => 0
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
            "schema" => "factmine.runtime.v1",
            "observedCallSites" => 0,
            "inferredCallSites" => 0,
            "typedReceivers" => 0,
            "emittedOccurrences" => 0,
          },
        }
      end

      def runtime_sources(events, evidence)
        sources = Array(@files).map { |path| File.expand_path(path, @root) }
        if sources.empty?
          sources.concat(events.filter_map { |event| event.dig("callsite", "path") })
          sources.concat(runtime_plan.fetch("documents", []).map do |document|
            File.expand_path(document.fetch("relative_path"), @root)
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
        sources.concat(evidence_workspace_sources(evidence))
        languages = (
          events.map { |event| event.fetch("language") } +
          runtime_plan.fetch("documents", []).map { |row| row["language"] }
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

      # Takes the already-parsed document. It used to re-read and re-parse the
      # evidence from disk, which was the third full parse of the same file in
      # one emit.
      def evidence_workspace_sources(evidence)
        return [] unless evidence

        evidence.fetch("anchors", []).flat_map do |anchor|
          anchor.fetch("executions", []).filter_map do |bucket|
            target = bucket["target"]
            next unless target &&
              target["source_role"] == "PRODUCTION" &&
              target["package_manager"] == "workspace"

            relative = target.dig("definition", "relative_path").to_s
            next if relative.empty?

            absolute = File.expand_path(relative, @root)
            next unless absolute.start_with?("#{@root}#{File::SEPARATOR}")
            next unless File.file?(absolute)

            absolute
          end
        end
      end

      def emit_with_fact_mine(evidence_path, sources)
        binary = fact_mine_binary
        evidence_digest = JsonIO.parse(evidence_path).fetch("trace_plan_digest")
        plan_digest = runtime_plan.fetch("plan_digest")
        unless evidence_digest == plan_digest
          raise "runtime evidence was collected for trace plan #{evidence_digest.inspect}, " \
            "but the current plan is #{plan_digest.inspect}"
        end
        Tempfile.create(["fact-mine-runtime-plan", ".json"]) do |plan|
          plan.write(JSON.generate(runtime_plan))
          plan.flush
          command = [
            binary,
            "runtime-scip",
            "--root", @root,
            "--trace-plan", plan.path,
            "--runtime-evidence", evidence_path,
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

      def fact_mine_binary
        Espalier::StaticEvidence::FACT_MINE_RUST_BINARY
      end

      def runtime_plan
        @runtime_plan ||= if File.file?(NilKill::TRACE_PLAN_PATH)
                            EvidenceProtocol.plan
                          else
                            generated =
                              StaticEvidence.build_runtime_evidence_plan(@files, root: @root)
                            raise ArgumentError, "no source files for a runtime evidence plan" unless generated

                            generated
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
