# frozen_string_literal: true

require_relative "bugspots"
require_relative "coverage_gap"
require_relative "decomplex_risk"
require_relative "hotspot"
require_relative "method_gap"

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
    def initialize(repo:, resultset:, fix_re: Bugspots::FIX_RE, top: 40, only: [])
      @repo = ::File.realpath(repo)
      @top = top
      @only = Array(only).map { |p| p.sub(%r{\A\./}, "").chomp("/") }.reject(&:empty?)
      events = Bugspots.events_from_git(@repo, fix_re: fix_re)
      @fix_commits = events.size
      scores = filter_paths(Bugspots.score(events))
      @fix_scores = scores
      @fix_max = [scores.values.max || 0.0, 1.0].max
      @blast_radius = filter_blast(Bugspots.blast_radius(events))
      gaps =
        if resultset && ::File.exist?(resultset)
          filter_paths(CoverageGap.from_resultset(resultset, root: @repo))
        else
          {}
        end
      @gaps = gaps
      @have_cov = !gaps.empty?
      @ranked, @unmeasured = Hotspot.rank(scores, gaps)
      @method_gaps =
        if resultset && ::File.exist?(resultset)
          method_files = filter_paths(
            MethodGap.covered_files(resultset, root: @repo).to_h { |rel| [rel, true] }
          ).keys
          decomplex_scores = DecomplexRisk.score(
            method_files.map { |rel| ::File.join(@repo, rel) },
            root: @repo
          )
          filter_paths(MethodGap.from_resultset(
            resultset,
            root: @repo,
            decomplex_scores: decomplex_scores
          ).group_by(&:file)).values.flatten
        else
          []
        end
      @state_branch_hotspots = build_state_branch_hotspots(resultset)
    end

    def in_scope?(rel)
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

    def to_markdown
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
      o << "- [Fixed But Unmeasured (#{@unmeasured.size})]" \
           "(#fixed-but-unmeasured-#{@unmeasured.size})\n"
      o << "- [Run Summary](#run-summary)\n\n"

      o << "## Project Prioritization\n"
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
        if (state_branch = @state_branch_hotspots.first)
          o << "- Highest state-based branch hotspot: " \
               "`#{state_branch[:file]}:#{state_branch[:method]}` " \
               "(score=#{state_branch[:risk].round(2)}, " \
               "state branches=#{state_branch[:decisions]}, " \
               "fix_norm=#{state_branch[:fix_norm]}, " \
               "branch gap=#{(state_branch[:branch_gap] * 100).round(1)}%).\n"
        end
        if (blast = @blast_radius.first)
          o << "- Highest multi-file fix blast radius: `#{blast.file}` " \
               "(score=#{blast.score}, avg files/fix=#{blast.avg_touched}, " \
               "max=#{blast.max_touched}).\n"
        end
        unless @have_cov
          o << "- WARNING: no branch-coverage resultset supplied; " \
               "only fix-churn is shown (gap assumed unknown).\n"
        end
        o << "\n"
      end

      o << "## Hotspots (#{@ranked.size})\n"
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

      o << "## Mostly Uncovered Methods (#{dark_method_count})\n"
      o << "_non-trivial methods (`>=5` executable lines) with very low line coverage; " \
           "risk = missed lines x gap, plus Decomplex detector score, " \
           "instance-state writes, and dark branches._\n\n"
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
        o << "| # | method | risk | covered | missed | decomplex | findings | writes | dark branches |\n"
        o << "|---|--------|------|---------|--------|-----------|----------|--------|---------------|\n"
        dark_methods.first(@top).each_with_index do |m, i|
          o << "| #{i + 1} | `#{m.file}:#{m.first_line}` `#{m.name}` " \
               "| #{m.risk.round(2)} | #{m.covered_lines}/#{m.executable_lines} " \
               "| #{m.missed_lines} | #{m.decomplex_score} | #{m.decomplex_findings} | #{m.state_writes} " \
               "| #{m.uncovered_branches} |\n"
        end
        o << "\n- ...(+#{dark_method_count - @top} more)\n" if dark_method_count > @top
        o << "\n"
      end

      o << "## State-Based Branch Hotspots (#{@state_branch_hotspots.size})\n"
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

      o << "## Multi-File Fix Blast Radius (#{@blast_radius.size})\n"
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

      o << "## Fixed But Unmeasured (#{@unmeasured.size})\n"
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

      o << "## Run Summary\n"
      o << "- Repo: `#{@repo}`\n"
      o << "- Scope: #{@only.empty? ? 'whole repo' : @only.map { |p| "`#{p}/`" }.join(', ')}\n"
      o << "- Fix commits matched: #{@fix_commits} (time span over whole history, unfiltered)\n"
      o << "- Files ranked: #{@ranked.size}; fixed-but-unmeasured: " \
           "#{@unmeasured.size}\n"
      o << "- State-based branch hotspots: #{@state_branch_hotspots.size}; " \
           "multi-file fix blast rows: #{@blast_radius.size}\n"
      o << "- Branch-coverage resultset: " \
           "#{@have_cov ? 'present' : 'ABSENT (fix-churn only)'}\n"
      o << "- Method: vendored bugspots " \
           "([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) " \
           "x SimpleCov branch gap; method gaps use Decomplex detector scores " \
           "(see [docs/agents/design.md](docs/agents/design.md))\n"
      o
    end

    def dark_methods
      @method_gaps.select { |m| m.line_gap >= 0.80 }
                  .sort_by { |m| [-m.risk, -m.missed_lines, m.file, m.first_line] }
    end

    def dark_method_count
      dark_methods.size
    end

    def build_state_branch_hotspots(resultset)
      files = if resultset && ::File.exist?(resultset)
                MethodGap.covered_files(resultset, root: @repo)
              else
                @fix_scores.keys
              end
      files = files.select { |rel| in_scope?(rel) && current_file?(rel) }
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
               (1.0 + branch_gap) * (1.0 + line_gap) + dark
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
  end
end
