# frozen_string_literal: true

require "json"
require_relative "root_cause"

module Decomplex
  # Before/after delta. decomplex is otherwise a stateless snapshot;
  # this is the feedback loop CLAUDE.md's "fixing reduces complexity,
  # not adds" demands: did a commit collapse the targeted root-cause
  # cluster, or just displace the debt elsewhere?
  #
  # Identity is LINE-INSENSITIVE by construction: a finding's
  # fingerprint is its detector + RootCause entities + (file, method),
  # never its line. A finding that only moved lines is "persisted",
  # NOT resolved+new -- so editing unrelated code above a finding does
  # not register as churn. Pure set/multiset arithmetic over two
  # snapshots; no re-analysis.
  module Delta
    module_function

    SEP = "\t" # source slices are space-collapsed; never contain tabs

    # sections: Report#sections_data ; clusters: RootCause.cluster(...).
    # Returns a JSON-round-trippable Hash (string keys).
    def snapshot(sections, clusters)
      findings = Hash.new(0)
      details = Hash.new { |h, k| h[k] = [] }
      sections.each do |title, _tier, fs|
        next unless fs

        fs.each do |f|
          fp = fingerprint(title, f)
          findings[fp] += 1
          details[fp] << json_safe_finding(title, f)
        end
      end
      site = Hash.new(0)
      site_details = Hash.new { |h, k| h[k] = [] }
      sections.each do |title, _tier, fs|
        next unless fs

        fs.each do |f|
          detail = json_safe_finding(title, f)
          site_fingerprints(title, f).each do |sfp|
            site[sfp] += 1
            site_details[sfp] << detail
          end
        end
      end
      cl = {}
      clusters.each do |c|
        cl["#{c[:kind]}#{SEP}#{c[:token]}"] =
          { "n" => c[:n_detectors], "s" => c[:support],
            "fat" => !c[:fat_union].nil? && c[:fat_union] }
      end
      { "findings" => findings, "site_findings" => site,
        "details" => details, "site_details" => site_details, "clusters" => cl,
        "total" => findings.values.sum }
    end

    def fingerprint(detector, finding)
      ents = RootCause.entities(finding)
                      .map { |k, t| "#{k}:#{t}" }.sort.join(",")
      units = RootCause.finding_units(finding)
                       .map { |f, m| "#{f}##{m}" }.uniq.sort.join(",")
      [detector, ents, units].join(SEP)
    end

    # Per-LEAF identity: one fingerprint per (detector, entities,
    # single file#method). The aggregate `fingerprint` re-keys a whole
    # multi-site finding when ANY member changes, so its per-finding
    # add/resolve is unusable for "which specific sites did this commit
    # add/remove" on aggregate detectors. ADDITIVE: `fingerprint`,
    # `findings`, `total`, clusters are unchanged (still report-
    # reconciled); this only powers the extra `site_*` delta.
    def site_fingerprints(detector, finding)
      ents = RootCause.entities(finding)
                      .map { |k, t| "#{k}:#{t}" }.sort.join(",")
      RootCause.finding_units(finding)
               .map { |f, m| "#{f}##{m}" }.uniq
               .map { |u| [detector, ents, u].join(SEP) }
    end

    def json_safe_finding(detector, finding)
      json_safe_value(finding.merge(detector: detector))
    end

    def json_safe_value(value)
      case value
      when Hash
        value.to_h { |k, v| [k.to_s, json_safe_value(v)] }
      when Array
        value.map { |v| json_safe_value(v) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    # base/head: snapshot Hashes (or JSON.parse of them). Returns the
    # structured delta.
    def diff(base, head)
      bf = base["findings"] || {}
      hf = head["findings"] || {}
      keys = (bf.keys | hf.keys)
      resolved = []
      added = []
      persisted = 0
      keys.each do |k|
        d = hf[k].to_i - bf[k].to_i
        if d.negative?  then resolved << [k, -d]
        elsif d.positive? then added << [k, d]
        else persisted += 1
        end
      end

      bc = base["clusters"] || {}
      hc = head["clusters"] || {}
      cl = { "grown" => [], "shrunk" => [], "new" => [], "resolved" => [] }
      (bc.keys | hc.keys).each do |k|
        b = bc[k]
        h = hc[k]
        if b.nil?  then cl["new"] << [k, h["s"]]
        elsif h.nil? then cl["resolved"] << [k, b["s"]]
        else
          ds = h["s"].to_i - b["s"].to_i
          (cl["grown"] << [k, b["s"], h["s"]] if ds.positive?)
          (cl["shrunk"] << [k, b["s"], h["s"]] if ds.negative?)
        end
      end

      # Site-level (per-leaf) delta -- the precise "which (file#method)
      # findings did this commit add/remove" that the aggregate
      # findings delta above cannot answer for multi-site detectors.
      bs = base["site_findings"] || {}
      hs = head["site_findings"] || {}
      s_added = []
      s_resolved = []
      s_persisted = 0
      (bs.keys | hs.keys).each do |k|
        d = hs[k].to_i - bs[k].to_i
        if d.negative?  then s_resolved << [k, -d]
        elsif d.positive? then s_added << [k, d]
        else s_persisted += 1
        end
      end

      {
        "resolved" => resolved.sort_by { |_, n| -n },
        "added" => added.sort_by { |_, n| -n },
        "persisted" => persisted,
        "site_resolved" => s_resolved.sort_by { |_, n| -n },
        "site_added" => s_added.sort_by { |_, n| -n },
        "site_persisted" => s_persisted,
        "totals" => { "base" => base["total"].to_i,
                      "head" => head["total"].to_i,
                      "delta" => head["total"].to_i - base["total"].to_i },
        "clusters" => cl
      }
    end

    def label(fp)
      d, ents, units = fp.split(SEP)
      "#{d} `#{ents.to_s.split(',').first || units.to_s.split(',').first}`"
    end

    def to_markdown(d)
      t = d["totals"]
      dir = t["delta"].zero? ? "no net change" :
            (t["delta"].negative? ? "REDUCED #{-t['delta']}" : "GREW #{t['delta']}")
      o = +"## Delta vs baseline\n\n"
      o << "_Line-insensitive. Net debt: #{dir} " \
           "(#{t['base']} -> #{t['head']}; #{d['persisted']} persisted, " \
           "#{d['added'].size} added, #{d['resolved'].size} resolved)._\n\n"
      unless d["clusters"]["shrunk"].empty? && d["clusters"]["resolved"].empty?
        o << "**Collapsed / shrunk root-cause clusters (the goal):**\n"
        d["clusters"]["resolved"].first(10).each do |k, s|
          o << "- `#{k.split(SEP).last}` -- #{s} findings -> GONE\n"
        end
        d["clusters"]["shrunk"].first(10).each do |k, b, h|
          o << "- `#{k.split(SEP).last}` -- #{b} -> #{h} findings\n"
        end
        o << "\n"
      end
      unless d["clusters"]["new"].empty? && d["clusters"]["grown"].empty?
        o << "**New / grown clusters (displaced debt -- watch):**\n"
        d["clusters"]["new"].first(10).each do |k, s|
          o << "- `#{k.split(SEP).last}` -- NEW, #{s} findings\n"
        end
        d["clusters"]["grown"].first(10).each do |k, b, h|
          o << "- `#{k.split(SEP).last}` -- #{b} -> #{h} findings\n"
        end
        o << "\n"
      end
      o << "**Top added findings:**\n"
      d["added"].first(15).each { |k, n| o << "- (+#{n}) #{label(k)}\n" }
      o << "- (none)\n" if d["added"].empty?

      sa = d["site_added"] || []
      sr = d["site_resolved"] || []
      unless sa.empty? && sr.empty?
        o << "\n**Site-level changes (precise -- exact file#method, " \
             "robust to membership churn):**\n"
        o << "- site-added #{sa.size}, site-resolved #{sr.size}, " \
             "site-persisted #{d['site_persisted']}\n"
        sa.first(25).each do |k, _|
          dd, _e, u = k.split(SEP)
          o << "  - + `#{u}` (#{dd})\n"
        end
        sr.first(25).each do |k, _|
          dd, _e, u = k.split(SEP)
          o << "  - - `#{u}` (#{dd})\n"
        end
      end
      o
    end
  end
end
