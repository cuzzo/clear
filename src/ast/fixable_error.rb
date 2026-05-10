# typed: true
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

require "sorbet-runtime"

require_relative "source_error"
require_relative "diagnostic_registry"

class Span
    extend T::Sig

  attr_reader :file, :line, :col, :length

  sig { params(file: NilClass, line: Integer, col: Integer, length: Integer).void }
  def initialize(file:, line:, col:, length:)
    @file = file
    @line = line
    @col = col
    @length = length
  end

  # End line / column — useful for LSP-style range diagnostics. For a
  # single-line span these equal `line` / `col + length`. For multi-line
  # replacements (e.g., inserting a block), callers can subclass or pass
  # a separate end position.
  def end_line; @line; end
  def end_col;  @col + @length; end

  def to_h
    { file: @file, line: @line, col: @col, length: @length,
      end_line: end_line, end_col: end_col }
  end
end

class Edit
    extend T::Sig

  attr_reader :span, :replacement

  sig { params(span: Span, replacement: String).void }
  def initialize(span:, replacement:)
    @span = span
    @replacement = replacement
  end
end

class Fix
  extend T::Sig

  CONFIDENCES = [:auto, :interactive].freeze

  attr_reader :description, :confidence, :edits

  sig { params(description: String, edits: Array, confidence: Symbol).void }
  def initialize(description:, edits:, confidence: :interactive)
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
    extend T::Sig

  # Ordered low-to-high; the set matches LSP's four DiagnosticSeverity
  # values (Hint, Information, Warning, Error). :error is the only
  # blocking level; everything else is advisory.
  LEVELS = [:hint, :info, :warning, :error].freeze
  # Delegated to the unified DiagnosticRegistry so a `category:` value
  # accepted by `error!(:CODE, ...)` is also accepted by `fixable!`.
  CATEGORIES = DiagnosticRegistry::CATEGORIES

  attr_reader :level, :message, :token, :category, :fixes

  sig { params(level: Symbol, message: String, token: T.untyped, category: Symbol, fixes: T::Array[Fix]).void }
  def initialize(level:, message:, token:, category:, fixes:)
    raise ArgumentError, "bad level #{level.inspect}" unless LEVELS.include?(level)
    raise ArgumentError, "bad category #{category.inspect}" unless CATEGORIES.include?(category)
    @level = level
    @message = message
    @token = token
    @category = category
    @fixes = Array(fixes)
    # An empty `fixes` is permitted for diagnostic-only findings (e.g.
    # gradual-typing's ambiguity / unresolved-Auto reports — see
    # docs/agents/gradual-typing.md §4.3 / §6). The CLI's `clear fix`
    # iterates `.fixes` and naturally skips findings with no
    # applicable fix; the message is still surfaced.
  end

  sig { returns(T::Boolean) }
  def fatal?; @level == :error; end
end

# Process-wide collector. `clear fix` enables it before running the
# frontend; every other caller (including `clear build` / `clear run`)
# leaves it disabled so behaviour is unchanged.
#
# When enabled, `fixable!` does NOT raise on `level: :error` — the
# finding is recorded and the caller returns normally. This lets the
# annotator accumulate every fixable diagnostic in a single pass (the
# shape an LSP needs for `textDocument/publishDiagnostics`). The
# original compiler still halts on downstream passes when fatal
# findings exist; `has_fatal?` / `fatal_count` expose that signal to
# the CLI.
module FixCollector
    extend T::Sig

  @findings = T.let(nil, T.nilable(T::Array[FixableFinding]))

  sig { returns(Array) }
  def self.enable!
    @findings = []
  end

  sig { returns(T.untyped) }
  def self.disable!
    @findings = nil
  end

  sig { returns(T::Boolean) }
  def self.enabled?
    !@findings.nil?
  end

  sig { params(finding: FixableFinding).returns(T.nilable(T::Array[FixableFinding])) }
  def self.push(finding)
    @findings << finding if @findings
  end

  sig { returns(Array) }
  def self.drain
    out = @findings || []
    @findings = [] if @findings
    out
  end

  def self.has_fatal?
    @findings && @findings.any?(&:fatal?)
  end

  def self.fatal_count
    @findings ? @findings.count(&:fatal?) : 0
  end
end
