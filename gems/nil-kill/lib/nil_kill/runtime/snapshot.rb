# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Owns the canonical runtime-evidence snapshot and the dependency metadata
    # needed to rebuild it from independently replaceable test shards.
    class Snapshot
      SCHEMA = "nil-kill.runtime-snapshot.v1"
      MANIFEST = "runtime-snapshot.json.gz"
      FINGERPRINT_SCHEME = "provider-runtime-evidence-v2"

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
        callsites: {}
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

      def select_increment(
        files:,
        function_inventory:,
        workload_plan:
      )
        current_hashes = source_hashes(files)
        previous_hashes = manifest.fetch("source_hashes", {})
        changed_files = current_hashes.filter_map do |path, fingerprint|
          path if previous_hashes[path] != fingerprint
        end
        deleted_files = previous_hashes.keys - current_hashes.keys
        current_environment = runtime_environment(files)
        previous_functions = manifest.fetch("functions", {})
        current_functions = function_inventory
        previous_workload = manifest.fetch("workload", {})
        current_workload = workload_plan.to_h
        previous_tests = previous_workload.fetch("tests", {})
        current_tests = current_workload.fetch("tests", {})
        previous_support = previous_workload.fetch("support_files", {})
        current_support = current_workload.fetch("support_files", {})
        changed_tests = current_tests.filter_map do |path, fingerprint|
          path if previous_tests[path] != fingerprint
        end
        deleted_tests = previous_tests.keys - current_tests.keys
        support_changed = previous_support != current_support
        added_functions = current_functions.keys - previous_functions.keys
        deleted_functions = previous_functions.keys - current_functions.keys
        changed_functions = current_functions.filter_map do |key, function|
          key if previous_functions[key] &&
            previous_functions[key]["fingerprint"] != function["fingerprint"]
        end
        function_changed_paths = (
          changed_functions.filter_map { |key| current_functions.dig(key, "path") } +
          added_functions.filter_map { |key| current_functions.dig(key, "path") } +
          deleted_functions.filter_map { |key| previous_functions.dig(key, "path") }
        ).uniq
        residual_source_changes = (changed_files + deleted_files).uniq - function_changed_paths
        environment_changed = current_environment != manifest.fetch("environment", {})
        command_changed = previous_workload["command_digest"] != current_workload["command_digest"]
        mode_changed = previous_workload["mode"] != current_workload["mode"]
        current_shards = workload_plan.shards.to_h { |shard| [shard.fetch("id"), shard] }
        prior_shards = previous_workload.fetch("shards", {})
        deleted_shards = prior_shards.keys - current_shards.keys
        selected = changed_tests.filter_map do |path|
          current_shards.values.find { |shard| shard["test_path"] == path }&.fetch("id")
        end
        dependencies = manifest.fetch("dependencies", {})
        changed_functions.each do |function_key|
          selected.concat(dependencies.filter_map do |shard_id, keys|
            shard_id if Array(keys).include?(function_key)
          end)
        end
        uncertain = environment_changed || command_changed || mode_changed ||
          support_changed || added_functions.any? || deleted_functions.any? ||
          residual_source_changes.any?
        opaque_fallback = current_workload["mode"] == "opaque" &&
          (changed_functions.any? || changed_tests.any? || deleted_tests.any?)
        fallback_full = uncertain || opaque_fallback
        selected = current_shards.keys if fallback_full
        {
          "selected_shards" => selected.uniq.sort,
          "deleted_shards" => deleted_shards.sort,
          "changed_tests" => changed_tests.sort,
          "deleted_tests" => deleted_tests.sort,
          "changed_functions" => changed_functions.sort,
          "added_functions" => added_functions.sort,
          "deleted_functions" => deleted_functions.sort,
          "changed_files" => changed_files.sort,
          "deleted_files" => deleted_files.sort,
          "residual_source_changes" => residual_source_changes.sort,
          "support_changed" => support_changed,
          "environment_changed" => environment_changed,
          "command_changed" => command_changed,
          "uncertain_closure" => false,
          "fallback_full" => fallback_full,
          "rebuild" => selected.any? || deleted_shards.any? || changed_functions.any? ||
            added_functions.any? || deleted_functions.any? || fallback_full,
          "current_hashes" => current_hashes,
          "environment" => current_environment,
          "functions" => current_functions,
          "workload" => current_workload,
        }
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
