# typed: false
# frozen_string_literal: true

require "open3"
require "tempfile"

module NilKill
  module Runtime
    # Orchestrates the evidence-only NilKill -> FactMine boundary. NilKill
    # serializes observations; FactMine owns source analysis and SCIP output.
    class ScipEmitter
      # The contract `trace-spec` publishes: what authority this index claims
      # and which event schema a tracer must produce. FactMine writes the index
      # and the attestation, and holds the same constants.
      SCHEMA_VERSION = 1
      TOOL_NAME = "nil-kill-runtime"
      TOOL_VERSION = "2"
      AUTHORITY = "runtime-modeled-world"
      AUTHORITY_ARGUMENT = "--fact-mine-index-authority=#{AUTHORITY}"

      def self.emit(
        root:,
        runtime_dir:,
        output: nil,
        attestation: nil,
        environment: {},
        files: nil,
        value_evidence_path: nil,
        plan: nil
      )
        new(
          root: root,
          runtime_dir: runtime_dir,
          output: output,
          attestation: attestation,
          environment: environment,
          files: files,
          value_evidence_path: value_evidence_path,
          plan: plan
        ).emit
      end

      # Produce only the language-neutral value-evidence bundle. Incremental
      # collection uses this to merge a delta into the canonical snapshot
      # before running FactMine once over the merged evidence.
      def initialize(
        root:,
        runtime_dir:,
        output: nil,
        attestation: nil,
        environment: {},
        files: nil,
        value_evidence_path: nil,
        plan: nil
      )
        @root = File.expand_path(root)
        @runtime_dir = File.expand_path(runtime_dir)
        @output = File.expand_path(output || File.join(@runtime_dir, "runtime.scip.json"))
        @attestation = File.expand_path(
          attestation || File.join(@runtime_dir, "runtime-attestation.json.gz")
        )
        @environment = environment.transform_keys(&:to_s).transform_values(&:to_s)
        @files = files
        @value_evidence_path = value_evidence_path && File.expand_path(value_evidence_path)
        @runtime_plan = plan
      end

      # Selecting the sources, laying the observed values over them, and
      # attesting what the answer covers are all questions about a directory of
      # artifacts. FactMine owns them; this hands over the paths.
      def emit
        Tempfile.create(["nil-kill-runtime-plan", ".json"]) do |file|
          file.write(JSON.generate(runtime_plan))
          file.flush
          evidence = @value_evidence_path || join_runtime_dir
          FileUtils.mkdir_p(File.dirname(@output))
          args = [
            fact_mine_binary, "nil-kill-scip-index",
            "--runtime-dir", @runtime_dir, "--evidence", evidence,
            "--plan", file.path, "--output", @output,
            "--attestation", @attestation, "--root", @root
          ]
          Array(@files).each { |path| args.concat(["--file", path.to_s]) }
          @environment.each { |key, value| args.concat(["--environment", "#{key}=#{value}"]) }
          stdout, stderr, status = Open3.capture3(*args)
          raise "fact-mine nil-kill-scip-index failed: #{stderr.strip}" unless status.success?

          JSON.parse(stdout)
        end
      end

      def join_runtime_dir
        # The plan this emitter was given, which is not always the one on disk:
        # `collect-runtime` builds one for the sources it was pointed at.
        Tempfile.create(["nil-kill-runtime-plan", ".json"]) do |file|
          file.write(JSON.generate(runtime_plan))
          file.flush
          DomainDeriver.trace_documents(
            runtime_dirs: [@runtime_dir], plan: file.path, root: @root
          )
          TraceArtifact.join_all(
            root: @root,
            traces: { "runtime" => File.join(@runtime_dir, TraceArtifact::DEFAULT_NAME) },
            plan: file.path
          )
        end
        File.join(@runtime_dir, TraceArtifact::EVIDENCE_NAME)
      end

      private

      def fact_mine_binary
        Espalier::StaticEvidence::FACT_MINE_RUST_BINARY
      end

      def runtime_plan
        @runtime_plan ||= if File.file?(NilKill::TRACE_PLAN_PATH)
                            EvidenceProtocol.plan
                          else
                            generated =
                              StaticEvidence.build_runtime_evidence_plan(@files, root: @root)
                            raise ArgumentError, "no source files for a runtime evidence plan" unless generated

                            generated
                          end
      end

    end
  end
end
