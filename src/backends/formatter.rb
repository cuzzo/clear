# CLEAR source formatter.
#
# Status: v0 (indent + blank-line + trailing-whitespace normalization).
#
# v0 guarantees:
#   - Refuses to write on parse error (exits non-zero).
#   - Re-computes 2-space indent from block structure:
#       opens:  `{`, `THEN`, `DO`, `->`  when they are the last code token on a line
#       closes: `END`, `}`                when they are the first token on a line
#       outdents (line-start only): `ELSE`, `ELSE_IF`, `CATCH`, `DEFAULT`
#   - Collapses 3+ consecutive blank lines to 2.
#   - Ensures exactly one blank line before `CATCH` / `DEFAULT` clauses.
#   - Strips trailing whitespace on every line.
#   - Preserves comments in place (by line preservation; intra-line content is not rewritten).
#   - Idempotent: fmt(fmt(x)) == fmt(x).
#
# Deferred to v1+ (documented here so nothing is lost):
#   - Intra-line spacing canonicalization (around operators, after commas, no-space inside
#     parens/brackets, no space between tense sigils and type: `!T` `?T` `%T` `~T`).
#   - Capability attach rules (type-position: `T@locked`; value-position: `1 @locked`,
#     `foo() @locked`).
#   - Forced multi-line for FN (no one-liners).
#   - FN signature forced wrap when >120 chars (`)`, `RETURNS T ->` at FN column).
#   - WITH: 2+ captures OR single cap >120 -> each capture on its own line,
#     body at +2, closing `}` at +1.
#   - WITH with ON clause: body at +2, closing `}` at +1, `ON ...` at +1.
#   - Pipeline: 2+ `s>` stages on their own lines; `s> RECOVER(...)` gets one
#     extra indent level relative to sibling `s>` stages.
#   - Method chain: >3 calls OR >80 chars -> one `.call()` per line.
#   - Pipeline/chain assignment: if first line >80 chars, drop RHS; receiver at +1,
#     chain/stages at +2.
#   - STRUCT / UNION / ENUM: one item per line (unconditional).
#   - Integer `_` separators (needs parser support).
#   - Warn-only width checks at 120 chars for non-forced-wrap cases.
#   - Ambiguous-comment-attachment detection + refuse-to-write with context.
#   - Continuation indent (context-aware, deferred last).

require_relative '../ast/lexer'
require_relative '../ast/parser'

