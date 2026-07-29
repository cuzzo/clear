# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Owns the canonical runtime-evidence snapshot. Incremental collections
    # replace every row attributable to a source observed by the delta (plus
    # changed/deleted sources), then atomically rewrite the complete canonical
    # evidence file. Delta directories remain as an audit trail.
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

      def changes(files, workload_digest: nil)
        current = source_hashes(files)
        previous = manifest.fetch("source_hashes")
        changed = current.filter_map { |path, digest| path if previous[path] != digest }
        deleted = previous.keys - current.keys
        current_environment = runtime_environment(files)
        environment_changed = current_environment != manifest.fetch("environment", {})
        workload_changed = workload_digest && workload_digest != manifest["workload_digest"]
        # Environment changes can alter every dispatch/cost observation. A
        # different workload with otherwise unchanged source is an explicit
        # request to extend/refresh coverage, so trace the whole source set.
        if environment_changed || (workload_changed && changed.empty? && deleted.empty?)
          changed = current.keys
        end
        {
          "current_hashes" => current,
          "changed_paths" => changed.sort,
          "deleted_paths" => deleted.sort,
          "environment" => current_environment,
          "environment_changed" => environment_changed,
          "workload_changed" => !!workload_changed,
        }
      end

      def write_full!(files:, evidence_path:, workload_digest: nil)
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
          "changed_paths" => hashes.keys.sort,
          "deleted_paths" => [],
          "created_at" => Time.now.utc.iso8601,
          "evidence" => relative(evidence_path),
        )
      end

      def merge_delta!(
        delta_evidence_path:,
        changed_paths:,
        deleted_paths:,
        current_hashes:,
        environment:,
        workload_digest:
      )
        canonical_path = File.join(runtime_dir, ValueEvidenceEmitter::DEFAULT_OUTPUT)
        baseline = JsonIO.parse(canonical_path)
        delta = JsonIO.parse(delta_evidence_path)
        observed = evidence_paths(delta)
        replaced = (Array(changed_paths) + Array(deleted_paths) + observed).uniq.sort
        merged = merge_evidence(baseline, delta, replaced)
        parent_id = manifest.fetch("snapshot_id")
        generation = manifest.fetch("generation").to_i + 1
        freshness = {
          "mode" => "fast",
          "potentially_stale" => true,
          "base_full_snapshot_id" => manifest.fetch("base_full_snapshot_id"),
          "parent_snapshot_id" => parent_id,
          "generation" => generation,
          "replaced_paths" => replaced,
          "reason" =>
            "dynamic effects outside the retraced/observed source slice are not proven closed",
        }
        merged["freshness"] = freshness
        JsonIO.write(canonical_path, JSON.pretty_generate(merged) + "\n")
        snapshot_id = identity("fast", current_hashes, parent_id, generation)
        write_manifest!(
          "schema" => SCHEMA,
          "fingerprint_scheme" => FINGERPRINT_SCHEME,
          "snapshot_id" => snapshot_id,
          "base_full_snapshot_id" => manifest.fetch("base_full_snapshot_id"),
          "parent_snapshot_id" => parent_id,
          "generation" => generation,
          "mode" => "fast",
          "complete" => false,
          "potentially_stale" => true,
          "source_hashes" => current_hashes,
          "environment" => environment,
          "workload_digest" => workload_digest,
          "changed_paths" => Array(changed_paths).sort,
          "deleted_paths" => Array(deleted_paths).sort,
          "replaced_paths" => replaced,
          "created_at" => Time.now.utc.iso8601,
          "evidence" => relative(canonical_path),
        )
        canonical_path
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

      def merge_evidence(baseline, delta, replaced)
        result = baseline.merge(
          "environment" => baseline.fetch("environment", {}).merge(delta.fetch("environment", {})).sort.to_h,
          "runs" => (Array(baseline["runs"]) + Array(delta["runs"])).uniq.sort
        )
        result["observations"] = replace_rows(
          baseline.fetch("observations", []),
          delta.fetch("observations", []),
          replaced
        ) { |row| row.dig("scope", "path").to_s }
        result["calls"] = replace_rows(
          baseline.fetch("calls", []),
          delta.fetch("calls", []),
          replaced
        ) do |row|
          callsite_path = row.dig("callsite", "path").to_s
          callsite_path.empty? ? row.dig("caller", "path").to_s : callsite_path
        end
        result
      end

      def replace_rows(old_rows, new_rows, replaced)
        kept = old_rows.reject { |row| replaced.include?(yield(row)) }
        (kept + new_rows).uniq { |row| JSON.generate(row) }
      end

      def evidence_paths(evidence)
        calls = evidence.fetch("calls", []).flat_map do |row|
          [row.dig("callsite", "path"), row.dig("caller", "path")]
        end
        observations = evidence.fetch("observations", []).map { |row| row.dig("scope", "path") }
        (calls + observations).map(&:to_s).reject(&:empty?).uniq.sort
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
