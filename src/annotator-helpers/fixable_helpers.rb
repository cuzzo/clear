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
    move_action = ownership_move_action_label(og_node.move_action)
    move_suffix = move_action ? " by #{move_action}" : ""

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
      message: "Use of moved value '#{name}' (moved at line #{og_node.move_line}#{move_suffix})",
      category: :ownership,
      level: :error,
      fixes: fixes,
      raise_in_collector: true)
  end

  def ownership_move_action_label(action)
    case action
    when :share then "SHARE"
    when :give then "GIVE"
    when :takes then "TAKES"
    when :return then "RETURN"
    when :next then "NEXT"
    when :collect then "COLLECT"
    when :capture then "capture"
    else nil
    end
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

  # Lint: `Variable 'x' is @local but never shared across fibers`. When
  # we have the annotator's source text, find `@local` on the
  # declaration's source line and emit an :auto fix that removes it
  # (plus one adjacent space). Falls back to a plain stderr note when
  # source isn't available or the text isn't found on the line.
  def emit_local_never_shared_finding!(info)
    name = info[:var]
    line = info[:line]
    msg = "Variable '#{name}' is @local but never shared across fibers. " \
          "You are paying for a heap allocation with no sharing benefit. Consider removing @local."
    fixes = []

    if @source_code && line
      src_line = @source_code.lines[line - 1] || ''
      idx = src_line.index('@local')
      if idx
        trail = (src_line[idx + 6] == ' ') ? 1 : 0
        lead  = (idx > 0 && src_line[idx - 1] == ' ') ? 1 : 0
        start_col = idx + 1 - lead
        length    = 6 + lead + trail
        fixes << Fix.new(
          description: "Remove `@local` capability from '#{name}' (never shared across fibers).",
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: line, col: start_col, length: length),
            replacement: ''
          )]
        )
      end
    end

    if fixes.empty?
      loc = line ? " (line #{line})" : ""
      $stderr.puts "\e[36m[Note]\e[0m #{msg}#{loc}"
      return
    end

    anchor = anchor_at(line, info[:column] || 1)
    fixable!(anchor,
      message: msg,
      category: :lint,
      level: :info,
      fixes: fixes)
  end

  # Ownership: `Variable 'x' is immutable` on reassignment. :auto fix
  # locates the original declaration and inserts `MUTABLE ` at its
  # column.
  def emit_immutable_assignment_error!(node, scope)
    fix = build_declare_mutable_fix(node.name, scope)
    return error!(node, "Variable '#{node.name}' is immutable") unless fix
    fixable!(node,
      message: "Variable '#{node.name}' is immutable",
      category: :ownership,
      level: :error,
      fixes: [fix])
  end

  # Ownership: `Argument i ('param') is MUTABLE, but you passed
  # immutable variable 'x'`. Same fix shape as the assignment case —
  # declare the passed variable MUTABLE at its binding site.
  def emit_immutable_arg_error!(arg_node, scope, arg_idx, param_name)
    fix = build_declare_mutable_fix(arg_node.name, scope)
    msg = "Argument #{arg_idx} ('#{param_name}') is MUTABLE, but you passed immutable variable '#{arg_node.name}'."
    return error!(arg_node, msg) unless fix
    fixable!(arg_node,
      message: msg,
      category: :ownership,
      level: :error,
      fixes: [fix],
      raise_in_collector: true)
  end

  # Shared helper — returns a Fix that inserts `MUTABLE ` at the
  # declaration of `name` in `scope`. Returns nil when the declaration
  # isn't locatable or already carries `MUTABLE`.
  def build_declare_mutable_fix(name, scope)
    info = scope.locals[name]
    decl = info&.reg
    return nil unless decl && decl.respond_to?(:token) && decl.token
    tok = decl.token
    return nil if tok.respond_to?(:value) && tok.value == 'MUTABLE'

    Fix.new(
      description: "Declare '#{name}' as MUTABLE at its binding site (line #{tok.line}).",
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: tok.line, col: tok.column, length: 0),
        replacement: 'MUTABLE '
      )]
    )
  end

  # Atomics M2.8: a M2.6 lifetime error fired (escape via store /
  # field-assign / RETURN) AND the offending source binding's sync
  # axis is `:atomic`. Build a Fix that swaps `@shared:atomic` to
  # `@shared:locked` at the source's declaration line so `clear fix`
  # has a concrete edit to surface; the `:interactive` confidence
  # forces the user to review (the migration is more involved than
  # a sigil swap -- `@shared:locked` typically requires a STRUCT
  # wrap around the primitive). Returns nil when source isn't
  # atomic or the decl line text isn't locatable; the caller then
  # falls back to the plain `error!` path.
  def build_atomic_escape_migration_fix(source_sym, source_name)
    return nil unless source_sym && source_sym.respond_to?(:sync) && source_sym.sync == :atomic
    return nil unless @source_code
    reg = source_sym.respond_to?(:reg) ? source_sym.reg : nil
    return nil unless reg && reg.respond_to?(:token) && reg.token
    line_num = reg.token.line
    return nil unless line_num
    src_line = @source_code.lines[line_num - 1] || ''
    # The sigil chain is order-independent: `@shared:atomic` and
    # `@atomic:shared` parse to the same Type. Match either form.
    match = src_line.match(/@(?:shared:atomic|atomic:shared)/)
    return nil unless match
    start_col = match.begin(0) + 1   # 1-based column

    Fix.new(
      description: "Migrate '#{source_name}' from `@shared:atomic` to " \
                   "`@shared:locked` so its lifetime can outlive the " \
                   "declaring scope. NOTE: `@shared:locked` typically " \
                   "needs a STRUCT wrap around the primitive (e.g. " \
                   "`STRUCT Counter { v: Int64 }; c = Counter{v: 0} " \
                   "@shared:locked`); read/write sites become " \
                   "`WITH EXCLUSIVE c AS a { ... }`. Alternatively, " \
                   "wait for v0.3 atomic struct fields, which lift " \
                   "this escape restriction without the Arc cost.",
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: line_num, col: start_col, length: match[0].length),
        replacement: '@shared:locked'
      )]
    )
  end

  # ---------------------------------------------------------------
  # Auto / gradual-typing fixable findings (M1.4) + operator-aware
  # suggestions (M2.1). See docs/agents/gradual-typing.md §6 and §12.
  # ---------------------------------------------------------------

  # Per-operator candidate-type table for M2.1 suggestions. Each
  # entry: { default: Symbol, alts: [Symbol], notes: { Sym => String } }.
  # The :default candidate is ranked first; :alts follow in order.
  # When multiple operators apply to the same slot, the candidate
  # set is the INTERSECTION across ops; ranking is by lowest sum of
  # per-op indices (most-default-across-the-board wins).
  AUTO_OP_CANDIDATES = {
    ADD:        { default: :Int64,   alts: [:Float64, :String] },
    SUB:        { default: :Int64,   alts: [:Float64] },
    MUL:        { default: :Int64,   alts: [:Float64] },
    DIV:        { default: :Float64, alts: [:Int64],
                  notes: { Int64: "integer division — TRUNCATES toward zero" } },
    MOD:        { default: :Int64,   alts: [] },
    EQ:         { default: :Int64,   alts: [:Float64, :String] },
    NEQ:        { default: :Int64,   alts: [:Float64, :String] },
    LT:         { default: :Int64,   alts: [:Float64, :String] },
    GT:         { default: :Int64,   alts: [:Float64, :String] },
    LTE:        { default: :Int64,   alts: [:Float64, :String] },
    GTE:        { default: :Int64,   alts: [:Float64, :String] },
    AND:        { default: :Bool,    alts: [] },
    OR:         { default: :Bool,    alts: [] },
  }.freeze

  # Rank candidate concrete types from a Set<op_symbol> per the
  # AUTO_OP_CANDIDATES table. Returns [[type_sym, note_or_nil], ...]
  # ordered by:
  #   1. Type appears in EVERY observed op's candidate list (intersection).
  #   2. Sum of per-op rank (default = 0, first alt = 1, ...) ascending.
  # Notes carried through from any op that has a note for that type.
  def auto_rank_candidates(ops)
    return [] if ops.nil? || ops.empty?

    # Per-type aggregation across ops.
    agg = {}  # type_sym => { count:, rank_sum:, notes: [] }
    ops.each do |op|
      entry = AUTO_OP_CANDIDATES[op]
      next unless entry
      ranked = [entry[:default]] + entry[:alts]
      ranked.each_with_index do |type_sym, idx|
        agg[type_sym] ||= { count: 0, rank_sum: 0, notes: [] }
        agg[type_sym][:count]    += 1
        agg[type_sym][:rank_sum] += idx
        if entry[:notes] && entry[:notes][type_sym]
          agg[type_sym][:notes] << entry[:notes][type_sym]
        end
      end
    end

    # Only keep candidates that appear for EVERY observed op
    # (intersection — otherwise we'd suggest a type for which one
    # of the user's operations has no defined behavior).
    n_ops = ops.size
    intersection = agg.select { |_, v| v[:count] == n_ops }
    intersection
      .sort_by { |_, v| v[:rank_sum] }
      .map { |type_sym, v| [type_sym, v[:notes].uniq.first] }
  end

  # Build an :interactive Fix for a single operator-derived candidate.
  # Returns nil when the slot has no Auto token to replace (implicit
  # Auto under --gradual; for those the diagnostic still surfaces the
  # candidates as text but no auto-applicable fix).
  def build_auto_candidate_fix(slot, type_sym, note, position)
    auto_tok = auto_token_for(slot)
    return nil unless auto_tok
    type_str = type_sym.to_s
    desc = +"(#{position}) Pin #{auto_slot_label(slot)} to `#{type_str}`."
    desc << " #{note}" if note
    Fix.new(
      description: desc,
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: auto_tok.line, col: auto_tok.column, length: 'Auto'.length),
        replacement: type_str,
      )]
    )
  end

  # Build the diagnostic body listing the operator hints + ranked
  # candidates. Used by both the unresolved and ambiguity finding
  # builders when op_evidence is present.
  def build_auto_op_evidence_block(ops, candidates)
    return "" if candidates.empty?
    op_list = ops.to_a.sort.join(", ")
    msg = +"\n  In the body, the binding is used in operator(s): #{op_list}.\n"
    msg << "  Suggested fixes:\n"
    candidates.each_with_index do |(type_sym, note), idx|
      label = idx == 0 ? "(recommended)" : ""
      line = "    #{idx + 1}. #{label.ljust(15)} #{type_sym}"
      line << "  -- #{note}" if note
      msg << line << "\n"
    end
    msg
  end

  # ---------------------------------------------------------------
  # Auto / gradual-typing fixable findings (M1.4).
  # See docs/agents/gradual-typing.md §5 (clear fix integration) and
  # §6 (ambiguity resolution) for the diagnostic-format spec.
  # ---------------------------------------------------------------

  # Resolved Auto slot. Emits an :info finding with an :auto fix that
  # replaces the explicit `Auto` keyword with the resolved type's
  # source form. For implicit-Auto slots (omitted under `--gradual`),
  # there is no token to replace — we still emit the :info finding so
  # the user sees what was inferred, but no auto fix.
  #
  # M2.2: shape-tagged slots are skipped here. Per-sub-slot findings
  # would offer wrong fix replacements (writing the scalar element /
  # key / value type into the binding's `Auto` slot, which holds the
  # whole container type). The caller emits one binding-level
  # finding per shape-tracked decl via `emit_auto_shape_resolved_finding!`.
  def emit_auto_resolved_finding!(resolution)
    slot = resolution.slot
    return if slot.respond_to?(:shape) && slot.shape

    type_str = auto_type_source_form(resolution.type)
    label = auto_slot_label(slot)
    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || slot.decl_node,
      message: "Inferred type for #{label}: #{type_str}.",
      category: :type, level: :info,
      fixes: build_auto_replace_fixes(auto_tok, type_str),
    )
  end

  # M2.2 — Emits a single :info finding per shape-tracked decl whose
  # `decl.type` has been successfully wrapped by `stamp_slot!` /
  # `stamp_map_pairs!` (i.e., for lists when the element type
  # resolved, for maps when both key and value resolved). The fix
  # replacement is the wrapped type's source form so the user's
  # `clear fix` rewrites `Auto` to e.g. `Int64[]` /
  # `HashMap<String, Int64>` rather than the misleading scalar.
  # Partial map resolutions intentionally produce no resolved
  # finding here — the unresolved sub-slot's finding tells the
  # user what's missing.
  def emit_auto_shape_resolved_finding!(decl, slot)
    return unless decl && decl.type.is_a?(Type)
    return if decl.type.auto?  # not yet wrapped — skip
    type_str = auto_type_source_form(decl.type)
    name = decl.respond_to?(:name) ? decl.name : "<binding>"
    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || decl,
      message: "Inferred type for `#{name}`: #{type_str}.",
      category: :type, level: :info,
      fixes: build_auto_replace_fixes(auto_tok, type_str),
    )
  end

  # Shared `:auto`-confidence Fix builder: returns `[Fix]` that
  # replaces the literal `Auto` keyword span with `type_str`. Empty
  # array if `auto_tok` is nil (implicit-Auto under `--gradual` —
  # there's no token span to edit).
  def build_auto_replace_fixes(auto_tok, type_str)
    return [] unless auto_tok
    [Fix.new(
      description: "Replace `Auto` with the inferred type `#{type_str}`.",
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: auto_tok.line, col: auto_tok.column, length: 'Auto'.length),
        replacement: type_str,
      )]
    )]
  end

  # Ambiguous Auto slot — two or more incompatible observed types.
  # Emits :error with the ranked Option-1 / Option-2 / Option-3 text
  # per spec §6. None of the proposed actions are :auto: the user
  # must pick a concrete type and either narrow callsites or build a
  # union. v1 includes the option text in the message; per-callsite
  # conversion fixes are a follow-up (would require knowing each
  # callsite's argument span and a coercion table). M2.1 layers
  # operator-derived candidates on top: when the body uses the
  # binding in operator expressions, those operators' default types
  # are offered as :interactive Fixes.
  def emit_auto_ambiguity_finding!(ambiguity, op_evidence: {})
    slot = ambiguity.slot
    label = auto_slot_label(slot)
    observed = ambiguity.observed_types
    observed_strs = observed.map { |t| auto_type_source_form(t) }

    message = build_auto_ambiguity_message(label, observed_strs, slot)

    # M2.1: append operator-derived suggestions when present.
    ops = op_evidence[slot_id_for(slot)] || Set.new
    candidates = auto_rank_candidates(ops)
    message += build_auto_op_evidence_block(ops, candidates) unless candidates.empty?

    fixes = candidates.each_with_index
                      .filter_map { |(type_sym, note), i|
                        build_auto_candidate_fix(slot, type_sym, note, i + 1)
                      }

    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || slot.decl_node,
      message: message, category: :type, level: :error, fixes: fixes,
    )
  end

  # No observed types at all — Auto slot the inference pass could not
  # constrain (e.g., a parameter on a fn that's never called, or an
  # empty `[]` never used). Emits :error directing the user to
  # specify a concrete type. M2.1: when the body uses the binding in
  # operator expressions, ranked candidate types per the
  # AUTO_OP_CANDIDATES table are offered as :interactive Fixes.
  def emit_auto_unresolved_finding!(slot, op_evidence: {})
    label = auto_slot_label(slot)
    base_msg = "Cannot infer type for #{label} — no observed uses to drive inference."

    # M2.1: operator-derived candidates ranked per AUTO_OP_CANDIDATES.
    ops = op_evidence[slot_id_for(slot)] || Set.new
    candidates = auto_rank_candidates(ops)

    message = base_msg.dup
    if candidates.empty?
      message << " Replace `Auto` with a concrete type, or remove the unused declaration."
    else
      message << build_auto_op_evidence_block(ops, candidates)
    end

    fixes = candidates.each_with_index
                      .filter_map { |(type_sym, note), i|
                        build_auto_candidate_fix(slot, type_sym, note, i + 1)
                      }

    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || slot.decl_node,
      message: message, category: :type, level: :error, fixes: fixes,
    )
  end

  # Reverse-lookup helper: given a Slot struct, return its hash key
  # in the slots map (matches the IDs AutoConstraintCollector uses).
  def slot_id_for(slot)
    case slot.kind
    when :param  then [:param, slot.fn_name, slot.index]
    when :return then [:return, slot.fn_name]
    when :local  then [:local, slot.decl_node.object_id]
    end
  end

  # ---------------------------------------------------------------
  # Auto helpers (private to this module).
  # ---------------------------------------------------------------

  def auto_type_source_form(type)
    # Prefer the resolved symbol's name; falls back to to_s for
    # parameterized types (`Int64[]`, `HashMap<String, Int64>`).
    if type.respond_to?(:resolved)
      sym = type.resolved
      sym.to_s
    else
      type.to_s
    end
  end

  def auto_slot_label(slot)
    # M2.2: shape-tagged slots (forward-flow inference for empty
    # `[]` / `{}`) get a more specific label so the diagnostic
    # tells the user which sub-type is being inferred.
    if slot.respond_to?(:shape) && slot.shape
      name = slot.decl_node.respond_to?(:name) ? slot.decl_node.name : "<local>"
      case slot.shape
      when :list_element then return "element type of list `#{name}`"
      when :map_key      then return "key type of map `#{name}`"
      when :map_value    then return "value type of map `#{name}`"
      end
    end

    case slot.kind
    when :param
      param = slot.decl_node.params[slot.index]
      "parameter '#{param[:name]}' of `#{slot.fn_name}`"
    when :return
      "return type of `#{slot.fn_name}`"
    when :local
      name = slot.decl_node.respond_to?(:name) ? slot.decl_node.name : "<local>"
      "local '#{name}'"
    else
      # AutoConstraintCollector only creates :param / :return /
      # :local slots. A different kind reaching this path means a
      # caller fabricated a Slot with an unrecognized kind — fail
      # loudly so the bug isn't masked by a "slot" placeholder
      # appearing in user-facing diagnostics.
      raise ArgumentError, "auto_slot_label: unrecognized slot kind #{slot.kind.inspect}"
    end
  end

  def auto_token_for(slot)
    # The cached `slot.auto_token` (captured at registration) is
    # the authoritative source of the original Auto keyword span.
    # `stamp_slot!` / `stamp_map_pairs!` may overwrite
    # `decl_node.type` with the wrapped concrete type, which
    # would lose the auto_token if read live; the cache is
    # resilient to that. Slots are always constructed via
    # `AutoConstraintCollector`, which sets auto_token at every
    # registration site.
    slot.auto_token
  end

  def build_auto_ambiguity_message(label, observed_strs, slot)
    types_list = observed_strs.join(', ')
    msg = +"Ambiguous Auto for #{label}: observed as #{types_list}.\n"

    # Option 1: pin one type; convert at divergent callsites.
    msg << "  Option 1 (recommended): pin one concrete type at the\n"
    msg << "    declaration and convert at the divergent sites. The\n"
    msg << "    candidate types observed are: #{types_list}.\n"
    msg << "    Pick the one whose semantics match your intent and\n"
    msg << "    convert the others (e.g. `Int64.toString(x)`,\n"
    msg << "    `Int.fromString(s) OR RAISE`).\n"

    # Option 2: types not obviously compatible.
    msg << "  Option 2: if these types do not have an obvious\n"
    msg << "    conversion path, restructure the call sites so a\n"
    msg << "    single concrete type flows through.\n"

    # Option 3: union — example only, never auto-applied.
    if slot.kind == :param || slot.kind == :return
      union_name = slot.kind == :param ? slot.decl_node.params[slot.index][:name].to_s.capitalize : "Result"
      variants = observed_strs.map.with_index { |t, i| "Variant#{i}: #{t}" }.join(', ')
      msg << "  Option 3 (last resort): if you genuinely need to accept\n"
      msg << "    multiple types, define a union explicitly:\n"
      msg << "      UNION #{union_name} { #{variants} }\n"
      msg << "    Auto does NOT auto-create unions.\n"
    end

    msg
  end
end
