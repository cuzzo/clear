# frozen_string_literal: true

require "set"

require_relative "finding"
require_relative "language_provider"
require_relative "fact_mine_provider_helper"

repo_tools = File.expand_path("../../../../../tools", __dir__)
require File.join(repo_tools, "loom_atomic_coverage")
require File.join(repo_tools, "vopr_coverage")
require File.join(repo_tools, "wait_loop_coverage")

module SlopCop
  module Constraints
    module ZigProvider
      module_function

      SCOPE_PREFIXES = ["zig/runtime/", "zig/lib/"].freeze

      def rules
        [
          {
            "id" => "slopcop-zig-loom-uncovered",
            "name" => "Zig Loom coverage missing",
            "shortDescription" => { "text" => "Atomic/interleaving site lacks Loom coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Zig atomic/interleaving site in production runtime code was not reached by Loom-only kcov coverage."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-zig-vopr-uncovered",
            "name" => "Zig VOPR coverage missing",
            "shortDescription" => { "text" => "Non-deterministic site lacks VOPR coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Zig time/random/I/O/retry site in production runtime code was not reached by VOPR-only kcov coverage."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-zig-wait-loop-unpaired",
            "name" => "Zig wait-loop hammer marker mismatch",
            "shortDescription" => { "text" => "Wait-loop and hammer coverage markers are not paired" },
            "fullDescription" => {
              "text" => "A changed Zig wait-loop marker has no matching HAMMER-COVERS marker, or a changed HAMMER-COVERS marker has no source wait-loop marker."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-zig-callback-uncovered",
            "name" => "Zig callback coverage missing",
            "shortDescription" => { "text" => "Zig callback invocation lacks test-tracing coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Zig callback or function-pointer invocation site was not reached by test-tracing coverage evidence."
            },
            "defaultConfiguration" => { "level" => "warning" }
          }
        ]
      end

      def findings(repo:, additions:, evidence:)
        repo = File.expand_path(repo)
        wait_indexes = nil
        cb_sites = callback_sites_by_location(repo, additions.keys.select { |path| source_path?(path) })
        additions.each_with_object([]) do |(path, lines), out|
          next unless source_path?(path)

          lines.each do |line|
            source = source_line(repo, path, line)
            next if source.empty?

            add_loom_finding(out, evidence, path, line, source)
            add_vopr_finding(out, evidence, path, line, source)
            add_callback_finding(out, evidence, cb_sites, path, line)
            wait_indexes = add_wait_loop_finding(out, repo, wait_indexes, path, line, source)
          end
        end
      end

      def callback_sites_by_location(repo, paths)
        return {} if paths.empty?

        callback_hazards(repo, paths).to_h { |site| [[site[:path], site[:line]], site] }
      end

      def add_callback_finding(out, evidence, cb_sites, path, line)
        site = cb_sites[[path, line]]
        return unless site
        return unless site.fetch(:report_required, true)

        if site.fetch(:coverage_required, true)
          return if LanguageProvider.covered?(evidence, site)
          message = "changed #{site[:label]} has no #{site[:required_evidence]} coverage evidence"
        else
          message = "changed #{site[:label]} requires review; #{site[:evidence_claim]} evidence cannot satisfy this hazard"
        end

        out << Finding.new(
          path: path,
          line: line,
          rule_id: "slopcop-zig-callback-uncovered",
          message: message,
          source: site[:source],
          hazard_type: site[:hazard_type],
          required_evidence: site[:required_evidence],
          severity: "warning"
        )
      end

      def callback_hazards(repo, paths)
        FactMineProviderHelper.scan_hazards_via_fact_mine(
          paths,
          repo: repo,
          language_extension: ".zig",
          hazard_type_filter: "zig_callback_invocation"
        )
      end

      def source_path?(path)
        path.end_with?(".zig") && SCOPE_PREFIXES.any? { |prefix| path.start_with?(prefix) }
      end

      def scan_hazards(repo:, paths: nil)
        repo = File.expand_path(repo)
        scope = Array(paths)
        scope = SCOPE_PREFIXES if scope.empty?
        cb_paths = scope.flat_map do |entry|
          if entry.end_with?(".zig")
            [entry]
          else
            Dir.chdir(repo) { Dir[File.join(entry, "**/*.zig")] }
          end
        end
        cb_sites = cb_paths.empty? ? [] : callback_hazards(repo, cb_paths)
        loom_sites = LoomAtomicCoverage.scan_atomic_sites(scope, repo).map do |site|
          hazard_site(site, "zig_loom_atomic")
        end
        vopr_sites = VoprCoverage.scan_sites(scope, repo).map do |site|
          hazard_site(site, "zig_vopr_#{site[:category]}")
        end
        wait_files = WaitLoopCoverage.scan_source_files(scope, repo)
        wait_loops, = WaitLoopCoverage.parse_loops(wait_files, repo)
        wait_sites = wait_loops.map do |loop|
          hazard_site(
            {
              file: loop.file,
              line: loop.begin_line,
              source: source_line(repo, loop.file, loop.begin_line)
            },
            "zig_wait_loop"
          )
        end
        (loom_sites + vopr_sites + wait_sites + cb_sites)
          .uniq { |site| [site[:path], site[:line], site[:hazard_type]] }
          .sort_by { |site| [site[:path], site[:line], site[:hazard_type]] }
      end

      def add_loom_finding(out, evidence, path, line, source)
        return unless loom_site?(source)
        return if loom_covered?(evidence, path, line, source)
        hazard_type = "zig_loom_atomic"
        required_evidence = FactMineProviderHelper.required_evidence_for(hazard_type)

        out << Finding.new(
          path: path,
          line: line,
          rule_id: "slopcop-zig-loom-uncovered",
          message: "changed atomic/interleaving site has no Loom coverage evidence",
          source: source.strip,
          hazard_type: hazard_type,
          required_evidence: required_evidence,
          severity: "warning"
        )
      end

      def add_vopr_finding(out, evidence, path, line, source)
        category = vopr_category(source)
        return unless category
        return if vopr_covered?(evidence, path, line, category)
        hazard_type = "zig_vopr_#{category}"
        required_evidence = FactMineProviderHelper.required_evidence_for(hazard_type)

        label = VoprCoverage::CATEGORY_LABEL.fetch(category, category).to_s
        out << Finding.new(
          path: path,
          line: line,
          rule_id: "slopcop-zig-vopr-uncovered",
          message: "changed #{label} site has no VOPR coverage evidence",
          source: source.strip,
          hazard_type: hazard_type,
          required_evidence: required_evidence,
          severity: "warning"
        )
      end

      def add_wait_loop_finding(out, repo, wait_indexes, path, line, source)
        if (begin_match = WaitLoopCoverage::BEGIN_RE.match(source))
          wait_indexes ||= wait_loop_indexes(repo)
          tag = begin_match[1]
          unless wait_indexes[:cover_tags].include?(tag)
            hazard_type = "zig_wait_loop"
            out << Finding.new(
              path: path,
              line: line,
              rule_id: "slopcop-zig-wait-loop-unpaired",
              message: "changed wait-loop tag `#{tag}` has no HAMMER-COVERS marker",
              source: source.strip,
              hazard_type: hazard_type,
              required_evidence: FactMineProviderHelper.required_evidence_for(hazard_type),
              severity: "warning"
            )
          end
        elsif (cover_match = WaitLoopCoverage::COVER_RE.match(source))
          wait_indexes ||= wait_loop_indexes(repo)
          tag = cover_match[1]
          unless wait_indexes[:loop_tags].include?(tag)
            hazard_type = "zig_wait_loop"
            out << Finding.new(
              path: path,
              line: line,
              rule_id: "slopcop-zig-wait-loop-unpaired",
              message: "changed HAMMER-COVERS tag `#{tag}` has no source wait-loop marker",
              source: source.strip,
              hazard_type: hazard_type,
              required_evidence: FactMineProviderHelper.required_evidence_for(hazard_type),
              severity: "warning"
            )
          end
        end
        wait_indexes
      end

      def loom_site?(source)
        stripped = source.sub(LoomAtomicCoverage::COMMENT_RE, "")
        LoomAtomicCoverage::ATOMIC_PATTERNS.any? { |pattern| stripped.match?(pattern) }
      end

      def vopr_category(source)
        return :retry if source.match?(VoprCoverage::RETRY_BEGIN_RE) || source.match?(VoprCoverage::RETRY_SINGLE_RE)

        VoprCoverage.categorize(source.sub(VoprCoverage::COMMENT_RE, ""))
      end

      def loom_covered?(evidence, path, line, source)
        return false unless evidence.known_type?("loom")
        return true if evidence.line_covered?("loom", path, line)
        return false unless evidence.line_known?("loom", path, line)

        LoomAtomicCoverage.classify_artifact(evidence.line_hit_map("loom", path), line, source)
      end

      def vopr_covered?(evidence, path, line, category)
        return false unless evidence.known_type?("vopr")
        if category == :retry
          instrumented = evidence.first_instrumented_line_at_or_after("vopr", path, line)
          return false unless instrumented

          return evidence.line_covered?("vopr", path, instrumented)
        end

        evidence.line_covered?("vopr", path, line)
      end

      def wait_loop_indexes(repo)
        source_files = WaitLoopCoverage.scan_source_files(SCOPE_PREFIXES, repo)
        test_files = WaitLoopCoverage.scan_hammer_test_files(["zig", "zig/runtime"], repo)
        loops, issues = WaitLoopCoverage.parse_loops(source_files, repo)
        covers = WaitLoopCoverage.parse_covers(test_files, repo)
        {
          issues: issues,
          loop_tags: loops.map(&:tag).to_set,
          cover_tags: covers.map(&:tag).to_set
        }
      end

      def source_line(repo, path, line)
        file = File.join(repo, path)
        return "" unless File.file?(file)

        File.readlines(file)[line.to_i - 1].to_s.rstrip
      end

      def hazard_site(site, hazard_type)
        policy = FactMineProviderHelper.hazard_policy(hazard_type)
        raise "hazard site #{hazard_type.inspect} has no hazard-contract policy" unless policy

        {
          path: site[:file],
          line: site[:line],
          source: site[:source].to_s.strip,
          hazard_type: hazard_type,
          required_evidence: policy.fetch("evidence_provider"),
          label: policy.fetch("label"),
          hazard_kind: policy.fetch("kind"),
          coverage_required: policy.fetch("coverage_required"),
          report_required: policy.fetch("report_required"),
          evidence_claim: policy.fetch("evidence_claim")
        }
      end
    end
  end
end
