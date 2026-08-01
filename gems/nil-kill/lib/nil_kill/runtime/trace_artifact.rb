# frozen_string_literal: true

require "open3"

module NilKill
  module Runtime
    # Driving FactMine's join over the documents the shards produced.
    module TraceArtifact
      VERSION = 1
      DEFAULT_NAME = "runtime-trace.json.gz"
      # What the join writes beside it.
      EVIDENCE_NAME = "runtime-evidence.v1.json.gz"

      # One invocation for every shard: the plan is parsed and digest-checked
      # once, and the shards -- which are independent -- join concurrently.
      # Joining them one at a time was the largest sequential stage of a collect.
      def self.join_all(root:, traces:, merged: nil, plan: NilKill::TRACE_PLAN_PATH)
        return traces if traces.empty?

        binary = NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY
        args = [binary, "runtime-trace", "--plan", plan.to_s, "--root", root.to_s]
        args.concat(["--merged-output", merged.to_s]) if merged
        traces.each_value { |trace| args.concat(["--runtime-trace", trace]) }
        _out, err, status = Open3.capture3(*args)
        raise "fact-mine runtime-trace failed: #{err}" unless status.success?

        traces
      end
    end
  end
end
