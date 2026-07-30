# frozen_string_literal: true

require_relative "spec_helper"
require "open3"

# The join -- deciding which planned anchor an observation satisfies -- is being
# moved out of Ruby and into FactMine, where it runs once for every collector
# language instead of once per language. Two implementations of a decision drift
# apart silently, so this pins them together on a real collect: same plan, same
# trace, therefore any disagreement is the port.
RSpec.describe "runtime trace join" do
  FACT_MINE = File.expand_path("../../fact-mine/target/release/fact-mine-rust", __dir__)

  SUBJECT_SRC = <<~RUBY
    class W
      def initialize(seed)
        @seed = seed.to_s
      end

      def calc(value)
        inner(value) + @seed.length
      end

      def inner(value)
        value.abs
      end

      def each_of(values)
        values.map { |item| item.to_s }
      end

      def raises
        raise ArgumentError, "boom"
      rescue ArgumentError
        :rescued
      end
    end
  RUBY

  DRIVER_SRC = <<~RUBY
    require_relative "lib"
    w = W.new(7)
    w.calc(3)
    w.calc(-4)
    w.each_of([1, 2])
    w.raises
  RUBY

  def ruby_statuses(evidence)
    evidence.fetch("anchors").to_h do |row|
      [row.fetch("anchor_symbol"),
       [row.dig("capture", "status"), row.dig("capture", "observed_executions").to_i]]
    end
  end

  def rust_statuses(plan_path, trace_path)
    out, err, status = Open3.capture3(
      FACT_MINE, "runtime-trace",
      "--plan", plan_path, "--runtime-trace", trace_path, "--root", NilKill::ROOT
    )
    raise "fact-mine runtime-trace failed: #{err}" unless status.success?

    JSON.parse(out)
  end

  it "agrees with the Ruby join on every anchor of a real collect", if: File.executable?(FACT_MINE) do
    Dir.mktmpdir("nk-join", NilKill::ROOT) do |dir|
      File.write(File.join(dir, "lib.rb"), SUBJECT_SRC)
      mini_collect(dir, "lib.rb", DRIVER_SRC, runtime_scip: true, targets: dir)

      runtime_dir = NilKill::RUNTIME_DIR
      plan = NilKill::Runtime::EvidenceProtocol.plan
      expect(plan.fetch("requests")).not_to be_empty

      trace_path = NilKill::Runtime::TraceArtifact.write(
        root: NilKill::ROOT, runtime_dir: runtime_dir, plan: plan,
        languages: ["ruby"], run_ids: ["join-spec"]
      )
      evidence = NilKill::Runtime::ScipEmitter.emit_value_evidence(
        root: NilKill::ROOT, runtime_dir: runtime_dir,
        languages: ["ruby"], run_ids: ["join-spec"]
      )

      ruby = ruby_statuses(NilKill::Runtime::JsonIO.parse(evidence.fetch("path")))
      rust = rust_statuses(NilKill::TRACE_PLAN_PATH, trace_path)

      expect(rust.keys.sort).to eq(ruby.keys.sort)
      disagreements = ruby.filter_map do |symbol, expected|
        observed = rust.fetch(symbol)
        next if observed == expected

        "#{symbol}: ruby=#{expected.inspect} rust=#{observed.inspect}"
      end
      expect(disagreements).to be_empty
      # A corpus where nothing was captured would make the comparison vacuous.
      expect(ruby.values.count { |status, _| status == "COMPLETE_FOR_RUNS" }).to be > 0
    end
  end
end
