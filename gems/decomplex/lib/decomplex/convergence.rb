# frozen_string_literal: true

module Decomplex
  # Cross-detector convergence: a pure READ-ONLY consumer of the
  # detectors' already-computed findings. It ranks (file, method) units
  # by how many DISTINCT detectors fire there, tier-weighted. It reads
  # only the three generic location keys every detector publishes
  # (:at, :ref_at, :sites) -- it never re-derives a finding. This keeps
  # the single-source-of-truth contract: detectors own findings, this
  # only aggregates them (design.md principle 3, additive).
  #
  # This is NOT nil-kill pressure. Pressure is a propagation DAG
  # (resolve a root -> downstream unlocks -> recompute -> loop).
  # decomplex findings are independent observations; the actionable
  # signal is AGREEMENT -- N independent detectors converging on one
  # method outranks any single detector's volume.
  class Convergence
    TIER_WEIGHT = { 1 => 3, 2 => 2, 3 => 1 }.freeze

    # sections: [[title(String), tier(Integer), findings(Array<Hash>)], ...]
    # Returns ranked Array<Hash> for units fired on by >= min_detectors
    # distinct detectors.
    def self.rollup(sections, min_detectors: 2)
      acc = Hash.new do |h, k|
        h[k] = { dets: Hash.new(0), tiers: {}, n: 0, at: nil }
      end
      sections.each do |title, tier, findings|
        next unless findings

        findings.each do |f|
          locations(f).each do |loc|
            file, meth, line = parse_loc(loc)
            next unless file && !file.empty? && meth && !meth.empty?

            u = acc[[file, meth]]
            u[:dets][title] += 1
            u[:tiers][title] = tier
            u[:n] += 1
            u[:at] ||= line ? "#{file}:#{meth}:#{line}" : "#{file}:#{meth}"
          end
        end
      end

      acc.filter_map do |(file, meth), u|
        next if u[:dets].size < min_detectors

        score = u[:tiers].values.sum { |t| TIER_WEIGHT.fetch(t, 1) }
        { file: file, method: meth, detectors: u[:dets].keys.sort,
          n_detectors: u[:dets].size, score: score,
          findings: u[:n], at: u[:at] }
      end.sort_by do |h|
        [-h[:n_detectors], -h[:score], -h[:findings], h[:file], h[:method]]
      end
    end

    # Coarser, file-granularity view of the same agreement signal.
    def self.by_file(units)
      units.group_by { |u| u[:file] }.filter_map do |file, us|
        dets = us.flat_map { |u| u[:detectors] }.uniq.sort
        next if dets.size < 2

        { file: file, detectors: dets, n_detectors: dets.size,
          methods: us.size, score: us.sum { |u| u[:score] } }
      end.sort_by { |h| [-h[:n_detectors], -h[:score], -h[:methods], h[:file]] }
    end

    # The only location keys any detector publishes (verified against
    # report.rb render): :at, :ref_at (single strings), :sites (array).
    def self.locations(finding)
      out = []
      [:at, :ref_at].each do |k|
        v = finding[k]
        out << v if v.is_a?(String)
      end
      v = finding[:sites]
      out.concat(v.select { |s| s.is_a?(String) }) if v.is_a?(Array)
      out
    end

    # "file:method:line" or "file:method" (some sites omit the line).
    # Split from the right: a trailing all-digit segment is the line;
    # the file path itself may contain colons (same rule as nav).
    def self.parse_loc(loc)
      parts = loc.to_s.split(":")
      return [nil, nil, nil] if parts.size < 2

      if parts.last =~ /\A\d+\z/
        line = parts.pop
        meth = parts.pop
        [parts.join(":"), meth, line]
      else
        meth = parts.pop
        [parts.join(":"), meth, nil]
      end
    end
  end
end
