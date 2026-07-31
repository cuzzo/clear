# typed: false
# frozen_string_literal: true

require "open3"
require "tempfile"

module NilKill
  module Runtime
    # Owns the canonical runtime-evidence snapshot and the dependency metadata
    # needed to rebuild it from independently replaceable test shards.
    class Snapshot
      SCHEMA = "nil-kill.runtime-snapshot.v1"
      MANIFEST = "runtime-snapshot.json.gz"
      FINGERPRINT_SCHEME = "provider-runtime-evidence-v1"

      attr_reader :root, :runtime_dir, :manifest

      def self.load(root:, runtime_dir:)
        path = File.join(runtime_dir, MANIFEST)
        raise ArgumentError, "no runtime snapshot at #{path}; run a full collect first" unless File.file?(path)

        manifest = JsonIO.parse(path)
        unless manifest["schema"] == SCHEMA &&
            manifest["fingerprint_scheme"] == FINGERPRINT_SCHEME
          raise ArgumentError,
            "runtime snapshot fingerprint contract is unsupported; run a full collect"
        end
        new(root: root, runtime_dir: runtime_dir, manifest: manifest)
      end

      def initialize(root:, runtime_dir:, manifest: nil)
        @root = File.expand_path(root)
        @runtime_dir = File.expand_path(runtime_dir)
        @manifest = manifest
      end

      def source_hashes(files)
        Array(files).select { |path| File.file?(path) }.sort.to_h do |path|
          provider = Languages.provider_for_path(path)
          fingerprint =
            if provider
              provider.runtime_incremental_fingerprint(path)
            else
              Digest::SHA256.file(path).hexdigest
            end
          [relative(path), fingerprint]
        end
      end

      def write_full!(
        files:,
        evidence_path:,
        workload_digest: nil,
        function_inventory: {},
        workload: {},
        dependencies: {},
        callsites: {},
        trace_plan_digest: nil
      )
        hashes = source_hashes(files)
        environment = runtime_environment(files)
        snapshot_id = identity(
          "full",
          hashes,
          environment,
          workload_digest,
          Digest::SHA256.hexdigest(JsonIO.read(evidence_path))
        )
        write_manifest!(
          "schema" => SCHEMA,
          "fingerprint_scheme" => FINGERPRINT_SCHEME,
          "snapshot_id" => snapshot_id,
          "base_full_snapshot_id" => snapshot_id,
          "parent_snapshot_id" => nil,
          "generation" => 0,
          "mode" => "full",
          "complete" => true,
          "potentially_stale" => false,
          "source_hashes" => hashes,
          "environment" => environment,
          "workload_digest" => workload_digest,
          "trace_plan_digest" => trace_plan_digest.to_s,
          "functions" => function_inventory,
          "workload" => workload,
          "dependencies" => dependencies,
          "callsites" => callsites,
          "changed_paths" => hashes.keys.sort,
          "deleted_paths" => [],
          "created_at" => Time.now.utc.iso8601,
          "evidence" => relative(evidence_path),
        )
      end

      # Comparing two manifests to decide which shards must rerun. Set
      # arithmetic over what the sources, functions, tests and workload were
      # against what they are -- FactMine's, so there is one implementation of
      # a rule whose failure mode is skipping a shard that needed rerunning.
      def select_increment(
        files:,
        function_inventory:,
        workload_plan:,
        trace_plan_digest:
      )
        request = {
          "manifest" => manifest,
          "current_hashes" => source_hashes(files),
          "environment" => runtime_environment(files),
          "functions" => function_inventory,
          "workload" => workload_plan.to_h,
          "trace_plan_digest" => trace_plan_digest.to_s,
        }
        Tempfile.create(["nil-kill-increment-in", ".json"]) do |input|
          input.write(JSON.generate(request))
          input.flush
          Tempfile.create(["nil-kill-increment-out", ".json"]) do |out|
            _stdout, err, status = Open3.capture3(
              NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY,
              "nil-kill-select-increment", "--input", input.path, "--output", out.path
            )
            raise "fact-mine nil-kill-select-increment failed: #{err}" unless status.success?

            JSON.parse(File.read(out.path))
          end
        end
      end

      def write_incremental!(
        selection:,
        evidence_path:,
        dependencies:,
        callsites:
      )
        parent_id = manifest.fetch("snapshot_id")
        generation = manifest.fetch("generation").to_i + 1
        snapshot_id = identity(
          "fast",
          selection.fetch("current_hashes"),
          selection.fetch("functions"),
          selection.fetch("workload"),
          parent_id,
          generation
        )
        write_manifest!(
          "schema" => SCHEMA,
          "fingerprint_scheme" => FINGERPRINT_SCHEME,
          "snapshot_id" => snapshot_id,
          "base_full_snapshot_id" => manifest.fetch("base_full_snapshot_id"),
          "parent_snapshot_id" => parent_id,
          "generation" => generation,
          "mode" => "fast",
          "complete" => !selection.fetch("uncertain_closure"),
          "potentially_stale" => selection.fetch("uncertain_closure"),
          "source_hashes" => selection.fetch("current_hashes"),
          "environment" => selection.fetch("environment"),
          "workload_digest" => selection.dig("workload", "command_digest"),
          "trace_plan_digest" => selection.fetch("trace_plan_digest"),
          "functions" => selection.fetch("functions"),
          "workload" => selection.fetch("workload"),
          "dependencies" => dependencies,
          "callsites" => callsites,
          "changed_functions" => selection.fetch("changed_functions"),
          "added_functions" => selection.fetch("added_functions"),
          "deleted_functions" => selection.fetch("deleted_functions"),
          "changed_tests" => selection.fetch("changed_tests"),
          "deleted_tests" => selection.fetch("deleted_tests"),
          "changed_files" => selection.fetch("changed_files"),
          "deleted_files" => selection.fetch("deleted_files"),
          "residual_source_changes" => selection.fetch("residual_source_changes"),
          "selected_shards" => selection.fetch("selected_shards"),
          "fallback_full" => selection.fetch("fallback_full"),
          "support_changed" => selection.fetch("support_changed"),
          "created_at" => Time.now.utc.iso8601,
          "evidence" => relative(evidence_path),
        )
      end

      def mark_stale!(reason:, selection:)
        write_manifest!(
          manifest.merge(
            "complete" => false,
            "potentially_stale" => true,
            "stale_reason" => reason.to_s,
            "attempted_changed_functions" => selection.fetch("changed_functions", []),
            "attempted_changed_tests" => selection.fetch("changed_tests", []),
            "attempted_selected_shards" => selection.fetch("selected_shards", []),
            "stale_at" => Time.now.utc.iso8601
          )
        )
      end

      private

      def runtime_environment(files)
        Array(files).filter_map { |path| Languages.provider_for_path(path) }
          .uniq
          .sort_by(&:language)
          .each_with_object({}) do |provider, claims|
            provider.runtime_scip_environment(root: root).each do |key, value|
              claims[key.to_s] = value.to_s
            end
          end
          .sort
          .to_h
      end

      def write_manifest!(value)
        @manifest = value
        JsonIO.write(File.join(runtime_dir, MANIFEST), JSON.pretty_generate(value) + "\n")
        value
      end

      def identity(*parts)
        "sha256:#{Digest::SHA256.hexdigest(parts.map { |part| JSON.generate(part) }.join("\0"))}"
      end

      def relative(path)
        Pathname.new(File.expand_path(path, root)).relative_path_from(Pathname.new(root)).to_s
      rescue ArgumentError
        path.to_s
      end
    end
  end
end
