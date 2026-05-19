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
      sections.each do |title, _tier, fs|
        next unless fs

        fs.each { |f| findings[fingerprint(title, f)] += 1 }
      end
      cl = {}
      clusters.each do |c|
        cl["#{c[:kind]}#{SEP}#{c[:token]}"] =
          { "n" => c[:n_detectors], "s" => c[:support],
            "fat" => !c[:fat_union].nil? && c[:fat_union] }
      end
      { "findings" => findings, "clusters" => cl,
        "total" => findings.values.sum }
    end

    def fingerprint(detector, finding)
      ents = RootCause.entities(finding)
                      .map { |k, t| "#{k}:#{t}" }.sort.join(",")
      units = RootCause.finding_units(finding)
                       .map { |f, m| "#{f}##{m}" }.uniq.sort.join(",")
      [detector, ents, units].join(SEP)
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

      {
        "resolved" => resolved.sort_by { |_, n| -n },
        "added" => added.sort_by { |_, n| -n },
        "persisted" => persisted,
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
      o
    end
  end
end
