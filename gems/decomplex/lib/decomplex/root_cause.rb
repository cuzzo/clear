# frozen_string_literal: true

require_relative "convergence"

module Decomplex
  # Root-cause clustering. Convergence answers "which (file, method) is
  # implicated by the most detectors" (a LOCATION hotspot). RootCause
  # answers the question that actually drives a rearchitecture: "which
  # ONE underlying entity, when fixed, collapses a cluster of findings
  # across detectors" -- the 74-findings-are-really-one-invariant view
  # (e.g. the `storage`/`provenance` co-write surface that
  # Neglected-Updates + Derived-State + Decision-Pressure + False-
  # Simplicity all name independently).
  #
  # Pure READ-ONLY consumer of Report#sections_data, exactly like
  # Convergence: it re-derives no detector. It only re-groups their
  # already-published findings by the ENTITY they are about instead of
  # by their location, and names the single fix shape.
  #
  # Two entity kinds (a finding contributes whichever it carries):
  #   :name  -- a shared identifier (attribute/contract/predicate). The
  #             cross-detector "same state" link (storage/provenance).
  #   :tuple -- a shared decision tuple (a guard/dispatch member set).
  #             Links the dispatch/path detectors on the same decision.
  class RootCause
    # Generic field families (NOT per-detector logic -- the same three
    # buckets every detector's findings already use).
    TUPLE_FIELDS = %i[members guards pattern].freeze
    NAME_ARRAY_FIELDS = %i[pair names].freeze
    NAME_STR_FIELDS = %i[field derived source contract canon predicate
                         detail ref_name has missing].freeze
    STOPWORDS = %w[nil true false self end do if then else self_ it
                   new to_s call each map].freeze

    # Ordered most-specific-first. Maps the SET of detectors that
    # converged to the one fix shape (SlopCop-style interpretation
    # policy: decomplex owns findings; this only names the action,
    # ranked-candidate, never a verdict).
    FIX_SHAPE = [
      [%w[Neglected\ Updates Derived-State\ Staleness], :name,
       "single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape"],
      [%w[Broken\ Protocols], :any,
       "pair the protocol (RAII / ensure); the unpaired site is the deviant"],
      [%w[Missing\ Abstractions Reification\ Misses Semantic\ Predicate\ Aliases Exact\ Predicate\ Aliases], :any,
       "reify ONE named predicate/decision and call it everywhere"],
      [%w[Missing\ Abstractions Neglected\ Conditions Neglected\ Path\ Conditions], :tuple,
       "extract the decision; if it dispatches a closed set, consider product-vs-sum (fat-union -> nil-kill)"],
      [%w[Decision\ Pressure], :any,
       "tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)"]
    ].freeze

    # sections: [[title, tier, findings], ...] (Report#sections_data).
    def self.cluster(sections, min_detectors: 2)
      tier_of = {}
      acc = Hash.new do |h, k|
        h[k] = { dets: {}, findings: [], tiers: {} }
      end
      sections.each do |title, tier, findings|
        next unless findings

        tier_of[title] = tier
        findings.each do |f|
          entities(f).each do |ent|
            u = acc[ent]
            u[:dets][title] = true
            u[:tiers][title] = tier
            u[:findings] << f
          end
        end
      end

      acc.filter_map do |(kind, token), u|
        next if u[:dets].size < min_detectors

        dets = u[:dets].keys.sort
        units = u[:findings].flat_map { |f| finding_units(f) }.uniq
        score = u[:tiers].values.sum { |t| Convergence::TIER_WEIGHT.fetch(t, 1) }
        fat = fat_union?(kind, token, u[:findings])
        { kind: kind, token: token, detectors: dets,
          n_detectors: dets.size, support: u[:findings].size,
          scatter: units.size, score: score, fat_union: fat,
          fix: fat ? FAT_UNION_FIX : fix_shape(dets, kind),
          sites: u[:findings].flat_map { |f| Convergence.locations(f) }
                             .uniq.first(8) }
      end.sort_by do |h|
        [-h[:n_detectors], -h[:score], -h[:scatter], h[:kind].to_s, h[:token]]
      end
    end

    FAT_UNION_FIX =
      "fat union -- decompose product-vs-sum: hoist the common fields " \
      "to a struct, keep a SMALL union for the variant part " \
      "(extraction is value-object work -> nil-kill owns it)"

    CONST_SEG = /\A(::)?[A-Z]\w*(::[A-Z]\w*)*\z/.freeze

    # #2 precursor: a :tuple cluster whose dispatch is over CLASS
    # CONSTANTS (not symbols/ints) and is a `case` dispatch (Missing
    # Abstractions carries kind: :case_dispatch) is a union being
    # re-dispatched -- the fat-union signature, surfaced without a
    # dedicated detector. Constant check excludes enum-ish int/symbol
    # dispatch (that is not a union).
    def self.fat_union?(kind, token, findings)
      return false unless kind == :tuple
      return false unless findings.any? { |f| f[:kind] == :case_dispatch }

      members = token.split(" | ")
      members.size >= 2 && members.all? { |m| m =~ CONST_SEG }
    end

    # -> Set of [kind, token]. Generic over the field families; no
    # per-detector branching.
    def self.entities(finding)
      out = []
      TUPLE_FIELDS.each do |k|
        v = finding[k]
        next unless v.is_a?(Array) && v.size >= 2

        # NO field-name prefix: Missing-Abstractions `:members`,
        # Neglected-Conditions `:pattern` and PathCondition `:guards`
        # for the SAME decision must yield the SAME token (that cross-
        # detector link is the whole point of a tuple-entity).
        out << [:tuple, v.map(&:to_s).sort.join(" | ")[0, 160]]
      end
      NAME_ARRAY_FIELDS.each do |k|
        v = finding[k]
        next unless v.is_a?(Array)

        v.each { |e| tokens(e).each { |t| out << [:name, t] } }
      end
      NAME_STR_FIELDS.each do |k|
        v = finding[k]
        tokens(v).each { |t| out << [:name, t] } if v
      end
      out.uniq
    end

    # Bare identifier tokens: strip a leading @/:/. and trailing =?!,
    # drop trivial/keyword/short noise. "storage=" / ".storage" /
    # "@storage" / "storage" all -> "storage" (the cross-detector link).
    def self.tokens(val)
      val.to_s.scan(/[A-Za-z_][A-Za-z0-9_]*[?!=]?/).filter_map do |w|
        t = w.sub(/[?!=]\z/, "")
        next if t.length < 2 || STOPWORDS.include?(t)

        t
      end.uniq
    end

    def self.finding_units(finding)
      Convergence.locations(finding).filter_map do |loc|
        file, meth, = Convergence.parse_loc(loc)
        [file, meth] if file && meth
      end
    end

    def self.fix_shape(detectors, kind)
      FIX_SHAPE.each do |titles, want_kind, label|
        next unless want_kind == :any || want_kind == kind
        next if (titles & detectors).empty?

        return label
      end
      "converging structural debt -- resolve once at the named entity"
    end
  end
end
