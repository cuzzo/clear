# frozen_string_literal: true

# OPTIONAL consumer of the sibling decomplex gem. Mirrors the boobytrap
# churn consumer discipline: require the sibling, READ its published
# verdict, re-derive NOTHING. decomplex owns the findings + their
# locations + spans + tiers (Report#sections_data); SlopCop owns only
# the POLICY for how a coverage gap should react to them. Degrades to
# a blank verdict if decomplex is absent or errors (like churn rescue).
begin
  require_relative "../../../decomplex/lib/decomplex"
  require_relative "../../../decomplex/lib/decomplex/report"
rescue LoadError
  nil
end

module SlopCop
  module DecomplexVerdict
    # SlopCop's interpretation policy (NOT a re-derivation -- decomplex
    # owns the detectors; this is how a coverage gap USES them):
    #
    # SPURIOUS: the decision is duplicated / a clone / a re-derived
    #   predicate. The arm is uncovered because it should not exist as
    #   written. NOT a test target: refactor, do not test.
    # DEVIANCE: the decision is structurally suspect *now* (path missing
    #   a step, half-applied protocol, stale derived state, loose
    #   contract, non-local behaviour). On a GENUINE uncovered arm this
    #   is the "probably-buggy AND untested" amplifier.
    SPURIOUS = ["Missing Abstractions", "Reification Misses",
                "Semantic Predicate Aliases", "Exact Predicate Aliases",
                "Inconsistent Rename Clones",
                "Flay Similarity (Type-2/3)"].freeze
    DEVIANCE = ["Neglected Conditions", "Neglected Path Conditions",
                "Broken Protocols", "Derived-State Staleness",
                "Decision Pressure", "False Simplicity"].freeze

    module_function

    def blank(status)
      { spans: {}, m_all: {}, m_spur: {}, m_devw: {}, status: status }
    end

    # abs_files: absolute paths -- the SAME strings SlopCop classifies,
    # so decomplex finding locations join on (file, method) and the
    # finding SPANS join on the arm's line. Builds, per file, the list
    # of flagged decision spans (precise), AND a (file, method)
    # aggregate (fallback for findings/locations lacking a span).
    def index(abs_files)
      return blank(:absent) unless defined?(Decomplex::Report)
      return blank(:absent) if abs_files.empty?

      sections = Decomplex::Report.new(abs_files).sections_data
      span_recs = Hash.new { |h, k| h[k] = [] }      # file => [rec...]
      m_all  = Hash.new { |h, k| h[k] = {} }         # [f,m] => {title=>1}
      m_spur = Hash.new(false)                       # [f,m] => Bool
      m_devw = Hash.new { |h, k| h[k] = {} }         # [f,m] => {title=>w}

      sections.each do |title, tier, findings|
        next unless findings

        w = Decomplex::Convergence::TIER_WEIGHT.fetch(tier, 1)
        spur = SPURIOUS.include?(title)
        dev  = DEVIANCE.include?(title)
        findings.each do |f|
          sp = f[:spans]
          Decomplex::Convergence.locations(f).each do |loc|
            file, meth, = Decomplex::Convergence.parse_loc(loc)
            next unless file && !file.empty? && meth && !meth.empty?

            key = [file, meth]
            m_all[key][title] = true
            m_spur[key] ||= spur
            m_devw[key][title] = w if dev
            s = sp && sp[loc]
            next unless s

            span_recs[file] << { fl: s[0], ll: s[2], title: title,
                                 spurious: spur, devw: (dev ? w : 0) }
          end
        end
      end

      { spans: span_recs, m_all: m_all, m_spur: m_spur, m_devw: m_devw,
        status: :ok }
    rescue StandardError
      # decomplex IS present but its run errored (e.g. the span
      # contract assertion fired). Distinct from :absent so the report
      # can say "errored", not just "not installed".
      blank(:error)
    end

    # Span-containment FIRST (precise: the arm's line is INSIDE a
    # flagged decision's source extent), method-join FALLBACK (coarse).
    # nil if decomplex flagged nothing for this unit.
    #
    # Decision policy (optimised against misleading-when-invisible):
    #   * `spurious` (a hard "do not test -- refactor", which REMOVES
    #     the arm from the gap list) is returned ONLY on the precise
    #     path. A coarse duplication signal must never silently delete
    #     a real test target.
    #   * the coarse path NEVER excludes; it only sets `coarse_dup`
    #     (the method has a duplication-class finding but it was not
    #     localised to this arm) so the report can flag "verify --
    #     possibly redundant" while the arm STAYS a visible gap.
    #   * deviance is floored at the method-level value (`max`): being
    #     precisely attributed can only ADD specificity, never push an
    #     arm BELOW its method-fallback peers in the ranking.
    def lookup(verdict, file, method, line)
      key = [file, method]
      m_titles = verdict[:m_all].fetch(key, nil)
      m_dev = devsum(m_titles ? m_titles.keys : [],
                     verdict[:m_devw].fetch(key, {}))

      recs = verdict[:spans].fetch(file, [])
                            .select { |r| r[:fl] <= line && line <= r[:ll] }
      unless recs.empty?
        titles = recs.map { |r| r[:title] }.uniq
        p_devw = recs.group_by { |r| r[:title] }
                     .transform_values { |rs| rs.first[:devw] }
        return result(titles,
                      spurious: recs.any? { |r| r[:spurious] },
                      coarse_dup: false,
                      # Fix 1: monotone -- never below the method floor.
                      deviance: [devsum(titles, p_devw), m_dev].max,
                      precise: true)
      end

      return nil if m_titles.nil? || m_titles.empty?

      titles = m_titles.keys
      result(titles,
             spurious: false, # coarse NEVER excludes a gap
             coarse_dup: titles.any? { |t| SPURIOUS.include?(t) },
             deviance: m_dev, precise: false)
    end

    # tier-weighted sum over distinct deviance detectors, x2 on
    # convergence (>=2 distinct). Shared so the precise floor compares
    # like-for-like with the method-level value.
    def devsum(titles, devw)
      s = devw.values.sum
      s *= 2 if titles.size >= 2 && s.positive?
      s
    end

    def result(titles, spurious:, coarse_dup:, deviance:, precise:)
      { spurious: spurious, coarse_dup: coarse_dup, deviance: deviance,
        detectors: titles.sort, convergent: titles.size >= 2,
        precise: precise }
    end
  end
end
