# typed: strict
# Rule-driven scanner that detects common operator typos in CLEAR
# source (e.g. `s>` meant `|>`, `=>` meant `->`) and emits FixableFinding
# entries via FixCollector. Runs as a PRE-PARSE pass in `clear fix`;
# the legacy compile path does not invoke it, so behaviour there is
# unchanged.
#
# Why source-scan instead of lexer or parser hook?
# - Lexer-level rewriting would change the token stream for every
#   consumer, including tests that assert on exact tokens.
# - Parser-level pattern detection requires distinguishing intent
#   (did the user mean `|` then `>` or `|>`?) — hard without grammar.
# - A textual scan with string/comment skipping catches the visual
#   typo directly, at the line/col where the user typed it, with a
#   clean replacement span.
#
# String/comment skipping is conservative: we honour triple-quoted
# strings, single-quoted strings (including backslash escapes and
# `${...}` interpolation), and `#` line comments. When in doubt, we
# skip the scan rather than emit a false-positive finding.

require "sorbet-runtime"

require_relative "fixable_error"

module SyntaxTypoScanner
    extend T::Sig

  # One rule = (pattern, replacement, human-readable label for the fix).
  # Patterns are literal string matches, not regexes — intentional; a
  # regex would risk matching sub-strings of larger identifiers (e.g.
  # `selectors>` would have `s>` inside it, which would be wrong to flag).
  RULES = T.let([
    { match: 's>', replace: '|>', label: 'pipeline operator (use `|>`, not `s>`)' },
    { match: '=>', replace: '->', label: 'arrow (use `->`, not `=>`)' },
  ].freeze, T::Array[T.untyped])

  sig { params(source: String).returns(T.untyped) }
  def self.scan!(source)
    return unless FixCollector.enabled?
    return unless source && !source.empty?

    i = T.let(0, Integer)
    len = source.length
    line = T.let(1, Integer)
    col = T.let(1, Integer)
    in_single = T.let(false, T::Boolean)  # inside "..."
    in_triple = T.let(false, T::Boolean)  # inside """..."""

    while i < len
      # Triple-quoted string boundary
      if !in_single && source[i, 3] == '"""'
        in_triple = !in_triple
        i += 3; col += 3
        next
      end

      if in_triple
        i, line, col = T.unsafe(advance(source, i, line, col))
        next
      end

      # Single-quoted string boundary (respect \" escape)
      if !in_single && source[i] == '"'
        in_single = true
        i += 1; col += 1
        next
      end
      if in_single
        if source[i] == '\\' && i + 1 < len
          i += 2; col += 2
          next
        end
        if source[i] == '"'
          in_single = false
          i += 1; col += 1
          next
        end
        i, line, col = T.unsafe(advance(source, i, line, col))
        next
      end

      # Line comment — skip to newline
      if source[i] == '#'
        while i < len && source[i] != "\n"
          i += 1; col += 1
        end
        next
      end

      # Check each rule at this position. For patterns whose first
      # char is an identifier char (e.g. `s>`), require the preceding
      # char to be a non-identifier so we don't flag `selectors>` or
      # similar valid identifiers.
      matched = T.let(false, T::Boolean)
      RULES.each do |r|
        pat = r[:match]
        next unless source[i, pat.length] == pat
        if T.must(pat)[0] =~ /[A-Za-z_]/ && i > 0 && source[i - 1] =~ /[A-Za-z0-9_]/
          next
        end
        emit_typo_finding!(line, col, r)
        i += T.must(pat).length
        col += T.must(pat).length
        matched = true
        break
      end
      next if matched

      i, line, col = T.unsafe(advance(source, i, line, col))
    end
  end

  sig { params(source: String, i: Integer, line: Integer, col: Integer).returns(T::Array[Integer]) }
  def self.advance(source, i, line, col)
    if source[i] == "\n"
      [i + 1, line + 1, 1]
    else
      [i + 1, line, col + 1]
    end
  end

  sig { params(line: Integer, col: Integer, rule: T.untyped).returns(T.nilable(T::Array[FixableFinding])) }
  def self.emit_typo_finding!(line, col, rule)
    fix = Fix.new(
      description: "Replace `#{rule[:match]}` with `#{rule[:replace]}` — #{rule[:label]}.",
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: line, col: col, length: rule[:match].length),
        replacement: rule[:replace]
      )]
    )

    anchor = Struct.new(:line, :column).new(line, col)
    finding = FixableFinding.new(
      level: :error,
      message: "Unknown operator `#{rule[:match]}` — did you mean `#{rule[:replace]}`?",
      token: anchor,
      category: :type,
      fixes: [fix]
    )
    FixCollector.push(finding)
  end
end
