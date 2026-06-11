# typed: strict
# MultiStatementLinter — emits a `clear fix` warning when a single
# source line contains more than one statement (multiple `;`-
# terminated statements at depth 0).
#
# Why warn but not auto-fix: splitting `a; b; c;` into three lines
# requires deciding indentation, blank-line treatment, and inline-
# comment placement. Those are judgement calls a fmt pass shouldn't
# make automatically — the user might genuinely have wanted a tight
# one-liner shape (e.g., for a hot-loop body they're debugging).
#
# Surfaced via FixCollector during `clear fix`. No-op when the
# collector is disabled, so normal `clear build` is unaffected.

require "sorbet-runtime"

require_relative '../ast/lexer'
require_relative '../ast/fixable_error'

module MultiStatementLinter
  extend T::Sig

  module_function

  sig { params(source: String).returns(T.nilable(Hash)) }
  def lint!(source)
    return unless FixCollector.enabled?

    line_to_semis = scan_top_level_semis(source)
    line_to_semis.each do |line_no, count|
      next if count < 2
      emit_finding(source, line_no)
    end
  end

  # Scan source forward, counting `;` at bracket-depth 0, grouped by
  # line. Inside `(...)`, `[...]`, `{...}`, strings, or comments the
  # `;` doesn't count — those are STRUCT-field separators, hash kv
  # separators, FOR-loop variants, etc. that legitimately share a
  # line.
  sig { params(source: String).returns(Hash) }
  def scan_top_level_semis(source)
    counts = Hash.new(0)
    line_no = 1
    depth = 0
    in_str = false
    in_triple = false
    i = 0
    while i < source.length
      c = source[i]
      if in_triple
        if source[i, 3] == '"""'
          in_triple = false
          i += 3
          next
        end
      elsif in_str
        if c == '\\' && i + 1 < source.length
          i += 2
          next
        elsif c == '"'
          in_str = false
        end
      else
        if source[i, 3] == '"""'
          in_triple = true
          i += 3
          next
        elsif c == '"'
          in_str = true
        elsif c == '#'
          # Skip to end of line.
          nl = source.index("\n", i) || source.length
          i = nl
          next
        elsif '([{'.include?(c)
          depth += 1
        elsif ')]}'.include?(c)
          depth -= 1 if depth > 0
        elsif c == ';' && depth.zero?
          counts[line_no] += 1
        end
      end
      if c == "\n"
        line_no += 1
      end
      i += 1
    end
    counts
  end

  def emit_finding(source, line_no)
    line_text = source.lines[line_no - 1] || ""
    anchor = Struct.new(:line, :column).new(line_no, 1)
    msg = "multiple statements on one line — split each `;`-terminated " \
          "statement to its own line for readability"
    finding = FixableFinding.new(
      level: :warning,
      message: msg,
      token: anchor,
      category: :lint,
      fixes: []  # no auto-fix; user has to decide layout
    )
    FixCollector.push(finding)
    _ = line_text  # reserved for future fix proposal
  end
  private :emit_finding
  private :scan_top_level_semis
  private_class_method :emit_finding
  private_class_method :scan_top_level_semis

end
