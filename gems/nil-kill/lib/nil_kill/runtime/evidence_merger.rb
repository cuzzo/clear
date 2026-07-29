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
        run_ids = bundle.fetch("runs").map { |run| run.fetch("id") }
        anchors = plan.fetch("requests").map do |request|
          anchor = request.fetch("anchor")
          row = old[anchor.fetch("symbol")]
          if row && row.fetch("anchor_semantic_digest") == anchor.fetch("semantic_digest")
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
          "anchors" => anchors
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
        symbols = per_bundle.flat_map(&:keys).uniq.sort
        unless per_bundle.all? { |rows| rows.keys.sort == symbols }
          raise ArgumentError, "runtime evidence shards do not cover the same trace-plan anchors"
        end
        symbols.map do |symbol|
          rows = per_bundle.map { |bundle| bundle.fetch(symbol) }
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
              "reason" => captures.filter_map { |capture| capture["reason"] }.uniq.sort.join("; "),
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

      def unique!(values, label)
        values = values.uniq
        raise ArgumentError, "runtime evidence shards disagree on #{label}" unless values.one?

        values.first
      end
    end
  end
end
