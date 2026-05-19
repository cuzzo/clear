# frozen_string_literal: true

require_relative "bugspots"
require_relative "coverage_gap"
require_relative "hotspot"

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
      gaps =
        if resultset && ::File.exist?(resultset)
          filter_paths(CoverageGap.from_resultset(resultset, root: @repo))
        else
          {}
        end
      @have_cov = !gaps.empty?
      @ranked, @unmeasured = Hotspot.rank(scores, gaps)
    end

    def in_scope?(rel)
      return true if @only.empty?

      @only.any? { |p| rel == p || rel.start_with?("#{p}/") }
    end

    def filter_paths(hash)
      return hash if @only.empty?

      hash.select { |rel, _| in_scope?(rel) }
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
      o << "- Branch-coverage resultset: " \
           "#{@have_cov ? 'present' : 'ABSENT (fix-churn only)'}\n"
      o << "- Method: vendored bugspots " \
           "([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) " \
           "x SimpleCov branch gap; file granularity; zero deps " \
           "(see [docs/agents/design.md](docs/agents/design.md))\n"
      o
    end
  end
end
