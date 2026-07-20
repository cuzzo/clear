# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

module SlopCop
  module Constraints
    module FactMineProviderHelper
      module_function

      def scan_hazards_via_fact_mine(paths, repo:, language_extension:, hazard_type_filter:, required_evidence:, label:)
        repo = File.expand_path(repo)
        files = if paths && !Array(paths).empty?
                  Array(paths).map { |f| File.expand_path(f, repo) }
                else
                  Dir.chdir(repo) { Dir["**/*#{language_extension}"] }.map { |f| File.expand_path(f, repo) }
                end
        files = files.select { |f| f.end_with?(language_extension) && File.file?(f) }

        return [] if files.empty?

        # 1. Try to read from pre-computed facts file
        if ENV["FACT_MINE_FACTS_FILE"] && File.file?(ENV["FACT_MINE_FACTS_FILE"])
          begin
            facts = JSON.parse(File.read(ENV["FACT_MINE_FACTS_FILE"]))
            hazard_sites = facts["hazard_sites"] || []
            return filter_and_format_hazards(hazard_sites, files, repo, hazard_type_filter, required_evidence, label)
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
          filter_and_format_hazards(hazard_sites, slice, repo, hazard_type_filter, required_evidence, label)
        end
      end

      def filter_and_format_hazards(hazard_sites, files, repo, hazard_type_filter, required_evidence, label)
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
          {
            path: Pathname.new(File.expand_path(site["path"], repo)).relative_path_from(Pathname.new(repo)).to_s,
            line: site["line"],
            source: site["source"].to_s.strip,
            hazard_type: site["hazard_type"],
            required_evidence: required_evidence,
            label: label
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
          
          changed = lines.to_set
          next unless changed.include?(hazard[:line])
          next if LanguageProvider.covered?(evidence, hazard)

          out << Finding.new(
            path: path,
            line: hazard[:line],
            rule_id: provider.rule_id_for(hazard[:required_evidence]),
            message: "changed #{hazard[:label]} has no #{hazard[:required_evidence]} coverage evidence",
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
