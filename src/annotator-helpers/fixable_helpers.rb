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

  # Synthesize a token-like anchor at an explicit (line, col). Used by
  # migrations whose error node doesn't carry a separate token for the
  # offending identifier (e.g., `Shape.Circl` — the field name 'Circl'
  # is a String in GetField, not a Token).
  #
  # Carries `type`/`value` stubs so `SourceError#build_message` — which
  # reads `@token.type == :EOF` — doesn't NPE when the anchor flows
  # through to the legacy error path in non-collector mode.
  AnchorToken = Struct.new(:line, :column) do
    def type; :ANCHOR; end
    def value; nil; end
  end

  def anchor_at(line, col)
    AnchorToken.new(line, col)
  end

  # Given a Type.Variant style GetField, compute the token line/col of
  # the variant name (right after `target.` — length of target + 1).
  def variant_anchor_from_getfield(getfield_node)
    tgt = getfield_node.target
    return nil unless tgt.respond_to?(:token) && tgt.token
    anchor_at(tgt.token.line, tgt.token.column + tgt.name.to_s.length + 1)
  end

  # For a UnionVariantLit `Union.Variant{...}`, the node's token is the
  # opening `{` — the variant name ends right before it, so the name's
  # start column is `token.column - variant_name.length`.
  def variant_anchor_from_unionlit(node, variant_name)
    return nil unless node.respond_to?(:token) && node.token
    anchor_at(node.token.line, node.token.column - variant_name.to_s.length)
  end

  # Typo-suggestion wrapper that takes an (line, col, name, length)
  # instead of a Token. Used by migrations whose error token comes
  # from a synthesized anchor.
  def emit_variant_typo!(anchor, name, candidates, message, fix_label,
                         cascade: false)
    best = closest_name(name, candidates)
    fixes = []
    if best
      fixes << Fix.new(
        description: "Replace '#{name}' with '#{best}' (#{fix_label}).",
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: anchor.line, col: anchor.column, length: name.to_s.length),
          replacement: best.to_s
        )]
      )
    end

    return error!(anchor, message) if fixes.empty?

    fixable!(anchor, message: message, category: :type, level: :error,
             fixes: fixes, raise_in_collector: cascade)
  end

  # Ownership: `Use of moved value 'x'`. Uses move-site tracking on
  # the OwnershipGraph node + (optional) annotator `source_code` to
  # build up to three interactive candidates:
  #
  #   1. Wrap the consuming reference with `COPY` at the move site.
  #      Always available when the move site is tracked.
  #   2. Change the declaration to `@multiowned` — single-scheduler Rc;
  #      moves become automatic clones. Available when we can locate
  #      the declaration's `;` (via source_code).
  #   3. Change the declaration to `@shared` — atomic Arc; safe across
  #      fibers and schedulers. Same requirement as (2).
  #
  # When the move site isn't tracked (e.g., branch-merge paths, BG
  # captures), fall through to the plain `error!` so the legacy
  # diagnostic still surfaces.
  def emit_use_of_moved_error!(use_node, og_node)
    name = use_node.name.to_s
    return error!(use_node, "Use of moved value '#{name}'") unless og_node
    return error!(use_node, "Use of moved value '#{name}'") unless og_node.move_line && og_node.move_col

    fixes = []
    fixes << Fix.new(
      description: "Wrap the consuming reference with COPY at line #{og_node.move_line} " \
                   "(the original survives for the later use).",
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: og_node.move_line, col: og_node.move_col, length: name.length),
        replacement: "(COPY #{name})"
      )]
    )

    # Declaration-level `@multiowned` / `@shared` fixes — append after
    # the value expression (before the statement-terminating `;`).
    scope = lookup_scope_for(name)
    decl = scope&.locals&.[](name)&.reg
    src = @source_code
    if decl && decl.respond_to?(:token) && decl.token && src
      dline = decl.token.line
      line_text = src.lines[dline - 1] || ''
      # Find the `;` that terminates the declaration (skip trailing
      # whitespace). Only suggest capability upgrades when the `;` is
      # on the same physical line as the declaration — multi-line
      # value expressions would need a broader span calc.
      semi_idx = line_text.index(';')
      if semi_idx
        insert_col = semi_idx + 1  # 1-based column at the `;`
        ['@multiowned', '@shared'].each do |cap|
          fixes << Fix.new(
            description: "Change '#{name}' to `#{cap}` at its declaration " \
                         "(#{cap == '@multiowned' ? 'single-scheduler Rc; automatic clone on move' : 'atomic Arc; safe across fibers'}).",
            confidence: :interactive,
            edits: [Edit.new(
              span: Span.new(file: nil, line: dline, col: insert_col, length: 0),
              replacement: " #{cap}"
            )]
          )
        end
      end
    end

    fixable!(use_node,
      message: "Use of moved value '#{name}' (moved at line #{og_node.move_line})",
      category: :ownership,
      level: :error,
      fixes: fixes,
      raise_in_collector: true)
  end

  # Type: `Integer literal N overflows T (range ...)`. When the
  # literal is written in suffixed form (`1000_u8`) and there's a
  # wider known type that fits the value, emit an :auto fix that
  # replaces just the suffix. Annotation-form overflows (`x: Byte =
  # 1000`) fall through to the legacy error path — locating the
  # annotation token from the literal's context is non-trivial and
  # deferred.
  INT_SUFFIXES = {
    Int8: 'i8', Byte: 'u8',
    Int16: 'i16', UInt16: 'u16',
    Int32: 'i32', UInt32: 'u32',
    Int64: 'i64', UInt64: 'u64',
  }.freeze

  # Order smallest-first so `find` picks the tightest fit.
  SIGNED_ORDER    = [:Int8,  :Int16,  :Int32,  :Int64 ].freeze
  UNSIGNED_ORDER  = [:Byte,  :UInt16, :UInt32, :UInt64].freeze

  def smallest_fitting_int_type(val)
    order = val >= 0 ? UNSIGNED_ORDER : SIGNED_ORDER
    order.find do |t|
      max = Type::INT_TYPE_MAX[t]
      min = Type::INT_TYPE_MIN[t] || 0
      val >= min && val <= max
    end
  end

  def emit_int_overflow_error!(node, val, target_type, min, max)
    msg = "Integer literal (#{val}) overflows #{target_type} (range #{min}..#{max})"
    tok = node.respond_to?(:token) ? node.token : nil
    return error!(node, msg) unless tok && @source_code

    best = smallest_fitting_int_type(val)
    return error!(node, msg) unless best

    line_text = @source_code.lines[tok.line - 1] || ''

    # Prefer the suffix form first (precise span; local replacement).
    snippet = line_text[(tok.column - 1)..] || ''
    if (m = snippet.match(/\A(\d[\d_]*)_([a-z]\d+)/))
      old_suffix = m[2]
      new_suffix = INT_SUFFIXES[best]
      if new_suffix && new_suffix != old_suffix
        suffix_col = tok.column + m[1].length + 1
        return emit_overflow_suffix_fix!(node, msg, tok, suffix_col, old_suffix, new_suffix, val)
      end
    end

    # Annotation form: scan the line for `: <target_type>` and replace
    # the type token (e.g., `x: Byte = 1000` -> `x: UInt16 = 1000`).
    target_name = target_type.to_s
    ann_match = line_text.match(/:\s*(#{Regexp.escape(target_name)})\b/)
    if ann_match
      ann_col = ann_match.begin(1) + 1  # 1-based column of the type name
      new_type = best.to_s
      if new_type != target_name
        fix = Fix.new(
          description: "Widen annotation `#{target_name}` to `#{new_type}` (smallest type that fits #{val}).",
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: tok.line, col: ann_col, length: target_name.length),
            replacement: new_type
          )]
        )
        return fixable!(node,
          message: msg,
          category: :type,
          level: :error,
          fixes: [fix],
          raise_in_collector: true)
      end
    end

    error!(node, msg)
  end

  def emit_overflow_suffix_fix!(node, msg, tok, suffix_col, old_suffix, new_suffix, val)
    fix = Fix.new(
      description: "Widen suffix `_#{old_suffix}` to `_#{new_suffix}` (smallest type that fits #{val}).",
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: tok.line, col: suffix_col, length: old_suffix.length),
        replacement: new_suffix
      )]
    )
    fixable!(node,
      message: msg,
      category: :type,
      level: :error,
      fixes: [fix],
      raise_in_collector: true)
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
