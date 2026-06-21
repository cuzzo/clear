# frozen_string_literal: true

require_relative "site_extractor"

module Decomplex
  # Two reports over the mined Sites:
  #
  #   missing_abstractions -- an identical guard tuple recomputed across
  #     >= 2 distinct (file,def) decision units. Ranked support x
  #     scatter. This is the objective "you check these N conditions
  #     many times -> that should be one named function/datum" signal.
  #     scatter>=2 of the FULL identical tuple is the conservative
  #     proxy for "0 reifications" (true alias-aware reification
  #     counting is v1).
  #
  #   neglected_conditions -- a site whose member set is exactly a
  #     high-support pattern minus one element (Hamming-1 subset), same
  #     kind. "You make decision T at S sites; here you make T minus one
  #     conjunct/case." This is the Chang-Podgurski-Yang neglected-
  #     condition / likely-bug signal. Ranked by support of T.
  class Miner
    attr_reader :sites

    def initialize(sites)
      @sites = sites
    end

    def self.scan(files)
      sites = files.flat_map { |f| SiteExtractor.extract(f) }
      new(sites)
    end

    # [{ kind:, members:, support:, scatter:, sites:[...] }, ...]
    def missing_abstractions(min_scatter: 2)
      groups.filter_map do |(_kind, _mem), sts|
        scatter = sts.map { |s| [s.file, s.defn] }.uniq.size
        next if scatter < min_scatter

        ordered_sites = sts.sort_by { |site| [site.file.to_s, site.line.to_i, site.defn.to_s] }
        {
          kind: sts.first.kind,
          members: sts.first.members,
          support: sts.size,
          scatter: scatter,
          rank: sts.size * scatter,
          sites: ordered_sites.map { |s| loc(s) },
          spans: sts.to_h { |s| [loc(s), s.span] }
        }
      end.sort_by { |h| -h[:rank] }
    end

    # [{ pattern:, support:, missing:, at: "file:def:line" }, ...]
    def neglected_conditions(min_support: 3)
      popular = groups.select { |(_k, _m), sts| sts.size >= min_support }
                      .map { |(k, m), sts| [k, m, sts.size] }
      out = []
      @sites.each do |s|
        popular.each do |k, mem, sup|
          next unless k == s.kind
          next unless (mem - s.members).size == 1 && (s.members - mem).empty?
          next if s.members == mem

          out << {
            pattern: mem,
            support: sup,
            missing: (mem - s.members).first,
            at: loc(s),
            spans: { loc(s) => s.span }
          }
        end
      end
      out.uniq.sort_by { |h| -h[:support] }
    end

    private

    def groups
      @groups ||= @sites.group_by { |s| [s.kind, s.members] }
    end

    def loc(s)
      "#{s.file}:#{s.defn}:#{s.line}"
    end
  end
end
