# CLEAR source formatter.
#
# Status: v1.1.
#
# v1.1 implements:
#   - Parse validation (refuse-on-error).
#   - Lossless tokenization preserving raw text (strings, comments, etc.).
#   - Intra-line spacing canonicalization:
#       * space around binary operators, `=`, after `,` and `;`
#       * no space inside `()` / `[]` / `{}`
#       * no space around `.` or `::`
#       * tense sigils (`!` `?` `%` `~`) attach to following type/sigil
#       * unary `-` / `!` / `~` attach at expression-start positions
#       * call/index attach: `foo(`, `foo[`, `)(`, `](`, `][`
#       * type annotation `:` — no space before, one space after
#   - Comment spacing: trailing `--` has 2 spaces before, 1 space after.
#   - FN one-liner expansion (§7): every FN becomes multi-line with body
#     statements split on `;` boundaries.
#   - STRUCT / UNION / ENUM (§3.8): one field/variant per line.
#   - 2-space indent recomputed from block structure (opens: `{` `THEN` `DO`
#     `->` line-terminal; closes: `END` `}` line-leading; outdents:
#     `ELSE` `ELSE_IF` `CATCH` `DEFAULT` line-leading).
#   - Blank-line normalization: collapse 3+ to 2, exactly one blank before
#     CATCH/DEFAULT, strip trailing blanks.
#   - Idempotent: fmt(fmt(x)) == fmt(x).
#
# Deferred to v1.2:
#   - FN signature forced wrap when >120 chars (§3.1).
#   - WITH forced wraps: 2+ captures, 1-cap >120, ON-clause shape (§3.2, §3.3).
#   - Pipeline forced wraps incl. `s> RECOVER` extra indent (§3.4, §3.7).
#   - Method chain forced wrap (§3.5).
#   - Pipeline/chain assignment drop when first line >80 (§3.6).
#
# Deferred to v2:
#   - Warn-only 120-char width reports.
#   - Ambiguous-comment-attachment detection + refuse-to-write.
#   - Continuation indent for arbitrary expression wrap.
#   - Integer `_` separator normalization.

require_relative '../ast/lexer'
require_relative '../ast/parser'
require 'strscan'
require 'set'

class Formatter
  class Error < StandardError; end

  INDENT = '  '

  # Tokens after which `-`/`!`/`~` is unary (attaches to the following token).
  EXPR_START_KEYWORDS = %w[
    RETURN IF THEN ELSE ELSE_IF WHILE DO FOR IN BG
    RAISE ASSERT OR AS CATCH DEFAULT MATCH WHEN
    TAP RECOVER EXIT PASS PRUNE GIVE TAKES COPY MOVE
    CLONE FREEZE LINK RESOLVE START YIELD
    SELECT WHERE INDEX REDUCE ORDER_BY LIMIT SKIP UNNEST
    DISTINCT EACH FIND ANY ALL COUNT SUM AVERAGE MIN MAX
    CONCURRENT SHARD TAKE_WHILE WINDOW JOIN MUTABLE
    ASSERT_RAISES CAPTURES SEQUENCE TRUE FALSE NIL
    NEXT CAST
  ].to_set.freeze

  EXPR_START_SYMS = [
    '(', '[', '{', ',', ';', '=', '<', '>', '+', '*', '/', '%', '?', ':'
  ].to_set.freeze

  EXPR_START_OPS = %w[
    == != <= >= && || ** += -= *= /= :: -> s>
    .. ..< ..<= ..= %* %+ %- !* !+ !-
  ].to_set.freeze

  OPEN_TERMINAL   = %w[-> { THEN DO].freeze
  CLOSE_LEADING   = %w[END }].freeze
  OUTDENT_LEADING = %w[ELSE ELSE_IF CATCH DEFAULT].freeze
  BLANK_BEFORE    = %w[CATCH DEFAULT].freeze

  # Keywords that attach directly to a following `(` — no space inserted.
  # Everything else gets a space between keyword and `(`.
  ATTACH_PAREN_AFTER = %w[
    WITH RETRY WINDOW RECOVER JOIN SHARD REDUCE
    ASSERT ASSERT_RAISES CAST
  ].to_set.freeze

  def self.format(source)
    new(source).format
  end

  def initialize(source)
    @source = source
  end

  def format
    validate_parse!
    tokens = FormatLexer.new(@source).tokenize
    Emitter.new(tokens).emit
  end

  private

  def validate_parse!
    ts = ::Lexer.new(@source).tokenize
    ::Parser.new(ts, @source).parse
  rescue => e
    raise Error, "parse error: #{e.message}"
  end