class Formatter
  class Error < StandardError; end

  INDENT = '  '

  OPEN_TERMINAL   = %w[-> { THEN DO].freeze
  CLOSE_LEADING   = %w[END }].freeze
  OUTDENT_LEADING = %w[ELSE ELSE_IF CATCH DEFAULT].freeze
  BLANK_BEFORE    = %w[CATCH DEFAULT].freeze

  def self.format(source)
    new(source).format
  end

  def initialize(source)
    @source = source
  end

  def format
    validate_parse!
    lines = @source.lines
    lines = lines.map { |l| strip_trailing_ws(l) }
    lines = reindent(lines)
    lines = collapse_blanks(lines)
    lines = ensure_blank_before_catch(lines)
    lines = trim_trailing_blanks(lines)
    ensure_trailing_newline(lines.join)
  end

  private

  # -- validation ----------------------------------------------------------

  def validate_parse!
    tokens = ::Lexer.new(@source).tokenize
    ::Parser.new(tokens, @source).parse
  rescue => e
    raise Error, "parse error: #{e.message}"
  end

  # -- whitespace normalization -------------------------------------------

  def strip_trailing_ws(line)
    has_nl = line.end_with?("\n")
    stripped = line.sub(/[ \t]+(?=\n|\z)/, '')
    stripped += "\n" if has_nl && !stripped.end_with?("\n")
    stripped
  end

  def collapse_blanks(lines)
    result = []
    blanks = 0
    lines.each do |l|
      if blank_line?(l)
        blanks += 1
        next
      end
      emit_blanks = [blanks, 2].min
      emit_blanks.times { result << "\n" }
      blanks = 0
      result << l
    end
    # Trailing blanks handled separately; drop them all here.
    result
  end

  def blank_line?(line)
    line.sub(/\n\z/, '').strip.empty?
  end

  def trim_trailing_blanks(lines)
    while lines.last && blank_line?(lines.last)
      lines.pop
    end
    lines
  end

  def ensure_trailing_newline(s)
    s.end_with?("\n") ? s : s + "\n"
  end

  def ensure_blank_before_catch(lines)
    result = []
    lines.each_with_index do |l, i|
      body = l.lstrip
      first = first_word(body)
      if BLANK_BEFORE.include?(first) && !result.empty?
        # back up over trailing blanks we already emitted
        while result.last && blank_line?(result.last)
          result.pop
        end
        result << "\n" unless result.empty?
      end
      result << l
    end
    result
  end

  def first_word(body)
    return nil if body.empty? || body.start_with?('--')
    m = body.match(/\A([A-Z_][A-Z_0-9]*)\b/)
    m && m[1]
  end

  # -- indent recomputation ------------------------------------------------

  def reindent(lines)
    depth = 0
    out = []
    lines.each do |raw|
      content = raw.sub(/\A[ \t]+/, '')
      nl = content.end_with?("\n") ? "\n" : ""
      body = content.sub(/\n\z/, '')

      if body.empty?
        out << nl
        next
      end

      first_tok = leading_token(body)
      last_tok  = trailing_token(body)

      if CLOSE_LEADING.include?(first_tok)
        depth = [depth - 1, 0].max
        line_depth = depth
      elsif OUTDENT_LEADING.include?(first_tok)
        line_depth = [depth - 1, 0].max
      else
        line_depth = depth
      end

      out << (INDENT * line_depth) + body + nl

      # Block-open: adjust depth for subsequent lines.
      if OPEN_TERMINAL.include?(last_tok)
        depth += 1
      end
    end
    out
  end

  # Return the first meaningful token on a line (after stripping leading indent).
  # A leading `--` comment line returns nil (comments don't affect depth).
  def leading_token(body)
    s = body.lstrip
    return nil if s.empty? || s.start_with?('--')
    # Match keywords, identifiers, or single-char block punctuation.
    m = s.match(/\A([A-Z_][A-Z_0-9]*|\{|\})/)
    return nil unless m
    tok = m[1]
    # Must be at a boundary (keyword followed by non-word char or end).
    return tok
  end

  # Return the trailing code token on a line, ignoring a trailing `--` comment.
  # Only returns the token if it matters for depth tracking (one of OPEN_TERMINAL
  # or a punctuation we care about); otherwise returns nil.
  def trailing_token(body)
    code = strip_trailing_comment(body).rstrip
    return nil if code.empty?

    # Check for the specific open terminals.
    return '->'   if code.end_with?('->')
    return '{'    if code.end_with?('{')
    return 'THEN' if code =~ /\bTHEN\s*\z/
    return 'DO'   if code =~ /\bDO\s*\z/
    nil
  end

  # Strip a trailing `--` line comment, being careful not to cut inside a
  # string literal. Handles `"..."` (respecting backslash escapes) and
  # `"""..."""` triple-quoted strings.
  def strip_trailing_comment(line)
    i = 0
    len = line.length
    in_single = false  # inside "..."
    in_triple = false  # inside """..."""
    while i < len
      c = line[i]

      if !in_single && line[i, 3] == '"""'
        in_triple = !in_triple
        i += 3
        next
      end

      if in_triple
        i += 1
        next
      end

      if c == '"' && (i == 0 || line[i - 1] != '\\')
        in_single = !in_single
        i += 1
        next
      end

      if !in_single && c == '-' && line[i + 1] == '-'
        return line[0...i]
      end

      i += 1
    end
    line
  end
end
