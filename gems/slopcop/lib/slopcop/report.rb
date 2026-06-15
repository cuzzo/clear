# frozen_string_literal: true

require_relative "rollup"
require_relative "sarif"
require "json"
require "pathname"
sibling_sarif = File.expand_path("../../../decomplex/lib/decomplex/sarif", __dir__)
if File.file?("#{sibling_sarif}.rb")
  require sibling_sarif
else
  require "decomplex/sarif"
end

module SlopCop
  # Markdown report. Leads with the actionable artifact: the top true
  # gaps, repo-relative + linked, ranked by boobytrap churn score.
  class Report
    # link_base: the directory the markdown will be SAVED in, so link
    # hrefs resolve correctly (a report at gems/slopcop/report.md must
    # link ../../src/x.rb, not src/x.rb). Defaults to repo root
    # (correct for stdout / a root-level report).
    def initialize(files:, repo:, resultset:, ffi_boundary: [],
                   diagnostic_mids: [], top: 50, link_base: nil, mutation: nil,
                   exclude: [])
      @repo = File.realpath(repo)
      @top = top
      @link_root = Pathname.new(File.expand_path(link_base || @repo))
      @r = Rollup.run(files: files, repo: repo, resultset: resultset,
                      ffi_boundary: ffi_boundary,
                      diagnostic_mids: diagnostic_mids,
                      mutation: mutation,
                      exclude: exclude)
    end

    # href from the report's directory to a repo-relative source file.
    def href(rel_file)
      Pathname.new(File.join(@repo, rel_file))
              .relative_path_from(@link_root).to_s
    end

    # A LOUD banner when the decomplex signal was not applied -- so a
    # degraded run is never mistaken for a healthy one (a churn-only
    # report otherwise looks identical). :ok -> no banner.
    def decomplex_banner(status)
      case status
      when :error
        "> ⚠ **decomplex signal UNAVAILABLE** (its run errored this " \
        "invocation). The `spurious` filter and structural-deviance " \
        "ranking were **NOT applied** -- gaps below are churn-only. " \
        "Re-run; if it persists, decomplex has a bug (it asserts its " \
        "own span contract and will name the detector).\n\n"
      when :absent
        "> ⚠ **decomplex not available** -- `spurious` filter and " \
        "structural-deviance ranking **NOT applied**; gaps below are " \
        "churn-only (still valid, just not sharpened).\n\n"
      else
        ""
      end
    end

    def to_markdown
      gaps = @r[:top_gaps]
      g = @r[:grand]
      o = +"# SlopCop Report\n\n"
      o << "> Top true coverage gaps, ranked by fix-churn x structural\n" \
           "> deviance. Every dark arm is categorized; only GENUINE\n" \
           "> reachable ones are gaps. Apex = uncovered AND historically\n" \
           "> churned (boobytrap), structurally deviant (decomplex),\n" \
           "> and weakly verified when mutation facts are supplied.\n" \
           "> Owns categorization; consumes boobytrap (churn) and\n" \
           "> optional decomplex (spurious filter + deviance rank).\n\n"

      o << decomplex_banner(@r[:decomplex_status])

      o << "## Top True Gaps (#{gaps.size}) — test these, ranked by fix-churn\n\n"
      if gaps.empty?
        o << "None.\n\n"
      else
        if @r[:mutation_label]
          o << "| # | gap | method | churn | decomplex deviance | verification | profile |\n" \
               "|---|---|---|---|---|---|---|\n"
        else
          o << "| # | gap | method | churn | decomplex deviance |\n" \
               "|---|---|---|---|---|\n"
        end
        gaps.first(@top).each_with_index do |x, i|
          link = "[`#{x[:file]}:#{x[:line]}`](#{href(x[:file])}#L#{x[:line]})"
          dets = x[:detectors].to_a
          dev = if dets.empty?
                  "-"
                else
                  # † = method-join fallback (no flagged span contained
                  # this arm) -- whole-method, coarser. ⚠ = a
                  # duplication-class finding hit the method but was
                  # NOT localised here: possibly redundant, VERIFY --
                  # deliberately NOT auto-excluded (a coarse signal must
                  # not silently delete a real gap).
                  mark = x[:precise] ? "" : " †"
                  mark += " ⚠dup?" if x[:coarse_dup]
                  "**#{x[:deviance]}**#{mark} (#{dets.first(3).join(', ')}" \
                  "#{dets.size > 3 ? ", +#{dets.size - 3}" : ''})"
                end
          row = "| #{i + 1} | #{link} | `#{x[:method]}` | " \
                "#{x[:churn]} | #{dev} "
          if @r[:mutation_label]
            row << "| #{x[:verification]} | #{x[:risk_profile]} "
          end
          o << "#{row}|\n"
        end
        o << "\n- ...(+#{gaps.size - @top} more genuine gaps)\n" if gaps.size > @top
        o << "\n"
        flagged = gaps.reject { |x| x[:detectors].to_a.empty? }
        unless flagged.empty?
          precise = flagged.count { |x| x[:precise] }
          coarse  = flagged.size - precise
          dup     = flagged.count { |x| x[:coarse_dup] }
          o << "> decomplex attribution on listed gaps: **#{precise} " \
               "span-precise**, **#{coarse} method-coarse (†)**" \
               "#{dup.positive? ? ", **#{dup} ⚠dup?** (possibly " \
               "redundant, not localised -- verify before testing)" : ''}." \
               " Coarse rows are whole-method: treat as a hint, not an " \
               "arm-level discriminator.\n\n"
        end
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
      o << "- Coverage input: #{@r[:coverage_label]}\n" if @r[:coverage_label]
      o << "- Mutation facts: #{@r[:mutation_label] || 'not supplied'}\n"
      unless @r[:sources].to_h.empty?
        source_bits = @r[:sources].sort.map { |source, count| "#{source}=#{count}" }.join(", ")
        o << "- Branch source: #{source_bits}\n"
      end
      o << "- General engine: categorizes uncovered branches, ranks " \
           "genuine gaps by consumed boobytrap churn x optional " \
           "decomplex structural deviance. Project lexicons " \
           "(external-boundary methods and domain diagnostic methods) " \
           "are caller-supplied, not baked in (see docs/agents/design.md).\n"
      o << "- decomplex join is span-precise (the arm's line falls " \
           "inside the flagged decision's source extent); `†` marks a " \
           "(file, method) fallback when no flagged span contained the " \
           "arm. A ranked candidate, not a verdict (Engler discipline).\n"
      o
    end

    def to_h
      {
        "format" => "slopcop.report.v1",
        "summary" => {
          "repo" => @repo,
          "files" => @r[:per_file].size,
          "dark_arms" => @r[:grand],
          "genuine_gaps" => @r[:top_gaps].size,
          "coverage_input" => @r[:coverage_label],
          "mutation_facts" => @r[:mutation_label],
          "decomplex_status" => @r[:decomplex_status].to_s,
          "branch_sources" => stringify_counts(@r[:sources])
        },
        "totals" => stringify_counts(@r[:totals]),
        "per_file" => @r[:per_file].transform_values do |file|
          {
            "total" => file[:total],
            "counts" => stringify_counts(file[:counts]),
            "churn" => file[:churn]
          }
        end,
        "top_gaps" => @r[:top_gaps].map { |gap| stringify_keys(gap) },
        "dark_arms" => @r[:dark_arms].map { |arm| stringify_keys(arm) }
      }
    end

    def to_json(*_args)
      to_sarif
    end

    def to_sarif
      JSON.pretty_generate(to_sarif_hash)
    end

    def to_sarif_hash
      Decomplex::Sarif.document(
        tool_name: "SlopCop",
        information_uri: "https://github.com/codeforreno/litedb",
        rules: sarif_rules,
        results: sarif_results,
        properties: {
          "format" => "slopcop.report.sarif.v1",
          "slopcop.report" => to_h
        }
      )
    end

    def to_sarif
      Sarif.render(self)
    end

    private

    def sarif_rules
      [
        Decomplex::Sarif.rule(
          id: "slopcop.genuine-gap",
          name: "Genuine Coverage Gap",
          short_description: Rollup::ACTION[:genuine]
        )
      ] + Rollup::ACTION.map do |category, description|
        Decomplex::Sarif.rule(
          id: "slopcop.dark-arm.#{category}",
          name: "Dark Arm: #{category}",
          short_description: description,
          default_level: category == :genuine ? "warning" : "note",
          properties: { "category" => category }
        )
      end
    end

    def sarif_results
      top_gap_results + dark_arm_results
    end

    def top_gap_results
      @r[:top_gaps].map do |gap|
        Decomplex::Sarif.result(
          rule_id: "slopcop.genuine-gap",
          level: "warning",
          message: "genuine gap: #{gap[:file]}:#{gap[:line]} #{gap[:method]}",
          path: gap[:file],
          line: gap[:line],
          properties: stringify_keys(gap).merge(
            "dark_arm" => true,
            "category" => "genuine",
            "source_format" => "slopcop.report.v1"
          )
        )
      end
    end

    def dark_arm_results
      @r[:dark_arms].map do |arm|
        category = arm[:category].to_s
        Decomplex::Sarif.result(
          rule_id: "slopcop.dark-arm.#{category}",
          level: category == "genuine" ? "warning" : "note",
          message: arm[:message] || "dark arm: #{category}",
          path: arm[:file],
          line: arm[:line],
          properties: stringify_keys(arm).merge(
            "dark_arm" => true,
            "category" => "dark arm: #{category}",
            "source_format" => "slopcop.report.v1"
          )
        )
      end
    end

    def stringify_counts(counts)
      counts.to_h.transform_keys(&:to_s)
    end

    def stringify_keys(hash)
      hash.to_h.transform_keys(&:to_s).transform_values do |value|
        value.is_a?(Symbol) ? value.to_s : value
      end
    end
  end
end
