# frozen_string_literal: true

require "set"
require_relative "local_flow"

module Decomplex
  # Detects likely implicit sub-function boundaries: a blank/comment boundary
  # where prior locals die and a new local set starts.
  class OperationalDiscontinuity
    DEFAULT_MIN_DEAD = 2
    DEFAULT_MIN_NEW = 2
    DEFAULT_MAX_CONTINUING = 1
    DEFAULT_MIN_SCORE = 12
    DEFAULT_HIGH_CONFIDENCE_MIN_SCORE = 20
    PHASE_COMMENT_PATTERN = /\A#\s*(?:\d+[a-z]?\s*[.)]|(?:phase|step|stage)\b)/i
    GRAMMAR_METHOD_PATTERN = /\Aparse(?:_|$)/

    RangeInfo = Struct.new(:first, :last, keyword_init: true)

    def self.scan(
      files,
      min_dead: DEFAULT_MIN_DEAD,
      min_new: DEFAULT_MIN_NEW,
      max_continuing: DEFAULT_MAX_CONTINUING,
      min_score: DEFAULT_MIN_SCORE
    )
      new(
        LocalFlow.scan(files),
        min_dead: min_dead,
        min_new: min_new,
        max_continuing: max_continuing,
        min_score: min_score
      ).findings
    end

    def self.high_confidence?(finding)
      finding[:confidence] == :high
    end

    def initialize(summaries, min_dead:, min_new:, max_continuing:, min_score:)
      @summaries = summaries
      @min_dead = min_dead.to_i
      @min_new = min_new.to_i
      @max_continuing = max_continuing.to_i
      @min_score = min_score.to_i
    end

    def findings
      @summaries.filter_map { |summary| finding_for(summary) }
                .sort_by { |finding| [-finding[:score], finding[:file], finding[:line]] }
    end

    private

    def finding_for(summary)
      return nil if summary.boundaries.empty?

      ranges = variable_ranges(summary)
      resets = summary.boundaries.filter_map { |boundary| reset_at(boundary, ranges) }
      return nil if resets.empty?

      score = resets.sum { |reset| reset[:dead].size + reset[:new].size - reset[:continuing].size } +
              (resets.size * 8)
      return nil if score < @min_score

      confidence_reasons = confidence_reasons_for(summary.name, score, resets)
      {
        file: summary.file,
        defn: summary.name,
        owner: summary.owner,
        method: summary.name,
        line: summary.line,
        at: "#{summary.file}:#{summary.name}:#{summary.line}",
        score: score,
        resets: resets.size,
        dead_total: resets.sum { |reset| reset[:dead].size },
        new_total: resets.sum { |reset| reset[:new].size },
        reset_points: resets,
        confidence: confidence_reasons.empty? ? :review : :high,
        confidence_reasons: confidence_reasons,
        spans: { "#{summary.file}:#{summary.name}:#{summary.line}" => summary.span },
      }
    end

    def confidence_reasons_for(method_name, score, resets)
      explicit_phase = resets.any? { |reset| phase_marker?(reset) }
      reasons = []
      reasons << :repeated_resets if resets.size >= 2
      reasons << :explicit_phase_marker if explicit_phase
      reasons << :high_score if score >= DEFAULT_HIGH_CONFIDENCE_MIN_SCORE
      reasons -= [:repeated_resets, :high_score] if grammar_method?(method_name) && !explicit_phase
      reasons
    end

    def phase_marker?(reset)
      reset[:text].to_s.match?(PHASE_COMMENT_PATTERN)
    end

    def grammar_method?(method_name)
      method_name.to_s.match?(GRAMMAR_METHOD_PATTERN)
    end

    def reset_at(boundary, ranges)
      before = boundary.before_index
      after = boundary.after_index
      before_vars = ranges.select { |_name, range| range.first <= before }
      dead = before_vars.filter_map { |name, range| name if range.last <= before }.sort
      continuing = before_vars.filter_map { |name, range| name if range.last >= after }.sort
      new_vars = ranges.filter_map { |name, range| name if range.first >= after }.sort

      return nil if dead.size < @min_dead
      return nil if new_vars.size < @min_new
      return nil if continuing.size > @max_continuing

      {
        line: boundary.line,
        kind: boundary.kind,
        text: boundary.text,
        before_statement: before,
        after_statement: after,
        dead: dead,
        new: new_vars,
        continuing: continuing,
      }
    end

    def variable_ranges(summary)
      ranges = {}
      summary.statements.each do |statement|
        touched_vars(statement).each do |name|
          existing = ranges[name]
          if existing
            existing.last = statement.index
          else
            ranges[name] = RangeInfo.new(first: statement.index, last: statement.index)
          end
        end
      end
      ranges
    end

    def touched_vars(statement)
      statement.reads | statement.writes
    end
  end
end
