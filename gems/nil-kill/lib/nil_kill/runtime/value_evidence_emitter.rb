# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Serializes tracer observations into FactMine's language-neutral runtime
    # evidence contract. It intentionally performs no source parsing or flow
    # inference.
    class ValueEvidenceEmitter
      SCHEMA = "fact-mine.runtime-value-evidence.v1"
      DEFAULT_OUTPUT = "runtime-values.json.gz"

      def self.emit(root:, runtime_dir:, events:, output: nil)
        new(root: root, runtime_dir: runtime_dir, output: output).emit(events)
      end

      def initialize(root:, runtime_dir:, output: nil)
        @root = File.expand_path(root)
        @runtime_dir = File.expand_path(runtime_dir)
        @output = File.expand_path(output || File.join(@runtime_dir, DEFAULT_OUTPUT))
      end

      def emit(events)
        semantic_events = events.select do |event|
          Languages.provider_for(event.fetch("language"))
            .runtime_scip_event_eligible?(event: event, root: @root)
        end
        languages = semantic_events.map { |event| event.fetch("language") }.uniq.sort
        observations = languages.flat_map do |language|
          Languages.provider_for(language).runtime_value_observations(
            runtime_dir: @runtime_dir,
            root: @root
          )
        end
        calls = observed_calls(semantic_events)
        environment = languages.each_with_object({}) do |language, claims|
          Languages.provider_for(language).runtime_scip_environment(root: @root).each do |key, value|
            key = key.to_s
            value = value.to_s
            if claims.key?(key) && claims.fetch(key) != value
              raise ArgumentError,
                "runtime evidence environment claim #{key} conflicts across traced languages"
            end
            claims[key] = value
          end
        end
        evidence = {
          "schema" => SCHEMA,
          "authority" => ScipEmitter::AUTHORITY,
          "environment" => environment.sort.to_h,
          "runs" => semantic_events.map { |event| event["run_id"].to_s }
            .reject(&:empty?).uniq.sort,
          "observations" => observations,
          "calls" => calls,
        }
        FileUtils.mkdir_p(File.dirname(@output))
        write_atomically(@output, JSON.pretty_generate(evidence) + "\n")
        {
          "path" => @output,
          "observations" => observations.length,
          "calls" => calls.length,
        }
      end

      private

      def observed_calls(events)
        decoded = events.map do |event|
          Languages.provider_for(event.fetch("language"))
            .runtime_scip_call_evidence(event: event, root: @root)
        end
        decoded.group_by do |row|
          caller = row.fetch("caller")
          callsite = row.fetch("callsite")
          [
            row.fetch("language"),
            caller["owner"], caller["name"], caller["kind"],
            caller["path"], caller["line"],
            callsite["path"], callsite["line"], callsite["range"],
            callsite["selector"],
            JSON.generate(row["receiver_domain"] || {}),
            Array(row["result_truths"]).sort_by { |truth| truth ? 1 : 0 },
          ]
        end.map do |_key, rows|
          first = rows.first
          caller = first.fetch("caller")
          callsite = first.fetch("callsite")
          targets = rows.map { |row| row.fetch("target") }.uniq.sort_by do |target|
            target.fetch("symbol")
          end
          {
            "language" => first.fetch("language"),
            "caller" => caller,
            "callsite" => callsite,
            "targets" => targets,
            "receiver_domain" => merged_call_domain(rows, "receiver_domain"),
            "result_domain" => merged_call_domain(rows, "result_domain"),
            "result_truths" => rows.flat_map { |row| Array(row["result_truths"]) }
              .uniq.sort_by { |truth| truth ? 1 : 0 },
            "count" => rows.sum { |event| event["count"].to_i },
          }.compact
        end.sort_by do |call|
          site = call.fetch("callsite")
          caller = call.fetch("caller")
          [call["language"], site["path"], site["line"], caller["name"], site["selector"]]
        end
      end

      def merged_call_domain(rows, field)
        domains = rows.filter_map { |row| row[field] }
        return if domains.empty?

        %w[types elements keys values shapes].to_h do |part|
          [part, domains.flat_map { |domain| Array(domain[part]) }.uniq.sort_by(&:to_s)]
        end
      end

      def write_atomically(path, contents)
        JsonIO.write(path, contents)
      end
    end
  end
end