end

# -----------------------------------------------------------------------
# Lossless tokenizer.
#
# Unlike the main Lexer, this one preserves the raw source text of every
# token (including quotes around strings and interpolation expressions).
# String tokens are kept opaque: we don't decode escapes or desugar `${}`.
# -----------------------------------------------------------------------
class Formatter::FormatLexer
  Token = Struct.new(:type, :raw, :line, :col)

  def initialize(source)
    @src = source
    @s = StringScanner.new(source)
    @line = 1
    @col  = 1
    @out  = []
  end

  def tokenize
    until @s.eos?
      sl, sc = @line, @col
      case
      when m = @s.scan(/[ \t]+/)             then push(:WS, m, sl, sc)
      when m = @s.scan(/\r?\n/)              then push(:NL, m, sl, sc)
      when m = @s.scan(/--[^\n]*/)           then push(:COMMENT, m, sl, sc)
      when m = @s.scan(/"""(?:.|\n)*?"""/m)  then push(:STRING, m, sl, sc)
      when @s.peek(1) == '"'
        raw = consume_string
        push(:STRING, raw, sl, sc)
      when m = @s.scan(/->|s>|==|!=|>=|<=|&&|\|\||\*\*|\+=|-=|\*=|\/=|::|\.\.<=|\.\.=|\.\.<|\.\.\.|\.\.|%\*|%\+|%-|!\*|!\+|!-/)
        push(:OP, m, sl, sc)
      when m = @s.scan(/[=+\-*\/<>&|!.,;(){}\[\]:?~%]/)
        push(:SYM, m, sl, sc)
      when m = @s.scan(/[a-zA-Z_@]\w*[!?]?/)
        if ::Lexer::KEYWORDS.include?(m)
          push(:KEYWORD, m, sl, sc)
        elsif m =~ /\A[A-Z]/
          push(:TYPE_ID, m, sl, sc)
        else
          push(:VAR_ID, m, sl, sc)
        end
      when m = @s.scan(/0[xob][0-9a-fA-F_]+(?:_[a-zA-Z][a-zA-Z0-9]*)?/)
        push(:NUM, m, sl, sc)
      when m = @s.scan(/\d+\.\d+(?:_[a-zA-Z][a-zA-Z0-9]*)?/)
        push(:NUM, m, sl, sc)
      when m = @s.scan(/\d+(?:_[a-zA-Z][a-zA-Z0-9]*)?/)
        push(:NUM, m, sl, sc)
      else
        raise Formatter::Error, "lex error at #{@line}:#{@col} near #{@s.peek(10).inspect}"
      end
    end
    @out
  end

  private

  # Consume balanced `"..."` string including `\` escapes and `${...}`
  # interpolation (which may nest braces). Returns raw source text
  # (including the surrounding quotes). Advances the scanner.
  def consume_string
    start = @s.pos
    @s.getch # opening quote
    depth = 0
    until @s.eos?
      c = @s.peek(1)
      if c == '\\'
        @s.getch
        @s.getch unless @s.eos?
        next
      end
      if depth == 0 && c == '"'
        @s.getch
        break
      end
      if c == '$' && @s.peek(2) == '${'
        @s.getch; @s.getch
        depth += 1
        next
      end
      if depth > 0 && c == '{'
        @s.getch
        depth += 1
        next
      end
      if depth > 0 && c == '}'
        @s.getch
        depth -= 1
        next
      end
      @s.getch
    end
    # NOTE: StringScanner#pos is a BYTE offset. Use byteslice so multi-byte
    # characters earlier in the source (e.g., `—` in comments) don't shift
    # the string-literal slice off its actual boundaries.
    @src.byteslice(start...@s.pos)
  end

  def push(type, raw, line, col)
    @out << Token.new(type, raw, line, col)
    advance(raw)
  end

  def advance(s)
    nl = s.count("\n")
    if nl > 0
      @line += nl
      last = s.rindex("\n")
      @col = s.length - last
    else
      @col += s.length
    end
  end
end

