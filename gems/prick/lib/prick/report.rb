# frozen_string_literal: true

require_relative "rollup"
require "pathname"

module Prick
  # Markdown report. Leads with the actionable artifact: the top true
  # gaps, repo-relative + linked, ranked by fix-cache churn score.
  class Report
    # link_base: the directory the markdown will be SAVED in, so link
    # hrefs resolve correctly (a report at gems/prick/report.md must
    # link ../../src/x.rb, not src/x.rb). Defaults to repo root
    # (correct for stdout / a root-level report).
    def initialize(files:, repo:, resultset:, ffi_boundary: [], top: 50,
                   link_base: nil)
      @repo = File.realpath(repo)
      @top = top
      @link_root = Pathname.new(File.expand_path(link_base || @repo))
      @r = Rollup.run(files: files, repo: repo, resultset: resultset,
                      ffi_boundary: ffi_boundary)
    end

    # href from the report's directory to a repo-relative source file.
    def href(rel_file)
      Pathname.new(File.join(@repo, rel_file))
              .relative_path_from(@link_root).to_s
    end

    def to_markdown
      gaps = @r[:top_gaps]
      g = @r[:grand]
      o = +"# Prick Report\n\n"
      o << "> Top true coverage gaps to test, ranked by fix-churn.\n" \
           "> Every dark branch arm is categorized; only the GENUINE\n" \
           "> reachable ones are gaps worth testing. Owns\n" \
           "> categorization; consumes fix-cache for churn.\n\n"

      o << "## Top True Gaps (#{gaps.size}) — test these, ranked by fix-churn\n\n"
      if gaps.empty?
        o << "None.\n\n"
      else
        o << "| # | gap | method | churn |\n|---|---|---|---|\n"
        gaps.first(@top).each_with_index do |x, i|
          link = "[`#{x[:file]}:#{x[:line]}`](#{href(x[:file])}#L#{x[:line]})"
          o << "| #{i + 1} | #{link} | `#{x[:method]}` | #{x[:churn]} |\n"
        end
        o << "\n- ...(+#{gaps.size - @top} more genuine gaps)\n" if gaps.size > @top
        o << "\n"
      end

      o << "## Category Summary\n"
      o << "_#{g} dark arms; only #{gaps.size} are genuine gaps. " \
           "The rest are not test targets:_\n\n"
      o << "| category | arms | % | what it means |\n|---|---|---|---|\n"
      Rollup::CATS.each do |c|
        n = @r[:totals][c].to_i
        pct = g.zero? ? 0 : (100.0 * n / g).round(1)
        o << "| #{c} | #{n} | #{pct}% | #{Rollup::ACTION[c]} |\n"
      end

      o << "\n## Run Summary\n"
      o << "- Repo: `#{@repo}`\n"
      o << "- Files: #{@r[:per_file].size}; dark arms: #{g}; " \
           "genuine gaps: #{gaps.size}\n"
      o << "- General engine: categorizes uncovered branches, ranks " \
           "genuine gaps by consumed fix-cache churn. Project lexicon " \
           "(external-boundary methods) is caller-supplied, not baked " \
           "in (see docs/agents/design.md).\n"
      o
    end
  end
end
