# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Stable, language-neutral function identities and semantic fingerprints
    # derived from FactMine's normalized source inventory.
    class FunctionInventory
      attr_reader :root, :functions

      def self.build(root:, files:, trace_plan: nil)
        new(root: root, files: files, trace_plan: trace_plan).tap(&:build)
      end

      def initialize(root:, files:, trace_plan: nil)
        @root = File.expand_path(root)
        @files = Array(files)
        @trace_plan = trace_plan || {}
        @functions = {}
      end

      def build
        static = StaticEvidence.build_trace_plan(@files, root: root)
        occurrences = Hash.new(0)
        @functions = static.fetch("methods", []).each_with_object({}) do |method, result|
          path = relative(method.fetch("path"))
          span = Array(method["span"])
          identity = [
            method["language"], path, method["owner"], method["name"], method["kind"]
          ].map(&:to_s)
          occurrence = occurrences[identity]
          occurrences[identity] += 1
          key = [*identity, occurrence].join("\0")
          normalized = method["normalized_source"].to_s
          normalized = method["raw_source"].to_s if normalized.empty?
          result[key] = {
            "key" => key,
            "language" => method["language"].to_s,
            "path" => path,
            "owner" => method["owner"].to_s,
            "name" => method["name"].to_s,
            "kind" => method["kind"].to_s,
            "occurrence" => occurrence,
            "line" => method["line"].to_i,
            "span" => span,
            "fingerprint" => Digest::SHA256.hexdigest(normalized),
            "runtime_demand" => runtime_demand?(method, span),
          }
        end
        self
      end

      def to_h
        functions.sort.to_h
      end

      def keys_for_coverage(path, lines)
        relative_path = relative(path)
        covered = Array(lines).map(&:to_i).to_set
        functions.values.filter_map do |function|
          next unless function["path"] == relative_path
          first_line, last_line = function.fetch("span", []).values_at(0, 2).map(&:to_i).minmax
          function["key"] if covered.any? { |line| line.between?(first_line, last_line) }
        end
      end

      def key_for_entry(path:, owner:, name:, kind:, line: nil)
        relative_path = relative(path)
        candidates = functions.values.select do |function|
          function["path"] == relative_path &&
            function["owner"] == owner.to_s &&
            function["name"] == name.to_s &&
            function["kind"] == kind.to_s
        end
        return candidates.first&.fetch("key") if candidates.length < 2

        entry_line = line.to_i
        matched = candidates.find { |function| function["line"] == entry_line } ||
          candidates.find do |function|
            first_line, last_line = function.fetch("span").values_at(0, 2).map(&:to_i).minmax
            entry_line.between?(first_line, last_line)
          end
        matched&.fetch("key")
      end

      private

      def runtime_demand?(method, span)
        absolute = File.expand_path(method.fetch("path"), root)
        method_key = [
          method["owner"], method["name"], method["kind"], absolute, method["line"]
        ].map(&:to_s).join("\0")
        plan = @trace_plan.fetch("methods", {})[method_key]
        return true if plan && (plan["sample"] || plan["frame"])

        first_line, last_line = span.values_at(0, 2).map(&:to_i).minmax
        %w[
          runtime_call_sites runtime_result_call_sites
          runtime_collection_receiver_sites loop_sites state_write_sites
        ].any? do |field|
          @trace_plan.fetch(field, {}).keys.any? do |key|
            path, line = key.split("\0", 3)
            path == absolute && line.to_i.between?(first_line, last_line)
          end
        end
      end

      def relative(path)
        absolute = File.expand_path(path, root)
        Pathname.new(absolute).relative_path_from(Pathname.new(root)).to_s
      rescue ArgumentError
        path.to_s
      end
    end
  end
end
