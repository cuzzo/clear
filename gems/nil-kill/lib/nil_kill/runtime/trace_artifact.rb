# frozen_string_literal: true

module NilKill
  module Runtime
    # The single, language-neutral artifact a trace run produces.
    #
    # Everything in here is an observation: what ran, what values were seen, and
    # where. Nothing in here is a decision about which planned anchor an
    # observation satisfies -- that join is the consumer's, and doing it in two
    # places is how the two implementations drift apart. The shapes are exactly
    # the ones the join already consumes, so a consumer needs no per-language
    # decoding of its own.
    module TraceArtifact
      VERSION = 1
      DEFAULT_NAME = "runtime-trace.json.gz"

      # `observations` and `calls` are already normalized by the language
      # provider; the remaining tables are the raw execution tallies the join
      # uses to tell "not executed" from "executed but not captured".
      def self.build(root:, runtime_dir:, plan:, languages:, run_ids:)
        languages = Array(languages).compact.uniq.sort
        emitter = ScipEmitter.new(root: root, runtime_dir: runtime_dir)
        events, invalid_events = emitter.send(:load_events)
        calls = events.map do |event|
          {
            "event" => event,
            "row" => Languages.provider_for(event.fetch("language"))
              .runtime_scip_call_evidence(event: event, root: root),
          }
        end
        observations = languages.flat_map do |language|
          Languages.provider_for(language).runtime_value_observations(
            runtime_dir: runtime_dir, root: root
          )
        end
        {
          "trace_version" => VERSION,
          "producer" => {
            "name" => EvidenceProtocol::PRODUCER,
            "version" => EvidenceProtocol::PRODUCER_VERSION,
          },
          "trace_plan_digest" => plan.fetch("plan_digest"),
          "languages" => languages,
          "run_ids" => Array(run_ids).map(&:to_s).reject(&:empty?).uniq.sort,
          "invalid_events" => invalid_events,
          "observations" => observations,
          "calls" => calls,
          "executed_callsites" => jsonl(runtime_dir, "executed-callsites-*.jsonl"),
          "exact_anchor_executions" => jsonl(runtime_dir, "exact-anchor-executions-*.jsonl"),
          "function_entries" => jsonl(runtime_dir, "function-entries-*.jsonl"),
          "coverage" => jsonl(runtime_dir, "coverage-*.jsonl"),
        }
      end

      def self.jsonl(runtime_dir, pattern)
        JsonIO.matching(runtime_dir, pattern).flat_map do |file|
          rows = []
          JsonIO.foreach(file) do |line|
            row = JSON.parse(line) rescue next
            rows << row
          end
          rows
        end
      end

      def self.write(root:, runtime_dir:, plan:, languages:, run_ids:, output: nil)
        path = File.expand_path(output || File.join(runtime_dir, DEFAULT_NAME))
        FileUtils.mkdir_p(File.dirname(path))
        JsonIO.write(
          path,
          JSON.generate(
            build(
              root: root, runtime_dir: runtime_dir, plan: plan,
              languages: languages, run_ids: run_ids
            )
          )
        )
        path
      end
    end
  end
end
