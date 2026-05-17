# frozen_string_literal: true

module Boobytrap
  # The join. A hotspot is code that BOTH keeps getting bug-fixed
  # (recurring, recent) AND is under-exercised by the test corpus.
  # hotspot = normalized_fix_score * branch_gap_fraction.
  #
  # Rationale (see docs/agents/design.md): raw complexity is a weak
  # standalone defect predictor; fix-locality is the validated signal;
  # the branch gap says the recurring-fix code is also not pinned by
  # tests -- the highest-probability latent defect surface. Output is
  # a ranked list to triage top-down, never a verdict.
  module Hotspot
    Row = Struct.new(:file, :fix, :fix_norm, :gap, :total_branches,
                      :uncovered, :hotspot, keyword_init: true)

    module_function

    # scores: { relpath => fix_score }   (Bugspots.score)
    # gaps:   { relpath => CoverageGap::File_ }
    # Returns [ranked_rows, fixed_but_unmeasured].
    def rank(scores, gaps)
      max = scores.values.max
      max = 1.0 if max.nil? || max.zero?

      ranked = []
      unmeasured = []
      scores.each do |file, fix|
        fix_norm = fix / max
        g = gaps[file]
        if g.nil?
          unmeasured << { file: file, fix: fix.round(3), fix_norm: fix_norm.round(3) }
          next
        end
        ranked << Row.new(
          file: file, fix: fix.round(3), fix_norm: fix_norm.round(3),
          gap: g.gap.round(3), total_branches: g.total, uncovered: g.uncovered,
          hotspot: (fix_norm * g.gap).round(4)
        )
      end
      [ranked.sort_by { |r| -r.hotspot },
       unmeasured.sort_by { |h| -h[:fix] }]
    end
  end
end
