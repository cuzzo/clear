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

  def rust_evidence(plan_path, trace_path)
    out, err, status = Open3.capture3(
      FACT_MINE, "runtime-trace", "--stdout",
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

      NilKill::Runtime::DomainDeriver.trace_documents(
        runtime_dirs: [runtime_dir], plan: NilKill::TRACE_PLAN_PATH, root: NilKill::ROOT
      )
      trace_path = File.join(runtime_dir, NilKill::Runtime::TraceArtifact::DEFAULT_NAME)
      # The run a shard was traced under is recorded by the traced program
      # itself, so both joins read it from there rather than being handed a
      # synthetic one that only the Ruby side would have seen.
      run_ids = NilKill::Runtime::JsonIO.parse(trace_path).fetch("run_ids")
      evidence = NilKill::Runtime::ScipEmitter.emit_value_evidence(
        root: NilKill::ROOT, runtime_dir: runtime_dir,
        languages: ["ruby"], run_ids: run_ids
      )

      ruby_doc = NilKill::Runtime::JsonIO.parse(evidence.fetch("path"))
      rust_doc = rust_evidence(NilKill::TRACE_PLAN_PATH, trace_path)

      %w[protocol_version authority trace_plan_digest runs environment correlations].each do |key|
        expect(rust_doc[key]).to eq(ruby_doc[key]), key
      end

      # FactMine's evidence is sparse: an anchor with no entry was not executed.
      # Compare on the dense view so the two are judged on what they claim, not
      # on how much of it they spell out.
      ruby_anchors = ruby_doc.fetch("anchors").to_h { |row| [row.fetch("anchor_symbol"), row] }
      rust_anchors = rust_doc.fetch("anchors").to_h { |row| [row.fetch("anchor_symbol"), row] }
      expect(rust_anchors.keys.to_set - ruby_anchors.keys.to_set).to be_empty
      (ruby_anchors.keys - rust_anchors.keys).each do |symbol|
        row = ruby_anchors.fetch(symbol)
        expect(row.dig("capture", "status")).to eq("NOT_EXECUTED"), symbol
        expect(row.fetch("executions")).to be_empty, symbol
        rust_anchors[symbol] = row
      end
      expect(rust_anchors.keys.sort).to eq(ruby_anchors.keys.sort)

      disagreements = ruby_anchors.filter_map do |symbol, expected|
        observed = rust_anchors.fetch(symbol)
        next if observed == expected

        "#{symbol}\n  ruby=#{JSON.generate(expected)[0, 400]}\n  rust=#{JSON.generate(observed)[0, 400]}"
      end
      expect(disagreements).to be_empty

      # A corpus where nothing was captured would make the comparison vacuous.
      captured = ruby_anchors.values.count { |row| row.dig("capture", "status") == "COMPLETE_FOR_RUNS" }
      expect(captured).to be > 0
    end
  end
end
