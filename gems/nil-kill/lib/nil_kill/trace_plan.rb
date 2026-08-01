# typed: false
# frozen_string_literal: true

require "open3"
require "tempfile"

module NilKill
  class TracePlan
    def self.write(path = TRACE_PLAN_PATH)
      new.write(path)
    end

    def initialize
      @methods = {}
      @tlets = {}
      @struct_fields = {}
      @state_write_site_owners = {}
      @runtime_call_sites = {}
      @runtime_result_call_sites = {}
      @runtime_collection_receiver_sites = {}
      @runtime_native_activation_sites = {}
    end

    # FactMine already decided what the source says; turning that into an
    # instrumentation plan is the same arithmetic, so it happens there.
    def write(path)
      files = NilKill.target_files
      FileUtils.mkdir_p(File.dirname(path))
      static = files.empty? ? { "methods" => [], "fields" => [], "facts" => {} } :
        StaticEvidence.build_trace_plan(files, root: ROOT)
      evidence = files.empty? ? nil : StaticEvidence.build_runtime_evidence_plan(files, root: ROOT)

      facts = Tempfile.new(["nil-kill-static-facts", ".json"])
      facts.write(JSON.generate(static))
      facts.close
      written = nil
      args = [Espalier::StaticEvidence::FACT_MINE_RUST_BINARY, "nil-kill-trace-plan",
              "--static-facts", facts.path, "--output", path.to_s, "--root", ROOT,
              "--generated-at", Time.now.utc.iso8601]
      NilKill.target_dirs.each { |dir| args.concat(["--target-dir", File.expand_path(dir, ROOT)]) }
      NilKill.target_exclude_dirs.each do |dir|
        args.concat(["--exclude-dir", File.expand_path(dir, ROOT)])
      end
      if evidence
        written = Tempfile.new(["nil-kill-runtime-plan", ".json"])
        written.write(JSON.generate(evidence))
        written.close
        args.concat(["--runtime-plan", written.path])
      end
      _out, err, status = Open3.capture3(*args)
      raise "fact-mine nil-kill-trace-plan failed: #{err}" unless status.success?

      facts.unlink
      written&.unlink
      write_collector_plan(File.join(File.dirname(path), COLLECTOR_PLAN_NAME), evidence)
    end

    private

    # The collector reads this instead of the plan above: flat records rather
    # than a document plus the code to reshape it, because everything in it was
    # already decided by the time the plan was built.
    def write_collector_plan(path, _runtime_evidence_plan)
      binary = NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY
      args = [binary, "nil-kill-collector-plan",
              "--plan", TRACE_PLAN_PATH, "--output", path, "--root", ROOT]
      NilKill.target_dirs.each { |dir| args.concat(["--target-dir", dir.to_s]) }
      _out, err, status = Open3.capture3(*args)
      raise "fact-mine nil-kill-collector-plan failed: #{err}" unless status.success?
    end

    def void_signature?(signature)
      signature.to_s.match?(/\bvoid\b/)
    end
  end
end
