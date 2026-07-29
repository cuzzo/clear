# typed: false
# frozen_string_literal: true

module NilKill
  module Runtime
    # Rebuilds canonical runtime evidence from independently replaceable test
    # shard bundles. Keeping each shard is what makes changed/deleted tests
    # subtractable without guessing which aggregate facts they contributed.
    module EvidenceMerger
      module_function

      def merge(paths)
        bundles = Array(paths).select { |path| File.file?(path) }.map { |path| JsonIO.parse(path) }
        {
          "schema" => ValueEvidenceEmitter::SCHEMA,
          "authority" => ScipEmitter::AUTHORITY,
          "environment" => bundles.each_with_object({}) do |bundle, result|
            result.merge!(bundle.fetch("environment", {}))
          end.sort.to_h,
          "runs" => bundles.flat_map { |bundle| Array(bundle["runs"]) }.uniq.sort,
          "observations" => merge_observations(
            bundles.flat_map { |bundle| bundle.fetch("observations", []) }
          ),
          "calls" => merge_calls(bundles.flat_map { |bundle| bundle.fetch("calls", []) }),
        }
      end

      def write(paths, output)
        evidence = merge(paths)
        JsonIO.write(output, JSON.pretty_generate(evidence) + "\n")
        output
      end

      def merge_observations(rows)
        rows.group_by do |row|
          [row["kind"], row["scope"], row["slot"], row["slot_kind"]]
        end.map do |_key, grouped|
          merged = Marshal.load(Marshal.dump(grouped.first))
          merged["count"] = grouped.sum { |row| row["count"].to_i }
          %w[types elements keys values shapes].each do |field|
            merged["domain"][field] = grouped.flat_map { |row| Array(row.dig("domain", field)) }
              .uniq
          end
          merged
        end.sort_by { |row| JSON.generate([row["scope"], row["kind"], row["slot"]]) }
      end

      def merge_calls(rows)
        rows.group_by do |row|
          [
            row["language"], row["caller"], row["callsite"],
            JSON.generate(row["receiver_domain"] || {}),
          ]
        end.map do |_key, grouped|
          merged = Marshal.load(Marshal.dump(grouped.first))
          merged["targets"] = grouped.flat_map { |row| Array(row["targets"]) }
            .uniq { |target| JSON.generate(target) }
            .sort_by { |target| target["symbol"].to_s }
          merged["count"] = grouped.sum { |row| row["count"].to_i }
          %w[receiver_domain result_domain].each do |domain_name|
            domains = grouped.filter_map { |row| row[domain_name] }
            next if domains.empty?
            merged[domain_name] = %w[types elements keys values shapes].to_h do |part|
              [part, domains.flat_map { |domain| Array(domain[part]) }.uniq]
            end
          end
          merged["result_truths"] = grouped.flat_map { |row| Array(row["result_truths"]) }.uniq
          merged
        end.sort_by { |row| JSON.generate([row["language"], row["callsite"], row["caller"]]) }
      end
    end
  end
end
