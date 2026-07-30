# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Projects raw provider observations onto the exact anchors requested by
    # FactMine. It performs no source parsing, dispatch inference, or flow
    # analysis. Every requested anchor receives an explicit capture status.
    class ValueEvidenceEmitter
      DEFAULT_OUTPUT = "runtime-evidence.v1.json.gz"

      def self.emit(root:, runtime_dir:, events:, output: nil, languages: nil, run_ids: nil, plan: nil)
        new(root: root, runtime_dir: runtime_dir, output: output, plan: plan)
          .emit(events, languages: languages, run_ids: run_ids)
      end

      def initialize(root:, runtime_dir:, output: nil, plan: nil)
        @root = File.expand_path(root)
        @runtime_dir = File.expand_path(runtime_dir)
        @output = File.expand_path(output || File.join(@runtime_dir, DEFAULT_OUTPUT))
        @plan = EvidenceProtocol.validate_plan!(plan || EvidenceProtocol.plan)
        @executed_callsites = load_rows("executed-callsites-*.jsonl")
        @function_entries = load_rows("function-entries-*.jsonl")
      end

      def emit(events, languages: nil, run_ids: nil)
        languages = (events.map { |event| event.fetch("language") } + Array(languages))
          .compact.uniq.sort
        observations = languages.flat_map do |language|
          Languages.provider_for(language).runtime_value_observations(
            runtime_dir: @runtime_dir,
            root: @root
          )
        end
        decoded_calls = events.map do |event|
          [
            event,
            Languages.provider_for(event.fetch("language"))
              .runtime_scip_call_evidence(event: event, root: @root),
          ]
        end
        build_lookup_indices(observations, decoded_calls)
        ids = (
          Array(run_ids).map(&:to_s) +
          events.map { |event| event["run_id"].to_s }
        ).reject(&:empty?).uniq.sort
        ids = ["unidentified-run"] if ids.empty?
        anchors = @plan.fetch("requests").map do |request|
          anchor_evidence(request, ids)
        end
        evidence = {
          "protocol_version" => EvidenceProtocol::VERSION,
          "producer" => {
            "name" => EvidenceProtocol::PRODUCER,
            "version" => EvidenceProtocol::PRODUCER_VERSION,
            "arguments" => ["collect", "runtime-evidence"],
          },
          "authority" => EvidenceProtocol::AUTHORITY,
          "trace_plan_digest" => @plan.fetch("plan_digest"),
          "environment" => environment(languages),
          "runs" => ids.map do |id|
            { "id" => id, "status" => "SUCCEEDED" }
          end,
          "anchors" => anchors,
        }
        FileUtils.mkdir_p(File.dirname(@output))
        JsonIO.write(@output, EvidenceProtocol.encode_evidence(evidence))
        {
          "path" => @output,
          "anchors" => anchors.length,
          "complete_anchors" => anchors.count {
            |row| row.dig("capture", "status") == "COMPLETE_FOR_RUNS"
          },
          "calls" => anchors.count { |row| row["executions"].any? { |bucket| bucket["target"] } },
          "observations" => anchors.count { |row| row["executions"].any? { |bucket| bucket["value"] } },
        }
      end

      private

      def anchor_evidence(request, run_ids)
        anchor = request.fetch("anchor")
        matches, ambiguity =
          case anchor.fetch("kind")
          when "FUNCTION_ENTRY"
            matching_observations(anchor, "parameter")
          when "FUNCTION_RETURN"
            matching_observations(anchor, "return")
          when "STATE_READ", "STATE_WRITE"
            matching_observations(anchor, "state")
          else
            matching_calls(anchor)
          end
        executions = matches.filter_map do |match|
          call_anchor?(anchor) ? call_bucket(match, run_ids.first) : value_bucket(match, run_ids.first)
        end
        executions = merge_identical_buckets(executions)
        requested = request.fetch("required")
        executed_without_capture = executions.empty? && anchor_executed?(anchor)
        complete_kinds =
          if ambiguity || executed_without_capture
            []
          elsif executions.empty?
            # No execution in a modeled run is a complete (empty) observation
            # for every requested field.
            requested
          else
            requested.select do |kind|
              field = evidence_field(kind)
              executions.all? { |bucket| bucket.key?(field) }
            end
          end
        status, reason =
          if ambiguity
            ["PARTIAL", "provider cannot uniquely correlate this source event to one exact anchor"]
          elsif executions.empty?
            if executed_without_capture
              ["NOT_INSTRUMENTED", "anchor executed but the provider did not capture its requested value"]
            else
              ["NOT_EXECUTED", "no matching execution in the modeled runs"]
            end
          elsif complete_kinds.sort != requested.sort
            ["PARTIAL", "provider did not capture every value requested at this anchor"]
          else
            ["COMPLETE_FOR_RUNS", nil]
          end
        observed = executions.sum { |bucket| bucket.fetch("count").to_i }
        {
          "anchor_symbol" => anchor.fetch("symbol"),
          "anchor_semantic_digest" => anchor.fetch("semantic_digest"),
          "capture" => {
            "status" => status,
            "run_ids" => run_ids,
            "observed_executions" => observed,
            "dropped_executions" => 0,
            "reason" => reason,
            "complete_kinds" => complete_kinds,
          }.compact,
          "executions" => executions,
        }
      end

      def matching_observations(anchor, kind)
        candidates = @observations_by_kind_path.fetch(
          [kind, anchor.fetch("relative_path")],
          []
        ).select { |row| source_line_matches?(anchor, row.dig("scope", "line")) }
        candidates.select! { |row| row["slot"].to_s == anchor["display_name"].to_s } if
          %w[parameter state].include?(kind)
        # A path/range/slot identifies one normalized storage boundary. More
        # than one provider row at that boundary represents additive runs, not
        # ambiguous source identity.
        [candidates, false]
      end

      def matching_calls(anchor)
        key = [anchor.fetch("relative_path"), anchor.fetch("display_name").to_s]
        candidates = @calls_by_path_selector.fetch(key, []).select do |_event, row|
          source_line_matches?(anchor, row.dig("callsite", "line"))
        end
        siblings = @call_anchor_counts.fetch(
          [*key, anchor.fetch("range").fetch("start_line")],
          0
        )
        # A provider may expose only line + selector rather than an exact
        # column. Never guess between two identical selectors on one line.
        [candidates, candidates.any? && siblings > 1]
      end

      def value_bucket(row, run_id)
        provider = Languages.provider_for(row.dig("scope", "language"))
        values = EvidenceProtocol.value_set(
          row.fetch("domain"),
          count: row.fetch("count", 1),
          provider: provider,
          source_role: "UNKNOWN_SOURCE"
        )
        return unless values

        {
          "count" => [row.fetch("count", 1).to_i, 1].max,
          "value" => values,
          "provenance" => provenance(run_id, provider),
        }
      end

      def call_bucket(pair, default_run_id)
        event, row = pair
        provider = Languages.provider_for(event.fetch("language"))
        receiver = EvidenceProtocol.value_set(
          row["receiver_domain"],
          count: row.fetch("count", 1),
          provider: provider,
          source_role: row.fetch("receiver_source_role", "UNKNOWN_SOURCE")
        )
        return unless receiver

        bucket = {
          "count" => [row.fetch("count", 1).to_i, 1].max,
          "receiver" => receiver,
          "target" => target_payload(row),
          "provenance" => provenance(
            event["run_id"].to_s.empty? ? default_run_id : event["run_id"],
            provider
          ),
        }
        result = EvidenceProtocol.value_set(
          row["result_domain"],
          count: row.fetch("count", 1),
          provider: provider,
          source_role: "UNKNOWN_SOURCE"
        )
        bucket["result"] = result if result
        truths = Array(row["result_truths"]).uniq
        bucket["boolean_result"] = truths.first if truths.one?
        bucket
      end

      def target_payload(row)
        target = EvidenceProtocol.target(row)
        definition = row.dig("target", "definition")
        return target unless definition

        candidates = @plan.fetch("requests").filter_map do |request|
          anchor = request.fetch("anchor")
          next unless %w[FUNCTION_ENTRY FUNCTION_RETURN].include?(anchor.fetch("kind"))
          next unless canonical_path(definition.fetch("path")) == anchor.fetch("relative_path")
          next unless source_line_matches?(anchor, definition.fetch("line"))

          anchor
        end.uniq { |anchor| anchor.fetch("enclosing_symbol") }
        unless candidates.one?
          line = definition.fetch("line").to_i
          path = canonical_path(definition.fetch("path"))
          return target if line <= 0 || path.empty?

          # The provider has already observed the exact declaration path and
          # line. Preserve that locator even when the declaration is outside
          # the trace plan; FactMine will parse and bind it. NilKill neither
          # opens the source nor guesses a callable identity here.
          return target.merge(
            "definition" => {
              "symbol" => target.fetch("symbol"),
              "anchor_symbol" => "",
              "relative_path" => path,
              "range" => {
                "start_line" => line - 1,
                "start_character" => 0,
                "end_line" => line - 1,
                "end_character" => 0,
              },
            }
          )
        end

        anchor = candidates.first
        target.merge(
          "symbol" => anchor.fetch("enclosing_symbol"),
          "definition" => {
            "symbol" => anchor.fetch("enclosing_symbol"),
            "anchor_symbol" => anchor.fetch("symbol"),
            "relative_path" => anchor.fetch("relative_path"),
            "range" => anchor.fetch("range"),
          }
        )
      end

      def provenance(run_id, provider)
        provider.runtime_evidence_provenance.merge(
          "run_id" => run_id.to_s.empty? ? "unidentified-run" : run_id.to_s
        )
      end

      def merge_identical_buckets(buckets)
        buckets.group_by { |bucket| JSON.generate(bucket.reject { |key, _| key == "count" }) }
          .values.map do |rows|
            rows.first.merge("count" => rows.sum { |row| row.fetch("count").to_i })
          end
      end

      def evidence_field(kind)
        {
          "PARAMETER_VALUE" => "value",
          "RETURN_VALUE" => "value",
          "STATE_VALUE" => "value",
          "RECEIVER_VALUE" => "receiver",
          "CALL_TARGET" => "target",
          "RESULT_VALUE" => "result",
          "COLLECTION_VALUE" => "receiver",
          "BOOLEAN_RESULT" => "boolean_result",
        }.fetch(kind)
      end

      def anchor_executed?(anchor)
        if call_anchor?(anchor)
          @executed_callsites_by_path_selector.fetch(
            [anchor.fetch("relative_path"), anchor.fetch("display_name").to_s],
            []
          ).any? { |line| source_line_matches?(anchor, line) }
        else
          @function_entries_by_path.fetch(anchor.fetch("relative_path"), [])
            .any? { |line| source_line_matches?(anchor, line) }
        end
      end

      def build_lookup_indices(observations, decoded_calls)
        @observations_by_kind_path = observations.group_by do |row|
          [row.fetch("kind"), canonical_path(row.dig("scope", "path"))]
        end
        @calls_by_path_selector = decoded_calls.group_by do |_event, row|
          callsite = row.fetch("callsite")
          [canonical_path(callsite.fetch("path")), callsite.fetch("selector").to_s]
        end
        @executed_callsites_by_path_selector =
          @executed_callsites.group_by do |row|
            [canonical_path(row.fetch("path")), row.fetch("selector", "").to_s]
          end.transform_values { |rows| rows.map { |row| row.fetch("line") } }
        @function_entries_by_path =
          @function_entries.group_by { |row| canonical_path(row.fetch("path")) }
            .transform_values { |rows| rows.map { |row| row.fetch("line") } }
        @call_anchor_counts = Hash.new(0)
        @plan.fetch("requests").each do |request|
          anchor = request.fetch("anchor")
          next unless call_anchor?(anchor)

          range = anchor.fetch("range")
          (range.fetch("start_line")..range.fetch("end_line")).each do |line|
            @call_anchor_counts[
              [
                anchor.fetch("relative_path"),
                anchor.fetch("display_name").to_s,
                line,
              ]
            ] += 1
          end
        end
      end

      def load_rows(glob)
        JsonIO.matching(@runtime_dir, glob).flat_map do |path|
          rows = []
          JsonIO.foreach(path) do |line|
            rows << JSON.parse(line)
          rescue JSON::ParserError
            next
          end
          rows
        end
      end

      def environment(languages)
        claims = {}
        languages.each do |language|
          Languages.provider_for(language).runtime_scip_environment(root: @root).each do |key, value|
            key = key.to_s
            value = value.to_s
            if claims.key?(key) && claims.fetch(key) != value
              raise ArgumentError, "runtime environment claim #{key} conflicts across providers"
            end
            claims[key] = value
          end
        end
        claims.sort.map { |key, value| { "key" => key, "value" => value } }
      end

      def call_anchor?(anchor)
        !%w[FUNCTION_ENTRY FUNCTION_RETURN STATE_READ STATE_WRITE].include?(anchor.fetch("kind"))
      end

      def source_line_matches?(anchor, one_based_line)
        line = one_based_line.to_i - 1
        range = anchor.fetch("range")
        range.fetch("start_line") <= line && line <= range.fetch("end_line")
      end

      def canonical_path(path)
        return "" if path.to_s.empty?

        absolute = File.expand_path(path, @root)
        Pathname.new(absolute).relative_path_from(Pathname.new(@root)).to_s.tr("\\", "/")
      rescue ArgumentError
        path.to_s.tr("\\", "/")
      end
    end
  end
end
