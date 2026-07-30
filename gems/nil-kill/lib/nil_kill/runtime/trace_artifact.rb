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
          provider = Languages.provider_for(event.fetch("language"))
          row = provider.runtime_scip_call_evidence(event: event, root: root)
          { "row" => row, "bucket" => call_bucket(row, event, provider) }.compact
        end
        observations = languages.flat_map do |language|
          provider = Languages.provider_for(language)
          provider.runtime_value_observations(runtime_dir: runtime_dir, root: root)
            .map { |row| row.merge("bucket" => value_bucket(row, provider)).compact }
        end
        {
          "trace_version" => VERSION,
          "producer" => {
            "name" => EvidenceProtocol::PRODUCER,
            "version" => EvidenceProtocol::PRODUCER_VERSION,
          },
          "trace_plan_digest" => plan.fetch("plan_digest"),
          "languages" => languages,
          # Environment claims are the collector's own facts about the runtime
          # it observed, so they travel with the observations.
          "environment" => languages.flat_map { |language|
            Languages.provider_for(language).runtime_scip_environment(root: root).to_a
          }.uniq.sort.map { |key, value| { "key" => key.to_s, "value" => value.to_s } },
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

      # Minting a protocol value from an observed one needs the language's own
      # type-symbol rules, which only the collector has. The join does not, so
      # the values travel already encoded and the consumer only has to decide
      # which anchor each belongs to.
      def self.value_bucket(row, provider)
        values = EvidenceProtocol.value_set(
          row.fetch("domain"), count: row.fetch("count", 1),
          provider: provider, source_role: "UNKNOWN_SOURCE"
        )
        return nil unless values

        {
          "count" => [row.fetch("count", 1).to_i, 1].max,
          "value" => values,
          "provenance" => provider.runtime_evidence_provenance.merge("run_id" => ""),
        }
      end

      def self.call_bucket(row, event, provider)
        receiver = EvidenceProtocol.value_set(
          row["receiver_domain"], count: row.fetch("count", 1),
          provider: provider,
          source_role: row.fetch("receiver_source_role", "UNKNOWN_SOURCE")
        )
        return nil unless receiver

        bucket = {
          "count" => [row.fetch("count", 1).to_i, 1].max,
          "receiver" => receiver,
          "target" => EvidenceProtocol.target(row),
          # The declaration the collector observed. Which planned function it
          # corresponds to is a question about the plan, so the locator travels
          # raw and the consumer resolves it.
          "target_definition" => row.dig("target", "definition"),
          "provenance" => provider.runtime_evidence_provenance.merge(
            "run_id" => event["run_id"].to_s
          ),
        }
        result = EvidenceProtocol.value_set(
          row["result_domain"], count: row.fetch("count", 1),
          provider: provider, source_role: "UNKNOWN_SOURCE"
        )
        bucket["result"] = result if result
        truths = Array(row["result_truths"]).uniq
        bucket["boolean_result"] = truths.first if truths.length == 1
        bucket
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
