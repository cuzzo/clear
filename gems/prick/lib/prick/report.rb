# frozen_string_literal: true

require_relative "rollup"

module Prick
  # Markdown report, structured like decomplex / fix-cache / nil-kill.
  class Report
    def initialize(files:, repo:, resultset:)
      @repo = repo
      @r = Rollup.run(files: files, repo: repo, resultset: resultset)
    end

    def to_markdown
      o = +"# Prick Report\n\n"
      o << "> Not all coverage gaps are equal. Every dark branch arm\n" \
           "> categorized; the GENUINE arms x fix-churn = where bugs\n" \
           "> are highly likely. Owns categorization; consumes\n" \
           "> fix-cache (churn). type_norm = confirm with nil-kill.\n\n"

      o << "## Table of Contents\n"
      o << "- [Category Rollup](#category-rollup)\n"
      o << "- [Bugs Highly Likely (#{@r[:bug_likely].size})](#bugs-highly-likely-#{@r[:bug_likely].size})\n"
      o << "- [Per-File Breakdown](#per-file-breakdown)\n"
      o << "- [Run Summary](#run-summary)\n\n"

      g = @r[:grand]
      o << "## Category Rollup\n"
      o << "_#{g} dark arms across #{@r[:per_file].size} file(s). " \
           "Most are NOT test targets:_\n\n"
      o << "| category | arms | % | action |\n|---|---|---|---|\n"
      Rollup::CATS.each do |c|
        n = @r[:totals][c].to_i
        pct = g.zero? ? 0 : (100.0 * n / g).round(1)
        o << "| **#{c}** | #{n} | #{pct}% | #{Rollup::ACTION[c]} |\n"
      end
      o << "\n"

      o << "## Bugs Highly Likely (#{@r[:bug_likely].size})\n"
      o << "_genuine reachable gaps in fix-churn-hot code -- triage " \
           "top-down; this is the actionable ~slice:_\n\n"
      if @r[:bug_likely].empty?
        o << "None.\n\n"
      else
        o << "| # | file | genuine arms | churn | score |\n|---|---|---|---|---|\n"
        @r[:bug_likely].first(30).each_with_index do |h, i|
          o << "| #{i + 1} | `#{h[:file]}` | #{h[:genuine]} | " \
               "#{h[:churn_norm]} | #{h[:score]} |\n"
        end
        o << "\n  Top file's genuine sites:\n"
        top = @r[:bug_likely].first
        top[:sites].each { |s| o << "  - #{s}\n" }
        o << "\n"
      end

      o << "## Per-File Breakdown\n\n"
      o << "| file | total | type_norm | dead | defensive | genuine | ffi | diag |\n"
      o << "|---|---|---|---|---|---|---|---|\n"
      @r[:per_file].sort_by { |_, h| -h[:total] }.each do |f, h|
        p = h[:pct]
        o << "| `#{f}` | #{h[:total]} | #{p[:type_norm]}% | #{p[:dead]}% " \
             "| #{p[:defensive]}% | #{p[:genuine]}% | #{p[:ffi]}% | #{p[:diagnostic]}% |\n"
      end
      o << "\n## Run Summary\n"
      o << "- Repo: `#{@repo}`\n"
      o << "- Files triaged: #{@r[:per_file].size}; dark arms: #{g}\n"
      o << "- Owns categorization; consumes fix-cache churn. type_norm " \
           "arms: confirm removable with nil-kill (see docs/agents/design.md)\n"
      o
    end
  end
end
