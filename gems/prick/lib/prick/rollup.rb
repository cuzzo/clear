# frozen_string_literal: true

require_relative "classifier"
# Consume the sibling fix-cache gem for the churn signal -- do NOT
# re-derive it (boundary: own categorization, consume churn).
require_relative "../../../fix-cache/lib/fix_cache"

module Prick
  # Per-file categorical totals + the headline artifact: every GENUINE
  # reachable gap, repo-relative, ranked by the file's fix-cache churn
  # score. "Here are the top N true gaps to test."
  module Rollup
    # Generic vocabulary -- NO repo jargon. Recommended-action text is
    # testing-strategy-neutral; the consuming project decides what a
    # "negative test" / "integration test" concretely is.
    ACTION = {
      type_norm:  "type/nil guard -- likely dead if the contract were strictly typed",
      dead:       "decision never executes -- audit as dead code, delete",
      defensive:  "inert / invariant-pinned -- accept, exclude from denominator",
      ffi:        "external/boundary call -- needs an integration test",
      diagnostic: "error/raise path -- reachable only by invalid input (negative test)",
      genuine:    "real reachable gap -- test it; ranked by fix-churn below"
    }.freeze
    CATS = ACTION.keys.freeze

    module_function

    # files: repo-relative .rb paths. repo: absolute root. resultset:
    # SimpleCov json. ffi_boundary: caller-supplied lexicon (the gem
    # ships NONE -- it is general; the consuming repo provides its own).
    def run(files:, repo:, resultset:, ffi_boundary: [])
      repo = File.realpath(repo)
      churn = begin
        FixCache::Bugspots.from_git(repo)
      rescue StandardError
        {}
      end
      mx = churn.values.max
      mx = 1.0 if mx.nil? || mx.zero?

      per_file = {}
      gaps = []
      files.each do |rel|
        abs = File.join(repo, rel)
        next unless File.exist?(abs)

        arms = Classifier.classify_file(resultset, abs, ffi_boundary: ffi_boundary)
        next if arms.empty?

        counts = Hash.new(0)
        arms.each { |a| counts[a.category] += 1 }
        cn = ((churn[rel] || 0.0) / mx).round(4)
        per_file[rel] = { total: arms.size, counts: counts, churn: cn }

        arms.each do |a|
          next unless a.category == :genuine

          gaps << { file: rel, line: a.line, method: a.defn, churn: cn }
        end
      end

      totals = Hash.new(0)
      per_file.each_value { |h| h[:counts].each { |c, n| totals[c] += n } }
      {
        per_file: per_file,
        totals: totals,
        grand: totals.values.sum,
        # the headline: true gaps ranked by fix-cache score, then
        # file/line for stable order.
        top_gaps: gaps.sort_by { |g| [-g[:churn], g[:file], g[:line]] }
      }
    end
  end
end
