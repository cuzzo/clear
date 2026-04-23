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