# -----------------------------------------------------------------------
# Emitter.
#
# Operates on a lossless token stream:
#   1. Drops :WS tokens; we regenerate spacing from scratch.
#   2. Applies structural transformations that may insert :NL tokens
#      (FN expansion, STRUCT/UNION/ENUM one-per-line).
#   3. Renders: walks tokens, emits canonical spacing, tracks block depth
#      for indent, normalizes blank lines, places comments.
# -----------------------------------------------------------------------
class Formatter::Emitter
  INDENT          = Formatter::INDENT
  OPEN_TERMINAL   = Formatter::OPEN_TERMINAL
  CLOSE_LEADING   = Formatter::CLOSE_LEADING
  OUTDENT_LEADING = Formatter::OUTDENT_LEADING
  BLANK_BEFORE    = Formatter::BLANK_BEFORE

  def initialize(tokens)
    @tokens = tokens
  end

  def emit
    toks = @tokens.reject { |t| t.type == :WS }
    toks = collapse_newlines(toks)
    toks = expand_fn_blocks(toks)
    toks = expand_then_do_blocks(toks)
    toks = expand_with_blocks(toks)
    toks = expand_pipelines(toks)
    toks = expand_record_types(toks)
    toks = collapse_newlines(toks)
    render(toks)
  end

  private

  # ---- pre-passes on the token stream ---------------------------------

  # Collapse runs of 3+ consecutive :NL into 2.
  def collapse_newlines(toks)
    out = []
    run = 0
    toks.each do |t|
      if t.type == :NL
        run += 1
        out << t if run <= 2
      else
        run = 0
        out << t
      end
    end
    out
  end

  # For each top-level `FN ... -> ... END` (or any nested FN), ensure that
  # the body is multi-line: a newline follows `->` and precedes `END`, and
  # statements in between are split on `;` boundaries.
  def expand_fn_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && t.raw == 'FN'
        i = emit_fn_block(out, toks, i)
      else
        out << t
        i += 1
      end
    end
    out
  end

  # Emits a FN block starting at index `start` (token = 'FN') into `out`.
  # Returns the index after the matching `END`.
  def emit_fn_block(out, toks, start)
    # Copy up to and including the `->` that ends the signature.
    arrow_idx = find_fn_arrow(toks, start)
    unless arrow_idx
      out << toks[start]
      return start + 1
    end

    (start..arrow_idx).each { |j| out << toks[j] }

    # Ensure exactly one :NL after the arrow (strip any blank line directly
    # after the signature — bodies start immediately at +1 indent).
    insert_nl(out)

    # Walk body, tracking depth, until matching END at depth 0.
    depth = 0
    j = arrow_idx + 1
    j = skip_nls(toks, j)
    body_start = out.length
    while j < toks.length
      tj = toks[j]
      if tj.type == :KEYWORD && tj.raw == 'END' && depth == 0
        break
      end
      # Nested END-terminated constructs: only the keywords whose scope
      # actually closes with END. Brace-terminated blocks (WITH/MATCH/
      # STRUCT/UNION/ENUM/BG) are handled by the `{`/`}` branches below.
      # Filter WITH (`CATCH Input WITH(...)`) is not a block opener.
      if tj.type == :KEYWORD && %w[FN IF WHILE FOR TEST WHEN].include?(tj.raw)
        if tj.raw == 'FN'
          j = emit_fn_block(out, toks, j)
          next
        else
          depth += 1
          out << tj
          j += 1
          next
        end
      end
      if tj.type == :KEYWORD && tj.raw == 'END'
        depth -= 1
        out << tj
        j += 1
        next
      end
      if tj.type == :SYM && tj.raw == '{'
        depth += 1
        out << tj
        j += 1
        next
      end
      if tj.type == :SYM && tj.raw == '}'
        depth -= 1
        out << tj
        j += 1
        next
      end
      # Statement boundary: `;` at depth 0 — force newline after it and
      # skip exactly one following source NL (it's redundant with the one
      # I just inserted). Additional source NLs pass through as blank lines.
      if tj.type == :SYM && tj.raw == ';' && depth == 0
        out << tj
        j += 1
        insert_nl(out)
        j += 1 if j < toks.length && toks[j].type == :NL
        next
      end
      # ELSE / ELSE_IF / CATCH / DEFAULT at this depth: ensure they start
      # on a new line.
      if tj.type == :KEYWORD && Formatter::OUTDENT_LEADING.include?(tj.raw) && depth == 0
        insert_nl(out)
        out << tj
        j += 1
        next
      end
      out << tj
      j += 1
    end

    # Strip any trailing NLs in the body and insert exactly one before END.
    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      insert_nl(out)
    end
    if j < toks.length
      out << toks[j]  # END
      j += 1
    end
    j
  end

  def skip_nls(toks, j)
    j += 1 while j < toks.length && toks[j].type == :NL
    j
  end

  def find_fn_arrow(toks, fn_idx)
    depth = 0
    j = fn_idx + 1
    while j < toks.length
      t = toks[j]
      case
      when t.type == :SYM && t.raw == '('  then depth += 1
      when t.type == :SYM && t.raw == ')'  then depth -= 1
      when t.type == :SYM && t.raw == '['  then depth += 1
      when t.type == :SYM && t.raw == ']'  then depth -= 1
      when t.type == :OP  && t.raw == '->' && depth == 0 then return j
      when t.type == :KEYWORD && t.raw == 'END' && depth == 0 then return nil
      end
      j += 1
    end
    nil
  end

  # Expand one-liner IF / WHILE / FOR blocks that use THEN or DO...END.
  # Detects blocks where no newline appears between the opening keyword and
  # the matching END, and expands them so the body is on its own line(s).
  # Multi-line forms are left untouched.
  def expand_then_do_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && %w[IF WHILE FOR].include?(t.raw)
        end_idx = one_liner_end(toks, i)
        if end_idx
          i = expand_if_while_for(out, toks, i, end_idx)
        else
          out << t
          i += 1
        end
      else
        out << t
        i += 1
      end
    end
    out
  end

  # Returns the index of the matching END if and only if no :NL appears
  # anywhere between `start` and that END (i.e., the whole construct is
  # a single source line). Otherwise nil.
  def one_liner_end(toks, start)
    depth = 0
    j = start + 1
    while j < toks.length
      t = toks[j]
      return nil if t.type == :NL
      if t.type == :KEYWORD
        case t.raw
        when 'IF', 'WHILE', 'FOR', 'TEST', 'WHEN', 'FN'
          depth += 1
        when 'END'
          return j if depth == 0
          depth -= 1
        end
      elsif t.type == :SYM
        case t.raw
        when '{' then depth += 1
        when '}' then depth -= 1
        end
      end
      j += 1
    end
    nil
  end

  # Expand a one-liner `IF/WHILE/FOR ... THEN|DO ... END` between indices
  # `start` (keyword) and `end_idx` (matching END). Emits into `out` and
  # returns the index after END.
  def expand_if_while_for(out, toks, start, end_idx)
    # Find the THEN or DO terminator at depth 0.
    term_idx = nil
    depth = 0
    (start + 1...end_idx).each do |j|
      t = toks[j]
      if t.type == :SYM && t.raw == '('      then depth += 1
      elsif t.type == :SYM && t.raw == ')'   then depth -= 1
      elsif t.type == :SYM && t.raw == '['   then depth += 1
      elsif t.type == :SYM && t.raw == ']'   then depth -= 1
      elsif t.type == :KEYWORD && %w[THEN DO].include?(t.raw) && depth == 0
        term_idx = j
        break
      end
    end
    unless term_idx
      # No terminator found — don't rewrite.
      out << toks[start]
      return start + 1
    end

    # Copy up through the terminator.
    (start..term_idx).each { |j| out << toks[j] }
    insert_nl(out)

    # Walk body tokens. Split `;` boundaries; outdent ELSE/ELSE_IF.
    depth = 0
    j = term_idx + 1
    body_start = out.length
    while j < end_idx
      tj = toks[j]
      if tj.type == :SYM && tj.raw == '('      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == ')'      then depth -= 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '['      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == ']'      then depth -= 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '{'      then depth += 1; out << tj; j += 1; next end
      if tj.type == :SYM && tj.raw == '}'      then depth -= 1; out << tj; j += 1; next end

      if tj.type == :SYM && tj.raw == ';' && depth == 0
        out << tj
        j += 1
        insert_nl(out)
        next
      end
      if tj.type == :KEYWORD && %w[ELSE ELSE_IF].include?(tj.raw) && depth == 0
        insert_nl(out)
        out << tj
        j += 1
        next
      end
      out << tj
      j += 1
    end

    # Strip any trailing NLs in body; insert exactly one before END.
    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      insert_nl(out)
    end
    out << toks[end_idx]  # END
    end_idx + 1
  end

  # ---- WITH forced wraps (§3.2, §3.3) -----------------------------------
  #
  # A block WITH has the shape `WITH caps... { body } [ON clause...]`. Two
  # triggers force multi-line layout:
  #   (a) 2+ capture clauses (comma-separated) — captures split onto their
  #       own lines, body at +2, `}` at +1.
  #   (b) any trailing ON ... / RETRY ... clause after `}` — `}` moves to
  #       its own line at +1, ON moves to +1, body at +2.
  # Both triggers can combine. `CATCH Input WITH(...)` filter uses
  # `WITH(`; it is NOT a block WITH and we leave it alone.
  def expand_with_blocks(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && t.raw == 'WITH' && with_is_block?(toks, i)
        i = emit_with_block(out, toks, i)
      else
        out << t
        i += 1
      end
    end
    out
  end

  def with_is_block?(toks, idx)
    j = idx + 1
    while j < toks.length && [:NL, :COMMENT].include?(toks[j].type)
      j += 1
    end
    return true if j >= toks.length
    !(toks[j].type == :SYM && toks[j].raw == '(')
  end

  def emit_with_block(out, toks, start)
    brace_idx = find_with_open_brace(toks, start)
    unless brace_idx
      out << toks[start]
      return start + 1
    end
    close_idx = find_matching_close_brace(toks, brace_idx)
    unless close_idx
      out << toks[start]
      return start + 1
    end

    # Captures between WITH and `{`; count top-level commas + 1.
    cap_count = 1
    depth = 0
    (start + 1 ... brace_idx).each do |j|
      t = toks[j]
      next unless t.type == :SYM
      case t.raw
      when '(', '[' then depth += 1
      when ')', ']' then depth -= 1
      when ','      then cap_count += 1 if depth == 0
      end
    end

    on_end = consume_on_clause(toks, close_idx + 1)
    has_on = on_end > close_idx + 1
    multi_cap = cap_count >= 2

    unless multi_cap || has_on
      out << toks[start]
      return start + 1
    end

    # ---- apply wrap ----------------------------------------------------
    out << toks[start]  # WITH

    if multi_cap
      insert_nl(out)
      out << phantom(:INDENT_OPEN)
      depth = 0
      j = start + 1
      j = skip_nls(toks, j)
      while j < brace_idx
        t = toks[j]
        if t.type == :NL
          j += 1
          next
        end
        if t.type == :SYM && t.raw == ',' && depth == 0
          out << t
          j += 1
          insert_nl(out)
          j = skip_nls(toks, j)
          next
        end
        if t.type == :SYM
          case t.raw
          when '(', '[' then depth += 1
          when ')', ']' then depth -= 1
          end
        end
        out << t
        j += 1
      end
      out << toks[brace_idx]  # `{`
      # Body is at (captures:+1) + (`{`:+1) = +2 naturally.
    else
      # Single cap, has_on. Emit capture tokens as-is up to and including `{`.
      (start + 1 .. brace_idx).each { |j| out << toks[j] }
      # Body needs +2 but `{` only gives +1; add extra marker.
      out << phantom(:INDENT_OPEN)
    end

    insert_nl(out)
    j = skip_nls(toks, brace_idx + 1)
    while j < close_idx
      out << toks[j]
      j += 1
    end
    out.pop while out.last && out.last.type == :NL
    insert_nl(out)
    out << toks[close_idx]  # `}`

    if has_on
      # Emit ON clause tokens on their own line at +1.
      insert_nl(out)
      j = close_idx + 1
      j = skip_nls(toks, j)
      while j < on_end
        t = toks[j]
        j += 1
        next if t.type == :NL
        out << t
      end
    end

    # Attach INDENT_CLOSE to the end of the current line (after last code).
    # Source NL / trailing whitespace handles line termination from here.
    out << phantom(:INDENT_CLOSE)

    has_on ? on_end : close_idx + 1
  end

  def find_with_open_brace(toks, start)
    depth = 0
    j = start + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[' then depth += 1
        when ')', ']' then depth -= 1
        when '{' then return j if depth == 0
        end
      end
      j += 1
    end
    nil
  end

  def find_matching_close_brace(toks, open_idx)
    depth = 0
    j = open_idx + 1
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '{' then depth += 1
        when '}'
          return j if depth == 0
          depth -= 1
        end
      end
      j += 1
    end
    nil
  end

  # Starting at `start` (one past `}`), attach any trailing
  # ON / RETRY segments. Returns the index of the last token of the ON
  # clause (usually a NL), or `start` if no clause. Does NOT advance past
  # NLs that follow the final ON segment — those blank lines belong to
  # the enclosing scope.
  def consume_on_clause(toks, start)
    cursor = start
    loop do
      peek = skip_nls(toks, cursor)
      break if peek >= toks.length
      t = toks[peek]
      break unless t.type == :KEYWORD && on_keyword?(t.raw)
      cursor = consume_on_segment(toks, peek)
    end
    cursor
  end

  def on_keyword?(raw)
    %w[ON RETRY POSSIBLE_DEADLOCK POSSIBLE_LOCK_CYCLE].include?(raw)
  end

  def consume_on_segment(toks, start)
    depth = 0
    j = start
    while j < toks.length
      t = toks[j]
      if t.type == :SYM
        case t.raw
        when '(', '[', '{' then depth += 1
        when ')', ']', '}' then depth -= 1
        end
      end
      if t.type == :NL && depth == 0
        return j
      end
      j += 1
    end
    j
  end

  def phantom(type)
    Formatter::FormatLexer::Token.new(type, '', 0, 0)
  end

  # ---- Pipeline forced wraps (§3.4, §3.7) --------------------------------
  #
  # When a pipeline chain has 2+ `s>` stages (at the same expression depth,
  # before any `;` / `,` / closing bracket), each stage renders on its own
  # line at +1 from the receiver.
  #
  # `s> RECOVER(...)` gets one extra indent level relative to its sibling
  # stages:  users s> a s> RECOVER(default) s> b  ->
  #   users
  #     s> a
  #     s> RECOVER(default)    <-- +1 more
  #     s> b
  def expand_pipelines(toks)
    chains = find_s_chains(toks)
    return toks if chains.empty?

    s_to_chain = {}
    chains.each { |c| c[:s_idxs].each { |idx| s_to_chain[idx] = c } }
    recover_s = detect_recover_stages(toks, chains)

    out = []
    i = 0
    while i < toks.length
      chain = s_to_chain[i]
      if chain && chain[:s_idxs].first == i
        i = emit_chain(out, toks, chain, recover_s)
      else
        out << toks[i]
        i += 1
      end
    end
    out
  end

  def find_s_chains(toks)
    chains = []
    i = 0
    while i < toks.length
      if toks[i].type == :OP && toks[i].raw == 's>'
        s_idxs = [i]
        depth = 0
        j = i + 1
        while j < toks.length
          t = toks[j]
          if t.type == :SYM
            case t.raw
            when '(', '[', '{' then depth += 1
            when ')', ']', '}'
              if depth == 0
                break
              else
                depth -= 1
              end
            when ',', ';'
              break if depth == 0
            end
          elsif t.type == :OP && t.raw == 's>' && depth == 0
            s_idxs << j
          end
          j += 1
        end
        chains << { s_idxs: s_idxs, end_idx: j } if s_idxs.length >= 2
        i = j
      else
        i += 1
      end
    end
    chains
  end

  def detect_recover_stages(toks, chains)
    result = {}
    chains.each do |c|
      c[:s_idxs].each do |idx|
        j = idx + 1
        j += 1 while j < toks.length && toks[j].type == :NL
        if j < toks.length && toks[j].type == :KEYWORD && toks[j].raw == 'RECOVER'
          result[idx] = true
        end
      end
    end
    result
  end

  # Emit a wrapped pipeline chain. Each stage on its own line at +1
  # (relative to receiver). Stages that are `s> RECOVER(...)` get an
  # additional +1. Strips source NLs inside stages so the canonical
  # layout wins regardless of the input layout.
  def emit_chain(out, toks, chain, recover_s)
    s_idxs  = chain[:s_idxs]
    end_idx = chain[:end_idx]

    insert_nl(out)
    out << phantom(:INDENT_OPEN)

    s_idxs.each_with_index do |s_idx, k|
      next_bound = s_idxs[k + 1] || end_idx
      recover    = recover_s[s_idx]

      insert_nl(out) if k > 0
      out << phantom(:INDENT_OPEN) if recover

      out << toks[s_idx]  # s>

      (s_idx + 1 ... next_bound).each do |j|
        next if toks[j].type == :NL  # discard source NLs inside a stage
        out << toks[j]
      end

      out << phantom(:INDENT_CLOSE) if recover
    end

    out << phantom(:INDENT_CLOSE)
    end_idx
  end

  # Split STRUCT / UNION / ENUM blocks so each field/variant is its own line.
  def expand_record_types(toks)
    out = []
    i = 0
    while i < toks.length
      t = toks[i]
      if t.type == :KEYWORD && %w[STRUCT UNION ENUM].include?(t.raw)
        i = emit_record_type(out, toks, i)
      else
        out << t
        i += 1
      end
    end
    out
  end

  def emit_record_type(out, toks, start)
    # Copy tokens until the opening `{`.
    j = start
    while j < toks.length
      t = toks[j]
      out << t
      j += 1
      break if t.type == :SYM && t.raw == '{'
    end
    return j if j >= toks.length

    # Canonicalize: exactly one NL after `{`, one NL after each top-level
    # `,`, one NL before `}`. Internal NLs/comments (e.g., default-method
    # FN declarations with leading comments in UNION bodies) are preserved.
    insert_nl(out)
    j = skip_nls(toks, j)

    depth = 0
    body_start = out.length
    while j < toks.length
      t = toks[j]
      if t.type == :SYM && t.raw == '{'
        depth += 1; out << t; j += 1; next
      end
      if t.type == :SYM && t.raw == '}'
        if depth == 0
          break
        else
          depth -= 1; out << t; j += 1; next
        end
      end
      if t.type == :SYM && t.raw == '(' then depth += 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == ')' then depth -= 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == '[' then depth += 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == ']' then depth -= 1; out << t; j += 1; next end
      if t.type == :SYM && t.raw == ',' && depth == 0
        out << t; j += 1
        insert_nl(out)
        j += 1 if j < toks.length && toks[j].type == :NL
        next
      end
      out << t
      j += 1
    end

    if body_start < out.length
      out.pop while out.last && out.last.type == :NL && out.length > body_start
      insert_nl(out)
    end
    if j < toks.length
      out << toks[j]  # `}`
      j += 1
    end
    j
  end

  # Ensure the last token in `out` is exactly one :NL. If the last token
  # is already :NL, leave it. Otherwise append a fresh :NL.
  def insert_nl(out)
    return if out.last && out.last.type == :NL
    out << Formatter::FormatLexer::Token.new(:NL, "\n", 0, 0)
  end

  # ---- rendering ------------------------------------------------------

  # Walks the transformed token stream and produces the final string.
  # Maintains: indent depth, per-line buffers, last non-comment code token
  # (for spacing decisions). `:INDENT_OPEN` / `:INDENT_CLOSE` phantom tokens
  # adjust depth for forced wraps where no `{` / `END` drives the change.
  def render(toks)
    lines = tokens_to_lines(toks)
    lines = ensure_blank_before_catch(lines)
    lines = drop_trailing_blanks(lines)

    depth = 0
    out = +""
    lines.each do |raw_line|
      pre_delta, post_delta, line = split_indent_markers(raw_line)
      depth = [depth + pre_delta, 0].max

      if line.empty?
        out << "\n"
        depth = [depth + post_delta, 0].max
        next
      end

      first = first_code(line)
      last  = last_code(line)

      line_depth = depth
      if first && CLOSE_LEADING.include?(first.raw)
        depth = [depth - 1, 0].max
        line_depth = depth
      elsif first && OUTDENT_LEADING.include?(first.raw)
        line_depth = [depth - 1, 0].max
      end

      out << (INDENT * line_depth)
      out << format_line_body(line)
      out << "\n"

      if last && OPEN_TERMINAL.include?(last.raw)
        depth += 1
      end
      depth = [depth + post_delta, 0].max
    end
    out
  end

  # Extract INDENT_OPEN/INDENT_CLOSE markers from a line. Markers that
  # appear before any code token adjust depth BEFORE the line renders
  # (pre_delta); markers that appear after code adjust depth after
  # (post_delta). Returns [pre_delta, post_delta, filtered_line].
  def split_indent_markers(line)
    pre = 0
    post = 0
    filtered = []
    seen_code = false
    line.each do |t|
      if t.type == :INDENT_OPEN
        seen_code ? post += 1 : pre += 1
      elsif t.type == :INDENT_CLOSE
        seen_code ? post -= 1 : pre -= 1
      else
        filtered << t
        seen_code = true if t.type != :COMMENT
      end
    end
    [pre, post, filtered]
  end

  def tokens_to_lines(toks)
    lines = []
    cur = []
    toks.each do |t|
      if t.type == :NL
        lines << cur
        cur = []
      else
        cur << t
      end
    end
    lines << cur unless cur.empty?
    lines
  end

  def first_code(line)
    line.find { |t| t.type != :COMMENT }
  end

  def last_code(line)
    line.reverse.find { |t| t.type != :COMMENT }
  end

  def ensure_blank_before_catch(lines)
    out = []
    lines.each do |line|
      fc = first_code(line)
      if fc && BLANK_BEFORE.include?(fc.raw) && !out.empty?
        # Strip any existing trailing blanks and insert exactly one.
        out.pop while out.last && out.last.empty?
        out << [] unless out.empty?
      end
      out << line
    end
    out
  end

  def drop_trailing_blanks(lines)
    lines = lines.dup
    lines.pop while lines.last && lines.last.empty?
    lines
  end

  # Emit a line's tokens with canonical intra-line spacing.
  # Comments get 2-space prefix if inline, 1 space after `--`.
  def format_line_body(line)
    buf = +""
    prev = nil  # previous emitted *code* token
    line.each_with_index do |t, idx|
      if t.type == :COMMENT
        # Trailing (inline) comment if any code precedes on this line.
        body = canonicalize_comment(t.raw)
        if prev
          buf << '  '
          buf << body
        else
          # Standalone leading comment on its own line.
          buf << body
        end
        next
      end
      if prev
        buf << ' ' if needs_space?(prev, t, line, idx)
      end
      buf << t.raw
      prev = t
    end
    buf
  end

  # Normalize a `--...` comment: exactly one space after `--`, trailing
  # whitespace stripped. `--` alone (empty comment) stays `--`.
  def canonicalize_comment(raw)
    body = raw[2..].to_s
    body = body.rstrip
    return '--' if body.empty?
    body = body.sub(/\A\s+/, '')
    "-- #{body}"
  end

  # Spacing decision between two adjacent code tokens A (prev) and B (cur).
  def needs_space?(a, b, line, b_idx)
    # No space inside opening/closing brackets.
    return false if a.type == :SYM && ['(', '[', '{'].include?(a.raw)
    return false if b.type == :SYM && [')', ']', '}'].include?(b.raw)

    # No space around `.` or `::`.
    return false if a.type == :SYM && a.raw == '.'
    return false if b.type == :SYM && b.raw == '.'
    return false if a.type == :OP  && a.raw == '::'
    return false if b.type == :OP  && b.raw == '::'

    # Call / index attach.
    if b.type == :SYM && b.raw == '('
      return false if [:VAR_ID, :TYPE_ID].include?(a.type)
      return false if a.type == :SYM && [')', ']'].include?(a.raw)
      return false if a.type == :KEYWORD && Formatter::ATTACH_PAREN_AFTER.include?(a.raw)
    end
    if b.type == :SYM && b.raw == '['
      return false if [:VAR_ID, :TYPE_ID].include?(a.type)
      return false if a.type == :SYM && [')', ']'].include?(a.raw)
    end

    # No space before `,` or `;`.
    if b.type == :SYM && (b.raw == ',' || b.raw == ';')
      return false
    end

    # Type annotation `:` — no space before, space after (default).
    if b.type == :SYM && b.raw == ':'
      return false
    end

    # Tense sigils (`!` `?` `%` `~`) attach to following type / sigil.
    if a.type == :SYM && %w[! ? % ~].include?(a.raw)
      if b.type == :TYPE_ID
        return false
      end
      if b.type == :SYM && %w[! ? % ~].include?(b.raw)
        return false
      end
      # Unary use at expression start: attach.
      if unary_context?(line, b_idx - 1)
        return false
      end
    end

    # Unary `-` at expression start: attach (e.g., `-1`).
    if a.type == :SYM && a.raw == '-' && unary_context?(line, b_idx - 1)
      return false
    end

    # `%` as modulus needs space; as sigil handled above. Default: space.

    # Default: one space.
    true
  end

  # Is position `a_idx` in `line` a unary-operator context — i.e., does
  # the token at `a_idx` appear at the start of an expression?
  #
  # This is true when the previous non-comment token is one of a set of
  # keywords/symbols/operators that end an expression.
  def unary_context?(line, a_idx)
    j = a_idx - 1
    while j >= 0
      prev = line[j]
      j -= 1
      next if prev.type == :COMMENT
      case prev.type
      when :KEYWORD
        return Formatter::EXPR_START_KEYWORDS.include?(prev.raw)
      when :SYM
        return true if Formatter::EXPR_START_SYMS.include?(prev.raw)
        return false
      when :OP
        return true if Formatter::EXPR_START_OPS.include?(prev.raw)
        return false
      else
        return false
      end
    end
    true  # start of line — treat as expression start
  end
end
