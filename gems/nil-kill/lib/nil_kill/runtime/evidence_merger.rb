# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Rebuilds one canonical evidence snapshot from replaceable per-test shard
    # bundles. Anchor ownership and per-run provenance make subtraction exact:
    # a changed/deleted shard is replaced, never heuristically subtracted from
    # a flattened type/call union.
    module EvidenceMerger
      module_function

      def merge(paths, plan: nil)
        bundles = Array(paths).select { |path| File.file?(path) }.map do |path|
          EvidenceProtocol.validate_evidence!(JsonIO.parse(path))
        end
        return empty_evidence if bundles.empty?

        plan = EvidenceProtocol.validate_plan!(plan) if plan
        bundles = bundles.map { |bundle| rebase(bundle, plan) } if plan
        plan_digest = unique!(bundles.map { |bundle| bundle.fetch("trace_plan_digest") }, "trace plan")
        version = unique!(bundles.map { |bundle| bundle.fetch("protocol_version") }, "protocol version")
        authority = unique!(bundles.map { |bundle| bundle.fetch("authority") }, "authority")
        {
          "protocol_version" => version,
          "producer" => {
            "name" => EvidenceProtocol::PRODUCER,
            "version" => EvidenceProtocol::PRODUCER_VERSION,
            "arguments" => ["collect", "runtime-evidence", "merge"],
          },
          "authority" => authority,
          "trace_plan_digest" => plan_digest,
          "environment" => merge_environment(bundles),
          "runs" => merge_runs(bundles),
          "anchors" => merge_anchors(bundles),
          "correlations" => merge_correlations(bundles),
        }
      end

      def write(paths, output, plan: nil)
        JsonIO.write(output, EvidenceProtocol.encode_evidence(merge(paths, plan: plan)))
        output
      end

      def empty_evidence
        plan = EvidenceProtocol.plan
        {
          "protocol_version" => EvidenceProtocol::VERSION,
          "producer" => {
            "name" => EvidenceProtocol::PRODUCER,
            "version" => EvidenceProtocol::PRODUCER_VERSION,
          },
          "authority" => EvidenceProtocol::AUTHORITY,
          "trace_plan_digest" => plan.fetch("plan_digest"),
          "environment" => [],
          "runs" => [],
          "anchors" => [],
          "correlations" => [],
        }
      end

      def merge_environment(bundles)
        claims = {}
        bundles.flat_map { |bundle| bundle.fetch("environment", []) }.each do |claim|
          key = claim.fetch("key")
          value = claim.fetch("value")
          raise ArgumentError, "conflicting runtime environment claim #{key}" if
            claims.key?(key) && claims.fetch(key) != value
          claims[key] = value
        end
        claims.sort.map { |key, value| { "key" => key, "value" => value } }
      end

      def rebase(bundle, plan)
        old = bundle.fetch("anchors").to_h { |row| [row.fetch("anchor_symbol"), row] }
        requests = plan.fetch("requests").to_h do |request|
          [request.dig("anchor", "symbol"), request]
        end
        run_ids = bundle.fetch("runs").map { |run| run.fetch("id") }
        # An anchor this shard has no entry for was not executed in it, which is
        # what absence already means. Rehydrating one for every planned anchor
        # made each shard's contribution scale with the plan rather than with
        # the run -- 13 shards of a 0.65s suite merged to 46MB, nearly all of it
        # saying nothing happened. STALE stays for the case it was written for:
        # an entry that IS present but describes different source.
        anchors = plan.fetch("requests").filter_map do |request|
          anchor = request.fetch("anchor")
          row = old[anchor.fetch("symbol")]
          if row.nil?
            nil
          elsif row.fetch("anchor_semantic_digest") == anchor.fetch("semantic_digest")
            row
          else
            {
              "anchor_symbol" => anchor.fetch("symbol"),
              "anchor_semantic_digest" => anchor.fetch("semantic_digest"),
              "capture" => {
                "status" => "STALE",
                "run_ids" => run_ids,
                "observed_executions" => 0,
                "dropped_executions" => 0,
                "reason" => "source semantics changed after this shard was collected",
              },
              "executions" => [],
            }
          end
        end
        bundle.merge(
          "trace_plan_digest" => plan.fetch("plan_digest"),
          "anchors" => anchors,
          "correlations" => bundle.fetch("correlations", []).select do |correlation|
            correlation.fetch("candidate_anchor_symbols").all? do |symbol|
              old_row = old[symbol]
              request = requests[symbol]
              old_row && request &&
                old_row.fetch("anchor_semantic_digest") ==
                  request.dig("anchor", "semantic_digest")
            end
          end
        )
      end

      def merge_runs(bundles)
        bundles.flat_map { |bundle| bundle.fetch("runs") }
          .group_by { |run| run.fetch("id") }
          .sort.map do |id, rows|
            unique!(rows.map { |row| JSON.generate(row) }, "run #{id}")
            rows.first
          end
      end

      def merge_anchors(bundles)
        per_bundle = bundles.map do |bundle|
          rows = bundle.fetch("anchors")
          if rows.map { |row| row.fetch("anchor_symbol") }.uniq.length != rows.length
            raise ArgumentError, "runtime evidence shard contains duplicate anchors"
          end
          rows.to_h { |row| [row.fetch("anchor_symbol"), row] }
        end
        # Shards no longer carry an entry per planned anchor, so they legitimately
        # cover different sets: a shard contributes what it observed. A symbol is
        # merged from the shards that saw it.
        symbols = per_bundle.flat_map(&:keys).uniq.sort
        symbols.map do |symbol|
          rows = per_bundle.filter_map { |bundle| bundle[symbol] }
          digest = unique!(
            rows.map { |row| row.fetch("anchor_semantic_digest") },
            "semantic digest for #{symbol}"
          )
          executions = rows.flat_map { |row| row.fetch("executions") }
          captures = rows.map { |row| row.fetch("capture") }
          {
            "anchor_symbol" => symbol,
            "anchor_semantic_digest" => digest,
            "capture" => {
              "status" => merged_status(captures, executions),
              "run_ids" => captures.flat_map { |capture| capture.fetch("run_ids") }.uniq.sort,
              "observed_executions" => executions.sum { |bucket| bucket.fetch("count").to_i },
              "dropped_executions" => captures.sum {
                |capture| capture.fetch("dropped_executions", 0).to_i
              },
              "reason" => merged_reason(captures, executions),
              "complete_kinds" => captures
                .map { |capture| Array(capture["complete_kinds"]) }
                .reduce { |complete, kinds| complete & kinds }
                .to_a.sort,
            }.reject { |key, value| key == "reason" && value.empty? },
            "executions" => merge_buckets(executions),
          }
        end
      end

      def merge_correlations(bundles)
        bundles.flat_map { |bundle| bundle.fetch("correlations", []) }
          .group_by { |row| row.fetch("group_id") }
          .sort.map do |group_id, rows|
            candidates = unique!(
              rows.map { |row| row.fetch("candidate_anchor_symbols") },
              "candidate anchors for correlation #{group_id}"
            )
            executions = rows.flat_map { |row| row.fetch("executions") }
            captures = rows.map { |row| row.fetch("capture") }
            {
              "group_id" => group_id,
              "candidate_anchor_symbols" => candidates,
              "capture" => {
                "status" => merged_status(captures, executions),
                "run_ids" => captures.flat_map { |capture| capture.fetch("run_ids") }.uniq.sort,
                "observed_executions" => executions.sum { |bucket| bucket.fetch("count").to_i },
                "dropped_executions" => captures.sum {
                  |capture| capture.fetch("dropped_executions", 0).to_i
                },
                "reason" => merged_reason(captures, executions),
                "complete_kinds" => captures
                  .map { |capture| Array(capture["complete_kinds"]) }
                  .reduce { |complete, kinds| complete & kinds }
                  .to_a.sort,
              }.reject { |key, value| key == "reason" && value.empty? },
              "executions" => merge_buckets(executions),
            }
          end
      end

      def merge_buckets(rows)
        rows.group_by { |row| JSON.generate(row.reject { |key, _| key == "count" }) }
          .values.map do |group|
            group.first.merge("count" => group.sum { |row| row.fetch("count").to_i })
          end.sort_by { |row| JSON.generate(row) }
      end

      def merged_status(captures, executions)
        statuses = captures.map { |capture| capture.fetch("status") }
        return "FAILED_CAPTURE" if statuses.include?("FAILED_CAPTURE")
        return "STALE" if statuses.include?("STALE")
        return "PARTIAL" if (statuses & %w[PARTIAL NOT_INSTRUMENTED UNSUPPORTED]).any?
        return "NOT_EXECUTED" if executions.empty?

        "COMPLETE_FOR_RUNS"
      end

      def merged_reason(captures, executions)
        status = merged_status(captures, executions)
        return "" if status == "COMPLETE_FOR_RUNS"

        relevant = captures.reject do |capture|
          %w[COMPLETE_FOR_RUNS NOT_EXECUTED].include?(capture.fetch("status"))
        end
        relevant = captures if relevant.empty?
        relevant.filter_map { |capture| capture["reason"] }.uniq.sort.join("; ")
      end

      def unique!(values, label)
        values = values.uniq
        raise ArgumentError, "runtime evidence shards disagree on #{label}" unless values.one?

        values.first
      end
    end
  end
end
