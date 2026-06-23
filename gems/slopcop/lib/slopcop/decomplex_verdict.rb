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

    DETECTOR_MAP = {
      "missing_abstractions" => ["Missing Abstractions", 1],
      "reification_misses" => ["Reification Misses", 1],
      "alias_clusters" => ["Exact Predicate Aliases", 1], # We'll disambiguate exact vs semantic later
      "decision_pressure" => ["Decision Pressure", 1],
      "neglected_updates" => ["Neglected Updates", 2],
      "neglected_conditions" => ["Neglected Conditions", 2],
      "derived_state" => ["Derived-State Staleness", 2],
      "inconsistent_rename_clone" => ["Inconsistent Rename Clones", 2],
      "flay_similarity" => ["Structural Similarity (Type-2/3)", 2],
      "neglected" => ["Neglected Path Conditions", 3], # from path_condition
      "broken_protocol" => ["Broken Protocols", 3],
      "false_simplicity" => ["False Simplicity", 3]
    }.freeze
    
    def blank(status)
      { spans: {}, m_all: {}, m_spur: {}, m_devw: {}, status: status }
    end

    def flatten_detectors(detectors, prefix = nil)
      flat = {}
      detectors.each do |k, v|
        if nested_detector_group?(v)
          v.each do |sub_k, sub_v|
            flat[mapped_detector_key(k, sub_k)] = sub_v
          end
        else
          flat[k] = v
        end
      end
      flat
    end

    def nested_detector_group?(v)
      v.is_a?(Hash) && !v.key?("sites") && !v.key?("spans") && !v.empty?
    end

    def mapped_detector_key(k, sub_k)
      if k == "semantic_alias" && sub_k == "alias_clusters"
        "semantic_predicate_aliases"
      elsif k == "predicate_alias" && sub_k == "alias_clusters"
        "exact_predicate_aliases"
      else
        sub_k
      end
    end

    def index(abs_files)
      return blank(:absent) if abs_files.empty?

      data = load_decomplex_facts(abs_files)
      return blank(data[:status]) if data[:status] != :ok

      detectors = flatten_detectors(data[:detectors] || {})
      
      span_recs = Hash.new { |h, k| h[k] = [] }      # file => [rec...]
      m_all  = Hash.new { |h, k| h[k] = {} }         # [f,m] => {title=>1}
      m_spur = Hash.new(false)                       # [f,m] => Bool
      m_devw = Hash.new { |h, k| h[k] = {} }         # [f,m] => {title=>w}

      process_detectors(detectors, span_recs, m_all, m_spur, m_devw)
      
      { spans: span_recs, m_all: m_all, m_spur: m_spur, m_devw: m_devw, status: :ok }
    rescue StandardError => e
      warn "SlopCop::DecomplexVerdict error: #{e.message}"
      blank(:error)
    end

    def load_decomplex_facts(abs_files)
      if ENV["DECOMPLEX_FACTS_FILE"] && !ENV["DECOMPLEX_FACTS_FILE"].empty?
        { detectors: JSON.parse(File.read(ENV["DECOMPLEX_FACTS_FILE"]))["detectors"], status: :ok }
      else
        begin
          require "tempfile"
          tmp = Tempfile.new(["decomplex-facts", ".json"])
          tmp.close
          
          bin = ENV.fetch("DECOMPLEX_RUST_BINARY", ::File.expand_path("../../../decomplex/rust/target/release/decomplex-rust", __dir__))
          unless ::File.executable?(bin)
            return { status: :absent }
          end
          
          ok = system(bin, "facts", "--output", tmp.path, *abs_files, err: File::NULL)
          return { status: :error } unless ok
          
          { detectors: JSON.parse(File.read(tmp.path))["detectors"], status: :ok }
        ensure
          tmp&.unlink if tmp
        end
      end
    end

    def process_detectors(detectors, span_recs, m_all, m_spur, m_devw)
      detectors.each do |detector, items|
        title, tier = detector_title_and_tier(detector)
        w = [1, 4 - tier].max # simple tier weight: 1=>3, 2=>2, 3=>1
        spur = SPURIOUS.include?(title)
        dev  = DEVIANCE.include?(title)
        
        extract_sites(items).each do |item|
          loc = item[:site]
          sp = item[:span]
          file, meth, = parse_loc(loc)
          next if file.to_s.empty? || meth.to_s.empty?

          key = [file, meth]
          m_all[key][title] = true
          m_spur[key] ||= spur
          m_devw[key][title] = w if dev
          next unless sp
          
          span_recs[file] << { fl: sp[0], ll: sp[2], title: title,
                               spurious: spur, devw: (dev ? w : 0) }
        end
      end
    end

    def detector_title_and_tier(detector)
      case detector
      when "semantic_predicate_aliases"
        ["Semantic Predicate Aliases", 1]
      when "exact_predicate_aliases"
        ["Exact Predicate Aliases", 1]
      else
        DETECTOR_MAP.fetch(detector, [detector.to_s, 3])
      end
    end

    def extract_sites(payload)
      sites = []
      if payload.is_a?(Array)
        payload.each do |item|
          if item.is_a?(Hash) && item["sites"]
            item["sites"].each do |site|
              span = item["spans"] ? item["spans"][site] : nil
              sites << { site: site, span: span }
            end
          end
        end
      elsif payload.is_a?(Hash)
        if payload["sites"]
          payload["sites"].each do |site|
            span = payload["spans"] ? payload["spans"][site] : nil
            sites << { site: site, span: span }
          end
        else
          payload.each_value do |v|
            sites.concat(extract_sites(v)) if v.is_a?(Array) || v.is_a?(Hash)
          end
        end
      end
      sites
    end

    def parse_loc(loc)
      parts = loc.split(":")
      return [] if parts.size < 3
      line = parts.pop
      method_name = parts.pop
      file_path = parts.join(":")
      [file_path, method_name, line]
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
