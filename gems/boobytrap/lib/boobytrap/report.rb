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
    attr_reader :fix_scores

    HEADER_TEXT = "# Boobytrap Report\n\n" \
                  "> Defect-risk hotspots: recurring bug-fix locality " \
                  "(bugspots, time-decayed) x branch-coverage gap.\n" \
                  "> A ranking to triage **top-down**, never a verdict. A\n" \
                  "> hotspot is \"the code most likely to be a bug source,\"\n" \
                  "> not \"a bug.\"\n\n"

    TOC_TEMPLATE = "## Table of Contents\n" \
                   "- [Project Prioritization](#project-prioritization)\n" \
                   "- [Hotspots (%d)](#hotspots-%d)\n" \
                   "- [Mostly Uncovered Methods (%d)](#mostly-uncovered-methods-%d)\n" \
                   "- [State-Based Branch Hotspots (%d)](#statebased-branch-hotspots-%d)\n" \
                   "- [Multi-File Fix Blast Radius (%d)](#multifile-fix-blast-radius-%d)\n" \
                   "- [Lineage Unit Risk (%d)](#lineage-unit-risk-%d)\n" \
                   "- [Fixed But Unmeasured (%d)](#fixed-but-unmeasured-%d)\n" \
                   "- [Run Summary](#run-summary)\n\n"

    HOTSPOTS_INTRO = "## Hotspots (%d)\n" \
                     "_normalized fix-churn x branch-gap; highest = most likely " \
                     "defect source._\n\n"

    DARK_METHODS_INTRO = "## Mostly Uncovered Methods (%d)\n" \
                         "_non-trivial methods (`>=5` executable lines) with very low line coverage; " \
                         "risk = missed lines x gap, Decomplex detector score, " \
                         "instance-state writes, dark branches, fix history, mutation " \
                         "verification, and named-test exposure when supplied._\n\n"

    STATE_BRANCH_INTRO = "## State-Based Branch Hotspots (%d)\n" \
                         "_Decomplex state-based branch density joined with fix-cache and branch coverage. " \
                         "These are branches over mutable/object state that are uncovered and/or historically fixed._\n\n"

    BLAST_RADIUS_INTRO = "## Multi-File Fix Blast Radius (%d)\n" \
                         "_Time-decayed fix commits where a file repeatedly changes with many other files. " \
                         "High rows are bug fixes whose blast radius is cross-module, not local._\n\n"

    LINEAGE_INTRO = "## Lineage Unit Risk (%d)\n" \
                    "_Optional Lineage SQLite overlay: time-decayed semantic `FIX`/`CHANGE` " \
                    "events at logical-unit granularity. Pure moves are shown but do not add risk._\n\n"

    UNMEASURED_INTRO = "## Fixed But Unmeasured (%d)\n" \
                       "_files with recurring fixes but NO branch-coverage data -- " \
                       "recurring-fix code the corpus does not measure at all; " \
                       "itself a risk._\n\n"

    HIGHEST_RISK_TEMPLATE = "- The single highest-risk file is **`%s`** (hotspot=%s: fix_norm=%s, branch gap=%.1f%%).\n"
    NEAR_MATCHES_TEMPLATE = "- %d file(s) are within 50%% of the top score (hotspot >= %.4f); triage those first.\n"
    STATE_HOTSPOT_TEMPLATE = "- Highest state-based branch hotspot: `%s:%s` (score=%.2f, state branches=%d, fix_norm=%.3f, branch gap=%.1f%%).\n"
    BLAST_RADIUS_TEMPLATE = "- Highest multi-file fix blast radius: `%s` (score=%s, avg files/fix=%s, max=%d).\n"
    DARK_METHOD_TEMPLATE  = "- Highest empirical method risk: `%s:%d` `%s` (risk=%.2f, fix_norm=%s, verification=%s, tests=%s).\n"
    LINEAGE_UNIT_TEMPLATE = "- Highest lineage unit risk: `%s` `%s` (risk=%.1f, fixes=%d, changes=%d, moves=%d).\n"
    NO_COVERAGE_WARNING   = "- WARNING: no branch-coverage resultset supplied; only fix-churn is shown (gap assumed unknown).\n"

    SUMMARY_TEMPLATE = "## Run Summary\n" \
                       "- Repo: `%s`\n" \
                       "- Scope: %s\n" \
                       "- Fix commits matched: %d (time span over whole history, unfiltered)\n" \
                       "- Files ranked: %d; fixed-but-unmeasured: %d\n" \
                       "- State-based branch hotspots: %d; multi-file fix blast rows: %d\n" \
                       "- Branch-coverage resultset: %s\n" \
                       "- Mutation facts: %s\n" \
                       "- Test exposure facts: %s\n" \
                       "- Lineage DB: %s\n"

    SUMMARY_METHOD_DESC = "- Method: vendored bugspots " \
                          "([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) " \
                          "x normalized coverage branch gap; method gaps use Decomplex detector scores, " \
                          "fix history, mutation verification, and named-test exposure when supplied " \
                          "(see [docs/agents/design.md](docs/agents/design.md))\n"

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
      o = +HEADER_TEXT

      o << sprintf(TOC_TEMPLATE,
                   @ranked.size, @ranked.size,
                   dark_method_count, dark_method_count,
                   @state_branch_hotspots.size, @state_branch_hotspots.size,
                   @blast_radius.size, @blast_radius.size,
                   @lineage[:units].size, @lineage[:units].size,
                   @unmeasured.size, @unmeasured.size)

      o << "## Project Prioritization\n"
      if @ranked.empty?
        o << "_No hotspots: no fix-churn x coverage-gap overlap found._\n\n"
      else
        first_ranked_hotspot = @ranked.first
        cutoff_score = first_ranked_hotspot.hotspot * 0.5
        near_count = @ranked.count { |r| r.hotspot >= cutoff_score }
        o << sprintf(HIGHEST_RISK_TEMPLATE, first_ranked_hotspot.file, first_ranked_hotspot.hotspot,
                     first_ranked_hotspot.fix_norm, first_ranked_hotspot.gap * 100)
        o << sprintf(NEAR_MATCHES_TEMPLATE, near_count, cutoff_score)
        if (first_state_hotspot = @state_branch_hotspots.first)
          o << sprintf(STATE_HOTSPOT_TEMPLATE, first_state_hotspot[:file], first_state_hotspot[:method],
                       first_state_hotspot[:risk], first_state_hotspot[:decisions],
                       first_state_hotspot[:fix_norm], first_state_hotspot[:branch_gap] * 100)
        end
        if (first_blast_radius = @blast_radius.first)
          o << sprintf(BLAST_RADIUS_TEMPLATE, first_blast_radius.file, first_blast_radius.score,
                       first_blast_radius.avg_touched, first_blast_radius.max_touched)
        end
        if (first_dark_method = dark_methods.first)
          o << sprintf(DARK_METHOD_TEMPLATE, first_dark_method.file, first_dark_method.first_line,
                       first_dark_method.name, first_dark_method.risk, first_dark_method.fix_norm,
                       first_dark_method.verification_status || 'not supplied',
                       first_dark_method.test_exposure_status || 'not supplied')
        end
        if (first_lineage_unit = @lineage[:units].first)
          o << sprintf(LINEAGE_UNIT_TEMPLATE, first_lineage_unit.file, first_lineage_unit.name,
                       first_lineage_unit.risk_score, first_lineage_unit.fixes,
                       first_lineage_unit.changes, first_lineage_unit.moves)
        end
        o << NO_COVERAGE_WARNING unless @have_cov
        o << "\n"
      end

      o << sprintf(HOTSPOTS_INTRO, @ranked.size)
      if @ranked.empty?
        o << "None.\n\n"
      else
        o << "| # | file | hotspot | fix_norm | branch gap | uncovered/total |\n"
        o << "|---|------|---------|----------|-----------|-----------------|\n"
        @ranked.first(@top).each_with_index do |h_row, i|
          o << "| #{i + 1} | `#{h_row.file}` | #{h_row.hotspot} | #{h_row.fix_norm} " \
               "| #{(h_row.gap * 100).round(1)}% | #{h_row.uncovered}/#{h_row.total_branches} |\n"
        end
        o << "\n- ...(+#{@ranked.size - @top} more)\n" if @ranked.size > @top
        o << "\n"
      end

      o << sprintf(DARK_METHODS_INTRO, dark_method_count)
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
        dark_methods.first(@top).each_with_index do |m_row, i|
          common = "| #{i + 1} | `#{m_row.file}:#{m_row.first_line}` `#{m_row.name}` " \
                   "| #{m_row.risk.round(2)} | #{m_row.covered_lines}/#{m_row.executable_lines} " \
                   "| #{m_row.missed_lines} | #{m_row.fix_norm} | #{lineage_cell(m_row)} | #{m_row.decomplex_score} "
          if empirical_columns?
            o << common
            o << "| #{m_row.verification_status || 'not supplied'} " \
              "| #{m_row.test_exposure_status || 'not supplied'} " \
              "| #{empirical_profile(m_row)} " \
              "| #{m_row.state_writes} " \
              "| #{m_row.uncovered_branches} |\n"
          else
            o << common
            o << "| #{m_row.decomplex_findings} | #{m_row.state_writes} | #{m_row.uncovered_branches} |\n"
          end
        end
        o << "\n- ...(+#{dark_method_count - @top} more)\n" if dark_method_count > @top
        o << "\n"
      end

      o << sprintf(STATE_BRANCH_INTRO, @state_branch_hotspots.size)
      if @state_branch_hotspots.empty?
        o << "None.\n\n"
      else
        o << "| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |\n"
        o << "|---|--------|------|----------------|------|----------|------------|----------|---------------|\n"
        @state_branch_hotspots.first(@top).each_with_index do |sb_row, idx|
          o << "| #{idx + 1} | `#{sb_row[:file]}:#{sb_row[:method]}` | #{sb_row[:risk].round(2)} | " \
               "#{sb_row[:decisions]} | `#{sb_row[:state_refs].first(5).join(' | ')}` | " \
               "#{sb_row[:fix_norm]} | #{(sb_row[:branch_gap] * 100).round(1)}% | " \
               "#{(sb_row[:line_gap] * 100).round(1)}% | #{sb_row[:dark_branches]} |\n"
        end
        o << "\n- ...(+#{@state_branch_hotspots.size - @top} more)\n" if @state_branch_hotspots.size > @top
        o << "\n"
      end

      o << sprintf(BLAST_RADIUS_INTRO, @blast_radius.size)
      if @blast_radius.empty?
        o << "None.\n\n"
      else
        o << "| # | file | score | fixes | avg files/fix | max files | top co-touched files |\n"
        o << "|---|------|-------|-------|---------------|-----------|----------------------|\n"
        @blast_radius.first(@top).each_with_index do |br_row, idx|
          partners = br_row.partners.map { |file, score| "#{file} (#{score})" }.join("; ")
          o << "| #{idx + 1} | `#{br_row.file}` | #{br_row.score} | #{br_row.fixes} | " \
               "#{br_row.avg_touched} | #{br_row.max_touched} | #{partners} |\n"
        end
        o << "\n- ...(+#{@blast_radius.size - @top} more)\n" if @blast_radius.size > @top
        o << "\n"
      end

      o << sprintf(LINEAGE_INTRO, @lineage[:units].size)
      if @lineage[:status] != :ok
        o << "_No Lineage database supplied._\n\n"
      elsif @lineage[:units].empty?
        o << "None.\n\n"
      else
        o << "| # | unit | risk | fixes | changes | moves | events |\n"
        o << "|---|------|------|-------|---------|-------|--------|\n"
        @lineage[:units].first(@top).each_with_index do |lu_row, idx|
          o << "| #{idx + 1} | `#{lu_row.file}` `#{lu_row.name}` | " \
               "#{lu_row.risk_score.round(1)} | #{lu_row.fixes} | #{lu_row.changes} | " \
               "#{lu_row.moves} | #{lu_row.total_events} |\n"
        end
        o << "\n- ...(+#{@lineage[:units].size - @top} more)\n" if @lineage[:units].size > @top
        o << "\n"
      end

      o << sprintf(UNMEASURED_INTRO, @unmeasured.size)
      if @unmeasured.empty?
        o << "None.\n\n"
      else
        @unmeasured.first(@top).each do |unm_row|
          o << "- `#{unm_row[:file]}` (fix_norm=#{unm_row[:fix_norm]})\n"
        end
        o << "\n"
      end

      o << sprintf(SUMMARY_TEMPLATE, @repo, scope_label, @fix_commits, @ranked.size, @unmeasured.size,
                   @state_branch_hotspots.size, @blast_radius.size,
                   @have_cov ? @coverage_mode : 'ABSENT (fix-churn only)',
                   @mutation_facts.active? ? @mutation_facts.label : 'not supplied',
                   test_exposure_label,
                   @lineage[:status] == :ok ? @lineage[:label] : 'not supplied')
      o << SUMMARY_METHOD_DESC
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
