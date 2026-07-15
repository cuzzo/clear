# typed: strict
require "sorbet-runtime"
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

require_relative "../../ast/ast"
require_relative "../../ast/diagnostic_registry"
require_relative "../../ast/fixable_error"
require_relative "../../ast/type"

# ruby-to-clear: emit-module-methods
module FixableHelper
    extend T::Sig

  DiagnosticKwValue = T.type_alias { DiagnosticRegistry::DiagnosticKwValue }
  NameCandidate = T.type_alias { T.any(String, Symbol) }
  AutoOperatorCandidateConfig = T.type_alias {
    T::Hash[Symbol, BasicObject]
  }

  sig { params(code: Symbol, kwargs: DiagnosticRegistry::DiagnosticKwValue).returns(String) }
  def fix_description(code, **kwargs)
    DiagnosticRegistry.fix_description_from_hash(code, kwargs)
  end

  # `value.field` where value is ?T is always safely repairable as
  # `value?.field`. GetField's token anchors the field name, so the dot is the
  # immediately preceding source column and inserting `?` there produces `?.`.
  sig { params(node: AST::GetField, target_type: Type).void }
  def emit_optional_field_safe_nav_finding!(node, target_type)
    T.bind(self, SemanticAnnotator) rescue nil
    token = node.token
    return error!(node, :OPTIONAL_FIELD_REQUIRES_SAFE_NAV,
                  field: node.field, type: Type.surface_name(target_type),
                  target: node.target.name) unless token

    fix = Fix.new(
      description: fix_description(:INSERT_SAFE_NAVIGATION),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: token.line, col: token.column - 1, length: 0),
        replacement: "?"
      )]
    )
    fixable!(node,
      code: :OPTIONAL_FIELD_REQUIRES_SAFE_NAV,
      field: node.field,
      type: Type.surface_name(target_type),
      target: node.target.name,
      category: :type,
      level: :error,
      fixes: [fix])
  end

  class CapabilityFixCandidate < T::Struct
    const :sigil, String
    const :description_code, Symbol
    const :description_params, T::Hash[Symbol, DiagnosticKwValue], default: {}
  end

  class AutoCandidate < T::Struct
    const :type_sym, Symbol
    const :note, T.nilable(String), default: nil
  end

  # Lint: `MUTABLE 'x' is never reassigned`. :auto fix removes the
  # `MUTABLE ` prefix (8 chars) at the VarDecl's column.
  sig { params(reg: T.nilable(T.any(AST::VarDecl, AST::DestructureTarget)), name: String).void }
  def emit_mutable_unused_finding!(reg, name)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless reg
    tok = if reg.is_a?(AST::VarDecl)
      T.unsafe(reg).token
    else
      T.unsafe(reg).token
    end
    fixes = []
    if tok.value == 'MUTABLE'
      fixes << Fix.new(
        description: fix_description(:REMOVE_MUTABLE_UNUSED),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: tok.line, col: tok.column, length: 'MUTABLE '.length),
          replacement: ''
        )]
      )
    end

    fixable!(reg,
      code: :MUTABLE_UNUSED,
      name: name,
      category: :lint,
      level: :warning,
      fixes: fixes)
  end

  # Return the name with the smallest Levenshtein distance from `input`
  # over `candidates`, provided it's within `max_distance`. Returns nil
  # when no candidate is close enough (don't suggest wild guesses).
  sig { params(input: NameCandidate, candidates: T::Enumerable[NameCandidate], max_distance: Integer).returns(T.nilable(String)) }
  def closest_name(input, candidates, max_distance: 3)
    T.bind(self, SemanticAnnotator) rescue nil
    best = T.let(nil, T.nilable(NameCandidate))
    best_d = T.let(max_distance + 1, Integer)
    candidates.each do |cand|
      d = levenshtein(input.to_s, cand.to_s)
      if d < best_d
        best = cand
        best_d = d
      end
    end
    best_d <= max_distance ? best.to_s : nil
  end

  sig { params(a: String, b: String).returns(Integer) }
  def levenshtein(a, b)
    T.bind(self, SemanticAnnotator) rescue nil
    return b.length if a.empty?
    return a.length if b.empty?
    prev = (0..b.length).to_a
    a.each_char.with_index do |ac, i|
      curr = [i + 1]
      b.each_char.with_index do |bc, j|
        cost = ac == bc ? 0 : 1
        curr << [T.must(curr[j]) + 1, T.must(prev[j + 1]) + 1, T.must(prev[j]) + cost].min
      end
      prev = curr
    end
    T.must(prev.last)
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
  sig { params(token: Lexer::Token, name: NameCandidate, candidates: T::Array[NameCandidate], message: String, fix_label: String).returns(NilClass) }
  def emit_registry_mismatch!(token, name, candidates, message, fix_label)
    T.bind(self, SemanticAnnotator) rescue nil
    best = if fix_label == "closest in-scope variable" && name.to_s.match?(/\A[A-Z]/)
      nil
    else
      closest_name(name, candidates)
    end
    fixes = []
    if best
      fixes << Fix.new(
        description: fix_description(:REPLACE_IDENTIFIER_WITH_CANDIDATE, name: name, best: best, label: fix_label),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: token.line, col: token.column, length: name.to_s.length),
          replacement: best.to_s
        )]
      )
    end

    return error!(token, :REGISTRY_MISMATCH_REJECTED, detail: message) if fixes.empty?

    fixable!(token, code: :REGISTRY_MISMATCH_REJECTED, detail: message,
             category: :registry, level: :error, fixes: fixes)
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
  sig { params(token: T.nilable(TypoToken), name: String, candidates: T::Array[String], message: String, fix_label: String, category: Symbol, cascade: T::Boolean).returns(NilClass) }
  def emit_typo_suggestion!(token, name, candidates, message, fix_label,
                            category: :registry, cascade: true)
    T.bind(self, SemanticAnnotator) rescue nil
    token_line = T.cast(T.unsafe(token).line, Integer)
    token_column = T.cast(T.unsafe(token).column, Integer)
    best = if fix_label == "closest in-scope variable" && name.to_s.match?(/\A[A-Z]/)
      nil
    else
      closest_name(name, candidates)
    end
    fixes = []
    if best
      fixes << Fix.new(
        description: fix_description(:REPLACE_IDENTIFIER_WITH_CANDIDATE, name: name, best: best, label: fix_label),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: token_line, col: token_column, length: name.to_s.length),
          replacement: best.to_s
        )]
      )
    end

    return error!(token, :TYPO_SUGGESTION_REJECTED, detail: message) if fixes.empty?

    fixable!(token, code: :TYPO_SUGGESTION_REJECTED, detail: message,
             category: category, level: :error,
             fixes: fixes, raise_in_collector: cascade)
  end

  # Synthesize a token-like anchor at an explicit (line, col). Used by
  sig { params(line: Integer, col: Integer).returns(AnchorToken) }
  def anchor_at(line, col)
    T.bind(self, SemanticAnnotator) rescue nil
    AnchorToken.new(line, col)
  end

  # Given a Type.Variant style GetField, compute the token line/col of
  # the variant name (right after `target.` — length of target + 1).
  sig { params(getfield_node: AST::GetField).returns(T.nilable(AnchorToken)) }
  def variant_anchor_from_getfield(getfield_node)
    T.bind(self, SemanticAnnotator) rescue nil
    tgt = getfield_node.target
    return nil unless tgt.token
    anchor_at(tgt.token.line, tgt.token.column + tgt.name.to_s.length + 1)
  end

  # For a UnionVariantLit `Union.Variant{...}`, the node's token is the
  # opening `{` — the variant name ends right before it, so the name's
  # start column is `token.column - variant_name.length`.
  sig { params(node: T.any(AST::StructLit, AST::UnionVariantLit), variant_name: String).returns(T.nilable(AnchorToken)) }
  def variant_anchor_from_unionlit(node, variant_name)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil unless node.token
    anchor_at(node.token.line, node.token.column - variant_name.to_s.length)
  end

  # Typo-suggestion wrapper that takes an (line, col, name, length)
  # instead of a Token. Used by migrations whose error token comes
  # from a synthesized anchor.
  sig { params(anchor: AnchorToken, name: String, candidates: T::Enumerable[NameCandidate], message: String, fix_label: String, cascade: T::Boolean).returns(NilClass) }
  def emit_variant_typo!(anchor, name, candidates, message, fix_label,
                         cascade: false)
    T.bind(self, SemanticAnnotator) rescue nil
    best = closest_name(name, candidates)
    fixes = []
    if best
      fixes << Fix.new(
        description: fix_description(:REPLACE_IDENTIFIER_WITH_CANDIDATE, name: name, best: best, label: fix_label),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: anchor.line, col: anchor.column, length: name.to_s.length),
          replacement: best.to_s
        )]
      )
    end

    return error!(anchor, :TYPO_SUGGESTION_REJECTED, detail: message) if fixes.empty?

    fixable!(anchor, code: :TYPO_SUGGESTION_REJECTED, detail: message,
             category: :type, level: :error,
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
  sig { params(use_node: AST::Identifier, og_node: OwnershipGraph::Node).returns(NilClass) }
  def emit_use_of_moved_error!(use_node, og_node)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    name = use_node.name.to_s
    move_line = og_node.move_line
    move_col = og_node.move_col
    unless move_line && move_col
      msg = "USE AFTER MOVE: You can't use `#{name}`."
      return error!(use_node, :USE_OF_MOVED_VALUE, detail: msg)
    end

    # Pick COPY vs CLONE for the consumer-site fix. CLEAR uses CLONE
    # for shared / refcounted handles (`@shared`, `@multiowned`,
    # `@split` streams) and COPY for plain affine values. Picking the
    # wrong keyword would either compile-error (CLONE on plain T) or
    # do something semantically different from what the user wants
    # (deep-COPY on an Arc handle when a refcount bump suffices).
    type = og_node.full_type
    is_shared = type.respond_to?(:shared?)     ? type.shared?     : false
    is_multi  = type.respond_to?(:multiowned?) ? type.multiowned? : false
    is_split  = type.respond_to?(:split?)      ? type.split?      : false
    use_clone = is_shared || is_multi || is_split

    consumer_keyword = use_clone ? "CLONE" : "COPY"
    consumer_description_code = use_clone ? :WRAP_CONSUMER_WITH_CLONE : :WRAP_CONSUMER_WITH_COPY

    replacement_col = move_col
    replacement_length = name.length
    source_code = @source_code
    if source_code
      move_text = source_code.lines[move_line - 1].to_s
      prefix = move_text[0, move_col - 1].to_s
      if (give_prefix = prefix.match(/GIVE\s+\z/))
        replacement_col = give_prefix.begin(0) + 1
        replacement_length += T.must(give_prefix[0]).length
      end
    end

    fixes = []
    fixes << Fix.new(
      description: fix_description(consumer_description_code, line: og_node.move_line),
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: move_line, col: replacement_col, length: replacement_length),
        replacement: "(#{consumer_keyword} #{name})"
      )]
    )

    # Declaration-level capability-upgrade fixes — append after the
    # value expression (before the statement-terminating `;`). Skip a
    # capability the binding already carries (would be a no-op /
    # syntactic error). `@split` is a separate sharing axis — neither
    # `@multiowned` nor `@shared` is a meaningful upgrade for it.
    candidate_caps = []
    candidate_caps << '@multiowned' unless is_multi || is_split
    candidate_caps << '@shared'     unless is_shared || is_split

    # Phase 2: when the move was a function call (TAKES or explicit
    # GIVE) into a parameter of plain affine T (no `@shared` /
    # `@multiowned`), upgrading the binding to a refcounted handle
    # WON'T fix the call — the function still demands a plain owned
    # value and the use-after-move re-fires after the upgrade. Skip
    # both upgrade fixes in that case so the dropdown doesn't dangle
    # red herrings.
    consumed_by_call = og_node.move_action == :takes || og_node.move_action == :give
    if og_node.respond_to?(:move_consumer_param_type) && consumed_by_call
      pt = og_node.move_consumer_param_type
      pt = Type.new(pt) if pt && !pt.is_a?(Type)
      param_admits_shared = pt && (pt.respond_to?(:shared?) ? pt.shared? : false)
      param_admits_multi  = pt && (pt.respond_to?(:multiowned?) ? pt.multiowned? : false)
      if pt && !param_admits_shared && !param_admits_multi
        candidate_caps.delete('@shared')
        candidate_caps.delete('@multiowned')
      end
    end

    scope = lookup_scope_for(name)
    decl = scope&.resolve_entry(name)&.reg
    src = @source_code
    if decl && decl.token && src
      dline = decl.token.line
      line_text = src.lines[dline - 1] || ''
      # Find the `;` that terminates the declaration (skip trailing
      # whitespace). Only suggest capability upgrades when the `;` is
      # on the same physical line as the declaration — multi-line
      # value expressions would need a broader span calc. Search from
      # the decl-name column so a prior statement's `;` on the same
      # line is skipped.
      semi_idx = line_text.index(';', decl.token.column - 1)
      if semi_idx
        insert_col = semi_idx + 1  # 1-based column at the `;`
        candidate_caps.each do |cap|
          reason = 'atomic Arc; safe across fibers'
          if cap == '@multiowned'
            reason = 'single-scheduler Rc; automatic clone on move'
          end
          fixes << Fix.new(
            description: fix_description(:CHANGE_BINDING_CAPABILITY_FOR_MOVE, name: name, cap: cap, reason: reason),
            confidence: :interactive,
            edits: [Edit.new(
              span: Span.new(file: nil, line: dline, col: insert_col, length: 0),
              replacement: " #{cap}"
            )]
          )
        end
      end
    end

    consumer = consumer_source_text(move_line)
    phrase   = ownership_active_phrase(og_node.move_action || :move)
    msg = if consumer
      "USE AFTER MOVE: You can't use `#{name}`. `#{consumer}` #{phrase} (line #{move_line})."
    else
      "USE AFTER MOVE: You can't use `#{name}` — it #{phrase} (line #{move_line})."
    end

    fixable!(use_node,
      code: :USE_OF_MOVED_VALUE,
      detail: msg,
      category: :ownership,
      level: :error,
      fixes: fixes,
      raise_in_collector: true)
  end

  # Loop-body use of a value that was moved on a prior iteration. The
  # coda "Values can only be TAKEN once; subsequent iterations have
  # nothing left to GIVE" is the canonical phrasing per WALKTHROUGH.md.
  sig { params(node: T.any(AST::WhileBindLoop, AST::WhileLoop), name: String, og_node: T.nilable(OwnershipGraph::Node), code: Symbol).returns(NilClass) }
  def emit_use_of_moved_in_loop_error!(node, name, og_node = nil, code: :USE_OF_MOVED_IN_LOOP)
    T.bind(self, SemanticAnnotator) rescue nil
    loop_move_line = og_node&.move_line
    consumer = loop_move_line ? consumer_source_text(loop_move_line) : nil
    consumer_clause = consumer ? "`#{consumer}` already TOOK it. " : ""
    msg = "USE AFTER MOVE: You can't use `#{name}` here — #{consumer_clause}" \
          "Values can only be TAKEN once; subsequent iterations have nothing left to GIVE."
    error!(node, code, detail: msg)
  end

  # Sub-path use after the path's owner was consumed elsewhere. Uses
  # passive voice ("was already TAKEN / GIVEN") because the subject of
  # the sentence is the owner — what HAPPENED to it — not the consumer.
  sig { params(node: AST::GetField, path: T::Array[NameCandidate], og_node: T.nilable(OwnershipGraph::Node)).returns(NilClass) }
  def emit_use_of_moved_path_error!(node, path, og_node = nil)
    T.bind(self, SemanticAnnotator) rescue nil
    path_str = path.map(&:to_s).join('.')
    root     = path.first.to_s
    msg = if og_node && og_node.move_line
      phrase = ownership_passive_phrase(og_node.move_action || :move)
      "USE AFTER MOVE: You can't use `#{path_str}`. Its owner `#{root}` #{phrase} on line #{og_node.move_line}."
    else
      "USE AFTER MOVE: You can't use `#{path_str}`. Its owner `#{root}` was already consumed elsewhere."
    end
    error!(node, :USE_OF_MOVED_PATH, detail: msg)
  end

  # Active form: subject is the consumer (e.g. "`process(GIVE msg)`
  # already GAVE it away"). Used when we can quote the consumer site.
  OWNERSHIP_ACTIVE_PHRASES = T.let({
    give:    "already GAVE it away",
    takes:   "already TOOK it away",
    return:  "already RETURNED it",
    next:    "already consumed it via NEXT",
    share:   "already SHARED it",
    collect: "already COLLECTED it",
    capture: "already captured it",
    move:    "already MOVED it",
  }.freeze, T::Hash[Symbol, String])

  # Passive form: subject is the value (e.g. "its owner `b` was
  # already TAKEN away"). Used by USE_OF_MOVED_PATH where we name the
  # path's owner rather than the consumer.
  OWNERSHIP_PASSIVE_PHRASES = T.let({
    give:    "was already GIVEN away",
    takes:   "was already TAKEN away",
    return:  "was already RETURNED",
    next:    "was already consumed via NEXT",
    share:   "was already SHARED",
    collect: "was already COLLECTED",
    capture: "was already captured",
    move:    "was already MOVED",
  }.freeze, T::Hash[Symbol, String])

  sig { params(action: Symbol).returns(String) }
  def ownership_active_phrase(action)
    T.bind(self, SemanticAnnotator) rescue nil
    OWNERSHIP_ACTIVE_PHRASES[action] || "already consumed it"
  end

  sig { params(action: Symbol).returns(String) }
  def ownership_passive_phrase(action)
    T.bind(self, SemanticAnnotator) rescue nil
    OWNERSHIP_PASSIVE_PHRASES[action] || "was already consumed"
  end

  # Best-effort: extract the source-line text at the move site so the
  # error can quote the consumer call (e.g. "process(GIVE msg)"). Falls
  # back to nil when @source_code isn't set (programmatic use of the
  # annotator) or the line is past EOF.
  sig { params(line_num: Integer).returns(T.nilable(String)) }
  def consumer_source_text(line_num)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    return nil unless @source_code && line_num
    line = @source_code.lines[line_num - 1]
    return nil unless line
    text = line.strip
    text = text.chomp(';').strip
    text.empty? ? nil : text
  end

  # Type: `Integer literal N overflows T (range ...)`. When the
  # literal is written in suffixed form (`1000_u8`) and there's a
  # wider known type that fits the value, emit an :auto fix that
  # replaces just the suffix. Annotation-form overflows (`x: Byte =
  # 1000`) fall through to the legacy error path — locating the
  # annotation token from the literal's context is non-trivial and
  # deferred.
  INT_SUFFIXES = T.let({
    Int8: 'i8', Byte: 'u8',
    Int16: 'i16', UInt16: 'u16',
    Int32: 'i32', UInt32: 'u32',
    Int64: 'i64', UInt64: 'u64',
  }.freeze, T::Hash[Symbol, String])

  # Order smallest-first so `find` picks the tightest fit.
  SIGNED_ORDER    = [:Int8,  :Int16,  :Int32,  :Int64 ].freeze
  UNSIGNED_ORDER  = [:Byte,  :UInt16, :UInt32, :UInt64].freeze

  sig { params(val: Integer).returns(T.nilable(Symbol)) }
  def smallest_fitting_int_type(val)
    T.bind(self, SemanticAnnotator) rescue nil
    order = val >= 0 ? UNSIGNED_ORDER : SIGNED_ORDER
    selected = T.let(nil, T.nilable(Symbol))
    order.each do |t|
      next if selected

      max = Type::INT_TYPE_MAX[t]
      next if max.nil?

      min = Type::INT_TYPE_MIN[t] || 0
      selected = t if val >= min && val <= max
    end
    selected
  end

  sig { params(prefix: String, target_name: String).returns(T.nilable(Integer)) }
  def annotation_type_column(prefix, target_name)
    T.bind(self, SemanticAnnotator) rescue nil
    idx = 0
    found = T.let(nil, T.nilable(Integer))
    while idx < prefix.length
      colon = prefix.index(':', idx)
      if colon
        type_start = colon + 1
        while type_start < prefix.length && whitespace_char?(prefix[type_start])
          type_start += 1
        end
        type_end = type_start + target_name.length
        if prefix[type_start, target_name.length] == target_name && !identifier_char_at?(prefix, type_end)
          found = type_start + 1
        end
        idx = colon + 1
      else
        idx = prefix.length
      end
    end
    found
  end

  sig { params(ch: T.nilable(String)).returns(T::Boolean) }
  def whitespace_char?(ch)
    ch == ' ' || ch == "\t"
  end

  sig { params(text: String, idx: Integer).returns(T::Boolean) }
  def identifier_char_at?(text, idx)
    return false if idx >= text.length
    ch = text[idx]
    return false unless ch

    (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_'
  end

  sig { params(node: AST::Literal, val: Integer, target_type: Symbol, min: Integer, max: Integer).returns(NilClass) }
  def emit_int_overflow_error!(node, val, target_type, min, max)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    tok = node.token
    return error!(node, :INT_LITERAL_OVERFLOW, val: val, type: target_type, min: min, max: max) unless tok && @source_code

    best = smallest_fitting_int_type(val)
    return error!(node, :INT_LITERAL_OVERFLOW, val: val, type: target_type, min: min, max: max) unless best

    line_text = @source_code.lines[tok.line - 1] || ''

    # Prefer the suffix form first (precise span; local replacement).
    snippet = line_text[(tok.column - 1)..] || ''
    if (m = snippet.match(/\A(\d[\d_]*)_([a-z]\d+)/))
      old_suffix = m[2]
      new_suffix = INT_SUFFIXES[best]
      if new_suffix && new_suffix != old_suffix
        suffix_col = tok.column + T.must(m[1]).length + 1
        return emit_overflow_suffix_fix!(node, target_type, min, max, tok, suffix_col, T.must(old_suffix), new_suffix, val)
      end
    end

    # Annotation form: scan the line for `: <target_type>` and replace
    # the type token (e.g., `x: Byte = 1000` -> `x: UInt16 = 1000`).
    # Restrict the search to the slice BEFORE the literal and pick the
    # LAST match so a prior decl with the same annotated type on the
    # same line doesn't capture the fix.
    target_name = target_type.to_s
    prefix = line_text[0...(tok.column - 1)] || ''
    ann_col = annotation_type_column(prefix, target_name)
    if ann_col
      new_type = best.to_s
      if new_type != target_name
        fix = Fix.new(
          description: fix_description(:WIDEN_INT_ANNOTATION, old_type: target_name, new_type: new_type, value: val),
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: tok.line, col: ann_col, length: target_name.length),
            replacement: new_type
          )]
        )
        return fixable!(node,
          code: :INT_LITERAL_OVERFLOW,
          val: val,
          type: target_type,
          min: min,
          max: max,
          category: :type,
          level: :error,
          fixes: [fix],
          raise_in_collector: true)
      end
    end

    error!(node, :INT_LITERAL_OVERFLOW, val: val, type: target_type, min: min, max: max)
  end

  sig { params(node: AST::Node, target_type: Symbol, min: Integer, max: Integer, tok: Lexer::Token, suffix_col: Integer, old_suffix: String, new_suffix: String, val: Integer).returns(NilClass) }
  def emit_overflow_suffix_fix!(node, target_type, min, max, tok, suffix_col, old_suffix, new_suffix, val)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = Fix.new(
      description: fix_description(:WIDEN_INT_SUFFIX, old_suffix: old_suffix, new_suffix: new_suffix, value: val),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: tok.line, col: suffix_col, length: old_suffix.length),
        replacement: new_suffix
      )]
    )
    fixable!(node,
      code: :INT_LITERAL_OVERFLOW,
      val: val,
      type: target_type,
      min: min,
      max: max,
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
  sig { params(info: CapabilityAudit::BindingAuditRecord).returns(NilClass) }
  def emit_local_never_shared_finding!(info)
    T.bind(self, SemanticAnnotator) rescue nil
    name = info.var
    line = info.line
    fixes = []

    if @source_code && line
      src_line = @source_code.lines[line - 1] || ''
      # Search from the decl-name column so a prior @local on the same
      # line (a different binding) isn't picked.
      idx = src_line.index('@local', (info.column || 1) - 1)
      if idx
        trail = (src_line[idx + 6] == ' ') ? 1 : 0
        lead  = (idx > 0 && src_line[idx - 1] == ' ') ? 1 : 0
        start_col = idx + 1 - lead
        length    = 6 + lead + trail
        fixes << Fix.new(
          description: fix_description(:REMOVE_LOCAL_CAPABILITY, name: name),
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: line, col: start_col, length: length),
            replacement: ''
          )]
        )
      end
    end

    anchor = line ? anchor_at(line, info.column || 1) : nil
    fixable!(anchor,
      code: :LOCAL_NEVER_SHARED,
      name: name,
      category: :lint,
      level: :info,
      fixes: fixes)
  end

  # Ownership: `Variable 'x' is immutable` on reassignment. :auto fix
  # locates the original declaration and inserts `MUTABLE ` at its
  # column.
  sig { params(node: AST::BindExpr, scope: Scope).returns(NilClass) }
  def emit_immutable_assignment_error!(node, scope)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = build_declare_mutable_fix(node.name, scope)
    return error!(node, :IMMUTABLE_ASSIGNMENT, name: node.name) unless fix
    fixable!(node,
      code: :IMMUTABLE_ASSIGNMENT,
      name: node.name,
      category: :ownership,
      level: :error,
      fixes: [fix])
  end

  # Ownership: `Argument i ('param') is MUTABLE, but you passed
  # immutable variable 'x'`. Same fix shape as the assignment case —
  # declare the passed variable MUTABLE at its binding site.
  sig { params(arg_node: AST::Identifier, scope: Scope, arg_idx: Integer, param_name: String).returns(NilClass) }
  def emit_immutable_arg_error!(arg_node, scope, arg_idx, param_name)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = build_declare_mutable_fix(arg_node.name, scope)
    kw = { index: arg_idx, param: param_name, actual: arg_node.name }
    return error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_MUTABLE, **kw) unless fix
    fixable!(arg_node,
      code: :IMMUTABLE_ARG_PASSED_AS_MUTABLE,
      **kw,
      category: :ownership,
      level: :error,
      fixes: [fix],
      raise_in_collector: true)
  end

  # `x[i] = ...` or `m["k"] = ...` where x/m is an immutable binding.
  # Same fix shape: insert MUTABLE at the binding's declaration. The
  # error code is named `_LIST` for historical reasons but the same
  # site fires for HashMap and any other indexable container.
  sig { params(assignment_node: AST::Assignment, scope: Scope, var_name: String).returns(NilClass) }
  def emit_immutable_index_assignment_error!(assignment_node, scope, var_name)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = build_declare_mutable_fix(var_name, scope)
    return error!(assignment_node, :ASSIGN_INDEX_IMMUTABLE_LIST, name: var_name) unless fix
    fixable!(assignment_node,
      code: :ASSIGN_INDEX_IMMUTABLE_LIST,
      name: var_name,
      category: :ownership,
      level: :error,
      fixes: [fix])
  end

  # `x.field = ...` where x is an immutable binding. Mirrors the index
  # variant; the fix is the same MUTABLE insertion. `field_name` is
  # the specific field being assigned (`b.x = ...` -> "x"), used to
  # produce a more pointed error message via IMMUTABLE_FIELD_ASSIGNMENT.
  sig { params(assignment_node: AST::Assignment, scope: Scope, var_name: String, field_name: String).returns(NilClass) }
  def emit_immutable_field_assignment_error!(assignment_node, scope, var_name, field_name)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = build_declare_mutable_fix(var_name, scope)
    kw = { name: var_name, field: field_name }
    return error!(assignment_node, :IMMUTABLE_FIELD_ASSIGNMENT, **kw) unless fix
    fixable!(assignment_node,
      code: :IMMUTABLE_FIELD_ASSIGNMENT,
      **kw,
      category: :ownership,
      level: :error,
      fixes: [fix])
  end

  # Reentrance: a function is recursive (directly or transitively) but
  # carries no EFFECTS REENTRANT declaration. :auto fix inserts
  # `EFFECTS REENTRANT ` immediately before the function's `->`. The
  # arrow_token's column is where the insertion lands; the fix is a
  # zero-length insert.
  #
  # `code` selects the error code that fires when the fix isn't
  # locatable (REENTRANCE_DIRECT_RECURSIVE for explicit reentrance guards,
  # REENTRANCE_INDIRECT_RECURSIVE for the no-marker case).
  sig { params(fn_node: AST::FunctionDef, code: Symbol).returns(NilClass) }
  def emit_reentrant_error!(fn_node, code)
    T.bind(self, SemanticAnnotator) rescue nil
    arrow = fn_node.arrow_token
    fix = nil
    if arrow
      fix = Fix.new(
        description: fix_description(:ADD_EFFECTS_REENTRANT),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: arrow.line, col: arrow.column, length: 0),
          replacement: 'EFFECTS REENTRANT '
        )]
      )
    end
    return error!(fn_node, code, name: fn_node.name) unless fix
    fixable!(fn_node,
      code: code,
      name: fn_node.name,
      category: :reentrance,
      level: :error,
      fixes: [fix])
  end

  # Capture: USE(MUTABLE x) where x is an immutable binding. :auto
  # fix inserts MUTABLE at the captured binding's declaration. Same
  # shape as emit_immutable_assignment_error! / emit_immutable_arg_error!.
  sig { params(node: AST::FunctionDef, cap_name: String, owner_scope: Scope).returns(NilClass) }
  def emit_capture_immutable_as_mutable_error!(node, cap_name, owner_scope)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = build_declare_mutable_fix(cap_name, owner_scope)
    return error!(node, :CAPTURE_IMMUTABLE_AS_MUTABLE, name: cap_name) unless fix
    fixable!(node,
      code: :CAPTURE_IMMUTABLE_AS_MUTABLE,
      name: cap_name,
      category: :ownership,
      level: :error,
      fixes: [fix])
  end

  # Type: function with multiple-typed RETURN branches and no explicit
  # `RETURNS` annotation. :auto fix inserts `RETURNS :Any ` immediately
  # before the function's `->` arrow so the compiler knows to accept
  # the polymorphic return.
  sig { params(fn_node: AST::FunctionDef, found_returns: T::Array[AST::ReturnFact]).void }
  def emit_ambiguous_return_error!(fn_node, found_returns)
    T.bind(self, SemanticAnnotator) rescue nil
    return_types = found_returns.map(&:type)
    arrow = fn_node.arrow_token
    fix = nil
    if arrow
      fix = Fix.new(
        description: fix_description(:INSERT_RETURNS_ANY),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: arrow.line, col: arrow.column, length: 0),
          replacement: 'RETURNS :Any '
        )]
      )
    end
    return error!(fn_node, :AMBIGUOUS_RETURN, types: return_types) unless fix
    fixable!(fn_node,
      code: :AMBIGUOUS_RETURN,
      types: return_types,
      category: :type,
      level: :error,
      fixes: [fix])
  end

  # MATCH on a non-discriminated subject (or non-exhaustive cases) —
  # both fixed by inserting `PARTIAL ` before the MATCH keyword. :auto
  # confidence because PARTIAL MATCH is strictly a superset (allows
  # DEFAULT, allows guards, doesn't require exhaustiveness).
  sig { params(match_node: AST::MatchStatement, code: Symbol, kwargs: DiagnosticKwValue).returns(NilClass) }
  def emit_match_partial_fix!(match_node, code, **kwargs)
    T.bind(self, SemanticAnnotator) rescue nil
    tok = match_node.token
    fix = nil
    if tok
      fix = Fix.new(
        description: fix_description(:REPLACE_MATCH_WITH_PARTIAL),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: tok.line, col: tok.column, length: 0),
          replacement: 'PARTIAL '
        )]
      )
    end
    return error!(match_node, code, **kwargs) unless fix
    case code
    when :MATCH_NEEDS_ENUM_OR_UNION
      fixable!(match_node,
        code: code,
        type: kwargs[:type],
        category: :type,
        level: :error,
        fixes: [fix])
    when :MATCH_NON_EXHAUSTIVE
      fixable!(match_node,
        code: code,
        kind: kwargs[:kind],
        name: kwargs[:name],
        missing: kwargs[:missing],
        category: :type,
        level: :error,
        fixes: [fix])
    else
      Kernel.raise ArgumentError, "unsupported MATCH partial fix diagnostic: #{code.inspect}"
    end
  end

  # Lifetime: returning a borrowed value without COPY or a `RETURNS x:T`
  # annotation. :auto fix wraps the return value with `COPY ` — safe for
  # values the compiler considers copy-eligible at runtime; user can
  # decline and add a lifetime annotation instead.
  sig { params(node: AST::Node).returns(NilClass) }
  def emit_return_borrowed_no_copy_error!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = nil
    if node.token
      tok = node.token
      fix = Fix.new(
        description: fix_description(:WRAP_RETURN_WITH_COPY),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: tok.line, col: tok.column, length: 0),
          replacement: 'COPY '
        )]
      )
    end
    kw = { type: node.full_type!(context: "borrowed return diagnostic") }
    return error!(node, :RETURN_BORROWED_NO_COPY_OR_LIFETIME, **kw) unless fix
    fixable!(node,
      code: :RETURN_BORROWED_NO_COPY_OR_LIFETIME,
      **kw,
      category: :lifetime,
      level: :error,
      fixes: [fix])
  end

  # Capability: direct field access (`c.value`) on a `@locked` /
  # `@writeLocked` / `@boxed:atomic` binding. :interactive fix
  # wraps the offending source line with `WITH <perm> name AS alias`,
  # rewriting `name.<field>` references on the line to `alias.<field>`.
  # Bare `name` references (e.g. passing it as a function arg) are
  # left alone — they still refer to the wrapper inside the WITH body.
  #
  # Limitations:
  # - Single-line statements only. Multi-line expressions land back at
  #   the plain `error!` path so the user does the wrap by hand.
  # - The alias name (`name + "_v"`) might collide with an existing
  #   binding; `:interactive` confidence so the user reviews.
  # - The enclosing function may need `RETURNS !T` (the WITH acquire
  #   can fail). The user's next compile catches that with its own
  #   fixable error.
  sig { params(node: AST::GetField, code: Symbol, name: NameCandidate, field: String, cap: String, perm: String).void }
  def emit_cap_field_needs_with!(node, code, name:, field:, cap:, perm:)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    kw = { name: name, field: field, cap: cap }
    fixes = []
    if @source_code && node.respond_to?(:token) && node.token
      line_num = node.token.line
      line_text = @source_code.lines[line_num - 1] || ''
      body = line_text.chomp
      indent = body[/\A\s*/] || ''
      inner = body.lstrip
      if !inner.empty? && !inner.include?("\n")
        alias_name = "#{name}_v"
        rewritten = inner.gsub(/\b#{Regexp.escape(name.to_s)}\.(?=\w)/, "#{alias_name}.")
        new_line = "#{indent}WITH #{perm} #{name} AS #{alias_name} { #{rewritten} }"
        fixes << Fix.new(
          description: fix_description(:WRAP_CAPABILITY_ACCESS,
            permission: perm,
            name: name,
            alias_name: alias_name,
            capability: cap),
          confidence: :interactive,
          edits: [Edit.new(
            span: Span.new(file: nil, line: line_num, col: 1, length: body.length),
            replacement: new_line
          )]
        )
      end
    end
    return error!(node, code, **kw) if fixes.empty?
    fixable!(node,
      code: code,
      **kw,
      category: :capability,
      level: :error,
      fixes: fixes,
      raise_in_collector: true)
  end

  # Capability: `WITH GUARD` clause where one or more participating
  # bindings have no AS alias. :auto fix that inserts ` AS <name>`
  # right after each missing-alias var node. The proposed alias is
  # the var's own name with `_v` appended (matches the convention used
  # by emit_cap_field_needs_with!). Falls back to plain `error!`
  # when no var token is locatable.
  sig { params(node: AST::WithBlock, missing_caps: T::Enumerable[CapabilityPlan::CapabilityTransition]).returns(NilClass) }
  def emit_with_guard_all_bindings_need_as!(node, missing_caps)
    T.bind(self, SemanticAnnotator) rescue nil
    edits = []
    missing_caps.each do |c|
      vn = c.var_node
      next unless vn.is_a?(AST::Identifier) && vn.respond_to?(:token) && vn.token
      tok = vn.token
      name = vn.name.to_s
      # Insert just past the end of the var name.
      edits << Edit.new(
        span: Span.new(file: nil, line: tok.line, col: tok.column + name.length, length: 0),
        replacement: " AS #{name}_v"
      )
    end
    return error!(node, :WITH_GUARD_ALL_BINDINGS_NEED_AS) if edits.empty?
    fix = Fix.new(
      description: fix_description(:ADD_WITH_GUARD_ALIASES),
      confidence: :auto,
      edits: edits
    )
    fixable!(node,
      code: :WITH_GUARD_ALL_BINDINGS_NEED_AS,
      category: :capability,
      level: :error,
      fixes: [fix],
      raise_in_collector: true)
  end

  # Capability: `WITH GUARD` body mutates a MUTABLE alias (silent
  # invalidation of the guard). :interactive fix offers to drop the
  # `MUTABLE` keyword from each named alias's WITH-block declaration.
  # The actual mutation site stays in place — the user reviews and
  # decides whether dropping MUTABLE is the right call (vs removing
  # the mutation, vs moving it outside the guarded WITH).
  sig { params(node: AST::WithBlock, names: T::Enumerable[String], verb: String).returns(NilClass) }
  def emit_with_guard_mutable_mutated!(node, names, verb)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    names = names.to_a
    src = @source_code
    edits = []
    if src && node.respond_to?(:token) && node.token
      # Search the WITH block's lines for `MUTABLE <name>` and drop
      # the keyword. The WITH header may span multiple lines, but
      # `MUTABLE` will appear immediately before the alias name.
      with_line = node.token.line
      window_lines = src.lines[(with_line - 1)..(with_line + 8)] || []
      names.each do |alias_name|
        pat = /\bMUTABLE\s+#{Regexp.escape(alias_name)}\b/
        off = 0
        found = T.let(false, T::Boolean)
        while off < window_lines.length && !found
          line = T.must(window_lines[off])
          idx = line =~ pat
          if idx
            line_no = with_line + off
            # 1-based column of the `MUTABLE` token.
            mut_col = idx + 1
            # The keyword is `MUTABLE` (7 chars) plus one trailing space.
            edits << Edit.new(
              span: Span.new(file: nil, line: line_no, col: mut_col, length: 'MUTABLE '.length),
              replacement: ''
            )
            found = true
          end
          off += 1
        end
      end
    end
    names_str = names.map { |n| "'#{n}'" }.join(', ')
    kw = { names: names_str, verb: verb }
    return error!(node, :WITH_GUARD_MUTABLE_MUTATED, **kw) if edits.empty?
    target = names.length == 1 ? 'the alias' : 'each guarded alias'
    fix = Fix.new(
      description: fix_description(:DROP_WITH_GUARD_MUTABLE, target: target),
      confidence: :interactive,
      edits: edits
    )
    fixable!(node,
      code: :WITH_GUARD_MUTABLE_MUTATED,
      **kw,
      category: :capability,
      level: :error,
      fixes: [fix],
      raise_in_collector: true)
  end

  # Capability: `WITH READ x` where x isn't `@writeLocked`. Two cases:
  # - x is `@locked` -> :auto fix swaps `@locked` -> `@writeLocked` (so
  #   concurrent readers can take WITH READ alongside WITH EXCLUSIVE
  #   writers).
  # - x has no sync (plain or otherwise) -> :auto fix inserts
  #   `@writeLocked` at the declaration.
  # Falls back to plain `error!` when no fix is locatable.
  sig { params(node: AST::WithBlock, name: String, var_node: AST::Node).returns(NilClass) }
  def emit_with_read_needs_write_lock!(node, name, var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    syn = cap_var_sync(var_node)
    fix = if syn == :locked
      build_decl_cap_replace_fix(name, '@locked', '@writeLocked',
        description_code: :REPLACE_LOCKED_WITH_WRITE_LOCKED,
        confidence: :auto)
    else
      build_decl_cap_insert_fix(name, '@writeLocked',
        description_code: :WITH_ADD_WRITE_LOCKED,
        description_params: { reader: "via `WITH READ`" },
        confidence: :auto)
    end
    return error!(node, :WITH_READ_NEEDS_WRITE_LOCK, name: name) unless fix
    fixable!(node,
      code: :WITH_READ_NEEDS_WRITE_LOCK,
      name: name,
      category: :capability,
      level: :error,
      fixes: [fix],
      raise_in_collector: true)
  end

  # Capability: plain `WITH x` on a binding with no recognised
  # capability. Surfaces 4 candidate sigils as :interactive options
  # (multiowned / shared / locked / writeLocked). Each is shown with
  # a one-line semantic difference. Falls through to plain `error!`
  # when no fixes are locatable.
  sig { params(node: AST::WithBlock, name: String).void }
  def emit_with_cannot_infer_cap!(node, name)
    T.bind(self, SemanticAnnotator) rescue nil
    candidates = [
      { sigil: '@multiowned',
        description_code: :WITH_ADD_MULTIOWNED,
        description_params: { suffix: "" } },
      { sigil: '@shared',
        description_code: :WITH_ADD_SHARED,
        description_params: { suffix: "across fibers" } },
      { sigil: '@locked',
        description_code: :WITH_ADD_LOCKED,
        description_params: {} },
      { sigil: '@writeLocked',
        description_code: :WITH_ADD_WRITE_LOCKED,
        description_params: { reader: "via WITH READ" } },
    ]
    fixes = candidates.filter_map do |c|
      build_decl_cap_insert_fix(name, c[:sigil],
        description_code: c[:description_code],
        description_params: c[:description_params],
        confidence: :interactive)
    end
    return error!(node, :WITH_CANNOT_INFER_CAP, name: name) if fixes.empty?
    fixable!(node,
      code: :WITH_CANNOT_INFER_CAP,
      name: name,
      category: :capability,
      level: :error,
      fixes: fixes,
      raise_in_collector: true)
  end

  # Capability: `WITH MATERIALIZED VIEW c AS s` where c isn't tense
  # (`~T`). The fix prefixes `~` to the type annotation on the
  # declaration line. Only handles single-line decls with a `: T`
  # annotation — bare-inferred declarations fall back to plain
  # `error!`.
  sig { params(node: AST::WithBlock, name: String, got: Type::TypeInput).returns(NilClass) }
  def emit_with_materialized_needs_tense!(node, name, got)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    scope = lookup_scope_for(name)
    decl = scope&.resolve_entry(name)&.reg
    src = @source_code
    fix = nil
    if decl && src
      token = decl.respond_to?(:token) ? decl.token : nil
      if token
        dline = token.line
        line_text = src.lines[dline - 1] || ''
        # Search from the decl-name column so a prior decl's `: TypeName`
        # on the same line is skipped.
        search_offset = token.column - 1
        ann_match = line_text[search_offset..]&.match(/:\s*([A-Za-z_][\w]*)/)
        if ann_match && !line_text.include?('~')
          type_col = search_offset + ann_match.begin(1) + 1  # 1-based
          fix = Fix.new(
            description: fix_description(:PREFIX_TENSE_TYPE, name: name),
            confidence: :interactive,
            edits: [Edit.new(
              span: Span.new(file: nil, line: dline, col: type_col, length: 0),
              replacement: '~'
            )]
          )
        end
      end
    end
    kw = { name: name, got: got }
    return error!(node, :WITH_MATERIALIZED_NEEDS_TENSE, **kw) unless fix
    fixable!(node,
      code: :WITH_MATERIALIZED_NEEDS_TENSE,
      **kw,
      category: :capability,
      level: :error,
      fixes: [fix],
      raise_in_collector: true)
  end

  # Capability: WITH RESTRICT on an immutable binding. :auto fix
  # locates the declaration and inserts `MUTABLE ` at its column —
  # same shape as emit_immutable_assignment_error!.
  sig { params(node: AST::WithBlock, var_node: AST::Identifier).returns(NilClass) }
  def emit_with_restrict_immutable_error!(node, var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    name = var_node.name
    scope = (var_node.symbol&.scope) || current_scope
    fix = build_declare_mutable_fix(name, scope)
    return error!(node, :WITH_RESTRICT_NEEDS_MUTABLE, name: name) unless fix
    fixable!(node,
      code: :WITH_RESTRICT_NEEDS_MUTABLE,
      name: name,
      category: :capability,
      level: :error,
      fixes: [fix])
  end

  # Style lint: a function with at least one MUTABLE param should end
  # in `!`. :auto fix appends `!` immediately after the function name.
  # Falls back to plain error! when the name token isn't available
  # (e.g. synthesized fns).
  sig { params(fn_node: AST::FunctionDef).void }
  def emit_style_mutable_param_needs_bang!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    name = fn_node.name
    name_tok = fn_node.name_token
    fix = nil
    if name_tok
      end_col = name_tok.column + name.length
      fix = Fix.new(
        description: fix_description(:APPEND_MUTABLE_PARAM_BANG, name: name),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: name_tok.line, col: end_col, length: 0),
          replacement: '!'
        )]
      )
    end
    return error!(fn_node, :STYLE_MUTABLE_PARAM_NEEDS_BANG, name: name) unless fix
    fixable!(fn_node,
      code: :STYLE_MUTABLE_PARAM_NEEDS_BANG,
      name: name,
      category: :lint,
      level: :error,
      fixes: [fix])
  end

  # Reentrance: `@canSmash` on BG/DO is recognized but not yet
  # implemented. :auto fix replaces the prefix sigil with `@service`
  # (OS-thread spawn — supported today, same compile-time guarantee).
  sig { params(node: EffectTracker::AsyncValidationNode).returns(NilClass) }
  def emit_can_smash_unsupported_error!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = nil
    tok = node.respond_to?(:can_smash_token) ? T.unsafe(node).can_smash_token : nil
    if tok
      fix = Fix.new(
        description: fix_description(:REPLACE_CAN_SMASH_WITH_SERVICE),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: tok.line, col: tok.column, length: tok.value.to_s.length),
          replacement: '@service'
        )]
      )
    end
    return error!(node, :CAN_SMASH_NOT_SUPPORTED) unless fix
    fixable!(node,
      code: :CAN_SMASH_NOT_SUPPORTED,
      category: :reentrance,
      level: :error,
      fixes: [fix])
  end

  # Type: `x: TargetType = some_value` where some_value's type doesn't
  # match. :interactive fix wraps the value in `CAST(value AS TargetType)`
  # — interactive because narrowing can lose data. Only offered when
  # the value is a literal whose source span is precisely known
  # (Literal nodes carry a token for the start; the value's textual
  # length is known from the parsed token's value).
  sig { params(node: T.any(AST::Assignment, AST::BindExpr), target_type: Type::TypeInput, value_type: Symbol).void }
  def emit_type_mismatch_assign_error!(node, target_type, value_type)
    T.bind(self, SemanticAnnotator) rescue nil
    kw = { got: value_type, expected: target_type }
    value = node.value
    fix = build_cast_wrap_fix(value, target_type)
    return error!(node, :TYPE_MISMATCH_ASSIGN, **kw) unless fix
    fixable!(node,
      code: :TYPE_MISMATCH_ASSIGN,
      **kw,
      category: :type,
      level: :error,
      fixes: [fix])
  end

  # Source-span length of a Literal token, used to position the
  # closing edit of a CAST wrap. `tok.value` is the PARSED value
  # (string sans quotes, integer sans separators/prefix/suffix), so
  # `tok.value.to_s.length` undershoots the actual source span for
  # strings, hex/oct/bin ints, separator-bearing numbers, and
  # suffixed numbers. Scan the source line forward from tok.column
  # to recover the true span. Falls back to `tok.value.to_s.length`
  # when @source_code is unavailable.
  sig { params(tok: Lexer::Token).returns(Integer) }
  def literal_source_length(tok)
    @source_code = T.let(@source_code, T.nilable(String))
    return tok.value.to_s.length unless @source_code
    line = @source_code.lines[tok.line - 1]
    return tok.value.to_s.length unless line
    rest = line[(tok.column - 1)..]
    return tok.value.to_s.length if rest.nil? || rest.empty?
    if rest.start_with?('"""')
      idx = rest.index('"""', 3)
      return idx ? idx + 3 : tok.value.to_s.length
    end
    if rest.start_with?('"')
      i = 1
      while i < rest.length
        ch = rest[i]
        break if ch == '"'
        i += 1 if ch == '\\' && i + 1 < rest.length
        i += 1
      end
      return i + 1
    end
    m = rest.match(/\A[\d_a-zA-Z.]+/)
    m ? T.must(m[0]).length : tok.value.to_s.length
  end

  # Helper: wrap a literal-or-identifier value with `CAST(... AS T)`.
  # Returns a Fix or nil. Only handles values whose textual span we
  # can compute exactly — Literal nodes (numeric / boolean / string)
  # and bare Identifier references. Anything else (binary expr,
  # function call) gets nil so the caller falls back to plain error!.
  sig { params(value: T.nilable(AST::Node), target_type: Type::TypeInput).returns(T.nilable(Fix)) }
  def build_cast_wrap_fix(value, target_type)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil unless value
    return nil unless value.token
    tok = value.token
    target_name = target_type.is_a?(Type) ? target_type.resolved : target_type
    text_length = case value
                  when AST::Literal
                    literal_source_length(tok)
                  when AST::Identifier
                    value.name.to_s.length
                  else
                    nil
                  end
    return nil unless text_length
    Fix.new(
      description: fix_description(:WRAP_VALUE_WITH_CAST, type: T.unsafe(target_name)),
      confidence: :interactive,
      edits: [
        Edit.new(span: Span.new(file: nil, line: tok.line, col: tok.column, length: 0),
                 replacement: "CAST("),
        Edit.new(span: Span.new(file: nil, line: tok.line, col: tok.column + text_length, length: 0),
                 replacement: " AS #{target_name})"),
      ]
    )
  end

  # Shared helper — returns a Fix that inserts a capability sigil
  # (`@locked`, `@shared`, ...) immediately before the `;` that
  # terminates the declaration line of `name`. Used by every
  # WITH-CAP-NEEDS-X fixable. Returns nil when:
  #  - the binding has no scope-local decl (param / field / global)
  #  - the decl line has no `;` (multi-line value expression)
  #  - the sigil is already present (idempotency — would be a no-op)
  sig do
    params(
      name: String,
      sigil: String,
      description_code: Symbol,
      description_params: T::Hash[Symbol, DiagnosticKwValue],
      confidence: Symbol
    ).returns(T.nilable(Fix))
  end
  def build_decl_cap_insert_fix(name, sigil, description_code: :ADD_DECL_CAPABILITY_GENERIC, description_params: {}, confidence: :auto)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    scope = lookup_scope_for(name)
    decl = scope&.resolve_entry(name)&.reg
    return nil unless decl && decl.respond_to?(:token) && decl.token
    return nil unless @source_code
    dline = decl.token.line
    line_text = @source_code.lines[dline - 1] || ''
    # Search from the decl-name column so a prior statement's `;` on
    # the same line is skipped.
    semi_idx = line_text.index(';', decl.token.column - 1)
    return nil unless semi_idx
    return nil if line_text.include?(sigil)
    insert_col = semi_idx + 1
    fix_params = description_params.merge(sigil: sigil, name: name, line: dline)
    Fix.new(
      description: fix_description_from_hash(description_code, fix_params),
      confidence: confidence,
      edits: [Edit.new(
        span: Span.new(file: nil, line: dline, col: insert_col, length: 0),
        replacement: " #{sigil}"
      )]
    )
  end

  # Shared helper — replace an existing sigil on the declaration line.
  # Returns nil when the old sigil isn't found on the line.
  sig do
    params(
      name: String,
      old_sigil: String,
      new_sigil: String,
      description_code: Symbol,
      description_params: T::Hash[Symbol, DiagnosticKwValue],
      confidence: Symbol
    ).returns(T.nilable(Fix))
  end
  def build_decl_cap_replace_fix(name, old_sigil, new_sigil, description_code: :CHANGE_DECL_CAPABILITY_GENERIC, description_params: {}, confidence: :auto)
    T.bind(self, SemanticAnnotator) rescue nil
    @source_code = T.let(@source_code, T.nilable(String))
    scope = lookup_scope_for(name)
    decl = scope&.resolve_entry(name)&.reg
    return nil unless decl && decl.respond_to?(:token) && decl.token
    return nil unless @source_code
    dline = decl.token.line
    line_text = @source_code.lines[dline - 1] || ''
    idx = line_text.index(old_sigil)
    return nil unless idx
    fix_params = description_params.merge(
      old_sigil: old_sigil,
      new_sigil: new_sigil,
      name: name,
      line: dline
    )
    Fix.new(
      description: fix_description_from_hash(description_code, fix_params),
      confidence: confidence,
      edits: [Edit.new(
        span: Span.new(file: nil, line: dline, col: idx + 1, length: old_sigil.length),
        replacement: new_sigil
      )]
    )
  end

  # Shared emit for the WITH-CAP-NEEDS-X family. `candidates` is an
  # ordered list of typed fix candidates; one Fix is
  # generated per candidate via `build_decl_cap_insert_fix`. Falls
  # back to plain `error!` (registry-formatted) when no candidate
  # is locatable (e.g. WITH target is a GetField / param).
  sig { params(node: AST::WithBlock, name: String, code: Symbol, candidates: T::Array[CapabilityFixCandidate], confidence: Symbol, kw: DiagnosticKwValue).void }
  def emit_with_cap_mismatch!(node, name, code, candidates, confidence: :auto, **kw)
    T.bind(self, SemanticAnnotator) rescue nil
    fixes = candidates.filter_map do |c|
      build_decl_cap_insert_fix(name, c.sigil,
        description_code: c.description_code,
        description_params: c.description_params,
        confidence: confidence)
    end
    return error!(node, code, **kw) if fixes.empty?
    case code
    when :WITH_EXCLUSIVE_NEEDS_LOCK
      fixable!(node,
        code: code,
        got: kw[:got],
        category: :capability,
        level: :error,
        fixes: fixes,
        raise_in_collector: true)
    when :WITH_SNAPSHOT_NEEDS_VERSIONED_OR_ATOMIC,
         :WITH_ATOMIC_NEEDS_SHARED_ATOMIC
      fixable!(node,
        code: code,
        name: kw[:name],
        actual: kw[:actual],
        category: :capability,
        level: :error,
        fixes: fixes,
        raise_in_collector: true)
    when :WITH_NEEDS_MULTIOWNED,
         :WITH_NEEDS_SHARED
      fixable!(node,
        code: code,
        name: kw[:name],
        category: :capability,
        level: :error,
        fixes: fixes,
        raise_in_collector: true)
    else
      Kernel.raise ArgumentError, "unsupported WITH capability mismatch diagnostic: #{code.inspect}"
    end
  end

  # Shared helper — returns a Fix that inserts `MUTABLE ` at the
  # declaration of `name` in `scope`. Returns nil when the declaration
  # isn't locatable or already carries `MUTABLE`.
  sig { params(name: String, scope: Scope).returns(T.nilable(Fix)) }
  def build_declare_mutable_fix(name, scope)
    T.bind(self, SemanticAnnotator) rescue nil
    info = scope.resolve_entry(name)
    return nil unless info
    # Locals carry a reg whose token is the binding's first source position.
    # Parameters have reg=nil but stash the VAR_ID token at decl time as
    # `param_decl_token` (set by declare_and_verify_params) so we can still
    # point a MUTABLE insertion at the signature.
    tok = nil
    decl = info.reg
    if decl && decl.token
      tok = decl.token
    elsif info.is_param && info.param_decl_token
      tok = info.param_decl_token
    end
    return nil unless tok
    return nil if tok.value == 'MUTABLE'

    Fix.new(
      description: fix_description(:DECLARE_MUTABLE_BINDING, name: name, line: tok.line),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: tok.line, col: tok.column, length: 0),
        replacement: 'MUTABLE '
      )]
    )
  end

  # Atomic bindings that escape their declaring scope need a reviewed migration
  # path: swapping to @shared:locked usually also requires wrapping primitives
  # in a STRUCT, so the fix is interactive rather than automatic.
  sig { params(source_sym: SymbolEntry, source_name: String).returns(T.nilable(Fix)) }
  def build_atomic_escape_migration_fix(source_sym, source_name)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil unless source_sym && source_sym.respond_to?(:sync) && source_sym.atomic?
    return nil unless @source_code
    reg = source_sym.respond_to?(:reg) ? source_sym.reg : nil
    return nil unless reg && reg.token
    line_num = reg.token.line
    return nil unless line_num
    src_line = @source_code.lines[line_num - 1] || ''
    # The sigil chain is order-independent: `@shared:atomic` and
    # `@atomic:shared` parse to the same Type. Match either form.
    # Search from the decl-name column so a prior decl's @shared:atomic
    # sigil on the same line is skipped.
    search_offset = reg.token.column - 1
    match = src_line[search_offset..]&.match(/@(?:shared:atomic|atomic:shared)/)
    return nil unless match
    start_col = search_offset + match.begin(0) + 1   # 1-based column

    Fix.new(
      description: fix_description(:MIGRATE_ATOMIC_ESCAPE, name: source_name),
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: line_num, col: start_col, length: T.must(match[0]).length),
        replacement: '@shared:locked'
      )]
    )
  end

  # ---------------------------------------------------------------
  # Auto / gradual-typing fixable findings plus operator-aware suggestions.
  # See docs/agents/gradual-typing.md §6 and §12.
  # ---------------------------------------------------------------

  # Per-operator candidate-type table. Each entry:
  # { default: Symbol, alts: [Symbol], notes: { Sym => String } }.
  # The :default candidate is ranked first; :alts follow in order.
  # When multiple operators apply to the same slot, the candidate
  # set is the INTERSECTION across ops; ranking is by lowest sum of
  # per-op indices (most-default-across-the-board wins).
  AUTO_OP_CANDIDATES = T.let({
    ADD:        { default: :Int64,   alts: [:Float64] },
    CONCAT:     { default: :String,  alts: [] },
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
  }.freeze, T::Hash[Symbol, AutoOperatorCandidateConfig])

  # Rank candidate concrete types from a Set<op_symbol> per the
  # AUTO_OP_CANDIDATES table. Returns [[type_sym, note_or_nil], ...]
  # ordered by:
  #   1. Type appears in EVERY observed op's candidate list (intersection).
  #   2. Sum of per-op rank (default = 0, first alt = 1, ...) ascending.
  # Notes carried through from any op that has a note for that type.
  sig { params(ops: T::Set[Symbol]).returns(T::Array[AutoCandidate]) }
  def auto_rank_candidates(ops)
    T.bind(self, SemanticAnnotator) rescue nil
    return [] if false || ops.empty?

    # Per-type aggregation across ops.
    agg = {}  # type_sym => { count:, rank_sum:, notes: [] }
    ops.each do |op|
      entry = AUTO_OP_CANDIDATES[op]
      next unless entry
      default = T.cast(entry[:default], Symbol)
      alts = T.cast(entry[:alts] || [], T::Array[Symbol])
      notes = T.cast(entry[:notes] || {}, T::Hash[Symbol, String])
      ranked = [default] + alts
      ranked.each_with_index do |type_sym, idx|
        stat = agg[type_sym]
        unless stat
          stat = { count: 0, rank_sum: 0, notes: [] }
          agg[type_sym] = stat
        end
        stat[:count] = T.cast(stat[:count], Integer) + 1
        stat[:rank_sum] = T.cast(stat[:rank_sum], Integer) + idx
        if notes[type_sym]
          T.cast(stat[:notes], T::Array[String]) << T.must(notes[type_sym])
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
      .map do |type_sym, v|
        AutoCandidate.new(
          type_sym: T.cast(type_sym, Symbol),
          note: T.cast(v[:notes], T::Array[String]).uniq.first
        )
      end
  end

  # Build an :interactive Fix for a single operator-derived candidate.
  # Returns nil when the slot has no Auto token to replace (implicit
  # Auto under --gradual; for those the diagnostic still surfaces the
  # candidates as text but no auto-applicable fix).
  sig { params(slot: AutoConstraintCollector::Slot, type_sym: Symbol, note: T.nilable(String), position: Integer).returns(T.nilable(Fix)) }
  def build_auto_candidate_fix(slot, type_sym, note, position)
    T.bind(self, SemanticAnnotator) rescue nil
    auto_tok = auto_token_for(slot)
    return nil unless auto_tok
    type_str = type_sym.to_s
    Fix.new(
      description: fix_description(:PIN_AUTO_SLOT,
        position: position,
        label: auto_slot_label(slot),
        type: type_str,
        note: note ? " #{note}" : ""),
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
  sig { params(ops: T::Set[Symbol], candidates: T::Array[AutoCandidate]).returns(String) }
  def build_auto_op_evidence_block(ops, candidates)
    T.bind(self, SemanticAnnotator) rescue nil
    return "" if candidates.empty?
    op_list = ops.to_a.sort.join(", ")
    msg = "\n  In the body, the binding is used in operator(s): #{op_list}.\n"
    msg << "  Suggested fixes:\n"
    idx = 0
    while idx < candidates.length
      candidate = candidates[idx]
      type_sym = T.unsafe(candidate).type_sym
      note = T.unsafe(candidate).note
      label = ""
      if idx == 0
        label = "(recommended)"
      end
      line = "    #{idx + 1}. #{label.ljust(15)} #{type_sym}"
      line << "  -- #{note}" if note
      msg << line << "\n"
      idx += 1
    end
    msg
  end

  # ---------------------------------------------------------------
  # Auto / gradual-typing fixable findings.
  # See docs/agents/gradual-typing.md §5 (clear fix integration) and
  # §6 (ambiguity resolution) for the diagnostic-format spec.
  # ---------------------------------------------------------------

  # Resolved Auto slot. Emits an :info finding with an :auto fix that
  # replaces the explicit `Auto` keyword with the resolved type's
  # source form. For implicit-Auto slots (omitted under `--gradual`),
  # there is no token to replace — we still emit the :info finding so
  # the user sees what was inferred, but no auto fix.
  #
  # Shape-tagged slots are skipped here because per-sub-slot findings would
  # replace the binding's `Auto` with a scalar element/key/value type instead
  # of the whole container type.
  sig { params(resolution: AutoUnifier::Resolution).returns(NilClass) }
  def emit_auto_resolved_finding!(resolution)
    T.bind(self, SemanticAnnotator) rescue nil
    slot = resolution.slot
    return if slot.respond_to?(:shape) && slot.shape

    type_str = auto_type_source_form(resolution.type)
    label = auto_slot_label(slot)
    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || slot.decl_node,
      code: :AUTO_INFERRED_TYPE,
      label: label,
      type: type_str,
      category: :type, level: :info,
      fixes: build_auto_replace_fixes(auto_tok, type_str),
    )
  end

  # Emits a single :info finding per shape-tracked decl whose `decl.type` has
  # been wrapped successfully. The fix replacement uses the wrapped container
  # type so `clear fix` rewrites `Auto` to e.g. `Int64[]` or
  # `HashMap<String, Int64>` rather than the misleading scalar.
  # Partial map resolutions intentionally produce no resolved
  # finding here — the unresolved sub-slot's finding tells the
  # user what's missing.
  sig { params(decl: AutoConstraintCollector::SlotDeclNode, slot: AutoConstraintCollector::Slot).returns(NilClass) }
  def emit_auto_shape_resolved_finding!(decl, slot)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless decl.is_a?(AST::VarDecl) || decl.is_a?(AST::BindExpr)
    return unless decl&.type
    return if decl.type.auto?  # not yet wrapped — skip
    type_str = auto_type_source_form(decl.type)
    name = decl.respond_to?(:name) ? decl.name : "<binding>"
    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || decl,
      code: :AUTO_INFERRED_BINDING_TYPE,
      name: name,
      type: type_str,
      category: :type, level: :info,
      fixes: build_auto_replace_fixes(auto_tok, type_str),
    )
  end

  # Shared `:auto`-confidence Fix builder: returns `[Fix]` that
  # replaces the literal `Auto` keyword span with `type_str`. Empty
  # array if `auto_tok` is nil (implicit-Auto under `--gradual` —
  # there's no token span to edit).
  sig { params(auto_tok: T.nilable(Lexer::Token), type_str: String).returns(T::Array[Fix]) }
  def build_auto_replace_fixes(auto_tok, type_str)
    T.bind(self, SemanticAnnotator) rescue nil
    return [] unless auto_tok
    [Fix.new(
      description: fix_description(:REPLACE_AUTO_WITH_INFERRED, type: type_str),
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
  # conversion fixes are a follow-up because they require each callsite's
  # argument span and a coercion table. Operator-derived candidates are added
  # when the body uses the binding in operator expressions.
  sig { params(ambiguity: AutoUnifier::Ambiguity, op_evidence: OperatorEvidenceCollector::EvidenceMap).returns(NilClass) }
  def emit_auto_ambiguity_finding!(ambiguity, op_evidence: {})
    T.bind(self, SemanticAnnotator) rescue nil
    slot = ambiguity.slot
    label = auto_slot_label(slot)
    observed = ambiguity.observed_types
    observed_strs = observed.map { |t| auto_type_source_form(t) }

    message = build_auto_ambiguity_message(T.must(label), observed_strs, slot)

    slot_id = slot_id_for(slot)
    ops = slot_id ? (op_evidence[slot_id] || Set.new) : Set.new
    candidates = auto_rank_candidates(ops)
    message += build_auto_op_evidence_block(ops, candidates) unless candidates.empty?

    fixes = []
    candidates.each_with_index do |candidate, i|
      fix = build_auto_candidate_fix(slot, candidate.type_sym, candidate.note, i + 1)
      fixes << fix if fix
    end

    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || slot.decl_node,
      code: :AUTO_AMBIGUOUS_TYPE,
      detail: message, category: :type, level: :error, fixes: fixes,
    )
  end

  # No observed types at all — Auto slot the inference pass could not
  # constrain (e.g., a parameter on a fn that's never called, or an
  # empty `[]` never used). Emits :error directing the user to
  # specify a concrete type. When the body uses the binding in operator
  # expressions, ranked candidate types are offered as interactive fixes.
  sig { params(slot: AutoConstraintCollector::Slot, op_evidence: OperatorEvidenceCollector::EvidenceMap).returns(NilClass) }
  def emit_auto_unresolved_finding!(slot, op_evidence: {})
    T.bind(self, SemanticAnnotator) rescue nil
    label = auto_slot_label(slot)
    base_msg = "Cannot infer type for #{label} — no observed uses to drive inference."

    slot_id = slot_id_for(slot)
    ops = slot_id ? (op_evidence[slot_id] || Set.new) : Set.new
    candidates = auto_rank_candidates(ops)

    message = base_msg.dup
    if candidates.empty?
      message << " Replace `Auto` with a concrete type, or remove the unused declaration."
    else
      message << build_auto_op_evidence_block(ops, candidates)
    end

    fixes = []
    candidates.each_with_index do |candidate, i|
      fix = build_auto_candidate_fix(slot, candidate.type_sym, candidate.note, i + 1)
      fixes << fix if fix
    end

    auto_tok = auto_token_for(slot)
    fixable!(
      auto_tok || slot.decl_node,
      code: :AUTO_UNRESOLVED_TYPE,
      detail: message, category: :type, level: :error, fixes: fixes,
    )
  end

  # Reverse-lookup helper: given a Slot struct, return its hash key
  # in the slots map (matches the IDs AutoConstraintCollector uses).
  sig { params(slot: AutoConstraintCollector::Slot).returns(T.nilable(AutoSlotId)) }
  def slot_id_for(slot)
    T.bind(self, SemanticAnnotator) rescue nil
    kind = slot.kind
    return nil if kind == :param && !(slot.fn_name && slot.index)
    return nil if kind == :return && !slot.fn_name

    case kind
    when :param  then AutoSlotId.param(T.must(slot.fn_name), T.must(slot.index))
    when :return then AutoSlotId.return(T.must(slot.fn_name))
    when :local
      AutoSlotId.local(T.cast(slot.decl_node, AutoConstraintCollector::DeclarationNode))
    end
  end

  # ---------------------------------------------------------------
  # Auto helpers (private to this module).
  # ---------------------------------------------------------------

  sig { params(type: AutoConstraintCollector::ObservedType).returns(String) }
  def auto_type_source_form(type)
    T.bind(self, SemanticAnnotator) rescue nil
    # Prefer the resolved symbol's name; falls back to to_s for
    # parameterized types (`Int64[]`, `HashMap<String, Int64>`).
    if type.is_a?(Type)
      sym = type.resolved
      sym.to_s
    else
      type.to_s
    end
  end

  sig { params(slot: AutoConstraintCollector::Slot).returns(T.nilable(String)) }
  def auto_slot_label(slot)
    T.bind(self, SemanticAnnotator) rescue nil
    # Shape-tagged slots get a more specific label so the diagnostic tells the
    # user which sub-type is being inferred.
    if slot.respond_to?(:shape) && slot.shape
      return auto_shape_slot_label(slot)
    end

    case slot.kind
    when :param
      auto_param_slot_label(slot)
    when :return
      "return type of `#{slot.fn_name}`"
    when :local
      auto_local_slot_label(slot)
    else
      # AutoConstraintCollector only creates :param / :return /
      # :local slots. A different kind reaching this path means a
      # caller fabricated a Slot with an unrecognized kind — fail
      # loudly so the bug isn't masked by a "slot" placeholder
      # appearing in user-facing diagnostics.
      raise ArgumentError, "auto_slot_label: unrecognized slot kind #{slot.kind.inspect}"
    end
  end

  sig { params(slot: AutoConstraintCollector::Slot).returns(T.nilable(String)) }
  def auto_shape_slot_label(slot)
    T.bind(self, SemanticAnnotator) rescue nil
    name = T.cast(slot.decl_node, AutoConstraintCollector::DeclarationNode).name
    case slot.shape
    when :list_element then "element type of list `#{name}`"
    when :map_key      then "key type of map `#{name}`"
    when :map_value    then "value type of map `#{name}`"
    end
  end

  sig { params(slot: AutoConstraintCollector::Slot).returns(String) }
  def auto_param_slot_label(slot)
    T.bind(self, SemanticAnnotator) rescue nil
    fn = T.cast(slot.decl_node, AST::FunctionDef)
    param = T.must(fn.params[T.must(slot.index)])
    "parameter '#{param.name}' of `#{slot.fn_name}`"
  end

  sig { params(slot: AutoConstraintCollector::Slot).returns(String) }
  def auto_local_slot_label(slot)
    T.bind(self, SemanticAnnotator) rescue nil
    name = T.cast(slot.decl_node, AutoConstraintCollector::DeclarationNode).name
    "local '#{name}'"
  end

  sig { params(slot: AutoConstraintCollector::Slot).returns(T.nilable(Lexer::Token)) }
  def auto_token_for(slot)
    T.bind(self, SemanticAnnotator) rescue nil
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

  sig { params(label: String, observed_strs: T::Array[String], slot: AutoConstraintCollector::Slot).returns(String) }
  def build_auto_ambiguity_message(label, observed_strs, slot)
    T.bind(self, SemanticAnnotator) rescue nil
    types_list = observed_strs.join(', ')
    msg = "Ambiguous Auto for #{label}: observed as #{types_list}.\n"

    # Option 1: pin one type; convert at divergent callsites.
    msg << "  Option 1 (recommended): pin one concrete type at the\n"
    msg << "    declaration and convert at the divergent sites. The\n"
    msg << "    candidate types observed are: #{types_list}.\n"
    msg << "    Pick the one whose semantics match your intent and\n"
    msg << "    convert the others (e.g. `Int64.toString(x)`,\n"
    msg << "    `Int.fromString(s) OR_ELSE RAISE`).\n"

    # Option 2: types not obviously compatible.
    msg << "  Option 2: if these types do not have an obvious\n"
    msg << "    conversion path, restructure the call sites so a\n"
    msg << "    single concrete type flows through.\n"

    # Option 3: union — example only, never auto-applied.
    if slot.kind == :param || slot.kind == :return
      union_name = if slot.kind == :param
        fn = T.cast(slot.decl_node, AST::FunctionDef)
        T.must(fn.params[T.must(slot.index)]).name.capitalize
      else
        "Result"
      end
      variant_parts = T.let([], T::Array[String])
      i = T.let(0, Integer)
      while i < observed_strs.length
        variant_parts << "Variant#{i}: #{observed_strs.fetch(i)}"
        i += 1
      end
      variants = variant_parts.join(', ')
      msg << "  Option 3 (last resort): if you genuinely need to accept\n"
      msg << "    multiple types, define a union explicitly:\n"
      msg << "      UNION #{union_name} { #{variants} }\n"
      msg << "    Auto does NOT auto-create unions.\n"
    end

    msg
  end

  private :build_decl_cap_insert_fix,
    :build_decl_cap_replace_fix,
    :literal_source_length
  private :anchor_at
  private :auto_rank_candidates
  private :auto_slot_label
  private :auto_type_source_form
  private :auto_token_for
  private :build_auto_ambiguity_message
  private :build_auto_candidate_fix
  private :build_auto_op_evidence_block
  private :build_auto_replace_fixes
  private :build_atomic_escape_migration_fix
  private :build_cast_wrap_fix
  private :build_declare_mutable_fix
  private :closest_name
  private :consumer_source_text
  private :emit_overflow_suffix_fix!
  private :levenshtein
  private :ownership_active_phrase
  private :ownership_passive_phrase
  private :smallest_fitting_int_type
  private :slot_id_for
  private :variant_anchor_from_getfield
  private :variant_anchor_from_unionlit

end
