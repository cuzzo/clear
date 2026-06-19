# frozen_string_literal: true

require "set"
require_relative "syntax"

module Decomplex
  # Structural similarity scanner for Type-2 / Type-3 clone pressure.
  #
  # Parser-specific structural fingerprinting is owned by Syntax adapters. This
  # detector ranks already-normalized clone candidates and emits report rows.
  class FlaySimilarity
    DEFAULT_MASS = 32
    DEFAULT_FUZZY = 1
    MAX_FUZZY_CHILDREN = 14

    def self.scan(files, mass: DEFAULT_MASS, fuzzy: DEFAULT_FUZZY)
      new(files, mass: mass, fuzzy: fuzzy).scan
    end

    def initialize(files, mass:, fuzzy:)
      @files = files
      @mass = mass
      @fuzzy = fuzzy
    end

    def scan
      candidates = @files.flat_map { |file| candidates_for_file(file) }
      findings = (type2_findings(candidates) + type3_findings(candidates)).sort_by do |finding|
        [finding[:clone_type] == :type2 ? 0 : 1, -finding[:mass].to_i, finding[:node].to_s, finding[:at].to_s]
      end
      prune_nested_findings(findings)
    rescue LoadError, StandardError
      []
    end

    private

    def candidates_for_file(file)
      return [] unless Syntax.supported_source?(file, parser: "tree_sitter")

      Syntax.parse(file, parser: "tree_sitter").clone_candidates.select do |candidate|
        candidate.mass >= effective_mass_floor
      end
    rescue StandardError
      []
    end

    def type2_findings(candidates)
      candidates.group_by(&:fingerprint).values.filter_map do |cluster|
        cluster = uniq_sites(cluster)
        next if cluster.size < 2
        next if cluster.map(&:raw).uniq.size < 2

        finding_for(cluster, clone_type: :type2, mass: cluster.map(&:mass).min)
      end
    end

    def type3_findings(candidates)
      return [] if @fuzzy <= 0

      groups = Hash.new { |hash, key| hash[key] = [] }
      candidates.each do |candidate|
        fuzzy_signatures(candidate).each do |signature, signature_mass|
          next if signature_mass < effective_mass_floor

          groups[signature] << [candidate, signature_mass]
        end
      end

      seen = Set.new
      groups.values.filter_map do |rows|
        cluster = uniq_sites(rows.map(&:first))
        next if cluster.size < 2
        next if cluster.map(&:fingerprint).uniq.size < 2

        key = cluster.map { |candidate| [candidate.file, candidate.line, candidate.node_name] }.sort
        next if seen.include?(key)

        seen << key
        finding_for(cluster, clone_type: :type3, mass: rows.map(&:last).max)
      end
    end

    def finding_for(cluster, clone_type:, mass:)
      sites = cluster.map { |candidate| site_for(candidate) }.sort
      {
        at: sites.first,
        sites: sites,
        spans: spans_for(cluster),
        clone_type: clone_type,
        node: cluster.map(&:node_name).tally.max_by { |_node, count| count }.first.to_s,
        mass: mass,
        locations: cluster.map { |candidate| "#{candidate.file}:#{candidate.line}" }.sort
      }
    end

    def prune_nested_findings(findings)
      defn_site_sets = findings.select { |finding| finding[:node].to_s == "defn" }
                               .map { |finding| [finding[:clone_type], site_identities(finding)] }
      kept = []
      findings.each do |finding|
        next if finding[:node].to_s != "defn" &&
                defn_site_sets.include?([finding[:clone_type], site_identities(finding)])
        next if kept.any? { |larger| nested_finding?(finding, larger) }

        kept << finding
      end
      kept
    end

    def nested_finding?(inner, outer)
      return false if inner.equal?(outer)
      return false if outer[:mass].to_i <= inner[:mass].to_i

      inner.fetch(:spans).all? do |site, span|
        file = site_file(site)
        outer.fetch(:spans).any? do |outer_site, outer_span|
          site_file(outer_site) == file && contains_span?(outer_span, span)
        end
      end
    end

    def contains_span?(outer, inner)
      outer_start = [outer[0].to_i, outer[1].to_i]
      outer_end = [outer[2].to_i, outer[3].to_i]
      inner_start = [inner[0].to_i, inner[1].to_i]
      inner_end = [inner[2].to_i, inner[3].to_i]
      (outer_start <=> inner_start) <= 0 && (outer_end <=> inner_end) >= 0
    end

    def site_file(site)
      parts = site.to_s.split(":")
      parts[0...-2].join(":")
    end

    def site_identities(finding)
      Array(finding[:sites]).map do |site|
        parts = site.to_s.split(":")
        [parts[0...-2].join(":"), parts[-2]]
      end.sort
    end

    def spans_for(cluster)
      cluster.each_with_object({}) do |candidate, out|
        out[site_for(candidate)] =
          if candidate.node_name == "defn"
            [candidate.span[0], 0, candidate.span[2], 1]
          else
            candidate.span
          end
      end
    end

    def site_for(candidate)
      "#{candidate.file}:#{candidate.method_name}:#{candidate.line}"
    end

    def uniq_sites(candidates)
      candidates.uniq { |candidate| [candidate.file, candidate.line, candidate.span, candidate.node_name] }
    end

    def fuzzy_signatures(candidate)
      children = candidate.child_fingerprints
      return [] if children.size < 2 || children.size > MAX_FUZZY_CHILDREN

      masses = candidate.child_masses
      max_delete = [@fuzzy, children.size - 1].min
      signatures = []
      (0..max_delete).each do |delete_count|
        (0...children.size).to_a.combination(delete_count) do |deleted|
          deleted_set = deleted.to_set
          kept = []
          mass = 0
          children.each_with_index do |fp, index|
            next if deleted_set.include?(index)

            kept << fp
            mass += masses[index].to_i
          end
          signatures << ["#{candidate.node_name}(#{kept.join('|')})", mass]
        end
      end
      signatures
    end

    def effective_mass_floor
      @effective_mass_floor ||= [@mass, (@mass * 23.0 / 8.0).ceil].max
    end
  end
end
