# frozen_string_literal: true

require "json"
require_relative "bugspots"
require_relative "coverage_data"
require_relative "coverage_gap"
require_relative "decomplex_risk"
require_relative "hotspot"
require_relative "lineage_risk"
require_relative "method_gap"
require_relative "mutation_facts"
require_relative "test_exposure_facts"
sibling_sarif = ::File.expand_path("../../../decomplex/lib/decomplex/sarif", __dir__)
if ::File.file?("#{sibling_sarif}.rb")
  require sibling_sarif
else
end

module Boobytrap
  # Single markdown report, structured like decomplex / nil-kill: TOC,
  # prioritization, ranked sections, run summary. A ranking to triage
  # top-down, NOT a verdict -- a hotspot is "look here first," not
  # "this is a bug."
  class Report
    # only: array of repo-relative path prefixes (e.g. ["src/"]). The
    # global fix-history time span is deliberately UNCHANGED -- recency
    # weighting stays consistent with the whole project; we only filter
    # WHICH files are ranked. Empty = whole repo.
    def initialize(repo:, resultset:, fix_re: Bugspots::FIX_RE, top: 40, only: [], files: [],
                   mutation: nil, test_exposure: nil, exclude: [], lineage: nil,
                   lineage_command: nil)
      @repo = ::File.realpath(repo)
      @top = top
      @only = Array(only).map { |p| p.sub(%r{\A\./}, "").chomp("/") }.reject(&:empty?)
      @files = normalize_file_scope(files)
      @exclude = Array(exclude)
      @mutation_facts = MutationFacts.load(mutation, root: @repo)
      @test_exposure_facts = TestExposureFacts.load(test_exposure, root: @repo)
      @lineage = LineageRisk.load(
        lineage,
        repo: @repo,
        only: @only,
        top: [top.to_i * 10, 200].max,
        command: lineage_command,
        current_only: true
      )
      events = Bugspots.events_from_git(@repo, fix_re: fix_re)
      @fix_commits = events.size
      scores = filter_paths(Bugspots.score(events))
      @fix_scores = scores
      @fix_max = [scores.values.max || 0.0, 1.0].max
      @blast_radius = filter_blast(Bugspots.blast_radius(events))
      source_files = current_source_files
      coverage = resultset ? CoverageData.load(resultset, root: @repo) : nil
      has_coverage = coverage && !coverage.empty?
      covered_files = if has_coverage
                        filter_paths(coverage.covered_files(root: @repo).to_h { |rel| [rel, true] }).keys.select do |rel|
                          source_file?(rel, parser: "tree_sitter")
                        end
                      else
                        []
                      end
      gaps = has_coverage ? filter_paths(CoverageGap.from_coverage(coverage, root: @repo)) : {}
      if DecomplexRisk.tree_sitter?
        static_gaps = filter_paths(CoverageGap.from_static(source_files - covered_files, root: @repo))
        gaps = static_gaps.merge(gaps)
      end
      @gaps = gaps
      @have_cov = has_coverage || !gaps.empty?
      @coverage_mode = coverage_mode(coverage, source_files, gaps)
      @ranked, @unmeasured = Hotspot.rank(scores, gaps)
      @method_gaps =
        if has_coverage || DecomplexRisk.tree_sitter?
          static_files = DecomplexRisk.tree_sitter? ? (source_files - covered_files) : []
          method_files = (covered_files + static_files).uniq
          decomplex_scores = DecomplexRisk.score(
            method_files.map { |rel| ::File.join(@repo, rel) },
            root: @repo
          )
          result_rows = if has_coverage
                          MethodGap.from_coverage(
                            coverage,
                            root: @repo,
                            decomplex_scores: decomplex_scores
                          )
                        else
                          []
                        end
          static_rows = MethodGap.from_static(
            static_files,
            root: @repo,
            decomplex_scores: decomplex_scores
          )
          filter_paths((result_rows + static_rows).group_by(&:file)).values.flatten
        else
          []
        end
      apply_empirical_method_risk!(@method_gaps)
      apply_lineage_method_risk!(@method_gaps)
      @state_branch_hotspots = build_state_branch_hotspots(coverage)
    end

    def in_scope?(rel)
      return false if excluded_path?(rel)
      return false if @files.any? && !@files.include?(rel)
      return true if @only.empty?

      @only.any? { |p| rel == p || rel.start_with?("#{p}/") }
    end

    def filter_paths(hash)
      hash.select { |rel, _| in_scope?(rel) && current_file?(rel) }
    end

    def filter_blast(rows)
      rows.select { |row| in_scope?(row.file) && current_file?(row.file) }
    end

    def current_file?(rel)
      ::File.file?(::File.join(@repo, rel))
    end

    def current_source_files
      files = []
      return @files.select { |rel| current_file?(rel) && source_file?(rel) } if @files.any?

      IO.popen(["git", "-C", @repo, "ls-files"], &:read).to_s.each_line do |line|
        rel = line.strip
        next if rel.empty?
        next unless in_scope?(rel) && current_file?(rel)
        next unless source_file?(rel)

        files << rel
      end
      files
    rescue StandardError
      Dir.chdir(@repo) do
        Dir["**/*"].select do |rel|
          in_scope?(rel) && source_file?(rel)
        end
      end
    end

    def normalize_file_scope(files)
      Array(files).flat_map { |value| value.to_s.split(",") }
                  .map { |path| normalize_scope_path(path) }
                  .reject(&:empty?)
                  .uniq
    end

    def normalize_scope_path(path)
      raw = path.to_s.strip.tr("\\", "/").sub(%r{\A\./}, "")
      return "" if raw.empty?

      if raw.start_with?("/")
        expanded = ::File.expand_path(raw).tr("\\", "/")
        root = "#{@repo.tr('\\', '/')}/"
        return expanded[root.length..].to_s if expanded.start_with?(root)
      end
      raw.chomp("/")
    end

    def source_file?(rel, parser: nil)
      DecomplexRisk.source_file?(rel, root: @repo, parser: parser, exclude: @exclude)
    end

    def excluded_path?(rel)
      DecomplexRisk.excluded_path?(rel, root: @repo, exclude: @exclude)
    end

    def coverage_mode(coverage, source_files, gaps)
      has_coverage = coverage && !coverage.empty?
      static = DecomplexRisk.tree_sitter? && source_files.any?
      return "#{coverage.label} + tree-sitter static fallback" if has_coverage && static
      return "tree-sitter static fallback" if static && !has_coverage
      return coverage.label if has_coverage
      return "absent" if gaps.empty?

      "unknown"
    end

    def to_markdown
      o = markdown_header
      o << markdown_prioritization
      o << markdown_hotspots
      o << markdown_dark_methods
      o << markdown_state_branch_hotspots
      o << markdown_blast_radius
      o << markdown_lineage
      o << markdown_unmeasured
      o << markdown_summary
      o
    end

    private

    def markdown_header
      o = +"# Boobytrap Report\n\n"
      o << "> Defect-risk hotspots: recurring bug-fix locality " \
           "(bugspots, time-decayed) x branch-coverage gap.\n" \
           "> A ranking to triage **top-down**, never a verdict. A\n" \
           "> hotspot is \"the code most likely to be a bug source,\"\n" \
           "> not \"a bug.\"\n\n"

      o << "## Table of Contents\n"
      o << "- [Project Prioritization](#project-prioritization)\n"
      o << "- [Hotspots (#{@ranked.size})](#hotspots-#{@ranked.size})\n"
      o << "- [Mostly Uncovered Methods (#{dark_method_count})]" \
           "(#mostly-uncovered-methods-#{dark_method_count})\n"
      o << "- [State-Based Branch Hotspots (#{@state_branch_hotspots.size})]" \
           "(#statebased-branch-hotspots-#{@state_branch_hotspots.size})\n"
      o << "- [Multi-File Fix Blast Radius (#{@blast_radius.size})]" \
           "(#multifile-fix-blast-radius-#{@blast_radius.size})\n"
      o << "- [Lineage Unit Risk (#{@lineage[:units].size})]" \
           "(#lineage-unit-risk-#{@lineage[:units].size})\n"
      o << "- [Fixed But Unmeasured (#{@unmeasured.size})]" \
           "(#fixed-but-unmeasured-#{@unmeasured.size})\n"
      o << "- [Run Summary](#run-summary)\n\n"
      o
    end

    def markdown_prioritization
      o = +"## Project Prioritization\n"
      if @ranked.empty?
        o << "_No hotspots: no fix-churn x coverage-gap overlap found._\n\n"
      else
        top = @ranked.first
        cutoff = top.hotspot * 0.5
        near = @ranked.count { |r| r.hotspot >= cutoff }
        o << "- The single highest-risk file is **`#{top.file}`** " \
             "(hotspot=#{top.hotspot}: fix_norm=#{top.fix_norm}, " \
             "branch gap=#{(top.gap * 100).round(1)}%).\n"
        o << "- #{near} file(s) are within 50% of the top score " \
             "(hotspot >= #{cutoff.round(4)}); triage those first.\n"
        if (first_state_hotspot = @state_branch_hotspots.first)
          o << "- Highest state-based branch hotspot: " \
               "`#{first_state_hotspot[:file]}:#{first_state_hotspot[:method]}` " \
               "(score=#{first_state_hotspot[:risk].round(2)}, " \
               "state branches=#{first_state_hotspot[:decisions]}, " \
               "fix_norm=#{first_state_hotspot[:fix_norm]}, " \
               "branch gap=#{(first_state_hotspot[:branch_gap] * 100).round(1)}%).\n"
        end
        if (first_blast_radius = @blast_radius.first)
          o << "- Highest multi-file fix blast radius: `#{first_blast_radius.file}` " \
               "(score=#{first_blast_radius.score}, avg files/fix=#{first_blast_radius.avg_touched}, " \
               "max=#{first_blast_radius.max_touched}).\n"
        end
        if (first_dark_method = dark_methods.first)
          o << "- Highest empirical method risk: " \
               "`#{first_dark_method.file}:#{first_dark_method.first_line}` `#{first_dark_method.name}` " \
               "(risk=#{first_dark_method.risk.round(2)}, fix_norm=#{first_dark_method.fix_norm}, " \
               "verification=#{first_dark_method.verification_status || 'not supplied'}, " \
               "tests=#{first_dark_method.test_exposure_status || 'not supplied'}).\n"
        end
        if (first_lineage_unit = @lineage[:units].first)
          o << "- Highest lineage unit risk: `#{first_lineage_unit.file}` `#{first_lineage_unit.name}` " \
               "(risk=#{first_lineage_unit.risk_score.round(1)}, fixes=#{first_lineage_unit.fixes}, " \
               "changes=#{first_lineage_unit.changes}, moves=#{first_lineage_unit.moves}).\n"
        end
        unless @have_cov
          o << "- WARNING: no branch-coverage resultset supplied; " \
               "only fix-churn is shown (gap assumed unknown).\n"
        end
        o << "\n"
      end
      o
    end

    def markdown_hotspots
      o = +"## Hotspots (#{@ranked.size})\n"
      o << "_normalized fix-churn x branch-gap; highest = most likely " \
           "defect source._\n\n"
      if @ranked.empty?
        o << "None.\n\n"
      else
        o << "| # | file | hotspot | fix_norm | branch gap | uncovered/total |\n"
        o << "|---|------|---------|----------|-----------|-----------------|\n"
        @ranked.first(@top).each_with_index do |r, i|
          o << "| #{i + 1} | `#{r.file}` | #{r.hotspot} | #{r.fix_norm} " \
               "| #{(r.gap * 100).round(1)}% | #{r.uncovered}/#{r.total_branches} |\n"
        end
        o << "\n- ...(+#{@ranked.size - @top} more)\n" if @ranked.size > @top
        o << "\n"
      end
      o
    end

    def markdown_dark_methods
      o = +"## Mostly Uncovered Methods (#{dark_method_count})\n"
      o << "_non-trivial methods (`>=5` executable lines) with very low line coverage; " \
           "risk = missed lines x gap, Decomplex detector score, " \
           "instance-state writes, dark branches, fix history, mutation " \
           "verification, and named-test exposure when supplied._\n\n"
      if @method_gaps.empty?
        o << "_No line-coverage method data available._\n\n"
      elsif dark_method_count.zero?
        o << "None.\n\n"
      else
        uncovered = @method_gaps.count { |m| m.covered_lines.zero? }
        le10 = @method_gaps.count { |m| m.line_gap >= 0.90 }
        le20 = dark_method_count
        le50 = @method_gaps.count { |m| m.line_gap >= 0.50 }
        o << "- Completely uncovered: #{uncovered}\n"
        o << "- <=10% covered: #{le10}\n"
        o << "- <=20% covered: #{le20}\n"
        o << "- <=50% covered: #{le50}\n\n"
        if empirical_columns?
          o << "| # | method | risk | covered | missed | fix_norm | lineage | decomplex | verification | tests | profile | writes | dark branches |\n"
          o << "|---|--------|------|---------|--------|----------|---------|-----------|--------------|-------|---------|--------|---------------|\n"
        else
          o << "| # | method | risk | covered | missed | fix_norm | lineage | decomplex | findings | writes | dark branches |\n"
          o << "|---|--------|------|---------|--------|----------|---------|-----------|----------|--------|---------------|\n"
        end
        dark_methods.first(@top).each_with_index do |m, i|
          common = "| #{i + 1} | `#{m.file}:#{m.first_line}` `#{m.name}` " \
                   "| #{m.risk.round(2)} | #{m.covered_lines}/#{m.executable_lines} " \
                   "| #{m.missed_lines} | #{m.fix_norm} | #{lineage_cell(m)} | #{m.decomplex_score} "
          if empirical_columns?
            o << common
            o << "| #{m.verification_status || 'not supplied'} " \
              "| #{m.test_exposure_status || 'not supplied'} " \
              "| #{empirical_profile(m)} " \
              "| #{m.state_writes} "
            o << "| #{m.uncovered_branches} |\n"
          else
            o << common
            o << "| #{m.decomplex_findings} | #{m.state_writes} | #{m.uncovered_branches} |\n"
          end
        end
        o << "\n- ...(+#{dark_method_count - @top} more)\n" if dark_method_count > @top
        o << "\n"
      end
      o
    end

    def markdown_state_branch_hotspots
      o = +"## State-Based Branch Hotspots (#{@state_branch_hotspots.size})\n"
      o << "_Decomplex state-based branch density joined with fix-cache and branch coverage. " \
           "These are branches over mutable/object state that are uncovered and/or historically fixed._\n\n"
      if @state_branch_hotspots.empty?
        o << "None.\n\n"
      else
        o << "| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |\n"
        o << "|---|--------|------|----------------|------|----------|------------|----------|---------------|\n"
        @state_branch_hotspots.first(@top).each_with_index do |h, idx|
          o << "| #{idx + 1} | `#{h[:file]}:#{h[:method]}` | #{h[:risk].round(2)} | " \
               "#{h[:decisions]} | `#{h[:state_refs].first(5).join(' | ')}` | " \
               "#{h[:fix_norm]} | #{(h[:branch_gap] * 100).round(1)}% | " \
               "#{(h[:line_gap] * 100).round(1)}% | #{h[:dark_branches]} |\n"
        end
        o << "\n- ...(+#{@state_branch_hotspots.size - @top} more)\n" if @state_branch_hotspots.size > @top
        o << "\n"
      end
      o
    end

    def markdown_blast_radius
      o = +"## Multi-File Fix Blast Radius (#{@blast_radius.size})\n"
      o << "_Time-decayed fix commits where a file repeatedly changes with many other files. " \
           "High rows are bug fixes whose blast radius is cross-module, not local._\n\n"
      if @blast_radius.empty?
        o << "None.\n\n"
      else
        o << "| # | file | score | fixes | avg files/fix | max files | top co-touched files |\n"
        o << "|---|------|-------|-------|---------------|-----------|----------------------|\n"
        @blast_radius.first(@top).each_with_index do |row, idx|
          partners = row.partners.map { |file, score| "#{file} (#{score})" }.join("; ")
          o << "| #{idx + 1} | `#{row.file}` | #{row.score} | #{row.fixes} | " \
               "#{row.avg_touched} | #{row.max_touched} | #{partners} |\n"
        end
        o << "\n- ...(+#{@blast_radius.size - @top} more)\n" if @blast_radius.size > @top
        o << "\n"
      end
      o
    end

    def markdown_lineage
      o = +"## Lineage Unit Risk (#{@lineage[:units].size})\n"
      o << "_Optional Lineage SQLite overlay: time-decayed semantic `FIX`/`CHANGE` " \
           "events at logical-unit granularity. Pure moves are shown but do not add risk._\n\n"
      if @lineage[:status] != :ok
        o << "_No Lineage database supplied._\n\n"
      elsif @lineage[:units].empty?
        o << "None.\n\n"
      else
        o << "| # | unit | risk | fixes | changes | moves | events |\n"
        o << "|---|------|------|-------|---------|-------|--------|\n"
        @lineage[:units].first(@top).each_with_index do |unit, idx|
          o << "| #{idx + 1} | `#{unit.file}` `#{unit.name}` | " \
               "#{unit.risk_score.round(1)} | #{unit.fixes} | #{unit.changes} | " \
               "#{unit.moves} | #{unit.total_events} |\n"
        end
        o << "\n- ...(+#{@lineage[:units].size - @top} more)\n" if @lineage[:units].size > @top
        o << "\n"
      end
      o
    end

    def markdown_unmeasured
      o = +"## Fixed But Unmeasured (#{@unmeasured.size})\n"
      o << "_files with recurring fixes but NO branch-coverage data -- " \
           "recurring-fix code the corpus does not measure at all; " \
           "itself a risk._\n\n"
      if @unmeasured.empty?
        o << "None.\n\n"
      else
        @unmeasured.first(@top).each do |h|
          o << "- `#{h[:file]}` (fix_norm=#{h[:fix_norm]})\n"
        end
        o << "\n"
      end
      o
    end

    def markdown_summary
      o = +"## Run Summary\n"
      o << "- Repo: `#{@repo}`\n"
      o << "- Scope: #{scope_label}\n"
      o << "- Fix commits matched: #{@fix_commits} (time span over whole history, unfiltered)\n"
      o << "- Files ranked: #{@ranked.size}; fixed-but-unmeasured: " \
           "#{@unmeasured.size}\n"
      o << "- State-based branch hotspots: #{@state_branch_hotspots.size}; " \
           "multi-file fix blast rows: #{@blast_radius.size}\n"
      o << "- Branch-coverage resultset: " \
           "#{@have_cov ? @coverage_mode : 'ABSENT (fix-churn only)'}\n"
      o << "- Mutation facts: #{@mutation_facts.active? ? @mutation_facts.label : 'not supplied'}\n"
      o << "- Test exposure facts: " \
           "#{test_exposure_label}\n"
      o << "- Lineage DB: #{@lineage[:status] == :ok ? @lineage[:label] : 'not supplied'}\n"
      o << "- Method: vendored bugspots " \
           "([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) " \
           "x normalized coverage branch gap; method gaps use Decomplex detector scores, " \
           "fix history, mutation verification, and named-test exposure when supplied " \
           "(see [docs/agents/design.md](docs/agents/design.md))\n"
      o
    end

    public

    def to_json(*_args)
      to_sarif
    end

    def to_sarif
      JSON.pretty_generate(to_sarif_hash)
    end

    def to_sarif_hash
      Decomplex::Sarif.document(
        tool_name: "Boobytrap",
        information_uri: "https://github.com/codeforreno/litedb",
        rules: sarif_rules,
        results: sarif_results,
        properties: {
          "format" => "boobytrap.report.sarif.v1",
          "summary" => sarif_summary
        }
      )
    end

    def sarif_rules
      [
        Decomplex::Sarif.rule(
          id: "boobytrap.file-hotspot",
          name: "File Hotspot",
          short_description: "Time-decayed fix churn overlaps with branch coverage gap"
        ),
        Decomplex::Sarif.rule(
          id: "boobytrap.dark-method",
          name: "Mostly Uncovered Method",
          short_description: "Non-trivial method has very low executable line coverage"
        ),
        Decomplex::Sarif.rule(
          id: "boobytrap.state-branch-hotspot",
          name: "State Branch Hotspot",
          short_description: "State-based branch density overlaps with fix history or coverage gaps"
        ),
        Decomplex::Sarif.rule(
          id: "boobytrap.fix-blast-radius",
          name: "Fix Blast Radius",
          short_description: "File repeatedly participates in multi-file bug fixes",
          default_level: "note"
        ),
        Decomplex::Sarif.rule(
          id: "boobytrap.lineage-unit-risk",
          name: "Lineage Unit Risk",
          short_description: "Logical unit has decayed semantic change/fix risk",
          default_level: "note"
        ),
        Decomplex::Sarif.rule(
          id: "boobytrap.fixed-unmeasured",
          name: "Fixed But Unmeasured",
          short_description: "Historically fixed source file has no branch coverage data"
        )
      ]
    end


    def sarif_results
      hotspot_results + dark_method_results + state_branch_results +
        blast_radius_results + lineage_results + unmeasured_results
    end

    def hotspot_results
      @ranked.first(@top).map do |row|
        Decomplex::Sarif.result(
          rule_id: "boobytrap.file-hotspot",
          level: row.hotspot.to_f.positive? ? "warning" : "note",
          message: "file hotspot: #{row.file} hotspot=#{row.hotspot} branch_gap=#{row.gap}",
          path: row.file,
          line: 1,
          properties: row.to_h.merge("source_format" => "boobytrap.report.v1")
        )
      end
    end

    def dark_method_results
      dark_methods.first(@top).map do |row|
        Decomplex::Sarif.result(
          rule_id: "boobytrap.dark-method",
          level: "warning",
          message: "mostly uncovered method: #{row.file}:#{row.first_line} #{row.name} risk=#{row.risk.round(2)}",
          path: row.file,
          line: row.first_line,
          end_line: row.last_line,
          properties: row_to_hash(row).merge(
            "dark_arm" => row.uncovered_branches.to_i.positive?,
            "source_format" => "boobytrap.report.v1"
          )
        )
      end
    end

    def state_branch_results
      @state_branch_hotspots.first(@top).map do |row|
        Decomplex::Sarif.result(
          rule_id: "boobytrap.state-branch-hotspot",
          level: "warning",
          message: "state branch hotspot: #{row[:file]} #{row[:method]} risk=#{row[:risk].round(2)}",
          path: row[:file],
          line: state_branch_line(row),
          properties: stringify_hash(row).merge("source_format" => "boobytrap.report.v1")
        )
      end
    end

    def blast_radius_results
      @blast_radius.first(@top).map do |row|
        Decomplex::Sarif.result(
          rule_id: "boobytrap.fix-blast-radius",
          level: "note",
          message: "fix blast radius: #{row.file} score=#{row.score}",
          path: row.file,
          line: 1,
          properties: row_to_hash(row).merge("source_format" => "boobytrap.report.v1")
        )
      end
    end

    def lineage_results
      return [] unless @lineage[:status] == :ok

      @lineage[:units].first(@top).map do |unit|
        Decomplex::Sarif.result(
          rule_id: "boobytrap.lineage-unit-risk",
          level: "note",
          message: "lineage unit risk: #{unit.file} #{unit.name} risk=#{unit.risk_score.round(1)}",
          path: unit.file,
          line: 1,
          properties: row_to_hash(unit).merge("source_format" => "boobytrap.report.v1")
        )
      end
    end

    def unmeasured_results
      @unmeasured.first(@top).map do |row|
        Decomplex::Sarif.result(
          rule_id: "boobytrap.fixed-unmeasured",
          level: "warning",
          message: "fixed but unmeasured: #{row[:file]} fix_norm=#{row[:fix_norm]}",
          path: row[:file],
          line: 1,
          properties: stringify_hash(row).merge("source_format" => "boobytrap.report.v1")
        )
      end
    end


    def sarif_summary
      {
        "repo" => @repo,
        "scope" => { "only" => @only, "files" => @files },
        "fix_commits" => @fix_commits,
        "files_ranked" => @ranked.size,
        "fixed_but_unmeasured" => @unmeasured.size,
        "state_branch_hotspots" => @state_branch_hotspots.size,
        "coverage_mode" => @have_cov ? @coverage_mode : "absent",
        "mutation_facts" => @mutation_facts.active? ? @mutation_facts.label : nil,
        "test_exposure_facts" => test_exposure_label,
        "lineage" => @lineage[:status] == :ok ? @lineage[:label] : nil
      }
    end

    def row_to_hash(row)
      stringify_hash(row.respond_to?(:to_h) ? row.to_h : row)
    end

    def stringify_hash(hash)
      hash.to_h.transform_keys(&:to_s).transform_values do |value|
        case value
        when Symbol then value.to_s
        else value
        end
      end
    end

    def state_branch_line(row)
      parsed = row[:at].to_s.split(":").last
      parsed.to_i.positive? ? parsed.to_i : 1
    end

    def scope_label
      return @files.map { |path| "`#{path}`" }.join(", ") if @files.any?
      return "whole repo" if @only.empty?

      @only.map { |path| "`#{path}/`" }.join(", ")
    end

    def empirical_columns?
      @mutation_facts.active? || @test_exposure_facts.active? || @lineage[:has_test_exposure]
    end

    def empirical_profile(row)
      profiles = [row.risk_profile, row.test_exposure_profile].compact.uniq
      profiles.empty? ? "not supplied" : profiles.join("; ")
    end

    def dark_methods
      @method_gaps.select { |m| m.line_gap >= 0.80 }
                  .sort_by { |m| [-m.risk, -m.missed_lines, m.file, m.first_line] }
    end

    def dark_method_count
      dark_methods.size
    end

    def apply_empirical_method_risk!(rows)
      rows.each do |row|
        fix_norm = (@fix_scores[row.file].to_f / @fix_max).round(3)
        row.fix_norm = fix_norm
        row.risk = (row.risk.to_f * (1.0 + fix_norm)).round(4)
        structural_score = empirical_structural_score(row)
        apply_mutation_risk!(row, structural_score, fix_norm)
        apply_test_exposure_risk!(row, structural_score, fix_norm)
      end
    end

    def apply_mutation_risk!(row, structural_score, fix_norm)
      return unless @mutation_facts.active?

      fact = @mutation_facts.status_for(row.file, row.name)
      row.verification_status = fact.summary
      row.mutation_kill_rate = fact.kill_rate
      row.mutation_gate_status = fact.gate_status
      row.risk_profile = MutationFacts.profile(
        fact,
        active: true,
        complexity: structural_score,
        history: fix_norm,
        coverage_gap: row.line_gap
      )
      row.verification_multiplier = MutationFacts.risk_multiplier(
        fact,
        active: true,
        complexity: structural_score,
        history: fix_norm,
        coverage_gap: row.line_gap
      )
      row.risk = (row.risk * row.verification_multiplier).round(4)
    end

    def apply_test_exposure_risk!(row, structural_score, fix_norm)
      return unless @test_exposure_facts.active?

      fact = @test_exposure_facts.status_for(
        row.file,
        row.name,
        first_line: row.first_line,
        last_line: row.last_line
      )
      row.test_exposure_status = fact.summary
      row.test_exposure_profile = TestExposureFacts.profile(fact, active: true)
      row.distinct_test_count = fact.distinct_test_count
      row.tested_line_count = fact.tested_line_count
      row.tested_branch_count = fact.tested_branch_count
      row.mutant_verified_test_count = fact.mutant_verified_test_count
      row.mutant_killed_test_count = fact.mutant_killed_test_count
      row.test_exposure_multiplier = TestExposureFacts.risk_multiplier(
        fact,
        active: true,
        complexity: structural_score,
        history: fix_norm,
        coverage_gap: row.line_gap
      )
      row.risk = (row.risk * row.test_exposure_multiplier).round(4)
    end

    def apply_lineage_method_risk!(rows)
      return unless @lineage[:status] == :ok

      max = @lineage[:units].map(&:risk_score).max.to_f
      max = 1.0 if max <= 0.0
      rows.each do |row|
        unit = @lineage[:index][[row.file, row.name]]
        next unless unit

        row.lineage_score = unit.risk_score
        row.lineage_fixes = unit.fixes
        row.lineage_changes = unit.changes
        row.lineage_moves = unit.moves
        lineage_norm = unit.risk_score.to_f / max
        row.risk = (row.risk.to_f * (1.0 + lineage_norm)).round(4)
        apply_lineage_test_exposure_risk!(row, unit, row.fix_norm)
      end
    end

    def apply_lineage_test_exposure_risk!(row, unit, fix_norm)
      return if @test_exposure_facts.active?
      return unless unit.test_exposure?

      row.test_exposure_status = LineageRisk.test_exposure_status(unit)
      row.test_exposure_profile = LineageRisk.exposure_profile(unit)
      row.distinct_test_count = unit.current_distinct_tests
      row.tested_line_count = 0
      row.tested_branch_count = 0
      row.mutant_verified_test_count = unit.current_mutant_verified_tests
      row.mutant_killed_test_count = unit.current_mutant_killed_tests
      structural_score = empirical_structural_score(row)
      row.test_exposure_multiplier = LineageRisk.exposure_multiplier(
        unit,
        active: true,
        complexity: structural_score,
        history: fix_norm,
        coverage_gap: row.line_gap
      )
      row.risk = (row.risk * row.test_exposure_multiplier).round(4)
    end

    def lineage_cell(row)
      return "0" unless row.lineage_score.to_f.positive?

      "#{row.lineage_score.round(1)} (f#{row.lineage_fixes}/c#{row.lineage_changes}/m#{row.lineage_moves})"
    end

    def empirical_structural_score(row)
      row.decomplex_score.to_f + row.state_writes.to_i + row.uncovered_branches.to_i
    end

    def build_state_branch_hotspots(coverage)
      files = if coverage && !coverage.empty?
                coverage.covered_files(root: @repo)
              else
                @fix_scores.keys
              end
      files = files.select do |rel|
        in_scope?(rel) && current_file?(rel) &&
          source_file?(rel, parser: "tree_sitter")
      end
      files = current_source_files if DecomplexRisk.tree_sitter? && files.empty?
      findings = DecomplexRisk.state_branch_density(
        files.map { |rel| ::File.join(@repo, rel) },
        root: @repo
      )
      method_index = @method_gaps.to_h { |m| [[m.file, m.name], m] }

      findings.map do |h|
        file = h[:file]
        method = h[:method]
        m = method_index[[file, method]]
        fix_norm = (@fix_scores[file].to_f / @fix_max).round(3)
        branch_gap = @gaps[file]&.gap.to_f
        line_gap = m&.line_gap.to_f
        dark = m&.uncovered_branches.to_i
        risk = h[:score].to_f * (1.0 + fix_norm) *
               (1.0 + branch_gap) * (1.0 + line_gap) *
               (m&.test_exposure_multiplier || 1.0) + dark
        h.merge(
          file: file,
          method: method,
          fix_norm: fix_norm,
          branch_gap: branch_gap,
          line_gap: line_gap,
          dark_branches: dark,
          risk: risk
        )
      end.sort_by { |h| [-h[:risk], -h[:decisions], h[:file], h[:method]] }
    end

    def test_exposure_label
      return @test_exposure_facts.label if @test_exposure_facts.active?
      return "#{@lineage[:label]} (Lineage)" if @lineage[:has_test_exposure]

      "not supplied"
    end
  end
end
