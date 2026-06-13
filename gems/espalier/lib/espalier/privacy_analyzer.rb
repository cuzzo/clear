# frozen_string_literal: true

module Espalier
  # Finds public methods that look like same-owner helper/protocol steps.
  # This is intentionally conservative: a manifest-visible external receiver
  # call to the same message suppresses the finding.
  class PrivacyAnalyzer
    DEFAULT_SCORE_THRESHOLD = 5.0

    PUBLIC_SURFACE_NAMES = %w[
      [] []= <=> == === call each eql? hash initialize inspect run to_s
    ].freeze
    PUBLIC_SURFACE_PREFIXES = %w[as_ self. to_].freeze
    PUBLIC_SURFACE_PATTERNS = [
      /\Avisit_[A-Z]/
    ].freeze
    HELPER_NAME_PATTERNS = [
      /\A(?:analyze|apply|build|check|classify|collect|consume|coerce|declare|emit|ensure|extract|finalize|handle|infer|inject|mark|normalize|prepare|record|reject|report|resolve|restore|sync|track|validate|verify|warn)_/,
      /[!?]\z/
    ].freeze

    def self.candidates(manifest, threshold: DEFAULT_SCORE_THRESHOLD)
      new(manifest, threshold: threshold).candidates
    end

    def self.annotate!(manifest, threshold: DEFAULT_SCORE_THRESHOLD)
      rows = candidates(manifest, threshold: threshold)
      by_key = rows.to_h { |row| [[row[:module], row[:name]], row] }
      Array(manifest).each do |mod|
        Array(mod[:functions]).each do |fn|
          row = by_key[[mod[:module], fn[:name].to_s]]
          next unless row

          metrics = fn[:quality_metrics] ||= {}
          metrics[:privacy_candidate] = true
          metrics[:privacy_score] = row[:score]
          metrics[:privacy_confidence] = row[:confidence]
        end
      end
      manifest
    end

    def initialize(manifest, threshold:)
      @manifest = Array(manifest)
      @threshold = threshold.to_f
    end

    def candidates
      @candidates ||= function_rows.filter_map { |row| candidate_for(row) }
                                  .sort_by { |row| [-row[:score], confidence_rank(row), row[:file].to_s, row[:name].to_s] }
    end

    private

    def candidate_for(row)
      return nil unless row[:visibility] == :public
      return nil if public_surface_name?(row[:name])
      return nil if row[:callers].empty?

      external_hits = external_calls_by_message[row[:name]]
      return nil unless external_hits.empty?

      score = candidate_score(row)
      return nil if score < @threshold

      row.merge(
        score: round(score),
        confidence: confidence_for(score),
        reason: reasons_for(row).join("; "),
        external_hits: external_hits
      )
    end

    def function_rows
      @function_rows ||= @manifest.flat_map do |mod|
        Array(mod[:functions]).map do |fn|
          graph = fn[:CALL_GRAPH] || {}
          reads = effect_list(fn, :reads)
          writes = effect_list(fn, :writes)
          {
            module: mod[:module],
            file: mod[:file],
            name: fn[:name].to_s,
            line: fn[:line],
            visibility: visibility_for(fn),
            callers: Array(graph[:internal_callers]).map(&:to_s).uniq.sort,
            callees: Array(graph[:internal_calls]).map(&:to_s).uniq.sort,
            reads: reads.size,
            writes: writes.size,
            state_touches: reads.size + writes.size,
            helper_shaped: helper_shaped_name?(fn[:name].to_s),
            quality: fn[:quality_metrics] || {}
          }
        end
      end
    end

    def candidate_score(row)
      score = 2.0
      score += row[:callers].size == 1 ? 3.0 : [row[:callers].size * 0.75, 3.0].min
      score += 1.5 if row[:state_touches].positive?
      score += 1.0 if row[:writes].positive?
      score += [row[:callees].size * 0.5, 2.0].min
      score += 1.5 if row[:helper_shaped]
      score += 1.0 unless row[:quality].empty?
      score
    end

    def reasons_for(row)
      reasons = ["public but only has same-owner callers"]
      reasons << "single internal caller: #{row[:callers].first}" if row[:callers].size == 1
      reasons << "stateful step reads=#{row[:reads]} writes=#{row[:writes]}" if row[:state_touches].positive?
      reasons << "coordinates #{row[:callees].size} internal call(s)" if row[:callees].any?
      reasons << "helper-shaped name" if row[:helper_shaped]
      reasons << "no manifest-visible external receiver call"
      reasons
    end

    def confidence_for(score)
      return :high if score >= 8.0
      return :medium if score >= 6.0

      :low
    end

    def confidence_rank(row)
      { high: 0, medium: 1, low: 2 }.fetch(row[:confidence], 3)
    end

    def external_calls_by_message
      @external_calls_by_message ||= @manifest.each_with_object(Hash.new { |h, k| h[k] = [] }) do |mod, index|
        Array(mod[:functions]).each do |fn|
          delegations = fn[:DELEGATIONS] || {}
          (Array(delegations[:always_calls]) + Array(delegations[:conditionally_calls])).each do |call|
            call_text = call.to_s
            next unless call_text.include?(".")

            message = call_text.split(".").last
            index[message] << "#{mod[:module]}##{fn[:name]} -> #{call_text}"
          end
        end
      end
    end

    def effect_list(fn, key)
      Array((fn[:EFFECTS] || {})[key])
    end

    def visibility_for(fn)
      (fn[:visibility] || :public).to_sym
    end

    def public_surface_name?(name)
      PUBLIC_SURFACE_NAMES.include?(name) ||
        PUBLIC_SURFACE_PREFIXES.any? { |prefix| name.start_with?(prefix) } ||
        PUBLIC_SURFACE_PATTERNS.any? { |pattern| name.match?(pattern) }
    end

    def helper_shaped_name?(name)
      HELPER_NAME_PATTERNS.any? { |pattern| name.match?(pattern) }
    end

    def round(value)
      (value * 10).round / 10.0
    end
  end
end
