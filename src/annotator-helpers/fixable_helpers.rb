# FixableHelper — emission helpers for FixableError findings.
#
# Each helper converts a specific compiler diagnostic into a
# FixableFinding with one or more Fix candidates. The Fix's span points
# at the exact source text to replace; the CLI (`clear fix`) applies the
# edits right-to-left per file to keep byte offsets stable.
#
# Design principles:
# - Fixes that always do the right thing get `confidence: :auto`.
# - Fixes whose correctness depends on user intent get `:interactive`.
# - When a correct fix cannot be located (e.g., declaration not in
#   scope, token missing), fall back to the plain `error!` / stderr
#   path so nothing is silently swallowed.
#
# Helpers live here so `annotator.rb` stays focused on AST walking and
# ownership analysis. Mixed into SemanticAnnotator via `include`.

module FixableHelper
  # Location of the variable NAME inside a VarDecl/BindExpr. For a
  # `MUTABLE x = ...` declaration the node's token points at `MUTABLE`,
  # so the name starts 8 columns later ("MUTABLE " is 7 letters + 1
  # space). For an `x = ...` bind the token IS the name.
  def var_name_span(reg, name, file: nil)
    tok = reg.respond_to?(:token) ? reg.token : nil
    return nil unless tok
    col = tok.column
    if reg.respond_to?(:mutable) && reg.mutable && tok.respond_to?(:value) && tok.value == 'MUTABLE'
      col += 'MUTABLE '.length
    end
    Span.new(file: file, line: tok.line, col: col, length: name.length)
  end

  # Lint: `MUTABLE 'x' is never reassigned`. :auto fix removes the
  # `MUTABLE ` prefix (8 chars) at the VarDecl's column.
  def emit_mutable_unused_finding!(reg, name)
    return unless reg && reg.respond_to?(:token) && reg.token
    tok = reg.token
    fixes = []
    if tok.respond_to?(:value) && tok.value == 'MUTABLE'
      fixes << Fix.new(
        description: "Remove MUTABLE keyword (binding is never reassigned).",
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: tok.line, col: tok.column, length: 'MUTABLE '.length),
          replacement: ''
        )]
      )
    end

    if fixes.empty?
      loc = " (line #{reg.line})"
      $stderr.puts "\e[33m[Warning]\e[0m MUTABLE '#{name}' is never reassigned#{loc} — consider removing MUTABLE"
      return
    end

    fixable!(reg,
      message: "MUTABLE '#{name}' is never reassigned — consider removing MUTABLE",
      category: :lint,
      level: :warning,
      fixes: fixes)
  end

  # Return the name with the smallest Levenshtein distance from `input`
  # over `candidates`, provided it's within `max_distance`. Returns nil
  # when no candidate is close enough (don't suggest wild guesses).
  def closest_name(input, candidates, max_distance: 3)
    best = nil
    best_d = max_distance + 1
    candidates.each do |cand|
      d = levenshtein(input.to_s, cand.to_s)
      if d < best_d
        best = cand
        best_d = d
      end
    end
    best_d <= max_distance ? best : nil
  end

  def levenshtein(a, b)
    return b.length if a.empty?
    return a.length if b.empty?
    prev = (0..b.length).to_a
    a.each_char.with_index do |ac, i|
      curr = [i + 1]
      b.each_char.with_index do |bc, j|
        cost = ac == bc ? 0 : 1
        curr << [curr[j] + 1, prev[j + 1] + 1, prev[j] + cost].min
      end
      prev = curr
    end
    prev.last
  end

  # Registry: an ON/CATCH selector names an identifier that isn't in
  # the registry. When a close match exists, emit an :auto replace-
  # the-name fix; otherwise fall through to the plain `error!` path.
  #
  #   token       — the selector's name token (line/col used for the edit span)
  #   name        — the user-typed identifier (Symbol or String)
  #   candidates  — list of valid identifiers (Symbols or Strings)
  #   message     — user-facing error message when no fix is applicable
  #   fix_label   — short description of what the replacement represents
  #                 (e.g. "closest known kind", "closest registered type")
  def emit_registry_mismatch!(token, name, candidates, message, fix_label)
    best = closest_name(name, candidates)
    fixes = []
    if best
      fixes << Fix.new(
        description: "Replace '#{name}' with '#{best}' (#{fix_label}).",
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: token.line, col: token.column, length: name.to_s.length),
          replacement: best.to_s
        )]
      )
    end

    return error!(token, message) if fixes.empty?

    fixable!(token, message: message, category: :registry, level: :error, fixes: fixes)
  end

  # Registry-shaped: an identifier typo against a known candidate set
  # that isn't strictly a registry but has the same emit shape.
  # Replaces the identifier at `token` with the closest candidate when
  # one is within the Levenshtein threshold.
  #
  #   token       — the name token (line/col used for the edit span)
  #   name        — the user-typed identifier
  #   candidates  — list of valid identifiers (Symbols or Strings)
  #   message     — user-facing error message
  #   fix_label   — short description of the replacement source
  #                 ("closest in-scope variable", "field of MyStruct", ...)
  #   category    — :registry by default; callers can override
  #   cascade     — when true, the error's site isn't safe to continue
  #                 past (downstream code reads fields this visitor
  #                 would have set); the finding is captured and THEN
  #                 the annotator raises. Pass `false` at sites where
  #                 the enclosing visitor can cleanly bail out.
  def emit_typo_suggestion!(token, name, candidates, message, fix_label,
                            category: :registry, cascade: true)
    best = closest_name(name, candidates)
    fixes = []
    if best
      fixes << Fix.new(
        description: "Replace '#{name}' with '#{best}' (#{fix_label}).",
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: token.line, col: token.column, length: name.to_s.length),
          replacement: best.to_s
        )]
      )
    end

    return error!(token, message) if fixes.empty?

    fixable!(token, message: message, category: category, level: :error,
             fixes: fixes, raise_in_collector: cascade)
  end

  # Ownership: `Variable 'x' is immutable` on reassignment. :auto fix
  # locates the original declaration (via the enclosing scope's info)
  # and inserts `MUTABLE ` at its column. If the declaration can't be
  # located or already has `MUTABLE`, falls through to the plain error
  # path so the build still halts.
  def emit_immutable_assignment_error!(node, scope)
    info = scope.locals[node.name]
    decl = info&.reg
    fixes = []
    if decl && decl.respond_to?(:token) && decl.token
      tok = decl.token
      already_mutable = tok.respond_to?(:value) && tok.value == 'MUTABLE'
      unless already_mutable
        fixes << Fix.new(
          description: "Declare '#{node.name}' as MUTABLE at its binding site (line #{tok.line}).",
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: tok.line, col: tok.column, length: 0),
            replacement: 'MUTABLE '
          )]
        )
      end
    end

    return error!(node, "Variable '#{node.name}' is immutable") if fixes.empty?

    fixable!(node,
      message: "Variable '#{node.name}' is immutable",
      category: :ownership,
      level: :error,
      fixes: fixes)
  end
end
