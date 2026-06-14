# frozen_string_literal: true

require_relative "classifier"
# Consume the sibling boobytrap gem for the churn signal -- do NOT
# re-derive it (boundary: own categorization, consume churn).
require_relative "../../../boobytrap/lib/boobytrap"
# Optionally consume decomplex: the negative `spurious` filter (a gap
# whose decision is redundant -- refactor, don't test) and the
# positive structural-deviance amplifier on genuine gaps. Read-only,
# re-derives nothing, degrades cleanly if decomplex is absent.
require_relative "decomplex_verdict"

module SlopCop
  # Per-file categorical totals + the headline artifact: every GENUINE
  # reachable gap, repo-relative, ranked by the file's boobytrap churn
  # score. "Here are the top N true gaps to test."
  module Rollup
    # Generic vocabulary -- NO repo jargon. Recommended-action text is
    # testing-strategy-neutral; the consuming project decides what a
    # "negative test" / "integration test" concretely is.
    ACTION = {
      type_norm:  "type/null guard -- likely dead if runtime contracts were stricter",
      dead:       "decision never executes in coverage -- audit as missing test or statically-dead code",
      defensive:  "inert / invariant-pinned -- accept, exclude from denominator",
      spurious:   "span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?)",
      ffi:        "external/boundary call -- needs an integration test",
      diagnostic: "language diagnostic/error path -- reachable only by invalid input (negative test)",
      genuine:    "real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance"
    }.freeze
    CATS = ACTION.keys.freeze

    module_function

    # files: repo-relative source paths. repo: absolute root. resultset:
    # any Boobytrap-normalized coverage input. ffi_boundary and
    # diagnostic_mids are caller-supplied project lexicons; language
    # defaults come from Decomplex::Syntax.
    def run(files:, repo:, resultset:, ffi_boundary: [], diagnostic_mids: [],
            mutation: nil, exclude: [])
      repo = File.realpath(repo)
      churn = begin
        Boobytrap::Bugspots.from_git(repo)
      rescue StandardError
        {}
      end
      coverage = if resultset
                   Classifier.coverage_dataset(resultset, root: repo)
                 end
      mx = churn.values.max
      mx = 1.0 if mx.nil? || mx.zero?

      abs_for = {}
      files.each do |file|
        next unless Boobytrap::DecomplexRisk.source_file?(
          file,
          root: repo,
          parser: "tree_sitter",
          exclude: exclude
        )

        a = file.to_s.start_with?("/") ? file.to_s : File.join(repo, file.to_s)
        rel = repo_relative(a, repo)
        abs_for[rel] = a if File.exist?(a)
      end
      # decomplex verdict, keyed [abs, method]. {} if decomplex absent.
      dv = DecomplexVerdict.index(abs_for.values)
      mutation_facts = Boobytrap::MutationFacts.load(mutation, root: repo)

      per_file = {}
      gaps = []
      dark_arms = []
      sources = Hash.new(0)
      abs_for.each do |rel, abs|
        arms = Classifier.classify_file(resultset, abs,
                                        root: repo,
                                        ffi_boundary: ffi_boundary,
                                        diagnostic_mids: diagnostic_mids)
        next if arms.empty?

        cn = ((churn[rel] || 0.0) / mx).round(4)
        counts = Hash.new(0)
        arms.each do |a|
          # span-containment first (the arm's line inside a flagged
          # decision's extent), method-join fallback. nil = decomplex
          # flagged nothing for this arm.
          v = DecomplexVerdict.lookup(dv, abs, a.defn, a.line)
          # `v[:spurious]` is true ONLY on the span-precise path (the
          # arm is literally inside a duplicated/cloned decision) ->
          # safe to exclude as "refactor, not test". A COARSE
          # duplication signal never excludes (it would silently
          # delete a real gap); it stays genuine and is flagged
          # `coarse_dup` for the human to verify. Never override a more
          # specific reason (ffi/diagnostic/type_norm/dead/defensive).
          cat = if a.category == :genuine && v && v[:spurious]
                  :spurious
                else
                  a.category
                end
          counts[cat] += 1
          sources[a.source || :coverage] += 1
          dark_arms << {
            file: rel,
            line: a.line,
            method: a.defn,
            category: cat,
            arm_category: cat,
            source: a.source || :coverage,
            message: "dark arm: #{cat}"
          }
          next unless cat == :genuine

          gaps << { file: rel, line: a.line, method: a.defn, churn: cn,
                    deviance: (v ? v[:deviance] : 0),
                    detectors: (v ? v[:detectors] : []),
                    precise: (v ? v[:precise] : nil),
                    coarse_dup: (v ? v[:coarse_dup] : false),
                    verification_fact: mutation_facts.status_for(rel, a.defn) }
        end
        per_file[rel] = { total: arms.size, counts: counts, churn: cn }
      end

      # apex = uncovered (genuine) AND historically churned AND
      # structurally deviant. Both signals normalized to [0,1] and
      # summed so either alone still ranks by itself; -churn tiebreak
      # keeps behaviour IDENTICAL when decomplex is absent (deviance
      # all 0 -> priority == churn).
      maxd = gaps.map { |x| x[:deviance] }.max.to_i
      maxd = 1 if maxd.zero?
      gaps.each do |x|
        structural = x[:deviance].to_f / maxd
        priority = x[:churn] + structural
        if mutation_facts.active?
          fact = x[:verification_fact]
          x[:verification] = fact.summary
          x[:mutation_kill_rate] = fact.kill_rate
          x[:mutation_gate_status] = fact.gate_status
          x[:risk_profile] = Boobytrap::MutationFacts.profile(
            fact,
            active: true,
            complexity: x[:deviance],
            history: x[:churn],
            coverage_gap: 1.0
          )
          x[:verification_multiplier] = Boobytrap::MutationFacts.risk_multiplier(
            fact,
            active: true,
            complexity: x[:deviance],
            history: x[:churn],
            coverage_gap: 1.0
          )
          priority *= x[:verification_multiplier]
        end
        x.delete(:verification_fact)
        x[:priority] = priority.round(4)
      end

      totals = Hash.new(0)
      per_file.each_value { |h| h[:counts].each { |c, n| totals[c] += n } }
      {
        per_file: per_file,
        totals: totals,
        grand: totals.values.sum,
        # :ok / :error / :absent -- so the report can LOUDLY say the
        # decomplex signal was not applied instead of emitting a
        # churn-only report indistinguishable from a healthy one.
        decomplex_status: dv[:status],
        # the headline: genuine gaps ranked by churn x decomplex
        # deviance, then -churn / file / line for stable order.
        top_gaps: gaps.sort_by do |g|
          [-g[:priority], -g[:churn], g[:file], g[:line]]
        end,
        dark_arms: dark_arms.sort_by do |arm|
          [arm[:file], arm[:line], arm[:method].to_s, arm[:category].to_s]
        end,
        coverage_label: coverage && !coverage.empty? ? coverage.label : nil,
        mutation_label: mutation_facts.active? ? mutation_facts.label : nil,
        sources: sources
      }
    end

    def repo_relative(path, repo)
      root = File.expand_path(repo).tr("\\", "/").chomp("/")
      expanded = File.expand_path(path).tr("\\", "/")
      prefix = "#{root}/"
      expanded.start_with?(prefix) ? expanded[prefix.length..] : path.to_s
    end
  end
end
