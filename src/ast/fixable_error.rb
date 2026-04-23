# Infrastructure for `clear fix` (Phase A).
#
# A FixableFinding is a compiler-produced diagnostic with one or more
# suggested edits. Findings are collected opt-in via FixCollector; when
# no collector is active, emission falls back to the legacy behaviour
# (stderr warnings, raised CompilerErrors) so normal `clear build` is
# unaffected.
#
# Data model:
#   Span   — (file, line, col, length) on the original source text.
#   Edit   — (span, replacement) — replace N chars starting at line:col.
#   Fix    — (description, confidence, edits[]) — one candidate; a Finding
#            may carry multiple Fixes when the choice is ambiguous.
#   FixableFinding — (level, message, token, category, fixes[])
#            level    :warning (non-blocking) or :error (blocks build)
#            category :lint | :ownership | :capability | :escape | :type
#                     | :registry

require_relative "source_error"

class Span
  attr_reader :file, :line, :col, :length

  def initialize(file:, line:, col:, length:)
    @file = file
    @line = line
    @col = col
    @length = length
  end

  # Build a span covering `length` characters starting at the token's
  # location. Defaults to the token's own textual length.
  def self.from_token(file, token, length: nil)
    raw = token.respond_to?(:value) ? token.value : nil
    len = length || (raw.is_a?(String) ? raw.length : 1)
    new(file: file, line: token.line, col: token.column, length: len)
  end

  def to_h
    { file: @file, line: @line, col: @col, length: @length }
  end
end

class Edit
  attr_reader :span, :replacement

  def initialize(span:, replacement:)
    @span = span
    @replacement = replacement
  end
end

class Fix
  CONFIDENCES = [:auto, :interactive].freeze

  attr_reader :description, :confidence, :edits

  def initialize(description:, confidence: :interactive, edits:)
    unless CONFIDENCES.include?(confidence)
      raise ArgumentError, "Fix.confidence must be one of #{CONFIDENCES}, got #{confidence.inspect}"
    end
    @description = description
    @confidence = confidence
    @edits = Array(edits)
    raise ArgumentError, "Fix needs at least one edit" if @edits.empty?
  end
end

class FixableFinding
  LEVELS = [:warning, :error].freeze
  CATEGORIES = [:lint, :ownership, :capability, :escape, :type, :registry].freeze

  attr_reader :level, :message, :token, :category, :fixes

  def initialize(level:, message:, token:, category:, fixes:)
    raise ArgumentError, "bad level #{level.inspect}" unless LEVELS.include?(level)
    raise ArgumentError, "bad category #{category.inspect}" unless CATEGORIES.include?(category)
    @level = level
    @message = message
    @token = token
    @category = category
    @fixes = Array(fixes)
    raise ArgumentError, "at least one Fix required" if @fixes.empty?
  end
end

# Process-wide collector. `clear fix` enables it before running the
# frontend; every other caller (including `clear build` / `clear run`)
# leaves it disabled so behaviour is unchanged.
module FixCollector
  @findings = nil

  def self.enable!
    @findings = []
  end

  def self.disable!
    @findings = nil
  end

  def self.enabled?
    !@findings.nil?
  end

  def self.push(finding)
    @findings << finding if @findings
  end

  def self.drain
    out = @findings || []
    @findings = [] if @findings
    out
  end
end
