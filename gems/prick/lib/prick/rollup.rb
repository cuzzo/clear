# frozen_string_literal: true

require_relative "classifier"
# Consume the sibling fix-cache gem for the churn signal -- do NOT
# re-derive it (boundary discipline: own categorization, consume churn).
require_relative "../../../fix-cache/lib/fix_cache"

module Prick
  # Per-file categorical rollup + the one genuinely-new signal:
  # genuine-reachable arms x fix-churn = "bugs highly likely HERE".
  module Rollup
    ACTION = {
      type_norm:  "type/nil guard -> likely removable; CONFIRM with nil-kill (typed contract kills the cluster)",
      dead:       "decision never executes -> audit as dead code, delete (complexity down)",
      defensive:  "inert / invariant-pinned -> accept + annotate, drop from denominator",
      ffi:        "extern/require/module -> a few targeted .cht",
      diagnostic: "raises -> one negative unit spec (fuzz cannot reach)",
      genuine:    "REAL reachable gap -> test it; if in churn-hot code, bug-likely"
    }.freeze
    CATS = ACTION.keys.freeze

    module_function

    # files: repo-relative .rb paths to triage (e.g. the fix-cache
    # hotspots). repo: absolute root. resultset: SimpleCov json.
    # Returns { per_file:, totals:, bug_likely: }.
    def run(files:, repo:, resultset:)
      repo = File.realpath(repo)
      churn = begin
        FixCache::Bugspots.from_git(repo)
      rescue StandardError
        {}
      end
      mx = churn.values.max
      mx = 1.0 if mx.nil? || mx.zero?

      per_file = {}
      bug_likely = []
      files.each do |rel|
        abs = File.join(repo, rel)
        next unless File.exist?(abs)

        arms = Classifier.classify_file(resultset, abs)
        next if arms.empty?

        counts = Hash.new(0)
        arms.each { |a| counts[a.category] += 1 }
        total = arms.size
        cn = (churn[rel] || 0.0) / mx
        per_file[rel] = {
          total: total,
          pct: CATS.to_h { |c| [c, total.zero? ? 0 : (100.0 * counts[c] / total).round(1)] },
          counts: counts,
          churn_norm: cn.round(3)
        }
        # the new signal: genuine arms weighted by the file's fix-churn
        gen = arms.select { |a| a.category == :genuine }
        next if gen.empty?

        bug_likely << {
          file: rel, genuine: gen.size, churn_norm: cn.round(3),
          score: (gen.size * cn).round(3),
          sites: gen.first(8).map { |a| "#{a.file}:#{a.defn}:#{a.line}" }
        }
      end

      totals = Hash.new(0)
      per_file.each_value { |h| h[:counts].each { |c, n| totals[c] += n } }
      {
        per_file: per_file,
        totals: totals,
        grand: totals.values.sum,
        bug_likely: bug_likely.sort_by { |h| -h[:score] }
      }
    end
  end
end
