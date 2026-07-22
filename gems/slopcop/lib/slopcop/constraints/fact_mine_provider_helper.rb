# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

module SlopCop
  module Constraints
    module FactMineProviderHelper
      module_function

      def scan_hazards_via_fact_mine(paths, repo:, language_extension:, hazard_type_filter:, required_evidence: nil, label: nil)
        hazard_sites_via_fact_mine(paths, repo: repo, language_extension: language_extension) do |hazard_sites, files, repo_path|
          filter_and_format_hazards(hazard_sites, files, repo_path, hazard_type_filter)
        end
      end

      # Same underlying fact-mine invocation as scan_hazards_via_fact_mine,
      # but resolves several distinct hazard categories (each with its own
      # required_evidence/label) from ONE pass over the facts instead of one
      # call per category. A provider needing N systems-hazard categories
      # (Rust: loom-atomic, loom-concurrency, unsafe-fn, unsafe-impl,
      # unsafe-block, unsafe-operation) would otherwise re-invoke the
      # fact-mine-rust binary N times for the exact same files - multiplying
      # CI's subprocess-spawn count for no benefit, since every category's
      # data comes from the same single fact-mine pass regardless.
      #
      # `categories` is an Array of Hashes containing at least `hazard_type`.
      # Evidence and labels are resolved from FactMine's emitted site and the
      # shared hazard contract, never from provider-specific copies.
      # `hazard_type` may be a String or an Array of Strings.
      def scan_multi_hazards_via_fact_mine(paths, repo:, language_extension:, categories:)
        hazard_sites_via_fact_mine(paths, repo: repo, language_extension: language_extension) do |hazard_sites, files, repo_path|
          categories.flat_map do |category|
            filter_and_format_hazards(
              hazard_sites, files, repo_path, category.fetch(:hazard_type)
            )
          end
        end
      end

      def hazard_sites_via_fact_mine(paths, repo:, language_extension:)
        repo = File.expand_path(repo)
        extensions = Array(language_extension)
        files = if paths && !Array(paths).empty?
                  Array(paths).map { |f| File.expand_path(f, repo) }
                else
                  extensions.flat_map { |ext| Dir.chdir(repo) { Dir["**/*#{ext}"] } }.map { |f| File.expand_path(f, repo) }
                end
        files = files.select { |f| extensions.any? { |ext| f.end_with?(ext) } && File.file?(f) }

        return [] if files.empty?

        # 1. Try to read from pre-computed facts file
        if ENV["FACT_MINE_FACTS_FILE"] && File.file?(ENV["FACT_MINE_FACTS_FILE"])
          begin
            facts = JSON.parse(File.read(ENV["FACT_MINE_FACTS_FILE"]))
            hazard_sites = facts["hazard_sites"] || []
            return yield(hazard_sites, files, repo)
          rescue => e
            raise "Failed to parse pre-computed facts from #{ENV["FACT_MINE_FACTS_FILE"]}: #{e.message}"
          end
        end

        # 2. Fallback to running fact-mine-rust directly
        fact_mine_bin = ENV.fetch("FACT_MINE_RUST_BINARY", File.expand_path("../../../../fact-mine/target/release/fact-mine-rust", __dir__))
        unless File.executable?(fact_mine_bin)
          raise "fact-mine-rust binary not found or not executable at #{fact_mine_bin}."
        end

        # Run on files in slices to avoid argument length limits
        files.each_slice(100).flat_map do |slice|
          rel_slice = slice.map { |f| Pathname.new(f).relative_path_from(Pathname.new(repo)).to_s }
          stdout, stderr, status = Open3.capture3(fact_mine_bin, "profile", "nil-kill", *rel_slice, chdir: repo)
          unless status.success?
            raise "fact-mine-rust failed: #{stderr}"
          end
          facts = JSON.parse(stdout)
          hazard_sites = facts["hazard_sites"] || []
          yield(hazard_sites, slice, repo)
        end
      end

      def hazard_contract
        @hazard_contract ||= begin
          candidates = [
            ENV["HAZARD_CONTRACT_JSON"],
            File.expand_path("../../../../hazard-contract/contract.json", __dir__),
            File.expand_path("../../../config/hazard_contract.json", __dir__)
          ].compact
          path = candidates.find { |candidate| File.file?(candidate) }
          raise "hazard contract not found" unless path

          JSON.parse(File.read(path))
        end
      end

      def hazard_policy(hazard_type)
        hazard_contract.fetch("policies").find do |policy|
          pattern = policy.fetch("match")
          pattern.include?("*") ? hazard_type.include?(pattern.delete("*")) : hazard_type == pattern
        end
      end

      def required_evidence_for(hazard_type)
        hazard_policy(hazard_type)&.fetch("evidence_provider", "")
      end

      def filter_and_format_hazards(hazard_sites, files, repo, hazard_type_filter)
        abs_files = files.map { |f| File.expand_path(f, repo) }

        hazard_sites.select do |site|
          site_abs_path = File.expand_path(site["path"], repo)
          match_hazard = if hazard_type_filter.is_a?(Regexp)
                           site["hazard_type"] =~ hazard_type_filter
                         elsif hazard_type_filter.is_a?(Array)
                           hazard_type_filter.include?(site["hazard_type"])
                         else
                           site["hazard_type"] == hazard_type_filter
                         end
          abs_files.include?(site_abs_path) && match_hazard
        end.map do |site|
          hazard_type = site.fetch("hazard_type")
          policy = hazard_policy(hazard_type)
          raise "hazard site #{hazard_type.inspect} has no hazard-contract policy" unless policy

          emitted_evidence = site.fetch("required_evidence", nil).to_s
          {
            path: Pathname.new(File.expand_path(site["path"], repo)).relative_path_from(Pathname.new(repo)).to_s,
            line: site["line"],
            source: site["source"].to_s.strip,
            hazard_type: hazard_type,
            # FactMine's site is authoritative. The contract is only a
            # validation/default for older precomputed facts; provider
            # configuration must never overwrite this value.
            required_evidence: emitted_evidence.empty? ? policy.fetch("evidence_provider") : emitted_evidence,
            label: site["label"] || policy.fetch("label"),
            hazard_kind: site["hazard_kind"] || policy.fetch("kind"),
            evidence_claim: site["evidence_claim"] || policy.fetch("evidence_claim"),
            coverage_required: site.key?("coverage_required") ? site["coverage_required"] : policy.fetch("coverage_required"),
            report_required: site.key?("report_required") ? site["report_required"] : policy.fetch("report_required"),
            mitigation: site["mitigation"] || policy.fetch("mitigation")
          }
        end
      end

      def findings_via_fact_mine(provider, repo:, additions:, evidence:)
        repo = File.expand_path(repo)
        changed_files = additions.keys.select { |path| provider.source_path?(path) }
        return [] if changed_files.empty?

        hazards = provider.scan_hazards(repo: repo, paths: changed_files)
        
        hazards.each_with_object([]) do |hazard, out|
          path = hazard[:path]
          lines = additions[path]
          next unless lines
          next unless hazard.fetch(:report_required, true)

          changed = lines.to_set
          next unless changed.include?(hazard[:line])

          if hazard.fetch(:coverage_required, true)
            next if LanguageProvider.covered?(evidence, hazard)
            message = "changed #{hazard[:label]} has no #{hazard[:required_evidence]} coverage evidence"
          else
            message = "changed #{hazard[:label]} requires review; #{hazard[:evidence_claim]} evidence cannot satisfy this hazard"
          end

          out << Finding.new(
            path: path,
            line: hazard[:line],
            rule_id: provider.rule_id_for(hazard[:required_evidence]),
            message: message,
            source: hazard[:source],
            hazard_type: hazard[:hazard_type],
            required_evidence: hazard[:required_evidence],
            severity: "warning"
          )
        end
      end
    end
  end
end
